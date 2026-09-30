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
- **构建 tag 记录（★2026-09-29 更正：实际有**三个** tag）**：tag 由**三处头文件各定义一处**（构建脚本都不写 tag）—— ① `deltas/glcore/src/gl/meowcore/meowcore.h` 的 **`MC_BUILD_TAG`**（gl4es init 日志打印）= `2026-09-27-r16 (multidraw: core base-vertex loop; ext diag)`（**雾改动前基准**）；② `deltas/glcore/src/gl/fog.c` 的 **`MEOW_GL4ES_BUILD_TAG`**（首次 `glFogfv` 的 `[meow-gl4es] build=…` **自证行用的是它**）= **`2026-09-29-fogfix-reentrant`**（**当前装机件自证值**；上一版为 `2026-09-29-cleanup`，被本次"强制距离模式改写缓冲改栈上副本（可重入）"取代）；③ `deltas/glcore/src/gl/meowctx.c` 的 **`MEOW_CTX_BUILD_TAG`**（首次 `meow_gl4es_bind` 的 `[meow-ctx] build=… tls=1 registry=on` **自证行用的是它**）= **`2026-09-30-ctxiso-tls3`**（**当前装机件自证值**；上一版为 `2026-09-29-ctxiso-tls2`，被本次"M-2 可观测化 warn（共享语义不变）"改动取代，见下节「每 EGL 上下文隔离 glstate」）。历史 `MC_BUILD_TAG` 值：r15 = `multidraw: EXT first, probe+loop fallback`、r14 = `multidraw: prefer core base-vertex loop`、r13 = `2026-09-26-r13 (honor glBindFragDataLocation too)`、r11 = `multidraw emulation + noop diag`、r12 = `honor glBindAttribLocation + multidraw`；更早 r6 = `ES-legal tex images`、r7 = `depth32 + core caps`、r8 = `uniform block cross-stage`、r9 = `sampler bindings + shader diag`、r10 = `entry coverage + diag keys`。换 tag 时改对应头文件一处并同步本文。
- 校验方式：同 tag + 同 SDK + 同路径下 **2× 干净重建 + `cmp` 逐字节**（不要只比 sha256）。**2026-09-27 实测 r16：2× 干净重建**（每次先 `rm -rf stuffs/research/gl4es/build-ohos`）**逐字节一致**（digest `f96d54a5…`，1,255,704 B），随包件与 `natives.manifest` 同哈希。**2026-09-29/30 实测 ctxtiso 三版均 2×/3× 干净重建 `cmp` 逐字节一致**（tls `f5c2d61f…`；tls2 `ea15f779…`；tls3 `35a81e4c…`，均 1,292,568 B）。（历史：2026-09-26 r13 2×、2026-09-22 r10 3× 干净重建一致。）

## Meowcraft delta：固定管线雾（2026-09-29，**已落地**）

> 背景与全部取证：[`notes/20-design/render/gl4es固定管线雾-取证与修复.md`](../../../notes/20-design/render/gl4es固定管线雾-取证与修复.md)。
> 触发场景：**MC 1.7.10 + OptiFine「Fog: Fast」**（显示列表画区块 + 逐区块改雾）⇒ 世界全透明/零碎面片。
> 状态口径（与 `notes/00-current/已知限制与待解.md` **C12** 一致）：**根因定案 + 已收敛为默认兜底**（该定稿产物 `5c01567d…`，tag `2026-09-29-fogfix-reentrant`；**其后随包件已换成上下文隔离版 `ea15f779…`**，见下节）＝**已落地**；**定稿件**已做同 SDK + 同构建路径 **2× 干净重建 + `cmp` 逐字节一致**（2026-09-29 实测），本轮各**中间变体**只构建过一次。

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

**产物（固定管线雾定稿件；现已被下节「每 EGL 上下文隔离」版取代）**：`stuffs/research/gl4es/out-fogfix-reentrant/libgl4es.so`，sha256 `5c01567dd9f0155ef2dbd8de3c9867ed63c92c7aa4617dbf543c5b5af1c80e61`，**1,259,800 B**（tag `2026-09-29-fogfix-reentrant`；`FORCE_RADIAL` 默认开、`FORCE_PLANE` 已除、推送已整段删除；本轮把强制距离模式用的改写缓冲由 `static GLfloat s_forceMode[4]` 改为**每次调用的栈上副本** ⇒ 该函数恢复可重入）⇒ 曾装到 `libs/meowlwjgls/libs/arm64-v8a/libgl4es.so` + `natives.manifest`（哈希同上，已核）。**上一版随包件** `87fc358b…`（1,260,408 B，tag `2026-09-29-cleanup`，产物 `stuffs/research/gl4es/out-fogfallback/libgl4es.so`）被本次取代。**当前随包件 = 上下文隔离版 tls3 `35a81e4c…`（1,292,568 B，tag `2026-09-30-ctxiso-tls3`，+ M-2 可观测化 warn），见下节。**
（本轮迭代过的中间件原样保留在工作区 `stuffs/research/gl4es/` 下：`fogtrace`/`fogfix`(v1 有绑定 bug)/`fogfix2`/`fogfix3`/`fogfix4`/`fpetrace`/`fpetrace2`/`fogreadback`/`fogshader`/`fogshader2`/`fpeattr`/`fogradial`；各自的 sha256 见笔记。重建：`sh tools/gl4es/rebuild_for_meowcraft.sh --delta tools/gl4es/deltas/glcore`。）

> ⚠️ **与上文 r16 基准的关系**：上文 `f96d54a5…`（1,255,704 B）是**加雾改动之前**的基准；其后随包件换成雾兜底版 `5c01567d…`（1,259,800 B，§产物），再换成**上下文隔离版**（tls `f5c2d61f…` → tls2 `ea15f779…` → tls3 `35a81e4c…`，均 1,292,568 B，下节）⇒ **当前随包件 = `35a81e4c…`**。
> ✅ **复现校验（2026-09-29 实测）**：**定稿件**在同 SDK + 同构建路径下 **2× 干净重建 + `cmp` 逐字节一致**（脚本每次自 `rm -rf <build>` 并重拷源码副本）⇒ **同路径可复现**成立；**跨路径不可**（RelWithDebInfo 把源路径编进 debug/`.comment` 面）。本轮各**中间**变体只构建过一次。
> **已知未决**：**平面变体自身为何坏**（shader/驱动层）**仍未查** ⇒ 现以 `MEOW_FOG_FORCE_RADIAL`（默认开）作**可逆兜底**；深挖候选手段见笔记 §"判别实验的结果"。

## Meowcraft delta：每 EGL 上下文隔离 glstate（2026-09-29；状态见 `notes/00-current/现状基线.md` §5 第 26 条）

> 背景/取证：[`notes/20-design/launch/Forge-splash-崩溃根因与共享上下文修复.md`](../../../notes/20-design/launch/Forge-splash-崩溃根因与共享上下文修复.md) §5.3 与 [`notes/00-current/已知限制与待解.md`](../../../notes/00-current/已知限制与待解.md) **C11**。
> 目的：FML 1.7.10 控制台 splash 在**两个线程上各跑一个 EGL 上下文**（splash 线程 = 主上下文；主线程 = 共享上下文，整个加载期重叠）而 gl4es 只有一个进程级 `glstate` ⇒ 数据竞争 ⇒ 原生崩溃。修法是**把 glstate 变成线程局部 + 按 EGL 上下文绑定**（上游 `glx.c` 的 per-context 机制在我们 NOX11+NOEGL 的构建里根本不会被调用）。
> **2026-09-29 23:26 实机（FML splash 打开）**：跑至干净退出，日志见 `[meow-ctx] … (root)` + `… (shared child of root)`、桥 `gl4es: per-context state hook active`、零 `rethrow signo(11)`/厂商 trap/EGL 错误。**逐版本/逐设备口径以 `现状基线.md` §5 第 26 条为准**（本页不复述）。

**新增/覆盖的文件**（覆盖式，非打补丁 ⇒ 上游改动需手工合并）：

| 文件 | 内容 |
|---|---|
| `deltas/glcore/src/gl/gl4es.h` | **整份覆盖**，只改一处：`extern glstate_t *glstate;` → `extern __thread glstate_t *glstate;`（所有 TU 都必须看到 TLS 声明） |
| `deltas/glcore/src/gl/glstate.c` | **整份覆盖**，只改一处：定义改 `__thread`，并把 `default_glstate` 提到 `glstate` 之前（TLS 初始化式用 `&default_glstate`，保证任何线程都不会拿到 NULL） |
| `deltas/glcore/src/gl/meowctx.c`（**新文件**） | 上下文注册表 + `meow_gl4es_bind/unbind/forget`：首绑上下文 = 共享组根（拥有共享对象表），其后每个上下文 `NewGLState(根, 0)`（共享表、独立事务状态）——即 EGL 共享上下文语义 |
| `deltas/glcore/src/gl/meowctx.h`（**新文件**） | 上述三个导出（`-fvisibility=hidden` ⇒ 必须 `EXPORT`，桥用 dlsym 取） |
| `deltas/glcore/src/CMakeLists.txt` | 把 `gl/meowctx.c` / `gl/meowctx.h` 加进 `GL_SRC`/`GL_H` |

**桥侧调用点**（`libs/meowcraftlib/.../meowcraftbridge/egl_gl.c`）：每次成功的 `eglMakeCurrent` 之后通知 gl4es —— 主上下文（`egl_bind`）、共享上下文（`meowMakeCurrentFor` 次级分支）、以及 release/销毁（`EGL_NO_CONTEXT`；销毁时另调 `meow_gl4es_forget`，**进程退出时 `meowTerminate` 对 primary 也调 `meow_gl4es_forget`**）。符号用 `dlsym` 解析（**不加链接期依赖**）；旧 `libgl4es.so` 缺符号时打**一条**英文日志并永久降级（不崩）。**新硬门（2026-09-30 改三态，M-1）**：hook 可用性判定为 `UNKNOWN`/`ABSENT`/`PRESENT`，解析**不再依赖**"已发生过一次成功 `eglMakeCurrent`"——`egl_ensure_context()` 的 gl4es(FPE) 分支在**建上下文时**即 `gl4es_ctx_hook_state()`（dlopen + dlsym，安全于 `initialize_gl4es()` 之前），且 `meowCreateSharedContext` 在判定前先强制解析（`UNKNOWN` 也先尝试），只有 `PRESENT` 才放行共享上下文：`ABSENT`（旧件）打 `shared ctx refused: per-context gl4es state hook ABSENT from the loaded libgl4es.so (hook-less/foreign build) - FML 1.7.10 will fail at SplashProgress.java:199`，`UNKNOWN`（库都加载不出）打 `shared ctx refused: per-context gl4es state hook UNRESOLVED (libgl4es.so could not be loaded to resolve it) - …`，二者都**无条件拒绝** —— 与 `MEOW_ALLOW_SHARED_CTX` 策略正交（见 `运行时环境变量.md` §1）。

**运行期自证日志**（用来证明设备上跑的是这一版、隔离已生效）：
- `[meow-ctx] build=2026-09-30-ctxiso-tls3 tls=1 registry=on`（首次绑定）
- `[meow-ctx] ctx=0x… -> state=0x… (root: owns shared tables)` / `(shared child of root)`
- 桥侧：`gl4es: per-context state hook active (meow_gl4es_bind)`；**确无符号**时 `gl4es: meow_gl4es_bind ABSENT in the loaded libgl4es.so (hook-less build) …`（与"尚未解析/加载不出"的 `UNRESOLVED` 相区分）
- 桥侧硬门（hook 非 `PRESENT` + 有人要共享上下文）：`shared ctx refused: per-context gl4es state hook ABSENT from the loaded libgl4es.so (hook-less/foreign build) - FML 1.7.10 will fail at SplashProgress.java:199`（旧件）或 `… hook UNRESOLVED (libgl4es.so could not be loaded to resolve it) …`（加载不出；见上「桥侧调用点」）
- M-2 已知限制（**仅日志，不改共享语义**）：share-group root 被 `meow_gl4es_forget` 遗忘而注册表仍有活跃子状态时，打 `[meow-ctx] WARN: share-group root forgotten while N child state(s) still alive; the next NewGLState(NULL) starts a NEW object-table group (EGL share group split) - known limitation, see meowctx.c M-2 note`（触发 = **首个被绑定的上下文（root）先于其子被销毁**；进程正常退出不触发）

**TLS 说明**：OHOS 的 clang 默认走**模拟 TLS**（`__emutls_*`，运行时自带、**不新增 DT_NEEDED**；已用 SDK clang 静态核过 `__emutls_get_address` 会被链进 .so）。`__thread` 每次访问是一次 `__emutls_get_address` 调用 ⇒ 若实机看到明显掉帧，需评估 TLS 模型或每线程缓存。

> ✅ **digest 已定**：**当前产物 = `stuffs/research/gl4es/out/libgl4es.so`，sha256 `35a81e4c67c29dfe515eb56ac77a2280108876fd3274e23140b9202ad4a44ad2`，1,292,568 B（tag `2026-09-30-ctxiso-tls3`）**；已装到 `libs/meowlwjgls/libs/arm64-v8a/libgl4es.so` + `natives.manifest`（tag `common`），并同步 `notes/30-supply-chain/{assets-digests.txt,per-so-catalog.md}`（v44）。本件相对上一随包件（tls2 `ea15f779…`）只加了一条 **M-2 观测 warn**（root 被遗忘而仍有子存活；纯日志 + 注释，**共享语义不变**、不做引用计数），**无新开关**；同 SDK + 同构建路径 **2× 干净重建 + `cmp` 逐字节一致**（本次会话实测）。
> 🧪 **构建脚本自检（2026-09-30）**：`build_gl4es_meow.sh` 现打印 `delta-content-sha256`（delta 树内容摘要 = 排序后的 路径+字节 摘要），并在末尾与 `artifact-sha256` **并列**输出，另支持 `--expect-digest H`（或 `$MEOW_GL4ES_EXPECT_DIGEST`）断言产物哈希 ⇒ 防"改了 delta 忘重打/重装 .so"。本次 `delta-content-sha256` = `f449b7791cea1407f2bd76de9d63d39f99bcad04db54149080a725c62acc4f58`。
> ⚠️ **本轮未做（后续项）**：**共享对象表**（`texture.list`/`buffers`/`glsl`/`headlists`/`fpe_cache`/fbo/sampler/query 表）的并发加固。两个上下文按 EGL 语义**共享**这些 khash 表（`NewGLState(根)` 拷指针），而两个线程会并发改它们 ⇒ 仍有**概率性**风险。**不是"加个叶锁"就能了事**：显示列表的 `glEndList` 会 `free_renderlist(kh_value(...))`、`glCallList` 又会遍历它（释放/遍历交叉 ⇒ 需要**引用计数**），而纹理/程序表的 get-create-delete 也不是单次原子操作；且这些改动散落在 `gl4es.c`/`texture.c`/`texture_params.c`/`program.c`/`shader.c`/`fpe_cache.c`/`framebuffers.c`… 十余个大文件里 —— 覆盖式 delta 的维护代价很大。**本隔离已实机验证消掉该崩溃（2026-09-29 23:26）**；若后续仍出现概率性崩溃，再取 `faultlog` 原生栈决定要不要做引用计数。


