import { fileIo, fileUri } from '@kit.CoreFileKit';

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
  return new fileUri.FileUri(uri).path;
}

/**
 * 识别出的游戏版本条目（从 <dir>/versions/<id>/<id>.json 解析出的信息子集）。
 * 普通 class 即可：识别完成后整体替换 versions 数组，无需逐字段观察。
 *
 * 字段说明：id/type 用于展示；mainClass/javaVersion 后续组装启动参数用；
 * jsonPath/releaseTime 供开发调试核对扫描来源。
 */
export class GameVersion {
  /** 版本 id，如 "1.20.1" / "1.20.4"；同时是版本目录名与 json 文件名。 */
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

  constructor(id: string, type: string, jsonPath: string, mainClass: string, javaVersion: number, releaseTime: string) {
    this.id = id;
    this.type = type;
    this.jsonPath = jsonPath;
    this.mainClass = mainClass;
    this.javaVersion = javaVersion;
    this.releaseTime = releaseTime;
  }
}

/**
 * 从版本 json 解析字段。
 * Minecraft 版本 json 结构：
 * { "id", "type", "mainClass", "releaseTime",
 *   "javaVersion": { "majorVersion": 17, ... }, ... }。
 * 解析失败或缺少 id 时返回 null（该版本目录被跳过）。
 */
function parseVersionJson(jsonPath: string): GameVersion | null {
  try {
    const text = fileIo.readTextSync(jsonPath);
    const obj = JSON.parse(text) as GameVersionJson;
    const id = obj.id ?? '';
    if (id.length === 0) {
      return null;
    }
    const type = obj.type ?? '';
    const mainClass = obj.mainClass ?? '';
    const javaVersion = obj.javaVersion?.majorVersion ?? 8;
    const releaseTime = obj.releaseTime ?? '';
    return new GameVersion(
      id,
      type.length > 0 ? type : 'unknown',
      jsonPath,
      mainClass,
      javaVersion,
      releaseTime
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
 * 扫描目录（可能为 .minecraft 父目录）下的已安装版本。
 *
 * 目录探测策略（兼容两种常见布局）：
 * 1. 若 <dir>/.minecraft/versions 存在，则把它当作游戏根目录（用户选了 .minecraft 的父目录）；
 * 2. 否则若 <dir>/versions 存在，则 <dir> 本身就是游戏根目录；
 * 3. 都不存在 → 返回空数组（不是有效游戏目录）。
 *
 * 对每个版本：遍历 versions/<v>/<v>.json 读取 id / type。
 * 跳过 "removed" 结尾的目录（历史启动器约定）。
 *
 * @param dirUri Picker 选中的目录 URI（file://docs/...），需已授权。
 */
export function scanVersions(dirUri: string): GameVersion[] {
  const dirPath = userFileUriToPath(dirUri);
  const rootPath = locateGameRoot(dirPath);
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
    if (name.endsWith('removed')) {
      continue;
    }
    try {
      const stat = fileIo.statSync(`${versionsPath}${name}`);
      if (stat.isDirectory()) {
        const v = parseVersionJson(`${versionsPath}${name}/${name}.json`);
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
 * 探测游戏根目录（含 versions 子目录的那一层）。
 * 返回空串表示无效目录。
 */
function locateGameRoot(dirPath: string): string {
  // 情形 1：dir 本身是 .minecraft（含 versions）
  if (hasSubdir(dirPath, 'versions')) {
    return dirPath;
  }
  // 情形 2：dir 是 .minecraft 的父目录
  if (hasSubdir(`${dirPath}/.minecraft`, 'versions')) {
    return `${dirPath}/.minecraft`;
  }
  return '';
}

/** 判断 dirPath 下是否存在名为 sub 的子目录。 */
function hasSubdir(dirPath: string, sub: string): boolean {
  try {
    return fileIo.accessSync(`${dirPath}/${sub}`);
  } catch {
    return false;
  }
}

/**
 * 由目录 URI 解析出游戏根目录物理路径（含 versions 的那一层，可能是 <dir>/.minecraft）。
 * 供安装器把新版本写进与扫描一致的根目录；无效目录返回空串。
 */
export function resolveGameRoot(dirUri: string): string {
  return locateGameRoot(userFileUriToPath(dirUri));
}
