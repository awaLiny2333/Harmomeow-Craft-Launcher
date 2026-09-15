import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_NOT_FOUND, SOURCE_OFFICIAL, TYPE_RELEASE, TYPE_SNAPSHOT,
  neoforgeBmclListUrl, neoforgeInstallerUrl, neoforgeOfficialListCandidates
} from '../constants/DownloadContract';
import { fetchText } from './Downloader';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'NeoForgeVersionList';

/**
 * NeoForge（mod loader）**版本列表**数据层（纯逻辑，无 UI / 无落盘）。
 *
 * 支持范围：**MC 1.20.2+**（制品 `net.neoforged:neoforge`；1.20.1 及更早的 `forge` 制品不做）。
 * 依据：真 installer 实测 + HMCL 实现，见 notes `20-design/launch/NeoForge支持-调研.md` §1。
 *
 * 两条源的形状**不同**（这是 NeoForge 与 Fabric 最大的差别）：
 *  - **官方**：`/api/maven/versions/releases/net/neoforged/neoforge` → `{isSnapshot, versions:[裸版本号]}`
 *    ⇒ MC 版本必须由 loader 版本号**破解**（{@link mcVersionOfLoaderVersion}）；
 *  - **BMCLAPI**：`/neoforge/list/{mc}` → 数组，条目**直接带 `mcversion`**，无需破解。
 */

/** 官方版本列表 API 的响应形状。 */
interface NeoForgeOfficialApiJson {
  isSnapshot?: boolean;
  versions?: string[];
}

/** BMCLAPI 列表条目（只认这两个字段，其余为站点内部噪声）。 */
interface NeoForgeBmclEntryJson {
  version?: string;
  mcversion?: string;
}

/** loader 版本号是否快照/预发布（对齐 HMCL：仅按字符串含 beta/alpha 判定）。 */
function isSnapshotLoader(loaderVersion: string): boolean {
  const v = loaderVersion.toLowerCase();
  return v.includes('beta') || v.includes('alpha');
}

/**
 * 从 loader 版本号「破解」MC 版本（规则对齐 HMCL `NeoForgeOfficialVersionList.refreshAsync`）。
 *
 * | loader | MC |
 * |---|---|
 * | `21.1.250` | `1.21.1` |
 * | `21.0.167` | `1.21` |
 * | `20.4.237` | `1.20.4` |
 * | `26.1.2.109` | `26.1.2` |
 * | `0.25w14craftmine.3-beta` | `25w14craftmine` |
 * | `26.1.2+snapshot-1` | `26.1.2-snapshot-1` |
 *
 * 无法解析时返回空串（调用方跳过该条）。
 */
export function mcVersionOfLoaderVersion(loaderVersion: string): string {
  let base = loaderVersion;
  let plus = '';
  const plusIndex = loaderVersion.indexOf('+');
  if (plusIndex >= 0) {
    base = loaderVersion.substring(0, plusIndex);
    plus = loaderVersion.substring(plusIndex + 1);
  }
  const parts = base.split('.');
  const segNum = (i: number): number => {
    const t = i < parts.length ? parts[i] : '';
    const n = parseInt(t, 10);
    return Number.isNaN(n) ? -1 : n;
  };
  const major = segNum(0);
  if (major < 0) {
    return '';
  }
  let mc = '';
  if (major === 0) {
    // 快照形态（0.x）：MC 版本 = 第二个点段（如 0.25w14craftmine.3-beta → 25w14craftmine）。
    mc = parts.length > 1 ? parts[1] : '';
  } else if (major >= 26) {
    // 26.x 起的新编号：取前三段；第三段为 0 时只取两段。
    if (parts.length < 2) {
      return '';
    }
    mc = (parts.length > 2 && segNum(2) !== 0)
      ? `${parts[0]}.${parts[1]}.${parts[2]}`
      : `${parts[0]}.${parts[1]}`;
  } else {
    // 传统编号：第二段为 0 时取两段（21.0.167 → 1.21），否则三段（20.4.237 → 1.20.4）。
    if (parts.length < 2) {
      return '';
    }
    mc = (segNum(1) !== 0) ? `1.${parts[0]}.${parts[1]}` : `1.${parts[0]}`;
  }
  if (mc.length === 0) {
    return '';
  }
  return plus.length > 0 ? `${mc}-${plus}` : mc;
}

/** loader 版本比较（数值段优先；数字段 > 非数字段）——用于列表「新版在前」排序。 */
export function compareLoaderVersions(a: string, b: string): number {
  const pa = a.split('.');
  const pb = b.split('.');
  const n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const ta = i < pa.length ? pa[i] : '';
    const tb = i < pb.length ? pb[i] : '';
    const na = parseInt(ta, 10);
    const nb = parseInt(tb, 10);
    const aNum = !Number.isNaN(na);
    const bNum = !Number.isNaN(nb);
    if (aNum && bNum) {
      if (na !== nb) {
        return na - nb;
      }
      continue;
    }
    if (aNum !== bNum) {
      return aNum ? 1 : -1;
    }
    if (ta !== tb) {
      return ta < tb ? -1 : 1;
    }
  }
  return 0;
}

/** 一条可安装的 NeoForge 候选。 */
export class NeoForgeRemoteVersion {
  /** loader 版本（= installer 版本，如 `21.1.250`）。 */
  loaderVersion: string;
  /** 对应的 MC 版本（如 `1.21.1`）。 */
  mcVersion: string;
  /** 类型：release / snapshot。 */
  type: string;
  /** installer jar 的**官方**地址（下载时再按下载源展开候选）。 */
  installerUrl: string;

  constructor(loaderVersion: string, mcVersion: string) {
    this.loaderVersion = loaderVersion;
    this.mcVersion = mcVersion;
    this.type = isSnapshotLoader(loaderVersion) ? TYPE_SNAPSHOT : TYPE_RELEASE;
    this.installerUrl = neoforgeInstallerUrl(loaderVersion);
  }
}

/** 拉取结果：把「该版本没有 NeoForge」与「拉取失败」区分开（UI 文案依赖它）。 */
export class NeoForgeListResult {
  /** 可用候选（新版在前）。 */
  versions: NeoForgeRemoteVersion[] = [];
  /** 实际生效的源（空串 = 所有源都没结果/失败）。 */
  sourceUsed: string = '';
  /** 各源的失败摘要（用于区分「没有」与「网络失败」）。 */
  errors: string = '';
}

/** 源名（写入 sourceUsed）。 */
const SOURCE_BMCLAPI: string = 'bmclapi';
const SOURCE_OFFICIAL_NAME: string = 'official';

function errorText(e: object): string {
  const be = e as BusinessError;
  return be.message !== undefined ? `${be.code} ${be.message}` : `${e}`;
}

/** 同源数组内排序：新版在前。 */
function sortNewestFirst(list: NeoForgeRemoteVersion[]): void {
  list.sort((a: NeoForgeRemoteVersion, b: NeoForgeRemoteVersion): number =>
    compareLoaderVersions(b.loaderVersion, a.loaderVersion));
}

/**
 * 拉取指定 MC 版本的 NeoForge 候选列表。
 *
 * 源顺序：非官方源时 **BMCLAPI → 官方**；每个源内部：
 *  - HTTP 4xx ⇒ 由 `fetchText` 判失败（**不解析 body**）→ 继续下一个源；
 *  - HTTP 200 + **空数组** ⇒ 视为「该源无结果」→ 继续下一个源（**不要**直接断定"无可用版本"）。
 *
 * @param mcVersion 当前游戏版本（如 `1.21.1`）。
 * @param source    下载源设置（{@link SOURCE_OFFICIAL} 时为仅官方）。
 */
export async function fetchNeoForgeVersions(mcVersion: string, source: string): Promise<NeoForgeListResult> {
  const result = new NeoForgeListResult();
  if (source !== SOURCE_OFFICIAL) {
    try {
      const text = await fetchText([neoforgeBmclListUrl(mcVersion)],
        [HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_NOT_FOUND]);
      const parsed = JSON.parse(text) as (NeoForgeBmclEntryJson | null)[];
      const out: NeoForgeRemoteVersion[] = [];
      if (Array.isArray(parsed)) {
        for (const entry of parsed) {
          if (entry === null || entry.version === undefined || entry.version.length === 0) {
            continue;
          }
          const mc = (entry.mcversion !== undefined && entry.mcversion.length > 0)
            ? entry.mcversion
            : mcVersionOfLoaderVersion(entry.version);
          if (mc !== mcVersion) {
            continue;
          }
          out.push(new NeoForgeRemoteVersion(entry.version, mc));
        }
      }
      if (out.length > 0) {
        sortNewestFirst(out);
        result.versions = out;
        result.sourceUsed = SOURCE_BMCLAPI;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'bmclapi list ok: %{public}d items for %{public}s',
          out.length, mcVersion);
        return result;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'bmclapi list empty for %{public}s, try official', mcVersion);
    } catch (e) {
      result.errors += `bmclapi: ${errorText(e)}; `;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'bmclapi list failed: %{public}s', errorText(e));
    }
  }

  try {
    const text = await fetchText(neoforgeOfficialListCandidates());
    const api = JSON.parse(text) as NeoForgeOfficialApiJson;
    const list = (api.versions !== undefined && Array.isArray(api.versions)) ? api.versions : [];
    const out: NeoForgeRemoteVersion[] = [];
    for (const v of list) {
      if (typeof v !== 'string' || v.length === 0) {
        continue;
      }
      // 官方只给裸版本号：必须破解出 MC 版本，再只留当前游戏版本的条目。
      if (mcVersionOfLoaderVersion(v) !== mcVersion) {
        continue;
      }
      out.push(new NeoForgeRemoteVersion(v, mcVersion));
    }
    if (out.length > 0) {
      sortNewestFirst(out);
      result.versions = out;
      result.sourceUsed = SOURCE_OFFICIAL_NAME;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'official list ok: %{public}d items for %{public}s',
        out.length, mcVersion);
    }
  } catch (e) {
    result.errors += `official: ${errorText(e)}; `;
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'official list failed: %{public}s', errorText(e));
  }
  return result;
}
