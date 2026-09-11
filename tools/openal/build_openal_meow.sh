#!/bin/sh
# Build Meowcraft's OHOS port of OpenAL Soft (libopenal.so).
#
# Standalone: every path is passed in, nothing is derived from the caller's
# layout. The source tree is patched in place by patch_openal_ohos.py, so pass
# a throwaway checkout/worktree (the project wrapper creates one).
#
# Usage:
#   sh build_openal_meow.sh --src DIR --sdk-native DIR --out DIR \
#       [--build DIR] [--patcher FILE] [--api N] [--arch NAME]
#
# Required:
#   --src DIR         openal-soft source tree, checked out at the target tag
#   --sdk-native DIR  OHOS SDK native dir (has build/cmake/ohos.toolchain.cmake,
#                     llvm/, sysroot/ with SLES/OpenSLES_OpenHarmony.h)
#   --out DIR         output dir; receives libopenal.so
#
# Optional:
#   --build DIR       out-of-tree build dir (default: <src>/../build-meow)
#   --patcher FILE    OpenSL patch script (default: patch_openal_ohos.py next to this script)
#   --ohaudio-patcher FILE  OHAudio backend installer (default: patch_openal_ohaudio.py)
#   --events-patcher FILE   SOFT_system_events export fixer (default: patch_openal_events_export.py)
#   --api N           OHOS platform level (default: 23)
#   --arch NAME       OHOS arch (default: arm64-v8a)
#   -h, --help        show this help
#
# Requires: cmake, ninja. Emits an OpenSL-only, musl/libc++_shared build.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

SRC=""
SDK_NATIVE=""
OUT=""
BUILD=""
PATCHER="$HERE/patch_openal_ohos.py"
OHAUDIO_PATCHER="$HERE/patch_openal_ohaudio.py"
EVENTS_PATCHER="$HERE/patch_openal_events_export.py"
API=23
ARCH=arm64-v8a

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)        SRC="$2"; shift 2 ;;
    --sdk-native) SDK_NATIVE="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --build)      BUILD="$2"; shift 2 ;;
    --patcher)    PATCHER="$2"; shift 2 ;;
    --ohaudio-patcher) OHAUDIO_PATCHER="$2"; shift 2 ;;
    --events-patcher) EVENTS_PATCHER="$2"; shift 2 ;;
    --api)        API="$2"; shift 2 ;;
    --arch)       ARCH="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ]        || { echo "error: --src is required" >&2; usage >&2; exit 2; }
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]        || { echo "error: --out is required" >&2; usage >&2; exit 2; }

OPENSL_CPP="$SRC/alc/backends/opensl.cpp"
TOOLCHAIN="$SDK_NATIVE/build/cmake/ohos.toolchain.cmake"
SYSROOT="$SDK_NATIVE/sysroot"
OPENSL_LIB="$SYSROOT/usr/lib/aarch64-linux-ohos/libOpenSLES.so"
STRIP="$SDK_NATIVE/llvm/bin/llvm-strip"

[ -f "$OPENSL_CPP" ] || { echo "error: not an openal-soft tree: $SRC" >&2; exit 2; }
[ -f "$TOOLCHAIN" ]  || { echo "error: OHOS toolchain not found: $TOOLCHAIN" >&2; exit 2; }
[ -f "$OPENSL_LIB" ] || { echo "error: libOpenSLES.so not found: $OPENSL_LIB" >&2; exit 2; }
[ -f "$PATCHER" ]    || { echo "error: patcher not found: $PATCHER" >&2; exit 2; }
[ -f "$OHAUDIO_PATCHER" ] || { echo "error: OHAudio patcher not found: $OHAUDIO_PATCHER" >&2; exit 2; }
[ -f "$EVENTS_PATCHER" ] || { echo "error: events patcher not found: $EVENTS_PATCHER" >&2; exit 2; }

[ -n "$BUILD" ] || BUILD="$(dirname "$SRC")/build-meow"
mkdir -p "$OUT"
rm -rf "$BUILD"

echo "=== patch OpenSL backend for OHOS ==="
python3 "$PATCHER" "$OPENSL_CPP"

echo "=== install OHAudio backend ==="
python3 "$OHAUDIO_PATCHER" "$SRC"

echo "=== export ALC_SOFT_system_events entry points ==="
python3 "$EVENTS_PATCHER" "$SRC"

echo "=== configure ($ARCH, api $API) ==="
# Force the export-visibility attribute: CMake's cross-compile link test for
# __attribute__((visibility("default"))) fails spuriously on the OHOS toolchain,
# which would otherwise leave ALC_API/AL_API empty and export no symbols.
cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_ARCH="$ARCH" -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL="$API" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DALSOFT_UPDATE_BUILD_VERSION=OFF \
  -DHAVE_GCC_PROTECTED_VISIBILITY=0 -DHAVE_GCC_DEFAULT_VISIBILITY=1 \
  -DOPENSL_INCLUDE_DIR="$SYSROOT/usr/include" \
  -DOPENSL_ANDROID_INCLUDE_DIR="$SYSROOT/usr/include" \
  -DOPENSL_LIBRARY="$OPENSL_LIB" \
  -DALSOFT_BACKEND_OPENSL=ON -DALSOFT_REQUIRE_OPENSL=ON \
  -DALSOFT_BACKEND_OHAUDIO=ON \
  -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_ALSA=OFF -DALSOFT_BACKEND_OSS=OFF \
  -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_SNDIO=OFF -DALSOFT_BACKEND_PORTAUDIO=OFF \
  -DALSOFT_BACKEND_SDL2=OFF -DALSOFT_BACKEND_SDL3=OFF -DALSOFT_BACKEND_OBOE=OFF \
  -DALSOFT_BACKEND_PIPEWIRE=OFF \
  -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF

echo "=== build ==="
ninja -C "$BUILD"

SO="$(ls "$BUILD"/libopenal.so.* 2>/dev/null | head -1)"
[ -n "$SO" ] && [ -f "$SO" ] || { echo "error: libopenal.so not produced" >&2; exit 1; }

if [ -x "$STRIP" ]; then
  "$STRIP" --strip-unneeded "$SO"
fi

cp "$SO" "$OUT/libopenal.so"

# Guard against the cross-compile visibility bug: a lib with no exported ALC
# symbols makes LWJGL fail with "A core ALC function is missing".
NM="$SDK_NATIVE/llvm/bin/llvm-nm"
if [ -x "$NM" ]; then
  ALC_COUNT=$("$NM" -D --defined-only "$OUT/libopenal.so" 2>/dev/null | grep -cE " alc" || true)
  [ "$ALC_COUNT" -gt 0 ] || { echo "error: no ALC symbols exported (visibility bug)" >&2; exit 1; }
  echo "exported ALC symbols: $ALC_COUNT"
fi

# Ensure the OHAudio backend was actually compiled/linked in.
READELF="$SDK_NATIVE/llvm/bin/llvm-readelf"
if [ -x "$READELF" ]; then
  "$READELF" -d "$OUT/libopenal.so" 2>/dev/null | grep -q "libohaudio.so" \
    || { echo "error: OHAudio backend not linked (libohaudio.so missing)" >&2; exit 1; }
  echo "linked: libohaudio.so"
fi

echo "OK -> $OUT/libopenal.so ($(wc -c < "$OUT/libopenal.so") bytes)"
sha256sum "$OUT/libopenal.so"
