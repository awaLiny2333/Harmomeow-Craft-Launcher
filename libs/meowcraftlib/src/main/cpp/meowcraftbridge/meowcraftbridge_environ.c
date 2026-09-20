/*
 * meowcraftbridge_environ.c - owner of the process-wide shared state block.
 *
 * Exports the 8-byte pointer `meow_environ`. The constructor adopts a block
 * whose address was published in MEOWCRAFT_ENVIRON by an earlier module, or
 * allocates a fresh zeroed block and publishes it. This lets a component that
 * is dlopen()ed later (for example the ArkTS-side bridge) find the same state.
 *
 * Only this file defines the block; meowcraftbridge_environ.h documents the field map.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "meowlog.h"
#include "meowcraftbridge_environ.h"

struct meow_environ_s *meow_environ;

/* -------------------------------------------------------------------------
 * ABI red lines. The platform is aarch64 LP64: pointers are 8 bytes, int is
 * 4 bytes, double is 8 bytes. Any change that trips one of these asserts will
 * break the frozen layout, so the assert must be treated as a design gate.
 * ------------------------------------------------------------------------- */
_Static_assert(sizeof(void *) == 8, "state block assumes aarch64 LP64");
_Static_assert(sizeof(MeowInputEvent) == 20, "ring entries are 20 bytes");
_Static_assert(offsetof(struct meow_environ_s, window) == 0x000, "window offset");
_Static_assert(offsetof(struct meow_environ_s, mainWindowBundle) == 0x008, "bundle offset");
_Static_assert(offsetof(struct meow_environ_s, config_renderer) == 0x010, "renderer offset");
_Static_assert(offsetof(struct meow_environ_s, force_vsync) == 0x014, "vsync offset");
_Static_assert(offsetof(struct meow_environ_s, eventCounter) == 0x018, "counter offset");
_Static_assert(offsetof(struct meow_environ_s, events) == 0x020, "ring offset");
_Static_assert(offsetof(struct meow_environ_s, outEventIndex) == 0x27120, "out index");
_Static_assert(offsetof(struct meow_environ_s, outTargetIndex) == 0x27128, "target index");
_Static_assert(offsetof(struct meow_environ_s, inEventIndex) == 0x27130, "in index");
_Static_assert(offsetof(struct meow_environ_s, inEventCount) == 0x27138, "in count");
_Static_assert(offsetof(struct meow_environ_s, cursorX) == 0x27140, "cursorX");
_Static_assert(offsetof(struct meow_environ_s, cursorY) == 0x27148, "cursorY");
_Static_assert(offsetof(struct meow_environ_s, cLastX) == 0x27150, "cLastX");
_Static_assert(offsetof(struct meow_environ_s, cLastY) == 0x27158, "cLastY");
_Static_assert(offsetof(struct meow_environ_s, javaVm) == 0x27160, "javaVm");
_Static_assert(offsetof(struct meow_environ_s, keyDownBuffer) == 0x27168, "key buffer");
_Static_assert(offsetof(struct meow_environ_s, mouseDownBuffer) == 0x27170, "mouse buffer");
_Static_assert(offsetof(struct meow_environ_s, showingWindow) == 0x27178, "showing window");
_Static_assert(offsetof(struct meow_environ_s, onCursorEnabled) == 0x27180, "cursor slot");
_Static_assert(offsetof(struct meow_environ_s, onNominalExit) == 0x27188, "exit slot");
_Static_assert(offsetof(struct meow_environ_s, invokeChar) == 0x27190, "invokeChar");
_Static_assert(offsetof(struct meow_environ_s, invokeCharMods) == 0x27198, "invokeCharMods");
_Static_assert(offsetof(struct meow_environ_s, invokeCursorEnter) == 0x271a0, "cursorEnter");
_Static_assert(offsetof(struct meow_environ_s, invokeCursorPos) == 0x271a8, "cursorPos");
_Static_assert(offsetof(struct meow_environ_s, invokeKey) == 0x271b0, "invokeKey");
_Static_assert(offsetof(struct meow_environ_s, invokeMouseButton) == 0x271b8, "mouseButton");
_Static_assert(offsetof(struct meow_environ_s, invokeScroll) == 0x271c0, "invokeScroll");
_Static_assert(offsetof(struct meow_environ_s, surfaceId) == 0x271c8, "surfaceId");
_Static_assert(offsetof(struct meow_environ_s, isInputReady) == 0x271d0, "isInputReady");
_Static_assert(offsetof(struct meow_environ_s, isCursorEntered) == 0x271d1, "isCursorEntered");
_Static_assert(offsetof(struct meow_environ_s, isUseStackQueueCall) == 0x271d2, "stackqueue");
_Static_assert(offsetof(struct meow_environ_s, isGrabbing) == 0x271d3, "isGrabbing");
_Static_assert(offsetof(struct meow_environ_s, savedWidth) == 0x271d4, "savedWidth");
_Static_assert(offsetof(struct meow_environ_s, savedHeight) == 0x271d8, "savedHeight");
_Static_assert(offsetof(struct meow_environ_s, width) == 0x271dc, "width");
_Static_assert(offsetof(struct meow_environ_s, height) == 0x271e0, "height");
_Static_assert(offsetof(struct meow_environ_s, shouldUpdateMouse) == 0x271e4, "mouse flag");
_Static_assert(offsetof(struct meow_environ_s, shouldUpdateMonitorSize) == 0x271e5, "size flag");
_Static_assert(offsetof(struct meow_environ_s, grabbing) == 0x271e8, "grabbing");
_Static_assert(offsetof(struct meow_environ_s, fsRequest) == 0x271ec, "fsRequest");
_Static_assert(offsetof(struct meow_environ_s, fsActive) == 0x271f0, "fsActive");
_Static_assert(offsetof(struct meow_environ_s, fsX) == 0x271f4, "fsX");
_Static_assert(offsetof(struct meow_environ_s, fsY) == 0x271f8, "fsY");
_Static_assert(offsetof(struct meow_environ_s, fsW) == 0x271fc, "fsW");
_Static_assert(offsetof(struct meow_environ_s, fsH) == 0x27200, "fsH");
_Static_assert(offsetof(struct meow_environ_s, windowUnfocused) == 0x27204, "windowUnfocused");
_Static_assert(sizeof(struct meow_environ_s) == MEOW_STATE_BYTES,
               "state block must be exactly 0x27228 bytes");

/* The 0x271d4..0x271dc span must remain two 32-bit integers. */
_Static_assert(offsetof(struct meow_environ_s, width) - offsetof(struct meow_environ_s, savedWidth) == 8,
               "red-line size pair must be two ints");

__attribute__((constructor)) static void meow_state_init(void) {
    const char *published = getenv("MEOWCRAFT_ENVIRON");
    if (published != NULL && *published != '\0') {
        struct meow_environ_s *adopted =
            (struct meow_environ_s *)strtoull(published, NULL, 16);
        if (adopted != NULL) {
            meow_environ = adopted;
            MEOWLOGI("adopted shared state at %{public}p", (void *)adopted);
            return;
        }
        MEOWLOGW("MEOWCRAFT_ENVIRON=%{public}s unparseable, allocating a fresh block", published);
    }

    meow_environ = (struct meow_environ_s *)calloc(1, MEOW_STATE_BYTES);
    if (meow_environ == NULL) {
        MEOWLOGE("calloc(%{public}d) failed for the shared state block", (int)MEOW_STATE_BYTES);
        return;
    }

    /* Renderer backend: 1 = desktop GL (default), 2 = GLES + gl4es (MC <=1.16). */
    const char *renderer = getenv("MEOWCRAFT_RENDERER");
    meow_environ->config_renderer =
        (renderer != NULL && strcmp(renderer, "gl4es") == 0) ? 2 : 1;

    /*
     * Start with input enabled. The Java stub may call nativeSetInputReady(),
     * but input on this platform is primarily driven from ArkTS through the
     * meow* NAPI surface, so the block must be usable before any such call.
     */
    meow_environ->isInputReady = 1;

    /* Window focus: zero means focused, which is also what an older HSP leaves here, so
     * the game never auto-pauses before the first real windowStageEvent (ACTIVE/INACTIVE). */
    meow_environ->windowUnfocused = 0;

    char hex[32];
    snprintf(hex, sizeof(hex), "%p", (void *)meow_environ);
    setenv("MEOWCRAFT_ENVIRON", hex, 1);
    MEOWLOGI("published shared state at %{public}s", hex);
}
