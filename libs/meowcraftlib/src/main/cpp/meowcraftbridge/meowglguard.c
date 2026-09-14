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
 * handle). This guard is that library: it exports glXGetProcAddress and
 * glXGetProcAddressARB (no eglGetProcAddress; LWJGL falls back to dlsym on the
 * handle, which our resolver mirrors) and forwards every name to the real
 * libGLv4, except that the CLIENT-MEMORY TEXTURE UPLOAD family gets a wrapper
 * which closes the enqueue->flush window. Selected by MEOW_GUARD_SYNC (only
 * applied when GALLIUM_THREAD is on; otherwise every wrapper is a thin forward
 * with no measurable cost):
 *
 *   none    no sync    (pure passthrough)
 *   flush   glFlush    (default: drains the threaded-context queue so the driver
 *                       consumes the pointer immediately, without waiting for the
 *                       GPU)
 *   finish  glFinish   (strongest; also waits for the GPU -> stalls per upload)
 *
 * Evidence (on device): flush and finish crashed zero times; the only remaining
 * faults were benign constant-address HotSpot poll-page ones.
 *
 * A fourth strategy (copy the client data into a staging buffer reclaimed via
 * glFenceSync, to avoid the per-upload sync entirely) was tried and REMOVED: it
 * crashed (staging/fence reclamation timing under glthread). See
 * notes 20-design/glthread-B方案-GL-guard.md §2.1 for the record.
 *
 * Scope (2026-09-15)
 *   - Wrapped: glTexSubImage2D (the original crash), plus the rest of the
 *     texture-upload family that also forwards a client pointer:
 *     glTexImage2D/1D/3D, glTexSubImage1D/3D, glCompressedTexImage2D/SubImage2D.
 *     The wrappers exist because a *corrupted* (not crashing) upload shows up as
 *     a partially-blank texture -- e.g. 26.2's inventory background arriving half
 *     transparent with GALLIUM_THREAD=1 and fine with it off.
 *   - Deliberately NOT wrapped (hot per-frame paths, no evidence yet):
 *     glBufferData / glBufferSubData, glMapBuffer and friends (map/unmap), client
 *     vertex arrays, glReadPixels, glShaderSource. The resolve path LOGS the first
 *     use of such an entry (once per name) so the next occurrence is self-diagnosing
 *     instead of guesswork.
 *   - The gl4es path (MC <=1.16 / legacy) uses libgl4es.so and is unaffected.
 *   - Rollback: point RENDERER_LIB back at RENDERER_LIB_REAL_GL (libGLv4.so), or
 *     switch off the per-version "threaded rendering" toggle.
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
typedef void (*FnTexImage2D)(unsigned int target, int level, int internalformat, int w, int h,
                             int border, unsigned int format, unsigned int type, const void *pixels);
typedef void (*FnTexImage1D)(unsigned int target, int level, int internalformat, int w, int border,
                             unsigned int format, unsigned int type, const void *pixels);
typedef void (*FnTexImage3D)(unsigned int target, int level, int internalformat, int w, int h,
                             int depth, int border, unsigned int format, unsigned int type,
                             const void *pixels);
typedef void (*FnTexSubImage1D)(unsigned int target, int level, int xoff, int w, unsigned int format,
                                unsigned int type, const void *pixels);
typedef void (*FnTexSubImage3D)(unsigned int target, int level, int xoff, int yoff, int zoff,
                                int w, int h, int depth, unsigned int format, unsigned int type,
                                const void *pixels);
typedef void (*FnCompressedTexImage2D)(unsigned int target, int level, unsigned int internalformat,
                                       int w, int h, int border, int imageSize, const void *data);
typedef void (*FnCompressedTexSubImage2D)(unsigned int target, int level, int xoff, int yoff,
                                          int w, int h, unsigned int format, int imageSize,
                                          const void *data);

enum { SYNC_NONE = 0, SYNC_FLUSH = 1, SYNC_FINISH = 2 };

static void *g_realLib = NULL;
static GetProcFn g_realGetProc = NULL;
static FnTexSubImage2D g_realTexSubImage2D = NULL;
static FnTexImage2D g_realTexImage2D = NULL;
static FnTexImage1D g_realTexImage1D = NULL;
static FnTexImage3D g_realTexImage3D = NULL;
static FnTexSubImage1D g_realTexSubImage1D = NULL;
static FnTexSubImage3D g_realTexSubImage3D = NULL;
static FnCompressedTexImage2D g_realCompressedTexImage2D = NULL;
static FnCompressedTexSubImage2D g_realCompressedTexSubImage2D = NULL;
static FnVoid g_glFinish = NULL;
static FnVoid g_glFlush = NULL;
static int g_glthread = 0;
static int g_syncMode = SYNC_FLUSH;

static int env_truthy(const char *v) {
    return v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
}

/* Close the enqueue->flush window: drain the threaded-context queue right after the
 * upload so the driver reads our (still valid) pixel pointer now, not later. */
static void meow_gl_sync_after_upload(void) {
    if (!g_glthread) {
        return;
    }
    if (g_syncMode == SYNC_FINISH && g_glFinish != NULL) {
        g_glFinish();
    } else if (g_syncMode == SYNC_FLUSH && g_glFlush != NULL) {
        g_glFlush();
    }
}

/* ---------------- the texture-upload family wrappers ---------------- */

static void meow_gl_TexSubImage2D(unsigned int target, int level, int xoff, int yoff, int w, int h,
                                  unsigned int format, unsigned int type, const void *pixels) {
    if (g_realTexSubImage2D == NULL) {
        return;
    }
    g_realTexSubImage2D(target, level, xoff, yoff, w, h, format, type, pixels);
    meow_gl_sync_after_upload();
}

static void meow_gl_TexImage2D(unsigned int target, int level, int internalformat, int w, int h,
                               int border, unsigned int format, unsigned int type,
                               const void *pixels) {
    if (g_realTexImage2D == NULL) {
        return;
    }
    g_realTexImage2D(target, level, internalformat, w, h, border, format, type, pixels);
    meow_gl_sync_after_upload();
}

static void meow_gl_TexImage1D(unsigned int target, int level, int internalformat, int w, int border,
                               unsigned int format, unsigned int type, const void *pixels) {
    if (g_realTexImage1D == NULL) {
        return;
    }
    g_realTexImage1D(target, level, internalformat, w, border, format, type, pixels);
    meow_gl_sync_after_upload();
}

static void meow_gl_TexImage3D(unsigned int target, int level, int internalformat, int w, int h,
                               int depth, int border, unsigned int format, unsigned int type,
                               const void *pixels) {
    if (g_realTexImage3D == NULL) {
        return;
    }
    g_realTexImage3D(target, level, internalformat, w, h, depth, border, format, type, pixels);
    meow_gl_sync_after_upload();
}

static void meow_gl_TexSubImage1D(unsigned int target, int level, int xoff, int w,
                                  unsigned int format, unsigned int type, const void *pixels) {
    if (g_realTexSubImage1D == NULL) {
        return;
    }
    g_realTexSubImage1D(target, level, xoff, w, format, type, pixels);
    meow_gl_sync_after_upload();
}

static void meow_gl_TexSubImage3D(unsigned int target, int level, int xoff, int yoff, int zoff,
                                  int w, int h, int depth, unsigned int format, unsigned int type,
                                  const void *pixels) {
    if (g_realTexSubImage3D == NULL) {
        return;
    }
    g_realTexSubImage3D(target, level, xoff, yoff, zoff, w, h, depth, format, type, pixels);
    meow_gl_sync_after_upload();
}

static void meow_gl_CompressedTexImage2D(unsigned int target, int level, unsigned int internalformat,
                                         int w, int h, int border, int imageSize,
                                         const void *data) {
    if (g_realCompressedTexImage2D == NULL) {
        return;
    }
    g_realCompressedTexImage2D(target, level, internalformat, w, h, border, imageSize, data);
    meow_gl_sync_after_upload();
}

static void meow_gl_CompressedTexSubImage2D(unsigned int target, int level, int xoff, int yoff,
                                            int w, int h, unsigned int format, int imageSize,
                                            const void *data) {
    if (g_realCompressedTexSubImage2D == NULL) {
        return;
    }
    g_realCompressedTexSubImage2D(target, level, xoff, yoff, w, h, format, imageSize, data);
    meow_gl_sync_after_upload();
}

/* Same bug class, deliberately NOT wrapped (hot per-frame paths). We log the first
 * resolve of each so a future blank/corrupt-texture report is self-diagnosing. */
static const char *const kUnwrappedClientMem[] = {
    "glBufferData", "glBufferSubData", "glNamedBufferData", "glNamedBufferSubData",
    "glMapBuffer", "glMapBufferRange", "glUnmapBuffer",
    "glReadPixels", "glShaderSource", "glDrawArrays", "glDrawElements",
    "glVertexPointer", "glTexCoordPointer", "glNormalPointer", "glColorPointer",
};
#define UNWRAPPED_N (sizeof(kUnwrappedClientMem) / sizeof(kUnwrappedClientMem[0]))
static unsigned char g_loggedUnwrapped[UNWRAPPED_N];

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
    g_realTexImage2D = (FnTexImage2D)dlsym(h, "glTexImage2D");
    g_realTexImage1D = (FnTexImage1D)dlsym(h, "glTexImage1D");
    g_realTexImage3D = (FnTexImage3D)dlsym(h, "glTexImage3D");
    g_realTexSubImage1D = (FnTexSubImage1D)dlsym(h, "glTexSubImage1D");
    g_realTexSubImage3D = (FnTexSubImage3D)dlsym(h, "glTexSubImage3D");
    g_realCompressedTexImage2D = (FnCompressedTexImage2D)dlsym(h, "glCompressedTexImage2D");
    g_realCompressedTexSubImage2D = (FnCompressedTexSubImage2D)dlsym(h, "glCompressedTexSubImage2D");
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
                 "guard: libGLv4=%{public}d resolver=%{public}p glthread=%{public}d sync=%{public}d "
                 "(texsub=%{public}p tex=%{public}p tex1d=%{public}p tex3d=%{public}p "
                 "sub1d=%{public}p sub3d=%{public}p comp2d=%{public}p compsub2d=%{public}p "
                 "finish=%{public}p flush=%{public}p)",
                 (int)(h != NULL), (void *)g_realGetProc, g_glthread, g_syncMode,
                 (void *)g_realTexSubImage2D, (void *)g_realTexImage2D, (void *)g_realTexImage1D,
                 (void *)g_realTexImage3D, (void *)g_realTexSubImage1D, (void *)g_realTexSubImage3D,
                 (void *)g_realCompressedTexImage2D, (void *)g_realCompressedTexSubImage2D,
                 (void *)g_glFinish, (void *)g_glFlush);
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
    /* Client-memory texture uploads: hand out our sync-after wrapper (the real
     * pointer is called inside it). Wrappers only when the real fn resolved. */
    if (strcmp(name, "glTexSubImage2D") == 0 && g_realTexSubImage2D != NULL) {
        return (GlProc)meow_gl_TexSubImage2D;
    }
    if (strcmp(name, "glTexImage2D") == 0 && g_realTexImage2D != NULL) {
        return (GlProc)meow_gl_TexImage2D;
    }
    if (strcmp(name, "glTexImage1D") == 0 && g_realTexImage1D != NULL) {
        return (GlProc)meow_gl_TexImage1D;
    }
    if (strcmp(name, "glTexImage3D") == 0 && g_realTexImage3D != NULL) {
        return (GlProc)meow_gl_TexImage3D;
    }
    if (strcmp(name, "glTexSubImage1D") == 0 && g_realTexSubImage1D != NULL) {
        return (GlProc)meow_gl_TexSubImage1D;
    }
    if (strcmp(name, "glTexSubImage3D") == 0 && g_realTexSubImage3D != NULL) {
        return (GlProc)meow_gl_TexSubImage3D;
    }
    if (strcmp(name, "glCompressedTexImage2D") == 0 && g_realCompressedTexImage2D != NULL) {
        return (GlProc)meow_gl_CompressedTexImage2D;
    }
    if (strcmp(name, "glCompressedTexSubImage2D") == 0 && g_realCompressedTexSubImage2D != NULL) {
        return (GlProc)meow_gl_CompressedTexSubImage2D;
    }
    /* Not wrapped: log the FIRST resolve of the client-memory entries we know about
     * (same bug class, deliberately left hot). One line per name, ever. */
    if (g_glthread && g_syncMode != SYNC_NONE) {
        for (size_t i = 0; i < UNWRAPPED_N; i++) {
            if (!g_loggedUnwrapped[i] && strcmp(name, kUnwrappedClientMem[i]) == 0) {
                g_loggedUnwrapped[i] = 1;
                OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                             "guard: unwrapped client-memory entry used: %{public}s "
                             "(deferred-read risk; wrap it if textures/buffers corrupt)",
                             name);
                break;
            }
        }
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
