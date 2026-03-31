// ============================================================================
// vita3k/ios/ios_vulkan_bridge.mm
// ============================================================================

#include "ios_vulkan_bridge.h"

#if TARGET_OS_IOS

#include "ios_platform.h"

// MoltenVK public header
#include <MoltenVK/mvk_vulkan.h>

// Vulkan C++ headers (already available via Vita3K's Vulkan dependency)
#define VK_NO_PROTOTYPES
#define VULKAN_HPP_NO_CONSTRUCTORS
#include <vulkan/vulkan.hpp>

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <cassert>
#include <cstring>
#include <string>
#include <vector>

// Bring in the global dynamic dispatcher that Vita3K already sets up
// in vita3k/renderer/src/vulkan/allocator.cpp
VULKAN_HPP_DEFAULT_DISPATCH_LOADER_DYNAMIC_STORAGE_EXTERN

namespace ios {

// ============================================================================
// build_moltenvk_layer_settings
// ============================================================================
// We store scalar values in a flat byte buffer so that the VkLayerSettingEXT
// structs' pValues pointers remain stable for the lifetime of the vector.
// The caller stores the vector and passes *outPNext to vkCreateInstance.
// ============================================================================

// Internal storage block for settings data
struct SettingsBlob {
    VkLayerSettingsCreateInfoEXT info { VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT };
    std::vector<VkLayerSettingEXT> settings;

    // Scalar storage: all booleans (VkBool32) and int32 values live here
    std::vector<VkBool32>  boolStorage;
    std::vector<int32_t>   intStorage;

    // We keep them separate so that push_back doesn't invalidate pointers
    // (we reserve up front).
};

static std::vector<uint8_t> s_blobStorage; // out-of-function lifetime

std::vector<uint8_t> build_moltenvk_layer_settings(
    const MoltenVKConfig& cfg,
    void**                outPNext)
{
    // Use a raw byte buffer large enough to hold the SettingsBlob
    std::vector<uint8_t> storage(sizeof(SettingsBlob), 0);
    auto* blob = new (storage.data()) SettingsBlob;

    // Reserve to avoid invalidating pointers
    blob->boolStorage.reserve(16);
    blob->intStorage.reserve(8);
    blob->settings.reserve(16);

    auto addBool = [&](const char* key, bool value) {
        blob->boolStorage.push_back(value ? VK_TRUE : VK_FALSE);
        VkLayerSettingEXT s{};
        s.pLayerName   = kMVKMoltenVKDriverLayerName;
        s.pSettingName = key;
        s.type         = VK_LAYER_SETTING_TYPE_BOOL32_EXT;
        s.valueCount   = 1;
        s.pValues      = &blob->boolStorage.back();
        blob->settings.push_back(s);
    };

    auto addInt = [&](const char* key, int32_t value) {
        blob->intStorage.push_back(value);
        VkLayerSettingEXT s{};
        s.pLayerName   = kMVKMoltenVKDriverLayerName;
        s.pSettingName = key;
        s.type         = VK_LAYER_SETTING_TYPE_INT32_EXT;
        s.valueCount   = 1;
        s.pValues      = &blob->intStorage.back();
        blob->settings.push_back(s);
    };

    // ----------------------------------------------------------------
    // Critical settings for GXM → Metal translation
    // ----------------------------------------------------------------
    addBool("MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE",          cfg.fullImageViewSwizzle);
    addBool("MVK_CONFIG_SYNCHRONIZE_PRESENT_ON_SUBMIT_BOUNDARY",  cfg.synchronizedPresent);
    addBool("MVK_CONFIG_USE_MTLFENCE_FOR_BARRIERS",        cfg.useMTLFenceForBarriers);
    // Merge Vulkan sub-passes into fewer Metal render passes where safe.
    // (MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS is unrelated — it controls
    // command-buffer pre-allocation, not render-pass merging.)
    addBool("MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", cfg.mergeSubpasses);

    addInt ("MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE",
            static_cast<int32_t>(cfg.commandBufferPoolSize));
    addInt ("MVK_CONFIG_LOG_LEVEL",                        cfg.logLevel);

#ifndef NDEBUG
    addBool("MVK_CONFIG_DEBUG", VK_TRUE);
#endif

    blob->info.settingCount = static_cast<uint32_t>(blob->settings.size());
    blob->info.pSettings    = blob->settings.data();
    blob->info.pNext        = nullptr; // caller may chain further

    if (outPNext) *outPNext = &blob->info;

    s_blobStorage = std::move(storage); // transfer ownership
    return {}; // empty – caller uses outPNext, we manage lifetime globally
}

// ============================================================================
// create_vulkan_surface
// ============================================================================
int create_vulkan_surface(void* vkInstance, void** outSurface, const void* allocator)
{
    auto* instance = reinterpret_cast<VkInstance>(vkInstance);
    auto* surface  = reinterpret_cast<VkSurfaceKHR*>(outSurface);

    CAMetalLayer* layer = (__bridge CAMetalLayer*)ios_get_ca_metal_layer();
    if (!layer) return VK_ERROR_SURFACE_LOST_KHR;

    VkMetalSurfaceCreateInfoEXT createInfo {
        .sType  = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pNext  = nullptr,
        .flags  = 0,
        .pLayer = (__bridge const CAMetalLayer*)layer,
    };

    auto fn = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
        vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT"));

    if (!fn) {
        // Fallback: older MVK versions expose vkCreateMacOSSurfaceMVK
        // but that doesn't apply on iOS — bail.
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    }

    return fn(instance, &createInfo,
              reinterpret_cast<const VkAllocationCallbacks*>(allocator),
              surface);
}

// ============================================================================
// required_instance_extensions
// ============================================================================
std::vector<const char*> required_instance_extensions()
{
    return {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_EXT_METAL_SURFACE_EXTENSION_NAME,
        // Needed for MoltenVK compatibility
        VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
    };
}

// ============================================================================
// required_device_extensions
// ============================================================================
std::vector<const char*> required_device_extensions()
{
    return {
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        VK_KHR_MAINTENANCE1_EXTENSION_NAME,
        VK_KHR_STORAGE_BUFFER_STORAGE_CLASS_EXTENSION_NAME,
        // MoltenVK portability subset (mandatory on Apple platforms)
        VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
    };
}

// ============================================================================
// choose_present_mode
// ============================================================================
int choose_present_mode(void* vkPhysicalDevice, void* vkSurface)
{
    auto gpu     = reinterpret_cast<VkPhysicalDevice>(vkPhysicalDevice);
    auto surface = reinterpret_cast<VkSurfaceKHR>(vkSurface);

    uint32_t count = 0;
    vkGetPhysicalDeviceSurfacePresentModesKHR(gpu, surface, &count, nullptr);
    std::vector<VkPresentModeKHR> modes(count);
    vkGetPhysicalDeviceSurfacePresentModesKHR(gpu, surface, &count, modes.data());

    // Prefer MAILBOX on ProMotion devices (A15 SoC and later)
    bool hasMailbox = std::find(modes.begin(), modes.end(),
                                VK_PRESENT_MODE_MAILBOX_KHR) != modes.end();
    if (hasMailbox) {
        // Only use mailbox if we are actually at 90/120 Hz
        double fps = ios::get_metal_context().displayRefreshRate;
        if (fps > 61.0) return static_cast<int>(VK_PRESENT_MODE_MAILBOX_KHR);
    }

    // FIFO is always available and syncs to vblank — best for battery life
    return static_cast<int>(VK_PRESENT_MODE_FIFO_KHR);
}

// ============================================================================
// recommended_swapchain_image_count
// ============================================================================
uint32_t recommended_swapchain_image_count()
{
    // Double-buffering (2) gives the best latency on iOS.
    // MoltenVK internally may use triple-buffering for Metal drawables,
    // but from the Vulkan perspective 2 is optimal.
    return 2;
}

// ============================================================================
// choose_surface_format
// ============================================================================
uint32_t choose_surface_format(const void* formatsPtr, uint32_t formatCount)
{
    const auto* formats = reinterpret_cast<const VkSurfaceFormatKHR*>(formatsPtr);

    for (uint32_t i = 0; i < formatCount; ++i) {
        if (formats[i].format     == VK_FORMAT_B8G8R8A8_UNORM
         && formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return i;
        }
    }
    // Fallback: first available format
    return 0;
}

// ============================================================================
// log_device_capabilities
// ============================================================================
void log_device_capabilities()
{
    id<MTLDevice> dev = ios::get_metal_context().device;
    if (!dev) return;

    NSLog(@"[Vita3K/iOS] Metal device: %@", dev.name);
    NSLog(@"[Vita3K/iOS] Unified memory: %s",
          ios::has_unified_memory() ? "yes" : "no");
    NSLog(@"[Vita3K/iOS] Recommended MTL storage mode: %s",
          ios::recommended_storage_mode() == MTLStorageModeShared
              ? "Shared" : "Private");

    if (@available(iOS 14.0, *)) {
        NSLog(@"[Vita3K/iOS] Max buffer length: %lu MB",
              (unsigned long)(dev.maxBufferLength / (1024 * 1024)));
    }

    NSLog(@"[Vita3K/iOS] Display refresh rate: %.0f Hz",
          ios::get_metal_context().displayRefreshRate);

    uint32_t w = 0, h = 0;
    ios_get_drawable_size(&w, &h);
    NSLog(@"[Vita3K/iOS] Drawable size: %u x %u px", w, h);
}

} // namespace ios

#endif // TARGET_OS_IOS
