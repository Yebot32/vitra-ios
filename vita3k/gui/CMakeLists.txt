set(GUI_SOURCES
	include/gui/functions.h
	include/gui/imgui_impl_sdl_gl3.h
	include/gui/imgui_impl_sdl_state.h
	include/gui/imgui_impl_sdl_vulkan.h
	include/gui/imgui_impl_sdl.h
	include/gui/state.h
	src/app_context_menu.cpp
	src/archive_install_dialog.cpp
	src/bgm_player.cpp
	src/common_dialog.cpp
	src/compile_shaders.cpp
	src/condvars_dialog.cpp
	src/content_manager.cpp
	src/eventflags_dialog.cpp
	src/firmware_install_dialog.cpp
	src/gui.cpp
	src/home_screen.cpp
	src/ime.cpp
	src/imgui_impl_sdl_gl3.cpp
	src/imgui_impl_sdl_vulkan.cpp
	src/imgui_impl_sdl.cpp
	src/information_bar.cpp
	src/initial_setup.cpp
	src/license_install_dialog.cpp
	src/live_area.cpp
	src/main_menubar.cpp
	src/manual.cpp
	src/mutexes_dialog.cpp
	src/pkg_install_dialog.cpp
	src/private.h
	src/reinstall.cpp
	src/semaphores_dialog.cpp
	src/settings.cpp
	src/settings_dialog.cpp
	src/themes.cpp
	src/threads_dialog.cpp
	src/trophy_collection.cpp
	src/user_management.cpp
	src/overlay_dialog.cpp
	src/controls_dialog.cpp
	src/controllers_dialog.cpp
	src/allocations_dialog.cpp
	src/disassembly_dialog.cpp
	src/trophy_unlocked.cpp
	src/about_dialog.cpp
	src/vita3k_update.cpp
	src/welcome_dialog.cpp
)

# Add macOS-specific Objective-C++ files
if(APPLE)
	if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
		# perf_overlay.cpp includes ios_platform.h (ObjC) so must be compiled as ObjC++
		list(APPEND GUI_SOURCES src/perf_overlay.mm)
		set_source_files_properties(src/perf_overlay.mm PROPERTIES
			COMPILE_FLAGS "-fobjc-arc -fmodules")
	else()
		list(APPEND GUI_SOURCES
			src/perf_overlay.cpp
			include/gui/macos_helper.h
			src/macos_helper.mm
		)
	endif()
else()
	list(APPEND GUI_SOURCES src/perf_overlay.cpp)
endif()

add_library(gui STATIC ${GUI_SOURCES})

target_include_directories(gui PUBLIC include ${CMAKE_SOURCE_DIR}/vita3k)
target_link_libraries(gui PUBLIC app codec compat config dialog emuenv ime imgui lang regmgr np)
target_link_libraries(gui PRIVATE audio camera cubeb cppcommon ctrl kernel miniz motion psvpfsparser pugixml::pugixml stb renderer packages SDL3::SDL3 touch vkutil host::dialog concurrentqueue)

# Force C++20 on this target so std::construct_at and other C++20 stdlib features
# are available. Without this, Xcode's ALL_BUILD scheme may compile gui with
# an older standard causing `no matching function for call to 'construct_at'`.
set_target_properties(gui PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set_target_properties(gui PROPERTIES
        XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
        XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
        XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
    )
    # _LIBCPP_DISABLE_AVAILABILITY bypasses libc++ availability guards so
    # C++20 features like std::construct_at compile regardless of SDK version checks.
    target_compile_definitions(gui PRIVATE _LIBCPP_DISABLE_AVAILABILITY)
endif()
# Link macOS frameworks for Objective-C++ code
if(APPLE)
	target_link_libraries(gui PRIVATE
		"-framework Foundation"
		"-framework ImageIO"
		"-framework UniformTypeIdentifiers"
	)
elseif(ANDROID)
	target_link_libraries(gui PRIVATE android)
endif()
if(TRACY_ENABLE_ON_CORE_COMPONENTS)
	target_link_libraries(gui PUBLIC tracy)
endif()
