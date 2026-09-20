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
#include <stdlib.h>
#include <time.h>

#include <multimodalinput/oh_input_manager.h>
#include <window_manager/oh_window_event_filter.h>

#include "meowlog.h"
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
    if (meow_environ == NULL) {
        return;
    }
    meow_environ->cLastX = meow_environ->cursorX = xpos;
    meow_environ->cLastY = meow_environ->cursorY = ypos;
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
    (void)jenv;
    (void)clazz;
    (void)action;
    (void)copySrc;
    MEOWLOGI("nativeClipboard: not implemented, returning null");
    return NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(
    JNIEnv *jenv, jclass clazz, jboolean grabbing) {
    (void)jenv;
    (void)clazz;
    if (meow_environ != NULL) {
        meow_environ->grabbing = grabbing ? 1 : 0;
        meow_environ->isGrabbing = grabbing ? 1u : 0u;
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
    g_grabCursorX = centerX;
    g_grabCursorY = centerY;
    critical_send_cursor_pos(centerX, centerY);
}

void meowGrabDelta(float dx, float dy) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || !env->grabbing) {
        return;
    }
    g_grabCursorX += dx * g_grabSensitivity;
    g_grabCursorY += dy * g_grabSensitivity;
    critical_send_cursor_pos(g_grabCursorX, g_grabCursorY);
    meow_rate_tick();
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
