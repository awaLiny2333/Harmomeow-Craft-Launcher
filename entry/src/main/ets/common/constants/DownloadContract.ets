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

/** BMCLAPI 前缀替换表（原版 host + Fabric meta/maven；路径对齐 HMCL）。 */
export const BMCLAPI_REWRITES: UrlRewrite[] = [
  { from: MOJANG_PISTON_META, to: BMCLAPI_ROOT },
  { from: MOJANG_PISTON_DATA, to: BMCLAPI_ROOT },
  { from: MOJANG_LAUNCHERMETA, to: BMCLAPI_ROOT },
  { from: MOJANG_LIBRARIES, to: `${BMCLAPI_ROOT}/libraries/` },
  { from: MOJANG_RESOURCES, to: `${BMCLAPI_ROOT}/assets` },
  { from: FABRIC_META_ROOT, to: `${BMCLAPI_ROOT}/fabric-meta` },
  { from: FABRIC_MAVEN, to: `${BMCLAPI_ROOT}/maven/` },
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
