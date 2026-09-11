#!/bin/sh
# Build Meowcraft's OHOS port of SDL3 (libSDL3.so) with the native "ohos"
# video driver enabled.
#
# Standalone: every path is passed in, nothing is derived from the caller's
# layout. The source tree is patched in place by patch_sdl_ohos.py, so pass a
# throwaway checkout/worktree (the project wrapper uses ref/SDL-3.4.14).
#
# Usage:
#   sh build_sdl_meow.sh --src DIR --sdk-native DIR --out DIR \
#       [--build DIR] [--api N] [--arch NAME] [--patcher FILE]
#
# Required:
#   --src DIR         SDL3 source tree at the target tag
#   --sdk-native DIR  OHOS SDK native dir (has build/cmake/ohos.toolchain.cmake,
#                     llvm/, sysroot/ with libEGL.so and native_window/)
#   --out DIR         output dir; receives libSDL3.so
#
# Optional:
#   --build DIR       out-of-tree build dir (default: <src>/../build-sdl-meow)
#   --patcher FILE    SDL patch script (default: patch_sdl_ohos.py next to this script)
#   --api N           OHOS platform level (default: 23)
#   --arch NAME       OHOS arch (default: arm64-v8a)
#   --toolchain FILE  CMake toolchain wrapper (default: sdl_ohos.toolchain.cmake here)
#   -h, --help        show this help
#
# The OHOS toolchain wrapper in this directory re-labels the target as Linux so
# SDL takes its unix code paths; the real compiler stays aarch64-linux-ohos.
#
# Requires: cmake, ninja, python3.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

SRC=""
SDK_NATIVE=""
OUT=""
BUILD=""
PATCHER="$HERE/patch_sdl_ohos.py"
TOOLCHAIN="$HERE/sdl_ohos.toolchain.cmake"
API=23
ARCH=arm64-v8a

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)        SRC="$2"; shift 2 ;;
    --sdk-native) SDK_NATIVE="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --build)      BUILD="$2"; shift 2 ;;
    --patcher)    PATCHER="$2"; shift 2 ;;
    --toolchain)  TOOLCHAIN="$2"; shift 2 ;;
    --api)        API="$2"; shift 2 ;;
    --arch)       ARCH="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ]        || { echo "error: --src is required" >&2; usage >&2; exit 2; }
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]        || { echo "error: --out is required" >&2; usage >&2; exit 2; }

TOOLCHAIN_REAL="$SDK_NATIVE/build/cmake/ohos.toolchain.cmake"
STRIP="$SDK_NATIVE/llvm/bin/llvm-strip"
NM="$SDK_NATIVE/llvm/bin/llvm-nm"
READELF="$SDK_NATIVE/llvm/bin/llvm-readelf"

[ -f "$SRC/CMakeLists.txt" ] || { echo "error: not an SDL3 tree: $SRC" >&2; exit 2; }
[ -f "$TOOLCHAIN_REAL" ]     || { echo "error: OHOS toolchain not found: $TOOLCHAIN_REAL" >&2; exit 2; }
[ -f "$TOOLCHAIN" ]          || { echo "error: SDL toolchain wrapper not found: $TOOLCHAIN" >&2; exit 2; }
[ -f "$PATCHER" ]            || { echo "error: patcher not found: $PATCHER" >&2; exit 2; }
[ -f "$SRC/src/video/khronos/EGL/eglplatform.h" ] || { echo "error: not an SDL3 source tree (eglplatform.h missing)" >&2; exit 2; }

export OHOS_SDK_NATIVE="$SDK_NATIVE"

[ -n "$BUILD" ] || BUILD="$(dirname "$SRC")/build-sdl-meow"
mkdir -p "$OUT"
rm -rf "$BUILD"

echo "=== patch SDL for OHOS ==="
python3 "$PATCHER" "$SRC"

echo "=== configure ($ARCH, api $API) ==="
cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_SDK_NATIVE="$SDK_NATIVE" \
  -DOHOS_ARCH="$ARCH" -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL="$API" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF \
  -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL=OFF \
  -DSDL_UNIX_CONSOLE_BUILD=ON \
  -DSDL_AUDIO=OFF -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF \
  -DSDL_POWER=OFF -DSDL_HIDAPI=OFF -DSDL_CAMERA=OFF -DSDL_DIALOG=OFF \
  -DSDL_LOCALE=OFF -DSDL_TRAY=OFF

echo "=== build ==="
ninja -C "$BUILD"

SO="$BUILD/libSDL3.so.0.4.14"
[ -f "$SO" ] || SO="$(ls "$BUILD"/libSDL3.so.[0-9]* 2>/dev/null | sort | tail -1)"
[ -n "$SO" ] && [ -f "$SO" ] || { echo "error: libSDL3.so not produced" >&2; exit 1; }

if [ -x "$STRIP" ]; then
  "$STRIP" --strip-unneeded "$SO"
fi
cp -L "$SO" "$OUT/libSDL3.so"

# The ohos driver must have been configured, compiled and linked in.
grep -q "SDL_VIDEO_DRIVER_OHOS" "$BUILD/include-config-release/build_config/SDL_build_config.h" \
  || { echo "error: SDL_VIDEO_DRIVER_OHOS not set in build config" >&2; exit 1; }

# >1000 exported SDL_* entry points (baseline dummy/offscreen build has ~1270).
if [ -x "$NM" ]; then
  SDL_COUNT=$("$NM" -D --defined-only "$OUT/libSDL3.so" 2>/dev/null | grep -cE " [TWBD] SDL_" || true)
  [ "$SDL_COUNT" -gt 1000 ] || { echo "error: only $SDL_COUNT SDL_* exports (expected >1000)" >&2; exit 1; }
  echo "exported SDL_* symbols: $SDL_COUNT"
fi

# Only libc.so (and optionally libEGL.so) may be a hard dependency: EGL/GL are
# dlopen()ed at runtime, not linked.
if [ -x "$READELF" ]; then
  NEEDED=$("$READELF" -d "$OUT/libSDL3.so" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
  [ -n "$NEEDED" ] || { echo "error: no DT_NEEDED entries (unexpected)" >&2; exit 1; }
  for lib in $NEEDED; do
    case "$lib" in
      libc.so|libEGL.so|libnative_window.so|libc++_shared.so) ;;
      *) echo "error: unexpected DT_NEEDED dependency '$lib'" >&2; exit 1 ;;
    esac
  done
  echo "DT_NEEDED: $(echo $NEEDED | tr '\n' ' ')"
fi

# The driver string must survive stripping.
grep -a -q "SDL OpenHarmony (OHOS) video driver" "$OUT/libSDL3.so" \
  || { echo "error: ohos video driver text not found in libSDL3.so" >&2; exit 1; }
echo "linked: ohos video driver present"

echo "OK -> $OUT/libSDL3.so ($(wc -c < "$OUT/libSDL3.so") bytes)"
sha256sum "$OUT/libSDL3.so"
