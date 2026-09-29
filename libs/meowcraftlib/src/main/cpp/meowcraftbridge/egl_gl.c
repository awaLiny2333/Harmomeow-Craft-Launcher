/*
 * egl_gl.c - Meowcraft's EGL/desktop-GL bridge and surface channel.
 *
 * This file implements:
 *   - the eleven plain-C meow* entry points that the Java GLFW stub resolves
 *     through SharedLibrary.apiGetFunctionAddress();
 *   - the surface channel used by ArkTS: meowSetSurfaceId() turns an ArkUI
 *     surface id into an OH_NativeWindow and publishes it in the shared state
 *     block, meowResizeSurface() records a new geometry from the UI thread, and
 *     meow_egl_apply_resize() performs the actual EGL work later on the render
 *     thread.
 *
 * EGL objects are created lazily on first use and are expected to be touched
 * only from the JVM render thread. The native window backing the EGL window
 * surface is always state->window; when none is available a 1x1 pbuffer is
 * substituted so a usable GL context still exists.
 *
 * The context is desktop OpenGL 3.2 when the platform exposes it, falling back
 * to OpenGL ES 2. Swap interval is pinned to 0 (immediate).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <dlfcn.h>
#include <stdio.h>

#include <EGL/egl.h>
#include <native_window/external_window.h>
#include <native_buffer/native_buffer.h>

#include "meowlog.h"
#include "meowcraftbridge_environ.h"
#include "meowqos.h"
#include "meowbt.h"

/* GLFW window hints that this bridge understands. */
#define MEOW_GLFW_CLIENT_API 0x22001
#define MEOW_GLFW_NO_API 0
#define MEOW_GLFW_OPENGL_API 0x30001

typedef struct {
    EGLDisplay display;
    EGLConfig config;
    EGLContext context;
    EGLSurface surface;
    void *surfaceWindow; /* state->window the current surface was made for */
    int displayReady;
    int contextReady;
} MeowEglState;

static MeowEglState g_egl = {EGL_NO_DISPLAY, (EGLConfig)0, EGL_NO_CONTEXT, EGL_NO_SURFACE,
                             NULL, 0, 0};

static void *g_boundWindow;      /* window seen by meowMakeCurrent */
static int g_windowHandle;       /* stable, non-null "GLFW window" address */
static int g_hintPair[2];        /* last meowSetWindowHint (hint, value) */

/*
 * Size last successfully applied on the render thread. Zero means "nothing
 * applied yet", which forces the first pump/swap after a window change to
 * rebuild the surface.
 */
static int g_appliedWidth;
static int g_appliedHeight;

/* Defined below. VULKAN-ONLY (F78): the EGL/GL window path must keep the window
 * buffer usage exactly as base did, so this is applied only from the Vulkan WSI
 * surface path (glfwCreateWindowSurface), never from the GL path. */
static void meow_apply_window_usage(OHNativeWindow *win);

/* Vulkan WSI window policy (see the definition). Only the GLFW path uses it; the SDL3
 * `ohos` driver in tools/sdl deliberately does not -- see SDL_ohosvulkan.c for why. */
static void meow_vk_prepare_surface_window(void *nativeWindow);

/* Context-registry entry points (defined further down; meowTerminate calls the destroy
 * one, and our LWJGL2 shim resolves all three by name at runtime). */
int meowMakeCurrentFor(void *window, void *handle);
void *meowCreateSharedContext(void *share);
void meowDestroySharedContext(void *handle);

/* ------------------------------------------------------------------------- */
/* gl4es (desktop-GL -> GLES fixed-function translator) support              */
/* ------------------------------------------------------------------------- *
 * When MEOWCRAFT_RENDERER=gl4es the bridge creates a GLES context (gl4es wraps
 * a GLES context) and, once that context is current, dlopen()s libgl4es.so and
 * runs its explicit initializer (gl4es is built with NO_INIT_CONSTRUCTOR).
 * LWJGL then drives gl4es directly through
 * -Dorg.lwjgl.opengl.libname=libgl4es.so (gl4es exports glXGetProcAddress).
 * Swapping stays host-side, i.e. the eglSwapBuffers() below. */
static int g_gl4es;      /* renderer is GLES + gl4es */
static int g_gl4esInit;  /* initialize_gl4es() already called */
static void *g_gl4esGlesLib; /* dlopen'ed GLES lib handle (gl4es backend + proc resolver) */

/* GL3 core backend (MC 1.17+): GL 3.2/3.3 core served by the native GLES 3.2
 * driver through the gl4es fork's core backend (tools/gl4es/deltas/glcore, symbol
 * namespace meowcore_*). Selected by env MEOW_GL3=1; skips desktop GL and the FPE. */
static int g_gl4esCore;

#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
#ifndef EGL_CONTEXT_MINOR_VERSION
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#endif

static int meow_gl3_requested(void) {
    const char *v = getenv("MEOW_GL3");
    return v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
}

static int renderer_is_gl4es(void) {
    const char *r = getenv("MEOWCRAFT_RENDERER");
    return r != NULL && strcmp(r, "gl4es") == 0;
}

/* Open the GLES library gl4es runs on. We probe candidates in-process and keep
 * the first that actually loads; the handle is retained both to pin the library
 * and to serve as a last-resort symbol source for the proc-address resolver
 * (gl4es needs one under NOEGL to run its hardware detection). */
static void gl4es_export_backend(void) {
    const char *preset = getenv("LIBGL_GLES");
    if (preset != NULL) {
        g_gl4esGlesLib = dlopen(preset, RTLD_NOW | RTLD_LOCAL);
        if (g_gl4esGlesLib != NULL) {
            MEOWLOGI("gl4es backend GLES: %{public}s", preset);
            return;
        }
    }
    const char *cands[] = {
        "/system/lib64/libGLESv3.so", "/system/lib64/ndk/libGLESv2.so",
        "libGLESv3.so", "libGLESv2.so", NULL
    };
    for (int i = 0; cands[i] != NULL; ++i) {
        void *h = dlopen(cands[i], RTLD_NOW | RTLD_LOCAL);
        if (h != NULL) {
            g_gl4esGlesLib = h;
            setenv("LIBGL_GLES", cands[i], 1);
            MEOWLOGI("gl4es backend GLES: %{public}s", cands[i]);
            return;
        }
    }
    MEOWLOGW("gl4es: no loadable GLES library found");
}

/* Proc-address resolver handed to gl4es via set_getprocaddress(). gl4es returns
 * this value verbatim (no internal dlsym fallback), so it must cover every name:
 * EGL proc lookup first, then already-loaded symbols, then the GLES lib handle. */
static void *gl4es_getproc(const char *name) {
    void *p = (void *)eglGetProcAddress(name);
    if (p != NULL) {
        return p;
    }
    p = dlsym(RTLD_DEFAULT, name);
    if (p != NULL) {
        return p;
    }
    if (g_gl4esGlesLib != NULL) {
        p = dlsym(g_gl4esGlesLib, name);
    }
    return p;
}

/* Main-framebuffer size callback gl4es uses for glBlitFramebuffer. */
static void gl4es_getmainfbsize(int *width, int *height) {
    if (meow_environ != NULL && meow_environ->width > 0 && meow_environ->height > 0) {
        *width = meow_environ->width;
        *height = meow_environ->height;
    } else {
        *width = 1;
        *height = 1;
    }
}

/* ------------------------------------------------------------------------- */
/* gl4es per-EGL-context state binding (Forge-splash root fix, 2026-09-29)    */
/* ------------------------------------------------------------------------- *
 * gl4es (fork delta tools/gl4es/deltas/glcore/src/gl/meowctx.c) exports
 * meow_gl4es_bind(EGLContext): it hands each EGL context its own glstate, so two
 * threads can no longer corrupt a single process-global state. FML 1.7.10's
 * console splash does exactly that — the splash thread renders on the main
 * context while the main thread holds the shared context the whole loading phase
 * (pause()/resume() are never called), so with one global state the two threads
 * race gl4es's immediate-mode transaction / display-list state => SIGSEGV or an
 * absurd vertex count => SIGTRAP (see notes/20-design/launch/
 * Forge-splash-崩溃根因与共享上下文修复.md and notes/00-current/已知限制与待解.md C11).
 *
 * The bridge and libgl4es.so are SEPARATE shared objects and gl4es is only
 * dlopen()ed at runtime, so this is resolved with dlsym (never a link-time
 * dependency). An older libgl4es.so without the symbol degrades safely: one
 * stable English log, then no-op for the rest of the process.
 */
typedef void *(*meow_gl4es_bind_fn)(void *eglContext);
typedef void *(*meow_gl4es_unbind_fn)(void);
typedef void  (*meow_gl4es_forget_fn)(void *eglContext);

static meow_gl4es_bind_fn   g_gl4esBind;
static meow_gl4es_unbind_fn g_gl4esUnbind;
static meow_gl4es_forget_fn g_gl4esForget;
static int g_gl4esHookLogged;   /* one-shot: resolved / missing */

/* Resolve the optional hook out of the dlopen()ed libgl4es.so. Idempotent. */
static void gl4es_resolve_ctx_hooks(void *lib) {
    if (lib == NULL || g_gl4esBind != NULL || g_gl4esHookLogged) {
        return;
    }
    g_gl4esBind   = (meow_gl4es_bind_fn)dlsym(lib, "meow_gl4es_bind");
    g_gl4esUnbind = (meow_gl4es_unbind_fn)dlsym(lib, "meow_gl4es_unbind");
    g_gl4esForget = (meow_gl4es_forget_fn)dlsym(lib, "meow_gl4es_forget");
    g_gl4esHookLogged = 1;
    if (g_gl4esBind == NULL) {
        MEOWLOGW("gl4es: meow_gl4es_bind not found (old libgl4es.so?); per-context "
                 "gl4es state disabled - a shared-context splash is still unsafe");
    } else {
        MEOWLOGI("gl4es: per-context state hook active (meow_gl4es_bind)");
    }
}

/* Tell gl4es which EGL context is current on THIS thread. EGL_NO_CONTEXT means
 * "released". No-op unless the FPE gl4es path is active: the GL3 core backend
 * (MEOW_GL3=1) never calls initialize_gl4es() and has no gl4es state. */
static void gl4es_notify_current(void *eglctx) {
    if (!g_gl4es || g_gl4esCore) {
        return;
    }
    if (eglctx == NULL || eglctx == (void *)EGL_NO_CONTEXT) {
        if (g_gl4esUnbind != NULL) {
            g_gl4esUnbind();
        } else if (g_gl4esBind != NULL) {
            g_gl4esBind(NULL); /* bind(NULL) is documented as unbind */
        }
        return;
    }
    if (g_gl4esBind != NULL) {
        g_gl4esBind(eglctx);
    }
}

/* dlopen gl4es and run initialize_gl4es() (requires a current GLES context). */
static void gl4es_init_once(void) {
    if (!g_gl4es || g_gl4esInit) {
        return;
    }
    if (g_gl4esCore) {
        /* Core backend: the FPE path is bypassed on purpose. We only need the library
         * loaded so LWJGL's -Dorg.lwjgl.opengl.libname resolves and gl4es'
         * glXGetProcAddress can serve the meowcore_* surface (the delta's hook). */
        const char *dir = getenv("MEOWCRAFT_NATIVEDIR");
        char path[512];
        void *lib = NULL;
        if (dir != NULL && dir[0] != '\0') {
            snprintf(path, sizeof(path), "%s/libgl4es.so", dir);
            lib = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        }
        if (lib == NULL) {
            lib = dlopen("libgl4es.so", RTLD_NOW | RTLD_GLOBAL);
        }
        if (lib == NULL) {
            MEOWLOGE("gl4es core: dlopen failed: %{public}s", dlerror());
            return;
        }
        MEOWLOGI("gl4es core backend loaded; FPE initialize_gl4es() skipped (MEOW_GL3=1)");
        g_gl4esInit = 1;
        return;
    }
    gl4es_export_backend();
    const char *dir = getenv("MEOWCRAFT_NATIVEDIR");
    char path[512];
    void *lib = NULL;
    if (dir != NULL && dir[0] != '\0') {
        snprintf(path, sizeof(path), "%s/libgl4es.so", dir);
        lib = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    }
    if (lib == NULL) {
        lib = dlopen("libgl4es.so", RTLD_NOW | RTLD_GLOBAL);
    }
    if (lib == NULL) {
        MEOWLOGE("gl4es: dlopen failed: %{public}s", dlerror());
        return;
    }
    /* Optional per-EGL-context state hook (see the section above); absent in an
     * older libgl4es.so and then simply inactive. */
    gl4es_resolve_ctx_hooks(lib);
    void (*setfb)(void (*)(int *, int *)) =
        (void (*)(void (*)(int *, int *)))dlsym(lib, "set_getmainfbsize");
    if (setfb != NULL) {
        setfb(gl4es_getmainfbsize);
    }
    /* gl4es under NOEGL needs a proc-address resolver to run its hardware
     * detection; without it, it reports "unknown renderer" and skips feature
     * detection (`notest = !gles_getProcAddress`, init.c). */
    void (*setproc)(void *(*)(const char *)) =
        (void (*)(void *(*)(const char *)))dlsym(lib, "set_getprocaddress");
    if (setproc != NULL) {
        setproc(gl4es_getproc);
        MEOWLOGI("gl4es: proc-address resolver set");
    }
    void (*init)(void) = (void (*)(void))dlsym(lib, "initialize_gl4es");
    if (init == NULL) {
        MEOWLOGE("gl4es: initialize_gl4es not found");
        return;
    }
    init();
    MEOWLOGI("gl4es: initialized on GLES context");
    void *(*getstr)(unsigned int) = (void *(*)(unsigned int))dlsym(lib, "glGetString");
    if (getstr != NULL) {
        MEOWLOGI("gl4es reports GL_VERSION=%{public}s GL_RENDERER=%{public}s",
                 (const char *)getstr(0x1F02), (const char *)getstr(0x1F01));
    }
    g_gl4esInit = 1; /* only on success; a failed attempt may be retried */
}

/* ------------------------------------------------------------------------- */
/* display / config / context                                                */
/* ------------------------------------------------------------------------- */

static int egl_ensure_display(void) {
    if (g_egl.displayReady) {
        return 1;
    }
    g_egl.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_egl.display == EGL_NO_DISPLAY) {
        MEOWLOGE("eglGetDisplay failed: %{public}x", eglGetError());
        return 0;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(g_egl.display, &major, &minor) != EGL_TRUE) {
        MEOWLOGE("eglInitialize failed: %{public}x", eglGetError());
        eglTerminate(g_egl.display);
        g_egl.display = EGL_NO_DISPLAY;
        return 0;
    }
    MEOWLOGI("EGL initialized %{public}d.%{public}d", (int)major, (int)minor);
    g_egl.displayReady = 1;
    return 1;
}

static EGLConfig egl_pick_config(EGLint renderableType) {
    const EGLint attrs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, renderableType,
        EGL_NONE
    };
    EGLint count = 0;
    if (eglChooseConfig(g_egl.display, attrs, NULL, 0, &count) != EGL_TRUE || count <= 0) {
        return (EGLConfig)0;
    }
    EGLConfig config = (EGLConfig)0;
    if (eglChooseConfig(g_egl.display, attrs, &config, 1, &count) != EGL_TRUE) {
        return (EGLConfig)0;
    }
    return config;
}

/* ------------------------------------------------------------------------- */
/* context registry (LWJGL2 SharedDrawable / background-loading contract)    */
/* ------------------------------------------------------------------------- *
 * LWJGL2's SharedDrawable is built with `new ContextGL(peer_info, attribs, context)`,
 * i.e. it asks the platform for a SECOND GL context that SHARES objects with the
 * primary one — plain GLX semantics, and the reason FML's 1.7.10 console splash can
 * render on a thread of its own. This bridge used to hand the very same EGL context
 * back for the share, so the splash thread's eglMakeCurrent() could only fail with
 * EGL_BAD_ACCESS (3002 — the context was still current on the render thread); the
 * thread then ran gl4es with NO current context and the process died with SIGSEGV
 * (measured 2026-09-29; evidence chain in notes 20-design/launch).
 *
 * A slot maps an opaque Java-side handle to one EGL context plus its OWN surface: EGL
 * binds a surface to at most one context at a time, so a secondary context may not
 * reuse the primary's window surface. Secondaries get a 1x1 pbuffer — the splash's
 * output is never presented (meowSwapBuffers is a no-op for them) and a pbuffer cannot
 * contend with the real window.
 */
#define MEOW_MAX_CTX 6

typedef struct {
    void *handle;       /* Java-side opaque handle (the MeowContext buffer address) */
    EGLContext context; /* EGL_NO_CONTEXT until the primary has actually been created */
    EGLSurface surface; /* secondary: own pbuffer; primary: unused (g_egl.surface) */
    int primary;
} MeowCtxSlot;

static MeowCtxSlot g_ctxSlots[MEOW_MAX_CTX];
static __thread MeowCtxSlot *t_currentSlot; /* slot bound on the calling thread */

/* Attributes of the last successfully created context: a shared context must match the
 * primary's version/profile, so we replay these instead of guessing. */
static EGLint g_ctxAttrs[8];
static int g_ctxAttrCount;

static void meow_ctx_remember_attrs(const EGLint *attrs) {
    int n = 0;
    while (attrs != NULL && attrs[n] != EGL_NONE &&
           n < (int)(sizeof(g_ctxAttrs) / sizeof(g_ctxAttrs[0])) - 1) {
        g_ctxAttrs[n] = attrs[n];
        ++n;
    }
    g_ctxAttrs[n] = EGL_NONE;
    g_ctxAttrCount = n;
}

/* eglCreateContext + remember the attributes it took. Every create site goes through
 * here, so g_ctxAttrs always mirrors the primary context. */
static EGLContext meow_create_context_with(const EGLint *attrs) {
    EGLContext c = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, attrs);
    if (c != EGL_NO_CONTEXT) {
        meow_ctx_remember_attrs(attrs);
    }
    return c;
}

static MeowCtxSlot *meow_slot_find(void *handle) {
    for (int i = 0; i < MEOW_MAX_CTX; ++i) {
        if (g_ctxSlots[i].handle == handle) {
            return &g_ctxSlots[i];
        }
    }
    return NULL;
}

/* First free slot, or NULL when the table is full. The slot's own address is the opaque
 * handle the rest of the file (and our LWJGL2 shim) uses. */
static MeowCtxSlot *meow_slot_alloc(void) {
    for (int i = 0; i < MEOW_MAX_CTX; ++i) {
        if (g_ctxSlots[i].handle == NULL) {
            return &g_ctxSlots[i];
        }
    }
    return NULL;
}

static int egl_ensure_context(void) {
    if (g_egl.contextReady) {
        return 1;
    }
    if (!egl_ensure_display()) {
        return 0;
    }

    /* GL3 core backend (MEOW_GL3=1): MC 1.17+ asks for GL 3.2/3.3 core; we hand it the
     * native GLES 3.2 driver, served by the gl4es fork's core backend. No desktop GL,
     * no FPE. Takes precedence over the gl4es(FPE) and desktop-GL branches below. */
    if (meow_gl3_requested()) {
        g_gl4es = 1;
        g_gl4esCore = 1;
        g_egl.config = egl_pick_config(EGL_OPENGL_ES3_BIT);
        if (g_egl.config == (EGLConfig)0) {
            MEOWLOGE("gl4es core: no EGL config for ES3");
            return 0;
        }
        if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
            MEOWLOGW("eglBindAPI(EGL_OPENGL_ES_API) failed: %{public}x", eglGetError());
        }
        const EGLint coreAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3,
                                    EGL_CONTEXT_MINOR_VERSION, 2, EGL_NONE};
        g_egl.context = meow_create_context_with(coreAttrs);
        if (g_egl.context == EGL_NO_CONTEXT) {
            MEOWLOGE("gl4es core: eglCreateContext (ES3.2) failed: %{public}x", eglGetError());
            return 0;
        }
        MEOWLOGI("created OpenGL ES 3.2 context for gl4es core backend (MEOW_GL3=1)");
        g_egl.contextReady = 1;
        return 1;
    }

    /* GLES + gl4es path (MC <=1.16 fixed pipeline): gl4es wraps a GLES context.
     * The desktop-GL/compat path below is skipped entirely. */
    if (renderer_is_gl4es()) {
        g_gl4es = 1;
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
        g_egl.config = egl_pick_config(EGL_OPENGL_ES2_BIT);
        if (g_egl.config == (EGLConfig)0) {
            g_egl.config = egl_pick_config(EGL_OPENGL_ES3_BIT);
        }
        if (g_egl.config == (EGLConfig)0) {
            MEOWLOGE("gl4es: no EGL config for ES2/ES3");
            return 0;
        }
        if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
            MEOWLOGW("eglBindAPI(EGL_OPENGL_ES_API) failed: %{public}x", eglGetError());
        }
        const EGLint esAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        g_egl.context = meow_create_context_with(esAttrs);
        if (g_egl.context == EGL_NO_CONTEXT) {
            MEOWLOGE("gl4es: eglCreateContext (GLES2) failed: %{public}x", eglGetError());
            return 0;
        }
        MEOWLOGI("created OpenGL ES2 context for gl4es");
        g_egl.contextReady = 1;
        return 1;
    }

    /* Preferred backend: desktop OpenGL 3.2. For legacy fixed-function renderers
     * (MC <=1.16) ArkTS sets MEOWCRAFT_GL_PROFILE=compat -> request a COMPATIBILITY
     * profile; otherwise (>=1.17 core renderer) use the plain 3.2 core context.
     * A rejected compat request falls back to core. */
    g_egl.config = egl_pick_config(EGL_OPENGL_BIT);
    if (g_egl.config != (EGLConfig)0) {
        if (eglBindAPI(EGL_OPENGL_API) != EGL_TRUE) {
            MEOWLOGW("eglBindAPI(EGL_OPENGL_API) failed: %{public}x", eglGetError());
        }
        const char *glProfile = getenv("MEOWCRAFT_GL_PROFILE");
        if (glProfile != NULL && strcmp(glProfile, "compat") == 0) {
#ifndef EGL_CONTEXT_OPENGL_PROFILE_MASK
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#endif
#ifndef EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT
#define EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT 0x00000002
#endif
            const EGLint compatAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2,
                                          EGL_CONTEXT_OPENGL_PROFILE_MASK,
                                          EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT, EGL_NONE};
            g_egl.context = meow_create_context_with(compatAttrs);
            if (g_egl.context != EGL_NO_CONTEXT) {
                MEOWLOGI("created desktop OpenGL 3.2 COMPATIBILITY-profile context");
                g_egl.contextReady = 1;
                return 1;
            }
            MEOWLOGW("compat-profile 3.2 ctx rejected: %{public}x, using core", eglGetError());
        }
        /* Explore the system desktop-GL ceiling: try 4.2 core first (more
         * extensions may unlock optional fast paths), fall back to 3.2 core. */
        const EGLint hiAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 2,
                                  EGL_NONE};
        g_egl.context = meow_create_context_with(hiAttrs);
        if (g_egl.context != EGL_NO_CONTEXT) {
            MEOWLOGI("created desktop OpenGL 4.2 (core) context");
            g_egl.contextReady = 1;
            return 1;
        }
        MEOWLOGW("GL 4.2 core ctx rejected: %{public}x, trying 3.2", eglGetError());
        const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2,
                                   EGL_NONE};
        g_egl.context = meow_create_context_with(ctxAttrs);
        if (g_egl.context != EGL_NO_CONTEXT) {
            MEOWLOGI("created desktop OpenGL 3.2 (core) context");
            g_egl.contextReady = 1;
            return 1;
        }
        MEOWLOGW("desktop GL context failed: %{public}x, falling back to GLES2", eglGetError());
    }

    /* Fallback: OpenGL ES 2. */
    g_egl.config = egl_pick_config(EGL_OPENGL_ES2_BIT);
    if (g_egl.config == (EGLConfig)0) {
        MEOWLOGE("no EGL config for EGL_OPENGL_BIT or EGL_OPENGL_ES2_BIT");
        return 0;
    }
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        MEOWLOGW("eglBindAPI(EGL_OPENGL_ES_API) failed: %{public}x", eglGetError());
    }
    const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    g_egl.context = meow_create_context_with(ctxAttrs);
    if (g_egl.context == EGL_NO_CONTEXT) {
        MEOWLOGE("eglCreateContext (GLES2) failed: %{public}x", eglGetError());
        return 0;
    }
    MEOWLOGI("created OpenGL ES2 context (fallback)");
    g_egl.contextReady = 1;
    return 1;
}

/*
 * Build a fresh EGL surface for the current state->window. The producer buffer
 * geometry is pinned to the size Minecraft currently expects before the window
 * surface is created, which avoids a first-frame skew where the window rect
 * and the surface height disagree.
 */
static EGLSurface egl_build_surface(void) {
    void *win = (meow_environ != NULL) ? meow_environ->window : NULL;

    if (win != NULL) {
        if (meow_environ->width > 0 && meow_environ->height > 0) {
            OH_NativeWindow_NativeWindowHandleOpt((OHNativeWindow *)win, SET_BUFFER_GEOMETRY,
                                                  meow_environ->width, meow_environ->height);
        }
        /* F78: no window-usage mutation on the GL path -- the EGL window surface
         * must present with the platform's original buffer usage, exactly as
         * before the Vulkan work (A23 F-M1). The Vulkan WSI path applies its own
         * CPU_READ clear in glfwCreateWindowSurface. */
        EGLSurface surface = eglCreateWindowSurface(
            g_egl.display, g_egl.config, (EGLNativeWindowType)(uintptr_t)win, NULL);
        if (surface != EGL_NO_SURFACE) {
            g_egl.surfaceWindow = win;
            eglSwapInterval(g_egl.display, 0);
            MEOWLOGI("EGL window surface created for %{public}p", win);
            return surface;
        }
        MEOWLOGW("eglCreateWindowSurface failed: %{public}x, using pbuffer", eglGetError());
    }

    const EGLint pbAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(g_egl.display, g_egl.config, pbAttrs);
    if (surface == EGL_NO_SURFACE) {
        MEOWLOGE("eglCreatePbufferSurface failed: %{public}x", eglGetError());
        return EGL_NO_SURFACE;
    }
    g_egl.surfaceWindow = NULL;
    MEOWLOGI("EGL 1x1 pbuffer surface created (no window)");
    return surface;
}

/*
 * Surface for a SECONDARY (shared) context. Deliberately a pbuffer: EGL binds a surface
 * to at most one context at a time, so a secondary context must not take the primary's
 * window surface, and the only shared-context consumer we know (FML's console splash)
 * never presents its output — meowSwapBuffers() is a no-op for secondaries.
 */
static EGLSurface egl_build_secondary_surface(void) {
    const EGLint pbAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface s = eglCreatePbufferSurface(g_egl.display, g_egl.config, pbAttrs);
    if (s == EGL_NO_SURFACE) {
        MEOWLOGE("shared ctx: eglCreatePbufferSurface failed: %{public}x", eglGetError());
    }
    return s;
}

/* glthread（GALLIUM_THREAD=1）下，销毁/重建 EGL surface 前必须把 Mesa threaded-context
 * 的队列**排空**，否则驱动侧可能仍引用旧 surface → use-after-free。
 * 实机 2026-09-13：开 glthread 后在加载屏随机 SIGSEGV(ACCERR) 被杀，且恰好发生在一次
 * surface 重建之后。关闭 glthread 时本函数是 no-op（不给常规路径加 glFinish 同步）。 */
static int g_tcChecked = 0;
static int g_tcOn = 0;
static void (*g_glFinish)(void) = NULL;
static void meow_drain_tc(void) {
    if (!g_tcChecked) {
        const char *v = getenv("GALLIUM_THREAD");
        g_tcOn = (v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0'));
        if (g_tcOn) {
            g_glFinish = (void (*)(void))eglGetProcAddress("glFinish");
            if (g_glFinish == NULL) {
                g_glFinish = (void (*)(void))dlsym(RTLD_DEFAULT, "glFinish");
            }
            MEOWLOGI("glthread on -> drain before surface ops (glFinish=%{public}p)",
                     (void *)g_glFinish);
        }
        g_tcChecked = 1;
    }
    if (g_tcOn && g_glFinish != NULL) {
        g_glFinish();
    }
}

/* Detach and destroy the current surface, if any. */
static void egl_drop_surface(void) {
    if (g_egl.surface == EGL_NO_SURFACE) {
        return;
    }
    meow_drain_tc();
    eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    /* This thread no longer has a context: let gl4es detach its per-context state. */
    gl4es_notify_current((void *)EGL_NO_CONTEXT);
    eglDestroySurface(g_egl.display, g_egl.surface);
    g_egl.surface = EGL_NO_SURFACE;
    g_egl.surfaceWindow = NULL;
}

/* ------------------------------------------------------------------------- */
/* GL info probe (diagnostic: MEOW_GLINFO=1)                                 */
/* ------------------------------------------------------------------------- *
 * Logs GL_VERSION/GL_RENDERER and whether a set of extension-gated features is
 * advertised. Used to verify that MESA_EXTENSION_OVERRIDE actually removed an
 * extension (MC 26.x picks its buffer/transient-memory path from these). */
static int g_glinfoDone = 0;
static void meow_gl_info_once(void) {
    if (g_glinfoDone) {
        return;
    }
    const char *en = getenv("MEOW_GLINFO");
    if (en == NULL || en[0] == '\0' || (en[0] == '0' && en[1] == '\0')) {
        return;
    }
    g_glinfoDone = 1;

    typedef const unsigned char *(*GetStringFn)(unsigned int);
    typedef void (*GetIntegervFn)(unsigned int, int *);
    typedef const unsigned char *(*GetStringiFn)(unsigned int, unsigned int);
    /* 用 `eglGetProcAddress` 直连（= 驱动/Mesa 真值）。**这是对的**：能力过滤现在走 **Mesa 层**
     * （`MESA_EXTENSION_OVERRIDE`，进程级生效）⇒ 直连也能看到"被藏掉"的结果 ✓。
     * （2026-09-16 教训：曾以为必须走 guard 的 `glXGetProcAddress`；实测 GL 层过滤**到不了 LWJGL** ✗
     *  ⇒ 那条路已撤销，见 `meowglguard.c` 顶部注释。） */
    GetStringFn getString = (GetStringFn)eglGetProcAddress("glGetString");
    GetIntegervFn getIntegerv = (GetIntegervFn)eglGetProcAddress("glGetIntegerv");
    GetStringiFn getStringi = (GetStringiFn)eglGetProcAddress("glGetStringi");
    if (getString == NULL || getIntegerv == NULL || getStringi == NULL) {
        MEOWLOGW("glinfo: procs missing (gs=%{public}p gi=%{public}p gsi=%{public}p)",
                 (void *)getString, (void *)getIntegerv, (void *)getStringi);
        return;
    }
    MEOWLOGI("glinfo: GL_VERSION=%{public}s GL_RENDERER=%{public}s",
             (const char *)getString(0x1F02), (const char *)getString(0x1F01));
    int n = 0;
    getIntegerv(0x821D /* GL_NUM_EXTENSIONS */, &n);
    MEOWLOGI("glinfo: num_extensions=%{public}d", n);
    static const char *keys[] = {
        "GL_ARB_buffer_storage", "GL_ARB_direct_state_access", "GL_ARB_multi_draw_indirect",
        "GL_ARB_draw_indirect", "GL_ARB_base_instance", "GL_ARB_vertex_attrib_binding",
        "GL_ARB_clip_control", "GL_ARB_shader_draw_parameters", "GL_ARB_debug_output",
        /* compute 家族：Flywheel INDIRECT 的 gating 项。用来验证「用 MESA_EXTENSION_OVERRIDE 把 compute
         * 藏掉」是否真的生效（2026-09-16：本机驱动 Bisheng 编译器在编译合法 compute SPIR-V 时会空指针崩溃，
         * 见 notes 20-design/render/1.21.1-崩溃-两条链与随包规避.md §1）。 */
        "GL_ARB_compute_shader", "GL_ARB_shader_storage_buffer_object",
        "GL_ARB_shader_image_load_store", "GL_ARB_shader_image_size",
        "GL_ARB_shader_atomic_counters", "GL_ARB_gpu_shader5", NULL
    };
    for (int k = 0; keys[k] != NULL; ++k) {
        int found = 0;
        for (int i = 0; i < n && !found; ++i) {
            const char *e = (const char *)getStringi(0x1F03 /* GL_EXTENSIONS */, (unsigned)i);
            if (e != NULL && strcmp(e, keys[k]) == 0) {
                found = 1;
            }
        }
        MEOWLOGI("glinfo: %{public}s=%{public}s", keys[k], found ? "YES" : "no");
    }
}

/* Ensure a surface exists for the current state->window and make it current. */
static int egl_bind(void) {
    if (!egl_ensure_context()) {
        return 0;
    }
    void *win = (meow_environ != NULL) ? meow_environ->window : NULL;
    if (g_egl.surface == EGL_NO_SURFACE || g_egl.surfaceWindow != win) {
        egl_drop_surface();
        g_egl.surface = egl_build_surface();
        if (g_egl.surface == EGL_NO_SURFACE) {
            return 0;
        }
    }
    if (eglMakeCurrent(g_egl.display, g_egl.surface, g_egl.surface, g_egl.context) != EGL_TRUE) {
        MEOWLOGE("eglMakeCurrent failed: %{public}x", eglGetError());
        return 0;
    }
    /* Swap interval only takes effect while a surface is current. */
    eglSwapInterval(g_egl.display, 0);
    /* gl4es must be initialized only after its GLES context is current. */
    gl4es_init_once();
    /* Give gl4es the now-current context's own state (root fix; see the section
     * above). Must run AFTER gl4es_init_once(), which resolves the hook. */
    gl4es_notify_current((void *)g_egl.context);
    /* 一次性 GL 能力探针（诊断；env 门控）。 */
    meow_gl_info_once();
    return 1;
}

/* ------------------------------------------------------------------------- */
/* render-thread resize helper (called from the pump and from swap)          */
/* ------------------------------------------------------------------------- */

int meow_egl_apply_resize(int width, int height) {
    if (width <= 0 || height <= 0) {
        MEOWLOGE("apply resize: bad size %{public}d x %{public}d", width, height);
        return -1;
    }
    if (g_appliedWidth == width && g_appliedHeight == height) {
        return 0;
    }

    if (g_egl.surface != EGL_NO_SURFACE) {
        if (!egl_ensure_context()) {
            return -1;
        }
        /* Recreating on a live surface is an EGL error: tear down first. */
        egl_drop_surface();
        if (!egl_bind()) {
            MEOWLOGE("apply resize %{public}d x %{public}d: rebuild failed, will retry", width,
                   height);
            return -1; /* not recorded: the swap self-heal retries */
        }
        MEOWLOGI("apply resize %{public}d x %{public}d", width, height);
    } else {
        /* Vulkan-only session: no EGL surface exists to rebuild, but the window's producer
         * buffer geometry must still track the real surface size, otherwise
         * vkGetPhysicalDeviceSurfaceCapabilitiesKHR keeps reporting the startup fallback
         * (1280x720) as currentExtent while MC builds its swapchain at its own size.
         * This runs on the render thread (glfwPollEvents -> meowPumpEvents -> here), so
         * touching the NativeWindow here respects the UI-thread-must-not rule. */
        void *win = (meow_environ != NULL) ? meow_environ->window : NULL;
        if (win != NULL) {
            OH_NativeWindow_NativeWindowHandleOpt((OHNativeWindow *)win, SET_BUFFER_GEOMETRY, width,
                                                  height);
            /* Final geometry now equals the display-scale-derived surface size, so
             * vkGetPhysicalDeviceSurfaceCapabilitiesKHR.currentExtent tracks it too. */
            MEOWLOGI("apply resize %{public}d x %{public}d -> window geometry (vulkan path, "
                     "scale-derived)", width, height);
        } else {
            MEOWLOGW("apply resize %{public}d x %{public}d: no window to update geometry",
                     width, height);
        }
    }

    g_appliedWidth = width;
    g_appliedHeight = height;
    return 0;
}

uintptr_t meow_current_window_handle(void) {
    if (meow_environ != NULL && meow_environ->showingWindow != NULL) {
        return (uintptr_t)meow_environ->showingWindow;
    }
    return (uintptr_t)(void *)&g_windowHandle;
}

/* ------------------------------------------------------------------------- */
/* meow* API                                                                */
/* ------------------------------------------------------------------------- */

int meowInit(void) {
    if (meow_environ != NULL) {
        /* Resolved lazily: MEOWCRAFT_RENDERER is set just before JVM launch, after
         * the state block's constructor already ran. 1 = desktop GL, 2 = GLES+gl4es. */
        meow_environ->config_renderer = renderer_is_gl4es() ? 2 : 1;
    }
    MEOWLOGI("meowInit (renderer=%{public}d window=%{public}p)",
           meow_environ != NULL ? meow_environ->config_renderer : -1,
           meow_environ != NULL ? meow_environ->window : NULL);
    if (meow_environ == NULL) {
        return 0;
    }
    return 1;
}

void meowTerminate(void) {
    MEOWLOGI("meowTerminate");
    /* Tear the shared contexts down before the display goes away. meowDestroySharedContext
     * skips the primary slot (an app-level ContextGL.destroy() must never tear this down);
     * the primary EGL context itself is destroyed below, at process exit. */
    for (int i = 0; i < MEOW_MAX_CTX; ++i) {
        if (g_ctxSlots[i].handle != NULL) {
            meowDestroySharedContext(&g_ctxSlots[i]);
            memset(&g_ctxSlots[i], 0, sizeof(g_ctxSlots[i]));
        }
    }
    t_currentSlot = NULL;
    if (g_egl.display != EGL_NO_DISPLAY) {
        egl_drop_surface();
        if (g_egl.context != EGL_NO_CONTEXT) {
            /* The primary EGL context IS destroyed here (unlike the app-level ContextGL.destroy(),
             * which meowDestroySharedContext ignores for the primary). Drop its gl4es state
             * registry entry first, exactly as meowDestroySharedContext does for secondaries, so
             * the registry never outlives the EGLContext it keys on (that address may be reused
             * by a later context). The state object itself is still never freed -- see
             * meow_gl4es_forget(). */
            if (g_gl4esForget != NULL) {
                g_gl4esForget((void *)g_egl.context);
            }
            eglDestroyContext(g_egl.display, g_egl.context);
            g_egl.context = EGL_NO_CONTEXT;
        }
        eglTerminate(g_egl.display);
        g_egl.display = EGL_NO_DISPLAY;
    }
    g_egl.displayReady = 0;
    g_egl.contextReady = 0;
    g_egl.surfaceWindow = NULL;
    g_boundWindow = NULL;
}

void *meowGetCurrentContext(void) {
    return g_boundWindow;
}

void *meowCreateContext(void *share) {
    (void)share;
    if (!egl_ensure_context()) {
        return NULL;
    }
    /* Single-window bridge: hand back a stable non-null pseudo window. */
    return (void *)&g_windowHandle;
}

/*
 * Bind the context named by `handle` (NULL = the primary) on the calling thread.
 * Returns 1 on success and 0 when nothing could be bound. A caller MUST NOT claim the
 * context is current after a 0: that is precisely the mistake that turned a failed
 * make-current into a SIGSEGV inside gl4es (see the registry comment above).
 */
int meowMakeCurrentFor(void *window, void *handle) {
    /* 渲染线程首次进入时：按 MEOW_QOS 提升线程 QoS；按 MEOW_BT 装 crash 抓栈。 */
    meow_qos_apply_current_thread();
    meow_bt_install_once();
    g_boundWindow = window;
    if (window == NULL) {
        /*
         * GLFW/LWJGL 语义：glfwMakeContextCurrent(NULL) = 在**调用线程上解除**上下文绑定。
         * 必须真的 release —— 曾把 NULL 当成"再绑一次"，导致上下文一直留在调用线程上。
         * 实测（NeoForge 1.21.1 / FML 早窗口）：其 GL 线程做完后 release（NULL），我们却把它
         * 重新绑回该线程 → MC 的 Render thread 再 makeCurrent 时 EGL_BAD_ACCESS(0x3002) →
         * GL.createCapabilities() 拿不到上下文 → 启动即崩（Window.<init>）。
         */
        t_currentSlot = NULL;
        if (g_egl.display != EGL_NO_DISPLAY) {
            eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        /* Released on this thread => gl4es detaches its per-context state here. */
        gl4es_notify_current((void *)EGL_NO_CONTEXT);
        return 1;
    }

    MeowCtxSlot *slot = (handle != NULL) ? meow_slot_find(handle) : NULL;
    if (slot != NULL && slot->primary) {
        /* Keep the slot's view of the EGL context in sync: it is the share parent for
         * any secondary context created later. */
        if (egl_ensure_context()) {
            slot->context = g_egl.context;
        }
    }
    if (slot == NULL || slot->primary) {
        if (!egl_bind()) {
            MEOWLOGW("meowMakeCurrent: no GL context/surface available");
            return 0;
        }
        t_currentSlot = slot; /* NULL when LWJGL did not tell us which context this is */
        return 1;
    }

    /* Secondary (shared) context: own pbuffer surface, same display and config. */
    if (!egl_ensure_context()) {
        return 0;
    }
    if (slot->surface == EGL_NO_SURFACE) {
        slot->surface = egl_build_secondary_surface();
        if (slot->surface == EGL_NO_SURFACE) {
            return 0;
        }
    }
    if (eglMakeCurrent(g_egl.display, slot->surface, slot->surface, slot->context) != EGL_TRUE) {
        MEOWLOGE("shared ctx makeCurrent failed: %{public}x", eglGetError());
        return 0;
    }
    /* gl4es must be initialised before any GL entry point runs on this thread: a shared
     * context can legitimately bind before the render thread ever made one current. */
    gl4es_init_once();
    /* Bind the SHARED context's own glstate on this thread (root fix). It is a child of
     * the first-bound context's state, so the object tables stay shared, but this thread's
     * matrix/enable/transaction state is now isolated from the other context's thread. */
    gl4es_notify_current((void *)slot->context);
    t_currentSlot = slot;
    return 1;
}

void meowMakeCurrent(void *window) {
    (void)meowMakeCurrentFor(window, NULL);
}

/*
 * Register a context handle and — when `share` names an existing slot — create a real
 * second EGL context whose objects are shared with it. This is LWJGL2's SharedDrawable
 * contract (DrawableGL.createSharedContext() -> new ContextGL(peer_info, attribs, ctx)),
 * i.e. plain GLX behaviour that desktop MC relies on for FML's console splash.
 *
 * ★2026-09-29 政策（本轮翻转）：**默认允许共享上下文**。此前默认拒绝，是因为共享上下文一旦
 * 真建起来，splash 线程与主线程会**并发驱动 gl4es 的同一个进程级 `glstate`** ⇒ 数据竞争 ⇒
 * 实机 SIGSEGV/SIGTRAP（`<HM_GPU> # Over the threasHold … vertexSum: 22364413`）。该竞争已由
 * **每 EGL 上下文隔离 glstate** 修掉：gl4es delta `tools/gl4es/deltas/glcore/src/gl/meowctx.c`
 * 把 `glstate` 变 `__thread` 并导出 `meow_gl4es_bind`，本文件每次成功 `eglMakeCurrent` 后按上下文
 * 绑定。实机（2026-09-29 23:26）FML splash **打开**时跑至干净退出：日志有 `[meow-ctx] … (root)` +
 * `… (shared child of root)`、`gl4es: per-context state hook active`，零 `rethrow signo(11)`。
 * ⇒ 默认回到"允许"，把 env 改造成**显式退出开关**（语义见 meow_allow_shared_ctx()）。
 *
 * 另一条**硬门**见 meowCreateSharedContext()：FPE 渲染下若 per-context hook 不可用（旧
 * `libgl4es.so`，dlsym 失败）⇒ **无条件拒绝**，因为那时"允许" = 重新引入上面那条竞争。
 *
 * `share == NULL` registers the primary slot and creates nothing eagerly: the primary EGL
 * context stays lazy (first make-current). Returns the handle to pass back to
 * meowMakeCurrentFor()/meowDestroySharedContext(), or NULL on failure.
 */
/* env 真值解析：`0` 或 `false`（ASCII 大小写不敏感）= 假；其余（含空）= 真。 */
static int meow_env_is_false(const char *v) {
    if (v == NULL || v[0] == '\0') {
        return 0;
    }
    if (v[0] == '0' && v[1] == '\0') {
        return 1;
    }
    const char *f = "false";
    int i = 0;
    for (; f[i] != '\0'; ++i) {
        char c = v[i];
        if (c >= 'A' && c <= 'Z') {
            c = (char)(c - 'A' + 'a');
        }
        if (c != f[i]) {
            return 0;
        }
    }
    return v[i] == '\0';
}

static int meow_allow_shared_ctx(void) {
    /*
     * 默认**允许**（见上面的政策块；共享上下文现已安全，2026-09-29 实机验证）。语义 = 显式退出开关：
     *   - 未设 / 空      ⇒ 允许（新默认）
     *   - `1` 或其它真值 ⇒ 允许（`=1` 继续表示"允许"，与用户既有设置兼容）
     *   - `0` / `false`  ⇒ 拒绝（用户知情关闭；FML 1.7.10 会把拒绝变成致命异常，故只作诊断/规避）
     * 本决策**只**看 env；per-context hook 的可用性是另一道硬门（meowCreateSharedContext）。
     */
    static int allow = -1;
    if (allow < 0) {
        const char *e = getenv("MEOW_ALLOW_SHARED_CTX");
        allow = meow_env_is_false(e) ? 0 : 1;
    }
    return allow;
}

void *meowCreateSharedContext(void *share) {
    if (share == NULL) {
        for (int i = 0; i < MEOW_MAX_CTX; ++i) {
            if (g_ctxSlots[i].primary) {
                return &g_ctxSlots[i];
            }
        }
        MeowCtxSlot *s = meow_slot_alloc();
        if (s == NULL) {
            MEOWLOGE("ctx registry: full (%{public}d), no slot for the primary", MEOW_MAX_CTX);
            return NULL;
        }
        memset(s, 0, sizeof(*s));
        s->handle = s;
        s->context = EGL_NO_CONTEXT;
        s->surface = EGL_NO_SURFACE;
        s->primary = 1;
        MEOWLOGI("ctx registry: primary slot %{public}p", (void *)s);
        return s;
    }

    if (!meow_allow_shared_ctx()) {
        /* 用户显式退出（MEOW_ALLOW_SHARED_CTX=0/false）。返回 NULL ⇒ shim 抛 LWJGLException。
         * ★对 FML 1.7.10 这**不是**"自禁 splash 后游戏继续"：SplashProgress.start() 捕获该
         * LWJGLException 后直接 `throw new RuntimeException(e)`（SplashProgress.java:199），
         * 该类**不含** disableSplash 调用（disableSplash() 只从 finish() 引用、崩溃后永不执行）
         * ⇒ 新装实例每次启动都崩。真因/证据见 notes 00-current/已知限制与待解.md C11。 */
        MEOWLOGW("shared ctx: refused (MEOW_ALLOW_SHARED_CTX=0/false); FML 1.7.10 turns this "
                 "into a fatal RuntimeException at SplashProgress.java:199");
        return NULL;
    }

    if (!egl_ensure_context()) {
        MEOWLOGE("shared ctx: no primary context to share with");
        return NULL;
    }

    /*
     * 硬门（2026-09-29）：共享上下文**只在** gl4es 的 per-context state hook 可用时才安全。
     * FPE 渲染下两个上下文各跑一个线程：hook 不可用（旧 `libgl4es.so`，dlsym 失败 ⇒ 只剩一个
     * 进程级 `glstate`）时允许共享 = 重新引入 2026-09-29 修掉的 SIGSEGV/SIGTRAP。此门与 env 策略
     * **正交**：env 允许也不够，hook 缺了就无条件拒绝。core 后端（MEOW_GL3）不用 gl4es state
     * （`gl4es_notify_current` 直接返回），不受此限；非 gl4es（桌面 GL）也没有可竞争的 gl4es 状态。
     * 该拒绝**必须显眼**：它会让 shim 抛 LWJGLException ⇒ FML 1.7.10 变成致命 RuntimeException
     * （SplashProgress.java:199）⇒ 解释"为什么接下来会 FML fatal"。
     */
    if (g_gl4es && !g_gl4esCore && g_gl4esBind == NULL) {
        MEOWLOGW("shared ctx refused: per-context gl4es state hook unavailable "
                 "(old libgl4es.so?) - FML 1.7.10 will fail at SplashProgress.java:199");
        return NULL;
    }
    MeowCtxSlot *parent = meow_slot_find(share);
    if (parent == NULL) {
        MEOWLOGE("shared ctx: unknown share handle %{public}p", share);
        return NULL;
    }
    if (parent->primary) {
        parent->context = g_egl.context;
    }
    if (g_ctxAttrCount == 0 || parent->context == EGL_NO_CONTEXT) {
        MEOWLOGE("shared ctx: parent has no context to share (attrs=%{public}d)", g_ctxAttrCount);
        return NULL;
    }

    EGLContext ctx = eglCreateContext(g_egl.display, g_egl.config, parent->context, g_ctxAttrs);
    if (ctx == EGL_NO_CONTEXT) {
        MEOWLOGE("shared ctx: eglCreateContext(share=%{public}p) failed: %{public}x",
                 (void *)parent->context, eglGetError());
        return NULL;
    }
    MeowCtxSlot *slot = meow_slot_alloc();
    if (slot == NULL) {
        MEOWLOGE("ctx registry: full (%{public}d), shared ctx discarded", MEOW_MAX_CTX);
        eglDestroyContext(g_egl.display, ctx);
        return NULL;
    }
    memset(slot, 0, sizeof(*slot));
    slot->handle = slot;
    slot->context = ctx;
    slot->surface = EGL_NO_SURFACE;
    slot->primary = 0;
    MEOWLOGI("shared ctx created: share=%{public}p -> ctx=%{public}p slot=%{public}p",
             (void *)parent->context, (void *)ctx, (void *)slot);
    return slot;
}

/* Destroy a secondary context (own surface + context). The primary slot is skipped: an
 * app-level LWJGL ContextGL.destroy() must not tear the bridge's primary state down. The
 * primary IS destroyed at process exit, by meowTerminate() (which also forgets its state). */
void meowDestroySharedContext(void *handle) {
    MeowCtxSlot *slot = meow_slot_find(handle);
    if (slot == NULL || slot->primary) {
        return;
    }
    if (t_currentSlot == slot) {
        if (g_egl.display != EGL_NO_DISPLAY) {
            eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        /* Released on this thread => gl4es detaches this thread's per-context state. */
        gl4es_notify_current((void *)EGL_NO_CONTEXT);
        t_currentSlot = NULL;
    }
    /* Drop the gl4es state registry entry for this EGLContext BEFORE it is destroyed, so a
     * later context that reuses the same address cannot inherit this one's stale state. */
    if (slot->context != EGL_NO_CONTEXT && g_gl4esForget != NULL) {
        g_gl4esForget((void *)slot->context);
    }
    if (slot->surface != EGL_NO_SURFACE) {
        eglDestroySurface(g_egl.display, slot->surface);
    }
    if (slot->context != EGL_NO_CONTEXT) {
        eglDestroyContext(g_egl.display, slot->context);
    }
    MEOWLOGI("shared ctx destroyed: slot=%{public}p", handle);
    memset(slot, 0, sizeof(*slot));
}

void meowSetWindowHint(int hint, int value) {
    g_hintPair[0] = hint;
    g_hintPair[1] = value;
    MEOWLOGD("meowSetWindowHint hint=%{public}x value=%{public}d", hint, value);
    /*
     * This bridge is desktop-GL-first, so the only hints that matter are
     * GLFW_CLIENT_API / GLFW_OPENGL_API, both of which are honoured implicitly.
     */
}

/*
 * ---------------------------------------------------------------- Vulkan WSI
 *
 * LWJGL's GLFWVulkan resolves these six names STRAIGHT FROM THIS LIBRARY
 * (apiGetFunctionAddress(GLFW.getLibrary(), "glfwVulkanSupported"), ...), so they must be plain C
 * exports: the class initialiser runs `apiGetFunctionAddress` for all six at once, and a single
 * missing symbol makes the whole class fail to load. That is why even the entry points MC does not
 * call are implemented here.
 *
 * A surface is only ever created from the real OHNativeWindow the bridge got from the ArkUI
 * XComponent surface id (meow_environ->window, set by meowSetSurfaceId). vkCreateSurfaceOHOS does
 * NOT validate its window argument -- a NULL one SIGSEGVs on this ICD (measured, notes section
 * 7.3) -- so when there is no window we FAIL instead of passing a handle we cannot vouch for.
 */
#define MEOW_VK_ST_SURFACE_CREATE_INFO_OHOS 1000685000   /* vulkan_core.h:1238 */
#define MEOW_VK_ERROR_INITIALIZATION_FAILED (-3)
#define MEOW_VK_ERROR_EXTENSION_NOT_PRESENT (-7)

typedef struct {
    uint32_t sType;
    const void *pNext;
    uint32_t flags;
    void *window;   /* OHNativeWindow* */
} meow_vk_surface_ci_ohos;

static const char *g_vkRequiredExts[2] = { "VK_KHR_surface", "VK_OHOS_surface" };

static void *meow_vk_loader(void) {
    static void *s_loader = NULL;
    if (s_loader == NULL) {
        s_loader = dlopen("/system/lib64/libvulkan.so", RTLD_NOW | RTLD_LOCAL);
        if (s_loader == NULL) {
            MEOWLOGE("meow vk wsi: dlopen real loader failed: %{public}s", dlerror());
        }
    }
    return s_loader;
}

/* Meowcraft's own Vulkan loader shim (libmeowvulkan.so). LWJGL loads it as its Vulkan library
 * (-Dorg.lwjgl.vulkan.libname=libmeowvulkan.so) and it is the component that applies the
 * extension/feature corrections and maps KHR/EXT names to the core names this ICD really exports.
 * Resolving it by name keeps GLFW's proc-address entry point from silently bypassing those
 * corrections. It may not be shared yet when this runs, so dlopen it; the shim itself resolves
 * /system/lib64/libvulkan.so, so this never recurses back into the bridge. If it is absent the
 * callers below fall back to the raw system loader. */
static void *meow_vk_shim(void) {
    static void *s_shim = NULL;
    static int s_tried = 0;
    if (!s_tried) {
        s_tried = 1;
        s_shim = dlopen("libmeowvulkan.so", RTLD_NOW | RTLD_LOCAL);
        if (s_shim == NULL) {
            MEOWLOGW("meow vk wsi: dlopen(libmeowvulkan.so) failed (%{public}s) -> raw system loader",
                     dlerror());
        }
    }
    return s_shim;
}

int glfwVulkanSupported(void) {
    MEOWLOGI("glfwVulkanSupported -> 1");
    return 1;
}

const char **glfwGetRequiredInstanceExtensions(uint32_t *count) {
    if (count != NULL) *count = 2;
    MEOWLOGI("glfwGetRequiredInstanceExtensions -> {VK_KHR_surface, VK_OHOS_surface}");
    return g_vkRequiredExts;
}

int glfwGetPhysicalDevicePresentationSupport(void *instance, void *physicalDevice, uint32_t queueFamily) {
    /* ALWAYS 1 -- a deliberate simplification, NOT a real query.
     * WHY NOT A REAL QUERY: GLFW's desktop implementations check
     * vkGetPhysicalDevice{Win32,Xlib,Wayland,MacOS}PresentationSupportKHR, but OHOS exposes no such
     * per-platform presentation-support entry point, and the real check
     * (vkGetPhysicalDeviceSurfaceSupportKHR) needs a VkSurfaceKHR that this API does not receive.
     * We could create one from meow_environ->window, but this may be called before the
     * instance/device/window are all valid and vkCreateSurfaceOHOS SIGSEGVs on a bad window
     * (measured, notes section 7.3), so fabricating a surface here would add crash risk for no gain.
     * CONSEQUENCE: MC uses the result only to pick a queue family; every graphics-capable family on
     * this ICD presents, and the authoritative check is done later through
     * vkGetPhysicalDeviceSurfaceSupportKHR via the shim. Callers must not read this as validation. */
    (void)instance;
    (void)physicalDevice;
    (void)queueFamily;
    return 1;
}

long glfwGetInstanceProcAddress(void *instance, const char *procname) {
    /* Prefer our own shim (see meow_vk_shim). This used to dlopen /system/lib64/libvulkan.so and
     * call its vkGetInstanceProcAddr directly, bypassing the shim's KHR/EXT -> core name mapping:
     * callers that resolved through GLFW then saw NULL for names like vkCmdBeginRenderingKHR. */
    void *(*gipa)(void *, const char *) = NULL;
    void *shim = meow_vk_shim();
    if (shim != NULL) {
        gipa = dlsym(shim, "vkGetInstanceProcAddr");
    }
    if (gipa == NULL) {
        void *loader = meow_vk_loader();
        if (loader == NULL) return 0;
        gipa = dlsym(loader, "vkGetInstanceProcAddr");
    }
    if (gipa == NULL) return 0;
    /* GLFW's contract: asking for vkGetInstanceProcAddr itself returns the loader's own entry point,
     * which the caller then re-uses for every other lookup. Hand back the shim's, so those
     * re-resolutions stay on the corrected path instead of escaping to the raw loader. */
    if (procname != NULL && strcmp(procname, "vkGetInstanceProcAddr") == 0) {
        return (long)gipa;
    }
    return (long)gipa(instance, procname);
}

void glfwInitVulkanLoader(void *loader) {
    /* Intentionally a no-op. GLFW's real implementation remembers `loader` and uses it for every
     * subsequent Vulkan lookup; here that would reintroduce the bypass removed above, because an
     * externally supplied entry point is not necessarily shim-aware. This stub instead always
     * prefers the shim and only falls back to /system/lib64/libvulkan.so when the shim is absent.
     * CONSEQUENCE: an app that deliberately passes a custom vkGetInstanceProcAddr gets the shim's
     * loader instead; for MC/LWJGL that is the intended path anyway (org.lwjgl.vulkan.libname is
     * already libmeowvulkan.so), so lookups stay consistent. */
    (void)loader;
}

int glfwCreateWindowSurface(void *instance, void *window, const void *allocator, void *pSurface) {
    (void)window;      /* the GLFW handle is not an OHNativeWindow; the bridge owns the real one */
    (void)allocator;
    MEOWLOGI("glfwCreateWindowSurface: ENTER (instance=%{public}p envWindow=%{public}p)", instance,
             (meow_environ != NULL) ? meow_environ->window : NULL);
    if (instance == NULL || pSurface == NULL) return MEOW_VK_ERROR_INITIALIZATION_FAILED;
    void *nw = (meow_environ != NULL) ? meow_environ->window : NULL;
    if (nw == NULL) {
        MEOWLOGE("glfwCreateWindowSurface: meow_environ->window is NULL (no surface id yet) -> refusing");
        return MEOW_VK_ERROR_INITIALIZATION_FAILED;
    }
    void *loader = meow_vk_loader();
    if (loader == NULL) return MEOW_VK_ERROR_INITIALIZATION_FAILED;
    void *(*gipa)(void *, const char *) = dlsym(loader, "vkGetInstanceProcAddr");
    if (gipa == NULL) return MEOW_VK_ERROR_INITIALIZATION_FAILED;
    int (*createSurface)(void *, const meow_vk_surface_ci_ohos *, const void *, void **) =
        gipa(instance, "vkCreateSurfaceOHOS");
    if (createSurface == NULL) {
        MEOWLOGE("glfwCreateWindowSurface: vkCreateSurfaceOHOS not resolvable");
        return MEOW_VK_ERROR_EXTENSION_NOT_PRESENT;
    }
    /* Pin the producer geometry and apply the usage/format policy before the VkSurface exists. */
    meow_vk_prepare_surface_window(nw);
    meow_vk_surface_ci_ohos ci = { MEOW_VK_ST_SURFACE_CREATE_INFO_OHOS, NULL, 0, nw };
    void *surface = NULL;
    int rc = createSurface(instance, &ci, NULL, &surface);
    if (pSurface != NULL) *(void **)pSurface = surface;
    MEOWLOGI("glfwCreateWindowSurface: window=%{public}p rc=%{public}d surface=%{public}p", nw, rc,
             surface);
    return rc;
}

/* Vulkan WSI window policy: Vulkan counterpart of egl_build_surface(). Pin the
 * producer buffer geometry to the current display-scale-derived size BEFORE the
 * VkSurface exists, so the first vkGetPhysicalDeviceSurfaceCapabilitiesKHR already
 * reports the right currentExtent; then apply the file-driven usage/format policy.
 * Runs on the render thread (MC's Vulkan init), never on the UI thread.
 * (Only the GLFW path uses this; the SDL3 `ohos` driver in tools/sdl does not —
 * see SDL_ohosvulkan.c for why.) */
static void meow_vk_prepare_surface_window(void *nativeWindow) {
    OHNativeWindow *nw = (OHNativeWindow *)nativeWindow;
    struct meow_environ_s *env = meow_environ;

    if (nw == NULL) {
        MEOWLOGW("vk surface prep: window is NULL, geometry/usage skipped");
        return;
    }
    if (env != NULL && env->width > 0 && env->height > 0) {
        OH_NativeWindow_NativeWindowHandleOpt(nw, SET_BUFFER_GEOMETRY, env->width, env->height);
        MEOWLOGI("vk surface prep: pinned window geometry %{public}d x %{public}d", env->width,
                 env->height);
    }
    meow_apply_window_usage(nw);
}

void meowSwapBuffers(void) {
    /* 渲染线程兜底：即便 MakeCurrent 走了别的路径，也保证 QoS 提升一次 + 抓栈已装。 */
    meow_qos_apply_current_thread();
    meow_bt_install_once();
    /* A secondary (shared) context never presents: swapping the primary's surface from a
     * thread whose current context is a secondary one is an EGL error, and the splash's
     * output is discarded on purpose (see egl_build_secondary_surface). */
    if (t_currentSlot != NULL && !t_currentSlot->primary) {
        static int warned = 0;
        if (!warned) {
            warned = 1;
            MEOWLOGI("swapBuffers on a shared context ignored (no presentation)");
        }
        return;
    }
    /* If a resize never made it through the pump, apply it now. */
    struct meow_environ_s *env = meow_environ;
    if (env != NULL && env->width > 0 && env->height > 0 &&
        (env->width != g_appliedWidth || env->height != g_appliedHeight)) {
        meow_egl_apply_resize(env->width, env->height);
    }

    if (!egl_ensure_context() || g_egl.surface == EGL_NO_SURFACE) {
        if (!egl_bind()) {
            return;
        }
    }

    if (eglSwapBuffers(g_egl.display, g_egl.surface) != EGL_TRUE) {
        EGLint err = eglGetError();
        MEOWLOGW("eglSwapBuffers failed: %{public}x", err);
        if (err == EGL_BAD_SURFACE || err == EGL_BAD_NATIVE_WINDOW) {
            egl_drop_surface();
            if (egl_bind()) {
                eglSwapBuffers(g_egl.display, g_egl.surface);
            }
        }
    }
}

void meowSwapInterval(int interval) {
    (void)interval; /* pinned to 0 */
    if (g_egl.display != EGL_NO_DISPLAY) {
        eglSwapInterval(g_egl.display, 0);
    }
}

/* ------------------------------------------------------------------------- */
/* surface channel                                                           */
/* ------------------------------------------------------------------------- */

/*
 * Resolve the window's final buffer usage:
 *
 *   DEFAULT -- clear NATIVEBUFFER_USAGE_CPU_READ only (measured 0x9 =
 *   CPU_READ|MEM_DMA -> 0x8). NO GPU bit is added. F25 used to OR in
 *   HW_RENDER|HW_TEXTURE unconditionally (0x9 -> 0x308), which is suspected of
 *   breaking window-buffer allocation: the shim .22 log shows
 *   `RequestBuffer failed: 40601000` (= NATIVE_ERROR_NO_BUFFER), absent in the
 *   F20..F25 window. That unconditional GPU-bit change is reverted here.
 *
 *   OVERRIDE -- if <filesDir>/meow-win-usage.txt holds a valid non-zero integer
 *   (0x prefix accepted), that value becomes the final usage.
 *
 * WHY A FILE, NOT AN ENV: the usage is set when the window is first configured
 * (01:15:04.760 measured), BEFORE the launcher applies its render env
 * (01:15:04.785). F24's env-gated override was therefore read too late and had
 * no effect. A file on disk has no such ordering problem.
 *
 * PATH SOURCE: the application sandbox files directory is already spelled, on
 * the native side, as the HOME env var -- meowjrebridge.cpp:258 sets
 * `HOME = filesDir` before JVM launch. This bridge has no other files-dir
 * constant, so `$HOME/<name>` is used verbatim rather than inventing a path. If
 * HOME is unset/empty the file is simply not read and the default applies.
 *
 * SCOPE (F78): this is VULKAN-ONLY. Clearing CPU_READ was introduced together
 * with the Vulkan work and applied to the shared window-acquisition path, which
 * is a real GL behaviour change (A23 F-M1) and made the GL picture flicker
 * intermittently (the GL driver may legitimately expect CPU access to the window
 * buffer). glfwCreateWindowSurface is therefore the sole caller; the EGL/GL path
 * mutates nothing and matches base byte-for-byte.
 *
 * TIMING: glfwCreateWindowSurface runs on the render thread after JVM launch,
 * after GameWindow.injectAndLaunch injected the surface, so HOME (filesDir) is
 * already set and a <filesDir>/meow-win-usage.txt override applies before the
 * VkSurface and its buffers exist. If HOME is unset/empty the default applies.
 *
 * GET -> compute -> SET -> GET-readback are logged with the value's source
 * (default|file) for external self-proof.
 */
static int g_winUsageDone = 0;
static int g_winUsageDirSeen = 0;
static void *g_winUsageWindow = NULL;

static const char *meow_win_file_dir(void) {
    const char *dir = getenv("HOME");
    return (dir != NULL && dir[0] != '\0') ? dir : NULL;
}

/* Read one integer (0x prefix accepted) from <filesDir>/<name>. Returns 1 only
 * for a syntactically valid, non-zero value; missing/empty/junk -> 0. Read-only:
 * the file is never created here. */
static int meow_read_int_file(const char *name, unsigned long long *out) {
    const char *dir = meow_win_file_dir();
    if (dir == NULL) {
        return 0;
    }
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return 0;
    }
    char buf[64];
    char *got = fgets(buf, sizeof(buf), f);
    fclose(f);
    if (got == NULL) {
        return 0;
    }
    char *end = NULL;
    unsigned long long v = strtoull(buf, &end, 0);
    if (end == buf || v == 0) {
        return 0;
    }
    *out = v;
    return 1;
}

static void meow_apply_window_usage(OHNativeWindow *win) {
    if (win == NULL) {
        MEOWLOGW("window buffer usage: window is NULL, usage bits skipped");
        return;
    }
    const char *dir = meow_win_file_dir();
    if (g_winUsageDone && g_winUsageWindow == win && (g_winUsageDirSeen || dir == NULL)) {
        return; /* already resolved for this window */
    }

    uint64_t before = 0;
    int32_t rcGet = OH_NativeWindow_NativeWindowHandleOpt(win, GET_USAGE, &before);
    if (rcGet != 0) {
        MEOWLOGW("window buffer usage: GET_USAGE failed rc=%{public}d", (int)rcGet);
        return;
    }

    unsigned long long fileVal = 0;
    uint64_t after;
    const char *source;
    if (meow_read_int_file("meow-win-usage.txt", &fileVal)) {
        after = (uint64_t)fileVal;
        source = "file";
    } else {
        after = before & ~(uint64_t)NATIVEBUFFER_USAGE_CPU_READ;
        source = "default";
    }

    int32_t rcSet = OH_NativeWindow_NativeWindowHandleOpt(win, SET_USAGE, after);
    if (rcSet != 0) {
        MEOWLOGW("window buffer usage: SET_USAGE failed rc=%{public}d (0x%{public}llx -> 0x%{public}llx, source: %{public}s)",
                 (int)rcSet, (unsigned long long)before, (unsigned long long)after, source);
        return;
    }

    uint64_t readback = 0;
    int32_t rcAfter = OH_NativeWindow_NativeWindowHandleOpt(win, GET_USAGE, &readback);
    if (rcAfter != 0) {
        MEOWLOGW("window buffer usage: readback GET_USAGE failed rc=%{public}d", (int)rcAfter);
    }
    MEOWLOGI("window buffer usage: 0x%{public}llx -> 0x%{public}llx (source: %{public}s)",
             (unsigned long long)before,
             (unsigned long long)(rcAfter == 0 ? readback : after), source);

    /* Optional file-driven pixel format: <filesDir>/meow-win-format.txt. */
    unsigned long long fileFmt = 0;
    if (meow_read_int_file("meow-win-format.txt", &fileFmt)) {
        int32_t rcFmt = OH_NativeWindow_NativeWindowHandleOpt(win, SET_FORMAT, (int32_t)fileFmt);
        if (rcFmt != 0) {
            MEOWLOGW("window buffer format: SET_FORMAT(0x%{public}x) failed rc=%{public}d (source: file)",
                     (unsigned)fileFmt, (int)rcFmt);
        } else {
            int32_t fmtAfter = -1;
            int32_t rcFmtAfter = OH_NativeWindow_NativeWindowHandleOpt(win, GET_FORMAT, &fmtAfter);
            MEOWLOGI("window buffer format: -> 0x%{public}x (source: file)",
                     (unsigned)(rcFmtAfter == 0 ? fmtAfter : (int32_t)fileFmt));
        }
    }

    /* Read-only buffer queue depth (previously never queried -- A7). */
    int32_t qsize = -1;
    int32_t rcQ = OH_NativeWindow_NativeWindowHandleOpt(win, GET_BUFFERQUEUE_SIZE, &qsize);
    if (rcQ != 0) {
        MEOWLOGW("window buffer queue size: GET_BUFFERQUEUE_SIZE failed rc=%{public}d", (int)rcQ);
    } else {
        MEOWLOGI("window buffer queue size: %{public}d", (int)qsize);
    }

    g_winUsageDone = 1;
    g_winUsageWindow = win;
    g_winUsageDirSeen = (dir != NULL) ? 1 : 0;
}

/*
 * Read-only window buffer FORMAT probe: called exactly once per window, at the
 * first OHNativeWindow acquisition (meowSetSurfaceId). It logs the window format
 * so it can be compared
 * with the swapchain imageFormat (logged as 37, i.e. VK_FORMAT_R8G8B8A8_UNORM)
 * in the field. It performs NO mutation.
 *
 * (F75 env-cleanup, 2026-09-18: the former env-gated SET_FORMAT / SET_USAGE /
 * SET_SOURCE_TYPE diagnostics MEOW_WIN_SET_FORMAT, MEOW_WIN_USAGE_EXTRA and
 * MEOW_WIN_SOURCE_TYPE were removed -- one-shot window-buffer experiments from
 * the second-submit VK_ERROR_DEVICE_LOST campaign, unused since Vulkan came up.)
 */
static void meow_window_format_usage_probe(OHNativeWindow *win) {
    if (win == NULL) {
        MEOWLOGW("window buffer format: window is NULL, probe skipped");
        return;
    }

    int32_t fmt = -1;
    int32_t rcFmt = OH_NativeWindow_NativeWindowHandleOpt(win, GET_FORMAT, &fmt);
    if (rcFmt != 0) {
        MEOWLOGW("window buffer format: GET_FORMAT failed rc=%{public}d", (int)rcFmt);
    } else {
        MEOWLOGI("window buffer format: 0x%{public}x (swapchain imageFormat=37)", (unsigned)fmt);
    }

}

int meowSetSurfaceId(int64_t sid, int width, int height) {
    /*
     * Vulkan milestone M1: the project's crash dumper (meowbt) is otherwise installed only from the
     * GL paths (meowMakeCurrent / meowSwapBuffers), which a Vulkan backend never walks -- so a Vulkan
     * SIGSEGV produced no backtrace at all. This entry point does run in the game process (UI thread,
     * before the JVM starts), so install it here as well. It stays inert unless MEOW_BT is set;
     * MEOW_BT_FILE=<path> makes it write a dump instead of only stderr (both are documented envs).
     */
    meow_bt_install_once();
    struct meow_environ_s *env = meow_environ;
    if (env == NULL) {
        MEOWLOGE("meowSetSurfaceId: state not ready");
        return -1;
    }

    if (env->surfaceId == sid && env->window != NULL) {
        if (width > 0 && height > 0) {
            env->savedWidth = width;
            env->savedHeight = height;
            env->width = width;
            env->height = height;
        }
        MEOWLOGD("meowSetSurfaceId: sid %{public}lld already bound", (long long)sid);
        return 0;
    }

    OHNativeWindow *win = NULL;
    int32_t rc = OH_NativeWindow_CreateNativeWindowFromSurfaceId((uint64_t)sid, &win);
    if (rc != 0 || win == NULL) {
        MEOWLOGE("CreateNativeWindowFromSurfaceId(%{public}lld) failed rc=%{public}d",
               (long long)sid, (int)rc);
        return -1;
    }

    /*
     * The previous window is intentionally not released: the ArkUI surface id
     * stays constant for the lifetime of the game window, so a genuine sid
     * change is rare and matches the long-standing behaviour.
     */
    env->window = (void *)win;
    env->surfaceId = sid;
    OH_NativeWindow_NativeWindowHandleOpt(win, SET_SOURCE_TYPE, OH_SURFACE_SOURCE_GAME);
    /* F78: window buffer usage is deliberately NOT touched here. This is the shared
     * GL/Vulkan window-acquisition point; the Vulkan WSI path applies its CPU_READ
     * clear later in glfwCreateWindowSurface, leaving the GL path on the pre-Vulkan
     * (base) behaviour. See meow_apply_window_usage(). */
    /* Read-only GET_FORMAT probe plus env-gated FORMAT/USAGE/SOURCE_TYPE diagnostics. */
    meow_window_format_usage_probe(win);
    if (width > 0 && height > 0) {
        env->savedWidth = width;
        env->savedHeight = height;
        env->width = width;
        env->height = height;
        OH_NativeWindow_NativeWindowHandleOpt(win, SET_BUFFER_GEOMETRY, width, height);
    } else {
        /* No size yet (onSurfaceCreated reports 0x0): deliberately do NOT pin a fallback
         * geometry. The render thread pump will apply the real, display-scale-derived
         * surface size as soon as meowResizeSurface records it. */
        MEOWLOGI("meowSetSurfaceId: size unknown (0x0) -> geometry deferred to resize");
    }

    /* Force the next render-thread apply to rebuild the surface. */
    g_appliedWidth = 0;
    g_appliedHeight = 0;
    MEOWLOGI("meowSetSurfaceId: sid=%{public}lld %{public}d x %{public}d window=%{public}p",
           (long long)sid, width, height, (void *)win);
    return 0;
}

int meowResizeSurface(int64_t sid, int width, int height) {
    struct meow_environ_s *env = meow_environ;
    if (env == NULL || width <= 0 || height <= 0) {
        MEOWLOGE("meowResizeSurface: bad state env=%{public}p size=%{public}dx%{public}d",
               (void *)env, width, height);
        return -1;
    }

    if (sid != env->surfaceId) {
        MEOWLOGI("meowResizeSurface: sid=%{public}lld != %{public}lld, full window path",
               (long long)sid, (long long)env->surfaceId);
        return meowSetSurfaceId(sid, width, height);
    }

    /* Same sid: only record the geometry; the render thread applies it. */
    env->savedWidth = width;
    env->savedHeight = height;
    env->width = width;
    env->height = height;
    MEOWLOGI("meow resize surface mark %{public}d x %{public}d", width, height);
    return 0;
}
