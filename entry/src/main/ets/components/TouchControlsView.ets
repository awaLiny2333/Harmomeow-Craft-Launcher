import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { TOUCH_CONTROL_BUTTON_SIZE, TOUCH_CONTROL_GAP, TOUCH_CONTROL_BG,
  TOUCH_CONTROL_BORDER_RADIUS, TOUCH_CONTROLS_INSET_DEFAULT } from '../common/constants/Constants';
import { GLFW_KEY_SPACE, GLFW_KEY_ESCAPE, GLFW_KEY_T, GLFW_MOUSE_BUTTON_1,
  GLFW_MOUSE_BUTTON_2 } from '../common/input/GlfwInput';
import { GameInputController } from '../common/input/GameInputController';
import { SettingsTools } from '../common/data/SettingsTools';

// GlfwInput.ets 未导出的 GLFW 键码（26.3 源码实测；与 GlfwInput 同一数值空间）。
const GLFW_KEY_W: number = 87;
const GLFW_KEY_A: number = 65;
const GLFW_KEY_S: number = 83;
const GLFW_KEY_D: number = 68;
const GLFW_KEY_E: number = 69;
const GLFW_KEY_LEFT_SHIFT: number = 340;

// 虚拟滚轮格方向：数值即 GLFW yoffset 符号（工程约定：正 = 向上滚 = GLFW +y，见 GameInputController.handleAxis）。
// 左键 = 下一个物品（等价鼠标向上滚）= 正；右键 = 前一个物品（等价鼠标向下滚）= 负。
const SCROLL_NOTCH_PREV: number = -1;
const SCROLL_NOTCH_NEXT: number = 1;

// 按键文字基准字号（vp）：实际字号 = 基准 × 整体缩放比，随按键边长等比缩放。
const TOUCH_CONTROL_LABEL_FONT_SIZE: number = 14;

// 八向方向键：每格 = 组合里每个键的 GLFW 码（按下时全按、抬起时全抬）。
const DIR_UP: number[] = [GLFW_KEY_W];
const DIR_DOWN: number[] = [GLFW_KEY_S];
const DIR_LEFT: number[] = [GLFW_KEY_A];
const DIR_RIGHT: number[] = [GLFW_KEY_D];
const DIR_UP_LEFT: number[] = [GLFW_KEY_W, GLFW_KEY_A];
const DIR_UP_RIGHT: number[] = [GLFW_KEY_W, GLFW_KEY_D];
const DIR_DOWN_LEFT: number[] = [GLFW_KEY_A, GLFW_KEY_S];
const DIR_DOWN_RIGHT: number[] = [GLFW_KEY_D, GLFW_KEY_S];

// 无方向：抬手后释放到的状态（也是 resolveDir 于中心格 / 中心死区的返回，语义为「保持当前」）。
const DIR_NONE: number[] = [];

// 方向网格几何（vp）：单格边长与格间距取统一常量，整块 3x3（步进 / 整块边长 / 中心 / 死区）
// 全部由它们派生，见组件实例字段；实际值再乘整体缩放百分比，不写死数字。

// 3x3 八向映射：行优先（上 / 中 / 下 行 x 左 / 中 / 右 列），中心格为 DIR_NONE。
const DIR_GRID: number[][] = [
  DIR_UP_LEFT, DIR_UP, DIR_UP_RIGHT,
  DIR_LEFT, DIR_NONE, DIR_RIGHT,
  DIR_DOWN_LEFT, DIR_DOWN, DIR_DOWN_RIGHT
];

// 八向扇区：每 45° 一扇区，扇区中心依次为正右、右下、正下、左下、正左、左上、正上、右上。
// 屏幕坐标 y 向下，故按极角 atan2(dy, dx) 从正右起顺时针排列，与视觉绕动方向一致。
const DIR_OCTANTS: number[][] = [
  DIR_RIGHT, DIR_DOWN_RIGHT, DIR_DOWN, DIR_DOWN_LEFT,
  DIR_LEFT, DIR_UP_LEFT, DIR_UP, DIR_UP_RIGHT
];
const DIR_SECTOR_STEP: number = Math.PI / 4;

// 扇区边界滞回（5°，即 PI/36）：绕动换向时，越过扇区边界还需再外移这一段才切换，
// 抑制触点停在边界附近时相邻两向之间反复横跳。
const DIR_ANGLE_HYSTERESIS: number = Math.PI / 36;

/**
 * 方向数组内容等价判断（V2 @Local 对数组做可观察包装，读回的可能是代理对象，
 * 直接 `===` 不可靠；方向集合互不相同，按内容比较即可当身份用）。
 */
function sameDir(a: number[], b: number[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'TouchControls';

/** 排除区自证日志开关（仅用于人工核对 display px 换算；默认关，需要排查时临时置 true）。 */
const TOUCH_EXCLUDE_DEBUG: boolean = false;
/** 布局/偏移变化后合并上报的防抖（ms）。 */
const TOUCH_EXCLUDE_REPORT_MS: number = 50;

/*
 * 排除区上报（display px）的坐标系说明（自证点）：
 * - native touch filter 拿到的 dx,dy = OH_Input_GetTouchEventDisplayX/Y，是**屏幕物理 px**；
 * - ArkUI TouchObject.displayX/Y 是**屏幕 vp**，windowX/Y 是**窗口内 vp** ⇒ 窗口原点
 *   vp 偏移 = display - window（浮窗模式下非 0）；
 * - Area.globalPosition 是窗口内 vp。
 * 故：按钮 display 物理 px = (globalPosition_vp + 窗口原点_vp) * vp2px(1)。
 * 命中判断在 native 直接用 dx,dy 比，无需再换算；日志并列打出「按钮矩形 px」与
 * 「真实触摸 display px」，触摸落在按钮上时前者应包含后者。
 */
function excludeRectCsv(rectDpX: number, rectDpY: number, w: number, h: number): string {
  return Math.round(rectDpX).toString() + ',' + Math.round(rectDpY).toString() + ',' +
    Math.round(w).toString() + ',' + Math.round(h).toString();
}

/** 一个虚拟按键触摸区的原始布局矩形（窗口内 vp）与换算前的缓存。 */
class RegionRect {
  gx: number = 0;
  gy: number = 0;
  w: number = 0;
  h: number = 0;
  valid: boolean = false;
}

// 需要排除的触摸区数量：0 方向键网格、1 右下动作键簇（含背包）、2/3 顶部暂停/输入。
const EXCLUDE_REGION_COUNT: number = 4;

/**
 * 虚拟触屏按键覆盖层（游戏画面上的半透明按钮）。
 *
 * 布局：所有键统一为一个方块边长 + 一个间隔，再乘「整体缩放」百分比；屏幕分区锚点，
 * 刻意不用百分比 / 自适应拉伸 —— 窗口 resize 或折叠屏动态切换时按钮物理大小不变，
 * 只随锚点（左下 / 右下 / 上中）重新贴合屏幕边角。
 * 分区：左下 3x3 八向方向键（中格留空），右下 3x3 动作区（上两行左格留空、右对齐，第三行 包 / 左 / 右），
 * 上区中间 暂停 / 输入（同为方块，不再用矮条）。
 *
 * 交互：方向键整块 3x3 当作一个触摸区，一次 onTouch 挂在网格容器上。触点在网格内时按就近格判定；
 * 滑出网格后按触点到网格中心的向量极角量化到最近八向（像摇杆一样绕动持续换向）。中心格内不改变
 * 当前方向，只有抬手（Up / Cancel）才释放、停下。方向只认「按下时落在网格的那根手指」（记 finger id），
 * 不取全屏任意触点，避免同时按住动作 / 跳跃键时取错手指。
 * 动作 / 顶部键仍各自 onTouch；Down 按下、Up / Cancel 抬起（手指滑出也收到 Up/Cancel）→ 绝不粘键。
 * 滚轮键（左 / 右）另走 onScroll 回调：按下发一格（不连发），不经键鼠原语。
 * 按下高亮：方向格由 activeDir 引用相等判定（滑到哪亮到哪，滑出网格绕动时高亮跟着在八格间跳，抬手才全灭）；
 * 动作 / 顶部键各自独立记录 pressedCodes，Down 置位、Up / Cancel 复位，底色换成主题色 brand 表示按下。
 * 键 / 鼠标原语经 onVirtual 回调转交 GameInputController.pressVirtual（同一套桥原语）。
 * 渲染由 GameWindow 按设置 touchControls 控制，本组件不做开关判断。
 *
 * 另：本组件把「所有虚拟按键的矩形」换算成 display px 上报给 GameInputController，
 * 使按在按键上的手指只触发按键、不再同时驱动 MC 光标/点击（其它手指照常）。
 */
@ComponentV2
export struct TouchControlsView {
  /** 虚拟按键转发回调：code 为 GLFW 键码（isMouse=true 时为 GLFW 鼠标键码）。 */
  @Param onVirtual: (code: number, isMouse: boolean, down: boolean) => void = () => {
  };

  /** 虚拟滚轮转发回调：notches 为格数，符号沿用 GLFW 约定（正 = 向上，负 = 向下）。 */
  @Param onScroll: (notches: number) => void = () => {
  };

  /** 当前按下中的方向（引用 DIR_GRID 里某一项，DIR_NONE 表示无方向）。 */
  @Local private activeDir: number[] = DIR_NONE;

  /** 各独立按键（右下七个 + 顶部两个）当前按下的 GLFW 键码，仅用于高亮。 */
  @Local private pressedCodes: number[] = [];

  /** 滚轮按键（右下左 / 右）当前按下的格数（+1 上 / -1 下），仅用于高亮。 */
  @Local private pressedScroll: number[] = [];

  // 覆盖层四边内边距（vp）：挂载时从全局设置读一次（与其它设置一致，改后重开窗生效）。
  // 默认 12 = 原先写死的 LAYOUT_PADDING，默认行为与现状逐像素一致。
  @Local private insetTop: number = TOUCH_CONTROLS_INSET_DEFAULT;
  @Local private insetRight: number = TOUCH_CONTROLS_INSET_DEFAULT;
  @Local private insetBottom: number = TOUCH_CONTROLS_INSET_DEFAULT;
  @Local private insetLeft: number = TOUCH_CONTROLS_INSET_DEFAULT;

  // 实际渲染几何（vp）：基准边长 / 间隔统一后，再乘整体缩放百分比；挂载时算一次。
  /** 实际单键边长（vp）= 基准边长 × 缩放比。 */
  private buttonSize: number = TOUCH_CONTROL_BUTTON_SIZE;
  /** 实际键间距（vp）= 基准间隔 × 缩放比。 */
  private gap: number = TOUCH_CONTROL_GAP;
  /** 实际按键文字字号（vp）= 基准字号 × 缩放比。 */
  private buttonFont: number = TOUCH_CONTROL_LABEL_FONT_SIZE;
  /** 实际按键圆角（vp）= 基准圆角 × 缩放比。 */
  private buttonRadius: number = TOUCH_CONTROL_BORDER_RADIUS;
  /** 3x3 方向网格单格步进（vp）= 单键边长 + 间隔。 */
  private dirGridStride: number = TOUCH_CONTROL_BUTTON_SIZE + TOUCH_CONTROL_GAP;
  /** 3x3 方向网格整块边长（vp）= 3 键 + 2 间隔。 */
  private dirGridSize: number = TOUCH_CONTROL_BUTTON_SIZE * 3 + TOUCH_CONTROL_GAP * 2;
  /** 网格中心（vp）：以网格容器左上角为原点，网格外触点判向的向量参考点。 */
  private dirGridCenter: number = 0;
  /** 正在服务的方向手指 id（-1 = 无）：只认按下时落在网格的那根，避免取到全屏其它手指。 */
  private dirFingerId: number = -1;

  /** 各触摸区原始布局矩形（窗口内 vp）。 */
  private regions: RegionRect[] = [];
  /** 窗口原点在屏幕上的 vp 偏移（display - window），首次触摸后标定。 */
  private winOffX: number = 0;
  private winOffY: number = 0;
  private winOffKnown: boolean = false;
  /** 排除区上报防抖定时器（-1 = 空闲）。 */
  private reportTimer: number = -1;

  aboutToAppear(): void {
    for (let i = 0; i < EXCLUDE_REGION_COUNT; i++) {
      this.regions.push(new RegionRect());
    }
    // 覆盖层四边内边距（vp）：挂载时读一次全局设置；改动需重开游戏窗口生效。
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const s = new SettingsTools(ctx);
    this.insetTop = s.touchControlsInsetTop();
    this.insetRight = s.touchControlsInsetRight();
    this.insetBottom = s.touchControlsInsetBottom();
    this.insetLeft = s.touchControlsInsetLeft();
    // 整体缩放：只作用于按键边长与间隔，四边内边距独立不缩放；改动需重开游戏窗口生效。
    const factor = s.touchControlsScalePercent() / 100;
    this.buttonSize = TOUCH_CONTROL_BUTTON_SIZE * factor;
    this.gap = TOUCH_CONTROL_GAP * factor;
    this.buttonFont = TOUCH_CONTROL_LABEL_FONT_SIZE * factor;
    this.buttonRadius = TOUCH_CONTROL_BORDER_RADIUS * factor;
    this.dirGridStride = this.buttonSize + this.gap;
    this.dirGridSize = this.buttonSize * 3 + this.gap * 2;
    this.dirGridCenter = this.dirGridSize / 2;
  }

  aboutToDisappear(): void {
    if (this.reportTimer >= 0) {
      clearTimeout(this.reportTimer);
      this.reportTimer = -1;
    }
    // 组件消失：把本组件按下过的方向 / 独立键全部释放，清高亮并复位手指跟踪，绝不粘键。
    this.releaseAll();
    // 覆盖层隐藏/关闭：清空排除区，避免残留导致游戏区误排除。
    GameInputController.setTouchExcludeRects('');
  }

  /** 释放本组件所有按下态：方向键 + 独立键（滚轮键无键原语，只清高亮）。 */
  private releaseAll(): void {
    this.emit(this.activeDir, false, false);
    this.activeDir = DIR_NONE;
    for (const code of this.pressedCodes) {
      this.onVirtual(code, false, false);
    }
    this.pressedCodes = [];
    this.pressedScroll = [];
    this.dirFingerId = -1;
  }

  /** 组合键统一派发（方向键一次可含多个键）。 */
  private emit(codes: number[], isMouse: boolean, down: boolean): void {
    for (const code of codes) {
      this.onVirtual(code, isMouse, down);
    }
  }

  /** 某独立按键当前是否按下（高亮用，与 activeDir 无关）。 */
  private isPressed(code: number): boolean {
    return this.pressedCodes.includes(code);
  }

  /** 独立维护单个按键的按下态：换新数组赋值以保证 V2 刷新；相同状态不改动。 */
  private setPressed(code: number, down: boolean): void {
    const index: number = this.pressedCodes.indexOf(code);
    if (down && index < 0) {
      const next: number[] = this.pressedCodes.slice();
      next.push(code);
      this.pressedCodes = next;
    } else if (!down && index >= 0) {
      const next: number[] = this.pressedCodes.slice();
      next.splice(index, 1);
      this.pressedCodes = next;
    }
  }

  /** 滚轮按键当前是否按下（高亮用）。 */
  private isScrollPressed(notches: number): boolean {
    return this.pressedScroll.includes(notches);
  }

  /** 独立维护滚轮按键的按下态：换新数组赋值以保证 V2 刷新；相同状态不改动。 */
  private setScrollPressed(notches: number, down: boolean): void {
    const index: number = this.pressedScroll.indexOf(notches);
    if (down && index < 0) {
      const next: number[] = this.pressedScroll.slice();
      next.push(notches);
      this.pressedScroll = next;
    } else if (!down && index >= 0) {
      const next: number[] = this.pressedScroll.slice();
      next.splice(index, 1);
      this.pressedScroll = next;
    }
  }

  private onButtonTouch(codes: number[], isMouse: boolean, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.setPressed(codes[0], true);
      this.emit(codes, isMouse, true);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.setPressed(codes[0], false);
      this.emit(codes, isMouse, false);
    }
  }

  /** 滚轮按键：按下发一格（不连发），抬手 / 取消恢复高亮，绝不粘。 */
  private onScrollTouch(notches: number, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.setScrollPressed(notches, true);
      this.onScroll(notches);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.setScrollPressed(notches, false);
    }
  }

  /** 在本次事件的全部触点里找正在服务的方向手指；找不到说明它已离开本组件。 */
  private findDirFinger(event: TouchEvent): TouchObject | undefined {
    for (let i = 0; i < event.touches.length; i++) {
      if (event.touches[i].id === this.dirFingerId) {
        return event.touches[i];
      }
    }
    return undefined;
  }

  /** 本次抬起 / 取消的触点里是否含正在服务的方向手指。 */
  private isDirFingerUp(event: TouchEvent): boolean {
    for (let i = 0; i < event.changedTouches.length; i++) {
      if (event.changedTouches[i].id === this.dirFingerId) {
        return true;
      }
    }
    return false;
  }

  /**
   * 方向手指落点 → 方向：网格内按就近格判定（空隙归最近格）；网格外按触点到网格中心的
   * 向量极角量化到最近八向。网格外不做死区：出网格后离中心至少半块，中心死区本就不可达。
   */
  private resolveDir(t: TouchObject): number[] {
    const x: number = t.x;
    const y: number = t.y;
    if (x >= 0 && y >= 0 && x < this.dirGridSize && y < this.dirGridSize) {
      return this.gridDirAt(x, y);
    }
    return this.dirOutsideGrid(x, y);
  }

  /** 网格内触点 → 就近格方向：比较 9 个格中心取最近者，格间空隙归最近格（避免 floor 把空隙计入前一格）。 */
  private gridDirAt(x: number, y: number): number[] {
    let best: number = 0;
    let bestDist: number = Number.POSITIVE_INFINITY;
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        const dx: number = x - (c * this.dirGridStride + this.buttonSize / 2);
        const dy: number = y - (r * this.dirGridStride + this.buttonSize / 2);
        const d: number = dx * dx + dy * dy;
        if (d < bestDist) {
          bestDist = d;
          best = r * 3 + c;
        }
      }
    }
    return DIR_GRID[best];
  }

  /** 网格外触点：按与网格中心的向量极角量化到最近八向。 */
  private dirOutsideGrid(x: number, y: number): number[] {
    return this.dirFromVector(x - this.dirGridCenter, y - this.dirGridCenter);
  }

  /**
   * 向量极角 → 八向：idx = round(atan2(dy, dx) / (PI/4)) mod 8，查 DIR_OCTANTS。
   * y 向下 → 正角为顺时针，故 0=正右、1=右下、…、7=右上。避免边界抖动：当就近扇区与当前
   * 方向不同、但角度距当前扇区中心仍不足「半扇区 + 5°」时返回当前方向（滞回），否则用就近扇区。
   */
  private dirFromVector(dx: number, dy: number): number[] {
    const angle: number = Math.atan2(dy, dx);
    let idx: number = Math.round(angle / DIR_SECTOR_STEP);
    idx = ((idx % 8) + 8) % 8;
    const cur: number = this.activeDirIndex();
    if (cur >= 0 && idx !== cur) {
      let diff: number = angle - cur * DIR_SECTOR_STEP;
      while (diff > Math.PI) {
        diff -= Math.PI * 2;
      }
      while (diff < -Math.PI) {
        diff += Math.PI * 2;
      }
      if (Math.abs(diff) < DIR_SECTOR_STEP / 2 + DIR_ANGLE_HYSTERESIS) {
        return DIR_OCTANTS[cur];
      }
    }
    return DIR_OCTANTS[idx];
  }

  /** 当前 activeDir 在八向表中的下标；不在八向（含 DIR_NONE）返回 -1，表示无滞回基准。 */
  private activeDirIndex(): number {
    for (let i = 0; i < DIR_OCTANTS.length; i++) {
      if (sameDir(DIR_OCTANTS[i], this.activeDir)) {
        return i;
      }
    }
    return -1;
  }

  /** 方向变化才动作：先释放旧方向全部键，再按下新方向全部键；相同则忽略。 */
  private switchDir(next: number[]): void {
    if (sameDir(next, this.activeDir)) {
      return;
    }
    this.emit(this.activeDir, false, false);
    this.activeDir = next;
    this.emit(next, false, true);
  }

  private onDirGridTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      // 只在没有正在服务的方向手指时接纳新手指：多指同按网格以先按下的那根为准。
      if (this.dirFingerId < 0 && event.changedTouches.length > 0) {
        this.dirFingerId = event.changedTouches[0].id;
      }
      this.updateDirFromFinger(event);
    } else if (event.type === TouchType.Move) {
      this.updateDirFromFinger(event);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // 只有正在服务的那根手指抬起才释放方向；别的格手指抬手不影响当前方向。
      if (this.isDirFingerUp(event)) {
        this.releaseDir();
      }
    }
  }

  /** 用正在服务的方向手指更新方向；该手指已不在本次触点里 ⇒ 视为离开，释放方向。 */
  private updateDirFromFinger(event: TouchEvent): void {
    const t: TouchObject | undefined = this.findDirFinger(event);
    if (t === undefined) {
      this.releaseDir();
      return;
    }
    const next: number[] = this.resolveDir(t);
    // DIR_NONE = 中心格：保持当前方向不动；只有抬手才停。
    if (!sameDir(next, DIR_NONE)) {
      this.switchDir(next);
    }
  }

  /** 释放方向并把手指跟踪复位（抬手 / 取消 / 消失共用）。 */
  private releaseDir(): void {
    this.dirFingerId = -1;
    this.switchDir(DIR_NONE);
  }

  /** 覆盖层根节点 onTouch：标定窗口原点偏移 + 自证日志（不消费事件，游戏照常收到）。 */
  private onOverlayTouch(event: TouchEvent): void {
    const t: TouchObject | undefined = event.touches.length > 0 ? event.touches[0] : undefined;
    if (t === undefined) {
      return;
    }
    const ox: number = t.displayX - t.windowX;
    const oy: number = t.displayY - t.windowY;
    if (Number.isFinite(ox) && Number.isFinite(oy)) {
      if (!this.winOffKnown || Math.abs(ox - this.winOffX) > 0.5 ||
        Math.abs(oy - this.winOffY) > 0.5) {
        this.winOffX = ox;
        this.winOffY = oy;
        this.winOffKnown = true;
        this.scheduleReport();
      }
    }
    if (TOUCH_EXCLUDE_DEBUG && event.type === TouchType.Down) {
      this.debugLogTouch(t);
    }
  }

  /** 记录某个触摸区的布局矩形并触发上报（与上一版相同则跳过，避免重复）。 */
  private onRegionArea(index: number, oldArea: Area, newArea: Area): void {
    if (index < 0 || index >= this.regions.length) {
      return;
    }
    const w: number = Number(newArea.width);
    const h: number = Number(newArea.height);
    const gx: number = Number(newArea.globalPosition.x);
    const gy: number = Number(newArea.globalPosition.y);
    if (!(w > 0) || !(h > 0) || !Number.isFinite(gx) || !Number.isFinite(gy)) {
      return;
    }
    if (Number(oldArea.width) === w && Number(oldArea.height) === h &&
      Number(oldArea.globalPosition.x) === gx && Number(oldArea.globalPosition.y) === gy) {
      return;
    }
    const r: RegionRect = this.regions[index];
    r.gx = gx;
    r.gy = gy;
    r.w = w;
    r.h = h;
    r.valid = true;
    this.scheduleReport();
  }

  /** 合并短时间内的多次布局变化，只上报一次。 */
  private scheduleReport(): void {
    if (this.reportTimer >= 0) {
      return;
    }
    this.reportTimer = setTimeout(() => {
      this.reportTimer = -1;
      /* 手势进行中不上报：native 侧"重设排除区"会刷新快照，若此刻有手指正按在按钮上，
       * 这条手势的排除状态会被打断（曾表现为"按虚拟键同时动视角 / 划视角乱飞"）。
       * 延后到抬手之后再报。 */
      if (this.dirFingerId >= 0 || this.pressedCodes.length > 0 || this.pressedScroll.length > 0) {
        this.scheduleReport();
        return;
      }
      const csv: string = this.buildCsv();
      /* 空串 = 还没有任何"有效"区域（布局未就绪 / 尺寸未量到）。
       * 绝不能把它当"清空"上报：那会把上一次的好矩形抹掉，于是按虚拟键会同时
       * 驱动"触屏当鼠标"光标，并让之后的拖动从按钮坐标算增量（视角乱飞）。
       * 真正的"清空"由关闭覆盖层时的显式调用负责。 */
      if (csv.length === 0) {
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'touch exclude rects: %{public}s', csv);
      GameInputController.setTouchExcludeRects(csv);
    }, TOUCH_EXCLUDE_REPORT_MS);
  }

  /** 所有有效触摸区 → display px CSV（窗口原点偏移 + vp2px）。 */
  private buildCsv(): string {
    const d: number = this.getUIContext().vp2px(1);
    const parts: string[] = [];
    for (let i = 0; i < this.regions.length; i++) {
      const r: RegionRect = this.regions[i];
      if (!r.valid || r.w <= 0 || r.h <= 0) {
        continue;
      }
      const x: number = (r.gx + this.winOffX) * d;
      const y: number = (r.gy + this.winOffY) * d;
      parts.push(excludeRectCsv(x, y, r.w * d, r.h * d));
    }
    return parts.join(';');
  }

  /** 自证日志：把算出的各按钮矩形（display px）与一次真实触摸的 display px 并列打出。 */
  private debugLogTouch(t: TouchObject): void {
    const d: number = this.getUIContext().vp2px(1);
    const tx: number = t.displayX * d;
    const ty: number = t.displayY * d;
    let hit: number = -1;
    for (let i = 0; i < this.regions.length; i++) {
      const r: RegionRect = this.regions[i];
      if (!r.valid) {
        continue;
      }
      const rx: number = (r.gx + this.winOffX) * d;
      const ry: number = (r.gy + this.winOffY) * d;
      if (tx >= rx && tx < rx + r.w * d && ty >= ry && ty < ry + r.h * d) {
        hit = i;
        break;
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'excl-dbg touch displayPx=(%{public}d,%{public}d) winOffVp=(%{public}d,%{public}d) hitRegion=%{public}d csv=[%{public}s]',
      Math.round(tx), Math.round(ty), Math.round(this.winOffX), Math.round(this.winOffY), hit,
      this.buildCsv());
  }

  /** 方向格：仅当本格方向正是当前 activeDir 时高亮（整网格一处 onTouch，滑到哪亮到哪；滑出网格保留）。 */
  @Builder
  private dirButton(label: Resource, dir: number[]): void {
    Text(label)
      .width(this.buttonSize)
      .height(this.buttonSize)
      .fontSize(this.buttonFont)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .backgroundColor(sameDir(this.activeDir, dir) ? $r('app.color.brand') : TOUCH_CONTROL_BG)
      .borderRadius(this.buttonRadius)
      .hitTestBehavior(HitTestMode.None);
  }

  @Builder
  private actionButton(code: number, isMouse: boolean, label: Resource): void {
    Text(label)
      .width(this.buttonSize)
      .height(this.buttonSize)
      .fontSize(this.buttonFont)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.isPressed(code) ? $r('app.color.brand') : TOUCH_CONTROL_BG)
      .borderRadius(this.buttonRadius)
      .onTouch((event: TouchEvent) => {
        this.onButtonTouch([code], isMouse, event);
      });
  }

  /** 网格空位：仅按统一单键尺寸占位（透明、无背景、不参与命中），补齐 3x3 骨架，非可见方块。 */
  @Builder
  private emptyCell(): void {
    Column()
      .width(this.buttonSize)
      .height(this.buttonSize)
      .hitTestBehavior(HitTestMode.None);
  }

  @Builder
  private scrollButton(notches: number, label: Resource): void {
    Text(label)
      .width(this.buttonSize)
      .height(this.buttonSize)
      .fontSize(this.buttonFont)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.isScrollPressed(notches) ? $r('app.color.brand') : TOUCH_CONTROL_BG)
      .borderRadius(this.buttonRadius)
      .onTouch((event: TouchEvent) => {
        this.onScrollTouch(notches, event);
      });
  }

  @Builder
  private topButton(code: number, label: Resource, regionIndex: number): void {
    Text(label)
      .width(this.buttonSize)
      .height(this.buttonSize)
      .fontSize(this.buttonFont)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.isPressed(code) ? $r('app.color.brand') : TOUCH_CONTROL_BG)
      .borderRadius(this.buttonRadius)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.onRegionArea(regionIndex, oldValue, newValue);
      })
      .onTouch((event: TouchEvent) => {
        this.onButtonTouch([code], false, event);
      });
  }

  build() {
    Stack() {
      Column() {
        // 上区中间：暂停 / 输入（水平居中）。
        Row({ space: this.gap }) {
          this.topButton(GLFW_KEY_ESCAPE, $r('app.string.touch_btn_pause'), 2);
          this.topButton(GLFW_KEY_T, $r('app.string.touch_btn_chat'), 3);
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None);

        // 中间留白撑开上下两区（自身不参与命中，保证空处事件透传给游戏）。
        Column()
          .width('100%')
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None);

        // 下区：左下方向键 + 右下动作键，两端锚定。
        Row() {
          Column({ space: this.gap }) {
            Row({ space: this.gap }) {
              this.dirButton($r('app.string.touch_dir_up_left'), DIR_UP_LEFT);
              this.dirButton($r('app.string.touch_dir_up'), DIR_UP);
              this.dirButton($r('app.string.touch_dir_up_right'), DIR_UP_RIGHT);
            }

            Row({ space: this.gap }) {
              this.dirButton($r('app.string.touch_dir_left'), DIR_LEFT);
              // 3x3 正中间留空（DIR_NONE，永不参与高亮）。
              Column()
                .width(this.buttonSize)
                .height(this.buttonSize)
                .hitTestBehavior(HitTestMode.None);
              this.dirButton($r('app.string.touch_dir_right'), DIR_RIGHT);
            }

            Row({ space: this.gap }) {
              this.dirButton($r('app.string.touch_dir_down_left'), DIR_DOWN_LEFT);
              this.dirButton($r('app.string.touch_dir_down'), DIR_DOWN);
              this.dirButton($r('app.string.touch_dir_down_right'), DIR_DOWN_RIGHT);
            }
          }
          // 整个 3x3 网格 = 一个触摸区，坐标以本容器为基准。
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.onRegionArea(0, oldValue, newValue);
          })
          .onTouch((event: TouchEvent) => {
            this.onDirGridTouch(event);
          });

          Column()
            .layoutWeight(1)
            .hitTestBehavior(HitTestMode.None);

          // 右下 3x3 动作区：上两行左格空、右对齐；第三行 包 / 左 / 右。
          Column({ space: this.gap }) {
            Row({ space: this.gap }) {
              this.emptyCell();
              this.actionButton(GLFW_MOUSE_BUTTON_1, true, $r('app.string.touch_btn_attack'));
              this.actionButton(GLFW_MOUSE_BUTTON_2, true, $r('app.string.touch_btn_interact'));
            }

            Row({ space: this.gap }) {
              this.emptyCell();
              this.actionButton(GLFW_KEY_SPACE, false, $r('app.string.touch_btn_jump'));
              this.actionButton(GLFW_KEY_LEFT_SHIFT, false, $r('app.string.touch_btn_sneak'));
            }

            Row({ space: this.gap }) {
              this.actionButton(GLFW_KEY_E, false, $r('app.string.touch_btn_inventory'));
              this.scrollButton(SCROLL_NOTCH_NEXT, $r('app.string.touch_btn_hotbar_left'));
              this.scrollButton(SCROLL_NOTCH_PREV, $r('app.string.touch_btn_hotbar_right'));
            }
          }
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.onRegionArea(1, oldValue, newValue);
          })
          .hitTestBehavior(HitTestMode.None);
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Bottom)
        .hitTestBehavior(HitTestMode.None);
      }
      .width('100%')
      .height('100%')
      // 四边内边距（vp）各自生效：默认 12 时与原先 .padding(LAYOUT_PADDING) 完全一致。
      .padding({
        top: this.insetTop,
        right: this.insetRight,
        bottom: this.insetBottom,
        left: this.insetLeft
      })
      .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onTouch((event: TouchEvent) => {
      this.onOverlayTouch(event);
    });
  }
}
