#!/bin/sh
# Build Meowcraft's OHOS lwjgl.jar from official LWJGL <ver> jars + clean-room GLFW overlay.
#
# This is the "jar" half of the lwjgl self-build (the natives half is
# build_lwjgl_natives.sh). It reproduces the shipped fat lwjgl.jar recipe:
#
#   official LWJGL modules (12)  +  clean-room GLFW overlay (~19 java files)
#   -> one merged jar, META-INF/cacio stripped, overlay wins on collisions.
#
# The overlay lives in tools/lwjgl/deltas/overlay; its RendererInit class matches
# our own bridge export Java_org_lwjgl_opengl_RendererInit_nativeInitGl4esInternals
# (see libs/meowcraftlib/src/main/cpp/meowcraftbridge/input_bridge.c).
#
# Standalone: every path is passed in, nothing is derived from the caller layout.
#
# Usage:
#   sh build_lwjgl_jar.sh --overlay DIR [--overlay DIR2 ...] [--official DIR]
#                         [--out DIR] [--work DIR] [--version 3.3.3] [--cache DIR]
#                         [--maven-base URL] [--offline] [--pack-jar FILE] [--manifest FILE]
#
# The official LWJGL modules are pulled from Maven Central (release, sha1-verified)
# and cached, so the stock base is the verifiable Maven RELEASE by default (stronger
# provenance than the historical 3.3.3-snapshot). Same "download if missing" pattern as
# tools/meow-launcher and tools/oshi.
#
# Required:
#   --overlay DIR    overlay source root (org/lwjgl/**); repeatable, applied in order
#                    (later wins). default <this dir>/deltas/overlay (common
#                    clean-room overlay). For a per-generation jar add the matching
#                    version overlay, e.g. --overlay deltas/overlay --overlay
#                    deltas/overlay-3.4.3 --version 3.4.3
# Optional:
#   --official DIR   local fallback dir for stock jars (also source of lwjglx, see below)
#   --out DIR        output dir for lwjgl.jar (default <work>/out)
#   --work DIR       scratch dir (default: <outer>/stuffs/research/lwjgl_build-<version>)
#   --version VER    LWJGL version to fetch (default 3.3.3)
#   --cache DIR      Maven cache dir (default <work>/m2)
#   --maven-base URL Maven repo base (default Maven Central)
#   --offline        never download; require every jar under --official
#   --with-lwjglx    ALSO merge lwjgl-lwjglx (LWJGL2 compat; DEFAULT: dropped)
#   --pack-jar FILE  deterministic packer (default ../oshi/pack_jar.py)
#   --manifest FILE  MANIFEST.MF to embed (default: extract from the core module jar)
#   -h, --help       show this help
#
# NB: `lwjgl-lwjglx` (LWJGL2 compat, NOT on Maven Central) is DROPPED by default:
# MC >= 1.17 does not reference any of its 163 unique classes (verified by scanning
# MC 1.21.10 + all MC libs + launcher.jar/gson). Use --with-lwjglx to include it.
#
# NOTE: javac needs a working JVM, which the agent shell does NOT have. Run this
# script yourself; the merge/pack steps are pure python/shell and reproducible.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"        # Meowcraft/ (app project)
OUTER="$(cd "$ROOT/.." && pwd)"          # workspace root (holds ref/ + stuffs/)

usage() { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//; /^set -e/d'; }

OFFICIAL=""; OVERLAYS=""; OUT=""; WORK=""; VERSION="3.3.3"; WITH_LWJGLX=0
CACHE=""; MAVEN_BASE="https://repo1.maven.org/maven2"; OFFLINE=0
PACK_JAR="$ROOT/tools/oshi/pack_jar.py"; MANIFEST=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --official)   OFFICIAL="$2";   shift 2 ;;
    --overlay)    OVERLAYS="$OVERLAYS $2"; shift 2 ;;
    --out)        OUT="$2";        shift 2 ;;
    --work)       WORK="$2";       shift 2 ;;
    --version)    VERSION="$2";    shift 2 ;;
    --cache)      CACHE="$2";      shift 2 ;;
    --maven-base) MAVEN_BASE="$2"; shift 2 ;;
    --offline)    OFFLINE=1;       shift ;;
    --with-lwjglx) WITH_LWJGLX=1;  shift ;;
    --pack-jar)   PACK_JAR="$2";   shift 2 ;;
    --manifest)   MANIFEST="$2";   shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$OVERLAYS" ] || OVERLAYS="$HERE/deltas/overlay"   # default clean-room overlay
for d in $OVERLAYS; do
  [ -d "$d" ] || { echo "error: overlay not a dir: $d" >&2; exit 2; }
done
[ -z "$OFFICIAL" ] || [ -d "$OFFICIAL" ] || { echo "error: not a dir: $OFFICIAL" >&2; exit 2; }
# resolve to absolute paths, preserving order (later overlays win on collisions)
ABS_OVERLAYS=""
for d in $OVERLAYS; do ABS_OVERLAYS="$ABS_OVERLAYS $(cd "$d" && pwd)"; done
OVERLAYS="$ABS_OVERLAYS"
FIRST_OVERLAY="${OVERLAYS# }"; FIRST_OVERLAY="${FIRST_OVERLAY%% *}"
# Guard: a per-generation overlay (deltas/overlay-<VERSION>) carries the version-pinned
# GLFW.java / GLCapabilities.java. If it exists but was not passed, the jar would silently
# miss them (or pick up another generation's) -> fail loudly at build time.
GEN_OVERLAY="$HERE/deltas/overlay-$VERSION"
if [ -d "$GEN_OVERLAY" ]; then
  found=0
  for d in $OVERLAYS; do [ "$d" = "$GEN_OVERLAY" ] && found=1; done
  [ "$found" = "1" ] || {
    echo "error: generation overlay exists but was not passed: $GEN_OVERLAY" >&2
    echo "       add: --overlay $GEN_OVERLAY" >&2
    exit 2; }
fi
[ -n "$OFFICIAL" ] && OFFICIAL="$(cd "$OFFICIAL" && pwd)"
[ -n "$WORK" ]  || WORK="$OUTER/stuffs/research/lwjgl_build-$VERSION"
[ -n "$OUT" ]   || OUT="$WORK/out"
[ -n "$CACHE" ] || CACHE="$WORK/m2"
mkdir -p "$WORK" "$OUT" "$CACHE"
WORK="$(cd "$WORK" && pwd)"; OUT="$(cd "$OUT" && pwd)"; CACHE="$(cd "$CACHE" && pwd)"
# reset scratch BEFORE fetching (so the cache, under $WORK, is not wiped after)
rm -rf "$WORK/overlay" "$WORK/classes" "$WORK/merge"
mkdir -p "$WORK/overlay" "$WORK/classes" "$WORK/merge"

# 8 Maven-published modules (LWJGL $VERSION). Dropped as proven dead for MC <= 1.21.x
# (verified by scanning MC 1.21.10 + all MC libs + launcher.jar/gson = 259 jars):
#   - lwjgl-lwjglx       (LWJGL2 compat, 163 unique classes, 0 refs; --with-lwjglx re-adds)
#   - nanovg/vma/shaderc/spvc (Vulkan/2D helpers, 0 refs for MC <= 1.21.x)
# MC >= 26.3's new `renderpearl` frontend DOES use vma/spvc/shaderc (shader compile /
# reflection / Vulkan memory) and SDL3, so for LWJGL >= 3.4.x we re-add them (see below).
MODULES="lwjgl lwjgl-glfw lwjgl-opengl lwjgl-openal lwjgl-stb \
lwjgl-vulkan lwjgl-freetype lwjgl-tinyfd"
# LWJGL >= 3.4.x additions (MC >= 26.3): SDL3 (dropped GLFW), plus renderpearl's
# vma/spvc/shaderc bindings. Their natives ship separately (libSDL3.so; shaderc/spvc/vma
# only if the GL path actually calls them).
WITH_SDL=0
case "$VERSION" in
  3.4.*|4.*) MODULES="$MODULES lwjgl-sdl lwjgl-vma lwjgl-spvc lwjgl-shaderc"; WITH_SDL=1 ;;
esac

# resolve_maven <group-path> <artifact> <version> -> path | empty
# Maven (release) wins; --official is the offline / not-on-Maven fallback. Verifies
# the published .sha1 (same "download if missing" spirit as tools/meow-launcher|oshi).
resolve_maven() {
  gp="$1"; art="$2"; ver="$3"
  dest="$CACHE/$gp/$art/$ver/$art-$ver.jar"
  if [ "$OFFLINE" != "1" ] && [ ! -s "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    echo "  fetch $art-$ver.jar ..." >&2
    code=$(curl -sL --max-time 180 --retry 3 -w '%{http_code}' -o "$dest" \
             "$MAVEN_BASE/$gp/$art/$ver/$art-$ver.jar" 2>/dev/null || echo 000)
    magic=$(dd if="$dest" bs=1 count=2 2>/dev/null)
    if [ "$code" != "200" ] || [ "$magic" != "PK" ]; then
      echo "  - $art-$ver.jar: not on Maven (http $code) -> fallback" >&2
      rm -f "$dest"
    else
      want=$(curl -sL --max-time 60 "$MAVEN_BASE/$gp/$art/$ver/$art-$ver.jar.sha1" 2>/dev/null | tr -dc '0-9a-fA-F' | cut -c1-40)
      got=$(sha1sum "$dest" 2>/dev/null | cut -d' ' -f1)
      if [ "$want" != "$got" ]; then
        echo "  ! $art-$ver.jar: sha1 mismatch (want=$want got=$got)" >&2
        rm -f "$dest"
      else
        echo "  ok $art-$ver.jar sha1=$got" >&2
      fi
    fi
  fi
  if [ -s "$dest" ]; then echo "$dest"; return; fi
  if [ -n "$OFFICIAL" ] && [ -s "$OFFICIAL/$art.jar" ]; then echo "$OFFICIAL/$art.jar"; return; fi
  echo ""
}

echo "=== resolve stock modules (release $VERSION from Maven${OFFICIAL:+; fallback $OFFICIAL}) ==="
MODULE_PATHS=""; CP=""
for a in $MODULES; do
  p="$(resolve_maven org/lwjgl "$a" "$VERSION")"
  [ -n "$p" ] || { echo "error: cannot resolve org.lwjgl:$a:$VERSION (need network or --official)" >&2; exit 2; }
  MODULE_PATHS="$MODULE_PATHS $p"; CP="$CP:$p"
done
# lwjgl-lwjglx is never on Maven and is dropped by default (dead for MC >= 1.17).
# Opt in with --with-lwjglx, resolved from --official, else the overlay's libs/ sibling.
if [ "$WITH_LWJGLX" != "1" ]; then
  echo "  lwjgl-lwjglx: dropped (dead for MC >= 1.17; --with-lwjglx to include)" >&2
else
  LWJGLX=""
  if [ -n "$OFFICIAL" ] && [ -s "$OFFICIAL/lwjgl-lwjglx.jar" ]; then
    LWJGLX="$OFFICIAL/lwjgl-lwjglx.jar"
  else
    LWJGLX="$(ls "$FIRST_OVERLAY/../../../libs"/*/lwjgl-lwjglx.jar 2>/dev/null | head -1)"
  fi
  if [ -n "$LWJGLX" ]; then MODULE_PATHS="$MODULE_PATHS $LWJGLX"; CP="$CP:$LWJGLX"
  else echo "  note: --with-lwjglx but jar not found (not on Maven; pass --official) -> skipped" >&2; fi
fi
CP="${CP#:}"
CORE_JAR="$(resolve_maven org/lwjgl lwjgl "$VERSION")"
JSR="$(resolve_maven com/google/code/findbugs jsr305 3.0.2)"
# LWJGL 3.4.x marks its public API with org.jspecify annotations; javac needs the
# jar on the classpath to read those signatures (our overlay does not import them).
JSPECIFY="$(resolve_maven org/jspecify jspecify 1.0.0)"
echo "  merged modules: $(echo $MODULE_PATHS | wc -w)   compile cp jars: $(echo "$CP" | tr ':' '\n' | grep -c .)"

echo "=== 1/5 stage overlay ==="
for d in $OVERLAYS; do cp -R "$d/." "$WORK/overlay/"; done

echo "=== 2/5 javac overlay (user-run) ==="
[ -n "$JSR" ] && [ -f "$JSR" ] && CP="$CP:$JSR"
[ -n "$JSPECIFY" ] && [ -f "$JSPECIFY" ] && CP="$CP:$JSPECIFY"
find "$WORK/overlay" -name '*.java' | LC_ALL=C sort > "$WORK/sources.txt"
echo "  overlay sources: $(wc -l < "$WORK/sources.txt")  cp: $(echo "$CP" | tr ':' '\n' | wc -l) jars"
# The agent shell cannot init a JVM ("Failed to mark memory page as executable");
# detect that early and bail gracefully so the user runs just the javac step.
if ! javac -version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[NO USABLE JVM] javac cannot initialise in this shell. Run this script from a
shell with a working JDK (source/target 8). Everything up to here is prepared
under --work; a successful javac + the remaining steps produce the jar.
EOF
  exit 3
fi
javac -encoding UTF-8 --release 8 -XDignore.symbol.file -proc:none -nowarn -g:none \
      -cp "$CP" -d "$WORK/classes" @"$WORK/sources.txt" || \
  javac -encoding UTF-8 -source 8 -target 8 -nowarn -g:none -cp "$CP" \
      -d "$WORK/classes" @"$WORK/sources.txt"

echo "=== 3/5 merge official classes + overlay (overlay wins) ==="
for p in $MODULE_PATHS; do
  ( cd "$WORK/merge" && unzip -o -q "$p" \
      -x 'META-INF/*' 'net/java/openjdk/cacio/*' )
done
# overlay classes (org/** only) copied last so they override official
( cd "$WORK/classes" && find org -name '*.class' 2>/dev/null | while IFS= read -r f; do
    mkdir -p "$WORK/merge/$(dirname "$f")"
    cp "$f" "$WORK/merge/$f"
  done )
rm -rf "$WORK/merge/META-INF" "$WORK/merge/net" "$WORK/merge/android" "$WORK/merge/module-info.class"

echo "=== 4/5 deterministic pack ==="
if [ -z "$MANIFEST" ]; then
  MANIFEST="$WORK/MANIFEST.MF"
  # Reuse the official core manifest (keeps Specification-Version etc.)
  unzip -p "$CORE_JAR" META-INF/MANIFEST.MF > "$MANIFEST" 2>/dev/null || \
    printf 'Manifest-Version: 1.0\n\n' > "$MANIFEST"
fi
python3 "$PACK_JAR" "$WORK/merge" "$MANIFEST" "$OUT/lwjgl.jar"

echo "=== 5/5 sanity ==="
python3 - "$OUT/lwjgl.jar" "$WITH_SDL" <<'PY'
import sys, zipfile
z=zipfile.ZipFile(sys.argv[1]); names=z.namelist()
with_sdl=(len(sys.argv)>2 and sys.argv[2]=="1")
cls=[n for n in names if n.endswith(".class")]
must=["org/lwjgl/glfw/GLFW.class","org/lwjgl/glfw/CallbackBridge.class",
      "org/lwjgl/glfw/GLFWWindowProperties.class","org/lwjgl/opengl/GLCapabilities.class",
      "org/lwjgl/opengl/RendererInit.class","org/lwjgl/util/freetype/FreeType.class",
      "org/lwjgl/openal/AL.class","org/lwjgl/stb/STBImage.class","org/lwjgl/vulkan/VK10.class"]
if with_sdl:
    must += ["org/lwjgl/sdl/SDL.class",
             "org/lwjgl/util/shaderc/ShadercIncludeResultReleaseI.class",
             "org/lwjgl/util/vma/Vma.class","org/lwjgl/util/spvc/Spvc.class"]
miss=[m for m in must if m not in names]
print("  classes:",len(cls),"(lwjglx:","yes" if "org/lwjgl/Sys.class" in names else "no",")")
print("  must-have missing:",miss or "none")
print("  no android/util:", not any(n.startswith("android/") for n in names))
bad=[n for n in names if n.startswith("META-INF/") and n!="META-INF/MANIFEST.MF"]
print("  stripped META-INF (except MANIFEST):", not bad)
assert not miss, "missing required classes: %s"%miss
assert len(cls)>=4000, "class count too low: %d"%len(cls)
glfw=z.read("org/lwjgl/glfw/GLFW.class")
print("  GLFW libname token:", "meowcraftbridge" if b"meowcraftbridge" in glfw else "??")
PY

echo "OK -> $OUT/lwjgl.jar ($(wc -c < "$OUT/lwjgl.jar") bytes)  [LWJGL $VERSION]"
sha256sum "$OUT/lwjgl.jar"
echo "== next: python3 tools/lwjgl/pack_extras.py …  (assemble lwjgl-$VERSION.jar into the bundle; see README §3)"
