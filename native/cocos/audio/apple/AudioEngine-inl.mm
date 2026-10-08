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
#include <mutex>
#include <atomic>
#include <cstdint>
#include <limits>
#if CC_PLATFORM == CC_PLATFORM_IOS
    #include "bindings/event/EventDispatcher.h"
    #include "bindings/jswrapper/SeApi.h"
#endif

using namespace cc;

static ALCdevice *s_ALDevice = nullptr;
static ALCcontext *s_ALContext = nullptr;
// 回调持有该锁期间实例不能析构；销毁 OpenAL sources 时不能持锁，避免等待内部回调造成死锁。
static std::mutex s_instanceMutex;
static AudioEngineImpl *s_instance = nullptr;

// JS 播放器可能比 native 实例活得久，重建后不能把旧 ID 分配给新的音效。
static std::atomic<uint64_t> s_nextAudioID{0};
static int bkNextAudioID() {
    auto next = s_nextAudioID.load(std::memory_order_relaxed);
    do {
        // 饱和后返回失败，不能溢出并复用旧 ID。
        if (next > static_cast<uint64_t>(std::numeric_limits<int>::max())) {
            return AudioEngine::INVALID_AUDIO_ID;
        }
    } while (!s_nextAudioID.compare_exchange_weak(next, next + 1, std::memory_order_relaxed));
    return static_cast<int>(next);
}

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
@class AudioEngineSessionHandler;
static AudioEngineSessionHandler *s_AudioEngineSessionHandler = nil;
// 初始化暂时失败时保留观察者和重建需求；显式 end()/成功初始化会释放此持有。
static AudioEngineSessionHandler *s_failedRebuildHandler = nil;
static bool s_rebuildingAudioEngine = false;

// 内部恢复合同：通知由游戏主线程发出，VM 尚未初始化/已经结束时不进入 JS。
static void bkNotifyAudioJS(const char *event) {
    if (EventDispatcher::initialized()) {
        EventDispatcher::doDispatchJsEvent(event, se::EmptyValueArray);
    }
}

enum class BKAudioRestoreResult {
    Ready,
    SessionUnavailable,
    ContextUnavailable,
};

@interface AudioEngineSessionHandler : NSObject {
}

@property (nonatomic, assign) Boolean needReactiveContext;
/** 避免重复排队重建音频引擎 */
@property (nonatomic, assign) Boolean rebuildScheduled;
/**
 广告正在展示中（由 PlatMgr 在所有广告回调的公共出口广播的 BKAudioAdStateChanged 维护）。
 只用来"暂时不抢音频会话"：广告期间 SDK 会自己接管 session，这时去改它会互相打架；
 广告结束会恢复。注意它不会让游戏静音，最坏情况只是这段时间不做兜底修复。
 */
@property (nonatomic, assign) Boolean adShowing;
/** 本次广告开始的时间戳，用于兜底：广告结束回调没来时的超时恢复 */
@property (nonatomic, assign) NSTimeInterval adStartTime;
/** 恢复任务和广告超时分别编号，后台切换不会丢失广告的超时兜底。 */
@property (nonatomic, assign) NSUInteger restoreGeneration;
@property (nonatomic, assign) NSUInteger adGeneration;
@property (nonatomic, assign) Boolean interrupted;
/** 媒体重置/上下文损坏时保留重建请求，待会话可用后再执行。 */
@property (nonatomic, assign) Boolean needRebuild;
/** 激活会话失败与上下文损坏分别处理；失败时新播放不能假装成功。 */
@property (nonatomic, assign) Boolean sessionUnavailable;
@property (nonatomic, assign) NSUInteger rebuildRetryCount;

- (id)init;
- (void)handleInterruption:(NSNotification *)notification;
- (void)resumeAudio:(NSNotification *)notification;
- (void)reactiveAudio;
- (void)handleVoiceRecordWillStart:(NSNotification *)notification;
- (void)handleVoiceRecordDidFinish:(NSNotification *)notification;
- (void)handleAdState:(NSNotification *)notification;
- (void)handleMediaServicesWereReset:(NSNotification *)notification;
- (void)handleRouteChange:(NSNotification *)notification;
- (void)handleAppInactive:(NSNotification *)notification;
- (BOOL)handleOnMainThread:(SEL)selector object:(id)object;
- (BOOL)canRestoreAudioSession;
- (void)restoreAudioSession:(NSString *)reason;
- (void)checkAndRestoreAudioSession:(NSString *)reason;
- (void)scheduleRestoreAudioSession:(NSString *)reason;
- (void)rebuildAudioEngine:(NSString *)reason;
- (void)rebuildAudioEngineIfNeeded:(NSString *)reason;

@end

/** 广告播完后仍收不到结束通知时的兜底恢复时间（秒），只做恢复、不做挂起 */
static const NSTimeInterval BK_AD_SHOWING_SAFETY_TIMEOUT = 120.0;

/**
 录音/录音回放相关的类别：录音模块录制时用 PlayAndRecord，这类会话不能改成 Ambient（会让录音失效）。
 用"读会话状态"判断而不是靠通知标记，是因为录音模块是先切会话、再异步发通知，
 中间有空窗期，靠通知判断会误伤录音。
 */
static bool bkCategoryIsForRecording(NSString *category) {
    return [category isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
           [category isEqualToString:AVAudioSessionCategoryRecord];
}

/**
 把 OpenAL 上下文"摘掉再挂回"，强制重绑。

 为什么必须显式重绑（这是"看完广告没声音"的正式修复）：
   `alcGetCurrentContext() == s_ALContext` 只说明**上下文还挂着**，**不代表底层 AudioUnit 还在渲染**。
   广告 SDK 抢走 AVAudioSession 时 iOS 会停掉 AudioUnit；会话恢复后 Apple 的 OpenAL 不一定会
   把它重新启动 —— 此时所有 AL 调用都返回成功、source 状态是 AL_PLAYING，但采样偏移永远停在 0
   （线上 26.7.1 实测：激励视频结束后大厅/老虎机全部音效都命中 play2dImpl 的 "STALLED"，
   而日志里 AudioRestore(adClose) 明确写着 "OpenAL context is current"；
   切后台再回前台能恢复，走的正是 resume() 里那条"上下文不匹配 → alcMakeContextCurrent"的路径）。
   所以这里无论是否 current 都重绑一次，让 OpenAL 重新启动 AudioUnit。
 */
static bool bkRebindOpenALContext(const char *reason) {
    if (s_ALDevice == nullptr || s_ALContext == nullptr) {
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] Rebind(%s): skip, OpenAL is not initialized", reason);
        return false;
    }
    // 先摘掉再挂回：只有"先摘"才能让 OpenAL 真正重新绑定（对已经正常的场景无害）
    alcMakeContextCurrent(nullptr);
    if (alcMakeContextCurrent(s_ALContext)) {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] Rebind(%s): OpenAL context re-bound (restart AudioUnit)", reason);
        return true;
    }
    ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] Rebind(%s): alcMakeContextCurrent FAILED", reason);
    return false;
}

/**
 "硬重启"音频 I/O：把 AVAudioSession 先停掉再打开，然后重绑 OpenAL 上下文。

 为什么需要（线上实测）：广告 SDK 抢走 AVAudioSession 后 iOS 会停掉底层 AudioUnit。
 只重绑 OpenAL 上下文能救回多数情况，但仍会出现"AU 一个采样都不渲染"的状态
 （源 0.4 秒后还是 offset 0 且已 STOPPED）—— 此时必须让 iOS 真正重新建立音频 I/O 才能恢复。
 用户手动"切后台再回前台"之所以总能恢复，正是因为 iOS 在那一步做了同样的 stop + start I/O。

 注意：setActive:NO 会打断其它 App / 广告正在播放的声音，所以
   ①只在"确知没有在渲染"（STALLED 检测）时调用；
   ②广告展示期间不调用（此时会话本来就该归 SDK）。
 */
static bool bkHardRestartAudioIO(const char *reason) {
    if (s_AudioEngineSessionHandler != nil && s_AudioEngineSessionHandler.adShowing) {
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] HardRestart(%s): skipped, ad is showing", reason);
        return false;
    }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    BOOL deactivated = [session setActive:NO error:&error];
    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] HardRestart(%s): setActive NO success=%d, error=%s",
          reason, (int)deactivated, error ? error.description.UTF8String : "nil");
    error = nil;
    BOOL activated = [session setActive:YES error:&error];
    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] HardRestart(%s): setActive YES success=%d, error=%s",
          reason, (int)activated, error ? error.description.UTF8String : "nil");
    bool rebound = bkRebindOpenALContext(reason);
    return activated && rebound;
}

/**
 把 AVAudioSession 拉回游戏期望的状态，并把 OpenAL 上下文重新挂上。
 广告SDK/录音等模块切走 session 后往往不会还原，这里统一做修复。
 只依赖文件级静态变量，所以音频引擎重建之后也能直接调用。
 会话激活失败保留恢复需求；只有 OpenAL 上下文不可用才需要重建 device/context。
 */
static BKAudioRestoreResult bkRestoreAudioSession(const char *reason) {
    if (s_ALDevice == nullptr || s_ALContext == nullptr) {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRestore(%s): skip, OpenAL is not initialized", reason);
        // 引擎尚未初始化（甚至还没被使用过）时不需要重建
        return BKAudioRestoreResult::Ready;
    }

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;

    // 1. 广告SDK常把 category 改成 Playback 且不还原，统一拉回 Ambient；
    //    但录音相关类别不动（Ambient 没有录音能力，改它会把录音打断），
    //    这种情况下只做激活和上下文重挂，类别收尾交给录音模块自己
    NSString *categoryBefore = audioSession.category;
    if (bkCategoryIsForRecording(categoryBefore)) {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRestore(%s): category \"%s\" is for recording, keep it and only reactivate",
              reason, categoryBefore.UTF8String);
    } else if (![categoryBefore isEqualToString:AVAudioSessionCategoryAmbient]) {
        error = nil;
        BOOL success = [audioSession setCategory:AVAudioSessionCategoryAmbient error:&error];
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRestore(%s): category \"%s\" -> Ambient, success=%d, error=%s",
              reason, categoryBefore.UTF8String, (int)success, error ? error.description.UTF8String : "nil");
        if (!success) return BKAudioRestoreResult::SessionUnavailable;
    }

    // 2. 广告SDK关闭时可能把 session 置为 inactive，不重新激活的话 OpenAL 就再也没有输出了
    error = nil;
    BOOL active = [audioSession setActive:YES error:&error];
    // outputVolume 一并打出来：万一是广告SDK把系统音量改成了0（有些SDK为了强推广告音量会这么干），
    // 这行日志能直接看出来，避免继续在会话/上下文上排查
    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRestore(%s): setActive YES, success=%d, error=%s, category=%s, outputVolume=%.2f, otherAudioPlaying=%d",
          reason, (int)active, error ? error.description.UTF8String : "nil",
          audioSession.category.UTF8String, audioSession.outputVolume, (int)audioSession.isOtherAudioPlaying);
    if (!active) return BKAudioRestoreResult::SessionUnavailable;

    // 3. 重新挂上 OpenAL 上下文，并**强制重绑一次**。
    //    "上下文已经是 current"并不等于设备还在渲染（详见 bkRebindOpenALContext 的说明）：
    //    广告结束后 AudioUnit 可能已被 iOS 停掉，而上下文还挂着 —— 只判断 current 就会漏掉这个状态，
    //    结果所有 AL 调用都成功但永远不出声。所以这里不再提前 return，统一走重绑。
    if (alcGetCurrentContext() == s_ALContext) {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRestore(%s): OpenAL context is current, rebind anyway to restart AudioUnit", reason);
    } else {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRestore(%s): OpenAL context mismatch, re-binding", reason);
    }
    if (!bkRebindOpenALContext(reason)) {
        return BKAudioRestoreResult::ContextUnavailable;
    }
    return BKAudioRestoreResult::Ready;
}

@implementation AudioEngineSessionHandler

// 通知可能从 SDK/系统的工作线程发出；所有会话状态和排队任务统一在主线程处理。
- (BOOL)handleOnMainThread:(SEL)selector object:(id)object {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:selector withObject:object];
        });
        return NO;
    }
    // dispatch block 会延长旧 handler 的生命，但不能让它操作重建后的引擎。
    return self == s_AudioEngineSessionHandler;
}

- (BOOL)canRestoreAudioSession {
    return [NSThread isMainThread] && self == s_AudioEngineSessionHandler &&
           [UIApplication sharedApplication].applicationState == UIApplicationStateActive &&
           !self.adShowing && !self.interrupted &&
           !bkCategoryIsForRecording([AVAudioSession sharedInstance].category);
}


- (id)init {
    if (self = [super init]) {
        self.needReactiveContext = true;
        self.rebuildScheduled = false;
        self.adShowing = false;
        self.adStartTime = 0;
        self.restoreGeneration = 0;
        self.adGeneration = 0;
        self.interrupted = false;
        self.needRebuild = false;
        self.sessionUnavailable = false;
        self.rebuildRetryCount = 0;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAudio:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAudio:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppInactive:) name:UIApplicationWillResignActiveNotification object:nil];

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
        
        // 初始化也不能打断录音或在后台主动改会话。
        if ([NSThread isMainThread] &&
            [UIApplication sharedApplication].applicationState == UIApplicationStateActive &&
            !bkCategoryIsForRecording([AVAudioSession sharedInstance].category)) {
            NSError *error = nil;
            BOOL success = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error];
            if (!success) {
                ALOGE("[AUDIO_DEBUG] AudioEngine: Fail to set audio session in init, error=%s", error ? error.description.UTF8String : "nil");
            }
        } else {
            self.needReactiveContext = true;
        }
    }
    return self;
}

- (void)restoreAudioSession:(NSString *)reason {
    if (![self handleOnMainThread:_cmd object:reason]) return;
    if (![self canRestoreAudioSession]) {
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] restore(%s) SKIPPED: mainThread=%d isHandler=%d appActive=%d adShowing=%d interrupted=%d recordingCategory=%d",
              reason.UTF8String, (int)[NSThread isMainThread], (int)(self == s_AudioEngineSessionHandler),
              (int)([UIApplication sharedApplication].applicationState == UIApplicationStateActive),
              (int)self.adShowing, (int)self.interrupted,
              (int)bkCategoryIsForRecording([AVAudioSession sharedInstance].category));
        self.needReactiveContext = true;
        return;
    }
    if (self.needRebuild) {
        [self rebuildAudioEngine:reason];
        return;
    }
    bool wasPending = self.needReactiveContext;
    auto result = bkRestoreAudioSession(reason.UTF8String);
    self.needReactiveContext = result != BKAudioRestoreResult::Ready;
    self.sessionUnavailable = result == BKAudioRestoreResult::SessionUnavailable;
    if (result == BKAudioRestoreResult::ContextUnavailable) {
        [self rebuildAudioEngine:@"contextRestoreFailed"];
    } else if (result == BKAudioRestoreResult::Ready && wasPending) {
        // 清除 pending 后再进入 JS，避免续播请求重入同一次恢复。
        bkNotifyAudioJS("onAudioSessionReady");
    }
}

- (void)checkAndRestoreAudioSession:(NSString *)reason {
    if (![self handleOnMainThread:_cmd object:reason]) return;
    if (![self canRestoreAudioSession]) return;
    // Ambient 也可能 inactive；后台/中断/被阻止的恢复留下的标记必须先处理。
    if (self.needReactiveContext || self.needRebuild ||
        ![[AVAudioSession sharedInstance].category isEqualToString:AVAudioSessionCategoryAmbient]) {
        [self restoreAudioSession:reason];
    }
}

- (void)scheduleRestoreAudioSession:(NSString *)reason {
    if (![self handleOnMainThread:_cmd object:reason]) return;
    NSUInteger generation = ++self.restoreGeneration;
    self.needReactiveContext = true;
    [self restoreAudioSession:reason];

    // SDK 可能在回调返回后才收尾。重试只属于本次恢复，不能越过下一次会话接管。
    NSTimeInterval delays[] = {0.2, 0.8, 2.0};
    for (int i = 0; i < 3; ++i) {
        NSTimeInterval delay = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self != s_AudioEngineSessionHandler || generation != self.restoreGeneration) return;
            [self restoreAudioSession:@"delayed"];
        });
    }
}

- (void)rebuildAudioEngineIfNeeded:(NSString *)reason {
    if (![self handleOnMainThread:_cmd object:reason]) return;
    self.needReactiveContext = true;
    NSUInteger generation = self.restoreGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self != s_AudioEngineSessionHandler || generation != self.restoreGeneration ||
            ![self canRestoreAudioSession] || s_ALDevice == nullptr || s_ALContext == nullptr) return;
        if (alcGetCurrentContext() == s_ALContext) return;
        [self rebuildAudioEngine:reason];
    });
}

- (void)rebuildAudioEngine:(NSString *)reason {
    if (![self handleOnMainThread:_cmd object:reason]) return;
    if (s_ALDevice == nullptr && s_ALContext == nullptr && !self.needRebuild) return;
    self.needRebuild = true;
    self.needReactiveContext = true;
    if (self.rebuildScheduled || ![self canRestoreAudioSession]) return;
    self.rebuildScheduled = true;
    if (![reason isEqualToString:@"initRetry"]) self.rebuildRetryCount = 0;
    NSUInteger generation = self.restoreGeneration;
    // end() 会释放当前 handler，必须离开通知栈再执行。
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rebuildScheduled = false;
        if (self != s_AudioEngineSessionHandler || generation != self.restoreGeneration ||
            ![self canRestoreAudioSession]) return;
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRebuild(%s): end() + lazyInit()", reason.UTF8String);
        bkNotifyAudioJS("onAudioEngineWillReset");
        // JS 中断事件可能同步打开广告/切后台，不能在重入后继续销毁会话。
        if (self != s_AudioEngineSessionHandler || generation != self.restoreGeneration ||
            ![self canRestoreAudioSession]) return;
        ++self.restoreGeneration;
        s_rebuildingAudioEngine = true;
        AudioEngine::end();
        bool success = AudioEngine::lazyInit();
        s_rebuildingAudioEngine = false;
        if (success) {
            // 使用新 handler 的保护条件，不能绕过广告/后台/录音的检查。
            [s_AudioEngineSessionHandler scheduleRestoreAudioSession:@"rebuildDone"];
        } else {
            // lazyInit() 的失败析构会删除新 handler；继续用旧观察者等待可恢复机会。
            s_failedRebuildHandler = [self retain];
            s_AudioEngineSessionHandler = self;
            if (++self.rebuildRetryCount <= 3) {
                NSUInteger retryGeneration = self.restoreGeneration;
                NSTimeInterval delay = 0.5 * self.rebuildRetryCount;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (self != s_AudioEngineSessionHandler || retryGeneration != self.restoreGeneration ||
                        ![self canRestoreAudioSession]) return;
                    [self rebuildAudioEngine:@"initRetry"];
                });
            }
        }
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] AudioRebuild: result=%d, previous players dropped", (int)success);
    });
}

- (void)reactiveAudio {
    if (self.needReactiveContext) {
        ALOGI("[AUDIO_DEBUG] AudioRestore: reactiveAudio, needReactiveContext was set");
        [self restoreAudioSession:@"reactive"];
    }
}

- (void)resumeAudio:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] resumeAudio: name=%s appState=%ld interrupted=%d adShowing=%d needReactive=%d needRebuild=%d category=%s",
          notification.name.UTF8String, (long)[UIApplication sharedApplication].applicationState, (int)self.interrupted,
          (int)self.adShowing, (int)self.needReactiveContext, (int)self.needRebuild,
          [AVAudioSession sharedInstance].category.UTF8String);
    // 系统不保证每次 Began 都有 Ended。真正回到 active 前台也是一次恢复机会。
    if ([notification.name isEqualToString:UIApplicationDidBecomeActiveNotification] &&
        [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        self.interrupted = false;
    }
    if ([self canRestoreAudioSession] && (self.needReactiveContext || self.needRebuild ||
        ![[AVAudioSession sharedInstance].category isEqualToString:AVAudioSessionCategoryAmbient])) {
        [self scheduleRestoreAudioSession:@"appActive"];
    }
}

- (void)handleAppInactive:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] handleAppInactive: appState=%ld adShowing=%d",
          (long)[UIApplication sharedApplication].applicationState, (int)self.adShowing);
    ++self.restoreGeneration;
    self.needReactiveContext = true;
    bkNotifyAudioJS("onAudioSessionSuspended");
}

- (void)handleInterruption:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    NSInteger reason = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] integerValue];
    if (reason == AVAudioSessionInterruptionTypeBegan) {
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] interruption BEGAN");
        ++self.restoreGeneration;
        self.interrupted = true;
        self.needReactiveContext = true;
        bkNotifyAudioJS("onAudioSessionSuspended");
        alcMakeContextCurrent(nullptr);
    } else if (reason == AVAudioSessionInterruptionTypeEnded) {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] interruption ENDED");
        self.interrupted = false;
        [self scheduleRestoreAudioSession:@"interruptionEnded"];
    }
}

- (void)handleVoiceRecordWillStart:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    ++self.restoreGeneration;
    self.needReactiveContext = true;
    // 录音模块先切 category 再发通知；恢复入口还会读取 category，覆盖通知前的空窗。
}

- (void)handleVoiceRecordDidFinish:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    [self scheduleRestoreAudioSession:@"recordDone"];
}

- (void)handleAdState:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    NSString *state = [[notification userInfo] objectForKey:@"state"];
    if ([state isEqualToString:@"start"]) {
        ++self.restoreGeneration;
        NSUInteger adGeneration = ++self.adGeneration;
        self.adShowing = true;
        bkNotifyAudioJS("onAudioSessionSuspended");
        self.adStartTime = [[NSDate date] timeIntervalSince1970];
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioAd: start, cancel previous recovery tasks");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BK_AD_SHOWING_SAFETY_TIMEOUT * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self != s_AudioEngineSessionHandler || adGeneration != self.adGeneration || !self.adShowing) return;
            ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] AudioAd: missing close callback after 120s");
            self.adShowing = false;
            self.adStartTime = 0;
            [self scheduleRestoreAudioSession:@"adNoCloseCallback"];
        });
    } else if ([state isEqualToString:@"close"]) {
        ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] AudioAd: close, restoring audio session");
        ++self.adGeneration;
        self.adShowing = false;
        self.adStartTime = 0;
        [self scheduleRestoreAudioSession:@"adClose"];
    }
}

- (void)handleMediaServicesWereReset:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] mediaServicesWereReset");
    ++self.restoreGeneration;
    self.interrupted = false;
    [self rebuildAudioEngine:@"mediaServicesReset"];
}

- (void)handleRouteChange:(NSNotification *)notification {
    if (![self handleOnMainThread:_cmd object:notification]) return;
    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] routeChange: category=%s",
          [AVAudioSession sharedInstance].category.UTF8String);
    [self checkAndRestoreAudioSession:@"routeChange"];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
@end

#endif

bool AudioEngineImpl::canInitialize() {
#if CC_PLATFORM == CC_PLATFORM_IOS
    return s_failedRebuildHandler == nil || [s_failedRebuildHandler canRestoreAudioSession];
#else
    return true;
#endif
}

void AudioEngineImpl::clearFailedRebuildHandler(bool cancelRecovery) {
#if CC_PLATFORM == CC_PLATFORM_IOS
    if (cancelRecovery && !s_rebuildingAudioEngine) bkNotifyAudioJS("onAudioEngineRecoveryCancelled");
    auto *handler = s_failedRebuildHandler;
    s_failedRebuildHandler = nil;
    if (s_AudioEngineSessionHandler == handler) s_AudioEngineSessionHandler = nil;
    [handler release];
#endif
}

ALvoid AudioEngineImpl::myAlSourceNotificationCallback(ALuint sid, ALuint notificationID, ALvoid *userData) {
    // Currently, we only care about AL_BUFFERS_PROCESSED event
    if (notificationID != AL_BUFFERS_PROCESSED)
        return;

    // OpenAL 内部线程可能与 end()/重建并发。持有实例锁直至最后一次成员访问，
    // 析构取得同一把锁后才断开实例引用，因此既不会检查后变空，也不会使用已析构的成员。
    std::lock_guard<std::mutex> instanceLock(s_instanceMutex);
    auto *instance = s_instance;
    if (instance == nullptr)
        return;

    std::lock_guard<std::mutex> playersLock(instance->_threadMutex);
    for (const auto &e : instance->_audioPlayers) {
        auto *player = e.second;
        if (player->_alSource == sid && player->_streamingSource) {
            player->wakeupRotateThread();
        }
    }
}

AudioEngineImpl::AudioEngineImpl()
: _lazyInitLoop(true) {
    std::lock_guard<std::mutex> instanceLock(s_instanceMutex);
    s_instance = this;
}

AudioEngineImpl::~AudioEngineImpl() {
    // 等待已进入的回调完成，再阻止新回调访问本实例。
    // 在任何 OpenAL 销毁调用之前释放实例锁，否则 OpenAL 等待回调时可能互相阻塞。
    {
        std::lock_guard<std::mutex> instanceLock(s_instanceMutex);
        if (s_instance == this) {
            s_instance = nullptr;
        }
    }

    if (auto sche = _scheduler.lock()) {
        sche->unschedule("AudioEngine", this);
    }

    if (s_ALContext) {
        alDeleteSources(MAX_AUDIOINSTANCES, _alSources);

        // AudioEngine::end() 已停止并 join 加载线程池，排队但尚未开始的任务会被丢弃。
        // 此时没有读取线程；标记跳过，避免缓存析构等待一个永远不会执行的任务。
        for (auto &entry : _audioCaches) {
            entry.second.setSkipReadDataTask(true);
        }
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
    auto *sessionHandler = s_AudioEngineSessionHandler;
    // 客户端播放/预加载也会调用 lazyInit；失败时仍保留旧观察者与恢复请求。
    s_AudioEngineSessionHandler = s_failedRebuildHandler;
    [sessionHandler release];
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

            // 引擎/应用可能已经处于销毁过程中：CC_CURRENT_ENGINE() 展开为
            // CC_CURRENT_APPLICATION_SAFE()->getEngine()，两次查找之间应用可能被释放，
            // 且 getEngine() 本身也可能返回空。这里用刚持有的 shared_ptr 串起来判空，
            // 避免把空的 _scheduler 留给后续回调使用。
            auto application = CC_CURRENT_APPLICATION_SAFE();
            if (application == nullptr) {
                ALOGI("AudioEngineImpl::init: no current application, abort OpenAL init.");
            } else {
                auto engine = application->getEngine();
                if (engine == nullptr) {
                    ALOGI("AudioEngineImpl::init: no current engine, abort OpenAL init.");
                } else {
                    _scheduler = engine->getScheduler();
                    ret = true;
                    ALOGI("OpenAL was initialized successfully!");
                }
            }
        }
    } while (false);

    // 只有成功初始化后才退休失败观察者；失败析构会把当前观察者切回它。
    if (ret) clearFailedRebuildHandler(false);
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
#if CC_PLATFORM == CC_PLATFORM_IOS
        // 新实例和已知待恢复状态不能被低频检查节流，成功客户端重试也必须通知 JS。
        if (s_AudioEngineSessionHandler.needReactiveContext || s_AudioEngineSessionHandler.needRebuild ||
            s_AudioEngineSessionHandler.sessionUnavailable) {
            [s_AudioEngineSessionHandler checkAndRestoreAudioSession:@"play2dPending"];
            if (s_AudioEngineSessionHandler.needRebuild || s_AudioEngineSessionHandler.sessionUnavailable) {
                return AudioEngine::INVALID_AUDIO_ID;
            }
        }
#endif
        ALCcontext *currentContext = alcGetCurrentContext();
        if (currentContext != s_ALContext) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: play2d WARNING - OpenAL context mismatch! current=%p, expected=%p", currentContext, s_ALContext);
#if CC_PLATFORM == CC_PLATFORM_IOS
            // 播放请求不代表广告/中断已经结束，不能借上下文兜底绕过会话保护。
            if (s_AudioEngineSessionHandler != nullptr) {
                if (![s_AudioEngineSessionHandler canRestoreAudioSession]) {
                    return AudioEngine::INVALID_AUDIO_ID;
                }
                [s_AudioEngineSessionHandler restoreAudioSession:@"play2d"];
                if (s_AudioEngineSessionHandler.needRebuild || s_AudioEngineSessionHandler.sessionUnavailable) {
                    return AudioEngine::INVALID_AUDIO_ID;
                }
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

    const int audioID = bkNextAudioID();
    if (audioID == AudioEngine::INVALID_AUDIO_ID) {
        return AudioEngine::INVALID_AUDIO_ID;
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
    
    ALOGI("[AUDIO_DEBUG] AudioEngine: play2d - file=%s, loop=%d, volume=%.2f, audioID=%d", filePath.c_str(), loop, volume, audioID);

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
    _audioPlayers[audioID] = player;
    _threadMutex.unlock();

    audioCache->addPlayCallback(std::bind(&AudioEngineImpl::play2dImpl, this, audioCache, audioID));

    if (_lazyInitLoop) {
        _lazyInitLoop = false;
        if (auto sche = _scheduler.lock()) {
            sche->schedule(CC_CALLBACK_1(AudioEngineImpl::update, this), this, 0.05f, false, "AudioEngine");
        }
    }

    return audioID;
}

void AudioEngineImpl::play2dImpl(AudioCache *cache, int audioID) {
    //Note: It may be in sub thread or main thread :(
    if (!*cache->_isDestroyed && cache->_state == AudioCache::State::READY) {
        _threadMutex.lock();
        auto playerIt = _audioPlayers.find(audioID);
        if (playerIt != _audioPlayers.end()) {
            // 不再用 CC_ASSERT(res)：它在 Release 被编掉、在 Debug 直接 abort，
            // 恰好把"播放其实失败/无声"这条路径藏起来。改为显式判断 + 打日志。
            bool res = playerIt->second->play2d();
            ALuint source = playerIt->second->_alSource;
            _threadMutex.unlock();

            if (res) {
                // 诊断：采样 AL_SAMPLE_OFFSET。广告 SDK 切走音频会话后，底层 AudioUnit 可能
                // 已停止渲染，但所有 AL 调用仍返回成功（"僵尸设备"）—— 此时状态是 PLAYING
                // 而偏移不前进。0.4 秒后再采一次即可直接判定。
                ALint state = 0;
                ALint offset = 0;
                ALint queued = 0;
                alGetSourcei(source, AL_SOURCE_STATE, &state);
                alGetSourcei(source, AL_SAMPLE_OFFSET, &offset);
                alGetSourcei(source, AL_BUFFERS_QUEUED, &queued);
                ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: audioID=%d source=%u state=%d offset=%d queued=%d alErr=0x%x",
                      audioID, source, state, offset, queued, alGetError());
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ALint state2 = 0;
                    ALint offset2 = 0;
                    alGetSourcei(source, AL_SOURCE_STATE, &state2);
                    alGetSourcei(source, AL_SAMPLE_OFFSET, &offset2);
                    if (state2 == AL_PLAYING && offset2 == offset) {
                        ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: STALLED! audioID=%d source=%u state=%d offset stuck at %d (device not rendering)",
                              audioID, source, state2, offset);
                        // 自愈兜底：偏移不动 = 底层 AudioUnit 没在渲染。重绑一次上下文让 OpenAL 重启它，
                        // 0.4 秒后再复查一次，把"是否真的救回来"写进日志（便于线上/测试直接判读）。
                        // 限频 5 秒：避免播放密集时反复重绑。
                        static NSTimeInterval s_lastStalledRecover = 0;
                        NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
                        if (nowTs - s_lastStalledRecover >= 5.0) {
                            s_lastStalledRecover = nowTs;
                            // 先试轻量的重绑；既然已经检测到"没在渲染"，直接上硬重启
                            // （setActive NO→YES + 重绑），等价于用户手动切后台再回前台的效果。
                            bkHardRestartAudioIO("stalled");
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                ALint state3 = 0;
                                ALint offset3 = 0;
                                alGetSourcei(source, AL_SOURCE_STATE, &state3);
                                alGetSourcei(source, AL_SAMPLE_OFFSET, &offset3);
                                if (state3 == AL_PLAYING && offset3 == offset) {
                                    ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: StalledRecover FAILED, still stuck at %d (audioID=%d)", offset3, audioID);
                                } else {
                                    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: StalledRecover OK, offset %d -> %d (audioID=%d)", offset, offset3, audioID);
                                }
                            });
                        }
                    } else {
                        // 正常推进用 D 级：避免每次播放都刷屏；只有异常（STALLED）才用 E 级。
                        ALOGD("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: progress ok audioID=%d source=%u state=%d offset %d -> %d",
                              audioID, source, state2, offset, offset2);
                        // 另一种更隐蔽的"僵尸设备"：流式（BGM 这类长音频）源在 0.4 秒内
                        // **一个采样都没渲染**就直接变成 STOPPED（偏移仍是 0）。
                        // 这种情况下流式补数据线程也不会再工作（它只在 PLAYING/PAUSED 时补），
                        // 表现为"BGM 只播个开头就再也没声，直到退出场景重进"。
                        // 判据加 duration > 1s，避免把"本来就播完了的短流式音频"误判成异常。
                        const bool longStreaming = (cache != nullptr) && cache->isStreaming() && cache->_duration > 1.0f;
                        if (state2 == AL_STOPPED && offset2 == offset && longStreaming) {
                            ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: stream source stopped without rendering any sample! audioID=%d offset=%d duration=%.2f (audio unit not running?)",
                                  audioID, offset2, cache->_duration);
                            static NSTimeInterval s_lastNoRenderRecover = 0;
                            NSTimeInterval nowNoRender = [[NSDate date] timeIntervalSince1970];
                            if (nowNoRender - s_lastNoRenderRecover >= 5.0) {
                                s_lastNoRenderRecover = nowNoRender;
                                bkHardRestartAudioIO("noRender");
                            }
                        }
                    }
                });
            } else {
                ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: AudioPlayer::play2d FAILED audioID=%d (no sound)", audioID);
            }
            return;
        }
        _threadMutex.unlock();
    } else {
        ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] play2dImpl: cache NOT READY (destroyed=%d state=%d) audioID=%d",
              (int)*cache->_isDestroyed, (int)cache->_state, audioID);
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
    ALuint source = _audioPlayers[audioID]->_alSource;
    ALint offsetBefore = 0;
    alGetSourcei(source, AL_SAMPLE_OFFSET, &offsetBefore);
    alSourcePlay(source);

    auto error = alGetError();
    if (error != AL_NO_ERROR) {
        ret = false;
        ALOGE("[AUDIO_DEBUG] AudioEngine: resume FAILED - audio id=%d, error=%x", audioID, error);
    } else {
        ALOGI("[AUDIO_DEBUG] AudioEngine: resume SUCCESS - audio id=%d", audioID);
    }

    // 【实证驱动的复查】resume 报成功 ≠ 真的在出声。2026-10-08 真机日志（广告后 BGM 无声、
    // 切后台回来才有声）里能直接看到这条路径的两个坑：
    //   ① resume 之后**还会发生多次会话恢复 + 上下文重绑**（2026-10-08 日志：
    //      resume SUCCESS - audio id=247 之后紧跟 3 次 AudioRestore(delayed) + Rebind(delayed)），
    //      而重绑（alcMakeContextCurrent(nullptr) 再挂回）本身会把所有源停掉；
    //   ② 底层 AudioUnit 没在拉数据时，AL 调用仍然全部成功、源状态也报 PLAYING（"僵尸设备"）。
    // 两者都表现为"AL 说成功、用户没声音"，而原来只有 play2dImpl 有 0.4 秒复查，resume 这条
    // 路径完全没有探针 —— 所以"广告后 BGM 无声"一直无法从日志判定。
    // 这里补上同样的 0.4 秒复查：偏移推进 = 真的在渲染；STOPPED = 被重绑停掉了（流式循环源由
    // rotateBufferThread 的自愈重播）；PLAYING 但偏移不动 = 僵尸设备 → 复用已有的硬重启自愈。
    if (ret) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            (void)alGetError(); // 清掉可能残留的 AL 错误态，避免污染别处对 alGetError() 的判读
            ALint state2 = 0;
            ALint offset2 = 0;
            ALint queued2 = 0;
            alGetSourcei(source, AL_SOURCE_STATE, &state2);
            alGetSourcei(source, AL_SAMPLE_OFFSET, &offset2);
            alGetSourcei(source, AL_BUFFERS_QUEUED, &queued2);
            if (state2 == AL_STOPPED) {
                ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] resume: source STOPPED after resume audioID=%d source=%u offset=%d (context rebind stopped it? streaming loop self-heals)",
                      audioID, source, offset2);
            } else if (state2 == AL_PLAYING && queued2 > 0 && offset2 == offsetBefore) {
                ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] resume: STALLED! audioID=%d source=%u state=%d offset stuck at %d (device not rendering)",
                      audioID, source, state2, offset2);
                static NSTimeInterval s_lastResumeStalled = 0;
                NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
                if (nowTs - s_lastResumeStalled >= 5.0) {
                    s_lastResumeStalled = nowTs;
                    bkHardRestartAudioIO("resumeStalled");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        ALint state3 = 0;
                        ALint offset3 = 0;
                        alGetSourcei(source, AL_SOURCE_STATE, &state3);
                        alGetSourcei(source, AL_SAMPLE_OFFSET, &offset3);
                        if (state3 == AL_PLAYING && offset3 == offsetBefore) {
                            ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] resume: StalledRecover FAILED, still stuck at %d (audioID=%d)", offset3, audioID);
                        } else {
                            ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] resume: StalledRecover OK, offset %d -> %d (audioID=%d)", offsetBefore, offset3, audioID);
                        }
                    });
                }
            } else {
                // 正常推进用 D 级，避免每次 resume 都刷屏。
                // 注意这里也覆盖"队列空却在 PLAYING"的情况（queued2==0 且偏移不动）——
                // 那种源本来就没有数据可放，不是设备问题，所以不触发硬重启。
                ALOGD("[AUDIO_DEBUG][BKAUDIOTRACE] resume: progress ok audioID=%d source=%u state=%d queued=%d offset %d -> %d",
                      audioID, source, state2, queued2, offsetBefore, offset2);
            }
            (void)alGetError();
        });
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

#if CC_PLATFORM == CC_PLATFORM_IOS
        // 【僵尸设备自愈】补数据线程判定"源在 PLAYING、队列里有数据、却连续 2 秒零消费"
        // （2026-10-08 真机日志：广告回来 resume 后 state=4114 queued=4 processed=0，
        //  短音效播放结束时 offset 停在 0，而广告前是跑满 → 底层 AudioUnit 没在拉数据）。
        // 这里做主线程侧的动作：硬重启音频 I/O（setActive NO→YES + 重绑），
        // 也就是"切后台再回来"那套、实测能恢复的操作；旋转线程的自愈会把循环源重新拉起来。
        // 限制：①广告展示期间不做（bkHardRestartAudioIO 自己也会跳过）；
        //      ②只有 App 在前台才做（后台时 iOS 本来就挂起 AudioUnit，硬重启既无效又可能报错）；
        //      ③5 秒一次、最多 5 次，避免反复打断其它声音。
        if (player->_deviceNotRendering.exchange(false)) {
            static double s_lastNoProcessCheck = 0;
            static int s_noProcessRestartCount = 0;
            NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
            // 5 秒节流放在最外层：补数据线程每 25ms 就会把标志置真一次，这里必须限流，
            // 否则"已放弃"之类的日志会每 50ms 刷一条（自审抓到的坑）。
            if (nowTs - s_lastNoProcessCheck >= 5.0) {
                s_lastNoProcessCheck = nowTs;
                bool appActive = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
                if (!appActive) {
                    ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] update: audioID=%d device-not-rendering but app is not active, skip hard restart", audioID);
                } else if (s_noProcessRestartCount >= 5) {
                    ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] update: audioID=%d device-not-rendering, already restarted %d times, suppress further attempts",
                          audioID, s_noProcessRestartCount);
                } else {
                    ++s_noProcessRestartCount;
                    ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] update: audioID=%d source=%u device not rendering (playing with queued buffers but none processed) -> hard restart audio I/O (attempt %d)",
                          audioID, alSource, s_noProcessRestartCount);
                    bkHardRestartAudioIO("noProcess");
                }
            }
        }
#endif

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

