import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { STORE_NAME, KEY_SHOW_INPUT_RATE, KEY_CPU_COUNT, KEY_MAX_HEAP_MB,
  KEY_VERSION_ISOLATION, KEY_SCROLL_SPEED, KEY_DOWNLOAD_SOURCE,
  KEY_VERSION_TYPE, KEY_RENDERER_OVERRIDES, SCROLL_SPEED_DEFAULT_PERCENT,
  KEY_RENDER_SCALE, RENDER_SCALE_DEFAULT, RENDER_SCALE_OPTIONS,
  KEY_MS_CLIENT_ID } from '../constants/Constants';
import { SOURCE_MIRROR, TYPE_RELEASE } from '../constants/DownloadContract';
import { RENDERER_AUTO } from '../constants/LaunchDefaults';

/** 逐版本渲染后端覆盖条目（backend ∈ auto/openglv4/gl4es）。 */
export interface RendererOverride {
  id: string;
  backend: string;
}

/**
 * 应用设置持久化数据层（纯逻辑，不依赖 UI）。
 *
 * 与 GameDirsTools 共用同一个 Preferences 文件（STORE_NAME），只是键不同。
 * 为什么需要它：高级选项（如"显示鼠标采样率 overlay"）需要在**主进程**（启动器）
 * 与**游戏进程**（:game）之间共享——两进程各自独立，AppStorageV2 不跨进程，
 * 因此用 Preferences 落盘，主进程写、游戏进程读。
 *
 * 写入规则同 GameDirsTools：putSync 只更新内存缓存，必须紧跟 flushSync() 才落盘。
 */
export class SettingsTools {
  /** Preferences 实例；构造失败时为 null，所有方法需判空兜底。 */
  private store: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch {
      this.store = null;
    }
  }

  /** 是否显示鼠标采样率 overlay（默认关）。 */
  showInputRate(): boolean {
    if (this.store === null) {
      return false;
    }
    try {
      return this.store.getSync(KEY_SHOW_INPUT_RATE, false) as boolean;
    } catch {
      return false;
    }
  }

  /** 写入"显示鼠标采样率"开关并立即落盘。 */
  setShowInputRate(on: boolean): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_SHOW_INPUT_RATE, on);
      this.store.flushSync();
    } catch {
      return;
    }
  }

  // ---- 启动参数覆盖（0 / 空串 = 自动，用 LaunchDefaults 默认）----
  // 主进程（高级选项）写，游戏进程（GameLauncher）读；跨进程走 Preferences。

  /** CPU 线程数覆盖；0 = 自动（不传 -XX:ActiveProcessorCount，由 JVM 探测）。 */
  cpuCount(): number {
    return this.getNumber(KEY_CPU_COUNT);
  }

  setCpuCount(n: number): void {
    this.putNumber(KEY_CPU_COUNT, n);
  }

  /** 最大堆 MB 覆盖；0 = 自动（不传 -Xmx，用 JVM 默认）。 */
  maxHeapMb(): number {
    return this.getNumber(KEY_MAX_HEAP_MB);
  }

  setMaxHeapMb(n: number): void {
    this.putNumber(KEY_MAX_HEAP_MB, n);
  }

  // ---- 版本隔离（逐版本开关；主进程 UI 写，游戏进程 GameLauncher 读）----
  // 存 JSON 字符串数组（已启用隔离的版本 id），空数组 = 全部不隔离（= 历史行为，无回归）。

  /** 已启用版本隔离的版本 id 列表；无记录/解析失败均返回空数组。 */
  versionIsolationIds(): string[] {
    if (this.store === null) {
      return [];
    }
    let raw = '';
    try {
      raw = this.store.getSync(KEY_VERSION_ISOLATION, '') as string;
    } catch {
      return [];
    }
    if (raw.length === 0) {
      return [];
    }
    try {
      const ids = JSON.parse(raw) as string[];
      return Array.isArray(ids) ? ids : [];
    } catch {
      return [];
    }
  }

  /** 写入某版本的隔离开关并立即落盘。 */
  setVersionIsolation(versionId: string, on: boolean): void {
    if (this.store === null || versionId.length === 0) {
      return;
    }
    const ids = this.versionIsolationIds();
    const next: string[] = on
      ? (ids.includes(versionId) ? ids : ids.concat(versionId))
      : ids.filter((v: string) => v !== versionId);
    try {
      this.store.putSync(KEY_VERSION_ISOLATION, JSON.stringify(next));
      this.store.flushSync();
    } catch {
      return;
    }
  }

  /** 某版本是否启用隔离（游戏进程启动前调用）。 */
  versionIsolated(versionId: string): boolean {
    return this.versionIsolationIds().includes(versionId);
  }

  /** 删除版本时清理其持久化设置：隔离开关 + 渲染后端覆盖（一次落盘）。 */
  clearVersion(versionId: string): void {
    if (this.store === null || versionId.length === 0) {
      return;
    }
    const iso = this.versionIsolationIds().filter((v: string) => v !== versionId);
    const ovr = this.rendererOverrides().filter((o: RendererOverride) => o.id !== versionId);
    try {
      this.store.putSync(KEY_VERSION_ISOLATION, JSON.stringify(iso));
      this.store.putSync(KEY_RENDERER_OVERRIDES, JSON.stringify(ovr));
      this.store.flushSync();
    } catch {
      return;
    }
  }

  // ---- 鼠标滚轮速度（百分比；主进程高级选项写，游戏进程读）----

  /** 滚轮速度百分比；未设置/非法/非正 → 默认 100（正常）。 */
  scrollSpeedPercent(): number {
    const n = this.getNumber(KEY_SCROLL_SPEED);
    return n > 0 ? n : SCROLL_SPEED_DEFAULT_PERCENT;
  }

  setScrollSpeedPercent(n: number): void {
    this.putNumber(KEY_SCROLL_SPEED, n);
  }

  // ---- 显示缩放（主进程高级选项写，游戏进程读）----

  /** 显示缩放 N（渲染分辨率 = 窗口/N）；仅 RENDER_SCALE_OPTIONS 内合法，否则默认 1（关闭）。 */
  renderScale(): number {
    const n = this.getNumber(KEY_RENDER_SCALE);
    return RENDER_SCALE_OPTIONS.indexOf(n) >= 0 ? n : RENDER_SCALE_DEFAULT;
  }

  setRenderScale(n: number): void {
    this.putNumber(KEY_RENDER_SCALE, n);
  }

  // ---- 微软登录 client_id（用户自填，不预置；主进程写、游戏进程读）----

  /** Azure 公有客户端 id；未设置 → 空串（微软登录不可用）。 */
  msClientId(): string {
    if (this.store === null) {
      return '';
    }
    try {
      return this.store.getSync(KEY_MS_CLIENT_ID, '') as string;
    } catch {
      return '';
    }
  }

  setMsClientId(v: string): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_MS_CLIENT_ID, v);
      this.store.flushSync();
    } catch {
      return;
    }
  }

  // ---- 版本下载源（下载面板写，安装时读）----

  /** 下载源；未设置 → 镜像（SOURCE_MIRROR）。 */
  downloadSource(): string {
    if (this.store === null) {
      return SOURCE_MIRROR;
    }
    try {
      const v = this.store.getSync(KEY_DOWNLOAD_SOURCE, SOURCE_MIRROR) as string;
      return v.length > 0 ? v : SOURCE_MIRROR;
    } catch {
      return SOURCE_MIRROR;
    }
  }

  setDownloadSource(source: string): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_DOWNLOAD_SOURCE, source);
      this.store.flushSync();
    } catch {
      return;
    }
  }

  // ---- 版本类型过滤（release / snapshot / other；下载面板写、读）----

  /** 版本类型过滤；未设置 → 正式版（release）。 */
  versionType(): string {
    if (this.store === null) {
      return TYPE_RELEASE;
    }
    try {
      const v = this.store.getSync(KEY_VERSION_TYPE, TYPE_RELEASE) as string;
      return v.length > 0 ? v : TYPE_RELEASE;
    } catch {
      return TYPE_RELEASE;
    }
  }

  setVersionType(type: string): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_VERSION_TYPE, type);
      this.store.flushSync();
    } catch {
      return;
    }
  }

  // ---- 逐版本渲染后端覆盖（主进程 UI 写，游戏进程 GameLauncher 读）----
  // 存 JSON 数组 [{id,backend}]；backend ∈ auto（推荐）/ openglv4 / gl4es。

  /** 全部覆盖条目；无记录/解析失败均返回空数组。 */
  rendererOverrides(): RendererOverride[] {
    if (this.store === null) {
      return [];
    }
    let raw = '';
    try {
      raw = this.store.getSync(KEY_RENDERER_OVERRIDES, '') as string;
    } catch {
      return [];
    }
    if (raw.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as RendererOverride[];
      if (!Array.isArray(arr)) {
        return [];
      }
      // 过滤掉旧版/损坏数据里 shape 不对的元素（缺 id/backend）。
      return arr.filter((o: RendererOverride) =>
        typeof o.id === 'string' && typeof o.backend === 'string');
    } catch {
      return [];
    }
  }

  /** 某版本的渲染后端；未设置 = auto（推荐按 MC 版本自动）。 */
  rendererOverride(versionId: string): string {
    for (const o of this.rendererOverrides()) {
      if (o.id === versionId) {
        return o.backend;
      }
    }
    return RENDERER_AUTO;
  }

  /** 写入某版本的渲染后端（auto = 清除覆盖）；立即落盘。 */
  setRendererOverride(versionId: string, backend: string): void {
    if (this.store === null || versionId.length === 0) {
      return;
    }
    const kept: RendererOverride[] =
      this.rendererOverrides().filter((o: RendererOverride) => o.id !== versionId);
    if (backend !== RENDERER_AUTO) {
      kept.push({ id: versionId, backend: backend });
    }
    try {
      this.store.putSync(KEY_RENDERER_OVERRIDES, JSON.stringify(kept));
      this.store.flushSync();
    } catch {
      return;
    }
  }

  private getNumber(key: string): number {
    if (this.store === null) {
      return 0;
    }
    try {
      return this.store.getSync(key, 0) as number;
    } catch {
      return 0;
    }
  }

  private putNumber(key: string, n: number): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(key, n);
      this.store.flushSync();
    } catch {
      return;
    }
  }
}
