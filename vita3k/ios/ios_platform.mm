// ============================================================================
// vita3k/ios/ios_platform.mm
// ============================================================================
// Implements the Metal / UIKit platform layer declared in ios_platform.h.
// Only compiled when TARGET_OS_IOS is set (handled by CMakeLists).
// ============================================================================

#include "ios_platform.h"

#if TARGET_OS_IOS

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#include <cassert>
#include <cmath>
#include <mutex>
#include <atomic>

// ============================================================================
// VitaMetalView implementation
// ============================================================================
@implementation VitaMetalView {
    id<MTLDevice> _device;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame device:(id<MTLDevice>)device {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _device = device;

    CAMetalLayer* ml = self.metalLayer;
    ml.device              = device;
    ml.pixelFormat         = MTLPixelFormatBGRA8Unorm;
    ml.framebufferOnly     = YES;   // fastest path; disable if screenshot needed
    ml.opaque              = YES;
    ml.contentsScale       = UIScreen.mainScreen.nativeScale;
    ml.delegate            = self;

    // Limit the number of inflight drawables to reduce latency.
    // 3 = max pipeline depth (triple buffering); 2 is better for latency.
    ml.maximumDrawableCount = 2;

    // ProMotion / 120 Hz support
    if (@available(iOS 15.0, *)) {
        CAFrameRateRange range = CAFrameRateRangeMake(30, 120, 60);
        ml.preferredFrameRateRange = range;
    }

    [self _updateDrawableSize];

    // Respond to bounds changes automatically
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentMode      = UIViewContentModeScaleToFill;

    return self;
}

- (CAMetalLayer*)metalLayer {
    return (CAMetalLayer*)self.layer;
}

- (CGSize)drawableSizePixels {
    return self.metalLayer.drawableSize;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self _updateDrawableSize];
}

- (void)_updateDrawableSize {
    CGSize  sz    = self.bounds.size;
    CGFloat scale = UIScreen.mainScreen.nativeScale;

    CGSize drawableSize = CGSizeMake(
        std::ceil(sz.width  * scale),
        std::ceil(sz.height * scale)
    );

    if (!CGSizeEqualToSize(self.metalLayer.drawableSize, drawableSize)) {
        self.metalLayer.drawableSize = drawableSize;

        if (self.onDrawableSizeChanged) {
            self.onDrawableSizeChanged(drawableSize);
        }
    }
}

@end

// ============================================================================
// VitaDisplayLink implementation
// ============================================================================
@implementation VitaDisplayLink {
    CADisplayLink* _displayLink;
    CFTimeInterval _lastTimestamp;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _displayLink = [CADisplayLink displayLinkWithTarget:self
                                               selector:@selector(_tick:)];

    if (@available(iOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 60);
    } else {
        _displayLink.preferredFramesPerSecond = 60;
    }

    _preferredFramesPerSecond = 60.0;
    return self;
}

- (void)start {
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop
                       forMode:NSRunLoopCommonModes];
    _isPaused = NO;
}

- (void)pause {
    _displayLink.paused = YES;
    _isPaused = YES;
}

- (void)resume {
    // Resume without re-adding to the run loop (start already did that).
    // Calling start again would register a second CADisplayLink entry,
    // causing every vblank to fire the callback twice.
    _displayLink.paused = NO;
    _isPaused = NO;
}

- (void)invalidate {
    [_displayLink invalidate];
}

- (void)_tick:(CADisplayLink*)link {
    _timestamp       = link.timestamp;
    _targetTimestamp = link.targetTimestamp;

    double dt = (_lastTimestamp > 0.0)
        ? (link.timestamp - _lastTimestamp)
        : (1.0 / 60.0);
    _lastTimestamp = link.timestamp;

    double fps = link.duration > 0.0 ? (1.0 / link.duration) : 60.0;
    _preferredFramesPerSecond = fps;

    if (self.onVblank) {
        self.onVblank(dt);
    }
}

@end

// ============================================================================
// Global platform state (C++ side)
// ============================================================================
namespace ios {

namespace {

// Singleton state — all access after init must go through the public API.
struct PlatformState {
    MetalContext      metalCtx;
    SurfaceInfo       surfaceInfo;
    FramePacingStats  pacingStats;

    __strong VitaMetalView*   metalView    = nil;
    __strong VitaDisplayLink* displayLink  = nil;

    std::mutex        mutex;
    std::atomic<bool> inBackground { false };
    std::atomic<bool> initialised  { false };
};

static PlatformState g_state;

} // anonymous namespace

// ---------------------------------------------------------------------------
bool platform_init(UIView* hostView) {
    std::lock_guard<std::mutex> lock(g_state.mutex);

    if (g_state.initialised.load()) return true;

    // 1. Pick the best Metal device
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return false;

    // 2. Create command queue
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) return false;

    // 3. Configure MetalContext
    g_state.metalCtx.device       = device;
    g_state.metalCtx.commandQueue = queue;
    g_state.metalCtx.pixelFormat  = MTLPixelFormatBGRA8Unorm;

    // 4. Create the VitaMetalView
    VitaMetalView* view = [[VitaMetalView alloc] initWithFrame:hostView.bounds
                                                        device:device];
    [hostView addSubview:view];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor     constraintEqualToAnchor:hostView.topAnchor],
        [view.bottomAnchor  constraintEqualToAnchor:hostView.bottomAnchor],
        [view.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
    ]];

    view.onDrawableSizeChanged = ^(CGSize newSize) {
        platform_resize(
            static_cast<uint32_t>(newSize.width),
            static_cast<uint32_t>(newSize.height),
            static_cast<float>(UIScreen.mainScreen.nativeScale)
        );
    };

    g_state.metalView = view;

    // 5. Surface info for MoltenVK / SDL
    CGSize drawSz = view.metalLayer.drawableSize;
    g_state.surfaceInfo.caMetalLayerPtr = (__bridge void*)view.metalLayer;
    g_state.surfaceInfo.widthPx         = static_cast<uint32_t>(drawSz.width);
    g_state.surfaceInfo.heightPx        = static_cast<uint32_t>(drawSz.height);
    g_state.surfaceInfo.contentScale    = static_cast<float>(UIScreen.mainScreen.nativeScale);

    g_state.metalCtx.drawableWidth  = g_state.surfaceInfo.widthPx;
    g_state.metalCtx.drawableHeight = g_state.surfaceInfo.heightPx;

    // 6. Display link for frame pacing
    VitaDisplayLink* dl = [[VitaDisplayLink alloc] init];
    dl.onVblank = ^(double dt) {
        platform_update_frame_pacing();
    };
    [dl start];
    g_state.displayLink = dl;

    // 7. Register thermal notifications
    [NSNotificationCenter.defaultCenter
        addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
        optimise_device_performance(NSProcessInfo.processInfo.thermalState);
    }];

    // Run initial performance optimisation
    optimise_device_performance(NSProcessInfo.processInfo.thermalState);

    g_state.initialised.store(true);
    return true;
}

// ---------------------------------------------------------------------------
void platform_shutdown() {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    [g_state.displayLink invalidate];
    g_state.displayLink  = nil;
    g_state.metalView    = nil;
    g_state.metalCtx     = {};
    g_state.surfaceInfo  = {};
    g_state.initialised.store(false);
}

// ---------------------------------------------------------------------------
MetalContext& get_metal_context() {
    return g_state.metalCtx;
}

// ---------------------------------------------------------------------------
SurfaceInfo get_surface_info() {
    return g_state.surfaceInfo;
}

// ---------------------------------------------------------------------------
void platform_resize(uint32_t w, uint32_t h, float scale) {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.surfaceInfo.widthPx      = w;
    g_state.surfaceInfo.heightPx     = h;
    g_state.surfaceInfo.contentScale = scale;
    g_state.metalCtx.drawableWidth   = w;
    g_state.metalCtx.drawableHeight  = h;
}

// ---------------------------------------------------------------------------
void platform_update_frame_pacing() {
    if (g_state.inBackground.load()) return;

    FramePacingStats& s = g_state.pacingStats;
    const double target = 1.0 / g_state.metalCtx.displayRefreshRate;

    s.targetFrameTime = target;
    s.frameIndex++;

    // Simple EWMA for average frame time — alpha=0.2 converges in ~11 frames,
    // responsive enough to catch sudden load spikes without over-reacting to
    // single-frame outliers.
    if (s.lastFrameDuration > 0.0) {
        constexpr double alpha = 0.2;
        s.averageFrameTime = alpha * s.lastFrameDuration
                           + (1.0 - alpha) * s.averageFrameTime;
    }

    // Throttle if running behind by more than 15%
    s.throttleRequested.store(s.averageFrameTime > target * 1.15);
}

// ---------------------------------------------------------------------------
const FramePacingStats& get_frame_pacing() {
    return g_state.pacingStats;
}

// ---------------------------------------------------------------------------
void optimise_device_performance(NSProcessInfoThermalState thermalState) {
    // Thermal notifications fire on the main queue; platform_resize() may run
    // concurrently on the render thread — both touch metalCtx.displayRefreshRate
    // so we must hold the mutex.
    std::lock_guard<std::mutex> lock(g_state.mutex);

    switch (thermalState) {
        case NSProcessInfoThermalStateNominal:
        case NSProcessInfoThermalStateFair:
            g_state.metalCtx.displayRefreshRate = g_state.displayLink
                ? g_state.displayLink.preferredFramesPerSecond
                : 60.0;
            g_state.pacingStats.throttleRequested.store(false);
            break;

        case NSProcessInfoThermalStateSerious:
            g_state.metalCtx.displayRefreshRate = 60.0;
            break;

        case NSProcessInfoThermalStateCritical:
            g_state.metalCtx.displayRefreshRate = 30.0;
            g_state.pacingStats.throttleRequested.store(true);
            break;

        default:
            break;
    }
}

// ---------------------------------------------------------------------------
void recycle_drawable() {
    // Measure actual wall-clock time between successive presents so the EWMA
    // in platform_update_frame_pacing() reflects real GPU throughput.
    static double s_lastPresentTime = 0.0;
    const double now = CACurrentMediaTime();
    if (s_lastPresentTime > 0.0)
        g_state.pacingStats.lastFrameDuration = now - s_lastPresentTime;
    s_lastPresentTime = now;
}

// ---------------------------------------------------------------------------
MTLStorageMode recommended_storage_mode() {
    // All modern iOS devices have unified memory (A9 and later).
    // MTLStorageModeShared lets the CPU write directly into GPU-accessible
    // memory without an explicit blit, which is crucial for constant buffers
    // and streaming vertex data in the emulator.
    return MTLStorageModeShared;
}

// ---------------------------------------------------------------------------
bool has_unified_memory() {
    id<MTLDevice> dev = g_state.metalCtx.device;
    if (!dev) return false;
    // hasUnifiedMemory is available from iOS 14
    if (@available(iOS 14.0, *)) {
        return [dev hasUnifiedMemory];
    }
    return true; // Safe assumption for A9+ / all supported iOS 15 devices
}

// ---------------------------------------------------------------------------
id<MTLBuffer> alloc_buffer(NSUInteger byteLength, MTLResourceOptions extraOpts) {
    id<MTLDevice> dev = g_state.metalCtx.device;
    assert(dev && "platform_init must be called before alloc_buffer");

    MTLResourceOptions opts = extraOpts;
    opts |= (recommended_storage_mode() == MTLStorageModeShared)
                ? MTLResourceStorageModeShared
                : MTLResourceStorageModePrivate;

    return [dev newBufferWithLength:byteLength options:opts];
}

} // namespace ios

// ============================================================================
// C shims
// ============================================================================
extern "C" {

void* ios_get_ca_metal_layer(void) {
    return ios::get_surface_info().caMetalLayerPtr;
}

void ios_get_drawable_size(uint32_t* outW, uint32_t* outH) {
    ios::SurfaceInfo info = ios::get_surface_info();
    if (outW) *outW = info.widthPx;
    if (outH) *outH = info.heightPx;
}

void ios_frame_presented(void) {
    // Record real inter-frame duration for the pacing EWMA.
    // platform_update_frame_pacing() is driven by the CADisplayLink vblank
    // callback and must NOT be called here again — doing so would double-count
    // every frame, corrupt frameIndex, and make throttle logic unreliable.
    ios::recycle_drawable();
}

void ios_app_did_enter_background(void) {
    ios::g_state.inBackground.store(true);
    [ios::g_state.displayLink pause];
}

void ios_app_will_enter_foreground(void) {
    ios::g_state.inBackground.store(false);
    [ios::g_state.displayLink resume];
}

} // extern "C"

#endif // TARGET_OS_IOS
