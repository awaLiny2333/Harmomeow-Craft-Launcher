#!/bin/sh
# Build Meowcraft's OHOS LWJGL2 native: liblwjgl.so  (MC 1.7–1.12 / LWJGL 2.9.x).
#
# Upstream's native build is Ant + GCC (platform_build/linux_ant/build.xml) linking
# X11 / GLX / jawt — unusable here (no Ant; no X11/GLX/jawt on OHOS). As with the
# LWJGL3 natives (tools/lwjgl/build_lwjgl_natives.sh drives clang directly instead of
# Ant), this script invokes the OHOS clang driver itself and replicates the essential
# upstream flags:
#
#   compile: -O2 -Wall -c -fPIC -std=c99 -Wunused -pthread        (upstream cflags64)
#            -I<src>/native/common -I<src>/native/common/opengl
#            -I<src>/hdrs-meow                                (javac -h headers)
#   link:    -shared -O2 -Wall -o liblwjgl.so -lm -lpthread       (upstream libs64)
#            ...MINUS -lX11 -lXext -lXcursor -lXrandr -lXxf86vm -ljawt (no OHOS equivalent)
#            and MINUS -Wl,--version-script,lwjgl.map: that script is GLX-shaped and
#            would hide most of our export surface.
#
# Source set = upstream compile set MINUS everything X11/GLX/AWT/OpenCL, which is
# either unused by MC or replaced under tools/lwjgl2/src-ohos/:
#   native/common/*.c        (skip org_lwjgl_opencl_CL.c, org_lwjgl_opencl_CallbackUtil.c,
#                             org_lwjgl_opengl_AWTSurfaceLock.c, extcl.c)
#   native/common/opengl/*.c (extgl.c, GLContext.c, CallbackUtil.c, NV*Util.c)
#   native/generated/{opengl,openal}/*.c   (from generate_sources.sh)
#   native/linux/linux_al.c  (generic dlopen-based OpenAL loader — no X11)
#   src-ohos/meow_extgl.c, src-ohos/meow_sys.c
#
# Stage 1 (default) ships Sys + GL glue + OpenAL. Display/context/input natives
# (Java_org_lwjgl_opengl_Linux*) are stage 2 (--with-display) and need
# src-ohos/meow_display.c + meow_context.c + meow_input.c + meow_cursor.c.
#
# Standalone: every path is passed in, nothing is derived from the caller layout.
#
# Usage:
#   sh build_lwjgl2_meow.sh --src DIR --sdk-native DIR --out DIR \
#       [--build DIR] [--arch NAME] [--jni-inc DIR] \
#       [--with-display] [--compare DIR]
#
# Required:
#   --src DIR         LWJGL2 source tree (ref/lwjgl), with src/hdrs-meow already generated
#   --sdk-native DIR  OHOS SDK native dir (contains sysroot/ and llvm/bin)
#   --out DIR         output dir; receives liblwjgl.so
#
# Optional:
#   --build DIR       out-of-tree build dir (default: <ws>/stuffs/lwjgl2/build)
#   --arch NAME       OHOS arch (default: arm64-v8a)
#   --jni-inc DIR     dir with jni.h/jni_md.h (default: repo meowcraftbridge headers)
#   --with-display    also compile the stage-2 display/context/input layer
#   --compare DIR     shipped-native reference dir (optional; symbol parity report)
#   -h, --help        show this help
#
# Emits a stripped .so with the OHOS .permission/.codesign/.comment sections removed,
# then asserts the export surface, that no X11/GLX/jawt/GL library crept into
# DT_NEEDED, and that .note.ohos is present.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # Meowcraft/ (app project)
WS="$(cd "$ROOT/.." && pwd)"               # workspace root (holds ref/ + stuffs/)

usage() { sed -n '2,/^set -e$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; }

SRC=""; SDK_NATIVE=""; OUT=""; BUILD=""; ARCH=arm64-v8a
JNIINC=""; WITH_DISPLAY=0; COMPARE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --src) [ $# -ge 2 ] || { echo "error: --src needs a value" >&2; exit 2; };          SRC="$2";        shift 2 ;;
    --sdk-native) [ $# -ge 2 ] || { echo "error: --sdk-native needs a value" >&2; exit 2; };   SDK_NATIVE="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || { echo "error: --out needs a value" >&2; exit 2; };          OUT="$2";        shift 2 ;;
    --build) [ $# -ge 2 ] || { echo "error: --build needs a value" >&2; exit 2; };        BUILD="$2";      shift 2 ;;
    --arch) [ $# -ge 2 ] || { echo "error: --arch needs a value" >&2; exit 2; };         ARCH="$2";       shift 2 ;;
    --jni-inc) [ $# -ge 2 ] || { echo "error: --jni-inc needs a value" >&2; exit 2; };      JNIINC="$2";     shift 2 ;;
    --with-display) WITH_DISPLAY=1;  shift ;;
    --compare) [ $# -ge 2 ] || { echo "error: --compare needs a value" >&2; exit 2; };      COMPARE="$2";    shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ]        || { echo "error: --src is required" >&2; usage >&2; exit 2; }
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]        || { echo "error: --out is required" >&2; usage >&2; exit 2; };

case "$SRC$OUT$SDK_NATIVE$BUILD" in
  *" "*) echo "error: paths containing spaces are not supported" >&2; exit 2 ;;
esac

# ---- arch -> OHOS target triple --------------------------------------------
# The SDK ships clang wrappers under the fully-qualified triple (e.g.
# aarch64-unknown-linux-ohos-clang) while the CMake toolchain uses the short one;
# accept either and fall back to `clang --target=<full triple>`.
case "$ARCH" in
  arm64-v8a)   TRIPLE="aarch64-linux-ohos"; WRAP="aarch64-unknown-linux-ohos" ;;
  armeabi-v7a) TRIPLE="arm-linux-ohos";     WRAP="armv7-unknown-linux-ohos"   ;;
  x86_64)      TRIPLE="x86_64-linux-ohos";  WRAP="x86_64-unknown-linux-ohos"  ;;
  *) echo "error: unsupported --arch '$ARCH' (use arm64-v8a/armeabi-v7a/x86_64)" >&2; exit 2 ;;
esac

# ---- layout -----------------------------------------------------------------
NATIVE="$SRC/src/native"
GENJ="$SRC/src/generated"
HDRS="$SRC/src/hdrs-meow"                  # javac -h output (generate_sources.sh)
OHOS="$HERE/src-ohos"
[ -d "$NATIVE" ] || { echo "error: not a lwjgl2 tree: $SRC" >&2; exit 2; }
[ -d "$GENJ" ] && [ -d "$HDRS" ] || {
  echo "error: generated sources not found; run tools/lwjgl2/generate_sources.sh first" >&2; exit 2; }

# ---- toolchain --------------------------------------------------------------
SYSROOT="$SDK_NATIVE/sysroot"
# NOTE: this SDK's llvm/bin ships llvm-{nm,objcopy,readobj,objdump,ar,size,strings}
# but NOT llvm-strip/llvm-readelf (the names the LWJGL3 script used). Strip therefore
# goes through llvm-objcopy and the ELF assertions through llvm-readobj.
OBJCOPY="$SDK_NATIVE/llvm/bin/llvm-objcopy"
NM="$SDK_NATIVE/llvm/bin/llvm-nm"
READOBJ="$SDK_NATIVE/llvm/bin/llvm-readobj"

[ -d "$SDK_NATIVE" ] || { echo "error: OHOS SDK native dir not found: $SDK_NATIVE" >&2; exit 2; }
[ -d "$SYSROOT" ]    || { echo "error: SDK sysroot not found: $SYSROOT" >&2; exit 2; }
[ -x "$NM" ]         || { echo "error: llvm-nm not found: $NM" >&2; exit 2; };

CC=""
for cand in "$TRIPLE-clang" "$WRAP-clang"; do
  if [ -x "$SDK_NATIVE/llvm/bin/$cand" ]; then CC="$SDK_NATIVE/llvm/bin/$cand"; break; fi
done
if [ -z "$CC" ]; then
  CC="$SDK_NATIVE/llvm/bin/clang"
  TARGET_FLAGS="--target=$WRAP --sysroot=$SYSROOT"
fi

# ---- JNI headers ------------------------------------------------------------
if [ -z "$JNIINC" ]; then
  for d in "$ROOT/libs/meowcraftlib/src/main/cpp/meowcraftbridge"; do
    if [ -f "$d/jni.h" ]; then JNIINC="$d"; break; fi
  done
fi
[ -n "$JNIINC" ] && [ -f "$JNIINC/jni.h" ] || {
  echo "error: jni.h not found; pass --jni-inc DIR (needs jni.h + jni_md.h)" >&2; exit 2; }

# ---- source set -------------------------------------------------------------
SRCS=""
add() { if [ -f "$1" ]; then SRCS="$SRCS $1"; fi; }

for f in "$NATIVE/common"/*.c; do
  case "$(basename "$f")" in
    # OpenCL (we build no CL) and AWT (no jawt on OHOS) — dropped in the port.
    org_lwjgl_opencl_CL.c|org_lwjgl_opencl_CallbackUtil.c|org_lwjgl_opengl_AWTSurfaceLock.c|extcl.c)
      continue ;;
  esac
  add "$f"
done
for f in "$NATIVE/common/opengl"/*.c; do add "$f"; done
for f in "$NATIVE/generated/opengl"/*.c; do add "$f"; done
for f in "$NATIVE/generated/openal"/*.c; do add "$f"; done
add "$NATIVE/linux/linux_al.c"
add "$OHOS/meow_extgl.c"
add "$OHOS/meow_sys.c"
if [ "$WITH_DISPLAY" -eq 1 ]; then
  add "$OHOS/meow_display.c"
  add "$OHOS/meow_context.c"
  add "$OHOS/meow_input.c"
  add "$OHOS/meow_cursor.c"
fi

# ---- flags ------------------------------------------------------------------
CF_COMMON="$TARGET_FLAGS -D__MUSL__ -O2 -fPIC -std=c99 -pthread -Wall -Wunused \
-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 \
-I$JNIINC -I$HDRS -I$NATIVE/common -I$NATIVE/common/opengl -I$NATIVE/common/KHR -I$NATIVE/common/CL \
-I$ROOT/libs/meowcraftlib/src/main/cpp/meowcraftbridge"

LIBS="-lm -lpthread"
LF_COMMON="$TARGET_FLAGS -shared -fuse-ld=lld -z noexecstack -O2 -pthread -Wl,--no-undefined"
# Stage 2 needs no EGL/GLES/native_window DT_NEEDED: the EGL context, the swap and the gl4es
# initialisation all live in libmeowcraftbridge.so and are reached via dlsym(RTLD_DEFAULT) —
# we only pass the OHNativeWindow through as an opaque pointer.

# ---- helpers ----------------------------------------------------------------
count_exports() { "$NM" -D --defined-only "$1" 2>/dev/null | grep -cE "$2" || true; }
require_sym() {
  "$NM" -D --defined-only "$1" 2>/dev/null | grep -qE "[[:space:]]$2\$" || {
    echo "error: $1 is missing expected export $2" >&2; exit 1; }
}

# ---- build ------------------------------------------------------------------
# Never delete something we do not own (guard --build before rm -rf).
if [ -z "$BUILD" ]; then
  # Scratch belongs under stuffs/, never inside ref/ (ref/ holds source clones only).
  BUILD="$WS/stuffs/lwjgl2/build"
fi
case "$BUILD" in
  "/"|""|"$SRC"|"$SRC"/*) echo "error: refusing --build '$BUILD'" >&2; exit 2 ;;
esac
rm -rf "$BUILD"; mkdir -p "$BUILD/obj" "$BUILD/out"; mkdir -p "$OUT"

# Fail early and clearly when generate_sources.sh has not been run (or ran partially).
for d in "$NATIVE/generated/opengl" "$NATIVE/generated/openal"; do
  set -- "$d"/*.c
  [ -f "$1" ] || { echo "error: no generated sources under $d - run tools/lwjgl2/generate_sources.sh first" >&2; exit 2; };
done

echo "=== compile ($ARCH, stage $([ "$WITH_DISPLAY" -eq 1 ] && echo 2 || echo 1)) ==="
objs=""
for f in $SRCS; do
  o="$BUILD/obj/$(echo "$f" | sed 's#[/.]#_#g').o"
  "$CC" $CF_COMMON -c "$f" -o "$o"
  objs="$objs $o"
done
echo "  compiled $(echo "$objs" | wc -w) translation units"

echo "=== link ==="
OUTFILE="$BUILD/out/liblwjgl.so"
"$CC" $LF_COMMON -o "$OUTFILE" $objs $LIBS

# ---- finalize ---------------------------------------------------------------
so="$OUTFILE"
[ -f "$so" ] || { echo "error: liblwjgl.so not produced" >&2; exit 1; }
if [ -x "$OBJCOPY" ]; then
  "$OBJCOPY" --strip-unneeded "$so"
  "$OBJCOPY" --remove-section=.permission --remove-section=.codesign \
             --remove-section=.comment "$so" 2>/dev/null || true
else
  echo "warn: llvm-objcopy not found; shipping an unstripped lib" >&2
fi

echo "=== assertions ==="
require_sym "$so" Java_org_lwjgl_DefaultSysImplementation_getJNIVersion
require_sym "$so" Java_org_lwjgl_DefaultSysImplementation_getPointerSize
require_sym "$so" Java_org_lwjgl_DefaultSysImplementation_setDebug
require_sym "$so" Java_org_lwjgl_BufferUtils_getBufferAddress
require_sym "$so" Java_org_lwjgl_BufferUtils_zeroBuffer0
require_sym "$so" Java_org_lwjgl_opengl_GLContext_ngetFunctionAddress
require_sym "$so" Java_org_lwjgl_opengl_GLContext_nLoadOpenGLLibrary
require_sym "$so" Java_org_lwjgl_opengl_GL11_nglAccum
require_sym "$so" Java_org_lwjgl_opengl_GL20_nglVertexAttribPointer
require_sym "$so" Java_org_lwjgl_openal_AL10_initNativeStubs
require_sym "$so" Java_org_lwjgl_openal_AL_resetNativeStubs
if [ "$WITH_DISPLAY" -eq 1 ]; then
  require_sym "$so" Java_org_lwjgl_opengl_LinuxDisplay_nCreateWindow
  require_sym "$so" Java_org_lwjgl_opengl_LinuxDisplay_nSetTitle
  require_sym "$so" Java_org_lwjgl_opengl_LinuxDisplay_nInternAtom
  require_sym "$so" Java_org_lwjgl_opengl_LinuxDisplay_nGetAvailableDisplayModes
  require_sym "$so" Java_org_lwjgl_opengl_LinuxDisplay_openDisplay
  require_sym "$so" Java_org_lwjgl_opengl_LinuxKeyboard_nSetDetectableKeyRepeat
  require_sym "$so" Java_org_lwjgl_opengl_LinuxKeyboard_lookupKeysym
  require_sym "$so" Java_org_lwjgl_opengl_LinuxMouse_nGetButtonCount
  require_sym "$so" Java_org_lwjgl_opengl_LinuxMouse_nQueryPointer
  require_sym "$so" Java_org_lwjgl_opengl_LinuxEvent_nNextEvent
  require_sym "$so" Java_org_lwjgl_opengl_LinuxEvent_getPending
  require_sym "$so" Java_org_lwjgl_opengl_LinuxPeerInfo_createHandle
  require_sym "$so" Java_org_lwjgl_opengl_LinuxContextImplementation_nCreate
  require_sym "$so" Java_org_lwjgl_opengl_LinuxContextImplementation_nMakeCurrent
  require_sym "$so" Java_org_lwjgl_opengl_LinuxContextImplementation_nSwapBuffers
fi

n_gl=$(count_exports "$so" 'Java_org_lwjgl_opengl_')
n_al=$(count_exports "$so" 'Java_org_lwjgl_openal_')
n_core=$(count_exports "$so" 'Java_org_lwjgl_')
echo "  exports: total=$n_core opengl=$n_gl openal=$n_al"
[ "$n_gl" -ge 2000 ] || { echo "error: OpenGL export collapse (only $n_gl)" >&2; exit 1; }
# 20 == the complete upstream OpenAL surface for this source set (AL/ALC10/ALC11/EFX10).
[ "$n_al" -ge 20 ]   || { echo "error: OpenAL export collapse (only $n_al)" >&2; exit 1; }

if [ -x "$READOBJ" ]; then
  # No X11/GLX/jawt may have crept into DT_NEEDED (the whole point of the port).
  for bad in X11 Xext Xcursor Xrandr Xxf86vm jawt; do
    if "$READOBJ" --dynamic-table "$so" 2>/dev/null | grep -q "lib$bad\.so"; then
      echo "error: unexpected DT_NEEDED lib$bad.so" >&2; exit 1; fi
  done
  "$READOBJ" --sections "$so" 2>/dev/null | grep -q 'Name: \.note\.ohos' || {
    echo "error: missing .note.ohos.ident (not an OHOS clang build?)" >&2; exit 1; }
  echo "  NEEDED: $("$READOBJ" --dynamic-table "$so" | grep NEEDED | sed 's/.*\[//;s/\].*//' | tr '\n' ' ')"
else
  echo "warn: llvm-readobj not found; skipped DT_NEEDED/.note.ohos assertions" >&2
fi

cp "$so" "$OUT/liblwjgl.so"
new_sha=$(sha256sum "$OUT/liblwjgl.so" | cut -d' ' -f1)
echo "  liblwjgl: exports=$n_core size=$(wc -c < "$OUT/liblwjgl.so") sha256=$new_sha"

if [ -n "$COMPARE" ] && [ -f "$COMPARE/liblwjgl.so" ]; then
  old_n=$(count_exports "$COMPARE/liblwjgl.so" 'Java_org_lwjgl_')
  echo "  liblwjgl: shipped=$COMPARE/liblwjgl.so exports=$old_n"
fi

echo "OK -> $OUT/liblwjgl.so"
