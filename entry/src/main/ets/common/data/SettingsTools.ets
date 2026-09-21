import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalSettings, LastLaunch, normalizeGlobalSettings } from './GlobalSettings';
import { appSettingsFileExists, tryReadAppGlobalSettings,
  writeAppGlobalSettings } from './AppSettings';
import { meowSettingsDir, touchControlsSettingsPath, touchControlsBadPath } from '../constants/Paths';
import { TOUCH_AS_MOUSE_DEFAULT, TOUCH_SENSITIVITY_DEFAULT_PERCENT, TOUCH_CONTROLS_DEFAULT,
  TOUCH_CONTROLS_INSET_DEFAULT, TOUCH_CONTROLS_SCALE_DEFAULT_PERCENT,
  TOUCH_CONTROLS_SCALE_MIN_PERCENT, TOUCH_CONTROLS_SCALE_MAX_PERCENT } from '../constants/Constants';

// 保持原公开 API：LastLaunch 类型原从本文件导出，现归属 GlobalSettings，这里转出。
export { LastLaunch };

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'SettingsTools';

/** 触控设置文件格式版本（plain JSON；`format` 总写；仿 app-settings.json 的 `APP_SETTINGS_FORMAT`）。 */
const TOUCH_CONTROLS_FORMAT: number = 1;
/** 触控设置写入临时文件后缀（同目录，写完 rename 原子替换）。 */
const TOUCH_CONTROLS_TMP_SUFFIX: string = '.tmp';

/** 模块级缓存：全局设置与应用级唯一，缓存这一份；写成功后更新。 */
let cacheValue: GlobalSettings | null = null;
/** 模块级缓存：触控设置（独立文件）唯一一份；仅"读到"或"写成功"后更新。 */
let cacheTouch: TouchSettings | null = null;

/**
 * 应用全局设置持久化数据层（纯逻辑，不依赖 UI）。
 *
 * 数据源为应用沙箱 `<filesDir>/meow-settings/app-settings.json` 的 `global` 段
 * （见 `AppSettings.ets` / `GlobalSettings.ets`）：**应用级、全局唯一**，不再按游戏目录各存一份。
 * 主进程（启动器）与游戏进程（`:game`）读同一份文件——AppStorageV2 不跨进程。
 *
 * 读不到（文件缺失 / 坏 / 异格式）→ getter 返回默认值；首次写入时以空设置起底，
 * 但**文件存在却读不出**时拒写（避免把磁盘上其它键删掉）。
 *
 * **触控设置单独一份**：`<filesDir>/meow-settings/touch-controls.json`（见文件末触控段落），
 * 扁平、可整份替换；非触控方法仍走 `app-settings.json`。
 *
 * 兼容性：本类**保留原公开 API（方法名 / 签名 / 默认值）**，仅换后端存储，故所有调用点无需改动。
 */
export class SettingsTools {
  /** 宿主上下文（解析应用沙箱路径）。 */
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 读应用级全局设置（带模块级缓存）；读不到 → 默认值。
   * **读不到时不写缓存**（文件缺失 / 坏）：否则后续重读仍会命中缓存里的默认值。
   */
  private current(): GlobalSettings {
    if (cacheValue !== null) {
      return cacheValue;
    }
    const s = tryReadAppGlobalSettings(this.context);
    if (s === null) {
      return GlobalSettings.defaults();
    }
    cacheValue = s;
    return s;
  }

  /**
   * 改一项并落盘（以磁盘最新为底读改写；成功才更新缓存）。
   * **读不到、但文件已存在**（坏文件 / 异格式）→ 不写：写入是"以磁盘 JSON 为底 merge"，起点若是
   * 默认对象会把磁盘上的其它键**删掉**；只有文件**根本不存在**（首次写入）才允许以默认值起底。
   */
  private update(mutate: (s: GlobalSettings) => void): void {
    let s = tryReadAppGlobalSettings(this.context);
    if (s === null) {
      if (appSettingsFileExists(this.context)) {
        hilog.error(LOG_DOMAIN, LOG_TAG,
          'app-settings.json exists but unreadable; global setting not written');
        return;
      }
      s = GlobalSettings.defaults();
    }
    mutate(s);
    // 写前归一化：缓存（写成功即缓存此对象）与磁盘（buildGlobalNode 同规则夹取）恒一致。
    s = normalizeGlobalSettings(s);
    if (writeAppGlobalSettings(this.context, s)) {
      cacheValue = s;
    } else {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write app global settings failed');
    }
  }

  /**
   * 读触控设置（独立文件 `<filesDir>/meow-settings/touch-controls.json`，带模块级缓存）。
   * 文件不存在 / 解析失败 / 字段缺失 → 默认值，不报错、不打断启动；
   * **文件不是合法 JSON 对象**（解析抛错 / 根非对象）或 `format` 不认识时，先把原文件改名备份为
   * 同目录 `.bad`（覆盖旧的 `.bad`），再照旧走默认值，避免用户手改内容被后续写盘静默覆盖；
   * **文件不存在**（含空 / 纯空白）时顺手写出一份完整默认内容（便于用户发现并手改）；
   * **文件存在却读失败**（非解析，如 I/O 错误）→ 用默认值但不写盘，避免覆盖用户内容；随后缓存。
   */
  private currentTouch(): TouchSettings {
    if (cacheTouch !== null) {
      return cacheTouch;
    }
    const res = readTouchResult(this.context);
    const s = parseTouchSettings(res.node);
    if (res.status === TOUCH_READ_MISSING || res.status === TOUCH_READ_BAD) {
      writeTouchSettings(this.context, s);
    } else if (res.status === TOUCH_READ_ERROR) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'touch-controls.json exists but unreadable; defaults used, not written');
    }
    cacheTouch = s;
    return s;
  }

  /**
   * 改一项触控设置并落盘（读改写；以磁盘现有 JSON 为底保留未知字段；成功才更新缓存）。
   * 写盘时机与既有应用级设置一致：变更即写。
   * **写前归一化**（同 `update()` 的 `normalizeGlobalSettings`）：缓存（写成功即缓存此对象）与磁盘
   * （`buildTouchNode` 同规则夹取）恒一致，避免"缓存 999 / 磁盘 200"这类分裂。
   */
  private updateTouch(mutate: (s: TouchSettings) => void): void {
    const s = parseTouchSettings(readTouchRaw(this.context));
    mutate(s);
    const n = normalizeTouchSettings(s);
    if (writeTouchSettings(this.context, n)) {
      cacheTouch = n;
    } else {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write touch-controls.json failed');
    }
  }

  /** 是否显示鼠标采样率 overlay（默认关）。 */
  showInputRate(): boolean {
    return this.current().showInputRate;
  }

  /** 写入"显示鼠标采样率"开关并落盘。 */
  setShowInputRate(on: boolean): void {
    this.update((s: GlobalSettings) => {
      s.showInputRate = on;
    });
  }

  /** 触屏当鼠标：单指点按=左键单击、拖动=移动光标、游戏内拖动=转视角、双指点按=右键（默认开）。 */
  touchAsMouse(): boolean {
    return this.currentTouch().touchAsMouse;
  }

  /** 写入"触屏当鼠标"开关并落盘。 */
  setTouchAsMouse(v: boolean): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchAsMouse = v;
    });
  }

  /** 虚拟触屏按键覆盖层（独立于触屏当鼠标；默认关）。 */
  touchControls(): boolean {
    return this.currentTouch().touchControls;
  }

  /** 写入"虚拟触屏按键覆盖层"开关并落盘。 */
  setTouchControls(v: boolean): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchControls = v;
    });
  }

  // ---- 虚拟触屏按键覆盖层四边内边距（vp；把三簇按钮从屏幕四边推开）----
  // 钳制：有限数且 ≥ 0（负数 / 非法 / 缺失 → 默认 12）；上界不限。

  /** 覆盖层上边距（vp）；未设置 / 非法 / 负数 → 默认 12。 */
  touchControlsInsetTop(): number {
    return this.currentTouch().touchControlsInsetTop;
  }

  setTouchControlsInsetTop(v: number): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchControlsInsetTop = v;
    });
  }

  /** 覆盖层右边距（vp）；未设置 / 非法 / 负数 → 默认 12。 */
  touchControlsInsetRight(): number {
    return this.currentTouch().touchControlsInsetRight;
  }

  setTouchControlsInsetRight(v: number): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchControlsInsetRight = v;
    });
  }

  /** 覆盖层下边距（vp）；未设置 / 非法 / 负数 → 默认 12。 */
  touchControlsInsetBottom(): number {
    return this.currentTouch().touchControlsInsetBottom;
  }

  setTouchControlsInsetBottom(v: number): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchControlsInsetBottom = v;
    });
  }

  /** 覆盖层左边距（vp）；未设置 / 非法 / 负数 → 默认 12。 */
  touchControlsInsetLeft(): number {
    return this.currentTouch().touchControlsInsetLeft;
  }

  setTouchControlsInsetLeft(v: number): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchControlsInsetLeft = v;
    });
  }

  // ---- 虚拟触屏按键覆盖层整体缩放（百分比）----

  /** 虚拟按键整体缩放百分比；未设置/非法/非正 → 默认 100（正常）；钳制到 [50,200]。 */
  touchControlsScalePercent(): number {
    return this.currentTouch().touchControlsScale;
  }

  setTouchControlsScalePercent(n: number): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchControlsScale = n;
    });
  }

  // ---- 启动参数覆盖（0 / 空串 = 自动，用 LaunchDefaults 默认）----

  /** CPU 线程数覆盖；0 = 自动（不传 -XX:ActiveProcessorCount，由 JVM 探测）。 */
  cpuCount(): number {
    return this.current().cpuCount;
  }

  setCpuCount(n: number): void {
    this.update((s: GlobalSettings) => {
      s.cpuCount = n;
    });
  }

  /** 最大堆 MB 覆盖；0 = 自动（不传 -Xmx，用 JVM 默认）。 */
  maxHeapMb(): number {
    return this.current().maxHeapMb;
  }

  setMaxHeapMb(n: number): void {
    this.update((s: GlobalSettings) => {
      s.maxHeapMb = n;
    });
  }

  // 注：逐版本设置（版本隔离 / 渲染后端 / 线程化渲染）**在应用沙箱之外**——
  // 现存各实例目录内的 `.hmmcraft/instance-settings.json`（见 data/InstanceSettings.ets）。

  // ---- 鼠标滚轮速度（百分比）----

  /** 滚轮速度百分比；未设置/非法/非正 → 默认 100（正常）。 */
  scrollSpeedPercent(): number {
    return this.current().scrollSpeed;
  }

  setScrollSpeedPercent(n: number): void {
    this.update((s: GlobalSettings) => {
      s.scrollSpeed = n;
    });
  }

  // ---- 触屏转视角灵敏度（百分比）----

  /** 触屏转视角灵敏度百分比；未设置/非法/非正 → 默认 128（正常）。 */
  touchSensitivityPercent(): number {
    return this.currentTouch().touchSensitivity;
  }

  setTouchSensitivityPercent(n: number): void {
    this.updateTouch((s: TouchSettings) => {
      s.touchSensitivity = n;
    });
  }

  // ---- 显示缩放 ----

  /** 显示缩放 N（渲染分辨率 = 窗口/N）；仅 RENDER_SCALE_OPTIONS 内合法，否则默认 1（关闭）。 */
  renderScale(): number {
    return this.current().renderScale;
  }

  setRenderScale(n: number): void {
    this.update((s: GlobalSettings) => {
      s.renderScale = n;
    });
  }

  // ---- 微软登录 client_id（用户自填，不预置）----

  /** Azure 公有客户端 id；未设置 → 空串（微软登录不可用）。 */
  msClientId(): string {
    return this.current().msClientId;
  }

  setMsClientId(v: string): void {
    this.update((s: GlobalSettings) => {
      s.msClientId = v;
    });
  }

  /** 额外渲染环境变量（实验；`K=V`，换行/`;` 分隔）。空 = 不改。 */
  renderEnv(): string {
    return this.current().renderEnv;
  }

  setRenderEnv(v: string): void {
    this.update((s: GlobalSettings) => {
      s.renderEnv = v;
    });
  }

  /** 额外 JVM 参数（实验；空格/换行分隔）。空 = 不传。 */
  jvmArgs(): string {
    return this.current().jvmArgs;
  }

  setJvmArgs(v: string): void {
    this.update((s: GlobalSettings) => {
      s.jvmArgs = v;
    });
  }

  // ---- 上次启动的游戏（"继续上次"按钮；删版本/移除目录时清理）----

  /** 上次启动记录；无记录/解析失败均返回 null。 */
  lastLaunch(): LastLaunch | null {
    return this.current().lastLaunch;
  }

  /** 记录一次成功启动（下次可用"继续上次"一键启动）。 */
  setLastLaunch(dir: string, version: string, jsonPath: string): void {
    if (dir.length === 0 || version.length === 0) {
      return;
    }
    this.update((s: GlobalSettings) => {
      s.lastLaunch = { dir: dir, version: version, jsonPath: jsonPath };
    });
  }

  /** 清除"上次启动"记录。 */
  clearLastLaunch(): void {
    this.update((s: GlobalSettings) => {
      s.lastLaunch = null;
    });
  }

  /**
   * 若"上次启动"记录正是该目录下的该版本，清除之（删版本时用）。
   * 记录为**应用级唯一**，故必须同时匹配 `dir` 与 `version`，否则会误清别的目录下的同名实例。
   */
  clearLastLaunchIf(dir: string, version: string): void {
    const rec = this.lastLaunch();
    if (rec !== null && rec.dir === dir && rec.version === version) {
      this.clearLastLaunch();
    }
  }

  // ---- 版本下载源（下载面板写，安装时读）----

  /** 下载源；未设置 → 镜像（SOURCE_MIRROR）。 */
  downloadSource(): string {
    return this.current().downloadSource;
  }

  setDownloadSource(source: string): void {
    this.update((s: GlobalSettings) => {
      s.downloadSource = source;
    });
  }

  // ---- mod loader 下载源（**与版本源独立**；目前仅 Fabric）----

  /** loader 下载源；未设置 → 镜像（SOURCE_MIRROR）。 */
  fabricSource(): string {
    return this.current().fabricSource;
  }

  setFabricSource(source: string): void {
    this.update((s: GlobalSettings) => {
      s.fabricSource = source;
    });
  }

  // ---- 版本类型过滤（release / snapshot / other；下载面板写、读）----

  /** 版本类型过滤；未设置 → 正式版（release）。 */
  versionType(): string {
    return this.current().versionType;
  }

  setVersionType(type: string): void {
    this.update((s: GlobalSettings) => {
      s.versionType = type;
    });
  }
}

// ---- 触控设置（独立文件 <filesDir>/meow-settings/touch-controls.json）----
// 8 个触控项中仅 touchAsMouse / touchSensitivity 两项自 app-settings.json 的 global.launcher 迁入
// （语义 / 默认值保持）；其余 6 项（touchControls + 整体缩放 + 四边内距）为本次新增。
// 文件是**扁平** JSON（format + 8 个键），整份替换即可换一套触控布局。

/** 触控设置（纯数据；独立文件内容模型；JSON 键名与字段名的映射见 parseTouchSettings / buildTouchNode）。 */
class TouchSettings {
  /** 触屏当鼠标（默认开）。 */
  touchAsMouse: boolean = TOUCH_AS_MOUSE_DEFAULT;
  /** 虚拟触屏按键覆盖层（默认关）。 */
  touchControls: boolean = TOUCH_CONTROLS_DEFAULT;
  /** 触屏转视角灵敏度百分比（默认 128）。 */
  touchSensitivity: number = TOUCH_SENSITIVITY_DEFAULT_PERCENT;
  /** 覆盖层整体缩放百分比（默认 100）。 */
  touchControlsScale: number = TOUCH_CONTROLS_SCALE_DEFAULT_PERCENT;
  /** 覆盖层上边距（vp；默认 12）。 */
  touchControlsInsetTop: number = TOUCH_CONTROLS_INSET_DEFAULT;
  /** 覆盖层右边距（vp；默认 12）。 */
  touchControlsInsetRight: number = TOUCH_CONTROLS_INSET_DEFAULT;
  /** 覆盖层下边距（vp；默认 12）。 */
  touchControlsInsetBottom: number = TOUCH_CONTROLS_INSET_DEFAULT;
  /** 覆盖层左边距（vp；默认 12）。 */
  touchControlsInsetLeft: number = TOUCH_CONTROLS_INSET_DEFAULT;

  /** 默认值工厂（各字段默认值取 `Constants.ets` 中的触控常量）。 */
  static defaults(): TouchSettings {
    return new TouchSettings();
  }
}

/** 磁盘上 touch-controls.json 的已知字段形状（只读解析用；未知字段经写入底稿保留）。 */
interface TouchControlsJson {
  format?: number;
  touchAsMouse?: boolean;
  touchControls?: boolean;
  touchSensitivity?: number;
  touchControlsScale?: number;
  insetTop?: number;
  insetRight?: number;
  insetBottom?: number;
  insetLeft?: number;
}

/** 读取状态：正常读到合法 JSON 对象。 */
const TOUCH_READ_OK: number = 0;
/** 读取状态：文件缺失 / 空（可安全以空对象起底写入）。 */
const TOUCH_READ_MISSING: number = 1;
/** 读取状态：文件存在但坏（解析失败 / 根非对象 / format 不认识），已备份为 `.bad`。 */
const TOUCH_READ_BAD: number = 2;
/** 读取状态：文件存在却读失败（非解析，如 I/O 错误）——**拒写**，避免静默覆盖。 */
const TOUCH_READ_ERROR: number = 3;

/** 触控文件读取结果：状态 + 正常时的对象（其余状态为 null）。 */
class TouchReadResult {
  status: number;
  node: Record<string, Object | undefined> | null;

  constructor(status: number, node: Record<string, Object | undefined> | null) {
    this.status = status;
    this.node = node;
  }
}

/** 触屏灵敏度夹到正数（非法 / 缺失 / 非正 → 128；范围与滚轮速度同规则，上界不限）。 */
function normalizeTouchSensitivity(v: number | undefined): number {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : TOUCH_SENSITIVITY_DEFAULT_PERCENT;
}

/** 触屏覆盖层内边距夹到非负有限数（非法 / 缺失 / 负数 → 默认 12）；上界不限（用户自行取舍）。 */
function normalizeTouchControlsInset(v: number | undefined): number {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : TOUCH_CONTROLS_INSET_DEFAULT;
}

/** 虚拟按键整体缩放夹到 [50,200] 百分比（非法 / 缺失 / 非正 → 默认 100）。 */
function normalizeTouchControlsScale(v: number | undefined): number {
  if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0) {
    return TOUCH_CONTROLS_SCALE_DEFAULT_PERCENT;
  }
  return Math.min(TOUCH_CONTROLS_SCALE_MAX_PERCENT, Math.max(TOUCH_CONTROLS_SCALE_MIN_PERCENT, v));
}

/**
 * 写盘 / 缓存前统一归一化（与 `buildTouchNode` 同一组夹取规则）。
 * 保证缓存对象与落到磁盘的字段逐字段一致（对照 `update()` 的 `normalizeGlobalSettings`）。
 * 布尔项不夹取（`parseTouchSettings` 已把语义收敛为 true / false）。
 */
function normalizeTouchSettings(s: TouchSettings): TouchSettings {
  s.touchSensitivity = normalizeTouchSensitivity(s.touchSensitivity);
  s.touchControlsScale = normalizeTouchControlsScale(s.touchControlsScale);
  s.touchControlsInsetTop = normalizeTouchControlsInset(s.touchControlsInsetTop);
  s.touchControlsInsetRight = normalizeTouchControlsInset(s.touchControlsInsetRight);
  s.touchControlsInsetBottom = normalizeTouchControlsInset(s.touchControlsInsetBottom);
  s.touchControlsInsetLeft = normalizeTouchControlsInset(s.touchControlsInsetLeft);
  return s;
}

/**
 * 解析触控设置（缺文件 / 缺字段 / 非法值 → 默认值）。
 * 布尔语义逐字沿用旧 global.launcher：`touchAsMouse` 仅显式 `false` 为关；`touchControls` 仅显式 `true` 为开。
 */
function parseTouchSettings(raw: Record<string, Object | undefined> | null): TouchSettings {
  const s = TouchSettings.defaults();
  if (raw === null) {
    return s;
  }
  const j = raw as TouchControlsJson;
  s.touchAsMouse = j.touchAsMouse !== false;
  s.touchControls = j.touchControls === true;
  s.touchSensitivity = normalizeTouchSensitivity(j.touchSensitivity);
  s.touchControlsScale = normalizeTouchControlsScale(j.touchControlsScale);
  s.touchControlsInsetTop = normalizeTouchControlsInset(j.insetTop);
  s.touchControlsInsetRight = normalizeTouchControlsInset(j.insetRight);
  s.touchControlsInsetBottom = normalizeTouchControlsInset(j.insetBottom);
  s.touchControlsInsetLeft = normalizeTouchControlsInset(j.insetLeft);
  return s;
}

/** 组装触控节点：覆写 `format` 与 8 个已知键（先经 normalizeTouchSettings 夹取）；底稿里其它未知键原样保留（扁平）。 */
function buildTouchNode(data: TouchSettings,
  base: Record<string, Object | undefined>): Record<string, Object | undefined> {
  const n = normalizeTouchSettings(data);
  base['format'] = TOUCH_CONTROLS_FORMAT;
  base['touchAsMouse'] = n.touchAsMouse;
  base['touchControls'] = n.touchControls;
  base['touchSensitivity'] = n.touchSensitivity;
  base['touchControlsScale'] = n.touchControlsScale;
  base['insetTop'] = n.touchControlsInsetTop;
  base['insetRight'] = n.touchControlsInsetRight;
  base['insetBottom'] = n.touchControlsInsetBottom;
  base['insetLeft'] = n.touchControlsInsetLeft;
  return base;
}

/**
 * 把无法解析的原文件改名为同目录 `.bad` 备份（供用户找回手改内容）。
 * `.bad` 已存在则直接覆盖：简单确定，不做时间戳堆叠。
 * 改名失败不影响流程（记 error 后忽略），后续照旧走默认值。
 */
function backupBadTouchFile(ctx: common.Context): void {
  const path = touchControlsSettingsPath(ctx.filesDir);
  const badPath = touchControlsBadPath(ctx.filesDir);
  try {
    removeQuietly(badPath);
    fileIo.renameSync(path, badPath);
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'touch-controls.json unparsable; backed up to %{public}s', badPath);
  } catch (e) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'backup touch-controls.json failed: %{public}s',
      (e as BusinessError).message);
  }
}

/**
 * 读触控设置 JSON（未知键随对象保留），区分四种状态（见 TOUCH_READ_*）。
 * 缺失 / 空 → MISSING；**存在但内容不是合法 JSON、根非对象、或 `format` 不认识** → 先备份为
 * `.bad` 再返回 BAD（对照 AppSettings 对未知 `format` 的处理，不静默降级）；**存在却读失败**（非解析，
 * 如 I/O 错误）→ ERROR（不备份、不覆盖）。
 * 字段缺失 / 值非法不在此拦截（交给各 normalize* 回默认，属既有契约）。
 */
function readTouchResult(ctx: common.Context): TouchReadResult {
  let text: string;
  try {
    text = fileIo.readTextSync(touchControlsSettingsPath(ctx.filesDir));
  } catch {
    // 区分"文件不存在"与"存在却读失败"：后者拒写，避免静默覆盖用户内容。
    return new TouchReadResult(touchFilePresent(ctx) ? TOUCH_READ_ERROR : TOUCH_READ_MISSING, null);
  }
  if (text.trim().length === 0) {
    return new TouchReadResult(TOUCH_READ_MISSING, null);
  }
  let parsed: Record<string, Object | undefined>;
  try {
    parsed = JSON.parse(text) as Record<string, Object | undefined>;
  } catch {
    backupBadTouchFile(ctx);
    return new TouchReadResult(TOUCH_READ_BAD, null);
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    backupBadTouchFile(ctx);
    return new TouchReadResult(TOUCH_READ_BAD, null);
  }
  const j = parsed as TouchControlsJson;
  if (j.format !== undefined && j.format !== TOUCH_CONTROLS_FORMAT) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown touch-controls format %{public}s', `${j.format}`);
    backupBadTouchFile(ctx);
    return new TouchReadResult(TOUCH_READ_BAD, null);
  }
  return new TouchReadResult(TOUCH_READ_OK, parsed);
}

/** 读触控设置 JSON 原文为对象；非 OK（缺失 / 空 / 坏 / 读失败）→ null。 */
function readTouchRaw(ctx: common.Context): Record<string, Object | undefined> | null {
  return readTouchResult(ctx).node;
}

/** 触控设置文件是否存在（不看内容、不看可读性）；用于区分"缺失"与"存在却读失败"。 */
function touchFilePresent(ctx: common.Context): boolean {
  try {
    return fileIo.accessSync(touchControlsSettingsPath(ctx.filesDir));
  } catch {
    return false;
  }
}

/**
 * 写触控设置（以磁盘现有 JSON 为底 merge，保留未知字段），返回是否成功。
 * 建目录 → 写同目录 `.tmp` → 先试 `renameSync` 覆盖，不允覆盖才 unlink 再 rename。
 * **文件存在却读失败**（非解析）→ 拒写（对照 `update()` 护栏），避免以空底稿覆盖、删掉未知键。
 * 坏内容（解析失败 / 异格式）已在 `readTouchResult` 中备份为 `.bad`，此时可安全以空底稿重建。
 */
function writeTouchSettings(ctx: common.Context, data: TouchSettings): boolean {
  const res = readTouchResult(ctx);
  if (res.status === TOUCH_READ_ERROR) {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'touch-controls.json exists but unreadable; not written to avoid overwriting');
    return false;
  }
  const node = buildTouchNode(data, res.node !== null ? res.node : {});
  return writeJsonAtomic(meowSettingsDir(ctx.filesDir),
    touchControlsSettingsPath(ctx.filesDir), node);
}

/**
 * 原子写 JSON：建目录 → 写 `.tmp` → 先试 `renameSync` 直接覆盖；不允覆盖已存在目标时
 * unlink 再 rename；两步皆败保留 tmp 并记 error。写多行缩进（2 空格）便于用户查看 / 手改。
 */
function writeJsonAtomic(dir: string, target: string,
  obj: Record<string, Object | undefined>): boolean {
  try {
    fileIo.mkdirSync(dir, true);
  } catch {
    // 目录已存在
  }
  const text = JSON.stringify(obj, null, 2);
  const tmp = `${target}${TOUCH_CONTROLS_TMP_SUFFIX}`;
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(tmp,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, text);
    fileIo.closeSync(file);
    file = null;
  } catch (e) {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch {
        // 忽略关闭异常
      }
    }
    removeQuietly(tmp);
    hilog.error(LOG_DOMAIN, LOG_TAG, 'write touch tmp failed at %{public}s: %{public}s',
      target, (e as BusinessError).message);
    return false;
  }
  try {
    fileIo.renameSync(tmp, target);
    return true;
  } catch {
    try {
      removeQuietly(target);
      fileIo.renameSync(tmp, target);
      return true;
    } catch (secondErr) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write touch failed at %{public}s (tmp kept): %{public}s',
        target, (secondErr as BusinessError).message);
      return false;
    }
  }
}

/** 删除文件，忽略不存在等错误。 */
function removeQuietly(path: string): void {
  try {
    fileIo.unlinkSync(path);
  } catch {
    // 目标不存在时忽略
  }
}
