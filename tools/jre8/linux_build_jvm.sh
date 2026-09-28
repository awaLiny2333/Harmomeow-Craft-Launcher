#!/bin/sh
# 容器内：原生构建 OpenJDK 8 的 libjvm.so（aarch64-linux-gnu）。
# 全程用容器原生 fs（$HOME/meow-jvm8），只把最终 libjvm.so 拷回共享挂载。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre8/linux_build_jvm.sh
#   MEOW_REUSE=1 sh .../linux_build_jvm.sh    # 复用已有 $WORK/{src,build}，只补跑"守卫 + 收件"（不重编译）
# 可覆盖的 env：MEOW_SHARE / MEOW_WORK / JDK_REPO / JDK_TAG / SOURCE_DATE_EPOCH / MEOW_REUSE
#
# 与 tools/jre26/linux_build_jvm.sh 的差异：
#   * boot JDK = **Temurin 8**（JDK 8 只能用 7/8 当 boot JDK，不能用 26 的）
#   * 源 = `openjdk/jdk8u` @ `jdk8u504-b01`（与官方件 release 的 SOURCE 对齐）
#   * **不需要** inject_malloc_slack.py（那是 MC ≥1.21 Flywheel 越界的规避；legacy 段不涉及）
#   * `--with-stdc++lib=static` JDK 8 **也支持**（common/autoconf/libraries.m4:749）
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J8="$SHARE/stuffs/research/jdk8"
JDK_REPO="${JDK_REPO:-$SHARE/ref/jdk8u}"
WORK="${MEOW_WORK:-$HOME/meow-jvm8}"
TAR="$J8/OpenJDK8U-jdk_aarch64_linux_hotspot_8u504b01.tar.gz"
echo "== SHARE: $SHARE"
echo "== REPO : $JDK_REPO"
echo "== WORK : $WORK"
mkdir -p "$WORK"; cd "$WORK" || exit 2

# 可复现：固定 SOURCE_DATE_EPOCH（= jdk8u504-b01 tag 提交时间，2026-08-10T15:44:35Z）
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1786376989}"
echo "== SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"

REUSE="${MEOW_REUSE:-0}"
if [ "$REUSE" = "1" ]; then
    # 只补跑"守卫 + 收件"：用于**守卫本身被修正后**（如 2026-09-28 那次判据误报）免去重编译。
    echo "== MEOW_REUSE=1：跳过 1~4（boot JDK / 取源 / 打补丁 / configure / make），只补跑守卫 + 收件 =="
    [ -d "$WORK/build" ] || { echo "  缺 $WORK/build（没有可复用的构建）"; exit 2; }
    grep -q "meow OHOS patch" "$WORK/src/hotspot/src/os/linux/vm/os_linux.cpp" 2>/dev/null \
        || { echo "  ⚠️ 复用源码里没有我们的补丁（第一遍别用 MEOW_REUSE）"; exit 2; }
    echo "  复用: $WORK/src（已含 OHOS patch） + $WORK/build"
else
echo; echo "========== 1) boot JDK（拷到原生 fs 再解包，避开挂载 utime 问题） =========="
[ -f "$TAR" ] || { echo "  找不到官方 tar: $TAR"; exit 2; }
if [ ! -x "$WORK/bootjdk/bin/java" ]; then
    mkdir -p "$WORK/bootjdk"
    cp "$TAR" "$WORK/bootjdk.tar.gz"
    tar xzf "$WORK/bootjdk.tar.gz" -C "$WORK/bootjdk" --strip-components=1
fi
echo "  java : $("$WORK/bootjdk/bin/java" -version 2>&1 | head -1)"

echo; echo "========== 2) 源码（每次重取干净源码；默认 jdk8u504-b01，可用 JDK_TAG 覆盖） =========="
rm -rf "$WORK/src"
TAG="${JDK_TAG:-jdk8u504-b01}"
if ! git -C "$JDK_REPO" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  本地无 $TAG，尝试 fetch"; git -C "$JDK_REPO" fetch --depth 1 origin tag "$TAG" 2>/dev/null || true
fi
git -C "$JDK_REPO" rev-parse "$TAG" >/dev/null 2>&1 || { echo "  找不到 tag: $TAG"; exit 2; }
echo "  使用 tag: $TAG ($(git -C "$JDK_REPO" rev-parse --short "$TAG^{commit}"))"
mkdir -p "$WORK/src"
git -C "$JDK_REPO" archive "$TAG" | tar -x -C "$WORK/src"
ls "$WORK/src" | head -3 | sed 's/^/    /'

echo; echo "========== 2.6) 打 HotSpot OHOS 分体补丁（含 musl 的 NPTL pin） =========="
PATCH="$SHARE/Harmomeow-Craft-Launcher/tools/jre8/patches/os_linux-ohos.patch"
OSL="$WORK/src/hotspot/src/os/linux/vm/os_linux.cpp"
if grep -q "meow OHOS patch" "$OSL" 2>/dev/null; then
    echo "  已打过，跳过"
elif [ -f "$PATCH" ]; then
    ( cd "$WORK/src" && git apply "$PATCH" ) && echo "  已应用: $(basename "$PATCH")"
else
    echo "  ⚠️ 找不到补丁: $PATCH"; exit 2
fi
grep -c "meow OHOS patch" "$OSL" | sed 's/^/  hunk 命中数: /'

echo; echo "========== 3) configure（aarch64-linux-gnu 原生；JDK 8 的 flags） =========="
rm -rf "$WORK/build"; mkdir -p "$WORK/build"; cd "$WORK/build" || exit 2
# ⚠️ JDK 8 的 configure 选项集与 JDK 9+ **不同**（权威清单：grep AC_ARG_WITH/ENABLE common/autoconf/*.m4）：
#   * **没有** `--disable-warnings-as-errors`（那是 9+ 的）⇒ 带上它会 "Unrecognized option" 直接失败；
#   * `--with-cups` 收的是**前缀目录**（Linux 上 CUPS 必需，传 `system` 会被当路径 /system/include）⇒ **不传**，走自动探测；
#   * `--with-freetype=system` 是合法形式（libraries.m4:299 明写 'system'|'bundled'）；
#   * `--with-stdc++lib=static`、`--with-native-debug-symbols=none`、`--with-debug-level=release` 均在 8 上存在。
bash "$WORK/src/configure" \
    --with-boot-jdk="$WORK/bootjdk" \
    --with-conf-name=meow-linux \
    --with-stdc++lib=static \
    --with-native-debug-symbols=none \
    --with-debug-level=release \
    --with-freetype=system \
    > configure.log 2>&1
rc=$?
echo "  configure rc=$rc"
if [ "$rc" -ne 0 ]; then
    echo ">> 贴回 configure.log 末尾："; tail -30 configure.log
    echo "   （若卡在 cups：加 --with-cups-include=/usr/include；若卡在 -Werror：加"
    echo "     --with-extra-cflags=-Wno-error --with-extra-cxxflags=-Wno-error）"
    exit "$rc"
fi

echo; echo "========== 4) make hotspot（耗时较长，请等） =========="
# JDK 8 的 configure 把 spec.gmk/Makefile 生成在**运行 configure 的目录**（本例 $WORK/build），
# 就在那里 make（前一轮实机已证该目录是对的：能跑到真编译）。
#
# ⚠️ 必须覆盖 `WARNINGS_ARE_ERRORS`：`hotspot/make/linux/makefiles/gcc.make:205` **硬写** `-Werror`，
#   而 gcc 12 对 8u 的老代码有**误报** —— 2026-09-28 实机首跑即卡在
#   `os_cpu/linux_aarch64/vm/orderAccess_linux_aarch64.inline.hpp:78` 的 `__atomic_load_8`：
#   `error: writing 8 bytes into a region of size 0 overflows the destination [-Werror=stringop-overflow=]`
#   （社区里 JDK 8 + 新 gcc 的经典假阳性）。make **命令行变量**优先于 makefile 赋值 ⇒ 置空即可；
#   比 `--with-extra-cflags=-Wno-error` 更外科——只影响 hotspot，且不依赖参数拼接顺序。
#   代价：本次构建的**警告不再致命**（我们靠 §4.5/§4.6 两道守卫 + 真机验收兜底）。
CFGDIR=$(dirname "$(find "$WORK/build" -name spec.gmk 2>/dev/null | head -1)")
echo "  构建目录: ${CFGDIR:-（未找到 spec.gmk）}"
[ -n "$CFGDIR" ] && [ -d "$CFGDIR" ] || { echo "  找不到构建目录（configure 产物缺失）"; exit 2; }
( cd "$CFGDIR" && make hotspot WARNINGS_ARE_ERRORS= ) > make.log 2>&1
rc=$?
echo "  make hotspot rc=$rc"
if [ "$rc" -ne 0 ]; then
    echo ">> 首个 ERROR 附近（make.log）："
    grep -nE "error:|Error [0-9]|\*\*\* |No rule" make.log 2>/dev/null | head -20
    echo ">> 若仍是 -Werror（说明该处 -Werror 不是来自 WARNINGS_ARE_ERRORS）：再补"
    echo "     --with-extra-cflags=-Wno-error --with-extra-cxxflags=-Wno-error 重跑 configure"
    exit "$rc"
fi
echo "  警告统计（仅供参考，不影响收件）：$(grep -c 'warning:' make.log 2>/dev/null) 条"
# 关掉 -Werror 的前提是"我们的改动本身干净" ⇒ 单独看一眼**我们打过补丁的那个文件**有没有新警告
WS=$(grep -nE "os_linux\.cpp:[0-9]+:[0-9]+: warning:" make.log 2>/dev/null | head -5)
if [ -n "$WS" ]; then
    echo "  ⚠️ 我们打过补丁的 hotspot/src/os/linux/vm/os_linux.cpp 有新警告（人工看一眼是否与补丁有关）："
    echo "$WS" | sed 's/^/     /'
else
    echo "  os_linux.cpp（本项目打过补丁的文件）**无警告** ✓"
fi
fi   # ← !MEOW_REUSE：以上 1~4 步（含 make）在 MEOW_REUSE=1 时整体跳过

echo; echo "========== 4.5) 守卫：构建类型必须是 release、且不含非 product 标志 =========="
SPEC=$(find "$WORK/build" -name spec.gmk | head -1)
LVL=$(grep -m1 -E "^DEBUG_LEVEL[[:space:]]*[:=]" "$SPEC" 2>/dev/null | cut -d= -f2 | tr -d ' ')
echo "  构建目录: $SPEC"
echo "  DEBUG_LEVEL=$LVL"
if [ "$LVL" != "release" ]; then
    echo ">> 拒绝收件：DEBUG_LEVEL=$LVL（必须是 release；否则随包 JVM 带断言）"
    exit 3
fi
LJVM_CHECK=$(find "$WORK/build" -name libjvm.so | head -1)
NSYM=0
[ -n "$LJVM_CHECK" ] && NSYM=$(nm "$LJVM_CHECK" 2>/dev/null | wc -l | tr -d ' ')
if [ -z "$LJVM_CHECK" ] || [ "$NSYM" = "0" ]; then
    echo ">> 拒绝收件：产物缺失或符号表不可读（nm 无输出）⇒ 无法判非 product 标志"
    exit 3
fi
# 判据 = JDK 8 `globals.hpp` 里的 **develop/notproduct 标志变量**是否出现：
#   CheckCompressedOops (notproduct, :525) / ZapJNIHandleArea (develop, :871) / VerifyOops (develop, :2886)
#   这些宏在 PRODUCT 下**不编译** ⇒ 符号只存在于非 product 构建。
#   **已校准（2026-09-28，llvm-nm 实测）**：官方 Temurin 8u504 的 libjvm.so 与随包 JRE26 的 libjvm.so
#   上，这三条计数**都是 0**；而下面的宽松模式在**官方 product 件里就有命中**（见 ⚠️）。
# ⚠️ 不要再用 `Metaspace::verify` / `report_assertion_failure` / `check_for_non_bad_heap_word_value`
#   这类"看着像 ASSERT"的模糊模式 —— 官方 product 件里同样存在（实测 `Metaspace::verify*` 2 处、
#   `check_for_non_bad_heap_word_value` 2 处；前者来自 `NOT_DEBUG_RETURN`，product 下也有符号）。
#   2026-09-28 正是 `Metaspace::verify_global_initialization()` 把一个**合格构建**拦下了。
NONPROD=0
for sym in CheckCompressedOops ZapJNIHandleArea VerifyOops; do
    h=$(nm "$LJVM_CHECK" 2>/dev/null | grep -E "^[0-9a-f]+ [BbDd] $sym$" | head -1)
    if [ -n "$h" ]; then
        echo ">> 拒绝收件：含非 product 标志符号 $sym（仍是 develop/断言构建）：$h"
        NONPROD=1
    fi
done
[ "$NONPROD" = "1" ] && exit 3
echo "  产物检查: $(basename "$LJVM_CHECK")（nm 符号 $NSYM 个；三条 develop/notproduct 标志计数均为 0 ⇒ product）"

echo; echo "========== 4.6) 守卫：NEEDED 不得带 libstdc++/libgcc_s（否则 OHOS 上加载不了） =========="
python3 - "$LJVM_CHECK" <<'PY'
import struct, sys
p = sys.argv[1]
data = open(p, 'rb').read()
# 走 PT_DYNAMIC + DT_STRTAB（不依赖 readelf）
e_phoff = struct.unpack_from('<Q', data, 0x20)[0]
e_phentsize = struct.unpack_from('<H', data, 0x36)[0]
e_phnum = struct.unpack_from('<H', data, 0x38)[0]
def v2o(v):
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from('<I', data, off)[0] != 1: continue
        p_off, p_va = struct.unpack_from('<QQ', data, off + 8)
        p_fsz = struct.unpack_from('<Q', data, off + 32)[0]
        if p_va <= v < p_va + p_fsz: return p_off + (v - p_va)
    return None
dyn = None
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    if struct.unpack_from('<I', data, off)[0] == 2:
        dyn = (struct.unpack_from('<Q', data, off + 8)[0], struct.unpack_from('<Q', data, off + 32)[0])
ents = [(struct.unpack_from('<QQ', data, dyn[0] + k * 16)) for k in range(dyn[1] // 16)]
str_va = next((v for t, v in ents if t == 5), None)
str_sz = next((v for t, v in ents if t == 10), None)
base = v2o(str_va)
blob = data[base:base + str_sz]
def s(o):
    return blob[o:blob.index(b'\0', o)].decode()
needed = sorted(s(v) for t, v in ents if t == 1)
print("  NEEDED:", ', '.join(needed) or '(none)')
bad = [n for n in needed if n.startswith(('libstdc++', 'libgcc_s'))]
if bad:
    print(">> 拒绝收件：NEEDED 含 %s（OHOS 没有这些件）" % bad); sys.exit(3)
PY
rc=$?
[ "$rc" -ne 0 ] && exit "$rc"

echo; echo "========== 5) 收 libjvm.so 回共享目录 =========="
LJVM=$(find "$WORK/build" -name libjvm.so | head -1)
echo "  找到: $LJVM"
mkdir -p "$J8/out-linux"
cp -v "$LJVM" "$J8/out-linux/libjvm.so"
echo "  file: $(file "$J8/out-linux/libjvm.so")"
echo "  size: $(ls -la "$J8/out-linux/libjvm.so" | awk '{print $5}')"
echo "== 完成 → $J8/out-linux/libjvm.so =="
echo "   接着在宿主跑：sh tools/jre8/rebuild_for_meowcraft.sh --official-jdk ... --jdk-src ... --libjvm \$J8/out-linux/libjvm.so"
