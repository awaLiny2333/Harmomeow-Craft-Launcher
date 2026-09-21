/**
 * 全局常量集中定义（按分类）。
 *
 * 铁律：禁止在业务代码中散落 magic string / magic number；
 * 所有有含义的值必须在这里命名定义后引用，便于统一修改与协作理解。
 */

// 日志：统一 domain（0x0001），各文件/组件自用私有 LOG_TAG 区分来源。
// 能力（Ability）文件也从这里取 LOG_DOMAIN，避免各处手写不一致。
export const LOG_DOMAIN: number = 0x0001;

// 路由：loadContent 使用的页面路径。路径与 main_pages.json 中注册的页面一一对应，
// 修改页面结构时需同步此处与资源文件。
export const ROUTE_INDEX: string = 'pages/Index';

// 显示缩放：渲染分辨率 = 窗口 / N（N=1 关闭）。UI 层用 1/N 布局 + .scale(N) 放大回满窗。
export const RENDER_SCALE_DEFAULT: number = 1;
export const RENDER_SCALE_OPTIONS: number[] = [1, 1.5, 2, 3, 4];

// 布局：通用间距与透明度（单位 vp，透明度 0~1）。
// 统一的布局常量保证各组件间距视觉一致，弱化次要文字用 OPACITY_SECONDARY 而不是改字号。
export const LAYOUT_SPACE: number = 8;
export const LAYOUT_SPACE_SMALL: number = 4;
export const LAYOUT_PADDING: number = 12;
export const LAYOUT_PADDING_SMALL: number = 8;
export const OPACITY_SECONDARY: number = 0.6;
export const BORDER_RADIUS: number = 14;
export const BORDER_RADIUS_SMALL: number = 8;
export const WINDOW_DECOR_HEIGHT: number = 50;
export const IMMERSIVE_STATE: boolean = true;
// 极细外边距（1vp）：修 TextInput layoutWeight(1) 的轻微布局抖动（账户区输入框用）。
export const LAYOUT_MARGIN_HAIRLINE: number = 1;

// 删除版本的临时残留目录（放在游戏根下、`versions/` 之外；同文件系统可原子 rename）。
// 放在 versions/ 之外 → 用户可任意命名实例（含 *removed），不会与残留冲突，扫描器也无需按后缀排除。
export const MEOW_TRASH_DIR: string = '.meow-trash';

// 页面响应式断点：窗口宽度 ≥ 此值（vp）时，账户区左移为独立侧栏（形成左右分栏）。
export const LAYOUT_WIDE_MIN_W: number = 640;
// 宽屏分栏时账户侧栏宽度（vp）。
export const LAYOUT_ACCOUNT_PANEL_W: number = 320;

// 采样率 overlay 底色（半透明黑，保证游戏画面上可读）。
export const OVERLAY_BG: string = '#80000000';

// 鼠标滚轮：ArkUI 的 AxisEvent 轴值单位是 vp，一个物理滚轮"格"约这么多 vp；
// 归一化到 GLFW/桌面约定（一格 ≈ ±1），避免 MC 里"一滚飞走"。按手感微调此值即可。
export const SCROLL_VP_PER_NOTCH: number = 15;
// 滚轮速度百分比的默认值（100 = 正常，即乘 1.0）。
export const SCROLL_SPEED_DEFAULT_PERCENT: number = 100;

// 下载面板远程版本列表高度（vp）：List 需定高才能用 Repeat.virtualScroll 懒加载，
// 否则长列表（几百个版本）会一次性铺满界面并在加载瞬间卡顿。
export const DOWNLOAD_LIST_HEIGHT: number = 360;
// 下载列表卡片栅格：单卡列宽范围（vp）——List.lanes 据此自适应一行显示几列（宽窗更多列）。
export const DOWNLOAD_CARD_MIN_W: number = 280;
export const DOWNLOAD_CARD_MAX_W: number = 420;

// 游戏启动兜底（ms）：正常在首次 onSurfaceChanged 拿到真实客户区尺寸后再启动；
// 若该回调迟迟不来，等这么久后按默认尺寸启动，避免"永不启动"。
export const LAUNCH_FALLBACK_MS: number = 1500;
