import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalSettings, GlobalSettingsJson, buildGlobalNode, parseGlobalNode }
  from './GlobalSettings';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'AppSettings';

/** 应用级设置目录（应用沙箱 filesDir 内，外部不可见；导出是唯一取出口）。 */
export const APP_SETTINGS_DIR: string = 'meow-settings';
/** 目录枚举 + 选中指针 + 全局设置文件名（一个文件装这些）。 */
const APP_SETTINGS_FILE: string = 'app-settings.json';
/** 账户列表文件名（含微软 token，导出时须告警）。 */
const ACCOUNTS_FILE: string = 'accounts.json';
/** 文件格式版本（plain JSON，不用 JSON Schema；`format` 总写）。 */
const APP_SETTINGS_FORMAT: number = 1;
/** 写入时用的临时文件后缀（同目录，写完 rename 原子替换）。 */
const APP_SETTINGS_TMP_SUFFIX: string = '.tmp';
/** 导出子目录前缀（避免覆盖目标目录里已有文件）。 */
const BACKUP_DIR_PREFIX: string = 'meow-settings-backup-';

/** 目录条目（普通数据，可安全 JSON 序列化）。 */
export interface AppDir {
  uri: string;
  name: string;
}

/** 应用级设置（目录列表 + 最后选中目录 + 最后选中账户 id + 应用级全局设置）。 */
export interface AppSettings {
  dirs: AppDir[];
  selectedDir: string;
  selectedAccount: string;
  global: GlobalSettings;
}

/** 空设置（各字段默认值）。 */
export function emptyAppSettings(): AppSettings {
  return {
    dirs: [],
    selectedDir: '',
    selectedAccount: '',
    global: GlobalSettings.defaults(),
  };
}

/** `<filesDir>/meow-settings/`。 */
export function appSettingsDir(ctx: common.Context): string {
  return `${ctx.filesDir}/${APP_SETTINGS_DIR}`;
}

/** `<filesDir>/meow-settings/app-settings.json`。 */
export function appSettingsPath(ctx: common.Context): string {
  return `${appSettingsDir(ctx)}/${APP_SETTINGS_FILE}`;
}

/** `<filesDir>/meow-settings/accounts.json`。 */
export function accountsPath(ctx: common.Context): string {
  return `${appSettingsDir(ctx)}/${ACCOUNTS_FILE}`;
}

/** 文件是否存在且**非空**（空 / 纯空白按"缺失"处理；用于区分"缺失"与"存在但读不出"）。 */
export function appSettingsFileExists(ctx: common.Context): boolean {
  return existsNonEmpty(appSettingsPath(ctx));
}

/** 文件是否存在且**非空**（空 / 纯空白按"缺失"处理；用于区分"缺失"与"存在但读不出"）。 */
export function accountsFileExists(ctx: common.Context): boolean {
  return existsNonEmpty(accountsPath(ctx));
}

/** 磁盘上 app-settings.json 的形状（只读解析用；缺键 = 默认值）。 */
interface AppSettingsJson {
  format?: number;
  dirs?: AppDirJson[];
  selectedDir?: string;
  selectedAccount?: string;
  global?: GlobalSettingsJson;
}

interface AppDirJson {
  uri?: string;
  name?: string;
}

/** 磁盘上 accounts.json 的形状（只读解析用）。 */
interface AccountsJson {
  format?: number;
  accounts?: Object[];
}

/**
 * 读应用级设置。**读不到返回 `null`**（文件缺失 / 空文件 / 读失败 / JSON 坏 / `format` 存在且 ≠1），
 * 与"读到但内容为空（dirs=[]、选中为空、global 全默认）"区分；`format` 缺失宽容按 1。
 * 空 / 纯空白文件按**缺失**处理（同样返回 `null`，语义=缺失、可写，不再锁死写入通道）。
 */
export function tryReadAppSettings(ctx: common.Context): AppSettings | null {
  const text = readSettingsText(appSettingsPath(ctx));
  if (text === null) {
    return null;
  }
  let raw: AppSettingsJson;
  try {
    raw = JSON.parse(text) as AppSettingsJson;
  } catch {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'parse app-settings.json failed');
    return null;
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return null;
  }
  if (raw.format !== undefined && raw.format !== APP_SETTINGS_FORMAT) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown app-settings format %{public}s', `${raw.format}`);
    return null;
  }
  const s = emptyAppSettings();
  if (Array.isArray(raw.dirs)) {
    for (const d of raw.dirs) {
      if (d !== null && d !== undefined && typeof d.uri === 'string' && d.uri.length > 0) {
        s.dirs.push({ uri: d.uri, name: typeof d.name === 'string' ? d.name : '' });
      }
    }
  }
  s.selectedDir = typeof raw.selectedDir === 'string' ? raw.selectedDir : '';
  s.selectedAccount = typeof raw.selectedAccount === 'string' ? raw.selectedAccount : '';
  s.global = parseGlobalNode(raw.global);
  return s;
}

/**
 * 读账户列表。**读不到返回 `null`**（文件缺失 / 空文件 / 读失败 / JSON 坏 / `format` 存在且 ≠1），
 * 与"读到但 `accounts` 为空数组"区分；`format` 缺失宽容按 1。
 * 空 / 纯空白文件按**缺失**处理（同样返回 `null`，语义=缺失、可写，不再锁死写入通道）。
 */
export function tryReadAccounts<T>(ctx: common.Context): T[] | null {
  const text = readSettingsText(accountsPath(ctx));
  if (text === null) {
    return null;
  }
  let raw: AccountsJson;
  try {
    raw = JSON.parse(text) as AccountsJson;
  } catch {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'parse accounts.json failed');
    return null;
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return null;
  }
  if (raw.format !== undefined && raw.format !== APP_SETTINGS_FORMAT) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown accounts format %{public}s', `${raw.format}`);
    return null;
  }
  if (!Array.isArray(raw.accounts)) {
    return [];
  }
  return toTypedList<T>(raw.accounts);
}

/** 读应用级设置；**读不到返回 `null`**（文件缺失 / 坏 / 异格式）。无历史迁移。 */
export function loadAppSettings(ctx: common.Context): AppSettings | null {
  return tryReadAppSettings(ctx);
}

/** 读账户列表；**读不到返回 `null`**（文件缺失 / 坏 / 异格式）。无历史迁移。 */
export function loadAccounts<T>(ctx: common.Context): T[] | null {
  return tryReadAccounts<T>(ctx);
}

/** 读应用级设置；文件**缺失**（含空 / 纯空白文件）→ 返回空设置（可安全作为写入起点）；**存在但读不出** → 返回 `null`（拒写护栏）。 */
export function loadAppSettingsOrDefault(ctx: common.Context): AppSettings | null {
  const s = tryReadAppSettings(ctx);
  if (s !== null) {
    return s;
  }
  return appSettingsFileExists(ctx) ? null : emptyAppSettings();
}

/**
 * 写应用级设置（以磁盘现有 JSON 为底 merge，保留未知键），返回是否成功。
 * `global` 段同样稀疏组装并保留其未知键。
 * 落盘：建目录 → 写同目录 `.tmp` → 先试 `renameSync` 直接覆盖，不允覆盖才 unlink 再 rename；
 * 两步皆败则保留 tmp 并记 error。
 */
export function writeAppSettings(ctx: common.Context, s: AppSettings): boolean {
  const base = readBase(appSettingsPath(ctx));
  base['format'] = APP_SETTINGS_FORMAT;
  base['dirs'] = s.dirs.map((d: AppDir): AppDir => ({ uri: d.uri, name: d.name }));
  base['selectedDir'] = s.selectedDir;
  base['selectedAccount'] = s.selectedAccount;
  base['global'] = buildGlobalNode(s.global, base['global']);
  return writeJsonAtomic(appSettingsDir(ctx), appSettingsPath(ctx), base);
}

/** 写账户列表（以磁盘现有 JSON 为底 merge，保留未知键），返回是否成功。 */
export function writeAccounts<T>(ctx: common.Context, accounts: T[]): boolean {
  const base = readBase(accountsPath(ctx));
  base['format'] = APP_SETTINGS_FORMAT;
  base['accounts'] = accounts;
  return writeJsonAtomic(appSettingsDir(ctx), accountsPath(ctx), base);
}

/**
 * 尝试读应用级全局设置。**读不到就返回 `null`**（`app-settings.json` 缺失 / 读失败 / JSON 坏 /
 * `format` 存在且 ≠1），读不到时**绝不回写**；文件在但无 `global` 段 → 返回默认对象（非 null）。
 *
 * 为什么要与"读到了、但内容就是默认值"区分：`SettingsTools` 会缓存结果，若把"读不到"也当成
 * 默认值缓存，后续真正写入前的重读仍会命中缓存里的默认值。
 */
export function tryReadAppGlobalSettings(ctx: common.Context): GlobalSettings | null {
  const s = loadAppSettings(ctx);
  return s !== null ? s.global : null;
}

/** 读应用级全局设置；**读不到 → 默认值**。不需要区分"读到了没有"的调用方用这个（如 `:game` 进程）。 */
export function readAppGlobalSettings(ctx: common.Context): GlobalSettings {
  const s = tryReadAppGlobalSettings(ctx);
  return s !== null ? s : GlobalSettings.defaults();
}

/**
 * 写应用级全局设置（**稀疏**；以磁盘现有 JSON 为底 merge，保留未知键），返回是否成功。
 * 文件缺失 → 以空设置起底；**文件在但读不出**（坏 / 异格式）→ 拒写（否则会把磁盘上其它键删掉）。
 */
export function writeAppGlobalSettings(ctx: common.Context, data: GlobalSettings): boolean {
  let s = loadAppSettings(ctx);
  if (s === null) {
    if (appSettingsFileExists(ctx)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'app-settings.json exists but unreadable; global not written');
      return false;
    }
    s = emptyAppSettings();
  }
  s.global = data;
  if (!writeAppSettings(ctx, s)) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'write app global settings failed');
    return false;
  }
  return true;
}

/** 导出结果：`outDir` 为 `null` = 整体失败（两份皆缺 / 皆读不出 / 目标非法 / 写盘失败）；`skipped` = 存在但读不出、被跳过的文件名。 */
export interface ExportResult {
  outDir: string | null;
  skipped: string[];
}

/**
 * 导出设置 JSON 到用户选择目录下的 `meow-settings-backup-<yyyyMMdd-HHmmss>/`。
 * **原文拷贝**：直接读磁盘上两份 JSON 原文（不经对象重建），解析后经 `writeJsonAtomic` 原样写出
 * （保持多行缩进与未知键）——哪份存在导哪份，缺 `accounts.json` 不影响 `app-settings.json` 导出；
 * **单份存在但读不出**（坏 / 异格式）→ 计入 `skipped` 并跳过该份；两份都缺失（或都读不出）→
 * `outDir` 为 `null`（调用方给可读错误）。一次性导出，不持久化授权。
 */
export function exportSettings(ctx: common.Context, targetDirUri: string): ExportResult {
  const skipped: string[] = [];
  const basePath = userFileUriToPath(targetDirUri);
  if (basePath.length === 0) {
    return { outDir: null, skipped };
  }
  const appPath = appSettingsPath(ctx);
  const acctPath = accountsPath(ctx);
  const appRaw = readSettingsFileRaw(appPath);
  const accountsRaw = readSettingsFileRaw(acctPath);
  // 存在但读不出（坏 / 异格式）→ 记入 skipped，导出时跳过该份（文件缺失不算 skipped）。
  if (appRaw === null && existsNonEmpty(appPath)) {
    skipped.push(APP_SETTINGS_FILE);
  }
  if (accountsRaw === null && existsNonEmpty(acctPath)) {
    skipped.push(ACCOUNTS_FILE);
  }
  if (appRaw === null && accountsRaw === null) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'export aborted: no settings files on disk');
    return { outDir: null, skipped };
  }
  const outDir = `${basePath}/${BACKUP_DIR_PREFIX}${timestamp()}`;
  if (appRaw !== null && !writeJsonAtomic(outDir, `${outDir}/${APP_SETTINGS_FILE}`, appRaw)) {
    return { outDir: null, skipped };
  }
  if (accountsRaw !== null && !writeJsonAtomic(outDir, `${outDir}/${ACCOUNTS_FILE}`, accountsRaw)) {
    return { outDir: null, skipped };
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'settings exported to %{public}s', outDir);
  return { outDir, skipped };
}

/** 读磁盘 JSON 原文并解析为对象（未知键随对象原样保留）；缺失 / 空文件 / 读失败 / 解析失败 / 根非对象 → null。 */
function readSettingsFileRaw(path: string): Record<string, Object | undefined> | null {
  const text = readSettingsText(path);
  if (text === null) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as Record<string, Object | undefined>;
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s has non-object root; skipped in export', path);
      return null;
    }
    return parsed;
  } catch {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'parse %{public}s failed; skipped in export', path);
    return null;
  }
}

/** 读文件全文；读失败或**空 / 纯空白** → `null`（空文件按"缺失"处理，语义=缺失、可写）。 */
function readSettingsText(path: string): string | null {
  try {
    const text = fileIo.readTextSync(path);
    return text.trim().length === 0 ? null : text;
  } catch {
    return null;
  }
}

/** 文件是否存在且非空（空 / 纯空白视作不存在；异常一律视作不存在）。 */
function existsNonEmpty(path: string): boolean {
  try {
    if (!fileIo.accessSync(path)) {
      return false;
    }
    return fileIo.readTextSync(path).trim().length > 0;
  } catch {
    return false;
  }
}

/** 把 `Object[]` 逐项断言为 `T[]`（调用方负责校验字段）。 */
function toTypedList<T>(arr: Object[]): T[] {
  const out: T[] = [];
  for (const item of arr) {
    out.push(item as T);
  }
  return out;
}

/** 读磁盘现有 JSON 作为合并底稿（不存在 / 解析失败 → 空对象）。 */
function readBase(target: string): Record<string, Object | undefined> {
  try {
    const text = fileIo.readTextSync(target);
    const parsed = JSON.parse(text) as Record<string, Object | undefined>;
    if (parsed !== null && parsed !== undefined) {
      return parsed;
    }
  } catch {
    // 文件缺失或损坏：以空对象起底
  }
  return {};
}

/**
 * 原子写 JSON：建目录 → 写 `.tmp` → 先试 `renameSync` 直接覆盖；不允覆盖已存在目标时
 * unlink 再 rename；两步皆败保留 tmp 并记 error。
 */
function writeJsonAtomic(dir: string, target: string,
  obj: Record<string, Object | undefined>): boolean {
  try {
    fileIo.mkdirSync(dir, true);
  } catch {
    // 目录已存在
  }
  // 写**多行缩进**（2 空格）而非单行：这些文件是给用户看/备份/手改的，可读性优先；
  // 格式化后的 JSON 仍是合法 JSON，读取端（JSON.parse）与平台 JSON 工具都认。
  const text = JSON.stringify(obj, null, 2);
  const tmp = `${target}${APP_SETTINGS_TMP_SUFFIX}`;
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
    hilog.error(LOG_DOMAIN, LOG_TAG, 'write tmp failed at %{public}s: %{public}s',
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
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write failed at %{public}s (tmp kept): %{public}s',
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

/** 把用户目录 URI（file://docs/...）转成可传给 fileIo 的物理路径；非法 → 空串。 */
function userFileUriToPath(uri: string): string {
  try {
    return new fileUri.FileUri(uri).path;
  } catch {
    return '';
  }
}

/** 两位补零。 */
function two(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** `yyyyMMdd-HHmmss`（本地时间）。 */
function timestamp(): string {
  const d = new Date();
  return `${d.getFullYear()}${two(d.getMonth() + 1)}${two(d.getDate())}-` +
    `${two(d.getHours())}${two(d.getMinutes())}${two(d.getSeconds())}`;
}
