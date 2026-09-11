#!/bin/sh
# Meowcraft wrapper around build_oshi_legacy_meow.sh.
#
# Builds the LEGACY oshi override used by MC 1.16.x (oshi-core 1.1). oshi 1.1 is
# untagged, so this checks out a 1.1-era commit of the oshi repo by default.
#
# Usage:
#   sh tools/oshi/rebuild_legacy_for_meowcraft.sh [REF] [LABEL]
#     REF    git ref with the legacy layout (default: 4047d5be65, 2015-01-08,
#            the last oshi commit before the 1.1 jar build date 2015-01-09)
#     LABEL  oshi version this jar replaces (default: 1.1)
#
# NOTE: this contains a javac step; run it from a shell that can execute a JVM
# (the agent shell cannot).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

REF="${1:-4047d5be65}"
LABEL="${2:-1.1}"

exec sh "$HERE/build_oshi_legacy_meow.sh" \
  --oshi-repo "$WS/ref/oshi" \
  --ref "$REF" \
  --label "$LABEL" \
  --minecraft "$WS/stuffs/.minecraft" \
  --cache "$WS/ref/jna-cache" \
  --out "$PROJ/entry/src/main/resources/rawfile/oshi-overrides"
