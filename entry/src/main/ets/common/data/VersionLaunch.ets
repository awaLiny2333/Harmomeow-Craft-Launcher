import { common } from '@kit.AbilityKit';
import { Account, AccountsTools, ACCOUNT_TYPE_MICROSOFT } from './AccountsTools';
import { asMsAuthError, MsAuthError } from './MicrosoftAuth';
import { GameVersion } from './VersionScanner';
import { checkLaunchJre } from './GameLauncher';
import { GameLaunchParams } from '../state/GameLaunchParams';
import { windowHolder } from '../state/WindowHolder';
import { WINDOW_DEFAULT_H, WINDOW_DEFAULT_W, WINDOW_DEFAULT_X, WINDOW_DEFAULT_Y } from '../constants/LaunchDefaults';

/**
 * 主进程侧"启动一个已安装版本"的共享编排（与具体 UI 组件解耦）。
 *
 * 职责：账户门控 → **该实例要用的那套 JRE 是否就绪**（启动前唯一的那次检查，见
 * `GameLauncher.checkLaunchJre`）→ 微软 token 续期/校验 → 打开独立游戏窗口。
 * 调用方（版本列表的"启动"、"继续上次"按钮）根据返回的 code 决定提示文案（JRE 未就绪时弹对话框）。
 *
 * 真正的 JVM 启动在游戏进程（GameLauncher.launchGame），本模块只负责"检查 + 开窗"。
 * 为什么检查放在这里（而不是 `launchGame`）：`GameAbility` 是**独立进程**（module.json5
 * `process: ":game"`），那里没有启动器 UI、弹不出对话框；而"准备完成后请再点一次启动"
 * 也只有在启动器窗口里才成立。
 */

export const LAUNCH_OK: number = 0;
/** 无可用账户（未选中）→ 调用方提示"尚无账户"。 */
export const LAUNCH_ERR_NO_ACCOUNT: number = 1;
/** 微软登录已失效 → 调用方提示重新登录（msError 为可解析的错误码）。 */
export const LAUNCH_ERR_MS_EXPIRED: number = 2;
/** jsonPath 反推游戏根失败（记录/路径已失效）→ "继续上次"据此自愈清记录。 */
export const LAUNCH_ERR_BAD_PATH: number = 3;
/** 游戏窗打开失败（startAbility 失败）→ 瞬时问题，不清记录。 */
export const LAUNCH_ERR_OPEN_FAILED: number = 4;
/** 该实例要用的那套 JRE 尚未解压/须升级 → 调用方弹对话框并沿用既有解压入口准备。 */
export const LAUNCH_ERR_JRE_NOT_READY: number = 5;

/** 启动结果（code + 可解析的错误，供调用方映射文案）。 */
export class LaunchOutcome {
  code: number = LAUNCH_OK;
  msError: MsAuthError | null = null;
  /** JRE 未就绪时：该实例要用的那套 runtime id（`LAUNCH_ERR_JRE_NOT_READY` 才有意义）。 */
  jreRuntimeId: string = '';
  /** JRE 未就绪时：该套的 Java 主版本（对话框文案里点名"哪一套"）。 */
  jreJavaMajor: number = 0;
  /** JRE 未就绪时：是"有数据但须升级"（true）还是"完全未解压"（false）。 */
  jreNeedsUpgrade: boolean = false;
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

/** 主进程启动一个已安装版本：账户门控 → JRE 就绪（启动前检查）→ 微软续期/校验 → 打开独立游戏窗口。 */
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
  // ★ 启动前唯一的那次 JRE 检查：按**该实例实际要用的那一套**判就绪（启动链同一处解析 + 同一套判据）。
  // 未就绪 ⇒ 不续期 token、不开窗，把该套 runtime 信息交回调用方弹对话框（准备沿用既有解压入口）。
  const jre = checkLaunchJre(ctx.filesDir, gameRoot, v.id, v.jsonPath);
  if (!jre.installed) {
    out.code = LAUNCH_ERR_JRE_NOT_READY;
    out.jreRuntimeId = jre.runtime.id;
    out.jreJavaMajor = jre.runtime.javaMajor;
    out.jreNeedsUpgrade = jre.needsUpgrade;
    return out;
  }
  // 微软账户：启动前确保 token 有效（过期→续期；续不动→提示重新登录，不硬启）。
  if (account.type === ACCOUNT_TYPE_MICROSOFT) {
    try {
      await accounts.ensureMicrosoftFresh(account, false, true);
    } catch (e) {
      out.code = LAUNCH_ERR_MS_EXPIRED;
      out.msError = asMsAuthError(e as Error);
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
