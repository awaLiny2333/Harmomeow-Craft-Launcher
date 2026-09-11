import { GameDirsView } from '../components/GameDirsView';
import { GameVersionsView } from '../components/GameVersionsView';
import { AccountView } from '../components/AccountView';
import { JavaEnvView } from '../components/JavaEnvView';
import { AdvancedOptionsView } from '../components/AdvancedOptionsView';
import { LAYOUT_PADDING, LAYOUT_SPACE } from '../common/constants/Constants';

/**
 * 应用入口页（@Entry + 状态管理 V2）。
 *
 * 设计原则：页面壳保持极薄——只负责整体布局与组合区块，不放业务逻辑。
 * 区块：
 * 1. GameDirsView   （游戏目录管理）
 * 2. GameVersionsView（版本列表 + 启动）
 * 3. JavaEnvView    （Java 环境状态：内置 JRE 与解压就绪情况）
 * 4. AdvancedOptionsView（高级选项：调试/进阶开关）
 * 目录区与版本区通过共享 LauncherState（AppStorageV2）协同。
 * 后续新增区块按同模式在 components/ 下新建后挂载于此。
 */
@Entry
@ComponentV2
struct Index {
  build() {
    Scroll() {
      Column({ space: LAYOUT_SPACE }) {
        GameDirsView()
        Divider()
        GameVersionsView()
        Divider()
        AccountView()
        Divider()
        JavaEnvView()
        Divider()
        AdvancedOptionsView()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .padding(LAYOUT_PADDING)
  }
}
