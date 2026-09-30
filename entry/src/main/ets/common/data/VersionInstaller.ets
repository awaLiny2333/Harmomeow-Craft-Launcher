import { appManager, common, contextConstant, StartOptions, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_LIBRARY_URL, DOWNLOAD_CONCURRENCY, ENV_OS_ARCH, ENV_OS_BITS, ENV_OS_NAME,
  FABRIC_MAVEN, HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_NOT_FOUND,
  LEGACY_INDEX_URL_PREFIX, MOJANG_RESOURCES, NEOFORGE_RELEASES, SOURCE_OFFICIAL,
  fabricLaunchMetaCandidates, fabricLoaderListCandidates, fileCandidates, forgeBmclListUrl,
  forgeInstallerCandidates, forgeMetadataCandidates, manifestCandidates,
  neoforgeInstallerCandidates } from '../constants/DownloadContract';
import { ASSET_HASH_PREFIX_LENGTH, assetObjectPath, assetsIndexesDir, FORGE_INSTALLER_DIR, librariesDir,
  NEO_INSTALLER_DIR, NEO_JVM_RESULT, NEO_JVM_TOOL_LOG, versionDir, versionJarPath,
  versionJsonPath } from '../constants/Paths';
import { NEO_INSTALL_ABILITY, NEO_INSTALL_PROCESS_SUFFIX } from '../constants/LaunchContract';
// 工具 JVM 的平台伪装前缀（**与游戏启动路径同源**的唯一事实源）：定义处是 `LaunchDefaults.ets`
// 的 `TOOL_JVM_PLATFORM_SPOOF_ARGS`（内含 `SPOOF_OS_NAME` / `SPOOF_OS_VERSION`；游戏侧用法见
// `MinecraftLauncher.buildLaunchArgv`）。Forge（`runForgeProcessors`）与 NeoForge
// （`runNeoForgeProcessors`）两处工具 JVM 的 argv 都复用本前缀——工具 JVM 与游戏 JVM 必须伪装成同一个平台。
import { TOOL_JVM_PLATFORM_SPOOF_ARGS } from '../constants/LaunchDefaults';
import { buildNeoForgeProcessorPlans, libraryNames, NeoForgeExpandContext, NeoForgeInstallProfileJson,
  NeoForgeLaunchJson, NeoForgeMergeModuleEntry, NeoForgeProcessorJob, NeoForgeProcessorPlan,
  NeoForgeProcessorSet, resolveMergeModuleEntries, stringArgs } from './NeoForgeInstaller';
// Forge 新格式安装器（1.13–1.20.1）的**独立**数据层：类型 / 占位符展开 / processor 计划 / `outputs` 幂等判定。
// 刻意不复用 `NeoForgeInstaller` 的符号（方案 B：两侧实现独立，避免语义/生命周期互相绑死）。
import { buildForgeProcessorPlans, ForgeExpandContext, ForgeNewInstallProfileJson, ForgeProcessorJob,
  ForgeProcessorPlan, ForgeProcessorSet, forgeOutputsAllMatch, forgeRemoveStaleOutputs,
  forgeVerifyOutputsOrThrow } from './ForgeNewInstaller';
import { removeTreeBestEffort } from './VersionTools';
import { compareVersionIds } from './VersionScanner';
import { downloadFile, fetchText } from './Downloader';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'VersionInstaller';

/**
 * 原版版本安装器（数据层，纯逻辑 + 落盘；不含 UI）。
 *
 * 目标：把某个原版版本"完整地"装进 .minecraft —— 与 HMCL/官方布局一致：
 *   versions/<id>/{<id>.json,<id>.jar}
 *   libraries/<maven 路径>
 *   assets/indexes/<assetId>.json + assets/objects/<2>/<hash>
 *
 * 复刻 HMCL 行为（不因 Meowcraft 自己不用就跳过）：natives classifier jar 与 org.lwjgl 库
 * 一如下载；能否在本机加载是启动期的事，与安装无关。
 *
 * 并发与幂等：文件级并发下载；目标文件已存在即跳过；新下载的文件做 sha1 校验。
 */

/** 远程版本（版本清单里的一项）。 */
export interface RemoteVersion {
  id: string;
  type: string;
  url: string;
  releaseTime: string;
}

/** 一个待下载项。 */
export interface DownloadItem {
  /** 展示用标签（文件名 / 资源名）。 */
  label: string;
  /** 候选地址（镜像优先、官方兜底）。 */
  urls: string[];
  /** 最终落盘路径。 */
  destPath: string;
  /** 期望 sha1（空串 = 不校验）。 */
  sha1: string;
  /** 期望大小（0 = 未知，仅展示用）。 */
  size: number;
}

/** 安装阶段码（UI 据此显示文案）。 */
export const PHASE_FILES: number = 1;
export const PHASE_ASSETS: number = 2;
export const PHASE_WRITE: number = 3;
/** 执行安装步骤（NeoForge 的 processor 链）。 */
export const PHASE_PROCESS: number = 4;

/** processor 执行：轮询间隔与单步超时（ART/binarypatcher 在大 jar 上可能较慢）。 */
export const PROCESSOR_POLL_MS: number = 500;
export const PROCESSOR_TIMEOUT_MS: number = 300000;
/**
 * **软超时**（工具 JVM 崩溃/被杀时别让界面挂满硬上限 300s）。
 *
 * 计时起点 = 首次观察到 `JLI_BEGIN`（工具 JVM 确已起）；此后若这么久内既无退出码、又没有能观察到的
 * 进程存活迹象 ⇒ 判崩，抛**可诊断**错误提前失败（点名 processor + 已等时长 + 去看 `.hmmcraft/logs`）。
 *
 * 取值依据：本工程 processor 是本地 jar 变换（installertools / binarypatcher / SpecialSource 等），
 * 实测单个远小于 1s；120s 是对实测 100×+ 的余量，且 <硬上限（300s）。**误杀防护**：只要进程探针能
 * 观察到 `:neoinstall` 存活（探针可用的环境），软超时计时即被重置 ⇒ "合法慢"不会因软超时被杀，
 * 只受硬上限（300s）约束。本机探针恒不可用（见 `neoInstallProcessAlive`），故软超时在设备上生效。
 */
export const PROCESSOR_SOFT_TIMEOUT_MS: number = 120000;
/** processor 之间：等上一次 `:neoinstall` 进程完全退出（JVM `_exit` 后仍有回收窗口，立刻再起会 16000068）。 */
export const PROCESSOR_GONE_TIMEOUT_MS: number = 20000;
/** 起 ability 的重试上限与退避（仅对"already running"/内部错误重试）。 */
export const PROCESSOR_START_RETRY_MAX: number = 8;
export const PROCESSOR_START_BACKOFF_MS: number = 800;

/**
 * 失败消息里**内联**的工具 stdio 摘录上限（字符）。
 *
 * 为什么内联（而不只给日志路径）：工具退非 0 的**全部原因都只在它的 stdout/stderr 上**（JLI 的
 * `Error: Could not find or load main class …`、工具的 `Input does not exist …`、
 * `UnsupportedClassVersionError` …）。UI 只显示 `errorDetail`（= 异常 message）⇒ 不内联的话，
 * 用户看到的是「processor failed (x) exit=1」，仍要另外去捞文件。上限取 600：足够装下
 * JLI/工具的整段错误头，又不至于把 UI 撑爆（超长部分在文件里，路径同时在消息里给出）。
 */
export const TOOL_LOG_EXCERPT_MAX: number = 600;

// ---- JSON 结构（Minecraft 版本清单 / 版本 json / 资源索引）----

interface ManifestJson {
  versions?: RemoteVersionJson[];
}

interface RemoteVersionJson {
  id?: string;
  type?: string;
  url?: string;
  releaseTime?: string;
}

interface VersionJson {
  id?: string;
  downloads?: DownloadsJson;
  assetIndex?: AssetIndexInfoJson;
  assets?: string;
  libraries?: LibraryJson[];
  // ---- 以下字段供 Fabric 安装（顶层扁平化）读写；原版 installVersion 不读它们 ----
  mainClass?: string;
  minecraftArguments?: string;
  arguments?: ArgumentsJson;
  javaVersion?: JavaVersionJson;
  type?: string;
  time?: string;
  releaseTime?: string;
  minimumLauncherVersion?: number;
  jar?: string;
  root?: boolean;
  patches?: PatchJson[];
  // 以下三项在 HMCL 折叠补丁时需要（`GameInstancePatch.fromManifest` 会取用它）→ 一并塞进 game patch
  complianceLevel?: number;
  compatibilityRules?: RuleJson[];
  logging?: Record<string, LoggingEntryJson>;
}

interface DownloadsJson {
  client?: FileInfoJson;
}

interface FileInfoJson {
  url?: string;
  sha1?: string;
  size?: number;
  path?: string;
}

/** log4j 日志配置的一项（`logging.<client|server>`）；原样透传，不做解释。 */
interface LoggingEntryJson {
  argument?: string;
  file?: FileInfoJson;
  type?: string;
}

interface AssetIndexInfoJson {
  id?: string;
  url?: string;
  sha1?: string;
  size?: number;
  totalSize?: number;
}

interface LibraryJson {
  name?: string;
  url?: string;
  downloads?: LibraryDownloadsJson;
  rules?: RuleJson[];
  natives?: Record<string, string>;
}

interface LibraryDownloadsJson {
  artifact?: FileInfoJson;
  classifiers?: Record<string, FileInfoJson>;
}

interface RuleJson {
  action?: string;
  os?: OsRuleJson;
  features?: Record<string, boolean>;
}

interface OsRuleJson {
  name?: string;
  arch?: string;
  version?: string;
}

interface AssetIndexJson {
  objects?: Record<string, AssetObjectJson>;
}

interface AssetObjectJson {
  hash?: string;
  size?: number;
}

// ---- Fabric 安装所需的扩展结构 ----

/** 参数项：字符串或带 rules 的对象（与版本 json 的 arguments 一致）。 */
type ArgumentEntry = string | RuleArgJson;

interface RuleArgJson {
  rules?: RuleJson[];
  value?: string | string[];
}

interface ArgumentsJson {
  game?: ArgumentEntry[];
  jvm?: ArgumentEntry[];
}

interface JavaVersionJson {
  component?: string;
  majorVersion?: number;
}

/** 补丁层（HMCL 补丁式：`patches[]` 的一项）。 */
interface PatchJson {
  id?: string;
  version?: string;
  priority?: number;
  mainClass?: string;
  minecraftArguments?: string;
  arguments?: ArgumentsJson;
  libraries?: LibraryJson[];
  assets?: string;
  assetIndex?: AssetIndexInfoJson;
  downloads?: DownloadsJson;
  javaVersion?: JavaVersionJson;
  type?: string;
  time?: string;
  releaseTime?: string;
  minimumLauncherVersion?: number;
  // HMCL `GameInstancePatch` 会折叠这三项；缺了它们，HMCL 读我们装的实例会丢 log4j 配置/合规级别
  complianceLevel?: number;
  compatibilityRules?: RuleJson[];
  logging?: Record<string, LoggingEntryJson>;
}

/** Fabric loader 版本（列表项；UI 选择用）。 */
export interface FabricLoaderVersion {
  version: string;
  stable: boolean;
}

/** Fabric meta 里的一个 maven 坐标项。 */
interface FabricArtifact {
  maven?: string;
  version?: string;
  stable?: boolean;
}

interface FabricMainClass {
  client?: string;
  server?: string;
}

interface FabricLibraries {
  common?: LibraryJson[];
  server?: LibraryJson[];
  client?: LibraryJson[];
  development?: LibraryJson[];
}

interface FabricLauncherMeta {
  /** 可能是字符串，或 `{client,server}` 对象（现代 meta 为对象）。 */
  mainClass?: string | FabricMainClass;
  libraries?: FabricLibraries;
}

/** `/v2/versions/loader/<game>[/<loader>]` 返回项。 */
interface FabricMeta {
  loader?: FabricArtifact;
  intermediary?: FabricArtifact;
  launcherMeta?: FabricLauncherMeta;
}

// ---- 规则求值（对齐 HMCL CompatibilityRule）----

function osAllows(os: OsRuleJson): boolean {
  const name = os.name ?? '';
  if (name.length > 0 && name !== ENV_OS_NAME) {
    return false;
  }
  const arch = os.arch ?? '';
  if (arch.length > 0 && arch !== ENV_OS_ARCH) {
    return false;
  }
  return true;
}

/** 返回本规则对当前环境的动作（'allow'/'disallow'），不适用返回空串。 */
function appliedAction(rule: RuleJson): string {
  const os = rule.os;
  if (os !== undefined && !osAllows(os)) {
    return '';
  }
  const features = rule.features;
  // 当前环境不启用任何 feature：带 features 的规则一律不适用（与 HMCL 空 feature 集等价）
  if (features !== undefined && Object.keys(features).length > 0) {
    return '';
  }
  return rule.action ?? 'allow';
}

/** 是否对当前环境生效（对齐 HMCL：有规则时默认 disallow，逐条匹配覆盖）。 */
function rulesAllow(rules?: RuleJson[]): boolean {
  if (rules === undefined || rules.length === 0) {
    return true;
  }
  let allow = false;
  for (const rule of rules) {
    const action = appliedAction(rule);
    if (action.length > 0) {
      allow = action === 'allow';
    }
  }
  return allow;
}

// ---- Maven 路径 / 下载项构造 ----

/** 由 `group:artifact:version[:classifier][@ext]` 生成 Maven 相对路径。 */
export function mavenPath(name: string): string {
  if (name.length === 0) {
    return '';
  }
  let ext = 'jar';
  let core = name;
  const at = name.indexOf('@');
  if (at >= 0) {
    ext = name.substring(at + 1);
    core = name.substring(0, at);
  }
  const parts = core.split(':');
  if (parts.length < 3) {
    return '';
  }
  const groupPath = parts[0].split('.').join('/');
  const artifact = parts[1];
  const version = parts[2];
  const classifier = parts.length >= 4 ? parts[3] : '';
  let fileName = `${artifact}-${version}`;
  if (classifier.length > 0) {
    fileName += `-${classifier}`;
  }
  fileName += `.${ext}`;
  return `${groupPath}/${artifact}/${version}/${fileName}`;
}

function newItem(label: string, urls: string[], destPath: string, sha1: string,
  size: number): DownloadItem {
  return { label: label, urls: urls, destPath: destPath, sha1: sha1, size: size };
}

/** 解析单个库为下载项；不适用当前环境或无地址时返回 null。 */
function libraryItem(gameRoot: string, lib: LibraryJson): DownloadItem | null {
  if (!rulesAllow(lib.rules)) {
    return null;
  }
  const name = lib.name ?? '';
  const downloads = lib.downloads;
  const artifact = downloads?.artifact;
  if (artifact !== undefined) {
    const url = artifact.url ?? '';
    if (url.length > 0) {
      const declaredPath = artifact.path ?? '';
      const rel = declaredPath.length > 0 ? declaredPath : mavenPath(name);
      if (rel.length === 0) {
        return null;
      }
      return newItem(name, [url], `${librariesDir(gameRoot)}/${rel}`,
        artifact.sha1 ?? '', artifact.size ?? 0);
    }
  }

  // 老版 natives：downloads.classifiers（按 natives 映射 / native-* 键选包）
  const classifiers = downloads?.classifiers;
  if (classifiers !== undefined) {
    let clsKey = '';
    const natives = lib.natives;
    if (natives !== undefined) {
      const want = natives[ENV_OS_NAME];
      if (want !== undefined) {
        clsKey = want.split('${arch}').join(ENV_OS_BITS);
      }
    }
    if (clsKey.length === 0) {
      const keys = Object.keys(classifiers);
      for (const key of keys) {
        if (key.startsWith('native')) {
          clsKey = key;
          break;
        }
      }
    }
    const info = clsKey.length > 0 ? classifiers[clsKey] : undefined;
    if (info !== undefined) {
      const url = info.url ?? '';
      if (url.length > 0) {
        const declaredPath = info.path ?? '';
        const rel = declaredPath.length > 0 ? declaredPath : mavenPath(`${name}:${clsKey}`);
        return newItem(name, [url], `${librariesDir(gameRoot)}/${rel}`,
          info.sha1 ?? '', info.size ?? 0);
      }
    }
  }

  // 无 downloads：按库 url / 缺省仓库 + Maven 路径拼接
  const rel = mavenPath(name);
  if (rel.length === 0) {
    return null;
  }
  const base = lib.url ?? DEFAULT_LIBRARY_URL;
  const full = base.endsWith('/') ? `${base}${rel}` : `${base}/${rel}`;
  return newItem(name, [full], `${librariesDir(gameRoot)}/${rel}`, '', 0);
}

/** 资源索引下载项。 */
function assetIndexItem(gameRoot: string, fallbackId: string,
  info: AssetIndexInfoJson | undefined): DownloadItem | null {
  if (info === undefined) {
    return null;
  }
  const idxId = (info.id ?? '').length > 0 ? (info.id ?? '') : fallbackId;
  if (idxId.length === 0) {
    return null;
  }
  let url = info.url ?? '';
  const sha1 = info.sha1 ?? '';
  if (url.length === 0 && sha1.length > 0) {
    url = `${LEGACY_INDEX_URL_PREFIX}${sha1}/${idxId}.json`;
  }
  if (url.length === 0) {
    return null;
  }
  return newItem(`${idxId}.json`, [url], `${assetsIndexesDir(gameRoot)}/${idxId}.json`,
    sha1, info.size ?? 0);
}

/** 由资源索引构造全部资源对象下载项（按 hash 去重：多个名字可指向同一对象）。 */
function assetObjectItems(gameRoot: string, index: AssetIndexJson): DownloadItem[] {
  const out: DownloadItem[] = [];
  const objects = index.objects;
  if (objects === undefined) {
    return out;
  }
  const seen: Set<string> = new Set<string>();
  const names = Object.keys(objects);
  for (const name of names) {
    const obj = objects[name];
    const hash = obj.hash ?? '';
    if (hash.length === 0 || seen.has(hash)) {
      continue;
    }
    seen.add(hash);
    const location = `${hash.substring(0, ASSET_HASH_PREFIX_LENGTH)}/${hash}`;
    out.push(newItem(name, [`${MOJANG_RESOURCES}/${location}`],
      assetObjectPath(gameRoot, hash), hash, obj.size ?? 0));
  }
  return out;
}

// ---- 落盘工具 ----

function ensureParent(filePath: string): void {
  const idx = filePath.lastIndexOf('/');
  if (idx <= 0) {
    return;
  }
  try {
    fileIo.mkdirSync(filePath.substring(0, idx), true);
  } catch {
    // 目录已存在
  }
}

function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch {
    return false;
  }
}

/** 目标目录是否具备写权限（Picker 临时授权失效后 fileIo.access 返回 false）。 */
export function canWriteDirectory(dirPath: string): boolean {
  try {
    return fileIo.accessSync(dirPath, fileIo.AccessModeType.WRITE);
  } catch {
    return false;
  }
}

function writeText(path: string, text: string): void {
  ensureParent(path);
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  } catch (error) {
    throw new Error(`write open failed: ${(error as BusinessError).message ?? ''}`);
  }
  if (file === null) {
    return;
  }
  // try/finally：无论写入成功、还是写入中途抛出，都必须释放 fd。
  // HarmonyOS 应用可用 fd 数有限且进程长期驻留，安装期会反复写 version json / job 文件；
  // 一旦在异常路径漏关，描述符会逐渐累积直至耗尽，之后所有 open 都失败（表现为莫名的写盘失败）。
  try {
    fileIo.writeSync(file.fd, text);
  } catch {
    throw new Error('write failed');
  } finally {
    try {
      fileIo.closeSync(file);
    } catch {
      // 忽略关闭异常
    }
  }
}

/** 文件级并发下载（已存在即跳过；总数为本批项数）。source 决定候选地址（官方/镜像）。 */
async function runDownloads(items: DownloadItem[], source: string,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  // 防御性去重：同一 destPath 只能有一个下载任务（否则并发写同一 .part → 互相截断/损坏）。
  const unique: DownloadItem[] = [];
  const seenPaths: Set<string> = new Set<string>();
  for (const it of items) {
    if (seenPaths.has(it.destPath)) {
      continue;
    }
    seenPaths.add(it.destPath);
    unique.push(it);
  }
  const total = unique.length;
  onCount(0, total);
  if (total === 0) {
    return;
  }
  let next = 0;
  let done = 0;
  const worker = async (): Promise<void> => {
    while (true) {
      const index = next;
      next++;
      if (index >= total) {
        return;
      }
      const item = unique[index];
      onCurrent(item.label);
      if (!exists(item.destPath)) {
        ensureParent(item.destPath);
        try {
          await downloadFile(fileCandidates(item.urls[0], source), item.destPath, item.sha1,
            onFileProgress);
        } catch (error) {
          const err = error as BusinessError;
          // 带上文件标签，便于定位是哪个文件失败。
          throw new Error(`${item.label}: ${err.message ?? ''}`);
        }
      }
      done++;
      onCount(done, total);
    }
  };
  const workers: Promise<void>[] = [];
  const count = Math.min(DOWNLOAD_CONCURRENCY, total);
  for (let i = 0; i < count; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
}

// ---- 对外 API ----

/** 拉取远程版本清单，返回可下载版本列表（source 决定清单来源：官方/镜像）。 */
export async function fetchManifest(source: string): Promise<RemoteVersion[]> {
  const text = await fetchText(manifestCandidates(source));
  const manifest = JSON.parse(text) as ManifestJson;
  const list = manifest.versions ?? [];
  const out: RemoteVersion[] = [];
  for (const v of list) {
    const id = v.id ?? '';
    if (id.length === 0) {
      continue;
    }
    out.push({ id: id, type: v.type ?? '', url: v.url ?? '', releaseTime: v.releaseTime ?? '' });
  }
  return out;
}

/**
 * 实例名称合法性（= 安装目标目录名；对齐 HMCL 的 instance name 校验）。
 * 只拦**真正危险/非法**的名字（路径穿越、文件系统非法字符），**不设"保留后缀"之类私规**
 *（HMCL 亦不禁 `*removed`；删除残留已移出 versions/，见 VersionTools）。
 * 规则：非空且非纯空白；非 `.` / `..`；不以 `.` 或空格结尾；
 * 不含路径分隔符 `/` `\`、控制字符、或各平台文件系统非法字符 `: * ? " < > |`。
 */
export function isValidInstanceName(name: string): boolean {
  if (name.length === 0 || name.trim().length === 0) {
    return false;
  }
  if (name === '.' || name === '..') {
    return false;
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    return false;
  }
  for (let i = 0; i < name.length; i++) {
    const c = name.charCodeAt(i);
    if (c < 0x20 || c === 0x7f) {
      return false; // 控制字符（含 NUL）
    }
    const ch = name.charAt(i);
    if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?'
      || ch === '"' || ch === '<' || ch === '>' || ch === '|') {
      return false;
    }
  }
  return true;
}

/** 目标实例目录 `<root>/versions/<name>/` 是否已存在（命名冲突检测）。 */
export function versionDirExists(gameRoot: string, name: string): boolean {
  try {
    return fileIo.statSync(`${gameRoot}/versions/${name}`).isDirectory();
  } catch {
    return false;
  }
}

/**
 * 安装失败收尾：若 `<root>/versions/<name>` 存在但**缺 `<name>.json`**（半装残留），best-effort 清掉。
 * 有 json 视为完整实例，绝不触碰。这样失败后同名可重试，不会留下"扫描不到又占名（冲突）"的僵尸目录。
 */
export function removeIncompleteInstance(gameRoot: string, name: string): void {
  if (name.length === 0 || !isValidInstanceName(name)) {
    return;
  }
  if (exists(versionJsonPath(gameRoot, name))) {
    return;
  }
  removeTreeBestEffort(versionDir(gameRoot, name));
}

/**
 * 安装一个原版版本到 gameRoot 下的**实例目录 `versions/<instanceName>/`**。
 *
 * `instanceName` = 实例名（目录名，玩家安装时设置；对齐 HMCL）。
 * 版本 json 原样写入 `<instanceName>.json`（其内部 id 不改，磁盘与 HMCL 一致），
 * client jar 落 `<instanceName>.jar`；启动/扫描按目录名定位（见 VersionScanner 身份约定）。
 *
 * @param instanceName 实例名（`versions/` 下的目录名）
 * @param onPhase   阶段变化回调（PHASE_FILES / PHASE_ASSETS / PHASE_WRITE）
 * @param onCount   进度回调（已完成 / 总数，按阶段重置）
 * @param onCurrent 当前处理项标签回调
 */
export async function installVersion(gameRoot: string, remote: RemoteVersion, source: string,
  instanceName: string,
  onPhase: (phase: number) => void,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  if (!isValidInstanceName(instanceName)) {
    throw new Error('invalid instance name');
  }
  onPhase(PHASE_FILES);
  const versionJsonText = await fetchText(fileCandidates(remote.url, source));
  const versionJson = JSON.parse(versionJsonText) as VersionJson;
  // 扫描器按"存在 <名>.json 且其内部 id 非空"识别实例；缺 id 的 json 装了也扫不到 → 提前拒绝。
  if ((versionJson.id ?? '').length === 0) {
    throw new Error('version json id missing');
  }

  // 第一批：client jar + libraries + 资源索引
  const files: DownloadItem[] = [];
  const client = versionJson.downloads?.client;
  if (client !== undefined) {
    const url = client.url ?? '';
    if (url.length > 0) {
      files.push(newItem(`${instanceName}.jar`, [url], versionJarPath(gameRoot, instanceName),
        client.sha1 ?? '', client.size ?? 0));
    }
  }
  const libraries = versionJson.libraries ?? [];
  for (const lib of libraries) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  const indexItem = assetIndexItem(gameRoot, versionJson.assets ?? '', versionJson.assetIndex);
  if (indexItem !== null) {
    files.push(indexItem);
  }
  await runDownloads(files, source, onCount, onCurrent, onFileProgress);

  // 第二批：资源对象（依赖已下好的资源索引）
  const assetId = (versionJson.assetIndex?.id ?? '').length > 0
    ? (versionJson.assetIndex?.id ?? '')
    : (versionJson.assets ?? '');
  if (indexItem !== null && assetId.length > 0) {
    onPhase(PHASE_ASSETS);
    const indexPath = `${assetsIndexesDir(gameRoot)}/${assetId}.json`;
    let index: AssetIndexJson = {};
    try {
      index = JSON.parse(fileIo.readTextSync(indexPath)) as AssetIndexJson;
    } catch {
      index = {};
    }
    const objects = assetObjectItems(gameRoot, index);
    await runDownloads(objects, source, onCount, onCurrent, onFileProgress);
  }

  // 最后写版本清单：扫描器只认这个文件，保证不出现"半装被识别"的版本
  onPhase(PHASE_WRITE);
  writeText(versionJsonPath(gameRoot, instanceName), versionJsonText);
}

// ---- Fabric 安装（单实例，HMCL 补丁式）----

/** 从 launcherMeta 取 mainClass（对象取 client；字符串直用）。 */
function fabricMainClass(meta: FabricMeta): string {
  const mc = meta.launcherMeta?.mainClass;
  if (typeof mc === 'string') {
    return mc;
  }
  return mc?.client ?? '';
}

/** 补 url：Fabric 元数据的产物一律托管在自家 maven（缺 url 时不能落到 Mojang 库仓）。 */
function withFabricUrl(lib: LibraryJson): LibraryJson {
  if ((lib.url ?? '').length === 0) {
    lib.url = FABRIC_MAVEN;
  }
  return lib;
}

/** fabric 库 = launcherMeta.libraries.common + server，再追加 intermediary / loader 两条（url=maven.fabricmc.net）。 */
function fabricLibraries(meta: FabricMeta): LibraryJson[] {
  const out: LibraryJson[] = [];
  const libs = meta.launcherMeta?.libraries;
  if (libs !== undefined) {
    for (const l of libs.common ?? []) {
      out.push(withFabricUrl(l));
    }
    for (const l of libs.server ?? []) {
      out.push(withFabricUrl(l));
    }
  }
  const inter = meta.intermediary?.maven ?? '';
  if (inter.length > 0) {
    out.push({ name: inter, url: FABRIC_MAVEN });
  }
  const loader = meta.loader?.maven ?? '';
  if (loader.length > 0) {
    out.push({ name: loader, url: FABRIC_MAVEN });
  }
  return out;
}

function concatLibs(a?: LibraryJson[], b?: LibraryJson[]): LibraryJson[] | undefined {
  if (a === undefined && b === undefined) {
    return undefined;
  }
  const out: LibraryJson[] = [];
  for (const x of a ?? []) {
    out.push(x);
  }
  for (const x of b ?? []) {
    out.push(x);
  }
  return out;
}

/**
 * 组装 HMCL 补丁式单实例清单：**顶层扁平化**（Java 端 form② 读顶层）+ **`patches[game,fabric]`**（ArkTS 端折叠）。
 * `vanilla` 解析对象被复用/就地改写——未声明字段（logging/time…）随 `JSON.stringify` 原样保留。
 * 注意：gamePatch 必须在改写 vanilla 之前构造（否则会拿到被覆盖后的值）。
 */
function composeFabricManifest(vanilla: VersionJson, instanceName: string, gameVersion: string,
  loaderVersion: string, mainClass: string, fabricDeps: LibraryJson[]): VersionJson {
  const gamePatch: PatchJson = {
    id: 'game',
    version: gameVersion,
    priority: 0,
    mainClass: vanilla.mainClass,
    minecraftArguments: vanilla.minecraftArguments,
    arguments: vanilla.arguments,
    libraries: vanilla.libraries,
    assets: vanilla.assets,
    assetIndex: vanilla.assetIndex,
    downloads: vanilla.downloads,
    javaVersion: vanilla.javaVersion,
    type: vanilla.type,
    time: vanilla.time,
    releaseTime: vanilla.releaseTime,
    minimumLauncherVersion: vanilla.minimumLauncherVersion,
    complianceLevel: vanilla.complianceLevel,
    compatibilityRules: vanilla.compatibilityRules,
    logging: vanilla.logging
  };
  const fabricPatch: PatchJson = {
    id: 'fabric',
    version: loaderVersion,
    priority: 30000,
    mainClass: mainClass,
    libraries: fabricDeps
  };
  vanilla.id = instanceName;
  vanilla.jar = instanceName;
  vanilla.root = true;
  vanilla.mainClass = mainClass;
  vanilla.libraries = concatLibs(vanilla.libraries, fabricDeps);
  vanilla.patches = [gamePatch, fabricPatch];
  return vanilla;
}

/**
 * 拉取某游戏版本可用的 Fabric loader 版本列表（按 **loader 自己的下载源** `source`）。
 * 端点 `…/v2/versions/loader/<game>`（已按新版在前返回）。
 */
export async function fetchFabricLoaders(gameVersion: string, source: string): Promise<FabricLoaderVersion[]> {
  // Fabric meta 对**不支持**的游戏版本返回 `400` + `[]`（而非 404）：按"无可用版本"处理，不当作拉取失败。
  const text = await fetchText(fabricLoaderListCandidates(gameVersion, source),
    [HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_NOT_FOUND]);
  // 元数据数组可能含 null / 缺字段项（外部 JSON 原样信任）：逐项判空，缺 loader 版本号的跳过。
  const list = JSON.parse(text) as (FabricMeta | null)[];
  const out: FabricLoaderVersion[] = [];
  if (!Array.isArray(list)) {
    return out;
  }
  for (const entry of list) {
    if (entry === null) {
      continue;
    }
    const version = entry.loader?.version ?? '';
    if (version.length === 0) {
      continue;
    }
    out.push({ version: version, stable: entry.loader?.stable === true });
  }
  return out;
}

/**
 * 安装 Fabric 实例（**单实例、HMCL 补丁式**）：`versions/<名>/<名>.json` = 顶层扁平化 + `patches[game,fabric]`。
 *
 * **整条链按 `loaderSource`**（Fabric 自己的源）：vanilla 清单 / client jar / 原版库 / 资源索引与对象
 * 与 Fabric 元数据 / 库**同一个源**。依据 HMCL：一次安装只有一个**文件源**（`AutoDownloadProvider`
 * 的文件候选来自 `fileDownloadSource`，同时服务原版件与 loader 件，不存在"原版件走共享源、loader 件走
 * 另一个源"的拆分；ref/HMCL `.../download/AutoDownloadProvider.java:78-101` 与
 * `.../download/BMCLAPIDownloadProvider.java:77-98` 的替换表里同时含 Mojang / Fabric / Forge / NeoForge 前缀）。
 * ⇒ 本函数**不再**接受"版本源"参数（此前 vanilla 件走版本源属实现不一致，2026-09-29 对齐 HMCL）。
 */
export async function installFabricVersion(gameRoot: string, gameRemote: RemoteVersion,
  loaderVersion: string, instanceName: string, loaderSource: string,
  onPhase: (phase: number) => void,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  if (!isValidInstanceName(instanceName)) {
    throw new Error('invalid instance name');
  }
  if (loaderVersion.length === 0) {
    throw new Error('fabric loader version missing');
  }

  // 1) vanilla 清单（Fabric 源）
  onPhase(PHASE_FILES);
  const vanillaText = await fetchText(fileCandidates(gameRemote.url, loaderSource));
  const vanilla = JSON.parse(vanillaText) as VersionJson;
  const vanillaId = vanilla.id ?? '';
  const gameVersion = vanillaId.length > 0 ? vanillaId : gameRemote.id;

  // 2) Fabric 元数据（Fabric 源）
  const metaText = await fetchText(fabricLaunchMetaCandidates(gameVersion, loaderVersion, loaderSource));
  const meta = JSON.parse(metaText) as FabricMeta;
  const mainClass = fabricMainClass(meta);
  if (mainClass.length === 0) {
    throw new Error('fabric mainClass missing');
  }
  const fabricDeps = fabricLibraries(meta);

  // 3) vanilla 文件：client jar（落 <名>.jar）+ 原版库 + 资源索引（Fabric 源）
  const files: DownloadItem[] = [];
  const client = vanilla.downloads?.client;
  if (client !== undefined) {
    const url = client.url ?? '';
    if (url.length > 0) {
      files.push(newItem(`${instanceName}.jar`, [url], versionJarPath(gameRoot, instanceName),
        client.sha1 ?? '', client.size ?? 0));
    }
  }
  for (const lib of vanilla.libraries ?? []) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  const indexItem = assetIndexItem(gameRoot, vanilla.assets ?? '', vanilla.assetIndex);
  if (indexItem !== null) {
    files.push(indexItem);
  }
  await runDownloads(files, loaderSource, onCount, onCurrent, onFileProgress);

  // 4) 资源对象（依赖已下好的索引；Fabric 源）
  const assetId = (vanilla.assetIndex?.id ?? '').length > 0
    ? (vanilla.assetIndex?.id ?? '')
    : (vanilla.assets ?? '');
  if (indexItem !== null && assetId.length > 0) {
    onPhase(PHASE_ASSETS);
    let index: AssetIndexJson = {};
    try {
      index = JSON.parse(fileIo.readTextSync(`${assetsIndexesDir(gameRoot)}/${assetId}.json`)) as AssetIndexJson;
    } catch {
      index = {};
    }
    await runDownloads(assetObjectItems(gameRoot, index), loaderSource, onCount, onCurrent, onFileProgress);
  }

  // 5) Fabric 库（Fabric 源；maven.fabricmc.net → 镜像/官方）
  onPhase(PHASE_FILES);
  const fabricItems: DownloadItem[] = [];
  for (const lib of fabricDeps) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      fabricItems.push(item);
    }
  }
  await runDownloads(fabricItems, loaderSource, onCount, onCurrent, onFileProgress);

  // 6) 写清单：顶层扁平化 + patches[game,fabric]
  onPhase(PHASE_WRITE);
  const composed = composeFabricManifest(vanilla, instanceName, gameVersion, loaderVersion, mainClass, fabricDeps);
  writeText(versionJsonPath(gameRoot, instanceName), JSON.stringify(composed));
}

// ---- NeoForge 安装（**仅 MC 1.20.2+**；installer jar 只作数据容器）----
// 依据：真 installer 实测 + 方案文档（notes 20-design/launch/NeoForge支持-改动方案.md）。
// 形态：**HMCL 形态**（顶层扁平 + patches[game,neoforge]），与 Fabric 一致（Java 侧只读顶层、
// ArkTS 侧对 patches 形态从空清单重放 patch，故 patches 必须自洽）。

/** 合并两段 arguments（前者在前、后者追加）——对齐 HMCL `Arguments.merge`。 */
function concatArgs(a?: ArgumentsJson, b?: ArgumentsJson): ArgumentsJson | undefined {
  if (a === undefined) {
    return b;
  }
  if (b === undefined) {
    return a;
  }
  const game: ArgumentEntry[] = [];
  for (const x of a.game ?? []) {
    game.push(x);
  }
  for (const x of b.game ?? []) {
    game.push(x);
  }
  const jvm: ArgumentEntry[] = [];
  for (const x of a.jvm ?? []) {
    jvm.push(x);
  }
  for (const x of b.jvm ?? []) {
    jvm.push(x);
  }
  return { game: game, jvm: jvm };
}

/**
 * NeoForge 工作目录（installer jar / 解包 / job 文件；位于 cacheDir，可随时重下）。
 *
 * 目录名带 `loaderSource`（与 `installForgeVersion` 同款）：`installer.jar` 按路径"命中即跳过"，
 * 若不带源，切换下载源后会**静默复用**另一源下过的文件（切源 = 不做任何下载、也看不出选的是哪个源）。
 * 隔离后切源必按新候选顺序重下，"所选源"在磁盘布局上也可观测；整棵树由 `CacheCleaner` 清理。
 */
function neoWorkDir(cacheDir: string, loaderSource: string, loaderVersion: string): string {
  return `${cacheDir}/${NEO_INSTALLER_DIR}/${loaderSource}/${loaderVersion}`;
}

/** 确保目录存在（递归；已存在则忽略）。 */
function ensureDir(dirPath: string): void {
  try {
    if (!fileIo.accessSync(dirPath)) {
      fileIo.mkdirSync(dirPath, true);
    }
  } catch {
    // 并发创建/已存在：忽略。
  }
}

/** 读并解析 JSON 文件。 */
function readJsonFile<T>(path: string): T {
  return JSON.parse(fileIo.readTextSync(path)) as T;
}

/**
 * 组装 NeoForge 实例清单（HMCL 形态）：顶层扁平 + `patches[game, neoforge]`。
 *
 * - `game` patch：vanilla 全部字段（priority 0）；
 * - `neoforge` patch：来自 installer 内嵌 `version.json`（mainClass / arguments / libraries 等，priority 30000）；
 * - 顶层：`mainClass = neoforge`、`libraries = vanilla ++ neoforge`、`arguments = vanilla ++ neoforge`
 *   （Java 侧只读顶层 ⇒ 必须把加载器的 jvm/game 参数并进来；`-cp ${classpath}` 由 vanilla 提供）。
 */
function composeNeoForgeManifest(vanilla: VersionJson, instanceName: string, gameVersion: string,
  loaderVersion: string, neo: NeoForgeLaunchJson): VersionJson {
  const gamePatch: PatchJson = {
    id: 'game',
    version: gameVersion,
    priority: 0,
    mainClass: vanilla.mainClass,
    minecraftArguments: vanilla.minecraftArguments,
    arguments: vanilla.arguments,
    libraries: vanilla.libraries,
    assets: vanilla.assets,
    assetIndex: vanilla.assetIndex,
    downloads: vanilla.downloads,
    javaVersion: vanilla.javaVersion,
    type: vanilla.type,
    time: vanilla.time,
    releaseTime: vanilla.releaseTime,
    minimumLauncherVersion: vanilla.minimumLauncherVersion,
    complianceLevel: vanilla.complianceLevel,
    compatibilityRules: vanilla.compatibilityRules,
    logging: vanilla.logging
  };
  const neoPatch: PatchJson = {
    id: 'neoforge',
    version: loaderVersion,
    priority: 30000,
    mainClass: neo.mainClass,
    arguments: neo.arguments as ArgumentsJson | undefined,
    libraries: neo.libraries as LibraryJson[] | undefined,
    type: neo.type,
    time: neo.time,
    releaseTime: neo.releaseTime,
    logging: neo.logging as Record<string, LoggingEntryJson> | undefined,
    complianceLevel: neo.complianceLevel
  };
  const mainClass = neo.mainClass ?? vanilla.mainClass;
  vanilla.id = instanceName;
  vanilla.jar = instanceName;
  vanilla.root = true;
  vanilla.mainClass = mainClass;
  vanilla.libraries = concatLibs(vanilla.libraries, neo.libraries as LibraryJson[] | undefined);
  vanilla.arguments = concatArgs(vanilla.arguments, neo.arguments as ArgumentsJson | undefined);
  vanilla.patches = [gamePatch, neoPatch];
  return vanilla;
}

/** NeoForge installer 的解包结果：profile 与内嵌启动清单（**两者都读到**才算"这个 jar 可用"）。 */
interface NeoForgeArchive {
  profile: NeoForgeInstallProfileJson;
  launch: NeoForgeLaunchJson;
}

/**
 * 安装 NeoForge 实例（**仅 1.20.2+**）。
 *
 * 步骤：拉 vanilla 清单 → 下 installer jar（数据容器）→ 解包读 `install_profile.json` 与内嵌
 * `version.json` → 下 vanilla 资产（client jar 落 `<名>.jar`、原版库、资源索引与对象）→
 * 下 NeoForge 两份库（install_profile.libraries + version.json.libraries，按 maven 树）→
 * 【processor 链】→ 写清单。
 *
 * ⚠️ processor 链（T3 待实现）会产出 patched client jar；**未完成前本函数会在写出清单之前抛错**，
 * 以免留下"能列出但起不来"的残缺实例。
 *
 * **整条链按 `loaderSource`**（NeoForge 自己的下载源）——NeoForge 制品来自 NeoForged
 * （`maven.neoforged.net`）、不是 Mojang，故不复用版本源（与 `installForgeVersion` 的语义一致）：
 *  - vanilla 清单 / client jar / 原版库 / 资源：`loaderSource`；
 *  - installer jar 与 NeoForge 库：同样按 `loaderSource` 展开候选（installer 直连 `downloadFile`
 *    〔候选含官方兜底〕，库走 `runDownloads` → 前缀重写表）。
 * 依据 HMCL：一次安装只有一个文件源（ref/HMCL `.../download/AutoDownloadProvider.java:78-101`）。
 *
 * `jreId` = processor **工具 JVM** 用的那套 JRE id（由 `confirmInstall` 经 `JavaPolicy` 按
 * (MC 版本 × NeoForge) 解析，与启动路径同源）；仅**透传**到 `:neoinstall`，本函数不解析 JRE。
 */
export async function installNeoForgeVersion(ctx: common.UIAbilityContext, gameRoot: string,
  gameRootUri: string, gameRemote: RemoteVersion, loaderVersion: string, instanceName: string,
  loaderSource: string, cacheDir: string, jreId: string,
  onPhase: (phase: number) => void,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  if (!isValidInstanceName(instanceName)) {
    throw new Error('invalid instance name');
  }
  if (loaderVersion.length === 0) {
    throw new Error('neoforge loader version missing');
  }

  // 1) vanilla 清单（NeoForge 源）
  onPhase(PHASE_FILES);
  const vanillaText = await fetchText(fileCandidates(gameRemote.url, loaderSource));
  const vanilla = JSON.parse(vanillaText) as VersionJson;
  const gameVersion = (vanilla.id ?? '').length > 0 ? (vanilla.id ?? '') : gameRemote.id;

  // 2) installer jar（数据容器）→ 解包 → 读 profile 与内嵌启动清单
  const workDir = neoWorkDir(cacheDir, loaderSource, loaderVersion);
  ensureDir(workDir);
  const jarPath = `${workDir}/installer.jar`;
  const unzipDir = `${workDir}/unzipped`;

  // 下 installer jar（候选顺序见 `neoforgeInstallerCandidates`）。
  // **直接走下载原语 `downloadFile`**（与 Forge 链同款），不再用 `runDownloads` —— 依据评审两条 finding：
  //  ① `runDownloads` 只对 `urls[0]` 再做一次前缀展开；`urls[0]` 已是镜像地址时展不出官方兜底，
  //     镜像取不到 installer 即无官方回退（notes 已知限制与待解 §E 的 finding (a)）。
  //  ② `runDownloads` 对"目标已存在"跳过下载；复用期自愈删坏文件后若删除失败，日志会打
  //     "re-downloading"却没真重下 ⇒ 坏缓存退化为"每次解包都失败"。`downloadFile` 落盘前先删目标再 rename，两者兼治。
  const downloadInstaller = async (): Promise<void> => {
    onCount(0, 1);
    onCurrent('neoforge-installer.jar');
    await downloadFile(neoforgeInstallerCandidates(loaderVersion, loaderSource), jarPath, '',
      onFileProgress);
    onCount(1, 1);
  };

  // 解包 installer 并读 `install_profile.json` 与内嵌启动清单（先清后解）；任一步失败即视为"这个 jar 不可用"。
  // 下游 processor 链正是靠这两份 JSON（profile 的 processors/libraries + launch 的 mainClass/arguments）。
  // 幂等：`unzipped/` 按 **下载源 + loader 版本** 跨实例复用（同名 job 目录），先清后解，避免
  // 「第二次安装/失败重试」时同名目录已存在导致的重复解压与半截残留。
  const extractArchive = async (): Promise<NeoForgeArchive> => {
    removeTreeBestEffort(unzipDir);
    ensureDir(unzipDir);
    onCurrent('installer-profile');
    await zlib.decompressFile(jarPath, unzipDir);
    const profile = readJsonFile<NeoForgeInstallProfileJson>(`${unzipDir}/install_profile.json`);
    const launchRel = (profile.json ?? '/version.json').replace(/^\//, '');
    const launch = readJsonFile<NeoForgeLaunchJson>(`${unzipDir}/${launchRel}`);
    return { profile: profile, launch: launch };
  };

  // `installer.jar` 经通用下载原语落在 `neo-installer/**`，按路径"命中即跳过"（sha1 为空，无从校验）：
  // 复用到的文件若已损坏（半截 / 被破坏 / 上次中断留下），必须能**自愈**，否则坏文件会被永久复用
  // （每次都在下游解包处失败，且 `exists` 为真 ⇒ 永不重下）。
  // HMCL 不靠"路径命中即跳过"：它每次下到**专门的临时文件**、用 ZIP 结构完整性校验把关、用完即删
  // （ref/HMCL `.../download/neoforge/NeoForgeInstallTask.java:67` 建临时文件、`:69-76` 下到临时文件并挂
  // `ZIP_INTEGRITY_CHECK_HANDLER`、`:85` 删除），坏文件从不进持久位置；其 `install()` 同样是先开 zip、
  // 读 `install_profile.json`（同文件 `:122-124`）——与"能不能解出 profile"这个可用性判据同源。
  // 这里保留跨实例复用的缓存目录，但**复用前先解一次**：zip 打不开、或缺 `install_profile.json` /
  // 内嵌启动清单，即判为坏文件 → 删除 → 重下再解。于是坏缓存最多只影响当次任务（当次即修），
  // 不会永久卡死。与 `installForgeVersion` 的自愈同款（见 ForgeInstallTask.java:76-84/92-93 的对应注释）。
  let archive: NeoForgeArchive | null = null;
  if (exists(jarPath)) {
    try {
      archive = await extractArchive();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'cached neoforge installer unusable, re-downloading: %{public}s (%{public}s)',
        jarPath, err.message ?? '');
      try {
        fileIo.unlinkSync(jarPath);
      } catch {
        // 删除失败也继续：`downloadFile` 落盘前会先删目标再 rename。
      }
    }
  }
  if (archive === null) {
    await downloadInstaller();
    archive = await extractArchive();
  }
  const profile = archive.profile;
  const launch = archive.launch;

  // 3) vanilla 文件：client jar（落 <名>.jar）+ 原版库 + 资源索引（NeoForge 源）
  const files: DownloadItem[] = [];
  const client = vanilla.downloads?.client;
  if (client !== undefined) {
    const url = client.url ?? '';
    if (url.length > 0) {
      files.push(newItem(`${instanceName}.jar`, [url], versionJarPath(gameRoot, instanceName),
        client.sha1 ?? '', client.size ?? 0));
    }
  }
  for (const lib of vanilla.libraries ?? []) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  const indexItem = assetIndexItem(gameRoot, vanilla.assets ?? '', vanilla.assetIndex);
  if (indexItem !== null) {
    files.push(indexItem);
  }
  // NeoForge 两份库一并下（maven 树；url 指向 maven.neoforged.net，按 **NeoForge 源**重写为镜像/官方）。
  const profileLibs = (profile.libraries ?? []) as LibraryJson[];
  for (const lib of profileLibs) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  const launchLibs = (launch.libraries ?? []) as LibraryJson[];
  for (const lib of launchLibs) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
    // 加载器 `-DmergeModules=` 点名的 jar：**不在任何清单里**，但加载器按文件名在 classpath 里找它
  // （找不到就拿空集做 union 合并 → 读 /META-INF/versions 抛异常 → 启动即败）。
  // 例：NeoForge 20.2.93 要 `jna-5.10.0.jar`，而 vanilla 1.20.2 只声明 jna 5.13.0 ⇒ 必须补下。
  const launchJvmArgs = stringArgs(launch.arguments);
  // group 解析来源要含 **vanilla 库表**：`jna`/`jna-platform` 只在 vanilla 1.20.2 里声明
  // （NeoForge 清单里没有它们），否则解析不出 group → 补不下那颗 jar。
  const declaredNames: string[] = [];
  for (const n of libraryNames(vanilla.libraries as object[] | undefined)) {
    declaredNames.push(n);
  }
  for (const n of libraryNames(profile.libraries)) {
    declaredNames.push(n);
  }
  for (const n of libraryNames(launch.libraries)) {
    declaredNames.push(n);
  }
  const mergeEntries: NeoForgeMergeModuleEntry[] = resolveMergeModuleEntries(launchJvmArgs, declaredNames);
  for (const e of mergeEntries) {
    const dest = `${librariesDir(gameRoot)}/${e.relPath}`;
    if (!exists(dest)) {
      files.push(newItem(e.fileName, [`${NEOFORGE_RELEASES}${e.relPath}`], dest, '', 0));
    }
  }
await runDownloads(files, loaderSource, onCount, onCurrent, onFileProgress);

  // 4) 资源对象（依赖已下好的索引；NeoForge 源）
  const assetId = (vanilla.assetIndex?.id ?? '').length > 0
    ? (vanilla.assetIndex?.id ?? '')
    : (vanilla.assets ?? '');
  if (indexItem !== null && assetId.length > 0) {
    onPhase(PHASE_ASSETS);
    let index: AssetIndexJson = {};
    try {
      index = JSON.parse(fileIo.readTextSync(`${assetsIndexesDir(gameRoot)}/${assetId}.json`)) as AssetIndexJson;
    } catch {
      index = {};
    }
    await runDownloads(assetObjectItems(gameRoot, index), loaderSource, onCount, onCurrent, onFileProgress);
  }

  // 5) processor 链：installer 只当数据容器，按 profile 顺序执行工具，产出 patched client jar。
  //    `{MINECRAFT_JAR}` 必须用**独立 temp 副本**（HMCL 同款硬约束）：工具会就地改写该 jar。
  onPhase(PHASE_PROCESS);
  onFileProgress(0, 0); // 处理器阶段无文件进度（清掉上一阶段残留的字节数显示）
  const mcJarForTools = `${workDir}/mc.jar`;
  try {
    fileIo.copyFileSync(versionJarPath(gameRoot, instanceName), mcJarForTools);
  } catch (error) {
    const err = error as BusinessError;
    throw new Error(`copy minecraft jar for processors failed: ${err.message ?? ''}`);
  }
  const expandCtx: NeoForgeExpandContext = {
    libraryDir: librariesDir(gameRoot),
    unzipDir: unzipDir,
    gameRoot: gameRoot,
    installerJar: jarPath,
    minecraftJar: mcJarForTools,
    minecraftVersion: gameVersion,
    mavenPathOf: (name: string): string => mavenPath(name)
  };
  const set = await buildNeoForgeProcessorPlans(profile, expandCtx, workDir);
  await runNeoForgeProcessors(ctx, set, workDir, gameRootUri, jreId, onCount, onCurrent);
  if (set.patchedPath.length === 0 || !exists(set.patchedPath)) {
    throw new Error('neoforge patched client jar missing after processors');
  }

  // 6) 写清单（HMCL 形态：顶层扁平 + patches[game, neoforge]）
  onPhase(PHASE_WRITE);
  const composed = composeNeoForgeManifest(vanilla, instanceName, gameVersion, loaderVersion, launch);
  writeText(versionJsonPath(gameRoot, instanceName), JSON.stringify(composed));
}

/**
 * 执行 NeoForge 的 processor 链：**每个 processor 起一次无窗 UIAbility（独立进程 + headless JVM）**。
 *
 * 为什么逐次起进程：JLI_Launch 一进程只能起一次；`System.exit` 只杀该进程；工具间静态状态互不污染。
 * 退出码来自桥在 headless 模式写的 `<filesDir>/meow-neo-jvm-result.txt`（native 只有 hilog，拿不到返回值）；
 * ⚠️ 工具**多数 fail-open（参数错也退 0）** ⇒ 成败另有产物断言（调用方负责）。
 *
 * `jreId` = 工具 JVM 该用哪套 JRE（由 `confirmInstall` 经 `JavaPolicy` 解析、与启动路径同源）；
 * 写进 job 文件交给 `:neoinstall`，让该进程用**同一套**起 `startJvm`（不在本层解析）。
 */
async function runNeoForgeProcessors(ctx: common.UIAbilityContext, set: NeoForgeProcessorSet,
  workDir: string, gameRootUri: string, jreId: string, onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void): Promise<void> {
  const resultPath = `${ctx.filesDir}/${NEO_JVM_RESULT}`;
  const total = set.plans.length;
  if (total === 0) {
    throw new Error('neoforge profile has no client-side processors');
  }
  onCount(0, total);
  for (let i = 0; i < total; i++) {
    const plan: NeoForgeProcessorPlan = set.plans[i];
    onCurrent(plan.label);
    // job：完整 java 参数（不经 meow.launcher；headless 由 rendererLib='' 触发）
    const job = new NeoForgeProcessorJob();
    job.rootUri = gameRootUri;
    // 工具 JVM 用哪套 JRE：与启动路径同源解析出的 id（`:neoinstall` 据此取 runtime）。
    job.jreId = jreId;
    // **平台伪装：工具 JVM 与游戏 JVM 必须伪装成同一个平台**。前缀 = 同源常量
    // `TOOL_JVM_PLATFORM_SPOOF_ARGS`（定义处 `constants/LaunchDefaults.ets`，内含 `SPOOF_OS_NAME` /
    // `SPOOF_OS_VERSION`；游戏路径的用法见 `MinecraftLauncher.buildLaunchArgv` 的「固定 JVM 参数」段；
    // 本机真 `os.name` = HarmonyOS）。完整机理与排查要点见 `runForgeProcessors` 的同名注释。
    //
    // 为什么**必需**（2026-09-30 真机 stderr 定案，Forge 1.16.5 夹具）：JDK 8（legacy 套）的
    // `sun.nio.fs.DefaultFileSystemProvider.create()` 按 `os.name` **精确匹配**（`Linux` / `SunOS` /
    // `Darwin` / …），匹配不上直接 `AssertionError: Platform not recognized`，且发生在**类初始化期**、
    // 连主类都加载不到 ⇒ JLI 退 1（stderr `A JNI error has occurred`）。
    // 现代套（26）对未知 `os.name` 宽容回退 ⇒ **不要依赖**这一点。渲染 / LWJGL / natives 参数一律不放
    // （工具 headless）。`-Dos.*` 排在其余 `-D` 之前：平台属性须在任何类初始化用到文件系统之前生效。
    //
    // `-Djava.io.tmpdir` 必须指可写沙箱目录（鸿蒙无 /tmp，与游戏路径的注入保持一致）：
    // 部分工具（解压/落盘中间产物）会用它，默认值在设备上不可写。
    job.argv = ['java', ...TOOL_JVM_PLATFORM_SPOOF_ARGS,
      `-Djava.io.tmpdir=${workDir}`, '-cp', plan.classpath.join(':'), plan.mainClass];
    for (const a of plan.argv) {
      job.argv.push(a);
    }
    const jobPath = `${workDir}/job-${i}.json`;
    writeText(jobPath, JSON.stringify(job));
    // 清上一次的结果文件，避免读到陈旧退出码
    const jobStartMs = Date.now();
    try {
      fileIo.unlinkSync(resultPath);
    } catch (e) {
      // 首次运行不存在属正常；但若因权限/IO 失败而残留，下一轮可能读到**陈旧退出码** ⇒ 记一条。
      hilog.info(LOG_DOMAIN, LOG_TAG, 'clear prev result file failed (ignored): %{public}s',
        JSON.stringify(e));
    }
    // **新鲜度基线**：即便上面的 unlink 失败，也据「发起本 processor 时文件已有的字节数」把陈旧内容
    // 排除在裁决之外（桥以**追加**模式写结果文件，见 meowjrebridge.cpp:WriteHeadlessResult）。
    const baseline: ProcessorResultBaseline = {
      offset: resultFileSize(resultPath),
      startMs: jobStartMs,
    };
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      moduleName: 'entry',
      abilityName: NEO_INSTALL_ABILITY,
      parameters: {
        'job': jobPath,
      },
    };
    const options: StartOptions = {
      processMode: contextConstant.ProcessMode.NEW_PROCESS_ATTACH_TO_PARENT,
      startupVisibility: contextConstant.StartupVisibility.STARTUP_HIDE,
    };
    // 上一次 processor 的进程要完全退出后才能再起（否则 16000068）；并对该码做退避重试。
    await waitNeoInstallGone();
    let started = false;
    let lastStartError = '';
    for (let attempt = 0; attempt < PROCESSOR_START_RETRY_MAX && !started; attempt++) {
      try {
        await ctx.startAbility(want, options);
        started = true;
      } catch (error) {
        const err = error as BusinessError;
        lastStartError = `${err.code} ${err.message ?? ''}`;
        const retryable = (err.code === 16000068 || err.code === 16000050);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'startAbility attempt %{public}d failed: %{public}s',
          attempt + 1, lastStartError);
        if (!retryable) {
          break;
        }
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, PROCESSOR_START_BACKOFF_MS * (attempt + 1));
        });
      }
    }
    if (!started) {
      throw new Error(`start install ability failed (${plan.label}): ${lastStartError}`);
    }
    const code = await waitProcessorExit(resultPath, PROCESSOR_TIMEOUT_MS, plan.label, baseline);
    if (code !== 0) {
      throw new Error(`processor failed (${plan.label}) exit=${code}`);
    }
    onCount(i + 1, total);
  }
}

/**
 * `:neoinstall` 进程是否存活（`appManager` 只看本应用进程，无需权限）。
 * 探测失败按「存活」处理——宁可慢，也不要因为探测不到就误判失败。
 */
async function neoInstallProcessAlive(): Promise<boolean> {
  try {
    const list = await appManager.getRunningProcessInformation();
    for (const info of list) {
      if (info.processName.includes(NEO_INSTALL_PROCESS_SUFFIX)) {
        return true;
      }
    }
    return false;
  } catch {
    return true;
  }
}

/**
 * 等 `:neoinstall` 进程完全消失（上一次 processor 的 JVM 刚 `_exit`，能力实例仍在回收窗口中；
 * 立刻再 `startAbility` 会得到 16000068 "The ability is already running"）。
 * 只在**已看到过该进程**时才等待；探测失败按"已退出"处理（重试逻辑兜底）。
 */
async function waitNeoInstallGone(): Promise<void> {
  const deadline = Date.now() + PROCESSOR_GONE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    // `neoInstallProcessAlive()` 内部已吞异常并**按存活**返回（宁可慢也不误判退出）⇒ 无 catch 分支。
    if (!(await neoInstallProcessAlive())) {
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, PROCESSOR_POLL_MS);
    });
  }
}

/**
 * `waitProcessorExit` 的**新鲜度基线**：发起本次 processor 时结果文件已有的字节数与发起时刻。
 * 见 `waitProcessorExit` 文档——用于在 **unlink 可能失败** 的前提下排除陈旧退出码。
 */
interface ProcessorResultBaseline {
  /** 结果文件已有的字节数（unlink 成功/文件不存在 ⇒ 0）。 */
  offset: number;
  /** 发起本次 processor 的时刻（ms；仅用于日志）。 */
  startMs: number;
}

/**
 * 结果文件当前字节数（缺失/读取失败 ⇒ 0）。
 *
 * 用**字节数**（而非 mtime）作新鲜度门限：`fileIo.statSync().mtime` 是**秒级**整数，同一秒内先后
 * 两次 processor 的写入无法区分；而桥对结果文件是**追加**写（`fopen(..., "a")`，见 meowjrebridge.cpp），
 * 每次运行新增的内容必然落在既有字节之后 ⇒ "本次是否新增了 `JLI_RETURNED`" 可用精确、单调的偏移判定。
 */
function resultFileSize(path: string): number {
  try {
    if (!fileIo.accessSync(path)) {
      return 0;
    }
    return fileIo.statSync(path).size;
  } catch {
    return 0;
  }
}

/**
 * 轮询结果文件，等出 `JLI_RETURNED code=N`；超时抛错。
 *
 * 裁决顺序（**返回码权威**）：文件里一旦出现 `JLI_RETURNED code=N` 就按 N 返回（0 成功；非 0
 * 交调用方判失败，**绝不吞**）；只有 `JLI_BEGIN` 而无返回码时，才允许用「进程探测」兜底判异常终结；
 * 两样都没写 = 尚未开始，继续轮询到 deadline。
 *
 * **陈旧退出码防护（`baseline`）**：桥以**追加**模式写结果文件（`WriteHeadlessResult`：`fopen` "a"），
 * 故上一轮若 unlink 失败、文件残留了 `JLI_RETURNED code=0`，只按"文件里有返回码"就会**误把上一轮的
 * 结果当本轮**。这里只认**基线偏移之后**出现的返回码（`baseline.offset` = 发起本轮时文件已有字节数）：
 * unlink 成功 ⇒ 基线 0（整份都是新的）；unlink 失败 ⇒ 基线 = 残留长度，头部旧内容一律不看。文件长度
 * 若小于基线（被截断/重写，正常不该发生）则视为整份新鲜，避免误挂到硬超时。选偏移而非 mtime 的理由
 * 见 `resultFileSize`（mtime 秒级精度不够）。握手文本固定为全 ASCII（`JLI_BEGIN args=N` /
 * `JLI_RETURNED code=N`）⇒ 字节偏移与字符下标一致。
 *
 * 【2026-09-30 设备取证 → 为什么这样改】NeoForge 安装报 `processor terminated without exit code
 * (installertools)`，但握手文件
 * `/data/storage/el2/base/haps/entry/files/meow-neo-jvm-result.txt` 里是
 * `JLI_BEGIN args=13` + `JLI_RETURNED code=0` —— 工具 JVM 明明退了 0（`neo-installer/**` 也有产物、
 * 无 `hs_err_pid*.log`）。桥侧（`meowjrebridge.cpp`：`"JLI_RETURNED code=" + int(code)` 追加一行）
 * 与旧解析器（`lastIndexOf('JLI_RETURNED code=')` + `parseInt`）**文本完全对得上** ⇒ 缺陷不是格式，
 * 而是这段裁决的**竞态**：旧实现用「一个轮询周期前读到的那份 `text`」+「一次瞬时
 * `getRunningProcessInformation` 快照」判死，抛错前**不再重读**。桥是**先写返回码、200ms 后才
 * `_exit`**，故只要这段窗口里返回码已落盘、或快照恰好漏列刚起的 `:neoinstall`，就会在
 * 「code=0 其实已写出」时误判「无退出码」。
 * 现改为：返回码权威、**抛错前重读一次**、进程探测只在**确实见过该进程存活**时才可信
 * （否则一律继续轮询到 deadline —— 2026-09-30 的事故正说明「没列出来」≠「没在跑」）。
 */
async function waitProcessorExit(resultPath: string, timeoutMs: number, label: string,
  baseline: ProcessorResultBaseline): Promise<number> {
  const startMs = Date.now();
  const deadline = startMs + timeoutMs;
  const marker = 'JLI_RETURNED code=';
  // 读一次握手文件；缺失/读失败一律按空串（文件可能正被创建/替换）。空串 ≠ 成功，绝不会误判。
  const readHandshake = (): string => {
    try {
      if (fileIo.accessSync(resultPath)) {
        return fileIo.readTextSync(resultPath);
      }
    } catch {
      // 读失败按空处理（见上）。
    }
    return '';
  };
  // 取返回码；**无返回码行 ⇒ undefined**（与 0 区分开，避免把「还没写」当成「成功」）。
  const returnedCode = (text: string): number | undefined => {
    const at = text.lastIndexOf(marker);
    if (at < 0) {
      return undefined;
    }
    const n = parseInt(text.substring(at + marker.length).split('\n')[0].trim(), 10);
    return Number.isNaN(n) ? -1 : n;   // 有行但非数字 ⇒ -1（沿旧语义：判失败，绝不吞）
  };
  // **新鲜**返回码：只在基线之后的切片里找（排除上一轮 unlink 失败残留的陈旧码）。文件被截断/重写
  // （长度 < 基线，正常不该发生）⇒ 基线按 0 处理（整份新鲜），避免误挂到硬超时。
  const freshReturnedCode = (text: string): number | undefined => {
    const base = text.length < baseline.offset ? 0 : baseline.offset;
    return returnedCode(base > 0 ? text.substring(base) : text);
  };
  // 单行握手摘要（日志用）：空 ⇒ absent；否则标 partial/complete 并附原文（换行折成 " | "）。
  const handshakeDigest = (text: string): string => {
    const t = text.trim();
    if (t.length === 0) {
      return 'absent';
    }
    const body = t.split('\n').join(' | ');
    return returnedCode(text) === undefined ? `partial(${body})` : `complete(${body})`;
  };
  let missedPolls = 0;
  let processEverAlive = false;
  // 软超时起点：**首次**观察到 `JLI_BEGIN`（工具 JVM 确已起）的时刻；0 = 尚未观察到。
  let beginMs = 0;
  while (Date.now() < deadline) {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, PROCESSOR_POLL_MS);
    });
    const text = readHandshake();
    // 1) 返回码权威（只认基线之后的**新鲜**码）：一旦写上立刻裁决，0 与非 0 都原样返回（绝不吞非 0）。
    const code = freshReturnedCode(text);
    if (code !== undefined) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'processor %{public}s handshake returned code=%{public}d elapsedMs=%{public}d',
        label, code, Date.now() - startMs);
      return code;
    }
    // 2) 无返回码：只有看到 `JLI_BEGIN`（JVM 确已起）才允许进程探测兜底；否则继续轮询。
    if (!text.includes('JLI_BEGIN')) {
      continue;
    }
    // 2.5) **软超时**（见 PROCESSOR_SOFT_TIMEOUT_MS）：BEGIN 之后长时间既无退出码、又无存活迹象 ⇒
    //      判工具崩溃/被杀，提前抛**可诊断**错误，别让界面挂满硬上限。只要探针观察到存活即重置起点
    //      （下面 probeAlive 分支），故探针可用的环境里"合法慢"不会被误杀。
    if (beginMs === 0) {
      beginMs = Date.now();
    }
    if (Date.now() - beginMs >= PROCESSOR_SOFT_TIMEOUT_MS) {
      // 已等时长：自 `JLI_BEGIN`（工具 JVM 起）与自 job 发起（含 ability 启动/重试）各报一个。
      const sinceBegin = Date.now() - beginMs;
      const sinceJob = Date.now() - baseline.startMs;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'processor %{public}s soft timeout: no exit code %{public}d ms after JLI_BEGIN and never'
        + ' observed alive (sinceJobStart=%{public}d ms) -> treating as crashed'
        + ' (see hilog and the instance .hmmcraft/logs)', label, sinceBegin, sinceJob);
      throw new Error(`processor appears crashed (${label}): no exit code ${sinceBegin} ms after tool`
        + ` JVM start (${sinceJob} ms since job start) and no liveness signal; see .hmmcraft/logs`);
    }
    if (await neoInstallProcessAlive()) {
      processEverAlive = true;
      missedPolls = 0;
      beginMs = Date.now();   // 探针看到存活 ⇒ 重置软超时起点（合法慢不误杀）
      continue;
    }
    // 3) 探测不到：**仅在确实见过它存活时**才当「已退出」用（否则「没列出来」可能只是快照漏列）。
    if (!processEverAlive) {
      if (missedPolls === 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'processor %{public}s never observed alive; ignoring probe-gone and waiting for handshake (elapsedMs=%{public}d)',
          label, Date.now() - startMs);
      }
      missedPolls++;
      continue;
    }
    // 连续 2 次探测不到才可疑：进程列表是瞬时快照，单次漏列不该误杀正在干活的 processor。
    missedPolls++;
    if (missedPolls < 2) {
      continue;
    }
    // 4) 决定前**重读一次**：此刻若返回码已补上就以它为准 —— 探测绝不覆盖已写出的退出码。
    const recheck = readHandshake();
    const recheckCode = freshReturnedCode(recheck);
    if (recheckCode !== undefined) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'processor %{public}s handshake returned code=%{public}d (on re-read) elapsedMs=%{public}d',
        label, recheckCode, Date.now() - startMs);
      return recheckCode;
    }
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'processor %{public}s ended without exit code: handshake=%{public}s probeAlive=false elapsedMs=%{public}d',
      label, handshakeDigest(recheck), Date.now() - startMs);
    throw new Error(`processor terminated without exit code (${label})`);
  }
  // 到 deadline：再重读一次（返回码可能刚好落盘），拿到就用。
  const finalText = readHandshake();
  const finalCode = freshReturnedCode(finalText);
  if (finalCode !== undefined) {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'processor %{public}s handshake returned code=%{public}d (at timeout) elapsedMs=%{public}d',
      label, finalCode, Date.now() - startMs);
    return finalCode;
  }
  hilog.error(LOG_DOMAIN, LOG_TAG,
    'processor %{public}s timeout after %{public}d ms: handshake=%{public}s probeAlive=%{public}s elapsedMs=%{public}d',
    label, timeoutMs, handshakeDigest(finalText),
    (await neoInstallProcessAlive()) ? 'true' : 'false', Date.now() - startMs);
  throw new Error(`processor timeout (${label}) after ${timeoutMs} ms`);
}

// ---- Forge（**零 JVM 面 = MC 1.7–1.12.2；processor 链面 = 1.13–1.20.1**）----
// 依据：真 installer 实测（工作区根 stuffs/research/forge-support/evidence/**）+ HMCL 做法对照，见
// notes `20-design/launch/Forge支持-调研.md` §11 与 `Forge支持-改动方案.md` §13 /
// `Forge-1.13至1.20.1-安装实施方案.md`（**按 installer 格式事实自研，不搬 HMCL 代码**）。
//
// 判别事实：**"安装要不要 JVM" 只看 client 侧 processor 数**，不是 `spec` 有无 ——
//   · 老形态（`install` + `versionInfo`，无 `spec`；≤1.8.9）：把 installer 内嵌的 universal jar 解到库路径；
//   · `spec` 形态且 0 个 client processor（1.12.2）：installer 内 `maven/**` 命中项 + 主制品纯拷贝；
//   · `spec` 形态且有 client processor（**1.13–1.20.1**）：走**独立**的 processor 链
//     （`installForgeNewVersion` + `ForgeNewInstaller.ets`，与 NeoForge 链代码独立）。
// 盘上格式与 Fabric/NeoForge 同款：顶层扁平 + `patches[game,forge]`。

/** Forge `install_profile.json` 的 `install` 段（老形态；只列用到的字段）。 */
interface ForgeInstallSectionJson {
  /** 主制品坐标（`net.minecraftforge:forge:<mcver>-<forge 版本号>`）。 */
  path?: string;
  /** installer 内嵌 universal jar 的条目名（如 `forge-1.7.10-10.13.4.1614-1.7.10-universal.jar`）。 */
  filePath?: string;
  /** 该 installer 期望的 MC 版本。 */
  minecraft?: string;
}

/** Forge `install_profile.json`（两形态共形；只列判型与落库用到的字段）。 */
interface ForgeInstallProfileJson {
  /** 有 `spec` ⇒ 新形态；无 ⇒ 老形态（`install` + `versionInfo`）。 */
  spec?: number;
  install?: ForgeInstallSectionJson;
  /** 老形态的内嵌启动清单（与版本 json 同形）。 */
  versionInfo?: VersionJson;
  /** 新形态内嵌启动清单的相对路径（如 `/version.json`）。 */
  json?: string;
  /** 新形态主制品坐标。 */
  path?: string;
  /** 新形态的 processor 列表（空 = 纯拷贝；非空 = 需要 JVM）。 */
  processors?: ForgeProcessorJson[];
  /** 库表（新形态的 processor 依赖与主制品；老形态没有这一项）。 */
  libraries?: LibraryJson[];
}

/** 一条 processor（只判"有没有 client 侧任务"，故只取 `sides`）。 */
interface ForgeProcessorJson {
  sides?: string[];
}

/**
 * Forge installer 的解包结果（对齐 NeoForge 的 `NeoForgeArchive`）：`install_profile.json` 与
 * `spec` 形态必需的**内嵌启动清单**（`profile.json` 指向的文件）。老形态的清单在 `profile.versionInfo`
 * 内、无独立文件 ⇒ `launch` 为 undefined。
 */
interface ForgeArchive {
  profile: ForgeInstallProfileJson;
  launch?: VersionJson;
}

/** BMCLAPI 列表里的一条 Forge 构建。 */
interface ForgeBmclEntryJson {
  version?: string;
  mcversion?: string;
  /** 目录名后缀（实测 1.7.10/1.8.9/1.9/1.9.4 非空；1.10.2–1.12.2 为 null）。 */
  branch?: string | null;
  files?: ForgeBmclFileJson[];
}

/**
 * BMCLAPI 列表里的一个文件项（当前只用来判"有没有 installer jar"）。
 *
 * 方案文档 §13.6 第 1 条（"installer jar 无强校验"）中的 `hash` 一问**已实测收口**（2026-10-01）：
 * `category == "installer" && format == "jar"` 的 `hash` **就是**官方 maven 上同名 installer jar 的 sha1
 * （抽样 1.7.10-10.13.4.1614 / 1.7.10-10.13.0.1151 / 1.12.2-14.23.5.2864，三者均与本地或官方文件 sha1 一致）。
 * ⇒ **镜像源**可对 installer 做 sha1 强校验（强于 HMCL 的结构校验：`ForgeInstallTask.java:83` 只挂
 * `ZIP_INTEGRITY_CHECK_HANDLER`）；**官方源**（`maven-metadata.xml` 只有目录名）仍无 hash。
 * 暂未接入安装链（接入需为每次安装多一次 BMCLAPI 往返），故此处只记录结论、不读取该字段。
 */
interface ForgeBmclFileJson {
  category?: string;
  format?: string;
}

/** 拉取结果：把「该版本没有 Forge」与「拉取失败」区分开（UI 文案依赖它，与 NeoForge 同形）。 */
export class ForgeListResult {
  /** 可用构建号（新版在前）。 */
  versions: string[] = [];
  /** 各源的失败摘要（空数组 + 非空摘要 ⇒ 是拉取失败，不是"该版本没有"）。 */
  errors: string = '';
}

/** 该条 BMCL 记录是否带 installer jar（只带源码包/changelog 的构建装不了，不入列表）。 */
function hasForgeInstaller(entry: ForgeBmclEntryJson): boolean {
  for (const f of entry.files ?? []) {
    if (f.category === 'installer' && f.format === 'jar') {
      return true;
    }
  }
  return false;
}

/** 同源结果内排序：新版在前（复用版本 id 的语义化比较，Forge 构建号是点分数字段）。 */
function sortForgeNewestFirst(list: string[]): void {
  list.sort((a: string, b: string): number => compareVersionIds(b, a));
}

/**
 * 从 Forge 官方 `maven-metadata.xml` 取「本 MC 版本的可安装目录名」。
 * 目录名形如 `<mc 版本>-<构建号>[-<branch>]`，去掉 `<mc 版本>-` 前缀即 loader 版本号；
 * 用字符串切分而非正则（该文件里 `<version>` 只出现在 `<versions>` 内，实测 5054 条）。
 */
function forgeVersionsOfMavenMetadata(xml: string, mcVersion: string): string[] {
  const prefix = `${mcVersion}-`;
  const out: string[] = [];
  const parts = xml.split('<version>');
  for (let i = 1; i < parts.length; i++) {
    const name = parts[i].split('</version>')[0].trim();
    if (name.startsWith(prefix)) {
      out.push(name.substring(prefix.length));
    }
  }
  return out;
}

/**
 * 拉取某 MC 版本的 Forge 构建列表（loader 版本号 = **installer 的 maven 目录名去掉 `<mc>-` 前缀**）。
 *
 * **列表源顺序随所选下载源变化**（`source` = `InstallerState.forgeSource`，Forge **自己的**源；语义与
 * Fabric 的 `fabricLoaderListCandidates` 完全一致：**所选源在前，另一源只作"尽力而为"兜底** —— 镜像源才兜到官方，
 * 官方源不碰镜像）：
 *  - 镜像源（SOURCE_MIRROR，默认）：`[BMCLAPI /forge/minecraft/<mc>]` → 失败/空结果时 `[官方 maven-metadata]`；
 *  - 官方源（SOURCE_OFFICIAL）    ：`[官方 maven-metadata]`（**不请求 BMCLAPI**）。
 * 依据 HMCL：列表源与文件源都随用户所选 `DownloadSource` 变化（ref/HMCL `.../setting/DownloadProviders.java:88-97`），
 * 且 BMCLAPI 的 Forge 列表是**独立端点**（`.../forge/ForgeBMCLVersionList.java:79`），不是官方 URL 换域名
 * ⇒ 只能这样显式分流（见 notes 20-design/launch/Forge支持-调研.md §2）。
 *
 * 每个源内部：
 *  - HTTP 4xx ⇒ 由 `fetchText` 判失败（**不解析 body**）→ 继续下一个源；
 *  - HTTP 200 + **空结果** ⇒ 视为「该源无结果」→ 继续下一个源（**不要**直接断定"无可用版本"）。
 * 两源形状不同：BMCLAPI 给分层字段（`version` + `branch`，**目录名要两段拼**，且带 installer 文件信息），
 * 官方元数据直接给目录名（更权威，但无法判"有没有 installer"）。
 */
export async function fetchForgeVersions(mcVersion: string, source: string): Promise<ForgeListResult> {
  const result = new ForgeListResult();
  if (mcVersion.length === 0) {
    return result;
  }

  // 只有镜像源（含默认值）才先走 BMCLAPI 列表端点；官方源从官方 maven-metadata 起步。
  const mirrorFirst = source !== SOURCE_OFFICIAL;
  if (mirrorFirst) {
    try {
      const text = await fetchText([forgeBmclListUrl(mcVersion)],
        [HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_NOT_FOUND]);
      const parsed = JSON.parse(text) as (ForgeBmclEntryJson | null)[];
      const out: string[] = [];
      if (Array.isArray(parsed)) {
        for (const entry of parsed) {
          if (entry === null) {
            continue;
          }
          const version = entry.version ?? '';
          if (version.length === 0) {
            continue;
          }
          // 端点本就按 MC 版本查询；记录自带 mcversion 时再核一次（实测老数据有缺字段的记录，缺则照收）。
          const mc = entry.mcversion ?? '';
          if (mc.length > 0 && mc !== mcVersion) {
            continue;
          }
          if (!hasForgeInstaller(entry)) {
            continue;
          }
          // 目录名 = `<mc>-<version>[-<branch>]`：branch 非空时必须带上（否则该目录下没有 installer）。
          const branch = entry.branch ?? '';
          out.push(branch.length > 0 ? `${version}-${branch}` : version);
        }
      }
      if (out.length > 0) {
        sortForgeNewestFirst(out);
        result.versions = out;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'forge bmclapi list ok: %{public}d items for %{public}s',
          out.length, mcVersion);
        return result;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'forge bmclapi list empty for %{public}s, try official', mcVersion);
    } catch (error) {
      const err = error as BusinessError;
      result.errors += `bmclapi: ${err.message ?? ''}; `;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'forge bmclapi list failed: %{public}s', err.message ?? '');
    }
  }

  try {
    const text = await fetchText(forgeMetadataCandidates(source));
    const out = forgeVersionsOfMavenMetadata(text, mcVersion);
    if (out.length > 0) {
      sortForgeNewestFirst(out);
      result.versions = out;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'forge official list ok: %{public}d items for %{public}s',
        out.length, mcVersion);
    }
  } catch (error) {
    const err = error as BusinessError;
    result.errors += `official: ${err.message ?? ''}; `;
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'forge official list failed: %{public}s', err.message ?? '');
  }
  return result;
}

/**
 * Forge installer 形态：
 * - `LEGACY`：老形态（无 `spec`，`install` + `versionInfo`；≤1.8.9）——零 JVM，纯拷贝；
 * - `SPEC_NO_PROCESSOR`：`spec` 形态且 client processor = 0（1.12.2）——零 JVM，内嵌 `maven/**` 命中项拷贝；
 * - `SPEC_PROCESSORS`：`spec` 形态且 client processor > 0（**1.13–1.20.1**）——需外部 JVM（processor 链）；
 * - `UNSUPPORTED`：两键皆无（格式不认识）——**明确拒绝**（且必须在写清单之前）。
 */
export const FORGE_FORM_LEGACY: string = 'legacy';
export const FORGE_FORM_SPEC_NO_PROCESSOR: string = 'spec-no-processor';
export const FORGE_FORM_SPEC_PROCESSORS: string = 'spec-processors';
export const FORGE_FORM_UNSUPPORTED: string = 'unsupported';

/** client 侧 processor 数（`sides` 缺省 = 双端；这是「安装要不要 JVM」的唯一依据）。 */
function forgeClientProcessorCount(profile: ForgeInstallProfileJson): number {
  let n = 0;
  for (const p of profile.processors ?? []) {
    if (p.sides === undefined || p.sides.includes('client')) {
      n++;
    }
  }
  return n;
}

/**
 * 判型（对齐 HMCL `ForgeInstallTask.detectForgeInstallerType` 的**键判据**，但"要不要 JVM"落在 processor 数上）：
 * 含 `spec` ⇒ 新形态（client processor > 0 = 需外部 JVM；= 0 = 零 JVM）；含 `install` 且含 `versionInfo`
 * ⇒ 老形态；**两键皆无** ⇒ 拒绝。`spec` 的具体值与该世代主制品形态无关，MC 版本号完全不参与判型。
 */
export function classifyForgeProfile(profile: ForgeInstallProfileJson): string {
  if (profile.spec !== undefined) {
    return forgeClientProcessorCount(profile) > 0 ? FORGE_FORM_SPEC_PROCESSORS : FORGE_FORM_SPEC_NO_PROCESSOR;
  }
  if (profile.install !== undefined && profile.versionInfo !== undefined) {
    return FORGE_FORM_LEGACY;
  }
  return FORGE_FORM_UNSUPPORTED;
}

/**
 * 库的 maven 相对路径：优先用 `downloads.artifact.path`（**必须与 `libraryItem` 的落点一致**，
 * 否则 `url` 为空的主制品不会被"目标已存在即跳过"接住），否则由坐标算（与 HMCL `Library.getPath()` 同义）。
 */
function forgeLibraryRelPath(lib: LibraryJson): string {
  const declared = lib.downloads?.artifact?.path ?? '';
  return declared.length > 0 ? declared : mavenPath(lib.name ?? '');
}

/** 把 installer 的解包产物拷到目标路径（源不存在 ⇒ 抛错；可选件由调用方先判 `exists`）。 */
function copyFromUnzip(srcPath: string, destPath: string): void {
  ensureParent(destPath);
  try {
    fileIo.copyFileSync(srcPath, destPath);
  } catch (error) {
    const err = error as BusinessError;
    throw new Error(`extract ${srcPath} failed: ${err.message ?? ''}`);
  }
}

/**
 * 库的合并键：主制品取 `group:artifact`；**natives / classifier 件另给一个键** ——
 * 它们的物理产物（natives jar）与同坐标的主 jar 是两份文件、两种角色，二者并存不算重复，
 * 不能互相顶掉（HMCL 的 `LaunchManifestNormalizer.uniqueLibraries` 对"同 id 同版本但坐标载荷不同"
 * 的项（其注释举 `text2speech` jar vs natives）也是两个都留，见 ref/HMCL `LaunchManifestNormalizer.java:270-317`）。
 * 坐标解析不出时返回空串（不参与去重）。
 */
function libraryMergeKey(lib: LibraryJson): string {
  const core = (lib.name ?? '').split('@')[0];
  const parts = core.split(':');
  if (parts.length < 2) {
    return '';
  }
  const coord = `${parts[0]}:${parts[1]}`;
  const dl = lib.downloads;
  const isNatives = parts.length >= 4
    || lib.natives !== undefined
    || (dl !== undefined && dl.artifact === undefined && dl.classifiers !== undefined);
  return isNatives ? `${coord}:natives` : coord;
}

/**
 * 合并两层补丁的库表（Forge 实例顶层扁平化用）：**按坐标去重，高优先级补丁胜出**。
 *
 * 依据（2026-09-29）：HMCL 实例 `stuffs/test-forge/versions/1.7.10-Forge/1.7.10-Forge.json` 的顶层
 * = 48 条（forge 18 条在前、game 30 条在后）；而 `concatLibs(game, forge)` 直接并出 **51** 条 ——
 * `com.google.guava:guava`（15.0 vs 17.0）、`org.apache.commons:commons-lang3`（3.1 vs 3.3.2）、
 * `net.sf.jopt-simple:jopt-simple`（4.5 两遍）三组同坐标各进两份。顶层会被平铺成 `-cp <dir>/*`
 * 单目录（`ClasspathStager`）⇒ 同坐标两份的类加载随文件系统顺序而定（不确定）。
 * 我们的 `patches[]` 带 priority（game 0 / forge 30000）⇒ **优先级高的整份在前**，低优先级里与高优先级
 * 同坐标的项跳过（其余保持并集语义与顺序）。natives/classifier 件另键，不参与同坐标合并。
 */
function mergeLibsByCoordinate(highPriority?: LibraryJson[],
  lowPriority?: LibraryJson[]): LibraryJson[] | undefined {
  if (highPriority === undefined && lowPriority === undefined) {
    return undefined;
  }
  const out: LibraryJson[] = [];
  const seen: Set<string> = new Set<string>();
  for (const lib of highPriority ?? []) {
    const key = libraryMergeKey(lib);
    if (key.length > 0 && seen.has(key)) {
      continue;
    }
    if (key.length > 0) {
      seen.add(key);
    }
    out.push(lib);
  }
  for (const lib of lowPriority ?? []) {
    const key = libraryMergeKey(lib);
    if (key.length > 0 && seen.has(key)) {
      continue;
    }
    if (key.length > 0) {
      seen.add(key);
    }
    out.push(lib);
  }
  return out;
}

/**
 * 组装 Forge 实例清单（HMCL 形态）：顶层扁平 + `patches[game, forge]`。
 *
 * - `game` patch：vanilla 全部字段（priority 0）；
 * - `forge` patch：启动清单模板（老 = `install.versionInfo`；新 = 内嵌 `version.json`）的字段，
 *   priority 30000（= HMCL 的 `PRIORITY_LOADER`）；
 * - 顶层：`mainClass` / `minecraftArguments` 取 Forge（`--tweakClass …FMLTweaker` **原样携带**），
 *   `libraries` = **forge ++ vanilla，按坐标去重**（`mergeLibsByCoordinate`：高优先级 patch 胜出；
 *   Java 侧只读顶层 ⇒ 必须并进来，但同坐标只能留一份，理由与证据见该函数注释）；
 * - 模板自带的 `inheritsFrom`（如 `1.7.10`）**不进顶层**：vanilla 字段已摊平，实例自带 `<名>.jar`。
 * 注意：gamePatch 必须在改写 vanilla 之前构造（否则会拿到被覆盖后的值）。
 *
 * `runtimeLibraries`（**只取内嵌清单**的运行期库表）：两条链的 `forge` 库表语义**不同**，故显式传入：
 * - ≤1.12.2 零 JVM 链（老形态 / `spec` + 0 processor）：`forge` 就是 installer 内嵌的启动清单
 *   （`install.versionInfo` 或 `version.json`），**它就是运行期权威库表** ⇒ 省略该参数、直接用
 *   `forge.libraries`（**语义不变，不许改动**）；
 * - **1.13–1.20.1 processor 链**：必须显式传 **内嵌 `version.json` 的 `libraries`**，**绝不**并入
 *   `install_profile.json` 的 `libraries`（那份是**安装期工具**：`installertools` / `jarsplitter` /
 *   `SpecialSource` / `binarypatcher` / `mcp_config` / `fmlcore` …；混进 classpath 会把工具 jar 塞给游戏，
 *   对 ② 代的 `-p`/模块解析尤其会引入噪声）。
 *   依据 HMCL（逐行取证）：`ForgeNewInstallTask.execute()` 把 patch 建自**内嵌 `version.json`**
 *   （`setResult(GameInstancePatch.fromManifest(forgeVersion, …))`，`forgeVersion` = `profile.getJson()` 读出的
 *   清单），`profile.getLibraries()` **只用于下载**（`GameLibrariesTask`，见 `doPreExecute`）⇒ 运行期清单里
 *   没有安装期工具。HMCL 的同版本实例 json 亦为逐条实证（`stuffs/test-higher-forge/versions/1.20.1-Forge/`、
 *   `1.16.5-Forge/`：`patches[forge].libraries` 与内嵌 `version.json` 的库表**逐条相等**，且不含
 *   `:universal` / `:client` / 任何 `installertools` 家族）。
 */
function composeForgeManifest(vanilla: VersionJson, instanceName: string, gameVersion: string,
  loaderVersion: string, forge: VersionJson, runtimeLibraries?: LibraryJson[]): VersionJson {
  // 运行期 forge 库表：显式传入者优先（**只取内嵌清单**的 processor 链），否则用模板自带的（≤1.12.2 链）。
  const forgeLibs = runtimeLibraries ?? forge.libraries;
  const gamePatch: PatchJson = {
    id: 'game',
    version: gameVersion,
    priority: 0,
    mainClass: vanilla.mainClass,
    minecraftArguments: vanilla.minecraftArguments,
    arguments: vanilla.arguments,
    libraries: vanilla.libraries,
    assets: vanilla.assets,
    assetIndex: vanilla.assetIndex,
    downloads: vanilla.downloads,
    javaVersion: vanilla.javaVersion,
    type: vanilla.type,
    time: vanilla.time,
    releaseTime: vanilla.releaseTime,
    minimumLauncherVersion: vanilla.minimumLauncherVersion,
    complianceLevel: vanilla.complianceLevel,
    compatibilityRules: vanilla.compatibilityRules,
    logging: vanilla.logging
  };
  const forgePatch: PatchJson = {
    id: 'forge',
    version: loaderVersion,
    priority: 30000,
    mainClass: forge.mainClass,
    minecraftArguments: forge.minecraftArguments,
    arguments: forge.arguments,
    libraries: forgeLibs,
    type: forge.type,
    time: forge.time,
    releaseTime: forge.releaseTime,
    logging: forge.logging,
    complianceLevel: forge.complianceLevel
  };
  const mainClass = forge.mainClass ?? '';
  const args = forge.minecraftArguments ?? '';
  vanilla.id = instanceName;
  vanilla.jar = instanceName;
  vanilla.root = true;
  if (mainClass.length > 0) {
    vanilla.mainClass = mainClass;
  }
  if (args.length > 0) {
    vanilla.minecraftArguments = args;
  }
  vanilla.libraries = mergeLibsByCoordinate(forgeLibs, vanilla.libraries);
  vanilla.arguments = concatArgs(vanilla.arguments, forge.arguments);
  vanilla.patches = [gamePatch, forgePatch];
  return vanilla;
}

/**
 * Forge installer jar 不可用：所选构建的所有候选地址都失败（例如官方列表列出"不带 installer"的构建）。
 * 单独成形，好让 UI 层把它从泛用的"安装失败"里区分出来（专属、可操作的逐构建文案）。
 */
export class ForgeInstallerUnavailableError extends Error {
  /** 出问题的构建（`<mc>-<loaderVersion>`）。 */
  readonly buildId: string;

  constructor(buildId: string) {
    super(`forge installer jar unavailable: ${buildId}`);
    this.name = 'ForgeInstallerUnavailableError';
    this.buildId = buildId;
  }
}

/**
 * 安装 Forge 实例（**零 JVM 面：MC 1.7–1.12.2**；installer jar 只作数据容器）。
 *
 * 步骤：拉 vanilla 清单 → 下 installer jar → 解包读
 * `install_profile.json` 判型 → 按形态把 loader 制品落共享库区 → 下 vanilla 资产（client jar 落
 * `<名>.jar`）与 Forge 库（老 = 模板库表；新 = profile 库表 + 模板库表）→ 写清单。
 *
 * **整个安装按 `loaderSource`（Forge 自己的下载源）**——Forge 制品来自 MinecraftForge、不是 Mojang，
 * 故不复用版本源（与 `installFabricVersion` 传 `loaderSource` 的语义一致）：
 *  - vanilla 清单 / client jar / 原版库 / 资源：`loaderSource`（镜像时 BMCLAPI 重写，官方时直连原 host）；
 *  - installer jar：`forgeInstallerCandidates(…, loaderSource)`；
 *  - Forge 库：`runDownloads(…, loaderSource)` → `fileCandidates`（同一个前缀重写表）。
 * 镜像源 = 镜像优先 + 官方兜底，官方源 = 仅官方。
 * 依据 HMCL `DownloadProvider.injectURL*` 与 `BMCLAPIDownloadProvider.replacement`
 * （ref/HMCL `.../download/BMCLAPIDownloadProvider.java:84-86,141-171`）。
 *
 * ⚠️ `spec` 形态带 client processor（**1.13–1.20.1**，需外部 JVM）⇒ 本函数**在写出清单之前**分派到
 * `installForgeNewVersion`（独立的 processor 链）；"两键皆无"的坏 profile ⇒ 在写清单前**明确拒绝**，
 * 以免留下"能列出但起不来"的残缺实例。
 *
 * `ctx` / `gameRootUri` / `jreId` 只服务于 processor 链（`spec` + processor 形态）：老形态与
 * `spec-no-processor` 形态**零 JVM**，这组参数被忽略（与 `installNeoForgeVersion` 对齐签名，便于上层统一透传）。
 */
export async function installForgeVersion(ctx: common.UIAbilityContext, gameRoot: string,
  gameRootUri: string, gameRemote: RemoteVersion,
  loaderVersion: string, instanceName: string, loaderSource: string, cacheDir: string, jreId: string,
  onPhase: (phase: number) => void,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  if (!isValidInstanceName(instanceName)) {
    throw new Error('invalid instance name');
  }
  if (loaderVersion.length === 0) {
    throw new Error('forge loader version missing');
  }

  // 1) installer jar → 解包 → 判型（**先做**，便于按形态分派：`spec` + processor 形态走独立的 processor 链；
  //    vanilla 清单在下面"3)"才取，避免对 processor 形态多做一次无用往返）。
  //    工作目录按 **下载源 + loader 版本** 定位（跨实例复用），先清后解。
  //    把 `loaderSource` 纳入目录名：installer.jar 按路径"命中即跳过"，若不带源，切换下载源后会**静默复用**
  //    另一源下过的文件（切源 = 不做任何下载、也看不出选的是哪个源）。隔离后，切源必按新候选顺序重下，
  //    "所选源"在磁盘布局上也可观测。整棵 `forge-installer/` 由 `CacheCleaner` 清理（见 CacheCleaner.ets）。
  //    注：同一个 (mc, loader) 的 installer 在不同源下内容一致（BMCLAPI 是 Forge maven 的镜像），
  //    故这是"可观测性 + 不跨源静默复用"的取舍，代价是切源后重下一次（installer 无 sha1 可校，见 §13.6.1）。
  onPhase(PHASE_FILES);
  const workDir = `${cacheDir}/${FORGE_INSTALLER_DIR}/${loaderSource}/${loaderVersion}`;
  ensureDir(workDir);
  const jarPath = `${workDir}/installer.jar`;
  const unzipDir = `${workDir}/unzipped`;

  // 下 installer jar。候选顺序见 `forgeInstallerCandidates`（镜像源 = [镜像, 官方]；官方源 = [官方]）。
  // **直接走下载原语**以确保官方兜底不丢：`runDownloads` 只对 `urls[0]` 再做一次前缀展开，
  // 而 `urls[0]` 若已是镜像地址就展不出官方了。
  const downloadInstaller = async (): Promise<void> => {
    const installerUrls = forgeInstallerCandidates(gameRemote.id, loaderVersion, loaderSource);
    onCount(0, 1);
    onCurrent('forge-installer.jar');
    try {
      await downloadFile(installerUrls, jarPath, '', onFileProgress);
    } catch (error) {
      // 官方列表（`maven-metadata.xml`）只有目录名、**没有文件清单** ⇒ 会列出"该目录不含 installer jar"的
      // 构建（HMCL 不踩这个坑：它的列表项自带文件表，镜像端点更直接过滤 `category == "installer"`）。
      // 所有候选都失败 ⇒ 按"该构建没有安装器"给出**逐构建**的可读错误（而非常规的下载失败）。
      // 仅此一步分型：其余下载失败继续走泛用的 INSTALL_ERR_INSTALL（见 InstallerState）。
      const err = error as BusinessError;
      const buildId = `${gameRemote.id}-${loaderVersion}`;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'forge installer jar unavailable for build %{public}s; candidates tried: %{public}s; last error: %{public}s',
        buildId, installerUrls.join(', '), err.message ?? '');
      throw new ForgeInstallerUnavailableError(buildId);
    }
    onCount(1, 1);
  };

  // 解包 installer 并读所需文件（先清后解）；任一步失败即视为"这个 jar 不可用"。
  // 复用校验须覆盖**下游真正要用的东西**（对齐 NeoForge 的 `NeoForgeArchive`）：除 `install_profile.json` 外，
  // `spec` 形态的启动清单在 `profile.json` 指向的内嵌文件里、且下游在 **try/catch 之外**才读它
  // ⇒ 若这里只证明有 `install_profile.json`，这类坏缓存会通过自愈、然后在同一处反复失败（评审：Forge 复用
  // 校验应与 NeoForge 校验同样的事项）。故**所有 `spec` 形态**（含 1.13+ 的 `FORGE_FORM_SPEC_PROCESSORS`）
  // 在这里一并读到，缺任一即判坏——否则"有 profile、缺内嵌清单"的坏缓存会通过自愈、在 processor 链里才炸。
  const extractArchive = async (): Promise<ForgeArchive> => {
    removeTreeBestEffort(unzipDir);
    ensureDir(unzipDir);
    onCurrent('installer-profile');
    await zlib.decompressFile(jarPath, unzipDir);
    const profile = readJsonFile<ForgeInstallProfileJson>(`${unzipDir}/install_profile.json`);
    const form = classifyForgeProfile(profile);
    if (form === FORGE_FORM_SPEC_NO_PROCESSOR || form === FORGE_FORM_SPEC_PROCESSORS) {
      const rel = (profile.json ?? '/version.json').replace(/^\//, '');
      const launch = readJsonFile<VersionJson>(`${unzipDir}/${rel}`);
      return { profile: profile, launch: launch };
    }
    return { profile: profile };
  };

  // `installer.jar` 按路径"命中即跳过"⇒ 复用到的文件若已损坏（半截 / 被破坏），必须能**自愈**，
  // 否则坏文件会被永久复用（每次都在下游解包/读 profile 处失败，且永远不重下）。
  // HMCL 不靠"路径命中即跳过"：它每次下到临时文件、ZIP 结构校验通过才落盘、用完即删
  // （ref/HMCL `.../download/forge/ForgeInstallTask.java:76-84`、`:92-93`），坏文件从不进持久位置。
  // 这里保留跨实例复用的缓存目录，但**复用前先解一次**：解不开、或解不出所需文件（`install_profile.json`，
  // `spec` 形态还需内嵌启动清单 —— 见 `extractArchive`），即判为坏文件 → 删除 → 重下再解。
  // 于是坏缓存最多只影响当次任务（当次即修），不会永久卡死。
  let archive: ForgeArchive | null = null;
  if (exists(jarPath)) {
    try {
      archive = await extractArchive();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'cached forge installer unusable, re-downloading: %{public}s (%{public}s)', jarPath, err.message ?? '');
      try {
        fileIo.unlinkSync(jarPath);
      } catch {
        // 删除失败也继续：`downloadFile` 落盘前会先删目标再 rename。
      }
    }
  }
  if (archive === null) {
    await downloadInstaller();
    archive = await extractArchive();
  }
  const profile = archive.profile;
  const form = classifyForgeProfile(profile);
  if (form === FORGE_FORM_SPEC_PROCESSORS) {
    // 新格式 + client processor（**1.13–1.20.1**）：走**独立**的 processor 链（与 installNeoForgeVersion 平行，
    // 但不复用其任何函数）。installer 已下好并解包过一次（缓存命中即跳过），新链复用同一 workDir/缓存。
    hilog.info(LOG_DOMAIN, LOG_TAG, 'forge spec+processors form (client=%{public}d); delegating to new chain',
      forgeClientProcessorCount(profile));
    await installForgeNewVersion(ctx, gameRoot, gameRootUri, gameRemote, loaderVersion, instanceName,
      loaderSource, cacheDir, jreId, onPhase, onCount, onCurrent, onFileProgress);
    return;
  }
  if (form === FORGE_FORM_UNSUPPORTED) {
    // 明确拒绝（且不留残缺实例）：两键皆无 = 格式不认识（`spec`/`processors` 不再落入此分支）。
    hilog.error(LOG_DOMAIN, LOG_TAG, 'forge install unsupported: unknown install_profile.json format (loader %{public}s)',
      loaderVersion);
    throw new Error('forge install unsupported: unknown install_profile.json format');
  }

  // 2) vanilla 清单（Forge 源）
  const vanillaText = await fetchText(fileCandidates(gameRemote.url, loaderSource));
  const vanilla = JSON.parse(vanillaText) as VersionJson;
  const gameVersion = (vanilla.id ?? '').length > 0 ? (vanilla.id ?? '') : gameRemote.id;

  // 3) 启动清单模板：老形态 = `install.versionInfo`；新形态 = 内嵌 `profile.json`（如 `/version.json`，
  //    已在 `extractArchive` 复用校验时读到）。
  let template: VersionJson;
  if (form === FORGE_FORM_LEGACY) {
    const info = profile.versionInfo;
    if (info === undefined) {
      throw new Error('forge install profile incomplete');
    }
    template = info;
  } else {
    const launch = archive.launch;
    if (launch === undefined) {
      throw new Error('forge install profile incomplete');
    }
    template = launch;
  }

  // 4) loader 制品落共享库区。**必须在库下载之前**：主制品在库表里 `url` 为空（Forge 官方的写法），
  //    靠"目标已存在即跳过"的语义接住这一步落位，否则会退到缺省库仓找它（必然 404）。
  if (form === FORGE_FORM_LEGACY) {
    const rel = mavenPath(profile.install?.path ?? '');
    const entry = profile.install?.filePath ?? '';
    if (rel.length === 0 || entry.length === 0) {
      throw new Error('forge install profile incomplete');
    }
    const src = `${unzipDir}/${entry}`;
    if (!exists(src)) {
      throw new Error(`forge universal jar missing in installer: ${entry}`);
    }
    copyFromUnzip(src, `${librariesDir(gameRoot)}/${rel}`);
  } else {
    // 新形态且 0 processor：installer 内 `maven/**` 命中项 + 主制品纯拷贝（只有随包内嵌的才有，其余靠下载）。
    for (const lib of profile.libraries ?? []) {
      const rel = forgeLibraryRelPath(lib);
      if (rel.length === 0) {
        continue;
      }
      const src = `${unzipDir}/maven/${rel}`;
      if (exists(src)) {
        copyFromUnzip(src, `${librariesDir(gameRoot)}/${rel}`);
      }
    }
    const mainRel = mavenPath(profile.path ?? '');
    const mainSrc = mainRel.length > 0 ? `${unzipDir}/maven/${mainRel}` : '';
    if (mainSrc.length > 0 && exists(mainSrc)) {
      copyFromUnzip(mainSrc, `${librariesDir(gameRoot)}/${mainRel}`);
    }
  }

  // 5) Forge 库表：老形态只有模板库表；新形态 = profile 库表（processor 依赖与主制品）+ 模板库表
  //    （1.12.2 的绝大部分库在模板里）。
  const forgeLibs: LibraryJson[] = [];
  if (form === FORGE_FORM_LEGACY) {
    for (const l of profile.versionInfo?.libraries ?? []) {
      forgeLibs.push(l);
    }
  } else {
    for (const l of profile.libraries ?? []) {
      forgeLibs.push(l);
    }
    for (const l of template.libraries ?? []) {
      forgeLibs.push(l);
    }
  }

  // 6) 待下载项：vanilla（client jar 落 `<名>.jar` + 原版库 + 资源索引）+ Forge 库（共享库区）。
  const files: DownloadItem[] = [];
  const client = vanilla.downloads?.client;
  if (client !== undefined) {
    const url = client.url ?? '';
    if (url.length > 0) {
      files.push(newItem(`${instanceName}.jar`, [url], versionJarPath(gameRoot, instanceName),
        client.sha1 ?? '', client.size ?? 0));
    }
  }
  for (const lib of vanilla.libraries ?? []) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  const indexItem = assetIndexItem(gameRoot, vanilla.assets ?? '', vanilla.assetIndex);
  if (indexItem !== null) {
    files.push(indexItem);
  }
  for (const lib of forgeLibs) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  await runDownloads(files, loaderSource, onCount, onCurrent, onFileProgress);

  // 7) 资源对象（依赖已下好的索引；Forge 源）
  const assetId = (vanilla.assetIndex?.id ?? '').length > 0
    ? (vanilla.assetIndex?.id ?? '')
    : (vanilla.assets ?? '');
  if (indexItem !== null && assetId.length > 0) {
    onPhase(PHASE_ASSETS);
    let index: AssetIndexJson = {};
    try {
      index = JSON.parse(fileIo.readTextSync(`${assetsIndexesDir(gameRoot)}/${assetId}.json`)) as AssetIndexJson;
    } catch {
      index = {};
    }
    await runDownloads(assetObjectItems(gameRoot, index), loaderSource, onCount, onCurrent, onFileProgress);
  }

  // 8) 写清单：顶层扁平 + patches[game, forge]
  onPhase(PHASE_WRITE);
  const composed = composeForgeManifest(vanilla, instanceName, gameVersion, loaderVersion, template);
  writeText(versionJsonPath(gameRoot, instanceName), JSON.stringify(composed));
}

// ---- Forge 新格式 processor 链（**MC 1.13–1.20.1**；与 NeoForge 链代码独立）----
// 依据：真 installer 实测（1.13.2 / 1.14.4 / 1.15.2 / 1.16.5 / 1.17.1 / 1.18.2 / 1.19.4 / 1.20.1）+
// notes `Forge-1.13至1.20.1-安装实施方案.md`、`Forge-1.13及以上-调研与方案.md` §2。
// 本段**不复用** `NeoForgeInstaller` / `installNeoForgeVersion` / `runNeoForgeProcessors` 的任何符号，
// 只复用 loader 无关的落盘原语（`downloadFile`/`runDownloads`/`libraryItem`/`writeText`/`copyFromUnzip`/
// `forgeLibraryRelPath`/`mergeLibsByCoordinate`/`composeForgeManifest`）与**平台载体**（`:neoinstall` + job 文件协议）。

/** Forge 新格式 installer 的解包结果：`install_profile.json`（含 `data`/`outputs`）与内嵌启动清单。 */
interface ForgeNewArchive {
  profile: ForgeNewInstallProfileJson;
  launch: VersionJson;
}

/** `runForgeProcessors` / `forgeWaitProcessorExit` 的**新鲜度基线**：发起本次 processor 时结果文件已有的字节数与发起时刻。 */
interface ForgeProcessorBaseline {
  /** 结果文件已有的字节数（unlink 成功/文件不存在 ⇒ 0）。 */
  offset: number;
  /** 发起本次 processor 的时刻（ms；仅用于日志）。 */
  startMs: number;
}

/**
 * 安装 Forge **新格式**实例（`install_profile.json` 带 `spec` 且 client processor > 0；**MC 1.13–1.20.1**）。
 *
 * 步骤：拉 vanilla 清单 → installer 获取/自愈/解包（`install_profile.json` + 内嵌 `version.json`）→
 * **G1 内嵌 `maven/**` 解包**（1.13–1.16.5 的主制品与 `:universal` 的库 `url` 为空，只能从这里取；
 * **必须在库下载之前**）→ 下 vanilla 资产与两份库（profile.libraries + 内嵌清单的 libraries）→
 * 【G3 `outputs` 幂等 + processor 链】→ 写清单（HMCL 形态：顶层扁平 + `patches[game, forge]`）。
 *
 * 签名与 `installNeoForgeVersion` 对齐：整条链按 `loaderSource`（Forge 自己的源）；`jreId` = processor
 * **工具 JVM** 用的那套 JRE（由 `confirmInstall` 经 `JavaPolicy` 按 (MC 版本 × Forge) 解析，与启动路径同源），
 * 仅透传到 `:neoinstall`，本函数不解析 JRE。
 */
export async function installForgeNewVersion(ctx: common.UIAbilityContext, gameRoot: string,
  gameRootUri: string, gameRemote: RemoteVersion, loaderVersion: string, instanceName: string,
  loaderSource: string, cacheDir: string, jreId: string,
  onPhase: (phase: number) => void,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  if (!isValidInstanceName(instanceName)) {
    throw new Error('invalid instance name');
  }
  if (loaderVersion.length === 0) {
    throw new Error('forge loader version missing');
  }

  // 1) vanilla 清单（Forge 源）
  onPhase(PHASE_FILES);
  const vanillaText = await fetchText(fileCandidates(gameRemote.url, loaderSource));
  const vanilla = JSON.parse(vanillaText) as VersionJson;
  const gameVersion = (vanilla.id ?? '').length > 0 ? (vanilla.id ?? '') : gameRemote.id;

  // 2) installer jar → 解包（与 installForgeVersion 同 workDir；缓存命中即复用，不再重下）。
  const workDir = `${cacheDir}/${FORGE_INSTALLER_DIR}/${loaderSource}/${loaderVersion}`;
  ensureDir(workDir);
  const jarPath = `${workDir}/installer.jar`;
  const unzipDir = `${workDir}/unzipped`;

  const downloadInstaller = async (): Promise<void> => {
    const installerUrls = forgeInstallerCandidates(gameRemote.id, loaderVersion, loaderSource);
    onCount(0, 1);
    onCurrent('forge-installer.jar');
    try {
      await downloadFile(installerUrls, jarPath, '', onFileProgress);
    } catch (error) {
      const err = error as BusinessError;
      const buildId = `${gameRemote.id}-${loaderVersion}`;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'forge installer jar unavailable for build %{public}s; candidates tried: %{public}s; last error: %{public}s',
        buildId, installerUrls.join(', '), err.message ?? '');
      throw new ForgeInstallerUnavailableError(buildId);
    }
    onCount(1, 1);
  };

  // 解包（先清后解）：profile 与内嵌启动清单**都读到**才算"这个 jar 可用"（F3：自愈面覆盖内嵌清单）。
  const extractNewArchive = async (): Promise<ForgeNewArchive> => {
    removeTreeBestEffort(unzipDir);
    ensureDir(unzipDir);
    onCurrent('installer-profile');
    await zlib.decompressFile(jarPath, unzipDir);
    const profile = readJsonFile<ForgeNewInstallProfileJson>(`${unzipDir}/install_profile.json`);
    const rel = (profile.json ?? '/version.json').replace(/^\//, '');
    const launch = readJsonFile<VersionJson>(`${unzipDir}/${rel}`);
    return { profile: profile, launch: launch };
  };

  let archive: ForgeNewArchive | null = null;
  if (exists(jarPath)) {
    try {
      archive = await extractNewArchive();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'cached forge installer unusable, re-downloading: %{public}s (%{public}s)', jarPath, err.message ?? '');
      try {
        fileIo.unlinkSync(jarPath);
      } catch {
        // 删除失败也继续：`downloadFile` 落盘前会先删目标再 rename。
      }
    }
  }
  if (archive === null) {
    await downloadInstaller();
    archive = await extractNewArchive();
  }
  const profile = archive.profile;
  const launch = archive.launch;
  const profileLibs = (profile.libraries ?? []) as LibraryJson[];

  // 3) **G1：内嵌 `maven/**` 解包**（1.13–1.16.5 的**必需项**，**必须在库下载之前**）。
  //    真件：主制品（`profile.path`）与 `:universal` 库条目的 `downloads.artifact.url` 都是 `""`
  //    ⇒ `libraryItem` 会穿透到 `DEFAULT_LIBRARY_URL`（libraries.minecraft.net）生成 404；
  //    靠"目标已存在即跳过"的语义接住这一步落位（与 1.12.2 分支同款）。rel 必须与 `libraryItem` 落点一致
  //    （`forgeLibraryRelPath` 优先 `downloads.artifact.path`，否则 `mavenPath(name)`）。
  //    这一步只负责**把文件放进 maven 树**：`net.minecraftforge:forge:<ver>` 与 `:universal` **都不进运行期
  //    清单**（前者本就在内嵌 `version.json` 的库表里；后者由 1.13–1.16.5 的 FML 用"ASM jar 上溯 6 级反推
  //    maven 根"自行定位，只要**文件在 maven 树里**即可）。`-client.jar` 是 `binarypatcher` 的产物、同样不进程清单。
  for (const lib of profileLibs) {
    const rel = forgeLibraryRelPath(lib);
    if (rel.length === 0) {
      continue;
    }
    const src = `${unzipDir}/maven/${rel}`;
    if (exists(src)) {
      copyFromUnzip(src, `${librariesDir(gameRoot)}/${rel}`);
    }
  }
  const mainRel = mavenPath(profile.path ?? '');
  const mainSrc = mainRel.length > 0 ? `${unzipDir}/maven/${mainRel}` : '';
  if (mainSrc.length > 0 && exists(mainSrc)) {
    copyFromUnzip(mainSrc, `${librariesDir(gameRoot)}/${mainRel}`);
  }

  // 4) 待下载项：vanilla（client jar 落 `<名>.jar` + 原版库 + 资源索引）+ 两份 Forge 库（共享库区）。
  const files: DownloadItem[] = [];
  const client = vanilla.downloads?.client;
  if (client !== undefined) {
    const url = client.url ?? '';
    if (url.length > 0) {
      files.push(newItem(`${instanceName}.jar`, [url], versionJarPath(gameRoot, instanceName),
        client.sha1 ?? '', client.size ?? 0));
    }
  }
  for (const lib of vanilla.libraries ?? []) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  const indexItem = assetIndexItem(gameRoot, vanilla.assets ?? '', vanilla.assetIndex);
  if (indexItem !== null) {
    files.push(indexItem);
  }
  // profile.libraries（processor 依赖与主制品所在的那份；maven 树）
  for (const lib of profileLibs) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  // 内嵌启动清单的库表（主制品/加载器库）
  const launchLibs = (launch.libraries ?? []) as LibraryJson[];
  for (const lib of launchLibs) {
    const item = libraryItem(gameRoot, lib);
    if (item !== null) {
      files.push(item);
    }
  }
  await runDownloads(files, loaderSource, onCount, onCurrent, onFileProgress);

  // 5) 资源对象（依赖已下好的索引；Forge 源）
  const assetId = (vanilla.assetIndex?.id ?? '').length > 0
    ? (vanilla.assetIndex?.id ?? '')
    : (vanilla.assets ?? '');
  if (indexItem !== null && assetId.length > 0) {
    onPhase(PHASE_ASSETS);
    let index: AssetIndexJson = {};
    try {
      index = JSON.parse(fileIo.readTextSync(`${assetsIndexesDir(gameRoot)}/${assetId}.json`)) as AssetIndexJson;
    } catch {
      index = {};
    }
    await runDownloads(assetObjectItems(gameRoot, index), loaderSource, onCount, onCurrent, onFileProgress);
  }

  // 6) processor 链：installer 只当数据容器，按 profile 顺序执行工具，产出 patched client jar。
  //    `{MINECRAFT_JAR}` 必须用**独立 temp 副本**（HMCL 同款硬约束）：工具会就地改写该 jar。
  onPhase(PHASE_PROCESS);
  onFileProgress(0, 0); // 处理器阶段无文件进度（清掉上一阶段残留的字节数显示）
  const mcJarForTools = `${workDir}/mc.jar`;
  try {
    fileIo.copyFileSync(versionJarPath(gameRoot, instanceName), mcJarForTools);
  } catch (error) {
    const err = error as BusinessError;
    throw new Error(`copy minecraft jar for processors failed: ${err.message ?? ''}`);
  }
  const expandCtx: ForgeExpandContext = {
    libraryDir: librariesDir(gameRoot),
    unzipDir: unzipDir,
    gameRoot: gameRoot,
    installerJar: jarPath,
    minecraftJar: mcJarForTools,
    minecraftVersion: gameVersion,
    mavenPathOf: (name: string): string => mavenPath(name)
  };
  const set = await buildForgeProcessorPlans(profile, expandCtx, workDir);
  await runForgeProcessors(ctx, set, workDir, gameRootUri, jreId, onCount, onCurrent);
  if (set.patchedPath.length === 0 || !exists(set.patchedPath)) {
    throw new Error('forge patched client jar missing after processors');
  }

  // 7) 写清单（HMCL 形态：顶层扁平 + patches[game, forge]）。
  //    **运行期 `libraries` 只取内嵌 `version.json`**（`launch.libraries`，经 `composeForgeManifest` 的
  //    `runtimeLibraries` 参数**显式**传入），**绝不**并入 `profile.libraries` —— 后者是**安装期工具**集
  //    （`installertools`/`jarsplitter`/`SpecialSource`/`binarypatcher`/`mcp_config`/`fmlcore` …），进了
  //    classpath 就是给游戏塞一堆工具 jar（对 ② 代的 `-p`/模块解析尤其引入噪声）。依据与 HMCL 对照见
  //    `composeForgeManifest` 的注释；`mainClass`/`arguments` 也取内嵌清单。
  onPhase(PHASE_WRITE);
  const forgeTemplate: VersionJson = launch;
  const composed = composeForgeManifest(vanilla, instanceName, gameVersion, loaderVersion, forgeTemplate,
    launchLibs);
  writeText(versionJsonPath(gameRoot, instanceName), JSON.stringify(composed));
}

/**
 * 桥在 headless 模式落盘的**工具 stdio** 绝对路径（`<filesDir>/meow-neo-jvm-tool.log`）。
 * 由 `:neoinstall` 进程写、本进程读（同一 App、同一 filesDir）⇒ 无跨目录授权问题。
 */
function forgeToolLogPath(ctx: common.UIAbilityContext): string {
  return `${ctx.filesDir}/${NEO_JVM_TOOL_LOG}`;
}

/** 清空上一轮的工具日志（桥以**追加**写；不清会把上一轮内容算进本轮归档）。删不掉也继续。 */
function forgeClearToolLog(path: string): void {
  try {
    if (exists(path)) {
      fileIo.unlinkSync(path);
    }
  } catch {
    // 忽略：归档时按现有内容整体拷贝，最坏情况是多一层旧行（不静默、可辨）。
  }
}

/** 标签 → 安全文件名（label 含 `:`，如 `installertools:MCP_DATA`；只留 `[A-Za-z0-9._-]`）。 */
function forgeLogSafeName(label: string): string {
  let out = '';
  for (let i = 0; i < label.length; i++) {
    const c = label.charAt(i);
    const keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      || c === '.' || c === '_' || c === '-';
    out += keep ? c : '_';
  }
  return out.length > 0 ? out : 'processor';
}

/**
 * 把工具 stdio 归档到 `<workDir>/logs/<序号>-<label>.log` 并返回**恒定**的路径。
 *
 * 为什么"没内容也写一个文件"：失败消息里的路径必须**总是**存在且可读，否则用户无法区分
 * 「工具什么都没打印」与「路径错了/日志没落盘」——这两种情况的下一步完全不同。
 */
function forgeArchiveToolLog(ctx: common.UIAbilityContext, workDir: string, label: string,
  index: number): string {
  const logsDir = `${workDir}/logs`;
  const dest = `${logsDir}/${index}-${forgeLogSafeName(label)}.log`;
  try {
    ensureDir(logsDir);
    const src = forgeToolLogPath(ctx);
    if (exists(src)) {
      fileIo.copyFileSync(src, dest);
    } else {
      writeText(dest, '(no tool stdio captured: bridge log absent => either the tool JVM printed nothing on'
        + ' stdout/stderr, or the installed bridge predates headless stdio logging (needs an HSP rebuild))\n');
    }
  } catch (error) {
    const err = error as BusinessError;
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'archive tool log for %{public}s failed: %{public}s',
      label, err.message ?? '');
  }
  return dest;
}

/** 工具日志的**有界摘录**（进失败消息：控制符压成 ` | `，便于 UI 单行/多行显示）。 */
function forgeToolLogExcerpt(path: string, maxLen: number): string {
  try {
    if (!exists(path)) {
      return '';
    }
    const raw = fileIo.readTextSync(path);
    let out = '';
    for (let i = 0; i < raw.length && out.length < maxLen; i++) {
      const code = raw.charCodeAt(i);
      out += (code < 0x20) ? ' | ' : raw.charAt(i);
    }
    return out.trim();
  } catch {
    return '';
  }
}

/**
 * 执行 Forge 新格式的 processor 链：**每个 processor 起一次无窗 UIAbility（独立进程 + headless JVM）**。
 *
 * 为什么逐次起进程：JLI_Launch 一进程只能起一次；`System.exit` 只杀该进程；工具间静态状态互不污染。
 * 退出码来自桥在 headless 模式写的 `<filesDir>/meow-neo-jvm-result.txt`（native 只有 hilog，拿不到返回值）；
 * ⚠️ 工具**多数 fail-open（参数错也退 0）** ⇒ 成败另有产物断言（G3 `outputs` + 调用方的 `PATCHED` 断言）。
 *
 * **工具 stdio 必须是可回看的**（本函数新增）：JLI/工具的失败原因**只写在它自己的 stdout/stderr 上**
 * （`Error: Could not find or load main class …` / `Input does not exist …` / `UnsupportedClassVersionError`
 * / VM 初始化失败），而桥只把它 pipe 到 hilog（滚动覆盖 + 现场抓取常按 tag 过滤）。故：每轮前清空桥的
 * `<filesDir>/meow-neo-jvm-tool.log` → 每次失败把该文件归档到 `<workDir>/logs/<序号>-<label>.log`，
 * 并把**路径 + 有界摘录**写进错误消息（UI 直接可读）。载体侧的"可读性预检"见 `NeoInstallAbility`
 * 的 `logToolJvmInputPreflight`（同进程视角，是唯一能在失败前回答"工具看得见类路径吗"的位置）。
 *
 * **G3 `outputs` 幂等**：整条 processor 的 `outputs`（对象 `{路径: sha1}`，已展开）全命中 ⇒ 跳过该条
 * （重入不重跑工具）；未全命中 ⇒ 先清掉不符的陈旧产物再执行；执行后逐条校验（sha1 主判据 + **`.jar` 的
 * ZIP 结构降级**，对齐 HMCL Forge 侧，见 `forgeVerifyOutputsOrThrow`），不符先删再抛。
 *
 * `jreId` 写进 job 交给 `:neoinstall`，让工具进程用与启动路径**同源**的那套 JRE 起 `startJvm`（不在本层解析）。
 */
async function runForgeProcessors(ctx: common.UIAbilityContext, set: ForgeProcessorSet,
  workDir: string, gameRootUri: string, jreId: string, onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void): Promise<void> {
  const resultPath = `${ctx.filesDir}/${NEO_JVM_RESULT}`;
  const total = set.plans.length;
  if (total === 0) {
    throw new Error('forge profile has no client-side processors');
  }
  onCount(0, total);
  for (let i = 0; i < total; i++) {
    const plan: ForgeProcessorPlan = set.plans[i];
    onCurrent(plan.label);
    // G3 幂等预检：`outputs` 非空且**全命中** ⇒ 整条跳过（重入/重试不再重跑工具）。
    if (await forgeOutputsAllMatch(plan)) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'forge processor %{public}s skipped (outputs already match)', plan.label);
      onCount(i + 1, total);
      continue;
    }
    // 未全命中：先删掉与声明不符/为空的陈旧产物，交给工具重建（工具多为"先删后写"）。
    await forgeRemoveStaleOutputs(plan);
    // job：完整 java 参数（不经 meow.launcher；headless 由 rendererLib='' 触发）
    const job = new ForgeProcessorJob();
    job.rootUri = gameRootUri;
    job.jreId = jreId;
    // **平台伪装：工具 JVM 与游戏 JVM 必须伪装成同一个平台**（前缀 = 同源常量
    // `TOOL_JVM_PLATFORM_SPOOF_ARGS`，定义处 `constants/LaunchDefaults.ets`，内含 `SPOOF_OS_NAME` /
    // `SPOOF_OS_VERSION`，游戏路径的用法见 `MinecraftLauncher.buildLaunchArgv` 的「固定 JVM 参数」段；
    // 本机真 `os.name` = HarmonyOS）。
    //
    // 为什么**必需**（2026-10-01 真机 stderr 定案，Forge 1.16.5 夹具）：JDK 8 的
    // `sun.nio.fs.DefaultFileSystemProvider.create()` 按 `os.name` **精确匹配**（`Linux` / `SunOS` /
    // `Darwin` / …），匹配不上**直接 `throw new AssertionError("Platform not recognized")`**。
    // 该异常发生在**类初始化期**——`java.io.FilePermission.<clinit>`
    // → `sun.net.www.protocol.file.FileURLConnection.getPermission` → `java.net.URLClassLoader.getPermissions`
    // → `sun.misc.Launcher$AppClassLoader.getPermissions` —— 于是 `sun.launcher.LauncherHelper.checkAndLoadMain`
    // 连**主类都加载不到**，JLI 只能退 1（stderr: `A JNI error has occurred` + `java.lang.AssertionError:
    // Platform not recognized`）。**在 legacy（Java 8）套上这就是必炸**：本机 `os.name` 是 HarmonyOS，
    // 而工具 JVM 此前不带任何平台伪装（游戏侧那一段则一直带）。
    // 现代套（26）对未知 `os.name` 宽容回退到 `UnixFileSystemProvider`，所以此前在 26 上没暴露——
    // **不要依赖**这一点：工具链将来落 Java 8 会同样中招。
    // 渲染 / LWJGL / natives 参数**一律不放**：工具是 headless（桥由 `NeoInstallAbility` 传
    // `rendererLib=''` 触发，不加载 GL、不做 glthread 失效安全），它不需要这些。
    // `-Dos.*` 排在 `-cp` 之前：与游戏路径同一形态，且平台属性必须在任何类初始化使用文件系统之前生效。
    // `cpu.name` / `meow.cpu.chip` 不在此列：它们只服务游戏侧 oshi 的 CPU 型号显示，工具从不查询。
    //
    // `-Djava.io.tmpdir` 必须指可写沙箱目录（鸿蒙无 /tmp；部分工具会用它落中间产物）。
    job.argv = ['java', ...TOOL_JVM_PLATFORM_SPOOF_ARGS,
      `-Djava.io.tmpdir=${workDir}`, '-cp', plan.classpath.join(':'), plan.mainClass];
    for (const a of plan.argv) {
      job.argv.push(a);
    }
    const jobPath = `${workDir}/job-${i}.json`;
    writeText(jobPath, JSON.stringify(job));
    // **工具 stdio 归零**：桥以追加写 `<filesDir>/meow-neo-jvm-tool.log`，不清会把上一轮的内容
    // 归到本轮（会让失败诊断指向错误的工具）。与 resultPath 的清空同一时机、同一目的。
    forgeClearToolLog(forgeToolLogPath(ctx));
    // 清上一次的结果文件（避免读到陈旧退出码）
    const jobStartMs = Date.now();
    try {
      fileIo.unlinkSync(resultPath);
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'clear prev result file failed (ignored): %{public}s', JSON.stringify(e));
    }
    // **新鲜度基线**：即便上面的 unlink 失败，也据"发起本 processor 时文件已有的字节数"把陈旧内容排除裁决之外。
    const baseline: ForgeProcessorBaseline = {
      offset: forgeResultFileSize(resultPath),
      startMs: jobStartMs,
    };
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      moduleName: 'entry',
      abilityName: NEO_INSTALL_ABILITY,
      parameters: {
        'job': jobPath,
      },
    };
    const options: StartOptions = {
      processMode: contextConstant.ProcessMode.NEW_PROCESS_ATTACH_TO_PARENT,
      startupVisibility: contextConstant.StartupVisibility.STARTUP_HIDE,
    };
    // 上一次 processor 的进程要完全退出后才能再起（否则 16000068）；并对该码做退避重试。
    await forgeWaitInstallGone();
    let started = false;
    let lastStartError = '';
    for (let attempt = 0; attempt < PROCESSOR_START_RETRY_MAX && !started; attempt++) {
      try {
        await ctx.startAbility(want, options);
        started = true;
      } catch (error) {
        const err = error as BusinessError;
        lastStartError = `${err.code} ${err.message ?? ''}`;
        const retryable = (err.code === 16000068 || err.code === 16000050);
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'forge startAbility attempt %{public}d failed: %{public}s',
          attempt + 1, lastStartError);
        if (!retryable) {
          break;
        }
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, PROCESSOR_START_BACKOFF_MS * (attempt + 1));
        });
      }
    }
    if (!started) {
      throw new Error(`start install ability failed (${plan.label}): ${lastStartError} job=${jobPath}`);
    }
    let code = 0;
    try {
      code = await forgeWaitProcessorExit(resultPath, PROCESSOR_TIMEOUT_MS, plan.label, baseline);
    } catch (error) {
      // 「软超时判崩/硬超时」同样是**工具侧**故障（崩溃/被杀/JLI 未返回）⇒ 工具 stdio 与 job 一并给出。
      const err = error as BusinessError;
      const log = forgeArchiveToolLog(ctx, workDir, plan.label, i + 1);
      const excerpt = forgeToolLogExcerpt(log, TOOL_LOG_EXCERPT_MAX);
      throw new Error(`${err.message ?? 'processor wait failed'} log=${log} job=${jobPath}`
        + (excerpt.length > 0 ? ` tool-output: ${excerpt}` : ' tool-output: (empty)'));
    }
    // 归档本轮的**工具 stdio**（无论成败都归）；失败消息里给出路径 + 有界摘录 —— 工具的失败原因
    // **只在它自己的 stdout/stderr 上**，这是 UI 能直接读到真相的唯一通路（见本函数头注释）。
    const toolLog = forgeArchiveToolLog(ctx, workDir, plan.label, i + 1);
    if (code !== 0) {
      const excerpt = forgeToolLogExcerpt(toolLog, TOOL_LOG_EXCERPT_MAX);
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'forge processor %{public}s exit=%{public}d tool-stdio=%{public}s job=%{public}s',
        plan.label, code, toolLog, jobPath);
      throw new Error(`processor failed (${plan.label}) exit=${code} log=${toolLog} job=${jobPath}`
        + (excerpt.length > 0 ? ` tool-output: ${excerpt}` : ' tool-output: (empty)'));
    }
    // 产物断言：`outputs` 逐条 sha1（`.jar` 不符时可降级为 ZIP 结构校验；非 `.jar` ⇒ 先删再抛）。
    // 工具退 0 但产物不对时，工具自己的 stdout 同样是第一手证据 ⇒ 一并带上（不吞原错误）。
    try {
      await forgeVerifyOutputsOrThrow(plan, workDir);
    } catch (error) {
      const err = error as BusinessError;
      const excerpt = forgeToolLogExcerpt(toolLog, TOOL_LOG_EXCERPT_MAX);
      throw new Error(`${err.message ?? 'outputs rejected'} log=${toolLog} job=${jobPath}`
        + (excerpt.length > 0 ? ` tool-output: ${excerpt}` : ' tool-output: (empty)'));
    }
    onCount(i + 1, total);
  }
}

/**
 * `:neoinstall` 进程是否存活（`appManager` 只看本应用进程，无需权限）。
 * 探测失败按「存活」处理——宁可慢，也不要因为探测不到就误判失败。
 */
async function forgeInstallProcessAlive(): Promise<boolean> {
  try {
    const list = await appManager.getRunningProcessInformation();
    for (const info of list) {
      if (info.processName.includes(NEO_INSTALL_PROCESS_SUFFIX)) {
        return true;
      }
    }
    return false;
  } catch {
    return true;
  }
}

/**
 * 等 `:neoinstall` 进程完全消失（上一次 processor 的 JVM 刚 `_exit`，能力实例仍在回收窗口中；
 * 立刻再 `startAbility` 会得到 16000068）。只在**已看到过该进程**时才等待；探测失败按"已退出"处理。
 */
async function forgeWaitInstallGone(): Promise<void> {
  const deadline = Date.now() + PROCESSOR_GONE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (!(await forgeInstallProcessAlive())) {
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, PROCESSOR_POLL_MS);
    });
  }
}

/**
 * 结果文件当前字节数（缺失/读取失败 ⇒ 0）。
 * 用**字节数**（而非 mtime）作新鲜度门限：`statSync().mtime` 是秒级整数，`resultFileSize` 与桥的
 * **追加**写（`fopen(..., "a")`）配合可做精确、单调的偏移判定。
 */
function forgeResultFileSize(path: string): number {
  try {
    if (!fileIo.accessSync(path)) {
      return 0;
    }
    return fileIo.statSync(path).size;
  } catch {
    return 0;
  }
}

/**
 * 轮询结果文件，等出 `JLI_RETURNED code=N`；超时抛错。
 *
 * 裁决顺序（**返回码权威**）：一旦出现 `JLI_RETURNED code=N` 就按 N 返回（0 成功；非 0 交调用方判失败，
 * **绝不吞**）；只有 `JLI_BEGIN` 而无返回码时，才允许用「进程探测」兜底判异常终结；两样都没写 = 尚未开始，
 * 继续轮询到 deadline。
 *
 * **陈旧退出码防护（`baseline`）**：只认**基线偏移之后**出现的返回码；文件长度若小于基线（被截断/重写，
 * 正常不该发生）则视为整份新鲜，避免误挂到硬超时。握手文本固定为全 ASCII ⇒ 字节偏移与字符下标一致。
 *
 * **软超时**（`PROCESSOR_SOFT_TIMEOUT_MS`）：自**首次** `JLI_BEGIN` 起算；其间只要探针观察到存活即重置起点
 * （探针可用的环境里"合法慢"不会被误杀）。到点仍无返回码 ⇒ 判工具崩溃/被杀，提前抛**可诊断**错误。
 * 判死前**重读一次**（返回码可能刚好落盘），且**仅在确实见过该进程存活时**才信"探测不到 = 已退出"
 * （进程列表是瞬时快照，单次漏列不该误杀正在干活的 processor）。
 *
 * 本函数为 Forge 链**独立实现**（语义与 NeoForge 链已验证的 `waitProcessorExit` 一致，但代码独立）。
 */
async function forgeWaitProcessorExit(resultPath: string, timeoutMs: number, label: string,
  baseline: ForgeProcessorBaseline): Promise<number> {
  const startMs = Date.now();
  const deadline = startMs + timeoutMs;
  const marker = 'JLI_RETURNED code=';
  const readHandshake = (): string => {
    try {
      if (fileIo.accessSync(resultPath)) {
        return fileIo.readTextSync(resultPath);
      }
    } catch {
      // 读失败按空处理（空串 ≠ 成功，绝不会误判）。
    }
    return '';
  };
  const returnedCode = (text: string): number | undefined => {
    const at = text.lastIndexOf(marker);
    if (at < 0) {
      return undefined;
    }
    const n = parseInt(text.substring(at + marker.length).split('\n')[0].trim(), 10);
    return Number.isNaN(n) ? -1 : n;
  };
  const freshReturnedCode = (text: string): number | undefined => {
    const base = text.length < baseline.offset ? 0 : baseline.offset;
    return returnedCode(base > 0 ? text.substring(base) : text);
  };
  const handshakeDigest = (text: string): string => {
    const t = text.trim();
    if (t.length === 0) {
      return 'absent';
    }
    const body = t.split('\n').join(' | ');
    return returnedCode(text) === undefined ? `partial(${body})` : `complete(${body})`;
  };
  let missedPolls = 0;
  let processEverAlive = false;
  // 软超时起点：**首次**观察到 `JLI_BEGIN`（工具 JVM 确已起）的时刻；0 = 尚未观察到。
  let beginMs = 0;
  while (Date.now() < deadline) {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, PROCESSOR_POLL_MS);
    });
    const text = readHandshake();
    // 1) 返回码权威（只认基线之后的**新鲜**码）：0 与非 0 都原样返回（绝不吞非 0）。
    const code = freshReturnedCode(text);
    if (code !== undefined) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'forge processor %{public}s handshake returned code=%{public}d elapsedMs=%{public}d',
        label, code, Date.now() - startMs);
      return code;
    }
    // 2) 无返回码：只有看到 `JLI_BEGIN`（JVM 确已起）才允许进程探测兜底；否则继续轮询。
    if (!text.includes('JLI_BEGIN')) {
      continue;
    }
    if (beginMs === 0) {
      beginMs = Date.now();
    }
    if (Date.now() - beginMs >= PROCESSOR_SOFT_TIMEOUT_MS) {
      const sinceBegin = Date.now() - beginMs;
      const sinceJob = Date.now() - baseline.startMs;
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'forge processor %{public}s soft timeout: no exit code %{public}d ms after JLI_BEGIN and never'
        + ' observed alive (sinceJobStart=%{public}d ms) -> treating as crashed', label, sinceBegin, sinceJob);
      throw new Error(`processor appears crashed (${label}): no exit code ${sinceBegin} ms after tool`
        + ` JVM start (${sinceJob} ms since job start) and no liveness signal`);
    }
    if (await forgeInstallProcessAlive()) {
      processEverAlive = true;
      missedPolls = 0;
      beginMs = Date.now();   // 探针看到存活 ⇒ 重置软超时起点（合法慢不误杀）
      continue;
    }
    // 3) 探测不到：**仅在确实见过它存活时**才当「已退出」用（否则「没列出来」可能只是快照漏列）。
    if (!processEverAlive) {
      if (missedPolls === 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'forge processor %{public}s never observed alive; ignoring probe-gone and waiting for handshake (elapsedMs=%{public}d)',
          label, Date.now() - startMs);
      }
      missedPolls++;
      continue;
    }
    missedPolls++;
    if (missedPolls < 2) {
      continue;
    }
    // 4) 决定前**重读一次**：此刻若返回码已补上就以它为准 —— 探测绝不覆盖已写出的退出码。
    const recheck = readHandshake();
    const recheckCode = freshReturnedCode(recheck);
    if (recheckCode !== undefined) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'forge processor %{public}s handshake returned code=%{public}d (on re-read) elapsedMs=%{public}d',
        label, recheckCode, Date.now() - startMs);
      return recheckCode;
    }
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'forge processor %{public}s ended without exit code: handshake=%{public}s probeAlive=false elapsedMs=%{public}d',
      label, handshakeDigest(recheck), Date.now() - startMs);
    throw new Error(`processor terminated without exit code (${label})`);
  }
  // 到 deadline：再重读一次（返回码可能刚好落盘），拿到就用。
  const finalText = readHandshake();
  const finalCode = freshReturnedCode(finalText);
  if (finalCode !== undefined) {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'forge processor %{public}s handshake returned code=%{public}d (at timeout) elapsedMs=%{public}d',
      label, finalCode, Date.now() - startMs);
    return finalCode;
  }
  hilog.error(LOG_DOMAIN, LOG_TAG,
    'forge processor %{public}s timeout after %{public}d ms: handshake=%{public}s probeAlive=%{public}s elapsedMs=%{public}d',
    label, timeoutMs, handshakeDigest(finalText),
    (await forgeInstallProcessAlive()) ? 'true' : 'false', Date.now() - startMs);
  throw new Error(`processor timeout (${label}) after ${timeoutMs} ms`);
}
