import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalSettings, LastLaunch, normalizeGlobalSettings } from './GlobalSettings';
import { appSettingsFileExists, tryReadAppGlobalSettings,
  writeAppGlobalSettings } from './AppSettings';
import { VK_PROBE_ENV_KEY, VK_PROBE_FRAMES } from '../constants/Constants';

// 保持原公开 API：LastLaunch 类型原从本文件导出，现归属 GlobalSettings，这里转出。
export { LastLaunch };

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'SettingsTools';

/** 模块级缓存：全局设置与应用级唯一，缓存这一份；写成功后更新。 */
let cacheValue: GlobalSettings | null = null;

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
 * 兼容性：本类**保留原公开 API（方法名 / 签名 / 默认值）**，仅把后端从"游戏根内文件"换成
 * `app-settings.json` 的 `global` 段，故所有调用点无需改动。
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

  /**
   * F76 开发者诊断：从 render-env 文本解析 Vulkan 送显探针触发。
   *
   * 出现 `MEOW_VK_PROBE`（或带帧数 `MEOW_VK_PROBE=120`）⇒ 返回要送显的帧数；
   * 未出现 ⇒ 0（不触发，正常用户零行为变化）。省略值 / `=1` / 非法值 → VK_PROBE_FRAMES。
   * 文本格式与 render-env 一致：`K=V`，换行或 `;` 分隔。键名/默认帧数见 Constants。
   */
  vkProbeFrames(): number {
    const text = this.renderEnv();
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const tokens: string[] = lines[i].split(';');
      for (let j = 0; j < tokens.length; j++) {
        const t = tokens[j].trim();
        if (t === VK_PROBE_ENV_KEY) {
          return VK_PROBE_FRAMES;
        }
        const prefix = VK_PROBE_ENV_KEY + '=';
        if (t.startsWith(prefix)) {
          const n = parseInt(t.substring(prefix.length), 10);
          return (Number.isNaN(n) || n <= 1) ? VK_PROBE_FRAMES : n;
        }
      }
    }
    return 0;
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
