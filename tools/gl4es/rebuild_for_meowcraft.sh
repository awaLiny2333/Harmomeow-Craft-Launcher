#!/bin/sh
# Meowcraft wrapper around the standalone build_gl4es_meow.sh.
#
# Builds gl4es (upstream ptitSeb/gl4es) for OHOS arm64 from the source clone at
# ref/gl4es and drops libgl4es.so plus a full log into stuffs/research/gl4es/.
#
# Usage:
#   sh tools/gl4es/rebuild_for_meowcraft.sh
#
# Override the OHOS SDK native dir with $OHOS_SDK_NATIVE if it is not at the
# default location.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

SRC="$WS/ref/gl4es"
BUILD="$WS/stuffs/research/gl4es/build-ohos"
OUT="$WS/stuffs/research/gl4es/out"
LOG="$WS/stuffs/research/gl4es/build-ohos.log"
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"

[ -f "$SRC/CMakeLists.txt" ] || { echo "error: gl4es source not found: $SRC" >&2; exit 2; }

if command -v git >/dev/null 2>&1; then
  DESC="$(git -C "$SRC" describe --tags 2>/dev/null || true)"
  echo "gl4es source: $SRC ($DESC)"
fi

mkdir -p "$(dirname "$LOG")" "$OUT"

set +e
sh "$HERE/build_gl4es_meow.sh" \
  --src "$SRC" \
  --build "$BUILD" \
  --sdk-native "$SDK" \
  --out "$OUT" >"$LOG" 2>&1
RC=$?
set -e

cat "$LOG"
[ "$RC" -eq 0 ] || exit "$RC"

echo "log: $LOG"
