#!/bin/sh
# Build Meowcraft-patched oshi-core jars, one per oshi version.
#
# Standalone: every path is passed in, nothing is derived from the caller's layout.
#
# Usage:
#   sh build_oshi_meow.sh --oshi-repo DIR --minecraft DIR --cache DIR --out DIR \
#       <oshi-version> [<oshi-version> ...]
#
# Required:
#   --oshi-repo DIR   full oshi git clone (must have the `oshi-parent-<v>` tags)
#   --minecraft DIR   a .minecraft dir; its `libraries/` is used (read-only) as the
#                     first place to look for jna / jna-platform / slf4j-api jars
#   --cache DIR       writable dir for dependency jars missing from --minecraft
#                     (downloaded from Maven Central, reused on later runs)
#   --out DIR         output dir; receives `oshi-core-<v>-meow.jar` + `manifest.txt`
#
# Optional:
#   --patcher FILE    patch script (default: patch_oshi.py next to this script)
#   -h, --help        show this help
#
# For each <version>: check out git tag `oshi-parent-<version>` into a throwaway
# worktree under <oshi-repo>/../<basename>.build/, apply the patcher to
# LinuxCentralProcessor.java, compile with plain javac (no Maven) against the JNA /
# slf4j versions that version's own pom declares, and emit
#   <out>/oshi-core-<version>-meow.jar
# then (re)write <out>/manifest.txt with `<staged jar>=<override jar>` lines.
#
# Requires: JDK 9+ (javac), python3, curl, git.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

OSHI_REPO=""
MC_DIR=""
CACHE=""
OUT=""
PATCHER="$HERE/patch_oshi.py"
VERSIONS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --oshi-repo) OSHI_REPO="$2"; shift 2 ;;
    --minecraft) MC_DIR="$2"; shift 2 ;;
    --cache)     CACHE="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --patcher)   PATCHER="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)           VERSIONS="$VERSIONS $1"; shift ;;
  esac
done
while [ "$#" -gt 0 ]; do VERSIONS="$VERSIONS $1"; shift; done

[ -n "$OSHI_REPO" ] || { echo "error: --oshi-repo is required" >&2; usage >&2; exit 2; }
[ -n "$MC_DIR" ]    || { echo "error: --minecraft is required" >&2; usage >&2; exit 2; }
[ -n "$CACHE" ]     || { echo "error: --cache is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]       || { echo "error: --out is required" >&2; usage >&2; exit 2; }
[ -n "$VERSIONS" ]  || { echo "error: at least one <oshi-version> is required" >&2; usage >&2; exit 2; }
[ -f "$PATCHER" ]   || { echo "error: patcher not found: $PATCHER" >&2; exit 2; }
[ -d "$OSHI_REPO/.git" ] || [ -f "$OSHI_REPO/.git" ] || {
  echo "error: --oshi-repo is not a git clone: $OSHI_REPO" >&2; exit 2; }

LIB="$MC_DIR/libraries"
[ -d "$LIB" ] || { echo "error: $LIB not found (--minecraft must contain libraries/)" >&2; exit 2; }
mkdir -p "$CACHE" "$OUT"

WT_ROOT="$(dirname "$OSHI_REPO")/$(basename "$OSHI_REPO").build"
MANIFEST="$OUT/manifest.txt"

# resolve_jar <group-path> <artifact> <version> -> absolute jar path
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

# pom_prop <tag> <file> <prop> -> value
pom_prop() {
  git -C "$OSHI_REPO" show "$1:$2" 2>/dev/null \
    | grep -oE "<$3>[^<]+" | head -1 | sed 's/.*>//'
}

# Preserve entries for versions NOT rebuilt in this run (e.g. the legacy 1.1 line
# produced by build_oshi_legacy_meow.sh): this script rewrites the manifest, and
# silently dropping them would regress MC 1.16.x.
PRESERVED="$OUT/manifest.preserved"
if [ -f "$MANIFEST" ]; then cp "$MANIFEST" "$PRESERVED"; else : > "$PRESERVED"; fi
: > "$MANIFEST"

for V in $VERSIONS; do
  TAG="oshi-parent-$V"
  WT="$WT_ROOT/$V"
  JAR="$OUT/oshi-core-$V-meow.jar"

  JNA_VER=$(pom_prop "$TAG" "oshi-core/pom.xml" jna.version)
  [ -z "$JNA_VER" ] && JNA_VER=$(pom_prop "$TAG" "pom.xml" jna.version)
  [ -z "$JNA_VER" ] && { echo "cannot determine jna.version for $V" >&2; exit 1; }
  SLF4J_VER=$(pom_prop "$TAG" "oshi-core/pom.xml" slf4j.version)
  [ -z "$SLF4J_VER" ] && SLF4J_VER=$(pom_prop "$TAG" "pom.xml" slf4j.version)
  [ -z "$SLF4J_VER" ] && SLF4J_VER=2.0.16

  echo "=== oshi $V ($TAG)  jna=$JNA_VER slf4j=$SLF4J_VER ==="
  JNA=$(resolve_jar net/java/dev/jna jna "$JNA_VER")
  JNA_PLATFORM=$(resolve_jar net/java/dev/jna jna-platform "$JNA_VER")
  SLF4J=$(resolve_jar org/slf4j slf4j-api "$SLF4J_VER")
  CP="$JNA:$JNA_PLATFORM:$SLF4J"

  git -C "$OSHI_REPO" worktree prune
  rm -rf "$WT"
  git -C "$OSHI_REPO" worktree add --detach -f -q "$WT" "$TAG"

  SRC="$WT/oshi-core/src/main/java"
  LCP="$SRC/oshi/hardware/platform/linux/LinuxCentralProcessor.java"
  python3 "$PATCHER" "$LCP"

  CLASSES="$WT/target/meow-classes"
  mkdir -p "$CLASSES" "$WT/target"
  find "$SRC" -name '*.java' > "$WT/target/sources.txt"
  javac -encoding UTF-8 --release 8 -nowarn -cp "$CP" -d "$CLASSES" @"$WT/target/sources.txt"
  cp -R "$WT/oshi-core/src/main/resources/." "$CLASSES/"

  printf 'Manifest-Version: 1.0\nAutomatic-Module-Name: com.github.oshi\nImplementation-Title: oshi-core\nImplementation-Version: %s-meow\n\n' "$V" > "$WT/target/MANIFEST.MF"
  # Deterministic jar (fixed timestamps + sorted entries) → byte-reproducible rebuilds.
  rm -f "$JAR"
  python3 "$HERE/pack_jar.py" "$CLASSES" "$WT/target/MANIFEST.MF" "$JAR"

  echo "oshi-core-$V.jar=oshi-core-$V-meow.jar" >> "$MANIFEST"
  echo "OK -> $JAR ($(wc -c < "$JAR") bytes)"
  git -C "$OSHI_REPO" worktree remove --force "$WT"
done

# Merge back preserved lines whose key this run did not produce.
if [ -f "$PRESERVED" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    grep -qF "${key}=" "$MANIFEST" 2>/dev/null || echo "$line" >> "$MANIFEST"
  done < "$PRESERVED"
  rm -f "$PRESERVED"
fi

echo "== manifest =="
cat "$MANIFEST"
