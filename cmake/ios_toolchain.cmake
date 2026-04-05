# iOS Toolchain for CMake

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphoneos)

# Deployment target — must be set here so ALL targets (gui, modules, etc.)
# get the right IPHONEOS_DEPLOYMENT_TARGET, enabling C++20 stdlib features
# like std::construct_at which require iOS 14+.
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0")
set(CMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0")

# arm64 only — all supported devices (A9+) are arm64.
set(CMAKE_OSX_ARCHITECTURES "arm64")

# Bitcode is deprecated as of Xcode 14.
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE "NO")

# C++20 is required by dynarmic (biscuit / fmt) and for std::construct_at.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Define TARGET_OS_IOS=1 globally so ALL translation units in the build
# (gui, modules, renderer, etc.) can use #if TARGET_OS_IOS guards.
# Without this, only vita3k_ios.cmake sets it, leaving other targets unaware.
add_compile_definitions(TARGET_OS_IOS=1 VITA3K_IOS=1)
