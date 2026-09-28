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

// ---- 自研启动器 Java 类名（launcher.jar 内，契约：净室 meow.launcher）----
export const MEOW_CLASS_LOADER: string = 'meow.launcher.MeowClassLoader';
export const MEOW_MAIN_CLASS: string = 'meow.launcher.MeowLauncher';

/**
 * launchwrapper 的主类（≤1.12.2 的 Forge / LiteLoader 等走它）。
 * 用途：① 是否把自研 system classloader 补给这类实例；② 是否把 launchwrapper **摘出平铺 `-cp`**。
 * 机理：`net.minecraft.launchwrapper.Launch.<init>` 里有 `(URLClassLoader) getClassLoader()` 强转，
 * 而 JDK 9+ 的 `AppClassLoader` 不再是 `URLClassLoader`。二者缺一不可 ——
 * 若 launchwrapper 仍在平铺目录里，app classloader 会**先命中**（父优先委托）⇒ 强转仍崩。
 * 2026-09-28 真机取证（两次）：Forge 1.12.2 在随包 JRE 26 上正是死在这一句（见 notes `Forge支持-改动方案.md` §10 R1）。
 */
export const LAUNCHWRAPPER_MAIN_CLASS: string = 'net.minecraft.launchwrapper.Launch';

/**
 * 「启动器族」的 maven 路径片段：这些制品**必须交给自研 system classloader（MeowClassLoader）加载**，
 * **不能留在平铺 `-cp` 里** —— 否则 app classloader 会抢先定义它们，而它看不到同族的其它类。
 *
 * - `/net/minecraft/launchwrapper/`：launchwrapper 本体（`Launch` / `LaunchClassLoader` / `ITweaker`）。
 * - `/net/minecraftforge/forge/`、`/net/minecraftforge/fmlloader/`：FML 本体 —— 它的类 implements
 *   `ITweaker` ⇒ 若由 app classloader 定义，它就解析不到 launchwrapper 的 `ITweaker`。
 *
 * 2026-09-28 真机两次取证：① 只换系统 CL 不够（app classloader 父优先先命中 `Launch` ⇒ `ClassCastException`）；
 * ② 只摘 launchwrapper 也不够（FML universal 仍在平铺 ⇒ 定义 `FMLTweaker` 时 `NoClassDefFoundError: ITweaker`）。
 * **静态核对**（同一轮，扫 53 个在册 jar 的常量池）：**只有这两个族**引用 `net/minecraft/launchwrapper`
 * ⇒ 摘这两个族是充分的。见 notes `Forge支持-改动方案.md` §10 R1。
 */
export const LOADER_FAMILY_PATH_SEGMENTS: string[] = [
  '/net/minecraft/launchwrapper/',
  '/net/minecraftforge/forge/',
  '/net/minecraftforge/fmlloader/'
];

/*
 * 以下契约不可用常量表达（对象字面量键 / 外部文件字段），仅登记为文档：
 * - 外部账户 JSON 键：accessToken / clientToken / profileId / username / xuid
 * - MC 版本 json 宏名：auth_player_name / auth_uuid / auth_access_token / auth_xuid /
 *   user_type / clientid / version_name / version_type / game_directory / assets_root /
 *   assets_index_name / classpath / natives_directory / launcher_name / launcher_version
 * - Java 系统属性键（-D）：MEOWCRAFT_HOME / MEOWCRAFT_GAME_DIR / meowcraft.path.* / glfwstub.* /
 *   cacio.managed.screensize / Server_Ip / os.name / os.version / cpu.name / user.* /
 *   org.lwjgl.* / jna.* / oshi.* / log4j2.formatMsgNoLookups 等
 * - 随包 jar 成员名：lwjgl.jar / launcher.jar / gson-for-launcher.jar（gson 已 shade 到 meow.gson）
 */
