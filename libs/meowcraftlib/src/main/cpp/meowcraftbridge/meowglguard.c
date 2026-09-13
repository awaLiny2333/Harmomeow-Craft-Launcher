/*
 * meowglguard.c - GL guard.
 *
 * LWJGL loads the OpenGL library named by -Dorg.lwjgl.opengl.libname and, on
 * Linux (non-EGL/Wayland), resolves EVERY GL name through that library's
 * glXGetProcAddress first (falling back to dlsym on the same handle). Pointing
 * libname at this guard makes it the single point where GL entry points are
 * resolved, so a few client-memory entries can be wrapped.
 *
 * B1 (done): pure passthrough to the real libGLv4 -- identical behaviour.
 * B2a (this): wrap glTexSubImage2D and, when Mesa glthread is enabled
 *   (GALLIUM_THREAD=1), call glFinish() after the real call. Rationale: with
 *   glthread the upload is *enqueued* and its client pointer is read later, at
 *   some app-thread flush; a glFinish right here forces that flush while the
 *   caller's pointer is still valid (we have not returned to MC yet), closing
 *   the use-after-free window. This is a falsifiable experiment: if the crash
 *   disappears, "enqueue -> later flush" is the mechanism and B is viable; if it
 *   still crashes, the pointer was already invalid at call time and B cannot fix
 *   it (see notes 20-design/glthread-B方案-GL-guard.md).
 *
 * Only glXGetProcAddress/ARB are exported (not eglGetProcAddress): the bridge
 * pre-dlopen()s this lib RTLD_GLOBAL, so exporting egl* could shadow the system
 * libEGL for other components.
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

static void *g_realLib = NULL;
static GetProcFn g_realGetProc = NULL;
static FnTexSubImage2D g_realTexSubImage2D = NULL;
static FnVoid g_glFinish = NULL;
static int g_glthread = 0;
static unsigned long g_resolveCount = 0;
static unsigned long g_wrapCount = 0;

static int env_truthy(const char *v) {
    return v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
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
    g_glthread = env_truthy(getenv("GALLIUM_THREAD"));
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "guard: libGLv4=%{public}d resolver=%{public}p glGetString=%{public}p texsub=%{public}p finish=%{public}p glthread=%{public}d",
                 (int)(h != NULL), (void *)g_realGetProc, dlsym(h, "glGetString"),
                 (void *)g_realTexSubImage2D, (void *)g_glFinish, g_glthread);
}

/* B2a wrapper for glTexSubImage2D: real call, then flush the threaded-context
 * queue while the caller's pixel pointer is still valid. */
static void meow_gl_TexSubImage2D(unsigned int target, int level, int xoff, int yoff, int w, int h,
                                  unsigned int format, unsigned int type, const void *pixels) {
    if (g_realTexSubImage2D != NULL) {
        g_realTexSubImage2D(target, level, xoff, yoff, w, h, format, type, pixels);
    }
    g_wrapCount++;
    if (g_glthread && g_glFinish != NULL) {
        g_glFinish();
    }
    if (g_wrapCount <= 3 || (g_wrapCount % 2000) == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "guard: texSubImage2D #%{public}ld %{public}dx%{public}d glthread=%{public}d",
                     (long)g_wrapCount, w, h, g_glthread);
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
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "guard: glTexSubImage2D wrapped (real=%{public}p, resolve #%{public}ld)",
                     (void *)g_realTexSubImage2D, (long)g_resolveCount);
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
