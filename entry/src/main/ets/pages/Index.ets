import { mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  LAYOUT_ACCOUNT_PANEL_W, LAYOUT_PADDING, LAYOUT_SPACE, LAYOUT_WIDE_MIN_W
} from '../common/constants/Constants';
import { GameVersion } from '../common/data/VersionScanner';
import {
  launchInMainProcess, LAUNCH_OK, LAUNCH_ERR_NO_ACCOUNT, LAUNCH_ERR_MS_EXPIRED, LAUNCH_ERR_BAD_PATH
} from '../common/data/VersionLaunch';
import { SettingsTools } from '../common/data/SettingsTools';
import { AccountView } from '../components/AccountView';
import { AdvancedOptionsView } from '../components/AdvancedOptionsView';
import { GameDirsView } from '../components/GameDirsView';
import { GameVersionsView } from '../components/GameVersionsView';
import { JavaEnvView } from '../components/JavaEnvView';
import { VulkanProbeHost } from '../devtools/VulkanProbeHost';
import { AccountState, getAccountState } from '../common/state/AccountState';
import { getLauncherState, LauncherState } from '../common/state/LauncherState';

/**
 * 应用入口页（@Entry + 状态管理 V2）。
 *
 * 设计原则：页面壳保持极薄——只负责整体布局与组合区块，不放业务逻辑。
 * 区块（主列顺序 = 常用优先；Java 环境最不常用，排最后）：
 * 1. GameDirsView   （游戏目录管理）
 * 2. GameVersionsView（版本列表 + 启动）
 * 3. AccountView    （账户区：窄屏在主列内；宽屏左移为独立侧栏）
 * 4. AdvancedOptionsView（高级选项：调试/进阶开关，**应用级全局唯一**）
 * 5. JavaEnvView    （Java 环境状态：内置 JRE 与解压就绪情况）
 * 目录区与版本区通过共享 LauncherState（AppStorageV2）协同。
 *
 * 响应式：窗口宽度 ≥ LAYOUT_WIDE_MIN_W 时，账户区左移为固定宽侧栏，主区保持原样单独滚动，
 * 形成左右分栏；否则维持单列原始布局。断点用官方 mediaquery 监听（分屏/旋转会实时更新）。
 *
 * 「继续上次」按钮：上次成功启动的版本（记录见 SettingsTools.lastLaunch()），文案
 * `<目录昵称> - <版本>`；作为滚动区的**兄弟**置于底部（宽屏在左栏账户 Scroll 下方，窄屏在主区 Scroll 下方）。
 */
@Entry
@ComponentV2
struct Index {
  /** 是否宽屏（≥ LAYOUT_WIDE_MIN_W vp）：宽屏时账户区左移为侧栏。 */
  @Local wide: boolean = false;

  /** 共享启动器状态（目录/版本/JRE/游戏运行中/上次启动镜像）。 */
  @Local state: LauncherState = getLauncherState();

  /** 账户共享状态（"继续上次"的启动门槛之一）。 */
  @Local accountState: AccountState = getAccountState();

  /** 媒体查询监听句柄（窄/宽断点）。 */
  private wideListener: mediaquery.MediaQueryListener | null = null;

  /** 开发者诊断：render-env 命中 MEOW_VK_PROBE 时才挂载 VulkanProbeHost（正常用户 false）。 */
  @Local vkProbeEnabled: boolean = false;

  aboutToAppear(): void {
    // 开发者诊断：仅当 render-env 命中 MEOW_VK_PROBE 时挂载探针宿主（正常用户零行为/零渲染）。
    const probeCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.vkProbeEnabled = new SettingsTools(probeCtx).vkProbeFrames() > 0;

    const query = `(min-width: ${LAYOUT_WIDE_MIN_W}vp)`;
    this.wideListener = this.getUIContext().getMediaQuery().matchMediaSync(query);
    this.wide = this.wideListener.matches;
    this.wideListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.wide = r.matches;
    });
  }

  aboutToDisappear(): void {
    if (this.wideListener !== null) {
      this.wideListener.off('change');
      this.wideListener = null;
    }
  }

  /** 主区区块。宽屏时账户区已左移，这里不再包含它（账户区只出现一次）。 */
  @Builder
  mainSections() {
    GameDirsView();
    Divider();
    GameVersionsView();
    if (!this.wide) {
      Divider();
      AccountView();
    }
    Divider();
    // 高级选项（应用级全局唯一）排在 Java 环境之前 —— 后者最不常用，放最下面。
    AdvancedOptionsView();
    Divider();
    JavaEnvView();
  }

  /** 「继续上次」是否可点（与单版本启动同门槛：JRE 就绪 + 有账户 + 未在运行）。 */
  private canLaunchLast(): boolean {
    return this.state.jreReady && this.accountState.selectedId.length > 0 && !this.state.gameRunning;
  }

  /** 「继续上次」按钮的动态部分：<目录昵称> - <版本>（昵称找不到时退化为仅版本号）。 */
  private lastLaunchLabel(): string {
    const dir = this.state.dirs.find((d) => d.uri === this.state.lastLaunchDir);
    const name = dir !== undefined ? dir.name : '';
    return name.length > 0
      ? `${name} - ${this.state.lastLaunchVersion}`
      : this.state.lastLaunchVersion;
  }

  /** 继续上次：用记录里的 jsonPath 直接重开游戏窗口（无需重扫目录）。 */
  private async launchLast(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const v = new GameVersion(this.state.lastLaunchVersion, '', this.state.lastLaunchJsonPath, '', 0, '', '', '', '');
    const out = await launchInMainProcess(ctx, v);
    if (out.code === LAUNCH_ERR_NO_ACCOUNT) {
      this.getUIContext().showAlertDialog({ message: $r('app.string.versions_need_account') });
      return;
    }
    if (out.code === LAUNCH_ERR_MS_EXPIRED) {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.accounts_login_expired'),
        message: out.detail,
      });
      return;
    }
    if (out.code === LAUNCH_ERR_BAD_PATH) {
      // 记录指向的版本/路径已失效（如外部删除）→ 自愈：清记录 + 刷新（按钮随之隐藏）。
      new SettingsTools(ctx).clearLastLaunch();
      this.state.refreshLastLaunch(ctx);
      this.getUIContext().showAlertDialog({ message: $r('app.string.launch_failed') });
      return;
    }
    if (out.code !== LAUNCH_OK) {
      // 开窗失败等瞬时问题：给出可见反馈（原先静默无反应），保留记录以便重试。
      this.getUIContext().showAlertDialog({ message: $r('app.string.launch_failed') });
    }
  }

  /** 「继续上次」按钮（仅在有记录时渲染）；与滚动区并列在容器底部。 */
  @Builder
  continueLastButton() {
    if (this.state.lastLaunchVersion.length > 0) {
      Row() {
        Button($r('app.string.launch_last', this.lastLaunchLabel()))
          .enabled(this.canLaunchLast())
          .width('100%')
          .onClick(() => {
            this.launchLast();
          });
      }
      .padding(this.wide ? 0 : { left: LAYOUT_PADDING, right: LAYOUT_PADDING, bottom: LAYOUT_PADDING });
    }
  }

  build() {
    Stack() {
      Row() {
        if (this.wide) {
          // 左侧栏：账户区（可滚动）+ 底部「继续上次」按钮（与账户 Scroll 并列）
          Column({ space: LAYOUT_SPACE }) {
            Scroll() {
              Column({ space: LAYOUT_SPACE }) {
                AccountView();
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start);
            }
            .edgeEffect(EdgeEffect.Spring)
            .layoutWeight(1)
            .width('100%')
            .align(Alignment.TopStart);
            this.continueLastButton();
          }
          .padding({ left: LAYOUT_PADDING, top: LAYOUT_PADDING, bottom: LAYOUT_PADDING })
          .width(LAYOUT_ACCOUNT_PANEL_W)
          .height('100%');
        }
        // 主区：可上下滚动的原页面（+ 窄屏时底部「继续上次」按钮，与主区 Scroll 并列）
        Column({ space: LAYOUT_SPACE }) {
          Scroll() {
            Column({ space: LAYOUT_SPACE }) {
              this.mainSections();
            }
            .padding(LAYOUT_PADDING)
            .width('100%')
            .alignItems(HorizontalAlign.Start);
          }
          .edgeEffect(EdgeEffect.Spring)
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.TopStart);
          if (!this.wide) {
            this.continueLastButton();
          }
        }
        .layoutWeight(1)
        .height('100%');
      }
      .width('100%')
      .height('100%');

      // 开发者诊断挂载：仅 render-env 命中 MEOW_VK_PROBE 时渲染 VulkanProbeHost（否则零行为/零渲染）。
      if (this.vkProbeEnabled) {
        VulkanProbeHost();
      }
    }
    .width('100%')
    .height('100%');
  }
}
