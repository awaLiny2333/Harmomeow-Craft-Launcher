import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buildLaunchArgv } from './MinecraftLauncher';
import { startJvm } from '../state/JvmLauncher';
import { stageClasspathDir } from './ClasspathStager';
import { Account, AccountsTools, ACCOUNT_TYPE_OFFLINE, ACCOUNT_TYPE_MICROSOFT, offlineUuid } from './AccountsTools';
import { SettingsTools } from './SettingsTools';
import { MEOW_HOME_DIR, MC_RUN_DIR_PREFIX, NATIVES_DIR, jreHomeDir,
  hspLibsDir, versionDir } from '../constants/Paths';
import { WINDOW_DEFAULT_W, WINDOW_DEFAULT_H, OFFLINE_USERNAME } from '../constants/LaunchDefaults';
import { rendererForVersion } from './RendererPolicy';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'GameLauncher';

/**
 * 完整启动流程（与游戏窗 UI 解耦）：stage classpath → 预置账户 → 组装 argv → 启动 JVM。
 * 调用方（GameWindow）负责先注入 surface；本函数只做"起 JVM"。
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
  // 当前选中账户（无则兜底创建默认离线账户）；写入账户档案后把玩家名交给启动器（launcher 按名加载）。
  const accounts = new AccountsTools(ctx);
  let account: Account | null = accounts.selected();
  if (account === null) {
    account = accounts.add({
      id: `account:${Date.now()}`,
      type: ACCOUNT_TYPE_OFFLINE,
      name: OFFLINE_USERNAME,
      uuid: offlineUuid(OFFLINE_USERNAME),
    });
  }
  accounts.writeAccountFile(meowHome, account);
  let launchAccount: Account = account;
  if (account.type === ACCOUNT_TYPE_MICROSOFT) {
    // 微软账户：启动前确保 token 新鲜（过期则用 refresh_token 续期）。
    try {
      launchAccount = await accounts.ensureMicrosoftFresh(account);
      accounts.writeAccountFile(meowHome, launchAccount);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'microsoft refresh failed: %{public}s', (e as Error).message);
    }
  }
  // 版本隔离（逐版本开关，跨进程从 Preferences 读）：隔离时游戏运行目录 = <gameRoot>/versions/<id>，
  // 存档/选项/日志/资源包落版本目录，与其它版本互不干扰；assets/libraries 仍是共享根（不随隔离变）。
  const isolated = settings.versionIsolated(versionId);
  const gameDir = isolated ? versionDir(gameRoot, versionId) : gameRoot;
  hilog.info(LOG_DOMAIN, LOG_TAG, 'version %{public}s isolation=%{public}s',
    versionId, isolated ? 'on' : 'off');
  const cpuChip = readCpuChip();
  // 渲染后端按 MC 版本选（≤1.16 → gl4es/GLES；≥1.17 → 系统桌面 GL）。lib 必须与 startJvm 传的一致。
  const renderer = rendererForVersion(versionId, settings.rendererOverride(versionId));
  const argv = buildLaunchArgv({
    gameRoot: gameRoot,
    gameDir: gameDir,
    jsonPath: jsonPath,
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
  });
  if (argv.length === 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'launch abort: empty argv for %{public}s', versionId);
    return;
  }
  const java = `${jreHomeDir(ctx.filesDir)}/bin/java`;
  const fullCmd = [java, ...argv].join(' ');
  hilog.info(LOG_DOMAIN, LOG_TAG, 'CMD: %{public}s', fullCmd.substring(0, 3000));
  hilog.info(LOG_DOMAIN, LOG_TAG, 'CMD_TAIL: %{public}s', fullCmd.substring(fullCmd.length - 800));
  await startJvm(ctx, [java, ...argv], renderer.lib, renderer.env, renderer.glProfile);
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
