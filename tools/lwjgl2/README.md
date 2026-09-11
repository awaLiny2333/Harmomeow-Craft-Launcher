# tools/lwjgl2/ — 自编 OHOS LWJGL2 native（MC 1.6.x–1.12.2 legacy）

产出 **`liblwjgl.so`**（aarch64 只找此名，不带 64），顶替 MC 1.6.x–1.12.2 缺失的 LWJGL2 native。
**只编 native**，不重编 MC 的 `lwjgl-2.9.x.jar`。

- **完整设计**：[`../../notes/20-design/lwjgl2-ohos自编方案.md`](../../notes/20-design/lwjgl2-ohos自编方案.md)
- **完整战役记录（来源/编译/魔改/逐条根因与证据）**：[`../../notes/20-design/LWJGL2-legacy适配复盘.md`](../../notes/20-design/LWJGL2-legacy适配复盘.md)
- 本地补丁说明：[`patches/README.md`](patches/README.md)

> **JNI_VERSION=19** 跨 2.9.0/2.9.1/2.9.3/2.9.4 一致、JNI 符号稳定 → 一份 native 服务 **1.6.x–1.12.2**（用户实机：**1.6.1 / 1.6.4** / 1.7.10 / 1.8.9 / 1.12.2 可玩）。
> 依据（2026-09-11 实测版本 json）：MC 1.6.1/1.6.4 声明 `org.lwjgl.lwjgl:lwjgl:2.9.0`（另有 `2.9.1-nightly-20130708-debug3`），
> 1.7.10 声明 `2.9.1`，1.12.2 声明 `2.9.4-nightly-20150209`（另有 `2.9.2-nightly-20140822`），且 1.6.x–1.12.2 均用 `minecraftArguments` 表达启动参数；
> 这些版本的 JNI 符号集在 2.9.x 内不变，故同一 `liblwjgl.so` 覆盖 **1.6.x–1.12.2**。

## 0. 前置：取得上游源码

`ref/lwjgl` 是**独立 clone**（在 app 仓库之外），必须钉在确切提交：

```sh
git clone https://github.com/LWJGL/lwjgl.git <ws>/ref/lwjgl
git -C <ws>/ref/lwjgl checkout 2df01dd7        # git describe: lwjgl2.9.3-19-g2df01dd7
```

## 1. 干净复现走查（四步，命令均已验证）

```sh
WS=<ws>/Meowcraft                      # app 工程（含 tools/）

# ① 打本地补丁（一次性）
cd "$WS/../ref/lwjgl" && git apply "$WS/tools/lwjgl2/patches/0001-generator-filer-bypass.patch"

# ② 生成源码（人跑，只需 JDK；不需要 ant/JDK8）。cwd 无关。
cd "$WS" && sh tools/lwjgl2/generate_sources.sh
#   产出：generated/{opengl:157,openal:3,opengles:47,opencl:15}/*.c、（重编）472 Java、25 JNI 头（src/hdrs-meow/）

# ③ 编 native（agent 可跑）。--with-display 是"可用的 native"的必要条件（Stage 1 只有 GL/AL，无窗口/输入）
sh tools/lwjgl2/build_lwjgl2_meow.sh \
  --src ../ref/lwjgl \
  --sdk-native /data/service/hnp/ohos-sdk.org/ohos-sdk_26.0.0.18/ohos/native \
  --out ../stuffs/lwjgl2 --with-display

# ④ 随包（manifest tag common）+ 清模块 build + 构建 + 部署
sh tools/lwjgl/install_natives.sh --native liblwjgl.so=../stuffs/lwjgl2/liblwjgl.so
rm -rf "$WS/entry/build" "$WS/libs/meowjre25/build"
devecocli build --modules entry meowjre25
devecocli run --skip-build --module entry meowjre25 --device 127.0.0.1:40229
```

**易错点**：②③ 依赖 `$WS/ref/lwjgl` 里由 ② 生成的 `src/hdrs-meow/`（③ 会明确报错提示先跑 ②）；脚本**拒绝**含空格的路径；
`--build` 指向 `$SRC` 或其子目录/`/` 时会被拒绝（保护 `rm -rf`）。`ref/lwjgl` 的生成物由补丁加入 `.gitignore`
（`/bin-meow`、`/src/hdrs-meow`；`/src/generated`、`/src/native/generated` 是上游本来就忽略的）。

## 2. 脚本与文件

| 文件 | 作用 |
|---|---|
| `generate_sources.sh` | 纯 `javac` 驱动注解处理器生成 Java/C + `javac -h` 出头（**绕过 Ant/JDK8/javah**）；完整复刻 `platform_build/build-generator.xml` 的 `generate-all`（8 处理器）与 `build.xml <target name="headers">` 的固定类清单 |
| `build_lwjgl2_meow.sh` | 直驱 OHOS clang 编 `liblwjgl.so`（**不用**官方 `linux_ant`/CMake）；带导出面/`DT_NEEDED`/`.note.ohos` 断言 |
| `src-ohos/meow_port.h` | 共享私有头：状态块采用（`MEOWCRAFT_ENVIRON`）、bridge thunk（`dlsym(RTLD_DEFAULT)`）、`MeowPortEvent`、GLFW→X11 KeySym 表 |
| `src-ohos/meow_{extgl,sys,display,context,input,cursor}.c` | 平台移植层（GL 取址→gl4es；Sys；窗口/上下文；输入；光标） |
| `patches/0001-*.patch` | 对 `ref/lwjgl` 的唯一必要源码补丁（JDK9+ `JavacFiler` 绕行） |

**Stage 1（默认）**：174 TU，导出 2166（GL 2141 / OpenAL 20 / Sys 3 / BufferUtils 2）。**⚠️ 不可出货**（无窗口/输入）。
**Stage 2（`--with-display`）**：178 TU，导出 2287（GL 2262 / OpenAL 20；`Linux*` = 9 个生成头声明的**全部** 121 个，`missing=NONE`），
`DT_NEEDED=libc.so`，`.note.ohos.ident` 在，strip 后 ~320 KB。

**链接**：`-lm -lpthread`（**不含** `-lEGL -lGLESv3 -lnative_window`——EGL/GLES/窗口全在 `libmeowcraftbridge.so`，
经 `dlsym(RTLD_DEFAULT)` 调用，故本 .so 零 GL 依赖、`DT_NEEDED=libc.so`）；**去掉**上游 GLX 形状的 `lwjgl.map`。
**SDK 工具坑**：本机 SDK `llvm/bin` 只有 `llvm-{nm,objcopy,readobj,objdump,ar,size,strings}`，**没有**
`llvm-strip`/`llvm-readelf` → 脚本用 `llvm-objcopy --strip-unneeded` 与 `llvm-readobj` 做断言。

## 3. 环境开关（运行时）

| 变量 | 作用 |
|---|---|
| `MEOW_LWJGL2_GL` | 覆盖 GL provider（默认 `libgl4es.so`） |
| `MEOW_LWJGL2_GLERRORS` | 设 1 = **恢复** gl4es 的 GL 错误上报（默认静默，见踩坑 11） |
| `MEOW_LWJGL2_VERBOSE` | 设 1 = 打开 native 的 `fullscreen -> N` / `pointer lock -> N` 状态翻转日志 |

## 4. 生成期事实（`generate_sources.sh`）

**为什么必须跑 `generate-all` 全 8 步**（即使只编 GL/AL 两份 native）：Java 侧互引闭包——
`org.lwjgl.opengl.ContextGL` `import org.lwjgl.opencl.APPLEGLSharing/KHRGLSharing`；`LinuxDisplay`/`LinuxDisplayPeerInfo`
引用 `org.lwjgl.opengles.{EGL,GLContext,PixelFormat,DrawableGLES}`；`GLContext/GLChecks/CallbackUtil/Pbuffer` 需要
`ContextCapabilities`（= `opengl-capabilities` 步产出）。少任一步，后续编译即缺符号。

| 步 | 处理器 | 产出 |
|---|---|---|
| openal | `GeneratorProcessor` + `ALTypeMap` | `org.lwjgl.openal.**` + `generated/openal/*.c` |
| opengl | `GeneratorProcessor` + `GLTypeMap` +`-Acontextspecific` | `org.lwjgl.opengl.GL1x..GL4x` 等 + `generated/opengl/*.c` |
| opengl-capabilities | `opengl.GLGeneratorProcessor` +`-Acontextspecific` | `org.lwjgl.opengl.ContextCapabilities` |
| opengl-references | `opengl.GLReferencesGeneratorProcessor` | `org.lwjgl.opengl.References` |
| opengles / opengles-capabilities | `GeneratorProcessor`+`GLESTypeMap` / `GLESGeneratorProcessor` | `org.lwjgl.opengles.**` |
| opencl / opencl-capabilities | `GeneratorProcessor`+`CLTypeMap` / `CLGeneratorProcessor` | `org.lwjgl.opencl.**` |

**头生成（`javac -h`）三点铁律**：
1. `-sourcepath "$JAVA:$GENJ"` 以**我们源码为准**——树内预编译 `eclipse-update/org.lwjgl/lwjgl.jar` 是**旧构建**
   （缺 `DisplayMode.toScreen`/`ContextGL`），当 classpath 基准会报一堆**假**缺符号；
2. `-cp "$BIN:$SRC/libs/jinput.jar"`（`input.Display`→`Controllers` 需要 JInput）；
3. `-XDshould-stop.ifError=GENERATE`：即使被牵连归因的无关源（`MacOSXSysImplementation`→`com.apple.eio`、
   `MemoryUtilSun`→`sun.reflect.FieldAccessor`）报错，也照样走到 generate 阶段、输出清单内类的头。

`input.Keyboard`/`Pbuffer` **无 native** → 不产生头（正常）；键盘/鼠标 native 在 `opengl.Linux{Keyboard,Mouse,Event}`；
Sys native 在 `DefaultSysImplementation`（`LinuxSysImplementation extends J2SESysImplementation`，自身无 native）。

## 5. 复用 vs 重写

- **复用**：`src/native/common/*.c`、`src/native/common/opengl/*`、`src/native/common/org_lwjgl_openal_*`、
  `linux/linux_al.c`（通用 dlopen 加载器）、`generated/{opengl,openal}/*.c`（生成 C 只 `#include "extgl.h"`+`<jni.h>`，
  **不需要** javah 头）。**排除**：OpenCL（`org_lwjgl_opencl_*`、`extcl.c`）、AWT（`org_lwjgl_opengl_AWTSurfaceLock.c`）、
  以及整层 X11/GLX（`linux/`、`linux/opengl/` 的 Display/Event/Keyboard/Mouse/PeerInfo/ContextImplementation/GLX/display/context）。
- **重写（`src-ohos/`）**：`extgl`（→gl4es）、`Display`、`Context`（EGL+OHNativeWindow）、输入（共享块输入环）、`Sys`。

## 6. 实机踩坑（LWJGL2 专有，逐条已定位根因；完整证据见复盘笔记）

1. **`org.lwjgl.util.Debug` 对 legacy 必须 false。** `Display.swapBuffers()`（`Display.java:616`）在**交换前**有
   `if (LWJGLUtil.DEBUG) drawable.checkGLError();` —— MC 自己从不查 GL 错误，而 gl4es 的固定管线模拟会留下**良性**
   GL 错误（`gl4es_glGetError` 转发底层 `gles_glGetError`，`ref/gl4es/src/gl/getter.c`）→ 调试开关把噪声变成致命
   `OpenGLException: Invalid operation (1282)`。**这不是环境绕过**：那是属于 LWJGL3 路径的过宽开关。
   排查要点：栈指向 `Display.swapBuffers(Display.java:617)` = **交换前**那次检查，不是 native。
2. **不要在 native 翻鼠标 Y。** LWJGL2 Java 侧自己翻（`LinuxMouse.transformY = nGetWindowHeight-1-y`，`:195`）；
   native 给**原始左上原点**（同 `XQueryPointer`），再翻会**上下镜像**。
3. **`nReleaseCurrentContext` 必须让 `nIsCurrent` 变 false。** 否则退出时 `ContextGL.destroy()` 的 `glGetError()`
   因 caps 已清而抛 `No OpenGL context found in the current thread`。用 TLS 标志镜像每线程模型。
4. **不要写共享块的 `width`/`height` 镜像**（`nSetWindowSize`/`nReshape`）：桥按它自愈重建 EGL surface，写入 MC 请求的
   尺寸会让两者失步 → **画面闪烁**。窗口尺寸归 ArkTS/XComponent + 桥所有。
5. **JNI `GetDirectBufferCapacity` 返回元素数**（`IntBuffer(4)`→4）→ 别做字节范围检查（上游按元素数检查；我们故意不查）。
6. **JNI 原型必须可见。** 漏 `#include "extgl.h"` → `extgl_GetProcAddress` 被隐式当 `int` → 指针截断即崩（`-Wall` 抓到）。
7. **键盘 native 必须逐条对齐上游参数序。** `utf8LookupString` 是 **`(xic, event_ptr, buffer, pos, size)`**；写成
   `(event_ptr, xic, …)` → 把假 XIC 令牌当事件指针解引用 → **任何按键即崩**（cppcrash `@0x4943004d` =
   `createIC` 令牌 `0x49430001`+0x4c，pc 落在本函数）。修完 `positionBuffer(env, buffer, buffer_position + len)`
   （Java 随后 `flip()`）。
8. **`MEOW_EV_CHAR`/`MEOW_EV_CHAR_MODS` 成对入环，翻译层只能吃一条。** `meowjrebridge` 的 `MeowSendChar` 对**一个**字符
   同时调 `charMods` 与 `ch`（对 GLFW/SDL 的 Java 回调路径是正确的）；走环时两条都进环 → 两种都当字符就**每个字符打两遍**。
   修法：紧邻的"另一种、同码点"一并消费（真重复之间必隔 KEY 按下/释放，不会误吞）。**排查法**：翻译层临时
   `fprintf(stderr,…)` 打产出事件（`printfDebug` 会被 LWJGL2 debug 开关静音），对照桥/jrebridge 生产侧日志。
9. **Esc 必须无条件转发给 MC。** `handleImeKey` 的 Esc 分支原先只调 `cancelImeByEsc()`，而它 `!imeActive` 时早退 →
   "IME 未激活但隐形 TextInput 仍持焦"时 Esc 被吞。修法：Esc 分支**永远** `sendImeKey(GLFW_KEY_ESCAPE)`（
   `cancelImeByEsc` 收敛为只去激活，避免激活时发两次）。
10. **功能键重复 Down 必须丢弃。** 本机物理键盘对 F 行键会**重复投递 Down**；F11 是"开关型"，MC 对任何 Down（含 REPEAT）
    都 toggle 一次 → 一次按下被送两遍 → **全屏刚进就被弹回**。修法：功能键的重复 Down **丢弃**（不转 REPEAT）。
11. **GL ERROR 刷屏：legacy 默认静默，可一键恢复。** MC 1.6.x–1.12.2 **每帧**查 `glGetError()` 并打
    `########## GL ERROR ##########`，而那是 gl4es 内部噪声。故 `nMakeCurrent` 首次调用时设 `LIBGL_NOERROR=1`
    （gl4es 只在其 `initialize_gl4es()` 读一次，而桥正是在 `meowMakeCurrent()` 内调它 → 抢在之前即可；**只影响 legacy**，
    不改共享桥）。**深挖时**设 `MEOW_LWJGL2_GLERRORS=1` 恢复上报。
12. **全屏切换会 destroy+create 重建窗口 → `focused=false`（`LinuxDisplay.java:506`），而 `Display.isActive()` =
    `focused || isLegacyFullscreen()`（`:816`）。** 真机 X11 随后由 WM 投递 **FocusIn** 恢复它；`checkInput()` 帮不上
    （`if (parent == null) return;`）。故 native 在**每次 `nCreateWindow` 后重新合成一次 FocusIn**，否则全屏往返后
    `isActive()` 恒 false → **进世界直接弹暂停菜单且"返回游戏"被立刻覆盖（死局）**。
13. **指针锁只跟 `Mouse.isGrabbed()`，不要跟全屏。** `LinuxDisplay.updatePointerGrab()` 全屏也会 grab，但**只有
    `shouldGrab()`（=Mouse.isGrabbed）时才隐藏光标**（`:432-440`）；绑定全屏会让**全屏主菜单也锁鼠标**，而桥在 grab 时
    抑制绝对坐标 → 光标不动、点不进世界。`nGrabPointer`/`nUngrabPointer` 不再写 `grabbing`（每帧镜像唯一拥有）。
14. **全屏尺寸来自 DisplayMode，不是 resize 通知。** `Display.update()` 里 `window_resized = !isFullscreen() && …`
    （`:652`）→ 全屏时通知被**强制抑制**；尺寸取 `createWindow` 时的 `mode.getWidth()`。故 `nGetAvailableDisplayModes`
    要给**屏幕尺寸**的 fullscreen-capable 模式（启动器传 `-Dmeow.screen.w/h`，优先"窗口所在显示器"，见 15）。
15. **多显示器**：全屏尺寸按**窗口所在显示器**取（`WindowProperties.displayId` → `getDisplayByIdSync`，回退默认显示器）。
    **已知限制**：`Display.initial_mode` 是 `final`、且 MC 自己的 fullscreen 标志会跳过它的 resize 检查 → **全屏期间
    显示器尺寸变化无法动态跟随**（LWJGL3/SDL 路径可以）。修法方向与难度见复盘笔记（JNI 调 MC 的 `resize(II)`）。
16. **别把"良性 cppcrash"当证据**：OHOS 每次启动可能固定产一个 cppcrash（pc 在 JIT rwx 匿名段、现场**没有** `liblwjgl.so`）。
    判据 = **真崩溃的栈里 pc 落在对应 so 的 r-x 段并带函数名**，并看 `Reason` 的故障地址。`-XX:ErrorFile=` 可让 JVM 写
    hs_err；**绝不要加 `-XX:-UseSignalChaining`**（OHOS 预装 SIGSEGV handler → JVM 启动即死）。`-Xlog:library=debug`
    可核对符号绑定。

## 7. 已知风险 / 未完成

- **AWT**：`LinuxSysImplementation` 静态块 `Toolkit.getDefaultToolkit()` 在无 X11 下风险（实测 1.7.10/1.8.9/1.12.2
  **未触发**）。对策：`-Djava.awt.headless=true`，或 overlay 影子类替换 `org.lwjgl.LinuxSysImplementation`。
- `Sys.<clinit>` **先载 native**（`Sys.java:112`）→ native 必须最先可用。
- **全屏动态调整**（15）与**多显示器 B/C 档**（共享块 ABI + 实时监听 + 可能 JNI 自愈）未做。
- **1.7.10 主菜单偶发局部闪一帧**：用户明确"可先搁置"。

## 8. 可复现性（已实测，非"应该"）

**规则**（项目铁律，`notes/00-current/工程与规范.md:126-127`）：声称"逐字节一致 / 可复现 / 已验证"前，必须**本次会话自己实跑**；
可复现编译的标准 = **≥2（建议 3）次干净重建 + `cmp` 逐字节比对**（不能只比哈希）。历史教训见
`notes/40-adaptation/openal-ohos.md:112-113`。

**一键校验**：
```sh
sh tools/lwjgl2/verify_reproducible.sh --sdk-native <sdk> [--with-generator]
```
- **A（native，无需 JVM）**：3 次干净重建 → sha256 + `cmp` + "不嵌绝对路径"断言。
- **B（`--with-generator`，需 JDK、由人跑）**：快照 `src/generated`/`src/native/generated`/`src/hdrs-meow`
  → 重跑 `generate_sources.sh` → `diff -r`。

**实测（2026-09-11）**：
- `liblwjgl.so` **3 次干净重建逐字节一致**（`cmp` 通过），sha256
  `df8864669dfc1703598903ae29a9ab70a733f603e8a8600a715939209eb47b11`，322600 B；
- **不嵌绝对路径、不嵌编译期时间戳**；与随包/装机件**同哈希**；
- ⇒ 在**同 tag + 同 SDK + 同源码路径**下可复现（输出不含路径/时间，故**构建目录无关**）。
- **生成物（B 段，实测 2026-09-11，用户跑）**：重跑 `generate_sources.sh` 后
  `src/generated` **472 文件**、`src/native/generated` **222 文件**、`src/hdrs-meow` **25 文件** 全部
  `diff -r` **逐字节一致** ⇒ **全链（生成 → 编译 → 随包）可复现**。
