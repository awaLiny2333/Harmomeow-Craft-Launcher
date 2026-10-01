import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { RAWFILE_MEOWCRAFT_EXTRAS, MEOWCRAFT_EXTRAS_DONE, RAWFILE_OSHI_DIR,
  RAWFILE_OSHI_MANIFEST, mcCpRoot, mcCpInstanceDir, instanceCacheName } from '../constants/Paths';
import { EXTRAS_VERSION, LWJGL_JAR_PREFIX,
  LWJGL_GEN_JARS, ASM_STAGE_SUBDIR, EXPECTED_ASM_JARS } from '../constants/LaunchDefaults';
// 真树 classpath 的**主类形态表**（与 `MinecraftLauncher.needsRealClasspath` 同一份常量 ⇒ 同一事实源）。
import { REAL_CLASSPATH_MAIN_CLASSES } from '../constants/LaunchContract';
import { collectJarSources, lwjglGeneration, isLegacyLwjgl, isLaunchWrapperMain } from './MinecraftLauncher';
import { LOADER_NEO_FORGE, resolveVersion } from './VersionResolver';

// native 导出（extractRawTar：解 meowcraft_extras.tar.gz）
import native from 'libmeowassets.so';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'ClasspathStager';

/** staging 物化意图（日志用）：`-cp` 是 `<dir>/*` 通配。 */
const STAGE_FLAT: string = 'flat';
/** staging 物化意图（日志用）：`-cp` 是显式绝对路径列表。 */
const STAGE_SLIM: string = 'slim';

/**
 * 本实例的 `-cp` 会不会是**平铺通配** `<dir>/*`（= 必须把整份声明库物化到 staging 目录）。
 *
 * 必须与 `MinecraftLauncher.buildLaunchArgv` 的形态分流（`needsRealClasspath` / `isLaunchWrapperMain`）
 * **同源**——staging 目录存在的意义就是被那条 `-cp` 消费。判据**全部复用启动侧的共享件**
 * （`REAL_CLASSPATH_MAIN_CLASSES` 同一常量 + 导入的 `isLaunchWrapperMain`）⇒ 两处不可能分歧：
 *  - 主类属真树族（`REAL_CLASSPATH_MAIN_CLASSES`）或 `loader === neoforge`
 *    ⇒ `-cp` 是逐条绝对路径（`real-tree`）⇒ **slim**；
 *  - 主类 = launchwrapper `Launch`（≤1.12.2 Forge / LiteLoader / 独立 OptiFine）⇒ `-cp` 是逐条绝对
 *    路径的**有序**列表（`ordered`）⇒ **slim**；
 *  - 其余（vanilla / Fabric）⇒ `<dir>/*` ⇒ **flat**。
 *
 * **方向性是故意的**：与启动侧判据同源 ⇒ 真正的"判不出"只剩"主类未被任何分支认出"这一种，
 * 一律落回 **flat**（多铺整套声明库）。这一侧偏安全 —— flat 的 `-cp` **就是**平铺目录通配，
 * 宁可多铺（只多花 I/O），不要少铺（会缺件）。
 */
function classpathUsesWildcard(gameRoot: string, jsonPath: string): boolean {
  const resolved = resolveVersion(gameRoot, jsonPath);
  if (resolved === null) {
    return true;
  }
  const main = resolved.json.mainClass ?? '';
  if (REAL_CLASSPATH_MAIN_CLASSES.includes(main)) {
    return false;
  }
  if (resolved.loader === LOADER_NEO_FORGE) {
    return false;
  }
  return !isLaunchWrapperMain(main);
}

/**
 * 把某版本的运行 jar **按 classpath 形态**物化到 `cacheDir/mc-cp/<key>-<id>/`（超长 -cp 在本 JLI
 * 移植会失效；`<key>` = gameRoot 短哈希、`<id>` = 实例名 —— 按游戏根隔离同名实例，见 `Paths.gameRootKey`）。
 *
 * 形态分流（判据见 `classpathUsesWildcard`；**行为上唯一允许的差异 = 不再多铺无用的库**）：
 *  - **flat**（vanilla / Fabric）：`-cp "<dir>/*"` ⇒ 把整份声明库**逐件**平铺（缺一件就起不来）；
 *  - **slim**（launchwrapper 系的 `ordered` / Forge ≥1.13 与 NeoForge 的 `real-tree`）：`-cp` 是
 *    **显式绝对路径列表** ⇒ 平铺目录只剩两处取件用途：
 *      ① 随包件：`lwjgl-<gen>.jar`（`real-tree` 按绝对路径补进 `-cp`）与 `asm9/*`（ASM 覆盖）；
 *      ② **oshi 补丁件**：`real-tree` / `ordered` 都按**绝对路径**前置这一件（见
 *         `MinecraftLauncher.assembleRealTreeClasspath`），故它必须物化（且是覆盖后的补丁内容）。
 *    整份声明库在这一形态里**不进任何 classpath** ⇒ 拷它纯属无用 I/O。
 * 两种形态都含 meowcraft_extras 解压与残留 jar 清理。纯文件操作，不依赖 UI；失败时返回空串由调用方中止启动。
 */
export function stageClasspathDir(ctx: common.UIAbilityContext, gameRoot: string,
  jsonPath: string, versionId: string): string {
  const cacheDir = ctx.cacheDir;
  // 目录名带 gameRoot 短哈希前缀（`<key>-<id>`）⇒ 同名而不同根的实例不共享 staging 目录。
  const instance = instanceCacheName(gameRoot, versionId);
  const base = mcCpRoot(cacheDir);
  const dir = mcCpInstanceDir(cacheDir, gameRoot, versionId);
  // 随包**只有一代** LWJGL jar（`lwjgl-3.4.3.jar`，其 overlay 带 3.4.x 兼容 shim，
  // 服务 MC 1.13–1.21.x 与 ≥1.22）。平铺目录里必须只留它一份（-cp "<dir>/*" 不能同时
  // 装两份 org.lwjgl.*；旧代残留由 pruneStaleJars 兜底清）。natives 现也只剩 liblwjgl_343* +
  // 无后缀的 legacy `liblwjgl.so`，靠 bundledLibrary.nameMapper 区分（见 LaunchDefaults）。
  const gen = lwjglGeneration(jsonPath);
  const genJar = `${LWJGL_JAR_PREFIX}${gen}.jar`;
  // legacy LWJGL2（≤1.12.2）：classpath 不能混入我们的 LWJGL3（两者都定义 org.lwjgl 包 →
  // sealing violation）。此时 keepGenJar 置空 → 把随包的那一代 jar 从平铺目录移除，只留 MC 的 LWJGL2。
  const legacyLwjgl = isLegacyLwjgl(jsonPath);
  const keepGenJar = legacyLwjgl ? '' : genJar;
  // ★形态（判据见 `classpathUsesWildcard`）：flat = 整份平铺；slim = 只物化"随包件 + oshi 补丁件"。
  const flat = classpathUsesWildcard(gameRoot, jsonPath);
  for (const d of [base, dir]) {
    try {
      fileIo.mkdirSync(d);
    } catch (e) {
      // 已存在则忽略
    }
  }
  // 随包件（lwjgl 合并 jar + asm9/ 子目录）随包分发。done 文件内容 = **令牌 + 随包 tar 的字节数**：
  //  - 令牌由人显式升（内容语义变化时）；
  //  - 字节数让"换了 tar 却忘升令牌"也自动重抽 —— 2026-09-15 踩过：native 改名后重打了 tar
  //    但令牌没动 → done 命中 → 缓存的**旧 lwjgl jar**（旧 nameMapper）继续被用 → 找旧 so 名 →
  //    `UnsatisfiedLinkError`。install -r 保留 cacheDir，光靠"文件存在"判断必然踩这个坑。
  const stamp = `${EXTRAS_VERSION}|${extrasTarBytes(ctx)}`;
  const doneMark = `${dir}/${MEOWCRAFT_EXTRAS_DONE}`;
  try {
    let upToDate = false;
    try {
      upToDate = fileIo.readTextSync(doneMark) === stamp;
    } catch (e) {
      upToDate = false; // 无标记或读取失败 → 重抽
    }
    // 标记命中还不够：cacheDir 可能被系统部分清理（丢件却留下标记）→ 期望件必须都在。
    if (upToDate && !stagedBundleComplete(dir, keepGenJar)) {
      upToDate = false;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'extras %{public}s: stamp=%{public}s reextract=%{public}s',
      instance, stamp, upToDate ? 'no' : 'yes');
    if (!upToDate) {
      if (native.extractRawTar(ctx.resourceManager, RAWFILE_MEOWCRAFT_EXTRAS, dir) as boolean) {
        const f = fileIo.openSync(doneMark, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
          fileIo.OpenMode.TRUNC);
        // try/finally：写入抛出也要释放 fd（外层 catch 只记日志、不关描述符）。
        try {
          fileIo.writeSync(f.fd, stamp);
        } finally {
          fileIo.closeSync(f);
        }
      }
    }
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'extract meowcraft_extras fail: %{public}s', JSON.stringify(e));
  }
  // oshi 覆盖清单：**一次读**、两处用（slim 的物化选择 + 覆盖本身）。清单缺失/为空 ⇒ 空表（= 无覆盖，
  // 优雅降级为上游行为）。与旧行为的唯一差别：这条 info 在 slim 下出现在拷贝循环**之前**。
  const oshiEntries = oshiManifestEntries(ctx);
  // 声明库只在"确实要物化它们"时才收集：slim 且清单为空（本版本没有可覆盖的 oshi 件）⇒ 连这一步都省
  // （省掉对全库逐件的 stat）。slim 的物化选择本身 = "清单点名 ∩ 本版本声明"（见 slimDeclaredSources）。
  const sources = (flat || oshiEntries.length > 0)
    ? collectJarSources(gameRoot, jsonPath, versionId)
    : [];
  const stageSources = flat ? sources : slimDeclaredSources(sources, oshiEntries);
  let copied = 0;
  let checked = 0;
  for (const src of stageSources) {
    const name = src.substring(src.lastIndexOf('/') + 1);
    const dest = `${dir}/${name}`;
    try {
      checked++;
      const srcSize = fileIo.statSync(src).size;
      let needCopy = true;
      try {
        const dstSize = fileIo.statSync(dest).size;
        needCopy = dstSize !== srcSize;
      } catch {
        needCopy = true;
      }
      if (needCopy) {
        fileIo.copyFileSync(src, dest);
        copied++;
      }
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sync fail %{public}s: %{public}s', src, JSON.stringify(e));
    }
  }
  // 自编 patched oshi 覆盖 staged 的同名 jar（版本无关；不改用户 .minecraft）：鸿蒙沙箱禁
  // /proc/cpuinfo，上游 oshi 读不到 CPU 型号；覆盖件认 -Dmeow.cpu.chip（:game 进程 deviceInfo.chipType）。
  // 只覆盖本版本实际物化过的 oshi 件（清单里其余版本跳过）。flat 下"物化过"= 刚平铺进来的那一件；
  // slim 下 = slimDeclaredSources 选中的那一件，故覆盖面两形态一致。
  applyOshiOverrides(ctx, dir, oshiEntries);
  dropOtherLwjglJar(dir, keepGenJar);
  // 期望集合 = **本次物化过的那几件** + 保留的 LWJGL 世代 jar（flat 时前者 = 整份声明库，与旧行为一致；
  // slim 时 = oshi 补丁件）。其余 .jar 一律删 —— 旧 cacheDir 里遗留的 `launcher.jar` /
  // `gson-for-launcher.jar`、上一次 flat 铺下的整份库、退代的 `lwjgl-3.3.3.jar` 都由此清掉。
  pruneStaleJars(dir, stageSources, keepGenJar);
  // 启动期形态断言：classpath 里 `org.lwjgl` 的提供者必须形态正确（不混代、不多不少）。
  // 异常直接中止启动（把类冲突挡在更前面），而非带着坏 classpath 硬跑。
  if (!lwjglClasspathOk(dir, legacyLwjgl, keepGenJar, flat)) {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'LWJGL classpath shape invalid (legacy=%{public}s keep=%{public}s): abort launch',
      legacyLwjgl ? 'yes' : 'no', keepGenJar.length > 0 ? keepGenJar : '(none)');
    return '';
  }
  // 形态自证（上机验证"这次到底铺了什么"先看这一行）：sources = 本次**有资格被物化**的件数
  // （flat = 整份声明库；slim = 清单点名的 oshi 件）。
  hilog.info(LOG_DOMAIN, LOG_TAG, 'stage %{public}s: mode=%{public}s sources=%{public}d',
    instance, flat ? STAGE_FLAT : STAGE_SLIM, stageSources.length);
  hilog.info(LOG_DOMAIN, LOG_TAG,
    'stage %{public}s: gen=%{public}s keep=%{public}s(%{public}d) checked=%{public}d copied=%{public}d',
    instance, gen, keepGenJar.length > 0 ? keepGenJar : '(none)',
    keepGenJar.length > 0 ? jarBytes(`${dir}/${keepGenJar}`) : -1, checked, copied);
  return dir;
}

/**
 * 断言平铺目录里 `org.lwjgl` 的提供者形态正确（启动期，一次）：
 * - legacy（LWJGL2，≤1.12.2）：**不得**出现我们的任一 LWJGL3 世代 jar；`flat` 形态还要求 MC 的
 *   LWJGL2（`lwjgl-2.*`/`lwjgl_util-2.*`）就在这个目录里 —— 因为 flat 的 `-cp "<dir>/*"` **就是**
 *   classpath（MC 的 LWJGL2 必须靠它）；`slim`（ordered）的 `-cp` 是显式列表、MC 的 LWJGL2 从真库树取
 *   ⇒ 该要求是空对空，只断言"不留我们的 LWJGL3"。
 * - 现代（LWJGL3）：**恰好**保留选中世代那一个 jar；不得出现 LWJGL2。
 * 违反 → 返回 false（调用方中止启动），避免"两份 org.lwjgl 类"的密封/重复类错误。
 */
function lwjglClasspathOk(dir: string, legacy: boolean, keepGenJar: string, flat: boolean): boolean {
  let ours = 0;
  let oursKeep = 0;
  let mc2 = 0;
  let stray = 0;
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (e) {
    return false;
  }
  for (const name of entries) {
    if (!name.endsWith('.jar')) {
      continue;
    }
    if (LWJGL_GEN_JARS.includes(name)) {
      ours++;
      if (name === keepGenJar) {
        oursKeep++;
      }
    } else if (name.startsWith('lwjgl-2.') || name.startsWith('lwjgl_util-2.')) {
      mc2++;
    } else if (/^lwjgl-\d/.test(name)) {
      // 其它 `lwjgl-<数字>*`（如退役的 `lwjgl-3.3.3.jar` 若 prune 没删掉）= 第二份 org.lwjgl
      // 提供者；只匹配"lwjgl-数字"以免误伤 `lwjgl_util-2.x` 或第三方 `lwjgl-helper.jar`。
      stray++;
    }
  }
  if (stray > 0) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'stray lwjgl jar(s) in classpath dir: %{public}d', stray);
    return false;
  }
  if (legacy) {
    // flat：平铺目录就是 classpath ⇒ MC 的 LWJGL2 必须在里面（否则 legacy 实例根本没有 org.lwjgl）。
    // slim（ordered）：平铺目录不进 classpath ⇒ 不再要求它在这里，只要求我们的 LWJGL3 一件不留。
    return ours === 0 && (flat ? mc2 >= 1 : true);
  }
  return ours === 1 && oursKeep === 1 && mc2 === 0;
}

/** 随包 extras tar 的字节数（**轻量**：只取 fd/长度，不把内容读进内存；失败 → -1，退化为只比令牌）。 */
function extrasTarBytes(ctx: common.UIAbilityContext): number {
  try {
    const d = ctx.resourceManager.getRawFdSync(RAWFILE_MEOWCRAFT_EXTRAS);
    const len = d.length;
    ctx.resourceManager.closeRawFdSync(RAWFILE_MEOWCRAFT_EXTRAS);
    return len;
  } catch (e) {
    return -1;
  }
}

/** 平铺目录里某文件的字节数（-1 = 缺失）；日志用，便于一眼看出"是不是旧的"。 */
function jarBytes(path: string): number {
  try {
    return fileIo.statSync(path).size;
  } catch (e) {
    return -1;
  }
}

/**
 * 抽取标记命中时确认"该有的件都在"（防 cacheDir 被系统部分清理：标记还在、文件没了）。
 *
 * 断言对象 = **随包 extras 里的件**（tar 根下的 `keepGenJar` + `asm9/*`）——两形态同款：
 * slim 也依赖这两处（`real-tree` 按绝对路径取 `lwjgl-<gen>.jar`；ASM 覆盖取 `asm9/`），
 * 而"声明库件在不在"另有拷贝循环逐件兜底（每轮都跑，不看标记）⇒ 这里无需（也不该）断言它们。
 */
function stagedBundleComplete(dir: string, keepGenJar: string): boolean {
  if (keepGenJar.length > 0) {
    try {
      fileIo.accessSync(`${dir}/${keepGenJar}`);
    } catch (e) {
      return false;
    }
  }
  // 随包 ASM 件在**子目录**里（不平铺，见 LaunchDefaults.ASM_STAGE_SUBDIR）——它们不被
  // pruneStaleJars 的平铺扫描碰到，故也必须在这里显式核对，否则"标记在、asm9/ 被清空"查不出来。
  for (const n of EXPECTED_ASM_JARS) {
    try {
      fileIo.accessSync(`${dir}/${ASM_STAGE_SUBDIR}/${n}`);
    } catch (e) {
      return false;
    }
  }
  return true;
}

/** 删除**我们的** lwjgl jar 中"不该留的那一份"（现在只有一代，故正常情况什么都不删；主要是给
 *  "旧 cacheDir 残留的 3.3.3"兜底）。只匹配 `LWJGL_GEN_JARS` 里的**精确名**——**绝不能**用
 *  `lwjgl-` 前缀，否则会误删 MC 自带的 LWJGL2（`lwjgl-2.9.x.jar`，legacy ≤1.12.2 需要）。 */
function dropOtherLwjglJar(dir: string, keepJar: string): void {
  const ours = new Set<string>(LWJGL_GEN_JARS);
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    if (ours.has(name) && name !== keepJar) {
      removeFile(`${dir}/${name}`);
    }
  }
}

function removeFile(path: string): void {
  try {
    fileIo.unlinkSync(path);
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'remove fail %{public}s', path);
  }
}

/** 随包 oshi 覆盖清单的一条（`<目标 jar 名>=<随包 patched jar 的 rawfile 名>`）。 */
interface OshiManifestEntry {
  /** staging 目录里的**目标 jar 名**（= 本版本声明的同名件，覆盖后即"oshi 补丁件"）。 */
  target: string;
  /** 随包里那份**已打补丁**的同名 jar 的 rawfile 名。 */
  raw: string;
}

/**
 * 读 `rawfile/oshi-overrides/manifest.txt`。清单缺失/为空 ⇒ 空表（= 无覆盖，未适配的 MC 版本优雅
 * 降级为上游行为），并记一条（与旧 `applyOshiOverrides` 同条件、同一句话）。
 *
 * 清单**列出所有支持的 oshi 版本** ⇒ 读取方必须自己按"本版本有没有这件"过滤（`applyOshiOverrides`
 * 按目录存在性过滤；`slimDeclaredSources` 按本版本声明的库过滤）。
 */
function oshiManifestEntries(ctx: common.UIAbilityContext): OshiManifestEntry[] {
  let manifest = '';
  try {
    const raw = ctx.resourceManager.getRawFileContentSync(RAWFILE_OSHI_MANIFEST);
    manifest = util.TextDecoder.create('utf-8').decodeToString(raw);
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'no oshi override manifest');
    return [];
  }
  const out: OshiManifestEntry[] = [];
  for (const line of manifest.split('\n')) {
    const entry = line.trim();
    const eq = entry.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const e: OshiManifestEntry = {
      target: entry.substring(0, eq),
      raw: entry.substring(eq + 1),
    };
    out.push(e);
  }
  return out;
}

/**
 * **slim 形态**要物化的**声明库**件：清单点名（= 本工程有补丁件的那一版 oshi）∩ 本版本声明的库。
 *
 * 为什么用"清单点名"而不是"`oshi-core-*` 前缀"：清单就是"哪些件需要补丁"的既有事实源，用它可保证
 * 物化集合与 `applyOshiOverrides` 的覆盖面**逐件一致**（不会出现"铺了一件却永不覆盖"）。
 * 代价（与旧 flat 行为的唯一差异）：**清单里没有的** oshi 版本（将来更上游的新版）在 slim 形态不再被
 * 平铺 —— 启动路径会因此打印 `oshi override missing … -> upstream oshi kept`，用的仍是真树里那份
 * **同样未打补丁**的同名 jar（字节相同，只是路径从 staging 换成真树）；补丁件一就位即自动回到覆盖路径。
 */
function slimDeclaredSources(sources: string[], entries: OshiManifestEntry[]): string[] {
  if (entries.length === 0) {
    return [];
  }
  const want = new Set<string>();
  for (const e of entries) {
    want.add(e.target);
  }
  const out: string[] = [];
  for (const src of sources) {
    const name = src.substring(src.lastIndexOf('/') + 1);
    if (want.has(name)) {
      out.push(src);
    }
  }
  return out;
}

/**
 * 按清单覆盖 staged 的 oshi jar。
 * 清单里但**本版本未物化过**的条目直接**跳过**（只覆盖实际存在的那一版）。
 */
function applyOshiOverrides(ctx: common.UIAbilityContext, dir: string,
  entries: OshiManifestEntry[]): void {
  for (const e of entries) {
    const target = e.target;
    // Only override an oshi jar that THIS version's classpath actually staged.
    // The manifest lists every supported oshi version; overriding the others
    // would CREATE them (openSync CREATE) only to be pruned right after -> 8
    // pointless writes and 9 misleading log lines per launch.
    let present = false;
    try {
      fileIo.statSync(`${dir}/${target}`);
      present = true;
    } catch {
      present = false;
    }
    if (!present) {
      continue;
    }
    overrideStagedJar(ctx, dir, `${RAWFILE_OSHI_DIR}/${e.raw}`, target);
  }
}

/** 用随包 patched jar 覆盖 staged 的同名 jar（内容变化时写一次）。 */
function overrideStagedJar(ctx: common.UIAbilityContext, dir: string,
  rawName: string, jarName: string): void {
  const dest = `${dir}/${jarName}`;
  try {
    const data = ctx.resourceManager.getRawFileContentSync(rawName);
    let needWrite = true;
    try {
      needWrite = fileIo.statSync(dest).size !== data.byteLength;
    } catch {
      needWrite = true;
    }
    if (!needWrite) {
      return;
    }
    const f = fileIo.openSync(dest, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
      fileIo.OpenMode.TRUNC);
    // 只写 Uint8Array 有效区间（.buffer 可能比内容大 → 否则 jar 损坏）。
    // try/finally：写入抛出也要释放 fd（外层 catch 只记日志、不关描述符）。
    try {
      fileIo.writeSync(f.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    } finally {
      fileIo.closeSync(f);
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'override %{public}s <- %{public}s (mem=%{public}d staged=%{public}d)',
      jarName, rawName, data.byteLength, fileIo.statSync(dest).size);
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'override fail %{public}s: %{public}s', rawName,
      JSON.stringify(e));
  }
}

/**
 * 清理平铺目录中不属于当前期望集合的残留 jar（官方 LWJGL / 未选中世代 / 已退役的旧随包件等，防类冲突）。
 *
 * `sources` = **本次物化过**的那些件（调用方传 `stageSources`：flat = 整份声明库；slim = oshi 补丁件），
 * 加上保留的 LWJGL 世代 jar（`keepJar`）；其余 `.jar` 一律删除。slim 下这条尤其重要：它负责把**上一次
 * flat 铺下的整份库**、旧 cacheDir 里遗留的 `launcher.jar` / `gson-for-launcher.jar`、退代的
 * `lwjgl-3.3.3.jar` / `lwjgl-2.9.x.jar` 一次清干净。`asm9/` 是**子目录**、且不匹配 `.jar`
 * （只列平铺目录的条目）⇒ 绝不被碰。
 */
function pruneStaleJars(dir: string, sources: string[], keepJar: string): void {
  const keep = new Set<string>();
  for (const src of sources) {
    keep.add(src.substring(src.lastIndexOf('/') + 1));
  }
  if (keepJar.length > 0) {
    keep.add(keepJar);
  }
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    if (keep.has(name) || !name.endsWith('.jar')) {
      continue;
    }
    try {
      fileIo.unlinkSync(`${dir}/${name}`);
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'prune fail %{public}s: %{public}s', name, JSON.stringify(e));
    }
  }
}
