import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  BORDER_RADIUS, LAYOUT_MARGIN_HAIRLINE, LAYOUT_PADDING_SMALL, LAYOUT_SPACE, LAYOUT_SPACE_SMALL,
  OPACITY_SECONDARY
} from '../common/constants/Constants';
import { Account, AccountsTools, ACCOUNT_TYPE_MICROSOFT, formatExpiry, isValidPlayerName } from '../common/data/AccountsTools';
import { AccountState, getAccountState } from '../common/state/AccountState';
import { DeviceCode, loginMicrosoft } from '../common/data/MicrosoftAuth';
import { SettingsTools } from '../common/data/SettingsTools';

/**
 * 账户管理区块（与 GameDirsView / GameVersionsView 等平级，由 Index 挂载）。
 *
 * P1：离线账户的增 / 删 / 选中（对标 HMCL 账户管理）。
 * P2 将在此加入微软登录（Device Code）入口。
 * 持久化经 AccountsTools（应用沙箱文件，跨进程：主进程写、游戏进程读）。
 */
@ComponentV2
export struct AccountView {
  /** 共享账户状态（与其它组件同一实例）。 */
  @Local state: AccountState = getAccountState();

  /** 添加离线账户的输入名。 */
  @Local newName: string = '';

  /** 上次确认时的名字非法/重复标记。 */
  @Local invalid: boolean = false;

  // 微软登录进度（进行中 / 设备码 / 校验地址 / 错误）已提升到共享 AccountState
  //（见 AccountState.msLoggingIn/msDeviceUserCode/msDeviceUri/msError）——
  // 宽窄断点切换会销毁重建本组件，放共享态才能保留进行中的登录 UI。

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    const tools = new AccountsTools(this.context());
    tools.backfillOfflineUuids();
    this.state.reload(this.context());
  }

  private typeLabel(t: string): Resource {
    return t === ACCOUNT_TYPE_MICROSOFT
      ? $r('app.string.accounts_type_microsoft')
      : $r('app.string.accounts_type_offline');
  }

  /** 账号下拉选项：显示账户名（运行时字符串，动态数据，非 UI 文案）。 */
  private accountOptions(): SelectOption[] {
    return this.state.accounts.map((a: Account): SelectOption => ({ value: a.name }));
  }

  /** 当前选中账号在列表中的下标（找不到时回退 0）。 */
  private selectedAccountIndex(): number {
    const list = this.state.accounts;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.state.selectedId) {
        return i;
      }
    }
    return 0;
  }

  /** 当前账号名（下拉显示值）。 */
  private selectedAccountName(): string {
    const list = this.state.accounts;
    return list.length > 0 ? list[this.selectedAccountIndex()].name : '';
  }

  /**
   * 微软账户登录凭证有效期文案（依据 MC access token 到期时间 notAfter）。
   * 注：这是 MC token（约 24h）的到期；即使显示已过期，只要 refresh token 仍在，
   * 启动时会自动静默续期，故过期不等于失效。
   */
  private expiryText(notAfter: number | undefined): Resource {
    const t = notAfter ?? 0;
    if (!Number.isFinite(t) || t <= 0) {
      return $r('app.string.accounts_status_unknown');
    }
    if (t <= Date.now()) {
      return $r('app.string.accounts_status_expired');
    }
    return $r('app.string.accounts_status_valid_until', formatExpiry(t));
  }

  /** 添加离线账户：名字校验（[A-Za-z0-9_]{1,16}）+ 查重；首个账户自动选中。 */
  private addOffline(): void {
    const name = this.newName.trim();
    const tools = new AccountsTools(this.context());
    if (!isValidPlayerName(name) || tools.list().some((a: Account) => a.name === name)) {
      this.invalid = true;
      return;
    }
    this.invalid = false;
    tools.createOffline(name);
    this.newName = '';
    this.state.reload(this.context());
  }

  private select(id: string): void {
    // 单选：已选中则不动（保证"点当前卡片"是真正的 no-op，不会触发重载/取消）。
    if (this.state.isSelected(id)) {
      return;
    }
    new AccountsTools(this.context()).setSelectedId(id);
    this.state.reload(this.context());
  }

  private remove(id: string): void {
    new AccountsTools(this.context()).remove(id);
    this.state.reload(this.context());
  }

  /** 发起微软登录（Device Code Flow）；updateId 非空 = 对已存在账户就地重新登录。 */
  private async doMicrosoftLogin(updateId: string): Promise<void> {
    this.state.msError = '';
    this.state.msNoClientId = false;
    this.state.msDeviceUserCode = '';
    this.state.msDeviceUri = '';
    this.state.msLoggingIn = true;
    try {
      const clientId = new SettingsTools(this.context()).msClientId();
      if (clientId.length === 0) {
        this.state.msNoClientId = true;
        return;
      }
      const r = await loginMicrosoft((d: DeviceCode) => {
        this.state.msDeviceUserCode = d.userCode;
        this.state.msDeviceUri = d.verificationUri;
      }, clientId);
      const tools = new AccountsTools(this.context());
      if (updateId.length > 0) {
        tools.updateMicrosoft(updateId, r);
      } else {
        tools.createMicrosoft(r);
      }
      this.state.reload(this.context());
    } catch (e) {
      this.state.msError = (e as Error).message;
    } finally {
      this.state.msLoggingIn = false;
      this.state.msDeviceUserCode = '';
      this.state.msDeviceUri = '';
    }
  }

  private startMicrosoftLogin(): void {
    this.doMicrosoftLogin('');
  }

  /** 刷新微软账户 token（强制续期）；失败（含 refresh 失效）显示错误。 */
  private async refreshMs(account: Account): Promise<void> {
    this.state.msError = '';
    this.state.msNoClientId = false;
    this.state.msLoggingIn = true;
    try {
      await new AccountsTools(this.context()).ensureMicrosoftFresh(account, true);
      this.state.reload(this.context());
    } catch (e) {
      this.state.msError = (e as Error).message;
    } finally {
      this.state.msLoggingIn = false;
    }
  }

  /** 退出登录：清 token，保留账户条目（可重新登录）。 */
  private logoutMs(account: Account): void {
    new AccountsTools(this.context()).logoutMicrosoft(account.id);
    this.state.reload(this.context());
  }

  /** 复制设备码到剪贴板（免读权限）。 */
  private copyUserCode(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.state.msDeviceUserCode);
      pasteboard.getSystemPasteboard().setDataSync(data);
    } catch {
      return;
    }
  }

  /** 打开系统浏览器到校验地址。 */
  private openVerification(): void {
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: this.state.msDeviceUri,
      };
      this.context().startAbility(want).catch(() => {
      });
    } catch {
      return;
    }
  }

  build() {
    Column({ space: LAYOUT_SPACE }) {
      Text($r('app.string.accounts_title'))
        .fontWeight(FontWeight.Bold);

      // 当前账户：下拉切换（账号为单选）。卡片仅作管理，不再承载选择。
      if (this.state.accounts.length > 0) {
        Select(this.accountOptions())
          .selected(this.selectedAccountIndex())
          .value(this.selectedAccountName())
          .onSelect((index: number) => {
            const list = this.state.accounts;
            if (index >= 0 && index < list.length) {
              this.select(list[index].id);
            }
          })
          .selectedOptionBgColor($r('app.color.brand_bg'))
          .selectedOptionFontColor($r('app.color.brand'))
          .width('100%');
      }

      if (this.state.accounts.length === 0) {
        Text($r('app.string.accounts_empty'))
          .opacity(OPACITY_SECONDARY);
      }
      Repeat<Account>(this.state.accounts)
        .each((obj: RepeatItem<Account>) => {
          Column({ space: LAYOUT_SPACE }) {
            Column() {
              Text(obj.item.name);
              // 生成的离线 UUID（创建即派生，与 launcher/原版一致）
              Text(obj.item.uuid.length > 0 ? obj.item.uuid : $r('app.string.accounts_uuid_pending'))
                .width('100%')
                .opacity(OPACITY_SECONDARY)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              // 微软已登录账户：显示登录凭证有效期状态
              if (obj.item.type === ACCOUNT_TYPE_MICROSOFT && (obj.item.accessToken ?? '').length > 0) {
                Text(this.expiryText(obj.item.notAfter))
                  .width('100%')
                  .opacity(OPACITY_SECONDARY);
              }
            }
            .alignItems(HorizontalAlign.Start);
            Row({ space: LAYOUT_SPACE }) {
              Text(this.typeLabel(obj.item.type))
                .opacity(OPACITY_SECONDARY);
              // 微软账户操作：刷新 / 退出登录；已登出则重新登录
              if (obj.item.type === ACCOUNT_TYPE_MICROSOFT) {
                if ((obj.item.accessToken ?? '').length === 0) {
                  Text($r('app.string.accounts_logged_out'))
                    .opacity(OPACITY_SECONDARY);
                  Button($r('app.string.accounts_relogin'))
                    .enabled(!this.state.msLoggingIn)
                    .onClick(() => {
                      this.doMicrosoftLogin(obj.item.id);
                    });
                } else {
                  Button($r('app.string.accounts_refresh'))
                    .enabled(!this.state.msLoggingIn)
                    .onClick(() => {
                      this.refreshMs(obj.item);
                    });
                  Button($r('app.string.accounts_logout'))
                    .onClick(() => {
                      this.logoutMs(obj.item);
                    });
                }
              }
              Button($r('app.string.common_remove'))
                .onClick(() => this.remove(obj.item.id));
            }
            .justifyContent(FlexAlign.End)
            .width('100%');
          }
          .width('100%')
          .padding(LAYOUT_PADDING_SMALL)
          .backgroundColor($r('app.color.brand_bg'))
          .borderRadius(BORDER_RADIUS);
        })
        // 全量加载模式仅按 key 判变化；账户是普通 interface，登出/刷新只改字段不改 id，
        // 必须并入 revision 才能在 reload 后重渲染（否则「已登出」/有效期不刷新）。
        .key((a: Account) => `${this.state.revision}:${a.id}`);

      // 离线账户 ID 输入框
      TextInput({ text: this.newName, placeholder: $r('app.string.accounts_name_placeholder') })
        .onChange((v: string) => {
          this.newName = v;
        })
        .margin({ right: LAYOUT_MARGIN_HAIRLINE }) // 修 TextInput layoutWeight(1) 的轻微布局抖动
        .onSubmit(() => this.addOffline());
      // 微软正版登录（Device Code Flow：浏览器输码 → 轮询）最左 + 添加离线账户（名字进入即校验；回车/添加均可）
      Row({ space: LAYOUT_SPACE }) {
        Button($r('app.string.accounts_add_microsoft'))
          .enabled(!this.state.msLoggingIn)
          .onClick(() => this.startMicrosoftLogin());
        Button($r('app.string.accounts_add_offline'))
          .onClick(() => this.addOffline());
      }
      .width('100%');
      if (this.invalid) {
        Text($r('app.string.accounts_name_invalid'))
          .opacity(OPACITY_SECONDARY);
      }
      if (this.state.msDeviceUserCode.length > 0) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.accounts_ms_instruction', this.state.msDeviceUri))
            .opacity(OPACITY_SECONDARY);
          Row({ space: LAYOUT_SPACE }) {
            Text(this.state.msDeviceUserCode)
              .fontWeight(FontWeight.Bold);
            Button($r('app.string.common_copy'))
              .onClick(() => this.copyUserCode());
            Button($r('app.string.accounts_ms_open'))
              .onClick(() => this.openVerification());
          }
          .alignItems(VerticalAlign.Center);
          Text($r('app.string.accounts_ms_waiting'))
            .opacity(OPACITY_SECONDARY);
        }
        .width('100%')
        .padding(LAYOUT_PADDING_SMALL)
        .backgroundColor($r('app.color.brand_bg'))
        .borderRadius(BORDER_RADIUS)
        .alignItems(HorizontalAlign.Start);
      }
      if (this.state.msNoClientId) {
        Text($r('app.string.accounts_ms_no_client_id'))
          .opacity(OPACITY_SECONDARY);
      } else if (this.state.msError.length > 0) {
        Text($r('app.string.accounts_ms_error', this.state.msError))
          .opacity(OPACITY_SECONDARY);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
