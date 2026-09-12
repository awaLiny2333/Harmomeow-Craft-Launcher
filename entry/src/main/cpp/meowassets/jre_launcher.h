/*
 * Meowcraft JRE 数据工具（entry 侧）。
 *
 * 职责（仅此二项）：
 * 1. Install：把随包 rawfile 的 meow_jre25.tar.gz（**官方 JDK25.0.2 数据，jlink 瘦身**，纯
 *    modules/conf 等，无 .so）解压到 <filesDir>/meow-jres/meow_jre25 作为 java.home
 *    （meow-jres 为 JRE 数据根，供未来多版本并存；与 meow-home 同级）；JRE 可执行
 *    .so 全部在 meowjre25 HSP el1 区，由 libmeowjrebridge.so（JLI_Launch）加载，
 *    entry 不直接 dlopen JRE。
 * 2. ExtractRawTar：通用 rawfile tar.gz 解压（staging 启动支持 jar 用）。
 *
 * 历史：早期 entry 直启链（LaunchJava/probeExec）与 GL 预览（egl_render）均已移除。
 */
#ifndef MEOWCRAFT_JRE_LAUNCHER_H
#define MEOWCRAFT_JRE_LAUNCHER_H

#include <string>

namespace jre {

/* JRE data root (multi-version capable). Per-JRE install dir + rawfile name are derived
 * from the jreId ("<jreId>.tar.gz" / "<filesDir>/meow-jres/<jreId>"), so there is no
 * per-JRE literal here. 同值镜像：ArkTS `common/constants/Paths.ets`（JRES_ROOT / JRE_ID_MEOW25）。 */
constexpr char kJresRoot[] = "meow-jres";

/* [数据门] 随包 JRE 数据版本令牌：Install 成功后写入 <installDir>/meow_jre_data。
 * Install 仅在「lib/modules 存在 且 令牌一致」时跳过；否则清目录重解压 →
 * 防止「新 el1 .so + 旧 filesDir 数据」混合。改随包 JRE 数据须同步此值 +
 * ArkTS `common/constants/Paths.ets` 的 JRE_DATA_TOKEN。 */
constexpr char kJreDataToken[] = "25.0.2+10-69-r2";
constexpr char kJreDataTokenFile[] = "meow_jre_data";

/**
 * Install the bundled JRE data for `jreId` under <filesDir>/meow-jres/<jreId> (idempotent).
 * The rawfile asset name is derived as "<jreId>.tar.gz".
 * @param resourceMgr native resource manager for rawfile access.
 * @param filesDir application files dir.
 * @param jreId JRE id / install dir name / rawfile prefix (e.g. "meow_jre25").
 * @return true on success.
 */
bool Install(void* resourceMgr, const std::string& filesDir, const std::string& jreId);

/**
 * Extract a bundled rawfile tar.gz into destDir (mkdir first, idempotent-ish).
 * Used to stage launcher-support jars (lwjgl bridge etc.).
 * @return true on success.
 */
bool ExtractRawTar(void* resourceMgr, const std::string& assetName,
                   const std::string& destDir);

} // namespace jre

#endif // MEOWCRAFT_JRE_LAUNCHER_H
