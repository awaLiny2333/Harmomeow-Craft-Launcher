import { fileIo } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RENDERER_LIB, VULKAN_LIB_SHIM, WINDOW_DEFAULT_W, WINDOW_DEFAULT_H,
  SPOOF_OS_NAME, SPOOF_OS_VERSION, SPOOF_CPU_NAME,
  LOCALE_LANGUAGE, LOCALE_COUNTRY, LOCALE_TIMEZONE, RULE_OS_NAME, RULE_OS_ARCH,
  OFFLINE_USERNAME, LAUNCHER_NAME, LAUNCHER_VERSION,
  CLIENT_MOD_NAME, LWJGL_GEN_343, LWJGL_JAR_PREFIX,
  LWJGL_NAME_MAPPER } from '../constants/LaunchDefaults';
import { MEOW_CLASS_LOADER, MEOW_MAIN_CLASS } from '../constants/LaunchContract';
import { libraryNames, resolveMergeModuleEntries } from './NeoForgeInstaller';
import { NATIVES_DIR } from '../constants/Paths';
import { VersionJson, VersionRule, VersionRuleArg, VERSION_FORM_VANILLA, LOADER_NEO_FORGE,
  resolveVersion, resolveVersionByPath } from './VersionResolver';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameLauncher';

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
  /** 游戏运行目录（= `-Duser.dir` = MeowLauncher 的 `${game_directory}` 宏 = MC 的 `--gameDir`）。
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
  /** 完整 classpath（可选）：通常平铺后用 "<dir>/*" 通配，规避超长 -cp 失效。 */
  classpath?: string;
  /** 平铺目录（可选）：NeoForge 走真 maven 树 classpath，但随包 LWJGL3 jar 只能从这里取。 */
  classpathDir?: string;
  /** 沙箱可写运行目录（tmpdir/natives 解压；鸿蒙无 /tmp）。 */
  runDir?: string;
  /** el1 可 dlopen 的 native libs 目录（meowjre HSP libs：JRE .so + LWJGL/JNA 组件）。 */
  nativeLibsDir?: string;
  /** 自研桥 so 所在目录（当前与 nativeLibsDir 同：meowjre HSP libs）——JVM 侧
   *  System.loadLibrary 也需能在该目录找到 libmeowcraftbridge.so。 */
  craftLibsDir?: string;
  /** 自研桥模式：MeowClassLoader + MeowLauncher 入口（配合 clean-room lwjgl.jar）。 */
  meowcraftLaunch?: boolean;
  /** 窗口尺寸（glfwstub 用）。 */
  width?: number;
  height?: number;
  /** 启动器 home 目录（meow-home）：账户/运行数据所在。默认 gameRoot 父目录；
   *  建议传 filesDir 下沙箱目录，避免外部目录写权限问题（账户自立门户）。
   *  注：目录已 meow 化（原 launcher-home）；Java 属性键（MEOWCRAFT_HOME / meowcraft.path.*）
   *  为 launcher.jar 读取的固定契约，不可改名。 */
  /** 实例身份（versions 目录名，见 VersionScanner.GameVersion.id）；空 = 退回 json 的 id。
   *  MeowLauncher 的 <version> 参数与 ${version_name} 用它，保证与目录名一致。 */
  versionId?: string;
  meowHomeDir?: string;
  /** CPU 线程数覆盖（-XX:ActiveProcessorCount）；0/未设 = 自动（不传，JVM 探测）。 */
  activeProcessorCount?: number;
  /** 最大堆 MB（-Xmx）；0/未设 = 自动（不传，JVM 默认）。 */
  maxHeapMb?: number;
  /** 离线玩家名；空 = 用 LaunchDefaults.OFFLINE_USERNAME。 */
  playerName?: string;
  /** 账户 UUID（NeoForge 由 ArkTS 直接组 game 参数 ⇒ 必须传真值；原版/Fabric 走 Java 侧可留空）。 */
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
  /** 【M1 实验】MC 的 `--graphicsBackend`（如 `vulkan`）。见下方 argv 处的注释。 */
  graphicsBackend?: string;
  /** 额外 JVM 参数（实验/调优）：空格/换行分隔，原样追加（放在固定参数之前，允许被覆盖）。 */
  jvmArgs?: string;
}

/**
 * 组装启动 argv（不含 argv[0]）。
 * 超长 -cp 在本 JLI 移植会失效，调用方应把 jar 平铺后用 "<dir>/*" 通配传入 classpath。
 */
export function buildLaunchArgv(opts: LaunchOptions): string[] {
  // 归一版本清单：展开 inheritsFrom 继承链 / HMCL patches[]（见 VersionResolver）。
  const resolved = resolveVersion(opts.gameRoot, opts.jsonPath);
  if (resolved === null) {
    return [];
  }
  const json = resolved.json;
  // NeoForge：启动参数与 classpath 形态都不同于原版/Fabric（见下方各处 `neoForge` 分支）。
  const neoForge = resolved.loader === LOADER_NEO_FORGE;
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
  // classpath：
  // - NeoForge：**必须走真 maven 树**（`-p` 模块路径与 `-DignoreList` 都依赖真实布局，
  //   且平铺的 `<dir>/*` 顺序不定、会与树形成双份库）；随包 LWJGL3 jar 另从平铺目录补进来。
  // - 原版/Fabric：维持平铺 `<dir>/*`（规避超长 -cp）。
  const classpath = neoForge
    ? assembleNeoForgeClasspath(opts.gameRoot, json, id,
        opts.classpathDir !== undefined ? opts.classpathDir : '', opts.jsonPath)
    : ((opts.classpath !== undefined && opts.classpath.length > 0)
      ? opts.classpath
      : assembleClasspath(opts.gameRoot, json, id));
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
  const macros = makeMacros(gameDir, opts.gameRoot, id, json.assetIndex?.id ?? '', classpath,
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
  // user.dir = 运行目录：MeowLauncher 的 GameDirs.profile 取它，派生 ${game_directory} 宏 →
  // MC 的 --gameDir（存档/选项/日志/资源包落点），log4j 相对路径也随它。
  // "版本隔离"开关的唯一作用点就是这里；user.home 保持 .minecraft 根（不参与隔离）。
  argv.push('-Duser.dir=' + gameDir);
  argv.push('-Duser.home=' + opts.gameRoot);
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

  // 自研桥模式固定参数（与历史启动器 JVMLauncher overridableArguments 全量对齐——LWJGL 桥与 MeowClassLoader 需要）。
  // NeoForge 同样需要（LWJGL/随包 native/平台伪装都在这一段），只是它**不设** MeowClassLoader、
  // 主类也不走 MeowLauncher（见下方两个分支的 `neoForge` 条件）。
  if (opts.meowcraftLaunch === true || neoForge) {
    // 自研 system classloader 只服务 vanilla：它让我们在运行期往 classpath 追加 jar。
    // **Fabric（等加载器）必须走默认 app classloader**：Fabric Knot 要求 loader 类由父加载器持有、
    // game 类由它自己的 KnotClassLoader 持有；若我们自设 system CL，KnotClassLoader 会把 loader 类
    // 当 game 类加载 → `verifyNotInTargetCl` 抛错 + mixin 类分裂。故加载器实例不设该 -D。
    if (resolved.form === VERSION_FORM_VANILLA) {
      argv.push(`-Djava.system.class.loader=${MEOW_CLASS_LOADER}`);
    }
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
    // 【M1 实验】Vulkan 库名指向自研 shim（libmeowvulkan.so，随包 native）。它可以修正本机 ICD 的
    // "上报面裁剪"（补 KHR 扩展名 / 补 post-1.2 feature 位 / createDevice 剔名 / KHR→core 名字映射），
    // 但**默认纯透传**（env MEOW_VK_SHIM 未设 = 与真 loader 行为一致）⇒ MC 的 Vulkan 探测照样失败、
    // 照样回退 OpenGL（= 今天的行为）。要做实验再设 MEOW_VK_SHIM=1。回退阶梯见方案文 §7.5。
    argv.push(`-Dorg.lwjgl.vulkan.libname=${VULKAN_LIB_SHIM}`);
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
    // launcher.jar 的 MeowLauncher.launchMinecraft 会读取该属性并转写为
    // glfw.windowSize（缺它则 getProperty 返回 null → System.setProperty NPE，同款）。
    argv.push(`-Dcacio.managed.screensize=${w}x${h}`);
    argv.push(`-Dmeowcraft.path.minecraft=${opts.gameRoot}`);
    // 目录模型：MEOWCRAFT_HOME=homeDir（账户所在，dir=<home>+"/accounts"），
    // MEOWCRAFT_GAME_DIR=.minecraft。账户目录自立门户：传 filesDir 下沙箱目录最稳（外部目录可能不可写）。
    // 账户 home：正常由 GameLauncher 恒传可写沙箱目录；缺省时退回游戏根（不再假设 .minecraft 父目录）。
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
  }

  // JVM 参数（规则过滤 + 宏替换；含 -cp ${classpath} → 真实 cp）。
  // legacy（≤1.12.2）用 minecraftArguments、没有 arguments.jvm，所以这里不会带出 -cp —— 必须补上，
  // 否则 `-Djava.system.class.loader=MeowClassLoader` 找不到类 → VM 初始化即败（表现=秒崩）。
  let hasClasspathArg = false;
  for (const raw of collectArgs(json.arguments?.jvm)) {
    const v = expand(raw, macros);
    if (v.length > 0) {
      argv.push(v);
      if (v === '-cp' || v === '-classpath') {
        hasClasspathArg = true;
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
  // 主类与后续参数：
  // - 原版/Fabric：MeowLauncher <username> <version>（其内部反射真正 mainClass）；
  // - **NeoForge**：直接以加载器的 mainClass（BootstrapLauncher / fml.startup.Client）为主类，
  //   并由本函数补齐 game 参数（`--fml.*` 等）——**不设** `-Djava.system.class.loader`
  //   （NeoForge 自带模块层与类加载体系，自设 system CL 会冲突）。
  if (opts.meowcraftLaunch === true && !neoForge) {
    argv.push(MEOW_MAIN_CLASS);
    argv.push(player);
    argv.push(id);
  } else {
    const mainClass = json.mainClass ?? '';
    if (mainClass.length > 0) {
      argv.push(mainClass);
    }
    // 游戏参数
    for (const raw of collectGameArgs(json)) {
      const v = expand(raw, macros);
      if (v.length > 0) {
        argv.push(v);
      }
    }
  }
  // MC 的 `--graphicsBackend` 是**游戏参数**，必须在主类之后（之前误放进 JVM 的 -D 区，JVM 会当作自己的
  // 选项而拒绝启动）。两条路径都在这里追加：原版/Fabric 由我们的 launcher 把 `args[2..]` 原样转给 MC，
  // NeoForge 直接由本函数补齐 game 参数。MC 默认 GL 优先（见方案文 §5.5），只有它才会去试 Vulkan；
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
function makeMacros(gameDir: string, gameRoot: string, id: string, assetIndexId: string,
  classpath: string, nativesDir: string, player: string, authUuid: string,
  authAccessToken: string, authXuid: string): LaunchMacros {
  const m: LaunchMacros = new Map<string, string>();
  m.set('auth_player_name', player);
  m.set('version_name', id);
  m.set('version_type', 'release');
  m.set('game_directory', gameDir);
  m.set('assets_root', `${gameRoot}/assets`);
  m.set('assets_index_name', assetIndexId);
  m.set('auth_uuid', authUuid);
  m.set('auth_access_token', authAccessToken);
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

/** 游戏参数：新版 arguments.game 或旧版 minecraftArguments（按空格拆分）。 */
function collectGameArgs(json: VersionJson): string[] {
  if (json.arguments?.game !== undefined) {
    return collectArgs(json.arguments.game);
  }
  const legacy = json.minecraftArguments ?? '';
  return legacy.length > 0 ? legacy.split(' ') : [];
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
 * NeoForge 的 classpath：**真 maven 树的按序路径** + 随包 LWJGL3 jar + 实例 jar。
 *
 * `collectFromJson` 已按声明顺序收集「规则允许且本地存在」的库，并**跳过 MC 声明的 LWJGL3**
 * （`org/lwjgl/…`，由随包 clean-room jar 替代）——这正是 NeoForge 需要的形态；
 * 唯一要补的是那个随包 jar（它在平铺目录里，不在 maven 树里）。
 */
function assembleNeoForgeClasspath(gameRoot: string, json: VersionJson, versionId: string,
  stagedDir: string, jsonPath: string): string {
  const parts = collectFromJson(gameRoot, json, versionId);
  // 加载器 `-DmergeModules=` 点名的 jar 必须出现在 `java.class.path` 里（它按**文件名**查表做合并）；
  // 这些 jar（如 jna-5.10.0.jar）不在清单中，由安装期补下到 maven 树 → 这里按名解析后补进 classpath。
  const jvmArgs = collectArgs(json.arguments?.jvm);
  const libNames = libraryNames(json.libraries as object[] | undefined);
  for (const e of resolveMergeModuleEntries(jvmArgs, libNames)) {
    const p = `${gameRoot}/libraries/${e.relPath}`;
    if (fileExists(p)) {
      parts.push(p);
    }
  }
  if (stagedDir.length > 0) {
    // (1) oshi 补丁版**前置**：真 maven 树里的 oshi 是上游原版，会去初始化 JNA（JNA 在 OHOS 上
    //     dlopen 自己解出来的 native 必失败 → NoClassDefFoundError，F3/SystemReport 报错）。
    //     平铺目录里那份是 ClasspathStager 覆盖过的补丁件（认 -Dmeow.cpu.chip），前置即可遮蔽。
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
    // (2) 随包 LWJGL3 jar（collectFromJson 会跳过树里的 org.lwjgl3，由它提供）。
    const genJar = `${LWJGL_JAR_PREFIX}${lwjglGeneration(jsonPath)}.jar`;
    const genPath = `${stagedDir}/${genJar}`;
    if (fileExists(genPath)) {
      parts.push(genPath);
    }
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

/** 声明里的 oshi jar 文件名（如 `oshi-core-6.4.10.jar`）；无则空串。 */
function oshiJarBaseName(json: VersionJson): string {
  const prefix = 'com.github.oshi:oshi-core:';
  for (const lib of json.libraries ?? []) {
    const name = lib.name ?? '';
    if (!name.startsWith(prefix)) {
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
 * 供启动器把它们平铺拷贝到沙箱目录后以 "<dir>/*" 通配作为 classpath——
 * 直接拼长 -cp（可达上万字符）在本 JLI 移植中会导致类加载失效。
 */
export function collectJarSources(gameRoot: string, jsonPath: string, versionId: string): string[] {
  const resolved = resolveVersion(gameRoot, jsonPath);
  if (resolved === null) {
    return [];
  }
  const parts = collectFromJson(gameRoot, resolved.json, versionId);
  // 继承/补丁实例的客户端 jar 在基座版本目录（叶子目录常无 <id>.jar）——补进 classpath，
  // 这样平铺目录对 Fabric 也自带 MC jar（不依赖自研 classloader 的运行期追加）。
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

// 账户档案由 AccountsTools.writeAccountFile 生成（见 data/AccountsTools.ets）。
