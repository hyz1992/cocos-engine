/****************************************************************************
 Copyright (c) 2021-2022 Xiamen Yaji Software Co., Ltd.

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

#include "platform/ios/modules/SystemWindow.h"
#import <UIKit/UIKit.h>
#include "platform/BasePlatform.h"
#include "platform/ios/IOSPlatform.h"
#include "platform/interfaces/modules/IScreen.h"

namespace cc {

SystemWindow::SystemWindow(uint32_t windowId, void *externalHandle)
    : _windowId(windowId)
    , _externalHandle(externalHandle) {
}

SystemWindow::~SystemWindow() = default;

void SystemWindow::setCursorEnabled(bool value) {
}

void SystemWindow::closeWindow() {
    // Force quit as there's no API to exit UIApplication
    IOSPlatform* platform = dynamic_cast<IOSPlatform*>(BasePlatform::getPlatform());
    platform->requestExit();
}

uintptr_t SystemWindow::getWindowHandle() const {
    return reinterpret_cast<uintptr_t>(UIApplication.sharedApplication.delegate.window.rootViewController.view);
}

uintptr_t SystemWindow::getWindowLayer() const {
    // UIKit is main-thread-only: reading -[UIView layer] from the render thread trips the
    // Main Thread Checker ("UI API called on a background thread: -[UIView layer]") and
    // Apple has announced that it will assert on such violations in a future OS release.
    // So resolve the CAMetalLayer here, on the main thread, and hand it to the render
    // thread through gfx::SwapchainInfo::windowLayer.
    //
    // When this is called from another thread we must not touch UIKit; return the last
    // value resolved on the main thread (0 until then, which makes the caller fall back
    // to the legacy windowHandle path instead of setting a nil layer).
    if ([NSThread isMainThread]) {
        UIView *view = UIApplication.sharedApplication.delegate.window.rootViewController.view;
        if (view) {
            _windowLayer = reinterpret_cast<uintptr_t>(view.layer);

            // A1 第二轮（真机日志驱动）：不仅"取 layer"要在主线程，**改 layer 的属性**也不能在
            // 渲染线程做 —— 对"由 view 支持的 layer"，UIKit 会拦截属性修改并在非主线程时报：
            //   Modifying properties of a view's layer off the main thread is not allowed:
            //   view <View: …> with associated view controller <ViewController: …>
            // 其中会被拦截的是 CALayer 属性 presentsWithTransaction（原来在
            // CCMTLSwapchain::doInit 的 lambda 里设置，栈正是报错点）；而 pixelFormat /
            // framebufferOnly 是 CAMetalLayer 自己的属性，改它们不会走这条记账路径，
            // 实测不报，所以仍留在 swapchain 侧。
            //
            // 取值：旧代码无论 _vsyncMode 落到哪一支，最终都是 presentsWithTransaction = NO
            // （VsyncMode::ON 还会因缺 break 落到下一支再设一次 NO），所以在主线程固定设 NO
            // 与改动前**行为等价**；即使渲染线程走 fallback 路径、这里没设过，CALayer 的默认值
            // 也是 NO，仍然等价。
            CAMetalLayer *metalLayer = (CAMetalLayer *)view.layer;
            if ([metalLayer isKindOfClass:[CAMetalLayer class]]) {
                metalLayer.presentsWithTransaction = NO;
            }
        }
    }
    return _windowLayer;
}

SystemWindow::Size SystemWindow::getViewSize() const {
    auto dpr = BasePlatform::getPlatform()->getInterface<IScreen>()->getDevicePixelRatio();
    CGRect bounds = [[UIScreen mainScreen] bounds];
    return Size{static_cast<float>(bounds.size.width * dpr), static_cast<float>(bounds.size.height * dpr)};
}

} // namespace cc
