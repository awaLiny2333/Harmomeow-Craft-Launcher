# tools/ — 自编资产构建工具（总索引）

本目录把 Meowcraft **所有自编/魔改随包件**的构建与打包固化下来，每个子目录自成一体、**路径全参数化**
（不假设调用者布局），可脱离本工程复用。目标：**别人接手也能 100% 复现**（同 tag + 同 SDK + 同构建路径 →
逐字节可复现，见各 README 的校验和）。

> 约定：**javac 必须由人跑**（沙箱内 shell 无可用 JVM）；native(C/C++/CMake/交叉编译) 与 python 打包 agent 可跑。
> 所有临时/调研产物进 `stuffs/`（勿用 `~/deveco/`）。

## 1. 外部源码仓（`ref/`，工作区级，不入 app 仓库）

| 仓 | 上游 | 用到的 tag | 获取 |
|---|---|---|---|
| `ref/lwjgl3` | https://github.com/LWJGL/lwjgl3.git | `3.4.3` | `git clone https://github.com/LWJGL/lwjgl3.git ref/lwjgl3`（含全部 tag；3.4.3 另建 worktree，见 tools/lwjgl） |
| `ref/lwjgl` | https://github.com/LWJGL/lwjgl.git | commit `2df01dd7`（`lwjgl2.9.3-19-g2df01dd7`） | `git clone https://github.com/LWJGL/lwjgl.git ref/lwjgl`（**LWJGL2**，服务 MC **1.6.x–1.12.2**，见 `tools/lwjgl2/`） |
| `ref/gl4es` | https://github.com/ptitSeb/gl4es.git | `v1.1.7`（`v1.1.6-91-g81547d98`） | `git clone https://github.com/ptitSeb/gl4es.git ref/gl4es`（见 `tools/gl4es/`） |
| `ref/openal-soft` | https://github.com/kcat/openal-soft.git | `1.24.3` | `git clone https://github.com/kcat/openal-soft.git ref/openal-soft` |
| `ref/freetype` | https://gitlab.freedesktop.org/freetype/freetype | `VER-2-13-3` | 见 `tools/freetype/` |
| `ref/oshi` | https://github.com/oshi/oshi | 多版本 | 见 `tools/oshi/` |
| `ref/SDL` + `ref/SDL-3.4.14` | https://github.com/libsdl-org/SDL.git | `release-3.4.14` | `git clone … ref/SDL` → `git -C ref/SDL worktree add --detach "$WS/ref/SDL-3.4.14" release-3.4.14`（`$WS` = 工作区根；**必须绝对路径**，见 §4「worktree 路径基准」） |
| `ref/jdk26u` | https://github.com/openjdk/jdk26u.git | `jdk-26.0.2.1-ga` | **JDK 26 更新仓**（26.0.x 不在主线 `openjdk/jdk`！）——随包 JRE 自编件的精确源，见 `tools/jre26/` |
| `ref/{shaderc,glslang,SPIRV-Tools,SPIRV-Headers,spirv-cross}` | google/shaderc、KhronosGroup/* | 按官方 LWJGL natives 的 `.git` 标记钉修订 | `tools/shaderc/rebuild_for_meowcraft.sh` **自动 clone**（见 `tools/shaderc/README.md`） |

**其它外部输入**（按需下载，见各 README）：libffi 源码 tarball（`https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz`）、
LWJGL/gson/jspecify 走 Maven Central（脚本自动下载 + `.sha1` 校验）、OHOS SDK（`$HOME/devecow/deveco_tools/sdk/default/openharmony/native`，可用 `$OHOS_SDK_NATIVE` 覆盖）。

**JRE 收编输入**（见 `tools/jre26/`）：官方 OpenJDK **26.0.2.1**（aarch64 Linux，**glibc**，来自 `https://jdk.java.net/archive/`）
tar（`openjdk-26.0.2.1_linux-aarch64_bin.tar.gz`，sha256 `b96b265a4a1a36c02454148891aa58ca63303cbc2d1b7979c33b4fe99e09117b`）
+ OpenJDK 源码 **`https://github.com/openjdk/jdk26u`**（**更新仓**）的 **`jdk-26.0.2.1-ga`** tag（供自编 `libjli`+`libjvm`；
commit `d55edf1cba61…`，**与官方件 `release` 的 `SOURCE=git:d55edf1cba61` 精确对齐**）
+ 用户提供的 **openEuler 24.03 aarch64 容器**（编 `libjvm`；设备不能执行编译产物）。**零黑箱。**

## 2. 工具清单

| 工具 | 产出 | 说明 |
|---|---|---|
| `lwjgl/` | `lwjgl-3.4.3.jar`、`liblwjgl_343{,_opengl,_stb}.so`、`liblwjgl_vma.so`、`libffi.a`、`meowcraft_extras.tar.gz` | LWJGL 现代**单代 3.4.3**（含 3.4.x 兼容 shim；旧 3.3.3 已于 2026-09-14 退役）；含净室 overlay、GLCapabilities 生成器、libffi 交叉编、`install_natives.sh`（扁平目录治理）、多件打包 |
| `lwjgl2/` | `liblwjgl.so` | 自编 **LWJGL2** OHOS native（aarch64 裸名 `liblwjgl.so`，不带后缀）；**MC 1.6.x–1.12.2** 的 legacy 平台绑定（JNI_VERSION=19 跨 2.9.x 稳定）；只编 native，不重编 MC 的 `lwjgl-2.9.x.jar` |
| `gl4es/` | `libgl4es.so` | 自编 **gl4es v1.1.7** OHOS 移植（桌面固定管线 GL → 原生 GLES 翻译层）；**MC ≤1.16**（含 1.6.x–1.12.2，经 LWJGL2 `extgl` 取址）的渲染翻译层 |
| `openal/` | `libopenal.so` | OpenAL Soft **1.24.3** OHOS 移植（OHAudio 默认后端 + 导出 `ALC_SOFT_system_events`） |
| `freetype/` | `libfreetype.so` | FreeType 2.13.3 OHOS 交叉编 |
| `jre26/` | 随包 JRE 集（`libs/*.so` + `java.home` 数据） | **魔改官方 OpenJDK 26.0.2.1(glibc) 跑 OHOS(musl)，零黑箱**：官方 26 lib **原地改 `.dynstr`** + `libc6.so` 兼容层 + **自编 `libjli`** + **自编 `libjvm`**（openEuler 容器编，两件均带 OHOS 分体 patch，源 = 更新仓 `jdk26u` @ `jdk-26.0.2.1-ga`）；数据经 jlink 瘦身。见 `tools/jre26/README.md` |
| `jre25/` | —（历史配方） | **25 时代**的随包 JRE 配方/溯源（已发布版本）；随包 JRE 已升级到 26，**勿用于当前随包**。见 `tools/jre25/README.md` |
| `sdl/` | `libSDL3.so` | 自编 OHOS **SDL3**（fork tag `release-3.4.14`）+ 自研 **`ohos` 驱动**（窗口/EGL/输入/grab/**Vulkan WSI**）；**MC 26.3** 的平台绑定 |
| `shaderc/` | `libshaderc.so`、`libspirv-cross.so` | 自编（glslang/SPIRV-Tools 静态并入；按官方 natives `.git` 钉修订）；**MC 26.3 `renderpearl`** 用 |
| `oshi/` | `oshi-core-<v>-meow.jar` ×10 | CPU 拓扑合成补丁；**现代 9 项 + legacy `oshi-core-1.1`（MC 1.16.x）** |
| `meow-launcher/` | `launcher.jar` | 净室自研 `meow.launcher`（无 GPL/Pojav/HMCL） |
| `relocate_gson.py` | `gson-for-launcher.jar` | `com.google.gson` → `meow.gson`（launcher 专用） |
| ~~`slim_jre_data.py`~~ | ~~`meow_jre*.tar.gz`~~ | **已删除 2026-09-18**（旧 JRE 时代工具，代码卫生清理时随废弃项移除）。现用 `tools/jre26/linux_slim_jre.sh`（jlink 裁 modules）+ `tools/jre26/pack_jre_data.py`（确定性打包） |
| `oshi/pack_jar.py` | — | **确定性** jar 打包器（launcher/lwjgl/oshi 共用） |
| `lwjgl/build_lwjgl_core_aligned_alloc_fix.sh` | `liblwjgl_343.so`（F2 对齐修复） | 单件重编 core：把 `posix_memalign` 前的 `alignment` clamp 到 `>= sizeof(void*)`（OHOS musl 对 `alignment < 8` 返 EINVAL）。详见下方「单件脚本」 |
| `lwjgl/build_lwjgl_vma.sh` | `liblwjgl_vma.so`（`--release` 默认 / `--diagnostic`） | 参数化自编 VMA：release = 随包纯净件（逐字节一致）；diagnostic = 带 `[vma]` 诊断串、**不随包**。详见下方「单件脚本」 |

**单件重编 / 诊断脚本（native；均可独立跑通，`ref/` 只读）**：

- **`lwjgl/build_lwjgl_core_aligned_alloc_fix.sh`（F2 对齐 clamp）**
  - **用途**：重编 LWJGL core，在生成的 `__aligned_alloc` 里把 `alignment` clamp 到 `>= sizeof(void*)`（修 OHOS musl `posix_memalign` 对小对齐返 EINVAL——VMA 用 `alignof(RegionInfo)==2` 申请 32 MiB 块页表 ⇒ `memset(NULL,…)` SIGSEGV）。
  - **何时需要**：换 LWJGL core 源码/tag 重编、或怀疑该修复丢失时。
  - **与随包产物**：产出即随包 `liblwjgl_343.so`（`2a6fcf99…`）；旧件备份 `stuffs/research/vulkan/fixes/liblwjgl_343.so.pre-f2`（`16298280…`）。
  - **如何自证**：默认只编不装，跑完除断言导出集与随包**集合一致**外，还会把 `stuffs/research/lwjgl_f2_align/out/liblwjgl.so` 与随包 `libs/meowlwjgls/libs/arm64-v8a/liblwjgl_343.so` 做**逐字节 `cmp`**（输出 `IDENTICAL` 才算通过；链接器把绝对输出路径写进二进制，故必须用默认 `$WORK` 路径）；加 `--install` 才落盘 + 更新 `natives.manifest`。
- **`lwjgl/build_lwjgl_vma.sh`（VMA 参数化：`--release` 默认 / `--diagnostic`）**
  - **用途**：自编 `liblwjgl_vma.so`（MC 的所有 Vulkan 分配都走 VMA；LibVma 无 override key ⇒ 缺件是硬失败 "Failed to create VMA allocator"）。VMA 只从 Java 拿 Vulkan 函数指针 ⇒ 无 Vulkan `DT_NEEDED`，libc++ 静态链入（`DT_NEEDED` 仅 `libc.so`）。
  - **何时需要**：VMA 模块重编/升级。`--diagnostic` 仅用于排查函数表 NULL / `memset` 野指针，**不随包**。
  - **与随包产物**：**默认 release 与随包 `liblwjgl_vma.so` 逐字节一致**（`479a619f…`）；随包的是 release，随包件**不含任何 `[vma]` 串**。release 的可复现性同其它 native：链接器把绝对输出路径写进二进制，故只有用默认 `WORK`（`stuffs/research/vulkan/vma_build`，即该件的原始构建路径）才逐字节一致。
  - **如何自证**：`sh tools/lwjgl/build_lwjgl_vma.sh && cmp stuffs/research/vulkan/vma_build/out/liblwjgl_vma.so Harmomeow-Craft-Launcher/libs/meowlwjgls/libs/arm64-v8a/liblwjgl_vma.so && echo IDENTICAL`；`--diagnostic` 产物必须 **sha 不同**且 `strings … | grep '\[vma\]'` 命中。

## 3. 从零复现顺序（关键产物）

外部 SDK/仓就位后（§1）：

```sh
# A. LWJGL 单代 3.4.3（javac 那步由人跑；见 tools/lwjgl/README.md）
sh tools/lwjgl/build_libffi.sh --src stuffs/research/libffi/libffi-3.8.0 \
    --sdk-native $SDK/native --out stuffs/research/libffi/out-ohos            # ① libffi 3.8.0（3.4.x natives 用）
git -C ref/lwjgl3 worktree add --detach "$WS/ref/lwjgl3-3.4.3" 3.4.3          # ② 3.4.3 源码树（$WS = 工作区根；绝对路径见 §4）
sh tools/lwjgl/build_lwjgl_jar.sh --version 3.4.3 --overlay tools/lwjgl/deltas/overlay \
    --overlay tools/lwjgl/deltas/overlay-3.4.3      # ③ 3.4.3 jar（人跑 javac）；≥3.4.x 自动补 sdl/vma/spvc/shaderc 模块（MC 26.3）
sh tools/lwjgl/rebuild_for_meowcraft.sh 3.4.3                                # ④ 3.4.3 natives → liblwjgl_343{,_opengl,_stb}.so（自动带 libffi）
# （natives 由 install_natives.sh 统一命名 + 维护 libs/meowlwjgls/libs/natives.manifest；勿手工拷/改名）

# A0. 单件重编 / 诊断脚本（可选；详见 §2 末「单件脚本」）
sh tools/lwjgl/build_lwjgl_core_aligned_alloc_fix.sh          # F2 对齐修复（默认只编；--install 才随包 + 更新 manifest）
sh tools/lwjgl/build_lwjgl_vma.sh                             # VMA release（默认；应与随包 liblwjgl_vma.so 逐字节一致）
#   sh tools/lwjgl/build_lwjgl_vma.sh --diagnostic            # 诊断版（带 [vma] 串；勿随包）

python3 tools/lwjgl/pack_extras.py --base-tar entry/.../rawfile/meowcraft_extras.tar.gz \
    --jar lwjgl-3.4.3.jar=… --out entry/.../rawfile/meowcraft_extras.tar.gz   # ⑤ 组包

# A2. legacy 随包件（MC 1.6.x–1.16.x）
#   LWJGL2 native：**MC 1.6.x–1.12.2 由 tools/lwjgl2/ 的 liblwjgl.so 支持**（见 tools/lwjgl2/README.md）
git -C ref/lwjgl apply tools/lwjgl2/patches/0001-generator-filer-bypass.patch   # ① 一次性本地补丁
sh tools/lwjgl2/generate_sources.sh                                            # ② 生成源码（人跑 javac）
sh tools/lwjgl2/build_lwjgl2_meow.sh --src ref/lwjgl --sdk-native $SDK/native \
    --out stuffs/lwjgl2 --with-display                                         # ③ 编 liblwjgl.so（stage 2）
sh tools/lwjgl/install_natives.sh --native liblwjgl.so=stuffs/lwjgl2/liblwjgl.so  # ④ 随包（tag common）
#   gl4es：≤1.16 的 GL→GLES 翻译层（1.6.x–1.12.2 经 LWJGL2 extgl 取址；见 tools/gl4es/README.md）
sh tools/gl4es/rebuild_for_meowcraft.sh                                        # libgl4es.so
sh tools/lwjgl/install_natives.sh --native libgl4es.so=stuffs/research/gl4es/out/libgl4es.so

# B. 其它随包件
sh tools/openal/rebuild_for_meowcraft.sh 1.24.3          # libopenal.so（默认 tag）
sh tools/sdl/rebuild_for_meowcraft.sh                    # libSDL3.so（fork release-3.4.14；需先建 ref/SDL-3.4.14，见 §1）
sh tools/shaderc/rebuild_for_meowcraft.sh                # libshaderc.so + libspirv-cross.so（自动 clone ref/ 五仓并钉修订）
#   随包（均 gen-agnostic，manifest tag `common`）：
sh tools/lwjgl/install_natives.sh --sdl stuffs/research/sdl/out/libSDL3.so
sh tools/lwjgl/install_natives.sh --native libshaderc.so=stuffs/research/shaderc/out/libshaderc.so
sh tools/lwjgl/install_natives.sh --native libspirv-cross.so=stuffs/research/shaderc/out/libspirv-cross.so
sh tools/oshi/build_oshi_meow.sh …                       # oshi-overrides 现代 ×9（+ legacy 1.1，见 tools/oshi/README.md）
sh tools/meow-launcher/build_meow_launcher.sh            # launcher.jar（人跑 javac）
# JRE 集（魔改官方 glibc 件跑 OHOS，零黑箱；完整步骤见 tools/jre26/README.md 的「复现」）
#   0) 输入：解官方 tar 到 stuffs/research/jdk26/_inspect；clone **更新仓** openjdk/jdk26u → ref/jdk26u，
#      再 worktree jdk26u-src @ `jdk-26.0.2.1-ga`（26.0.x 不在主线 openjdk/jdk）
#   1) 容器(openEuler/aarch64)：装环境 + 编 libjvm(glibc) +（仅换官方输入时）jlink 瘦 modules
sh tools/jre26/linux_bootstrap.sh              # 容器内：装工具链 + boot JDK
sh tools/jre26/linux_build_jvm.sh              # 容器内：out-linux/libjvm.so（glibc，可复现；默认源 ref/jdk26u）
sh tools/jre26/linux_slim_jre.sh               # 容器内：out-linux/modules.slim（仅换官方输入时需要）
#   2) 宿主：组装（魔改 26 官方件 + 自编 libc6/libjli + 魔改 libjvm + 数据瘦身）
sh tools/jre26/rebuild_for_meowcraft.sh \
    --official-jdk stuffs/research/jdk26/_inspect/jdk-26.0.2.1 \
    --jdk-src      stuffs/research/jdk26/jdk26u-src \
    --libjvm       stuffs/research/jdk26/out-linux/libjvm.so \
    --modules-slim stuffs/research/jdk26/out-linux/modules.slim \
    --out          stuffs/research/jdk26/out

# C. 部署（改 libs 后必须先清模块 build；见下）
rm -rf libs/{meowlwjgls,meowjre,meowcraftlib}/build entry/build
devecocli build --modules entry meowjre      # 注意：不带 --modules 只出 HAP，不出 HSP
devecocli run --module entry meowjre --device <serial>
```

## 4. 通用坑（改 libs / 打包 / 部署）

- **hvigor 不追踪 `libs/<abi>/` 增删**：加了/删了 `.so` 后必须清模块 build 再 `build --modules entry meowjre`，
  否则 HSP 不重打（设备报 `… not found`）。见记忆 `meowcraft_hvigor_libs_delete_stale`。
- **natives 必须随包**：平台只对随包 native 打 fs-verity；运行时写入数据区的文件 `dlopen` 一律 EINVAL。
  故多版本 natives 同放一个随包目录、**世代号紧跟基名**区分（见 `tools/lwjgl/README.md`）。
- **确定性**：`pack_jar.py`（固定时间戳 + 排序）、`pack_extras.py`（gzip mtime=0 + 排序）→ 逐字节可复现。
- **jar 的 MANIFEST 必须自洽（2026-09-16 事故）**：凡**剥掉 `META-INF/**`** 的打包（我们全部打包器都这么做），
  **必须同时去掉 MANIFEST 的 `Multi-Release: true`** —— 否则产出「声称多版本 jar 却没有 `META-INF/versions/**`」
  的坏件；bootstraplauncher 1.1.2（NeoForge 1.20.2 用）会因此在 `SecureJar.from` 里 `Files.walk` 该目录抛异常、启动即崩。
  已在三处根治：`tools/lwjgl/build_lwjgl_jar.sh`、`tools/relocate_gson.py`、**共用打包器 `tools/oshi/pack_jar.py`（统一守卫 + 告警）**。
- **extras tar 组包配方（可复现，逐字节已验证）**：基座 tar 需含 `launcher.jar` + **未 shade 的** `gson-<v>.jar`（可另含 lwjgl jar，`pack_extras.py` 会丢弃同名 `lwjgl*`），然后
  `python3 tools/relocate_gson.py <base.tar.gz>` → `python3 tools/lwjgl/pack_extras.py --base-tar <base.tar.gz> --jar lwjgl-3.4.3.jar=<built> --require lwjgl-3.4.3.jar --out <final>`
  → 覆盖 `entry/.../rawfile/meowcraft_extras.tar.gz` 并**升 `EXTRAS_VERSION`**。
- **JRE 可复现**：`libc6.so`/`libjli.so`、官方 26 件魔改、数据 tar（`tools/jre26/pack_jre_data.py`）均**逐字节**；自编 `libjvm` 同 OS/工具链/源/**同路径** + `SOURCE_DATE_EPOCH=1784133400`（`jdk-26.0.2.1-ga` 提交）**2× cmp 一致**（`d28164cd…`；`linux_verify_jvm_repro.sh` 默认 2，`MEOW_REPRO_N` 可调高。见 `tools/jre26/README.md` §可复现性）。
- **★ `git -C <repo> …` 里的路径基准是 `<repo>`，不是你的 cwd（2026-09-19 事故）**：`git -C ref/SDL worktree add --detach ref/SDL-3.4.14 …`
  会在 `ref/SDL/` **里面**建出 `ref/SDL/ref/SDL-3.4.14`（文档里多处曾这么写，已改）。⇒ **建/删 worktree 一律用绝对路径**（或相对该 repo 的 `../…`）；
  删错建的树也用绝对路径 + `worktree prune`，并顺手清掉留下的**空父目录**。自证：`git -C <repo> worktree list`。
- **native 可复现**：同 tag + 同 SDK + **同 `--src`/`--out` 绝对路径** → 逐字节一致（链接器把输出路径写进 `.dynstr`；换路径同功能、哈希不同）。本工具链的新原生已 **3× 干净重建 `cmp` 一致**（对照 2026-09-11 盘上随包件）：`libSDL3.so`(`5f8b551f…`；2026-09-21 已并入 Vulkan、失焦暂停、剪贴板写与打开网址，各阶段**从零 3 轮 15 次**逐字节重验；2026-09-23 **输入收尾（最小必需集）轮**：游戏发起的指针移动/归中一律无条件 no-op（`OHOS_WarpMouse`、桥 `meowGrabReset`、`glfwSetCursorPos` 都不写光标槽/不发 motion），出 grab（1→0）边沿强制一次绝对上报（服务「返回游戏」按钮高亮）；同时移除本轮试错/诊断改动（含其共享状态字段，状态块布局回归 HEAD），仅保留一条低频 `WARP ignored` 证明 no-op 生效；1× 重建即 `5f8b551f…`，迭代轮不做 2×/`cmp`；权威清单见 [`notes/30-supply-chain/assets-digests.txt`](../../notes/30-supply-chain/assets-digests.txt))、`libshaderc.so`(`0cff3465…`)、`libspirv-cross.so`(`93ad9907…`)、`liblwjgl.so`(`df886466…`)；其中 `spirv-cross` 需 `SOURCE_DATE_EPOCH`（`tools/shaderc/build_shaderc_meow.sh` 已内置，取 pinned 提交时间）。`libgl4es.so`(`90c6ff6b…`) 同路径下**预期**可复现（见 `tools/gl4es/README.md`，尚未 3× 验证）。**VMA / F2 单件**：`liblwjgl_vma.so` release(`479a619f…`，默认 `WORK=stuffs/research/vulkan/vma_build`) 与随包件 `cmp` 一致、`liblwjgl_343.so` F2(`2a6fcf99…`，`libs/meowlwjgls/libs/arm64-v8a/`) —— 见 §2「单件脚本」；VMA 诊断版(`64cba35f…`)仅存在于 `stuffs/`、**不随包**。
- **构建期断言（缺件在发包时拦下，运行期不加防护）**：`pack_extras.py --require <member>`（断言 tar 成员齐，如 `lwjgl-3.4.3.jar`）；
  `install_natives.sh --verify`（断言 `natives.manifest` 每项在盘且 sha 匹配）。缺件属"我们发包可掌控"→ 只在构建期拦，不在运行时查（省开销）。
- **javac**：任何 `.jar` 步骤沙箱内不可跑，须人在有 JDK 的 shell 执行。

## 5. 权威文档

- **工具内详解**：`tools/lwjgl/README.md` §1（**overlay 机制**：为什么要覆盖 / 5 步流水线 / 两层判据 / 加代清单），§2–§4（3.4.3 构建 / 打包 / digests）。
- **JRE 收编**：`tools/jre26/README.md`（现役：输入/工序/可复现/digests/与 25 差异；源 = 更新仓 `jdk26u` @ `jdk-26.0.2.1-ga`）、`tools/jre25/README.md`（历史）。
- **legacy（MC 1.6.x–1.16.x）**：`tools/lwjgl2/README.md`（LWJGL2 `liblwjgl.so`：生成/编译/随包/踩坑/可复现）、`tools/gl4es/README.md`（gl4es `libgl4es.so`：NOEGL 宿主自持上下文）。
- **SDL3 / shaderc**：`tools/sdl/README.md`（拉取/补丁/驱动文件/digest）、`tools/shaderc/README.md`；复盘 `notes/20-design/render/SDL3适配-复盘.md`（§一 时间线、**§七 Vulkan 接通**）、方案 `notes/20-design/render/SDL3桥接-设计.md`。
- 设计/流程：`notes/20-design/launch/launcher净室-设计.md`、`notes/20-design/render/GLFW净室桥-设计.md`、`notes/20-design/lwjgl/LWJGL3世代管理-方案.md`、`notes/20-design/lwjgl/LWJGL3单代收敛-决策依据.md`、`notes/20-design/lwjgl/LWJGL2自编-方案.md`
- 适配/移植：`notes/40-adaptation/{openal-ohos,ohaudio-backend,freetype-ohos,oshi-cpu-info,launcher-rebuild}.md`
- 溯源/校验和：`notes/30-supply-chain/{provenance-master.md,assets-digests.txt,per-so-catalog.md}`
- 现状总览：`notes/00-current/{现状基线.md,架构决策与踩坑.md}`

## 6. 可安全删除的 scratch / 缓存（按配方重建）

以下目录**只用于重建**、不参与运行；需要时按配方重生成（已实测可删、可重建）：

| 路径 | 是什么 | 重建方式 |
|---|---|---|
| `stuffs/research/**` | 构建/调研临时产物（`lwjgl_build*` / `lwjgl_natives*` / `libffi` / `openal` / `gl4es` / `jdk25` / `jdk26` …） | 按 §3 顺序重跑对应脚本（各 README 有配方） |
| `stuffs/lwjgl2/` | LWJGL2 native 构建/复现产物（`build/`、`repro/`、`liblwjgl.so`） | `sh tools/lwjgl2/build_lwjgl2_meow.sh --src ref/lwjgl --sdk-native $SDK/native --out stuffs/lwjgl2 --with-display` |
| `ref/lwjgl/{bin-meow,src/hdrs-meow,src/generated,src/native/generated}` | LWJGL2 生成物（补丁加入 `.gitignore`，可删可重建） | `sh tools/lwjgl2/generate_sources.sh`（需先 `git apply` 补丁） |
| `ref/openal-soft.build/` | OpenAL worktree（tag 1.24.3，已打补丁）+ build 目录 | `sh tools/openal/rebuild_for_meowcraft.sh 1.24.3`（自动建 worktree + 补丁 + 编译） |
| `ref/lwjgl3-3.4.3/` | LWJGL 3.4.3 tag 的 git worktree（纯 tag，无独特改动） | `git -C ref/lwjgl3 worktree add --detach "$WS/ref/lwjgl3-3.4.3" 3.4.3` |
| `ref/SDL-3.4.14/` | SDL fork 的 tag worktree（`release-3.4.14`；**patcher 会就地打补丁** ⇒ `git status` 非空属正常） | `git -C ref/SDL worktree add --detach "$WS/ref/SDL-3.4.14" release-3.4.14`；要回到"干净树"（撤销 patcher 改动）就 `worktree remove --force` 后重加，见 `tools/sdl/README.md` §3 末 |
| `ref/jna-cache/` | JNA jar 下载缓存（oshi 构建用） | oshi 构建时**自动重下**（见 `tools/oshi/README.md`） |

- 删 **worktree** 务必用 `git -C ref/<repo> worktree remove --force <path>`（或 `rm -rf` 后 `git -C ref/<repo> worktree prune`），否则留悬挂条目。
- `ref/` 只保留**源码 clone**（`lwjgl3` / `lwjgl` / `openal-soft` / `freetype` / `oshi` / `gl4es` / `jdk26u`）作为可重建输入；外部参照仓（`Amethyst-Android` / `HMCL` / `HomoLauncher` / `PojavLauncher_iOS`）**不入 app 仓库、不随包**，**保留供继续学习参考（用户决定：勿删）**。
- 2026-09-10：已删 `ref/openal-soft.build`(18M) + `ref/lwjgl3-3.4.3`(174M) + `ref/jna-cache`(15M)，共省 ~207M（按上表重建）。
