import { common, Want } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameLaunchParams } from './GameLaunchParams';
import { ENTRY_MODULE, GAME_ABILITY } from '../constants/LaunchContract';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'WindowHolder';

/**
 * 应用窗口/游戏窗口单例持有者。
 *
 * 为什么：PC 自由窗口设备上"独立系统窗口（带装饰、可拖动、可缩放）"应通过
 * startAbility 启动另一个 UIAbility（第二个窗口），而不是 createSubWindow——
 * 子窗口是悬浮窗形态：无系统顶栏、拖动需手势自实现、布局跟随主窗。
 *
 * UIAbilityContext 只在 Ability 生命周期内稳定，因此 EntryAbility 启动时注入本单例，
 * 首页组件点击"打开游戏窗口"时直接调用。
 *
 * 窗口形态：不显式指定 windowMode（无 FLOATING 枚举），而是用 supportWindowModes
 * 声明 FLOATING+FULL_SCREEN，2in1 上按该声明默认以自由悬浮窗打开（带系统顶栏）。
 */
class WindowHolder {
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility.onCreate 注入。 */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /**
   * 启动独立游戏窗口（第二个 UIAbility GameAbility），自由窗口模式并指定初始位置/尺寸。
   * 游戏启动参数经 want.parameters 传给 GameAbility（跨 Ability 传递）。
   */
  async openGameWindow(left: number, top: number, width: number, height: number,
    parameters?: GameLaunchParams): Promise<boolean> {
    const ctx = this.context;
    if (ctx === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'UIAbilityContext not initialized');
      return false;
    }
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      moduleName: ENTRY_MODULE,
      abilityName: GAME_ABILITY,
      parameters: {
        gameRoot: parameters?.gameRoot ?? '',
        jsonPath: parameters?.jsonPath ?? '',
        versionId: parameters?.versionId ?? '',
      },
    };
    try {
      await ctx.startAbility(want, {
        displayId: 0,
        windowLeft: left,
        windowTop: top,
        windowWidth: width,
        windowHeight: height,
        supportWindowModes: [
          bundleManager.SupportWindowMode.FLOATING,
          bundleManager.SupportWindowMode.FULL_SCREEN,
        ],
      });
      hilog.info(LOG_DOMAIN, LOG_TAG, 'GameAbility started (independent window)');
      return true;
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'startAbility failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}

/** 全局单例。 */
export const windowHolder = new WindowHolder();
