import { AppStorageV2 } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Account, AccountsTools } from '../data/AccountsTools';

/**
 * 账户共享状态（跨组件通过 AppStorageV2 共享同一实例）。
 * 与 LauncherState 同构：@Trace 字段变化同步刷新所有 connect 组件；仅运行时镜像，持久化在 AccountsTools。
 */
@ObservedV2
export class AccountState {
  /** 账户列表（来自 AccountsTools.list）。 */
  @Trace accounts: Account[] = [];

  /** 当前选中账户 id（来自 AccountsTools.selectedId）。 */
  @Trace selectedId: string = '';

  /** 某账户是否为当前选中。 */
  isSelected(id: string): boolean {
    return this.selectedId === id;
  }

  /** 从 Preferences 重读列表与选中项（增删改 / 切选后调用）。 */
  reload(ctx: common.Context): void {
    const tools = new AccountsTools(ctx);
    this.accounts = tools.list();
    this.selectedId = tools.selectedId();
  }
}

/** 通过 AppStorageV2 获取（或创建）共享的 AccountState 实例。 */
export function getAccountState(): AccountState {
  return AppStorageV2.connect<AccountState>(AccountState, () => new AccountState())!;
}
