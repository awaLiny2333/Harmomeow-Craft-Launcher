#!/bin/sh
# 构建 OHOS musl 兼容层 libc6.so（glibc→musl）
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
CLANG="$SDK/llvm/bin/clang"
OUT="${1:-$HERE/libc6.so}"

# 注意：**不要**加版本脚本。OHOS musl 对「有版本号的导出」会做版本匹配：
#   自编件引用的是较新版本（如 __isoc23_fscanf@GLIBC_2.38），若 shim 导出成 @@GLIBC_2.17 会不匹配 → "symbol not found"。
# 导出为**无版本**符号（与 musl libc 自身一致）→ 任何版本引用都按名字解析。
"$CLANG" \
  --target=aarch64-unknown-linux-ohos \
  --sysroot="$SDK/sysroot" \
  -O2 -fPIC -fvisibility=default -D_GNU_SOURCE \
  -shared -Wl,-soname,libc6.so \
  -Wl,--build-id=none \
  -o "$OUT" "$HERE/glibc_compat.c"

echo "built: $OUT"
