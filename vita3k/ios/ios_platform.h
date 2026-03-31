#pragma once

// ============================================================================
// vita3k/ios/ios_platform.h
// iOS / iPadOS Metal platform layer for Vita3K
//
// Replaces the OpenGL / Vulkan windowing path on Apple mobile targets.
// MoltenVK is used to translate Vulkan API calls to Metal under the hood,
// but the windowing surface (CAMetalLayer, MTKView) is owned here so that
// the rest of the renderer never touches UIKit directly.
// ============================================================================

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IOS

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <atomic>

// ----------------------------------------------------------------------------
// Forward declarations (C++ side)
// ----------------------------------------------------------------------------
namespace ios {

// ---------------------------------------------------------------------------
// MetalContext
// The single Metal device + command queue used by the entire emulator.
// All objects allocated here are thread-safe singletons.
// ---------------------------------------------------------------------------
struct MetalContext {
    id<MTLDevice>       device       = nil;
    id<MTLCommandQueue> commandQueue = nil;

    // Drawable dimensions (in pixels, respecting contentScaleFactor)
    uint32_t drawableWidth  = 0;
    uint32_t drawableHeight = 0;

    // Display link timestamp for frame pacing
    double   displayRefreshRate = 60.0;

    // Pixel format used by the swapchain layer
    MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;

    bool isValid() const { return device != nil && commandQueue != nil; }
};

// ---------------------------------------------------------------------------
// SurfaceInfo
// Thin wrapper that exposes the CAMetalLayer to SDL / MoltenVK so they can
// create a VkSurfaceKHR from it without pulling in UIKit headers.
// ---------------------------------------------------------------------------
struct SurfaceInfo {
    void*    caMetalLayerPtr = nullptr; // __bridge void* to CAMetalLayer
    uint32_t widthPx         = 0;
    uint32_t heightPx        = 0;
    float    contentScale    = 1.0f;
};

// ---------------------------------------------------------------------------
// FramePacingStats — updated every frame by ios_update_frame_pacing()
// ---------------------------------------------------------------------------
struct FramePacingStats {
    double  targetFrameTime    = 1.0 / 60.0;  // seconds
    double  lastFrameDuration  = 0.0;
    double  averageFrameTime   = 0.0;
    uint64_t frameIndex        = 0;
    std::atomic<bool> throttleRequested { false };
};

// ============================================================================
// Public C++ API (implemented in ios_platform.mm)
// ============================================================================

/// Initialise the Metal device, command queue and CAMetalLayer.
/// Must be called once from the main thread before any rendering starts.
/// Returns false if Metal is unavailable (should never happen on iOS 15+).
bool platform_init(UIView* hostView);

/// Tear down Metal state. Call from -applicationWillTerminate:.
void platform_shutdown();

/// Return a reference to the global MetalContext (valid after platform_init).
MetalContext& get_metal_context();

/// Return surface info for MoltenVK / SDL_Vulkan_CreateSurface.
SurfaceInfo get_surface_info();

/// Called when the hosting UIView changes bounds (rotation, split-view, …).
/// Resizes the CAMetalLayer drawable and notifies the renderer.
void platform_resize(uint32_t newWidthPx, uint32_t newHeightPx, float scale);

/// Called once per CADisplayLink tick. Updates frame-pacing stats and,
/// if the GPU is behind, signals the emulator to drop an emulated frame.
void platform_update_frame_pacing();

/// Returns current frame-pacing stats (read-only).
const FramePacingStats& get_frame_pacing();

/// Optimise GPU / CPU performance tier for the current thermal state.
/// Called automatically from the thermal notification handler, but can
/// also be called manually during benchmark or loading screens.
void optimise_device_performance(NSProcessInfoThermalState thermalState);

/// Flush completed command buffers and recycle the drawable. Call this
/// after presenting to the screen so ARC can release the drawable quickly.
void recycle_drawable();

// ---------------------------------------------------------------------------
// Memory management helpers
// ---------------------------------------------------------------------------

/// Return the recommended Metal resource storage mode for this device.
/// - Apple Silicon A-series / M-series: MTLStorageModeShared (unified mem)
/// - Older devices: MTLStorageModePrivate + staging buffers
MTLStorageMode recommended_storage_mode();

/// True when the GPU and CPU share the same physical memory (A9+).
bool has_unified_memory();

/// Allocate a Metal buffer using the optimal storage mode.
/// The caller takes ownership (the buffer is autoreleased).
id<MTLBuffer> alloc_buffer(NSUInteger byteLength, MTLResourceOptions extraOpts = 0);

} // namespace ios

// ============================================================================
// Objective-C interface (only visible to .mm translation units)
// ============================================================================
#ifdef __OBJC__

// ---------------------------------------------------------------------------
// VitaMetalView
// A UIView subclass whose backing layer is CAMetalLayer.
// Vita3K creates exactly one of these and embeds it as the root view of the
// window. SDL then wraps it via SDL_CreateWindowFrom().
// ---------------------------------------------------------------------------
@interface VitaMetalView : UIView <CALayerDelegate>

/// The underlying Metal layer (same as self.layer cast to CAMetalLayer).
@property (nonatomic, readonly) CAMetalLayer* metalLayer;

/// Pixel dimensions of the drawable (updated on every bounds change).
@property (nonatomic, readonly) CGSize drawableSizePixels;

/// Block invoked on the render thread each time a new drawable is available.
@property (nonatomic, copy) void (^onDrawableSizeChanged)(CGSize newSize);

/// Initialise with an explicit Metal device so the layer is set up before
/// the view is added to the hierarchy.
- (instancetype)initWithFrame:(CGRect)frame
                       device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@end

// ---------------------------------------------------------------------------
// VitaDisplayLink
// Wraps CADisplayLink to drive the emulator's render loop at the display's
// native refresh rate (60 / 90 / 120 Hz depending on the device).
// ---------------------------------------------------------------------------
@interface VitaDisplayLink : NSObject

@property (nonatomic, readonly)  double  preferredFramesPerSecond;
@property (nonatomic, readonly)  double  timestamp;          // last vblank
@property (nonatomic, readonly)  double  targetTimestamp;    // next vblank
@property (nonatomic, readonly)  BOOL    isPaused;

/// Block called on every vblank from the display link's run-loop.
@property (nonatomic, copy) void (^onVblank)(double dt);

- (instancetype)init;
- (void)start;
- (void)pause;
- (void)resume;   ///< Re-enables after pause without re-registering the display link.
- (void)invalidate;

@end

#endif // __OBJC__

// ============================================================================
// C linkage shims — lets C++ translation units poke the Obj-C layer
// without importing UIKit headers.
// ============================================================================
#ifdef __cplusplus
extern "C" {
#endif

/// Returns the __bridge void* pointer to the current CAMetalLayer.
/// Safe to call from any thread after platform_init().
void* ios_get_ca_metal_layer(void);

/// Returns drawable width / height in device pixels.
void  ios_get_drawable_size(uint32_t* outW, uint32_t* outH);

/// Notify the platform layer that the emulator has finished presenting a frame.
void  ios_frame_presented(void);

/// Signal the platform that the app moved to background (pause rendering).
void  ios_app_did_enter_background(void);

/// Signal the platform that the app returned to foreground.
void  ios_app_will_enter_foreground(void);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // TARGET_OS_IOS
