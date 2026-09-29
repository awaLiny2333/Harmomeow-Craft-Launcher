import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MC_CP_DIR, MC_RUN_DIR_PREFIX, NEO_INSTALLER_DIR, FORGE_INSTALLER_DIR } from '../constants/Paths';
import { removeTreeBestEffort } from './VersionTools';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'CacheCleaner';

/**
 * 清除启动器**自己的**沙箱缓存（纯数据层，不依赖 UI）。
 *
 * 只动 `ctx.cacheDir` 下**本项目写出来的**条目（见 `Paths` 常量）——cacheDir 里可能还有系统
 * 自己的东西（rawheap 等），故**逐个点名**删除、绝不清空整个 cacheDir：
 *   - `mc-cp/`（`MC_CP_DIR`）：各版本 classpath 平铺暂存（含 meowcraft_extras 解压与 done 标记）；
 *   - `mc-run-<id>` 与 `mc-run-<id>-logs`（`MC_RUN_DIR_PREFIX`）：运行目录（java.io.tmpdir / natives 解压）
 *     与兜底运行日志目录；
 *   - `neo-installer/`（`NEO_INSTALLER_DIR`）、`forge-installer/`（`FORGE_INSTALLER_DIR`）：安装器解包工作目录。
 *
 * **绝不触碰**游戏根（libraries / assets / versions / config / 存档 / 日志）与 `<filesDir>` 下的
 * JRE 解压（`meow-jres/`）、启动器 home（`meow-home/`）、设置（`meow-settings/`）。
 *
 * 安全：全部 best-effort —— 被占用的文件跳过并如实上报，绝不抛异常。释放字节按**删除前后实测差**计
 * （故部分失败时给出的就是真实释放量）。
 */

/** 清除结果：释放字节数 + 成功 / 跳过（被占用等）的顶层条目名（相对 cacheDir）。 */
export interface CacheClearOutcome {
  /** 实测释放的字节数（删除前占用 − 删除后残留）。 */
  freedBytes: number;
  /** 成功清掉的顶层条目名（相对 cacheDir）。 */
  clearedItems: string[];
  /** 未能清掉的顶层条目名（相对 cacheDir；多为被占用）。 */
  skippedItems: string[];
}

/** 路径存在性（读不到一律按不存在）。 */
function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch {
    return false;
  }
}

/** 递归求目录 / 文件占用的字节数（只读；不存在或读失败按 0 计，绝不抛）。 */
function sizeOf(path: string): number {
  let isDir = false;
  let fileSize = 0;
  try {
    const st = fileIo.statSync(path);
    isDir = st.isDirectory();
    fileSize = st.size;
  } catch {
    return 0;
  }
  if (!isDir) {
    return fileSize;
  }
  let total = 0;
  let entries: string[] = [];
  try {
    // 递归列表返回以 '/' 开头的相对路径（见 VersionTools.removeTreeBestEffort）。
    entries = fileIo.listFileSync(path, { recursion: true });
  } catch {
    return 0;
  }
  for (const rel of entries) {
    try {
      const st = fileIo.statSync(`${path}${rel}`);
      if (!st.isDirectory()) {
        total += st.size;
      }
    } catch {
      // 单条读不到 → 跳过（不阻断其余）
    }
  }
  return total;
}

/** 收集 cacheDir 下属于本项目的顶层缓存条目（绝对路径）。 */
function topLevelTargets(cacheDir: string): string[] {
  const targets: string[] = [
    `${cacheDir}/${MC_CP_DIR}`,
    `${cacheDir}/${NEO_INSTALLER_DIR}`,
    `${cacheDir}/${FORGE_INSTALLER_DIR}`,
  ];
  // 运行目录与运行日志目录共用 `mc-run-` 前缀（`mc-run-<id>` 与 `mc-run-<id>-logs`）→ 按前缀一并收集。
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(cacheDir);
  } catch {
    names = [];
  }
  for (const n of names) {
    if (n.startsWith(MC_RUN_DIR_PREFIX)) {
      targets.push(`${cacheDir}/${n}`);
    }
  }
  return targets;
}

/**
 * 清除沙箱缓存并返回结果。**调用方**负责先拒绝**游戏运行中**与**安装进行中**两种状态
 * （本函数不判任何运行状态）：后者因为 `neo-installer/` / `forge-installer/` 里是安装器**正在用**的
 * 活文件（installer.jar / 解包数据 / job / `{MINECRAFT_JAR}` 副本）。
 * 一条稳定的英文日志（释放字节 + 条目清单），供实机排障。
 */
export function clearSandboxCaches(cacheDir: string): CacheClearOutcome {
  const targets = topLevelTargets(cacheDir);
  const present: string[] = [];
  let before = 0;
  for (const t of targets) {
    if (exists(t)) {
      present.push(t);
      before += sizeOf(t);
    }
  }
  const clearedItems: string[] = [];
  const skippedItems: string[] = [];
  for (const t of present) {
    removeTreeBestEffort(t);
    const name = t.substring(cacheDir.length + 1);
    if (exists(t)) {
      skippedItems.push(name);
    } else {
      clearedItems.push(name);
    }
  }
  let after = 0;
  for (const t of targets) {
    after += sizeOf(t);
  }
  const freedBytes = before - after > 0 ? before - after : 0;
  hilog.info(LOG_DOMAIN, LOG_TAG,
    'clear cache: freed=%{public}d items=%{public}s skipped=%{public}s',
    freedBytes, clearedItems.join(','), skippedItems.join(','));
  return { freedBytes: freedBytes, clearedItems: clearedItems, skippedItems: skippedItems };
}
