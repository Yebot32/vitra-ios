// Vita3K emulator project — iOS port
// Copyright (C) 2026 Vita3K team / Vitra-iOS contributors
//
// This file is the iOS-optimised version of
// vita3k/renderer/src/vulkan/renderer.cpp
// Differences from upstream:
//   • MoltenVK layer settings injected via VkLayerSettingsCreateInfoEXT
//   • Surface created from CAMetalLayer (not SDL_Vulkan_CreateSurface)
//   • Device selection simplified (single GPU on iOS)
//   • swap_window() calls ios_frame_presented() for frame-pacing accounting
//   • Portability subset extension enabled
//   • ANDROID blocks retained for reference but guarded

// ── Complete MacTypes.h replacement ─────────────────────────────────────
// vita3k/mem/ptr.h defines global `class Ptr<T>`, conflicting with
// MacTypes.h's `typedef char* Ptr`. We suppress MacTypes.h entirely and
// provide every type that Apple's CoreFoundation/CFString/CFBase headers need.
// The two conflicting typedefs (Ptr, Handle) are intentionally omitted.
#ifdef __APPLE__
#define __MACTYPES__

// ── Integer types ────────────────────────────────────────────────────────
typedef unsigned char           UInt8;
typedef unsigned short          UInt16;
typedef unsigned int            UInt32;
typedef unsigned long long      UInt64;
typedef signed char             SInt8;
typedef signed short            SInt16;
typedef signed int              SInt32;
typedef signed long long        SInt64;

// ── Boolean and floating point ───────────────────────────────────────────
typedef unsigned char           Boolean;
typedef float                   Float32;
typedef double                  Float64;

// ── Character types (required by CFString.h) ─────────────────────────────
typedef unsigned short          UniChar;        // UTF-16 code unit
typedef unsigned int            UTF32Char;      // UTF-32 code unit
typedef unsigned short          UTF16Char;      // UTF-16 code unit
typedef unsigned char           UTF8Char;       // UTF-8 code unit
typedef const UniChar *         ConstUniCharPtr;
typedef UInt32                  UniCharCount;

// ── Pascal string types (required by CFString.h) ─────────────────────────
typedef unsigned char *         StringPtr;
typedef const unsigned char *   ConstStringPtr;
typedef unsigned char           Str255[256];
typedef unsigned char           Str63[64];
typedef unsigned char           Str32[33];
typedef unsigned char           Str15[16];
typedef const unsigned char *   ConstStr255Param;
typedef const unsigned char *   ConstStr63Param;
typedef const unsigned char *   ConstStr32Param;

// ── Legacy Mac types ──────────────────────────────────────────────────────
typedef SInt32                  OSStatus;
typedef SInt16                  OSErr;
typedef unsigned int            FourCharCode;
typedef FourCharCode            OSType;
typedef FourCharCode            ResType;
typedef long                    Size;
typedef long                    LogicalAddress;
typedef unsigned long           ByteCount;
typedef unsigned long           ByteOffset;
typedef UInt32                  OptionBits;
typedef UInt32                  ItemCount;
typedef SInt32                  Fixed;
typedef Fixed *                 FixedPtr;
typedef SInt32                  Fract;
typedef SInt32                  ShortFixed;

// Locale types (required by CFLocale.h)
typedef SInt16                  LangCode;
typedef SInt16                  RegionCode;
typedef SInt16                  ScriptCode;

// 'Ptr' (typedef char*) and 'Handle' (typedef Ptr*) intentionally omitted:
// they conflict with vita3k's global class Ptr<T> template.
#endif


// ── Standard Vita3K includes ──────────────────────────────────────────────
#include <renderer/functions.h>
#include <renderer/types.h>
#include <renderer/vulkan/functions.h>
#include <renderer/vulkan/state.h>

#include <config/state.h>
#include <config/version.h>
#include <display/state.h>
#include <shader/spirv_recompiler.h>
#include <util/align.h>
#include <util/log.h>
#include <vkutil/vkutil.h>

#include <SDL3/SDL_vulkan.h>

// ── iOS-specific patch layer ─────────────────────────────────────────────
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IOS
#include "ios/ios_platform.h"
#include "ios/ios_vulkan_bridge.h"
#include "ios/ios_renderer_patch.h"
// MoltenVK public header (provides kMVKMoltenVKDriverLayerName and layer
// setting names without the private MVKConfiguration struct).
#include <MoltenVK/mvk_vulkan.h>
#endif

// ── MoltenVK macOS (desktop) path ────────────────────────────────────────
#if defined(__APPLE__) && !TARGET_OS_IOS
#include <MoltenVK/mvk_vulkan.h>
#endif

// ── Validation layer helpers ──────────────────────────────────────────────
static void debug_log_message(std::string_view msg) {
    static const char *ignored_errors[] = {
        "VUID-vkCmdDrawIndexed-None-02721",
        "VUID-VkImageViewCreateInfo-usage-02275",
        "VUID-VkImageCreateInfo-imageCreateMaxMipLevels-02251",
        "VUID-vkCmdPipelineBarrier-pDependencies-02285",
        "VUID-vkCmdDrawIndexed-None-09003",
        "VUID-vkCmdDrawIndexed-None-06538",
        "VUID-vkCmdDrawIndexed-None-09000",
        "VKDBGUTILWARN003",
        "VK_FORMAT_BC",
        "VUID-vkCmdCopyBufferToImage-dstImage-01997"
    };

    for (auto e : ignored_errors)
        if (msg.find(e) != std::string_view::npos) return;

    LOG_ERROR("Validation layer: {}", msg);
}

static vk::DebugUtilsMessengerEXT debug_messenger;
static VKAPI_ATTR VkBool32 VKAPI_CALL debug_util_callback(
    vk::DebugUtilsMessageSeverityFlagBitsEXT severity,
    vk::DebugUtilsMessageTypeFlagsEXT        type,
    const vk::DebugUtilsMessengerCallbackDataEXT* data,
    void*)
{
    if (severity >= vk::DebugUtilsMessageSeverityFlagBitsEXT::eWarning
     && (type & ~vk::DebugUtilsMessageTypeFlagBitsEXT::ePerformance))
        debug_log_message(data->pMessage);
    return VK_FALSE;
}

static vk::DebugReportCallbackEXT debug_report;
static VKAPI_ATTR VkBool32 VKAPI_CALL debug_report_callback(
    vk::DebugReportFlagsEXT,
    vk::DebugReportObjectTypeEXT objectType,
    uint64_t object, size_t location, int32_t messageCode,
    const char* layerPrefix, const char* message, void*)
{
    debug_log_message(fmt::format(
        "Validation: Vk{}:{}[0x{:X}]:I{}:L{}: {}",
        layerPrefix, vk::to_string(objectType),
        object, messageCode, location, message));
    return VK_FALSE;
}

// Required device extensions (common to all platforms)
static const std::vector<const char*> required_device_extensions_base = {
    vk::KHRSwapchainExtensionName,
    vk::KHRStorageBufferStorageClassExtensionName,
    vk::KHRMaintenance1ExtensionName,
};

namespace renderer::vulkan {

// ============================================================================
// iOS-specific driver version formatting
// ============================================================================
static std::string get_driver_version(uint32_t vendorId, uint32_t raw) {
    if (vendorId == 4318) // NVIDIA
        return fmt::format("{}.{}.{}.{}",
            (raw >> 22) & 0x3ff, (raw >> 14) & 0x0ff,
            (raw >>  6) & 0x0ff,  raw        & 0x003f);
    return fmt::format("{}.{}.{}",
        (raw >> 22) & 0x3ff, (raw >> 12) & 0x3ff, raw & 0xfff);
}

// ============================================================================
// VKState::create — iOS variant
// ============================================================================
bool VKState::create(SDL_Window* window,
                     std::unique_ptr<renderer::State>& state,
                     const Config& config)
{
    auto& vk_state = dynamic_cast<VKState&>(*state);

    // ── 1. Bootstrap Vulkan dispatcher ────────────────────────────────────
    {
        PFN_vkGetInstanceProcAddr vkGIPA =
            reinterpret_cast<PFN_vkGetInstanceProcAddr>(
                SDL_Vulkan_GetVkGetInstanceProcAddr());
        VULKAN_HPP_DEFAULT_DISPATCHER.init(vkGIPA);
    }

    // ── 2. Build instance extension list ─────────────────────────────────
    std::vector<const char*> instance_extensions;
    {
        unsigned int sdlExtCount = 0;
        const char* const* sdlExts = SDL_Vulkan_GetInstanceExtensions(&sdlExtCount);
        instance_extensions.reserve(sdlExtCount + 8);
        for (unsigned i = 0; i < sdlExtCount; ++i)
            instance_extensions.push_back(sdlExts[i]);

#if TARGET_OS_IOS
        // Replace SDL's surface extension with our Metal surface extension
        // and add portability enumeration.
        ios_patch::append_ios_instance_extensions(instance_extensions);
#endif
    }

    // ── 3. Optional instance extensions ──────────────────────────────────
    {
        const std::set<std::string> optional_exts = {
            vk::KHRGetPhysicalDeviceProperties2ExtensionName,
            vk::KHRExternalMemoryCapabilitiesExtensionName,
            vk::KHRDeviceGroupCreationExtensionName,
#if !TARGET_OS_IOS
            vk::KHRPortabilityEnumerationExtensionName,
            vk::EXTLayerSettingsExtensionName,
#endif
        };

        // Build a deduplicated set from what is already in the list so that
        // ios_patch::append_ios_instance_extensions() entries (e.g.
        // VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2) are not added twice.
        // Duplicate extension names cause vkCreateInstance to return
        // VK_ERROR_EXTENSION_NOT_PRESENT on strict MoltenVK builds.
        std::set<std::string> already_added(
            instance_extensions.begin(), instance_extensions.end());

        for (const auto& prop : vk::enumerateInstanceExtensionProperties()) {
            const std::string name(prop.extensionName.data());
            if (optional_exts.count(name) && !already_added.count(name)) {
                instance_extensions.push_back(optional_exts.find(name)->c_str());
                already_added.insert(name);
            }
        }
    }

    // ── 4. Validation layer ───────────────────────────────────────────────
    bool has_validation = false;
    std::string found_debug_ext;
    {
        const std::array<std::string, 2> debug_exts = {
            VK_EXT_DEBUG_UTILS_EXTENSION_NAME,
            VK_EXT_DEBUG_REPORT_EXTENSION_NAME
        };
        for (const auto& prop : vk::enumerateInstanceExtensionProperties()) {
            std::string_view ext(prop.extensionName.data());
            for (const auto& de : debug_exts)
                if (de == ext) found_debug_ext = std::string(ext);
        }
        const std::string val_layer = "VK_LAYER_KHRONOS_validation";
        for (const auto& lp : vk::enumerateInstanceLayerProperties())
            if (std::string_view(lp.layerName.data()) == val_layer)
                has_validation = true;
    }

    std::vector<const char*> instance_layers;
    if (has_validation && !found_debug_ext.empty() && config.validation_layer) {
        LOG_INFO("Enabling Vulkan validation layers");
        instance_layers.push_back("VK_LAYER_KHRONOS_validation");
        instance_extensions.push_back(found_debug_ext.c_str());
    }

    // ── 5. Application info ───────────────────────────────────────────────
    vk::ApplicationInfo app_info{
        .pApplicationName   = app_name,
        .applicationVersion = VK_MAKE_API_VERSION(0, 0, 0, 1),
        .pEngineName        = org_name,
        .engineVersion      = VK_MAKE_API_VERSION(0, 0, 0, 1),
        .apiVersion         = VK_API_VERSION_1_0
    };

    // ── 6. MoltenVK / iOS layer settings ─────────────────────────────────
#if TARGET_OS_IOS
    void* settings_pnext = nullptr;
    // blob must outlive vkCreateInstance
    std::vector<uint8_t> mvk_blob =
        ios_patch::build_moltenvk_settings(&settings_pnext);
#elif defined(__APPLE__)
    // macOS desktop MoltenVK settings (existing code)
    const VkBool32 full_swizzle = VK_TRUE;
    vk::LayerSettingEXT layer_settings[] = {
        { kMVKMoltenVKDriverLayerName,
          "MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE",
          vk::LayerSettingTypeEXT::eBool32, 1, &full_swizzle },
    };
    vk::LayerSettingsCreateInfoEXT layer_settings_info{
        .settingCount = static_cast<uint32_t>(std::size(layer_settings)),
        .pSettings    = layer_settings,
    };
    void* settings_pnext = &layer_settings_info;
#else
    void* settings_pnext = nullptr;
#endif

    // ── 7. vkCreateInstance ───────────────────────────────────────────────
    {
        vk::InstanceCreateInfo inst_info{
#if TARGET_OS_IOS
            .flags  = ios_patch::build_instance_create_flags(),
            .pNext  = settings_pnext,
#elif defined(__APPLE__)
            .flags  = vk::InstanceCreateFlagBits::eEnumeratePortabilityKHR,
            .pNext  = settings_pnext,
#else
            .pNext  = settings_pnext,
#endif
            .pApplicationInfo = &app_info,
        };
        inst_info.setPEnabledLayerNames(instance_layers);
        inst_info.setPEnabledExtensionNames(instance_extensions);

        instance = vk::createInstance(inst_info);
        VULKAN_HPP_DEFAULT_DISPATCHER.init(instance);
    }

    // Debug messenger
    if (has_validation && !found_debug_ext.empty() && config.validation_layer) {
        if (found_debug_ext == VK_EXT_DEBUG_UTILS_EXTENSION_NAME) {
            vk::DebugUtilsMessengerCreateInfoEXT di{
                .messageSeverity =
                    vk::DebugUtilsMessageSeverityFlagBitsEXT::eVerbose
                  | vk::DebugUtilsMessageSeverityFlagBitsEXT::eWarning
                  | vk::DebugUtilsMessageSeverityFlagBitsEXT::eError,
                .messageType =
                    vk::DebugUtilsMessageTypeFlagBitsEXT::eGeneral
                  | vk::DebugUtilsMessageTypeFlagBitsEXT::eValidation
                  | vk::DebugUtilsMessageTypeFlagBitsEXT::ePerformance,
                .pfnUserCallback = debug_util_callback
            };
            debug_messenger = instance.createDebugUtilsMessengerEXT(di);
        }
    }

    // ── 8. Surface ────────────────────────────────────────────────────────
#if TARGET_OS_IOS
    {
        // Use CAMetalLayer-backed surface — SDL_Vulkan_CreateSurface is
        // NOT used on iOS to avoid UIKit threading constraints.
        if (!ios_patch::create_ios_surface(instance,
                                           screen_renderer.surface)) {
            LOG_ERROR("Failed to create Metal surface on iOS.");
            return false;
        }
    }
#else
    if (!screen_renderer.create(window))
        return false;
#endif

    // ── 9. Physical device ────────────────────────────────────────────────
    {
        auto physical_devices = instance.enumeratePhysicalDevices();

#if TARGET_OS_IOS
        // Single GPU on iOS — no need for discrete/integrated preference logic.
        physical_device = ios_patch::select_ios_physical_device(
            instance, physical_devices);
        if (!physical_device) {
            LOG_ERROR("No Vulkan-capable GPU found on this iOS device.");
            return false;
        }
#else
        if (gpu_idx > 0 && gpu_idx <= (int)physical_devices.size()) {
            physical_device = physical_devices[gpu_idx - 1];
        } else {
            for (const auto& dev : physical_devices) {
                using enum vk::PhysicalDeviceType;
                const auto dt = dev.getProperties().deviceType;
                if (!physical_device) physical_device = dev;
                else if (physical_device.getProperties().deviceType != dt
                      && (dt == eDiscreteGpu || dt == eIntegratedGpu))
                    physical_device = dev;
                if (dt == eDiscreteGpu) break;
            }
        }
        if (!physical_device) {
            LOG_ERROR("Failed to select Vulkan physical device.");
            return false;
        }
#endif

        physical_device_properties  = physical_device.getProperties();
        physical_device_features    = physical_device.getFeatures();
        physical_device_memory      = physical_device.getMemoryProperties();
        physical_device_queue_families = physical_device.getQueueFamilyProperties();

        LOG_INFO("Vulkan device: {}", physical_device_properties.deviceName.data());
        LOG_INFO("Driver version: {}",
            get_driver_version(physical_device_properties.vendorID,
                               physical_device_properties.driverVersion));

#if TARGET_OS_IOS
        // Log iOS-specific Metal capabilities for diagnostics
        ::ios::log_device_capabilities();
#endif
    }

    // ── 10. Logical device ────────────────────────────────────────────────
    bool support_dedicated_allocations = false;
    {
        std::vector<vk::DeviceQueueCreateInfo> queue_infos;
        std::vector<std::vector<float>> queue_priorities;

        // Queue selection (unchanged from upstream)
        bool found_graphics = false, found_transfer = false;
        for (uint32_t i = 0;
             i < vk_state.physical_device_queue_families.size(); ++i) {
            const auto& qf = vk_state.physical_device_queue_families[i];
            std::vector<float>& prio = queue_priorities.emplace_back(
                qf.queueCount, 1.0f);

            if (!found_graphics
             && (qf.queueFlags & vk::QueueFlagBits::eGraphics)
             && (qf.queueFlags & vk::QueueFlagBits::eTransfer)
             && vk_state.physical_device.getSurfaceSupportKHR(
                    i, vk_state.screen_renderer.surface)) {
                queue_infos.push_back({
                    .queueFamilyIndex = i,
                    .queueCount       = qf.queueCount,
                    .pQueuePriorities = prio.data()
                });
                vk_state.general_family_index  = i;
                vk_state.transfer_family_index = i;
                found_graphics = found_transfer = true;
            }
            if (found_graphics && found_transfer) break;
        }
        if (!found_graphics) {
            LOG_ERROR("Failed to find a Vulkan graphics queue.");
            return false;
        }

        // Device extensions
        auto device_extensions = ios_patch::get_ios_device_extensions(
            physical_device,
            required_device_extensions_base);

        // Optional extensions
        bool temp_bool = false;
        bool support_global_priority      = false;
        bool support_buffer_device_addr   = false;
        bool support_external_memory      = false;
        bool support_shader_interlock     = false;

        const std::map<std::string_view, bool*> optional_exts = {
            { vk::KHRGetMemoryRequirements2ExtensionName,     &temp_bool },
            { vk::KHRDedicatedAllocationExtensionName,        &support_dedicated_allocations },
            { vk::KHRImageFormatListExtensionName,            &surface_cache.support_image_format_specifier },
            { vk::KHRBufferDeviceAddressExtensionName,        &support_buffer_device_addr },
            { vk::KHRUniformBufferStandardLayoutExtensionName, &support_standard_layout },
            { vk::KHRShaderFloat16Int8ExtensionName,          &support_fsr },
            { vk::EXTFragmentShaderInterlockExtensionName,    &support_shader_interlock },
#ifdef __APPLE__
            { vk::KHRPortabilitySubsetExtensionName,          &temp_bool },
#endif
            { VK_EXT_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_EXTENSION_NAME,
              &support_rasterized_order_access },
        };

        for (const auto& ext : physical_device.enumerateDeviceExtensionProperties()) {
            auto it = optional_exts.find(ext.extensionName.data());
            if (it != optional_exts.end()) {
                *it->second = true;
                device_extensions.push_back(it->first.data());
            }
        }

        // iOS: unified memory — always disable external host memory path
        bool support_memory_mapping = support_buffer_device_addr && support_standard_layout;
#if TARGET_OS_IOS
        // MoltenVK on iOS does not support VK_EXT_external_memory_host.
        // Use DoubleBuffer method (host-coherent shared memory) instead.
        support_memory_mapping = support_memory_mapping; // keep as-is
        support_external_memory = false;
#endif

        supported_mapping_methods_mask = (1 << static_cast<int>(MappingMethod::Disabled));
        if (support_memory_mapping) {
            mapping_method = MappingMethod::DoubleBuffer;
            supported_mapping_methods_mask |=
                (1 << static_cast<int>(MappingMethod::DoubleBuffer))
              | (1 << static_cast<int>(MappingMethod::PageTable));
        }

        // Feature validation for FSR, shader interlock
        support_fsr &= static_cast<bool>(physical_device_features.shaderInt16);
        if (support_fsr) {
            auto props = physical_device.getFeatures2KHR<
                vk::PhysicalDeviceFeatures2,
                vk::PhysicalDeviceShaderFloat16Int8Features>();
            support_fsr = static_cast<bool>(
                props.get<vk::PhysicalDeviceShaderFloat16Int8Features>()
                    .shaderFloat16);
        }

        if (support_rasterized_order_access) {
            auto props = physical_device.getFeatures2KHR<
                vk::PhysicalDeviceFeatures2,
                vk::PhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT>();
            support_rasterized_order_access = static_cast<bool>(
                props.get<vk::PhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT>()
                    .rasterizationOrderColorAttachmentAccess);
            support_shader_interlock = false;
        }

        support_shader_interlock &= static_cast<bool>(
            physical_device_features.fragmentStoresAndAtomics);
        if (support_shader_interlock) {
            auto props = physical_device.getFeatures2KHR<
                vk::PhysicalDeviceFeatures2,
                vk::PhysicalDeviceFragmentShaderInterlockFeaturesEXT>();
            support_shader_interlock = static_cast<bool>(
                props.get<vk::PhysicalDeviceFragmentShaderInterlockFeaturesEXT>()
                    .fragmentShaderSampleInterlock);
            features.support_shader_interlock = support_shader_interlock;
        }

        vk::PhysicalDeviceFeatures enabled_features{
            .depthClamp                    = physical_device_features.depthClamp,
            .fillModeNonSolid              = physical_device_features.fillModeNonSolid,
            .wideLines                     = physical_device_features.wideLines,
            .samplerAnisotropy             = physical_device_features.samplerAnisotropy,
            .occlusionQueryPrecise         = physical_device_features.occlusionQueryPrecise,
            .fragmentStoresAndAtomics      = physical_device_features.fragmentStoresAndAtomics,
            .shaderStorageImageExtendedFormats =
                physical_device_features.shaderStorageImageExtendedFormats,
            .shaderInt16                   = physical_device_features.shaderInt16,
        };

        vk::StructureChain<
            vk::DeviceCreateInfo,
            vk::PhysicalDeviceBufferDeviceAddressFeatures,
            vk::PhysicalDeviceUniformBufferStandardLayoutFeatures,
            vk::PhysicalDeviceShaderFloat16Int8Features,
            vk::PhysicalDeviceFragmentShaderInterlockFeaturesEXT,
            vk::PhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT>
            device_info_chain {
                vk::DeviceCreateInfo{ .pEnabledFeatures = &enabled_features },
                vk::PhysicalDeviceBufferDeviceAddressFeatures{
                    .bufferDeviceAddress = VK_TRUE },
                vk::PhysicalDeviceUniformBufferStandardLayoutFeatures{
                    .uniformBufferStandardLayout = VK_TRUE },
                vk::PhysicalDeviceShaderFloat16Int8Features{
                    .shaderFloat16 = VK_TRUE },
                vk::PhysicalDeviceFragmentShaderInterlockFeaturesEXT{
                    .fragmentShaderSampleInterlock = VK_TRUE },
                vk::PhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT{
                    .rasterizationOrderColorAttachmentAccess = VK_TRUE },
        };

        if (!support_memory_mapping)
            device_info_chain.unlink<vk::PhysicalDeviceBufferDeviceAddressFeatures>();
        if (!support_standard_layout)
            device_info_chain.unlink<vk::PhysicalDeviceUniformBufferStandardLayoutFeatures>();
        if (!support_rasterized_order_access)
            device_info_chain.unlink<vk::PhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT>();
        if (!support_fsr)
            device_info_chain.unlink<vk::PhysicalDeviceShaderFloat16Int8Features>();
        if (!support_shader_interlock)
            device_info_chain.unlink<vk::PhysicalDeviceFragmentShaderInterlockFeaturesEXT>();

        device_info_chain.get().setQueueCreateInfos(queue_infos);
        device_info_chain.get().setPEnabledExtensionNames(device_extensions);

        try {
            device = physical_device.createDevice(device_info_chain.get());
        } catch (vk::NotPermittedError&) {
            for (auto& qi : queue_infos) qi.pNext = nullptr;
            device = physical_device.createDevice(device_info_chain.get());
        }
        VULKAN_HPP_DEFAULT_DISPATCHER.init(device);
    }

    // ── 11. Queues & command pools ────────────────────────────────────────
    general_queue  = device.getQueue(general_family_index,  0);
    transfer_queue = device.getQueue(transfer_family_index, 0);

    {
        vk::CommandPoolCreateInfo gpi{
            .flags            = vk::CommandPoolCreateFlagBits::eResetCommandBuffer,
            .queueFamilyIndex = general_family_index
        };
        vk::CommandPoolCreateInfo tpi{
            .flags            = vk::CommandPoolCreateFlagBits::eTransient,
            .queueFamilyIndex = transfer_family_index
        };
        general_command_pool  = device.createCommandPool(gpi);
        transfer_command_pool = device.createCommandPool(tpi);

        gpi.flags |= vk::CommandPoolCreateFlagBits::eTransient;
        multithread_command_pool = device.createCommandPool(gpi);
    }

    // ── 12. VMA allocator ─────────────────────────────────────────────────
    {
        vma::VulkanFunctions vf{
            .vkGetInstanceProcAddr = VULKAN_HPP_DEFAULT_DISPATCHER.vkGetInstanceProcAddr,
            .vkGetDeviceProcAddr   = VULKAN_HPP_DEFAULT_DISPATCHER.vkGetDeviceProcAddr
        };
        vma::AllocatorCreateInfo ai{
            .flags         = vma::AllocatorCreateFlagBits::eExternallySynchronized,
            .physicalDevice = physical_device,
            .device         = device,
            .pVulkanFunctions = &vf,
            .instance         = instance,
            .vulkanApiVersion = VK_API_VERSION_1_0,
        };
        if (support_dedicated_allocations)
            ai.flags |= vma::AllocatorCreateFlagBits::eKhrDedicatedAllocation;
        if (supported_mapping_methods_mask > 1)
            ai.flags |= vma::AllocatorCreateFlagBits::eBufferDeviceAddress;

        allocator = vma::createAllocator(ai);
        vkutil::init(allocator);
    }

    // ── 13. Default image & buffer ────────────────────────────────────────
    {
        default_buffer = vkutil::Buffer(KiB(4));
        default_buffer.init_buffer(vk::BufferUsageFlagBits::eVertexBuffer);

        default_image = vkutil::Image(1, 1, vk::Format::eR8G8B8A8Unorm);
        default_image.init_image(
            vk::ImageUsageFlagBits::eSampled | vk::ImageUsageFlagBits::eTransferDst);

        vk::CommandBuffer cmd = vkutil::create_single_time_command(
            device, general_command_pool);
        default_image.transition_to(cmd, vkutil::ImageLayout::TransferDst);

        vk::ClearColorValue white{ std::array<float,4>{1,1,1,1} };
        cmd.clearColorImage(default_image.image,
                            vk::ImageLayout::eTransferDstOptimal,
                            white, vkutil::color_subresource_range);
        default_image.transition_to(cmd, vkutil::ImageLayout::StorageImage);
        vkutil::end_single_time_command(device, general_queue,
                                        general_command_pool, cmd);

        vk::SamplerCreateInfo si{
            .magFilter    = vk::Filter::eLinear,
            .minFilter    = vk::Filter::eLinear,
            .mipmapMode   = vk::SamplerMipmapMode::eLinear,
            .addressModeU = vk::SamplerAddressMode::eRepeat,
            .addressModeV = vk::SamplerAddressMode::eRepeat,
            .addressModeW = vk::SamplerAddressMode::eRepeat,
        };
        default_image.sampler = device.createSampler(si);
    }

    // ── 14. Frame objects ─────────────────────────────────────────────────
    for (int i = 0; i < MAX_FRAMES_RENDERING; ++i) {
        FrameObject& frame = frames[i];
        vk::CommandPoolCreateInfo pi{ .queueFamilyIndex = general_family_index };
        frame.render_pool = device.createCommandPool(pi);
        pi.flags = vk::CommandPoolCreateFlagBits::eResetCommandBuffer;
        frame.prerender_pool = device.createCommandPool(pi);
        frame.destroy_queue.init(device);
    }

    // ── 15. Screen renderer setup ─────────────────────────────────────────
#if TARGET_OS_IOS
    // The surface was already created in step 8; just set up the swapchain.
    if (!screen_renderer.setup())
        return false;
    // Override present mode with iOS-optimal choice
    screen_renderer.present_mode =
        static_cast<vk::PresentModeKHR>(
            ::ios::choose_present_mode(
                static_cast<void*>(static_cast<VkPhysicalDevice>(physical_device)),
                static_cast<void*>(static_cast<VkSurfaceKHR>(
                    screen_renderer.surface))));
    LOG_INFO("[iOS] Present mode: {}", vk::to_string(screen_renderer.present_mode));
#else
    if (!screen_renderer.setup())
        return false;
#endif

    support_fsr &= static_cast<bool>(
        screen_renderer.surface_capabilities.supportedUsageFlags
        & vk::ImageUsageFlagBits::eStorage);

    return true;
}

// ============================================================================
// VKState::swap_window — notify iOS frame-pacing on every present
// ============================================================================
void VKState::swap_window(SDL_Window* window) {
    screen_renderer.swap_window();

#if TARGET_OS_IOS
    // Let the platform layer update frame-pacing stats and, if needed,
    // signal throttle to the emulation loop.
    ios_patch::notify_frame_presented();
#endif

    // Pipeline cache save (unchanged from upstream)
    const auto time_s = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (time_s >= pipeline_cache.next_pipeline_cache_save) {
        pipeline_cache.save_pipeline_cache();
        pipeline_cache.next_pipeline_cache_save =
            std::numeric_limits<uint64_t>::max();
    }
}

// ── All remaining VKState methods are unchanged from upstream ────────────
// (VKState::init, late_init, cleanup, render_frame, dump_frame, etc.)
// They are compiled from the shared renderer.cpp; this file provides only
// the iOS-patched create() and swap_window() overrides.

} // namespace renderer::vulkan
