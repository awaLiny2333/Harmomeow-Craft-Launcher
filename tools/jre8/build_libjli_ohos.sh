#!/bin/sh
# 自编 OHOS(musl) 版 libjli（JDK 8）—— 独立交叉编译，路径全参数化，无 boot JDK 依赖。
# 源：OpenJDK 8u 源树（需已打 patches/libjli-ohos.patch 的 OHOS 分体改动）。
#
# 与 tools/jre26/build_libjli_ohos.sh 的差异（全部来自 JDK 8 的 launcher 布局，见 jdk/make/lib/CoreLibraries.gmk:354-431）：
#   * 源码在 jdk/src/share/bin 与 jdk/src/solaris/bin 两处；**没有** java_md.c（unix 实现在 java_md_solinux.c）
#   * 需要 ergo.c + -DUSE_GENERIC_ERGO（aarch64 没有 ergo_aarch64.c；JDK 9+ 已整体删除 ergo）
#   * classfile_constants.h 是**签入仓库**的（jdk/src/share/javavm/export，major=52）⇒ 无需模板替换
#   * 链接 zlib 用系统的 -lz（官方默认也是 external libz 时同样处理）
# 用法:
#   build_libjli_ohos.sh --src <JDK8源树> [--sdk-native <SDK/native>] [--out <libjli.so>]
set -e

SRC=""
OUT=""
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
while [ $# -gt 0 ]; do
    case "$1" in
        --src)        SRC="$2"; shift 2 ;;
        --out)        OUT="$2"; shift 2 ;;
        --sdk-native) SDK="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done
[ -n "$SRC" ] || { echo "需要 --src <JDK8源树>" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"   # 规范化绝对路径：源码路径会编进产物，相对/绝对形式 → 不同字节
OUT="${OUT:-$PWD/libjli.so}"
CLANG="$SDK/llvm/bin/clang"
[ -x "$CLANG" ] || { echo "找不到 clang: $CLANG" >&2; exit 2; }

J="$SRC/jdk/src"
# jni.h/jvm.h 在 share/javavm/export；jni_md.h/jvm_md.h 在 solaris/javavm/export（JDK 8 的
# unix 平台头目录；JDK 9+ 对应 src/java.base/unix/native/include）
INC="-I$J/share/bin -I$J/solaris/bin -I$J/share/javavm/export -I$J/solaris/javavm/export"

# 官方由 autoconf 给 LIBARCHNAME（common/autoconf/platform.m4:342 取 OPENJDK_TARGET_CPU_JLI）：
# ergo.c / java_md_solinux.c 把它当**字符串字面量**拼接，故必须带引号传（单独成词，见下方 clang 行；
# 放进 $DEFS 会被 shell 的引号移除吃掉引号）。
DEFS="-D_GNU_SOURCE -DMUSL_LIBC -D_FILE_OFFSET_BITS=64 -DLINUX -DUSE_GENERIC_ERGO"

SRCS="$J/share/bin/java.c \
$J/share/bin/splashscreen_stubs.c \
$J/share/bin/parse_manifest.c \
$J/share/bin/version_comp.c \
$J/share/bin/wildcard.c \
$J/share/bin/jli_util.c \
$J/solaris/bin/java_md_common.c \
$J/solaris/bin/java_md_solinux.c \
$J/solaris/bin/ergo.c"

# shellcheck disable=SC2086
"$CLANG" \
  --target=aarch64-unknown-linux-ohos \
  --sysroot="$SDK/sysroot" \
  -O2 -fPIC -fvisibility=default \
  -shared -Wl,-soname,libjli.so -Wl,--build-id=none \
  $INC $DEFS \
  -DLIBARCHNAME='"aarch64"' \
  -o "$OUT" $SRCS \
  -lz

echo "built: $OUT"
