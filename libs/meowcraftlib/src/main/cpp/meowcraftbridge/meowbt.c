/*
 * meowbt.c - SIGSEGV/SIGBUS/SIGABRT dumper (diagnostic, env MEOW_BT).
 *
 * Why: GALLIUM_THREAD=1 (Mesa glthread) crashes ~50% of runs inside the Huawei
 * Vulkan driver's pipeline-cache path (see notes 20-design/性能优化-实验台与
 * glthread负项.md). The driver is a closed blob, so the only way to pin the
 * faulting call/thread from our side is to catch the signal ourselves.
 *
 * Design notes:
 *   - backtrace() inside the handler only unwinds the *handler's* stack (it does
 *     not cross the signal frame), so it is useless here. Instead we report the
 *     interrupted context registers (from ucontext) and resolve the interesting
 *     addresses against a module table captured at install time.
 *   - The module table is built once via dl_iterate_phdr() at install, so the
 *     signal handler never calls into the dynamic loader (avoids deadlocks if the
 *     fault happened while the loader lock was held).
 *   - Install from a thread that runs after the JVM is up (bridge render thread):
 *     HotSpot replaces SIGSEGV during startup, so installing earlier is undone.
 *     We chain to the previously installed handler, so crash semantics are
 *     unchanged.
 *   - Only non-null-ish faults are dumped: HotSpot uses SIGSEGV for implicit
 *     null checks (addresses near 0), which are benign and frequent.
 *   - Output goes to stderr, which the JVM launcher redirected into a pipe that
 *     is pumped to hilog.
 */
#define _GNU_SOURCE

#include "meowbt.h"

#include <link.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ucontext.h>

#define BT_MAX_DUMPS 24
/* Faults below this are HotSpot's implicit-null-check range: benign. */
#define BT_BENIGN_MAX 0x10000UL

#define MOD_MAX 320
#define MOD_NAME_MAX 112

typedef struct {
    unsigned long base;
    unsigned long end;
    char name[MOD_NAME_MAX];
} ModEntry;

static ModEntry g_mods[MOD_MAX];
static int g_modc = 0;

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

/* Resolve an address against the cached module table (no loader lock). */
static const ModEntry *find_mod(unsigned long a) {
    for (int i = 0; i < g_modc; ++i) {
        if (a >= g_mods[i].base && a < g_mods[i].end) {
            return &g_mods[i];
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
    const ModEntry *m = find_mod(a);
    if (m != NULL) {
        p = put_str(p, " ");
        p = put_str(p, m->name[0] != '\0' ? m->name : "?");
        p = put_str(p, "+");
        p = put_hex(p, a - m->base);
    } else {
        p = put_str(p, " <anon/unmapped>");
    }
    p = put_str(p, "\n");
    write_buf(g_buf, (int)(p - g_buf));
}

static int phdr_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    (void)data;
    if (g_modc >= MOD_MAX) {
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
    g_mods[g_modc].base = lo;
    g_mods[g_modc].end = hi;
    const char *nm = info->dlpi_name;
    const char *bn = (nm != NULL) ? strrchr(nm, '/') : NULL;
    bn = (bn != NULL) ? bn + 1 : nm;
    g_mods[g_modc].name[0] = '\0';
    if (bn != NULL && bn[0] != '\0') {
        size_t n = strlen(bn);
        if (n >= MOD_NAME_MAX) {
            n = MOD_NAME_MAX - 1;
        }
        memcpy(g_mods[g_modc].name, bn, n);
        g_mods[g_modc].name[n] = '\0';
    }
    g_modc++;
    return 0;
}

static void dump_module_map(void) {
    for (int i = 0; i < g_modc; ++i) {
        char *p = g_buf;
        p = put_str(p, "[meowbt] mod ");
        p = put_hex(p, g_mods[i].base);
        p = put_str(p, "-");
        p = put_hex(p, g_mods[i].end);
        p = put_str(p, " ");
        p = put_str(p, g_mods[i].name[0] != '\0' ? g_mods[i].name : "?");
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

    /* Module table first (loader calls are safe here, not in the handler). */
    g_modc = 0;
    dl_iterate_phdr(phdr_cb, NULL);
    const char *hdr = "[meowbt] installed (SEGV/BUS/ABRT); module map follows\n";
    write_buf(hdr, (int)strlen(hdr));
    dump_module_map();

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
    sigemptyset(&sa.sa_mask);

    g_prev_valid[0] = (sigaction(SIGSEGV, &sa, &g_prev[0]) == 0);
    g_prev_valid[1] = (sigaction(SIGBUS, &sa, &g_prev[1]) == 0);
    g_prev_valid[2] = (sigaction(SIGABRT, &sa, &g_prev[2]) == 0);
}
