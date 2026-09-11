#!/bin/sh
# Meowcraft wrapper: build one LWJGL generation's natives and install them into the
# flat packaged dir under the uniform suffix.
#
#   STAGE: extract ref/lwjgl3@<tag> into a throwaway tree (git archive; the source
#          repo checkout is untouched) -> build_lwjgl_natives.sh -> <staging>/out
#   INSTALL: install_natives.sh <tag> -> libs/meowlwjgl3/libs/arm64-v8a/lib*_<digits>.so
#            (+ natives.manifest)
#
# Usage:
#   sh tools/lwjgl/rebuild_for_meowcraft.sh [tag]     # default tag: 3.3.3
#
# 3.3.x: libffi auto-resolved by build_lwjgl_natives.sh (source tree under
#        stuffs/research, else the OHOS HNP prebuilt 3.4.4).
# 3.4.x: the core native links libffi 3.8.0 (ffi_call_plan_*), so a libffi.a is
#        REQUIRED — take $LWJGL_LIBFFI_A, else stuffs/research/libffi/out-ohos/libffi.a
#        (build it first with tools/lwjgl/build_libffi.sh).
#
# Override the OHOS SDK native dir with $OHOS_SDK_NATIVE if it is not at the
# default location.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

TAG="${1:-3.3.3}"
REF="$WS/ref/lwjgl3"
WT="$WS/stuffs/research/lwjgl_natives-$TAG/src"
BUILD="$WS/stuffs/research/lwjgl_natives-$TAG/build"
STAGE="$WS/stuffs/research/lwjgl_natives-$TAG/out"
COMPARE="$PROJ/libs/meowlwjgl3/libs/arm64-v8a"
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"

[ -d "$REF/.git" ] || {
  echo "error: not a git clone: $REF" >&2
  echo "  git clone https://github.com/LWJGL/lwjgl3.git $REF" >&2
  exit 2; }
git -C "$REF" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "error: tag not found in $REF: $TAG" >&2; exit 2; }

LIBFFI_ARG=""
case "$TAG" in
  3.[4-9].*|4.*)
    LIBFFI_A="${LWJGL_LIBFFI_A:-$WS/stuffs/research/libffi/out-ohos/libffi.a}"
    [ -f "$LIBFFI_A" ] || {
      echo "error: $TAG links libffi 3.8.0; not found: $LIBFFI_A" >&2
      echo "  build it: sh tools/lwjgl/build_libffi.sh \\" >&2
      echo "    --src stuffs/research/libffi/libffi-3.8.0 --sdk-native $SDK \\" >&2
      echo "    --out $WS/stuffs/research/libffi/out-ohos" >&2
      exit 2; }
    LIBFFI_ARG="--libffi-a $LIBFFI_A"
    echo "note: $TAG -> linking $LIBFFI_A"
    ;;
esac

rm -rf "$WT"; mkdir -p "$WT"
git -C "$REF" archive "$TAG" | tar -x -C "$WT"

# shellcheck disable=SC2086
sh "$HERE/build_lwjgl_natives.sh" \
  --src "$WT" \
  --build "$BUILD" \
  --sdk-native "$SDK" \
  --out "$STAGE" \
  $LIBFFI_ARG \
  --compare "$COMPARE"

exec sh "$HERE/install_natives.sh" "$TAG" --src "$STAGE"
