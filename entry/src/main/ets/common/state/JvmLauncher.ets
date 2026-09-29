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
 * **桥就绪契约**（2026-09-29 新增；同日定为**可重臂**语义）—— 一个显式的"桥已选定"事件源
 * + 一个早期调用队列，取代此前到处"读 `currentBridge()` 当前值再判空"的写法：后者的 `undefined`
 * 表示"还没选"，**不是**"失败"，于是所有在启动早期（surface 就绪 / `selectBridge` 之前）发起的
 * 桥调用都被**静默跳过**。**2026-09-29 真机事故**：`GameInputController` 的启动触屏 filter 注册
 * 正是这样被跳过 ⇒ **鼠标不动时触屏全废**（纯触屏设备上根本没有鼠标事件去补注册）。
 *
 * 两个消费入口：[`whenBridgeSelected()`]（等选定后做一次）与 [`runWithBridge()`]（未选定则入队、
 * 选定后 FIFO flush）。二者都是同一契约的投影，且都保证**绝不静默丢弃**。
 *
 * **最终语义（为什么必须"可重臂"）**：`selectBridge()` 是**可重试**的（选择失败不绑定
 * `activeBridge`，`startJvm` 失败会重置 `jvmStarted`），故"就绪"是**当前这一次**的状态、
 * 不是进程终态：
 *   - **失败 = 只拒掉当刻的等待者**（绝不挂起），并**立刻换一个新的待兑现 promise** —— 否则一次
 *     失败会**永久毒化**契约，之后成功的重选再也叫不醒等待者（启动触屏注册就会在重试路径上再次
 *     静默丢失，正是本次要根治的 bug）。
 *   - **成功 = 兑现当刻等待者**（清空引用 ⇒ 重复信号天然幂等）；若当刻无人等待，之后任何一次
 *     `whenBridgeSelected()` 直接由已落定的 `activeBridge` 立即兑现。
 *   - 入队动作**有上界**（[`MAX_PENDING_BRIDGE_ACTIONS`]）；选择失败 / 启动中止时**带条数丢弃**
 *     （绝不静默），仅成功时 FIFO flush —— 陈旧意图不跨会话重放。
 */
let resolveBridgeSelected: ((b: JreLibModule) => void) | undefined = undefined;
let rejectBridgeSelected: ((e: Error) => void) | undefined = undefined;

/** 新建一个"桥已选定"待兑现 promise，并挂防御 catch（失败而当下无人 await 时不产 unhandled rejection 噪声）。 */
function makeBridgeSelectedPromise(): Promise<JreLibModule> {
  const p: Promise<JreLibModule> = new Promise<JreLibModule>((resolve, reject) => {
    resolveBridgeSelected = resolve;
    rejectBridgeSelected = reject;
  });
  p.catch(() => {
  });
  return p;
}

/** 当前待兑现的就绪 promise（**可重臂**：失败时整体换新 —— 见 [`signalBridgeReadyFailure()`]）。 */
let bridgeSelectedPromise: Promise<JreLibModule> = makeBridgeSelectedPromise();

/** 桥就绪后按需执行的动作队列（FIFO；选定瞬间 flush）。有界，见 [`MAX_PENDING_BRIDGE_ACTIONS`]。 */
type BridgeAction = (b: JreLibModule) => void;
const pendingBridgeActions: BridgeAction[] = [];

/**
 * 队列容量上界。入队的都是"就绪后做一次"的小注册/上报（窗口焦点、虚拟按键排除区），
 * 正常一屏个位数；给一个明显宽裕但**有限**的上界，杜绝"选择迟迟不发生 ⇒ 无限堆积"。
 * 溢出时丢**最旧**的一条（有状态语义天然"最后写入者胜"，最新意图更接近当前状态）并留痕。
 */
const MAX_PENDING_BRIDGE_ACTIONS = 64;

function signalBridgeReady(b: JreLibModule): void {
  const r = resolveBridgeSelected;
  resolveBridgeSelected = undefined;
  rejectBridgeSelected = undefined;
  if (r !== undefined) {
    r(b);
  }
}

/**
 * 就绪失败：**只拒掉当刻的等待者**，并**立刻重新武装**（换一个新的待兑现 promise）。
 * 为什么重臂：`selectBridge()` 可重试（失败不绑定 `activeBridge`，`startJvm` 会重置 `jvmStarted`）
 * ⇒ 一次失败不是终态；若不重臂，之后成功的重选**既叫不醒（已 reject 的）旧等待者、更会让新
 * 等待者拿到一个永不兑现的旧 promise**（就绪契约被一次性毒化）。重复调用天然幂等（引用已清空）；
 * 无等待者时也照常重臂。
 */
function signalBridgeReadyFailure(reason: string): void {
  const j = rejectBridgeSelected;
  resolveBridgeSelected = undefined;
  rejectBridgeSelected = undefined;
  if (j !== undefined) {
    j(new Error(reason));
  }
  bridgeSelectedPromise = makeBridgeSelectedPromise();
}

/**
 * 选择失败 / 启动中止时**丢弃**全部待发动作：它们属于**已经失败的那一次启动**，留在队列里会在
 * 下一次成功选择时被补发（跨会话重放陈旧意图）。绝不静默 —— 必带条数与原因（空队列时不动作）。
 */
function dropPendingBridgeActions(reason: string): void {
  const n = pendingBridgeActions.length;
  if (n === 0) {
    return;
  }
  pendingBridgeActions.splice(0, n);
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'dropping %{public}d pending bridge action(s): %{public}s',
    n, reason);
}

function flushPendingBridgeActions(): void {
  const b = activeBridge;
  if (b === undefined || pendingBridgeActions.length === 0) {
    return;
  }
  const batch: BridgeAction[] = pendingBridgeActions.splice(0, pendingBridgeActions.length);
  hilog.info(LOG_DOMAIN, LOG_TAG, 'bridge selected: flushing %{public}d queued action(s)',
    batch.length);
  for (const action of batch) {
    try {
      action(b);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'queued bridge action failed: %{public}s', JSON.stringify(e));
    }
  }
}

/**
 * 按 HSP 模块名取桥入口。
 * 动态 import 的 specifier 必须是**静态字面量** ⇒ 只能这样写成一张小表；
 * **新增一套 JRE 时只在此加一个分支**（生产侧走 [`selectBridge()`]，消费侧走
 * [`whenBridgeSelected()`] / [`runWithBridge()`]，低层读取才用 [`currentBridge()`]）。
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
        'bridge already bound to %{public}s, cannot switch to %{public}s (one per process)',
        activeHspModule, runtime.hspModule);
      return false;
    }
    return true;
  }
  try {
    activeBridge = await loadBridge(runtime.hspModule);
  } catch (e) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'bridge load failed: hsp=%{public}s err=%{public}s',
      runtime.hspModule, JSON.stringify(e));
    // 就绪失败必须显式告知等待者（否则 whenBridgeSelected() 会永远挂起）；可重臂，见 signalBridgeReadyFailure。
    signalBridgeReadyFailure('bridge load failed: ' + runtime.hspModule);
    // 这次启动的早期入队动作属于**已经失败的一次选择** ⇒ 带条数丢弃（绝不静默、不跨会话重放）。
    dropPendingBridgeActions('bridge selection failed: ' + runtime.hspModule);
    return false;
  }
  activeHspModule = runtime.hspModule;
  hilog.info(LOG_DOMAIN, LOG_TAG, 'bridge selected: hsp=%{public}s', activeHspModule);
  // 兑现"桥已选定"契约（当刻等待者）+ flush 早期入队的桥调用；都必须在 activeBridge 落定之后。
  signalBridgeReady(activeBridge);
  flushPendingBridgeActions();
  return true;
}

/**
 * 取**本进程当前实例**的桥；**未选定 ⇒ `undefined`**（绝不自动加载默认模块——见 `selectBridge` 的注释）。
 *
 * ⚠️ 这是**低层访问器**：`undefined` 表示"还没选"，**不是**"失败"。用途仅限**生产侧**
 * （`selectBridge` 之后紧接着读一次的调用，如 `GameWindow.injectAndLaunch`）。**其它消费方**
 * （要在就绪后执行一次注册/上报的代码）必须走 [`whenBridgeSelected()`] / [`runWithBridge()`] ——
 * 直接读当前值会在启动早期（surface 就绪 / `selectBridge` 之前）静默跳过调用，
 * 这正是 2026-09-29 触屏 filter 启动注册被跳过、鼠标不动即触屏全废的根因。
 */
export async function currentBridge(): Promise<JreLibModule | undefined> {
  return activeBridge;
}

/**
 * **等桥选定**：返回"本进程选定桥"的 promise —— 已选定则**立即兑现**（不依赖当刻有无等待者）；
 * 否则等一个**仍在等待**的选择；选择失败则 reject（且契约会重臂 ⇒ 之后成功的重选仍能兑现后续调用）。
 * 消费方（要在就绪后执行一次注册/上报）一律用它，**不要**读 [`currentBridge()`] 的当前值判空。
 */
export function whenBridgeSelected(): Promise<JreLibModule> {
  if (activeBridge !== undefined) {
    return Promise.resolve(activeBridge);
  }
  return bridgeSelectedPromise;
}

/**
 * **桥就绪后执行一次**：桥已选定 ⇒ 立即执行（带保护，与 flush 路径对称）；否则入队、在 `selectBridge`
 * 成功后按 FIFO flush（有状态语义的调用天然"最后写入者胜"）。用于"开窗早期可能早于桥选定"的
 * 最佳努力调用，**绝不静默丢弃**（入队即留痕）。与 [`whenBridgeSelected()`] 是同一契约的两面。
 */
export function runWithBridge(action: BridgeAction): void {
  if (activeBridge !== undefined) {
    // 与 flushPendingBridgeActions 的 flush 路径对称：单个动作抛异常不得打断调用方
    // （调用点多为 ArkUI 事件回调 / 静态入口）。
    try {
      action(activeBridge);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'bridge action failed: %{public}s', JSON.stringify(e));
    }
    return;
  }
  if (pendingBridgeActions.length >= MAX_PENDING_BRIDGE_ACTIONS) {
    // 有界：满则丢最旧（最新意图更接近当前状态），留痕不静默。
    pendingBridgeActions.shift();
    hilog.warn(LOG_DOMAIN, LOG_TAG,
      'pending bridge actions at cap %{public}d: dropped oldest (pending=%{public}d)',
      MAX_PENDING_BRIDGE_ACTIONS, pendingBridgeActions.length);
  }
  pendingBridgeActions.push(action);
  hilog.info(LOG_DOMAIN, LOG_TAG, 'bridge not selected yet: action queued (pending=%{public}d)',
    pendingBridgeActions.length);
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
 * 驱动翻译成 SDL 焦点事件。
 * 焦点事件可能在桥选定之前就来（窗口创建即产 ACTIVE）⇒ 走就绪队列（[`runWithBridge()`]）：
 * 选定后补发，而不是读当前值后静默丢弃（旧版 HSP 无该入口时仍静默忽略 —— 那是**能力缺失**，
 * `?.` 表达，与启动时序无关）。
 */
export async function notifyWindowActive(active: boolean): Promise<void> {
  runWithBridge((craft) => {
    craft.setWindowActive?.(active);
  });
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
      'JRE "%{public}s" el1 not ready: missing %{public}s/libjli.so => HSP module "%{public}s" not installed/rebuilt (install HSP before HAP)',
      runtime.id, libsDir, runtime.hspModule);
    jvmStarted = false;   // 什么都没起（进程内 JVM 仍未启动）⇒ 允许修完部署后重试
    // 启动中止 ⇒ 丢弃这次启动早期入队的动作（绝不静默、不跨会话重放）。
    dropPendingBridgeActions('launch aborted: el1 not deployed: ' + runtime.id);
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
    hilog.info(LOG_DOMAIN, LOG_TAG, 'el1(ArkTS view) %{public}s: %{public}d entries, libjvm=%{public}s',
      libsDir, names.length, hasJvm ? 'yes' : 'no');
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'el1(ArkTS view) unreadable: %{public}s', libsDir);
  }
  try {
    if (!await selectBridge(runtime)) {
      // 选择失败已由 selectBridge 内部（可重臂 + 带条数丢弃队列）处理；此处兜底再丢一次（空队列无动作）。
      dropPendingBridgeActions('launch aborted: bridge select failed: ' + runtime.hspModule);
      jvmStarted = false;
      return false;
    }
    const craft = await currentBridge();
    if (craft === undefined) {
      jvmStarted = false;
      dropPendingBridgeActions('launch aborted: bridge missing after select: ' + runtime.hspModule);
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
