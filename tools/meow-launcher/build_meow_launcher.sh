#!/bin/sh
# Build the clean-room meow.launcher jar from source.
#
# Reproducibility: with javac 17.0.13 this script plus finalize_for_meowcraft.sh rebuilds the
# shipped launcher.jar byte for byte (72426aca..., 21191 B) -- measured, so the JDK version is
# part of the recipe (javac is invoked with --release 17).
# Contents: `meow.launcher.*` (own implementation) + clean-room `com.mojang.text2speech`
# narrator stub + vendored Apache-2.0 `android/util/*` (needed by our lwjgl.jar GLFW).
# NO third-party/GPL code, no `net.kdt`, no native loadLibrary.
#
# gson is a COMPILE-ONLY dependency: this jar keeps `com.google.gson` references; the
# shade to `meow.gson` happens in finalize (tools/relocate_gson.py). gson is fetched
# from Maven Central with the published `.sha1` verified (same pattern as tools/lwjgl).
#
# javac must be run by YOU (the agent shell has no runnable JVM).
#
# Usage:
#   sh build_meow_launcher.sh [--src DIR] [--out DIR] [--work DIR] [--cache DIR]
#                             [--gson FILE] [--offline] [--pack-jar FILE] [--manifest FILE]
#
# Optional:
#   --src DIR        source root (default: <this dir>/src)
#   --out DIR        output dir for launcher.jar (default <work>/out)
#   --work DIR       scratch dir (default <outer>/stuffs/research/meow_launcher_build)
#   --cache DIR      Maven cache (default <work>/m2)
#   --gson FILE      explicit gson-2.13.1.jar (skips download)
#   --offline        never download; require --gson or a cached gson
#   --pack-jar FILE  deterministic packer (default ../oshi/pack_jar.py)
#   --manifest FILE  MANIFEST.MF (default <this dir>/MANIFEST.MF)
#   -h, --help       show this help
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"        # Meowcraft/ (app project)
OUTER="$(cd "$ROOT/.." && pwd)"          # workspace root (holds ref/ + stuffs/)

usage() { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//; /^set -e/d'; }

SRC=""; OUT=""; WORK=""; CACHE=""; GSON=""; OFFLINE=0; VERSION="2.13.1"
PACK_JAR="$ROOT/tools/oshi/pack_jar.py"; MANIFEST="$HERE/MANIFEST.MF"
MAVEN_BASE="https://repo1.maven.org/maven2"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)      SRC="$2";      shift 2 ;;
    --out)      OUT="$2";      shift 2 ;;
    --work)     WORK="$2";     shift 2 ;;
    --cache)    CACHE="$2";    shift 2 ;;
    --gson)     GSON="$2";     shift 2 ;;
    --offline)  OFFLINE=1;     shift ;;
    --pack-jar) PACK_JAR="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$SRC" ] || SRC="$HERE/src"
[ -d "$SRC" ] || { echo "error: not a dir: $SRC" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "error: manifest not found: $MANIFEST" >&2; exit 2; }
[ -n "$WORK" ]  || WORK="$OUTER/stuffs/research/meow_launcher_build"
[ -n "$OUT" ]   || OUT="$WORK/out"
[ -n "$CACHE" ] || CACHE="$WORK/m2"
mkdir -p "$WORK" "$OUT" "$CACHE"
WORK="$(cd "$WORK" && pwd)"; OUT="$(cd "$OUT" && pwd)"; CACHE="$(cd "$CACHE" && pwd)"

# ---- resolve gson-2.13.1.jar (compile-only) ---------------------------------
if [ -z "$GSON" ]; then
  cached="$CACHE/com/google/code/gson/gson/$VERSION/gson-$VERSION.jar"
  if [ -s "$cached" ]; then
    GSON="$cached"
  elif [ "$OFFLINE" != "1" ]; then
    rel="com/google/code/gson/gson/$VERSION/gson-$VERSION.jar"
    mkdir -p "$(dirname "$cached")"
    echo "=== fetch gson-$VERSION.jar ==="
    code=$(curl -sL --max-time 120 --retry 3 -w '%{http_code}' -o "$cached" \
             "$MAVEN_BASE/$rel" 2>/dev/null || echo 000)
    magic=$(dd if="$cached" bs=1 count=2 2>/dev/null)
    if [ "$code" != "200" ] || [ "$magic" != "PK" ]; then
      rm -f "$cached"; echo "error: gson fetch failed (http $code)" >&2; exit 2
    fi
    want=$(curl -sL --max-time 60 "$MAVEN_BASE/$rel.sha1" 2>/dev/null | tr -dc '0-9a-fA-F' | cut -c1-40)
    got=$(sha1sum "$cached" | cut -d' ' -f1)
    [ "$want" = "$got" ] || { echo "error: gson sha1 mismatch (want=$want got=$got)" >&2; rm -f "$cached"; exit 2; }
    echo "  ok gson-$VERSION.jar sha1=$got"
    GSON="$cached"
  fi
fi
[ -n "$GSON" ] && [ -f "$GSON" ] || { echo "error: gson not available; pass --gson FILE" >&2; exit 2; }

# ---- compile ----------------------------------------------------------------
rm -rf "$WORK/classes" "$WORK/sources.txt"
mkdir -p "$WORK/classes"
find "$SRC" -name '*.java' | LC_ALL=C sort > "$WORK/sources.txt"
echo "=== javac (user-run) ==="
echo "  sources: $(wc -l < "$WORK/sources.txt")  cp: $(basename "$GSON")"
if ! javac -version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[NO USABLE JVM] javac cannot initialise in this shell. Run this script from a
shell with a working JDK (17+). Everything up to here is prepared under --work.
EOF
  exit 3
fi
javac -encoding UTF-8 --release 17 -nowarn -g:none -cp "$GSON" \
      -d "$WORK/classes" @"$WORK/sources.txt"

# ---- deterministic pack -----------------------------------------------------
python3 "$PACK_JAR" "$WORK/classes" "$MANIFEST" "$OUT/launcher.jar"

# ---- sanity -----------------------------------------------------------------
python3 - "$OUT/launcher.jar" <<'PY'
import sys, zipfile
n = zipfile.ZipFile(sys.argv[1]).namelist()
must = ["meow/launcher/MeowLauncher.class", "meow/launcher/MeowClassLoader.class",
        "com/mojang/text2speech/Narrator.class",
        "meow/launcher/Account.class", "meow/launcher/VersionLoader.class",
        "meow/launcher/ArgBuilder.class", "meow/launcher/LibraryResolver.class"]
miss = [m for m in must if m not in n]
bad = [x for x in n if x.startswith("net/kdt/") or x.startswith("org/jackhuang/")]
print("  classes:", len([x for x in n if x.endswith('.class')]))
print("  must-have missing:", miss or "none")
print("  foreign residue:", bad or "none")
print("  android/ classes:", sum(1 for x in n if x.startswith("android/")))
# no com.google.gson class entries (gson is compile-only, not bundled)
bundled = [x for x in n if x.startswith("com/google/gson/")]
print("  bundled gson classes:", len(bundled))
assert not miss, "missing: %s" % miss
assert not bad, "foreign residue: %s" % bad
assert not bundled, "gson must not be bundled"
assert not any(x.startswith("android/") for x in n), "android/util no longer needed"
assert any(x.endswith(".class") and b"com/google/gson" in zipfile.ZipFile(sys.argv[1]).read(x)
           for x in n), "launcher must still reference com.google.gson (shaded later)"
PY

echo "OK -> $OUT/launcher.jar ($(wc -c < "$OUT/launcher.jar") bytes)"
sha256sum "$OUT/launcher.jar"
echo "== next: sh tools/meow-launcher/finalize_for_meowcraft.sh"
