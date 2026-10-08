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

#define LOG_TAG "AudioPlayer"

#import <Foundation/Foundation.h>
#include "audio/apple/AudioCache.h"
#include "audio/apple/AudioDecoder.h"
#include "audio/apple/AudioPlayer.h"
#include "base/memory/Memory.h"
#include "platform/FileUtils.h"

#ifdef VERY_VERY_VERBOSE_LOGGING
    #define ALOGVV ALOGV
#else
    #define ALOGVV(...) \
        do {            \
        } while (false)
#endif

using namespace cc;

namespace {
unsigned int __idIndex = 0;
}

AudioPlayer::AudioPlayer()
: _audioCache(nullptr), _finishCallbak(nullptr), _isDestroyed(false), _removeByAudioEngine(false), _ready(false), _currTime(0.0f), _streamingSource(false), _rotateBufferThread(nullptr), _timeDirty(false), _isRotateThreadExited(false), _needWakeupRotateThread(false), _id(++__idIndex) {
    memset(_bufferIds, 0, sizeof(_bufferIds));
}

AudioPlayer::~AudioPlayer() {
    ALOGVV("~AudioPlayer() (%p), id=%u", this, _id);
    destroy();

    if (_streamingSource) {
        alDeleteBuffers(QUEUEBUFFER_NUM, _bufferIds);
    }
}

void AudioPlayer::destroy() {
    if (_isDestroyed)
        return;

    ALOGVV("AudioPlayer::destroy begin, id=%u", _id);

    _isDestroyed = true;

    do {
        if (_audioCache != nullptr) {
            if (_audioCache->_state == AudioCache::State::INITIAL) {
                ALOGV("AudioPlayer::destroy, id=%u, cache isn't ready!", _id);
                break;
            }

            while (!_audioCache->_isLoadingFinished) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        }

        // Wait for play2d to be finished.
        _play2dMutex.lock();
        _play2dMutex.unlock();

        if (_streamingSource) {
            if (_rotateBufferThread != nullptr) {
                while (!_isRotateThreadExited) {
                    _sleepCondition.notify_one();
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                }

                if (_rotateBufferThread->joinable()) {
                    _rotateBufferThread->join();
                }

                delete _rotateBufferThread;
                _rotateBufferThread = nullptr;
                ALOGVV("rotateBufferThread exited!");

#if CC_TARGET_PLATFORM == CC_PLATFORM_IOS
                // some specific OpenAL implement defects existed on iOS platform
                // refer to: https://github.com/cocos2d/cocos2d-x/issues/18597
                ALint sourceState;
                ALint bufferProcessed = 0;
                alGetSourcei(_alSource, AL_SOURCE_STATE, &sourceState);
                if (sourceState == AL_PLAYING) {
                    alGetSourcei(_alSource, AL_BUFFERS_PROCESSED, &bufferProcessed);
                    while (bufferProcessed < QUEUEBUFFER_NUM) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(2));
                        alGetSourcei(_alSource, AL_BUFFERS_PROCESSED, &bufferProcessed);
                    }
                    alSourceUnqueueBuffers(_alSource, QUEUEBUFFER_NUM, _bufferIds);
                    CHECK_AL_ERROR_DEBUG();
                }
                ALOGVV("UnqueueBuffers Before alSourceStop");
#endif
            }
        }
    } while (false);

    ALOGVV("Before alSourceStop");
    alSourceStop(_alSource);
    CHECK_AL_ERROR_DEBUG();
    ALOGVV("Before alSourcei");
    alSourcei(_alSource, AL_BUFFER, 0);
    CHECK_AL_ERROR_DEBUG();

    _removeByAudioEngine = true;

    _ready = false;
    ALOGVV("AudioPlayer::destroy end, id=%u", _id);
}

void AudioPlayer::setCache(AudioCache *cache) {
    _audioCache = cache;
}

bool AudioPlayer::play2d() {
    _play2dMutex.lock();
    ALOGVV("AudioPlayer::play2d, _alSource: %u", _alSource);

    /*********************************************************************/
    /*       Note that it may be in sub thread or in main thread.       **/
    /*********************************************************************/
    bool ret = false;
    do {
        if (_audioCache->_state != AudioCache::State::READY) {
            ALOGE("alBuffer isn't ready for play!");
            break;
        }

        alSourcei(_alSource, AL_BUFFER, 0);
        CHECK_AL_ERROR_DEBUG();
        alSourcef(_alSource, AL_PITCH, 1.0f);
        CHECK_AL_ERROR_DEBUG();
        alSourcef(_alSource, AL_GAIN, _volume);
        CHECK_AL_ERROR_DEBUG();
        alSourcei(_alSource, AL_LOOPING, AL_FALSE);
        CHECK_AL_ERROR_DEBUG();

        if (_audioCache->_queBufferFrames == 0) {
            if (_loop) {
                alSourcei(_alSource, AL_LOOPING, AL_TRUE);
                CHECK_AL_ERROR_DEBUG();
            }
        } else {
            if (_currTime > _audioCache->_duration) {
                _currTime = 0.F; // Target current start time is invalid, reset to 0.
            }
            alGenBuffers(QUEUEBUFFER_NUM, _bufferIds);

            auto alError = alGetError();
            if (alError == AL_NO_ERROR) {
                for (int index = 0; index < QUEUEBUFFER_NUM; ++index) {
                    alBufferData(_bufferIds[index], _audioCache->_format, _audioCache->_queBuffers[index], _audioCache->_queBufferSize[index], _audioCache->_sampleRate);
                }
                CHECK_AL_ERROR_DEBUG();
            } else {
                ALOGE("%s:alGenBuffers error code:%x", __PRETTY_FUNCTION__, alError);
                break;
            }
            _streamingSource = true;
        }

        {
            std::unique_lock<std::mutex> lk(_sleepMutex);
            if (_isDestroyed)
                break;

            if (_streamingSource) {
                // To continuously stream audio from a source without interruption, buffer queuing is required.
                alSourceQueueBuffers(_alSource, QUEUEBUFFER_NUM, _bufferIds);
                CHECK_AL_ERROR_DEBUG();
                _rotateBufferThread = ccnew std::thread(&AudioPlayer::rotateBufferThread, this, _audioCache->_queBufferFrames * QUEUEBUFFER_NUM + 1);
            } else {
                alSourcei(_alSource, AL_BUFFER, _audioCache->_alBufferId);
                CHECK_AL_ERROR_DEBUG();
            }

            alSourcePlay(_alSource);
        }

        auto alError = alGetError();
        if (alError != AL_NO_ERROR) {
            ALOGE("%s:alSourcePlay error code:%x", __PRETTY_FUNCTION__, alError);
            break;
        }
        /** Due to the bug of OpenAL, when the second time OpenAL trying to mix audio into bus, the mRampState become kRampingComplete, and for those oalSource whose mRampState == kRampingComplete, nothing happens.
         * OALSource::Play{
         *      switch(mState){
         *       case kTransitionToStop:
         *       case kTransitionToStop:
         *         if(mRampState != kRampingComplete){..}
         *         break;
         *      }
         * }
         * So the assert here will trigger this bug as aolSource is reused.
         * Replace OpenAL with AVAudioEngine on V3.6 mightbe helpful
        */
//        CC_ASSERT_EQ(state, AL_PLAYING);
        _ready = true;
        ret = true;
    } while (false);

    if (!ret) {
        _removeByAudioEngine = true;
    }

    _play2dMutex.unlock();
    return ret;
}

// rotateBufferThread is used to rotate alBufferData for _alSource when playing big audio file
void AudioPlayer::rotateBufferThread(int offsetFrame) {
    char *tmpBuffer = nullptr;
    AudioDecoder decoder;
    long long rotateSleepTime = static_cast<long long>(QUEUEBUFFER_TIME_STEP * 1000) / 2;
    // 流式播放的初始只排队 QUEUEBUFFER_NUM(4) × QUEUEBUFFER_TIME_STEP(0.05s) ≈ 0.2 秒音频，
    // 之后全靠本线程每 25ms 续一次。所以"BGM 只播个开头就停"= 本线程没在工作（或提前退出）。
    // 下面几条日志把线程的 start / 提前退出 / 正常退出都记下来，便于一次复现就定位。
    // 带上 player id：真机日志里这些行原来没有 id，无法判断是哪个 BGM 卡住（2026-10-08 复现时踩到）
    ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] Rotate(id=%u): start, offsetFrame=%d queuedFrames=%u sleepMs=%lld",
          _id, offsetFrame, _audioCache ? _audioCache->_queBufferFrames : 0, rotateSleepTime);
    do {
        if (!decoder.open(_audioCache->_fileFullPath.c_str())) {
            ALOGE("[AUDIO_DEBUG][BKAUDIOTRACE] Rotate: decoder.open FAILED -> no refill, playback will stop after the queued buffers");
            break;
        }

        uint32_t framesRead = 0;
        const uint32_t framesToRead = _audioCache->_queBufferFrames;
        const uint32_t bufferSize = framesToRead * decoder.getBytesPerFrame();
        tmpBuffer = (char *)malloc(bufferSize);
        memset(tmpBuffer, 0, bufferSize);

        if (offsetFrame != 0) {
            decoder.seek(offsetFrame);
        }

        ALint sourceState;
        ALint bufferProcessed = 0;
        bool needToExitThread = false;
        // 诊断（限频 1 秒）：流式补数据只在这两个条件成立时才会发生 ——
        //   ① source 处于 PLAYING/PAUSED；
        //   ② AL_BUFFERS_PROCESSED > 0（有播完可回收的缓冲）。
        // 线上"BGM 只播个开头就停"（约 QUEUEBUFFER_NUM × QUEUEBUFFER_TIME_STEP ≈ 2 秒后无声）
        // 就是这两个条件之一不成立导致的：这里把实际取值打出来，一次复现即可定位。
        auto lastRotateDiag = std::chrono::steady_clock::now();
        auto lastResumeAttempt = std::chrono::steady_clock::now() - std::chrono::seconds(10);
        ALint diagQueued = 0;

        while (!_isDestroyed) {
            alGetSourcei(_alSource, AL_SOURCE_STATE, &sourceState);
            alGetSourcei(_alSource, AL_BUFFERS_QUEUED, &diagQueued);
            bool rotateDidWork = false;
            /* On IOS, audio state will lie, when the system is not fully foreground,
             * openAl will process the buffer in queue, but our condition cannot make sure that the audio
             * is playing as it's too short. Interesting IOS system.
             * Solution is to load buffer even if it's paused, just make sure that there's no bufferProcessed in 
             */
            // 注意 AL_STOPPED 也要进这个分支：广告/音频会话被接管后 iOS 可能把源直接停掉
            // （一次采样都没渲染就 STOPPED），而补数据只在 PLAYING/PAUSED 时工作 ——
            // 源一旦 STOPPED 就永远不再补数据，表现为"BGM 只播个开头就再也没声，
            // 直到退出场景重进（那时是全新的音频源）"。循环播放的源在这里做自愈。
            if (sourceState == AL_PLAYING || sourceState == AL_PAUSED || (sourceState == AL_STOPPED && _loop)) {
                alGetSourcei(_alSource, AL_BUFFERS_PROCESSED, &bufferProcessed);
                rotateDidWork = bufferProcessed > 0;
                while (bufferProcessed > 0) {
                    bufferProcessed--;
                    if (_timeDirty) {
                        _timeDirty = false;
                        offsetFrame = _currTime * decoder.getSampleRate();
                        decoder.seek(offsetFrame);
                    } else {
                        _currTime += QUEUEBUFFER_TIME_STEP;
                        if (_currTime > _audioCache->_duration) {
                            if (_loop) {
                                _currTime = 0.0f;
                            } else {
                                _currTime = _audioCache->_duration;
                            }
                        }
                    }

                    framesRead = decoder.readFixedFrames(framesToRead, tmpBuffer);

                    if (framesRead == 0) {
                        if (_loop) {
                            decoder.seek(0);
                            framesRead = decoder.readFixedFrames(framesToRead, tmpBuffer);
                        } else {
                            needToExitThread = true;
                            break;
                        }
                    }
                    /*
                     While the source is playing, alSourceUnqueueBuffers can be called to remove buffers which have
                     already played. Those buffers can then be filled with new data or discarded. New or refilled
                     buffers can then be attached to the playing source using alSourceQueueBuffers. As long as there is
                     always a new buffer to play in the queue, the source will continue to play.
                     */
                    ALuint bid;
                    alSourceUnqueueBuffers(_alSource, 1, &bid);
                    alBufferData(bid, _audioCache->_format, tmpBuffer, framesRead * decoder.getBytesPerFrame(), decoder.getSampleRate());
                    alSourceQueueBuffers(_alSource, 1, &bid);
                }

                // 自愈：补完数据后如果循环源仍处于 STOPPED（上面那种"压根没渲染就被停"的情况），
                // 重新 alSourcePlay 让它接着放。限频 1 秒，避免在设备确实不可用时反复重播刷日志。
                if (_loop) {
                    ALint stateNow = 0;
                    alGetSourcei(_alSource, AL_SOURCE_STATE, &stateNow);
                    if (stateNow == AL_STOPPED) {
                        auto nowResume = std::chrono::steady_clock::now();
                        if (std::chrono::duration_cast<std::chrono::milliseconds>(nowResume - lastResumeAttempt).count() >= 1000) {
                            lastResumeAttempt = nowResume;
                            ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] Rotate(id=%u): loop source was STOPPED unexpectedly -> re-queue + play again (queued=%d)",
                                  _id, diagQueued);
                            alSourcePlay(_alSource);
                        }
                    }
                }
            }

            // 限频诊断：只有当"本轮没有做任何补数据"且持续 1 秒以上时才打一行，
            // 避免正常播放时刷屏；一旦 BGM 卡住，这条日志会每秒出现一次并给出 state/queued/processed。
            if (rotateDidWork) {
                lastRotateDiag = std::chrono::steady_clock::now();
            } else {
                auto now = std::chrono::steady_clock::now();
                if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastRotateDiag).count() >= 1000) {
                    lastRotateDiag = now;
                    ALOGW("[AUDIO_DEBUG][BKAUDIOTRACE] Rotate(idle): id=%u state=%d queued=%d processed=%d loop=%d currTime=%.2f duration=%.2f -> no refill",
                          _id, sourceState, diagQueued, bufferProcessed, (int)_loop, _currTime, _audioCache ? _audioCache->_duration : 0.0f);
                }
            }

            std::unique_lock<std::mutex> lk(_sleepMutex);
            if (_isDestroyed || needToExitThread) {
                // needToExitThread 只在"读到 0 帧且 loop=0"时置位：那之后不会再补数据，
                // 对 loop=1 的 BGM 不该出现；出现即说明 loop 标记没生效。
                ALOGI("[AUDIO_DEBUG][BKAUDIOTRACE] Rotate(id=%u): exit loop, isDestroyed=%d needToExitThread=%d loop=%d",
                      _id, (int)_isDestroyed, (int)needToExitThread, (int)_loop);
                break;
            }

            if (!_needWakeupRotateThread) {
                _sleepCondition.wait_for(lk, std::chrono::milliseconds(rotateSleepTime));
            }

            _needWakeupRotateThread = false;
        }

    } while (false);

    ALOGVV("Exit rotate buffer thread ...");
    decoder.close();
    free(tmpBuffer);
    _isRotateThreadExited = true;
}

void AudioPlayer::wakeupRotateThread() {
    _needWakeupRotateThread = true;
    _sleepCondition.notify_all();
}

bool AudioPlayer::setLoop(bool loop) {
    if (!_isDestroyed) {
        _loop = loop;
        return true;
    }

    return false;
}

bool AudioPlayer::setTime(float time) {
    if (!_isDestroyed && time >= 0.0f && time < _audioCache->_duration) {
        _currTime = time;
        _timeDirty = true;

        return true;
    }
    return false;
}
