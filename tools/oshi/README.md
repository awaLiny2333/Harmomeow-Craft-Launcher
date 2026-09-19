# oshi 鸿蒙适配工具集

> **目的**：把 oshi（MC 用来读 CPU/内存/系统的库）改成能在鸿蒙沙箱下正确报出 CPU 型号与核数，
> 并随 app 分发（不改用户 `.minecraft`）。
> **设计与结论**（现象/根因/端到端数据流/版本调查表）见
> [`../../../notes/40-adaptation/oshi-cpu-info.md`](../../../notes/40-adaptation/oshi-cpu-info.md)；
> 本目录只放**可执行工具 + 资源来源说明**。

## 0. 一句话流程

```
survey_oshi.py（查 MC↔oshi 版本映射）
  → rebuild_for_meowcraft.sh <oshi版本>...（wrapper → build_oshi_meow.sh：worktree+patch+javac+pack）
  → entry/src/main/resources/rawfile/oshi-overrides/（各版本 jar + manifest.txt）
  → ClasspathStager.applyOshiOverrides()（部署时覆盖 staged jar）
  → F3 显示 20x KirinX90
```

## 1. 本目录内容

| 文件 | 谁写的 | 作用 |
|---|---|---|
| `patch_oshi.py` | **我们** | 结构感知补丁器：改 oshi 的 `LinuxCentralProcessor.java` |
| `build_oshi_meow.sh` | **我们** | 独立通用：逐版本 worktree → patch → javac → pack → 写 manifest（路径全从参数来） |
| `pack_jar.py` | **我们** | 确定性打包：固定时间戳 + 排序条目 → 重建逐字节相同 |
| `rebuild_for_meowcraft.sh` | **我们** | 本项目 wrapper：把本仓库路径填进上面的通用脚本 |
| `survey_oshi.py` | **我们** | 查 BMCLAPI，列出每个 oshi 版本对应哪些 MC 版本 |
| `patch_oshi_legacy.py` | **我们** | **legacy（<3.0，单模块老布局）** 补丁器：改 `oshi/software/os/linux/proc/CentralProcessor.java` + `LinuxHardwareAbstractionLayer.java` |
| `build_oshi_legacy_meow.sh` | **我们** | 独立通用：legacy 版（按 **commit** 而非 tag）→ patch → javac → pack；manifest **就地更新**（不重写） |
| `rebuild_legacy_for_meowcraft.sh` | **我们** | 本项目 wrapper：默认编 **oshi 1.1**（MC 1.16.x 用） |
| `README.md` | **我们** | 本文件 |

## 2. 我们自己写的（源码就在本目录）

### 2.1 `patch_oshi.py`

对 `oshi-core/src/main/java/oshi/hardware/platform/linux/LinuxCentralProcessor.java` 做两处改动：

1. **`queryProcessorId()`**：在 `return new ProcessorIdentifier(cpuVendor, cpuName, ...)`（跨版本稳定锚点）
   之前注入——`-Dmeow.cpu.chip` 非空时用它当 `cpuName`（该属性由 app 从 ArkTS
   `deviceInfo.chipType` 读入）。
2. **`initProcessorCounts()`**：整体包 `try/catch (Throwable)`；失败时用
   `Runtime.getRuntime().availableProcessors()`（尊重 `-XX:ActiveProcessorCount`）造回退拓扑。

**为什么是"结构感知"而不是 `.patch`**：两个补丁点的锚点行随 oshi 版本变化，尤其
`initProcessorCounts()` 的返回类型有 4 种（`List` / `Pair` / `Triplet` / `Quartet`），
补丁器按方法名 + 花括号配对定位，自动识别返回类型并生成对应兜底。

- 输入：`LinuxCentralProcessor.java` 路径（就地修改）。
- 幂等：源码里已有 `meow.cpu.chip` 则跳过。
- 失败即报错退出（锚点缺失 / 返回类型不认识 / 花括号不配对）。

### 2.2 `build_oshi_meow.sh`（独立通用）

**所有路径都从参数传入**，不依赖调用者的目录结构：

```sh
sh build_oshi_meow.sh --oshi-repo DIR --minecraft DIR --cache DIR --out DIR <oshi-version>...
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `--oshi-repo DIR` | ✅ | oshi 的完整 git clone（含 `oshi-parent-<v>` tag） |
| `--minecraft DIR` | ✅ | `.minecraft` 目录；其 `libraries/` 作为依赖 jar 的**只读**首选来源 |
| `--cache DIR` | ✅ | 缺失依赖 jar 的下载 / 复用目录（Maven Central） |
| `--out DIR` | ✅ | 产物目录：`oshi-core-<v>-meow.jar` + `manifest.txt` |
| `--patcher FILE` | ✗ | 补丁脚本（默认 = 本脚本同目录的 `patch_oshi.py`） |

每个版本：

1. `git -C <oshi-repo> worktree add --detach "$PWD/<repo>.build/<v>" oshi-parent-<v>`（取源码；路径须**绝对** —— `-C` 会先 chdir）。
2. 从该 tag 的 `oshi-core/pom.xml` 读 `jna.version` / `slf4j.version`（**老 oshi 必须用它自己
   声明的 JNA**，否则 `Cfgmgr32` 等覆写签名冲突）。
3. 解析依赖 jar：`<minecraft>/libraries` 有就用，没有则从 **Maven Central** 下到 `<cache>`。
4. `patch_oshi.py` → `javac --release 8` → 拷 resources → `pack_jar.py`（确定性打包）。
5. 产物落 `<out>/oshi-core-<v>-meow.jar`，并向 `<out>/manifest.txt` 追加一行
   `<staged jar>=<覆盖件 jar>`。
6. 移除临时 worktree。

- 无需 Maven、无需联网（除非要下依赖）。
- `javac` 需 **JDK 9+**（实测 BiSheng 17，`--release 8`）；打包用 `pack_jar.py`（不再依赖 `jar`）。
- **字节可复现**：相同输入重复构建产出逐字节相同的 jar（`pack_jar.py` 固定条目时间戳 + 排序）。
- 构建期只**只读** `.minecraft` 里的 jar，不写入。

### 2.3 `rebuild_for_meowcraft.sh`（本项目 wrapper）

把本项目的路径填进上面的通用脚本：

```sh
sh tools/oshi/rebuild_for_meowcraft.sh 5.7.4 5.7.5 5.8.2 5.8.5 6.2.2 6.4.5 6.4.10 6.6.5 6.9.0
```

等价于：

```sh
sh tools/oshi/build_oshi_meow.sh \
  --oshi-repo <ws>/ref/oshi --minecraft <ws>/stuffs/.minecraft \
  --cache <ws>/ref/jna-cache --out <proj>/entry/src/main/resources/rawfile/oshi-overrides \
  <versions...>
```

### 2.4 `survey_oshi.py`

```sh
python3 tools/oshi/survey_oshi.py          # 默认 1.17 起
python3 tools/oshi/survey_oshi.py 1.20     # 自定义下界
```

- 数据源：`https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json` + `/version/<v>/json`。
- 输出：每个 oshi 版本一行 + 对应 MC release 列表。
- 用 `curl` 拉数据（本机 python 的 SSL 走本地代理会失败）。

### 2.5 app 侧（ArkTS，非本目录）

| 位置 | 作用 |
|---|---|
| `entry/src/main/ets/common/data/GameLauncher.ets` `readCpuChip()` | `:game` 进程读 `deviceInfo.chipType` |
| `entry/src/main/ets/common/data/MinecraftLauncher.ets` | argv 追加 `-Dmeow.cpu.chip=<值>` |
| `entry/src/main/ets/common/data/ClasspathStager.ets` `applyOshiOverrides()` | 读 manifest，覆盖 staged jar |
| `entry/src/main/ets/common/constants/Paths.ets` | `RAWFILE_OSHI_DIR` / `RAWFILE_OSHI_MANIFEST` |

### 2.6 legacy：oshi 1.1（MC 1.16.x）

> **现状（2026-09-11 实测）**：`rawfile/oshi-overrides/manifest.txt` = **10 项**（现代 9 项 + legacy `oshi-core-1.1`）。
> legacy 覆盖件**只服务 MC 1.16.x**（注意：不是 1.6.x——1.6.x 走 `tools/lwjgl2/` 的 legacy 路径，与本 oshi 覆盖无关）。

MC **1.16.x** 用的是 `oshi-project:oshi-core:1.1`（2015 年），其 **API 与布局与现代 oshi 完全不同**：

- 老 API：`SystemInfo.getHardware()` → `HardwareAbstractionLayer.getProcessors()`（**复数**）→ `Processor.getName()`；
- 老布局：单模块（根 `pom.xml` + `src/main/java/oshi/...`），Linux CPU 实现在
  `oshi/software/os/linux/proc/CentralProcessor.java`（现代布局是 `oshi/hardware/platform/linux/LinuxCentralProcessor.java`）。
- 因此**现代的 9 个覆盖件不能拿来替代 1.1**（缺 `getProcessors()`/`oshi/hardware/Processor` → MC `NoSuchMethodError`）。

问题：aarch64 的 `/proc/cpuinfo` **没有 `model name` 行** → 老 oshi 的 `getName()` 恒为 **null**（F3 显示 `<n>x null`）。

补丁（`patch_oshi_legacy.py`）：
1. `CentralProcessor.getName()` → 有 `-Dmeow.cpu.chip` 时返回它；
2. `LinuxHardwareAbstractionLayer.getProcessors()` → chip 非空时，把处理器数组规整为
   `Runtime.availableProcessors()` 个、名字都设为该 chip（修掉 `21x`）。

**1.1 无 tag，Maven Central 也无该版本** → 用 git **commit** 取源码（默认 `4047d5be65`，2015-01-08，
1.1 版 jar 构建日 2015-01-09 前最近提交）。依赖 **JNA 3.4.0**（`net.java.dev.jna:jna` + `:platform`，本地 `.minecraft` 优先）。

```sh
sh tools/oshi/rebuild_legacy_for_meowcraft.sh        # 默认 ref=4047d5be65 label=1.1
```

> 同现代版：**javac 必须由人跑**；区别是 legacy 脚本 **就地更新 manifest**（不覆盖已有的现代版 9 项）。

## 3. 不是我们写的（来源与获取方式）

| 资源 | 上游 / 来源 | 许可 | 我们怎么得到的 |
|---|---|---|---|
| **oshi 源码** | github.com/oshi/oshi | MIT | `git clone`（含全部 208 个 tag）；构建期用，不随包。本项目 wrapper 放 `ref/oshi`，通用脚本由 `--oshi-repo` 指定 |
| **JNA / jna-platform** | github.com/java-native-access/jna | LGPL-2.1 / Apache-2.0 | 优先取 `.minecraft/libraries`，缺失则从 Maven Central 下到 `--cache` 目录（仅编译 classpath） |
| **slf4j-api** | slf4j.org | MIT | 同上 |
| **MC↔oshi 版本数据** | BMCLAPI（`bmclapi2.bangbang93.com`） | 第三方镜像服务 | `survey_oshi.py` 构建期查询 |
| **`deviceInfo.chipType`** | 鸿蒙 SDK（`@ohos.deviceInfo`） | 平台 API | API 21+，无需权限；C/NAPI `deviceinfo.h` 无此函数 |
| **MC 自带的 oshi jar** | Minecraft（Mojang） | 上游依赖 | 用户 `.minecraft/libraries/.../oshi-core-<v>.jar`；我们只读它当编译 classpath |

> 我们不修改、不重分发上游源码；产出物是"上游源码 + 我们的补丁"的本地编译 jar，随 app 包分发。

## 4. 环境要求

- **JDK 9+**（`javac`）——注意：agent 所在的 shell **跑不了 JVM**（`Failed to mark memory
  page as executable`），所以 Java 编译需在用户的可执行 shell 里跑。打包用 `pack_jar.py`，不需要 `jar`。
- `python3`、`curl`、`git`。
- 网络：Maven Central（下缺失依赖）+ BMCLAPI（查版本映射）；仅构建期需要。
- `--oshi-repo` 指向的 clone 必须是**带 tag 的完整 clone**（`git fetch --tags`）。

## 5. 常用操作

**新增一个 oshi 版本**（比如 MC 用了 oshi 7.0.0）：
1. `git -C ref/oshi fetch --tags`；
2. `sh tools/oshi/rebuild_for_meowcraft.sh 7.0.0`（或直接用通用脚本并显式传 4 个路径）；
3. 产物自动进 `rawfile/oshi-overrides/` + manifest，`devecocli run --module entry` 即可。

**在别的项目/机器上复用**：只带 `patch_oshi.py` + `build_oshi_meow.sh` 两个文件即可，用
`--oshi-repo/--minecraft/--cache/--out` 指向自己的目录，无需任何 Meowcraft 结构。

**更新 MC 版本支持面**：`python3 tools/oshi/survey_oshi.py`，对比 `notes/00-current/版本支持边界.md`，
补编缺的版本。

**排查编译错误**：多为 JNA 签名冲突 → 确认脚本从 tag 的 pom 读到的 `jna.version` 正确，
或删 `ref/jna-cache/<版本>` 重下。

## 6. 验证

- jar 内容：`unzip -p oshi-core-<v>-meow.jar oshi/hardware/platform/linux/LinuxCentralProcessor.class | grep -a meow.cpu.chip`。
- 实机：进游戏按 **F3**，CPU 行应为 `<核数>x <芯片型号>`（如 `20x KirinX90`）。
- 日志：`override oshi-core-<v>.jar <- oshi-overrides/oshi-core-<v>-meow.jar (mem=… staged=…)`。

## 7. 相关

- 设计与根因：[`notes/40-adaptation/oshi-cpu-info.md`](../../../notes/40-adaptation/oshi-cpu-info.md)
- 依赖溯源：[`notes/30-supply-chain/`](../../../notes/30-supply-chain/)
- 历史（patchjna，已归档）：[`notes/90-archive/supply-chain-retired/patchjna-agent.md`](../../../notes/90-archive/supply-chain-retired/patchjna-agent.md)
