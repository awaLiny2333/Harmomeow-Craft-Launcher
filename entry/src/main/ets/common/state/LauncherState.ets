import { AppStorageV2 } from '@kit.ArkUI';
import { GameDir } from '../data/GameDirsTools';
import { GameVersion, scanVersions } from '../data/VersionScanner';
import { scanJavaEnv } from '../data/JavaEnvScanner';
import { isGameProcessRunning } from '../data/GameProcessScanner';

/**
 * 启动器应用级共享状态（跨组件通过 AppStorageV2 共享同一实例）。
 *
 * 为什么需要它：目录选择区（GameDirsView）与版本列表区（GameVersionsView）是两块
 * 独立 UI 组件，但共享同一份数据——当前选中的目录、哪些目录已授权、识别出的版本。
 * 若各组件各自持有 @Local 副本，切换目录 / 授权后另一块组件无法感知。
 *
 * 为什么叫 LauncherState 而非 LaunchState：这里承载的是整个启动器（Launcher）
 * 的运行状态（目录/授权/版本），不是"一次启动(launch)动作"的状态。
 *
 * 机制（状态管理 V2 + AppStorageV2）：
 * - LauncherState 是 @ObservedV2 class，跨组件关心的字段用 @Trace 装饰；
 * - 各组件通过 AppStorageV2.connect(LauncherState, ...) 拿到同一个实例（@Local 持有）；
 * - 任一处修改 @Trace 字段，所有 connect 到该 key 的组件 UI 都会同步刷新。
 *
 * 注意：本 class 是纯运行时状态，不做序列化持久化。
 * 持久化在别处：目录列表 / 上次选中项见 GameDirsTools；高级选项与版本隔离见 SettingsTools。
 * isolatedIds 只是 SettingsTools 的运行时镜像，供版本区展示与切换。
 */
@ObservedV2
export class LauncherState {
  /** 已记住的游戏目录列表（来自 GameDirsTools.list()）。 */
  @Trace dirs: GameDir[] = [];

  /** 当前选中的目录 URI（上次记忆恢复或用户下拉选择）。 */
  @Trace selected: string = '';

  /** 本次会话内已通过授权 Picker 的目录 URI 集合（不持久化，重启清空）。 */
  @Trace activated: string[] = [];

  /** 当前选中目录下识别出的游戏版本。 */
  @Trace versions: GameVersion[] = [];

  /** 版本扫描代数：每次 refreshVersions 自增。Repeat 按 id 复用行时不重跑 item
   *  builder，同 id 内容变化（如换目录后 jsonPath 改变）会显示旧值——把本值拼进
   *  行 key 强制重建（见 GameVersionsView）。 */
  @Trace versionEpoch: number = 0;

  /** 内置 JRE 是否已解压就绪（版本区据此禁用"启动"，避免无 JRE 空启动）。 */
  @Trace jreReady: boolean = false;

  /** JRE 数据须升级（有数据但令牌不符）——版本区据此显示"须升级"型提示而非"未解压"。 */
  @Trace jreNeedsUpgrade: boolean = false;

  /** 游戏 Ability 独立进程是否在运行（版本区据此禁用"启动"，避免重复开游戏）。 */
  @Trace gameRunning: boolean = false;

  /** 已启用版本隔离的版本 id 列表（镜像 Preferences，见 SettingsTools.versionIsolationIds）。 */
  @Trace isolatedIds: string[] = [];

  /** 当前选中目录是否已授权（selected 在 activated 中）。 */
  isSelectedActivated(): boolean {
    return this.activated.includes(this.selected);
  }

  /** 某版本是否已启用版本隔离（UI 开关状态与游戏启动同源）。 */
  isIsolated(versionId: string): boolean {
    return this.isolatedIds.includes(versionId);
  }

  /**
   * 扫描当前选中目录下的游戏版本。
   * - 无选中目录：清空版本列表；
   * - 选中但未授权：清空版本列表（UI 层据此显示"授权"提示）；
   * - 已授权：调用 scanVersions 填充版本列表。
   * 该方法是共享状态的调度入口：目录区在选中 / 授权 / 移除变化后调用，
   * 版本区在挂载 / 点刷新时也调用；两边看到同一份 versions。
   */
  refreshVersions(): void {
    if (this.selected.length === 0 || !this.isSelectedActivated()) {
      this.versions = [];
    } else {
      this.versions = scanVersions(this.selected);
    }
    this.versionEpoch++; // 使版本区行 key 失效重建，同 id 的新内容才会刷新
  }

  /**
   * 探测内置 JRE 是否已解压就绪（filesDir/meow-jres/<id>/lib/modules 存在；.so 只在 el1）。
   * 版本区挂载 / Java 环境区安装完成后都会调用，使"启动"按钮可用性全局同步。
   */
  refreshJre(filesDir: string): void {
    let ready = false;
    let needsUpgrade = false;
    const envs = scanJavaEnv(filesDir);
    for (const env of envs) {
      if (env.installed) {
        ready = true;
        break;
      }
      if (env.needsUpgrade) {
        needsUpgrade = true;
      }
    }
    this.jreReady = ready;
    this.jreNeedsUpgrade = !ready && needsUpgrade;
  }

  /** 探测游戏 Ability 进程是否存活（跨进程，免权限）。主窗定时/触发调用。 */
  async refreshGameRunning(): Promise<void> {
    this.gameRunning = await isGameProcessRunning();
  }
}

/** 通过 AppStorageV2 获取（或创建）共享的 LauncherState 实例。 */
export function getLauncherState(): LauncherState {
  return AppStorageV2.connect<LauncherState>(LauncherState, () => new LauncherState())!;
}
