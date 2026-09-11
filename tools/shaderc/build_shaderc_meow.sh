#!/bin/sh
# Build Meowcraft's OHOS aarch64 (musl, libc++_shared) copies of:
#   * libshaderc.so      <- google/shaderc (target shaderc_shared)
#   * libspirv-cross.so  <- KhronosGroup/SPIRV-Cross (target spirv-cross-c-shared)
#
# These are drop-in replacements for the LWJGL 3.4.3 natives used by Minecraft's
# renderpearl path:
#   org.lwjgl.util.shaderc.Shaderc -> libshaderc.so
#   org.lwjgl.util.spvc.Spvc       -> libspirv-cross.so
#
# Standalone: every path is passed in, nothing is derived from the caller's
# layout. The upstream source trees are never modified; dependency trees are
# wired into shaderc's build through SHADERC_*_DIR cache variables.
#
# Usage:
#   sh build_shaderc_meow.sh --src DIR --sdk-native DIR --out DIR \
#       [--glslang DIR] [--spirv-tools DIR] [--spirv-headers DIR] \
#       [--spirv-cross DIR] [--build DIR] [--api N] [--arch NAME] \
#       [--only shaderc|spirv-cross|both] [--toolchain FILE]
#
# Required:
#   --src DIR          google/shaderc source tree (pinned revision)
#   --sdk-native DIR   OHOS SDK native dir (build/cmake/ohos.toolchain.cmake,
#                      llvm/, sysroot/)
#   --out DIR          output dir; receives libshaderc.so and libspirv-cross.so
#
# Optional:
#   --glslang DIR      glslang source (default: sibling 'glslang' of --src)
#   --spirv-tools DIR  SPIRV-Tools source (default: sibling 'SPIRV-Tools')
#   --spirv-headers DIR SPIRV-Headers source (default: sibling 'SPIRV-Headers')
#   --spirv-cross DIR  SPIRV-Cross source (default: sibling 'spirv-cross')
#   --build DIR        out-of-tree build root (default: <out>/../build-shaderc-meow)
#   --api N            OHOS platform level (default: 23)
#   --arch NAME        OHOS arch (default: arm64-v8a)
#   --only WHICH       build only 'shaderc', 'spirv-cross' or 'both' (default both)
#   --toolchain FILE   CMake toolchain wrapper (default: shaderc_ohos.toolchain.cmake here)
#   -h, --help         show this help
#
# Requires: cmake, ninja, python3. The toolchain wrapper survives the OHOS SDK's
# bare CMAKE_SYSTEM_NAME=OHOS by re-presenting the target as Linux/unix while the
# compiler stays aarch64-linux-ohos.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
}

SRC=""
SDK_NATIVE=""
OUT=""
BUILD=""
GLSLANG=""
SPIRV_TOOLS=""
SPIRV_HEADERS=""
SPIRV_CROSS=""
TOOLCHAIN="$HERE/shaderc_ohos.toolchain.cmake"
API=23
ARCH=arm64-v8a
ONLY=both

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)           SRC="$2"; shift 2 ;;
    --sdk-native)    SDK_NATIVE="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    --build)         BUILD="$2"; shift 2 ;;
    --glslang)       GLSLANG="$2"; shift 2 ;;
    --spirv-tools)   SPIRV_TOOLS="$2"; shift 2 ;;
    --spirv-headers) SPIRV_HEADERS="$2"; shift 2 ;;
    --spirv-cross)   SPIRV_CROSS="$2"; shift 2 ;;
    --toolchain)     TOOLCHAIN="$2"; shift 2 ;;
    --api)           API="$2"; shift 2 ;;
    --arch)          ARCH="$2"; shift 2 ;;
    --only)          ONLY="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ]        || { echo "error: --src is required" >&2; usage >&2; exit 2; }
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]        || { echo "error: --out is required" >&2; usage >&2; exit 2; }
case "$ONLY" in shaderc|spirv-cross|both) ;; *) echo "error: --only must be shaderc|spirv-cross|both" >&2; exit 2 ;; esac

SRC="$(cd "$SRC" && pwd)"
GLSLANG="${GLSLANG:-$(dirname "$SRC")/glslang}"
SPIRV_TOOLS="${SPIRV_TOOLS:-$(dirname "$SRC")/SPIRV-Tools}"
SPIRV_HEADERS="${SPIRV_HEADERS:-$(dirname "$SRC")/SPIRV-Headers}"
SPIRV_CROSS="${SPIRV_CROSS:-$(dirname "$SRC")/spirv-cross}"

# Reproducibility: SPIRV-Cross's CMakeLists embeds `string(TIMESTAMP …)` into
# gitversion.h, which is compiled into the library (.rodata) + the build-id, so a
# plain build differs on every run. CMake's string(TIMESTAMP) honours
# SOURCE_DATE_EPOCH, so pin it to the pinned SPIRV-Cross commit time (deterministic)
# unless the caller already set SOURCE_DATE_EPOCH.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  sde="$(git -C "$SPIRV_CROSS" show -s --format=%ct HEAD 2>/dev/null || true)"
  [ -n "$sde" ] && export SOURCE_DATE_EPOCH="$sde"
fi

TOOLCHAIN_REAL="$SDK_NATIVE/build/cmake/ohos.toolchain.cmake"
STRIP="$SDK_NATIVE/llvm/bin/llvm-strip"
NM="$SDK_NATIVE/llvm/bin/llvm-nm"
READELF="$SDK_NATIVE/llvm/bin/llvm-readelf"

[ -f "$SRC/CMakeLists.txt" ] && grep -q "project(shaderc)" "$SRC/CMakeLists.txt" \
  || { echo "error: not a shaderc tree: $SRC" >&2; exit 2; }
[ -f "$TOOLCHAIN_REAL" ] || { echo "error: OHOS toolchain not found: $TOOLCHAIN_REAL" >&2; exit 2; }
[ -f "$TOOLCHAIN" ]      || { echo "error: toolchain wrapper not found: $TOOLCHAIN" >&2; exit 2; }

if [ "$ONLY" != "spirv-cross" ]; then
  [ -f "$GLSLANG/CMakeLists.txt" ]       || { echo "error: glslang tree not found: $GLSLANG" >&2; exit 2; }
  [ -f "$SPIRV_TOOLS/CMakeLists.txt" ]   || { echo "error: SPIRV-Tools tree not found: $SPIRV_TOOLS" >&2; exit 2; }
  [ -f "$SPIRV_HEADERS/CMakeLists.txt" ] || { echo "error: SPIRV-Headers tree not found: $SPIRV_HEADERS" >&2; exit 2; }
fi
if [ "$ONLY" != "shaderc" ]; then
  [ -f "$SPIRV_CROSS/CMakeLists.txt" ] && grep -q "spirv-cross" "$SPIRV_CROSS/CMakeLists.txt" \
    || { echo "error: not a SPIRV-Cross tree: $SPIRV_CROSS" >&2; exit 2; }
fi

export OHOS_SDK_NATIVE="$SDK_NATIVE"

[ -n "$BUILD" ] || BUILD="$(cd "$OUT/.." 2>/dev/null && pwd)/build-shaderc-meow"
mkdir -p "$OUT" "$BUILD"

# Allowed DT_NEEDED for a self-contained OHOS drop-in. libm/libdl are tolerated.
needed_ok() {
  case "$1" in
    libc++_shared.so|libc.so|libm.so|libdl.so) return 0 ;;
    *) return 1 ;;
  esac
}

check_needed() {
  lib="$1"
  [ -x "$READELF" ] || return 0
  NEEDED=$("$READELF" -d "$lib" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
  [ -n "$NEEDED" ] || { echo "error: no DT_NEEDED in $lib" >&2; exit 1; }
  for dep in $NEEDED; do
    needed_ok "$dep" || { echo "error: unexpected DT_NEEDED '$dep' in $lib" >&2; exit 1; }
  done
  echo "  DT_NEEDED: $(echo $NEEDED | tr '\n' ' ')"
}

report() {
  lib="$1"; shift
  [ -x "$NM" ] || return 0
  for sym in "$@"; do
    n=$("$NM" -D --defined-only "$lib" 2>/dev/null | grep -c " $sym$" || true)
    [ "$n" -ge 1 ] || { echo "error: export '$sym' missing from $lib" >&2; exit 1; }
  done
  total=$("$NM" -D --defined-only "$lib" 2>/dev/null | wc -l)
  echo "  required exports present; $total dynamic symbols defined"
}

if [ "$ONLY" != "spirv-cross" ]; then
  echo "=== shaderc: configure ($ARCH, api $API) ==="
  rm -rf "$BUILD/shaderc"
  cmake -G Ninja -S "$SRC" -B "$BUILD/shaderc" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DOHOS_SDK_NATIVE="$SDK_NATIVE" \
    -DOHOS_ARCH="$ARCH" -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL="$API" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSHADERC_GLSLANG_DIR="$GLSLANG" \
    -DSHADERC_SPIRV_TOOLS_DIR="$SPIRV_TOOLS" \
    -DSHADERC_SPIRV_HEADERS_DIR="$SPIRV_HEADERS" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_EXECUTABLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSHADERC_ENABLE_SHARED_CRT=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
    -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DGLSLANG_TESTS=OFF

  echo "=== shaderc: build ==="
  ninja -C "$BUILD/shaderc" shaderc_shared

  SO="$(ls "$BUILD/shaderc/libshaderc/libshaderc_shared.so".[0-9]* 2>/dev/null | sort | tail -1)"
  [ -n "$SO" ] && [ -f "$SO" ] || { echo "error: libshaderc_shared.so not produced" >&2; exit 1; }
  [ -x "$STRIP" ] && "$STRIP" --strip-unneeded "$SO"
  cp -L "$SO" "$OUT/libshaderc.so"
  echo "=== shaderc: verify ==="
  check_needed "$OUT/libshaderc.so"
  report "$OUT/libshaderc.so" shaderc_compiler_initialize shaderc_compile_into_spv shaderc_compile_options_initialize
  echo "OK -> $OUT/libshaderc.so ($(wc -c < "$OUT/libshaderc.so") bytes)"
  sha256sum "$OUT/libshaderc.so"
fi

if [ "$ONLY" != "shaderc" ]; then
  echo "=== spirv-cross: configure ($ARCH, api $API) ==="
  rm -rf "$BUILD/spirv-cross"
  cmake -G Ninja -S "$SPIRV_CROSS" -B "$BUILD/spirv-cross" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DOHOS_SDK_NATIVE="$SDK_NATIVE" \
    -DOHOS_ARCH="$ARCH" -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL="$API" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SHARED=ON \
    -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_WERROR=OFF

  echo "=== spirv-cross: build ==="
  ninja -C "$BUILD/spirv-cross" spirv-cross-c-shared

  SO="$(ls "$BUILD/spirv-cross/libspirv-cross-c-shared.so".[0-9]* 2>/dev/null | sort | tail -1)"
  [ -n "$SO" ] && [ -f "$SO" ] || { echo "error: libspirv-cross-c-shared.so not produced" >&2; exit 1; }
  [ -x "$STRIP" ] && "$STRIP" --strip-unneeded "$SO"
  cp -L "$SO" "$OUT/libspirv-cross.so"
  echo "=== spirv-cross: verify ==="
  check_needed "$OUT/libspirv-cross.so"
  report "$OUT/libspirv-cross.so" spvc_context_create spvc_compiler_create_compiler_options
  echo "OK -> $OUT/libspirv-cross.so ($(wc -c < "$OUT/libspirv-cross.so") bytes)"
  sha256sum "$OUT/libspirv-cross.so"
fi
