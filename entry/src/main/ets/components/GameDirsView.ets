import { common } from '@kit.AbilityKit';
import { GameDirsTools, GameDir } from '../common/data/GameDirsTools';
import {
  pickDirectory, authorizeDirectory, persistDirectory, activateDirectory,
  revokeDirectory, showInFiles
} from '../common/access/FileAccess';
import { LauncherState, getLauncherState } from '../common/state/LauncherState';
import { LAYOUT_PADDING_SMALL, BORDER_RADIUS, LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY } from '../common/constants/Constants';

/**
 * 游戏目录管理区块（页面级组件，由 Index 挂载）。
 *
 * 职责：
 * 1. 展示用户已记住的游戏目录列表（昵称 + 完整 URI）；
 * 2. 下拉 Select 切换"当前要用的目录"（写入共享 LauncherState.selected，供版本区使用）；
 * 3. 每个目录提供：改名（点击昵称进入行内编辑）、授权（激活）、在系统文件管理器中打开（已激活时）、移除。
 *
 * 状态归属（与 GameVersionsView 共享，见 common/state/LauncherState.ets）：
 * - dirs / selected / activated 放在 LauncherState（@ObservedV2），通过 AppStorageV2
 *   与应用内其它组件共享同一实例；@Trace 字段改动同步刷新所有 connect 组件。
 * - editingUri / editingName 是本组件私有的行内编辑 UI 状态，无需跨组件，留在 @Local。
 * - 授权状态（activated）是运行时数组；但授权本身经 fileShare **持久化**——首次"激活"后
 *   落库，App 重启自动 activatePermission，无需再次 Picker（不支持该能力的设备退化为每次手动）。
 */
@ComponentV2
export struct GameDirsView {
  /** 共享应用状态（与版本列表区等组件同实例）。 */
  @Local state: LauncherState = getLauncherState();

  /** 正在编辑昵称的目录 URI，空串表示当前不在编辑态。 */
  @Local editingUri: string = '';

  /** 编辑中的昵称输入值（TextInput 双向绑定目标）。 */
  @Local editingName: string = '';

  /** 惰性初始化的数据层实例。ArkTS 不支持确定赋值断言，故用可空 + getter 首次创建。 */
  private tools: GameDirsTools | null = null;

  /** 从组件获取 UIAbilityContext（Picker 与数据层都需要）。 */
  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 惰性 getter：首次访问时创建 GameDirsTools 并缓存，之后直接复用。 */
  private getTools(): GameDirsTools {
    let s = this.tools;
    if (s === null) {
      s = new GameDirsTools(this.context());
      this.tools = s;
    }
    return s;
  }

  /**
   * 组件即将挂载：加载已记住的目录与上次选中项到共享状态。
   * 上次选中的目录若仍存在则恢复，否则回退到第一个（兜底目录被删的情况）。
   */
  aboutToAppear(): void {
    const st = this.state;
    st.dirs = this.getTools().list();
    const remembered = this.getTools().selected();
    st.selected = st.dirs.some((d) => d.uri === remembered)
      ? remembered
      : (st.dirs.length > 0 ? st.dirs[0].uri : '');
    // 尝试激活已持久化的授权（重启后免再次 Picker）。
    this.autoActivate();
    // 校验"上次启动"记录：其目录若已不在列表则清除（目录被移除等）。
    st.refreshLastLaunch(this.context());
  }

  /**
   * 添加文件夹：拉起普通目录选择 Picker。
   * 选到目录后入库、刷新共享列表并自动选中它（新的当前目录）。
   */
  async addDir(): Promise<void> {
    const picked = await pickDirectory(this.context());
    if (picked === null) {
      return;
    }
    const st = this.state;
    this.getTools().add(picked);
    st.dirs = this.getTools().list();
    // 普通 Picker 已授予临时读授权 → 本会话即可用（置"已激活"）；
    // 再尝试持久化，使重启后免再次授权（失败则维持临时授权，用户可手动"激活"）。
    if (!st.activated.includes(picked)) {
      st.activated = st.activated.concat(picked);
    }
    await persistDirectory(picked);
    this.select(picked);
  }

  /**
   * 激活（授权）指定目录：拉起"授权 Picker"。
   * 授权 Picker 会把用户锁定在 defaultFilePathUri 指定的目录上（2in1/PC 生效），
   * 授权成功后记录到共享 activated 集合，并触发一次版本扫描（此时才可读目录）。
   */
  async activate(uri: string): Promise<void> {
    const ok = await authorizeDirectory(this.context(), uri);
    if (!ok) {
      return;
    }
    // 持久化授权：重启后无需再次 Picker（设备不支持则退化为临时授权）。
    await persistDirectory(uri);
    const st = this.state;
    if (!st.activated.includes(uri)) {
      st.activated = st.activated.concat(uri);
      st.refreshVersions();
      // 手动激活成功后同样补校验「继续上次」（与 autoActivate 的二次刷新对齐）：
      // 否则"外部删版本 → 手动激活"后按钮残留。
      st.refreshLastLaunch(this.context());
    }
  }

  /** 启动时激活已持久化的目录授权：成功则置"已激活"，失败维持"未激活"（用户可手动激活）。 */
  private async autoActivate(): Promise<void> {
    const st = this.state;
    const okUris: string[] = [];
    for (const dir of st.dirs) {
      if (await activateDirectory(dir.uri)) {
        okUris.push(dir.uri);
      }
    }
    if (okUris.length === 0) {
      return;
    }
    const next: string[] = st.activated.slice();
    for (const uri of okUris) {
      if (!next.includes(uri)) {
        next.push(uri);
      }
    }
    st.activated = next;
    st.refreshVersions();
    // 授权完成后再次校验"上次启动"（此时才可安全判断版本 json 是否还在）。
    st.refreshLastLaunch(this.context());
  }

  /** 移除目录入口：二次确认（与「删除版本」同款弹窗；移除只解除记忆，不动文件）后再执行。 */
  private confirmRemove(dir: GameDir): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.game_dirs_remove_title'),
      message: $r('app.string.game_dirs_remove_message', dir.name),
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {
        },
        fontColor: $r('sys.color.white'),
        backgroundColor: $r('app.color.brand')
      },
      secondaryButton: {
        value: $r('app.string.common_remove'),
        action: () => {
          this.removeDir(dir.uri);
        },
        fontColor: $r('sys.color.white'),
        backgroundColor: $r('app.color.danger')
      }
    });
  }

  /**
   * 移除目录：删除持久化记录、清理共享列表与授权标记；
   * 若移除的是当前选中目录，则回退到第一个；
   * 若正在编辑该目录昵称，同时退出编辑态。
   */
  async removeDir(uri: string): Promise<void> {
    this.getTools().remove(uri);
    const st = this.state;
    st.dirs = this.getTools().list();
    st.activated = st.activated.filter((d) => d !== uri);
    if (st.selected === uri) {
      this.select(st.dirs.length > 0 ? st.dirs[0].uri : '');
    }
    if (this.editingUri === uri) {
      this.editingUri = '';
    }
    // 目录被移除 → 清掉指向它的"上次启动"记录（refreshLastLaunch 校验目录是否仍在列表）。
    st.refreshLastLaunch(this.context());
    // 撤销该目录的持久化授权（best-effort）。
    await revokeDirectory(uri);
  }

  /** 进入行内编辑态：记录目标目录并把当前昵称填入输入框。 */
  startEdit(dir: GameDir): void {
    this.editingUri = dir.uri;
    this.editingName = dir.name;
  }

  /**
   * 确认改名：先直接改共享列表中对应 GameDir 的 name（@Trace 触发对应行 UI 刷新），
   * 再调用 store 持久化。随后退出编辑态。
   */
  confirmEdit(): void {
    if (this.editingUri.length > 0) {
      const target = this.state.dirs.find((d) => d.uri === this.editingUri);
      if (target) {
        target.name = this.editingName;
      }
      this.getTools().rename(this.editingUri, this.editingName);
    }
    this.editingUri = '';
  }

  /** 取消编辑：只退出编辑态，丢弃输入（store 与 UI 均不改动）。 */
  cancelEdit(): void {
    this.editingUri = '';
  }

  /** 选中某个目录：写入共享状态、持久化记忆（选中 ≠ 授权），并触发版本扫描。 */
  select(uri: string): void {
    this.state.selected = uri;
    this.getTools().setSelected(uri);
    this.state.refreshVersions();
  }

  build() {
    Column({ space: LAYOUT_SPACE }) {
      Text($r('app.string.game_dirs_title'))
        .fontWeight(FontWeight.Bold);

      // 目录下拉（选择当前要用的目录）+「添加文件夹」并排，节约竖向空间
      Row({ space: LAYOUT_SPACE }) {
        if (this.state.dirs.length === 0) {
          Text($r('app.string.game_dirs_empty'))
            .layoutWeight(1);
        } else {
          // 下拉唯一用途：选择「当前要用的目录」，选中项写入共享 state 并持久化
          Select(this.state.dirs.map((d): SelectOption => ({ value: d.name })))
            .selected(this.state.dirs.findIndex((d) => d.uri === this.state.selected))
            .value(this.state.selected.length > 0 ? (this.state.dirs.find((d) => d.uri === this.state.selected)?.name ?? '') : $r('app.string.game_dirs_select_hint'))
            .onSelect((index: number) => {
              this.select(this.state.dirs[index].uri);
            })
            // Select 选项高亮不受主题 token 管，显式指定选中项底色/字色
            .selectedOptionBgColor($r('app.color.brand_bg'))
            .selectedOptionFontColor($r('app.color.brand'))
            .layoutWeight(1);
        }
        Button($r('app.string.game_dirs_add'))
          .onClick(() => this.addDir());
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Repeat<GameDir>(this.state.dirs)
        .each((obj: RepeatItem<GameDir>) => {
          Row({ space: LAYOUT_SPACE }) {
            if (this.editingUri === obj.item.uri) {
              // 行内编辑态：输入框（回车确认）+ 确定 / 取消按钮
              TextInput({ text: this.editingName })
                .onChange((v: string) => this.editingName = v)
                .onSubmit(() => this.confirmEdit())
                .layoutWeight(1);
              Button($r('app.string.common_confirm'))
                .onClick(() => this.confirmEdit());
              Button($r('app.string.common_cancel'))
                .onClick(() => this.cancelEdit());
            } else {
              // 常态展示：昵称（点击改名）+ 完整路径（弱化显示）
              Column({ space: LAYOUT_SPACE_SMALL }) {
                Text(obj.item.name)
                  .onClick(() => this.startEdit(obj.item));
                Text(obj.item.uri)
                  .opacity(OPACITY_SECONDARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start);
            }
            // 已激活：显示「打开文件夹」按钮（在系统文件管理器中打开该目录）；
            // 未激活：提示文字 + 「激活」按钮（已激活无需再授权）。
            if (this.state.activated.includes(obj.item.uri)) {
              Button($r('app.string.game_dirs_open_folder'))
                .onClick(() => showInFiles(obj.item.uri, this.context()));
            } else {
              Text($r('app.string.game_dirs_inactive'));
              Button($r('app.string.common_activate'))
                .onClick(() => this.activate(obj.item.uri));
            }
            Button($r('app.string.common_remove'))
              .onClick(() => this.confirmRemove(obj.item));
          }
          .padding(LAYOUT_PADDING_SMALL)
          .backgroundColor($r('app.color.brand_bg'))
          .borderRadius(BORDER_RADIUS)
          .width('100%')
          .alignItems(VerticalAlign.Center);
        })
        .key((dir: GameDir) => dir.uri);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
