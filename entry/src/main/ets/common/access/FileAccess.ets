import { common, OpenLinkOptions } from '@kit.AbilityKit';
import { picker, fileShare } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'FileAccess';

/**
 * 系统文件访问工具（Picker）。
 *
 * 为什么单独成文件：目录持久化（GameDirsTools）与 Picker 交互（本文件）是两类不同职责，
 * 不混在同一类中，便于各自独立演化。
 *
 * 鸿蒙文件权限背景：
 * - Picker 是系统预置选择器，本身无需申请权限；
 * - 选中的目录 URI 自带临时授权（App 退出即失效）；
 * - 授权状态不落盘，每次使用都需用户重新走一次 Picker。
 */

/**
 * 普通目录选择：用于「添加文件夹」。
 * 拉起系统文件选择器（FOLDER 模式），让用户从任意位置挑选目录。
 * 返回的 URI 自带临时读写授权，可直接用于本次会话。
 * 用户取消或调用失败时返回 null。
 */
export async function pickDirectory(context: common.Context): Promise<string | null> {
  const options = new picker.DocumentSelectOptions();
  options.selectMode = picker.DocumentSelectMode.FOLDER;
  const documentPicker = new picker.DocumentViewPicker(context);
  try {
    const uris = await documentPicker.select(options);
    return uris.length > 0 ? uris[0] : null;
  } catch {
    return null;
  }
}

/**
 * 授权模式目录选择：用于「激活」某个已记住的目录。
 *
 * 与 pickDirectory 的关键差异：设置 authMode=true 后，系统拉起的是"授权 Picker"，
 * 界面只会针对 defaultFilePathUri 指定的目录让用户确认授权，无法浏览 / 选择其它路径，
 * 从而把用户的访问范围锁定在预期目录上。
 *
 * 设备限制：authMode 仅在 2in1/PC 设备生效（本工程 deviceTypes 正是 2in1）；
 * 其余设备上该参数无效（退化为普通选择），调用不报错。
 *
 * @returns true 表示用户完成了一次授权选择（uris 非空）；取消或失败返回 false。
 */
export async function authorizeDirectory(context: common.Context, uri: string): Promise<boolean> {
  const options = new picker.DocumentSelectOptions();
  options.selectMode = picker.DocumentSelectMode.FOLDER;
  options.defaultFilePathUri = uri;
  options.authMode = true;
  const documentPicker = new picker.DocumentViewPicker(context);
  try {
    const uris = await documentPicker.select(options);
    return uris.length > 0;
  } catch {
    return false;
  }
}

// ---- 授权持久化（重启后免再次 Picker）----
// 机制：Picker 只给临时授权；fileShare.persistPermission 落库 → 每次启动 activatePermission 激活。
// 依赖系统能力 FolderAuthorization + 权限 ohos.permission.FILE_ACCESS_PERSIST（声明即可）。
// 卸载会清空持久化授权；重新安装需重新授权。

/** 设备是否支持目录授权持久化（SystemCapability...FolderAuthorization）。 */
export function folderAuthorizationSupported(): boolean {
  return canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization');
}

/** 读+写策略（对游戏目录需读写：写存档/日志）。 */
function rwPolicy(uri: string): fileShare.PolicyInfo {
  return {
    uri: uri,
    operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
  };
}

/** 打印 fileShare 策略错误：13900001 的具体原因在 err.data（PolicyErrorResult.code）。 */
function logPolicyError(tag: string,
  error: BusinessError<Array<fileShare.PolicyErrorResult>>): void {
  let detail = '';
  const data = error.data;
  if (data !== undefined) {
    for (const item of data) {
      detail += ` [uri=${item.uri} code=${item.code} msg=${item.message}]`;
    }
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s code=%{public}d msg=%{public}s%{public}s',
    tag, error.code, error.message, detail);
}

/**
 * 持久化目录授权（须先经 Picker 拿到临时授权）。返回是否成功；
 * 设备不支持或失败时返回 false（调用方退化为"本次会话临时授权"）。
 */
export async function persistDirectory(uri: string): Promise<boolean> {
  if (!folderAuthorizationSupported() || uri.length === 0) {
    return false;
  }
  const policies: fileShare.PolicyInfo[] = [rwPolicy(uri)];
  try {
    await fileShare.persistPermission(policies);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'persistPermission ok');
    return true;
  } catch (error) {
    logPolicyError('persistPermission fail',
      error as BusinessError<Array<fileShare.PolicyErrorResult>>);
    return false;
  }
}

/** 激活已持久化的目录授权（每次启动后按需调用）。返回是否成功。 */
export async function activateDirectory(uri: string): Promise<boolean> {
  if (!folderAuthorizationSupported() || uri.length === 0) {
    return false;
  }
  const policies: fileShare.PolicyInfo[] = [rwPolicy(uri)];
  try {
    await fileShare.activatePermission(policies);
    return true;
  } catch (error) {
    logPolicyError('activatePermission fail',
      error as BusinessError<Array<fileShare.PolicyErrorResult>>);
    return false;
  }
}

/** 取消某目录的持久化授权（移除目录时调用；best-effort）。 */
export async function revokeDirectory(uri: string): Promise<void> {
  if (!folderAuthorizationSupported() || uri.length === 0) {
    return;
  }
  const policies: fileShare.PolicyInfo[] = [rwPolicy(uri)];
  try {
    await fileShare.revokePermission(policies);
  } catch (error) {
    logPolicyError('revokePermission fail',
      error as BusinessError<Array<fileShare.PolicyErrorResult>>);
  }
}

/** 查询某目录是否已持久化授权（API 17+；诊断用）。 */
export async function isDirectoryPersisted(uri: string): Promise<boolean> {
  if (!folderAuthorizationSupported() || uri.length === 0) {
    return false;
  }
  try {
    const res = await fileShare.checkPersistentPermission([rwPolicy(uri)]);
    return res.length > 0 ? res[0] : false;
  } catch (error) {
    logPolicyError('checkPersistentPermission fail',
      error as BusinessError<Array<fileShare.PolicyErrorResult>>);
    return false;
  }
}

// ---- 在系统文件管理器中打开目录 ----

/**
 * 在**系统文件管理器**里打开某个目录（如 `versions/<id>/`）。
 *
 * 机制（官方 FAQ「如何跳转到系统文件管理App界面」+ `@ohos.app.ability.OpenLinkOptions`）：
 * `openLink('filemanager://openDirectory', { parameters: { fileUri } })`。
 *
 * ⚠️ `uri` 必须是**用户文件 URI**（`file://docs/storage/Users/...`，即 Picker 返回的形式）：
 * 文件管理器是另一个应用，只认这个命名空间。`fileUri.getUriFromPath(物理路径)` 得到的是
 * **应用沙箱 URI**（`file://<bundleName>/...`，见 fileuri 文档构造示例），不属于公共空间 → 打不开。
 * 故目标 URI 一律由「已授权的目录 URI + 相对子路径」拼出（见 Paths.versionDirUri）。
 *
 * best-effort：失败仅记日志，不阻塞 UI。
 */
export function showInFiles(uri: string, context: common.UIAbilityContext): void {
  if (uri.length === 0) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'showInFiles: empty uri');
    return;
  }
  const options: OpenLinkOptions = {
    parameters: {
      'fileUri': uri
    }
  };
  try {
    context.openLink('filemanager://openDirectory', options)
      .then(() => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'openLink filemanager ok');
      })
      .catch((err: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'openLink fail: %{public}d %{public}s',
          err.code, err.message);
      });
  } catch (error) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'openLink throw: %{public}s',
      (error as BusinessError).message);
  }
}
