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

  /**
   * 每次 reload 自增的版本号。
   * 账户对象是普通 interface（非 @ObservedV2/@Trace），登出/刷新只改字段不改 id；
   * Repeat 全量加载模式下仅按 key 判变化（见官方《Repeat》"键值不变即使数据改变也不刷新"），
   * 故把它并入 Repeat 的 key，确保 reload 后卡片内容重渲染。
   */
  @Trace revision: number = 0;

  /**
   * 微软设备码登录进度（提升到共享态）：宽/窄断点切换会销毁重建 AccountView，
   * 若这些态留在组件 @Local 会导致"进行中的登录 UI 丢失"。放共享态即可跨重建保留。
   */
  @Trace msLoggingIn: boolean = false;
  @Trace msDeviceUserCode: string = '';
  @Trace msDeviceUri: string = '';
  @Trace msError: string = '';
  /** 未配置 client_id 的专用提示（UI 走 resource，避免在逻辑里硬编码文案）。 */
  @Trace msNoClientId: boolean = false;

  /** 某账户是否为当前选中。 */
  isSelected(id: string): boolean {
    return this.selectedId === id;
  }

  /** 从 Preferences 重读列表与选中项（增删改 / 切选后调用）。 */
  reload(ctx: common.Context): void {
    const tools = new AccountsTools(ctx);
    this.accounts = tools.list();
    // 校验选中项：指向不存在账户/为空时回退到首个并落盘，避免"下拉显示已选中首个、
    // 启动门控却判无账户"的自相矛盾。
    const sel = tools.selectedId();
    let valid = false;
    for (const a of this.accounts) {
      if (a.id === sel) {
        valid = true;
        break;
      }
    }
    if (valid) {
      this.selectedId = sel;
    } else {
      const fallback = this.accounts.length > 0 ? this.accounts[0].id : '';
      if (fallback.length > 0) {
        tools.setSelectedId(fallback);
      }
      this.selectedId = fallback;
    }
    this.revision++;
  }
}

/** 通过 AppStorageV2 获取（或创建）共享的 AccountState 实例。 */
export function getAccountState(): AccountState {
  return AppStorageV2.connect<AccountState>(AccountState, () => new AccountState())!;
}
