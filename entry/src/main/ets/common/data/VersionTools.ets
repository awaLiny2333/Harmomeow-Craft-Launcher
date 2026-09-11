import { fileIo } from '@kit.CoreFileKit';
import { versionDir } from '../constants/Paths';

/**
 * 版本实例的删除操作（纯数据层，不依赖 UI）。
 *
 * 删除语义（与主流启动器一致，见 notes/10-research/启动器目录模型与版本隔离.md）：
 * 删除 <gameRoot>/versions/<id>/ 整个实例目录。`assets/` 与 `libraries/` 是共享池，
 * **不**随版本删除。启用「版本隔离」后该目录同时承载存档/选项/日志 → 会一并删除；
 * 调用方必须先向用户二次确认（见 GameVersionsView）。
 *
 * 原子性（对齐 HMCL：先把实例根 move 走再删，失败则原样保留）：
 * `fs.renameSync` 先把 `versions/<id>` 改名为同层的 `versions/<id>_removed`；改名失败
 * （占用/权限/不存在）即返回 false，实例**保持不变**。改名成功后才 best-effort 递归清删，
 * 故绝不会留下"可见的半损实例"（`*_removed` 也被 VersionScanner 主动跳过）。
 */

/** 删除期的临时目录后缀（改名目标；VersionScanner 会跳过 `*removed` 目录）。 */
const REMOVED_SUFFIX: string = '_removed';

/**
 * 删除已安装版本 <gameRoot>/versions/<versionId>/。
 * 返回 true = 实例根已移走（删除成功）；false = 改名失败，实例原样保留。
 */
export function deleteVersionDir(gameRoot: string, versionId: string): boolean {
  // 路径安全：id 必须是单一目录名（防版本 json 里 id 含 '/'、'\'、'..' 造成越界改名）。
  if (versionId.length === 0 || versionId.includes('/') || versionId.includes('\\')
    || versionId.includes('..')) {
    return false;
  }
  const dir = versionDir(gameRoot, versionId);
  const trash = `${dir}${REMOVED_SUFFIX}`;
  // 先清掉上一次未收尾的临时目录（best-effort），避免改名目标已存在。
  removeTreeBestEffort(trash);
  try {
    fileIo.renameSync(dir, trash);
  } catch {
    return false;
  }
  removeTreeBestEffort(trash);
  return true;
}

/**
 * best-effort 递归删除目录，绝不抛异常：先深后浅逐个 rmdir/unlink，单条失败不阻断。
 * （fileIo.rmdirSync 只能删空目录，故必须自底向上；listFile 递归模式返回以 '/' 开头的相对路径。）
 */
function removeTreeBestEffort(dirPath: string): void {
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dirPath, { recursion: true });
  } catch {
    return;
  }
  entries.sort((a: string, b: string) => b.length - a.length);
  for (const rel of entries) {
    const full = `${dirPath}${rel}`;
    try {
      if (fileIo.statSync(full).isDirectory()) {
        fileIo.rmdirSync(full);
      } else {
        fileIo.unlinkSync(full);
      }
    } catch {
      // 单条失败（被占用等）不阻断其余。
      continue;
    }
  }
  try {
    fileIo.rmdirSync(dirPath);
  } catch {
    // 目录非空/被占用 → 残留 <id>_removed（扫描器跳过），不影响删除成功语义。
  }
}
