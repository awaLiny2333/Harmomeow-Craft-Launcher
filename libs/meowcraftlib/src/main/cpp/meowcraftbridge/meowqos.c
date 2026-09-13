/*
 * meowqos.c - experimental thread QoS / CPU-affinity knobs (env driven).
 *
 * See meowqos.h for the two environment variables. Everything here is
 * best-effort: the goal is to let the launcher A/B platform scheduling levers
 * without a hard dependency on the device exposing them.
 *
 *   - QoS: OH_QoS_SetThreadQoS() lives in the device's libqos.so. We resolve it
 *     with dlopen()/dlsym() instead of linking, so a device without the library
 *     keeps working (the call is simply skipped, with one warning).
 *   - Affinity: sched_setaffinity() is libc. The launch thread is pinned before
 *     the JVM starts, and JVM worker/render threads inherit the mask.
 */
#define _GNU_SOURCE /* cpu_set_t / CPU_SET / sched_setaffinity (glibc & musl) */

#include "meowqos.h"

#include <dlfcn.h>
#include <errno.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>

#include "meowlog.h"

/* OH_QoS_Level (qos/qos.h), redeclared locally to avoid a hard link. */
typedef enum {
    MEOW_QOS_BACKGROUND = 0,
    MEOW_QOS_UTILITY,
    MEOW_QOS_DEFAULT,
    MEOW_QOS_USER_INITIATED,
    MEOW_QOS_DEADLINE_REQUEST,
    MEOW_QOS_USER_INTERACTIVE
} MeowQosLevel;
typedef int (*MeowQosSetThreadQosFn)(MeowQosLevel);

#ifndef CPU_SETSIZE
#define CPU_SETSIZE 128
#endif

/* "0" / "" / unset are all "disabled"; anything else (e.g. "1") enables. */
static int env_enabled(const char *v) {
    return v != NULL && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
}

void meow_qos_apply_current_thread(void) {
    static __thread int done = 0;
    if (done) {
        return;
    }
    done = 1;
    if (!env_enabled(getenv("MEOW_QOS"))) {
        return;
    }

    static void *lib = NULL;
    static MeowQosSetThreadQosFn setFn = NULL;
    static int resolved = 0;
    if (!resolved) {
        resolved = 1;
        lib = dlopen("/system/lib64/libqos.so", RTLD_NOW | RTLD_LOCAL);
        if (lib == NULL) {
            lib = dlopen("libqos.so", RTLD_NOW | RTLD_LOCAL);
        }
        if (lib == NULL) {
            MEOWLOGW("QoS: libqos.so not found (%{public}s)", dlerror());
            return;
        }
        setFn = (MeowQosSetThreadQosFn)dlsym(lib, "OH_QoS_SetThreadQoS");
        if (setFn == NULL) {
            MEOWLOGW("QoS: OH_QoS_SetThreadQoS missing in libqos.so");
            return;
        }
        MEOWLOGI("QoS: libqos.so loaded");
    }
    if (setFn != NULL) {
        int rc = setFn(MEOW_QOS_USER_INTERACTIVE);
        MEOWLOGI("QoS: current thread -> USER_INTERACTIVE rc=%{public}d", rc);
    }
}

/* Parse "0-3,8,10-11" into a cpu_set_t. Returns 0 on success, -1 on bad spec. */
static int parse_cpuset(const char *spec, cpu_set_t *set) {
    CPU_ZERO(set);
    const char *p = spec;
    int any = 0;
    while (*p != '\0') {
        while (*p == ' ' || *p == '\t' || *p == ',') {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        char *end = NULL;
        long lo = strtol(p, &end, 10);
        if (end == p) {
            return -1;
        }
        p = end;
        long hi = lo;
        if (*p == '-') {
            ++p;
            long v = strtol(p, &end, 10);
            if (end == p) {
                return -1;
            }
            hi = v;
            p = end;
        }
        if (lo < 0 || hi < lo || hi >= CPU_SETSIZE) {
            return -1;
        }
        for (long c = lo; c <= hi; ++c) {
            CPU_SET((int)c, set);
            any = 1;
        }
    }
    return any ? 0 : -1;
}

int meow_affinity_apply_current_thread(void) {
    static __thread int done = 0;
    if (done) {
        return 1;
    }
    done = 1;
    const char *spec = getenv("MEOW_AFFINITY");
    if (spec == NULL || spec[0] == '\0') {
        return 1;
    }
    cpu_set_t set;
    if (parse_cpuset(spec, &set) != 0) {
        MEOWLOGW("affinity: bad spec '%{public}s' (want e.g. 8-19 or 0-3,8)", spec);
        return -1;
    }
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        MEOWLOGW("affinity: sched_setaffinity('%{public}s') failed errno=%{public}d", spec, errno);
        return -1;
    }
    int n = 0;
    for (int c = 0; c < CPU_SETSIZE; ++c) {
        if (CPU_ISSET(c, &set)) {
            ++n;
        }
    }
    MEOWLOGI("affinity: current thread bound to '%{public}s' (%{public}d cpus)", spec, n);
    return 0;
}
