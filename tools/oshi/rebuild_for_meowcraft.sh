#!/bin/sh
# Meowcraft wrapper around the standalone build_oshi_meow.sh.
# Fills in this project's paths; pass the oshi versions as arguments.
#
# Usage:
#   sh tools/oshi/rebuild_for_meowcraft.sh 6.6.5
#   sh tools/oshi/rebuild_for_meowcraft.sh 5.7.4 5.7.5 5.8.2 5.8.5 6.2.2 6.4.5 6.4.10 6.6.5 6.9.0
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

exec sh "$HERE/build_oshi_meow.sh" \
  --oshi-repo "$WS/ref/oshi" \
  --minecraft "$WS/stuffs/.minecraft" \
  --cache "$WS/ref/jna-cache" \
  --out "$PROJ/entry/src/main/resources/rawfile/oshi-overrides" \
  "$@"
