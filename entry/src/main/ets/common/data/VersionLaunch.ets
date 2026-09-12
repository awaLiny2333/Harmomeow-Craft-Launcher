import { common } from '@kit.AbilityKit';
import { Account, AccountsTools, ACCOUNT_TYPE_MICROSOFT } from './AccountsTools';
import { GameVersion } from './VersionScanner';
import { GameLaunchParams } from '../state/GameLaunchParams';
import { windowHolder } from '../state/WindowHolder';
import { WINDOW_DEFAULT_H, WINDOW_DEFAULT_W, WINDOW_DEFAULT_X, WINDOW_DEFAULT_Y } from '../constants/LaunchDefaults';

/**
 * 主进程侧"启动一个已安装版本"的共享编排（与具体 UI 组件解耦）。
 *
 * 职责：账户门控 → 微软 token 续期/校验 → 打开独立游戏窗口。
 * 调用方（版本列表的"启动"、"继续上次"按钮）根据返回的 code 决定提示文案。
 *
 * 真正的 JVM 启动在游戏进程（GameLauncher.launchGame），本模块只负责"开窗 + 门控"。
 */

export const LAUNCH_OK: number = 0;
/** 无可用账户（未选中）→ 调用方提示"尚无账户"。 */
export const LAUNCH_ERR_NO_ACCOUNT: number = 1;
/** 微软登录已失效 → 调用方提示重新登录（detail 为原因）。 */
export const LAUNCH_ERR_MS_EXPIRED: number = 2;
/** jsonPath 反推游戏根失败（记录/路径已失效）→ "继续上次"据此自愈清记录。 */
export const LAUNCH_ERR_BAD_PATH: number = 3;
/** 游戏窗打开失败（startAbility 失败）→ 瞬时问题，不清记录。 */
export const LAUNCH_ERR_OPEN_FAILED: number = 4;

/** 启动结果（code + 可展示的 detail）。 */
export class LaunchOutcome {
  code: number = LAUNCH_OK;
  detail: string = '';
}

/**
 * 从版本 jsonPath 反推游戏根（.minecraft 那一层）。
 * jsonPath 形如 <root>/versions/<id>/<id>.json；不匹配返回空串。
 */
function gameRootOf(v: GameVersion): string {
  const suffix = `/versions/${v.id}/${v.id}.json`;
  return v.jsonPath.endsWith(suffix)
    ? v.jsonPath.substring(0, v.jsonPath.length - suffix.length)
    : '';
}

/** 主进程启动一个已安装版本：账户门控 → 微软续期/校验 → 打开独立游戏窗口。 */
export async function launchInMainProcess(ctx: common.UIAbilityContext,
  v: GameVersion): Promise<LaunchOutcome> {
  const out = new LaunchOutcome();
  const accounts = new AccountsTools(ctx);
  const account: Account | null = accounts.selected();
  if (account === null) {
    out.code = LAUNCH_ERR_NO_ACCOUNT;
    return out;
  }
  const gameRoot = gameRootOf(v);
  if (gameRoot.length === 0) {
    out.code = LAUNCH_ERR_BAD_PATH;
    return out;
  }
  // 微软账户：启动前确保 token 有效（过期→续期；续不动→提示重新登录，不硬启）。
  if (account.type === ACCOUNT_TYPE_MICROSOFT) {
    try {
      await accounts.ensureMicrosoftFresh(account, false, true);
    } catch (e) {
      out.code = LAUNCH_ERR_MS_EXPIRED;
      out.detail = (e as Error).message;
      return out;
    }
  }
  const params: GameLaunchParams = {
    gameRoot: gameRoot,
    jsonPath: v.jsonPath,
    versionId: v.id,
  };
  const opened = await windowHolder.openGameWindow(WINDOW_DEFAULT_X, WINDOW_DEFAULT_Y,
    WINDOW_DEFAULT_W, WINDOW_DEFAULT_H, params);
  if (!opened) {
    out.code = LAUNCH_ERR_OPEN_FAILED;
  }
  return out;
}
