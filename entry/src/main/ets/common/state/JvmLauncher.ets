import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HSP_MEOWJRE, HSP_MEOWJRE_LEGACY } from '../constants/Paths';
import { JavaRuntime } from '../data/JavaRuntime';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'JvmLauncher';

/**
 * meowjre HSP 模块形态（自研启动桥；其 native 在 HSP namespace 内 dlopen
 * JRE 模块的 libjli 起 JVM）。JRE 数据在 filesDir/meow-jres，JRE .so 在 meowjre HSP。
 * 唯一共享类型：入口/游戏页等所有使用方从此处 import，勿各自重复声明。
 */
/**
 * 全屏切换请求（MC 的 glfwSetWindowMonitor → native 存 → ArkTS 轮询取走）。
 * request: 0 无 / 1 进入全屏 / 2 退出全屏；x/y/w/h 为 MC 传入的窗口矩形（退出时还原用）。
 */
export interface FullscreenRequest {
  request: number;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface JreLibModule {
  launchJvm: (filesDir: string, args: string[], jreHome: string, jreLibsDir: string,
    rendererLib: string, rendererEnv: string, glProfile: string, extraRenderEnv: string) => void;
  /** 自研 meowcraftbridge：surface 就绪时把 surfaceId 给它（写 env+0 窗口环）。 */
  setGameSurface?: (surfaceId: number, w: number, h: number) => boolean;
  setWindowActive?: (active: boolean) => boolean;
  /** 自研 meowcraftbridge：resize 通知（同 sid 只标尺寸，render 线程 apply）。 */
  resizeGameSurface?: (surfaceId: number, w: number, h: number) => boolean;
  /** 自研 meowcraftbridge：关窗请求（翻转 LWJGL shouldClose，让 MC 优雅退出）。 */
  requestGameWindowClose?: () => boolean;
  /** 输入透传：以下均直连自研 meowcraftbridge（ring+pump，不经额外桥）。 */
  meowSendKey?: (key: number, scancode: number, action: number, mods: number) => boolean;
  meowSendMouseButton?: (button: number, action: number, mods: number) => boolean;
  meowSendCursorPos?: (x: number, y: number) => boolean;
  meowSendScroll?: (x: number, y: number) => boolean;
  meowSendChar?: (codepoint: number, mods: number) => boolean;
  meowGetGrabbing?: () => number;
  lockCursor?: (windowId: number, follow: boolean) => number;
  unlockCursor?: (windowId: number) => number;
  mouseFilterStart?: (windowId: number, ox: number, oy: number, scale: number) => number;
  mouseFilterStop?: (windowId: number) => number;
  /** 触屏 → 鼠标：窗口级 touch filter，与 mouseFilter* 同一套「原点 / 缩放」口径。
   *  enable = 开关；sens = 触屏转视角倍率（独立于鼠标手感）。 */
  touchFilterStart?: (windowId: number, ox: number, oy: number, scale: number,
    enable: boolean, sens: number) => number;
  touchFilterStop?: (windowId: number) => number;
  /** 虚拟按键排除区（display px CSV "x,y,w,h;..."）；命中区内的手指只按按钮，空串清空。 */
  touchSetExcludeRects?: (csv: string) => void;
  /** 原生鼠标增量输入：挂 NDK 覆盖节点，grab 时按 rawDelta 驱动虚拟光标。 */
  bindNodeContent?: (content: object, sens: number) => number;
  /** 进入 grab：重置原生虚拟光标到中心并下发一次。 */
  meowGrabReset?: (cx: number, cy: number) => number;
  /** 当前有效鼠标采样率（次/秒），供右下角 overlay 显示。 */
  meowGetInputRate?: () => number;
  /** 取走一次全屏切换请求（MC glfwSetWindowMonitor 触发）；无则 request=0。 */
  takeFullscreenRequest?: () => FullscreenRequest;
}

/** 进程内 JVM 只能起一次（单例，二次启动会冲突/失败）。 */
let jvmStarted = false;

/**
 * 本进程**已选定的桥**（= 起 JVM 的那个 HSP 模块）。
 *
 * 为什么必须"记住"而不是每次 import 固定模块名：每个 HSP 模块各有一份自己的
 * `libmeowcraftbridge.so`，而它带着**共享状态**（窗口环 / surface / 输入 / grab）。
 * 若 JVM 起在 legacy 模块、而窗口/输入调用仍 import `meowjre`，两者会各写一份、状态分家
 * ⇒ 窗口无响应/输入失效。JVM 进程内只起一次（见 `jvmStarted`）⇒ 单值绑定足够。
 */
let activeBridge: JreLibModule | undefined = undefined;
let activeHspModule: string = '';

/**
 * 按 HSP 模块名取桥入口。
 * 动态 import 的 specifier 必须是**静态字面量** ⇒ 只能这样写成一张小表；
 * **新增一套 JRE 时只在此加一个分支**（其余代码一律走 [`selectBridge()`] / [`currentBridge()`]）。
 */
async function loadBridge(hspModule: string): Promise<JreLibModule> {
  if (hspModule === HSP_MEOWJRE_LEGACY) {
    return await import('meowjrelegacy') as JreLibModule;
  }
  return await import('meowjre') as JreLibModule;
}

/**
 * **选定**本进程的桥 = "本实例要用的那套 JRE 所在模块"。返回是否可用。
 *
 * ⚠️ 必须在**任何**桥调用之前调用（`GameWindow` 在注入 surface 之前调），且**同进程只能选一次**
 * （重复选同一个模块 = 幂等；选不同模块 = 报错拒绝，因为桥的 native 共享状态已经绑定）。
 *
 * 为什么不能"按需自动加载默认模块"：每个 HSP 各有一份 `libmeowcraftbridge`/`libmeowjrebridge`，
 * 且两模块 `libIsolation:true`（各自独立命名空间）。**2026-09-29 真机事故**：`onSurfaceCreated`
 * 先按"默认"加载了 `meowjre` 的桥，随后启动选了 legacy ⇒ 就成了"跑在 meowjre 的桥里去 dlopen
 * `meowjrelegacy` 的 libjli" ⇒ 被策略拒绝，且错误是 `No error information`（无 errno），
 * 同时 `stat`/`open` 全部成功 —— 极难从现象反推（当时连查三轮）。
 */
export async function selectBridge(runtime: JavaRuntime): Promise<boolean> {
  if (activeBridge !== undefined) {
    if (activeHspModule !== runtime.hspModule) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        '桥已绑定 %{public}s，无法切到 %{public}s（同进程只能一套）',
        activeHspModule, runtime.hspModule);
      return false;
    }
    return true;
  }
  activeBridge = await loadBridge(runtime.hspModule);
  activeHspModule = runtime.hspModule;
  hilog.info(LOG_DOMAIN, LOG_TAG, 'bridge selected: hsp=%{public}s', activeHspModule);
  return true;
}

/**
 * 取**本进程当前实例**的桥；**未选定 ⇒ `undefined`**（绝不自动加载默认模块——见 `selectBridge` 的注释）。
 * 所有桥调用都必须经它（窗口/输入/全屏/grab），且调用方按"可能没有桥"处理（`?.`）。
 */
export async function currentBridge(): Promise<JreLibModule | undefined> {
  return activeBridge;
}

/** 本进程当前桥所在的 HSP 模块名（日志/自证用；未选定 = 空串）。 */
export function currentHspModule(): string {
  return activeHspModule;
}

/**
 * 26.3(SDL)：把"游戏窗口是否获焦"告诉 native。
 * 为什么需要：MC 只在收到 SDL 的 FOCUS_LOST/FOCUS_GAINED 时才更新自己的 focused（→
 * `Minecraft.pauseIfInactive` 依 options 的 pauseOnLostFocus 决定自动暂停）；平台侧能给出
 * 这个状态的只有 windowStageEvent 的 ACTIVE/INACTIVE。native 侧落进共享块，由 SDL `ohos`
 * 驱动翻译成 SDL 焦点事件。best-effort：桥未选定 / HSP 未就绪 / 旧版 HSP 无该入口时静默忽略。
 */
export async function notifyWindowActive(active: boolean): Promise<void> {
  const craft = await currentBridge();
  craft?.setWindowActive?.(active);
}

/**
 * 启动 JVM 执行给定 argv（argv[0] 应含 java 可执行路径）。
 * 幂等保护：进程内只允许启动一次，重复调用直接忽略并打日志。
 *
 * @param runtime **选中**的那套 JRE（见 [`JavaPolicy.resolveJavaRuntime`](../data/JavaPolicy.ets)）：
 *        它同时给出桥所在模块（el1/OHOS_DL_DIR 的来源）与数据目录（java.home），
 *        ⇒ 两者**必然配套**，不会出现"数据用 A、el1 用 B"。
 */
export async function startJvm(uiContext: common.UIAbilityContext, argv: string[],
  runtime: JavaRuntime, rendererLib: string, rendererEnv: string, glProfile: string,
  renderEnv: string): Promise<boolean> {
  if (jvmStarted) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'JVM already started in this process, skip');
    return false;
  }
  jvmStarted = true;
  const libsDir = runtime.libsDir(uiContext.bundleCodeDir);
  // 部署自检：每套 JRE 的 el1 由**它自己的 HSP 模块**承载。缺 `libjli.so` 几乎总是
  // 「新 HSP 没随包安装」——而**没有**这道检查时，症状是 native 的
  // `dlopen libjli failed: ... No such file or directory`（且 ArkTS 侧可能已静默回落到
  // 另一份 `meowcraftlib` 绑定，日志里看到的是**别**模块的 libsDir，容易误判）。
  // 2026-09-29 真机就踩了这个：桥来自 `meowjre`、却去 `meowjrelegacy` 的 el1 找 libjli。
  let deployed = false;
  try {
    deployed = fileIo.accessSync(`${libsDir}/libjli.so`);
  } catch (e) {
    deployed = false;
  }
  if (!deployed) {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'JRE "%{public}s" el1 未就绪：缺 %{public}s/libjli.so ⇒ HSP 模块 "%{public}s" 没安装/没重建（须先装 HSP 再装 HAP）',
      runtime.id, libsDir, runtime.hspModule);
    jvmStarted = false;   // 什么都没起（进程内 JVM 仍未启动）⇒ 允许修完部署后重试
    return false;
  }
  // [对比用] ArkTS 侧看到的该 el1 目录内容 —— 与 native 的 `[diag]` 对照，
  // 判定"两侧是否看到同一个目录"（2026-09-29 真机：ArkTS 说 libjli 在、native dlopen 说 ENOENT）。
  try {
    const names = fileIo.listFileSync(libsDir);
    let hasJvm = false;
    for (const n of names) {
      if (n === 'libjvm.so') {
        hasJvm = true;
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'el1(ArkTS 视图) %{public}s: %{public}d 件，libjvm=%{public}s',
      libsDir, names.length, hasJvm ? 'yes' : 'no');
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'el1(ArkTS 视图) 读不到: %{public}s', libsDir);
  }
  try {
    if (!await selectBridge(runtime)) {
      jvmStarted = false;
      return false;
    }
    const craft = await currentBridge();
    if (craft === undefined) {
      jvmStarted = false;
      return false;
    }
    const jreHome = runtime.home(uiContext.filesDir);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'launching: hsp=%{public}s jreId=%{public}s argv0=%{public}s argn=%{public}d libs=%{public}s',
      runtime.hspModule, runtime.id, argv.length > 0 ? argv[0] : '', argv.length, libsDir);
    craft.launchJvm(uiContext.filesDir, argv, jreHome, libsDir, rendererLib, rendererEnv,
      glProfile, renderEnv);
    return true;
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'launch error (hsp=%{public}s): %{public}s',
      runtime.hspModule, JSON.stringify(e));
    return false;
  }
}
