/*
 * meowbt.c - SIGSEGV/SIGBUS/SIGABRT dumper (diagnostic, env MEOW_BT).
 *
 * Context: with Mesa glthread (GALLIUM_THREAD=1) MC 26.x dies in libgallium/Zink
 * (see notes 20-design/glthread崩溃-bug报告.md). This dumper captures the
 * interrupted context so the faulting call site can be identified.
 *
 * Hard-won constraints:
 *   - backtrace() inside the handler only unwinds the *handler's* stack -> use
 *     the ucontext registers instead.
 *   - dl_iterate_phdr misses app-namespace libs (libgallium/libhvgr/libjvm), so
 *     resolve against /proc/self/maps (snapshotted at install, so the handler
 *     never calls into the loader).
 *   - HotSpot poll/guard faults (a constant PROT_NONE page, hit during safe
 *     points) are BENIGN and frequent; they must not be mistaken for the crash.
 *     We treat addr==0 / addr<64 KB as benign, collapse repeats of the same
 *     address to one compact line, and label 4 KB unnamed PROT_NONE pages.
 *   - Install from the bridge render thread (after HotSpot installs SIGSEGV) and
 *     chain to the previous handler, so crash semantics are unchanged.
 */
#define _GNU_SOURCE

#include "meowbt.h"

#include <link.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <ucontext.h>

#define BT_MAX_DUMPS 16
/* Faults below this are HotSpot's implicit-null-check range: benign. */
#define BT_BENIGN_MAX 0x10000UL

#define MAP_MAX 16384
#define MAP_NAME_MAX 72
#define SEEN_MAX 64

typedef struct {
    unsigned long start;
    unsigned long end;
    char perms[5];
    char name[MAP_NAME_MAX];
} MapEntry;

static MapEntry g_maps[MAP_MAX];
static int g_mapc = 0;

static unsigned long g_seen_addr[SEEN_MAX];
static int g_seen_count[SEEN_MAX];
static int g_seen_n = 0;

static struct sigaction g_prev[3]; /* 0 = SEGV, 1 = BUS, 2 = ABRT */
static int g_prev_valid[3];
static int g_installed = 0;
static volatile int g_dumps = 0;
static char g_buf[2048];

static char *put_str(char *p, const char *s) {
    while (*s != '\0') {
        *p++ = *s++;
    }
    return p;
}

static char *put_hex(char *p, unsigned long v) {
    static const char h[] = "0123456789abcdef";
    *p++ = '0';
    *p++ = 'x';
    if (v == 0) {
        *p++ = '0';
        return p;
    }
    char t[16];
    int i = 0;
    while (v != 0) {
        t[i++] = h[v & 0xf];
        v >>= 4;
    }
    while (i > 0) {
        *p++ = t[--i];
    }
    return p;
}

static char *put_dec(char *p, long v) {
    if (v < 0) {
        *p++ = '-';
        v = -v;
    }
    char t[16];
    int i = 0;
    if (v == 0) {
        t[i++] = '0';
    }
    while (v != 0) {
        t[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i > 0) {
        *p++ = t[--i];
    }
    return p;
}

static void write_buf(const char *b, int len) {
    if (len > 0) {
        ssize_t r = write(STDERR_FILENO, b, (size_t)len);
        (void)r;
    }
}

static void set_name(MapEntry *m, const char *s) {
    m->name[0] = '\0';
    if (s == NULL || s[0] == '\0') {
        return;
    }
    size_t n = strlen(s);
    if (n >= MAP_NAME_MAX) {
        n = MAP_NAME_MAX - 1;
    }
    memcpy(m->name, s, n);
    m->name[n] = '\0';
}

/* ---- /proc/self/maps snapshot (falls back to dl_iterate_phdr) ------------ */

static int phdr_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    (void)data;
    if (g_mapc >= MAP_MAX) {
        return 1;
    }
    unsigned long lo = ~0UL;
    unsigned long hi = 0;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD) {
            continue;
        }
        unsigned long s = (unsigned long)info->dlpi_addr + (unsigned long)ph->p_vaddr;
        unsigned long e = s + (unsigned long)ph->p_memsz;
        if (s < lo) {
            lo = s;
        }
        if (e > hi) {
            hi = e;
        }
    }
    if (hi <= lo) {
        return 0;
    }
    g_maps[g_mapc].start = lo;
    g_maps[g_mapc].end = hi;
    memcpy(g_maps[g_mapc].perms, "r-xp", 4);
    g_maps[g_mapc].perms[4] = '\0';
    const char *nm = info->dlpi_name;
    const char *bn = (nm != NULL) ? strrchr(nm, '/') : NULL;
    set_name(&g_maps[g_mapc], (bn != NULL) ? bn + 1 : (nm != NULL ? nm : "?"));
    g_mapc++;
    return 0;
}

static void load_map(void) {
    g_mapc = 0;
    FILE *fp = fopen("/proc/self/maps", "r");
    if (fp != NULL) {
        char line[512];
        while (g_mapc < MAP_MAX && fgets(line, sizeof(line), fp) != NULL) {
            unsigned long s = 0;
            unsigned long e = 0;
            char perms[8] = {0};
            int off = 0;
            if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &s, &e, perms, &off) < 3) {
                continue;
            }
            g_maps[g_mapc].start = s;
            g_maps[g_mapc].end = e;
            memcpy(g_maps[g_mapc].perms, perms, 4);
            g_maps[g_mapc].perms[4] = '\0';
            const char *path = line + off;
            if (path[0] != '\0') {
                const char *bn = strrchr(path, '/');
                set_name(&g_maps[g_mapc], (bn != NULL) ? bn + 1 : path);
            } else if (strchr(perms, 'x') != NULL) {
                set_name(&g_maps[g_mapc], "<anon-exec>");
            } else {
                set_name(&g_maps[g_mapc], "<anon>");
            }
            g_mapc++;
        }
        fclose(fp);
    } else {
        dl_iterate_phdr(phdr_cb, NULL);
    }
}

static const MapEntry *find_map(unsigned long a) {
    for (int i = 0; i < g_mapc; ++i) {
        if (a >= g_maps[i].start && a < g_maps[i].end) {
            return &g_maps[i];
        }
    }
    return NULL;
}

static void print_mapping_of(const char *label, unsigned long a) {
    if (a == 0) {
        return;
    }
    char *p = g_buf;
    p = put_str(p, "[meowbt]   ");
    p = put_str(p, label);
    p = put_str(p, "=");
    p = put_hex(p, a);
    const MapEntry *m = find_map(a);
    if (m != NULL) {
        p = put_str(p, " ");
        p = put_str(p, (m->name[0] != '\0') ? m->name : "?");
        p = put_str(p, "+");
        p = put_hex(p, a - m->start);
        p = put_str(p, " [");
        p = put_str(p, m->perms);
        p = put_str(p, " size=");
        p = put_hex(p, m->end - m->start);
        p = put_str(p, "]");
    } else {
        p = put_str(p, " <UNMAPPED>");
    }
    p = put_str(p, "\n");
    write_buf(g_buf, (int)(p - g_buf));
}

/* Key libraries whose load base we always want (the aggregate list can be
 * truncated), so fault offsets can be resolved offline. */
static int name_is_key(const char *n) {
    static const char *keys[] = {
        "gallium", "hvgr", "libjvm", "libjli", "ld-musl", "meowcraftbridge",
        "meowjrebridge", "libEGL", "libGLv4", "libvulkan", "bisheng", "libc6", NULL
    };
    for (int i = 0; keys[i] != NULL; ++i) {
        if (strstr(n, keys[i]) != NULL) {
            return 1;
        }
    }
    return 0;
}

static void print_map(void) {
    char *q = g_buf;
    q = put_str(q, "[meowbt] mapcount=");
    q = put_dec(q, g_mapc);
    q = put_str(q, "\n");
    write_buf(g_buf, (int)(q - g_buf));

    /* Key libraries first (aggregated by name, full range). */
    for (int i = 0; i < g_mapc; ++i) {
        const char *nm = g_maps[i].name;
        if (nm[0] == '<' || !name_is_key(nm)) {
            continue;
        }
        /* merge all segments with the same name */
        unsigned long lo = g_maps[i].start;
        unsigned long hi = g_maps[i].end;
        for (int j = i + 1; j < g_mapc; ++j) {
            if (strcmp(g_maps[j].name, nm) == 0) {
                if (g_maps[j].start < lo) {
                    lo = g_maps[j].start;
                }
                if (g_maps[j].end > hi) {
                    hi = g_maps[j].end;
                }
            }
        }
        char *p = g_buf;
        p = put_str(p, "[meowbt] KEY ");
        p = put_hex(p, lo);
        p = put_str(p, "-");
        p = put_hex(p, hi);
        p = put_str(p, " ");
        p = put_str(p, nm);
        p = put_str(p, "\n");
        write_buf(g_buf, (int)(p - g_buf));
    }

    /* anon-exec regions (JIT / generated code) with size. */
    for (int i = 0; i < g_mapc; ++i) {
        if (strcmp(g_maps[i].name, "<anon-exec>") != 0) {
            continue;
        }
        char *p = g_buf;
        p = put_str(p, "[meowbt] exec ");
        p = put_hex(p, g_maps[i].start);
        p = put_str(p, "-");
        p = put_hex(p, g_maps[i].end);
        p = put_str(p, " ");
        p = put_str(p, g_maps[i].perms);
        p = put_str(p, " size=");
        p = put_hex(p, g_maps[i].end - g_maps[i].start);
        p = put_str(p, "\n");
        write_buf(g_buf, (int)(p - g_buf));
    }
}

/* ---- signal handling ----------------------------------------------------- */

static void print_bt_frame(int idx, unsigned long a) {
    char lbl[8];
    lbl[0] = 'b';
    lbl[1] = 't';
    lbl[2] = '#';
    char d[4];
    int k = 0;
    int n = idx;
    if (n == 0) {
        d[k++] = '0';
    }
    while (n > 0) {
        d[k++] = (char)('0' + (n % 10));
        n /= 10;
    }
    int j = 3;
    while (k > 0) {
        lbl[j++] = d[--k];
    }
    lbl[j] = '\0';
    print_mapping_of(lbl, a);
}

/* Bounded frame-pointer walk from the *faulting* context (x29): the first
 * return address is the caller of the crashing function. Best-effort: Mesa may
 * omit frame pointers. Reads are confined to the faulting stack window. */
static void walk_fp(unsigned long fp, unsigned long sp) {
    unsigned long cur = fp;
    unsigned long prev = 0;
    for (int i = 0; i < 24; ++i) {
        if (cur == 0 || (cur & 0x7UL) != 0) {
            break;
        }
        if (cur < sp || (cur - sp) > 0x400000UL) {
            break;
        }
        if (cur <= prev) {
            break;
        }
        unsigned long *frame = (unsigned long *)cur;
        unsigned long next = frame[0];
        unsigned long ret = frame[1];
        print_bt_frame(i, ret);
        if (ret == 0) {
            break;
        }
        prev = cur;
        cur = next;
    }
}

static void chain_to_prev(int idx, int signo, siginfo_t *si, void *uctx) {
    if (idx < 0 || idx > 2 || !g_prev_valid[idx]) {
        signal(signo, SIG_DFL);
        raise(signo);
        return;
    }
    struct sigaction *o = &g_prev[idx];
    if ((o->sa_flags & SA_SIGINFO) != 0 && o->sa_sigaction != NULL) {
        o->sa_sigaction(signo, si, uctx);
    } else if (o->sa_handler != SIG_DFL && o->sa_handler != SIG_IGN && o->sa_handler != NULL) {
        o->sa_handler(signo);
    } else {
        signal(signo, SIG_DFL);
        raise(signo);
    }
}

static void append_regs(char *p, const long *r) {
    p = put_str(p, " x0=");
    p = put_hex(p, (unsigned long)r[0]);
    p = put_str(p, " x1=");
    p = put_hex(p, (unsigned long)r[1]);
    p = put_str(p, " x2=");
    p = put_hex(p, (unsigned long)r[2]);
    p = put_str(p, " x8=");
    p = put_hex(p, (unsigned long)r[8]);
    p = put_str(p, " x27=");
    p = put_hex(p, (unsigned long)r[27]);
    p = put_str(p, " x28=");
    p = put_hex(p, (unsigned long)r[28]);
    p = put_str(p, "\n");
    write_buf(g_buf, (int)(p - g_buf));
}

static void handler(int signo, siginfo_t *si, void *uctx) {
    int idx = (signo == SIGSEGV) ? 0 : (signo == SIGBUS ? 1 : 2);

    unsigned long addr = 0;
    unsigned long pc = 0;
    unsigned long sp = 0;
    unsigned long fp = 0;
    unsigned long lr = 0;
    long regs[31] = {0};
    if (si != NULL) {
        addr = (unsigned long)si->si_addr;
    }
    if (uctx != NULL) {
        ucontext_t *uc = (ucontext_t *)uctx;
        pc = (unsigned long)uc->uc_mcontext.pc;
        sp = (unsigned long)uc->uc_mcontext.sp;
        fp = (unsigned long)uc->uc_mcontext.regs[29];
        lr = (unsigned long)uc->uc_mcontext.regs[30];
        for (int i = 0; i < 31; ++i) {
            regs[i] = (long)uc->uc_mcontext.regs[i];
        }
        if (addr == 0) {
            addr = (unsigned long)uc->uc_mcontext.fault_address;
        }
    }

    /* addr==0 (null) and the low implicit-null-check range are benign. */
    int benign = (addr < BT_BENIGN_MAX);
    if (!benign) {
        /* Collapse repeats of the same address (HotSpot poll/guard page faults). */
        int seen = -1;
        for (int i = 0; i < g_seen_n; ++i) {
            if (g_seen_addr[i] == addr) {
                seen = i;
                break;
            }
        }
        long tid = (long)syscall(SYS_gettid);
        if (seen >= 0) {
            g_seen_count[seen]++;
            char *p = g_buf;
            p = put_str(p, "[meowbt] repeat addr=");
            p = put_hex(p, addr);
            p = put_str(p, " x");
            p = put_dec(p, g_seen_count[seen]);
            p = put_str(p, " tid=");
            p = put_dec(p, tid);
            p = put_str(p, "\n");
            write_buf(g_buf, (int)(p - g_buf));
        } else if (g_dumps < BT_MAX_DUMPS) {
            g_dumps++;
            if (g_seen_n < SEEN_MAX) {
                g_seen_addr[g_seen_n] = addr;
                g_seen_count[g_seen_n] = 1;
                g_seen_n++;
            }
            char tname[32] = {0};
            (void)pthread_getname_np(pthread_self(), tname, sizeof(tname));

            char *p = g_buf;
            p = put_str(p, "[meowbt] FAULT#");
            p = put_dec(p, g_dumps);
            p = put_str(p, " sig=");
            p = put_dec(p, signo);
            p = put_str(p, " code=");
            p = put_dec(p, (si != NULL) ? (long)si->si_code : -1);
            p = put_str(p, " tid=");
            p = put_dec(p, tid);
            p = put_str(p, " thr=");
            p = put_str(p, (tname[0] != '\0') ? tname : "?");
            p = put_str(p, "\n");
            write_buf(g_buf, (int)(p - g_buf));

            p = g_buf;
            p = put_str(p, "[meowbt]   addr=");
            p = put_hex(p, addr);
            p = put_str(p, " pc=");
            p = put_hex(p, pc);
            p = put_str(p, " lr=");
            p = put_hex(p, lr);
            p = put_str(p, " sp=");
            p = put_hex(p, sp);
            p = put_str(p, " fp=");
            p = put_hex(p, fp);
            append_regs(p, regs);

            print_mapping_of("addr->", addr);
            print_mapping_of("pc  ->", pc);
            print_mapping_of("lr  ->", lr);
            /* 受限 fp 链回溯：抓 caller（Mesa 常省 fp，尽力而为）。 */
            if (fp != 0) {
                walk_fp(fp, sp);
            }
        }
    }

    chain_to_prev(idx, signo, si, uctx);
}

void meow_bt_install_once(void) {
    if (g_installed) {
        return;
    }
    const char *en = getenv("MEOW_BT");
    if (en == NULL || en[0] == '\0' || (en[0] == '0' && en[1] == '\0')) {
        return;
    }
    g_installed = 1;

    load_map();
    const char *hdr = "[meowbt] installed (SEGV/BUS/ABRT); maps follow\n";
    write_buf(hdr, (int)strlen(hdr));
    print_map();

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
    sigemptyset(&sa.sa_mask);

    g_prev_valid[0] = (sigaction(SIGSEGV, &sa, &g_prev[0]) == 0);
    g_prev_valid[1] = (sigaction(SIGBUS, &sa, &g_prev[1]) == 0);
    g_prev_valid[2] = (sigaction(SIGABRT, &sa, &g_prev[2]) == 0);
}
