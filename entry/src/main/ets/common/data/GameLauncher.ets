import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buildLaunchArgv, readVersionId } from './MinecraftLauncher';
import { startJvm } from '../state/JvmLauncher';
import { stageClasspathDir } from './ClasspathStager';
import { Account, AccountsTools, ACCOUNT_TYPE_MICROSOFT } from './AccountsTools';
import { SettingsTools } from './SettingsTools';
import { MEOW_HOME_DIR, MC_RUN_DIR_PREFIX, NATIVES_DIR, jreHomeDir,
  hspLibsDir, versionDir } from '../constants/Paths';
import { WINDOW_DEFAULT_W, WINDOW_DEFAULT_H, RENDERER_ENV } from '../constants/LaunchDefaults';
import { rendererForVersion, guardNeedsSync } from './RendererPolicy';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameLauncher';

/**
 * 完整启动流程（与游戏窗 UI 解耦）：stage classpath → 校验账户 → 组装 argv → 启动 JVM。
 * 调用方（GameWindow）负责先注入 surface；本函数只做"起 JVM"。
 * 账户为必需前置：无选中账户直接拒绝（绝不静默造号），UI 层已按此门控启动按钮。
 */
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
  // 高级选项覆盖（主进程写 Preferences，本进程读）：0/空 = 自动。
  const settings = new SettingsTools(ctx);
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
  // 版本隔离（逐版本开关，跨进程从 Preferences 读）：隔离时游戏运行目录 = <gameRoot>/versions/<id>，
  // 存档/选项/日志/资源包落版本目录，与其它版本互不干扰；assets/libraries 仍是共享根（不随隔离变）。
  const isolated = settings.versionIsolated(versionId);
  const gameDir = isolated ? versionDir(gameRoot, versionId) : gameRoot;
  hilog.info(LOG_DOMAIN, LOG_TAG, 'version %{public}s isolation=%{public}s',
    versionId, isolated ? 'on' : 'off');
  const cpuChip = readCpuChip();
  // 渲染后端按**版本 json 的内部 id**（真 MC 版本号）选（≤1.16 → gl4es/GLES；≥1.17 → 桌面 GL）。
  // 注意：versionId 现在是实例名（目录名，玩家可任取），不能拿它判版本。
  const mcVersion = readVersionId(jsonPath);
  const renderer = rendererForVersion(mcVersion, settings.rendererOverride(versionId));
  const argv = buildLaunchArgv({
    gameRoot: gameRoot,
    gameDir: gameDir,
    jsonPath: jsonPath,
    versionId: versionId,
    classpath: `${cpDir}/*`,
    runDir: runDir,
    nativeLibsDir: hspLibsDir(ctx.bundleCodeDir), // 自足 JRE 模块 el1（隔离）
    craftLibsDir: hspLibsDir(ctx.bundleCodeDir), // 桥已并入同模块
    meowcraftLaunch: true,
    meowHomeDir: meowHome,
    width: width > 0 ? width : WINDOW_DEFAULT_W,
    height: height > 0 ? height : WINDOW_DEFAULT_H,
    activeProcessorCount: settings.cpuCount(),
    maxHeapMb: settings.maxHeapMb(),
    playerName: launchAccount.name,
    cpuChip: cpuChip,
    rendererLib: renderer.lib,
    jvmArgs: settings.jvmArgs(),
  });
  if (argv.length === 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'launch abort: empty argv for %{public}s', versionId);
    return;
  }
  const java = `${jreHomeDir(ctx.filesDir)}/bin/java`;
  const fullCmd = [java, ...argv].join(' ');
  hilog.info(LOG_DOMAIN, LOG_TAG, 'CMD: %{public}s', fullCmd.substring(0, 3000));
  hilog.info(LOG_DOMAIN, LOG_TAG, 'CMD_TAIL: %{public}s', fullCmd.substring(fullCmd.length - 800));
  // 线程化渲染（glthread）：**逐版本开关（默认开，可在「编辑版本」里关）**；且**仅现代渲染路径
  // （OpenGLv4/桌面 GL）**有效——gl4es/legacy 无此机制（桥对它们本就置 GALLIUM_THREAD=0）。
  // 拼在用户「额外渲染环境变量」**之前** → 用户可显式覆盖。
  const glthread = settings.glThreadEnabled(versionId) && renderer.env === RENDERER_ENV;
  // Mesa glthread 的 UAF **只对 26.x 实测会崩**；≤1.21.x 从不因它崩，而它们（尤其 1.21.10 主菜单
  // ~2800 次/秒的小图上传）会被「每次同步」拖垮 → 对 ≤1.21.x 关掉守卫的同步（守卫退化为纯透传，
  // glthread 收益照拿）。见 notes 20-design/lwjgl3-并代可行性.md / glthread-B方案-GL-guard.md §2。
  const guardSyncNone = glthread && !guardNeedsSync(mcVersion);
  const renderEnv = `GALLIUM_THREAD=${glthread ? '1' : '0'}`
    + (guardSyncNone ? '\nMEOW_GUARD_SYNC=none' : '')
    + `\n${settings.renderEnv()}`;
  hilog.info(LOG_DOMAIN, LOG_TAG, 'glthread=%{public}s guardSync=%{public}s renderer=%{public}s',
    glthread ? 'on' : 'off', guardSyncNone ? 'none' : 'per-call', renderer.env);
  await startJvm(ctx, [java, ...argv], renderer.lib, renderer.env, renderer.glProfile, renderEnv);
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
