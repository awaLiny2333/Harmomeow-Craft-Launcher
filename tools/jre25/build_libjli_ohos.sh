#!/bin/sh
# 自编 OHOS(musl) 版 libjli —— 独立编译，路径全参数化，无 boot JDK 依赖。
# 源：OpenJDK 25 源树（已含 patches/libjli-ohos.patch 的 OHOS 分体改动）。
# 用法:
#   build_libjli_ohos.sh --src <JDK源树> [--sdk-native <SDK/native>] [--out <libjli.so>]
# SDK 默认 $OHOS_SDK_NATIVE 或 $HOME/devecow/deveco_tools/sdk/default/openharmony/native
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
[ -n "$SRC" ] || { echo "需要 --src <JDK源树>" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"   # 规范化绝对路径：源码路径会编进产物，相对/绝对形式 → 不同字节
OUT="${OUT:-$PWD/libjli.so}"
CLANG="$SDK/llvm/bin/clang"
[ -x "$CLANG" ] || { echo "找不到 clang: $CLANG" >&2; exit 2; }

INC="-I$SRC/src/java.base/share/native/libjli \
-I$SRC/src/java.base/unix/native/libjli \
-I$SRC/src/java.base/share/native/include \
-I$SRC/src/java.base/unix/native/include \
-I$SRC/src/hotspot/share/include \
-I$SRC/src/hotspot/os/posix/include"

# classfile_constants.h 由模板生成（替换类文件版本占位符）；JDK25 major=69, minor=0
GEN="$(cd "$(dirname "$OUT")" && pwd)/gen"
mkdir -p "$GEN"
sed -e 's/@@VERSION_CLASSFILE_MAJOR@@/69/' -e 's/@@VERSION_CLASSFILE_MINOR@@/0/' \
    "$SRC/src/java.base/share/native/include/classfile_constants.h.template" > "$GEN/classfile_constants.h"
INC="-I$GEN $INC"

DEFS="-D_GNU_SOURCE -DMUSL_LIBC -D_FILE_OFFSET_BITS=64 -DLINUX \
-DJDK_MAJOR_VERSION=25 -DJDK_MINOR_VERSION=0 -DJDK_MICRO_VERSION=0 -DJDK_UPDATE_VERSION=0"

SRCS="$SRC/src/java.base/share/native/libjli/args.c \
$SRC/src/java.base/share/native/libjli/java.c \
$SRC/src/java.base/share/native/libjli/jli_util.c \
$SRC/src/java.base/share/native/libjli/link_type.c \
$SRC/src/java.base/share/native/libjli/parse_manifest.c \
$SRC/src/java.base/share/native/libjli/splashscreen_stubs.c \
$SRC/src/java.base/share/native/libjli/wildcard.c \
$SRC/src/java.base/unix/native/libjli/java_md.c \
$SRC/src/java.base/unix/native/libjli/java_md_common.c"

# shellcheck disable=SC2086
"$CLANG" \
  --target=aarch64-unknown-linux-ohos \
  --sysroot="$SDK/sysroot" \
  -O2 -fPIC -fvisibility=default \
  -shared -Wl,-soname,libjli.so -Wl,--build-id=none \
  $INC $DEFS \
  -o "$OUT" $SRCS \
  -lz

echo "built: $OUT"
