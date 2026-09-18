// VulkanProbeHost.ets — 开发者诊断入口（与产品 UI 无关）：仅当 render-env 命中 MEOW_VK_PROBE 时由 Index 挂载。
// 正常用户不会设置该 env，故零行为、零渲染。
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingsTools } from '../common/data/SettingsTools';
import { JreLibModule } from '../common/state/JvmLauncher';
import { LAYOUT_SPACE, LOG_DOMAIN, VK_PROBE_POLL_MS, VK_PROBE_SURFACE_HEIGHT,
  VK_PROBE_RESULT_HEIGHT } from '../common/constants/Constants';

const LOG_TAG = 'VulkanProbeHost';

/** F76：进程内探针只触发一次（render-env 命中 MEOW_VK_PROBE 时）。 */
let vkProbeTriggered: boolean = false;

/**
 * F29 探针专用 XComponent 控制器：只用于创建一个临时 SURFACE，
 * 把 surfaceId 交给 native 探针（native 直接 dlopen 系统 libvulkan.so 送显）。
 */
class VkProbeXComponentController extends XComponentController {
  private ready: (surfaceId: string, w: number, h: number) => void = () => {
  };

  setReadyHandler(h: (surfaceId: string, w: number, h: number) => void): void {
    this.ready = h;
  }

  onSurfaceCreated(surfaceId: string): void {
    this.ready(surfaceId, 0, 0);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.ready(surfaceId, rect.surfaceWidth, rect.surfaceHeight);
  }
}

/**
 * 开发者诊断宿主（F29/F76）：由 Index 仅在 render-env 命中 MEOW_VK_PROBE 时挂载。
 * 创建临时 XComponent SURFACE 交给 native 裸 ICD + WSI 送显探针，轮询结果并在屏幕/hilog 双回显。
 */
@ComponentV2
export struct VulkanProbeHost {
  /** 临时探针 surface 是否可见（可见才有 surfaceId）。 */
  @Local probeSurfaceVisible: boolean = false;
  /** 探针报告（空串 = 尚无结果）。 */
  @Local probeResult: string = '';

  private settings: SettingsTools | undefined = undefined;
  /** 探针 XComponent 控制器 + 轮询定时器 + meowjre 引用。 */
  private probeController: VkProbeXComponentController = new VkProbeXComponentController();
  private probeTimer: number = -1;
  private probeStarted: boolean = false;
  private probeLib: JreLibModule | null = null;
  /** 本次触发的送显帧数（来自 render-env 的 MEOW_VK_PROBE 值）。 */
  private probeFrames: number = 0;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.settings = new SettingsTools(this.context());
    // surface 就绪即启动 native 探针（窗口为 NULL / 无 surfaceId 则打日志早退）。
    this.probeController.setReadyHandler((sid: string) => {
      this.onProbeSurface(sid);
    });
    // render-env 文本里出现 MEOW_VK_PROBE 时，表面就绪后自动跑一次裸 ICD + WSI 送显探针。
    // 正常用户不填该项 = 零行为变化。
    let frames = 0;
    if (this.settings !== undefined) {
      frames = this.settings.vkProbeFrames();
    }
    if (frames > 0 && !vkProbeTriggered) {
      vkProbeTriggered = true;
      this.probeFrames = frames;
      this.probeSurfaceVisible = true;
    }
  }

  aboutToDisappear(): void {
    this.stopProbePoll();
  }

  /** surface 就绪 → 取 surfaceId 启动 native 探针，然后轮询报告。 */
  private async onProbeSurface(surfaceId: string): Promise<void> {
    if (!this.probeSurfaceVisible || this.probeStarted) {
      return;
    }
    this.probeStarted = true;
    const sid = parseInt(surfaceId, 10);
    try {
      const jre = await import('meowjre') as JreLibModule;
      const startFn = jre.vulkanPresentProbeStart;
      if (startFn === undefined || jre.vulkanPresentProbeResult === undefined) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'vk probe unavailable: meowjre export missing');
        this.finishVkProbe();
        return;
      }
      const started: boolean = Number.isNaN(sid) ? false : startFn(sid, this.probeFrames);
      if (!started) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'vk probe no window (sid=%{public}d)', sid);
        this.finishVkProbe();
        return;
      }
      this.probeLib = jre;
      this.stopProbePoll();
      this.probeTimer = setInterval(() => {
        this.readVkProbe();
      }, VK_PROBE_POLL_MS);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'vk probe start error: %{public}s', JSON.stringify(e));
      this.finishVkProbe();
    }
  }

  /** 轮询 native 报告；非空即收尾（屏幕结果区 + hilog 双回显）。 */
  private readVkProbe(): void {
    const jre = this.probeLib;
    if (jre === null) {
      return;
    }
    const resultFn = jre.vulkanPresentProbeResult;
    if (resultFn === undefined) {
      return;
    }
    const r: string = resultFn();
    if (r.length > 0) {
      this.stopProbePoll();
      this.probeResult = r;
      this.probeSurfaceVisible = false;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'vk probe report:\n%{public}s', r);
    }
  }

  /** 早退收尾（无窗口 / 接口缺失 / 探针结束），原因已打 hilog。 */
  private finishVkProbe(): void {
    this.stopProbePoll();
    this.probeSurfaceVisible = false;
    this.probeStarted = false;
  }

  private stopProbePoll(): void {
    if (this.probeTimer >= 0) {
      clearInterval(this.probeTimer);
      this.probeTimer = -1;
    }
  }

  build() {
    Column({ space: LAYOUT_SPACE }) {
      // 临时探针表面：onSurfaceCreated 后启动 native 探针，探针结束即隐藏。
      if (this.probeSurfaceVisible) {
        XComponent({ type: XComponentType.SURFACE, controller: this.probeController })
          .width('100%')
          .height(VK_PROBE_SURFACE_HEIGHT)
          .backgroundColor(Color.Black);
      }

      // 结果区：长按可选中复制（探针报告；同时已打 hilog）。非 MEOW_VK_PROBE 时恒为空。
      if (this.probeResult.length > 0) {
        Scroll() {
          Text(this.probeResult)
            .copyOption(CopyOptions.LocalDevice)
            .width('100%');
        }
        .width('100%')
        .height(VK_PROBE_RESULT_HEIGHT)
        .edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
