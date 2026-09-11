import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pointer, KeyCode } from '@kit.InputKit';
import { window, NodeContent } from '@kit.ArkUI';
import { JreLibModule } from '../state/JvmLauncher';
import { SettingsTools } from '../data/SettingsTools';
import { WINDOW_DEFAULT_W, WINDOW_DEFAULT_H } from '../constants/LaunchDefaults';
import { SCROLL_VP_PER_NOTCH } from '../constants/Constants';
import { GLFW_RELEASE, GLFW_PRESS, GLFW_REPEAT, GLFW_MOD_SHIFT, GLFW_MOD_CTRL, GLFW_MOD_ALT,
  GLFW_MOD_SUPER, GLFW_KEY_ESCAPE, GLFW_KEY_ENTER, GLFW_KEY_BACKSPACE, GLFW_KEY_T,
  GLFW_KEY_SLASH, toGlfwKey, glfwMouseButton, keyModFlag } from './GlfwInput';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameInput';

/** rawDelta -> 虚拟光标像素 的校准系数（grab 视角灵敏度；可调）。 */
const CURSOR_SENS: number = 1.0;
/** grab 状态轮询间隔（ms）。 */
const GRAB_POLL_MS: number = 120;
/** 开聊键（T//）转发给 MC 后，等待其释放 grab 再激活 IME 的延迟（ms）。 */
const IME_ACTIVATE_DELAY_MS: number = 120;
/** 去激活后的冷却：防 Esc 关菜单/切屏瞬间被 poll 抢回焦点到隐形 IME。 */
const IME_COOLDOWN_MS: number = 600;
/** 采样率 overlay 刷新间隔（ms）。 */
const RATE_POLL_MS: number = 500;
/**
 * 功能键释放延迟（ms）。平台在"按住功能键 + 按其它键"时会先发一个 spurious Up
 * （实测 F3+F6：F3 提前 1-3ms 被抬起）。F 键的 Up 延迟提交且**必发**（不因其它键取消），
 * 既让紧随的键仍看到 F3 按住（组合键成立），又不会粘键（到期即释放）。
 */
const FKEY_RELEASE_GRACE_MS: number = 20;

/**
 * 游戏输入控制器（与 GameWindow 页面解耦的纯逻辑类）。
 *
 * 职责：键鼠/滚轮透传、隐形 IME 状态机、光标 grab 锁、窗口级鼠标 filter、
 * 采样率统计。页面只保留 UI 响应式字段（imeText/mouseRate/showInputRate）与 build()。
 *
 * 与页面的三个回调：
 * - focus(id)：请求焦点（'ime-input' / 'game-xc'）。
 * - onImeText(v)：把 IME 镜像文本回写页面 @Local（TextInput 绑定）。
 * - onRate(hz)：把采样率回写页面 @Local（overlay 显示）。
 */
export class GameInputController {
  private ctx: common.UIAbilityContext;
  private focus: (id: string) => void;
  private onImeText: (v: string) => void;
  private onRate: (hz: number) => void;

  private bridge: JreLibModule | undefined = undefined;

  // ---- 窗口级鼠标 filter（非 grab 绝对坐标直通）----
  private filterActive: boolean = false;
  private filterWinId: number = 0;
  private mapLastMs: number = 0;
  private mapOx: number = -1e9;
  private mapOy: number = -1e9;

  // ---- 原生鼠标增量输入（NDK 覆盖节点）----
  private nativeGrabInput: boolean = false;
  private overlayBound: boolean = false;

  // ---- 定时器 ----
  private grabPollTimer: number = -1;
  private rateTimer: number = -1;
  private imeActivateTimer: number = -1;
  private imeCooldownTimer: number = -1;

  // ---- grab ----
  private grabNative: boolean = false;
  private grabApplied: boolean = false;
  private grabBusy: boolean = false;
  private vx: number = 0;
  private vy: number = 0;
  private winId: number = 0;

  // ---- 键盘 / 尺寸 ----
  private pressed: Set<number> = new Set<number>();
  /** 功能键延迟释放定时器（kc -> timer）。见 FKEY_RELEASE_GRACE_MS。 */
  private pendingRelease: Map<number, number> = new Map<number, number>();
  private frameW: number = WINDOW_DEFAULT_W;
  private frameH: number = WINDOW_DEFAULT_H;
  private xcVpW: number = WINDOW_DEFAULT_W;
  private xcVpH: number = WINDOW_DEFAULT_H;
  /** 滚轮累计器：把 vp 轴值归一化后累计成整数"格"再下发（native ring 为 int）。 */
  private scrollAccX: number = 0;
  private scrollAccY: number = 0;
  /** 滚轮速度倍率（来自高级选项，默认 1.0；启动时读入）。 */
  private scrollScale: number = 1.0;
  /** 显示缩放系数 S：XComponent 布局为 1/S、视觉经 .scale(S) 放大；1 = 不缩放（默认，零回归）。 */
  private renderScale: number = 1;

  // ---- 隐形 IME ----
  private imeText: string = '';
  private imeLast: string = '';
  private imeActive: boolean = false;
  private imeLocalDeleted: boolean = false;
  private chatOpening: boolean = false;
  private imeCooldown: boolean = false;

  constructor(ctx: common.UIAbilityContext, focus: (id: string) => void,
    onImeText: (v: string) => void, onRate: (hz: number) => void) {
    this.ctx = ctx;
    this.focus = focus;
    this.onImeText = onImeText;
    this.onRate = onRate;
  }

  /** 由 GameWindow 注入已 import 的 meowjre25 桥。 */
  setBridge(b: JreLibModule): void {
    this.bridge = b;
  }

  /** surface 尺寸变化时同步（px + vp）。 */
  setFrameSize(w: number, h: number, vpW: number, vpH: number): void {
    this.frameW = w;
    this.frameH = h;
    this.xcVpW = vpW;
    this.xcVpH = vpH;
  }

  /** 设置显示缩放系数 S（与 XComponent 的 1/S 布局 + .scale(S) 配套）；<=0 视为 1。 */
  setRenderScale(scale: number): void {
    this.renderScale = scale > 0 ? scale : 1;
  }

  /** 挂 NDK 覆盖节点（同一 ContentSlot 只绑一次）。返回是否启用原生增量路径。 */
  bindOverlay(content: NodeContent): boolean {
    if (this.overlayBound) {
      return this.nativeGrabInput;
    }
    const b = this.bridge;
    if (b === undefined) {
      return false;
    }
    try {
      const brc = b.bindNodeContent?.(content, CURSOR_SENS) ?? -1;
      this.nativeGrabInput = brc === 0;
      this.overlayBound = brc === 0;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'bindNodeContent rc=%{public}d nativeGrab=%{public}d',
        brc, this.nativeGrabInput ? 1 : 0);
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'bindNodeContent err: %{public}s', JSON.stringify(e));
    }
    return this.nativeGrabInput;
  }

  /** 启动 grab 轮询 + 采样率 overlay（页面挂载时调用）。 */
  start(showInputRate: boolean): void {
    // 滚轮速度（高级选项，跨进程 Preferences）；窗口存活期内固定，改后下次开窗生效。
    this.scrollScale = new SettingsTools(this.ctx).scrollSpeedPercent() / 100;
    this.grabPollTimer = setInterval(() => {
      this.pollGrabbing();
    }, GRAB_POLL_MS);
    if (showInputRate) {
      this.startRateTimer();
    }
  }

  private startRateTimer(): void {
    if (this.rateTimer >= 0) {
      return;
    }
    this.rateTimer = setInterval(() => {
      const b = this.bridge;
      if (b !== undefined && b.meowGetInputRate !== undefined) {
        this.onRate(b.meowGetInputRate());
      }
    }, RATE_POLL_MS);
  }

  /** 页面销毁：清定时器 + 兜底解锁/补键。 */
  dispose(): void {
    this.clearPendingReleases();
    if (this.grabPollTimer >= 0) {
      clearInterval(this.grabPollTimer);
      this.grabPollTimer = -1;
    }
    if (this.rateTimer >= 0) {
      clearInterval(this.rateTimer);
      this.rateTimer = -1;
    }
    this.clearImeActivateTimer();
    if (this.imeCooldownTimer >= 0) {
      clearTimeout(this.imeCooldownTimer);
      this.imeCooldownTimer = -1;
    }
    this.imeCooldown = false;
    this.cleanupInput();
  }

  // ---- 桥懒加载 ----

  private async ensureBridge(): Promise<JreLibModule | undefined> {
    if (this.bridge !== undefined) {
      return this.bridge;
    }
    try {
      const b = await import('meowjre25') as JreLibModule;
      this.bridge = b;
      return b;
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'bridge lazy import fail: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  // ---- 发送原语（全部直连自研 meowcraftbridge，同步无锁）----

  /** 由 pressed 按下集合实时推导 GLFW mods（丢失/重复事件可自愈）。 */
  private currentMods(): number {
    let m: number = 0;
    if (this.isDown(KeyCode.KEYCODE_CTRL_LEFT) || this.isDown(KeyCode.KEYCODE_CTRL_RIGHT)) {
      m |= GLFW_MOD_CTRL;
    }
    if (this.isDown(KeyCode.KEYCODE_SHIFT_LEFT) || this.isDown(KeyCode.KEYCODE_SHIFT_RIGHT)) {
      m |= GLFW_MOD_SHIFT;
    }
    if (this.isDown(KeyCode.KEYCODE_ALT_LEFT) || this.isDown(KeyCode.KEYCODE_ALT_RIGHT)) {
      m |= GLFW_MOD_ALT;
    }
    if (this.isDown(KeyCode.KEYCODE_META_LEFT) || this.isDown(KeyCode.KEYCODE_META_RIGHT)) {
      m |= GLFW_MOD_SUPER;
    }
    return m;
  }

  private isDown(kc: number): boolean {
    return this.pressed.has(kc);
  }

  /** 功能键（F1-F24）：平台会在按住时按其它键前先发 spurious Up，需延迟释放兜底。 */
  private isFunctionKey(kc: number): boolean {
    return (kc >= KeyCode.KEYCODE_F1 && kc <= KeyCode.KEYCODE_F12) ||
      (kc >= KeyCode.KEYCODE_F13 && kc <= KeyCode.KEYCODE_F24);
  }

  /** 取消某键的待释放（仅同一键重新按下时调用；其它键不影响，避免粘键）。 */
  private cancelPendingReleaseFor(kc: number): void {
    const t = this.pendingRelease.get(kc);
    if (t !== undefined) {
      clearTimeout(t);
      this.pendingRelease.delete(kc);
    }
  }

  /** 延迟提交功能键释放（kc 保持在 pressed 直到定时器触发，到点必发）。 */
  private scheduleDeferredRelease(kc: number, gk: number): void {
    this.cancelPendingReleaseFor(kc);
    const timer = setTimeout(() => {
      this.pendingRelease.delete(kc);
      if (this.pressed.has(kc)) {
        this.pressed.delete(kc);
        this.sendKey(gk, GLFW_RELEASE);
      }
    }, FKEY_RELEASE_GRACE_MS);
    this.pendingRelease.set(kc, timer);
  }

  /** 清空所有待释放定时器（页面销毁）。 */
  private clearPendingReleases(): void {
    this.pendingRelease.forEach((t: number) => {
      clearTimeout(t);
    });
    this.pendingRelease.clear();
  }

  private sendKey(glfwKey: number, action: number): void {
    this.sendKeyMods(glfwKey, action, this.currentMods());
  }

  private sendKeyMods(glfwKey: number, action: number, mods: number): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendKey === undefined) {
      return;
    }
    b.meowSendKey(glfwKey, 0, action, mods);
  }

  private sendMouseButton(glfwBtn: number, action: number): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendMouseButton === undefined) {
      return;
    }
    b.meowSendMouseButton(glfwBtn, action, this.currentMods());
  }

  private sendCursorPos(x: number, y: number): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendCursorPos === undefined) {
      return;
    }
    b.meowSendCursorPos(x, y);
  }

  private sendScroll(x: number, y: number): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendScroll === undefined) {
      return;
    }
    b.meowSendScroll(x, y);
  }

  // ---- 隐形 IME ----

  private setImeText(v: string): void {
    this.imeText = v;
    this.onImeText(v);
  }

  /** 发送一次 GLFW 键 press+release（mods=0），IME 会话内的聊天注入用。 */
  private sendImeKey(glfwKey: number): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendKey === undefined) {
      return;
    }
    b.meowSendKey(glfwKey, 0, GLFW_PRESS, 0);
    b.meowSendKey(glfwKey, 0, GLFW_RELEASE, 0);
  }

  /** 把 seg 逐 UTF-32 codepoint（代理对合成）注入 MC 聊天。 */
  private sendImeChars(seg: string): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendChar === undefined) {
      return;
    }
    const n: number = seg.length;
    let i: number = 0;
    while (i < n) {
      const u: number = seg.charCodeAt(i);
      if (u >= 0xd800 && u <= 0xdbff && i + 1 < n) {
        const lo: number = seg.charCodeAt(i + 1);
        if (lo >= 0xdc00 && lo <= 0xdfff) {
          b.meowSendChar(((u - 0xd800) << 10) + (lo - 0xdc00) + 0x10000, 0);
          i += 2;
          continue;
        }
      }
      b.meowSendChar(u, 0);
      i += 1;
    }
  }

  /** 连续发送 count 次 BACKSPACE（press+release），删除 MC 聊天尾部。 */
  private sendImeBackspaces(count: number): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendKey === undefined) {
      return;
    }
    let k: number = 0;
    while (k < count) {
      b.meowSendKey(GLFW_KEY_BACKSPACE, 0, GLFW_PRESS, 0);
      b.meowSendKey(GLFW_KEY_BACKSPACE, 0, GLFW_RELEASE, 0);
      k += 1;
    }
  }

  private clearImeActivateTimer(): void {
    if (this.imeActivateTimer >= 0) {
      clearTimeout(this.imeActivateTimer);
      this.imeActivateTimer = -1;
    }
  }

  /** grab 中按了开聊键（T//）：延迟探测 MC 释放 grab 后激活。 */
  private onChatOpeningKey(): void {
    this.chatOpening = true;
    this.clearImeActivateTimer();
    this.imeActivateTimer = setTimeout(() => {
      this.imeActivateTimer = -1;
      const opening: boolean = this.chatOpening;
      this.chatOpening = false;
      if (opening && !this.imeActive && !this.grabNative && !this.imeCooldown) {
        this.activateIme();
      }
    }, IME_ACTIVATE_DELAY_MS);
  }

  private activateIme(): void {
    if (this.imeActive) {
      return;
    }
    this.imeActive = true;
    this.chatOpening = false;
    this.setImeText('');
    this.imeLast = '';
    this.imeLocalDeleted = false;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'IME activate');
    this.focus('ime-input');
  }

  private deactivateIme(): void {
    if (!this.imeActive) {
      return;
    }
    this.clearImeActivateTimer();
    this.imeActive = false;
    this.chatOpening = false;
    this.imeLast = '';
    this.setImeText('');
    this.imeLocalDeleted = false;
    this.imeCooldown = true;
    if (this.imeCooldownTimer >= 0) {
      clearTimeout(this.imeCooldownTimer);
    }
    this.imeCooldownTimer = setTimeout(() => {
      this.imeCooldownTimer = -1;
      this.imeCooldown = false;
    }, IME_COOLDOWN_MS);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'IME deactivate');
    this.focus('game-xc');
  }

  private cancelImeByEsc(): void {
    // 只负责去激活；Esc 的转发统一由 handleImeKey 负责（避免激活时重复发两次 Esc）。
    if (!this.imeActive) {
      return;
    }
    this.deactivateIme();
  }

  /** TextInput onSubmit（IME 非组字期 Enter）：发 ENTER 给 MC 提交 → 去激活。 */
  submitImeText(): void {
    if (!this.imeActive) {
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'IME submit diff len=%{public}d', this.imeText.length);
    this.sendImeKey(GLFW_KEY_ENTER);
    this.deactivateIme();
  }

  /** TextInput onChange：本地缓冲镜像 + 尾差同步（详见 notes/09/13、14）。 */
  syncImeText(v: string): void {
    // Guard + advance the mirror BEFORE setImeText(): writing the bound TextInput
    // text can re-fire onChange synchronously, which used to re-enter here and
    // send the same tail twice (duplicated characters in MC chat).
    if (v === this.imeLast) {
      return;
    }
    const last: string = this.imeLast;
    this.imeLast = v;
    this.setImeText(v);
    const b = this.bridge;
    if (b === undefined || b.meowSendChar === undefined || b.meowSendKey === undefined) {
      return;
    }
    if (v.startsWith(last)) {
      this.imeLocalDeleted = false;
      this.sendImeChars(v.substring(last.length));
    } else if (last.startsWith(v)) {
      this.imeLocalDeleted = true;
      this.sendImeBackspaces(last.length - v.length);
    } else {
      const nLast: number = last.length;
      const nV: number = v.length;
      const max: number = nLast < nV ? nLast : nV;
      let p: number = 0;
      while (p < max && last.charCodeAt(p) === v.charCodeAt(p)) {
        p += 1;
      }
      this.imeLocalDeleted = nLast - p > 0;
      this.sendImeBackspaces(nLast - p);
      this.sendImeChars(v.substring(p));
    }
  }

  // ---- grab 轮询与应用 ----

  private scheduleImeForMenu(): void {
    if (this.imeActive || this.imeCooldown || this.imeActivateTimer >= 0) {
      return;
    }
    this.imeActivateTimer = setTimeout(() => {
      this.imeActivateTimer = -1;
      if (!this.imeActive && !this.grabNative && !this.imeCooldown) {
        this.activateIme();
      }
    }, IME_ACTIVATE_DELAY_MS);
  }

  private pollGrabbing(): void {
    const b = this.bridge;
    if (b === undefined || b.meowGetGrabbing === undefined) {
      return;
    }
    const want: boolean = b.meowGetGrabbing() !== 0;
    if (want !== this.grabNative) {
      this.grabNative = want;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'grab->%{public}d', want ? 1 : 0);
      if (want && this.imeActive) {
        this.deactivateIme();
      }
      this.setGrab(want);
    }
    if (!want && !this.imeActive) {
      this.scheduleImeForMenu();
    }
  }

  /** 焦点回到 XComponent：若 MC 仍想 grab，按需重锁光标。 */
  onFocusGained(): void {
    this.setGrab(this.grabNative);
  }

  private async setGrab(target: boolean): Promise<void> {
    if (this.grabApplied === target || this.grabBusy) {
      return;
    }
    this.grabBusy = true;
    try {
      if (target) {
        const win = await window.getLastWindow(this.ctx);
        this.winId = win.getWindowProperties().id;
        const b = await this.ensureBridge();
        if (b === undefined || b.lockCursor === undefined) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'lockCursor: bridge/lockCursor unavailable');
          return;
        }
        this.vx = this.frameW / 2;
        this.vy = this.frameH / 2;
        if (this.nativeGrabInput) {
          b.meowGrabReset?.(this.vx, this.vy);
        } else {
          this.sendCursorPos(this.vx, this.vy);
        }
        const rc: number = b.lockCursor(this.winId, false);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'lockCursor windowId=%{public}d rc=%{public}d',
          this.winId, rc);
        if (rc !== 0) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'lockCursor failed, skip hiding pointer');
          return;
        }
        try {
          pointer.setPointerVisibleSync(false);
        } catch (e) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'pointer hide fail: %{public}s', JSON.stringify(e));
        }
        this.grabApplied = true;
      } else {
        try {
          pointer.setPointerVisibleSync(true);
        } catch (e) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'pointer show fail: %{public}s', JSON.stringify(e));
        }
        const b = await this.ensureBridge();
        if (b !== undefined && b.unlockCursor !== undefined && this.winId > 0) {
          const rc: number = b.unlockCursor(this.winId);
          hilog.info(LOG_DOMAIN, LOG_TAG, 'unlockCursor windowId=%{public}d rc=%{public}d',
            this.winId, rc);
        }
        this.grabApplied = false;
      }
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'setGrab fail: %{public}s', JSON.stringify(e));
    } finally {
      this.grabBusy = false;
    }
  }

  // ---- 键盘 / 鼠标 / 滚轮转发 ----

  handleKey(event: KeyEvent): void {
    if (this.imeActive) {
      event.stopPropagation();
      return;
    }
    const kc: number = event.keyCode;
    const modBit: number = keyModFlag(kc);
    const down: boolean = event.type === KeyType.Down;
    if (down) {
      this.cancelPendingReleaseFor(kc);
      if (kc === KeyCode.KEYCODE_ESCAPE && this.grabApplied) {
        this.setGrab(false);
      }
      let action: number = GLFW_PRESS;
      if (this.pressed.has(kc)) {
        // 功能键（F1..F24）在本机物理键盘上会重复投递 Down（历史坑）。F 键多是"开关型"
        // （F3/F5/F11…），MC 对任何一次 Down（含 REPEAT）都会再执行一次动作 —— 实测 F11
        // 一次按下被送两遍 → MC toggle 两次 → 全屏刚进就被弹回。故功能键的重复 Down 直接丢弃。
        if (this.isFunctionKey(kc)) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'fkey dup down dropped kc=%{public}d', kc);
          event.stopPropagation();
          return;
        }
        action = GLFW_REPEAT;
      } else {
        this.pressed.add(kc);
      }
      const gk: number = toGlfwKey(kc);
      if (gk !== 0) {
        this.sendKey(gk, action);
      }
      if (action === GLFW_PRESS && this.grabNative &&
        (gk === GLFW_KEY_T || gk === GLFW_KEY_SLASH)) {
        this.onChatOpeningKey();
      }
      // Text insertion is handled SOLELY by the invisible-IME onChange path
      // (GameWindow TextInput.onChange -> syncImeText -> sendImeChars). Sending
      // the key's unicode here as well duplicated every character in MC (the SDL
      // path had both the XComponent onKeyEvent and the IME onChange active).
      // The key event above still reaches MC for key bindings.
    } else {
      const wasDown: boolean = this.pressed.has(kc);
      if (wasDown) {
        const gk: number = toGlfwKey(kc);
        if (gk !== 0 && this.isFunctionKey(kc)) {
          this.scheduleDeferredRelease(kc, gk);
        } else {
          this.pressed.delete(kc);
          if (gk !== 0) {
            this.sendKey(gk, GLFW_RELEASE);
          }
        }
      }
      if (modBit !== 0) {
        this.pressed.delete(kc);
      }
    }
    event.stopPropagation();
  }

  /**
   * onKeyPreIme 回调：在输入法**之前**截获物理键（官方：按键优先派发给输入法，应用可用
   * onKeyPreIme 提前感知）。把会被输入法吞掉的可打印键另外转发给 MC —— 按键绑定需要 key
   * 事件；返回 false（见 GameWindow）让输入法照常收字符做文本合成 → 绑定与中文 IME 兼得。
   * 仅处理 [32,126] 且无 Ctrl/Alt/Super 组合；其余键/组合仍走 handleImeKey / handleKey，避免双发。
   */
  preImeKey(event: KeyEvent): void {
    const gk: number = toGlfwKey(event.keyCode);
    if (gk < 32 || gk > 126) {
      return;
    }
    const mods: number = this.currentMods();
    if ((mods & (GLFW_MOD_CTRL | GLFW_MOD_ALT | GLFW_MOD_SUPER)) !== 0) {
      return;
    }
    this.sendKey(gk, event.type === KeyType.Down ? GLFW_PRESS : GLFW_RELEASE);
  }

  /** IME 激活期间隐形 TextInput 收到的物理键（详见 notes/09/13、14）。 */
  handleImeKey(event: KeyEvent): void {
    const kc: number = event.keyCode;
    const modBit: number = keyModFlag(kc);
    const down: boolean = event.type === KeyType.Down;
    if (kc === KeyCode.KEYCODE_ESCAPE) {
      if (down) {
        // Esc 必须【永远】转发给 MC：此前只在 imeActive 时经 cancelImeByEsc 转发，一旦处于
        // "IME 未激活但隐形 TextInput 仍持有焦点"的状态，Esc 就被 stopPropagation 吞掉 →
        // 游戏里按 Esc 无反应（打不开暂停菜单）。
        this.sendImeKey(GLFW_KEY_ESCAPE);
        this.cancelImeByEsc();          // 若 IME 激活则去激活（不再重复发 Esc）
      }
      event.stopPropagation();
      return;
    }
    const gk: number = toGlfwKey(kc);
    if (kc === KeyCode.KEYCODE_DEL || kc === KeyCode.KEYCODE_FORWARD_DEL) {
      if (down) {
        if (this.imeText.length === 0 && gk !== 0) {
          this.pressed.add(kc);
          this.sendKey(gk, GLFW_PRESS);
        }
      } else {
        const had: boolean = this.pressed.delete(kc);
        if (had) {
          if (gk !== 0) {
            this.sendKey(gk, GLFW_RELEASE);
          }
        } else if (gk !== 0) {
          const localDeleted: boolean = this.imeLocalDeleted;
          this.imeLocalDeleted = false;
          if (this.imeText.length === 0 && !localDeleted) {
            this.sendImeKey(gk);
          }
        }
      }
      event.stopPropagation();
      return;
    }
    const editingKey: boolean =
      kc === KeyCode.KEYCODE_DPAD_LEFT || kc === KeyCode.KEYCODE_DPAD_RIGHT ||
      kc === KeyCode.KEYCODE_MOVE_HOME || kc === KeyCode.KEYCODE_MOVE_END;
    if (down) {
      this.cancelPendingReleaseFor(kc);
      let action: number = GLFW_PRESS;
      if (this.pressed.has(kc)) {
        // 功能键（F1..F24）在本机物理键盘上会重复投递 Down（历史坑）。F 键多是"开关型"
        // （F3/F5/F11…），MC 对任何一次 Down（含 REPEAT）都会再执行一次动作 —— 实测 F11
        // 一次按下被送两遍 → MC toggle 两次 → 全屏刚进就被弹回。故功能键的重复 Down 直接丢弃。
        if (this.isFunctionKey(kc)) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'fkey dup down dropped kc=%{public}d', kc);
          event.stopPropagation();
          return;
        }
        action = GLFW_REPEAT;
      } else {
        this.pressed.add(kc);
      }
      const mods: number = this.currentMods();
      const combo: boolean = (mods & (GLFW_MOD_CTRL | GLFW_MOD_ALT | GLFW_MOD_SUPER)) !== 0;
      // 可打印键的 key 由 onKeyPreIme（preImeKey，输入法之前截获）另行转发；此处按"纯文本"
      // 抑制以免双发。组合键（Ctrl/Alt/Super）仍走本路径。文本插字仍只经 onChange → char。
      const plainText: boolean = !combo && gk >= 32 && gk <= 126;
      if (gk !== 0 && !editingKey && !plainText) {
        this.sendKey(gk, action);
      }
    } else {
      const wasDown: boolean = this.pressed.has(kc);
      const mods: number = this.currentMods();
      const combo: boolean = (mods & (GLFW_MOD_CTRL | GLFW_MOD_ALT | GLFW_MOD_SUPER)) !== 0;
      const plainText: boolean = !combo && gk >= 32 && gk <= 126;
      const forward: boolean = gk !== 0 && !editingKey && !plainText;
      if (wasDown && forward && this.isFunctionKey(kc)) {
        this.scheduleDeferredRelease(kc, gk);
      } else if (wasDown) {
        this.pressed.delete(kc);
        if (forward) {
          this.sendKey(gk, GLFW_RELEASE);
        }
      } else if (modBit !== 0) {
        this.pressed.delete(kc);
      }
    }
    event.stopPropagation();
  }

  /** !grab：XComponent 本地坐标(vp) → MC framebuffer 像素绝对坐标。 */
  private sendAbsCursor(x: number, y: number): void {
    const cw: number = this.xcVpW > 0 ? this.xcVpW : this.frameW;
    const ch: number = this.xcVpH > 0 ? this.xcVpH : this.frameH;
    let rx: number = cw > 0 ? x / cw : 0;
    let ry: number = ch > 0 ? y / ch : 0;
    if (rx < 0) {
      rx = 0;
    } else if (rx > 1) {
      rx = 1;
    }
    if (ry < 0) {
      ry = 0;
    } else if (ry > 1) {
      ry = 1;
    }
    this.sendCursorPos(Math.round(rx * this.frameW), Math.round(ry * this.frameH));
  }

  handleMouse(event: MouseEvent): void {
    if (event.action === MouseAction.Press) {
      const gb: number = glfwMouseButton(event.button);
      if (gb >= 0) {
        if (!this.grabNative) {
          this.sendAbsCursor(event.x, event.y);
        }
        this.sendMouseButton(gb, GLFW_PRESS);
        if (!this.grabNative && this.imeActive) {
          this.refocusImeAfterClick();
        }
      }
    } else if (event.action === MouseAction.Release || event.action === MouseAction.CANCEL) {
      const gb: number = glfwMouseButton(event.button);
      if (gb >= 0) {
        this.sendMouseButton(gb, GLFW_RELEASE);
      }
    } else if (event.action === MouseAction.Move) {
      if (this.grabNative) {
        if (!this.nativeGrabInput) {
          const dx: number = event.rawDeltaX ?? 0;
          const dy: number = event.rawDeltaY ?? 0;
          if (dx !== 0 || dy !== 0) {
            this.vx += dx * CURSOR_SENS;
            this.vy += dy * CURSOR_SENS;
            this.sendCursorPos(this.vx, this.vy);
          }
        }
      } else {
        this.pushMouseMap(event);
        if (!this.filterActive) {
          this.sendAbsCursor(event.x, event.y);
        }
      }
    }
    event.stopPropagation();
  }

  handleAxis(event: AxisEvent): void {
    if (event.action === AxisAction.UPDATE) {
      const v: number = event.getVerticalAxisValue();
      const h: number = event.getHorizontalAxisValue();
      if (v !== 0) {
        // ArkUI 轴值单位 vp，一格滚轮远大于 1 → 归一化到 ±1/格，再乘高级选项的速度倍率。
        this.pushScroll(0, (-v / SCROLL_VP_PER_NOTCH) * this.scrollScale); // 正=向下 -> GLFW +y=向上
      }
      if (h !== 0) {
        this.pushScroll((-h / SCROLL_VP_PER_NOTCH) * this.scrollScale, 0); // 水平：负向左
      }
    }
    event.propagation();
  }

  /** 滚轮累计发射：把归一化后的增量累计到整数"格"再下发（native ring 为 int，会截断小数）。 */
  private pushScroll(dx: number, dy: number): void {
    this.scrollAccX += dx;
    this.scrollAccY += dy;
    const ix = Math.trunc(this.scrollAccX);
    const iy = Math.trunc(this.scrollAccY);
    if (ix !== 0 || iy !== 0) {
      this.scrollAccX -= ix;
      this.scrollAccY -= iy;
      this.sendScroll(ix, iy);
    }
  }

  /** 用 ArkUI 事件换算组件左上角的 display 像素偏移并下发（filter 直通用）。 */
  private pushMouseMap(event: MouseEvent): void {
    const b = this.bridge;
    if (b === undefined || b.mouseFilterStart === undefined) {
      return;
    }
    const nowMs = Date.now();
    if (nowMs - this.mapLastMs < 100) {
      return;
    }
    this.mapLastMs = nowMs;
    const s: number = this.renderScale > 0 ? this.renderScale : 1;
    const sx = this.xcVpW > 0 ? this.frameW / this.xcVpW : 1;
    const sy = this.xcVpH > 0 ? this.frameH / this.xcVpH : 1;
    // 组件布局为 1/S、视觉经 .scale(S) 放大 → displayX = 原点 + S·event.x，故须用 S·event.x 反算原点；
    // 直接用 event.x 会让原点随指针漂移 → native filter 频闪。S=1 时与原公式逐位一致。
    const ox = (event.displayX - s * event.x) * sx;
    const oy = (event.displayY - s * event.y) * sy;
    if (this.filterActive && Math.abs(ox - this.mapOx) < 0.5 &&
      Math.abs(oy - this.mapOy) < 0.5) {
      return;
    }
    this.mapOx = ox;
    this.mapOy = oy;
    const apply = (wid: number): void => {
      const rc = b.mouseFilterStart?.(wid, ox, oy, s) ?? -1;
      if (rc === 0 && !this.filterActive) {
        this.filterActive = true;
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'pushMouseMap active win=%{public}d ox=%{public}d oy=%{public}d',
          wid, Math.round(ox), Math.round(oy));
      }
    };
    if (this.filterWinId > 0) {
      apply(this.filterWinId);
    } else {
      window.getLastWindow(this.ctx).then((w: window.Window) => {
        this.filterWinId = w.getWindowProperties().id;
        apply(this.filterWinId);
      }).catch((e: Error) => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'pushMouseMap win err: %{public}s',
          JSON.stringify(e.message));
      });
    }
  }

  /** 鼠标点击后把焦点还给隐形 TextInput（防 focusOnTouch 抢焦；IME 态专用）。 */
  private refocusImeAfterClick(): void {
    setTimeout(() => {
      if (!this.imeActive) {
        return;
      }
      this.focus('ime-input');
    }, 10);
  }

  /** 补发全部按住键的 UP（action 0），然后清空 pressed。 */
  releaseAllKeysUp(): void {
    const b = this.bridge;
    if (b === undefined || b.meowSendKey === undefined || this.pressed.size === 0) {
      this.pressed.clear();
      return;
    }
    const released: number[] = [];
    for (const kc of this.pressed) {
      const gk: number = toGlfwKey(kc);
      if (gk !== 0) {
        released.push(gk);
      }
    }
    for (const gk of released) {
      b.meowSendKey(gk, 0, 0, 0);
    }
    this.pressed.clear();
  }

  /** 生命周期兜底：解锁 + 显示指针 + 全部按键 UP（防卡键）。 */
  private cleanupInput(): void {
    this.clearImeActivateTimer();
    this.chatOpening = false;
    if (this.imeCooldownTimer >= 0) {
      clearTimeout(this.imeCooldownTimer);
      this.imeCooldownTimer = -1;
    }
    this.imeCooldown = false;
    if (this.imeActive) {
      this.imeActive = false;
      this.imeLast = '';
      this.setImeText('');
      this.imeLocalDeleted = false;
    }
    this.grabNative = false;
    if (this.grabApplied) {
      this.grabApplied = false;
      try {
        pointer.setPointerVisibleSync(true);
      } catch (e) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'cleanup pointer show fail: %{public}s', JSON.stringify(e));
      }
      const b = this.bridge;
      if (b !== undefined && b.unlockCursor !== undefined && this.winId > 0) {
        try {
          const rc: number = b.unlockCursor(this.winId);
          hilog.info(LOG_DOMAIN, LOG_TAG, 'cleanup unlockCursor rc=%{public}d', rc);
        } catch (e) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'cleanup unlock fail: %{public}s', JSON.stringify(e));
        }
      }
    }
    this.releaseAllKeysUp();
  }
}
