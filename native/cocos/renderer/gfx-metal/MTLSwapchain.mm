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

#import "../gfx-base/GFXDef-common.h"
#import "MTLSwapchain.h"
#if CC_PLATFORM == CC_PLATFORM_MACOS
    #import <AppKit/NSView.h>
#else
    #import <UIKit/UIView.h>
#endif

#import "base/Log.h"
#import "MTLGPUObjects.h"
#import "MTLDevice.h"
#import "MTLGPUObjects.h"
namespace cc {
namespace gfx {

namespace {
#if CC_PLATFORM == CC_PLATFORM_MACOS
using CCView = NSView;
#else
using CCView = UIView;
#endif
}; // namespace

CCMTLSwapchain::CCMTLSwapchain() {
}

CCMTLSwapchain::~CCMTLSwapchain() {
    destroy();
}

void CCMTLSwapchain::doInit(const SwapchainInfo& info) {
    _gpuSwapchainObj = ccnew CCMTLGPUSwapChainObject;

    //----------------------acquire layer-----------------------------------
#if CC_EDITOR
    CAMetalLayer* layer = (CAMetalLayer*)info.windowHandle;
    if (!layer.device) {
        layer.device = MTLCreateSystemDefaultDevice();
    }
#else
    // This runs on the render/message-queue consumer thread, so UIKit must not be
    // touched here. Prefer the layer the platform resolved on the main thread
    // (see SwapchainInfo::windowLayer / SystemWindow::getWindowLayer()).
    CAMetalLayer *layer = nullptr;
    #if CC_PLATFORM == CC_PLATFORM_IOS
    if (info.windowLayer) {
        layer = static_cast<CAMetalLayer *>(info.windowLayer);
    }
    #endif
    if (!layer) {
        // Legacy path: -[UIView layer] off the main thread is exactly the violation we
        // are removing. Kept only as a last resort, so that a missing windowLayer
        // degrades to the previous behavior (which works) instead of leaving a nil
        // CAMetalLayer behind (acquire() would then spin forever on nextDrawable).
        auto *view = (CCView *)info.windowHandle;
        layer = static_cast<CAMetalLayer *>(view.layer);
    #if CC_PLATFORM == CC_PLATFORM_IOS
        CC_LOG_WARNING("MTLSwapchain::doInit: windowLayer is empty, falling back to -[UIView layer] on the render thread.");
    #endif
    }
#endif

    if (layer.pixelFormat == MTLPixelFormatInvalid) {
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    }
    // framebufferOnly 是 CAMetalLayer 自己的属性，改它不会走 UIKit 对"view 支持的 layer"的记账，
    // 所以放在渲染线程是安全的（A1 第二轮实测：真机不再对这两行报任何违规）。
    layer.framebufferOnly = NO;
#if CC_PLATFORM == CC_PLATFORM_MACOS
    //setDisplaySyncEnabled : physic device refresh rate.
    //setPresentsWithTransaction : Core Animation transactions update rate.
    auto syncModeFunc = [&](BOOL sync, BOOL transaction) {
        [layer setDisplaySyncEnabled:sync];
        [layer setPresentsWithTransaction:transaction];
    };
    switch (_vsyncMode) {
        case VsyncMode::OFF:
            syncModeFunc(NO, NO);
            break;
        case VsyncMode::ON:
            syncModeFunc(YES, YES);
        case VsyncMode::RELAXED:
        case VsyncMode::MAILBOX:
        case VsyncMode::HALF:
            syncModeFunc(YES, NO);
        default:
            break;
    }
#else
    // iOS 上**不能**在这里改 presentsWithTransaction：它是 CALayer 属性，UIKit 对"由 view 支持的
    // layer"会拦截修改并在非主线程时报（A1 第二轮的真机日志，栈就是原来这个 lambda）：
    //   Modifying properties of a view's layer off the main thread is not allowed:
    //   view <View: …> with associated view controller <ViewController: …>
    //   … CCMTLSwapchain::doInit(…)::$_0::operator() …
    // 取值本来就是常数：无论 _vsyncMode 落到哪一支，presentsWithTransaction 都是 NO
    // （VsyncMode::ON 还会因为缺 break 落到下一支再设一次 NO）。所以改在**主线程**解析 layer 时
    // 一次性设好（见 SystemWindow::getWindowLayer()），渲染线程不再碰它。
    // _vsyncMode 在 iOS 上因此不再参与 layer 配置；若将来真要支持 OFF/ON 的差别，必须把
    // 对应设置也放到主线程那条路径上，而不是搬回这里。
#endif
    _gpuSwapchainObj->mtlLayer = layer;

    //    MTLPixelFormatBGRA8Unorm
    //    MTLPixelFormatBGRA8Unorm_sRGB
    //    MTLPixelFormatRGBA16Float
    //    MTLPixelFormatRGB10A2Unorm (macOS only)
    //    MTLPixelFormatBGR10A2Unorm (macOS only)
    //    MTLPixelFormatBGRA10_XR
    //    MTLPixelFormatBGRA10_XR_sRGB
    //    MTLPixelFormatBGR10_XR
    //    MTLPixelFormatBGR10_XR_sRGB
    Format colorFmt = Format::BGRA8;
    Format depthStencilFmt = Format::DEPTH_STENCIL;

    _colorTexture = ccnew CCMTLTexture;
    _depthStencilTexture = ccnew CCMTLTexture;

    SwapchainTextureInfo textureInfo;
    textureInfo.swapchain = this;
    textureInfo.format = colorFmt;
    textureInfo.width = info.width;
    textureInfo.height = info.height;
    initTexture(textureInfo, _colorTexture);

    textureInfo.format = depthStencilFmt;
    initTexture(textureInfo, _depthStencilTexture);

    CCMTLDevice::getInstance()->registerSwapchain(this);
}

void CCMTLSwapchain::doDestroy() {
    CCMTLDevice::getInstance()->unRegisterSwapchain(this);
    if (_gpuSwapchainObj) {
        _gpuSwapchainObj->currentDrawable = nil;
        _gpuSwapchainObj->mtlLayer = nil;

        CC_SAFE_DELETE(_gpuSwapchainObj);
    }

    CC_SAFE_DESTROY_NULL(_colorTexture);
    CC_SAFE_DESTROY_NULL(_depthStencilTexture);
}

void CCMTLSwapchain::doDestroySurface() {
    if (_gpuSwapchainObj) {
        _gpuSwapchainObj->currentDrawable = nil;
        _gpuSwapchainObj->mtlLayer = nil;
    }
}

void CCMTLSwapchain::doResize(uint32_t width, uint32_t height, SurfaceTransform /*transform*/) {
    _colorTexture->resize(width, height);
    _depthStencilTexture->resize(width, height);
}

CCMTLTexture* CCMTLSwapchain::colorTexture() {
    return static_cast<CCMTLTexture*>(_colorTexture.get());
}

CCMTLTexture* CCMTLSwapchain::depthStencilTexture() {
    return static_cast<CCMTLTexture*>(_depthStencilTexture.get());
}

id<CAMetalDrawable> CCMTLSwapchain::currentDrawable() {
    return _gpuSwapchainObj->currentDrawable;
}

void CCMTLSwapchain::release() {
    _gpuSwapchainObj->currentDrawable = nil;
    static_cast<CCMTLTexture*>(_colorTexture.get())->update();
}

void CCMTLSwapchain::acquire() {
    // hang on here if next drawable not available
    while (!_gpuSwapchainObj->currentDrawable) {
        _gpuSwapchainObj->currentDrawable = [_gpuSwapchainObj->mtlLayer nextDrawable];
        static_cast<CCMTLTexture*>(_colorTexture.get())->update();
    }
}

void CCMTLSwapchain::doCreateSurface(void* windowHandle) {
}

} // namespace gfx
} // namespace cc
