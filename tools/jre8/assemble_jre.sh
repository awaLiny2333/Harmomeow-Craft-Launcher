#!/bin/sh
# 把官方 glibc 构建的 JRE .so 改成 OHOS(musl) 可加载——**不用 patchelf**（避免重排/填充 X）。
#   做法：原地改写 .dynstr 的 NEEDED 名（见 patch_dynstr.py）：
#     libc.so.6 / ld-linux -> libc6.so（兼容层）；pthread/dl/rt/m -> libc.so；z/freetype 去版本号。
#   依据：glibc 特有缺失符号由 libc6.so 提供；libc6.so 自身依赖 musl libc.so（自动入全局作用域）。
# 用法: assemble_jre.sh <官方lib目录> <输出目录> <libc6.so> [lib1 lib2 ...]
set -e
SRC="$1"; DST="$2"; SHIM="$3"; shift 3
[ -n "$SRC" ] && [ -n "$DST" ] && [ -n "$SHIM" ] || { echo "用法: $0 <srcLibDir> <dstLibDir> <libc6.so> [libs...]"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$DST"

[ $# -gt 0 ] || set -- $(cd "$SRC" && ls lib*.so)
for name in "$@"; do
    [ -f "$SRC/$name" ] || { echo "  ✗ 缺失官方件: $SRC/$name（清单与实际不符，硬错）" >&2; exit 2; }
    base=$(basename "$name")
    cp -f "$SRC/$name" "$DST/$base"
    python3 "$HERE/patch_dynstr.py" "$DST/$base"
done
[ "$SHIM" = "$DST/libc6.so" ] || cp -f "$SHIM" "$DST/libc6.so"
echo "  + libc6.so (兼容层)"
echo "done -> $DST"
