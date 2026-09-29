# tools/gl4es/gl4es_ohos.toolchain.cmake
#
# Wrapper around the OHOS SDK CMake toolchain that presents the target as a
# Linux-like UNIX system. gl4es' src/CMakeLists.txt only compiles the GLX
# sources (glx.c / lookup.c, which provide glXGetProcAddress) when
# CMAKE_SYSTEM_NAME matches "Linux"; the OHOS SDK toolchain sets it to "OHOS",
# which would silently drop those files. Re-presenting the system as Linux keeps
# the compile/link flags, compiler and sysroot from the real OHOS toolchain,
# only changing the *system name*.
#
# Usage:
#   cmake -G Ninja -S <gl4es-src> -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=$PWD/tools/gl4es/gl4es_ohos.toolchain.cmake \
#     -DOHOS_SDK_NATIVE=<sdk/native>
#
# OHOS_SDK_NATIVE must be given via -DOHOS_SDK_NATIVE=<dir> or the $OHOS_SDK_NATIVE env var.
# There is deliberately NO machine-specific default here (base build files stay
# environment-independent; environment binding belongs in the wrapper rebuild_for_meowcraft.sh).

set(OHOS_SDK_NATIVE "$ENV{OHOS_SDK_NATIVE}" CACHE PATH "OHOS SDK native dir")
if(NOT OHOS_SDK_NATIVE)
  message(FATAL_ERROR "OHOS_SDK_NATIVE is not set: pass -DOHOS_SDK_NATIVE=<sdk/native> or set the env var")
endif()

set(OHOS_ARCH "arm64-v8a" CACHE STRING "")
set(OHOS_STL "c++_shared" CACHE STRING "")
if(NOT DEFINED OHOS_PLATFORM_LEVEL)
  set(OHOS_PLATFORM_LEVEL "23" CACHE STRING "")
endif()

include("${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake")

# Re-present as Linux/UNIX so gl4es compiles its glx/* sources.
set(CMAKE_SYSTEM_NAME "Linux")
set(LINUX TRUE)
set(UNIX TRUE)
set(ANDROID FALSE)
