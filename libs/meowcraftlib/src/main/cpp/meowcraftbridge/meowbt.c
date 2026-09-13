/*
 * meowbt.c - SIGSEGV/SIGBUS/SIGABRT backtrace dumper (diagnostic, env MEOW_BT).
 *
 * Why: GALLIUM_THREAD=1 (Mesa glthread) crashes ~50% of runs inside the Huawei
 * Vulkan driver's pipeline-cache path (see notes 20-design/性能优化-实验台与
 * glthread负项.md). The driver is a closed blob, so the only way to pin the
 * faulting call/thread from our side is to catch the signal ourselves, dump a
 * native backtrace (OHOS libc exports execinfo backtrace()), and then chain to
 * the handler the JVM installed so crash behavior is unchanged.
 *
 * Install from a thread that runs after the JVM is up (the bridge render
 * thread): HotSpot replaces SIGSEGV during startup, so installing earlier would
 * be undone. Output goes to stderr, which the JVM launcher has redirected into a
 * pipe that is pumped to hilog.
 *
 * Only non-null-ish faults are dumped: HotSpot uses SIGSEGV for implicit null
 * checks (addresses near 0) and those are benign and frequent.
 */
#define _GNU_SOURCE

#include "meowbt.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ucontext.h>

#define BT_MAX_FRAMES 64
#define BT_MAX_DUMPS 32
/* Faults below this are HotSpot's implicit-null-check range: benign. */
#define BT_BENIGN_MAX 0x10000UL

static struct sigaction g_prev[3]; /* 0 = SEGV, 1 = BUS, 2 = ABRT */
static int g_prev_valid[3];
static int g_installed = 0;
static volatile int g_dumps = 0;
static char g_buf[4096];

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

/* "#NN 0xADDR symbol+off in lib+off" via dladdr. */
static void dump_frame(int idx, void *addr) {
    Dl_info di;
    char *p = g_buf;
    p = put_str(p, "#");
    p = put_dec(p, idx);
    p = put_str(p, " ");
    p = put_hex(p, (unsigned long)addr);
    if (dladdr(addr, &di) != 0) {
        if (di.dli_sname != NULL) {
            p = put_str(p, " ");
            p = put_str(p, di.dli_sname);
            p = put_str(p, "+");
            p = put_hex(p, (unsigned long)((const char *)addr - (const char *)di.dli_saddr));
        }
        if (di.dli_fname != NULL) {
            const char *b = strrchr(di.dli_fname, '/');
            p = put_str(p, " in ");
            p = put_str(p, (b != NULL) ? b + 1 : di.dli_fname);
            p = put_str(p, "+");
            p = put_hex(p, (unsigned long)((const char *)addr - (const char *)di.dli_fbase));
        }
    }
    p = put_str(p, "\n");
    write_buf(g_buf, (int)(p - g_buf));
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
    if (si != NULL) {
        addr = (unsigned long)si->si_addr;
    }
    if (uctx != NULL) {
        ucontext_t *uc = (ucontext_t *)uctx;
        pc = (unsigned long)uc->uc_mcontext.pc;
        sp = (unsigned long)uc->uc_mcontext.sp;
        fp = (unsigned long)uc->uc_mcontext.regs[29];
        lr = (unsigned long)uc->uc_mcontext.regs[30];
        if (addr == 0) {
            addr = (unsigned long)uc->uc_mcontext.fault_address;
        }
    }

    int benign = (addr != 0 && addr < BT_BENIGN_MAX);
    if (!benign && g_dumps < BT_MAX_DUMPS) {
        g_dumps++;

        /* Register line first: decisive even if backtrace() fails below. */
        char *p = g_buf;
        p = put_str(p, "[meowbt] signal=");
        p = put_dec(p, signo);
        p = put_str(p, " code=");
        p = put_dec(p, (si != NULL) ? (long)si->si_code : -1);
        p = put_str(p, " addr=");
        p = put_hex(p, addr);
        p = put_str(p, " pc=");
        p = put_hex(p, pc);
        p = put_str(p, " lr=");
        p = put_hex(p, lr);
        p = put_str(p, " fp=");
        p = put_hex(p, fp);
        p = put_str(p, " sp=");
        p = put_hex(p, sp);
        p = put_str(p, "\n");
        write_buf(g_buf, (int)(p - g_buf));

        /* Decisive minimal stack: pc + lr resolved via dladdr (lib + offset). */
        if (pc != 0) {
            dump_frame(0, (void *)pc);
        }
        if (lr != 0) {
            dump_frame(1, (void *)lr);
        }

        /* Full native stack (best effort; may allocate inside libc). */
        void *frames[BT_MAX_FRAMES];
        int n = backtrace(frames, BT_MAX_FRAMES);
        for (int i = 0; i < n && i < BT_MAX_FRAMES; ++i) {
            dump_frame(i, frames[i]);
        }
        const char *end = "[meowbt] end\n";
        write_buf(end, (int)strlen(end));
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

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
    sigemptyset(&sa.sa_mask);

    g_prev_valid[0] = (sigaction(SIGSEGV, &sa, &g_prev[0]) == 0);
    g_prev_valid[1] = (sigaction(SIGBUS, &sa, &g_prev[1]) == 0);
    g_prev_valid[2] = (sigaction(SIGABRT, &sa, &g_prev[2]) == 0);

    const char *msg = "[meowbt] installed (SEGV/BUS/ABRT); dump non-null faults\n";
    write_buf(msg, (int)strlen(msg));
}
