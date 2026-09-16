#!/usr/bin/env python3
"""给 HotSpot 的 `os::malloc` 注入「尾部富余（slack）」——**随包规避，默认全尺寸开**。

背景（2026-09-16，Meowcraft）：`backend/engine/LightDataCollector.write()` 按 **18³** 网格索引
（`x1 + z1*18 + y1*18*18`，最大 5831）写入 `LightStorage.SOLID_SIZE_BYTES + offset`，而光照区只有
`LIGHT_SIZE_BYTES = BLOCKS_PER_SECTION = 4096` 字节 ⇒ **每次光照写最多越过本条 ~1.7KB**。
glibc 桌面靠 malloc 富余侥幸不崩；**OHOS/musl 的紧凑分配会直接砸进相邻的 JVM C 堆对象**
（实测打坏 SymbolTable ⇒ 崩溃，且"反复命中、偶发可恢复、最终致命"）。

**实机 A/B（2026-09-16，单变量）**：`MEOW_MALLOC_SLACK=0` 时 → 4 分钟内两次
`Service Thread @ 0x5d00000008`（HeapBase+8）崩溃；放回后 → 9 分钟 + 7.5 分钟两轮干净 ⇒ 机制坐实。
⇒ 本补丁从"诊断"升格为**随包规避**，构建默认注入（见 `linux_build_jvm.sh` step 2.7）。

**全尺寸**：默认对所有尺寸生效（`MEOW_MALLOC_SLACK_MIN` 默认 0）。曾收窄成"只给 ≥1KB"，但实机在
**加载 16 s** 时仍崩（JVM 自报 `concurrentHashTable.inline.hpp:675 Cannot resize table: Node hash code
has changed`）⇒ 被越界的目标**不限于大块** ⇒ 回到全尺寸。两个旋钮都是**运行时 env**，调参不必重编。

**自证**：`os::malloc` 首次被调用时往 **stderr** 打一行（→ hilog），**不落盘**（铁律：不污染硬盘）。

绕过 NMT 记账 ⇒ 仅 NMT 关闭时使用（NMT/MallocLimit 默认关；用户显式开启时本规避会绕过其记账/限额）。

⚠️ 注入的代码直接调用 `::malloc/::free/::realloc/snprintf`，而 HotSpot 把它们列为 forbidden
（`forbiddenFunctions.hpp`）⇒ 会触发 `-Wdeprecated-declarations`。本配方依赖
`--disable-warnings-as-errors`（`configure` 已显式带），**别删那个 flag**。

用法: inject_malloc_slack.py <hotspot 源根>
"""
import pathlib
import sys

# 幂等标记：只在注入块里出现（`MEOW_MALLOC_SLACK` 这个词在上面的注释里也有，不能用它判）
INJECT_MARK = "#define MEOW_SLACK_MAGIC"

HELPER = r'''
// ================== [meow OHOS] MEOW_MALLOC_SLACK（随包规避，默认全尺寸开）==================
// 见 tools/jre26/inject_malloc_slack.py：给 os::malloc 的分配留尾部富余，吸收上游"略微越界写"
// （Flywheel 光照 18³ 越界 ~1.7KB 会砸进相邻 JVM C 堆对象；实测打坏 SymbolTable）。
// 运行时两个旋钮（**都可在 env 调，不必重编**）：
//   MEOW_MALLOC_SLACK=<bytes>      富余大小，默认 4096；0 = 关闭（A/B 用）
//   MEOW_MALLOC_SLACK_MIN=<bytes>  只对 >= 该值的分配加，默认 0（= 全尺寸；2026-09-16 教训：
//                                  收窄到 1KB 后仍在加载期崩 ⇒ 小分配同样是越界目标）
// 自证：每次进程启动往 stderr 打一行（→ hilog）。**不落盘**（铁律：不污染硬盘）。
// ⚠️ 绕过 NMT/MallocLimit 记账 ⇒ 仅在其关闭时使用（默认关）。
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define MEOW_SLACK_MAGIC   0x4d454f57534c414bULL /* "MEOWSLAK" */
#define MEOW_SLACK_HDR     16     /* 头部只存 magic+total；p-16 对 musl 的指针也恒可读 */
#define MEOW_SLACK_DEFAULT 4096   /* 覆盖 Flywheel 那 ~1.7KB 越界 */

/* 解析 env：非数字/负数/空 ⇒ 用默认值。 */
static long meow_env_long(const char* name, long dflt) {
  const char* e = ::getenv(name);
  if (e == nullptr || e[0] == '\0') { return dflt; }
  char* end = nullptr;
  long v = ::strtol(e, &end, 0);
  if (end == e || v < 0) { return dflt; }
  return v;
}
static long meow_slack_min(void) {
  static long mn = -2;
  if (mn == -2) {
    mn = meow_env_long("MEOW_MALLOC_SLACK_MIN", 0);
    if (mn > (1L << 30)) { mn = (1L << 30); }
  }
  return mn;
}
static size_t meow_slack(void) {
  static long v = -2;
  if (v == -2) {
    long mn = meow_slack_min();
    v = meow_env_long("MEOW_MALLOC_SLACK", (long)MEOW_SLACK_DEFAULT);
    if (v > (1L << 20)) { v = (1L << 20); }
    char msg[160];
    int n = ::snprintf(msg, sizeof(msg),
        "[meow] os::malloc tail slack = %ld B (allocs >= %ld B); env MEOW_MALLOC_SLACK / _MIN override, 0 = off\n",
        v, mn);
    if (n > 0) {
      size_t len = ((size_t)n < sizeof(msg)) ? (size_t)n : (sizeof(msg) - 1);
      ::write(2, msg, len);   /* 只走 stderr（→ hilog），不落盘 */
    }
  }
  return (size_t)v;
}
/* force=0：低于 MEOW_MALLOC_SLACK_MIN 的分配返回 nullptr（走原路径）。
 * force=1：**必须**处理（用于 os::realloc 我们自己的块——不能因为新尺寸低于阈值就报失败）。
 * 返回 nullptr = 该次分配不归我们（调用方继续走原路径）。 */
static void* meow_slack_malloc(size_t size, int force) {
  size_t s = meow_slack();
  if (s == 0) { return nullptr; }
  long mn = meow_slack_min();
  if (!force && mn > 0 && size < (size_t)mn) { return nullptr; }
  if (size > (size_t)-1 - s) { return nullptr; }                 /* size + s 回绕 */
  size_t total = size + s;
  if (total > (size_t)-1 - MEOW_SLACK_HDR) { return nullptr; }   /* + 头部 回绕（否则会静默欠分配）*/
  char* p = (char*)::malloc(total + MEOW_SLACK_HDR);
  if (p == nullptr) { return nullptr; }
  ((size_t*)p)[0] = (size_t)MEOW_SLACK_MAGIC;
  ((size_t*)p)[1] = total;
  return p + MEOW_SLACK_HDR;
}
static bool meow_slack_ours(void* p) {
  if (p == nullptr) { return false; }
  // p-16：对我们自己的块是 magic；对 musl 的块是它自己的 chunk 头（与数据同页，读它安全）。
  return ((size_t*)((char*)p - MEOW_SLACK_HDR))[0] == (size_t)MEOW_SLACK_MAGIC;
}
static size_t meow_slack_total(void* p) {
  return ((size_t*)((char*)p - MEOW_SLACK_HDR))[1];
}
static void meow_slack_free(void* p) {
  ::free((char*)p - MEOW_SLACK_HDR);
}
// =============================================================================
'''


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "src/hotspot")
    os_cpp = root / "share/runtime/os.cpp"
    if not os_cpp.is_file():
        print(f"error: 找不到 {os_cpp}", file=sys.stderr)
        return 2
    s = os_cpp.read_text(encoding="utf-8")
    if INJECT_MARK in s:
        print("  已注入过，跳过")
        return 0

    anchors = [
        ("void* os::malloc(size_t size, MemTag mem_tag) {",
         HELPER + "\nvoid* os::malloc(size_t size, MemTag mem_tag) {"),
        ("""void* os::malloc(size_t size, MemTag mem_tag, const NativeCallStack& stack) {

  // Special handling for NMT preinit phase before arguments are parsed""",
         """void* os::malloc(size_t size, MemTag mem_tag, const NativeCallStack& stack) {
  if (meow_slack() != 0) {
    void* mp = meow_slack_malloc(size, 0);
    if (mp != nullptr) { return mp; }
  }

  // Special handling for NMT preinit phase before arguments are parsed"""),
        ("""void  os::free(void *memblock) {

  // Special handling for NMT preinit phase before arguments are parsed""",
         """void  os::free(void *memblock) {
  if (meow_slack() != 0 && meow_slack_ours(memblock)) { meow_slack_free(memblock); return; }

  // Special handling for NMT preinit phase before arguments are parsed"""),
        ("""void* os::realloc(void *memblock, size_t size, MemTag mem_tag, const NativeCallStack& stack) {

  // Special handling for NMT preinit phase before arguments are parsed""",
         """void* os::realloc(void *memblock, size_t size, MemTag mem_tag, const NativeCallStack& stack) {
  if (meow_slack() != 0 && meow_slack_ours(memblock)) {
    size_t old = meow_slack_total(memblock);
    /* force=1：这是我们自己的块，必须自己处理（低于阈值也不能报 nullptr —— 那会被当成 OOM）。 */
    void* np = meow_slack_malloc(size, 1);
    if (np == nullptr) { return nullptr; }   /* 真 OOM：原块保持有效（realloc 语义） */
    ::memcpy(np, memblock, old < size ? old : size);
    meow_slack_free(memblock);
    return np;
  }

  // Special handling for NMT preinit phase before arguments are parsed"""),
    ]
    for old, new in anchors:
        if s.count(old) != 1:
            print(f"error: 锚点命中 {s.count(old)} 次（应为 1）：{old.splitlines()[0][:60]}", file=sys.stderr)
            return 3
        s = s.replace(old, new, 1)
    # 注入后再确认四条改写都在（防半成品）
    for probe in ("meow_slack_malloc(size, 0)", "meow_slack_malloc(size, 1)",
                  "meow_slack_ours(memblock)", INJECT_MARK):
        if probe not in s:
            print(f"error: 注入后缺少 {probe}", file=sys.stderr)
            return 4
    os_cpp.write_text(s, encoding="utf-8")
    print(f"  已注入 MEOW_MALLOC_SLACK 到 {os_cpp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
