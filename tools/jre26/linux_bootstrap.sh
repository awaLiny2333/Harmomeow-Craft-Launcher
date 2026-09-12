#!/bin/sh
# 容器内 bootstrap：装原生工具链 + 用宿主自带的官方 JDK26(glibc/aarch64) 当 boot JDK 验证。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre26/linux_bootstrap.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J26="$SHARE/stuffs/research/jdk26"
[ -d "$J26" ] || { echo "找不到挂载: $J26"; exit 2; }

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO=sudo
command -v dnf >/dev/null 2>&1 || { echo "需要 dnf（openEuler）"; exit 2; }

echo "========== 1. 安装原生工具链 =========="
# 基础工具 + configure 需要的桌面依赖 + libstdc++-static（libjvm 必须静态链 stdc++，否则 NEEDED 带 libstdc++/libgcc_s）
$SUDO dnf -y install gcc gcc-c++ make autoconf automake m4 pkgconf-pkg-config \
    zip unzip which file binutils tar python3 perl git curl \
    alsa-lib-devel cups-devel fontconfig-devel freetype-devel \
    libX11-devel libXext-devel libXrender-devel libXtst-devel libXi-devel \
    libXrandr-devel libXinerama-devel libXcursor-devel xorg-x11-proto-devel \
    libXt-devel libXmu-devel libXpm-devel libstdc++-static 2>&1 | tail -12 || { echo "dnf 安装失败"; exit 1; }

echo; echo "========== 2. 复核 =========="
for t in gcc g++ make autoconf m4 unzip file; do printf "  %-12s " "$t"; command -v "$t" 2>/dev/null || echo "(缺)"; done
echo "  gcc: $(gcc --version 2>/dev/null | head -1)"

echo; echo "========== 3. 解官方 JDK26(glibc/aarch64) 当 boot JDK =========="
EXP_SHA=b96b265a4a1a36c02454148891aa58ca63303cbc2d1b7979c33b4fe99e09117b
TAR="$J26/openjdk-26.0.2.1_linux-aarch64_bin.tar.gz"
[ -f "$TAR" ] || { echo "  找不到官方 tar: $TAR"; exit 2; }
got=$(sha256sum "$TAR" | cut -d' ' -f1)
[ "$got" = "$EXP_SHA" ] && echo "  官方 tar sha256 OK" || echo "  ⚠️ 官方 tar sha256 不符（期望 $EXP_SHA，实得 $got）"
BOOT="$J26/linux-bootjdk"
if [ -x "$BOOT/bin/java" ]; then
    echo "  已存在: $BOOT"
else
    mkdir -p "$BOOT"
    tar xzf "$J26/openjdk-26.0.2.1_linux-aarch64_bin.tar.gz" -C "$BOOT" --strip-components=1
fi
echo "  java : $("$BOOT/bin/java" -version 2>&1 | head -1)"
echo "  javac: $("$BOOT/bin/javac" -version 2>&1 | head -1)"
echo "  release: $(grep -E '^JAVA_VERSION=' "$BOOT/release" 2>/dev/null)"

echo; echo "========== 4. JDK26 源可用性（用挂载的 clone 的 tag，离线） =========="
SRC_REPO="$J26/jdk"
if [ -d "$SRC_REPO/.git" ] || [ -f "$SRC_REPO/.git" ]; then
    echo "  clone 可见: $SRC_REPO"
    git -C "$SRC_REPO" tag --list "jdk-26*" 2>/dev/null | tail -5 | sed 's/^/    /'
else
    echo "  找不到 clone: $SRC_REPO"
fi

echo; echo "（把以上输出贴回；下一步我给「取源 → configure → make hotspot」的构建脚本。）"
