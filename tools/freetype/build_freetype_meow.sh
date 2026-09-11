#!/bin/sh
# Build Meowcraft's OHOS FreeType (libfreetype.so) from source.
#
# Standalone: every path is passed in, nothing is derived from the caller's
# layout.
#
# Usage:
#   sh build_freetype_meow.sh --src DIR --sdk-native DIR --out DIR \
#       [--build DIR] [--api N] [--arch NAME]
#
# Required:
#   --src DIR         freetype source tree, checked out at the target tag
#   --sdk-native DIR  OHOS SDK native dir (build/cmake/ohos.toolchain.cmake + sysroot)
#   --out DIR         output dir; receives libfreetype.so
#
# Optional:
#   --build DIR       out-of-tree build dir (default: <src>/../build-meow)
#   --api N           OHOS platform level (default: 23)
#   --arch NAME       OHOS arch (default: arm64-v8a)
#   -h, --help        show this help
#
# Emits a shared FreeType with **zlib only** (bzip2/png/harfbuzz/brotli off),
# stripped, with the OHOS `.permission`/`.codesign`/`.comment` metadata sections
# removed to match the shipped binary's shape.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

SRC=""; SDK_NATIVE=""; OUT=""; BUILD=""; API=23; ARCH=arm64-v8a
while [ "$#" -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --sdk-native) SDK_NATIVE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --api) API="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ]        || { echo "error: --src is required" >&2; usage >&2; exit 2; }
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]        || { echo "error: --out is required" >&2; usage >&2; exit 2; }

TOOLCHAIN="$SDK_NATIVE/build/cmake/ohos.toolchain.cmake"
STRIP="$SDK_NATIVE/llvm/bin/llvm-strip"
OBJCOPY="$SDK_NATIVE/llvm/bin/llvm-objcopy"
NM="$SDK_NATIVE/llvm/bin/llvm-nm"

[ -f "$SRC/CMakeLists.txt" ] || { echo "error: not a freetype tree: $SRC" >&2; exit 2; }
[ -f "$TOOLCHAIN" ] || { echo "error: OHOS toolchain not found: $TOOLCHAIN" >&2; exit 2; }

[ -n "$BUILD" ] || BUILD="$(dirname "$SRC")/build-meow"
mkdir -p "$OUT"
rm -rf "$BUILD"

echo "=== configure ($ARCH, api $API) ==="
cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DOHOS_ARCH="$ARCH" -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL="$API" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_SHARED_LIBS=ON \
  -DFT_DISABLE_ZLIB=OFF -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON

echo "=== build ==="
ninja -C "$BUILD"

SO="$(ls "$BUILD"/libfreetype.so.* 2>/dev/null | grep -vE '\.so\.6$' | head -1)"
[ -f "$SO" ] || { echo "error: libfreetype.so not produced" >&2; exit 1; }

echo "=== strip + drop OHOS metadata sections (match shipped shape) ==="
[ -x "$STRIP" ] && "$STRIP" --strip-unneeded "$SO"
if [ -x "$OBJCOPY" ]; then
  "$OBJCOPY" --remove-section=.permission --remove-section=.codesign --remove-section=.comment "$SO" 2>/dev/null || true
fi

cp "$SO" "$OUT/libfreetype.so"

# Sanity: same SONAME/deps/version surface as the shipped binary.
if [ -x "$NM" ]; then
  FT_COUNT=$("$NM" -D --defined-only "$OUT/libfreetype.so" 2>/dev/null | grep -cE " T (FT|FTC|TT)_" || true)
  [ "$FT_COUNT" -ge 200 ] || { echo "error: unexpected FreeType symbol count: $FT_COUNT" >&2; exit 1; }
  echo "exported FT_/FTC_/TT_ symbols: $FT_COUNT"
fi
echo "SONAME/NEEDED:"
readelf -d "$OUT/libfreetype.so" 2>/dev/null | grep -E "NEEDED|SONAME" || true

echo "OK -> $OUT/libfreetype.so ($(wc -c < "$OUT/libfreetype.so") bytes)"
sha256sum "$OUT/libfreetype.so"
