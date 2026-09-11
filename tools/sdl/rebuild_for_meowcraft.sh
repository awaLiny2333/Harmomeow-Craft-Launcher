#!/bin/sh
# Meowcraft wrapper around the standalone build_sdl_meow.sh.
#
# Uses the SDL fork worktree at ref/SDL-3.4.14 (release-3.4.14), applies the
# OHOS patcher in place, builds libSDL3.so with the native "ohos" video driver,
# and drops the artifact plus a full log into stuffs/research/sdl/.
#
# Usage:
#   sh tools/sdl/rebuild_for_meowcraft.sh
#
# Override the OHOS SDK native dir with $OHOS_SDK_NATIVE if it is not at the
# default location.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

TAG="release-3.4.14"
SRC="$WS/ref/SDL-3.4.14"
BUILD="$WS/stuffs/research/sdl/build-ohos"
OUT="$WS/stuffs/research/sdl/out"
LOG="$WS/stuffs/research/sdl/build-ohos.log"
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"

[ -f "$SRC/CMakeLists.txt" ] || { echo "error: SDL fork worktree not found: $SRC" >&2; exit 2; }

if command -v git >/dev/null 2>&1; then
  CURRENT="$(git -C "$SRC" describe --tags 2>/dev/null || true)"
  if [ -n "$CURRENT" ] && [ "$CURRENT" != "$TAG" ]; then
    echo "warning: $SRC is at '$CURRENT', expected tag '$TAG'" >&2
  fi
fi

mkdir -p "$(dirname "$LOG")" "$OUT"

set +e
sh "$HERE/build_sdl_meow.sh" \
  --src "$SRC" \
  --build "$BUILD" \
  --sdk-native "$SDK" \
  --out "$OUT" \
  --patcher "$HERE/patch_sdl_ohos.py" >"$LOG" 2>&1
RC=$?
set -e

cat "$LOG"
[ "$RC" -eq 0 ] || exit "$RC"

echo "log: $LOG"
