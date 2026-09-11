/**
 * meowcraftlib HSP native bridge (libmeowjrebridge.so).
 * Launches the JVM by dlopen'ing the selected JRE module's libjli.
 */

/**
 * Launch the JVM on a background thread (fire-and-forget).
 * @param filesDir application files dir.
 * @param args full java argv (argv0 first), e.g. ["java", "-version"].
 * @param jreHome java.home data dir (filesDir/meow-jres/<id>).
 * @param jreLibsDir JRE module el1 libs dir (contains libjli.so/libjvm.so; OHOS_DL_DIR).
 * @param rendererLib renderer .so to pre-dlopen (RTLD_GLOBAL), e.g. "libGLv4.so".
 * @param rendererEnv MEOWCRAFT_RENDERER value, e.g. "openglv4".
 */
export const launchJvm: (filesDir: string, args: string[], jreHome: string, jreLibsDir: string,
  rendererLib: string, rendererEnv: string, glProfile: string) => void;

/**
 * Hand the XComponent surfaceId to our own libmeowcraftbridge.so so it creates
 * the OH_NativeWindow and stores it at meow_environ->window (env+0x000).
 * Call once when the game XComponent surface is first ready.
 * @param surfaceId XComponent surface id.
 * @param w surface width in px (hint).
 * @param h surface height in px (hint).
 */
export const setGameSurface: (surfaceId: number, w: number, h: number) => boolean;

/**
 * Notify our libmeowcraftbridge of a live surface resize. Same surfaceId only updates
 * the internal size mirrors (render thread applies it); a different surfaceId
 * falls back to the full window-create path. Call from onSurfaceChanged.
 * @param surfaceId XComponent surface id.
 * @param w new width in px.
 * @param h new height in px.
 */
export const resizeGameSurface: (surfaceId: number, w: number, h: number) => boolean;

/**
 * Ask libmeowcraftbridge to flip LWJGL's shouldClose flag so Minecraft exits gracefully.
 * Intended for the XComponent surface-destroyed callback. No-op-safe if the
 * bridge has not been primed.
 */
export const requestGameWindowClose: () => boolean;

/**
 * Forward a GLFW key event into libmeowcraftbridge's input ring (critical_send_key).
 * @param key GLFW key code (see GlfwInput.ets toGlfwKey).
 * @param scancode always 0 in this build.
 * @param action GLFW action: 0 release / 1 press / 2 repeat.
 * @param mods GLFW modifier bitmask (1 shift / 2 ctrl / 4 alt / 8 super).
 */
export const meowSendKey: (key: number, scancode: number, action: number, mods: number) => boolean;

/**
 * Forward a mouse button event (critical_send_mouse_button).
 * @param button GLFW mouse button 0..7.
 * @param action 1 press / 0 release.
 * @param mods GLFW modifier bitmask.
 */
export const meowSendMouseButton: (button: number, action: number, mods: number) => boolean;

/**
 * Forward absolute cursor position in frame pixels (critical_send_cursor_pos;
 * native signature is float,float). Coordinates originate top-left like GLFW.
 */
export const meowSendCursorPos: (x: number, y: number) => boolean;

/**
 * Forward a scroll wheel event (critical_send_scroll). GLFW convention:
 * positive y = scroll up, positive x = scroll right.
 */
export const meowSendScroll: (x: number, y: number) => boolean;

/**
 * Forward a printable character (critical_send_char_mods then critical_send_char).
 * @param codepoint Unicode code point of the character.
 * @param mods GLFW modifier bitmask.
 */
export const meowSendChar: (codepoint: number, mods: number) => boolean;

/**
 * Read libmeowcraftbridge env->grabbing (set by MC via CallbackBridge.nativeSetGrabbing).
 * @returns 1 while Minecraft has the cursor grabbed, else 0.
 */
export const meowGetGrabbing: () => number;

/**
 * Lock the mouse cursor into a window (native OH_WindowManager_LockCursor).
 * Only supported on the focused window; auto-released on focus loss.
 * @param windowId window id from window.Window#getWindowProperties().id.
 * @param follow if false the cursor is held in place (does not follow movement).
 * @returns 0 (WS_OK) on success, else an error code.
 */
export const lockCursor: (windowId: number, follow: boolean) => number;

/**
 * Release the mouse cursor lock (native OH_WindowManager_UnlockCursor).
 * @param windowId window id from window.Window#getWindowProperties().id.
 * @returns 0 (WS_OK) on success, else an error code.
 */
export const unlockCursor: (windowId: number) => number;

/**
 * 注册窗口级鼠标 filter（非 grab 绝对坐标直通；绕开 ArkUI 节流）。
 * NDK displayX/Y 为 display 像素；本端 local = (displayPx - originPx) / scale，
 * 得到 MC framebuffer 空间的坐标（渲染缩放 S 时组件布局为 1/S、视觉经 .scale(S) 放大，
 * 故 displayPx = origin + S * 组件px）。scale=1 时退化为 local = displayPx - originPx。
 * @param windowId 游戏窗口 id。
 * @param ox 组件左上角在 display 像素的 x（= (ArkUI displayX - S * event.x) * pxPerVp）。
 * @param oy 组件左上角在 display 像素的 y。
 * @param scale 渲染缩放系数 S（1 = 不缩放）。
 */
export const mouseFilterStart: (windowId: number, ox: number, oy: number, scale: number) => number;
export const mouseFilterStop: (windowId: number) => number;

/**
 * 把 ArkTS 侧 ContentSlot 的 NodeContent 交给 native，挂一个 NDK 创建的透明覆盖节点
 * （HitTestMode.Transparent，不挡下层 XComponent），注册 NODE_ON_MOUSE。
 * grab 时原生按 rawDelta 驱动虚拟光标（采样率 = 显示帧率）。
 * @param content NodeContent（@kit.ArkUI）。
 * @param sens 抓取灵敏度（与 ArkTS CURSOR_SENS 一致）。
 * @returns 0 表示注册成功。
 */
export const bindNodeContent: (content: object, sens: number) => number;

/**
 * 进入 grab：把原生虚拟光标重置到 (cx, cy) 并下发一次（避免视角瞬跳）。
 * @param cx 中心 x（frame px）。
 * @param cy 中心 y（frame px）。
 * @returns 0 表示成功。
 */
export const meowGrabReset: (cx: number, cy: number) => number;

/**
 * 当前有效鼠标采样率（次/秒）：grab 走原生 NODE_ON_MOUSE，非 grab 走窗口 filter。
 * 供左下角 overlay 显示。
 */
export const meowGetInputRate: () => number;

/**
 * 全屏切换请求（MC 的 glfwSetWindowMonitor → native 存 → ArkTS 轮询取走）。
 * request: 0 无 / 1 进入全屏 / 2 退出全屏；x/y/w/h 为 MC 传入的窗口矩形（退出还原用）。
 */
export interface FullscreenRequest {
  request: number;
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 取走一次全屏切换请求；无请求时 request=0。 */
export const takeFullscreenRequest: () => FullscreenRequest;
