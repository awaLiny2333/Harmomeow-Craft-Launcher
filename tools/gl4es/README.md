# tools/gl4es/ — 自编 OHOS gl4es（≤1.16/legacy FPE + 1.17–1.21.x GL3 core）

上游：**ptitSeb/gl4es**（MIT）。用途：给 **MC ≤1.16**（用固定管线 GL；`RendererPolicy` 对所有 `<1.17` 生效）提供
"桌面 GL 1.x/2.x → 原生 OpenGL ES" 的固定管线翻译层，绕开系统 `libGLv4.so`（Mesa Zink）
compat 路径的渲染错乱。详见 `notes/20-design/render/legacy渲染-gl4es-落地方案.md`。

> 同一 `libgl4es.so` 也是 **MC 1.6.x–1.12.2**（`tools/lwjgl2/` 的 LWJGL2 legacy 路径）的 GL 提供者：
> LWJGL2 native 的 `extgl` 经 `MEOW_LWJGL2_GL`（默认 `libgl4es.so`）取址，见 `tools/lwjgl2/README.md` §3。

> 版本：`ref/gl4es` = v1.1.7（`v1.1.6-91-g81547d98`）。**不带 `--delta` 的上游配方**只走 FPE、shader 转换内建
> （不依赖 glslang/SPIRV-Cross）；**当前随包产物 = 带 `--delta deltas/glcore` 的构建**，它另含 **GL3 core 后端**
> （GL 3.2/3.3 → 原生 GLES 3.2）。core 路径的着色器翻译在**运行期 `dlopen`** 与 `libgl4es.so` **同目录**的
> `libshaderc.so` + `libspirv-cross.so`（随包在 `meowjre` HSP 的 `libs/arm64/`，两者都已登记进
> `natives.manifest`；自编配方见 `tools/shaderc/`）⇒ `libgl4es.so` 自身 `DT_NEEDED` 仍仅 `libc.so`。
> 需要新增"ES 非法用法"规则时的落点与清单见 `notes/20-design/render/GL33到GLES32-后端-方案.md` §16–§18。
> 不使用已归档的 `ref/NG-GL4ES` fork（它是黑盒 `libng_gl4es.so` 的出处）。

## 产物

`libgl4es.so`（由 gl4es 的 `libGL.so.1` 改名而来，因 **hvigor 只打包顶层 `*.so`**）：
- ELF arm64，`DT_NEEDED` 仅 `libc.so`，`SONAME=libGL.so.1`，`.note.ohos.ident`，stripped。
- 导出桌面裸名 `gl*`（含固定管线真实现：`glMatrixMode`/`glEnableClientState`/`glFogfv`/`glBegin`…）。
- `glGetString(GL_VERSION)`：FPE 路径报 `2.1 gl4es wrapper 1.1.7`；**GL3 core 后端报 `3.3 Meowcraft (GLES 3.2 backend)`**（当前随包产物走 core）。

## 构建（从零复现）

```sh
sh tools/gl4es/rebuild_for_meowcraft.sh        # 用 ref/gl4es，产物落 stuffs/research/gl4es/out/
# fork delta（本仓自有改动）：把 ref/gl4es 拷到副本、叠加 deltas/<name>、再从副本构建（不改 ref/）
sh tools/gl4es/rebuild_for_meowcraft.sh --delta tools/gl4es/deltas/glcore
# 通用：sh tools/gl4es/build_gl4es_meow.sh --src <gl4es> --sdk-native <sdk/native> --out <dir>
```

关键编译项（`build_gl4es_meow.sh` 内置）：
```
NOX11=1   NOEGL=1   DEFAULT_ES=2   NO_INIT_CONSTRUCTOR=1
GBM=OFF   EGL_WRAPPER=OFF   GLX_STUBS=OFF   STATICLIB=OFF
```
- **`NOEGL=1`**：gl4es 不管 EGL/窗口 —— **宿主自建 GLES context + surface 并 make current**。
- **`NO_INIT_CONSTRUCTOR=1`**：不在库构造器里自动 init；宿主在 context current 后显式调 `initialize_gl4es()`。

> **★ 坑**：OHOS 工具链把 `CMAKE_SYSTEM_NAME` 设成 `OHOS`，而 gl4es 的 `src/CMakeLists.txt` 只在
> `MATCHES "Linux"` 时才编 `glx/*`（提供 `glXGetProcAddress`）→ 必须用本目录的
> `gl4es_ohos.toolchain.cmake`（OHOS→Linux 伪装）重标；否则静默丢符号。

## 装进工程

```sh
sh tools/lwjgl/install_natives.sh --native libgl4es.so=stuffs/research/gl4es/out/libgl4es.so
# 落 libs/meowlwjgls/libs/arm64-v8a/libgl4es.so + natives.manifest（tag common）
```

## 运行期模型（宿主自持上下文）

1. 宿主用 **GLES** 建 `EGLDisplay/Config/Context(ES)/WindowSurface` 并 `eglMakeCurrent`。
2. `dlopen("libgl4es.so")` → `initialize_gl4es()`（**必须 context 已 current**）。
3. 之后用 LWJGL 驱动：`-Dorg.lwjgl.opengl.libname=<...>/libgl4es.so`；交换缓冲由宿主 `eglSwapBuffers`。
4. env：桥（gl4es 模式）设置 `LIBGL_ES=2 LIBGL_GL=21 LIBGL_NORMALIZE=1 LIBGL_NOINTOVLHACK=1 LIBGL_NOERROR=0 LIBGL_NOBANNER=1 LIBGL_SILENTSTUB=1`，并在探测到可加载的原生 GLES 后设 `LIBGL_GLES`。

## 复现/校验

- 构建期断言（`build_gl4es_meow.sh`）：导出含固定管线入口（`glMatrixMode/glEnableClientState/glFogfv/glBegin/glGetString/glViewport`）**与运行期 dlsym 目标**（`glXGetProcAddress/initialize_gl4es/set_getmainfbsize/set_getprocaddress`）；`DT_NEEDED` 仅 `libc.so` 等白名单。
- ⚠️ **不带 `--delta` 的上游配方不可逐字节复现**：`ref/gl4es/src/gl/build_info.c` 把 `__DATE__`/`__TIME__` 编进二进制，且本机 clang **不认** `SOURCE_DATE_EPOCH`（实测无效；`-D__DATE__="…"` 因 `CMAKE_C_FLAGS` 按空格切分亦不可行）⇒ 每次构建只差日期/时间串。另：**裸配方按上游 CMake 行为把产物写进 `<src>/lib/`**（即 `ref/gl4es/lib/libGL.so.1`，该目录 gitignore）⇒ **"从不改 `ref/`" 只对带 `--delta` 的配方成立**。
- **带 `--delta` 的配方逐字节可复现（⚠️ 前提：同命令、同 `--src`/`--out`/`--build` 路径 —— 跨路径不可，见文末实测边界）**：`deltas/glcore` 覆盖 `build_info.c`（去掉时间戳）并加入 **GL3 核心后端**；另加 `-DCMAKE_SKIP_RPATH=ON`（否则产物会带一条指向**临时副本目录**的 `RUNPATH` —— 开发路径泄漏）。**当前基准 = r16**：digest `f96d54a573772bdd1330c1ccdfe51b324188bcd54f89034758fbf05303769d04`，**1,255,704 B**（r13/r14/r15 中间基准 `24cd5f33…`/`3e152749…`/`0c2075e7…`，同为 1,255,704 B；r11/r12 = `aac4a628…`/`7babd51c…`；上一稳定基准 r10 = `2c2b6f09…`，1,251,608 B；再早 r9 = `2fbf08bc…`，1,251,608 B；r6/r7/r8 = `6c9065bb…`/`7f0fa55a…`/`637c033d…`，均 1,247,512 B）——**digest 随 delta 变化而变，换装时同步更新**（随包件 `libs/meowlwjgls/libs/natives.manifest` 同步）。⚠️ 本配方**逐字节可复现但与"注释放多少行"有关**（RelWithDebInfo ⇒ 行号/调试信息进产物）⇒ 改注释也会换 digest，须一并重装。
- **构建 tag 记录（★2026-09-29 更正：实际有**两个** tag）**：tag 由**两处头文件各定义一处**（两个构建脚本都不写 tag）—— ① `deltas/glcore/src/gl/meowcore/meowcore.h` 的 **`MC_BUILD_TAG`**（gl4es init 日志打印）= `2026-09-27-r16 (multidraw: core base-vertex loop; ext diag)`（**雾改动前基准**）；② `deltas/glcore/src/gl/fog.c` 的 **`MEOW_GL4ES_BUILD_TAG`**（首次 `glFogfv` 的 `[meow-gl4es] build=…` **自证行用的是它**）= **`2026-09-29-fogfix-reentrant`**（**当前装机件自证值**；上一版为 `2026-09-29-cleanup`，被本次"强制距离模式改写缓冲改栈上副本（可重入）"取代）。历史 `MC_BUILD_TAG` 值：r15 = `multidraw: EXT first, probe+loop fallback`、r14 = `multidraw: prefer core base-vertex loop`、r13 = `2026-09-26-r13 (honor glBindFragDataLocation too)`、r11 = `multidraw emulation + noop diag`、r12 = `honor glBindAttribLocation + multidraw`；更早 r6 = `ES-legal tex images`、r7 = `depth32 + core caps`、r8 = `uniform block cross-stage`、r9 = `sampler bindings + shader diag`、r10 = `entry coverage + diag keys`。换 tag 时改对应头文件一处并同步本文。
- 校验方式：同 tag + 同 SDK + 同路径下 **2× 干净重建 + `cmp` 逐字节**（不要只比 sha256）。**2026-09-27 实测 r16：2× 干净重建**（每次先 `rm -rf stuffs/research/gl4es/build-ohos`）**逐字节一致**（digest `f96d54a5…`，1,255,704 B），随包件与 `natives.manifest` 同哈希。（历史：2026-09-26 r13 2×、2026-09-22 r10 3× 干净重建一致。）

## Meowcraft delta：固定管线雾（2026-09-29，**已落地**）

> 背景与全部取证：[`notes/20-design/render/gl4es固定管线雾-取证与修复.md`](../../../notes/20-design/render/gl4es固定管线雾-取证与修复.md)。
> 触发场景：**MC 1.7.10 + OptiFine「Fog: Fast」**（显示列表画区块 + 逐区块改雾）⇒ 世界全透明/零碎面片。
> 状态口径（与 `notes/00-current/已知限制与待解.md` **C12** 一致）：**根因定案 + 已收敛为默认兜底**（装机件 `5c01567d…`，tag `2026-09-29-fogfix-reentrant`）＝**已落地**；**定稿件**已做同 SDK + 同构建路径 **2× 干净重建 + `cmp` 逐字节一致**（2026-09-29 实测），本轮各**中间变体**只构建过一次。

**新增被 delta 覆盖的文件**（覆盖式，非打补丁 ⇒ 上游改动需手工合并）：

| 文件 | 内容 |
|---|---|
| `deltas/glcore/src/gl/fog.c` | ① 雾追踪（env `MEOW_FOG_TRACE=1`，打印每次雾状态变化，上限 4000）；② 平面雾兜底 `MEOW_FOG_FORCE_RADIAL`（默认开，见下「运行期开关」）。~~每次雾状态变化后调用 `fpe_UploadFogUniforms()`~~ **该推送机制已删除（2026-09-29）**，见下「已删除的机制」 |
| `deltas/glcore/src/gl/fpe.c` | ① FPE 逐绘制诊断（env `MEOW_FPE_TRACE=1` → `[fpetrace]`/`[fogshader]`/`[fogreadback]`/`[fpeattr]`，见下「运行期开关」）。~~`meow_fpe_fog_push()` + `fpe_UploadFogUniforms()`~~ **该推送机制已删除（2026-09-29）**，见下「已删除的机制」 |
| `deltas/glcore/src/gl/fpe.h` | 随上游整份覆盖（内容未改） |

**运行期开关**（不设 = 默认行为；均可用于实机 A/B）：

| env | 作用 |
|---|---|
| **`MEOW_FOG_FORCE_RADIAL`** | **默认开**（显式 `=0` 关）：把 `GL_FOG_DISTANCE_MODE_NV` 一律按 `GL_EYE_RADIAL_NV` 处理。**依据**：本栈"平面雾变体"渲染坏（几何撕裂）、径向变体正常，而两者只差这个距离模式；实机开启后 OptiFine `Fog: Fast` 画面正常。**E1 判别实验**（曾有的 `MEOW_FOG_FORCE_PLANE=1`：全场景只用平面单变体）实机**仍坏且更稀疏** ⇒ 坏的是**平面变体自身**，不是两变体共存；该开关**已移除**。详见笔记 §"判别实验的结果"。**覆盖范围（2026-09-29 补，已读代码核实）**：该改写只作用于能到达 delta `gl4es_glFogfv()` 钩子的三条路径 —— `glFogfv` / `glFogf` / `glFogi`（`glFogi` 经 `gl4es_glFogi`→`gl4es_glFogf`→`gl4es_glFogfv`，见 `ref/gl4es/src/gl/wrap/gl4eswraps.c:26-28`）。**`glFogiv` 不在覆盖内，且这属文档遗漏而非缺陷**：上游 `gl4es_glFogiv()` 的 `switch(pname)`（同文件 `:29-49`）根本没有 `GL_FOG_DISTANCE_MODE_NV` 分支（只转发 `DENSITY/START/END/MODE/INDEX/COORD_SRC`→`glFogf`、`COLOR`→`glFogfv`）⇒ 距离模式经 `glFogiv` 传入时**早在上游就被丢弃**；FPE 侧 `fpe_glFogfv()`（`deltas/glcore/src/gl/fpe.c:977-1003`）同样只处理 `GL_FOG_MODE` / `GL_FOG_COORDINATE_SOURCE` / `GL_FOG_DISTANCE_MODE_NV` 三个 pname |
| `MEOW_FOG_TRACE=1` | 打印每次雾**状态变化**的实际值（`MODE/START/END/DENSITY/COLOR/COORD_SRC/DISTANCE_MODE_NV`），上限 4000 条；`[fogtrace-list]` 另记**显示列表编译期**的雾调用 |
| `MEOW_FPE_TRACE=1` | 每次 FPE 绘制打 `[fpetrace]`（含变体位与雾值；**只记开了雾的绘制**）+ `[fogshader]`（每个变体一次：真正编译进 GPU 的雾相关 shader 行）+ `[fogreadback]`（把雾 uniform 从 GL **回读**与 `glstate` 比对，上限 600）+ `[fpeattr]`（程序属性 location 与 VAO 顶点指针/步长；属性名按 gl4es 自己的 `builtin_attrib[]` 反查，见下） |
| `MEOW_FOG_NO_NV_DISTANCE=1` | 反向开关：忽略距离模式设置、保持默认平面 ⇒ **可用来复现原 bug**（不是"有效二分"，见笔记 §1②） |

**日志标记**（**每次运行都会打**，用来证明"设备上跑的到底是哪一版 gl4es"）：
- **`[meow-gl4es] build=<tag> force_radial=<0|1>`** —— 首次 `glFogfv` 时**无条件**打一行（当前 tag = **`2026-09-29-fogfix-reentrant`**）。踩过三次"换了件但跑的还是旧件"的坑（判据只看 `strings` 里的标记是**不够**的，必须看这一行）。
- ~~`[fogfix] active: …`~~ —— 该标记随"雾 uniform 推送"整段删除而消失（见下）。
- `[fpeattr]` 的属性名**必须**用 gl4es 自己钉的那套（`_gl4es_Vertex`/`_gl4es_Color`/`_gl4es_MultiTexCoordN`/`_gl4es_FogCoord`…，来自 `shaderconv.c` 的 `builtin_attrib[]`）；手写 `"vertex"`/`"texcoord0"` 之类在生成的 shader 里根本不存在 ⇒ `glGetAttribLocation` 恒 −1 ⇒ 该栏等于没测（已修：改为 `hasBuiltinAttrib()` 反查）。

**已删除的机制（2026-09-29）**："雾变化 / 列表回放时推送 FPE 雾 uniform"（`fpe_UploadFogUniforms()` + `meow_fpe_fog_push()` + `MEOW_FOG_FIX` 开关）。**当初为何存在 / 为何丢弃**：见 `deltas/glcore/src/gl/fog.c` 顶部与该文件同段的完整留档（① 前提错：列表回放本就走 `realize_glenv()`；② 本身有害：`GoUniformfv` 不绑定程序、会把值写进别的程序；③ 判别实验 E2 判定它既非真凶也无疗效）。

**产物（当前装机件）**：`stuffs/research/gl4es/out-fogfix-reentrant/libgl4es.so`，sha256 `5c01567dd9f0155ef2dbd8de3c9867ed63c92c7aa4617dbf543c5b5af1c80e61`，**1,259,800 B**（tag `2026-09-29-fogfix-reentrant`；`FORCE_RADIAL` 默认开、`FORCE_PLANE` 已除、推送已整段删除；本轮把强制距离模式用的改写缓冲由 `static GLfloat s_forceMode[4]` 改为**每次调用的栈上副本** ⇒ 该函数恢复可重入）⇒ 已装到 `libs/meowlwjgls/libs/arm64-v8a/libgl4es.so` + `natives.manifest`（哈希同上，已核）。**上一版随包件** `87fc358b…`（1,260,408 B，tag `2026-09-29-cleanup`，产物 `stuffs/research/gl4es/out-fogfallback/libgl4es.so`）被本次取代。
（本轮迭代过的中间件原样保留在工作区 `stuffs/research/gl4es/` 下：`fogtrace`/`fogfix`(v1 有绑定 bug)/`fogfix2`/`fogfix3`/`fogfix4`/`fpetrace`/`fpetrace2`/`fogreadback`/`fogshader`/`fogshader2`/`fpeattr`/`fogradial`；各自的 sha256 见笔记。重建：`sh tools/gl4es/rebuild_for_meowcraft.sh --delta tools/gl4es/deltas/glcore`。）

> ⚠️ **与上文 r16 基准的关系**：上文 `f96d54a5…`（1,255,704 B）是**加雾改动之前**的基准；**当前随包件已换成上面的 `5c01567d…`**（1,259,800 B，与 §产物 一致）。
> ✅ **复现校验（2026-09-29 实测）**：**定稿件**在同 SDK + 同构建路径下 **2× 干净重建 + `cmp` 逐字节一致**（脚本每次自 `rm -rf <build>` 并重拷源码副本）⇒ **同路径可复现**成立；**跨路径不可**（RelWithDebInfo 把源路径编进 debug/`.comment` 面）。本轮各**中间**变体只构建过一次。
> **已知未决**：**平面变体自身为何坏**（shader/驱动层）**仍未查** ⇒ 现以 `MEOW_FOG_FORCE_RADIAL`（默认开）作**可逆兜底**；深挖候选手段见笔记 §"判别实验的结果"。

