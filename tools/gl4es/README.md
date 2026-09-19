# tools/gl4es/ — 自编 OHOS gl4es（≤1.16 legacy 渲染）

上游：**ptitSeb/gl4es**（MIT）。用途：给 **MC ≤1.16**（用固定管线 GL；`RendererPolicy` 对所有 `<1.17` 生效）提供
"桌面 GL 1.x/2.x → 原生 OpenGL ES" 的固定管线翻译层，绕开系统 `libGLv4.so`（Mesa Zink）
compat 路径的渲染错乱。详见 `notes/20-design/render/legacy渲染-gl4es-落地方案.md`。

> 同一 `libgl4es.so` 也是 **MC 1.6.x–1.12.2**（`tools/lwjgl2/` 的 LWJGL2 legacy 路径）的 GL 提供者：
> LWJGL2 native 的 `extgl` 经 `MEOW_LWJGL2_GL`（默认 `libgl4es.so`）取址，见 `tools/lwjgl2/README.md` §3。

> 版本：`ref/gl4es` = v1.1.7（`v1.1.6-91-g81547d98`）。**不依赖 glslang/SPIRV-Cross**（shader 转换内建）。
> 不使用已归档的 `ref/NG-GL4ES` fork（它是黑盒 `libng_gl4es.so` 的出处）。

## 产物

`libgl4es.so`（由 gl4es 的 `libGL.so.1` 改名而来，因 **hvigor 只打包顶层 `*.so`**）：
- ELF arm64，`DT_NEEDED` 仅 `libc.so`，`SONAME=libGL.so.1`，`.note.ohos.ident`，stripped。
- 导出桌面裸名 `gl*`（含固定管线真实现：`glMatrixMode`/`glEnableClientState`/`glFogfv`/`glBegin`…）。
- `glGetString(GL_VERSION)` 默认报 `2.1 gl4es wrapper 1.1.7`。

## 构建（从零复现）

```sh
sh tools/gl4es/rebuild_for_meowcraft.sh        # 用 ref/gl4es，产物落 stuffs/research/gl4es/out/
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
- 同 tag + 同 SDK + 同 `--src`/`--build` 路径下预期可复现（gl4es 无内嵌时间戳；如需严格逐字节复现按 2× 干净重建 + `cmp` 验证）。
- 已核验 digest（本项目构建）：`sha256 90c6ff6bc1521b3da04dc787d6581575fb4800c1399b3c01ab828ec14ebe0e54`（stripped，1231128 B）。
