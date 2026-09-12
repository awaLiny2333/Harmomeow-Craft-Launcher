import { fileIo } from '@kit.CoreFileKit';
import { JRES_ROOT, JRE_ID_MEOW, JRE_DATA_TOKEN, JRE_DATA_TOKEN_FILE } from '../constants/Paths';

/** JRE 数据根目录名（= Paths.JRES_ROOT；保留别名以兼容既有引用）。 */
export const JRES_DIR: string = JRES_ROOT;

/**
 * Java 运行时（JRE）环境条目。
 *
 * java.home 约定 = <filesDir>/meow-jres/<id>，id 即安装目录名（**版本无关**，如 "meow_jre"）。
 * 内置来源：entry rawfile 的 meow_jre.tar.gz（魔改派生：纯数据）解压到 filesDir/meow-jres/meow_jre。
 * JRE 版本由 release 的 JAVA_VERSION 展示；数据令牌不符 → needsUpgrade。
 */
export class JavaEnvInfo {
  /** 唯一标识；同时是 meow-jres 下安装目录名（java.home 子目录），如 "meow_jre"。 */
  id: string;

  /** 是否已解压就绪（filesDir/meow-jres/<id>/lib/modules 存在 且 数据令牌一致；
   *  .so 只在 el1 不入 filesDir，故不能拿 libjli.so 判定）。 */
  installed: boolean;

  /** 盘上已有数据但令牌不符（旧/缺失）→ **须升级**（区别于完全未解压）。 */
  needsUpgrade: boolean;

  /** 盘上数据的令牌（未解压/无令牌时为空）——用于向用户展示 旧→新。 */
  extractedToken: string;

  /** 解析出的 Java 版本，如 "26.0.2.1"；未安装时为空。 */
  version: string;

  constructor(id: string, installed: boolean, needsUpgrade: boolean, extractedToken: string, version: string) {
    this.id = id;
    this.installed = installed;
    this.needsUpgrade = needsUpgrade;
    this.extractedToken = extractedToken;
    this.version = version;
  }
}

/** 随包内置的 JRE id 清单（顺序即 UI 展示顺序）；对应 rawfile 中 <id>.tar.gz。 */
const BUNDLED_JRE_IDS: string[] = [JRE_ID_MEOW];

/**
 * 扫描 Java 环境状态：探测每个内置 JRE 是否已解压 + 解析版本。
 * 纯只读（accessSync/readTextSync），不触发解压或启动 JVM。
 */
export function scanJavaEnv(filesDir: string): JavaEnvInfo[] {
  const result: JavaEnvInfo[] = [];
  for (const id of BUNDLED_JRE_IDS) {
    const home = `${filesDir}/${JRES_DIR}/${id}`;
    let installed = false;
    let needsUpgrade = false;
    let extractedToken = '';
    let version = '';
    try {
      // 就绪 = lib/modules 存在（.so 只在 el1，不入数据）且 数据令牌一致。
      // 有数据但令牌不符 → 须升级（令 UI 显示「升级」并展示 旧→新 令牌，而非「未解压」）。
      if (fileIo.accessSync(`${home}/lib/modules`)) {
        extractedToken = readTextTrim(`${home}/${JRE_DATA_TOKEN_FILE}`);
        if (extractedToken === JRE_DATA_TOKEN) {
          installed = true;
          version = readReleaseVersion(`${home}/release`);
        } else {
          needsUpgrade = true;
        }
      }
    } catch {
      // 目录缺失或不可读按未安装处理
    }
    result.push(new JavaEnvInfo(id, installed, needsUpgrade, extractedToken, version));
  }
  return result;
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
