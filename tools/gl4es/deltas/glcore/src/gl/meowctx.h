/*
 * Meowcraft gl4es delta: per-EGL-context glstate isolation — public hook.
 *
 * See meowctx.c for the full rationale. Short version: our gl4es is built
 * NOX11+NOEGL, so upstream's glx.c per-context machinery never runs and the
 * host (libmeowcraftbridge.so) owns EGL. The bridge therefore calls
 *
 *     meow_gl4es_bind(EGLContext)    after every successful eglMakeCurrent
 *     meow_gl4es_unbind()            when it releases the thread's context
 *     meow_gl4es_forget(EGLContext)  when it destroys a secondary context
 *
 * and this file maps each EGL context to its own glstate_t (sharing the object
 * tables between contexts of the same share group, as EGL requires).
 *
 * These are plain-C exports out of libgl4es.so; the bridge resolves them with
 * dlsym and degrades safely when they are absent (older libgl4es.so).
 */
#ifndef MEOW_GL4ES_CTX_H
#define MEOW_GL4ES_CTX_H

#include "attributes.h"   /* EXPORT (gl4es is built -fvisibility=hidden) */

#ifdef __cplusplus
extern "C" {
#endif

/* Bind the glstate belonging to `eglContext` on the CALLING THREAD and make it
 * current for gl4es. Lazily creates the state on first use. Never leaves the
 * thread with a NULL state (falls back to the no-context default state).
 * `eglContext == NULL` is treated as unbind(). Returns the bound state (opaque). */
EXPORT void *meow_gl4es_bind(void *eglContext);

/* Detach the calling thread from any glstate (it has no current EGL context).
 * Returns the fallback ("no context") state. */
EXPORT void *meow_gl4es_unbind(void);

/* Drop the registry entry for a destroyed EGL context so a later context that
 * reuses the same address cannot inherit its stale state. Does not free the
 * state (a stale thread pointer must never dangle). */
EXPORT void meow_gl4es_forget(void *eglContext);

#ifdef __cplusplus
}
#endif

#endif /* MEOW_GL4ES_CTX_H */
