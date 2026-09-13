/*
 * meowglguard.c - GL guard: an application-side fix for the Mesa "glthread"
 * use-after-free that intermittently kills Minecraft 26.x on this platform.
 *
 * ============================== THE BUG ==============================
 *
 * Symptom
 *   With Mesa's threaded context enabled (env GALLIUM_THREAD=1) MC 26.x dies at
 *   the loading screen (occasionally in-game) in ~50% of runs with SIGSEGV
 *   (SEGV_ACCERR) while reading unmapped memory. Older MC versions (<=1.21) do
 *   not die (they only hit benign HotSpot safepoint-poll faults). With
 *   GALLIUM_THREAD=0 it never dies.
 *
 * Crash chain (symbolised; see notes 20-design/glthread崩溃-bug报告.md)
 *   glTexSubImage2D                                  (MC via LWJGL, Render thread)
 *     -> _mesa_TexSubImage2D -> texsubimage_err -> texture_sub_image
 *     -> st_TexSubImage                              (state tracker)
 *     -> tc_texture_subdata                          (glthread threaded context)
 *     -> zink_buffer_subdata                         (libgallium-25.0.1.so +0xE26CC4)
 *     -> memcpy(dst, src = the caller's pixel pointer, n)   <-- faults here
 *
 * Root cause
 *   tc_texture_subdata does NOT copy the client data itself. It forwards the
 *   caller's transient pointer to the driver; the actual read happens later,
 *   when the app thread next flushes the threaded-context queue. By then the
 *   caller may already have freed/reused that buffer -> use-after-free.
 *   (GL semantics require the client pointer to be consumed synchronously.)
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
 *   none    no sync        (control: crashes with the exact same signature)
 *   flush   glFlush        (default: drain the TC queue without waiting for GPU)
 *   finish  glFinish       (strongest, but stalls once per upload)
 *   copy    copy + fence   (copy the client data into a staging buffer retained
 *                           until a GL fence signals -> no per-call stall)
 *
 * Evidence (on device): MEOW_GUARD_SYNC=none crashed every time with
 * `lr = libgallium + 0xE26CC4`; flush (3 runs) and finish (9 runs) crashed zero
 * times. Only benign constant-address HotSpot poll-page faults remained.
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
#include <pthread.h>
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
typedef void (*FnPixelStorei)(unsigned int pname, int param);
typedef void *GLsyncT;
typedef GLsyncT (*FnFenceSync)(unsigned int condition, unsigned int flags);
typedef int (*FnClientWaitSync)(GLsyncT sync, unsigned int flags, unsigned long long timeout);
typedef void (*FnDeleteSync)(GLsyncT sync);

enum { SYNC_NONE = 0, SYNC_FLUSH = 1, SYNC_FINISH = 2, SYNC_COPY = 3 };

/* GL enums (values from the OpenGL/GLES headers; kept local to avoid a GL dep). */
#define GL_UNPACK_ALIGNMENT   0x0CF5
#define GL_UNPACK_ROW_LENGTH  0x0D02
#define GL_UNPACK_SKIP_ROWS   0x0D03
#define GL_UNPACK_SKIP_PIXELS 0x0D04
#define GL_SYNC_GPU_COMMANDS_COMPLETE 0x9117
#define GL_ALREADY_SIGNALED   0x911A

/* Cap a single staging copy; larger uploads fall back to the flush path. */
#define GLGUARD_MAX_STAGE_BYTES (16u << 20)

static void *g_realLib = NULL;
static GetProcFn g_realGetProc = NULL;
static FnTexSubImage2D g_realTexSubImage2D = NULL;
static FnPixelStorei g_realPixelStorei = NULL;
static FnVoid g_glFinish = NULL;
static FnVoid g_glFlush = NULL;
static FnFenceSync g_fenceSync = NULL;
static FnClientWaitSync g_clientWaitSync = NULL;
static FnDeleteSync g_deleteSync = NULL;
static int g_glthread = 0;
static int g_syncMode = SYNC_FLUSH;
static unsigned long g_resolveCount = 0;
static unsigned long g_wrapCount = 0;
static unsigned long g_copyCount = 0;
static unsigned long g_fallbackCount = 0;

/* Tracked client-side unpack state (only consulted by the copy mode). */
static int g_unpackAlign = 4;
static int g_unpackRowLength = 0;
static int g_unpackSkipRows = 0;
static int g_unpackSkipPixels = 0;

struct Stage {
    void *ptr;
    GLsyncT sync;
    struct Stage *next;
};
static struct Stage *g_stages = NULL; /* guarded by g_stageLock */
static pthread_mutex_t g_stageLock = PTHREAD_MUTEX_INITIALIZER;

static void g_publish(const char *what);

static int env_truthy(const char *v) {
    return v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
}

/* Bytes-per-pixel of a (format,type) client image, or 0 when unknown. */
static int fmt_components(unsigned int f) {
    switch (f) {
        case 0x1903: /* GL_RED */
        case 0x1906: /* GL_ALPHA */
        case 0x1909: /* GL_LUMINANCE */
        case 0x1902: /* GL_DEPTH_COMPONENT */
        case 0x8D94: /* GL_RED_INTEGER */
        case 0x8D96: /* GL_GREEN_INTEGER */
        case 0x8D97: /* GL_BLUE_INTEGER */
            return 1;
        case 0x8227: /* GL_RG */
        case 0x190A: /* GL_LUMINANCE_ALPHA */
        case 0x84F9: /* GL_DEPTH_STENCIL */
        case 0x8228: /* GL_RG_INTEGER */
            return 2;
        case 0x1907: /* GL_RGB */
        case 0x80E0: /* GL_BGR */
        case 0x8D98: /* GL_RGB_INTEGER */
        case 0x8D9A: /* GL_BGR_INTEGER */
            return 3;
        case 0x1908: /* GL_RGBA */
        case 0x80E1: /* GL_BGRA */
        case 0x8D99: /* GL_RGBA_INTEGER */
        case 0x8D9B: /* GL_BGRA_INTEGER */
            return 4;
        default:
            return 0;
    }
}

static int type_bytes(unsigned int t) {
    switch (t) {
        case 0x1401: /* GL_UNSIGNED_BYTE */
        case 0x1400: /* GL_BYTE */
            return 1;
        case 0x1403: /* GL_UNSIGNED_SHORT */
        case 0x1402: /* GL_SHORT */
        case 0x140B: /* GL_HALF_FLOAT */
            return 2;
        case 0x1405: /* GL_UNSIGNED_INT */
        case 0x1404: /* GL_INT */
        case 0x1406: /* GL_FLOAT */
            return 4;
        case 0x140A: /* GL_DOUBLE */
            return 8;
        default:
            return 0;
    }
}

/* Packed pixel types carry a fixed number of bytes per pixel. */
static int packed_bytes(unsigned int t) {
    switch (t) {
        case 0x8032: /* GL_UNSIGNED_BYTE_3_3_2 */
        case 0x8362: /* GL_UNSIGNED_BYTE_2_3_3_REV */
            return 1;
        case 0x8033: /* GL_UNSIGNED_SHORT_4_4_4_4 */
        case 0x8034: /* GL_UNSIGNED_SHORT_5_5_5_1 */
        case 0x8363: /* GL_UNSIGNED_SHORT_5_6_5 */
        case 0x8364: /* GL_UNSIGNED_SHORT_5_6_5_REV */
        case 0x8365: /* GL_UNSIGNED_SHORT_4_4_4_4_REV */
        case 0x8366: /* GL_UNSIGNED_SHORT_1_5_5_5_REV */
            return 2;
        case 0x8035: /* GL_UNSIGNED_INT_8_8_8_8 */
        case 0x8036: /* GL_UNSIGNED_INT_10_10_10_2 */
        case 0x8367: /* GL_UNSIGNED_INT_8_8_8_8_REV */
        case 0x8368: /* GL_UNSIGNED_INT_2_10_10_10_REV */
            return 4;
        default:
            return 0;
    }
}

static int bytes_per_pixel(unsigned int format, unsigned int type) {
    int pb = packed_bytes(type);
    if (pb > 0) {
        return pb;
    }
    int c = fmt_components(format);
    int b = type_bytes(type);
    return (c > 0 && b > 0) ? c * b : 0;
}

/* Upper bound, in bytes from the caller's pointer, of what the driver reads for
 * a glTexSubImage2D(width,height) with the current unpack state. */
static long stage_bytes(int width, int height, unsigned int format, unsigned int type) {
    int bpp = bytes_per_pixel(format, type);
    if (bpp <= 0 || width <= 0 || height <= 0) {
        return 0;
    }
    long rowPixels = (g_unpackRowLength > 0) ? g_unpackRowLength : width;
    long align = (g_unpackAlign == 1 || g_unpackAlign == 2 || g_unpackAlign == 4 || g_unpackAlign == 8)
                     ? g_unpackAlign
                     : 4;
    long rowBytes = rowPixels * bpp;
    long stride = (rowBytes + align - 1) / align * align;
    long total = (long)(g_unpackSkipRows + height) * stride;
    return total > 0 ? total : 0;
}

/* Free staging buffers whose fence has signalled. Caller holds g_stageLock. */
static void stage_reap(void) {
    struct Stage **pp = &g_stages;
    while (*pp != NULL) {
        struct Stage *s = *pp;
        int done = 0;
        if (s->sync == NULL) {
            done = 1;
        } else if (g_clientWaitSync != NULL) {
            done = (g_clientWaitSync(s->sync, 0, 0) == GL_ALREADY_SIGNALED);
        }
        if (done) {
            if (s->sync != NULL && g_deleteSync != NULL) {
                g_deleteSync(s->sync);
            }
            free(s->ptr);
            *pp = s->next;
            free(s);
        } else {
            pp = &s->next;
        }
    }
}

/* B2c: copy the client data into a staging buffer that survives until the fence
 * inserted after the upload signals. Returns 1 if handled, 0 to fall back. */
static int texsubimage_copy(unsigned int target, int level, int xoff, int yoff, int w, int h,
                            unsigned int format, unsigned int type, const void *pixels) {
    long bytes = stage_bytes(w, h, format, type);
    if (bytes <= 0 || (unsigned long)bytes > GLGUARD_MAX_STAGE_BYTES) {
        g_fallbackCount++;
        return 0;
    }
    void *staging = malloc((size_t)bytes);
    if (staging == NULL) {
        g_fallbackCount++;
        return 0;
    }
    memcpy(staging, pixels, (size_t)bytes);
    g_realTexSubImage2D(target, level, xoff, yoff, w, h, format, type, staging);
    GLsyncT sy = (g_fenceSync != NULL) ? g_fenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0) : NULL;
    pthread_mutex_lock(&g_stageLock);
    struct Stage *s = (struct Stage *)malloc(sizeof(*s));
    if (s != NULL) {
        s->ptr = staging;
        s->sync = sy;
        s->next = g_stages;
        g_stages = s;
    } else {
        if (sy != NULL && g_deleteSync != NULL) {
            g_deleteSync(sy);
        }
        free(staging);
    }
    stage_reap();
    pthread_mutex_unlock(&g_stageLock);
    g_copyCount++;
    return 1;
}

/* glTexSubImage2D wrapper: forward via the selected strategy. */
static void meow_gl_TexSubImage2D(unsigned int target, int level, int xoff, int yoff, int w, int h,
                                  unsigned int format, unsigned int type, const void *pixels) {
    if (g_realTexSubImage2D == NULL) {
        return;
    }
    g_wrapCount++;
    if (g_glthread) {
        if (g_syncMode == SYNC_COPY && pixels != NULL) {
            if (texsubimage_copy(target, level, xoff, yoff, w, h, format, type, pixels)) {
                g_publish("copy");
                return;
            }
            /* unknown/oversized -> flush fallback */
        }
        g_realTexSubImage2D(target, level, xoff, yoff, w, h, format, type, pixels);
        if (g_syncMode == SYNC_FINISH && g_glFinish != NULL) {
            g_glFinish();
        } else if (g_syncMode == SYNC_FLUSH && g_glFlush != NULL) {
            g_glFlush();
        }
    } else {
        g_realTexSubImage2D(target, level, xoff, yoff, w, h, format, type, pixels);
    }
    g_publish("sync");
}

static void meow_gl_PixelStorei(unsigned int pname, int param) {
    if (pname == GL_UNPACK_ALIGNMENT) {
        g_unpackAlign = param;
    } else if (pname == GL_UNPACK_ROW_LENGTH) {
        g_unpackRowLength = param;
    } else if (pname == GL_UNPACK_SKIP_ROWS) {
        g_unpackSkipRows = param;
    } else if (pname == GL_UNPACK_SKIP_PIXELS) {
        g_unpackSkipPixels = param;
    }
    if (g_realPixelStorei != NULL) {
        g_realPixelStorei(pname, param);
    }
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
    g_realPixelStorei = (FnPixelStorei)dlsym(h, "glPixelStorei");
    g_glFinish = (FnVoid)dlsym(h, "glFinish");
    g_glFlush = (FnVoid)dlsym(h, "glFlush");
    g_fenceSync = (FnFenceSync)dlsym(h, "glFenceSync");
    g_clientWaitSync = (FnClientWaitSync)dlsym(h, "glClientWaitSync");
    g_deleteSync = (FnDeleteSync)dlsym(h, "glDeleteSync");
    g_glthread = env_truthy(getenv("GALLIUM_THREAD"));
    {
        const char *sm = getenv("MEOW_GUARD_SYNC");
        if (sm != NULL && strcmp(sm, "none") == 0) {
            g_syncMode = SYNC_NONE;
        } else if (sm != NULL && strcmp(sm, "finish") == 0) {
            g_syncMode = SYNC_FINISH;
        } else if (sm != NULL && strcmp(sm, "copy") == 0) {
            g_syncMode = SYNC_COPY;
        } else {
            g_syncMode = SYNC_FLUSH;
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "guard: libGLv4=%{public}d resolver=%{public}p glthread=%{public}d sync=%{public}d (texsub=%{public}p finish=%{public}p flush=%{public}p fence=%{public}p)",
                 (int)(h != NULL), (void *)g_realGetProc, g_glthread, g_syncMode,
                 (void *)g_realTexSubImage2D, (void *)g_glFinish, (void *)g_glFlush, (void *)g_fenceSync);
}

static void g_publish(const char *what) {
    if (g_wrapCount <= 3 || (g_wrapCount % 2000) == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "guard: texSubImage2D #%{public}ld %{public}s glthread=%{public}d sync=%{public}d copy=%{public}ld fallback=%{public}ld",
                     (long)g_wrapCount, what, g_glthread, g_syncMode, (long)g_copyCount,
                     (long)g_fallbackCount);
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
    /* The unpack state only matters for the copy mode; intercept glPixelStorei
     * there so no GL query is ever needed on the upload path. */
    if (g_syncMode == SYNC_COPY && strcmp(name, "glPixelStorei") == 0 && g_realPixelStorei != NULL) {
        return (GlProc)meow_gl_PixelStorei;
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
