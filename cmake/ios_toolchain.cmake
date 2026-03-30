# iOS Toolchain for CMake

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT iphoneos)

# Include Metal framework
set(METAL_FRAMEWORK Metal)
set(CMAKE_XCODE_ATTRIBUTE_OTHER_CPLUSPLUSFLAGS "-fembed-bitcode") # Enable bitcode

# Set architectures: arm64
set(CMAKE_OSX_ARCHITECTURES "arm64")

# Additional flags for iOS optimization
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Os")
