/*
 * meowglguard.c - GL guard (phase B1: pure passthrough).
 *
 * LWJGL loads the OpenGL library named by -Dorg.lwjgl.opengl.libname and, on
 * Linux (non-EGL/Wayland), resolves EVERY GL function through that library's
 * glXGetProcAddress first (falling back to dlsym on the same handle). So by
 * pointing libname at this guard we become the single point where GL entry
 * points are resolved -- later phases wrap a few client-memory entries (e.g.
 * glTexSubImage2D) to work around the Mesa glthread use-after-free
 * (see notes 20-design/glthread-B方案-GL-guard.md).
 *
 * B1 only forwards: the real libGLv4 is dlopen()ed (RTLD_GLOBAL so GL/EGL
 * symbols stay visible to the rest of the process) and every name is forwarded
 * to its glXGetProcAddress / dlsym. Behavior must be identical to before.
 *
 * Only glXGetProcAddress/glXGetProcAddressARB are exported (NOT
 * eglGetProcAddress): this guard is pre-dlopen()ed RTLD_GLOBAL by the bridge, so
 * exporting egl* could shadow the system libEGL for other components.
 */
#define _GNU_SOURCE

#include <dlfcn.h>
#include <stddef.h>
#include <string.h>

#include "hilog/log.h"

#undef LOG_TAG
#define LOG_TAG "MeowGlGuard"
#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0001

typedef void (*GlProc)(void);
typedef GlProc (*GetProcFn)(const char *);

static void *g_realLib = NULL;
static GetProcFn g_realGetProc = NULL;
static unsigned long g_resolveCount = 0;

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
    /* Diagnostics: whether libGLv4 carries a resolver at all, and a probe of the
     * dlsym path (the resolver is usually NULL on this platform). */
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "guard: libGLv4=%{public}d resolver=%{public}p dlsym(glGetString)=%{public}p",
                 (int)(h != NULL), (void *)g_realGetProc, dlsym(h, "glGetString"));
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
    /* Proof that LWJGL routes every GL name through this guard; the B2 target is
     * logged with its resolved address. */
    if (strcmp(name, "glTexSubImage2D") == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "guard: glTexSubImage2D -> %{public}p (resolve #%{public}ld)",
                     (void *)p, (long)g_resolveCount);
    } else if (g_resolveCount == 1) {
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
