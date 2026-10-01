/**
 * 文件系统路径与随包资产名（ArkTS 侧唯一来源）。
 *
 * 与 native 镜像保持同值：`entry/src/main/cpp/meowassets/jre_launcher.h`
 * （kJresRoot/kJreDataToken）与 `meowjrebridge.cpp`（缺省回退）。
 * ArkTS/native 无法共享头文件，故 native 侧保留同值字面量 + 交叉引用注释。
 *
 * ⚠️ JRE 命名**版本无关**：模块/JRE id 固定（`meowjre` / `meow_jre`），JRE 版本只由
 * **数据令牌**（JRE_DATA_TOKEN）体现 → 升级时 HSP 原地替换、filesDir 走「须升级」，不产生残留。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/** JRE 数据根目录（filesDir 下）。 */
export const JRES_ROOT: string = 'meow-jres';

/**
 * JRE id（= 安装目录名 = rawfile 名前缀）；**版本无关**，勿带版本号。
 * `JRE_ID_MEOW` = **现代套**（默认）；`JRE_ID_MEOW_LEGACY` = **legacy 套**（OpenJDK 8，
 * 服务 Forge ≤1.12.2 LaunchWrapper / 1.13–1.16 ModLauncher——那些在现代 JDK 上跑不了：
 * JDK 14 删了 `java.util.jar.Pack200`、JDK 24 禁了 SecurityManager）。
 * ⚠️ 这两条只是**字符串常量**；「哪套 JRE 有哪些属性/路径」的**结构性事实**在
 * [`common/data/JavaRuntime.ets`](../data/JavaRuntime.ets) 的表里（单一来源，勿在此另立平行常量）。
 */
export const JRE_ID_MEOW: string = 'meow_jre';
export const JRE_ID_MEOW_LEGACY: string = 'meow_jre_legacy';

/**
 * [数据门] 每 id 的随包 JRE 数据令牌（java.home 数据内容标识）——**逐 id 独立**，勿共用
 * （共用会产出「新 el1 .so + 旧数据」混合）。就绪判断要求解压目录内 `meow_jre_data` == 该 id 的令牌。
 * **改某 id 的随包数据必须同步升该 id 的令牌**；native 侧同值镜像见
 * `entry/src/main/cpp/meowassets/jre_launcher.h::kJreSpecs`。
 */
export const JRE_DATA_TOKEN: string = '26.0.2.1+1-7-r2';
/** legacy 套（OpenJDK 8u504）的数据令牌。 */
export const JRE_DATA_TOKEN_LEGACY: string = '1.8.0_504-b01-r1';

/** JRE 数据令牌文件名（<installDir>/meow_jre_data）。 */
export const JRE_DATA_TOKEN_FILE: string = 'meow_jre_data';

/** 启动器 home（账户 / 运行数据），与 JRE 数据同级。 */
export const MEOW_HOME_DIR: string = 'meow-home';

/** "打开链接"请求文件（native 写、ArkTS 取走；见 GameWindow.pollOpenUrl）。 */
export const OPEN_URL_REQUEST_FILE: string = 'meow-open-url.txt';

/** 应用级设置目录名（filesDir 下）；**唯一来源**，AppSettings.APP_SETTINGS_DIR 引用本常量，不得再写同值字面量。 */
export const MEOW_SETTINGS_DIR: string = 'meow-settings';

/** 触控设置文件名（独立成整份：整份替换即可换一套触控布局）。 */
export const TOUCH_CONTROLS_FILE: string = 'touch-controls.json';

/** 解析失败文件的后缀（原文件改名加此后缀备份，供用户找回手改内容）。 */
export const BAD_FILE_SUFFIX: string = '.bad';

/** 版本 jar 平铺目录（cacheDir 下）。**每实例**的实际目录为 `mc-cp/<key>-<id>`
 *  （`<key>` = gameRoot 短哈希，见 `gameRootKey`；`<id>` = 实例名）—— 按游戏根隔离同名实例。 */
export const MC_CP_DIR: string = 'mc-cp';

/** 运行目录根（cacheDir 下，与 `mc-cp` **对等**的一级目录）。**每实例**的实际目录为
 *  `mc-run/<key>-<id>`（`<key>` = gameRoot 短哈希，见 `gameRootKey`；`<id>` = 实例名）
 *  —— 与 `mc-cp/` 同一分区规则，按游戏根隔离同名实例。 */
export const MC_RUN_DIR: string = 'mc-run';

/** 运行目录内的**兜底日志子目录名**（实际为 `mc-run/<key>-<id>/logs-fallback`）：仅当实例内日志目录
 *  （`<gameRoot>/versions/<id>/.hmmcraft/logs`）**建不出来 / 不可用**时，`-XX:ErrorFile` 的落点兜底。
 *  名字即语义（`logs-fallback` = 兜底日志），与 runDir 其它子目录（`natives/`）平级。 */
export const MC_RUN_LOGS_FALLBACK_SUBDIR: string = 'logs-fallback';

/** 实例沙箱缓存目录名里 gameRoot 短哈希的**长度**（十六进制字符数；见 `gameRootKey`）。 */
export const GAME_ROOT_KEY_LENGTH: number = 8;

/** NeoForge 安装工作目录名（cacheDir 下，实际为 `neo-installer/<loaderSource>/<loaderVersion>`；带源＝切源不静默复用另一源下过的 installer）：installer jar / 解包 / job / mainclass 缓存。 */
export const NEO_INSTALLER_DIR: string = 'neo-installer';

/** Forge 安装工作目录名（cacheDir 下，实际为 `forge-installer/<loaderSource>/<loaderVersion>`；带源同 NeoForge）：installer jar / 解包。 */
export const FORGE_INSTALLER_DIR: string = 'forge-installer';

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

/** JRE HSP 模块名（打包契约，与 build-profile.json5 一致）；**版本无关**。 */
export const HSP_MEOWJRE: string = 'meowjre';
/** legacy 套的 HSP 模块名（打包契约）；**版本无关**（禁把 JRE 版本塞进模块名）。 */
export const HSP_MEOWJRE_LEGACY: string = 'meowjrelegacy';

/** HSP 内 native libs 子路径（打包契约）。 */
export const HSP_LIBS_SUBPATH: string = 'libs/arm64';

/** 启动支持 jar 载体 rawfile 名。 */
export const RAWFILE_MEOWCRAFT_EXTRAS: string = 'meowcraft_extras.tar.gz';

/** oshi 覆盖件目录（rawfile 下，内含各版本 patched oshi-core jar + manifest.txt）。 */
export const RAWFILE_OSHI_DIR: string = 'oshi-overrides';

/** oshi 覆盖清单（每行 `<staged jar>=<覆盖件 jar>`）。 */
export const RAWFILE_OSHI_MANIFEST: string = 'oshi-overrides/manifest.txt';

/** staging 完成标记文件名。 */
export const MEOWCRAFT_EXTRAS_DONE: string = 'meowcraft_extras.done';

/** NeoForge 安装期 headless JVM 的阶段/退出码结果文件（由桥在 headless 模式追加写入）。 */
export const NEO_JVM_RESULT: string = 'meow-neo-jvm-result.txt';

/**
 * 安装期 headless JVM 的**工具 stdio 落盘件**（由桥在 headless 模式把 fd 1/2 收到的每一行
 * 按 `<tag> <line>` 追加写入；见 `meowjrebridge.cpp` 的 pump `emit`）。
 *
 * 为什么需要它：工具（installertools / jarsplitter / SpecialSource / binarypatcher）的异常只在
 * stdout/stderr 上（`Error: Could not find or load main class …` / `Input does not exist …` /
 * `UnsupportedClassVersionError` …），而桥原本只把这两路 pipe 到 **hilog**：hilog 会滚动覆盖、且现场
 * 抓日志常按 tag 过滤 ⇒ 工具为何退 1 **取证不到**（2026-09-30 实机事故：只拿到
 * `installertools:MCP_DATA handshake returned code=1 elapsedMs=501` 一行）。
 * 调用方（`VersionInstaller.runForgeProcessors`）在每次 processor 前清空它、结束后拷到
 * `<workDir>/logs/<label>.log` 并把路径写进失败错误，故安装失败时**不用再抓日志**。
 *
 * 与 `NEO_JVM_RESULT` 同处 `<filesDir>`：两个文件都由 **`:neoinstall` 进程**（同一 App，同一 filesDir）
 * 写、由父进程读，无跨目录授权问题。
 */
export const NEO_JVM_TOOL_LOG: string = 'meow-neo-jvm-tool.log';

/** <filesDir>/meow-jres/<id>（java.home 数据目录）；id **必传**（不设默认，防「忘传 id 静默用现代套」）。 */
export function jreHomeDir(filesDir: string, id: string): string {
  return `${filesDir}/${JRES_ROOT}/${id}`;
}

/** `<filesDir>/meow-settings`（应用级设置目录）。 */
export function meowSettingsDir(filesDir: string): string {
  return `${filesDir}/${MEOW_SETTINGS_DIR}`;
}

/** `<filesDir>/meow-settings/touch-controls.json`（触控设置，整份可替换）。 */
export function touchControlsSettingsPath(filesDir: string): string {
  return `${meowSettingsDir(filesDir)}/${TOUCH_CONTROLS_FILE}`;
}

/** `<filesDir>/meow-settings/touch-controls.json.bad`（解析失败的原文件备份）。 */
export function touchControlsBadPath(filesDir: string): string {
  return `${touchControlsSettingsPath(filesDir)}${BAD_FILE_SUFFIX}`;
}

/** <bundleCodeDir>/<module>/libs/arm64 —— **指定** HSP 模块的 el1 native libs 目录。 */
export function hspLibsDirFor(bundleCodeDir: string, moduleName: string): string {
  return `${bundleCodeDir}/${moduleName}/${HSP_LIBS_SUBPATH}`;
}

/**
 * `<gameRoot>/versions/<versionId>`（版本实例目录）。
 * 启用版本隔离时它就是游戏运行目录（MC 的 `--gameDir`），存档/选项/日志落在版本目录内，
 * 与其它版本互不干扰；assets/libraries 仍留在 gameRoot 下共享（与 HMCL/PCL/HomoLauncher 同构）。
 */
export function versionDir(gameRoot: string, versionId: string): string {
  return `${gameRoot}/${MC_VERSIONS_DIR}/${versionId}`;
}

/**
 * `<gameRootUri>/versions/<versionId>`（实例目录的**用户文件 URI**形式）。
 * 与 versionDir 同一布局，但作用于 Picker 返回的目录 URI（`file://docs/...`）命名空间：
 * 供 `openLink` 在系统文件管理器中打开实例目录（文件管理器是另一个应用，只认该命名空间；
 * 物理路径拼不出能被它解析的 URI）。
 */
export function versionDirUri(gameRootUri: string, versionId: string): string {
  return `${gameRootUri}/${MC_VERSIONS_DIR}/${versionId}`;
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

// ---- 实例沙箱缓存目录（cacheDir 下，`mc-cp/` 与 `mc-run/` 两个对等一级目录，均按游戏根分区）----
// 为什么需要 gameRoot 维度：早期按**实例名**命名的缓存目录（如 `mc-cp/<id>`、`mc-run/<id>`）只含实例名
// ⇒ **同名而不同游戏根**的两个实例会共享同一份 staging/run 目录（实测已发生：同一实例名跑过多个根）。
// 加 gameRoot 短哈希前缀即可隔离；`mc-cp/` 与 `mc-run/` 采用**同一** `<key>-<id>` 分区规则，
// CacheCleaner 只需整棵删除这两个一级目录即可（旧形态孤儿由 CacheCleaner 兜底清扫）。

/**
 * 规范化 gameRoot 路径，供 `gameRootKey` 取哈希（**唯一**规范化口径）。
 *
 * 规则（刻意保守——HarmonyOS 文件系统一般**区分大小写**，故**不**动大小写）：
 *  1. 折叠连续斜杠（`a//b` → `a/b`）；
 *  2. 去尾部斜杠（保留根 `/` 本身）。
 * 不做其它重写（不解析 `.` / `..`、不做 unicode 归一、不降大小写）。
 */
export function normalizeGameRoot(gameRoot: string): string {
  let s = gameRoot.replace(/\/{2,}/g, '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/**
 * gameRoot 的**短哈希 key**（`GAME_ROOT_KEY_LENGTH` 个十六进制字符）。
 *
 * 稳定性依据：**同一路径的任何一次运行都得到同一个 key** —— 输入 = `normalizeGameRoot` 的
 * **确定性**规范化结果 + **纯函数**哈希（SHA-256）；不含时间 / 随机数 / 环境量，故跨进程、跨启动一致。
 * 取字节用 `util.TextEncoder`（UTF-8）⇒ 非 ASCII 路径（如含中文的游戏目录）按**字节**哈希，与字符宽度无关。
 * 失败（理论不可达）退化为一串 `0`，**绝不**返回空串（否则目录名会退化成 `-<id>`，破坏命名规则）。
 */
export function gameRootKey(gameRoot: string): string {
  try {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encodeInto(normalizeGameRoot(gameRoot)) });
    const bytes = new Uint8Array(md.digestSync().data);
    let hex = '';
    for (let i = 0; i < bytes.length; i++) {
      const h = bytes[i].toString(16);
      hex += h.length === 1 ? `0${h}` : h;
    }
    return hex.substring(0, GAME_ROOT_KEY_LENGTH);
  } catch (e) {
    let zeros = '';
    for (let i = 0; i < GAME_ROOT_KEY_LENGTH; i++) {
      zeros += '0';
    }
    return zeros;
  }
}

/**
 * 按实例名命名的沙箱缓存条目的**唯一分区名**：`<key>-<id>`（`<key>` = `gameRootKey(gameRoot)`）。
 * `mc-cp/` 与 `mc-run/` 两个一级目录下都用它做子目录名（同名而不同游戏根 ⇒ 不同子目录）。
 */
export function instanceCacheName(gameRoot: string, versionId: string): string {
  return `${gameRootKey(gameRoot)}-${versionId}`;
}

/** `<cacheDir>/mc-cp`（classpath 平铺根目录）。 */
export function mcCpRoot(cacheDir: string): string {
  return `${cacheDir}/${MC_CP_DIR}`;
}

/** `<cacheDir>/mc-cp/<key>-<id>`（某游戏根下某实例的 classpath 平铺目录）。 */
export function mcCpInstanceDir(cacheDir: string, gameRoot: string, versionId: string): string {
  return `${mcCpRoot(cacheDir)}/${instanceCacheName(gameRoot, versionId)}`;
}

/** `<cacheDir>/mc-run`（运行目录根；与 `mc-cp` 对等的一级目录）。 */
export function mcRunRoot(cacheDir: string): string {
  return `${cacheDir}/${MC_RUN_DIR}`;
}

/** `<cacheDir>/mc-run/<key>-<id>`（某游戏根下某实例的沙箱运行目录；`java.io.tmpdir` / natives 解压）。 */
export function mcRunDir(cacheDir: string, gameRoot: string, versionId: string): string {
  return `${mcRunRoot(cacheDir)}/${instanceCacheName(gameRoot, versionId)}`;
}

/** `<runDir>/logs-fallback`（`-XX:ErrorFile` 的**兜底**目录；首选仍是实例内 `<gameRoot>/versions/<id>/.hmmcraft/logs`）。 */
export function mcRunLogsFallbackDir(runDir: string): string {
  return `${runDir}/${MC_RUN_LOGS_FALLBACK_SUBDIR}`;
}
