#!/bin/sh
# Build Meowcraft's OHOS build of gl4es (desktop-GL -> OpenGL ES translator) as
# a shared library that a host can dlopen while it owns the EGL/GLES context.
#
# Standalone: every path is passed in, nothing is derived from the caller's
# layout. gl4es is built with:
#   NOX11=1 NOEGL=1            - no X11/EGL context management; the host creates
#                                and makes current a GLES context itself.
#   DEFAULT_ES=2               - GLES2 backend (upstream has no ES3 switch).
#   NO_INIT_CONSTRUCTOR=1      - do NOT auto-init from a library constructor;
#                                the host calls initialize_gl4es() explicitly,
#                                AFTER the GLES context is current.
#
# Usage:
#   sh build_gl4es_meow.sh --src DIR --sdk-native DIR --out DIR \
#       [--build DIR] [--api N] [--arch NAME] [--toolchain FILE]
#
# Required:
#   --src DIR         gl4es source tree (ptitSeb/gl4es)
#   --sdk-native DIR  OHOS SDK native dir (has build/cmake/ohos.toolchain.cmake, llvm/)
#   --out DIR         output dir; receives libgl4es.so
#
# Optional:
#   --build DIR       out-of-tree build dir (default: <src>/../build-gl4es-meow)
#   --api N           OHOS platform level (default: 23)
#   --arch NAME       OHOS arch (default: arm64-v8a)
#   --toolchain FILE  CMake toolchain wrapper (default: gl4es_ohos.toolchain.cmake here)
#   -h, --help        show this help
#
# Requires: cmake (>=3.19; CMake 4.x also needs CMAKE_POLICY_VERSION_MINIMUM),
#           ninja.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

SRC=""
SDK_NATIVE=""
OUT=""
BUILD=""
TOOLCHAIN="$HERE/gl4es_ohos.toolchain.cmake"
API=23
ARCH=arm64-v8a

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)        SRC="$2"; shift 2 ;;
    --sdk-native) SDK_NATIVE="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --build)      BUILD="$2"; shift 2 ;;
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

[ -f "$SRC/CMakeLists.txt" ]      || { echo "error: not a gl4es tree: $SRC" >&2; exit 2; }
[ -f "$SRC/src/gl/gl4es.c" ]       || { echo "error: not a gl4es source tree (src/gl/gl4es.c missing)" >&2; exit 2; }
[ -f "$TOOLCHAIN_REAL" ]           || { echo "error: OHOS toolchain not found: $TOOLCHAIN_REAL" >&2; exit 2; }
[ -f "$TOOLCHAIN" ]                || { echo "error: gl4es toolchain wrapper not found: $TOOLCHAIN" >&2; exit 2; }

export OHOS_SDK_NATIVE="$SDK_NATIVE"

[ -n "$BUILD" ] || BUILD="$(dirname "$SRC")/build-gl4es-meow"
mkdir -p "$OUT"
rm -rf "$BUILD"

echo "=== configure ($ARCH, api $API) ==="
cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_SDK_NATIVE="$SDK_NATIVE" \
  -DOHOS_ARCH="$ARCH" -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL="$API" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DNOX11=1 -DNOEGL=1 -DDEFAULT_ES=2 -DNO_INIT_CONSTRUCTOR=1 \
  -DGBM=OFF -DEGL_WRAPPER=OFF -DGLX_STUBS=OFF -DSTATICLIB=OFF

echo "=== build ==="
ninja -C "$BUILD"

# gl4es hardcodes its lib output dir to <src>/lib and names the artifact
# libGL.so.1 (SUFFIX ".so.1").
RAW="$SRC/lib/libGL.so.1"
[ -f "$RAW" ] || { echo "error: libGL.so.1 not produced at $RAW" >&2; exit 1; }

if [ -x "$STRIP" ]; then
  "$STRIP" --strip-unneeded "$RAW"
fi
# hvigor only packages top-level *.so files, so ship it under a .so name.
cp -f "$RAW" "$OUT/libgl4es.so"

LIB="$OUT/libgl4es.so"

# The legacy fixed-function entry points must be real exports.
if [ -x "$NM" ]; then
  MISSING=""
  # Fixed-function entry points AND the runtime dlsym targets the bridge needs.
  for sym in glMatrixMode glEnableClientState glFogfv glBegin glGetString glViewport \
             glXGetProcAddress initialize_gl4es set_getmainfbsize set_getprocaddress; do
    "$NM" -D --defined-only "$LIB" 2>/dev/null | grep -qE " [TWBD] ${sym}$" || MISSING="$MISSING $sym"
  done
  [ -z "$MISSING" ] || { echo "error: missing fixed-function exports:$MISSING" >&2; exit 1; }
  GL_COUNT=$("$NM" -D --defined-only "$LIB" 2>/dev/null | grep -cE " [TWBD] gl[A-Z]" || true)
  echo "exported gl* symbols: $GL_COUNT"
fi

# Only libc.so (and possibly libm.so/libdl.so/libc++_shared.so) may be a hard
# dependency: EGL/GLES are dlopen()ed at runtime, not linked.
if [ -x "$READELF" ]; then
  NEEDED=$("$READELF" -d "$LIB" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
  [ -n "$NEEDED" ] || { echo "error: no DT_NEEDED entries (unexpected)" >&2; exit 1; }
  for lib in $NEEDED; do
    case "$lib" in
      libc.so|libm.so|libdl.so|libc++_shared.so|libhilog_ndk.z.so) ;;
      *) echo "error: unexpected DT_NEEDED dependency '$lib'" >&2; exit 1 ;;
    esac
  done
  echo "DT_NEEDED: $(echo $NEEDED | tr '\n' ' ')"
fi

echo "OK -> $LIB ($(wc -c < "$LIB") bytes)"
sha256sum "$LIB"
