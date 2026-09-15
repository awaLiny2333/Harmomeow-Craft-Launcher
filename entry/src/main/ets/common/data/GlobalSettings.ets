import { SCROLL_SPEED_DEFAULT_PERCENT, RENDER_SCALE_DEFAULT,
  RENDER_SCALE_OPTIONS } from '../constants/Constants';
import { SOURCE_MIRROR, SOURCE_OFFICIAL, TYPE_RELEASE, TYPE_SNAPSHOT,
  TYPE_OTHER } from '../constants/DownloadContract';

/** 上次启动的游戏记录（"继续上次"按钮用）。 */
export interface LastLaunch {
  /** 游戏目录 URI（用于校验目录仍在列表里 / 移除时清理）。 */
  dir: string;
  /** 版本 id。 */
  version: string;
  /** 版本 json 的物理路径（无需再扫描即可直接启动）。 */
  jsonPath: string;
}

/** 磁盘上 `global` 段里"上次启动"节点的形状（只读解析用）。 */
interface LastLaunchJson {
  dir?: string;
  version?: string;
  jsonPath?: string;
}

interface LauncherGroupJson {
  scrollSpeed?: number;
  showInputRate?: boolean;
  versionType?: string;
  lastLaunch?: LastLaunchJson;
}

interface RuntimeGroupJson {
  cpuCount?: number;
  maxHeapMb?: number;
  renderScale?: number;
  renderEnv?: string;
  jvmArgs?: string;
}

interface NetworkGroupJson {
  downloadSource?: string;
  fabricSource?: string;
  msClientId?: string;
}

/** 磁盘上 `app-settings.json` 的 `global` 段形状（稀疏，缺键 = 默认值）。 */
export interface GlobalSettingsJson {
  launcher?: LauncherGroupJson;
  runtime?: RuntimeGroupJson;
  network?: NetworkGroupJson;
}

/**
 * 全局设置（纯数据）。
 *
 * 存 `<filesDir>/meow-settings/app-settings.json` 的 `global` 段：**应用级、全局唯一**，
 * 不再按游戏目录各存一份、也不再随游戏目录迁移。分三组：
 * - `launcher`：滚动速度 / 采样率 overlay / 版本类型 / 上次启动；
 * - `runtime`：CPU 线程数 / 最大堆 / 显示缩放 / 渲染环境变量 / JVM 参数；
 * - `network`：版本下载源 / loader 下载源 / 微软 client_id。
 *
 * 注意：账户（含 token）与目录枚举也在同一目录下（`accounts.json` / 本文件的同级段），见 `AppSettings.ets`。
 */
export class GlobalSettings {
  // ---- launcher 组 ----
  /** 滚轮速度百分比；100 = 正常。 */
  scrollSpeed: number = SCROLL_SPEED_DEFAULT_PERCENT;
  /** 是否显示鼠标采样率 overlay（默认关）。 */
  showInputRate: boolean = false;
  /** 版本类型过滤：release / snapshot / other。 */
  versionType: string = TYPE_RELEASE;
  /** 上次启动记录；无记录 = null。 */
  lastLaunch: LastLaunch | null = null;
  // ---- runtime 组 ----
  /** CPU 线程数覆盖；0 = 自动。 */
  cpuCount: number = 0;
  /** 最大堆 MB 覆盖；0 = 自动。 */
  maxHeapMb: number = 0;
  /** 显示缩放 N（渲染分辨率 = 窗口 / N）。 */
  renderScale: number = RENDER_SCALE_DEFAULT;
  /** 额外渲染环境变量（`K=V`，换行/`;` 分隔）；空 = 不改。 */
  renderEnv: string = '';
  /** 额外 JVM 参数；空 = 不传。 */
  jvmArgs: string = '';
  // ---- network 组 ----
  /** 版本下载源：mirror / official。 */
  downloadSource: string = SOURCE_MIRROR;
  /** mod loader 下载源（与版本源独立）：mirror / official。 */
  fabricSource: string = SOURCE_MIRROR;
  /** 微软登录 client_id（用户自填）；空 = 不可用。 */
  msClientId: string = '';

  /** 默认值工厂（各字段与既有代码默认一致）。 */
  static defaults(): GlobalSettings {
    return new GlobalSettings();
  }
}

/** 版本类型夹到合法集合（非法 / 缺失 → release）。 */
function normalizeVersionType(v: string | undefined): string {
  if (v === TYPE_SNAPSHOT || v === TYPE_OTHER) {
    return v;
  }
  return TYPE_RELEASE;
}

/** 下载源夹到合法集合（非法 / 缺失 → mirror）。 */
function normalizeSource(v: string | undefined): string {
  return v === SOURCE_OFFICIAL ? SOURCE_OFFICIAL : SOURCE_MIRROR;
}

/** 显示缩放夹到合法集合（非法 / 缺失 → 1）。 */
function normalizeRenderScale(v: number | undefined): number {
  return typeof v === 'number' && RENDER_SCALE_OPTIONS.indexOf(v) >= 0 ? v : RENDER_SCALE_DEFAULT;
}

/** 线程数 / 堆 MB 夹到非负整数（非法 / 缺失 / 非正 → 0 = 自动）。 */
function normalizeCount(v: number | undefined): number {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;
}

/** 滚轮速度夹到正数（非法 / 缺失 / 非正 → 100）。 */
function normalizeScrollSpeed(v: number | undefined): number {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : SCROLL_SPEED_DEFAULT_PERCENT;
}

/** 由三字段组装"上次启动"记录：齐全才算有效，否则 null（读盘与写前归一化共用）。 */
function lastLaunchFrom(dir: string, version: string, jsonPath: string): LastLaunch | null {
  if (dir.length > 0 && version.length > 0 && jsonPath.length > 0) {
    return { dir: dir, version: version, jsonPath: jsonPath };
  }
  return null;
}

/** 解析"上次启动"记录：三字段齐全才算有效，否则 null。 */
function readLastLaunch(v: LastLaunchJson | undefined): LastLaunch | null {
  if (v === undefined || v === null) {
    return null;
  }
  const dir = typeof v.dir === 'string' ? v.dir : '';
  const version = typeof v.version === 'string' ? v.version : '';
  const jsonPath = typeof v.jsonPath === 'string' ? v.jsonPath : '';
  return lastLaunchFrom(dir, version, jsonPath);
}

/**
 * 把磁盘上的 `global` 段解析为 `GlobalSettings`（缺组 / 缺键 → 默认值；非法值经归一化）。
 * `undefined` / `null` → 全默认对象（与"读不到文件"不同层：这里代表"文件在、但无 global 段"）。
 */
export function parseGlobalNode(raw: GlobalSettingsJson | undefined): GlobalSettings {
  const s = GlobalSettings.defaults();
  if (raw === undefined || raw === null) {
    return s;
  }
  const l = raw.launcher;
  if (l !== undefined && l !== null) {
    s.scrollSpeed = normalizeScrollSpeed(l.scrollSpeed);
    s.showInputRate = l.showInputRate === true;
    s.versionType = normalizeVersionType(l.versionType);
    s.lastLaunch = readLastLaunch(l.lastLaunch);
  }
  const r = raw.runtime;
  if (r !== undefined && r !== null) {
    s.cpuCount = normalizeCount(r.cpuCount);
    s.maxHeapMb = normalizeCount(r.maxHeapMb);
    s.renderScale = normalizeRenderScale(r.renderScale);
    s.renderEnv = typeof r.renderEnv === 'string' ? r.renderEnv : '';
    s.jvmArgs = typeof r.jvmArgs === 'string' ? r.jvmArgs : '';
  }
  const n = raw.network;
  if (n !== undefined && n !== null) {
    s.downloadSource = normalizeSource(n.downloadSource);
    s.fabricSource = normalizeSource(n.fabricSource);
    s.msClientId = typeof n.msClientId === 'string' ? n.msClientId : '';
  }
  return s;
}

/**
 * 把既有归一化逻辑集中应用一遍（版本类型 / 下载源 / loader 源 / 显示缩放 / CPU 线程数 /
 * 最大堆 / 滚轮速度 / 上次启动；`showInputRate` 为布尔、`renderEnv`/`jvmArgs`/`msClientId`
 * 为自由字符串，无需夹取）。`SettingsTools.update()` 在 mutate 之后、写盘之前调用 ⇒
 * 缓存对象与磁盘落盘值（`buildGlobalNode` 写入时同规则夹取）恒一致。
 */
export function normalizeGlobalSettings(s: GlobalSettings): GlobalSettings {
  s.scrollSpeed = normalizeScrollSpeed(s.scrollSpeed);
  s.versionType = normalizeVersionType(s.versionType);
  const ll = s.lastLaunch;
  s.lastLaunch = ll === null ? null : lastLaunchFrom(ll.dir, ll.version, ll.jsonPath);
  s.cpuCount = normalizeCount(s.cpuCount);
  s.maxHeapMb = normalizeCount(s.maxHeapMb);
  s.renderScale = normalizeRenderScale(s.renderScale);
  s.downloadSource = normalizeSource(s.downloadSource);
  s.fabricSource = normalizeSource(s.fabricSource);
  return s;
}

/** 取对象型 JSON 子节点（非对象 / 缺失 → 空对象，起底用）。 */
function asRecord(v: Object | undefined): Record<string, Object | undefined> {
  if (v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v)) {
    return v as Record<string, Object | undefined>;
  }
  return {};
}

/** 写数字键；等于默认值 → 赋 `undefined`（JSON.stringify 省略，实现"删键"）。 */
function putNumber(obj: Record<string, Object | undefined>, key: string, value: number,
  def: number): void {
  obj[key] = value === def ? undefined : value;
}

/** 写布尔键；等于默认值 → 赋 `undefined` 省略。 */
function putBool(obj: Record<string, Object | undefined>, key: string, value: boolean,
  def: boolean): void {
  obj[key] = value === def ? undefined : value;
}

/** 写字符串键；空串 / 等于默认值 → 赋 `undefined` 省略。 */
function putString(obj: Record<string, Object | undefined>, key: string, value: string,
  def: string): void {
  obj[key] = value.length === 0 || value === def ? undefined : value;
}

/** 组装"上次启动"子对象；无效 → `undefined`（不写）。 */
function buildLastLaunch(ll: LastLaunch | null): Record<string, Object | undefined> | undefined {
  if (ll === null || ll.dir.length === 0 || ll.version.length === 0 || ll.jsonPath.length === 0) {
    return undefined;
  }
  const rec: Record<string, Object | undefined> = {};
  rec['dir'] = ll.dir;
  rec['version'] = ll.version;
  rec['jsonPath'] = ll.jsonPath;
  return rec;
}

/** 组内是否已无"实值"键（只有 `undefined` 视为空，可删整组）。 */
function isEmptyRecord(obj: Record<string, Object | undefined>): boolean {
  const keys = Object.keys(obj);
  for (const k of keys) {
    if (obj[k] !== undefined) {
      return false;
    }
  }
  return true;
}

/**
 * 组装 `global` 段（**稀疏**：值为默认的键不写、空组不写）。以磁盘现有 `global` 为底合并，
 * 未知键 / 未知组原样保留。全部为空（且底稿也没有内容）→ 返回 `undefined`（调用方据此不写该段）。
 */
export function buildGlobalNode(data: GlobalSettings,
  existing: Object | undefined): Record<string, Object | undefined> | undefined {
  const base = asRecord(existing);
  // launcher 组
  const launcher = asRecord(base['launcher']);
  putNumber(launcher, 'scrollSpeed', normalizeScrollSpeed(data.scrollSpeed), SCROLL_SPEED_DEFAULT_PERCENT);
  putBool(launcher, 'showInputRate', data.showInputRate, false);
  putString(launcher, 'versionType', normalizeVersionType(data.versionType), TYPE_RELEASE);
  launcher['lastLaunch'] = buildLastLaunch(data.lastLaunch);
  base['launcher'] = isEmptyRecord(launcher) ? undefined : launcher;
  // runtime 组
  const runtime = asRecord(base['runtime']);
  putNumber(runtime, 'cpuCount', normalizeCount(data.cpuCount), 0);
  putNumber(runtime, 'maxHeapMb', normalizeCount(data.maxHeapMb), 0);
  putNumber(runtime, 'renderScale', normalizeRenderScale(data.renderScale), RENDER_SCALE_DEFAULT);
  putString(runtime, 'renderEnv', data.renderEnv, '');
  putString(runtime, 'jvmArgs', data.jvmArgs, '');
  base['runtime'] = isEmptyRecord(runtime) ? undefined : runtime;
  // network 组
  const network = asRecord(base['network']);
  putString(network, 'downloadSource', normalizeSource(data.downloadSource), SOURCE_MIRROR);
  putString(network, 'fabricSource', normalizeSource(data.fabricSource), SOURCE_MIRROR);
  putString(network, 'msClientId', data.msClientId, '');
  base['network'] = isEmptyRecord(network) ? undefined : network;
  return isEmptyRecord(base) ? undefined : base;
}
