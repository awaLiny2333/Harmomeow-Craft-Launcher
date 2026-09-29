/**
 * 版本下载外部契约（下载源 / 地址模板 / 校验）。
 *
 * 与启动链路的外部契约（LaunchContract）分开：这里是"从网络抓原版资产"的世界，
 * 启动契约是"怎么把已装好的资产跑起来"的世界。
 *
 * 地址严格对齐 HMCL：官方（Mojang）为默认源，BMCLAPI 为国内镜像；镜像不做单独逻辑，
 * 一律通过"前缀替换表"把官方地址重写为镜像地址（见 bmclapiCandidates）。
 * 这些 host/路径是 Minecraft 启动器生态的既有事实，不在此处臆造。
 */

/** 版本清单相对路径（官方与镜像同路径）。 */
export const MANIFEST_PATH: string = 'mc/game/version_manifest.json';

/** 官方 host：版本清单 / 版本 json / 资源索引。 */
export const MOJANG_PISTON_META: string = 'https://piston-meta.mojang.com';

/** 官方 host：client jar / log4j 配置等对象。 */
export const MOJANG_PISTON_DATA: string = 'https://piston-data.mojang.com';

/** 官方 host：旧版资源索引 / 版本 json 回退。 */
export const MOJANG_LAUNCHERMETA: string = 'https://launchermeta.mojang.com';

/** 官方库仓库（Maven 布局）。 */
export const MOJANG_LIBRARIES: string = 'https://libraries.minecraft.net/';

/** 官方资源对象 host（内容寻址 <前2位>/<hash>）。 */
export const MOJANG_RESOURCES: string = 'https://resources.download.minecraft.net';

/** BMCLAPI 镜像根。 */
export const BMCLAPI_ROOT: string = 'https://bmclapi2.bangbang93.com';

/** 官方版本清单完整地址。 */
export const OFFICIAL_MANIFEST_URL: string = `${MOJANG_PISTON_META}/${MANIFEST_PATH}`;

/** 镜像版本清单完整地址。 */
export const BMCLAPI_MANIFEST_URL: string = `${BMCLAPI_ROOT}/${MANIFEST_PATH}`;

/** 库地址缺省回退仓库（版本 json 未给库 url / downloads 时为它拼 Maven 路径）。 */
export const DEFAULT_LIBRARY_URL: string = MOJANG_LIBRARIES;

/** 旧版资源索引地址模板（版本 json 未给 assetIndex.url 时用）。 */
export const LEGACY_INDEX_URL_PREFIX: string = `${MOJANG_LAUNCHERMETA}/v1/packages/`;

/** 完整性算法：与 Minecraft 生态一致（sha1 十六进制，hash.hash 返回大写）。 */
export const HASH_ALGORITHM: string = 'sha1';

/** 并发下载上限（小文件多，取适中值；http 无并发上限，避免过载）。 */
export const DOWNLOAD_CONCURRENCY: number = 6;

/** HTTP 成功码区间。 */
export const HTTP_STATUS_MIN: number = 200;
export const HTTP_STATUS_MAX: number = 300;

/**
 * 可被当作"有效空结果"的 4xx 码。
 * 用途：Fabric meta 对**不支持**的游戏版本返回 `400` + 空数组 `[]`（而非 404）——
 * 语义是"该版本没有可用 loader"，不是"请求失败"，不应显示为拉取错误。
 */
export const HTTP_STATUS_BAD_REQUEST: number = 400;
export const HTTP_STATUS_NOT_FOUND: number = 404;

/** 连接 / 读取超时（毫秒）。 */
export const HTTP_CONNECT_TIMEOUT: number = 30000;
export const HTTP_READ_TIMEOUT: number = 120000;

/** 当前环境（rules 求值用）：与 JVM 伪装一致（os.name=Linux、os.arch=aarch64、bit=64）。 */
export const ENV_OS_NAME: string = 'linux';
export const ENV_OS_ARCH: string = 'aarch64';
export const ENV_OS_BITS: string = '64';

/** 一条地址前缀替换规则。 */
export interface UrlRewrite {
  from: string;
  to: string;
}

/** Fabric meta 根（loader 列表 / 安装元数据）；无尾斜杠，拼接 `/v2/...`。 */
export const FABRIC_META_ROOT: string = 'https://meta.fabricmc.net';

/** Fabric Maven 仓库（loader/intermediary/asm 等）；带尾斜杠，与库 `url` 字段一致。 */
export const FABRIC_MAVEN: string = 'https://maven.fabricmc.net/';

// ---- NeoForge（mod loader；**仅 1.20.2+**，制品 = net.neoforged:neoforge）----
// 依据：真 installer 实测 + HMCL 实现（见 notes 20-design/launch/NeoForge支持-调研.md §1/§8）。
// 端点边界（实测）：官方 API 只返回**裸版本号**（MC 版本需按版本号规则"破解"）；
// BMCLAPI 走**独立的按 MC 版本查询接口**（不是把官方 URL 换域名）。

/** NeoForge 官方 Maven 根（制品）。 */
export const NEOFORGE_MAVEN_ROOT: string = 'https://maven.neoforged.net';

/** NeoForge 官方 Maven releases 前缀（制品下载；镜像重写针对它）。 */
export const NEOFORGE_RELEASES: string = `${NEOFORGE_MAVEN_ROOT}/releases/`;

/** NeoForge 制品 group 路径（Maven 布局）。 */
export const NEOFORGE_GROUP_PATH: string = 'net/neoforged/neoforge';

/**
 * NeoForge 版本列表 API：返回 `{isSnapshot, versions:[裸版本号]}`。
 * ⚠️ **不要**把它交给镜像重写（BMCLAPI 无该路径）；镜像侧走 {@link neoforgeBmclListUrl} 专用接口。
 */
export const NEOFORGE_VERSION_API: string =
  `${NEOFORGE_MAVEN_ROOT}/api/maven/versions/releases/net/neoforged/neoforge`;

/** BMCLAPI：NeoForge 按 MC 版本列表（返回含 `version` / `mcversion` 的数组）。 */
export function neoforgeBmclListUrl(mcVersion: string): string {
  return `${BMCLAPI_ROOT}/neoforge/list/${mcVersion}`;
}

/** NeoForge installer jar 的官方地址（1.20.2+ 制品；1.20.1 时代的 forge 制品不支持）。 */
export function neoforgeInstallerUrl(loaderVersion: string): string {
  return `${NEOFORGE_RELEASES}${NEOFORGE_GROUP_PATH}/${loaderVersion}/neoforge-${loaderVersion}-installer.jar`;
}

/** installer jar 候选地址（按下载源；镜像 = `{apiRoot}/maven/...`，与 HMCL 一致）。 */
export function neoforgeInstallerCandidates(loaderVersion: string, source: string): string[] {
  return fileCandidates(neoforgeInstallerUrl(loaderVersion), source);
}

/** NeoForge 版本列表的官方候选（唯一一条；不参与镜像重写）。 */
export function neoforgeOfficialListCandidates(): string[] {
  return [NEOFORGE_VERSION_API];
}

// ---- Forge（mod loader；**本次只做 MC 1.7–1.12.2 的零 JVM 安装**）----
// 依据：真 installer 实测（工作区根 stuffs/research/forge-support/evidence/**）+ HMCL 做法对照，见
// notes 20-design/launch/Forge支持-调研.md §3/§11 与 Forge支持-改动方案.md §13（**按格式事实自研，不搬 HMCL 代码**）。
//
// 实测（2026-09-29，14 份真 installer + 官方 `maven-metadata.xml` 的 5054 条目录名）：
// - installer 的 maven 目录名 = **`<mc 版本>-<Forge 构建号>[-<branch>]`**，branch 由列表项给出
//   （1.7.10 / 1.8.9 / 1.9 / 1.9.4 非空，1.10.2–1.12.2 为空）⇒ 名字要按两段拼，**只有一种目录布局**。
// - host 只有一族：`maven.minecraftforge.net` 与旧名 `files.minecraftforge.net/maven` 是同一仓库
//   （样本里库 `url` 全是前者）⇒ 无需照抄「两种布局」。
// - BMCLAPI 的 `/forge/download?...` 专用接口**已失效**（两种写法实测均 404）⇒ 镜像走前缀重写后的
//   `/maven/**`（installer 与 `maven-metadata.xml` 均实测 200）。

/** Forge 官方 Maven 根（installer jar 与 `net.minecraftforge:forge` 制品；带尾斜杠）。 */
export const FORGE_MAVEN: string = 'https://maven.minecraftforge.net/';

/** Forge 制品 group 路径（Maven 布局）。 */
export const FORGE_GROUP_PATH: string = 'net/minecraftforge/forge';

/** BMCLAPI：按 MC 版本的 Forge 列表（返回含 `mcversion` / `version` / `branch` / `files` 的数组）。 */
export function forgeBmclListUrl(mcVersion: string): string {
  return `${BMCLAPI_ROOT}/forge/minecraft/${mcVersion}`;
}

/**
 * Forge 官方 Maven 元数据：`<versions>` 里每一条 `<version>` **就是 installer 的目录名**
 * （即上面那个 `<mc 版本>-<构建号>[-<branch>]`），故它是「目录名」的权威来源 ⇒ 用作官方兜底源。
 * ⚠️ 不采用 HMCL 自托管的 `hmcl.glavo.site/metadata/forge/`（HMCL 专有基础设施，见方案文档 §13.4），
 * 也不用 Forge 的 `promotions_slim.json`：后者只给裸构建号，而 1.7.10/1.8.9/1.9/1.9.4 的真实目录名
 * 还带 `-branch`（裸名目录下没有 installer）⇒ 会拼出 404 的地址。
 */
export const FORGE_MAVEN_METADATA_URL: string = `${FORGE_MAVEN}${FORGE_GROUP_PATH}/maven-metadata.xml`;

/**
 * Forge 官方 `maven-metadata.xml` 的候选地址（按下载源）——与 {@link fabricLoaderListCandidates}
 * 的**降级语义完全一致**（所选源在前、另一源仅"尽力而为"兜底）：
 * - 官方源（SOURCE_OFFICIAL）→ `[官方]`（不碰镜像）；
 * - 镜像源（SOURCE_MIRROR）  → `[BMCLAPI/maven/…, 官方]`（`FORGE_MAVEN` 命中前缀重写表）。
 * 依据 HMCL：列表源与文件源都随用户所选 `DownloadSource` 变化，官方只给官方、镜像给"镜像首选 + 官方兜底"
 * （ref/HMCL `.../setting/DownloadProviders.java:88-97`、`.../download/BMCLAPIDownloadProvider.java:141-171`）。
 */
export function forgeMetadataCandidates(source: string): string[] {
  return fileCandidates(FORGE_MAVEN_METADATA_URL, source);
}

/** Forge installer jar 的官方地址（`classifier = <mc 版本>-<loader 版本号>`）。 */
export function forgeInstallerUrl(mcVersion: string, loaderVersion: string): string {
  const classifier = `${mcVersion}-${loaderVersion}`;
  return `${FORGE_MAVEN}${FORGE_GROUP_PATH}/${classifier}/forge-${classifier}-installer.jar`;
}

/**
 * installer jar 候选地址（按下载源；镜像 = `/maven/**` 前缀重写，与 HMCL 一致）：
 * - 官方源 → `[官方 maven]`（单条，无兜底）；
 * - 镜像源 → `[BMCLAPI/maven/…, 官方 maven]`（镜像优先、官方兜底）。
 * 注意：BMCLAPI 的旧 `/forge/download?...` 专用接口**已失效**（实测 404），镜像一律走前缀重写后的
 * `/maven/**`（见本文件上方的 Forge 段注释与 notes 20-design/launch/Forge支持-调研.md §6）。
 */
export function forgeInstallerCandidates(mcVersion: string, loaderVersion: string,
  source: string): string[] {
  return fileCandidates(forgeInstallerUrl(mcVersion, loaderVersion), source);
}

/** BMCLAPI 前缀替换表（原版 host + Fabric meta/maven + NeoForge/Forge maven；路径对齐 HMCL）。 */
export const BMCLAPI_REWRITES: UrlRewrite[] = [
  { from: MOJANG_PISTON_META, to: BMCLAPI_ROOT },
  { from: MOJANG_PISTON_DATA, to: BMCLAPI_ROOT },
  { from: MOJANG_LAUNCHERMETA, to: BMCLAPI_ROOT },
  { from: MOJANG_LIBRARIES, to: `${BMCLAPI_ROOT}/libraries/` },
  { from: MOJANG_RESOURCES, to: `${BMCLAPI_ROOT}/assets` },
  { from: FABRIC_META_ROOT, to: `${BMCLAPI_ROOT}/fabric-meta` },
  { from: FABRIC_MAVEN, to: `${BMCLAPI_ROOT}/maven/` },
  { from: NEOFORGE_RELEASES, to: `${BMCLAPI_ROOT}/maven/` },
  // Forge 的库 `url` 与 installer 都指向 Forge maven ⇒ 一并入镜像表（实测镜像有 `/maven/**` 全量）。
  { from: FORGE_MAVEN, to: `${BMCLAPI_ROOT}/maven/` },
];

/**
 * 给定官方地址，返回"镜像优先 + 官方兜底"的候选地址列表。
 * 未命中替换表时只返回官方地址本身。
 */
export function candidatesFor(url: string): string[] {
  const out: string[] = [];
  for (const rw of BMCLAPI_REWRITES) {
    if (url.startsWith(rw.from)) {
      out.push(rw.to + url.substring(rw.from.length));
      break;
    }
  }
  out.push(url);
  return out;
}

// ---- 下载源（用户可选，持久化为字符串）----

/** 镜像源：BMCLAPI 优先、官方兜底（默认，国内快）。 */
export const SOURCE_MIRROR: string = 'mirror';

/** 官方源：仅 Mojang（海外）。 */
export const SOURCE_OFFICIAL: string = 'official';

/** 版本清单候选地址（按下载源）。 */
export function manifestCandidates(source: string): string[] {
  return source === SOURCE_OFFICIAL
    ? [OFFICIAL_MANIFEST_URL]
    : [BMCLAPI_MANIFEST_URL, OFFICIAL_MANIFEST_URL];
}

/** 单个文件（client jar / 库 / 资源）的候选地址（按下载源）。 */
export function fileCandidates(url: string, source: string): string[] {
  return source === SOURCE_OFFICIAL ? [url] : candidatesFor(url);
}

/** Fabric loader 列表地址（按游戏版本）；走下载源。 */
export function fabricLoaderListCandidates(gameVersion: string, source: string): string[] {
  return fileCandidates(`${FABRIC_META_ROOT}/v2/versions/loader/${gameVersion}`, source);
}

/** Fabric 单点安装元数据地址（按 游戏版本 + loader 版本）；走下载源。 */
export function fabricLaunchMetaCandidates(gameVersion: string, loaderVersion: string, source: string): string[] {
  return fileCandidates(`${FABRIC_META_ROOT}/v2/versions/loader/${gameVersion}/${loaderVersion}`, source);
}

// ---- 版本类型过滤（清单里 type 字段）----

/** 正式版。 */
export const TYPE_RELEASE: string = 'release';
/** 快照。 */
export const TYPE_SNAPSHOT: string = 'snapshot';
/** 其他（old_beta / old_alpha / 未知）。 */
export const TYPE_OTHER: string = 'other';
