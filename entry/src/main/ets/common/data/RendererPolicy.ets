import { RENDERER_LIB, RENDERER_ENV, RENDERER_LIB_GL4ES,
  RENDERER_ENV_GL4ES } from '../constants/LaunchDefaults';

/**
 * 渲染后端选择（按 MC 版本），单一事实源。
 *
 * 两端的分派是同一个阈值（1.17）：
 * - **≤1.16**：MC 用固定管线 GL → 走 **gl4es**（自编，桌面 GL→原生 GLES 翻译层）。
 *   gl4es 在 GLES context 上仿真固定管线，绕开系统 `libGLv4.so`（Mesa Zink）compat 路径的
 *   渲染错乱。此路径下 `glProfile` 无意义（桥走 GLES 分支），仍传 `compat` 以保持桌面回落行为。
 * - **≥1.17**：MC 用 core-profile 渲染器 → 走系统桌面 GL `libGLv4.so`（Zink），`glProfile=core`。
 *
 * 版本号形如 `1.16.5` / `1.21.10` / `26.1.2`（取前两段做阈值判断）。
 */
export class RendererChoice {
  /** 传给 `-Dorg.lwjgl.opengl.libname`，也是桥预 dlopen 的目标（两者必须一致）。 */
  lib: string;
  /** `MEOWCRAFT_RENDERER`：桥据此决定建桌面 GL 还是 GLES+gl4es 上下文。 */
  env: string;
  /** `MEOWCRAFT_GL_PROFILE`：仅桌面 GL 路径使用（core / compat）。 */
  glProfile: string;

  constructor(lib: string, env: string, glProfile: string) {
    this.lib = lib;
    this.env = env;
    this.glProfile = glProfile;
  }
}

/** 版本是否 legacy（<1.17，用固定管线 GL，需 compatibility profile）。 */
function isLegacyVersion(versionId: string): boolean {
  const m: RegExpMatchArray | null = versionId.match(/^(\d+)\.(\d+)/);
  if (m !== null) {
    const major = parseInt(m[1]);
    const minor = parseInt(m[2]);
    return major < 1 || (major === 1 && minor < 17);
  }
  return false;
}

export function rendererForVersion(versionId: string, backend: string): RendererChoice {
  // GL profile 永远按版本判定：<1.17 用固定管线必须 compatibility，≥1.17 用 core。
  // 「后端」覆盖只切换 lib/env，不改变 profile 语义（否则 1.16.5 选 OpenGLv4 会被 core 拒而崩）。
  const legacy = isLegacyVersion(versionId);
  const glProfile = legacy ? 'compat' : 'core';
  if (backend === RENDERER_ENV_GL4ES) {
    return new RendererChoice(RENDERER_LIB_GL4ES, RENDERER_ENV_GL4ES, glProfile);
  }
  if (backend === RENDERER_ENV) {
    return new RendererChoice(RENDERER_LIB, RENDERER_ENV, glProfile);
  }
  // auto（推荐）：≤1.16 走 gl4es，≥1.17 走系统桌面 GL。
  return legacy
    ? new RendererChoice(RENDERER_LIB_GL4ES, RENDERER_ENV_GL4ES, glProfile)
    : new RendererChoice(RENDERER_LIB, RENDERER_ENV, glProfile);
}
