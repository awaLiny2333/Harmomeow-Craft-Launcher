import { fileIo, hash } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HASH_ALGORITHM } from '../constants/DownloadContract';
import { removeTreeBestEffort } from './VersionTools';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'ForgeNewInstaller';

/** `.jar` 输出的扩展名（**只有 `.jar`** 才允许 sha1 不符时降级为 ZIP 结构校验；见 `forgeZipStructurallyValid`）。 */
const JAR_EXTENSION = '.jar';

/**
 * Forge **新格式安装器**（`install_profile.json` 带 `spec` 且 client 侧 processor > 0；MC 1.13–1.20.1）
 * 的数据层：profile/processor 类型、变量表与占位符展开、从工具 jar 读 `Main-Class`、以及 `outputs` 幂等判定。
 *
 * 与 NeoForge 链**代码独立**（这是刻意的：两份装载器格式逐字同构，但共享同一份实现会把两侧的
 * 语义/生命周期绑死，任一侧的需求变化都会波及另一侧；见 notes `Forge-1.13至1.20.1-安装实施方案.md` 方案 B）。
 * 故这里的类型/展开/计划构造**不复用** `NeoForgeInstaller.ets` 的任何符号，只参照其已被真件验证的口径。
 *
 * 设计要点（对齐真件 + HMCL 口径）：
 * - **参数原样来自 profile**，我们只做占位符替换 ⇒ 不必理解 `--task MCP_DATA` 之类的语义，也不随
 *   `InstallerTools` 的 CLI 版本漂移；
 * - `data` 取值三形态：`'literal'` / 安装包内路径（`/data/client.lzma`）/ `[maven 坐标]`
 *   （坐标既可能是**输入件**（如 `mcp_config@zip`，已由 profile.libraries 下好），
 *   也可能是某个处理器的**输出路径**（如 `[net.minecraftforge:forge:…:client]`）——两者都按 maven 树路径解析）；
 * - **主类必须从工具 jar 的 MANIFEST 读**（`-cp` 方式运行需要显式主类，且各代工具类名不同，照抄会随版本漂移失效）；
 * - `outputs` 校验：sha1 为主判据，**`.jar` 不符时可降级为 ZIP 结构校验**（对齐 HMCL 的 Forge 侧行为；
 *   因为 processor 动态生成的 jar 在 deflate 实现与官方不同的沙箱里 sha1 必然不符），详见
 *   `forgeVerifyOutputsOrThrow` / `forgeOutputsAllMatch`。
 */

/** install_profile.json 的一条 `data`（只取 client 侧）。 */
export interface ForgeNewDataEntryJson {
  client?: string;
  server?: string;
}

/**
 * install_profile.json 的一条 processor（字段取自真样本）。
 * `outputs` 形态是**对象** `{输出路径占位键: sha1 占位值}`（**不是数组**）——用于 G3 幂等预检。
 */
export interface ForgeNewProcessorJson {
  sides?: string[];
  jar: string;
  classpath?: string[];
  args?: string[];
  outputs?: Record<string, string>;
}

/**
 * 新格式 Forge `install_profile.json`（只列用到的字段）。
 * **必须含 `data`**（processor 参数里的 `{MAPPINGS}` 等键就在这里，缺了展开会抛 `unresolved placeholder`）。
 */
export interface ForgeNewInstallProfileJson {
  spec?: number;
  profile?: string;
  version?: string;
  minecraft?: string;
  json?: string;
  path?: string;
  data?: Record<string, ForgeNewDataEntryJson>;
  processors?: ForgeNewProcessorJson[];
  /** 库表：与 vanilla 库同形（由 VersionInstaller 以自身 LibraryJson 处理）。 */
  libraries?: object[];
}

/** 一条 `outputs` 目标（键/值均已展开为字面路径与 sha1）。 */
export class ForgeOutputTarget {
  /** 输出文件的绝对路径。 */
  path: string = '';
  /** 期望 sha1（小写；空串 = 该件无 sha1 语义，校验时跳过）。 */
  sha1: string = '';
}

/** 一条可执行的 processor（所有路径均已展开为绝对路径）。 */
export class ForgeProcessorPlan {
  /** 展示标签（进度/日志用；含 installertools 的 `--task` 子任务名，便于区分同名工具）。 */
  label: string = '';
  /** 工具主类（读自工具 jar 的 MANIFEST）。 */
  mainClass: string = '';
  /** 绝对路径 classpath（工具 jar + 其依赖）。 */
  classpath: string[] = [];
  /** 展开后的参数（不含 java 与主类）。 */
  argv: string[] = [];
  /** 该 processor 声明的产物（G3 幂等：全命中即跳过整条）。 */
  outputs: ForgeOutputTarget[] = [];

  constructor(label: string) {
    this.label = label;
  }
}

/** processor 计划集合：可执行计划 + 关键产物（供编排侧断言）。 */
export class ForgeProcessorSet {
  plans: ForgeProcessorPlan[] = [];
  /** `PATCHED`（打补丁后的 client jar）绝对路径——安装成功的唯一硬判据。 */
  patchedPath: string = '';
}

/**
 * 交给 `:neoinstall` ability 执行的作业（以 JSON 文件传递，避免 want 传长数组）。
 * 字段形状与 `NeoForgeProcessorJob` 一致（同一份 job 文件协议 / 同一个无窗载体），但**本侧独立声明**。
 */
export class ForgeProcessorJob {
  /**
   * 完整 java 参数（组装处 `VersionInstaller.runForgeProcessors`）：
   * `[java, -Dos.name=Linux, -Dos.version=6.6, -Djava.io.tmpdir=…, -cp, <cp>, <mainClass>, ...args]`。
   * 前两个是**平台伪装**（与游戏启动路径同源常量，见 `LaunchDefaults.ets` 的 `SPOOF_OS_NAME` /
   * `SPOOF_OS_VERSION`）——legacy（Java 8）工具 JVM 少了它会在主类加载前 `AssertionError` 退 1。
   */
  argv: string[] = [];
  /** 游戏目录的用户文件 URI（ability 进程内再激活一次持久化授权；best-effort）。 */
  rootUri: string = '';
  /** 工具 JVM 该用哪套 JRE 的 id（由安装编排按 (MC 版本 × Forge) 经 `JavaPolicy` 解析，与启动路径同源）。 */
  jreId: string = '';
}

/** 展开 context：库路径解析函数由调用方注入（避免与本模块形成循环依赖）。 */
export interface ForgeExpandContext {
  /** libraries/ 绝对目录。 */
  libraryDir: string;
  /** installer 解包目录（`data/` 下的文件在此取）。 */
  unzipDir: string;
  /** 游戏根（`{ROOT}`）。 */
  gameRoot: string;
  /** installer jar 绝对路径（`{INSTALLER}`）。 */
  installerJar: string;
  /** 独立 temp 的 vanilla client jar（`{MINECRAFT_JAR}`；**严禁**用共享缓存路径）。 */
  minecraftJar: string;
  /** MC 版本（`{MINECRAFT_VERSION}`）。 */
  minecraftVersion: string;
  /** 坐标 → maven 相对路径（由 VersionInstaller 注入，复用同一套规则）。 */
  mavenPathOf: (name: string) => string;
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

/** 取路径的父目录。 */
function dirOf(filePath: string): string {
  const i = filePath.lastIndexOf('/');
  return i > 0 ? filePath.substring(0, i) : '';
}

/** 文件是否存在（读取失败一律按不存在）。 */
function fileExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch {
    return false;
  }
}

/** 文件 sha1（小写；缺失/读取失败按空串，调用方据此判定不符）。 */
async function forgeSha1(path: string): Promise<string> {
  try {
    return (await hash.hash(path, HASH_ALGORITHM)).toLowerCase();
  } catch {
    return '';
  }
}

/**
 * 单个占位符/字面量/坐标 → 展开值（对齐 HMCL `parseLiteral`）：
 * - `'literal'` → 去引号；
 * - `[group:name:version[:classifier][@ext]]` → `<libraries>/<maven 路径>`；
 * - 其它 → 替换其中的 `{KEY}`（**未定义则抛错**，便于定位缺失的 `data` 键）。
 */
function expandForgeValue(raw: string, vars: Map<string, string>, ctx: ForgeExpandContext): string {
  const t = raw.trim();
  if (t.length >= 2 && t.startsWith("'") && t.endsWith("'")) {
    return t.substring(1, t.length - 1);
  }
  if (t.length >= 2 && t.startsWith('[') && t.endsWith(']')) {
    return `${ctx.libraryDir}/${ctx.mavenPathOf(t.substring(1, t.length - 1))}`;
  }
  let out = t;
  let guard = 0;
  while (out.includes('{') && guard < 16) {
    guard++;
    const open = out.indexOf('{');
    const close = out.indexOf('}', open + 1);
    if (close < 0) {
      break;
    }
    const key = out.substring(open + 1, close);
    const v = vars.get(key);
    if (v === undefined) {
      throw new Error(`unresolved placeholder {${key}}`);
    }
    out = out.substring(0, open) + v + out.substring(close + 1);
  }
  return out;
}

/**
 * 读工具 jar 的 `Main-Class`（解包该 jar、解析 MANIFEST、结果落缓存；同一 jar 只解一次）。
 *
 * **必需**：`-cp` 方式运行工具要显式主类，且各代工具类名不同（照抄会随版本漂移失效）。
 * 与 `NeoForgeInstaller.readToolMainClassAsync` 同款（本侧独立实现，避免两侧耦合）。
 */
export async function readForgeToolMainClassAsync(jarPath: string, cacheDir: string): Promise<string> {
  const base = jarPath.substring(jarPath.lastIndexOf('/') + 1);
  const cacheFile = `${cacheDir}/mainclass/${base}.txt`;
  try {
    if (fileIo.accessSync(cacheFile)) {
      return fileIo.readTextSync(cacheFile).trim();
    }
  } catch {
    // 忽略。
  }
  const outDir = `${cacheDir}/mainclass/${base}`;
  // 先清后解：`.txt` 只在解包成功后写入，故半截目录（无 `.txt`）会被下一轮再次解压 ⇒ 先清即可廉价重算。
  removeTreeBestEffort(outDir);
  ensureDir(outDir);
  await zlib.decompressFile(jarPath, outDir);
  const manifestPath = `${outDir}/META-INF/MANIFEST.MF`;
  const text = fileIo.readTextSync(manifestPath);
  // JAR 规范：MANIFEST 每行 ≤72 字节，超长会**折行**（续行以一个空格开头）⇒ 先拼回再匹配。
  const logical: string[] = [];
  for (const rawLine of text.split('\n')) {
    const line = rawLine.endsWith('\r') ? rawLine.substring(0, rawLine.length - 1) : rawLine;
    if (line.startsWith(' ') && logical.length > 0) {
      logical[logical.length - 1] += line.substring(1);
    } else {
      logical.push(line);
    }
  }
  let mainClass = '';
  for (const l of logical) {
    if (l.startsWith('Main-Class:')) {
      mainClass = l.substring('Main-Class:'.length).trim();
      break;
    }
  }
  if (mainClass.length === 0) {
    throw new Error(`Main-Class missing in ${base}`);
  }
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(cacheFile,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, mainClass);
  } catch {
    // 缓存写失败不影响本次结果。
  } finally {
    // 无论写入成功、失败还是中途抛出，都必须释放 fd（应用 fd 数有限且进程长期驻留）。
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch {
        // 忽略关闭异常
      }
    }
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'tool %{public}s main=%{public}s', base, mainClass);
  return mainClass;
}

/**
 * processor 的展示标签：`<artifact>`，若参数含 `--task <TASK>` 则拼成 `<artifact>:<TASK>`。
 *
 * 为什么带 task：1.17.1+ 的 client 侧有 **3 个 installertools 子任务**（MCP_DATA / DOWNLOAD_MOJMAPS /
 * MERGE_MAPPING），其 artifact id 全是 `installertools` ⇒ 只用 artifact 名时失败日志
 * `processor failed (installertools)` 分不清是哪一个子任务（诊断要求）。
 */
function forgeProcessorLabel(p: ForgeNewProcessorJson): string {
  const shortName = p.jar.split(':')[1] ?? p.jar;
  const args = p.args ?? [];
  for (let i = 0; i + 1 < args.length; i++) {
    if (args[i] === '--task') {
      return `${shortName}:${args[i + 1]}`;
    }
  }
  return shortName;
}

/**
 * 由 profile 生成**可执行**的 processor 计划（只含 client 侧；顺序与 profile 一致）。
 *
 * 变量表：`data.*.client` 三形态 → 绝对路径/字面量；另注入内建变量
 * `SIDE=client`、`MINECRAFT_JAR`、`MINECRAFT_VERSION`、`ROOT`、`INSTALLER`、`LIBRARY_DIR`。
 * 每条 plan 同时携带**展开后的 `outputs`**（G3 幂等判定用，见各 `forgeOutputs*` 函数）。
 */
export async function buildForgeProcessorPlans(profile: ForgeNewInstallProfileJson,
  ctx: ForgeExpandContext, scratchDir: string): Promise<ForgeProcessorSet> {
  const vars = new Map<string, string>();
  // 内建变量（与 installer/HMCL 的名字一致）
  vars.set('SIDE', 'client');
  vars.set('MINECRAFT_JAR', ctx.minecraftJar);
  vars.set('MINECRAFT_VERSION', ctx.minecraftVersion);
  vars.set('ROOT', ctx.gameRoot);
  vars.set('INSTALLER', ctx.installerJar);
  vars.set('LIBRARY_DIR', ctx.libraryDir);
  // data（只取 client；值是"坐标/字面量/安装包内路径"三种形态）
  const data = profile.data ?? {};
  const keys = Object.keys(data);
  for (const key of keys) {
    const entry = data[key];
    const raw = entry.client ?? '';
    if (raw.length === 0) {
      continue;
    }
    let value = '';
    if (raw.startsWith('/')) {
      // 安装包内路径（如 /data/client.lzma）：installer 已整体解包
      value = `${ctx.unzipDir}${raw}`;
    } else {
      value = expandForgeValue(raw, vars, ctx);
    }
    vars.set(key, value);
    // 输出类路径（坐标形态）先备好父目录，部分工具不会自建。
    const parent = dirOf(value);
    if (parent.length > 0) {
      ensureDir(parent);
    }
  }

  const plans: ForgeProcessorPlan[] = [];
  const processors = profile.processors ?? [];
  const clientPlans = processors.filter((p: ForgeNewProcessorJson) =>
    p.sides === undefined || p.sides.includes('client'));
  for (const p of clientPlans) {
    const jarRel = ctx.mavenPathOf(p.jar);
    const jarPath = `${ctx.libraryDir}/${jarRel}`;
    const plan = new ForgeProcessorPlan(forgeProcessorLabel(p));
    const cp: string[] = [];
    for (const c of p.classpath ?? [p.jar]) {
      const rel = ctx.mavenPathOf(c);
      if (rel.length === 0) {
        continue;
      }
      const abs = `${ctx.libraryDir}/${rel}`;
      if (!cp.includes(abs)) {
        cp.push(abs);
      }
    }
    if (!cp.includes(jarPath)) {
      cp.push(jarPath);
    }
    plan.classpath = cp;
    const argv: string[] = [];
    for (const a of p.args ?? []) {
      argv.push(expandForgeValue(a, vars, ctx));
    }
    plan.argv = argv;
    // `outputs` 形态 = 对象 `{路径占位键: sha1 占位值}`（**不是数组**）：逐条展开为字面路径/sha1。
    const outs = p.outputs;
    if (outs !== undefined) {
      for (const k of Object.keys(outs)) {
        const target = new ForgeOutputTarget();
        target.path = expandForgeValue(k, vars, ctx);
        target.sha1 = expandForgeValue(outs[k], vars, ctx).toLowerCase();
        plan.outputs.push(target);
      }
    }
    plan.mainClass = await readForgeToolMainClassAsync(jarPath, scratchDir);
    plans.push(plan);
  }
  const set = new ForgeProcessorSet();
  set.plans = plans;
  set.patchedPath = vars.get('PATCHED') ?? '';
  return set;
}

/**
 * 该 processor 的 `outputs` 是否**全部**命中：非空 + 文件存在 + sha1 相符。
 * 空 `outputs`（真件里 1.17.1+ 的 binarypatcher 无 outputs）⇒ 恒 `false`（**不可跳过**，必须执行）。
 *
 * ⚠️ 这里**只看 sha1**（不做 ZIP 结构降级）：对齐 HMCL `ProcessorTask.execute()` 的**预检**
 * （`if (!outputs.isEmpty() && !miss) return;` —— 预检里 sha1 不符就删件重跑，不看结构）。ZIP 结构降级
 * 只属于**执行后校验**（`forgeVerifyOutputsOrThrow`），这样"预检认为命中"与"执行后接受"的判据互不冲突。
 */
export async function forgeOutputsAllMatch(plan: ForgeProcessorPlan): Promise<boolean> {
  if (plan.outputs.length === 0) {
    return false;
  }
  for (const o of plan.outputs) {
    if (o.path.length === 0 || o.sha1.length === 0) {
      return false;
    }
    if (!fileExists(o.path)) {
      return false;
    }
    const actual = await forgeSha1(o.path);
    if (actual !== o.sha1) {
      return false;
    }
  }
  return true;
}

/**
 * 删除与声明 sha1 不符/为空的现有产物（工具多为"先删后写"，先清掉陈旧件交给工具重建；HMCL 同款）。
 * 只在"未全命中、即将执行"的路径上调用，避免把有效产物误删。
 */
export async function forgeRemoveStaleOutputs(plan: ForgeProcessorPlan): Promise<void> {
  for (const o of plan.outputs) {
    if (o.path.length === 0 || !fileExists(o.path)) {
      continue;
    }
    let matches = false;
    if (o.sha1.length > 0) {
      matches = (await forgeSha1(o.path)) === o.sha1;
    }
    if (!matches) {
      try {
        fileIo.unlinkSync(o.path);
      } catch {
        // 删除失败也继续：工具会覆盖重写。
      }
    }
  }
}

/** 输出路径是否 `.jar`（大小写不敏感）—— **只有 `.jar`** 允许走 ZIP 结构降级。 */
function isJarOutput(path: string): boolean {
  return path.toLowerCase().endsWith(JAR_EXTENSION);
}

/**
 * `.jar` 输出的 **ZIP 结构降级校验**：能整体解出（结构与条目完整）即视为通过。
 *
 * 实现 = `zlib.decompressFile` 解到 `scratchDir` 下的临时目录：它既验证 ZIP 结构可读（中央目录/条目表），
 * 又验证条目数据可完整解出（优于 HMCL `ZIP_INTEGRITY_CHECK_HANDLER` 的"只开 zip 文件系统"）。
 * 探测目录**用完即删**（失败时可能只解出一部分，绝不可留在 workDir 里被下一轮误用）。
 */
async function forgeZipStructurallyValid(jarPath: string, scratchDir: string): Promise<boolean> {
  const probeDir = `${scratchDir}/zipprobe`;
  removeTreeBestEffort(probeDir);
  try {
    ensureDir(probeDir);
    await zlib.decompressFile(jarPath, probeDir);
    return true;
  } catch {
    return false;
  } finally {
    removeTreeBestEffort(probeDir);
  }
}

/**
 * 执行后逐条校验 `outputs`：**主判据是 sha1**；sha1 不符时，**仅 `.jar`** 降级为 ZIP 结构校验
 * （`forgeZipStructurallyValid`），通过则继续并打一条稳定英文 warn（**不伪造 sha1、不写出"已核对"**）；
 * 非 `.jar` 输出、或 `.jar` 但结构也不合法 ⇒ **先删产物再抛可诊断错误**。
 *
 * 为什么做这个降级（**有意对齐 HMCL 的 Forge 侧行为**）：Forge 的 processor 会在安装期**动态生成** jar
 * （`jarsplitter` 的 `MC_SLIM`/`MC_EXTRA`、`binarypatcher` 的 `PATCHED`）；若设备沙箱的 deflate 实现
 * 与官方"参考 zlib"逐字节不同（HMCL 用 `ZlibUtils.IS_ZLIB_COMPATIBLE` 的已知向量探测这种环境），
 * 官方 `install_profile.json` 记录的 sha1 就**必然不符** ⇒ 不做降级会让安装**必然失败**。
 * HMCL 的做法（`ForgeNewInstallTask.ProcessorTask.execute()`）：`if (!ZlibUtils.IS_ZLIB_COMPATIBLE
 * && ext == "jar")` → `FileDownloadTask.ZIP_INTEGRITY_CHECK_HANDLER.checkIntegrity(...)` → 通过即 `continue`；
 * **NeoForge 侧没有这个降级** ⇒ 这正是"Forge/NeoForge 两条链分开实现"的好处之一：本侧可以照抄，
 * 而不必污染 NeoForge 链（本文件与 `NeoForgeInstaller.ets` 互不调用）。
 *
 * `scratchDir` = 可写的临时根（processor 的 `workDir`）；ZIP 探测的中间产物落在其下的 `zipprobe/`。
 */
export async function forgeVerifyOutputsOrThrow(plan: ForgeProcessorPlan, scratchDir: string): Promise<void> {
  for (const o of plan.outputs) {
    if (o.path.length === 0 || o.sha1.length === 0) {
      continue;
    }
    const present = fileExists(o.path);
    let actual = '';
    if (present) {
      actual = await forgeSha1(o.path);
    }
    if (actual === o.sha1) {
      continue;
    }
    // sha1 不符：**仅 `.jar`** 允许降级为 ZIP 结构校验（有意对齐 HMCL 的 Forge 侧行为，见本函数注释）。
    const jarDowngrade = present && isJarOutput(o.path);
    if (jarDowngrade && await forgeZipStructurallyValid(o.path, scratchDir)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'output sha1 mismatch but ZIP structure is valid; accepting (zlib-downgrade) label=%{public}s'
        + ' file=%{public}s expected=%{public}s actual=%{public}s',
        plan.label, o.path, o.sha1, actual.length > 0 ? actual : 'missing');
      continue;
    }
    if (present) {
      try {
        // 先删再抛是"下次重跑"的前提，删不掉也要如实报错。
        fileIo.unlinkSync(o.path);
      } catch {
        // 忽略删除失败。
      }
    }
    const reason = present
      ? (jarDowngrade ? 'sha1-mismatch+zip-invalid' : 'sha1-mismatch')
      : 'missing';
    throw new Error(`processor output rejected (${plan.label}): ${o.path}`
      + ` expected-sha1=${o.sha1} actual-sha1=${actual.length > 0 ? actual : 'missing'} reason=${reason}`);
  }
}
