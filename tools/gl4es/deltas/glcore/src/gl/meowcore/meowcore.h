/*
 * Meowcraft GL3 core backend (GL 3.2/3.3 core -> native GLES 3.2) — skeleton.
 *
 * Lives in the gl4es fork delta (tools/gl4es/deltas/glcore). It deliberately
 * keeps its OWN symbol namespace (meowcore_*) so it never collides with gl4es'
 * own exported `gl*` surface (which keeps serving <=1.16 / legacy). The bridge
 * (and gl4es' glXGetProcAddress hook) selects this surface when core mode is on.
 *
 * Slice 1 (this file): mode selection, GLES resolution, glGetString /
 * glGetStringi / glGetIntegerv patching, and a table-driven GetProcAddress.
 * Later slices add shader translation (GLSL 150/330 -> ESSL 320) and the
 * name/location mapping table.
 */
#ifndef MEOWCORE_H
#define MEOWCORE_H

#ifdef __cplusplus
extern "C" {
#endif

/* gl4es is built with -fvisibility=hidden: public entry points must say so. */
#define MEOWCORE_API __attribute__((visibility("default")))

/* Build tag: printed at init so the device log states WHICH build is running
 * (bump this string on every behavioural change). */
#define MC_BUILD_TAG "2026-09-22-r9 (sampler bindings + shader diag)"

/* 1 = core (GLES) backend selected. Reads env MEOW_GL3 (unset/"0" = off). */
MEOWCORE_API int meowcore_active(void);

/* Resolve the native GLES library + the real entry points. Idempotent.
 * Returns 1 on success. Safe to call repeatedly. */
MEOWCORE_API int meowcore_init(void);

/* GL3 surface lookup: our patched entry points, else the real GLES function. */
MEOWCORE_API void *meowcore_GetProcAddress(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* MEOWCORE_H */
