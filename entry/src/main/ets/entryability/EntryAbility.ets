/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window, ThemeControl } from '@kit.ArkUI';
import { LOG_DOMAIN, ROUTE_INDEX } from '../common/constants/Constants';
import { MEOW_THEME } from '../common/theme/AppTheme';
import { windowHolder } from '../common/state/WindowHolder';

const LOG_TAG = 'EntryAbility';

/**
 * 应用主 Ability（入口）。
 *
 * 职责：进程级生命周期管理 + 窗口初始化 + 加载首屏页面。
 * 窗口相关约定见各生命周期方法内的注释；日志统一走 LOG_DOMAIN/LOG_TAG。
 */
export default class EntryAbility extends UIAbility {
  /**
   * Ability 创建：设置应用级配色模式跟随系统（不强制浅/深色）。
   * want / launchParam 是生命周期框架入参（可能为空场景由框架保证），这里暂不使用。
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 供独立游戏窗口（startAbility 第二 UIAbility）使用
    windowHolder.init(this.context);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onDestroy');
  }

  /**
   * 窗口创建完成：初始化窗口能力并加载首页。
   * 1. 开启系统级"窗口位置/大小记忆"：记住主窗关闭时的位置与尺寸，下次启动按记忆恢复
   *    （自由窗口保留大小/位置、超工作区回弹；2in1/PC 设备生效，与工程 deviceTypes 匹配）。
   * 2. loadContent 加载首屏；页面路径必须与 main_pages.json 注册页一致，否则白屏。
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.setWindowRectAutoSave(true).catch((err: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to set window rect auto-save. code: %{public}s, message: %{public}s',
        err.code, err.message);
    });

    windowStage.loadContent(ROUTE_INDEX, (err) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // 应用内主题（青色）；官方要求放在 loadContent 完成回调里。
      ThemeControl.setDefaultTheme(MEOW_THEME);

      // Set immersive
      try {
        const mainWindow = windowStage.getMainWindowSync();
        mainWindow.setImmersiveModeEnabledState(true);
        mainWindow.setWindowDecorVisible(false);
        mainWindow.setWindowSystemBarEnable([]).catch((err: BusinessError) => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to setWindowSystemBarEnable. code: %{public}s, message: %{public}s',
            err.code, err.message);
        });
      } catch (err) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to set immersive. Cause: %{public}s', JSON.stringify(err));
      }

      hilog.info(LOG_DOMAIN, LOG_TAG, 'Succeeded in loading the content.');
    });
  }

  /** 窗口销毁：释放 UI 相关资源。 */
  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onBackground');
  }
}
