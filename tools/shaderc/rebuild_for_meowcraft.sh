#!/bin/sh
# Meowcraft wrapper around the standalone build_shaderc_meow.sh.
#
# Pins and builds the exact upstream revisions LWJGL 3.4.3 used for its Linux
# natives (read from the libshaderc.so.git / libspirv-cross.so.git markers in
# the Maven jars), so our OHOS libraries are ABI/behaviour-matched to the ones
# Minecraft 26.3's renderpearl expects:
#   libshaderc.so      (org.lwjgl.util.shaderc.Shaderc)
#   libspirv-cross.so  (org.lwjgl.util.spvc.Spvc)
#
# Source checkouts live in the workspace-level ref/ (never inside the app repo);
# build trees, logs and artifacts go to stuffs/research/shaderc/.
#
# Usage:
#   sh tools/shaderc/rebuild_for_meowcraft.sh
#
# Override the OHOS SDK native dir with $OHOS_SDK_NATIVE if it is not at the
# default location. Missing ref/ trees are cloned automatically (TLS proxy uses
# a self-signed cert, hence http.sslVerify=false).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"      # Meowcraft project dir
WS="$(cd "$PROJ/.." && pwd)"           # workspace: holds ref/ and stuffs/

REF="$WS/ref"
RES="$WS/stuffs/research/shaderc"
OUT="$RES/out"
LOG="$RES/build-meow.log"
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"

SHADERC_REV="2c8cae778eec0283b44acbe7ed1a386865d78799"
GLSLANG_REV="168d452a4f460d24b588fed08477a81c44ee27a1"
SPIRV_TOOLS_REV="b707790a898e44038547df54580022fc1cf89c3d"
SPIRV_HEADERS_REV="29981f65241605e08b0ede4cfeb999fe3b723c6a"
SPIRV_CROSS_REV="6c09849fe88c48eaed08413aa022aaa136a3a057"

GIT="git -c http.sslVerify=false"

ensure_repo() {
  dir="$1"; url="$2"; rev="$3"; name="$4"
  if [ ! -d "$dir/.git" ]; then
    echo "=== clone $name @ $rev ==="
    $GIT clone --filter=blob:none "$url" "$dir"
    git -C "$dir" checkout -q "$rev"
  else
    have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$have" != "$rev" ]; then
      echo "warning: $dir is at $have, expected $rev (not changing the checkout)" >&2
    fi
  fi
}

mkdir -p "$REF" "$RES" "$OUT"

ensure_repo "$REF/shaderc"       "https://github.com/google/shaderc.git"        "$SHADERC_REV"       shaderc
ensure_repo "$REF/glslang"       "https://github.com/KhronosGroup/glslang.git"  "$GLSLANG_REV"       glslang
ensure_repo "$REF/SPIRV-Tools"   "https://github.com/KhronosGroup/SPIRV-Tools.git" "$SPIRV_TOOLS_REV" SPIRV-Tools
ensure_repo "$REF/SPIRV-Headers" "https://github.com/KhronosGroup/SPIRV-Headers.git" "$SPIRV_HEADERS_REV" SPIRV-Headers
ensure_repo "$REF/spirv-cross"   "https://github.com/KhronosGroup/SPIRV-Cross.git"  "$SPIRV_CROSS_REV"   SPIRV-Cross

set +e
sh "$HERE/build_shaderc_meow.sh" \
  --src "$REF/shaderc" \
  --glslang "$REF/glslang" \
  --spirv-tools "$REF/SPIRV-Tools" \
  --spirv-headers "$REF/SPIRV-Headers" \
  --spirv-cross "$REF/spirv-cross" \
  --sdk-native "$SDK" \
  --out "$OUT" \
  --build "$RES/build-ohos" >"$LOG" 2>&1
RC=$?
set -e

cat "$LOG"
[ "$RC" -eq 0 ] || exit "$RC"

echo "log: $LOG"
