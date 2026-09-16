import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RENDERER_AUTO, RENDERER_ENV, RENDERER_ENV_GL4ES } from '../constants/LaunchDefaults';
import { versionDir } from '../constants/Paths';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'InstanceSettings';

/** 实例设置 dot-dir（实例目录内，随实例目录跨机迁移）。 */
const INSTANCE_SETTINGS_DIR: string = '.hmmcraft';

/** 逐实例**落盘物证目录**：`<dir>/.hmmcraft/logs`（本启动器与随包 JVM 共用）。
 *  目的：让**游戏目录（= 进程 cwd）保持干净**（铁律：不污染硬盘）。
 *  ⚠️ 返回**空串 = 建目录失败**（实例目录不可写等）。调用方**必须**退回沙箱目录，
 *  **绝不能**把 `-XX:ErrorFile` 指到不存在的路径——那时 JVM 会把 `hs_err_pid*.log` 静默写回
 *  cwd（即游戏目录），正是我们要消除的污染（见 notes `20-design/render/1.21.1-崩溃-两条链与随包规避.md`）。 */
export function ensureInstanceLogsDir(dir: string): string {
  const root = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  if (root.length === 0) {
    return '';
  }
  const logs = `${root}/${INSTANCE_SETTINGS_DIR}/logs`;
  try {
    fileIo.mkdirSync(logs, true);
    return logs;
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'mkdir %{public}s failed: %{public}s', logs, (e as BusinessError).message);
    return '';
  }
}
/** 实例设置文件名（一个文件装全部逐版本设置）。 */
const INSTANCE_SETTINGS_FILE: string = 'instance-settings.json';
/** 文件格式版本（plain JSON，不用 JSON Schema；与全局设置文件同一种约定）。 */
const INSTANCE_SETTINGS_FORMAT: number = 1;
/** 写入时用的临时文件后缀（同目录，写完 rename 原子替换）。 */
const INSTANCE_SETTINGS_TMP_SUFFIX: string = '.tmp';

/** 隔离标记键名 = HMCL 表示法：overrideProperties 含此键即隔离（也是 JSON 键名，契约勿改名）。 */
const KEY_RUNNING_DIRECTORY: string = 'runningDirectory';
/** overrideProperties 数组键名（保留其余未知项；契约勿改名）。 */
const KEY_OVERRIDE_PROPERTIES: string = 'overrideProperties';
/** 渲染后端覆盖键名。 */
const KEY_RENDERER_BACKEND: string = 'hmmcraftRendererBackend';
/** 线程化渲染键名（仅显式 false 才写）。 */
const KEY_GL_THREAD: string = 'hmmcraftGlThreadEnabled';
/** GL_ARB_compute_shader 屏蔽键名（**仅显式 false 才写**：默认 = 屏蔽该能力，与 glthread 同构）。 */
const KEY_COMPUTE_SHADER: string = 'hmmcraftComputeShaderMasked';

/** 逐版本渲染后端覆盖条目（编辑面板镜像用；与实例文件同源）。 */
export interface RendererOverride {
  id: string;
  backend: string;
}

/** 磁盘上实例设置文件的形状（只读解析用；稀疏，缺键 = 默认值）。 */
interface InstanceSettingsJson {
  format?: number;
  overrideProperties?: string[];
  runningDirectory?: string;
  hmmcraftRendererBackend?: string;
  hmmcraftGlThreadEnabled?: boolean;
  hmmcraftComputeShaderMasked?: boolean;
}

/**
 * 单个实例（版本）的设置（纯数据）。
 *
 * 存 `<gameRoot>/versions/<id>/.hmmcraft/instance-settings.json`：设置**跟着实例目录走**，
 * 跨机迁移/拷贝实例时一起带走；也天然按"目录 + 实例名"区分，不同游戏目录下的同名实例不再撞键
 * （旧实现只按实例 id 存在 Preferences，跨 .minecraft 根同名会互相覆盖）。
 */
export class InstanceSettings {
  /** 是否启用版本隔离（开 → 运行目录 = versions/<id>）。 */
  isolation: boolean;
  /** 渲染后端：auto / openglv4 / gl4es（用 LaunchDefaults 常量）。 */
  rendererBackend: string;
  /** 是否启用线程化渲染（glthread，默认开）。 */
  glThreadEnabled: boolean;
  /** 是否**屏蔽** GL_ARB_compute_shader（**默认开**；关掉 = 允许使用该能力，见 notes §6 操作规范）。 */
  computeShaderMasked: boolean;

  constructor(isolation: boolean, rendererBackend: string, glThreadEnabled: boolean,
    computeShaderMasked: boolean) {
    this.isolation = isolation;
    this.rendererBackend = rendererBackend;
    this.glThreadEnabled = glThreadEnabled;
    this.computeShaderMasked = computeShaderMasked;
  }

  /**
   * 默认值工厂（**隔离开** / 后端 auto / glthread 开 / **compute 关**）。
   *
   * 隔离默认**开**是三态语义的一半（用户 2026-09-15 定）：**没有设置文件 = 从未配置 → 取默认（开）**；
   * 文件存在但 `overrideProperties` **不含** `runningDirectory` = **显式关**。所以"关"必须落盘才算数
   * （关隔离时只写 `format`，文件存在本身即"已配置为关"）。
   *
   * compute 默认**屏蔽**（表里即默认开）：本机 GPU 驱动编译 compute 着色器不稳会崩，只有用户显式关掉才不屏蔽。
   */
  static defaults(): InstanceSettings {
    return new InstanceSettings(true, RENDERER_AUTO, true, true);
  }
}

/** `<gameRoot>/versions/<id>/.hmmcraft/instance-settings.json`。 */
export function instanceSettingsPath(gameRoot: string, id: string): string {
  return `${versionDir(gameRoot, id)}/${INSTANCE_SETTINGS_DIR}/${INSTANCE_SETTINGS_FILE}`;
}

/**
 * 读某实例的设置。文件缺失 / 解析失败 / `format` 存在且 ≠1 → 一律**默认值（隔离开）**，且**不覆盖**
 * 原文件（读失败只记日志；旧 Preferences 键已直接弃用，不做迁移）。`format` **缺失** → 宽容按 1 处理
 * （旧 `$schema` 形态的文件无 `format` 键，仍能读出）。
 *
 * 隔离三态：**无文件 → 默认（开）**；有文件且含 `runningDirectory` → 开；有文件但不含 → **显式关**。
 */
export function readInstanceSettings(gameRoot: string, id: string): InstanceSettings {
  const path = instanceSettingsPath(gameRoot, id);
  let text = '';
  try {
    text = fileIo.readTextSync(path);
  } catch {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'no settings file for %{public}s (use defaults)', id);
    return InstanceSettings.defaults();
  }
  try {
    const raw = JSON.parse(text) as InstanceSettingsJson;
    if (raw.format !== undefined && raw.format !== INSTANCE_SETTINGS_FORMAT) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unrecognized format for %{public}s (use defaults)', id);
      return InstanceSettings.defaults();
    }
    // 隔离 = 对齐 HMCL 表示法：overrideProperties 含 "runningDirectory"。
    const overrides: string[] = Array.isArray(raw.overrideProperties) ? raw.overrideProperties : [];
    const isolated = overrides.includes(KEY_RUNNING_DIRECTORY);
    // 后端：只认已知的显式覆盖值，其余（含缺失）→ auto（推荐）。
    let backend = RENDERER_AUTO;
    if (raw.hmmcraftRendererBackend === RENDERER_ENV || raw.hmmcraftRendererBackend === RENDERER_ENV_GL4ES) {
      backend = raw.hmmcraftRendererBackend;
    }
    // glthread：默认开，只有显式 false 才关。
    const glThread = raw.hmmcraftGlThreadEnabled === false ? false : true;
    // compute：默认**屏蔽**（与 glthread 的"默认开、显式关"同构 —— 只有显式 false 才关屏蔽）。
    const computeShader = raw.hmmcraftComputeShaderMasked === false ? false : true;
    return new InstanceSettings(isolated, backend, glThread, computeShader);
  } catch {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'parse failed for %{public}s (use defaults)', id);
    return InstanceSettings.defaults();
  }
}

/** 写入前把渲染后端夹到合法集合（非法值按 auto 处理）。 */
function normalizeRendererBackend(backend: string): string {
  if (backend === RENDERER_ENV || backend === RENDERER_ENV_GL4ES) {
    return backend;
  }
  return RENDERER_AUTO;
}

/** 从底稿对象读 overrideProperties（缺键 / 非数组 → 空数组；保留其中全部已知与未知项）。 */
function readOverrideProperties(src: Record<string, Object | undefined>): string[] {
  const raw = src[KEY_OVERRIDE_PROPERTIES];
  const out: string[] = [];
  if (Array.isArray(raw)) {
    const arr = raw as Object[];
    for (const item of arr) {
      if (typeof item === 'string') {
        out.push(item as string);
      }
    }
  }
  return out;
}

/**
 * 写前可读性门禁：目标文件**不存在**（或为**空 / 纯空白**文件，按"不存在"放行）→ 允许写（首次写入，返回 true）；
 * **存在但读不出**（读失败 / JSON 坏 / 根非对象 / `format` 存在且 ≠1）→ **拒绝写**（返回 false）——
 * 绝不用默认对象覆盖磁盘上未知内容。先用 `accessSync` 区分"缺失"与"读失败"，再逐层校验。
 */
function instanceSettingsFileReadable(target: string): boolean {
  let onDisk = false;
  try {
    onDisk = fileIo.accessSync(target);
  } catch {
    // 存在性都判不出（路径异常等）→ 按"不存在"放行，让后续写入流程给出真实错误
    return true;
  }
  if (!onDisk) {
    return true;
  }
  let text = '';
  try {
    text = fileIo.readTextSync(target);
  } catch {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'instance-settings exists but unreadable at %{public}s; not written', target);
    return false;
  }
  if (text.trim().length === 0) {
    // 空 / 纯空白文件：内容为空即无未知内容可保护 → 按"不存在"放行（可写）。
    return true;
  }
  try {
    const parsed = JSON.parse(text) as Record<string, Object | undefined>;
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'instance-settings unreadable (bad root) at %{public}s; not written', target);
      return false;
    }
    const fmt = (parsed as InstanceSettingsJson).format;
    if (fmt !== undefined && fmt !== INSTANCE_SETTINGS_FORMAT) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'instance-settings unknown format %{public}s at %{public}s; not written', `${fmt}`, target);
      return false;
    }
    return true;
  } catch {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'instance-settings exists but unreadable at %{public}s; not written', target);
    return false;
  }
}

/**
 * 写某实例的设置（**稀疏**：值为默认的键不写；`format` 总写），返回是否成功。
 *
 * **存在但读不出**（坏 / 异格式）→ 先过 `instanceSettingsFileReadable` 门禁拒写（绝不覆盖）。
 * 以磁盘上现有 JSON 为**底稿合并**：本启动器不认识的键、以及 `overrideProperties` 里
 * `runningDirectory` 之外的项都原样保留；同时**显式移除**遗留的 `$schema` 键（统一为纯 `format` 约定）。
 * 落盘：`mkdirSync(..., true)` 建目录 → 先写同目录临时文件 `.tmp` → **先尝试直接 `renameSync(tmp, target)`
 * 覆盖**（平台允许时原子替换、无空窗）；仅当它抛错（平台不允覆盖已存在目标）才 `removeQuietly(target)`
 * 再 rename。两步都失败则**保留 tmp**（下次可救）并记 error，不静默删 tmp。
 */
export function writeInstanceSettings(gameRoot: string, id: string, data: InstanceSettings): boolean {
  const target = instanceSettingsPath(gameRoot, id);
  const dirPath = `${versionDir(gameRoot, id)}/${INSTANCE_SETTINGS_DIR}`;
  try {
    fileIo.mkdirSync(dirPath, true);
  } catch {
    // 目录已存在
  }
  // 门禁：文件存在但读不出（坏 / 异格式）→ 拒写，绝不用默认对象覆盖。
  if (!instanceSettingsFileReadable(target)) {
    return false;
  }
  // 底稿：磁盘现有 JSON（不存在 → 空对象起底；能走到这里说明文件不存在或可解析）。
  let base: Record<string, Object | undefined> = {};
  try {
    const existing = fileIo.readTextSync(target);
    const parsed = JSON.parse(existing) as Record<string, Object | undefined>;
    if (parsed !== null && parsed !== undefined) {
      base = parsed;
    }
  } catch {
    // 文件缺失：以空对象起底
  }
  base[KEY_RUNNING_DIRECTORY] = undefined;
  base[KEY_RENDERER_BACKEND] = undefined;
  base[KEY_GL_THREAD] = undefined;
  base[KEY_COMPUTE_SHADER] = undefined;
  const props = readOverrideProperties(base);
  if (data.isolation) {
    // 开隔离：确保 overrideProperties **含** runningDirectory（保留其余项）。
    if (!props.includes(KEY_RUNNING_DIRECTORY)) {
      props.push(KEY_RUNNING_DIRECTORY);
    }
    base[KEY_OVERRIDE_PROPERTIES] = props;
    base[KEY_RUNNING_DIRECTORY] = `versions/${id}`;
  } else {
    // 关隔离：移除 runningDirectory；集合空了就删该键。
    const kept = props.filter((p: string) => p !== KEY_RUNNING_DIRECTORY);
    base[KEY_OVERRIDE_PROPERTIES] = kept.length > 0 ? kept : undefined;
  }
  const backend = normalizeRendererBackend(data.rendererBackend);
  base[KEY_RENDERER_BACKEND] = backend !== RENDERER_AUTO ? backend : undefined;
  base[KEY_GL_THREAD] = data.glThreadEnabled ? undefined : false;
  // compute：默认**屏蔽**（与 glthread 同构）⇒ 只在"用户显式关掉屏蔽"时才写键（缺键 = 按默认屏蔽 ✓）。
  base[KEY_COMPUTE_SHADER] = data.computeShaderMasked ? undefined : false;
  base['$schema'] = undefined;
  base['format'] = INSTANCE_SETTINGS_FORMAT;
  // 写**多行缩进**（2 空格）：实例设置文件会跟着实例目录走、可能被用户直接看/改，可读性优先。
  const text = JSON.stringify(base, null, 2);
  const tmp = `${target}${INSTANCE_SETTINGS_TMP_SUFFIX}`;
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
    hilog.error(LOG_DOMAIN, LOG_TAG, 'write tmp failed for %{public}s: %{public}s',
      id, (e as BusinessError).message);
    return false;
  }
  // 先尝试直接覆盖（允许覆盖的平台原子替换、无空窗）；仅当不允覆盖已存在目标时，才删目标再 rename。
  try {
    fileIo.renameSync(tmp, target);
    return true;
  } catch {
    try {
      removeQuietly(target);
      fileIo.renameSync(tmp, target);
      return true;
    } catch (secondErr) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write failed for %{public}s (tmp kept): %{public}s',
        id, (secondErr as BusinessError).message);
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
