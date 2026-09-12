#!/bin/sh
# 容器内：验证自编 libjvm 是否逐字节可复现（3× 干净重建 + cmp）。
# 前置：先跑过 linux_build_jvm.sh（$WORK/src 已取源+打补丁；$WORK/bootjdk 已在）。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre26/linux_verify_jvm_repro.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J26="$SHARE/stuffs/research/jdk26"
WORK="${MEOW_WORK:-$HOME/meow-jvm26}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1770909215}"

[ -d "$WORK/src/src" ] || { echo "缺源码 $WORK/src（先跑 linux_build_jvm.sh）"; exit 2; }
[ -x "$WORK/bootjdk/bin/java" ] || { echo "缺 boot JDK $WORK/bootjdk"; exit 2; }

echo "== SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH  WORK=$WORK"
for i in 1 2 3; do
    echo "---- build #$i ----"
    rm -rf "$WORK/build"; mkdir -p "$WORK/build"; cd "$WORK/build" || exit 2
    bash "$WORK/src/configure" --with-boot-jdk="$WORK/bootjdk" --with-conf-name=meow-linux \
        --with-stdc++lib=static --with-native-debug-symbols=none --disable-warnings-as-errors \
        > "cfg.$i.log" 2>&1 || { echo "configure 失败"; tail -15 "cfg.$i.log"; exit 1; }
    make hotspot > "mk.$i.log" 2>&1 || { echo "make 失败"; grep -nE "error:|\*\*\*" "mk.$i.log" | head; exit 1; }
    _LJ=$(find "$WORK/build" -name libjvm.so | head -1)
    cp "$_LJ" "$WORK/libjvm.$i.so"
    ls -la "$WORK/libjvm.$i.so" | awk '{print "  "$5, $NF}'
done

if cmp -s "$WORK/libjvm.1.so" "$WORK/libjvm.2.so" && cmp -s "$WORK/libjvm.2.so" "$WORK/libjvm.3.so"; then
    echo "✅ libjvm 3× 逐字节一致"
    sha256sum "$WORK/libjvm.1.so" | sed 's/^/  /'
else
    echo "❌ libjvm 3× 不一致："
    cmp "$WORK/libjvm.1.so" "$WORK/libjvm.2.so" | head -3
    echo "  （可尝试：固定 \$WORK 路径、关 BuildID(链接器 --build-id=none)、去 -g；见 README）"
fi
