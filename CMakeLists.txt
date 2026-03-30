# ============================================================================
# vita3k/ios/CMakeLists.txt
# Compiled only when CMAKE_SYSTEM_NAME is iOS (set by the toolchain file).
# ============================================================================
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    return()
endif()

# ── Source files ─────────────────────────────────────────────────────────────
set(IOS_SOURCES
    ios_platform.mm          # Metal context, frame pacing, thermal management
    ios_vulkan_bridge.mm     # MoltenVK layer settings + CAMetalLayer surface
    ios_renderer.cpp         # iOS-patched Vulkan renderer (create + swap_window)
)

set(IOS_HEADERS
    ios_platform.h
    ios_vulkan_bridge.h
    ios_renderer_patch.h
)

# ── Library ───────────────────────────────────────────────────────────────────
add_library(vita3k_ios STATIC ${IOS_SOURCES} ${IOS_HEADERS})

# ── Language settings ─────────────────────────────────────────────────────────
# The .mm files need ObjC++ ARC.
set_source_files_properties(
    ios_platform.mm
    ios_vulkan_bridge.mm
    PROPERTIES
        COMPILE_FLAGS "-fobjc-arc -fmodules"
)

# ── Include directories ───────────────────────────────────────────────────────
target_include_directories(vita3k_ios
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/..  # so #include "ios/ios_platform.h" works
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
)

# ── Frameworks & libraries ────────────────────────────────────────────────────
target_link_libraries(vita3k_ios
    PUBLIC
        "-framework Metal"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework UIKit"
        "-framework Foundation"
        MoltenVK          # provided by external/MoltenVK or system SDK
    PRIVATE
        renderer          # the main Vita3K renderer target
        util
)

# ── Deployment target ─────────────────────────────────────────────────────────
set_target_properties(vita3k_ios PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.vita3k.ios"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"           # not needed for iOS 16+
    XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL "-O" # N/A but harmless
)

# ── Compile definitions ───────────────────────────────────────────────────────
target_compile_definitions(vita3k_ios
    PUBLIC
        TARGET_OS_IOS=1
        VITA3K_IOS=1
)

# Enable 120 Hz ProMotion support (requires entitlement on device)
target_compile_definitions(vita3k_ios
    PRIVATE
        VITA3K_IOS_PROMO_DISPLAY=1
)
