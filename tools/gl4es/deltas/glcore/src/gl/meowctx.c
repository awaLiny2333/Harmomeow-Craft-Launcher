/*
 * Meowcraft gl4es delta: per-EGL-context glstate registry + bind hook.
 * (New file, no upstream counterpart; added to GL_SRC by deltas/glcore/src/CMakeLists.txt.)
 *
 * PROBLEM (root cause, 2026-09-29 — see notes/20-design/launch/
 * Forge-splash-崩溃根因与共享上下文修复.md §5.3 and notes/00-current/已知限制与待解.md C11):
 * FML 1.7.10's console splash drives TWO EGL contexts on TWO threads with no
 * cross-thread GL mutex: the splash thread renders on the main context while the
 * main thread holds the *shared* context (SplashProgress.start() releases the
 * main context, makes the shared drawable current, and keeps doing loading-era
 * GL); pause()/resume() are never called, so the overlap lasts the whole loading
 * phase.  Our gl4es is built -DNOX11 -DNOEGL (= tools/gl4es/build_gl4es_meow.sh),
 * so upstream's per-context machinery in src/glx/glx.c (NewGLState /
 * ActivateGLState) is never reached: the host owns EGL and the ONLY state was a
 * single process-global `glstate`.  Two threads driving it concurrently corrupt
 * the immediate-mode transaction / display-list state (garbage list->len => the
 * vendor log's absurd `vertexSum: 22364413` => SIGTRAP) or wedge a pointer
 * (SIGSEGV, DFX signo(11), tid 42832, 2026-09-29 22:57 — still fatal with
 * GALLIUM_THREAD=0, i.e. the race is gl4es-side, not Mesa glthread).
 *
 * FIX: `glstate` is now `__thread` (gl4es.h + glstate.c delta), and this file maps
 * each EGL context to its own glstate_t.  The bridge calls meow_gl4es_bind(ctx)
 * right after every successful eglMakeCurrent.  Object tables stay SHARED between
 * contexts of the same group (NewGLState(parent) does exactly that), which is the
 * EGL shared-context contract; per-context we isolate matrices / enables /
 * the glBegin..glEnd transaction / VAO caches / gleshard.
 *
 * INVARIANTS
 *   - A thread's `glstate` is never NULL: TLS is initialized to &default_glstate
 *     (glstate.c) and every path here falls back to it.
 *   - `default_glstate` is the "no context on this thread" state. The registry never
 *     INSTALLS it on a thread that already holds a per-context state: the OOM / registry
 *     -full fallback in meow_gl4es_bind keeps the thread's previous state (and warns)
 *     instead of downgrading it to default_glstate, so a live context is never handed the
 *     shared default while its thread had a real state (i.e. two live contexts cannot
 *     race default_glstate through the normal create/bind path).
 *   - The registry lock is a leaf lock: it is taken only here, and the GL calls
 *     inside NewGLState() cannot re-enter this file => no lock cycle.
 *   - Not wired into the shared object tables yet: protecting those needs
 *     refcounting, not a leaf lock (see the report / follow-up list).
 *
 * Degrades safely: with a single context this behaves exactly like before
 * (one state, all GL calls) apart from the very first bind replacing the
 * post-init default state with a dedicated one (see note in meow_gl4es_bind).
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "gl4es.h"    /* glstate (TLS), glstate_t, EXPORT via attributes.h */
#include "glstate.h"

#include "meowctx.h"

/* Upstream per-context entry points, defined in glstate.c.  Upstream declares
 * them locally in glx.c/agl.c (they are not in a header); mirror that here. */
void *NewGLState(void *shared_glstate, int es2only);
void  ActivateGLState(void *new_glstate);

/* The "no context bound on this thread" state (definition in glstate.c). */
extern glstate_t default_glstate;

/* Bound the registry: an app that leaks contexts must not grow it forever. */
#define MEOW_CTX_MAX 24

typedef struct meow_ctx_state_s {
    void       *egl_ctx;   /* key: the EGLContext (opaque pointer) */
    glstate_t  *state;     /* its gl4es state */
    struct meow_ctx_state_s *next;
} meow_ctx_state_t;

static pthread_mutex_t   g_ctx_mutex = PTHREAD_MUTEX_INITIALIZER; /* registry only */
static meow_ctx_state_t *g_ctx_list;
static int               g_ctx_count;
static glstate_t        *g_ctx_root;   /* first state = group root (owns shared tables) */
static int               g_ctx_logged;
static int               g_ctx_warned;

/* Build tag: printed once so a device log shows WHICH build is running and that
 * the TLS registry is active (bump on every behavioural change). */
#define MEOW_CTX_BUILD_TAG "2026-09-29-ctxiso-tls2"

static void meow_ctx_log_once(void) {
    if (g_ctx_logged)
        return;
    g_ctx_logged = 1;
    fprintf(stderr, "[meow-ctx] build=%s tls=1 registry=on\n", MEOW_CTX_BUILD_TAG);
}

EXPORT
void *meow_gl4es_bind(void *eglContext) {
    if (eglContext == NULL)
        return meow_gl4es_unbind();

    pthread_mutex_lock(&g_ctx_mutex);
    meow_ctx_log_once();   /* inside the lock: exactly one "[meow-ctx] build=…" line */

    meow_ctx_state_t *e = g_ctx_list;
    while (e != NULL && e->egl_ctx != eglContext)
        e = e->next;

    if (e == NULL && g_ctx_count < MEOW_CTX_MAX) {
        e = (meow_ctx_state_t *)calloc(1, sizeof(*e));
        if (e != NULL) {
            e->egl_ctx = eglContext;
            e->next = g_ctx_list;
            g_ctx_list = e;
            ++g_ctx_count;
        }
    }

    if (e != NULL && e->state == NULL) {
        /* First bind of this EGL context: give it a glstate.
         *  - the FIRST context bound is the share-group ROOT and owns the shared
         *    object tables (texture.list / buffers / glsl / headlists / fpe_cache
         *    / fbo lists / samplers / queries — see glstate.h "shared" comments);
         *  - every later context is NewGLState(root, 0): it SHARES those tables but
         *    has its own matrices / enables / immediate-mode transaction / VAO /
         *    gleshard — exactly the EGL shared-context semantics upstream's
         *    glx.c provides on Linux (glx.c:1232).
         *  es2only=0 matches gl_init()'s default (this stack reports GL 2.1). */
        if (g_ctx_root == NULL) {
            e->state = (glstate_t *)NewGLState(NULL, 0);
            if (e->state != NULL)
                g_ctx_root = e->state;
        } else {
            e->state = (glstate_t *)NewGLState(g_ctx_root, 0);
        }
        if (e->state != NULL) {
            fprintf(stderr, "[meow-ctx] ctx=%p -> state=%p (%s)\n", eglContext,
                    (void *)e->state,
                    (e->state == g_ctx_root) ? "root: owns shared tables"
                                             : "shared child of root");
        }
    }

    if (e != NULL && e->state != NULL) {
        ActivateGLState(e->state);   /* sets this thread's TLS glstate */
        glstate_t *st = e->state;
        pthread_mutex_unlock(&g_ctx_mutex);
        return st;
    }

    /* Fallback (OOM, or registry full). We were called with a NON-NULL ctx, i.e. this
     * thread DOES have a live context, so we must NOT install default_glstate here: that
     * would (a) break the documented invariant that default_glstate is only ever the
     * "no context on this thread" state, and (b) let this live context scribble the shared
     * default state. Instead keep this thread's current state (its previous context's
     * state, or default_glstate if it never bound one) and warn loudly: this context's GL
     * state is then not isolated, but the process stays consistent. Reachable only on
     * calloc OOM or a >MEOW_CTX_MAX context leak (never observed). */
    pthread_mutex_unlock(&g_ctx_mutex);
    if (!g_ctx_warned) {
        g_ctx_warned = 1;
        fprintf(stderr,
                "[meow-ctx] WARN: no state for ctx=%p (count=%d/%d) -> keeping previous "
                "thread state (default_glstate not given to a live context)\n",
                eglContext, g_ctx_count, MEOW_CTX_MAX);
    }
    return glstate;
}

EXPORT
void *meow_gl4es_unbind(void) {
    /* This thread has no current EGL context.  Keep the registry untouched: the
     * same EGL context must get back the SAME state when it is re-bound, else its
     * per-context caches (VAO/gleshard/display-list transaction) would be lost. */
    ActivateGLState(&default_glstate);
    return &default_glstate;
}

EXPORT
void meow_gl4es_forget(void *eglContext) {
    if (eglContext == NULL)
        return;
    pthread_mutex_lock(&g_ctx_mutex);
    meow_ctx_state_t **pp = &g_ctx_list;
    while (*pp != NULL && (*pp)->egl_ctx != eglContext)
        pp = &(*pp)->next;
    if (*pp != NULL) {
        meow_ctx_state_t *e = *pp;
        *pp = e->next;
        --g_ctx_count;
        /* Clearing the root covers BOTH orders the registry can see: (a) a secondary
         * forgotten while it is the root (the primary was forgotten first), and (b) the
         * PRIMARY itself being forgotten at process exit -- egl_gl.c's meowTerminate DOES
         * destroy the primary EGL context (only the app-level ContextGL.destroy() is
         * ignored), and now calls meow_gl4es_forget for it too. */
        if (e->state != NULL && e->state == g_ctx_root)
            g_ctx_root = NULL;
        /* Deliberately NOT DeleteGLState()/free(state): another thread's TLS
         * `glstate` may still point at it (bind/unbind ordering is the app's), and
         * freeing would be a use-after-free.  Leak = one glstate_t per destroyed
         * context; the process creates only a handful. */
        free(e);
    }
    pthread_mutex_unlock(&g_ctx_mutex);
}
