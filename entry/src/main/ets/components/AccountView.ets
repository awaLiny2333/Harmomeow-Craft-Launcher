import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  BORDER_RADIUS, LAYOUT_PADDING_SMALL, LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY
} from '../common/constants/Constants';
import { Account, AccountsTools, ACCOUNT_TYPE_MICROSOFT, isValidPlayerName } from '../common/data/AccountsTools';
import { AccountState, getAccountState } from '../common/state/AccountState';
import { DeviceCode, loginMicrosoft } from '../common/data/MicrosoftAuth';
import { SettingsTools } from '../common/data/SettingsTools';

/**
 * 账户管理区块（与 GameDirsView / GameVersionsView 等平级，由 Index 挂载）。
 *
 * P1：离线账户的增 / 删 / 选中（对标 HMCL 账户管理）。
 * P2 将在此加入微软登录（Device Code）入口。
 * 持久化经 AccountsTools（Preferences，跨进程：主进程写、游戏进程读）。
 */
@ComponentV2
export struct AccountView {
  /** 共享账户状态（与其它组件同一实例）。 */
  @Local state: AccountState = getAccountState();

  /** 添加离线账户的输入名。 */
  @Local newName: string = '';

  /** 上次确认时的名字非法/重复标记。 */
  @Local invalid: boolean = false;

  /** 微软登录状态：进行中 / 设备码 / 校验地址 / 错误。 */
  @Local loggingIn: boolean = false;
  @Local deviceUserCode: string = '';
  @Local deviceUri: string = '';
  @Local authError: string = '';

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
    new AccountsTools(this.context()).setSelectedId(id);
    this.state.reload(this.context());
  }

  private remove(id: string): void {
    new AccountsTools(this.context()).remove(id);
    this.state.reload(this.context());
  }

  /** 发起微软登录（Device Code Flow）；updateId 非空 = 对已存在账户就地重新登录。 */
  private async doMicrosoftLogin(updateId: string): Promise<void> {
    this.authError = '';
    this.deviceUserCode = '';
    this.deviceUri = '';
    this.loggingIn = true;
    try {
      const clientId = new SettingsTools(this.context()).msClientId();
      if (clientId.length === 0) {
        this.authError = '未配置 Microsoft client_id：请先在「高级选项」填写你自注册的 Azure 公有客户端 id';
        return;
      }
      const r = await loginMicrosoft((d: DeviceCode) => {
        this.deviceUserCode = d.userCode;
        this.deviceUri = d.verificationUri;
      }, clientId);
      const tools = new AccountsTools(this.context());
      if (updateId.length > 0) {
        tools.updateMicrosoft(updateId, r);
      } else {
        tools.createMicrosoft(r);
      }
      this.state.reload(this.context());
    } catch (e) {
      this.authError = (e as Error).message;
    } finally {
      this.loggingIn = false;
      this.deviceUserCode = '';
      this.deviceUri = '';
    }
  }

  private startMicrosoftLogin(): void {
    this.doMicrosoftLogin('');
  }

  /** 刷新微软账户 token（强制续期）；失败（含 refresh 失效）显示错误。 */
  private async refreshMs(account: Account): Promise<void> {
    this.authError = '';
    this.loggingIn = true;
    try {
      await new AccountsTools(this.context()).ensureMicrosoftFresh(account, true);
      this.state.reload(this.context());
    } catch (e) {
      this.authError = (e as Error).message;
    } finally {
      this.loggingIn = false;
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
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.deviceUserCode);
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
        uri: this.deviceUri,
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

      if (this.state.accounts.length === 0) {
        Text($r('app.string.accounts_empty'))
          .opacity(OPACITY_SECONDARY);
      }
      Repeat<Account>(this.state.accounts)
        .each((obj: RepeatItem<Account>) => {
          Row({ space: LAYOUT_SPACE }) {
            Column() {
              Text(obj.item.name);
              // 生成的离线 UUID（创建即派生，与 launcher/原版一致）
              Text(obj.item.uuid.length > 0 ? obj.item.uuid : $r('app.string.accounts_uuid_pending'))
                .width('100%')
                .opacity(OPACITY_SECONDARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
            Text(this.typeLabel(obj.item.type))
              .opacity(OPACITY_SECONDARY);
            if (this.state.isSelected(obj.item.id)) {
              Text($r('app.string.accounts_selected'));
            } else {
              Button($r('app.string.accounts_select'))
                .onClick(() => this.select(obj.item.id));
            }
            // 微软账户操作：刷新 / 退出登录；已登出则重新登录
            if (obj.item.type === ACCOUNT_TYPE_MICROSOFT) {
              if ((obj.item.accessToken ?? '').length === 0) {
                Text($r('app.string.accounts_logged_out'))
                  .opacity(OPACITY_SECONDARY);
                Button($r('app.string.accounts_relogin'))
                  .enabled(!this.loggingIn)
                  .onClick(() => {
                    this.doMicrosoftLogin(obj.item.id);
                  });
              } else {
                Button($r('app.string.accounts_refresh'))
                  .enabled(!this.loggingIn)
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
          .width('100%')
          .padding(LAYOUT_PADDING_SMALL)
          .backgroundColor($r('app.color.brand_bg'))
          .borderRadius(BORDER_RADIUS);
        })
        .key((a: Account) => a.id);

      // 添加离线账户（名字进入即校验；回车/添加均可）
      Row({ space: LAYOUT_SPACE }) {
        TextInput({ text: this.newName, placeholder: $r('app.string.accounts_name_placeholder') })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.newName = v;
          })
          .onSubmit(() => this.addOffline());
        Button($r('app.string.accounts_add_offline'))
          .onClick(() => this.addOffline());
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
      if (this.invalid) {
        Text($r('app.string.accounts_name_invalid'))
          .opacity(OPACITY_SECONDARY);
      }

      // 微软正版登录（Device Code Flow：浏览器输码 → 轮询）
      Row({ space: LAYOUT_SPACE }) {
        Button($r('app.string.accounts_add_microsoft'))
          .enabled(!this.loggingIn)
          .onClick(() => this.startMicrosoftLogin());
      }
      .width('100%');
      if (this.deviceUserCode.length > 0) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.accounts_ms_instruction', this.deviceUri))
            .opacity(OPACITY_SECONDARY);
          Row({ space: LAYOUT_SPACE }) {
            Text(this.deviceUserCode)
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
      if (this.authError.length > 0) {
        Text($r('app.string.accounts_ms_error', this.authError))
          .opacity(OPACITY_SECONDARY);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
