import { RENDERER_LIB, RENDERER_ENV, RENDERER_LIB_GL4ES,
  RENDERER_ENV_GL4ES } from '../constants/LaunchDefaults';

/**
 * 渲染后端选择（按 MC 版本），单一事实源。
 *
 * 两端的分派是同一个阈值（1.17）：
 * - **≤1.16**：MC 用固定管线 GL → 走 **gl4es**（自编，桌面 GL→原生 GLES 翻译层）。
 *   gl4es 在 GLES context 上仿真固定管线，绕开系统 `libGLv4.so`（Mesa Zink）compat 路径的
 *   渲染错乱。此路径下 `glProfile` 无意义（桥走 GLES 分支），仍传 `compat` 以保持桌面回落行为。
 * - **≥1.17**：MC 用 core-profile 渲染器 → 走 **GL guard**（`libmeowglguard.so`，透传到系统桌面 GL
 *   `libGLv4.so`/Zink；guard 对 `glTexSubImage2D` 加后置同步以规避 Mesa glthread UAF），`glProfile=core`。
 *
 * ⚠️ 传入的 `mcVersion` 必须是**解析继承/补丁后的真 MC 版本号**（`MinecraftLauncher.readVersionId()` 的产出，
 * 如 `1.16.5`/`1.21.10`/`26.1.2`；Fabric 实例也会解析回基座版本），**不是实例名/目录名**——实例名可被玩家任意取
 * （对齐 HMCL），用它判版本会选错后端/profile。
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

/** MC 版本（json 内部 id）是否 legacy（<1.17，用固定管线 GL，需 compatibility profile）。 */
function isLegacyVersion(mcVersion: string): boolean {
  const m: RegExpMatchArray | null = mcVersion.match(/^(\d+)\.(\d+)/);
  if (m !== null) {
    const major = parseInt(m[1]);
    const minor = parseInt(m[2]);
    return major < 1 || (major === 1 && minor < 17);
  }
  return false;
}

/**
 * GL guard 是否需要「每次 glTexSubImage2D 后同步」（= 不给它 `MEOW_GUARD_SYNC=none` 时的默认行为）。
 *
 * 实测（见 notes 20-design/glthread-B方案-GL-guard.md §2.2、§2.4）：
 * - **26.x** 在 glthread 下会因 Mesa 的 glthread UAF（`tc_texture_subdata` 不拷贝客户端数据，
 *   延后到 flush 才读）间歇崩溃（~50%）→ **必须每次同步**；
 * - **≤1.21.x** 从未因它崩过（数十次实机），而 1.21.10 主菜单会以 **~2800 次/秒**的小图上传
 *   （1x1…32x32）把「每次同步」放大成灾难性掉帧 → **必须不同步**（glthread 的收益照拿）。
 * 认不出/更老的版本 → 保守返回 true（同步）。
 */
export function guardNeedsSync(mcVersion: string): boolean {
  // legacy（<1.17）默认走 gl4es、根本不经过守卫；但用户可把后端强制成 OpenGLv4（compat profile）
  // ——那条组合未实测，保守按"要同步"处理（宁可慢，不可崩）。
  if (isLegacyVersion(mcVersion)) {
    return true;
  }
  const m: RegExpMatchArray | null = mcVersion.match(/^(\d+)\.(\d+)/);
  if (m === null) {
    return true;
  }
  const major = parseInt(m[1]);
  const minor = parseInt(m[2]);
  return !(major === 1 && minor <= 21);
}

/** `mcVersion` = 版本 json 的内部 `id`（真 MC 版本号），**不是实例名**。 */
export function rendererForVersion(mcVersion: string, backend: string): RendererChoice {
  // GL profile 永远按版本判定：<1.17 用固定管线必须 compatibility，≥1.17 用 core。
  // 「后端」覆盖只切换 lib/env，不改变 profile 语义（否则 1.16.5 选 OpenGLv4 会被 core 拒而崩）。
  const legacy = isLegacyVersion(mcVersion);
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
