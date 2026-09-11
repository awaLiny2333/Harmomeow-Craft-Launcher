#!/bin/sh
# Verify that the LWJGL2 artifacts we ship are reproducible.
#
# Why this script exists (project rule, notes/00-current/工程与规范.md:126-127):
#   never claim "byte-identical / reproducible / verified" without doing the check yourself
#   in this very session; the standard is >=2 (recommended 3) CLEAN rebuilds + `cmp`.
# (History: the OpenAL campaign once asserted reproducibility after a single build and was
#  rightly challenged — see notes/40-adaptation/openal-ohos.md:112-113.)
#
# Two independent checks:
#   A. native  (`liblwjgl.so`): 3 clean builds into separate dirs -> sha256 + cmp.
#      Needs only the OHOS SDK (no JVM) — can be run by anyone/CI.
#   B. generator (`--with-generator`): snapshot src/generated + src/native/generated +
#      src/hdrs-meow, re-run generate_sources.sh, then diff -r. Needs a JDK (human only).
#
# Usage:
#   sh tools/lwjgl2/verify_reproducible.sh [--with-generator] \
#       [--src DIR] [--sdk-native DIR] [--work DIR] [--nout]
#     --src         LWJGL2 tree      (default: <ws>/ref/lwjgl)
#     --sdk-native  OHOS SDK native  (required for check A)
#     --work        scratch dir      (default: <ws>/stuffs/lwjgl2/repro)
#     --nout        keep the built .so files (default: removed after cmp)
# Exits non-zero on the first failed check.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
WS="$(cd "$PROJ/.." && pwd)"

WITH_GEN=0; SRC="$WS/ref/lwjgl"; SDK_NATIVE=""; WORK="$WS/stuffs/lwjgl2/repro"; KEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-generator) WITH_GEN=1; shift ;;
    --src)         [ $# -ge 2 ] || { echo "error: --src needs a value" >&2; exit 2; }; SRC="$2"; shift 2 ;;
    --sdk-native)  [ $# -ge 2 ] || { echo "error: --sdk-native needs a value" >&2; exit 2; }; SDK_NATIVE="$2"; shift 2 ;;
    --work)        [ $# -ge 2 ] || { echo "error: --work needs a value" >&2; exit 2; }; WORK="$2"; shift 2 ;;
    --nout)        KEEP=1; shift ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "=== A. native: 3 clean rebuilds + cmp  (src=$SRC) ==="
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required for check A" >&2; exit 2; }
rm -rf "$WORK"; mkdir -p "$WORK"
i=1
while [ "$i" -le 3 ]; do
  sh "$HERE/build_lwjgl2_meow.sh" --src "$SRC" --sdk-native "$SDK_NATIVE" \
     --out "$WORK/n$i" --build "$WORK/b$i" --with-display > "$WORK/n$i.log" 2>&1 \
     || { echo "FAIL: rebuild $i"; tail -5 "$WORK/n$i.log"; exit 1; }
  i=$((i + 1))
done
sha1=$(sha256sum "$WORK/n1/liblwjgl.so" | cut -d' ' -f1)
sha2=$(sha256sum "$WORK/n2/liblwjgl.so" | cut -d' ' -f1)
sha3=$(sha256sum "$WORK/n3/liblwjgl.so" | cut -d' ' -f1)
echo "  sha256 n1=$sha1"
echo "  sha256 n2=$sha2"
echo "  sha256 n3=$sha3"
[ "$sha1" = "$sha2" ] && [ "$sha1" = "$sha3" ] || { echo "FAIL: hashes differ"; exit 1; }
cmp "$WORK/n1/liblwjgl.so" "$WORK/n2/liblwjgl.so" >/dev/null || { echo "FAIL: cmp n1 n2"; exit 1; }
cmp "$WORK/n1/liblwjgl.so" "$WORK/n3/liblwjgl.so" >/dev/null || { echo "FAIL: cmp n1 n3"; exit 1; }
# Determinism extras: nothing may embed paths or build timestamps.
if strings -a "$WORK/n1/liblwjgl.so" | grep -qE "/storage/|/Users/|/data/service|SOURCE_DATE"; then
  echo "FAIL: the .so embeds an absolute path"; exit 1; fi
echo "  PASS: 3x byte-identical (cmp), no embedded paths, sha256=$sha1"
if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK/n2" "$WORK/n3"; fi

if [ "$WITH_GEN" -eq 1 ]; then
  echo "=== B. generator: re-run generate_sources.sh and diff -r ==="
  command -v javac >/dev/null 2>&1 || { echo "SKIP: no javac on PATH (needs a JDK)"; exit 3; }
  SNAP="$WORK/gen-snap"; mkdir -p "$SNAP"
  for d in src/generated src/native/generated src/hdrs-meow; do
    [ -d "$SRC/$d" ] || { echo "error: $SRC/$d missing - run generate_sources.sh first" >&2; exit 2; }
    mkdir -p "$SNAP/$d"
    cp -a "$SRC/$d/." "$SNAP/$d/"
  done
  sh "$HERE/generate_sources.sh" > "$WORK/gen.log" 2>&1 || { echo "FAIL: generate_sources.sh"; tail -5 "$WORK/gen.log"; exit 1; }
  for d in src/generated src/native/generated src/hdrs-meow; do
    if diff -r "$SNAP/$d" "$SRC/$d" > "$WORK/gen-diff.txt" 2>&1; then
      echo "  PASS: $d identical ($(find "$SRC/$d" -type f | wc -l) files)"
    else
      echo "  FAIL: $d differs:"; head -10 "$WORK/gen-diff.txt"; exit 1
    fi
  done
  echo "  PASS: generator output is byte-identical"
fi

echo "OK"
