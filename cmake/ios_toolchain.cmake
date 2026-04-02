# iOS Toolchain for CMake

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphoneos)

# arm64 only — all supported devices (A9+) are arm64.
# No fat/universal slice needed for device builds.
set(CMAKE_OSX_ARCHITECTURES "arm64")

# Bitcode is deprecated as of Xcode 14 and must NOT be enabled.
# vita3k_ios already sets XCODE_ATTRIBUTE_ENABLE_BITCODE "NO".
# Do NOT add -fembed-bitcode here — it conflicts with that setting
# and causes "invalid argument" linker errors on Xcode 14+.
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE "NO")

# Optimise for size on device builds (-Os); improves IPA size and cache usage.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Os")

# C++20 is required by dynarmic (biscuit / fmt).
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
