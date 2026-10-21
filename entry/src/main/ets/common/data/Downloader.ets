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
 * 写盘合并阈值（字节）。
 *
 * `dataReceive` 的分片通常只有几 KB～几十 KB；若每片都 `writeSync`，一个 100 MiB 的
 * client jar 就是几千次同步系统调用，而同步写会占住 ArkTS 线程 —— 同一线程上其它
 * 并发下载的接收回调也被一起堵住。攒到 1 MiB 再落盘，系统调用次数降到百分之一量级。
 */
const WRITE_BUFFER_BYTES: number = 1024 * 1024;

/** 进度回调最小间隔（毫秒）：避免每个网络分片都触发一次 UI 状态更新。 */
const PROGRESS_INTERVAL_MS: number = 100;

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
    // 两个独立事件：流结束（dataEnd）与 HTTP 结果（requestInStream 回调）。
    // 以前 dataEnd 一到就 resolve，小响应（如镜像的 404 页面）会在状态码回来前被当成成功，
    // 结果把错误页落盘成 jar。现在必须两个都到齐、且状态码为 2xx 才 resolve。
    let streamEnded = false;
    let httpDone = false;
    let httpCode = 0;
    let httpError: Error | null = null;
    let finished = false;
    // 写盘缓冲：接收分片先攒在内存里，满一个阈值（或数据结束时）再同步写一次。
    const pending: Uint8Array = new Uint8Array(WRITE_BUFFER_BYTES);
    let pendingLen = 0;
    let writeError: Error | null = null;
    let lastProgressAt = 0;

    const flush = (): void => {
      if (file === null || pendingLen === 0) {
        return;
      }
      // 复制出恰好 pendingLen 字节：不能把缓冲区尾部未填充的部分写进文件。
      const out = new ArrayBuffer(pendingLen);
      new Uint8Array(out).set(pending.subarray(0, pendingLen));
      try {
        fileIo.writeSync(file.fd, out);
        pendingLen = 0;
      } catch (error) {
        writeError = new Error(`write failed: ${(error as BusinessError).message ?? ''}`);
      }
    };

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

    /** 两件事都到齐后一次性收尾：流结束 + 状态码。 */
    const finalize = (): void => {
      if (finished || !streamEnded || !httpDone) {
        return;
      }
      finished = true;
      flush();
      cleanup();
      if (httpError !== null) {
        reject(httpError);
        return;
      }
      if (httpCode < HTTP_STATUS_MIN || httpCode >= HTTP_STATUS_MAX) {
        reject(new Error(`HTTP ${httpCode}`));
        return;
      }
      if (writeError !== null) {
        // 以前静默忽略写失败，只在 sha1 校验里间接暴露；这里直接报出来，避免无谓的重试。
        reject(writeError);
        return;
      }
      resolve();
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
      if (file === null || writeError !== null) {
        return;
      }
      const chunk = new Uint8Array(data);
      let offset = 0;
      while (offset < chunk.length) {
        const space = pending.length - pendingLen;
        if (space === 0) {
          flush();
          if (writeError !== null) {
            return;
          }
          continue;
        }
        const take = Math.min(space, chunk.length - offset);
        pending.set(chunk.subarray(offset, offset + take), pendingLen);
        pendingLen += take;
        offset += take;
      }
      if (pendingLen === pending.length) {
        flush();
      }
    });
    request.on('dataEnd', () => {
      if (finished) {
        return;
      }
      streamEnded = true;
      finalize();
    });
    // 进度（需服务端返回 Content-Length；无则回调不触发，UI 侧按 total<=0 处理）。
    // 节流到 ~10Hz：多并发 worker 同时上报时，避免把 UI 状态刷成高频抖动。
    request.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
      if (onProgress === undefined) {
        return;
      }
      const now = Date.now();
      if (info.totalSize > 0 && now - lastProgressAt < PROGRESS_INTERVAL_MS) {
        return;
      }
      lastProgressAt = now;
      onProgress(info.receiveSize, info.totalSize);
    });

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: HTTP_CONNECT_TIMEOUT,
      readTimeout: HTTP_READ_TIMEOUT,
    };
    request.requestInStream(url, options, (err: BusinessError, code: number) => {
      if (finished) {
        return;
      }
      httpDone = true;
      httpCode = code;
      if (err) {
        // 连接/传输失败：不会再有关键的 dataEnd，立即失败，避免永久挂起。
        httpError = err;
        finished = true;
        cleanup();
        reject(err);
        return;
      }
      if (code < HTTP_STATUS_MIN || code >= HTTP_STATUS_MAX) {
        // 非 2xx：不必等 body 收完（镜像的 404 页面可能很小，也可能很大），立即失败。
        finished = true;
        cleanup();
        reject(new Error(`HTTP ${code}`));
        return;
      }
      finalize();
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
