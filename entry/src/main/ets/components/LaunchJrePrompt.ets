import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { installRuntime } from '../common/data/JavaEnvScanner';
import { getLauncherState } from '../common/state/LauncherState';

/**
 * 「该实例要用的那套 JRE 还没解压」的对话框 —— **全项目唯一一处**这种提示。
 *
 * 为什么单独成一个模块：版本列表的「启动」与底部「继续上次」都会走到这个分支，
 * 两处必须给出同一句话、同一个动作（否则又回到"到处提示"的老毛病）。
 * ★ 安装入口（下载面板的「确认安装」勾 NeoForge）也要走同一条：安装期会起**工具 JVM**
 *   （`:neoinstall` 独立进程，无 UI、弹不出对话框）⇒ 检查只能放在**主进程的安装入口**，
 *   但对话框仍复用本模块（仅动作语境不同：正文/"再点一次"的动词由 `action` 决定）。
 *
 * 沿用 UI 里其他对话框的既有写法（`getUIContext().showAlertDialog` + 两按钮 + `$r('app.string.*')`
 * 文案 + cancel=brand / 动作=danger 配色；见 GameVersionsView.confirmDelete、GameDirsView.confirmRemove、
 * AdvancedOptionsView.confirmExport）。
 *
 * 动作取**最简、失败面最小**的一种：确认后就地走既有的解压入口（`installRuntime`，与「Java 环境」区
 * 同一个 native `installJre`），完成后提示"请再点一次启动 / 确认安装"。**不**自动续跑启动或安装链——
 * 前者要跨进程重开游戏窗口 / 重建 surface / 重走 argv，后者要重跑整条 processor 链（逐次起
 * `:neoinstall` 进程），两者失败面都大且失败时对用户不可见。
 */

/** 动作语境：**启动**一个已装实例（版本列表「启动」/ 底部「继续上次」）。 */
export const JRE_ACTION_LAUNCH: number = 0;
/** 动作语境：**安装**一个 NeoForge 实例（安装期起工具 JVM，见 `NeoInstallAbility`）。 */
export const JRE_ACTION_INSTALL: number = 1;

/**
 * 弹「JRE 未就绪」对话框。
 *
 * @param ui          发起方的 UIContext（组件里 `this.getUIContext()`）。
 * @param runtimeId   要用/要装的那套 JRE id（= `JavaRuntime.id`，解压入口按它选 rawfile）。
 * @param javaMajor   该套的 Java 主版本（文案里点名"哪一套"；26 / 8 …）。
 * @param needsUpgrade 有数据但令牌不符（按钮显示「升级」）还是完全未解压（「解压」）。
 * @param action      动作语境（`JRE_ACTION_LAUNCH` / `JRE_ACTION_INSTALL`）：决定正文与"再点一次"的动词。
 */
export function promptJreNotReady(ui: UIContext, runtimeId: string, javaMajor: number,
  needsUpgrade: boolean, action: number = JRE_ACTION_LAUNCH): void {
  ui.showAlertDialog({
    title: $r('app.string.launch_jre_title'),
    message: action === JRE_ACTION_INSTALL
      ? $r('app.string.launch_jre_install_message', javaMajor)
      : $r('app.string.launch_jre_message', javaMajor),
    primaryButton: {
      value: $r('app.string.common_cancel'),
      action: () => {
      },
      fontColor: $r('sys.color.white'),
      backgroundColor: $r('app.color.brand')
    },
    secondaryButton: {
      value: needsUpgrade ? $r('app.string.java_env_upgrade') : $r('app.string.java_env_extract'),
      action: () => {
        prepareJre(ui, runtimeId, action);
      },
      fontColor: $r('sys.color.white'),
      backgroundColor: $r('app.color.danger')
    },
  });
}

/** 解压/升级该套 JRE（同步，约 1~2s）→ 让「Java 环境」区同步看到新状态 → 告知用户再点一次「启动 / 确认安装」。 */
function prepareJre(ui: UIContext, runtimeId: string, action: number): void {
  const ctx = ui.getHostContext() as common.Context;
  const ok = installRuntime(ctx, runtimeId);
  // 这里是"替「Java 环境」区装了 JRE"，必须让它重扫，否则那一区会停在旧的「未解压」上。
  // 失败也重扫：解到一半留下的数据由该区按真实令牌如实显示（未解压 / 须升级）。
  getLauncherState().refreshJreEnvs(ctx.filesDir);
  const prepared = action === JRE_ACTION_INSTALL
    ? $r('app.string.launch_jre_install_prepared')
    : $r('app.string.launch_jre_prepared');
  ui.showAlertDialog({
    message: ok ? prepared : $r('app.string.launch_jre_prepare_failed'),
  });
}
