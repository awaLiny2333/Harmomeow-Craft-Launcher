import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { loadAppSettings, loadAppSettingsOrDefault, loadAccounts, writeAccounts,
  writeAppSettings, tryReadAccounts, accountsFileExists } from './AppSettings';
import { ACCOUNTS_DIR, OFFLINE_TOKEN } from '../constants/LaunchDefaults';
import { CredentialExpiredError, MicrosoftResult, refreshMicrosoft, validateMcToken } from './MicrosoftAuth';
import { SettingsTools } from './SettingsTools';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'AccountsTools';

/** 账户类型。 */
export const ACCOUNT_TYPE_OFFLINE: string = 'offline';
export const ACCOUNT_TYPE_MICROSOFT: string = 'microsoft';

/**
 * 账户条目（**含微软 token，持久化于应用沙箱文件**）。
 *
 * 决策（2026-09-11，用户）：metadata 与 token（微软 access/refresh、notAfter、XSTS uhs）都持久化；
 * 应用私有区（`/data/storage/el2`）其他应用读不到，但**不加密**（随备份可外泄），接受此权衡以简化实现。
 * 2026-09-15 起从 Preferences 改为文件 `<filesDir>/meow-settings/accounts.json`（用户决定）；
 * 2026-09-15 二轮决策连 Preferences 及迁移代码一并删除（无历史迁移，旧值弃用）。
 * 日后若要更安全可换 **Asset Store**（`@ohos.security.asset`，`SECRET` ≤1024B，换签名证书会让旧资产读不到）。
 * 见 `notes/20-design/launch/账户系统-设计与进度.md` §4.2 与
 * `notes/20-design/launch/实例设置存储-方案.md` §3.3。
 */
export interface Account {
  /** 稳定内部 id（形如 'account:<毫秒时间戳>-<4位hex随机后缀>'，见 `newAccountId`）。 */
  id: string;
  /** offline | microsoft。 */
  type: string;
  /** 玩家名 / profile 名（也是账户文件名）。 */
  name: string;
  /** profileId（带横线 UUID）。离线留空 → 由 launcher 按名派生；微软为真实 UUID。 */
  uuid: string;
  // ---- 仅 microsoft（token 按用户决策存应用沙箱 accounts.json）----
  accessToken?: string;
  refreshToken?: string;
  /** MC access token 到期时间（epoch ms）。 */
  notAfter?: number;
  /** XSTS user hash（启动 --xuid 用）。 */
  xuid?: string;
}

/** 把无横线 32-hex UUID 规范为带横线形式；已是带横线则原样返回。 */
export function dashedUuid(id: string): string {
  const h = id.split('-').join('');
  if (h.length !== 32) {
    return id;
  }
  return `${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-` +
    `${h.substring(16, 20)}-${h.substring(20)}`;
}

/**
 * 玩家名合法性：可打印 ASCII 的 `[A-Za-z0-9_]`、长度 1–16。
 * 对齐现代 MC 服务端 `StringUtil.isValidPlayerName`（>32 && <127、≤16）与 HMCL 的离线校验。
 */
export function isValidPlayerName(name: string): boolean {
  if (name.length === 0 || name.length > 16) {
    return false;
  }
  for (let i = 0; i < name.length; i++) {
    const c = name.charCodeAt(i);
    const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
    if (!ok) {
      return false;
    }
  }
  return true;
}

/**
 * 规范的离线玩家 UUID（Java type-3）：md5("OfflinePlayer:" + name)，再置版本位=3 / RFC4122 变体位。
 * 与 launcher.jar 的 `Account.offlineUuid` 及原版客户端**完全一致**（如 `Player → a01e3843-e521-3998-958a-f459800e4d11`）。
 */
export function offlineUuid(name: string): string {
  try {
    const md = cryptoFramework.createMd('MD5');
    const msg = new util.TextEncoder().encodeInto(`OfflinePlayer:${name}`);
    md.updateSync({ data: msg });
    const b = new Uint8Array(md.digestSync().data);
    b[6] = (b[6] & 0x0f) | 0x30; // version 3
    b[8] = (b[8] & 0x3f) | 0x80; // variant RFC 4122
    let hex = '';
    for (let i = 0; i < b.length; i++) {
      const h = b[i].toString(16);
      hex += h.length === 1 ? `0${h}` : h;
    }
    return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-` +
      `${hex.substring(16, 20)}-${hex.substring(20)}`;
  } catch {
    // 计算失败 → 返回空串，由 launcher.jar 启动时按名派生兜底。
    return '';
  }
}

/** 把 epoch ms 格式化为本地时间「MM-DD HH:mm」（用于展示登录凭证有效期）。 */
export function formatExpiry(notAfter: number): string {
  const d = new Date(notAfter);
  const p = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 生成账户内部 id：`account:<毫秒时间戳>-<4 位 hex 随机后缀>`；后缀防同毫秒创建的两个账户撞 id 被去重覆盖。 */
function newAccountId(): string {
  const suffix = Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0');
  return `account:${Date.now()}-${suffix}`;
}

/**
 * 账户管理数据层（纯逻辑，不碰 UI）。
 * - 账户列表持久化在应用沙箱 `<filesDir>/meow-settings/accounts.json`；选中项指针
 *   `selectedAccount` 与目录共用 `app-settings.json`（见 `AppSettings.ets`）；Preferences 已彻底移除。
 * - `writeAccountFile` 生成 launcher.jar 读取的账户档案 `<meow-home>/accounts/<name>.json`
 *   （JSON 键 accessToken/clientToken/profileId/username/xuid 是硬契约，勿改名）。
 */
export class AccountsTools {
  /** 宿主上下文（解析应用沙箱路径，读全局设置里的 ms client_id）。 */
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 账户列表；无记录/解析失败返回空数组。 */
  list(): Account[] {
    const arr = loadAccounts<Account>(this.context);
    if (arr === null) {
      return [];
    }
    return arr.filter((a: Account) =>
      typeof a.id === 'string' && typeof a.name === 'string' && typeof a.type === 'string');
  }

  private save(list: Account[]): void {
    if (accountsFileExists(this.context) && tryReadAccounts<Account>(this.context) === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'accounts.json unreadable; accounts not written');
      return;
    }
    if (!writeAccounts<Account>(this.context, list)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write accounts failed');
    }
  }

  /** 按 id 去重后落库，返回该账户。 */
  add(account: Account): Account {
    const list = this.list().filter((a: Account) => a.id !== account.id);
    list.push(account);
    this.save(list);
    return account;
  }

  /** 创建离线账户（**创建即计算规范 UUID**）并落库；首个账户自动选中。 */
  createOffline(name: string): Account {
    const account: Account = {
      id: newAccountId(),
      type: ACCOUNT_TYPE_OFFLINE,
      name: name,
      uuid: offlineUuid(name),
    };
    this.add(account);
    if (this.selectedId().length === 0) {
      this.setSelectedId(account.id);
    }
    return account;
  }

  /** 为历史遗留（uuid 为空）的离线账户补算 UUID；有变更返回 true。 */
  backfillOfflineUuids(): boolean {
    const list = this.list();
    let changed = false;
    for (const a of list) {
      if (a.type === ACCOUNT_TYPE_OFFLINE && a.uuid.length === 0) {
        a.uuid = offlineUuid(a.name);
        changed = true;
      }
    }
    if (changed) {
      this.save(list);
    }
    return changed;
  }

  /** 由微软登录结果创建 microsoft 账户并落库；首个账户自动选中。 */
  createMicrosoft(r: MicrosoftResult): Account {
    const account: Account = {
      id: newAccountId(),
      type: ACCOUNT_TYPE_MICROSOFT,
      name: r.name,
      uuid: dashedUuid(r.uuid),
      accessToken: r.accessToken,
      refreshToken: r.refreshToken,
      notAfter: r.notAfter,
      xuid: r.xuid,
    };
    this.add(account);
    if (this.selectedId().length === 0) {
      this.setSelectedId(account.id);
    }
    return account;
  }

  /** 用新的微软登录/刷新结果更新账户（就地改 + 落库）。 */
  updateMicrosoft(id: string, r: MicrosoftResult): Account | null {
    const list = this.list();
    for (const a of list) {
      if (a.id === id) {
        a.name = r.name;
        a.uuid = dashedUuid(r.uuid);
        a.accessToken = r.accessToken;
        a.refreshToken = r.refreshToken;
        a.notAfter = r.notAfter;
        a.xuid = r.xuid;
        this.save(list);
        return a;
      }
    }
    return null;
  }

  /**
   * 微软账户 token 续期/校验（对齐 HMCL）：
   * - `force=true` 无条件刷新；否则 token 未过期（留 60s 余量）直接返回。
   * - `validate=true` 时未过期也调一次 `/minecraft/profile` 抓"提前吊销"（网络异常则信任本地 token）。
   * - 过期/吊销 → 用 refresh_token 走完整链换新 MC token（refresh_token 会轮换并落库）。
   * - refresh_token 失效 → 抛 `CredentialExpiredError`（调用方提示重新登录）。
   */
  async ensureMicrosoftFresh(account: Account, force: boolean = false,
    validate: boolean = false): Promise<Account> {
    if (account.type !== ACCOUNT_TYPE_MICROSOFT) {
      return account;
    }
    const notAfter = account.notAfter ?? 0;
    const token = account.accessToken ?? '';
    const fresh = token.length > 0 && Date.now() < notAfter - 60000;
    if (!force && fresh) {
      if (!validate) {
        return account;
      }
      try {
        if (await validateMcToken(token)) {
          return account;
        }
      } catch {
        return account;
      }
    }
    const rt = account.refreshToken ?? '';
    if (rt.length === 0) {
      throw new CredentialExpiredError('缺少 refresh token，请重新登录');
    }
    const r = await refreshMicrosoft(rt, this.readMsClientId());
    const updated = this.updateMicrosoft(account.id, r);
    return updated ?? account;
  }

  /** 读用户自填的 Microsoft client_id（应用级全局设置；空 = 未配置）。 */
  private readMsClientId(): string {
    return new SettingsTools(this.context).msClientId();
  }

  /** 退出登录：清除该微软账户的 token（保留账户条目，可重新登录）。 */
  logoutMicrosoft(id: string): void {
    const list = this.list();
    for (const a of list) {
      if (a.id === id) {
        a.accessToken = '';
        a.refreshToken = '';
        a.notAfter = 0;
        a.xuid = '';
        this.save(list);
        return;
      }
    }
  }

  /** 删除账户；若删的是当前选中项，回退到剩余首个（或空）。 */
  remove(id: string): void {
    const list = this.list().filter((a: Account) => a.id !== id);
    this.save(list);
    if (this.selectedId() === id) {
      this.setSelectedId(list.length > 0 ? list[0].id : '');
    }
  }

  selectedId(): string {
    const s = loadAppSettings(this.context);
    return s === null ? '' : s.selectedAccount;
  }

  setSelectedId(id: string): void {
    const s = loadAppSettingsOrDefault(this.context);
    if (s === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings unreadable; selected account not written');
      return;
    }
    s.selectedAccount = id;
    if (!writeAppSettings(this.context, s)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write selected account failed');
    }
  }

  /** 当前选中账户；无/失效返回 null。 */
  selected(): Account | null {
    const id = this.selectedId();
    for (const a of this.list()) {
      if (a.id === id) {
        return a;
      }
    }
    return null;
  }

  /**
   * 生成启动用账户档案 `<homeDir>/accounts/<name>.json`（launcher.jar 按文件名=玩家名加载）。
   * 离线：token 用离线常量、profileId 留空（launcher 派生 UUID）、xuid 空。
   * 微软：token 取自 Account 对象（随 accounts.json 落盘）、profileId 真实、xuid=uhs；
   * Asset Store（@ohos.security.asset）为可选的更安全替代（见 `Account` 注释），当前未用。
   */
  writeAccountFile(homeDir: string, account: Account): void {
    const accountsDir = `${homeDir}/${ACCOUNTS_DIR}`;
    const file = `${accountsDir}/${account.name}.json`;
    try {
      for (const d of [homeDir, accountsDir]) {
        try {
          fileIo.mkdirSync(d);
        } catch (e) {
          // 已存在则忽略
        }
      }
      const body = JSON.stringify({
        accessToken: account.type === ACCOUNT_TYPE_MICROSOFT
          ? (account.accessToken ?? OFFLINE_TOKEN) : OFFLINE_TOKEN,
        clientToken: '',
        profileId: account.uuid,
        username: account.name,
        xuid: account.type === ACCOUNT_TYPE_MICROSOFT ? (account.xuid ?? '') : ''
      });
      const f = fileIo.openSync(file, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
        fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, body);
      fileIo.closeSync(f);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'account file written: %{public}s', file);
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'write account file fail: %{public}s', JSON.stringify(e));
    }
  }
}
