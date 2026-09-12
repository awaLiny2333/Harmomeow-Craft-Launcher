import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { MC_CP_DIR, RAWFILE_MEOWCRAFT_EXTRAS, MEOWCRAFT_EXTRAS_DONE, RAWFILE_OSHI_DIR,
  RAWFILE_OSHI_MANIFEST } from '../constants/Paths';
import { EXTRAS_VERSION, EXPECTED_EXTRA_JARS, LWJGL_JAR_PREFIX,
  LWJGL_GEN_JARS } from '../constants/LaunchDefaults';
import { collectJarSources, lwjglGeneration, isLegacyLwjgl } from './MinecraftLauncher';

// native 导出（extractRawTar：解 meowcraft_extras.tar.gz）
import native from 'libmeowassets.so';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'ClasspathStager';

/**
 * 把某版本的运行 jar 平铺到 `cacheDir/mc-cp/<id>/`，供 `-cp "<dir>/*"` 使用
 * （超长 -cp 在本 JLI 移植会失效）。含 meowcraft_extras 解压与残留 jar 清理。
 * 纯文件操作，不依赖 UI；失败时返回空串由调用方中止启动。
 */
export function stageClasspathDir(ctx: common.UIAbilityContext, gameRoot: string,
  jsonPath: string, versionId: string): string {
  const cacheDir = ctx.cacheDir;
  const base = `${cacheDir}/${MC_CP_DIR}`;
  const dir = `${base}/${versionId}`;
  // 随包分发两代 LWJGL jar；按版本 json 声明的 lwjgl 版本选中一代，平铺目录里只保留
  // 该代（-cp "<dir>/*" 不能同时装两份 org.lwjgl.*）。natives 两代同名共存于 el1
  // 随包目录，靠启动参数的 bundledLibrary.nameMapper 按世代选名（见 LaunchDefaults）。
  const gen = lwjglGeneration(jsonPath);
  const genJar = `${LWJGL_JAR_PREFIX}${gen}.jar`;
  // legacy LWJGL2（≤1.12.2）：classpath 不能混入我们的 LWJGL3（两 jar 都定义 org.lwjgl 包 →
  // sealing violation）。此时 keepGenJar 置空 → 把两代随包 jar 都从平铺目录移除，只留 MC 的 LWJGL2。
  const legacyLwjgl = isLegacyLwjgl(jsonPath);
  const keepGenJar = legacyLwjgl ? '' : genJar;
  for (const d of [base, dir]) {
    try {
      fileIo.mkdirSync(d);
    } catch (e) {
      // 已存在则忽略
    }
  }
  // 桥 jar（lwjgl 合并/launcher 等）随包分发。done 文件内容 = EXTRAS_VERSION：
  // tar 内容一旦变更（换 jar/打补丁）就提升版本号，重抽覆盖缓存旧 jar——
  // install -r 保留 cacheDir，光靠文件存在会继续用旧 lwjgl.jar（如 so 改名后仍
  // loadLibrary 旧名 → UnsatisfiedLinkError）。
  const doneMark = `${dir}/${MEOWCRAFT_EXTRAS_DONE}`;
  try {
    let upToDate = false;
    try {
      upToDate = fileIo.readTextSync(doneMark) === EXTRAS_VERSION;
    } catch (e) {
      upToDate = false; // 无标记或读取失败 → 重抽
    }
    if (!upToDate) {
      if (native.extractRawTar(ctx.resourceManager, RAWFILE_MEOWCRAFT_EXTRAS, dir) as boolean) {
        const f = fileIo.openSync(doneMark, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
          fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, EXTRAS_VERSION);
        fileIo.closeSync(f);
      }
    }
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'extract meowcraft_extras fail: %{public}s', JSON.stringify(e));
  }
  const sources = collectJarSources(gameRoot, jsonPath, versionId);
  let copied = 0;
  let checked = 0;
  for (const src of sources) {
    const name = src.substring(src.lastIndexOf('/') + 1);
    const dest = `${dir}/${name}`;
    try {
      checked++;
      const srcSize = fileIo.statSync(src).size;
      let needCopy = true;
      try {
        const dstSize = fileIo.statSync(dest).size;
        needCopy = dstSize !== srcSize;
      } catch {
        needCopy = true;
      }
      if (needCopy) {
        fileIo.copyFileSync(src, dest);
        copied++;
      }
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sync fail %{public}s: %{public}s', src, JSON.stringify(e));
    }
  }
  // 自编 patched oshi 覆盖 staged 的同名 jar（版本无关；不改用户 .minecraft）：鸿蒙沙箱禁
  // /proc/cpuinfo，上游 oshi 读不到 CPU 型号；覆盖件认 -Dmeow.cpu.chip（:game 进程 deviceInfo.chipType）。
  // 只覆盖本版本实际 staged 的 oshi 件（清单里其余版本跳过）。
  applyOshiOverrides(ctx, dir);
  dropOtherLwjglJar(dir, keepGenJar);
  pruneStaleJars(dir, sources, keepGenJar);
  // 启动期形态断言：classpath 里 `org.lwjgl` 的提供者必须形态正确（不混代、不多不少）。
  // 异常直接中止启动（把类冲突挡在更前面），而非带着坏 classpath 硬跑。
  if (!lwjglClasspathOk(dir, legacyLwjgl, keepGenJar)) {
    hilog.error(LOG_DOMAIN, LOG_TAG,
      'LWJGL classpath shape invalid (legacy=%{public}s keep=%{public}s): abort launch',
      legacyLwjgl ? 'yes' : 'no', keepGenJar.length > 0 ? keepGenJar : '(none)');
    return '';
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'stage %{public}s: gen=%{public}s checked=%{public}d copied=%{public}d',
    versionId, gen, checked, copied);
  return dir;
}

/**
 * 断言平铺 classpath 的 `org.lwjgl` 形态正确（启动期，一次）：
 * - legacy（LWJGL2，≤1.12.2）：**不得**出现我们的任一 LWJGL3 世代 jar；至少要有 MC 的 LWJGL2（`lwjgl-2.*`/`lwjgl_util-2.*`）。
 * - 现代（LWJGL3）：**恰好**保留选中世代那一个 jar；不得出现 LWJGL2。
 * 违反 → 返回 false（调用方中止启动），避免"两份 org.lwjgl 类"的密封/重复类错误。
 */
function lwjglClasspathOk(dir: string, legacy: boolean, keepGenJar: string): boolean {
  let ours = 0;
  let oursKeep = 0;
  let mc2 = 0;
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (e) {
    return false;
  }
  for (const name of entries) {
    if (!name.endsWith('.jar')) {
      continue;
    }
    if (LWJGL_GEN_JARS.includes(name)) {
      ours++;
      if (name === keepGenJar) {
        oursKeep++;
      }
    } else if (name.startsWith('lwjgl-2.') || name.startsWith('lwjgl_util-2.')) {
      mc2++;
    }
  }
  if (legacy) {
    return ours === 0 && mc2 >= 1;
  }
  return ours === 1 && oursKeep === 1 && mc2 === 0;
}

/** 删除未选中世代的**我们的** lwjgl jar（另一代随包但本版本不用；避免 -cp 双份类冲突）。
 *  只匹配我们随包的世代名（lwjgl-3.3.3.jar / lwjgl-3.4.3.jar）——**绝不能**用 `lwjgl-` 前缀，
 *  否则会误删 MC 自带的 LWJGL2（`lwjgl-2.9.x.jar`，legacy ≤1.12.2 需要）。 */
function dropOtherLwjglJar(dir: string, keepJar: string): void {
  const ours = new Set<string>(LWJGL_GEN_JARS);
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    if (ours.has(name) && name !== keepJar) {
      removeFile(`${dir}/${name}`);
    }
  }
}

function removeFile(path: string): void {
  try {
    fileIo.unlinkSync(path);
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'remove fail %{public}s', path);
  }
}

/**
 * 按 rawfile/oshi-overrides/manifest.txt 覆盖 staged 的 oshi jar。
 * 清单缺失 / 为空 = 无覆盖（未适配的 MC 版本优雅降级为上游行为）；
 * 清单里但**本版本 classpath 未 staged** 的条目直接**跳过**（只覆盖实际存在的那一版）。
 */
function applyOshiOverrides(ctx: common.UIAbilityContext, dir: string): void {
  let manifest = '';
  try {
    const raw = ctx.resourceManager.getRawFileContentSync(RAWFILE_OSHI_MANIFEST);
    manifest = util.TextDecoder.create('utf-8').decodeToString(raw);
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'no oshi override manifest');
    return;
  }
  for (const line of manifest.split('\n')) {
    const entry = line.trim();
    const eq = entry.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const target = entry.substring(0, eq);
    // Only override an oshi jar that THIS version's classpath actually staged.
    // The manifest lists every supported oshi version; overriding the others
    // would CREATE them (openSync CREATE) only to be pruned right after -> 8
    // pointless writes and 9 misleading log lines per launch.
    let present = false;
    try {
      fileIo.statSync(`${dir}/${target}`);
      present = true;
    } catch {
      present = false;
    }
    if (!present) {
      continue;
    }
    const source = `${RAWFILE_OSHI_DIR}/${entry.substring(eq + 1)}`;
    overrideStagedJar(ctx, dir, source, target);
  }
}

/** 用随包 patched jar 覆盖 staged 的同名 jar（内容变化时写一次）。 */
function overrideStagedJar(ctx: common.UIAbilityContext, dir: string,
  rawName: string, jarName: string): void {
  const dest = `${dir}/${jarName}`;
  try {
    const data = ctx.resourceManager.getRawFileContentSync(rawName);
    let needWrite = true;
    try {
      needWrite = fileIo.statSync(dest).size !== data.byteLength;
    } catch {
      needWrite = true;
    }
    if (!needWrite) {
      return;
    }
    const f = fileIo.openSync(dest, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
      fileIo.OpenMode.TRUNC);
    // 只写 Uint8Array 有效区间（.buffer 可能比内容大 → 否则 jar 损坏）。
    fileIo.writeSync(f.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    fileIo.closeSync(f);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'override %{public}s <- %{public}s (mem=%{public}d staged=%{public}d)',
      jarName, rawName, data.byteLength, fileIo.statSync(dest).size);
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'override fail %{public}s: %{public}s', rawName,
      JSON.stringify(e));
  }
}

/** 清理平铺目录中不属于当前期望集合的残留 jar（官方 LWJGL / 未选中世代等，防类冲突）。 */
function pruneStaleJars(dir: string, sources: string[], keepJar: string): void {
  const keep = new Set<string>();
  for (const src of sources) {
    keep.add(src.substring(src.lastIndexOf('/') + 1));
  }
  for (const n of EXPECTED_EXTRA_JARS) {
    keep.add(n);
  }
  if (keepJar.length > 0) {
    keep.add(keepJar);
  }
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    if (keep.has(name) || !name.endsWith('.jar')) {
      continue;
    }
    try {
      fileIo.unlinkSync(`${dir}/${name}`);
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'prune fail %{public}s: %{public}s', name, JSON.stringify(e));
    }
  }
}
