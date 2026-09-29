/*
 * Meowcraft JRE 数据工具（entry 侧）。
 *
 * 职责（仅此二项）：
 * 1. Install：把随包 rawfile 的 <jreId>.tar.gz 解压到 <filesDir>/meow-jres/<jreId> 作为 java.home
 *    （meow-jres 为 JRE 数据根）。当前随包**两套**：
 *      - `meow_jre`        = 现代套（官方 OpenJDK 26.0.2.1 数据，jlink 瘦身；模块化 ⇒ 标记 lib/modules）；
 *      - `meow_jre_legacy` = legacy 套（官方 OpenJDK 8u504 数据；rt.jar 布局 ⇒ 标记 lib/rt.jar），
 *        服务 Forge ≤1.12.2（LaunchWrapper）/ 1.13–1.16（ModLauncher）——它们在现代 JDK 上跑不了。
 *    JRE 可执行 .so 全部在对应 HSP 的 el1 区（`meowjre` / `meowjrelegacy`），
 *    由 libmeowjrebridge.so（JLI_Launch）加载，entry 不直接 dlopen JRE。
 *    JRE 命名**版本无关**：版本只体现在**每 id 的数据令牌**（native `kJreSpecs` ↔ ArkTS `BUNDLED_JRES`，
 *    两边同值镜像）。
 * 2. ExtractRawTar：通用 rawfile tar.gz 解压（staging 启动支持 jar 用）。
 *
 * 历史：早期 entry 直启链（LaunchJava/probeExec）与 GL 预览（egl_render）均已移除。
 */
#ifndef MEOWCRAFT_JRE_LAUNCHER_H
#define MEOWCRAFT_JRE_LAUNCHER_H

#include <cstddef>
#include <string>

namespace jre {

/* JRE data root. Per-JRE install dir + rawfile name are derived from the jreId
 * ("<jreId>.tar.gz" / "<filesDir>/meow-jres/<jreId>"), so there is no per-JRE literal here.
 * 同值镜像：ArkTS `common/constants/Paths.ets`（JRES_ROOT / JRE_ID_*）；id **版本无关**（禁把 JRE 版本塞进 id）。 */
constexpr char kJresRoot[] = "meow-jres";

/* [数据门] 随包 JRE **规格表**（native 侧唯一事实源；与 ArkTS
 * `common/constants/Paths.ets::BUNDLED_JRES` **同值镜像**）。
 * 每个 id 自带「数据令牌」与「就绪标记」，两者都**随 JRE 家族不同**：
 *  - 现代套（OpenJDK 26 数据，jlink 瘦身）：模块化 jimage ⇒ 标记 `lib/modules`；
 *  - legacy 套（OpenJDK 8 数据）：rt.jar 布局 ⇒ 标记 `lib/rt.jar`（**根本没有 lib/modules**）。
 * 令牌值形如 `<JDK 版本>+<配方版本>-rN`；**改某 id 的随包数据必须同步升该 id 的令牌**。
 * 就绪判据 = 「就绪标记存在 ∧ <installDir>/meow_jre_data == 该 id 的令牌」，否则清目录重解压
 * ⇒ 防止「新 el1 .so + 旧 filesDir 数据」混合。 */
struct JreSpec {
    const char* id;
    const char* dataToken;
    const char* readyMarker;
};
constexpr JreSpec kJreSpecs[] = {
    { "meow_jre",        "26.0.2.1+1-7-r2",  "lib/modules" },
    { "meow_jre_legacy", "1.8.0_504-b01-r1", "lib/rt.jar" },
};
constexpr size_t kJreSpecsCount = sizeof(kJreSpecs) / sizeof(kJreSpecs[0]);

/* 令牌文件名（<installDir>/meow_jre_data）；**每 id 一份、值不同**。 */
constexpr char kJreDataTokenFile[] = "meow_jre_data";

/* **已废弃** id 白名单：Install 只清理列在这里的 id 的遗留数据目录。
 * ⚠️ **绝不能**改回「清理所有非当前 id」——随包多套 JRE 后那样会在装一套时删掉另一套的数据
 *（notes `多JRE共存-方案.md` §4「P0 危险」）。历次改名/退役的 id 在此登记。 */
constexpr char kRetiredJreIds[][32] = {
    "meowjre25", "meowjre26", "meow_jre8",
};
constexpr size_t kRetiredJreIdsCount = sizeof(kRetiredJreIds) / sizeof(kRetiredJreIds[0]);

/**
 * Install the bundled JRE data for `jreId` under <filesDir>/meow-jres/<jreId> (idempotent).
 * The rawfile asset name is derived as "<jreId>.tar.gz".
 * Also purges data dirs of **retired** JRE ids (kRetiredJreIds whitelist; orphans left over after
 * a bundled-JRE rename). Idempotent, purge failure is non-fatal.
 * @param resourceMgr native resource manager for rawfile access.
 * @param filesDir application files dir.
 * @param jreId JRE id / install dir name / rawfile prefix (e.g. "meow_jre"); must be listed in
 *        kJreSpecs (unknown id → error, we never guess a token/marker).
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
