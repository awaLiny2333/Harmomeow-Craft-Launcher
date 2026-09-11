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

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { LOG_DOMAIN } from '../common/constants/Constants';

const LOG_TAG = 'EntryBackupAbility';

/**
 * 备份扩展 Ability：由系统在应用备份 / 恢复时回调。
 * 当前无自定义数据需要额外处理，保留空实现并打点确认系统调用了正确路径。
 */
export default class EntryBackupAbility extends BackupExtensionAbility {
  /** 备份阶段回调：无需导出额外数据，等待系统完成即可。 */
  async onBackup() {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onBackup ok');
    await Promise.resolve();
  }

  /** 恢复阶段回调：bundleVersion 携带备份时的版本信息，暂不据此做迁移处理。 */
  async onRestore(bundleVersion: BundleVersion) {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onRestore ok %{public}s', JSON.stringify(bundleVersion));
    await Promise.resolve();
  }
}
