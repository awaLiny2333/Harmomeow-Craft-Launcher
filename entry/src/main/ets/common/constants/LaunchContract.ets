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
