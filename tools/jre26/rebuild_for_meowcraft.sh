#!/bin/sh
# 把「官方 OpenJDK(glibc) + JDK26 源 + 自编 glibc libjvm」组装成随包 JRE 集（libs + 数据）。
#
# 产物（<out>/）：
#   *.so   —— 26 个官方件（原地改 .dynstr）+ libc6.so(兼容层) + libjli.so(自编) + libjvm.so(传入→本脚本魔改)
#   home/  —— java.home 数据（release/conf/bin/lib 非 .so）；可 --modules-slim 瘦身 + pack_jre_data.py 打包
#
# 用法:
#   rebuild_for_meowcraft.sh --official-jdk <官方JDK目录> --jdk-src <JDK26源树> \
#       --libjvm <自编 glibc libjvm.so> [--modules-slim <modules.slim>] \
#       [--sdk-native <SDK/native>] [--out <目录>]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SDK="${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony/native}"
OFF=""; JDKSRC=""; LIBJVM=""; OUT=""; SLIM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --official-jdk) OFF="$2"; shift 2 ;;
        --jdk-src)      JDKSRC="$2"; shift 2 ;;
        --libjvm)       LIBJVM="$2"; shift 2 ;;
        --modules-slim) SLIM="$2"; shift 2 ;;
        --sdk-native)   SDK="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OFF" ] && [ -n "$JDKSRC" ] && [ -n "$LIBJVM" ] || {
    echo "需要 --official-jdk --jdk-src --libjvm" >&2; exit 2; }
OUT="${OUT:-$PWD/out}"
OLIB="$OFF/lib"
[ -d "$OLIB" ] || { echo "官方 JDK 里没有 lib/: $OLIB" >&2; exit 2; }
mkdir -p "$OUT"

# 保留的 26 个官方 lib（**最小可用**：剔除 MC/JVM 运行不用的件）：
#   已删 libjawt(仅X11)/libawt_xawt/libjsound/libsplashscreen(X11/ALSA)；
#   已删 libj2pkcs11(PKCS#11 智能卡)/libattach(Attach API 工具)/libj2pcsc(PC/SC 智能卡)。
#   libjli/libjvm 单独处理（libjli 自编；libjvm 传入=**自编 glibc 件**，本脚本随后魔改）。
OFFICIAL_LIBS="libawt.so libawt_headless.so libdt_socket.so libextnet.so \
libfontmanager.so libinstrument.so libj2gss.so libjaas.so libjava.so \
libjavajpeg.so libjdwp.so libjimage.so libjsig.so liblcms.so libmanagement.so \
libmanagement_agent.so libmanagement_ext.so libmlib_image.so libnet.so libnio.so \
libprefs.so librmi.so libsctp.so libsyslookup.so libverify.so libzip.so"

echo "== 1/4 兼容层 libc6.so =="
export OHOS_SDK_NATIVE="$SDK"   # build_shim.sh 读此 env（--sdk-native 由此传递）
sh "$HERE/build_shim.sh" "$OUT/libc6.so"

echo "== 2/4 自编 libjli.so =="
if ! grep -q "meow OHOS patch" "$JDKSRC/src/java.base/unix/native/libjli/java_md.c" 2>/dev/null; then
    echo "  应用 patches/libjli-ohos.patch"
    (cd "$JDKSRC" && git apply "$HERE/patches/libjli-ohos.patch")
fi
sh "$HERE/build_libjli_ohos.sh" --src "$JDKSRC" --sdk-native "$SDK" --out "$OUT/libjli.so"
rm -rf "$OUT/gen"   # 编译期生成的 classfile_constants.h，用后即弃

echo "== 3/4 官方件原地改 .dynstr + 装入 libjvm =="
# shellcheck disable=SC2086
sh "$HERE/assemble_jre.sh" "$OLIB" "$OUT" "$OUT/libc6.so" $OFFICIAL_LIBS
cp -f "$LIBJVM" "$OUT/libjvm.so"
python3 "$HERE/patch_dynstr.py" "$OUT/libjvm.so" >/dev/null || { echo "  ✗ libjvm 魔改失败" >&2; exit 1; }   # 自编 libjvm 是 glibc
echo "  + libjli.so(自编) + libjvm.so(传入, 已魔改)"

echo "== 4/4 java.home 数据 =="
mkdir -p "$OUT/home/lib"
for d in release conf bin; do
    [ -e "$OFF/$d" ] || { echo "  ✗ 官方 JDK 缺 $OFF/$d" >&2; exit 2; }
    cp -a "$OFF/$d" "$OUT/home/"
done
cp -a "$OFF/lib/." "$OUT/home/lib/"
rm -f "$OUT/home/lib"/*.so
rm -rf "$OUT/home/lib/server"
rm -f "$OUT/home/lib/src.zip" "$OUT/home/lib/ct.sym"
# 可选瘦身（推荐）：传入 jlink 出的 modules.slim → 换 modules + 裁 bin 到 MC 运行所需
if [ -n "$SLIM" ] && [ -f "$SLIM" ]; then
    cp -f "$SLIM" "$OUT/home/lib/modules"
    # 用 jlink 镜像的 release（MODULES 与实际一致、无 LIBC=gnu）；缺失则保留官方 release
    _REL="$(dirname "$SLIM")/release.slim"
    [ -f "$_REL" ] && cp -f "$_REL" "$OUT/home/release"
    for f in "$OUT/home/bin"/*; do
        case " java keytool jfr jrunscript rmiregistry jwebserver " in
            *" $(basename "$f") "*) ;;
            *) rm -f "$f" ;;
        esac
    done
    echo "  已瘦身: modules<-$(basename "$SLIM"); bin 裁至 $(ls "$OUT/home/bin" | wc -l) 个"
fi

echo "== 校验 =="
python3 "$HERE/verify_symbols.py" "$OUT" --libc "$SDK/sysroot/usr/lib/aarch64-linux-ohos/libc.so" \
    --extra "$SDK/sysroot/usr/lib/aarch64-linux-ohos/libz.so" \
    --extra "$SDK/llvm/lib/aarch64-linux-ohos/libc++_shared.so" \
    --extra "${MEOW_FREETYPE:-$HERE/../../libs/meowlwjgl3/libs/arm64-v8a/libfreetype.so}"

cat <<EOF

完成 -> $OUT
随包步骤（工程内）：
  1) 用 $OUT/*.so 替换 libs/meowjre/libs/arm64-v8a/ 下同名件
  2) 用 pack_jre_data.py 规范化打包 $OUT/home 为 entry/src/main/resources/rawfile/meow_jre.tar.gz
     （python3 $HERE/pack_jre_data.py --home $OUT/home --out <rawfile>/meow_jre.tar.gz）
  3) rm -rf libs/meowjre/build entry/build && devecocli build --modules entry meowjre
  4) 先装 HSP 再装 HAP（改 JRE 后需卸载/清数据以重解压）
EOF
