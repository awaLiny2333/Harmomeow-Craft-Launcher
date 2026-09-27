import { MsAuthError, MsAuthErrorCode } from '../common/data/MicrosoftAuth';

/**
 * 微软登录错误 → string 资源。**UI 层唯一的「码 → 文案」映射点**：
 * 逻辑层（MicrosoftAuth）只抛 MsAuthError 码，不硬编码文案（见 工程与规范 §二.7）。
 */
export function msAuthErrorText(e: MsAuthError | null): Resource {
  if (e === null) {
    return $r('app.string.ms_err_unknown');
  }
  switch (e.code) {
    case MsAuthErrorCode.CLIENT_ID_MISSING:
      return $r('app.string.accounts_ms_no_client_id');
    case MsAuthErrorCode.NETWORK:
      return $r('app.string.ms_err_network', e.detail);
    case MsAuthErrorCode.DEVICE_CODE_EXPIRED:
      return $r('app.string.ms_err_device_code_expired');
    case MsAuthErrorCode.DECLINED:
      return $r('app.string.ms_err_declined');
    case MsAuthErrorCode.TIMEOUT:
      return $r('app.string.ms_err_timeout');
    case MsAuthErrorCode.CREDENTIAL_EXPIRED:
      return $r('app.string.ms_err_credential_expired');
    case MsAuthErrorCode.NO_REFRESH_TOKEN:
      return $r('app.string.ms_err_no_refresh_token');
    case MsAuthErrorCode.NO_ENTITLEMENT:
      return $r('app.string.ms_err_no_entitlement');
    case MsAuthErrorCode.PROFILE_BAD:
      return $r('app.string.ms_err_profile_bad');
    case MsAuthErrorCode.MSA_MISSING:
      return $r('app.string.ms_err_msa_missing');
    case MsAuthErrorCode.XBL_HTTP:
      return $r('app.string.ms_err_xbl_http', e.status);
    case MsAuthErrorCode.MC_LOGIN_HTTP:
      return $r('app.string.ms_err_mc_login_http', e.status);
    case MsAuthErrorCode.MC_PROFILE_HTTP:
      return $r('app.string.ms_err_mc_profile_http', e.status);
    case MsAuthErrorCode.XSTS_BANNED:
      return $r('app.string.ms_err_xsts_banned');
    case MsAuthErrorCode.XSTS_NO_XBOX:
      return $r('app.string.ms_err_xsts_no_xbox');
    case MsAuthErrorCode.XSTS_REGION:
      return $r('app.string.ms_err_xsts_region');
    case MsAuthErrorCode.XSTS_ADULT:
      return $r('app.string.ms_err_xsts_adult');
    case MsAuthErrorCode.XSTS_FAMILY:
      return $r('app.string.ms_err_xsts_family');
    case MsAuthErrorCode.XSTS_BAD_RESPONSE:
      return $r('app.string.ms_err_xsts_bad');
    case MsAuthErrorCode.XSTS_GENERIC:
      return e.detail.length > 0
        ? $r('app.string.ms_err_xsts_generic_xerr', e.status, e.detail)
        : $r('app.string.ms_err_xsts_generic', e.status);
    case MsAuthErrorCode.OAUTH_GENERIC:
      return $r('app.string.ms_err_oauth_generic', e.detail);
    case MsAuthErrorCode.OAUTH_HTTP:
      return $r('app.string.ms_err_oauth_http', e.status);
    default:
      return $r('app.string.ms_err_unknown');
  }
}
