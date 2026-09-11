# tools/sdl/sdl_ohos.toolchain.cmake
#
# Wrapper around the OHOS SDK CMake toolchain that presents the target as a
# Linux-like UNIX system, so SDL3's CMake takes its unix paths (src/core/unix,
# thread/pthread, timer/unix, filesystem/unix, loadso/dlopen) instead of landing
# in the "unknown platform" branch (the OHOS SDK toolchain sets
# CMAKE_SYSTEM_NAME=OHOS, which CMake does not treat as UNIX).
#
# Usage:
#   cmake -G Ninja -S ref/SDL-3.4.14 -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=$PWD/tools/sdl/sdl_ohos.toolchain.cmake
#
# The compile/link flags, compiler paths and sysroot all still come from the
# real OHOS toolchain; only the *system name* is re-presented.

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

# Re-present the target as Linux/unix so SDL (and generic CMake checks) enable
# the unix-like backends. The actual compiler target stays aarch64-linux-ohos.
set(CMAKE_SYSTEM_NAME "Linux")
set(LINUX TRUE)
set(UNIX TRUE)
set(ANDROID FALSE)
