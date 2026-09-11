/**
 * Meowcraft native asset helpers declarations (libmeowassets.so).
 *
 * ArkTS imports:  import native from 'libmeowassets.so';
 *
 * 注意：本 so 只承载 JRE 数据安装 / rawfile tar 解压工具。
 * JVM 启动与渲染由 jrelib HSP（libmeowjrebridge.so / libmeowcraftbridge.so）负责，
 * 入口侧不再保留 GL 渲染与 JLI 直启逻辑（历史死代码已清理）。
 */

/**
 * Install the bundled JRE data for `jreId` (rawfile "<jreId>.tar.gz") into
 * <filesDir>/meow-jres/<jreId> (meow-jres = JRE data root, sibling of meow-home).
 * @param resourceManager context.resourceManager.
 * @param filesDir context.filesDir.
 * @param jreId JRE id / install dir name / rawfile prefix (e.g. "meow_jre25").
 * @returns true when installed / already present.
 */
export const installJre: (resourceManager: object, filesDir: string, jreId: string) => boolean;

/**
 * Extract a bundled rawfile tar.gz into a sandbox dir.
 * @param resourceManager context.resourceManager.
 * @param assetName rawfile file name (e.g. "meowcraft_extras.tar.gz").
 * @param destDir absolute sandbox dir to extract into.
 * @returns true on success.
 */
export const extractRawTar: (resourceManager: object, assetName: string, destDir: string) => boolean;

/**
 * 本机在线 CPU 核数（sysconf(_SC_NPROCESSORS_ONLN)）。ArkTS 无公开 API，故走 native。
 * 供高级选项显示，并作为 CPU 线程数手动值的参考。
 */
export const getCpuCount: () => number;

