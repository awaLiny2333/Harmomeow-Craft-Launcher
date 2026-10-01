import { fileIo } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { RENDERER_LIB, VULKAN_LIB_SHIM, VULKAN_LIB_DISABLED, WINDOW_DEFAULT_W, WINDOW_DEFAULT_H,
  SPOOF_OS_NAME, SPOOF_OS_VERSION, SPOOF_CPU_NAME,
  LOCALE_LANGUAGE, LOCALE_COUNTRY, LOCALE_TIMEZONE, RULE_OS_NAME, RULE_OS_ARCH,
  OFFLINE_USERNAME, OFFLINE_TOKEN, LAUNCHER_NAME, LAUNCHER_VERSION,
  CLIENT_MOD_NAME, LWJGL_GEN_343, LWJGL_JAR_PREFIX,
  LWJGL_NAME_MAPPER,
  ASM_BUNDLED_VERSION, ASM_STAGE_SUBDIR, EXPECTED_ASM_JARS } from '../constants/LaunchDefaults';
import { REAL_CLASSPATH_MAIN_CLASSES } from '../constants/LaunchContract';
import { libraryNames, resolveMergeModuleEntries } from './NeoForgeInstaller';
import { NATIVES_DIR } from '../constants/Paths';
import { ResolvedVersion, VersionJson, VersionRule, VersionRuleArg,
  LOADER_NEO_FORGE, LOADER_FORGE, resolveVersion, resolveVersionByPath } from './VersionResolver';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameLauncher';

/**
 * classpath 三态**字面量的唯一来源**（只作诊断串的见证；见 `buildLaunchArgv` 的 `classpath mode=<…>`）：
 *  - `real-tree` = 真库树逐条绝对路径 + 实例 jar（Forge ≥1.13 / NeoForge）；
 *  - `ordered`   = launchwrapper 形态的**显式有序绝对路径**（≤1.12.2 Forge / LiteLoader / OptiFine）；
 *  - `flat`      = 平铺目录通配 `<dir>/*`（原版 / Fabric）。
 * 判据见 `needsRealClasspath` / `isLaunchWrapperMain`；名字集中在此以免三处日志各写一份。
 */
const CLASSPATH_MODE_REAL_TREE: string = 'real-tree';
const CLASSPATH_MODE_ORDERED: string = 'ordered';
const CLASSPATH_MODE_FLAT: string = 'flat';

/**
 * 窗口所在显示器的尺寸（px），由 GameWindow 在 surface 就绪时写入。全屏尺寸取决于我们上报给
 * LWJGL2 的 DisplayMode（见 buildLaunchArgv 里 legacy 分支的说明），而窗口可能在副屏上 —— 用默认
 * 显示器会尺寸不符。0 = 未提供，回退到默认显示器。
 */
let windowDisplayW: number = 0;
let windowDisplayH: number = 0;

export function setWindowDisplaySize(w: number, h: number): void {
  windowDisplayW = w;
  windowDisplayH = h;
}

/**
 * Minecraft 启动参数组装（纯函数，无副作用）。
 *
 * 输入：已授权的 .minecraft 根目录物理路径 + 版本 <id>.json 路径。
 * 输出：完整 JVM argv（不含 argv[0]，由调用方填 java 可执行路径）。
 *
 * 职责：
 * 1. 解析版本 json：mainClass / arguments(jvm+game) / libraries / assetIndex / id；
 * 2. 按当前平台（鸿蒙视作 linux + aarch64）过滤规则项；
 * 3. classpath = json 声明且本地真实存在的库 jar + 版本 jar；
 * 4. ${...} 宏替换为离线运行值。
 *
 * 离线约定：username=Player、uuid/accessToken 占位（MC 离线可进主菜单）。
 */

/** 版本 json 数据模型（含三形态判定与合并）见 ./VersionResolver —— 唯一 schema 归属。 */

/**
 * 平台规则命中：无规则默认允许；否则存在 allow 且 os 匹配当前平台才放行。
 */
function ruleAllows(rules?: VersionRule[]): boolean {
  if (rules === undefined || rules.length === 0) {
    return true;
  }
  for (const r of rules) {
    // features 门控（has_custom_resolution / is_demo_user / is_quick_play_* 等）：本工程**不声明**
    // 任何 feature ⇒ 带 features 的规则一律不匹配。必须如此：否则会把 MC json 里 feature 门控的
    // `--width ${resolution_width}` 之类**原样带宏**发出去 → ModLauncher 的 joptsimple 解析
    // `--width` 时 NumberFormatException → 启动即退（2026-09-16 实测 NeoForge 1.21.1）。
    // 非空 features 才视为不匹配（与安装侧 VersionInstaller.rulesAllow 口径一致：
    // `features: {}` 等价于"无特性要求"，应照常命中）。
    if (r.features !== undefined && Object.keys(r.features).length > 0) {
      continue;
    }
    const os = r.os;
    const nameHit = os === undefined || os.name === undefined || os.name === RULE_OS_NAME;
    const archHit = os === undefined || os.arch === undefined || os.arch === RULE_OS_ARCH;
    const hit = nameHit && archHit;
    if (hit && r.action === 'allow') {
      return true;
    }
    if (hit && r.action === 'disallow') {
      return false;
    }
  }
  return false;
}

/** 宏表类型。 */
type LaunchMacros = Map<string, string>;

/** buildLaunchArgv 入参。 */
export interface LaunchOptions {
  /** .minecraft 根目录（物理路径）。 */
  gameRoot: string;
  /** 游戏运行目录（= `-Duser.dir` = game 参数 `${game_directory}` 宏 = MC 的 `--gameDir`）。
   *  未设/空 = gameRoot（不隔离）；启用版本隔离时传 `<gameRoot>/versions/<id>`。
   *  只切运行目录，assets/libraries 仍由 gameRoot 派生（共享池）——与 HMCL/PCL/HomoLauncher 同构。 */
  gameDir?: string;
  /** versions/<id>/<id>.json 物理路径。 */
  jsonPath: string;
  /** 落盘物证目录（best-effort：由 `ensureInstanceLogsDir` 尝试创建，失败返回空串）。
   *  非空时用作 `-XX:ErrorFile` 的落点（hs_err 不落游戏目录；用户自有 ErrorFile 时不覆盖）。
   *  注意：`meowbt` 转储与 `-XX:+Log*` 输出**不**走这里——前者默认只打 stderr（要落盘须显式 `MEOW_BT_FILE`），
   *  后者是诊断参数、随包默认不设。 */
  logsDir?: string;
  /** 完整 classpath（可选）：平铺后用 "<dir>/*" 通配，规避超长 -cp 失效。
   *  **仅用于平铺形态**（原版/Fabric）——自身走真库树的版本（`needsRealClasspath`）与
   *  launchwrapper 形态（`isLaunchWrapperMain`）都会**忽略**它、改走显式有序绝对路径。 */
  classpath?: string;
  /** 平铺目录（可选）：**只在真库树形态**（Forge ≥1.13 / NeoForge）用作**随包 LWJGL3 jar** 的取件处
   *  （按**绝对路径**取，绝不把 `<dir>/*` 通配放进 classpath——见 assembleRealTreeClasspath）；
   *  launchwrapper 形态还从这里取 **oshi 补丁件**（同样按绝对路径，不用通配）。 */
  classpathDir?: string;
  /** 沙箱可写运行目录（tmpdir/natives 解压；鸿蒙无 /tmp）。 */
  runDir?: string;
  /** el1 可 dlopen 的 native libs 目录（meowjre HSP libs：JRE .so + LWJGL/JNA 组件）。 */
  nativeLibsDir?: string;
  /** 自研桥 so 所在目录（当前与 nativeLibsDir 同：meowjre HSP libs）——JVM 侧
   *  System.loadLibrary 也需能在该目录找到 libmeowcraftbridge.so。 */
  craftLibsDir?: string;
  /** 窗口尺寸（glfwstub 用）。 */
  width?: number;
  height?: number;
  /** 实例身份（versions 目录名，见 VersionScanner.GameVersion.id）；空 = 退回 json 的 id。
   *  `${version_name}` 用它，保证与目录名一致。 */
  versionId?: string;
  /** 启动器 home 目录（meow-home）：运行数据所在。默认 gameRoot 父目录；
   *  建议传 filesDir 下沙箱目录，避免外部目录写权限问题（账户自立门户）。
   *  注：目录已 meow 化（原 launcher-home）；`-DMEOWCRAFT_HOME` 属性同步它（历史 launcher 的键名，
   *  保留以不改动手册/夹具）。 */
  meowHomeDir?: string;
  /** CPU 线程数覆盖（-XX:ActiveProcessorCount）；0/未设 = 自动（不传，JVM 探测）。 */
  activeProcessorCount?: number;
  /** 最大堆 MB（-Xmx）；0/未设 = 自动（不传，JVM 默认）。 */
  maxHeapMb?: number;
  /** 离线玩家名；空 = 用 LaunchDefaults.OFFLINE_USERNAME。 */
  playerName?: string;
  /** 账户 UUID（game 参数由 ArkTS 组 ⇒ 必须传真值）。 */
  authUuid?: string;
  /** 账户 accessToken（同上）。 */
  authAccessToken?: string;
  /** XSTS user hash（`--xuid`；同上）。 */
  authXuid?: string;
  /** 设备 CPU 芯片型号（ArkTS deviceInfo.chipType）；空 = 不传。 */
  cpuChip?: string;
  /** 渲染后端库名（按 MC 版本选，见 RendererPolicy）；空 = 默认桌面 GL（RENDERER_LIB）。
   *  必须与 GameLauncher 传给 startJvm 的 rendererLib 一致（meowjrebridge 启动前会自检）。 */
  rendererLib?: string;
  /** MC 的 `--graphicsBackend`（如 `vulkan`）。见下方 argv 处的注释。 */
  graphicsBackend?: string;
  /** 额外 JVM 参数（实验/调优）：空格/换行分隔，原样追加（放在固定参数之前，允许被覆盖）。 */
  jvmArgs?: string;
  /** 随包 JRE 里 `jdk.zipfs` 补丁目录（`<jreHome>/lib/patch/jdk.zipfs`）。非空 = 给 JVM 加
   *  `--patch-module jdk.zipfs=<dir>`：用 JDK 官方机制**只覆盖那一个类**（`ZipFileSystem.sync()`
   *  的 chmod 变 best-effort，规避手机用户存储(FUSE) 拒绝 chmod 导致 Fabric 首次 remap 崩），
   *  **不动 `lib/modules`(jimage) / `jmods` / 模块哈希**。目录不存在时调用方须传空（否则 JVM
   *  初始化即 `patch module ... does not exist` 失败）。 */
  zipfsPatchDir?: string;
  /** 本次启动所用**随包 JRE 的主版本**（Java major，如 26 / 8；= `JavaRuntime.javaMajor`，
   *  由 `GameLauncher` 从已解析的 `JavaChoice` 传入）。用于「随包 ASM 覆盖」判定
   *  （见 `needsAsmOverride`：声明 ASM 能否读**当前 JRE** 的 class 文件）。0/未设 = 不判定、不替换。 */
  jreMajor?: number;
}

/**
 * 组装启动 argv（不含 argv[0]）。
 * classpath 三种形态（按**主类/启动形态**分流，判据见 needsRealClasspath / isLaunchWrapperMain）：
 * ① **真 maven 树**（Forge ≥1.13 / NeoForge）：逐条绝对路径 + 实例 jar —— 必需，见
 *    REAL_CLASSPATH_MAIN_CLASSES（FML 按 ASM jar 的祖先目录反推 maven 根）；
 * ② **有序绝对路径**（launchwrapper 形态：≤1.12.2 Forge / LiteLoader / 独立 OptiFine）：同样是
 *    「清单顺序逐条绝对路径 + 实例 jar」，但**不含**随包 LWJGL3（改用 MC 的 LWJGL2），并按 HMCL 口径
 *    把 OptiFine 排到最后、丢掉它的 launchwrapper fork —— 见 assembleRealTreeClasspath /
 *    launchWrapperOptifineOrder。**为什么不用通配**见那条注释（它就是本次 TRSRTransformation 事故的根因）；
 * ③ **平铺 `<dir>/*`**（原版/Fabric）：超长 -cp 在本 JLI 移植会失效，故 jar 平铺后用通配传入。
 */
export function buildLaunchArgv(opts: LaunchOptions): string[] {
  // 归一版本清单：展开 inheritsFrom 继承链 / HMCL patches[]（见 VersionResolver）。
  const resolved = resolveVersion(opts.gameRoot, opts.jsonPath);
  if (resolved === null) {
    return [];
  }
  const json = resolved.json;
  // 实例身份 = versions 目录名（opts.versionId，对齐 HMCL）；无则退回 json 的 id。
  const id = (opts.versionId !== undefined && opts.versionId.length > 0)
    ? opts.versionId : (json.id ?? '');
  if (id.length === 0) {
    return [];
  }
  // 运行目录（游戏数据落点）：版本隔离时 = versions/<id>，否则 = .minecraft 根。
  const gameDir = (opts.gameDir !== undefined && opts.gameDir.length > 0)
    ? opts.gameDir
    : opts.gameRoot;
  // 「该有效版本要不要**真 maven 树** classpath」的**单一判据**（按启动形态判，不按 loader 名 /
  // 版本号；见 needsRealClasspath 与 REAL_CLASSPATH_MAIN_CLASSES 的机制说明）。
  const realTreeClasspath = needsRealClasspath(resolved);
  // 「要不要给 launchwrapper 形态也走**显式有序绝对路径**」的判据（**按主类形态**，不写死版本号）：
  // ≤1.12.2 的 Forge / LiteLoader / 独立 OptiFine 主类都是 `net.minecraft.launchwrapper.Launch`。
  // 为什么必须（2026-10-01 事故定案）：平铺 `<dir>/*` 的展开顺序 = 文件系统 `readdir`（JDK 8 的
  // `FileList_expandWildcards` 逐条目原地插入，**无排序语义**）⇒ OptiFine jar 里那份 920 B 的
  // `TRSRTransformation` 空壳可能先于 Forge 本体命中 ⇒ `IModel.getDefaultState()` 调 `identity()`
  // 抛 `NoSuchMethodError`（取证见 stuffs/research/launchwrapper-study/TRSR-crash-forensics.md）。
  // 换回"清单顺序"后 `net.minecraftforge:forge` 恒在 OptiFine 之前（HMCL 同口径），同名类归属**确定**。
  const launchWrapperClasspath = isLaunchWrapperMain(json.mainClass);
  // ── 随包 ASM 覆盖（方案 A「随包」）──
  // 判定见 needsAsmOverride（ModLauncher ≥10 且声明 ASM 读不懂当前 JRE 的 class 文件）；
  // 落位 = 实例 staging 平铺目录下的**子目录**（ASM_STAGE_SUBDIR，**不平铺**，避免混进
  // 平铺形态的 `-cp "<dir>/*"` 通配）。找不到随包目录/件时**保持原样**（不假装成功）并打 warn。
  const jreMajor = (opts.jreMajor !== undefined && opts.jreMajor > 0) ? opts.jreMajor : 0;
  const asmDir = (opts.classpathDir !== undefined && opts.classpathDir.length > 0)
    ? `${opts.classpathDir}/${ASM_STAGE_SUBDIR}` : '';
  const asmOverrideWanted = needsAsmOverride(resolved, jreMajor);
  const asmOverride = asmOverrideWanted && asmBundleComplete(asmDir);
  if (asmOverrideWanted && !asmOverride) {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'bundled ASM missing/incomplete at %{public}s -> keeping declared ASM (expect'
      + ' "Unsupported class file major version %{public}d" on this JRE)',
      asmDir.length > 0 ? asmDir : '(no staged dir)', jreMajor + CLASS_MAJOR_OFFSET);
  }
  // **主类分叉已取消（2026-10-01 方案 A：MeowLauncher 退役）**：所有形态一律直启 `json.mainClass`，
  // 且**不设** `-Djava.system.class.loader`。这里保留"为什么"的定案，防止将来又把它请回来：
  //  · **launchwrapper 系（legacy ≤1.12.2 的 Forge / LiteLoader / OptiFine）**：`net.minecraft.launchwrapper.Launch`
  //    的私有构造里有 `(URLClassLoader) getClassLoader()` 强转。我们只在 **Java 8 档**跑这类实例
  //    （见 JavaPolicy），而 JDK 8 的 app classloader（`sun.misc.Launcher$AppClassLoader`）**本身就是
  //    `URLClassLoader` 子类** ⇒ 强转原生成立，**不需要**换系统 CL。历史上"换系统 CL（MeowClassLoader）
  //    + 把启动器族摘出平铺"这一对**只是为现代 JRE（JDK 9+ 的 `AppClassLoader extends BuiltinClassLoader`）
  //    **服务；既然已定口径"老 Forge 只走 Java 8 档"，整套机制不再需要
  //    （研究档 `stuffs/research/launchwrapper-study/REPORT.md` §2/§2.4）。
  //  · `LaunchClassLoader` 的委派父指向"定义 `Launch` 的那个 CL"（= app CL）⇒ tweaker 实现类与
  //    `net.minecraft.launchwrapper.ITweaker` 同源 ⇒ **单一平铺 CL 下无 CCE / 无 CNFE**（同报告 §2.2）。
  //  · **vanilla**：历史上走 MeowLauncher 只为运行期 `addURL`；`ClasspathStager` 已把全部 jar 平铺 ⇒
  //    平铺 classpath 自足、该职责空转 ⇒ 直启 `net.minecraft.client.main.Main`（2026-10-01 摘除）。
  //  · **Forge ≥1.13 / NeoForge**（加载器直启形态，真 maven 树 classpath）：必须直启其 `mainClass`
  //    （Java 9+ 模块系统下从无名模块反射调"有模块"的主类会被 `IllegalAccessException` 拒；2026-09-30 取证）
  //    ⇒ 与"一律直启"同口径。
  // ⇒ 主类恒 = `json.mainClass`；game 参数恒由本函数 `collectGameArgs`（launchwrapper 系另加 tweak
  //    顺序修复，见 reorderLaunchWrapperTweaks）拼出。
  // classpath：
  // - 真 maven 树（`realTreeClasspath`）：**必须**是「真库树逐条绝对路径 + 实例 jar」——Forge ≥1.13 的 FML
  //   用 ASM jar 的祖先目录反推 maven 根，平铺通配必然把路径基算错 ⇒ `Missing forge!`
  //   （机制见 REAL_CLASSPATH_MAIN_CLASSES）；NeoForge 的 `-p` / `-DignoreList` / `-DmergeModules`
  //   同样依赖真实布局。随包 LWJGL3 jar 另从平铺目录按**绝对路径**补进来——**绝不用** `<dir>/*`
  //   （否则 ASM 可能先命中平铺那份，病根照旧）。
  // - launchwrapper 形态（≤1.12.2 Forge / LiteLoader / 独立 OptiFine）：**同样不用通配**，走
  //   「清单顺序逐条绝对路径 + 实例 jar」（与旧 `MeowClassLoader` / HMCL 的 `${classpath}` 同口径）。
  //   不复用平铺的原因 = 通配没有顺序语义（TRSRTransformation 事故根因）；OptiFine 排位见
  //   launchWrapperOptifineOrder。注意它**不含**随包 LWJGL3（用 MC 的 LWJGL2）。
  // - 原版/Fabric：平铺 `<dir>/*`（规避超长 -cp），沿用既有行为。
  const rawClasspath = (realTreeClasspath || launchWrapperClasspath)
    ? assembleRealTreeClasspath(opts.gameRoot, resolved, id,
        opts.classpathDir !== undefined ? opts.classpathDir : '', opts.jsonPath,
        realTreeClasspath, launchWrapperClasspath)
    : ((opts.classpath !== undefined && opts.classpath.length > 0)
      ? opts.classpath
      : assembleClasspath(opts.gameRoot, json, id));
  // ASM 覆盖：**替换面覆盖 `-cp`**（`-p` 见下方 jvm 参数循环）。只在判据命中且随包件齐时改：
  // `-cp` 里的 ASM 条目（=`collectFromJson` 收的真树件）换成随包件的**绝对路径**，其余 `org/ow2/asm/*` 剔除。
  const classpath = asmOverride ? rewriteAsmList(rawClasspath, asmDir) : rawClasspath;
  // classpath 形态自证（稳定英文诊断串）：排查"这类实例为什么起不来"时先看这一行。
  // real-tree = 真库树逐条绝对路径（Forge ≥1.13 / NeoForge）；ordered = launchwrapper 形态的
  // **显式有序绝对路径**（≤1.12.2 Forge；本次 TRSRTransformation 事故的修法，**不再是通配**）；
  // flat = 平铺目录通配（原版/Fabric）。entries = `:` 分隔的条目数。
  // bytes = classpath 串的 **UTF-8 字节数**（对齐 argv 长度上限口径；用 util.TextEncoder 精确取，
  // 非 UTF-16 字符数 —— 游戏根路径可能含非 ASCII 中文目录名）。
  const cpEntries = classpath.length === 0 ? 0 : classpath.split(':').length;
  const cpBytes = classpath.length === 0 ? 0 : new util.TextEncoder().encodeInto(classpath).byteLength;
  if (realTreeClasspath) {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'classpath mode=' + CLASSPATH_MODE_REAL_TREE + ' (entries=%{public}d, bytes=%{public}d)',
      cpEntries, cpBytes);
    logAsmProvider(classpath, opts.gameRoot, asmOverride);
  } else if (launchWrapperClasspath) {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'classpath mode=' + CLASSPATH_MODE_ORDERED + ' (entries=%{public}d, bytes=%{public}d)',
      cpEntries, cpBytes);
    // 同名类多提供者体检（F3）：本次事故"下次一眼可见"的保障，只对已知敏感类做定点检查。
    logDuplicateClassProviders(classpath, DUPLICATE_CLASS_WATCHLIST);
  } else {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'classpath mode=' + CLASSPATH_MODE_FLAT);
  }
  // ASM 覆盖自证（稳定英文诊断串）：换了哪几件、指向哪个目录、丢掉了哪套声明版本。
  if (asmOverride) {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'asm override: bundled ASM %{public}s (5 jars) staged at %{public}s; dropped declared'
      + ' modlauncher=%{public}s asm=%{public}s (jre=%{public}d -> class major %{public}d);'
      + ' -cp and -p rewritten',
      ASM_BUNDLED_VERSION, asmDir, declaredModLauncherVersion(resolved.json) ?? '(none)',
      declaredAsmVersion(resolved.json) ?? '(none)', jreMajor, jreMajor + CLASS_MAJOR_OFFSET);
  } else if (realTreeClasspath && !asmOverrideWanted) {
    // 不替换的自证（只在真树形态打，平铺形态不刷屏）。
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'asm override: not needed (modlauncher=%{public}s asm=%{public}s jre=%{public}d)',
      declaredModLauncherVersion(resolved.json) ?? '(none)',
      declaredAsmVersion(resolved.json) ?? '(none)', jreMajor);
  }
  // natives 目录：JNA/LWJGL native 解压目标（runDir 沙箱内可写优先）。
  const nativesDir = (opts.runDir !== undefined && opts.runDir.length > 0)
    ? `${opts.runDir}/${NATIVES_DIR}`
    : `${opts.gameRoot}/versions/${id}-${NATIVES_DIR}`;
  // version json 的 ${natives_directory} 宏会进 -Djava.library.path（JVM 参数最后覆盖我们前面
  // 设的 java.library.path）。必须指向 el1（含全部 musl .so），否则 LWJGL loadLibrary("lwjgl")
  // 在空 natives 目录找不到 → UnsatisfiedLinkError。JNA 解压(tmpdir)仍用 runDir/natives。
  const nativeMacroDir = (opts.nativeLibsDir !== undefined && opts.nativeLibsDir.length > 0)
    ? opts.nativeLibsDir
    : nativesDir;
  const player = (opts.playerName !== undefined && opts.playerName.length > 0)
    ? opts.playerName : OFFLINE_USERNAME;
  const macros = makeMacros(gameDir, opts.gameRoot, id, json, classpath,
    nativeMacroDir, player,
    opts.authUuid !== undefined ? opts.authUuid : '',
    opts.authAccessToken !== undefined ? opts.authAccessToken : '',
    opts.authXuid !== undefined ? opts.authXuid : '');
  const argv: string[] = [];

  // 固定 JVM 参数：平台伪装成 Linux —— MC/oshi/LWJGL 检测 os.name，HarmonyOS 会被拒绝。
  argv.push(`-Dos.name=${SPOOF_OS_NAME}`);
  argv.push(`-Dos.version=${SPOOF_OS_VERSION}`);
  // 设备真实 CPU 芯片型号（ArkTS deviceInfo.chipType 读入；鸿蒙沙箱读不到 /proc/cpuinfo）。
  if (opts.cpuChip !== undefined && opts.cpuChip.length > 0) {
    argv.push(`-Dmeow.cpu.chip=${opts.cpuChip}`);
  }
  // 额外 JVM 参数（高级选项/实验）：空格/换行分隔，原样追加（放固定参数之前，允许被后续覆盖）。
  if (opts.jvmArgs !== undefined && opts.jvmArgs.length > 0) {
    const extraArgs = opts.jvmArgs.split('\n').join(' ').split(' ').filter((s: string) => s.length > 0);
    for (const a of extraArgs) {
      argv.push(a);
    }
  }
  // 最大堆覆盖（高级选项）；0/未设 = 不传，用 JVM 默认。
  if (opts.maxHeapMb !== undefined && opts.maxHeapMb > 0) {
    argv.push(`-Xmx${opts.maxHeapMb}m`);
  }
  // user.dir = 运行目录：game 参数 `${game_directory}` 宏由它派生 → MC 的 --gameDir
  // （存档/选项/日志/资源包落点），log4j 相对路径也随它。
  // "版本隔离"开关的唯一作用点就是这里；user.home 保持 .minecraft 根（不参与隔离）。
  argv.push('-Duser.dir=' + gameDir);
  argv.push('-Duser.home=' + opts.gameRoot);
  // jdk.zipfs 补丁（best-effort chmod）：用 JDK 官方 `--patch-module` 只覆盖那一个类，
  // 不动 lib/modules(jimage)/jmods/模块哈希。仅当随包 JRE 带了该目录时才加（见 GameLauncher 的存在性检查）。
  if (opts.zipfsPatchDir !== undefined && opts.zipfsPatchDir.length > 0) {
    argv.push('--patch-module');
    argv.push(`jdk.zipfs=${opts.zipfsPatchDir}`);
  }
  if (opts.runDir !== undefined && opts.runDir.length > 0) {
    argv.push(`-Djava.io.tmpdir=${opts.runDir}`);
    argv.push(`-Djna.tmpdir=${nativesDir}`);
  }
  // el1 可 dlopen 区放 native .so：LWJGL/JNA 组件在 JRE 模块（meowjre），自研桥
  // (meowcraftbridge) 在 meowcraftlib；java.library.path 两者都要（meowcraftbridge 在前）。
  if (opts.nativeLibsDir !== undefined && opts.nativeLibsDir.length > 0) {
    const craft = opts.craftLibsDir !== undefined && opts.craftLibsDir.length > 0
      ? `${opts.craftLibsDir}:` : '';
    argv.push(`-Djna.boot.library.path=${opts.nativeLibsDir}`);
    argv.push(`-Dorg.lwjgl.librarypath=${opts.nativeLibsDir}`);
    argv.push(`-Djava.library.path=${craft}${opts.nativeLibsDir}:${nativesDir}`);
    // freetype 由随包 libfreetype.so 提供（自编，来自 meowlwjgls HAR；libfontmanager 硬依赖，勿改名覆盖）。
  }

  // 自研桥模式固定参数（与历史启动器 JVMLauncher overridableArguments 全量对齐——LWJGL 桥需要）。
  // **加载器直启形态**（Forge ≥1.13 / NeoForge）同样需要（LWJGL/随包 native/平台伪装都在这一段）。
  // 注：这一段**不再设** `-Djava.system.class.loader`（MeowLauncher/MeowClassLoader 已退役，2026-10-01）：
  //  各形态一律直启其 `mainClass`、classpath 平铺/真树自足 ⇒ 设它只会让 JVM 启动期
  //  `Class.forName` 直接 ClassNotFound。Fabric 同理（Knot 要求 loader 类由父加载器持有）。
  // **本段无条件执行**（原 `if (opts.meowcraftLaunch === true || neoForge)` 守卫已随 `meowcraftLaunch`
  //  恒真钩子一并删除，2026-10-01 —— 它从未起过筛选作用；各形态都需要这一段）。
  // 渲染后端按 MC 版本选（见 RendererPolicy）：≥1.17 → 桌面 GL libGLv4.so(Zink)；
  // ≤1.16 → gl4es(libgl4es.so，GLES 上的固定管线翻译)。必须与 startJvm 传的 rendererLib 一致；
  // glfwstub 不自建 EGL，交给渲染后端（桥按 MEOWCRAFT_RENDERER 决定 GL/GLES）。
  const rendererLib = (opts.rendererLib !== undefined && opts.rendererLib.length > 0)
    ? opts.rendererLib : RENDERER_LIB;
  argv.push(`-Dorg.lwjgl.opengl.libname=${rendererLib}`);
  // LWJGL 世代命名：世代号紧跟基名（`liblwjgl_<digits>[_opengl|_stb].so`，如 liblwjgl_343.so），与随包
  // 扁平目录里的多代共存；启动一律设 mapper + 世代号，交给 MeowBundledNameMapper 选名。
  const lwjglGen = lwjglGeneration(opts.jsonPath);
  argv.push(`-Dorg.lwjgl.system.bundledLibrary.nameMapper=${LWJGL_NAME_MAPPER}`);
  argv.push(`-Dmeow.lwjgl.gen=${lwjglGen}`);
  argv.push('-Dorg.lwjgl.system.allocator=system');
  argv.push('-Dorg.lwjgl.glfw.checkThread0=false');
  // 【F75 env-cleanup】`-Dorg.lwjgl.vulkan.libname` 就是"选哪个 Vulkan 后端"的参数：选 Vulkan
  // （opts.graphicsBackend 非空）→ 指向自研 shim（libmeowvulkan.so，随包 native；修正本机 ICD 的
  // "上报面裁剪"并翻译提交与 WSI，见 meowvulkan.c 头注释）；否则 → 指向不存在的占位库
  // （libmeow-no-vulkan.so），让 LWJGL 的 Vulkan 探测直接失败、跳过 Vulkan 组。
  // 不再需要任何 env；shim 一经加载即默认挂钩（逃生口 = 用户 env 里写 `MEOW_VK_SHIM=0`）。
  // 回退阶梯见方案文 §7.5 / §13。
  const vulkanLibName = (opts.graphicsBackend !== undefined && opts.graphicsBackend.length > 0)
    ? VULKAN_LIB_SHIM : VULKAN_LIB_DISABLED;
  argv.push(`-Dorg.lwjgl.vulkan.libname=${vulkanLibName}`);
  argv.push('-DDEBUG=true');
  argv.push(`-Dcpu.name=${SPOOF_CPU_NAME}`);
  argv.push(`-Dnet.minecraft.clientmodname=${CLIENT_MOD_NAME}`);
  argv.push('-Dfml.earlyprogresswindow=false');
  argv.push('-Dloader.disable_forked_guis=true');
  argv.push('-Dsodium.checks.issue2561=false');
  argv.push('-Djdk.lang.Process.launchMechanism=FORK');
  argv.push('-Dglfwstub.initEgl=false');
  const w = opts.width ?? WINDOW_DEFAULT_W;
  const h = opts.height ?? WINDOW_DEFAULT_H;
  argv.push(`-Dglfwstub.windowWidth=${w}`);
  argv.push(`-Dglfwstub.windowHeight=${h}`);
  argv.push(`-Dmeowcraft.path.minecraft=${opts.gameRoot}`);
  // 目录模型：MEOWCRAFT_HOME=homeDir（运行数据 home），MEOWCRAFT_GAME_DIR=.minecraft。
  // 传 filesDir 下沙箱目录最稳（外部目录可能不可写）；缺省时退回游戏根。
  const homeDir = opts.meowHomeDir !== undefined && opts.meowHomeDir.length > 0
    ? opts.meowHomeDir
    : opts.gameRoot;
  argv.push(`-DMEOWCRAFT_HOME=${homeDir}`);
  argv.push(`-DMEOWCRAFT_GAME_DIR=${opts.gameRoot}`);
  argv.push('-Djna.nosys=false');
  argv.push('-Doshi.util.disable.cpufrequency=true');
  argv.push('-Doshi.util.disable.powersource=true');
  // CPU 线程数覆盖（高级选项）；0/未设 = 不传，由 JVM 自动探测（sysconf）。
  if (opts.activeProcessorCount !== undefined && opts.activeProcessorCount > 0) {
    argv.push(`-XX:ActiveProcessorCount=${opts.activeProcessorCount}`);
  }
  // 崩喷落点统一到实例的 `.hmmcraft/logs`：`-XX:ErrorFile` 是**产品**参数（可直接用），
  // JVM 的 hs_err 默认落 cwd（= 游戏目录）⇒ 指到这里。沿用本文件「用户额外参数优先」的约定：
  // 用户自己给了 `-XX:ErrorFile` 就不覆盖。
  // ⚠️ 这里**不要**加 `-XX:LogFile=`：它是**诊断**参数，未开 `-XX:+UnlockDiagnosticVMOptions`
  //    会让 JVM 直接拒启（2026-09-16 实测："VM option 'LogFile' is diagnostic …" → 启动失败，
  //    且**没有** hs_err、MC 的 latest.log 也不更新）。需要 Log* 时由用户自己在额外参数里连 unlock 一起给。
  const userArgs = opts.jvmArgs !== undefined ? opts.jvmArgs : '';
  if (opts.logsDir !== undefined && opts.logsDir.length > 0 && !/-\s*XX:ErrorFile\s*=/.test(userArgs)) {
    argv.push(`-XX:ErrorFile=${opts.logsDir}/hs_err_pid%p.log`);
  }
  argv.push(`-Duser.language=${LOCALE_LANGUAGE}`);
  argv.push(`-Duser.country=${LOCALE_COUNTRY}`);
  argv.push(`-Duser.timezone=${LOCALE_TIMEZONE}`);
  argv.push('-Dlog4j2.formatMsgNoLookups=true');
  // Tools.getMinecraftArgs 会读 Server_Ip 属性并 isBlank() 判空（历史启动器 JVMLauncher 同款）；
  // 缺属性则 getProperty 返回 null → NPE。空值可安全走"无服务器直连"分支。
  argv.push('-DServer_Ip=');
  // LWJGL 调试开关：**默认不设（= 关）**。`org.lwjgl.util.Debug=true` 会开启 LWJGL 的
  // "额外运行期检查（部分很贵）"并刷诊断输出（LWJGL 源码 Configuration.DEBUG 原文）；
  // `DebugLoader` 依附于它；`org.lwjgl.opengl.Debug` 根本不是 LWJGL 属性（core/opengl 源码零命中，
  // MC json 也不设）→ 历史死旗标，已一并移除。排障/A-B 时用高级选项「额外 JVM 参数」加
  // `-Dorg.lwjgl.util.Debug=true` 即可覆盖（额外参数排在固定参数之前，不会被覆盖）。
  // legacy 也必须保持关：LWJGL2 的 LWJGLUtil.DEBUG 门控 Display.swapBuffers 的"交换前 glGetError
  // 检查"，会把 gl4es 的良性 GL 错误变成致命 OpenGLException（实测 `Invalid operation (1282)`）。
  const legacyLwjgl = isLegacyLwjgl(opts.jsonPath);
  if (legacyLwjgl) {
    // LWJGL2 的全屏尺寸来自"应用选定的 DisplayMode"（createWindow 里 window_width=mode.width；
    // 且全屏时 LWJGL2 主动抑制 resize 通知：Display.java `window_resized = !isFullscreen() && …`）。
    // 故把真实屏幕尺寸告诉 native，让它作为 fullscreen-capable 模式上报，否则 MC 全屏后视口
    // 仍是窗口尺寸（画面停在左下角）。
    try {
      // 优先用"窗口所在显示器"尺寸（副屏场景）；没有则退回默认显示器。
      let dw = windowDisplayW;
      let dh = windowDisplayH;
      if (!(dw > 0 && dh > 0)) {
        const d = display.getDefaultDisplaySync();
        dw = d.width;
        dh = d.height;
      }
      if (dw > 0 && dh > 0) {
        argv.push(`-Dmeow.screen.w=${dw}`);
        argv.push(`-Dmeow.screen.h=${dh}`);
      }
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'screen size query failed: %{public}s', JSON.stringify(e));
    }
  }

  // JVM 参数（规则过滤 + 宏替换；含 -cp ${classpath} → 真实 cp）。
  // legacy（≤1.12.2）用 minecraftArguments、没有 arguments.jvm，所以这里不会带出 -cp —— 必须补上，
  // 否则 classpath 缺失 → 主类/库加载失败（表现=秒崩）。
  let hasClasspathArg = false;
  // `-p` 的**下一项**是 module path 串：ASM 覆盖时把它一并改写（见 rewriteAsmList —— ②代 ASM 正是
  // 经 `-p` + `--add-modules ALL-MODULE-PATH` 加载，只改 `-cp` 会留旧件、甚至造成同模块两份）。
  let rewriteNextAsModulePath = false;
  // 与 game 参数循环**有意不同**：这里**丢弃"展开后为空"的 token**。
  //  依据（逐处说明）：json 的 `arguments.jvm` 全是**自足单 token**（`-cp ${classpath}` / `-p ${module_path}` /
  //  `-Dfoo=${bar}` / `--add-opens …`），`${…}` 均**恒非空**（classpath / module path / 各 -D 值都不会是空串）
  //  ⇒ "展开为空"只可能是规则过滤或异常清单，此时把空串推进 JVM 选项区反而会被 JVM 当非法选项。
  //  这段是 ArkTS 侧新写的 JVM argv（**不**来自已删除的 Java `ArgBuilder`——它只管 game 参数），故不适用
  //  game 那段"空串照发"的口径。
  for (const raw of collectArgs(json.arguments?.jvm)) {
    let v = expand(raw, macros);
    if (rewriteNextAsModulePath) {
      v = asmOverride ? rewriteAsmList(v, asmDir) : v;
      rewriteNextAsModulePath = false;
    }
    if (v.length > 0) {
      argv.push(v);
      if (v === '-cp' || v === '-classpath') {
        hasClasspathArg = true;
      } else if (v === '-p' || v === '--module-path') {
        rewriteNextAsModulePath = true;
      }
    }
  }
  if (!hasClasspathArg && classpath.length > 0) {
    argv.push('-cp');
    argv.push(classpath);
  }
  // 版本 json 的 jvm 参数会把 java.library.path / jna.tmpdir / LWJGL 提取目录 / netty 工作目录
  // 指向 ${natives_directory}（26.2 更细到 ${natives_directory}/{java,jna,lwjgl,netty}），且排在
  // 我们参数之后 → 覆盖生效。而我们的 ${natives_directory} 为让 native 能从 el1 加载必须指只读的
  // 随包签名区 → 26.2 新增 NativeLibrariesBootstrap 在这些目录上 createDirectories 会 AccessDenied
  // （只读区也不允许写入）。故在 json 参数之后统一覆盖为可写 runDir/natives；
  // native 仍按名从 el1 加载（org.lwjgl.librarypath + MeowBundledNameMapper），仅工作目录落沙箱。
  if (opts.runDir !== undefined && opts.runDir.length > 0) {
    if (opts.nativeLibsDir !== undefined && opts.nativeLibsDir.length > 0) {
      const craftLibs = opts.craftLibsDir !== undefined && opts.craftLibsDir.length > 0
        ? `${opts.craftLibsDir}:` : '';
      argv.push(`-Djava.library.path=${craftLibs}${opts.nativeLibsDir}:${nativesDir}`);
    }
    argv.push(`-Djna.tmpdir=${nativesDir}`);
    argv.push(`-Dorg.lwjgl.system.SharedLibraryExtractPath=${nativesDir}`);
    argv.push(`-Dio.netty.native.workdir=${nativesDir}`);
  }
  // 主类与后续参数（**统一路径**，2026-10-01 起不再分叉）：
  // 直接以 `json.mainClass` 启动（`net.minecraft.client.main.Main` / KnotClient / launchwrapper 的
  // `net.minecraft.launchwrapper.Launch` / modlauncher.Launcher / BootstrapLauncher / ForgeBootstrap /
  // fml.startup.Client …），并由本函数补齐 game 参数（账户 / `--launchTarget` / `--fml.*` 等）。
  // launchwrapper 系另做一遍 tweak 顺序修复（照抄 HMCL 的确定性规则，见 reorderLaunchWrapperTweaks）。
  const mainClass = json.mainClass ?? '';
  if (mainClass.length > 0) {
    argv.push(mainClass);
  }
  // 游戏参数：`collectGameArgs` 出原始 token（可能同时来自 minecraftArguments 与 arguments.game），
  // launchwrapper 系先按 HMCL 规则重排 tweak，再统一做宏替换后追加。
  let gameArgs = collectGameArgs(json);
  if (isLaunchWrapperMain(mainClass)) {
    gameArgs = reorderLaunchWrapperTweaks(gameArgs, resolved, json);
  }
  // 空串**照发**（与已删除的 Java 侧 `ArgBuilder.build` 同口径）：旧实现（= 已删的 Java `ArgBuilder.build`）只跳过"**展开前**即为空"的原始
  // token，**展开后**为空的照 push。`${clientid}` / `${auth_xuid}` 在未配置 / 离线时展开为空串；若在此
  // 丢弃，`--clientId` / `--xuid` 就会把**下一个 flag** 吃成自己的值（标志与值错位，2026-10-01 修正）。
  for (const raw of gameArgs) {
    if (raw.length === 0) {
      continue;
    }
    argv.push(expand(raw, macros));
  }
  // MC 的 `--graphicsBackend` 是**游戏参数**，必须在主类之后（之前误放进 JVM 的 -D 区，JVM 会当作自己的
  // 选项而拒绝启动）。所有形态的 game 参数都由本函数补齐（2026-10-01 起无 Java 侧转发）。
  // MC 默认 GL 优先（见方案文 §5.5），只有它才会去试 Vulkan；
  // 候选列表是 {VulkanBackend, GlBackend}，Vulkan 失败仍回退 GL（安全垫）。回退阶梯见 §7.5。
  if (opts.graphicsBackend !== undefined && opts.graphicsBackend.length > 0) {
    argv.push('--graphicsBackend', opts.graphicsBackend);
  }
  return argv;
}

/**
 * 读取**解析后的真 MC 版本号**（如 "1.16.5"），渲染后端/LWJGL 世代判定用。
 * 注意：不是 json 内部 `id` —— Fabric 实例的 `id` 形如 `fabric-loader-0.15.11-1.20.1`，
 * 真版本号在继承链根 / `game` 补丁里（见 ./VersionResolver）。失败/缺省返回 ''。
 */
export function readVersionId(jsonPath: string): string {
  const resolved = resolveVersionByPath(jsonPath);
  return resolved === null ? '' : resolved.mcVersion;
}

/** 宏表：值由 json + 离线约定决定。gameDir = 运行目录（隔离时 = versions/<id>），
 *  gameRoot = .minecraft 根（只有 assets 从它派生，保证资源池始终共享）。 */
function makeMacros(gameDir: string, gameRoot: string, id: string, json: VersionJson,
  classpath: string, nativesDir: string, player: string, authUuid: string,
  authAccessToken: string, authXuid: string): LaunchMacros {
  const m: LaunchMacros = new Map<string, string>();
  m.set('auth_player_name', player);
  m.set('version_name', id);
  // `version_type` 取清单声明的 `type`（旧 Java `ArgBuilder` 同源；缺省 release）。纯装饰性：
  // MC 不据此做分支，仅进 F3/日志。
  m.set('version_type', (json.type !== undefined && json.type.length > 0) ? json.type : 'release');
  m.set('game_directory', gameDir);
  m.set('assets_root', `${gameRoot}/assets`);
  // `assets_index_name` 优先取清单的 `assets` 字段、再退 `assetIndex.id`（旧 Java `ArgBuilder` 同序；
  // 1.6.x 及更早只用 `assets`）。
  m.set('assets_index_name', assetIndexName(json));
  // `auth_uuid` **去横线**（32 位紧凑形式）——旧 Java `ArgBuilder.stripDashes` 与 HMCL 的
  // `UUIDs.toCompactString` 都如此，且 HMCL 对**所有**版本（含 1.20.x）都发紧凑形式 ⇒ 统一去横线。
  m.set('auth_uuid', authUuid.split('-').join(''));
  // `auth_access_token` 与 `auth_session` 同义、**同口径**：离线（`authAccessToken` 为空）时退回
  // `OFFLINE_TOKEN`（= 旧 Java `Account.OFFLINE_ACCESS_TOKEN='0'`：原版只要求非空、不校验值）。
  // 离线仍发 `'0'`（而非空串）—— 与 `auth_session` 一致，且避免 `--accessToken` 后接空值。
  m.set('auth_access_token', authAccessToken.length > 0 ? authAccessToken : OFFLINE_TOKEN);
  // legacy（≤1.12.2）清单要用的三个宏 —— 旧 Java 侧 `ArgBuilder` 有、ArkTS 侧原先缺（本函数原先只服务
  // 直启形态：Fabric / Forge ≥1.13 / NeoForge，它们的现代清单不用这三个）。legacy 也从本函数走后
  // **必须补齐**，否则会把 `${...}` 字面量原样发给 MC：
  //  - `1.6.4`：`--username ${auth_player_name} --session ${auth_session} --version … --gameDir …
  //    --assetsDir ${game_assets}`（用 `auth_session` / `game_assets`）；
  //  - `1.7.10` / `1.8.9`：`… --userProperties ${user_properties} --userType ${user_type}`
  //    （MC 把 `--userProperties` 的值当 JSON 解析 ⇒ 必须给 `{}`）。
  //  取值与旧 `ArgBuilder.build` 同义：`auth_session` = accessToken（离线无 token 时退回 `OFFLINE_TOKEN`）；
  //  `game_assets` = `<gameRoot>/assets`（与 `assets_root` 同源）；`user_properties` = `{}`。
  m.set('auth_session', authAccessToken.length > 0 ? authAccessToken : OFFLINE_TOKEN);
  m.set('game_assets', `${gameRoot}/assets`);
  m.set('user_properties', '{}');
  m.set('classpath', classpath);
  m.set('natives_directory', nativesDir);
  // NeoForge（FML）清单里的占位符：模块路径 / 库目录 / 主 jar（`-DignoreList` 要用）。
  m.set('library_directory', `${gameRoot}/libraries`);
  m.set('classpath_separator', ':');
  m.set('file_separator', '/');
  m.set('primary_jar', `${gameRoot}/versions/${id}/${id}.jar`);
  m.set('primary_jar_name', `${id}.jar`);
  m.set('launcher_name', LAUNCHER_NAME);
  m.set('launcher_version', LAUNCHER_VERSION);
  // 现代清单（≥1.14）的三个账户相关宏（`--clientId` / `--xuid` / `--userType`）——取值对齐旧 Java
  // `Account` + `ArgBuilder`（本机无 `clientToken` 来源，且旧 `Account` 对离线把 `clientToken`/`xuid`
  // 皆归一为空串）：
  //  · `clientid`：**恒空串**（离线 / 正版一致；我们不发 client token）。
  //  · `auth_xuid`：正版 = XSTS user hash（`Account.xuid`）；离线 = 空串。
  //  · `user_type`：**恒 `'msa'`**（HMCL 对离线也发 msa；`'mojang'` 联机可能被判无效会话）。
  // 空串在 argv 里**照发**（见上方 game 参数循环）⇒ `--clientId` / `--xuid` 后面始终有一个值。
  m.set('clientid', '');
  m.set('auth_xuid', authXuid);
  m.set('user_type', 'msa');
  return m;
}

/** 收集 arguments 数组（规则过滤后展开字符串）。 */
function collectArgs(args?: Array<string | VersionRuleArg>): string[] {
  const out: string[] = [];
  for (const a of args ?? []) {
    if (typeof a === 'string') {
      out.push(a);
    } else if (ruleAllows(a.rules)) {
      if (typeof a.value === 'string') {
        out.push(a.value);
      } else if (Array.isArray(a.value)) {
        for (const v of a.value) {
          out.push(v);
        }
      }
    }
  }
  return out;
}

/** 清单的 asset index 名：优先 `assets` 字段、再退 `assetIndex.id`（旧 Java `ArgBuilder` 同序）。 */
function assetIndexName(json: VersionJson): string {
  const a = json.assets;
  if (a !== undefined && a.length > 0) {
    return a;
  }
  return json.assetIndex?.id ?? '';
}

/**
 * 游戏参数原始 token（宏替换前）。
 *
 * 形态对齐 HMCL `GameInstanceLibraryBuilder`：
 * - `minecraftArguments`（单串，按**空白**切）与 `arguments.game`（数组）**各存一份**；
 * - 若存在 `minecraftArguments`，官方启动器会**忽略** `arguments`，HMCL 于是把 `game` 追加进 mcArgs
 *   （`build()` 的实现）⇒ 本函数同样返回 `mcArgs + game`。**必需**：HMCL 补丁式（patches[]）的
 *   Forge+OptiFine 实例里，`--tweakClass FMLTweaker` 在 `minecraftArguments`、`--tweakClass
 *   optifine.OptiFineTweaker` 在 `arguments.game`，只取其一都会丢 tweak。
 * - 只有 `arguments.game`（现代清单）⇒ 直接用 game 数组。
 */
function collectGameArgs(json: VersionJson): string[] {
  const legacy = json.minecraftArguments ?? '';
  const mcArgs: string[] = legacy.length > 0
    ? legacy.split(/\s+/).filter((s: string) => s.length > 0)
    : [];
  const game: string[] = json.arguments?.game !== undefined ? collectArgs(json.arguments.game) : [];
  if (mcArgs.length > 0) {
    return mcArgs.concat(game);
  }
  return game;
}

// ───────────────────── launchwrapper tweak 顺序修复（照抄 HMCL 的确定性规则） ─────────────────────
// 为什么需要：装上 Forge 常会**整段替换**游戏的参数表（如 Forge 安装器/补丁写自己的
// `minecraftArguments`），把 LiteLoader / OptiFine 的 `--tweakClass` 挤掉或打乱顺序。launchwrapper 对
// tweak 的**加载顺序敏感**（后者可覆盖前者的 transformer 注册），故必须在启动前把顺序修成确定性形式。
//
// 规则来源（逐条照抄 `ref/HMCL`，勿凭理解改写）：
//  · `org.jackhuang.hmcl.game.LaunchManifestNormalizer.repairLaunchWrapper()`（三段：LiteLoader → OptiFine
//    → Forge，每段以"先删净、再前插"处理，故**净效果头部 = Forge → OptiFine → LiteLoader**）；
//  · `org.jackhuang.hmcl.game.GameInstanceLibraryBuilder.replaceTweakClass(target, replacement, false, true)`
//    （`reorderTweakClass=true` ⇒ `inPlace=false, reserve=true`：删掉**所有** `--tweakClass <target>` 相邻
//    对；若 replacement 非空则把 `--tweakClass <replacement>` 前插到**最前**）；
//  · `org.jackhuang.hmcl.game.GameComponentAnalyzer`（组件识别：补丁 id 优先、其次库坐标）；
//  · 主类常量 `GameComponentAnalyzer.{LAUNCH_WRAPPER_MAIN, MOD_LAUNCHER_MAIN}`。
//
// 触发面：仅 **launchwrapper 主类**（`net.minecraft.launchwrapper.Launch`，≤1.12.2 的 Forge/LiteLoader/
// OptiFine）。**Forge 的 tweaker 缺失时不补**（HMCL 只对已存在的 Forge tweaker 重排；LiteLoader/OptiFine
// 才在组件存在时"补一份"）。
/** launchwrapper 主类（tweak 顺序修复 + 显式有序 classpath 的触发判据）。 */
const LAUNCHWRAPPER_MAIN: string = 'net.minecraft.launchwrapper.Launch';

/**
 * 主类是否 launchwrapper 形态（≤1.12.2 的 Forge / LiteLoader / 独立 OptiFine）。
 * 判据按**主类（形态）**而非 MC 版本号 / loader 名：薄 `inheritsFrom`、被人工改写的清单、
 * 独立 OptiFine 等都能稳定命中。用于挑「显式有序 classpath」与 tweak 顺序修复。
 *
 * **导出**：staging 侧（`ClasspathStager.classpathUsesWildcard`）的形态分流与这里**共用同一判据**
 * ⇒ 两处不可能分歧（此前 staging 侧另存了一份主类字面量，需人工同步）。
 */
export function isLaunchWrapperMain(main: string | undefined): boolean {
  return main === LAUNCHWRAPPER_MAIN;
}
/** Forge 的 tweaker（1.5.2 的 LibraryFixer / 1.7.10 的 cpw.mods / 1.8+ 的 net.minecraftforge）。
 *  迭代顺序同 HMCL；每命中即"删净 + 前插"，只有**已存在**的那个会被重排（缺失不补）。 */
const FORGE_TWEAKERS: string[] = [
  'net.minecraftforge.legacy._1_5_2.LibraryFixerTweaker',
  'cpw.mods.fml.common.launcher.FMLTweaker',
  'net.minecraftforge.fml.common.launcher.FMLTweaker',
];
/** OptiFine 的两种 tweaker：`[0]` = 独立版，`[1]` = 与 Forge 同用版。 */
const OPTIFINE_TWEAKER_PLAIN: string = 'optifine.OptiFineTweaker';
const OPTIFINE_TWEAKER_FORGE: string = 'optifine.OptiFineForgeTweaker';
/** LiteLoader 的 tweaker。 */
const LITELOADER_TWEAKER: string = 'com.mumfrey.liteloader.launch.LiteLoaderTweaker';

/** 参数表里是否存在 `--tweakClass <t>` 相邻对（等价 HMCL `hasTweakClass`）。 */
function hasTweak(args: string[], t: string): boolean {
  for (let i = 0; i + 1 < args.length; i++) {
    if (args[i] === '--tweakClass' && args[i + 1] === t) {
      return true;
    }
  }
  return false;
}

/**
 * HMCL `replaceTweakClass(target, replacement, inPlace=false, reserve=true)` 的等价实现：
 * 删净**所有** `--tweakClass <target>` 相邻对；`replacement` 非空则把 `--tweakClass <replacement>`
 * **前插到最前**（`replacement=null` 即 HMCL 的 `removeTweakClass`）。
 */
function reorderTweak(args: string[], target: string, replacement: string | null): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (i + 1 < args.length && args[i] === '--tweakClass' && args[i + 1] === target) {
      i++;   // 丢掉这一对
      continue;
    }
    out.push(args[i]);
  }
  if (replacement !== null) {
    out.unshift(replacement);
    out.unshift('--tweakClass');
  }
  return out;
}

/** 库表里是否存在某 `group:artifact` 前缀的条目（组件识别用；对齐 HMCL GameComponentAnalyzer）。 */
function hasLibraryPrefix(json: VersionJson, prefix: string): boolean {
  for (const lib of json.libraries ?? []) {
    if ((lib.name ?? '').startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

/**
 * 按 HMCL `repairLaunchWrapper` 的三段规则重排 launchwrapper 系的 `--tweakClass`，净效果头部 =
 * **Forge → OptiFine → LiteLoader**。`resolved` 用于 Forge 组件识别（= `detectLoader` 的结论；
 * 解析后的有效清单里 `patches[]` 已折叠掉，故组件识别只能用**库表 + loader**）。
 *
 * HMCL 里 `hasForgeModLauncher()` 的两个分支（把主类提升为 ModLauncher / 删 OptiFine tweaker）**不会**
 * 到达：本函数只在主类 = launchwrapper `Launch` 时被调用，而 Forge-ModLauncher 形态的主类是
 * `cpw.mods.modlauncher.Launcher`（见 needsRealClasspath / REAL_CLASSPATH_MAIN_CLASSES）⇒ 已排除。
 */
function reorderLaunchWrapperTweaks(args: string[], resolved: ResolvedVersion,
  json: VersionJson): string[] {
  const hasLiteLoader = hasLibraryPrefix(json, 'com.mumfrey:liteloader');
  const hasOptiFine = hasLibraryPrefix(json, 'optifine:OptiFine');
  const hasForge = resolved.loader === LOADER_FORGE;
  let out = args;
  // ① LiteLoader：有组件则"删净 + 前插一份"，否则清掉不该有的。
  if (hasLiteLoader) {
    out = reorderTweak(out, LITELOADER_TWEAKER, LITELOADER_TWEAKER);
  } else {
    out = reorderTweak(out, LITELOADER_TWEAKER, null);
  }
  // ② OptiFine：独立版用 OptiFineTweaker；与 Forge（或 LiteLoader）同用时换成 OptiFineForgeTweaker。
  if (hasOptiFine) {
    if (!hasLiteLoader && !hasForge) {
      // 独立 OptiFine：若误带 Forge 版 tweaker，换回独立版。
      if (hasTweak(out, OPTIFINE_TWEAKER_FORGE)) {
        out = reorderTweak(out, OPTIFINE_TWEAKER_FORGE, OPTIFINE_TWEAKER_PLAIN);
      }
    } else if (hasTweak(out, OPTIFINE_TWEAKER_PLAIN)) {
      out = reorderTweak(out, OPTIFINE_TWEAKER_PLAIN, OPTIFINE_TWEAKER_FORGE);
    }
  } else {
    out = reorderTweak(out, OPTIFINE_TWEAKER_PLAIN, null);
    out = reorderTweak(out, OPTIFINE_TWEAKER_FORGE, null);
  }
  // ③ Forge：无组件则清掉；有组件且该 tweaker **已存在**才重排（缺失不补，这是 HMCL 的刻意行为）。
  for (const t of FORGE_TWEAKERS) {
    if (!hasForge) {
      out = reorderTweak(out, t, null);
    } else if (hasTweak(out, t)) {
      out = reorderTweak(out, t, t);
    }
  }
  return out;
}

/** 宏替换：仅 ${name} 形式。 */
function expand(raw: string, macros: LaunchMacros): string {
  let out = raw;
  macros.forEach((v: string, k: string) => {
    out = out.split(`\${${k}}`).join(v);
  });
  return out;
}

/**
 * 由 maven 描述符 `group:artifact:version[:classifier][@ext]` 推本地 maven 相对路径
 * （对齐 Java 侧 LibraryResolver.artifactPath）。Fabric loader 库常只给 `name`+`url`、
 * 无 `downloads.artifact.path`，需此回退才能进 classpath。
 */
function mavenPathFromName(name: string): string {
  const at = name.indexOf('@');
  const ext = at >= 0 ? name.substring(at + 1) : 'jar';
  const base = at >= 0 ? name.substring(0, at) : name;
  const parts = base.split(':');
  if (parts.length < 3) {
    return '';
  }
  const group = parts[0].replace(/\./g, '/');
  const artifact = parts[1];
  const version = parts[2];
  const classifier = parts.length >= 4 ? `-${parts[3]}` : '';
  return `${group}/${artifact}/${version}/${artifact}-${version}${classifier}.${ext}`;
}

/** 从已解析 json 收集本规则+存在的 jar（库 + 版本 jar）。
 *  org.lwjgl.* 排除：LWJGL 全家由 clean-room 合并 jar 替代（鸿蒙 musl .so + glfw 桥）。 */
function collectFromJson(gameRoot: string, json: VersionJson, versionId: string): string[] {
  const parts: string[] = [];
  const libRoot = `${gameRoot}/libraries/`;
  for (const lib of json.libraries ?? []) {
    if (!ruleAllows(lib.rules)) {
      continue;
    }
    let rel = lib.downloads?.artifact?.path ?? '';
    if (rel.length === 0) {
      rel = mavenPathFromName(lib.name ?? '');
    }
    if (rel.startsWith('org/lwjgl/')) {
      // LWJGL3（`org/lwjgl/lwjgl/<ver>/…`）由 clean-room 合并 jar 替代 → 跳过。
      // LWJGL2（legacy ≤1.12.2）的 core/util（`org/lwjgl/lwjgl/lwjgl|_util/<ver>/…`）必须随包进
      // classpath —— MC 1.7–1.12 直接调 `org.lwjgl.opengl.Display` / `Keyboard` / `Mouse`。
      // （natives 走 `-natives-*` 条目，不在 classpath；其平台实现另需自研桥。）
      const isLwjgl2Core = rel.startsWith('org/lwjgl/lwjgl/lwjgl/')
        || rel.startsWith('org/lwjgl/lwjgl/lwjgl_util/');
      if (!isLwjgl2Core) {
        continue;
      }
    }
    if (rel.length > 0 && fileExists(`${libRoot}${rel}`)) {
      parts.push(`${libRoot}${rel}`);
    }
  }
  // 版本 jar 路径用实例身份（目录名），缺省退回 json id。
  const id = versionId.length > 0 ? versionId : (json.id ?? '');
  const verJar = `${gameRoot}/versions/${id}/${id}.jar`;
  if (fileExists(verJar)) {
    parts.push(verJar);
  }
  return parts;
}

/**
 * 该有效版本是否需要**真 maven 树 classpath**（逐条绝对路径 + 实例 jar），而不是平铺 `<dir>/*`。
 *
 * 判据按**启动形态（主类）**优先，不按 loader 名 / MC 版本号字符串比较（机制与取证见
 * [`REAL_CLASSPATH_MAIN_CLASSES`](../constants/LaunchContract.ets)）：
 * - Forge ≥1.13 三代主类命中 → 真；其中 `BootstrapLauncher` 同时覆盖 NeoForge（现状）。
 * - 兜底再认 `loader === neoforge`：NeoForge 的 classpath 形态属"现状不得改动"，将来它若换主类名
 *   （NeoForge 版本演进很快）也必须仍走真树，不能掉回平铺。
 * - legacy（launchwrapper）/ Fabric / vanilla → 假：既有平铺路径与自补 `-cp` 一律不动。
 */
function needsRealClasspath(resolved: ResolvedVersion): boolean {
  const main = resolved.json.mainClass ?? '';
  for (const c of REAL_CLASSPATH_MAIN_CLASSES) {
    if (main === c) {
      return true;
    }
  }
  return resolved.loader === LOADER_NEO_FORGE;
}

/**
 * 类路径条目名是否为 **ASM 核心 jar**（`asm-<版本>.jar`；`asm-9.6.jar` / `asm-9.9.1.jar`）。
 *
 * 必须与同前缀的 `asm-commons` / `asm-tree` / `asm-util` / `asm-analysis` 区分开：FML 找的是
 * `org/objectweb/asm/Opcodes.class` 的**提供者**，只有核心 jar 里有它；那几个兄弟 jar 同在前缀、
 * 文件名也以 `asm-` 开头，用 `startsWith('asm-')` 之类的判据会误判。故用**全名**锚定
 * `asm-` + 数字开头 + 只含数字与点 + `.jar`。
 */
function isAsmCoreJarFileName(name: string): boolean {
  return /^asm-\d[\d.]*\.jar$/.test(name);
}

// ───────────────────────── 随包 ASM 覆盖（方案 A「随包」） ─────────────────────────
// 背景（2026-09-30 定案）：Forge 1.19.4 在随包 JRE 26 上启动失败 ——
//   `Unsupported class file major version 70`（`org.objectweb.asm@9.7.1 ClassReader.<init>`）
//   ← `modlauncher 10.0.8 ClassTransformer.transform → computeHierarchyFromFile`
// 即 Forge 1.19.4 **声明的 ASM 9.7.1 读不懂 JDK 26 的类文件（major 70）**。
// 1.17.1（ASM 9.1）/1.18.2 /1.16.5 /1.20.1（ASM 9.9.1）均已实测可启动 ⇒ **不新增 JRE 档**，
// 改为在启动期为需要的实例把 ASM 指向**随包的 9.9.1**（落在 staging 子目录，见 ASM_STAGE_SUBDIR）。

/** ASM 版本 → 它能读的最高 **class 文件 major**（能力表）；递增排列，查表取"≤ 声明版本 的最大一条"。 */
interface AsmClassMajor {
  ver: string;
  maxMajor: number;
}

/**
 * ASM 能力表（class 文件 major；Java major + 44 = class major，Java 8→52 … Java 26→70）。
 * 9.6→66（Java 22）/ 9.7→67（23）/ **9.7.1→68（24）** / 9.8→69（25）/ **9.9→70（26）**。
 *
 * 分界依据（本机实测）：Forge 1.18.2 声明 ASM **9.7.1**（能力 68）在 JDK 26 上**正常**，
 * 而 Forge 1.19.4 声明**同样的 9.7.1** 却失败 ⇒ 分界**不在 ASM 版本算术**，而在"读 JDK 类文件"
 * 这件事的**组件版本**：1.18.2 是 modlauncher **9.1.3**、1.19.4 是 modlauncher **10.0.8**
 * （`ClassTransformer.transform → computeHierarchyFromFile` 这条路径在 ≥10 才去读 JDK 自己的类文件）。
 * ⇒ 判据 = **ModLauncher ≥ 10 且声明 ASM 覆盖不了当前 JRE 的 class 文件版本**（见 needsAsmOverride）。
 */
const ASM_CLASS_MAJOR_TABLE: AsmClassMajor[] = [
  { ver: '9.0', maxMajor: 60 },    // Java 16
  { ver: '9.1', maxMajor: 61 },    // Java 17
  { ver: '9.2', maxMajor: 62 },    // Java 18
  { ver: '9.3', maxMajor: 63 },    // Java 19
  { ver: '9.4', maxMajor: 64 },    // Java 20
  { ver: '9.5', maxMajor: 65 },    // Java 21
  { ver: '9.6', maxMajor: 66 },    // Java 22
  { ver: '9.7', maxMajor: 67 },    // Java 23
  { ver: '9.7.1', maxMajor: 68 },  // Java 24
  { ver: '9.8', maxMajor: 69 },    // Java 25
  { ver: '9.9', maxMajor: 70 },    // Java 26
  { ver: '9.9.1', maxMajor: 70 },  // Java 26（当前随包件 = ASM_BUNDLED_VERSION）
];

/** class 文件 major = Java major + 44（Java 1.1 起固定；8→52 … 26→70）。 */
const CLASS_MAJOR_OFFSET: number = 44;

/** 点分版本 → 数值段；先剥 `@ext` 后缀。认不出（空/非数字）返回 null。 */
function parseDottedVersion(v: string): number[] | null {
  const at = v.indexOf('@');
  const core = (at >= 0 ? v.substring(0, at) : v).trim();
  if (!/^\d+(\.\d+)*$/.test(core)) {
    return null;
  }
  const out: number[] = [];
  for (const s of core.split('.')) {
    out.push(parseInt(s));
  }
  return out;
}

/** 点分版本字典序比较（缺段补 0）：a<b → -1，a==b → 0，a>b → 1；认不出 → 0。 */
function compareDottedVersion(a: string, b: string): number {
  const pa = parseDottedVersion(a);
  const pb = parseDottedVersion(b);
  if (pa === null || pb === null) {
    return 0;
  }
  const n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const x = i < pa.length ? pa[i] : 0;
    const y = i < pb.length ? pb[i] : 0;
    if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

/** 声明 ASM 版本能读的最高 class major（查 ASM_CLASS_MAJOR_TABLE）。0 = 比表内任何一条都老/认不出。 */
function asmMaxClassMajor(asmVer: string): number {
  let out = 0;
  for (const e of ASM_CLASS_MAJOR_TABLE) {
    if (compareDottedVersion(e.ver, asmVer) <= 0) {
      out = e.maxMajor;
    }
  }
  return out;
}

/** 取任意 `…:<artifact>:<ver>` 的声明版本；无则 null（版本串原样返回，比较时再剥 `@ext`）。 */
function declaredLibraryVersion(json: VersionJson, artifact: string): string | null {
  for (const lib of json.libraries ?? []) {
    const parts = (lib.name ?? '').split(':');
    if (parts.length >= 3 && parts[1] === artifact) {
      return parts[2];
    }
  }
  return null;
}

/** `org.ow2.asm:asm:<ver>` 的声明版本（`Opcodes` 的提供者）；无则 null。 */
function declaredAsmVersion(json: VersionJson): string | null {
  return declaredLibraryVersion(json, 'asm');
}

/** 判据①的取值：ModLauncher 版本。两代 group 都要认（`cpw.mods:modlauncher` /
 *  `net.minecraftforge:modlauncher`）；无则 null。 */
function declaredModLauncherVersion(json: VersionJson): string | null {
  return declaredLibraryVersion(json, 'modlauncher');
}

/** 该实例是否 NeoForge（结构判据：`loader === neoforge` 或出现 `net.neoforged.*` 库）。 */
function looksLikeNeoForge(resolved: ResolvedVersion): boolean {
  if (resolved.loader === LOADER_NEO_FORGE) {
    return true;
  }
  for (const lib of resolved.json.libraries ?? []) {
    if ((lib.name ?? '').startsWith('net.neoforged.')) {
      return true;
    }
  }
  return false;
}

/**
 * 是否需要把 ASM 指向随包件（两条判据都成立）：
 *  ① **ModLauncher ≥ 10** —— 只有 ≥10 的 `ClassTransformer.transform → computeHierarchyFromFile`
 *     才去读 **JDK 自己的类文件**（major = 当前 JRE 的 class 版本）；
 *  ② **实例声明的 ASM 覆盖不了当前 JRE 的 class 文件版本**（能力表 = ASM_CLASS_MAJOR_TABLE）。
 *
 * 与本机实测一致（`jreMajor` = 选中随包套的主版本；现代套 26 ⇒ class major 70）：
 *  - 1.16.5：ML 8.1.3（且 JavaPolicy 判给 Java 8 套）⇒ ① 不成立 ⇒ **不触发** ✓
 *  - 1.17.1：ML 9.0.7 ⇒ ① 不成立 ⇒ **不触发** ✓（即便其 ASM 9.1 能力仅 61）
 *  - 1.18.2：ML 9.1.3 ⇒ ① 不成立 ⇒ **不触发** ✓（其声明 9.7.1 与 1.19.4 同版却正常，正是这条分界）
 *  - 1.19.4：ML 10.0.8 且 ASM 9.7.1（68 < 70）⇒ **触发** ✓
 *  - 1.20.1：ML 10.0.9 但 ASM 9.9.1（70 ≥ 70）⇒ ② 不成立 ⇒ **不触发** ✓
 *
 * **NeoForge 一律不触发**（`looksLikeNeoForge`）：① 其 `-DignoreList` 用**带版本的文件名**点名 ASM
 * （`asm-9.5.jar,…`，bootstraplauncher 按子串匹配）⇒ 改名会**静默脱靶**；② NeoForge 侧不在本方案
 * 范围（只动 Forge ≥1.13 的必要实例）。它若真在 JDK 26 上撞同一面，修法必须**同时**改 `-DignoreList`
 * ——那是另一个改动面，不在本次。
 */
function needsAsmOverride(resolved: ResolvedVersion, jreMajor: number): boolean {
  if (jreMajor <= 0) {
    return false;   // 未传当前 JRE ⇒ 不判定（绝不瞎替换）
  }
  if (looksLikeNeoForge(resolved)) {
    return false;
  }
  const ml = declaredModLauncherVersion(resolved.json);
  if (ml === null || compareDottedVersion(ml, '10') < 0) {
    return false;   // ① 未声明 / < 10 ⇒ 不读 JDK 类文件
  }
  const asm = declaredAsmVersion(resolved.json);
  if (asm === null) {
    return false;   // 未声明 ASM：没有"被替换的那套"，不动
  }
  return asmMaxClassMajor(asm) < jreMajor + CLASS_MAJOR_OFFSET;   // ②
}

/** 随包 ASM 5 件是否都在（在 = 可安全替换；缺 = 保持原样，绝不假装成功）。 */
function asmBundleComplete(asmDir: string): boolean {
  if (asmDir.length === 0) {
    return false;
  }
  for (const n of EXPECTED_ASM_JARS) {
    if (!fileExists(`${asmDir}/${n}`)) {
      return false;
    }
  }
  return true;
}

/** 从 ASM 条目文件名取 artifact（`asm-9.7.1.jar`→`asm`；`asm-commons-9.7.1.jar`→`asm-commons`）；
 *  非随包的 5 件之一（异形件如 `asm-all` / `asm-debug-all`）返回 ''。 */
function asmArtifactOf(fileName: string): string {
  const m: RegExpMatchArray | null = fileName.match(/^(asm(?:-[a-z]+)?)-\d[\d.]*\.jar$/);
  if (m === null) {
    return '';
  }
  const artifact = m[1];
  return EXPECTED_ASM_JARS.includes(`${artifact}-${ASM_BUNDLED_VERSION}.jar`) ? artifact : '';
}

/**
 * 把一条 `:` 分隔的 classpath / **module path** 串里的旧 ASM 条目换成随包件（或剔除）。
 *
 * 替换面必须**同时**覆盖 `-cp` 与 `-p`：Forge ≥1.13 的 ASM 经 `-p` + `--add-modules
 * ALL-MODULE-PATH` 加载，但 `-cp` 里也有一份（`collectFromJson` 收真树里声明的 ASM）
 * ⇒ 只改一处会留旧件、甚至造成同模块两份。本函数对**任一** ASM 条目：
 *  - 落在随包 5 件里 → 换成 `<asmDir>/<artifact>-<随包版本>.jar`（**按绝对路径**引用子目录）；
 *  - 其余 `org/ow2/asm/*`（异形/旧代） → **剔除**（保证"同组件旧版本条目在任何列表里都不出现"）。
 * 保序 + 按绝对路径去重。`asmDir` 为空 = 拿不到随包目录 ⇒ 调用方保持原样（见 buildLaunchArgv 告警）。
 */
function rewriteAsmList(list: string, asmDir: string): string {
  if (asmDir.length === 0 || list.length === 0) {
    return list;
  }
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const one of list.split(':')) {
    if (one.length === 0) {
      continue;
    }
    if (!one.includes('/org/ow2/asm/')) {
      if (!seen.has(one)) {
        seen.add(one);
        out.push(one);
      }
      continue;
    }
    const fname = one.substring(one.lastIndexOf('/') + 1);
    const artifact = asmArtifactOf(fname);
    if (artifact.length === 0) {
      continue;   // 不认识的 ASM 件：剔除，绝不残留
    }
    const repl = `${asmDir}/${artifact}-${ASM_BUNDLED_VERSION}.jar`;
    if (!seen.has(repl)) {
      seen.add(repl);
      out.push(repl);
    }
  }
  return out.join(':');
}

/**
 * 真树 classpath 的 **ASM 自证**（只打日志、不改任何行为）。
 *
 * 验收所依赖的唯一不变量：Forge ≤1.16.x 的 FML 用 `getResource("org/objectweb/asm/Opcodes.class")`
 * 取到的那个 jar 的路径**上溯 6 级**当 `libraries` 根（见 `REAL_CLASSPATH_MAIN_CLASSES`）⇒ classpath
 * 里**第一个**能提供 `Opcodes.class` 的条目（= `getResource` 的首命中，按 classpath 顺序）必须是真树里的
 * `<gameRoot>/libraries/org/ow2/asm/<artifact>/<ver>/`。这条不变量以前没有可观测落点（只打了条目数），
 * 一旦将来被平铺具名件或新加条目破坏，现象又是 `Missing forge!` 而看不出原因 —— 故在这里落成一行日志。
 */
function logAsmProvider(classpath: string, gameRoot: string, asmOverridden: boolean): void {
  const libPrefix = `${gameRoot}/libraries/org/ow2/asm/`;
  let first = '';
  for (const one of classpath.split(':')) {
    if (one.length > 0 && isAsmCoreJarFileName(one.substring(one.lastIndexOf('/') + 1))) {
      first = one;
      break;   // 只认第一个：`getResource` 就是按 classpath 顺序取首命中
    }
  }
  if (first.length === 0) {
    hilog.warn(LOG_DOMAIN, LOG_TAG,
      'classpath ' + CLASSPATH_MODE_REAL_TREE + ': asm=(none) (in-libraries=no) -> Forge <=1.16.x cannot locate its'
      + ' libraries root (Missing forge!)');
    return;
  }
  const inLibs = first.startsWith(libPrefix);
  hilog.info(LOG_DOMAIN, LOG_TAG,
    'classpath ' + CLASSPATH_MODE_REAL_TREE + ': asm=%{public}s (in-libraries=%{public}s)',
    first, inLibs ? 'yes' : 'no');
  if (!inLibs) {
    if (asmOverridden) {
      // 我们**主动**把 ASM 换成了随包件（见 needsAsmOverride）⇒ "不在真树里"是**预期**的，不是缺陷：
      // 该"上溯 6 级"不变量只服务 Forge ≤1.16.x（`cpw.mods.modlauncher.Launcher` 世代），而它天然
      // **不触发替换**（modlauncher < 10）⇒ 本行不适用于它，也不该报 `Missing forge!`。
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'classpath ' + CLASSPATH_MODE_REAL_TREE + ': asm provider is the bundled override (expected; the <=1.16.x Launcher-gen'
        + ' tree-relative invariant does not apply to this modlauncher generation)');
      return;
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG,
      'classpath ' + CLASSPATH_MODE_REAL_TREE + ': asm provider is NOT under %{public}s -> Forge <=1.16.x derives a wrong'
      + ' maven root (Missing forge!)', libPrefix);
  }
}

// ───────────── launchwrapper 形态的 OptiFine 排位（照抄 HMCL DefaultLauncher.getClasspath） ─────────────
/**
 * 把 launchwrapper 形态的**清单顺序**整理成"同名类赢家确定"的形态（对齐 HMCL
 * `DefaultLauncher.getClasspath()` 的 `processOptiFine` 分支）：
 *
 * HMCL 在「OptiFine 与 Forge 或 LiteLoader 共存」时做两件事：
 *  1. `optifine:launchwrapper-of` **整条丢掉**（原文 "Drop OptiFine's private launchwrapper;
 *     Forge/LiteLoader supply their own."）——它定义与 `net.minecraft:launchwrapper:1.12` **完全同名**
 *     的一组 `net.minecraft.launchwrapper.*`；留着会让"谁定义 `Launch` / `LaunchClassLoader`"不确定
 *     （本次事故的第二个冲突面：真正生效的 `Launch` 竟来自 `launchwrapper-of-2.2`，见
 *     `stuffs/research/launchwrapper-study/TRSR-crash-forensics.md` §3.3）。
 *  2. `optifine:OptiFine` 从原位**移到最末**（原文 "Re-append the installer last so OptiFine follows
 *     Forge"）——OptiFine 1.12.2 的 jar 里带着 10 个 `net.minecraftforge.**` 残件（含 920 B 的
 *     `TRSRTransformation` 空壳）；只有让 Forge 本体**先命中**，`IModel.getDefaultState()` 的
 *     `identity()` 才能解析到真身（22976 B / 65 方法）。
 *
 * ⇒ 顺序来源仍是**清单顺序**（与旧 `MeowClassLoader` / HMCL 同口径），只在两类件上做上述整理；
 *    **不是**改回通配，故不依赖任何文件系统枚举顺序。就地改写 `parts`（保序去重由调用方紧随其后）。
 *
 * ⚠️ **本判据的前提 = "Forge/LiteLoader 与 OptiFine 共存"**（丢 `launchwrapper-of` 的理由正是
 *    "Forge/LiteLoader supply their own"）**；独立 OptiFine（无 Forge、无 LiteLoader）不在支持范围**：
 *    此时 OptiFine 的 `optifine:launchwrapper-of` 很可能是 classpath 上**唯一**的
 *    `net.minecraft.launchwrapper.Launch` 提供者，把它丢掉反而会让主类无处可寻。此前提由用户裁决
 *    （2026-10-01），**不改本逻辑**——真要为独立 OptiFine 兜底，须先有能力判定"谁是 Launch 的提供者"。
 */
function launchWrapperOptifineOrder(parts: string[], gameRoot: string, json: VersionJson): void {
  const libRoot = `${gameRoot}/libraries/`;
  const dropPaths = new Set<string>();   // optifine:launchwrapper-of*（整条丢）
  const lastPaths = new Set<string>();   // optifine:OptiFine*（移到最末）
  for (const lib of json.libraries ?? []) {
    if (!ruleAllows(lib.rules)) {
      continue;
    }
    const name = lib.name ?? '';
    const isLaunchWrapperOf = name === 'optifine:launchwrapper-of'
      || name.startsWith('optifine:launchwrapper-of:');
    const isOptiFine = name === 'optifine:OptiFine' || name.startsWith('optifine:OptiFine:');
    if (!isLaunchWrapperOf && !isOptiFine) {
      continue;
    }
    // 与 collectFromJson 同口径推路径（maven 相对路径 → 绝对路径），保证命中的正是 classpath 里那条。
    let rel = lib.downloads?.artifact?.path ?? '';
    if (rel.length === 0) {
      rel = mavenPathFromName(name);
    }
    if (rel.length === 0) {
      continue;
    }
    if (isLaunchWrapperOf) {
      dropPaths.add(`${libRoot}${rel}`);
    } else {
      lastPaths.add(`${libRoot}${rel}`);
    }
  }
  if (dropPaths.size === 0 && lastPaths.size === 0) {
    return;
  }
  const head: string[] = [];
  const tail: string[] = [];
  let dropped = 0;
  for (const one of parts) {
    if (dropPaths.has(one)) {
      dropped++;
      continue;
    }
    if (lastPaths.has(one)) {
      tail.push(one);
    } else {
      head.push(one);
    }
  }
  parts.length = 0;
  for (const one of head) {
    parts.push(one);
  }
  for (const one of tail) {
    parts.push(one);
  }
  if (dropped > 0 || tail.length > 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'classpath ' + CLASSPATH_MODE_ORDERED + ': optifine last (moved=%{public}d), dropped launchwrapper-of=%{public}d'
      + ' (HMCL getClasspath parity: keeps forge before optifine, Launch single-sourced)',
      tail.length, dropped);
  }
}

// ─────────────── 同名类多提供者体检（F3；launchwrapper 形态启动期一次，log-only） ───────────────
/** 体检的「已知敏感类」监视表（本次事故的两类；需要时可在此扩展）。 */
const DUPLICATE_CLASS_WATCHLIST: string[] = [
  'net/minecraftforge/common/model/TRSRTransformation.class',   // OptiFine 1.12.2 空壳 vs Forge 真身
  'net/minecraft/launchwrapper/Launch.class',                   // launchwrapper-1.12 vs launchwrapper-of
];
/** EOCD 搜索窗口 = 最大注释 64 KiB + 22 字节 EOCD（标准 ZIP）。 */
const ZIP_EOCD_SEARCH_BYTES: number = 65557;
/** 中央目录读取上限（防御损坏 / 异常大的 jar；超过则跳过该 jar）。 */
const ZIP_CENTRAL_DIR_MAX_BYTES: number = 4 * 1024 * 1024;

/** ZIP 小端 u16。 */
function leU16(b: Uint8Array, i: number): number {
  return b[i] | (b[i + 1] << 8);
}

/** ZIP 小端 u32（`>>> 0` 归一为非负）。 */
function leU32(b: Uint8Array, i: number): number {
  return (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
}

/**
 * 读出一个 jar 的**中央目录条目名**（只读中央目录，不解压、不读载荷）——仅供体检判断"谁提供这个类"。
 * 认不出（非标准 ZIP / zip64 / 读取失败）即返回空数组：best-effort，绝不抛、绝不影响启动。
 */
function jarEntryNames(path: string): string[] {
  const names: string[] = [];
  try {
    const size = fileIo.statSync(path).size;
    if (size <= 22) {
      return names;
    }
    const tailLen = Math.min(size, ZIP_EOCD_SEARCH_BYTES);
    const tail = new Uint8Array(tailLen);
    let count = 0;
    let cdSize = 0;
    let cdOff = 0;
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const n = fileIo.readSync(f.fd, tail.buffer, { offset: size - tailLen, length: tailLen });
      let eocd = -1;
      // 从后往前找 EOCD 签名 PK\x05\x06。
      for (let i = n - 22; i >= 0; i--) {
        if (tail[i] === 0x50 && tail[i + 1] === 0x4b && tail[i + 2] === 0x05 && tail[i + 3] === 0x06) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) {
        return names;
      }
      count = leU16(tail, eocd + 10);
      cdSize = leU32(tail, eocd + 12);
      cdOff = leU32(tail, eocd + 16);
    } finally {
      fileIo.closeSync(f);
    }
    if (count <= 0 || cdSize <= 0 || cdOff <= 0 || cdSize > ZIP_CENTRAL_DIR_MAX_BYTES) {
      return names;
    }
    const cd = new Uint8Array(cdSize);
    // **单次**读中央目录（每个 fd 只读一次：ReadOptions.offset 相对当前 filePointer，新开的 fd
    // filePointer=0 ⇒ offset 即绝对位置；不循环读以免语义歧义）。读不满则以实读长度收窄边界。
    const g = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    let got = 0;
    try {
      got = fileIo.readSync(g.fd, cd.buffer, { offset: cdOff, length: cdSize });
    } finally {
      fileIo.closeSync(g);
    }
    if (got < cdSize) {
      cdSize = got;
    }
    let p = 0;
    for (let k = 0; k < count; k++) {
      if (p + 46 > cdSize) {
        break;
      }
      // 中央目录条目签名 PK\x01\x02。
      if (!(cd[p] === 0x50 && cd[p + 1] === 0x4b && cd[p + 2] === 0x01 && cd[p + 3] === 0x02)) {
        break;
      }
      const nameLen = leU16(cd, p + 28);
      const extraLen = leU16(cd, p + 30);
      const commentLen = leU16(cd, p + 32);
      const start = p + 46;
      if (start + nameLen > cdSize) {
        break;
      }
      let s = '';
      for (let j = 0; j < nameLen; j++) {
        s += String.fromCharCode(cd[start + j]);
      }
      names.push(s);
      p = start + nameLen + extraLen + commentLen;
    }
  } catch (e) {
    // best-effort：任何异常都当"没读到"（纯诊断，绝不因它影响启动）。
  }
  return names;
}

/**
 * 同名类多提供者体检（F3）：扫一遍本次 classpath 各 jar 的中央目录，若某种**已知敏感类**被 ≥2 个
 * jar 提供就记一条稳定英文 warn（点名类名 + 各 jar 基名）。这是本次 `TRSRTransformation` / `Launch`
 * 事故"下次一眼可见"的保障 —— 若早有这行日志，现场直接就是
 * "TRSRTransformation provided by forge-….jar + OptiFine-….jar"。
 *
 * 取舍（成本/收益）：只做**定点**检查（DUPLICATE_CLASS_WATCHLIST）而非"全类名多提供者"扫描，
 * 以免逐 jar 建全量类名集合（内存 + 启动耗时）；逐 jar 也只读中央目录、不解压。**log-only**：
 * 从不改 classpath、从不中止启动，任何异常都被吞掉。
 *
 * 注意：Forge + OptiFine 实例**必然会**命中一条（两 jar 都提供 `TRSRTransformation`）——这是
 * "顺序决定胜负"的事实陈述，不是错误；与 `classpath mode=ordered` / `optifine last` 两行合看即可判位。
 */
function logDuplicateClassProviders(classpath: string, watch: string[]): void {
  if (classpath.length === 0 || watch.length === 0) {
    return;
  }
  const providers: Map<string, string[]> = new Map<string, string[]>();
  for (const one of classpath.split(':')) {
    if (one.length === 0 || !one.endsWith('.jar')) {
      continue;
    }
    const names = jarEntryNames(one);
    if (names.length === 0) {
      continue;
    }
    const base = one.substring(one.lastIndexOf('/') + 1);
    for (const cls of watch) {
      if (names.includes(cls)) {
        const arr = providers.get(cls);
        if (arr === undefined) {
          providers.set(cls, [base]);
        } else {
          arr.push(base);
        }
      }
    }
  }
  providers.forEach((arr: string[], cls: string) => {
    if (arr.length >= 2) {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'classpath duplicate class: %{public}s provided by %{public}s (first in classpath wins)',
        cls, arr.join(' + '));
    }
  });
}

/**
 * 「按清单顺序」组装显式 classpath：逐条绝对路径 + 实例 jar（对齐 HMCL 的 `${classpath}`）。
 *
 * **两个形态共用**：
 * - 真 maven 树（`needsRealClasspath`：Forge ≥1.13 / NeoForge）：它们**必须**能从 classpath 条目上
 *   看出真实 maven 布局（FML 按 ASM jar 的祖先目录反推 `libraries` 根，见 `REAL_CLASSPATH_MAIN_CLASSES`）
 *   ⇒ **平铺目录绝不能出现在这里**：只要平铺在，ASM 就可能先命中平铺那份，路径基又算错（`Missing forge!`）。
 *   是**替换**，不是追加。
 * - launchwrapper（`isLaunchWrapperMain`：≤1.12.2 Forge / LiteLoader / 独立 OptiFine）：这里**代替**
 *   平铺 `<dir>/*` 通配 —— 通配**没有顺序语义**（展开顺序 = 文件系统 `readdir`），本次事故里 OptiFine
 *   的空壳 `TRSRTransformation` 就是靠它抢在 Forge 本体之前命中，使 Forge 的 `IModel.getDefaultState()`
 *   调 `identity()` 抛 `NoSuchMethodError`。按清单顺序后同名类归属**确定**。
 *
 * `collectFromJson` 已按声明顺序收集「规则允许且本地存在」的库，并**跳过 MC 声明的 LWJGL3**
 * （`org/lwjgl/…`，由随包 clean-room 合并 jar 替代）——现代形态要的正是这个；launchwrapper 形态
 * 需要的是 MC 的 LWJGL2（`org/lwjgl/lwjgl/lwjgl|_util/<ver>/…`，`collectFromJson` 的 `isLwjgl2Core`
 * 已保留）⇒ 两形态在 LWJGL 上互不干扰。另外几类补充见函数体。
 *
 * @param includeBundledLwjgl3 是否从平铺目录按**绝对路径**补随包 LWJGL3（真树形态 = true；
 *   launchwrapper = false —— 它用 MC 的 LWJGL2，混入 LWJGL3 会因两者都定义 `org.lwjgl` 包而
 *   `sealing violation`）。
 * @param optifineLastForLaunchWrapper 是否按 HMCL `DefaultLauncher.getClasspath()` 把 OptiFine 排到最后
 *   并丢掉它的 launchwrapper fork（见 launchWrapperOptifineOrder）。
 */
function assembleRealTreeClasspath(gameRoot: string, resolved: ResolvedVersion, versionId: string,
  stagedDir: string, jsonPath: string, includeBundledLwjgl3: boolean,
  optifineLastForLaunchWrapper: boolean): string {
  const json = resolved.json;
  const parts = collectFromJson(gameRoot, json, versionId);
  // 继承式实例（官方 Forge 安装器布局）的客户端 jar 在**基座版本目录**，叶子目录常无 `<id>.jar`
  // ⇒ 按 `resolved.clientJarId` 补进 classpath（与 `collectJarSources` 同口径；HMCL 的 `${classpath}`
  // 同样含 client jar）。补丁式（HMCL）时 clientJarId == 实例 id ⇒ 已由 collectFromJson 加入，不重复。
  const baseId = resolved.clientJarId;
  if (baseId.length > 0 && baseId !== versionId) {
    const baseJar = `${gameRoot}/versions/${baseId}/${baseId}.jar`;
    if (fileExists(baseJar) && !parts.includes(baseJar)) {
      parts.push(baseJar);
    }
  }
  // 加载器 `-DmergeModules=` 点名的 jar 必须出现在 `java.class.path` 里（它按**文件名**查表做合并）；
  // 这些 jar（如 jna-5.10.0.jar）不在清单中，由安装期补下到 maven 树 → 这里按名解析后补进 classpath。
  const jvmArgs = collectArgs(json.arguments?.jvm);
  const libNames = libraryNames(json.libraries as object[] | undefined);
  for (const e of resolveMergeModuleEntries(jvmArgs, libNames)) {
    const p = `${gameRoot}/libraries/${e.relPath}`;
    if (fileExists(p)) {
      parts.push(p);
    } else {
      // 加载器 `-DmergeModules=` 点名的 jar 在真树里**不存在**（声明的版本与树里的不一致，如
      // 清单声明 jna-5.12.1 而加载器点名 jna-5.10.0.jar）。加载器按**文件名**查表合并，查不到就
      // 拿空集去 union → 启动期 `NoSuchFileException`/`Duplicate key` 之类难查的失败。必须告警别静默。
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'mergeModules: %{public}s declared by loader but absent from real tree (%{public}s);'
        + ' declared-vs-tree mismatch -> name lookup will fail', e.fileName, e.relPath);
    }
  }
  if (stagedDir.length > 0) {
    // (1) oshi 补丁版**前置**：真 maven 树里的 oshi 是上游原版，会去初始化 JNA（JNA 在 OHOS 上
    //     dlopen 自己解出来的 native 必失败 → NoClassDefFoundError，F3/SystemReport 报错）。
    //     平铺目录里那份是 ClasspathStager 覆盖过的补丁件（认 -Dmeow.cpu.chip），前置即可遮蔽。
    //     **launchwrapper 形态也走这一段**：legacy 的 oshi 是 `oshi-project:oshi-core`（经
    //     `OSH_CORE_PREFIXES` 命中，见 oshi-overrides/manifest.txt 的 `oshi-core-1.1.jar`），
    //     故 legacy 用的同样是**被替换后的补丁件**，不会退回上游版。
    const oshiBase = oshiJarBaseName(json);
    if (oshiBase.length > 0) {
      const patched = `${stagedDir}/${oshiBase}`;
      if (!fileExists(patched)) {
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'oshi override missing (%{public}s) -> upstream oshi kept (JNA noise expected)', oshiBase);
      }
      if (fileExists(patched)) {
        // **替换**而不是「前置」：真 maven 树里的同名 oshi 必须同时移出 classpath，
        // 否则同名两件同时在场（潜在模块/包冲突，靠先到先得侥幸）。
        const kept: string[] = [];
        for (const one of parts) {
          if (!one.endsWith(`/${oshiBase}`)) {
            kept.push(one);
          }
        }
        parts.length = 0;
        parts.push(patched);
        for (const one of kept) {
          parts.push(one);
        }
      }
    }
    // (2) 随包 LWJGL3 jar（collectFromJson 会跳过树里的 org.lwjgl3，由它提供）。**只在真树形态补**：
    //     launchwrapper 形态用 MC 自带的 LWJGL2（collectFromJson 已保留其 core/util），再混入 LWJGL3
    //     会因两者都定义 `org.lwjgl` 包而 `sealing violation`。
    if (includeBundledLwjgl3) {
      const genJar = `${LWJGL_JAR_PREFIX}${lwjglGeneration(jsonPath)}.jar`;
      const genPath = `${stagedDir}/${genJar}`;
      if (fileExists(genPath)) {
        parts.push(genPath);
      }
    }
  } else if (includeBundledLwjgl3) {
    // 真树形态（Forge ≥1.13 / NeoForge）本应从平铺目录取随包 LWJGL3 jar。stagedDir 为空 = 调用方没给
    // 平铺目录 ⇒ 该件按**绝对路径**补不进来：LWJGL3 缺失 ⇒ 加载器/游戏 `NoClassDefFoundError`。
    // 导出 API 的防御性可观测化（纯日志，不改行为）。
    hilog.warn(LOG_DOMAIN, LOG_TAG,
      CLASSPATH_MODE_REAL_TREE + ' classpath: stagedDir empty -> bundled LWJGL3 jar will NOT be added'
      + ' (expect NoClassDefFoundError)');
  }
  // launchwrapper 形态：按 HMCL `DefaultLauncher.getClasspath()` 重排 —— 把 OptiFine 排到最后、
  // 丢掉它的 launchwrapper fork（否则 Forge 本体会被 OptiFine 的同名空壳遮蔽 / `Launch` 来源不定）。
  if (optifineLastForLaunchWrapper) {
    launchWrapperOptifineOrder(parts, gameRoot, json);
  }
  // **按绝对路径去重**（保序）：NeoForge 清单与 vanilla 清单会声明**同一个库**
  // （guava/failureaccess、gson 等 FML 依赖与 MC 依赖重合）⇒ 同路径出现两次会让
  // bootstraplauncher 1.1.2 的合并阶段抛 `IllegalStateException: Duplicate key`
  // （2026-09-16 实测 1.20.2）。注意：**不能**按 artifact 名去重——BN 本来就是靠同名不同版本
  // 的 jar 合并成同一模块，按名去重会破坏它；只有完全相同的路径才该去掉。
  const unique: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const one of parts) {
    if (!seen.has(one)) {
      seen.add(one);
      unique.push(one);
    }
  }
  return unique.join(':');
}

/** 声明里的 oshi **核心** jar 文件名（如 `oshi-core-6.4.10.jar`）；无则空串。
 *  两个制品组都要认：`com.github.oshi:oshi-core`（MC ≥1.17）与 `oshi-project:oshi-core`（MC ≤1.16.x）。
 *  后者漏认会让 Forge 1.16.x 用上真树里那份**未打补丁**的 oshi（平铺模式下它是被覆盖过的）。 */
const OSHI_CORE_PREFIXES: string[] = ['com.github.oshi:oshi-core:', 'oshi-project:oshi-core:'];

function oshiJarBaseName(json: VersionJson): string {
  for (const lib of json.libraries ?? []) {
    // 与 `collectFromJson` 同口径：**规则不允许的条目必须跳过**。否则可能取到被规则排除的
    // 那条 `oshi-core`（如 Windows-only 条目）⇒ 覆盖件名与真树里实际会进 classpath 的那条不一致，
    // 覆盖逻辑（ClasspathStager 按名覆盖）就会错位。
    if (!ruleAllows(lib.rules)) {
      continue;
    }
    const name = lib.name ?? '';
    let hit = false;
    for (const pfx of OSHI_CORE_PREFIXES) {
      if (name.startsWith(pfx)) {
        hit = true;
      }
    }
    if (!hit) {
      continue;
    }
    const rel = lib.downloads?.artifact?.path ?? mavenPathFromName(name);
    const slash = rel.lastIndexOf('/');
    return slash >= 0 ? rel.substring(slash + 1) : rel;
  }
  return '';
}

/** classpath：本地存在的声明库 jar + 版本 jar，冒号连接。 */
export function assembleClasspath(gameRoot: string, json: VersionJson, versionId: string): string {
  return collectFromJson(gameRoot, json, versionId).join(':');
}

/** LWJGL 世代选择规则：声明的 lwjgl 版本 ≥ 门槛即选该世代。 */
interface LwjglGenRule {
  minMajor: number;
  minMinor: number;
  gen: string;
}

/**
 * LWJGL 世代表（**按门槛降序**）。**现代只随包一代（3.4.3）** → 任何 LWJGL3 声明（含更老的
 * 3.1.x/3.2.x/3.3.x）都归并到它；表最后一行即"地板"，未命中任何门槛也落到它。
 * legacy（≤1.12.2，声明 `org.lwjgl.lwjgl:*`）不走此表——由 `isLegacyLwjgl` 单独处理
 * （用 MC 自带的 LWJGL2 + 我们自编的 `liblwjgl.so`）。
 * 现代能统一到 3.4.3，靠我们 overlay 里的 **3.4.x 兼容 shim**（见 tools/lwjgl/README.md）。
 * 将来若要并存多代：按门槛降序加行即可（门槛 = 该世代的 lwjgl 版本）。
 */
const LWJGL_GEN_TABLE: LwjglGenRule[] = [
  { minMajor: 3, minMinor: 4, gen: LWJGL_GEN_343 },
];

/**
 * 从版本 json 声明的 `org.lwjgl:lwjgl:<ver>` 推断 LWJGL 世代。现代只有一代（3.4.3）→ 一律返回它；
 * 更老/未知/无该依赖也归并到它（不会指向未随包的世代）。若某版本真缺 API，运行期显式报
 * `NoSuchMethodError`，即"该补 shim / 该加一代"的信号（先跑 tools/lwjgl/mc_lwjgl_compat_check.py）。
 */
export function lwjglGeneration(jsonPath: string): string {
  const resolved = resolveVersionByPath(jsonPath);
  let major = -1;
  let minor = -1;
  if (resolved !== null) {
    const prefix = 'org.lwjgl:lwjgl:';
    for (const lib of resolved.json.libraries ?? []) {
      const name = lib.name ?? '';
      if (!name.startsWith(prefix)) {
        continue;
      }
      const m: RegExpMatchArray | null = name.substring(prefix.length).match(/^(\d+)\.(\d+)/);
      if (m !== null) {
        major = parseInt(m[1]);
        minor = parseInt(m[2]);
        break;
      }
    }
  }
  let chosen = LWJGL_GEN_TABLE[LWJGL_GEN_TABLE.length - 1].gen;   // 地板 = 最老世代
  for (const rule of LWJGL_GEN_TABLE) {
    if (major > rule.minMajor || (major === rule.minMajor && minor >= rule.minMinor)) {
      chosen = rule.gen;
      break;
    }
  }
  return chosen;
}

/**
 * 收集该版本运行所需的全部 jar 源路径（规则过滤后本地存在的库 + 版本 jar）。
 * 供 `ClasspathStager` 把它们平铺拷贝到沙箱目录 `<cache>/mc-cp/<id>/`。
 *
 * 谁还在用平铺目录（2026-10-01 方案 A 之后的现状）：
 *  - **原版 / Fabric**：`-cp "<dir>/*"` 通配（平铺 classpath 自足）；
 *  - **launchwrapper（≤1.12.2 Forge / LiteLoader / 独立 OptiFine）**：**不再**用通配 —— `-cp` 改走
 *    `assembleRealTreeClasspath` 的**显式有序绝对路径**（见 buildLaunchArgv / launchWrapperOptifineOrder）。
 *    根因 = 通配没有顺序语义（展开序 = 文件系统 `readdir`），本次 `TRSRTransformation` 事故即由此。
 *    此时平铺目录仍被启动路径消费的只剩**随包/补丁件**：oshi 补丁件（`assembleRealTreeClasspath` 按
 *    绝对路径前置）、`asm9/*` 子目录（ASM 覆盖）。整份平铺集合**保留**是保守做法（去留/清理留待
 *    下一轮，勿在此顺手删）。
 *  - 注：**不再**把「启动器族」（launchwrapper / FML 本体 / OptiFine）摘出平铺目录 —— Java 8 档下
 *    JDK 8 的 app classloader 本身就是 `URLClassLoader`，`Launch.<init>` 的强转原生成立、族内类同源
 *    ⇒ 无需换系统 CL、无需摘族（见 buildLaunchArgv 顶部定案与研究档
 *    `stuffs/research/launchwrapper-study/REPORT.md` §2）。
 * 继承/补丁实例的客户端 jar 在基座版本目录（叶子目录常无 <id>.jar）——补进列表，
 * 这样平铺目录对 Fabric 也自带 MC jar（平铺 classpath 自足，无需任何运行期追加）。
 */
export function collectJarSources(gameRoot: string, jsonPath: string, versionId: string): string[] {
  const resolved = resolveVersion(gameRoot, jsonPath);
  if (resolved === null) {
    return [];
  }
  const parts = collectFromJson(gameRoot, resolved.json, versionId);
  // 继承/补丁实例的客户端 jar 在基座版本目录（叶子目录常无 <id>.jar）——补进 classpath，
  // 这样平铺目录对 Fabric 也自带 MC jar（平铺 classpath 自足，无需任何运行期追加）。
  // （「启动器族不再摘出」「launchwrapper 形态不再用通配」等口径见本函数头注释。）
  const baseId = resolved.clientJarId;
  if (baseId.length > 0 && baseId !== versionId) {
    const baseJar = `${gameRoot}/versions/${baseId}/${baseId}.jar`;
    if (fileExists(baseJar) && !parts.includes(baseJar)) {
      parts.push(baseJar);
    }
  }
  return parts;
}

/**
 * 该版本是否 **legacy LWJGL2**（声明 `org.lwjgl.lwjgl:*`；即 MC ≤1.12.2）。
 * LWJGL2 与 LWJGL3 都定义 `org.lwjgl` 包 → 同时进 classpath 会 `sealing violation`，
 * 因此 legacy 版本**不得**混入我们随包的 LWJGL3 jar。
 */
export function isLegacyLwjgl(jsonPath: string): boolean {
  const resolved = resolveVersionByPath(jsonPath);
  if (resolved === null) {
    return false;
  }
  const prefix = 'org.lwjgl.lwjgl:';
  for (const lib of resolved.json.libraries ?? []) {
    // Respect per-library rules: a version whose only org.lwjgl.lwjgl: entries are rule-excluded
    // (e.g. Windows-only) must NOT be treated as legacy — otherwise we would drop our LWJGL3 jar
    // and lwjglClasspathOk() would then abort the launch.
    if (!ruleAllows(lib.rules)) {
      continue;
    }
    if ((lib.name ?? '').startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

function fileExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch {
    return false;
  }
}
