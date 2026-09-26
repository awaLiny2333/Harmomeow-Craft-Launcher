#!/bin/sh
# 容器内：只做一件事 —— 用官方 JDK26 的 javac 编出**打过 chmod 补丁的 jdk.zipfs 类**。
#
# 走 JDK 官方机制 `--patch-module`（启动时覆盖）：**不动** `lib/modules`(jimage) / **不动**
# `jmods` / **不动任何模块哈希**。产物是 `jdk/nio/zipfs/*.class`（整套包，保证与我们改过的
# `ZipFileSystem` 自洽），随 JRE 数据带上 → 宿主 `rebuild_for_meowcraft.sh --zipfs-patch <dir>`
# 放进 `home/lib/patch/jdk.zipfs/`，启动器加 `--patch-module jdk.zipfs=<JRE数据>/lib/patch/jdk.zipfs`。
# 补丁本体见 `patches/zipfs_chmod_best_effort.py`（`ZipFileSystem.sync()` 里那次
# `Files.setPosixFilePermissions` 变 best-effort —— 手机用户存储(FUSE) 拒绝 chmod 会让 Fabric
# 首次 remap 崩；jar 字节不变）。
#
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre26/linux_build_zipfs_patch.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J26="$SHARE/stuffs/research/jdk26"
WORK="${MEOW_WORK:-$HOME/meow-jvm26}"
HERE=$(cd "$(dirname "$0")" && pwd)

BOOT="$WORK/bootjdk"
[ -x "$BOOT/bin/javac" ] || BOOT="$J26/linux-bootjdk"
[ -x "$BOOT/bin/javac" ] || { echo "找不到 boot JDK(javac): $BOOT"; exit 2; }
echo "boot JDK: $("$BOOT/bin/java" -version 2>&1 | head -1)"

ZSRC="$SHARE/ref/jdk26u/src/jdk.zipfs/share/classes"
[ -f "$ZSRC/module-info.java" ] || { echo "找不到源: $ZSRC"; exit 2; }

W="$J26/zipfs-patch-work"
rm -rf "$W"; mkdir -p "$W/zsrc/jdk.zipfs" "$W/classes"

# 1) 整模块源（14 个 .java，含 module-info.java）到工作副本；只改其一
#    注意：**整模块编**（--module-source-path + -m），否则单编一个文件时 javac 找不到
#    同包的 ZipPath/ZipCoder/...（--patch-module 只提供"类"，不提供源里的同包依赖）。
cp -r "$ZSRC/." "$W/zsrc/jdk.zipfs/"
python3 "$HERE/patches/zipfs_chmod_best_effort.py" "$W/zsrc/jdk.zipfs/jdk/nio/zipfs/ZipFileSystem.java" || exit 3
grep -q "Best-effort" "$W/zsrc/jdk.zipfs/jdk/nio/zipfs/ZipFileSystem.java" || { echo "补丁未落到源"; exit 3; }

# 2) 整模块编译（jdk.zipfs 只依赖 java.*）
"$BOOT/bin/javac" --module-source-path "$W/zsrc" --module-path "$BOOT/jmods" \
        -m jdk.zipfs -d "$W/classes" || { echo "javac 失败"; exit 4; }
[ -f "$W/classes/jdk.zipfs/jdk/nio/zipfs/ZipFileSystem.class" ] || { echo "产物缺失"; exit 4; }

# 3) 交付：整包类（**不含 module-info.class**：--patch-module 的补丁目录不该带模块描述符）
OUT="$J26/out-linux/zipfs-patch"
rm -rf "$OUT"; mkdir -p "$OUT"
cp -r "$W/classes/jdk.zipfs/jdk" "$OUT/"
echo "== 产物 =="
find "$OUT" -type f | sed 's/^/  /'
echo "  classes: $(find "$OUT" -name '*.class' | wc -l)"
sha256sum "$OUT/jdk/nio/zipfs/ZipFileSystem.class" | sed 's/^/  sha256 /'
echo "  -> $OUT"
echo "  宿主侧：sh tools/jre26/rebuild_for_meowcraft.sh ... --zipfs-patch $OUT"
