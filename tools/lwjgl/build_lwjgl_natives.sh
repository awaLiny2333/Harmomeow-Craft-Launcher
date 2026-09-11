#!/bin/sh
# Build Meowcraft's OHOS LWJGL natives from source: liblwjgl.so (core),
# liblwjgl_opengl.so (opengl) and liblwjgl_stb.so (stb).
#
# This is the "natives" half of the lwjgl self-build (the jar half is
# build_lwjgl_jar.sh). Upstream has NO CMake for the natives: the official
# build is Ant + GCC (config/linux/build.xml). Ant is not installed here, so
# this script invokes the OHOS clang driver directly and replicates the
# essential flags from config/linux/build.xml:
#
#   compile: -std=gnu11 -O3 -fPIC -pthread -DNDEBUG -DLWJGL_LINUX
#            -DLWJGL_arm64 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
#            -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64
#   link:    -shared -z noexecstack -O3 -fPIC -pthread -Wl,--no-undefined
#            -Wl,--version-script,<src>/config/linux/version.script
#            (core: + libffi.a -ldl ; stb: + -lm ; opengl: no extra libs)
#
# We deliberately do NOT add -fvisibility=hidden: LWJGL retargets the export
# surface with an explicit linker version script (tag LWJGL), and jni.h marks
# every entry point JNIEXPORT (visibility default). The historical OHOS
# "zero exports" bug (OpenAL, tools/openal) came from a CMake visibility probe
# that LWJGL does not use; the post-link export assertions below are the gate
# against a silent collapse anyway.
#
# libffi: LWJGL core links a target libffi.a (org_lwjgl_system_Callback.c +
# the generated org_lwjgl_system_libffi_* bindings). ref/lwjgl3 vendors libffi
# *headers only*, so a real libffi is needed. This script can build one from a
# full libffi source tree (--libffi-src) for aarch64-linux-ohos, or use a
# prebuilt one (--libffi-a; e.g. the OHOS HNP libffi 3.4.4). The build is a
# direct clang compile of the 8 translation units libffi needs on aarch64
# (no autotools: the JNA-bundled tree ships configure.ac but no configure, and
# this sandbox has no automake/libtoolize).
#
# Standalone: every path is passed in, nothing is derived from the caller layout.
#
# Usage:
#   sh build_lwjgl_natives.sh --src DIR --sdk-native DIR --out DIR \
#       [--build DIR] [--api N] [--arch NAME] \
#       [--jni-inc DIR] [--libffi-src DIR | --libffi-a FILE] \
#       [--compare DIR]
#
# Required:
#   --src DIR         lwjgl3 source tree, checked out at the target tag (3.3.3)
#   --sdk-native DIR  OHOS SDK native dir (build/cmake/ohos.toolchain.cmake + sysroot)
#   --out DIR         output dir; receives liblwjgl{,_opengl,_stb}.so
#
# Optional:
#   --build DIR       out-of-tree build dir (default: <src>/../build-lwjgl-meow)
#   --api N           OHOS platform level (default: 23)
#   --arch NAME       OHOS arch (default: arm64-v8a; only arm64-v8a supported
#                     for the from-source libffi path)
#   --jni-inc DIR     dir with jni.h/jni_md.h (default: repo meowcraftbridge headers)
#   --libffi-src DIR  full libffi source tree (configure.ac + src/) to build from
#   --libffi-a FILE   prebuilt libffi.a for the target instead of building one
#   --compare DIR     shipped-native reference dir (default: meowlwjgl3 libs/<arch>)
#   -h, --help        show this help
#
# Emits stripped .so with the OHOS .permission/.codesign/.comment metadata
# sections removed to match the shipped binary shape, asserts the export
# surface + DT_NEEDED + .note.ohos, then prints size/sha256 and compares
# against the shipped counterpart (symbol parity, not byte identity).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # Meowcraft/ (app project)
OUTER="$(cd "$ROOT/.." && pwd)"            # workspace root (holds ref/ + stuffs/)

usage() { sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'; }

SRC=""; SDK_NATIVE=""; OUT=""; BUILD=""; API=23; ARCH=arm64-v8a
JNIINC=""; LIBFFI_SRC=""; LIBFFI_A=""; COMPARE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)        SRC="$2";        shift 2 ;;
    --sdk-native) SDK_NATIVE="$2"; shift 2 ;;
    --out)        OUT="$2";        shift 2 ;;
    --build)      BUILD="$2";      shift 2 ;;
    --api)        API="$2";        shift 2 ;;
    --arch)       ARCH="$2";       shift 2 ;;
    --jni-inc)    JNIINC="$2";     shift 2 ;;
    --libffi-src) LIBFFI_SRC="$2"; shift 2 ;;
    --libffi-a)   LIBFFI_A="$2";   shift 2 ;;
    --compare)    COMPARE="$2";    shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ]        || { echo "error: --src is required" >&2; usage >&2; exit 2; }
[ -n "$SDK_NATIVE" ] || { echo "error: --sdk-native is required" >&2; usage >&2; exit 2; }
[ -n "$OUT" ]        || { echo "error: --out is required" >&2; usage >&2; exit 2; }

# ---- arch -> OHOS target triple + LWJGL arch macro --------------------------
case "$ARCH" in
  arm64-v8a)   TRIPLE="aarch64-linux-ohos"; LARCH="arm64" ;;
  armeabi-v7a) TRIPLE="arm-linux-ohos";     LARCH="arm"   ;;
  x86_64)      TRIPLE="x86_64-linux-ohos";  LARCH="x64"   ;;
  *) echo "error: unsupported --arch '$ARCH' (use arm64-v8a/armeabi-v7a/x86_64)" >&2; exit 2 ;;
esac

# ---- toolchain --------------------------------------------------------------
SYSROOT="$SDK_NATIVE/sysroot"
STRIP="$SDK_NATIVE/llvm/bin/llvm-strip"
OBJCOPY="$SDK_NATIVE/llvm/bin/llvm-objcopy"
NM="$SDK_NATIVE/llvm/bin/llvm-nm"
READELF="$SDK_NATIVE/llvm/bin/llvm-readelf"
AR="$SDK_NATIVE/llvm/bin/llvm-ar"

[ -d "$SDK_NATIVE" ]        || { echo "error: OHOS SDK native dir not found: $SDK_NATIVE" >&2; exit 2; }
[ -d "$SYSROOT" ]           || { echo "error: SDK sysroot not found: $SYSROOT" >&2; exit 2; }
[ -x "$NM" ]                || { echo "error: llvm-nm not found: $NM" >&2; exit 2; }
[ -f "$SRC/config/linux/version.script" ] || { echo "error: not a lwjgl3 tree: $SRC" >&2; exit 2; }

if [ -x "$SDK_NATIVE/llvm/bin/${TRIPLE}-clang" ]; then
  CC="$SDK_NATIVE/llvm/bin/${TRIPLE}-clang"     # wrapper already sets --target/--sysroot
else
  CC="$SDK_NATIVE/llvm/bin/clang"
  TARGET_FLAGS="--target=$TRIPLE --sysroot=$SYSROOT"
fi

# ---- JNI headers ------------------------------------------------------------
if [ -z "$JNIINC" ]; then
  for d in \
    "$ROOT/libs/meowcraftlib/src/main/cpp/meowcraftbridge" \
    "$OUTER/stuffs/research/jna/jna_poc/inc"; do
    if [ -f "$d/jni.h" ]; then JNIINC="$d"; break; fi
  done
fi
[ -n "$JNIINC" ] && [ -f "$JNIINC/jni.h" ] || {
  echo "error: jni.h not found; pass --jni-inc DIR (needs jni.h + jni_md.h)" >&2; exit 2; }

# ---- libffi resolution ------------------------------------------------------
# Precedence: explicit prebuilt > explicit source > auto source > auto HNP.
if [ -n "$LIBFFI_A" ]; then
  [ -f "$LIBFFI_A" ] || { echo "error: --libffi-a not found: $LIBFFI_A" >&2; exit 2; }
  BUILD_LIBFFI=0
elif [ -z "$LIBFFI_SRC" ]; then
  for d in "$OUTER/stuffs/research/jna/jna_src/native/libffi"; do
    if [ -f "$d/configure.ac" ] && [ -d "$d/src/aarch64" ]; then LIBFFI_SRC="$d"; break; fi
  done
fi

if [ -z "$LIBFFI_A" ] && [ -z "$LIBFFI_SRC" ]; then
  HNP="/data/service/hnp/libffi.org/libffi_3.4.4"
  if [ -f "$HNP/lib/libffi.a" ]; then
    LIBFFI_A="$HNP/lib/libffi.a"; BUILD_LIBFFI=0
    echo "note: no --libffi-src; using prebuilt OHOS libffi: $LIBFFI_A"
  else
    echo "error: no libffi available; pass --libffi-src DIR or --libffi-a FILE" >&2; exit 2
  fi
fi

# ---- layout -----------------------------------------------------------------
[ -n "$BUILD" ] || BUILD="$(dirname "$SRC")/build-lwjgl-meow"
VSCRIPT="$SRC/config/linux/version.script"
CORE="$SRC/modules/lwjgl/core"
GL="$SRC/modules/lwjgl/opengl"
STB="$SRC/modules/lwjgl/stb"
[ -d "$CORE" ] && [ -d "$GL" ] && [ -d "$STB" ] || {
  echo "error: lwjgl module dirs missing under $SRC/modules/lwjgl" >&2; exit 2; }

# Shipped reference dir (auto only when --compare is omitted).
[ -n "$COMPARE" ] || COMPARE="$ROOT/libs/meowlwjgl3/libs/$ARCH"

rm -rf "$BUILD"
mkdir -p "$BUILD/obj-core" "$BUILD/obj-opengl" "$BUILD/obj-stb" "$BUILD/out"
mkdir -p "$OUT"

# ---- flags ------------------------------------------------------------------
# The ${TRIPLE}-clang wrapper defines __MUSL__/__OHOS__ already; keep -D__MUSL__
# explicit per the OHOS recipe (an identical redefinition is harmless).
CF_COMMON="$TARGET_FLAGS -D__MUSL__ -O3 -fPIC -std=gnu11 -pthread -DNDEBUG \
-DLWJGL_LINUX -DLWJGL_${LARCH} -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
-D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I$JNIINC -I$CORE/src/main/c -I$CORE/src/main/c/linux"
LF_COMMON="$TARGET_FLAGS -shared -fuse-ld=lld -z noexecstack -O3 -fPIC -pthread \
-Wl,--no-undefined -Wl,--version-script,$VSCRIPT"

# ---- helpers ----------------------------------------------------------------
count_exports() { "$NM" -D --defined-only "$1" 2>/dev/null | grep -cE "$2" || true; }

finalize() {
  # $1 = build output .so, $2 = bare name (liblwjgl...), $3 = export regex, $4 = min
  so="$1"; name="$2"; pat="$3"; min="$4"
  [ -f "$so" ] || { echo "error: $name not produced" >&2; exit 1; }

  [ -x "$STRIP" ]   && "$STRIP" --strip-unneeded "$so"
  if [ -x "$OBJCOPY" ]; then
    "$OBJCOPY" --remove-section=.permission --remove-section=.codesign \
               --remove-section=.comment "$so" 2>/dev/null || true
  fi

  n=$(count_exports "$so" "$pat")
  [ "$n" -ge "$min" ] || {
    echo "error: $name export collapse: only $n match /$pat/ (need >= $min)" >&2; exit 1; }

  # DT_NEEDED must be libc.so only (musl folds libm/libdl/libpthread in).
  if [ -x "$READELF" ]; then
    badneeded=$("$READELF" -d "$so" 2>/dev/null | grep NEEDED | grep -vc 'libc\.so' || true)
    [ "$badneeded" -eq 0 ] || {
      echo "error: $name has unexpected DT_NEEDED (want only libc.so):" >&2
      "$READELF" -d "$so" | grep NEEDED >&2; exit 1; }
    "$READELF" -SW "$so" 2>/dev/null | grep -q 'note\.ohos' || {
      echo "error: $name missing .note.ohos.ident (not an OHOS clang build?)" >&2; exit 1; }
  fi

  # Capture the shipped counterpart BEFORE copying (out may equal ref).
  old_sha=""; old_size=""; old_n=""
  if [ -f "$COMPARE/$name.so" ]; then
    old_sha=$(sha256sum "$COMPARE/$name.so" | cut -d' ' -f1)
    old_size=$(wc -c < "$COMPARE/$name.so")
    old_n=$(count_exports "$COMPARE/$name.so" "$pat")
  fi

  cp "$so" "$OUT/$name.so"
  new_sha=$(sha256sum "$OUT/$name.so" | cut -d' ' -f1)
  new_size=$(wc -c < "$OUT/$name.so")

  echo "  $name: exports=$n  size=$new_size  NEEDED=libc.so  .note.ohos=yes"
  echo "  $name: sha256=$new_sha"
  if [ -n "$old_sha" ]; then
    echo "  $name: shipped=$old_sha ($old_size B, exports=$old_n)"
    echo "  $name: parity=$([ "$n" = "$old_n" ] && echo 'EXPORT-MATCH' || echo "DIFF new=$n old=$old_n")"
  fi
}

# ---- build libffi (core only) ----------------------------------------------
if [ -z "$LIBFFI_A" ]; then
  case "$ARCH" in arm64-v8a) ;; *) echo "error: from-source libffi only supports arm64-v8a" >&2; exit 2 ;; esac
  echo "=== libffi ($ARCH) from $LIBFFI_SRC ==="
  [ -d "$LIBFFI_SRC/src/aarch64" ] || { echo "error: not a libffi tree: $LIBFFI_SRC" >&2; exit 2; }
  LF_DIR="$BUILD/libffi"; mkdir -p "$LF_DIR/inc" "$LF_DIR/obj"
  # Generate ffi.h + fficonfig.h (normally done by configure; we have no autotools here).
  sed -e 's/@VERSION@/3.4.4/g' -e 's/@TARGET@/AARCH64/g' \
      -e 's/@HAVE_LONG_DOUBLE@/1/g' -e 's/@FFI_EXEC_TRAMPOLINE_TABLE@/0/g' \
      "$LIBFFI_SRC/include/ffi.h.in" > "$LF_DIR/inc/ffi.h"
  cat > "$LF_DIR/inc/fficonfig.h" <<'FFICONFIG'
#define STDC_HEADERS 1
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_MEMCPY 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMSET 1
#define HAVE_MMAP 1
#define HAVE_MMAP_ANON 1
#define HAVE_MMAP_FILE 1
#define HAVE_GETPAGESIZE 1
#define HAVE_MKOSTEMP 1
#define HAVE_MEMFD_CREATE 1
#define HAVE_MNTENT 1
#define HAVE_SYS_MMAN_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRING_H 1
#define HAVE_STDLIB_H 1
#define HAVE_DLFCN_H 1
#define HAVE_HIDDEN_VISIBILITY_ATTRIBUTE 1
#define HAVE_LONG_DOUBLE 1
#define FFI_EXEC_STATIC_TRAMP 1
#define FFI_EXEC_TRAMPOLINE_TABLE 0
#define FFI_TMPDIR "/tmp"
#ifdef LIBFFI_ASM
#define FFI_HIDDEN(name) .hidden name
#else
#define FFI_HIDDEN __attribute__ ((visibility ("hidden")))
#endif
FFICONFIG
  LCF="$TARGET_FLAGS -D__MUSL__ -O2 -fPIC -I$LF_DIR/inc -I$LIBFFI_SRC/include -I$LIBFFI_SRC/src -I$LIBFFI_SRC/src/aarch64"
  for f in prep_cif types raw_api java_raw_api closures tramp; do
    "$CC" $LCF -c "$LIBFFI_SRC/src/$f.c" -o "$LF_DIR/obj/$f.o"
  done
  "$CC" $LCF -c "$LIBFFI_SRC/src/aarch64/ffi.c" -o "$LF_DIR/obj/ffi.o"
  "$CC" $LCF -c "$LIBFFI_SRC/src/aarch64/sysv.S" -o "$LF_DIR/obj/sysv.o"
  "$AR" rcs "$LF_DIR/libffi.a" "$LF_DIR/obj/"*.o
  LIBFFI_A="$LF_DIR/libffi.a"
  echo "  built $LIBFFI_A ($(wc -c < "$LIBFFI_A") bytes)"
else
  echo "=== libffi (prebuilt) $LIBFFI_A ==="
fi

# ---- 1. opengl (generated C only; no GL backend linked) ---------------------
echo "=== opengl ==="
( cd "$BUILD/obj-opengl"
  GCF="$CF_COMMON -I$GL/src/main/c"
  for f in "$GL"/src/generated/c/*.c; do
    case "$f" in *WGL*) continue ;; esac
    "$CC" $GCF -c "$f" -o "$(basename "$f" .c).o"
  done
  "$CC" $LF_COMMON -o "$BUILD/out/liblwjgl_opengl.so" *.o )
finalize "$BUILD/out/liblwjgl_opengl.so" liblwjgl_opengl 'Java_org_lwjgl_opengl_' 2200

# ---- 2. stb (vendored header-only impl + generated JNI) ---------------------
echo "=== stb ==="
( cd "$BUILD/obj-stb"
  SCF="$CF_COMMON -isystem $STB/src/main/c"
  for f in "$STB"/src/generated/c/*.c; do
    "$CC" $SCF -c "$f" -o "$(basename "$f" .c).o"
  done
  "$CC" $LF_COMMON -o "$BUILD/out/liblwjgl_stb.so" *.o -lm )
finalize "$BUILD/out/liblwjgl_stb.so" liblwjgl_stb 'Java_org_lwjgl_stb_' 200

# ---- 3. core (JNI trampolines, MemoryUtil, callbacks/libffi, linux, uring) ---
echo "=== core ==="
( cd "$BUILD/obj-core"
  CCF="$CF_COMMON -I$CORE/src/main/c/libffi -I$CORE/src/main/c/libffi/aarch64 \
       -I$CORE/src/main/c/linux/liburing -I$CORE/src/main/c/linux/liburing/include"
  for f in "$CORE"/src/main/c/*.c "$CORE"/src/generated/c/*.c "$CORE"/src/generated/c/linux/*.c; do
    "$CC" $CCF -c "$f" -o "$(basename "$f" .c).o"
  done
  for f in "$CORE"/src/main/c/linux/liburing/*.c; do
    "$CC" $CCF -DCONFIG_HAVE_MEMFD_CREATE -c "$f" -o "liburing_$(basename "$f" .c).o"
  done
  "$CC" $LF_COMMON -o "$BUILD/out/liblwjgl.so" *.o "$LIBFFI_A" -ldl )
finalize "$BUILD/out/liblwjgl.so" liblwjgl 'Java_org_lwjgl_' 1900

# libffi must have contributed its 40+ entry points.
NFFI=$(count_exports "$OUT/liblwjgl.so" 'libffi_')
[ "$NFFI" -ge 40 ] || { echo "error: libffi not linked into core (only $NFFI libffi_ exports)" >&2; exit 1; }
echo "  liblwjgl: libffi_ exports=$NFFI"

# ---- 4. tinyfd (vendored tinyfiledialogs.c + generated JNI; generation-agnostic) --------------
# MC >= 1.22's NativeLibrariesBootstrap eagerly loads org.lwjgl.util.tinyfd ("tinyfd") at boot
# (fail-fast), so this native must ship. MeowBundledNameMapper passes "lwjgl_tinyfd" through
# unchanged -> the file keeps its plain name (no per-generation suffix).
echo "=== tinyfd ==="
TINYFD="$SRC/modules/lwjgl/tinyfd"
[ -d "$TINYFD" ] || { echo "error: tinyfd module dir missing: $TINYFD" >&2; exit 2; }
mkdir -p "$BUILD/obj-tinyfd"
( cd "$BUILD/obj-tinyfd"
  TCF="$CF_COMMON -I$TINYFD/src/main/c -I$CORE/src/main/c -I$CORE/src/main/c/linux"
  "$CC" $TCF -c "$TINYFD/src/main/c/tinyfiledialogs.c" -o tinyfiledialogs.o
  "$CC" $TCF -c "$TINYFD/src/generated/c/org_lwjgl_util_tinyfd_TinyFileDialogs.c" -o jni.o
  "$CC" $LF_COMMON -o "$BUILD/out/liblwjgl_tinyfd.so" *.o )
finalize "$BUILD/out/liblwjgl_tinyfd.so" liblwjgl_tinyfd 'org_lwjgl_|tinyfd' 5

echo "OK -> $OUT/{liblwjgl,liblwjgl_opengl,liblwjgl_stb,liblwjgl_tinyfd}.so"
