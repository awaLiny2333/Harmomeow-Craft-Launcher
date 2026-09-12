#!/bin/sh
# 容器内：用官方 JDK25 的 jlink，按「原 HOML JRE 的模块集」裁出精简 lib/modules（jimage）。
# 用法（容器内）:
#   sh /mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft/Harmomeow-Craft-Launcher/tools/jre25/linux_slim_jre.sh
set -u
SHARE="${MEOW_SHARE:-/mnt/linux_share/Documents/Meow/Codes/HMOS/HarmonyOS_Projects/HarmonyOS_Projects/Meowcraft}"
J25="$SHARE/stuffs/research/jdk25"
WORK="${MEOW_WORK:-$HOME/meow-jvm}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1755018936}"   # 与 libjvm 一致，固定 jlink 输出

# boot JDK：优先容器原生 fs 里的，否则用挂载的
BOOT="$WORK/bootjdk"
[ -x "$BOOT/bin/jlink" ] || BOOT="$J25/linux-bootjdk"
[ -x "$BOOT/bin/jlink" ] || { echo "找不到 boot JDK(jlink): $BOOT"; exit 2; }
echo "boot JDK: $("$BOOT/bin/java" -version 2>&1 | head -1)"

# 模块集 = 原 HOML JRE 的 MODULES（已知 MC 1.6.x–26.3 可用）；**已剔除 jdk.crypto.cryptoki**
#（其 native libj2pkcs11 已删，保留模块会不一致）
MODS="java.base java.compiler java.datatransfer java.desktop java.instrument java.logging \
java.management java.management.rmi java.naming java.net.http java.prefs java.rmi java.scripting \
java.se java.security.jgss java.security.sasl java.sql java.sql.rowset java.transaction.xa java.xml \
java.xml.crypto jdk.accessibility jdk.charsets jdk.crypto.ec jdk.dynalink \
jdk.httpserver jdk.internal.vm.ci jdk.jdwp.agent jdk.jfr jdk.jsobject jdk.localedata jdk.management \
jdk.management.agent jdk.management.jfr jdk.naming.dns jdk.naming.rmi jdk.net jdk.nio.mapmode jdk.sctp \
jdk.security.auth jdk.security.jgss jdk.unsupported jdk.xml.dom jdk.zipfs"
MODS_CSV=$(echo "$MODS" | tr -s ' ' ',')   # jlink --add-modules 需要逗号分隔

OUT="$J25/out-linux/slim-rt"
rm -rf "$OUT"
"$BOOT/bin/jlink" \
    --module-path "$BOOT/jmods" \
    --add-modules "$MODS_CSV" \
    --no-header-files --no-man-pages --strip-debug \
    --compress=zip-6 \
    --output "$OUT"

echo "== 产物 =="
ls -la "$OUT/lib/modules" | awk '{print "  modules:", $5, "bytes"}'
mkdir -p "$J25/out-linux"
cp -f "$OUT/lib/modules" "$J25/out-linux/modules.slim"
cp -f "$OUT/release" "$J25/out-linux/release.slim"
echo "  -> $J25/out-linux/modules.slim ($(stat -c %s "$J25/out-linux/modules.slim") bytes)"
sha256sum "$J25/out-linux/modules.slim" | sed 's/^/  sha256 /'
echo "（把两行 bytes 贴回即可。）"
