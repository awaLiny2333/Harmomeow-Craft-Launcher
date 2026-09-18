#!/bin/sh
# F2 fix: LWJGL core's memAlignedAlloc fallback breaks on OHOS/musl for small alignments.
#
# ROOT CAUSE (measured, see stuffs/research/vulkan/fixes/F2-lwjgl-aligned-alloc-musl.md):
#   * The generator emits (modules/lwjgl/core/src/generated/c/org_lwjgl_system_MemoryAccessJNI.c):
#         #else
#             static void* __aligned_alloc(size_t alignment, size_t size) {
#                 void *p;
#                 return posix_memalign(&p, alignment, size) ? NULL : p;
#             }
#         #endif
#     because `__USE_ISOC11` is a glibc feature macro and is never defined by the OHOS clang.
#   * musl's posix_memalign() returns EINVAL for alignment < sizeof(void*):
#         cmp x1, #8 ; b.hs ok ; mov w0, #22 (EINVAL)  [SDK libc.a posix_memalign.o, disasm]
#   * VMA calls org_lwjgl_aligned_alloc == this __aligned_alloc with alignof(RegionInfo)==2
#     for the 32 MiB block page table (8192 * 4 == 0x8000 bytes). The call returns NULL; with
#     -DNDEBUG VMA's "CPU memory allocation failed" assert is compiled out and the following
#     memset(NULL, 0, 0x8000) faults (SIGSEGV/SEGV_MAPERR in musl memset, x0=x1=0, x2=0x8000).
#
# FIX: clamp the alignment to >= sizeof(void*) before calling posix_memalign. It is applied to a
#      throwaway copy of ref/lwjgl3@3.4.3 (ref/ is never modified). The generator template is
#      patched too so a future regeneration keeps the fix.
#
# This script builds core ONLY (liblwjgl.so -> installed as liblwjgl_343.so). The crash path lives
# in core: LibVma's static initializer calls setupMalloc(..., MemoryUtil.getAllocator().getAlignedAlloc())
# and the pointer it installs is core's __aligned_alloc (Java_org_lwjgl_system_MemoryAccessJNI_aligned_alloc
# returns &__aligned_alloc). liblwjgl_vma.so itself only holds the (BSS) function pointer.
#
# Usage:  sh build_lwjgl_core_aligned_alloc_fix.sh [--install] [--libffi-a FILE]
#         (no --install: build + assert only, output in $WORK/out)
#
# Assertions: exports unchanged (dynsym set vs the shipped liblwjgl_343.so), DT_NEEDED == libc.so only,
# .note.ohos present, libffi_ exports >= 40. With --install: backs the old file up first and updates
# natives.manifest.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"            # Harmomeow-Craft-Launcher
WS="$(cd "$PROJ/.." && pwd)"                 # workspace (ref/, stuffs/)
REF="$WS/ref/lwjgl3"
TAG=3.4.3
WORK="$WS/stuffs/research/lwjgl_f2_align"
SRC="$WORK/src"
OBJ="$WORK/obj"
OUT="$WORK/out"
SHIPPED="$PROJ/libs/meowlwjgls/libs/arm64-v8a"
MANIFEST="$PROJ/libs/meowlwjgls/libs/natives.manifest"

SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
SYSROOT="$SDK/sysroot"
CC="$SDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
NM="$SDK/llvm/bin/llvm-nm"
READELF="$SDK/llvm/bin/llvm-readelf"
STRIP="$SDK/llvm/bin/llvm-strip"
OBJCOPY="$SDK/llvm/bin/llvm-objcopy"

JNIINC="${JNIINC:-$PROJ/libs/meowcraftlib/src/main/cpp/meowcraftbridge}"
LIBFFI_A="${LIBFFI_A:-$WS/stuffs/research/libffi/out-ohos/libffi.a}"

DO_INSTALL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install)   DO_INSTALL=1; shift ;;
    --libffi-a)  LIBFFI_A="$2"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---- sanity ----------------------------------------------------------------
[ -d "$REF/.git" ] || { echo "error: not a git clone: $REF" >&2; exit 2; }
git -C "$REF" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "error: tag $TAG missing in $REF" >&2; exit 2; }
[ -f "$JNIINC/jni.h" ] || { echo "error: jni.h not found: $JNIINC" >&2; exit 2; }
[ -f "$LIBFFI_A" ]     || { echo "error: libffi.a not found: $LIBFFI_A" >&2; exit 2; }
[ -f "$SHIPPED/liblwjgl_343.so" ] || { echo "error: shipped core not found" >&2; exit 2; }

VSCRIPT="$REF/config/linux/version.script"

# ---- 1. extract pristine source -------------------------------------------
rm -rf "$SRC" "$OBJ" "$OUT"
mkdir -p "$SRC" "$OBJ" "$OUT"
( cd "$REF" && git archive "$TAG" ) | tar -x -C "$SRC"
echo "== extracted $REF@$TAG -> $SRC"

CORE="$SRC/modules/lwjgl/core"

# ---- 2. apply the fix to the COPY -----------------------------------------
echo "== patching core __aligned_alloc (clamp alignment >= sizeof(void*)) =="
python3 - "$CORE" <<'PY'
import sys
core = sys.argv[1]
gen = core + "/src/generated/c/org_lwjgl_system_MemoryAccessJNI.c"
kt  = core + "/src/templates/kotlin/core/templates/MemoryAccessJNI.kt"

gen_old = """    #else
        static void* __aligned_alloc(size_t alignment, size_t size) {
            void *p;
            return posix_memalign(&p, alignment, size) ? NULL : p;
        }
    #endif"""
gen_new = """    #else
        static void* __aligned_alloc(size_t alignment, size_t size) {
            // MEOWCRAFT F2 FIX (musl): posix_memalign returns EINVAL (NULL) for alignment
            // < sizeof(void*). VMA legitimately asks for alignof(RegionInfo) == 2 when it
            // builds the 32 MiB block's page table (8192 * 4 == 0x8000 bytes). Clamp to the
            // platform pointer size so the allocation succeeds; an alignment already above
            // sizeof(void*) is left untouched.
            if (alignment < sizeof(void *)) {
                alignment = sizeof(void *);
            }
            void *p;
            return posix_memalign(&p, alignment, size) ? NULL : p;
        }
    #endif"""
g = open(gen, encoding='utf-8').read()
assert gen_old in g, "generated C anchor not found"
open(gen, 'w', encoding='utf-8').write(g.replace(gen_old, gen_new, 1))

kt_old = """        static void* __aligned_alloc(size_t alignment, size_t size) {
            void *p;
            return posix_memalign(&p, alignment, size) ? NULL : p;
        }"""
kt_new = """        static void* __aligned_alloc(size_t alignment, size_t size) {
            // MEOWCRAFT F2 FIX (musl): posix_memalign rejects alignment < sizeof(void*)
            // with EINVAL. See the generated C for the full rationale.
            if (alignment < sizeof(void *)) {
                alignment = sizeof(void *);
            }
            void *p;
            return posix_memalign(&p, alignment, size) ? NULL : p;
        }"""
k = open(kt, encoding='utf-8').read()
assert kt_old in k, "generator template anchor not found"
open(kt, 'w', encoding='utf-8').write(k.replace(kt_old, kt_new, 1))
print("   patched: generated C + generator template")
PY

# ---- 3. compile + link core (mirrors build_lwjgl_natives.sh core section) --
CF_COMMON="-D__MUSL__ -O3 -fPIC -std=gnu11 -pthread -DNDEBUG \
-DLWJGL_LINUX -DLWJGL_arm64 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
-D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I$JNIINC -I$CORE/src/main/c -I$CORE/src/main/c/linux"
CCF="$CF_COMMON -I$CORE/src/main/c/libffi -I$CORE/src/main/c/libffi/aarch64 \
     -I$CORE/src/main/c/linux/liburing -I$CORE/src/main/c/linux/liburing/include"
LF_COMMON="-shared -fuse-ld=lld -z noexecstack -O3 -fPIC -pthread \
-Wl,--no-undefined -Wl,--version-script,$VSCRIPT"

echo "== compiling core =="
for f in "$CORE"/src/main/c/*.c "$CORE"/src/generated/c/*.c "$CORE"/src/generated/c/linux/*.c; do
  "$CC" $CCF -c "$f" -o "$OBJ/$(basename "$f" .c).o"
done
for f in "$CORE"/src/main/c/linux/liburing/*.c; do
  "$CC" $CCF -DCONFIG_HAVE_MEMFD_CREATE -c "$f" -o "$OBJ/liburing_$(basename "$f" .c).o"
done

echo "== linking liblwjgl.so =="
"$CC" $LF_COMMON -o "$OUT/liblwjgl.so" "$OBJ"/*.o "$LIBFFI_A" -ldl

[ -x "$STRIP" ]   && "$STRIP" --strip-unneeded "$OUT/liblwjgl.so"
if [ -x "$OBJCOPY" ]; then
  "$OBJCOPY" --remove-section=.permission --remove-section=.codesign \
             --remove-section=.comment "$OUT/liblwjgl.so" 2>/dev/null || true
fi

# ---- 4. assertions ---------------------------------------------------------
echo "== assertions =="
N=$("$NM" -D --defined-only "$OUT/liblwjgl.so" | grep -cE 'Java_org_lwjgl_' || true)
[ "$N" -ge 1900 ] || { echo "error: export collapse: $N" >&2; exit 1; }
NFFI=$("$NM" -D --defined-only "$OUT/liblwjgl.so" | grep -c 'libffi_' || true)
[ "$NFFI" -ge 40 ] || { echo "error: libffi not linked ($NFFI)" >&2; exit 1; }
BAD=$("$READELF" -d "$OUT/liblwjgl.so" | grep NEEDED | grep -vc 'libc\.so' || true)
[ "$BAD" -eq 0 ] || { echo "error: unexpected DT_NEEDED" >&2; "$READELF" -d "$OUT/liblwjgl.so" | grep NEEDED >&2; exit 1; }
"$READELF" -SW "$OUT/liblwjgl.so" | grep -q 'note\.ohos' || { echo "error: no .note.ohos" >&2; exit 1; }

# posix_memalign stays imported (the wrapper now clamps before calling it).
PM=$("$NM" -D --undefined-only "$OUT/liblwjgl.so" | grep -c posix_memalign || true)
echo "   posix_memalign imports: $PM (expected 1; caller clamps)"

# Export SET must be identical to the shipped core (normalise the @@LWJGL suffix).
norm() { "$1" -D --defined-only "$2" | awk '{print $NF}' | sed 's/@@.*//' | sort -u; }
norm "$NM" "$SHIPPED/liblwjgl_343.so" > "$WORK/sym-before.txt"
norm "$NM" "$OUT/liblwjgl.so"         > "$WORK/sym-after.txt"
if diff -q "$WORK/sym-before.txt" "$WORK/sym-after.txt" >/dev/null; then
  echo "   exports: $(wc -l < "$WORK/sym-after.txt") symbols, SET IDENTICAL to shipped"
else
  echo "error: export set changed:" >&2; diff "$WORK/sym-before.txt" "$WORK/sym-after.txt" | head >&2; exit 1
fi

NEW_SHA=$(sha256sum "$OUT/liblwjgl.so" | cut -d' ' -f1)
echo "   size   : $(wc -c < "$OUT/liblwjgl.so") bytes"
echo "   sha256 : $NEW_SHA"
echo "   NEEDED : $(  "$READELF" -d "$OUT/liblwjgl.so" | grep NEEDED | sed 's/.*\[//;s/\]//' | tr '\n' ' ')"

# ---- 5. install (opt-in) ---------------------------------------------------
if [ "$DO_INSTALL" -eq 1 ]; then
  DST="$SHIPPED/liblwjgl_343.so"
  # Back up OUTSIDE the packaged libs dir (hvigor packages libs/<abi>/*.so) and prove the swap.
  BAK="$WS/stuffs/research/vulkan/fixes/liblwjgl_343.so.pre-f2"
  [ -f "$BAK" ] || cp -p "$DST" "$BAK"
  if cmp -s "$BAK" "$OUT/liblwjgl.so"; then
    echo "error: new core is byte-identical to the pre-fix one; fix not applied" >&2; exit 1
  fi
  cp "$OUT/liblwjgl.so" "$DST"
  echo "   installed -> $DST"
  echo "   backup    : $BAK ($(sha256sum "$BAK" | cut -d' ' -f1))"
  echo "   new sha   : $(sha256sum "$DST" | cut -d' ' -f1)"
  grep -v "$(printf '^%s\tliblwjgl_343.so\t' "$TAG")" "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
  printf '%s\tliblwjgl_343.so\t%s\n' "$TAG" "$(sha256sum "$DST" | cut -d' ' -f1)" >> "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  echo "   manifest updated ($TAG liblwjgl_343.so)"
fi

echo "OK -> $OUT/liblwjgl.so"
