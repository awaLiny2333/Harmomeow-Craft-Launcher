import { appManager } from '@kit.AbilityKit';
import { GAME_PROCESS_SUFFIX } from '../constants/LaunchContract';

/**
 * 游戏进程运行探测（纯逻辑，供主窗 UI 禁用重复启动/显示状态）。
 *
 * GameAbility 独立进程名为 <bundleName>:game（见 module.json5 process=":game"）。
 * getRunningProcessInformation 免权限、仅返回本应用进程，主进程据此判断
 * 游戏进程是否存活——跨进程无需通信即可知道"游戏中"。
 */

/** 游戏 Ability 进程当前是否在运行。 */
export async function isGameProcessRunning(): Promise<boolean> {
  try {
    const infos = await appManager.getRunningProcessInformation();
    for (const info of infos) {
      if (info.processName.endsWith(GAME_PROCESS_SUFFIX)) {
        return true;
      }
    }
  } catch {
    // 探测失败按未运行处理（UI 层不因此崩溃）
  }
  return false;
}
