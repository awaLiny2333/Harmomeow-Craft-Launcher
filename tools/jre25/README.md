# tools/jre25 — 魔改官方 OpenJDK(glibc) 跑 OHOS(musl)，产出随包 JRE

把**官方 OpenJDK 25.0.2（Linux/aarch64，glibc）**改造成能在 **OHOS(musl)** 上加载运行的 JRE 集，
替换原先「外部预编译 OHOS JRE 黑箱」。目标：随包 JRE 的每个 `.so` 都**可复现、可溯源**。

> 现状（2026-09-12，实机 MC 可玩）：**官方 26 lib（原地改 `.dynstr`）+ `libc6.so` 兼容层 +
> 自编 `libjli` + 自编 `libjvm` + 官方 25.0.2 数据（jlink 瘦身）**。
> **零黑箱**：随包 JRE 每个 `.so` 都可由本目录配方复现（`libjvm` 在 openEuler 容器里编，见 §4；数据瘦身见 §5）。

## 为什么可行（关键取证）

| 事实 | 结论 | 取证 |
|---|---|---|
| 官方件 `release` `LIBC=gnu`；OHOS 只有单一 musl `libc.so` | 需兼容层补 glibc 缺失符号 | `release` + `readelf -d` |
| OHOS loader（`/lib/ld-musl-aarch64.so.1`）**不解析 ELF 符号版本** | 251 个 `@GLIBC_2.17` 引用按**名字**解析，无需 gcompat 全套 | loader 反汇编无 `DT_VERSYM/VERNEED` 常量；无 glibc 式版本错误串 |
| `ucontext_t`/`sigcontext`/`struct stat`/`sigjmp_buf` 布局 glibc==musl(aarch64) | HotSpot 信号/safepoint **无 ABI 墙** | 官方 `ucontext_get_pc` 偏移 `#440/#432/#416` == musl 头 dump |
| 官方 `libjli`/`libjvm` **无** `OHOS_JAVA_HOME`/`OHOS_DL_DIR` | 官方 libjli 靠 `/proc/self/exe` + `/lib/`、`/bin/` 标记推 JRE 路径；OHOS 是 `.../meowjre25/libs/arm64/`（`libs`≠`lib`）→ 推不出 → `could not find libjava.so` | 反汇编 + 实机日志 |

## 溯源（来源 · 钉版 · 一致性）

### 外部输入
| 输入 | 来源 | 钉版 / sha256 |
|---|---|---|
| 官方 OpenJDK **25.0.2**（Linux/aarch64 **glibc**） | **https://jdk.java.net/archive/** | `openjdk-25.0.2_linux-aarch64_bin.tar.gz`；sha256 `671208d205e70c9805da45a483f670d49dd64654990a7b7223ccffb2abb070dd`；`release` = `25.0.2+10-69` |
| OpenJDK 源码 | https://github.com/openjdk/jdk | `jdk-25-ga` tag → commit `6c48f4ed707bf0b15f9b6098de30db8aae6fa40f`（自编 `libjli`+`libjvm` 同用） |

- 官方 tar 同时用作**容器里的 boot JDK**（glibc/aarch64，openEuler 可直接跑）。
- 可选精配：`jdk-25.0.2+10` tag（容器联网 `git fetch`）；当前产物基于 `jdk-25-ga`（25.0.0，同 feature release，与官方 25.0.2 数据接口兼容）。

### 构建环境（容器）
`libjvm` 在用户提供的 **openEuler 容器**里原生编（设备本身不能执行编译产物，见 §坑）：

| 项 | 值（2026-09-12 实测快照） |
|---|---|
| OS | openEuler **24.03 LTS-SP1**，arch **aarch64**，kernel **6.6.0** |
| 编译器 | gcc / g++ **12.3.1-67.oe2403sp1** |
| 构建工具 | make **4.4.1-2**、autoconf **2.71-9**、automake **1.16.5-8**、m4 **1.4.19-5**、binutils(ld) **2.41-28** |
| C 库 | glibc **2.38-47** |
| 运行时 | python3 **3.11.6**、perl **5.38.0**、pkg-config、curl、git |
| boot JDK | 官方 **25.0.2+10-69**（`build 25.0.2+10-69`） |
| 额外 dnf 依赖 | alsa-lib-devel 1.2.10-5、cups-devel 2.4.7-15、fontconfig-devel 2.15.0-1、freetype-devel 2.13.2-5、libX11-devel 1.8.7-3、libXext-devel 1.3.5-1、libXrender-devel 0.9.11-1、libXtst-devel 1.2.4-2、libXi-devel 1.8.1-1、libXrandr-devel 1.5.4-1、libXinerama-devel 1.1.5-1、libXcursor-devel 1.2.1-2、xorg-x11-proto-devel 2023.2-1、libXt-devel 1.3.0-2、libXmu-devel 1.1.4-2、libXpm-devel 3.5.17-2 |
| **必须** | **`libstdc++-static` 12.3.1-67**（否则 `libjvm` 动态链 `libstdc++`/`libgcc_s`，OHOS 没有） |
| 装法 | `sh tools/jre25/linux_bootstrap.sh`（内含 `dnf -y install …`）；复核对齐用 `linux_env_snapshot.sh` |

> 上表为实测快照；换机器/换时间复现时，先跑 `sh tools/jre25/linux_env_snapshot.sh` 核对（版本一致才谈逐字节一致）。

### 可复现性（逐字节，2026-09-12 实测）

| 产物 | 结论 | 方法 |
|---|---|---|
| 官方 26 lib（魔改后） | ✅ **逐字节** | `patch_dynstr.py` 原地等长改写；抽样 5 件 2× `cmp` 一致 |
| `libc6.so` | ✅ **逐字节** | `build_shim.sh` **3× 干净重建 + `cmp`** 一致 |
| `libjli.so` | ✅ **逐字节** | `build_libjli_ohos.sh` **3× 干净重建 + `cmp`** 一致 |
| `meow_jre25.tar.gz` | ✅ **逐字节** | `pack_jre_data.py` 规范化打包（排序 / mtime=0 / uid=gid=0 / gzip mtime=0）；2× `cmp` 一致 |
| `libjvm.so`（容器编） | ✅ **逐字节** | `SOURCE_DATE_EPOCH=1755018936` + 固定 `$WORK`；`linux_verify_jvm_repro.sh` **3× `cmp` 一致**（未魔改 glibc 件 sha `3dc51cd9…`） |

- **路径必须规范（前提）**：产物会嵌入**源码路径**（如 `libjli` 内嵌 `.../jdk25src/src/...`）与部分 native 的**输出路径**（写进 `.dynstr`）→ 必须用**同一绝对路径**，否则同功能、哈希不同。`build_libjli_ohos.sh` 已把 `--src` 规范化成绝对路径（相对/绝对调用结果一致）。
- 打包数据**必须**用 `pack_jre_data.py`（toybox/GNU `tar czf` 的 mtime/顺序不定）。
- `libjvm` 若 3× 不一致：再关链接器 BuildID、去 `-g`（见 `linux_verify_jvm_repro.sh` 提示）。

## 文件

| 文件 | 作用 |
|---|---|
| `rebuild_for_meowcraft.sh` | **入口**：组装整套 JRE 集（调下面各步）+ 打印随包步骤 |
| `build_shim.sh` / `glibc_compat.c` | 兼容层 `libc6.so`（约 40 个 glibc 缺失符号；**无版本**导出） |
| `patch_dynstr.py` | **原地**改 ELF `.dynstr` 的 NEEDED 名（**不用 patchelf**） |
| `assemble_jre.sh` | 把官方 26 lib 逐个 `patch_dynstr.py` 后装入输出目录 |
| `build_libjli_ohos.sh` | 从 JDK25 源**独立编译** `libjli.so`（无 boot JDK） |
| `patches/libjli-ohos.patch` | libjli OHOS 分体 patch（见 §3） |
| `patches/os_linux-ohos.patch` | HotSpot 分体 patch（`java.home`/`dll_dir` 认 `OHOS_JAVA_HOME`/`OHOS_DL_DIR`，见 §4） |
| `linux_bootstrap.sh` / `linux_build_jvm.sh` | **容器内**：装工具链 + boot JDK + 原生编 `libjvm.so`（见 §4） |
| `linux_env_snapshot.sh` | **容器内**：打印精确环境版本（供溯源/一致性核对） |
| `linux_slim_jre.sh` | **容器内**：`jlink` 按原 HOML 模块集裁 `lib/modules`（见 §5） |
| `linux_verify_jvm_repro.sh` | **容器内**：3× 干净重建 `libjvm` + `cmp`（验逐字节复现） |
| `pack_jre_data.py` | **确定性**打包 `home` → `meow_jre25.tar.gz`（排序 / mtime=0 / uid=gid=0 / gzip mtime=0） |
| `verify_symbols.py` | 符号满足性自检（GLOBAL 未定义 vs 提供者集合） |

## 复现（端到端）

```sh
# 0) 外部输入（见「溯源」）
#    官方 JDK25 tar（jdk.java.net/archive）→ stuffs/research/jdk25/
#    OpenJDK 源码：git clone https://github.com/openjdk/jdk → stuffs/research/jdk25/jdk
tar xzf stuffs/research/jdk25/openjdk-25.0.2_linux-aarch64_bin.tar.gz -C stuffs/research/jdk25/_inspect
git -C stuffs/research/jdk25/jdk worktree add stuffs/research/jdk25/jdk25src jdk-25-ga

# 1) 容器（openEuler 24.03 aarch64；环境见「构建环境」）—— 编 libjvm + 瘦 modules
sh tools/jre25/linux_bootstrap.sh         # 装工具链 + boot JDK
sh tools/jre25/linux_build_jvm.sh         # → out-linux/libjvm.so（glibc；SOURCE_DATE_EPOCH 固定）
sh tools/jre25/linux_verify_jvm_repro.sh  # （可选）3× cmp 验 libjvm 逐字节可复现
sh tools/jre25/linux_slim_jre.sh          # → out-linux/modules.slim（jlink）

# 2) 宿主 —— 组装（魔改 26 官方件 + 自编 libc6/libjli + 魔改自编 libjvm + 数据瘦身）
sh tools/jre25/rebuild_for_meowcraft.sh \
    --official-jdk stuffs/research/jdk25/_inspect/jdk-25.0.2 \
    --jdk-src      stuffs/research/jdk25/jdk25src \
    --libjvm       stuffs/research/jdk25/out-linux/libjvm.so \
    --modules-slim stuffs/research/jdk25/out-linux/modules.slim \
    --out          stuffs/research/jdk25/out
#   （rebuild 会对 --jdk-src 打 patches/libjli-ohos.patch 后自编 libjli；对 --libjvm 跑魔改）

# 3) 随包（工程内）
cp stuffs/research/jdk25/out/*.so libs/meowjre25/libs/arm64-v8a/
python3 tools/jre25/pack_jre_data.py --home stuffs/research/jdk25/out/home \
    --out entry/src/main/resources/rawfile/meow_jre25.tar.gz
rm -rf libs/meowjre25/build entry/build && devecocli build --modules entry meowjre25

# 4) 部署：先 HSP 后 HAP；改 JRE 后须卸载/清数据让 meow_jre25.tar.gz 重新解压
```

### digests（2026-09-12 实测，sha256）
| 对象 | sha256 |
|---|---|
| 官方 JDK tar | `671208d205e70c9805da45a483f670d49dd64654990a7b7223ccffb2abb070dd` |
| 自编 glibc `libjvm.so`（未魔改） | `3dc51cd9c4084a49eef3b691db3e4e6bcf2a8928b25fda85b1a84c14da242685` |
| 随包 `libjvm.so`（魔改后） | `67d8652ebea1873ece752a845364013d49b8ca7e33eb2b4949cd8863584f0fed` |
| 随包 `libc6.so` | `46e1038190324c24b845b3a547cae29fa6e75efcdc5a3c217810eebefd8fdd6f` |
| 随包 `libjli.so` | `ec653f89c5970b752746a5015d23d49f28df630e94296b3737e5cb12679320c6` |
| `modules.slim`（jlink 产物，44 模块） | `014b3bdb85b77983b95101b12b33e6e3f988b22c094a9eff69a625f92ac769fb`（39.4 MiB） |
| 随包数据 tar（`pack_jre_data.py` 规范化） | `6c21f9a0e0e72bd75df5e4ce876cac953118e5b2e37e9c131d622f50c9a21b08`（38.0 MiB） |
| HAP（本次 debug 签名） | `be75fd5d8e98bf1dd277706743836b455d83f87e9b73a6cfb6d73ebef4cdd33b` |
| HSP（本次 debug 签名） | `aaa250bdb049d4c81725c5514881c0d487f2095f44e86d500080d7bb61f123f0` |

> HAP/HSP 含签名材料 → 随签名变化；上表为本次 debug 签名的参考值。其余件与签名无关。

## 三块机制

### 1) 兼容层 `libc6.so`（`glibc_compat.c`）
官方 glibc 件相对 OHOS musl 缺一批符号（libjvm 22 个；跨全部 lib 去重后 libc 级 ≈25；最终 shim 导出 37 个），`libc6.so` 补齐：多为别名
（`__strdup→strdup`、`__strtok_r→strtok_r`、`__getdelim→getdelim`、`__pthread_key_create→pthread_key_create`、
`__isinf/__isnan/__isnanf`、`__rawmemchr`、`__xmknod`、`__xpg_strerror_r`、`__sigsetjmp→sigsetjmp`），
少数需实现（`__ctype_b/tolower/toupper_loc` 三张 glibc 布局表、`__xstat64/__lxstat64/__fxstat64` 直通、
`dlinfo`/`malloc_trim`/`getutxent`/`setutxent`/`secure_getenv`/`__getauxval`/`__sched_cpufree` 桩）。
**导出为「无版本」符号**（与 musl libc 自身一致）：OHOS musl 对「有版本号的导出」会做**版本匹配**——
自编件引用 `__isoc23_fscanf@GLIBC_2.38` 等较新版本，若 shim 导成 `@@GLIBC_2.17` 会不匹配 → `symbol not found`。
**自编 `libjvm` 额外需要**（已加）：`__environ`/`_environ`、`__sysconf`、`__libc_single_threaded`、
`__isoc23_{strtol,strtoll,strtoull,sscanf,fscanf,vsscanf}`、`_dl_find_object`、`__cxa_thread_atexit_impl`（自实现 per-thread LIFO）、`fcntl64`。

### 2) 原地改 `.dynstr`（`patch_dynstr.py`）——**禁用 patchelf**
把官方件的 NEEDED 名原地改短（新名 ≤ 旧名，覆盖 + 补 `\0`，**文件尺寸/偏移全不变**，
NEEDED 与 VERNEED 共用同一 `.dynstr` 偏移 → 一处替换两者同步）：

| 旧 | 新 | 说明 |
|---|---|---|
| `libc.so.6` | `libc6.so` | **= 兼容层**（既满足依赖，又把 shim 注入每个 lib） |
| `ld-linux-aarch64.so.1` | `libc6.so` | OHOS 无 glibc 解释器 |
| `libpthread.so.0` / `libdl.so.2` / `librt.so.1` / `libm.so.6` | `libc.so` | musl 全并入 libc |
| `libz.so.1` | `libz.so` | 系统 zlib |
| `libfreetype.so.6` | `libfreetype.so` | 自编 freetype（`tools/freetype/`） |

### 3) 自编 `libjli`（`build_libjli_ohos.sh` + `patches/libjli-ohos.patch`）
从 JDK25 源独立编（9 个 C 文件，链接 `-lz`；生成 `classfile_constants.h`，major=69）。
OHOS 分体 patch（3 处）：
- `GetJDKInstallRoot`：`OHOS_JAVA_HOME` 非空 → 直接作为 java.home（跳过 `libjava.so` 存在性检查）；
- `GetJVMPath`：`OHOS_DL_DIR` 非空 → `jvmpath = $OHOS_DL_DIR/libjvm.so`（扁平 el1 目录）；
- `CreateExecutionEnvironment`：有 `OHOS_*` → **直接 return**（OHOS 不能 `execve` 重入；`LD_LIBRARY_PATH` 由宿主预置）。

### 4) 自编 `libjvm`（容器 openEuler，`linux_*.sh` + `patches/os_linux-ohos.patch`）
设备上**不能执行编译产物**（可写路径 ELF `EPERM`）→ 借用户 **openEuler 24.03 aarch64 容器**（挂载宿主工作区 `/mnt/linux_share`）**原生构建**：
1. `linux_bootstrap.sh`：`dnf` 装 gcc/make/autoconf + 桌面依赖（alsa/cups/fontconfig/freetype/X11 全套，含 `libXt-devel`）+ **`libstdc++-static`**；解**官方 JDK25(glibc/aarch64)** 当 boot JDK（容器里能直接跑）。
2. `linux_build_jvm.sh`：取干净源（挂载 clone 的 `jdk-25-ga`，或 fetch `jdk-25.0.2+10`）→ 打 `patches/os_linux-ohos.patch` → `configure --with-stdc++lib=static` → `make hotspot` → 拷 `libjvm.so` 回共享目录。
3. 宿主侧：`patch_dynstr.py` 魔改（NEEDED→`libc.so`/`libc6.so`）→ 装进 JRE。
- **必须 `--with-stdc++lib=static`**：否则 NEEDED 带 `libstdc++.so.6`/`libgcc_s.so.1`（OHOS 没有）。
- HotSpot 分体 patch（`os_linux.cpp` 2 处）：`java.home` 认 `OHOS_JAVA_HOME`、`dll_dir` 认 `OHOS_DL_DIR`（上游假设 `lib/<variant>/` 会**多剥一层** `arm64` → `Failed setting boot class path` / `Unable to load jimage library`）。

### 5) 数据瘦身（`linux_slim_jre.sh` + 裁 `bin/`）
官方**完整 JDK 数据**（49.5 MiB tar / 61 文件，含全 `bin/` + 136.8 MiB modules）远超 MC 所需 → 瘦到 **38.0 MiB / 37 文件**（≈原 HOML 的 37.8 MiB）：
1. **`lib/modules`**：容器里用官方 JDK 的 `jlink` 按**原 HOML 模块集**裁（**45 个再剔除 `jdk.crypto.cryptoki`**，因其 native `libj2pkcs11` 已删，保留会不一致）+ `--compress=zip-6`（`linux_slim_jre.sh`）→ 大幅缩小（约 39 MiB）。
2. **`bin/`**：只留 `java keytool jfr jrunscript rmiregistry jwebserver`（30 → 6）。
- **数据门（防混合）**：`Install` 解压后写 `<installDir>/meow_jre_data`（令牌 `25.0.2+10-69-r2`）；ArkTS `Paths.JRE_DATA_TOKEN`/`JavaEnvScanner` 同步校验；令牌不符 → 未就绪 + `Install` 清目录重解压。**⚠️ 改随包 JRE 数据的任何内容（模块集/文件）都必须同步升令牌**（native `kJreDataToken` + ArkTS `JRE_DATA_TOKEN`），否则用户会沿用旧数据。
  - **UI**：app 区分 **须升级**（有数据但令牌不符 → 显示「升级」+ 令牌 旧→新）vs **未解压**（显示「解压」）；须升级时**禁用所有版本的「启动」**（防用混合 JRE 跑游戏）。
- 模块集 = 原 HOML（已知 MC 1.6.x–26.3 可用）；**实机验证可玩（2026-09-12，含瘦身后）**。
- 收益：数据 tar 49.5→38.0 MiB；HAP 81.7→**66.8 MB**、HSP 53.0→**45.7 MB**。

## 校验（2026-09-12）

| 项 | 值 |
|---|---|
| 符号满足性 `verify_symbols.py` | **PASS**（全部 lib 的 GLOBAL 未定义符号被 libc∪本集∪libz∪libc++_shared∪freetype 满足） |
| 兼容层 `libc6.so` | **无版本**导出；符号满足性 PASS |
| 自编 `libjli.so` | NEEDED=`libz.so`+`libc.so`；导出 ⊇ 现役件 |
| 自编 `libjvm.so`（容器编，glibc） | 26.7MB；魔改后 NEEDED=`libc.so`+`libc6.so`×2；符号满足性 PASS |
| 数据瘦身 | tar 49.5→**38.0 MiB**（37 文件）；`lib/modules` 136.8→**39.4 MiB**（44 模块） |
| 实机 | **MC 可玩**（用户实测 2026-09-12，含瘦身后；1.7.10 / 26.3 等）；VM 横幅正常 |

## 坑（务必记住）

- **禁用 patchelf**：`--replace-needed libc.so.6`（该名有 VERNEED 条目）+ `--add-needed` 会让 patchelf
  **重排文件并用 `X` 填充**（76K→331K），OHOS loader 把符号名读进填充区 → `Error relocating …: XXXX…`。
  必须**原地改 `.dynstr`**。见记忆 `meowcraft_glibc_neededs_inplace_not_patchelf`。
- **shim 必须「无版本」导出**：见 §1。有版本号会被 musl 的版本匹配拒绝（`symbol not found`）。
- **HotSpot 也要分体 patch**（`libjli` 不够）：`java.home` 认 `OHOS_JAVA_HOME`、`dll_dir` 认 `OHOS_DL_DIR`，
  否则 `Failed setting boot class path` / `Unable to load jimage library`。见 §4。
- **容器构建用 `--with-stdc++lib=static`**：否则 NEEDED 带 `libstdc++.so.6`/`libgcc_s.so.1`（OHOS 没有）。
- **设备不能执行编译产物**：用户可写路径 ELF `EPERM` → 需运行编译产物的构建只能在容器/Linux 跑。
- **OHOS 分体布局**：`.so` 必须在 **el1**（随包）；数据区（el2）`dlopen` 一律失败。故 `libjli`/`libjvm` 必须认
  `OHOS_DL_DIR`/`OHOS_JAVA_HOME`（官方件不认）。
- **hvigor 不追踪 `libs/<abi>/` 增删**：改后必须清模块 build 再 `build --modules entry meowjre25`。
- **JRE 解压幂等**：`installJre` 以 `lib/modules` 是否存在为准，换数据 tar 后须**卸载/清数据**才会重解压。
- **剔除** `libjawt.so`（只需 X11 的 `awt_*`）、`libawt_xawt`/`libjsound`/`libsplashscreen`（X11/ALSA）、
  `libj2pkcs11`（PKCS#11 智能卡）/`libattach`（Attach API 工具）/`libj2pcsc`（PC/SC 智能卡）、
  `libsaproc`（SA）/`libsleef`（SIMD 数学，官方 libjvm 未 NEEDED）——**MC/JVM 运行不用，保持最小可用**。

> **容器脚本调用约定**：所有 `linux_*.sh` 只在**容器内**跑；默认挂载根 `MEOW_SHARE=/mnt/linux_share/Documents/Meow/…/Meowcraft`、构建目录 `MEOW_WORK=$HOME/meow-jvm`，可用环境变量覆盖。**可复现要求固定绝对路径**：`libjli` 的 `--src`（默认 `…/stuffs/research/jdk25/jdk25src`）、`libjvm` 的 `$WORK` 与源 tag（默认 `jdk-25-ga`）。

## 未完成 / 下一步

**（无）——全收编完成，零黑箱。**
可选精修：`libjvm`/`libjli` 现基于 `jdk-25-ga`（25.0.0）；如需与官方数据 **25.0.2** 精确对齐，可用 `jdk-25.0.2+10` 源重编
（`linux_build_jvm.sh` 已优先尝试该 tag，需容器联网 `git fetch`）。

## 相关

- notes：`20-design/收编自研路线与交接.md` §候选 C、`00-current/已知限制与待解.md` §D
- 同族工具：`tools/freetype/`（`libfreetype.so`）；~~`tools/slim_jre_data.py`~~ **已废弃**（改用 `pack_jre_data.py` + `linux_slim_jre.sh`）
- 主索引：`tools/README.md`
