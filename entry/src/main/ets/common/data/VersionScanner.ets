import { fileIo, fileUri } from '@kit.CoreFileKit';
import { resolveVersion } from './VersionResolver';

/**
 * 将 Picker 返回的目录 URI（file://docs/...）转换为可传给 fileIo 的物理路径。
 *
 * 为什么用 fileUri.FileUri 而不是手剥前缀：手写剥掉 file://docs 属于"草台代码"——
 * URI→路径的转换规则是系统约定的，可能随系统演进变化。官方推荐（fs 模块文档引言）：
 * "对于只支持沙箱路径作为入参的接口，可以构造 fileUri 对象并获取其 path 属性
 * 将 URI 转换为沙箱路径"。FileUri 的 path 属性即此系统约定转换，获得的授权 URI 同样适用。
 *
 * 说明：本函数仅在本文件（版本扫描）内使用；游戏启动链路收到的 jsonPath 已是
 * 由此产出的物理路径，不需要再次转换。
 */
function userFileUriToPath(uri: string): string {
  try {
    return new fileUri.FileUri(uri).path;
  } catch {
    // 非法/空 URI：返回空串，调用方据此判无效（避免 new FileUri('') 抛异常冒泡）。
    return '';
  }
}

/**
 * 识别出的游戏版本条目（从 <dir>/versions/<id>/<id>.json 解析出的信息子集）。
 * 普通 class 即可：识别完成后整体替换 versions 数组，无需逐字段观察。
 *
 * 字段说明：id/type 用于展示；mainClass/javaVersion 后续组装启动参数用；
 * jsonPath/releaseTime 供开发调试核对扫描来源。
 */
export class GameVersion {
  /**
   * 实例身份 = `versions/` 下的**目录名**（也是 json 文件名），如 "1.20.1" / "MyPack"。
   * 注意：是目录名，**不是 json 内容里的 `id` 字段**——对齐 HMCL：目录名才是实例身份，
   * 启动/删除/隔离等所有路径都从它派生，故目录名≠json id（重命名/整合包）也不会错。
   */
  id: string;

  /** 版本类型：release / snapshot / old_beta / old_alpha 等。 */
  type: string;

  /** 版本 json 的物理路径，后续启动时可直接复用。 */
  jsonPath: string;

  /** 主类（launch manifest 的 mainClass 字段），拼 JVM 参数用。可能为空。 */
  mainClass: string;

  /** 所需 Java 大版本（javaVersion.majorVersion），决定选哪个 JRE。默认 8。 */
  javaVersion: number;

  /** 版本发布日期（releaseTime），供展示/排序。可能为空。 */
  releaseTime: string;

  /** 加载器：'' / 'fabric' / 'legacy_fabric'（见 VersionResolver.detectLoader）。 */
  loader: string;

  /** 真 MC 版本号（解析继承/补丁后；渲染后端/LWJGL 世代判定用），可能与实例名不同。 */
  mcVersion: string;

  constructor(id: string, type: string, jsonPath: string, mainClass: string, javaVersion: number,
    releaseTime: string, loader: string, mcVersion: string) {
    this.id = id;
    this.type = type;
    this.jsonPath = jsonPath;
    this.mainClass = mainClass;
    this.javaVersion = javaVersion;
    this.releaseTime = releaseTime;
    this.loader = loader;
    this.mcVersion = mcVersion;
  }
}

/**
 * 从版本 json 解析字段。`dirName` = `versions/` 下的目录名（实例身份）。
 * Minecraft 版本 json 结构：
 * { "id", "type", "mainClass", "releaseTime",
 *   "javaVersion": { "majorVersion": 17, ... }, ... }。
 * json 里的 `id` 仅要求存在（把"任意 json"挡在外面），身份一律用 `dirName`；
 * 解析失败/缺 id 时返回 null（该版本目录被跳过）。
 */
function parseVersionJson(gameRoot: string, dirName: string, jsonPath: string): GameVersion | null {
  try {
    const text = fileIo.readTextSync(jsonPath);
    const leaf = JSON.parse(text) as GameVersionJson;
    if ((leaf.id ?? '').length === 0) {
      return null;
    }
    let type = leaf.type ?? '';
    let mainClass = leaf.mainClass ?? '';
    let javaVersion = leaf.javaVersion?.majorVersion ?? 8;
    let releaseTime = leaf.releaseTime ?? '';
    let loader = '';
    let mcVersion = leaf.id ?? '';
    // 解析继承链/补丁取"有效清单"（展示用），真 MC 版本号取解析结果（Fabric 实例 ≠ 目录名）。
    const resolved = resolveVersion(gameRoot, jsonPath);
    if (resolved !== null) {
      const rj = resolved.json;
      type = rj.type ?? type;
      mainClass = rj.mainClass ?? mainClass;
      javaVersion = rj.javaVersion?.majorVersion ?? javaVersion;
      releaseTime = rj.releaseTime ?? releaseTime;
      loader = resolved.loader;
      mcVersion = resolved.mcVersion;
    }
    return new GameVersion(
      dirName,
      type.length > 0 ? type : 'unknown',
      jsonPath,
      mainClass,
      javaVersion,
      releaseTime,
      loader,
      mcVersion
    );
  } catch {
    return null;
  }
}

interface GameVersionJson {
  id?: string;
  type?: string;
  mainClass?: string;
  javaVersion?: GameJavaVersion;
  releaseTime?: string;
}

interface GameJavaVersion {
  majorVersion?: number;
}

/**
 * 扫描选中目录（即游戏根 = .minecraft）下的已安装版本。
 *
 * 语义：**用户选中的目录就是游戏根**（不识别"父目录"等其它布局）。
 * 目录里没有 versions/ 时返回空数组（只是"还没装版本"，不是无效目录）。
 *
 * 对每个版本：遍历 versions/<v>/<v>.json；条目身份 = 目录名 `<v>`（见 GameVersion.id）。
 * 排除逻辑（对齐 HMCL）：**不按名字/后缀排除**，只要求存在 `<v>/<v>.json` 且可解析；
 * 删除残留已移出 `versions/`（见 VersionTools），非实例目录（无同名 json）自然被跳过。
 *
 * @param dirUri Picker 选中的目录 URI（file://docs/...），需已授权。
 */
export function scanVersions(dirUri: string): GameVersion[] {
  const rootPath = userFileUriToPath(dirUri);
  if (rootPath.length === 0) {
    return [];
  }
  const versionsPath = `${rootPath}/versions/`;
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(versionsPath);
  } catch {
    return [];
  }

  const result: GameVersion[] = [];
  for (const name of entries) {
    try {
      const stat = fileIo.statSync(`${versionsPath}${name}`);
      if (stat.isDirectory()) {
        const v = parseVersionJson(rootPath, name, `${versionsPath}${name}/${name}.json`);
        if (v) {
          result.push(v);
        }
      }
    } catch {
      // 单版本损坏不影响其它版本
      continue;
    }
  }
  // 排序：语义化**降序**——新版本在前（1.21.10 > 1.17 > 1.10.2 > 1.7.10）；
  // 段纯数字按数值比较，不是字符串字典序（否则 1.7.10 会排到 1.10.x 前）。
  result.sort((a: GameVersion, b: GameVersion) => compareVersionIds(b.id, a.id));
  return result;
}

/** 段是否全为数字（用于版本号数值比较）。 */
function isAllDigits(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 48 || c > 57) {
      return false;
    }
  }
  return true;
}

/**
 * 版本 id 语义化比较：按 '.' 分段，段全为数字则数值比较，否则字典序；
 * 前缀相等时短者在前。例：1.7.10 < 1.10.2；1.16.5 < 1.17。
 */
export function compareVersionIds(a: string, b: string): number {
  const sa = a.split('.');
  const sb = b.split('.');
  const n = Math.min(sa.length, sb.length);
  for (let i = 0; i < n; i++) {
    const segA = sa[i];
    const segB = sb[i];
    if (isAllDigits(segA) && isAllDigits(segB)) {
      const na = parseInt(segA, 10);
      const nb = parseInt(segB, 10);
      if (na !== nb) {
        return na < nb ? -1 : 1;
      }
    } else {
      const c = segA.localeCompare(segB);
      if (c !== 0) {
        return c;
      }
    }
  }
  return sa.length - sb.length;
}

/**
 * 由目录 URI 解析出游戏根目录物理路径。
 * 用户选中的目录**就是游戏根**（等价 .minecraft）；空目录同样有效，安装时创建标准结构。
 * 非法/空 URI 返回空串（调用方据此判"无法解析"）。
 * 供安装器把新版本写进与扫描一致的根目录。
 */
export function resolveGameRoot(dirUri: string): string {
  return userFileUriToPath(dirUri);
}
