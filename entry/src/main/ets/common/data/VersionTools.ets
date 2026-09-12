import { fileIo } from '@kit.CoreFileKit';
import { versionDir } from '../constants/Paths';
import { MEOW_TRASH_DIR } from '../constants/Constants';

/**
 * 版本实例的删除操作（纯数据层，不依赖 UI）。
 *
 * 删除语义（与主流启动器一致，见 notes/10-research/启动器目录模型与版本隔离.md）：
 * 删除 <gameRoot>/versions/<id>/ 整个实例目录。`assets/` 与 `libraries/` 是共享池，
 * **不**随版本删除。启用「版本隔离」后该目录同时承载存档/选项/日志 → 会一并删除；
 * 调用方必须先向用户二次确认（见 GameVersionsView）。
 *
 * 原子性（对齐 HMCL：先把实例根 move 走再删，失败则原样保留）：
 * `fs.renameSync` 先把 `versions/<id>` 移到 `<gameRoot>/<MEOW_TRASH_DIR>/`（**versions/ 之外**，
 * 同文件系统可原子 rename）；改名失败（占用/权限/不存在）即返回 false，实例**保持不变**。
 * 改名成功后才 best-effort 递归清删。残留放在 versions/ 之外 → 用户可任意命名实例
 * （含 `*removed`），不会与残留冲突，扫描器也无需按后缀名排除（对齐 HMCL）。
 */

/**
 * 删除已安装版本 <gameRoot>/versions/<versionId>/。
 * 返回 true = 实例根已移走（删除成功）；false = 改名失败，实例原样保留。
 */
export function deleteVersionDir(gameRoot: string, versionId: string): boolean {
  // 路径安全：id 必须是单一目录名（拒绝空、精确 `.`/`..`、分隔符，防越界改名）。
  // 与 `isValidInstanceName` 对齐：允许 `a..b`/前导点等名字（HMCL 亦允许），不做过宽的 `..` 子串拦截。
  if (versionId.length === 0 || versionId === '.' || versionId === '..'
    || versionId.includes('/') || versionId.includes('\\')) {
    return false;
  }
  const dir = versionDir(gameRoot, versionId);
  const trashRoot = `${gameRoot}/${MEOW_TRASH_DIR}`;
  // 时间戳后缀：与用户实例名不可能同名（实例名不允许以点结尾，且此处为独立命名空间）。
  const trash = `${trashRoot}/${versionId}-${Date.now()}`;
  try {
    fileIo.mkdirSync(trashRoot, true);
  } catch {
    // 已存在则忽略
  }
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
export function removeTreeBestEffort(dirPath: string): void {
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
    // 目录非空/被占用 → 残留留在 <MEOW_TRASH_DIR>（在 versions/ 之外，不会被扫描），不影响删除成功语义。
  }
}
