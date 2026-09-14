#!/bin/sh
# Install a LWJGL generation's natives into the (flat, packaged) module libs dir
# under generation-qualified names, and keep a manifest.
#
# Why flat + generation-qualified: hvigor only packages top-level `libs/<abi>/*.so`
# (subdirs are dropped), and every MC version is served by ONE JRE HSP whose namespace
# must hold all generations side by side -> same base name, so the generation tag goes
# right AFTER the base: `liblwjgl_343.so`, `liblwjgl_343_opengl.so`,
# `liblwjgl_343_stb.so`. LWJGL is told the tag at launch via MeowBundledNameMapper
# (`-Dmeow.lwjgl.gen=<tag>`) -- the two MUST stay in lockstep.
#
# Usage:
#   sh tools/lwjgl/install_natives.sh <tag> [--src DIR] [--libs DIR]
#   sh tools/lwjgl/install_natives.sh --clean <tag> [--libs DIR]
#   sh tools/lwjgl/install_natives.sh --list [--libs DIR]
#   sh tools/lwjgl/install_natives.sh --verify [--libs DIR]   # assert every manifest entry on disk
#   sh tools/lwjgl/install_natives.sh --sdl FILE [--libs DIR]       # install our SDL3 fork as libSDL3.so (tag common)
#   sh tools/lwjgl/install_natives.sh --native NAME=PATH [--libs DIR]  # install a gen-agnostic native (tag common)
#
#   <tag>        LWJGL generation, e.g. 3.4.3 -> names liblwjgl_343{,_opengl,_stb}.so
#   --src DIR    dir with liblwjgl{,_opengl,_stb}.so (default: auto-detect under
#                stuffs/research/lwjgl_natives[-<tag>]/out)
#   --sdl FILE   our SDL3 build (tools/sdl/out/libSDL3.so) -> installed as libSDL3.so
#   --native     NAME=PATH, e.g. libshaderc.so=stuffs/research/shaderc/out/libshaderc.so
#   --libs DIR   flat packaged dir (default libs/meowlwjgls/libs/arm64-v8a)
#
# Manifest: <libs>/../natives.manifest, lines "<tag>  <file>  <sha256>".
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
WS="$(cd "$PROJ/.." && pwd)"

TAG=""; MODE=install; SRC=""; SDL_SO=""; NATIVE_SPEC=""; LIBS="$PROJ/libs/meowlwjgls/libs/arm64-v8a"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean) MODE=clean; TAG="$2"; shift 2 ;;
    --list)  MODE=list;  shift ;;
    --verify) MODE=verify; shift ;;
    --src)   SRC="$2";    shift 2 ;;
    --sdl)   MODE=sdl; SDL_SO="$2"; shift 2 ;;
    --native) MODE=native; NATIVE_SPEC="$2"; shift 2 ;;
    --libs)  LIBS="$2";   shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) TAG="$1"; shift ;;
  esac
done
LIBS_ABS="$(cd "$LIBS" 2>/dev/null && pwd || true)"
[ -n "$LIBS_ABS" ] || { echo "error: --libs not a dir: $LIBS" >&2; exit 2; }
MANIFEST="$(cd "$LIBS_ABS/.." && pwd)/natives.manifest"

if [ "$MODE" = list ]; then
  [ -f "$MANIFEST" ] && cat "$MANIFEST" || echo "(no manifest at $MANIFEST)"
  exit 0
fi

if [ "$MODE" = verify ]; then
  # Build-time guard: every manifest entry must exist on disk with matching sha256.
  [ -f "$MANIFEST" ] || { echo "error: no manifest at $MANIFEST" >&2; exit 2; }
  fail=0
  while IFS="$(printf '\t')" read -r tag file sha; do
    [ -n "$file" ] || continue
    if [ ! -f "$LIBS_ABS/$file" ]; then echo "MISSING $tag $file" >&2; fail=1; continue; fi
    got="$(sha256sum "$LIBS_ABS/$file" | cut -d' ' -f1)"
    if [ "$got" != "$sha" ]; then echo "DRIFT   $tag $file (sha $got != $sha)" >&2; fail=1;
    else echo "ok      $tag $file"; fi
  done < "$MANIFEST"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

if [ "$MODE" = sdl ]; then
  # Generation-agnostic SDL3 native (MC >= 26.3 drives window/input/GL through SDL3).
  # No per-generation suffix: MeowBundledNameMapper passes "SDL3" straight through, so
  # LWJGL resolves mapLibraryNameBundled("SDL3") -> libSDL3.so.
  [ -f "$SDL_SO" ] || { echo "error: --sdl file not found: $SDL_SO" >&2; exit 2; }
  cp "$SDL_SO" "$LIBS_ABS/libSDL3.so"
  grep -v "$(printf '^common\tlibSDL3.so\t')" "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
  printf 'common\t%s\t%s\n' "libSDL3.so" \
    "$(sha256sum "$LIBS_ABS/libSDL3.so" | cut -d' ' -f1)" >> "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  echo "installed SDL3 -> $LIBS_ABS/libSDL3.so"
  exit 0
fi

if [ "$MODE" = native ]; then
  # Generic generation-agnostic native: --native NAME=PATH installs PATH under NAME
  # (manifest tag "common"), e.g. libshaderc.so / libspirv-cross.so.
  name="${NATIVE_SPEC%%=*}"; src="${NATIVE_SPEC#*=}"
  [ -n "$name" ] && [ "$src" != "$NATIVE_SPEC" ] && [ -f "$src" ] || {
    echo "error: --native expects NAME=PATH (file must exist): $NATIVE_SPEC" >&2; exit 2; }
  cp "$src" "$LIBS_ABS/$name"
  grep -v "$(printf '^common\t%s\t' "$name")" "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
  printf 'common\t%s\t%s\n' "$name" "$(sha256sum "$LIBS_ABS/$name" | cut -d' ' -f1)" >> "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  echo "installed native $name -> $LIBS_ABS/$name"
  exit 0
fi

[ -n "$TAG" ] || { echo "error: <tag> is required" >&2; exit 2; }
DIGITS="$(printf '%s' "$TAG" | tr -d '.')"
BASES="liblwjgl liblwjgl_opengl liblwjgl_stb"

# Shipped file name for a stock native base: the generation tag goes right AFTER the base,
# so the three natives line up (lwjgl -> liblwjgl_343.so, lwjgl_opengl ->
# liblwjgl_343_opengl.so, lwjgl_stb -> liblwjgl_343_stb.so). Must stay in lockstep with
# MeowBundledNameMapper (the Java side that decides what LWJGL looks for).
gen_name() {   # <base> <digits>
  case "$1" in
    liblwjgl)        echo "liblwjgl_$2.so" ;;
    liblwjgl_opengl) echo "liblwjgl_$2_opengl.so" ;;
    liblwjgl_stb)    echo "liblwjgl_$2_stb.so" ;;
  esac
}

strip_tag() {  # print manifest without the given tag's lines
  [ -f "$MANIFEST" ] && grep -v "^$1	" "$MANIFEST" || true
}

if [ "$MODE" = clean ]; then
  for b in $BASES; do rm -f "$LIBS_ABS/$(gen_name "$b" "$DIGITS")"; done
  strip_tag "$TAG" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST" || true
  echo "cleaned generation $TAG (tag _$DIGITS)"
  exit 0
fi

# --- install ---
if [ -z "$SRC" ]; then
  for d in "$WS/stuffs/research/lwjgl_natives-$TAG/out" "$WS/stuffs/research/lwjgl_natives/out"; do
    if [ -f "$d/liblwjgl.so" ]; then SRC="$d"; break; fi
  done
fi
[ -n "$SRC" ] && [ -f "$SRC/liblwjgl.so" ] || {
  echo "error: natives not found; pass --src DIR (needs liblwjgl{,_opengl,_stb}.so)" >&2; exit 2; }

strip_tag "$TAG" > "$MANIFEST.tmp"
for b in $BASES; do
  [ -f "$SRC/$b.so" ] || { echo "error: missing $SRC/$b.so" >&2; exit 2; }
  name="$(gen_name "$b" "$DIGITS")"
  cp "$SRC/$b.so" "$LIBS_ABS/$name"
  printf '%s\t%s\t%s\n' "$TAG" "$name" \
    "$(sha256sum "$LIBS_ABS/$name" | cut -d' ' -f1)" >> "$MANIFEST.tmp"
done
mv "$MANIFEST.tmp" "$MANIFEST"

# Generation-agnostic native: tinyfd (MC >= 1.22 NativeLibrariesBootstrap eagerly loads it).
# No per-generation suffix (MeowBundledNameMapper passes "lwjgl_tinyfd" through); one file
# serves every generation, recorded in the manifest with the pseudo-tag "common".
if [ -f "$SRC/liblwjgl_tinyfd.so" ]; then
  cp "$SRC/liblwjgl_tinyfd.so" "$LIBS_ABS/liblwjgl_tinyfd.so"
  grep -v "^common	liblwjgl_tinyfd.so	" "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
  printf 'common\t%s\t%s\n' "liblwjgl_tinyfd.so" \
    "$(sha256sum "$LIBS_ABS/liblwjgl_tinyfd.so" | cut -d' ' -f1)" >> "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
fi

echo "installed generation $TAG -> $LIBS_ABS (tag _$DIGITS)"
grep "^$TAG	" "$MANIFEST" | sed 's/^/  /'
