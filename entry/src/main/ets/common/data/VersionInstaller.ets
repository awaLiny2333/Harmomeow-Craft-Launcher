import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DEFAULT_LIBRARY_URL, DOWNLOAD_CONCURRENCY, ENV_OS_ARCH, ENV_OS_BITS, ENV_OS_NAME,
  LEGACY_INDEX_URL_PREFIX, MOJANG_RESOURCES, fileCandidates,
  manifestCandidates } from '../constants/DownloadContract';
import { ASSET_HASH_PREFIX_LENGTH, assetObjectPath, assetsIndexesDir, librariesDir,
  versionJarPath, versionJsonPath } from '../constants/Paths';
import { downloadFile, fetchText } from './Downloader';

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
function mavenPath(name: string): string {
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
  let writeOk = true;
  try {
    fileIo.writeSync(file.fd, text);
  } catch (error) {
    writeOk = false;
  }
  try {
    fileIo.closeSync(file);
  } catch (error) {
    // 忽略关闭异常
  }
  if (!writeOk) {
    throw new Error('write failed');
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

/** 判断某远程版本是否已安装（本地 versions 目录下已有 json）。 */
export function isInstalled(gameRoot: string, versionId: string): boolean {
  return exists(versionJsonPath(gameRoot, versionId));
}

/**
 * 安装一个原版版本到 gameRoot。
 *
 * @param onPhase   阶段变化回调（PHASE_FILES / PHASE_ASSETS / PHASE_WRITE）
 * @param onCount   进度回调（已完成 / 总数，按阶段重置）
 * @param onCurrent 当前处理项标签回调
 */
export async function installVersion(gameRoot: string, remote: RemoteVersion, source: string,
  onPhase: (phase: number) => void,
  onCount: (done: number, total: number) => void,
  onCurrent: (label: string) => void,
  onFileProgress: (received: number, total: number) => void): Promise<void> {
  onPhase(PHASE_FILES);
  const versionJsonText = await fetchText(fileCandidates(remote.url, source));
  const versionJson = JSON.parse(versionJsonText) as VersionJson;
  const id = (versionJson.id ?? '').length > 0 ? (versionJson.id ?? '') : remote.id;
  if (id.length === 0) {
    throw new Error('version id missing');
  }

  // 第一批：client jar + libraries + 资源索引
  const files: DownloadItem[] = [];
  const client = versionJson.downloads?.client;
  if (client !== undefined) {
    const url = client.url ?? '';
    if (url.length > 0) {
      files.push(newItem(`${id}.jar`, [url], versionJarPath(gameRoot, id),
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
  writeText(versionJsonPath(gameRoot, id), versionJsonText);
}
