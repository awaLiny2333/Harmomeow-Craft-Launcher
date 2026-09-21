// meowcraftlib HSP: Meowcraft 启动器运行库（自研 native 桥）。
// - libmeowjrebridge.so：JLI 启动（dlopen 指定 JRE 的 libjli + 设 OHOS_DL_DIR）、
//   surface 注入、输入透传（meowSend*）、光标锁、关窗。
// - libmeowcraftbridge.so：GLFW/GL 桥（ring+pump/EGL）。
// JRE 运行时（官方 OpenJDK 件 + 组件）在 meowjre HSP；JRE 数据（modules/conf）在
// filesDir/meow-jres/meow_jre（随 entry rawfile 解压）。launchJvm 参数化
// jreHome/jreLibsDir，与 JRE 版本解耦。
import bridge from 'libmeowjrebridge.so';

export const launchJvm = bridge.launchJvm;
// 自研 meowcraftbridge 桥：把 XComponent surfaceId 交给 libmeowcraftbridge.so（写 env+0 窗口环）。
export const setGameSurface = bridge.setGameSurface;
export const setWindowActive = bridge.setWindowActive;
export const resizeGameSurface = bridge.resizeGameSurface;
export const requestGameWindowClose = bridge.requestGameWindowClose;
// 输入透传：ArkTS 事件 -> critical_send_* 全自研链路（ring+pump）。
export const meowSendKey = bridge.meowSendKey;
export const meowSendMouseButton = bridge.meowSendMouseButton;
export const meowSendCursorPos = bridge.meowSendCursorPos;
export const meowSendScroll = bridge.meowSendScroll;
export const meowSendChar = bridge.meowSendChar;
export const meowGetGrabbing = bridge.meowGetGrabbing;
export const lockCursor = bridge.lockCursor;
export const unlockCursor = bridge.unlockCursor;
// P0：窗口级鼠标 filter（绕开 ArkUI 节流，非 grab 直通）。
export const mouseFilterStart = bridge.mouseFilterStart;
export const mouseFilterStop = bridge.mouseFilterStop;
// 触屏 -> 鼠标：窗口级 touch filter（与 mouseFilter* 同一套原点/缩放口径）。
export const touchFilterStart = bridge.touchFilterStart;
export const touchFilterStop = bridge.touchFilterStop;
// 虚拟按键排除区（display px CSV）：命中区内的手指只按按钮，不驱动光标/点击。
export const touchSetExcludeRects = bridge.touchSetExcludeRects;
// 原生鼠标增量输入：挂 NDK 覆盖节点收 NODE_ON_MOUSE（grab 视角驱动）。
export const bindNodeContent = bridge.bindNodeContent;
export const meowGrabReset = bridge.meowGrabReset;
export const meowGetInputRate = bridge.meowGetInputRate;
// 全屏：MC 的 glfwSetWindowMonitor → native 存请求，ArkTS 轮询取走并驱动真实窗口。
export const takeFullscreenRequest = bridge.takeFullscreenRequest;
