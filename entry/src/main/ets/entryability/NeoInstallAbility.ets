import { UIAbility, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN } from '../common/constants/Constants';
import { startJvm } from '../common/state/JvmLauncher';
import { JavaRuntime, defaultRuntime, runtimeById } from '../common/data/JavaRuntime';
import { runtimeStatus } from '../common/data/JavaEnvScanner';
import { NeoForgeProcessorJob } from '../common/data/NeoForgeInstaller';
import { activateDirectory } from '../common/access/FileAccess';

const LOG_TAG = 'NeoInstallAbility';

/** 工具 JVM 的临时目录 JVM 参数（父进程写入 job；预检按它报"tmpdir 是否可见"）。 */
const TMPDIR_FLAG = '-Djava.io.tmpdir=';

/**
 * NeoForge 安装期执行 processor 的**无窗** Ability（B 路线，见 notes `安装期JVM载体-调研.md` §8.3）。
 *
 * **命名正名（2026-10-01）**：本 ability 是**两条链共用**的安装期载体 —— Forge ≥1.13 与 NeoForge 都往
 * `:neoinstall` 投**同一份 job 协议**、由同一个 `startJvm` 起 headless 工具 JVM（见 `VersionInstaller`
 * 的「安装期工具 JVM 载体」）。名字里的 `Neo` 是历史（它先为 NeoForge 而建）。**平台标识一律不改**：
 * `module.json5` 的 ability 名、`:neoinstall` 进程名、`LaunchContract.NEO_INSTALL_ABILITY` /
 * `NEO_INSTALL_PROCESS_SUFFIX`、job 里的引用与 notes/夹具全靠它们对齐 ⇒ 改名是高风险 churn、零行为收益。
 * 故按"注释层正名"办：读作**"安装期工具 JVM 载体 ability"**（对两条链等价）。
 *
 * 要点：
 * - 声明静态 `process: ":neoinstall"`（module.json5）⇒ 与主进程隔离：JVM 结束时桥会 `_exit`，
 *   只结束本进程，启动器不受影响；
 * - **不 `loadContent`**（不建页面）；窗口显隐由父进程 `startAbility` 的 StartOptions 决定
 *   （`processMode: NEW_PROCESS_ATTACH_TO_PARENT` + `startupVisibility: STARTUP_HIDE`，二者必须成对，实测无感）；
 * - 作业经 **job 文件**传入（`want.parameters.job`）：内容为 `{argv: [...], rootUri, jreId}`，即完整 java
 *   参数（`java -cp <tools> <MainClass> ...`）+ 目录授权 URI + 该用的 JRE id。**两条链**按同一协议投递
 *   （Forge 侧是同形的 `ForgeProcessorJob`，字段同名同序 ⇒ 本文件按 `NeoForgeProcessorJob` 读即可）；
 * - `rendererLib` 传空 ⇒ 桥走 **headless**（跳过渲染器预 dlopen / GL env / glthread 失效安全），
 *   并把 `JLI_BEGIN` / `JLI_RETURNED code=N` 写入 `<filesDir>/meow-neo-jvm-result.txt` 供父进程判成败。
 */
export default class NeoInstallAbility extends UIAbility {
  async onCreate(want: Want): Promise<void> {
    const p = want.parameters as Record<string, string> | undefined;
    const jobPath: string = (p !== undefined ? p.job : undefined) ?? '';
    if (jobPath.length === 0) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'job path missing in want.parameters');
      return;
    }
    let job: NeoForgeProcessorJob;
    try {
      job = JSON.parse(fileIo.readTextSync(jobPath)) as NeoForgeProcessorJob;
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'read job failed: %{public}s', JSON.stringify(e));
      return;
    }
    if (job.argv.length === 0) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'job argv empty');
      return;
    }
    // 主类 = `-cp` 之后那一项（argv 里还有 -D 项，别写死下标）。
    let mainIdx = -1;
    for (let i = 0; i < job.argv.length - 1; i++) {
      if (job.argv[i] === '-cp' || job.argv[i] === '-classpath') {
        mainIdx = i + 2;
        break;
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'run processor job: argn=%{public}d main=%{public}s',
      job.argv.length, mainIdx >= 0 && mainIdx < job.argv.length ? job.argv[mainIdx] : '');
    // 目录授权：主进程已 persist+activate；本进程再激活一次（best-effort），
    // 确保 :neoinstall 进程能读写游戏目录下的 libraries/（用户目录需要该授权）。
    if (job.rootUri.length > 0) {
      try {
        await activateDirectory(job.rootUri);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'activateDirectory failed: %{public}s', JSON.stringify(e));
      }
    }
    // headless：渲染器参数全空 ⇒ 桥不加载 GL，只起一个纯工具 JVM。
    // JRE 选择：安装期是**工具 JVM**（跑 Forge 的 processor 工具，不是游戏）。**与启动路径同源**——
    // id 由父进程 `GameVersionsView.confirmInstall` 经 `JavaPolicy.resolveJavaRuntime(MC 版本 × loader)`
    // 解析、写进 job 带过来（见 `NeoForgeProcessorJob.jreId`），本进程**不重解析**（无第二事实源）。
    const toolRuntime = toolRuntimeForJob(job.jreId);
    // 【兜底数据门】主进程安装入口（`GameVersionsView.confirmInstall`）已按**同一判据**
    // （`runtimeStatus` × 同一解析结果）放行过；但数据可能在放行后被删/升级，本进程又**无 UI**
    // 弹不出对话框 ⇒ 这里同步早退，绝不硬起工具 JVM（`startJvm` 只自检 el1 的 `libjli.so`，
    // 管不到 java.home 的数据）。**判据与主进程同源，此处不另写解析逻辑。**
    if (!runtimeStatus(this.context.filesDir, toolRuntime).installed) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'abort: JRE %{public}s not ready for tool JVM', toolRuntime.id);
      return;
    }
    // 诊断：**本进程**是唯一能在失败前回答"工具看得见类路径/输入件吗"的地方（工具 JVM 就在
    // 本进程里起、同 uid、同一份用户文件授权）⇒ 先留痕再起 JVM。
    logToolJvmInputPreflight(job.argv);
    startJvm(this.context, job.argv, toolRuntime, '', '', '', '');
  }
}

/**
 * 工具 JVM 的**可读性预检 + 完整 argv 留痕**（**只写日志，不改任何行为**）。
 *
 * 为什么必须在本进程做：工具 JVM 由本进程 `dlopen(libjli)+JLI_Launch` **in-process** 起，故本进程
 * `fileIo` 看到的可见性 = 工具 JVM 看到的可见性（同 uid、同一份用户文件授权）。而工具**在自己的
 * stdout/stderr 上**报错（`Error: Could not find or load main class …` → JLI 退 1；`Input does not
 * exist …` → 工具 `error()` 退 1），父进程只能拿到退出码 ⇒ 这条日志是本轮唯一能在**没有工具 stderr**
 * 时判定"是类路径不可见，还是工具自己报错"的证据（工具 stderr 的落盘见桥的 `meow-neo-jvm-tool.log`）。
 *
 * 语义边界：`-cp` 条目是**确定**的文件路径 ⇒ 逐条给 exists/size；其余 argv 只对"看起来像绝对路径"的
 * 项做存在性留痕（**启发式，仅日志**：argv 的语义属工具，本层不解释、不校验、不改写）。
 */
function logToolJvmInputPreflight(argv: string[]): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, 'tool JVM argv(%{public}d): %{public}s', argv.length, argv.join(' '));
  let cp = '';
  let tmpdir = '';
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-cp' || a === '-classpath') {
      cp = i + 1 < argv.length ? argv[i + 1] : '';
    } else if (a.startsWith(TMPDIR_FLAG)) {
      tmpdir = a.substring(TMPDIR_FLAG.length);
    }
  }
  if (cp.length === 0) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'cp preflight: -cp missing/empty in argv -> JVM cannot see any tool jar');
  } else {
    const entries = cp.split(':');
    let unreadable = 0;
    for (const e of entries) {
      if (e.length === 0) {
        continue;
      }
      const size = readableSize(e);
      if (size < 0) {
        unreadable++;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'cp preflight: UNREADABLE %{public}s', e);
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cp preflight: entries=%{public}d unreadable=%{public}d',
      entries.length, unreadable);
  }
  if (tmpdir.length > 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'java.io.tmpdir %{public}s exists=%{public}s',
      tmpdir, readableSize(tmpdir) >= 0 ? 'yes' : 'no');
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('/')) {
      continue;
    }
    const size = readableSize(a);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'argv[%{public}d] path-like exists=%{public}s size=%{public}d %{public}s',
      i, size >= 0 ? 'yes' : 'no', size, a);
  }
}

/** 文件/目录可读时的字节数；不存在或不可读 ⇒ -1（**绝不抛**：预检本身不得成为失败源）。 */
function readableSize(path: string): number {
  try {
    if (fileIo.accessSync(path)) {
      return fileIo.statSync(path).size;
    }
  } catch (e) {
    return -1;
  }
  return -1;
}

/**
 * 取工具 JVM 该用的 runtime：job 带的 id（父进程按策略解析）→ 查表；**缺失/未知 ⇒ 现代套 + warn**。
 * 只做"id → runtime"查表，**不解析策略**（策略只在父进程一处，见 `JavaPolicy`）⇒ 无第二事实源。
 * 回退保证向后兼容：旧 job（无 `jreId`，`JSON.parse` 后该字段为 `undefined`）或表里没有的 id
 * 也照跑，行为 = 单 JRE 时代（现代套）。
 */
function toolRuntimeForJob(jreId: string | undefined): JavaRuntime {
  if (jreId === undefined || jreId.length === 0) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'job has no jreId (old job?) -> fallback to default runtime');
    return defaultRuntime();
  }
  const rt = runtimeById(jreId);
  if (rt === undefined) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'job jreId "%{public}s" unknown -> fallback to default runtime', jreId);
    return defaultRuntime();
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'tool JVM JRE = %{public}s (from job, policy-resolved)', rt.id);
  return rt;
}
