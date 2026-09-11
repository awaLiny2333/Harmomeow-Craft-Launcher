import { http } from '@kit.NetworkKit';

/**
 * Minecraft 正版（Microsoft / Xbox Live）在线登录协议（纯逻辑，不碰 UI）。
 *
 * 四级链：MSA OAuth2(Device Code) → Xbox Live(XBL) → XSTS → Minecraft Services(login_with_xbox)
 * → entitlements/mcstore + minecraft/profile。见 notes/20-design/账户系统-离线与微软登录.md。
 *
 * client_id：先复用公开的 MC 客户端 id 跑通；正式发布建议自注册 Azure 公有客户端替换。
 * token 由调用方按用户决策存 Preferences（本文件不发请求之外的持久化）。
 */

/**
 * Microsoft client_id **不预置**：由用户在「高级选项」自填（存 Preferences，见 `SettingsTools.msClientId`）。
 * 用户需自注册 Azure 公有客户端：Supported account types = Personal Microsoft accounts only；
 * Allow public client flows = Yes。本文件所有登录/续期函数都必须收到非空 `clientId`。
 */

const TENANT: string = 'consumers';
const SCOPE: string = 'XboxLive.signin offline_access';
const DEVICE_CODE_URL: string = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/devicecode`;
const TOKEN_URL: string = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token`;
const XBL_URL: string = 'https://user.auth.xboxlive.com/user/authenticate';
const XSTS_URL: string = 'https://xsts.auth.xboxlive.com/xsts/authorize';
const MC_LOGIN_URL: string = 'https://api.minecraftservices.com/authentication/login_with_xbox';
const MC_ENTITLEMENTS_URL: string = 'https://api.minecraftservices.com/entitlements/mcstore';
const MC_PROFILE_URL: string = 'https://api.minecraftservices.com/minecraft/profile';

/** device code 申请结果（供 UI 展示 user_code / verification_uri）。 */
export interface DeviceCode {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  intervalSec: number;
  expiresInSec: number;
}

/** 微软登录最终产物（写入账户）。 */
export interface MicrosoftResult {
  /** profile 名（Minecraft 用户名）。 */
  name: string;
  /** 无横线 UUID（来自 /minecraft/profile 的 id）。 */
  uuid: string;
  /** MC access token（启动用）。 */
  accessToken: string;
  /** MSA refresh token（续期用）。 */
  refreshToken: string;
  /** XSTS 的 user hash（启动 --xuid 用）。 */
  xuid: string;
  /** MC access token 到期时间（epoch ms）。 */
  notAfter: number;
}

/** refresh_token 失效 → 必须重新登录（对齐 HMCL 的 CredentialExpiredException）。 */
export class CredentialExpiredError extends Error {
  constructor(message: string) {
    super(message);
  }
}

interface HttpResp {
  code: number;
  text: string;
}

// ---- 响应 JSON 形状（MS/JSON）----
interface DeviceCodeResp {
  device_code?: string;
  user_code?: string;
  verification_uri?: string;
  expires_in?: number;
  interval?: number;
  error?: string;
  error_description?: string;
}

interface TokenResp {
  access_token?: string;
  refresh_token?: string;
  error?: string;
  error_description?: string;
}

interface Xui {
  uhs?: string;
}

interface XblResp {
  Token?: string;
  DisplayClaims?: XblClaims;
  Identity?: string;
}

interface XblClaims {
  xui?: Xui[];
}

interface McLoginResp {
  access_token?: string;
  expires_in?: number;
  error?: string;
  errorMessage?: string;
}

interface McProfileResp {
  id?: string;
  name?: string;
}

interface XerrResp {
  XErr?: number;
}

// ---- 请求体形状（避免 ArkTS 未类型化对象字面量）----
interface XblAuthProps {
  AuthMethod: string;
  SiteName: string;
  RpsTicket: string;
}

interface XblAuthRequest {
  Properties: XblAuthProps;
  RelyingParty: string;
  TokenType: string;
}

interface XstsProps {
  SandboxId: string;
  UserTokens: string[];
}

interface XstsRequest {
  Properties: XstsProps;
  RelyingParty: string;
  TokenType: string;
}

interface McLoginRequest {
  identityToken: string;
}

// ---- HTTP helpers ----

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function formBody(pairs: string[][]): string {
  const parts: string[] = [];
  for (const p of pairs) {
    parts.push(`${encodeURIComponent(p[0])}=${encodeURIComponent(p[1])}`);
  }
  return parts.join('&');
}

async function httpSend(url: string, method: http.RequestMethod, header: Record<string, string>,
  body: string): Promise<HttpResp> {
  const req = http.createHttp();
  try {
    const opts: http.HttpRequestOptions = {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 20000,
      readTimeout: 30000,
    };
    if (body.length > 0) {
      opts.extraData = body;
    }
    const resp = await req.request(url, opts);
    const text = resp.result === undefined ? '' : resp.result as string;
    return { code: resp.responseCode, text: text };
  } catch (e) {
    throw new Error(`网络请求失败：${(e as Error).message}`);
  } finally {
    req.destroy();
  }
}

function jsonHeader(bearer: string): Record<string, string> {
  const h: Record<string, string> = { 'Accept': 'application/json', 'x-xbl-contract-version': '1' };
  if (bearer.length > 0) {
    h['Authorization'] = `Bearer ${bearer}`;
  }
  return h;
}

async function postForm(url: string, pairs: string[][]): Promise<HttpResp> {
  const h: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Accept': 'application/json',
  };
  return await httpSend(url, http.RequestMethod.POST, h, formBody(pairs));
}

async function postJson(url: string, json: string, bearer: string): Promise<HttpResp> {
  const h = jsonHeader(bearer);
  h['Content-Type'] = 'application/json';
  return await httpSend(url, http.RequestMethod.POST, h, json);
}

async function getJson(url: string, bearer: string): Promise<HttpResp> {
  return await httpSend(url, http.RequestMethod.GET, jsonHeader(bearer), '');
}

/** client_id 守卫：未配置（空）时给出可读错误。 */
function requireClientId(clientId: string): void {
  if (clientId.length === 0) {
    throw new Error('未配置 Microsoft client_id：请在「高级选项」填写你自注册的 Azure 公有客户端 id');
  }
}

// ---- 协议步骤 ----

/** 步骤 1：申请设备码（用户在浏览器输入 user_code）。 */
export async function requestDeviceCode(clientId: string): Promise<DeviceCode> {
  requireClientId(clientId);
  const r = await postForm(DEVICE_CODE_URL, [['client_id', clientId], ['scope', SCOPE]]);
  const body = JSON.parse(r.text) as DeviceCodeResp;
  if (r.code !== 200 || body.device_code === undefined || body.user_code === undefined) {
    throw new Error(describeMsError(r.code, body.error, body.error_description));
  }
  return {
    deviceCode: body.device_code,
    userCode: body.user_code,
    verificationUri: body.verification_uri ?? 'https://microsoft.com/link',
    intervalSec: body.interval ?? 5,
    expiresInSec: body.expires_in ?? 900,
  };
}

/**
 * 步骤 2：轮询换取 MSA token。
 * 处理 authorization_pending / slow_down（加大间隔）/ expired_token / 其它错误。
 */
export async function pollMsaToken(device: DeviceCode, clientId: string): Promise<TokenResp> {
  let intervalMs = device.intervalSec * 1000;
  const deadline = Date.now() + device.expiresInSec * 1000;
  while (Date.now() < deadline) {
    await delay(intervalMs);
    const r = await postForm(TOKEN_URL, [
      ['grant_type', 'urn:ietf:params:oauth:grant-type:device_code'],
      ['client_id', clientId],
      ['device_code', device.deviceCode],
    ]);
    if (r.code === 200) {
      const body = JSON.parse(r.text) as TokenResp;
      if (body.access_token !== undefined) {
        return body;
      }
    }
    const err = JSON.parse(r.text) as TokenResp;
    switch (err.error) {
      case 'authorization_pending':
        continue;
      case 'slow_down':
        intervalMs += 5000;
        continue;
      case 'expired_token':
        throw new Error('设备码已过期，请重试');
      case 'authorization_declined':
        throw new Error('用户拒绝授权');
      default:
        throw new Error(describeMsError(r.code, err.error, err.error_description));
    }
  }
  throw new Error('登录超时，请重试');
}

/** 用 refresh_token 续期 MSA token（refresh_token 会轮换，调用方须保存新值）。 */
export async function refreshMsaToken(refreshToken: string, clientId: string): Promise<TokenResp> {
  requireClientId(clientId);
  const r = await postForm(TOKEN_URL, [
    ['grant_type', 'refresh_token'],
    ['client_id', clientId],
    ['refresh_token', refreshToken],
    ['scope', SCOPE],
  ]);
  const body = JSON.parse(r.text) as TokenResp;
  if (r.code !== 200 || body.access_token === undefined) {
    if (body.error === 'invalid_grant') {
      throw new CredentialExpiredError('登录凭据已失效，请重新登录');
    }
    throw new Error(describeMsError(r.code, body.error, body.error_description));
  }
  return body;
}

/** 步骤 3：Xbox Live 用户认证 → {token, uhs}。 */
export async function authenticateXbl(msaAccessToken: string): Promise<XblStep> {
  const req: XblAuthRequest = {
    Properties: {
      AuthMethod: 'RPS',
      SiteName: 'user.auth.xboxlive.com',
      RpsTicket: `d=${msaAccessToken}`,
    },
    RelyingParty: 'http://auth.xboxlive.com',
    TokenType: 'JWT',
  };
  const json = JSON.stringify(req);
  const r = await postJson(XBL_URL, json, '');
  const body = JSON.parse(r.text) as XblResp;
  const uhs = xuiOf(body);
  if (r.code !== 200 || body.Token === undefined || uhs.length === 0) {
    throw new Error(`Xbox Live 认证失败（HTTP ${r.code}）`);
  }
  return { token: body.Token, uhs: uhs };
}

/** 步骤 4：XSTS 授权 → {token, uhs}；含常见 XErr 错误码。 */
export async function authorizeXsts(xblToken: string): Promise<XblStep> {
  const req: XstsRequest = {
    Properties: { SandboxId: 'RETAIL', UserTokens: [xblToken] },
    RelyingParty: 'rp://api.minecraftservices.com/',
    TokenType: 'JWT',
  };
  const json = JSON.stringify(req);
  const r = await postJson(XSTS_URL, json, '');
  if (r.code !== 200) {
    const xerr = extractXerr(r.text);
    throw new Error(describeXstsError(xerr, r.code));
  }
  const body = JSON.parse(r.text) as XblResp;
  const uhs = xuiOf(body);
  if (body.Token === undefined || uhs.length === 0) {
    throw new Error('XSTS 授权返回异常');
  }
  return { token: body.Token, uhs: uhs };
}

/** 步骤 5：用 XSTS 换 Minecraft access token。 */
export async function loginWithXbox(uhs: string, xstsToken: string): Promise<McLoginStep> {
  const json = JSON.stringify({ identityToken: `XBL3.0 x=${uhs};${xstsToken}` } as McLoginRequest);
  const r = await postJson(MC_LOGIN_URL, json, '');
  const body = JSON.parse(r.text) as McLoginResp;
  if (r.code !== 200 || body.access_token === undefined) {
    throw new Error(`Minecraft 登录失败（HTTP ${r.code}）`);
  }
  const expiresIn = body.expires_in ?? 86400;
  return { accessToken: body.access_token, notAfter: Date.now() + expiresIn * 1000 };
}

/** 步骤 6：查询所有权（200 = 有 Java 版）。 */
export async function hasMcEntitlement(mcToken: string): Promise<boolean> {
  const r = await getJson(MC_ENTITLEMENTS_URL, mcToken);
  return r.code === 200;
}

/** 步骤 7：取档案（UUID 无横线 + 名）。 */
export async function fetchMcProfile(mcToken: string): Promise<McProfile> {
  const r = await getJson(MC_PROFILE_URL, mcToken);
  if (r.code !== 200) {
    throw new Error(`获取 Minecraft 档案失败（HTTP ${r.code}）：该账户可能未拥有 Java 版或未创建档案`);
  }
  const body = JSON.parse(r.text) as McProfileResp;
  if (body.id === undefined || body.name === undefined) {
    throw new Error('Minecraft 档案响应异常');
  }
  return { id: body.id, name: body.name };
}

/** 校验 MC token 是否仍有效（调 /minecraft/profile；200=有效）。网络异常会抛出，由调用方区分。 */
export async function validateMcToken(mcToken: string): Promise<boolean> {
  const r = await getJson(MC_PROFILE_URL, mcToken);
  return r.code === 200;
}

export interface XblStep {
  token: string;
  uhs: string;
}

export interface McLoginStep {
  accessToken: string;
  notAfter: number;
}

export interface McProfile {
  id: string;
  name: string;
}

/** 由 MSA token 走完整链得到最终产物（新登与刷新共用）。 */
async function finishWithMsa(msa: TokenResp): Promise<MicrosoftResult> {
  if (msa.access_token === undefined || msa.refresh_token === undefined) {
    throw new Error('MSA token 缺失');
  }
  const xbl = await authenticateXbl(msa.access_token);
  const xsts = await authorizeXsts(xbl.token);
  const login = await loginWithXbox(xsts.uhs, xsts.token);
  if (!(await hasMcEntitlement(login.accessToken))) {
    throw new Error('该账户未拥有 Minecraft Java 版');
  }
  const profile = await fetchMcProfile(login.accessToken);
  return {
    name: profile.name,
    uuid: profile.id,
    accessToken: login.accessToken,
    refreshToken: msa.refresh_token,
    xuid: xsts.uhs,
    notAfter: login.notAfter,
  };
}

/** 全新登录：申请设备码 → 轮询 → 走完整链。UI 用 onDevice 展示 user_code/URI。 */
export async function loginMicrosoft(onDevice: (d: DeviceCode) => void,
  clientId: string): Promise<MicrosoftResult> {
  const device = await requestDeviceCode(clientId);
  onDevice(device);
  const msa = await pollMsaToken(device, clientId);
  return await finishWithMsa(msa);
}

/** 续期：refresh_token → 新 MSA token → 完整链（返回含轮换后的 refreshToken）。 */
export async function refreshMicrosoft(refreshToken: string,
  clientId: string): Promise<MicrosoftResult> {
  const msa = await refreshMsaToken(refreshToken, clientId);
  return await finishWithMsa(msa);
}

// ---- 错误信息 ----

function xuiOf(body: XblResp): string {
  const xui = body.DisplayClaims?.xui;
  if (xui === undefined || xui.length === 0) {
    return '';
  }
  return xui[0].uhs ?? '';
}

function extractXerr(text: string): number {
  try {
    const obj = JSON.parse(text) as XerrResp;
    return obj.XErr ?? 0;
  } catch {
    return 0;
  }
}

function describeXstsError(xerr: number, code: number): string {
  if (xerr === 2148916227) {
    return '该 Xbox 账户已被封禁';
  }
  if (xerr === 2148916233) {
    return '该账户没有 Xbox Live 账号（请先在 xbox.com 创建）';
  }
  if (xerr === 2148916235) {
    return '该账户所在国家/地区不支持 Xbox Live';
  }
  if (xerr === 2148916236 || xerr === 2148916237) {
    return '该账户需要完成成人验证';
  }
  if (xerr === 2148916238) {
    return '未成年账户需先加入 Microsoft 家庭组';
  }
  return `XSTS 授权失败（HTTP ${code}${xerr !== 0 ? `, XErr ${xerr}` : ''}）`;
}

function describeMsError(code: number, error?: string, desc?: string): string {
  if (error !== undefined && error.length > 0) {
    return `微软登录失败：${error}${desc !== undefined && desc.length > 0 ? `（${desc}）` : ''}`;
  }
  return `微软登录失败（HTTP ${code}）`;
}
