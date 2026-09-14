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

// Preferences 存储：
// STORE_NAME 是首选项文件实例名（一个文件对应一个 Preferences 实例），
// KEY_DIRS / KEY_SELECTED 是该文件内的两个键，值均为 JSON 字符串（见 GameDirsTools）。
export const STORE_NAME: string = 'meowcraft';
export const KEY_DIRS: string = 'game_dirs';
export const KEY_SELECTED: string = 'selected_dir';
// 高级选项：是否在游戏窗口右下角显示鼠标采样率 overlay（bool）。
export const KEY_SHOW_INPUT_RATE: string = 'show_input_rate';
// 高级选项：启动参数覆盖（0 / 空串 = 自动，用默认）。
export const KEY_CPU_COUNT: string = 'cpu_count';
export const KEY_MAX_HEAP_MB: string = 'max_heap_mb';
// 账户系统：账户列表（JSON 字符串数组）+ 当前选中账户 id。
export const KEY_ACCOUNTS: string = 'accounts';
export const KEY_SELECTED_ACCOUNT: string = 'selected_account';
// 上次启动的游戏（JSON {dir,version,jsonPath}；"继续上次"按钮用；删版本/移除目录时清理）。
export const KEY_LAST_LAUNCH: string = 'last_launch';
// 微软登录：用户自填的 Azure 公有客户端 id（不预置；空 = 微软登录不可用）。
export const KEY_MS_CLIENT_ID: string = 'ms_client_id';
// 版本隔离：已启用隔离的版本 id 列表（JSON 字符串数组；逐版本开关，空数组 = 全部不隔离）。
export const KEY_VERSION_ISOLATION: string = 'version_isolation';
// 逐版本渲染后端覆盖（JSON 数组 [{id,backend}]；backend ∈ auto/openglv4/gl4es）。
export const KEY_RENDERER_OVERRIDES: string = 'renderer_overrides';
// 鼠标滚轮速度（百分比；主进程高级选项写、游戏进程读；100 = 正常）。
export const KEY_SCROLL_SPEED: string = 'scroll_speed';
// 版本下载源（'mirror' / 'official'；下载面板写、安装时读）。
export const KEY_DOWNLOAD_SOURCE: string = 'download_source';
// mod loader 下载源（'mirror' / 'official'；**与版本源独立**；目前仅 Fabric）。
export const KEY_FABRIC_SOURCE: string = 'fabric_source';
// 版本类型过滤（'release' / 'snapshot' / 'other'；下载面板写、安装时读）。
export const KEY_VERSION_TYPE: string = 'version_type';
// 显示缩放：渲染分辨率 = 窗口 / N（N=1 关闭）。UI 层用 1/N 布局 + .scale(N) 放大回满窗。
export const KEY_RENDER_SCALE: string = 'render_scale';
export const RENDER_SCALE_DEFAULT: number = 1;
export const RENDER_SCALE_OPTIONS: number[] = [1, 1.5, 2, 3, 4];

/** 额外渲染环境变量（**实验/调优**）：`K=V`，换行或 `;` 分隔；启动前 setenv（可覆盖内置默认，如 GALLIUM_THREAD/ZINK_*）。 */
export const KEY_RENDER_ENV: string = 'render_env';

/** 额外 JVM 参数（**实验/调优**）：空格/换行分隔，原样追加到 argv。例：`-XX:+UnlockDiagnosticVMOptions -XX:-ImplicitNullChecks`。 */
export const KEY_JVM_ARGS: string = 'jvm_args';

/** 逐版本「线程化渲染」**关闭**列表（JSON 字符串数组；未列入 = 开）。GPU 调用交独立线程（提帧、
 *  加载期略慢）；**仅 OpenGLv4（桌面 GL）后端生效**。见 notes 20-design/glthread-B方案-GL-guard.md。 */
export const KEY_GLTHREAD_OFF: string = 'glthread_off';

// 布局：通用间距与透明度（单位 vp，透明度 0~1）。
// 统一的布局常量保证各组件间距视觉一致，弱化次要文字用 OPACITY_SECONDARY 而不是改字号。
export const LAYOUT_SPACE: number = 8;
export const LAYOUT_SPACE_SMALL: number = 4;
export const LAYOUT_PADDING: number = 12;
export const LAYOUT_PADDING_SMALL: number = 8;
export const OPACITY_SECONDARY: number = 0.6;
export const BORDER_RADIUS: number = 14;
export const BORDER_RADIUS_SMALL: number = 8;
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
