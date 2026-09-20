/*
 * Vendored, trimmed copy of the Meowcraft bridge shared-state contract
 * (meowcraftbridge_environ.h). Kept in the SDL fork so the OHOS video driver can
 * read the ArkTS input ring without depending on the app's build tree.
 *
 * The struct layout is an ABI red line: it must stay byte-identical to
 * Meowcraft/libs/meowcraftlib/src/main/cpp/meowcraftbridge/meowcraftbridge_environ.h
 * (total size 0x27228; field offsets frozen). Only the enum + struct + ring
 * geometry are needed here; the `extern meow_environ` symbol is deliberately
 * omitted (we adopt the block via the MEOWCRAFT_ENVIRON hex pointer).
 */
#ifndef OHOS_MEOW_ENVIRON_H
#define OHOS_MEOW_ENVIRON_H

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MEOW_RING_CAPACITY 8000

enum {
    MEOW_EV_CHAR = 1000,
    MEOW_EV_CHAR_MODS = 1001,
    MEOW_EV_CURSOR_ENTER = 1002,
    MEOW_EV_KEY = 1005,
    MEOW_EV_MOUSE_BUTTON = 1006,
    MEOW_EV_SCROLL = 1007,

    MEOW_STATE_BYTES = 0x27228
};

typedef struct {
    int type;
    int i1;
    int i2;
    int i3;
    int i4;
} MeowInputEvent;

typedef void (*MeowInvokeCharFn)(void *window, unsigned int codepoint);
typedef void (*MeowInvokeCharModsFn)(void *window, unsigned int codepoint, int mods);
typedef void (*MeowInvokeCursorEnterFn)(void *window, int entered);
typedef void (*MeowInvokeCursorPosFn)(void *window, double xpos, double ypos);
typedef void (*MeowInvokeKeyFn)(void *window, int key, int scancode, int action, int mods);
typedef void (*MeowInvokeMouseButtonFn)(void *window, int button, int action, int mods);
typedef void (*MeowInvokeScrollFn)(void *window, double xoffset, double yoffset);

struct meow_environ_s {
    /* 0x000 */ void *window;
    /* 0x008 */ void *mainWindowBundle;
    /* 0x010 */ int config_renderer;
    /* 0x014 */ unsigned char force_vsync;
    /* 0x015 */ unsigned char pad_015[3];
    /* 0x018 */ atomic_size_t eventCounter;
    /* 0x020 */ MeowInputEvent events[MEOW_RING_CAPACITY];
    /* 0x27120 */ size_t outEventIndex;
    /* 0x27128 */ size_t outTargetIndex;
    /* 0x27130 */ size_t inEventIndex;
    /* 0x27138 */ size_t inEventCount;
    /* 0x27140 */ double cursorX;
    /* 0x27148 */ double cursorY;
    /* 0x27150 */ double cLastX;
    /* 0x27158 */ double cLastY;
    /* 0x27160 */ void *javaVm;
    /* 0x27168 */ unsigned char *keyDownBuffer;
    /* 0x27170 */ unsigned char *mouseDownBuffer;
    /* 0x27178 */ void *showingWindow;
    /* 0x27180 */ void (*onCursorEnabled)(int);
    /* 0x27188 */ void (*onNominalExit)(int);
    /* 0x27190 */ MeowInvokeCharFn invokeChar;
    /* 0x27198 */ MeowInvokeCharModsFn invokeCharMods;
    /* 0x271a0 */ MeowInvokeCursorEnterFn invokeCursorEnter;
    /* 0x271a8 */ MeowInvokeCursorPosFn invokeCursorPos;
    /* 0x271b0 */ MeowInvokeKeyFn invokeKey;
    /* 0x271b8 */ MeowInvokeMouseButtonFn invokeMouseButton;
    /* 0x271c0 */ MeowInvokeScrollFn invokeScroll;
    /* 0x271c8 */ int64_t surfaceId;
    /* 0x271d0 */ unsigned char isInputReady;
    /* 0x271d1 */ unsigned char isCursorEntered;
    /* 0x271d2 */ unsigned char isUseStackQueueCall;
    /* 0x271d3 */ unsigned char isGrabbing;
    /* 0x271d4 */ int savedWidth;
    /* 0x271d8 */ int savedHeight;
    /* 0x271dc */ int width;
    /* 0x271e0 */ int height;
    /* 0x271e4 */ unsigned char shouldUpdateMouse;
    /* 0x271e5 */ unsigned char shouldUpdateMonitorSize;
    /* 0x271e6 */ unsigned char reserved_align[2];
    /* 0x271e8 */ int grabbing;
    /* 0x271ec */ int fsRequest;              /* fullscreen: 0 none, 1 enter, 2 exit */
    /* 0x271f0 */ int fsActive;
    /* 0x271f4 */ int fsX;
    /* 0x271f8 */ int fsY;
    /* 0x271fc */ int fsW;
    /* 0x27200 */ int fsH;
    /* 0x27204 */ int windowUnfocused;  /* 1 = game window lost focus, 0 = focused (zero = old behaviour) */
    /* 0x27208 */ unsigned char reserved_tail[MEOW_STATE_BYTES - 0x27208];
};

/* Keep the layout honest from this side too: the bridge asserts the same offsets in
 * meowcraftbridge_environ.c. A negative array size is a portable compile-time failure,
 * so this needs no C11 _Static_assert. */
typedef char ohos_meow_environ_size_check[sizeof(struct meow_environ_s) == MEOW_STATE_BYTES ? 1 : -1];
typedef char ohos_meow_environ_focus_check[offsetof(struct meow_environ_s, windowUnfocused) == 0x27204 ? 1 : -1];

#ifdef __cplusplus
}
#endif

#endif /* OHOS_MEOW_ENVIRON_H */
