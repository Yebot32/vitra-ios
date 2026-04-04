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
    ios_overlay.mm           # On-screen PS Vita controller (ImGui draw lists + SDL virtual joystick)
)

set(IOS_HEADERS
    ios_platform.h
    ios_vulkan_bridge.h
    ios_renderer_patch.h
    ios_overlay.h
)

# ── App icon asset catalog ────────────────────────────────────────────────────
set(IOS_ASSET_CATALOG
    ${CMAKE_CURRENT_SOURCE_DIR}/Assets.xcassets
)

# ── Info.plist ────────────────────────────────────────────────────────────────
set(IOS_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist)

# ── Library ───────────────────────────────────────────────────────────────────
add_library(vita3k_ios STATIC ${IOS_SOURCES} ${IOS_HEADERS})

# ── Language settings ─────────────────────────────────────────────────────────
# The .mm files need ObjC++ ARC.
set_source_files_properties(
    ios_platform.mm
    ios_vulkan_bridge.mm
    ios_overlay.mm
    PROPERTIES
        COMPILE_FLAGS "-fobjc-arc -fmodules"
)

# ── Include directories ───────────────────────────────────────────────────────
target_include_directories(vita3k_ios
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/..  # so #include "ios/ios_platform.h" works
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_SOURCE_DIR}/external/concurrentqueue  # blockingconcurrentqueue.h for ios_renderer.cpp
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
        SDL3::SDL3        # SDL3/SDL_vulkan.h + SDL3/SDL_joystick.h etc.
        gui               # gui/state.h
        util
        touch             # handle_touch_event forwarding
        imgui             # overlay draw lists
)

# ── Deployment target ─────────────────────────────────────────────────────────
set_target_properties(vita3k_ios PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.vitra.app"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
    XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL "-O"
    # Icon & branding
    MACOSX_BUNDLE_BUNDLE_NAME "Vitra"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_INFO_PLIST "${IOS_PLIST}"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.vitra.app"
    XCODE_ATTRIBUTE_PRODUCT_NAME "Vitra"
    RESOURCE "${IOS_ASSET_CATALOG}"
    # Entitlements (ProMotion + JIT + iCloud)
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/Vitra.entitlements"
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
