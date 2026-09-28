/*
 * libmeowglibccompat — 让「glibc 构建的 OpenJDK」跑在 OHOS(musl) 上的兼容层。
 *
 * 设计依据（2026-09-12 取证，见 notes 收编路线 C）：
 *  - OHOS loader(/lib/ld-musl-aarch64.so.1) 忽略 ELF 符号版本 -> @GLIBC_2.17 按名字解析。
 *  - ucontext_t/sigcontext 布局 glibc==musl（官方 libjvm 反汇编偏移 pc=440/sp=432/fp=416 与 musl 一致）。
 *  - struct stat / sigjmp_buf 布局 glibc==musl(aarch64) -> stat 族直通、sigsetjmp 直别名。
 * 本文件只补齐官方 JRE 在 OHOS musl 上**缺失的 libc 级符号**；其余缺件（zlib/freetype）靠链接既有件。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
#include <math.h>
#include <sched.h>
#include <pthread.h>
#include <dlfcn.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <utmpx.h>
#include <sys/auxv.h>
#include <sys/stat.h>
#include <sys/types.h>

/* ---------------- stat 族：glibc __xstat64(ver, path, buf) -- 布局一致直通 ---------------- */
int __xstat64(int ver, const char *path, struct stat *buf)  { (void)ver; return stat(path, buf); }
int __lxstat64(int ver, const char *path, struct stat *buf) { (void)ver; return lstat(path, buf); }
int __fxstat64(int ver, int fd, struct stat *buf)           { (void)ver; return fstat(fd, buf); }

/* ---------------- stat 族（非 64 后缀版）：**JDK 8 专有** ----------------
 * 官方 8 的 libjava/libjvm/libjli 引用的是 glibc 的旧式 __xstat/__lxstat/__fxstat
 * （aarch64 上 glibc 仍导出，且 struct stat 布局与 musl 一致 ⇒ 直通、忽略版本参数）。
 * 依据：tools/jre8/README.md §2.2（elf_syms.py --gap 的实测缺口）。 */
int __xstat(int ver, const char *path, struct stat *buf)  { (void)ver; return stat(path, buf); }
int __lxstat(int ver, const char *path, struct stat *buf) { (void)ver; return lstat(path, buf); }
int __fxstat(int ver, int fd, struct stat *buf)           { (void)ver; return fstat(fd, buf); }

/* ---------------- glibc 专有的杂项（**JDK 8 专有**） ---------------- */
/* __getpagesize：glibc 对 getpagesize() 的内部名（HotSpot 8 的 os_linux 直接引用） */
int __getpagesize(void) { return (int)sysconf(_SC_PAGESIZE); }
/* __timezone：glibc 里就是 `timezone` 的内部名（JDK 8 的 libjava.so 引用它；JDK 8 源码树里
 * 搜不到显式引用 ⇒ 来自 glibc 头文件层面的名字）。用汇编 `.set` 做**真别名**：shim 里对
 * `timezone` 留一条未定义引用（装载时由 musl 解析），`__timezone` 与它同址 ⇒ 不是副本、不会过期。 */
extern long timezone;
__asm__(".globl __timezone\n.set __timezone, timezone\n");
/* glibc 版本字符串：HotSpot 8 的 os::Linux::libpthread_init() 在 confstr(_CS_GNU_LIBC_VERSION)
 * 不被支持时会调用这两个（musl 不支持该 key ⇒ **必被调用**）。
 * 注意：我们自编的 libjvm 已把该分支 patch 掉（tools/jre8/patches/os_linux-ohos.patch 的 NPTL pin），
 * 这里保留是为了「万一用官方 libjvm / 将来别的件引用」也不缺符号。*/
const char *gnu_get_libc_version(void) { return "2.17"; }
const char *gnu_get_libc_release(void) { return "stable release version 2.17."; }

/* ---------------- stdio：glibc getc() 宏会编成 _IO_getc ---------------- */
int _IO_getc(FILE *fp) { return fgetc(fp); }

/* ---------------- ctype 表：glibc 布局 = 指针指向 [-128,255] 的 384 项表 ---------------- */
#define _ISupper  0x0100
#define _ISlower  0x0200
#define _ISalpha  0x0400
#define _ISdigit  0x0800
#define _ISxdigit 0x1000
#define _ISspace  0x2000
#define _ISprint  0x4000
#define _ISgraph  0x8000
#define _ISblank  0x0001
#define _IScntrl  0x0002
#define _ISpunct  0x0004
#define _ISalnum  0x0008

static unsigned short ctype_b_tab[384];
static int32_t ctype_lower_tab[384];
static int32_t ctype_upper_tab[384];
static const unsigned short *ctype_b_loc;
static const int32_t *ctype_lower_loc;
static const int32_t *ctype_upper_loc;

__attribute__((constructor)) static void meow_compat_init(void) {
    for (int i = 0; i < 384; i++) {
        ctype_b_tab[i] = 0;
        ctype_lower_tab[i] = i - 128;
        ctype_upper_tab[i] = i - 128;
    }
    for (int c = 0; c < 256; c++) {
        unsigned short f = 0;
        if (isupper(c))  f |= _ISupper;
        if (islower(c))  f |= _ISlower;
        if (isalpha(c))  f |= _ISalpha;
        if (isdigit(c))  f |= _ISdigit;
        if (isxdigit(c)) f |= _ISxdigit;
        if (isspace(c))  f |= _ISspace;
        if (isprint(c))  f |= _ISprint;
        if (isgraph(c))  f |= _ISgraph;
        if (isblank(c))  f |= _ISblank;
        if (iscntrl(c))  f |= _IScntrl;
        if (ispunct(c))  f |= _ISpunct;
        if (isalnum(c))  f |= _ISalnum;
        ctype_b_tab[c + 128] = f;
        ctype_lower_tab[c + 128] = tolower(c);
        ctype_upper_tab[c + 128] = toupper(c);
    }
    ctype_b_loc = ctype_b_tab + 128;
    ctype_lower_loc = ctype_lower_tab + 128;
    ctype_upper_loc = ctype_upper_tab + 128;
}
const unsigned short **__ctype_b_loc(void)      { return &ctype_b_loc; }
const int32_t **__ctype_tolower_loc(void)       { return &ctype_lower_loc; }
const int32_t **__ctype_toupper_loc(void)       { return &ctype_upper_loc; }

/* ---------------- 字符串 / 内存别名 ---------------- */
char *__strdup(const char *s) { return strdup(s); }
char *__strtok_r(char *s, const char *delim, char **save) { return strtok_r(s, delim, save); }
void *__rawmemchr(const void *s, int c) {
    const unsigned char *p = (const unsigned char *)s;
    while (*p != (unsigned char)c) p++;
    return (void *)p;
}

/* ---------------- 文件/目录 ---------------- */
ssize_t __getdelim(char **lineptr, size_t *n, int delim, FILE *stream) {
    return getdelim(lineptr, n, delim, stream);
}
int __xmknod(int ver, const char *path, mode_t mode, dev_t *dev) {
    (void)ver;
    return mknod(path, mode, *dev);
}
int __xpg_strerror_r(int errnum, char *buf, size_t buflen) {
    return strerror_r(errnum, buf, buflen);
}

/* ---------------- 线程 / 调度 ---------------- */
int __pthread_key_create(pthread_key_t *key, void (*destr)(void *)) {
    return pthread_key_create(key, destr);
}
void __sched_cpufree(cpu_set_t *set) { free(set); }
int __sigsetjmp(sigjmp_buf env, int savemask) { return sigsetjmp(env, savemask); }

/* ---------------- 数学 ---------------- */
int __isinf(double x)   { return isinf(x); }
int __isnan(double x)   { return isnan(x); }
int __isnanf(float x)   { return isnan(x); }

/* ---------------- 环境 / auxv / 动态加载 ---------------- */
char *secure_getenv(const char *name) { return getenv(name); }
unsigned long __getauxval(unsigned long type) { return getauxval(type); }
int dlinfo(void *handle, int request, void *info) {
    (void)handle; (void)request; (void)info;
    errno = ENOSYS;
    return -1;
}

/* ---------------- 会话记账 / 堆整理：无实质用途，安全空实现 ---------------- */
struct utmpx *getutxent(void) { return NULL; }
void setutxent(void) { }
int malloc_trim(size_t pad) { (void)pad; return 1; }

/* ================= 自编 libjvm（容器 gcc12 / 较新 glibc）额外需要的接口 ================= */

/* 历史别名：glibc 的 __environ / _environ == environ（构造函数期取一次；JVM 期 environ 基本不变） */
extern char **environ;
char **__environ;
char **_environ;

/* glibc >=2.32 单线程标志（0 = 多线程，保守） */
char __libc_single_threaded = 0;

long __sysconf(int name) { return sysconf(name); }

/* C23 版 strto* / scanf 族（glibc 2.38+ 默认启用）→ 映射到经典实现
 * ⚠️ 这一族按**实测缺口**逐个补（不要凭感觉铺全）：本项目的自编 libjvm(JDK 8) 需要
 * `__isoc23_strtoul`（jre26 那套没用到它）。缺哪个补哪个——`verify_symbols.py` 会点名。 */
long               __isoc23_strtol(const char *n, char **e, int b)   { return strtol(n, e, b); }
unsigned long      __isoc23_strtoul(const char *n, char **e, int b)  { return strtoul(n, e, b); }
long long          __isoc23_strtoll(const char *n, char **e, int b)  { return strtoll(n, e, b); }
unsigned long long __isoc23_strtoull(const char *n, char **e, int b) { return strtoull(n, e, b); }
int __isoc23_sscanf(const char *s, const char *f, ...) { va_list ap; va_start(ap, f); int r = vsscanf(s, f, ap); va_end(ap); return r; }
int __isoc23_fscanf(FILE *fp, const char *f, ...) { va_list ap; va_start(ap, f); int r = vfscanf(fp, f, ap); va_end(ap); return r; }
int __isoc23_vsscanf(const char *s, const char *f, va_list ap) { return vsscanf(s, f, ap); }

/* glibc 动态链接器内省；OHOS 无对应 → 未找到 */
int _dl_find_object(void *address, void *result) { (void)address; (void)result; return -1; }

/* glibc 大文件 fcntl 别名（按命令区分是否取第 3 参，避免对无参命令 va_arg 读越界 = UB） */
int fcntl64(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd);
    void *arg = NULL;
    if (cmd != F_GETFD && cmd != F_GETFL) {
        arg = va_arg(ap, void *);
    }
    va_end(ap);
    return fcntl(fd, cmd, arg);
}

/* thread_local 析构注册（静态 libstdc++/libc++abi 需要）；libc 未导出 → 自实现（per-thread LIFO） */
struct meow_tls_dtor { void (*f)(void *); void *o; struct meow_tls_dtor *next; };
static pthread_key_t meow_tls_key;
static pthread_once_t meow_tls_once = PTHREAD_ONCE_INIT;
static void meow_tls_run(void *p) {
    struct meow_tls_dtor *d = (struct meow_tls_dtor *)p;
    while (d) { struct meow_tls_dtor *n = d->next; if (d->f) d->f(d->o); free(d); d = n; }
}
static void meow_tls_make(void) { pthread_key_create(&meow_tls_key, meow_tls_run); }
int __cxa_thread_atexit_impl(void (*func)(void *), void *obj, void *dso_handle) {
    (void)dso_handle;
    pthread_once(&meow_tls_once, meow_tls_make);
    struct meow_tls_dtor *d = (struct meow_tls_dtor *)malloc(sizeof(*d));
    if (!d) return -1;
    d->f = func; d->o = obj;
    d->next = (struct meow_tls_dtor *)pthread_getspecific(meow_tls_key);
    return pthread_setspecific(meow_tls_key, d);
}

__attribute__((constructor)) static void meow_compat_init_environ(void) {
    __environ = environ;
    _environ = environ;
}
