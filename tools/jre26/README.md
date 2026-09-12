# tools/jre26 — 魔改官方 OpenJDK 26(glibc) 跑 OHOS(musl)，产出随包 JRE

把**官方 OpenJDK 26.0.2.1（Linux/aarch64，glibc）**改造成能在 **OHOS(musl)** 上加载运行的 JRE 集。
随包 JRE 的每个 `.so` 都**可复现、可溯源**。

> 现状（2026-09-12，实机 MC 可玩）：**官方 26 lib（原地改 `.dynstr`）+ `libc6.so` 兼容层 +
> 自编 `libjli` + 自编 `libjvm` + 官方 26.0.2.1 数据（jlink 瘦身）**。
> **零黑箱**：随包 JRE 每个 `.so` 都可由本目录配方复现（`libjvm` 在 openEuler 容器里编，见 §4；数据瘦身见 §5）。

> 本目录是 `tools/jre25/` 工序在 **JDK 26** 上的移植（工序检验）。与 25 的差异见 §6。
> **已与官方件精确对齐**：自编件的源 = 官方 26.0.2.1 发布所用的同一 commit（见「溯源」）。

## 为什么可行（关键取证）

| 事实 | 结论 | 取证 |
|---|---|---|
| 官方件 `release` `LIBC=gnu`；OHOS 只有单一 musl `libc.so` | 需兼容层补 glibc 缺失符号 | `release` + `readelf -d` |
| OHOS loader（`/lib/ld-musl-aarch64.so.1`）**不解析 ELF 符号版本** | `@GLIBC_2.x` 引用按**名字**解析，无需 gcompat 全套 | loader 反汇编无 `DT_VERSYM/VERNEED` 常量；无 glibc 式版本错误串 |
| `ucontext_t`/`sigcontext`/`struct stat`/`sigjmp_buf` 布局 glibc==musl(aarch64) | HotSpot 信号/safepoint **无 ABI 墙** | 官方 `ucontext_get_pc` 偏移 == musl 头 dump |
| 官方 `libjli`/`libjvm` **无** `OHOS_JAVA_HOME`/`OHOS_DL_DIR` | 官方 libjli 靠 `/proc/self/exe` + `/lib/`、`/bin/` 标记推 JRE 路径；OHOS 是 `.../meowjre/libs/arm64/`（`libs`≠`lib`）→ 推不出 → `could not find libjava.so` | 反汇编 + 实机日志 |
| JDK26 的 `lib/*.so` 集合与 JDK25 **完全相同**（36 顶层 + `server/libjvm`+`libjsig`） | 保留清单 / `.dynstr` 映射 / 剔除清单**原样沿用** | `ls lib/*.so` 双向 diff |
| JDK26 的 NEEDED 集合与 JDK25 一致（仅计数微差） | `patch_dynstr.py` 的 MAP **无需增改** | 全 lib `readelf -d` 去重 diff |

## 溯源（来源 · 钉版 · 一致性）

### 外部输入
| 输入 | 来源 | 钉版 / sha256 |
|---|---|---|
| 官方 OpenJDK **26.0.2.1**（Linux/aarch64 **glibc**） | **https://jdk.java.net/archive/** | `openjdk-26.0.2.1_linux-aarch64_bin.tar.gz`；sha256 `b96b265a4a1a36c02454148891aa58ca63303cbc2d1b7979c33b4fe99e09117b`；`release` = `26.0.2.1+1-7`（`JAVA_VERSION_DATE=2026-08-18`） |
| OpenJDK 源码（自编 `libjli`+`libjvm` 同用） | **https://github.com/openjdk/jdk26u**（**更新仓**，非主线 `openjdk/jdk`） | tag **`jdk-26.0.2.1-ga`** → commit **`d55edf1cba61219d17565da51cd13a4d425f7c59`** |

- **精确对齐**：官方 tar 的 `release` 写 `SOURCE=".:git:d55edf1cba61"` → **正是** `jdk26u` 的 `jdk-26.0.2.1-ga`（同一 commit）。自编件因此与官方件同源，source offer 无歧义。
- ⚠️ **更新版不在主线**：`openjdk/jdk`（主线）最终只到 `jdk-26-ga`（26.0.0 GA，commit `4408cd2a07a1`），**没有** 26.0.x。26.0.1/26.0.2/26.0.2.1 从**独立更新仓 `openjdk/jdk26u`** 切出 → 必须 clone 该仓。
- ⚠️ **注解 tag**：`jdk-26.0.2.1-ga` / `jdk-26.0.2.1+1` 的 **tag 对象**哈希 ≠ commit（`+1` 的 tag 对象是 `bb70eaa9…`）；引用 commit 一律用 `git rev-parse 'jdk-26.0.2.1-ga^{commit}'`。
- 官方 tar 同时用作**容器里的 boot JDK**（glibc/aarch64，openEuler 可直接跑）。
- **源码仓落位**：`ref/jdk26u`（完整 clone，2.5G）；宿主侧 worktree `stuffs/research/jdk26/jdk26u-src`（供 `--jdk-src` 编 `libjli`）。容器只需 `ref/jdk26u`（自包含；worktree 的 `.git` 指向宿主绝对路径，**不能**在容器里用）。

### 构建环境（容器）
`libjvm` 在用户提供的 **openEuler 容器**里原生编（设备本身不能执行编译产物，见 §坑）：

| 项 | 值（2026-09-12 实测快照） |
|---|---|
| OS | openEuler **24.03 LTS-SP1**，arch **aarch64**，kernel **6.6.0** |
| 编译器 | gcc / g++ **12.3.1-67.oe2403sp1** |
| 构建工具 | make **4.4.1-2**、autoconf **2.71-9**、automake **1.16.5-8**、m4 **1.4.19-5**、binutils(ld) **2.41-28** |
| C 库 | glibc **2.38-47** |
| 运行时 | python3 **3.11.6**、perl **5.38.0**、pkg-config、curl、git |
| boot JDK | 官方 **26.0.2.1+1-7**（`build 26.0.2.1+1-7`） |
| 额外 dnf 依赖 | alsa-lib-devel、cups-devel、fontconfig-devel、freetype-devel、libX11/Xext/Xrender/Xtst/Xi/Xrandr/Xinerama/Xcursor-devel、xorg-x11-proto-devel、libXt/Xmu/Xpm-devel + **`libstdc++-static`**（必须） |
| 装法 | `sh tools/jre26/linux_bootstrap.sh`；复核对齐用 `linux_env_snapshot.sh` |
| 构建目录 | `$WORK=$HOME/meow-jvm26`（**与 jre25 的 `$HOME/meow-jvm` 分开**，避免复用旧 boot JDK） |

### 可复现性（逐字节）

| 产物 | 结论 | 方法 |
|---|---|---|
| 官方 26 lib（魔改后） | ✅ **逐字节** | `patch_dynstr.py` 原地等长改写（文件尺寸/偏移全不变） |
| `libc6.so` | ✅ **逐字节** | `build_shim.sh` 干净重建 + 比对 |
| `libjli.so` | ✅ **逐字节** | `build_libjli_ohos.sh`（`--src` 规范化绝对路径） |
| `meow_jre.tar.gz` | ✅ **逐字节** | `pack_jre_data.py` 规范化打包（排序 / mtime=0 / uid=gid=0 / gzip mtime=0） |
| `libjvm.so`（容器编） | ✅ **逐字节** | `SOURCE_DATE_EPOCH=1784133400` + 固定 `$WORK=$HOME/meow-jvm26`；`linux_verify_jvm_repro.sh` **2× cmp 一致**（`MEOW_REPRO_N` 可调高） |

- **路径必须规范（前提）**：产物会嵌入**源码路径**（`libjli` 内嵌 `.../jdk26u-src/src/...`）与部分 native 的**输出路径**（写进 `.dynstr`）
  → 必须用**同一绝对路径**，否则同功能、哈希不同。`build_libjli_ohos.sh` 已把 `--src` 规范化成绝对路径。
- 打包数据**必须**用 `pack_jre_data.py`（toybox/GNU `tar czf` 的 mtime/顺序不定）。
- `libjvm` 若多次不一致（默认为 2 次比对）：再关链接器 BuildID、去 `-g`（见 `linux_verify_jvm_repro.sh` 提示）。

## 文件

| 文件 | 作用 |
|---|---|
| `rebuild_for_meowcraft.sh` | **入口**：组装整套 JRE 集（调下面各步）+ 打印随包步骤 |
| `build_shim.sh` / `glibc_compat.c` | 兼容层 `libc6.so`（约 40 个 glibc 缺失符号；**无版本**导出） |
| `patch_dynstr.py` | **原地**改 ELF `.dynstr` 的 NEEDED 名（**不用 patchelf**） |
| `assemble_jre.sh` | 把官方 26 lib 逐个 `patch_dynstr.py` 后装入输出目录 |
| `build_libjli_ohos.sh` | 从 JDK26 源**独立编译** `libjli.so`（无 boot JDK） |
| `patches/libjli-ohos.patch` | libjli OHOS 分体 patch（见 §3）——**对 `jdk-26.0.2.1-ga` 源干净可打** |
| `patches/os_linux-ohos.patch` | HotSpot 分体 patch（`java.home`/`dll_dir` 认 `OHOS_JAVA_HOME`/`OHOS_DL_DIR`，见 §4）——**同上** |
| `linux_bootstrap.sh` / `linux_build_jvm.sh` | **容器内**：装工具链 + boot JDK + 原生编 `libjvm.so`（见 §4） |
| `linux_env_snapshot.sh` | **容器内**：打印精确环境版本（供溯源/一致性核对） |
| `linux_slim_jre.sh` | **容器内**：`jlink` 裁 `lib/modules`（见 §5） |
| `linux_verify_jvm_repro.sh` | **容器内**：N× 干净重建 `libjvm` + `cmp`（默认 2；`MEOW_REPRO_N` 可调） |
| `pack_jre_data.py` | **确定性**打包 `home` → `meow_jre.tar.gz` |
| `verify_symbols.py` | 符号满足性自检（GLOBAL 未定义 vs 提供者集合） |

## 复现（端到端）

```sh
# 0) 外部输入（见「溯源」）
#    官方 JDK26 tar（jdk.java.net/archive）→ stuffs/research/jdk26/
#    源码：**更新仓** openjdk/jdk26u（非主线！）→ ref/jdk26u；宿主 worktree：
tar xzf stuffs/research/jdk26/openjdk-26.0.2.1_linux-aarch64_bin.tar.gz -C stuffs/research/jdk26/_inspect
git clone https://github.com/openjdk/jdk26u.git ref/jdk26u
git -C ref/jdk26u worktree add stuffs/research/jdk26/jdk26u-src jdk-26.0.2.1-ga

# 1) 容器（openEuler 24.03 aarch64；环境见「构建环境」）—— 编 libjvm（+ 可选瘦 modules）
sh tools/jre26/linux_bootstrap.sh         # 装工具链 + boot JDK（如已装可跳过）
sh tools/jre26/linux_build_jvm.sh         # → out-linux/libjvm.so（glibc；默认源 ref/jdk26u @ jdk-26.0.2.1-ga）
sh tools/jre26/linux_verify_jvm_repro.sh  # （建议）N× cmp 验 libjvm 逐字节可复现（默认 2；MEOW_REPRO_N 调高）
sh tools/jre26/linux_slim_jre.sh          # （仅在换官方输入时需要）→ out-linux/modules.slim

# 2) 宿主 —— 组装（魔改 26 官方件 + 自编 libc6/libjli + 魔改自编 libjvm）
sh tools/jre26/rebuild_for_meowcraft.sh \
    --official-jdk stuffs/research/jdk26/_inspect/jdk-26.0.2.1 \
    --jdk-src      stuffs/research/jdk26/jdk26u-src \
    --libjvm       stuffs/research/jdk26/out-linux/libjvm.so \
    --modules-slim stuffs/research/jdk26/out-linux/modules.slim \
    --out          stuffs/research/jdk26/out
#   （rebuild 会对 --jdk-src 打 patches/libjli-ohos.patch 后自编 libjli；对 --libjvm 跑魔改）

# 3) 随包（工程内）
cp stuffs/research/jdk26/out/*.so libs/meowjre/libs/arm64-v8a/
python3 tools/jre26/pack_jre_data.py --home stuffs/research/jdk26/out/home \
    --out entry/src/main/resources/rawfile/meow_jre.tar.gz
rm -rf libs/meowjre/build entry/build && devecocli build --modules entry meowjre

# 4) 部署：先 HSP 后 HAP；**换 JRE 版本/数据时**须卸载/清数据让 meow_jre.tar.gz 重新解压
```

### digests（2026-09-12 实测，sha256）
| 对象 | sha256 |
|---|---|
| 官方 JDK tar | `b96b265a4a1a36c02454148891aa58ca63303cbc2d1b7979c33b4fe99e09117b` |
| 自编 glibc `libjvm.so`（未魔改，27,707,544 B） | `d28164cdc728b8a4860b539c410a1cdbffa08e35096b567447e44a0c9438f5f0` |
| 随包 `libjvm.so`（魔改后） | `9736402dade1c059064b8087ec3fbc2870684bb8c97af17e60f0f50b6e7ab579` |
| 随包 `libc6.so` | `c8b06fadd6f074b8bab3069bddb537bf503ac815575b46021b6ef05121a5a723` |
| 随包 `libjli.so` | `bedc743c54d0d9acd37a5d841963b87e79659063f5d5e4222a8433cad637d089` |
| `modules.slim`（jlink 产物，43 模块） | `d7486973d16eccc577ac86a96531089184c69c6be284b5c712d30d7da1d8f0c0`（42,748,043 B） |
| 随包数据 tar（`pack_jre_data.py` 规范化） | `4f9c2b87af26303ba660e6cde1c048c61e817c7dcb50f1b5cf93eecbeea2579b`（41,158,374 B） |
| HAP（本次 debug 签名） | `69e2ebd33b8288d41798fcb1c962a8d19dc1e2fb53db369583ceb11b3f278bda` |
| HSP（本次 debug 签名） | `e415480b03b7257bf0ea887b10194ed646fca2dba43192b79245d330e02c9e47` |

> HAP/HSP 含签名材料 → 随签名变化；上表为本次 debug 签名的参考值。其余件与签名无关。
> **对齐精确源只改自编件**：`libjvm`/`libjli` 变；官方 26 lib、`libc6.so`、`modules.slim`、数据 tar **均不变**。

## 三块机制

### 1) 兼容层 `libc6.so`（`glibc_compat.c`）
官方 glibc 件相对 OHOS musl 缺一批 libc 级符号（≈40 个），`libc6.so` 补齐：多为别名
（`__strdup→strdup`、`__strtok_r→strtok_r`、`__getdelim→getdelim`、`__pthread_key_create→pthread_key_create`、
`__isinf/__isnan/__isnanf`、`__rawmemchr`、`__xmknod`、`__xpg_strerror_r`、`__sigsetjmp→sigsetjmp`），
少数需实现（`__ctype_b/tolower/toupper_loc` 三张 glibc 布局表、`__xstat64/__lxstat64/__fxstat64` 直通、
`dlinfo`/`malloc_trim`/`getutxent`/`setutxent`/`secure_getenv`/`__getauxval`/`__sched_cpufree` 桩），
自编 `libjvm` 额外接口（`__environ`/`_environ`、`__sysconf`、`__libc_single_threaded`、`__isoc23_*`、
`_dl_find_object`、`__cxa_thread_atexit_impl`、`fcntl64`）。
**导出为「无版本」符号**（与 musl libc 自身一致）：OHOS musl 对「有版本号的导出」会做**版本匹配**。
> **JDK26 无需改 `glibc_compat.c`**：`verify_symbols.py` 对 jdk26 全部 29 件 **PASS**（含精确源版）。

### 2) 原地改 `.dynstr`（`patch_dynstr.py`）——**禁用 patchelf**
把官方件的 NEEDED 名原地改短（新名 ≤ 旧名，覆盖 + 补 `\0`，**文件尺寸/偏移全不变**）：

| 旧 | 新 | 说明 |
|---|---|---|
| `libc.so.6` | `libc6.so` | **= 兼容层**（既满足依赖，又把 shim 注入每个 lib） |
| `ld-linux-aarch64.so.1` | `libc6.so` | OHOS 无 glibc 解释器 |
| `libpthread.so.0` / `libdl.so.2` / `librt.so.1` / `libm.so.6` | `libc.so` | musl 全并入 libc |
| `libz.so.1` | `libz.so` | 系统 zlib |
| `libfreetype.so.6` | `libfreetype.so` | 自编 freetype（`tools/freetype/`） |

> JDK26 无需增改映射（NEEDED 集合同 25）。

### 3) 自编 `libjli`（`build_libjli_ohos.sh` + `patches/libjli-ohos.patch`）
从 JDK26 源（`jdk26u-src` @ `jdk-26.0.2.1-ga`）独立编（9 个 C 文件，链接 `-lz`；生成 `classfile_constants.h`，**major=70**）。
OHOS 分体 patch（3 处）：
- `GetJDKInstallRoot`：`OHOS_JAVA_HOME` 非空 → 直接作为 java.home（跳过 `libjava.so` 存在性检查）；
- `GetJVMPath`：`OHOS_DL_DIR` 非空 → `jvmpath = $OHOS_DL_DIR/libjvm.so`（扁平 el1 目录）；
- `CreateExecutionEnvironment`：有 `OHOS_*` → **直接 return**（OHOS 不能 `execve` 重入；`LD_LIBRARY_PATH` 由宿主预置）。

### 4) 自编 `libjvm`（容器 openEuler，`linux_*.sh` + `patches/os_linux-ohos.patch`）
设备上**不能执行编译产物**（可写路径 ELF `EPERM`）→ 借用户 **openEuler 24.03 aarch64 容器**（挂载宿主工作区 `/mnt/linux_share`）**原生构建**：
1. `linux_bootstrap.sh`：`dnf` 装 gcc/make/autoconf + 桌面依赖 + **`libstdc++-static`**；解**官方 JDK26(glibc/aarch64)** 当 boot JDK。
2. `linux_build_jvm.sh`：取干净源（`$JDK_REPO` = `ref/jdk26u` 的 `jdk-26.0.2.1-ga`）→ 打 `patches/os_linux-ohos.patch` → `configure --with-stdc++lib=static` → `make hotspot` → 拷 `libjvm.so` 回共享目录。
3. 宿主侧：`patch_dynstr.py` 魔改（NEEDED→`libc.so`/`libc6.so`）→ 装进 JRE。
- **必须 `--with-stdc++lib=static`**：否则 NEEDED 带 `libstdc++.so.6`/`libgcc_s.so.1`（OHOS 没有）。
- HotSpot 分体 patch（`os_linux.cpp` 2 处）：`java.home` 认 `OHOS_JAVA_HOME`、`dll_dir` 认 `OHOS_DL_DIR`（上游假设 `lib/<variant>/` 会**多剥一层** `arm64` → `Failed setting boot class path` / `Unable to load jimage library`）。

### 5) 数据瘦身（`linux_slim_jre.sh` + 裁 `bin/`）
官方**完整 JDK 数据**远超 MC 所需 → 瘦到 **41,158,374 B / 35 文件**：
1. **`lib/modules`**：容器里用官方 JDK26 的 `jlink` 按原 HOML 模块集裁，**两处 26 版适配**：
   - 剔除 **`jdk.crypto.cryptoki`**（其 native `libj2pkcs11` 已删，保留会不一致）；
   - 剔除 **`jdk.jsobject`**（**JDK26 已移除该模块**，保留 jlink 报错）。
   → **43 模块** + `--compress=zip-6`。
2. **`bin/`**：只留 `java keytool jfr jwebserver rmiregistry`（JDK26 无 `jrunscript` → 实留 **5** 个）。
- **数据门（防混合）**：`Install` 解压后写 `<installDir>/meow_jre_data`（令牌 `26.0.2.1+1-7-r1`）；ArkTS `Paths.JRE_DATA_TOKEN`/`JavaEnvScanner` 同步校验；令牌不符 → 未就绪 + `Install` 清目录重解压。**⚠️ 改随包 JRE 数据的任何内容（模块集/文件）都必须同步升令牌**（native `kJreDataToken` + ArkTS `JRE_DATA_TOKEN`）。**只换 el1 `.so`（数据不变）→ 令牌不动。**
- **旧 JRE 数据自动清理**：`Install` 会扫 `filesDir/meow-jres/`，删除**非当前 id** 的兄弟目录（换版本/改名后遗留的孤儿），幂等、失败仅告警不阻断（`PurgeStaleJreData`）。
  - **UI**：app 区分 **须升级**（有数据但令牌不符 → 显示「升级」+ 令牌 旧→新）vs **未解压**（显示「解压」）；须升级时**禁用所有版本的「启动」**。
- 模块集 = 原 HOML（已知 MC 1.6.x–26.3 可用）；实机验证见 §校验。

## 校验（2026-09-12）

| 项 | 值 |
|---|---|
| 符号满足性 `verify_symbols.py` | **PASS**（29 件全绿：libc∪本集∪libz∪libc++_shared∪freetype 满足） |
| 兼容层 `libc6.so` | **无版本**导出；符号满足性 PASS；**无需为 26 增补** |
| 自编 `libjli.so` | NEEDED=`libz.so`+`libc.so`；编译自 `jdk-26.0.2.1-ga` |
| 自编 `libjvm.so`（容器编，glibc） | 27,707,544 B；魔改后 NEEDED=`libc.so`+`libc6.so`×2；符号满足性 PASS |
| 数据瘦身 | data tar → **41,158,374 B**（35 文件）；`lib/modules` → **42,748,043 B**（43 模块） |
| 实机 | **MC 可玩**（用户实测） |
| 逐字节（现网 vs 组装） | `libc6.so`/`libjli.so`/`libjvm.so` 均 **OK** |

## 坑（务必记住）

- **禁用 patchelf**：会让 patchelf **重排文件并用 `X` 填充**，OHOS loader 把符号名读进填充区 → `Error relocating …`。必须**原地改 `.dynstr`**。见记忆 `meowcraft_glibc_neededs_inplace_not_patchelf`。
- **shim 必须「无版本」导出**：有版本号会被 musl 的版本匹配拒绝（`symbol not found`）。
- **HotSpot 也要分体 patch**（`libjli` 不够）：`java.home` 认 `OHOS_JAVA_HOME`、`dll_dir` 认 `OHOS_DL_DIR`。
- **容器构建用 `--with-stdc++lib=static`**：否则 NEEDED 带 `libstdc++.so.6`/`libgcc_s.so.1`（OHOS 没有）。
- **设备不能执行编译产物**：用户可写路径 ELF `EPERM` → 需运行编译产物的构建只能在容器/Linux 跑。
- **更新版源在独立仓**：26.0.x **不在** `openjdk/jdk` 主线（主线止于 `jdk-26-ga`）→ 用 **`openjdk/jdk26u`**（`jdk-26.0.2.1-ga`）。
- **注解 tag**：打印 commit 用 `^{commit}`（否则得到 tag 对象哈希）。
- **worktree 不能进容器**：`jdk26u-src` 的 `.git` 指向宿主绝对路径 → 容器里 `git` 失效；容器只用自包含的 `ref/jdk26u`。
- **hvigor 不追踪 `libs/<abi>/` 增删**：改后必须清模块 build 再 `build --modules entry meowjre`。
- **剔除** `libjawt`(仅X11)/`libawt_xawt`/`libjsound`/`libsplashscreen`(X11/ALSA)、`libj2pkcs11`(PKCS#11)、`libattach`(Attach API)、`libj2pcsc`(PC/SC)、`libsaproc`(SA)、`libsleef`(SIMD 数学)——**MC/JVM 运行不用，保持最小可用**。

> **容器脚本调用约定**：所有 `linux_*.sh` 只在**容器内**跑；默认挂载根 `MEOW_SHARE=/mnt/linux_share/Documents/Meow/…/Meowcraft`、源仓 `JDK_REPO=$SHARE/ref/jdk26u`、构建目录 `MEOW_WORK=$HOME/meow-jvm26`，可用环境变量覆盖。**可复现要求固定绝对路径**：`libjli` 的 `--src`（`…/stuffs/research/jdk26/jdk26u-src`）、`libjvm` 的 `$WORK` 与源 tag（默认 `jdk-26.0.2.1-ga`）。

## 与 jre25 工序的差异（26 版适配清单）

| # | 差异 | 位置 |
|---|---|---|
| 1 | 官方输入 25.0.2 → **26.0.2.1**（sha/tar 名/boot JDK） | `linux_bootstrap.sh`、`linux_build_jvm.sh` |
| 2 | 源码 `jdk-25-ga`（主线）→ **`jdk-26.0.2.1-ga`（更新仓 `jdk26u`）**；`SOURCE_DATE_EPOCH` `1755018936` → **`1784133400`** | `linux_build_jvm.sh`、`linux_slim_jre.sh`、`linux_verify_jvm_repro.sh` |
| 3 | 类文件 major `69` → **`70`**；`-DJDK_MAJOR_VERSION=26` | `build_libjli_ohos.sh` |
| 4 | jlink 模块集**剔除新增** `jdk.jsobject`（26 已移除） | `linux_slim_jre.sh` |
| 5 | 容器 `$WORK` → **`$HOME/meow-jvm26`**（避免复用 25 的 boot JDK） | `linux_*.sh` |
| 6 | 随包命名改为**版本无关**：HSP 模块 `meowjre`、JRE id `meow_jre`、rawfile `meow_jre.tar.gz`（旧 `meowjre25`/`meowjre26` 已废）；JRE 版本只由**数据门令牌** `26.0.2.1+1-7-r1` 体现 | 工程 + `rebuild_for_meowcraft.sh` |
| 7 | **无需改**：`glibc_compat.c`、`patch_dynstr.py`、`assemble_jre.sh`、`build_shim.sh`、`verify_symbols.py`、两个 patch | — |

> **为什么命名要版本无关**：HSP 模块名若绑 JRE 版本（`meowjre25`/`meowjre26`），每升一次 JRE 就会在设备上留下一个**删不掉的旧 HSP**（app 无权重删，只有 `hdc uninstall` 清）。改为固定名后，升级 = 「HSP 原地替换 + 数据门走『须升级 → 升级』」，不产生残留；`filesDir/meow-jres/` 侧另有 `PurgeStaleJreData` 兜底清孤儿目录。

## 未完成 / 下一步

**（无）—— 已与官方 26.0.2.1 精确对齐，零黑箱。**

## 相关

- 姊妹工序：`tools/jre25/`（**25 时代历史配方**，随包 JRE 已升级到 26）
- 同族工具：`tools/freetype/`（`libfreetype.so`）
- 主索引：`tools/README.md`
