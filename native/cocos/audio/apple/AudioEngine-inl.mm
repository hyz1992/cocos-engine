/****************************************************************************
 Copyright (c) 2014-2016 Chukong Technologies Inc.
 Copyright (c) 2017-2022 Xiamen Yaji Software Co., Ltd.

 http://www.cocos.com

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated engine source code (the "Software"), a limited,
 worldwide, royalty-free, non-assignable, revocable and non-exclusive license
 to use Cocos Creator solely to develop games on your target platforms. You shall
 not use Cocos Creator software for developing other software or tools that's
 used for developing games. You are not granted to publish, distribute,
 sublicense, and/or sell copies of Cocos Creator.

 The software or tools in this License Agreement are licensed, not sold.
 Xiamen Yaji Software Co., Ltd. reserves all rights not expressly granted to you.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
****************************************************************************/

#define LOG_TAG "AudioEngine-inl.mm"
#include "audio/apple/AudioEngine-inl.h"

#import <OpenAL/alc.h>
#import <AVFoundation/AVFoundation.h>
#if CC_PLATFORM == CC_PLATFORM_IOS
    #import <UIKit/UIApplication.h>
#endif

#include "audio/include/AudioEngine.h"
#include "application/ApplicationManager.h"
#include "base/Scheduler.h"
#include "base/Utils.h"
#include "base/memory/Memory.h"
#include "platform/FileUtils.h"
#include "AudioDecoder.h"

using namespace cc;

static ALCdevice *s_ALDevice = nullptr;
static ALCcontext *s_ALContext = nullptr;
static AudioEngineImpl *s_instance = nullptr;

typedef ALvoid (*alSourceNotificationProc)(ALuint sid, ALuint notificationID, ALvoid *userData);
typedef ALenum (*alSourceAddNotificationProcPtr)(ALuint sid, ALuint notificationID, alSourceNotificationProc notifyProc, ALvoid *userData);
static ALenum alSourceAddNotificationExt(ALuint sid, ALuint notificationID, alSourceNotificationProc notifyProc, ALvoid *userData) {
    static alSourceAddNotificationProcPtr proc = nullptr;

    if (proc == nullptr) {
        proc = (alSourceAddNotificationProcPtr)alcGetProcAddress(nullptr, "alSourceAddNotification");
    }

    if (proc) {
        return proc(sid, notificationID, notifyProc, userData);
    }
    return AL_INVALID_VALUE;
}

#if CC_PLATFORM == CC_PLATFORM_IOS
@interface AudioEngineSessionHandler : NSObject {
}

@property (nonatomic, assign) Boolean needReactiveContext;
/** 避免重复排队重建音频引擎 */
@property (nonatomic, assign) Boolean rebuildScheduled;
/** 录音进行中：录音模块会主动把 session 切成 PlayAndRecord，这段时间不要去改它 */
@property (nonatomic, assign) Boolean recordActive;

- (id)init;
- (void)handleInterruption:(NSNotification *)notification;
- (void)resumeAudio:(NSNotification *)notification;
- (void)reactiveAudio;
- (void)handleVoiceRecordWillStart:(NSNotification *)notification;
- (void)handleVoiceRecordDidFinish:(NSNotification *)notification;
- (void)handleAdState:(NSNotification *)notification;
- (void)handleMediaServicesWereReset:(NSNotification *)notification;
- (void)handleRouteChange:(NSNotification *)notification;
- (void)restoreAudioSession:(NSString *)reason;
- (void)checkAndRestoreAudioSession:(NSString *)reason;
- (void)scheduleRestoreAudioSession:(NSString *)reason;
- (void)rebuildAudioEngine:(NSString *)reason;
- (void)rebuildAudioEngineIfNeeded:(NSString *)reason;

@end

/**
 把 AVAudioSession 拉回游戏期望的状态，并把 OpenAL 上下文重新挂上。
 广告SDK/录音等模块切走 session 后往往不会还原，这里统一做修复。
 只依赖文件级静态变量，所以音频引擎重建之后也能直接调用。
 返回 false 表示 OpenAL 上下文已不可用，需要重建 device/context。
 */
static bool bkRestoreAudioSession(const char *reason) {
    if (s_ALDevice == nullptr || s_ALContext == nullptr) {
        ALOGI("[AUDIO_DEBUG] AudioRestore(%s): skip, OpenAL is not initialized", reason);
        // 引擎尚未初始化（甚至还没被使用过）时不需要重建
        return true;
    }

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;

    // 1. 广告SDK常把 category 改成 Playback/PlayAndRecord 且不还原，统一拉回 Ambient
    NSString *categoryBefore = audioSession.category;
    if (![categoryBefore isEqualToString:AVAudioSessionCategoryAmbient]) {
        error = nil;
        BOOL success = [audioSession setCategory:AVAudioSessionCategoryAmbient error:&error];
        ALOGI("[AUDIO_DEBUG] AudioRestore(%s): category \"%s\" -> Ambient, success=%d, error=%s",
              reason, categoryBefore.UTF8String, (int)success, error ? error.description.UTF8String : "nil");
    }

    // 2. 广告SDK关闭时可能把 session 置为 inactive，不重新激活的话 OpenAL 就再也没有输出了
    error = nil;
    BOOL active = [audioSession setActive:YES error:&error];
    // outputVolume 一并打出来：万一是广告SDK把系统音量改成了0（有些SDK为了强推广告音量会这么干），
    // 这行日志能直接看出来，避免继续在会话/上下文上排查
    ALOGI("[AUDIO_DEBUG] AudioRestore(%s): setActive YES, success=%d, error=%s, category=%s, outputVolume=%.2f, otherAudioPlaying=%d",
          reason, (int)active, error ? error.description.UTF8String : "nil",
          audioSession.category.UTF8String, audioSession.outputVolume, (int)audioSession.isOtherAudioPlaying);

    // 3. 重新挂上 OpenAL 上下文：上下文被摘掉后即使不报错也不会出声，必须重新挂上
    if (alcGetCurrentContext() == s_ALContext) {
        ALOGI("[AUDIO_DEBUG] AudioRestore(%s): OpenAL context is current", reason);
        return true;
    }
    if (alcMakeContextCurrent(s_ALContext)) {
        ALOGI("[AUDIO_DEBUG] AudioRestore(%s): OpenAL context re-activated", reason);
        return true;
    }

    ALOGE("[AUDIO_DEBUG] AudioRestore(%s): alcMakeContextCurrent FAILED", reason);
    return false;
}

@implementation AudioEngineSessionHandler


- (id)init {
    if (self = [super init]) {
        self.needReactiveContext = false;
        self.rebuildScheduled = false;
        self.recordActive = false;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAudio:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAudio:) name:UIApplicationWillEnterForegroundNotification object:nil];

        // 系统媒体服务被重置（audiomxd 崩溃重启）后，OpenAL 的 device/context 会变成不可用的僵尸对象，
        // 按 Apple 的要求必须销毁重建，只切上下文是无效的
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMediaServicesWereReset:) name:AVAudioSessionMediaServicesWereResetNotification object:[AVAudioSession sharedInstance]];
        // 音频路由变化（插拔耳机/蓝牙）后同样要确认 session 与上下文可用
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:[AVAudioSession sharedInstance]];
        
        // 监听录音模块的通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleVoiceRecordWillStart:) name:@"VoiceRecordWillStartRecording" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleVoiceRecordDidFinish:) name:@"VoiceRecordDidFinishRecording" object:nil];

        // 监听广告开关：广告SDK播放视频时会自己切换 AVAudioSession，结束后往往不还原，
        // 这是"看广告回来没音效"的根因；广告开始只记录，广告结束做恢复
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAdState:) name:@"BKAudioAdStateChanged" object:nil];
        
        NSError *error = nil;
        BOOL success = [[AVAudioSession sharedInstance]
                        setCategory:AVAudioSessionCategoryAmbient
                        error:&error];
        if (!success) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: Fail to set audio session in init, error=%s", error ? error.description.UTF8String : "nil");
        } else {
            ALOGI("[AUDIO_DEBUG] AudioEngine: Audio session initialized with category Ambient");
        }
    }
    return self;
}

- (void)restoreAudioSession:(NSString *)reason {
    if (!bkRestoreAudioSession(reason.UTF8String)) {
        [self rebuildAudioEngine:@"contextRestoreFailed"];
    }
    self.needReactiveContext = false;
}

- (void)checkAndRestoreAudioSession:(NSString *)reason {
    // 录音期间录音模块会主动切成 PlayAndRecord，不能动
    if (self.recordActive) {
        return;
    }
    // 后台/过渡态不要去激活音频会话，回到前台时 resumeAudio 会统一恢复
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }

    // 正常情况下 category 就是 Ambient，这里只是一次字符串比较，开销可忽略；
    // 只有确认被外部模块改过（广告SDK/视频播放器等改完不还原）才动手，不做任何投机性操作
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSString *category = audioSession.category;
    if ([category isEqualToString:AVAudioSessionCategoryAmbient]) {
        return;
    }

    ALOGI("[AUDIO_DEBUG] AudioRestore(%s): session category is \"%s\", changed by other module - restoring",
          reason.UTF8String, category.UTF8String);
    [self restoreAudioSession:reason];
}

- (void)scheduleRestoreAudioSession:(NSString *)reason {
    [self restoreAudioSession:reason];

    // 广告/录音等SDK往往在自己的回调栈里才做音频会话收尾，只恢复一次可能会被它们改回去，
    // 因此再补几次延迟恢复（幂等操作，重复执行无副作用）
    NSTimeInterval delays[] = {0.2, 0.8, 2.0};
    for (int i = 0; i < 3; ++i) {
        NSTimeInterval delay = delays[i]; // 每轮捕获一个标量，避免block捕获到局部数组指针
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self restoreAudioSession:@"delayed"];
        });
    }
}

- (void)rebuildAudioEngineIfNeeded:(NSString *)reason {
    // 延迟一点再判断：有些失败是瞬时的（例如中断过程中音频硬件还没交还）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (s_ALDevice == nullptr || s_ALContext == nullptr) {
            return;
        }
        if (alcGetCurrentContext() == s_ALContext) {
            ALOGI("[AUDIO_DEBUG] AudioRebuild(%s): canceled, OpenAL context is fine now", reason.UTF8String);
            return;
        }
        [self rebuildAudioEngine:reason];
    });
}

- (void)rebuildAudioEngine:(NSString *)reason {
    if (self.rebuildScheduled) {
        return;
    }
    // 音频引擎还没初始化过（游戏还没播过声音）就没什么可重建的，
    // 更不能在这里反向触发初始化：那会平白创建音频设备并改动音频会话
    if (s_ALDevice == nullptr && s_ALContext == nullptr) {
        ALOGI("[AUDIO_DEBUG] AudioRebuild(%s): skip, audio engine was never initialized", reason.UTF8String);
        return;
    }
    self.rebuildScheduled = true;
    ALOGW("[AUDIO_DEBUG] AudioRebuild(%s): scheduling OpenAL device/context rebuild", reason.UTF8String);

    // 必须异步执行：end() 会析构 AudioEngineImpl（也就是本对象的持有者），在回调栈里直接调用等于删掉自己
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rebuildScheduled = false;
        ALOGW("[AUDIO_DEBUG] AudioRebuild: end() + lazyInit() begin");
        AudioEngine::end();
        bool success = AudioEngine::lazyInit();
        ALOGW("[AUDIO_DEBUG] AudioRebuild: lazyInit result=%d", (int)success);
        if (success) {
            bkRestoreAudioSession("rebuildDone");
        }
        ALOGW("[AUDIO_DEBUG] AudioRebuild: done. All previous audio players were dropped, "
              "next play2d will recreate the OpenAL device/context");
    });
}

- (void)reactiveAudio {
    if (self.needReactiveContext) {
        ALOGI("[AUDIO_DEBUG] AudioRestore: reactiveAudio, needReactiveContext was set");
        [self restoreAudioSession:@"reactive"];
    }
}

- (void)resumeAudio:(NSNotification *)notification {
    // 保持引擎原有行为：系统打断结束（或应用回到前台）时按标记恢复一次
    [self reactiveAudio];
    // 再补一次"有证据才动手"的检查：广告/视频等外部模块改了 session 又不还原时，category 能看出来
    [self checkAndRestoreAudioSession:@"appActive"];
}

- (void)handleInterruption:(NSNotification *)notification {

    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
        NSInteger reason = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] integerValue];
        if (reason == AVAudioSessionInterruptionTypeBegan) {
            ALOGI("[AUDIO_DEBUG] AudioEngine: Audio interruption BEGAN - suspending OpenAL context");
            alcMakeContextCurrent(nullptr);
        } else if (reason == AVAudioSessionInterruptionTypeEnded) {
            ALOGI("[AUDIO_DEBUG] AudioEngine: Audio interruption ENDED - scheduling context restoration");
            // When the application goes to background, invoke alcMakeContextCurrent may fail. So a flag is set here to delay the execution
            self.needReactiveContext = true;
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                [self reactiveAudio];
            }
        }
    }
}

- (void)handleVoiceRecordWillStart:(NSNotification *)notification {
    ALOGI("[AUDIO_DEBUG] AudioEngine: VoiceRecord will start - game audio will be ducked (auto reduced to ~20%% volume)");
    // 录音即将开始
    // 使用了 PlayAndRecord + DuckOthers 方案：
    // - 游戏音效不会中断，只是音量自动降低到约 20%
    // - 录音结束后音量会自动恢复到 100%
    // - 不需要手动干预，系统自动处理
    self.recordActive = true;
}

- (void)handleVoiceRecordDidFinish:(NSNotification *)notification {
    ALOGI("[AUDIO_DEBUG] AudioRestore: voice record did finish");
    self.recordActive = false;
    // 录音结束：录音模块会把 session 从 PlayAndRecord 切回 Ambient，这里补上一次恢复，
    // 保证 OpenAL 上下文可用（录音后没音效也是历史上踩过的坑）
    [self scheduleRestoreAudioSession:@"recordDone"];
}

- (void)handleAdState:(NSNotification *)notification {
    NSString *state = [[notification userInfo] objectForKey:@"state"];

    if ([state isEqualToString:@"start"]) {
        // 只记录，不做任何事：广告开始时不主动改音频会话，
        // 避免广告SDK的会话操作和游戏音频互相影响（宁可不作为，也不能让游戏变哑）
        ALOGI("[AUDIO_DEBUG] AudioAd: ad will show (observer only)");
        return;
    }

    if ([state isEqualToString:@"close"]) {
        ALOGI("[AUDIO_DEBUG] AudioAd: ad did close - restoring audio session");
        // 广告播放期间广告SDK会自己切换 AVAudioSession（category/active）且结束时往往不还原，
        // 这是"看完广告回来没音效"的根因，这里统一恢复
        [self scheduleRestoreAudioSession:@"adClose"];
        return;
    }

    ALOGW("[AUDIO_DEBUG] AudioAd: unknown ad state \"%s\"", state.UTF8String);
}

- (void)handleMediaServicesWereReset:(NSNotification *)notification {
    // 媒体服务被系统重置：所有音频对象（含 OpenAL 的 device/context）都成了僵尸对象，
    // 按 Apple 文档必须销毁重建，光切换上下文是没用的
    ALOGW("[AUDIO_DEBUG] AudioRestore: media services were reset");
    [self rebuildAudioEngine:@"mediaServicesReset"];
}

- (void)handleRouteChange:(NSNotification *)notification {
    NSInteger reason = [[[notification userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    ALOGI("[AUDIO_DEBUG] AudioRoute: route changed (reason=%ld) - checking audio session", (long)reason);
    // 只做"有证据才动手"的检查：正常情况下 category 仍是 Ambient，这里什么都不做；
    // 只有在路由变化过程中被外部模块改坏时才恢复
    [self checkAndRestoreAudioSession:@"routeChange"];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"VoiceRecordWillStartRecording" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"VoiceRecordDidFinishRecording" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BKAudioAdStateChanged" object:nil];

    [super dealloc];
}
@end

static id s_AudioEngineSessionHandler = nullptr;
#endif

ALvoid AudioEngineImpl::myAlSourceNotificationCallback(ALuint sid, ALuint notificationID, ALvoid *userData) {
    // Currently, we only care about AL_BUFFERS_PROCESSED event
    if (notificationID != AL_BUFFERS_PROCESSED)
        return;

    // 该回调由 OpenAL 内部线程发起，析构（应用退出/音频引擎重建）过程中可能与之并发，先判空
    if (s_instance == nullptr)
        return;

    AudioPlayer *player = nullptr;
    s_instance->_threadMutex.lock();
    for (const auto &e : s_instance->_audioPlayers) {
        player = e.second;
        if (player->_alSource == sid && player->_streamingSource) {
            player->wakeupRotateThread();
        }
    }
    s_instance->_threadMutex.unlock();
}

AudioEngineImpl::AudioEngineImpl()
: _lazyInitLoop(true), _currentAudioID(0) {
    s_instance = this;
}

AudioEngineImpl::~AudioEngineImpl() {
    // 先断开全局实例引用：OpenAL 内部线程的通知回调会用到它
    s_instance = nullptr;

    if (auto sche = _scheduler.lock()) {
        sche->unschedule("AudioEngine", this);
    }

    if (s_ALContext) {
        alDeleteSources(MAX_AUDIOINSTANCES, _alSources);

        _audioCaches.clear();

        alcMakeContextCurrent(nullptr);
        alcDestroyContext(s_ALContext);
        // 置空静态指针：销毁/重建后，延迟回调不能再操作悬空指针
        s_ALContext = nullptr;
    }
    if (s_ALDevice) {
        alcCloseDevice(s_ALDevice);
        s_ALDevice = nullptr;
    }

#if CC_PLATFORM == CC_PLATFORM_IOS
    [s_AudioEngineSessionHandler release];
    s_AudioEngineSessionHandler = nullptr;
#endif
}

bool AudioEngineImpl::init() {
    bool ret = false;
    do {
#if CC_PLATFORM == CC_PLATFORM_IOS
        ALOGI("[AUDIO_DEBUG] AudioEngine: Initializing audio engine");
        s_AudioEngineSessionHandler = [[AudioEngineSessionHandler alloc] init];
#endif

        s_ALDevice = alcOpenDevice(nullptr);
        
        if (!s_ALDevice) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: alcOpenDevice FAILED");
            break;
        }
        ALOGI("[AUDIO_DEBUG] AudioEngine: alcOpenDevice SUCCESS");

        if (s_ALDevice) {
            s_ALContext = alcCreateContext(s_ALDevice, nullptr);
            if (!s_ALContext) {
                ALOGE("[AUDIO_DEBUG] AudioEngine: alcCreateContext FAILED");
                break;
            }
            ALOGI("[AUDIO_DEBUG] AudioEngine: alcCreateContext SUCCESS");
            
            if (!alcMakeContextCurrent(s_ALContext)) {
                ALOGE("[AUDIO_DEBUG] AudioEngine: Initial alcMakeContextCurrent FAILED");
                break;
            }
            ALOGI("[AUDIO_DEBUG] AudioEngine: Initial alcMakeContextCurrent SUCCESS");

            alGenSources(MAX_AUDIOINSTANCES, _alSources);
            auto alError = alGetError();
            if (alError != AL_NO_ERROR) {
                ALOGE("%s:generating sources failed! error = %x", __PRETTY_FUNCTION__, alError);
                break;
            }

            for (int i = 0; i < MAX_AUDIOINSTANCES; ++i) {
                _unusedSourcesPool.push_back(_alSources[i]);
                alSourceAddNotificationExt(_alSources[i], AL_BUFFERS_PROCESSED, myAlSourceNotificationCallback, nullptr);
            }

            // fixed #16170: Random crash in alGenBuffers(AudioCache::readDataTask) at startup
            // Please note that, as we know the OpenAL operation is atomic (threadsafe),
            // 'alGenBuffers' may be invoked by different threads. But in current implementation of 'alGenBuffers',
            // When the first time it's invoked, application may crash!!!
            // Why? OpenAL is opensource by Apple and could be found at
            // http://opensource.apple.com/source/OpenAL/OpenAL-48.7/Source/OpenAL/oalImp.cpp .
            /*

            void InitializeBufferMap()
            {
                if (gOALBufferMap == NULL) // Position 1
                {
                    gOALBufferMap = ccnew OALBufferMap ();  // Position 2

                    // Position Gap

                    gBufferMapLock = ccnew CAGuard("OAL:BufferMapLock"); // Position 3
                    gDeadOALBufferMap = ccnew OALBufferMap ();

                    OALBuffer   *newBuffer = ccnew OALBuffer (AL_NONE);
                    gOALBufferMap->Add(AL_NONE, &newBuffer);
                }
            }

            AL_API ALvoid AL_APIENTRY alGenBuffers(ALsizei n, ALuint *bids)
            {
                ...

                try {
                    if (n < 0)
                    throw ((OSStatus) AL_INVALID_VALUE);

                    InitializeBufferMap();
                    if (gOALBufferMap == NULL)
                    throw ((OSStatus) AL_INVALID_OPERATION);

                    CAGuard::Locker locked(*gBufferMapLock);  // Position 4
                ...
                ...
            }

             */
            // 'gBufferMapLock' will be initialized in the 'InitializeBufferMap' function,
            // that's the problem. It means that 'InitializeBufferMap' may be invoked in different threads.
            // It will be very dangerous in multi-threads environment.
            // Imagine there're two threads (Thread A, Thread B), they call 'alGenBuffers' simultaneously.
            // While A goto 'Position Gap', 'gOALBufferMap' was assigned, then B goto 'Position 1' and find
            // that 'gOALBufferMap' isn't NULL, B just jump over 'InitialBufferMap' and goto 'Position 4'.
            // Meanwhile, A is still at 'Position Gap', B will crash at '*gBufferMapLock' since 'gBufferMapLock'
            // is still a null pointer. Oops, how could Apple implemented this method in this fucking way?

            // Workaround is do an unused invocation in the mainthread right after OpenAL is initialized successfully
            // as bellow.
            // ================ Workaround begin ================ //

            ALuint unusedAlBufferId = 0;
            alGenBuffers(1, &unusedAlBufferId);
            alDeleteBuffers(1, &unusedAlBufferId);

            // ================ Workaround end ================ //

            _scheduler = CC_CURRENT_ENGINE()->getScheduler();
            ret = true;
            ALOGI("OpenAL was initialized successfully!");
        }
    } while (false);

    return ret;
}

AudioCache *AudioEngineImpl::preload(const ccstd::string &filePath, std::function<void(bool)> callback) {
    AudioCache *audioCache = nullptr;

    auto it = _audioCaches.find(filePath);
    if (it == _audioCaches.end()) {
        audioCache = &_audioCaches[filePath];
        audioCache->_fileFullPath = FileUtils::getInstance()->fullPathForFilename(filePath);
        unsigned int cacheId = audioCache->_id;
        auto isCacheDestroyed = audioCache->_isDestroyed;
        AudioEngine::addTask([audioCache, cacheId, isCacheDestroyed]() {
            if (*isCacheDestroyed) {
                ALOGV("AudioCache (id=%u) was destroyed, no need to launch readDataTask.", cacheId);
                audioCache->setSkipReadDataTask(true);
                return;
            }
            audioCache->readDataTask(cacheId);
        });
    } else {
        audioCache = &it->second;
    }

    if (audioCache && callback) {
        audioCache->addLoadCallback(callback);
    }
    return audioCache;
}

int AudioEngineImpl::play2d(const ccstd::string &filePath, bool loop, float volume) {
    if (s_ALDevice == nullptr) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: play2d FAILED - s_ALDevice is null");
        return AudioEngine::INVALID_AUDIO_ID;
    }

    // 检查OpenAL上下文是否有效
    {
#if CC_PLATFORM == CC_PLATFORM_IOS
        // 低频兜底：外部模块（广告SDK等）改过音频会话后会一直静音，这里每秒最多检查一次（健康时什么都不做）
        static double s_lastSessionCheckTime = 0;
        double nowTime = [[NSDate date] timeIntervalSince1970];
        if (nowTime - s_lastSessionCheckTime >= 1.0) {
            s_lastSessionCheckTime = nowTime;
            if (s_AudioEngineSessionHandler != nullptr) {
                [s_AudioEngineSessionHandler checkAndRestoreAudioSession:@"play2d"];
            }
        }
#endif
        ALCcontext *currentContext = alcGetCurrentContext();
        if (currentContext != s_ALContext) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: play2d WARNING - OpenAL context mismatch! current=%p, expected=%p", currentContext, s_ALContext);
#if CC_PLATFORM == CC_PLATFORM_IOS
            // 又要出声了：说明中断/广告等场景已经结束，这里做一次完整恢复（session + 上下文）
            if (s_AudioEngineSessionHandler != nullptr) {
                [s_AudioEngineSessionHandler restoreAudioSession:@"play2d"];
                currentContext = alcGetCurrentContext();
            }
#endif
            // 尝试恢复上下文
            if (currentContext != s_ALContext && !alcMakeContextCurrent(s_ALContext)) {
                ALOGE("[AUDIO_DEBUG] AudioEngine: play2d - Failed to restore OpenAL context");
#if CC_PLATFORM == CC_PLATFORM_IOS
                if (s_AudioEngineSessionHandler != nullptr) {
                    [s_AudioEngineSessionHandler rebuildAudioEngineIfNeeded:@"play2dContextFailed"];
                }
#endif
                return AudioEngine::INVALID_AUDIO_ID;
            }
            ALOGI("[AUDIO_DEBUG] AudioEngine: play2d - Successfully restored OpenAL context");
        }
    }

    ALuint alSource = findValidSource();
    if (alSource == AL_INVALID) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: play2d FAILED - no valid source available");
        return AudioEngine::INVALID_AUDIO_ID;
    }

    auto *player = ccnew AudioPlayer;
    if (player == nullptr) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: play2d FAILED - cannot create AudioPlayer");
        return AudioEngine::INVALID_AUDIO_ID;
    }
    
    ALOGI("[AUDIO_DEBUG] AudioEngine: play2d - file=%s, loop=%d, volume=%.2f, audioID=%d", filePath.c_str(), loop, volume, _currentAudioID);

    player->_alSource = alSource;
    player->_loop = loop;
    player->_volume = volume;

    auto audioCache = preload(filePath, nullptr);
    if (audioCache == nullptr) {
        delete player;
        return AudioEngine::INVALID_AUDIO_ID;
    }

    player->setCache(audioCache);
    _threadMutex.lock();
    _audioPlayers[_currentAudioID] = player;
    _threadMutex.unlock();

    audioCache->addPlayCallback(std::bind(&AudioEngineImpl::play2dImpl, this, audioCache, _currentAudioID));

    if (_lazyInitLoop) {
        _lazyInitLoop = false;
        if (auto sche = _scheduler.lock()) {
            sche->schedule(CC_CALLBACK_1(AudioEngineImpl::update, this), this, 0.05f, false, "AudioEngine");
        }
    }

    return _currentAudioID++;
}

void AudioEngineImpl::play2dImpl(AudioCache *cache, int audioID) {
    //Note: It may be in sub thread or main thread :(
    if (!*cache->_isDestroyed && cache->_state == AudioCache::State::READY) {
        _threadMutex.lock();
        auto playerIt = _audioPlayers.find(audioID);
        if (playerIt != _audioPlayers.end()) {
            // Trust it, or assert it out.
            bool res = playerIt->second->play2d();
            CC_ASSERT(res);
        }
        _threadMutex.unlock();
    } else {
        ALOGD("AudioEngineImpl::play2dImpl, cache was destroyed or not ready!");
        auto iter = _audioPlayers.find(audioID);
        if (iter != _audioPlayers.end()) {
            iter->second->_removeByAudioEngine = true;
        }
    }
}

ALuint AudioEngineImpl::findValidSource() {
    ALuint sourceId = AL_INVALID;
    if (!_unusedSourcesPool.empty()) {
        sourceId = _unusedSourcesPool.front();
        _unusedSourcesPool.pop_front();
    }

    return sourceId;
}

void AudioEngineImpl::setVolume(int audioID, float volume) {
    if (!checkAudioIdValid(audioID)) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: setVolume FAILED - invalid audioID=%d", audioID);
        return;
    }
    auto player = _audioPlayers[audioID];
    player->_volume = volume;

    if (player->_ready) {
        alSourcef(_audioPlayers[audioID]->_alSource, AL_GAIN, volume);

        auto error = alGetError();
        if (error != AL_NO_ERROR) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: setVolume FAILED - audio id=%d, volume=%.2f, error=%x", audioID, volume, error);
        } else {
            ALOGI("[AUDIO_DEBUG] AudioEngine: setVolume SUCCESS - audio id=%d, volume=%.2f", audioID, volume);
        }
    }
}

void AudioEngineImpl::setLoop(int audioID, bool loop) {
    if (!checkAudioIdValid(audioID)) {
        return;
    }
    auto player = _audioPlayers[audioID];

    if (player->_ready) {
        if (player->_streamingSource) {
            player->setLoop(loop);
        } else {
            if (loop) {
                alSourcei(player->_alSource, AL_LOOPING, AL_TRUE);
            } else {
                alSourcei(player->_alSource, AL_LOOPING, AL_FALSE);
            }

            auto error = alGetError();
            if (error != AL_NO_ERROR) {
                ALOGE("%s: audio id = %d, error = %x", __PRETTY_FUNCTION__, audioID, error);
            }
        }
    } else {
        player->_loop = loop;
    }
}

bool AudioEngineImpl::pause(int audioID) {
    if (!checkAudioIdValid(audioID)) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: pause FAILED - invalid audioID=%d", audioID);
        return false;
    }
    bool ret = true;
    alSourcePause(_audioPlayers[audioID]->_alSource);

    auto error = alGetError();
    if (error != AL_NO_ERROR) {
        ret = false;
        ALOGE("[AUDIO_DEBUG] AudioEngine: pause FAILED - audio id=%d, error=%x", audioID, error);
    } else {
        ALOGI("[AUDIO_DEBUG] AudioEngine: pause SUCCESS - audio id=%d", audioID);
    }

    return ret;
}

bool AudioEngineImpl::resume(int audioID) {
    if (!checkAudioIdValid(audioID)) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: resume FAILED - invalid audioID=%d", audioID);
        return false;
    }
    
    // 检查OpenAL上下文
    ALCcontext *currentContext = alcGetCurrentContext();
    if (currentContext != s_ALContext) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: resume WARNING - OpenAL context mismatch! Attempting to restore...");
        if (!alcMakeContextCurrent(s_ALContext)) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: resume FAILED - cannot restore OpenAL context");
            return false;
        }
        ALOGI("[AUDIO_DEBUG] AudioEngine: resume - OpenAL context restored");
    }
    
    bool ret = true;
    alSourcePlay(_audioPlayers[audioID]->_alSource);

    auto error = alGetError();
    if (error != AL_NO_ERROR) {
        ret = false;
        ALOGE("[AUDIO_DEBUG] AudioEngine: resume FAILED - audio id=%d, error=%x", audioID, error);
    } else {
        ALOGI("[AUDIO_DEBUG] AudioEngine: resume SUCCESS - audio id=%d", audioID);
    }

    return ret;
}

void AudioEngineImpl::stop(int audioID) {
    if (!checkAudioIdValid(audioID)) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: stop FAILED - invalid audioID=%d", audioID);
        return;
    }
    ALOGI("[AUDIO_DEBUG] AudioEngine: stop - audio id=%d", audioID);
    auto player = _audioPlayers[audioID];
    player->destroy();

    // Call 'update' method to cleanup immediately since the schedule may be cancelled without any notification.
    update(0.0f);
}

void AudioEngineImpl::stopAll() {
    ALOGI("[AUDIO_DEBUG] AudioEngine: stopAll - stopping %d audio(s)", (int)_audioPlayers.size());
    for (auto &&player : _audioPlayers) {
        player.second->destroy();
    }

    // Call 'update' method to cleanup immediately since the schedule may be cancelled without any notification.
    update(0.0f);
}

float AudioEngineImpl::getDuration(int audioID) {
    if (!checkAudioIdValid(audioID)) {
        return 0.0f;
    }
    auto player = _audioPlayers[audioID];
    if (player->_ready) {
        return player->_audioCache->_duration;
    } else {
        return AudioEngine::TIME_UNKNOWN;
    }
}

float AudioEngineImpl::getDurationFromFile(const ccstd::string &filePath) {
    auto it = _audioCaches.find(filePath);
    if (it == _audioCaches.end()) {
        this->preload(filePath, nullptr);
        return AudioEngine::TIME_UNKNOWN;
    }

    return it->second._duration;
}

float AudioEngineImpl::getCurrentTime(int audioID) {
    if (!checkAudioIdValid(audioID)) {
        return 0.0f;
    }
    float ret = 0.0f;
    auto player = _audioPlayers[audioID];
    if (player->_ready) {
        if (player->_streamingSource) {
            ret = player->getTime();
        } else {
            alGetSourcef(player->_alSource, AL_SEC_OFFSET, &ret);

            auto error = alGetError();
            if (error != AL_NO_ERROR) {
                ALOGE("%s, audio id:%d,error code:%x", __PRETTY_FUNCTION__, audioID, error);
            }
        }
    }

    return ret;
}

bool AudioEngineImpl::setCurrentTime(int audioID, float time) {
    if (!checkAudioIdValid(audioID)) {
        return false;
    }
    bool ret = false;
    auto player = _audioPlayers[audioID];

    do {
        if (!player->_ready) {
            std::lock_guard<std::mutex> lck(player->_play2dMutex);// To prevent the race condition
            player->_timeDirty = true;
            player->_currTime = time;
            break;
        }

        if (player->_streamingSource) {
            ret = player->setTime(time);
            break;
        } else {
            if (player->_audioCache->_framesRead != player->_audioCache->_totalFrames &&
                (time * player->_audioCache->_sampleRate) > player->_audioCache->_framesRead) {
                ALOGE("%s: audio id = %d", __PRETTY_FUNCTION__, audioID);
                break;
            }

            alSourcef(player->_alSource, AL_SEC_OFFSET, time);

            auto error = alGetError();
            if (error != AL_NO_ERROR) {
                ALOGE("%s: audio id = %d, error = %x", __PRETTY_FUNCTION__, audioID, error);
            }
            ret = true;
        }
    } while (0);

    return ret;
}

void AudioEngineImpl::setFinishCallback(int audioID, const std::function<void(int, const ccstd::string &)> &callback) {
    if (!checkAudioIdValid(audioID)) {
        return;
    }
    _audioPlayers[audioID]->_finishCallbak = callback;
}

void AudioEngineImpl::update(float dt) {
    ALint sourceState;
    int audioID;
    AudioPlayer *player;
    ALuint alSource;

    //    ALOGV("AudioPlayer count: %d", (int)_audioPlayers.size());

#if CC_PLATFORM == CC_PLATFORM_IOS
    // 有音频在播的时候每5秒兜底检查一次音频会话是否被外部模块（广告SDK等）改坏；
    // 正常情况下只做一次字符串比较，开销可忽略
    static float s_sessionCheckElapsed = 0.0f;
    s_sessionCheckElapsed += dt;
    if (s_sessionCheckElapsed >= 5.0f) {
        s_sessionCheckElapsed = 0.0f;
        if (s_AudioEngineSessionHandler != nullptr) {
            [s_AudioEngineSessionHandler checkAndRestoreAudioSession:@"update"];
        }
    }
#endif

    for (auto it = _audioPlayers.begin(); it != _audioPlayers.end();) {
        audioID = it->first;
        player = it->second;
        alSource = player->_alSource;
        alGetSourcei(alSource, AL_SOURCE_STATE, &sourceState);

        if (player->_removeByAudioEngine) {
            AudioEngine::remove(audioID);
            _threadMutex.lock();
            it = _audioPlayers.erase(it);
            _threadMutex.unlock();
            delete player;
            _unusedSourcesPool.push_back(alSource);
        } else if (player->_ready && sourceState == AL_STOPPED) {
            ccstd::string filePath;
            if (player->_finishCallbak) {
                auto &audioInfo = AudioEngine::sAudioIDInfoMap[audioID];
                filePath = *audioInfo.filePath;
            }

            AudioEngine::remove(audioID);
            _threadMutex.lock();
            it = _audioPlayers.erase(it);
            _threadMutex.unlock();

            if (auto sche = _scheduler.lock()) {
                if (player->_finishCallbak) {
                    auto cb = player->_finishCallbak;
                    sche->performFunctionInCocosThread([audioID, cb, filePath]() {
                        cb(audioID, filePath); //IDEA: callback will delay 50ms
                    });
                }
            }

            delete player;
            _unusedSourcesPool.push_back(alSource);
        } else {
            ++it;
        }
    }

    if (_audioPlayers.empty()) {
        _lazyInitLoop = true;
        if (auto sche = _scheduler.lock()) {
            sche->unschedule("AudioEngine", this);
        }
    }
}

void AudioEngineImpl::uncache(const ccstd::string &filePath) {
    _audioCaches.erase(filePath);
}

void AudioEngineImpl::uncacheAll() {
    _audioCaches.clear();
}

bool AudioEngineImpl::checkAudioIdValid(int audioID) {
    return _audioPlayers.find(audioID) != _audioPlayers.end();
}

PCMHeader AudioEngineImpl::getPCMHeader(const char *url){
    PCMHeader header {};
    auto itr = _audioCaches.find(url);
    if (itr != _audioCaches.end() && itr->second._state == AudioCache::State::READY) {
        CC_LOG_DEBUG("file %s found in cache, load header directly", url);
        auto cache = &itr->second;
        header.bytesPerFrame = cache->_bytesPerFrame;
        header.channelCount = cache->_channelCount;
        header.dataFormat = AudioDataFormat::SIGNED_16;
        header.sampleRate = cache->_sampleRate;
        header.totalFrames = cache->_totalFrames;
        return header;
    }
    ccstd::string fileFullPath = FileUtils::getInstance()->fullPathForFilename(url);
        if (fileFullPath == "") {
            CC_LOG_DEBUG("file %s does not exist or failed to load", url);
            return header;
        }
    AudioDecoder decoder;
    do {
        if (!decoder.open(fileFullPath.c_str())) {
            CC_LOG_ERROR("[Audio Decoder] File open failed %s", url);
            break;
        }
        header.bytesPerFrame = decoder.getBytesPerFrame();
        header.channelCount = decoder.getChannelCount();
        header.dataFormat = AudioDataFormat::SIGNED_16;
        header.sampleRate = decoder.getSampleRate();
        header.totalFrames = decoder.getTotalFrames();
    } while (false);

    decoder.close();
    
    return header;
}

ccstd::vector<uint8_t> AudioEngineImpl::getOriginalPCMBuffer(const char *url, uint32_t channelID) {
    ccstd::vector<uint8_t> pcmData;
    auto itr = _audioCaches.find(url);
    if (itr != _audioCaches.end() && itr->second._state == AudioCache::State::READY) {
        auto cache = &itr->second;
        auto bytesPerChannelInFrame = cache->_bytesPerFrame / cache->_channelCount;
        pcmData.resize(bytesPerChannelInFrame * cache->_totalFrames);
        auto *p = pcmData.data();
        if (!cache->isStreaming()) { // Cache contains a fully prepared buffer.
            for (int itr = 0; itr < cache->_totalFrames; itr++) {
                memcpy(p, cache->_pcmData + itr * cache->_bytesPerFrame + channelID * bytesPerChannelInFrame, bytesPerChannelInFrame);
                p += bytesPerChannelInFrame;
            }
            return pcmData;
        }
    }
    ccstd::string fileFullPath = FileUtils::getInstance()->fullPathForFilename(url);
    if (fileFullPath.empty()) {
        CC_LOG_DEBUG("file %s does not exist or failed to load", url);
        return pcmData;
    }
    AudioDecoder decoder;

    do {
        if (!decoder.open(fileFullPath.c_str())) {
            CC_LOG_ERROR("[Audio Decoder] File open failed %s", url);
            break;
        }
        const uint32_t bytesPerFrame = decoder.getBytesPerFrame();
        const uint32_t channelCount = decoder.getChannelCount();
        if (channelID >= channelCount) {
            CC_LOG_ERROR("channelID invalid, total channel count is %d but %d is required", channelCount, channelID);
            break;
        }
        uint32_t totalFrames = decoder.getTotalFrames();
        uint32_t remainingFrames = totalFrames;
        uint32_t framesRead = 0;
        uint32_t framesToReadOnce = std::min(totalFrames, static_cast<uint32_t>(decoder.getSampleRate() * QUEUEBUFFER_TIME_STEP * QUEUEBUFFER_NUM));
        const uint32_t bytesPerChannelInFrame = bytesPerFrame / channelCount;
                
        pcmData.resize(bytesPerChannelInFrame * totalFrames);
        uint8_t *p = pcmData.data();
        
        auto tmpBuf = static_cast<char *>(malloc(framesToReadOnce * bytesPerFrame));
        
        while (remainingFrames > 0) {
            framesToReadOnce = std::min(framesToReadOnce, remainingFrames);
            framesRead = decoder.read(framesToReadOnce, tmpBuf);
            for (int itr = 0; itr < framesToReadOnce; itr++) {
                memcpy(p, tmpBuf + itr * bytesPerFrame + channelID * bytesPerChannelInFrame, bytesPerChannelInFrame);
                p += bytesPerChannelInFrame;
            }
            remainingFrames -= framesToReadOnce;
            
        };
        free(tmpBuf);
        // Adjust total frames by setting position to the end of frames and try to read more data.
        // This is a workaround for https://github.com/cocos2d/cocos2d-x/issues/16938
        if (decoder.seek(totalFrames)) {
            tmpBuf = static_cast<char *>(malloc(bytesPerFrame * framesToReadOnce));
            do {
                framesRead = decoder.read(framesToReadOnce, tmpBuf); //read one by one to easy divide
                if (framesRead > 0) { // Adjust frames exist
                    // transfer char data to float data
                    for (int itr = 0; itr < framesRead; itr++) {
                        memcpy(p, tmpBuf + itr * bytesPerFrame + channelID * bytesPerChannelInFrame, bytesPerChannelInFrame);
                        p += bytesPerChannelInFrame;
                    }
                }
            } while (framesRead > 0);
            free(tmpBuf);
        }
        BREAK_IF_ERR_LOG(!decoder.seek(0), "AudioDecoder::seek(0) failed!");
    } while (false);
    decoder.close();
    return pcmData;
}

