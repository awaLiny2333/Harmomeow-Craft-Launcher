import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buildLaunchArgv, readVersionId } from './MinecraftLauncher';
import { startJvm } from '../state/JvmLauncher';
import { stageClasspathDir } from './ClasspathStager';
import { Account, AccountsTools, ACCOUNT_TYPE_MICROSOFT } from './AccountsTools';
import { readAppGlobalSettings } from './AppSettings';
import { readInstanceSettings, ensureInstanceLogsDir } from './InstanceSettings';
import { MEOW_HOME_DIR, MC_RUN_DIR_PREFIX, NATIVES_DIR, jreHomeDir,
  hspLibsDir, versionDir } from '../constants/Paths';
import { WINDOW_DEFAULT_W, WINDOW_DEFAULT_H, RENDERER_ENV } from '../constants/LaunchDefaults';
import { rendererForVersion, guardNeedsSync, supportsVulkanBackend } from './RendererPolicy';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameLauncher';

/**
 * 完整启动流程（与游戏窗 UI 解耦）：stage classpath → 校验账户 → 组装 argv → 启动 JVM。
 * 调用方（GameWindow）负责先注入 surface；本函数只做"起 JVM"。
 * 账户为必需前置：无选中账户直接拒绝（绝不静默造号），UI 层已按此门控启动按钮。
 */
/**
 * 日志前**打码凭据**：argv 里会带 `--accessToken <微软 access token>`（NeoForge 由 ArkTS 直接组
 * game 参数；原版/Fabric 则由 Java 侧读账户文件），整条打进 hilog 就等于把令牌写进日志。
 * 这里只保留前 4 位，其余以 `(masked)` 代替（保留长度可读性不做，避免泄露长度）。
 */
function maskCredentials(cmd: string): string {
  const key = '--accessToken ';
  let out = cmd;
  let idx = out.indexOf(key);
  while (idx >= 0) {
    const start = idx + key.length;
    const space = out.indexOf(' ', start);
    const end = space < 0 ? out.length : space;
    const token = out.substring(start, end);
    if (token.length > 4) {
      out = out.substring(0, start) + token.substring(0, 4) + '(masked)' + out.substring(end);
    }
    idx = out.indexOf(key, start);
  }
  return out;
}

export async function launchGame(ctx: common.UIAbilityContext, gameRoot: string, jsonPath: string,
  versionId: string, width: number, height: number): Promise<void> {
  const cpDir = stageClasspathDir(ctx, gameRoot, jsonPath, versionId);
  if (cpDir.length === 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'launch abort: classpath stage failed for %{public}s', versionId);
    return;
  }
  const runDir = `${ctx.cacheDir}/${MC_RUN_DIR_PREFIX}${versionId}`;
  for (const d of [runDir, `${runDir}/${NATIVES_DIR}`]) {
    try {
      fileIo.mkdirSync(d);
    } catch (e) {
      // 已存在则忽略
    }
  }
  // 账户沙箱 home（filesDir 内，可写）。
  const meowHome = `${ctx.filesDir}/${MEOW_HOME_DIR}`;
  // 高级选项覆盖（读应用级 `app-settings.json` 的 global 段，全局唯一）：0/空 = 自动。
  const settings = readAppGlobalSettings(ctx);
  // 必须已选中账户：无账号不允许启动（UI 已门控；此处兜底拒绝，绝不静默造号）。
  const accounts = new AccountsTools(ctx);
  const account: Account | null = accounts.selected();
  if (account === null) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'launch abort: no account selected');
    return;
  }
  let launchAccount: Account = account;
  if (account.type === ACCOUNT_TYPE_MICROSOFT) {
    // 微软账户：启动前确保 token 新鲜（过期则用 refresh_token 续期）；
    // 续不动 → 与主进程门控一致：中止启动，不拿坏 token 硬启。
    try {
      launchAccount = await accounts.ensureMicrosoftFresh(account);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'launch abort: microsoft refresh failed: %{public}s',
        (e as Error).message);
      return;
    }
  }
  accounts.writeAccountFile(meowHome, launchAccount);
  // 逐版本设置（隔离 / 渲染后端 / 线程化渲染）从**实例目录内**的 .hmmcraft 文件读
  // （不是 Preferences）：随实例目录跨机迁移，且按"目录 + 实例名"区分，同名实例不串。
  const instance = readInstanceSettings(gameRoot, versionId);
  // 版本隔离（逐版本开关）：隔离时游戏运行目录 = <gameRoot>/versions/<id>，
  // 存档/选项/日志/资源包落版本目录，与其它版本互不干扰；assets/libraries 仍是共享根（不随隔离变）。
  const isolated = instance.isolation;
  const gameDir = isolated ? versionDir(gameRoot, versionId) : gameRoot;
  // 落盘物证统一到**实例**的 `.hmmcraft/logs`（游戏目录 = 进程 cwd 保持干净，铁律：不污染硬盘）：
  // **即使未开隔离也按 `versions/<id>` 归位**（各实例不混、hs_err 不互相覆盖）；建不出目录则退沙箱，
  // 绝不退回游戏目录（否则 JVM 又会把 hs_err 写到 cwd）。见 ensureInstanceLogsDir 的注释。
  let logsDir = ensureInstanceLogsDir(versionDir(gameRoot, versionId));
  if (logsDir.length === 0) {
    logsDir = `${runDir}-logs`;
    try {
      fileIo.mkdirSync(logsDir, true);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'fallback logs dir unavailable: %{public}s', logsDir);
      logsDir = '';
    }
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'version %{public}s isolation=%{public}s',
    versionId, isolated ? 'on' : 'off');
  const cpuChip = readCpuChip();
  // 渲染后端按**版本 json 的内部 id**（真 MC 版本号）选（≤1.16 → gl4es/GLES；≥1.17 → 桌面 GL）。
  // 注意：versionId 现在是实例名（目录名，玩家可任取），不能拿它判版本。
  const mcVersion = readVersionId(jsonPath);
  const renderer = rendererForVersion(mcVersion, instance.rendererBackend);
  // 【临时诊断，查完即删】把 Vulkan 开关这条链上的四个值一次暴露出来：盘上的后端值、选择函数给出的
  // graphicsBackend、以及版本把关的结果。任何一环不对，CMD_TAIL 里就不会出现 --graphicsBackend。
  hilog.info(LOG_DOMAIN, LOG_TAG,
    'vkdiag mcVersion=%{public}s backendFromDisk=%{public}s choiceGb=%{public}s gate=%{public}s',
    mcVersion, instance.rendererBackend, renderer.graphicsBackend,
    supportsVulkanBackend(mcVersion) ? 'true' : 'false');
  // 【F74】选了 Vulkan 档（且该 MC 版本支持）时，除了游戏参数 `--graphicsBackend vulkan`，还要把
  // `MEOW_VK_SHIM=1` 送进游戏进程环境（走下方既有"额外渲染环境变量"通道）。libmeowvulkan.so 的
  // 加载器 shim 读的是 **getenv**（不是 -D），所以不能做成 JVM 属性。auto/GL 档不注入 ⇒ 与今天一致。
  const vulkanBackendSelected =
    renderer.graphicsBackend.length > 0 && supportsVulkanBackend(mcVersion);
  const argv = buildLaunchArgv({
    gameRoot: gameRoot,
    gameDir: gameDir,
    jsonPath: jsonPath,
    versionId: versionId,
    classpath: `${cpDir}/*`,
    classpathDir: cpDir,
    runDir: runDir,
    nativeLibsDir: hspLibsDir(ctx.bundleCodeDir), // 自足 JRE 模块 el1（隔离）
    craftLibsDir: hspLibsDir(ctx.bundleCodeDir), // 桥已并入同模块
    meowcraftLaunch: true,
    // NeoForge 由 ArkTS 直接组 game 参数（不经 launcher.jar）⇒ 账户三件套必须传真值。
    authUuid: launchAccount.uuid,
    authAccessToken: launchAccount.accessToken !== undefined ? launchAccount.accessToken : '',
    authXuid: launchAccount.xuid !== undefined ? launchAccount.xuid : '',
    meowHomeDir: meowHome,
    width: width > 0 ? width : WINDOW_DEFAULT_W,
    height: height > 0 ? height : WINDOW_DEFAULT_H,
    activeProcessorCount: settings.cpuCount,
    maxHeapMb: settings.maxHeapMb,
    playerName: launchAccount.name,
    cpuChip: cpuChip,
    rendererLib: renderer.lib,
    // 选了 Vulkan 档时才让 MC 去试（26.2+ 才认这个游戏参数；失败仍回退 GL）。见 RendererPolicy。
    graphicsBackend: vulkanBackendSelected ? renderer.graphicsBackend : undefined,
    jvmArgs: settings.jvmArgs,
    logsDir: logsDir,
  });
  if (argv.length === 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'launch abort: empty argv for %{public}s', versionId);
    return;
  }
  const java = `${jreHomeDir(ctx.filesDir)}/bin/java`;
  const fullCmd = [java, ...argv].join(' ');
  // 先打码再截断；两处长度基准都必须是**打码后**的字符串（否则 token 越长、尾部日志越短，
  // 真 JWT 那种数百字符的 token 会让 CMD_TAIL 变成空串——独立复核发现）。
  const maskedCmd = maskCredentials(fullCmd);
  hilog.info(LOG_DOMAIN, LOG_TAG, 'CMD: %{public}s', maskedCmd.substring(0, 3000));
  hilog.info(LOG_DOMAIN, LOG_TAG, 'CMD_TAIL: %{public}s',
    maskedCmd.substring(Math.max(0, maskedCmd.length - 800)));
  // 线程化渲染（glthread）：**逐版本开关（默认开，可在「编辑版本」里关）**；且**仅现代渲染路径
  // （OpenGLv4/桌面 GL）**有效——gl4es/legacy 无此机制（桥对它们本就置 GALLIUM_THREAD=0）。
  // 拼在用户「额外渲染环境变量」**之前** → 用户可显式覆盖。
  const glthread = instance.glThreadEnabled && renderer.env === RENDERER_ENV;
  // Mesa glthread 的 UAF **只对 26.x 实测会崩**；≤1.21.x 从不因它崩，而它们（尤其 1.21.10 主菜单
  // ~2800 次/秒的小图上传）会被「每次同步」拖垮 → 对 ≤1.21.x 关掉守卫的同步（守卫退化为纯透传，
  // glthread 收益照拿）。见 notes 20-design/lwjgl3-并代可行性.md / glthread-B方案-GL-guard.md §2。
  const guardSyncNone = glthread && !guardNeedsSync(mcVersion);
  const userRenderEnv = settings.renderEnv;
  // ★能力屏蔽（通用接口，2026-09-16）：**一份策略 → 两个执行点**。
  // 策略是运行时数据：内置默认（见下），或用户在「额外渲染环境变量」里显式给的
  // `MEOW_MASK_EXTENSIONS=GL_A,GL_B`（用户优先；显式写空 = 关闭屏蔽）。
  //   · Mesa 层  `MESA_EXTENSION_OVERRIDE=-GL_A -GL_B` —— 进程级；决定驱动是否真去创建该能力。
  //   · LWJGL 层 `MEOW_MASK_EXTENSIONS=GL_A,GL_B` —— LWJGL 的能力构造器读它（见
  //     `tools/lwjgl/deltas/overlay/org/lwjgl/opengl/RendererInit.java` 的 filterCapabilities，
  //     由 `gen_glcap.py` 第 5 条改写注入到 `GLCapabilities`）⇒ 模组读到的就是"没有该能力"。
  // 为什么两层都要：**LWJGL 层**让模组走它**设计好的**降级路径（不依赖它捕获异常）；**Mesa 层**保证
  // 任何绕过 LWJGL 直接查 GL 的消费者也拿不到那条会崩的创建路径（只会得到干净的 GL 错误）。
  // 内置默认：现代渲染路径 + 芯片含 Kirin ⇒ 屏蔽 `GL_ARB_compute_shader`（本机 Maleoon 的 Bisheng
  // 编译器在编译**合法** compute SPIR-V 时空指针崩，4 次复现；见 notes
  // `20-design/render/1.21.1-崩溃-两条链与随包规避.md` §1）。代价 = 本机丢掉 GPU 驱动渲染（纯性能损失）。
  // ⚠️ 实测依据与机制更正（2026-09-16，3/3 复现）：**GL 层**（guard 过滤扩展表）到不了 LWJGL ✗；
  // **Mesa 层**有效 ✓，但它只是把"驱动崩溃"变成"干净的 GL 错误"——LWJGL 的能力集**仍看得到**该扩展，
  // Flywheel 照常去编译 compute 程序，全靠它自己捕获失败后退回 instancing（`fell back from …`）。
  // ⇒ 只做 Mesa 层等于**依赖模组的错误处理**；LWJGL 层那一半才让"门槛真的为假"。两层合起来才完备。
  // 拼接在用户 env **之前** ⇒ 用户可显式覆盖 ✓。
  const defaultMask: string[] = (/Kirin/i.test(cpuChip) && renderer.env === RENDERER_ENV)
    // ★只屏蔽 compute 这一个能力。2026-09-16 曾临时把 `OpenGL46` 也写进来（因为 Flywheel 的
    // `GlCompat.isIndirectSupported()` 有 `if (CAPABILITIES.OpenGL46) return true;` 版本组直通），
    // 但那是**治标**：真正的病根是我们 overlay 曾删掉官方 234 处
    // `if (!ext.contains("...")) return false;` 守卫，导致版本组/扩展在 Mesa 派发表上"恒真" ✗。
    // 根因已修（`gen_glcap.py` 第 2 条改为**运行时条件守卫** + `RendererInit.strictCapabilities()`：
    // 现代路径保留守卫 ⇒ 版本组诚实；gl4es 兼容上下文才放行）⇒ 这里不再需要钉假版本组 ✓。
    // ★逐版本开关「**屏蔽** GL_ARB_compute_shader」（默认**开** = 屏蔽该能力，与 `MEOW_MASK_EXTENSIONS`
    //   的"设/不设"对齐）：用户关掉 = 不屏蔽 ⇒ 模组可用 compute，但本机驱动不稳**可能直接崩** ⇒ 知情承担。
    //   ⚠️ 它只决定**默认清单**：用户若在「额外渲染环境变量」写了 `MEOW_MASK_EXTENSIONS`，下一行会**整份
    //   覆盖**它 ⇒ 开关**影响不到**用户在 env 区设置的任何屏蔽 ✓。将来若默认清单里还有别的能力，
    //   这里要改成"只去掉 compute"（别整体置空 ✗）。
    ? (instance.computeShaderMasked ? ['GL_ARB_compute_shader'] : []) : [];
  // ⚠️ 若将来某设备又出现"门控绕过了本清单"，可在「额外渲染环境变量」里写
  // `MEOW_MASK_EXTENSIONS=GL_X,OpenGL46` 临时兜底（无需重编）✓。
  const maskOverride = parseMaskOverride(userRenderEnv);
  const capMask = maskOverride === null ? defaultMask : maskOverride;
  // Mesa 只认 `GL_*` 扩展名；版本组（`OpenGLxx`）不进 `MESA_EXTENSION_OVERRIDE`。
  const mesaMask = capMask.filter((n: string) => n.startsWith('GL_'));
  const maskEnv = capMask.length > 0
    ? (mesaMask.length > 0
      ? `MESA_EXTENSION_OVERRIDE=${mesaMask.map((n: string) => `-${n}`).join(' ')}\n`
      : '')
      + `MEOW_MASK_EXTENSIONS=${capMask.join(',')}`
    : '';
  const renderEnv = `GALLIUM_THREAD=${glthread ? '1' : '0'}`
    + (guardSyncNone ? '\nMEOW_GUARD_SYNC=none' : '')
    + (maskEnv.length > 0 ? `\n${maskEnv}` : '')
    // 【F74】Vulkan 档自动注入 shim 门控；拼在用户 env 之前 ⇒ 用户可显式覆盖。
    + (vulkanBackendSelected ? '\nMEOW_VK_SHIM=1' : '')
    + `\n${userRenderEnv}`;
  // 用户「额外渲染环境变量」里若**显式**写 none，会让守卫对"本需要同步的版本"也纯透传（fail-open）——
  // 不改用户语义（用户优先），但记一条 WARN 便于实机排障（见 notes 00-current/运行时环境变量.md 回滚阶梯）。
  if (glthread && guardNeedsSync(mcVersion) && userForcedGuardSyncNone(userRenderEnv)) {
    hilog.warn(LOG_DOMAIN, LOG_TAG,
      'extra render env forces MEOW_GUARD_SYNC=none on a version that needs the guard sync (UAF risk)');
  }
  hilog.info(LOG_DOMAIN, LOG_TAG,
    'glthread=%{public}s guardSync=%{public}s renderer=%{public}s capMask=%{public}s computeShader=%{public}s',
    glthread ? 'on' : 'off', guardSyncNone ? 'none(auto)' : 'per-call', renderer.env,
    capMask.length > 0 ? `on(${capMask.join(',')})` : 'off',
    instance.computeShaderMasked ? 'on(default)' : 'off(user)');
  await startJvm(ctx, [java, ...argv], renderer.lib, renderer.env, renderer.glProfile, renderEnv);
}

/** 用户「额外渲染环境变量」里是否要求 `MEOW_GUARD_SYNC=none`（格式 `K=V`，换行或 `;` 分隔；容忍 `=` 两侧空格）。 */
function userForcedGuardSyncNone(env: string): boolean {
  for (const part of env.split(/[\n;]/)) {
    const kv = part.trim().split('=');
    if (kv.length === 2 && kv[0].trim() === 'MEOW_GUARD_SYNC' && kv[1].trim() === 'none') {
      return true;
    }
  }
  return false;
}

/** 读用户「额外渲染环境变量」里的 `MEOW_MASK_EXTENSIONS`（**最后一个生效**，与 native `setenv(…,1)`
 *  的覆盖语义一致）。返回 `null` = 用户没写（用内置默认）；返回 `[]` = 用户显式写空（关闭屏蔽）。 */
function parseMaskOverride(env: string): string[] | null {
  let result: string[] | null = null;
  for (const part of env.split(/[\n\r;]+/)) {
    const kv = part.trim().split('=');
    if (kv.length < 2 || kv[0].trim() !== 'MEOW_MASK_EXTENSIONS') {
      continue;
    }
    result = kv.slice(1).join('=').split(/[\s,]+/).filter((n: string) => n.length > 0);
  }
  return result;
}

/** 读取设备 CPU 芯片型号（deviceInfo.chipType，API 21+）；失败/空返回空串。 */
function readCpuChip(): string {
  try {
    const chip: string = deviceInfo.chipType;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'device chipType=%{public}s', chip.length > 0 ? chip : '(empty)');
    return chip;
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'chipType unavailable: %{public}s', (e as Error).message);
    return '';
  }
}
