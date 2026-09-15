import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'NeoForgeInstaller';

/**
 * NeoForge 安装期数据层（**仅 MC 1.20.2+**）：installer 的 profile/清单类型、processor 的
 * **变量表与占位符展开**、以及从工具 jar 读 `Main-Class`。
 *
 * 设计要点（对齐 HMCL + 真 installer 实测，见 notes `20-design/launch/NeoForge支持-调研.md` §2/§8）：
 * - **参数原样来自 profile**，我们只做占位符替换 ⇒ 不需要理解 `-DmergeModules` 之类的语义，
 *   也不必跟随 `InstallerTools` 的 CLI 版本漂移；
 * - `data` 取值三形态：`'literal'` / 安装包内路径（`/data/xxx.lzma`）/ `[maven 坐标]`
 *   （坐标既可能是**输入件**（如 `neoform@zip`，已由 profile.libraries 下好），
 *   也可能是某个工具的**输出路径**——两者都按 maven 树路径解析）；
 * - **主类必须从工具 jar 的 MANIFEST 读**（`-cp` 方式运行需要显式主类；2.x 与 4.x 的工具类名不同，
 *   照抄会随版本漂移而失效）。
 */

/** install_profile.json 的一条 data（只取 client 侧）。 */
export interface NeoForgeDataEntryJson {
  client?: string;
  server?: string;
}

/** install_profile.json 的一条 processor（字段取自真样本；现代版本通常无 outputs）。 */
export interface NeoForgeProcessorJson {
  sides?: string[];
  jar: string;
  classpath?: string[];
  args?: string[];
}

/** install_profile.json（只列用到的字段）。 */
export interface NeoForgeInstallProfileJson {
  spec?: number;
  profile?: string;
  version?: string;
  minecraft?: string;
  json?: string;
  data?: Record<string, NeoForgeDataEntryJson>;
  processors?: NeoForgeProcessorJson[];
  /** 库表：与 vanilla 库同形（由 VersionInstaller 以自身 LibraryJson 处理）。 */
  libraries?: object[];
}

/** installer 内嵌的 version.json（启动清单；只列用到的字段）。 */
export interface NeoForgeLaunchJson {
  id?: string;
  mainClass?: string;
  inheritsFrom?: string;
  type?: string;
  time?: string;
  releaseTime?: string;
  /** 参数：与 vanilla 的 arguments 同形（string 或带 rules 的对象）。
   *  内部以 object 承载，由 VersionInstaller 按自身 ArgumentsJson 处理（JSON 解析结果）。 */
  arguments?: object;
  /** log4j 配置（形态随版本不同；有则搬运）。 */
  logging?: object;
  complianceLevel?: number;
  /** 库表：与 vanilla 库同形（由 VersionInstaller 处理）。 */
  libraries?: object[];
}

/** 一条可执行的 processor（所有路径均已展开为绝对路径）。 */
export class NeoForgeProcessorPlan {
  /** 展示标签（进度用，仅工具名如 `installertools`；序号由进度计数行表达，与下载阶段语义一致）。 */
  label: string = '';
  /** 工具主类（读自工具 jar 的 MANIFEST）。 */
  mainClass: string = '';
  /** 绝对路径 classpath（工具 jar + 其依赖）。 */
  classpath: string[] = [];
  /** 展开后的参数（不含 java 与主类）。 */
  argv: string[] = [];

  constructor(label: string) {
    this.label = label;
  }
}

/** processor 计划集合：可执行计划 + 关键产物（供编排侧断言）。 */
export class NeoForgeProcessorSet {
  plans: NeoForgeProcessorPlan[] = [];
  /** `PATCHED`（打补丁后的 client jar）绝对路径——安装成功的唯一硬判据。 */
  patchedPath: string = '';
}

/** 交给 `:neoinstall` ability 执行的作业（以 JSON 文件传递，避免 want 传长数组）。 */
export class NeoForgeProcessorJob {
  /** 完整 java 参数（`[java, -cp, <cp>, <mainClass>, ...args]`）。 */
  argv: string[] = [];
  /** 游戏目录的用户文件 URI（ability 进程内再激活一次持久化授权；best-effort）。 */
  rootUri: string = '';
}

/** 展开 context：库路径解析函数由调用方注入（避免与本模块形成循环依赖）。 */
export interface NeoForgeExpandContext {
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

/**
 * 单个占位符/字面量/坐标 → 展开值（对齐 HMCL `parseLiteral`）：
 * - `'literal'` → 去引号；
 * - `[group:name:version[:classifier][@ext]]` → `<libraries>/<maven 路径>`；
 * - 其它 → 替换其中的 `{KEY}`（未定义则抛错，便于定位）。
 */
function expandValue(raw: string, vars: Map<string, string>, ctx: NeoForgeExpandContext): string {
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
 * **必需**：`-cp` 方式运行工具要显式主类，且 2.x / 4.x 的工具类名不同（照抄会随版本漂移失效）。
 */
export async function readToolMainClassAsync(jarPath: string, cacheDir: string): Promise<string> {
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
  ensureDir(outDir);
  await zlib.decompressFile(jarPath, outDir);
  const manifestPath = `${outDir}/META-INF/MANIFEST.MF`;
  const text = fileIo.readTextSync(manifestPath);
  // JAR 规范：MANIFEST 每行 ≤72 字节，超长会**折行**（续行以一个空格开头）。主类名较长时
  // （如带包的内部类）会被折行 ⇒ 必须先拼回再匹配，否则读不到 Main-Class。
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
  try {
    fileIo.writeSync(fileIo.openSync(cacheFile,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd, mainClass);
  } catch {
    // 缓存写失败不影响本次结果。
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'tool %{public}s main=%{public}s', base, mainClass);
  return mainClass;
}

/**
 * 由 profile 生成**可执行**的 processor 计划（只含 client 侧；顺序与 profile 一致）。
 *
 * 变量表：`data.*.client` 三形态 → 绝对路径/字面量；另注入内建变量
 * `SIDE=client`、`MINECRAFT_JAR`、`MINECRAFT_VERSION`、`ROOT`、`INSTALLER`、`LIBRARY_DIR`。
 */
export async function buildNeoForgeProcessorPlans(profile: NeoForgeInstallProfileJson,
  ctx: NeoForgeExpandContext, scratchDir: string): Promise<NeoForgeProcessorSet> {
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
      value = expandValue(raw, vars, ctx);
    }
    vars.set(key, value);
    // 输出类路径（坐标形态）先备好父目录，部分工具不会自建。
    const parent = dirOf(value);
    if (parent.length > 0) {
      ensureDir(parent);
    }
  }

  const plans: NeoForgeProcessorPlan[] = [];
  const processors = profile.processors ?? [];
  const clientPlans = processors.filter((p: NeoForgeProcessorJson) =>
    p.sides === undefined || p.sides.includes('client'));
  for (const p of clientPlans) {
    const jarRel = ctx.mavenPathOf(p.jar);
    const jarPath = `${ctx.libraryDir}/${jarRel}`;
    const shortName = p.jar.split(':')[1] ?? p.jar;
    const plan = new NeoForgeProcessorPlan(shortName);
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
      argv.push(expandValue(a, vars, ctx));
    }
    plan.argv = argv;
    plan.mainClass = await readToolMainClassAsync(jarPath, scratchDir);
    plans.push(plan);
  }
  const set = new NeoForgeProcessorSet();
  set.plans = plans;
  set.patchedPath = vars.get('PATCHED') ?? '';
  return set;
}

/** `mergeModules` 要求的一个 jar（加载器按**文件名**在 classpath 里找它）。 */
export class NeoForgeMergeModuleEntry {
  /** 加载器给出的文件名（如 `jna-5.10.0.jar`）——必须**逐字**匹配。 */
  fileName: string = '';
  /** maven 相对路径（`group/artifact/version/<fileName>`）：用于下载与拼 classpath。 */
  relPath: string = '';
}

/** 从 jvm 参数里取 `-DmergeModules=a.jar,b.jar` 的文件名列表（无则空）。 */
function mergeModuleNames(jvmArgs: string[]): string[] {
  const prefix = '-DmergeModules=';
  for (const a of jvmArgs) {
    if (!a.startsWith(prefix)) {
      continue;
    }
    const out: string[] = [];
    for (const one of a.substring(prefix.length).split(',')) {
      const n = one.trim();
      if (n.length > 0) {
        out.push(n);
      }
    }
    return out;
  }
  return [];
}

/** 由文件名拆出 artifact 与 version（如 `jna-platform-5.10.0.jar` → jna-platform / 5.10.0）。 */
function splitArtifactVersion(fileName: string): string[] {
  const base = fileName.endsWith('.jar') ? fileName.substring(0, fileName.length - 4) : fileName;
  const parts = base.split('-');
  // 从**前**找「首个以数字开头的段」作为版本起点（从后找会切错 `lib-1.0.0-beta-2.jar`）：
  //  - `jna-5.10.0` → (jna, 5.10.0)；`jna-platform-5.10.0` → (jna-platform, 5.10.0)；
  //  - `guava-25.1-jre` → (guava, 25.1-jre)（版本保留连字符）。
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    if (seg.length > 0 && seg.charAt(0) >= '0' && seg.charAt(0) <= '9') {
      // 版本 = 从该段起到**结尾**，用 `-` 连接（保留连字符）：`guava-25.1-jre` → `25.1-jre`。
      // 早期用 `.` 连接会把 `25.1-jre` 拆成 `25.1.jre` → 路径错 → 404。
      return [parts.slice(0, i).join('-'), parts.slice(i).join('-')];
    }
  }
  return ['', ''];
}

/**
 * 把 `mergeModules` 的文件名解析成 maven 相对路径。
 *
 * 背景（2026-09-16 实测，NeoForge 20.2.93 / bootstraplauncher 1.1.2）：
 * 加载器按**文件名**在 classpath 里查这些 jar（`getMergeFilenameMap`），查不到就拿空集去
 * union 合并 → 读 `/META-INF/versions` 抛 `UnionFileSystem$NoSuchFileException` → 启动即败。
 * 而它要的 `jna-5.10.0.jar` **并不在任何清单里**（vanilla 1.20.2 只声明 5.13.0）⇒ 必须由我们补。
 * **group 取自「同 artifact 的已声明库」**（jna/jna-platform 都在 vanilla 清单里），版本用加载器点名的。
 */
export function resolveMergeModuleEntries(jvmArgs: string[],
  declaredLibNames: string[]): NeoForgeMergeModuleEntry[] {
  const out: NeoForgeMergeModuleEntry[] = [];
  for (const fileName of mergeModuleNames(jvmArgs)) {
    const av = splitArtifactVersion(fileName);
    const artifact = av[0];
    const version = av[1];
    if (artifact.length === 0 || version.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mergeModules: cannot parse %{public}s', fileName);
      continue;
    }
    let group = '';
    for (const name of declaredLibNames) {
      const core = name.includes('@') ? name.substring(0, name.indexOf('@')) : name;
      const p = core.split(':');
      if (p.length >= 3 && p[1] === artifact) {
        group = p[0];
        break;
      }
    }
    if (group.length === 0) {
      // 解析不出 group（声明库里没有同名 artifact）⇒ 这颗 jar 补不下，启动期会因缺件失败。
      // 必须告警，别静默（历史教训：静默 continue 让问题推迟到启动期才炸）。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mergeModules: no declared artifact for %{public}s', fileName);
      continue;
    }
    const entry = new NeoForgeMergeModuleEntry();
    entry.fileName = fileName;
    entry.relPath = `${group.split('.').join('/')}/${artifact}/${version}/${fileName}`;
    out.push(entry);
  }
  return out;
}

/** 声明库的 name 列表（profile / version.json / 已解析清单均可）。 */
export function libraryNames(libs: object[] | undefined): string[] {
  const out: string[] = [];
  for (const l of (libs ?? []) as NeoForgeLibraryNameJson[]) {
    if (l.name !== undefined && l.name.length > 0) {
      out.push(l.name);
    }
  }
  return out;
}

/** 只取 name 的最小库形状（用于解析 group）。 */
export interface NeoForgeLibraryNameJson {
  name?: string;
}

/** 取 `arguments.jvm` 里的字符串项（installer 写的 jvm 参数都是纯字符串）。 */
export function stringArgs(args: object | undefined): string[] {
  const out: string[] = [];
  const jvm = (args as NeoForgeArgumentsLike | undefined)?.jvm;
  for (const a of jvm ?? []) {
    if (typeof a === 'string') {
      out.push(a);
    }
  }
  return out;
}

/** 只取 jvm 数组的最小 arguments 形状。 */
export interface NeoForgeArgumentsLike {
  jvm?: (string | object)[];
}
