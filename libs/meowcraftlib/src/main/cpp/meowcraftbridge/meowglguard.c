/*
 * meowglguard.c - GL guard: an application-side fix for the Mesa "glthread"
 * use-after-free that intermittently killed Minecraft 26.x on this platform.
 *
 * ============================== THE BUG ==============================
 *
 * Symptom
 *   With Mesa's threaded context enabled (env GALLIUM_THREAD=1) MC 26.x died at
 *   the loading screen (occasionally in-game) in ~50% of runs with SIGSEGV
 *   (SEGV_ACCERR) while reading unmapped memory. Older MC versions (<=1.21) only
 *   hit benign HotSpot safepoint-poll faults. With GALLIUM_THREAD=0 it never died.
 *
 * Crash chain (symbolised; see notes 20-design/glthread崩溃-bug报告.md)
 *   glTexSubImage2D                                  (MC via LWJGL, Render thread)
 *     -> _mesa_TexSubImage2D -> texsubimage_err -> texture_sub_image
 *     -> st_TexSubImage                              (state tracker)
 *     -> tc_texture_subdata                          (glthread threaded context)
 *     -> zink_buffer_subdata                         (libgallium-25.0.1.so +0xE26CC4)
 *     -> memcpy(dst, src = the caller's pixel pointer, n)   <-- faulted here
 *
 * Root cause
 *   tc_texture_subdata does NOT copy the client data itself: it forwards the
 *   caller's transient pointer to the driver, and the read happens later when
 *   the app thread next flushes the threaded-context queue. By then the caller
 *   may already have freed/reused that buffer -> use-after-free. (GL semantics
 *   require the client pointer to be consumed synchronously.)
 *
 *   Mesa's libgallium is stripped but keeps a .gnu_debugdata section with a full
 *   .symtab, which is how the frames above were named; see
 *   stuffs/research/mesa/README.md for the symbolisation recipe.
 *
 * ============================== THE FIX ==============================
 *
 * LWJGL resolves every GL entry point through the library named by
 * -Dorg.lwjgl.opengl.libname (its glXGetProcAddress first, then dlsym on that
 * handle). This guard is that library: it exports glXGetProcAddress/ARB and
 * forwards every name to the real libGLv4, except that glTexSubImage2D gets a
 * wrapper which closes the enqueue->flush window. Selected by MEOW_GUARD_SYNC
 * (only applied when GALLIUM_THREAD is on; otherwise the wrapper is a thin
 * forward with no measurable cost):
 *
 *   none    no sync    (control: crashed every time with the exact same
 *                       `lr = libgallium + 0xE26CC4` signature)
 *   flush   glFlush    (default: drains the threaded-context queue so the driver
 *                       consumes the pointer immediately, without waiting for the
 *                       GPU)
 *   finish  glFinish   (strongest; also waits for the GPU -> stalls per upload)
 *
 * Evidence (on device): flush (3 runs) and finish (9 runs) crashed zero times;
 * the only remaining faults were benign constant-address HotSpot poll-page ones.
 *
 * A fourth strategy (copy the client data into a staging buffer reclaimed via
 * glFenceSync, to avoid the per-upload sync entirely) was tried and REMOVED: it
 * crashed (staging/fence reclamation timing under glthread). See
 * notes 20-design/glthread-B方案-GL-guard.md §2.1 for the record.
 *
 * Scope / limits
 *   - Only glTexSubImage2D is wrapped (empirically the entry hit by this
 *     content). Other client-memory entries (Compressed/1D/3D tex, glBuffer*,
 *     client draw/vertex arrays, glReadPixels, glShaderSource...) belong to the
 *     same bug class and can be added here if ever observed.
 *   - The gl4es path (MC <=1.16 / legacy) uses libgl4es.so and is unaffected.
 *   - Rollback: point RENDERER_LIB back at RENDERER_LIB_REAL_GL (libGLv4.so).
 *
 * See notes 20-design/glthread-B方案-GL-guard.md, 26.x渲染栈差异.md §5, and
 * 00-current/运行时环境变量.md for the full plan, evidence and knobs.
 */
#define _GNU_SOURCE

#include <dlfcn.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "hilog/log.h"

#undef LOG_TAG
#define LOG_TAG "MeowGlGuard"
#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0001

typedef void (*GlProc)(void);
typedef GlProc (*GetProcFn)(const char *);
typedef void (*FnVoid)(void);
typedef void (*FnTexSubImage2D)(unsigned int target, int level, int xoff, int yoff, int w, int h,
                                unsigned int format, unsigned int type, const void *pixels);

enum { SYNC_NONE = 0, SYNC_FLUSH = 1, SYNC_FINISH = 2 };

static void *g_realLib = NULL;
static GetProcFn g_realGetProc = NULL;
static FnTexSubImage2D g_realTexSubImage2D = NULL;
static FnVoid g_glFinish = NULL;
static FnVoid g_glFlush = NULL;
static int g_glthread = 0;
static int g_syncMode = SYNC_FLUSH;
static unsigned long g_resolveCount = 0;
static unsigned long g_wrapCount = 0;

static int env_truthy(const char *v) {
    return v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
}

/* glTexSubImage2D wrapper: real call, then close the enqueue->flush window. */
static void meow_gl_TexSubImage2D(unsigned int target, int level, int xoff, int yoff, int w, int h,
                                  unsigned int format, unsigned int type, const void *pixels) {
    if (g_realTexSubImage2D == NULL) {
        return;
    }
    g_realTexSubImage2D(target, level, xoff, yoff, w, h, format, type, pixels);
    g_wrapCount++;
    if (g_glthread) {
        if (g_syncMode == SYNC_FINISH && g_glFinish != NULL) {
            g_glFinish();
        } else if (g_syncMode == SYNC_FLUSH && g_glFlush != NULL) {
            g_glFlush();
        }
    }
    if (g_wrapCount <= 3 || (g_wrapCount % 2000) == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "guard: texSubImage2D #%{public}ld %{public}dx%{public}d glthread=%{public}d sync=%{public}d",
                     (long)g_wrapCount, w, h, g_glthread, g_syncMode);
    }
}

/* Exported so the bridge can verify (before JLI_Launch) that the guard is armed
 * and, if not, force GALLIUM_THREAD=0 rather than leave glthread unprotected. */
int meow_glguard_armed(void) {
    if (g_realTexSubImage2D == NULL) {
        return 0;
    }
    if (g_syncMode == SYNC_NONE) {
        return 1; /* the operator explicitly asked for no sync */
    }
    if (g_syncMode == SYNC_FINISH) {
        return g_glFinish != NULL ? 1 : 0;
    }
    return g_glFlush != NULL ? 1 : 0;
}

__attribute__((constructor)) static void meow_gl_guard_init(void) {
    void *h = dlopen("libGLv4.so", RTLD_NOW | RTLD_GLOBAL);
    if (h == NULL) {
        h = dlopen("/system/lib64/ndk/libGLv4.so", RTLD_NOW | RTLD_GLOBAL);
    }
    if (h == NULL) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "guard: dlopen libGLv4 failed: %{public}s", dlerror());
        return;
    }
    g_realLib = h;
    g_realGetProc = (GetProcFn)dlsym(h, "glXGetProcAddress");
    if (g_realGetProc == NULL) {
        g_realGetProc = (GetProcFn)dlsym(h, "glXGetProcAddressARB");
    }
    if (g_realGetProc == NULL) {
        g_realGetProc = (GetProcFn)dlsym(h, "eglGetProcAddress");
    }
    g_realTexSubImage2D = (FnTexSubImage2D)dlsym(h, "glTexSubImage2D");
    g_glFinish = (FnVoid)dlsym(h, "glFinish");
    g_glFlush = (FnVoid)dlsym(h, "glFlush");
    g_glthread = env_truthy(getenv("GALLIUM_THREAD"));
    {
        const char *sm = getenv("MEOW_GUARD_SYNC");
        if (sm != NULL && strcmp(sm, "none") == 0) {
            g_syncMode = SYNC_NONE;
        } else if (sm != NULL && strcmp(sm, "finish") == 0) {
            g_syncMode = SYNC_FINISH;
        } else {
            g_syncMode = SYNC_FLUSH;
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "guard: libGLv4=%{public}d resolver=%{public}p glthread=%{public}d sync=%{public}d (texsub=%{public}p finish=%{public}p flush=%{public}p)",
                 (int)(h != NULL), (void *)g_realGetProc, g_glthread, g_syncMode,
                 (void *)g_realTexSubImage2D, (void *)g_glFinish, (void *)g_glFlush);
    /* Fail-safe: if glthread is on but this guard cannot protect glTexSubImage2D
     * (missing real symbol / missing sync entry point), do not leave the platform
     * in the unprotected configuration that reintroduces the Mesa UAF. This runs
     * when the bridge pre-dlopen()s us, i.e. after it set the env and before
     * Mesa screen init, so the override is effective. */
    if (g_glthread && !meow_glguard_armed()) {
        setenv("GALLIUM_THREAD", "0", 1);
        OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                     "guard: NOT armed (texsub=%{public}p finish=%{public}p flush=%{public}p) -> forced GALLIUM_THREAD=0",
                     (void *)g_realTexSubImage2D, (void *)g_glFinish, (void *)g_glFlush);
    }
}

static GlProc meow_gl_guard_resolve(const char *name) {
    if (name == NULL) {
        return NULL;
    }
    /* Faithful to LWJGL's pre-guard path: libGLv4's own resolver (absent today),
     * then dlsym on the libGLv4 handle (which also searches its dependencies).
     * NO dlsym(RTLD_DEFAULT): that would be a behavioural superset. */
    GlProc p = NULL;
    if (g_realGetProc != NULL) {
        p = g_realGetProc(name);
    }
    if (p == NULL && g_realLib != NULL) {
        p = (GlProc)dlsym(g_realLib, name);
    }
    g_resolveCount++;
    if (strcmp(name, "glTexSubImage2D") == 0 && g_realTexSubImage2D != NULL) {
        return (GlProc)meow_gl_TexSubImage2D;
    }
    if (g_resolveCount == 1) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "guard: first resolve '%{public}s' -> %{public}p", name, (void *)p);
    }
    return p;
}

/* Exported as the OpenGL library by LWJGL. */
GlProc glXGetProcAddress(const char *name) {
    return meow_gl_guard_resolve(name);
}

GlProc glXGetProcAddressARB(const char *name) {
    return meow_gl_guard_resolve(name);
}
