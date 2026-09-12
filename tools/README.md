# tools/ — 自编资产构建工具（总索引）

本目录把 Meowcraft **所有自编/魔改随包件**的构建与打包固化下来，每个子目录自成一体、**路径全参数化**
（不假设调用者布局），可脱离本工程复用。目标：**别人接手也能 100% 复现**（同 tag + 同 SDK + 同构建路径 →
逐字节可复现，见各 README 的校验和）。

> 约定：**javac 必须由人跑**（沙箱内 shell 无可用 JVM）；native(C/C++/CMake/交叉编译) 与 python 打包 agent 可跑。
> 所有临时/调研产物进 `stuffs/`（勿用 `~/deveco/`）。

## 1. 外部源码仓（`ref/`，工作区级，不入 app 仓库）

| 仓 | 上游 | 用到的 tag | 获取 |
|---|---|---|---|
| `ref/lwjgl3` | https://github.com/LWJGL/lwjgl3.git | `3.3.3`、`3.4.3` | `git clone https://github.com/LWJGL/lwjgl3.git ref/lwjgl3`（含全部 tag；3.4.3 另建 worktree，见 tools/lwjgl） |
| `ref/lwjgl` | https://github.com/LWJGL/lwjgl.git | commit `2df01dd7`（`lwjgl2.9.3-19-g2df01dd7`） | `git clone https://github.com/LWJGL/lwjgl.git ref/lwjgl`（**LWJGL2**，服务 MC **1.6.x–1.12.2**，见 `tools/lwjgl2/`） |
| `ref/gl4es` | https://github.com/ptitSeb/gl4es.git | `v1.1.7`（`v1.1.6-91-g81547d98`） | `git clone https://github.com/ptitSeb/gl4es.git ref/gl4es`（见 `tools/gl4es/`） |
| `ref/openal-soft` | https://github.com/kcat/openal-soft.git | `1.24.3` | `git clone https://github.com/kcat/openal-soft.git ref/openal-soft` |
| `ref/freetype` | https://gitlab.freedesktop.org/freetype/freetype | `VER-2-13-3` | 见 `tools/freetype/` |
| `ref/oshi` | https://github.com/oshi/oshi | 多版本 | 见 `tools/oshi/` |
| `ref/SDL` + `ref/SDL-3.4.14` | https://github.com/libsdl-org/SDL.git | `release-3.4.14` | `git clone … ref/SDL` → `git -C ref/SDL worktree add --detach ref/SDL-3.4.14 release-3.4.14`（见 `tools/sdl/`） |
| `ref/{shaderc,glslang,SPIRV-Tools,SPIRV-Headers,spirv-cross}` | google/shaderc、KhronosGroup/* | 按官方 LWJGL natives 的 `.git` 标记钉修订 | `tools/shaderc/rebuild_for_meowcraft.sh` **自动 clone**（见 `tools/shaderc/README.md`） |

**其它外部输入**（按需下载，见各 README）：libffi 源码 tarball（`https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz`）、
LWJGL/gson/jspecify 走 Maven Central（脚本自动下载 + `.sha1` 校验）、OHOS SDK（`$HOME/devecow/deveco_tools/sdk/default/openharmony/native`，可用 `$OHOS_SDK_NATIVE` 覆盖）。

**JRE 收编输入**（见 `tools/jre25/`）：官方 OpenJDK **25.0.2**（aarch64 Linux，**glibc**，来自 `https://jdk.java.net/archive/`）
tar（`openjdk-25.0.2_linux-aarch64_bin.tar.gz`，sha256 `671208d205e70c9805da45a483f670d49dd64654990a7b7223ccffb2abb070dd`）
+ OpenJDK 源码 **`https://github.com/openjdk/jdk`** 的 **`jdk-25-ga`** tag（供自编 `libjli`+`libjvm`；commit `6c48f4ed…`）
+ 用户提供的 **openEuler 24.03 aarch64 容器**（编 `libjvm`；设备不能执行编译产物）。**零黑箱。**

## 2. 工具清单

| 工具 | 产出 | 说明 |
|---|---|---|
| `lwjgl/` | `lwjgl-<ver>.jar`、`liblwjgl{,_opengl,_stb}_<digits>.so`、`libffi.a`、`meowcraft_extras.tar.gz` | LWJGL **两代并存**（3.3.3 + 3.4.3，natives 统一后缀 `_333`/`_343`）；含净室 overlay、GLCapabilities 生成器、libffi 交叉编、`install_natives.sh`（扁平目录治理）、多件打包 |
| `lwjgl2/` | `liblwjgl.so` | 自编 **LWJGL2** OHOS native（aarch64 裸名 `liblwjgl.so`，不带后缀）；**MC 1.6.x–1.12.2** 的 legacy 平台绑定（JNI_VERSION=19 跨 2.9.x 稳定）；只编 native，不重编 MC 的 `lwjgl-2.9.x.jar` |
| `gl4es/` | `libgl4es.so` | 自编 **gl4es v1.1.7** OHOS 移植（桌面固定管线 GL → 原生 GLES 翻译层）；**MC ≤1.16**（含 1.6.x–1.12.2，经 LWJGL2 `extgl` 取址）的渲染翻译层 |
| `openal/` | `libopenal.so` | OpenAL Soft **1.24.3** OHOS 移植（OHAudio 默认后端 + 导出 `ALC_SOFT_system_events`） |
| `freetype/` | `libfreetype.so` | FreeType 2.13.3 OHOS 交叉编 |
| `jre25/` | 随包 JRE 集（`libs/*.so` + `java.home` 数据） | **魔改官方 OpenJDK 25.0.2(glibc) 跑 OHOS(musl)，零黑箱**：官方 26 lib **原地改 `.dynstr`** + `libc6.so` 兼容层 + **自编 `libjli`** + **自编 `libjvm`**（openEuler 容器编，两件均带 OHOS 分体 patch）；数据经 jlink 瘦身。见 `tools/jre25/README.md` |
| `sdl/` | `libSDL3.so` | 自编 OHOS **SDL3**（fork tag `release-3.4.14`）+ 自研 **`ohos` 驱动**（窗口/EGL/输入/grab）；**MC 26.3** 的平台绑定 |
| `shaderc/` | `libshaderc.so`、`libspirv-cross.so` | 自编（glslang/SPIRV-Tools 静态并入；按官方 natives `.git` 钉修订）；**MC 26.3 `renderpearl`** 用 |
| `oshi/` | `oshi-core-<v>-meow.jar` ×10 | CPU 拓扑合成补丁；**现代 9 项 + legacy `oshi-core-1.1`（MC 1.16.x）** |
| `meow-launcher/` | `launcher.jar` | 净室自研 `meow.launcher`（无 GPL/Pojav/HMCL） |
| `relocate_gson.py` | `gson-for-launcher.jar` | `com.google.gson` → `meow.gson`（launcher 专用） |
| ~~`slim_jre_data.py`~~ | ~~`meow_jre25.tar.gz`~~ | **已废弃**（旧 JRE 时代工具）。现用 `tools/jre25/linux_slim_jre.sh`（jlink 裁 modules）+ `tools/jre25/pack_jre_data.py`（确定性打包） |
| `oshi/pack_jar.py` | — | **确定性** jar 打包器（launcher/lwjgl/oshi 共用） |

## 3. 从零复现顺序（关键产物）

外部 SDK/仓就位后（§1）：

```sh
# A. LWJGL 两代（javac 那步由人跑；见 tools/lwjgl/README.md）
sh tools/lwjgl/build_libffi.sh --src stuffs/research/libffi/libffi-3.8.0 \
    --sdk-native $SDK/native --out stuffs/research/libffi/out-ohos            # ① libffi 3.8.0（3.4.x natives 用）
git -C ref/lwjgl3 worktree add --detach ref/lwjgl3-3.4.3 3.4.3               # ② 3.4.3 源码树
sh tools/lwjgl/build_lwjgl_jar.sh --version 3.3.3 --overlay tools/lwjgl/deltas/overlay \
    --overlay tools/lwjgl/deltas/overlay-3.3.3                                                       # ③a 3.3.3 jar（人跑 javac）
sh tools/lwjgl/build_lwjgl_jar.sh --version 3.4.3 --overlay tools/lwjgl/deltas/overlay \
    --overlay tools/lwjgl/deltas/overlay-3.4.3      # ③b 3.4.3 jar（人跑）；≥3.4.x 自动补 sdl/vma/spvc/shaderc 模块（MC 26.3）
sh tools/lwjgl/rebuild_for_meowcraft.sh 3.3.3                                # ④a 3.3.3 natives → 构建并安装 liblwjgl*_333.so
sh tools/lwjgl/rebuild_for_meowcraft.sh 3.4.3                                # ④b 3.4.3 natives → liblwjgl*_343.so（自动带 libffi）
# （natives 由 install_natives.sh 统一命名 + 维护 libs/meowlwjgl3/libs/natives.manifest；勿手工拷/改名）
python3 tools/lwjgl/pack_extras.py --base-tar entry/.../rawfile/meowcraft_extras.tar.gz \
    --jar lwjgl-3.3.3.jar=… --jar lwjgl-3.4.3.jar=… --out entry/.../rawfile/meowcraft_extras.tar.gz   # ⑤ 组包

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
# JRE 集（魔改官方 glibc 件跑 OHOS，零黑箱；完整步骤见 tools/jre25/README.md 的「复现」）
#   0) 输入：解官方 tar 到 stuffs/research/jdk25/_inspect；clone openjdk/jdk 建 jdk-25-ga 源码树
#   1) 容器(openEuler/aarch64)：装环境 + 编 libjvm(glibc) + jlink 瘦 modules
sh tools/jre25/linux_bootstrap.sh              # 容器内：装工具链 + boot JDK
sh tools/jre25/linux_build_jvm.sh              # 容器内：out-linux/libjvm.so（glibc，可复现）
sh tools/jre25/linux_slim_jre.sh               # 容器内：out-linux/modules.slim
#   2) 宿主：组装（魔改 26 官方件 + 自编 libc6/libjli + 魔改 libjvm + 数据瘦身）
sh tools/jre25/rebuild_for_meowcraft.sh \
    --official-jdk stuffs/research/jdk25/_inspect/jdk-25.0.2 \
    --jdk-src      stuffs/research/jdk25/jdk25src \
    --libjvm       stuffs/research/jdk25/out-linux/libjvm.so \
    --modules-slim stuffs/research/jdk25/out-linux/modules.slim \
    --out          stuffs/research/jdk25/out

# C. 部署（改 libs 后必须先清模块 build；见下）
rm -rf libs/{meowlwjgl3,meowjre25,meowcraftlib}/build entry/build
devecocli build --modules entry meowjre25      # 注意：不带 --modules 只出 HAP，不出 HSP
devecocli run --module entry meowjre25 --device <serial>
```

## 4. 通用坑（改 libs / 打包 / 部署）

- **hvigor 不追踪 `libs/<abi>/` 增删**：加了/删了 `.so` 后必须清模块 build 再 `build --modules entry meowjre25`，
  否则 HSP 不重打（设备报 `… not found`）。见记忆 `meowcraft_hvigor_libs_delete_stale`。
- **natives 必须随包**：平台只对随包 native 打 fs-verity；运行时写入数据区的文件 `dlopen` 一律 EINVAL。
  故多版本 natives 同放一个随包目录、用**后缀名**区分（见 `tools/lwjgl/README.md`）。
- **确定性**：`pack_jar.py`（固定时间戳 + 排序）、`pack_extras.py`（gzip mtime=0 + 排序）→ 逐字节可复现。
- **JRE 可复现**：`libc6.so`/`libjli.so`（各 **3× cmp**）、26 官方件魔改（2× cmp）、数据 tar（`tools/jre25/pack_jre_data.py`，2× cmp）均**逐字节**；自编 `libjvm` 同 OS/工具链/源/**同路径** + `SOURCE_DATE_EPOCH=1755018936` **3× cmp 一致**（见 `tools/jre25/README.md` §可复现性）。
- **native 可复现**：同 tag + 同 SDK + **同 `--src`/`--out` 绝对路径** → 逐字节一致（链接器把输出路径写进 `.dynstr`；换路径同功能、哈希不同）。本工具链的新原生已 **3× 干净重建 `cmp` 一致**（对照 2026-09-11 盘上随包件）：`libSDL3.so`(`241bbfef…`)、`libshaderc.so`(`0cff3465…`)、`libspirv-cross.so`(`93ad9907…`)、`liblwjgl.so`(`df886466…`)；其中 `spirv-cross` 需 `SOURCE_DATE_EPOCH`（`tools/shaderc/build_shaderc_meow.sh` 已内置，取 pinned 提交时间）。`libgl4es.so`(`90c6ff6b…`) 同路径下**预期**可复现（见 `tools/gl4es/README.md`，尚未 3× 验证）。
- **构建期断言（缺件在发包时拦下，运行期不加防护）**：`pack_extras.py --require <member>`（断言 tar 成员齐，如各代 `lwjgl-<gen>.jar`）；
  `install_natives.sh --verify`（断言 `natives.manifest` 每项在盘且 sha 匹配）。缺件属"我们发包可掌控"→ 只在构建期拦，不在运行时查（省开销）。
- **javac**：任何 `.jar` 步骤沙箱内不可跑，须人在有 JDK 的 shell 执行。

## 5. 权威文档

- **工具内详解**：`tools/lwjgl/README.md` §1（**overlay 机制**：为什么要覆盖 / 5 步流水线 / 两层判据 / 加代清单），§2–§4（各代构建 / 打包 / digests）。
- **legacy（MC 1.6.x–1.16.x）**：`tools/lwjgl2/README.md`（LWJGL2 `liblwjgl.so`：生成/编译/随包/踩坑/可复现）、`tools/gl4es/README.md`（gl4es `libgl4es.so`：NOEGL 宿主自持上下文）。
- **SDL3 / shaderc**：`tools/sdl/README.md`（拉取/补丁/驱动文件/digest）、`tools/shaderc/README.md`；复盘对照 `notes/20-design/26.3-SDL适配复盘.md`、方案 `notes/20-design/sdl3桥接方案.md`。
- 设计/流程：`notes/20-design/{净室-meow-launcher,净室-lwjgl-glfw-bridge,lwjgl自编方案,lwjgl多版本并存方案}.md`
- 适配/移植：`notes/40-adaptation/{openal-ohos,ohaudio-backend,freetype-ohos,oshi-cpu-info,launcher-rebuild}.md`
- 溯源/校验和：`notes/30-supply-chain/{provenance-master.md,assets-digests.txt,per-so-catalog.md}`
- 现状总览：`notes/00-current/{现状基线.md,架构决策与踩坑.md}`

## 6. 可安全删除的 scratch / 缓存（按配方重建）

以下目录**只用于重建**、不参与运行；需要时按配方重生成（已实测可删、可重建）：

| 路径 | 是什么 | 重建方式 |
|---|---|---|
| `stuffs/research/**` | 构建/调研临时产物（`lwjgl_build*` / `lwjgl_natives*` / `libffi` / `openal` / `gl4es` …） | 按 §3 顺序重跑对应脚本（各 README 有配方） |
| `stuffs/lwjgl2/` | LWJGL2 native 构建/复现产物（`build/`、`repro/`、`liblwjgl.so`） | `sh tools/lwjgl2/build_lwjgl2_meow.sh --src ref/lwjgl --sdk-native $SDK/native --out stuffs/lwjgl2 --with-display` |
| `ref/lwjgl/{bin-meow,src/hdrs-meow,src/generated,src/native/generated}` | LWJGL2 生成物（补丁加入 `.gitignore`，可删可重建） | `sh tools/lwjgl2/generate_sources.sh`（需先 `git apply` 补丁） |
| `ref/openal-soft.build/` | OpenAL worktree（tag 1.24.3，已打补丁）+ build 目录 | `sh tools/openal/rebuild_for_meowcraft.sh 1.24.3`（自动建 worktree + 补丁 + 编译） |
| `ref/lwjgl3-3.4.3/` | LWJGL 3.4.3 tag 的 git worktree（纯 tag，无独特改动） | `git -C ref/lwjgl3 worktree add --detach ref/lwjgl3-3.4.3 3.4.3` |
| `ref/jna-cache/` | JNA jar 下载缓存（oshi 构建用） | oshi 构建时**自动重下**（见 `tools/oshi/README.md`） |

- 删 **worktree** 务必用 `git -C ref/<repo> worktree remove --force <path>`（或 `rm -rf` 后 `git -C ref/<repo> worktree prune`），否则留悬挂条目。
- `ref/` 只保留**源码 clone**（`lwjgl3` / `lwjgl` / `openal-soft` / `freetype` / `oshi` / `gl4es`）作为可重建输入；外部参照仓（`Amethyst-Android` / `HMCL` / `HomoLauncher` / `PojavLauncher_iOS`）**不入 app 仓库、不随包**，**保留供继续学习参考（用户决定：勿删）**。
- 2026-09-10：已删 `ref/openal-soft.build`(18M) + `ref/lwjgl3-3.4.3`(174M) + `ref/jna-cache`(15M)，共省 ~207M（按上表重建）。
