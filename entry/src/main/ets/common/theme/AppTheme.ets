import { CustomColors, CustomTheme } from '@kit.ArkUI';

/**
 * 应用内主题：把 ArkUI 默认（鸿蒙蓝）的品牌/强调色统一改为本应用品牌色。
 * 色值在 `resources/base|dark/element/color.json` 的 `brand`（`$r('app.color.brand')`；换色只改 resource），
 * 经 `ThemeControl.setDefaultTheme`（EntryAbility loadContent 回调）一次性生效，全局组件受益。
 *
 * token 影响面（官方文档）：`brand` → TextInput/Search；`fontEmphasize` → Button/Select/各类弹窗；
 * `warning` → Button/Badge/AlertDialog；`interactiveHover` → MenuItem/Select 等悬停/高亮（API 26+）。
 */
class MeowColors implements CustomColors {
  brand: ResourceColor = $r('app.color.brand');
  fontEmphasize: ResourceColor = $r('app.color.brand');
  warning: ResourceColor = $r('app.color.brand');
  interactiveHover: ResourceColor = $r('app.color.brand');
}

class MeowTheme implements CustomTheme {
  colors: MeowColors = new MeowColors();
}

/** 全局单例主题（启动时注入）。 */
export const MEOW_THEME: CustomTheme = new MeowTheme();
