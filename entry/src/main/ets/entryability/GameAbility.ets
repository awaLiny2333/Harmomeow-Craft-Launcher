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

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { IMMERSIVE_STATE, LOG_DOMAIN } from '../common/constants/Constants';
import { gameLaunchParams, setGameLaunchParams } from '../common/state/GameLaunchParams';
import { notifyWindowActive } from '../common/state/JvmLauncher';
import { GAME_ROUTE } from '../common/constants/LaunchContract';

const LOG_TAG = 'GameAbility';

/**
 * 游戏独立窗口 Ability。
 *
 * 在 PC 自由窗口设备上，应用内"另一个系统窗口"的正解是 startAbility 启动第二个
 * UIAbility（带系统装饰、可拖动/缩放），而非 createSubWindow（悬浮窗形态、无顶栏）。
 * 本 Ability 加载游戏渲染页 pages/GameWindow（承载 XComponent 画面 + 启动 JVM），
 * 即"点启动 → 独立游戏窗口"。启动参数经 want.parameters 进入 GameLaunchParams。
 */
export default class GameAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'GameAbility onCreate params=%{public}s',
      JSON.stringify(want.parameters ?? {}));
    // 透传启动参数给 GameWindow 页。
    const p = want.parameters as Record<string, string> | undefined;
    if (p !== undefined) {
      setGameLaunchParams({
        gameRoot: p.gameRoot ?? '',
        jsonPath: p.jsonPath ?? '',
        versionId: p.versionId ?? '',
      });
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'GameAbility onWindowStageCreate');

    // 记住窗口位置尺寸，下次打开按记忆恢复（2in1/PC 生效）
    windowStage.setWindowRectAutoSave(true).catch((err: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'setWindowRectAutoSave failed code=%{public}s msg=%{public}s',
        err.code, err.message);
    });

    windowStage.loadContent(GAME_ROUTE, (err) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'GameAbility loadContent failed. Cause: %{public}s',
          JSON.stringify(err));
        return;
      }
      
      // Set immersive
      try {
        const mainWindow = windowStage.getMainWindowSync();
        // mainWindow.setWindowDecorHeight(WINDOW_DECOR_HEIGHT);
        mainWindow.setImmersiveModeEnabledState(IMMERSIVE_STATE);
        // mainWindow.setWindowDecorVisible(!IMMERSIVE_STATE);
        mainWindow.setWindowSystemBarEnable([]).catch((err: BusinessError) => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to setWindowSystemBarEnable. code: %{public}s, message: %{public}s',
            err.code, err.message);
        });
      } catch (err) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'Failed to set immersive. Cause: %{public}s', JSON.stringify(err));
      }
      
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'GameAbility content loaded');
      // 顶栏标题设为该版本 id（"游戏窗口显示自己的版本号"）。
      this.applyWindowTitle(windowStage);
    });

    // 26.3(SDL)：MC 靠 SDL 的 FOCUS_LOST/GAINED 决定是否自动暂停（options: pauseOnLostFocus）；
    // 平台侧告知获焦/失焦的只有 windowStageEvent，转给 native（写共享块 → SDL 驱动发焦点事件）。
    try {
      windowStage.on('windowStageEvent', (ev: window.WindowStageEventType) => {
        notifyWindowActive(ev === window.WindowStageEventType.ACTIVE).catch((e: BusinessError) => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'notifyWindowActive failed code=%{public}s', e.code);
        });
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'windowStageEvent subscribe failed');
    }
  }

  /** 把游戏窗口顶栏标题设为当前启动版本的 id（best-effort；设备/窗口不支持则忽略）。 */
  private applyWindowTitle(windowStage: window.WindowStage): void {
    const id: string = gameLaunchParams.versionId;
    if (id.length === 0) {
      return;
    }
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowTitle(id).catch((e: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'setWindowTitle failed code=%{public}s msg=%{public}s',
          e.code, e.message);
      });
      hilog.info(LOG_DOMAIN, LOG_TAG, 'window title set to %{public}s', id);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'setWindowTitle err: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'GameAbility onDestroy');
  }
}
