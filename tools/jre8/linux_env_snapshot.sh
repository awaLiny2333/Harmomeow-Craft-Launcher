#!/bin/sh
# 在 openEuler 容器里跑：打印用于构建 libjvm(JDK 8) 的环境精确版本快照（供溯源/一致性核对）。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre8/linux_env_snapshot.sh
set -u
echo "===== 1. 平台 ====="
uname -a
echo "arch: $(uname -m)"
( . /etc/os-release 2>/dev/null && echo "os: $PRETTY_NAME ($VERSION)" ) 2>/dev/null || head -3 /etc/os-release

echo; echo "===== 2. 编译器 / 构建工具 ====="
gcc --version 2>/dev/null | head -1
g++ --version 2>/dev/null | head -1
make --version 2>/dev/null | head -1
autoconf --version 2>/dev/null | head -1
automake --version 2>/dev/null | head -1
m4 --version 2>/dev/null | head -1
ld --version 2>/dev/null | head -1
nm --version 2>/dev/null | head -1
python3 --version 2>/dev/null
perl --version 2>/dev/null | sed -n 2p

echo; echo "===== 3. 关键已装包（含版本） ====="
rpm -q gcc gcc-c++ make autoconf automake m4 binutils glibc libstdc++ libstdc++-static \
      alsa-lib-devel cups-devel fontconfig-devel freetype-devel \
      libX11-devel libXext-devel libXrender-devel libXtst-devel libXi-devel \
      libXrandr-devel libXinerama-devel libXcursor-devel xorg-x11-proto-devel \
      libXt-devel libXmu-devel libXpm-devel 2>&1 | sed 's/^/  /'

echo; echo "===== 4. boot JDK 校验 ====="
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
# boot JDK 在**容器原生 fs**（不往挂载解包：挂载不支持 utime，见 linux_bootstrap.sh 注释）
BOOT="${MEOW_WORK:-$HOME/meow-jvm8}/bootjdk"
if [ -x "$BOOT/bin/java" ]; then
    "$BOOT/bin/java" -version 2>&1 | sed 's/^/  /'
    grep -E '^JAVA_VERSION=' "$BOOT/release" 2>/dev/null | sed 's/^/  /'
else
    echo "  未找到 $BOOT（先跑 linux_build_jvm.sh）"
fi

echo; echo "===== 5. 源码 tag ====="
SRC="$SHARE/ref/jdk8u"
[ -d "$SRC/.git" ] && echo "  ref/jdk8u HEAD: $(git -C "$SRC" rev-parse --short HEAD)  describe: $(git -C "$SRC" describe --tags 2>/dev/null)"

echo; echo "（把以上输出整段贴回 tools/jre8/README.md 的「容器环境快照」段。）"
