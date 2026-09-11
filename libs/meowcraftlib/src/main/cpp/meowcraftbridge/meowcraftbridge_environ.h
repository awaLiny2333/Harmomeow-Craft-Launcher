/*
 * meowcraftbridge_environ.h - Meowcraft native bridge: shared state block and cross-unit API.
 *
 * libmeowcraftbridge.so owns exactly one process-wide state block that links three
 * independent worlds:
 *
 *   - the Java GLFW stub (org.lwjgl.glfw.GLFW / CallbackBridge). It calls the
 *     exported Java_* natives, exposes the two direct ByteBuffer key/mouse
 *     arrays and the mGLFWWindowWidth/Height fields, and installs the seven
 *     input callbacks through nglfwSet*Callback;
 *   - the ArkTS layer (through libmeowjrebridge), which feeds pointer and key
 *     input in through the plain-C critical_send_* / meow* exports; and
 *   - this library's own render-thread event pump (meowStartPumping /
 *     meowPumpEvents / meowStopPumping).
 *
 * Publication: the block lives at `meow_environ` and is also advertised through
 * the MEOWCRAFT_ENVIRON environment variable as a hexadecimal pointer so that any
 * other component loaded into the process can adopt the same struct. The
 * constructor in meowcraftbridge_environ.c adopts a pre-existing pointer if one is
 * published, otherwise it allocates a zeroed block and publishes it.
 *
 * ABI rules (asserted at compile time in meowcraftbridge_environ.c):
 *   - total size is exactly 0x27228 bytes;
 *   - every field offset listed below is frozen;
 *   - bytes 0x271d4..0x271dc are two plain 32-bit integers (savedWidth /
 *     savedHeight). They are an ABI red line: no pointer may ever be stored
 *     there, because other revisions of the contract read them as a size pair.
 *
 * Field map (offset in comments is authoritative):
 *   0x000   OH_NativeWindow* used as the EGL native window
 *   0x010   renderer selector (1 = desktop GL, 2 = GLES + gl4es)
 *   0x018   SPSC event counter (producer release / consumer acquire)
 *   0x020   input event ring, MEOW_RING_CAPACITY entries of 20 bytes each
 *   0x27140 latest cursor position slot (double x, double y)
 *   0x27150 last cursor position handed to LWJGL (double x, double y)
 *   0x27160 cached JavaVM* and the two Java direct-buffer base addresses
 *   0x27178 the "showing window" handle seen by nglfwSetShowingWindow
 *   0x27190 seven GLFW callback thunks installed by the Java stub
 *   0x271c8 surface id mirrored by meowSetSurfaceId
 *   0x271d0 small boolean flags (isInputReady defaults to 1 on purpose)
 *   0x271d4 savedWidth / savedHeight / width / height, all plain int
 *   0x271e8 cursor-grab flag written by nativeSetGrabbing
 */
#ifndef MEOWCRAFT_ENVIRON_H
#define MEOWCRAFT_ENVIRON_H

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Producer/consumer ring geometry. Each entry is five 32-bit ints = 20 bytes. */
#define MEOW_RING_CAPACITY 8000

enum {
    /* Event types written into the ring by the critical_send_* producers. */
    MEOW_EV_CHAR = 1000,
    MEOW_EV_CHAR_MODS = 1001,
    MEOW_EV_CURSOR_ENTER = 1002,
    MEOW_EV_KEY = 1005,
    MEOW_EV_MOUSE_BUTTON = 1006,
    MEOW_EV_SCROLL = 1007,

    /* Exact size of the shared state block published through MEOWCRAFT_ENVIRON. */
    MEOW_STATE_BYTES = 0x27228
};

typedef struct {
    int type;
    int i1;
    int i2;
    int i3;
    int i4;
} MeowInputEvent;

/* The Java stub invokes these with the GLFW window handle as first argument. */
typedef void (*MeowInvokeCharFn)(void *window, unsigned int codepoint);
typedef void (*MeowInvokeCharModsFn)(void *window, unsigned int codepoint, int mods);
typedef void (*MeowInvokeCursorEnterFn)(void *window, int entered);
typedef void (*MeowInvokeCursorPosFn)(void *window, double xpos, double ypos);
typedef void (*MeowInvokeKeyFn)(void *window, int key, int scancode, int action, int mods);
typedef void (*MeowInvokeMouseButtonFn)(void *window, int button, int action, int mods);
typedef void (*MeowInvokeScrollFn)(void *window, double xoffset, double yoffset);

struct meow_environ_s {
    /* 0x000 */ void *window;                 /* OH_NativeWindow*, set by meowSetSurfaceId */
    /* 0x008 */ void *mainWindowBundle;       /* reserved */
    /* 0x010 */ int config_renderer;          /* 1 = desktop GL, 2 = GLES + gl4es */
    /* 0x014 */ unsigned char force_vsync;
    /* 0x015 */ unsigned char pad_015[3];
    /* 0x018 */ atomic_size_t eventCounter;   /* events queued but not yet pumped */
    /* 0x020 */ MeowInputEvent events[MEOW_RING_CAPACITY];
    /* 0x27120 */ size_t outEventIndex;       /* next ring slot to dispatch   */
    /* 0x27128 */ size_t outTargetIndex;      /* exclusive drain end          */
    /* 0x27130 */ size_t inEventIndex;        /* next free ring slot          */
    /* 0x27138 */ size_t inEventCount;        /* counter snapshot at Start    */
    /* 0x27140 */ double cursorX;             /* latest pointer x             */
    /* 0x27148 */ double cursorY;             /* latest pointer y             */
    /* 0x27150 */ double cLastX;              /* pointer x last sent to LWJGL */
    /* 0x27158 */ double cLastY;              /* pointer y last sent to LWJGL */
    /* 0x27160 */ void *javaVm;               /* JavaVM*, cached in JNI_OnLoad */
    /* 0x27168 */ unsigned char *keyDownBuffer;   /* Java direct key states   */
    /* 0x27170 */ unsigned char *mouseDownBuffer; /* Java direct button states */
    /* 0x27178 */ void *showingWindow;        /* nglfwSetShowingWindow handle */
    /* 0x27180 */ void (*onCursorEnabled)(int);   /* reserved */
    /* 0x27188 */ void (*onNominalExit)(int);     /* reserved */
    /* 0x27190 */ MeowInvokeCharFn invokeChar;
    /* 0x27198 */ MeowInvokeCharModsFn invokeCharMods;
    /* 0x271a0 */ MeowInvokeCursorEnterFn invokeCursorEnter;
    /* 0x271a8 */ MeowInvokeCursorPosFn invokeCursorPos;
    /* 0x271b0 */ MeowInvokeKeyFn invokeKey;
    /* 0x271b8 */ MeowInvokeMouseButtonFn invokeMouseButton;
    /* 0x271c0 */ MeowInvokeScrollFn invokeScroll;
    /* 0x271c8 */ int64_t surfaceId;          /* OH surface id mirror         */
    /* 0x271d0 */ unsigned char isInputReady; /* defaults to 1                */
    /* 0x271d1 */ unsigned char isCursorEntered;
    /* 0x271d2 */ unsigned char isUseStackQueueCall;
    /* 0x271d3 */ unsigned char isGrabbing;
    /* 0x271d4 */ int savedWidth;             /* plain int, never a pointer   */
    /* 0x271d8 */ int savedHeight;            /* plain int, never a pointer   */
    /* 0x271dc */ int width;                  /* current window width mirror  */
    /* 0x271e0 */ int height;                 /* current window height mirror */
    /* 0x271e4 */ unsigned char shouldUpdateMouse;
    /* 0x271e5 */ unsigned char shouldUpdateMonitorSize;
    /* 0x271e6 */ unsigned char reserved_align[2];
    /* 0x271e8 */ int grabbing;               /* ArkTS polls this for the cursor state */
    /* 0x271ec */ int fsRequest;              /* fullscreen: 0 none, 1 enter, 2 exit (driver/GLFW -> ArkTS) */
    /* 0x271f0 */ int fsActive;               /* last fullscreen state told to the launcher */
    /* 0x271f4 */ int fsX;                    /* windowed restore rect */
    /* 0x271f8 */ int fsY;
    /* 0x271fc */ int fsW;
    /* 0x27200 */ int fsH;
    /* 0x27204 */ unsigned char reserved_tail[MEOW_STATE_BYTES - 0x27204];
};

extern struct meow_environ_s *meow_environ;

/*
 * Cross-unit entry points shared by the two translation units of the library.
 * They are not part of the public Java/native contract; they exist so
 * input_bridge.c can drive resize/surface work that lives in egl_gl.c.
 */
int meow_egl_apply_resize(int width, int height);
uintptr_t meow_current_window_handle(void);

#ifdef __cplusplus
}
#endif

#endif /* MEOWCRAFT_ENVIRON_H */
