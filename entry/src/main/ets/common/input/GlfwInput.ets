// GLFW 输入常量与 HarmonyOS KeyCode / 鼠标键 -> GLFW 的映射。
// GLFW 数值照历史启动器 LWJGLGLFWKeycode.ets 与 GLFW 头文件；
// HarmonyOS KeyCode 数值见 @ohos.multimodalInput.keyCode（数字/字母区 2000~2042）。
// 未知键返回 0：调用方丢弃 key 事件（可打印字符仍可走 meowSendChar 通道）。

import { KeyCode } from '@kit.InputKit';

// GLFW 修饰键位（glfw3.h）。mods 由 ArkTS 自维护，见 GameWindow。
export const GLFW_MOD_SHIFT: number = 0x1;
export const GLFW_MOD_CTRL: number = 0x2;
export const GLFW_MOD_ALT: number = 0x4;
export const GLFW_MOD_SUPER: number = 0x8;

// GLFW 键动作。
export const GLFW_RELEASE: number = 0;
export const GLFW_PRESS: number = 1;
export const GLFW_REPEAT: number = 2;

// GLFW 常用键码（完整数值表见 LWJGLGLFWKeycode.ets，这里只列本页需要引用的）。
export const GLFW_KEY_SPACE: number = 32;
export const GLFW_KEY_ESCAPE: number = 256;
export const GLFW_KEY_ENTER: number = 257;
export const GLFW_KEY_BACKSPACE: number = 259;
export const GLFW_KEY_T: number = 84;
export const GLFW_KEY_SLASH: number = 47; // '/'

// GLFW 鼠标键。
export const GLFW_MOUSE_BUTTON_1: number = 0;
export const GLFW_MOUSE_BUTTON_2: number = 1;
export const GLFW_MOUSE_BUTTON_3: number = 2;
export const GLFW_MOUSE_BUTTON_4: number = 3;
export const GLFW_MOUSE_BUTTON_5: number = 4;
export const GLFW_MOUSE_BUTTON_UNKNOWN: number = -1;

// HarmonyOS KeyCode 区段端点（快路径用）。
const HM_DIGIT_0: number = 2000;
const HM_DIGIT_9: number = 2009;
const HM_A: number = 2017;
const HM_Z: number = 2042;
const HM_F1: number = 2090;
const HM_F12: number = 2101;
const HM_F13: number = 2816;
const HM_F24: number = 2827;
const HM_KP_0: number = 2103;
const HM_KP_9: number = 2112;

/**
 * 可打印字符判断。unicode 仅在可打印时由 ArkUI 给出（基本拉丁），见规格 §3。
 * @param cp unicode 码点。
 * @returns 是否属于 0x21..0x7E 可打印区间。
 */
export function isPrintableChar(cp: number): boolean {
  return cp >= 0x21 && cp <= 0x7e;
}

/**
 * 返回该键是否是修饰键以及对应的 GLFW mod 位（非修饰键返回 0）。
 * 用于 GameWindow 自维护 mods。
 */
export function keyModFlag(hm: number): number {
  if (hm === KeyCode.KEYCODE_SHIFT_LEFT || hm === KeyCode.KEYCODE_SHIFT_RIGHT) {
    return GLFW_MOD_SHIFT;
  }
  if (hm === KeyCode.KEYCODE_CTRL_LEFT || hm === KeyCode.KEYCODE_CTRL_RIGHT) {
    return GLFW_MOD_CTRL;
  }
  if (hm === KeyCode.KEYCODE_ALT_LEFT || hm === KeyCode.KEYCODE_ALT_RIGHT) {
    return GLFW_MOD_ALT;
  }
  if (hm === KeyCode.KEYCODE_META_LEFT || hm === KeyCode.KEYCODE_META_RIGHT) {
    return GLFW_MOD_SUPER;
  }
  return 0;
}

/**
 * HarmonyOS KeyCode -> GLFW 键码。未知返回 0。
 * 快路径：数字 2000..2009 与 A..Z 2017..2042 均为 hm-1952；
 * F1..F12 (2090..2101)、F13..F24 (2816..2827)、小键盘 0..9 (2103..2112) 各成连续段；
 * 其余（编辑键/方向键/修饰左右/小键盘运算符）精确映射。
 */
export function toGlfwKey(hm: number): number {
  if (hm >= HM_DIGIT_0 && hm <= HM_DIGIT_9) {
    return hm - 1952; // 48..57
  }
  if (hm >= HM_A && hm <= HM_Z) {
    return hm - 1952; // 65..90
  }
  if (hm >= HM_F1 && hm <= HM_F12) {
    return hm - 1800; // 290..301
  }
  if (hm >= HM_F13 && hm <= HM_F24) {
    return hm - 2514; // 302..313
  }
  if (hm >= HM_KP_0 && hm <= HM_KP_9) {
    return hm - 1783; // 320..329
  }
  switch (hm) {
    case KeyCode.KEYCODE_SPACE:
      return 32;
    case KeyCode.KEYCODE_COMMA:
      return 44;
    case KeyCode.KEYCODE_MINUS:
      return 45;
    case KeyCode.KEYCODE_PERIOD:
      return 46;
    case KeyCode.KEYCODE_SLASH:
      return 47;
    case KeyCode.KEYCODE_SEMICOLON:
      return 59;
    case KeyCode.KEYCODE_EQUALS:
      return 61;
    case KeyCode.KEYCODE_LEFT_BRACKET:
      return 91;
    case KeyCode.KEYCODE_BACKSLASH:
      return 92;
    case KeyCode.KEYCODE_RIGHT_BRACKET:
      return 93;
    case KeyCode.KEYCODE_GRAVE:
      return 96;
    case KeyCode.KEYCODE_APOSTROPHE:
      return 39;
    case KeyCode.KEYCODE_ESCAPE:
      return 256;
    case KeyCode.KEYCODE_ENTER:
      return 257;
    case KeyCode.KEYCODE_TAB:
      return 258;
    case KeyCode.KEYCODE_DEL: // DEL(退格) = GLFW BACKSPACE，勿与 FORWARD_DEL(删除) 混淆
      return 259;
    case KeyCode.KEYCODE_INSERT:
      return 260;
    case KeyCode.KEYCODE_FORWARD_DEL:
      return 261;
    case KeyCode.KEYCODE_DPAD_RIGHT:
      return 262;
    case KeyCode.KEYCODE_DPAD_LEFT:
      return 263;
    case KeyCode.KEYCODE_DPAD_DOWN:
      return 264;
    case KeyCode.KEYCODE_DPAD_UP:
      return 265;
    case KeyCode.KEYCODE_PAGE_UP:
      return 266;
    case KeyCode.KEYCODE_PAGE_DOWN:
      return 267;
    case KeyCode.KEYCODE_MOVE_HOME:
      return 268;
    case KeyCode.KEYCODE_MOVE_END:
      return 269;
    case KeyCode.KEYCODE_CAPS_LOCK:
      return 280;
    case KeyCode.KEYCODE_SCROLL_LOCK:
      return 281;
    case KeyCode.KEYCODE_NUM_LOCK:
      return 282;
    case KeyCode.KEYCODE_SYSRQ:
      return 283;
    case KeyCode.KEYCODE_BREAK:
      return 284;
    case KeyCode.KEYCODE_NUMPAD_DIVIDE:
      return 331;
    case KeyCode.KEYCODE_NUMPAD_MULTIPLY:
      return 332;
    case KeyCode.KEYCODE_NUMPAD_SUBTRACT:
      return 333;
    case KeyCode.KEYCODE_NUMPAD_ADD:
      return 334;
    case KeyCode.KEYCODE_NUMPAD_DOT:
      return 330;
    case KeyCode.KEYCODE_NUMPAD_ENTER:
      return 335;
    case KeyCode.KEYCODE_NUMPAD_EQUALS:
      return 336;
    case KeyCode.KEYCODE_SHIFT_LEFT:
      return 340;
    case KeyCode.KEYCODE_CTRL_LEFT:
      return 341;
    case KeyCode.KEYCODE_ALT_LEFT:
      return 342;
    case KeyCode.KEYCODE_META_LEFT:
      return 343;
    case KeyCode.KEYCODE_SHIFT_RIGHT:
      return 344;
    case KeyCode.KEYCODE_CTRL_RIGHT:
      return 345;
    case KeyCode.KEYCODE_ALT_RIGHT:
      return 346;
    case KeyCode.KEYCODE_META_RIGHT:
      return 347;
    case KeyCode.KEYCODE_MENU:
      return 348;
    // AT/PLUS/STAR/POUND/NUMPAD_COMMA/括号等：无对应 GLFW 物理键 -> 0
    default:
      return 0;
  }
}

/**
 * ArkUI onMouse 鼠标键（MouseButton 位标志）-> GLFW 鼠标键。
 * @param hmBtn ArkUI MouseButton 枚举成员。
 * @returns GLFW 鼠标键 0..4；其它返回 -1。
 */
export function glfwMouseButton(hmBtn: MouseButton): number {
  switch (hmBtn) {
    case MouseButton.Left:
      return GLFW_MOUSE_BUTTON_1;
    case MouseButton.Right:
      return GLFW_MOUSE_BUTTON_2;
    case MouseButton.Middle:
      return GLFW_MOUSE_BUTTON_3;
    case MouseButton.Forward:
      return GLFW_MOUSE_BUTTON_4;
    case MouseButton.Back:
      return GLFW_MOUSE_BUTTON_5;
    default:
      return GLFW_MOUSE_BUTTON_UNKNOWN;
  }
}
