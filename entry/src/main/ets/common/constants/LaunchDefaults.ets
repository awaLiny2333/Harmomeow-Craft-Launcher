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

/**
 * 「工具 JVM 平台伪装前缀」——本仓**任何「另起 JVM」**（安装期工具 JVM / 各子进程 / 将来的其它载体）
 * 的 argv 里都必须紧跟在 `java` 之后、其余 `-D` 之前原样展开本数组。
 *
 * **与游戏路径同源**（同一对 `SPOOF_OS_NAME` / `SPOOF_OS_VERSION`；游戏侧用法见
 * `MinecraftLauncher.buildLaunchArgv` 的「固定 JVM 参数」段）—— 工具 JVM 与游戏 JVM 必须伪装成同一个平台。
 *
 * **缺了它必炸**（2026-09-30 真机 stderr 定案，Forge 1.16.5 夹具）：JDK 8（legacy 套）的
 * `sun.nio.fs.DefaultFileSystemProvider.create()` 按 `os.name` **精确匹配**（`Linux` / `SunOS` /
 * `Darwin` / …），本机真 `os.name` 是 HarmonyOS ⇒ 匹配不上直接 `AssertionError: Platform not recognized`；
 * 该异常发生于**类初始化期**（`FilePermission.<clinit>` → `LauncherHelper.checkAndLoadMain`），连主类都加载不到，
 * JLI 只能退 1（stderr: `A JNI error has occurred`）。现代套（26）对未知 `os.name` 宽容回退 ⇒ **别依赖**这一点。
 * 浅述见本前缀的两处消费点（`VersionInstaller.runForgeProcessors` / `runNeoForgeProcessors` 的注释）。
 */
export const TOOL_JVM_PLATFORM_SPOOF_ARGS: string[] = [
  `-Dos.name=${SPOOF_OS_NAME}`,
  `-Dos.version=${SPOOF_OS_VERSION}`,
];

// ---- 账户（离线玩家名的兜底与占位 token；账户记录本身见 data/AccountsTools.ets） ----
/** 默认离线账户名（无任何账户时的兜底）。 */
export const OFFLINE_USERNAME: string = 'Player';
/** 离线 access token：原版只要求非空、不校验值（UUID 由启动器按名派生）。 */
export const OFFLINE_TOKEN: string = '0';

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

// ---- 逐实例「Java 环境」覆盖（与渲染后端同构：auto = 交给 JavaPolicy 按 MC 版本 × loader 选） ----
/** 逐实例 Java 环境覆盖值：`auto`（推荐）。其余取值 = [`JavaRuntime.id`](../data/JavaRuntime.ets)。 */
export const JAVA_ENV_AUTO: string = 'auto';
// 逐版本「渲染后端」下拉的第四档：让 MC 去试 **VulkanBackend**（26.2+ 才有）。
// 它**不改 GL 侧的任何东西**（lib/env 仍是桌面 GL），只让启动器额外给 MC 传游戏参数
// `--graphicsBackend vulkan`；MC 的候选列表因此变成 {VulkanBackend, GlBackend} ⇒ Vulkan 失败照样回退 GL。
// 见方案文 §5.5（后端选择）与 §7.5（开关与回退）。
export const RENDERER_BACKEND_VULKAN: string = 'vulkan';
// 逐版本「渲染后端」第五档：**GL3 核心后端**（MC 1.17–1.21.x 走 gl4es fork 的 core 后端 → 原生 GLES 3.2；
// 用于没有系统桌面 GL 的设备，2in1 上亦作可选档）。复用 gl4es 的 lib/env（桥据此走 GLES 分支），
// 额外注入 `MEOW_GL3=1` 以启用 core 后端。方案见 notes/20-design/render/GL33到GLES32-后端-方案.md。
export const RENDERER_BACKEND_GL4ES3: string = 'gl4es3';
export const VULKAN_LIB: string = 'libvulkan.so';
// 26.2 新增 NativeLibrariesBootstrap：一旦探测到 Vulkan loader，就会强载 lwjgl-shaderc/spvc/vma
// （本工程不随包这些模块）。**未选 Vulkan 时**把 LWJGL 的 Vulkan 库名指向这个不存在的名字 → 探测
// 失败 → 跳过 Vulkan 组；本工程渲染走 GL/GLES（见 RendererPolicy：≥1.17 桌面 GL，≤1.16 gl4es），
// 不依赖 LWJGL 的 Vulkan 绑定。
export const VULKAN_LIB_DISABLED: string = 'libmeow-no-vulkan.so';
// 自研 Vulkan loader shim（随包 native，见 meowvulkan.c 头注释）：转发到真 loader，并做必要修正
// （补扩展名 / 补 feature 位 / createDevice 剔名 / KHR→core 名字映射 + 提交与 WSI 的翻译）。
// 【F75 2026-09-18 env-cleanup】选「渲染后端 = Vulkan」时，启动器直接把
// `-Dorg.lwjgl.vulkan.libname` 指向本库 —— "选哪个库"本身就是参数，**不再有 MEOW_VK_SHIM=1 注入**；
// shim 一经加载即默认挂钩（g_hooks=1）。逃生口：在「额外渲染环境变量」里写 `MEOW_VK_SHIM=0`（或空）
// = 纯透传，行为与系统 loader 一致。回退阶梯见
// notes/20-design/render/Vulkan后端-绕过可行性-调研与方案.md §7.5 / §13。
export const VULKAN_LIB_SHIM: string = 'libmeowvulkan.so';

// ---- 启动器标识（品牌：Harmomeow Craft Launcher，HarmonyOS + meow）----
export const LAUNCHER_NAME: string = 'Harmomeow Craft';
export const LAUNCHER_VERSION: string = '1.0.0';
export const CLIENT_MOD_NAME: string = 'Harmomeow Craft';

// ---- staging（启动支持 jar 载体）----
/** 内容令牌：meowcraft_extras.tar.gz 内容变更（换 jar / 打补丁）时递增，强制重抽缓存。
 *  2026-10-01：tar 摘除 `launcher.jar` 与 `gson-for-launcher.jar`（MeowLauncher 退役）⇒ 升令牌。 */
export const EXTRAS_VERSION: string = '20261001-drop-meow-launcher';
// ---- 随包 ASM（方案 A「随包」）----
// Forge 1.19.4 声明的 ASM 9.7.1 读不懂 JDK 26 的类文件（major 70）⇒ modlauncher 10.0.8 的
// `ClassTransformer.transform → computeHierarchyFromFile` 抛 `Unsupported class file major version 70`。
// 修法：**不新增 JRE 档**，改为在启动期为需要的实例把 ASM 指向随包的 9.9.1（见
// `MinecraftLauncher` 的 `needsAsmOverride` / `rewriteAsmList`）。
/** 随包 ASM 版本（5 件同版；模块名在 9.7.1→9.9.1 间不变，故 `--add-modules ALL-MODULE-PATH` 解析不受影响）。 */
export const ASM_BUNDLED_VERSION: string = '9.9.1';
/** 随包 ASM 在**实例 staging 目录下的子目录名**（`<cache>/mc-cp/<实例>/asm9/`）。
 *  **必须放在子目录**：平铺模式（vanilla/Fabric/legacy）的 `-cp "<dir>/*"` 通配不递归，平铺进去
 *  会让我们的 ASM 混进它们的 classpath、可能与 Fabric 自己的 ASM 互相遮蔽。 */
export const ASM_STAGE_SUBDIR: string = 'asm9';
/** 随包 ASM 的 5 个成员名（落在 `ASM_STAGE_SUBDIR` 下；`org.ow2.asm` 全家）。
 *  `asm-<v>.jar` 是 `Opcodes` 的提供者（FML 找的正是它），其余 4 件是它的兄弟模块。 */
export const EXPECTED_ASM_JARS: string[] = [
  `asm-${ASM_BUNDLED_VERSION}.jar`,
  `asm-analysis-${ASM_BUNDLED_VERSION}.jar`,
  `asm-commons-${ASM_BUNDLED_VERSION}.jar`,
  `asm-tree-${ASM_BUNDLED_VERSION}.jar`,
  `asm-util-${ASM_BUNDLED_VERSION}.jar`,
];
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
