import { JRE_DATA_TOKEN_FILE, JRE_DATA_TOKEN, JRE_DATA_TOKEN_LEGACY,
  JRE_ID_MEOW, JRE_ID_MEOW_LEGACY, HSP_MEOWJRE, HSP_MEOWJRE_LEGACY,
  jreHomeDir, hspLibsDirFor } from '../constants/Paths';

/**
 * 一套随包 JRE 的**静态描述**（多版本共存的单一事实源）。
 *
 * 为什么是"对象"而不是散参数：一套 JRE 的**四个值必须彼此一致** ——
 *   ① id（= 安装目录名 = rawfile 前缀 = 令牌文件名所在目录）
 *   ② HSP 模块名（= el1 native libs 目录；`OHOS_DL_DIR` 指向它）
 *   ③ 数据令牌（数据内容标识；改数据必须升）
 *   ④ 就绪标记（**数据布局事实**：模块化套是 `lib/modules`；OpenJDK 8 是 `lib/rt.jar`）
 * 散着传必然某处漏传或错配（"数据用 A、el1 用 B"）；绑成一个对象后，
 * 启动链只认"解析好的那一个"，**不可能**错配。路径派生也由它自己提供（见 home/libsDir/…）。
 *
 * 加第三套 JRE 的步骤（**无需改任何逻辑**）：① `tools/<recipe>` 产出 el1 + 数据 tar；
 * ② 新建版本中性的 `type:shared` 模块（`libs/<name>/`，四处接线见 build-profile/oh-package）；
 * ③ 本表加一行 + `Paths.ets` 加字符串 + native `jre_launcher.h::kJreSpecs` 同值加一行；
 * ④ 数据 tar 以 `<id>.tar.gz` 放进 rawfile；⑤ 若需要新规则，在 `JavaPolicy` 的**表**里加一行。
 */
export class JavaRuntime {
  /** JRE id：安装目录名 + rawfile 前缀（`<id>.tar.gz`）；**版本无关**。 */
  readonly id: string;
  /** 承载本套 JRE el1 native libs 的 HSP 模块名（也是 `OHOS_DL_DIR` 的来源）。 */
  readonly hspModule: string;
  /** 数据门令牌（`<home>/meow_jre_data` 的内容必须等于它）。 */
  readonly dataToken: string;
  /** 就绪标记（相对 `<home>`；**随数据布局不同**：`lib/modules` vs `lib/rt.jar`）。 */
  readonly readyMarker: string;
  /** 该 JRE 的 Java 主版本（26 / 8 …）。**选择策略只读这个**（不读版本号字符串）。 */
  readonly javaMajor: number;

  constructor(id: string, hspModule: string, dataToken: string, readyMarker: string, javaMajor: number) {
    this.id = id;
    this.hspModule = hspModule;
    this.dataToken = dataToken;
    this.readyMarker = readyMarker;
    this.javaMajor = javaMajor;
  }

  /** `<filesDir>/meow-jres/<id>`（java.home = 数据目录，喂 `OHOS_JAVA_HOME`）。 */
  home(filesDir: string): string {
    return jreHomeDir(filesDir, this.id);
  }

  /** `<bundleCodeDir>/<module>/libs/arm64`（el1；喂 `OHOS_DL_DIR` 与 `LD_LIBRARY_PATH`）。 */
  libsDir(bundleCodeDir: string): string {
    return hspLibsDirFor(bundleCodeDir, this.hspModule);
  }

  /** `<home>/bin/java`（就绪判定与传给桥的 argv[0]）。 */
  javaBin(filesDir: string): string {
    return `${this.home(filesDir)}/bin/java`;
  }

  /** `<home>/<就绪标记>`（如 `lib/modules` / `lib/rt.jar`）。 */
  readyPath(filesDir: string): string {
    return `${this.home(filesDir)}/${this.readyMarker}`;
  }

  /** `<home>/meow_jre_data`（数据令牌文件）。 */
  tokenPath(filesDir: string): string {
    return `${this.home(filesDir)}/${JRE_DATA_TOKEN_FILE}`;
  }

  /**
   * `<home>/lib/patch/jdk.zipfs`（`jdk.zipfs` best-effort-chmod 补丁类目录）。
   * **只现代套有**；调用方一律用**存在性检查**决定是否加 `--patch-module`
   * （见 `GameLauncher`），这样"有没有这个补丁"是**数据事实**而不是版本分支。
   */
  zipfsPatchDir(filesDir: string): string {
    return `${this.home(filesDir)}/lib/patch/jdk.zipfs`;
  }
}

/** 现代套（现役）：OpenJDK 26 数据（jlink 瘦身，模块化 ⇒ 标记 `lib/modules`）。 */
const RUNTIME_MEOW: JavaRuntime =
  new JavaRuntime(JRE_ID_MEOW, HSP_MEOWJRE, JRE_DATA_TOKEN, 'lib/modules', 26);
/** legacy 套：OpenJDK 8u504 数据（rt.jar 布局 ⇒ 标记 `lib/rt.jar`）。 */
const RUNTIME_MEOW_LEGACY: JavaRuntime =
  new JavaRuntime(JRE_ID_MEOW_LEGACY, HSP_MEOWJRE_LEGACY, JRE_DATA_TOKEN_LEGACY, 'lib/rt.jar', 8);

/**
 * 随包 JRE 清单（**顺序即 UI 展示顺序**）。新增一套 = 这里加一行（见类注释的步骤）。
 * 注意顺序：把"默认/推荐"放前面，UI 的兜底与日志更直观。
 */
export const BUNDLED_RUNTIMES: JavaRuntime[] = [RUNTIME_MEOW, RUNTIME_MEOW_LEGACY];

/** 按 id 查表；未知 id → undefined（调用方负责兜底与告警，**绝不猜**）。 */
export function runtimeById(id: string): JavaRuntime | undefined {
  for (const rt of BUNDLED_RUNTIMES) {
    if (rt.id === id) {
      return rt;
    }
  }
  return undefined;
}

/** 默认（现代）套；用于无法解析实例上下文时的兜底，保持与单 JRE 时代同一行为。 */
export function defaultRuntime(): JavaRuntime {
  return RUNTIME_MEOW;
}
