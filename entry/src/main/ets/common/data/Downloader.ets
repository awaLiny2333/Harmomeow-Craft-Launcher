import { http } from '@kit.NetworkKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HASH_ALGORITHM, HTTP_CONNECT_TIMEOUT, HTTP_READ_TIMEOUT, HTTP_STATUS_MAX,
  HTTP_STATUS_MIN } from '../constants/DownloadContract';
import { DOWNLOAD_PART_SUFFIX } from '../constants/Paths';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'Downloader';

/**
 * 网络下载原语（与业务无关）：拉文本、下文件（流式落盘 + 校验）。
 *
 * 设计：
 * - 所有对外函数接收"候选地址列表"（镜像优先、官方兜底），逐个尝试直到成功；
 * - 大文件一律流式写盘（requestInStream + dataReceive），不整块进内存；
 * - 校验用 @kit.CoreFileKit 的 hash.hash（sha1，返回大写十六进制，比较时统一小写）；
 * - 落盘走"临时 .part → 校验 → rename"，避免半截文件被当成完整文件。
 */

/** 删除文件，忽略不存在等错误。 */
function removeQuietly(path: string): void {
  try {
    fileIo.unlinkSync(path);
  } catch {
    // 目标不存在时忽略
  }
}

/**
 * 拉取文本（版本清单 / 版本 json / 资源索引）。
 * 依次尝试候选地址；全部失败则抛错（错误信息含最后一次失败原因）。
 *
 * @param alsoAccept 额外"也算成功"的状态码（如以 4xx + 空数组表达"无结果"的端点）；
 *                   不传时行为与只认 2xx 完全一致。
 */
export async function fetchText(candidates: string[], alsoAccept?: number[]): Promise<string> {
  let lastError = 'no candidate';
  for (const url of candidates) {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_CONNECT_TIMEOUT,
        readTimeout: HTTP_READ_TIMEOUT,
      };
      const resp = await request.request(url, options);
      const code = resp.responseCode;
      const result = resp.result;
      request.destroy();
      const ok = (code >= HTTP_STATUS_MIN && code < HTTP_STATUS_MAX)
        || (alsoAccept !== undefined && alsoAccept.includes(code));
      if (ok && typeof result === 'string') {
        return result;
      }
      lastError = `HTTP ${code}`;
    } catch (error) {
      const err = error as BusinessError;
      request.destroy();
      lastError = err.message ?? `code ${err.code}`;
    }
  }
  throw new Error(lastError);
}

/**
 * 把 URL 流式写入文件（内部使用）。
 * 成功 resolve；HTTP 非 2xx 或异常 reject。
 */
function streamToFile(url: string, filePath: string,
  onProgress?: (received: number, total: number) => void): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
    const request = http.createHttp();
    let file: fileIo.File | null = null;
    let settled = false;

    const cleanup = (): void => {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch {
          // 忽略关闭异常
        }
        file = null;
      }
      request.destroy();
    };

    try {
      file = fileIo.openSync(filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    } catch (error) {
      request.destroy();
      reject(new Error(`open failed: ${(error as BusinessError).message ?? ''}`));
      return;
    }

    request.on('dataReceive', (data: ArrayBuffer) => {
      if (file !== null) {
        try {
          fileIo.writeSync(file.fd, data);
        } catch {
          // 写入失败交由后续校验/HTTP 结果暴露
        }
      }
    });
    request.on('dataEnd', () => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve();
    });
    // 进度（需服务端返回 Content-Length；无则回调不触发，UI 侧按 total<=0 处理）。
    request.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
      if (onProgress !== undefined) {
        onProgress(info.receiveSize, info.totalSize);
      }
    });

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: HTTP_CONNECT_TIMEOUT,
      readTimeout: HTTP_READ_TIMEOUT,
    };
    request.requestInStream(url, options, (err: BusinessError, code: number) => {
      if (settled) {
        return;
      }
      if (err || code < HTTP_STATUS_MIN || code >= HTTP_STATUS_MAX) {
        settled = true;
        cleanup();
        reject(new Error(`HTTP ${code}`));
      }
    });
  });
}

/**
 * 下载单个文件到目标路径（候选地址逐个尝试 + sha1 校验）。
 *
 * @param candidates  候选地址（镜像优先、官方兜底）
 * @param destPath    最终目标路径（父目录须已存在）
 * @param expectedSha1 期望 sha1（小写或大写均可）；空串表示不校验
 */
export async function downloadFile(candidates: string[], destPath: string,
  expectedSha1: string, onProgress?: (received: number, total: number) => void): Promise<void> {
  const tempPath = destPath + DOWNLOAD_PART_SUFFIX;
  let lastError = 'no candidate';
  for (const url of candidates) {
    removeQuietly(tempPath);
    try {
      await streamToFile(url, tempPath, onProgress);
      if (expectedSha1.length > 0) {
        const actual = await hash.hash(tempPath, HASH_ALGORITHM);
        if (actual.toLowerCase() !== expectedSha1.toLowerCase()) {
          lastError = `sha1 mismatch: ${actual}`;
          hilog.info(LOG_DOMAIN, LOG_TAG,
            'sha1 mismatch file=%{public}s expected=%{public}s actual=%{public}s',
            destPath, expectedSha1, actual);
          removeQuietly(tempPath);
          continue;
        }
      }
      removeQuietly(destPath);
      fileIo.renameSync(tempPath, destPath);
      return;
    } catch (error) {
      const err = error as BusinessError;
      lastError = err.message ?? `code ${err.code}`;
      removeQuietly(tempPath);
    }
  }
  throw new Error(lastError);
}
