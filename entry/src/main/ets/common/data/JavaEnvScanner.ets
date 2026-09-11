import { fileIo } from '@kit.CoreFileKit';
import { JRES_ROOT, JRE_ID_MEOW25 } from '../constants/Paths';

/** JRE 数据根目录名（= Paths.JRES_ROOT；保留别名以兼容既有引用）。 */
export const JRES_DIR: string = JRES_ROOT;

/**
 * Java 运行时（JRE）环境条目。
 *
 * java.home 约定 = <filesDir>/meow-jres/<id>，id 即安装目录名。
 * 内置来源：entry rawfile 的 meow_jre25.tar.gz（魔改派生：C2 瘦身纯数据）
 * 解压到 filesDir/meow-jres/meow_jre25。
 */
export class JavaEnvInfo {
  /** 唯一标识；同时是 meow-jres 下安装目录名（java.home 子目录），如 "meow_jre25"。 */
  id: string;

  /** 是否已解压就绪（filesDir/meow-jres/<id>/lib/modules 存在，与 installJre 完成标记一致；
   *  .so 只在 el1 不入 filesDir，故不能拿 libjli.so 判定）。 */
  installed: boolean;

  /** 解析出的 Java 版本，如 "25.0.1"；未安装时为空。 */
  version: string;

  constructor(id: string, installed: boolean, version: string) {
    this.id = id;
    this.installed = installed;
    this.version = version;
  }
}

/** 随包内置的 JRE id 清单（顺序即 UI 展示顺序）；对应 rawfile 中 <id>.tar.gz。 */
const BUNDLED_JRE_IDS: string[] = [JRE_ID_MEOW25];

/**
 * 扫描 Java 环境状态：探测每个内置 JRE 是否已解压 + 解析版本。
 * 纯只读（accessSync/readTextSync），不触发解压或启动 JVM。
 */
export function scanJavaEnv(filesDir: string): JavaEnvInfo[] {
  const result: JavaEnvInfo[] = [];
  for (const id of BUNDLED_JRE_IDS) {
    const home = `${filesDir}/${JRES_DIR}/${id}`;
    let installed = false;
    let version = '';
    try {
      if (fileIo.accessSync(`${home}/lib/modules`)) {
        installed = true;
        version = readReleaseVersion(`${home}/release`);
      }
    } catch {
      // 目录缺失或不可读按未安装处理
    }
    result.push(new JavaEnvInfo(id, installed, version));
  }
  return result;
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
