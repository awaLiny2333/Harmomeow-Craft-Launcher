import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { NodeContent, window, display } from '@kit.ArkUI';
import { launchGame } from '../common/data/GameLauncher';
import { JreLibModule, FullscreenRequest } from '../common/state/JvmLauncher';
import { gameLaunchParams } from '../common/state/GameLaunchParams';
import { isLegacyLwjgl, setWindowDisplaySize } from '../common/data/MinecraftLauncher';
import { readAppGlobalSettings } from '../common/data/AppSettings';
import { LAYOUT_SPACE, OVERLAY_BG, LAUNCH_FALLBACK_MS } from '../common/constants/Constants';
import { OPEN_URL_REQUEST_FILE } from '../common/constants/Paths';
import { WINDOW_DEFAULT_W, WINDOW_DEFAULT_H } from '../common/constants/LaunchDefaults';
import { GameInputController } from '../common/input/GameInputController';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameWindow';

/**
 * 游戏独立窗口页（GameAbility 加载）——薄壳。
 *
 * 职责：承载 XComponent 画面 + 隐形 IME 客户端 + 采样率 overlay，并把事件转发给
 * GameInputController；启动编排交给 GameLauncher。所有输入/IME/grab 逻辑在
 * common/input/GameInputController，classpath/账户/JVM 启动在 common/data/*。
 *
 * 时序：onSurfaceCreated → 注入 surfaceId → 启动 JVM（一次）。
 * 启动参数由 GameAbility.onCreate 从 want.parameters 写入 gameLaunchParams 单例。
 */
class GameXComponentController extends XComponentController {
  private onSurfaceReady: (surfaceId: string, w: number, h: number) => void = () => {
  };
  private onSurfaceGone: () => void = () => {
  };

  setSurfaceReadyHandler(h: (surfaceId: string, w: number, h: number) => void): void {
    this.onSurfaceReady = h;
  }

  setSurfaceGoneHandler(h: () => void): void {
    this.onSurfaceGone = h;
  }

  onSurfaceCreated(surfaceId: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onSurfaceCreated %{public}s', surfaceId);
    this.onSurfaceReady(surfaceId, 0, 0);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onSurfaceChanged %{public}s %{public}dx%{public}d',
      surfaceId, rect.surfaceWidth, rect.surfaceHeight);
    this.onSurfaceReady(surfaceId, rect.surfaceWidth, rect.surfaceHeight);
  }

  onSurfaceDestroyed(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onSurfaceDestroyed');
    this.onSurfaceGone();
  }
}

@Entry
@ComponentV2
struct GameWindow {
  private xController: GameXComponentController = new GameXComponentController();
  private launchTriggered: boolean = false;
  /** 启动兜底定时器：等 onSurfaceChanged 尺寸；超时则按默认尺寸启动（-1 = 未启动）。 */
  private launchFallbackTimer: number = -1;
  private requestCloseSent: boolean = false;

  /** meowjre 模块引用（surface 就绪后赋值），供全屏请求轮询使用。 */
  private jrelib: JreLibModule | null = null;
  /** 全屏请求轮询定时器（-1 = 未启动）。 */
  private fsTimer: number = -1;
  private urlTimer: number = -1;

  /** 右下角 overlay：当前鼠标有效采样率（Hz）。 */
  @Local mouseRate: number = 0;
  /** 应用级高级选项：是否显示采样率 overlay（挂载时从应用沙箱全局设置读入）。 */
  @Local showInputRate: boolean = false;
  /** 应用级高级选项：显示缩放 N（渲染分辨率 = 窗口/N；挂载时从应用沙箱全局设置读入，1=关闭）。 */
  @Local renderScale: number = 1;
  /** 隐形 TextInput 文本（绑定 id('ime-input')；由 GameInputController 回写）。 */
  @Local imeText: string = '';

  /** 原生鼠标增量输入：NDK 覆盖节点挂载点（ContentSlot）。 */
  private inputOverlay: NodeContent = new NodeContent();
  /** 输入/IME/grab 控制器（aboutToAppear 创建）。 */
  private input: GameInputController | null = null;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    const ctx = this.context();
    const param = gameLaunchParams;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'aboutToAppear gameRoot=%{public}s id=%{public}s',
      param.gameRoot, param.versionId);
    // 控制器与页面通过 3 个回调解耦：焦点请求 / IME 文本回写 / 采样率回写。
    this.input = new GameInputController(ctx,
      (id: string) => {
        try {
          this.getUIContext().getFocusController().requestFocus(id);
        } catch (e) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'requestFocus %{public}s err: %{public}s', id,
            JSON.stringify(e));
        }
      },
      (v: string) => {
        this.imeText = v;
      },
      (hz: number) => {
        this.mouseRate = hz;
      });
    this.xController.setSurfaceReadyHandler((surfaceId: string, w: number, h: number) => {
      if (w > 0 && h > 0) {
        // 缓存 frame(px) 与 XComponent vp 尺寸：!grab 绝对坐标换算用。
        this.input?.setFrameSize(w, h, this.getUIContext().px2vp(w),
          this.getUIContext().px2vp(h));
      }
      this.injectAndLaunch(ctx, surfaceId, w, h);
    });
    this.xController.setSurfaceGoneHandler(() => {
      // 兜底：解锁 + 显示指针 + 补发按键 UP，再请求 MC 退出。
      this.input?.dispose();
      this.requestCloseGame();
    });
    // 采样率 overlay + 显示缩放（应用级高级选项，读应用沙箱全局设置；XComponent 按 1/S 布局 +
    // .scale(S) 放大；渲染分辨率 = 窗口/S）。
    const gs = readAppGlobalSettings(ctx);
    this.showInputRate = gs.showInputRate;
    this.renderScale = gs.renderScale;
    this.input.setRenderScale(this.renderScale);
    this.input.start(this.showInputRate);
    // 轮询 MC 的全屏切换请求（GLFW stub → native 桥 → 这里驱动真实窗口）：100 ms 保响应。
    this.fsTimer = setInterval(() => {
      this.pollFullscreen();
    }, 100);
    // 打开链接是"用户点一下"的动作 ⇒ 1 s 一次文件 stat 足够；常态零成本（native 侧只在点击时写一次）。
    this.urlTimer = setInterval(() => {
      this.pollOpenUrl();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.fsTimer >= 0) {
      clearInterval(this.fsTimer);
      this.fsTimer = -1;
    }
    if (this.urlTimer >= 0) {
      clearInterval(this.urlTimer);
      this.urlTimer = -1;
    }
    this.input?.dispose();
  }

  /** XComponent surface 销毁后请求 MC 优雅退出（幂等，只发一次）。 */
  private async requestCloseGame(): Promise<void> {
    if (this.requestCloseSent) {
      return;
    }
    this.requestCloseSent = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'surface gone -> request game window close');
    try {
      const jrelib = await import('meowjre') as JreLibModule;
      jrelib.requestGameWindowClose?.();
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'request close fail: %{public}s', JSON.stringify(e));
    }
  }

  /** XComponent surface 就绪后：注入 surfaceId 给自研 meowcraftbridge，然后启动 JVM（一次）。 */
  private async injectAndLaunch(ctx: common.UIAbilityContext, surfaceId: string, w: number,
    h: number): Promise<void> {
    const param = gameLaunchParams;
    if (param.gameRoot.length === 0 || param.jsonPath.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'inject abort: missing launch params');
      return;
    }
    try {
      // 1. 加载 meowjre，先注入 surface（必须在 JVM 启动前）。全链路自研：
      //    meowSetSurfaceId 创建 OH_NativeWindow 写 env+0；meowResizeSurface 同 sid
      //    只标尺寸，由 render 线程 pump diff apply（GL 分支重建 EGL surface；Vulkan 分支
      //    回写 OHNativeWindow geometry），sid 变更才重建窗。
      const jrelib = await import('meowjre') as JreLibModule;
      this.jrelib = jrelib;
      this.input?.setBridge(jrelib);
      // 原生鼠标增量输入：把 ContentSlot 的 NodeContent 交给 native（挂 NDK 覆盖节点）。
      // 控制器内部保证同一 ContentSlot 只绑一次（重复绑会叠加接收器 → 灵敏度爆炸）。
      this.input?.bindOverlay(this.inputOverlay);
      const sid = parseInt(surfaceId, 10);
      if (w > 0 && h > 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'resize surface sid=%{public}d %{public}dx%{public}d',
          sid, w, h);
        jrelib.resizeGameSurface?.(sid, w, h);
      } else {
        // onSurfaceCreated reports 0x0 before the first layout pass. Pass the real (unknown)
        // 0x0 through instead of a fixed fallback: meowSetSurfaceId already guards
        // `width > 0 && height > 0`, so the OHNativeWindow is bound here without pinning a
        // geometry that is unrelated to the display-scale-derived surface size. The real size
        // arrives via onSurfaceChanged -> resizeGameSurface and is written back by the render
        // thread pump (never on this UI thread).
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'set surface sid=%{public}d (size unknown, geometry deferred)', sid);
        jrelib.setGameSurface?.(sid, 0, 0);
      }
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'surface inject fail: %{public}s', JSON.stringify(e));
    }
    // 全屏尺寸取决于我们上报给 LWJGL2 的 DisplayMode（不是 resize 通知），而窗口可能在副屏 ——
    // 在启动前把"窗口所在显示器"的尺寸交给参数组装（A：多显示器）。仅 legacy 需要（避免其它
    // 渲染路径上的无谓 IPC）。
    if (isLegacyLwjgl(param.jsonPath)) {
      try {
        const w = await window.getLastWindow(ctx);
        const props = w.getWindowProperties();
        const did: number = props.displayId ?? display.getDefaultDisplaySync().id;
        const d = display.getDisplayByIdSync(did);
        if (d.width > 0 && d.height > 0) {
          setWindowDisplaySize(d.width, d.height);
          hilog.info(LOG_DOMAIN, LOG_TAG, 'window display id=%{public}d %{public}dx%{public}d', did, d.width, d.height);
        }
      } catch (e) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'window display query fail: %{public}s', JSON.stringify(e));
      }
    }
    // 2. 启动 JVM（幂等保护在 startJvm 内）。
    if (this.launchTriggered) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'launch already triggered in this window');
      return;
    }
    if (w <= 0 || h <= 0) {
      // onSurfaceCreated fires with 0x0; wait for the first onSurfaceChanged so the
      // launch advertises the REAL client size. The window title bar makes the
      // client area smaller than the OS window, and Minecraft derives its
      // mouse/GUI coordinate space from this launch size.
      hilog.info(LOG_DOMAIN, LOG_TAG, 'defer launch until surface size known');
      if (this.launchFallbackTimer < 0) {
        // Safety net: if onSurfaceChanged never delivers a size, still launch.
        this.launchFallbackTimer = setTimeout(() => {
          this.launchFallbackTimer = -1;
          if (!this.launchTriggered) {
            this.launchTriggered = true;
            hilog.info(LOG_DOMAIN, LOG_TAG, 'launch fallback (surface size unknown)');
            launchGame(ctx, param.gameRoot, param.jsonPath, param.versionId,
              WINDOW_DEFAULT_W, WINDOW_DEFAULT_H);
          }
        }, LAUNCH_FALLBACK_MS);
      }
      return;
    }
    if (this.launchFallbackTimer >= 0) {
      clearTimeout(this.launchFallbackTimer);
      this.launchFallbackTimer = -1;
    }
    this.launchTriggered = true;
    await launchGame(ctx, param.gameRoot, param.jsonPath, param.versionId, w, h);
  }

  /** 轮询一次全屏请求并驱动真实窗口（PC 2in1：无边框 + 铺满显示）。 */
  private async pollFullscreen(): Promise<void> {
    const jrelib = this.jrelib;
    if (jrelib === null || jrelib.takeFullscreenRequest === undefined) {
      return;
    }
    const req: FullscreenRequest = jrelib.takeFullscreenRequest();
    if (req.request === 1) {
      await this.enterFullscreen();
    } else if (req.request === 2) {
      await this.exitFullscreen();
    }
  }

  /**
   * 取走一次"打开链接"请求（MC 26.3：Blaze3D → SDL_OpenURL → 我们的 ohos sysurl 写请求文件）
   * 并以隐式 Want 拉起浏览器。文件由 native 以「临时文件 + rename」写入，故不会读到半截 URL。
   * OHOS 没有原生的"打开 URL"入口，只能由持有 Ability 的 ArkTS 侧 startAbility。
   */
  private pollOpenUrl(): void {
    const path: string = `${this.context().filesDir}/${OPEN_URL_REQUEST_FILE}`;
    let url: string;
    try {
      if (!fileIo.accessSync(path)) {
        return;
      }
      url = fileIo.readTextSync(path);
      fileIo.unlinkSync(path);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'pollOpenUrl: cannot take %{public}s', path);
      return;
    }
    if (url.length === 0) {
      return;
    }
    const want: Want = { action: 'ohos.want.action.viewData', uri: url };
    this.context().startAbility(want).catch((e: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'pollOpenUrl: startAbility failed code=%{public}s', e.code);
    });
  }

  /** 进入全屏：maximize 的 ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER → 铺满整屏并隐藏
   *  dock/标题栏/状态栏，且鼠标 Hover 热区不显示它们。MC 经 surface resize 得到新尺寸。 */
  private async enterFullscreen(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context());
      await win.maximize(
        window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
      await win.setTitleAndDockHoverShown(false, false);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'enter fullscreen (maximize immersive)');
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'enter fullscreen err: %{public}s', JSON.stringify(e));
    }
  }

  /** 退出全屏：recover 回到自由窗口。 */
  private async exitFullscreen(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context());
      await win.recover();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'exit fullscreen (recover)');
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'exit fullscreen err: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      // 游戏画面层（获焦键盘/鼠标/滚轮透传）。
      Column({ space: LAYOUT_SPACE }) {
        // 现代 XComponentOptions 形式（type+controller，id 走属性）→ 节点为 V2 pattern，
        // 无 libraryname，通用键盘/鼠标事件可用。
        XComponent({
          type: XComponentType.SURFACE,
          controller: this.xController,
        })
          // 显示缩放：surface 按 1/S 布局，再用 .scale(S) 放大回满窗（pivot 左上）。
          // MC 收到缩小后的窗口/framebuffer 尺寸 → 低分辨率渲染 + 合成器上采样（S=1 时与原状完全等价）。
          .width(`${100 / this.renderScale}%`)
          .height(`${100 / this.renderScale}%`)
          .scale({ x: this.renderScale, y: this.renderScale, centerX: 0, centerY: 0 })
          .backgroundColor(Color.Black)
          // 需获焦才有 onKeyEvent：focusable；焦点由 IME 激活/去激活程序化管理。
          .id('game-xc')
          .focusable(true)
          .defaultFocus(true)
          .onKeyEvent((event: KeyEvent) => {
            this.input?.handleKey(event);
          })
          .onFocus(() => {
            this.input?.onFocusGained();
          })
          .onBlur(() => {
            this.input?.releaseAllKeysUp();
          })
          .onMouse((event: MouseEvent) => {
            this.input?.handleMouse(event);
          })
          .onTouch((event: TouchEvent) => {
            this.input?.handleTouchMap(event);
          })
          .onAxisEvent((event: AxisEvent) => {
            this.input?.handleAxis(event);
          });
      }
      .width('100%')
      .height('100%')
      // 缩放时 XComponent 按 1/S 布局，须贴左上角，配合 .scale pivot(0,0) 放大才铺满（默认居中会错位）。
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start);

      // 原生鼠标增量输入：NDK 覆盖节点占位（HitTestMode.Transparent，不挡下层 XComponent）。
      ContentSlot(this.inputOverlay);

      // 隐形 IME 客户端：1x1、透明、可获焦、命中全透传。
      // hitTestBehavior(None)：不拦截鼠标/不显示文本 I 光标/不响应点击，
      // 焦点仅由代码 requestFocus('ime-input') 控制。视觉零新增。
      TextInput({ text: this.imeText, placeholder: '' })
        .id('ime-input')
        .width(1)
        .height(1)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
        .focusable(true)
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => {
          this.input?.syncImeText(value);
        })
        .onSubmit(() => {
          this.input?.submitImeText();
        })
        .onKeyEvent((event: KeyEvent) => {
          this.input?.handleImeKey(event);
        })
        // onKeyPreIme 在输入法之前触发；返回 false 不消费（继续交给输入法做文本合成）。
        // 把会被输入法吞掉的可打印键转发给 MC：按键绑定需要 key 事件。
        .onKeyPreIme((event: KeyEvent) => {
          this.input?.preImeKey(event);
          return false;
        });

      // 右下角：当前鼠标有效采样率（不拦截输入；由高级选项控制）。
      if (this.showInputRate) {
        Column() {
          Text($r('app.string.game_input_rate', this.mouseRate))
            .fontColor(Color.White)
            .backgroundColor(OVERLAY_BG)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 12, bottom: 12 })
        .hitTestBehavior(HitTestMode.None);
      }
    }
    .width('100%')
    .height('100%');
  }
}
