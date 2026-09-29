# tools/jre8 — 收编官方 OpenJDK 8(glibc) 跑 OHOS(musl)：legacy Forge 的第二套 JRE

把**官方 OpenJDK 8（Temurin 8u504，Linux/aarch64，glibc）**改造成能在 **OHOS(musl)** 上加载运行的第二套
JRE，服务 **Forge ≤1.12.2（LaunchWrapper）+ 1.13–1.16（ModLauncher/Mixin）**——即 HMCL 的 `MODDED_JAVA_8` 段。
工序沿用 [`tools/jre26/`](../jre26/README.md)（同一套"魔改官方件 + 兼容层 + 自编 libjli/libjvm"的做法），
差异逐条列在 §4。

> 状态：**宿主侧工序已全部落地并自证通过**（shim / 自编 libjli / 组装 / 符号检查 / 打包 全绿，§3）。
> 唯一待办的执行项是**容器里自编 libjvm**（§3.3，须拥有者跑）。状态单一事实源见
> [`notes/00-current/现状基线.md`](../../../notes/00-current/现状基线.md)。

## 0. 为什么是 Java 8（触发链，2026-09-28 实测）

1. 随包 JRE 26 跑 Forge 1.12.2 → 卡 `UnsupportedOperationException: Setting a Security Manager is not supported`
   （**JEP 486 / JDK 24+ 永久禁用**，任何 flag 无效）。
2. 把那一次 `System.setSecurityManager` 就地摘掉（3 字节补丁，见
   `stuffs/research/forge-support/r1-probe/SM-PATCH.md`）后，堆栈推进到 coremod 注入阶段，新卡点换成
   **`java.lang.NoClassDefFoundError: java/util/jar/Pack200`**（`ClassPatchManager.setup`，**JEP 367 / JDK 14 删除**）。
3. ⇒ **能跑"原样"Forge 1.12.2 客户端的 JDK 上限 = 13**；**Java 23/21/17/14 全部出局**（都拦在 Pack200 上）。
4. Pack200 无"小补丁"替代：`java.util.jar.Pack200` 是 **JDK 类**，**无法从 classpath 提供**
   （`ClassLoader.preDefineClass` 对非 platform loader 一律 `throw SecurityException("Prohibited package name: ...")`，
   `ref/jdk26u/src/java.base/share/classes/java/lang/ClassLoader.java:854-860`）。
5. ⇒ 采纳 HMCL 的答案：**给 legacy 段配 Java 8**（同时是 1.13–1.16 段唯一有背书的宿主）。

## 1. 输入件（可溯源）

| 项 | 值 |
|---|---|
| 来源 | Eclipse Adoptium **Temurin 8**（`jdk8u504-b01`，linux/**aarch64 glibc**，image_type=**jdk**） |
| 文件 | `OpenJDK8U-jdk_aarch64_linux_hotspot_8u504b01.tar.gz`（**102,617,391 B**） |
| URL | `https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u504-b01/OpenJDK8U-jdk_aarch64_linux_hotspot_8u504b01.tar.gz` |
| sha256 | `57b7ed8af9d48542bb49ff7894448040b17bea0a48b41677d11ecaec6129768d`（已核对 ✅） |
| 落地 | `stuffs/research/jdk8/`（tar + `_inspect/jdk8u504-b01/`；`assets.json` = Adoptium API 原始应答） |
| `release` 溯源 | `JAVA_VERSION="1.8.0_504"`、`SOURCE=".:git:1358e1b273e2+"`、`SOURCE_REPO="https://github.com/adoptium/jdk8u.git"`、`FULL_VERSION="1.8.0_504-b01"` |
| 源码 | **`openjdk/jdk8u` @ tag `jdk8u504-b01`**（commit `4efe3643`，2026-08-10）→ `ref/jdk8u`（浅克隆 902 MB；`SOURCE_DATE_EPOCH=1786376989`） |

## 2. M0 静态验证（纯宿主、无需 JVM/容器）

> 工具：本目录的 [`verify_symbols.py`](verify_symbols.py)（**纯 Python**，见 §2.2 的口径修正）；
> 调研期的 `elf_needed.py`/`elf_syms.py` 留在 `stuffs/research/jdk8/`。

### 2.1 `.so` 与 NEEDED

官方布局：`jre/lib/aarch64/*.so` + `jre/lib/aarch64/server/libjvm.so` + `jre/lib/aarch64/jli/libjli.so`
（**本来就是一层扁平**，比 JDK 9+ 好办；`server/libjsig.so` 是指向 `../../libjsig.so` 的符号链接）。

- NEEDED 全集里**只有一个新名字**：**`libgcc_s.so.1`**（`libfontmanager`/`libsunec`/`libunpack` 各 1 处）；
  其余（`libc.so.6`/`ld-linux-aarch64.so.1`/`libdl.so.2`/`libpthread.so.0`/`libm.so.6`）都在
  [`patch_dynstr.py`](patch_dynstr.py) 的现有 MAP 内。
- **不需要为 libstdc++ 操心**：官方 `libjvm.so` 的 NEEDED 只有 `libm/libdl/libpthread/libc/ld-linux`
  （与 JDK 26 相反——26 是我们自己 `--with-stdc++lib=static` 才干净的）。
- `libgcc_s.so.1` 是**名义依赖**：那三个件真正需要的 `_Unwind_*` 符号**全部由 `libc++_shared.so` 提供**
  （它已随包在 el1 与 JRE 同目录）⇒ MAP 加一行 `libgcc_s.so.1` → **`libc6.so`**（13→9 字符，满足"新名不长于旧名"），
  符号走全局作用域命中 `libc++_shared`。**不引入真 libgcc**。

### 2.2 符号满足性 —— **口径修正：只认"真重定位"**

⚠️ [`tools/jre26/verify_symbols.py`](../jre26/verify_symbols.py) 用的是 `readelf --dyn-syms` 的"未定义符号"口径，
会把**只有 .dynsym 条目、没有任何重定位**的幽灵符号算成"缺"。JDK 8 正好撞上：

| 幽灵 | 真相（`llvm-objdump -R` 实测） |
|---|---|
| `libjava.so` 的未定义 `__timezone` | **无重定位**；真重定位是 `R_AARCH64_GLOB_DAT timezone` ⇒ **musl 本就提供**，什么都不用补 |

⇒ 本目录的 [`verify_symbols.py`](verify_symbols.py) 改为**重定位口径**（扫 `.rela.dyn`/`.rela.plt`，只把被引用的
未定义符号算作需求），与加载器的实际要求一致，且纯 Python（宿主无 `readelf` 也能跑）。

按该口径实测（提供者 = SDK sysroot `libc.so` ∪ `libz.so` ∪ `libc++_shared.so` ∪ 官方件自身）：

| 真需求 | 出现在 | 处置 |
|---|---|---|
| `__xstat` `__lxstat` `__fxstat` | `libjava` `libjli`（**官方件**；被丢弃的 `libawt_xawt` 也要） | **补进 shim** ✓（shim 原来只有 64 版）。⚠️ **我们自编的 libjvm 不用它们**——容器里 glibc 2.38 已把 `stat()` 直接指向 `stat/fstat/lstat`(+`*64`)，实测其需求集里没有 `__xstat` |
| `__getpagesize` | `libjvm`（自编） | **补进 shim** ✓ |
| `__isoc23_strtoul` | `libjvm`（自编） | **补进 shim** ✓（2026-09-28 正式组装时 `verify_symbols.py` 点名的**唯一缺口**；`__isoc23_strtol/strtoll/strtoull` 早已有——这一族按实测缺口逐个补，不凭感觉铺全） |
| `gnu_get_libc_version` `gnu_get_libc_release` | `libjvm`（官方**与自编都**要） | **必须补进 shim** ✓（见下方 ⚠️） |
| `_Unwind_Resume` | `libfontmanager` `libsunec` `libunpack` | 由 `libc++_shared.so` 提供 ✓（见 §2.1） |
| `timezone` | `libjava` | musl 提供 ✓ |
| X11/ALSA/`libthread_db` 系 | `libawt_xawt`(226) `libsplashscreen`(42) `libjsoundalsa`(119) `libsaproc`(5) | **丢弃这些件**（与 jre26 同策略） |

> ⚠️ **纠正一条先前说法（2026-09-28 实测）**：§2.3 的 NPTL patch **只改运行时分支，不消除符号引用**——
> 自编 libjvm 的未定义符号里**仍然**有 `gnu_get_libc_version/release`（`else` 分支的代码照旧被编译、被链接）。
> 所以 shim 提供这两个不是"兜底"，而是**硬需求**。

> 注：`libc6.so` 的 shim **抢不到 musl 已有的名字**（musl libc 在全局作用域里加载更早），
> 所以只有 musl **没有**的名字才轮得到 shim——上面前 5 个恰好都是 glibc 专有名字 ✅。

### 2.3 ⚠️ 必须新增的 HotSpot patch：musl 被误判成 LinuxThreads

`hotspot/src/os/linux/vm/os_linux.cpp:586 os::Linux::libpthread_init()`：上游用
`confstr(_CS_GNU_LIBC_VERSION/_CS_GNU_LIBPTHREAD_VERSION)` 探测 glibc，**musl 两个 key 都不支持 → 返回 0**
⇒ 上游走 "glibc < 2.3.2" 分支：`set_libpthread_version("linuxthreads")` → `set_is_LinuxThreads()`，
**整个 VM 切到 LinuxThreads 模型**（线程栈默认尺寸、`create_thread` 分支），并引用两个 glibc 专有符号。
处置（`patches/os_linux-ohos.patch`）：直接 pin `glibc 2.17` + `NPTL 2.17` + `set_is_NPTL()` +
`set_is_floating_stack()` 并 return（musl 本就是 1:1 线程 = NPTL 语义）。
（JDK 26 无此问题：LinuxThreads 支持早已删除。）

### 2.4 数据面与体积（**实测：比现役 JRE 26 还小**）

关键事实：**官方 `rt.jar` 里 19898 个条目全部是 STORED（未压缩）** ⇒ gzip 有 **3.03×** 的压缩率
（62.7 MiB → 20.7 MiB）。因此**不需要**做 rt.jar 裁剪（曾预估"必须裁"，实测推翻）：

| | 第二套（JDK 8，dry-run 实测） | 现役 JRE 26 |
|---|---|---|
| el1 `.so` | 25 件 / **20 MB** | 30 件 / 33 MB |
| 数据 tar（`pack_jre_data.py`） | **30.8 MiB** | 39.3 MiB |
| 合计 | **≈51 MiB** | ≈72 MiB |

（`多JRE共存-方案.md` §0 里"每新增一套 JRE ≈ 72 MiB"的估算来自 26 那一套；**JDK 8 更省**。）

### 2.5 布局要点（收编时必须遵守）

- **el1（模块名版本中性，如 `meowjrelegacy/libs/arm64/`）**：`jre/lib/aarch64/*.so` + `server/libjvm.so` +
  `jli/libjli.so` **拉平**；再加 `libc6.so`(自编) + `libjli.so`(自编) + `libjvm.so`(容器自编) +
  `libfreetype.so`(自编) + `libc++_shared.so`（既有随包件）。
- **数据侧（`OHOS_JAVA_HOME`）**：`release`、`bin/java`（`JavaEnvScanner` 的就绪标记）、`lib/**`（`rt.jar` 等）、
  `lib/security/**`、`lib/ext/**`、**`lib/aarch64/jvm.cfg` 必须留**（`GetJREPath` 出来的 `jrepath` 要读它）。
- `OHOS_DL_DIR` / `OHOS_JAVA_HOME` 语义与 jre26 **完全一致**（桥侧已参数化，无需改 native ABI）。

- **id / HSP 模块 / rawfile 名都**版本中性**（禁塞 JRE 版本号，见 [`现状基线.md`](../../../notes/00-current/现状基线.md) §1）：
  id = `meow_jre_legacy`（本套）/ `meow_jre`（现代套）；rawfile = `<id>.tar.gz`；HSP 模块 = `meowjrelegacy` / `meowjre`。
  **本套的数据令牌 = `1.8.0_504-b01-r1`**（改数据必须同步升它；两边同值镜像：
  native `entry/src/main/cpp/meowassets/jre_launcher.h::kJreSpecs` ↔ ArkTS `common/constants/Paths.ets::BUNDLED_JRES`）。
  **就绪标记 = `lib/rt.jar`**（JDK 8 没有 `lib/modules`！）。

## 3. 工序与现状

| 步骤 | 脚本 | 状态 |
|---|---|---|
| 1 兼容层 `libc6.so` | [`build_shim.sh`](build_shim.sh) + [`glibc_compat.c`](glibc_compat.c) | ✅ 已编通（46 导出；含新增 5 个真需求符号） |
| 2 自编 `libjli.so` | [`build_libjli_ohos.sh`](build_libjli_ohos.sh) + [`patches/libjli-ohos.patch`](patches/libjli-ohos.patch) | ✅ 已编通并自证（§3.1） |
| 3 官方件改 `.dynstr` | [`assemble_jre.sh`](assemble_jre.sh) + [`patch_dynstr.py`](patch_dynstr.py) | ✅（MAP 加 `libgcc_s.so.1`） |
| 4 数据面 | `jre/` 布局 + [`pack_jre_data.py`](pack_jre_data.py) | ✅（30.8 MiB 实测） |
| 5 符号自检 | [`verify_symbols.py`](verify_symbols.py) | ✅ 重定位口径（纯 Python，宿主可跑） |
| 6 入口 | [`rebuild_for_meowcraft.sh`](rebuild_for_meowcraft.sh) | ✅ dry-run 全绿（§3.2） |
| 7 **容器自编 `libjvm.so`** | [`linux_bootstrap.sh`](linux_bootstrap.sh) / [`linux_build_jvm.sh`](linux_build_jvm.sh) / [`linux_env_snapshot.sh`](linux_env_snapshot.sh) / [`linux_verify_jvm_repro.sh`](linux_verify_jvm_repro.sh) + [`patches/os_linux-ohos.patch`](patches/os_linux-ohos.patch) | ✅ **已跑通**（2026-09-28）：`libjvm.so` 16,374,456 B、`DEBUG_LEVEL=release`、非 product 标志全 0、`NEEDED=ld-linux-aarch64.so.1,libc.so.6,libm.so.6`（无 stdc++/gcc_s） |
| 8 **正式产物** | `stuffs/research/jdk8/out/` + 数据 tar（**随包名 = `<id>.tar.gz` = `meow_jre_legacy.tar.gz`**） | ✅ 25 件 `.so` **全部 PASS**（重定位口径）；`home` 80 MB/58 文件 → tar **30.8 MiB / 72 条目**；digests 见 §3.4 |

### 3.1 `libjli.so`（JDK 8）已跑通 ✅

```sh
git -C "$WS/ref/jdk8u" apply "$WS/Harmomeow-Craft-Launcher/tools/jre8/patches/libjli-ohos.patch"   # 绝对路径！
sh tools/jre8/build_libjli_ohos.sh --src "$WS/ref/jdk8u" --sdk-native "$SDK" --out stuffs/research/jdk8/out-host/libjli.so
```

产物 89,744 B：`SONAME=libjli.so`、`NEEDED=libz.so,libc.so`（原生名，**不需** dynstr 魔改）、符号检查 PASS、
产物内含 `OHOS_JAVA_HOME`/`OHOS_DL_DIR` 串（分体改动在位）。

`patches/libjli-ohos.patch` 的 3 处 hunk（对应 jre26 版的 3 处，落点不同）：

| hunk | 落点 | 作用 |
|---|---|---|
| `CreateExecutionEnvironment` | `jdk/src/solaris/bin/java_md_solinux.c:489`（`mustsetenv` 算完之后、`putenv`+`execve` 之前） | 有 `OHOS_*` 就 `JLI_MemFree(newargv); return;`（上游在 Linux 上**必定** `execv` 自己） |
| `GetJVMPath` | 同文件 `:784` | `OHOS_DL_DIR` → `$OHOS_DL_DIR/libjvm.so` |
| `GetJREPath` | 同文件 `:809` | `OHOS_JAVA_HOME` 直接作为 `jrepath`（跳过 `<home>/lib/<arch>/libjava.so` 探测；`jvmcfg` 由它派生） |

### 3.2 dry-run 组装（libjvm 用官方件当替身）全绿 ✅

```sh
sh tools/jre8/rebuild_for_meowcraft.sh --official-jdk stuffs/research/jdk8/_inspect/jdk8u504-b01 \
    --jdk-src ref/jdk8u --libjvm <官方 jre/lib/aarch64/server/libjvm.so> \
    --out stuffs/research/jdk8/out-dryrun
```

25 个 `.so` **全部 ✓**（relocation 口径 PASS）；`home/` 80 MB / 58 文件 → tar 30.8 MiB。
配合 §2.3 的 patch，自编 libjvm 会把 `gnu_get_libc_*` 那两条需求一并消掉。

### 3.3 容器步骤（拥有者执行）

```sh
# ① 装环境 + 解 boot JDK(Temurin 8)
sh <SHARE>/Harmomeow-Craft-Launcher/tools/jre8/linux_bootstrap.sh
# ② 取源(jdk8u504-b01) + 打 os_linux-ohos.patch + configure + make hotspot（含 release/NEEDED 守卫）
sh <SHARE>/Harmomeow-Craft-Launcher/tools/jre8/linux_build_jvm.sh
# ③（可选）逐字节可复现验证；④ 环境快照入档
MEOW_REPRO_N=2 sh <SHARE>/.../tools/jre8/linux_verify_jvm_repro.sh
sh <SHARE>/.../tools/jre8/linux_env_snapshot.sh
```

拿到 `stuffs/research/jdk8/out-linux/libjvm.so` 后，把 `--libjvm` 换成它重跑入口脚本即为**正式产物**。

> **守卫被修正后不必重编译**：`MEOW_REUSE=1 sh tools/jre8/linux_build_jvm.sh` 会复用 `$WORK/{src,build}`
> 只补跑"守卫 + 收件"（2026-09-28 的误报就是这样补救的，省掉一次全量 hotspot 编译）。

### 3.4 正式产物与 digests（2026-09-28，sha256）

自编 `libjvm.so`（容器产物，收件前）：`3e0f16fc938916754a2320d3f6e8314f298351974694814d8089b05e90c4f8ec`（16,374,456 B）

| 文件（`stuffs/research/jdk8/out/`） | sha256 |
|---|---|
| `libc6.so`（自编兼容层） | `5d3ca113ec5455a9672f5d2ccd3e67d8ea86637762eba4006d09766a04807145` |
| `libjli.so`（自编） | `843296ad19d1aeec9b4cc834a24f981c286c1671b5e5cfb4ec6a96acbd25f3af` |
| `libjvm.so`（容器编 + 魔改后） | `295f7a98ae4760bd3e86efc585350698b3071a39a23622a6c4c12c820ce611dc` |
| `libfreetype.so`（自编，取自随包） | `e41fe6b927f3d6605548473a6468000855ab9ad9239ef8d6ad988a3b2e0f1167` |
| `libjava.so`（官方件魔改后） | `eab84771eed26b3946fab2c17e1e6db599a8882bc8a93c5baee25955a863b46e` |
| `libunpack.so`（官方件魔改后，**Pack200 必需**） | `c457e5797eaf97e51ad4a869499af404e1b60909638dca0669bde9d1a577d506` |
| `meow_jre_legacy.tar.gz`（数据，72 条目；**随包名 = `<id>.tar.gz`**） | `342a6a0a353ab66b34fee7600640d4b09e70675051539fce3af42bf2cf345215` |

（其余 .so 的 digest 可由 `sha256sum stuffs/research/jdk8/out/*.so` 复算；改 `glibc_compat.c`/`patch_dynstr.py` 后
`libc6.so` 与所有**被改过 dynstr 的官方件**都会变哈希，属预期。）

## 4. 与 `tools/jre26` 的差异清单

| # | 差异 | 位置 |
|---|---|---|
| 1 | 布局：JDK 8 是 `jre/`（`rt.jar` + `lib/<arch>/`），**无模块系统** ⇒ 无 jlink 瘦身（但见 §2.4：也不需要裁） | 入口脚本第 4 步 |
| 2 | launcher 源：`jdk/src/share/bin` + `jdk/src/solaris/bin`（**无 `java_md.c`**）；需 `ergo.c` + `-DUSE_GENERIC_ERGO`；`classfile_constants.h` **签入仓库**（major=52，无模板替换）；需 `-DLIBARCHNAME='"aarch64"'`（引号必须**单独成词**，放进 `$DEFS` 会被 shell 的引号移除吃掉） | `build_libjli_ohos.sh` |
| 3 | HotSpot：多一处 `libpthread_init` 的 **NPTL pin**（§2.3）。**补丁里必须写 `::getenv(...)` 而不是 `getenv(...)`**：JDK 8 的 `class os` 有成员 `static bool getenv(const char*, char*, int)`（`runtime/os.hpp:178`）⇒ 在 `os` 的成员函数里裸写 `getenv` 会被**成员遮蔽**（实机报 `error: no matching function for call to 'os::getenv(const char [12])'`）；JDK 26 的 `os` 没有这个成员，所以 jre26 的补丁包裸写能编——**这是 JDK 8 专有的坑**。`--with-stdc++lib=static` **JDK 8 也支持**（`common/autoconf/libraries.m4:749`） | `patches/os_linux-ohos.patch`、`linux_build_jvm.sh` |
| 4 | boot JDK 必须换成 **Temurin 8**（JDK 8 只能拿 7/8 当 boot JDK） | `linux_bootstrap.sh`、`linux_build_jvm.sh` |
| 5 | shim：多 **6 类**真需求符号（`__xstat`/`__lxstat`/`__fxstat`、`__getpagesize`、**`gnu_get_libc_version`+`gnu_get_libc_release`**、`__isoc23_strtoul`）——全部由 `verify_symbols.py` 点名、非猜测 | `glibc_compat.c` |
| 6 | dynstr MAP：多 `libgcc_s.so.1` → `libc6.so` | `patch_dynstr.py` |
| 7 | **不需要** `inject_malloc_slack.py`（MC ≥1.21 Flywheel 越界的规避）、**不需要** `jdk.zipfs` 类补丁（无模块系统）。⚠️ 但若把 ≤1.16 的 **Fabric** 也路由到 JRE 8，则要另做 zipfs chmod 等价物（JDK 8 无 `--patch-module`，只能换 `rt.jar` 里的类） | 待评 |
| 8 | 符号自检改用**重定位口径**（纯 Python）；jre26 那份是 dynsym 口径（会误报，见 §2.2） | `verify_symbols.py` |
| 9 | **必须覆盖 `WARNINGS_ARE_ERRORS`**：`hotspot/make/linux/makefiles/gcc.make:205` 硬写 `-Werror`，而 **gcc 12 对 8u 老代码有误报**（2026-09-28 实机首跑即卡在 `orderAccess_linux_aarch64.inline.hpp:78` 的 `__atomic_load_8` → `-Werror=stringop-overflow`）。处置：`make hotspot WARNINGS_ARE_ERRORS=`（命令行覆盖优先；上游自己在同文件 237-239 行就用 `-Wno-error=format-overflow` 给 `os_linux.o` 开过同类口子，见 JDK-8269388）⇒ 构建警告不再致命，代价由 §3.3 的两道守卫 + 真机验收兜底 | `linux_build_jvm.sh` |
| 10 | **release 守卫的判据必须换成本项目校准过的那三条**：`CheckCompressedOops`(`notproduct`, `globals.hpp:525`) / `ZapJNIHandleArea`(`develop`, `:871`) / `VerifyOops`(`develop`, `:2886`) —— `develop`/`notproduct` 标志在 `PRODUCT` 下**不编译**，故其**标志变量符号**只存在于非 product 构建。**校准证据（llvm-nm 实测）**：官方 Temurin 8u504 的 `libjvm.so` 与随包 JRE26 的 `libjvm.so` 上，这三条计数都是 **0**；而同一条正则对真实存在的标志（`UseG1GC`）能命中 ⇒ 机制有效。**禁用** jre26 那套模糊模式（`Metaspace::verify` / `report_assertion_failure` / `check_for_non_bad_heap_word_value`）：它们在**官方 product 件里也有**（实测 `Metaspace::verify*` 2 处、`check_for_non_bad_heap_word_value` 2 处；`Metaspace::verify_global_initialization` 走 `NOT_DEBUG_RETURN`，product 下同样有符号）——2026-09-28 曾因此**误拒一个合格构建** | `linux_build_jvm.sh` |

## 5. 待办

1. **（应用侧，下一步）** 多 JRE 骨架：`多JRE共存-方案.md` §4 的 P0/P1（`PurgeStaleJreData` 白名单、令牌按 id、
   `hspLibsDir(id)`、传参链）+ 新 `type:shared` 模块 **`meowjrelegacy`** + `JavaPolicy` 选择逻辑（Forge ≤1.16.999 → 本套）。
   ⇒ 落到工程里 = 把本目录 `out/*.so` 铺进 `libs/meowjrelegacy/libs/arm64-v8a/`、把数据 tar 按 `<id>.tar.gz` 命名
   （= `meow_jre_legacy.tar.gz`）放进 `entry/src/main/resources/rawfile/`（**模块名与 rawfile 名都版本中性**）。
2. **（待验，真机）** ① 官方 8 件在 OHOS 上能否 `dlopen`/跑通；② `/proc/self/maps` 在 app 沙箱可读性
   （HotSpot 8 的线程栈/`is_initial_thread` 路径会读它；对照已知：`/proc/cpuinfo` 被禁，oshi 才要覆盖件）。
3. 复现性：JDK 8 是否认 `SOURCE_DATE_EPOCH` 未验（`MEOW_REUSE` 无关，跑 `linux_verify_jvm_repro.sh` 给结论，回写本文件）。
