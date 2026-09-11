#!/bin/sh
# Build a Meowcraft-patched oshi-core jar for a LEGACY (pre-3.0) oshi.
#
# Legacy oshi uses the old single-module layout (`src/main/java/oshi/...`) and the
# old API (`HardwareAbstractionLayer.getProcessors()` / `Processor.getName()`).
# MC 1.16.x ships `oshi-project:oshi-core:1.1`, which is NOT tagged in the oshi
# repo (earliest tag is oshi-core-1.3) and is absent from Maven Central, so this
# script checks out an arbitrary git ref (a commit) instead of a tag.
#
# Standalone: every path is passed in, nothing is derived from the caller's layout.
#
# Usage:
#   sh build_oshi_legacy_meow.sh --oshi-repo DIR --ref REF --label VER \
#       --minecraft DIR --cache DIR --out DIR [--patcher FILE] [--jna VER]
#
# Required:
#   --oshi-repo DIR   full oshi git clone
#   --ref REF         git ref (commit/tag) with the legacy layout
#   --label VER       oshi version this jar REPLACES (drives jar name + manifest key)
#   --minecraft DIR   a .minecraft dir; its libraries/ is read-only first source
#   --cache DIR       writable dir for dependency jars missing from --minecraft
#   --out DIR         output dir; receives oshi-core-<label>-meow.jar + manifest.txt
#
# Optional:
#   --patcher FILE    patch script (default: patch_oshi_legacy.py next to this script)
#   --jna VER         JNA / old jna-platform ("platform") version (default: 3.4.0)
#   -h, --help        show this help
#
# The manifest is UPDATED IN PLACE (existing lines preserved), unlike the modern
# build_oshi_meow.sh which rewrites it from scratch.
#
# Requires: JDK 9+ (javac), python3, curl, git.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

OSHI_REPO=""
REF=""
LABEL=""
MC_DIR=""
CACHE=""
OUT=""
PATCHER="$HERE/patch_oshi_legacy.py"
JNA_VER="3.4.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --oshi-repo) OSHI_REPO="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --label)     LABEL="$2"; shift 2 ;;
    --minecraft) MC_DIR="$2"; shift 2 ;;
    --cache)     CACHE="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --patcher)   PATCHER="$2"; shift 2 ;;
    --jna)       JNA_VER="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$OSHI_REPO" ] || { echo "error: --oshi-repo is required" >&2; exit 2; }
[ -n "$REF" ]       || { echo "error: --ref is required" >&2; exit 2; }
[ -n "$LABEL" ]     || { echo "error: --label is required" >&2; exit 2; }
[ -n "$MC_DIR" ]    || { echo "error: --minecraft is required" >&2; exit 2; }
[ -n "$CACHE" ]     || { echo "error: --cache is required" >&2; exit 2; }
[ -n "$OUT" ]       || { echo "error: --out is required" >&2; exit 2; }
[ -f "$PATCHER" ]   || { echo "error: patcher not found: $PATCHER" >&2; exit 2; }
[ -d "$OSHI_REPO/.git" ] || [ -f "$OSHI_REPO/.git" ] || {
  echo "error: --oshi-repo is not a git clone: $OSHI_REPO" >&2; exit 2; }

LIB="$MC_DIR/libraries"
[ -d "$LIB" ] || { echo "error: $LIB not found (--minecraft must contain libraries/)" >&2; exit 2; }
mkdir -p "$CACHE" "$OUT"

WT_ROOT="$(dirname "$OSHI_REPO")/$(basename "$OSHI_REPO").build"
WT="$WT_ROOT/legacy-$LABEL"
MANIFEST="$OUT/manifest.txt"
JAR="$OUT/oshi-core-$LABEL-meow.jar"

resolve_jar() {
  RJ_GROUP="$1"; RJ_ART="$2"; RJ_VER="$3"
  RJ_NAME="$RJ_ART-$RJ_VER.jar"
  if [ -f "$LIB/$RJ_GROUP/$RJ_ART/$RJ_VER/$RJ_NAME" ]; then
    echo "$LIB/$RJ_GROUP/$RJ_ART/$RJ_VER/$RJ_NAME"; return
  fi
  if [ -f "$CACHE/$RJ_NAME" ]; then echo "$CACHE/$RJ_NAME"; return; fi
  echo "  downloading $RJ_NAME ..." >&2
  curl -sL --max-time 90 --retry 3 --retry-delay 2 -o "$CACHE/$RJ_NAME" \
    "https://repo1.maven.org/maven2/$RJ_GROUP/$RJ_ART/$RJ_VER/$RJ_NAME" \
    || { echo "download failed: $RJ_NAME" >&2; exit 1; }
  echo "$CACHE/$RJ_NAME"
}

git -C "$OSHI_REPO" worktree prune
rm -rf "$WT"
git -C "$OSHI_REPO" worktree add --detach -f -q "$WT" "$REF"

SRC="$WT/src/main/java"
[ -d "$SRC/oshi/software/os/linux/proc" ] || {
  echo "error: $REF does not look like the legacy oshi layout" >&2; exit 1; }

# Legacy oshi declares JNA 3.4.0 (net.java.dev.jna:jna + :platform).
JNA=$(resolve_jar net/java/dev/jna jna "$JNA_VER")
JNA_PLATFORM=$(resolve_jar net/java/dev/jna platform "$JNA_VER")
CP="$JNA:$JNA_PLATFORM"

echo "=== legacy oshi $LABEL (ref $REF)  jna=$JNA_VER ==="
python3 "$PATCHER" \
  "$SRC/oshi/software/os/linux/proc/CentralProcessor.java" \
  "$SRC/oshi/software/os/linux/LinuxHardwareAbstractionLayer.java"

CLASSES="$WT/target/meow-classes"
mkdir -p "$CLASSES" "$WT/target"
find "$SRC" -name '*.java' > "$WT/target/sources.txt"
javac -encoding UTF-8 --release 8 -nowarn -cp "$CP" -d "$CLASSES" @"$WT/target/sources.txt"
if [ -d "$WT/src/main/resources" ]; then
  cp -R "$WT/src/main/resources/." "$CLASSES/"
fi

printf 'Manifest-Version: 1.0\nImplementation-Title: oshi-core\nImplementation-Version: %s-meow\n\n' \
  "$LABEL" > "$WT/target/MANIFEST.MF"
rm -f "$JAR"
python3 "$HERE/pack_jar.py" "$CLASSES" "$WT/target/MANIFEST.MF" "$JAR"

# Update manifest in place (preserve the modern versions' lines).
touch "$MANIFEST"
TMP="$MANIFEST.tmp.$$"
grep -v "^oshi-core-$LABEL.jar=" "$MANIFEST" > "$TMP" || true
echo "oshi-core-$LABEL.jar=oshi-core-$LABEL-meow.jar" >> "$TMP"
mv "$TMP" "$MANIFEST"

echo "OK -> $JAR ($(wc -c < "$JAR") bytes)"
git -C "$OSHI_REPO" worktree remove --force "$WT"

echo "== manifest =="
cat "$MANIFEST"
