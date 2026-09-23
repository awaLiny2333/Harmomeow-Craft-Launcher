// meowvulkan.c — Vulkan loader shim for this device's masked ICD.
//
// WHY: the OHOS ICD (vulkan.hvgr_v210.so) is a 1.4-era implementation that reports itself as
// Vulkan 1.2 and trims its *advertisement*: KHR-suffixed names are gated behind enabling, the
// post-1.2 feature bits are cleared, while the unsuffixed core names are exposed and real.
// MC 26.2/26.3 hard-requires VK_KHR_dynamic_rendering, VK_KHR_push_descriptor and
// VK_EXT_vertex_attribute_divisor, so it refuses the Vulkan backend before ever calling into it.
//
// This library is loaded INSTEAD of the system loader by LWJGL
// (mc.launcher passes -Dorg.lwjgl.vulkan.libname=libmeowvulkan.so) and forwards everything to the
// real loader at /system/lib64/libvulkan.so, with four corrections:
//
//   hook 1  vkEnumerateDeviceExtensionProperties : append the three gated names
//   hook 2  vkGetPhysicalDeviceFeatures2         : set the bits the ICD clears
//   hook 3  vkCreateDevice                       : strip the three names from a COPY
//                                                  (never mutate the caller's struct: LWJGL's own
//                                                  capability booleans are derived from it)
//   hook 4  vkGetDeviceProcAddr / vkGetInstanceProcAddr : map ...KHR -> the ICD's core name
//
// Not a lie for two of the three: dynamic_rendering and push_descriptor are really implemented and
// were proven pixel/state-level on device (notes sections 4.9, 4.9.4). vertex_attribute_divisor IS
// a lie -- maxVertexAttribDivisor is 1 -- but vanilla never uses a divisor other than 1 (section
// 5.4), so it is safe for our target while being wrong for mods. See section 7.6.
//
// MASTER SWITCH: MEOW_VK_SHIM. F75 (shim build 2026-09-18.55 env-cleanup): the shim HOOKS BY DEFAULT
// WHEN LOADED -- being loaded is the parameter (the launcher selects it through the Vulkan library
// NAME `-Dorg.lwjgl.vulkan.libname`, which carries "use Vulkan"). MEOW_VK_SHIM=0 (or empty) is PURE
// PASSTHROUGH -- exactly the system loader's behaviour -- an escape hatch, not a master on-switch.
// See notes section 7.5 for the rollback ladder.
//
// ============ ENV SWITCH TIERS (F80, shim build 2026-09-18.58 env-grading) ============
// ONE rule, by DEFAULT VALUE: TIER A = functionally required / default ON (the user sets none of
// these); TIER B = diagnostic / default OFF (opened by hand only to investigate). Authoritative list;
// keep it in sync when a switch is added or retired. The old temporary probes (16 MEOW_VK_PROBE_* and
// meowvkprobe.c) were deleted along with their tier.
//
// --- TIER A: FUNCTIONALLY REQUIRED -- default ON, the user sets NONE of these --------------------
//   MEOW_VK_SHIM=0 (or empty)          escape hatch: pure passthrough. Unset/1 = hooks on.
//   F66 (no env)                       merge submit entries; this ICD accepts exactly one entry.
//   MEOW_VK_SYNC2_TO_V1                sync2 -> v1 (follows hooks); both sync2 entries used together
//                                      kill the first submit.
//   MEOW_VK_SYNC2_TO_V1_MERGE          merge v1 entries (follows hooks); one-entry ICD (F66).
//   MEOW_VK_WAIT_VIA_QUEUE_IDLE        real vkQueueWaitIdle (default ON); vkWaitSemaphores times out.
//   MEOW_VK_TIMELINE_AS_FENCE          timeline -> real fence (F69); the counter never advances.
//   MEOW_VK_PUSH_AS_SET                emulate push with a normal set (F72); MC's only descriptor path.
//   MEOW_VK_FIX_SURFACE_TRANSFORM      force IDENTITY (F73/F74, default); WSI rotates 90 here.
//                                      "requested"/"0" = keep caller value.
//   MEOW_VK_STRIP_UNSUPPORTED_FEATURES zero unsupported bits (F36, default); else createDevice rc=-8.
//
// --- TIER B: DIAGNOSTIC -- default OFF, kept so a defect can be re-investigated -----------------
//   MEOW_VK_VERBOSE                    per-call / detail logs (high volume, perturbs timing); also
//                                      makes the F72b push totals line print on every push (F104).
//   MEOW_VK_WD=<seconds>               hang watchdog: SIGQUIT for a thread dump when Vulkan goes quiet.
//   MEOW_VK_FIX_EXTENT=current         force imageExtent = caps.currentExtent (not needed here yet).
//   MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE=1 F53 CopyBufferToImage rewrite (default OFF since F61).
//   MEOW_VK_NO_DIVISOR_FEATURE=1       skip the divisor feature lie (would make MC refuse Vulkan).
//   MEOW_VK_DROP_DRAW=1                drop all draws, to bisect a failing frame.
//   MEOW_VK_DROP_PUSH_DESCRIPTOR=1     drop all push descriptors, to bisect a failing frame.
//   MEOW_VK_F72_RING=1                 F92/F99 descriptor-set reuse -- STUDY ONLY, default OFF (F100).
//                                      Reuse REPLACES vkResetDescriptorPool, so a pool's maxSets budget
//                                      is never returned: allocs reach pools*maxSets, then
//                                      OUT_OF_POOL_MEMORY -> native push fallback -> DEVICE_LOST.
//                                      F99's coverage gate (I5) is kept; reuse is not a default.
//   MEOW_VK_TOTALS_SEC=<seconds>       F98: print the F72b push totals line every N seconds even in
//                                      steady state (opt-in heartbeat). F104: the totals line is now
//                                      DEFAULT SILENT (MEOW_VK_VERBOSE or this env is needed to see it).
// ===============================================================================
//
// STATUS: production shim. The four corrections above are the shipped Vulkan path -- the launcher
// selects this library by name when the Vulkan backend is chosen; the env tiers above are the
// supported switches. The M1 milestone (get MC's Vulkan backend to start so its real calls could be
// observed) is complete. See notes/20-design/render/Vulkan后端-绕过可行性-调研与方案.md section 11.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "meowlog.h"
#include "meowbt.h"

// Official Vulkan types/enums, straight from the OHOS SDK header
// (<sdk>/default/openharmony/native/sysroot/usr/include/vulkan/vulkan.h). VK_NO_PROTOTYPES is
// required: this shim never links libvulkan.so -- it dlopen()s the real loader and forwards through
// function pointers -- and without it the header's vk* prototypes would clash with our own exports.
// VK_USE_PLATFORM_OHOS is deliberately NOT defined: this file uses no OHOS platform types.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#define REAL_LOADER "/system/lib64/libvulkan.so"

// VkInstance/VkPhysicalDevice/VkDevice/VkBool32/VkResult/VkExtensionProperties now come from the
// official header. The old local VkBase {sType,pNext} mirror is replaced by the SDK's
// VkBaseInStructure/VkBaseOutStructure (vulkan_core.h:3069/3074) in the pNext walks below.
typedef VkDeviceCreateInfo VkDeviceCI;   // fields use the official spellings (see hook_CreateDevice)

// Official feature structs, so field order/size can never drift from LWJGL's binding again:
// VkPhysicalDeviceVulkan13Features (vulkan_core.h:7039), VkPhysicalDeviceDynamicRenderingFeatures
// (:7469), VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT (:8107) and
// VkPhysicalDeviceSynchronization2Features (:7246). Field accesses use the SDK names.
typedef VkPhysicalDeviceVulkan13Features Vk13Features;
typedef VkPhysicalDeviceDynamicRenderingFeatures VkDynRenderFeatures;
typedef VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT VkDivisorFeaturesExt;

// sType values: official enum constants from vulkan_core.h (no hand-typed numbers).
#define ST_VK13_FEATURES        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
#define ST_DYNREND_FEATURES     VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES
#define ST_DIVISOR_FEATURES_EXT VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT

// The names MC needs that the ICD implements but does not advertise. Measured addition (2026-09-17):
// VK_KHR_get_physical_device_properties2. On this 1.2-core device LWJGL does not resolve the KHR
// spellings of the 1.1 "2" queries unless that extension is enabled, so VMA's function table ended up
// with a NULL vkGetPhysicalDeviceMemoryProperties2KHR -- VMA aborts on it (vk_mem_alloc.h:13824) with
// assertions on and calls straight through it with -DNDEBUG (the wild low-address reads this project
// chased). Advertising the extension makes LWJGL resolve the KHR name, and hook 4 maps it to the
// unsuffixed core implementation the ICD really has. Hook 3 strips it again at createDevice if the
// ICD rejects the name, exactly like the other three.
static const char* kGatedNames[] = {
    "VK_KHR_dynamic_rendering",
    "VK_KHR_push_descriptor",
    "VK_EXT_vertex_attribute_divisor",
    "VK_KHR_get_physical_device_properties2",
};
#define kGatedCount ((int)(sizeof(kGatedNames) / sizeof(kGatedNames[0])))

// ------------------------------------------------------------------ plumbing
typedef void (*PFN_vkVoidFunctionLocal)(void);
static void* g_real;
static PFN_vkVoidFunctionLocal (*g_gipa)(VkInstance, const char*);
static PFN_vkVoidFunctionLocal (*g_gdpa)(VkDevice, const char*);
static int g_hooks;
// The instance the application created, stashed from vkGetInstanceProcAddr. Instance-level commands
// (vkEnumerateDeviceExtensionProperties, vkGetPhysicalDeviceFeatures2, vkCreateDevice, ...) are NOT
// required to resolve against a NULL instance -- only *global* commands are. Resolving them with
// NULL is what made this shim hand MC a VK_ERROR_EXTENSION_NOT_PRESENT for
// "Failed to get number of device extension properties" (measured on device).
static VkInstance g_inst_seen;
// Same idea for the device: device-level commands (vkCmd*) must be resolved through the device.
static VkDevice g_dev_seen;

// F87 (.65): per-wrapper cache for resolved device-function pointers. Each hot wrapper owns its own
// static slot (declared just below), so a call costs one pointer compare plus - only when the device
// changed or the slot is still unresolved - one g_gdpa() lookup. It is never a per-call table lookup.
// g_gdpa == NULL keeps the original "resolution failed" behaviour (slot stays NULL and is retried).
// CONTRACT: single render thread (A10 G5; the same lock-free assumption g_dev_seen already makes).
//
// F91 (M1 race, review A39 F1): the two fields are a (device tag, pointer) pair. To keep them from
// being observed crossed under a contract violation, WRITE the device tag first, then release-publish
// the pointer; READ the device tag first, then the pointer. Under the single render thread this is
// strictly equivalent to the old body (same condition, same g_gdpa call, same returned value).
static PFN_vkVoidFunctionLocal meow_cached_proc(PFN_vkVoidFunctionLocal* slot, void** devSlot,
                                                const char* name) {
    void* dev = (void*)g_dev_seen;
    void* cachedDev = __atomic_load_n(devSlot, __ATOMIC_ACQUIRE);        // (1) device tag first
    PFN_vkVoidFunctionLocal p = __atomic_load_n(slot, __ATOMIC_ACQUIRE); // (2) then the pointer
    if (p == NULL || cachedDev != dev) {
        p = g_gdpa ? g_gdpa(g_dev_seen, name) : NULL;
        __atomic_store_n(devSlot, dev, __ATOMIC_RELAXED);               // publish the tag first
        __atomic_store_n(slot, p, __ATOMIC_RELEASE);                    // then the pointer (release)
    }
    return p;
}
#define MEOW_F87_SLOT(N) static PFN_vkVoidFunctionLocal meow_p_##N; static void* meow_d_##N;
MEOW_F87_SLOT(vkCmdCopyBufferToImage)
MEOW_F87_SLOT(vkCmdPushDescriptorSet)
MEOW_F87_SLOT(vkQueueSubmit)
MEOW_F87_SLOT(vkQueueSubmit2)
MEOW_F87_SLOT(vkCmdPipelineBarrier)
MEOW_F87_SLOT(vkCmdPipelineBarrier2)
MEOW_F87_SLOT(vkCmdBeginRendering)
MEOW_F87_SLOT(vkCmdEndRendering)
MEOW_F87_SLOT(vkCmdBindPipeline)
MEOW_F87_SLOT(vkCmdBindDescriptorSets)
MEOW_F87_SLOT(vkCmdBindVertexBuffers)
MEOW_F87_SLOT(vkCmdBindIndexBuffer)
MEOW_F87_SLOT(vkCmdDraw)
MEOW_F87_SLOT(vkCmdDrawIndexed)
MEOW_F87_SLOT(vkCmdDrawIndirect)
MEOW_F87_SLOT(vkCmdDrawIndexedIndirect)
MEOW_F87_SLOT(vkCmdCopyBuffer)
MEOW_F87_SLOT(vkCmdCopyImage)
MEOW_F87_SLOT(vkCmdBlitImage)
MEOW_F87_SLOT(vkCmdClearColorImage)
MEOW_F87_SLOT(vkCmdClearAttachments)
MEOW_F87_SLOT(vkCmdSetViewport)
MEOW_F87_SLOT(vkCmdSetScissor)
MEOW_F87_SLOT(vkCmdPushConstants)
MEOW_F87_SLOT(vkCmdUpdateBuffer)
MEOW_F87_SLOT(vkCmdFillBuffer)
MEOW_F87_SLOT(vkCmdExecuteCommands)
MEOW_F87_SLOT(vkCmdPushDescriptorSetWithTemplate)
MEOW_F87_SLOT(vkCmdSetEvent)
MEOW_F87_SLOT(vkCmdResetEvent)
MEOW_F87_SLOT(vkCmdWaitEvents)
MEOW_F87_SLOT(vkCmdSetEvent2)
MEOW_F87_SLOT(vkCmdResetEvent2)
MEOW_F87_SLOT(vkCmdWaitEvents2)
MEOW_F87_SLOT(vkCmdWriteTimestamp)
MEOW_F87_SLOT(vkCmdWriteTimestamp2)
MEOW_F87_SLOT(vkAllocateDescriptorSets)
MEOW_F87_SLOT(vkUpdateDescriptorSets)
// F92 (.70 per-call cost): the remaining per-frame/per-call resolution points. Same F87 pair-per-wrapper
// contract (one pointer compare per call; g_gdpa() only on device change or first use). Device change
// invalidates automatically because meow_cached_proc re-resolves whenever g_dev_seen differs.
MEOW_F87_SLOT(vkCreateFence)
MEOW_F87_SLOT(vkWaitForFences)
MEOW_F87_SLOT(vkGetFenceStatus)
MEOW_F87_SLOT(vkDestroyFence)
MEOW_F87_SLOT(vkQueueWaitIdle)
MEOW_F87_SLOT(vkWaitSemaphores)
MEOW_F87_SLOT(vkGetSemaphoreCounterValue)
MEOW_F87_SLOT(vkDeviceWaitIdle)
MEOW_F87_SLOT(vkResetDescriptorPool)
MEOW_F87_SLOT(vkAcquireNextImageKHR)
MEOW_F87_SLOT(vkQueuePresentKHR)
MEOW_F87_SLOT(vkBeginCommandBuffer)
MEOW_F87_SLOT(vkAllocateCommandBuffers)
MEOW_F87_SLOT(vkCmdBeginDebugUtilsLabelEXT)
MEOW_F87_SLOT(vkCmdEndDebugUtilsLabelEXT)
MEOW_F87_SLOT(vkCmdInsertDebugUtilsLabelEXT)

// F60 (shim build .40): the queue used by the most recent submit/present, so the vkWaitSemaphores
// wrapper can perform a REAL wait (vkQueueWaitIdle) instead of trusting this ICD's broken timeline
// completion signal. The submit wrappers (v1/v2) and vkQueuePresentKHR only WRITE it here; the sole
// reader is log_WaitSemaphores. MC renders on one thread, so this is deliberately lock-free -- the
// same assumption g_dev_seen already makes. See stuffs/research/vulkan/fixes/F60-wait-via-queue-idle.md.
static void* g_meow_last_queue;
static unsigned long g_meow_wait_qidle;

// F54 (shim build .34): meow_vk_verbose() is defined with the exports far below; forward-declare it
// here because the per-command wrappers above use it to gate their high-volume CALLED/detail logs.
static int meow_vk_verbose(void);

// =====================================================================================
// F53 (shim build .33): redirect vkCmdCopyBufferToImage.
//
// WHY: on this ICD every vkCmdCopyBufferToImage RECORDS fine but the submit that contains
// it is rejected as rc=-1 (VK_ERROR_OUT_OF_HOST_MEMORY). The two commands the ICD does
// execute correctly are vkCmdCopyBuffer (buffer->buffer) and vkCmdCopyImage
// (image->image, measured byte-identical). So a buffer->image upload is rewritten as:
//   1. a per-target LINEAR intermediate image, with a TRANSFER_DST buffer aliased onto the
//      SAME VkDeviceMemory (memory aliasing, both "linear" resources);
//   2. vkCmdCopyBuffer(src -> alias)          [GPU, verified good]
//   3. vkCmdCopyImage(linear -> dst, dstLayout) [GPU, verified good]
// The whole rewrite happens INSIDE the recording call; nothing is deferred to submit time
// and no CPU readback is involved. (A CPU "map staging -> copy" design cannot work here:
// command buffers are already ended at submit time, and a CPU cannot observe a
// vkCmdCopyBuffer recorded into an unsubmitted command buffer, so it would read stale
// data. The GPU route above handles device-local and host-visible sources identically.)
//
// MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE=0 disables it (A/B control); default follows hooks.
// Any unknown image, unsupported format, or oversized region list forwards the original
// call unchanged, so the shim degrades to today's behaviour instead of guessing.
// =====================================================================================

/* All Vulkan constants below expand to the official SDK enums (vulkan_core.h) -- none is hand-typed. */
#define MEOW_F53_ST_IMAGE_CREATE_INFO      VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
#define MEOW_F53_ST_BUFFER_CREATE_INFO     VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
#define MEOW_F53_ST_MEMORY_ALLOCATE_INFO   VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
#define MEOW_F53_ST_IMAGE_MEMORY_BARRIER   VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
#define MEOW_F53_ST_MEMORY_BARRIER         VK_STRUCTURE_TYPE_MEMORY_BARRIER
#define MEOW_F53_TILING_OPTIMAL            VK_IMAGE_TILING_OPTIMAL
#define MEOW_F53_TILING_LINEAR             VK_IMAGE_TILING_LINEAR
#define MEOW_F53_SHARING_EXCLUSIVE         VK_SHARING_MODE_EXCLUSIVE
#define MEOW_F53_LAYOUT_UNDEFINED          VK_IMAGE_LAYOUT_UNDEFINED
#define MEOW_F53_LAYOUT_GENERAL            VK_IMAGE_LAYOUT_GENERAL
#define MEOW_F53_IMAGE_USAGE_TRANSFER_SRC  VK_IMAGE_USAGE_TRANSFER_SRC_BIT
#define MEOW_F53_IMAGE_USAGE_TRANSFER_DST  VK_IMAGE_USAGE_TRANSFER_DST_BIT
#define MEOW_F53_BUFFER_USAGE_TRANSFER_DST VK_BUFFER_USAGE_TRANSFER_DST_BIT
#define MEOW_F53_ASPECT_COLOR              VK_IMAGE_ASPECT_COLOR_BIT
#define MEOW_F53_STAGE_TOP_OF_PIPE         VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
#define MEOW_F53_STAGE_TRANSFER            VK_PIPELINE_STAGE_TRANSFER_BIT
#define MEOW_F53_ACCESS_TRANSFER_READ      VK_ACCESS_TRANSFER_READ_BIT
#define MEOW_F53_ACCESS_TRANSFER_WRITE     VK_ACCESS_TRANSFER_WRITE_BIT
#define MEOW_F53_QF_IGNORED                VK_QUEUE_FAMILY_IGNORED
#define MEOW_F53_MAX_BUFFER_COPIES 131072u
#define MEOW_F53_IMG_CACHE_MAX 512
// F57 (shim build .37): O(1) slot lookup. A fixed 1024-bucket separate-chaining table (load factor
// 0.5 at 512 entries) plus an intrusive free list turns a saturated cache from a 512-entry scan into
// an O(1) early exit. Semantics are unchanged: at most the same 512 live images tracked by exact
// pointer, same hit/miss decisions.
#define MEOW_F53_IMG_HASH_SIZE 1024

/* F53 mirrors are now aliases to the official SDK types (vulkan_core.h): no handwritten layout
   remains, so any header field/offset change propagates automatically. Field accesses below use the
   official spellings (extent.width/height/depth, imageSubresource, imageOffset, imageExtent,
   srcSubresource/dstSubresource, subresourceRange). */
typedef VkImageCreateInfo          MeowF53ImageCreateInfoL;
typedef VkBufferCreateInfo         MeowF53BufferCreateInfoL;
typedef VkMemoryAllocateInfo       MeowF53MemoryAllocateInfoL;
typedef VkMemoryRequirements       MeowF53MemoryRequirementsL;
typedef VkImageSubresource         MeowF53ImageSubresourceL;
typedef VkSubresourceLayout        MeowF53SubresourceLayoutL;
typedef VkBufferCopy               MeowF53BufferCopyL;
typedef VkImageSubresourceLayers   MeowF53SubresourceLayersL;
typedef VkBufferImageCopy          MeowF53BufferImageCopyL;
typedef VkImageCopy                MeowF53ImageCopyL;
typedef VkImageMemoryBarrier       MeowF53ImageBarrierL;
typedef VkMemoryBarrier            MeowF53MemoryBarrierL;

typedef int (*MeowF53PFN_createImage)(void*, const void*, const void*, void**);
typedef void (*MeowF53PFN_destroyImage)(void*, void*, const void*);
typedef void (*MeowF53PFN_getImageMemReq)(void*, void*, void*);
typedef int (*MeowF53PFN_bindImageMemory)(void*, void*, void*, uint64_t);
typedef void (*MeowF53PFN_getImageLayout)(void*, void*, const void*, void*);
typedef int (*MeowF53PFN_createBuffer)(void*, const void*, const void*, void**);
typedef void (*MeowF53PFN_destroyBuffer)(void*, void*, const void*);
typedef void (*MeowF53PFN_getBufferMemReq)(void*, void*, void*);
typedef int (*MeowF53PFN_bindBufferMemory)(void*, void*, void*, uint64_t);
typedef int (*MeowF53PFN_allocateMemory)(void*, const void*, const void*, void**);
typedef void (*MeowF53PFN_freeMemory)(void*, void*, const void*);
typedef void (*MeowF53PFN_cmdCopyBuffer)(void*, void*, void*, uint32_t, const void*);
typedef void (*MeowF53PFN_cmdCopyImage)(void*, void*, uint32_t, void*, uint32_t, uint32_t, const void*);
typedef void (*MeowF53PFN_cmdPipelineBarrier)(void*, uint32_t, uint32_t, uint32_t, uint32_t,
                                              const void*, uint32_t, const void*, uint32_t, const void*);

static PFN_vkVoidFunctionLocal meow_f53_sym(const char* n) {
    return g_gdpa ? g_gdpa(g_dev_seen, n) : NULL;
}

static int meow_f53_decide(const char** why) {
    const char* s = getenv("MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE");
    if (s != NULL && strcmp(s, "0") == 0) {
        if (why != NULL) *why = "explicit OFF (MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE=0)";
        return 0;
    }
    if (s != NULL && s[0] == '1') {
        if (why != NULL) *why = "explicit ON (MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE=1)";
        return 1;
    }
    // F61 (shim build .41): DEFAULT OFF, independent of hooks. A11 proved F53 cannot cure the rc=-4 /
    // rc=-1 submit failures (it was an "avoid the upload" attempt and LOG-B still failed with every
    // upload redirected), while each redirected upload pays calloc + a double GPU copy. Keep the code
    // path for A/B reuse, but never enable it implicitly; MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE=1 opts in.
    if (why != NULL) *why = "default OFF (F61; MEOW_VK_FIX_COPY_BUFFER_TO_IMAGE=1 to enable)";
    return 0;
}

// Bytes per texel for the UNCOMPRESSED color formats (vulkan_core.h:1855-1984). Returns 0
// for depth/stencil, block-compressed and multi-planar formats, which are refused (LINEAR
// tiling is not even legal for most of those).
static uint32_t meow_f53_format_bpp(uint32_t f) {
    if (f == 1u) return 1u;
    if (f >= 2u && f <= 8u) return 2u;
    if (f >= 9u && f <= 15u) return 1u;
    if (f >= 16u && f <= 22u) return 2u;
    if (f >= 23u && f <= 36u) return 3u;
    if (f >= 37u && f <= 57u) return 4u;
    if (f >= 58u && f <= 69u) return 4u;
    if (f >= 70u && f <= 76u) return 2u;
    if (f >= 77u && f <= 83u) return 4u;
    if (f >= 84u && f <= 90u) return 6u;
    if (f >= 91u && f <= 97u) return 8u;
    if (f >= 98u && f <= 100u) return 4u;
    if (f >= 101u && f <= 103u) return 8u;
    if (f >= 104u && f <= 106u) return 12u;
    if (f >= 107u && f <= 109u) return 16u;
    if (f >= 110u && f <= 112u) return 8u;
    if (f >= 113u && f <= 115u) return 16u;
    if (f >= 116u && f <= 118u) return 24u;
    if (f >= 119u && f <= 121u) return 32u;
    if (f == 122u || f == 123u) return 4u;
    return 0u;
}

typedef struct {
    void* image;
    uint32_t format, imageType, samples, mipLevels, arrayLayers, usage, tiling;
    uint32_t width, height, depth;
    int used;
    int interState;      /* 0 = none, 1 = ready, 2 = failed */
    int interGeneral;    /* linear image has been moved UNDEFINED -> GENERAL */
    void* linImage;
    void* aliasBuffer;
    void* linMem;
    uint32_t interMip, interLayers;
    int32_t link;        /* F57: bucket-chain next slot, or free-list next slot */
} MeowF53ImgEntry;

static MeowF53ImgEntry g_meow_f53_imgs[MEOW_F53_IMG_CACHE_MAX];
static pthread_mutex_t g_meow_f53_img_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long g_meow_f53_redirects;
static unsigned long g_meow_f53_fallbacks;

// F61 (shim build .41): create-info STAGING, separate from the redirect cache above. vkCreateImage
// only stashes the VkImageCreateInfo here -- one direct-mapped write, no chains, no free list, no
// "full" state, no per-image log. An image is promoted into the redirect cache ONLY when it actually
// becomes a vkCmdCopyBufferToImage destination ("lazy registration"). The staging table is keyed by
// the same F57 pointer hash, so a create can never saturate the cache the way .40 did; a collision
// just overwrites a stale entry. Semantics change: F53 no longer silently stops redirecting merely
// because the app created more than MEOW_F53_IMG_CACHE_MAX images (the .40 "越跑越卡" regression).
#define MEOW_F53_INFO_SIZE MEOW_F53_IMG_HASH_SIZE
typedef struct {
    void* image;
    uint32_t format, imageType, samples, mipLevels, arrayLayers, usage, tiling;
    uint32_t width, height, depth;
    int used;
} MeowF53ImgInfo;
static MeowF53ImgInfo g_meow_f53_info[MEOW_F53_INFO_SIZE];

// F57 (shim build .37): O(1) index over g_meow_f53_imgs. g_meow_f53_buckets[h] is a slot index or -1;
// each entry's `link` is either the next slot in its bucket chain or the next free slot. All of this
// (like g_meow_f53_imgs itself) is guarded by g_meow_f53_img_lock.
static int32_t g_meow_f53_buckets[MEOW_F53_IMG_HASH_SIZE];
static int32_t g_meow_f53_free_head;
static int g_meow_f53_fast_ready;

static uint32_t meow_f53_hash_ptr(const void* p) {
    uint64_t x = (uint64_t)(uintptr_t)p;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (uint32_t)(x & (uint64_t)(MEOW_F53_IMG_HASH_SIZE - 1));
}

/* F61: staging is direct-mapped on the same hash -> exactly one slot, so a create is O(1) and can
   never report "full". Caller holds g_meow_f53_img_lock. */
static void meow_f53_info_drop_locked(void* img) {
    MeowF53ImgInfo* s = &g_meow_f53_info[meow_f53_hash_ptr(img)];
    if (s->used && s->image == img) s->used = 0;
}

/* Caller holds g_meow_f53_img_lock. */
static void meow_f53_fast_init_locked(void) {
    if (g_meow_f53_fast_ready) return;
    for (int i = 0; i < MEOW_F53_IMG_HASH_SIZE; i++) g_meow_f53_buckets[i] = -1;
    for (int i = 0; i < MEOW_F53_IMG_CACHE_MAX; i++) {
        g_meow_f53_imgs[i].used = 0;
        g_meow_f53_imgs[i].link = (i + 1 < MEOW_F53_IMG_CACHE_MAX) ? (int32_t)(i + 1) : -1;
    }
    g_meow_f53_free_head = 0;
    g_meow_f53_fast_ready = 1;
}

/* Caller holds g_meow_f53_img_lock. */
static int meow_f53_lookup_locked(void* img) {
    if (!g_meow_f53_fast_ready) return -1;
    for (int32_t i = g_meow_f53_buckets[meow_f53_hash_ptr(img)]; i >= 0; i = g_meow_f53_imgs[i].link) {
        if (g_meow_f53_imgs[i].used && g_meow_f53_imgs[i].image == img) return (int)i;
    }
    return -1;
}

/* Caller holds g_meow_f53_img_lock. -1 on a full cache: O(1), no traversal. */
static int meow_f53_claim_locked(void) {
    if (g_meow_f53_free_head < 0) return -1;
    int32_t slot = g_meow_f53_free_head;
    g_meow_f53_free_head = g_meow_f53_imgs[slot].link;
    return (int)slot;
}

/* Caller holds g_meow_f53_img_lock; sets the entry's bucket link (link was cleared by memset). */
static void meow_f53_link_locked(int idx, void* img) {
    uint32_t h = meow_f53_hash_ptr(img);
    g_meow_f53_imgs[idx].link = g_meow_f53_buckets[h];
    g_meow_f53_buckets[h] = (int32_t)idx;
}

/* Caller holds g_meow_f53_img_lock; unlinks from its bucket chain and returns the slot to free list. */
static void meow_f53_release_locked(int idx) {
    uint32_t h = meow_f53_hash_ptr(g_meow_f53_imgs[idx].image);
    int32_t prev = -1;
    for (int32_t i = g_meow_f53_buckets[h]; i >= 0; i = g_meow_f53_imgs[i].link) {
        if (i == (int32_t)idx) {
            if (prev < 0) g_meow_f53_buckets[h] = g_meow_f53_imgs[i].link;
            else g_meow_f53_imgs[prev].link = g_meow_f53_imgs[i].link;
            break;
        }
        prev = i;
    }
    g_meow_f53_imgs[idx].used = 0;
    g_meow_f53_imgs[idx].link = g_meow_f53_free_head;
    g_meow_f53_free_head = (int32_t)idx;
}

// F61 (shim build .41): the create path no longer registers into the redirect cache. It only stashes
// the create-info (one O(1) direct-mapped write); NO slot is held, NO counter is bumped, NO log is
// emitted. This is the "lazy registration" fix for the .40 "越跑越卡": with .40 all 3500 created
// images were registered, so once the 512 slots filled every new image walked the full path and
// g_meow_f53_cache_full grew monotonically. Here, only real upload targets ever enter the cache.
static void meow_f53_stage_created(void* img, const void* ci) {
    if (!g_hooks || img == NULL || ci == NULL) return;
    const MeowF53ImageCreateInfoL* c = (const MeowF53ImageCreateInfoL*)ci;
    pthread_mutex_lock(&g_meow_f53_img_lock);
    MeowF53ImgInfo* s = &g_meow_f53_info[meow_f53_hash_ptr(img)];
    s->used = 1;
    s->image = img;
    s->format = c->format;
    s->imageType = c->imageType;
    s->samples = c->samples;
    s->mipLevels = c->mipLevels ? c->mipLevels : 1u;
    s->arrayLayers = c->arrayLayers ? c->arrayLayers : 1u;
    s->usage = c->usage;
    s->tiling = c->tiling;
    s->width = c->extent.width;
    s->height = c->extent.height;
    s->depth = c->extent.depth ? c->extent.depth : 1u;
    pthread_mutex_unlock(&g_meow_f53_img_lock);
}

// F61: promote a staged image into the redirect cache the first time it is the destination of a
// vkCmdCopyBufferToImage. Returns the slot, or -1 when the image was never staged (or its staging
// slot was overwritten by a collision) or when the redirect cache is full. Full is a silent O(1)
// early exit: the fast path is a single free-list pop, so zero traversal, zero allocation, zero
// counter increment and zero per-call log. Only ONE one-time notice marks the first saturation.
static int meow_f53_register_target(void* img) {
    if (img == NULL) return -1;
    int slot = -1;
    pthread_mutex_lock(&g_meow_f53_img_lock);
    MeowF53ImgInfo* s = &g_meow_f53_info[meow_f53_hash_ptr(img)];
    if (!s->used || s->image != img) {
        pthread_mutex_unlock(&g_meow_f53_img_lock);
        return -1;
    }
    MeowF53ImgInfo info = *s;
    s->used = 0;                 /* consumed on promotion: one staged entry per tracked target */
    if (!g_meow_f53_fast_ready) meow_f53_fast_init_locked();
    slot = meow_f53_claim_locked();
    if (slot < 0) {
        static int s_f53_full_noted;
        if (!s_f53_full_noted) {
            s_f53_full_noted = 1;
            MEOWLOGW("meowvulkan: F53 target cache full (%{public}d); further upload targets forwarded",
                     MEOW_F53_IMG_CACHE_MAX);
        }
        pthread_mutex_unlock(&g_meow_f53_img_lock);
        return -1;
    }
    MeowF53ImgEntry* e = &g_meow_f53_imgs[slot];
    memset(e, 0, sizeof(*e));
    e->used = 1;
    e->image = img;
    e->format = info.format;
    e->imageType = info.imageType;
    e->samples = info.samples;
    e->mipLevels = info.mipLevels;
    e->arrayLayers = info.arrayLayers;
    e->usage = info.usage;
    e->tiling = info.tiling;
    e->width = info.width;
    e->height = info.height;
    e->depth = info.depth;
    meow_f53_link_locked(slot, img);
    pthread_mutex_unlock(&g_meow_f53_img_lock);
    return slot;
}

static int meow_f53_find(void* img) {
    if (img == NULL) return -1;
    int found = -1;
    pthread_mutex_lock(&g_meow_f53_img_lock);
    found = meow_f53_lookup_locked(img);
    pthread_mutex_unlock(&g_meow_f53_img_lock);
    return found;
}

static void meow_f53_destroy_partial(void* lin, void* ab, void* mem) {
    MeowF53PFN_destroyBuffer db = (MeowF53PFN_destroyBuffer)meow_f53_sym("vkDestroyBuffer");
    MeowF53PFN_destroyImage di = (MeowF53PFN_destroyImage)meow_f53_sym("vkDestroyImage");
    MeowF53PFN_freeMemory fm = (MeowF53PFN_freeMemory)meow_f53_sym("vkFreeMemory");
    if (ab != NULL && db != NULL) db(g_dev_seen, ab, NULL);
    if (lin != NULL && di != NULL) di(g_dev_seen, lin, NULL);
    if (mem != NULL && fm != NULL) fm(g_dev_seen, mem, NULL);
}

static int meow_f53_ensure_intermediate(MeowF53ImgEntry* e) {
    if (e->interState == 1) return 1;
    if (e->interState == 2) return 0;
    e->interState = 2;   /* pessimistic: stays 2 unless the whole set-up succeeds */
    MeowF53PFN_createImage realCreateImage = (MeowF53PFN_createImage)meow_f53_sym("vkCreateImage");
    MeowF53PFN_getImageMemReq realGetImageMemReq = (MeowF53PFN_getImageMemReq)meow_f53_sym("vkGetImageMemoryRequirements");
    MeowF53PFN_createBuffer realCreateBuffer = (MeowF53PFN_createBuffer)meow_f53_sym("vkCreateBuffer");
    MeowF53PFN_getBufferMemReq realGetBufferMemReq = (MeowF53PFN_getBufferMemReq)meow_f53_sym("vkGetBufferMemoryRequirements");
    MeowF53PFN_allocateMemory realAllocateMemory = (MeowF53PFN_allocateMemory)meow_f53_sym("vkAllocateMemory");
    MeowF53PFN_bindImageMemory realBindImageMemory = (MeowF53PFN_bindImageMemory)meow_f53_sym("vkBindImageMemory");
    MeowF53PFN_bindBufferMemory realBindBufferMemory = (MeowF53PFN_bindBufferMemory)meow_f53_sym("vkBindBufferMemory");
    if (realCreateImage == NULL || realGetImageMemReq == NULL || realCreateBuffer == NULL ||
        realGetBufferMemReq == NULL || realAllocateMemory == NULL || realBindImageMemory == NULL ||
        realBindBufferMemory == NULL) {
        MEOWLOGE("meowvulkan: F53 intermediate: a required entry point is unresolved; forwarding original");
        return 0;
    }
    void* lin = NULL;
    void* ab = NULL;
    void* mem = NULL;
    MeowF53ImageCreateInfoL ci;
    memset(&ci, 0, sizeof(ci));
    ci.sType = MEOW_F53_ST_IMAGE_CREATE_INFO;
    ci.imageType = e->imageType;
    ci.format = e->format;
    ci.extent.width = e->width;
    ci.extent.height = e->height;
    ci.extent.depth = e->depth;
    ci.mipLevels = e->mipLevels;
    ci.arrayLayers = e->arrayLayers;
    ci.samples = e->samples;
    ci.tiling = MEOW_F53_TILING_LINEAR;
    ci.usage = MEOW_F53_IMAGE_USAGE_TRANSFER_SRC | MEOW_F53_IMAGE_USAGE_TRANSFER_DST;
    ci.sharingMode = MEOW_F53_SHARING_EXCLUSIVE;
    ci.initialLayout = MEOW_F53_LAYOUT_UNDEFINED;
    int rc = realCreateImage(g_dev_seen, &ci, NULL, &lin);
    if (rc != 0 || lin == NULL) {
        MEOWLOGE("meowvulkan: F53 intermediate: vkCreateImage(LINEAR) rc=%{public}d; forwarding original", rc);
        return 0;
    }
    MeowF53MemoryRequirementsL imgReq;
    memset(&imgReq, 0, sizeof(imgReq));
    realGetImageMemReq(g_dev_seen, lin, &imgReq);
    MeowF53BufferCreateInfoL bci;
    memset(&bci, 0, sizeof(bci));
    bci.sType = MEOW_F53_ST_BUFFER_CREATE_INFO;
    bci.size = imgReq.size;
    bci.usage = MEOW_F53_BUFFER_USAGE_TRANSFER_DST;
    bci.sharingMode = MEOW_F53_SHARING_EXCLUSIVE;
    rc = realCreateBuffer(g_dev_seen, &bci, NULL, &ab);
    if (rc != 0 || ab == NULL) {
        MEOWLOGE("meowvulkan: F53 intermediate: vkCreateBuffer(alias) rc=%{public}d; forwarding original", rc);
        meow_f53_destroy_partial(lin, NULL, NULL);
        return 0;
    }
    MeowF53MemoryRequirementsL bufReq;
    memset(&bufReq, 0, sizeof(bufReq));
    realGetBufferMemReq(g_dev_seen, ab, &bufReq);
    uint32_t bits = imgReq.memoryTypeBits & bufReq.memoryTypeBits;
    int mt = -1;
    for (int k = 0; k < 32; k++) {
        if ((bits & (1u << k)) != 0u) { mt = k; break; }
    }
    if (mt < 0) {
        MEOWLOGE("meowvulkan: F53 intermediate: no memory type usable by both image and alias buffer; forwarding original");
        meow_f53_destroy_partial(lin, ab, NULL);
        return 0;
    }
    uint64_t bytes = (imgReq.size > bufReq.size) ? imgReq.size : bufReq.size;
    MeowF53MemoryAllocateInfoL mai;
    memset(&mai, 0, sizeof(mai));
    mai.sType = MEOW_F53_ST_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = bytes;
    mai.memoryTypeIndex = (uint32_t)mt;
    rc = realAllocateMemory(g_dev_seen, &mai, NULL, &mem);
    if (rc != 0 || mem == NULL) {
        MEOWLOGE("meowvulkan: F53 intermediate: vkAllocateMemory rc=%{public}d; forwarding original", rc);
        meow_f53_destroy_partial(lin, ab, NULL);
        return 0;
    }
    rc = realBindImageMemory(g_dev_seen, lin, mem, 0);
    if (rc != 0) {
        MEOWLOGE("meowvulkan: F53 intermediate: vkBindImageMemory rc=%{public}d; forwarding original", rc);
        meow_f53_destroy_partial(lin, ab, mem);
        return 0;
    }
    rc = realBindBufferMemory(g_dev_seen, ab, mem, 0);
    if (rc != 0) {
        MEOWLOGE("meowvulkan: F53 intermediate: vkBindBufferMemory(alias) rc=%{public}d; forwarding original", rc);
        meow_f53_destroy_partial(lin, ab, mem);
        return 0;
    }
    e->linImage = lin;
    e->aliasBuffer = ab;
    e->linMem = mem;
    e->interMip = e->mipLevels;
    e->interLayers = e->arrayLayers;
    e->interGeneral = 0;
    e->interState = 1;
    // F55 (shim build .35): per-image success line -> rate-limit. First 8 individually (path proof),
    // then one summary every 500; MEOW_VK_VERBOSE=1 restores every line. static = single-thread
    // assumption for the render thread (noted in F55). F53 failure paths are MEOWLOGE above and stay.
    {
        static unsigned long s_f53_inter_ready = 0;
        ++s_f53_inter_ready;
        if (meow_vk_verbose() || s_f53_inter_ready <= 8ul) {
            MEOWLOGI("meowvulkan: F53 intermediate ready target=%{public}p lin=%{public}p alias=%{public}p "
                     "mem=%{public}p format=%{public}u extent=%{public}ux%{public}ux%{public}u mips=%{public}u "
                     "layers=%{public}u samples=%{public}u memType=%{public}d bytes=%{public}llu",
                     e->image, lin, ab, mem, e->format, e->width, e->height, e->depth, e->mipLevels,
                     e->arrayLayers, e->samples, mt, (unsigned long long)bytes);
        } else if ((s_f53_inter_ready % 20000ul) == 0ul) {
            MEOWLOGI("meowvulkan: F53 intermediate ready summary: total=%{public}lu format=%{public}u "
                     "extent=%{public}ux%{public}ux%{public}u memType=%{public}d bytes=%{public}llu",
                     s_f53_inter_ready, e->format, e->width, e->height, e->depth, mt,
                     (unsigned long long)bytes);
        }
    }
    return 1;
}

static void meow_f53_record_destroyed(void* img) {
    if (img == NULL) return;
    void* lin = NULL;
    void* ab = NULL;
    void* mem = NULL;
    pthread_mutex_lock(&g_meow_f53_img_lock);
    meow_f53_info_drop_locked(img);   /* F61: drop the staged create-info if it was never promoted */
    int idx = meow_f53_lookup_locked(img);
    if (idx >= 0) {
        lin = g_meow_f53_imgs[idx].linImage;
        ab = g_meow_f53_imgs[idx].aliasBuffer;
        mem = g_meow_f53_imgs[idx].linMem;
        meow_f53_release_locked(idx);   /* keeps the free-list link intact (no memset) */
    }
    pthread_mutex_unlock(&g_meow_f53_img_lock);
    if (lin != NULL || ab != NULL || mem != NULL) {
        meow_f53_destroy_partial(lin, ab, mem);
    }
}

// Returns 1 when the call was fully translated (the caller must NOT forward the original),
// 0 when it must forward unchanged.
static int meow_f53_redirect_copy(void* cmd, void* src, void* dst, uint32_t dstLayout,
                                  uint32_t regionCount, const void* pRegions) {
    const char* why = NULL;
    if (!meow_f53_decide(&why)) return 0;
    if (cmd == NULL || src == NULL || dst == NULL || pRegions == NULL) return 0;
    if (regionCount == 0 || regionCount > 4096) return 0;
    int idx = meow_f53_find(dst);
    if (idx < 0) idx = meow_f53_register_target(dst);   /* F61: lazy registration on first use */
    if (idx < 0) {
        if (++g_meow_f53_fallbacks <= 16ul)
            MEOWLOGI("meowvulkan: F53 forward dst=%{public}p (not a staged upload target)", dst);
        return 0;
    }
    MeowF53ImgEntry* e = &g_meow_f53_imgs[idx];
    if (e->tiling != MEOW_F53_TILING_OPTIMAL) return 0;
    if (e->samples != 1u) return 0;
    uint32_t bpp = meow_f53_format_bpp(e->format);
    if (bpp == 0) {
        if (++g_meow_f53_fallbacks <= 16ul)
            MEOWLOGI("meowvulkan: F53 forward dst=%{public}p (format=%{public}u not LINEAR-capable uncompressed)",
                     dst, e->format);
        return 0;
    }
    const MeowF53BufferImageCopyL* r = (const MeowF53BufferImageCopyL*)pRegions;
    uint64_t total = 0;
    for (uint32_t i = 0; i < regionCount; i++) {
        if ((r[i].imageSubresource.aspectMask & MEOW_F53_ASPECT_COLOR) == 0u) return 0;
        if (r[i].imageSubresource.layerCount == 0u || r[i].imageExtent.width == 0u ||
            r[i].imageExtent.height == 0u) return 0;
        uint64_t d = r[i].imageExtent.depth ? r[i].imageExtent.depth : 1u;
        total += (uint64_t)r[i].imageSubresource.layerCount * d * r[i].imageExtent.height;
        if (total > MEOW_F53_MAX_BUFFER_COPIES) {
            if (++g_meow_f53_fallbacks <= 16ul)
                MEOWLOGI("meowvulkan: F53 forward dst=%{public}p (row count %{public}llu > cap)",
                         dst, (unsigned long long)total);
            return 0;
        }
    }
    if (total == 0) return 0;
    if (!meow_f53_ensure_intermediate(e)) return 0;
    MeowF53PFN_getImageLayout realGetLayout =
        (MeowF53PFN_getImageLayout)meow_f53_sym("vkGetImageSubresourceLayout");
    MeowF53PFN_cmdCopyBuffer realCopyBuffer = (MeowF53PFN_cmdCopyBuffer)meow_f53_sym("vkCmdCopyBuffer");
    MeowF53PFN_cmdCopyImage realCopyImage = (MeowF53PFN_cmdCopyImage)meow_f53_sym("vkCmdCopyImage");
    MeowF53PFN_cmdPipelineBarrier realBarrier =
        (MeowF53PFN_cmdPipelineBarrier)meow_f53_sym("vkCmdPipelineBarrier");
    if (realGetLayout == NULL || realCopyBuffer == NULL || realCopyImage == NULL || realBarrier == NULL) {
        MEOWLOGE("meowvulkan: F53 a transfer entry point is unresolved; forwarding original");
        meow_f53_destroy_partial(e->linImage, e->aliasBuffer, e->linMem);
        e->linImage = e->aliasBuffer = e->linMem = NULL;
        e->interState = 2;
        return 0;
    }
    MeowF53BufferCopyL* bcs = (MeowF53BufferCopyL*)calloc((size_t)total, sizeof(MeowF53BufferCopyL));
    MeowF53ImageCopyL* ics = (MeowF53ImageCopyL*)calloc(regionCount, sizeof(MeowF53ImageCopyL));
    if (bcs == NULL || ics == NULL) {
        free(bcs);
        free(ics);
        MEOWLOGE("meowvulkan: F53 out of memory building copy lists; forwarding original");
        return 0;
    }
    uint64_t n = 0;
    for (uint32_t i = 0; i < regionCount; i++) {
        const MeowF53BufferImageCopyL* q = &r[i];
        uint32_t extW = q->imageExtent.width;
        uint32_t extH = q->imageExtent.height;
        uint32_t extD = q->imageExtent.depth ? q->imageExtent.depth : 1u;
        uint64_t srcRowStride = (uint64_t)(q->bufferRowLength ? q->bufferRowLength : extW) * bpp;
        uint64_t srcPlaneStride = (uint64_t)(q->bufferImageHeight ? q->bufferImageHeight : extH) * srcRowStride;
        for (uint32_t L = 0; L < q->imageSubresource.layerCount; L++) {
            MeowF53ImageSubresourceL sub;
            MeowF53SubresourceLayoutL lay;
            memset(&lay, 0, sizeof(lay));
            sub.aspectMask = q->imageSubresource.aspectMask;
            sub.mipLevel = q->imageSubresource.mipLevel;
            sub.arrayLayer = q->imageSubresource.baseArrayLayer + L;
            realGetLayout(g_dev_seen, e->linImage, &sub, &lay);
            for (uint32_t z = 0; z < extD; z++) {
                uint64_t planeIndex = (uint64_t)L * extD + z;
                uint64_t srcPlane = planeIndex * srcPlaneStride;
                for (uint32_t y = 0; y < extH; y++) {
                    bcs[n].srcOffset = q->bufferOffset + srcPlane + (uint64_t)y * srcRowStride;
                    bcs[n].dstOffset = lay.offset
                        + ((uint64_t)(q->imageOffset.y + (int32_t)y)) * lay.rowPitch
                        + (uint64_t)q->imageOffset.x * bpp
                        + (uint64_t)(q->imageOffset.z + (int32_t)z) * lay.depthPitch;
                    bcs[n].size = (uint64_t)extW * bpp;
                    n++;
                }
            }
        }
        MeowF53ImageCopyL* ic = &ics[i];
        memset(ic, 0, sizeof(*ic));
        ic->srcSubresource.aspectMask = q->imageSubresource.aspectMask;
        ic->srcSubresource.mipLevel = q->imageSubresource.mipLevel;
        ic->srcSubresource.baseArrayLayer = q->imageSubresource.baseArrayLayer;
        ic->srcSubresource.layerCount = q->imageSubresource.layerCount;
        ic->dstSubresource.aspectMask = q->imageSubresource.aspectMask;
        ic->dstSubresource.mipLevel = q->imageSubresource.mipLevel;
        ic->dstSubresource.baseArrayLayer = q->imageSubresource.baseArrayLayer;
        ic->dstSubresource.layerCount = q->imageSubresource.layerCount;
        ic->dstOffset.x = q->imageOffset.x;
        ic->dstOffset.y = q->imageOffset.y;
        ic->dstOffset.z = q->imageOffset.z;
        ic->extent.width = extW;
        ic->extent.height = extH;
        ic->extent.depth = extD;
    }
    if (!e->interGeneral) {
        MeowF53ImageBarrierL ib;
        memset(&ib, 0, sizeof(ib));
        ib.sType = MEOW_F53_ST_IMAGE_MEMORY_BARRIER;
        ib.srcAccessMask = 0u;
        ib.dstAccessMask = MEOW_F53_ACCESS_TRANSFER_READ | MEOW_F53_ACCESS_TRANSFER_WRITE;
        ib.oldLayout = MEOW_F53_LAYOUT_UNDEFINED;
        ib.newLayout = MEOW_F53_LAYOUT_GENERAL;
        ib.srcQueueFamilyIndex = MEOW_F53_QF_IGNORED;
        ib.dstQueueFamilyIndex = MEOW_F53_QF_IGNORED;
        ib.image = e->linImage;
        ib.subresourceRange.aspectMask = MEOW_F53_ASPECT_COLOR;
        ib.subresourceRange.baseMipLevel = 0u;
        ib.subresourceRange.levelCount = e->interMip;
        ib.subresourceRange.baseArrayLayer = 0u;
        ib.subresourceRange.layerCount = e->interLayers;
        realBarrier(cmd, MEOW_F53_STAGE_TOP_OF_PIPE, MEOW_F53_STAGE_TRANSFER, 0u,
                    0u, NULL, 0u, NULL, 1u, &ib);
        e->interGeneral = 1;
    } else {
        MeowF53MemoryBarrierL mb;
        memset(&mb, 0, sizeof(mb));
        mb.sType = MEOW_F53_ST_MEMORY_BARRIER;
        mb.srcAccessMask = MEOW_F53_ACCESS_TRANSFER_READ;
        mb.dstAccessMask = MEOW_F53_ACCESS_TRANSFER_WRITE;
        realBarrier(cmd, MEOW_F53_STAGE_TRANSFER, MEOW_F53_STAGE_TRANSFER, 0u,
                    1u, &mb, 0u, NULL, 0u, NULL);
    }
    realCopyBuffer(cmd, src, e->aliasBuffer, (uint32_t)n, bcs);
    {
        MeowF53MemoryBarrierL mb;
        memset(&mb, 0, sizeof(mb));
        mb.sType = MEOW_F53_ST_MEMORY_BARRIER;
        mb.srcAccessMask = MEOW_F53_ACCESS_TRANSFER_WRITE;
        mb.dstAccessMask = MEOW_F53_ACCESS_TRANSFER_READ;
        realBarrier(cmd, MEOW_F53_STAGE_TRANSFER, MEOW_F53_STAGE_TRANSFER, 0u,
                    1u, &mb, 0u, NULL, 0u, NULL);
    }
    realCopyImage(cmd, e->linImage, MEOW_F53_LAYOUT_GENERAL, dst, dstLayout, regionCount, ics);
    free(bcs);
    free(ics);
    ++g_meow_f53_redirects;
    // F55 (shim build .35): per-upload success line (measured thousands/run, several per frame) ->
    // rate-limit. First 8 individually, then one summary every 500; MEOW_VK_VERBOSE=1 restores all.
    // F53 forward/fallback lines (<=16) stay unconditional; the cache-full WARN is rate-limited since
    // F56 (.36) because it was the 91% flood.
    if (meow_vk_verbose() || g_meow_f53_redirects <= 8ul) {
        MEOWLOGI("meowvulkan: F53 redirect vkCmdCopyBufferToImage dst=%{public}p regions=%{public}u "
                 "bufRegions=%{public}llu bpp=%{public}u lin=%{public}p alias=%{public}p ok=1",
                 dst, regionCount, (unsigned long long)n, bpp, e->linImage, e->aliasBuffer);
    } else if ((g_meow_f53_redirects % 20000ul) == 0ul) {
        MEOWLOGI("meowvulkan: F53 redirect summary: total=%{public}lu dst=%{public}p regions=%{public}u "
                 "bufRegions=%{public}llu bpp=%{public}u",
                 g_meow_f53_redirects, dst, regionCount, (unsigned long long)n, bpp);
    }
    return 1;
}

// ★ BUGFIX 2026-09-17 (shim build .7) -- root cause of the "wandering @0xc" campaign.
// This wrapper used to declare SEVEN parameters: an extra `srcLayout` that does NOT exist in the API
// (v1.0's vkCmdCopyBufferToImage carries no source layout -- that is vkCmdCopyBufferToImage2's job via
// VkCopyBufferToImageInfo2). One invented parameter shifted EVERY argument by one register:
//     driver received  dstImage = <our "srcLayout" value>,  dstImageLayout = <the dst handle>,
//                      regionCount = <the real dstImageLayout>,  pRegions = <the real regionCount>
// so the ICD walked a WILD POINTER as an array of ~3 billion VkBufferImageCopy records. That is a
// textbook DEFERRED memory stomp, and it matches every symptom this campaign chased: the fault lands
// later and elsewhere (JIT'd Java, drifting pc), the heap verifier is clean at safepoints, and it
// happens only on the Vulkan path. The older notes' "known defect: vkCmdCopyBufferToImage dies inside
// the call" was this bug (measured 2026-09-17 22:31: the call RETURNED, and logged the garbage
// "regions=3068047000" that was really the pRegions pointer's low half).
// Signature verified against ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h:4587 --
// the header the CALLER was generated from, not a guessed one.
// RULE for every wrapper in this file: declare exactly the real parameters, in order, and forward that
// same list. Never invent a parameter, not even for logging.
typedef void (*PFN_cmdCopyBufferToImage)(void*, void*, void*, uint32_t, uint32_t, const void*);
// VkBufferImageCopy -- official SDK type (vulkan_core.h:4097); accesses use imageSubresource /
// imageOffset / imageExtent below.
typedef VkBufferImageCopy VkBufImageCopyL;
static void log_CmdCopyBufferToImage(void* cmd, void* src, void* dst, uint32_t dstLayout,
                                     uint32_t regionCount, const void* pRegions) {
    if (meow_vk_verbose()) {
        if (regionCount > 0 && regionCount < 4096 && pRegions != NULL) {
            const VkBufImageCopyL* r0 = (const VkBufImageCopyL*)pRegions;
            MEOWLOGI("meowvulkan: vkCmdCopyBufferToImage CALLED cmdBuf=%{public}p (regions=%{public}u) r0{bufOff=%{public}llu "
                     "mip=%{public}u layers=%{public}u..+%{public}u off=%{public}d,%{public}d,%{public}d "
                     "ext=%{public}u x %{public}u x %{public}u} -- forwarding",
                     cmd, regionCount, (unsigned long long)r0->bufferOffset, r0->imageSubresource.mipLevel,
                     r0->imageSubresource.baseArrayLayer, r0->imageSubresource.layerCount,
                     r0->imageOffset.x, r0->imageOffset.y, r0->imageOffset.z,
                     r0->imageExtent.width, r0->imageExtent.height, r0->imageExtent.depth);
        } else {
            MEOWLOGI("meowvulkan: vkCmdCopyBufferToImage CALLED cmdBuf=%{public}p (regions=%{public}u) -- forwarding",
                     cmd, regionCount);
        }
    }
    // F53: when enabled, the buffer->image upload is rewritten as
    // vkCmdCopyBuffer(src -> alias) + vkCmdCopyImage(linear -> dst) and the original is NOT
    // recorded (it is the call whose submit the ICD rejects).
    if (meow_f53_redirect_copy(cmd, src, dst, dstLayout, regionCount, pRegions)) {
        if (meow_vk_verbose())
            MEOWLOGI("meowvulkan: vkCmdCopyBufferToImage NOT recorded (F53 redirect active)");
        return;
    }
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdCopyBufferToImage, &meow_d_vkCmdCopyBufferToImage, "vkCmdCopyBufferToImage");
    if (real != NULL) {
        ((PFN_cmdCopyBufferToImage)real)(cmd, src, dst, dstLayout, regionCount, pRegions);
        if (meow_vk_verbose())
            MEOWLOGI("meowvulkan: vkCmdCopyBufferToImage returned (this line means it did NOT crash)");
    } else {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdCopyBufferToImage");
    }
}

// F54/F68: diagnostic log wrappers around the descriptor-push and shader-module calls. Per-call
// detail is gated behind MEOW_VK_VERBOSE (Tier B, default OFF); the wrappers themselves are the
// forwarding mechanism and stay. History: the crash dumper's own record never survived the OS signal
// chain, so logging right before/after the suspect call was how each failure was located.
typedef void (*PFN_cmdPush)(void*, uint32_t, void*, uint32_t, uint32_t, const void*);
// F72 (shim build .49) forward declarations: the implementation lives with the F69 helpers further
// down (it reuses meow_f69_createFence/getFenceStatus), but the push wrapper above needs the on/off
// decision and the emulation entry point now.
static int meow_f72_on(void);
static int meow_f72_emulate_push(void* cmd, uint32_t bindPoint, void* layout, uint32_t set,
                                 uint32_t n, const void* writes);
static void meow_f72_bind_submit(VkFence submitFence, int ownsFence, int ok);
// F91: returns the fence to hand to this submit and sets *ownsFence when the shim had to create it
// (no caller fence and no F69 fence) so the frame's pools can be reclaimed. Defined with the pool code.
static VkFence meow_f72_fence_for_submit(VkFence submitFence, int* ownsFence);
// F68 (shim build .44): causal test switch for the push-descriptor defect.
// WHY: the first successful MC Vulkan frame (shim .43, F66 merge) had its ONE merged submit accepted
// (submitsIn=3 -> submits=1, cmdBufs=4, rc=0) and then the driver's queue recovery fired
// ("Gpu is reset when wait idle" / "RecoverCqError clear qid=19/20" / "return device lost"), i.e. the
// GPU faulted on that submit's CONTENT. The log shows the frame was tiny (1 begin-rendering, 4 draws,
// 8 barriers, 1 copyImage) and its only "never truly tested" content is vkCmdPushDescriptorSet: the
// probe always pushed without a graphics pipeline to CONSUME the descriptors (A8 §3.2: no pipeline, no
// draw, no SPIR-V), while MC pushes into a real pipeline. The campaign's third known blocker is exactly
// "vkCmdPushDescriptorSet consumed by a pipeline => device lost". Dropping the pushes makes the picture
// wrong but removes the suspect: if the device NO LONGER gets lost, the push path is confirmed as the
// trigger and the designed remedy (emulate the push with an ordinary descriptor set) is the fix.
// MEOW_VK_DROP_PUSH_DESCRIPTOR=1 opts in; unset = forward exactly as before.
// F87 (.65): the env is read lazily ONCE and cached (same policy as g_hooks: first use wins). The
// decision itself is unchanged; only the number of getenv() calls changed (was once per push).
static int meow_vk_drop_push(void) {
    static int s_drop = -1;
    if (s_drop < 0) {
        const char* s = getenv("MEOW_VK_DROP_PUSH_DESCRIPTOR");
        s_drop = (s != NULL && s[0] == '1') ? 1 : 0;
    }
    return s_drop;
}

// F70 (shim build .46): causal test switch for the REAL graphics-pipeline path.
// WHY: with F66 (merge) + F69 (timeline->fence) MC's Vulkan frame is now accepted and its completion
// is a real GPU fence wait, and the whole system no longer janks (no fake host-side advances) -- but
// the driver still runs its queue recovery ("Gpu is reset when wait idle" / "RecoverCqError clear
// qid=19/20" / "return device lost") on MC's real first frame. That frame is tiny (1 begin-rendering,
// 4 draws, 8 translated barriers, 1 copyImage; the two push-descriptor calls were already cleared by
// F68, which failed the same way). What has NEVER been exercised on this ICD is real graphics-pipeline
// execution: the probe had no graphics pipeline, no SPIR-V and no draws (A8 3.2), and the campaign's
// "render-to-image works" result used a clear, not a pipeline. Dropping the draws removes exactly that
// (a render pass with zero draws is legal), so if the queue error disappears the pipeline/draw path is
// convicted. MEOW_VK_DROP_DRAW=1 opts in; unset = forward exactly as before.
// NOTE: MC draws with vkCmdDrawIndirect/vkCmdDrawIndexedIndirect (A8 3.1), which this shim did NOT
// wrap until now -- the indirect wrappers below exist so the gate can actually cover MC's draws.
static int meow_vk_drop_draw(void) {
    // F92 (.70): called once per draw (indirect draws included). The env read was one getenv() per
    // call; cache it once per process exactly like meow_vk_drop_push (F87). Same decision logic.
    static int s_drop = -1;
    if (s_drop < 0) {
        const char* s = getenv("MEOW_VK_DROP_DRAW");
        s_drop = (s != NULL && s[0] == '1') ? 1 : 0;
    }
    return s_drop;
}

// F71b (.48): rate-limited reporter for the causal-test drop gates. A per-call line on a hot path is
// exactly the mistake the project already banned (F55/F56): the F70 build logged every dropped draw
// and produced a 33,923-line export of which 30,145 lines were ours, which pushed the F71 divisor
// evidence (and even the shim's own build tag) out of the log. First 4 calls are named (path proof),
// then one running-total line every 4000; MEOW_VK_VERBOSE=1 restores every call.
static void meow_log_drop(const char* what) {
    static unsigned long total = 0;
    ++total;
    if (meow_vk_verbose() || total <= 4ul) {
        MEOWLOGW("meowvulkan: %{public}s DROPPED (causal test, not forwarded) -- #%{public}lu",
                 what, total);
    } else if ((total % 20000ul) == 0ul) {
        MEOWLOGW("meowvulkan: causal-test drops so far: %{public}lu (rate-limited; "
                 "MEOW_VK_VERBOSE=1 shows every call)", total);
    }
}

// F91 (.69): thread-identity proof, reusing the EXISTING MEOW_VK_VERBOSE gate (no new env). Each
// selected hot wrapper calls this with its own one-shot flag on its FIRST invocation; under verbose it
// prints gettid() exactly once per wrapper (a handful of lines in total, never per call). If a single
// run shows one tid for all wrappers, the shim's "single render thread" contract (A10 G5) holds and
// the F87/M1 races are theoretical; more than one tid promotes them. `seen` is the caller's static.
static void meow_log_thread_once(unsigned char* seen, const char* what) {
    if (*seen || !meow_vk_verbose()) return;
    *seen = 1;
    MEOWLOGI("meowvulkan: F91 thread probe %{public}s gettid=%{public}ld (first call; one line per wrapper)",
             what, (long)gettid());
}

static void log_CmdPushDescriptorSet(void* cmd, uint32_t bindPoint, void* layout, uint32_t set,
                                     uint32_t n, const void* writes) {
    static unsigned char s_tp_push;
    meow_log_thread_once(&s_tp_push, "vkCmdPushDescriptorSet");
    if (meow_vk_drop_push()) {
        // F68: never forwarded -- the causal test. Logged once per call (bounded: the causal run is short).
        meow_log_drop("vkCmdPushDescriptorSet");   // F71b: rate-limited
        return;
    }
    // F72 (build .49): DROP has priority over AS_SET. When the emulation succeeds the real push is
    // never recorded; every failure path falls through to the original forward below (the emulator
    // emits a rate-limited WARN saying why).
    if (meow_f72_on() && meow_f72_emulate_push(cmd, bindPoint, layout, set, n, writes)) {
        if (meow_vk_verbose())
            MEOWLOGI("meowvulkan: vkCmdPushDescriptorSet EMULATED as an ordinary descriptor set (F72)");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdPushDescriptorSet CALLED (writes=%{public}u) -- forwarding", n);
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdPushDescriptorSet, &meow_d_vkCmdPushDescriptorSet, "vkCmdPushDescriptorSet");
    if (real != NULL) {
        ((PFN_cmdPush)real)(cmd, bindPoint, layout, set, n, writes);
        if (meow_vk_verbose())
            MEOWLOGI("meowvulkan: vkCmdPushDescriptorSet returned");
    } else {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdPushDescriptorSet");
    }
}

typedef int (*PFN_createSM)(void*, const void*, const void*, void**);
static int log_CreateShaderModule(void* dev, const void* ci, const void* alloc, void** sm) {
    // The vendor shader compiler runs inside this call; it is the known culprit of the GL-path
    // "chain A" crash, so log around it too (F54: per-module pair -> verbose; 180 calls in LOG-A).
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCreateShaderModule CALLED -- forwarding (vendor compiler runs inside)");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkCreateShaderModule") : NULL;
    if (real == NULL) return -3;
    int rc = ((PFN_createSM)real)(dev, ci, alloc, sm);
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCreateShaderModule returned rc=%{public}d", rc);
    return rc;
}

// Tier B diagnostic (default OFF): allocation-boundary wrappers (vkMapMemory / vkAllocateMemory /
// vkCreateBuffer / vkBindBufferMemory / vkGetBufferMemoryRequirements). They pass everything through
// unchanged and only read results back; their log lines are gated behind MEOW_VK_VERBOSE, so the
// default run stays quiet -- set MEOW_VK_VERBOSE=1 to name the last call before a fault.
// ---------------------------------------------------------------- hang watchdog
// Tier B diagnostic: hang watchdog (env MEOW_VK_WD=<seconds>, default OFF).
// WHY: the Vulkan init path can *hang* (black screen) rather than fault: no hs_err, no MC crash
// report, no cppcrash of its own -- and eventually the platform kills the process, which looks like
// a crash from the outside. A hang keeps the JVM healthy, so the cheapest way to learn where it is
// stuck is a *thread dump*.
// HOW: remember the monotonic timestamp of the last observed Vulkan activity; a detached thread
// SIGQUITs this process once that timestamp goes stale. SIGQUIT is the standard thread-dump signal
// and is deliberately NOT a SIGSEGV handler -- hijacking SIGSEGV broke the JVM (see
// stuffs/research/vulkan/vk-m1-evidence/README.md).
// LIMITS: "activity = liveness" only holds for the calls this shim sees, so a long stretch that only
// calls unhooked commands can produce a false positive; the log line names the last call seen and it
// fires at most 3 times.
static volatile long long g_wd_last_ns;
static int  g_wd_armed, g_wd_dumps;
// F87 (.65): g_wd_armed means "wd_maybe_start() already ran" (it is set BEFORE the env check), NOT
// "the watchdog thread is running". g_wd_on is the independent flag that actually means the thread
// started; only wd_maybe_start() sets it, and only after pthread_create succeeds.
static int  g_wd_on;
static char g_wd_last_name[128];

static long long wd_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}
static void wd_note(const char* name) {
    if (!g_wd_on) return;   // F87: watchdog off (the default) -> no clock_gettime/snprintf per call
    g_wd_last_ns = wd_now_ns();
    if (name != NULL) {
        snprintf(g_wd_last_name, sizeof(g_wd_last_name), "%s", name);
    }
}
// wd_touch() is only called from wd_maybe_start() (before the thread starts, so it must write) and
// from vkGetInstanceProcAddr (init only), never from a hot per-call path -> left ungated.
static void wd_touch(void) { g_wd_last_ns = wd_now_ns(); }

static void* wd_thread(void* arg) {
    long long limit = (long long)(intptr_t)arg;
    for (;;) {
        long long now = wd_now_ns();
        if (now - g_wd_last_ns > limit && g_wd_dumps < 3) {
            g_wd_dumps++;
            MEOWLOGE("meowvulkan: WATCHDOG: no Vulkan activity for %{public}d s (last seen: %{public}s)"
                     " -> SIGQUIT so HotSpot prints a thread dump (#%{public}d)",
                     (int)(limit / 1000000000LL), g_wd_last_name[0] ? g_wd_last_name : "(none)", g_wd_dumps);
            kill(getpid(), SIGQUIT);   // standard thread dump; NOT a SIGSEGV hijack
            g_wd_last_ns = wd_now_ns();
        }
        usleep(500000);
    }
    return NULL;
}
static void wd_maybe_start(void) {
    if (g_wd_armed) return;
    g_wd_armed = 1;
    const char* s = getenv("MEOW_VK_WD");
    if (s == NULL || s[0] == '\0' || (s[0] == '0' && s[1] == '\0')) return;   // default OFF
    int secs = atoi(s);
    if (secs <= 0) secs = 15;
    wd_touch();
    pthread_t t;
    if (pthread_create(&t, NULL, wd_thread, (void*)(intptr_t)((long long)secs * 1000000000LL)) == 0) {
        pthread_detach(t);
        g_wd_on = 1;   // F87: the thread exists only from here; wd_note() may now write
        MEOWLOGI("meowvulkan: watchdog armed: %{public}d s without any Vulkan activity -> SIGQUIT + thread dump", secs);
    } else {
        MEOWLOGE("meowvulkan: watchdog could not start (pthread_create failed)");
    }
}

typedef int (*PFN_mapMemory)(void*, void*, uint64_t, uint64_t, uint32_t, void**);
static int log_MapMemory(void* dev, void* mem, uint64_t off, uint64_t size, uint32_t flags, void** pp) {
    wd_note("vkMapMemory");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkMapMemory") : NULL;
    if (real == NULL) return -3;
    int rc = ((PFN_mapMemory)real)(dev, mem, off, size, flags, pp);
    void* got = (pp != NULL) ? *pp : NULL;
    // Tier B: per-call result line -> verbose gate (default OFF).
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkMapMemory rc=%{public}d size=%{public}llu ptr=%{public}p", rc,
                 (unsigned long long)size, got);
    return rc;
}

typedef int (*PFN_allocMemory)(void*, const void*, const void*, void**);
/* VkMemoryAllocateInfo: sType(0) pNext(8) allocationSize(16) memoryTypeIndex(24) -- read-only inspection,
 * the call itself is unchanged. The first allocation is where the process dies (deterministically, right
 * after this line), so its size/type are the numbers we are missing. */
typedef VkMemoryAllocateInfo VkMemAI;   // official SDK type (vulkan_core.h)
static int log_AllocateMemory(void* dev, const void* ai, const void* alloc, void** mem) {
    wd_note("vkAllocateMemory");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkAllocateMemory") : NULL;
    if (real == NULL) return -3;
    const VkMemAI* info = (const VkMemAI*)ai;
    uint32_t pnext_st = 0;
    if (info != NULL && info->pNext != NULL) {
        pnext_st = *(const uint32_t*)info->pNext;
    }
    int rc = ((PFN_allocMemory)real)(dev, ai, alloc, mem);
    // Tier B: per-call result line -> verbose gate (default OFF).
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkAllocateMemory rc=%{public}d mem=%{public}p size=%{public}llu type=%{public}u pNext_sType=%{public}u",
                 rc, (mem != NULL) ? *mem : NULL,
                 (unsigned long long)((info != NULL) ? info->allocationSize : 0ULL),
                 (unsigned)((info != NULL) ? info->memoryTypeIndex : 0U), pnext_st);
    return rc;
}

/* VkBufferCreateInfo: sType(0) pNext(8) flags(16) size(24) usage(32) -- the buffer sizes MC asks for
 * right after that allocation tell us what the Vulkan backend was setting up when it died. */
typedef VkBufferCreateInfo VkBufCI;   // official SDK type (vulkan_core.h)
typedef int (*PFN_createBuffer)(void*, const void*, const void*, void**);
static int log_CreateBuffer(void* dev, const void* ci, const void* alloc, void** buf) {
    wd_note("vkCreateBuffer");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkCreateBuffer") : NULL;
    if (real == NULL) return -3;
    const VkBufCI* info = (const VkBufCI*)ci;
    int rc = ((PFN_createBuffer)real)(dev, ci, alloc, buf);
    // F55 (shim build .35): per-object result line (measured ~101+ callers/frame during uploads) ->
    // diagnostic gate. vkCreateBuffer is a hot creation path; verbose restores the line.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCreateBuffer rc=%{public}d buf=%{public}p size=%{public}llu usage=0x%{public}x",
                 rc, (buf != NULL) ? *buf : NULL,
                 (unsigned long long)((info != NULL) ? info->size : 0ULL),
                 (unsigned)((info != NULL) ? info->usage : 0U));
    return rc;
}

typedef int (*PFN_bindBufMemory)(void*, void*, void*, uint64_t);
static int log_BindBufferMemory(void* dev, void* buf, void* mem, uint64_t off) {
    wd_note("vkBindBufferMemory");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkBindBufferMemory") : NULL;
    if (real == NULL) return -3;
    int rc = ((PFN_bindBufMemory)real)(dev, buf, mem, off);
    // F55 (shim build .35): per-object result line (paired with every vkCreateBuffer) -> verbose gate.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkBindBufferMemory rc=%{public}d buf=%{public}p mem=%{public}p off=%{public}llu", rc,
                 buf, mem, (unsigned long long)off);
    return rc;
}

// Tier B diagnostic (default OFF): measurement-gap wrappers for the buffer-memory calls VMA makes
// next (vkGetBufferMemoryRequirements / vkBindBufferMemory). They only log (entry + result) and
// forward unchanged; the line is gated behind MEOW_VK_VERBOSE, so the default run stays quiet.
typedef void (*PFN_gbmr)(void*, void*, void*);
static void log_GetBufferMemoryRequirements(void* dev, void* buf, void* out) {
    wd_note("vkGetBufferMemoryRequirements");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkGetBufferMemoryRequirements") : NULL;
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetBufferMemoryRequirements");
        return;
    }
    ((PFN_gbmr)real)(dev, buf, out);
    unsigned long long sz = (out != NULL) ? *(unsigned long long*)out : 0ULL;   // VkMemoryRequirements.size
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkGetBufferMemoryRequirements buf=%{public}p need=%{public}llu", buf, sz);
}

typedef int (*PFN_createImage)(void*, const void*, const void*, void**);
static int log_CreateImage(void* dev, const void* ci, const void* alloc, void** img) {
    wd_note("vkCreateImage");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkCreateImage") : NULL;
    if (real == NULL) return -3;
    int rc = ((PFN_createImage)real)(dev, ci, alloc, img);
    // F55 (shim build .35): per-object result line (measured 3758/run during texture upload) -> verbose
    // gate. The F53 record below still runs regardless: only the LOG line is gated.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCreateImage rc=%{public}d img=%{public}p", rc, (img != NULL) ? *img : NULL);
    if (rc == VK_SUCCESS && img != NULL && *img != NULL) {
        meow_f53_stage_created(*img, ci);   /* F61: stash only; promoted lazily if uploaded */
    }
    return rc;
}

// F53: drop the per-image cache slot and free the LINEAR intermediate (image + alias buffer +
// memory) that may have been created for it. The app's own image destroy still forwards.
typedef void (*PFN_destroyImage)(void*, void*, const void*);
static void log_DestroyImage(void* dev, void* img, const void* alloc) {
    wd_note("vkDestroyImage");
    meow_f53_record_destroyed(img);
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkDestroyImage") : NULL;
    if (real != NULL) {
        ((PFN_destroyImage)real)(dev, img, alloc);
    } else {
        MEOWLOGE("meowvulkan: cannot resolve the real vkDestroyImage");
    }
}

typedef int (*PFN_flushMapped)(void*, uint32_t, const void*);
static int log_FlushMappedMemoryRanges(void* dev, uint32_t count, const void* ranges) {
    wd_note("vkFlushMappedMemoryRanges");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkFlushMappedMemoryRanges") : NULL;
    if (real == NULL) return -3;
    int rc = ((PFN_flushMapped)real)(dev, count, ranges);
    // Tier B: per-call result line -> verbose gate (default OFF).
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkFlushMappedMemoryRanges rc=%{public}d count=%{public}u", rc, (unsigned)count);
    return rc;
}

typedef int (*PFN_queueSubmit)(void*, uint32_t, const void*, void*);
static int log_QueueSubmit(void* queue, uint32_t count, const void* submits, void* fence) {
    static unsigned char s_tp_submit;
    meow_log_thread_once(&s_tp_submit, "vkQueueSubmit");
    wd_note("vkQueueSubmit");
    g_meow_last_queue = queue;   /* F60: write-only cache for the real wait */
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkQueueSubmit, &meow_d_vkQueueSubmit, "vkQueueSubmit");
    if (real == NULL) return -3;
    // F72 (build .49) / F91: cover the pool that recorded the frame with this submit's fence. If MC
    // handed no fence, create a shim-owned tracking fence FIRST and hand it to the submit (review A40
    // F-02/F-08: the old code bound ownsFence=0, so a fence==0 submit pinned its pools forever and the
    // cap path degraded to the real push).
    // F96 (.74 bind-merged-submit): a vkQueueSubmit's ONE VkFence covers the ENTIRE batch -- every
    // VkSubmitInfo entry in pSubmits signals it (Vulkan spec: the fence signals once all submissions
    // complete), so there is no reason to require count==1. The old `count == 1` gate meant a real
    // multi-entry submit (count>=2) never registered the frame's pools -> they stayed non-pending and
    // could neither be recycled nor reused (the "stranded pool" that grows one new pool per 256 push).
    // Register for ANY non-empty batch, exactly once, with the batch's single fence.
    VkFence sf = (VkFence)(uintptr_t)fence;
    int ownsFence = 0;
    if (meow_f72_on() && count >= 1) sf = meow_f72_fence_for_submit(sf, &ownsFence);
    int rc = ((PFN_queueSubmit)real)(queue, count, submits, (void*)sf);
    if (meow_f72_on() && count >= 1) meow_f72_bind_submit(sf, ownsFence, (rc == 0));
    // Tier B: per-call result line -> verbose gate (default OFF).
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkQueueSubmit rc=%{public}d count=%{public}u", rc, (unsigned)count);
    return rc;
}

// vkQueueSubmit2: the submit the Vulkan backend actually uses. MC enables VK_KHR_synchronization2, so
// the real submit goes through vkQueueSubmit2; this wrapper mirrors the vkQueueSubmit bookkeeping for it.
//
// SIGNATURES COPIED VERBATIM from ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h:
//   :7971  typedef VkResult (VKAPI_PTR *PFN_vkQueueSubmit2)(VkQueue queue, uint32_t submitCount,
//                                                              const VkSubmitInfo2* pSubmits, VkFence fence);
//   :7022  typedef VkResult (VKAPI_PTR *PFN_vkWaitSemaphores)(VkDevice device,
//                                                              const VkSemaphoreWaitInfo* pWaitInfo, uint64_t timeout);
//   :7021  typedef VkResult (VKAPI_PTR *PFN_vkGetSemaphoreCounterValue)(VkDevice device,
//                                                              VkSemaphore semaphore, uint64_t* pValue);
// KHR aliases also exist in the same header (:12436 vkQueueSubmit2KHR, :11671 vkWaitSemaphoresKHR,
// :11670 vkGetSemaphoreCounterValueKHR) with identical parameter lists, so both spellings are
// registered below to the same wrapper.
//
// STRUCT LAYOUTS, LP64, copied from the same header and machine-checked with _Static_assert against it
// (VkSemaphoreSubmitInfo@7581, VkCommandBufferSubmitInfo@7590, VkSubmitInfo2@7597, VkSemaphoreWaitInfo@6674):
//   VkSemaphoreSubmitInfo      : sType@0 pNext@8 semaphore@16 value@24 stageMask@32 deviceIndex@40 (size 48)
//   VkCommandBufferSubmitInfo  : sType@0 pNext@8 commandBuffer@16 deviceMask@24 (size 32)
//   VkSubmitInfo2              : sType@0 pNext@8 flags@16 waitCount@20 pWaits@24 cmdCount@32 pCmdBufs@40
//                                signalCount@48 pSignals@56 (size 64)
//   VkSemaphoreWaitInfo        : sType@0 pNext@8 flags@16 semaphoreCount@20 pSemaphores@24 pValues@32 (size 40)
// Semaphores are NON-dispatchable handles => uint64_t on LP64 (NOT void*). VkQueue/VkDevice/VkCommandBuffer
// are dispatchable => pointers.
// Official synchronization2 submit types (vulkan_core.h:7218/7227/7234/6611). VkSemaphore is a
// non-dispatchable handle, so the translation buffers below are typed VkSemaphore/VkCommandBuffer
// (not the former uint64_t/void* mirrors).
typedef VkSemaphoreSubmitInfo       VkSemaphoreSubmitInfoL;
typedef VkCommandBufferSubmitInfo   VkCommandBufferSubmitInfoL;
typedef VkSubmitInfo2               VkSubmitInfo2L;
typedef VkSemaphoreWaitInfo         VkSemaphoreWaitInfoL;

// =====================================================================================
// F44 (shim build .26): synchronization2 -> core-1.0 translation.
//
// WHY: the on-device A10 G1/G2 evidence (F33/F39/F43) is unambiguous -- this ICD's
// synchronization2 path is unusable. F33: sync2 barrier + v1 vkQueueSubmit => OK.
// F39: v1 barrier + vkQueueSubmit2 => OK. F43: sync2 barrier + vkQueueSubmit2 =>
// every cell "FAIL frame 0 rc=-1". The two sync2 entry points each work only when the
// OTHER one is v1; using both together dies on the very first submit.
//
// WHAT: when MEOW_VK_SYNC2_TO_V1 is on (DEFAULT: on whenever the hooks are on, exactly
// like the F36 strip), this shim TRANSLATES the two synchronization2 entry points into
// their core-1.0 equivalents before forwarding to the ICD:
//   vkQueueSubmit2        -> vkQueueSubmit        (VkSubmitInfo2 -> VkSubmitInfo)
//   vkCmdPipelineBarrier2 -> vkCmdPipelineBarrier (VkDependencyInfo -> v1 barriers)
// Timeline semaphore VALUES are NOT dropped: the translated VkSubmitInfo chains a
// VkTimelineSemaphoreSubmitInfo (header :6665) carrying the per-wait/per-signal values.
// MEOW_VK_SYNC2_TO_V1=0 forces the translation OFF (A/B control, the F43 baseline); the
// existing vkQueueSubmit2 / vkCmdPipelineBarrier2 CALLED logs run in BOTH modes.
//
// Stage/access masks are 64-bit (VkPipelineStageFlags2 / VkAccessFlags2) in v2 but 32-bit
// in v1. The tables below are bit-for-bit from vulkan_core.h (stage v1 :2916, stage v2
// :7140, access v1 :3098, access v2 :7226). Bits 0..16 are numerically identical; the
// v2-only bits (COPY/RESOLVE/BLIT/CLEAR + SHADER_SAMPLED/STORAGE access) have no v1
// spelling and are folded conservatively (stage -> ALL_COMMANDS, access -> MEMORY_R|W).
// =====================================================================================
// F45 (shim build .27): the translation itself already lived here and was correctly wired for
// BOTH entry points; this round makes a non-translation SELF-EXPLANATORY and closes two ways a
// caller could have slipped past it:
//   * every wrapper logs a "NOT translating ... reason=<env/hooks>" line when it forwards;
//   * the zero-submit fast path emits the same "SYNC2->V1 translate ..." proof line as the rest;
//   * map_name() folds vkQueueSubmit2KHR / vkCmdPipelineBarrier2KHR onto the core names;
//   * vkGetInstanceProcAddr now also serves these two device commands (the F18 DebugUtils-label
//     precedent), so a resolver that uses the instance path cannot bypass the translation.
// The long per-build prose that used to be appended to the version banner was moved to
// stuffs/research/vulkan/fixes/F45-submit-translation-fix-and-short-version.md.
// =====================================================================================
#define ST_SUBMIT_INFO                    VK_STRUCTURE_TYPE_SUBMIT_INFO
#define ST_BUFFER_MEMORY_BARRIER          VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
#define ST_IMAGE_MEMORY_BARRIER           VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
#define ST_MEMORY_BARRIER                 VK_STRUCTURE_TYPE_MEMORY_BARRIER
#define ST_TIMELINE_SEMAPHORE_SUBMIT_INFO VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO

static unsigned long g_sync2v1_submits;
static unsigned long g_sync2v1_barriers;

// F58 (shim build .38): submit-interval probe. Evidence: a vkQueueSubmit2 whose previous
// vkQueueSubmit2 was >= ~985 ms earlier returns rc=-4, while <= ~52 ms returns rc=0 (.37 run,
// 16/16 submits, zero counterexamples). Measure the monotonic gap HERE so "max submit interval"
// can be read straight off the log with no host-side tooling. Single render thread writer.
static long long g_meow_prev_submit_ns;
static long long g_meow_max_gap_ms;

// Default follows the hooks (`g_hooks ? 1 : 0`); explicit =0 / =1 wins.
// Deliberately NOT cached: the F44 probe matrix toggles this switch PER CELL inside one
// process (cells 1..7 =0, cell 8 =1), so the value must be re-read on every call.
//
// F45: the decision and its human-readable reason live in ONE place. When a wrapper does NOT
// translate it now prints exactly WHY (raw env value vs. hooks default) on its own line. The
// F44 device log showed a submit line ending in "-- forwarding" with no explanation, which is
// what made it look like the submit branch was missing. The decision logic is UNCHANGED.
//
// F75 env-cleanup (2026-09-18): the F47 split switches MEOW_VK_SYNC2_TO_V1_BARRIER / _SUBMIT were
// removed; the barrier and submit translations now share this single decision (legacy
// MEOW_VK_SYNC2_TO_V1, defaulting to the hooks state).
static int meow_sync2_to_v1_decide(const char** why) {
    // F97 (.75, residual-percall-2): env read lazily ONCE and cached (same policy as g_hooks and
    // meow_f72_decide). This decide runs on EVERY vkCmdPipelineBarrier2 (dozens/frame, :4043) and
    // every vkQueueSubmit2 (1/frame, :3403), so the per-call getenv+strcmp was pure overhead. The
    // decision logic and every `why` string are byte-for-byte unchanged; only the getenv() count
    // dropped from one per call to one per process. g_hooks is resolved once by init_once() before
    // any wrapper runs, so caching the branch is equivalent.
    static int s_decided = -1;
    static const char* s_why = NULL;
    if (s_decided < 0) {
        const char* s = getenv("MEOW_VK_SYNC2_TO_V1");
        if (s != NULL && strcmp(s, "0") == 0) {
            s_decided = 0;                            /* explicit off (F43 baseline reproduction) */
            s_why = "explicit OFF (MEOW_VK_SYNC2_TO_V1=0)";
        } else if (s != NULL && s[0] == '1') {
            s_decided = 1;                            /* explicit on */
            s_why = "explicit ON (MEOW_VK_SYNC2_TO_V1=1)";
        } else {
            s_decided = g_hooks ? 1 : 0;              /* default follows the hooks */
            s_why = g_hooks ? "default ON (hooks on, env unset)"
                            : "default OFF (hooks off, env unset)";
        }
    }
    if (why != NULL) *why = s_why;
    return s_decided;
}
static int meow_vk_sync2_to_v1(void) { return meow_sync2_to_v1_decide(NULL); }

// F75 env-cleanup (2026-09-18): the F50 host-side timeline signal (MEOW_VK_TIMELINE_HOST_SIGNAL) was
// removed. F60 had already proven it harmful (early pool reset -> present never completes) and it had
// defaulted OFF; real GPU-completion is provided by F69 (timeline-as-fence).

// F60 (shim build .40): REAL wait for the translated submit path's completion.
// WHY: with F50 host-side signalling OFF the ICD's broken timeline makes vkWaitSemaphores TIMEOUT
// (rc=2) / DEVICE_LOST, but with it ON MC resets command pools while the GPU is still executing and
// the present semaphore never signals (~940 ms acquire). Both fail. The third road: satisfy the wait
// by DRAINING THE QUEUE (vkQueueWaitIdle) -- a real wait for GPU completion of all submitted work.
// WHAT: when on (DEFAULT ON) and a queue has been cached by a submit/present wrapper, log_WaitSemaphores
// calls vkQueueWaitIdle(queue); on VK_SUCCESS it returns VK_SUCCESS to the caller and never enters the
// ICD's broken vkWaitSemaphores. On failure / no cached queue it falls back to the real vkWaitSemaphores.
// SEMANTIC TRADE (see the F60 report): timeout/flags of vkWaitSemaphores are ignored -- queue-idle is
// treated as "satisfied"; it is a STRICTER completion guarantee than the semaphore wait, but it
// serialises every wait to full GPU idle and does not advance the timeline counter itself.
// MEOW_VK_WAIT_VIA_QUEUE_IDLE=0 restores the original pure-forward path (A/B control).
static int meow_wait_via_queue_idle_decide(const char** why) {
    // F97 (.75, residual-percall-2): lazy one-shot cache (see meow_sync2_to_v1_decide). This decide
    // runs on EVERY vkWaitSemaphores/poll (:3591). Logic and `why` strings unchanged.
    static int s_decided = -1;
    static const char* s_why = NULL;
    if (s_decided < 0) {
        const char* s = getenv("MEOW_VK_WAIT_VIA_QUEUE_IDLE");
        if (s != NULL && strcmp(s, "0") == 0) {
            s_decided = 0;
            s_why = "explicit OFF (MEOW_VK_WAIT_VIA_QUEUE_IDLE=0)";
        } else if (s != NULL && s[0] == '1') {
            s_decided = 1;
            s_why = "explicit ON (MEOW_VK_WAIT_VIA_QUEUE_IDLE=1)";
        } else {
            s_decided = 1;
            s_why = "default ON (real wait via vkQueueWaitIdle)";
        }
    }
    if (why != NULL) *why = s_why;
    return s_decided;
}

/* Official core-1.0 / timeline types: VkMemoryBarrier (vulkan_core.h:3133),
   VkBufferMemoryBarrier (:3079), VkMemoryBarrier2 (:7168), VkSubmitInfo (:3469),
   VkTimelineSemaphoreSubmitInfo (:6602). */
typedef VkMemoryBarrier                VkMemBarrierL;
typedef VkBufferMemoryBarrier          VkBufBarrierL;
typedef VkMemoryBarrier2               VkMemBarrier2L;
typedef VkSubmitInfo                   VkSubmitInfoL;
typedef VkTimelineSemaphoreSubmitInfo  VkTimelineSemSubmitInfoL;

typedef struct { uint64_t v2; uint32_t v1; } MeowFlag2To1;

// VkPipelineStageFlags2 -> VkPipelineStageFlags. Only the bits v1 actually defines.
static const MeowFlag2To1 kStage2To1[] = {
    { 0x00000001ULL, 0x00000001u }, /* TOP_OF_PIPE            -> TOP_OF_PIPE            */
    { 0x00000002ULL, 0x00000002u }, /* DRAW_INDIRECT          -> DRAW_INDIRECT          */
    { 0x00000004ULL, 0x00000004u }, /* VERTEX_INPUT           -> VERTEX_INPUT           */
    { 0x00000008ULL, 0x00000008u }, /* VERTEX_SHADER          -> VERTEX_SHADER          */
    { 0x00000010ULL, 0x00000010u }, /* TESSELLATION_CONTROL   -> TESSELLATION_CONTROL   */
    { 0x00000020ULL, 0x00000020u }, /* TESSELLATION_EVALUATION-> TESSELLATION_EVALUATION*/
    { 0x00000040ULL, 0x00000040u }, /* GEOMETRY_SHADER        -> GEOMETRY_SHADER        */
    { 0x00000080ULL, 0x00000080u }, /* FRAGMENT_SHADER        -> FRAGMENT_SHADER        */
    { 0x00000100ULL, 0x00000100u }, /* EARLY_FRAGMENT_TESTS   -> EARLY_FRAGMENT_TESTS   */
    { 0x00000200ULL, 0x00000200u }, /* LATE_FRAGMENT_TESTS    -> LATE_FRAGMENT_TESTS    */
    { 0x00000400ULL, 0x00000400u }, /* COLOR_ATTACHMENT_OUTPUT-> COLOR_ATTACHMENT_OUTPUT*/
    { 0x00000800ULL, 0x00000800u }, /* COMPUTE_SHADER         -> COMPUTE_SHADER         */
    { 0x00001000ULL, 0x00001000u }, /* ALL_TRANSFER/TRANSFER  -> TRANSFER               */
    { 0x00002000ULL, 0x00002000u }, /* BOTTOM_OF_PIPE         -> BOTTOM_OF_PIPE         */
    { 0x00004000ULL, 0x00004000u }, /* HOST                  -> HOST                   */
    { 0x00008000ULL, 0x00008000u }, /* ALL_GRAPHICS          -> ALL_GRAPHICS          */
    { 0x00010000ULL, 0x00010000u }, /* ALL_COMMANDS          -> ALL_COMMANDS          */
};

// VkAccessFlags2 -> VkAccessFlags. The three SHADER_SAMPLED/STORAGE v2-only bits are
// folded onto their nearest 32-bit v1 spelling; anything else is folded conservatively.
static const MeowFlag2To1 kAccess2To1[] = {
    { 0x00000001ULL, 0x00000001u }, /* INDIRECT_COMMAND_READ        */
    { 0x00000002ULL, 0x00000002u }, /* INDEX_READ                   */
    { 0x00000004ULL, 0x00000004u }, /* VERTEX_ATTRIBUTE_READ        */
    { 0x00000008ULL, 0x00000008u }, /* UNIFORM_READ                 */
    { 0x00000010ULL, 0x00000010u }, /* INPUT_ATTACHMENT_READ        */
    { 0x00000020ULL, 0x00000020u }, /* SHADER_READ                  */
    { 0x00000040ULL, 0x00000040u }, /* SHADER_WRITE                 */
    { 0x00000080ULL, 0x00000080u }, /* COLOR_ATTACHMENT_READ        */
    { 0x00000100ULL, 0x00000100u }, /* COLOR_ATTACHMENT_WRITE       */
    { 0x00000200ULL, 0x00000200u }, /* DEPTH_STENCIL_ATTACHMENT_READ */
    { 0x00000400ULL, 0x00000400u }, /* DEPTH_STENCIL_ATTACHMENT_WRITE*/
    { 0x00000800ULL, 0x00000800u }, /* TRANSFER_READ                */
    { 0x00001000ULL, 0x00001000u }, /* TRANSFER_WRITE               */
    { 0x00002000ULL, 0x00002000u }, /* HOST_READ                    */
    { 0x00004000ULL, 0x00004000u }, /* HOST_WRITE                   */
    { 0x00008000ULL, 0x00008000u }, /* MEMORY_READ                  */
    { 0x00010000ULL, 0x00010000u }, /* MEMORY_WRITE                 */
    { 0x100000000ULL, 0x00000020u }, /* SHADER_SAMPLED_READ  -> SHADER_READ  */
    { 0x200000000ULL, 0x00000020u }, /* SHADER_STORAGE_READ  -> SHADER_READ  */
    { 0x400000000ULL, 0x00000040u }, /* SHADER_STORAGE_WRITE -> SHADER_WRITE */
};

static uint32_t meow_stage2_to_v1(uint64_t m, int* lost) {
    uint32_t out = 0;
    uint64_t rem = m;
    for (size_t i = 0; i < sizeof(kStage2To1) / sizeof(kStage2To1[0]); i++) {
        if (m & kStage2To1[i].v2) {
            out |= kStage2To1[i].v1;
            rem &= ~kStage2To1[i].v2;
        }
    }
    if (rem != 0) {
        out |= 0x00010000u;   /* unmappable v2-only stage bits -> ALL_COMMANDS (conservative) */
        if (lost) ++*lost;
    }
    return out;
}

static uint32_t meow_access2_to_v1(uint64_t m, int* lost) {
    uint32_t out = 0;
    uint64_t rem = m;
    for (size_t i = 0; i < sizeof(kAccess2To1) / sizeof(kAccess2To1[0]); i++) {
        if (m & kAccess2To1[i].v2) {
            out |= kAccess2To1[i].v1;
            rem &= ~kAccess2To1[i].v2;
        }
    }
    if (rem != 0) {
        out |= 0x00018000u;   /* unmappable -> MEMORY_READ|MEMORY_WRITE (conservative) */
        if (lost) ++*lost;
    }
    return out;
}

/* Per-submit temporary storage for one translated vkQueueSubmit call. */
typedef struct {
    VkSemaphore* waitSems;
    uint32_t* waitStages;
    uint64_t* waitVals;
    VkCommandBuffer* cmdBufs;
    VkSemaphore* sigSems;
    uint64_t* sigVals;
    VkTimelineSemSubmitInfoL tsi;
    int useTsi;
    int scratch;   /* F97: 1 => the six pointers above alias the file-level F97 scratch (never freed) */
} MeowSubmit2Tr;

// =====================================================================================
// F97 (.75, residual-percall-2): A3 -- file-level reusable scratch for the per-frame submit and
// barrier translation temporaries (was a calloc/free storm: 2 arrays + <=7 per entry + <=6 merged +
// <=3 per barrier, every frame).
//
// LIFETIME PROOF (must hold before reusing a buffer): every one of these arrays is handed to a
// SYNCHRONOUS Vulkan call -- vkQueueSubmit / vkCmdPipelineBarrier -- which reads it (and everything
// it points to) DURING the call and copies the values it keeps into its own state; the host is only
// required to keep the arrays valid until the call returns (Vulkan parameter-lifetime rules for a
// queue / command-recording command, exactly the rule the F88 `g_f72_writes` scratch already relies
// on: meowvulkan.c:2304). Nothing in this file stores any of these pointers after the call, and no
// wrapper is re-entered by the driver call (the real entry points are the ICD's, not ours), so a
// single static buffer per role is safe under the documented single-render-thread contract
// (A10 G5 / F91 thread probe). Anything larger than the scratch capacity keeps the original
// calloc/free path -- the scratch is never a truncation point.
// =====================================================================================
#define MEOW_F97_MAX_ENTRIES 64   /* == the submitCount cap enforced in meow_translate_queue_submit2 */
#define MEOW_F97_CAP 16           /* per-entry / merged / barrier array capacity; overflow -> calloc */
static MeowSubmit2Tr          g_f97_st[MEOW_F97_MAX_ENTRIES];
static VkSubmitInfoL          g_f97_outs[MEOW_F97_MAX_ENTRIES];
static VkSemaphore            g_f97_e_wsems[MEOW_F97_MAX_ENTRIES][MEOW_F97_CAP];
static uint32_t               g_f97_e_wstages[MEOW_F97_MAX_ENTRIES][MEOW_F97_CAP];
static uint64_t               g_f97_e_wvals[MEOW_F97_MAX_ENTRIES][MEOW_F97_CAP];
static VkCommandBuffer        g_f97_e_cmds[MEOW_F97_MAX_ENTRIES][MEOW_F97_CAP];
static VkSemaphore            g_f97_e_ssems[MEOW_F97_MAX_ENTRIES][MEOW_F97_CAP];
static uint64_t               g_f97_e_svals[MEOW_F97_MAX_ENTRIES][MEOW_F97_CAP];
static VkSemaphore            g_f97_m_wsems[MEOW_F97_CAP];
static uint32_t               g_f97_m_wstages[MEOW_F97_CAP];
static uint64_t               g_f97_m_wvals[MEOW_F97_CAP];
static VkCommandBuffer        g_f97_m_cmds[MEOW_F97_CAP];
static VkSemaphore            g_f97_m_ssems[MEOW_F97_CAP];
static uint64_t               g_f97_m_svals[MEOW_F97_CAP];
static VkMemoryBarrier        g_f97_b_mem[MEOW_F97_CAP];
static VkBufferMemoryBarrier  g_f97_b_buf[MEOW_F97_CAP];
static VkImageMemoryBarrier   g_f97_b_img[MEOW_F97_CAP];

static void meow_submit2_tr_free(MeowSubmit2Tr* st, uint32_t n) {
    if (st == NULL) return;
    for (uint32_t i = 0; i < n; i++) {
        if (st[i].scratch) continue;   // F97: aliases the file-level scratch -> never freed here
        free(st[i].waitSems);
        free(st[i].waitStages);
        free(st[i].waitVals);
        free(st[i].cmdBufs);
        free(st[i].sigSems);
        free(st[i].sigVals);
    }
    if (st != g_f97_st) free(st);      // F97: the struct array itself is usually the scratch
}

// Translate one vkQueueSubmit2 call into vkQueueSubmit call(s) and issue them.
// F48 (shim build .29): the on-device .28 log settles the "malformed VkSubmitInfo" question --
// EVERY translated call that kept N>1 VkSubmitInfo entries returned rc=-1, while EVERY
// vkQueueSubmit with submitCount==1 (the probe's native v1 path / the un-split cells) returned
// rc=0 (all 210 of them across the .logs corpus). The per-entry VkSubmitInfo this file builds is
// spec-valid (sType=4, pWaitDstStageMask present for waitCount>0, arrays/counts match; verified
// against vulkan_core.h and in the compiled .so), so the failing dimension is submitCount itself:
// this ICD's v1 vkQueueSubmit does not accept submitCount>1. The .29 fold (N entries -> ONE v1
// VkSubmitInfo with N command buffers) STILL returned rc=-1, while the SAME .29 log shows 90
// native "vkQueueSubmit rc=0 count=1" successes -- so the ICD rejects any multi-entry submit.
// F49 (shim build .30): therefore SPLIT instead of fold. For each VkSubmitInfo2 entry i we build
// its own VkSubmitInfo and issue a SEPARATE realSubmit(queue, 1, &out[i], fence?) call: each call
// carries exactly one entry and that entry's command buffer list, i.e. exactly the shape of every
// observed rc=0 call. Wait/signal semaphores stay attached to the entry they came from (the .29
// fold moved every wait before every command buffer), so per-entry ordering is preserved. A
// per-entry VkTimelineSemaphoreSubmitInfo is chained when that entry has any non-zero value.
// NOTE ON commandBufferInfoCount>1: an entry's command buffers are deliberately kept in its ONE
// VkSubmitInfo (v1 natively carries N command buffers). Device evidence condemns submitCount, not
// commandBufferCount, and splitting one entry's command buffers would change Vulkan execution
// semantics. Every entry in this project's logs has exactly 1 command buffer anyway.
// F50 (shim build .31): the .30 split made submit itself succeed (rc=0), but the timeline value a
// submit was supposed to signal never advanced the timeline counter, so vkWaitSemaphores returned
// rc=2 (TIMEOUT). After each entry is accepted, the host now advances every value!=0 signal
// semaphore of that entry via vkSignalSemaphore (see meow_timeline_host_signal_decide). Accepted
// cost: host-side advance does NOT wait for GPU completion (possible tearing), but no TIMEOUT.
// F51 (shim build .32 no-fold): the .31 device log exposed the last place where a batch of N
// entries produced fewer than N vkQueueSubmit calls: the per-entry loop used to BREAK on the first
// non-zero return, so a batch whose entry[0] came back rc=-4 logged "submitsIn=2 submits=1 ...
// stoppedAt=0 rcSeq=-4" (this is an early STOP, NOT an aggregation/fold -- only entry[0]'s own
// command buffers were ever put in that one call). The loop now attempts EVERY entry exactly once
// (one vkQueueSubmit each, submitCount=1) and keeps the FIRST error as rc; `submits` therefore
// always equals `submitsIn`, and a new `diverged=` field reports any future regression. The rc=-4
// itself is the ICD's own VK_ERROR_DEVICE_LOST on a legitimate single-entry submit; removing the
// break does not, and is not claimed to, cure device loss.
// F66 (shim build .43): MERGE the entries instead of splitting them.
// WHY (on-device F65/F65b, probe cells 8/9/12/16 vs 17): this ICD accepts exactly ONE entry per
// submission. With N entries the SECOND one dies -- rcSeq=0,-1, and the driver says
// "Command buffer has error and cannot be executed" / "Queue submit batches fail result 3". The
// frame content is irrelevant (an in-place clear instead of the blit fails identically, and a
// binary-only signal fails identically). One merged entry carrying the acquire wait + every
// command buffer + every signal passes 60/60 frames with submit/present/timeline all rc=0 and no
// slow acquire. So F49's "N single-entry vkQueueSubmit calls" was the wrong direction for this
// ICD: it merely moved the failure from "second entry in one call" to "second call".
// WHAT: build ONE VkSubmitInfo holding, in original entry order, every entry's waits (with their
// own translated stage masks and timeline values), every command buffer and every signal; chain a
// single VkTimelineSemaphoreSubmitInfo when any entry carried a timeline wait/signal. The merged
// wait set is a superset of each entry's own (a wait that used to order entry k now also orders
// the earlier command buffers) -- strictly more conservative, and submission order within one
// queue is preserved, so this is a faithful translation for a single queue.
// MEOW_VK_SYNC2_TO_V1_MERGE=0 restores the F49 N-call split as the A/B control.
static int meow_sync2v1_merge_decide(const char** why) {
    // F97 (.75, residual-percall-2): lazy one-shot cache (see meow_sync2_to_v1_decide). This decide
    // runs on EVERY translated submit (:3045). Logic and `why` strings unchanged.
    static int s_decided = -1;
    static const char* s_why = NULL;
    if (s_decided < 0) {
        const char* s = getenv("MEOW_VK_SYNC2_TO_V1_MERGE");
        if (s != NULL && strcmp(s, "0") == 0) {
            s_decided = 0;
            s_why = "explicit OFF (MEOW_VK_SYNC2_TO_V1_MERGE=0): F49 N-call split";
        } else if (s != NULL && s[0] == '1') {
            s_decided = 1;
            s_why = "explicit ON (MEOW_VK_SYNC2_TO_V1_MERGE=1)";
        } else {
            s_decided = g_hooks ? 1 : 0;
            s_why = g_hooks ? "default ON (F66: this ICD accepts exactly one entry)"
                            : "default OFF (hooks off)";
        }
    }
    if (why != NULL) *why = s_why;
    return s_decided;
}

// =====================================================================================
// F69 (shim build 2026-09-18.45 timeline-as-fence): translate MC's TIMELINE semaphore
// completion to a REAL VkFence -- never a host-side forge.
//
// WHY: on-device F66 evidence (see stuffs/research/vulkan/fixes/F50-host-timeline-signal.md:18)
// is that this ICD accepts the merged v1 submit (rc=0) but never advances the timeline counter
// from the GPU side, so MC's vkWaitSemaphores on its own timeline returns -4 (DEVICE_LOST) /
// rc=2 (TIMEOUT). F50's host-side vkSignalSemaphore was PROVEN harmful (F60: MC resets command
// pools while the GPU is still running -> present never completes) and is default OFF.
// WHAT (real GPU-completion semantics):
//   * merged submit (F66, default ON): every timeline SIGNAL semaphore is REMOVED from the
//     submitted pSignalSemaphores (binary ones stay). One real VkFence is created and handed to
//     vkQueueSubmit; after rc=0 the mapping (sem, value) -> fence is recorded. A later
//     vkWaitSemaphores / vkGetSemaphoreCounterValue is answered from that fence, i.e. from
//     ACTUAL GPU completion.
//   * timeline WAIT inside a submit: the host first vkWaitForFences on the mapped fence (real
//     completion of the earlier submit) and that wait is removed from pWaitSemaphores. This
//     serialises host vs GPU but keeps the ordering correct.
// NO host-side advance happens here: a fence signals only when the GPU is done.
// Bounded: <=64 timeline semaphores x <=64 (value,fence) each; the oldest is evicted and its
// fence destroyed with a rate-limited log. Single render thread (same assumption as
// g_meow_last_queue), so the table is deliberately lock-free.
// MEOW_VK_TIMELINE_AS_FENCE: 0 = off (EXACTLY today's behaviour), 1 = on, unset = follows g_hooks.
// Only the F66 merged path is translated; the non-merge F49 path is left untouched.
// =====================================================================================
#define MEOW_F69_MAX_SEMS 64
#define MEOW_F69_MAX_ENTRIES 64

typedef struct { uint64_t value; uint64_t fence; int signaled; uint64_t queue; } MeowF69Map;
typedef struct { uint64_t sem; uint32_t count; MeowF69Map map[MEOW_F69_MAX_ENTRIES]; } MeowF69SemSlot;
typedef struct { uint64_t sem; uint64_t value; } MeowF69Pair;

static MeowF69SemSlot g_f69_sems[MEOW_F69_MAX_SEMS];
static unsigned long g_f69_evicts;

static int meow_f69_decide(const char** why) {
    // F97 (.75, residual-percall-2): lazy one-shot cache (see meow_sync2_to_v1_decide). This decide
    // runs on EVERY wait (:3532), every vkGetSemaphoreCounterValue poll (:3646) and every translated
    // submit (:3125), i.e. the hottest of the four. Logic and `why` strings unchanged.
    static int s_decided = -1;
    static const char* s_why = NULL;
    if (s_decided < 0) {
        const char* s = getenv("MEOW_VK_TIMELINE_AS_FENCE");
        if (s != NULL && strcmp(s, "0") == 0) {
            s_decided = 0;
            s_why = "explicit OFF (MEOW_VK_TIMELINE_AS_FENCE=0)";
        } else if (s != NULL && s[0] == '1') {
            s_decided = 1;
            s_why = "explicit ON (MEOW_VK_TIMELINE_AS_FENCE=1)";
        } else {
            s_decided = g_hooks ? 1 : 0;
            s_why = g_hooks ? "default ON (hooks on, env unset)" : "default OFF (hooks off, env unset)";
        }
    }
    if (why != NULL) *why = s_why;
    return s_decided;
}
static int meow_f69_on(void) { return meow_f69_decide(NULL); }

typedef int  (*MeowF69PFN_createFence)(void*, const void*, const void*, void**);
typedef void (*MeowF69PFN_destroyFence)(void*, uint64_t, const void*);
typedef int  (*MeowF69PFN_waitForFences)(void*, uint32_t, const uint64_t*, uint32_t, uint64_t);
typedef int  (*MeowF69PFN_getFenceStatus)(void*, uint64_t);

// F92 (.70): these four were resolved through g_gdpa() on EVERY call. getFenceStatus runs once per
// pending pool per frame (meow_f72_pool_free) and waitForFences once per frame (F69 merged submit +
// vkWaitSemaphores poll), so they now use the F87 per-wrapper cache. Same failure behaviour: a NULL
// g_gdpa leaves the slot NULL and it is retried on the next call.
static MeowF69PFN_createFence meow_f69_createFence(void) {
    return (MeowF69PFN_createFence)meow_cached_proc(&meow_p_vkCreateFence, &meow_d_vkCreateFence, "vkCreateFence");
}
static MeowF69PFN_waitForFences meow_f69_waitForFences(void) {
    return (MeowF69PFN_waitForFences)meow_cached_proc(&meow_p_vkWaitForFences, &meow_d_vkWaitForFences, "vkWaitForFences");
}
static MeowF69PFN_getFenceStatus meow_f69_getFenceStatus(void) {
    return (MeowF69PFN_getFenceStatus)meow_cached_proc(&meow_p_vkGetFenceStatus, &meow_d_vkGetFenceStatus, "vkGetFenceStatus");
}
static void meow_f69_destroyFence_raw(uint64_t fence) {
    if (fence == 0) return;
    MeowF69PFN_destroyFence df =
        (MeowF69PFN_destroyFence)meow_cached_proc(&meow_p_vkDestroyFence, &meow_d_vkDestroyFence, "vkDestroyFence");
    if (df != NULL) df(g_dev_seen, fence, NULL);
}

// F78 (review A24 F-1): an F69-created fence is also BORROWED by F72 pools
// (meow_f72_bind_submit) as the completion fence of the submit it covers, but F72 can
// outlive the F69 map entry (64-entry eviction, or vkDestroySemaphore while pools are
// still pending). Destroying the fence from F69 alone would leave F72's pools holding a
// dangling handle that meow_f72_pool_free() still passes to vkGetFenceStatus. Each borrow
// takes a reference; meow_f69_destroyFence() relinquishes F69's ownership but DEFERS the
// real destroy while references remain, and the last meow_f69_borrow_unref() reaps it.
// Bounded by the F72 pool cap (MEOW_F72_NPOOLS <= 64 pending pools) -> no env, no switch.
#define MEOW_F69_MAX_BORROWS 64
typedef struct { uint64_t fence; int refs; int released; } MeowF69Borrow;
static MeowF69Borrow g_f69_borrows[MEOW_F69_MAX_BORROWS];
// F95 (.73): saturation count for THIS fixed table (defined early so meow_f69_borrow_ref can bump it;
// printed on the existing F72b totals line). Declared once here, no duplicate definition later.
static unsigned long g_f95_borrow_full;

static MeowF69Borrow* meow_f69_borrow_find(uint64_t fence) {
    for (int i = 0; i < MEOW_F69_MAX_BORROWS; i++) {
        if (g_f69_borrows[i].fence == fence) return &g_f69_borrows[i];
    }
    return NULL;
}

static void meow_f69_borrow_ref(uint64_t fence) {
    if (fence == 0) return;
    MeowF69Borrow* b = meow_f69_borrow_find(fence);
    if (b != NULL) { ++b->refs; return; }
    for (int i = 0; i < MEOW_F69_MAX_BORROWS; i++) {
        if (g_f69_borrows[i].fence == 0) {
            g_f69_borrows[i].fence = fence;
            g_f69_borrows[i].refs = 1;
            g_f69_borrows[i].released = 0;
            return;
        }
    }
    // F95 (.73): a full borrow table is a REAL saturation, not noise: an untracked fence can be
    // destroyed by F69's map eviction while an F72 pool still holds it (dangling pool fence). Count
    // it so the next totals line tells this apart from "the table was never full".
    ++g_f95_borrow_full;
    MEOWLOGW("meowvulkan: F78 borrow table full (%{public}d); fence=0x%{public}llx untracked",
             MEOW_F69_MAX_BORROWS, (unsigned long long)fence);
}

static void meow_f69_borrow_unref(uint64_t fence) {
    if (fence == 0) return;
    MeowF69Borrow* b = meow_f69_borrow_find(fence);
    if (b == NULL) return;
    if (--b->refs > 0) return;
    int released = b->released;
    b->fence = 0;
    b->refs = 0;
    b->released = 0;
    if (released) meow_f69_destroyFence_raw(fence);
}

// F78: F69 gives up its ownership here. If F72 still borrows the fence, the destroy is
// deferred to the last meow_f69_borrow_unref(); otherwise it happens now (unchanged path).
static void meow_f69_destroyFence(uint64_t fence) {
    if (fence == 0) return;
    MeowF69Borrow* b = meow_f69_borrow_find(fence);
    if (b != NULL) { b->released = 1; return; }
    meow_f69_destroyFence_raw(fence);
}

static int meow_f69_find_sem(uint64_t sem) {
    for (int i = 0; i < MEOW_F69_MAX_SEMS; i++) {
        if (g_f69_sems[i].sem == sem) return i;
    }
    return -1;
}
static int meow_f69_is_timeline(uint64_t sem) { return meow_f69_find_sem(sem) >= 0; }

static void meow_f69_register_sem(uint64_t sem) {
    if (sem == 0 || meow_f69_find_sem(sem) >= 0) return;
    for (int i = 0; i < MEOW_F69_MAX_SEMS; i++) {
        if (g_f69_sems[i].sem == 0) {
            memset(&g_f69_sems[i], 0, sizeof(g_f69_sems[i]));
            g_f69_sems[i].sem = sem;
            MEOWLOGI("meowvulkan: F69 timeline sem registered sem=0x%{public}llx slot=%{public}d",
                     (unsigned long long)sem, i);
            return;
        }
    }
    MEOWLOGW("meowvulkan: F69 timeline sem table full (%{public}d); sem=0x%{public}llx untracked",
             MEOW_F69_MAX_SEMS, (unsigned long long)sem);
}

static void meow_f69_add_entry(uint64_t sem, uint64_t value, uint64_t fence, uint64_t queue) {
    int si = meow_f69_find_sem(sem);
    if (si < 0 || fence == 0) return;
    MeowF69SemSlot* s = &g_f69_sems[si];
    if (s->count >= MEOW_F69_MAX_ENTRIES) {
        uint64_t victim = s->map[0].fence;
        memmove(&s->map[0], &s->map[1], (MEOW_F69_MAX_ENTRIES - 1) * sizeof(MeowF69Map));
        s->count = MEOW_F69_MAX_ENTRIES - 1;
        meow_f69_destroyFence(victim);
        unsigned long n = ++g_f69_evicts;
        if (n <= 8 || (n % 2000) == 0)
            MEOWLOGW("meowvulkan: F69 map full sem=0x%{public}llx; evicted oldest fence=0x%{public}llx (evict#%{public}lu)",
                     (unsigned long long)sem, (unsigned long long)victim, n);
    }
    s->map[s->count].value = value;
    s->map[s->count].fence = fence;
    // F97 (.75, residual-percall-2): remember the queue this fence was submitted to. The whole-queue
    // idle proof (meow_f69_mark_queue_idle) only trusts vkQueueWaitIdle on THIS queue, so a fence
    // submitted to a different queue is never marked complete by an unrelated idle.
    s->map[s->count].queue = queue;
    // F93 (.71 fix-pool-reclaim): the slot about to be written may be a REUSED one -- after the
    // eviction memmove above, index `count` still holds the previous newest entry, whose `signaled`
    // bit may be 1. F92-B added `signaled` but never (re)initialised it here, so a brand-new
    // (value,fence) inherited a stale "already signaled" proof. That made meow_f69_completion_proven()
    // / meow_f69_signaled_value() report completion that no real query ever proved -> the merged
    // submit dropped its timeline wait ("少等", I1 violation) and MC ran frames ahead, so the F72
    // pool completion fences were never observed SIGNALED -> pools never reclaimed. Initialise it.
    s->map[s->count].signaled = 0;
    s->count++;
}

// F92 (.70, invariant I1 companion): a fence, once observed SIGNALED, stays signaled until it is
// destroyed -- and a destroyed fence's map entry is removed in the same step (meow_f69_add_entry
// eviction / meow_f69_forget_sem / meow_f69_destroyFence_raw), so no stale handle can be reused.
// Marking the bit therefore never makes the shim "wait less": it only records a completion that a REAL
// driver query already proved. meow_f69_completion_proven() short-circuits a wait ONLY on that bit;
// when the bit is clear it does NOT query the driver (which would add a call to the not-ready case) --
// the caller proceeds with exactly today's wait. Strictly never worse, never a forged success.
static int meow_f69_completion_proven(uint64_t sem, uint64_t fence) {
    if (fence == 0) return 0;
    int si = meow_f69_find_sem(sem);
    if (si < 0) return 0;
    MeowF69SemSlot* s = &g_f69_sems[si];
    for (uint32_t i = 0; i < s->count; i++) {
        if (s->map[i].fence == fence) return s->map[i].signaled;
    }
    return 0;
}

static void meow_f69_mark_completion(uint64_t sem, uint64_t fence) {
    if (fence == 0) return;
    int si = meow_f69_find_sem(sem);
    if (si < 0) return;
    MeowF69SemSlot* s = &g_f69_sems[si];
    for (uint32_t i = 0; i < s->count; i++) {
        if (s->map[i].fence == fence) { s->map[i].signaled = 1; return; }
    }
}

// Smallest mapped value >= the requested value: waiting for it proves the counter reached it.
static uint64_t meow_f69_wait_fence_for(uint64_t sem, uint64_t value) {
    int si = meow_f69_find_sem(sem);
    if (si < 0) return 0;
    MeowF69SemSlot* s = &g_f69_sems[si];
    uint64_t best = 0, bestVal = 0;
    for (uint32_t i = 0; i < s->count; i++) {
        if (s->map[i].fence != 0 && s->map[i].value >= value) {
            if (best == 0 || s->map[i].value < bestVal) { best = s->map[i].fence; bestVal = s->map[i].value; }
        }
    }
    return best;
}

// Largest mapped value whose fence is already signaled (the completed counter value).
static uint64_t meow_f69_signaled_value(uint64_t sem) {
    int si = meow_f69_find_sem(sem);
    if (si < 0) return 0;
    MeowF69SemSlot* s = &g_f69_sems[si];
    MeowF69PFN_getFenceStatus gfs = meow_f69_getFenceStatus();
    uint64_t best = 0;
    if (gfs == NULL) return 0;
    for (uint32_t i = 0; i < s->count; i++) {
        if (s->map[i].fence == 0) continue;
        // F92: a previously-proven fence needs no driver query at all (MC polls this heavily).
        if (s->map[i].signaled || gfs(g_dev_seen, s->map[i].fence) == VK_SUCCESS) {
            s->map[i].signaled = 1;
            if (s->map[i].value > best) best = s->map[i].value;
        }
    }
    return best;
}

// F97 (.75, residual-percall-2): A1 -- reuse the F60 "whole queue idle" proof for the F69 map.
// A successful vkQueueWaitIdle(Q) is the SAME boundary F94/F95 already trust as stronger than any
// single fence: it proves EVERY submission to Q before that point completed. Every F69 map entry is
// added only AFTER its vkQueueSubmit returned rc=0 and records the queue it was submitted to
// (meow_f69_add_entry on the merged path), so at the idle point every entry whose `.queue == Q` is
// backed by a real VkFence the GPU has signaled. Recording that one-way bit removes the per-poll
// vkGetFenceStatus storm in meow_f69_signaled_value WITHOUT changing its reported value: the value
// is still the largest mapped value covered by a REAL completion proof -- only the proof source
// changes (queue-idle boundary instead of a per-fence query). It is idempotent, and an entry added
// after the idle is simply marked at the next idle of its queue (F93 keeps new entries signaled=0),
// so no fence that was still in flight at idle time is ever marked. Only reachable while F69 is on.
static void meow_f69_mark_queue_idle(uint64_t queue) {
    if (!meow_f69_on()) return;
    if (queue == 0) return;
    for (int i = 0; i < MEOW_F69_MAX_SEMS; i++) {
        MeowF69SemSlot* s = &g_f69_sems[i];
        if (s->sem == 0) continue;
        for (uint32_t k = 0; k < s->count; k++) {
            MeowF69Map* m = &s->map[k];
            if (m->fence != 0 && !m->signaled && m->queue == queue) m->signaled = 1;
        }
    }
}

static void meow_f69_forget_sem(uint64_t sem) {
    int si = meow_f69_find_sem(sem);
    if (si < 0) return;
    MeowF69SemSlot* s = &g_f69_sems[si];
    uint32_t n = s->count;
    for (uint32_t i = 0; i < s->count; i++) meow_f69_destroyFence(s->map[i].fence);
    memset(s, 0, sizeof(*s));
    MEOWLOGI("meowvulkan: F69 timeline sem destroyed sem=0x%{public}llx fences=%{public}u",
             (unsigned long long)sem, n);
}

static void meow_f69_forget_all(void) {
    for (int i = 0; i < MEOW_F69_MAX_SEMS; i++) {
        if (g_f69_sems[i].sem != 0) meow_f69_forget_sem(g_f69_sems[i].sem);
    }
}

// F69: a semaphore is a timeline semaphore iff its create-info pNext chain carries a
// VkSemaphoreTypeCreateInfo with semaphoreType == VK_SEMAPHORE_TYPE_TIMELINE.
static int meow_f69_createinfo_is_timeline(const void* ci) {
    const VkSemaphoreCreateInfo* sc = (const VkSemaphoreCreateInfo*)ci;
    const VkBaseInStructure* p = (sc != NULL) ? (const VkBaseInStructure*)sc->pNext : NULL;
    while (p != NULL) {
        if ((uint32_t)p->sType == (uint32_t)VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO) {
            const VkSemaphoreTypeCreateInfo* st = (const VkSemaphoreTypeCreateInfo*)p;
            return (st->semaphoreType == VK_SEMAPHORE_TYPE_TIMELINE) ? 1 : 0;
        }
        p = p->pNext;
    }
    return 0;
}

// =====================================================================================
// F72 (shim build 2026-09-18.49 push-as-set): emulate vkCmdPushDescriptorSet(KHR) with an
// ORDINARY VkDescriptorSet.
//
// WHY: F68 cleared the two push-descriptor calls by DROPPING them, and the frame then still failed
// the same way (device lost) -- but MC only ever binds descriptors through push, so dropping them
// meant the draws ran with NO descriptors, i.e. a different fault, not a cleared suspect. F71
// falsified the divisor hypothesis (plain pipelines=1 withDivisorState=0 maxDivisor=0). The
// campaign's standing blocker is exactly "vkCmdPushDescriptorSet consumed by a real pipeline =>
// device lost". The designed remedy (proven end-to-end in native C on this device: pool -> set ->
// vkUpdateDescriptorSets -> vkCmdBindDescriptorSets) is to RECORD the same content through the
// ordinary descriptor path instead of the broken push path.
//
// WHAT (all host-side, never a lie about the command stream's semantics):
//   * vkCreatePipelineLayout is captured into a bounded table so (layout, set) -> its
//     VkDescriptorSetLayout is known. A missing entry is NOT guessed: the real push is forwarded.
//   * a push is turned into: vkAllocateDescriptorSets(pool) + copy the writes with dstSet set +
//     vkUpdateDescriptorSets + vkCmdBindDescriptorSets(firstSet=set, count=1, dynamicOffset 0).
//   * pools: 8 rotating VkDescriptorPool, each with a generous fixed ceiling (256 sets x 16 of
//     every core descriptor type -- MC's write types/counts cannot be predicted). A pool is only
//     reset/reused after the fence of the submit that used it has SIGNALED (F69 helpers:
//     meow_f69_createFence / meow_f69_getFenceStatus / meow_f69_destroyFence).
//   * every failure (layout not captured, no free pool, allocate failed, missing forward) degrades
//     to forwarding the ORIGINAL push with a rate-limited WARN -- no guessing, no silent drop.
// MEOW_VK_PUSH_AS_SET: 0 = off (EXACTLY today's behaviour), 1 = on, unset = follows g_hooks.
// =====================================================================================
#define MEOW_F72_NPOOLS   64   // F72c (.53): hard cap; pools start at 0 and grow on demand
#define MEOW_F72_MAXSETS  256
#define MEOW_F72_PER_TYPE 16
#define MEOW_F72_LAYOUTS  256
// F93 (.71, requirement B): force a proven completion boundary once this many pools have been grown
// in a row with no successful reclaim in between. Far below MEOW_F72_NPOOLS, so the count can never
// creep to the cap even if fence-signal reclaim is stuck.
#define MEOW_F72_EARLY_RECLAIM_GROWS 2

static int meow_f72_decide(const char** why) {
    // F87 (.65): env read lazily ONCE and cached (same policy as g_hooks: first use wins); the
    // decision logic and every `why` string are unchanged, only the getenv() count dropped from one
    // per call to one per process. g_hooks is itself resolved once by init_once() before any wrapper.
    static int s_decided = -1;
    static const char* s_why = NULL;
    if (s_decided < 0) {
        const char* s = getenv("MEOW_VK_PUSH_AS_SET");
        if (s != NULL && strcmp(s, "0") == 0) {
            s_decided = 0;
            s_why = "explicit OFF (env=0)";
        } else if (s != NULL && s[0] == '1') {
            s_decided = 1;
            s_why = "explicit ON (env=1)";
        } else {
            s_decided = g_hooks ? 1 : 0;
            s_why = g_hooks ? "default ON (hooks on, env unset)" : "default OFF (hooks off, env unset)";
        }
    }
    if (why != NULL) *why = s_why;
    return s_decided;
}
static int meow_f72_on(void) { return meow_f72_decide(NULL); }

// =====================================================================================
// F92 (.70) F72 ring reuse -- TIER B, DEFAULT OFF (MEOW_VK_F72_RING=1 opts in).
//
// WHY: in the default (`.65`-proven) path every push costs a real vkAllocateDescriptorSets. With
// MEOW_VK_F72_RING=1 a push may instead reuse a descriptor set that was returned to a per-pool free
// table at a PROVEN completion boundary. This is exactly the class of change the project has crashed
// on twice, so it is opt-in and honour the following invariants (see the F92 report):
//   I2  free table empty  => STILL vkAllocateDescriptorSets from the CURRENT pool; a pool is left
//       only on capacity exhaustion (nsets >= MAXSETS) or VK_ERROR_OUT_OF_POOL_MEMORY. (The `.67`
//       bug -- rotate the pool the instant the free table was empty -- is NOT reintroduced.)
//   I3  a set enters the free table ONLY inside meow_f72_pool_recycle(), which is reachable only from
//       meow_f72_reset_pool(), i.e. only after the pool's fence has SIGNALED (pool_free) or a
//       successful vkQueueWaitIdle (quiesce). The generation that produced the set is then provably
//       complete.
//   I4  a set is in `ring` XOR `issued`, never both; it is issued at most once between recycle
//       boundaries, and every reissue is separated from its previous use by a proven completion.
//   I5  (F99, .77) a set is only ever REUSED after a push that provably overwrote EVERY binding of its
//       layout (meow_f72_push_covers); a layout that cannot be verified is never reused.
// Default: the ring is OFF again since F100 (.78). F99's gate fixes set content, but reuse also
// replaces the pool reset that returns descriptor memory -> pools saturate -> DEVICE_LOST; see F100.
// =====================================================================================
typedef struct { VkDescriptorSet set; VkDescriptorSetLayout layout; } MeowF72SetRef;

static int meow_f72_ring_decide(const char** why) {
    static int s_decided = -1;
    static const char* s_why = NULL;
    if (s_decided < 0) {
        const char* s = getenv("MEOW_VK_F72_RING");
        // F100 (.78): BACK TO OPT-IN. F99's coverage gate fixed set CONTENT, but reuse also REPLACES
        // vkResetDescriptorPool -- and a pool's maxSets is the allocation budget BETWEEN resets, so
        // without a reset the descriptor memory is never returned: allocs reach pools*maxSets, then
        // vkAllocateDescriptorSets returns OUT_OF_POOL_MEMORY, the push falls back to the native
        // vkCmdPushDescriptorSet (broken here) and the ICD loses the device (flicker + very low FPS).
        // Reuse must not be the default. =1 re-enables the (gate-protected) path for study only.
        if (s != NULL && s[0] == '1') {
            s_decided = 1;
            s_why = "explicit ON (MEOW_VK_F72_RING=1; study only, NOT a supported default -- see F100)";
        } else {
            s_decided = 0;
            s_why = "default OFF (F100; MEOW_VK_F72_RING=1 to enable, study only)";
        }
    }
    if (why != NULL) *why = s_why;
    return s_decided;
}
static int meow_f72_ring_on(void) { return meow_f72_ring_decide(NULL); }

// Rate-limited reporter (same policy as meow_log_drop, F55/F56 project rule): the first 4 failures
// are named, then one running total every 4000; MEOW_VK_VERBOSE=1 restores every call.
static unsigned long g_f72_fallbacks;
// F72c (.53): `a`/`b` are SIGNED. `a` is a VkResult or a value; `b` is the set index or the pool
// index (0 where not applicable). VkResult code table (all negative):
//   -1 = VK_ERROR_OUT_OF_HOST_MEMORY        -2 = VK_ERROR_OUT_OF_DEVICE_MEMORY
//   -3 = VK_ERROR_INITIALIZATION_FAILED     -4 = VK_ERROR_DEVICE_LOST
//   -5 = VK_ERROR_MEMORY_MAP_FAILED         -1000069000 = VK_ERROR_OUT_OF_POOL_MEMORY
//   -1000069001 = VK_ERROR_INVALID_EXTERNAL_HANDLE
static void meow_f72_warn(const char* what, long a, long b) {
    unsigned long n = ++g_f72_fallbacks;
    if (meow_vk_verbose() || n <= 4ul) {
        MEOWLOGW("meowvulkan: F72b push forwarded(reason=%{public}s a=%{public}ld b=%{public}ld) -- #%{public}lu",
                 what, a, b, n);
    } else if ((n % 20000ul) == 0ul) {
        MEOWLOGW("meowvulkan: F72 push-as-set fallbacks so far: %{public}lu (rate-limited; "
                 "MEOW_VK_VERBOSE=1 shows every call)", n);
    }
}

static PFN_vkVoidFunctionLocal meow_f72_real(const char* name) {
    return g_gdpa ? g_gdpa(g_dev_seen, name) : NULL;
}

// ---------------------------------------------------------------- (layout, set) -> setLayout
typedef struct { uint64_t layout; uint32_t count; VkDescriptorSetLayout* sets; } MeowF72LayoutSlot;
static MeowF72LayoutSlot g_f72_layouts[MEOW_F72_LAYOUTS];
static unsigned long g_f72_layout_evicts;

static void meow_f72_capture_layout(const void* ci, void* layout) {
    if (!meow_f72_on() || ci == NULL || layout == NULL) return;
    const VkPipelineLayoutCreateInfo* pci = (const VkPipelineLayoutCreateInfo*)ci;
    uint32_t n = pci->setLayoutCount;
    if (n > 0 && pci->pSetLayouts == NULL) return;
    uint64_t key = (uint64_t)(uintptr_t)layout;
    for (int i = 0; i < MEOW_F72_LAYOUTS; i++) {
        if (g_f72_layouts[i].layout == key) return;   // already captured
    }
    int slot = -1;
    for (int i = 0; i < MEOW_F72_LAYOUTS; i++) {
        if (g_f72_layouts[i].layout == 0) { slot = i; break; }
    }
    if (slot < 0) {
        // Bounded table: drop the oldest (slot 0) and append at the end. Rare; rate-limited.
        free(g_f72_layouts[0].sets);
        memmove(&g_f72_layouts[0], &g_f72_layouts[1], (MEOW_F72_LAYOUTS - 1) * sizeof(MeowF72LayoutSlot));
        memset(&g_f72_layouts[MEOW_F72_LAYOUTS - 1], 0, sizeof(MeowF72LayoutSlot));
        slot = MEOW_F72_LAYOUTS - 1;
        unsigned long e = ++g_f72_layout_evicts;
        if (e <= 4ul || (e % 2000ul) == 0ul)
            MEOWLOGW("meowvulkan: F72 pipeline-layout table full (%{public}d); evicted oldest (evict#%{public}lu)",
                     MEOW_F72_LAYOUTS, e);
    }
    VkDescriptorSetLayout* copy = NULL;
    if (n > 0) {
        copy = (VkDescriptorSetLayout*)calloc(n, sizeof(VkDescriptorSetLayout));
        if (copy == NULL) { meow_f72_warn("oom-layout-copy", n, 0); return; }
        for (uint32_t i = 0; i < n; i++) copy[i] = pci->pSetLayouts[i];
    }
    g_f72_layouts[slot].layout = key;
    g_f72_layouts[slot].count = n;
    g_f72_layouts[slot].sets = copy;
    // F103 (build 2026-09-23.82 quiet-vk-probes): capture is per DISTINCT pipeline layout, which MC
    // creates per pipeline (measured 200 lines/run) -- a research probe, so default QUIET. The capture
    // itself is unchanged; MEOW_VK_VERBOSE=1 restores the line.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: F72 pipelineLayout captured layout=0x%{public}llx setLayouts=%{public}u slot=%{public}d",
                 (unsigned long long)key, n, slot);
}

static VkDescriptorSetLayout meow_f72_lookup_dsl(void* layout, uint32_t set) {
    uint64_t key = (uint64_t)(uintptr_t)layout;
    // F87 (.65): last-hit cache for the per-push lookup. The cache is only trusted after re-checking
    // that the remembered slot still holds this exact key, so an eviction/memmove can never make it
    // return another layout's sets. Misses fall back to the unchanged full scan -> same result.
    static int s_last = -1;
    static uint64_t s_last_key = 0;
    // F91 (M1 race, review A39 F2): snapshot the remembered index/key into locals and use ONLY them.
    // The remembered entry is still re-checked against its OWN key (`g_f72_layouts[i].layout == key`),
    // so under the single render thread the result is byte-for-byte the old one, and a concurrent
    // rewrite of s_last can no longer make this branch return another layout's set.
    int li = s_last;
    uint64_t lk = s_last_key;
    if (li >= 0 && lk == key && g_f72_layouts[li].layout == key) {
        if (set < g_f72_layouts[li].count && g_f72_layouts[li].sets != NULL)
            return g_f72_layouts[li].sets[set];
        return VK_NULL_HANDLE;
    }
    for (int i = 0; i < MEOW_F72_LAYOUTS; i++) {
        if (g_f72_layouts[i].layout == key) {
            s_last = i;
            s_last_key = key;
            if (set < g_f72_layouts[i].count && g_f72_layouts[i].sets != NULL)
                return g_f72_layouts[i].sets[set];
            return VK_NULL_HANDLE;
        }
    }
    return VK_NULL_HANDLE;
}

// ------------------------------------------------- vkCreateDescriptorSetLayout capture + mirror
// F72b (build .50): MC only uses push descriptors, so its VkDescriptorSetLayouts very likely carry
// VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR -- and by spec such a layout CANNOT be used
// with vkAllocateDescriptorSets. Emulating with the original layout would then fail on (almost) every
// push and silently degrade to forwarding. Fix: capture each set layout's create-info and build a
// MIRROR layout with the SAME bindings / immutable samplers but WITHOUT the push bit; allocate from
// the mirror and bind with the ORIGINAL pipeline layout (the push bit does not participate in
// set-layout compatibility). Mirror creation failure => that layout is not simulatable => push
// forwards. Mirrors are destroyed on vkDestroyDescriptorSetLayout / vkDestroyDevice.
#define MEOW_F72_DSL_MAX 256
// F99 (.77): the largest binding number a layout may use and still be verifiable for safe set reuse.
#define MEOW_F72_MAX_BINDINGS 64
typedef struct {
    uint64_t orig;
    VkDescriptorSetLayout mirror;   // == orig when the push bit is absent; 0 = not simulatable
    uint32_t flags;
    uint32_t bindings;
    int ownsMirror;
    int pushBit;
    // F99 (.77): the layout's binding set, captured so a push can be PROVEN to overwrite all of it
    // before its set is ever reused (see meow_f72_push_covers). covmask = bitmask of binding numbers;
    // bdesc[b] = that binding's descriptorCount (0 = binding absent); unverifiable = never reuse.
    uint64_t covmask;
    int unverifiable;
    uint16_t bdesc[MEOW_F72_MAX_BINDINGS];
} MeowF72DslSlot;
static MeowF72DslSlot g_f72_dsl[MEOW_F72_DSL_MAX];
static unsigned long g_f72_dsl_evicts, g_f72_dsl_logged;

static MeowF72DslSlot* meow_f72_dsl_find(uint64_t key) {
    // F87 (.65): last-hit cache, validated against the table before use. forget/evict memsets or
    // memmoves slots, but the remembered index must still carry `key` or the unchanged full scan runs.
    static int s_last = -1;
    static uint64_t s_last_key = 0;
    // F91 (M1 race, review A39 F2): snapshot into locals, then re-check the entry's OWN key before
    // using it. Single-thread result is unchanged; a concurrent s_last rewrite cannot misdirect it.
    int li = s_last;
    uint64_t lk = s_last_key;
    if (li >= 0 && lk == key && g_f72_dsl[li].orig == key)
        return &g_f72_dsl[li];
    for (int i = 0; i < MEOW_F72_DSL_MAX; i++) {
        if (g_f72_dsl[i].orig == key) {
            s_last = i;
            s_last_key = key;
            return &g_f72_dsl[i];
        }
    }
    return NULL;
}

static void meow_f72_dsl_log(const MeowF72DslSlot* s, int slot) {
    unsigned long n = ++g_f72_dsl_logged;
    if (meow_vk_verbose() || n <= 8ul || (n % 2000ul) == 0ul)
        MEOWLOGI("meowvulkan: F72b setLayout #%{public}lu flags=0x%{public}x pushBit=%{public}d bindings=%{public}u "
                 "slot=%{public}d mirror=%{public}s", n, s->flags, s->pushBit, s->bindings, slot,
                 (s->mirror != 0) ? (s->ownsMirror ? "created" : "identity") : "FAILED");
}

static void meow_f72_capture_dsl(const void* ci, void* orig) {
    if (!meow_f72_on() || ci == NULL || orig == NULL) return;
    uint64_t key = (uint64_t)(uintptr_t)orig;
    if (meow_f72_dsl_find(key) != NULL) return;
    const VkDescriptorSetLayoutCreateInfo* pci = (const VkDescriptorSetLayoutCreateInfo*)ci;
    int slot = -1;
    for (int i = 0; i < MEOW_F72_DSL_MAX; i++) {
        if (g_f72_dsl[i].orig == 0) { slot = i; break; }
    }
    if (slot < 0) {
        // Evict oldest; destroy its mirror when we own it.
        MeowF72DslSlot* old = &g_f72_dsl[0];
        if (old->ownsMirror && old->mirror != 0) {
            void (*dl)(void*, void*, const void*) =
                (void (*)(void*, void*, const void*))meow_f72_real("vkDestroyDescriptorSetLayout");
            if (dl != NULL) dl(g_dev_seen, old->mirror, NULL);
        }
        memmove(&g_f72_dsl[0], &g_f72_dsl[1], (MEOW_F72_DSL_MAX - 1) * sizeof(MeowF72DslSlot));
        memset(&g_f72_dsl[MEOW_F72_DSL_MAX - 1], 0, sizeof(MeowF72DslSlot));
        slot = MEOW_F72_DSL_MAX - 1;
        unsigned long e = ++g_f72_dsl_evicts;
        if (e <= 4ul || (e % 2000ul) == 0ul)
            MEOWLOGW("meowvulkan: F72b mirror table full (%{public}d); evicted oldest (evict#%{public}lu)",
                     MEOW_F72_DSL_MAX, e);
    }
    MeowF72DslSlot* s = &g_f72_dsl[slot];
    s->orig = key;
    s->flags = pci->flags;
    s->bindings = pci->bindingCount;
    // F99 (.77): capture the binding set (numbers + per-binding descriptorCount) so a push can be
    // PROVEN to overwrite the whole layout before its set is ever reused. Anything unverifiable
    // (binding >= MEOW_F72_MAX_BINDINGS, descriptorCount 0, empty set) is marked and never reused.
    s->covmask = 0;
    s->unverifiable = 0;
    memset(s->bdesc, 0, sizeof(s->bdesc));
    if (pci->pBindings != NULL) {
        for (uint32_t j = 0; j < pci->bindingCount; j++) {
            uint32_t b = pci->pBindings[j].binding;
            uint32_t dc = pci->pBindings[j].descriptorCount;
            if (b >= MEOW_F72_MAX_BINDINGS || dc == 0 || dc > 0xffffu) {
                s->unverifiable = 1;
                continue;
            }
            s->covmask |= (1ull << b);
            s->bdesc[b] = (uint16_t)dc;
        }
    }
    if (s->covmask == 0) s->unverifiable = 1;
    s->pushBit = (pci->flags & (uint32_t)VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR) ? 1 : 0;
    s->mirror = 0;
    s->ownsMirror = 0;
    if (!s->pushBit) {
        s->mirror = (VkDescriptorSetLayout)orig;   // already allocatable: no mirror object needed
    } else {
        typedef int (*PFN_createDsl)(void*, const void*, const void*, void**);
        PFN_createDsl cd = (PFN_createDsl)meow_f72_real("vkCreateDescriptorSetLayout");
        if (cd != NULL) {
            VkDescriptorSetLayoutCreateInfo mci = *pci;
            mci.flags = pci->flags & ~((uint32_t)VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR);
            VkDescriptorSetLayout mirror = VK_NULL_HANDLE;
            int mrc = cd(g_dev_seen, &mci, NULL, (void**)&mirror);
            if (mrc == 0 && mirror != VK_NULL_HANDLE) {
                s->mirror = mirror;
                s->ownsMirror = 1;
            } else {
                MEOWLOGW("meowvulkan: F72b mirror vkCreateDescriptorSetLayout failed rc=%{public}d", mrc);
            }
        } else {
            MEOWLOGW("meowvulkan: F72b cannot resolve vkCreateDescriptorSetLayout for the mirror");
        }
    }
    meow_f72_dsl_log(s, slot);
}

static VkDescriptorSetLayout meow_f72_mirror_of(VkDescriptorSetLayout dsl) {
    if (dsl == VK_NULL_HANDLE) return VK_NULL_HANDLE;
    MeowF72DslSlot* s = meow_f72_dsl_find((uint64_t)(uintptr_t)dsl);
    if (s == NULL) return VK_NULL_HANDLE;
    return s->mirror;
}

static void meow_f72_forget_dsl(uint64_t key) {
    MeowF72DslSlot* s = meow_f72_dsl_find(key);
    if (s == NULL) return;
    if (s->ownsMirror && s->mirror != 0) {
        void (*dl)(void*, void*, const void*) =
            (void (*)(void*, void*, const void*))meow_f72_real("vkDestroyDescriptorSetLayout");
        if (dl != NULL) dl(g_dev_seen, s->mirror, NULL);
    }
    memset(s, 0, sizeof(*s));
}

// F99 (.77, invariant I5): may a set carrying this layout be REUSED for the given push? A reused set
// must be fully overwritten by the push that takes it, otherwise the bindings it does NOT write would
// still point at the previous generation's (possibly destroyed) buffers/images. Requires every layout
// binding to appear exactly once, at array element 0, with the layout's descriptorCount. Returns 0
// (= do not reuse; caller allocates fresh, exactly like the ring-off path) whenever it cannot verify.
static int meow_f72_push_covers(const MeowF72DslSlot* s, uint32_t n, const void* writes) {
    if (s == NULL || s->unverifiable || s->covmask == 0) return 0;
    const VkWriteDescriptorSet* w = (const VkWriteDescriptorSet*)writes;
    uint64_t seen = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t b = w[i].dstBinding;
        if (b >= MEOW_F72_MAX_BINDINGS) return 0;
        if (s->bdesc[b] == 0) return 0;                              // binding not in this layout
        if (w[i].dstArrayElement != 0) return 0;                     // partial array write
        if (w[i].descriptorCount != (uint32_t)s->bdesc[b]) return 0;  // count must match the layout
        seen |= (1ull << b);
    }
    return (seen == s->covmask) ? 1 : 0;
}

// ------------------------------------------------------------------ rotating descriptor pools
// F90 (.68 f72-drop-reuse): the F89 free-list layer is REMOVED. This is the `.65` acquire path again,
// which the device proved bounded (14.52M pushes -> pools=27, resets=66048):
//   * every push does a real vkAllocateDescriptorSets from the current pool;
//   * a pool is left for another one ONLY when its capacity is exhausted
//     (nsets >= MEOW_F72_MAXSETS, or the driver returns VK_ERROR_OUT_OF_POOL_MEMORY);
//   * a pending pool is reusable only after the fence of the submit that used it has SIGNALED, and
//     reuse is then a WHOLE-POOL vkResetDescriptorPool (meow_f72_reset_pool) -- the pool reset, not a
//     free list, is what bounds the pool count.
// No per-pool set table / free list exists any more, so there is no reclaim/reuse counter to report
// either: the whole-pool reset (`resets`) is the only reclaim signal (F91 removed the two dead fields).
typedef struct {
    VkDescriptorPool pool;
    VkFence fence;     // fence covering the submit that last used this pool (0 = unknown)
    int ownsFence;     // 1 = the shim created it (shared; ref-counted via g_f72_owned_refs)
    int pending;       // 1 = a submit using this pool has not been confirmed complete
    int used;          // 1 = already used for the frame currently being recorded
    int nsets;         // sets allocated since this pool's last reset (0 .. MEOW_F72_MAXSETS)
    // F92 (.70, invariant-I1 companion): one-way "this pool's fence was observed signaled". Set only
    // from a real vkGetFenceStatus success; cleared whenever the pool gets a new fence (pool_release)
    // so a reused pool can never carry a stale completion bit.
    int fenceSignaled;
    // F92 (.70, MEOW_VK_F72_RING=1 only): free table + current-generation issue list. Untouched
    // (and never read/written) when the ring is off.
    MeowF72SetRef ring[MEOW_F72_MAXSETS];      // reuse candidates, valid only at a proven boundary
    int ringCount;
    MeowF72SetRef issued[MEOW_F72_MAXSETS];    // sets issued since the last recycle boundary
    int issuedCount;
} MeowF72Pool;
static MeowF72Pool g_f72_pools[MEOW_F72_NPOOLS];   // MEOW_F72_NPOOLS == hard cap
static int g_f72_npools;                           // pools created so far (grow-on-demand)
static int g_f72_active = -1;                 // pool used for the frame being recorded; -1 = none
// F90 counters (totals line): emulated/forwarded = outcome of every push; pools = created pools;
// resets = whole-pool vkResetDescriptorPool calls (the .65 reclaim path, ~once per frame); grow = new
// pools created; allocs = every real vkAllocateDescriptorSets success (expected ~= emulated).
// F91: the two always-0 status fields were removed -- they had no producer and reading them against
// the old F89 acceptance table invited misreads.
static unsigned long g_f72_emulated, g_f72_forwarded, g_f72_resets, g_f72_grows;
static unsigned long g_f72_allocs;
// F92 (.70): ring-reuse counters (printed on the existing F72b totals line). Both stay 0 unless
// MEOW_VK_F72_RING=1. ring_misses counts a real vkAllocateDescriptorSets caused by an empty/mismatched
// free table (I2: that alone never rotates the pool).
static unsigned long g_f72_ring_hits, g_f72_ring_misses;
// F99 (.77): pushes whose writes did NOT provably cover their layout -> reuse refused (the set is
// allocated fresh and never recorded as reusable). Stays 0 for a well-behaved caller.
static unsigned long g_f72_ring_gate_reject;
// F101 (.79 wait-counters): W1-P0 wait accounting (W1 verdict: F69's wait is already the narrowest;
// the open question is whether the F60 whole-queue drain fires every frame -- never counted before).
// Counters only: no branch, no wait duration and no env changes. Incremented in log_WaitSemaphores /
// log_GetSemaphoreCounterValue; printed on the existing F72b totals line (same print point).
static unsigned long g_wait_calls, g_wait_f69, g_wait_f60_drain, g_wait_fwd;
static unsigned long g_wait_fence_ms, g_wait_drain_ms;   // cumulative wall time, ms
static unsigned long g_gscv_calls;                       // vkGetSemaphoreCounterValue polls
// F93 (.71 fix-pool-reclaim): why meow_f72_pool_free() refused a pending pool, tallied on the SAME
// F72b totals line (no new print point). Healthy default path => all three stay ~0; if a regression
// returns, exactly one of them grows and names the cause in the log itself:
//   reclaim_fail_nofence     -> the pool never got a fence (F91 owned-fence path regressed)
//   reclaim_fail_noquery     -> vkGetFenceStatus could not be resolved (both cached and uncached)
//   reclaim_fail_notsignaled -> the fence is real but the driver says it has not signaled yet
static unsigned long g_f72_reclaim_fail_nofence, g_f72_reclaim_fail_noquery, g_f72_reclaim_fail_notsignaled;
// F94 (A, build 2026-09-19.72 pool-fence-fix): CLASSIFY the vkGetFenceStatus result instead of
// collapsing every non-success into "notsignaled". Tallied on the SAME F72b totals line (no new print
// point). Decision key for the next device run:
//   reclaim_status_notready -> a REAL, live fence that simply has not completed yet (I1: keep waiting)
//   reclaim_status_error    -> the query returned a real error code (e.g. DEVICE_LOST) or an invalid
//                              handle -> the fence is unusable; reclaim must come from a queue-idle
//                              boundary, not from this fence
//   reclaim_status_proven   -> successful reclaim gates (fence observed VK_SUCCESS). Must grow.
static unsigned long g_f72_reclaim_status_notready, g_f72_reclaim_status_error, g_f72_reclaim_status_proven;
// F94 (A)/F96: number of (used pool -> pending) registrations performed by a SUCCESSFUL real submit,
// summed over every used pool of that submit. Semantics: with the normal one-pool-per-frame workload
// it grows by exactly +1 per submitted frame (a frame that filled and rotated through K pools binds
// K). It must track the frame count. If it freezes while grow climbs, the frame's pools never became
// pending (no submit registered them) -- the "池永不回收" root the F94/F95/F96 counters discriminate.
static unsigned long g_f72_bind_pools;
// F93 (B): consecutive creations with no successful reclaim. The F91 valve also fires when this
// reaches MEOW_F72_EARLY_RECLAIM_GROWS; cleared in meow_f72_pool_release() (every reclaim goes there).
static int g_f72_grow_streak;
// F95 (.73 fix-cap-saturation): DISCRIMINATING counters for the "reclaim froze at ~35" contract.
// WHY: the three F94 counters (resets / reclaim_status_proven / bind_pools) freeze TOGETHER while
// grow/pools keep climbing one per ~256 pushes. That signature has exactly two code-level worlds:
//   (W1) meow_f72_bind_submit() is reached but ok==0 (the submit failed) -> bind_fail grows and no
//        pool ever becomes `pending`; full pools stay non-pending and are re-selected, so each frame
//        grows one pool. This is the world the F95 boundedness fix targets.
//   (W2) meow_f72_bind_submit() is never reached (used stays set) -> no pending pool at all; grow
//        continues and no reuse is possible. The only shim-side bound then is the proven-idle valve.
// Each field names exactly which fixed table / path saturated on the NEXT device run, on the SAME
// `F72b push totals` line (no new print point):
//   bind_fail      -> (W1): submits started failing (ok==0) -- with used pools present.
//   fence0_bind    -> pools moved used->pending with NO completion fence (fence==0 => pinned).
//   dead_full_skip -> a full, non-pending pool was skipped by the scan (stranded capacity).
//   stranded_reset -> a non-pending pool with leftover sets was reclaimed at a proven queue-idle.
//   borrow_full    -> the F78 borrow table (MEOW_F69_MAX_BORROWS) rejected a borrow (table saturated).
//   f69_evict      -> the F69 map (MEOW_F69_MAX_ENTRIES) evicted an entry/fence (table saturated).
// g_f95_borrow_full is declared next to the F78 borrow table (defined before its user).
static unsigned long g_f95_bind_fail, g_f95_fence0_bind, g_f95_dead_full_skip, g_f95_stranded_reset;

// R1 (kept from F88): per-push scratch for the VkWriteDescriptorSet copy. vkUpdateDescriptorSets is a host-side
// device command: it consumes pDescriptorWrites (and the image/buffer arrays it points to) DURING the
// call and must not dereference it afterwards (Vulkan parameter-lifetime rules for a non-queue
// command), so this buffer is reusable as soon as the call returns. 64 entries cover the whole
// session (every logged push is n=6); anything larger keeps the original malloc fallback -- the
// buffer is never a truncation point. Same single-render-thread assumption as every other F72 global.
#define MEOW_F72_WRITES_SCRATCH 64
static VkWriteDescriptorSet g_f72_writes[MEOW_F72_WRITES_SCRATCH];

// F72c: at most ONE shim-owned tracking fence may be outstanding (created only when no F69/caller
// fence exists); g_f72_owned_refs counts the pending pools still referencing it.
static VkFence g_f72_owned_fence = VK_NULL_HANDLE;
static int g_f72_owned_refs;

static VkDescriptorPool meow_f72_create_pool(void) {
    int (*create)(void*, const void*, const void*, void**) =
        (int (*)(void*, const void*, const void*, void**))meow_f72_real("vkCreateDescriptorPool");
    if (create == NULL) return VK_NULL_HANDLE;
    static const VkDescriptorType kTypes[] = {
        VK_DESCRIPTOR_TYPE_SAMPLER, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER,
        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC,
        VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
    };
    const uint32_t nt = (uint32_t)(sizeof(kTypes) / sizeof(kTypes[0]));
    VkDescriptorPoolSize sizes[sizeof(kTypes) / sizeof(kTypes[0])];
    for (uint32_t i = 0; i < nt; i++) {
        sizes[i].type = kTypes[i];
        sizes[i].descriptorCount = (uint32_t)MEOW_F72_MAXSETS * (uint32_t)MEOW_F72_PER_TYPE;
    }
    VkDescriptorPoolCreateInfo pci;
    memset(&pci, 0, sizeof(pci));
    pci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pci.pNext = NULL;
    pci.flags = 0;
    pci.maxSets = (uint32_t)MEOW_F72_MAXSETS;
    pci.poolSizeCount = nt;
    pci.pPoolSizes = sizes;
    VkDescriptorPool p = VK_NULL_HANDLE;
    int rc = create(g_dev_seen, &pci, NULL, (void**)&p);
    if (rc != 0 || p == VK_NULL_HANDLE) {
        MEOWLOGW("meowvulkan: F72 vkCreateDescriptorPool failed rc=%{public}d", rc);
        return VK_NULL_HANDLE;
    }
    return p;
}

static VkFence meow_f72_track_fence_create(void) {
    MeowF69PFN_createFence cf = meow_f69_createFence();
    if (cf == NULL) return VK_NULL_HANDLE;
    VkFenceCreateInfo fci;
    memset(&fci, 0, sizeof(fci));
    fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fci.pNext = NULL;
    fci.flags = 0;
    VkFence f = VK_NULL_HANDLE;
    if (cf(g_dev_seen, &fci, NULL, (void**)&f) != 0) return VK_NULL_HANDLE;
    return f;
}

// F72c: tail of the reset path -- release the tracking-fence reference and clear the lifecycle flags.
static void meow_f72_pool_release(int i) {
    MeowF72Pool* p = &g_f72_pools[i];
    // F72c: a shim-owned fence is shared by every pool used in the frame; destroy it only when the
    // last referencing pool has been released (no pool may call vkGetFenceStatus on a dead handle).
    if (p->ownsFence && p->fence != 0) {
        if (g_f72_owned_refs > 0) --g_f72_owned_refs;
        if (g_f72_owned_refs == 0 && g_f72_owned_fence == p->fence) {
            meow_f69_destroyFence((uint64_t)g_f72_owned_fence);
            g_f72_owned_fence = VK_NULL_HANDLE;
        }
    } else if (p->fence != 0) {
        // F78: this pool borrowed the F69/caller fence -- release that reference. The fence is
        // reaped here only if F69 has already relinquished it (see meow_f69_borrow_unref).
        meow_f69_borrow_unref((uint64_t)p->fence);
    }
    p->fence = 0;
    p->ownsFence = 0;
    p->pending = 0;
    // F92: a new fence (or none) invalidates the one-way completion bit -- never carry it across.
    p->fenceSignaled = 0;
    // F93 (B): this is the tail of BOTH reclaim paths (reset_pool / pool_recycle), so a pool having
    // actually been reclaimed resets the grow-without-reclaim streak.
    g_f72_grow_streak = 0;
}

// F92 (.70, ring ON only): the reclaim path. Reached ONLY where reset_pool is legal (=> pool fence
// SIGNALED, or a successful queue-idle), so I3 holds: the generation that produced every `issued`
// set is provably complete. Instead of invalidating them with vkResetDescriptorPool we return them
// to the free table. `nsets` is deliberately NOT cleared: it counts distinct driver allocations and
// keeps the pool bounded at MEOW_F72_MAXSETS exactly as before.
static int meow_f72_pool_recycle(int i) {
    MeowF72Pool* p = &g_f72_pools[i];
    for (int k = 0; k < p->issuedCount; k++) {
        if (p->ringCount < MEOW_F72_MAXSETS) p->ring[p->ringCount++] = p->issued[k];
    }
    p->issuedCount = 0;
    meow_f72_pool_release(i);
    return 0;
}

// F92: pop a reusable set carrying the EXACT mirror layout this push needs (0 = hit). A layout
// mismatch is a miss: a set allocated for another layout can never be bound for this push.
static int meow_f72_ring_take(int i, VkDescriptorSetLayout dsl, VkDescriptorSet* out) {
    MeowF72Pool* p = &g_f72_pools[i];
    for (int k = 0; k < p->ringCount; k++) {
        if (p->ring[k].layout != dsl) continue;
        *out = p->ring[k].set;
        p->ring[k] = p->ring[--p->ringCount];
        return 0;
    }
    return -1;
}

// F92 (I4): record a set as issued for the current generation. Called exactly once per successful
// acquire (ring hit OR fresh allocation), so a set is never in `ring` and `issued` at once.
static void meow_f72_ring_record_issued(int i, VkDescriptorSet set, VkDescriptorSetLayout dsl) {
    MeowF72Pool* p = &g_f72_pools[i];
    if (p->issuedCount < MEOW_F72_MAXSETS) {
        p->issued[p->issuedCount].set = set;
        p->issued[p->issuedCount].layout = dsl;
        ++p->issuedCount;
    }
}

// .65 reset path (F90: this IS the reclaim path again). A whole-pool vkResetDescriptorPool invalidates
// every set allocated from the pool, so it may only run once the fence of the pool's last submit has
// SIGNALED -- exactly the guard in meow_f72_pool_free(). `resets` counts these; it is the cadence the
// `.65` device run showed bounded (resets=66048 over 14.52M pushes, ~1 per frame).
static int meow_f72_reset_pool(int i) {
    // F92: ring ON shifts the same proven boundary from "reset" to "recycle"; ring OFF is byte-for-byte
    // the old function.
    if (meow_f72_ring_on()) return meow_f72_pool_recycle(i);
    int (*reset)(void*, void*, uint32_t) =
        (int (*)(void*, void*, uint32_t))meow_cached_proc(
            &meow_p_vkResetDescriptorPool, &meow_d_vkResetDescriptorPool, "vkResetDescriptorPool");
    if (reset == NULL) { meow_f72_warn("no-vkResetDescriptorPool", (long)i, 0); return -1; }
    int rc = reset(g_dev_seen, g_f72_pools[i].pool, 0);
    if (rc != 0) { meow_f72_warn("reset-pool-rc", (long)rc, (long)i); return -1; }
    // The reset implicitly frees every set -> the pool's allocation counter starts over.
    g_f72_pools[i].nsets = 0;
    meow_f72_pool_release(i);
    ++g_f72_resets;
    return 0;
}

// F94 (B, build 2026-09-19.72 pool-fence-fix): reclaim every PENDING pool at a proven completion
// boundary. Callable ONLY when the GPU is known idle (a successful vkQueueWaitIdle): that is a
// strictly STRONGER proof than any single fence signal, so resetting the pools' sets is legal and I1
// ("never treat an unproven completion as complete") is preserved. This is what bounds the pool count
// even when the borrowed/created completion fence is never observed SIGNALED: MC already drains the
// queue once per frame (F60, awaitSubmitCompletion -> vkWaitSemaphores -> vkQueueWaitIdle), so the
// reclaim now happens on that boundary instead of depending on the fragile per-pool fence query.
// Pools used by the frame currently being recorded are `used==1, pending==0` and are never touched.
static void meow_f72_reclaim_pending_now(void) {
    if (!meow_f72_on()) return;
    for (int i = 0; i < g_f72_npools; i++) {
        if (!g_f72_pools[i].pending) continue;
        (void)meow_f72_reset_pool(i);   // logs+skips a failure; the caller proved queue-idle
    }
}

// A pool may be reset only once the fence of its last submit has signaled. A pending pool with no
// fence is deliberately NOT reusable (we cannot prove the GPU is done).
static int meow_f72_pool_free(int i) {
    MeowF72Pool* p = &g_f72_pools[i];
    if (!p->pending) return 1;
    // F92 (I1 companion): reuse the one-way bit; it is only ever set from a real VK_SUCCESS query and
    // cleared when the pool's fence changes, so this never reports "done" without a driver proof.
    if (p->fenceSignaled) return 1;
    if (p->fence == 0) { ++g_f72_reclaim_fail_nofence; return 0; }
    MeowF69PFN_getFenceStatus gfs = meow_f69_getFenceStatus();
    // F93 (.71): the cached slot is an optimisation, not the only way to answer. If it failed, resolve
    // once through the uncached device path before declaring the pool unreclaimable -- a single NULL
    // resolution must never lock reclaim forever.
    if (gfs == NULL)
        gfs = (MeowF69PFN_getFenceStatus)(g_gdpa ? g_gdpa(g_dev_seen, "vkGetFenceStatus") : NULL);
    if (gfs == NULL) { ++g_f72_reclaim_fail_noquery; return 0; }
    // F94 (A): classify the result. VK_SUCCESS -> a real, proven completion. VK_NOT_READY -> live but
    // unfinished. Anything else (a negative VkResult, or an invalid/destroyed handle) -> the fence
    // cannot be used as a completion proof at all; the queue-idle boundary above is then the only
    // reclaim route. Neither failure mode is ever upgraded to "complete" (I1).
    int st = gfs(g_dev_seen, (uint64_t)p->fence);
    if (st == VK_SUCCESS) { p->fenceSignaled = 1; ++g_f72_reclaim_status_proven; return 1; }
    if (st == VK_NOT_READY) { ++g_f72_reclaim_status_notready; }
    else { ++g_f72_reclaim_status_error; }
    ++g_f72_reclaim_fail_notsignaled;
    return 0;
}

static int meow_f72_used_count(void) {
    int c = 0;
    for (int i = 0; i < g_f72_npools; i++) {
        if (g_f72_pools[i].used) ++c;
    }
    return c;
}

// F91 (.69): the pool-cap safety valve. Called by meow_f72_ensure_active() only when the scan found
// no free pool and pools are pinned (a pending pool with no fence) or the hard cap has been reached.
// It manufactures a PROVABLE completion boundary -- a real vkQueueWaitIdle on the same cached queue
// F60 already trusts -- and only then whole-pool-resets every pending pool. Rationale (invariant I2):
// a vkResetDescriptorPool invalidates the pool's sets, so it is legal only once the GPU no longer
// references them; queue-idle after all submits proves exactly that, without trusting a fence we do
// not have (the fence==0 pinning, review A40 F-02). Never routes the pool-cap case to the real
// vkCmdPushDescriptorSet (the historical device-losing path): we would rather stall once.
static int meow_f72_quiesce_and_reclaim(void) {
    if (g_meow_last_queue == NULL) return 0;
    int (*idle)(void*) = (int (*)(void*))meow_cached_proc(&meow_p_vkQueueWaitIdle, &meow_d_vkQueueWaitIdle, "vkQueueWaitIdle");
    if (idle == NULL) return 0;
    if (idle(g_meow_last_queue) != VK_SUCCESS) return 0;   // cannot prove completion -> touch nothing
    // F97 (.75): same proven-idle boundary -> every F69 fence submitted to this queue is complete.
    meow_f69_mark_queue_idle((uint64_t)(uintptr_t)g_meow_last_queue);
    // F95 (.73): vkQueueWaitIdle==VK_SUCCESS proves NO GPU work is in flight, which is a stronger
    // boundary than any single fence. It is therefore legal to reset not only `pending` pools but ALSO
    // a `!used` pool that is stranded with leftover sets and was never successfully bound (`pending`
    // never set -- e.g. a frame whose submit was rejected, world W1). Those pools are invisible to the
    // fence path forever (pool_free only ever runs on `pending` pools) and are exactly the ones that
    // make the allocator grow a new pool per ~MEOW_F72_MAXSETS pushes. A pool used by the frame being
    // recorded has `used==1` and is NEVER touched here (invariant: no reset of in-flight sets).
    for (int i = 0; i < g_f72_npools; i++) {
        if (g_f72_pools[i].used) continue;                                       // frame being recorded
        if (!g_f72_pools[i].pending && g_f72_pools[i].nsets == 0) continue;      // nothing to reclaim
        int stranded = !g_f72_pools[i].pending;
        if (meow_f72_reset_pool(i) == 0 && stranded) ++g_f95_stranded_reset;
    }
    return 1;
}

// F72c/.65: pick the pool for the next allocation. (1) first RECLAIM (whole-pool reset) every pending
// pool whose fence has signaled; (2) pick a free pool not already used by this frame; (3) if none is
// free, GROW by one pool (hard cap MEOW_F72_NPOOLS); (4) F91 safety valve: if growing is blocked by
// pinned (fence==0) pools or the cap is reached, quiesce+reclaim first. Only a genuinely unavailable
// pool makes the push forward.
static int meow_f72_ensure_active(void) {
    if (g_f72_active >= 0 && g_f72_pools[g_f72_active].pool != VK_NULL_HANDLE) return g_f72_active;
    for (int i = 0; i < g_f72_npools; i++) {
        if (g_f72_pools[i].pending && meow_f72_pool_free(i)) {
            if (meow_f72_reset_pool(i) != 0) continue;
        }
    }
    // F95 (.73): a `!pending` pool that already holds MEOW_F72_MAXSETS sets is STRANDED capacity: it
    // was allocated in a frame that never produced a successful bind (world W1: submit rejected), so
    // pool_free() never runs on it and no reset ever frees it. Selecting it is a lie (it cannot hold
    // another set); it only makes pool_take_set() return 1 and forces the caller to grow. Detect it up
    // front so the F93 valve (a proven queue-idle boundary) can reclaim it instead of growing.
    int has_dead = 0;
    for (int i = 0; i < g_f72_npools; i++) {
        if (g_f72_pools[i].used) continue;
        if (!g_f72_pools[i].pending && g_f72_pools[i].nsets >= MEOW_F72_MAXSETS) { has_dead = 1; break; }
    }
    static int nextScan = 0;
    for (int k = 0; k < g_f72_npools; k++) {
        int i = nextScan;
        nextScan = (g_f72_npools > 0) ? ((nextScan + 1) % g_f72_npools) : 0;
        if (g_f72_pools[i].used) continue;              // already part of the current frame
        if (!meow_f72_pool_free(i)) continue;
        // F95: skip stranded full capacity (see has_dead above) -- it is reclaimed at the valve below.
        if (!g_f72_pools[i].pending && g_f72_pools[i].nsets >= MEOW_F72_MAXSETS) { ++g_f95_dead_full_skip; continue; }
        // F94 (B): never reuse a still-pending pool whose reset failed above -- it would carry its old
        // `nsets` (possibly already MEOW_F72_MAXSETS) into the new frame and force a spurious grow.
        if (g_f72_pools[i].pending && meow_f72_reset_pool(i) != 0) continue;
        if (g_f72_pools[i].pool == VK_NULL_HANDLE) {
            g_f72_pools[i].pool = meow_f72_create_pool();
            if (g_f72_pools[i].pool == VK_NULL_HANDLE) { meow_f72_warn("create-pool", (long)i, 0); return -1; }
            // F92: a freshly created pool starts with empty ring/issue tables (no stale reuse state).
            g_f72_pools[i].ringCount = 0;
            g_f72_pools[i].issuedCount = 0;
            g_f72_pools[i].fenceSignaled = 0;
            ++g_f72_grows;
            ++g_f72_grow_streak;   // F93 (B): count grows since the last successful reclaim
        }
        g_f72_pools[i].pending = 0;
        g_f72_pools[i].used = 1;
        g_f72_active = i;
        return i;
    }
    // F91 safety valve: no free pool. A pinned pool exists, or we are at the hard cap -> make a
    // completion boundary and reclaim, then retry the scan. Growth caused by pinning therefore never
    // costs a pool slot, so the count cannot creep to the cap.
    // F93 (B): ALSO fire after MEOW_F72_EARLY_RECLAIM_GROWS consecutive grows with no reclaim at all,
    // even when no pool is pinned and the cap is far away. That is what keeps the pool count bounded
    // if fence-signal reclaim is stuck (the .70 regression): we force a real vkQueueWaitIdle boundary
    // long before 64 and reclaim there.
    int pinned = 0;
    for (int i = 0; i < g_f72_npools; i++) {
        if (g_f72_pools[i].pending && g_f72_pools[i].fence == 0) { pinned = 1; break; }
    }
    // F95: `has_dead` forces the same proven-idle boundary for stranded (never-bound, full) pools, so
    // a string of rejected submits can never make the pool count bound over push count.
    if ((pinned || has_dead || g_f72_grow_streak >= MEOW_F72_EARLY_RECLAIM_GROWS ||
         g_f72_npools >= MEOW_F72_NPOOLS) && meow_f72_quiesce_and_reclaim()) {
        for (int k = 0; k < g_f72_npools; k++) {
            int i = nextScan;
            nextScan = (g_f72_npools > 0) ? ((nextScan + 1) % g_f72_npools) : 0;
            if (g_f72_pools[i].used) continue;
            if (g_f72_pools[i].pool == VK_NULL_HANDLE) continue;
            if (!meow_f72_pool_free(i)) continue;
            if (g_f72_pools[i].pending && meow_f72_reset_pool(i) != 0) continue;   // F94 (B)
            g_f72_pools[i].pending = 0;
            g_f72_pools[i].used = 1;
            g_f72_active = i;
            return i;
        }
    }
    if (g_f72_npools < MEOW_F72_NPOOLS) {
        int i = g_f72_npools;
        g_f72_pools[i].pool = meow_f72_create_pool();
        if (g_f72_pools[i].pool != VK_NULL_HANDLE) {
            g_f72_npools = i + 1;
            g_f72_pools[i].ringCount = 0;
            g_f72_pools[i].issuedCount = 0;
            g_f72_pools[i].fenceSignaled = 0;
            ++g_f72_grows;
            ++g_f72_grow_streak;   // F93 (B): count grows since the last successful reclaim
            g_f72_pools[i].pending = 0;
            g_f72_pools[i].used = 1;
            g_f72_active = i;
            return i;
        }
        meow_f72_warn("create-pool", (long)i, 0);
        return -1;
    }
    // F93 (B): never route the cap case back to the real vkCmdPushDescriptorSet (the historical
    // device-losing path). The F93 grow-streak valve above makes this unreachable in practice; if it
    // is ever reached (e.g. every pool belongs to the frame being recorded), stall on further proven
    // completion boundaries and retry the scan before conceding a forward.
    for (int attempt = 0; attempt < 8; attempt++) {
        if (!meow_f72_quiesce_and_reclaim()) break;
        for (int k = 0; k < g_f72_npools; k++) {
            int i = nextScan;
            nextScan = (g_f72_npools > 0) ? ((nextScan + 1) % g_f72_npools) : 0;
            if (g_f72_pools[i].used) continue;
            if (g_f72_pools[i].pool == VK_NULL_HANDLE) continue;
            if (!meow_f72_pool_free(i)) continue;
            if (g_f72_pools[i].pending && meow_f72_reset_pool(i) != 0) continue;   // F94 (B)
            g_f72_pools[i].pending = 0;
            g_f72_pools[i].used = 1;
            g_f72_active = i;
            return i;
        }
    }
    meow_f72_warn("no-free-pool", 0, 0);
    return -1;
}

// .65 acquire (F90): allocate a FRESH set from pool `i` for the current push. Returns 0 on success
// (++allocs), 1 when the pool's allocation capacity is exhausted (caller must rotate/grow), -1 on a
// real allocation failure (*allocRc holds the VkResult). There is no free list any more: the only
// lifetime end is the whole-pool reset in meow_f72_reset_pool, run once the pool's fence has signaled.
static int meow_f72_pool_take_set(int i, VkDescriptorSetLayout dsl,
                                  int (*alloc)(void*, const void*, void**),
                                  VkDescriptorSet* out, int* allocRc) {
    MeowF72Pool* p = &g_f72_pools[i];
    *allocRc = 0;
    if (p->nsets >= MEOW_F72_MAXSETS) return 1;   // capacity exhausted -> caller rotates to another pool
    VkDescriptorSetAllocateInfo ai;
    memset(&ai, 0, sizeof(ai));
    ai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    ai.pNext = NULL;
    ai.descriptorPool = p->pool;
    ai.descriptorSetCount = 1;
    ai.pSetLayouts = &dsl;
    VkDescriptorSet ds = VK_NULL_HANDLE;
    int rc = alloc(g_dev_seen, &ai, (void**)&ds);
    if (rc != 0 || ds == VK_NULL_HANDLE) { *allocRc = rc; return -1; }
    ++p->nsets;
    ++g_f72_allocs;
    *out = ds;
    return 0;
}

// F91 (.69): cover a submit that has no fence. Mirrors the F66 merged path's tracking-fence rule so
// the v1 vkQueueSubmit path is not asymmetric (review A40 F-02/F-08): if MC handed no fence and F69
// did not create one, make one shim-owned tracking fence (at most one outstanding, same throttle) so
// the pools used by this submit still become reclaimable. Returns the fence to hand to the submit.
static VkFence meow_f72_fence_for_submit(VkFence submitFence, int* ownsFence) {
    *ownsFence = 0;
    if (!meow_f72_on() || submitFence != 0) return submitFence;
    if (meow_f72_used_count() <= 0 || g_f72_owned_refs != 0) return submitFence;
    VkFence f = meow_f72_track_fence_create();
    if (f != 0) *ownsFence = 1;
    return f;
}

// Called at the submit point (F66 merged path, and the v1 wrapper for completeness). Associates EVERY
// pool used while recording this frame with the fence that covers the submit, then closes the frame.
static void meow_f72_bind_submit(VkFence submitFence, int ownsFence, int ok) {
    if (!meow_f72_on()) return;
    if (!ok) {
        if (ownsFence && submitFence != 0) meow_f69_destroyFence((uint64_t)submitFence);
        // F95 (.73): count a rejected submit that actually had used pools. This is the W1 signature:
        // bind_submit IS reached, but ok==0, so no pool ever becomes `pending` (proven/resets freeze)
        // and full pools are only ever reset by the proven-idle valve (stranded_reset). If this stays 0
        // while the three F94 counters freeze, the cause is W2 (bind_submit not reached at all).
        for (int i = 0; i < g_f72_npools; i++) { if (g_f72_pools[i].used) { ++g_f95_bind_fail; break; } }
        // F90: the submit was rejected, so no GPU work referenced this frame's sets. Just close the
        // frame; the pool (not pending) stays selected for the next frame and is reset only after a
        // later submit's fence signals -- its nsets carries on toward the cap in the meantime.
        for (int i = 0; i < g_f72_npools; i++) {
            // F92 (ring ON): a rejected submit is a trivially-proven completion (the GPU never saw
            // these sets), so return them to the free table now instead of letting `issued` accumulate.
            if (meow_f72_ring_on() && g_f72_pools[i].used) (void)meow_f72_pool_recycle(i);
            g_f72_pools[i].used = 0;
        }
        g_f72_active = -1;
        return;
    }
    if (ownsFence && submitFence != 0) g_f72_owned_fence = submitFence;
    for (int i = 0; i < g_f72_npools; i++) {
        if (!g_f72_pools[i].used) continue;
        g_f72_pools[i].used = 0;
        g_f72_pools[i].fence = submitFence;
        g_f72_pools[i].ownsFence = ownsFence;
        // F94 (build .72): a new fence invalidates the one-way completion bit AT THE WRITE SITE (F92's
        // lesson: a one-shot flag must be explicitly initialised where its owner is assigned). Without
        // this, a pool reused by the scan while a stale bit was still set would skip its fence query
        // for the NEW submit and could reset a pool the GPU is still using. pool_release() clears it
        // too; both are needed because the scan can reuse a pool without going through release.
        g_f72_pools[i].fenceSignaled = 0;
        g_f72_pools[i].pending = 1;
        if (ownsFence && submitFence != 0) ++g_f72_owned_refs;
        else if (submitFence != 0) meow_f69_borrow_ref((uint64_t)submitFence);   // F78
        else ++g_f95_fence0_bind;   // F95: used->pending with NO fence => pinned until a proven-idle valve
        ++g_f72_bind_pools;   // F94 (A): proves (used -> pending) actually happened
    }
    g_f72_active = -1;
}

// The emulation body. Returns 1 = recorded via the ordinary set path, 0 = nothing to do (no writes),
// -1 = must forward the original push (rate-limited WARN already emitted).
static int meow_f72_emulate_push_inner(void* cmd, uint32_t bindPoint, void* layout, uint32_t set,
                                       uint32_t n, const void* writes) {
    if (n == 0 || writes == NULL) return 0;
    if (n > 4096) { meow_f72_warn("too-many-writes", (long)n, (long)set); return -1; }
    VkDescriptorSetLayout dsl = meow_f72_lookup_dsl(layout, set);
    if (dsl == VK_NULL_HANDLE) {
        meow_f72_warn("layout-not-captured", (long)set, 0);
        return -1;
    }
    // F72b: allocate from the mirror (push bit removed); bind still uses the ORIGINAL pipeline layout.
    VkDescriptorSetLayout allocDsl = meow_f72_mirror_of(dsl);
    if (allocDsl == VK_NULL_HANDLE) {
        meow_f72_warn("no-mirror-layout", (long)set, 0);
        return -1;
    }
    int pi = meow_f72_ensure_active();
    if (pi < 0) return -1;
    int (*alloc)(void*, const void*, void**) =
        (int (*)(void*, const void*, void**))meow_cached_proc(
            &meow_p_vkAllocateDescriptorSets, &meow_d_vkAllocateDescriptorSets, "vkAllocateDescriptorSets");
    void (*update)(void*, uint32_t, const void*, uint32_t, const void*) =
        (void (*)(void*, uint32_t, const void*, uint32_t, const void*))meow_cached_proc(
            &meow_p_vkUpdateDescriptorSets, &meow_d_vkUpdateDescriptorSets, "vkUpdateDescriptorSets");
    void (*bind)(void*, uint32_t, void*, uint32_t, uint32_t, const void*, uint32_t, const void*) =
        (void (*)(void*, uint32_t, void*, uint32_t, uint32_t, const void*, uint32_t, const void*))
            meow_cached_proc(&meow_p_vkCmdBindDescriptorSets, &meow_d_vkCmdBindDescriptorSets,
                             "vkCmdBindDescriptorSets");
    if (alloc == NULL || update == NULL || bind == NULL) {
        meow_f72_warn("missing-forward", 0, 0);
        return -1;
    }
    // F90/.65 acquire, F92 (.70) ring, F99 (.77) default ON + coverage gate. I5: a set may only be
    // reused when THIS push provably overwrites the whole layout (meow_f72_push_covers); otherwise
    // reuse is refused and the code below is exactly the ring-off (fresh allocation) path.
    MeowF72DslSlot* covslot = meow_f72_dsl_find((uint64_t)(uintptr_t)dsl);
    int covered = meow_f72_push_covers(covslot, n, writes);
    int reuse_ok = meow_f72_ring_on() && covered;
    if (meow_f72_ring_on() && !covered) ++g_f72_ring_gate_reject;
    // Reuse (reuse_ok): first try the pool's free table for a set with the SAME mirror layout
    // (ring_hits); otherwise a real vkAllocateDescriptorSets (ring_misses). A pool is left ONLY on
    // capacity exhaustion / OUT_OF_POOL_MEMORY (I2) -- an empty free table never rotates a pool.
    VkDescriptorSet ds = VK_NULL_HANDLE;
    int arc = 0;
    int t = -1;
    if (reuse_ok && meow_f72_ring_take(pi, allocDsl, &ds) == 0) {
        ++g_f72_ring_hits;
        t = 0;
    } else {
        if (reuse_ok) ++g_f72_ring_misses;
        t = meow_f72_pool_take_set(pi, allocDsl, alloc, &ds, &arc);
        if (t == 1 || arc == VK_ERROR_OUT_OF_POOL_MEMORY) {
            g_f72_active = -1;
            int npi = meow_f72_ensure_active();
            if (npi >= 0 && npi != pi) {
                pi = npi;
                arc = 0;
                if (reuse_ok && meow_f72_ring_take(pi, allocDsl, &ds) == 0) {
                    ++g_f72_ring_hits;
                    t = 0;
                } else {
                    if (reuse_ok) ++g_f72_ring_misses;
                    t = meow_f72_pool_take_set(pi, allocDsl, alloc, &ds, &arc);
                }
            }
        }
    }
    if (t != 0) {
        // F72c: VkResult printed SIGNED (see the code table at meow_f72_warn).
        if (arc == 0) arc = VK_ERROR_OUT_OF_POOL_MEMORY;
        meow_f72_warn("allocate-set-failed", (long)arc, (long)set);
        return -1;
    }
    // F92 (I4) + F99 (I5): record the acquired set exactly once so meow_f72_pool_recycle() can return
    // it -- but ONLY when this push proved full coverage, so an unverified set is never handed back.
    if (reuse_ok) meow_f72_ring_record_issued(pi, ds, allocDsl);
    // R1 (kept from F88): reuse the file-scope scratch; only an over-capacity call falls back to malloc. The push
    // ignores dstSet, but vkUpdateDescriptorSets requires it -> copy and point every write at the set
    // just acquired. The pointed-to image/buffer arrays are consumed synchronously by the update call,
    // so no deep copy of those is needed.
    VkWriteDescriptorSet* wheap = NULL;
    VkWriteDescriptorSet* w;
    if (n <= (uint32_t)MEOW_F72_WRITES_SCRATCH) {
        w = g_f72_writes;
    } else {
        wheap = (VkWriteDescriptorSet*)malloc((size_t)n * sizeof(VkWriteDescriptorSet));
        if (wheap == NULL) { meow_f72_warn("oom-writes", (long)n, 0); return -1; }
        w = wheap;
    }
    memcpy(w, writes, (size_t)n * sizeof(VkWriteDescriptorSet));
    for (uint32_t i = 0; i < n; i++) w[i].dstSet = ds;
    update(g_dev_seen, n, w, 0, NULL);
    // Push descriptors carry no dynamic offsets (pDynamicOffsets is NULL / count 0).
    bind(cmd, bindPoint, layout, set, 1, &ds, 0, NULL);
    free(wheap);
    return 1;
}

// Public entry: counts the outcome and emits the F72c/F90 totals line under MEOW_VK_VERBOSE (or the
// MEOW_VK_TOTALS_SEC heartbeat); default silent since F104.
static int meow_f72_emulate_push(void* cmd, uint32_t bindPoint, void* layout, uint32_t set,
                                 uint32_t n, const void* writes) {
    int r = meow_f72_emulate_push_inner(cmd, bindPoint, layout, set, n, writes);
    if (r == 1) {
        // F86: the per-push MEOWLOGI line is deleted; the counter is still incremented for the totals.
        ++g_f72_emulated;
    } else {
        ++g_f72_forwarded;   // r == 0 (no writes) or -1 (failure): the original push is forwarded
    }
    // F104 (build 2026-09-23.83 quiet-f72b-totals): DEFAULT SILENT. The .76/.91 forwarded/grow
    // "change" trigger was NOT low-frequency in normal play: MC issues empty pushes (n==0 ->
    // forwarded++) about once per frame, and `g_f72_grows` also creeps, so a whole session printed
    // ~one totals line per forwarded increment (log 1790168149: forwarded 1290->3890 => 2601 lines).
    // The line now prints only (a) per call under the existing MEOW_VK_VERBOSE switch, or (b) on the
    // existing opt-in slow heartbeat MEOW_VK_TOTALS_SEC=<seconds>. No new env; the clock is read only
    // when (b) is set, and then at most once per 256 pushes. Same MEOWLOGI line, no new print point.
    // Real forward failures keep their own signal: meow_f72_warn() still names the first 4 and every
    // 4th/20000th reason (allocate-set-failed, layout-not-captured, ...).
    int f98_print = meow_vk_verbose();
    if (!f98_print) {
        static int f98_decided = 0, f98_secs = 0;
        static long long f98_next_ns = 0;
        if (!f98_decided) {
            f98_decided = 1;   // read the env once (process-wide; F87/F97 idiom)
            const char* f98_env = getenv("MEOW_VK_TOTALS_SEC");
            f98_secs = (f98_env != NULL) ? atoi(f98_env) : 0;
            if (f98_secs < 1) f98_secs = 0;   // absent/invalid/<=0 = OFF (default path unchanged)
        }
        if (f98_secs > 0 && (g_f72_emulated & 0xFFul) == 0ul) {
            long long f98_now = wd_now_ns();
            if (f98_next_ns == 0) {
                f98_next_ns = f98_now + (long long)f98_secs * 1000000000LL;
            } else if (f98_now >= f98_next_ns) {
                f98_print = 1;
                f98_next_ns = f98_now + (long long)f98_secs * 1000000000LL;
            }
        }
    }
    if (f98_print) {
        MEOWLOGI("meowvulkan: F72b push totals: emulated=%{public}lu forwarded=%{public}lu pools=%{public}d "
                 "resets=%{public}lu allocs=%{public}lu grow=%{public}lu ring_hits=%{public}lu ring_misses=%{public}lu "
                 "ring_gate_reject=%{public}lu "
                 "reclaim_fail_nofence=%{public}lu reclaim_fail_noquery=%{public}lu reclaim_fail_notsignaled=%{public}lu "
                 "reclaim_status_notready=%{public}lu reclaim_status_error=%{public}lu reclaim_status_proven=%{public}lu "
                 "bind_pools=%{public}lu "
                 // F95 (.73) saturation/rejection counters, same line, no new print point:
                 //   bind_fail      = rejected submits that had used pools (W1 discriminator)
                 //   fence0_bind    = used->pending with no fence (pin event)
                 //   dead_full_skip = stranded full non-pending pool skipped by the scan
                 //   stranded_reset = stranded pool reclaimed at a proven queue-idle boundary
                 //   borrow_full    = F78 borrow table (MEOW_F69_MAX_BORROWS) saturated
                 //   f69_evict      = F69 map (MEOW_F69_MAX_ENTRIES) saturated/evicted
                 "bind_fail=%{public}lu fence0_bind=%{public}lu dead_full_skip=%{public}lu stranded_reset=%{public}lu "
                 "borrow_full=%{public}lu f69_evict=%{public}lu "
                 // F101 (.79): W1-P0 wait accounting, same line, no new print point.
                 //   wait_calls / wait_f69 / wait_drain / wait_fwd = how the frame's waits were served
                 //   wait_fence_ms / wait_drain_ms = cumulative wall time in each wait
                 //   gscv = vkGetSemaphoreCounterValue polls (the per-fence query tax)
                 "wait_calls=%{public}lu wait_f69=%{public}lu wait_drain=%{public}lu wait_fwd=%{public}lu "
                 "wait_fence_ms=%{public}lu wait_drain_ms=%{public}lu gscv=%{public}lu",
                 g_f72_emulated, g_f72_forwarded, g_f72_npools, g_f72_resets, g_f72_allocs,
                 g_f72_grows, g_f72_ring_hits, g_f72_ring_misses, g_f72_ring_gate_reject,
                 g_f72_reclaim_fail_nofence, g_f72_reclaim_fail_noquery, g_f72_reclaim_fail_notsignaled,
                 g_f72_reclaim_status_notready, g_f72_reclaim_status_error, g_f72_reclaim_status_proven,
                 g_f72_bind_pools,
                 g_f95_bind_fail, g_f95_fence0_bind, g_f95_dead_full_skip, g_f95_stranded_reset,
                 g_f95_borrow_full, g_f69_evicts,
                 g_wait_calls, g_wait_f69, g_wait_f60_drain, g_wait_fwd,
                 g_wait_fence_ms, g_wait_drain_ms, g_gscv_calls);
    }
    return (r == 1) ? 1 : 0;
}

static void meow_f72_shutdown(void) {
    for (int i = 0; i < MEOW_F72_NPOOLS; i++) {
        if (g_f72_pools[i].pool != VK_NULL_HANDLE) {
            void (*dp)(void*, void*, const void*) =
                (void (*)(void*, void*, const void*))meow_f72_real("vkDestroyDescriptorPool");
            if (dp != NULL) dp(g_dev_seen, g_f72_pools[i].pool, NULL);
            g_f72_pools[i].pool = VK_NULL_HANDLE;
        }
        // F78: drop any borrow on an F69/caller fence before clearing the slot. meow_f69_forget_all()
        // has already run, so a borrowed fence whose F69 entry is gone is reaped here.
        if (g_f72_pools[i].fence != 0 && !g_f72_pools[i].ownsFence) {
            meow_f69_borrow_unref((uint64_t)g_f72_pools[i].fence);
        }
        g_f72_pools[i].fence = 0;
        g_f72_pools[i].ownsFence = 0;
        g_f72_pools[i].pending = 0;
        g_f72_pools[i].used = 0;
        g_f72_pools[i].nsets = 0;   // F90: the pool handle is gone; drop the allocation counter
        // F92: the pool handle is gone -> its ring/issue tables are meaningless. Clear them so a later
        // pool in this slot can never observe stale set handles.
        g_f72_pools[i].ringCount = 0;
        g_f72_pools[i].issuedCount = 0;
        g_f72_pools[i].fenceSignaled = 0;
    }
    // F72c: the shim-owned fence is shared, so destroy it exactly once.
    if (g_f72_owned_fence != VK_NULL_HANDLE) {
        meow_f69_destroyFence((uint64_t)g_f72_owned_fence);
        g_f72_owned_fence = VK_NULL_HANDLE;
    }
    g_f72_owned_refs = 0;
    g_f72_npools = 0;
    g_f72_active = -1;
    for (int i = 0; i < MEOW_F72_LAYOUTS; i++) {
        free(g_f72_layouts[i].sets);
        g_f72_layouts[i].sets = NULL;
        g_f72_layouts[i].layout = 0;
        g_f72_layouts[i].count = 0;
    }
    // F72b: destroy every mirror set layout we created.
    for (int i = 0; i < MEOW_F72_DSL_MAX; i++) {
        if (g_f72_dsl[i].ownsMirror && g_f72_dsl[i].mirror != 0) {
            void (*dl)(void*, void*, const void*) =
                (void (*)(void*, void*, const void*))meow_f72_real("vkDestroyDescriptorSetLayout");
            if (dl != NULL) dl(g_dev_seen, g_f72_dsl[i].mirror, NULL);
        }
        memset(&g_f72_dsl[i], 0, sizeof(g_f72_dsl[i]));
    }
}

static int meow_translate_queue_submit2(void* queue, uint32_t submitCount, const void* submits,
                                        uint64_t fence) {
    int (*realSubmit)(void*, uint32_t, const void*, uint64_t) =
        (int (*)(void*, uint32_t, const void*, uint64_t))(meow_cached_proc(&meow_p_vkQueueSubmit, &meow_d_vkQueueSubmit, "vkQueueSubmit"));
    if (realSubmit == NULL) {
        MEOWLOGE("meowvulkan: SYNC2->V1: cannot resolve the real vkQueueSubmit");
        return -3;
    }
    // F75 env-cleanup: the F50 host-side timeline signal (and its MEOW_VK_TIMELINE_HOST_SIGNAL gate)
    // was removed here; real GPU-completion is provided by F69 (timeline-as-fence).
    if (submitCount == 0) {
        // F45: emit the self-proof line for the zero-submit path too. Previously this early
        // return forwarded with NO "SYNC2->V1 translate ..." line, so "the translation did not
        // run" and "there was nothing to translate" were indistinguishable in the log.
        int rc0 = realSubmit(queue, 0, NULL, fence);
        unsigned long subN0 = ++g_sync2v1_submits;
        if (meow_vk_verbose() || rc0 != 0) {
            MEOWLOGI("meowvulkan: SYNC2->V1 translate vkQueueSubmit2 -> vkQueueSubmit #%{public}lu "
                     "submits=0 waits=0 cmdBufs=0 signals=0 timelineChains=0 foldedMaskBits=0 diverged=0 "
                     "rc=%{public}d fence=0x%{public}llx rcSeq=%{public}d",
                     subN0, rc0, (unsigned long long)fence, rc0);
        }
        return rc0;
    }
    const VkSubmitInfo2L* s = (const VkSubmitInfo2L*)submits;
    if (s == NULL || submitCount > 64) {
        MEOWLOGW("meowvulkan: SYNC2->V1: refusing to translate vkQueueSubmit2 (submitCount=%{public}u ptr=%{public}p)",
                 submitCount, submits);
        return -3;
    }
    // F49: one VkSubmitInfo + one MeowSubmit2Tr per vkQueueSubmit2 entry; N single-entry calls.
    // F97 (.75): submitCount is capped at 64 above, so both arrays come from the file-level reusable
    // scratch; consumed by the synchronous vkQueueSubmit calls and dead afterwards (see the F97 block).
    MeowSubmit2Tr* st = g_f97_st;
    VkSubmitInfoL* outs = g_f97_outs;
    memset(st, 0, (size_t)submitCount * sizeof(MeowSubmit2Tr));
    memset(outs, 0, (size_t)submitCount * sizeof(VkSubmitInfoL));
    uint32_t totalWaits = 0, totalCmds = 0, totalSignals = 0;
    uint32_t timelineChains = 0, waitDstMask0 = 0;
    int haveMask0 = 0, lostBits = 0, ok = 1;
    // Pass 1: per-entry bounds check, running totals, per-entry array allocation.
    for (uint32_t i = 0; i < submitCount && ok; i++) {
        uint32_t wc = s[i].waitSemaphoreInfoCount;
        uint32_t cc = s[i].commandBufferInfoCount;
        uint32_t sc = s[i].signalSemaphoreInfoCount;
        if (wc > 4096 || cc > 4096 || sc > 4096) { ok = 0; break; }
        totalWaits += wc;
        totalCmds += cc;
        totalSignals += sc;
        MeowSubmit2Tr* e = &st[i];
        // F97: the common case (every MC entry) fits the scratch; a larger entry falls back to the
        // original calloc for ALL of its arrays so the free path stays all-or-nothing per entry.
        if (wc <= MEOW_F97_CAP && cc <= MEOW_F97_CAP && sc <= MEOW_F97_CAP) {
            e->scratch = 1;
            if (wc > 0) {
                e->waitSems = g_f97_e_wsems[i];
                e->waitStages = g_f97_e_wstages[i];
                e->waitVals = g_f97_e_wvals[i];
            }
            if (cc > 0) e->cmdBufs = g_f97_e_cmds[i];
            if (sc > 0) {
                e->sigSems = g_f97_e_ssems[i];
                e->sigVals = g_f97_e_svals[i];
            }
        } else {
            e->scratch = 0;
            if (wc > 0) {
                e->waitSems = (VkSemaphore*)calloc(wc, sizeof(VkSemaphore));
                e->waitStages = (uint32_t*)calloc(wc, sizeof(uint32_t));
                e->waitVals = (uint64_t*)calloc(wc, sizeof(uint64_t));
                if (e->waitSems == NULL || e->waitStages == NULL || e->waitVals == NULL) ok = 0;
            }
            if (ok && cc > 0) {
                e->cmdBufs = (VkCommandBuffer*)calloc(cc, sizeof(VkCommandBuffer));
                if (e->cmdBufs == NULL) ok = 0;
            }
            if (ok && sc > 0) {
                e->sigSems = (VkSemaphore*)calloc(sc, sizeof(VkSemaphore));
                e->sigVals = (uint64_t*)calloc(sc, sizeof(uint64_t));
                if (e->sigSems == NULL || e->sigVals == NULL) ok = 0;
            }
        }
    }
    // Pass 2: fill each entry's own VkSubmitInfo in original entry/index order.
    for (uint32_t i = 0; i < submitCount && ok; i++) {
        const VkSubmitInfo2L* ent = &s[i];
        MeowSubmit2Tr* e = &st[i];
        VkSubmitInfoL* out = &outs[i];
        for (uint32_t k = 0; k < ent->waitSemaphoreInfoCount; k++) {
            const VkSemaphoreSubmitInfoL* w = &ent->pWaitSemaphoreInfos[k];
            uint32_t sm = meow_stage2_to_v1(w->stageMask, &lostBits);
            if (sm == 0) sm = 0x00010000u;   /* v1 wait stage must be a real stage */
            e->waitSems[k] = w->semaphore;
            e->waitStages[k] = sm;
            e->waitVals[k] = w->value;
            if (w->value != 0) e->useTsi = 1;   /* timeline wait */
            if (!haveMask0) { waitDstMask0 = sm; haveMask0 = 1; }
        }
        for (uint32_t k = 0; k < ent->commandBufferInfoCount; k++) {
            e->cmdBufs[k] = ent->pCommandBufferInfos[k].commandBuffer;
        }
        for (uint32_t k = 0; k < ent->signalSemaphoreInfoCount; k++) {
            const VkSemaphoreSubmitInfoL* g = &ent->pSignalSemaphoreInfos[k];
            e->sigSems[k] = g->semaphore;
            e->sigVals[k] = g->value;
            if (g->value != 0) e->useTsi = 1;   /* timeline signal */
        }
        // v1 VkSubmitInfo has NO flags field, so VkSubmitInfo2.flags cannot be carried;
        // VK_SUBMIT_PROTECTED_BIT (0x1) is the only bit both define. Anything else is
        // dropped -- the only reachable oddity here is a protected submit, never seen.
        if (ent->flags != 0) {
            MEOWLOGW("meowvulkan: SYNC2->V1: VkSubmitInfo2.flags=0x%{public}x dropped (no v1 field)",
                     ent->flags);
        }
        out->sType = ST_SUBMIT_INFO;
        out->waitSemaphoreCount = ent->waitSemaphoreInfoCount;
        out->pWaitSemaphores = (ent->waitSemaphoreInfoCount > 0) ? e->waitSems : NULL;
        out->pWaitDstStageMask = (ent->waitSemaphoreInfoCount > 0) ? e->waitStages : NULL;
        out->commandBufferCount = ent->commandBufferInfoCount;
        out->pCommandBuffers = (ent->commandBufferInfoCount > 0) ? e->cmdBufs : NULL;
        out->signalSemaphoreCount = ent->signalSemaphoreInfoCount;
        out->pSignalSemaphores = (ent->signalSemaphoreInfoCount > 0) ? e->sigSems : NULL;
        if (e->useTsi) {
            e->tsi.sType = ST_TIMELINE_SEMAPHORE_SUBMIT_INFO;
            e->tsi.pNext = NULL;   /* never forward a synchronization2 pNext chain into v1 */
            e->tsi.waitSemaphoreValueCount = ent->waitSemaphoreInfoCount;
            e->tsi.pWaitSemaphoreValues = (ent->waitSemaphoreInfoCount > 0) ? e->waitVals : NULL;
            e->tsi.signalSemaphoreValueCount = ent->signalSemaphoreInfoCount;
            e->tsi.pSignalSemaphoreValues = (ent->signalSemaphoreInfoCount > 0) ? e->sigVals : NULL;
            out->pNext = &e->tsi;
            ++timelineChains;
        }
    }
    int rc = -3;
    int rcSeq[64];
    int firstErr = 0;
    uint32_t issued = 0, stoppedAt = 0, firstErrAt = 0;
    char rcseq[512];
    rcseq[0] = '\0';
    // F66: merge (default) vs the F49 N-call split. `merged` records which path actually ran so
    // the self-proof line can say so and `diverged` stays meaningful (merged=1 => not a regression).
    const char* mergeWhy = NULL;
    int doMerge = meow_sync2v1_merge_decide(&mergeWhy);
    int merged = 0;
    // F69: reported by the self-proof line below (set only on the merged path).
    uint32_t f69SigN = 0, f69WaitN = 0;
    int f69Active = 0, f69OwnFence = 0;
    uint64_t f69FenceUsed = 0;
    if (ok) {
        // F49: N calls, each submitCount=1 with its own entry. The caller's fence is passed to
        // EVERY call (NOT only the last). A VkFence may be referenced by several queue submissions
        // and is signaled only once ALL of them complete, so this preserves the original
        // single-vkQueueSubmit2 semantics, where the one fence covered the whole batch. Passing it
        // only on the last call would let the host observe an earlier entry still in flight when
        // the fence signals (the log shows entry[0] signals nothing that entry[1] waits on), so
        // the last-only shortcut is deliberately NOT used.
        // F51: do NOT break on the first non-zero rc. Every entry still gets its own single-entry
        // vkQueueSubmit, so `submits` (== issued) always equals `submitsIn`; the FIRST error is kept
        // as the returned rc. (A break here was the last path that could log submits<submitsIn; it
        // was an early stop, not a fold -- see the F51 note above the function.)
        if (doMerge) {
            // F66: ONE merged v1 submit. See the meow_sync2v1_merge_decide note above for the
            // on-device evidence that this ICD rejects the second entry of a multi-entry batch.
            // F97 (.75): totals fit the scratch -> reuse it; otherwise the original calloc, freed below.
            const int mScratch = (totalWaits <= MEOW_F97_CAP && totalCmds <= MEOW_F97_CAP &&
                                  totalSignals <= MEOW_F97_CAP);
            VkSemaphore* mwSems = (totalWaits > 0) ? (mScratch ? g_f97_m_wsems : (VkSemaphore*)calloc(totalWaits, sizeof(VkSemaphore))) : NULL;
            uint32_t* mwStages = (totalWaits > 0) ? (mScratch ? g_f97_m_wstages : (uint32_t*)calloc(totalWaits, sizeof(uint32_t))) : NULL;
            uint64_t* mwVals = (totalWaits > 0) ? (mScratch ? g_f97_m_wvals : (uint64_t*)calloc(totalWaits, sizeof(uint64_t))) : NULL;
            VkCommandBuffer* mCBs = (totalCmds > 0) ? (mScratch ? g_f97_m_cmds : (VkCommandBuffer*)calloc(totalCmds, sizeof(VkCommandBuffer))) : NULL;
            VkSemaphore* msSems = (totalSignals > 0) ? (mScratch ? g_f97_m_ssems : (VkSemaphore*)calloc(totalSignals, sizeof(VkSemaphore))) : NULL;
            uint64_t* msVals = (totalSignals > 0) ? (mScratch ? g_f97_m_svals : (uint64_t*)calloc(totalSignals, sizeof(uint64_t))) : NULL;
            const int mergeAllocOk = ((totalWaits == 0) || (mwSems != NULL && mwStages != NULL && mwVals != NULL)) &&
                                     ((totalCmds == 0) || mCBs != NULL) &&
                                     ((totalSignals == 0) || (msSems != NULL && msVals != NULL));
            if (!mergeAllocOk) {
                MEOWLOGE("meowvulkan: SYNC2->V1 merge: out of memory building the merged VkSubmitInfo");
            } else {
                uint32_t w = 0, c = 0, g = 0;
                for (uint32_t i = 0; i < submitCount; i++) {
                    const MeowSubmit2Tr* e = &st[i];
                    for (uint32_t k = 0; k < s[i].waitSemaphoreInfoCount; k++) {
                        mwSems[w] = e->waitSems[k];
                        mwStages[w] = e->waitStages[k];
                        mwVals[w] = e->waitVals[k];
                        ++w;
                    }
                    for (uint32_t k = 0; k < s[i].commandBufferInfoCount; k++) {
                        mCBs[c] = e->cmdBufs[k];
                        ++c;
                    }
                    for (uint32_t k = 0; k < s[i].signalSemaphoreInfoCount; k++) {
                        msSems[g] = e->sigSems[k];
                        msVals[g] = e->sigVals[k];
                        ++g;
                    }
                }
                VkSubmitInfoL one;
                MeowSubmit2Tr mtr;
                memset(&one, 0, sizeof(one));
                memset(&mtr, 0, sizeof(mtr));
                one.sType = ST_SUBMIT_INFO;
                one.waitSemaphoreCount = totalWaits;
                one.pWaitSemaphores = (totalWaits > 0) ? mwSems : NULL;
                one.pWaitDstStageMask = (totalWaits > 0) ? mwStages : NULL;
                one.commandBufferCount = totalCmds;
                one.pCommandBuffers = (totalCmds > 0) ? mCBs : NULL;
                one.signalSemaphoreCount = totalSignals;
                one.pSignalSemaphores = (totalSignals > 0) ? msSems : NULL;
                if (timelineChains > 0) {
                    mtr.tsi.sType = ST_TIMELINE_SEMAPHORE_SUBMIT_INFO;
                    mtr.tsi.pNext = NULL;   /* never forward a synchronization2 pNext chain into v1 */
                    mtr.tsi.waitSemaphoreValueCount = totalWaits;
                    mtr.tsi.pWaitSemaphoreValues = (totalWaits > 0) ? mwVals : NULL;
                    mtr.tsi.signalSemaphoreValueCount = totalSignals;
                    mtr.tsi.pSignalSemaphoreValues = (totalSignals > 0) ? msVals : NULL;
                    one.pNext = &mtr.tsi;
                }
                // ------------------------------------------------------------------ F69
                // Real GPU-completion semantics: strip the timeline SIGNAL semaphores and cover
                // them with one real VkFence handed to vkQueueSubmit; satisfy any timeline WAIT
                // from an already-mapped fence on the HOST first. See the F69 block above.
                MeowF69Pair* f69Pairs = NULL;
                {
                    const char* f69Why = NULL;
                    int f69 = meow_f69_decide(&f69Why);
                    f69FenceUsed = fence;
                    if (f69) {
                        // (1) timeline WAITS: real host wait, then drop from the submit.
                        MeowF69PFN_waitForFences wff = meow_f69_waitForFences();
                        if (wff != NULL) {
                            uint32_t dst = 0;
                            for (uint32_t k = 0; k < totalWaits; k++) {
                                uint64_t ws = (uint64_t)(uintptr_t)mwSems[k];
                                if (mwVals[k] != 0 && meow_f69_is_timeline(ws)) {
                                    uint64_t wf = meow_f69_wait_fence_for(ws, mwVals[k]);
                                    if (wf != 0) {
                                        // F92 (I1): skip the real wait ONLY when an earlier query already
                                        // proved THIS exact fence signaled. No bit -> fall through to
                                        // today's vkWaitForFences(UINT64_MAX); the wait is never shortened
                                        // and success is never forged.
                                        if (meow_f69_completion_proven(ws, wf)) {
                                            ++f69WaitN;
                                            continue;
                                        }
                                        int wrc = wff(g_dev_seen, 1, &wf, VK_TRUE, UINT64_MAX);
                                        if (wrc == VK_SUCCESS) {
                                            meow_f69_mark_completion(ws, wf);
                                            ++f69WaitN;
                                            if (f69WaitN <= 8)
                                                MEOWLOGI("meowvulkan: F69 wait->fence sem=0x%{public}llx "
                                                         "value=%{public}llu fence=0x%{public}llx rc=0 -- removed "
                                                         "from submit",
                                                         (unsigned long long)ws, (unsigned long long)mwVals[k],
                                                         (unsigned long long)wf);
                                            continue;   /* satisfied on host; do not ask the GPU */
                                        }
                                        // F85: a wait result is only news when it is a REAL error (rc < 0).
                                        // VK_TIMEOUT(2)/VK_NOT_READY(1) are normal "not done yet" and are
                                        // silent by default; verbose restores the line.
                                        if (meow_vk_verbose() || wrc < 0)
                                            MEOWLOGW("meowvulkan: F69 vkWaitForFences rc=%{public}d sem=0x%{public}llx "
                                                     "value=%{public}llu -- leaving the wait to the GPU", wrc,
                                                     (unsigned long long)ws, (unsigned long long)mwVals[k]);
                                    }
                                }
                                mwSems[dst] = mwSems[k];
                                mwStages[dst] = mwStages[k];
                                mwVals[dst] = mwVals[k];
                                ++dst;
                            }
                            totalWaits = dst;
                        } else {
                            MEOWLOGW("meowvulkan: F69 vkWaitForFences unresolved; timeline waits left to the GPU");
                        }
                        // (2) timeline SIGNALS: strip and cover with one real fence.
                        uint32_t tlSignals = 0;
                        for (uint32_t k = 0; k < totalSignals; k++) {
                            if (msVals[k] != 0 && meow_f69_is_timeline((uint64_t)(uintptr_t)msSems[k])) ++tlSignals;
                        }
                        if (tlSignals > 0) {
                            if (fence != 0) {
                                MEOWLOGW("meowvulkan: F69 caller supplied fence=0x%{public}llx; NOT translating "
                                         "timeline signals (behaviour preserved)", (unsigned long long)fence);
                            } else {
                                MeowF69PFN_createFence cf = meow_f69_createFence();
                                VkFence nf = 0;
                                int crc = -3;
                                if (cf != NULL) {
                                    VkFenceCreateInfo fci;
                                    fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
                                    fci.pNext = NULL;
                                    fci.flags = 0;
                                    crc = cf(g_dev_seen, &fci, NULL, (void**)&nf);
                                }
                                if (crc != 0 || nf == 0) {
                                    MEOWLOGW("meowvulkan: F69 vkCreateFence failed rc=%{public}d; keeping today's "
                                             "behaviour (timeline signals untouched)", crc);
                                } else if ((f69Pairs = (MeowF69Pair*)calloc(totalSignals, sizeof(MeowF69Pair))) == NULL) {
                                    meow_f69_destroyFence((uint64_t)nf);
                                    MEOWLOGW("meowvulkan: F69 out of memory for signal pairs; timeline untouched");
                                } else {
                                    f69FenceUsed = (uint64_t)nf;
                                    f69OwnFence = 1;
                                    uint32_t dst = 0;
                                    for (uint32_t k = 0; k < totalSignals; k++) {
                                        if (msVals[k] != 0 && meow_f69_is_timeline((uint64_t)(uintptr_t)msSems[k])) {
                                            f69Pairs[f69SigN].sem = (uint64_t)(uintptr_t)msSems[k];
                                            f69Pairs[f69SigN].value = msVals[k];
                                            ++f69SigN;
                                        } else {
                                            msSems[dst] = msSems[k];
                                            msVals[dst] = msVals[k];
                                            ++dst;
                                        }
                                    }
                                    totalSignals = dst;
                                    f69Active = 1;
                                    if (meow_vk_verbose())
                                        MEOWLOGI("meowvulkan: F69 timeline->fence queue=0x%{public}p fence=0x%{public}llx "
                                                 "sigN=%{public}u sigVal0=%{public}llu waitN=%{public}u why=%{public}s",
                                                 queue, (unsigned long long)f69FenceUsed, f69SigN,
                                                 (unsigned long long)((f69SigN > 0) ? f69Pairs[0].value : 0ULL),
                                                 f69WaitN, f69Why ? f69Why : "(unset)");
                                }
                            }
                        }
                    }
                }
                // F69: counts changed -> keep both the v1 counts and the tsi counts consistent.
                one.waitSemaphoreCount = totalWaits;
                one.pWaitSemaphores = (totalWaits > 0) ? mwSems : NULL;
                one.pWaitDstStageMask = (totalWaits > 0) ? mwStages : NULL;
                one.signalSemaphoreCount = totalSignals;
                one.pSignalSemaphores = (totalSignals > 0) ? msSems : NULL;
                if (timelineChains > 0) {
                    mtr.tsi.waitSemaphoreValueCount = totalWaits;
                    mtr.tsi.pWaitSemaphoreValues = (totalWaits > 0) ? mwVals : NULL;
                    mtr.tsi.signalSemaphoreValueCount = totalSignals;
                    mtr.tsi.pSignalSemaphoreValues = (totalSignals > 0) ? msVals : NULL;
                }
                // F72 (build .49): cover the pool that recorded this frame's push descriptors with the
                // fence handed to this submit. If no fence exists (fence==0 and F69 did not create
                // one), create one purely for pool lifetime tracking -- MC passed 0, so nothing it
                // observes changes. bind_submit() closes the frame so the next allocation rotates.
                VkFence f72Fence = (VkFence)(uintptr_t)f69FenceUsed;
                int f72OwnFence = 0;
                // F72c: cover EVERY pool used this frame; only create a shim fence when none exists
                // (and at most one such fence may be outstanding).
                if (meow_f72_on() && meow_f72_used_count() > 0 && f72Fence == 0 && g_f72_owned_refs == 0) {
                    f72Fence = meow_f72_track_fence_create();
                    f72OwnFence = (f72Fence != 0);
                }
                int r = realSubmit(queue, 1, &one, (uint64_t)(uintptr_t)f72Fence);
                meow_f72_bind_submit(f72Fence, f72OwnFence, (r == 0));
                merged = 1;
                rcSeq[0] = r;
                issued = 1;
                if (r != 0) {
                    firstErr = r;
                    firstErrAt = 0;
                    stoppedAt = 0;
                    // F69: submit rejected -> the fence is not in flight; destroy and do not map.
                    if (f69OwnFence) {
                        meow_f69_destroyFence(f69FenceUsed);
                        f69OwnFence = 0;
                        f69Active = 0;
                    }
                } else {
                    stoppedAt = 1;
                    // F69: register (timelineSem, value) -> the fence that just covered the submit.
                    for (uint32_t k = 0; f69OwnFence && k < f69SigN; k++) {
                        meow_f69_add_entry(f69Pairs[k].sem, f69Pairs[k].value, f69FenceUsed,
                                           (uint64_t)(uintptr_t)queue);
                    }
                }
                free(f69Pairs);
            }
            if (!mScratch) {
                free(mwSems);
                free(mwStages);
                free(mwVals);
                free(mCBs);
                free(msSems);
                free(msVals);
            }
        } else {
        // F96 (.74 bind-merged-submit): the F49 split is a REAL submit path (reachable with
        // MEOW_VK_SYNC2_TO_V1_MERGE=0), so it must register the frame's pools too. The single VkFence
        // handed to every call covers the whole frame, so one shim tracking fence (when the caller
        // supplied none) plus one bind cover every entry regardless of submitCount. Mirrors the F66
        // merge branch above; the registration still happens on the actual submitted fence.
        VkFence f72SplitFence = (VkFence)(uintptr_t)fence;
        int f72SplitOwn = 0;
        if (meow_f72_on() && submitCount >= 1 && f72SplitFence == 0 && g_f72_owned_refs == 0 &&
            meow_f72_used_count() > 0) {
            f72SplitFence = meow_f72_track_fence_create();
            f72SplitOwn = (f72SplitFence != 0);
        }
        for (uint32_t i = 0; i < submitCount; i++) {
            int r = realSubmit(queue, 1, &outs[i], (uint64_t)(uintptr_t)f72SplitFence);
            rcSeq[i] = r;
            issued = i + 1;
            if (r != 0) {
                if (firstErr == 0) { firstErr = r; firstErrAt = i; }
                continue;   /* F51: still attempt the remaining entries */
            }
        }
        if (meow_f72_on() && submitCount >= 1)
            meow_f72_bind_submit(f72SplitFence, f72SplitOwn, (issued != 0 && firstErr == 0));
        }
        // F51: every entry was attempted, so `submits` (== issued) equals `submitsIn`; rc is the
        // first error (0 when every entry was accepted). `diverged` is the self-proof that a batch
        // of N entries really became N calls: 0 = no divergence, 1 = fewer calls were issued than
        // entries seen (a fold / early-stop regression), with the reason in divergedReason.
        rc = firstErr;
        // F66: with the merge path there is exactly ONE call by design, so it is NOT a divergence.
        stoppedAt = merged ? (issued != 0 ? 1u : 0u) : (firstErr ? firstErrAt : submitCount);
        int diverged = (!merged && issued != submitCount) ? 1 : 0;
        const char* divergedReason = merged ? "merged (F66): one entry by design"
                                            : (diverged ? "issued<submitsIn (early stop/fold regression)" : "none");
        size_t off = 0;
        for (uint32_t i = 0; i < issued && off + 8 < sizeof(rcseq); i++) {
            off += (size_t)snprintf(rcseq + off, sizeof(rcseq) - off, "%s%d", (i ? "," : ""), rcSeq[i]);
        }
        unsigned long subN = ++g_sync2v1_submits;
        if (meow_vk_verbose() || rc != 0) {
            MEOWLOGI("meowvulkan: SYNC2->V1 translate vkQueueSubmit2 -> vkQueueSubmit #%{public}lu "
                     "submitsIn=%{public}u submits=%{public}u waits=%{public}u cmdBufs=%{public}u signals=%{public}u "
                     "timelineChains=%{public}u foldedMaskBits=%{public}d rc=%{public}d stoppedAt=%{public}u "
                     "fence=0x%{public}llx rcSeq=%{public}s "
                     "f69=%{public}d f69SigN=%{public}u f69WaitN=%{public}u f69OwnFence=%{public}d f69Fence=0x%{public}llx "
                     "diverged=%{public}d divergedReason=%{public}s merged=%{public}d",
                     subN, submitCount, issued, totalWaits, totalCmds, totalSignals,
                     timelineChains, lostBits, rc, stoppedAt, (unsigned long long)fence, rcseq,
                     f69Active, f69SigN, f69WaitN, f69OwnFence, (unsigned long long)f69FenceUsed,
                     diverged, divergedReason, merged);
        }
        // F47/F48/F49: compact summary of the TRANSLATED PRODUCT (counts + masks only, never a
        // pointer dump). Counts are the per-batch totals across all entry-products; waitDstMask0
        // is the first translated wait stage. arrays=heap documents the storage lifetime.
        if (meow_vk_verbose() || rc != 0) {
            MEOWLOGI("meowvulkan: translated submit: cbCount=%{public}u waitCount=%{public}u "
                     "sigCount=%{public}u timelineInfo=%{public}d waitDstMask0=0x%{public}x "
                     "waitPtr=%{public}s arrays=heap",
                     totalCmds, totalWaits, totalSignals, timelineChains > 0 ? 1 : 0,
                     waitDstMask0,
                     (totalWaits > 0 && haveMask0) ? "valid" : "null");
        }
    } else {
        MEOWLOGE("meowvulkan: SYNC2->V1: translation aborted (counts/alloc); vkQueueSubmit2 NOT forwarded");
    }
    meow_submit2_tr_free(st, submitCount);
    if (outs != g_f97_outs) free(outs);   // F97: the array itself may be the file-level scratch
    return rc;
}

// Defined after the v1 VkImageMemoryBarrier mirror (it reuses VkImgBarrierL).
static int meow_translate_cmd_pipeline_barrier2(void* cmd, const void* di);

// F84 (shim build 2026-09-18.62 quiet-frames) / F85 (shim build 2026-09-18.63 quiet-all): the submit /
// wait proof lines below fire on EVERY frame (every submit / every wait), which floods the device log
// and perturbs timing. They are DEFAULT SILENT: MEOW_VK_VERBOSE=1 prints them individually, and a real
// failure (rc < 0) is ALWAYS printed regardless of verbose (the debugging lifeline). On top of that,
// one slow heartbeat every 20000 calls (F85: was 600) is emitted regardless of verbose, so a quiet run
// still shows liveness, the rough frame pace and the latest error. Same policy as meow_log_drop
// (F55/F56 project rule).
// F85 WAIT RULE: a wait/poll result is only an error when rc < 0. VK_TIMEOUT(2) / VK_NOT_READY(1)
// from a timeout=0 poll are the NORMAL "not done yet" answer and are NEVER logged (not even at
// verbose for the zero-timeout case is desirable, but they are verbose-gated too). See the
// F69 vkWaitSemaphores->vkWaitForFences site.
static unsigned long g_meow_f84_submit_calls;
static unsigned long g_meow_f84_wait_calls;
static int g_meow_f84_wait_last_rc;

static void meow_f84_submit_heartbeat(int rc, long long gap_ms, long long max_gap_ms) {
    unsigned long total = ++g_meow_f84_submit_calls;
    if ((total % 20000ul) == 0ul) {
        MEOWLOGW("meowvulkan: F84 submit heartbeat total=%{public}lu rc=%{public}d gapMs=%{public}lld "
                 "maxGapMs=%{public}lld (per-submit lines quiet; MEOW_VK_VERBOSE=1 restores them)",
                 total, rc, gap_ms, max_gap_ms);
    }
}

static void meow_f84_wait_heartbeat(void) {
    unsigned long total = ++g_meow_f84_wait_calls;
    if ((total % 20000ul) == 0ul) {
        MEOWLOGW("meowvulkan: F84 wait heartbeat total=%{public}lu lastRc=%{public}d "
                 "(per-wait lines quiet; MEOW_VK_VERBOSE=1 restores them)",
                 total, g_meow_f84_wait_last_rc);
    }
}

typedef int (*PFN_queueSubmit2)(void*, uint32_t, const void*, uint64_t);
static int log_QueueSubmit2(void* queue, uint32_t submitCount, const void* submits, uint64_t fence) {
    wd_note("vkQueueSubmit2");
    g_meow_last_queue = queue;   /* F60: write-only cache for the real wait (core + KHR spelling) */
    // F58: submit-interval probe (see g_meow_prev_submit_ns). gapMs == 0 => first submit seen.
    long long t_submit = wd_now_ns();
    long long gap_ms = 0;
    if (g_meow_prev_submit_ns != 0) gap_ms = (t_submit - g_meow_prev_submit_ns) / 1000000LL;
    g_meow_prev_submit_ns = t_submit;
    if (gap_ms > g_meow_max_gap_ms) g_meow_max_gap_ms = gap_ms;
    // F44: when the sync2->v1 translation is on we forward to vkQueueSubmit instead, so the
    // ICD's (broken) vkQueueSubmit2 is never entered. The CALLED log below still runs.
    const char* why = NULL;
    int doTranslate = meow_sync2_to_v1_decide(&why);
    PFN_vkVoidFunctionLocal real = NULL;
    if (!doTranslate) {
        real = meow_cached_proc(&meow_p_vkQueueSubmit2, &meow_d_vkQueueSubmit2, "vkQueueSubmit2");
        if (real == NULL) {
            MEOWLOGE("meowvulkan: cannot resolve the real vkQueueSubmit2");
            return -3;
        }
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkQueueSubmit2 CALLED submitCount=%{public}u fence=0x%{public}llx -- %{public}s",
                 (unsigned)submitCount, (unsigned long long)fence,
                 doTranslate ? "translating to vkQueueSubmit" : "forwarding");
        if (doTranslate) {
            MEOWLOGI("meowvulkan: SYNC2->V1 translate vkQueueSubmit2 -> vkQueueSubmit "
                     "(reason=%{public}s, g_hooks=%{public}d) -- translating",
                     why, g_hooks);
        } else {
            MEOWLOGI("meowvulkan: SYNC2->V1 NOT translating vkQueueSubmit2 -> vkQueueSubmit "
                     "(reason=%{public}s, g_hooks=%{public}d) -- forwarding to the ICD's vkQueueSubmit2",
                     why, g_hooks);
        }
    }
    const VkSubmitInfo2L* s = (const VkSubmitInfo2L*)submits;
    if (meow_vk_verbose() && s != NULL && submitCount > 0) {
        uint32_t n = (submitCount > 16) ? 16u : submitCount;   // bound the noise
        for (uint32_t i = 0; i < n; i++) {
            MEOWLOGI("meowvulkan:   submit[%{public}u] flags=0x%{public}x wait=%{public}u cmdBuf=%{public}u signal=%{public}u",
                     i, s[i].flags, s[i].waitSemaphoreInfoCount, s[i].commandBufferInfoCount,
                     s[i].signalSemaphoreInfoCount);
            // F15 (.14): the `cmdBuf=` field above stays the COUNT (unchanged). This appended line lists
            // the handles themselves so a submit can be tied to the command buffers built by the wrappers
            // (capped at 4; more than 4 prints the count only).
            if (s[i].pCommandBufferInfos != NULL && s[i].commandBufferInfoCount > 0) {
                uint32_t nc = s[i].commandBufferInfoCount;
                if (nc <= 4) {
                    MEOWLOGI("meowvulkan:   submit[%{public}u] cmdBuf handles=[%{public}p,%{public}p,%{public}p,%{public}p]",
                             i,
                             (void*)s[i].pCommandBufferInfos[0].commandBuffer,
                             (nc > 1) ? (void*)s[i].pCommandBufferInfos[1].commandBuffer : NULL,
                             (nc > 2) ? (void*)s[i].pCommandBufferInfos[2].commandBuffer : NULL,
                             (nc > 3) ? (void*)s[i].pCommandBufferInfos[3].commandBuffer : NULL);
                } else {
                    MEOWLOGI("meowvulkan:   submit[%{public}u] cmdBuf handles omitted (%{public}u > 4)", i, nc);
                }
            }
            // F8 (.11): print EVERY wait/signal entry (capped at 4 each), not just [0]. Goal: see
            // which signal entry emits the timeline value (val0=2) the submit waits on. `value` is
            // 64-bit (VkSemaphoreSubmitInfo.value : uint64_t) -> %{public}llu, never truncated.
            if (s[i].pWaitSemaphoreInfos != NULL) {
                uint32_t nw = (s[i].waitSemaphoreInfoCount > 4) ? 4u : s[i].waitSemaphoreInfoCount;
                for (uint32_t k = 0; k < nw; k++) {
                    const VkSemaphoreSubmitInfoL* w = &s[i].pWaitSemaphoreInfos[k];
                    MEOWLOGI("meowvulkan:   submit[%{public}u] wait[%{public}u] sem=0x%{public}llx "
                             "value=%{public}llu stageMask=0x%{public}llx",
                             i, k, (unsigned long long)(uintptr_t)w->semaphore, (unsigned long long)w->value,
                             (unsigned long long)w->stageMask);
                }
            }
            if (s[i].pSignalSemaphoreInfos != NULL) {
                uint32_t ns = (s[i].signalSemaphoreInfoCount > 4) ? 4u : s[i].signalSemaphoreInfoCount;
                for (uint32_t k = 0; k < ns; k++) {
                    const VkSemaphoreSubmitInfoL* g = &s[i].pSignalSemaphoreInfos[k];
                    MEOWLOGI("meowvulkan:   submit[%{public}u] signal[%{public}u] sem=0x%{public}llx "
                             "value=%{public}llu stageMask=0x%{public}llx",
                             i, k, (unsigned long long)(uintptr_t)g->semaphore, (unsigned long long)g->value,
                             (unsigned long long)g->stageMask);
                }
            }
        }
    }
    int rc;
    if (doTranslate) {
        rc = meow_translate_queue_submit2(queue, submitCount, submits, fence);
    } else {
        // F96 (.74 bind-merged-submit): the raw forward is a REAL submit path (reachable with
        // MEOW_VK_SYNC2_TO_V1=0), so register this frame's pools on the fence actually handed to the
        // ICD. Create a shim tracking fence when the caller supplied none (MC always passes 0); one
        // fence covers the whole sync2 batch, so one bind covers every used pool regardless of
        // submitCount. Mirrors the F66 merge branch.
        VkFence f72Fence = (VkFence)(uintptr_t)fence;
        int f72OwnFence = 0;
        if (meow_f72_on() && submitCount >= 1 && f72Fence == 0 && g_f72_owned_refs == 0 &&
            meow_f72_used_count() > 0) {
            f72Fence = meow_f72_track_fence_create();
            f72OwnFence = (f72Fence != 0);
        }
        rc = ((PFN_queueSubmit2)real)(queue, submitCount, submits, (uint64_t)(uintptr_t)f72Fence);
        if (meow_f72_on() && submitCount >= 1)
            meow_f72_bind_submit(f72Fence, f72OwnFence, (rc == 0));
    }
    // F54: kept -- one line per submit, the plain device-loss / success verdict.
    // F58: gapMs = ms since the previous vkQueueSubmit2 (0 on the first submit); maxGapMs = running
    // max. This is the in-log measurement the .37 report §D asked for ("相邻两次提交的间隔").
    if (meow_vk_verbose() || rc != 0) {
        MEOWLOGI("meowvulkan: vkQueueSubmit2 returned rc=%{public}d gapMs=%{public}lld maxGapMs=%{public}lld "
                 "(-4 = VK_ERROR_DEVICE_LOST)", rc, gap_ms, g_meow_max_gap_ms);
    }
    meow_f84_submit_heartbeat(rc, gap_ms, g_meow_max_gap_ms);
    return rc;
}

typedef int (*PFN_waitSemaphores)(void*, const void*, uint64_t);
typedef int (*PFN_queueWaitIdleF)(void*);   /* header :4544 VkResult (*)(VkQueue) */
static int log_WaitSemaphores(void* dev, const void* wi, uint64_t timeout) {
    wd_note("vkWaitSemaphores");
    ++g_wait_calls;                                    // F101: one per frame (MC's awaitSubmitCompletion)
    long long t0 = wd_now_ns();                        // F101: wait wall-time baseline
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkWaitSemaphores, &meow_d_vkWaitSemaphores, "vkWaitSemaphores");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkWaitSemaphores");
        return -3;
    }
    const VkSemaphoreWaitInfoL* w = (const VkSemaphoreWaitInfoL*)wi;
    uint32_t flags = (w != NULL) ? w->flags : 0u;
    uint32_t count = (w != NULL) ? w->semaphoreCount : 0u;
    uint64_t sem0 = 0, val0 = 0;
    if (w != NULL && count > 0) {
        if (w->pSemaphores != NULL) sem0 = (uint64_t)(uintptr_t)w->pSemaphores[0];
        if (w->pValues != NULL) val0 = w->pValues[0];
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkWaitSemaphores CALLED flags=0x%{public}x timeout=%{public}llu ns count=%{public}u "
                 "sem0=0x%{public}llx val0=%{public}llu -- real wait if a queue is cached (else forwarding)",
                 flags, (unsigned long long)timeout, count, (unsigned long long)sem0, (unsigned long long)val0);
    }
    meow_f84_wait_heartbeat();
    // F69 (shim build .45): if EVERY semaphore in the wait is a tracked TIMELINE semaphore with a
    // mapped fence, answer with vkWaitForFences -- a REAL GPU-completion wait, never a host forge.
    // Mixed/partial waits are not guessed at: they fall through to the existing F60 path untouched.
    const char* f69Why = NULL;
    if (meow_f69_decide(&f69Why) && w != NULL && count > 0 && count <= 64 &&
        w->pSemaphores != NULL && w->pValues != NULL) {
        MeowF69PFN_waitForFences wff = meow_f69_waitForFences();
        if (wff != NULL) {
            uint64_t ff[64];
            uint64_t ffs[64];
            uint32_t nf = 0;
            int allMapped = 1;
            int allProven = 1;   // F92: every fence already proven signaled by an earlier REAL query
            for (uint32_t i = 0; i < count; i++) {
                uint64_t ss = (uint64_t)(uintptr_t)w->pSemaphores[i];
                if (!meow_f69_is_timeline(ss)) { allMapped = 0; break; }
                uint64_t ffence = meow_f69_wait_fence_for(ss, w->pValues[i]);
                if (ffence == 0) { allMapped = 0; break; }
                ff[nf] = ffence;
                ffs[nf] = ss;
                ++nf;
                if (!meow_f69_completion_proven(ss, ffence)) allProven = 0;
            }
            if (allMapped && nf > 0) {
                // F92 (I1): all fences already proven signaled -> vkWaitForFences(waitAll, timeout)
                // would return VK_SUCCESS for ANY timeout, so returning here is identical. This uses
                // only the cached one-way bit; it never queries the driver in the not-ready case.
                if (allProven) {
                    g_meow_f84_wait_last_rc = VK_SUCCESS;
                    if (meow_vk_verbose())
                        MEOWLOGI("meowvulkan: F69 vkWaitSemaphores count=%{public}u proven-complete (no wait)", nf);
                    ++g_wait_f69;   // F101: F69 answered with zero driver wait (allProven shortcut)
                    return VK_SUCCESS;
                }
                int wrc = wff(g_dev_seen, nf, ff, VK_TRUE, timeout);
                ++g_wait_f69;   // F101: F69 served this wait
                g_wait_fence_ms += (unsigned long)((wd_now_ns() - t0) / 1000000);   // F101
                g_meow_f84_wait_last_rc = wrc;
                // F92: a successful wait proves every listed fence signaled; remember it so the next
                // poll costs zero driver calls (fences are one-way until destroyed).
                if (wrc == VK_SUCCESS) {
                    for (uint32_t i = 0; i < nf; i++) meow_f69_mark_completion(ffs[i], ff[i]);
                }
                // F85: MC polls with timeout=0; VK_TIMEOUT(2) there is the NORMAL "not done yet" answer,
                // not a failure -- so it must never print. The line is unconditional only for a REAL
                // error (rc < 0); everything else needs MEOW_VK_VERBOSE=1.
                if (meow_vk_verbose() || wrc < 0) {
                    MEOWLOGI("meowvulkan: F69 vkWaitSemaphores->vkWaitForFences count=%{public}u timeout=%{public}llu "
                             "rc=%{public}d sem0=0x%{public}llx val0=%{public}llu flags=0x%{public}x (%{public}s)",
                             nf, (unsigned long long)timeout, wrc, (unsigned long long)sem0,
                             (unsigned long long)val0, flags, f69Why ? f69Why : "(unset)");
                }
                return wrc;
            }
            // F85: per-wait path detail -> verbose only (a poll loop reaches this every call).
            if (meow_vk_verbose())
                MEOWLOGI("meowvulkan: F69 wait not fully mapped (count=%{public}u); using the legacy wait path",
                         count);
        }
    }
    // F60 (shim build .40): real wait. The ICD's timeline completion is unusable (host-forge -> early
    // pool reset -> present never completes; no forge -> TIMEOUT/device-loss). If a submit/present
    // wrapper cached a queue, drain it with vkQueueWaitIdle: success means all submitted GPU work
    // finished, so report VK_SUCCESS without entering the broken vkWaitSemaphores. timeout/flags are
    // deliberately ignored (queue-idle is a stronger guarantee than any semaphore-value wait).
    const char* qidleWhy = NULL;
    int viaQueueIdle = meow_wait_via_queue_idle_decide(&qidleWhy);
    if (viaQueueIdle && g_meow_last_queue != NULL) {
        PFN_vkVoidFunctionLocal idle = meow_cached_proc(&meow_p_vkQueueWaitIdle, &meow_d_vkQueueWaitIdle, "vkQueueWaitIdle");
        if (idle != NULL) {
            int qrc = ((PFN_queueWaitIdleF)idle)(g_meow_last_queue);
            unsigned long n = ++g_meow_wait_qidle;
            ++g_wait_f60_drain;   // F101: the F60 fallback really drained the whole queue
            g_wait_drain_ms += (unsigned long)((wd_now_ns() - t0) / 1000000);   // F101
            if (qrc == VK_SUCCESS) {
                // F85: per-wait success line -> verbose (poll loop). Slow heartbeat every 20000.
                if (meow_vk_verbose() || n <= 4ul || (n % 20000ul) == 0ul)
                    MEOWLOGI("meowvulkan: wait->queueIdle #%{public}lu (ok=1 qrc=%{public}d "
                             "sem0=0x%{public}llx val0=%{public}llu timeout=%{public}llu flags=0x%{public}x)",
                             n, qrc, (unsigned long long)sem0, (unsigned long long)val0,
                             (unsigned long long)timeout, flags);
                if (meow_vk_verbose())
                    MEOWLOGI("meowvulkan: vkWaitSemaphores returned rc=0 (-4 = VK_ERROR_DEVICE_LOST)");
                g_meow_f84_wait_last_rc = VK_SUCCESS;
                // F97 (.75, residual-percall-2): A1 -- this same proven-idle boundary completes every
                // F69 fence previously submitted to this queue, so record their one-way signaled bit
                // now. The following vkGetSemaphoreCounterValue polls then answer without re-issuing a
                // per-fence vkGetFenceStatus; the reported value is unchanged (at this instant those
                // very queries would return VK_SUCCESS). See meow_f69_mark_queue_idle.
                meow_f69_mark_queue_idle((uint64_t)(uintptr_t)g_meow_last_queue);
                // F94 (B, build .72): the queue is provably idle here, so every pool submitted by a
                // PREVIOUS frame is complete. Reclaim it NOW on this stronger-than-a-fence boundary.
                // This is what bounds the F72 descriptor pools even when the per-pool completion fence
                // is never observed SIGNALED; MC already drains the queue once per frame.
                meow_f72_reclaim_pending_now();
                return VK_SUCCESS;
            }
            if (meow_vk_verbose() || n <= 4ul || (n % 20000ul) == 0ul)
                MEOWLOGI("meowvulkan: wait->queueIdle #%{public}lu (ok=0 qrc=%{public}d) -- fallback",
                         n, qrc);
            MEOWLOGW("meowvulkan: vkQueueWaitIdle failed rc=%{public}d; forwarding to the real vkWaitSemaphores",
                     qrc);
        } else {
            MEOWLOGW("meowvulkan: vkQueueWaitIdle unresolved; forwarding to the real vkWaitSemaphores");
        }
    } else if (viaQueueIdle) {
        MEOWLOGW("meowvulkan: no cached queue yet; forwarding to the real vkWaitSemaphores (%{public}s)",
                 qidleWhy ? qidleWhy : "(unset)");
    }
    ++g_wait_fwd;   // F101: no shim-side wait answered -- fell through to the real vkWaitSemaphores
    int rc = ((PFN_waitSemaphores)real)(dev, wi, timeout);
    // F85: per-wait result -> verbose; only a real error prints by default.
    if (meow_vk_verbose() || rc < 0)
        MEOWLOGI("meowvulkan: vkWaitSemaphores returned rc=%{public}d (-4 = VK_ERROR_DEVICE_LOST)", rc);
    g_meow_f84_wait_last_rc = rc;
    return rc;
}

typedef int (*PFN_getSemaphoreCounterValue)(void*, uint64_t, uint64_t*);
static int log_GetSemaphoreCounterValue(void* dev, uint64_t sem, uint64_t* pValue) {
    wd_note("vkGetSemaphoreCounterValue");
    ++g_gscv_calls;   // F101: drives the per-fence query tax (meow_f69_signaled_value)
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkGetSemaphoreCounterValue, &meow_d_vkGetSemaphoreCounterValue, "vkGetSemaphoreCounterValue");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetSemaphoreCounterValue");
        return -3;
    }
    // F69 (shim build .45): for a tracked timeline semaphore report the LARGEST mapped value whose
    // fence is signaled -- the completed counter value. The ICD's own query is the broken one this
    // whole fix bypasses. Un-tracked sems fall through to the real query unchanged.
    const char* f69Why = NULL;
    if (meow_f69_decide(&f69Why) && meow_f69_is_timeline((uint64_t)sem)) {
        uint64_t v = meow_f69_signaled_value((uint64_t)sem);
        if (pValue != NULL) *pValue = v;
        // F85: per-call query line -> verbose (MC polls this too).
        if (meow_vk_verbose())
            MEOWLOGI("meowvulkan: F69 vkGetSemaphoreCounterValue->max signaled value=%{public}llu sem=0x%{public}llx "
                     "(%{public}s)", (unsigned long long)v, (unsigned long long)sem, f69Why ? f69Why : "(unset)");
        return VK_SUCCESS;
    }
    int rc = ((PFN_getSemaphoreCounterValue)real)(dev, sem, pValue);
    if (meow_vk_verbose() || rc < 0)
        MEOWLOGI("meowvulkan: vkGetSemaphoreCounterValue rc=%{public}d sem=0x%{public}llx value=%{public}llu",
                 rc, (unsigned long long)sem,
                 (unsigned long long)((pValue != NULL) ? *pValue : 0ULL));
    return rc;
}

typedef int (*PFN_devIdle)(void*);
static int log_DeviceWaitIdle(void* dev) {
    wd_note("vkDeviceWaitIdle");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkDeviceWaitIdle, &meow_d_vkDeviceWaitIdle, "vkDeviceWaitIdle");
    if (real == NULL) return -3;
    int rc = ((PFN_devIdle)real)(dev);
    // F85: wait result -> verbose; real error always visible.
    if (meow_vk_verbose() || rc < 0)
        MEOWLOGI("meowvulkan: vkDeviceWaitIdle rc=%{public}d", rc);
    return rc;
}

// Entry-only forwarding for the init tail. Rationale: the crash sits right after the first VMA block,
// and the calls we already hook (bind/map/queue submit) never appear -- so the dying call is a
// LATER-INIT operation that we simply could not see. The last entry line printed before death names
// it. Entry logging is enough: the next entry implies the previous call returned.
//
// NAMING NOTE: meow_resolve_device_fn() and MEOW_FORWARD_3OUT (below) are this shim's OWN generic
// "resolve a device-level function / forward a 3-out call" helpers used by 10+ wrappers. They were
// once named probe_*, but they are NOT the (now deleted) F29 diagnostic probe -- never delete them.
static PFN_vkVoidFunctionLocal meow_resolve_device_fn(const char* name) {
    PFN_vkVoidFunctionLocal p = g_gdpa ? g_gdpa(g_dev_seen, name) : NULL;
    if (p == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve %{public}s", name);
    } else if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: %{public}s CALLED", name);
    }
    return p;
}

// NOTE: the local typedef is prefixed (MeowForwardPFN_) so it cannot collide with the official
// PFN_vkCreateXXX typedefs that <vulkan/vulkan.h> now provides.
#define MEOW_FORWARD_3OUT(NAME, A, B, C, D) \
    typedef int (*MeowForwardPFN_##NAME)(A, B, C, D); \
    static int log_##NAME(A a1, B a2, C a3, D a4) { \
        wd_note("" #NAME ""); \
        MeowForwardPFN_##NAME real = (MeowForwardPFN_##NAME)meow_resolve_device_fn("" #NAME ""); \
        if (real == NULL) return -3; \
        return real(a1, a2, a3, a4); \
    }

// F72 (build .49): vkCreatePipelineLayout is hand-written (not MEOW_FORWARD_3OUT) so the
// (pipelineLayout, set) -> VkDescriptorSetLayout map can be captured for the push-as-set emulation.
// The entry log + forward are identical to the macro; the capture call is a no-op when F72 is off.
typedef int (*MeowF72PFN_createPipelineLayout)(void*, const void*, const void*, void**);
static int log_vkCreatePipelineLayout(void* dev, const void* ci, const void* alloc, void** out) {
    wd_note("vkCreatePipelineLayout");
    MeowF72PFN_createPipelineLayout real =
        (MeowF72PFN_createPipelineLayout)meow_resolve_device_fn("vkCreatePipelineLayout");
    if (real == NULL) return -3;
    int rc = real(dev, ci, alloc, out);
    if (rc == 0 && out != NULL && *out != NULL) meow_f72_capture_layout(ci, *out);
    return rc;
}
// F72b (build .50): vkCreateDescriptorSetLayout is hand-written so each layout's flags/bindings can
// be captured and a push-bit-stripped MIRROR created (see the F72b block above). The destroy side is
// wrapped too, so the mirror goes away with the original. Both are pure passthrough when F72 is off.
typedef int (*MeowF72PFN_createDescriptorSetLayout)(void*, const void*, const void*, void**);
static int log_vkCreateDescriptorSetLayout(void* dev, const void* ci, const void* alloc, void** out) {
    wd_note("vkCreateDescriptorSetLayout");
    MeowF72PFN_createDescriptorSetLayout real =
        (MeowF72PFN_createDescriptorSetLayout)meow_resolve_device_fn("vkCreateDescriptorSetLayout");
    if (real == NULL) return -3;
    int rc = real(dev, ci, alloc, out);
    if (rc == 0 && out != NULL && *out != NULL) meow_f72_capture_dsl(ci, *out);
    return rc;
}
typedef void (*MeowF72PFN_destroyDescriptorSetLayout)(void*, void*, const void*);
static void log_vkDestroyDescriptorSetLayout(void* dev, void* dsl, const void* alloc) {
    wd_note("vkDestroyDescriptorSetLayout");
    MeowF72PFN_destroyDescriptorSetLayout real =
        (MeowF72PFN_destroyDescriptorSetLayout)
            (g_gdpa ? g_gdpa(g_dev_seen, "vkDestroyDescriptorSetLayout") : NULL);
    if (real == NULL) { MEOWLOGE("meowvulkan: cannot resolve the real vkDestroyDescriptorSetLayout"); return; }
    if (meow_f72_on()) meow_f72_forget_dsl((uint64_t)(uintptr_t)dsl);
    real(dev, dsl, alloc);
}
MEOW_FORWARD_3OUT(vkCreateCommandPool, void*, const void*, const void*, void**)
// F69: vkCreateSemaphore is hand-written (not MEOW_FORWARD_3OUT) so TIMELINE semaphores can be registered
// for the timeline->fence translation. Same entry + forward as before when F69 is off.
typedef int (*PFN_createSemaphoreF69)(void*, const void*, const void*, void**);
static int log_vkCreateSemaphore(void* dev, const void* ci, const void* alloc, void** out) {
    wd_note("vkCreateSemaphore");
    PFN_createSemaphoreF69 real = (PFN_createSemaphoreF69)meow_resolve_device_fn("vkCreateSemaphore");
    if (real == NULL) return -3;
    int rc = real(dev, ci, alloc, out);
    if (rc == 0 && out != NULL && *out != NULL && meow_f69_on() && meow_f69_createinfo_is_timeline(ci)) {
        meow_f69_register_sem((uint64_t)(uintptr_t)*out);
    }
    return rc;
}
// F69: destroy side -- release the fences this shim owns for that timeline semaphore.
typedef void (*PFN_destroySemaphoreF69)(void*, uint64_t, const void*);
static void log_DestroySemaphore(void* dev, uint64_t sem, const void* alloc) {
    wd_note("vkDestroySemaphore");
    PFN_destroySemaphoreF69 real =
        (PFN_destroySemaphoreF69)(g_gdpa ? g_gdpa(g_dev_seen, "vkDestroySemaphore") : NULL);
    if (real == NULL) { MEOWLOGE("meowvulkan: cannot resolve the real vkDestroySemaphore"); return; }
    if (meow_f69_on()) meow_f69_forget_sem((uint64_t)sem);
    real(dev, sem, alloc);
}
// F69: device teardown -- every owned fence must go before the device does.
typedef void (*PFN_destroyDeviceF69)(void*, const void*);
static void log_DestroyDevice(void* dev, const void* alloc) {
    wd_note("vkDestroyDevice");
    PFN_destroyDeviceF69 real =
        (PFN_destroyDeviceF69)(g_gdpa ? g_gdpa(g_dev_seen, "vkDestroyDevice") : NULL);
    if (real == NULL) { MEOWLOGE("meowvulkan: cannot resolve the real vkDestroyDevice"); return; }
    if (meow_f69_on()) meow_f69_forget_all();
    meow_f72_shutdown();   // F72: destroy the emulation pools (and any tracking fences we own)
    real(dev, alloc);
}
MEOW_FORWARD_3OUT(vkCreateFence, void*, const void*, const void*, void**)
// NOTE: vkCreateSwapchainKHR is NOT forwarded here any more -- F9 (.12) replaces the entry-only
// MEOW_FORWARD_3OUT with a real field-logging wrapper (log_vkCreateSwapchainKHR, defined in the F9
// block below). Same name, same dispatch site in vkGetDeviceProcAddr, unchanged forward.

typedef int (*PFN_createGraphicsPipelines)(void*, void*, uint32_t, const void*, const void*, void*);
static int log_CreateGraphicsPipelines(void* dev, void* cache, uint32_t count, const void* cis,
                                       const void* alloc, void* pipes) {
    wd_note("vkCreateGraphicsPipelines");
    // F71 (shim build .47): divisor diagnostics.
    // WHY: on-device (F70/F71) MC's Vulkan backend HARD-REQUIRES VK_EXT_vertex_attribute_divisor --
    // with the shim's feature-query lie removed (MEOW_VK_NO_DIVISOR_FEATURE=1) MC logs
    // "Render thread ERROR Failed to create backend Vulkan" and falls back to OpenGL 4.2. So the lie
    // is mandatory. This ICD however genuinely lacks the extension (maxVertexAttribDivisor==1), so a
    // divisor > 1 binding would ask the GPU for state it does not have -- the standing hypothesis for
    // "only real draws fault" (F70: dropping the draws makes MC reach the main menu with no crash).
    // Logging the divisor state here answers "does MC ever ask for divisor>1?" from a SAFE run
    // (draws dropped), because pipelines are created at load time regardless of the draws.
    // Uses the official structs (the shim includes <vulkan/vulkan.h> with VK_NO_PROTOTYPES since F62).
    // F103 (build 2026-09-23.82 quiet-vk-probes): this whole divisor block is a research probe from the
    // F70/F71 campaign. MC creates pipelines lazily, so the per-create summary printed 233 lines/run.
    // Gated behind MEOW_VK_VERBOSE=1 (the existing diagnostics switch); the feature lie itself is
    // unaffected (it lives in the device-feature/createDevice path, not here).
    uint32_t pipesWithDiv = 0, pipesTotal = 0, maxDivSeen = 0;
    if (meow_vk_verbose() && count > 0 && cis != NULL) {
        const VkGraphicsPipelineCreateInfo* gci = (const VkGraphicsPipelineCreateInfo*)cis;
        for (uint32_t i = 0; i < count; i++) {
            ++pipesTotal;
            const VkPipelineVertexInputStateCreateInfo* vi = gci[i].pVertexInputState;
            uint32_t nDiv = 0, nBind = 0;
            if (vi != NULL) {
                nBind = vi->vertexBindingDescriptionCount;
                for (const VkBaseInStructure* p = (const VkBaseInStructure*)vi->pNext; p != NULL; p = p->pNext) {
                    if (p->sType == VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_DIVISOR_STATE_CREATE_INFO_EXT) {
                        const VkPipelineVertexInputDivisorStateCreateInfoEXT* d =
                            (const VkPipelineVertexInputDivisorStateCreateInfoEXT*)p;
                        nDiv = d->vertexBindingDivisorCount;
                        if (++pipesWithDiv == 1 || meow_vk_verbose()) {
                            for (uint32_t k = 0; k < nDiv && k < 16; k++) {
                                uint32_t binding = d->pVertexBindingDivisors[k].binding;
                                uint32_t div = d->pVertexBindingDivisors[k].divisor;
                                if (div > maxDivSeen) maxDivSeen = div;
                                MEOWLOGI("meowvulkan: F71 pipeline[%{public}u] DIVISOR_STATE binding=%{public}u "
                                         "divisor=%{public}u%s", i, binding, div,
                                         div > 1u ? "  <-- >1, the ICD has maxVertexAttribDivisor=1" : "");
                            }
                        } else {
                            for (uint32_t k = 0; k < nDiv && k < 16; k++) {
                                if (d->pVertexBindingDivisors[k].divisor > maxDivSeen)
                                    maxDivSeen = d->pVertexBindingDivisors[k].divisor;
                            }
                        }
                        break;
                    }
                }
            }
            if (meow_vk_verbose())
                MEOWLOGI("meowvulkan: F71 pipeline[%{public}u] vertexBindings=%{public}u divisorEntries=%{public}u",
                         i, nBind, nDiv);
        }
        // F103: was one line per create call; now only reachable under MEOW_VK_VERBOSE=1 (the answer to
        // "does MC ever use divisor>1?" is a research finding, not a per-run invariant).
        MEOWLOGI("meowvulkan: F71 divisor summary: pipelines=%{public}u withDivisorState=%{public}u maxDivisor=%{public}u",
                 pipesTotal, pipesWithDiv, maxDivSeen);
    }
    PFN_createGraphicsPipelines real = (PFN_createGraphicsPipelines)meow_resolve_device_fn("vkCreateGraphicsPipelines");
    if (real == NULL) return -3;
    return real(dev, cache, count, cis, alloc, pipes);
}

// VkCommandBufferAllocateInfo -- official SDK type (vulkan_core.h:4058).
typedef VkCommandBufferAllocateInfo VkCommandBufferAllocateInfoL;
typedef int (*PFN_allocateCommandBuffers)(void*, const void*, void*);
static int log_AllocateCommandBuffers(void* dev, const void* ai, void* cbs) {
    wd_note("vkAllocateCommandBuffers");
    // F92 (.70): F85 measured this as a per-frame hot path -> F87 cache.
    PFN_allocateCommandBuffers real = (PFN_allocateCommandBuffers)
        meow_cached_proc(&meow_p_vkAllocateCommandBuffers, &meow_d_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkAllocateCommandBuffers");
        return -3;
    }
    const VkCommandBufferAllocateInfoL* a = (const VkCommandBufferAllocateInfoL*)ai;
    uint32_t count = (a != NULL) ? a->commandBufferCount : 0u;
    // F85: command-buffer allocation is a per-frame hot path -> verbose (real errors stay visible).
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkAllocateCommandBuffers CALLED commandPool=0x%{public}llx level=%{public}d "
                 "commandBufferCount=%{public}u -- forwarding",
                 (unsigned long long)(uintptr_t)((a != NULL) ? a->commandPool : VK_NULL_HANDLE),
                 (a != NULL) ? (int)a->level : 0, count);
    int rc = real(dev, ai, cbs);
    if (meow_vk_verbose() || rc != 0) {
        if (cbs != NULL && count > 0 && count <= 4) {
            const void* const* h = (const void* const*)cbs;
            const void* h0 = h[0];
            const void* h1 = (count > 1) ? h[1] : NULL;
            const void* h2 = (count > 2) ? h[2] : NULL;
            const void* h3 = (count > 3) ? h[3] : NULL;
            MEOWLOGI("meowvulkan: vkAllocateCommandBuffers rc=%{public}d handles=[%{public}p,%{public}p,%{public}p,%{public}p]",
                     rc, h0, h1, h2, h3);
        } else if (count > 4) {
            MEOWLOGI("meowvulkan: vkAllocateCommandBuffers rc=%{public}d allocated %{public}u command buffers "
                     "(handles omitted: >4)", rc, count);
        } else {
            MEOWLOGI("meowvulkan: vkAllocateCommandBuffers rc=%{public}d count=%{public}u", rc, count);
        }
    }
    return rc;
}

typedef void (*PFN_getDeviceQueue)(void*, uint32_t, uint32_t, void**);
static void log_GetDeviceQueue(void* dev, uint32_t family, uint32_t index, void** queue) {
    wd_note("vkGetDeviceQueue");
    PFN_getDeviceQueue real = (PFN_getDeviceQueue)meow_resolve_device_fn("vkGetDeviceQueue");
    if (real != NULL) real(dev, family, index, queue);
}

typedef int (*PFN_beginCommandBuffer)(void*, const void*);
static int log_BeginCommandBuffer(void* cmd, const void* bi) {
    wd_note("vkBeginCommandBuffer");
    // F92 (.70): per-frame call -> F87 cache instead of one g_gdpa() lookup per frame.
    PFN_beginCommandBuffer real = (PFN_beginCommandBuffer)
        meow_cached_proc(&meow_p_vkBeginCommandBuffer, &meow_d_vkBeginCommandBuffer, "vkBeginCommandBuffer");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkBeginCommandBuffer");
        return -3;
    }
    // F15 (.14): command-buffer ownership tagging -- cmd IS the first parameter, printed verbatim.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkBeginCommandBuffer CALLED cmdBuf=%{public}p -- forwarding", cmd);
    return real(cmd, bi);
}

// The core of the forgery: dynamic rendering is one of the extensions we make MC believe in.
typedef void (*PFN_cmdBeginRendering)(void*, const void*);
static void log_CmdBeginRendering(void* cmd, const void* ri) {
    wd_note("vkCmdBeginRendering");
    PFN_cmdBeginRendering real = (PFN_cmdBeginRendering)meow_cached_proc(
        &meow_p_vkCmdBeginRendering, &meow_d_vkCmdBeginRendering, "vkCmdBeginRendering");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBeginRendering");
        return;
    }
    // F15 (.14): command-buffer ownership tagging -- cmd IS the first parameter, printed verbatim.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdBeginRendering CALLED cmdBuf=%{public}p -- forwarding", cmd);
    real(cmd, ri);
}

// =====================================================================================
// F6 (shim build .9): present/acquire + command-level diagnostics for the second submit
// that returns VK_ERROR_DEVICE_LOST. ADDITIVE ONLY -- nothing above or below is modified.
// In particular log_CmdCopyBufferToImage (the one verified-good path) is NOT touched.
//
// Every prototype below copies the parameter list verbatim from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361).
// The struct mirrors are machine-checked (sizes/offsets/arity) against that header with clang
// _Static_assert; see stuffs/research/vulkan/fixes/F6-present-cmdbarrier-diagnostics.md.
// RULE: forward the SAME argument list. No parameter is ever invented, not even for logging.
// =====================================================================================

// F59 (shim build 2026-09-18.39 acq-slow-probe): slow-acquire window-side observability.
// The .38 verbose log shows vkAcquireNextImageKHR blocking ~1 s (dtMs=1021/984/989/1011) while
// acquire count 4 / present count 3 -- i.e. the stall starts once MC has run out of swapchain
// images. This block records (a) running acquire/present counters and (b) the LAST SUCCESSFULLY
// created swapchain's parameters, and emits ONE extra line when a single acquire takes >= 500 ms
// so the acquire ordinal can be read straight off the log ("slow acquire #k (acquireCount=A
// presentCount=P)"). Always on; only a slow acquire prints.
// Counters/scalars live here (before the acquire wrapper); the logging helper is defined further
// down, after the surface/swapchain caches it also reads, and forward-declared here.
static unsigned long g_meow_acquire_count;
static unsigned long g_meow_present_count;
// Last successful vkCreateSwapchainKHR: the parameters actually FORWARDED (post-diagnostic values).
// Plain scalars so this can sit above the VkSwapchainCIKHRL mirror, which is defined much later.
static uint64_t g_meow_sw_handle;
static uint32_t g_meow_sw_min_image_count;
static int32_t  g_meow_sw_image_format;
static uint32_t g_meow_sw_image_usage;
static int32_t  g_meow_sw_pre_transform;
static int32_t  g_meow_sw_present_mode;
static int g_meow_sw_valid;

static void meow_vk_log_slow_acquire(void* swapchain, int rc, long long dt_ms);

// vkAcquireNextImageKHR -- header :9169
// PFN_vkAcquireNextImageKHR(VkDevice, VkSwapchainKHR, uint64_t, VkSemaphore, VkFence, uint32_t*)
typedef int (*PFN_acquireNextImageKHR)(void*, void*, uint64_t, void*, void*, uint32_t*);
static int log_AcquireNextImageKHR(void* dev, void* swapchain, uint64_t timeout,
                                   void* semaphore, void* fence, uint32_t* pImageIndex) {
    wd_note("vkAcquireNextImageKHR");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkAcquireNextImageKHR, &meow_d_vkAcquireNextImageKHR, "vkAcquireNextImageKHR");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkAcquireNextImageKHR");
        return -3;   // VK_ERROR_INITIALIZATION_FAILED
    }
    // F58: acquire/present were hooked but only logged under MEOW_VK_VERBOSE, so a ~1 s BLOCKING
    // vkAcquireNextImageKHR (MC passes timeout=5 s) was invisible in the quiet logs -- "no shim
    // line" could not distinguish "MC computing" from "MC blocked in acquire". Time the real call
    // and emit a line whenever it exceeds 200 ms (plus the full line under verbose).
    long long t0 = wd_now_ns();
    int rc = ((PFN_acquireNextImageKHR)real)(dev, swapchain, timeout, semaphore, fence, pImageIndex);
    long long dt_ms = (wd_now_ns() - t0) / 1000000LL;
    g_meow_acquire_count++;
    if (meow_vk_verbose() || dt_ms >= 200)
        MEOWLOGI("meowvulkan: vkAcquireNextImageKHR rc=%{public}d dtMs=%{public}lld (-1=NOT_READY -2=TIMEOUT) swapchain=%{public}p "
                 "timeout=%{public}llu sem=%{public}p fence=%{public}p imageIndex=%{public}u",
                 rc, dt_ms, swapchain, (unsigned long long)timeout, semaphore, fence,
                 (unsigned)((pImageIndex != NULL) ? *pImageIndex : 0u));
    // F59: ONE extra line only for a genuinely slow acquire (>= 500 ms). When the swapchain runs
    // out of presentable images this is where the "images not returned" hypothesis becomes visible:
    // the acquire ordinal (#k) vs. the running acquire/present counts tells whether the stall starts
    // at A~4/P~3 (all images in flight) or from the very first acquire (a different failure).
    if (dt_ms >= 500)
        meow_vk_log_slow_acquire(swapchain, rc, dt_ms);
    return rc;
}

// VkPresentInfoKHR -- official SDK type (vulkan_core.h:8682). NOTE: it carries NO stageMask field;
// this wrapper logs the fields that really exist and does NOT invent one.
typedef VkPresentInfoKHR VkPresentInfoKHRL;
// vkQueuePresentKHR -- header :9170  PFN_vkQueuePresentKHR(VkQueue, const VkPresentInfoKHR*)
typedef int (*PFN_queuePresentKHR)(void*, const void*);
static int log_QueuePresentKHR(void* queue, const void* pi) {
    wd_note("vkQueuePresentKHR");
    g_meow_last_queue = queue;   /* F60: fallback source for the cached queue (same render thread) */
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkQueuePresentKHR, &meow_d_vkQueuePresentKHR, "vkQueuePresentKHR");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkQueuePresentKHR");
        return -3;
    }
    const VkPresentInfoKHRL* p = (const VkPresentInfoKHRL*)pi;
    uint32_t waitCount = (p != NULL) ? p->waitSemaphoreCount : 0u;
    uint32_t scCount = (p != NULL) ? p->swapchainCount : 0u;
    void* sem0 = NULL;
    void* sc0 = NULL;
    uint32_t idx0 = 0;
    if (p != NULL) {
        if (waitCount > 0 && p->pWaitSemaphores != NULL) {
            sem0 = p->pWaitSemaphores[0];
        }
        if (scCount > 0 && p->pSwapchains != NULL) {
            sc0 = p->pSwapchains[0];
        }
        if (scCount > 0 && p->pImageIndices != NULL) {
            idx0 = p->pImageIndices[0];
        }
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkQueuePresentKHR CALLED waitSemaphoreCount=%{public}u waitSem0=%{public}p "
                 "swapchainCount=%{public}u swapchain0=%{public}p imageIndex0=%{public}u -- forwarding",
                 waitCount, sem0, scCount, sc0, idx0);
    long long t0 = wd_now_ns();
    int rc = ((PFN_queuePresentKHR)real)(queue, pi);
    long long dt_ms = (wd_now_ns() - t0) / 1000000LL;
    g_meow_present_count++;   // F59: completed presents, read by the slow-acquire line
    if (meow_vk_verbose() || dt_ms >= 200)
        MEOWLOGI("meowvulkan: vkQueuePresentKHR returned rc=%{public}d dtMs=%{public}lld (-1=SUBOPTIMAL -1000001004=OUT_OF_DATE)", rc, dt_ms);
    return rc;
}

// Official sync2 barrier/dependency types (vulkan_core.h:7191/7177/7206). The former mirrors
// flattened VkImageMemoryBarrier2.subresourceRange; accesses below use the official nesting.
typedef VkImageMemoryBarrier2    VkImgBarrier2L;
typedef VkBufferMemoryBarrier2   VkBufBarrier2L;
typedef VkDependencyInfo         VkDependencyInfoL;
// vkCmdPipelineBarrier2 -- header :7969; KHR alias :12434 (identical parameter list). The ICD exposes
// the core name only, so the wrapper always forwards to "vkCmdPipelineBarrier2".
typedef void (*PFN_cmdPipelineBarrier2)(void*, const void*);
static void log_CmdPipelineBarrier2(void* cmd, const void* di) {
    wd_note("vkCmdPipelineBarrier2");
    // F44: when the sync2->v1 translation is on we forward to vkCmdPipelineBarrier instead, so
    // the ICD's (broken) vkCmdPipelineBarrier2 is never entered. The CALLED log still runs.
    const char* why = NULL;
    int doTranslate = meow_sync2_to_v1_decide(&why);
    PFN_vkVoidFunctionLocal real = NULL;
    if (!doTranslate) {
        real = meow_cached_proc(&meow_p_vkCmdPipelineBarrier2, &meow_d_vkCmdPipelineBarrier2, "vkCmdPipelineBarrier2");
        if (real == NULL) {
            MEOWLOGE("meowvulkan: cannot resolve the real vkCmdPipelineBarrier2");
            return;
        }
    }
    const VkDependencyInfoL* d = (const VkDependencyInfoL*)di;
    uint32_t memC = (d != NULL) ? d->memoryBarrierCount : 0u;
    uint32_t bufC = (d != NULL) ? d->bufferMemoryBarrierCount : 0u;
    uint32_t imgC = (d != NULL) ? d->imageMemoryBarrierCount : 0u;
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdPipelineBarrier2 CALLED cmdBuf=%{public}p memoryBarrierCount=%{public}u "
                 "bufferMemoryBarrierCount=%{public}u imageMemoryBarrierCount=%{public}u -- %{public}s",
                 cmd, memC, bufC, imgC,
                 doTranslate ? "translating to vkCmdPipelineBarrier" : "forwarding");
        if (doTranslate) {
            MEOWLOGI("meowvulkan: SYNC2->V1 translate vkCmdPipelineBarrier2 -> vkCmdPipelineBarrier "
                     "(reason=%{public}s, g_hooks=%{public}d) -- translating",
                     why, g_hooks);
        } else {
            MEOWLOGI("meowvulkan: SYNC2->V1 NOT translating vkCmdPipelineBarrier2 -> vkCmdPipelineBarrier "
                     "(reason=%{public}s, g_hooks=%{public}d) -- forwarding to the ICD's vkCmdPipelineBarrier2",
                     why, g_hooks);
        }
        if (d != NULL && imgC > 0 && d->pImageMemoryBarriers != NULL) {
            const VkImgBarrier2L* b = (const VkImgBarrier2L*)d->pImageMemoryBarriers;
            MEOWLOGI("meowvulkan:   imgBarrier0 oldLayout=%{public}u newLayout=%{public}u "
                     "srcStageMask=0x%{public}llx dstStageMask=0x%{public}llx "
                     "srcAccessMask=0x%{public}llx dstAccessMask=0x%{public}llx "
                     "aspectMask=0x%{public}x image=%{public}p",
                     b->oldLayout, b->newLayout, (unsigned long long)b->srcStageMask,
                     (unsigned long long)b->dstStageMask, (unsigned long long)b->srcAccessMask,
                     (unsigned long long)b->dstAccessMask, b->subresourceRange.aspectMask, b->image);
        }
        // F7 (.10): the buffer barrier's access masks/range, same reasoning as the image barrier above.
        if (d != NULL && bufC > 0 && d->pBufferMemoryBarriers != NULL) {
            const VkBufBarrier2L* b = (const VkBufBarrier2L*)d->pBufferMemoryBarriers;
            MEOWLOGI("meowvulkan:   bufBarrier0 srcAccessMask=0x%{public}llx dstAccessMask=0x%{public}llx "
                     "offset=%{public}llu size=%{public}llu buffer=%{public}p",
                     (unsigned long long)b->srcAccessMask, (unsigned long long)b->dstAccessMask,
                     (unsigned long long)b->offset, (unsigned long long)b->size, b->buffer);
        }
    }
    if (doTranslate) {
        meow_translate_cmd_pipeline_barrier2(cmd, di);
    } else {
        ((PFN_cmdPipelineBarrier2)real)(cmd, di);
    }
}

// vkCmdBindPipeline -- header :4625 (VkPipelineBindPoint is an int32 enum; VkPipeline is a 64-bit handle).
typedef void (*PFN_cmdBindPipeline)(void*, uint32_t, void*);
static void log_CmdBindPipeline(void* cmd, uint32_t bindPoint, void* pipeline) {
    wd_note("vkCmdBindPipeline");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdBindPipeline, &meow_d_vkCmdBindPipeline, "vkCmdBindPipeline");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBindPipeline");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdBindPipeline CALLED bindPoint=%{public}u pipeline=%{public}p -- forwarding",
                 bindPoint, pipeline);
    ((PFN_cmdBindPipeline)real)(cmd, bindPoint, pipeline);
}

// vkCmdDraw -- header :4651
typedef void (*PFN_cmdDraw)(void*, uint32_t, uint32_t, uint32_t, uint32_t);
static void log_CmdDraw(void* cmd, uint32_t vertexCount, uint32_t instanceCount,
                        uint32_t firstVertex, uint32_t firstInstance) {
    wd_note("vkCmdDraw");
    if (meow_vk_drop_draw()) {   // F70: causal test, see meow_vk_drop_draw
        meow_log_drop("vkCmdDraw");   // F71b: rate-limited
        return;
    }
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdDraw, &meow_d_vkCmdDraw, "vkCmdDraw");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdDraw");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdDraw CALLED cmdBuf=%{public}p vertexCount=%{public}u instanceCount=%{public}u "
                 "firstVertex=%{public}u firstInstance=%{public}u -- forwarding",
                 cmd, vertexCount, instanceCount, firstVertex, firstInstance);
    ((PFN_cmdDraw)real)(cmd, vertexCount, instanceCount, firstVertex, firstInstance);
}

// vkCmdDrawIndexed -- header :4652 (vertexOffset is int32_t)
typedef void (*PFN_cmdDrawIndexed)(void*, uint32_t, uint32_t, uint32_t, int32_t, uint32_t);
static void log_CmdDrawIndexed(void* cmd, uint32_t indexCount, uint32_t instanceCount,
                               uint32_t firstIndex, int32_t vertexOffset, uint32_t firstInstance) {
    static unsigned char s_tp_drawidx;
    meow_log_thread_once(&s_tp_drawidx, "vkCmdDrawIndexed");
    wd_note("vkCmdDrawIndexed");
    if (meow_vk_drop_draw()) {   // F70: causal test, see meow_vk_drop_draw
        meow_log_drop("vkCmdDrawIndexed");   // F71b: rate-limited
        return;
    }
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdDrawIndexed, &meow_d_vkCmdDrawIndexed, "vkCmdDrawIndexed");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdDrawIndexed");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdDrawIndexed CALLED cmdBuf=%{public}p indexCount=%{public}u instanceCount=%{public}u "
                 "firstIndex=%{public}u vertexOffset=%{public}d firstInstance=%{public}u -- forwarding",
                 cmd, indexCount, instanceCount, firstIndex, vertexOffset, firstInstance);
    ((PFN_cmdDrawIndexed)real)(cmd, indexCount, instanceCount, firstIndex, vertexOffset, firstInstance);
}

// F70: vkCmdDrawIndirect / vkCmdDrawIndexedIndirect -- header :4685 / :4694. A8 3.1 says MC uses
// these, but this shim had never wrapped them, so MEOW_VK_DROP_DRAW could not have covered MC's real
// draws. Signature: (cmdBuf, VkBuffer buffer, VkDeviceSize offset, uint32_t drawCount, uint32_t stride).
typedef void (*PFN_cmdDrawIndirect)(void*, void*, uint64_t, uint32_t, uint32_t);
static void log_CmdDrawIndirect(void* cmd, void* buffer, uint64_t offset, uint32_t drawCount,
                                uint32_t stride) {
    wd_note("vkCmdDrawIndirect");
    if (meow_vk_drop_draw()) {   // F70: causal test
        meow_log_drop("vkCmdDrawIndirect");   // F71b: rate-limited
        return;
    }
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdDrawIndirect, &meow_d_vkCmdDrawIndirect, "vkCmdDrawIndirect");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdDrawIndirect");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdDrawIndirect CALLED cmdBuf=%{public}p buffer=%{public}p offset=%{public}llu "
                 "drawCount=%{public}u stride=%{public}u -- forwarding",
                 cmd, buffer, (unsigned long long)offset, drawCount, stride);
    ((PFN_cmdDrawIndirect)real)(cmd, buffer, offset, drawCount, stride);
}

static void log_CmdDrawIndexedIndirect(void* cmd, void* buffer, uint64_t offset, uint32_t drawCount,
                                       uint32_t stride) {
    wd_note("vkCmdDrawIndexedIndirect");
    if (meow_vk_drop_draw()) {   // F70: causal test
        meow_log_drop("vkCmdDrawIndexedIndirect");   // F71b: rate-limited
        return;
    }
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdDrawIndexedIndirect, &meow_d_vkCmdDrawIndexedIndirect, "vkCmdDrawIndexedIndirect");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdDrawIndexedIndirect");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdDrawIndexedIndirect CALLED cmdBuf=%{public}p buffer=%{public}p "
                 "offset=%{public}llu drawCount=%{public}u stride=%{public}u -- forwarding",
                 cmd, buffer, (unsigned long long)offset, drawCount, stride);
    ((PFN_cmdDrawIndirect)real)(cmd, buffer, offset, drawCount, stride);
}

// vkCmdEndRendering -- header :7985; KHR alias :10305 (same one parameter).
typedef void (*PFN_cmdEndRendering)(void*);
static void log_CmdEndRendering(void* cmd) {
    wd_note("vkCmdEndRendering");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdEndRendering, &meow_d_vkCmdEndRendering, "vkCmdEndRendering");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdEndRendering");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdEndRendering CALLED cmdBuf=%{public}p -- forwarding", cmd);
    ((PFN_cmdEndRendering)real)(cmd);
}

// vkCmdCopyBuffer -- header :4585 (VkBuffer handles are 64-bit). Distinct from and independent of
// log_CmdCopyBufferToImage, which is left untouched.
typedef void (*PFN_cmdCopyBuffer)(void*, void*, void*, uint32_t, const void*);
static void log_CmdCopyBuffer(void* cmd, void* src, void* dst, uint32_t regionCount, const void* regions) {
    wd_note("vkCmdCopyBuffer");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdCopyBuffer, &meow_d_vkCmdCopyBuffer, "vkCmdCopyBuffer");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdCopyBuffer");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdCopyBuffer CALLED src=%{public}p dst=%{public}p regionCount=%{public}u "
                 "-- forwarding", src, dst, regionCount);
    ((PFN_cmdCopyBuffer)real)(cmd, src, dst, regionCount, regions);
}

// ---- F7 (.10): the three binding entry points between the barriers/draws. Same iron rule: the
// parameter list is copied verbatim from the header and forwarded unchanged. 64-bit quantities are
// logged with %{public}llx/%{public}llu (never truncated to 32 bits).

// vkCmdBindVertexBuffers -- header :4650
// PFN_vkCmdBindVertexBuffers(VkCommandBuffer commandBuffer, uint32_t firstBinding, uint32_t bindingCount,
//                            const VkBuffer* pBuffers, const VkDeviceSize* pOffsets)
// pBuffers is an array of 64-bit VkBuffer handles; pOffsets an array of 64-bit VkDeviceSize.
typedef void (*PFN_cmdBindVertexBuffers)(void*, uint32_t, uint32_t, const void*, const void*);
static void log_CmdBindVertexBuffers(void* cmd, uint32_t firstBinding, uint32_t bindingCount,
                                     const void* pBuffers, const void* pOffsets) {
    wd_note("vkCmdBindVertexBuffers");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdBindVertexBuffers, &meow_d_vkCmdBindVertexBuffers, "vkCmdBindVertexBuffers");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBindVertexBuffers");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdBindVertexBuffers CALLED firstBinding=%{public}u bindingCount=%{public}u "
                 "-- forwarding", firstBinding, bindingCount);
        if (bindingCount > 0 && pBuffers != NULL && pOffsets != NULL) {
            const void* buf0 = ((const void* const*)pBuffers)[0];
            uint64_t off0 = ((const uint64_t*)pOffsets)[0];
            MEOWLOGI("meowvulkan:   vtxBuf0 buffer=%{public}p offset=%{public}llu", buf0,
                     (unsigned long long)off0);
        }
    }
    ((PFN_cmdBindVertexBuffers)real)(cmd, firstBinding, bindingCount, pBuffers, pOffsets);
}

// vkCmdBindIndexBuffer -- header :4649
// PFN_vkCmdBindIndexBuffer(VkCommandBuffer commandBuffer, VkBuffer buffer, VkDeviceSize offset,
//                          VkIndexType indexType)   (VkIndexType is a 32-bit enum)
typedef void (*PFN_cmdBindIndexBuffer)(void*, void*, uint64_t, uint32_t);
static void log_CmdBindIndexBuffer(void* cmd, void* buffer, uint64_t offset, uint32_t indexType) {
    wd_note("vkCmdBindIndexBuffer");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdBindIndexBuffer, &meow_d_vkCmdBindIndexBuffer, "vkCmdBindIndexBuffer");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBindIndexBuffer");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdBindIndexBuffer CALLED buffer=%{public}p offset=%{public}llu "
                 "indexType=%{public}u (0=UINT16 1=UINT32) -- forwarding",
                 buffer, (unsigned long long)offset, indexType);
    ((PFN_cmdBindIndexBuffer)real)(cmd, buffer, offset, indexType);
}

// vkCmdBindDescriptorSets -- header :4626
// PFN_vkCmdBindDescriptorSets(VkCommandBuffer commandBuffer, VkPipelineBindPoint pipelineBindPoint,
//                             VkPipelineLayout layout, uint32_t firstSet, uint32_t descriptorSetCount,
//                             const VkDescriptorSet* pDescriptorSets, uint32_t dynamicOffsetCount,
//                             const uint32_t* pDynamicOffsets)
typedef void (*PFN_cmdBindDescriptorSets)(void*, uint32_t, void*, uint32_t, uint32_t, const void*,
                                          uint32_t, const void*);
static void log_CmdBindDescriptorSets(void* cmd, uint32_t bindPoint, void* layout, uint32_t firstSet,
                                      uint32_t setCount, const void* pDescriptorSets,
                                      uint32_t dynamicOffsetCount, const void* pDynamicOffsets) {
    static unsigned char s_tp_bind;
    meow_log_thread_once(&s_tp_bind, "vkCmdBindDescriptorSets");
    wd_note("vkCmdBindDescriptorSets");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdBindDescriptorSets, &meow_d_vkCmdBindDescriptorSets, "vkCmdBindDescriptorSets");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBindDescriptorSets");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdBindDescriptorSets CALLED bindPoint=%{public}u layout=%{public}p "
                 "firstSet=%{public}u setCount=%{public}u dynamicOffsetCount=%{public}u -- forwarding",
                 bindPoint, layout, firstSet, setCount, dynamicOffsetCount);
    ((PFN_cmdBindDescriptorSets)real)(cmd, bindPoint, layout, firstSet, setCount, pDescriptorSets,
                                      dynamicOffsetCount, pDynamicOffsets);
}

// =====================================================================================
// F8 (shim build .11): the "data movement" commands that sit BETWEEN the two
// vkCmdPipelineBarrier2 calls of the second submit (UNDEFINED->TRANSFER_DST_OPTIMAL and
// TRANSFER_DST_OPTIMAL->PRESENT_SRC_KHR were visible; the copy/blit/clear between them was not),
// plus the full wait/signal list of vkQueueSubmit2 (see that wrapper above). ADDITIVE ONLY.
// log_CmdCopyBufferToImage (:142), log_CmdBeginRendering (:554) and log_CmdEndRendering (:758) are
// NOT touched.
//
// Every prototype copies the parameter list verbatim from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361). Every
// struct mirror below is machine-checked by /storage/Users/currentUser/deveco/f8_probe.c, which
// compiles the AUTHORITATIVE header and _Static_asserts each offset/size, and assigns a function
// carrying the shim's exact parameter list to the header's PFN_vk* (a dropped/added/reordered
// parameter is an incompatible function pointer type and fails under -Werror). RULE: forward the
// SAME argument list. No parameter is ever invented, not even for logging.
//
// NOTE (do not "fix" this): the task brief said "vkCmdBlitImage ... first region same as above",
// but VkImageBlit (header :4500) has NO `extent` member -- only srcOffsets[2]/dstOffsets[2]. This
// wrapper therefore logs the fields that really exist (mipLevel/baseArrayLayer/layerCount plus both
// offsets of each side) and does NOT fabricate an extent. (Same class as VkPresentInfoKHR having no
// stageMask.)
// =====================================================================================

// VkImageSubresourceLayers -- official SDK type (vulkan_core.h:4090), shared by VkImageCopy/Blit.
typedef VkImageSubresourceLayers VkImgSubresLayersL;

// vkCmdCopyImage -- header :4586
// PFN_vkCmdCopyImage(VkCommandBuffer commandBuffer, VkImage srcImage, VkImageLayout srcImageLayout,
//                    VkImage dstImage, VkImageLayout dstImageLayout, uint32_t regionCount,
//                    const VkImageCopy* pRegions)
typedef void (*PFN_cmdCopyImage)(void*, void*, uint32_t, void*, uint32_t, uint32_t, const void*);
// VkImageCopy -- official SDK type (vulkan_core.h:4141); accesses use srcSubresource/dstSubresource.
typedef VkImageCopy VkImageCopyL;

static void log_CmdCopyImage(void* cmd, void* srcImage, uint32_t srcLayout, void* dstImage,
                             uint32_t dstLayout, uint32_t regionCount, const void* pRegions) {
    wd_note("vkCmdCopyImage");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdCopyImage, &meow_d_vkCmdCopyImage, "vkCmdCopyImage");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdCopyImage");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdCopyImage CALLED srcImage=%{public}p srcLayout=%{public}u "
                 "dstImage=%{public}p dstLayout=%{public}u regionCount=%{public}u -- forwarding",
                 srcImage, srcLayout, dstImage, dstLayout, regionCount);
        if (regionCount > 0 && regionCount < 4096 && pRegions != NULL) {
            const VkImageCopyL* r0 = (const VkImageCopyL*)pRegions;
            MEOWLOGI("meowvulkan:   copyRegion0 src{mip=%{public}u layer=%{public}u..+%{public}u} "
                     "dst{mip=%{public}u layer=%{public}u..+%{public}u} ext=%{public}u x %{public}u x %{public}u",
                     r0->srcSubresource.mipLevel, r0->srcSubresource.baseArrayLayer, r0->srcSubresource.layerCount,
                     r0->dstSubresource.mipLevel, r0->dstSubresource.baseArrayLayer, r0->dstSubresource.layerCount,
                     r0->extent.width, r0->extent.height, r0->extent.depth);
        }
    }
    ((PFN_cmdCopyImage)real)(cmd, srcImage, srcLayout, dstImage, dstLayout, regionCount, pRegions);
}

// vkCmdBlitImage -- header :4655
// PFN_vkCmdBlitImage(VkCommandBuffer commandBuffer, VkImage srcImage, VkImageLayout srcImageLayout,
//                    VkImage dstImage, VkImageLayout dstImageLayout, uint32_t regionCount,
//                    const VkImageBlit* pRegions, VkFilter filter)
typedef void (*PFN_cmdBlitImage)(void*, void*, uint32_t, void*, uint32_t, uint32_t, const void*,
                                 uint32_t);
// VkImageBlit -- official SDK type (vulkan_core.h:4134). NO extent field exists -- do not add one.
typedef VkImageBlit VkImageBlitL;

static void log_CmdBlitImage(void* cmd, void* srcImage, uint32_t srcLayout, void* dstImage,
                             uint32_t dstLayout, uint32_t regionCount, const void* pRegions,
                             uint32_t filter) {
    wd_note("vkCmdBlitImage");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdBlitImage, &meow_d_vkCmdBlitImage, "vkCmdBlitImage");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBlitImage");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdBlitImage CALLED cmdBuf=%{public}p srcImage=%{public}p srcLayout=%{public}u "
                 "dstImage=%{public}p dstLayout=%{public}u regionCount=%{public}u filter=%{public}u "
                 "(0=NEAREST 1=LINEAR) -- forwarding",
                 cmd, srcImage, srcLayout, dstImage, dstLayout, regionCount, filter);
        if (regionCount > 0 && regionCount < 4096 && pRegions != NULL) {
            const VkImageBlitL* r0 = (const VkImageBlitL*)pRegions;
            MEOWLOGI("meowvulkan:   blitRegion0 src{mip=%{public}u layer=%{public}u..+%{public}u} "
                     "off0=%{public}d,%{public}d,%{public}d off1=%{public}d,%{public}d,%{public}d",
                     r0->srcSubresource.mipLevel, r0->srcSubresource.baseArrayLayer, r0->srcSubresource.layerCount,
                     r0->srcOffsets[0].x, r0->srcOffsets[0].y, r0->srcOffsets[0].z,
                     r0->srcOffsets[1].x, r0->srcOffsets[1].y, r0->srcOffsets[1].z);
            MEOWLOGI("meowvulkan:   blitRegion0 dst{mip=%{public}u layer=%{public}u..+%{public}u} "
                     "off0=%{public}d,%{public}d,%{public}d off1=%{public}d,%{public}d,%{public}d",
                     r0->dstSubresource.mipLevel, r0->dstSubresource.baseArrayLayer, r0->dstSubresource.layerCount,
                     r0->dstOffsets[0].x, r0->dstOffsets[0].y, r0->dstOffsets[0].z,
                     r0->dstOffsets[1].x, r0->dstOffsets[1].y, r0->dstOffsets[1].z);
        }
    }
    ((PFN_cmdBlitImage)real)(cmd, srcImage, srcLayout, dstImage, dstLayout, regionCount, pRegions,
                             filter);
}

// vkCmdClearColorImage -- header :4627
// PFN_vkCmdClearColorImage(VkCommandBuffer commandBuffer, VkImage image, VkImageLayout imageLayout,
//                          const VkClearColorValue* pColor, uint32_t rangeCount,
//                          const VkImageSubresourceRange* pRanges)
typedef void (*PFN_cmdClearColorImage)(void*, void*, uint32_t, const void*, uint32_t, const void*);
// Official SDK types: VkClearColorValue union (vulkan_core.h:4106; members float32/int32/uint32) and
// VkImageSubresourceRange (vulkan_core.h:3112).
typedef VkClearColorValue        VkClearColorValueL;
typedef VkImageSubresourceRange  VkImageSubresourceRangeL;

static void log_CmdClearColorImage(void* cmd, void* image, uint32_t imageLayout, const void* pColor,
                                   uint32_t rangeCount, const void* pRanges) {
    wd_note("vkCmdClearColorImage");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdClearColorImage, &meow_d_vkCmdClearColorImage, "vkCmdClearColorImage");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdClearColorImage");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdClearColorImage CALLED image=%{public}p imageLayout=%{public}u "
                 "rangeCount=%{public}u -- forwarding", image, imageLayout, rangeCount);
        if (rangeCount > 0 && rangeCount < 4096 && pRanges != NULL) {
            const VkImageSubresourceRangeL* r0 = (const VkImageSubresourceRangeL*)pRanges;
            MEOWLOGI("meowvulkan:   clearRange0 aspectMask=0x%{public}x baseMip=%{public}u "
                     "levelCount=%{public}u baseLayer=%{public}u layerCount=%{public}u",
                     r0->aspectMask, r0->baseMipLevel, r0->levelCount, r0->baseArrayLayer,
                     r0->layerCount);
        }
        if (pColor != NULL) {
            const VkClearColorValueL* c = (const VkClearColorValueL*)pColor;
            MEOWLOGI("meowvulkan:   clearColor raw u32=0x%{public}08x,0x%{public}08x,0x%{public}08x,0x%{public}08x",
                     c->uint32[0], c->uint32[1], c->uint32[2], c->uint32[3]);
            MEOWLOGI("meowvulkan:   clearColor as f32=%{public}f,%{public}f,%{public}f,%{public}f",
                     (double)c->float32[0], (double)c->float32[1], (double)c->float32[2], (double)c->float32[3]);
        }
    }
    ((PFN_cmdClearColorImage)real)(cmd, image, imageLayout, pColor, rangeCount, pRanges);
}

// vkCmdSetViewport -- header :4640
// PFN_vkCmdSetViewport(VkCommandBuffer commandBuffer, uint32_t firstViewport, uint32_t viewportCount,
//                      const VkViewport* pViewports)
typedef void (*PFN_cmdSetViewport)(void*, uint32_t, uint32_t, const void*);
// VkViewport -- official SDK type (vulkan_core.h:3751).
typedef VkViewport VkViewportL;

static void log_CmdSetViewport(void* cmd, uint32_t firstViewport, uint32_t viewportCount,
                               const void* pViewports) {
    wd_note("vkCmdSetViewport");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdSetViewport, &meow_d_vkCmdSetViewport, "vkCmdSetViewport");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdSetViewport");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdSetViewport CALLED firstViewport=%{public}u viewportCount=%{public}u "
                 "-- forwarding", firstViewport, viewportCount);
        if (viewportCount > 0 && pViewports != NULL) {
            const VkViewportL* v0 = (const VkViewportL*)pViewports;
            MEOWLOGI("meowvulkan:   viewport0 x=%{public}f y=%{public}f w=%{public}f h=%{public}f "
                     "minDepth=%{public}f maxDepth=%{public}f",
                     (double)v0->x, (double)v0->y, (double)v0->width, (double)v0->height,
                     (double)v0->minDepth, (double)v0->maxDepth);
        }
    }
    ((PFN_cmdSetViewport)real)(cmd, firstViewport, viewportCount, pViewports);
}

// vkCmdSetScissor -- header :4641
// PFN_vkCmdSetScissor(VkCommandBuffer commandBuffer, uint32_t firstScissor, uint32_t scissorCount,
//                     const VkRect2D* pScissors)
typedef void (*PFN_cmdSetScissor)(void*, uint32_t, uint32_t, const void*);
// VkRect2D -- official SDK type (vulkan_core.h:3064); accesses use offset.x/y, extent.width/height.
typedef VkRect2D VkRect2DL;

static void log_CmdSetScissor(void* cmd, uint32_t firstScissor, uint32_t scissorCount,
                              const void* pScissors) {
    wd_note("vkCmdSetScissor");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdSetScissor, &meow_d_vkCmdSetScissor, "vkCmdSetScissor");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdSetScissor");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdSetScissor CALLED firstScissor=%{public}u scissorCount=%{public}u "
                 "-- forwarding", firstScissor, scissorCount);
        if (scissorCount > 0 && pScissors != NULL) {
            const VkRect2DL* s0 = (const VkRect2DL*)pScissors;
            MEOWLOGI("meowvulkan:   scissor0 offset=%{public}d,%{public}d extent=%{public}u x %{public}u",
                     s0->offset.x, s0->offset.y, s0->extent.width, s0->extent.height);
        }
    }
    ((PFN_cmdSetScissor)real)(cmd, firstScissor, scissorCount, pScissors);
}

// vkCmdClearAttachments -- header :4657
// PFN_vkCmdClearAttachments(VkCommandBuffer commandBuffer, uint32_t attachmentCount,
//                           const VkClearAttachment* pAttachments, uint32_t rectCount,
//                           const VkClearRect* pRects)
typedef void (*PFN_cmdClearAttachments)(void*, uint32_t, const void*, uint32_t, const void*);
// VkClearAttachment -- official SDK type (vulkan_core.h:4122); clearValue is the official union, read
// as raw 32-bit words via clearValue.color.uint32[] below.
typedef VkClearAttachment VkClearAttachmentL;

static void log_CmdClearAttachments(void* cmd, uint32_t attachmentCount, const void* pAttachments,
                                    uint32_t rectCount, const void* pRects) {
    wd_note("vkCmdClearAttachments");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdClearAttachments, &meow_d_vkCmdClearAttachments, "vkCmdClearAttachments");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdClearAttachments");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdClearAttachments CALLED attachmentCount=%{public}u rectCount=%{public}u "
                 "-- forwarding", attachmentCount, rectCount);
        if (attachmentCount > 0 && attachmentCount < 4096 && pAttachments != NULL) {
            const VkClearAttachmentL* a0 = (const VkClearAttachmentL*)pAttachments;
            MEOWLOGI("meowvulkan:   clearAttachment0 aspectMask=0x%{public}x colorAttachment=%{public}u "
                     "clearValue.raw=0x%{public}08x,0x%{public}08x,0x%{public}08x,0x%{public}08x",
                     a0->aspectMask, a0->colorAttachment, a0->clearValue.color.uint32[0],
                     a0->clearValue.color.uint32[1], a0->clearValue.color.uint32[2],
                     a0->clearValue.color.uint32[3]);
        }
    }
    ((PFN_cmdClearAttachments)real)(cmd, attachmentCount, pAttachments, rectCount, pRects);
}

// Suffix-stripping fallback. ROOT CAUSE (measured 2026-09-17): this ICD exposes only the core
// (unsuffixed) names and hides the KHR/EXT spellings -- the very reason this shim exists. Our old
// hardcoded map covered just four names, so every other suffixed lookup resolved to NULL. VMA then
// dies: with assertions on, "Assertion failed: m_VulkanFunctions.vkGetPhysicalDeviceProperties2KHR
// != nullptr" (vk_mem_alloc.h:13825); with -DNDEBUG (the shipped build) it keeps running with a NULL
// function pointer and takes a wild low-address read -- which is exactly the "wandering 0xc" crash
// this campaign chased. Stripping the suffix and retrying covers the whole family at once.
static const char* strip_vk_suffix(const char* name, char* buf, size_t n) {
    static const char* kSuffixes[] = { "KHR", "EXT", "AMD", "NV", "GOOGLE", "INTEL" };
    size_t len = (name != NULL) ? strlen(name) : 0;
    for (size_t i = 0; i < sizeof(kSuffixes) / sizeof(kSuffixes[0]); i++) {
        size_t sl = strlen(kSuffixes[i]);
        if (len > sl && !strcmp(name + len - sl, kSuffixes[i])) {
            snprintf(buf, n, "%.*s", (int)(len - sl), name);
            return buf;
        }
    }
    return NULL;
}

// Resolve a forwarded instance-level command through the application's instance.
static PFN_vkVoidFunctionLocal real_proc(const char* name) {
    if (!g_gipa) return NULL;
    PFN_vkVoidFunctionLocal p = g_gipa(g_inst_seen, name);
    if (!p) p = g_gipa(0, name);   // last resort (global commands / lenient loaders)
    if (!p) {
        char stripped[256];
        const char* s = strip_vk_suffix(name, stripped, sizeof(stripped));
        if (s != NULL) {
            p = g_gipa(g_inst_seen, s);
            if (!p) p = g_gipa(0, s);
        }
    }
    return p;
}

// =====================================================================================
// F18 (shim build .17): bounded wrappers for the commands that make a submitted command buffer look
// EMPTY. F17 (.16) only NAMED them (vkCmdPipelineBarrier v1, vkCmdPushConstants, vkCmdUpdateBuffer,
// vkCmdFillBuffer, vkCmdExecuteCommands and the three vkCmd*DebugUtilsLabelEXT commands) via the
// UNWRAPPED catch-all, which fires at LOOKUP time -- so it said what MC *asked for*, never what a
// specific submitted buffer actually recorded. This round gives each one a real wrapper so the
// per-cmdBuf log lines attribute the buffer's real contents. ADDITIVE ONLY: log_CmdCopyBufferToImage
// (:142), log_CmdPipelineBarrier2 (:742), log_CmdBeginRendering (:615), log_CmdEndRendering (:825)
// and the UNWRAPPED catch-all are NOT touched.
//
// Every prototype copies the parameter list verbatim from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361):
//   :4591  PFN_vkCmdPipelineBarrier(VkCommandBuffer, VkPipelineStageFlags, VkPipelineStageFlags,
//                                   VkDependencyFlags, uint32_t, const VkMemoryBarrier*,
//                                   uint32_t, const VkBufferMemoryBarrier*,
//                                   uint32_t, const VkImageMemoryBarrier*)
//   :4633  PFN_vkCmdPushConstants(VkCommandBuffer, VkPipelineLayout, VkShaderStageFlags,
//                                   uint32_t, uint32_t, const void*)
//   :4589  PFN_vkCmdUpdateBuffer(VkCommandBuffer, VkBuffer, VkDeviceSize, VkDeviceSize, const void*)
//   :4590  PFN_vkCmdFillBuffer(VkCommandBuffer, VkBuffer, VkDeviceSize, VkDeviceSize, uint32_t)
//   :4597  PFN_vkCmdExecuteCommands(VkCommandBuffer, uint32_t, const VkCommandBuffer*)
//   :16334 PFN_vkCmdBeginDebugUtilsLabelEXT(VkCommandBuffer, const VkDebugUtilsLabelEXT*)
//   :16335 PFN_vkCmdEndDebugUtilsLabelEXT(VkCommandBuffer)
//   :16336 PFN_vkCmdInsertDebugUtilsLabelEXT(VkCommandBuffer, const VkDebugUtilsLabelEXT*)
// Struct offsets below are machine-checked with _Static_assert against that header's LP64 layout.
// RULE: forward the SAME argument list. No parameter is ever invented, not even for logging.
// =====================================================================================

// vkCmdPipelineBarrier -- header :4591. This is the v1 entry point, DISTINCT from vkCmdPipelineBarrier2
// above (:741). Its srcStageMask/dstStageMask are 32-bit VkPipelineStageFlags (VkFlags = uint32_t,
// header :2953/:97), NOT the 64-bit masks of VkDependencyInfo (VkPipelineStageFlags2 = uint64_t).
// VkImageMemoryBarrier -- official SDK type (vulkan_core.h:3120); subresourceRange is nested, so the
// accesses below use <barrier>.subresourceRange.<member>.
typedef VkImageMemoryBarrier VkImgBarrierL;

// F44: VkDependencyInfo -> vkCmdPipelineBarrier. Forward-declared above (near the sync2
// submit translation) because the v1 image-barrier mirror only exists from here on.
// NOTE: v1 takes ONE src/dst stage pair for the whole call, so the (individually carried)
// v2 stage masks of every barrier are OR-ed into that pair -- the standard, and strictly
// more conservative, translation. Barrier COUNT/order, layouts, queue-family indices,
// ranges and the dependency flags are preserved exactly (only the masks are widened).
static int meow_translate_cmd_pipeline_barrier2(void* cmd, const void* di) {
    void (*real)(void*, uint32_t, uint32_t, uint32_t, uint32_t, const void*, uint32_t, const void*,
                 uint32_t, const void*) =
        (void (*)(void*, uint32_t, uint32_t, uint32_t, uint32_t, const void*, uint32_t, const void*,
                  uint32_t, const void*))(meow_cached_proc(&meow_p_vkCmdPipelineBarrier, &meow_d_vkCmdPipelineBarrier, "vkCmdPipelineBarrier"));
    if (real == NULL) {
        MEOWLOGE("meowvulkan: SYNC2->V1: cannot resolve the real vkCmdPipelineBarrier");
        return -3;
    }
    if (di == NULL) {
        MEOWLOGE("meowvulkan: SYNC2->V1: vkCmdPipelineBarrier2 pDependencyInfo is NULL; dropping");
        return -3;
    }
    const VkDependencyInfoL* d = (const VkDependencyInfoL*)di;
    uint32_t mc = d->memoryBarrierCount;
    uint32_t bc = d->bufferMemoryBarrierCount;
    uint32_t ic = d->imageMemoryBarrierCount;
    if (mc > 4096 || bc > 4096 || ic > 4096) {
        MEOWLOGW("meowvulkan: SYNC2->V1: refusing to translate vkCmdPipelineBarrier2 "
                 "(mem=%{public}u buf=%{public}u img=%{public}u)", mc, bc, ic);
        return -3;
    }
    VkMemBarrierL* mb = NULL;
    VkBufBarrierL* bb = NULL;
    VkImgBarrierL* ib = NULL;
    // F97 (.75): common-case barrier counts reuse the file-level scratch (consumed by the synchronous
    // vkCmdPipelineBarrier below); a count over MEOW_F97_CAP keeps the original calloc. See the F97 block.
    if (mc > 0) {
        mb = (mc <= MEOW_F97_CAP) ? g_f97_b_mem : (VkMemBarrierL*)calloc(mc, sizeof(VkMemBarrierL));
        if (mb == NULL) { MEOWLOGE("meowvulkan: SYNC2->V1: OOM (memory barriers)"); return -3; }
    }
    if (bc > 0) {
        bb = (bc <= MEOW_F97_CAP) ? g_f97_b_buf : (VkBufBarrierL*)calloc(bc, sizeof(VkBufBarrierL));
        if (bb == NULL) { if (mb != g_f97_b_mem) free(mb); MEOWLOGE("meowvulkan: SYNC2->V1: OOM (buffer barriers)"); return -3; }
    }
    if (ic > 0) {
        ib = (ic <= MEOW_F97_CAP) ? g_f97_b_img : (VkImgBarrierL*)calloc(ic, sizeof(VkImgBarrierL));
        if (ib == NULL) { if (mb != g_f97_b_mem) free(mb); if (bb != g_f97_b_buf) free(bb); MEOWLOGE("meowvulkan: SYNC2->V1: OOM (image barriers)"); return -3; }
    }
    int lostBits = 0;
    uint32_t srcStage = 0, dstStage = 0;
    if (mc > 0 && d->pMemoryBarriers != NULL) {
        const VkMemBarrier2L* p = (const VkMemBarrier2L*)d->pMemoryBarriers;
        for (uint32_t k = 0; k < mc; k++) {
            srcStage |= meow_stage2_to_v1(p[k].srcStageMask, &lostBits);
            dstStage |= meow_stage2_to_v1(p[k].dstStageMask, &lostBits);
            mb[k].sType = ST_MEMORY_BARRIER;
            mb[k].pNext = p[k].pNext;
            mb[k].srcAccessMask = meow_access2_to_v1(p[k].srcAccessMask, &lostBits);
            mb[k].dstAccessMask = meow_access2_to_v1(p[k].dstAccessMask, &lostBits);
        }
    }
    if (bc > 0 && d->pBufferMemoryBarriers != NULL) {
        const VkBufBarrier2L* p = (const VkBufBarrier2L*)d->pBufferMemoryBarriers;
        for (uint32_t k = 0; k < bc; k++) {
            srcStage |= meow_stage2_to_v1(p[k].srcStageMask, &lostBits);
            dstStage |= meow_stage2_to_v1(p[k].dstStageMask, &lostBits);
            bb[k].sType = ST_BUFFER_MEMORY_BARRIER;
            bb[k].pNext = p[k].pNext;
            bb[k].srcAccessMask = meow_access2_to_v1(p[k].srcAccessMask, &lostBits);
            bb[k].dstAccessMask = meow_access2_to_v1(p[k].dstAccessMask, &lostBits);
            bb[k].srcQueueFamilyIndex = p[k].srcQueueFamilyIndex;
            bb[k].dstQueueFamilyIndex = p[k].dstQueueFamilyIndex;
            bb[k].buffer = p[k].buffer;
            bb[k].offset = p[k].offset;
            bb[k].size = p[k].size;
        }
    }
    if (ic > 0 && d->pImageMemoryBarriers != NULL) {
        const VkImgBarrier2L* p = (const VkImgBarrier2L*)d->pImageMemoryBarriers;
        for (uint32_t k = 0; k < ic; k++) {
            srcStage |= meow_stage2_to_v1(p[k].srcStageMask, &lostBits);
            dstStage |= meow_stage2_to_v1(p[k].dstStageMask, &lostBits);
            ib[k].sType = ST_IMAGE_MEMORY_BARRIER;
            ib[k].pNext = p[k].pNext;
            ib[k].srcAccessMask = meow_access2_to_v1(p[k].srcAccessMask, &lostBits);
            ib[k].dstAccessMask = meow_access2_to_v1(p[k].dstAccessMask, &lostBits);
            ib[k].oldLayout = p[k].oldLayout;
            ib[k].newLayout = p[k].newLayout;
            ib[k].srcQueueFamilyIndex = p[k].srcQueueFamilyIndex;
            ib[k].dstQueueFamilyIndex = p[k].dstQueueFamilyIndex;
            ib[k].image = p[k].image;
            ib[k].subresourceRange.aspectMask = p[k].subresourceRange.aspectMask;
            ib[k].subresourceRange.baseMipLevel = p[k].subresourceRange.baseMipLevel;
            ib[k].subresourceRange.levelCount = p[k].subresourceRange.levelCount;
            ib[k].subresourceRange.baseArrayLayer = p[k].subresourceRange.baseArrayLayer;
            ib[k].subresourceRange.layerCount = p[k].subresourceRange.layerCount;
        }
    }
    real(cmd, srcStage, dstStage, d->dependencyFlags, mc, mb, bc, bb, ic, ib);
    // F55 (shim build .35): this is ONE line per barrier translation (measured 6954/run -- the single
    // biggest source) -> rate-limit. First 8 individually (proves the barrier path at boot), then one
    // summary every 500 with the running total; MEOW_VK_VERBOSE=1 restores every line. Every failure
    // path above is MEOWLOGE/WARN and is never suppressed. static counter = render-thread only.
    ++g_sync2v1_barriers;
    {
        static unsigned long s_barrier_xlate_total = 0;
        ++s_barrier_xlate_total;
        if (meow_vk_verbose() || s_barrier_xlate_total <= 8ul) {
            MEOWLOGI("meowvulkan: SYNC2->V1 translate vkCmdPipelineBarrier2 -> vkCmdPipelineBarrier "
                     "#%{public}lu mem=%{public}u buf=%{public}u img=%{public}u "
                     "srcStage=0x%{public}x dstStage=0x%{public}x depFlags=0x%{public}x foldedMaskBits=%{public}d",
                     g_sync2v1_barriers, mc, bc, ic, srcStage, dstStage, d->dependencyFlags, lostBits);
        } else if ((s_barrier_xlate_total % 20000ul) == 0ul) {
            MEOWLOGI("meowvulkan: SYNC2->V1 barrier translate summary: total=%{public}lu (#%{public}lu) "
                     "mem=%{public}u buf=%{public}u img=%{public}u srcStage=0x%{public}x dstStage=0x%{public}x "
                     "foldedMaskBits=%{public}d",
                     s_barrier_xlate_total, g_sync2v1_barriers, mc, bc, ic, srcStage, dstStage, lostBits);
        }
    }
    // F47: one compact summary of the TRANSLATED PRODUCT (counts + masks only, no pointers).
    // F54: per-barrier detail -> verbose; the "SYNC2->V1 translate ..." line above is the kept signal.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: translated barrier: mem=%{public}u buf=%{public}u img=%{public}u "
                 "srcStage=0x%{public}x dstStage=0x%{public}x",
                 mc, bc, ic, srcStage, dstStage);
    if (mb != g_f97_b_mem) free(mb);
    if (bb != g_f97_b_buf) free(bb);
    if (ib != g_f97_b_img) free(ib);
    return 0;
}

typedef void (*PFN_cmdPipelineBarrier)(void*, uint32_t, uint32_t, uint32_t, uint32_t, const void*,
                                       uint32_t, const void*, uint32_t, const void*);
static void log_CmdPipelineBarrier(void* cmd, uint32_t srcStageMask, uint32_t dstStageMask,
                                   uint32_t dependencyFlags, uint32_t memoryBarrierCount,
                                   const void* pMemoryBarriers, uint32_t bufferMemoryBarrierCount,
                                   const void* pBufferMemoryBarriers, uint32_t imageMemoryBarrierCount,
                                   const void* pImageMemoryBarriers) {
    wd_note("vkCmdPipelineBarrier");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdPipelineBarrier, &meow_d_vkCmdPipelineBarrier, "vkCmdPipelineBarrier");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdPipelineBarrier");
        return;
    }
    // srcStageMask/dstStageMask are 32-bit here (0x%x) -- deliberately NOT the 64-bit v2 masks.
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdPipelineBarrier CALLED cmdBuf=%{public}p srcStageMask=0x%{public}x "
                 "dstStageMask=0x%{public}x dependencyFlags=0x%{public}x memoryBarrierCount=%{public}u "
                 "bufferMemoryBarrierCount=%{public}u imageMemoryBarrierCount=%{public}u -- forwarding",
                 cmd, srcStageMask, dstStageMask, dependencyFlags, memoryBarrierCount,
                 bufferMemoryBarrierCount, imageMemoryBarrierCount);
        if (imageMemoryBarrierCount > 0 && pImageMemoryBarriers != NULL) {
            const VkImgBarrierL* b = (const VkImgBarrierL*)pImageMemoryBarriers;
            MEOWLOGI("meowvulkan:   imgBarrier0 oldLayout=%{public}d newLayout=%{public}d "
                     "srcStageMask=0x%{public}x dstStageMask=0x%{public}x aspectMask=0x%{public}x image=%{public}p",
                     b->oldLayout, b->newLayout, srcStageMask, dstStageMask,
                     b->subresourceRange.aspectMask, b->image);
        }
    }
    ((PFN_cmdPipelineBarrier)real)(cmd, srcStageMask, dstStageMask, dependencyFlags,
                                   memoryBarrierCount, pMemoryBarriers, bufferMemoryBarrierCount,
                                   pBufferMemoryBarriers, imageMemoryBarrierCount, pImageMemoryBarriers);
}

// vkCmdPushConstants -- header :4633. VkShaderStageFlags is 32-bit (header :2906/:97); VkPipelineLayout
// is a non-dispatchable handle => pointer on this ABI. pValues is NOT read (only the range is logged).
typedef void (*PFN_cmdPushConstants)(void*, void*, uint32_t, uint32_t, uint32_t, const void*);
static void log_CmdPushConstants(void* cmd, void* layout, uint32_t stageFlags, uint32_t offset,
                                 uint32_t size, const void* pValues) {
    wd_note("vkCmdPushConstants");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdPushConstants, &meow_d_vkCmdPushConstants, "vkCmdPushConstants");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdPushConstants");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdPushConstants CALLED cmdBuf=%{public}p layout=%{public}p "
                 "stageFlags=0x%{public}x offset=%{public}u size=%{public}u -- forwarding",
                 cmd, layout, stageFlags, offset, size);
    ((PFN_cmdPushConstants)real)(cmd, layout, stageFlags, offset, size, pValues);
}

// vkCmdUpdateBuffer -- header :4589. dstOffset/dataSize are VkDeviceSize (uint64_t, header :96) ->
// %{public}llu, never truncated. pData is a caller buffer, logged as a pointer only.
typedef void (*PFN_cmdUpdateBuffer)(void*, void*, uint64_t, uint64_t, const void*);
static void log_CmdUpdateBuffer(void* cmd, void* dstBuffer, uint64_t dstOffset, uint64_t dataSize,
                                const void* pData) {
    wd_note("vkCmdUpdateBuffer");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdUpdateBuffer, &meow_d_vkCmdUpdateBuffer, "vkCmdUpdateBuffer");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdUpdateBuffer");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdUpdateBuffer CALLED cmdBuf=%{public}p dstBuffer=%{public}p "
                 "dstOffset=%{public}llu dataSize=%{public}llu pData=%{public}p -- forwarding",
                 cmd, dstBuffer, (unsigned long long)dstOffset, (unsigned long long)dataSize, pData);
    ((PFN_cmdUpdateBuffer)real)(cmd, dstBuffer, dstOffset, dataSize, pData);
}

// vkCmdFillBuffer -- header :4590 (dstOffset/size are VkDeviceSize; data is one 32-bit word).
typedef void (*PFN_cmdFillBuffer)(void*, void*, uint64_t, uint64_t, uint32_t);
static void log_CmdFillBuffer(void* cmd, void* dstBuffer, uint64_t dstOffset, uint64_t size,
                              uint32_t data) {
    wd_note("vkCmdFillBuffer");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdFillBuffer, &meow_d_vkCmdFillBuffer, "vkCmdFillBuffer");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdFillBuffer");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdFillBuffer CALLED cmdBuf=%{public}p dstBuffer=%{public}p "
                 "dstOffset=%{public}llu size=%{public}llu data=0x%{public}x -- forwarding",
                 cmd, dstBuffer, (unsigned long long)dstOffset, (unsigned long long)size, data);
    ((PFN_cmdFillBuffer)real)(cmd, dstBuffer, dstOffset, size, data);
}

// vkCmdExecuteCommands -- header :4597. pCommandBuffers is an array of dispatchable VkCommandBuffer
// handles (pointers on this ABI); the first two are logged so a non-empty SECONDARY buffer is exposed.
typedef void (*PFN_cmdExecuteCommands)(void*, uint32_t, const void*);
static void log_CmdExecuteCommands(void* cmd, uint32_t commandBufferCount, const void* pCommandBuffers) {
    wd_note("vkCmdExecuteCommands");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdExecuteCommands, &meow_d_vkCmdExecuteCommands, "vkCmdExecuteCommands");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdExecuteCommands");
        return;
    }
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdExecuteCommands CALLED cmdBuf=%{public}p commandBufferCount=%{public}u "
                 "-- forwarding", cmd, commandBufferCount);
        if (commandBufferCount > 0 && pCommandBuffers != NULL) {
            const void* const* h = (const void* const*)pCommandBuffers;
            MEOWLOGI("meowvulkan:   secondary[0]=%{public}p secondary[1]=%{public}p",
                     h[0], (commandBufferCount > 1) ? h[1] : NULL);
        }
    }
    ((PFN_cmdExecuteCommands)real)(cmd, commandBufferCount, pCommandBuffers);
}

// vkCmd*DebugUtilsLabelEXT -- header :16334/:16335/:16336. These are DEVICE-level commands, but the
// F17 device log shows MC resolving them through vkGetInstanceProcAddr ("UNWRAPPED instance
// vkCmdBeginDebugUtilsLabelEXT"), so the wrappers are registered in BOTH vkGetInstanceProcAddr and
// vkGetDeviceProcAddr and resolution prefers g_gdpa, then falls back to the instance path. The real
// name keeps its EXT suffix (it is part of the name, unlike the KHR core aliases).
// VkDebugUtilsLabelEXT -- official SDK type (vulkan_core.h:14153).
typedef VkDebugUtilsLabelEXT VkDebugUtilsLabelL;

// F92 (.70): the DebugUtils labels are recorded every frame (F15/F18), so the g_gdpa-first,
// instance-fallback resolution is now cached per wrapper (same F87 pair/atomic contract). Once
// resolved the cost is one pointer compare; if BOTH paths return NULL the slot stays NULL and the
// lookup is retried unchanged.
static PFN_vkVoidFunctionLocal resolve_debug_label(PFN_vkVoidFunctionLocal* slot, void** devSlot,
                                                   const char* name) {
    void* dev = (void*)g_dev_seen;
    void* cachedDev = __atomic_load_n(devSlot, __ATOMIC_ACQUIRE);
    PFN_vkVoidFunctionLocal p = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (p == NULL || cachedDev != dev) {
        p = g_gdpa ? g_gdpa(g_dev_seen, name) : NULL;
        if (p == NULL) p = real_proc(name);   // instance-path resolution (how MC asked for these)
        __atomic_store_n(devSlot, dev, __ATOMIC_RELAXED);
        __atomic_store_n(slot, p, __ATOMIC_RELEASE);
    }
    return p;
}

typedef void (*PFN_cmdBeginDebugUtilsLabelEXT)(void*, const void*);
static void log_CmdBeginDebugUtilsLabelEXT(void* cmd, const void* pLabelInfo) {
    wd_note("vkCmdBeginDebugUtilsLabelEXT");
    PFN_vkVoidFunctionLocal real = resolve_debug_label(&meow_p_vkCmdBeginDebugUtilsLabelEXT,
        &meow_d_vkCmdBeginDebugUtilsLabelEXT, "vkCmdBeginDebugUtilsLabelEXT");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdBeginDebugUtilsLabelEXT");
        return;
    }
    const VkDebugUtilsLabelL* li = (const VkDebugUtilsLabelL*)pLabelInfo;
    const char* label = (li != NULL) ? li->pLabelName : NULL;   // null-check BEFORE any dereference
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdBeginDebugUtilsLabelEXT CALLED cmdBuf=%{public}p label=%{public}s "
                 "-- forwarding", cmd, (label != NULL) ? label : "(null)");
    ((PFN_cmdBeginDebugUtilsLabelEXT)real)(cmd, pLabelInfo);
}

typedef void (*PFN_cmdEndDebugUtilsLabelEXT)(void*);
static void log_CmdEndDebugUtilsLabelEXT(void* cmd) {
    wd_note("vkCmdEndDebugUtilsLabelEXT");
    PFN_vkVoidFunctionLocal real = resolve_debug_label(&meow_p_vkCmdEndDebugUtilsLabelEXT,
        &meow_d_vkCmdEndDebugUtilsLabelEXT, "vkCmdEndDebugUtilsLabelEXT");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdEndDebugUtilsLabelEXT");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdEndDebugUtilsLabelEXT CALLED cmdBuf=%{public}p -- forwarding", cmd);
    ((PFN_cmdEndDebugUtilsLabelEXT)real)(cmd);
}

typedef void (*PFN_cmdInsertDebugUtilsLabelEXT)(void*, const void*);
static void log_CmdInsertDebugUtilsLabelEXT(void* cmd, const void* pLabelInfo) {
    wd_note("vkCmdInsertDebugUtilsLabelEXT");
    PFN_vkVoidFunctionLocal real = resolve_debug_label(&meow_p_vkCmdInsertDebugUtilsLabelEXT,
        &meow_d_vkCmdInsertDebugUtilsLabelEXT, "vkCmdInsertDebugUtilsLabelEXT");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdInsertDebugUtilsLabelEXT");
        return;
    }
    const VkDebugUtilsLabelL* li = (const VkDebugUtilsLabelL*)pLabelInfo;
    const char* label = (li != NULL) ? li->pLabelName : NULL;   // null-check BEFORE any dereference
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdInsertDebugUtilsLabelEXT CALLED cmdBuf=%{public}p label=%{public}s "
                 "-- forwarding", cmd, (label != NULL) ? label : "(null)");
    ((PFN_cmdInsertDebugUtilsLabelEXT)real)(cmd, pLabelInfo);
}

// =====================================================================================
// F19 (shim build .18): vkCmdPushDescriptorSetWithTemplate (+ KHR) -- the LAST unwrapped command
// path. F16 (.15) showed map_name() already folds the KHR spelling, but no wrapper existed, so MC's
// descriptor-update path (push + template; vkCmdBindDescriptorSets is never called) bypassed the shim
// and the buffer it recorded still read as EMPTY in vkQueueSubmit2 -- the second-submit
// VK_ERROR_DEVICE_LOST. This round wraps BOTH the template creation (so the template's SHAPE is known)
// and the push (so cmdBuf + template + layout + set + pData are attributed to the buffer).
//
// Every prototype copies the parameter list verbatim from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361):
//   :8825  PFN_vkCmdPushDescriptorSetWithTemplate(VkCommandBuffer, VkDescriptorUpdateTemplate,
//                                                  VkPipelineLayout, uint32_t, const void*)
//   :8882  vkCmdPushDescriptorSetWithTemplate(VkCommandBuffer, VkDescriptorUpdateTemplate,
//                                             VkPipelineLayout, uint32_t, const void*)
//   :10702 PFN_vkCmdPushDescriptorSetWithTemplateKHR(same list)
//   :10716 vkCmdPushDescriptorSetWithTemplateKHR(same list)
//   :6186  PFN_vkCreateDescriptorUpdateTemplate(VkDevice,
//                                               const VkDescriptorUpdateTemplateCreateInfo*,
//                                               const VkAllocationCallbacks*,
//                                               VkDescriptorUpdateTemplate*)
//   :6306  vkCreateDescriptorUpdateTemplate(VkDevice, const VkDescriptorUpdateTemplateCreateInfo*,
//                                           const VkAllocationCallbacks*, VkDescriptorUpdateTemplate*)
// NOTE: vkCmdPushDescriptorSetWithTemplate has NO pipelineBindPoint parameter (that field belongs to
// vkCmdPushDescriptorSet, header :8824). The bind point comes from the template itself; we read it from
// the cached VkDescriptorUpdateTemplateCreateInfo.pipelineBindPoint and NEVER invent a parameter.
// RULE: forward the SAME argument list. No parameter is ever added, not even for logging.
// =====================================================================================

// VkDescriptorUpdateTemplateEntry -- official SDK type (vulkan_core.h:5667).
typedef VkDescriptorUpdateTemplateEntry VkDUTEntryL;

// VkDescriptorUpdateTemplateCreateInfo -- official SDK type (vulkan_core.h:5676).
typedef VkDescriptorUpdateTemplateCreateInfo VkDUTCreateInfoL;

// Bounded cache: template handle -> the shape MC created it with. Written once per create, read on
// every push. <=32 templates is far above what MC creates; overflow is logged, never silent. A lock is
// taken only around the array itself, NEVER around the real Vulkan call, so no driver code runs under it.
#define MEOW_DUT_MAX 32
typedef struct { void* tmpl; uint32_t entryCount, templateType, pipelineBindPoint, set;
                 void* pipelineLayout;
                 uint32_t dstBinding, dstArrayElement, descriptorCount, descriptorType;
                 uint64_t offset, stride; } MeowDutShape;
static MeowDutShape g_dut_shapes[MEOW_DUT_MAX];
static int g_dut_count = 0;
static pthread_mutex_t g_dut_lock = PTHREAD_MUTEX_INITIALIZER;

static void dut_record(const MeowDutShape* s) {
    pthread_mutex_lock(&g_dut_lock);
    if (g_dut_count >= MEOW_DUT_MAX) {
        MEOWLOGW("meowvulkan: template cache full (%{public}d); shape not recorded", g_dut_count);
    } else {
        g_dut_shapes[g_dut_count++] = *s;
    }
    pthread_mutex_unlock(&g_dut_lock);
}

static int dut_lookup(void* tmpl, MeowDutShape* out) {
    int found = 0;
    pthread_mutex_lock(&g_dut_lock);
    for (int i = 0; i < g_dut_count; i++) {
        if (g_dut_shapes[i].tmpl == tmpl) { *out = g_dut_shapes[i]; found = 1; break; }
    }
    pthread_mutex_unlock(&g_dut_lock);
    return found;
}

// vkCreateDescriptorUpdateTemplate -- header :6186/:6306. The create-side wrapper: it records the
// template's SHAPE so the push-side wrapper can interpret pData. pCreateInfo/pDescriptorUpdateEntries
// are null-checked BEFORE any dereference (caller may pass count 0 / QUERY).
typedef int (*PFN_createDUT)(void*, const void*, const void*, void**);
static int log_CreateDescriptorUpdateTemplate(void* dev, const void* pCreateInfo,
                                              const void* pAllocator, void** pTemplate) {
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkCreateDescriptorUpdateTemplate") : NULL;
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCreateDescriptorUpdateTemplate");
        return -3;   // VK_ERROR_INITIALIZATION_FAILED
    }
    int rc = ((PFN_createDUT)real)(dev, pCreateInfo, pAllocator, pTemplate);
    if (rc != VK_SUCCESS) {
        MEOWLOGI("meowvulkan: vkCreateDescriptorUpdateTemplate rc=%{public}d (failed)", rc);
        return rc;
    }
    if (pCreateInfo == NULL) return rc;
    const VkDUTCreateInfoL* ci = (const VkDUTCreateInfoL*)pCreateInfo;
    void* tmpl = (pTemplate != NULL) ? *pTemplate : NULL;
    MEOWLOGI("meowvulkan: vkCreateDescriptorUpdateTemplate rc=%{public}d template=%{public}p "
             "templateType=%{public}u entryCount=%{public}u flags=0x%{public}x set=%{public}u "
             "pipelineBindPoint=%{public}d descriptorSetLayout=%{public}p pipelineLayout=%{public}p",
             rc, tmpl, ci->templateType, ci->descriptorUpdateEntryCount, ci->flags, ci->set,
             ci->pipelineBindPoint, ci->descriptorSetLayout, ci->pipelineLayout);
    if (ci->descriptorUpdateEntryCount > 0 && ci->pDescriptorUpdateEntries != NULL) {
        const VkDUTEntryL* e = &ci->pDescriptorUpdateEntries[0];
        MEOWLOGI("meowvulkan:   entry0{dstBinding=%{public}u dstArrayElement=%{public}u "
                 "descriptorCount=%{public}u descriptorType=%{public}d offset=%{public}llu "
                 "stride=%{public}llu}",
                 e->dstBinding, e->dstArrayElement, e->descriptorCount, e->descriptorType,
                 (unsigned long long)e->offset, (unsigned long long)e->stride);
        if (tmpl != NULL) {
            MeowDutShape s;
            memset(&s, 0, sizeof(s));
            s.tmpl = tmpl;
            s.entryCount = ci->descriptorUpdateEntryCount;
            s.templateType = ci->templateType;
            s.pipelineBindPoint = ci->pipelineBindPoint;
            s.set = ci->set;
            s.pipelineLayout = ci->pipelineLayout;
            s.dstBinding = e->dstBinding;
            s.dstArrayElement = e->dstArrayElement;
            s.descriptorCount = e->descriptorCount;
            s.descriptorType = e->descriptorType;
            s.offset = e->offset;
            s.stride = e->stride;
            dut_record(&s);
        }
    } else {
        MEOWLOGI("meowvulkan:   (no update entries: entryCount=%{public}u pEntries=%{public}p)",
                 ci->descriptorUpdateEntryCount, ci->pDescriptorUpdateEntries);
    }
    return rc;
}

// vkCmdPushDescriptorSetWithTemplate -- header :8825/:8882 (core) and :10702/:10716 (KHR alias,
// identical list). FIVE parameters, NO pipelineBindPoint. pData is interpreted ONLY when the template
// handle is in the shape cache; NULL pData is never read (it is logged as (nil) by %p and the memcpy
// below is guarded by pData != NULL). Only 8 safe bytes are read, at the shape's entry0.offset.
typedef void (*PFN_cmdPushDescriptorSetWithTemplate)(void*, void*, void*, uint32_t, const void*);
static void log_CmdPushDescriptorSetWithTemplate(void* cmd, void* tmpl, void* layout, uint32_t set,
                                                 const void* pData) {
    wd_note("vkCmdPushDescriptorSetWithTemplate");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdPushDescriptorSetWithTemplate, &meow_d_vkCmdPushDescriptorSetWithTemplate, "vkCmdPushDescriptorSetWithTemplate");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdPushDescriptorSetWithTemplate");
        return;
    }
    // F72b (build .50): this form is deliberately NOT emulated this round; count it (rate-limited) so
    // the log can state whether MC actually depends on the template push path.
    static unsigned long f72bWtN = 0;
    unsigned long wtN = ++f72bWtN;
    if (meow_vk_verbose() || wtN <= 4ul)
        MEOWLOGW("meowvulkan: F72b WithTemplate push seen: %{public}lu (not emulated, forwarding)", wtN);
    else if ((wtN % 20000ul) == 0ul)
        MEOWLOGW("meowvulkan: F72b WithTemplate pushes so far: %{public}lu (rate-limited, not emulated)", wtN);
    if (meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: vkCmdPushDescriptorSetWithTemplate CALLED cmdBuf=%{public}p "
                 "template=%{public}p layout=%{public}p set=%{public}u pData=%{public}p -- forwarding",
                 cmd, tmpl, layout, set, pData);
        MeowDutShape s;
        if (dut_lookup(tmpl, &s)) {
            MEOWLOGI("meowvulkan:   shape{templateType=%{public}u entryCount=%{public}u "
                     "pipelineBindPoint=%{public}d set=%{public}u entry0{dstBinding=%{public}u "
                     "dstArrayElement=%{public}u descriptorCount=%{public}u descriptorType=%{public}d "
                     "offset=%{public}llu stride=%{public}llu}}",
                     s.templateType, s.entryCount, s.pipelineBindPoint, s.set, s.dstBinding,
                     s.dstArrayElement, s.descriptorCount, s.descriptorType,
                     (unsigned long long)s.offset, (unsigned long long)s.stride);
            if (pData != NULL && s.offset <= 4096) {
                uint64_t raw = 0;
                memcpy(&raw, (const unsigned char*)pData + s.offset, sizeof(raw));   // null-checked above
                MEOWLOGI("meowvulkan:   pData+entry0.offset first 8 bytes=0x%{public}llx "
                         "(descriptor data: handle for sampler/imageView/buffer, or inline value)",
                         (unsigned long long)raw);
            } else {
                MEOWLOGI("meowvulkan:   pData=%{public}p (offset=%{public}llu) -- descriptor data NOT read",
                         pData, (unsigned long long)s.offset);
            }
        } else {
            MEOWLOGI("meowvulkan:   template=%{public}p not in shape cache -- data not interpreted", tmpl);
        }
    }
    ((PFN_cmdPushDescriptorSetWithTemplate)real)(cmd, tmpl, layout, set, pData);
}

// =====================================================================================
// F21 (shim build .19): the event / timestamp command family -- the last unobserved family and the
// prime suspect for the second submit's VK_ERROR_DEVICE_LOST. Working hypothesis: a vkCmdWaitEvents2
// (or v1 vkCmdWaitEvents) in the SECOND frame waits on an event that is never set, so the GPU stops
// forever and the timeline semaphore never advances -- reported as DEVICE_LOST. The .16 UNWRAPPED list
// showed MC PARSED these names, yet not one of them had a wrapper, so each bypassed the shim entirely.
// This round gives every one a real wrapper so a per-cmdBuf line names the event/query/stage involved.
//
// Every prototype copies the parameter list VERBATIM from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361):
//   :4595  PFN_vkCmdWriteTimestamp(VkCommandBuffer, VkPipelineStageFlagBits, VkQueryPool, uint32_t)
//   :4630  PFN_vkCmdSetEvent(VkCommandBuffer, VkEvent, VkPipelineStageFlags)
//   :4631  PFN_vkCmdResetEvent(VkCommandBuffer, VkEvent, VkPipelineStageFlags)
//   :4632  PFN_vkCmdWaitEvents(VkCommandBuffer, uint32_t, const VkEvent*, VkPipelineStageFlags,
//                              VkPipelineStageFlags, uint32_t, const VkMemoryBarrier*,
//                              uint32_t, const VkBufferMemoryBarrier*, uint32_t,
//                              const VkImageMemoryBarrier*)
//   :7970  PFN_vkCmdWriteTimestamp2(VkCommandBuffer, VkPipelineStageFlags2, VkQueryPool, uint32_t)
//   :7979  PFN_vkCmdSetEvent2(VkCommandBuffer, VkEvent, const VkDependencyInfo*)
//   :7980  PFN_vkCmdResetEvent2(VkCommandBuffer, VkEvent, VkPipelineStageFlags2)
//   :7981  PFN_vkCmdWaitEvents2(VkCommandBuffer, uint32_t, const VkEvent*, const VkDependencyInfo*)
//   :12431 :12432 :12433 :12435  the KHR aliases (vkCmdSetEvent2KHR / vkCmdResetEvent2KHR /
//                              vkCmdWaitEvents2KHR / vkCmdWriteTimestamp2KHR), identical parameter
//                              lists; map_name() folds them onto the core names the ICD exposes.
// The v1 commands have NO KHR spelling in this header (grep: 0 hits for vkCmdSetEventKHR &
// vkCmdResetEventKHR & vkCmdWaitEventsKHR & vkCmdWriteTimestampKHR), so none is invented here.
//
// HANDLE / MASK TYPES (this decides the print verb, per the iron rule):
//   VkEvent     -- VK_DEFINE_NON_DISPATCHABLE_HANDLE(VkEvent),     header :114 (macro :54-:60)
//   VkQueryPool -- VK_DEFINE_NON_DISPATCHABLE_HANDLE(VkQueryPool), header :109
//     On this LP64 target VK_USE_64_BIT_PTR_DEFINES==1 (header :30), so the macro picks the POINTER
//     typedef (:56); the alternate branch (:58) is `typedef uint64_t`. Either way a handle is exactly
//     ONE 64-bit word/register, so it is logged as a 64-bit value with 0x%{public}llx after an
//     (unsigned long long) cast -- never `%p` -- matching the file's VkSemaphoreL convention (:395).
//   VkPipelineStageFlags  = VkFlags   = uint32_t -> 0x%x   (header :2953, :97)
//   VkPipelineStageFlags2 = VkFlags64 = uint64_t -> 0x%llx (header :7137, :7112)
//   VkPipelineStageFlagBits (the v1 `stage`) is a 32-bit enum -> 0x%x (header :2952).
// RULE: forward the SAME argument list. No parameter is ever invented, not even for logging.
// =====================================================================================

// Official non-dispatchable handles (vulkan_core.h); one 64-bit word on this LP64 target.
typedef VkEvent     VkEventL;
typedef VkQueryPool VkQueryPoolL;
_Static_assert(sizeof(VkEventL) == 8, "VkEvent is a 64-bit non-dispatchable handle");
_Static_assert(sizeof(VkQueryPoolL) == 8, "VkQueryPool is a 64-bit non-dispatchable handle");

// VkDependencyInfo mirror -- the same VkDependencyInfoL already declared at :735 (header :7569). These
// asserts pin its LP64 layout here as well, where the v2 event wrappers consume it.
_Static_assert(sizeof(VkDependencyInfoL) == 64, "VkDependencyInfo must be 64 bytes on LP64");
_Static_assert(offsetof(VkDependencyInfoL, dependencyFlags) == 16, "VkDependencyInfo.dependencyFlags offset");
_Static_assert(offsetof(VkDependencyInfoL, memoryBarrierCount) == 20, "VkDependencyInfo.memoryBarrierCount offset");
_Static_assert(offsetof(VkDependencyInfoL, pMemoryBarriers) == 24, "VkDependencyInfo.pMemoryBarriers offset");
_Static_assert(offsetof(VkDependencyInfoL, bufferMemoryBarrierCount) == 32, "VkDependencyInfo.bufferMemoryBarrierCount offset");
_Static_assert(offsetof(VkDependencyInfoL, imageMemoryBarrierCount) == 48, "VkDependencyInfo.imageMemoryBarrierCount offset");

// ---- v1 event family (32-bit stage masks) --------------------------------------------------------

// vkCmdSetEvent -- header :4630. VkPipelineStageFlags is 32-bit; VkEvent is a 64-bit handle.
typedef void (*PFN_cmdSetEvent)(void*, uint64_t, uint32_t);
static void log_CmdSetEvent(void* cmd, uint64_t event, uint32_t stageMask) {
    wd_note("vkCmdSetEvent");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdSetEvent, &meow_d_vkCmdSetEvent, "vkCmdSetEvent");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdSetEvent");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdSetEvent CALLED cmdBuf=%{public}p event=0x%{public}llx "
                 "stageMask=0x%{public}x -- forwarding", cmd, (unsigned long long)event,
                 (unsigned)stageMask);
    ((PFN_cmdSetEvent)real)(cmd, event, stageMask);
}

// vkCmdResetEvent -- header :4631. Same shape as vkCmdSetEvent.
typedef void (*PFN_cmdResetEvent)(void*, uint64_t, uint32_t);
static void log_CmdResetEvent(void* cmd, uint64_t event, uint32_t stageMask) {
    wd_note("vkCmdResetEvent");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdResetEvent, &meow_d_vkCmdResetEvent, "vkCmdResetEvent");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdResetEvent");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdResetEvent CALLED cmdBuf=%{public}p event=0x%{public}llx "
                 "stageMask=0x%{public}x -- forwarding", cmd, (unsigned long long)event,
                 (unsigned)stageMask);
    ((PFN_cmdResetEvent)real)(cmd, event, stageMask);
}

// vkCmdWaitEvents -- header :4632 (11 parameters). pEvents is an array of 64-bit VkEvent handles; only
// the first two are read, and only when eventCount says they exist. The three barrier counts are read
// but the barrier arrays are NOT walked (a hanging wait is identified by the events + stage masks).
typedef void (*PFN_cmdWaitEvents)(void*, uint32_t, const void*, uint32_t, uint32_t, uint32_t,
                                  const void*, uint32_t, const void*, uint32_t, const void*);
static void log_CmdWaitEvents(void* cmd, uint32_t eventCount, const void* pEvents,
                              uint32_t srcStageMask, uint32_t dstStageMask,
                              uint32_t memoryBarrierCount, const void* pMemoryBarriers,
                              uint32_t bufferMemoryBarrierCount, const void* pBufferMemoryBarriers,
                              uint32_t imageMemoryBarrierCount, const void* pImageMemoryBarriers) {
    wd_note("vkCmdWaitEvents");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdWaitEvents, &meow_d_vkCmdWaitEvents, "vkCmdWaitEvents");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdWaitEvents");
        return;
    }
    uint64_t e0 = 0, e1 = 0;
    if (eventCount > 0 && pEvents != NULL) {
        const uint64_t* ev = (const uint64_t*)pEvents;
        e0 = ev[0];
        if (eventCount > 1) e1 = ev[1];
    }
    // srcStageMask/dstStageMask are 32-bit here (0x%x) -- deliberately NOT the 64-bit v2 masks.
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdWaitEvents CALLED cmdBuf=%{public}p eventCount=%{public}u "
                 "event0=0x%{public}llx event1=0x%{public}llx srcStageMask=0x%{public}x "
                 "dstStageMask=0x%{public}x memoryBarrierCount=%{public}u bufferMemoryBarrierCount=%{public}u "
                 "imageMemoryBarrierCount=%{public}u -- forwarding",
                 cmd, eventCount, (unsigned long long)e0, (unsigned long long)e1, (unsigned)srcStageMask,
                 (unsigned)dstStageMask, memoryBarrierCount, bufferMemoryBarrierCount,
                 imageMemoryBarrierCount);
    ((PFN_cmdWaitEvents)real)(cmd, eventCount, pEvents, srcStageMask, dstStageMask,
                              memoryBarrierCount, pMemoryBarriers, bufferMemoryBarrierCount,
                              pBufferMemoryBarriers, imageMemoryBarrierCount, pImageMemoryBarriers);
}

// ---- v2 event family (64-bit stage masks; KHR aliases folded by map_name()) -----------------------

// vkCmdSetEvent2 -- header :7979. pDependencyInfo is a VkDependencyInfo*; its counts/flags are logged.
typedef void (*PFN_cmdSetEvent2)(void*, uint64_t, const void*);
static void log_CmdSetEvent2(void* cmd, uint64_t event, const void* pDependencyInfo) {
    wd_note("vkCmdSetEvent2");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdSetEvent2, &meow_d_vkCmdSetEvent2, "vkCmdSetEvent2");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdSetEvent2");
        return;
    }
    const VkDependencyInfoL* d = (const VkDependencyInfoL*)pDependencyInfo;
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdSetEvent2 CALLED cmdBuf=%{public}p event=0x%{public}llx "
                 "dependencyFlags=0x%{public}x memoryBarrierCount=%{public}u bufferMemoryBarrierCount=%{public}u "
                 "imageMemoryBarrierCount=%{public}u -- forwarding",
                 cmd, (unsigned long long)event,
                 (unsigned)((d != NULL) ? d->dependencyFlags : 0u),
                 (unsigned)((d != NULL) ? d->memoryBarrierCount : 0u),
                 (unsigned)((d != NULL) ? d->bufferMemoryBarrierCount : 0u),
                 (unsigned)((d != NULL) ? d->imageMemoryBarrierCount : 0u));
    ((PFN_cmdSetEvent2)real)(cmd, event, pDependencyInfo);
}

// vkCmdResetEvent2 -- header :7980. stageMask is a 64-bit VkPipelineStageFlags2 -> 0x%llx.
typedef void (*PFN_cmdResetEvent2)(void*, uint64_t, uint64_t);
static void log_CmdResetEvent2(void* cmd, uint64_t event, uint64_t stageMask) {
    wd_note("vkCmdResetEvent2");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdResetEvent2, &meow_d_vkCmdResetEvent2, "vkCmdResetEvent2");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdResetEvent2");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdResetEvent2 CALLED cmdBuf=%{public}p event=0x%{public}llx "
                 "stageMask=0x%{public}llx -- forwarding", cmd, (unsigned long long)event,
                 (unsigned long long)stageMask);
    ((PFN_cmdResetEvent2)real)(cmd, event, stageMask);
}

// vkCmdWaitEvents2 -- header :7981 (4 parameters). pEvents is a uint64_t array; pDependencyInfos is an
// array with one VkDependencyInfo per event, so entry [0] is logged alongside the first two events.
typedef void (*PFN_cmdWaitEvents2)(void*, uint32_t, const void*, const void*);
static void log_CmdWaitEvents2(void* cmd, uint32_t eventCount, const void* pEvents,
                               const void* pDependencyInfos) {
    wd_note("vkCmdWaitEvents2");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdWaitEvents2, &meow_d_vkCmdWaitEvents2, "vkCmdWaitEvents2");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdWaitEvents2");
        return;
    }
    uint64_t e0 = 0, e1 = 0;
    if (eventCount > 0 && pEvents != NULL) {
        const uint64_t* ev = (const uint64_t*)pEvents;
        e0 = ev[0];
        if (eventCount > 1) e1 = ev[1];
    }
    const VkDependencyInfoL* d0 = (const VkDependencyInfoL*)pDependencyInfos;
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdWaitEvents2 CALLED cmdBuf=%{public}p eventCount=%{public}u "
                 "event0=0x%{public}llx event1=0x%{public}llx dep0{dependencyFlags=0x%{public}x "
                 "memoryBarrierCount=%{public}u bufferMemoryBarrierCount=%{public}u "
                 "imageMemoryBarrierCount=%{public}u} -- forwarding",
                 cmd, eventCount, (unsigned long long)e0, (unsigned long long)e1,
                 (unsigned)((d0 != NULL) ? d0->dependencyFlags : 0u),
                 (unsigned)((d0 != NULL) ? d0->memoryBarrierCount : 0u),
                 (unsigned)((d0 != NULL) ? d0->bufferMemoryBarrierCount : 0u),
                 (unsigned)((d0 != NULL) ? d0->imageMemoryBarrierCount : 0u));
    ((PFN_cmdWaitEvents2)real)(cmd, eventCount, pEvents, pDependencyInfos);
}

// ---- timestamp family ---------------------------------------------------------------------------

// vkCmdWriteTimestamp -- header :4595. VkPipelineStageFlagBits (the `stage`) is a 32-bit enum; queryPool
// is a 64-bit handle; query is the uint32_t index within the pool.
typedef void (*PFN_cmdWriteTimestamp)(void*, uint32_t, uint64_t, uint32_t);
static void log_CmdWriteTimestamp(void* cmd, uint32_t stage, uint64_t queryPool, uint32_t query) {
    wd_note("vkCmdWriteTimestamp");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdWriteTimestamp, &meow_d_vkCmdWriteTimestamp, "vkCmdWriteTimestamp");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdWriteTimestamp");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdWriteTimestamp CALLED cmdBuf=%{public}p stage=0x%{public}x "
                 "queryPool=0x%{public}llx query=%{public}u -- forwarding", cmd, (unsigned)stage,
                 (unsigned long long)queryPool, query);
    ((PFN_cmdWriteTimestamp)real)(cmd, stage, queryPool, query);
}

// vkCmdWriteTimestamp2 -- header :7970. `stage` is a 64-bit VkPipelineStageFlags2 -> 0x%llx.
typedef void (*PFN_cmdWriteTimestamp2)(void*, uint64_t, uint64_t, uint32_t);
static void log_CmdWriteTimestamp2(void* cmd, uint64_t stage, uint64_t queryPool, uint32_t query) {
    wd_note("vkCmdWriteTimestamp2");
    PFN_vkVoidFunctionLocal real = meow_cached_proc(&meow_p_vkCmdWriteTimestamp2, &meow_d_vkCmdWriteTimestamp2, "vkCmdWriteTimestamp2");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCmdWriteTimestamp2");
        return;
    }
    if (meow_vk_verbose())
        MEOWLOGI("meowvulkan: vkCmdWriteTimestamp2 CALLED cmdBuf=%{public}p stage=0x%{public}llx "
                 "queryPool=0x%{public}llx query=%{public}u -- forwarding", cmd,
                 (unsigned long long)stage, (unsigned long long)queryPool, query);
    ((PFN_cmdWriteTimestamp2)real)(cmd, stage, queryPool, query);
}

// =====================================================================================
// F22 (shim build .20): the TWO values the second-submit VK_ERROR_DEVICE_LOST hypothesis
// stands on -- and the only two that have NEVER been observed:
//   (1) the SHAPE of the query pool MC writes its GPU timestamps into
//       (VkQueryPoolCreateInfo.queryType / queryCount), and
//   (2) the QUEUE FAMILY's timestamp capability
//       (VkQueueFamilyProperties.timestampValidBits).
// Latest on-device evidence (shim .19) is that MC writes timestamps EVERY FRAME:
//     vkCmdWriteTimestamp2 CALLED ... stage=0x10000 queryPool=0x5afdaac4b0 query=2
//     vkCmdWriteTimestamp2 CALLED ... stage=0x10000 queryPool=0x5afdaac4b0 query=3
// Working hypotheses, both "violate => undefined" per the Vulkan spec:
//   (a) the chosen queue family has timestampValidBits == 0  => vkCmdWriteTimestamp(2) on that
//       queue is a VUID violation and the driver may do anything (here: DEVICE_LOST); or
//   (b) queryCount <= the highest index written (3) => the write is out of bounds => UB.
// Every prototype copies the parameter list VERBATIM from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361):
//   :4567  PFN_vkCreateQueryPool(VkDevice, const VkQueryPoolCreateInfo*,
//                                const VkAllocationCallbacks*, VkQueryPool*)                 -> VkResult
//   :4532  PFN_vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice, uint32_t*,
//                                VkQueueFamilyProperties*)                                  -> void
//   :6177  PFN_vkGetPhysicalDeviceQueueFamilyProperties2(VkPhysicalDevice, uint32_t*,
//                                VkQueueFamilyProperties2*)                                 -> void
//   :10359 PFN_vkGetPhysicalDeviceQueueFamilyProperties2KHR -- IDENTICAL parameter list; the
//                                KHR spelling is folded onto the core name by map_name().
// Struct fields copied verbatim (each offset/size _Static_assert'ed below against the LP64 layout):
//   VkQueryPoolCreateInfo        header :3873  (sType, pNext, flags, queryType, queryCount,
//                                               pipelineStatistics)                       size 32
//   VkQueueFamilyProperties      header :3715  (queueFlags, queueCount, timestampValidBits,
//                                               minImageTransferGranularity:VkExtent3D)    size 24
//   VkQueueFamilyProperties2     header :5832  (sType, pNext, queueFamilyProperties)      size 40
//   VkExtent3D                   header :3405  (uint32 width, height, depth)
//   VK_QUERY_TYPE_TIMESTAMP      header :2239  == 2
// HANDLE PRINT BASIS (VkQueryPool): VK_DEFINE_NON_DISPATCHABLE_HANDLE(VkQueryPool) at header :109;
// the macro is at :54-:60 and VK_USE_64_BIT_PTR_DEFINES is 1 for __LP64__ (:29-:34, __LP64__ branch
// at :30/:31), so :56 is selected: `typedef struct object##_T *object;` -- an 8-byte POINTER (the
// :58 `typedef uint64_t` branch is the 32-bit-target alternative). Either branch is exactly one
// 64-bit word, so the handle is logged as a 64-bit hex value with 0x%{public}llx after an
// (unsigned long long)(uintptr_t) cast -- never %p, matching the file's VkSwapchainKHR convention
// (:1987) and the F21 VkQueryPool note (:1681-:1685). The same rule applies to *pQueryPool and to
// the VkPhysicalDevice arguments (void* in this shim). NOTE: `timestampPeriod` (header :3672, in
// VkPhysicalDeviceLimits) is deliberately NOT logged: reading it would require mirroring the whole
// VkPhysicalDeviceLimits/VkPhysicalDeviceProperties struct -- exactly the "guess a field" trap this
// campaign keeps falling into -- so it is skipped as "not cheap".
// RULE: forward the SAME argument list. No parameter is ever invented, not even for logging.
// =====================================================================================

// VkQueryPoolCreateInfo -- official SDK type (vulkan_core.h:3873).
typedef VkQueryPoolCreateInfo VkQueryPoolCIL;

// vkCreateQueryPool -- header :4567. VkQueryPool (the out handle) is a 64-bit non-dispatchable
// handle, so `out` is a void** and *out is printed with 0x%{public}llx. Forwarded with the identical
// 4-argument list; rc is returned unchanged.
typedef int (*PFN_createQueryPool)(void*, const void*, const void*, void**);
static int log_CreateQueryPool(void* dev, const void* ci, const void* alloc, void** out) {
    wd_note("vkCreateQueryPool");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkCreateQueryPool") : NULL;
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCreateQueryPool");
        return -3;   // VK_ERROR_INITIALIZATION_FAILED
    }
    if (ci != NULL) {
        const VkQueryPoolCIL* c = (const VkQueryPoolCIL*)ci;
        // VK_QUERY_TYPE_TIMESTAMP == 2 (header :2239). queryCount must exceed the highest index MC
        // writes; the .19 log shows index 3, so anything <= 3 is flagged as the out-of-bounds case.
        MEOWLOGI("meowvulkan: vkCreateQueryPool CALLED queryType=%{public}d (%{public}s) "
                 "queryCount=%{public}u (queryCount>3: %{public}s) pipelineStatistics=0x%{public}x "
                 "-- forwarding",
                 c->queryType,
                 (c->queryType == 2) ? "TIMESTAMP(2)" : "NOT-TIMESTAMP",
                 c->queryCount,
                 (c->queryCount > 3u) ? "YES" : "NO *** <=3: index 2/3 would be OUT OF BOUNDS ***",
                 (unsigned)c->pipelineStatistics);
    } else {
        MEOWLOGI("meowvulkan: vkCreateQueryPool CALLED pCreateInfo=NULL -- forwarding");
    }
    int rc = ((PFN_createQueryPool)real)(dev, ci, alloc, out);
    MEOWLOGI("meowvulkan: vkCreateQueryPool returned rc=%{public}d queryPool=0x%{public}llx",
             rc, (unsigned long long)(uintptr_t)((out != NULL) ? *out : NULL));
    return rc;
}

// VkQueueFamilyProperties / VkQueueFamilyProperties2 -- official SDK types (vulkan_core.h:3715/5832).
// Accesses below use the official `queueFamilyProperties` member (not the former `props`).
typedef VkQueueFamilyProperties  VkQueueFamilyPropsL;
typedef VkQueueFamilyProperties2 VkQueueFamilyProps2L;

// One line per family. ★ timestampValidBits == 0 means "this queue does NOT support timestamps" --
// writing a timestamp on such a queue is the VUID violation behind hypothesis (a).
static void log_queue_family_one(const VkQueueFamilyPropsL* q, uint32_t i, const char* which) {
    MEOWLOGI("meowvulkan: %{public}s queueFamily[%{public}u] queueFlags=0x%{public}x "
             "queueCount=%{public}u timestampValidBits=%{public}u (%{public}s)",
             which, i, q->queueFlags, q->queueCount, q->timestampValidBits,
             (q->timestampValidBits == 0u) ? "*** 0 = TIMESTAMPS UNSUPPORTED ***"
                                           : "nonzero = timestamps supported");
}
static void log_queue_family_props(const VkQueueFamilyPropsL* q, uint32_t n, const char* which) {
    for (uint32_t i = 0; i < n; i++) {
        log_queue_family_one(&q[i], i, which);
    }
}

// vkGetPhysicalDeviceQueueFamilyProperties -- header :4532. INSTANCE-level, resolved through the
// application's instance (real_proc) and registered in vkGetInstanceProcAddr. Forwarded ONCE with
// the SAME argument list; we only read back the caller's in/out count and the returned array.
typedef void (*PFN_gpdqfp)(void*, uint32_t*, void*);
static void log_GetPhysicalDeviceQueueFamilyProperties(void* pdev, uint32_t* count, void* props) {
    wd_note("vkGetPhysicalDeviceQueueFamilyProperties");
    PFN_gpdqfp real = (PFN_gpdqfp)real_proc("vkGetPhysicalDeviceQueueFamilyProperties");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetPhysicalDeviceQueueFamilyProperties");
        return;
    }
    uint32_t inCount = (count != NULL) ? *count : 0u;
    real(pdev, count, props);
    uint32_t outCount = (count != NULL) ? *count : 0u;
    MEOWLOGI("meowvulkan: vkGetPhysicalDeviceQueueFamilyProperties inCount=%{public}u "
             "outCount=%{public}u pQueueFamilyProperties=%{public}s",
             inCount, outCount, (props != NULL) ? "non-null" : "NULL (count query)");
    if (props != NULL) {
        uint32_t n = (outCount > 16u) ? 16u : outCount;
        log_queue_family_props((const VkQueueFamilyPropsL*)props, n, "vkGetPhysicalDeviceQueueFamilyProperties");
    }
}

// vkGetPhysicalDeviceQueueFamilyProperties2 (+ KHR alias) -- header :6177 / :10359. Same discipline;
// pQueueFamilyProperties is an array of VkQueueFamilyProperties2, each carrying its properties inline
// at +16 (machine-checked above). KHR is folded by map_name(), and real_proc() strips the suffix too.
typedef void (*PFN_gpdqfp2)(void*, uint32_t*, void*);
static void log_GetPhysicalDeviceQueueFamilyProperties2(void* pdev, uint32_t* count, void* props2) {
    wd_note("vkGetPhysicalDeviceQueueFamilyProperties2");
    PFN_gpdqfp2 real = (PFN_gpdqfp2)real_proc("vkGetPhysicalDeviceQueueFamilyProperties2");
    if (real == NULL) real = (PFN_gpdqfp2)real_proc("vkGetPhysicalDeviceQueueFamilyProperties2KHR");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetPhysicalDeviceQueueFamilyProperties2");
        return;
    }
    uint32_t inCount = (count != NULL) ? *count : 0u;
    real(pdev, count, props2);
    uint32_t outCount = (count != NULL) ? *count : 0u;
    MEOWLOGI("meowvulkan: vkGetPhysicalDeviceQueueFamilyProperties2 inCount=%{public}u "
             "outCount=%{public}u pQueueFamilyProperties=%{public}s",
             inCount, outCount, (props2 != NULL) ? "non-null" : "NULL (count query)");
    if (props2 != NULL) {
        uint32_t n = (outCount > 16u) ? 16u : outCount;
        const VkQueueFamilyProps2L* a = (const VkQueueFamilyProps2L*)props2;
        for (uint32_t i = 0; i < n; i++) {
            log_queue_family_one(&a[i].queueFamilyProperties, i, "vkGetPhysicalDeviceQueueFamilyProperties2");
        }
    }
}

// ------------------------------ physical-device memory types (platform-specific lead)
// This GPU advertises only FOUR memory types and one of them is DEVICE_LOCAL|LAZILY_ALLOCATED -- a type
// that most engines (VMA included) essentially never meet on desktop GPUs. The Maleoon best-practices
// doc (saved at stuffs/research/vulkan/docs-maleoon-gpu-best-practices.md) says vkAllocateMemory is
// DEFERRED: real pages appear at vkBindBufferMemory/vkMapMemory, and for LAZILY_ALLOCATED types the
// memory is address space only until first access. Our crash sits exactly in that window, so the table
// is the missing input: if the allocator picked a type it cannot legally map, that is the bug.
// Official memory-type table types (vulkan_core.h:3227/3399).
typedef VkMemoryType VkMemTypeL;
typedef VkPhysicalDeviceMemoryProperties VkMemPropsL;

static void log_mem_types(const VkMemPropsL* mp) {
    if (mp == NULL) return;
    uint32_t n = mp->memoryTypeCount;
    if (n > 32) n = 32;
    for (uint32_t i = 0; i < n; i++) {
        MEOWLOGI("meowvulkan: memType[%{public}u] flags=0x%{public}x heap=%{public}u",
                 i, mp->memoryTypes[i].propertyFlags, mp->memoryTypes[i].heapIndex);
    }
}

static void hook_GetPhysicalDeviceMemoryProperties(VkPhysicalDevice pdev, void* out) {
    void (*real)(VkPhysicalDevice, void*) =
        (void (*)(VkPhysicalDevice, void*))real_proc("vkGetPhysicalDeviceMemoryProperties");
    if (real) real(pdev, out);
    log_mem_types((const VkMemPropsL*)out);
}

static void hook_GetPhysicalDeviceMemoryProperties2(VkPhysicalDevice pdev, void* out) {
    void (*real)(VkPhysicalDevice, void*) =
        (void (*)(VkPhysicalDevice, void*))real_proc("vkGetPhysicalDeviceMemoryProperties2");
    if (real) real(pdev, out);
    if (out != NULL) {
        log_mem_types((const VkMemPropsL*)((const char*)out + 16));   // skip sType + pNext
    }
}

// =====================================================================================
// F9 (shim build .12): the DECISIVE observation for the second submit's
// VK_ERROR_DEVICE_LOST -- the swapchain creation parameters (what usage MC actually asked
// for) and the surface capabilities (what usage the ICD says the swapchain image may have).
//
// Hypothesis under test: the swapchain image lacks VK_IMAGE_USAGE_TRANSFER_DST_BIT (0x2)
// in its creation `imageUsage`, or the ICD's `supportedUsageFlags` does not contain it, and
// the blit-into-swapchain-image in the second submit is what kills the device.
//
// Every prototype below copies the parameter list verbatim from the authoritative header
// ref/lwjgl3/modules/lwjgl/vulkan/src/main/c/vulkan/vulkan_core.h (VK_HEADER_VERSION 361):
//   :9166  PFN_vkCreateSwapchainKHR(VkDevice, const VkSwapchainCreateInfoKHR*,
//                                    const VkAllocationCallbacks*, VkSwapchainKHR*)
//   :9017  PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(VkPhysicalDevice, VkSurfaceKHR,
//                                    VkSurfaceCapabilitiesKHR*)
//   :9018  PFN_vkGetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice, VkSurfaceKHR,
//                                    uint32_t*, VkSurfaceFormatKHR*)
//   :9019  PFN_vkGetPhysicalDeviceSurfacePresentModesKHR(VkPhysicalDevice, VkSurfaceKHR,
//                                    uint32_t*, VkPresentModeKHR*)
// The struct mirrors below are machine-checked against that header by
// /storage/Users/currentUser/deveco/f9_probe.c (every offset/size is _Static_assert'ed there,
// and a function carrying the shim's exact parameter list is assigned to each header PFN, so a
// dropped/added/reordered parameter is an incompatible pointer type and fails under -Werror).
// RULE: forward the SAME argument list. No parameter is ever invented, not even for logging.
// =====================================================================================

// VkSurfaceCapabilitiesKHR -- official SDK type (vulkan_core.h:8583); extent fields are nested
// (currentExtent/minImageExtent/maxImageExtent), so accesses below use the official nesting.
typedef VkSurfaceCapabilitiesKHR VkSurfaceCapsKHRL;

// VkSurfaceFormatKHR -- official SDK type (vulkan_core.h:9010).
typedef VkSurfaceFormatKHR VkSurfaceFormatKHRL;

// F27 (.22): caches of what the surface actually advertises, filled by the three surface-query
// wrappers below (each still forwards exactly ONCE and only records the result). The
// vkCreateSwapchainKHR wrapper cross-checks the request against these. `*_valid` is set only by a
// successful query (rc==0) with a non-NULL output array; when a cache is invalid the cross-check
// prints `?` and emits NO verdict rather than guessing. One surface per process => newest wins.
static VkSurfaceCapsKHRL g_meow_caps;
static int g_meow_caps_valid = 0;
#define MEOW_SURF_FMT_MAX 16
static VkSurfaceFormatKHRL g_meow_formats[MEOW_SURF_FMT_MAX];
static uint32_t g_meow_format_count = 0;
static int g_meow_formats_valid = 0;
#define MEOW_PRESENT_MODE_MAX 16
static int32_t g_meow_present_modes[MEOW_PRESENT_MODE_MAX];
static uint32_t g_meow_present_mode_count = 0;
static int g_meow_present_modes_valid = 0;

// VkSwapchainCreateInfoKHR -- official SDK type (vulkan_core.h:8661); the extent is nested
// (imageExtent.width/height) and surface/oldSwapchain are typed handles (VkSurfaceKHR/VkSwapchainKHR).
typedef VkSwapchainCreateInfoKHR VkSwapchainCIKHRL;

// F75 env-cleanup (2026-09-18): the F23/F26/F27 one-shot swapchain diagnostics
// (MEOW_VK_SWAPCHAIN_USAGE_EXTRA / MEOW_VK_FIX_COMPOSITE_ALPHA / MEOW_VK_FIX_MIN_IMAGE_COUNT /
// MEOW_VK_FIX_PRESENT_MODE) and their helpers / image-usage aliases / composite-alpha cache were
// removed: the Vulkan path is up, and these overlays changed the forwarded VkSwapchainCreateInfoKHR.

// ------------------------------------------------------------------ swapchain enum aliases
// Enum values from the authoritative SDK header; used by the read-only cross-check/logging below.
#define MEOW_VK_PRESENT_MODE_IMMEDIATE_KHR    VK_PRESENT_MODE_IMMEDIATE_KHR
#define MEOW_VK_PRESENT_MODE_MAILBOX_KHR      VK_PRESENT_MODE_MAILBOX_KHR
#define MEOW_VK_PRESENT_MODE_FIFO_KHR         VK_PRESENT_MODE_FIFO_KHR
#define MEOW_VK_PRESENT_MODE_FIFO_RELAXED_KHR VK_PRESENT_MODE_FIFO_RELAXED_KHR
#define MEOW_VK_FORMAT_UNDEFINED              VK_FORMAT_UNDEFINED
#define MEOW_VK_SHARING_MODE_EXCLUSIVE        VK_SHARING_MODE_EXCLUSIVE
#define MEOW_VK_SHARING_MODE_CONCURRENT       VK_SHARING_MODE_CONCURRENT
#define MEOW_VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR

static const char* meow_present_mode_name(int32_t m) {
    switch (m) {
        case MEOW_VK_PRESENT_MODE_IMMEDIATE_KHR:    return "IMMEDIATE";
        case MEOW_VK_PRESENT_MODE_MAILBOX_KHR:      return "MAILBOX";
        case MEOW_VK_PRESENT_MODE_FIFO_KHR:         return "FIFO";
        case MEOW_VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "FIFO_RELAXED";
        default: return "?";
    }
}

// F74 (shim build 2026-09-18.54 wrapup). Resolve MEOW_VK_FIX_SURFACE_TRANSFORM once and return its
// SOURCE label, which the receipt line prints:
//   "default"   -> env unset/empty/unknown => identity is applied (F74 default-on)
//   "identity"  -> env explicitly "identity" => identity is applied
//   "requested" -> env "requested"/"0"       => the caller's preTransform is kept (A/B escape hatch)
// Read-once is safe here: env does not change after process start, and this path runs once per
// swapchain creation (NOT a hot path), so a single receipt line per create is emitted.
static const char* meow_vk_fix_surface_transform_source(void) {
    static const char* src;
    static int done = 0;
    if (!done) {
        const char* t = getenv("MEOW_VK_FIX_SURFACE_TRANSFORM");
        if (t != NULL && (strcmp(t, "requested") == 0 || strcmp(t, "0") == 0)) {
            src = "requested";
        } else if (t != NULL && strcmp(t, "identity") == 0) {
            src = "identity";
        } else {
            src = "default";
        }
        done = 1;
    }
    return src;
}

// True when the F73/F74 transform override should be applied (default and identity sources; NOT
// "requested"). Used by the cross-check so a deliberate IDENTITY override is not reported as a VUID
// violation.
static int meow_vk_fix_surface_transform_active(void) {
    return strcmp(meow_vk_fix_surface_transform_source(), "requested") != 0;
}

// Lazily materialise a mutable LOCAL copy of the caller's create-info. Untouched requests keep
// forwarding the caller's original pointer byte-for-byte (`*fwdCi` is only repointed here).
static VkSwapchainCIKHRL* meow_swapchain_mut(const VkSwapchainCIKHRL* c, VkSwapchainCIKHRL* copy,
                                             const void** fwdCi) {
    if (*fwdCi != (const void*)copy) {
        *copy = *c;
        *fwdCi = (const void*)copy;
    }
    /* F73 (shim build .51) / F74 (shim build 2026-09-18.54 wrapup): WSI orientation / extent overrides.
     * WHY: with F72 (push->descriptor-set) MC's native Vulkan backend finally RENDERS on this device,
     * but the picture arrives rotated 90 deg counter-clockwise and stretched ("lying on its side,
     * skinny and long"). This platform's OHOS surface reports currentTransform = 0x2
     * (VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR, measured repeatedly in the surface-capabilities logs),
     * and the WSI really does rotate the presented image, so forwarding the caller's value verbatim
     * ALWAYS lands the picture on its side. F74 therefore makes the transform override DEFAULT-ON:
     *   MEOW_VK_FIX_SURFACE_TRANSFORM unset/""/identity -> force preTransform = IDENTITY (default)
     *   MEOW_VK_FIX_SURFACE_TRANSFORM=requested (or 0)  -> keep the caller's value (A/B escape hatch)
     * The extent override stays opt-in:
     *   MEOW_VK_FIX_EXTENT=current -> force imageExtent = cached caps.currentExtent
     */
    {
        const char* ts = meow_vk_fix_surface_transform_source();
        if (meow_vk_fix_surface_transform_active()) {
            if ((uint32_t)copy->preTransform != MEOW_VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) {
                MEOWLOGI("meowvulkan: F73 forcing preTransform 0x%{public}x -> IDENTITY(0x1) "
                         "(MEOW_VK_FIX_SURFACE_TRANSFORM source=%{public}s)",
                         (unsigned)copy->preTransform, ts);
                copy->preTransform = (int32_t)MEOW_VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
            }
        }
        const char* e = getenv("MEOW_VK_FIX_EXTENT");
        if (e != NULL && strcmp(e, "current") == 0 && g_meow_caps_valid) {
            uint32_t cw = g_meow_caps.currentExtent.width;
            uint32_t ch = g_meow_caps.currentExtent.height;
            if (cw != 0xFFFFFFFFu && cw != 0u &&
                (copy->imageExtent.width != cw || copy->imageExtent.height != ch)) {
                MEOWLOGI("meowvulkan: F73 forcing imageExtent %{public}ux%{public}u -> %{public}ux%{public}u "
                         "(MEOW_VK_FIX_EXTENT=current)",
                         copy->imageExtent.width, copy->imageExtent.height, cw, ch);
                copy->imageExtent.width = cw;
                copy->imageExtent.height = ch;
            }
        }
    }
    return copy;
}

// F27 (.22): full request-vs-cached-surface cross-check, printed right after the CALLED line in
// vkCreateSwapchainKHR. Every verdict is a plain containment test on the cached values from the
// three surface queries; when a cache is missing the field prints `?` and NO verdict is guessed.
// Criteria (VUID short names are ours, the numbers are the spec's):
//   minImageCount          >= caps.minImageCount and (maxImageCount==0 || <= maxImageCount)  [01271]
//   imageFormat/ColorSpace    the (format,colorSpace) pair is in the surface format list; a lone
//                             VK_FORMAT_UNDEFINED entry means "any format"
//   imageExtent            == caps.currentExtent unless that is 0xFFFFFFFF, then within
//                             [caps.minImageExtent, caps.maxImageExtent]
//   imageArrayLayers       <= caps.maxImageArrayLayers
//   imageUsage             subset of caps.supportedUsageFlags
//   imageSharingMode       EXCLUSIVE with queueFamilyIndexCount==0, or CONCURRENT with >=1
//   preTransform           in caps.supportedTransforms, and == caps.currentTransform when that is
//                             not IDENTITY(0x1)
//   compositeAlpha         exactly one bit, subset of caps.supportedCompositeAlpha
//   presentMode            member of the surface present-mode list
//   clipped                printed (0/1); no validity criterion
static void meow_crosscheck_swapchain(const VkSwapchainCIKHRL* c) {
    if (c == NULL) {
        MEOWLOGI("meowvulkan: CROSSCHECK pCreateInfo=NULL -> skipped");
        return;
    }
    MEOWLOGI("meowvulkan: CROSSCHECK request vs cached surface (surface=0x%{public}llx)",
             (unsigned long long)(uintptr_t)c->surface);
    if (!g_meow_caps_valid) {
        MEOWLOGI("meowvulkan:   caps=? (surface capabilities not cached) -> all caps verdicts are ?");
        MEOWLOGI("meowvulkan:   minImageCount=%{public}u imageExtent=%{public}ux%{public}u "
                 "imageArrayLayers=%{public}u imageUsage=0x%{public}x preTransform=0x%{public}x "
                 "compositeAlpha=0x%{public}x",
                 c->minImageCount, c->imageExtent.width, c->imageExtent.height, c->imageArrayLayers,
                 (unsigned)c->imageUsage, (unsigned)c->preTransform, (unsigned)c->compositeAlpha);
    } else {
        const VkSurfaceCapsKHRL* k = &g_meow_caps;
        int ok = (c->minImageCount >= k->minImageCount) &&
                 (k->maxImageCount == 0u || c->minImageCount <= k->maxImageCount);
        MEOWLOGI("meowvulkan:   minImageCount req=%{public}u caps=[%{public}u..%{public}u] %{public}s",
                 c->minImageCount, k->minImageCount, k->maxImageCount, ok ? "[OK]" : "[*** VIOLATION ***]");
        ok = (k->currentExtent.width == 0xFFFFFFFFu && k->currentExtent.height == 0xFFFFFFFFu)
                 ? (c->imageExtent.width >= k->minImageExtent.width &&
                    c->imageExtent.width <= k->maxImageExtent.width &&
                    c->imageExtent.height >= k->minImageExtent.height &&
                    c->imageExtent.height <= k->maxImageExtent.height)
                 : (c->imageExtent.width == k->currentExtent.width &&
                    c->imageExtent.height == k->currentExtent.height);
        MEOWLOGI("meowvulkan:   imageExtent req=%{public}ux%{public}u current=%{public}ux%{public}u "
                 "min=%{public}ux%{public}u max=%{public}ux%{public}u %{public}s",
                 c->imageExtent.width, c->imageExtent.height, k->currentExtent.width, k->currentExtent.height,
                 k->minImageExtent.width, k->minImageExtent.height, k->maxImageExtent.width,
                 k->maxImageExtent.height, ok ? "[OK]" : "[*** VIOLATION ***]");
        MEOWLOGI("meowvulkan:   imageArrayLayers req=%{public}u max=%{public}u %{public}s",
                 c->imageArrayLayers, k->maxImageArrayLayers,
                 (c->imageArrayLayers <= k->maxImageArrayLayers) ? "[OK]" : "[*** VIOLATION ***]");
        MEOWLOGI("meowvulkan:   imageUsage req=0x%{public}x supported=0x%{public}x %{public}s",
                 (unsigned)c->imageUsage, (unsigned)k->supportedUsageFlags,
                 ((c->imageUsage & ~k->supportedUsageFlags) == 0u) ? "[OK]" : "[*** VIOLATION ***]");
        MEOWLOGI("meowvulkan:   preTransform req=0x%{public}x current=0x%{public}x supported=0x%{public}x %{public}s",
                 (unsigned)c->preTransform, k->currentTransform, k->supportedTransforms,
                 (((k->supportedTransforms & (uint32_t)c->preTransform) != 0u) &&
                  (k->currentTransform == MEOW_VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR ||
                   c->preTransform == (int32_t)k->currentTransform ||
                   /* F73/F74: a preTransform forced to IDENTITY by MEOW_VK_FIX_SURFACE_TRANSFORM
                    * (default, identity or requested sources all report the override as active only
                    * for default/identity) is a deliberate override, not a violation. */
                   (((uint32_t)c->preTransform) == MEOW_VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR &&
                    meow_vk_fix_surface_transform_active())))
                     ? "[OK]" : "[*** VIOLATION ***]");
        MEOWLOGI("meowvulkan:   compositeAlpha req=0x%{public}x supported=0x%{public}x %{public}s",
                 (unsigned)c->compositeAlpha, (unsigned)k->supportedCompositeAlpha,
                 (((uint32_t)c->compositeAlpha != 0u) &&
                  (((uint32_t)c->compositeAlpha & ((uint32_t)c->compositeAlpha - 1u)) == 0u) &&
                  (((uint32_t)c->compositeAlpha & ~k->supportedCompositeAlpha) == 0u))
                     ? "[OK]" : "[*** VIOLATION ***]");
    }
    if (g_meow_formats_valid) {
        int found = 0, anyFmt = 0;
        for (uint32_t i = 0; i < g_meow_format_count; i++) {
            if (g_meow_formats[i].format == MEOW_VK_FORMAT_UNDEFINED) anyFmt = 1;
            if (g_meow_formats[i].format == c->imageFormat &&
                g_meow_formats[i].colorSpace == c->imageColorSpace) found = 1;
        }
        MEOWLOGI("meowvulkan:   imageFormat/ColorSpace req=%{public}d/%{public}d (n=%{public}u%{public}s) %{public}s",
                 c->imageFormat, c->imageColorSpace, g_meow_format_count,
                 anyFmt ? ",HAS_UNDEFINED(any)" : "",
                 (found || anyFmt) ? "[OK]" : "[*** VIOLATION ***]");
    } else {
        MEOWLOGI("meowvulkan:   imageFormat/ColorSpace req=%{public}d/%{public}d formats=? [not cached]",
                 c->imageFormat, c->imageColorSpace);
    }
    MEOWLOGI("meowvulkan:   imageSharingMode req=%{public}d queueFamilyIndexCount=%{public}u %{public}s",
             c->imageSharingMode, c->queueFamilyIndexCount,
             ((c->imageSharingMode == MEOW_VK_SHARING_MODE_EXCLUSIVE && c->queueFamilyIndexCount == 0u) ||
              (c->imageSharingMode == MEOW_VK_SHARING_MODE_CONCURRENT && c->queueFamilyIndexCount >= 1u))
                 ? "[OK]" : "[*** VIOLATION ***]");
    if (g_meow_present_modes_valid) {
        int found = 0;
        for (uint32_t i = 0; i < g_meow_present_mode_count; i++) {
            if (g_meow_present_modes[i] == c->presentMode) found = 1;
        }
        MEOWLOGI("meowvulkan:   presentMode req=%{public}d (%{public}s) n=%{public}u %{public}s",
                 c->presentMode, meow_present_mode_name(c->presentMode),
                 g_meow_present_mode_count, found ? "[OK]" : "[*** VIOLATION ***]");
    } else {
        MEOWLOGI("meowvulkan:   presentMode req=%{public}d (%{public}s) presentModes=? [not cached]",
                 c->presentMode, meow_present_mode_name(c->presentMode));
    }
    MEOWLOGI("meowvulkan:   clipped=%{public}u (printed; no validity criterion)", c->clipped);
}

// vkCreateSwapchainKHR -- header :9166. Device-level: resolved through g_gdpa exactly as the
// MEOW_FORWARD_3OUT it replaces did, and forwarded with the identical 4-argument list.
typedef int (*PFN_createSwapchainKHR)(void*, const void*, const void*, void**);
static int log_vkCreateSwapchainKHR(void* dev, const void* ci, const void* alloc, void** out) {
    wd_note("vkCreateSwapchainKHR");
    PFN_vkVoidFunctionLocal real = g_gdpa ? g_gdpa(g_dev_seen, "vkCreateSwapchainKHR") : NULL;
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkCreateSwapchainKHR");
        return -3;   // VK_ERROR_INITIALIZATION_FAILED
    }
    const VkSwapchainCIKHRL* c = (ci != NULL) ? (const VkSwapchainCIKHRL*)ci : NULL;
    const void* fwdCi = ci;
    VkSwapchainCIKHRL ciCopy;   // function scope: fwdCi points at it past the if below
    if (c != NULL) {
        // imageUsage is THE field to read: TRANSFER_DST (0x2) is at 0x%x. imageSharingMode/
        // preTransform/compositeAlpha/presentMode are enums -> %d; flag words -> 0x%x.
        MEOWLOGI("meowvulkan: vkCreateSwapchainKHR CALLED surface=0x%{public}llx minImageCount=%{public}u "
                 "imageFormat=%{public}d imageColorSpace=%{public}d imageExtent=%{public}ux%{public}u "
                 "imageArrayLayers=%{public}u imageUsage=0x%{public}x imageSharingMode=%{public}d "
                 "queueFamilyIndexCount=%{public}u preTransform=0x%{public}x compositeAlpha=0x%{public}x "
                 "presentMode=%{public}d clipped=%{public}u oldSwapchain=0x%{public}llx -- forwarding",
                 (unsigned long long)(uintptr_t)c->surface, c->minImageCount, c->imageFormat, c->imageColorSpace,
                 c->imageExtent.width, c->imageExtent.height, c->imageArrayLayers, (unsigned)c->imageUsage,
                 c->imageSharingMode, c->queueFamilyIndexCount, (unsigned)c->preTransform,
                 (unsigned)c->compositeAlpha, c->presentMode, c->clipped,
                 (unsigned long long)(uintptr_t)c->oldSwapchain);
    } else {
        MEOWLOGI("meowvulkan: vkCreateSwapchainKHR CALLED pCreateInfo=NULL -- forwarding");
    }
    // F27 (.22): read-only cross-check of the REQUEST against the cached surface caps/formats/modes.
    // Runs before any override below, so it always describes what the caller (MC) really asked for.
    meow_crosscheck_swapchain(c);
    // F73b (.52): ALWAYS take the mutable copy here, so the WSI overrides inside meow_swapchain_mut()
    // (F73: forced preTransform / forced imageExtent) are actually reachable. BUG being fixed:
    // meow_swapchain_mut() used to be called only from the other MEOW_VK_FIX_* branches, so with ONLY
    // an F73 switch set it never ran at all -- proved on-device (MEOW_VK_FIX_SURFACE_TRANSFORM=identity
    // was present in the render env, yet no "F73 forcing" line appeared). With no override set this
    // insertion is a plain struct copy and every forwarded field is unchanged. The receipt line below
    // exists so that silence can never again be mistaken for "the switch did not reach us".
    if (c != NULL) {
        VkSwapchainCIKHRL* mPre = meow_swapchain_mut(c, &ciCopy, &fwdCi);
        const char* srcPre = meow_vk_fix_surface_transform_source();
        const char* ePre = getenv("MEOW_VK_FIX_EXTENT");
        MEOWLOGI("meowvulkan: F73 receipt: FIX_SURFACE_TRANSFORM source=%{public}s FIX_EXTENT=%{public}s | "
                 "requested preTransform=0x%{public}x extent=%{public}ux%{public}u -> forwarded "
                 "preTransform=0x%{public}x extent=%{public}ux%{public}u",
                 srcPre, ePre != NULL ? ePre : "(unset)",
                 (unsigned)c->preTransform, c->imageExtent.width, c->imageExtent.height,
                 (unsigned)mPre->preTransform, mPre->imageExtent.width, mPre->imageExtent.height);
    }
    int rc = ((PFN_createSwapchainKHR)real)(dev, fwdCi, alloc, out);
    MEOWLOGI("meowvulkan: vkCreateSwapchainKHR returned rc=%{public}d swapchain=0x%{public}llx",
             rc, (unsigned long long)(uintptr_t)((out != NULL) ? *out : NULL));
    // F59: cache the LAST successful swapchain's FORWARDED parameters (fwdCi, i.e. post-diagnostic)
    // so the slow-acquire line can print what the WSI is actually driving.
    if (rc == 0 && out != NULL && *out != NULL) {
        const VkSwapchainCIKHRL* r = (const VkSwapchainCIKHRL*)fwdCi;
        if (r != NULL) {
            g_meow_sw_handle = (uint64_t)(uintptr_t)*out;
            g_meow_sw_min_image_count = r->minImageCount;
            g_meow_sw_image_format = r->imageFormat;
            g_meow_sw_image_usage = r->imageUsage;
            g_meow_sw_pre_transform = r->preTransform;
            g_meow_sw_present_mode = r->presentMode;
            g_meow_sw_valid = 1;
        }
    }
    return rc;
}

// F59: the slow-acquire extra line. Reads the F27 surface caches (caps / formats / present modes)
// and the F59 last-created-swapchain scalars. Window handle and buffer-queue size are NOT reachable
// from this shim: meowvulkan.c neither includes external_window.h nor links the EGL/ArkUI surface
// channel -- the only cached OHNativeWindow lives in egl_gl.c (g_egl.surfaceWindow) and egl_gl.c has
// NO GET_BUFFERQUEUE_SIZE query at all, so both fields print a fixed "egl-side" marker instead of a
// guessed value. Reaching them would mean editing egl_gl.c, which is deliberately out of scope now.
// Logging only: it never touches the forwarded arguments or the return value.
static void meow_vk_log_slow_acquire(void* swapchain, int rc, long long dt_ms) {
    const char* pmodename = g_meow_sw_valid ? meow_present_mode_name(g_meow_sw_present_mode) : "?";
    int32_t fmt0 = (g_meow_formats_valid && g_meow_format_count > 0u) ? g_meow_formats[0].format : 0;
    int32_t cs0  = (g_meow_formats_valid && g_meow_format_count > 0u) ? g_meow_formats[0].colorSpace : 0;
    int32_t pm0  = (g_meow_present_modes_valid && g_meow_present_mode_count > 0u) ? g_meow_present_modes[0] : 0;
    MEOWLOGI("meowvulkan: slow acquire #%{public}lu (acquireCount=%{public}lu presentCount=%{public}lu) "
             "dtMs=%{public}lld rc=%{public}d swapchain=%{public}p sw_valid=%{public}d "
             "minImageCount=%{public}u imageFormat=%{public}d imageUsage=0x%{public}x preTransform=0x%{public}x "
             "presentMode=%{public}d(%{public}s) capsValid=%{public}d caps.minImageCount=%{public}u "
             "caps.currentExtent=%{public}ux%{public}u caps.supportedUsageFlags=0x%{public}x "
             "formatsValid=%{public}d formatsN=%{public}u fmt0=%{public}d/cs%{public}d "
             "presentModesValid=%{public}d presentModesN=%{public}u pm0=%{public}d "
             "window=egl-side(egl_gl.c g_egl.surfaceWindow; not in meowvulkan.c) "
             "bufferQueueSize=egl-side(no query in egl_gl.c)",
             g_meow_acquire_count, g_meow_acquire_count, g_meow_present_count,
             dt_ms, rc, swapchain, g_meow_sw_valid,
             g_meow_sw_valid ? g_meow_sw_min_image_count : 0u,
             g_meow_sw_valid ? g_meow_sw_image_format : 0,
             g_meow_sw_valid ? g_meow_sw_image_usage : 0u,
             g_meow_sw_valid ? g_meow_sw_pre_transform : 0,
             g_meow_sw_valid ? g_meow_sw_present_mode : 0, pmodename,
             g_meow_caps_valid,
             g_meow_caps_valid ? g_meow_caps.minImageCount : 0u,
             g_meow_caps_valid ? g_meow_caps.currentExtent.width : 0u,
             g_meow_caps_valid ? g_meow_caps.currentExtent.height : 0u,
             g_meow_caps_valid ? g_meow_caps.supportedUsageFlags : 0u,
             g_meow_formats_valid, g_meow_format_count, fmt0, cs0,
             g_meow_present_modes_valid, g_meow_present_mode_count, pm0);
}

// (F27 .22: VkSurfaceCapabilitiesKHR / VkSurfaceFormatKHR mirrors and their asserts moved UP, to the
//  F9 block header, so the vkCreateSwapchainKHR cross-check can use them. Definitions unchanged.)

// vkGetPhysicalDeviceSurfaceCapabilitiesKHR -- header :9017. INSTANCE-level command, resolved
// through the application's instance (real_proc) and registered in vkGetInstanceProcAddr.
// ★ supportedUsageFlags is the decisive number: TRANSFER_DST = 0x2.
typedef int (*PFN_surfaceCaps)(void*, void*, void*);
static int log_GetPhysicalDeviceSurfaceCapabilitiesKHR(void* pdev, void* surface, void* caps) {
    wd_note("vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    PFN_surfaceCaps real = (PFN_surfaceCaps)real_proc("vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
        return -3;
    }
    int rc = real(pdev, surface, caps);
    if (caps != NULL) {
        const VkSurfaceCapsKHRL* c = (const VkSurfaceCapsKHRL*)caps;
        if (rc == 0) {
            g_meow_caps = *c;                 // F27 (.22): full caps cache for the swapchain cross-check
            g_meow_caps_valid = 1;
        }
        MEOWLOGI("meowvulkan: vkGetPhysicalDeviceSurfaceCapabilitiesKHR rc=%{public}d "
                 "minImageCount=%{public}u maxImageCount=%{public}u currentExtent=%{public}ux%{public}u "
                 "minImageExtent=%{public}ux%{public}u maxImageExtent=%{public}ux%{public}u "
                 "maxImageArrayLayers=%{public}u currentTransform=0x%{public}x "
                 "supportedTransforms=0x%{public}x supportedCompositeAlpha=0x%{public}x "
                 "supportedUsageFlags=0x%{public}x (TRANSFER_DST bit0x2: %{public}s)",
                 rc, c->minImageCount, c->maxImageCount, c->currentExtent.width, c->currentExtent.height,
                 c->minImageExtent.width, c->minImageExtent.height, c->maxImageExtent.width,
                 c->maxImageExtent.height, c->maxImageArrayLayers, c->currentTransform,
                 c->supportedTransforms, c->supportedCompositeAlpha,
                 c->supportedUsageFlags,
                 ((c->supportedUsageFlags & 0x2u) != 0u) ? "SUPPORTED" : "*** ABSENT ***");
    } else {
        MEOWLOGI("meowvulkan: vkGetPhysicalDeviceSurfaceCapabilitiesKHR rc=%{public}d pCaps=NULL", rc);
    }
    return rc;
}

// vkGetPhysicalDeviceSurfaceFormatsKHR -- header :9018. Forwarded ONCE (we never issue our own
// extra enumeration: that would be a behaviour change); we read the caller's in/out count and the
// first 2 returned entries.
typedef int (*PFN_surfaceFormats)(void*, void*, uint32_t*, void*);
static int log_GetPhysicalDeviceSurfaceFormatsKHR(void* pdev, void* surface, uint32_t* count,
                                                  void* formats) {
    wd_note("vkGetPhysicalDeviceSurfaceFormatsKHR");
    PFN_surfaceFormats real = (PFN_surfaceFormats)real_proc("vkGetPhysicalDeviceSurfaceFormatsKHR");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetPhysicalDeviceSurfaceFormatsKHR");
        return -3;
    }
    uint32_t inCount = (count != NULL) ? *count : 0u;
    int rc = real(pdev, surface, count, formats);
    uint32_t outCount = (count != NULL) ? *count : 0u;
    MEOWLOGI("meowvulkan: vkGetPhysicalDeviceSurfaceFormatsKHR rc=%{public}d inCount=%{public}u "
             "outCount=%{public}u pFormats=%{public}s", rc, inCount, outCount,
             (formats != NULL) ? "non-null" : "NULL");
    if (formats != NULL) {
        const VkSurfaceFormatKHRL* f = (const VkSurfaceFormatKHRL*)formats;
        // F27 (.22): cache the real array (bounded) for the swapchain cross-check. rc>=0 covers
        // VK_SUCCESS(0) and VK_INCOMPLETE(5); a NULL array is a count query and is not cached.
        if (rc >= 0) {
            uint32_t cn = (outCount > MEOW_SURF_FMT_MAX) ? MEOW_SURF_FMT_MAX : outCount;
            for (uint32_t i = 0; i < cn; i++) g_meow_formats[i] = f[i];
            g_meow_format_count = cn;
            g_meow_formats_valid = 1;
        }
        uint32_t n = (outCount > 2u) ? 2u : outCount;
        for (uint32_t i = 0; i < n; i++) {
            MEOWLOGI("meowvulkan:   surfaceFormat[%{public}u] format=%{public}d colorSpace=%{public}d",
                     i, f[i].format, f[i].colorSpace);
        }
    }
    return rc;
}

// vkGetPhysicalDeviceSurfacePresentModesKHR -- header :9019. Same single-forward discipline; the
// array is int32 enum values.
typedef int (*PFN_surfacePresentModes)(void*, void*, uint32_t*, void*);
static int log_GetPhysicalDeviceSurfacePresentModesKHR(void* pdev, void* surface, uint32_t* count,
                                                       void* modes) {
    wd_note("vkGetPhysicalDeviceSurfacePresentModesKHR");
    PFN_surfacePresentModes real =
        (PFN_surfacePresentModes)real_proc("vkGetPhysicalDeviceSurfacePresentModesKHR");
    if (real == NULL) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetPhysicalDeviceSurfacePresentModesKHR");
        return -3;
    }
    uint32_t inCount = (count != NULL) ? *count : 0u;
    int rc = real(pdev, surface, count, modes);
    uint32_t outCount = (count != NULL) ? *count : 0u;
    MEOWLOGI("meowvulkan: vkGetPhysicalDeviceSurfacePresentModesKHR rc=%{public}d inCount=%{public}u "
             "outCount=%{public}u pPresentModes=%{public}s", rc, inCount, outCount,
             (modes != NULL) ? "non-null" : "NULL");
    if (modes != NULL) {
        const int32_t* m = (const int32_t*)modes;
        // F27 (.22): cache the real array (bounded) for the swapchain cross-check; see the formats
        // wrapper above for the rc>=0 / NULL-array reasoning.
        if (rc >= 0) {
            uint32_t cn = (outCount > MEOW_PRESENT_MODE_MAX) ? MEOW_PRESENT_MODE_MAX : outCount;
            for (uint32_t i = 0; i < cn; i++) g_meow_present_modes[i] = m[i];
            g_meow_present_mode_count = cn;
            g_meow_present_modes_valid = 1;
        }
        uint32_t n = (outCount > 2u) ? 2u : outCount;
        for (uint32_t i = 0; i < n; i++) {
            MEOWLOGI("meowvulkan:   presentMode[%{public}u]=%{public}d", i, m[i]);
        }
    }
    return rc;
}

// Defined at the bottom; vkGetInstanceProcAddr hands this back for the "vkGetDeviceProcAddr" lookup.
PFN_vkVoidFunctionLocal vkGetDeviceProcAddr(VkDevice dev, const char* name);
// Same idea: we now hand back OUR vkCreateInstance so the apiVersion probe runs (without a forward
// declaration this is a hard compile error -- -Wimplicit-function-declaration, measured).
VkResult vkCreateInstance(const void* ci, const void* alloc, VkInstance* out);

static void init_once(void) {
    if (g_real) return;
    g_real = dlopen(REAL_LOADER, RTLD_NOW | RTLD_LOCAL);
    if (!g_real) {
        MEOWLOGE("meowvulkan: dlopen(%{public}s) failed: %{public}s", REAL_LOADER, dlerror());
        return;
    }
    g_gipa = (PFN_vkVoidFunctionLocal(*)(VkInstance, const char*))dlsym(g_real, "vkGetInstanceProcAddr");
    // NOTE: vkGetDeviceProcAddr is resolved LAZILY in vkGetDeviceProcAddr itself, through the real
    // instance -- a NULL-instance lookup does not reliably resolve a device-level command here.
    // F75 env-cleanup: being LOADED is the parameter -- hooks default ON. MEOW_VK_SHIM=0 (or an empty
    // value) is the escape hatch back to pure passthrough; unset keeps the hooks on.
    const char* sw = getenv("MEOW_VK_SHIM");
    g_hooks = (sw == NULL || (sw[0] != '\0' && strcmp(sw, "0") != 0)) ? 1 : 0;
    MEOWLOGI("meowvulkan: real loader=%{public}p hooks=%{public}d (MEOW_VK_SHIM=%{public}s; unset = hooks on, 0/empty = pure passthrough)",
             g_real, g_hooks, sw ? sw : "(unset)");
    // Deployment self-certification: this campaign lost a run to "the fix was in the tree but not on
    // the device", so every shim build now names itself. Bump the tag whenever the shim changes.
    // F74 env switch tiers (A/B) are documented in the header comment at the top of this file.
    MEOWLOGI("meowvulkan: shim build 2026-09-23.83 quiet-f72b-totals");
    // Crash backtraces for the Vulkan path are handled by meowbt, which the bridge now installs from
    // meowSetSurfaceId (see egl_gl.c) -- reachable on this path, unlike the GL-only install sites.
    // Enable with the documented envs: MEOW_BT=1 (and optionally MEOW_BT_FILE=<path>).
    //
    // DO NOT re-introduce a self-installed SIGSEGV handler. One was tried on 2026-09-17 and it BROKE
    // the JVM: HotSpot implements implicit null checks by faulting deliberately (SIGSEGV at addr=0x8/0xc
    // inside the code cache) and converting it into a NullPointerException in its own handler. Sitting in
    // front of that handler and re-raising turns the signal into SI_TKILL (code=-6) with a pc inside
    // raise(), so the JVM no longer recognises the fault site, treats it as a fatal VM error and aborts --
    // the app then dies at the very first benign null check (measured: "it crashes sooner"). Intercepting
    // SIGSEGV in a JVM process is the same class of mistake as interposing libc for dlopen'd libraries.
    // The former self-installed handler was removed; keep it that way.

    // One-time startup diagnostic: dump the tail of our own command line. The hilog "CMD:" line is
    // truncated before the main class, which is exactly where the interesting part is -- the tail holds
    // "<mainClass> <game args...>", confirming from inside the JVM process which game args MC received.
    {
        FILE* f = fopen("/proc/self/cmdline", "rb");
        if (f != NULL) {
            static char buf[4096];
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            buf[n] = 0;
            for (size_t i = 0; i < n; i++) {
                if (buf[i] == 0) buf[i] = ' ';
            }
            MEOWLOGI("meowvulkan: cmdline has graphicsBackend? %{public}s",
                     (strstr(buf, "graphicsBackend") != NULL) ? "YES" : "NO");
            MEOWLOGI("meowvulkan: cmdline tail: %{public}s", (n > 600) ? (buf + n - 600) : buf);
        } else {
            MEOWLOGE("meowvulkan: cannot open /proc/self/cmdline");
        }
    }
}

// hook 4: the KHR spelling of a command that the ICD only exposes unsuffixed.
static const char* map_name(const char* name) {
    if (!name) return name;
    // F45: fold the KHR spellings of the two entry points this shim translates, so the
    // translation is reached identically whether the caller asks for the core or KHR name
    // (the registration below already accepted both; this makes the KHR path first-class and
    // keeps the forwarded lookup on the core name the ICD actually exposes).
    if (!strcmp(name, "vkQueueSubmit2KHR")) return "vkQueueSubmit2";
    if (!strcmp(name, "vkCmdPipelineBarrier2KHR")) return "vkCmdPipelineBarrier2";
    if (!strcmp(name, "vkCmdBeginRenderingKHR")) return "vkCmdBeginRendering";
    if (!strcmp(name, "vkCmdEndRenderingKHR")) return "vkCmdEndRendering";
    if (!strcmp(name, "vkCmdPushDescriptorSetKHR")) return "vkCmdPushDescriptorSet";
    if (!strcmp(name, "vkCmdPushDescriptorSetWithTemplateKHR")) return "vkCmdPushDescriptorSetWithTemplate";
    // F19 (.18): the create-side KHR spelling of the same feature. Identical parameter list (header
    // :10782 vs :6186); the ICD only exposes the unsuffixed core name, so fold it like the other two.
    if (!strcmp(name, "vkCreateDescriptorUpdateTemplateKHR")) return "vkCreateDescriptorUpdateTemplate";
    // F21 (.19): the synchronization2 v2 event/timestamp KHR aliases -- identical parameter lists
    // (header :12431-:12435); the ICD exposes only the core names, so fold them like the others.
    if (!strcmp(name, "vkCmdSetEvent2KHR")) return "vkCmdSetEvent2";
    if (!strcmp(name, "vkCmdResetEvent2KHR")) return "vkCmdResetEvent2";
    if (!strcmp(name, "vkCmdWaitEvents2KHR")) return "vkCmdWaitEvents2";
    if (!strcmp(name, "vkCmdWriteTimestamp2KHR")) return "vkCmdWriteTimestamp2";
    // F22 (.20): the KHR spelling of the queue-family property query -- identical parameter list
    // (header :10359); the ICD exposes only the core name, so fold it like the others.
    if (!strcmp(name, "vkGetPhysicalDeviceQueueFamilyProperties2KHR")) return "vkGetPhysicalDeviceQueueFamilyProperties2";
    return name;
}

static int is_gated(const char* n) {
    for (int i = 0; i < kGatedCount; i++) {
        if (!strcmp(n, kGatedNames[i])) return 1;
    }
    return 0;
}

// ------------------------------------------------------- hook 1: advertise
static VkResult hook_EnumerateDeviceExtensionProperties(VkPhysicalDevice pdev, const char* layer,
                                                        uint32_t* pCount, VkExtensionProperties* pProps) {
    VkResult (*real)(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*) =
        (VkResult(*)(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*))
            real_proc("vkEnumerateDeviceExtensionProperties");
    if (!real) {
        MEOWLOGE("meowvulkan: cannot resolve vkEnumerateDeviceExtensionProperties (instance=%{public}p) -> -7",
                 g_inst_seen);
        return -7;   // VK_ERROR_EXTENSION_NOT_PRESENT
    }
    if (!pCount) return real(pdev, layer, pCount, pProps);
    if (layer != NULL) return real(pdev, layer, pCount, pProps);   // layer query: leave alone
    if (pProps == NULL) {
        VkResult r = real(pdev, layer, pCount, pProps);
        *pCount += kGatedCount;                                    // report our extra names
        return (r == VK_INCOMPLETE) ? VK_SUCCESS : r;
    }
    uint32_t cap = *pCount;
    VkResult r = real(pdev, layer, pCount, pProps);
    uint32_t n = *pCount;
    for (int i = 0; i < kGatedCount; i++) {
        if (n >= cap) break;
        int dup = 0;
        for (uint32_t k = 0; k < n; k++) {
            if (!strcmp(pProps[k].extensionName, kGatedNames[i])) { dup = 1; break; }
        }
        if (dup) continue;
        memset(&pProps[n], 0, sizeof(pProps[n]));
        strncpy(pProps[n].extensionName, kGatedNames[i], sizeof(pProps[n].extensionName) - 1);
        pProps[n].specVersion = 1;
        n++;
        MEOWLOGI("meowvulkan: advertised (gated name added): %{public}s", kGatedNames[i]);
    }
    *pCount = n;
    return r;
}

// Diagnostic bisect switch (2026-09-17, shim build .9). "THE ONE LIE" is the unconditional
// VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT.vertexAttributeInstanceRateDivisor = 1 write
// below (the official SDK field name; the old local mirror mislabelled it `rateDivisor`). The other two
// forged feature bits (dynamic_rendering / push_descriptor) are proven real implementations, so
// this single-variable switch isolates the divisor lie: MEOW_VK_NO_DIVISOR_FEATURE=1 skips ONLY
// that write and changes nothing else. maxVertexAttribDivisor property reads are untouched.
// Env read once, default off. (F75 removed the sibling MEOW_VK_NO_VK13_WRITE bisect.)
static int meow_vk_skip_divisor_feature(void) {
    static int v = -1;
    if (v < 0) {
        const char* s = getenv("MEOW_VK_NO_DIVISOR_FEATURE");
        v = (s != NULL && s[0] == '1') ? 1 : 0;
    }
    return v;
}

// ------------------------------------------------- F35 (.23): strip feature bits
// The mirror image of the three writes in hook_GetPhysicalDeviceFeatures2 below. The shim already
// strips EXTENSION names the ICD rejects (hook_CreateDevice, hook 3) but never touched the FEATURE
// BITS. So the app could still put "dynamicRendering / synchronization2 / vertex-attribute-divisor =
// VK_TRUE" in VkDeviceCreateInfo::pNext and this ICD silently accepted bits it does not implement --
// exactly the "works for a frame or two, then DEVICE_LOST" shape this campaign chased. This walk runs
// on the VkDeviceCreateInfo COPY that hook_CreateDevice builds; a node whose sType we know has only
// the named fields zeroed. The node stays in the chain ("present but 0" is legal); nothing is
// unlinked and no unknown feature bit is touched. The caller's top-level VkDeviceCreateInfo is never
// handed to the driver -- only the copy is. (The pNext nodes themselves are the caller's, and like
// hook_GetPhysicalDeviceFeatures2 above we write the two fields in place; the driver is given the
// same chain through the copy.)
// F36: the switch now DEFAULTS ON whenever the shim hooks are ON. Rationale: the hooks already make MC
// believe the ICD has the gated extensions (extension-name stripping keeps the masquerade), so they MUST
// also zero the feature bits -- otherwise MC builds a device out of features the ICD never had, which is
// driver UB. On-device vkCreateDevice rc=-8 returns VK_ERROR_FEATURE_NOT_PRESENT (vulkan_core.h:154),
// i.e. exactly "you asked for a feature I do not have": that is the direct evidence for this default.
// Explicit values still win: MEOW_VK_STRIP_UNSUPPORTED_FEATURES=0 forces it OFF (control experiment),
// =1 forces it ON (F35 semantics unchanged). Env is read once; g_hooks is set by init_once before any
// hook runs, so it is valid here.
static int meow_vk_strip_unsupported_features(void) {
    static int v = -1;
    if (v < 0) {
        const char* s = getenv("MEOW_VK_STRIP_UNSUPPORTED_FEATURES");
        if (s != NULL && strcmp(s, "0") == 0) {
            v = 0;                     /* explicit off */
        } else if (s != NULL && s[0] == '1') {
            v = 1;                     /* explicit on (F35 semantics unchanged) */
        } else {
            v = g_hooks ? 1 : 0;       /* F36: default follows the hooks */
        }
    }
    return v;
}

static void meow_vk_strip_feature_bits(void* pNext) {
    int stripped = 0;
    // F37: synchronization2 is KEPT (this ICD advertises VK_KHR_synchronization2 (A10 G1) and MC
    // hard-depends on it). This ICD-advertised extension was a false positive: zeroing the bit left MC
    // using vkQueueSubmit2 / VkSubmitInfo2 with sync2 "disabled" -- the use-of-unenabled-feature UB this
    // campaign chased. The F35 vkCreateDevice rc=-8 is explained by dynamicRendering +
    // vertex_attribute_divisor alone (their extensions are NOT in the ICD's 69-name list). F75 removed
    // the MEOW_VK_KEEP_SYNC2 A/B switch; sync2 is now unconditionally kept.
    for (VkBaseOutStructure* p = (VkBaseOutStructure*)pNext; p != NULL; p = p->pNext) {
        switch (p->sType) {
            case ST_VK13_FEATURES: {
                Vk13Features* f = (Vk13Features*)p;
                if (f->dynamicRendering) {
                    MEOWLOGI("meowvulkan: F35 strip: VkPhysicalDeviceVulkan13Features.dynamicRendering "
                             "%{public}u -> 0", f->dynamicRendering);
                    f->dynamicRendering = 0;
                    stripped++;
                }
                break;
            }
            case ST_DYNREND_FEATURES: {
                VkDynRenderFeatures* f = (VkDynRenderFeatures*)p;
                if (f->dynamicRendering) {
                    MEOWLOGI("meowvulkan: F35 strip: VkPhysicalDeviceDynamicRenderingFeatures.dynamicRendering "
                             "%{public}u -> 0", f->dynamicRendering);
                    f->dynamicRendering = 0;
                    stripped++;
                }
                break;
            }
            case ST_DIVISOR_FEATURES_EXT: {
                VkDivisorFeaturesExt* f = (VkDivisorFeaturesExt*)p;
                if (f->vertexAttributeInstanceRateDivisor) {
                    MEOWLOGI("meowvulkan: F35 strip: "
                             "VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT.vertexAttributeInstanceRateDivisor "
                             "%{public}u -> 0", f->vertexAttributeInstanceRateDivisor);
                    f->vertexAttributeInstanceRateDivisor = 0;
                    stripped++;
                }
                if (f->vertexAttributeInstanceRateZeroDivisor) {
                    MEOWLOGI("meowvulkan: F35 strip: "
                             "VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT.vertexAttributeInstanceRateZeroDivisor "
                             "%{public}u -> 0", f->vertexAttributeInstanceRateZeroDivisor);
                    f->vertexAttributeInstanceRateZeroDivisor = 0;
                    stripped++;
                }
                break;
            }
            default: break;
        }
    }
    MEOWLOGI("meowvulkan: F35 strip: pNext walk done, %{public}d feature bit(s) zeroed "
             "(sync2 KEPT)", stripped);
}

// ------------------------------------------------------------ hook 2: bits
static void hook_GetPhysicalDeviceFeatures2(VkPhysicalDevice pdev, void* pFeatures) {
    void (*real)(VkPhysicalDevice, void*) = (void (*)(VkPhysicalDevice, void*))real_proc("vkGetPhysicalDeviceFeatures2");
    if (real) real(pdev, pFeatures);
    for (VkBaseOutStructure* p = (VkBaseOutStructure*)pFeatures; p != NULL; p = p->pNext) {
        switch (p->sType) {
            case ST_VK13_FEATURES:
                ((Vk13Features*)p)->dynamicRendering = 1;
                MEOWLOGI("meowvulkan: set Vulkan13Features.dynamicRendering=1");
                break;
            case ST_DYNREND_FEATURES:
                ((VkDynRenderFeatures*)p)->dynamicRendering = 1;
                MEOWLOGI("meowvulkan: set DynamicRenderingFeatures.dynamicRendering=1");
                break;
            case ST_DIVISOR_FEATURES_EXT:
                // THE ONE LIE: maxVertexAttribDivisor is 1. Safe for vanilla (never uses != 1),
                // wrong for mods. Flagged in the UI/docs and revertible.
                // MEOW_VK_NO_DIVISOR_FEATURE=1 (build .9) skips just this write so the lie can be
                // bisected on its own; everything else is unchanged.
                if (meow_vk_skip_divisor_feature()) {
                    MEOWLOGI("meowvulkan: DIAG: skipping VertexAttributeDivisorFeaturesEXT.vertexAttributeInstanceRateDivisor write");
                    break;
                }
                ((VkDivisorFeaturesExt*)p)->vertexAttributeInstanceRateDivisor = 1;
                MEOWLOGI("meowvulkan: set VertexAttributeDivisorFeaturesEXT.vertexAttributeInstanceRateDivisor=1 (this one is a lie)");
                break;
            default: break;
        }
    }
}

// ------------------------------------------------- hook 3: createDevice copy
static VkResult hook_CreateDevice(VkPhysicalDevice pdev, const VkDeviceCI* ci, const void* alloc, VkDevice* out) {
    VkResult (*real)(VkPhysicalDevice, const VkDeviceCI*, const void*, VkDevice*) =
        (VkResult(*)(VkPhysicalDevice, const VkDeviceCI*, const void*, VkDevice*))real_proc("vkCreateDevice");
    if (!real) return -3;   // VK_ERROR_INITIALIZATION_FAILED
    if (!ci) return real(pdev, ci, alloc, out);

    /* File-scope, NOT a local: this pointer goes to the ICD inside `copy`. The Vulkan contract says the
     * driver must not retain it, but this ICD is measured to keep such data alive longer than the spec
     * allows (see the vendor-compiler notes), and a stack array would be reused while the driver still
     * pointed at it -- a use-after-return window that produces exactly the wandering low-address faults
     * we have been chasing. One vkCreateDevice per process: no cost, one fewer way to die. */
    static const char* kept[256];
    uint32_t n = 0;
    int extChanged = 0;
    const char* const* names = (const char* const*)ci->ppEnabledExtensionNames;
    if (names != NULL && ci->enabledExtensionCount > 0) {
        for (uint32_t i = 0; i < ci->enabledExtensionCount && n < 256; i++) {
            if (names[i] && is_gated(names[i])) {
                MEOWLOGI("meowvulkan: createDevice dropping (ICD rejects it): %{public}s", names[i]);
                continue;
            }
            kept[n++] = names[i];
        }
        extChanged = (n != ci->enabledExtensionCount);
    }

    // F35/F36 (.24): also strip feature BITS the ICD does not implement (F36: default ON with hooks; =0 disables).
    int stripFeatures = meow_vk_strip_unsupported_features();
    if (!extChanged && !stripFeatures) return real(pdev, ci, alloc, out);   // nothing to strip

    VkDeviceCI copy = *ci;
    if (extChanged) {
        copy.enabledExtensionCount = n;
        copy.ppEnabledExtensionNames = kept;
    }
    if (stripFeatures) {
        MEOWLOGI("meowvulkan: createDevice stripping unsupported feature bits (F36: default with hooks; MEOW_VK_STRIP_UNSUPPORTED_FEATURES=0 disables)");
        meow_vk_strip_feature_bits((void*)copy.pNext);
    }
    return real(pdev, &copy, alloc, out);
}

// ------------------------------------------------------------- the exports
// meowbt is compiled into libmeowcraftbridge.so, and this shim is a SEPARATE shared object, so the
// dumper cannot be called directly (that is an undefined symbol at link time -- measured). Resolve it
// lazily through the already-loaded bridge instead: RTLD_NOLOAD finds it regardless of how it was
// opened, and if it is missing we warn once and carry on with the dumper off.
/* Diagnostic verbosity. The per-lookup logging is high-volume (hundreds of lines per run) and it
 * measurably perturbs timing -- which matters when what we are chasing may be a race inside MC
 * itself. Default QUIET (the project rule for diagnostic switches), MEOW_VK_VERBOSE=1 brings the
 * per-lookup/MAP noise back. The low-volume result lines (allocate/createBuffer/map/bind) still log. */
static int meow_vk_verbose(void) {
    static int v = -1;
    if (v < 0) {
        const char* s = getenv("MEOW_VK_VERBOSE");
        v = (s != NULL && s[0] == '1') ? 1 : 0;
    }
    return v;
}

// F17 (.16): the "unwrapped command" catch-all. Every wrapper we own has already returned by the time
// this runs, so any vkCmd* name that reaches the final forward is one we did NOT wrap -- exactly the
// invisible content of a command buffer that vkQueueSubmit2 reports as empty. Each name is logged
// ONCE through a small static dedup table (<=64 names), shared by both GPA catch-alls; the copy into
// the table means the caller's string need not outlive the call. Low volume, so it is deliberately
// NOT gated by MEOW_VK_VERBOSE -- this is the signal, not the per-lookup noise. Logging only: no
// wrapper is added and no forwarded value changes.
#define MEOW_UNWRAPPED_MAX 64
#define MEOW_UNWRAPPED_NAME 64
static char g_unwrapped_seen[MEOW_UNWRAPPED_MAX][MEOW_UNWRAPPED_NAME];
static int g_unwrapped_count;

static void note_unwrapped(const char* lvl, const char* name) {
    if (name == NULL || strncmp(name, "vkCmd", 5) != 0) return;
    size_t len = strlen(name);
    if (len >= MEOW_UNWRAPPED_NAME) len = MEOW_UNWRAPPED_NAME - 1;
    for (int i = 0; i < g_unwrapped_count; i++) {
        if (!strncmp(g_unwrapped_seen[i], name, len) && g_unwrapped_seen[i][len] == 0) return;
    }
    if (g_unwrapped_count < MEOW_UNWRAPPED_MAX) {
        memcpy(g_unwrapped_seen[g_unwrapped_count], name, len);
        g_unwrapped_seen[g_unwrapped_count][len] = 0;
        g_unwrapped_count++;
    }
    MEOWLOGI("meowvulkan: UNWRAPPED %{public}s%{public}s", lvl, name);
}

static void meow_maybe_install_bt(void) {
    static int tried = 0;
    static void (*install)(void) = NULL;
    if (tried) {
        if (install != NULL) {
            install();
        }
        return;
    }
    tried = 1;
    void* bridge = dlopen("libmeowcraftbridge.so", RTLD_NOW | RTLD_NOLOAD);
    if (bridge != NULL) {
        install = (void (*)(void))dlsym(bridge, "meow_bt_install_once");
    }
    if (install != NULL) {
        install();
    } else {
        MEOWLOGW("meowvulkan: meow_bt_install_once not found in libmeowcraftbridge.so (dumper stays off)");
    }
}

PFN_vkVoidFunctionLocal vkGetInstanceProcAddr(VkInstance inst, const char* name) {
    init_once();
    wd_maybe_start();
    wd_touch();
    /* The Vulkan backend walks none of the GL paths and the surface is injected BEFORE launchJvm, so
     * the bridge's other install sites are either unreachable (meowMakeCurrent/meowSwapBuffers) or
     * too early (meowSetSurfaceId). Here is the first moment guaranteed to be *after* HotSpot
     * installed its SIGSEGV handler -- so the dumper can chain correctly instead of bypassing the JVM.
     * No-op unless MEOW_BT is set (meow_bt_install_once checks it itself). */
    meow_maybe_install_bt();
    if (inst != NULL) g_inst_seen = inst;   // remember it: instance-level forwards need a real instance
    if (!g_gipa) return NULL;
    // CRITICAL: LWJGL fetches vkGetDeviceProcAddr THROUGH vkGetInstanceProcAddr. Forwarding that one
    // lookup to the real loader silently bypasses this shim for every device-level command, so the
    // KHR->core name mapping never runs -- and MC's vkCmdBeginRenderingKHR (the KHR spelling, which
    // this ICD only exposes unsuffixed because we had to strip the extension from createDevice)
    // resolves to NULL and SIGSEGVs. Hand back OUR implementation.
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunctionLocal)vkGetDeviceProcAddr;
    if (g_hooks) {
        if (!strcmp(name, "vkEnumerateDeviceExtensionProperties")) return (PFN_vkVoidFunctionLocal)hook_EnumerateDeviceExtensionProperties;
        if (!strcmp(name, "vkGetPhysicalDeviceFeatures2") ||
            !strcmp(name, "vkGetPhysicalDeviceFeatures2KHR")) return (PFN_vkVoidFunctionLocal)hook_GetPhysicalDeviceFeatures2;
        // Platform-specific lead: this GPU's 4-type memory table (one type is LAZILY_ALLOCATED).
        if (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties")) return (PFN_vkVoidFunctionLocal)hook_GetPhysicalDeviceMemoryProperties;
        if (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties2") ||
            !strcmp(name, "vkGetPhysicalDeviceMemoryProperties2KHR")) return (PFN_vkVoidFunctionLocal)hook_GetPhysicalDeviceMemoryProperties2;
        // F22 (.20): the queue family's timestamp capability (timestampValidBits). Instance-level,
        // registered by the MAPPED name so the KHR spelling (folded in map_name) reaches this wrapper.
        if (!strcmp(map_name(name), "vkGetPhysicalDeviceQueueFamilyProperties")) return (PFN_vkVoidFunctionLocal)log_GetPhysicalDeviceQueueFamilyProperties;
        if (!strcmp(map_name(name), "vkGetPhysicalDeviceQueueFamilyProperties2")) return (PFN_vkVoidFunctionLocal)log_GetPhysicalDeviceQueueFamilyProperties2;
        // F9 (.12): WSI surface queries (instance-level; no KHR->core alias exists -- the KHR
        // suffix is part of the real name). These name the surface capabilities MC built the
        // swapchain against, most importantly supportedUsageFlags.
        if (!strcmp(name, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) return (PFN_vkVoidFunctionLocal)log_GetPhysicalDeviceSurfaceCapabilitiesKHR;
        if (!strcmp(name, "vkGetPhysicalDeviceSurfaceFormatsKHR")) return (PFN_vkVoidFunctionLocal)log_GetPhysicalDeviceSurfaceFormatsKHR;
        if (!strcmp(name, "vkGetPhysicalDeviceSurfacePresentModesKHR")) return (PFN_vkVoidFunctionLocal)log_GetPhysicalDeviceSurfacePresentModesKHR;
        // F18 (.17): the three DebugUtils label commands are DEVICE-level, but MC resolves them through
        // this instance path (F17 log: "UNWRAPPED instance vkCmdBeginDebugUtilsLabelEXT" etc.), so they
        // are registered here as well as in vkGetDeviceProcAddr. Match on map_name(name) like the
        // device-path table (identity for these EXT names, but never an exact raw-strcmp regression).
        if (!strcmp(map_name(name), "vkCmdBeginDebugUtilsLabelEXT")) return (PFN_vkVoidFunctionLocal)log_CmdBeginDebugUtilsLabelEXT;
        if (!strcmp(map_name(name), "vkCmdEndDebugUtilsLabelEXT")) return (PFN_vkVoidFunctionLocal)log_CmdEndDebugUtilsLabelEXT;
        if (!strcmp(map_name(name), "vkCmdInsertDebugUtilsLabelEXT")) return (PFN_vkVoidFunctionLocal)log_CmdInsertDebugUtilsLabelEXT;
        // F45: serve the two sync2 entry points from the INSTANCE path too, mirroring the
        // DebugUtils-label precedent just above. A caller that resolves them through
        // vkGetInstanceProcAddr (rather than vkGetDeviceProcAddr) would otherwise receive the
        // ICD's raw function and silently bypass the sync2->v1 translation. map_name() now folds
        // the KHR spellings onto these core names, so one test covers both.
        if (!strcmp(map_name(name), "vkQueueSubmit2")) return (PFN_vkVoidFunctionLocal)log_QueueSubmit2;
        if (!strcmp(map_name(name), "vkCmdPipelineBarrier2")) return (PFN_vkVoidFunctionLocal)log_CmdPipelineBarrier2;
    }
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunctionLocal)hook_CreateDevice;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunctionLocal)vkCreateInstance;
    // Diagnostic gap (cost two rounds): instance-level lookups were only logged when they FAILED, so a
    // name that never reached us -- e.g. LWJGL refusing to resolve a KHR spelling because the extension
    // is not enabled -- was invisible. MEOW_VK_VERBOSE=1 now logs every instance-level lookup too.
    if (g_hooks && name != NULL && meow_vk_verbose()) {
        MEOWLOGI("meowvulkan: gipa lookup: %{public}s (inst=%{public}p)", name, g_inst_seen);
    }
    // F17 (.16): last fallback -- after every wrapper decision above, before the real lookup. Any
    // vkCmd* name still here is unwrapped (the reader can tell this was the instance path).
    note_unwrapped("instance ", name);
    // Never forward with a NULL instance when we already know the real one: only GLOBAL commands are
    // resolvable that way, and callers (LWJGL's VMA bindings among them) do look up device-level
    // commands here. real_proc() retries through the instance we were given.
    PFN_vkVoidFunctionLocal out = real_proc(map_name(name));
    if (out == NULL) {
        MEOWLOGW("meowvulkan: instance lookup miss: %{public}s (instance=%{public}p)", name, g_inst_seen);
    }
    return out;
}

PFN_vkVoidFunctionLocal vkGetDeviceProcAddr(VkDevice dev, const char* name) {
    init_once();
    wd_maybe_start();
    wd_note(name);
    if (dev != NULL) g_dev_seen = dev;
    // F16 (.15): the wrapper table below is keyed on the MAPPED name, not the raw spelling. MC
    // resolves the KHR spellings (vkCmdBeginRenderingKHR / vkCmdEndRenderingKHR /
    // vkCmdPushDescriptorSetKHR); map_name() folds those onto the core names the ICD exposes.
    // Matching on the raw name made the exact-strcmp chain miss them, so the lookup fell through to
    // the real ICD and OUR wrapper was silently bypassed. map_name() is NULL-safe and is the identity
    // for every name it does not alias, so `mapped == name` on the non-aliased paths.
    const char* mapped = map_name(name);
    if (g_hooks && !strcmp(mapped, "vkCmdCopyBufferToImage")) {
        return (PFN_vkVoidFunctionLocal)log_CmdCopyBufferToImage;
    }
    if (g_hooks && !strcmp(mapped, "vkCmdPushDescriptorSet")) {
        if (mapped != name) MEOWLOGI("meowvulkan: wrapper serves %{public}s (mapped %{public}s)", name, mapped);
        return (PFN_vkVoidFunctionLocal)log_CmdPushDescriptorSet;
    }
    // F19 (.18): the LAST unwrapped command path -- MC's descriptor update is push+template, so with no
    // wrapper here the buffer recorded as EMPTY. map_name() already folds the KHR spelling (F16 .15).
    if (g_hooks && !strcmp(mapped, "vkCmdPushDescriptorSetWithTemplate")) {
        if (mapped != name) MEOWLOGI("meowvulkan: wrapper serves %{public}s (mapped %{public}s)", name, mapped);
        return (PFN_vkVoidFunctionLocal)log_CmdPushDescriptorSetWithTemplate;
    }
    // F19 (.18): the create side, so the push above has the template's shape in the cache. Registered by
    // the same mapped name (the KHR spelling folds onto the core name in map_name()).
    if (g_hooks && !strcmp(mapped, "vkCreateDescriptorUpdateTemplate")) {
        if (mapped != name) MEOWLOGI("meowvulkan: wrapper serves %{public}s (mapped %{public}s)", name, mapped);
        return (PFN_vkVoidFunctionLocal)log_CreateDescriptorUpdateTemplate;
    }
    if (g_hooks && !strcmp(mapped, "vkCreateShaderModule")) {
        return (PFN_vkVoidFunctionLocal)log_CreateShaderModule;
    }
    if (g_hooks && !strcmp(mapped, "vkMapMemory")) {
        return (PFN_vkVoidFunctionLocal)log_MapMemory;
    }
    if (g_hooks && !strcmp(mapped, "vkAllocateMemory")) {
        return (PFN_vkVoidFunctionLocal)log_AllocateMemory;
    }
    if (g_hooks && !strcmp(mapped, "vkBindBufferMemory")) {
        return (PFN_vkVoidFunctionLocal)log_BindBufferMemory;
    }
    if (g_hooks && !strcmp(mapped, "vkCreateBuffer")) {
        return (PFN_vkVoidFunctionLocal)log_CreateBuffer;
    }
    // Close the "unhooked call" measurement gap right after the first VMA allocation:
    if (g_hooks && !strcmp(mapped, "vkGetBufferMemoryRequirements")) {
        return (PFN_vkVoidFunctionLocal)log_GetBufferMemoryRequirements;
    }
    if (g_hooks && !strcmp(mapped, "vkCreateImage")) {
        return (PFN_vkVoidFunctionLocal)log_CreateImage;
    }
    // F53: the destroy side, so the per-image cache slot (and any LINEAR intermediate) is
    // released with the image instead of leaking for the process lifetime.
    if (g_hooks && !strcmp(mapped, "vkDestroyImage")) {
        return (PFN_vkVoidFunctionLocal)log_DestroyImage;
    }
    if (g_hooks && !strcmp(mapped, "vkFlushMappedMemoryRanges")) {
        return (PFN_vkVoidFunctionLocal)log_FlushMappedMemoryRanges;
    }
    if (g_hooks && !strcmp(mapped, "vkQueueSubmit")) {
        return (PFN_vkVoidFunctionLocal)log_QueueSubmit;
    }
    // F5 (.8): synchronization2 submit path. Register BOTH spellings: MC may resolve the KHR name
    // (the header has vkQueueSubmit2KHR / vkWaitSemaphoresKHR / vkGetSemaphoreCounterValueKHR with
    // identical parameters), and the wrapper always forwards to the unsuffixed core name the ICD exposes.
    if (g_hooks && (!strcmp(mapped, "vkQueueSubmit2") || !strcmp(mapped, "vkQueueSubmit2KHR"))) {
        return (PFN_vkVoidFunctionLocal)log_QueueSubmit2;
    }
    if (g_hooks && (!strcmp(mapped, "vkWaitSemaphores") || !strcmp(mapped, "vkWaitSemaphoresKHR"))) {
        return (PFN_vkVoidFunctionLocal)log_WaitSemaphores;
    }
    if (g_hooks && (!strcmp(mapped, "vkGetSemaphoreCounterValue") ||
                    !strcmp(mapped, "vkGetSemaphoreCounterValueKHR"))) {
        return (PFN_vkVoidFunctionLocal)log_GetSemaphoreCounterValue;
    }
    if (g_hooks && !strcmp(mapped, "vkDeviceWaitIdle")) {
        return (PFN_vkVoidFunctionLocal)log_DeviceWaitIdle;
    }
    // Init-tail probes (entry-only): the last "… CALLED" line printed before death names the call.
    if (g_hooks && !strcmp(mapped, "vkCreatePipelineLayout")) return (PFN_vkVoidFunctionLocal)log_vkCreatePipelineLayout;
    if (g_hooks && !strcmp(mapped, "vkCreateDescriptorSetLayout")) return (PFN_vkVoidFunctionLocal)log_vkCreateDescriptorSetLayout;
    // F72b (build .50): destroy side so each mirror set layout is released with its original.
    if (g_hooks && !strcmp(mapped, "vkDestroyDescriptorSetLayout")) return (PFN_vkVoidFunctionLocal)log_vkDestroyDescriptorSetLayout;
    if (g_hooks && !strcmp(mapped, "vkCreateCommandPool")) return (PFN_vkVoidFunctionLocal)log_vkCreateCommandPool;
    if (g_hooks && (!strcmp(mapped, "vkCreateSemaphore") ||
                    (name != NULL && !strcmp(name, "vkCreateSemaphoreKHR")))) return (PFN_vkVoidFunctionLocal)log_vkCreateSemaphore;
    // F69: destroy side of the timeline tracking. Registered by the same style as neighbours; a
    // pure passthrough when MEOW_VK_TIMELINE_AS_FENCE is off.
    if (g_hooks && (!strcmp(mapped, "vkDestroySemaphore") ||
                    (name != NULL && !strcmp(name, "vkDestroySemaphoreKHR")))) return (PFN_vkVoidFunctionLocal)log_DestroySemaphore;
    if (g_hooks && !strcmp(mapped, "vkDestroyDevice")) return (PFN_vkVoidFunctionLocal)log_DestroyDevice;
    if (g_hooks && !strcmp(mapped, "vkCreateFence")) return (PFN_vkVoidFunctionLocal)log_vkCreateFence;
    if (g_hooks && !strcmp(mapped, "vkCreateSwapchainKHR")) return (PFN_vkVoidFunctionLocal)log_vkCreateSwapchainKHR;
    if (g_hooks && !strcmp(mapped, "vkCreateGraphicsPipelines")) return (PFN_vkVoidFunctionLocal)log_CreateGraphicsPipelines;
    if (g_hooks && !strcmp(mapped, "vkAllocateCommandBuffers")) return (PFN_vkVoidFunctionLocal)log_AllocateCommandBuffers;
    if (g_hooks && !strcmp(mapped, "vkGetDeviceQueue")) return (PFN_vkVoidFunctionLocal)log_GetDeviceQueue;
    if (g_hooks && !strcmp(mapped, "vkBeginCommandBuffer")) return (PFN_vkVoidFunctionLocal)log_BeginCommandBuffer;
    if (g_hooks && !strcmp(mapped, "vkCmdBeginRendering")) {
        if (mapped != name) MEOWLOGI("meowvulkan: wrapper serves %{public}s (mapped %{public}s)", name, mapped);
        return (PFN_vkVoidFunctionLocal)log_CmdBeginRendering;
    }
    // F6 (.9): present/acquire + command-level diagnostics. Register both spellings where the header
    // defines a KHR alias (vkCmdPipelineBarrier2KHR :12434, vkCmdEndRenderingKHR :10305); the wrappers
    // always forward to the unsuffixed core name the ICD exposes.
    if (g_hooks && !strcmp(mapped, "vkAcquireNextImageKHR")) return (PFN_vkVoidFunctionLocal)log_AcquireNextImageKHR;
    if (g_hooks && !strcmp(mapped, "vkQueuePresentKHR")) return (PFN_vkVoidFunctionLocal)log_QueuePresentKHR;
    if (g_hooks && (!strcmp(mapped, "vkCmdPipelineBarrier2") ||
                    !strcmp(mapped, "vkCmdPipelineBarrier2KHR"))) return (PFN_vkVoidFunctionLocal)log_CmdPipelineBarrier2;
    if (g_hooks && !strcmp(mapped, "vkCmdBindPipeline")) return (PFN_vkVoidFunctionLocal)log_CmdBindPipeline;
    if (g_hooks && !strcmp(mapped, "vkCmdDraw")) return (PFN_vkVoidFunctionLocal)log_CmdDraw;
    if (g_hooks && !strcmp(mapped, "vkCmdDrawIndexed")) return (PFN_vkVoidFunctionLocal)log_CmdDrawIndexed;
    // F70 (.46): the indirect draw family was NOT wrapped before; it exists so MEOW_VK_DROP_DRAW can
    // reach MC's actual draws (A8 3.1: MC uses vkCmdDrawIndirect / vkCmdDrawIndexedIndirect).
    if (g_hooks && !strcmp(mapped, "vkCmdDrawIndirect")) return (PFN_vkVoidFunctionLocal)log_CmdDrawIndirect;
    if (g_hooks && !strcmp(mapped, "vkCmdDrawIndexedIndirect")) return (PFN_vkVoidFunctionLocal)log_CmdDrawIndexedIndirect;
    if (g_hooks && (!strcmp(mapped, "vkCmdEndRendering") ||
                    !strcmp(mapped, "vkCmdEndRenderingKHR"))) {
        if (mapped != name) MEOWLOGI("meowvulkan: wrapper serves %{public}s (mapped %{public}s)", name, mapped);
        return (PFN_vkVoidFunctionLocal)log_CmdEndRendering;
    }
    if (g_hooks && !strcmp(mapped, "vkCmdCopyBuffer")) return (PFN_vkVoidFunctionLocal)log_CmdCopyBuffer;
    // F7 (.10): binding entry points. None of these has a KHR alias in the header (the KHR families
    // are vkCmdBindVertexBuffers2 / vkCmdBindIndexBuffer2 / vkCmdBindDescriptorSets2, different
    // signatures), so only the unsuffixed names are registered.
    if (g_hooks && !strcmp(mapped, "vkCmdBindVertexBuffers")) return (PFN_vkVoidFunctionLocal)log_CmdBindVertexBuffers;
    if (g_hooks && !strcmp(mapped, "vkCmdBindIndexBuffer")) return (PFN_vkVoidFunctionLocal)log_CmdBindIndexBuffer;
    if (g_hooks && !strcmp(mapped, "vkCmdBindDescriptorSets")) return (PFN_vkVoidFunctionLocal)log_CmdBindDescriptorSets;
    // F8 (.11): the transfer/state commands between the two barriers. All core 1.0, all unsuffixed
    // (the header's only 2-suffixed variants are vkCmdCopyImage2/vkCmdBlitImage2 -- different
    // signatures -- so no KHR alias is registered). vkCmdClearDepthStencilImage is deliberately NOT
    // wrapped (not needed this round).
    if (g_hooks && !strcmp(mapped, "vkCmdCopyImage")) return (PFN_vkVoidFunctionLocal)log_CmdCopyImage;
    if (g_hooks && !strcmp(mapped, "vkCmdBlitImage")) return (PFN_vkVoidFunctionLocal)log_CmdBlitImage;
    if (g_hooks && !strcmp(mapped, "vkCmdClearColorImage")) return (PFN_vkVoidFunctionLocal)log_CmdClearColorImage;
    if (g_hooks && !strcmp(mapped, "vkCmdSetViewport")) return (PFN_vkVoidFunctionLocal)log_CmdSetViewport;
    if (g_hooks && !strcmp(mapped, "vkCmdSetScissor")) return (PFN_vkVoidFunctionLocal)log_CmdSetScissor;
    if (g_hooks && !strcmp(mapped, "vkCmdClearAttachments")) return (PFN_vkVoidFunctionLocal)log_CmdClearAttachments;
    // F18 (.17): bounded wrappers for the commands that made a submitted buffer look EMPTY. All core
    // vkCmd* names are resolved through the device path; the DebugUtils labels also have an
    // instance-path registration above (MC asked for them through vkGetInstanceProcAddr). None of the
    // six core names has a KHR alias in the header, so only the unsuffixed spelling is registered.
    if (g_hooks && !strcmp(mapped, "vkCmdPipelineBarrier")) return (PFN_vkVoidFunctionLocal)log_CmdPipelineBarrier;
    if (g_hooks && !strcmp(mapped, "vkCmdPushConstants")) return (PFN_vkVoidFunctionLocal)log_CmdPushConstants;
    if (g_hooks && !strcmp(mapped, "vkCmdUpdateBuffer")) return (PFN_vkVoidFunctionLocal)log_CmdUpdateBuffer;
    if (g_hooks && !strcmp(mapped, "vkCmdFillBuffer")) return (PFN_vkVoidFunctionLocal)log_CmdFillBuffer;
    if (g_hooks && !strcmp(mapped, "vkCmdExecuteCommands")) return (PFN_vkVoidFunctionLocal)log_CmdExecuteCommands;
    if (g_hooks && !strcmp(mapped, "vkCmdBeginDebugUtilsLabelEXT")) return (PFN_vkVoidFunctionLocal)log_CmdBeginDebugUtilsLabelEXT;
    if (g_hooks && !strcmp(mapped, "vkCmdEndDebugUtilsLabelEXT")) return (PFN_vkVoidFunctionLocal)log_CmdEndDebugUtilsLabelEXT;
    if (g_hooks && !strcmp(mapped, "vkCmdInsertDebugUtilsLabelEXT")) return (PFN_vkVoidFunctionLocal)log_CmdInsertDebugUtilsLabelEXT;
    // F21 (.19): event / timestamp family -- the last unobserved command family. Registered by the
    // MAPPED name, exactly like the block above: map_name() folds the four KHR v2 spellings onto these
    // core names, and the v1 commands have no KHR alias in the header at all, so no raw strcmp is used.
    if (g_hooks && !strcmp(mapped, "vkCmdSetEvent")) return (PFN_vkVoidFunctionLocal)log_CmdSetEvent;
    if (g_hooks && !strcmp(mapped, "vkCmdResetEvent")) return (PFN_vkVoidFunctionLocal)log_CmdResetEvent;
    if (g_hooks && !strcmp(mapped, "vkCmdWaitEvents")) return (PFN_vkVoidFunctionLocal)log_CmdWaitEvents;
    if (g_hooks && !strcmp(mapped, "vkCmdSetEvent2")) return (PFN_vkVoidFunctionLocal)log_CmdSetEvent2;
    if (g_hooks && !strcmp(mapped, "vkCmdResetEvent2")) return (PFN_vkVoidFunctionLocal)log_CmdResetEvent2;
    if (g_hooks && !strcmp(mapped, "vkCmdWaitEvents2")) return (PFN_vkVoidFunctionLocal)log_CmdWaitEvents2;
    if (g_hooks && !strcmp(mapped, "vkCmdWriteTimestamp")) return (PFN_vkVoidFunctionLocal)log_CmdWriteTimestamp;
    if (g_hooks && !strcmp(mapped, "vkCmdWriteTimestamp2")) return (PFN_vkVoidFunctionLocal)log_CmdWriteTimestamp2;
    // F22 (.20): the query pool MC writes those timestamps into -- its shape (queryType/queryCount)
    // is hypothesis (b). Device-level, registered by the mapped name like every other create call.
    if (g_hooks && !strcmp(mapped, "vkCreateQueryPool")) return (PFN_vkVoidFunctionLocal)log_CreateQueryPool;
    // Diagnostic: log every device-level lookup only when MEOW_VK_VERBOSE=1. It is high volume
    // (hundreds of lines) and perturbs timing, which is exactly what we must NOT do while testing
    // whether an MC-side race is being exposed by our own logging.
    if (g_hooks && name != NULL && meow_vk_verbose()) {
        // Reuse the same mapped name computed above -- never map twice (F16 .15).
        if (mapped != name) {
            MEOWLOGI("meowvulkan: gdpa MAP %{public}s -> %{public}s", name, mapped);
        } else {
            MEOWLOGI("meowvulkan: gdpa lookup: %{public}s", name);
        }
    }
    if (g_gdpa == NULL) {
        // Resolve it through the real INSTANCE. vkGetDeviceProcAddr is a device-level command, so a
        // NULL-instance lookup is NOT guaranteed to resolve -- on this ICD it returns NULL, which made
        // every forward below degrade to g_gipa(NULL, name) and hand out NULL pointers. Measured
        // consequence: LWJGL's VMA capabilities ended up with a NULL vkAllocateMemory and MC died in
        // VmaVulkanFunctions.set -> Checks.check (NullPointerException) inside VulkanBackend.createVma.
        g_gdpa = (PFN_vkVoidFunctionLocal(*)(VkDevice, const char*))real_proc("vkGetDeviceProcAddr");
    }
    if (!g_gdpa) {
        MEOWLOGE("meowvulkan: cannot resolve the real vkGetDeviceProcAddr");
        return NULL;
    }
    // F17 (.16): this is the last fallback -- every wrapper we own has already returned, so a vkCmd*
    // name that still reaches this point is one we do NOT wrap. Name it once: that is how we learn the
    // contents of the submits' apparently-empty command buffers without wrapping each command by hand.
    note_unwrapped("", name);
    PFN_vkVoidFunctionLocal out = g_gdpa(dev, mapped);
    if (out == NULL) {
        // Same suffix-stripping fallback as real_proc(): VMA's function table is filled through here.
        char stripped[256];
        const char* s = strip_vk_suffix(mapped, stripped, sizeof(stripped));
        if (s != NULL) {
            out = g_gdpa(dev, s);
            if (out != NULL) {
                MEOWLOGI("meowvulkan: gdpa suffix-stripped fallback: %{public}s -> %{public}s", name, s);
            }
        }
    }
    if (out == NULL) {
        // MEASURED (vk_mem_alloc.h:13825): things like vkGetPhysicalDeviceProperties2KHR are
        // INSTANCE-level commands, but callers (LWJGL's Vma helper, VMA's own validation) do look them
        // up through vkGetDeviceProcAddr. A device lookup for an instance command returns NULL here, so
        // fall back to the instance path -- which already strips the KHR/EXT spelling.
        out = real_proc(name);
        if (out != NULL) {
            MEOWLOGI("meowvulkan: gdpa->instance fallback served: %{public}s", name);
        }
    }
    if (out == NULL) {
        MEOWLOGW("meowvulkan: gdpa MISS (real loader returned NULL): %{public}s", name);
    }
    return out;
}

VkResult vkCreateInstance(const void* ci, const void* alloc, VkInstance* out) {
    init_once();
    if (!g_gipa) return -9;   // VK_ERROR_INCOMPATIBLE_DRIVER
    // Which Vulkan version the application asks for decides which function-table entries VMA will use:
    // with vulkanApiVersion >= 1.3 it reaches for vkGetDevice{Buffer,Image}MemoryRequirements, which
    // VMA deliberately does NOT assert on (see its issue #397 note) -- a very plausible next NULL call.
    // Offsets from the SDK header: VkInstanceCreateInfo (vulkan_core.h:3211) is
    //   sType@0 pNext@8 flags@16 [pad@20] pApplicationInfo@24; VkApplicationInfo (vulkan_core.h:3187)
    //   is sType@0 pNext@8 pApplicationName@16 applicationVersion@24 pEngineName@32 engineVersion@40
    //   apiVersion@44. So pApplicationInfo is +24, NOT +16 (that is `flags` + its alignment padding).
    // Diagnostic only; quiet unless MEOW_VK_VERBOSE=1 (new diagnostics are env-gated by project rule).
    if (ci != NULL && meow_vk_verbose()) {
        const void* appInfo = *(const void* const*)((const char*)ci + 24);
        uint32_t api = (appInfo != NULL) ? *(const uint32_t*)((const char*)appInfo + 44) : 0u;
        MEOWLOGI("meowvulkan: vkCreateInstance apiVersion=%{public}u.%{public}u.%{public}u",
                 api >> 22, (api >> 12) & 0x3FFu, api & 0xFFFu);
    }
    VkResult (*real)(const void*, const void*, VkInstance*) =
        (VkResult(*)(const void*, const void*, VkInstance*))g_gipa(0, "vkCreateInstance");
    return real ? real(ci, alloc, out) : -9;
}

VkResult vkCreateDevice(VkPhysicalDevice pdev, const VkDeviceCI* ci, const void* alloc, VkDevice* out) {
    init_once();
    return hook_CreateDevice(pdev, ci, alloc, out);
}
