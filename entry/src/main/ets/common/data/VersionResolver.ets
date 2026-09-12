import { fileIo } from '@kit.CoreFileKit';
import { versionJsonPath } from '../constants/Paths';

/**
 * 版本 json 解析器（唯一 schema 归属）：把"叶子 json"归一成"有效清单"。
 *
 * 支持三种形态（互斥判定，见 detectVersionForm）：
 * - ① 继承式（`inheritsFrom`，官方安装器 / 外部导入）：递归解析父实例并合并（子覆盖父）。
 * - ② 补丁式（`patches[]`，HMCL 自装）：按 priority 升序折叠各补丁。
 * - ③ 原版：叶子自洽。
 *
 * 关键产出：`ResolvedVersion.mcVersion` = **真 MC 版本号**（① 继承链根 / ② `game` patch.version /
 * ③ json.id）——与"实例身份 = 目录名"严格区分。Fabric 实例的目录名/json id 形如
 * `fabric-loader-0.15.11-1.20.1`，**不是** MC 版本，渲染后端/LWJGL 世代必须用 mcVersion 判定。
 *
 * 合并规则对齐 HMCL（GameInstanceManifest.merge）：
 * - 标量（mainClass/assets/assetIndex/javaVersion/type/releaseTime/jar/minecraftArguments）：子/补丁非空覆盖；
 * - `arguments.game`/`arguments.jvm`：基座在前、覆盖层追加在后；
 * - `libraries`：继承式 = 子在前父在后；补丁式 = 基座在前、补丁追加在后。
 *
 * 健壮性：来源 json 可能被人工编辑/外部工具写坏 → 所有字段访问做类型守卫，非法形状不抛异常。
 */

// ---- 形态 / 加载器 / 补丁 id（集中常量，禁散落 magic）----
export const VERSION_FORM_VANILLA: string = 'vanilla';
export const VERSION_FORM_INHERITS: string = 'inherits';
export const VERSION_FORM_PATCHES: string = 'patches';
export const LOADER_FABRIC: string = 'fabric';
export const LOADER_LEGACY_FABRIC: string = 'legacy_fabric';

/** 原版游戏补丁层的 id（HMCL GameComponentType.GAME）。 */
const PATCH_ID_GAME: string = 'game';
/** HMCL 补丁 id：普通/legacy Fabric。 */
const PATCH_ID_FABRIC: string = 'fabric';
const PATCH_ID_LEGACY_FABRIC: string = 'legacyfabric';

// ---- 版本 json 数据模型（仅建模本工程消费到的字段；JSON 键名由外部格式决定）----

/** 平台规则 os 字段。 */
export interface VersionRuleOs {
  name?: string;
  arch?: string;
}

/** 单条平台规则。 */
export interface VersionRule {
  action?: string;
  os?: VersionRuleOs;
}

/** 带规则的参数项（对象形式；字符串形式直接用 string）。 */
export interface VersionRuleArg {
  rules?: VersionRule[];
  value?: string | string[];
}

/** arguments 分组。 */
export interface VersionArguments {
  game?: Array<string | VersionRuleArg>;
  jvm?: Array<string | VersionRuleArg>;
}

/** assetIndex 信息。 */
export interface VersionAssetIndex {
  id?: string;
}

/** 依赖库 artifact 下载信息。 */
export interface VersionArtifact {
  path?: string;
}

/** 依赖库 downloads 信息。 */
export interface VersionLibraryDownloads {
  artifact?: VersionArtifact;
}

/** 依赖库。 */
export interface VersionLibrary {
  name?: string;
  url?: string;
  rules?: VersionRule[];
  downloads?: VersionLibraryDownloads;
}

/** Java 版本要求。 */
export interface VersionJavaVersion {
  majorVersion?: number;
}

/** 补丁层（HMCL 补丁式：`patches[]` 的一项）。 */
export interface VersionPatch {
  id?: string;
  version?: string;
  priority?: number;
  mainClass?: string;
  inheritsFrom?: string;
  jar?: string;
  minecraftArguments?: string;
  arguments?: VersionArguments;
  libraries?: VersionLibrary[];
  assets?: string;
  assetIndex?: VersionAssetIndex;
  javaVersion?: VersionJavaVersion;
  type?: string;
  releaseTime?: string;
}

/** 版本 json（完整/有效清单共用）。 */
export interface VersionJson {
  id?: string;
  inheritsFrom?: string;
  mainClass?: string;
  jar?: string;
  assets?: string;
  assetIndex?: VersionAssetIndex;
  type?: string;
  releaseTime?: string;
  javaVersion?: VersionJavaVersion;
  minecraftArguments?: string;
  arguments?: VersionArguments;
  libraries?: VersionLibrary[];
  patches?: VersionPatch[];
  root?: boolean;
}

/** 解析结果：有效清单 + 派生身份。 */
export class ResolvedVersion {
  /** 形态：VERSION_FORM_*。 */
  form: string;
  /** 真 MC 版本号（渲染后端/LWJGL 世代判定用），可能为空。 */
  mcVersion: string;
  /** 加载器：'' / LOADER_FABRIC / LOADER_LEGACY_FABRIC。 */
  loader: string;
  /** 客户端 jar 所在的版本 id（①继承链根 / ②`jar`字段或id / ③id）。 */
  clientJarId: string;
  /** 归一后的有效清单（已展开继承/补丁）。 */
  json: VersionJson;

  constructor(form: string, mcVersion: string, loader: string, clientJarId: string, json: VersionJson) {
    this.form = form;
    this.mcVersion = mcVersion;
    this.loader = loader;
    this.clientJarId = clientJarId;
    this.json = json;
  }
}

/** 内部：解析中间态（有效清单 + 版本号 + 加载器 + 客户端 jar 版本）。 */
class Effective {
  json: VersionJson;
  mcVersion: string;
  loader: string;
  form: string;
  /** 提供客户端类的版本 id（① 继承链根 / ② jar 字段或 id / ③ id）；其 <id>.jar 进 classpath。 */
  clientJarId: string;

  constructor(json: VersionJson, mcVersion: string, loader: string, form: string, clientJarId: string) {
    this.json = json;
    this.mcVersion = mcVersion;
    this.loader = loader;
    this.form = form;
    this.clientJarId = clientJarId;
  }
}

const VERSIONS_MARKER: string = '/versions/';

/** 由版本 json 路径反推游戏根：`<gameRoot>/versions/<id>/<id>.json` → `<gameRoot>`。 */
export function gameRootFromJsonPath(jsonPath: string): string {
  const idx = jsonPath.lastIndexOf(VERSIONS_MARKER);
  return idx < 0 ? '' : jsonPath.substring(0, idx);
}

/** 读取并解析版本 json；失败返回 null。 */
export function readVersionJson(jsonPath: string): VersionJson | null {
  try {
    return JSON.parse(fileIo.readTextSync(jsonPath)) as VersionJson;
  } catch {
    return null;
  }
}

/** 判定形态（互斥）：有非空 inheritsFrom → ①；否则有含 id=="game" 的 patches → ②；否则 ③。 */
export function detectVersionForm(json: VersionJson): string {
  const inh = json.inheritsFrom;
  if (typeof inh === 'string' && inh.length > 0) {
    return VERSION_FORM_INHERITS;
  }
  if (hasGamePatch(json.patches)) {
    return VERSION_FORM_PATCHES;
  }
  return VERSION_FORM_VANILLA;
}

/** patches 是否含 `id == "game"`（HMCL 可维护根清单的判定键之一）。 */
export function hasGamePatch(patches?: VersionPatch[]): boolean {
  if (!Array.isArray(patches)) {
    return false;
  }
  for (const p of patches) {
    if (isPatch(p) && p.id === PATCH_ID_GAME) {
      return true;
    }
  }
  return false;
}

/** 运行时守卫：json 里 patches 元素可能是 null/非对象。 */
function isPatch(p: VersionPatch | undefined): boolean {
  return p !== undefined && p !== null;
}

/**
 * 解析版本（由 jsonPath 反推 gameRoot）。供只持有 jsonPath 的调用方使用。
 */
export function resolveVersionByPath(jsonPath: string): ResolvedVersion | null {
  return resolveVersion(gameRootFromJsonPath(jsonPath), jsonPath);
}

/**
 * 解析版本为"有效清单"。任何解析异常都吞掉并返回 null（来源 json 可能被写坏）。
 * @param gameRoot 游戏根（父实例查找用）
 * @param jsonPath 叶子版本 json 路径
 */
export function resolveVersion(gameRoot: string, jsonPath: string): ResolvedVersion | null {
  try {
    const eff = resolveEffective(gameRoot, jsonPath, new Set<string>());
    if (eff === null) {
      return null;
    }
    return new ResolvedVersion(eff.form, eff.mcVersion, eff.loader, eff.clientJarId, eff.json);
  } catch {
    return null;
  }
}

/** 递归解析（含环保护）。 */
function resolveEffective(gameRoot: string, jsonPath: string, visited: Set<string>): Effective | null {
  const raw = readVersionJson(jsonPath);
  if (raw === null) {
    return null;
  }
  const form = detectVersionForm(raw);

  if (form === VERSION_FORM_INHERITS) {
    const parentId = typeof raw.inheritsFrom === 'string' ? raw.inheritsFrom : '';
    if (parentId.length > 0 && !visited.has(jsonPath)) {
      visited.add(jsonPath);
      const parentPath = versionJsonPath(gameRoot, parentId);
      const parentEff = resolveEffective(gameRoot, parentPath, visited);
      if (parentEff !== null) {
        let merged = mergeInherit(parentEff.json, raw);
        // 混合形态（少见）：继承之上再叠加自身 patches（与 HMCL resolve 一致）。
        for (const p of sortedPatches(raw.patches)) {
          merged = mergePatch(merged, p);
        }
        const mcVersion = parentEff.mcVersion.length > 0 ? parentEff.mcVersion : parentId;
        return new Effective(merged, mcVersion, detectLoader(merged), form, parentEff.clientJarId);
      }
    }
    // 父缺失/成环：退化为原版叶子（尽量可启动）。
    const solo = mergeInherit(null, raw);
    return new Effective(solo, raw.id ?? '', detectLoader(solo), form, raw.id ?? '');
  }

  if (form === VERSION_FORM_PATCHES) {
    let eff: VersionJson = emptyJson();
    for (const p of sortedPatches(raw.patches)) {
      eff = mergePatch(eff, p);
    }
    const gamePatch = findGamePatch(raw.patches);
    const mcVersion = gamePatch !== null && (gamePatch.version ?? '').length > 0
      ? (gamePatch.version ?? '') : (raw.id ?? '');
    // 加载器：优先补丁/库；补丁式叶子顶层可能无 loader 字段，故 merged 与 raw 都查。
    let loader = detectLoader(eff);
    if (loader.length === 0) {
      loader = detectLoader(raw);
    }
    // HMCL 写盘时顶层 jar = 实例 id 且为实例复制了 <id>.jar；顶层 jar 优先。
    const clientJarId = (raw.jar ?? '').length > 0 ? (raw.jar ?? '') : (raw.id ?? '');
    eff.id = raw.id; // 有效清单身份 = 实例 id（HMCL builder.setId）
    return new Effective(eff, mcVersion, loader, form, clientJarId);
  }

  // 原版：叶子即有效清单。
  return new Effective(raw, raw.id ?? '', detectLoader(raw), form, raw.id ?? '');
}

/**
 * 补丁按 priority 升序。缺省 priority 取 `Number.MIN_SAFE_INTEGER`（与 HMCL
 * `GameInstancePatch.getPriority()` 对 null 返回 `Integer.MIN_VALUE` 一致 → 缺省者排最前）。
 * 不改动入参：构造新数组。
 */
function sortedPatches(patches?: VersionPatch[]): VersionPatch[] {
  const arr: VersionPatch[] = [];
  if (Array.isArray(patches)) {
    for (const p of patches) {
      if (isPatch(p)) {
        arr.push(p);
      }
    }
  }
  arr.sort((a: VersionPatch, b: VersionPatch) => priorityOf(a) - priorityOf(b));
  return arr;
}

function priorityOf(p: VersionPatch): number {
  return p.priority ?? Number.MIN_SAFE_INTEGER;
}

function findGamePatch(patches?: VersionPatch[]): VersionPatch | null {
  if (!Array.isArray(patches)) {
    return null;
  }
  for (const p of patches) {
    if (isPatch(p) && p.id === PATCH_ID_GAME) {
      return p;
    }
  }
  return null;
}

/**
 * 继承式合并：child 覆盖 parent，基座在前、children 追加（libraries 例外：子在前）。
 */
function mergeInherit(parent: VersionJson | null, child: VersionJson): VersionJson {
  const p: VersionJson = parent === null ? emptyJson() : parent;
  return {
    id: pickStr(child.id, p.id),
    inheritsFrom: undefined,
    mainClass: pickStr(child.mainClass, p.mainClass),
    jar: pickStr(child.jar, p.jar),
    assets: pickStr(child.assets, p.assets),
    assetIndex: pickObj(child.assetIndex, p.assetIndex),
    type: pickStr(child.type, p.type),
    releaseTime: pickStr(child.releaseTime, p.releaseTime),
    javaVersion: pickJava(child.javaVersion, p.javaVersion),
    minecraftArguments: pickStr(child.minecraftArguments, p.minecraftArguments),
    arguments: concatArguments(p.arguments, child.arguments),
    libraries: concatLibraries(child.libraries, p.libraries),
    patches: child.patches,
    root: child.root
  };
}

/**
 * 补丁式折叠：patch 覆盖 eff，基座在前、补丁追加（arguments/libraries 同序）。
 */
function mergePatch(eff: VersionJson, patch: VersionPatch): VersionJson {
  return {
    id: pickStr(patch.id, eff.id),
    inheritsFrom: eff.inheritsFrom,
    mainClass: pickStr(patch.mainClass, eff.mainClass),
    jar: pickStr(patch.jar, eff.jar),
    assets: pickStr(patch.assets, eff.assets),
    assetIndex: pickObj(patch.assetIndex, eff.assetIndex),
    type: pickStr(patch.type, eff.type),
    releaseTime: pickStr(patch.releaseTime, eff.releaseTime),
    javaVersion: pickJava(patch.javaVersion, eff.javaVersion),
    minecraftArguments: pickStr(patch.minecraftArguments, eff.minecraftArguments),
    arguments: concatArguments(eff.arguments, patch.arguments),
    libraries: concatLibraries(eff.libraries, patch.libraries),
    patches: eff.patches,
    root: eff.root
  };
}

function pickStr(a?: string, b?: string): string | undefined {
  if (typeof a === 'string' && a.length > 0) {
    return a;
  }
  return b;
}

function pickObj(a?: VersionAssetIndex, b?: VersionAssetIndex): VersionAssetIndex | undefined {
  return isObj(a) ? a : b;
}

function pickJava(a?: VersionJavaVersion, b?: VersionJavaVersion): VersionJavaVersion | undefined {
  return isObj(a) ? a : b;
}

/** 运行时守卫：JSON null 不是有效对象。 */
function isObj<T>(a?: T): boolean {
  return a !== undefined && a !== null && typeof a === 'object';
}

function concatArguments(a?: VersionArguments, b?: VersionArguments): VersionArguments | undefined {
  if (a === undefined && b === undefined) {
    return undefined;
  }
  const out: VersionArguments = {
    game: concatArgList(a === undefined ? undefined : a.game, b === undefined ? undefined : b.game),
    jvm: concatArgList(a === undefined ? undefined : a.jvm, b === undefined ? undefined : b.jvm)
  };
  return out;
}

function concatArgList(a?: Array<string | VersionRuleArg>,
  b?: Array<string | VersionRuleArg>): Array<string | VersionRuleArg> | undefined {
  if (a === undefined && b === undefined) {
    return undefined;
  }
  const out: Array<string | VersionRuleArg> = [];
  for (const x of a ?? []) {
    out.push(x);
  }
  for (const x of b ?? []) {
    out.push(x);
  }
  return out;
}

function concatLibraries(a?: VersionLibrary[], b?: VersionLibrary[]): VersionLibrary[] | undefined {
  if (a === undefined && b === undefined) {
    return undefined;
  }
  const out: VersionLibrary[] = [];
  for (const x of a ?? []) {
    out.push(x);
  }
  for (const x of b ?? []) {
    out.push(x);
  }
  return out;
}

function emptyJson(): VersionJson {
  const e: VersionJson = {
    id: undefined,
    inheritsFrom: undefined,
    mainClass: undefined,
    jar: undefined,
    assets: undefined,
    assetIndex: undefined,
    type: undefined,
    releaseTime: undefined,
    javaVersion: undefined,
    minecraftArguments: undefined,
    arguments: undefined,
    libraries: undefined,
    patches: undefined,
    root: undefined
  };
  return e;
}

/**
 * 加载器识别：补丁 id（`fabric`/`legacyfabric`）或库 `net.fabricmc:fabric-loader`
 * （精确或带 `:` 版本后缀）；出现 `net.legacyfabric:` 组库 → Legacy Fabric。
 */
export function detectLoader(json: VersionJson): string {
  let fabric = false;
  let legacy = false;
  for (const lib of json.libraries ?? []) {
    const name = lib.name ?? '';
    if (name === 'net.fabricmc:fabric-loader' || name.startsWith('net.fabricmc:fabric-loader:')) {
      fabric = true;
    }
    if (name.startsWith('net.legacyfabric:')) {
      legacy = true;
    }
  }
  for (const p of json.patches ?? []) {
    if (!isPatch(p)) {
      continue;
    }
    if (p.id === PATCH_ID_FABRIC) {
      fabric = true;
    }
    if (p.id === PATCH_ID_LEGACY_FABRIC) {
      legacy = true;
    }
  }
  if (!fabric && !legacy) {
    return '';
  }
  return legacy ? LOADER_LEGACY_FABRIC : LOADER_FABRIC;
}
