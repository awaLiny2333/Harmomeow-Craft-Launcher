import { common } from '@kit.AbilityKit';
import { installRuntime, JavaEnvInfo } from '../common/data/JavaEnvScanner';
import { LauncherState, getLauncherState } from '../common/state/LauncherState';
import { LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY } from '../common/constants/Constants';
import { jreHomeDir } from '../common/constants/Paths';

/**
 * Java 环境区块（与 GameVersionsView 平级，由 Index 挂载）。
 *
 * 职责：展示"可用 Java 运行时"的状态——有哪些 JRE、是否已解压就绪、
 * 版本号；对未就绪的 JRE 提供"解压"按钮（走 installRuntime = 既有的 native installJre）。
 * 探测结果放**共享态** `LauncherState.jreEnvs`（版本区**不再**据此禁用"启动"——那是启动前的检查，
 * 见 GameLauncher.checkLaunchJre 与 LaunchJrePrompt）。
 *
 * 注意：Repeat 的 key 必须携带 installed（可变状态），否则解压前后 key 不变、
 * item 又非 @Observed 类，ArkUI 不会重渲染该行（表现为"刷新没反应、重启才见"）。
 */
@ComponentV2
export struct JavaEnvView {
  /** 共享应用状态（`jreEnvs` = 探测结果；启动路径上在别处解压时也会刷新它）。 */
  @Local state: LauncherState = getLauncherState();

  /** 正在解压的 JRE id（避免重复点击）。 */
  @Local installingId: string = '';

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /** 重新探测 Java 环境状态（只读）→ 共享态 jreEnvs。 */
  refresh(): void {
    this.state.refreshJreEnvs(this.context().filesDir);
  }

  /** 解压指定 JRE（native 同步解压，约 1~2s，期间按钮转"解压中"防重入）。 */
  install(env: JavaEnvInfo): void {
    if (this.installingId.length > 0 || env.installed) {
      return;
    }
    this.installingId = env.id;
    installRuntime(this.context(), env.id);
    this.refresh();
    this.installingId = '';
  }

  /** 行副行文本：<版本>  <java.home 完整路径>（版本未装时省略，主行已显 id）。 */
  private rowSubText(env: JavaEnvInfo): string {
    const ver = env.version.length > 0 ? `${env.version}  ` : '';
    return `${ver}${jreHomeDir(this.context().filesDir, env.id)}`;
  }

  build() {
    Column({ space: LAYOUT_SPACE }) {
      Text($r('app.string.java_env_title'))
        .fontWeight(FontWeight.Bold);

      if (this.state.jreEnvs.length === 0) {
        Text($r('app.string.java_env_empty'));
      }

      Repeat<JavaEnvInfo>(this.state.jreEnvs)
        .each((obj: RepeatItem<JavaEnvInfo>) => {
          Row({ space: LAYOUT_SPACE }) {
            Column({ space: LAYOUT_SPACE_SMALL }) {
              // 主行：JRE id + 就绪状态
              Row({ space: LAYOUT_SPACE }) {
                Text(obj.item.id)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(obj.item.installed ? $r('app.string.java_env_ready')
                  : (obj.item.needsUpgrade ? $r('app.string.java_env_need_upgrade')
                     : $r('app.string.java_env_not_extracted')))
                  .opacity(OPACITY_SECONDARY)
                  .maxLines(1);
              }
              .width('100%');
              // 副行：须升级时展示「令牌 旧 → 新」（防用户迷惑）；否则 <版本> + java.home 路径
              if (obj.item.needsUpgrade) {
                Text($r('app.string.java_env_token_fmt', obj.item.extractedToken, obj.item.requiredToken))
                  .opacity(OPACITY_SECONDARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              } else {
                Text(this.rowSubText(obj.item))
                  .opacity(OPACITY_SECONDARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            // 行内操作：未就绪可解压；就绪无动作（后续可放"启动验证"等）
            if (!obj.item.installed) {
              Button(this.installingId === obj.item.id ? $r('app.string.java_env_extracting')
                : (obj.item.needsUpgrade ? $r('app.string.java_env_upgrade')
                   : $r('app.string.java_env_extract')))
                .enabled(this.installingId.length === 0)
                .onClick(() => this.install(obj.item));
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center);
        })
        // key 携带 installed/needsUpgrade：状态变化会重建该行，确保刷新立即生效
        .key((e: JavaEnvInfo) => `${e.id}-${e.installed}-${e.needsUpgrade}`);

      Button($r('app.string.common_refresh'))
        .onClick(() => this.refresh());
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
