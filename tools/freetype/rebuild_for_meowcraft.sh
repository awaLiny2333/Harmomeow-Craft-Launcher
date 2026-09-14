#!/bin/sh
# Meowcraft wrapper around the standalone build_freetype_meow.sh.
# Creates a throwaway worktree of ref/freetype at the given tag, builds the
# OHOS libfreetype.so, and drops it into meowlwjgls.
#
# Usage:
#   sh tools/freetype/rebuild_for_meowcraft.sh [tag]   # default tag: VER-2-13-3
#
# Override the OHOS SDK native dir with $OHOS_SDK_NATIVE if it is not at the
# default location.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

TAG="${1:-VER-2-13-3}"
REF="$WS/ref/freetype"
WT="$WS/stuffs/research/freetype/$TAG"
BUILD="$WS/stuffs/research/freetype/build-$TAG"
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
OUT="$PROJ/libs/meowlwjgls/libs/arm64-v8a"

[ -d "$REF/.git" ] || { echo "error: not a git clone: $REF" >&2; exit 2; }

git -C "$REF" worktree remove --force "$WT" 2>/dev/null || true
git -C "$REF" worktree prune
git -C "$REF" worktree add --detach -f "$WT" "$TAG"

exec sh "$HERE/build_freetype_meow.sh" \
  --src "$WT" \
  --build "$BUILD" \
  --sdk-native "$SDK" \
  --out "$OUT"
