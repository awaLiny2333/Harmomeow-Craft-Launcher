import { common } from '@kit.AbilityKit';
import { SettingsTools } from '../common/data/SettingsTools';
import { exportSettings } from '../common/data/AppSettings';
import { pickDirectory, authorizeDirectory } from '../common/access/FileAccess';
import { LAYOUT_SPACE, LAYOUT_SPACE_SMALL, OPACITY_SECONDARY,
  SCROLL_SPEED_DEFAULT_PERCENT, TOUCH_SENSITIVITY_DEFAULT_PERCENT, TOUCH_AS_MOUSE_DEFAULT,
  TOUCH_CONTROLS_DEFAULT, TOUCH_CONTROLS_INSET_DEFAULT, TOUCH_CONTROLS_SCALE_DEFAULT_PERCENT,
  RENDER_SCALE_OPTIONS } from '../common/constants/Constants';

// native 导出（getCpuCount：sysconf 探测本机核数）
import native from 'libmeowassets.so';

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
  /** 触屏当鼠标（默认开）。 */
  @Local touchAsMouse: boolean = TOUCH_AS_MOUSE_DEFAULT;
  /** 触屏虚拟按键（默认关）。 */
  @Local touchControls: boolean = TOUCH_CONTROLS_DEFAULT;
  /** CPU 线程数覆盖（空 = 自动）。 */
  @Local cpuCountText: string = '';
  /** 最大堆 MB 覆盖（空 = 自动）。 */
  @Local maxHeapText: string = '';
  /** 滚轮速度百分比（空 = 100 正常）。 */
  @Local scrollSpeedText: string = '';
  /** 触屏转视角灵敏度百分比（空 = 默认 128 正常）。 */
  @Local touchSensitivityText: string = '';
  /** 虚拟触屏按键覆盖层上边距（空 = 默认 12vp）。 */
  @Local touchControlsInsetTopText: string = '';
  /** 虚拟触屏按键覆盖层右边距（空 = 默认 12vp）。 */
  @Local touchControlsInsetRightText: string = '';
  /** 虚拟触屏按键覆盖层下边距（空 = 默认 12vp）。 */
  @Local touchControlsInsetBottomText: string = '';
  /** 虚拟触屏按键覆盖层左边距（空 = 默认 12vp）。 */
  @Local touchControlsInsetLeftText: string = '';
  /** 虚拟触屏按键覆盖层整体缩放百分比（空 = 默认 100）。 */
  @Local touchControlsScaleText: string = '';
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
    this.reloadFromSettings();
    try {
      this.detectedCpus = native.getCpuCount();
    } catch (e) {
      this.detectedCpus = 0;
    }
  }

  /** 从应用级全局设置刷新本地编辑态（只读，不写盘）。挂载时读一次即可（设置不随目录变化）。 */
  private reloadFromSettings(): void {
    const s = new SettingsTools(this.context());
    this.settings = s;
    this.showInputRate = s.showInputRate();
    this.touchAsMouse = s.touchAsMouse();
    this.touchControls = s.touchControls();
    const c = s.cpuCount();
    this.cpuCountText = c > 0 ? `${c}` : '';
    const m = s.maxHeapMb();
    this.maxHeapText = m > 0 ? `${m}` : '';
    const sp = s.scrollSpeedPercent();
    this.scrollSpeedText = sp === SCROLL_SPEED_DEFAULT_PERCENT ? '' : `${sp}`;
    const ts = s.touchSensitivityPercent();
    this.touchSensitivityText = ts === TOUCH_SENSITIVITY_DEFAULT_PERCENT ? '' : `${ts}`;
    const it = s.touchControlsInsetTop();
    this.touchControlsInsetTopText = it === TOUCH_CONTROLS_INSET_DEFAULT ? '' : `${it}`;
    const ir = s.touchControlsInsetRight();
    this.touchControlsInsetRightText = ir === TOUCH_CONTROLS_INSET_DEFAULT ? '' : `${ir}`;
    const ib = s.touchControlsInsetBottom();
    this.touchControlsInsetBottomText = ib === TOUCH_CONTROLS_INSET_DEFAULT ? '' : `${ib}`;
    const il = s.touchControlsInsetLeft();
    this.touchControlsInsetLeftText = il === TOUCH_CONTROLS_INSET_DEFAULT ? '' : `${il}`;
    const tsc = s.touchControlsScalePercent();
    this.touchControlsScaleText = tsc === TOUCH_CONTROLS_SCALE_DEFAULT_PERCENT ? '' : `${tsc}`;
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

  /** 解析覆盖层内边距（vp，允许小数）；空/非法 → -1 哨兵，交给设置层归一化回默认值（0 是合法值）。 */
  private parseInset(v: string): number {
    const t = v.trim();
    if (t.length === 0) {
      return -1;
    }
    const n = parseFloat(t);
    return Number.isNaN(n) ? -1 : n;
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
   * 导出的是**应用级数据**（目录列表 + 账户列表 + 高级选项 + 触控布局；账户含 token）——故放在本区（应用级设置区）最下面。
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

  /** 选目标目录（授权一次，一次性导出不持久化）→ 写三份 JSON（设置 + 账户 + 触控布局）到带时间戳子目录；取消静默；部分读不出则提示跳过。 */
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

      // 触屏当鼠标（默认开）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_as_mouse'));
          Text($r('app.string.advanced_touch_as_mouse_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        Toggle({ type: ToggleType.Switch, isOn: this.touchAsMouse })
          .onChange((isOn: boolean) => {
            this.touchAsMouse = isOn;
            this.settings?.setTouchAsMouse(isOn);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 触屏虚拟按键（默认关）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_controls'));
          Text($r('app.string.advanced_touch_controls_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        Toggle({ type: ToggleType.Switch, isOn: this.touchControls })
          .onChange((isOn: boolean) => {
            this.touchControls = isOn;
            this.settings?.setTouchControls(isOn);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 触屏虚拟按键覆盖层：上边距 vp（空 = 默认 12）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_inset_top'));
          Text($r('app.string.advanced_touch_inset_top_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.touchControlsInsetTopText, placeholder: `${TOUCH_CONTROLS_INSET_DEFAULT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.touchControlsInsetTopText = v;
          })
          .onSubmit(() => {
            this.settings?.setTouchControlsInsetTop(this.parseInset(this.touchControlsInsetTopText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 触屏虚拟按键覆盖层：右边距 vp（空 = 默认 12）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_inset_right'));
          Text($r('app.string.advanced_touch_inset_right_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.touchControlsInsetRightText, placeholder: `${TOUCH_CONTROLS_INSET_DEFAULT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.touchControlsInsetRightText = v;
          })
          .onSubmit(() => {
            this.settings?.setTouchControlsInsetRight(this.parseInset(this.touchControlsInsetRightText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 触屏虚拟按键覆盖层：下边距 vp（空 = 默认 12）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_inset_bottom'));
          Text($r('app.string.advanced_touch_inset_bottom_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.touchControlsInsetBottomText, placeholder: `${TOUCH_CONTROLS_INSET_DEFAULT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.touchControlsInsetBottomText = v;
          })
          .onSubmit(() => {
            this.settings?.setTouchControlsInsetBottom(this.parseInset(this.touchControlsInsetBottomText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 触屏虚拟按键覆盖层：左边距 vp（空 = 默认 12）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_inset_left'));
          Text($r('app.string.advanced_touch_inset_left_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.touchControlsInsetLeftText, placeholder: `${TOUCH_CONTROLS_INSET_DEFAULT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.touchControlsInsetLeftText = v;
          })
          .onSubmit(() => {
            this.settings?.setTouchControlsInsetLeft(this.parseInset(this.touchControlsInsetLeftText));
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 触屏虚拟按键覆盖层：整体缩放 %（空 = 默认 100；只缩放按键尺寸与间隔，不影响四周边距）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_scale'));
          Text($r('app.string.advanced_touch_scale_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.touchControlsScaleText, placeholder: `${TOUCH_CONTROLS_SCALE_DEFAULT_PERCENT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.touchControlsScaleText = v;
          })
          .onSubmit(() => {
            this.settings?.setTouchControlsScalePercent(this.parseCount(this.touchControlsScaleText));
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

      // 触屏转视角灵敏度 %（空 = 默认 128 正常）
      Row({ space: LAYOUT_SPACE }) {
        Column({ space: LAYOUT_SPACE_SMALL }) {
          Text($r('app.string.advanced_touch_sensitivity'));
          Text($r('app.string.advanced_touch_sensitivity_hint'))
            .opacity(OPACITY_SECONDARY);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        TextInput({ text: this.touchSensitivityText, placeholder: `${TOUCH_SENSITIVITY_DEFAULT_PERCENT}` })
          .type(InputType.Number)
          .width(120)
          .onChange((v: string) => {
            this.touchSensitivityText = v;
          })
          .onSubmit(() => {
            this.settings?.setTouchSensitivityPercent(this.parseCount(this.touchSensitivityText));
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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
