import { AppStorageV2 } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteVersion, fetchManifest, installVersion, removeIncompleteInstance } from '../data/VersionInstaller';
import { SOURCE_MIRROR, TYPE_OTHER, TYPE_RELEASE,
  TYPE_SNAPSHOT } from '../constants/DownloadContract';

/**
 * 安装器应用级共享状态（跨组件通过 AppStorageV2 共享同一实例）。
 *
 * 职责：承载"下载新版本"面板的状态与动作（版本清单、单任务安装进度、错误）。
 * 与 LauncherState 分开：LauncherState 管"已装版本的启动"，本类管"远程版本的安装"。
 *
 * 约束（用户决策）：同一时刻只允许安装一个版本 —— installingId 非空即视为占用。
 */

/** 错误种类（UI 据此选择资源文案，避免把 UI 文案塞进逻辑层）。 */
export const INSTALL_ERR_NONE: number = 0;
export const INSTALL_ERR_MANIFEST: number = 1;
export const INSTALL_ERR_INSTALL: number = 2;
export const INSTALL_ERR_NO_WRITE: number = 3;

@ObservedV2
export class InstallerState {
  /** 远程版本清单（全部可下载版本）。 */
  @Trace manifest: RemoteVersion[] = [];

  /** 清单是否已成功加载过（避免每次展开都重拉）。 */
  @Trace manifestLoaded: boolean = false;

  /** 清单加载中。 */
  @Trace manifestLoading: boolean = false;

  /** 正在安装的版本 id（空串 = 空闲；非空即占用，禁止并行安装）。 */
  @Trace installingId: string = '';

  /** 安装阶段码（见 VersionInstaller.PHASE_*）。 */
  @Trace phase: number = 0;

  /** 当前批次已完成数 / 总数。 */
  @Trace done: number = 0;
  @Trace total: number = 0;

  /** 当前处理项标签（文件名 / 资源名）。 */
  @Trace current: string = '';

  /** 错误种类与详情（详情为动态数据，可直接展示）。 */
  @Trace errorKind: number = INSTALL_ERR_NONE;
  @Trace errorDetail: string = '';

  /** 当前下载源（'mirror' / 'official'），由下载面板设置。 */
  @Trace source: string = SOURCE_MIRROR;

  /** 版本类型过滤（release / snapshot / other），由下载面板设置。 */
  @Trace versionType: string = TYPE_RELEASE;

  /** 过滤后的可见版本列表（Repeat 渲染用；manifest 为原始全量）。 */
  @Trace visible: RemoteVersion[] = [];

  /** 当前文件已接收 / 总字节数（进度显示；total<=0 表示服务端未给长度）。 */
  @Trace fileReceived: number = 0;
  @Trace fileTotal: number = 0;

  /** 拉取远程版本清单（首次展开面板或手动重试时调用）。 */
  async refreshManifest(): Promise<void> {
    if (this.manifestLoading) {
      return;
    }
    this.manifestLoading = true;
    this.errorKind = INSTALL_ERR_NONE;
    this.errorDetail = '';
    try {
      this.manifest = await fetchManifest(this.source);
      this.manifestLoaded = true;
      this.applyFilter();
    } catch (error) {
      const err = error as BusinessError;
      this.errorKind = INSTALL_ERR_MANIFEST;
      this.errorDetail = err.message ?? '';
    }
    this.manifestLoading = false;
  }

  /** 安装一个版本到 `versions/<instanceName>/`（单任务）；返回是否成功。 */
  async install(gameRoot: string, remote: RemoteVersion, instanceName: string): Promise<boolean> {
    if (this.installingId.length > 0) {
      return false;
    }
    this.installingId = remote.id;
    this.errorKind = INSTALL_ERR_NONE;
    this.errorDetail = '';
    this.phase = 0;
    this.done = 0;
    this.total = 0;
    this.current = '';
    this.fileReceived = 0;
    this.fileTotal = 0;
    let ok = true;
    try {
      await installVersion(gameRoot, remote, this.source, instanceName,
        (phase: number) => {
          this.phase = phase;
        },
        (done: number, total: number) => {
          this.done = done;
          this.total = total;
        },
        (label: string) => {
          this.current = label;
        },
        (received: number, total: number) => {
          this.fileReceived = received;
          this.fileTotal = total;
        });
    } catch (error) {
      // 失败收尾：清掉半装残留（缺 <名>.json 才清，绝不碰完整实例），避免"扫描不到又占名"的僵尸目录。
      removeIncompleteInstance(gameRoot, instanceName);
      const err = error as BusinessError;
      this.errorKind = INSTALL_ERR_INSTALL;
      this.errorDetail = err.message ?? '';
      ok = false;
    }
    this.installingId = '';
    return ok;
  }

  /** 设置下载源（面板用）；清空已加载的清单，等待用户点「获取版本列表」。 */
  setSource(source: string): void {
    if (source === this.source) {
      return;
    }
    this.source = source;
    this.manifestLoaded = false;
    this.manifest = [];
    this.visible = [];
    this.errorKind = INSTALL_ERR_NONE;
    this.errorDetail = '';
  }

  /** 设置版本类型过滤（面板用）；对已加载清单即时过滤，不重新拉取。 */
  setVersionType(type: string): void {
    if (type === this.versionType) {
      return;
    }
    this.versionType = type;
    this.applyFilter();
  }

  /** 按 versionType 过滤 manifest → visible。 */
  private applyFilter(): void {
    const t = this.versionType;
    if (t === TYPE_OTHER) {
      this.visible = this.manifest.filter((v: RemoteVersion) =>
        v.type !== TYPE_RELEASE && v.type !== TYPE_SNAPSHOT);
    } else {
      this.visible = this.manifest.filter((v: RemoteVersion) => v.type === t);
    }
  }
}

/** 通过 AppStorageV2 获取（或创建）共享的 InstallerState 实例。 */
export function getInstallerState(): InstallerState {
  return AppStorageV2.connect<InstallerState>(InstallerState, () => new InstallerState())!;
}
