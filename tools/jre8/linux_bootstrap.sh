#!/bin/sh
# 容器内 bootstrap：装原生工具链 + 用宿主已下的 Temurin 8(glibc/aarch64) 当 boot JDK 验证。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre8/linux_bootstrap.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J8="$SHARE/stuffs/research/jdk8"
[ -d "$J8" ] || { echo "找不到挂载: $J8"; exit 2; }

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO=sudo
command -v dnf >/dev/null 2>&1 || { echo "需要 dnf（openEuler）"; exit 2; }

echo "========== 1. 安装原生工具链 =========="
# 基础工具 + JDK8 configure 需要的桌面依赖（libX11/cups/freetype/fontconfig）
# + libstdc++-static（libjvm 用 --with-stdc++lib=static，避免 NEEDED 带 libstdc++/libgcc_s）
$SUDO dnf -y install gcc gcc-c++ make autoconf automake m4 pkgconf-pkg-config \
    zip unzip which file binutils tar python3 perl git curl \
    alsa-lib-devel cups-devel fontconfig-devel freetype-devel \
    libX11-devel libXext-devel libXrender-devel libXtst-devel libXi-devel \
    libXrandr-devel libXinerama-devel libXcursor-devel xorg-x11-proto-devel \
    libXt-devel libXmu-devel libXpm-devel libstdc++-static 2>&1 | tail -12 || { echo "dnf 安装失败"; exit 1; }

echo; echo "========== 2. 复核 =========="
for t in gcc g++ make autoconf m4 unzip file nm; do printf "  %-12s " "$t"; command -v "$t" 2>/dev/null || echo "(缺)"; done
echo "  gcc: $(gcc --version 2>/dev/null | head -1)"

echo; echo "========== 3. 校验 Temurin 8 tar（**不在挂载里解包**）=========="
# 官方件与该 sha256 精确对齐（同 jre26 的做法：先校验）。
# ⚠️ 2026-09-28 实机教训：往 /mnt/linux_share 上解包会一路 "Cannot utime: Permission denied"
#   （挂载不支持 utime）—— 所以**本脚本不解包**；真正的 boot JDK 由 linux_build_jvm.sh
#   解到容器原生 fs 的 $WORK/bootjdk（那里没有这个问题）。
EXP_SHA=57b7ed8af9d48542bb49ff7894448040b17bea0a48b41677d11ecaec6129768d
TAR="$J8/OpenJDK8U-jdk_aarch64_linux_hotspot_8u504b01.tar.gz"
[ -f "$TAR" ] || { echo "  找不到官方 tar: $TAR"; exit 2; }
got=$(sha256sum "$TAR" | cut -d' ' -f1)
[ "$got" = "$EXP_SHA" ] && echo "  sha256 OK" || { echo "  ⚠️ sha256 不符（期望 $EXP_SHA，实得 $got）"; exit 2; }
echo "  tar 顶层: $(tar tzf "$TAR" 2>/dev/null | head -1)"
echo "  解包目标（linux_build_jvm.sh 里）: \$WORK/bootjdk = ${MEOW_WORK:-$HOME/meow-jvm8}/bootjdk"
# 若容器原生 fs 上已有 boot JDK，顺手报一下版本（证明 boot JDK 可用）
WBOOT="${MEOW_WORK:-$HOME/meow-jvm8}/bootjdk"
if [ -x "$WBOOT/bin/java" ]; then
    echo "  已就绪: $WBOOT  →  $("$WBOOT/bin/java" -version 2>&1 | head -1)"
else
    echo "  （尚无）先跑 linux_build_jvm.sh，它会解到原生 fs 并打印 java -version"
fi

echo; echo "========== 4. JDK8 源可用性（挂载的 clone 的 tag，离线） =========="
SRC_REPO="$SHARE/ref/jdk8u"
if [ -d "$SRC_REPO/.git" ] || [ -f "$SRC_REPO/.git" ]; then
    echo "  clone 可见: $SRC_REPO"
    git -C "$SRC_REPO" tag --list "jdk8u504*" 2>/dev/null | sed 's/^/    /'
    echo "  HEAD: $(git -C "$SRC_REPO" rev-parse --short HEAD)"
else
    echo "  找不到 clone: $SRC_REPO"
fi

echo; echo "（boot JDK 就绪后即可跑 linux_build_jvm.sh —— 它会自己取源/打补丁/configure/make hotspot。）"
