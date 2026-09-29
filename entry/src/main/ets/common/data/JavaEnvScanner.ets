import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JRES_ROOT } from '../constants/Paths';
import { JavaRuntime, BUNDLED_RUNTIMES } from './JavaRuntime';

// native 导出（installJre：rawfile <jreId>.tar.gz -> filesDir/meow-jres/<jreId>）
import native from 'libmeowassets.so';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'JavaEnvScanner';

/** JRE 数据根目录名（= Paths.JRES_ROOT；保留别名以兼容既有引用）。 */
export const JRES_DIR: string = JRES_ROOT;

/**
 * Java 运行时（JRE）环境条目。
 *
 * java.home 约定 = <filesDir>/meow-jres/<id>，id 即安装目录名（**版本无关**，如 "meow_jre"）。
 * 来源：entry rawfile 的 `<id>.tar.gz`（纯数据）解压到 filesDir/meow-jres/<id>。
 * JRE 版本由 release 的 JAVA_VERSION 展示；数据令牌不符 → needsUpgrade。
 *
 * ⚠️ **就绪判据逐 id 不同**（数据布局事实）：现代套 `lib/modules`、legacy 套 `lib/rt.jar`
 * （JDK 8 根本没有 lib/modules）。判据来自 [`JavaRuntime`](JavaRuntime.ets) 的表，
 * 本文件**不再**硬编码任何标记。
 */
export class JavaEnvInfo {
  /** 唯一标识；同时是 meow-jres 下安装目录名（java.home 子目录），如 "meow_jre"。 */
  id: string;

  /** 是否已解压就绪（该 id 的「就绪标记」存在 且 数据令牌一致；
   *  .so 只在 el1 不入 filesDir，故不能拿 libjli.so 判定）。 */
  installed: boolean;

  /** 盘上已有数据但令牌不符（旧/缺失）→ **须升级**（区别于完全未解压）。 */
  needsUpgrade: boolean;

  /** 盘上数据的令牌（未解压/无令牌时为空）——用于向用户展示 旧→新。 */
  extractedToken: string;

  /** **本 id 应达到**的数据令牌（表里的值）——UI 展示"旧→新"时用它，而不是全局常量。 */
  requiredToken: string;

  /** 解析出的 Java 版本，如 "26.0.2.1" / "1.8.0_504"；未安装时为空。 */
  version: string;

  constructor(id: string, installed: boolean, needsUpgrade: boolean, extractedToken: string,
    requiredToken: string, version: string) {
    this.id = id;
    this.installed = installed;
    this.needsUpgrade = needsUpgrade;
    this.extractedToken = extractedToken;
    this.requiredToken = requiredToken;
    this.version = version;
  }
}

/**
 * 扫描 Java 环境状态：探测每个**随包** JRE 是否已解压 + 解析版本。
 * 纯只读（accessSync/readTextSync），不触发解压或启动 JVM。
 * 清单来源 = [`BUNDLED_RUNTIMES`](JavaRuntime.ets)（顺序即 UI 展示顺序）。
 */
export function scanJavaEnv(filesDir: string): JavaEnvInfo[] {
  const result: JavaEnvInfo[] = [];
  for (const rt of BUNDLED_RUNTIMES) {
    result.push(runtimeStatus(filesDir, rt));
  }
  return result;
}

/**
 * 单个 runtime 的就绪状态 —— **就绪判据的唯一实现**（`scanJavaEnv` 与启动前检查
 * `GameLauncher.checkLaunchJre` 都调它，避免两处判据漂移）。就绪标记与令牌都取自
 * 该套自己的描述（渐进式：现代套 `lib/modules`、legacy 套 `lib/rt.jar`）。
 */
export function runtimeStatus(filesDir: string, rt: JavaRuntime): JavaEnvInfo {
  let installed = false;
  let needsUpgrade = false;
  let extractedToken = '';
  let version = '';
  try {
    // 就绪 = 该 id 的「就绪标记」存在（.so 只在 el1，不入数据）且 数据令牌一致。
    // 有数据但令牌不符 → 须升级（令 UI 显示「升级」并展示 旧→新 令牌，而非「未解压」）。
    if (fileIo.accessSync(rt.readyPath(filesDir))) {
      extractedToken = readTextTrim(rt.tokenPath(filesDir));
      if (extractedToken === rt.dataToken) {
        installed = true;
        version = readReleaseVersion(`${rt.home(filesDir)}/release`);
      } else {
        needsUpgrade = true;
      }
    }
  } catch {
    // 目录缺失或不可读按未安装处理
  }
  return new JavaEnvInfo(rt.id, installed, needsUpgrade, extractedToken, rt.dataToken, version);
}

/**
 * 解压 / 升级一套随包 JRE（rawfile `<id>.tar.gz` → `filesDir/meow-jres/<id>`）。
 *
 * **唯一的 JRE 准备入口**：「Java 环境」区的按钮与启动时未就绪对话框都走这里
 * （native 同步解压，约 1~2s），不在别处另写安装逻辑。调用方负责在成功后重扫状态。
 */
export function installRuntime(ctx: common.Context, id: string): boolean {
  let ok = false;
  try {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'install %{public}s -> filesDir', id);
    ok = native.installJre(ctx.resourceManager, ctx.filesDir, id) as boolean;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'installJre(%{public}s) -> %{public}s', id, String(ok));
  } catch (e) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'install %{public}s failed: %{public}s', id, JSON.stringify(e));
  }
  return ok;
}

/** 读取小文本文件并去除首尾空白；失败/不存在返回空串。 */
function readTextTrim(path: string): string {
  try {
    return fileIo.readTextSync(path).trim();
  } catch {
    return '';
  }
}

/** 从 JRE release 文件提取 JAVA_VERSION="x.y.z"（properties 风格，按行匹配）。 */
function readReleaseVersion(releasePath: string): string {
  try {
    const text = fileIo.readTextSync(releasePath);
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('JAVA_VERSION=')) {
        return trimmed.substring('JAVA_VERSION="'.length, trimmed.length - 1);
      }
    }
  } catch {
    // 读取失败返回空版本
  }
  return '';
}
