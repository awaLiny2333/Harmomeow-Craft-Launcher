/**
 * 游戏窗口启动参数通道。
 *
 * GameVersionsView（主窗）→ openGameWindow(parameters) → GameAbility.onCreate 收 want →
 * 写入本单例 → GameWindow 页 aboutToAppear 读取。模块级单例在同一进程内共享。
 */
export interface GameLaunchParams {
  gameRoot: string;
  jsonPath: string;
  versionId: string;
}

/** 当前待启动的版本参数（由 GameAbility 从 want 写入）。 */
export const gameLaunchParams: GameLaunchParams = {
  gameRoot: '',
  jsonPath: '',
  versionId: '',
};

/** GameAbility 收到 want 时写入。 */
export function setGameLaunchParams(p: GameLaunchParams): void {
  gameLaunchParams.gameRoot = p.gameRoot;
  gameLaunchParams.jsonPath = p.jsonPath;
  gameLaunchParams.versionId = p.versionId;
}
