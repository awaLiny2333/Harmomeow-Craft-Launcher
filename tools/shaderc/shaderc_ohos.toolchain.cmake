# tools/shaderc/shaderc_ohos.toolchain.cmake
#
# Wrapper around the OHOS SDK CMake toolchain that presents the target as a
# Linux-like UNIX system. shaderc/glslang/SPIRV-Tools/SPIRV-Cross all contain
# generic "if(UNIX)/if(CMAKE_SYSTEM_NAME STREQUAL Linux)" branches and also do
# try_compile sanity checks that dislike the bare "OHOS" system name the SDK
# toolchain reports. Re-labelling the system as Linux keeps those checks and
# branches happy while the compiler, sysroot and link flags still come from the
# real OHOS toolchain, so the actual target stays aarch64-linux-ohos.
#
# Usage:
#   cmake -G Ninja -S <src> -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=$PWD/tools/shaderc/shaderc_ohos.toolchain.cmake

set(OHOS_SDK_NATIVE "$ENV{OHOS_SDK_NATIVE}" CACHE PATH "OHOS SDK native dir")
if(NOT OHOS_SDK_NATIVE)
  set(OHOS_SDK_NATIVE "$ENV{HOME}/devecow/deveco_tools/sdk/default/openharmony/native" CACHE PATH "" FORCE)
endif()

set(OHOS_ARCH "arm64-v8a" CACHE STRING "")
set(OHOS_STL "c++_shared" CACHE STRING "")
if(NOT DEFINED OHOS_PLATFORM_LEVEL)
  set(OHOS_PLATFORM_LEVEL "23" CACHE STRING "")
endif()

include("${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake")

# Re-present the target as Linux/unix. The compiler target stays
# aarch64-linux-ohos; only CMAKE_SYSTEM_NAME and the platform flags change.
set(CMAKE_SYSTEM_NAME "Linux")
set(LINUX TRUE)
set(UNIX TRUE)
set(ANDROID FALSE)
