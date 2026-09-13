import { common } from '@kit.AbilityKit';
import { SettingsTools } from '../common/data/SettingsTools';
import { LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY,
  SCROLL_SPEED_DEFAULT_PERCENT, RENDER_SCALE_OPTIONS } from '../common/constants/Constants';

// native 导出（getCpuCount：sysconf 探测本机核数）
import native from 'libmeowassets.so';

/**
 * 高级选项区块（与 GameDirsView / GameVersionsView / JavaEnvView 平级，由 Index 挂载）。
 *
 * 承载不常用、偏调试/进阶的开关与启动参数覆盖。所有值经 SettingsTools 落盘到 Preferences，
 * 供游戏进程（:game）在启动时读取；跨进程共享因此不走 AppStorageV2。
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

  private settings: SettingsTools | undefined = undefined;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
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
    try {
      this.detectedCpus = native.getCpuCount();
    } catch (e) {
      this.detectedCpus = 0;
    }
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

  build() {
    Column({ space: LAYOUT_SPACE }) {
      Text($r('app.string.advanced_title'))
        .fontWeight(FontWeight.Bold);

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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
