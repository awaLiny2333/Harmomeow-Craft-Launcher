import { common } from '@kit.AbilityKit';
import { SettingsTools } from '../common/data/SettingsTools';
import { exportSettings } from '../common/data/AppSettings';
import { pickDirectory, authorizeDirectory } from '../common/access/FileAccess';
import { JreLibModule } from '../common/state/JvmLauncher';
import { LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY,
  SCROLL_SPEED_DEFAULT_PERCENT, RENDER_SCALE_OPTIONS,
  VK_PROBE_FRAMES, VK_PROBE_POLL_MS, VK_PROBE_SURFACE_HEIGHT,
  VK_PROBE_RESULT_HEIGHT } from '../common/constants/Constants';

// native 导出（getCpuCount：sysconf 探测本机核数）
import native from 'libmeowassets.so';

/** 探针提示态（0 无 / 1 接口缺失 / 2 无窗口）。 */
const PROBE_NOTICE_NONE: number = 0;
const PROBE_NOTICE_UNAVAILABLE: number = 1;
const PROBE_NOTICE_NO_WINDOW: number = 2;

/**
 * F29 探针专用 XComponent 控制器：只用于在高级选项区内创建一个临时 SURFACE，
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
 * 高级选项区块（与 GameDirsView / GameVersionsView / JavaEnvView 平级，由 Index 挂载）。
 *
 * 承载不常用、偏调试/进阶的开关与启动参数覆盖。所有值经 SettingsTools 落盘到**应用级全局设置**
 * （`<filesDir>/meow-settings/app-settings.json` 的 `global` 段），供游戏进程（:game）在启动时读取；跨进程共享因此不走 AppStorageV2。
 * 约定：数字项留空 = 自动（用 LaunchDefaults 默认）；改动在下次打开游戏窗口生效。
 */
@ComponentV2
export struct AdvancedOptionsView {
  /** 是否显示采样率 overlay。 */
  @Local showInputRate: boolean = false;
  /** CPU 线程数覆盖（空 = 自动）。 */
  @Local cpuCountText: string = '';
  /** 最大堆 MB 覆盖（空 = 自动）。 */
  @Local maxHeapText: string = '';
  /** 滚轮速度百分比（空 = 100 正常）。 */
  @Local scrollSpeedText: string = '';
  /** 显示缩放档位索引（映射 RENDER_SCALE_OPTIONS；默认 0 = 1x 关闭）。 */
  @Local scaleIndex: number = 0;
  /** 微软登录 client_id（用户自填，不预置；空 = 不可用）。 */
  @Local msClientIdText: string = '';
  /** 额外渲染环境变量（实验；空 = 不改）。 */
  @Local renderEnvText: string = '';
  /** 额外 JVM 参数（实验；空 = 不改）。 */
  @Local jvmArgsText: string = '';
  /** native 探测到的本机核数（仅展示参考）。 */
  @Local detectedCpus: number = 0;

  /** F29：临时探针 surface 是否可见（可见才有 surfaceId）。 */
  @Local probeSurfaceVisible: boolean = false;
  /** F29：探针是否运行中。 */
  @Local probeRunning: boolean = false;
  /** F29：探针报告（空串 = 尚无结果）。 */
  @Local probeResult: string = '';
  /** F29：探针提示态（无窗口 / 接口缺失）。 */
  @Local probeNotice: number = PROBE_NOTICE_NONE;

  private settings: SettingsTools | undefined = undefined;
  /** F29：探针 XComponent 控制器 + 轮询定时器 + meowjre 引用。 */
  private probeController: VkProbeXComponentController = new VkProbeXComponentController();
  private probeTimer: number = -1;
  private probeStarted: boolean = false;
  private probeLib: JreLibModule | null = null;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.reloadFromSettings();
    try {
      this.detectedCpus = native.getCpuCount();
    } catch (e) {
      this.detectedCpus = 0;
    }
    // F29：surface 就绪即启动 native 探针（窗口为 NULL / 无 surfaceId 则提示 no window）。
    this.probeController.setReadyHandler((sid: string) => {
      this.onProbeSurface(sid);
    });
  }

  aboutToDisappear(): void {
    this.stopProbePoll();
  }

  /** 从应用级全局设置刷新本地编辑态（只读，不写盘）。挂载时读一次即可（设置不随目录变化）。 */
  private reloadFromSettings(): void {
    const s = new SettingsTools(this.context());
    this.settings = s;
    this.showInputRate = s.showInputRate();
    const c = s.cpuCount();
    this.cpuCountText = c > 0 ? `${c}` : '';
    const m = s.maxHeapMb();
    this.maxHeapText = m > 0 ? `${m}` : '';
    const sp = s.scrollSpeedPercent();
    this.scrollSpeedText = sp === SCROLL_SPEED_DEFAULT_PERCENT ? '' : `${sp}`;
    const si = RENDER_SCALE_OPTIONS.indexOf(s.renderScale());
    this.scaleIndex = si >= 0 ? si : 0;
    this.msClientIdText = s.msClientId();
    this.renderEnvText = s.renderEnv();
    this.jvmArgsText = s.jvmArgs();
  }

  /** 作用域提示：本区选项**对整个启动器生效**（应用私有目录内，全局唯一）。 */
  private scopeHint(): Resource {
    return $r('app.string.advanced_scope_hint');
  }

  /** 解析非负整数；空/非法 → 0（自动）。 */
  private parseCount(v: string): number {
    const t = v.trim();
    if (t.length === 0) {
      return 0;
    }
    const n = parseInt(t, 10);
    return Number.isNaN(n) || n < 0 ? 0 : n;
  }

  private cpuPlaceholder(): string | Resource {
    // 自动值即本机探测核数；探测失败才退回"自动"文案。
    return this.detectedCpus > 0 ? `${this.detectedCpus}` : $r('app.string.advanced_auto');
  }

  /** 显示缩放 Select 选项（1x（关闭）/ 1.5x / 2x / 3x / 4x）。 */
  private scaleOptions(): SelectOption[] {
    return RENDER_SCALE_OPTIONS.map((n: number): SelectOption => ({
      value: n === 1 ? $r('app.string.render_scale_off') : `${n}x`,
    }));
  }

  private scaleValue(): string | Resource {
    const n = RENDER_SCALE_OPTIONS[this.scaleIndex];
    return n === 1 ? $r('app.string.render_scale_off') : `${n}x`;
  }

  private setScale(index: number): void {
    this.scaleIndex = index;
    this.settings?.setRenderScale(RENDER_SCALE_OPTIONS[index]);
  }

  /**
   * 导出设置入口：先弹窗确认（文案明确提示含微软登录凭据、勿分享），确认后选目录并导出。
   * 导出的是**应用级数据**（目录列表 + 账户列表 + 高级选项；账户含 token）——故放在本区（应用级设置区）最下面。
   */
  private confirmExport(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.settings_export'),
      message: $r('app.string.settings_export_confirm_message'),
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {
        },
        fontColor: $r('sys.color.white'),
        backgroundColor: $r('app.color.brand')
      },
      secondaryButton: {
        value: $r('app.string.settings_export'),
        action: () => {
          this.doExport();
        },
        fontColor: $r('sys.color.white'),
        backgroundColor: $r('app.color.danger')
      },
    });
  }

  /** 选目标目录（授权一次，一次性导出不持久化）→ 写两份 JSON 到带时间戳子目录；取消静默；部分读不出则提示跳过。 */
  private async doExport(): Promise<void> {
    const ctx = this.context();
    const picked = await pickDirectory(ctx);
    if (picked === null) {
      return;
    }
    const authorized = await authorizeDirectory(ctx, picked);
    if (!authorized) {
      // 授权失败也给出可见提示（与导出失败一致），不再静默返回。
      this.getUIContext().showAlertDialog({ message: $r('app.string.settings_export_failed') });
      return;
    }
    const result = exportSettings(ctx, picked);
    if (result.outDir === null) {
      this.getUIContext().showAlertDialog({ message: $r('app.string.settings_export_failed') });
      return;
    }
    if (result.skipped.length > 0) {
      // 有文件存在但读不出 → 不假成功：列出被跳过的文件。
      this.getUIContext().showAlertDialog({
        message: $r('app.string.settings_export_partial', result.skipped.join('、')),
      });
      return;
    }
    this.getUIContext().showAlertDialog({
      message: $r('app.string.settings_export_success', result.outDir),
    });
  }

  /** F29：点按钮 → 先建临时 surface（可见），surface 就绪后在 onProbeSurface 启动 native。 */
  private startVkProbe(): void {
    if (this.probeRunning) {
      return;
    }
    this.probeResult = '';
    this.probeNotice = PROBE_NOTICE_NONE;
    this.probeRunning = true;
    this.probeStarted = false;
    this.probeSurfaceVisible = true;
  }

  /** F29：surface 就绪 → 取 surfaceId 启动 native 探针，然后轮询报告。 */
  private async onProbeSurface(surfaceId: string): Promise<void> {
    if (!this.probeRunning || this.probeStarted) {
      return;
    }
    this.probeStarted = true;
    const sid = parseInt(surfaceId, 10);
    try {
      const jre = await import('meowjre') as JreLibModule;
      const startFn = jre.vulkanPresentProbeStart;
      if (startFn === undefined || jre.vulkanPresentProbeResult === undefined) {
        this.finishVkProbe(PROBE_NOTICE_UNAVAILABLE);
        return;
      }
      const started: boolean = Number.isNaN(sid) ? false : startFn(sid, VK_PROBE_FRAMES);
      if (!started) {
        this.finishVkProbe(PROBE_NOTICE_NO_WINDOW);
        return;
      }
      this.probeLib = jre;
      this.stopProbePoll();
      this.probeTimer = setInterval(() => {
        this.readVkProbe();
      }, VK_PROBE_POLL_MS);
    } catch (e) {
      this.finishVkProbe(PROBE_NOTICE_UNAVAILABLE);
    }
  }

  /** F29：轮询 native 报告；非空即收尾上屏。 */
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
      this.probeRunning = false;
      this.probeSurfaceVisible = false;
    }
  }

  /** F29：早退收尾（无窗口 / 接口缺失），结果区给出原因。 */
  private finishVkProbe(notice: number): void {
    this.stopProbePoll();
    this.probeRunning = false;
    this.probeSurfaceVisible = false;
    this.probeStarted = false;
    this.probeNotice = notice;
  }

  private stopProbePoll(): void {
    if (this.probeTimer >= 0) {
      clearInterval(this.probeTimer);
      this.probeTimer = -1;
    }
  }

  build() {
    Column({ space: LAYOUT_SPACE }) {
      Text($r('app.string.advanced_title'))
        .fontWeight(FontWeight.Bold);

      // 作用域说明：本区设置为**应用级、全局唯一**（存应用私有目录，不随游戏目录变化）。
      Text(this.scopeHint())
        .opacity(OPACITY_SECONDARY);

      // 显示鼠标采样率 overlay
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_show_input_rate'));
          Text($r('app.string.advanced_show_input_rate_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        Toggle({ type: ToggleType.Switch, isOn: this.showInputRate })
          .onChange((isOn: boolean) => {
            this.showInputRate = isOn;
            this.settings?.setShowInputRate(isOn);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // CPU 线程数（空 = 自动）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_cpu_count'));
          Text($r('app.string.advanced_cpu_count_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.cpuCountText, placeholder: this.cpuPlaceholder() })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.cpuCountText = v;
          })
          .onSubmit(() => {
            this.settings?.setCpuCount(this.parseCount(this.cpuCountText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 最大内存 MB（空 = 自动）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_max_heap'));
          Text($r('app.string.advanced_max_heap_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.maxHeapText, placeholder: $r('app.string.advanced_auto') })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.maxHeapText = v;
          })
          .onSubmit(() => {
            this.settings?.setMaxHeapMb(this.parseCount(this.maxHeapText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 滚轮速度 %（空 = 100 正常）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_scroll_speed'));
          Text($r('app.string.advanced_scroll_speed_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.scrollSpeedText, placeholder: `${SCROLL_SPEED_DEFAULT_PERCENT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.scrollSpeedText = v;
          })
          .onSubmit(() => {
            this.settings?.setScrollSpeedPercent(this.parseCount(this.scrollSpeedText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 显示缩放（渲染分辨率 = 窗口 / N；越高越省 GPU、画面越糊；下次开游戏生效）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_render_scale'));
          Text($r('app.string.advanced_render_scale_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        // 不设 width/height → Select 自适应文字宽度（本项选项很短，无需与输入框同宽）
        Select(this.scaleOptions())
          .selected(this.scaleIndex)
          .value(this.scaleValue())
          .onSelect((index: number) => {
            this.setScale(index);
          })
          .selectedOptionBgColor($r('app.color.brand_bg'))
          .selectedOptionFontColor($r('app.color.brand'));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 微软登录 client_id（用户自填，不预置；留空 = 微软登录不可用）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_ms_client_id'));
          Text($r('app.string.advanced_ms_client_id_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.msClientIdText })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.msClientIdText = v;
          })
          .onSubmit(() => {
            this.settings?.setMsClientId(this.msClientIdText.trim());
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 额外渲染环境变量（实验/调优；K=V，换行或 ; 分隔；空 = 不改）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_render_env'));
          Text($r('app.string.advanced_render_env_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.renderEnvText })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.renderEnvText = v;
          })
          .onSubmit(() => {
            this.settings?.setRenderEnv(this.renderEnvText.trim());
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 额外 JVM 参数（实验/调优；空格或换行分隔；空 = 不传）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_jvm_args'));
          Text($r('app.string.advanced_jvm_args_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.jvmArgsText })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.jvmArgsText = v;
          })
          .onSubmit(() => {
            this.settings?.setJvmArgs(this.jvmArgsText.trim());
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 最下面的次要入口：导出应用设置（目录 + 账户 + 高级选项；账户含凭据）到用户选择的目录。
      Button($r('app.string.settings_export'))
        .onClick(() => this.confirmExport());

      // F29 诊断：裸 ICD + WSI 可持续送显探针（本区最下方）。点按钮先建临时 XComponent
      // 表面（用与 MC 相同的 XComponent SURFACE 通道），native 直接 dlopen 系统
      // libvulkan.so 连续送显 VK_PROBE_FRAMES 帧；不依赖 MC，也不走自研 shim。
      Column({ space: LAYOUT_SPACE_SMALL }) {
        Text($r('app.string.advanced_vk_probe'))
          .fontWeight(FontWeight.Bold);
        Text($r('app.string.advanced_vk_probe_hint'))
          .opacity(OPACITY_SECONDARY);
        Row({ space: LAYOUT_SPACE }) {
          Button($r('app.string.advanced_vk_probe_run'))
            .enabled(!this.probeRunning)
            .onClick(() => {
              this.startVkProbe();
            });
          if (this.probeRunning) {
            Text($r('app.string.advanced_vk_probe_running'))
              .opacity(OPACITY_SECONDARY);
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        // 临时探针表面：onSurfaceCreated 后启动 native 探针，探针结束即隐藏。
        if (this.probeSurfaceVisible) {
          XComponent({ type: XComponentType.SURFACE, controller: this.probeController })
            .width('100%')
            .height(VK_PROBE_SURFACE_HEIGHT)
            .backgroundColor(Color.Black);
        }

        // 早退提示（不硬跑）：无窗口 / 接口缺失。
        if (this.probeNotice === PROBE_NOTICE_UNAVAILABLE) {
          Text($r('app.string.advanced_vk_probe_unavailable'))
            .opacity(OPACITY_SECONDARY);
        } else if (this.probeNotice === PROBE_NOTICE_NO_WINDOW) {
          Text($r('app.string.advanced_vk_probe_no_window'))
            .opacity(OPACITY_SECONDARY);
        }

        // 结果区：长按可选中复制（含每帧 rc 摘要 + 交换链参数 + 结论）。
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
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
