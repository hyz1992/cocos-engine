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

- (id)init;
- (void)handleInterruption:(NSNotification *)notification;
- (void)resumeAudio:(NSNotification *)notification;
- (void)reactiveAudio;
- (void)handleVoiceRecordWillStart:(NSNotification *)notification;
- (void)handleVoiceRecordDidFinish:(NSNotification *)notification;

@end

@implementation AudioEngineSessionHandler


- (id)init {
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAudio:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resumeAudio:) name:UIApplicationWillEnterForegroundNotification object:nil];
        
        // 监听录音模块的通知
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleVoiceRecordWillStart:) name:@"VoiceRecordWillStartRecording" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleVoiceRecordDidFinish:) name:@"VoiceRecordDidFinishRecording" object:nil];
        
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

- (void)reactiveAudio {
    if (self.needReactiveContext) {
        self.needReactiveContext = false;
        ALOGI("[AUDIO_DEBUG] AudioEngine: reactiveAudio - attempting to restore audio context");
        
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        NSError *error = nil;
        
        ALOGI("[AUDIO_DEBUG] AudioEngine: Current audio session category=%s, isOtherAudioPlaying=%d", 
              audioSession.category.UTF8String, audioSession.isOtherAudioPlaying);
        
        BOOL success = [audioSession setCategory:AVAudioSessionCategoryAmbient error:&error];
        if (!success) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: Fail to set audio session, error=%s", error ? error.description.UTF8String : "nil");
            return;
        }
        ALOGI("[AUDIO_DEBUG] AudioEngine: setCategory SUCCESS");
        
        [audioSession setActive:YES error:&error];
        if (error) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: setActive FAILED, error=%s", error.description.UTF8String);
        } else {
            ALOGI("[AUDIO_DEBUG] AudioEngine: setActive SUCCESS");
        }
        
        if (!alcMakeContextCurrent(s_ALContext)) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: alcMakeContextCurrent FAILED - audio context is invalid, need to recreate!");
        } else {
            ALOGI("[AUDIO_DEBUG] AudioEngine: alcMakeContextCurrent SUCCESS - OpenAL context restored");
        }
    }
}

- (void)resumeAudio:(NSNotification *)notification {
    [self reactiveAudio];
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
}

- (void)handleVoiceRecordDidFinish:(NSNotification *)notification {
    ALOGI("[AUDIO_DEBUG] AudioEngine: VoiceRecord did finish - game audio volume will auto restore to 100%%");
    
    // 录音结束，执行保险措施：确保 OpenAL 上下文正常
    // 注意：使用 DuckOthers 方案，音频会话切换时音量会自动恢复，这里是额外保险
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        NSError *error = nil;
        
        ALOGI("[AUDIO_DEBUG] AudioEngine: [Insurance] Checking audio session after recording, current category=%s", audioSession.category.UTF8String);
        
        // 确保音频会话类别正确（VoiceRecord 应该已经设置好了）
        BOOL success = [audioSession setCategory:AVAudioSessionCategoryAmbient error:&error];
        if (!success) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: [Insurance] setCategory FAILED, error=%s", error ? error.description.UTF8String : "nil");
        } else {
            ALOGI("[AUDIO_DEBUG] AudioEngine: [Insurance] setCategory confirmed");
        }
        
        [audioSession setActive:YES error:&error];
        if (error) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: [Insurance] setActive FAILED, error=%s", error.description.UTF8String);
        } else {
            ALOGI("[AUDIO_DEBUG] AudioEngine: [Insurance] setActive confirmed");
        }
        
        // 【保险措施】重新激活 OpenAL 上下文，防止上下文失效导致静音
        if (s_ALContext) {
            ALCcontext *currentContext = alcGetCurrentContext();
            if (currentContext != s_ALContext) {
                ALOGE("[AUDIO_DEBUG] AudioEngine: [Insurance] OpenAL context mismatch detected! Restoring...");
            }
            
            if (!alcMakeContextCurrent(s_ALContext)) {
                ALOGE("[AUDIO_DEBUG] AudioEngine: [Insurance] alcMakeContextCurrent FAILED!");
                
                // 尝试检查OpenAL错误
                ALenum alcError = alcGetError(s_ALDevice);
                ALOGE("[AUDIO_DEBUG] AudioEngine: [Insurance] ALC Error code: %d", alcError);
            } else {
                ALOGI("[AUDIO_DEBUG] AudioEngine: [Insurance] alcMakeContextCurrent SUCCESS - OpenAL context verified");
                
                // 验证 OpenAL 状态
                ALCint contextState;
                alcGetIntegerv(s_ALDevice, ALC_SYNC, 1, &contextState);
                ALOGI("[AUDIO_DEBUG] AudioEngine: [Insurance] OpenAL context state=%d", contextState);
            }
        }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"VoiceRecordWillStartRecording" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"VoiceRecordDidFinishRecording" object:nil];

    [super dealloc];
}
@end

static id s_AudioEngineSessionHandler = nullptr;
#endif

ALvoid AudioEngineImpl::myAlSourceNotificationCallback(ALuint sid, ALuint notificationID, ALvoid *userData) {
    // Currently, we only care about AL_BUFFERS_PROCESSED event
    if (notificationID != AL_BUFFERS_PROCESSED)
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
    if (auto sche = _scheduler.lock()) {
        sche->unschedule("AudioEngine", this);
    }

    if (s_ALContext) {
        alDeleteSources(MAX_AUDIOINSTANCES, _alSources);

        _audioCaches.clear();

        alcMakeContextCurrent(nullptr);
        alcDestroyContext(s_ALContext);
    }
    if (s_ALDevice) {
        alcCloseDevice(s_ALDevice);
    }

#if CC_PLATFORM == CC_PLATFORM_IOS
    [s_AudioEngineSessionHandler release];
#endif
    s_instance = nullptr;
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
    ALCcontext *currentContext = alcGetCurrentContext();
    if (currentContext != s_ALContext) {
        ALOGE("[AUDIO_DEBUG] AudioEngine: play2d WARNING - OpenAL context mismatch! current=%p, expected=%p", currentContext, s_ALContext);
        // 尝试恢复上下文
        if (!alcMakeContextCurrent(s_ALContext)) {
            ALOGE("[AUDIO_DEBUG] AudioEngine: play2d - Failed to restore OpenAL context");
            return AudioEngine::INVALID_AUDIO_ID;
        }
        ALOGI("[AUDIO_DEBUG] AudioEngine: play2d - Successfully restored OpenAL context");
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

