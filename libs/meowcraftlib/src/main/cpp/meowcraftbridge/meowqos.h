/*
 * meowqos.h - Meowcraft native bridge: experimental thread-scheduling knobs.
 *
 * Both helpers are purely env-driven (so they can be A/B-ed with zero rebuilds
 * through the launcher's "extra render env" field) and degrade silently when the
 * platform lacks the capability:
 *
 *   MEOW_QOS=1            -> raise the *current* thread to QOS_USER_INTERACTIVE
 *   MEOW_AFFINITY=<cpuset> -> pin the *current* thread (e.g. "8-19", "0-3,8-11")
 *
 * meowqos.c is compiled into BOTH libmeowjrebridge.so and
 * libmeowcraftbridge.so, so each library raises whichever thread calls it: the
 * JVM launch thread (bridge) and the render thread (meowcraftbridge).
 */
#ifndef MEOWCRAFTBRIDGE_MEOWQOS_H
#define MEOWCRAFTBRIDGE_MEOWQOS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Raise the current thread to QOS_USER_INTERACTIVE when MEOW_QOS is enabled.
 * libqos.so is dlopen()ed on demand; a missing library / symbol is a no-op. */
void meow_qos_apply_current_thread(void);

/* Pin the current thread to the CPUs named by MEOW_AFFINITY.
 * Returns 0 = applied, 1 = not configured (skip), -1 = bad spec or EPERM. */
int meow_affinity_apply_current_thread(void);

#ifdef __cplusplus
}
#endif

#endif /* MEOWCRAFTBRIDGE_MEOWQOS_H */
