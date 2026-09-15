import { UIAbility, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN } from '../common/constants/Constants';
import { startJvm } from '../common/state/JvmLauncher';
import { NeoForgeProcessorJob } from '../common/data/NeoForgeInstaller';
import { activateDirectory } from '../common/access/FileAccess';

const LOG_TAG = 'NeoInstallAbility';

/**
 * NeoForge 安装期执行 processor 的**无窗** Ability（B 路线，见 notes `安装期JVM载体-调研.md` §8.3）。
 *
 * 要点：
 * - 声明静态 `process: ":neoinstall"`（module.json5）⇒ 与主进程隔离：JVM 结束时桥会 `_exit`，
 *   只结束本进程，启动器不受影响；
 * - **不 `loadContent`**（不建页面）；窗口显隐由父进程 `startAbility` 的 StartOptions 决定
 *   （`processMode: NEW_PROCESS_ATTACH_TO_PARENT` + `startupVisibility: STARTUP_HIDE`，二者必须成对，实测无感）；
 * - 作业经 **job 文件**传入（`want.parameters.job`）：内容为 `{argv: [...]}`，即完整 java 参数
 *   （`java -cp <tools> <MainClass> ...`，由父进程按 installer profile 原样展开）；
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
    startJvm(this.context, job.argv, '', '', '', '');
  }
}
