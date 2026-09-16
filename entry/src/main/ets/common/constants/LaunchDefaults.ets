/**
 * 启动默认值 / 平台伪装值 / 离线账户占位 / staging 版本（ArkTS 侧唯一来源）。
 * 渲染后端常量与 native `meowjrebridge.cpp` 同值（交叉引用注释）。
 */

// ---- 窗口默认几何 ----
export const WINDOW_DEFAULT_W: number = 1280;
export const WINDOW_DEFAULT_H: number = 720;
export const WINDOW_DEFAULT_X: number = 120;
export const WINDOW_DEFAULT_Y: number = 80;

// ---- JVM 默认 / 平台伪装 ----
export const SPOOF_OS_NAME: string = 'Linux';
export const SPOOF_OS_VERSION: string = '6.6';
export const SPOOF_CPU_NAME: string = 'harmonyos';
export const LOCALE_LANGUAGE: string = 'zh';
export const LOCALE_COUNTRY: string = 'CN';
export const LOCALE_TIMEZONE: string = 'Asia/Shanghai';
/** 版本 rules 平台匹配（鸿蒙视作 linux + aarch64）。 */
export const RULE_OS_NAME: string = 'linux';
export const RULE_OS_ARCH: string = 'aarch64';

// ---- 账户（对齐 launcher.jar Account 的账户文件字段；JSON 键名为契约，勿改名） ----
/** 默认离线账户名（无任何账户时的兜底）。 */
export const OFFLINE_USERNAME: string = 'Player';
/** 离线 access token：原版只要求非空、不校验值（UUID 由 launcher 按名派生）。 */
export const OFFLINE_TOKEN: string = '0';
/** 账户文件目录名（<meow-home>/accounts/<name>.json）。 */
export const ACCOUNTS_DIR: string = 'accounts';

// ---- 渲染后端（与 native meowjrebridge.cpp / egl_gl.c 的 env 取值同源） ----
// 现代版（≥1.17）：**GL guard**（`libmeowglguard.so`，B1 纯透传）→ 内部转发到系统桌面 GL
// `libGLv4.so`（Mesa Zink），env `openglv4`。guard 是后续给少数"客户端内存入口"补同步拷贝、
// 规避 Mesa glthread UAF 的落点（见 notes 20-design/glthread-B方案-GL-guard.md）。
// **回滚 = 把 RENDERER_LIB 改回 RENDERER_LIB_REAL_GL**。
export const RENDERER_LIB: string = 'libmeowglguard.so';
export const RENDERER_LIB_REAL_GL: string = 'libGLv4.so';
export const RENDERER_ENV: string = 'openglv4';
// 老版（≤1.16，固定管线）：自编 gl4es（桌面 GL→GLES 翻译层），env `gl4es`。
// gl4es 跑在原生 GLES 上，由桥建 GLES context，绕开 Zink 的 compat 固定管线缺陷。
export const RENDERER_LIB_GL4ES: string = 'libgl4es.so';
export const RENDERER_ENV_GL4ES: string = 'gl4es';
/** 逐版本"渲染后端"覆盖值：推荐（按 MC 版本自动）/ 桌面 GL / gl4es。 */
export const RENDERER_AUTO: string = 'auto';
export const VULKAN_LIB: string = 'libvulkan.so';
// 26.2 新增 NativeLibrariesBootstrap：一旦探测到 Vulkan loader，就会强载 lwjgl-shaderc/spvc/vma
// （本工程不随包这些模块）。把 LWJGL 的 Vulkan 库名指向一个不存在的名字 → 探测失败 → 跳过 Vulkan 组；
// 本工程渲染走 GL/GLES（见 RendererPolicy：≥1.17 桌面 GL，≤1.16 gl4es），不依赖 LWJGL 的 Vulkan 绑定。
export const VULKAN_LIB_DISABLED: string = 'libmeow-no-vulkan.so';

// ---- 启动器标识（品牌：Harmomeow Craft Launcher，HarmonyOS + meow）----
export const LAUNCHER_NAME: string = 'Harmomeow Craft';
export const LAUNCHER_VERSION: string = '1.0.0';
export const CLIENT_MOD_NAME: string = 'Harmomeow Craft';

// ---- staging（启动支持 jar 载体）----
/** 内容令牌：meowcraft_extras.tar.gz 内容变更（换 jar / 打补丁）时递增，强制重抽缓存。 */
export const EXTRAS_VERSION: string = '20260916-lwjgl-review';
/** 平铺目录必须保留的公共 jar（其余 .jar 视为残留删除；lwjgl 世代 jar 按版本另行保留）。 */
export const EXPECTED_EXTRA_JARS: string[] = ['launcher.jar', 'gson-for-launcher.jar'];
// ---- LWJGL（**现代只随包一代**：3.4.3 服务全部 LWJGL3 版本；legacy ≤1.12.2 仍走 MC 的 LWJGL2）----
// 命名约定与 tools/lwjgl 一致：jar = `lwjgl-<gen>.jar`；native = `liblwjgl_<gen 去点>{,_opengl,_stb}.so`
// （由 tools/lwjgl/install_natives.sh 铺进扁平目录）。世代选择表见 MinecraftLauncher.lwjglGeneration。
// 注：3.4.3 之所以能服务 1.13–1.21.x，靠我们 overlay 里的 **3.4.x 兼容 shim**
// （struct mallocStack ×3 / STBImageResize.nstbir_resize_uint8 / tinyfd_messageBox）——
// 见 tools/lwjgl/README.md「3.4.x compat shims」与 notes 20-design/lwjgl3-并代可行性.md。
export const LWJGL_JAR_PREFIX: string = 'lwjgl-';
/** bundled 库名映射器类：把 native 名映射成"世代号紧跟基名"的形式（与 legacy 的无后缀 `liblwjgl.so` 共存）。
 *  实现见 tools/lwjgl/deltas/overlay/org/lwjgl/system/MeowBundledNameMapper.java。 */
export const LWJGL_NAME_MAPPER: string = 'org.lwjgl.system.MeowBundledNameMapper';
/** 唯一 LWJGL3 世代：3.4.3（服务 MC 1.13.x–1.21.x 与 ≥1.22 / 26.x）。 */
export const LWJGL_GEN_343: string = '3.4.3';
/** 我们随包的 LWJGL 世代 jar 名（= `meowcraft_extras.tar.gz` 里那一代合并 jar）。
 *  classpath 平铺目录里必须**只有一个** `org.lwjgl` 提供者 → `ClasspathStager` 用它精确裁决
 *  保留/删除（`dropOtherLwjglJar` + 形态断言），并防误删 legacy 的 `lwjgl-2.9.x.jar`。 */
export const LWJGL_GEN_JARS: string[] = [
  `${LWJGL_JAR_PREFIX}${LWJGL_GEN_343}.jar`,
];
