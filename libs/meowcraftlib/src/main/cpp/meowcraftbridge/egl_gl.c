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

/* dlopen gl4es and run initialize_gl4es() (requires a current GLES context). */
static void gl4es_init_once(void) {
    if (!g_gl4es || g_gl4esInit) {
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

static int egl_ensure_context(void) {
    if (g_egl.contextReady) {
        return 1;
    }
    if (!egl_ensure_display()) {
        return 0;
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
        g_egl.context = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, esAttrs);
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
            g_egl.context = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, compatAttrs);
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
        g_egl.context = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, hiAttrs);
        if (g_egl.context != EGL_NO_CONTEXT) {
            MEOWLOGI("created desktop OpenGL 4.2 (core) context");
            g_egl.contextReady = 1;
            return 1;
        }
        MEOWLOGW("GL 4.2 core ctx rejected: %{public}x, trying 3.2", eglGetError());
        const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2,
                                   EGL_NONE};
        g_egl.context = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, ctxAttrs);
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
    g_egl.context = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, ctxAttrs);
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
        "GL_ARB_clip_control", "GL_ARB_shader_draw_parameters", "GL_ARB_debug_output", NULL
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
    if (g_egl.display != EGL_NO_DISPLAY) {
        egl_drop_surface();
        if (g_egl.context != EGL_NO_CONTEXT) {
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

void meowMakeCurrent(void *window) {
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
        if (g_egl.display != EGL_NO_DISPLAY) {
            eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        return;
    }
    if (!egl_bind()) {
        MEOWLOGW("meowMakeCurrent: no GL context/surface available");
    }
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

void meowSwapBuffers(void) {
    /* 渲染线程兜底：即便 MakeCurrent 走了别的路径，也保证 QoS 提升一次 + 抓栈已装。 */
    meow_qos_apply_current_thread();
    meow_bt_install_once();
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

int meowSetSurfaceId(int64_t sid, int width, int height) {
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
    if (width > 0 && height > 0) {
        env->savedWidth = width;
        env->savedHeight = height;
        env->width = width;
        env->height = height;
        OH_NativeWindow_NativeWindowHandleOpt(win, SET_BUFFER_GEOMETRY, width, height);
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
