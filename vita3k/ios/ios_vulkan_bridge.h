// ============================================================================
// vita3k/ios/ios_vulkan_bridge.h
// ============================================================================
// Provides iOS-specific helpers that wire the CAMetalLayer surface into
// SDL3's Vulkan path (SDL_Vulkan_CreateSurface) and configure MoltenVK
// for optimal performance on Apple Silicon / iOS.
//
// Include this header ONLY from .mm translation units or from .cpp files
// that are compiled with -x objective-c++ on iOS targets.
// ============================================================================
#pragma once

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IOS

#include <cstdint>
#include <string>
#include <vector>

// MoltenVK layer settings struct is forward-declared here to avoid pulling in
// MoltenVK headers in every translation unit.
struct SDL_Window;

namespace ios {

// ---------------------------------------------------------------------------
// MoltenVK configuration knobs tuned for the Vita3K workload.
// Call configure_moltenvk() once, before vkCreateInstance(), to push these
// into the MoltenVK layer settings. The layer reads them via the
// VkLayerSettingsCreateInfoEXT extension on the instance chain.
// ---------------------------------------------------------------------------
struct MoltenVKConfig {
    // Full image view swizzle support is required for GXM colour formats
    // (e.g. ABGR vs RGBA) that don't map 1-to-1 to Metal pixel formats.
    bool fullImageViewSwizzle        = true;

    // Allow timestamp queries (needed for performance HUD).
    bool timestampPeriodMicroseconds = true;

    // Synchronise present calls with CAMetalLayer. Setting this to false
    // can improve throughput but may produce tearing on older drivers.
    bool synchronizedPresent         = true;

    // Use Metal's MTLFence for pipeline barriers instead of GPU-side waits
    // where possible — gives ~5 % throughput gain on A-series.
    bool useMTLFenceForBarriers      = true;

    // Number of MTLCommandBuffers in the internal MoltenVK pool.
    // Vita3K submits bursts of command buffers (prerender + render);
    // 8 is a safe pool size that avoids stalls.
    uint32_t commandBufferPoolSize   = 8;

    // Prefer larger Metal render passes (merged sub-passes where possible).
    bool mergeSubpasses              = true;

    // Log only errors on release builds.
#ifdef NDEBUG
    int logLevel = 1; // errors only
#else
    int logLevel = 4; // verbose
#endif
};

/// Apply MoltenVK-specific layer settings to the VkLayerSettingsCreateInfoEXT
/// chain that will be passed to vkCreateInstance.
/// Returns a vector of VkLayerSettingEXT structs (populated with string/bool/
/// int32 values) and updates *pNext to point at the new settings info.
/// The returned vector must remain alive until vkCreateInstance returns.
///
/// Usage:
///   void* layerSettingsPNext = nullptr;
///   auto settings = ios::build_moltenvk_layer_settings(cfg, &layerSettingsPNext);
///   instanceCreateInfo.pNext = layerSettingsPNext;
std::vector<uint8_t> build_moltenvk_layer_settings(
    const MoltenVKConfig& cfg,
    void**                outPNext);

/// Create the VkSurfaceKHR from the CAMetalLayer that platform_init() set up.
/// This is a thin wrapper around vkCreateMetalSurfaceEXT.
/// Returns VK_SUCCESS or a Vulkan error code (cast to int for C++ cleanness).
int create_vulkan_surface(
    void*       vkInstance,  // VkInstance cast to void*
    void**      outSurface,  // VkSurfaceKHR* cast to void**
    const void* allocator);  // const VkAllocationCallbacks* (may be nullptr)

/// Return the list of instance extensions required for the iOS Metal surface.
/// Append these to the list SDL_Vulkan_GetInstanceExtensions() returns.
std::vector<const char*> required_instance_extensions();

/// Return the list of device extensions required / recommended on iOS.
std::vector<const char*> required_device_extensions();

// ---------------------------------------------------------------------------
// Swapchain helpers
// ---------------------------------------------------------------------------

/// Choose the best VkPresentModeKHR for iOS:
///   - VK_PRESENT_MODE_FIFO_KHR on devices without ProMotion
///   - VK_PRESENT_MODE_MAILBOX_KHR on ProMotion panels (A15+)
int choose_present_mode(void* vkPhysicalDevice, void* vkSurface);

/// Return the recommended swapchain image count (2 = double buffer on iOS).
uint32_t recommended_swapchain_image_count();

/// Return the preferred VkSurfaceFormatKHR index from the list.
/// Prefers {VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}.
uint32_t choose_surface_format(const void* formats, uint32_t formatCount);

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Log MoltenVK and Metal capabilities for the current device.
/// Useful for CI / bug reports.
void log_device_capabilities();

} // namespace ios

#endif // TARGET_OS_IOS
