#!/bin/sh
# 把「官方 OpenJDK 8(glibc) + JDK8 源 + 自编 glibc libjvm」组装成随包 JRE 集（libs + 数据）。
# 接口与 tools/jre26/rebuild_for_meowcraft.sh 保持一致（同样的 --official-jdk/--jdk-src/--libjvm/--out）。
#
# 产物（<out>/）：
#   *.so   —— 21 个官方件（原地改 .dynstr）+ libc6.so(兼容层) + libjli.so(自编) + libjvm.so(传入→本脚本魔改)
#   home/  —— java.home 数据（OHOS_JAVA_HOME 指向它）：release/bin/java/lib(rt.jar…)/lib/aarch64/jvm.cfg
#
# 用法:
#   rebuild_for_meowcraft.sh --official-jdk <官方JDK8目录> --jdk-src <JDK8源树> \
#       --libjvm <自编 glibc libjvm.so> [--sdk-native <SDK/native>] [--out <目录>]
#   说明：--libjvm 就绪前，可先用官方 jre/lib/aarch64/server/libjvm.so 做 **dry-run**（符号检查会额外
#         报 gnu_get_libc_version/release —— 那两条正是我们要用 NPTL patch 消掉的，见 README §2.3）。
#   **不做 rt.jar 裁剪**：实测官方 rt.jar 里 19898 个条目全是 STORED（未压缩）⇒ gzip 有 3.03x，
#   照搬的数据 tar 仅 30.8 MiB（比现役 JRE 26 的 39.3 MiB 还小）⇒ 没有裁剪的必要（见 README §2.4）。
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
OFF=""; JDKSRC=""; LIBJVM=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --official-jdk) OFF="$2"; shift 2 ;;
        --jdk-src)      JDKSRC="$2"; shift 2 ;;
        --libjvm)       LIBJVM="$2"; shift 2 ;;
        --sdk-native)   SDK="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OFF" ] && [ -n "$JDKSRC" ] && [ -n "$LIBJVM" ] || {
    echo "需要 --official-jdk --jdk-src --libjvm" >&2; exit 2; }
OUT="${OUT:-$PWD/out}"
# JDK 8 的运行时件在 <jdk>/jre（不是 <jdk>/lib）；官方件目录是 jre/lib/aarch64（**一层扁平**）
OARCH="$OFF/jre/lib/aarch64"
[ -d "$OARCH" ] || { echo "官方 JDK 里没有 jre/lib/aarch64/: $OARCH" >&2; exit 2; }
mkdir -p "$OUT"

# 保留的 21 个官方件（**最小可用**；策略与 jre26 对齐：剔除 X11/ALSA/智能卡/工具类）：
#   已删：libawt_xawt + libjawt + libsplashscreen（X11）/ libjsound + libjsoundalsa（ALSA）/
#         libj2pcsc + libj2pkcs11（智能卡）/ libattach + libsaproc + libnpt（诊断工具/SA）/
#         libhprof + libjsdt + libjava_crw_demo（调试/HPROF）。
#   **保留 JDK 8 专有三件**：libsunec（EC/TLS 原生）、libunpack（**Pack200 使能**，legacy Forge 必需）、
#         libjpeg（图像）、libfreetype 用我们自编件替换（tools/freetype）。
#   libjli/libjvm 单独处理（libjli 自编；libjvm 传入=**自编 glibc 件**，本脚本随后魔改）。
OFFICIAL_LIBS="libawt.so libawt_headless.so libdt_socket.so libfontmanager.so libinstrument.so \
libj2gss.so libjaas_unix.so libjava.so libjpeg.so libjdwp.so libjsig.so liblcms.so libmanagement.so \
libmlib_image.so libnet.so libnio.so libsctp.so libsunec.so libunpack.so libverify.so libzip.so"

echo "== 1/4 兼容层 libc6.so =="
export OHOS_SDK_NATIVE="$SDK"   # build_shim.sh 读此 env（--sdk-native 由此传递）
sh "$HERE/build_shim.sh" "$OUT/libc6.so"

echo "== 2/4 自编 libjli.so =="
if ! grep -q "meow OHOS patch" "$JDKSRC/jdk/src/solaris/bin/java_md_solinux.c" 2>/dev/null; then
    echo "  应用 patches/libjli-ohos.patch"
    (cd "$JDKSRC" && git apply "$HERE/patches/libjli-ohos.patch")
fi
sh "$HERE/build_libjli_ohos.sh" --src "$JDKSRC" --sdk-native "$SDK" --out "$OUT/libjli.so"

echo "== 3/4 官方件原地改 .dynstr + 装入 libjvm =="
# shellcheck disable=SC2086
sh "$HERE/assemble_jre.sh" "$OARCH" "$OUT" "$OUT/libc6.so" $OFFICIAL_LIBS
# libfreetype：官方件带版本号名，用我们自编件（tools/freetype）替换
cp -f "${MEOW_FREETYPE:-$HERE/../../libs/meowlwjgls/libs/arm64-v8a/libfreetype.so}" "$OUT/libfreetype.so"
cp -f "$LIBJVM" "$OUT/libjvm.so"
python3 "$HERE/patch_dynstr.py" "$OUT/libjvm.so" >/dev/null || { echo "  ✗ libjvm 魔改失败" >&2; exit 1; }
echo "  + libjli.so(自编) + libjvm.so(传入, 已魔改) + libfreetype.so(自编)"

echo "== 4/4 java.home 数据（JDK 8：jre/ 布局）=="
H="$OUT/home"
rm -rf "$H"; mkdir -p "$H/lib"
# release / bin / lib 之外的零散件（security 在 lib 下，见下）
for f in release; do [ -e "$OFF/$f" ] && cp -a "$OFF/$f" "$H/"; done
[ -e "$OFF/jre/bin" ] || { echo "  ✗ 官方 JDK 缺 jre/bin" >&2; exit 2; }
mkdir -p "$H/bin" && cp -a "$OFF/jre/bin/java" "$H/bin/java"   # 只留 java：JavaEnvScanner 以 <jreHome>/bin/java 作就绪标记
cp -a "$OFF/jre/lib/." "$H/lib/"
# el1 已承载所有 .so ⇒ 数据侧一个 .so 都不留（jvm.cfg 保留：GetJREPath 出来的 jrepath 要读它）
NSO=$(find "$H/lib" -name '*.so' | wc -l | tr -d ' ')
find "$H/lib" -name '*.so' -delete
echo "  el1 已接管 $NSO 个 .so（数据侧不留）"
rm -rf "$H/lib/server" "$H/lib/jli"
# 明确丢弃的（jre26 亦然）：jexec 启动器、applet 支持、java.home 里不参与运行的诊断/工具件
rm -rf "$H/lib/jexec" "$H/lib/applet" "$H/lib/management-agent.jar" "$H/lib/jfr" "$H/lib/jfr.jar"
echo "  home 体积: $(du -sh "$H" | cut -f1)（$(find "$H" -type f | wc -l) 文件）"

echo "== 校验（**重定位口径**：只认加载器真正要求的符号）=="
python3 "$HERE/verify_symbols.py" "$OUT" --libc "$SDK/sysroot/usr/lib/aarch64-linux-ohos/libc.so" \
    --extra "$SDK/sysroot/usr/lib/aarch64-linux-ohos/libz.so" \
    --extra "$SDK/llvm/lib/aarch64-linux-ohos/libc++_shared.so" \
    --extra "$OUT/libfreetype.so"

cat <<EOF

完成 -> $OUT
随包步骤（工程内）：
  1) 用 $OUT/*.so 铺进 libs/meowjrelegacy/libs/arm64-v8a/（模块名**版本中性**，见 多JRE共存-方案.md §3）
  2) python3 $HERE/pack_jre_data.py --home $OUT/home --out <rawfile>/meow_jre8.tar.gz
  3) rm -rf libs/meowjrelegacy/build entry/build && devecocli build --modules entry meowjrelegacy
  4) 先装 HSP 再装 HAP（改 JRE 后需卸载/清数据以重解压）
EOF
