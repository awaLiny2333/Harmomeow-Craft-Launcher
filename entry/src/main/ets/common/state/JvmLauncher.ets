import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { jreHomeDir, hspLibsDir } from '../constants/Paths';

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
 * 启动 JVM 执行给定 argv（argv[0] 应为 java 可执行路径）。
 * 幂等保护：进程内只允许启动一次，重复调用直接忽略并打日志。
 *
 * 经 jrelib HSP 桥：先确保 JRE 数据已解压（由调用方保证），
 * 动态 import 后把参数交给 native 桥（pipe 捕获输出上抛 hilog）。
 */
/**
 * 26.3(SDL)：把"游戏窗口是否获焦"告诉 native。
 * 为什么需要：MC 只在收到 SDL 的 FOCUS_LOST/FOCUS_GAINED 时才更新自己的 focused（→
 * `Minecraft.pauseIfInactive` 依 options 的 pauseOnLostFocus 决定自动暂停）；平台侧能给出
 * 这个状态的只有 windowStageEvent 的 ACTIVE/INACTIVE。native 侧落进共享块，由 SDL `ohos`
 * 驱动翻译成 SDL 焦点事件。best-effort：HSP 未就绪 / 旧版 HSP 无该入口时静默忽略。
 */
export async function notifyWindowActive(active: boolean): Promise<void> {
  const craft = await import('meowjre') as JreLibModule;
  craft.setWindowActive?.(active);
}

export async function startJvm(uiContext: common.UIAbilityContext, argv: string[],
  rendererLib: string, rendererEnv: string, glProfile: string, renderEnv: string): Promise<boolean> {
  if (jvmStarted) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'JVM already started in this process, skip');
    return false;
  }
  jvmStarted = true;
  try {
    const craft = await import('meowjre') as JreLibModule;
    const jreHome = jreHomeDir(uiContext.filesDir);
    const jreLibsDir = hspLibsDir(uiContext.bundleCodeDir); // JRE 模块自足 el1（桥同目录）
    hilog.info(LOG_DOMAIN, LOG_TAG, 'launching, argv0=%{public}s argn=%{public}d jre=%{public}s',
      argv.length > 0 ? argv[0] : '', argv.length, jreLibsDir);
    craft.launchJvm(uiContext.filesDir, argv, jreHome, jreLibsDir, rendererLib, rendererEnv,
      glProfile, renderEnv);
    return true;
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'meowjre launch error: %{public}s', JSON.stringify(e));
    return false;
  }
}
