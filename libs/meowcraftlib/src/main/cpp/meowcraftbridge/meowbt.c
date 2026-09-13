/*
 * meowbt.c - SIGSEGV/SIGBUS/SIGABRT dumper (diagnostic, env MEOW_BT).
 *
 * Why: GALLIUM_THREAD=1 (Mesa glthread) crashes ~50% of runs inside the Huawei
 * Vulkan driver's pipeline-cache path (see notes 20-design/性能优化-实验台与
 * glthread负项.md). The driver is a closed blob, so we catch the signal and
 * report the interrupted context, resolved against the process memory map.
 *
 * Facts learned the hard way:
 *   - backtrace() inside the handler only unwinds the *handler's* stack (it does
 *     not cross the signal frame) -> useless; report ucontext registers instead.
 *   - dl_iterate_phdr() misses the app's module-namespace libraries (libgallium,
 *     libhvgr, libjvm, ...), so resolve against /proc/self/maps instead (the full
 *     mapping set, including anonymous regions).
 *   - Install from a thread that runs after the JVM is up (bridge render thread):
 *     HotSpot replaces SIGSEGV during startup, so installing earlier is undone.
 *     We chain to the previously installed handler, so crash semantics are
 *     unchanged.
 *   - Only non-null-ish faults are dumped (HotSpot's implicit-null-check SIGSEGVs
 *     are benign and frequent).
 *   - Output goes to stderr, which the JVM launcher redirected into a pipe that
 *     is pumped to hilog.
 */
#define _GNU_SOURCE

#include "meowbt.h"

#include <link.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ucontext.h>

#define BT_MAX_DUMPS 24
/* Faults below this are HotSpot's implicit-null-check range: benign. */
#define BT_BENIGN_MAX 0x10000UL

#define MAP_MAX 16384
#define MAP_NAME_MAX 72

typedef struct {
    unsigned long start;
    unsigned long end;
    char name[MAP_NAME_MAX];
} MapEntry;

static MapEntry g_maps[MAP_MAX];
static int g_mapc = 0;

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

/* Read /proc/self/maps into g_maps; fall back to dl_iterate_phdr if unavailable. */
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

static void print_resolved(const char *label, unsigned long a) {
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
    } else {
        p = put_str(p, " <UNMAPPED>");
    }
    p = put_str(p, "\n");
    write_buf(g_buf, (int)(p - g_buf));
}

static void print_map(void) {
    char *q = g_buf;
    q = put_str(q, "[meowbt] mapcount=");
    q = put_dec(q, g_mapc);
    q = put_str(q, "\n");
    write_buf(g_buf, (int)(q - g_buf));

    /* Aggregate by name (file-backed + anon-exec) to keep the log compact. */
    enum { UNIQ_MAX = 768 };
    static char names[UNIQ_MAX][MAP_NAME_MAX];
    static unsigned long nstart[UNIQ_MAX];
    static unsigned long nend[UNIQ_MAX];
    int nc = 0;

    for (int i = 0; i < g_mapc; ++i) {
        const char *nm = g_maps[i].name;
        if (nm[0] == '\0') {
            continue;
        }
        if (nm[0] == '<' && strcmp(nm, "<anon-exec>") != 0) {
            continue; /* skip plain anon/data regions */
        }
        int idx = -1;
        for (int j = 0; j < nc; ++j) {
            if (strcmp(names[j], nm) == 0) {
                idx = j;
                break;
            }
        }
        if (idx < 0) {
            if (nc >= UNIQ_MAX) {
                continue;
            }
            idx = nc++;
            size_t nl = strlen(nm);
            if (nl >= MAP_NAME_MAX) {
                nl = MAP_NAME_MAX - 1;
            }
            memcpy(names[idx], nm, nl);
            names[idx][nl] = '\0';
            nstart[idx] = g_maps[i].start;
            nend[idx] = g_maps[i].end;
        } else {
            if (g_maps[i].start < nstart[idx]) {
                nstart[idx] = g_maps[i].start;
            }
            if (g_maps[i].end > nend[idx]) {
                nend[idx] = g_maps[i].end;
            }
        }
    }

    for (int j = 0; j < nc; ++j) {
        char *p = g_buf;
        p = put_str(p, "[meowbt] mod ");
        p = put_hex(p, nstart[j]);
        p = put_str(p, "-");
        p = put_hex(p, nend[j]);
        p = put_str(p, " ");
        p = put_str(p, names[j]);
        p = put_str(p, "\n");
        write_buf(g_buf, (int)(p - g_buf));
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

static void handler(int signo, siginfo_t *si, void *uctx) {
    int idx = (signo == SIGSEGV) ? 0 : (signo == SIGBUS ? 1 : 2);

    unsigned long addr = 0;
    unsigned long pc = 0;
    unsigned long sp = 0;
    unsigned long fp = 0;
    unsigned long lr = 0;
    unsigned long x0 = 0, x1 = 0, x2 = 0, x3 = 0, x8 = 0;
    if (si != NULL) {
        addr = (unsigned long)si->si_addr;
    }
    if (uctx != NULL) {
        ucontext_t *uc = (ucontext_t *)uctx;
        pc = (unsigned long)uc->uc_mcontext.pc;
        sp = (unsigned long)uc->uc_mcontext.sp;
        fp = (unsigned long)uc->uc_mcontext.regs[29];
        lr = (unsigned long)uc->uc_mcontext.regs[30];
        x0 = (unsigned long)uc->uc_mcontext.regs[0];
        x1 = (unsigned long)uc->uc_mcontext.regs[1];
        x2 = (unsigned long)uc->uc_mcontext.regs[2];
        x3 = (unsigned long)uc->uc_mcontext.regs[3];
        x8 = (unsigned long)uc->uc_mcontext.regs[8];
        if (addr == 0) {
            addr = (unsigned long)uc->uc_mcontext.fault_address;
        }
    }

    int benign = (addr != 0 && addr < BT_BENIGN_MAX);
    if (!benign && g_dumps < BT_MAX_DUMPS) {
        g_dumps++;

        char *p = g_buf;
        p = put_str(p, "[meowbt] FAULT#");
        p = put_dec(p, g_dumps);
        p = put_str(p, " sig=");
        p = put_dec(p, signo);
        p = put_str(p, " code=");
        p = put_dec(p, (si != NULL) ? (long)si->si_code : -1);
        p = put_str(p, " addr=");
        p = put_hex(p, addr);
        p = put_str(p, " pc=");
        p = put_hex(p, pc);
        p = put_str(p, " lr=");
        p = put_hex(p, lr);
        p = put_str(p, " sp=");
        p = put_hex(p, sp);
        p = put_str(p, " fp=");
        p = put_hex(p, fp);
        p = put_str(p, "\n");
        write_buf(g_buf, (int)(p - g_buf));

        p = g_buf;
        p = put_str(p, "[meowbt]   x0=");
        p = put_hex(p, x0);
        p = put_str(p, " x1=");
        p = put_hex(p, x1);
        p = put_str(p, " x2=");
        p = put_hex(p, x2);
        p = put_str(p, " x3=");
        p = put_hex(p, x3);
        p = put_str(p, " x8=");
        p = put_hex(p, x8);
        p = put_str(p, "\n");
        write_buf(g_buf, (int)(p - g_buf));

        print_resolved("addr->", addr);
        print_resolved("pc  ->", pc);
        print_resolved("lr  ->", lr);
        print_resolved("fp  ->", fp);
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
