import { common } from '@kit.AbilityKit';
import { AppStorageV2 } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteVersion, fetchManifest, installVersion, removeIncompleteInstance,
  fetchFabricLoaders, installFabricVersion, installNeoForgeVersion, fetchForgeVersions,
  installForgeVersion, FabricLoaderVersion, ForgeListResult,
  ForgeInstallerUnavailableError } from '../data/VersionInstaller';
import { fetchNeoForgeVersions, NeoForgeListResult, NeoForgeRemoteVersion } from '../data/NeoForgeVersionList';
import { SOURCE_MIRROR, TYPE_OTHER, TYPE_RELEASE,
  TYPE_SNAPSHOT } from '../constants/DownloadContract';

/** 安装的 mod loader 种类（原版 / Fabric / NeoForge / Forge）。 */
export const LOADER_KIND_VANILLA: string = 'vanilla';
export const LOADER_KIND_FABRIC: string = 'fabric';
/** NeoForge：**仅 MC 1.20.2+**（见 notes 20-design/launch/NeoForge支持-改动方案.md）。 */
export const LOADER_KIND_NEO_FORGE: string = 'neoforge';
/**
 * Forge：**本次只做 MC 1.7–1.12.2 的零 JVM 安装**（`spec` 形态带 client processor 的 1.13+
 * 由数据层明确拒绝；见 notes 20-design/launch/Forge支持-改动方案.md §13）。
 */
export const LOADER_KIND_FORGE: string = 'forge';
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
/**
 * Forge 所选构建没有 installer jar（官方列表可能含"不带安装器"的构建）。
 * 单列一种：UI 要给出**逐构建**的可操作文案（其余安装失败仍是 INSTALL_ERR_INSTALL 的泛用文案）。
 */
export const INSTALL_ERR_FORGE_NO_INSTALLER: number = 5;

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

  /**
   * 当前版本下载源（原版 'mirror' / 'official'），由下载面板设置。
   * **只服务纯原版路径**（清单 + client jar + 原版库 + 资源）：三个 loader 各有独立源，不读它
   * （依据 HMCL：文件源/列表源是**全局一对**、装 loader 时整条链共用同一源，不存在"原版走共享源、
   * loader 制品走另一源"的拆分；见 ref/HMCL `.../download/AutoDownloadProvider.java:78-101`）。
   */
  @Trace source: string = SOURCE_MIRROR;

  /** 版本类型过滤（release / snapshot / other），由下载面板设置。 */
  @Trace versionType: string = TYPE_RELEASE;

  /** 安装的 mod loader 种类（原版 / Fabric）；由"设置实例名"面板设置。 */
  @Trace loaderKind: string = LOADER_KIND_VANILLA;

  /** Fabric 下载源（**与版本源 this.source 独立**；镜像/官方）。 */
  @Trace fabricSource: string = SOURCE_MIRROR;

  /**
   * Forge 下载源（**与版本源 this.source 独立**；镜像/官方）。
   * 语义上与 Fabric 的 fabricSource 对称：Forge 制品（构建列表 / installer / 库）来自 MinecraftForge，
   * **不是 Mojang 提供** ⇒ 复用版本源的「官方（Mojang）」对本 loader 语义错误，故自持一份。
   */
  @Trace forgeSource: string = SOURCE_MIRROR;

  /**
   * NeoForge 下载源（**与版本源 this.source 独立**；镜像/官方）。
   * 与 fabricSource / forgeSource 同款：NeoForge 制品（版本列表 / installer / 库）来自 **NeoForged**
   * （`maven.neoforged.net`），不是 Mojang ⇒ 复用版本源的「官方（Mojang）」语义错误，故自持一份。
   */
  @Trace neoForgeSource: string = SOURCE_MIRROR;

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

  /** Forge 构建列表与选中项（**仅 MC 1.7–1.12.2**；列表与 installer 都按 **this.forgeSource**）。 */
  @Trace forgeLoaders: string[] = [];
  @Trace forgeLoader: string = '';
  @Trace forgeLoadersLoading: boolean = false;
  @Trace forgeLoadersLoaded: boolean = false;
  /** 已按哪个游戏版本拉过（换版本 → 需重拉）。 */
  @Trace forgeLoadersGame: string = '';

  /** Forge 列表请求序号（非观察态）：与 Fabric/NeoForge 同理，防旧响应覆盖新状态。 */
  private forgeLoaderSeq: number = 0;

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

  /** 设置 Forge 下载源；作废在途请求并清空列表（下次按新源重拉）。与 setFabricSource 对称。 */
  setForgeSource(source: string): void {
    if (source === this.forgeSource) {
      return;
    }
    this.forgeSource = source;
    this.resetForgeLoaders();
  }

  /** 设置 NeoForge 下载源；作废在途请求并清空列表（下次按新源重拉）。与 setFabricSource 对称。 */
  setNeoForgeSource(source: string): void {
    if (source === this.neoForgeSource) {
      return;
    }
    this.neoForgeSource = source;
    this.resetNeoLoaders();
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
   * 安装 Fabric 实例（**单实例、HMCL 补丁式**）：**整条安装链**（vanilla 清单 / client jar / 原版库 /
   * 资源 + Fabric 元数据 / 库）都按 `this.fabricSource`（loader 自己的源）——对齐 HMCL 的"一次安装只有一个
   * 文件源"（`AutoDownloadProvider` 同时管列表与文件，不区分原版件与 loader 件；
   * ref/HMCL `.../download/AutoDownloadProvider.java:78-101`）。返回是否成功。
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
      await installFabricVersion(gameRoot, remote, this.fabricLoader, instanceName, this.fabricSource,
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
   * 按 **NeoForge 自己的下载源**(this.neoForgeSource)（与 Fabric/Forge 同款：制品来自 NeoForged，
   * 非 Mojang，不用版本源 this.source）；数据层内部按 镜像(BMCLAPI) → 官方 降级（官方源则只走官方 API）。
   */
  async refreshNeoLoaders(gameVersion: string): Promise<void> {
    if (gameVersion.length === 0) {
      return;
    }
    const seq = ++this.neoLoaderSeq;
    // 先取当次源：await 期间源可能被改，结果只在序号仍最新时才采用（与 refreshFabricLoaders 一致）。
    const source = this.neoForgeSource;
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
   * 安装 NeoForge 实例（**仅 MC 1.20.2+**；HMCL 形态）。整个安装（清单 / installer / 库 / 资产）都按
   * `this.neoForgeSource`（**NeoForge 自己的源**，与 installForge 传 forgeSource 对称）——制品来自
   * NeoForged（`maven.neoforged.net`），不复用版本源 this.source。
   * `jreId` = 安装期**工具 JVM** 用的那套 JRE id（由调用方按 (MC 版本 × NeoForge) 经 `JavaPolicy`
   * 解析得出，与启动路径同源）；一路透传到 `:neoinstall`，不在此重解析。
   */
  async installNeoForge(ctx: common.UIAbilityContext, gameRoot: string, gameRootUri: string,
    remote: RemoteVersion, instanceName: string, jreId: string): Promise<boolean> {
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
      await installNeoForgeVersion(ctx, gameRoot, gameRootUri, remote, this.neoLoader, instanceName,
        this.neoForgeSource, ctx.cacheDir, jreId,
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

  /** 作废在途的 Forge 列表请求并清空（切源 / 换游戏版本 / 重开面板）。 */
  resetForgeLoaders(): void {
    this.forgeLoaderSeq++;
    this.forgeLoadersLoading = false;
    this.forgeLoaders = [];
    this.forgeLoadersLoaded = false;
    this.forgeLoadersGame = '';
    this.forgeLoader = '';
  }

  /**
   * 拉取某游戏版本的 Forge 构建列表（**仅 1.7–1.12.2**，调用方负责版本门槛）；成功后默认选最新。
   * 按 **Forge 自己的下载源**(this.forgeSource)——与 Fabric 的 refreshFabricLoaders 同款（Forge 制品来自
   * MinecraftForge，非 Mojang，不用版本源 this.source）；列表源顺序随所选源变化（所选源在前、另一源尽力兜底）：
   *   · mirror  → BMCLAPI 专用列表端点 → 官方 maven-metadata（兜底）；
   *   · official → 仅官方 maven-metadata（不请求 BMCLAPI）。
   * 细节见 `VersionInstaller.fetchForgeVersions` 的文档注释。
   */
  async refreshForgeLoaders(gameVersion: string): Promise<void> {
    if (gameVersion.length === 0) {
      return;
    }
    const seq = ++this.forgeLoaderSeq;
    // 先取当次源：await 期间源可能被改，结果只在序号仍最新时才采用（与 refreshFabricLoaders 一致）。
    const source = this.forgeSource;
    this.forgeLoadersLoading = true;
    this.errorKind = INSTALL_ERR_NONE;
    this.errorDetail = '';
    try {
      const result: ForgeListResult = await fetchForgeVersions(gameVersion, source);
      if (seq !== this.forgeLoaderSeq) {
        return;
      }
      this.forgeLoaders = result.versions;
      this.forgeLoadersLoaded = true;
      this.forgeLoadersGame = gameVersion;
      this.forgeLoader = result.versions.length > 0 ? result.versions[0] : '';
      // 空列表 + 有失败摘要 ⇒ 是「拉取失败」而不是「该版本没有」。
      if (result.versions.length === 0 && result.errors.length > 0) {
        this.errorKind = INSTALL_ERR_LOADER;
        this.errorDetail = result.errors;
      }
    } catch (error) {
      if (seq !== this.forgeLoaderSeq) {
        return;
      }
      const err = error as BusinessError;
      this.errorKind = INSTALL_ERR_LOADER;
      this.errorDetail = err.message ?? '';
      this.forgeLoaders = [];
      this.forgeLoadersLoaded = false;
      this.forgeLoadersGame = '';
      this.forgeLoader = '';
    } finally {
      if (seq === this.forgeLoaderSeq) {
        this.forgeLoadersLoading = false;
      }
    }
  }

  /**
   * 安装 Forge 实例（**零 JVM 面：仅 MC 1.7–1.12.2**；见 `VersionInstaller.installForgeVersion`）。
   * 整个安装（构建列表之外的清单 / installer / 库 / 资产）都按 `this.forgeSource`（**Forge 自己的源**，
   * 与 Fabric 的 installFabric 传 loaderSource 对称）——Forge 制品来自 MinecraftForge，不复用版本源 this.source。
   * 全程在 ArkTS 内完成（不起工具 JVM ⇒ **无需** JRE 就绪前置，与 NeoForge/processor 形态不同）；
   * `cacheDir` 只用于 installer 解包。
   */
  async installForge(gameRoot: string, remote: RemoteVersion, instanceName: string,
    cacheDir: string): Promise<boolean> {
    if (this.installingId.length > 0) {
      return false;
    }
    // 硬门：所选 loader 版本必须与本次要装的游戏版本匹配（列表可能因切源/换版本而陈旧）。
    if (this.forgeLoader.length === 0 || this.forgeLoadersGame !== remote.id) {
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
      await installForgeVersion(gameRoot, remote, this.forgeLoader, instanceName, this.forgeSource, cacheDir,
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
      if (error instanceof ForgeInstallerUnavailableError) {
        // 该构建在所选源下没有 installer jar ⇒ 专属文案（把构建名带上，供 UI 作 $r 参数）。
        this.errorKind = INSTALL_ERR_FORGE_NO_INSTALLER;
        this.errorDetail = error.buildId;
      } else {
        const err = error as BusinessError;
        this.errorKind = INSTALL_ERR_INSTALL;
        this.errorDetail = err.message ?? '';
      }
      ok = false;
    }
    this.installingId = '';
    return ok;
  }

  /** 设置版本下载源（面板用）；清空已加载的清单，等待用户点「获取版本列表」。 */
  setSource(source: string): void {
    if (source === this.source) {
      return;
    }
    this.source = source;
    this.manifestLoaded = false;
    this.manifest = [];
    this.visible = [];
    // 三个 loader 各有独立源（fabricSource / forgeSource / neoForgeSource）⇒ 切**版本源**不影响它们的列表，
    // 故此处不作废任何 loader 列表（各自的 setXxxSource 才作废自己的那份）。
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
