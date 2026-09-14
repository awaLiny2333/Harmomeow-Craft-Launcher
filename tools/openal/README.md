# tools/openal — 自编 OHOS 版 OpenAL Soft（libopenal.so）

用**上游 OpenAL Soft 1.24.3 源码**自编鸿蒙版 `libopenal.so`，替换外部转手来的
预编译件（`libs/meowlwjgls/libs/arm64-v8a/libopenal.so`），把它的可控性从
「归因（未复现）」升级为「**源码级**」。

包含两个后端改造：
- **OpenSL 后端移植**（`opensl.cpp`）：上游是 Android 专用，OHOS 需移植（见下）。
- **新增 OHAudio 后端**（`ohaudio.cpp`）：OHOS 推荐 API，取代过时的 OpenSL ES。**默认后端**。

## 〇、源码获取与构建前置

```sh
git clone https://github.com/kcat/openal-soft.git ref/openal-soft     # 含全部 tag（1.21–1.25…）
sh tools/openal/rebuild_for_meowcraft.sh 1.24.3    # 本项目：自动 worktree(tag) → 三补丁 → 构建 → 落 meowlwjgls
# 通用脚本（路径全参数化，可脱离本工程复用）：
sh tools/openal/build_openal_meow.sh --src <源码树> --sdk-native $SDK/native --out <目录>
```
- SDK native：`$OHOS_SDK_NATIVE`，默认 `$HOME/devecow/deveco_tools/sdk/default/openharmony/native`。
- `rebuild_for_meowcraft.sh` 要求 `ref/openal-soft` 是 git clone（否则报错并给出 clone 命令），自动建/清 tag worktree。
- 三补丁器由 `build_openal_meow.sh` 依序调用（OpenSL → OHAudio → events 导出），见 §6。

## 一、OpenSL 后端移植（`patch_openal_ohos.py`）

上游 `alc/backends/opensl.cpp` 是**为 Android 写的**：含 `<SLES/OpenSLES_Android.h>`、
Android simple buffer queue IID、并（在 `#if 0` 里）用 JNI。OHOS 只有
`<SLES/OpenSLES_OpenHarmony.h>` + `SL_IID_OH_BUFFERQUEUE`，没有 Android 头/jni.h。
补丁（`__OHOS__` 守卫，非 OHOS 仍可编 Android）：

1. `jni.h` 仅在非 OHOS 引入（唯一 JNI 用法本就在 `#if 0` 里）。
2. 头文件：OHOS 用 `OpenSLES.h` + `OpenSLES_OpenHarmony.h`。
3. 中性别名 `MeowBufferQueueItf` / `MeowBufferQueueState` / `MeowDataLocator_BufferQueue`
   与 `MEOW_SL_IID_BUFFERQUEUE` / `MEOW_SL_DATALOCATOR_BUFFERQUEUE`，OHOS 映射到 OH buffer queue。
4. OHOS 回调多一个 `size` 参数（`SlOHBufferQueueCallback`）。
5. OHOS 创建 player/recorder 时不请求可选接口（随后 `GetInterface` 取）。
6. Android 专有 stream type / recording preset 配置块在 OHOS 下编译掉。

## 二、新增 OHAudio 后端（`patch_openal_ohaudio.py` + `ohaudio/`）

上游**无 OHAudio 后端**，故新写一个（`alc/backends/ohaudio.cpp/.h`）：

- **播放**：OHAudio 拉取回调 `OH_AudioRenderer_OnWriteDataCallback` 里直接
  `mDevice->renderSamples()`（与 Oboe/CoreAudio 同构，无额外线程/ring，延迟最低）。
- **捕获**：`OH_AudioCapturer_OnReadDataCallback` 推入 ring buffer，供 `captureSamples` 读。
- **配置**：`AUDIOSTREAM_USAGE_GAME`、`ENCODING_TYPE_RAW`、请求 `LATENCY_MODE_FAST`（+10ms 帧），
  失败由系统自动降级 NORMAL；格式/声道以 `Get*` 回查为准（S16LE/S32LE/F32LE/U8）。
- **注册**：`BackendList` 中 `ohaudio` 排在 `opensl` **之前** ⇒ 默认 OHAudio；OpenSL 保留作回退
  （`ALSOFT_DRIVERS=opensl` 可强制）。错误回调接 `handleDisconnect`。
- **构建接线**：`patch_openal_ohaudio.py` 装入两文件并锚定修改
  `CMakeLists.txt`（`HAVE_OHAUDIO` + `find_library(ohaudio)` 块）、`config.h.in`、`alc/alc.cpp`。

## 文件

| 文件 | 作用 |
|---|---|
| `patch_openal_ohos.py` | OpenSL 后端移植补丁器（版本容错：认 1.23.x + 1.24.x 锚点） |
| `patch_openal_ohaudio.py` | 安装 OHAudio 后端：拷入 `ohaudio.cpp/.h` + 改 CMake/config/alc.cpp（1.24.x 用 `config_backends.h.in`） |
| `ohaudio/ohaudio.cpp` / `ohaudio.h` | OHAudio 后端源码（按 1.24 API：`open(std::string_view)` / `enumerate` / fmt；播放 model-b + 捕获 ring） |
| `patch_openal_events_export.py` | 导出 `ALC_SOFT_system_events` 三个函数（补 `ALC_API` + 列入 `libopenal.version`） |
| `build_openal_meow.sh` | **独立通用**构建脚本：路径全从参数来，无项目假设 |
| `rebuild_for_meowcraft.sh` | 本项目 wrapper：从 `ref/openal-soft` 拉临时 worktree → 构建 → 落 `meowlwjgls` |

## 用法

```sh
# 本项目（默认 tag 1.24.3）
sh tools/openal/rebuild_for_meowcraft.sh

# 通用脚本（任何 OHOS 工程可复用）
sh tools/openal/build_openal_meow.sh \
  --src <openal-soft 源码树> \
  --sdk-native <OHOS SDK>/native \
  --out <输出目录> \
  [--build <构建目录>] [--patcher <OpenSL补丁>] [--ohaudio-patcher <OHAudio安装器>] [--api 23]
```

SDK 不在默认位置时用环境变量 `OHOS_SDK_NATIVE` 覆盖（默认 `$HOME/devecow/deveco_tools/sdk/default/openharmony/native`）。

## 构建配置

- 工具链：`<sdk>/native/build/cmake/ohos.toolchain.cmake`（`OHOS_ARCH=arm64-v8a`、`OHOS_STL=c++_shared`）。
- 后端：**OHAudio（默认）+ OpenSL（回退）**；其余 ALSA/Pulse/OSS/JACK/SndIO/PortAudio/SDL/Oboe/PipeWire 全关。
- `FindOpenSL` 强制要求 Android 头 → 显式传 `OPENSL_INCLUDE_DIR` / `OPENSL_ANDROID_INCLUDE_DIR` /
  `OPENSL_LIBRARY` 绕过（`OPENSL_ANDROID_INCLUDE_DIR` 指向 sysroot include 即可）。
- `ALSOFT_UPDATE_BUILD_VERSION=OFF`：worktree 的 `.git` 文件会触发 OpenAL 的 git 版本见证步骤报错。
- **强制导出可见性**（关键坑）：OHOS 交叉编译下 CMake 对
  `__attribute__((visibility("default")))` 的 try_compile 误判失败 → `ALC_API`/`AL_API` 为空 →
  库零导出 → LWJGL 崩 `A core ALC function is missing`。显式传
  `-DHAVE_GCC_PROTECTED_VISIBILITY=0 -DHAVE_GCC_DEFAULT_VISIBILITY=1`，并断言 `alc` 导出数 > 0。
- 产物 `llvm-strip --strip-unneeded` 后 ~940KB。

## 核验（2026-09-10，OpenAL Soft 1.24.3 / OHAudio 默认版）

| 项 | 结果 |
|---|---|
| 版本串 | `1.24.3` |
| `DT_NEEDED` | `libohaudio.so` / `libhilog_ndk.z.so` / `libc++_shared.so` / `libc.so` |
| 后端 | `config_backends.h`: `HAVE_OHAUDIO` + `HAVE_OPENSL`；`BackendList`: OHAudio → OpenSL |
| 导出 | `alc*` **33** 个 + `al*` **176** 个（含 `ALC_SOFT_system_events` 的 `alcEventIsSupportedSOFT`/`alcEventControlSOFT`/`alcEventCallbackSOFT`） |
| 实机 | ✅ 1.21.10 音频正常；✅ **26.1.2 音频正常**（其 `CallbackDeviceTracker` 依赖的 `ALC_SOFT_system_events` 已导出） |
| sha256 | `fececaeea7f785c8f47a9b4f804421b3922524f0c2df87419d21256a680b2d6c` |
| 可复现 | ✅ **3 次干净重建 `cmp` 逐字节一致**（同 tag + SDK + 构建路径），sha 恒为 `fececaee…`（2026-09-10 实跑核实） |

> 历史：1.23.1 OHAudio 版 sha `9c2ae446…` / OpenSL-only `0d6ec75c…` / 归因件 `15ad72b0…`（均已退役，制品留 git 历史）。

## 相关

- 适配说明：`notes/40-adaptation/openal-ohos.md`（OpenSL 移植）、`notes/40-adaptation/ohaudio-backend.md`（OHAudio）
- 溯源：`notes/30-supply-chain/provenance-master.md` §4.3、`per-so-catalog.md` §B
- 官方文档：OpenSL ES 播放 `…/using-opensl-es-for-playback`；OHAudio 播放 `…/using-ohaudio-for-playback`
