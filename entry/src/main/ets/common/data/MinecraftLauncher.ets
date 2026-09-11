import { fileIo } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RENDERER_LIB, VULKAN_LIB_DISABLED, WINDOW_DEFAULT_W, WINDOW_DEFAULT_H,
  SPOOF_OS_NAME, SPOOF_OS_VERSION, SPOOF_CPU_NAME,
  LOCALE_LANGUAGE, LOCALE_COUNTRY, LOCALE_TIMEZONE, RULE_OS_NAME, RULE_OS_ARCH,
  OFFLINE_USERNAME, LAUNCHER_NAME, LAUNCHER_VERSION,
  CLIENT_MOD_NAME, LWJGL_GEN_333, LWJGL_GEN_343,
  LWJGL_NAME_MAPPER } from '../constants/LaunchDefaults';
import { MEOW_CLASS_LOADER, MEOW_MAIN_CLASS } from '../constants/LaunchContract';
import { NATIVES_DIR } from '../constants/Paths';

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

/** 平台规则 os 字段。 */
interface RuleOs {
  name?: string;
  arch?: string;
}

/** 单条平台规则。 */
interface VersionRule {
  action?: string;
  os?: RuleOs;
}

/** 带规则的参数项。 */
interface VersionRuleArg {
  rules?: VersionRule[];
  value?: string | string[];
}

/** arguments 分组。 */
interface VersionArguments {
  game?: Array<string | VersionRuleArg>;
  jvm?: Array<string | VersionRuleArg>;
}

/** assetIndex 信息。 */
interface AssetIndex {
  id?: string;
}

/** 依赖库 artifact 下载信息。 */
interface ArtifactInfo {
  path?: string;
}

/** 依赖库 downloads 信息。 */
interface LibraryDownloads {
  artifact?: ArtifactInfo;
}

/** 版本 json 子集。 */
interface VersionJson {
  id?: string;
  mainClass?: string;
  minecraftArguments?: string;
  arguments?: VersionArguments;
  assetIndex?: AssetIndex;
  libraries?: VersionLibrary[];
}

/** 依赖库。 */
interface VersionLibrary {
  name?: string;
  rules?: VersionRule[];
  downloads?: LibraryDownloads;
}

/**
 * 平台规则命中：无规则默认允许；否则存在 allow 且 os 匹配当前平台才放行。
 */
function ruleAllows(rules?: VersionRule[]): boolean {
  if (rules === undefined || rules.length === 0) {
    return true;
  }
  for (const r of rules) {
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
  /** 完整 classpath（可选）：通常平铺后用 "<dir>/*" 通配，规避超长 -cp 失效。 */
  classpath?: string;
  /** 沙箱可写运行目录（tmpdir/natives 解压；鸿蒙无 /tmp）。 */
  runDir?: string;
  /** el1 可 dlopen 的 native libs 目录（meowjre25 HSP libs：JRE .so + LWJGL/JNA 组件）。 */
  nativeLibsDir?: string;
  /** 自研桥 so 所在目录（当前与 nativeLibsDir 同：meowjre25 HSP libs）——JVM 侧
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
  meowHomeDir?: string;
  /** CPU 线程数覆盖（-XX:ActiveProcessorCount）；0/未设 = 自动（不传，JVM 探测）。 */
  activeProcessorCount?: number;
  /** 最大堆 MB（-Xmx）；0/未设 = 自动（不传，JVM 默认）。 */
  maxHeapMb?: number;
  /** 离线玩家名；空 = 用 LaunchDefaults.OFFLINE_USERNAME。 */
  playerName?: string;
  /** 设备 CPU 芯片型号（ArkTS deviceInfo.chipType）；空 = 不传。 */
  cpuChip?: string;
  /** 渲染后端库名（按 MC 版本选，见 RendererPolicy）；空 = 默认桌面 GL（RENDERER_LIB）。
   *  必须与 GameLauncher 传给 startJvm 的 rendererLib 一致（meowjrebridge 启动前会自检）。 */
  rendererLib?: string;
}

/**
 * 组装启动 argv（不含 argv[0]）。
 * 超长 -cp 在本 JLI 移植会失效，调用方应把 jar 平铺后用 "<dir>/*" 通配传入 classpath。
 */
export function buildLaunchArgv(opts: LaunchOptions): string[] {
  const json = readJson(opts.jsonPath);
  if (json === null) {
    return [];
  }
  const id = json.id ?? '';
  if (id.length === 0) {
    return [];
  }
  // 运行目录（游戏数据落点）：版本隔离时 = versions/<id>，否则 = .minecraft 根。
  const gameDir = (opts.gameDir !== undefined && opts.gameDir.length > 0)
    ? opts.gameDir
    : opts.gameRoot;
  // classpath：给定则直接用，否则按 json 本地存在 jar 拼。
  const classpath = (opts.classpath !== undefined && opts.classpath.length > 0)
    ? opts.classpath
    : assembleClasspath(opts.gameRoot, json);
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
    nativeMacroDir, player);
  const argv: string[] = [];

  // 固定 JVM 参数：平台伪装成 Linux —— MC/oshi/LWJGL 检测 os.name，HarmonyOS 会被拒绝。
  argv.push(`-Dos.name=${SPOOF_OS_NAME}`);
  argv.push(`-Dos.version=${SPOOF_OS_VERSION}`);
  // 设备真实 CPU 芯片型号（ArkTS deviceInfo.chipType 读入；鸿蒙沙箱读不到 /proc/cpuinfo）。
  if (opts.cpuChip !== undefined && opts.cpuChip.length > 0) {
    argv.push(`-Dmeow.cpu.chip=${opts.cpuChip}`);
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
  // el1 可 dlopen 区放 native .so：LWJGL/JNA 组件在 JRE 模块（meowjre25），自研桥
  // (meowcraftbridge) 在 meowcraftlib；java.library.path 两者都要（meowcraftbridge 在前）。
  if (opts.nativeLibsDir !== undefined && opts.nativeLibsDir.length > 0) {
    const craft = opts.craftLibsDir !== undefined && opts.craftLibsDir.length > 0
      ? `${opts.craftLibsDir}:` : '';
    argv.push(`-Djna.boot.library.path=${opts.nativeLibsDir}`);
    argv.push(`-Dorg.lwjgl.librarypath=${opts.nativeLibsDir}`);
    argv.push(`-Djava.library.path=${craft}${opts.nativeLibsDir}:${nativesDir}`);
    // freetype 由 jre 自带 libfreetype.so 提供（预编译 JRE 包同款，勿改名覆盖）。
  }

  // 自研桥模式固定参数（与历史启动器 JVMLauncher overridableArguments 全量对齐——LWJGL 桥与 MeowClassLoader 需要）。
  if (opts.meowcraftLaunch === true) {
    argv.push(`-Djava.system.class.loader=${MEOW_CLASS_LOADER}`);
    // 渲染后端按 MC 版本选（见 RendererPolicy）：≥1.17 → 桌面 GL libGLv4.so(Zink)；
    // ≤1.16 → gl4es(libgl4es.so，GLES 上的固定管线翻译)。必须与 startJvm 传的 rendererLib 一致；
    // glfwstub 不自建 EGL，交给渲染后端（桥按 MEOWCRAFT_RENDERER 决定 GL/GLES）。
    const rendererLib = (opts.rendererLib !== undefined && opts.rendererLib.length > 0)
      ? opts.rendererLib : RENDERER_LIB;
    argv.push(`-Dorg.lwjgl.opengl.libname=${rendererLib}`);
    // LWJGL 世代命名：所有世代统一用后缀名（liblwjgl_<digits>.so，如 _333/_343），与随包
    // 扁平目录里的多代共存；启动一律设 mapper + 世代号，交给 MeowBundledNameMapper 选名。
    const lwjglGen = lwjglGeneration(opts.jsonPath);
    argv.push(`-Dorg.lwjgl.system.bundledLibrary.nameMapper=${LWJGL_NAME_MAPPER}`);
    argv.push(`-Dmeow.lwjgl.gen=${lwjglGen}`);
    argv.push('-Dorg.lwjgl.system.allocator=system');
    argv.push('-Dorg.lwjgl.glfw.checkThread0=false');
    argv.push(`-Dorg.lwjgl.vulkan.libname=${VULKAN_LIB_DISABLED}`);
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
    const homeDir = opts.meowHomeDir !== undefined && opts.meowHomeDir.length > 0
      ? opts.meowHomeDir
      : gameRootParent(opts.gameRoot);
    argv.push(`-DMEOWCRAFT_HOME=${homeDir}`);
    argv.push(`-DMEOWCRAFT_GAME_DIR=${opts.gameRoot}`);
    argv.push('-Djna.nosys=false');
    argv.push('-Doshi.util.disable.cpufrequency=true');
    argv.push('-Doshi.util.disable.powersource=true');
    // CPU 线程数覆盖（高级选项）；0/未设 = 不传，由 JVM 自动探测（sysconf）。
    if (opts.activeProcessorCount !== undefined && opts.activeProcessorCount > 0) {
      argv.push(`-XX:ActiveProcessorCount=${opts.activeProcessorCount}`);
    }
    argv.push(`-Duser.language=${LOCALE_LANGUAGE}`);
    argv.push(`-Duser.country=${LOCALE_COUNTRY}`);
    argv.push(`-Duser.timezone=${LOCALE_TIMEZONE}`);
    argv.push('-Dlog4j2.formatMsgNoLookups=true');
    // Tools.getMinecraftArgs 会读 Server_Ip 属性并 isBlank() 判空（历史启动器 JVMLauncher 同款）；
    // 缺属性则 getProperty 返回 null → NPE。空值可安全走"无服务器直连"分支。
    argv.push('-DServer_Ip=');
    // LWJGL native 加载诊断——native 库加载失败时给出具体库名与原因。
    // 注意（LWJGL2/legacy 必须关 util.Debug）：LWJGL2 的 LWJGLUtil.DEBUG 门控
    // Display.swapBuffers 里的"交换前 glGetError 检查"（Display.java:616）。MC 自己从不检查
    // GL 错误，而 gl4es 的固定管线模拟会留下良性 GL 错误 → 该调试开关会把噪声变成致命
    // OpenGLException（实测 `Invalid operation (1282)`）。DebugLoader / opengl.Debug 保留
    // （仍有库加载与 GL 能力诊断输出），它们不触发那次检查。
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
    argv.push(`-Dorg.lwjgl.util.Debug=${legacyLwjgl ? 'false' : 'true'}`);
    argv.push('-Dorg.lwjgl.util.DebugLoader=true');
    argv.push('-Dorg.lwjgl.opengl.Debug=true');
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
  // 主类与后续参数：自研桥模式 = MeowLauncher <username> <version>；否则 vanilla。
  if (opts.meowcraftLaunch === true) {
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
  return argv;
}

/** 读取并解析版本 json。 */
function readJson(path: string): VersionJson | null {
  try {
    return JSON.parse(fileIo.readTextSync(path)) as VersionJson;
  } catch {
    return null;
  }
}

/** 宏表：值由 json + 离线约定决定。gameDir = 运行目录（隔离时 = versions/<id>），
 *  gameRoot = .minecraft 根（只有 assets 从它派生，保证资源池始终共享）。 */
function makeMacros(gameDir: string, gameRoot: string, id: string, assetIndexId: string,
  classpath: string, nativesDir: string, player: string): LaunchMacros {
  const m: LaunchMacros = new Map<string, string>();
  m.set('auth_player_name', player);
  m.set('version_name', id);
  m.set('version_type', 'release');
  m.set('game_directory', gameDir);
  m.set('assets_root', `${gameRoot}/assets`);
  m.set('assets_index_name', assetIndexId);
  m.set('auth_uuid', '');
  m.set('auth_access_token', '');
  m.set('classpath', classpath);
  m.set('natives_directory', nativesDir);
  m.set('launcher_name', LAUNCHER_NAME);
  m.set('launcher_version', LAUNCHER_VERSION);
  m.set('clientid', '');
  m.set('auth_xuid', '');
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

/** 从已解析 json 收集本规则+存在的 jar（库 + 版本 jar）。
 *  org.lwjgl.* 排除：LWJGL 全家由 clean-room 合并 jar 替代（鸿蒙 musl .so + glfw 桥）。 */
function collectFromJson(gameRoot: string, json: VersionJson): string[] {
  const parts: string[] = [];
  const libRoot = `${gameRoot}/libraries/`;
  for (const lib of json.libraries ?? []) {
    if (!ruleAllows(lib.rules)) {
      continue;
    }
    const rel = lib.downloads?.artifact?.path ?? '';
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
  const id = json.id ?? '';
  const verJar = `${gameRoot}/versions/${id}/${id}.jar`;
  if (fileExists(verJar)) {
    parts.push(verJar);
  }
  return parts;
}

/** classpath：本地存在的声明库 jar + 版本 jar，冒号连接。 */
export function assembleClasspath(gameRoot: string, json: VersionJson): string {
  return collectFromJson(gameRoot, json).join(':');
}

/** LWJGL 世代选择规则：声明的 lwjgl 版本 ≥ 门槛即选该世代。 */
interface LwjglGenRule {
  minMajor: number;
  minMinor: number;
  gen: string;
}

/**
 * LWJGL 世代表（**按门槛降序**）。就近归并：取「声明的 lwjgl 版本 ≥ 门槛」的**最高**世代；
 * 低于所有门槛（含无该依赖/极老版本）→ 落到表中**最老**世代（我们的地板）。
 * 故**永不选到未随包的世代**。新增一代：加一行（门槛 = 该世代的 lwjgl 版本）+ 随包 jar/natives
 * （见 tools/lwjgl/：`build_lwjgl_jar.sh` + `install_natives.sh <tag>`）。
 */
const LWJGL_GEN_TABLE: LwjglGenRule[] = [
  { minMajor: 3, minMinor: 4, gen: LWJGL_GEN_343 },
  { minMajor: 3, minMinor: 3, gen: LWJGL_GEN_333 },
];

/**
 * 从版本 json 声明的 `org.lwjgl:lwjgl:<ver>` 推断 LWJGL 世代。跨代 API 不兼容，故按代选随包件；
 * 未知/更老版本就近归并到最老世代（不会指向未随包的世代；若某版本真缺 API，运行期显式报
 * `NoSuchMethodError`，即"该加一代"的信号）。
 */
export function lwjglGeneration(jsonPath: string): string {
  const json = readJson(jsonPath);
  let major = -1;
  let minor = -1;
  if (json !== null) {
    const prefix = 'org.lwjgl:lwjgl:';
    for (const lib of json.libraries ?? []) {
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
export function collectJarSources(gameRoot: string, jsonPath: string): string[] {
  const json = readJson(jsonPath);
  if (json === null) {
    return [];
  }
  return collectFromJson(gameRoot, json);
}

/**
 * 该版本是否 **legacy LWJGL2**（声明 `org.lwjgl.lwjgl:*`；即 MC ≤1.12.2）。
 * LWJGL2 与 LWJGL3 都定义 `org.lwjgl` 包 → 同时进 classpath 会 `sealing violation`，
 * 因此 legacy 版本**不得**混入我们随包的 LWJGL3 jar。
 */
export function isLegacyLwjgl(jsonPath: string): boolean {
  const json = readJson(jsonPath);
  if (json === null) {
    return false;
  }
  const prefix = 'org.lwjgl.lwjgl:';
  for (const lib of json.libraries ?? []) {
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

/**
 * .minecraft 的父目录（历史启动器 homeDir）：取 gameRoot 去掉末尾 "/.minecraft"。
 * 形如 <parent>/.minecraft -> <parent>；其它形态退回上级目录。
 */
export function gameRootParent(gameRoot: string): string {
  const norm = gameRoot.endsWith('/') ? gameRoot.substring(0, gameRoot.length - 1) : gameRoot;
  if (norm.endsWith('/.minecraft')) {
    return norm.substring(0, norm.length - '/.minecraft'.length);
  }
  const idx = norm.lastIndexOf('/');
  return idx > 0 ? norm.substring(0, idx) : norm;
}

// 账户档案由 AccountsTools.writeAccountFile 生成（见 data/AccountsTools.ets）。
