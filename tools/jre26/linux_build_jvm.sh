#!/bin/sh
# 容器内：原生构建 JDK26 的 libjvm.so（aarch64-linux-gnu）。
# 全程用容器原生 fs（$HOME/meow-jvm26），只把最终 libjvm.so 拷回共享挂载。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre26/linux_build_jvm.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J26="$SHARE/stuffs/research/jdk26"
# 源仓：官方 26 更新版在**独立更新仓 jdk26u**（非主线的 jdk-26-ga），用于与官方件精确对齐
JDK_REPO="${JDK_REPO:-$SHARE/ref/jdk26u}"
WORK="${MEOW_WORK:-$HOME/meow-jvm26}"
echo "== SHARE: $SHARE"
echo "== REPO : $JDK_REPO"
echo "== WORK : $WORK"
mkdir -p "$WORK"; cd "$WORK" || exit 2

# 可复现：固定 SOURCE_DATE_EPOCH（= jdk-26.0.2.1-ga 提交时间 2026-07-15T16:36:40Z）
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1784133400}"
echo "== SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"

echo; echo "========== 1) boot JDK（拷到原生 fs 再解包，避开挂载 utime 问题） =========="
if [ ! -x "$WORK/bootjdk/bin/java" ]; then
    mkdir -p "$WORK/bootjdk"
    cp "$J26/openjdk-26.0.2.1_linux-aarch64_bin.tar.gz" "$WORK/bootjdk.tar.gz"
    tar xzf "$WORK/bootjdk.tar.gz" -C "$WORK/bootjdk" --strip-components=1
fi
echo "  java : $("$WORK/bootjdk/bin/java" -version 2>&1 | head -1)"

echo; echo "========== 2) 源码（每次重取干净源码；默认 jdk-26.0.2.1-ga，可用 JDK_TAG 覆盖） =========="
rm -rf "$WORK/src"
# 默认 = 官方 26.0.2.1 件的确切源（release 的 SOURCE=git:d55edf1cba61 == jdk26u 的 jdk-26.0.2.1-ga）
TAG="${JDK_TAG:-jdk-26.0.2.1-ga}"
if ! git -C "$JDK_REPO" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  本地无 $TAG，尝试 fetch"; git -C "$JDK_REPO" fetch --depth 1 origin tag "$TAG" 2>/dev/null || true
fi
git -C "$JDK_REPO" rev-parse "$TAG" >/dev/null 2>&1 || { echo "  找不到 tag: $TAG"; exit 2; }
echo "  使用 tag: $TAG ($(git -C "$JDK_REPO" rev-parse --short "$TAG^{commit}"))"
mkdir -p "$WORK/src"
git -C "$JDK_REPO" archive "$TAG" | tar -x -C "$WORK/src"
ls "$WORK/src" | head -3 | sed 's/^/    /'

echo; echo "========== 2.6) 打 HotSpot OHOS 分体补丁 =========="
PATCH="$SHARE/Harmomeow-Craft-Launcher/tools/jre26/patches/os_linux-ohos.patch"
OSL="$WORK/src/src/hotspot/os/linux/os_linux.cpp"
if grep -q "meow OHOS patch" "$OSL" 2>/dev/null; then
    echo "  已打过，跳过"
elif [ -f "$PATCH" ]; then
    ( cd "$WORK/src" && git apply "$PATCH" ) && echo "  已应用: $(basename "$PATCH")"
else
    echo "  ⚠️ 找不到补丁: $PATCH"; exit 2
fi

echo; echo "========== 2.7) 注入 MEOW_MALLOC_SLACK（随包规避：os::malloc 尾部富余） =========="
# ⚠️ **这不是诊断 patch，是随包规避**：Flywheel 光照 `LightDataCollector.write()` 的 18³ 越界
# （每次写最多越过本条 ~1.7KB）在 OHOS/musl 的紧凑分配下会砸进相邻的 **JVM C 堆对象**
# （实测打坏 SymbolTable ⇒ 复现性崩溃）。实机单变量 A/B（2026-09-16）：关掉 → 4 分钟内两次崩；
# 开着 → 9 分钟干净。理由与阈值详见 `inject_malloc_slack.py` 文档注释。
# 收窄策略：**默认全尺寸生效**（曾收窄为 ≥1KB，实机在加载 16s 仍崩 ⇒ 被越界的目标不限于大块）。
# 自证只在 stderr 打一行（→ hilog，**不落盘**）；要给可离线核对的凭证时才显式设
# `MEOW_MALLOC_SLACK_MARKER=<path>`（铁律：不污染硬盘）。
python3 "$SHARE/Harmomeow-Craft-Launcher/tools/jre26/inject_malloc_slack.py" "$WORK/src/src/hotspot"
IRC=$?
if [ "$IRC" -ne 0 ]; then
    echo ">> 注入失败 rc=$IRC（2=找不到源 3=锚点不匹配 4=注入后半成品）——拒绝继续构建"
    exit "$IRC"
fi

echo; echo "========== 3) configure（aarch64-linux-gnu 原生） =========="
rm -rf "$WORK/build"; mkdir -p "$WORK/build"; cd "$WORK/build" || exit 2
bash "$WORK/src/configure" \
    --with-boot-jdk="$WORK/bootjdk" \
    --with-conf-name=meow-linux \
    --with-stdc++lib=static \
    --with-native-debug-symbols=none \
    --with-debug-level=release \
    --disable-warnings-as-errors \
    > configure.log 2>&1
rc=$?
echo "  configure rc=$rc"
if [ "$rc" -ne 0 ]; then echo ">> 贴回 configure.log 末尾："; tail -20 configure.log; exit "$rc"; fi

echo; echo "========== 4) make hotspot（耗时较长，请等） =========="
make hotspot > make.log 2>&1
rc=$?
echo "  make hotspot rc=$rc"
if [ "$rc" -ne 0 ]; then
    echo ">> 首个 ERROR 附近："
    grep -nE "error:|Error|\*\*\*|No rule" make.log | head -20
    exit "$rc"
fi

echo; echo "========== 4.5) 守卫：确认构建类型是 release =========="
# 目的：防止随包 JVM 变成断言构建（fastdebug/slowdebug）——那种件会跑极少被验证的 assert 路径，
# 且性能/内存都吃亏。注意判据：**只有 ASSERT 专属物**才算证据；
# 2026-09-16 曾把 StressCCP/PrintOptoAssembly 误当 develop（JDK26 里它们是 product+DIAGNOSTIC），
# 据此错判过一次构建类型 ⇒ 见 notes「判 HotSpot 构建类型的正确判据」。
SPEC=$(find "$WORK/build" -name spec.gmk | head -1)
# ⚠️ spec.gmk 是 make 语法：写的是 `DEBUG_LEVEL := release`（冒号等号），**不是** `DEBUG_LEVEL=release`。
# 所以必须同时认 `=` 与 `:=`；但又不能误配 `DEBUG_LEVEL_PDB := …` ⇒ 用 `[[:space:]]*[:=]`。
# （2026-09-16 教训：曾把这里"加固"成只认 `=`，结果 LVL 为空、把好构建拒了。）
LVL=$(grep -m1 -E "^DEBUG_LEVEL[[:space:]]*[:=]" "$SPEC" 2>/dev/null | cut -d= -f2 | tr -d ' ')
echo "  构建目录: $SPEC"
echo "  DEBUG_LEVEL=$LVL"
if [ "$LVL" != "release" ]; then
    echo ">> 拒绝收件：DEBUG_LEVEL=$LVL（必须是 release；否则随包 JVM 带断言）"
    exit 3
fi
# 判据只用**已验证**的 ASSERT 专属物：develop 开关的数据符号（CheckCompressedOops/VerifyOops）
# 与 ASSERT 专属函数（Metaspace::verify / report_assertion_failure / check_for_non_bad_heap_word_value）。
# ⚠️ 别用 StressCCP / PrintOptoAssembly —— JDK26 里它们是 product(...DIAGNOSTIC)，release 也有（会误报）。
LJVM_CHECK=$(find "$WORK/build" -name libjvm.so | head -1)
NSYM=0
if [ -n "$LJVM_CHECK" ]; then
    NSYM=$(nm "$LJVM_CHECK" 2>/dev/null | wc -l | tr -d ' ')
fi
# ⚠️ nm 无输出时**不能**算通过：那可能是产物缺失/被 strip，此时本检查毫无判别力（假安全感）。
# 本配方用 `--with-native-debug-symbols=none` 但符号表仍在（实测 6 万+ 个）⇒ 空表即异常，硬拒。
if [ -z "$LJVM_CHECK" ] || [ "$NSYM" = "0" ]; then
    echo ">> 拒绝收件：产物缺失或符号表不可读（nm 无输出）⇒ 无法判 ASSERT 专属物"
    exit 3
fi
ASSERT_HIT=$(nm "$LJVM_CHECK" 2>/dev/null | grep -E " (CheckCompressedOops|VerifyOops)$" | head -1)
[ -z "$ASSERT_HIT" ] && ASSERT_HIT=$(nm -C "$LJVM_CHECK" 2>/dev/null \
    | grep -E " (VMError::report_assertion_failure|Metaspace::verify|GCHeap::check_for_non_bad_heap_word_value)" | head -1)
if [ -n "$ASSERT_HIT" ]; then
    echo ">> 拒绝收件：$LJVM_CHECK 含 ASSERT 专属符号（仍是断言构建）：$ASSERT_HIT"
    exit 3
fi
echo "  产物检查: $(basename "$LJVM_CHECK")（nm 符号 $NSYM 个；无 ASSERT 专属符号）"

echo; echo "========== 5) 收 libjvm.so 回共享目录 =========="
LJVM=$(find "$WORK/build" -name libjvm.so | head -1)
echo "  找到: $LJVM"
mkdir -p "$J26/out-linux"
cp -v "$LJVM" "$J26/out-linux/libjvm.so"
echo "  file: $(file "$J26/out-linux/libjvm.so")"
echo "  size: $(ls -la "$J26/out-linux/libjvm.so" | awk '{print $5}')"
echo "== 完成 → $J26/out-linux/libjvm.so（把它贴回/告诉我就行） =="
