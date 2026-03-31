// ============================================================================
// vita3k/ios/ios_renderer_patch.h
// ============================================================================
// Inline helpers that are #included by vita3k/renderer/src/vulkan/renderer.cpp
// when compiling for iOS. They replace platform-specific snippets:
//
//  1. Instance creation — inject MoltenVK layer settings and iOS extensions
//  2. Surface creation  — use ios::create_vulkan_surface() instead of SDL
//  3. Device selection  — single GPU on iOS, skip enumeration logic
//  4. Swapchain config  — double-buffer, FIFO/MAILBOX, optimal format
//
// The patch is applied as:
//   #if TARGET_OS_IOS
//   #include "ios/ios_renderer_patch.h"
//   #endif
// at the top of renderer.cpp (after all other includes).
// ============================================================================
#pragma once

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IOS

#include "ios_platform.h"
#include "ios_vulkan_bridge.h"

#include <MoltenVK/mvk_vulkan.h>

#define VK_NO_PROTOTYPES
#define VULKAN_HPP_NO_CONSTRUCTORS
#include <vulkan/vulkan.hpp>

#include <vector>
#include <string>

namespace renderer::vulkan::ios_patch {

// ---------------------------------------------------------------------------
// append_ios_instance_extensions
// ---------------------------------------------------------------------------
/// Append the iOS/MoltenVK mandatory extensions to an existing list.
/// Call this right after SDL_Vulkan_GetInstanceExtensions().
inline void append_ios_instance_extensions(std::vector<const char*>& exts)
{
    // Remove the portability enumeration extension if SDL already added it
    // (prevents duplicate entries causing validation errors)
    exts.erase(
        std::remove_if(exts.begin(), exts.end(), [](const char* s) {
            return s && std::string_view(s) ==
                        VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        }),
        exts.end());

    for (const char* ext : ::ios::required_instance_extensions()) {
        bool already = false;
        for (const char* e : exts) {
            if (e && std::string_view(e) == ext) { already = true; break; }
        }
        if (!already) exts.push_back(ext);
    }
}

// ---------------------------------------------------------------------------
// build_instance_create_flags
// ---------------------------------------------------------------------------
/// Returns the VkInstanceCreateFlags required on iOS (portability enumeration).
inline vk::InstanceCreateFlags build_instance_create_flags()
{
    return vk::InstanceCreateFlagBits::eEnumeratePortabilityKHR;
}

// ---------------------------------------------------------------------------
// build_moltenvk_settings
// ---------------------------------------------------------------------------
/// Build MoltenVK layer settings and update *pNext.
/// Keep the returned blob alive until vkCreateInstance returns.
inline std::vector<uint8_t> build_moltenvk_settings(void** outPNext)
{
    ::ios::MoltenVKConfig cfg;
    // Tune for the Vita3K workload:
    cfg.fullImageViewSwizzle      = true;  // Required for GXM colour swizzles
    cfg.synchronizedPresent       = true;  // Prevents tearing
    cfg.useMTLFenceForBarriers    = true;  // ~5 % throughput gain on A-series
    cfg.mergeSubpasses            = true;  // Reduce render-pass overhead
    cfg.commandBufferPoolSize     = 8;     // prerender + render burst pattern
    return ::ios::build_moltenvk_layer_settings(cfg, outPNext);
}

// ---------------------------------------------------------------------------
// create_ios_surface
// ---------------------------------------------------------------------------
/// Create VkSurfaceKHR from the iOS CAMetalLayer.
/// Returns true on success and stores the surface in *outSurface.
inline bool create_ios_surface(vk::Instance instance, vk::SurfaceKHR& outSurface)
{
    VkSurfaceKHR raw = VK_NULL_HANDLE;
    int result = ::ios::create_vulkan_surface(
        static_cast<void*>(static_cast<VkInstance>(instance)),
        reinterpret_cast<void**>(&raw),
        nullptr);

    if (result != VK_SUCCESS) return false;
    outSurface = vk::SurfaceKHR(raw);
    return true;
}

// ---------------------------------------------------------------------------
// select_ios_physical_device
// ---------------------------------------------------------------------------
/// On iOS there is exactly one GPU. Just take the first one that is compatible.
inline vk::PhysicalDevice select_ios_physical_device(
    vk::Instance                         instance,
    const std::vector<vk::PhysicalDevice>& devices)
{
    for (const auto& dev : devices) {
        auto props = dev.getProperties();
        // On iOS the device type is typically eIntegratedGpu
        if (props.deviceType == vk::PhysicalDeviceType::eIntegratedGpu
         || props.deviceType == vk::PhysicalDeviceType::eOther) {
            return dev;
        }
    }
    return devices.empty() ? vk::PhysicalDevice{} : devices[0];
}

// ---------------------------------------------------------------------------
// get_ios_device_extensions
// ---------------------------------------------------------------------------
/// Return the required device extensions for iOS, filtered to those actually
/// available on `physicalDevice`.
inline std::vector<const char*> get_ios_device_extensions(
    vk::PhysicalDevice physicalDevice,
    const std::vector<const char*>& baseExtensions)
{
    auto available = physicalDevice.enumerateDeviceExtensionProperties();

    // Seed with base extensions and track what is already present so we
    // never pass duplicate names to vkCreateDevice (undefined behaviour /
    // VK_ERROR_EXTENSION_NOT_PRESENT on strict drivers / MoltenVK).
    std::vector<const char*> result = baseExtensions;
    std::set<std::string_view> seen;
    for (const char* e : result) if (e) seen.insert(e);

    for (const char* req : ::ios::required_device_extensions()) {
        if (!req || seen.count(req)) continue;

        // Verify the extension is actually exposed by this physical device.
        for (const auto& avail : available) {
            if (std::string_view(avail.extensionName.data()) == req) {
                result.push_back(req);
                seen.insert(req);
                break;
            }
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// get_ios_present_mode
// ---------------------------------------------------------------------------
inline vk::PresentModeKHR get_ios_present_mode(
    vk::PhysicalDevice physicalDevice,
    vk::SurfaceKHR     surface)
{
    int raw = ::ios::choose_present_mode(
        static_cast<void*>(static_cast<VkPhysicalDevice>(physicalDevice)),
        static_cast<void*>(static_cast<VkSurfaceKHR>(surface)));
    return static_cast<vk::PresentModeKHR>(raw);
}

// ---------------------------------------------------------------------------
// get_ios_swapchain_image_count
// ---------------------------------------------------------------------------
inline uint32_t get_ios_swapchain_image_count()
{
    return ::ios::recommended_swapchain_image_count(); // 2
}

// ---------------------------------------------------------------------------
// notify_frame_presented
// ---------------------------------------------------------------------------
/// Call this at the end of VKState::swap_window() on iOS.
inline void notify_frame_presented()
{
    ios_frame_presented();
}

// ---------------------------------------------------------------------------
// should_throttle
// ---------------------------------------------------------------------------
/// True when thermal pressure requires skipping non-essential GPU work.
inline bool should_throttle()
{
    return ::ios::get_frame_pacing().throttleRequested.load();
}

} // namespace renderer::vulkan::ios_patch

#endif // TARGET_OS_IOS
