import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { authorizeDirectory, showInFiles } from '../common/access/FileAccess';
import {
  BORDER_RADIUS,
  DOWNLOAD_CARD_MAX_W, DOWNLOAD_CARD_MIN_W, DOWNLOAD_LIST_HEIGHT,
  LAYOUT_PADDING_SMALL, LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY
} from '../common/constants/Constants';
import {
  SOURCE_MIRROR, SOURCE_OFFICIAL, TYPE_OTHER, TYPE_RELEASE, TYPE_SNAPSHOT
} from '../common/constants/DownloadContract';
import { RENDERER_AUTO, RENDERER_ENV, RENDERER_ENV_GL4ES } from '../common/constants/LaunchDefaults';
import { rendererForVersion } from '../common/data/RendererPolicy';
import { LOADER_FABRIC, LOADER_LEGACY_FABRIC, VERSION_FORM_VANILLA } from '../common/data/VersionResolver';
import { SettingsTools, RendererOverride } from '../common/data/SettingsTools';
import {
  canWriteDirectory, isValidInstanceName, PHASE_FILES, PHASE_ASSETS, RemoteVersion,
  versionDirExists
} from '../common/data/VersionInstaller';
import { GameVersion, resolveGameRoot } from '../common/data/VersionScanner';
import { versionDirUri } from '../common/constants/Paths';
import { deleteVersionDir } from '../common/data/VersionTools';
import {
  launchInMainProcess, LAUNCH_OK, LAUNCH_ERR_NO_ACCOUNT, LAUNCH_ERR_MS_EXPIRED
} from '../common/data/VersionLaunch';
import { getInstallerState, InstallerState, INSTALL_ERR_INSTALL, INSTALL_ERR_LOADER, INSTALL_ERR_MANIFEST, INSTALL_ERR_NO_WRITE, INSTALL_ERR_NONE, LOADER_KIND_FABRIC, LOADER_KIND_VANILLA } from '../common/state/InstallerState';
import { getLauncherState, LauncherState } from '../common/state/LauncherState';
import { AccountState, getAccountState } from '../common/state/AccountState';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameVersionsView';

/** 实例名校验结果（UI 据此显示提示 / 是否允许「确认安装」）。 */
const NAME_OK: number = 0;
const NAME_INVALID: number = 1;
const NAME_CONFLICT: number = 2;

/**
 * 游戏版本列表区块（与 GameDirsView 平级，由 Index 挂载）。
 *
 * 职责：展示"当前选中的目录"下识别到的已安装版本，并提供刷新。
 * 三种状态：
 * 1. 未选择目录 → 提示先选择；
 * 2. 已选择但未授权 → 只显示"授权"按钮（未授权读不了目录，不能扫版本）；
 * 3. 已授权 → 版本列表 + 刷新按钮。
 *
 * 数据来源：与 GameDirsView 共享同一个 LauncherState（AppStorageV2）。
 * - 目录区切换选中 / 授权后会调用 state.refreshVersions()，这里直接读 state.versions 展示；
 * - 本组件自身的"刷新"按钮与首次挂载也调用 state.refreshVersions() 兜底。
 */
@ComponentV2
export struct GameVersionsView {
  /** 共享应用状态（与目录选择区同一实例）。 */
  @Local state: LauncherState = getLauncherState();

  /** 当前展开"编辑"面板的版本 id（空串 = 全部收起；同一时刻只展开一个）。 */
  @Local editingId: string = '';

  /** 被编辑的版本对象（面板渲染在列表上方、列表之外，供其取字段；editingId 为空时为占位对象）。 */
  @Local editing: GameVersion = new GameVersion('', '', '', '', 0, '', '', '', '');

  /** 被编辑实例所属的游戏目录（打开时快照）：跨目录切换后仍指向原目录，标题据此标注、删除/相对路径据此刻定目标。 */
  @Local editingDirUri: string = '';
  @Local editingRoot: string = '';
  @Local editingDirName: string = '';

  /** 是否展开"下载新版本"面板（由"下载/收起"按钮切换）。 */
  @Local showDownload: boolean = false;

  /** 正在设置实例名的远程版本 id（空串 = 未展开"设置实例名"安装面板）。 */
  @Local installTargetId: string = '';

  /** 安装面板里的实例名输入（默认 = 版本号）。 */
  @Local installName: string = '';

  /** 安装面板目标远程版本（缓存对象：切下载源/类型导致 visible 重建时仍可确认）。 */
  private installTargetRef: RemoteVersion | null = null;

  /** 逐版本渲染后端覆盖（编辑面板的下拉；与 Preferences 同源）。 */
  @Local overrides: RendererOverride[] = [];

  /** 逐版本「线程化渲染」**关闭**表（复制 Preferences，供编辑面板开关展示；未列入 = 开）。 */
  @Local glThreadOffIds: string[] = [];

  /** 安装器共享状态（与 InstallerState 同一实例，承载远程清单/单任务进度/错误）。 */
  @Local installer: InstallerState = getInstallerState();

  /** 账户共享状态（与 AccountView 同一实例）：启动前需已选中账户。 */
  @Local accountState: AccountState = getAccountState();

  /** "游戏中"轮询定时器（跨进程探测，UI 常驻时每 2s 刷新一次）。 */
  private pollTimer: number = -1;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 首次挂载：扫描版本 + 同步 JRE 就绪态 + 开启"游戏中"轮询。 */
  aboutToAppear(): void {
    this.state.refreshVersions();
    this.state.refreshJre(this.context().filesDir);
    // 账户就绪态（启动门之一）：与 AccountView 共享同一 AccountState，这里兜底重读一次。
    this.accountState.reload(this.context());
    // 隔离开关状态来自 Preferences（持久化），载入共享状态供 UI 展示。
    this.state.isolatedIds = new SettingsTools(this.context()).versionIsolationIds();
    // 逐版本渲染后端覆盖（持久化）载入，供编辑面板下拉展示。
    this.overrides = new SettingsTools(this.context()).rendererOverrides();
    // 逐版本「线程化渲染」关闭表（持久化）载入。
    this.glThreadOffIds = new SettingsTools(this.context()).glThreadOffIds();
    // 下载源（持久化）：默认镜像，海外可切官方。
    this.installer.source = new SettingsTools(this.context()).downloadSource();
    // mod loader 下载源（**独立于版本源**）：持久化载入。
    this.installer.fabricSource = new SettingsTools(this.context()).fabricSource();
    // 版本类型过滤（持久化）：默认正式版。
    this.installer.setVersionType(new SettingsTools(this.context()).versionType());
    this.state.refreshGameRunning();
    this.pollTimer = setInterval(() => {
      this.state.refreshGameRunning();
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 编辑按钮文案：该行未展开显示"编辑"，展开中显示"完成"。 */
  private editLabel(versionId: string): Resource {
    return this.editingId === versionId
      ? $r('app.string.common_done')
      : $r('app.string.common_edit');
  }

  /**
   * 展开 / 收起某版本的编辑面板（同一时刻只展开一个）。面板渲染在版本列表**上方**（列表之外），
   * 故同时缓存被编辑的 GameVersion 对象。
   */
  private toggleEdit(v: GameVersion): void {
    if (this.editingId === v.id) {
      this.editingId = '';
      return;
    }
    this.editingId = v.id;
    this.editing = v;
    // 快照"该实例所属的游戏目录"：面板跨目录切换后仍指向它（标题标注 + 删除/相对路径据此刻定目标）。
    this.editingDirUri = this.state.selected;
    this.editingRoot = resolveGameRoot(this.state.selected);
    const dir = this.state.dirs.find((d) => d.uri === this.state.selected);
    this.editingDirName = dir !== undefined ? dir.name : '';
  }

  /** 发行日期显示：releaseTime 为 ISO 串（如 2024-06-13T15:00:00+00:00），只取日期部分。 */
  private fmtReleaseDate(raw: string): string {
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  /**
   * 版本类型展示：原版 / Fabric / Legacy Fabric / 未知。
   * 「未知」= 有继承/补丁形态但加载器识别不出（如 Forge/NeoForge/Quilt/整合包等我们暂不点名的 loader）。
   */
  private versionTypeLabel(v: GameVersion): Resource {
    if (v.loader === LOADER_LEGACY_FABRIC) {
      return $r('app.string.version_type_legacy_fabric');
    }
    if (v.loader === LOADER_FABRIC) {
      return $r('app.string.version_type_fabric');
    }
    if (v.form === VERSION_FORM_VANILLA) {
      return $r('app.string.version_type_vanilla');
    }
    return $r('app.string.version_type_unknown');
  }

  /** 编辑面板标题：`编辑版本 - <游戏目录昵称> - <实例名>`（无目录昵称时省略中段）。 */
  private editTitle(v: GameVersion): Resource {
    return this.editingDirName.length > 0
      ? $r('app.string.version_edit_title', this.editingDirName, v.id)
      : $r('app.string.version_edit_title_nofolder', v.id);
  }

  /**
   * JSON 路径显示：截去游戏根前缀，只显示游戏目录内的相对路径（如 `versions/<id>/<id>.json`）；
   * 不在根内（异常）时退回绝对路径。
   */
  private relJsonPath(v: GameVersion): string {
    const root = this.editingRoot;
    const path = v.jsonPath;
    if (root.length > 0 && path.startsWith(root)) {
      let rel = path.substring(root.length);
      if (rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      if (rel.length > 0) {
        return rel;
      }
    }
    return path;
  }

  /** 切换某版本的版本隔离：落盘 Preferences 后回读，保证 UI 与持久化同源。 */
  private setIsolation(versionId: string, on: boolean): void {
    const settings = new SettingsTools(this.context());
    settings.setVersionIsolation(versionId, on);
    this.state.isolatedIds = settings.versionIsolationIds();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'isolation %{public}s = %{public}s',
      versionId, on ? 'on' : 'off');
  }

  /** 删除版本入口：二次确认（已启用隔离时额外告警存档/选项会一并删除）后再执行。 */
  private confirmDelete(v: GameVersion): void {
    const isolated = this.state.isIsolated(v.id);
    this.getUIContext().showAlertDialog({
      title: $r('app.string.version_delete_title'),
      message: isolated
        ? $r('app.string.version_delete_message_isolated', v.id)
        : $r('app.string.version_delete_message', v.id, v.id),
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {
        },
      },
      secondaryButton: {
        value: $r('app.string.common_delete'),
        fontColor: $r('app.color.danger'),
        action: () => {
          this.deleteVersion(v);
        },
      },
    });
  }

  /**
   * 删除该版本：递归删 <gameRoot>/versions/<id>/（隔离时含存档/选项/日志，见确认文案），
   * 清理其持久化设置，收起编辑面板并刷新列表。assets/libraries 共享池不动。
   */
  private deleteVersion(v: GameVersion): void {
    // 兜底复检：按钮已按 gameRunning 禁用，但轮询有 ~2s 延迟，这里再实时判一次。
    if (this.state.gameRunning) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'delete abort: game running');
      return;
    }
    const root = this.editingRoot;
    if (root.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'delete abort: no game root');
      return;
    }
    if (!deleteVersionDir(root, v.id)) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'delete failed: %{public}s', v.id);
      this.getUIContext().showAlertDialog({
        message: $r('app.string.version_delete_failed'),
      });
      return;
    }
    const settings = new SettingsTools(this.context());
    // 逐版本设置（隔离 / 渲染后端 / 线程化渲染）**只按实例 id 存**，跨 .minecraft 根的同名实例会撞键。
    // 故只有当**没有别的已授权目录**还留同名实例时才清；否则会把另一根那份的设置一并抹掉。
    const elsewhere = this.state.dirs.some((d) =>
      d.uri !== this.editingDirUri && versionDirExists(resolveGameRoot(d.uri), v.id));
    if (elsewhere) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'keep per-version settings for %{public}s (same id exists in another root)', v.id);
    } else {
      settings.clearVersion(v.id);
    }
    // 若"上次启动"正是这个版本，一并清理记录（否则"继续上次"会指向已删版本）。
    settings.clearLastLaunchIf(this.editingDirUri, v.id);
    this.state.refreshLastLaunch(this.context());
    this.state.isolatedIds = settings.versionIsolationIds();
    this.overrides = settings.rendererOverrides();
    this.glThreadOffIds = settings.glThreadOffIds();
    if (this.editingId === v.id) {
      this.editingId = '';
    }
    this.state.refreshVersions();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'deleted version %{public}s', v.id);
  }

  /** 渲染后端 Select 选项：推荐 / OpenGLv4 / GL4ES（兼容）。 */
  private rendererOptions(): SelectOption[] {
    return [
      { value: $r('app.string.renderer_auto') },
      { value: $r('app.string.renderer_openglv4') },
      { value: $r('app.string.renderer_gl4es') },
    ];
  }

  /** 某版本当前渲染后端（auto/openglv4/gl4es）；无覆盖 = auto。 */
  private rendererBackend(versionId: string): string {
    for (const o of this.overrides) {
      if (o.id === versionId) {
        return o.backend;
      }
    }
    return RENDERER_AUTO;
  }

  private rendererIndex(versionId: string): number {
    const b = this.rendererBackend(versionId);
    if (b === RENDERER_ENV) {
      return 1;
    }
    if (b === RENDERER_ENV_GL4ES) {
      return 2;
    }
    return 0;
  }

  private rendererValue(versionId: string): Resource {
    const i = this.rendererIndex(versionId);
    if (i === 1) {
      return $r('app.string.renderer_openglv4');
    }
    if (i === 2) {
      return $r('app.string.renderer_gl4es');
    }
    return $r('app.string.renderer_auto');
  }

  /** 切换某版本的渲染后端：落盘 Preferences 后回读（游戏进程启动时读同一份）。 */
  private setRenderer(versionId: string, index: number): void {
    const backend = index === 1 ? RENDERER_ENV
      : (index === 2 ? RENDERER_ENV_GL4ES : RENDERER_AUTO);
    const settings = new SettingsTools(this.context());
    settings.setRendererOverride(versionId, backend);
    this.overrides = settings.rendererOverrides();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'renderer %{public}s = %{public}s', versionId, backend);
  }

  /** 该版本的「线程化渲染」是否可用：**只有 OpenGLv4（桌面 GL）后端**有效，其余后端灰化。 */
  private glThreadSupported(v: GameVersion): boolean {
    return rendererForVersion(v.mcVersion, this.rendererBackend(v.id)).env === RENDERER_ENV;
  }

  /** 某版本是否启用「线程化渲染」（**默认开**）。 */
  private glThreadEnabled(versionId: string): boolean {
    return !this.glThreadOffIds.includes(versionId);
  }

  /** 切换某版本的「线程化渲染」：落盘 Preferences 后回读（游戏进程启动时读同一份）。 */
  private setGlThread(versionId: string, on: boolean): void {
    const settings = new SettingsTools(this.context());
    settings.setGlThreadEnabled(versionId, on);
    this.glThreadOffIds = settings.glThreadOffIds();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'glthread %{public}s = %{public}s', versionId, on ? 'on' : 'off');
  }

  /** 授权当前选中目录：成功后刷新版本扫描。 */
  async authorizeSelected(): Promise<void> {
    const uri = this.state.selected;
    const ok = await authorizeDirectory(this.context(), uri);
    if (ok && !this.state.activated.includes(uri)) {
      this.state.activated = this.state.activated.concat(uri);
      this.state.refreshVersions();
    }
  }

  /** 启动门：需已选中账户（与 JRE 就绪同级）。 */
  private accountReady(): boolean {
    return this.accountState.selectedId.length > 0;
  }

  /**
   * 启动选中版本：由 jsonPath 反推 .minecraft 根 → 弹独立游戏窗口 → 窗口内起 JVM。
   * jsonPath 形如 <root>/versions/<id>/<id>.json。
   */
  async launch(v: GameVersion): Promise<void> {
    const out = await launchInMainProcess(this.context(), v);
    if (out.code === LAUNCH_ERR_NO_ACCOUNT) {
      this.getUIContext().showAlertDialog({ message: $r('app.string.versions_need_account') });
      return;
    }
    if (out.code === LAUNCH_ERR_MS_EXPIRED) {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.accounts_login_expired'),
        message: out.detail,
      });
      return;
    }
    if (out.code !== LAUNCH_OK) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'launch aborted for %{public}s (code %{public}d)', v.id, out.code);
      this.getUIContext().showAlertDialog({ message: $r('app.string.launch_failed') });
      return;
    }
    // 记录"上次启动"，供"继续上次"按钮一键启动。
    new SettingsTools(this.context()).setLastLaunch(this.state.selected, v.id, v.jsonPath);
    this.state.refreshLastLaunch(this.context());
    hilog.info(LOG_DOMAIN, LOG_TAG, 'open game window for %{public}s', v.id);
  }

  /** 切换下载面板；不再自动拉清单（由用户选源后点「获取版本列表」）。 */
  private toggleDownload(): void {
    this.showDownload = !this.showDownload;
  }

  /** 安装阶段文案。 */
  private phaseText(): Resource {
    if (this.installer.phase === PHASE_FILES) {
      return $r('app.string.download_phase_files');
    }
    if (this.installer.phase === PHASE_ASSETS) {
      return $r('app.string.download_phase_assets');
    }
    return $r('app.string.download_phase_write');
  }

  /** 错误文案（按错误种类选资源）。 */
  private errorText(): Resource {
    if (this.installer.errorKind === INSTALL_ERR_NO_WRITE) {
      return $r('app.string.download_error_no_write');
    }
    if (this.installer.errorKind === INSTALL_ERR_MANIFEST) {
      return $r('app.string.download_error_manifest');
    }
    return $r('app.string.download_error_install');
  }

  /** 下载源 Select 选项（镜像 / 官方）。 */
  private sourceOptions(): SelectOption[] {
    return [
      { value: $r('app.string.download_source_mirror') },
      { value: $r('app.string.download_source_official') },
    ];
  }

  /** 切换下载源：仅持久化并清空旧清单（不立即拉取，等用户点按钮）。 */
  private setDownloadSource(source: string): void {
    new SettingsTools(this.context()).setDownloadSource(source);
    this.installer.setSource(source);
  }

  /** 版本类型 Select 选项（正式版 / 快照 / 其他）。 */
  private typeOptions(): SelectOption[] {
    return [
      { value: $r('app.string.download_type_release') },
      { value: $r('app.string.download_type_snapshot') },
      { value: $r('app.string.download_type_other') },
    ];
  }

  private selectedTypeIndex(): number {
    if (this.installer.versionType === TYPE_SNAPSHOT) {
      return 1;
    }
    if (this.installer.versionType === TYPE_OTHER) {
      return 2;
    }
    return 0;
  }

  private typeValue(): Resource {
    const i = this.selectedTypeIndex();
    if (i === 1) {
      return $r('app.string.download_type_snapshot');
    }
    if (i === 2) {
      return $r('app.string.download_type_other');
    }
    return $r('app.string.download_type_release');
  }

  /** 切换版本类型：持久化 + 对已加载清单即时过滤（不重新拉取）。 */
  private setVersionType(index: number): void {
    const t = index === 1 ? TYPE_SNAPSHOT : (index === 2 ? TYPE_OTHER : TYPE_RELEASE);
    new SettingsTools(this.context()).setVersionType(t);
    this.installer.setVersionType(t);
  }

  // ---- mod loader 选择（原版 / Fabric）----

  /** 加载器 Select 选项（原版 / Fabric）。 */
  private loaderOptions(): SelectOption[] {
    return [
      { value: $r('app.string.loader_vanilla') },
      { value: $r('app.string.loader_fabric') },
    ];
  }

  private loaderIndex(): number {
    return this.installer.loaderKind === LOADER_KIND_FABRIC ? 1 : 0;
  }

  private loaderValue(): Resource {
    return this.loaderIndex() === 1 ? $r('app.string.loader_fabric') : $r('app.string.loader_vanilla');
  }

  /** 切换 mod loader 种类；切到 Fabric 时拉取该游戏版本的 loader 列表（未拉过才拉）。 */
  private setLoaderKind(index: number): void {
    const kind = index === 1 ? LOADER_KIND_FABRIC : LOADER_KIND_VANILLA;
    this.installer.loaderKind = kind;
    if (kind === LOADER_KIND_FABRIC && this.installer.fabricLoadersGame !== this.installTargetId) {
      this.installer.refreshFabricLoaders(this.installTargetId);
    }
  }

  /** 切换 mod loader 下载源（独立于版本源）：持久化 + 清列表 + 重拉。 */
  private setFabricSource(index: number): void {
    const src = index === 1 ? SOURCE_OFFICIAL : SOURCE_MIRROR;
    new SettingsTools(this.context()).setFabricSource(src);
    this.installer.setFabricSource(src);
    this.installer.refreshFabricLoaders(this.installTargetId);
  }

  // 注：源/版本文案按 **loader 维度**组织（资源名以 loader 结尾），便于日后新增 loader。
  /** 该 loader 的下载源下拉项（镜像 / 官方；官方文案按 loader 区分，Fabric=官方（FabricMC））。 */
  private loaderSourceOptions(): SelectOption[] {
    return [
      { value: $r('app.string.loader_source_mirror') },
      { value: $r('app.string.loader_source_official_fabric') },
    ];
  }

  private loaderSourceIndex(): number {
    return this.installer.fabricSource === SOURCE_OFFICIAL ? 1 : 0;
  }

  private loaderSourceValue(): Resource {
    return this.loaderSourceIndex() === 1
      ? $r('app.string.loader_source_official_fabric')
      : $r('app.string.loader_source_mirror');
  }

  /** loader 版本下拉项（全部版本进一个下拉，省空间）。 */
  private loaderVersionOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (const l of this.installer.fabricLoaders) {
      out.push({ value: l.version });
    }
    return out;
  }

  private loaderVersionIndex(): number {
    const list = this.installer.fabricLoaders;
    for (let i = 0; i < list.length; i++) {
      if (list[i].version === this.installer.fabricLoader) {
        return i;
      }
    }
    return 0;
  }

  /** 选择某 loader 版本（按下拉索引）。 */
  private selectFabricLoaderByIndex(index: number): void {
    const list = this.installer.fabricLoaders;
    if (index >= 0 && index < list.length) {
      this.installer.fabricLoader = list[index].version;
    }
  }

  /** 「确认安装」是否可点：空闲 + 未运行 + 名合法 + （Fabric 时）已选 loader 版本。 */
  private canConfirmInstall(): boolean {
    if (this.installer.installingId.length > 0 || this.state.gameRunning) {
      return false;
    }
    if (this.instanceNameErrorKind() !== NAME_OK) {
      return false;
    }
    if (this.installer.loaderKind === LOADER_KIND_FABRIC && this.installer.fabricLoader.length === 0) {
      return false;
    }
    return true;
  }

  /** 字节数格式化（进度显示用；动态数据，非 UI 文案）。 */
  private fmtSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes < kb) {
      return `${bytes} B`;
    }
    if (bytes < mb) {
      return `${(bytes / kb).toFixed(1)} KB`;
    }
    return `${(bytes / mb).toFixed(1)} MB`;
  }

  /** 打开某远程版本的"设置实例名"安装面板（默认名 = 版本号）。 */
  private openInstallPanel(remote: RemoteVersion): void {
    this.installTargetRef = remote;
    this.installTargetId = remote.id;
    this.installName = remote.id;
    // 每次打开重置为原版；Fabric 源持久化，loader 列表按需重拉。
    // resetFabricLoaders 同时作废在途请求，避免上一个版本的在途响应污染本面板。
    this.installer.loaderKind = LOADER_KIND_VANILLA;
    this.installer.resetFabricLoaders();
    this.installer.errorKind = INSTALL_ERR_NONE;
    this.installer.errorDetail = '';
  }

  /** 关闭"设置实例名"安装面板。 */
  private closeInstallPanel(): void {
    this.installTargetRef = null;
    this.installTargetId = '';
  }

  /** 实例名校验结果：NAME_OK / NAME_INVALID / NAME_CONFLICT（`versions/<名>` 已存在）。 */
  private instanceNameErrorKind(): number {
    const name = this.installName.trim();
    if (!isValidInstanceName(name)) {
      return NAME_INVALID;
    }
    const root = resolveGameRoot(this.state.selected);
    if (root.length > 0 && versionDirExists(root, name)) {
      return NAME_CONFLICT;
    }
    return NAME_OK;
  }

  /** 确认安装：名称合法且不冲突、游戏未运行才真正安装（否则禁止）。 */
  private async confirmInstall(): Promise<void> {
    const remote = this.installTargetRef;
    if (remote === null || !this.canConfirmInstall()) {
      return;
    }
    const fabric = this.installer.loaderKind === LOADER_KIND_FABRIC;
    const name = this.installName.trim();
    this.closeInstallPanel();
    if (fabric) {
      await this.installFabricRemote(remote, name);
    } else {
      await this.installRemote(remote, name);
    }
  }

  /**
   * 把某远程版本安装为实例 `versions/<instanceName>/`；完成后刷新版本列表。
   * 安装前校验目录写权限（授权失效时不能写，UI 明确提示）。
   */
  async installRemote(remote: RemoteVersion, instanceName: string): Promise<void> {
    const root = resolveGameRoot(this.state.selected);
    if (root.length === 0) {
      // 兜底：解析不出目录时给出可见错误，而不是静默无反应。
      this.installer.errorKind = INSTALL_ERR_INSTALL;
      this.installer.errorDetail = '';
      return;
    }
    if (!canWriteDirectory(root)) {
      this.installer.errorKind = INSTALL_ERR_NO_WRITE;
      this.installer.errorDetail = '';
      return;
    }
    const ok = await this.installer.install(root, remote, instanceName);
    if (ok) {
      // 与 HMCL 一致（enableIsolation）：新装实例默认开启版本隔离（游戏数据落 versions/<id>/）。
      const settings = new SettingsTools(this.context());
      settings.setVersionIsolation(instanceName, true);
      this.state.isolatedIds = settings.versionIsolationIds();
    }
    this.state.refreshVersions();
  }

  /**
   * 安装 Fabric 实例（**单实例、HMCL 补丁式**）：版本资产按版本源、Fabric 资产按 loader 源（独立）。
   * 安装前同样校验目录写权限；成功后默认开启隔离并刷新列表。
   */
  async installFabricRemote(remote: RemoteVersion, instanceName: string): Promise<void> {
    const root = resolveGameRoot(this.state.selected);
    if (root.length === 0) {
      this.installer.errorKind = INSTALL_ERR_INSTALL;
      this.installer.errorDetail = '';
      return;
    }
    if (!canWriteDirectory(root)) {
      this.installer.errorKind = INSTALL_ERR_NO_WRITE;
      this.installer.errorDetail = '';
      return;
    }
    const ok = await this.installer.installFabric(root, remote, instanceName);
    if (ok) {
      const settings = new SettingsTools(this.context());
      settings.setVersionIsolation(instanceName, true);
      this.state.isolatedIds = settings.versionIsolationIds();
    }
    this.state.refreshVersions();
  }

  /**
   * 版本「编辑」面板（渲染在版本列表**上方**、列表之外；同一时刻只展开一个）。
   * 字段：版本类型 / JSON / 发行日期 / 渲染后端 / 版本隔离 / 删除版本。不含改名。
   */
  @Builder
  editPanel() {
    Column({ space: LAYOUT_SPACE_SMALL }) {
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text(this.editTitle(this.editing));
          // 次要元信息合一行：版本类型 · 发行日期 · JSON 相对路径（JSON 可长 → 占余量 + 省略号）
          Row({ space: LAYOUT_SPACE }) {
            Text(this.versionTypeLabel(this.editing))
              .opacity(OPACITY_SECONDARY);
            if (this.editing.releaseTime.length > 0) {
              Text(this.fmtReleaseDate(this.editing.releaseTime))
                .opacity(OPACITY_SECONDARY);
            }
            Text(this.relJsonPath(this.editing))
              .layoutWeight(1)
              .opacity(OPACITY_SECONDARY);
          }
          .alignItems(VerticalAlign.Center);
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Button($r('app.string.common_done'))
          .onClick(() => {
            this.editingId = '';
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Divider().padding({ top: LAYOUT_SPACE_SMALL });

      // 版本隔离（标题 + 说明放进一个 Column，与右侧开关并列）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.version_isolation_label'));
          Text($r('app.string.version_isolation_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
        Toggle({ type: ToggleType.Switch, isOn: this.state.isIsolated(this.editing.id) })
          .onChange((isOn: boolean) => {
            this.setIsolation(this.editing.id, isOn);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 渲染后端（逐版本）：推荐 / OpenGLv4 / GL4ES（兼容）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.version_renderer_label'));
          Text($r('app.string.version_renderer_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
        Select(this.rendererOptions())
          .width('auto')
          .selected(this.rendererIndex(this.editing.id))
          .value(this.rendererValue(this.editing.id))
          .onSelect((index: number) => {
            this.setRenderer(this.editing.id, index);
          })
          .selectedOptionBgColor($r('app.color.brand_bg'))
          .selectedOptionFontColor($r('app.color.brand'));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 线程化渲染（逐版本）：**只对 OpenGLv4（桌面 GL）后端生效** —— 其它后端**灰化提示**（仍可编辑，
      // 值照存；只是启动时不会生效，见 GameLauncher 的 renderer.env 门控）。
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.version_glthread_label'));
          Text($r('app.string.version_glthread_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
        Toggle({ type: ToggleType.Switch, isOn: this.glThreadEnabled(this.editing.id) })
          .opacity(this.glThreadSupported(this.editing) ? 1 : OPACITY_SECONDARY)
          .onChange((isOn: boolean) => {
            this.setGlThread(this.editing.id, isOn);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Divider().padding({ top: LAYOUT_SPACE_SMALL, bottom: LAYOUT_SPACE_SMALL });

      // 操作行：左「打开文件夹」（在系统文件管理器中打开该实例目录） / 右「删除版本」（危险）
      Row({ space: LAYOUT_SPACE }) {
        Button($r('app.string.version_open_folder'))
          .onClick(() => {
            // 目标目录用「已授权目录 URI + 相对子路径」拼出（文件管理器认 URI 命名空间）。
            showInFiles(versionDirUri(this.editingDirUri, this.editing.id), this.context());
          });
        Button($r('app.string.version_delete'))
          .backgroundColor($r('app.color.danger'))
          .enabled(!this.state.gameRunning)
          .onClick(() => this.confirmDelete(this.editing));
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween);
    }
    .padding(LAYOUT_PADDING_SMALL)
    .backgroundColor($r('app.color.brand_bg'))
    .borderRadius(BORDER_RADIUS)
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  build() {
    Column({ space: LAYOUT_SPACE }) {
      Text($r('app.string.versions_title'))
        .fontWeight(FontWeight.Bold);

      if (this.state.selected.length === 0) {
        // 未选目录：无法确定扫描目标
        Text($r('app.string.versions_need_select'));
      } else if (!this.state.isSelectedActivated()) {
        // 已选但未授权：读不了目录，只给授权入口
        Text($r('app.string.versions_need_authorize'));
        Button($r('app.string.common_activate'))
          .onClick(() => this.authorizeSelected());
      } else {
        // 已授权：版本列表 + 刷新按钮
        if (this.state.versions.length === 0) {
          Text($r('app.string.versions_empty'));
        }
        if (!this.state.jreReady) {
          Text(this.state.jreNeedsUpgrade ? $r('app.string.versions_jre_need_upgrade')
            : $r('app.string.versions_jre_not_ready'))
            .opacity(OPACITY_SECONDARY)
            .width('100%');
        }
        if (!this.accountReady()) {
          Text($r('app.string.versions_need_account'))
            .opacity(OPACITY_SECONDARY)
            .width('100%');
        }
        if (this.state.gameRunning) {
          Text($r('app.string.versions_game_running'))
            .opacity(OPACITY_SECONDARY)
            .width('100%');
        }
        // 版本「编辑」面板：渲染在版本列表**上方**（列表之外），同一时刻只展开一个。
        if (this.editingId.length > 0) {
          this.editPanel();
        }
        // 多列布局：版本卡片按断点自适应 1~4 列（宽窗口一行显示多个，提升空间利用率）。
        // 用 GridRow/GridCol（非滚动、高度自适应）而非 WaterFlow：本页在 Index 的外层 Scroll 内，
        // WaterFlow 自身是滚动容器，嵌套会与其抢手势/需固定高，故取栅格方案。
        // 断点参照物必须用 ComponentSize（按本容器宽度）：宽屏时账户区左移为侧栏，主区变窄，
        // 若按 WindowSize（窗口）算会误判为"宽"→ 列数偏多 → 卡片被压到省略号。
        GridRow({
          columns: 12,
          gutter: { x: LAYOUT_SPACE, y: LAYOUT_SPACE },
          breakpoints: { value: ['520vp', '840vp', '1280vp'], reference: BreakpointsReference.ComponentSize }
        }) {
          Repeat<GameVersion>(this.state.versions)
            .each((obj: RepeatItem<GameVersion>) => {
              // span 相对 12 列：窄 1 列 / 中 2 列 / 宽 3 列 / 更宽 4 列
              GridCol({ span: { xs: 12, sm: 6, md: 4, lg: 3 } }) {
                Column({ space: LAYOUT_SPACE_SMALL }) {
                  Row({ space: LAYOUT_SPACE }) {
                    Column() {
                      // 版本 id 独占主行
                      Text(obj.item.id)
                        .width('100%')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis });
                      // 副行：游戏类型（原版 / Fabric / 未知…） · JRE 大版本
                      Row({ space: LAYOUT_SPACE_SMALL }) {
                        Text(this.versionTypeLabel(obj.item));
                        Text($r('app.string.versions_jre_suffix', obj.item.javaVersion));
                      }
                      .width('100%')
                      .opacity(OPACITY_SECONDARY);
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start);
                    // 行内操作：编辑 / 完成（展开该版本的编辑面板）
                    Button(this.editLabel(obj.item.id))
                      .onClick(() => {
                        this.toggleEdit(obj.item);
                      });
                    // 启动：JRE 未就绪 / 无账户 / 游戏已在运行时禁用，避免空启动/重复开
                    Button($r('app.string.common_launch'))
                      .enabled(this.state.jreReady && this.accountReady() && !this.state.gameRunning)
                      .onClick(() => {
                        this.launch(obj.item);
                      });
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center);
                  // 编辑面板已移至版本列表上方（见同文件的 editPanel @Builder），卡片内不再内联展开。
                }
                .padding(LAYOUT_PADDING_SMALL)
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(BORDER_RADIUS)
                .width('100%')
                .alignItems(HorizontalAlign.Start);
              };
            })
            // key 里带上 editingId：Repeat 按同 key 复用行时不重跑 item builder，
            // 展开/收起（以及切换展开目标）必须让该行重建才会重新求值面板的 if。
            .key((v: GameVersion) => `${v.id}:${this.state.versionEpoch}:${this.editingId === v.id ? 'edit' : ''}:${this.rendererBackend(v.id)}`);
        }
        .width('100%')
        .alignItems(ItemAlign.Start);
        Row({ space: LAYOUT_SPACE }) {
          Button($r('app.string.common_refresh'))
            .onClick(() => this.state.refreshVersions());
          // 下载面板开关：与版本行"编辑/完成"同款的显隐按钮
          Button(this.showDownload
            ? $r('app.string.download_close')
            : $r('app.string.common_download'))
            .onClick(() => this.toggleDownload());
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
        // 下载面板：列出远程版本，逐个安装（同一时刻只允许一个安装任务）
        if (this.showDownload) {
          Column({ space: LAYOUT_SPACE }) {
            Column({ space: LAYOUT_SPACE }) {
              Text($r('app.string.download_panel_title'))
                .fontWeight(FontWeight.Bold);
              // 下载源 + 手动拉取：先选源，点「获取版本列表」再拉（海外可先切官方）
              Row({ space: LAYOUT_SPACE }) {
                Select(this.sourceOptions())
                  .selected(this.installer.source === SOURCE_OFFICIAL ? 1 : 0)
                  .value(this.installer.source === SOURCE_OFFICIAL
                    ? $r('app.string.download_source_official')
                    : $r('app.string.download_source_mirror'))
                  .onSelect((index: number) => {
                    this.setDownloadSource(index === 1 ? SOURCE_OFFICIAL : SOURCE_MIRROR);
                  })
                  .selectedOptionBgColor($r('app.color.brand_bg'))
                  .selectedOptionFontColor($r('app.color.brand'))
                  .enabled(this.installer.installingId.length === 0)
                  .layoutWeight(1);
                Button($r('app.string.download_fetch'))
                  .enabled(this.installer.installingId.length === 0
                    && !this.installer.manifestLoading)
                  .onClick(() => this.installer.refreshManifest());
                // 版本类型：正式版 / 快照 / 其他（对已拉清单即时过滤）
                Select(this.typeOptions())
                  .selected(this.selectedTypeIndex())
                  .value(this.typeValue())
                  .onSelect((index: number) => {
                    this.setVersionType(index);
                  })
                  .selectedOptionBgColor($r('app.color.brand_bg'))
                  .selectedOptionFontColor($r('app.color.brand'))
                  .enabled(this.installer.installingId.length === 0)
                  .layoutWeight(1);
              }
              .width('100%')
              .alignItems(VerticalAlign.Center);
            }
            .padding(LAYOUT_PADDING_SMALL)
            .backgroundColor($r('app.color.brand_bg'))
            .borderRadius(BORDER_RADIUS)
            .width('100%')
            .alignItems(HorizontalAlign.Start);
            // 「设置实例名」安装面板（对齐 HMCL：安装时给实例起名，名称即 versions/<名> 目录名）
            if (this.installTargetId.length > 0) {
              Column({ space: LAYOUT_SPACE }) {
                // Confirm & Cancel
                Row({ space: LAYOUT_SPACE }) {
                  Column({ space: LAYOUT_SPACE_SMALL }) {
                    Text($r('app.string.download_instance_settings'));
                    Text($r('app.string.download_instance_for', this.installTargetId))
                      .opacity(OPACITY_SECONDARY);
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1);
                  Button($r('app.string.download_confirm_install'))
                    .enabled(this.canConfirmInstall())
                    .onClick(() => this.confirmInstall());
                  Button($r('app.string.common_cancel'))
                    .onClick(() => this.closeInstallPanel());
                }
                .width('100%');
                Row({ space: LAYOUT_SPACE }) {
                  TextInput({
                    text: this.installName,
                    placeholder: $r('app.string.download_instance_placeholder')
                  })
                    .layoutWeight(1)
                    .onChange((v: string) => {
                      this.installName = v;
                    })
                    .onSubmit(() => this.confirmInstall());
                  // mod loader 选择（原版 / Fabric）
                  Select(this.loaderOptions())
                    .width('auto')
                    .selected(this.loaderIndex())
                    .value(this.loaderValue())
                    .onSelect((index: number) => {
                      this.setLoaderKind(index);
                    })
                    .selectedOptionBgColor($r('app.color.brand_bg'))
                    .selectedOptionFontColor($r('app.color.brand'))
                    .enabled(this.installer.installingId.length === 0);
                }
                .width('100%')
                .alignItems(VerticalAlign.Center);
                if (this.instanceNameErrorKind() === NAME_INVALID) {
                  Text($r('app.string.download_instance_name_invalid'))
                    .opacity(OPACITY_SECONDARY)
                    .width('100%');
                } else if (this.instanceNameErrorKind() === NAME_CONFLICT) {
                  Text($r('app.string.download_instance_name_conflict'))
                    .opacity(OPACITY_SECONDARY)
                    .width('100%');
                }
                // Fabric：loader 子面板（该 loader 的下载源 + loader 版本，均收进下拉省空间）
                if (this.installer.loaderKind === LOADER_KIND_FABRIC) {
                  Row({ space: LAYOUT_SPACE }) {
                    Column({ space: LAYOUT_SPACE_SMALL }) {
                      Text($r('app.string.loader_source_label'));
                      Text($r('app.string.loader_source_hint'))
                        .opacity(OPACITY_SECONDARY);
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start);
                    Select(this.loaderSourceOptions())
                      .width('auto')
                      .selected(this.loaderSourceIndex())
                      .value(this.loaderSourceValue())
                      .onSelect((index: number) => {
                        this.setFabricSource(index);
                      })
                      .selectedOptionBgColor($r('app.color.brand_bg'))
                      .selectedOptionFontColor($r('app.color.brand'))
                      .enabled(this.installer.installingId.length === 0);
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center);
                  if (this.installer.fabricLoadersLoading) {
                    Text($r('app.string.loader_loading'))
                      .opacity(OPACITY_SECONDARY)
                      .width('100%');
                  } else if (this.installer.errorKind === INSTALL_ERR_LOADER) {
                    Text($r('app.string.loader_error'))
                      .opacity(OPACITY_SECONDARY)
                      .width('100%');
                    Button($r('app.string.common_retry'))
                      .onClick(() => this.installer.refreshFabricLoaders(this.installTargetId));
                  } else if (!this.installer.fabricLoadersLoaded) {
                    Text($r('app.string.loader_fetch_hint'))
                      .opacity(OPACITY_SECONDARY)
                      .width('100%');
                  } else if (this.installer.fabricLoaders.length === 0) {
                    Text($r('app.string.loader_empty'))
                      .opacity(OPACITY_SECONDARY)
                      .width('100%');
                  } else {
                    Row({ space: LAYOUT_SPACE }) {
                      Column({ space: LAYOUT_SPACE_SMALL }) {
                        Text($r('app.string.loader_version_label'));
                        Text($r('app.string.loader_version_hint'))
                          .opacity(OPACITY_SECONDARY);
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start);
                      Select(this.loaderVersionOptions())
                        .width('auto')
                        .selected(this.loaderVersionIndex())
                        .value(this.installer.fabricLoader)
                        .onSelect((index: number) => {
                          this.selectFabricLoaderByIndex(index);
                        })
                        .selectedOptionBgColor($r('app.color.brand_bg'))
                        .selectedOptionFontColor($r('app.color.brand'))
                        .enabled(this.installer.installingId.length === 0);
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center);
                  }
                }
              }
              .padding(LAYOUT_PADDING_SMALL)
              .backgroundColor($r('app.color.brand_bg'))
              .borderRadius(BORDER_RADIUS)
              .width('100%')
              .alignItems(HorizontalAlign.Start);
            }
            if (this.installer.manifestLoading) {
              Text($r('app.string.download_loading'))
                .opacity(OPACITY_SECONDARY);
            } else if (this.installer.errorKind === INSTALL_ERR_MANIFEST) {
              Text(this.errorText())
                .opacity(OPACITY_SECONDARY);
              Button($r('app.string.common_retry'))
                .onClick(() => this.installer.refreshManifest());
            } else if (!this.installer.manifestLoaded) {
              Text($r('app.string.download_fetch_hint'))
                .opacity(OPACITY_SECONDARY);
            } else if (this.installer.visible.length === 0) {
              Text($r('app.string.download_empty'))
                .opacity(OPACITY_SECONDARY);
            } else {
              // 安装中 / 出错时的状态行
              if (this.installer.installingId.length > 0) {
                Text(this.phaseText())
                  .opacity(OPACITY_SECONDARY);
                Text($r('app.string.download_progress', this.installer.done, this.installer.total))
                  .opacity(OPACITY_SECONDARY);
                Text(this.installer.current)
                  .opacity(OPACITY_SECONDARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                // 当前文件大小进度（服务端给了 Content-Length 才显示）
                if (this.installer.fileTotal > 0) {
                  Text($r('app.string.download_file_progress',
                    this.fmtSize(this.installer.fileReceived),
                    this.fmtSize(this.installer.fileTotal)))
                    .opacity(OPACITY_SECONDARY);
                }
              } else if (this.installer.errorKind === INSTALL_ERR_INSTALL
                || this.installer.errorKind === INSTALL_ERR_NO_WRITE) {
                Text(this.errorText())
                  .opacity(OPACITY_SECONDARY);
                if (this.installer.errorDetail.length > 0) {
                  Text(this.installer.errorDetail)
                    .opacity(OPACITY_SECONDARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                }
              }
              // 远程版本可能有几百个：用 List + Repeat.virtualScroll 懒加载，只渲染可见区域，
              // 避免一次性铺满整个界面（列表需定高，见 DOWNLOAD_LIST_HEIGHT）。
              // 多列：List.lanes 按可用宽度自适应列数（单卡列宽 [MIN,MAX] vp），宽窗口一行显示多个。
              List({ space: LAYOUT_SPACE }) {
                Repeat<RemoteVersion>(this.installer.visible)
                  .each((obj: RepeatItem<RemoteVersion>) => {
                    ListItem() {
                      Row({ space: LAYOUT_SPACE }) {
                        Column({ space: LAYOUT_SPACE_SMALL }) {
                          Text(obj.item.id)
                            .width('100%')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis });
                          // 副行：type · 发布日期（releaseTime 为完整 ISO 串，只取日期避免多列卡片里被截成省略号）
                          Text(`${obj.item.type}${obj.item.releaseTime.length > 0 ? ' · ' + this.fmtReleaseDate(obj.item.releaseTime) : ''}`)
                            .width('100%')
                            .opacity(OPACITY_SECONDARY)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis });
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start);
                        Button($r('app.string.download_install'))
                          .enabled(this.installer.installingId.length === 0
                            && !this.state.gameRunning)
                          .onClick(() => this.openInstallPanel(obj.item));
                      }
                      .padding(LAYOUT_PADDING_SMALL)
                      .backgroundColor($r('app.color.brand_bg'))
                      .borderRadius(BORDER_RADIUS)
                      .width('100%')
                      .alignItems(VerticalAlign.Center);
                    };
                  })
                  .key((v: RemoteVersion) => v.id)
                  .virtualScroll();
              }
              // 自适应列数 + 列间距（行间距由 List 的 space 控制）；仍保持 Repeat.virtualScroll 懒加载
              .lanes({ minLength: DOWNLOAD_CARD_MIN_W, maxLength: DOWNLOAD_CARD_MAX_W }, LAYOUT_SPACE)
              .height(DOWNLOAD_LIST_HEIGHT)
              .width('100%');
            }

          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
