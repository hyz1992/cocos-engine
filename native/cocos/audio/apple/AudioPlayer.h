/****************************************************************************
 Copyright (c) 2014-2016 Chukong Technologies Inc.
 Copyright (c) 2017-2023 Xiamen Yaji Software Co., Ltd.

 http://www.cocos.com

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 of the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
****************************************************************************/

#pragma once

#include "audio/apple/AudioMacros.h"
#include "base/Macros.h"

#include <OpenAL/al.h>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include "base/std/container/string.h"

namespace cc {
class AudioCache;
class AudioEngineImpl;

class AudioPlayer {
public:
    AudioPlayer();
    ~AudioPlayer();

    void destroy();

    //queue buffer related stuff
    bool setTime(float time);
    float getTime() { return _currTime; }
    bool setLoop(bool loop);

protected:
    void setCache(AudioCache *cache);
    void rotateBufferThread(int offsetFrame);
    bool play2d();
    void wakeupRotateThread();

    AudioCache *_audioCache;

    float _volume;
    bool _loop;
    std::function<void(int, const ccstd::string &)> _finishCallbak;

    bool _isDestroyed;
    bool _removeByAudioEngine;
    bool _ready;
    ALuint _alSource;

    //play by circular buffer
    float _currTime;
    bool _streamingSource;
    ALuint _bufferIds[QUEUEBUFFER_NUM];
    std::thread *_rotateBufferThread;
    std::condition_variable _sleepCondition;
    std::mutex _sleepMutex;
    bool _timeDirty;
    bool _isRotateThreadExited;
    std::atomic_bool _needWakeupRotateThread;

    // 【僵尸设备检测】补数据线程发现"源在 PLAYING、队列里有数据、却连续若干秒没有任何缓冲被消费"
    // 就把它置真（= 底层 AudioUnit 没在拉数据）。由 AudioEngineImpl::update()（主线程）消费，
    // 在那里做硬重启（setActive NO→YES + 重绑，等价于"切后台再回来"）。
    // 放在这里而不是直接在补数据线程里做：硬重启要碰 AVAudioSession，只能在主线程/持有会话的那一侧做。
    std::atomic_bool _deviceNotRendering{false};

    std::mutex _play2dMutex;

    unsigned int _id;

    friend class AudioEngineImpl;
};

} // namespace cc
