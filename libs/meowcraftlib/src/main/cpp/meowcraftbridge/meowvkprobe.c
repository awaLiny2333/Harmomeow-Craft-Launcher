/*
 * meowvkprobe.c - F29 minimal "sustained present" probe (bare ICD + WSI).
 *
 * WHY: the MC 26.2 Vulkan backend builds instance/surface/device/swapchain/pipeline,
 * presents one frame, then the SECOND vkQueueSubmit2 dies waiting a timeline
 * semaphore with rc=-4 (VK_ERROR_DEVICE_LOST). Ten-plus hypotheses were already
 * ruled out on-device (size, semaphore graph, barriers, reverse blit, descriptor
 * template, LAZILY memory, events, timestamp/query pools, queue family, swapchain
 * imageUsage, compositeAlpha, CPU_READ on the window, GPU bits, window buffer
 * queue, OHOS present interfaces).
 *
 * This probe is the "boundary experiment": a program that does NOT go through
 * MC and does NOT go through our libmeowvulkan.so shim. It dlopen()s the raw
 * system loader /system/lib64/libvulkan.so, builds instance/surface/device/
 * swapchain directly, and issues N back-to-back acquire -> submit -> present
 * cycles (default 120), recording each frame's rc. It draws nothing. Two
 * present-path variants exist, selected by MEOW_VK_PROBE_PIPELINE:
 *   blitImage (DEFAULT) - vkCmdClearColorImage an offscreen image (same format,
 *                         the write path this ICD honours), then vkCmdBlitImage
 *                         it into the acquired swapchain image (the MC path);
 *   clearColorImage     - vkCmdClearColorImage straight into the swapchain image.
 * Either way the swapchain image ends in PRESENT_SRC_KHR. No
 * renderPass/framebuffer/pipeline is needed.
 *
 * F31 adds a frame-sync variant (MEOW_VK_PROBE_SYNC): DEFAULT is a
 * VK_SEMAPHORE_TYPE_TIMELINE semaphore - each submit signals it to frame+1
 * (v1, v2, ... 64-bit) and then vkWaitSemaphores waits that value, recording
 * "tl=" (the MC path). MEOW_VK_PROBE_SYNC=binary keeps the legacy binary
 * semaphore + fence path. The fence is retained in BOTH variants and its wait
 * is recorded separately as "wf=" so the two waits can be told apart.
 *
 * F32 adds a library variant (MEOW_VK_PROBE_LIB): DEFAULT is "shim" - dlopen our
 * libmeowvulkan.so instead of /system/lib64/libvulkan.so, so the LAST difference
 * between this probe and MC (our shim's masquerade) is put on the table. The shim
 * only exports vkGetInstanceProcAddr / vkGetDeviceProcAddr (+ vkCreateInstance /
 * vkCreateDevice), so the probe loads entry points the canonical Vulkan way:
 * instance-level commands via the shim's vkGetInstanceProcAddr, device-level
 * commands via the shim's vkGetDeviceProcAddr. MEOW_VK_PROBE_LIB=raw restores the
 * pre-F32 direct-to-ICD path (unchanged). The report prints the value of the
 * shim's own switch env (MEOW_VK_SHIM) so a passthrough run is never mistaken
 * for an active shim. F34: in the SHIM variant the probe sets that switch itself
 * (setenv "MEOW_VK_SHIM"="1", overwrite) BEFORE it dlopen()s the shim or makes
 * the first call into it, so the user only has to press the button; the raw
 * variant never sets it. F36: in that same SHIM branch, right beside the setenv
 * above, the probe also sets MEOW_VK_STRIP_UNSUPPORTED_FEATURES=1 (overwrite),
 * before the first shim call (the shim reads both envs in the one init_once then),
 * and prints its was=/after values; the raw variant never sets it either.
 *
 * F33 adds a frame-SHAPE variant (MEOW_VK_PROBE_SHAPE): DEFAULT is "mc", which
 * reproduces the more complete command family MC submits every frame - KHR
 * dynamic rendering (vkCmdBeginRenderingKHR / vkCmdEndRenderingKHR on an
 * offscreen COLOR_ATTACHMENT image, layout GENERAL, loadOp CLEAR / storeOp
 * STORE), sync2 barriers (vkCmdPipelineBarrier2 + VkDependencyInfo /
 * VkImageMemoryBarrier2), a push-descriptor set layout + pipeline layout and one
 * vkCmdPushDescriptorSetKHR write, a vkCmdCopyBufferToImage upload into a 16x16
 * R8G8B8A8_UNORM image, and a 4-query TIMESTAMP pool written with
 * vkCmdWriteTimestamp2 every frame. The device enables VK_KHR_dynamic_rendering,
 * VK_KHR_synchronization2, VK_KHR_push_descriptor and
 * VK_EXT_vertex_attribute_divisor (with the matching feature bits through a
 * VkPhysicalDeviceFeatures2 chain). No SPIR-V / no graphics pipeline is needed.
 * MEOW_VK_PROBE_SHAPE=plain restores the pre-F33 minimal frame. The swapchain
 * blit, timeline semaphore, 120 frames, shim lib variant and teardown are
 * unchanged.
 *
 * F37 adds a submit-API variant (MEOW_VK_PROBE_SUBMIT): DEFAULT is "queue2",
 * which submits through vkQueueSubmit2 + VkSubmitInfo2 (MC's path -- resolved as
 * the core name first, the KHR alias if the ICD only exposes that) instead of the
 * v1 VkSubmitInfo / vkQueueSubmit. In shape=mc the frame is split into two submit
 * stages like MC: stage A carries the offscreen render command buffer (no
 * waits/signals); stage B waits the acquire binary semaphore, carries the blit
 * command buffer, and signals the present binary semaphore + the timeline
 * semaphore. MEOW_VK_PROBE_SUBMIT=v1 restores the pre-F37 v1 vkQueueSubmit path.
 * The fence wait ("wf=") and the timeline wait ("tl=") are both retained; the
 * report line names the active variant ("submit=queue2|v1").
 *
 * F38 turns the one-shot probe into a MATRIX driver: with NEITHER
 * MEOW_VK_PROBE_LIB NOR MEOW_VK_PROBE_SUBMIT set, one press runs all four cells
 * {shim,raw} x {v1,queue2} automatically (N=30 frames each) and prints one
 * compact line per cell plus a generated verdict. Every cell rebuilds its own
 * instance/surface/device/swapchain/... and tears them down before returning, so
 * a failure in one cell can never affect the next (an instance/device failure is
 * recorded as that cell's failure point and the next cell still runs). If either
 * of those two envs IS set, the probe runs a single cell using the user's values
 * exactly as before (env semantics preserved for manual runs). Each queue2 cell
 * prints the spelling it resolved ("vkQueueSubmit2" core vs "vkQueueSubmit2KHR").
 *
 * F39 fixes the two defects the on-device F38 matrix exposed:
 *  (1) the raw cells died at vkCreateDevice rc=-7 (EXTENSION_NOT_PRESENT). The
 *      probe hard-coded the five device extensions plus the divisor /
 *      dynamicRendering / synchronization2 feature chain, and the raw system ICD
 *      only advertises a subset (our shim was papering over that). The probe now
 *      calls vkEnumerateDeviceExtensionProperties and asks for only
 *      {VK_KHR_swapchain} + {the mc extensions that lib actually advertises}, and
 *      it enables only the feature bits the lib reports through
 *      vkGetPhysicalDeviceFeatures2. If an mc extension is missing, the cell runs
 *      a DEGRADED plain frame (core barriers + clear + blit, still
 *      pipeline=blitImage) instead of the mc command family, so it still reaches
 *      vkQueueSubmit2. raw and shim cells may therefore run with different
 *      capability sets; that is accepted and printed ("device caps:" /
 *      "frame=mc-degraded-plain"). If the feature-query entry point is absent the
 *      raw cells enable no extension features (avoid FEATURE_NOT_PRESENT) while
 *      the shim path keeps the pre-F39 "ask for the advertised ones" behaviour.
 *  (2) the F38 SUMMARY counted a SETUP FAIL cell as a submit failure (the raw
 *      cells never reached submit). The verdict now compares ONLY cells that set
 *      up AND actually issued >=1 submit call; every SETUP-FAIL / never-submitted
 *      cell is listed as "setup failed, submit not tested" and excluded, the
 *      participating cell numbers are printed, and when the comparison is
 *      inconclusive the SUMMARY says INSUFFICIENT INFO instead of guessing.
 *
 * F40 splits the mc SHAPE into independently switchable sub-shapes so one button
 * press can bisect which masqueraded feature makes frame 0 fail. Five envs, each
 * default ON: MEOW_VK_PROBE_MC_DR (vkCmdBeginRenderingKHR/EndRenderingKHR and the
 * offscreen view), MEOW_VK_PROBE_MC_PUSH (the push-descriptor layout and
 * vkCmdPushDescriptorSetKHR), MEOW_VK_PROBE_MC_UPLOAD (vkCmdCopyBufferToImage and
 * its 16x16 target image), MEOW_VK_PROBE_MC_TS (the TIMESTAMP query pool and every
 * vkCmdWriteTimestamp2), and MEOW_VK_PROBE_MC_DIV (the divisor feature bit at
 * device creation). "0" removes ONLY that item; the rest of the mc frame is
 * untouched. The F38/F39 lib x submit MATRIX is replaced by a SUB-SHAPE matrix
 * that runs ONLY lib=shim + submit=queue2 (the raw cells were not comparable,
 * F39): cell 1 is all-on (should reproduce the F37 frame-0 submit rc=-1), then
 * one cell per single item switched off (dr, push, div, upload, ts), 30 frames
 * each. Every cell rebuilds and tears down its own device / swapchain /
 * resources, so one failure cannot affect the next. Each cell prints its
 * effective sub-shape ("cell 2: dr=0 push=1 upload=1 ts=1 div=1") and the SUMMARY
 * is generated from the actual results (if no single-item removal fixed it, it
 * says INSUFFICIENT INFO instead of guessing). ONE necessary change rides along:
 * the sync2 feature is enabled for the shim whenever the extension is advertised
 * (the F37 gating), because the shim's feature-query hook synthesises
 * dynamicRendering and divisor but NOT synchronization2 -- the F39 query gate
 * would otherwise degrade every sub-shape cell to a plain frame (F39 measured
 * caps[sync2=0] frame=plain(degraded)), making the bisect impossible. raw keeps
 * the conservative F39 query gating; only the shim is affected.
 *
 * F41 adds a device-FEATURE policy axis (MEOW_VK_PROBE_DEVFEAT, three modes) on
 * top of the F40 mc shape. For the three feature-bit-bearing capabilities
 * (dynamicRendering / synchronization2 / vertex-attribute-divisor) it separates
 * the CAPABILITY VIEW (what the probe believes, prints as "caps", and uses to
 * decide frameMc) from the ENABLE SET (what is actually requested at
 * vkCreateDevice):
 *   real       - view = enable = the bits vkGetPhysicalDeviceFeatures2 reports
 *                (the F39 gate: only genuinely-available features are enabled);
 *   fake       - view = enable = derived from the advertised device extensions,
 *                ignoring the query (the F40 gate: advertised => enabled);
 *   fake-strip - view = advertised (the query masquerade: the capability LOOKS
 *                available, so the mc frame still runs) but enable = the
 *                query-reported bits only (the advertised-but-unreported bits are
 *                stripped at device creation -- the F35/F36 strip).
 * The F40 sub-shape matrix is replaced by a 3-cell DEVFEAT matrix that runs ONLY
 * lib=shim + submit=queue2 with shape=mc fully on (dr/push/upload/ts/div all 1),
 * 30 frames per cell, each cell building and tearing down its own device /
 * swapchain / resources so a failure cannot affect the next. Every cell prints
 * "devfeat=" plus the capability view ("caps[..]") and the actually-enabled
 * feature bits ("enabled[..]"); the SUMMARY is generated from the real per-cell
 * submit outcomes and says INSUFFICIENT INFO when it cannot conclude. Every
 * other axis (shape / pipeline / sync / q2 spelling / teardown / guards / env
 * semantics) is unchanged.
 *
 * F42 DECOUPLES the frame family from the feature set. F41 gated the WHOLE mc
 * frame on `viewDr && viewSync2 && push` (frameMc), so the F41 "real" policy
 * (shim: qrySync2=0) fell back to a plain frame and the "mc frame + features
 * not enabled" cell never actually ran. Now each mc item (DR / PUSH / UPLOAD /
 * TS / DIV) is decided on its own: it runs when its F40 sub-switch is ON and
 * the capability VIEW says the feature it needs is available, and a missing
 * item is SKIPPED instead of degrading the whole family. vkCmdWriteTimestamp2
 * is a synchronization2 command, so the TS item additionally requires
 * viewSync2 (the only item the F41 "real" policy cannot run). The mc frame's
 * sync2 barriers and vkQueueSubmit2 remain shared scaffolding (they are not one
 * of the five items). Every cell prints `ran[dr push up ts div]` next to the
 * capability view and the enable set. The F41 3-cell devfeat matrix is replaced
 * by a 4-cell matrix: {real per-item, fake per-item, fake with only the items
 * real could run, true plain control}; the third cell is the decision point.
 * The SUMMARY only compares cells whose device was really created (dev=0) and
 * which ran at least one mc item, prints the participating cell numbers, and
 * says INSUFFICIENT INFO when it cannot conclude. Every other axis (view/enable
 * semantics, shape/pipeline/sync/q2, teardown, guards, env semantics) is
 * unchanged.
 *
 * F43 turns the F42 per-item decoupling around: instead of REMOVING one mc item
 * from the full frame (F40's all-minus-one bisect), the default one-press matrix
 * now KEEPS ONLY ONE item at a time (the "one-item-only" matrix, the complement
 * of F40). The F40 sub-switches and the F42 per-item ran* logic are reused
 * unchanged: a cell is just an MC_* env combination plus the F42 devfeat policy,
 * and every cell runs lib=shim + submit=queue2 + devfeat=fake, 30 frames, with
 * its own instance/surface/device/swapchain/resources built and torn down so a
 * failure in one cell cannot leak into the next:
 *   cell 1  all five items on (baseline; should reproduce the frame-0 submit -1)
 *   cell 2  only DR           (mcDr=1; push/upload/ts/div off)
 *   cell 3  only PUSH
 *   cell 4  only UPLOAD
 *   cell 5  only DIV          (no mc command in the frame body at all; only the
 *                              divisor feature bit is requested at device creation)
 *   cell 6  only TS           (vkCmdWriteTimestamp2, needs viewSync2; when that
 *                              capability view is absent the item is skipped and
 *                              both the cell line and the SUMMARY say so)
 * Every cell prints enabled[..] + ran[..] (the F42 format) and its own
 * RESULT/FAIL/rc. The SHARED SCAFFOLDING of every mc cell is the per-frame sync2
 * layout barriers (vkCmdPipelineBarrier2) + the offscreen clear/blit into the
 * swapped image + the two-stage vkQueueSubmit2; it is identical in all cells and
 * is therefore a standing alternative explanation whenever all one-item cells
 * fail. The SUMMARY compares only cells whose device was really created (dev=0)
 * and that ran >=1 mc item, prints the participating cell numbers, and names
 * every comparable one-item cell whose submit came out OK (that single remaining
 * item did not by itself reproduce the -1) versus the ones that failed. The F42
 * four-cell semantics stay reachable through single-cell env runs.
 *
 * F44 adds two CONFIRMATION cells on top of the F43 six (the other six are
 * unchanged in shape, and are pinned to MEOW_VK_SYNC2_TO_V1=0 so they keep
 * reproducing the F43 baseline):
 *   cell 7  full mc shape + submit=v1 + the sync2 layout barriers  => OK (F33 repro)
 *   cell 8  full mc shape + submit=queue2 + sync2 barriers + MEOW_VK_SYNC2_TO_V1=1
 *           => OK if the shim's new synchronization2 -> core-1.0 translation works
 * The shim (meowvulkan.c, build .26) now translates vkQueueSubmit2 -> vkQueueSubmit and
 * vkCmdPipelineBarrier2 -> vkCmdPipelineBarrier whenever MEOW_VK_SYNC2_TO_V1 is on, which
 * is the DEFAULT whenever the shim hooks are on. The matrix therefore sets the switch
 * EXPLICITLY per cell: 0 for cells 1..7 (so cell 1 still reproduces the F43 -1) and 1 for
 * cell 8 (the cure). The SUMMARY prints cells 7/8 on their own and states whether the fix
 * is confirmed: cell 1 (translation OFF) FAILED while cell 8 (translation ON) OK means the
 * translation is the cure. Every new env/string is additive; the F43 six-cell semantics
 * remain reachable through single-cell env runs.
 *
 * F46 adds two MORE confirmation cells (9/10) to test whether the on-device -1 that
 * survives the sync2->v1 translation (cell 8) is tied to the TIMELINE SEMAPHORE VALUE
 * that F44 chains through VkTimelineSemaphoreSubmitInfo:
 *   cell 9  full mc shape + submit=queue2 + MEOW_VK_SYNC2_TO_V1=1 + sync=BINARY. No
 *           timeline semaphore exists at all, so the probe's VkSubmitInfo2 carries only
 *           binary semaphores (value 0) and the shim's translated VkSubmitInfo has no
 *           timeline value to chain.
 *   cell 10 full mc shape + submit=v1 + sync=timeline: native v1 + timeline, the explicit
 *           control adjacent to cell 7 (equal to it by construction).
 * MEOW_VK_PROBE_SYNC is promoted to a per-cell matrix axis (timeline for cells 1..8 and
 * 10, binary for cell 9) and is set right beside MEOW_VK_SYNC2_TO_V1, before probe_run_one
 * and therefore before the shim is dlopen()ed / first called (the ordering both env reads
 * require). Reading:
 *   cell 8 FAILED + cell 9 OK    => the -1 tracks the timeline VALUE the translation
 *                                   carries (binary passes)
 *   cell 8 FAILED + cell 9 FAILED => binary sync does not help; not (only) the timeline value
 *   cell 10 OK corroborates that native v1 + timeline is fine (cell 7 control)
 * Every new env/string is additive; the 8-cell F44 semantics stay reachable by single-cell
 * env runs.
 *
 * F52 adds a TEXTURED item (MEOW_VK_PROBE_TEXTURED, default ON) -- the sixth member of
 * the mc family beside DR / PUSH / UPLOAD / TS / DIV. When it runs, the frame creates a
 * 64x64 R8G8B8A8_UNORM SAMPLED|TRANSFER_DST image plus a vkCreateSampler and an image
 * view, fills a HOST_VISIBLE|HOST_COHERENT TRANSFER_SRC source buffer from the CPU
 * (vkMapMemory), uploads it with vkCmdCopyBufferToImage (UNDEFINED ->
 * TRANSFER_DST_OPTIMAL, then -> GENERAL, MC's sampled layout) and pushes a
 * COMBINED_IMAGE_SAMPLER descriptor (binding 1) through the existing push-descriptor
 * pipeline layout. The default one-press matrix gains an "only TEX" cell (13) and every
 * all-on cell carries the item. NO vkCmdDraw is added: this probe has no graphics
 * pipeline / SPIR-V at all, so the textured item stops at create + upload + descriptor
 * push (a real textured draw would require a full pipeline, which F33 deliberately
 * avoided and this task explicitly does not require). The upload is the command under
 * suspicion -- the in-tree record says vkCmdCopyBufferToImage SIGSEGVs on this ICD.
 *
 * F63 adds a frame submit/present PATTERN (MEOW_VK_PROBE_PATTERN=mc|own, default
 * mc) that replicates MC 26.2's per-frame shape so the "acquire stalls ~1 s then
 * rc=-4" symptom can be reproduced without MC. The mc pattern runs one
 * vkQueueSubmit2 carrying TWO VkSubmitInfo2 entries (entry[0] = render CB, no
 * waits/signals; entry[1] waits the acquire binary semaphore, runs the blit CB
 * and signals the present binary + the timeline semaphore to an increasing
 * value), submits with fence=NULL, then presents, then waits the timeline for
 * the PREVIOUS submitted value (the probe's lax equivalent of MC's v-2 wait;
 * the value just submitted is v=f+1, the wait target is v-1=f). Two
 * command-buffer pairs alternate (f&1) so two submits stay in flight while each
 * pair is reused only after its own frame completed. The default one-press
 * matrix gains PATTERN cells 14 (mc) and 15 (own control), all-on, 60 frames,
 * each built/torn down independently, and each prints per-frame telemetry:
 * acquire dtMs, imageIndex, submit/present/timelineWait rc and the cumulative
 * acquire/present counts (to spot images that are never returned).
 * MEOW_VK_PROBE_PATTERN=own keeps the pre-F63 behaviour; cells 1..13 are pinned
 * to own and remain byte-identical.
 *
 * SELF-CONTAINED: no SDK vulkan header is included. Every struct / sType /
 * enum below mirrors the authoritative vulkan_core.h layout for LP64, with
 * _Static_assert guards (same approach as egl_gl.c / meowvulkan.c).
 *
 * EARLY-EXIT GUARD: every dlsym / getProcAddr result is null-checked. Any missing
 * required entry point, a NULL window, or any setup failure returns immediately
 * and writes the reason into the result string; nothing is ever called through
 * a NULL pointer (the launcher has been crashed by that before).
 *
 * CLEANUP: swapchain, image views, device, surface and instance are destroyed on
 * every exit path, and the OHNativeWindow created from the surface id is
 * released. Window geometry / format / usage are NEVER written (read-only probe),
 * so a later normal game launch is unaffected.
 *
 * The NAPI wrappers live in meowjrebridge.cpp; this file exposes only the two
 * plain-C entry points below (compiled as C, so the symbols are already C).
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <native_window/external_window.h>

/* ------------------------------------------------------------------ */
/* sType values (vulkan_core.h)                                        */
/* ------------------------------------------------------------------ */
#define VK_ST_APPLICATION_INFO 0u
#define VK_ST_INSTANCE_CREATE_INFO 1u
#define VK_ST_DEVICE_QUEUE_CREATE_INFO 2u
#define VK_ST_DEVICE_CREATE_INFO 3u
#define VK_ST_SUBMIT_INFO 4u
#define VK_ST_MEMORY_ALLOCATE_INFO 5u
#define VK_ST_FENCE_CREATE_INFO 8u
#define VK_ST_SEMAPHORE_CREATE_INFO 9u
#define VK_ST_SEMAPHORE_TYPE_CREATE_INFO 1000207002u
#define VK_ST_TIMELINE_SEMAPHORE_SUBMIT_INFO 1000207003u
#define VK_ST_SEMAPHORE_WAIT_INFO 1000207004u
#define VK_ST_IMAGE_CREATE_INFO 14u
#define VK_ST_IMAGE_VIEW_CREATE_INFO 15u
#define VK_ST_COMMAND_POOL_CREATE_INFO 39u
#define VK_ST_COMMAND_BUFFER_ALLOCATE_INFO 40u
#define VK_ST_COMMAND_BUFFER_BEGIN_INFO 42u
#define VK_ST_IMAGE_MEMORY_BARRIER 45u
#define VK_ST_SWAPCHAIN_CREATE_INFO_KHR 1000001000u
#define VK_ST_PRESENT_INFO_KHR 1000001002u
#define VK_ST_SURFACE_CREATE_INFO_OHOS 1000685000u /* vulkan_core.h (OHOS platform ext) */
/* F33 (shape=mc): sTypes for the MC command family, each read from
 * ref/lwjgl3/.../vulkan_core.h (VK_HEADER_VERSION 361); see the F33 report. */
#define VK_ST_QUERY_POOL_CREATE_INFO 11u
#define VK_ST_BUFFER_CREATE_INFO 12u
#define VK_ST_PIPELINE_LAYOUT_CREATE_INFO 30u
#define VK_ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO 32u
#define VK_ST_WRITE_DESCRIPTOR_SET 35u
#define VK_ST_PHYSICAL_DEVICE_FEATURES_2 1000059000u
#define VK_ST_RENDERING_INFO_KHR 1000044000u            /* == ..._RENDERING_INFO */
#define VK_ST_RENDERING_ATTACHMENT_INFO_KHR 1000044001u /* == ..._ATTACHMENT_INFO */
#define VK_ST_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES 1000044003u
#define VK_ST_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT 1000190002u
#define VK_ST_IMAGE_MEMORY_BARRIER_2 1000314002u
#define VK_ST_DEPENDENCY_INFO 1000314003u
#define VK_ST_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES 1000314007u
/* F37 (submit=queue2): sync2 submit structs, each read from
 * ref/lwjgl3/.../vulkan_core.h (vulkan_core.h:381-383, structs :7581-:7607). */
#define VK_ST_SUBMIT_INFO_2 1000314004u
#define VK_ST_SEMAPHORE_SUBMIT_INFO 1000314005u
#define VK_ST_COMMAND_BUFFER_SUBMIT_INFO 1000314006u
/* F52 (textured item): sampler create info, read from
 * ref/lwjgl3/.../vulkan_core.h:238 (VK_HEADER_VERSION 361). */
#define VK_ST_SAMPLER_CREATE_INFO 31u

/* ------------------------------------------------------------------ */
/* Result codes                                                        */
/* ------------------------------------------------------------------ */
#define VK_OK 0
#define VK_NOT_READY 1
#define VK_TIMEOUT 2
#define VK_SUBOPTIMAL_KHR 1000001003
#define VK_ERROR_DEVICE_LOST (-4)
/* F38: negative VkResult names printed by rc_name. Values read from
 * ref/lwjgl3/.../vulkan_core.h:147-155 (VK_HEADER_VERSION 361). */
#define VK_ERROR_OUT_OF_HOST_MEMORY (-1)
#define VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)
#define VK_ERROR_INITIALIZATION_FAILED (-3)
#define VK_ERROR_MEMORY_MAP_FAILED (-5)
#define VK_ERROR_LAYER_NOT_PRESENT (-6)
#define VK_ERROR_EXTENSION_NOT_PRESENT (-7)
#define VK_ERROR_FEATURE_NOT_PRESENT (-8)
#define VK_ERROR_INCOMPATIBLE_DRIVER (-9)

/* F39: VK_MAX_EXTENSION_NAME_SIZE (vulkan_core.h:134) and the extension NAME
 * strings this probe queries / compares (the header's *_EXTENSION_NAME values:
 * vulkan_core.h:9066, :10289, :12402, :10698, :18239). */
#define VK_MAX_EXTENSION_NAME_SIZE 256u
#define MEOW_VK_EXT_SWAPCHAIN "VK_KHR_swapchain"
#define MEOW_VK_EXT_DYNAMIC_RENDERING "VK_KHR_dynamic_rendering"
#define MEOW_VK_EXT_SYNCHRONIZATION2 "VK_KHR_synchronization2"
#define MEOW_VK_EXT_PUSH_DESCRIPTOR "VK_KHR_push_descriptor"
#define MEOW_VK_EXT_VERTEX_ATTRIBUTE_DIVISOR "VK_EXT_vertex_attribute_divisor"

/* ------------------------------------------------------------------ */
/* Enums / flags                                                       */
/* ------------------------------------------------------------------ */
#define VK_API_VERSION_1_0 0x00400000u

#define VK_QUEUE_GRAPHICS_BIT 0x00000001u

#define VK_IMAGE_USAGE_TRANSFER_SRC_BIT 0x00000001u
#define VK_IMAGE_USAGE_TRANSFER_DST_BIT 0x00000002u
#define VK_IMAGE_USAGE_SAMPLED_BIT 0x00000004u /* F52: sampled texture */
#define VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT 0x00000010u

#define VK_SHARING_MODE_EXCLUSIVE 0

#define VK_SEMAPHORE_TYPE_BINARY 0
#define VK_SEMAPHORE_TYPE_TIMELINE 1

/* F31: finite bound on the CPU timeline wait so the probe ALWAYS records an rc
 * (an unbounded wait on a wedged timeline would leave the probe thread stuck). */
#define MEOW_VK_PROBE_TL_WAIT_NS 5000000000ull

/* F63 (MEOW_VK_PROBE_PATTERN): the MC submit/present pattern records one sample
 * per frame; this bounds the per-cell sample arrays. The pattern cells run N=60. */
#define MEOW_VK_PROBE_PAT_FRAMES 64

/* F32: fallback on-device location of our shim. HSP native libs install under
 * <bundleCodeDir>/<hsp>/libs/<abi>; meowcraftlib is a HAR whose natives ship
 * inside the meowjre HSP (meowjrebridge.cpp:601 "ships in the same meowjre libs
 * dir"), and Paths.ets:HSP_LIBS_SUBPATH is "libs/arm64". dlopen() by soname is
 * tried FIRST; this absolute path is the fallback, never a guess chain. */
#define MEOW_VK_PROBE_SHIM_SONAME "libmeowvulkan.so"
#define MEOW_VK_PROBE_SHIM_PATH "/data/storage/el1/bundle/meowjre/libs/arm64/libmeowvulkan.so"

#define VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR 0x00000001u
#define VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR 0x00000002u
#define VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR 0x00000004u
#define VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR 0x00000008u

#define VK_PRESENT_MODE_FIFO_KHR 2

#define VK_IMAGE_LAYOUT_UNDEFINED 0
#define VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL 6
#define VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 7
#define VK_IMAGE_LAYOUT_PRESENT_SRC_KHR 1000001002

#define VK_IMAGE_TYPE_2D 1
#define VK_IMAGE_TILING_OPTIMAL 0
#define VK_SAMPLE_COUNT_1_BIT 0x00000001u
#define VK_FILTER_NEAREST 0
/* F52 (textured item): sampler enums, vulkan_core.h:2378 / :2399. */
#define VK_SAMPLER_MIPMAP_MODE_NEAREST 0
#define VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE 2

#define VK_IMAGE_VIEW_TYPE_2D 1
#define VK_IMAGE_ASPECT_COLOR_BIT 0x00000001u
#define VK_COMPONENT_SWIZZLE_IDENTITY 0

#define VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT 0x00000001u
#define VK_PIPELINE_STAGE_TRANSFER_BIT 0x00001000u
#define VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT 0x00002000u

#define VK_ACCESS_TRANSFER_READ_BIT 0x00000800u
#define VK_ACCESS_TRANSFER_WRITE_BIT 0x00001000u
#define VK_ACCESS_MEMORY_READ_BIT 0x00008000u

#define VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT 0x00000001u
#define VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT 0x00000002u  /* F52: CPU-written staging */
#define VK_MEMORY_PROPERTY_HOST_COHERENT_BIT 0x00000004u /* F52: no flush needed */
#define VK_MAX_MEMORY_TYPES 32u
#define VK_MAX_MEMORY_HEAPS 16u

#define VK_COMMAND_BUFFER_LEVEL_PRIMARY 0
#define VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT 0x00000001u
#define VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT 0x00000002u
#define VK_FENCE_CREATE_SIGNALED_BIT 0x00000001u

#define VK_FORMAT_UNDEFINED 0
#define VK_FORMAT_R8G8B8A8_UNORM 37
#define VK_FORMAT_B8G8R8A8_UNORM 44

#define VK_TRUE 1u

/* F33 (shape=mc): layout / attachment / query / descriptor / sync2 values.
 * Each mirrors vulkan_core.h (VK_HEADER_VERSION 361). */
#define VK_IMAGE_LAYOUT_GENERAL 1
#define VK_ATTACHMENT_LOAD_OP_CLEAR 1
#define VK_ATTACHMENT_STORE_OP_STORE 0
#define VK_QUERY_TYPE_TIMESTAMP 2
#define VK_BUFFER_USAGE_TRANSFER_SRC_BIT 0x00000001u
#define VK_BUFFER_USAGE_STORAGE_BUFFER_BIT 0x00000020u
#define VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 7
#define VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1 /* F52: vulkan_core.h:2406 */
#define VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR 0x00000001u
#define VK_PIPELINE_BIND_POINT_GRAPHICS 0
#define VK_SHADER_STAGE_ALL_GRAPHICS 0x0000001Fu

#define VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT 0x00000001ull
#define VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT 0x00000400ull
#define VK_PIPELINE_STAGE_2_TRANSFER_BIT 0x00001000ull
#define VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT 0x00002000ull
#define VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT 0x00010000ull
#define VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT 0x00000100ull
#define VK_ACCESS_2_TRANSFER_READ_BIT 0x00000800ull
#define VK_ACCESS_2_TRANSFER_WRITE_BIT 0x00001000ull
#define VK_ACCESS_2_MEMORY_READ_BIT 0x00008000ull

/* shape=mc upload: a 16x16 R8G8B8A8_UNORM buffer->image copy (MC's only
 * texture-upload entry point) and a >=4-query timestamp pool. */
#define MEOW_VK_PROBE_UPLOAD_EXTENT 16u
#define MEOW_VK_PROBE_UPLOAD_QUERIES 4u
/* F52 textured item: a 64x64 R8G8B8A8_UNORM sampled texture uploaded with
 * vkCmdCopyBufferToImage from a CPU-written HOST_VISIBLE source buffer. */
#define MEOW_VK_PROBE_TEX_EXTENT 64u

/* F41 device-feature policy modes (MEOW_VK_PROBE_DEVFEAT). */
#define MEOW_VK_DEVFEAT_REAL 0
#define MEOW_VK_DEVFEAT_FAKE 1
#define MEOW_VK_DEVFEAT_FAKE_STRIP 2

/* ------------------------------------------------------------------ */
/* Struct mirrors (LP64). All asserted below.                          */
/* ------------------------------------------------------------------ */
typedef struct {
    uint32_t sType;
    const void* pNext;
    const char* pApplicationName;
    uint32_t applicationVersion;
    const char* pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} MeowVkApplicationInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    const MeowVkApplicationInfo* pApplicationInfo;
    uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames;
} MeowVkInstanceCreateInfo;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t depth;
} MeowVkExtent3D;

typedef struct {
    uint32_t queueFlags;
    uint32_t queueCount;
    uint32_t timestampValidBits;
    MeowVkExtent3D minImageTransferGranularity;
} MeowVkQueueFamilyProperties;

typedef struct {
    uint32_t minImageCount;
    uint32_t maxImageCount;
    uint32_t currentExtentW;
    uint32_t currentExtentH;
    uint32_t minImageExtentW;
    uint32_t minImageExtentH;
    uint32_t maxImageExtentW;
    uint32_t maxImageExtentH;
    uint32_t maxImageArrayLayers;
    uint32_t supportedTransforms;
    uint32_t currentTransform;
    uint32_t supportedCompositeAlpha;
    uint32_t supportedUsageFlags;
} MeowVkSurfaceCapabilitiesKHR;

typedef struct {
    int32_t format;
    int32_t colorSpace;
} MeowVkSurfaceFormatKHR;

/* F39: VkExtensionProperties (vulkan_core.h:3746-3749), LP64. */
typedef struct {
    char extensionName[VK_MAX_EXTENSION_NAME_SIZE];
    uint32_t specVersion;
} MeowVkExtensionProperties;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t queueFamilyIndex;
    uint32_t queueCount;
    const float* pQueuePriorities;
} MeowVkDeviceQueueCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t queueCreateInfoCount;
    const MeowVkDeviceQueueCreateInfo* pQueueCreateInfos;
    uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames;
    const void* pEnabledFeatures;
} MeowVkDeviceCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    void* window;
} MeowVkSurfaceCreateInfoOHOS;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint64_t surface;
    uint32_t minImageCount;
    int32_t imageFormat;
    int32_t imageColorSpace;
    uint32_t extentW;
    uint32_t extentH;
    uint32_t imageArrayLayers;
    uint32_t imageUsage;
    int32_t imageSharingMode;
    uint32_t queueFamilyIndexCount;
    const void* pQueueFamilyIndices;
    int32_t preTransform;
    int32_t compositeAlpha;
    int32_t presentMode;
    uint32_t clipped;
    uint64_t oldSwapchain;
} MeowVkSwapchainCreateInfoKHR;

typedef struct {
    uint32_t aspectMask;
    uint32_t baseMipLevel;
    uint32_t levelCount;
    uint32_t baseArrayLayer;
    uint32_t layerCount;
} MeowVkImageSubresourceRange;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint64_t image;
    int32_t viewType;
    int32_t format;
    int32_t r;
    int32_t g;
    int32_t b;
    int32_t a;
    MeowVkImageSubresourceRange subresourceRange;
} MeowVkImageViewCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t queueFamilyIndex;
} MeowVkCommandPoolCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t commandPool;
    int32_t level;
    uint32_t commandBufferCount;
} MeowVkCommandBufferAllocateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    const void* pInheritanceInfo;
} MeowVkCommandBufferBeginInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t srcAccessMask;
    uint32_t dstAccessMask;
    int32_t oldLayout;
    int32_t newLayout;
    uint32_t srcQueueFamilyIndex;
    uint32_t dstQueueFamilyIndex;
    uint64_t image;
    MeowVkImageSubresourceRange subresourceRange;
} MeowVkImageMemoryBarrier;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
} MeowVkSemaphoreCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    int32_t semaphoreType;
    uint64_t initialValue;
} MeowVkSemaphoreTypeCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t waitSemaphoreValueCount;
    const uint64_t* pWaitSemaphoreValues;
    uint32_t signalSemaphoreValueCount;
    const uint64_t* pSignalSemaphoreValues;
} MeowVkTimelineSemaphoreSubmitInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t semaphoreCount;
    const uint64_t* pSemaphores;
    const uint64_t* pValues;
} MeowVkSemaphoreWaitInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
} MeowVkFenceCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t waitSemaphoreCount;
    const uint64_t* pWaitSemaphores;
    const uint32_t* pWaitDstStageMask;
    uint32_t commandBufferCount;
    const uint64_t* pCommandBuffers;
    uint32_t signalSemaphoreCount;
    const uint64_t* pSignalSemaphores;
} MeowVkSubmitInfo;

/* F37: synchronization2 submit structs (vulkan_core.h:7581-:7607). Field order
 * and LP64 padding verified against the header, asserted below. */
typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t semaphore;
    uint64_t value;
    uint64_t stageMask;
    uint32_t deviceIndex;
} MeowVkSemaphoreSubmitInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t commandBuffer;
    uint32_t deviceMask;
} MeowVkCommandBufferSubmitInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t waitSemaphoreInfoCount;
    const MeowVkSemaphoreSubmitInfo* pWaitSemaphoreInfos;
    uint32_t commandBufferInfoCount;
    const MeowVkCommandBufferSubmitInfo* pCommandBufferInfos;
    uint32_t signalSemaphoreInfoCount;
    const MeowVkSemaphoreSubmitInfo* pSignalSemaphoreInfos;
} MeowVkSubmitInfo2;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t waitSemaphoreCount;
    const uint64_t* pWaitSemaphores;
    uint32_t swapchainCount;
    const uint64_t* pSwapchains;
    const uint32_t* pImageIndices;
    int32_t* pResults;
} MeowVkPresentInfoKHR;

typedef struct {
    float r;
    float g;
    float b;
    float a;
} MeowVkClearColorValue;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    int32_t imageType;
    int32_t format;
    MeowVkExtent3D extent;
    uint32_t mipLevels;
    uint32_t arrayLayers;
    uint32_t samples;
    int32_t tiling;
    uint32_t usage;
    int32_t sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
    int32_t initialLayout;
} MeowVkImageCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t allocationSize;
    uint32_t memoryTypeIndex;
} MeowVkMemoryAllocateInfo;

typedef struct {
    uint64_t size;
    uint64_t alignment;
    uint32_t memoryTypeBits;
} MeowVkMemoryRequirements;

typedef struct {
    uint32_t propertyFlags;
    uint32_t heapIndex;
} MeowVkMemoryType;

typedef struct {
    uint64_t size;
    uint32_t flags;
} MeowVkMemoryHeap;

typedef struct {
    uint32_t memoryTypeCount;
    MeowVkMemoryType memoryTypes[VK_MAX_MEMORY_TYPES];
    uint32_t memoryHeapCount;
    MeowVkMemoryHeap memoryHeaps[VK_MAX_MEMORY_HEAPS];
} MeowVkPhysicalDeviceMemoryProperties;

typedef struct {
    uint32_t aspectMask;
    uint32_t mipLevel;
    uint32_t baseArrayLayer;
    uint32_t layerCount;
} MeowVkImageSubresourceLayers;

typedef struct {
    int32_t x;
    int32_t y;
    int32_t z;
} MeowVkOffset3D;

typedef struct {
    MeowVkImageSubresourceLayers srcSubresource;
    MeowVkOffset3D srcOffsets[2];
    MeowVkImageSubresourceLayers dstSubresource;
    MeowVkOffset3D dstOffsets[2];
} MeowVkImageBlit;

/* ------------------------------------------------------------------ */
/* F33 (shape=mc) struct mirrors (LP64). All asserted below.           */
/* ------------------------------------------------------------------ */
typedef struct {
    int32_t x;
    int32_t y;
} MeowVkOffset2D;

typedef struct {
    uint32_t width;
    uint32_t height;
} MeowVkExtent2D;

typedef struct {
    MeowVkOffset2D offset;
    MeowVkExtent2D extent;
} MeowVkRect2D;

typedef struct {
    float depth;
    uint32_t stencil;
} MeowVkClearDepthStencilValue;

typedef union {
    MeowVkClearColorValue color;
    MeowVkClearDepthStencilValue depthStencil;
} MeowVkClearValue;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t imageView;
    int32_t imageLayout;
    int32_t resolveMode;
    uint64_t resolveImageView;
    int32_t resolveImageLayout;
    int32_t loadOp;
    int32_t storeOp;
    MeowVkClearValue clearValue;
} MeowVkRenderingAttachmentInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    MeowVkRect2D renderArea;
    uint32_t layerCount;
    uint32_t viewMask;
    uint32_t colorAttachmentCount;
    const MeowVkRenderingAttachmentInfo* pColorAttachments;
    const MeowVkRenderingAttachmentInfo* pDepthAttachment;
    const MeowVkRenderingAttachmentInfo* pStencilAttachment;
} MeowVkRenderingInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t srcStageMask;
    uint64_t srcAccessMask;
    uint64_t dstStageMask;
    uint64_t dstAccessMask;
    int32_t oldLayout;
    int32_t newLayout;
    uint32_t srcQueueFamilyIndex;
    uint32_t dstQueueFamilyIndex;
    uint64_t image;
    MeowVkImageSubresourceRange subresourceRange;
} MeowVkImageMemoryBarrier2;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t dependencyFlags;
    uint32_t memoryBarrierCount;
    const void* pMemoryBarriers;
    uint32_t bufferMemoryBarrierCount;
    const void* pBufferMemoryBarriers;
    uint32_t imageMemoryBarrierCount;
    const MeowVkImageMemoryBarrier2* pImageMemoryBarriers;
} MeowVkDependencyInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t features[55]; /* VkPhysicalDeviceFeatures: 55 VkBool32 fields */
} MeowVkPhysicalDeviceFeatures2;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t vertexAttributeInstanceRateDivisor;
    uint32_t vertexAttributeInstanceRateZeroDivisor;
} MeowVkPhysicalDeviceVertexAttributeDivisorFeaturesEXT;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t dynamicRendering;
} MeowVkPhysicalDeviceDynamicRenderingFeatures;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t synchronization2;
} MeowVkPhysicalDeviceSynchronization2Features;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    int32_t queryType;
    uint32_t queryCount;
    uint32_t pipelineStatistics;
} MeowVkQueryPoolCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint64_t size;
    uint32_t usage;
    int32_t sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
} MeowVkBufferCreateInfo;

typedef struct {
    uint64_t bufferOffset;
    uint32_t bufferRowLength;
    uint32_t bufferImageHeight;
    MeowVkImageSubresourceLayers imageSubresource;
    MeowVkOffset3D imageOffset;
    MeowVkExtent3D imageExtent;
} MeowVkBufferImageCopy;

typedef struct {
    uint64_t buffer;
    uint64_t offset;
    uint64_t range;
} MeowVkDescriptorBufferInfo;

typedef struct {
    uint32_t binding;
    int32_t descriptorType;
    uint32_t descriptorCount;
    uint32_t stageFlags;
    const void* pImmutableSamplers;
} MeowVkDescriptorSetLayoutBinding;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t bindingCount;
    const MeowVkDescriptorSetLayoutBinding* pBindings;
} MeowVkDescriptorSetLayoutCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    uint32_t setLayoutCount;
    const uint64_t* pSetLayouts;
    uint32_t pushConstantRangeCount;
    const void* pPushConstantRanges;
} MeowVkPipelineLayoutCreateInfo;

typedef struct {
    uint32_t sType;
    const void* pNext;
    uint64_t dstSet;
    uint32_t dstBinding;
    uint32_t dstArrayElement;
    uint32_t descriptorCount;
    int32_t descriptorType;
    const void* pImageInfo;
    const MeowVkDescriptorBufferInfo* pBufferInfo;
    const void* pTexelBufferView;
} MeowVkWriteDescriptorSet;

/* F52 (textured item) struct mirrors (LP64), asserted below.
 * VkSamplerCreateInfo: vulkan_core.h:4135-4154; VkDescriptorImageInfo: :4174-4178. */
typedef struct {
    uint32_t sType;
    const void* pNext;
    uint32_t flags;
    int32_t magFilter;
    int32_t minFilter;
    int32_t mipmapMode;
    int32_t addressModeU;
    int32_t addressModeV;
    int32_t addressModeW;
    float mipLodBias;
    uint32_t anisotropyEnable;
    float maxAnisotropy;
    uint32_t compareEnable;
    int32_t compareOp;
    float minLod;
    float maxLod;
    int32_t borderColor;
    uint32_t unnormalizedCoordinates;
} MeowVkSamplerCreateInfo;

typedef struct {
    uint64_t sampler;
    uint64_t imageView;
    int32_t imageLayout;
} MeowVkDescriptorImageInfo;

_Static_assert(sizeof(MeowVkApplicationInfo) == 48, "VkApplicationInfo size");
_Static_assert(sizeof(MeowVkInstanceCreateInfo) == 64, "VkInstanceCreateInfo size");
_Static_assert(sizeof(MeowVkQueueFamilyProperties) == 24, "VkQueueFamilyProperties size");
_Static_assert(sizeof(MeowVkSurfaceCapabilitiesKHR) == 52, "VkSurfaceCapabilitiesKHR size");
_Static_assert(sizeof(MeowVkSurfaceFormatKHR) == 8, "VkSurfaceFormatKHR size");
_Static_assert(sizeof(MeowVkExtensionProperties) == 260, "VkExtensionProperties size");
_Static_assert(sizeof(MeowVkDeviceQueueCreateInfo) == 40, "VkDeviceQueueCreateInfo size");
_Static_assert(sizeof(MeowVkDeviceCreateInfo) == 72, "VkDeviceCreateInfo size");
_Static_assert(sizeof(MeowVkSurfaceCreateInfoOHOS) == 32, "VkSurfaceCreateInfoOHOS size");
_Static_assert(sizeof(MeowVkSwapchainCreateInfoKHR) == 104, "VkSwapchainCreateInfoKHR size");
_Static_assert(sizeof(MeowVkImageViewCreateInfo) == 80, "VkImageViewCreateInfo size");
_Static_assert(sizeof(MeowVkCommandPoolCreateInfo) == 24, "VkCommandPoolCreateInfo size");
_Static_assert(sizeof(MeowVkCommandBufferAllocateInfo) == 32, "VkCommandBufferAllocateInfo size");
_Static_assert(sizeof(MeowVkCommandBufferBeginInfo) == 32, "VkCommandBufferBeginInfo size");
_Static_assert(sizeof(MeowVkImageMemoryBarrier) == 72, "VkImageMemoryBarrier size");
_Static_assert(sizeof(MeowVkSemaphoreCreateInfo) == 24, "VkSemaphoreCreateInfo size");
_Static_assert(sizeof(MeowVkSemaphoreTypeCreateInfo) == 32, "VkSemaphoreTypeCreateInfo size");
_Static_assert(sizeof(MeowVkTimelineSemaphoreSubmitInfo) == 48,
               "VkTimelineSemaphoreSubmitInfo size");
_Static_assert(sizeof(MeowVkSemaphoreWaitInfo) == 40, "VkSemaphoreWaitInfo size");
_Static_assert(offsetof(MeowVkSemaphoreTypeCreateInfo, semaphoreType) == 16,
               "VkSemaphoreTypeCreateInfo.semaphoreType @16");
_Static_assert(offsetof(MeowVkSemaphoreTypeCreateInfo, initialValue) == 24,
               "VkSemaphoreTypeCreateInfo.initialValue @24");
_Static_assert(offsetof(MeowVkTimelineSemaphoreSubmitInfo, pWaitSemaphoreValues) == 24,
               "VkTimelineSemaphoreSubmitInfo.pWaitSemaphoreValues @24");
_Static_assert(offsetof(MeowVkTimelineSemaphoreSubmitInfo, pSignalSemaphoreValues) == 40,
               "VkTimelineSemaphoreSubmitInfo.pSignalSemaphoreValues @40");
_Static_assert(offsetof(MeowVkSemaphoreWaitInfo, semaphoreCount) == 20,
               "VkSemaphoreWaitInfo.semaphoreCount @20");
_Static_assert(offsetof(MeowVkSemaphoreWaitInfo, pSemaphores) == 24,
               "VkSemaphoreWaitInfo.pSemaphores @24");
_Static_assert(offsetof(MeowVkSemaphoreWaitInfo, pValues) == 32,
               "VkSemaphoreWaitInfo.pValues @32");
_Static_assert(sizeof(MeowVkFenceCreateInfo) == 24, "VkFenceCreateInfo size");
_Static_assert(sizeof(MeowVkSubmitInfo) == 72, "VkSubmitInfo size");
/* F37 (submit=queue2) sizes / offsets, LP64. */
_Static_assert(sizeof(MeowVkSemaphoreSubmitInfo) == 48, "VkSemaphoreSubmitInfo size");
_Static_assert(offsetof(MeowVkSemaphoreSubmitInfo, semaphore) == 16,
               "VkSemaphoreSubmitInfo.semaphore @16");
_Static_assert(offsetof(MeowVkSemaphoreSubmitInfo, value) == 24,
               "VkSemaphoreSubmitInfo.value @24");
_Static_assert(offsetof(MeowVkSemaphoreSubmitInfo, stageMask) == 32,
               "VkSemaphoreSubmitInfo.stageMask @32");
_Static_assert(offsetof(MeowVkSemaphoreSubmitInfo, deviceIndex) == 40,
               "VkSemaphoreSubmitInfo.deviceIndex @40");
_Static_assert(sizeof(MeowVkCommandBufferSubmitInfo) == 32, "VkCommandBufferSubmitInfo size");
_Static_assert(offsetof(MeowVkCommandBufferSubmitInfo, commandBuffer) == 16,
               "VkCommandBufferSubmitInfo.commandBuffer @16");
_Static_assert(offsetof(MeowVkCommandBufferSubmitInfo, deviceMask) == 24,
               "VkCommandBufferSubmitInfo.deviceMask @24");
_Static_assert(sizeof(MeowVkSubmitInfo2) == 64, "VkSubmitInfo2 size");
_Static_assert(offsetof(MeowVkSubmitInfo2, flags) == 16, "VkSubmitInfo2.flags @16");
_Static_assert(offsetof(MeowVkSubmitInfo2, waitSemaphoreInfoCount) == 20,
               "VkSubmitInfo2.waitSemaphoreInfoCount @20");
_Static_assert(offsetof(MeowVkSubmitInfo2, pWaitSemaphoreInfos) == 24,
               "VkSubmitInfo2.pWaitSemaphoreInfos @24");
_Static_assert(offsetof(MeowVkSubmitInfo2, commandBufferInfoCount) == 32,
               "VkSubmitInfo2.commandBufferInfoCount @32");
_Static_assert(offsetof(MeowVkSubmitInfo2, pCommandBufferInfos) == 40,
               "VkSubmitInfo2.pCommandBufferInfos @40");
_Static_assert(offsetof(MeowVkSubmitInfo2, signalSemaphoreInfoCount) == 48,
               "VkSubmitInfo2.signalSemaphoreInfoCount @48");
_Static_assert(offsetof(MeowVkSubmitInfo2, pSignalSemaphoreInfos) == 56,
               "VkSubmitInfo2.pSignalSemaphoreInfos @56");
_Static_assert(sizeof(MeowVkPresentInfoKHR) == 64, "VkPresentInfoKHR size");
_Static_assert(sizeof(MeowVkImageSubresourceRange) == 20, "VkImageSubresourceRange size");
_Static_assert(sizeof(MeowVkClearColorValue) == 16, "VkClearColorValue size");
_Static_assert(sizeof(MeowVkImageCreateInfo) == 88, "VkImageCreateInfo size");
_Static_assert(sizeof(MeowVkMemoryAllocateInfo) == 32, "VkMemoryAllocateInfo size");
_Static_assert(sizeof(MeowVkMemoryRequirements) == 24, "VkMemoryRequirements size");
_Static_assert(sizeof(MeowVkMemoryType) == 8, "VkMemoryType size");
_Static_assert(sizeof(MeowVkMemoryHeap) == 16, "VkMemoryHeap size");
_Static_assert(sizeof(MeowVkPhysicalDeviceMemoryProperties) == 520,
               "VkPhysicalDeviceMemoryProperties size");
_Static_assert(sizeof(MeowVkImageSubresourceLayers) == 16, "VkImageSubresourceLayers size");
_Static_assert(sizeof(MeowVkOffset3D) == 12, "VkOffset3D size");
_Static_assert(sizeof(MeowVkImageBlit) == 80, "VkImageBlit size");
_Static_assert(offsetof(MeowVkImageBlit, srcOffsets) == 16, "VkImageBlit.srcOffsets @16");
_Static_assert(offsetof(MeowVkImageBlit, dstSubresource) == 40, "VkImageBlit.dstSubresource @40");
_Static_assert(offsetof(MeowVkImageCreateInfo, usage) == 56, "VkImageCreateInfo.usage @56");
_Static_assert(offsetof(MeowVkImageCreateInfo, pQueueFamilyIndices) == 72,
               "VkImageCreateInfo.pQueueFamilyIndices @72");
_Static_assert(offsetof(MeowVkMemoryAllocateInfo, allocationSize) == 16,
               "VkMemoryAllocateInfo.allocationSize @16");
/* F33 (shape=mc) sizes / offsets. */
_Static_assert(sizeof(MeowVkOffset2D) == 8, "VkOffset2D size");
_Static_assert(sizeof(MeowVkExtent2D) == 8, "VkExtent2D size");
_Static_assert(sizeof(MeowVkRect2D) == 16, "VkRect2D size");
_Static_assert(sizeof(MeowVkClearDepthStencilValue) == 8, "VkClearDepthStencilValue size");
_Static_assert(sizeof(MeowVkClearValue) == 16, "VkClearValue size");
_Static_assert(sizeof(MeowVkRenderingAttachmentInfo) == 72, "VkRenderingAttachmentInfo size");
_Static_assert(offsetof(MeowVkRenderingAttachmentInfo, imageView) == 16,
               "VkRenderingAttachmentInfo.imageView @16");
_Static_assert(offsetof(MeowVkRenderingAttachmentInfo, imageLayout) == 24,
               "VkRenderingAttachmentInfo.imageLayout @24");
_Static_assert(offsetof(MeowVkRenderingAttachmentInfo, loadOp) == 44,
               "VkRenderingAttachmentInfo.loadOp @44");
_Static_assert(offsetof(MeowVkRenderingAttachmentInfo, storeOp) == 48,
               "VkRenderingAttachmentInfo.storeOp @48");
_Static_assert(offsetof(MeowVkRenderingAttachmentInfo, clearValue) == 52,
               "VkRenderingAttachmentInfo.clearValue @52");
_Static_assert(sizeof(MeowVkRenderingInfo) == 72, "VkRenderingInfo size");
_Static_assert(offsetof(MeowVkRenderingInfo, renderArea) == 20, "VkRenderingInfo.renderArea @20");
_Static_assert(offsetof(MeowVkRenderingInfo, colorAttachmentCount) == 44,
               "VkRenderingInfo.colorAttachmentCount @44");
_Static_assert(offsetof(MeowVkRenderingInfo, pColorAttachments) == 48,
               "VkRenderingInfo.pColorAttachments @48");
_Static_assert(sizeof(MeowVkImageMemoryBarrier2) == 96, "VkImageMemoryBarrier2 size");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, srcStageMask) == 16,
               "VkImageMemoryBarrier2.srcStageMask @16");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, srcAccessMask) == 24,
               "VkImageMemoryBarrier2.srcAccessMask @24");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, dstStageMask) == 32,
               "VkImageMemoryBarrier2.dstStageMask @32");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, dstAccessMask) == 40,
               "VkImageMemoryBarrier2.dstAccessMask @40");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, oldLayout) == 48,
               "VkImageMemoryBarrier2.oldLayout @48");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, newLayout) == 52,
               "VkImageMemoryBarrier2.newLayout @52");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, image) == 64,
               "VkImageMemoryBarrier2.image @64");
_Static_assert(offsetof(MeowVkImageMemoryBarrier2, subresourceRange) == 72,
               "VkImageMemoryBarrier2.subresourceRange @72");
_Static_assert(sizeof(MeowVkDependencyInfo) == 64, "VkDependencyInfo size");
_Static_assert(offsetof(MeowVkDependencyInfo, pImageMemoryBarriers) == 56,
               "VkDependencyInfo.pImageMemoryBarriers @56");
_Static_assert(sizeof(MeowVkPhysicalDeviceFeatures2) == 240, "VkPhysicalDeviceFeatures2 size");
_Static_assert(offsetof(MeowVkPhysicalDeviceFeatures2, features) == 16,
               "VkPhysicalDeviceFeatures2.features @16");
_Static_assert(sizeof(MeowVkPhysicalDeviceVertexAttributeDivisorFeaturesEXT) == 24,
               "VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT size");
_Static_assert(offsetof(MeowVkPhysicalDeviceVertexAttributeDivisorFeaturesEXT,
                        vertexAttributeInstanceRateDivisor) == 16,
               "divisor.feature @16");
_Static_assert(offsetof(MeowVkPhysicalDeviceVertexAttributeDivisorFeaturesEXT,
                        vertexAttributeInstanceRateZeroDivisor) == 20,
               "divisor.zeroFeature @20");
_Static_assert(sizeof(MeowVkPhysicalDeviceDynamicRenderingFeatures) == 24,
               "VkPhysicalDeviceDynamicRenderingFeatures size");
_Static_assert(sizeof(MeowVkPhysicalDeviceSynchronization2Features) == 24,
               "VkPhysicalDeviceSynchronization2Features size");
_Static_assert(sizeof(MeowVkQueryPoolCreateInfo) == 32, "VkQueryPoolCreateInfo size");
_Static_assert(sizeof(MeowVkBufferCreateInfo) == 56, "VkBufferCreateInfo size");
_Static_assert(offsetof(MeowVkBufferCreateInfo, size) == 24, "VkBufferCreateInfo.size @24");
_Static_assert(offsetof(MeowVkBufferCreateInfo, usage) == 32, "VkBufferCreateInfo.usage @32");
_Static_assert(sizeof(MeowVkBufferImageCopy) == 56, "VkBufferImageCopy size");
_Static_assert(offsetof(MeowVkBufferImageCopy, imageSubresource) == 16,
               "VkBufferImageCopy.imageSubresource @16");
_Static_assert(offsetof(MeowVkBufferImageCopy, imageExtent) == 44,
               "VkBufferImageCopy.imageExtent @44");
_Static_assert(sizeof(MeowVkDescriptorBufferInfo) == 24, "VkDescriptorBufferInfo size");
_Static_assert(sizeof(MeowVkDescriptorSetLayoutBinding) == 24,
               "VkDescriptorSetLayoutBinding size");
_Static_assert(sizeof(MeowVkDescriptorSetLayoutCreateInfo) == 32,
               "VkDescriptorSetLayoutCreateInfo size");
_Static_assert(sizeof(MeowVkPipelineLayoutCreateInfo) == 48, "VkPipelineLayoutCreateInfo size");
_Static_assert(offsetof(MeowVkPipelineLayoutCreateInfo, pSetLayouts) == 24,
               "VkPipelineLayoutCreateInfo.pSetLayouts @24");
_Static_assert(sizeof(MeowVkWriteDescriptorSet) == 64, "VkWriteDescriptorSet size");
_Static_assert(offsetof(MeowVkWriteDescriptorSet, pBufferInfo) == 48,
               "VkWriteDescriptorSet.pBufferInfo @48");
/* F52 (textured item) sizes / offsets. */
_Static_assert(sizeof(MeowVkSamplerCreateInfo) == 80, "VkSamplerCreateInfo size");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, magFilter) == 20,
               "VkSamplerCreateInfo.magFilter @20");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, mipmapMode) == 28,
               "VkSamplerCreateInfo.mipmapMode @28");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, addressModeU) == 32,
               "VkSamplerCreateInfo.addressModeU @32");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, mipLodBias) == 44,
               "VkSamplerCreateInfo.mipLodBias @44");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, anisotropyEnable) == 48,
               "VkSamplerCreateInfo.anisotropyEnable @48");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, compareOp) == 60,
               "VkSamplerCreateInfo.compareOp @60");
_Static_assert(offsetof(MeowVkSamplerCreateInfo, unnormalizedCoordinates) == 76,
               "VkSamplerCreateInfo.unnormalizedCoordinates @76");
_Static_assert(sizeof(MeowVkDescriptorImageInfo) == 24, "VkDescriptorImageInfo size");
_Static_assert(offsetof(MeowVkDescriptorImageInfo, imageView) == 8,
               "VkDescriptorImageInfo.imageView @8");
_Static_assert(offsetof(MeowVkDescriptorImageInfo, imageLayout) == 16,
               "VkDescriptorImageInfo.imageLayout @16");
/* Spot-check the fields the shim already proved on this ABI. */
_Static_assert(offsetof(MeowVkSwapchainCreateInfoKHR, surface) == 24, "swapchain.surface @24");
_Static_assert(offsetof(MeowVkSwapchainCreateInfoKHR, imageUsage) == 56, "swapchain.imageUsage @56");
_Static_assert(offsetof(MeowVkImageMemoryBarrier, image) == 40, "imb.image @40");
_Static_assert(offsetof(MeowVkPresentInfoKHR, pSwapchains) == 40, "present.pSwapchains @40");

/* ------------------------------------------------------------------ */
/* Function pointer typedefs (void* handles; LP64 pointer-sized).      */
/* ------------------------------------------------------------------ */
typedef void* (*PFN_gipa)(void*, const char*);
typedef int32_t (*PFN_vkCreateInstance)(const MeowVkInstanceCreateInfo*, const void*, void**);
typedef int32_t (*PFN_vkEnumeratePhysicalDevices)(void*, uint32_t*, void**);
typedef int32_t (*PFN_vkEnumerateDeviceExtensionProperties)(void*, const char*, uint32_t*,
                                                            MeowVkExtensionProperties*);
typedef void (*PFN_vkGetPhysicalDeviceQueueFamilyProperties)(void*, uint32_t*,
                                                             MeowVkQueueFamilyProperties*);
typedef int32_t (*PFN_vkGetPhysicalDeviceSurfaceSupportKHR)(void*, uint32_t, void*, uint32_t*);
typedef int32_t (*PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR)(void*, void*,
                                                                 MeowVkSurfaceCapabilitiesKHR*);
typedef int32_t (*PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)(void*, void*, uint32_t*,
                                                            MeowVkSurfaceFormatKHR*);
typedef int32_t (*PFN_vkGetPhysicalDeviceSurfacePresentModesKHR)(void*, void*, uint32_t*,
                                                                 int32_t*);
typedef int32_t (*PFN_vkCreateSurfaceOHOS)(void*, const MeowVkSurfaceCreateInfoOHOS*, const void*,
                                           void**);
typedef int32_t (*PFN_vkCreateDevice)(void*, const MeowVkDeviceCreateInfo*, const void*, void**);
typedef void (*PFN_vkGetDeviceQueue)(void*, uint32_t, uint32_t, void**);
typedef int32_t (*PFN_vkCreateSwapchainKHR)(void*, const MeowVkSwapchainCreateInfoKHR*,
                                            const void*, void**);
typedef int32_t (*PFN_vkGetSwapchainImagesKHR)(void*, void*, uint32_t*, void**);
typedef int32_t (*PFN_vkCreateImageView)(void*, const MeowVkImageViewCreateInfo*, const void*,
                                         void**);
typedef int32_t (*PFN_vkCreateCommandPool)(void*, const MeowVkCommandPoolCreateInfo*, const void*,
                                           void**);
typedef int32_t (*PFN_vkAllocateCommandBuffers)(void*, const MeowVkCommandBufferAllocateInfo*,
                                                void**);
typedef int32_t (*PFN_vkBeginCommandBuffer)(void*, const MeowVkCommandBufferBeginInfo*);
typedef void (*PFN_vkCmdPipelineBarrier)(void*, uint32_t, uint32_t, uint32_t, uint32_t, const void*,
                                         uint32_t, const void*, uint32_t,
                                         const MeowVkImageMemoryBarrier*);
typedef void (*PFN_vkCmdClearColorImage)(void*, void*, int32_t, const MeowVkClearColorValue*,
                                         uint32_t, const MeowVkImageSubresourceRange*);
typedef void (*PFN_vkCmdBlitImage)(void*, void*, int32_t, void*, int32_t, uint32_t,
                                   const MeowVkImageBlit*, int32_t);
typedef int32_t (*PFN_vkCreateImage)(void*, const MeowVkImageCreateInfo*, const void*, void**);
typedef void (*PFN_vkGetImageMemoryRequirements)(void*, void*, MeowVkMemoryRequirements*);
typedef int32_t (*PFN_vkBindImageMemory)(void*, void*, void*, uint64_t);
typedef int32_t (*PFN_vkAllocateMemory)(void*, const MeowVkMemoryAllocateInfo*, const void*, void**);
typedef void (*PFN_vkGetPhysicalDeviceMemoryProperties)(void*,
                                                        MeowVkPhysicalDeviceMemoryProperties*);
/* F39: feature query (core 1.1 / VK_KHR_get_physical_device_properties2). */
typedef void (*PFN_vkGetPhysicalDeviceFeatures2)(void*, MeowVkPhysicalDeviceFeatures2*);
typedef void (*PFN_vkDestroyImage)(void*, void*, const void*);
typedef void (*PFN_vkFreeMemory)(void*, void*, const void*);
typedef int32_t (*PFN_vkEndCommandBuffer)(void*);
typedef int32_t (*PFN_vkResetCommandBuffer)(void*, uint32_t);
typedef int32_t (*PFN_vkCreateSemaphore)(void*, const MeowVkSemaphoreCreateInfo*, const void*,
                                         void**);
typedef int32_t (*PFN_vkCreateFence)(void*, const MeowVkFenceCreateInfo*, const void*, void**);
typedef int32_t (*PFN_vkAcquireNextImageKHR)(void*, void*, uint64_t, void*, void*, uint32_t*);
typedef int32_t (*PFN_vkQueueSubmit)(void*, uint32_t, const MeowVkSubmitInfo*, void*);
typedef int32_t (*PFN_vkQueueSubmit2)(void*, uint32_t, const MeowVkSubmitInfo2*, void*);
typedef int32_t (*PFN_vkQueuePresentKHR)(void*, const MeowVkPresentInfoKHR*);
typedef int32_t (*PFN_vkWaitForFences)(void*, uint32_t, void**, uint32_t, uint64_t);
typedef int32_t (*PFN_vkWaitSemaphores)(void*, const MeowVkSemaphoreWaitInfo*, uint64_t);
typedef int32_t (*PFN_vkResetFences)(void*, uint32_t, void**);
typedef int32_t (*PFN_vkDeviceWaitIdle)(void*);
typedef void (*PFN_vkDestroyFence)(void*, void*, const void*);
typedef void (*PFN_vkDestroySemaphore)(void*, void*, const void*);
typedef void (*PFN_vkDestroyCommandPool)(void*, void*, const void*);
typedef void (*PFN_vkDestroyImageView)(void*, void*, const void*);
typedef void (*PFN_vkDestroySwapchainKHR)(void*, void*, const void*);
typedef void (*PFN_vkDestroySurfaceKHR)(void*, void*, const void*);
typedef void (*PFN_vkDestroyDevice)(void*, const void*);
typedef void (*PFN_vkDestroyInstance)(void*, const void*);
/* F33 (shape=mc) entry points. */
typedef int32_t (*PFN_vkCreateQueryPool)(void*, const MeowVkQueryPoolCreateInfo*, const void*,
                                         void**);
typedef void (*PFN_vkDestroyQueryPool)(void*, void*, const void*);
typedef void (*PFN_vkResetQueryPool)(void*, void*, uint32_t, uint32_t);
typedef void (*PFN_vkCmdResetQueryPool)(void*, void*, uint32_t, uint32_t);
typedef void (*PFN_vkCmdWriteTimestamp2)(void*, uint64_t, void*, uint32_t);
typedef int32_t (*PFN_vkCreateBuffer)(void*, const MeowVkBufferCreateInfo*, const void*, void**);
typedef void (*PFN_vkGetBufferMemoryRequirements)(void*, void*, MeowVkMemoryRequirements*);
typedef int32_t (*PFN_vkBindBufferMemory)(void*, void*, void*, uint64_t);
typedef void (*PFN_vkDestroyBuffer)(void*, void*, const void*);
typedef void (*PFN_vkCmdCopyBufferToImage)(void*, void*, void*, int32_t, uint32_t,
                                           const MeowVkBufferImageCopy*);
typedef void (*PFN_vkCmdPipelineBarrier2)(void*, const MeowVkDependencyInfo*);
typedef void (*PFN_vkCmdBeginRenderingKHR)(void*, const MeowVkRenderingInfo*);
typedef void (*PFN_vkCmdEndRenderingKHR)(void*);
typedef void (*PFN_vkCmdPushDescriptorSetKHR)(void*, int32_t, void*, uint32_t, uint32_t,
                                              const MeowVkWriteDescriptorSet*);
typedef int32_t (*PFN_vkCreateDescriptorSetLayout)(void*,
                                                   const MeowVkDescriptorSetLayoutCreateInfo*,
                                                   const void*, void**);
typedef void (*PFN_vkDestroyDescriptorSetLayout)(void*, void*, const void*);
typedef int32_t (*PFN_vkCreatePipelineLayout)(void*, const MeowVkPipelineLayoutCreateInfo*,
                                              const void*, void**);
typedef void (*PFN_vkDestroyPipelineLayout)(void*, void*, const void*);
/* F52 (textured item) entry points. */
typedef int32_t (*PFN_vkCreateSampler)(void*, const MeowVkSamplerCreateInfo*, const void*, void**);
typedef void (*PFN_vkDestroySampler)(void*, void*, const void*);
typedef int32_t (*PFN_vkMapMemory)(void*, void*, uint64_t, uint64_t, uint32_t, void**);
typedef void (*PFN_vkUnmapMemory)(void*, void*);

/* ------------------------------------------------------------------ */
/* Small string builder (single writer: the probe thread).             */
/* ------------------------------------------------------------------ */
typedef struct {
    char* buf;
    size_t cap;
    size_t len;
} MeowSb;

static void sb_reset(MeowSb* sb, char* buf, size_t cap) {
    sb->buf = buf;
    sb->cap = cap;
    sb->len = 0;
    if (cap > 0) {
        buf[0] = '\0';
    }
}

static void sb_add(MeowSb* sb, const char* fmt, ...) {
    if (sb->len + 1 >= sb->cap) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(sb->buf + sb->len, sb->cap - sb->len, fmt, ap);
    va_end(ap);
    if (n > 0) {
        size_t add = (size_t)n;
        if (add > sb->cap - sb->len - 1) {
            add = sb->cap - sb->len - 1;
        }
        sb->len += add;
    }
}

/* F63: wall-clock delta in whole milliseconds between two CLOCK_MONOTONIC stamps. */
static int64_t meow_dt_ms(const struct timespec* a, const struct timespec* b) {
    return (int64_t)(b->tv_sec - a->tv_sec) * 1000 +
           (int64_t)(b->tv_nsec - a->tv_nsec) / 1000000;
}

static const char* rc_name(int rc) {
    switch (rc) {
        case VK_OK:
            return "OK";
        case VK_NOT_READY:
            return "NOT_READY";
        case VK_TIMEOUT:
            return "TIMEOUT";
        case VK_ERROR_OUT_OF_HOST_MEMORY:
            return "OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY:
            return "OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED:
            return "INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST:
            return "DEVICE_LOST";
        case VK_ERROR_MEMORY_MAP_FAILED:
            return "MEMORY_MAP_FAILED";
        case VK_ERROR_LAYER_NOT_PRESENT:
            return "LAYER_NOT_PRESENT";
        case VK_ERROR_EXTENSION_NOT_PRESENT:
            return "EXTENSION_NOT_PRESENT";
        case VK_ERROR_FEATURE_NOT_PRESENT:
            return "FEATURE_NOT_PRESENT";
        case VK_ERROR_INCOMPATIBLE_DRIVER:
            return "INCOMPATIBLE_DRIVER";
        case VK_SUBOPTIMAL_KHR:
            return "SUBOPTIMAL";
        default:
            return "ERR";
    }
}

/* F41: printable name of a devfeat policy (the per-cell "devfeat=" tag). */
static const char* meow_devfeat_name(int mode) {
    switch (mode) {
        case MEOW_VK_DEVFEAT_REAL:
            return "real";
        case MEOW_VK_DEVFEAT_FAKE_STRIP:
            return "fake-strip";
        default:
            return "fake";
    }
}

/* F33 (shape=mc): first DEVICE_LOCAL memory type matching `typeBits`, or
 * 0xFFFFFFFF if none (same selection the offscreen image already uses). */
static uint32_t meow_pick_device_local(const MeowVkPhysicalDeviceMemoryProperties* mp,
                                       uint32_t typeBits) {
    for (uint32_t i = 0; i < mp->memoryTypeCount && i < VK_MAX_MEMORY_TYPES; ++i) {
        if ((typeBits & (1u << i)) != 0 &&
            (mp->memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
            return i;
        }
    }
    return 0xFFFFFFFFu;
}

/* F52 (textured item): first HOST_VISIBLE memory type matching `typeBits`, or
 * 0xFFFFFFFF if none. The CPU-written upload source buffer uses this (it must be
 * mappable); the sampled image itself stays DEVICE_LOCAL. */
static uint32_t meow_pick_host_visible(const MeowVkPhysicalDeviceMemoryProperties* mp,
                                       uint32_t typeBits) {
    for (uint32_t i = 0; i < mp->memoryTypeCount && i < VK_MAX_MEMORY_TYPES; ++i) {
        if ((typeBits & (1u << i)) != 0 &&
            (mp->memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
            return i;
        }
    }
    return 0xFFFFFFFFu;
}

/* ------------------------------------------------------------------ */
/* F39: per-lib device capability probe. The raw system ICD and our    */
/* shim advertise different device extensions, so each cell must ask   */
/* its lib what it supports before requesting anything (F38 hard-coded */
/* five extensions and raw died at vkCreateDevice rc=-7).              */
/* ------------------------------------------------------------------ */
typedef struct {
    int swapchain;
    int dynamicRendering;
    int synchronization2;
    int pushDescriptor;
    int vertexAttributeDivisor;
} MeowVkProbeCaps;

static int meow_name_in_ext_list(const MeowVkExtensionProperties* props, uint32_t count,
                                 const char* name) {
    for (uint32_t i = 0; i < count; ++i) {
        if (strcmp(props[i].extensionName, name) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Enumerate the lib's device extensions once and record which of the ones we
 * care about are advertised. Returns the VkResult of the enumeration. */
static int meow_probe_dev_exts(PFN_vkEnumerateDeviceExtensionProperties enumerateDevExts,
                               void* physDev, MeowVkProbeCaps* caps) {
    memset(caps, 0, sizeof(*caps));
    uint32_t count = 0;
    int rc = enumerateDevExts(physDev, NULL, &count, NULL);
    if (rc != VK_OK || count == 0) {
        return rc == VK_OK ? VK_ERROR_INITIALIZATION_FAILED : rc;
    }
    MeowVkExtensionProperties* props =
        (MeowVkExtensionProperties*)malloc(sizeof(MeowVkExtensionProperties) * (size_t)count);
    if (props == NULL) {
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    rc = enumerateDevExts(physDev, NULL, &count, props);
    if (rc == VK_OK) {
        caps->swapchain = meow_name_in_ext_list(props, count, MEOW_VK_EXT_SWAPCHAIN);
        caps->dynamicRendering =
            meow_name_in_ext_list(props, count, MEOW_VK_EXT_DYNAMIC_RENDERING);
        caps->synchronization2 =
            meow_name_in_ext_list(props, count, MEOW_VK_EXT_SYNCHRONIZATION2);
        caps->pushDescriptor =
            meow_name_in_ext_list(props, count, MEOW_VK_EXT_PUSH_DESCRIPTOR);
        caps->vertexAttributeDivisor =
            meow_name_in_ext_list(props, count, MEOW_VK_EXT_VERTEX_ATTRIBUTE_DIVISOR);
    }
    free(props);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Global result slot (shared with the NAPI wrapper).                  */
/* ------------------------------------------------------------------ */
#define MEOW_VK_PROBE_RESULT_CAP 16384

typedef struct {
    int64_t surfaceId;
    int frames;
} MeowVkProbeJob;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_result[MEOW_VK_PROBE_RESULT_CAP];
static int g_running = 0;

static void set_result_locked(const char* text) {
    snprintf(g_result, sizeof(g_result), "%s", text);
    g_running = 0;
}

/* ------------------------------------------------------------------ */
/* F38: one matrix cell = one (lib, submit) pair. probe_run_one() runs  */
/* exactly one cell; it still reads the MEOW_VK_PROBE_* envs (the       */
/* matrix driver sets LIB/SUBMIT per cell), and it builds its own       */
/* instance / surface / device / swapchain and tears them ALL down      */
/* before returning, so no cell can affect the next. It runs on the     */
/* detached worker thread (the whole matrix), never on the ArkTS UI     */
/* thread.                                                              */
/* ------------------------------------------------------------------ */
#define MEOW_VK_PROBE_DEV_UNSET (-1000)

typedef struct {
    int libShim;
    int submitQueue2;
    int setupOk;
    int devRc; /* vkCreateDevice rc, or MEOW_VK_PROBE_DEV_UNSET if not reached */
    int framesWanted;
    int framesDone;
    int f0Acq;
    int f0Sub;
    int f0Tl;
    int f0Pres;
    int allOk;
    int failKind; /* 0 none, 3 acquire, 4 submit, 5 timeline, 6 present */
    int failFrame;
    int failRc;
    /* F39: whether the cell actually issued >=1 submit call, and the rc of the
     * first submit that returned != VK_OK. A SETUP FAIL (or a failure before the
     * first submit) has submitTested==0 and therefore carries NO submit info. */
    int submitTested;
    int submitFailRc;
    /* F39: the effective capability set this cell requested from its lib. */
    int frameMc;     /* mc command family actually used (0 = degraded plain) */
    int mcDegraded;  /* shape=mc requested but a required extension was missing */
    int capDr;
    int capSync2;
    int capPushDesc;
    int capDivisor;
    /* F40: the mc sub-shape switches that were in effect for this cell (1 = the
     * item was part of the frame / device creation, 0 = it was removed). */
    int mcDr;
    int mcPush;
    int mcUpload;
    int mcTs;
    int mcDiv;
    /* F52: the textured item switch and whether it actually ran (needs the
     * push-descriptor capability so its sampler can be pushed). */
    int mcTex;
    int ranTex;
    /* F42: the mc items that ACTUALLY RAN in this cell (per-item decoupling).
     * ranX = the F40 sub-switch is ON and the capability view permits item X;
     * this is what the cell line prints as "ran[..]" and is never all-or-nothing. */
    int ranDr;
    int ranPush;
    int ranUpload;
    int ranTs;
    int ranDiv;
    /* F41: device-feature policy and its two sets. view* = the CAPABILITY VIEW
     * the probe believed (decides frameMc and is printed as "caps"); the cap*
     * fields above are the ENABLE SET actually requested at vkCreateDevice. */
    int devFeatMode;
    int viewDr;
    int viewSync2;
    int viewPushDesc;
    int viewDiv;
    const char* submit2Name; /* resolved queue2 spelling (NULL for v1) */
    /* F44: the MEOW_VK_SYNC2_TO_V1 value this cell ran under (1 on / 0 off / -1 unset).
     * -1 means the shim's own default applies (ON whenever the hooks are on). */
    int sync2ToV1;
    /* F46: the frame-sync family this cell ran under (1 = timeline semaphore, 0 = binary).
     * Cell 9 forces binary so the translated VkSubmitInfo carries no timeline value. */
    int syncTimeline;
    /* F47: the SPLIT translation switches this cell ran under (1 on / 0 off / -1 unset).
     * _BARRIER gates vkCmdPipelineBarrier2 -> vkCmdPipelineBarrier only; _SUBMIT gates
     * vkQueueSubmit2 -> vkQueueSubmit only. Cell 11 flips only the barrier, cell 12 only
     * the submit, so the malformed translation product can be localised by type. */
    int sync2ToV1Barrier;
    int sync2ToV1Submit;
    /* F63 (MEOW_VK_PROBE_PATTERN): the MC submit/present pattern. patRec = the
     * driver asked this cell to record per-frame telemetry; patMcEnv = the
     * requested pattern (1 mc / 0 own); patActive = the mc pattern really ran
     * (it needs a split queue2 + timeline frame). The arrays hold one sample per
     * frame (bounded by MEOW_VK_PROBE_PAT_FRAMES); patAcqTotal/patPresTotal are
     * the cumulative acquire/present call counts (to spot images never returned). */
    int patRec;
    int patMcEnv;
    int patActive;
    int patCount;
    int patAcqTotal;
    int patPresTotal;
    int64_t patAcqDtMs[MEOW_VK_PROBE_PAT_FRAMES];
    int32_t patImg[MEOW_VK_PROBE_PAT_FRAMES];
    int32_t patSub[MEOW_VK_PROBE_PAT_FRAMES];
    int32_t patPres[MEOW_VK_PROBE_PAT_FRAMES];
    int32_t patTl[MEOW_VK_PROBE_PAT_FRAMES];
    /* F65 (MEOW_VK_PROBE_MC_BLIT): 1 = in this cell the mc shape wrote the acquired
     * swapchain image with the in-place clear instead of the offscreen->swapchain
     * vkCmdBlitImage. The blit is PROBE scaffolding (MC renders straight into the
     * swapchain image), so flipping only this one command isolates whether the blit
     * is what the ICD rejects in the second submit entry. */
    int mcNoBlit;
    /* F65b (MEOW_VK_PROBE_NOSPLIT): 1 = this cell kept the mc shape AND submit=queue2
     * but did NOT split the frame into two submit entries -- one entry carries the
     * acquire wait, every mc command buffer and every signal. That is the shape a
     * "merge the entries" translation would produce, so it pre-validates the fix
     * without touching the shim. */
    int noSplit;
    /* F67 (MEOW_VK_PROBE_TAIL): 0 = full tail CB, 1 = no timestamp, 2 = no blit/clear write.
     * Selects which part of the split tail's second command buffer is kept, so the cell
     * line names the exact variant that ran. */
    int tailMode;
    char detail[192];        /* last diagnostic line of the cell (setup reasons) */
} MeowVkProbeCell;

static MeowVkProbeCell g_cell;
/* F63: set by the driver around the pattern cells (and for a single-cell run) so
 * probe_run_one records the per-frame MC-pattern telemetry; 0 elsewhere keeps the
 * existing cells byte-identical. Only the probe worker thread touches it. */
static int g_patternRecord = 0;

/* F39: a submit-layer conclusion is only valid for a cell that set up AND
 * actually issued at least one submit; everything else carries no submit info
 * (this is what F38 got wrong when it counted a SETUP FAIL as a submit fail). */
static int cell_reached_submit(const MeowVkProbeCell* c) {
    return (c->setupOk && c->submitTested);
}

static int cell_submit_failed(const MeowVkProbeCell* c) {
    return (cell_reached_submit(c) && c->submitFailRc != VK_OK);
}

/* F42: did this cell actually run at least one mc item (the decoupled frame
 * family)? The plain control (cell 4) answers 0 and is never evidence. */
static int cell_ran_mc(const MeowVkProbeCell* c) {
    return (c->frameMc != 0 &&
            (c->ranDr || c->ranPush || c->ranUpload || c->ranTs || c->ranDiv || c->ranTex));
}

/* F42: a submit result is comparable only when the device was really created
 * (dev=0), the cell set up and reached submit, and it ran at least one mc item. */
static int cell_comparable(const MeowVkProbeCell* c) {
    return (c->devRc == VK_OK && c->setupOk && c->submitTested && cell_ran_mc(c));
}

/* F43: human label of a one-item-only cell, derived from its mc sub-switches.
 * Used by the matrix line and the SUMMARY so the single remaining item of a
 * cell is named without carrying an extra string through MeowVkProbeCell. */
static const char* meow_cell_label(const MeowVkProbeCell* c) {
    int n = c->mcDr + c->mcPush + c->mcUpload + c->mcTs + c->mcDiv + c->mcTex;
    if (n == 6) {
        return "all-on";
    }
    if (n == 0) {
        return "no-item(plain)";
    }
    if (c->mcDr) {
        return "only DR";
    }
    if (c->mcPush) {
        return "only PUSH";
    }
    if (c->mcUpload) {
        return "only UPLOAD";
    }
    if (c->mcTs) {
        return "only TS";
    }
    if (c->mcDiv) {
        return "only DIV";
    }
    if (c->mcTex) {
        return "only TEX";
    }
    return "mixed";
}

/* Keep the last (non-empty) line the cell wrote -- for a setup failure that is
 * exactly the reason it gave up, so it can be folded into the one-line summary. */
static void cell_capture_last_line(const char* buf) {
    size_t n = strlen(buf);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) {
        --n;
    }
    size_t start = n;
    while (start > 0 && buf[start - 1] != '\n') {
        --start;
    }
    size_t len = n - start;
    if (len >= sizeof(g_cell.detail)) {
        len = sizeof(g_cell.detail) - 1;
    }
    memcpy(g_cell.detail, buf + start, len);
    g_cell.detail[len] = '\0';
}

static void probe_run_one(int64_t surfaceId, int frames) {
    memset(&g_cell, 0, sizeof(g_cell));
    g_cell.devRc = MEOW_VK_PROBE_DEV_UNSET;
    g_cell.framesWanted = frames;

    char report[MEOW_VK_PROBE_RESULT_CAP];
    MeowSb sb;
    sb_reset(&sb, report, sizeof(report));

    /* F32 library variant. Default is the shim (this round's axis: go through our
     * libmeowvulkan.so, not the raw ICD); MEOW_VK_PROBE_LIB=raw restores the
     * pre-F32 direct-to-ICD path. */
    int useShim = 1;
    {
        const char* lib = getenv("MEOW_VK_PROBE_LIB");
        if (lib != NULL && strcmp(lib, "raw") == 0) {
            useShim = 0;
        }
    }

    if (useShim) {
        sb_add(&sb, "MeowVkProbe report (lib=shim)\n");
    } else {
        sb_add(&sb, "MeowVkProbe report (lib=raw)\n");
    }
    /* Surface the shim's own on/off switch so a passthrough run (MEOW_VK_SHIM
     * unset) can never be misread as "the shim was active". Mirrors the shim's
     * own test (meowvulkan.c: unset/empty/"0" = passthrough). F34: in the shim
     * variant the probe TURNS THE HOOKS ON itself here (overwrite=1), BEFORE it
     * dlopen()s the shim (step 1) and long before the first call into it (the
     * first gipa() invocation in step 2). The shim reads this env in its
     * init_once, i.e. on its first invocation, so this is early enough; the raw
     * variant never sets it (the user's value, if any, stays untouched). */
    {
        const char* shimWas = getenv("MEOW_VK_SHIM");
        sb_add(&sb, "MEOW_VK_SHIM was=%s\n", shimWas != NULL ? shimWas : "(unset)");
        if (useShim) {
            setenv("MEOW_VK_SHIM", "1", 1);
        }
        const char* shimEnv = getenv("MEOW_VK_SHIM");
        int shimHooks = (shimEnv != NULL && shimEnv[0] != '\0' && strcmp(shimEnv, "0") != 0);
        sb_add(&sb, "MEOW_VK_SHIM=%s (shim hooks %s)\n", shimEnv != NULL ? shimEnv : "(unset)",
               shimHooks ? "ON" : "OFF/passthrough");
    }
    /* F36: the F35 feature-bit strip switch is self-set the same way, right beside the
     * MEOW_VK_SHIM setenv above. The launcher applies render envs to the GAME (JVM)
     * process, so a user-set MEOW_VK_STRIP_UNSUPPORTED_FEATURES never reached this
     * probe process (a round whose log had no "extra render env:" line proved it).
     * In the shim variant the probe therefore sets it itself (overwrite=1) BEFORE it
     * dlopen()s the shim and before the first call into it; the shim reads BOTH envs
     * in the one init_once on that first call, so it sees "1". The raw variant never
     * sets it (the user's value, if any, stays untouched). (meowvulkan.c now defaults
     * the strip ON with the hooks anyway; this is the explicit, self-certifying form.) */
    {
        const char* stripWas = getenv("MEOW_VK_STRIP_UNSUPPORTED_FEATURES");
        sb_add(&sb, "MEOW_VK_STRIP_UNSUPPORTED_FEATURES was=%s\n",
               stripWas != NULL ? stripWas : "(unset)");
        if (useShim) {
            setenv("MEOW_VK_STRIP_UNSUPPORTED_FEATURES", "1", 1);
        }
        const char* stripEnv = getenv("MEOW_VK_STRIP_UNSUPPORTED_FEATURES");
        int stripOn = (stripEnv != NULL && stripEnv[0] == '1');
        sb_add(&sb, "MEOW_VK_STRIP_UNSUPPORTED_FEATURES=%s (strip features %s)\n",
               stripEnv != NULL ? stripEnv : "(unset)", stripOn ? "ON" : "OFF");
    }

    /* F30 present-path variant. Default is the blit path (the MC path under
     * test this round); MEOW_VK_PROBE_PIPELINE=clear selects the legacy
     * in-place clear variant. On-device the default is what actually runs. */
    int useBlit = 1;
    {
        const char* pipeline = getenv("MEOW_VK_PROBE_PIPELINE");
        if (pipeline != NULL && strcmp(pipeline, "clear") == 0) {
            useBlit = 0;
        }
    }

    /* F31 frame-sync variant. Default is the TIMELINE semaphore (the MC path
     * under test this round: submit signals it to an increasing value, then
     * vkWaitSemaphores waits that value, recording rc). MEOW_VK_PROBE_SYNC=binary
     * keeps the legacy binary semaphore + fence path. The fence is retained in
     * BOTH variants but its wait is recorded separately ("wf=") from the timeline
     * wait ("tl="). */
    int useTimeline = 1;
    {
        const char* sync = getenv("MEOW_VK_PROBE_SYNC");
        if (sync != NULL && strcmp(sync, "binary") == 0) {
            useTimeline = 0;
        }
    }

    /* F33 frame-shape variant. DEFAULT is "mc": the more complete command
     * family MC submits every frame (KHR dynamic rendering, sync2 barriers, push
     * descriptors, buffer->image upload, timestamps) on top of the F29/F30/F31
     * skeleton. MEOW_VK_PROBE_SHAPE=plain restores the pre-F33 minimal frame. */
    int useMc = 1;
    {
        const char* shape = getenv("MEOW_VK_PROBE_SHAPE");
        if (shape != NULL && strcmp(shape, "plain") == 0) {
            useMc = 0;
        }
    }
    if (useMc) {
        useBlit = 1; /* the mc frame always renders offscreen and blits it out */
    }

    /* F65 mc-shape swapchain-write variant. MEOW_VK_PROBE_MC_BLIT=0 keeps the mc
     * frame COMPLETELY unchanged (offscreen image, mc command family, 2-entry
     * split, every barrier) and only replaces the single offscreen->swapchain
     * vkCmdBlitImage with the in-place vkCmdClearColorImage of the acquired
     * swapchain image (the pre-F33 write path, already used by the
     * MEOW_VK_PROBE_PIPELINE=clear branch below). One variable, no shape change.
     * Default (unset / any other value) = blit, i.e. every pre-F65 cell is
     * byte-identical. Read once per cell, like every other axis here. */
    int mcNoBlit = 0;
    {
        const char* mb = getenv("MEOW_VK_PROBE_MC_BLIT");
        if (mb != NULL && strcmp(mb, "0") == 0) {
            mcNoBlit = 1;
        }
    }

    /* F65b entry-count variant. MEOW_VK_PROBE_NOSPLIT=1 keeps useMc and
     * useQueue2Submit exactly as they are and only turns OFF the two-entry split
     * (splitCb below), so ONE vkQueueSubmit2 entry carries the acquire wait, all mc
     * command buffers and all signals -- the shape a merged translation produces.
     * Default (unset / any other value) = split, i.e. every pre-F65b cell is
     * byte-identical. Read once per cell, like every other axis here. */
    int probeNoSplit = 0;
    {
        const char* ns = getenv("MEOW_VK_PROBE_NOSPLIT");
        if (ns != NULL && strcmp(ns, "0") != 0 && ns[0] != '\0') {
            probeNoSplit = 1;
        }
    }

    /* F67 tail-content bisect. The split path's SECOND command buffer (the split tail)
     * holds, in order: the acquired-image UNDEFINED->TRANSFER_DST barrier, the offscreen
     * ->swapchain write (blit or clear), the TRANSFER_DST->PRESENT_SRC barrier and a
     * vkCmdWriteTimestamp2. Pre-merge on-device data says this CB alone is rejected
     * (rcSeq=0,-1: the render CB passes, this one fails) while the SAME commands inside
     * ONE CB pass. MEOW_VK_PROBE_TAIL selects which part to keep so one run can name the
     * poison: "nots" = drop the timestamp, "nobar" = drop the blit/clear write,
     * anything else = full tail (every pre-F67 cell, byte-identical). */
    const char* tailMode = getenv("MEOW_VK_PROBE_TAIL");
    const int tailNoTs = (tailMode != NULL && strcmp(tailMode, "nots") == 0);
    const int tailNoWrite = (tailMode != NULL && strcmp(tailMode, "nobar") == 0);

    /* F37 submit-API variant. DEFAULT is the sync2 path (vkQueueSubmit2 +
     * VkSubmitInfo2, MC's); MEOW_VK_PROBE_SUBMIT=v1 restores the v1
     * vkQueueSubmit/VkSubmitInfo path. */
    int useQueue2Submit = 1;
    {
        const char* submit = getenv("MEOW_VK_PROBE_SUBMIT");
        if (submit != NULL && strcmp(submit, "v1") == 0) {
            useQueue2Submit = 0;
        }
    }

    /* F40 mc sub-shape switches (each default ON). "0" removes ONLY that item
     * from the mc frame (or, for MC_DIV, the divisor feature bit from device
     * creation); every other part of the mc family stays, so a cell is a clean
     * single-variable test. Read once per cell. */
    int mcDr = 1;
    int mcPush = 1;
    int mcUpload = 1;
    int mcTs = 1;
    int mcDiv = 1;
    /* F52: the textured item is the sixth mc member. It uses its own env name
     * (MEOW_VK_PROBE_TEXTURED; "0" removes it) rather than an MC_* name, per the
     * task, but it participates in the same per-item logic below. */
    int mcTex = 1;
    {
        const char* v = getenv("MEOW_VK_PROBE_MC_DR");
        if (v != NULL && strcmp(v, "0") == 0) {
            mcDr = 0;
        }
        v = getenv("MEOW_VK_PROBE_MC_PUSH");
        if (v != NULL && strcmp(v, "0") == 0) {
            mcPush = 0;
        }
        v = getenv("MEOW_VK_PROBE_MC_UPLOAD");
        if (v != NULL && strcmp(v, "0") == 0) {
            mcUpload = 0;
        }
        v = getenv("MEOW_VK_PROBE_MC_TS");
        if (v != NULL && strcmp(v, "0") == 0) {
            mcTs = 0;
        }
        v = getenv("MEOW_VK_PROBE_MC_DIV");
        if (v != NULL && strcmp(v, "0") == 0) {
            mcDiv = 0;
        }
        v = getenv("MEOW_VK_PROBE_TEXTURED");
        if (v != NULL && strcmp(v, "0") == 0) {
            mcTex = 0;
        }
    }

    /* F44: expose the shim's sync2->v1 translation switch for this cell. -1 when unset (the
     * shim then applies its own default: ON with the hooks). Only recorded/reported; the shim
     * itself reads MEOW_VK_SYNC2_TO_V1, so the probe never acts on it directly. */
    int sync2ToV1 = -1;
    {
        const char* t = getenv("MEOW_VK_SYNC2_TO_V1");
        if (t != NULL && strcmp(t, "0") == 0) {
            sync2ToV1 = 0;
        } else if (t != NULL && t[0] == '1') {
            sync2ToV1 = 1;
        }
    }

    /* F47: the split switches. -1 when unset (the shim then falls back to the legacy
     * MEOW_VK_SYNC2_TO_V1 and finally to its hooks default). Recorded/reported only; the
     * shim reads these envs itself, the probe never acts on them. */
    int sync2ToV1Barrier = -1;
    {
        const char* t = getenv("MEOW_VK_SYNC2_TO_V1_BARRIER");
        if (t != NULL && strcmp(t, "0") == 0) {
            sync2ToV1Barrier = 0;
        } else if (t != NULL && t[0] == '1') {
            sync2ToV1Barrier = 1;
        }
    }
    int sync2ToV1Submit = -1;
    {
        const char* t = getenv("MEOW_VK_SYNC2_TO_V1_SUBMIT");
        if (t != NULL && strcmp(t, "0") == 0) {
            sync2ToV1Submit = 0;
        } else if (t != NULL && t[0] == '1') {
            sync2ToV1Submit = 1;
        }
    }

    /* F63 frame submit/present PATTERN. DEFAULT is "mc": reproduce MC 26.2's shape
     * (one vkQueueSubmit2 carrying two VkSubmitInfo2 entries, no fence, present
     * before the timeline wait, and the timeline wait targets the PREVIOUS
     * submitted value -- MC's lax v-2 equivalent). MEOW_VK_PROBE_PATTERN=own
     * keeps the probe's pre-F63 behaviour (the control). patternRecord is the
     * driver's record switch; setting it for this cell enables the per-frame
     * telemetry (acquire dtMs / imageIndex / submit / present / timelineWait). */
    int patternEnvMc = 1;
    {
        const char* p = getenv("MEOW_VK_PROBE_PATTERN");
        if (p != NULL && strcmp(p, "own") == 0) {
            patternEnvMc = 0;
        }
    }
    int patternRecord = (g_patternRecord != 0);

    /* All handles / entry points start NULL so `goto done` teardown is safe. */
    void* loader = NULL;
    PFN_gipa gipa = NULL;
    /* F32: the shim's vkGetDeviceProcAddr, resolved through gipa in shim mode. */
    PFN_gipa gdpa = NULL;
    void* instance = NULL;
    void* surface = NULL;
    void* device = NULL;
    void* swapchain = NULL;
    void* cmdPool = NULL;
    void* cmdBuf = NULL;
    /* F37: second command buffer (blit stage) when submit=queue2 + shape=mc. */
    void* blitBuf = NULL;
    /* F63 mc pattern: two command-buffer pairs (f&1) so the lax timeline wait
     * ("previous submitted value") can keep 2 submits in flight while a pair is
     * reused only after its own frame has completed (MC uses two pools likewise). */
    void* cmdBufA = NULL;
    void* blitBufA = NULL;
    void* cmdBufB = NULL;
    void* blitBufB = NULL;
    void* semAcquire = NULL;
    void* semRender = NULL;
    void* semTimeline = NULL;
    void* fence = NULL;
    void** imageViews = NULL;
    void* offImage = NULL;
    void* offMemory = NULL;
    /* F33 (shape=mc) resources. */
    void* offView = NULL;
    void* uploadImage = NULL;
    void* uploadMemory = NULL;
    void* srcBuffer = NULL;
    void* srcMemory = NULL;
    void* queryPool = NULL;
    void* descLayout = NULL;
    void* pipeLayout = NULL;
    /* F52 (textured item) resources. */
    void* texImage = NULL;
    void* texMemory = NULL;
    void* texView = NULL;
    void* texSampler = NULL;
    void* texBuffer = NULL;
    void* texBufMemory = NULL;
    OHNativeWindow* window = NULL;
    uint32_t imageCount = 0;
    int deviceCreated = 0;
    int surfaceCreated = 0;
    int rc = VK_OK;

    /* F39: per-cell device capability set actually requested from this lib. */
    MeowVkProbeCaps devCaps;
    memset(&devCaps, 0, sizeof(devCaps));
    int enableDivisor = 0;
    int enableDr = 0;
    int enableSync2 = 0;
    int enablePushDesc = 0;
    int frameMc = 0;     /* mc command family actually usable in this cell */
    int submitsAttempted = 0;
    int submitFailRc = VK_OK;
    /* F41: device-feature policy (parsed below) and its two sets (see step 6). */
    int devFeatMode = MEOW_VK_DEVFEAT_FAKE;
    int qDr = 0;    /* bits vkGetPhysicalDeviceFeatures2 actually reports */
    int qSync2 = 0;
    int qDiv = 0;
    int viewDr = 0; /* capability view: decides frameMc and is printed as caps */
    int viewSync2 = 0;
    int viewDiv = 0;

    /* F41 device-feature policy. DEFAULT when unset is "fake", which preserves
     * the F40 single-cell gate; the devfeat matrix sets it explicitly per cell.
     * Unknown values also fall back to "fake". */
    {
        const char* devfeatEnv = getenv("MEOW_VK_PROBE_DEVFEAT");
        if (devfeatEnv != NULL) {
            if (strcmp(devfeatEnv, "real") == 0) {
                devFeatMode = MEOW_VK_DEVFEAT_REAL;
            } else if (strcmp(devfeatEnv, "fake-strip") == 0) {
                devFeatMode = MEOW_VK_DEVFEAT_FAKE_STRIP;
            } else {
                devFeatMode = MEOW_VK_DEVFEAT_FAKE;
            }
        }
    }

    PFN_vkCreateInstance createInstance = NULL;
    PFN_vkEnumeratePhysicalDevices enumerateDevices = NULL;
    PFN_vkEnumerateDeviceExtensionProperties enumerateDevExts = NULL;
    PFN_vkGetPhysicalDeviceFeatures2 getFeatures2 = NULL;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties getQueueFamilyProps = NULL;
    PFN_vkGetPhysicalDeviceSurfaceSupportKHR getSurfaceSupport = NULL;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR getSurfaceCaps = NULL;
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR getSurfaceFormats = NULL;
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR getPresentModes = NULL;
    PFN_vkCreateSurfaceOHOS createSurface = NULL;
    PFN_vkCreateDevice createDevice = NULL;
    PFN_vkGetDeviceQueue getDeviceQueue = NULL;
    PFN_vkCreateSwapchainKHR createSwapchain = NULL;
    PFN_vkGetSwapchainImagesKHR getSwapchainImages = NULL;
    PFN_vkCreateImageView createImageView = NULL;
    PFN_vkCreateCommandPool createCommandPool = NULL;
    PFN_vkAllocateCommandBuffers allocateCommandBuffers = NULL;
    PFN_vkBeginCommandBuffer beginCommandBuffer = NULL;
    PFN_vkCmdPipelineBarrier cmdPipelineBarrier = NULL;
    PFN_vkCmdClearColorImage cmdClearColorImage = NULL;
    PFN_vkCmdBlitImage cmdBlitImage = NULL;
    PFN_vkEndCommandBuffer endCommandBuffer = NULL;
    PFN_vkResetCommandBuffer resetCommandBuffer = NULL;
    PFN_vkCreateSemaphore createSemaphore = NULL;
    PFN_vkCreateFence createFence = NULL;
    PFN_vkAcquireNextImageKHR acquireNextImage = NULL;
    PFN_vkQueueSubmit queueSubmit = NULL;
    /* F37: sync2 submit entry point (core name preferred, KHR fallback). */
    PFN_vkQueueSubmit2 queueSubmit2 = NULL;
    const char* queueSubmit2Name = NULL;
    PFN_vkQueuePresentKHR queuePresent = NULL;
    PFN_vkWaitForFences waitForFences = NULL;
    PFN_vkWaitSemaphores waitSemaphores = NULL;
    PFN_vkResetFences resetFences = NULL;
    PFN_vkDeviceWaitIdle deviceWaitIdle = NULL;
    PFN_vkDestroyFence destroyFence = NULL;
    PFN_vkDestroySemaphore destroySemaphore = NULL;
    PFN_vkDestroyCommandPool destroyCommandPool = NULL;
    PFN_vkDestroyImageView destroyImageView = NULL;
    PFN_vkDestroySwapchainKHR destroySwapchain = NULL;
    PFN_vkDestroySurfaceKHR destroySurface = NULL;
    PFN_vkDestroyDevice destroyDevice = NULL;
    PFN_vkDestroyInstance destroyInstance = NULL;
    PFN_vkGetPhysicalDeviceMemoryProperties getMemoryProperties = NULL;
    PFN_vkCreateImage createImage = NULL;
    PFN_vkGetImageMemoryRequirements getImageMemoryRequirements = NULL;
    PFN_vkBindImageMemory bindImageMemory = NULL;
    PFN_vkAllocateMemory allocateMemory = NULL;
    PFN_vkDestroyImage destroyImage = NULL;
    PFN_vkFreeMemory freeMemory = NULL;
    /* F33 (shape=mc) entry points. */
    PFN_vkCreateQueryPool createQueryPool = NULL;
    PFN_vkDestroyQueryPool destroyQueryPool = NULL;
    PFN_vkResetQueryPool resetQueryPool = NULL;
    PFN_vkCmdResetQueryPool cmdResetQueryPool = NULL;
    PFN_vkCmdWriteTimestamp2 cmdWriteTimestamp2 = NULL;
    PFN_vkCreateBuffer createBuffer = NULL;
    PFN_vkGetBufferMemoryRequirements getBufferMemoryRequirements = NULL;
    PFN_vkBindBufferMemory bindBufferMemory = NULL;
    PFN_vkDestroyBuffer destroyBuffer = NULL;
    PFN_vkCmdCopyBufferToImage cmdCopyBufferToImage = NULL;
    PFN_vkCmdPipelineBarrier2 cmdPipelineBarrier2 = NULL;
    PFN_vkCmdBeginRenderingKHR cmdBeginRenderingKHR = NULL;
    PFN_vkCmdEndRenderingKHR cmdEndRenderingKHR = NULL;
    PFN_vkCmdPushDescriptorSetKHR cmdPushDescriptorSetKHR = NULL;
    PFN_vkCreateDescriptorSetLayout createDescriptorSetLayout = NULL;
    PFN_vkDestroyDescriptorSetLayout destroyDescriptorSetLayout = NULL;
    PFN_vkCreatePipelineLayout createPipelineLayout = NULL;
    PFN_vkDestroyPipelineLayout destroyPipelineLayout = NULL;
    /* F52 (textured item) entry points. */
    PFN_vkCreateSampler createSampler = NULL;
    PFN_vkDestroySampler destroySampler = NULL;
    PFN_vkMapMemory mapMemory = NULL;
    PFN_vkUnmapMemory unmapMemory = NULL;

    /* 1. loader: our shim by default, the raw system loader with LIB=raw.
     * Shim location: soname first (the loader search path of this process
     * includes the app/HSP native lib dir), then the one verified absolute path.
     * If both fail we report it and stop -- no guessed path chain. */
    if (useShim) {
        loader = dlopen(MEOW_VK_PROBE_SHIM_SONAME, RTLD_NOW | RTLD_GLOBAL);
        if (loader != NULL) {
            sb_add(&sb, "shim located via soname: %s\n", MEOW_VK_PROBE_SHIM_SONAME);
        } else {
            const char* sonameErr = dlerror();
            sb_add(&sb, "dlopen(%s) failed: %s\n", MEOW_VK_PROBE_SHIM_SONAME,
                   sonameErr != NULL ? sonameErr : "(no dlerror)");
            loader = dlopen(MEOW_VK_PROBE_SHIM_PATH, RTLD_NOW | RTLD_GLOBAL);
            if (loader == NULL) {
                sb_add(&sb, "dlopen(%s) failed: %s\n", MEOW_VK_PROBE_SHIM_PATH, dlerror());
                goto done;
            }
            sb_add(&sb, "shim located at explicit path: %s\n", MEOW_VK_PROBE_SHIM_PATH);
        }
    } else {
        loader = dlopen("/system/lib64/libvulkan.so", RTLD_NOW);
        if (loader == NULL) {
            sb_add(&sb, "dlopen /system/lib64/libvulkan.so failed: %s\n", dlerror());
            goto done;
        }
    }
    gipa = (PFN_gipa)dlsym(loader, "vkGetInstanceProcAddr");
    if (gipa == NULL) {
        sb_add(&sb, "missing symbol: vkGetInstanceProcAddr\n");
        goto done;
    }

    /* 2. instance (VK_KHR_surface + VK_OHOS_surface) */
    createInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (createInstance == NULL) {
        sb_add(&sb, "missing symbol: vkCreateInstance\n");
        goto done;
    }
    MeowVkApplicationInfo appInfo;
    memset(&appInfo, 0, sizeof(appInfo));
    appInfo.sType = VK_ST_APPLICATION_INFO;
    appInfo.pApplicationName = "MeowVkProbe";
    appInfo.applicationVersion = 1;
    appInfo.pEngineName = "meowvkprobe";
    appInfo.engineVersion = 1;
    appInfo.apiVersion = VK_API_VERSION_1_0;

    const char* instExts[2] = { "VK_KHR_surface", "VK_OHOS_surface" };
    MeowVkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof(ici));
    ici.sType = VK_ST_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &appInfo;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = instExts;
    rc = createInstance(&ici, NULL, &instance);
    if (rc != VK_OK || instance == NULL) {
        sb_add(&sb, "vkCreateInstance rc=%d (%s)\n", rc, rc_name(rc));
        goto done;
    }
    sb_add(&sb, "vkCreateInstance rc=0\n");

    /* 3. instance-level entry points through the instance (every result
     * null-checked). Device-level commands are NOT resolved here any more: see
     * the MEOW_LOAD_DEV block right after vkCreateDevice (F32). */
#define MEOW_LOAD(ptr, name)                                            \
    do {                                                                \
        void* sym = gipa(instance, name);                               \
        if (sym == NULL) {                                              \
            sb_add(&sb, "missing symbol: %s\n", name);                  \
            goto done;                                                  \
        }                                                               \
        memcpy(&(ptr), &sym, sizeof(ptr));                              \
    } while (0)

/* F39: optional instance-level load (no abort), used for the core-1.1 /
 * VK_KHR_get_physical_device_properties2 feature query. */
#define MEOW_LOAD_OPT(ptr, name)                                        \
    do {                                                                \
        void* sym = gipa(instance, name);                               \
        if (sym != NULL) {                                              \
            memcpy(&(ptr), &sym, sizeof(ptr));                          \
        }                                                               \
    } while (0)

    MEOW_LOAD(enumerateDevices, "vkEnumeratePhysicalDevices");
    MEOW_LOAD(enumerateDevExts, "vkEnumerateDeviceExtensionProperties");
    MEOW_LOAD(getQueueFamilyProps, "vkGetPhysicalDeviceQueueFamilyProperties");
    MEOW_LOAD(getSurfaceSupport, "vkGetPhysicalDeviceSurfaceSupportKHR");
    MEOW_LOAD(getSurfaceCaps, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    MEOW_LOAD(getSurfaceFormats, "vkGetPhysicalDeviceSurfaceFormatsKHR");
    MEOW_LOAD(getPresentModes, "vkGetPhysicalDeviceSurfacePresentModesKHR");
    MEOW_LOAD(createSurface, "vkCreateSurfaceOHOS");
    MEOW_LOAD(createDevice, "vkCreateDevice");
    MEOW_LOAD(getMemoryProperties, "vkGetPhysicalDeviceMemoryProperties");
    MEOW_LOAD(destroySurface, "vkDestroySurfaceKHR");
    MEOW_LOAD(destroyInstance, "vkDestroyInstance");
    /* F32: the shim exports only vkGetInstanceProcAddr / vkGetDeviceProcAddr
     * (plus vkCreateInstance / vkCreateDevice), so device-level commands MUST be
     * fetched through this. Resolve it from the instance now; it is used below.
     * This also means the probe exercises the shim's KHR->core mapping. */
    if (useShim) {
        MEOW_LOAD(gdpa, "vkGetDeviceProcAddr");
    }
    /* F39: feature query is optional; core name first, then the KHR alias. If
     * neither resolves the cell falls back conservatively (see step 6). */
    MEOW_LOAD_OPT(getFeatures2, "vkGetPhysicalDeviceFeatures2");
    if (getFeatures2 == NULL) {
        MEOW_LOAD_OPT(getFeatures2, "vkGetPhysicalDeviceFeatures2KHR");
    }
#undef MEOW_LOAD
#undef MEOW_LOAD_OPT

    /* 4. window from the ArkUI surface id (our own reference; never mutate) */
    int32_t nwrc = OH_NativeWindow_CreateNativeWindowFromSurfaceId((uint64_t)surfaceId, &window);
    if (nwrc != 0 || window == NULL) {
        sb_add(&sb, "no window: CreateNativeWindowFromSurfaceId(sid=%lld) rc=%d\n",
               (long long)surfaceId, (int)nwrc);
        goto done;
    }
    sb_add(&sb, "window ok (sid=%lld)\n", (long long)surfaceId);

    MeowVkSurfaceCreateInfoOHOS sci;
    memset(&sci, 0, sizeof(sci));
    sci.sType = VK_ST_SURFACE_CREATE_INFO_OHOS;
    sci.window = window;
    rc = createSurface(instance, &sci, NULL, &surface);
    if (rc != VK_OK || surface == NULL) {
        sb_add(&sb, "vkCreateSurfaceOHOS rc=%d (%s)\n", rc, rc_name(rc));
        goto done;
    }
    surfaceCreated = 1;

    /* 5. physical device + a queue family that supports graphics AND present */
    uint32_t devCount = 1;
    void* physDev = NULL;
    rc = enumerateDevices(instance, &devCount, &physDev);
    if (rc != VK_OK || devCount < 1 || physDev == NULL) {
        sb_add(&sb, "vkEnumeratePhysicalDevices rc=%d count=%u\n", rc, (unsigned)devCount);
        goto done;
    }
    uint32_t qfCount = 0;
    getQueueFamilyProps(physDev, &qfCount, NULL);
    if (qfCount == 0) {
        sb_add(&sb, "no queue families\n");
        goto done;
    }
    MeowVkQueueFamilyProperties* qfProps =
        (MeowVkQueueFamilyProperties*)malloc(sizeof(MeowVkQueueFamilyProperties) * qfCount);
    if (qfProps == NULL) {
        sb_add(&sb, "malloc queue families failed\n");
        goto done;
    }
    getQueueFamilyProps(physDev, &qfCount, qfProps);
    int32_t queueFamily = -1;
    for (uint32_t i = 0; i < qfCount; ++i) {
        if ((qfProps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0) {
            continue;
        }
        uint32_t support = 0;
        rc = getSurfaceSupport(physDev, i, surface, &support);
        if (rc == VK_OK && support != 0) {
            queueFamily = (int32_t)i;
            break;
        }
    }
    free(qfProps);
    if (queueFamily < 0) {
        sb_add(&sb, "no graphics+present queue family\n");
        goto done;
    }

    MeowVkSurfaceCapabilitiesKHR caps;
    memset(&caps, 0, sizeof(caps));
    rc = getSurfaceCaps(physDev, surface, &caps);
    if (rc != VK_OK) {
        sb_add(&sb, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR rc=%d\n", rc);
        goto done;
    }
    uint32_t fmtCount = 0;
    getSurfaceFormats(physDev, surface, &fmtCount, NULL);
    if (fmtCount == 0) {
        sb_add(&sb, "no surface formats\n");
        goto done;
    }
    MeowVkSurfaceFormatKHR* formats =
        (MeowVkSurfaceFormatKHR*)malloc(sizeof(MeowVkSurfaceFormatKHR) * fmtCount);
    if (formats == NULL) {
        sb_add(&sb, "malloc formats failed\n");
        goto done;
    }
    getSurfaceFormats(physDev, surface, &fmtCount, formats);
    int32_t chosenFormat = formats[0].format;
    int32_t chosenColorSpace = formats[0].colorSpace;
    for (uint32_t i = 0; i < fmtCount; ++i) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM ||
            formats[i].format == VK_FORMAT_R8G8B8A8_UNORM) {
            chosenFormat = formats[i].format;
            chosenColorSpace = formats[i].colorSpace;
            break;
        }
    }
    free(formats);
    if (chosenFormat == VK_FORMAT_UNDEFINED) {
        chosenFormat = VK_FORMAT_B8G8R8A8_UNORM;
    }
    uint32_t modeCount = 0;
    getPresentModes(physDev, surface, &modeCount, NULL);
    int32_t chosenMode = VK_PRESENT_MODE_FIFO_KHR; /* always supported by spec */
    if (modeCount > 0) {
        int32_t* modes = (int32_t*)malloc(sizeof(int32_t) * modeCount);
        if (modes != NULL) {
            getPresentModes(physDev, surface, &modeCount, modes);
            for (uint32_t i = 0; i < modeCount; ++i) {
                if (modes[i] == VK_PRESENT_MODE_FIFO_KHR) {
                    chosenMode = VK_PRESENT_MODE_FIFO_KHR;
                    break;
                }
            }
            free(modes);
        }
    }

    uint32_t extentW = caps.currentExtentW;
    uint32_t extentH = caps.currentExtentH;
    if (extentW == 0xFFFFFFFFu || extentH == 0xFFFFFFFFu) {
        extentW = 640;
        extentH = 360;
        if (extentW < caps.minImageExtentW) extentW = caps.minImageExtentW;
        if (extentH < caps.minImageExtentH) extentH = caps.minImageExtentH;
        if (extentW > caps.maxImageExtentW) extentW = caps.maxImageExtentW;
        if (extentH > caps.maxImageExtentH) extentH = caps.maxImageExtentH;
    }
    uint32_t minImages = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && minImages > caps.maxImageCount) {
        minImages = caps.maxImageCount;
    }
    uint32_t usage = 0;
    if (caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT) {
        usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) {
            usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        }
    }
    if (usage == 0) {
        sb_add(&sb, "swapchain imageUsage unsupported (caps=0x%x)\n",
               (unsigned)caps.supportedUsageFlags);
        goto done;
    }
    uint32_t composite = caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (composite == 0) {
        composite = caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    }
    if (composite == 0) {
        composite = caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR;
    }
    if (composite == 0) {
        composite = caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    }

    /* 6. device with VK_KHR_swapchain */
    const float priority = 1.0f;
    MeowVkDeviceQueueCreateInfo qci;
    memset(&qci, 0, sizeof(qci));
    qci.sType = VK_ST_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = (uint32_t)queueFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;
    /* F39: ask THIS lib what it supports before requesting anything. F38
     * hard-coded five extensions and the raw system ICD answered vkCreateDevice
     * with EXTENSION_NOT_PRESENT (-7); the shim had been hiding that. */
    rc = meow_probe_dev_exts(enumerateDevExts, physDev, &devCaps);
    if (rc != VK_OK) {
        sb_add(&sb, "vkEnumerateDeviceExtensionProperties rc=%d (%s)\n", rc, rc_name(rc));
        goto done;
    }
    if (!devCaps.swapchain) {
        sb_add(&sb, "device ext missing: %s\n", MEOW_VK_EXT_SWAPCHAIN);
        goto done;
    }

    /* Feature bits this lib actually reports. The query chain contains only the
     * extensions the lib advertises (an unsupported ext's feature struct must not
     * be chained); after the call the structs hold what the ICD answered. */
    MeowVkPhysicalDeviceFeatures2 features2;
    MeowVkPhysicalDeviceVertexAttributeDivisorFeaturesEXT divisorFeatures;
    MeowVkPhysicalDeviceDynamicRenderingFeatures drFeatures;
    MeowVkPhysicalDeviceSynchronization2Features sync2Features;
    memset(&features2, 0, sizeof(features2));
    memset(&divisorFeatures, 0, sizeof(divisorFeatures));
    memset(&drFeatures, 0, sizeof(drFeatures));
    memset(&sync2Features, 0, sizeof(sync2Features));
    if (useMc) {
        if (getFeatures2 != NULL) {
            const void* queryHead = NULL;
            if (devCaps.vertexAttributeDivisor) {
                divisorFeatures.sType =
                    VK_ST_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT;
                divisorFeatures.pNext = queryHead;
                queryHead = &divisorFeatures;
            }
            if (devCaps.dynamicRendering) {
                drFeatures.sType = VK_ST_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
                drFeatures.pNext = queryHead;
                queryHead = &drFeatures;
            }
            if (devCaps.synchronization2) {
                sync2Features.sType = VK_ST_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES;
                sync2Features.pNext = queryHead;
                queryHead = &sync2Features;
            }
            features2.sType = VK_ST_PHYSICAL_DEVICE_FEATURES_2;
            features2.pNext = queryHead;
            getFeatures2(physDev, &features2);
            qDiv = devCaps.vertexAttributeDivisor &&
                   divisorFeatures.vertexAttributeInstanceRateDivisor != 0;
            qDr = devCaps.dynamicRendering && drFeatures.dynamicRendering != 0;
            qSync2 = devCaps.synchronization2 && sync2Features.synchronization2 != 0;
        } else if (useShim) {
            /* No feature-query entry point. Keep the pre-F39 shim behaviour: ask
             * for the advertised ones; the shim strips whatever it cannot do
             * (MEOW_VK_STRIP_UNSUPPORTED_FEATURES is set above). */
            qDiv = devCaps.vertexAttributeDivisor;
            qDr = devCaps.dynamicRendering;
            qSync2 = devCaps.synchronization2;
        }
        /* raw with no query entry point: report/enable no extension features (a
         * blind request is exactly what produced FEATURE_NOT_PRESENT). */
        enablePushDesc = devCaps.pushDescriptor;
    }
    /* F41 devfeat policy: view* is the CAPABILITY VIEW, enable* the device set.
     *   real       view = qry, enable = qry  (F39: only reported bits)
     *   fake       view = adv, enable = adv  (F40: advertised => enabled)
     *   fake-strip view = adv, enable = qry  (F35/F36: masquerade at query time,
     *                                         strip the unreported bits at device
     *                                         creation)
     * push_descriptor has no feature bit: it is always used when advertised. */
    {
        int real = (devFeatMode == MEOW_VK_DEVFEAT_REAL);
        int fake = (devFeatMode == MEOW_VK_DEVFEAT_FAKE);
        viewDr = real ? qDr : devCaps.dynamicRendering;
        viewSync2 = real ? qSync2 : devCaps.synchronization2;
        viewDiv = real ? qDiv : devCaps.vertexAttributeDivisor;
        enableDr = fake ? devCaps.dynamicRendering : qDr;
        enableSync2 = fake ? devCaps.synchronization2 : qSync2;
        enableDivisor = fake ? devCaps.vertexAttributeDivisor : qDiv;
    }
    /* F42: DECOUPLE the frame family from the feature enablement. Each mc item
     * runs on its own merits -- its F40 sub-switch is ON and the capability VIEW
     * says the feature that item needs is available -- and a missing item is
     * SKIPPED, never turned into a whole-family degradation to plain. */
    int ranDr = 0;
    int ranPush = 0;
    int ranUpload = 0;
    int ranTs = 0;
    int ranDiv = 0;
    int ranTex = 0;
    if (useMc) {
        ranDr = (mcDr && viewDr);              /* VK_KHR_dynamic_rendering */
        ranPush = (mcPush && enablePushDesc);  /* VK_KHR_push_descriptor (no bit) */
        ranUpload = mcUpload;                  /* core copy/upload, no feature bit */
        ranTs = (mcTs && viewSync2);           /* vkCmdWriteTimestamp2 is a sync2 cmd */
        ranDiv = (mcDiv && viewDiv);           /* VK_EXT_vertex_attribute_divisor bit */
        /* F52: sampling + copyBufferToImage are core, but the texture descriptor
         * is pushed, so the item needs the push-descriptor capability. */
        ranTex = (mcTex && enablePushDesc);
    }
    /* F40 MC_DIV=0 removes only the divisor feature bit from device creation;
     * F42 extends that to a DIV item whose capability view is unavailable. */
    if (!ranDiv) {
        enableDivisor = 0;
    }
    /* The cell runs the mc frame whenever at least one item survived; the
     * per-item ran* flags (not frameMc) decide what is actually emitted below. */
    frameMc = useMc && (ranDr || ranPush || ranUpload || ranTs || ranDiv || ranTex);
    g_cell.devFeatMode = devFeatMode;
    g_cell.viewDr = viewDr;
    g_cell.viewSync2 = viewSync2;
    g_cell.viewPushDesc = enablePushDesc;
    g_cell.viewDiv = viewDiv;
    g_cell.capDr = enableDr;
    g_cell.capSync2 = enableSync2;
    g_cell.capPushDesc = enablePushDesc;
    g_cell.capDivisor = enableDivisor;
    g_cell.ranDr = ranDr;
    g_cell.ranPush = ranPush;
    g_cell.ranUpload = ranUpload;
    g_cell.ranTs = ranTs;
    g_cell.ranDiv = ranDiv;
    g_cell.ranTex = ranTex;
    g_cell.frameMc = frameMc;
    g_cell.mcNoBlit = mcNoBlit;   /* F65: swapchain write = in-place clear, not blit */
    g_cell.noSplit = probeNoSplit;   /* F65b: one entry carried the whole frame */
    g_cell.tailMode = tailNoTs ? 1 : (tailNoWrite ? 2 : 0);   /* F67: 0 full / 1 no-ts / 2 no-write */
    g_cell.mcDegraded = (useMc && !frameMc);
    /* F63: the mc pattern only has meaning on a split queue2 + timeline frame
     * (two command buffers, one vkQueueSubmit2 with two VkSubmitInfo2 entries).
     * Any other combination degrades to the legacy "own" path and says so. */
    int patternActive = patternRecord && patternEnvMc && frameMc && useQueue2Submit && useTimeline;
    g_cell.patRec = patternRecord;
    g_cell.patMcEnv = patternEnvMc;
    g_cell.patActive = patternActive;

    /* 6. device: request {swapchain} + only the mc extensions we will actually
     * use (advertised AND feature-enabled). MEOW_VK_EXT_SYNCHRONIZATION2 is kept
     * whenever the feature is on, because vkQueueSubmit2 needs it even when the
     * frame degrades to plain. */
    const char* devExts[5];
    uint32_t devExtCount = 0;
    devExts[devExtCount++] = MEOW_VK_EXT_SWAPCHAIN;
    if (enableSync2) {
        devExts[devExtCount++] = MEOW_VK_EXT_SYNCHRONIZATION2;
    }
    /* F42: request each mc device extension only when its item actually ran. */
    if (ranDr) {
        devExts[devExtCount++] = MEOW_VK_EXT_DYNAMIC_RENDERING;
    }
    if (ranPush || ranTex) {
        devExts[devExtCount++] = MEOW_VK_EXT_PUSH_DESCRIPTOR;
    }
    if (enableDivisor) {
        devExts[devExtCount++] = MEOW_VK_EXT_VERTEX_ATTRIBUTE_DIVISOR;
    }
    MeowVkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof(dci));
    dci.sType = VK_ST_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = devExtCount;
    dci.ppEnabledExtensionNames = devExts;
    /* Build the device feature chain from the bits we decided to enable. pNext
     * stays NULL (and pEnabledFeatures NULL) when nothing is enabled. */
    {
        const void* createHead = NULL;
        if (enableDivisor) {
            memset(&divisorFeatures, 0, sizeof(divisorFeatures));
            divisorFeatures.sType =
                VK_ST_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT;
            divisorFeatures.vertexAttributeInstanceRateDivisor = VK_TRUE;
            divisorFeatures.vertexAttributeInstanceRateZeroDivisor = VK_TRUE;
            createHead = &divisorFeatures;
        }
        if (enableDr) {
            memset(&drFeatures, 0, sizeof(drFeatures));
            drFeatures.sType = VK_ST_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
            drFeatures.pNext = createHead;
            drFeatures.dynamicRendering = VK_TRUE;
            createHead = &drFeatures;
        }
        if (enableSync2) {
            memset(&sync2Features, 0, sizeof(sync2Features));
            sync2Features.sType = VK_ST_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES;
            sync2Features.pNext = createHead;
            sync2Features.synchronization2 = VK_TRUE;
            createHead = &sync2Features;
        }
        if (createHead != NULL) {
            memset(&features2, 0, sizeof(features2));
            features2.sType = VK_ST_PHYSICAL_DEVICE_FEATURES_2;
            features2.pNext = createHead;
            dci.pNext = &features2;
        }
    }
    rc = createDevice(physDev, &dci, NULL, &device);
    g_cell.devRc = rc;
    if (rc != VK_OK || device == NULL) {
        sb_add(&sb, "vkCreateDevice rc=%d (%s)\n", rc, rc_name(rc));
        goto done;
    }
    deviceCreated = 1;

    /* 6b. device-level entry points. raw: gipa(instance, name), exactly the
     * pre-F32 behaviour. shim: the device's vkGetDeviceProcAddr -- the canonical
     * Vulkan load path, and the one that runs the shim's dispatch / name map. */
#define MEOW_LOAD_DEV(ptr, name)                                        \
    do {                                                                \
        void* sym = (useShim && gdpa != NULL) ? gdpa(device, name)      \
                                              : gipa(instance, name);   \
        if (sym == NULL) {                                              \
            sb_add(&sb, "missing symbol: %s (lib=%s)\n", name,          \
                   useShim ? "shim" : "raw");                           \
            goto done;                                                  \
        }                                                               \
        memcpy(&(ptr), &sym, sizeof(ptr));                              \
    } while (0)

/* F33: optional device-level load (no abort). Needed for symbols whose
 * core/KHR name depends on how the ICD exposes a promoted extension
 * (vkCmdPipelineBarrier2 vs ...KHR, vkResetQueryPool availability). */
#define MEOW_LOAD_DEV_OPT(ptr, name)                                    \
    do {                                                                \
        void* sym = (useShim && gdpa != NULL) ? gdpa(device, name)      \
                                              : gipa(instance, name);   \
        if (sym != NULL) {                                              \
            memcpy(&(ptr), &sym, sizeof(ptr));                          \
        }                                                               \
    } while (0)

    MEOW_LOAD_DEV(getDeviceQueue, "vkGetDeviceQueue");
    MEOW_LOAD_DEV(createSwapchain, "vkCreateSwapchainKHR");
    MEOW_LOAD_DEV(getSwapchainImages, "vkGetSwapchainImagesKHR");
    MEOW_LOAD_DEV(createImageView, "vkCreateImageView");
    MEOW_LOAD_DEV(createCommandPool, "vkCreateCommandPool");
    MEOW_LOAD_DEV(allocateCommandBuffers, "vkAllocateCommandBuffers");
    MEOW_LOAD_DEV(beginCommandBuffer, "vkBeginCommandBuffer");
    MEOW_LOAD_DEV(cmdPipelineBarrier, "vkCmdPipelineBarrier");
    MEOW_LOAD_DEV(cmdClearColorImage, "vkCmdClearColorImage");
    MEOW_LOAD_DEV(cmdBlitImage, "vkCmdBlitImage");
    MEOW_LOAD_DEV(createImage, "vkCreateImage");
    MEOW_LOAD_DEV(getImageMemoryRequirements, "vkGetImageMemoryRequirements");
    MEOW_LOAD_DEV(bindImageMemory, "vkBindImageMemory");
    MEOW_LOAD_DEV(allocateMemory, "vkAllocateMemory");
    MEOW_LOAD_DEV(destroyImage, "vkDestroyImage");
    MEOW_LOAD_DEV(freeMemory, "vkFreeMemory");
    MEOW_LOAD_DEV(endCommandBuffer, "vkEndCommandBuffer");
    MEOW_LOAD_DEV(resetCommandBuffer, "vkResetCommandBuffer");
    MEOW_LOAD_DEV(createSemaphore, "vkCreateSemaphore");
    MEOW_LOAD_DEV(createFence, "vkCreateFence");
    MEOW_LOAD_DEV(acquireNextImage, "vkAcquireNextImageKHR");
    MEOW_LOAD_DEV(queueSubmit, "vkQueueSubmit");
    if (useQueue2Submit) {
        /* F37: sync2 was promoted to core 1.3; on a 1.2 device the ICD exposes
         * VK_KHR_synchronization2 and may expose only the KHR alias. Try the
         * core name first, then the KHR spelling; report which one resolved. */
        MEOW_LOAD_DEV_OPT(queueSubmit2, "vkQueueSubmit2");
        if (queueSubmit2 != NULL) {
            queueSubmit2Name = "vkQueueSubmit2";
        } else {
            MEOW_LOAD_DEV_OPT(queueSubmit2, "vkQueueSubmit2KHR");
            if (queueSubmit2 != NULL) {
                queueSubmit2Name = "vkQueueSubmit2KHR";
            }
        }
        if (queueSubmit2 == NULL) {
            sb_add(&sb, "missing symbol: vkQueueSubmit2[KHR] (submit=queue2)\n");
            goto done;
        }
        g_cell.submit2Name = queueSubmit2Name;
    }
    MEOW_LOAD_DEV(queuePresent, "vkQueuePresentKHR");
    MEOW_LOAD_DEV(waitForFences, "vkWaitForFences");
    if (useTimeline) {
        MEOW_LOAD_DEV(waitSemaphores, "vkWaitSemaphores");
    }
    MEOW_LOAD_DEV(resetFences, "vkResetFences");
    MEOW_LOAD_DEV(deviceWaitIdle, "vkDeviceWaitIdle");
    MEOW_LOAD_DEV(destroyFence, "vkDestroyFence");
    MEOW_LOAD_DEV(destroySemaphore, "vkDestroySemaphore");
    MEOW_LOAD_DEV(destroyCommandPool, "vkDestroyCommandPool");
    MEOW_LOAD_DEV(destroyImageView, "vkDestroyImageView");
    MEOW_LOAD_DEV(destroySwapchain, "vkDestroySwapchainKHR");
    MEOW_LOAD_DEV(destroyDevice, "vkDestroyDevice");
    /* F39/F40: the mc command family is only loaded when the lib exposes and
     * enabled the extensions it needs; F40 loads only the entry points the
     * enabled sub-shape actually uses (a removed item needs no symbol). */
    if (frameMc) {
        /* The sync2 barriers are always part of the mc frame. */
        MEOW_LOAD_DEV_OPT(cmdPipelineBarrier2, "vkCmdPipelineBarrier2");
        if (cmdPipelineBarrier2 == NULL) {
            MEOW_LOAD_DEV_OPT(cmdPipelineBarrier2, "vkCmdPipelineBarrier2KHR");
        }
        if (cmdPipelineBarrier2 == NULL) {
            sb_add(&sb, "missing symbol: vkCmdPipelineBarrier2[KHR] (shape=mc)\n");
            goto done;
        }
        if (ranUpload || ranPush || ranTex) {
            MEOW_LOAD_DEV(createBuffer, "vkCreateBuffer");
            MEOW_LOAD_DEV(getBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
            MEOW_LOAD_DEV(bindBufferMemory, "vkBindBufferMemory");
            MEOW_LOAD_DEV(destroyBuffer, "vkDestroyBuffer");
        }
        if (ranUpload || ranTex) {
            MEOW_LOAD_DEV(cmdCopyBufferToImage, "vkCmdCopyBufferToImage");
        }
        if (ranTs) {
            MEOW_LOAD_DEV(createQueryPool, "vkCreateQueryPool");
            MEOW_LOAD_DEV(destroyQueryPool, "vkDestroyQueryPool");
            MEOW_LOAD_DEV(cmdResetQueryPool, "vkCmdResetQueryPool");
            MEOW_LOAD_DEV_OPT(resetQueryPool, "vkResetQueryPool");
            /* sync2 was promoted to core 1.3; some ICDs expose the KHR alias only. */
            MEOW_LOAD_DEV_OPT(cmdWriteTimestamp2, "vkCmdWriteTimestamp2");
            if (cmdWriteTimestamp2 == NULL) {
                MEOW_LOAD_DEV_OPT(cmdWriteTimestamp2, "vkCmdWriteTimestamp2KHR");
            }
            if (cmdWriteTimestamp2 == NULL) {
                sb_add(&sb, "missing symbol: vkCmdWriteTimestamp2[KHR] (shape=mc)\n");
                goto done;
            }
        }
        if (ranDr) {
            /* dynamicRendering was promoted to core 1.3; raw ICDs may expose only
             * the KHR alias (or vice versa). Either spelling is the same command. */
            MEOW_LOAD_DEV_OPT(cmdBeginRenderingKHR, "vkCmdBeginRenderingKHR");
            if (cmdBeginRenderingKHR == NULL) {
                MEOW_LOAD_DEV_OPT(cmdBeginRenderingKHR, "vkCmdBeginRendering");
            }
            if (cmdBeginRenderingKHR == NULL) {
                sb_add(&sb, "missing symbol: vkCmdBeginRendering[KHR] (shape=mc)\n");
                goto done;
            }
            MEOW_LOAD_DEV_OPT(cmdEndRenderingKHR, "vkCmdEndRenderingKHR");
            if (cmdEndRenderingKHR == NULL) {
                MEOW_LOAD_DEV_OPT(cmdEndRenderingKHR, "vkCmdEndRendering");
            }
            if (cmdEndRenderingKHR == NULL) {
                sb_add(&sb, "missing symbol: vkCmdEndRendering[KHR] (shape=mc)\n");
                goto done;
            }
        }
        if (ranPush || ranTex) {
            MEOW_LOAD_DEV(cmdPushDescriptorSetKHR, "vkCmdPushDescriptorSetKHR");
            MEOW_LOAD_DEV(createDescriptorSetLayout, "vkCreateDescriptorSetLayout");
            MEOW_LOAD_DEV(destroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout");
            MEOW_LOAD_DEV(createPipelineLayout, "vkCreatePipelineLayout");
            MEOW_LOAD_DEV(destroyPipelineLayout, "vkDestroyPipelineLayout");
        }
        if (ranTex) {
            /* F52 (textured item): sampler + CPU-written staging buffer. */
            MEOW_LOAD_DEV(createSampler, "vkCreateSampler");
            MEOW_LOAD_DEV(destroySampler, "vkDestroySampler");
            MEOW_LOAD_DEV(mapMemory, "vkMapMemory");
            MEOW_LOAD_DEV(unmapMemory, "vkUnmapMemory");
        }
    }
#undef MEOW_LOAD_DEV
#undef MEOW_LOAD_DEV_OPT

    void* queue = NULL;
    getDeviceQueue(device, (uint32_t)queueFamily, 0, &queue);
    if (queue == NULL) {
        sb_add(&sb, "vkGetDeviceQueue returned NULL\n");
        goto done;
    }

    /* 7. swapchain */
    MeowVkSwapchainCreateInfoKHR scci;
    memset(&scci, 0, sizeof(scci));
    scci.sType = VK_ST_SWAPCHAIN_CREATE_INFO_KHR;
    scci.surface = (uint64_t)(uintptr_t)surface;
    scci.minImageCount = minImages;
    scci.imageFormat = chosenFormat;
    scci.imageColorSpace = chosenColorSpace;
    scci.extentW = extentW;
    scci.extentH = extentH;
    scci.imageArrayLayers = 1;
    scci.imageUsage = usage;
    scci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    scci.preTransform = caps.currentTransform;
    scci.compositeAlpha = (int32_t)composite;
    scci.presentMode = chosenMode;
    scci.clipped = VK_TRUE;
    rc = createSwapchain(device, &scci, NULL, &swapchain);
    if (rc != VK_OK || swapchain == NULL) {
        sb_add(&sb, "vkCreateSwapchainKHR rc=%d (%s)\n", rc, rc_name(rc));
        goto done;
    }
    imageCount = 0;
    rc = getSwapchainImages(device, swapchain, &imageCount, NULL);
    if (rc != VK_OK || imageCount == 0) {
        sb_add(&sb, "vkGetSwapchainImagesKHR rc=%d count=%u\n", rc, (unsigned)imageCount);
        goto done;
    }
    void** images = (void**)malloc(sizeof(void*) * imageCount);
    imageViews = (void**)calloc(imageCount, sizeof(void*));
    if (images == NULL || imageViews == NULL) {
        sb_add(&sb, "malloc swapchain images failed\n");
        free(images);
        goto done;
    }
    rc = getSwapchainImages(device, swapchain, &imageCount, images);
    if (rc != VK_OK) {
        sb_add(&sb, "vkGetSwapchainImagesKHR(2) rc=%d\n", rc);
        free(images);
        goto done;
    }
    for (uint32_t i = 0; i < imageCount; ++i) {
        MeowVkImageViewCreateInfo ivci;
        memset(&ivci, 0, sizeof(ivci));
        ivci.sType = VK_ST_IMAGE_VIEW_CREATE_INFO;
        ivci.image = (uint64_t)(uintptr_t)images[i];
        ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = chosenFormat;
        ivci.r = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.g = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.b = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.a = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        ivci.subresourceRange.baseMipLevel = 0;
        ivci.subresourceRange.levelCount = 1;
        ivci.subresourceRange.baseArrayLayer = 0;
        ivci.subresourceRange.layerCount = 1;
        rc = createImageView(device, &ivci, NULL, &imageViews[i]);
        if (rc != VK_OK) {
            sb_add(&sb, "vkCreateImageView[%u] rc=%d\n", (unsigned)i, rc);
            free(images);
            goto done;
        }
    }

    sb_add(&sb, "swapchain: fmt=%d cs=%d mode=%d extent=%ux%u images=%u usage=0x%x\n",
           (int)chosenFormat, (int)chosenColorSpace, (int)chosenMode, (unsigned)extentW,
           (unsigned)extentH, (unsigned)imageCount, (unsigned)usage);
    sb_add(&sb, "frames=%d pipeline=%s sync=%s submit=%s lib=%s shape=%s pattern=%s\n", frames,
           useBlit ? "blitImage" : "clearColorImage", useTimeline ? "timeline" : "binary",
           useQueue2Submit ? "queue2" : "v1", useShim ? "shim" : "raw",
           frameMc ? (ranTex ? "mc+tex" : "mc") : (useMc ? "mc-degraded-plain" : "plain"),
           patternRecord ? (patternEnvMc ? "mc" : "own") : "own(off)");
    if (patternRecord) {
        sb_add(&sb,
               "pattern=mc|pattern=own requested=%s active=%d (one vkQueueSubmit2 with 2"
               " VkSubmitInfo2 entries, fence=NULL, present-before-timeline-wait, timeline"
               " wait=previous submitted value)\n",
               patternEnvMc ? "mc" : "own", patternActive);
    }
    sb_add(&sb,
           "device caps: swapchain=%d dr=%d sync2=%d pushdesc=%d divisor=%d"
           " features2=%s frame=%s\n",
           devCaps.swapchain, enableDr, enableSync2, enablePushDesc, enableDivisor,
           getFeatures2 != NULL ? "queried" : "unavailable",
           frameMc ? "mc" : (useMc ? "degraded-plain" : "plain"));
    sb_add(&sb,
           "devfeat=%s caps[dr=%d sync2=%d push=%d div=%d] enabled[dr=%d sync2=%d push=%d"
           " div=%d] ran[dr=%d push=%d up=%d ts=%d div=%d] frame=%s\n",
           meow_devfeat_name(devFeatMode), viewDr, viewSync2, enablePushDesc, viewDiv,
           enableDr, enableSync2, enablePushDesc, enableDivisor,
           ranDr, ranPush, ranUpload, ranTs, ranDiv,
           frameMc ? "mc" : (useMc ? "degraded-plain" : "plain"));
    if (useQueue2Submit) {
        sb_add(&sb, "queueSubmit2 resolved as: %s\n",
               queueSubmit2Name != NULL ? queueSubmit2Name : "(unresolved)");
    }

    /* 7b. blit variant: an offscreen source image (same format as the swapchain,
     * never part of it). Cleared with vkCmdClearColorImage (the write path this
     * ICD honours) and then vkCmdBlitImage'd into the acquired swapchain image. */
    if (useBlit) {
        MeowVkImageCreateInfo icinfo;
        memset(&icinfo, 0, sizeof(icinfo));
        icinfo.sType = VK_ST_IMAGE_CREATE_INFO;
        icinfo.imageType = VK_IMAGE_TYPE_2D;
        icinfo.format = chosenFormat;
        icinfo.extent.width = extentW;
        icinfo.extent.height = extentH;
        icinfo.extent.depth = 1;
        icinfo.mipLevels = 1;
        icinfo.arrayLayers = 1;
        icinfo.samples = VK_SAMPLE_COUNT_1_BIT;
        icinfo.tiling = VK_IMAGE_TILING_OPTIMAL;
        /* the mc frame renders into this image (needs COLOR_ATTACHMENT) then
         * blits it out; a degraded/plain frame only clears it (TRANSFER_DST).
         * Both need TRANSFER_SRC. */
        icinfo.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                       (frameMc ? VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                                : VK_IMAGE_USAGE_TRANSFER_DST_BIT);
        icinfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        icinfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        rc = createImage(device, &icinfo, NULL, &offImage);
        if (rc != VK_OK || offImage == NULL) {
            sb_add(&sb, "vkCreateImage(offscreen) rc=%d (%s)\n", rc, rc_name(rc));
            free(images);
            goto done;
        }
        MeowVkMemoryRequirements memReq;
        memset(&memReq, 0, sizeof(memReq));
        getImageMemoryRequirements(device, offImage, &memReq);
        MeowVkPhysicalDeviceMemoryProperties memProps;
        memset(&memProps, 0, sizeof(memProps));
        getMemoryProperties(physDev, &memProps);
        uint32_t memType = 0xFFFFFFFFu;
        for (uint32_t i = 0; i < memProps.memoryTypeCount && i < VK_MAX_MEMORY_TYPES; ++i) {
            if ((memReq.memoryTypeBits & (1u << i)) != 0 &&
                (memProps.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) !=
                    0) {
                memType = i;
                break;
            }
        }
        if (memType == 0xFFFFFFFFu) {
            sb_add(&sb, "no DEVICE_LOCAL memory type for offscreen (bits=0x%x)\n",
                   (unsigned)memReq.memoryTypeBits);
            free(images);
            goto done;
        }
        MeowVkMemoryAllocateInfo mai;
        memset(&mai, 0, sizeof(mai));
        mai.sType = VK_ST_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = memReq.size;
        mai.memoryTypeIndex = memType;
        rc = allocateMemory(device, &mai, NULL, &offMemory);
        if (rc != VK_OK || offMemory == NULL) {
            sb_add(&sb, "vkAllocateMemory(offscreen) rc=%d (%s)\n", rc, rc_name(rc));
            free(images);
            goto done;
        }
        rc = bindImageMemory(device, offImage, offMemory, 0);
        if (rc != VK_OK) {
            sb_add(&sb, "vkBindImageMemory(offscreen) rc=%d (%s)\n", rc, rc_name(rc));
            free(images);
            goto done;
        }
        if (ranDr) {
            MeowVkImageViewCreateInfo ovci;
            memset(&ovci, 0, sizeof(ovci));
            ovci.sType = VK_ST_IMAGE_VIEW_CREATE_INFO;
            ovci.image = (uint64_t)(uintptr_t)offImage;
            ovci.viewType = VK_IMAGE_VIEW_TYPE_2D;
            ovci.format = chosenFormat;
            ovci.r = VK_COMPONENT_SWIZZLE_IDENTITY;
            ovci.g = VK_COMPONENT_SWIZZLE_IDENTITY;
            ovci.b = VK_COMPONENT_SWIZZLE_IDENTITY;
            ovci.a = VK_COMPONENT_SWIZZLE_IDENTITY;
            ovci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            ovci.subresourceRange.baseMipLevel = 0;
            ovci.subresourceRange.levelCount = 1;
            ovci.subresourceRange.baseArrayLayer = 0;
            ovci.subresourceRange.layerCount = 1;
            rc = createImageView(device, &ovci, NULL, &offView);
            if (rc != VK_OK || offView == NULL) {
                sb_add(&sb, "vkCreateImageView(offscreen) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
        }
        sb_add(&sb, "offscreen: fmt=%d extent=%ux%u memType=%u memSize=%llu\n",
               (int)chosenFormat, (unsigned)extentW, (unsigned)extentH, (unsigned)memType,
               (unsigned long long)memReq.size);
    }

    /* 7c. mc resources: upload source buffer + 16x16 R8G8B8A8_UNORM image,
     * a TIMESTAMP query pool, and a push-descriptor set layout plus its pipeline
     * layout. Only when the full mc command family is usable. F40: each object
     * is created only when its sub-switch is ON, so a cell that removes one item
     * really drops just that object. No SPIR-V / no graphics pipeline is created. */
    if (frameMc) {
        const uint32_t uploadExtent = MEOW_VK_PROBE_UPLOAD_EXTENT;
        const uint64_t uploadBytes =
            (uint64_t)uploadExtent * (uint64_t)uploadExtent * 4ull; /* R8G8B8A8 */
        MeowVkPhysicalDeviceMemoryProperties memProps2;
        memset(&memProps2, 0, sizeof(memProps2));
        getMemoryProperties(physDev, &memProps2);

        /* The source buffer is the upload source (UPLOAD) and also the push
         * descriptor's storage buffer (PUSH); create it when either ran. */
        if (ranUpload || ranPush) {
            MeowVkBufferCreateInfo bci;
            memset(&bci, 0, sizeof(bci));
            bci.sType = VK_ST_BUFFER_CREATE_INFO;
            bci.size = uploadBytes;
            bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
            bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            rc = createBuffer(device, &bci, NULL, &srcBuffer);
            if (rc != VK_OK || srcBuffer == NULL) {
                sb_add(&sb, "vkCreateBuffer(mc) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            MeowVkMemoryRequirements bufReq;
            memset(&bufReq, 0, sizeof(bufReq));
            getBufferMemoryRequirements(device, srcBuffer, &bufReq);
            uint32_t bufMemType = meow_pick_device_local(&memProps2, bufReq.memoryTypeBits);
            if (bufMemType == 0xFFFFFFFFu) {
                sb_add(&sb, "no DEVICE_LOCAL memory type for mc buffer (bits=0x%x)\n",
                       (unsigned)bufReq.memoryTypeBits);
                free(images);
                goto done;
            }
            MeowVkMemoryAllocateInfo bmai;
            memset(&bmai, 0, sizeof(bmai));
            bmai.sType = VK_ST_MEMORY_ALLOCATE_INFO;
            bmai.allocationSize = bufReq.size;
            bmai.memoryTypeIndex = bufMemType;
            rc = allocateMemory(device, &bmai, NULL, &srcMemory);
            if (rc != VK_OK || srcMemory == NULL) {
                sb_add(&sb, "vkAllocateMemory(mc buffer) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            rc = bindBufferMemory(device, srcBuffer, srcMemory, 0);
            if (rc != VK_OK) {
                sb_add(&sb, "vkBindBufferMemory(mc) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
        }

        if (ranUpload) {
            MeowVkImageCreateInfo uic;
            memset(&uic, 0, sizeof(uic));
            uic.sType = VK_ST_IMAGE_CREATE_INFO;
            uic.imageType = VK_IMAGE_TYPE_2D;
            uic.format = VK_FORMAT_R8G8B8A8_UNORM;
            uic.extent.width = uploadExtent;
            uic.extent.height = uploadExtent;
            uic.extent.depth = 1;
            uic.mipLevels = 1;
            uic.arrayLayers = 1;
            uic.samples = VK_SAMPLE_COUNT_1_BIT;
            uic.tiling = VK_IMAGE_TILING_OPTIMAL;
            uic.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
            uic.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            uic.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            rc = createImage(device, &uic, NULL, &uploadImage);
            if (rc != VK_OK || uploadImage == NULL) {
                sb_add(&sb, "vkCreateImage(mc upload) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            MeowVkMemoryRequirements imgReq;
            memset(&imgReq, 0, sizeof(imgReq));
            getImageMemoryRequirements(device, uploadImage, &imgReq);
            uint32_t imgMemType = meow_pick_device_local(&memProps2, imgReq.memoryTypeBits);
            if (imgMemType == 0xFFFFFFFFu) {
                sb_add(&sb, "no DEVICE_LOCAL memory type for mc upload image\n");
                free(images);
                goto done;
            }
            MeowVkMemoryAllocateInfo imai;
            memset(&imai, 0, sizeof(imai));
            imai.sType = VK_ST_MEMORY_ALLOCATE_INFO;
            imai.allocationSize = imgReq.size;
            imai.memoryTypeIndex = imgMemType;
            rc = allocateMemory(device, &imai, NULL, &uploadMemory);
            if (rc != VK_OK || uploadMemory == NULL) {
                sb_add(&sb, "vkAllocateMemory(mc upload) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            rc = bindImageMemory(device, uploadImage, uploadMemory, 0);
            if (rc != VK_OK) {
                sb_add(&sb, "vkBindImageMemory(mc upload) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
        }

        if (ranTs) {
            MeowVkQueryPoolCreateInfo qpci;
            memset(&qpci, 0, sizeof(qpci));
            qpci.sType = VK_ST_QUERY_POOL_CREATE_INFO;
            qpci.queryType = VK_QUERY_TYPE_TIMESTAMP;
            qpci.queryCount = MEOW_VK_PROBE_UPLOAD_QUERIES;
            rc = createQueryPool(device, &qpci, NULL, &queryPool);
            if (rc != VK_OK || queryPool == NULL) {
                sb_add(&sb, "vkCreateQueryPool(timestamp) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
        }

        /* F52 (textured item): a CPU-written HOST_VISIBLE staging buffer, a
         * DEVICE_LOCAL 64x64 R8G8B8A8_UNORM SAMPLED|TRANSFER_DST image, its view
         * and a sampler. Built before the descriptor layout so binding 1 exists. */
        if (ranTex) {
            const uint64_t texBytes =
                (uint64_t)MEOW_VK_PROBE_TEX_EXTENT * (uint64_t)MEOW_VK_PROBE_TEX_EXTENT * 4ull;
            MeowVkBufferCreateInfo tbci;
            memset(&tbci, 0, sizeof(tbci));
            tbci.sType = VK_ST_BUFFER_CREATE_INFO;
            tbci.size = texBytes;
            tbci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
            tbci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            rc = createBuffer(device, &tbci, NULL, &texBuffer);
            if (rc != VK_OK || texBuffer == NULL) {
                sb_add(&sb, "vkCreateBuffer(tex) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            MeowVkMemoryRequirements texBufReq;
            memset(&texBufReq, 0, sizeof(texBufReq));
            getBufferMemoryRequirements(device, texBuffer, &texBufReq);
            uint32_t texBufMemType = meow_pick_host_visible(&memProps2, texBufReq.memoryTypeBits);
            if (texBufMemType == 0xFFFFFFFFu) {
                sb_add(&sb, "no HOST_VISIBLE memory type for tex buffer (bits=0x%x)\n",
                       (unsigned)texBufReq.memoryTypeBits);
                free(images);
                goto done;
            }
            MeowVkMemoryAllocateInfo tbmai;
            memset(&tbmai, 0, sizeof(tbmai));
            tbmai.sType = VK_ST_MEMORY_ALLOCATE_INFO;
            tbmai.allocationSize = texBufReq.size;
            tbmai.memoryTypeIndex = texBufMemType;
            rc = allocateMemory(device, &tbmai, NULL, &texBufMemory);
            if (rc != VK_OK || texBufMemory == NULL) {
                sb_add(&sb, "vkAllocateMemory(tex buffer) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            rc = bindBufferMemory(device, texBuffer, texBufMemory, 0);
            if (rc != VK_OK) {
                sb_add(&sb, "vkBindBufferMemory(tex) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            void* texMapped = NULL;
            if (mapMemory(device, texBufMemory, 0, texBytes, 0, &texMapped) != VK_OK ||
                texMapped == NULL) {
                sb_add(&sb, "vkMapMemory(tex) failed\n");
                free(images);
                goto done;
            }
            {
                uint8_t* px = (uint8_t*)texMapped;
                for (uint32_t y = 0; y < MEOW_VK_PROBE_TEX_EXTENT; ++y) {
                    for (uint32_t x = 0; x < MEOW_VK_PROBE_TEX_EXTENT; ++x) {
                        uint32_t o = (y * MEOW_VK_PROBE_TEX_EXTENT + x) * 4u;
                        px[o + 0] = (uint8_t)(x * 4u);
                        px[o + 1] = (uint8_t)(y * 4u);
                        px[o + 2] = (uint8_t)((x ^ y) * 4u);
                        px[o + 3] = 255u;
                    }
                }
            }
            unmapMemory(device, texBufMemory);

            MeowVkImageCreateInfo tic;
            memset(&tic, 0, sizeof(tic));
            tic.sType = VK_ST_IMAGE_CREATE_INFO;
            tic.imageType = VK_IMAGE_TYPE_2D;
            tic.format = VK_FORMAT_R8G8B8A8_UNORM;
            tic.extent.width = MEOW_VK_PROBE_TEX_EXTENT;
            tic.extent.height = MEOW_VK_PROBE_TEX_EXTENT;
            tic.extent.depth = 1;
            tic.mipLevels = 1;
            tic.arrayLayers = 1;
            tic.samples = VK_SAMPLE_COUNT_1_BIT;
            tic.tiling = VK_IMAGE_TILING_OPTIMAL;
            tic.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
            tic.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            tic.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            rc = createImage(device, &tic, NULL, &texImage);
            if (rc != VK_OK || texImage == NULL) {
                sb_add(&sb, "vkCreateImage(tex) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            MeowVkMemoryRequirements texImgReq;
            memset(&texImgReq, 0, sizeof(texImgReq));
            getImageMemoryRequirements(device, texImage, &texImgReq);
            uint32_t texImgMemType = meow_pick_device_local(&memProps2, texImgReq.memoryTypeBits);
            if (texImgMemType == 0xFFFFFFFFu) {
                sb_add(&sb, "no DEVICE_LOCAL memory type for tex image\n");
                free(images);
                goto done;
            }
            MeowVkMemoryAllocateInfo timai;
            memset(&timai, 0, sizeof(timai));
            timai.sType = VK_ST_MEMORY_ALLOCATE_INFO;
            timai.allocationSize = texImgReq.size;
            timai.memoryTypeIndex = texImgMemType;
            rc = allocateMemory(device, &timai, NULL, &texMemory);
            if (rc != VK_OK || texMemory == NULL) {
                sb_add(&sb, "vkAllocateMemory(tex image) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            rc = bindImageMemory(device, texImage, texMemory, 0);
            if (rc != VK_OK) {
                sb_add(&sb, "vkBindImageMemory(tex) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            MeowVkImageViewCreateInfo tvci;
            memset(&tvci, 0, sizeof(tvci));
            tvci.sType = VK_ST_IMAGE_VIEW_CREATE_INFO;
            tvci.image = (uint64_t)(uintptr_t)texImage;
            tvci.viewType = VK_IMAGE_VIEW_TYPE_2D;
            tvci.format = VK_FORMAT_R8G8B8A8_UNORM;
            tvci.r = VK_COMPONENT_SWIZZLE_IDENTITY;
            tvci.g = VK_COMPONENT_SWIZZLE_IDENTITY;
            tvci.b = VK_COMPONENT_SWIZZLE_IDENTITY;
            tvci.a = VK_COMPONENT_SWIZZLE_IDENTITY;
            tvci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            tvci.subresourceRange.baseMipLevel = 0;
            tvci.subresourceRange.levelCount = 1;
            tvci.subresourceRange.baseArrayLayer = 0;
            tvci.subresourceRange.layerCount = 1;
            rc = createImageView(device, &tvci, NULL, &texView);
            if (rc != VK_OK || texView == NULL) {
                sb_add(&sb, "vkCreateImageView(tex) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            MeowVkSamplerCreateInfo tsci;
            memset(&tsci, 0, sizeof(tsci));
            tsci.sType = VK_ST_SAMPLER_CREATE_INFO;
            tsci.magFilter = VK_FILTER_NEAREST;
            tsci.minFilter = VK_FILTER_NEAREST;
            tsci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
            tsci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            tsci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            tsci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            rc = createSampler(device, &tsci, NULL, &texSampler);
            if (rc != VK_OK || texSampler == NULL) {
                sb_add(&sb, "vkCreateSampler(tex) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
        }

        if (ranPush || ranTex) {
            MeowVkDescriptorSetLayoutBinding dslb[2];
            memset(dslb, 0, sizeof(dslb));
            uint32_t dslbCount = 0;
            if (ranPush) {
                dslb[dslbCount].binding = 0;
                dslb[dslbCount].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
                dslb[dslbCount].descriptorCount = 1;
                dslb[dslbCount].stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS;
                ++dslbCount;
            }
            if (ranTex) {
                dslb[dslbCount].binding = 1;
                dslb[dslbCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                dslb[dslbCount].descriptorCount = 1;
                dslb[dslbCount].stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS;
                ++dslbCount;
            }
            MeowVkDescriptorSetLayoutCreateInfo dslci;
            memset(&dslci, 0, sizeof(dslci));
            dslci.sType = VK_ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            dslci.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR;
            dslci.bindingCount = dslbCount;
            dslci.pBindings = dslb;
            rc = createDescriptorSetLayout(device, &dslci, NULL, &descLayout);
            if (rc != VK_OK || descLayout == NULL) {
                sb_add(&sb, "vkCreateDescriptorSetLayout(push) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
            const uint64_t setLayoutHandle = (uint64_t)(uintptr_t)descLayout;
            MeowVkPipelineLayoutCreateInfo plci;
            memset(&plci, 0, sizeof(plci));
            plci.sType = VK_ST_PIPELINE_LAYOUT_CREATE_INFO;
            plci.setLayoutCount = 1;
            plci.pSetLayouts = &setLayoutHandle;
            rc = createPipelineLayout(device, &plci, NULL, &pipeLayout);
            if (rc != VK_OK || pipeLayout == NULL) {
                sb_add(&sb, "vkCreatePipelineLayout(push) rc=%d (%s)\n", rc, rc_name(rc));
                free(images);
                goto done;
            }
        }
        sb_add(&sb, "mc resources: upload=%d buf=%d queries=%u pushlayout=%d bytes=%llu"
                    " tex=%d\n",
               ranUpload, (ranUpload || ranPush), ranTs ? MEOW_VK_PROBE_UPLOAD_QUERIES : 0u,
               ranPush, (unsigned long long)uploadBytes, ranTex);
        if (ranTex) {
            const uint64_t texBytes =
                (uint64_t)MEOW_VK_PROBE_TEX_EXTENT * (uint64_t)MEOW_VK_PROBE_TEX_EXTENT * 4ull;
            sb_add(&sb,
                   "tex=1 upload=copyBufferToImage smp=1 extent=%ux%u fmt=R8G8B8A8_UNORM"
                   " buf=%lluB hostvis=1\n",
                   (unsigned)MEOW_VK_PROBE_TEX_EXTENT, (unsigned)MEOW_VK_PROBE_TEX_EXTENT,
                   (unsigned long long)texBytes);
        }
    }

    /* 8. command pool / buffer, semaphores, fence */
    MeowVkCommandPoolCreateInfo cpci;
    memset(&cpci, 0, sizeof(cpci));
    cpci.sType = VK_ST_COMMAND_POOL_CREATE_INFO;
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = (uint32_t)queueFamily;
    rc = createCommandPool(device, &cpci, NULL, &cmdPool);
    if (rc != VK_OK) {
        sb_add(&sb, "vkCreateCommandPool rc=%d\n", rc);
        free(images);
        goto done;
    }
    MeowVkCommandBufferAllocateInfo cbai;
    memset(&cbai, 0, sizeof(cbai));
    cbai.sType = VK_ST_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = (uint64_t)(uintptr_t)cmdPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    /* F37: submit=queue2 + shape=mc needs a second command buffer for the blit
     * stage (stage B); every other combination uses a single command buffer.
     * F63 mc pattern: allocate two render+blit pairs and alternate them (f&1). */
    /* F65b: MEOW_VK_PROBE_NOSPLIT=1 turns the TWO-ENTRY mc shape into ONE entry that
     * carries everything (acquire wait + every mc command buffer + every signal).
     * Nothing else about the frame changes. */
    int splitCb = (useQueue2Submit && frameMc && !probeNoSplit);
    if (patternActive) {
        void* cbs[4] = { NULL, NULL, NULL, NULL };
        cbai.commandBufferCount = 4;
        rc = allocateCommandBuffers(device, &cbai, cbs);
        cmdBufA = cbs[0];
        blitBufA = cbs[1];
        cmdBufB = cbs[2];
        blitBufB = cbs[3];
        cmdBuf = cmdBufA;
        blitBuf = blitBufA;
    } else if (splitCb) {
        void* cbs[2] = { NULL, NULL };
        cbai.commandBufferCount = 2;
        rc = allocateCommandBuffers(device, &cbai, cbs);
        cmdBuf = cbs[0];
        blitBuf = cbs[1];
    } else {
        cbai.commandBufferCount = 1;
        rc = allocateCommandBuffers(device, &cbai, &cmdBuf);
    }
    if (rc != VK_OK || cmdBuf == NULL || (splitCb && blitBuf == NULL) ||
        (patternActive && (cmdBufB == NULL || blitBufB == NULL))) {
        sb_add(&sb, "vkAllocateCommandBuffers rc=%d\n", rc);
        free(images);
        goto done;
    }
    MeowVkSemaphoreCreateInfo semci;
    memset(&semci, 0, sizeof(semci));
    semci.sType = VK_ST_SEMAPHORE_CREATE_INFO;
    if (createSemaphore(device, &semci, NULL, &semAcquire) != VK_OK ||
        createSemaphore(device, &semci, NULL, &semRender) != VK_OK) {
        sb_add(&sb, "vkCreateSemaphore failed\n");
        free(images);
        goto done;
    }
    MeowVkFenceCreateInfo fci;
    memset(&fci, 0, sizeof(fci));
    fci.sType = VK_ST_FENCE_CREATE_INFO;
    fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    if (createFence(device, &fci, NULL, &fence) != VK_OK) {
        sb_add(&sb, "vkCreateFence failed\n");
        free(images);
        goto done;
    }
    if (useTimeline) {
        MeowVkSemaphoreTypeCreateInfo tci;
        memset(&tci, 0, sizeof(tci));
        tci.sType = VK_ST_SEMAPHORE_TYPE_CREATE_INFO;
        tci.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
        tci.initialValue = 0;
        MeowVkSemaphoreCreateInfo tsci;
        memset(&tsci, 0, sizeof(tsci));
        tsci.sType = VK_ST_SEMAPHORE_CREATE_INFO;
        tsci.pNext = &tci;
        if (createSemaphore(device, &tsci, NULL, &semTimeline) != VK_OK ||
            semTimeline == NULL) {
            sb_add(&sb, "vkCreateSemaphore(timeline) failed\n");
            free(images);
            goto done;
        }
    }

    /* 9. per-frame rc storage (bounded) */
    if (frames > 4096) {
        frames = 4096;
    }
    int* acqRc = (int*)malloc(sizeof(int) * (size_t)frames);
    int* subRc = (int*)malloc(sizeof(int) * (size_t)frames);
    int* preRc = (int*)malloc(sizeof(int) * (size_t)frames);
    int* fenceRc = (int*)malloc(sizeof(int) * (size_t)frames);
    int* tlRc = (int*)malloc(sizeof(int) * (size_t)frames);
    if (acqRc == NULL || subRc == NULL || preRc == NULL || fenceRc == NULL || tlRc == NULL) {
        sb_add(&sb, "malloc frame rc arrays failed\n");
        free(acqRc);
        free(subRc);
        free(preRc);
        free(fenceRc);
        free(tlRc);
        free(images);
        goto done;
    }
    int doneFrames = 0;
    int failFrame = -1;
    int failAcq = VK_OK;
    int failSub = VK_OK;
    int failPre = VK_OK;
    int failTl = VK_OK;

    /* F38: instance/surface/device/swapchain/pool/semaphores are all built. */
    g_cell.setupOk = 1;

    const MeowVkClearColorValue clearColor = { 0.0f, 0.35f, 0.7f, 1.0f };
    const MeowVkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

    for (int f = 0; f < frames; ++f) {
        int rcAcq = VK_OK;
        int rcSub = VK_OK;
        int rcPre = VK_OK;
        int rcFence = VK_OK;
        int rcTl = useTimeline ? VK_OK : -1; /* -1 = timeline wait not performed */

        /* F63: alternate the two command-buffer pairs so the lax timeline wait can
         * keep two submits in flight (pair f&1 was last used by frame f-2). */
        if (patternActive) {
            cmdBuf = (f & 1) ? cmdBufB : cmdBufA;
            blitBuf = (f & 1) ? blitBufB : blitBufA;
        }
        if (patternRecord && f < MEOW_VK_PROBE_PAT_FRAMES) {
            g_cell.patAcqDtMs[f] = -1;
            g_cell.patImg[f] = -1;
            g_cell.patSub[f] = -1000;
            g_cell.patPres[f] = -1000;
            g_cell.patTl[f] = -1000;
        }
        tlRc[f] = rcTl;
        if (!patternActive) {
            /* fence was created signaled; wait the previous submit before reuse */
            if (waitForFences(device, 1, &fence, VK_TRUE, 0xFFFFFFFFFFFFFFFFull) != VK_OK) {
                rcFence = -999;
                rcSub = -999;
                acqRc[f] = rcSub;
                subRc[f] = rcSub;
                preRc[f] = rcSub;
                fenceRc[f] = rcFence;
                tlRc[f] = rcTl;
                doneFrames = f;
                failFrame = f;
                failSub = rcSub;
                break;
            }
            fenceRc[f] = rcFence;
            resetFences(device, 1, &fence);
        } else {
            /* MC submits with fence=NULL; the timeline wait is the completion gate. */
            fenceRc[f] = -1;
        }

        uint32_t imageIndex = 0;
        struct timespec acqT0;
        struct timespec acqT1;
        if (patternRecord) {
            clock_gettime(CLOCK_MONOTONIC, &acqT0);
        }
        rcAcq = acquireNextImage(device, swapchain, 0xFFFFFFFFFFFFFFFFull, semAcquire, NULL,
                                 &imageIndex);
        if (patternRecord) {
            clock_gettime(CLOCK_MONOTONIC, &acqT1);
            ++g_cell.patAcqTotal;
            if (f < MEOW_VK_PROBE_PAT_FRAMES) {
                g_cell.patImg[f] = (int32_t)imageIndex;
                g_cell.patAcqDtMs[f] = meow_dt_ms(&acqT0, &acqT1);
            }
        }
        acqRc[f] = rcAcq;
        if (rcAcq != VK_OK && rcAcq != VK_SUBOPTIMAL_KHR) {
            doneFrames = f;
            failFrame = f;
            failAcq = rcAcq;
            break;
        }

        resetCommandBuffer(cmdBuf, 0);
        MeowVkCommandBufferBeginInfo cbbi;
        memset(&cbbi, 0, sizeof(cbbi));
        cbbi.sType = VK_ST_COMMAND_BUFFER_BEGIN_INFO;
        cbbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (beginCommandBuffer(cmdBuf, &cbbi) != VK_OK) {
            rcSub = -998;
            subRc[f] = rcSub;
            doneFrames = f;
            failFrame = f;
            failSub = rcSub;
            break;
        }

        if (frameMc) {
            /* ---- F33 shape=mc: the MC-shaped command family, all v2/KHR ---- */
            MeowVkImageMemoryBarrier2 b2;
            MeowVkDependencyInfo dep;

            /* timestamps (F40 MC_TS): 4 queries per frame, MC writes one every
             * frame. Host vkResetQueryPool is preferred (MC's path);
             * vkCmdResetQueryPool is the core-1.0 fallback (both share the same
             * (obj,pool,first,count) shape, so the object is device vs cmd buf). */
            if (ranTs) {
                PFN_vkResetQueryPool resetFn =
                    resetQueryPool != NULL ? resetQueryPool : cmdResetQueryPool;
                void* resetObj = resetQueryPool != NULL ? device : cmdBuf;
                resetFn(resetObj, queryPool, 0, MEOW_VK_PROBE_UPLOAD_QUERIES);
                cmdWriteTimestamp2(cmdBuf, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, queryPool, 0);
            }

            /* offscreen render target: UNDEFINED -> GENERAL (rendering layout) */
            memset(&b2, 0, sizeof(b2));
            b2.sType = VK_ST_IMAGE_MEMORY_BARRIER_2;
            b2.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
            b2.srcAccessMask = 0;
            b2.dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
            b2.dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
            b2.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            b2.newLayout = VK_IMAGE_LAYOUT_GENERAL;
            b2.srcQueueFamilyIndex = 0xFFFFFFFFu;
            b2.dstQueueFamilyIndex = 0xFFFFFFFFu;
            b2.image = (uint64_t)(uintptr_t)offImage;
            b2.subresourceRange = range;
            memset(&dep, 0, sizeof(dep));
            dep.sType = VK_ST_DEPENDENCY_INFO;
            dep.imageMemoryBarrierCount = 1;
            dep.pImageMemoryBarriers = &b2;
            cmdPipelineBarrier2(cmdBuf, &dep);

            /* F40/F42 UPLOAD item: upload image UNDEFINED -> TRANSFER_DST. */
            if (ranUpload) {
                b2.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
                b2.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
                b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                b2.image = (uint64_t)(uintptr_t)uploadImage;
                cmdPipelineBarrier2(cmdBuf, &dep);
            }
            /* acquired swapchain image: UNDEFINED -> TRANSFER_DST. F37: with
             * submit=queue2 the swapchain image is only acquired for stage B, so
             * its layout transition moves there (see below). */
            if (!splitCb) {
                b2.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
                b2.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
                b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                b2.image = (uint64_t)(uintptr_t)images[imageIndex];
                cmdPipelineBarrier2(cmdBuf, &dep);
            }

            /* MC's only texture-upload entry point (F40/F42 UPLOAD item). */
            if (ranUpload) {
                MeowVkBufferImageCopy bic;
                memset(&bic, 0, sizeof(bic));
                bic.bufferOffset = 0;
                bic.bufferRowLength = 0;
                bic.bufferImageHeight = 0;
                bic.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                bic.imageSubresource.mipLevel = 0;
                bic.imageSubresource.baseArrayLayer = 0;
                bic.imageSubresource.layerCount = 1;
                bic.imageExtent.width = MEOW_VK_PROBE_UPLOAD_EXTENT;
                bic.imageExtent.height = MEOW_VK_PROBE_UPLOAD_EXTENT;
                bic.imageExtent.depth = 1;
                cmdCopyBufferToImage(cmdBuf, srcBuffer, uploadImage,
                                     VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bic);
            }
            /* F52 textured item: UNDEFINED -> TRANSFER_DST_OPTIMAL, upload the
             * CPU-written 64x64 source buffer with vkCmdCopyBufferToImage (the
             * command under suspicion), then TRANSFER_DST_OPTIMAL -> GENERAL
             * (MC's sampled layout). */
            if (ranTex) {
                b2.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
                b2.srcAccessMask = 0;
                b2.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
                b2.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
                b2.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
                b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                b2.image = (uint64_t)(uintptr_t)texImage;
                cmdPipelineBarrier2(cmdBuf, &dep);

                MeowVkBufferImageCopy tbc;
                memset(&tbc, 0, sizeof(tbc));
                tbc.bufferOffset = 0;
                tbc.bufferRowLength = 0;
                tbc.bufferImageHeight = 0;
                tbc.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                tbc.imageSubresource.mipLevel = 0;
                tbc.imageSubresource.baseArrayLayer = 0;
                tbc.imageSubresource.layerCount = 1;
                tbc.imageExtent.width = MEOW_VK_PROBE_TEX_EXTENT;
                tbc.imageExtent.height = MEOW_VK_PROBE_TEX_EXTENT;
                tbc.imageExtent.depth = 1;
                cmdCopyBufferToImage(cmdBuf, texBuffer, texImage,
                                     VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &tbc);

                b2.srcStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
                b2.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
                b2.dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
                b2.dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT;
                b2.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                b2.newLayout = VK_IMAGE_LAYOUT_GENERAL;
                b2.image = (uint64_t)(uintptr_t)texImage;
                cmdPipelineBarrier2(cmdBuf, &dep);
            }
            if (ranTs) {
                cmdWriteTimestamp2(cmdBuf, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, queryPool, 1);
            }

            /* vkCmdBeginRenderingKHR on the offscreen image (KHR spelling, MC's;
             * F40/F42 DR item). */
            if (ranDr) {
                MeowVkRenderingAttachmentInfo colorAtt;
                memset(&colorAtt, 0, sizeof(colorAtt));
                colorAtt.sType = VK_ST_RENDERING_ATTACHMENT_INFO_KHR;
                colorAtt.imageView = (uint64_t)(uintptr_t)offView;
                colorAtt.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
                colorAtt.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
                colorAtt.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
                colorAtt.clearValue.color = clearColor;
                MeowVkRenderingInfo ri;
                memset(&ri, 0, sizeof(ri));
                ri.sType = VK_ST_RENDERING_INFO_KHR;
                ri.renderArea.extent.width = extentW;
                ri.renderArea.extent.height = extentH;
                ri.layerCount = 1;
                ri.colorAttachmentCount = 1;
                ri.pColorAttachments = &colorAtt;
                cmdBeginRenderingKHR(cmdBuf, &ri);
            }

            /* MC's descriptor path (F40/F42 PUSH item): one push-descriptor write
             * (storage buffer, written directly, no descriptor pool / set). */
            if (ranPush || ranTex) {
                MeowVkWriteDescriptorSet wds[2];
                memset(wds, 0, sizeof(wds));
                MeowVkDescriptorBufferInfo dbi;
                memset(&dbi, 0, sizeof(dbi));
                MeowVkDescriptorImageInfo dii;
                memset(&dii, 0, sizeof(dii));
                uint32_t writeCount = 0;
                if (ranPush) {
                    dbi.buffer = (uint64_t)(uintptr_t)srcBuffer;
                    dbi.offset = 0;
                    dbi.range = (uint64_t)MEOW_VK_PROBE_UPLOAD_EXTENT *
                                (uint64_t)MEOW_VK_PROBE_UPLOAD_EXTENT * 4ull;
                    wds[writeCount].sType = VK_ST_WRITE_DESCRIPTOR_SET;
                    wds[writeCount].dstSet = 0; /* ignored for push descriptors */
                    wds[writeCount].dstBinding = 0;
                    wds[writeCount].dstArrayElement = 0;
                    wds[writeCount].descriptorCount = 1;
                    wds[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
                    wds[writeCount].pBufferInfo = &dbi;
                    ++writeCount;
                }
                if (ranTex) {
                    /* F52: the sampled texture as a COMBINED_IMAGE_SAMPLER
                     * (binding 1); layout GENERAL, MC's sampled layout. */
                    dii.sampler = (uint64_t)(uintptr_t)texSampler;
                    dii.imageView = (uint64_t)(uintptr_t)texView;
                    dii.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
                    wds[writeCount].sType = VK_ST_WRITE_DESCRIPTOR_SET;
                    wds[writeCount].dstSet = 0;
                    wds[writeCount].dstBinding = 1;
                    wds[writeCount].dstArrayElement = 0;
                    wds[writeCount].descriptorCount = 1;
                    wds[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                    wds[writeCount].pImageInfo = &dii;
                    ++writeCount;
                }
                cmdPushDescriptorSetKHR(cmdBuf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeLayout, 0,
                                        writeCount, wds);
            }

            if (ranDr) {
                cmdEndRenderingKHR(cmdBuf);
            }
            if (ranTs) {
                cmdWriteTimestamp2(cmdBuf, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, queryPool, 2);
            }

            /* offscreen: GENERAL -> TRANSFER_SRC_OPTIMAL */
            b2.srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
            b2.srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
            b2.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
            b2.dstAccessMask = VK_ACCESS_2_TRANSFER_READ_BIT;
            b2.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
            b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            b2.image = (uint64_t)(uintptr_t)offImage;
            cmdPipelineBarrier2(cmdBuf, &dep);

            /* F37: with submit=queue2, end the render (stage A) command buffer
             * here and open the blit (stage B) one; stage B carries the acquire
             * wait and the present/timeline signals. */
            void* tail = cmdBuf;
            if (splitCb) {
                if (endCommandBuffer(cmdBuf) != VK_OK) {
                    rcSub = -997;
                    subRc[f] = rcSub;
                    doneFrames = f;
                    failFrame = f;
                    failSub = rcSub;
                    break;
                }
                if (resetCommandBuffer(blitBuf, 0) != VK_OK ||
                    beginCommandBuffer(blitBuf, &cbbi) != VK_OK) {
                    rcSub = -998;
                    subRc[f] = rcSub;
                    doneFrames = f;
                    failFrame = f;
                    failSub = rcSub;
                    break;
                }
                tail = blitBuf;
                /* acquired swapchain image: UNDEFINED -> TRANSFER_DST (stage B) */
                b2.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
                b2.srcAccessMask = 0;
                b2.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
                b2.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
                b2.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
                b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                b2.image = (uint64_t)(uintptr_t)images[imageIndex];
                cmdPipelineBarrier2(tail, &dep);
            }

            if (!tailNoWrite) {
            if (mcNoBlit) {
                /* F65: identical barriers and identical entry topology -- only the
                 * swapchain write changes: in-place clear instead of the offscreen
                 * blit. Valid because the barrier just above put the acquired image
                 * in TRANSFER_DST_OPTIMAL, which is exactly what a clear needs. */
                cmdClearColorImage(tail, images[imageIndex],
                                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clearColor, 1, &range);
            } else {
                MeowVkImageBlit blit;
                memset(&blit, 0, sizeof(blit));
                blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                blit.srcSubresource.mipLevel = 0;
                blit.srcSubresource.baseArrayLayer = 0;
                blit.srcSubresource.layerCount = 1;
                blit.srcOffsets[1].x = (int32_t)extentW;
                blit.srcOffsets[1].y = (int32_t)extentH;
                blit.srcOffsets[1].z = 1;
                blit.dstSubresource = blit.srcSubresource;
                blit.dstOffsets[1].x = (int32_t)extentW;
                blit.dstOffsets[1].y = (int32_t)extentH;
                blit.dstOffsets[1].z = 1;
                cmdBlitImage(tail, offImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                             images[imageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                             VK_FILTER_NEAREST);
            }
            }

            /* swapchain: TRANSFER_DST_OPTIMAL -> PRESENT_SRC_KHR */
            b2.srcStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
            b2.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
            b2.dstStageMask = VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT;
            b2.dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT;
            b2.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            b2.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
            b2.image = (uint64_t)(uintptr_t)images[imageIndex];
            cmdPipelineBarrier2(tail, &dep);

            if (ranTs && !tailNoTs) {
                cmdWriteTimestamp2(tail, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, queryPool, 3);
            }
        } else {
        MeowVkImageMemoryBarrier toDst;
        memset(&toDst, 0, sizeof(toDst));
        toDst.sType = VK_ST_IMAGE_MEMORY_BARRIER;
        toDst.srcAccessMask = 0;
        toDst.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toDst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        toDst.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toDst.srcQueueFamilyIndex = 0xFFFFFFFFu;
        toDst.dstQueueFamilyIndex = 0xFFFFFFFFu;
        toDst.image = (uint64_t)(uintptr_t)images[imageIndex];
        toDst.subresourceRange = range;
        cmdPipelineBarrier(cmdBuf, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                           VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &toDst);
        if (useBlit) {
            /* offscreen: UNDEFINED -> TRANSFER_DST_OPTIMAL, clear to a solid
             * colour (the write path this ICD honours) */
            MeowVkImageMemoryBarrier offToDst;
            memset(&offToDst, 0, sizeof(offToDst));
            offToDst.sType = VK_ST_IMAGE_MEMORY_BARRIER;
            offToDst.srcAccessMask = 0;
            offToDst.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            offToDst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            offToDst.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            offToDst.srcQueueFamilyIndex = 0xFFFFFFFFu;
            offToDst.dstQueueFamilyIndex = 0xFFFFFFFFu;
            offToDst.image = (uint64_t)(uintptr_t)offImage;
            offToDst.subresourceRange = range;
            cmdPipelineBarrier(cmdBuf, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                               VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &offToDst);
            cmdClearColorImage(cmdBuf, offImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clearColor,
                               1, &range);
            /* offscreen: TRANSFER_DST_OPTIMAL -> TRANSFER_SRC_OPTIMAL */
            MeowVkImageMemoryBarrier offToSrc;
            memset(&offToSrc, 0, sizeof(offToSrc));
            offToSrc.sType = VK_ST_IMAGE_MEMORY_BARRIER;
            offToSrc.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            offToSrc.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            offToSrc.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            offToSrc.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            offToSrc.srcQueueFamilyIndex = 0xFFFFFFFFu;
            offToSrc.dstQueueFamilyIndex = 0xFFFFFFFFu;
            offToSrc.image = (uint64_t)(uintptr_t)offImage;
            offToSrc.subresourceRange = range;
            cmdPipelineBarrier(cmdBuf, VK_PIPELINE_STAGE_TRANSFER_BIT,
                               VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &offToSrc);
            /* offscreen (TRANSFER_SRC_OPTIMAL) -> swapchain image
             * (TRANSFER_DST_OPTIMAL), identical extent, NEAREST filter */
            MeowVkImageBlit blit;
            memset(&blit, 0, sizeof(blit));
            blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.srcSubresource.mipLevel = 0;
            blit.srcSubresource.baseArrayLayer = 0;
            blit.srcSubresource.layerCount = 1;
            blit.srcOffsets[0].x = 0;
            blit.srcOffsets[0].y = 0;
            blit.srcOffsets[0].z = 0;
            blit.srcOffsets[1].x = (int32_t)extentW;
            blit.srcOffsets[1].y = (int32_t)extentH;
            blit.srcOffsets[1].z = 1;
            blit.dstSubresource = blit.srcSubresource;
            blit.dstOffsets[0].x = 0;
            blit.dstOffsets[0].y = 0;
            blit.dstOffsets[0].z = 0;
            blit.dstOffsets[1].x = (int32_t)extentW;
            blit.dstOffsets[1].y = (int32_t)extentH;
            blit.dstOffsets[1].z = 1;
            cmdBlitImage(cmdBuf, offImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                         images[imageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                         VK_FILTER_NEAREST);
        } else {
            cmdClearColorImage(cmdBuf, images[imageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                               &clearColor, 1, &range);
        }
        MeowVkImageMemoryBarrier toPresent;
        memset(&toPresent, 0, sizeof(toPresent));
        toPresent.sType = VK_ST_IMAGE_MEMORY_BARRIER;
        toPresent.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toPresent.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        toPresent.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toPresent.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        toPresent.srcQueueFamilyIndex = 0xFFFFFFFFu;
        toPresent.dstQueueFamilyIndex = 0xFFFFFFFFu;
        toPresent.image = (uint64_t)(uintptr_t)images[imageIndex];
        toPresent.subresourceRange = range;
        cmdPipelineBarrier(cmdBuf, VK_PIPELINE_STAGE_TRANSFER_BIT,
                           VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1,
                           &toPresent);
        }
        /* F37: with splitCb both command buffers are already ended above. */
        if (!splitCb && endCommandBuffer(cmdBuf) != VK_OK) {
            rcSub = -997;
            subRc[f] = rcSub;
            doneFrames = f;
            failFrame = f;
            failSub = rcSub;
            break;
        }

        const uint32_t waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        const uint64_t cmdHandle = (uint64_t)(uintptr_t)cmdBuf;
        const uint64_t blitHandle = (uint64_t)(uintptr_t)blitBuf;
        const uint64_t sigSem = (uint64_t)(uintptr_t)semRender;
        const uint64_t waitSem = (uint64_t)(uintptr_t)semAcquire;
        const uint64_t tlSem = (uint64_t)(uintptr_t)semTimeline;
        const uint64_t tlValue = (uint64_t)f + 1; /* v1, v2, ... (64-bit) */
        /* F63 mc pattern: wait the value the PREVIOUS frame submitted (= f; frame
         * f-1 signalled f). It is the probe's lax equivalent of MC's v-2 wait and
         * keeps 2 submits in flight; own waits the value just submitted (f+1). */
        const uint64_t tlWaitValue = patternActive ? (f > 0 ? (uint64_t)f : 0ull) : tlValue;
        if (useQueue2Submit) {
            /* F37: sync2 submit (MC's). Structs/sTypes mirror vulkan_core.h
             * :7581-:7607; field order/padding asserted at file scope. */
            MeowVkSemaphoreSubmitInfo waitInfo;
            memset(&waitInfo, 0, sizeof(waitInfo));
            waitInfo.sType = VK_ST_SEMAPHORE_SUBMIT_INFO;
            waitInfo.semaphore = waitSem;
            waitInfo.value = 0; /* binary wait: value ignored */
            waitInfo.stageMask = splitCb ? VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
                                         : VK_PIPELINE_STAGE_2_TRANSFER_BIT;

            MeowVkSemaphoreSubmitInfo sigInfos[2];
            memset(sigInfos, 0, sizeof(sigInfos));
            sigInfos[0].sType = VK_ST_SEMAPHORE_SUBMIT_INFO;
            sigInfos[0].semaphore = sigSem;
            sigInfos[0].value = 0; /* binary signal */
            sigInfos[0].stageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
            uint32_t sigCount = 1;
            if (useTimeline) {
                sigInfos[1].sType = VK_ST_SEMAPHORE_SUBMIT_INFO;
                sigInfos[1].semaphore = tlSem;
                sigInfos[1].value = tlValue;
                sigInfos[1].stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
                sigCount = 2;
            }

            MeowVkCommandBufferSubmitInfo cbInfos[2];
            memset(cbInfos, 0, sizeof(cbInfos));
            cbInfos[0].sType = VK_ST_COMMAND_BUFFER_SUBMIT_INFO;
            cbInfos[0].commandBuffer = cmdHandle;
            cbInfos[1].sType = VK_ST_COMMAND_BUFFER_SUBMIT_INFO;
            cbInfos[1].commandBuffer = blitHandle;

            MeowVkSubmitInfo2 si2[2];
            memset(si2, 0, sizeof(si2));
            if (splitCb) {
                /* A8 shape: stage A = render CB (no waits/signals); stage B =
                 * acquire wait + blit CB + present/timeline signals. */
                si2[0].sType = VK_ST_SUBMIT_INFO_2;
                si2[0].commandBufferInfoCount = 1;
                si2[0].pCommandBufferInfos = &cbInfos[0];
                si2[1].sType = VK_ST_SUBMIT_INFO_2;
                si2[1].waitSemaphoreInfoCount = 1;
                si2[1].pWaitSemaphoreInfos = &waitInfo;
                si2[1].commandBufferInfoCount = 1;
                si2[1].pCommandBufferInfos = &cbInfos[1];
                si2[1].signalSemaphoreInfoCount = sigCount;
                si2[1].pSignalSemaphoreInfos = sigInfos;
                rcSub = queueSubmit2(queue, 2, si2, patternActive ? NULL : fence);
            } else {
                si2[0].sType = VK_ST_SUBMIT_INFO_2;
                si2[0].waitSemaphoreInfoCount = 1;
                si2[0].pWaitSemaphoreInfos = &waitInfo;
                si2[0].commandBufferInfoCount = 1;
                si2[0].pCommandBufferInfos = &cbInfos[0];
                si2[0].signalSemaphoreInfoCount = sigCount;
                si2[0].pSignalSemaphoreInfos = sigInfos;
                rcSub = queueSubmit2(queue, 1, si2, patternActive ? NULL : fence);
            }
        } else {
            const uint64_t waitValues[1] = { 0 };     /* binary wait value is ignored */
            const uint64_t signalValues[2] = { 0, tlValue };
            const uint64_t signalSems[2] = { sigSem, tlSem };
            MeowVkTimelineSemaphoreSubmitInfo tsi;
            memset(&tsi, 0, sizeof(tsi));
            tsi.sType = VK_ST_TIMELINE_SEMAPHORE_SUBMIT_INFO;
            tsi.waitSemaphoreValueCount = 1;
            tsi.pWaitSemaphoreValues = waitValues;
            tsi.signalSemaphoreValueCount = 2;
            tsi.pSignalSemaphoreValues = signalValues;
            MeowVkSubmitInfo si;
            memset(&si, 0, sizeof(si));
            si.sType = VK_ST_SUBMIT_INFO;
            si.waitSemaphoreCount = 1;
            si.pWaitSemaphores = &waitSem;
            si.pWaitDstStageMask = &waitStage;
            si.commandBufferCount = 1;
            si.pCommandBuffers = &cmdHandle;
            if (useTimeline) {
                si.pNext = &tsi;
                si.signalSemaphoreCount = 2;
                si.pSignalSemaphores = signalSems;
            } else {
                si.signalSemaphoreCount = 1;
                si.pSignalSemaphores = &sigSem;
            }
            rcSub = queueSubmit(queue, 1, &si, patternActive ? NULL : fence);
        }
        /* F39: a submit call has now really been issued (both branches above end
         * in exactly one). Record the first real non-OK rc so the summary can
         * tell a submit failure apart from a pre-submit / setup failure. */
        if (patternRecord && f < MEOW_VK_PROBE_PAT_FRAMES) {
            g_cell.patSub[f] = rcSub;
        }
        ++submitsAttempted;
        if (rcSub != VK_OK) {
            submitFailRc = rcSub;
        }
        subRc[f] = rcSub;
        if (rcSub != VK_OK) {
            doneFrames = f;
            failFrame = f;
            failSub = rcSub;
            break;
        }

        /* F63: the mc pattern presents BEFORE the timeline wait (the task's MC
         * sequence); own keeps the legacy wait-then-present order. */
        if (useTimeline && !patternActive) {
            MeowVkSemaphoreWaitInfo swi;
            memset(&swi, 0, sizeof(swi));
            swi.sType = VK_ST_SEMAPHORE_WAIT_INFO;
            swi.flags = 0;
            swi.semaphoreCount = 1;
            swi.pSemaphores = &tlSem;
            swi.pValues = &tlWaitValue;
            rcTl = waitSemaphores(device, &swi, MEOW_VK_PROBE_TL_WAIT_NS);
            tlRc[f] = rcTl;
            if (patternRecord && f < MEOW_VK_PROBE_PAT_FRAMES) {
                g_cell.patTl[f] = rcTl;
            }
            if (rcTl != VK_OK) {
                doneFrames = f;
                failFrame = f;
                failTl = rcTl;
                break;
            }
        }

        MeowVkPresentInfoKHR pi;
        memset(&pi, 0, sizeof(pi));
        pi.sType = VK_ST_PRESENT_INFO_KHR;
        pi.waitSemaphoreCount = 1;
        pi.pWaitSemaphores = &sigSem;
        pi.swapchainCount = 1;
        const uint64_t swapchainHandle = (uint64_t)(uintptr_t)swapchain;
        pi.pSwapchains = &swapchainHandle;
        pi.pImageIndices = &imageIndex;
        rcPre = queuePresent(queue, &pi);
        preRc[f] = rcPre;
        if (patternRecord) {
            ++g_cell.patPresTotal;
            if (f < MEOW_VK_PROBE_PAT_FRAMES) {
                g_cell.patPres[f] = rcPre;
            }
        }
        doneFrames = f + 1;
        if (rcPre != VK_OK && rcPre != VK_SUBOPTIMAL_KHR) {
            failFrame = f;
            failPre = rcPre;
            break;
        }

        if (useTimeline && patternActive) {
            MeowVkSemaphoreWaitInfo swi;
            memset(&swi, 0, sizeof(swi));
            swi.sType = VK_ST_SEMAPHORE_WAIT_INFO;
            swi.flags = 0;
            swi.semaphoreCount = 1;
            swi.pSemaphores = &tlSem;
            swi.pValues = &tlWaitValue;
            rcTl = waitSemaphores(device, &swi, MEOW_VK_PROBE_TL_WAIT_NS);
            tlRc[f] = rcTl;
            if (f < MEOW_VK_PROBE_PAT_FRAMES) {
                g_cell.patTl[f] = rcTl;
            }
            if (rcTl != VK_OK) {
                doneFrames = f;
                failFrame = f;
                failTl = rcTl;
                break;
            }
        }
    }

    /* F38: fold this cell's outcome into g_cell for the matrix summary.
     * F39: also record whether a submit was actually issued (see cell_reached_submit). */
    g_cell.framesDone = doneFrames;
    if (patternRecord) {
        int recCount = doneFrames;
        if (failFrame >= 0 && recCount <= failFrame) {
            recCount = failFrame + 1;
        }
        if (recCount > frames) {
            recCount = frames;
        }
        if (recCount > MEOW_VK_PROBE_PAT_FRAMES) {
            recCount = MEOW_VK_PROBE_PAT_FRAMES;
        }
        g_cell.patCount = recCount;
    }
    g_cell.submitTested = (submitsAttempted > 0);
    g_cell.submitFailRc = submitFailRc;
    if (doneFrames > 0) {
        g_cell.f0Acq = acqRc[0];
        g_cell.f0Sub = subRc[0];
        g_cell.f0Tl = tlRc[0];
        g_cell.f0Pres = preRc[0];
    }
    if (failFrame >= 0) {
        g_cell.failFrame = failFrame;
        if (failAcq != VK_OK) {
            g_cell.failKind = 3;
            g_cell.failRc = failAcq;
        } else if (failSub != VK_OK) {
            g_cell.failKind = 4;
            g_cell.failRc = failSub;
        } else if (failTl != VK_OK) {
            g_cell.failKind = 5;
            g_cell.failRc = failTl;
        } else {
            g_cell.failKind = 6;
            g_cell.failRc = failPre;
        }
    } else if (doneFrames >= frames) {
        g_cell.allOk = 1;
    }

    /* 10. summary: first 3 + failure point + last 3 */
    int firstN = doneFrames < 3 ? doneFrames : 3;
    for (int i = 0; i < firstN; ++i) {
        sb_add(&sb, "f%d acq=%d sub=%d wf=%d tl=%d pres=%d\n", i, acqRc[i], subRc[i], fenceRc[i],
               tlRc[i], preRc[i]);
    }
    if (failFrame >= 0) {
        if (failFrame >= 3) {
            sb_add(&sb, "f%d acq=%d sub=%d wf=%d tl=%d pres=%d\n", failFrame, acqRc[failFrame],
                   subRc[failFrame], fenceRc[failFrame], tlRc[failFrame], preRc[failFrame]);
        }
        if (failAcq != VK_OK) {
            sb_add(&sb, "FAIL at frame %d: acquire rc=%d (%s)\n", failFrame, failAcq,
                   rc_name(failAcq));
        } else if (failSub != VK_OK) {
            sb_add(&sb, "FAIL at frame %d: submit rc=%d (%s)\n", failFrame, failSub,
                   rc_name(failSub));
        } else if (failTl != VK_OK) {
            sb_add(&sb, "FAIL at frame %d: timelinewait rc=%d (%s)\n", failFrame, failTl,
                   rc_name(failTl));
        } else {
            sb_add(&sb, "FAIL at frame %d: present rc=%d (%s)\n", failFrame, failPre,
                   rc_name(failPre));
        }
    } else {
        int lastN = doneFrames < 3 ? doneFrames : 3;
        for (int i = doneFrames - lastN; i < doneFrames; ++i) {
            sb_add(&sb, "f%d acq=%d sub=%d wf=%d tl=%d pres=%d\n", i, acqRc[i], subRc[i],
                   fenceRc[i], tlRc[i], preRc[i]);
        }
    }
    if (failFrame < 0 && doneFrames >= frames) {
        sb_add(&sb, "RESULT: all %d frames OK\n", doneFrames);
    } else if (failFrame >= 0) {
        sb_add(&sb, "RESULT: frame %d failed\n", failFrame);
    } else {
        sb_add(&sb, "RESULT: stopped after %d/%d frames (no rc marked failure)\n", doneFrames,
               frames);
    }
    free(acqRc);
    free(subRc);
    free(preRc);
    free(fenceRc);
    free(tlRc);
    free(images);

done:
    /* 11. thorough teardown (every exit path) */
    if (device != NULL) {
        if (deviceWaitIdle != NULL) {
            deviceWaitIdle(device);
        }
        if (fence != NULL && destroyFence != NULL) {
            destroyFence(device, fence, NULL);
        }
        if (offImage != NULL && destroyImage != NULL) {
            destroyImage(device, offImage, NULL);
        }
        if (offMemory != NULL && freeMemory != NULL) {
            freeMemory(device, offMemory, NULL);
        }
        /* F33 shape=mc resources: objects before their backing memory. */
        if (offView != NULL && destroyImageView != NULL) {
            destroyImageView(device, offView, NULL);
        }
        if (uploadImage != NULL && destroyImage != NULL) {
            destroyImage(device, uploadImage, NULL);
        }
        if (srcBuffer != NULL && destroyBuffer != NULL) {
            destroyBuffer(device, srcBuffer, NULL);
        }
        if (pipeLayout != NULL && destroyPipelineLayout != NULL) {
            destroyPipelineLayout(device, pipeLayout, NULL);
        }
        if (descLayout != NULL && destroyDescriptorSetLayout != NULL) {
            destroyDescriptorSetLayout(device, descLayout, NULL);
        }
        if (queryPool != NULL && destroyQueryPool != NULL) {
            destroyQueryPool(device, queryPool, NULL);
        }
        /* F52 textured resources: sampler / view / image / buffer before memory. */
        if (texSampler != NULL && destroySampler != NULL) {
            destroySampler(device, texSampler, NULL);
        }
        if (texView != NULL && destroyImageView != NULL) {
            destroyImageView(device, texView, NULL);
        }
        if (texImage != NULL && destroyImage != NULL) {
            destroyImage(device, texImage, NULL);
        }
        if (texBuffer != NULL && destroyBuffer != NULL) {
            destroyBuffer(device, texBuffer, NULL);
        }
        if (texMemory != NULL && freeMemory != NULL) {
            freeMemory(device, texMemory, NULL);
        }
        if (texBufMemory != NULL && freeMemory != NULL) {
            freeMemory(device, texBufMemory, NULL);
        }
        if (uploadMemory != NULL && freeMemory != NULL) {
            freeMemory(device, uploadMemory, NULL);
        }
        if (srcMemory != NULL && freeMemory != NULL) {
            freeMemory(device, srcMemory, NULL);
        }
        if (semAcquire != NULL && destroySemaphore != NULL) {
            destroySemaphore(device, semAcquire, NULL);
        }
        if (semRender != NULL && destroySemaphore != NULL) {
            destroySemaphore(device, semRender, NULL);
        }
        if (semTimeline != NULL && destroySemaphore != NULL) {
            destroySemaphore(device, semTimeline, NULL);
        }
        if (cmdPool != NULL && destroyCommandPool != NULL) {
            destroyCommandPool(device, cmdPool, NULL);
        }
        if (imageViews != NULL && destroyImageView != NULL) {
            for (uint32_t i = 0; i < imageCount; ++i) {
                if (imageViews[i] != NULL) {
                    destroyImageView(device, imageViews[i], NULL);
                }
            }
        }
        if (swapchain != NULL && destroySwapchain != NULL) {
            destroySwapchain(device, swapchain, NULL);
        }
        if (deviceCreated && destroyDevice != NULL) {
            destroyDevice(device, NULL);
        }
    }
    if (imageViews != NULL) {
        free(imageViews);
    }
    if (surface != NULL && surfaceCreated && destroySurface != NULL) {
        destroySurface(instance, surface, NULL);
    }
    if (window != NULL) {
        OH_NativeWindow_DestroyNativeWindow(window);
    }
    if (instance != NULL && destroyInstance != NULL) {
        destroyInstance(instance, NULL);
    }
    if (loader != NULL) {
        dlclose(loader);
    }

    /* F38: keep the cell's own last diagnostic line (the setup reason on an
     * early exit) and its parsed axes; the verbose body report is intentionally
     * discarded so the on-screen report stays one line per cell. */
    cell_capture_last_line(report);
    g_cell.libShim = useShim;
    g_cell.submitQueue2 = useQueue2Submit;
    g_cell.sync2ToV1 = sync2ToV1;   /* F44: reported, never acted on by the probe */
    g_cell.sync2ToV1Barrier = sync2ToV1Barrier; /* F47: -1 = env unset (falls back) */
    g_cell.sync2ToV1Submit = sync2ToV1Submit;   /* F47: -1 = env unset (falls back) */
    g_cell.syncTimeline = useTimeline; /* F46: 1 = timeline semaphore, 0 = binary */
    /* F40: record the sub-shape this cell ran so the matrix line and the
     * generated SUMMARY can name exactly which item was removed. */
    g_cell.mcDr = mcDr;
    g_cell.mcPush = mcPush;
    g_cell.mcUpload = mcUpload;
    g_cell.mcTs = mcTs;
    g_cell.mcDiv = mcDiv;
    g_cell.mcTex = mcTex;
}

/* ------------------------------------------------------------------ */
/* F43 one-item-only matrix driver. With NONE of MEOW_VK_PROBE_LIB,     */
/* MEOW_VK_PROBE_SUBMIT or MEOW_VK_PROBE_DEVFEAT set, one press runs six */
/* cells (only lib=shim + submit=queue2 + devfeat=fake): all-on, then    */
/* five cells that each keep exactly one mc item (DR / PUSH / UPLOAD /   */
/* DIV / TS). The complement of the F40 all-minus-one bisect. It prints  */
/* one compact line each (enabled[..] / ran[..]) plus a generated        */
/* SUMMARY that names every comparable one-item cell that came out OK.   */
/* With any of those envs set it runs a single cell using the user's     */
/* values (the F42 four-cell semantics stay reachable that way).         */
/* ------------------------------------------------------------------ */
static void* probe_main(void* arg) {
    MeowVkProbeJob* job = (MeowVkProbeJob*)arg;
    int64_t surfaceId = job->surfaceId;
    int frames = job->frames;
    free(job);

    int envLib = getenv("MEOW_VK_PROBE_LIB") != NULL;
    int envSubmit = getenv("MEOW_VK_PROBE_SUBMIT") != NULL;
    int envDevfeat = getenv("MEOW_VK_PROBE_DEVFEAT") != NULL;
    int envPattern = getenv("MEOW_VK_PROBE_PATTERN") != NULL;
    int matrixMode = (!envLib && !envSubmit && !envDevfeat && !envPattern);
    if (matrixMode && frames > 30) {
        frames = 30; /* the matrix only needs to see whether frames 0-2 fail */
    }
    if (frames <= 0) {
        frames = matrixMode ? 30 : 120;
    }

    char report[MEOW_VK_PROBE_RESULT_CAP];
    MeowSb sb;
    sb_reset(&sb, report, sizeof(report));
    {
        const char* shape = getenv("MEOW_VK_PROBE_SHAPE");
        const char* pipeline = getenv("MEOW_VK_PROBE_PIPELINE");
        const char* sync = getenv("MEOW_VK_PROBE_SYNC");
        const char* devfeat = getenv("MEOW_VK_PROBE_DEVFEAT");
        const char* pattern = getenv("MEOW_VK_PROBE_PATTERN");
        const char* sync2v1 = getenv("MEOW_VK_SYNC2_TO_V1");
        const char* sync2v1b = getenv("MEOW_VK_SYNC2_TO_V1_BARRIER");
        const char* sync2v1s = getenv("MEOW_VK_SYNC2_TO_V1_SUBMIT");
        sb_add(&sb,
               "MeowVkProbe report F63+F65+F65b+F67 (mode=%s) frames=%d shape=%s pipeline=%s sync=%s"
               " pattern_env=%s devfeat_env=%s sync2v1_env=%s sync2v1B_env=%s"
               " sync2v1S_env=%s\n",
               matrixMode ? "one-item-plus-pattern-matrix" : "single", frames,
               shape != NULL ? shape : "mc(default)",
               pipeline != NULL ? pipeline : "blitImage(default)",
               sync != NULL ? sync : "timeline(default)",
               pattern != NULL ? pattern : "mc(default)",
               devfeat != NULL ? devfeat : "(default)",
               sync2v1 != NULL ? sync2v1 : "(default)",
               sync2v1b != NULL ? sync2v1b : "(default)",
               sync2v1s != NULL ? sync2v1s : "(default)");
    }
    if (matrixMode) {
        sb_add(&sb,
               "matrix: F47 one-item-only + 6 confirmation cells (lib=shim devfeat=fake)"
               " cell1 all-on, cell2 only DR, cell3 only PUSH, cell4 only UPLOAD,"
               " cell5 only DIV, cell6 only TS, cell7 all-on+v1+timeline,"
               " cell8 all-on+queue2+sync2v1+timeline, cell9 all-on+queue2+sync2v1+binary,"
               " cell10 all-on+v1+timeline, cell11 all-on+v1+barrier-translated-only,"
               " cell12 all-on+queue2+submit-translated-only, cell13 only TEX"
               " (F52 textured item: vkCmdCopyBufferToImage + COMBINED_IMAGE_SAMPLER push),"
               " then F63 PATTERN cells 14=mc / 15=own (all-on, 60 frames, per-frame"
               " telemetry), then F65 cell16 = cell8 with ONLY the swapchain write"
               " flipped (MC_BLIT=0: in-place clear instead of the offscreen"
               " vkCmdBlitImage; same 2-entry shape, same barriers, 60 frames)"
               " -- a single-variable test of whether the blit command is what the"
               " ICD rejects in the second submit entry; result: it is NOT (cell 16"
               " failed exactly like cell 8), so F65b cell17 = cell16 with"
               " MEOW_VK_PROBE_NOSPLIT=1: same mc shape and still submit=queue2, but"
               " ONE submit entry carries the acquire wait + every mc command buffer +"
               " every signal (the shape a merged translation produces); result: OK(60)"
               " and the same 2-entry frames still fail, so F67 bisects the split tail's"
               " SECOND command buffer: cell18 = cell8 with TAIL=nots (no timestamp),"
               " cell19 = cell8 with TAIL=nobar (no blit/clear write; barriers+timestamp"
               " only) -- one run names the exact command the ICD rejects\n");
    }

    MeowVkProbeCell cells[19];
    int cellCount = 0;
    if (matrixMode) {
        /* F44's F43 ONE-ITEM-ONLY matrix (cells 1..6, unchanged in shape) plus SIX
         * confirmation cells (7/8 from F44; 9/10 from F46; 11/12 from F47). ONLY
         * lib=shim + devfeat=fake; every cell rebuilds and tears down its own instance /
         * surface / device / swapchain / resources, so a failure cannot leak into the next.
         * The F40 sub-switches and the F42 per-item ran* logic are reused unchanged for 1..6.
         *   cell 1  all five items on, queue2, translation OFF (F43 baseline; frame-0 -1)
         *   cell 2  only DR
         *   cell 3  only PUSH
         *   cell 4  only UPLOAD
         *   cell 5  only DIV            (no mc command in the frame body at all)
         *   cell 6  only TS             (needs viewSync2; skipped + annotated when absent)
         *   cell 7  all five on, submit=v1,     translation OFF, sync=timeline => OK (F33)
         *   cell 8  all five on, submit=queue2, BOTH translations ON, sync=timeline => the
         *           on-device -1 under test (F44/F45)
         *   cell 9  all five on, submit=queue2, BOTH translations ON, sync=BINARY => no
         *           timeline semaphore at all (F46: is the -1 tied to the timeline value?)
         *   cell 10 all five on, submit=v1,     translation OFF, sync=timeline => native v1 +
         *           timeline control (F46; equal to cell 7 by construction)
         *   cell 11 all five on, submit=v1,     BARRIER translation ON / SUBMIT OFF, timeline
         *           => only the barrier translation product is exercised (F47)
         *   cell 12 all five on, submit=queue2, BARRIER translation OFF / SUBMIT ON, timeline
         *           => only the submit translation product is exercised (F47)
         * The legacy MEOW_VK_SYNC2_TO_V1 keeps the F44 cells 1..10 byte-identical; the two new
         * per-type envs are ALSO set on every cell (equal to the legacy value for 1..10, so
         * they simply agree) and diverge only on 11/12. All setenv calls happen BEFORE
         * probe_run_one() -- which is before the shim is dlopen()ed and before the first call
         * into it, i.e. before the shim reads any env in its first-call init -- so the
         * ordering the (uncached) switch semantics require is satisfied. */
        /* F63: cells 1..13 keep their exact shape and are pinned to pattern=own
         * (g_patternRecord=0 => no telemetry, no behaviour change); cells 14/15
         * are the new PATTERN A/B (all-on mc shape), 60 frames each, with
         * g_patternRecord=1 so probe_run_one records the per-frame samples. */
        /* F65: the array gained a 13th column = the swapchain write (1 = the
         * offscreen->swapchain blit, i.e. every pre-F65 behaviour; 0 = the in-place
         * clear). Cells 1..15 therefore keep "1" and are byte-identical to F63.
         * Cell 16 is cell 8 with ONLY that column flipped: same all-on mc shape,
         * same queue2 submit, same BOTH translations on, same timeline sync, same
         * 60 frames + telemetry -- so the blit command is the single variable. */
        static const char* const f47Cell[19][15] = {
            /* dr    push  upload ts    div   submit    sync2v1  sync      B     S     tex   pattern  blit  nosplit tail */
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "0",  "timeline", "0", "0", "1", "own", "1", "0", "full" }, /* 1*/
            {  "1",  "0",  "0",    "0",  "0",  "queue2", "0",  "timeline", "0", "0", "0", "own", "1", "0", "full" }, /* 2*/
            {  "0",  "1",  "0",    "0",  "0",  "queue2", "0",  "timeline", "0", "0", "0", "own", "1", "0", "full" }, /* 3*/
            {  "0",  "0",  "1",    "0",  "0",  "queue2", "0",  "timeline", "0", "0", "0", "own", "1", "0", "full" }, /* 4*/
            {  "0",  "0",  "0",    "0",  "1",  "queue2", "0",  "timeline", "0", "0", "0", "own", "1", "0", "full" }, /* 5*/
            {  "0",  "0",  "0",    "1",  "0",  "queue2", "0",  "timeline", "0", "0", "0", "own", "1", "0", "full" }, /* 6*/
            {  "1",  "1",  "1",    "1",  "1",  "v1",     "0",  "timeline", "0", "0", "1", "own", "1", "0", "full" }, /* 7*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "1",  "timeline", "1", "1", "1", "own", "1", "0", "full" }, /* 8*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "1",  "binary",   "1", "1", "1", "own", "1", "0", "full" }, /* 9*/
            {  "1",  "1",  "1",    "1",  "1",  "v1",     "0",  "timeline", "0", "0", "1", "own", "1", "0", "full" }, /*10*/
            {  "1",  "1",  "1",    "1",  "1",  "v1",     "0",  "timeline", "1", "0", "1", "own", "1", "0", "full" }, /*11*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "0",  "timeline", "0", "1", "1", "own", "1", "0", "full" }, /*12*/
            {  "0",  "0",  "0",    "0",  "0",  "queue2", "0",  "timeline", "0", "0", "1", "own", "1", "0", "full" }, /*13*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "0",  "timeline", "0", "0", "1", "mc" , "1", "0", "full" }, /*14*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "0",  "timeline", "0", "0", "1", "own", "1", "0", "full" }, /*15*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "1",  "timeline", "1", "1", "1", "own", "0", "0", "full" }, /*16*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "1",  "timeline", "1", "1", "1", "own", "0", "1", "full" }, /*17*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "1",  "timeline", "1", "1", "1", "own", "1", "0", "nots" }, /*18*/
            {  "1",  "1",  "1",    "1",  "1",  "queue2", "1",  "timeline", "1", "1", "1", "own", "1", "0", "nobar" }, /*19*/
        };
        setenv("MEOW_VK_PROBE_LIB", "shim", 1);
        setenv("MEOW_VK_PROBE_SHAPE", "mc", 1);
        setenv("MEOW_VK_PROBE_DEVFEAT", "fake", 1);
        for (int ci = 0; ci < 19; ++ci) {
            setenv("MEOW_VK_PROBE_MC_DR", f47Cell[ci][0], 1);
            setenv("MEOW_VK_PROBE_MC_PUSH", f47Cell[ci][1], 1);
            setenv("MEOW_VK_PROBE_MC_UPLOAD", f47Cell[ci][2], 1);
            setenv("MEOW_VK_PROBE_MC_TS", f47Cell[ci][3], 1);
            setenv("MEOW_VK_PROBE_MC_DIV", f47Cell[ci][4], 1);
            setenv("MEOW_VK_PROBE_SUBMIT", f47Cell[ci][5], 1);
            setenv("MEOW_VK_SYNC2_TO_V1", f47Cell[ci][6], 1);
            setenv("MEOW_VK_PROBE_SYNC", f47Cell[ci][7], 1);
            setenv("MEOW_VK_SYNC2_TO_V1_BARRIER", f47Cell[ci][8], 1);
            setenv("MEOW_VK_SYNC2_TO_V1_SUBMIT", f47Cell[ci][9], 1);
            setenv("MEOW_VK_PROBE_TEXTURED", f47Cell[ci][10], 1);
            setenv("MEOW_VK_PROBE_PATTERN", f47Cell[ci][11], 1);
            setenv("MEOW_VK_PROBE_MC_BLIT", f47Cell[ci][12], 1);   /* F65 */
            setenv("MEOW_VK_PROBE_NOSPLIT", f47Cell[ci][13], 1);   /* F65b */
            setenv("MEOW_VK_PROBE_TAIL", f47Cell[ci][14], 1);      /* F67 */
            /* F63: only the two new pattern cells run N=60 and record telemetry. */
            g_patternRecord = (ci >= 13) ? 1 : 0;
            int cellFrames = (ci >= 13) ? 60 : frames;
            probe_run_one(surfaceId, cellFrames);
            cells[cellCount++] = g_cell;
        }
        g_patternRecord = 0;
        unsetenv("MEOW_VK_PROBE_LIB");
        unsetenv("MEOW_VK_PROBE_SUBMIT");
        unsetenv("MEOW_VK_PROBE_SHAPE");
        unsetenv("MEOW_VK_PROBE_DEVFEAT");
        unsetenv("MEOW_VK_PROBE_PATTERN");
        unsetenv("MEOW_VK_PROBE_MC_DR");
        unsetenv("MEOW_VK_PROBE_MC_PUSH");
        unsetenv("MEOW_VK_PROBE_MC_UPLOAD");
        unsetenv("MEOW_VK_PROBE_MC_TS");
        unsetenv("MEOW_VK_PROBE_MC_DIV");
        unsetenv("MEOW_VK_SYNC2_TO_V1");
        unsetenv("MEOW_VK_PROBE_SYNC");
        unsetenv("MEOW_VK_SYNC2_TO_V1_BARRIER");
        unsetenv("MEOW_VK_SYNC2_TO_V1_SUBMIT");
        unsetenv("MEOW_VK_PROBE_TEXTURED");
        unsetenv("MEOW_VK_PROBE_MC_BLIT");   /* F65 */
        unsetenv("MEOW_VK_PROBE_NOSPLIT");   /* F65b */
        unsetenv("MEOW_VK_PROBE_TAIL");      /* F67 */
    } else {
        /* F63: a single-cell run records the pattern telemetry too (the env
         * semantics are unchanged: any of LIB/SUBMIT/DEVFEAT/PATTERN = one cell). */
        g_patternRecord = 1;
        probe_run_one(surfaceId, frames);
        g_patternRecord = 0;
        cells[cellCount++] = g_cell;
    }

    for (int i = 0; i < cellCount; ++i) {
        const MeowVkProbeCell* c = &cells[i];
        char line[640];
        MeowSb ls;
        sb_reset(&ls, line, sizeof(line));
        sb_add(&ls,
               "cell %d: devfeat=%-10s caps[dr=%d sync2=%d push=%d div=%d]"
               " enabled[dr=%d sync2=%d push=%d div=%d]"
               " ran[dr=%d push=%d up=%d ts=%d div=%d tex=%d]"
               " mc[dr=%d push=%d up=%d ts=%d div=%d tex=%d] lib=%-4s submit=%s sync=%s"
               " pattern=%s",
               i + 1, meow_devfeat_name(c->devFeatMode), c->viewDr, c->viewSync2,
               c->viewPushDesc, c->viewDiv, c->capDr, c->capSync2, c->capPushDesc,
               c->capDivisor, c->ranDr, c->ranPush, c->ranUpload, c->ranTs, c->ranDiv,
               c->ranTex, c->mcDr, c->mcPush, c->mcUpload, c->mcTs, c->mcDiv, c->mcTex,
               c->libShim ? "shim" : "raw", c->submitQueue2 ? "queue2" : "v1",
               c->syncTimeline ? "timeline" : "binary",
               c->patRec ? (c->patMcEnv ? "mc" : "own") : "off");
        /* F44: name the shim's sync2->v1 translation state for this cell (-1 = env unset). */
        if (c->sync2ToV1 < 0) {
            sb_add(&ls, " sync2v1=default");
        } else {
            sb_add(&ls, " sync2v1=%d", c->sync2ToV1);
        }
        /* F47: name the per-type translation switches (-1 = env unset => legacy/default). */
        sb_add(&ls, " sync2v1B=%d sync2v1S=%d", c->sync2ToV1Barrier, c->sync2ToV1Submit);
        /* F65: which swapchain write this cell used (1 = in-place clear, no blit). */
        sb_add(&ls, " mcblit=%d", c->mcNoBlit ? 0 : 1);
        /* F65b: how many submit entries the frame used (1 = merged shape). */
        sb_add(&ls, " entries=%d", c->noSplit ? 1 : 2);
        /* F67: which part of the split tail's second CB was kept (0 full, 1 no-ts, 2 no-write). */
        sb_add(&ls, " tail=%s", c->tailMode == 1 ? "nots" : (c->tailMode == 2 ? "nobar" : "full"));
        /* F63: cumulative acquire/present call counts + whether the mc pattern ran. */
        if (c->patRec) {
            sb_add(&ls, " A=%d P=%d patternActive=%d", c->patAcqTotal, c->patPresTotal,
                   c->patActive);
        }
        sb_add(&ls, " dev=");
        if (c->devRc == MEOW_VK_PROBE_DEV_UNSET) {
            sb_add(&ls, "-");
        } else {
            sb_add(&ls, "%d", c->devRc);
        }
        if (c->setupOk) {
            sb_add(&ls, " f0 acq=%d sub=%d tl=%d pres=%d", c->f0Acq, c->f0Sub, c->f0Tl,
                   c->f0Pres);
        }
        if (c->submitQueue2) {
            sb_add(&ls, " q2=%s", c->submit2Name != NULL ? c->submit2Name : "(unresolved)");
        }
        if (c->setupOk && c->mcDegraded) {
            /* F39: this lib lacks an mc extension; the frame ran in the plain
             * fallback (so the cell still reached submit, but not the full mc
             * command family). */
            sb_add(&ls, " frame=plain(degraded) caps[dr=%d sync2=%d push=%d div=%d]",
                   c->capDr, c->capSync2, c->capPushDesc, c->capDivisor);
        }
        if (!c->setupOk) {
            sb_add(&ls, " SETUP FAIL: %s", c->detail[0] != '\0' ? c->detail : "(unknown)");
        } else if (c->allOk) {
            sb_add(&ls, " RESULT: OK (%d)", c->framesDone);
        } else if (c->failKind != 0) {
            const char* what = "present";
            if (c->failKind == 3) {
                what = "acquire";
            } else if (c->failKind == 4) {
                what = "submit";
            } else if (c->failKind == 5) {
                what = "timelinewait";
            }
            sb_add(&ls, " FAIL at frame %d: %s rc=%d (%s)", c->failFrame, what, c->failRc,
                   rc_name(c->failRc));
        } else {
            sb_add(&ls, " RESULT: stopped after %d/%d frames", c->framesDone, c->framesWanted);
        }
        sb_add(&sb, "%s\n", line);
    }

    /* Generated verdict. F39: a submit-layer conclusion is only drawn from cells
     * that BOTH set up AND actually issued >=1 submit; a SETUP FAIL (or a failure
     * before the first submit) carries no submit information and is excluded. The
     * participating cell numbers are printed, and an inconclusive comparison says
     * INSUFFICIENT INFO instead of guessing (this is the F38 defect fixed). */
    {
        const MeowVkProbeCell* shimQ2 = NULL;
        const MeowVkProbeCell* rawQ2 = NULL;
        for (int i = 0; i < cellCount; ++i) {
            const MeowVkProbeCell* c = &cells[i];
            if (c->libShim && c->submitQueue2) {
                shimQ2 = c;
            } else if (!c->libShim && c->submitQueue2) {
                rawQ2 = c;
            }
        }
        sb_add(&sb, "q2 spelling: shim=%s raw=%s\n",
               shimQ2 != NULL && shimQ2->submit2Name != NULL ? shimQ2->submit2Name : "-",
               rawQ2 != NULL && rawQ2->submit2Name != NULL ? rawQ2->submit2Name : "-");

        /* F42: the cells whose submit result is actually comparable = device
         * really created (dev=0) AND at least one mc item actually ran. The
         * plain control and any setup / never-submit cell never participate. */
        char cmpList[48];
        MeowSb cl;
        sb_reset(&cl, cmpList, sizeof(cmpList));
        int cmpCount = 0;
        for (int i = 0; i < cellCount; ++i) {
            if (cell_comparable(&cells[i])) {
                sb_add(&cl, "%s[%d]", cmpCount > 0 ? "," : "", i + 1);
                ++cmpCount;
            }
        }
        sb_add(&sb, "SUMMARY: comparable cells (dev=0 + ran mc items)=%s\n",
               cmpCount > 0 ? cmpList : "(none)");

        /* Account for every excluded cell explicitly (never read as a submit fail). */
        for (int i = 0; i < cellCount; ++i) {
            const MeowVkProbeCell* c = &cells[i];
            if (cell_comparable(c)) {
                continue;
            }
            if (!c->setupOk) {
                sb_add(&sb,
                       "  cell [%d] lib=%s submit=%s: setup failed, submit not tested (%s)\n",
                       i + 1, c->libShim ? "shim" : "raw",
                       c->submitQueue2 ? "queue2" : "v1",
                       c->detail[0] != '\0' ? c->detail : "(unknown)");
            } else if (c->devRc != VK_OK) {
                sb_add(&sb,
                       "  cell [%d] lib=%s submit=%s: dev=%d, submit not tested (%s)\n", i + 1,
                       c->libShim ? "shim" : "raw", c->submitQueue2 ? "queue2" : "v1", c->devRc,
                       c->detail[0] != '\0' ? c->detail : "(unknown)");
            } else if (!c->submitTested) {
                sb_add(&sb,
                       "  cell [%d] lib=%s submit=%s: setup ok but never reached submit, submit"
                       " not tested (%s)\n",
                       i + 1, c->libShim ? "shim" : "raw",
                       c->submitQueue2 ? "queue2" : "v1",
                       c->detail[0] != '\0' ? c->detail : "no diagnostic");
            } else {
                sb_add(&sb,
                       "  cell [%d] lib=%s submit=%s: ran no mc item (frame=plain), not an"
                       " mc-frame comparison\n",
                       i + 1, c->libShim ? "shim" : "raw",
                       c->submitQueue2 ? "queue2" : "v1");
            }
        }

        if (!matrixMode) {
            /* Single-cell run: report its own submit outcome, no cross-lib claim. */
            const MeowVkProbeCell* only = cellCount > 0 ? &cells[0] : NULL;
            if (only == NULL) {
                sb_add(&sb, "SUMMARY: no cell ran => INSUFFICIENT INFO\n");
            } else if (!cell_reached_submit(only)) {
                sb_add(&sb,
                       "SUMMARY: the single cell did not reach submit => INSUFFICIENT INFO"
                       " (setup failed or failed before submit)\n");
            } else if (cell_submit_failed(only)) {
                sb_add(&sb, "SUMMARY: single cell lib=%s submit=%s => submit FAILED rc=%d (%s)\n",
                       only->libShim ? "shim" : "raw", only->submitQueue2 ? "queue2" : "v1",
                       only->submitFailRc, rc_name(only->submitFailRc));
            } else {
                sb_add(&sb, "SUMMARY: single cell lib=%s submit=%s => submit OK\n",
                       only->libShim ? "shim" : "raw", only->submitQueue2 ? "queue2" : "v1");
            }
        } else {
            /* F43/F44 ONE-ITEM-ONLY SUMMARY. Every comparable cell is lib=shim +
             * devfeat=fake; cell 1 is all-on (the baseline), cells 2..6 each keep
             * exactly one mc item. A conclusion only uses comparable cells
             * (dev=0 + >=1 mc item); the plain-control / never-submit / no-item
             * cells never participate. Cells 7/8 (all-on) are reported separately
             * below, so this loop is bounded to the six one-item cells. */
            for (int i = 0; i < cellCount && i < 6; ++i) {
                const MeowVkProbeCell* c = &cells[i];
                if (!cell_comparable(c)) {
                    continue;
                }
                sb_add(&sb,
                       "SUMMARY: cell %d %-11s ran[dr=%d push=%d up=%d ts=%d div=%d] => ",
                       i + 1, meow_cell_label(c), c->ranDr, c->ranPush, c->ranUpload,
                       c->ranTs, c->ranDiv);
                if (c->submitFailRc != VK_OK) {
                    sb_add(&sb, "submit FAILED rc=%d (%s) at frame %d\n", c->submitFailRc,
                           rc_name(c->submitFailRc), c->failFrame);
                } else {
                    sb_add(&sb, "submit OK (%d frames)\n", c->framesDone);
                }
            }
            /* The baseline decides whether the matrix can conclude anything. */
            const MeowVkProbeCell* base = cellCount > 0 ? &cells[0] : NULL;
            int baseCmp = (base != NULL && cell_comparable(base));
            if (!baseCmp) {
                sb_add(&sb,
                       "SUMMARY: the all-on baseline cell did not reach a comparable state"
                       " (dev=0 + ran an mc item) => INSUFFICIENT INFO\n");
            } else if (base->submitFailRc == VK_OK) {
                sb_add(&sb,
                       "SUMMARY: the all-on baseline submitted OK (frame-0 -1 not reproduced)"
                       " => INSUFFICIENT INFO about the cause\n");
            } else {
                sb_add(&sb,
                       "SUMMARY: the all-on baseline reproduced the frame-%d submit rc=%d (%s)\n",
                       base->failFrame, base->submitFailRc, rc_name(base->submitFailRc));
            }
            /* Name every comparable one-item-only cell: OK means its single item
             * alone did NOT reproduce the -1; FAILED means that item already did. */
            int okCount = 0;
            int failCount = 0;
            for (int i = 1; i < cellCount && i < 6; ++i) {
                const MeowVkProbeCell* c = &cells[i];
                if (!cell_comparable(c)) {
                    continue;
                }
                if (c->submitFailRc == VK_OK) {
                    sb_add(&sb,
                           "SUMMARY: one-item cell %d (%s) submitted OK => that single item alone"
                           " did NOT reproduce the -1\n",
                           i + 1, meow_cell_label(c));
                    ++okCount;
                } else {
                    ++failCount;
                }
            }
            if (baseCmp && base->submitFailRc != VK_OK) {
                if (okCount > 0) {
                    sb_add(&sb,
                           "SUMMARY: %d one-item cell(s) OK, %d FAILED => at least one single item"
                           " is not sufficient by itself; the shared scaffolding (per-frame sync2"
                           " layout barriers + blit + two-stage vkQueueSubmit2) and/or a"
                           " combination remain\n",
                           okCount, failCount);
                } else if (failCount > 0) {
                    sb_add(&sb,
                           "SUMMARY: every one-item-only cell FAILED => each single mc item,"
                           " riding the shared scaffolding, is already sufficient to trigger the"
                           " failure; no single item is uniquely responsible (the scaffolding"
                           " cannot be excluded)\n");
                } else {
                    sb_add(&sb,
                           "SUMMARY: no comparable one-item-only cell => INSUFFICIENT INFO\n");
                }
            }
            /* F44/F46: the four confirmation cells (7 = F33 v1+timeline repro, 8 = the F44
             * translation cure under test, 9 = translation + BINARY sync (no timeline value),
             * 10 = native v1 + timeline control). Reported on their own; every statement is
             * made only from comparable cells. */
            int c7cmp = (cellCount > 6 && cell_comparable(&cells[6]));
            int c8cmp = (cellCount > 7 && cell_comparable(&cells[7]));
            int c9cmp = (cellCount > 8 && cell_comparable(&cells[8]));
            int c10cmp = (cellCount > 9 && cell_comparable(&cells[9]));
            if (c7cmp) {
                const MeowVkProbeCell* c = &cells[6];
                sb_add(&sb,
                       "SUMMARY: cell 7 (all-on, submit=v1, sync=timeline, sync2v1=%d) => %s\n",
                       c->sync2ToV1,
                       c->submitFailRc == VK_OK ? "submit OK (corroborates F33)"
                                                : "submit FAILED (F33 not reproduced)");
            }
            if (c8cmp) {
                const MeowVkProbeCell* c = &cells[7];
                sb_add(&sb,
                       "SUMMARY: cell 8 (all-on, submit=queue2, sync=timeline, sync2v1=%d) => %s\n",
                       c->sync2ToV1,
                       c->submitFailRc == VK_OK ? "submit OK (translation cured it)"
                                                : "submit FAILED (translation did NOT cure it)");
            }
            if (c9cmp) {
                const MeowVkProbeCell* c = &cells[8];
                sb_add(&sb,
                       "SUMMARY: cell 9 (all-on, submit=queue2, sync=binary, sync2v1=%d) => %s\n",
                       c->sync2ToV1,
                       c->submitFailRc == VK_OK
                           ? "submit OK (translation survives WITHOUT a timeline value)"
                           : "submit FAILED (removing the timeline value did NOT help)");
            }
            if (c10cmp) {
                const MeowVkProbeCell* c = &cells[9];
                sb_add(&sb,
                       "SUMMARY: cell 10 (all-on, submit=v1, sync=timeline, sync2v1=%d) => %s\n",
                       c->sync2ToV1,
                       c->submitFailRc == VK_OK ? "submit OK (native v1 + timeline control)"
                                                : "submit FAILED (native v1 + timeline broke)");
            }
            if (baseCmp && c8cmp) {
                if (base->submitFailRc != VK_OK && cells[7].submitFailRc == VK_OK) {
                    sb_add(&sb,
                           "SUMMARY: FIX CONFIRMED: cell 1 (same frame, translation OFF) FAILED"
                           " rc=%d while cell 8 (translation ON) submitted OK => the shim's"
                           " synchronization2 -> v1 translation is the cure\n",
                           base->submitFailRc);
                } else if (base->submitFailRc == VK_OK) {
                    sb_add(&sb,
                           "SUMMARY: cell 1 also submitted OK (F43 baseline not reproduced;"
                           " translation may be leaking ON) => INSUFFICIENT INFO\n");
                } else {
                    sb_add(&sb,
                           "SUMMARY: cell 8 still FAILED rc=%d while cell 1 FAILED rc=%d => the"
                           " translation did not cure it\n",
                           cells[7].submitFailRc, base->submitFailRc);
                }
            }
            /* F46: the cell 8 vs cell 9 comparison isolates the timeline VALUE that the
             * translation chains through VkTimelineSemaphoreSubmitInfo. Both cells are
             * translation-ON + queue2; ONLY the sync family differs (timeline vs binary). */
            if (c8cmp && c9cmp) {
                if (cells[7].submitFailRc != VK_OK && cells[8].submitFailRc == VK_OK) {
                    sb_add(&sb,
                           "SUMMARY: timeline VALUE implicated: cell 8 (translation ON + timeline)"
                           " FAILED rc=%d while cell 9 (translation ON + binary, no timeline"
                           " value) submitted OK => the -1 tracks the timeline semaphore value"
                           " the translation carries\n",
                           cells[7].submitFailRc);
                } else if (cells[7].submitFailRc != VK_OK && cells[8].submitFailRc != VK_OK) {
                    sb_add(&sb,
                           "SUMMARY: timeline value NOT (solely) responsible: cell 8 and cell 9"
                           " BOTH FAILED (rc=%d / rc=%d); binary sync did not help\n",
                           cells[7].submitFailRc, cells[8].submitFailRc);
                } else if (cells[7].submitFailRc == VK_OK && cells[8].submitFailRc == VK_OK) {
                    sb_add(&sb,
                           "SUMMARY: cell 8 and cell 9 both submitted OK => translation is"
                           " timeline-value independent on this run\n");
                }
            }
            /* F46: cell 10 repeats cell 7's axis combination as an explicit native-v1 +
             * timeline control; agreement between them is the point. */
            if (c7cmp && c10cmp && cells[6].submitFailRc == cells[9].submitFailRc) {
                sb_add(&sb,
                       "SUMMARY: cell 10 == cell 7 native-v1+timeline control => %s\n",
                       cells[9].submitFailRc == VK_OK ? "both OK (consistent)"
                                                      : "both FAILED (consistent)");
            }
            /* F47: cells 11/12 split the translation BY TYPE. Cell 11 = v1 submit so only
             * the barrier translation is in play; cell 12 = queue2 submit with the barrier
             * translation OFF, so only the submit translation is in play. Each still has a
             * comparable (dev=0 + ran mc) frame, so an OK/FAILED here names the malformed
             * translation product directly. */
            int c11cmp = (cellCount > 10 && cell_comparable(&cells[10]));
            int c12cmp = (cellCount > 11 && cell_comparable(&cells[11]));
            if (c11cmp) {
                const MeowVkProbeCell* c = &cells[10];
                sb_add(&sb,
                       "SUMMARY: cell 11 (all-on, submit=v1, barrier translated only,"
                       " sync2v1B=%d sync2v1S=%d) => %s\n",
                       c->sync2ToV1Barrier, c->sync2ToV1Submit,
                       c->submitFailRc == VK_OK
                           ? "submit OK (barrier translation product is well-formed)"
                           : "submit FAILED (barrier translation product is malformed)");
            }
            if (c12cmp) {
                const MeowVkProbeCell* c = &cells[11];
                sb_add(&sb,
                       "SUMMARY: cell 12 (all-on, submit=queue2, submit translated only,"
                       " sync2v1B=%d sync2v1S=%d) => %s\n",
                       c->sync2ToV1Barrier, c->sync2ToV1Submit,
                       c->submitFailRc == VK_OK
                           ? "submit OK (submit translation product is well-formed)"
                           : "submit FAILED (submit translation product is malformed)");
            }
            if (c11cmp && c12cmp) {
                int f11 = (cells[10].submitFailRc != VK_OK);
                int f12 = (cells[11].submitFailRc != VK_OK);
                if (f11 && f12) {
                    sb_add(&sb,
                           "SUMMARY: cell 11 and cell 12 BOTH FAILED => BOTH translation products"
                           " are malformed (or share one common defect)\n");
                } else if (f11) {
                    sb_add(&sb,
                           "SUMMARY: cell 11 FAILED but cell 12 OK => the BARRIER translation"
                           " product is the malformed one\n");
                } else if (f12) {
                    sb_add(&sb,
                           "SUMMARY: cell 12 FAILED but cell 11 OK => the SUBMIT translation"
                           " product is the malformed one\n");
                } else {
                    sb_add(&sb,
                           "SUMMARY: cell 11 and cell 12 both OK => each translation product is"
                           " individually well-formed; the cell 8 -1 needs BOTH together"
                           " (combination-only)\n");
                }
            }
            /* F52: cell 13 keeps ONLY the textured item (64x64 texture create +
             * vkCmdCopyBufferToImage upload + COMBINED_IMAGE_SAMPLER push), riding
             * the same shared scaffolding as every other cell. If it fails while
             * the other one-item cells pass, the textured upload is implicated. */
            int c13cmp = (cellCount > 12 && cell_comparable(&cells[12]));
            if (c13cmp) {
                const MeowVkProbeCell* c = &cells[12];
                sb_add(&sb,
                       "SUMMARY: cell 13 (only TEX: vkCmdCopyBufferToImage +"
                       " COMBINED_IMAGE_SAMPLER push) => %s\n",
                       c->submitFailRc == VK_OK
                           ? "submit OK (textured upload alone did NOT reproduce the failure)"
                           : "submit FAILED (textured upload alone reproduces the failure)");
            }
            /* Cell 6 is the sync2-gated TS cell: annotate an explicit skip. */
            if (cellCount > 5 && !cells[5].ranTs) {
                sb_add(&sb,
                       "SUMMARY: only TS item skipped: sync2 capability view unavailable"
                       " (ran[ts=0])\n");
            }
        }
        sb_add(&sb, "VERDICT keys: -1=%s (vulkan_core.h:147)\n",
               rc_name(VK_ERROR_OUT_OF_HOST_MEMORY));
    }

    /* F63: one compact line per frame for the pattern cells, printed AFTER the
     * verdict so a report-size overrun can never hide the SUMMARY. Each line is
     * acquire dtMs / imageIndex / submit / present / timelineWait rc; A/P totals
     * (on the cell line) show whether swapchain images are ever not returned. */
    for (int i = 0; i < cellCount; ++i) {
        const MeowVkProbeCell* c = &cells[i];
        if (c->patRec && c->patCount > 0) {
            sb_add(&sb, "pattern=%s frames=%d A=%d P=%d patternActive=%d\n",
                   c->patMcEnv ? "mc" : "own", c->patCount, c->patAcqTotal, c->patPresTotal,
                   c->patActive);
            for (int k = 0; k < c->patCount; ++k) {
                sb_add(&sb, "  pat=%s f%d dt=%lld img=%d s=%d p=%d tl=%d\n",
                       c->patMcEnv ? "mc" : "own", k, (long long)c->patAcqDtMs[k],
                       c->patImg[k], c->patSub[k], c->patPres[k], c->patTl[k]);
            }
        }
    }

    pthread_mutex_lock(&g_lock);
    set_result_locked(report);
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Public C entry points (wrapped by meowjrebridge.cpp NAPI).          */
/* ------------------------------------------------------------------ */
int meowVkProbeStart(int64_t surfaceId, int frames) {
    pthread_mutex_lock(&g_lock);
    if (g_running) {
        pthread_mutex_unlock(&g_lock);
        return -2;
    }
    g_running = 1;
    g_result[0] = '\0';
    pthread_mutex_unlock(&g_lock);

    MeowVkProbeJob* job = (MeowVkProbeJob*)malloc(sizeof(MeowVkProbeJob));
    if (job == NULL) {
        pthread_mutex_lock(&g_lock);
        set_result_locked("MeowVkProbe: malloc job failed");
        pthread_mutex_unlock(&g_lock);
        return -3;
    }
    job->surfaceId = surfaceId;
    job->frames = frames > 0 ? frames : 120;

    pthread_t th;
    if (pthread_create(&th, NULL, probe_main, job) != 0) {
        free(job);
        pthread_mutex_lock(&g_lock);
        set_result_locked("MeowVkProbe: pthread_create failed");
        pthread_mutex_unlock(&g_lock);
        return -4;
    }
    pthread_detach(th);
    return 0;
}

int meowVkProbeResultCopy(char* out, int cap) {
    if (out == NULL || cap <= 0) {
        return -1;
    }
    pthread_mutex_lock(&g_lock);
    size_t n = strlen(g_result);
    if (n > (size_t)(cap - 1)) {
        n = (size_t)(cap - 1);
    }
    memcpy(out, g_result, n);
    out[n] = '\0';
    pthread_mutex_unlock(&g_lock);
    return (int)n;
}
