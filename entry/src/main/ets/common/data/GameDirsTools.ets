import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { STORE_NAME, KEY_DIRS, KEY_SELECTED } from '../constants/Constants';

/**
 * 可观察的游戏目录条目。
 *
 * 用 @ObservedV2 + @Trace 而不是普通 interface，是为了配合状态管理 V2：
 * 当 name / uri 属性被赋值时，UI 上所有读取了该属性的组件（例如 Repeat 中的
 * Text）会精确刷新，无需像 V1 那样把变化字段拼进 ForEach key 强制整行重建。
 *
 * 注意：本类实例只应作为"运行时数据"存在（list() 产出、UI 持有），
 * 不能直接 JSON.stringify 序列化——见下方 GameDirData 的说明。
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
 * 序列化用的普通数据结构。
 *
 * 为什么需要它：@Trace 装饰的属性在编译后以访问器（getter/setter）形式存在，
 * 默认不可枚举，导致 JSON.stringify 拿不到这些字段。因此持久化 / 反序列化时
 * 统一经过 { uri, name } 普通对象，禁止直接对 GameDir 实例做 JSON 操作。
 */
interface GameDirData {
  uri: string;
  name: string;
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
 * 存储介质：Preferences（@kit.ArkData），键名集中在 Constants.ets。
 * 写入规则：putSync 只更新内存缓存，必须紧跟 flushSync() 才会落盘，
 * 否则 App 重启后数据丢失（官方文档明确标注的坑）。
 */
export class GameDirsTools {
  /** Preferences 实例。构造失败（如目录不可写）时为 null，后续所有方法都需判空兜底。 */
  private store: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch {
      // 初始化失败时保持 null，让上层以"空列表"降级运行，而不是抛异常。
      this.store = null;
    }
  }

  /**
   * 读取全部已记住的目录，并重建为可观察的 GameDir 实例列表。
   * 兜底逻辑：
   * - Preferences 不可用 / 读取失败 / JSON 损坏 → 返回空数组；
   * - 历史数据缺少 name（或为空串）→ 用 defaultName(uri) 补默认昵称。
   */
  list(): GameDir[] {
    if (this.store === null) {
      return [];
    }
    let raw = '[]';
    try {
      raw = this.store.getSync(KEY_DIRS, '[]') as string;
    } catch {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as GameDirData[];
      return arr.map((d: GameDirData): GameDir => {
        const name = d.name && d.name.length > 0 ? d.name : defaultName(d.uri);
        return new GameDir(d.uri, name);
      });
    } catch {
      // JSON 结构不符预期（例如被旧版本写成纯字符串数组）时丢弃，视为空。
      return [];
    }
  }

  /**
   * 将目录列表整体写盘。
   * 先 map 成 GameDirData 普通对象再 stringify（原因见 GameDirData 注释），
   * putSync 后立即 flushSync 落盘。
   */
  private save(dirs: GameDir[]): void {
    if (this.store === null) {
      return;
    }
    const data: GameDirData[] = dirs.map((d: GameDir): GameDirData => ({ uri: d.uri, name: d.name }));
    try {
      this.store.putSync(KEY_DIRS, JSON.stringify(data));
      this.store.flushSync();
    } catch {
      // 写入失败静默忽略：属于尽力而为的持久化，失败不应中断用户操作。
      return;
    }
  }

  /** 添加目录（自动生成默认昵称）。按 uri 去重，重复添加不生效。 */
  add(uri: string): void {
    const dirs = this.list();
    if (!dirs.some((d) => d.uri === uri)) {
      dirs.push(new GameDir(uri, defaultName(uri)));
      this.save(dirs);
    }
  }

  /** 按 uri 移除目录。uri 是唯一键，未命中时 save 原列表（无副作用）。 */
  remove(uri: string): void {
    this.save(this.list().filter((d) => d.uri !== uri));
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
    const dirs = this.list();
    const target = dirs.find((d) => d.uri === uri);
    if (target) {
      target.name = trimmed;
      this.save(dirs);
    }
  }

  /**
   * 读取上次选中的目录 URI。
   * 注意这是"纯记忆"：重启后即使能读回 URI，该目录的授权也随 App 退出失效，
   * 调用方仍需让用户重新授权后才可访问目录内容。
   */
  selected(): string {
    if (this.store === null) {
      return '';
    }
    try {
      return this.store.getSync(KEY_SELECTED, '') as string;
    } catch {
      return '';
    }
  }

  /** 记录当前选中的目录 URI，供下次启动恢复（同 selected() 的"纯记忆"语义）。 */
  setSelected(uri: string): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(KEY_SELECTED, uri);
      this.store.flushSync();
    } catch {
      return;
    }
  }
}
