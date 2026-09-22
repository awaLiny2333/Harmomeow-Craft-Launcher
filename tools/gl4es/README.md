# tools/gl4es/ — 自编 OHOS gl4es（≤1.16/legacy FPE + 1.17–1.21.x GL3 core）

上游：**ptitSeb/gl4es**（MIT）。用途：给 **MC ≤1.16**（用固定管线 GL；`RendererPolicy` 对所有 `<1.17` 生效）提供
"桌面 GL 1.x/2.x → 原生 OpenGL ES" 的固定管线翻译层，绕开系统 `libGLv4.so`（Mesa Zink）
compat 路径的渲染错乱。详见 `notes/20-design/render/legacy渲染-gl4es-落地方案.md`。

> 同一 `libgl4es.so` 也是 **MC 1.6.x–1.12.2**（`tools/lwjgl2/` 的 LWJGL2 legacy 路径）的 GL 提供者：
> LWJGL2 native 的 `extgl` 经 `MEOW_LWJGL2_GL`（默认 `libgl4es.so`）取址，见 `tools/lwjgl2/README.md` §3。

> 版本：`ref/gl4es` = v1.1.7（`v1.1.6-91-g81547d98`）。**不带 `--delta` 的上游配方**只走 FPE、shader 转换内建
> （不依赖 glslang/SPIRV-Cross）；**当前随包产物 = 带 `--delta deltas/glcore` 的构建**，它另含 **GL3 core 后端**
> （GL 3.2/3.3 → 原生 GLES 3.2），该路径**静态并入 glslang(shaderc) + SPIRV-Cross**（库内含 `spvc_*` / shaderc 符号；
> `DT_NEEDED` 仍仅 `libc.so`）。
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
- **带 `--delta` 的配方逐字节可复现**：`deltas/glcore` 覆盖 `build_info.c`（去掉时间戳）并加入 **GL3 核心后端**；另加 `-DCMAKE_SKIP_RPATH=ON`（否则产物会带一条指向**临时副本目录**的 `RUNPATH` —— 开发路径泄漏）。**当前基准 = r9**：digest `2fbf08bce987bb4a75155b27ab23bde14c4d4feddd80627178c67a401a0a8fac`，**1,251,608 B**（上一基准 r6/r7/r8 = `6c9065bb…`/`7f0fa55a…`/`637c033d…`，均 1,247,512 B，逐轮更替）——**digest 随 delta 增长而变，换装时同步更新**（随包件 `libs/meowlwjgls/libs/natives.manifest` 同步）。
- **构建 tag 闭环**：tag 由 `deltas/glcore/src/gl/meowcore/meowcore.h` 的 `MC_BUILD_TAG` 定义；构建脚本与本文记录**当前值** = `2026-09-22-r9 (sampler bindings + shader diag)`（r6 = `2026-09-22-r6 (ES-legal tex images)`、r7 = `depth32 + core caps`、r8 = `uniform block cross-stage`）。换 tag 时三处（头文件 / 构建脚本 / 本文）同改。
- 校验方式：同 tag + 同 SDK + 同路径下 **2× 干净重建 + `cmp` 逐字节**（不要只比 sha256）。
