import { JRE_ID_MEOW, JRE_ID_MEOW_LEGACY } from '../common/constants/Paths';

/**
 * 一套随包 JRE 的展示名（id → string 资源）。**UI 层唯一的「JRE id → 文案」映射点**：
 * 「编辑版本」面板的 Java 环境下拉与「Java 环境」区块共用，避免两处口径漂移。
 * 认不出的 id 退原文（**不静默换标签**）。
 */
export function javaRuntimeLabel(id: string): ResourceStr {
  if (id === JRE_ID_MEOW) {
    return $r('app.string.java_env_modern');
  }
  if (id === JRE_ID_MEOW_LEGACY) {
    return $r('app.string.java_env_legacy');
  }
  return id;
}
