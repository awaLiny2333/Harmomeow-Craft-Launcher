import { http } from '@kit.NetworkKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HASH_ALGORITHM, HTTP_CONNECT_TIMEOUT, HTTP_READ_TIMEOUT, HTTP_STATUS_MAX,
  HTTP_STATUS_MIN } from '../constants/DownloadContract';
import { DOWNLOAD_PART_SUFFIX } from '../constants/Paths';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'Downloader';

/** 2xx 里「按协议即无 body」的两个码：直接判失败，绝不等 `dataEnd`。 */
const HTTP_STATUS_NO_CONTENT: number = 204;
const HTTP_STATUS_RESET_CONTENT: number = 205;

/**
 * 空闲看门狗 (毫秒)：超过这么久没收到任何字节/事件，就判定请求已挂起。
 *
 * 存在的理由：`readTimeout` 的语义在官方文档里自相矛盾（API 参考说「读超时」，
 * 开发指南说「从请求开始到结束的总时间」），且「没有 pending 读」时可能根本不触发。
 * 一旦库不再回调，没有这层兜底就是**永久挂起**（文件不关、worker 不返回、安装锁不清）。
 * 这层看门狗把「挂起」降级为「有界失败」，让候选地址回退逻辑能接手。
 *
 * 取 60 s：大于 connectTimeout(30 s)，小于 readTimeout(120 s)；只要还在收数据就不断重置。
 */
const IDLE_TIMEOUT_MS: number = 60 * 1000;
const WATCHDOG_TICK_MS: number = 1000;

/**
 * 本次流式落盘是否发生了**本机** I/O 失败（open / write / close / 短写）。
 *
 * 换镜像对这类错误没有任何意义（磁盘满、fd 耗尽、权限不够都是本机状态），调用方必须
 * 据此**立即终止候选列表**，否则一次 ENOSPC 会把整套镜像挨个试一遍。
 * 用显式输出标志而不是自定义 Error 子类：ArkTS 不支持结构类型，`class X extends Error`
 * 在「赋给 Error 形参」处会触发 `arkts-no-structural-typing`。
 */
interface StreamOutcome {
  localFailure: boolean;
}

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
 *
 * 结算契约（见 `notes/20-design/launch/下载器-可靠性方案.md`）：
 * - 非 2xx / 传输错误：**立即**失败，不等 body（镜像的 404 页面永远进不了磁盘）；
 * - 成功：必须「最终状态码 2xx」且「body 完成已证明」（`dataEnd`；204/205 按协议无 body）；
 * - 任何可能永不发生的等待都由**空闲看门狗**兜底 ⇒ 挂起降级为有界失败；
 * - 本地 I/O 失败（open/write/短写/close）通过 `outcome.localFailure` 上报，调用方据此停止换镜像。
 */
function streamToFile(url: string, filePath: string,
  onProgress: ((received: number, total: number) => void) | undefined,
  outcome: StreamOutcome): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
    const request = http.createHttp();
    let file: fileIo.File | null = null;
    let finished = false;
    let streamEnded = false;
    let httpDone = false;
    let httpCode = 0;
    let httpError: Error | null = null;
    // 写盘：分片先攒在 staging 里，满了再一次性写；失败后一个字节都不再落盘。
    // staging 与 pending 分开持有：WriteOptions 没有 buffer 内偏移，写入必须以 staging 起点为 0。
    const staging: ArrayBuffer = new ArrayBuffer(WRITE_BUFFER_BYTES);
    const pending: Uint8Array = new Uint8Array(staging);
    let pendingLen = 0;
    let writeError: Error | null = null;
    // 完整性账目：与服务端声明的长度比对，抓「传输层给了 dataEnd 但 body 是残的」。
    let received = 0;
    let declaredLength = -1;
    let lastActivityAt = Date.now();
    let watchdogId: number = -1;
    let lastProgressAt = 0;

    /** 标记「本机 I/O 失败」并造出错误对象：调用方看到该标志就不再换镜像。 */
    const localFailure = (message: string): Error => {
      outcome.localFailure = true;
      return new Error(message);
    };

    const stopWatchdog = (): void => {
      if (watchdogId !== -1) {
        clearInterval(watchdogId);
        watchdogId = -1;
      }
    };

    /** 关文件并返回错误。close 才是 ENOSPC 最常暴露的地方，不能吞。 */
    const closeFile = (): Error | null => {
      if (file === null) {
        return null;
      }
      const opened = file;
      file = null;
      try {
        fileIo.closeSync(opened);
        return null;
      } catch (error) {
        return localFailure(`close failed: ${(error as BusinessError).message ?? ''}`);
      }
    };

    const destroyRequest = (): void => {
      try {
        request.destroy();
      } catch {
        // 销毁失败不能阻止结算（否则 finished 已置位却既不 resolve 也不 reject）
      }
    };

    /**
     * 把攒下的字节落盘。
     *
     * 不带 `offset`：`offset` 是**绝对文件位置**（pwrite 语义），传 0 会让每次 flush 都写回
     * 文件头且 fd 位置不推进 ⇒ 文件被覆盖。只传 `length` 时 offset 取 -1，走 write(2)
     * 在当前位置写并推进，既裁掉了缓冲区尾部的脏数据，又不需要先复制一份。
     */
    const flush = (): void => {
      const opened = file;
      if (opened === null || pendingLen === 0 || writeError !== null) {
        return;
      }
      const want = pendingLen;
      try {
        const written = fileIo.writeSync(opened.fd, staging, { length: want });
        if (written !== want) {
          // 短写：WriteOptions 没有 buffer 内偏移，无法安全续写同一缓冲 ⇒ 判失败
          writeError = localFailure(`short write: ${written}/${want}`);
          pendingLen = 0;
          return;
        }
        pendingLen = 0;
      } catch (error) {
        writeError = localFailure(`write failed: ${(error as BusinessError).message ?? ''}`);
        pendingLen = 0;
      }
    };

    /**
     * 进度发射器（本文件的**唯一**流内上报出口）：节流到 ~10Hz，并统一守住前置条件。
     *
     * total 只取「服务端声明长度」：`declaredLength` 未给时上报 0，由上层按“长度未知”处理。
     * 上报走**累计字节** `received`（由 `dataReceive` 维护），而不是某个事件的载荷 —— 于是
     * 服务端不给 `Content-Length` 时读数照样推进。
     */
    const emitProgress = (): void => {
      if (finished || writeError !== null || onProgress === undefined) {
        return;
      }
      if (received <= 0) {
        return;
      }
      const now = Date.now();
      if (now - lastProgressAt < PROGRESS_INTERVAL_MS) {
        return;
      }
      lastProgressAt = now;
      try {
        onProgress(received, declaredLength > 0 ? declaredLength : 0);
      } catch {
        // UI 回调异常不得影响下载状态机
      }
    };

    /** 唯一失败出口：丢弃缓冲 → destroy → close → 恰好结算一次。 */
    const fail = (err: Error): void => {
      if (finished) {
        return;
      }
      finished = true;
      stopWatchdog();
      pendingLen = 0;
      destroyRequest();
      const closeErr = closeFile();
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'download failed file=%{public}s code=%{public}d received=%{public}d declared=%{public}d err=%{public}s close=%{public}s',
        filePath, httpCode, received, declaredLength, err.message,
        closeErr === null ? 'ok' : closeErr.message);
      reject(err);
    };

    /** 唯一成功出口：两个事件齐备后才走这里，同样恰好结算一次。 */
    const finalize = (): void => {
      if (finished || !streamEnded || !httpDone) {
        return;
      }
      finished = true;
      stopWatchdog();
      flush();
      const closeErr = closeFile();
      destroyRequest();
      if (httpError !== null) {
        reject(httpError);
        return;
      }
      if (httpCode < HTTP_STATUS_MIN || httpCode >= HTTP_STATUS_MAX) {
        reject(new Error(`HTTP ${httpCode}`));
        return;
      }
      if (declaredLength > 0 && received < declaredLength) {
        // 传输层说「收完了」但收到的字节比声明少：残包不能靠 sha1 兜（空 sha1 的调用点尤其危险）。
        // 只用「少于」判定：多于声明长度不算截断（有些链路会自动解压，字节数天然对不上）。
        reject(new Error(`truncated: ${received}/${declaredLength}`));
        return;
      }
      if (writeError !== null) {
        reject(writeError);
        return;
      }
      if (closeErr !== null) {
        reject(closeErr);
        return;
      }
      // 落盘字节数必须等于收到的字节数：这一条同时兜住「短写」和「写偏移语义写错」，
      // 对没有 sha1 的调用点（安装器 jar）是唯一的内容自检。
      let finalSize = -1;
      try {
        finalSize = fileIo.statSync(filePath).size;
      } catch {
        reject(new Error('stat failed after close'));
        return;
      }
      if (finalSize !== received) {
        reject(new Error(`size mismatch: disk=${finalSize} received=${received}`));
        return;
      }
      // 结算补发已移到 `downloadFile`（rename 成功之后）：此处只做状态机结算，不动进度。
      hilog.info(LOG_DOMAIN, LOG_TAG, 'downloaded file=%{public}s bytes=%{public}d code=%{public}d',
        filePath, received, httpCode);
      resolve();
    };

    try {
      file = fileIo.openSync(filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    } catch (error) {
      destroyRequest();
      finished = true;
      reject(localFailure(`open failed: ${(error as BusinessError).message ?? ''}`));
      return;
    }

    request.on('dataReceive', (data: ArrayBuffer) => {
      if (finished || writeError !== null) {
        return;
      }
      lastActivityAt = Date.now();
      const chunk = new Uint8Array(data);
      received += chunk.length;
      let offset = 0;
      while (offset < chunk.length) {
        if (pendingLen === pending.length) {
          flush();
          if (writeError !== null) {
            // 磁盘满/短写：立刻停，不等 body、也不等状态码
            fail(writeError);
            return;
          }
        }
        const take = Math.min(pending.length - pendingLen, chunk.length - offset);
        pending.set(chunk.subarray(offset, offset + take), pendingLen);
        pendingLen += take;
        offset += take;
      }
      // 每收一片就尝试上报一次（节流在发射器里）：这条路不依赖 Content-Length。
      emitProgress();
    });
    request.on('dataEnd', () => {
      if (finished) {
        return;
      }
      streamEnded = true;
      lastActivityAt = Date.now();
      finalize();
    });
    // 进度（服务端给 Content-Length 时才有此事件）。
    // 职责收窄为：记录声明长度（完整性账目）→ 交给同一个发射器（节流会自然去重）。
    request.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
      if (finished) {
        return;
      }
      lastActivityAt = Date.now();
      // totalSize 就是声明长度：先记账，再决定要不要回调 UI（节流不能影响完整性判断）
      if (info.totalSize > 0) {
        declaredLength = info.totalSize;
      }
      emitProgress();
    });

    // 看门狗：只要还在收数据就一直重置；静默超时就把「挂起」变成「失败」。
    watchdogId = setInterval(() => {
      if (finished) {
        return;
      }
      if (Date.now() - lastActivityAt < IDLE_TIMEOUT_MS) {
        return;
      }
      fail(new Error(`idle timeout ${IDLE_TIMEOUT_MS}ms received=${received}`));
    }, WATCHDOG_TICK_MS);

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: HTTP_CONNECT_TIMEOUT,
      readTimeout: HTTP_READ_TIMEOUT,
    };
    try {
      request.requestInStream(url, options, (err: BusinessError, code: number) => {
        if (finished) {
          return;
        }
        httpDone = true;
        httpCode = code;
        lastActivityAt = Date.now();
        if (err) {
          // 连接/传输失败：不会再有 dataEnd，立即失败
          httpError = err;
          fail(err);
          return;
        }
        if (code < HTTP_STATUS_MIN || code >= HTTP_STATUS_MAX) {
          // 非 2xx：不必等 body 收完（镜像的 404 页面可小可大），立即失败
          fail(new Error(`HTTP ${code}`));
          return;
        }
        if (code === HTTP_STATUS_NO_CONTENT || code === HTTP_STATUS_RESET_CONTENT) {
          // 协议规定无 body ⇒ 永远等不到 dataEnd，直接判失败（0 字节不是合法产物）
          fail(new Error(`HTTP ${code} without body`));
          return;
        }
        finalize();
      });
    } catch (error) {
      fail(new Error(`start failed: ${(error as BusinessError).message ?? ''}`));
    }
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
    // 每次尝试单独记账：上一次的本地失败不能污染下一次候选
    const outcome: StreamOutcome = { localFailure: false };
    try {
      await streamToFile(url, tempPath, onProgress, outcome);
      // 0 字节产物绝不 rename 进正式名：204/镜像返回空 body/中途关流的最后一道闸。
      const st = fileIo.statSync(tempPath);
      if (st.size === 0) {
        lastError = 'empty body';
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'empty body file=%{public}s url=%{public}s',
          destPath, url);
        removeQuietly(tempPath);
        continue;
      }
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
      // 终态：文件已落到正式名（sha1 / 空产物等校验全部通过后）才补发满格读数 ——
      // `streamToFile` 的 100ms 节流会把最后一片丢掉，不补发就会停在 < total。
      // 用已取到的实际大小当分子分母，不依赖服务端是否给长度。
      if (onProgress !== undefined) {
        try {
          onProgress(st.size, st.size);
        } catch {
          // UI 回调异常不得影响下载
        }
      }
      return;
    } catch (error) {
      if (outcome.localFailure) {
        // 本机状态（磁盘满 / fd 耗尽 / 权限）：换镜像没有任何意义，直接失败
        removeQuietly(tempPath);
        throw error as Error;
      }
      const err = error as BusinessError;
      lastError = err.message ?? `code ${err.code}`;
      removeQuietly(tempPath);
    }
  }
  throw new Error(lastError);
}
