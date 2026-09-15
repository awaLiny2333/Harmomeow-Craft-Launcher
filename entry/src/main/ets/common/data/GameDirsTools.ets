import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppDir, AppSettings, loadAppSettings, loadAppSettingsOrDefault, writeAppSettings,
  tryReadAppSettings, appSettingsFileExists } from './AppSettings';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameDirsTools';

/**
 * 可观察的游戏目录条目。
 *
 * 用 @ObservedV2 + @Trace 而不是普通 interface，是为了配合状态管理 V2：
 * 当 name / uri 属性被赋值时，UI 上所有读取了该属性的组件（例如 Repeat 中的
 * Text）会精确刷新，无需像 V1 那样把变化字段拼进 ForEach key 强制整行重建。
 *
 * 注意：本类实例只应作为"运行时数据"存在（list() 产出、UI 持有），
 * 不能直接 JSON.stringify 序列化——持久化统一经过 AppDir 普通对象。
 */
@ObservedV2
export class GameDir {
  /** 目录在系统中的唯一标识（file:// 开头的 URI），不可变，用作 Repeat key 与去重依据。 */
  @Trace uri: string;

  /** 用户可编辑的显示昵称。修改该属性会触发读取它的 UI 刷新。 */
  @Trace name: string;

  constructor(uri: string, name: string) {
    this.uri = uri;
    this.name = name;
  }
}

/**
 * 从目录 URI 提取默认昵称（URI 最后一个 '/' 之后的片段）。
 * Picker 返回的 URI 可能包含百分号转义（如 %20 表示空格），因此解码后再返回。
 * 解码失败时退回原始片段，保证任何 URI 都能得到一个可读的默认名。
 */
function defaultName(uri: string): string {
  const idx = uri.lastIndexOf('/');
  const base = idx >= 0 ? uri.substring(idx + 1) : uri;
  try {
    return decodeURIComponent(base);
  } catch {
    return base;
  }
}

/**
 * 游戏目录的持久化数据层（纯逻辑，不依赖 UI，因此内部不使用 $r）。
 *
 * 设计背景（鸿蒙文件访问限制）：
 * - Picker 选中的目录 URI 只带"临时授权"，App 退出后即失效；
 * - 因此本类只负责持久化"记住了哪些目录"及"上次选中的目录"，
 *   绝不持久化授权状态——需要使用时由 UI 层重新拉起授权 Picker。
 *
 * 存储介质（2026-09-15 起）：应用沙箱 `<filesDir>/meow-settings/app-settings.json`（见
 * `AppSettings.ets`），不再写 Preferences（Preferences 已彻底移除，无历史迁移）。
 */
export class GameDirsTools {
  /** 宿主上下文（解析应用沙箱路径）。 */
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 读取全部已记住的目录，并重建为可观察的 GameDir 实例列表。
   * 兜底逻辑：
   * - 文件缺失 / 读取失败 / JSON 损坏 → 返回空数组；
   * - 历史数据缺少 name（或为空串）→ 用 defaultName(uri) 补默认昵称。
   */
  list(): GameDir[] {
    const s = loadAppSettings(this.context);
    if (s === null) {
      return [];
    }
    return s.dirs.map((d: AppDir): GameDir => {
      const name = d.name && d.name.length > 0 ? d.name : defaultName(d.uri);
      return new GameDir(d.uri, name);
    });
  }

  /**
   * 将目录列表整体写盘（以磁盘现有 JSON 为底 merge，保留未知键）。
   * 若文件存在却读不出（坏 / 异格式），拒绝写入以避免把未知键删掉。
   */
  private save(s: AppSettings): void {
    if (this.readUnreadable()) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'app-settings.json unreadable; dirs not written');
      return;
    }
    if (!writeAppSettings(this.context, s)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write app-settings failed');
    }
  }

  /** 文件存在但解析不出（坏 / 异格式）→ 不允许覆盖。 */
  private readUnreadable(): boolean {
    return appSettingsFileExists(this.context) && tryReadAppSettings(this.context) === null;
  }

  /** 添加目录（自动生成默认昵称）。按 uri 去重，重复添加不生效。 */
  add(uri: string): void {
    const s = loadAppSettingsOrDefault(this.context);
    if (s === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings unreadable; dir not added');
      return;
    }
    if (!s.dirs.some((d: AppDir) => d.uri === uri)) {
      const entry: AppDir = { uri: uri, name: defaultName(uri) };
      s.dirs.push(entry);
      this.save(s);
    }
  }

  /** 按 uri 移除目录。uri 是唯一键；未命中且设置文件本就不存在时不落盘（不新建空 `app-settings.json`）。 */
  remove(uri: string): void {
    const s = loadAppSettingsOrDefault(this.context);
    if (s === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings unreadable; dir not removed');
      return;
    }
    const before = s.dirs.length;
    s.dirs = s.dirs.filter((d: AppDir) => d.uri !== uri);
    if (s.dirs.length === before && !appSettingsFileExists(this.context)) {
      // 未命中且文件不存在：无可写内容，跳过 save（避免为一次无效移除新建设置文件）。
      return;
    }
    this.save(s);
  }

  /**
   * 重命名目录昵称。
   * 空名（trim 后为空串）会被忽略以阻止存下无意义昵称；
   * 目标不存在时静默返回。
   */
  rename(uri: string, name: string): void {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    const s = loadAppSettingsOrDefault(this.context);
    if (s === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings unreadable; dir not renamed');
      return;
    }
    const target = s.dirs.find((d: AppDir) => d.uri === uri);
    if (target) {
      target.name = trimmed;
      this.save(s);
    }
  }

  /**
   * 读取上次选中的目录 URI。
   * 注意这是"纯记忆"：重启后即使能读回 URI，该目录的授权也随 App 退出失效，
   * 调用方仍需让用户重新授权后才可访问目录内容。
   */
  selected(): string {
    const s = loadAppSettings(this.context);
    return s === null ? '' : s.selectedDir;
  }

  /** 记录当前选中的目录 URI，供下次启动恢复（同 selected() 的"纯记忆"语义）。 */
  setSelected(uri: string): void {
    const s = loadAppSettingsOrDefault(this.context);
    if (s === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings unreadable; selected dir not written');
      return;
    }
    s.selectedDir = uri;
    this.save(s);
  }
}
