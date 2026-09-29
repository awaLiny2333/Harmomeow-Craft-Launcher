import { JAVA_ENV_AUTO } from '../constants/LaunchDefaults';
import { JavaRuntime, BUNDLED_RUNTIMES, defaultRuntime, runtimeById } from './JavaRuntime';
import { LOADER_FORGE } from './VersionResolver';

/**
 * 该用哪套 JRE —— **两张表的 join**，不是版本号 `if`。
 *
 * 表 A「段 → 约束」：只写**有证据**的约束（见下方 REQUIREMENT 的逐条依据）；
 * 表 B「可用 runtime」：每一套自带 `javaMajor`（见 [`JavaRuntime.ets`](JavaRuntime.ets)）。
 * 求解：满足区间 → 取与 preferred 最接近者（同距取更高）⇒ **加一套 JRE 只需在表 B 加一行**，
 * 本文件无需改（除非要新增规则）。
 *
 * 设计上的三条克制（避免"聪明地改变现有行为"）：
 *  1. **默认不改现状**：没有规则命中的组合（香草 / Fabric / NeoForge / 1.17+ 的 Forge）一律
 *     "取最新"⇒ 仍是现代套，与单 JRE 时代完全一致；
 *  2. **约束只写证据支持的**：legacy 段之外不臆断上限；
 *  3. **用户可覆盖**：显式指定 id 时**尊重用户**（但把"与强制约束冲突"写进日志理由，
 *     不静默）；AUTO 才是策略说话的地方。
 */

/** 约束（Java 主版本的闭区间；0 = 该侧不设限）+ 首选 + 人类可读依据。 */
export class JavaRequirement {
  /** 下限（0 = 不设）。 */
  minMajor: number;
  /** 上限（0 = 不设）。 */
  maxMajor: number;
  /** 首选主版本（0 = 无偏好，求解时取"最新"）。 */
  preferredMajor: number;
  /** 依据（进日志 / UI 提示；一句话说清"为什么"）。 */
  reason: string;

  constructor(minMajor: number, maxMajor: number, preferredMajor: number, reason: string) {
    this.minMajor = minMajor;
    this.maxMajor = maxMajor;
    this.preferredMajor = preferredMajor;
    this.reason = reason;
  }
}

/** 选择结果：选中的 runtime + 理由（用于日志自证与 UI 展示）。 */
export class JavaChoice {
  runtime: JavaRuntime;
  /** 为什么选它（进 hilog：`实例 X → JRE Y（理由）`）。 */
  reason: string;

  constructor(runtime: JavaRuntime, reason: string) {
    this.runtime = runtime;
    this.reason = reason;
  }
}

/** MC 版本号（json 内部 id）→ 数值段；认不出返回 null。 */
class McVersion {
  major: number;
  minor: number;
  patch: number;

  constructor(major: number, minor: number, patch: number) {
    this.major = major;
    this.minor = minor;
    this.patch = patch;
  }
}

/** `1.12.2` / `1.7.10` / `26.1.2` / `26.3` → 数值段；认不出 null（调用方保守兜底）。 */
function parseMcVersion(mcVersion: string): McVersion | null {
  const m: RegExpMatchArray | null = mcVersion.match(/^(\d+)\.(\d+)(?:\.(\d+))?/);
  if (m === null) {
    return null;
  }
  return new McVersion(parseInt(m[1]), parseInt(m[2]), m[3] !== undefined ? parseInt(m[3]) : 0);
}

/** `a` 是否 <= `b`（按 major/minor/patch 字典序）。 */
function le(a: McVersion, b: McVersion): boolean {
  if (a.major !== b.major) {
    return a.major < b.major;
  }
  if (a.minor !== b.minor) {
    return a.minor < b.minor;
  }
  return a.patch <= b.patch;
}

/**
 * 表 A：段 → 约束。**每条都必须能指出依据**（HMCL 口径或我们的实测）。
 *
 * 依据台账：
 * - `examples` HMCL `game/JavaVersionConstraint.java:68-107`（Forge 分段）、`:129-140`
 *   （`LAUNCH_WRAPPER ≤1.12.999 → ≤8`，**强制**）、`:179-223`（`MODLAUNCHER_8`
 *   = 1.16.3–1.17.1 + Forge → **≤17**）；`game/GameJavaVersion.java:42-54`（香草下限）。
 * - **我们的实测（2026-09-28，真机三阶段 + 第二轮探针）**：Forge 1.12.2 在 JDK 26 上结构性
 *   不可启动——`LaunchWrapper` 要 ≤13（JDK 14 删 `java.util.jar.Pack200`）、SM 要 ≤23
 *   （JDK 24 禁 SecurityManager）⇒ 该段**必须**落在 Java 8 那一套。
 * - 1.13–1.16.999 段：HMCL 口径为 8、上限 17；我们**未实测**它在现代 JRE 上可行
 *   ⇒ 写"偏好 8、上限 17"（诚实标注为未验，而不是假装强制）。
 */
function requirementFor(mcVersion: string, loader: string): JavaRequirement | null {
  const v = parseMcVersion(mcVersion);
  if (v === null) {
    return null;
  }
  if (loader === LOADER_FORGE) {
    // LaunchWrapper 段（Forge ≤1.12.2）：**强制上限 8**。
    if (le(v, new McVersion(1, 12, 999))) {
      return new JavaRequirement(0, 8, 8,
        'Forge ≤1.12.2 走 LaunchWrapper：需 java.util.jar.Pack200（JDK 14 删）与可用的 SecurityManager（JDK 24 禁）⇒ 上限 8（HMCL 同口径）');
    }
    // ModLauncher/Mixin 段（1.13–1.16.999）：偏好 8，上限 17（HMCL MODLAUNCHER_8）；**未实测**。
    if (le(v, new McVersion(1, 16, 999))) {
      return new JavaRequirement(0, 17, 8,
        'Forge 1.13–1.16.999 走 ModLauncher/Mixin：HMCL 口径为 Java 8（上限 17）；我们在现代 JRE 上未验 ⇒ 偏好 8');
    }
    if (le(v, new McVersion(1, 20, 4))) {
      return new JavaRequirement(16, 0, 17, 'Forge 1.17–1.20.4：HMCL 口径 Java 16/17');
    }
    return new JavaRequirement(21, 0, 21, 'Forge ≥1.20.5：HMCL 口径 Java 21');
  }
  // 香草 / Fabric / NeoForge / 其它：**不设约束**（保持现状：取最新）。
  // 香草下限（HMCL GameJavaVersion：≥1.13→8、≥1.17→16、≥1.18→17、≥1.20.5→21、≥26.1→25）
  // 对"只有现代套"的我们是**恒被满足**的，故不必写成规则（写了也只是噪声）。
  return null;
}

/** 候选是否满足约束。 */
function satisfies(rt: JavaRuntime, r: JavaRequirement): boolean {
  if (r.minMajor > 0 && rt.javaMajor < r.minMajor) {
    return false;
  }
  if (r.maxMajor > 0 && rt.javaMajor > r.maxMajor) {
    return false;
  }
  return true;
}

/**
 * 在候选里挑最合适的一个：
 * 有 preferred ⇒ 取 |major-preferred| 最小者（同距取更高）；无 preferred ⇒ 取最高。
 * 返回 null = 无候选（调用方兜底并告警）。
 */
function pickBest(candidates: JavaRuntime[], preferredMajor: number): JavaRuntime | null {
  if (candidates.length === 0) {
    return null;
  }
  let best: JavaRuntime = candidates[0];
  for (const rt of candidates) {
    if (preferredMajor > 0) {
      const dBest = Math.abs(best.javaMajor - preferredMajor);
      const dRt = Math.abs(rt.javaMajor - preferredMajor);
      if (dRt < dBest || (dRt === dBest && rt.javaMajor > best.javaMajor)) {
        best = rt;
      }
    } else if (rt.javaMajor > best.javaMajor) {
      best = rt;
    }
  }
  return best;
}

/**
 * 解析"本次启动用哪套 JRE"。
 *
 * @param mcVersion 解析继承/补丁后的**真 MC 版本号**（`ResolvedVersion.mcVersion`），不是实例名。
 * @param loader    加载器（`ResolvedVersion.loader`，可为空串/未知）。
 * @param overrideId 用户在该实例设置里的覆盖：`JAVA_ENV_AUTO`（或空串）= 自动。
 */
export function resolveJavaRuntime(mcVersion: string, loader: string, overrideId: string): JavaChoice {
  // ① 用户显式指定：尊重用户；与规则冲突只**记录**，不静默改。
  if (overrideId.length > 0 && overrideId !== JAVA_ENV_AUTO) {
    const picked = runtimeById(overrideId);
    if (picked !== undefined) {
      const req = requirementFor(mcVersion, loader);
      if (req !== null && !satisfies(picked, req)) {
        return new JavaChoice(picked, `用户指定 ${picked.id}（⚠️ 与建议冲突：${req.reason}）`);
      }
      return new JavaChoice(picked, `用户指定 ${picked.id}`);
    }
    // 未知 id（旧设置/手改）：回落自动并说清楚，绝不静默当默认。
    const auto = autoChoice(mcVersion, loader);
    return new JavaChoice(auto.runtime, `设置里的 javaEnv="${overrideId}" 不是已知 JRE ⇒ 回落自动（${auto.reason}）`);
  }
  return autoChoice(mcVersion, loader);
}

/** 自动选择（表 A × 表 B 的 join）。 */
function autoChoice(mcVersion: string, loader: string): JavaChoice {
  const req = requirementFor(mcVersion, loader);
  if (req === null) {
    // 无规则命中：取最新（保持单 JRE 时代行为）。
    const best = pickBest(BUNDLED_RUNTIMES, 0);
    if (best === null) {
      return new JavaChoice(defaultRuntime(), '无随包 JRE（异常）');
    }
    return new JavaChoice(best, `无版本约束 ⇒ 取最新（Java ${best.javaMajor}）`);
  }
  const candidates: JavaRuntime[] = [];
  for (const rt of BUNDLED_RUNTIMES) {
    if (satisfies(rt, req)) {
      candidates.push(rt);
    }
  }
  const best = pickBest(candidates, req.preferredMajor);
  if (best === null) {
    // 无候选（例如将来表 A 的区间比随包 JRE 更严）：兜底现代套并**明说**。
    const fallback = defaultRuntime();
    return new JavaChoice(fallback,
      `⚠️ 无随包 JRE 满足「${req.reason}」⇒ 兜底 ${fallback.id}（Java ${fallback.javaMajor}，可能启动失败）`);
  }
  return new JavaChoice(best, req.reason);
}
