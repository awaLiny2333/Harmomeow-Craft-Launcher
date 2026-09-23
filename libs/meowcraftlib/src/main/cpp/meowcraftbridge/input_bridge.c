/*
 * input_bridge.c - Meowcraft's native input path and GLFW/LWJGL JNI surface.
 *
 * Responsibilities:
 *   - the exported Java_org_lwjgl_glfw_GLFW_* and
 *     Java_org_lwjgl_glfw_CallbackBridge_* natives that the Java GLFW stub
 *     resolves by symbol name (no RegisterNatives is used anywhere);
 *   - the exported plain-C critical_send_* producers and meow* helpers that the
 *     ArkTS side reaches through libmeowjrebridge;
 *   - the render-thread event pump driven by glfwPollEvents:
 *         meowStartPumping -> meowPumpEvents (once per window) -> meowStopPumping.
 *
 * Event delivery uses an SPSC ring of MEOW_RING_CAPACITY 20-byte entries. One
 * producer thread (any ArkTS/UI thread) appends at inEventIndex and publishes
 * with a release increment of eventCounter. The single consumer (the render
 * thread) snapshots the counter at StartPumping, drains
 * [outEventIndex, outTargetIndex) during PumpEvents, and commits in
 * StopPumping. Pointer motion additionally uses latest-value slots
 * (cursorX/cursorY + a dirty flag) so that only the newest position is sent.
 *
 * Window resizes are discovered by the pump from the width/height mirrors that
 * meowSetSurfaceId / meowResizeSurface / critical_send_screen_size write. The
 * pump pushes the new size into Java (throttled to at least
 * MEOW_RESIZE_MIN_INTERVAL_MS) and then rebuilds the EGL surface before the
 * next swap.
 */
#include <jni.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <multimodalinput/oh_input_manager.h>
#include <window_manager/oh_window_event_filter.h>

#include "meowlog.h"
#include "meowpasteboard.h"
#include "meowcraftbridge_environ.h"

/* Minimum spacing between window-size upcalls + EGL surface rebuilds. */
#define MEOW_RESIZE_MIN_INTERVAL_MS 50

/* Defined with the sampling-rate meter at the bottom; used by the input paths. */
static void meow_rate_tick(void);

/* ------------------------------------------------------------------------- */
/* monotonic clock                                                           */
/* ------------------------------------------------------------------------- */

static int64_t meow_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

/* ------------------------------------------------------------------------- */
/* diagnostic motion tracing (DELIBERATELY always-on in this build)          */
/*                                                                           */
/* Every writer of the virtual cursor (env->cursorX/Y) that can make the SDL  */
/* 'ohos' pump emit a relative motion event logs a rate-limited line with a   */
/* `src=` tag, the mouse/button correlation being the point. stderr is used   */
/* instead of SDL_Log/hilog for the same reason as the SDL driver: it shows   */
/* up in the exported log as [jre_stderr] MeowSDL: ...                        */
/* ------------------------------------------------------------------------- */
#define MEOW_TRACE_BURST_MS 400
#define MEOW_TRACE_BURST_SAME_MS 50
#define MEOW_TRACE_RATE_MS 1000

static int64_t g_mtrace_last_ms;
static const char *g_mtrace_last_src;
static int64_t g_mtrace_button_until_ms;

/* Arm the post-button burst window without adding a second BUTTON line (the
 * authoritative one is emitted by the SDL pump when it delivers to MC). */
static void meow_trace_button_mark(void) {
    g_mtrace_button_until_ms = meow_now_ms() + MEOW_TRACE_BURST_MS;
}

static void meow_trace_motion(const char *src, double x, double y, int grabbing) {
    int64_t now = meow_now_ms();
    bool burst = (now <= g_mtrace_button_until_ms);
    bool first = (g_mtrace_last_src == NULL);
    bool switched = (g_mtrace_last_src != src);
    int64_t since = now - g_mtrace_last_ms;

    if (burst) {
        if (!switched && since < MEOW_TRACE_BURST_SAME_MS) {
            return;
        }
    } else if (!(first || switched || since >= MEOW_TRACE_RATE_MS)) {
        return;
    }

    g_mtrace_last_ms = now;
    g_mtrace_last_src = src;
    fprintf(stderr,
            "MeowSDL: MOTION src=%s x=%.3f y=%.3f grabbing=%d cursor=(%.3f,%.3f)\n",
            src, x, y, grabbing,
            meow_environ ? meow_environ->cursorX : 0.0,
            meow_environ ? meow_environ->cursorY : 0.0);
}

/*
 * Ignored game-warp diagnostic. PLATFORM FACT: OHOS gives an application no
 * API to move the user's pointer, so every game-initiated pointer recentre
 * (the ArkTS grab reset -> meowGrabReset, the GLFW glfwSetCursorPos) is a
 * no-op: no cursor-slot write and no motion. This prints a rate-limited line
 * so a device log shows the no-op was taken (and with which target) instead of
 * a phantom motion. Same stderr channel as the MOTION lines, so it also shows
 * up as [jre_stderr] MeowSDL: ...
 */
static int64_t g_iwarp_last_ms;

static void meow_trace_warp_ignored(const char *src, double x, double y) {
    int64_t now = meow_now_ms();

    /* Hard ceiling independent of target/source: at most one proof line per
     * MEOW_TRACE_RATE_MS. The old same-target/same-src dedup alone had no
     * bound, so a caller recentring every frame with changing coordinates (or
     * alternating glfwwarp/grabreset) could flood the log. */
    if (g_iwarp_last_ms != 0 && (now - g_iwarp_last_ms) < MEOW_TRACE_RATE_MS) {
        return;
    }
    g_iwarp_last_ms = now;
    fprintf(stderr,
            "MeowSDL: WARP ignored (platform cannot move OS pointer) src=%s x=%.3f y=%.3f\n",
            src, x, y);
}

/* ------------------------------------------------------------------------- */
/* Java GLFW bridge cache (window-size upcall and graceful close)            */
/* ------------------------------------------------------------------------- */

/*
 * Cached on first use. The render thread primes it, and all accesses
 * afterwards happen on that same thread, so no locking is required.
 */
static jclass g_glfwClass;               /* global ref to org/lwjgl/glfw/GLFW */
static jmethodID g_windowSizeMethod;     /* internalWindowSizeChanged (JII)V or (J)V */
static jmethodID g_setCloseMethod;       /* glfwSetWindowShouldClose (JZ)V */
static jfieldID g_windowWidthField;      /* mGLFWWindowWidth (I)  */
static jfieldID g_windowHeightField;     /* mGLFWWindowHeight (I) */
static int g_windowSizeViaFields;        /* 1 = only (J)V exists; size travels in fields */
static int g_pushedWidth;                /* last size pushed to Java */
static int g_pushedHeight;
static int64_t g_lastSizePushMs;         /* throttle stamp */

static int meow_glfw_bridge_ready(JNIEnv *jenv) {
    if (jenv == NULL) {
        return 0;
    }
    if (g_glfwClass != NULL) {
        return 1;
    }

    jclass local = (*jenv)->FindClass(jenv, "org/lwjgl/glfw/GLFW");
    if (local == NULL) {
        (*jenv)->ExceptionClear(jenv);
        MEOWLOGE("FindClass(org/lwjgl/glfw/GLFW) failed");
        return 0;
    }
    jclass global = (jclass)(*jenv)->NewGlobalRef(jenv, local);
    (*jenv)->DeleteLocalRef(jenv, local);
    if (global == NULL) {
        MEOWLOGE("NewGlobalRef(org/lwjgl/glfw/GLFW) failed");
        return 0;
    }

    /* Size fields are optional but harmless to write when present. */
    g_windowWidthField = (*jenv)->GetStaticFieldID(jenv, global, "mGLFWWindowWidth", "I");
    if (g_windowWidthField == NULL) {
        (*jenv)->ExceptionClear(jenv);
    }
    g_windowHeightField = (*jenv)->GetStaticFieldID(jenv, global, "mGLFWWindowHeight", "I");
    if (g_windowHeightField == NULL) {
        (*jenv)->ExceptionClear(jenv);
    }

    /*
     * Prefer the explicit (JII)V form. If it is absent, fall back to the (J)V
     * form, which reads mGLFWWindowWidth/Height, and require the two fields.
     */
    jmethodID size3 = (*jenv)->GetStaticMethodID(jenv, global, "internalWindowSizeChanged",
                                                 "(JII)V");
    if (size3 != NULL) {
        g_windowSizeViaFields = 0;
        g_windowSizeMethod = size3;
    } else {
        (*jenv)->ExceptionClear(jenv);
        jmethodID size1 = (*jenv)->GetStaticMethodID(jenv, global, "internalWindowSizeChanged",
                                                     "(J)V");
        if (size1 != NULL) {
            g_windowSizeViaFields = 1;
            g_windowSizeMethod = size1;
        } else {
            (*jenv)->ExceptionClear(jenv);
            g_windowSizeMethod = NULL;
            g_windowSizeViaFields = 0;
        }
    }
    if (g_windowSizeViaFields &&
        (g_windowWidthField == NULL || g_windowHeightField == NULL)) {
        MEOWLOGW("(J)V window-size form present but size fields missing; upcall disabled");
        g_windowSizeMethod = NULL;
    }
    if (g_windowSizeMethod == NULL) {
        MEOWLOGW("internalWindowSizeChanged not found; window-size upcall disabled");
    }

    jmethodID close = (*jenv)->GetStaticMethodID(jenv, global, "glfwSetWindowShouldClose",
                                                 "(JZ)V");
    if (close == NULL) {
        (*jenv)->ExceptionClear(jenv);
        MEOWLOGE("glfwSetWindowShouldClose lookup failed");
        (*jenv)->DeleteGlobalRef(jenv, global);
        return 0;
    }

    g_setCloseMethod = close;
    g_glfwClass = global;
    MEOWLOGI("cached GLFW bridge (size=%{public}s close=ok)",
           g_windowSizeMethod == NULL ? "none" : (g_windowSizeViaFields ? "fields" : "direct"));
    return 1;
}

/* ------------------------------------------------------------------------- */
/* graceful close request (ArkTS -> JVM)                                     */
/* ------------------------------------------------------------------------- */

int meowGlfwRequestClose(void) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || env->javaVm == NULL) {
        MEOWLOGE("request close: state/javaVm not ready");
        return 0;
    }

    JavaVM *vm = (JavaVM *)env->javaVm;
    JNIEnv *jenv = NULL;
    int attached = 0;
    jint rc = (*vm)->GetEnv(vm, (void **)&jenv, JNI_VERSION_1_4);
    if (rc != JNI_OK || jenv == NULL) {
        if (rc == JNI_EDETACHED &&
            (*vm)->AttachCurrentThread(vm, (void **)&jenv, NULL) == JNI_OK && jenv != NULL) {
            attached = 1;
        } else {
            MEOWLOGE("request close: GetEnv/Attach failed rc=%{public}d", (int)rc);
            return 0;
        }
    }

    int ok = 0;
    if (meow_glfw_bridge_ready(jenv)) {
        uintptr_t handle = meow_current_window_handle();
        (*jenv)->CallStaticVoidMethod(jenv, g_glfwClass, g_setCloseMethod, (jlong)handle,
                                      JNI_TRUE);
        if ((*jenv)->ExceptionCheck(jenv)) {
            (*jenv)->ExceptionClear(jenv);
            MEOWLOGE("request close: glfwSetWindowShouldClose raised");
        } else {
            ok = 1;
            MEOWLOGI("request close window=%{public}llx", (unsigned long long)handle);
        }
    }

    if (attached) {
        (*vm)->DetachCurrentThread(vm);
    }
    return ok;
}

/* ------------------------------------------------------------------------- */
/* SPSC ring producer                                                        */
/* ------------------------------------------------------------------------- */

static void meow_ring_push(int type, int i1, int i2, int i3, int i4) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL) {
        return;
    }
    MeowInputEvent *event = &env->events[env->inEventIndex];
    event->type = type;
    event->i1 = i1;
    event->i2 = i2;
    event->i3 = i3;
    event->i4 = i4;

    size_t next = env->inEventIndex + 1;
    if (next >= MEOW_RING_CAPACITY) {
        next -= MEOW_RING_CAPACITY;
    }
    env->inEventIndex = next;
    atomic_fetch_add_explicit(&env->eventCounter, 1, memory_order_release);
}

/* ------------------------------------------------------------------------- */
/* critical_send_* producers (ArkTS -> native input)                         */
/* ------------------------------------------------------------------------- */

void critical_set_stackqueue(int use_input_stack_queue) {
    if (meow_environ == NULL) {
        return;
    }
    meow_environ->isUseStackQueueCall = use_input_stack_queue ? 1u : 0u;
}

int critical_send_char(int codepoint) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->isInputReady) {
        return 0;
    }
    /* No GLFW consumer (MC >= 26.3 uses SDL): fall back to the ring so the SDL
     * driver's PumpEvents can translate it. With GLFW present this is unchanged. */
    if (env->isUseStackQueueCall || env->invokeChar == NULL) {
        meow_ring_push(MEOW_EV_CHAR, codepoint, 0, 0, 0);
    } else {
        env->invokeChar(env->showingWindow, (unsigned int)codepoint);
    }
    return 1;
}

int critical_send_char_mods(int codepoint, int mods) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->isInputReady) {
        return 0;
    }
    if (env->isUseStackQueueCall || env->invokeCharMods == NULL) {
        meow_ring_push(MEOW_EV_CHAR_MODS, codepoint, mods, 0, 0);
    } else {
        env->invokeCharMods(env->showingWindow, (unsigned int)codepoint, mods);
    }
    return 1;
}

/*
 * Absolute cursor sink. NOTE: do NOT add a `grabbing` early-out here. In grab the
 * callers of this function are the *relative* producers (meowGrabDelta /
 * meow_touch_grab_delta) plus the grab-reset seed; OHOS_PumpEvents derives SDL's
 * only relative motion from env->cursorX/Y, so guarding this slot in grab would
 * freeze the camera. The absolute->relative leak is instead cut at its single
 * entry: MeowNodeEventReceiver drops non-MOVE mouse events before meowGrabDelta.
 */
void critical_send_cursor_pos(float x, float y) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->isInputReady) {
        return;
    }

    /* Emit the enter transition once, so the consumer sees the pointer arrive. */
    if (!env->isCursorEntered) {
        env->isCursorEntered = 1;
        if (env->isUseStackQueueCall || env->invokeCursorEnter == NULL) {
            meow_ring_push(MEOW_EV_CURSOR_ENTER, 1, 0, 0, 0);
        } else {
            env->invokeCursorEnter(env->showingWindow, 1);
        }
    }

    if (env->isUseStackQueueCall || env->invokeCursorPos == NULL) {
        /* Latest-value slot; the pump floors it when it dispatches. */
        env->cursorX = (double)x;
        env->cursorY = (double)y;
    } else {
        env->invokeCursorPos(env->showingWindow, (double)x, (double)y);
    }
}

void critical_send_key(int key, int scancode, int action, int mods) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->isInputReady) {
        return;
    }

    if (env->keyDownBuffer != NULL) {
        /*
         * The direct buffer LWJGL reads through glfwGetKey only knows pressed
         * (1) and released (0); a repeat (2) must be reported as held so that
         * "is the key down" logic keeps working while a key repeats.
         */
        int index = key - 31;
        if (index < 0) {
            index = 0;
        }
        if (index < 317) {
            env->keyDownBuffer[index] = (action == 0) ? 0 : 1;
        }
    }

    if (env->isUseStackQueueCall || env->invokeKey == NULL) {
        meow_ring_push(MEOW_EV_KEY, key, scancode, action, mods);
    } else {
        env->invokeKey(env->showingWindow, key, scancode, action, mods);
    }
}

void critical_send_mouse_button(int button, int action, int mods) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->isInputReady) {
        return;
    }

    if (button == 0) {
        meow_trace_button_mark();
    }

    if (env->mouseDownBuffer != NULL && button >= 0 && button < 8) {
        env->mouseDownBuffer[button] = (unsigned char)action;
    }

    if (env->isUseStackQueueCall || env->invokeMouseButton == NULL) {
        meow_ring_push(MEOW_EV_MOUSE_BUTTON, button, action, mods, 0);
    } else {
        env->invokeMouseButton(env->showingWindow, button, action, mods);
    }
}

void critical_send_screen_size(int width, int height) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL) {
        return;
    }
    /*
     * Record the size in both the saved pair (red-line ints) and the live
     * mirrors. No direct Java call is made here: the pump owns the upcall so
     * that it always runs on a thread with a usable JNIEnv.
     */
    env->savedWidth = width;
    env->savedHeight = height;
    env->width = width;
    env->height = height;
    env->shouldUpdateMonitorSize = 1;
    MEOWLOGD("screen size -> %{public}d x %{public}d", width, height);
}

void critical_send_scroll(double xoffset, double yoffset) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->isInputReady) {
        return;
    }
    if (env->isUseStackQueueCall || env->invokeScroll == NULL) {
        /* Ring slots are ints; the scroll delta is truncated to match. */
        meow_ring_push(MEOW_EV_SCROLL, (int)xoffset, (int)yoffset, 0, 0);
    } else {
        env->invokeScroll(env->showingWindow, xoffset, yoffset);
    }
}

/* ------------------------------------------------------------------------- */
/* pump (back end of glfwPollEvents)                                         */
/* ------------------------------------------------------------------------- */

/*
 * Push the current window size to Java and rebuild the EGL surface, at most
 * once per MEOW_RESIZE_MIN_INTERVAL_MS. The size mirrors are also refreshed by
 * critical_send_screen_size / meowResizeSurface; the last-pushed pair prevents
 * redundant upcalls once a size has been delivered.
 */
static void meow_push_window_size(void *window, struct meow_environ_s *env) {
    if (env->width <= 0 || env->height <= 0) {
        return;
    }
    if (env->width == g_pushedWidth && env->height == g_pushedHeight) {
        return;
    }

    int64_t now = meow_now_ms();
    if (g_lastSizePushMs != 0 && now - g_lastSizePushMs < MEOW_RESIZE_MIN_INTERVAL_MS) {
        return; /* keep the pending size for a later frame */
    }
    g_lastSizePushMs = now;

    JavaVM *vm = (JavaVM *)env->javaVm;
    if (vm != NULL) {
        JNIEnv *jenv = NULL;
        if ((*vm)->GetEnv(vm, (void **)&jenv, JNI_VERSION_1_4) == JNI_OK && jenv != NULL &&
            meow_glfw_bridge_ready(jenv) && g_windowSizeMethod != NULL) {
            void *target = (window != NULL) ? window : (void *)meow_current_window_handle();

            /* The (J)V variant reads these fields; write them for both forms. */
            if (g_windowWidthField != NULL && g_windowHeightField != NULL) {
                (*jenv)->SetStaticIntField(jenv, g_glfwClass, g_windowWidthField, env->width);
                (*jenv)->SetStaticIntField(jenv, g_glfwClass, g_windowHeightField, env->height);
            }

            if (g_windowSizeViaFields) {
                (*jenv)->CallStaticVoidMethod(jenv, g_glfwClass, g_windowSizeMethod,
                                              (jlong)(uintptr_t)target);
            } else {
                (*jenv)->CallStaticVoidMethod(jenv, g_glfwClass, g_windowSizeMethod,
                                              (jlong)(uintptr_t)target, env->width, env->height);
            }
            if ((*jenv)->ExceptionCheck(jenv)) {
                (*jenv)->ExceptionClear(jenv);
                MEOWLOGE("window size upcall raised");
            }
            MEOWLOGI("java window size upcall %{public}d x %{public}d", env->width, env->height);
        }
    }

    g_pushedWidth = env->width;
    g_pushedHeight = env->height;

    /* Rebuild the EGL surface against the new geometry before the next swap. */
    meow_egl_apply_resize(env->width, env->height);
}

void meowStartPumping(void) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL) {
        return;
    }

    size_t queued = atomic_load_explicit(&env->eventCounter, memory_order_acquire);
    size_t start = env->outEventIndex;

    env->inEventCount = queued;
    env->outTargetIndex = (start + queued) % MEOW_RING_CAPACITY;

    /*
     * If the pointer moved since it was last handed to LWJGL, arm a direct
     * update for this pump round. The check runs once per pump, not per window.
     */
    if ((env->cLastX != env->cursorX || env->cLastY != env->cursorY) &&
        env->invokeCursorPos != NULL) {
        env->cLastX = env->cursorX;
        env->cLastY = env->cursorY;
        env->shouldUpdateMouse = 1;
    }
}

void meowPumpEvents(void *window) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL) {
        return;
    }

    meow_push_window_size(window, env);

    if (env->shouldUpdateMouse && env->invokeCursorPos != NULL) {
        /* Floored: some anti-cheat stacks object to sub-pixel precision. */
        env->invokeCursorPos(window, floor(env->cursorX), floor(env->cursorY));
    }

    size_t index = env->outEventIndex;
    size_t target = env->outTargetIndex;
    while (index != target) {
        MeowInputEvent event = env->events[index];
        switch (event.type) {
            case MEOW_EV_CHAR:
                if (env->invokeChar != NULL) {
                    env->invokeChar(window, (unsigned int)event.i1);
                }
                break;
            case MEOW_EV_CHAR_MODS:
                if (env->invokeCharMods != NULL) {
                    env->invokeCharMods(window, (unsigned int)event.i1, event.i2);
                }
                break;
            case MEOW_EV_KEY:
                if (env->invokeKey != NULL) {
                    env->invokeKey(window, event.i1, event.i2, event.i3, event.i4);
                }
                break;
            case MEOW_EV_MOUSE_BUTTON:
                if (env->invokeMouseButton != NULL) {
                    env->invokeMouseButton(window, event.i1, event.i2, event.i3);
                }
                break;
            case MEOW_EV_CURSOR_ENTER:
                if (env->invokeCursorEnter != NULL) {
                    env->invokeCursorEnter(window, event.i1);
                }
                break;
            case MEOW_EV_SCROLL:
                if (env->invokeScroll != NULL) {
                    env->invokeScroll(window, (double)event.i1, (double)event.i2);
                }
                break;
            default:
                MEOWLOGD("pump: dropping unknown event type %{public}d", event.type);
                break;
        }

        if (++index >= MEOW_RING_CAPACITY) {
            index -= MEOW_RING_CAPACITY;
        }
    }
}

void meowStopPumping(void) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL) {
        return;
    }
    env->outEventIndex = env->outTargetIndex;
    atomic_fetch_sub_explicit(&env->eventCounter, env->inEventCount, memory_order_acquire);
    env->shouldUpdateMouse = 0;
    env->shouldUpdateMonitorSize = 0;
}

/* ------------------------------------------------------------------------- */
/* GLFW callback setters                                                     */
/* ------------------------------------------------------------------------- */

#define MEOW_DEFINE_CALLBACK_SETTER(NAME, FIELD)                                              \
    JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(                \
        JNIEnv *jenv, jclass clazz, jlong window, jlong callback) {                           \
        (void)jenv;                                                                           \
        (void)clazz;                                                                          \
        (void)window;                                                                         \
        if (meow_environ == NULL) {                                                          \
            return 0;                                                                         \
        }                                                                                     \
        jlong previous = (jlong)(uintptr_t)meow_environ->FIELD;                              \
        meow_environ->FIELD = (MeowInvoke##NAME##Fn)(uintptr_t)callback;                     \
        return previous;                                                                      \
    }

MEOW_DEFINE_CALLBACK_SETTER(Char, invokeChar)
MEOW_DEFINE_CALLBACK_SETTER(CharMods, invokeCharMods)
MEOW_DEFINE_CALLBACK_SETTER(CursorEnter, invokeCursorEnter)
MEOW_DEFINE_CALLBACK_SETTER(CursorPos, invokeCursorPos)
MEOW_DEFINE_CALLBACK_SETTER(Key, invokeKey)
MEOW_DEFINE_CALLBACK_SETTER(MouseButton, invokeMouseButton)
MEOW_DEFINE_CALLBACK_SETTER(Scroll, invokeScroll)

#undef MEOW_DEFINE_CALLBACK_SETTER

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv *jenv, jclass clazz,
                                                                     jlong window) {
    (void)jenv;
    (void)clazz;
    if (meow_environ == NULL) {
        return;
    }
    meow_environ->showingWindow = (void *)(uintptr_t)window;
}

/* ------------------------------------------------------------------------- */
/* cursor get / set                                                          */
/* ------------------------------------------------------------------------- */

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *jenv, jclass clazz,
                                                                 jlong window, jobject xpos,
                                                                 jobject ypos) {
    (void)clazz;
    (void)window;
    if (meow_environ == NULL) {
        return;
    }
    double *xp = (double *)(*jenv)->GetDirectBufferAddress(jenv, xpos);
    double *yp = (double *)(*jenv)->GetDirectBufferAddress(jenv, ypos);
    if (xp != NULL) {
        *xp = meow_environ->cursorX;
    }
    if (yp != NULL) {
        *yp = meow_environ->cursorY;
    }
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *jenv, jclass clazz,
                                                                  jlong window, jdoubleArray xpos,
                                                                  jdoubleArray ypos) {
    (void)clazz;
    (void)window;
    if (meow_environ == NULL) {
        return;
    }
    double x = meow_environ->cursorX;
    double y = meow_environ->cursorY;
    (*jenv)->SetDoubleArrayRegion(jenv, xpos, 0, 1, &x);
    (*jenv)->SetDoubleArrayRegion(jenv, ypos, 0, 1, &y);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *jenv, jclass clazz,
                                                                jlong window, jdouble xpos,
                                                                jdouble ypos) {
    (void)jenv;
    (void)clazz;
    (void)window;
    /*
     * UNCONDITIONAL NO-OP. Game-initiated absolute warp (GLFW glfwSetCursorPos,
     * MC <= 26.2). PLATFORM FACT: OHOS cannot move the user's pointer, so this
     * must not fake one either: no cursor-slot write, no cLast update, no
     * motion. (The 26.3 SDL path does the same in OHOS_WarpMouse.) User
     * absolute writes (critical_send_cursor_pos) remain the only sink that may
     * move the slot, so MC's pointer tracks real input.
     */
    meow_trace_warp_ignored("glfwwarp", xpos, ypos);
}

/* ------------------------------------------------------------------------- */
/* GLFW direct-buffer caching / bridge init                                  */
/* ------------------------------------------------------------------------- */

static int g_buffersCached;

static void meow_cache_direct_buffers(JNIEnv *jenv) {
    if (meow_environ == NULL || jenv == NULL) {
        return;
    }
    if (g_buffersCached && meow_environ->keyDownBuffer != NULL &&
        meow_environ->mouseDownBuffer != NULL) {
        return;
    }

    jclass cls = (*jenv)->FindClass(jenv, "org/lwjgl/glfw/GLFW");
    if (cls == NULL) {
        (*jenv)->ExceptionClear(jenv);
        MEOWLOGW("direct-buffer cache: FindClass(org/lwjgl/glfw/GLFW) failed");
        return;
    }

    jfieldID keyField = (*jenv)->GetStaticFieldID(jenv, cls, "keyDownBuffer",
                                                  "Ljava/nio/ByteBuffer;");
    if (keyField != NULL) {
        jobject buffer = (*jenv)->GetStaticObjectField(jenv, cls, keyField);
        if (buffer != NULL) {
            meow_environ->keyDownBuffer = (unsigned char *)(*jenv)->GetDirectBufferAddress(jenv, buffer);
            (*jenv)->DeleteLocalRef(jenv, buffer);
        }
    } else {
        (*jenv)->ExceptionClear(jenv);
    }

    jfieldID mouseField = (*jenv)->GetStaticFieldID(jenv, cls, "mouseDownBuffer",
                                                    "Ljava/nio/ByteBuffer;");
    if (mouseField != NULL) {
        jobject buffer = (*jenv)->GetStaticObjectField(jenv, cls, mouseField);
        if (buffer != NULL) {
            meow_environ->mouseDownBuffer = (unsigned char *)(*jenv)->GetDirectBufferAddress(jenv, buffer);
            (*jenv)->DeleteLocalRef(jenv, buffer);
        }
    } else {
        (*jenv)->ExceptionClear(jenv);
    }

    (*jenv)->DeleteLocalRef(jenv, cls);
    g_buffersCached = 1;
    MEOWLOGI("cached keyDownBuffer=%{public}p mouseDownBuffer=%{public}p",
           (void *)meow_environ->keyDownBuffer, (void *)meow_environ->mouseDownBuffer);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nativeInitializeGLFWNativeBridge(JNIEnv *jenv,
                                                                                jclass clazz) {
    (void)clazz;
    MEOWLOGI("nativeInitializeGLFWNativeBridge");
    meow_cache_direct_buffers(jenv);
}

JNIEXPORT jint JNICALL JNI_OnLoadGLFW(JNIEnv *jenv, jclass clazz) {
    (void)clazz;
    MEOWLOGI("JNI_OnLoadGLFW");
    meow_cache_direct_buffers(jenv);
    return 0;
}

/* ------------------------------------------------------------------------- */
/* CallbackBridge natives                                                    */
/* ------------------------------------------------------------------------- */

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetInputReady(
    JNIEnv *jenv, jclass clazz, jboolean inputReady) {
    (void)jenv;
    (void)clazz;
    if (meow_environ != NULL) {
        meow_environ->isInputReady = inputReady ? 1u : 0u;
    }
    MEOWLOGI("input ready: %{public}d", (int)inputReady);
    return JNI_FALSE;
}

JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(
    JNIEnv *jenv, jclass clazz, jint action, jbyteArray copySrc) {
    char *utf8;
    jsize len;

    (void)clazz;
    if (jenv == NULL) {
        return NULL;
    }
    if (action != 2000 /* CallbackBridge.CLIPBOARD_COPY */) {
        /* Reading the clipboard needs ohos.permission.READ_PASTEBOARD (with an
         * authorisation dialog), and the recommended no-dialog route - the paste
         * control - only exists in ArkTS UI, which a game screen cannot host. */
        MEOWLOGW("nativeClipboard: paste is unsupported (needs READ_PASTEBOARD)");
        return NULL;
    }
    if (copySrc == NULL) {
        return NULL;
    }

    /* The Java stub hands over the UTF-8 bytes of the string to copy. */
    len = (*jenv)->GetArrayLength(jenv, copySrc);
    utf8 = (char *)malloc((size_t)len + 1);
    if (utf8 == NULL) {
        return NULL;
    }
    (*jenv)->GetByteArrayRegion(jenv, copySrc, 0, len, (jbyte *)utf8);
    utf8[len] = '\0';
    meow_clipboard_set_text(utf8);
    free(utf8);
    return NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(
    JNIEnv *jenv, jclass clazz, jboolean grabbing) {
    (void)jenv;
    (void)clazz;
    if (meow_environ != NULL) {
        meow_environ->grabbing = grabbing ? 1 : 0;
        meow_environ->isGrabbing = grabbing ? 1u : 0u;
        fprintf(stderr, "MeowSDL: GRABFLAG src=nativeSetGrabbing grabbing=%d\n",
                meow_environ->grabbing);
    }
    MEOWLOGI("nativeSetGrabbing: %{public}d", (int)grabbing);
}

/*
 * ArkTS polls the grab flag through this helper (libmeowjrebridge ->
 * meowGetGrabbing).
 */
int meowGetGrabbing(void) {
    return (meow_environ != NULL) ? meow_environ->grabbing : 0;
}

/*
 * Fullscreen request channel (MC -> launcher).
 *
 * The GLFW Java stub has no real OS window: MC's glfwSetWindowMonitor only toggled a
 * fake monitor, so F11 / the in-game "fullscreen" option never moved the real window.
 * The stub now forwards the request here; ArkTS polls it (libmeowjrebridge
 * takeFullscreenRequest) and drives the real GameAbility window.
 */
/* Fullscreen request now lives in the shared meow_environ block (fs* fields). */

/* The request lives in the shared meow_environ block (fields fs*), NOT in C statics,
 * so a driver in a different linker namespace (our SDL 'ohos' driver) can raise it
 * by writing the same block it already reads — no dlsym / symbol resolution. */
void meowSetFullscreenRequest(int want, int x, int y, int w, int h) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || want == env->fsActive) {
        return;
    }
    env->fsActive = want;
    env->fsX = x;
    env->fsY = y;
    env->fsW = w;
    env->fsH = h;
    env->fsRequest = want ? 1 : 2;
    MEOWLOGI("setFullscreenRequest: %{public}d rect=%{public}d,%{public}d %{public}dx%{public}d",
             want, x, y, w, h);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetFullscreen(
    JNIEnv *jenv, jclass clazz, jboolean fullscreen, jint x, jint y, jint w, jint h) {
    (void)jenv;
    (void)clazz;
    meowSetFullscreenRequest(fullscreen ? 1 : 0, x, y, w, h);
}

/* Window focus for the GLFW path. MC <=26.2 learns about focus only through
 * glfwSetWindowFocusCallback (Window.onFocus -> Minecraft.pauseIfInactive), and this
 * fork's GLFW stub is Java, so the stub polls this from glfwPollEvents() and re-dispatches
 * the callback itself. Same shared-block field the SDL path reads; zero means focused, so
 * an older HSP that never writes it keeps the pre-feature behaviour. */
JNIEXPORT jint JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeWindowUnfocused(
    JNIEnv *jenv, jclass clazz) {
    (void)jenv;
    (void)clazz;
    return (meow_environ != NULL) ? (jint)meow_environ->windowUnfocused : (jint)0;
}

/* Window focus, published by ArkTS from windowStageEvent (ACTIVE = focused). The SDL3
 * `ohos` driver polls this field and turns a change into SDL focus events, which is how
 * Minecraft 26.3 decides to auto-pause (Window.isFocused -> Minecraft.pauseIfInactive).
 * Same rationale as the fullscreen request above: the flag lives in the shared block so
 * a driver in another linker namespace reads it without any dlsym. */
void meowSetWindowActive(int active) {
    struct meow_environ_s *env = meow_environ;
    /* Stored inverted on purpose: 0 = focused is the fail-safe default, because this field
     * sits in space that used to be reserved_tail -- an older HSP never writes it, and the
     * zeroed value must keep the old behaviour (focused, no auto-pause). */
    int unfocused = active ? 0 : 1;

    if (env == NULL || unfocused == env->windowUnfocused) {
        return;
    }
    env->windowUnfocused = unfocused;
    MEOWLOGI("setWindowActive: %{public}d (windowUnfocused=%{public}d)", active ? 1 : 0, unfocused);
}

/* ArkTS side (libmeowjrebridge) takes the pending request; returns the kind and
 * fills the requested window rect (windowed restore geometry). */
int meowTakeFullscreenRequest(int *x, int *y, int *w, int *h) {
    struct meow_environ_s *env = meow_environ;
    int req;
    if (env == NULL) {
        return 0;
    }
    req = env->fsRequest;
    env->fsRequest = 0;
    if (x != NULL) {
        *x = env->fsX;
    }
    if (y != NULL) {
        *y = env->fsY;
    }
    if (w != NULL) {
        *w = env->fsW;
    }
    if (h != NULL) {
        *h = env->fsH;
    }
    return req;
}

/*
 * Gamepad / DPI / launcher-notification stubs.
 *
 * The GLFW Java stub initialises these during glfwInit();
 * internalGetGamepadDataPointer() and the two CallbackBridge buffer factories
 * must return stable, non-null addresses or JNI lookup fails and the game dies
 * immediately after GLFW loads. There are no controllers on this build, so the
 * backing store is a single zeroed GLFWgamepadstate-shaped buffer: buttons[15]
 * (plus padding) followed by six float axes.
 */
static unsigned char g_gamepadState[40] = {0};

JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_internalGetGamepadDataPointer(JNIEnv *jenv,
                                                                              jclass clazz) {
    (void)jenv;
    (void)clazz;
    return (jlong)(uintptr_t)&g_gamepadState[0];
}

JNIEXPORT jobject JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadButtonBuffer(
    JNIEnv *jenv, jclass clazz) {
    (void)clazz;
    return (*jenv)->NewDirectByteBuffer(jenv, &g_gamepadState[0], (jlong)16);
}

JNIEXPORT jobject JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeCreateGamepadAxisBuffer(
    JNIEnv *jenv, jclass clazz) {
    (void)clazz;
    return (*jenv)->NewDirectByteBuffer(jenv, &g_gamepadState[16], (jlong)24);
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeEnableGamepadDirectInput(
    JNIEnv *jenv, jclass clazz) {
    (void)jenv;
    (void)clazz;
    return JNI_FALSE;
}

JNIEXPORT jfloat JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeGetAndroidDPI(JNIEnv *jenv,
                                                                               jclass clazz) {
    (void)jenv;
    (void)clazz;
    return 160.0f;
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeNotifyLauncher(
    JNIEnv *jenv, jclass clazz, jint type, jintArray action) {
    (void)jenv;
    (void)clazz;
    (void)type;
    (void)action;
    return JNI_FALSE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSendData(
    JNIEnv *jenv, jclass clazz, jboolean isAndroid, jint type, jstring data) {
    (void)jenv;
    (void)clazz;
    (void)isAndroid;
    (void)type;
    (void)data;
}

/* ------------------------------------------------------------------------- */
/* RendererInit / Vulkan stubs                                               */
/* ------------------------------------------------------------------------- */

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_RendererInit_nativeInitGl4esInternals(
    JNIEnv *jenv, jclass clazz, jobject functionProvider) {
    (void)jenv;
    (void)clazz;
    (void)functionProvider;
    MEOWLOGI("nativeInitGl4esInternals: no-op (gl4es is initialized by the bridge, not here)");
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_vulkan_VK_getVulkanDriverHandle(JNIEnv *jenv,
                                                                       jclass clazz) {
    (void)jenv;
    (void)clazz;
    MEOWLOGI("getVulkanDriverHandle: 0 (no Vulkan loader)");
    return 0;
}

/* ------------------------------------------------------------------------- */
/* JNI entry point                                                           */
/* ------------------------------------------------------------------------- */

jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    MEOWLOGI("JNI_OnLoad");

    if (meow_environ == NULL) {
        MEOWLOGE("JNI_OnLoad: shared state not ready");
        return JNI_VERSION_1_4;
    }
    if (meow_environ->javaVm == NULL) {
        meow_environ->javaVm = (void *)vm;
    }

    if (getenv("MEOWCRAFT_SKIP_JNI_GLFW") == NULL) {
        JNIEnv *jenv = NULL;
        if ((*vm)->GetEnv(vm, (void **)&jenv, JNI_VERSION_1_4) == JNI_OK && jenv != NULL) {
            JNI_OnLoadGLFW(jenv, NULL);
        } else {
            MEOWLOGW("JNI_OnLoad: GetEnv failed, direct-buffer cache skipped");
        }
    }
    return JNI_VERSION_1_4;
}

/* ------------------------------------------------------------------------- */
/* pointer filter: absolute motion while not grabbing                        */
/* ------------------------------------------------------------------------- */

/*
 * ArkUI can coalesce/throttle pointer events; this window-level filter feeds
 * the latest absolute position straight to the bridge outside grab mode. The
 * NDK display coordinates are physical pixels. Subtract the widget origin
 * (computed by ArkTS) then divide by the render scale S, so the value lands in
 * Minecraft's framebuffer space: with the display-downscale feature the
 * XComponent is laid out at 1/S and visually enlarged by .scale(S), hence
 * displayPx = origin + S * componentPx. S == 1 reproduces the legacy path
 * bit-for-bit.
 */
static double g_filterOriginX;
static double g_filterOriginY;
static double g_filterScale = 1.0;
static int g_filterRegistered;
static int32_t g_filterWindowId;

static bool meow_mouse_filter(Input_MouseEvent *event) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || event == NULL) {
        return false;
    }
    if (OH_Input_GetMouseEventAction(event) != MOUSE_ACTION_MOVE) {
        return false;
    }
    if (env->grabbing || !env->isInputReady) {
        return false;
    }

    double s = (g_filterScale > 0.0) ? g_filterScale : 1.0;
    double x = ((double)OH_Input_GetMouseEventDisplayX(event) - g_filterOriginX) / s;
    double y = ((double)OH_Input_GetMouseEventDisplayY(event) - g_filterOriginY) / s;
    if (x < 0.0) {
        x = 0.0;
    }
    if (y < 0.0) {
        y = 0.0;
    }
    critical_send_cursor_pos((float)x, (float)y);
    meow_trace_motion("mousefilter", x, y, env->grabbing);
    meow_rate_tick();
    return false; /* do not consume: ArkUI still needs the event */
}

int meowMouseFilterStart(int32_t windowId, double originX, double originY, double scale) {
    g_filterOriginX = originX;
    g_filterOriginY = originY;
    g_filterScale = (scale > 0.0) ? scale : 1.0;
    if (g_filterRegistered && g_filterWindowId == windowId) {
        return 0;
    }
    int32_t rc = OH_NativeWindowManager_RegisterMouseEventFilter(windowId, meow_mouse_filter);
    if (rc == 0) {
        g_filterRegistered = 1;
        g_filterWindowId = windowId;
        MEOWLOGI("mouse filter start window=%{public}d origin=%{public}f,%{public}f scale=%{public}f",
               windowId, originX, originY, g_filterScale);
    } else {
        MEOWLOGE("mouse filter start failed rc=%{public}d", (int)rc);
    }
    return (int)rc;
}

int meowMouseFilterStop(int32_t windowId) {
    int32_t rc = OH_NativeWindowManager_UnregisterMouseEventFilter(windowId);
    g_filterRegistered = 0;
    g_filterWindowId = 0;
    MEOWLOGI("mouse filter stop rc=%{public}d", (int)rc);
    return (int)rc;
}

/* ------------------------------------------------------------------------- */
/* grab mode: virtual cursor driven by raw mouse deltas                      */
/* ------------------------------------------------------------------------- */

static float g_grabCursorX;
static float g_grabCursorY;
static float g_grabSensitivity = 1.0f;

void meowGrabSetSens(float sensitivity) {
    g_grabSensitivity = sensitivity;
}

void meowGrabReset(float centerX, float centerY) {
    struct meow_environ_s *env = meow_environ;

    /*
     * "Recentering the pointer to the window centre" is a game-initiated warp and
     * PLATFORM FACT says OHOS cannot move the user's pointer, so the request
     * itself is a no-op: no cursor-slot write and no motion (the drop-in centre
     * coordinates are deliberately ignored).
     *
     * What IS kept: the bridge's grab-delta integration base is re-aligned to
     * the *current user pointer slot* (read-only). Otherwise the first
     * meowGrabDelta after entering grab would difference the whole "stale
     * accumulator -> real pointer" gap and send it as one huge relative turn
     * (loses the first move). Aligning only reads env->cursorX/Y; it never
     * writes the slot. After this, the slot is written by user input alone
     * (critical_send_cursor_pos absolute writes and genuine grab deltas), which
     * is exactly what the `ohos` pump reflects.
     */
    meow_trace_warp_ignored("grabreset", centerX, centerY);
    if (env == NULL) {
        return;
    }
    g_grabCursorX = (float)env->cursorX;
    g_grabCursorY = (float)env->cursorY;
}

void meowGrabDelta(float dx, float dy) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->grabbing) {
        return;
    }
    g_grabCursorX += dx * g_grabSensitivity;
    g_grabCursorY += dy * g_grabSensitivity;
    meow_trace_motion("bridge", g_grabCursorX, g_grabCursorY, env->grabbing);
    critical_send_cursor_pos(g_grabCursorX, g_grabCursorY);
    meow_rate_tick();
}

/*
 * 触屏 → 鼠标（窗口级 touch filter，与上面的 mouse filter 同族；API 15）。
 *
 * 语义（"触屏当鼠标"）：
 *   单指按下 = 光标跳到触点 + 左键按下；单指拖动 = 光标跟随；抬起 = 左键释放
 *   游戏内(grab) 单指拖动 = 转视角（喂 meow_touch_grab_delta，自带 grabbing 自检且只受触屏灵敏度）
 *   双指点按 = 右键（不做滚轮：MC 里可滚动处都有滚动条）
 *
 * 开关由上层以参数传入（启动器「高级选项」），不再读任何 env：早先的 MEOW_TOUCH
 * 环境变量与合成分支已删除，是否触屏当鼠标只看 Start 的 enable 入参。
 * 恒 `return false`（不消费），与 mouse filter 一致：ArkUI 仍需该事件。
 */
static int g_touchEnabled;
static int g_touchReg;
static int32_t g_touchWinId;
static int g_tFingers;
static int g_tLeftDown;
static int g_tTwoFinger;
static double g_tLastX;
static double g_tLastY;
static int64_t g_tDownMs;
/* 触屏转视角倍率（高级选项传入）。**独立于鼠标**：鼠标/node 路径用 g_grabSensitivity，
 * 两者不能共用，否则调触屏手感会连带改掉鼠标手感。 */
static float g_touchSens = 1.0f;
static int64_t g_tLastLogMs;
/* 触屏自己的原点/缩放（display px -> framebuffer）。**独立于鼠标**：鼠标 filter 用
 * g_filterOriginX/Y/Scale，触屏若共用，一旦两边取值不同，触屏 Start 会把鼠标定位改坏。 */
static double g_touchOriginX;
static double g_touchOriginY;
static double g_touchScale = 1.0;

/*
 * 双指点按判定上限（ms）：从第一指按下到全部抬起短于此值才算「点按」= 右键；长按
 * （拖拽 / 停留更久）不触发，避免双指操作起手误发右键。点按 vs 长按本质是时间判据，
 * 无事件可替代；450ms 与常见触摸长按阈值同量级，比典型点按（<200ms）宽裕。
 */
#define MEOW_TWO_FINGER_TAP_MS 450

/*
 * 虚拟按键排除区（display px，与 OH_Input_GetTouchEventDisplayX/Y 同空间）。
 * 命中这些矩形的触点「只按虚拟按键」，不驱动 MC 光标/点击；起手落在排除区的那根
 * 手指整段手势都跳过，其它手指照常。上限固定，解析失败/超限即跳过。
 */
#define MEOW_MAX_EXCLUDE_RECTS 24
#define MEOW_MAX_EXCLUDE_FINGERS 10

struct meow_exclude_rect {
    float x;
    float y;
    float w;
    float h;
};
/*
 * 双缓冲 + 原子发布槽位：ArkTS(NAPI) 线程只写「非当前」的那一份，写完整份（含条数）
 * 后再用 release 语义把 g_tExclActive 换成它；filter 线程先 acquire 读槽位，再只读该份。
 * 这样读方拿到的永远是一份写完的快照：既不会看到写一半的矩形，也不会有 count 瞬间为 0
 * 的中间态。两份轮流用，一次发布只搬动一个 int。 */
static struct meow_exclude_rect g_tExclRects[2][MEOW_MAX_EXCLUDE_RECTS];
static int g_tExclRectCounts[2];
static atomic_int g_tExclActive;
/* 起手落在排除区的手指 id 列表；这些手指的后续事件整体跳过。 */
static int g_tExclFingers[MEOW_MAX_EXCLUDE_FINGERS];
static int g_tExclFingerCount;

static const char *meow_touch_action_name(int a) {
    switch (a) {
        case TOUCH_ACTION_DOWN: return "DOWN";
        case TOUCH_ACTION_UP: return "UP";
        case TOUCH_ACTION_MOVE: return "MOVE";
        case TOUCH_ACTION_CANCEL: return "CANCEL";
        default: return "?";
    }
}

/* display px → Minecraft framebuffer 空间（用触屏自己那组原点/缩放，不碰鼠标的） */
static void meow_touch_local(double dx, double dy, double *lx, double *ly) {
    double s = (g_touchScale > 0.0) ? g_touchScale : 1.0;
    double x = (dx - g_touchOriginX) / s;
    double y = (dy - g_touchOriginY) / s;
    *lx = (x < 0.0) ? 0.0 : x;
    *ly = (y < 0.0) ? 0.0 : y;
}

/*
 * 上报虚拟按键排除区。CSV 形如 "x,y,w,h;x,y,w,h"，单位 display px；
 * 空串 / NULL 清空。逐段解析（允许空格），非 4 字段或宽高非正即跳过该段。
 */
void meowTouchSetExcludeRects(const char *csv) {
    /*
     * 先原子取「非当前」槽位来写，写完再发布。空串 / NULL 也走同一条发布路径，
     * 于是「清空」对读方同样是一次完整快照，而不是把正在用的 count 直接清零。
     */
    int slot = 1 - atomic_load_explicit(&g_tExclActive, memory_order_relaxed);
    int n = 0;

    if (csv != NULL && csv[0] != '\0') {
        const char *p = csv;
        while (*p != '\0' && n < MEOW_MAX_EXCLUDE_RECTS) {
            float x = 0.0f;
            float y = 0.0f;
            float w = 0.0f;
            float h = 0.0f;
            if (sscanf(p, "%f,%f,%f,%f", &x, &y, &w, &h) == 4 && w > 0.0f && h > 0.0f) {
                struct meow_exclude_rect *r = &g_tExclRects[slot][n];
                r->x = x;
                r->y = y;
                r->w = w;
                r->h = h;
                n++;
            }
            const char *semi = strchr(p, ';');
            if (semi == NULL) {
                break;
            }
            p = semi + 1;
        }
    }

    g_tExclRectCounts[slot] = n;
    /*
     * **不要在这里清 `g_tExclFingerCount`**：ArkTS 会在手势进行中重推排除区（首触标定、
     * IME/旋转/resize 引起的布局变化），若每次都清手指表，按住虚拟键的那根手指就会被
     * 中途「解封」⇒ 它的 MOVE 掉进"触屏当鼠标"路径 ⇒ 按虚拟键同时动视角 / 划视角乱飞。
     * 手指表的清理只属于「手势终结」（UP/CANCEL）与「会话边界」（Start 新窗口 / Stop），
     * 并且只允许 filter 线程触碰它（避免与 NAPI 线程竞态）。
     */
    atomic_store_explicit(&g_tExclActive, slot, memory_order_release);
    MEOWLOGI("touch exclude rects n=%{public}d", n);
}

static bool meow_touch_in_exclude(double dx, double dy) {
    /* acquire 读到已发布的槽位，该槽位内容（含条数）在 release 之前已写完。 */
    int slot = atomic_load_explicit(&g_tExclActive, memory_order_acquire);
    int count = g_tExclRectCounts[slot];
    const struct meow_exclude_rect *rects = g_tExclRects[slot];
    for (int i = 0; i < count; i++) {
        const struct meow_exclude_rect *r = &rects[i];
        if (dx >= (double)r->x && dx < (double)(r->x + r->w) &&
            dy >= (double)r->y && dy < (double)(r->y + r->h)) {
            return true;
        }
    }
    return false;
}

static bool meow_touch_excl_finger_has(int fid) {
    for (int i = 0; i < g_tExclFingerCount; i++) {
        if (g_tExclFingers[i] == fid) {
            return true;
        }
    }
    return false;
}

static void meow_touch_excl_finger_add(int fid) {
    if (meow_touch_excl_finger_has(fid) || g_tExclFingerCount >= MEOW_MAX_EXCLUDE_FINGERS) {
        return;
    }
    g_tExclFingers[g_tExclFingerCount++] = fid;
}

static void meow_touch_excl_finger_remove(int fid) {
    for (int i = 0; i < g_tExclFingerCount; i++) {
        if (g_tExclFingers[i] == fid) {
            g_tExclFingers[i] = g_tExclFingers[g_tExclFingerCount - 1];
            g_tExclFingerCount--;
            return;
        }
    }
}

/*
 * 一次触屏会话的全部单次状态复位。Start/Stop 都调：若上一段手势丢了收尾的 UP/CANCEL，
 * 双指标志 / 手指计数 / 排除手指会一直挂着，导致光标与左键到重启前都失效。复位时若左键
 * 还按着，先补发一次释放，防粘键。
 */
static void meow_touch_reset_gesture(void) {
    if (g_tLeftDown) {
        critical_send_mouse_button(0, 0, 0);
        g_tLeftDown = 0;
    }
    g_tFingers = 0;
    g_tTwoFinger = 0;
    g_tLastX = 0.0;
    g_tLastY = 0.0;
    g_tDownMs = 0;
    g_tExclFingerCount = 0;
    g_tLastLogMs = 0;
}

/*
 * 触屏专用转视角累加，语义与 meowGrabDelta 相同，但**只**按 g_touchSens 缩放，
 * 不再被鼠标/node 的 g_grabSensitivity 二次缩放。触点位置仍落在同一个虚拟抓取光标上，
 * 这样进入 grab 时的 meowGrabReset 对两种输入都生效。dx/dy 为 display px 位移。
 */
static void meow_touch_grab_delta(double dx, double dy) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->grabbing) {
        return;
    }
    double s = (g_touchScale > 0.0) ? g_touchScale : 1.0;
    /* 手感因子 = 触屏灵敏度设置 × 光标灵敏度基值(g_grabSensitivity)。
     * 后者是进 grab 时由 ArkTS 设定的**基值**，与鼠标/node 路径共用；触屏只读不写它，
     * 所以"动触屏设置不影响鼠标手感"仍然成立。**两个因子都要留**：只留前者会让视角
     * 按 g_grabSensitivity 的倍数突然变快（2026-09-21 实测"划视角乱飞"）。 */
    double k = (double)g_touchSens * (double)g_grabSensitivity;
    g_grabCursorX += (float)(dx / s * k);
    g_grabCursorY += (float)(dy / s * k);
    meow_trace_motion("touchmap", g_grabCursorX, g_grabCursorY, env->grabbing);
    critical_send_cursor_pos(g_grabCursorX, g_grabCursorY);
    meow_rate_tick();
}

static bool meow_touch_filter(Input_TouchEvent *event) {
    struct meow_environ_s *env = meow_environ;
    if (event == NULL) {
        return false;
    }
    int action = OH_Input_GetTouchEventAction(event);
    int fid = OH_Input_GetTouchEventFingerId(event);
    double dx = (double)OH_Input_GetTouchEventDisplayX(event);
    double dy = (double)OH_Input_GetTouchEventDisplayY(event);

    /*
     * 整段手势被取消：一次到位复位。**不能只减一格手指计数** —— 双指场景下 g_tTwoFinger
     * 不清、计数又回不到 0 ⇒ 之后每次 DOWN 都把它顶回 2 ⇒ 永久卡在双指模式（单指点击与
     * 拖动全被吞，直到 Stop）。取消事件也未必带有效 fingerId，所以按"整段终结"处理。
     */
    if (action == TOUCH_ACTION_CANCEL) {
        meow_touch_reset_gesture();
        return false;
    }

    /*
     * 虚拟按键排除区：命中即本指整段手势「只按按钮」。在计数之前判定，使落在按键上的
     * 手指**不参与 g_tFingers**（否则会误触发双指右键，把另一根手指的转视角/光标顶掉）；
     * 手指计数靠 g_tExclFingers 单独维护，抬手时移除，不会漂移。
     */
    bool exclDown = (action == TOUCH_ACTION_DOWN) && meow_touch_in_exclude(dx, dy);
    /* 一次 DOWN 就是该 id 新手势的起点：若上一段手势漏了 UP、列表里还残留这个 id，
     * 这里先摘掉，否则「重用的 id 起手在区外」会被整段误跳过。 */
    if (action == TOUCH_ACTION_DOWN && !exclDown) {
        meow_touch_excl_finger_remove(fid);
    }
    bool exclHeld = meow_touch_excl_finger_has(fid);
    if (exclDown || exclHeld) {
        if (exclDown) {
            meow_touch_excl_finger_add(fid);
            if (g_tLeftDown) { /* 之前由别的手指按下的左键补一次释放，防粘键 */
                critical_send_mouse_button(0, 0, 0);
                g_tLeftDown = 0;
            }
        }
        if (action == TOUCH_ACTION_UP) {
            meow_touch_excl_finger_remove(fid);
        }
        return false;
    }

    if (action == TOUCH_ACTION_DOWN) {
        g_tFingers++;
    } else if (action == TOUCH_ACTION_UP) {
        if (g_tFingers > 0) {
            g_tFingers--;
        }
    }

    /* 诊断（节流 200ms；MOVE 可达 150–500Hz，全打会淹掉日志） */
    int64_t now = meow_now_ms();
    if (now - g_tLastLogMs >= 200) {
        g_tLastLogMs = now;
        MEOWLOGI("touch %{public}s fid=%{public}d x=%{public}d y=%{public}d fingers=%{public}d en=%{public}d",
                 meow_touch_action_name(action), fid, (int)dx, (int)dy, g_tFingers, g_touchEnabled);
    }

    if (!g_touchEnabled || env == NULL || !env->isInputReady) {
        return false;
    }

    /* 升级为双指：本手势不再走单指逻辑 */
    if (action == TOUCH_ACTION_DOWN && g_tFingers >= 2) {
        g_tTwoFinger = 1;
        g_tLastY = dy;
        if (g_tLeftDown) { /* 第二指落下 = 取消已按下的左键 */
            critical_send_mouse_button(0, 0, 0);
            g_tLeftDown = 0;
        }
        return false;
    }

    if (g_tTwoFinger) {
        /* 双指不做滚轮（MC 里可滚动处都有滚动条）；只保留「双指点按 = 右键」。 */
        if ((action == TOUCH_ACTION_UP || action == TOUCH_ACTION_CANCEL) && g_tFingers == 0) {
            if ((now - g_tDownMs) < MEOW_TWO_FINGER_TAP_MS) {
                critical_send_mouse_button(1, 1, 0);
                critical_send_mouse_button(1, 0, 0);
            }
            g_tTwoFinger = 0;
        }
        return false;
    }

    /* 单指 */
    if (action == TOUCH_ACTION_DOWN) {
        g_tDownMs = now;
        g_tLastX = dx;
        g_tLastY = dy;
        /* 游戏内(grab) **故意不发左键**：那里单指拖动是用来转视角的，若按下即攻击
         * 会「一转视角就开始挖」（2026-09-21 实测反馈）。⇒ 光标定位与左键按下都只在
         * 非 grab 做。破坏/攻击的触屏方案以后再定，勿当 bug"修"掉。
         * 右键（双指点按）不受此限，一直可用。 */
        if (!env->grabbing) {
            double lx = 0.0;
            double ly = 0.0;
            meow_touch_local(dx, dy, &lx, &ly);
            meow_trace_motion("touchmap", lx, ly, env->grabbing);
            critical_send_cursor_pos((float)lx, (float)ly);
            critical_send_mouse_button(0, 1, 0);
            g_tLeftDown = 1;
        }
        return false;
    }

    if (action == TOUCH_ACTION_MOVE) {
        if (env->grabbing) {
            meow_touch_grab_delta(dx - g_tLastX, dy - g_tLastY);
        } else {
            double lx = 0.0;
            double ly = 0.0;
            meow_touch_local(dx, dy, &lx, &ly);
            meow_trace_motion("touchmap", lx, ly, env->grabbing);
            critical_send_cursor_pos((float)lx, (float)ly);
            meow_rate_tick(); /* 与鼠标路径一致，供速率浮层统计 */
        }
        g_tLastX = dx;
        g_tLastY = dy;
        return false;
    }

    if (action == TOUCH_ACTION_UP || action == TOUCH_ACTION_CANCEL) {
        if (g_tLeftDown) {
            critical_send_mouse_button(0, 0, 0); /* 左键释放 */
            g_tLeftDown = 0;
        }
        if (g_tFingers == 0) {
            g_tTwoFinger = 0;
        }
    }
    return false;
}

int meowTouchFilterStart(int32_t windowId, double originX, double originY, double scale, int enable,
                         double sens) {
    /*
     * 参数（原点/缩放/开关/灵敏度）可以每次刷新：ArkTS 在触摸过程中会反复重推它们。
     * **但绝不能在这里复位手势状态** —— 曾把它们放在同一个函数里一起做，于是"每次刷新
     * 都 reset"在手势进行中每 ~100ms 发生一次，把上次坐标清零 ⇒ 下一个 MOVE 从 0 算增量
     * （划视角乱飞），并把排除区的手指记忆清掉 ⇒ 按虚拟键不再被排除（按键同时动视角）。
     * 一个根因，两个症状。复位只在**真正的会话边界**做（窗口变了 / 之前 Stop 过）。
     */
    g_touchOriginX = originX;
    g_touchOriginY = originY;
    g_touchScale = (scale > 0.0) ? scale : 1.0;
    /* 开关被关掉（1→0）时若此前按下了左键，**补一次释放**：否则该释放会随下面的门控一起
     * 被跳过 ⇒ 左键粘住、一直挖/放。门控只该挡"新增输入"，不该挡"收尾"。 */
    if (g_touchEnabled && enable == 0 && g_tLeftDown) {
        critical_send_mouse_button(0, 0, 0);
        g_tLeftDown = 0;
    }
    /* 开关由上层（启动器「高级选项」）以参数传入，不用 env（能参数化就不加 env）。 */
    g_touchEnabled = (enable != 0) ? 1 : 0;
    g_touchSens = (sens > 0.0) ? (float)sens : 1.0f;
    if (g_touchReg && g_touchWinId == windowId) {
        return 0; /* 同一窗口：纯参数刷新，不动手势状态 */
    }
    /* 新会话：复位，避免把上一段手势的残留（漏收尾的 UP/CANCEL）带进来。 */
    meow_touch_reset_gesture();
    int32_t rc = OH_NativeWindowManager_RegisterTouchEventFilter(windowId, meow_touch_filter);
    if (rc == 0) {
        g_touchReg = 1;
        g_touchWinId = windowId;
        MEOWLOGI("touch filter start window=%{public}d origin=%{public}f,%{public}f scale=%{public}f enabled=%{public}d",
                 windowId, originX, originY, g_touchScale, g_touchEnabled);
    } else {
        MEOWLOGE("touch filter start failed rc=%{public}d", (int)rc);
    }
    return (int)rc;
}

int meowTouchFilterStop(int32_t windowId) {
    int32_t rc = OH_NativeWindowManager_UnregisterTouchEventFilter(windowId);
    g_touchReg = 0;
    g_touchWinId = 0;
    meow_touch_reset_gesture();
    MEOWLOGI("touch filter stop rc=%{public}d", (int)rc);
    return (int)rc;
}

/* ------------------------------------------------------------------------- */
/* input sampling-rate meter (used by the in-game overlay)                   */
/* ------------------------------------------------------------------------- */

static unsigned long g_rateCount;
static int64_t g_rateWindowStart;

static void meow_rate_tick(void) {
    int64_t now = meow_now_ms();
    if (g_rateWindowStart == 0 || now - g_rateWindowStart >= 1000) {
        g_rateWindowStart = now;
        g_rateCount = 0;
    }
    g_rateCount++;
}

int meowRateGet(void) {
    if (g_rateWindowStart == 0) {
        return 0;
    }
    int64_t now = meow_now_ms();
    int64_t elapsed = now - g_rateWindowStart;
    if (elapsed <= 0 || elapsed > 1500) {
        return 0; /* idle for too long */
    }
    return (int)((double)g_rateCount * 1000.0 / (double)elapsed);
}
