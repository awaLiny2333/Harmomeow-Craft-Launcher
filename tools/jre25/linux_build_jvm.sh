#!/bin/sh
# 容器内：原生构建 JDK25 的 libjvm.so（aarch64-linux-gnu）。
# 全程用容器原生 fs（$HOME/meow-jvm），只把最终 libjvm.so 拷回共享挂载。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre25/linux_build_jvm.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J25="$SHARE/stuffs/research/jdk25"
WORK="${MEOW_WORK:-$HOME/meow-jvm}"
echo "== SHARE: $SHARE"
echo "== WORK : $WORK"
mkdir -p "$WORK"; cd "$WORK" || exit 2

# 可复现：固定 SOURCE_DATE_EPOCH（= jdk-25-ga 提交时间 2025-08-12T17:15:36Z）
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1755018936}"
echo "== SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"

echo; echo "========== 1) boot JDK（拷到原生 fs 再解包，避开挂载 utime 问题） =========="
if [ ! -x "$WORK/bootjdk/bin/java" ]; then
    mkdir -p "$WORK/bootjdk"
    cp "$J25/openjdk-25.0.2_linux-aarch64_bin.tar.gz" "$WORK/bootjdk.tar.gz"
    tar xzf "$WORK/bootjdk.tar.gz" -C "$WORK/bootjdk" --strip-components=1
fi
echo "  java : $("$WORK/bootjdk/bin/java" -version 2>&1 | head -1)"

echo; echo "========== 2) 源码（每次重取干净源码；默认 jdk-25-ga，可用 JDK_TAG 覆盖） =========="
rm -rf "$WORK/src"
# 默认用文档/digests 对应的 jdk-25-ga；如需 jdk-25.0.2+10：联网 + export JDK_TAG=jdk-25.0.2+10（digests 会随之变化）
TAG="${JDK_TAG:-jdk-25-ga}"
if ! git -C "$J25/jdk" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  本地无 $TAG，尝试 fetch"; git -C "$J25/jdk" fetch --depth 1 origin tag "$TAG" 2>/dev/null || true
fi
git -C "$J25/jdk" rev-parse "$TAG" >/dev/null 2>&1 || { echo "  找不到 tag: $TAG"; exit 2; }
echo "  使用 tag: $TAG ($(git -C "$J25/jdk" rev-parse --short "$TAG"))"
mkdir -p "$WORK/src"
git -C "$J25/jdk" archive "$TAG" | tar -x -C "$WORK/src"
ls "$WORK/src" | head -3 | sed 's/^/    /'

echo; echo "========== 2.6) 打 HotSpot OHOS 分体补丁 =========="
PATCH="$SHARE/Harmomeow-Craft-Launcher/tools/jre25/patches/os_linux-ohos.patch"
OSL="$WORK/src/src/hotspot/os/linux/os_linux.cpp"
if grep -q "meow OHOS patch" "$OSL" 2>/dev/null; then
    echo "  已打过，跳过"
elif [ -f "$PATCH" ]; then
    ( cd "$WORK/src" && git apply "$PATCH" ) && echo "  已应用: $(basename "$PATCH")"
else
    echo "  ⚠️ 找不到补丁: $PATCH"; exit 2
fi

echo; echo "========== 3) configure（aarch64-linux-gnu 原生） =========="
rm -rf "$WORK/build"; mkdir -p "$WORK/build"; cd "$WORK/build" || exit 2
bash "$WORK/src/configure" \
    --with-boot-jdk="$WORK/bootjdk" \
    --with-conf-name=meow-linux \
    --with-stdc++lib=static \
    --with-native-debug-symbols=none \
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

echo; echo "========== 5) 收 libjvm.so 回共享目录 =========="
LJVM=$(find "$WORK/build" -name libjvm.so | head -1)
echo "  找到: $LJVM"
mkdir -p "$J25/out-linux"
cp -v "$LJVM" "$J25/out-linux/libjvm.so"
echo "  file: $(file "$J25/out-linux/libjvm.so")"
echo "  size: $(ls -la "$J25/out-linux/libjvm.so" | awk '{print $5}')"
echo "== 完成 → $J25/out-linux/libjvm.so（把它贴回/告诉我就行） =="
