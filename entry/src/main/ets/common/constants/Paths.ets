/**
 * 文件系统路径与随包资产名（ArkTS 侧唯一来源）。
 *
 * 与 native 镜像保持同值：`entry/src/main/cpp/meowassets/jre_launcher.h`
 * （kJresRoot/kInstallDir/kAssetName）与 `meowjrebridge.cpp`（缺省回退）。
 * ArkTS/native 无法共享头文件，故 native 侧保留同值字面量 + 交叉引用注释。
 */

/** JRE 数据根目录（filesDir 下，多版本并存）。 */
export const JRES_ROOT: string = 'meow-jres';

/** 内置 JRE id（= 安装目录名 = rawfile 名前缀）。 */
export const JRE_ID_MEOW25: string = 'meow_jre25';

/** 启动器 home（账户 / 运行数据），与 JRE 数据同级。 */
export const MEOW_HOME_DIR: string = 'meow-home';

/** 版本 jar 平铺目录（cacheDir 下）。 */
export const MC_CP_DIR: string = 'mc-cp';

/** 运行目录前缀（cacheDir 下，后接 versionId）。 */
export const MC_RUN_DIR_PREFIX: string = 'mc-run-';

/** natives 子目录名（JNA 解压 / java.library.path 兜底）。 */
export const NATIVES_DIR: string = 'natives';

/** 版本层目录名（.minecraft 下，每个子目录 = 一个版本实例）。 */
export const MC_VERSIONS_DIR: string = 'versions';

/** 共享库目录名（Maven 布局，.minecraft 下，跨版本共享）。 */
export const MC_LIBRARIES_DIR: string = 'libraries';

/** 资源目录名（.minecraft 下，跨版本共享）。 */
export const MC_ASSETS_DIR: string = 'assets';

/** 资源索引子目录名（assets/ 下）。 */
export const MC_ASSETS_INDEXES_DIR: string = 'indexes';

/** 资源对象子目录名（assets/ 下，内容寻址）。 */
export const MC_ASSETS_OBJECTS_DIR: string = 'objects';

/** 资源对象子目录前缀长度（取 hash 前 N 位作为二级目录名，官方约定为 2）。 */
export const ASSET_HASH_PREFIX_LENGTH: number = 2;

/** 下载中临时文件后缀（同目录下 .part，完成后 rename 为正式名）。 */
export const DOWNLOAD_PART_SUFFIX: string = '.part';

/** JRE HSP 模块名（打包契约，与 build-profile.json5 一致）。 */
export const HSP_MEOWJRE25: string = 'meowjre25';

/** HSP 内 native libs 子路径（打包契约）。 */
export const HSP_LIBS_SUBPATH: string = 'libs/arm64';

/** 内置 JRE 数据 rawfile 名（契约：须与 resources/rawfile 下文件同名）。 */
export const RAWFILE_MEOW_JRE: string = 'meow_jre25.tar.gz';

/** 启动支持 jar 载体 rawfile 名。 */
export const RAWFILE_MEOWCRAFT_EXTRAS: string = 'meowcraft_extras.tar.gz';

/** oshi 覆盖件目录（rawfile 下，内含各版本 patched oshi-core jar + manifest.txt）。 */
export const RAWFILE_OSHI_DIR: string = 'oshi-overrides';

/** oshi 覆盖清单（每行 `<staged jar>=<覆盖件 jar>`）。 */
export const RAWFILE_OSHI_MANIFEST: string = 'oshi-overrides/manifest.txt';

/** staging 完成标记文件名。 */
export const MEOWCRAFT_EXTRAS_DONE: string = 'meowcraft_extras.done';

/** <filesDir>/meow-jres/<id>（java.home 数据目录）。 */
export function jreHomeDir(filesDir: string, id: string = JRE_ID_MEOW25): string {
  return `${filesDir}/${JRES_ROOT}/${id}`;
}

/** <bundleCodeDir>/meowjre25/libs/arm64（JRE/桥 el1 native libs）。 */
export function hspLibsDir(bundleCodeDir: string): string {
  return `${bundleCodeDir}/${HSP_MEOWJRE25}/${HSP_LIBS_SUBPATH}`;
}

/**
 * `<gameRoot>/versions/<versionId>`（版本实例目录）。
 * 启用版本隔离时它就是游戏运行目录（MC 的 `--gameDir`），存档/选项/日志落在版本目录内，
 * 与其它版本互不干扰；assets/libraries 仍留在 gameRoot 下共享（与 HMCL/PCL/HomoLauncher 同构）。
 */
export function versionDir(gameRoot: string, versionId: string): string {
  return `${gameRoot}/${MC_VERSIONS_DIR}/${versionId}`;
}

/** `<gameRoot>/versions/<id>/<id>.json`（版本清单文件）。 */
export function versionJsonPath(gameRoot: string, versionId: string): string {
  return `${versionDir(gameRoot, versionId)}/${versionId}.json`;
}

/** `<gameRoot>/versions/<id>/<id>.jar`（client jar 文件）。 */
export function versionJarPath(gameRoot: string, versionId: string): string {
  return `${versionDir(gameRoot, versionId)}/${versionId}.jar`;
}

/** `<gameRoot>/libraries`（共享库根）。 */
export function librariesDir(gameRoot: string): string {
  return `${gameRoot}/${MC_LIBRARIES_DIR}`;
}

/** `<gameRoot>/assets`（共享资源根）。 */
export function assetsDir(gameRoot: string): string {
  return `${gameRoot}/${MC_ASSETS_DIR}`;
}

/** `<gameRoot>/assets/indexes`（资源索引目录）。 */
export function assetsIndexesDir(gameRoot: string): string {
  return `${assetsDir(gameRoot)}/${MC_ASSETS_INDEXES_DIR}`;
}

/** `<gameRoot>/assets/objects/<前2位>/<hash>`（某个资源对象的目标路径）。 */
export function assetObjectPath(gameRoot: string, hash: string): string {
  const prefix = hash.substring(0, ASSET_HASH_PREFIX_LENGTH);
  return `${assetsDir(gameRoot)}/${MC_ASSETS_OBJECTS_DIR}/${prefix}/${hash}`;
}
