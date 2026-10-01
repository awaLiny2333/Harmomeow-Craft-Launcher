/**
 * 外部契约常量：必须与配置文件 / 外部系统（jar、MC manifest、外部账户文件）一致，
 * **禁止改名**。仅集中跨文件、易错的值；单点使用的 Java `-D` 属性键保持就地内联
 * （属性名本身就是文档，集中反而增加间接层）。
 */

// ---- 页面 / Ability / 进程（与 module.json5、main_pages.json 一致）----
export const GAME_ROUTE: string = 'pages/GameWindow';
export const GAME_ABILITY: string = 'GameAbility';
export const ENTRY_MODULE: string = 'entry';
export const GAME_PROCESS_SUFFIX: string = ':game';
/** NeoForge 安装期执行 processor 的无窗 ability 与其独立进程名（见 notes 安装期JVM载体-调研.md §8.3）。 */
export const NEO_INSTALL_ABILITY: string = 'NeoInstallAbility';
export const NEO_INSTALL_PROCESS_SUFFIX: string = ':neoinstall';

/**
 * 「需要真 maven 树 classpath」的主类形态 —— Forge ≥1.13 三代（含 NeoForge，其主类同为
 * `BootstrapLauncher`）。命中者**不得**用平铺 `<dir>/*` 承载 classpath。
 *
 * 为什么是**必需**而不是"更规范"（字节码定案，2026-09-30）：这一族 FML 定位自己的主制品是**按自身
 * jar 的物理位置**推 maven 根 —— `LibraryFinder.findLibsPath()` 用
 * `ClassLoader.getResource("org/objectweb/asm/Opcodes.class")` 取到 **ASM jar 的路径**，再连续
 * `getParent()` × 6 次当作 `libraries` 根，拼 `net/minecraftforge/forge/<ver>/forge-<ver>-universal.jar`
 * 后只做 `Files.exists` 校验（`FMLCommonLaunchHandler.validatePaths:104`）。
 * ASM 在真 maven 树里正好是 `libraries/org/ow2/asm/asm/<v>/asm-<v>.jar`（上溯 6 级 = `libraries`）；
 * 一旦 classpath 是平铺目录的 `<dir>/*` 通配，ASM 就命中**平铺目录里那份**，上溯 6 级得到的是
 * **应用数据根** ⇒ 校验失败 ⇒ 1.16.5 实测 fatal `Missing forge!`（jar 其实存在）。
 * 该代际 json 里**没有**任何可指向该 jar 的参数，FML 也不读 `-D` 属性 ⇒ **换任何深度的平铺目录**
 * 都只会把"路径基"错成另一个值，只有真树能修。
 *
 * 判据用**主类（形态）**而非 loader 名 / MC 版本号字符串比较：这族实例可能是薄 `inheritsFrom`
 * （`detectLoader` 认不出），主类却始终稳定。
 */
export const REAL_CLASSPATH_MAIN_CLASSES: string[] = [
  'cpw.mods.modlauncher.Launcher',                 // Forge 1.13–1.16.5
  'cpw.mods.bootstraplauncher.BootstrapLauncher',  // Forge 1.17–1.20.1 / NeoForge 1.20.2+
  'net.minecraftforge.bootstrap.ForgeBootstrap',   // Forge 1.20.6+
  // NeoForge 新世代（1.21.11 / 26.x 实测主类）。**必须显式列出**而不是"交给 `loader === neoforge`
  // 兜底"：兜底依赖 `detectLoader` 识别成功（它看 `net.neoforged.fancymodloader:*` 库与 `neoforge`
  // 补丁 id），而形态判据的立论就是"不依赖 loader 识别是否正确"（这族实例可能是薄 `inheritsFrom`/
  // 被人工改写的清单）⇒ 主类清单自己要是完备的，兜底只作为 NeoForge 的额外保险。
  'net.neoforged.fml.startup.Client'
];

/*
 * 以下契约不可用常量表达（对象字面量键 / 外部文件字段），仅登记为文档：
 * - MC 版本 json 宏名：auth_player_name / auth_uuid / auth_access_token / auth_xuid /
 *   user_type / clientid / version_name / version_type / game_directory / assets_root /
 *   assets_index_name / classpath / natives_directory / launcher_name / launcher_version
 * - Java 系统属性键（-D）：MEOWCRAFT_HOME / MEOWCRAFT_GAME_DIR / meowcraft.path.* / glfwstub.* /
 *   Server_Ip / os.name / os.version / cpu.name / user.* /
 *   org.lwjgl.* / jna.* / oshi.* / log4j2.formatMsgNoLookups 等
 * - 随包 extras 成员名：lwjgl-<gen>.jar（平铺）/ asm9/*.jar（子目录）——见 LaunchDefaults
 */
