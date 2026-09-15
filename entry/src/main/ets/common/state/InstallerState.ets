import { common } from '@kit.AbilityKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteVersion, fetchManifest, installVersion, removeIncompleteInstance,
  fetchFabricLoaders, installFabricVersion, installNeoForgeVersion,
  FabricLoaderVersion } from '../data/VersionInstaller';
import { fetchNeoForgeVersions, NeoForgeListResult, NeoForgeRemoteVersion } from '../data/NeoForgeVersionList';
import { SOURCE_MIRROR, TYPE_OTHER, TYPE_RELEASE,
  TYPE_SNAPSHOT } from '../constants/DownloadContract';

/** 安装的 mod loader 种类（原版 / Fabric / NeoForge）。 */
export const LOADER_KIND_VANILLA: string = 'vanilla';
export const LOADER_KIND_FABRIC: string = 'fabric';
/** NeoForge：**仅 MC 1.20.2+**（见 notes 20-design/launch/NeoForge支持-改动方案.md）。 */
export const LOADER_KIND_NEO_FORGE: string = 'neoforge';
/** 安装错误码：loader 列表拉取失败 / 未选 loader 版本。 */
export const INSTALL_ERR_LOADER: number = 4;

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

  /** 安装的 mod loader 种类（原版 / Fabric）；由"设置实例名"面板设置。 */
  @Trace loaderKind: string = LOADER_KIND_VANILLA;

  /** Fabric 下载源（**与版本源 this.source 独立**；镜像/官方）。 */
  @Trace fabricSource: string = SOURCE_MIRROR;

  /** Fabric loader 版本列表与选中项（UI 展示/选择用）。 */
  @Trace fabricLoaders: FabricLoaderVersion[] = [];
  @Trace fabricLoader: string = '';
  @Trace fabricLoadersLoading: boolean = false;
  @Trace fabricLoadersLoaded: boolean = false;
  /** 已按哪个游戏版本拉过 loader 列表（换游戏版本 → 需重拉）。 */
  @Trace fabricLoadersGame: string = '';

  /**
   * loader 列表请求序号（非观察态）：每次请求/作废都自增；响应只在仍是"最新序号"时才写入，
   * 避免「切源 / 换游戏版本 / 重开安装面板后，旧的在途响应覆盖新状态」的竞态。
   */
  private fabricLoaderSeq: number = 0;

  /** NeoForge loader 版本列表与选中项（仅 1.20.2+；两条源与降级在数据层完成）。 */
  @Trace neoLoaders: NeoForgeRemoteVersion[] = [];
  @Trace neoLoader: string = '';
  @Trace neoLoadersLoading: boolean = false;
  @Trace neoLoadersLoaded: boolean = false;
  /** 已按哪个游戏版本拉过（换版本 → 需重拉）。 */
  @Trace neoLoadersGame: string = '';
  /** 上次拉取的失败摘要（用于区分「该版本没有 NeoForge」与「拉取失败」）。 */
  @Trace neoLoadersErrors: string = '';

  /**
   * NeoForge 列表请求序号（非观察态）：与 Fabric 同理，防「切源/换版本/重开面板后旧响应覆盖新状态」。
   */
  private neoLoaderSeq: number = 0;

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

  /**
   * 作废在途的 loader 列表请求并清空列表（切源 / 换游戏版本 / 重开安装面板时调用）。
   * 自增序号让旧请求的响应落地时被判为过期 → 直接丢弃，避免陈旧数据覆盖新状态。
   */
  resetFabricLoaders(): void {
    this.fabricLoaderSeq++;
    this.fabricLoadersLoading = false;
    this.fabricLoaders = [];
    this.fabricLoadersLoaded = false;
    this.fabricLoadersGame = '';
    this.fabricLoader = '';
  }

  /** 设置 Fabric 下载源；作废在途请求并清空列表（下次按新源重拉）。 */
  setFabricSource(source: string): void {
    if (source === this.fabricSource) {
      return;
    }
    this.fabricSource = source;
    this.resetFabricLoaders();
  }

  /** 拉取某游戏版本的 Fabric loader 列表（按 loader 源）；成功后默认选最新。 */
  async refreshFabricLoaders(gameVersion: string): Promise<void> {
    if (gameVersion.length === 0) {
      return;
    }
    const seq = ++this.fabricLoaderSeq;
    // 先取当次源：await 期间源可能被改，结果只在序号仍最新时才采用。
    const source = this.fabricSource;
    this.fabricLoadersLoading = true;
    this.errorKind = INSTALL_ERR_NONE;
    this.errorDetail = '';
    try {
      const list = await fetchFabricLoaders(gameVersion, source);
      if (seq !== this.fabricLoaderSeq) {
        return;
      }
      this.fabricLoaders = list;
      this.fabricLoadersLoaded = true;
      this.fabricLoadersGame = gameVersion;
      this.fabricLoader = list.length > 0 ? list[0].version : '';
    } catch (error) {
      if (seq !== this.fabricLoaderSeq) {
        return;
      }
      const err = error as BusinessError;
      this.errorKind = INSTALL_ERR_LOADER;
      this.errorDetail = err.message ?? '';
      this.fabricLoaders = [];
      this.fabricLoadersLoaded = false;
      this.fabricLoadersGame = '';
      this.fabricLoader = '';
    } finally {
      if (seq === this.fabricLoaderSeq) {
        this.fabricLoadersLoading = false;
      }
    }
  }

  /**
   * 安装 Fabric 实例（**单实例、HMCL 补丁式**）：vanilla 资产按 `this.source`（版本源），
   * Fabric 元数据/库按 `this.fabricSource`（loader 源）。返回是否成功。
   */
  async installFabric(gameRoot: string, remote: RemoteVersion, instanceName: string): Promise<boolean> {
    if (this.installingId.length > 0) {
      return false;
    }
    // 硬门：所选 loader 版本必须与本次要装的游戏版本匹配（列表可能因切源/换版本而陈旧）。
    if (this.fabricLoader.length === 0 || this.fabricLoadersGame !== remote.id) {
      this.errorKind = INSTALL_ERR_LOADER;
      this.errorDetail = '';
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
      await installFabricVersion(gameRoot, remote, this.fabricLoader, instanceName,
        this.source, this.fabricSource,
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
      // 失败收尾：清掉半装残留（缺 <名>.json 才清，绝不碰完整实例）。
      removeIncompleteInstance(gameRoot, instanceName);
      const err = error as BusinessError;
      this.errorKind = INSTALL_ERR_INSTALL;
      this.errorDetail = err.message ?? '';
      ok = false;
    }
    this.installingId = '';
    return ok;
  }

  /** 作废在途的 NeoForge 列表请求并清空（切源 / 换游戏版本 / 重开面板）。 */
  resetNeoLoaders(): void {
    this.neoLoaderSeq++;
    this.neoLoadersLoading = false;
    this.neoLoaders = [];
    this.neoLoadersLoaded = false;
    this.neoLoadersGame = '';
    this.neoLoadersErrors = '';
    this.neoLoader = '';
  }

  /**
   * 拉取某游戏版本的 NeoForge 列表（仅 1.20.2+，调用方负责版本门槛）；成功后默认选最新。
   * 复用「版本源」(this.source)：数据层内部按 镜像(BMCLAPI) → 官方 降级。
   */
  async refreshNeoLoaders(gameVersion: string): Promise<void> {
    if (gameVersion.length === 0) {
      return;
    }
    const seq = ++this.neoLoaderSeq;
    const source = this.source;
    this.neoLoadersLoading = true;
    this.errorKind = INSTALL_ERR_NONE;
    this.errorDetail = '';
    try {
      const result: NeoForgeListResult = await fetchNeoForgeVersions(gameVersion, source);
      if (seq !== this.neoLoaderSeq) {
        return;
      }
      this.neoLoaders = result.versions;
      this.neoLoadersErrors = result.errors;
      this.neoLoadersLoaded = true;
      this.neoLoadersGame = gameVersion;
      this.neoLoader = result.versions.length > 0 ? result.versions[0].loaderVersion : '';
      // 空列表 + 有失败摘要 ⇒ 是「拉取失败」而不是「该版本没有」。
      if (result.versions.length === 0 && result.errors.length > 0) {
        this.errorKind = INSTALL_ERR_LOADER;
        this.errorDetail = result.errors;
      }
    } catch (error) {
      if (seq !== this.neoLoaderSeq) {
        return;
      }
      const err = error as BusinessError;
      this.errorKind = INSTALL_ERR_LOADER;
      this.errorDetail = err.message ?? '';
      this.neoLoaders = [];
      this.neoLoadersLoaded = false;
      this.neoLoadersGame = '';
      this.neoLoader = '';
    } finally {
      if (seq === this.neoLoaderSeq) {
        this.neoLoadersLoading = false;
      }
    }
  }

  /**
   * 安装 NeoForge 实例（**仅 MC 1.20.2+**；HMCL 形态）。资产按 `this.source`（版本源）；
   * installer 与库的 url 由下载层按下载源重写为镜像。返回是否成功。
   */
  async installNeoForge(ctx: common.UIAbilityContext, gameRoot: string, gameRootUri: string,
    remote: RemoteVersion, instanceName: string): Promise<boolean> {
    if (this.installingId.length > 0) {
      return false;
    }
    // 硬门：所选 loader 版本必须与本次游戏版本匹配（列表可能因切源/换版本而陈旧）。
    if (this.neoLoader.length === 0 || this.neoLoadersGame !== remote.id) {
      this.errorKind = INSTALL_ERR_LOADER;
      this.errorDetail = '';
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
      await installNeoForgeVersion(ctx, gameRoot, gameRootUri, remote, this.neoLoader, instanceName, this.source,
        ctx.cacheDir,
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
      // 失败收尾：清掉半装残留（缺 <名>.json 才清，绝不碰完整实例）。
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
    // 与 Fabric 的 setFabricSource 对称：NeoForge 列表复用版本源 ⇒ 切源后必须作废重拉。
    this.resetNeoLoaders();
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
