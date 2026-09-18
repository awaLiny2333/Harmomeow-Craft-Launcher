#!/bin/sh
# liblwjgl_vma.so (OHOS aarch64) — parameterized recipe, two modes.
#
#   sh build_lwjgl_vma.sh [--release|--diagnostic] [--install] [--work DIR]
#
#   MODE=release    (DEFAULT) — the PRISTINE VMA module, no source patch. This is what is SHIPPED
#                              (main repo libs/meowlwjgls/libs/arm64-v8a/liblwjgl_vma.so,
#                              manifest tag `common`, sha256 479a619f99d0f74023a4361c3863976b21ca3dad4c0cac304b0b76cbe7335002).
#                              VMA only needs the app-provided Vulkan function pointers, so a clean
#                              upstream build is correct and is the runtime default.
#   MODE=diagnostic           — the SAME module with the investigative patches kept in
#                              stuffs/research/vulkan/build_vma_patched.sh: (a) narrow the KHR
#                              function-table assert to m_UseExtMemoryBudget, (b) dump apiVersion +
#                              every NULL table entry ([vma] NULL entry: …), (c) a memset(NULL,…)
#                              watcher ([vma] memset NULL dst …). NEVER ship this build; the shipped
#                              lib is release (the shipped file contains NO `[vma]` diagnostic string).
#
# WHY VMA IS BUILT AT ALL (measured, see stuffs/research/vulkan/build_vma_probe.sh header):
#   MC routes every Vulkan allocation through VMA (vmaCreateAllocator/Buffer/...); LibVma has no
#   override key, so a missing liblwjgl_vma.so is a hard "Failed to create VMA allocator". LWJGL
#   disables BOTH of VMA's own import paths, so the whole VmaVulkanFunctions table is filled from
#   Java — hence no Vulkan DT_NEEDED, and libc++ is linked statically (DT_NEEDED stays libc.so only).
#
# REPRODUCIBILITY: like the other natives, the linker records the absolute output path in the
#   binary, so a release build is byte-identical to the shipped file ONLY when built at the SAME
#   path. The canonical WORK below (stuffs/research/vulkan/vma_build) is exactly where the shipped
#   artifact was built; run with the defaults and it must cmp-equal the shipped file. Any other
#   --work produces the same function with a different hash.
#
# SELF-VERIFY (no install needed):
#   sh build_lwjgl_vma.sh && cmp stuffs/research/vulkan/vma_build/out/liblwjgl_vma.so \
#       ../../libs/meowlwjgls/libs/arm64-v8a/liblwjgl_vma.so && echo IDENTICAL
#   # diagnostic build must NOT be identical and must contain diagnostic strings:
#   sh build_lwjgl_vma.sh --diagnostic && strings stuffs/research/vulkan/vma_build_patched/out/liblwjgl_vma.so | grep '\[vma\]'
#
# Usage details: ref/ is only read (git archive is NOT even needed here — the pristine VMA module is
# compiled straight from ref/lwjgl3; the diagnostic copy is made under $WORK so ref/ stays clean).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"            # Harmomeow-Craft-Launcher
WS="$(cd "$PROJ/.." && pwd)"                 # workspace (ref/, stuffs/)
REF="$WS/ref/lwjgl3"
TAG=3.4.3
CANON_WORK="$WS/stuffs/research/vulkan/vma_build"
DIAG_WORK="$WS/stuffs/research/vulkan/vma_build_patched"
WORK=""
SHIPPED="$PROJ/libs/meowlwjgls/libs/arm64-v8a"
MANIFEST="$PROJ/libs/meowlwjgls/libs/natives.manifest"

SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
CC="$SDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
NM="$SDK/llvm/bin/llvm-nm"
READELF="$SDK/llvm/bin/llvm-readelf"
STRIP="$SDK/llvm/bin/llvm-strip"
LIBCXX_STATIC="$SDK/llvm/lib/aarch64-linux-ohos/c++/libc++_static.a"

JNIINC="${JNIINC:-$PROJ/libs/meowcraftlib/src/main/cpp/meowcraftbridge}"

MODE=release
DO_INSTALL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)    MODE=release; shift ;;
    --diagnostic) MODE=diagnostic; shift ;;
    --install)    DO_INSTALL=1; shift ;;
    --work)       WORK="$2"; shift 2 ;;
    -h|--help)    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$WORK" ] || { if [ "$MODE" = diagnostic ]; then WORK="$DIAG_WORK"; else WORK="$CANON_WORK"; fi; }
OUT="$WORK/out"
OBJ="$WORK/obj"
PATCHED="$WORK/src"
VSCRIPT="$REF/config/linux/version.script"
CORE="$REF/modules/lwjgl/core"
VMA="$REF/modules/lwjgl/vma"

# ---- sanity ----------------------------------------------------------------
[ -d "$CORE" ] && [ -d "$VMA" ] || { echo "error: lwjgl module dirs missing under $REF" >&2; exit 2; }
[ -f "$VMA/src/main/c/vk_mem_alloc.h" ] || { echo "error: vk_mem_alloc.h missing under $VMA" >&2; exit 2; }
[ -f "$JNIINC/jni.h" ] || { echo "error: jni.h not found: $JNIINC" >&2; exit 2; }
[ -f "$LIBCXX_STATIC" ] || { echo "error: libc++_static.a not found: $LIBCXX_STATIC" >&2; exit 2; }
[ -f "$SHIPPED/liblwjgl_vma.so" ] || { echo "error: shipped liblwjgl_vma.so not found" >&2; exit 2; }

if [ "$MODE" = diagnostic ] && [ "$DO_INSTALL" -eq 1 ]; then
  echo "error: refusing --install for a diagnostic build (the shipped lib must stay release)" >&2
  exit 2
fi

echo "== mode: $MODE =="
echo "== work: $WORK"

rm -rf "$OBJ" "$OUT"
mkdir -p "$OBJ" "$OUT"

if [ "$MODE" = diagnostic ]; then
  # ---- 1. patch a COPY of the vendored header (ref/ stays pristine) --------
  rm -rf "$PATCHED"; mkdir -p "$PATCHED"
  # trailing /.: copy the CONTENTS of vma/src into $PATCHED (not $PATCHED/src)
  cp -r "$VMA/src/." "$PATCHED/"
  echo "== patching diagnostic copy: $PATCHED/main/c/vk_mem_alloc.h =="
  python3 - "$PATCHED/main/c/vk_mem_alloc.h" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()

# (a) only require the 1.1 "2" queries when VMA will actually use them
old = """#if VMA_GET_PHYSICAL_DEVICE_PROPERTIES2
    if(m_UseExtMemoryBudget || m_VulkanApiVersion >= VK_MAKE_VERSION(1, 1, 0))
    {
        VMA_ASSERT(m_VulkanFunctions.vkGetPhysicalDeviceMemoryProperties2KHR != VMA_NULL);
        VMA_ASSERT(m_VulkanFunctions.vkGetPhysicalDeviceProperties2KHR != VMA_NULL);
    }
#endif"""
new = """#if VMA_GET_PHYSICAL_DEVICE_PROPERTIES2
    // MEOWCRAFT DIAG: only assert the "2" queries when VMA really uses them. LWJGL fills this table
    // from Java; on a 1.2-core device (no VK_KHR_get_physical_device_properties2) it legitimately
    // leaves the KHR-spelled entries NULL and the code falls back to the 1.0 entry.
    if(m_UseExtMemoryBudget)
    {
        VMA_ASSERT(m_VulkanFunctions.vkGetPhysicalDeviceMemoryProperties2KHR != VMA_NULL);
        VMA_ASSERT(m_VulkanFunctions.vkGetPhysicalDeviceProperties2KHR != VMA_NULL);
    }
#endif"""
assert old in s, "assert block not found (upstream changed?)"
s = s.replace(old, new, 1)

# (b) list every NULL table entry + the state that decides which entries VMA will reach for
anchor = """    // VMA_ASSERT(m_VulkanFunctions.vkGetDeviceBufferMemoryRequirements != VMA_NULL);
    // VMA_ASSERT(m_VulkanFunctions.vkGetDeviceImageMemoryRequirements != VMA_NULL);
}"""
diag = """    // VMA_ASSERT(m_VulkanFunctions.vkGetDeviceBufferMemoryRequirements != VMA_NULL);
    // VMA_ASSERT(m_VulkanFunctions.vkGetDeviceImageMemoryRequirements != VMA_NULL);

    // MEOWCRAFT DIAG
    fprintf(stderr, "[vma] apiVersion=%u.%u.%u useExtMemoryBudget=%d useKhrDedicatedAllocation=%d\\n",
            m_VulkanApiVersion >> 22, (m_VulkanApiVersion >> 12) & 0x3FFu, m_VulkanApiVersion & 0xFFFu,
            (int)m_UseExtMemoryBudget, (int)m_UseKhrDedicatedAllocation);
#define MEOWVMA_NULLCHECK(f) do { if (m_VulkanFunctions.f == VMA_NULL) fprintf(stderr, "[vma] NULL entry: %s\\n", #f); } while(0)
    MEOWVMA_NULLCHECK(vkGetPhysicalDeviceProperties);
    MEOWVMA_NULLCHECK(vkGetPhysicalDeviceProperties2KHR);
    MEOWVMA_NULLCHECK(vkGetPhysicalDeviceMemoryProperties);
    MEOWVMA_NULLCHECK(vkGetPhysicalDeviceMemoryProperties2KHR);
    MEOWVMA_NULLCHECK(vkGetDeviceBufferMemoryRequirements);
    MEOWVMA_NULLCHECK(vkGetDeviceImageMemoryRequirements);
    MEOWVMA_NULLCHECK(vkGetBufferMemoryRequirements);
    MEOWVMA_NULLCHECK(vkGetImageMemoryRequirements);
    MEOWVMA_NULLCHECK(vkBindBufferMemory);
    MEOWVMA_NULLCHECK(vkBindImageMemory);
    MEOWVMA_NULLCHECK(vkMapMemory);
    MEOWVMA_NULLCHECK(vkUnmapMemory);
    MEOWVMA_NULLCHECK(vkAllocateMemory);
    MEOWVMA_NULLCHECK(vkFreeMemory);
    MEOWVMA_NULLCHECK(vkCreateBuffer);
    MEOWVMA_NULLCHECK(vkDestroyBuffer);
    MEOWVMA_NULLCHECK(vkCreateImage);
    MEOWVMA_NULLCHECK(vkDestroyImage);
    MEOWVMA_NULLCHECK(vkCmdCopyBuffer);
    MEOWVMA_NULLCHECK(vkFlushMappedMemoryRanges);
    MEOWVMA_NULLCHECK(vkInvalidateMappedMemoryRanges);
    MEOWVMA_NULLCHECK(vkGetBufferMemoryRequirements2KHR);
    MEOWVMA_NULLCHECK(vkBindBufferMemory2KHR);
#undef MEOWVMA_NULLCHECK
}"""
assert anchor in s, "nullcheck anchor not found (upstream changed?)"
s = s.replace(anchor, diag, 1)

# (c) memset watcher: only screams when dst == NULL (never #define memset globally)
anchor2 = "#include <cstring>"
diag2 = """#include <cstring>
#include <cstdio>
// MEOWCRAFT DIAG: the fatal fault is memset(NULL, 0, 0x8000); report dst/SIZE whenever dst is NULL.
#define MEOWVMA_MEMSET(dst, val, sz)                                            \\
    do {                                                                        \\
        if ((void*)(dst) == (void*)0) {                                         \\
            fprintf(stderr, "[vma] memset NULL dst size=%zu (0x%zx)\\n",        \\
                    (size_t)(sz), (size_t)(sz));                                \\
            fflush(stderr);                                                     \\
        }                                                                       \\
        memset((dst), (val), (sz));                                             \\
    } while (0)"""
assert anchor2 in s, "cstring include not found"
s = s.replace(anchor2, diag2, 1)

pat = re.compile(r"memset\((?=[^;]*(?:pAllocations|m_FreeList|m_InnerIsFreeBitmap|m_RegionInfo|ctx\.pageAllocs))([^;]*)\);")
s, n = pat.subn(lambda m: "MEOWVMA_MEMSET(" + m.group(1) + ");", s)
assert n > 0, "no candidate memset sites matched"
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("   patched: assert gated on m_UseExtMemoryBudget + NULL-entry diagnostic + memset watcher (%d site(s))" % n)
PY
  INC_VMA="$PATCHED/main/c"
  GEN_VMA="$PATCHED/generated/c"
else
  # ---- 1. pristine: compile straight from ref/ (never modified) ------------
  INC_VMA="$VMA/src/main/c"
  GEN_VMA="$VMA/src/generated/c"
fi

# ---- 2. compile + link (mirrors stuffs/research/vulkan/build_vma_probe.sh) --
CF="$CC -O3 -fPIC -std=gnu++17 -pthread -DNDEBUG -DLWJGL_LINUX -DLWJGL_arm64 \
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 \
    -I$JNIINC -I$CORE/src/main/c -I$CORE/src/main/c/linux -I$INC_VMA -I$SDK/sysroot/usr/include"

echo "== compiling =="
for f in org_lwjgl_util_vma_LibVma org_lwjgl_util_vma_Vma; do
  echo "   $f.cpp"
  $CF -c "$GEN_VMA/$f.cpp" -o "$OBJ/$f.o"
done

echo "== linking liblwjgl_vma.so =="
# libc++ is linked STATICALLY so DT_NEEDED stays libc.so only (same convention as the other natives).
$CC -shared -fuse-ld=lld -z noexecstack -O3 -fPIC -pthread \
    -Wl,--no-undefined -Wl,--version-script,"$VSCRIPT" \
    "$OBJ/org_lwjgl_util_vma_LibVma.o" "$OBJ/org_lwjgl_util_vma_Vma.o" \
    "$LIBCXX_STATIC" \
    -o "$OUT/liblwjgl_vma.so"

[ -x "$STRIP" ] && "$STRIP" --strip-unneeded "$OUT/liblwjgl_vma.so" || true

# ---- 3. assertions ---------------------------------------------------------
echo "== assertions =="
N=$("$NM" -D --defined-only "$OUT/liblwjgl_vma.so" 2>/dev/null | grep -c 'org_lwjgl_' || true)
[ "$N" -ge 1 ] || { echo "error: no org_lwjgl_* exports" >&2; exit 1; }
BAD=$("$READELF" -d "$OUT/liblwjgl_vma.so" 2>/dev/null | grep NEEDED | grep -vc 'libc\.so' || true)
[ "$BAD" -eq 0 ] || { echo "error: unexpected DT_NEEDED" >&2; "$READELF" -d "$OUT/liblwjgl_vma.so" | grep NEEDED >&2; exit 1; }
"$READELF" -SW "$OUT/liblwjgl_vma.so" > "$OBJ/sections.txt" 2>/dev/null || true
grep -q 'note\.ohos' "$OBJ/sections.txt" || { echo "error: no .note.ohos" >&2; exit 1; }

NEW_SHA=$(sha256sum "$OUT/liblwjgl_vma.so" | cut -d' ' -f1)
SHIPPED_SHA=$(sha256sum "$SHIPPED/liblwjgl_vma.so" | cut -d' ' -f1)
echo "   exports org_lwjgl_* : $N"
echo "   NEEDED             : $( "$READELF" -d "$OUT/liblwjgl_vma.so" | grep NEEDED | sed 's/.*\[//;s/\]//' | tr '\n' ' ')"
echo "   size               : $(wc -c < "$OUT/liblwjgl_vma.so") bytes"
echo "   sha256             : $NEW_SHA"

if [ "$MODE" = release ]; then
  DIAGS=$(strings "$OUT/liblwjgl_vma.so" 2>/dev/null | grep -c '\[vma\]' || true)
  [ "$DIAGS" -eq 0 ] || echo "   WARNING: release build contains $DIAGS '[vma]' diagnostic string(s)" >&2
  echo "   shipped sha256     : $SHIPPED_SHA"
  if cmp -s "$OUT/liblwjgl_vma.so" "$SHIPPED/liblwjgl_vma.so"; then
    echo "   cmp vs shipped     : IDENTICAL (release == shipped)"
  else
    echo "   cmp vs shipped     : DIFFERS (expected if --work is not $CANON_WORK)"
  fi
else
  echo "   diagnostic strings : $(strings "$OUT/liblwjgl_vma.so" 2>/dev/null | grep -c '\[vma\]' || true) (see 'strings | grep \\[vma\\]')"
fi

# ---- 4. install (opt-in; release only) -------------------------------------
if [ "$DO_INSTALL" -eq 1 ]; then
  DST="$SHIPPED/liblwjgl_vma.so"
  cp "$OUT/liblwjgl_vma.so" "$DST"
  echo "   installed -> $DST"
  echo "   new sha   : $(sha256sum "$DST" | cut -d' ' -f1)"
  grep -v "$(printf '^common\tliblwjgl_vma.so\t')" "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
  printf 'common\tliblwjgl_vma.so\t%s\n' "$(sha256sum "$DST" | cut -d' ' -f1)" >> "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  echo "   manifest updated (common liblwjgl_vma.so)"
fi

echo "OK -> $OUT/liblwjgl_vma.so"
