# tools/sdl — self-built OHOS SDL3 (`libSDL3.so`) with a native `ohos` driver

Builds our SDL fork (**tag `release-3.4.14`**) into a `libSDL3.so` whose video
subsystem has a real, first-class **`ohos`** driver (external `OHNativeWindow` +
desktop GL via our EGL recipe) plus mouse hooks, and an `ohos` input pump. This
is the platform binding for **Minecraft 26.3**, which dropped GLFW for SDL3.

The driver bridges SDL to the window/EGL/input layer that Meowcraft's ArkTS +
`libmeowcraftbridge.so` already owns (shared state block `meow_environ`).

## 0. Sources (where to pull what)

The wrapper expects an SDL worktree at **`ref/SDL-3.4.14`** (workspace level,
never inside the app repo). It is **not kept in the tree** — it is a `git
worktree` derived from `ref/SDL`, regenerable in one command (and the wrapper
patches it in place, so remove it with `git worktree remove --force` when you do
not need it). Create it once:

```sh
# from the workspace root (holds ref/ and stuffs/)
git clone https://github.com/libsdl-org/SDL.git ref/SDL
git -C ref/SDL worktree prune    # if the tree was ever deleted by hand ("missing but already registered"), clear it first
git -C ref/SDL worktree add --detach "$PWD/ref/SDL-3.4.14" release-3.4.14   # 必须绝对路径：-C 会先 chdir，相对路径会在 ref/SDL 里再建一层
```

**Why exactly `release-3.4.14`?** It is the revision LWJGL 3.4.3's official
`libSDL3.so` was built from — read it from the natives jar marker
(`org.lwjgl:lwjgl-sdl:3.4.3:natives-linux` → `libSDL3.so.git` = `147a8ee32dbf9ac02f3794964490687b6bbda1bc`
= tag `release-3.4.14`). `org.lwjgl.sdl` → `Platform.mapLibraryNameBundled("SDL3")`
→ `libSDL3.so`, so our build must be ABI-identical to that revision.

> Our build does not use the official `libSDL3.so` — it supplies an `ohos`
> backend, which upstream SDL3 does not have.

## 1. What the driver does

`src/video/ohos/` (kept here; the patcher copies it into the SDL tree):

| File | Role |
|---|---|
| `SDL_ohosvideo.c/.h` | `VideoInit`/`VideoQuit`, `CreateDevice`, `OHOS_bootstrap` (registered **before** `DUMMY`), one display, bridge accessors, `OHOS_InitMouse()` call |
| `SDL_ohoswindow.c/.h` | `struct SDL_WindowData`, external-window creation, **single shared EGL surface**, buffer-geometry pinning, `OHOS_SyncSurfaceSize()` (resize) |
| `SDL_ohosevents.c/.h` | **input pump** (`OHOS_PumpEvents`): drains the bridge ring → SDL events; `WaitEventTimeout` |
| `SDL_ohosgl.c/.h` | EGL context/surface/swap + **GL entry-point resolution via `dlopen`+`dlsym`** (pointer identity with LWJGL) |
| `SDL_ohosvulkan.c/.h` | **Vulkan support**: the `Vulkan_LoadLibrary`/`UnloadLibrary`/`GetInstanceExtensions`/`CreateSurface`/`DestroySurface` entries SDL core needs (without them `SDL_Vulkan_LoadLibrary` fails with *“No dynamic Vulkan support in current SDL video driver (ohos)”*). See §6. |
| `SDL_ohosmouse.c/.h` | **`SDL_Mouse` hooks**: relative mode → `env->grabbing`; `WarpMouse` is an unconditional no-op (OHOS cannot move the user's pointer) |
| `SDL_ohosclipboard.c/.h` | **Clipboard write** (`SetClipboardText`) via the platform pasteboard NDK (`libpasteboard.so`/`libudmf.so`, resolved with `dlopen` so `DT_NEEDED` stays clean). Read/paste is deliberately absent: it needs `ohos.permission.READ_PASTEBOARD`. |
| `../misc/ohos/SDL_sysurl.c` | **URL opener** (`SDL_SYS_OpenURL`) — writes the URL to `$HOME/meow-open-url.txt`; the ArkTS side picks it up and does `startAbility`. Copied to `src/misc/ohos/` (not `src/video/ohos/`), see §3. |
| `ohos_meow_environ.h` | vendored, trimmed copy of the bridge ABI struct (ring + cursor slots) |

Key behaviours (all reasoned from Minecraft 26.3 + on-device findings):

- **External window.** ArkTS creates the XComponent surface; the bridge publishes
  the `OHNativeWindow*` in `meow_environ` (advertised via `MEOWCRAFT_ENVIRON`). The
  driver reads it (env var, or the create-time property
  `SDL_PROP_WINDOW_CREATE_OHOS_NATIVE_WINDOW_POINTER`), sets `SDL_WINDOW_EXTERNAL`,
  and never owns/destroys it.
- **Shared EGL surface.** All SDL windows (MC opens a probe window, the real one,
  and a throwaway test window) share **one** surface bound to the one native
  window; a window's `DestroyWindow` does **not** tear the surface down.
- **Buffer geometry.** `SET_BUFFER_GEOMETRY` is pinned to the real client size
  before surface creation and on resize (otherwise the surface disagrees with the
  XComponent).
- **Resize.** `OHOS_SyncSurfaceSize()` (each pump) follows the bridge size; on a
  real change it sends `SDL_EVENT_WINDOW_RESIZED` **before** updating `window->w`
  (SDL drops the event when the size equals `window->w`) + `PIXEL_SIZE_CHANGED`.
- **GL proc-address identity.** MC's `renderpearl.GlBackend.loadLibrary` asserts
  `GL.getFunctionProvider().getFunctionAddress("glGetError") == SDL_GL_GetProcAddress("glGetError")`,
  so `SDL_GL_GetProcAddress` is served by `dlsym` on the exact GL library path MC
  passes to `SDL_GL_LoadLibrary` (not `eglGetProcAddress`).
- **Input.** The deck: ArkTS → `critical_send_*` → SPSC ring in `meow_environ` →
  `OHOS_PumpEvents` drains it → `SDL_SendKeyboardKey/MouseMotion/MouseButton/MouseWheel/KeyboardText`
  (GLFW→SDL scancode/button tables). Text: `CHAR_MODS`/`CHAR` pair collapsed to
  one `TEXT_INPUT`; the UTF-8 string is NUL-terminated.
- **Mouse grab.** `SDL_Mouse.SetRelativeMouseMode` → `env->grabbing` (ArkTS then
  `LockCursor`s + hides the pointer); while grabbing the pump differences the
  bridge virtual cursor (`env->cursorX/Y`) and sends **relative** motion.
- **Game-initiated pointer moves are a no-op (2026-09-23).** OHOS gives an
  application no API to move the user's pointer, so a game warp is
  unimplementable and must not be faked. `OHOS_WarpMouse` (SDL core, incl. the
  exit-grab recentre and MC's own warps), the bridge `meowGrabReset` (ArkTS grab
  re-centre) and `glfwSetCursorPos` all **do nothing**: they do not write the
  cursor slot and do not send motion. Each prints a rate-limited `MeowSDL: WARP
  ignored (platform cannot move OS pointer) …` (at most one line per second,
  independent of the target, so even a per-frame warper cannot flood it) so a
  device log proves the no-op was taken. Pretending to move made MC believe the
  pointer sat at the warp
  target (the surface centre) while the real pointer stayed where the user left
  it, so UI hover jumped to the centre and a following click lifted the view
  (the touch path exposes it because a tap is teleport+click with no MOVE to
  mask the wrong position).
  **The cursor slot is now written by user input only** —
  `critical_send_cursor_pos` (menu pointer positioning, touch tap, NAPI
  `sendCursorPos`) plus genuine `meowGrabDelta` / `meow_touch_grab_delta` — so
  the non-grab absolute branch and the exit-grab sync always report the user's
  real pointer. `meowGrabReset` still re-aligns the bridge's grab-delta
  integration base to the current slot (read-only), so the first `meowGrabDelta`
  after entering grab is not lost.
- **Exit-grab pointer sync.** On the `grabbing` **1→0** edge the pump forces
  exactly one **absolute** motion report (`SDL_SendMouseMotion(relative=false)`)
  even when the virtual cursor did not move since `cLast`, so MC's menu
  pointer/hover lands immediately and the button under it lights up without a
  physical move. This covers the case the change-gated absolute branch would
  otherwise skip; the entry edge (**0→1**) deliberately does **not** report — MC
  is then in relative mode with the pointer hidden and an absolute write there
  could shift the grab baseline. The report is emitted after SDL core's exit
  recentre `SDL_PerformWarpMouseInWindow` (which clears `has_position` and
  flushes pending motion), so it is actually queued to MC instead of being
  dropped as a no-change sample. It is logged as `MOTION src=exitgrab`.
  When a pump that owes this report has no event window (`OHOS_EventWindow()`
  returns NULL, e.g. the transient after focus was lost), `cLast` is left
  unchanged so the report is retried on a later pump instead of being recorded
  as sent and lost — otherwise the sync would silently degrade to a HEAD hover
  that needs a physical move to refresh.
- **Size.** Mirrored from the bridge (`width`/`height` at `0x271dc`/`0x271e0`).

## 2. Build

```sh
# from the workspace root: requires ref/SDL-3.4.14 (see §0)
sh Harmomeow-Craft-Launcher/tools/sdl/rebuild_for_meowcraft.sh
```

The wrapper patches `ref/SDL-3.4.14` in place, builds into
`stuffs/research/sdl/build-ohos`, logs to `stuffs/research/sdl/build-ohos.log`,
and drops the artifact in `stuffs/research/sdl/out/libSDL3.so`.

Generic, path-agnostic script (any OHOS project can reuse it; the **source tree
must already be checked out**):

```sh
sh Harmomeow-Craft-Launcher/tools/sdl/build_sdl_meow.sh \
  --src <SDL3 源码树> --sdk-native <OHOS SDK>/native --out <输出目录> \
  [--build <构建目录>] [--api 23] [--arch arm64-v8a] [--patcher <补丁>]
```

SDK path defaults to `$OHOS_SDK_NATIVE`, else
`$HOME/devecow/deveco_tools/sdk/default/openharmony/native`.

### The configure command (what the script runs)

```sh
cmake -G Ninja -S ref/SDL-3.4.14 -B stuffs/research/sdl/build-ohos \
  -DCMAKE_TOOLCHAIN_FILE=Harmomeow-Craft-Launcher/tools/sdl/sdl_ohos.toolchain.cmake \
  -DOHOS_SDK_NATIVE=$OHOS_SDK_NATIVE -DOHOS_ARCH=arm64-v8a \
  -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL=23 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
  -DSDL_INSTALL=OFF -DSDL_UNIX_CONSOLE_BUILD=ON \
  -DSDL_AUDIO=OFF -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF \
  -DSDL_POWER=OFF -DSDL_HIDAPI=OFF -DSDL_CAMERA=OFF -DSDL_DIALOG=OFF \
  -DSDL_LOCALE=OFF -DSDL_TRAY=OFF
```

`tools/sdl/sdl_ohos.toolchain.cmake` wraps the OHOS SDK toolchain and
**re-labels the target as Linux** so SDL takes its unix backend paths (the SDK
toolchain sets `CMAKE_SYSTEM_NAME=OHOS`, which CMake does not treat as `UNIX`);
the actual compiler stays `aarch64-linux-ohos`. `SDL_UNIX_CONSOLE_BUILD=ON`
skips the X11/Wayland requirement.

## 3. Patcher

`patch_sdl_ohos.py <SDL3-src>` is idempotent (check-then-insert) and fails
loudly if an anchor is missing. It applies:

1. `src/thread/pthread/SDL_systhread.c`: guard `pthread_setcanceltype()` with
   `#if defined(PTHREAD_CANCEL_ASYNCHRONOUS) && !defined(__OHOS__)` (OHOS's
   *dynamic* libc does not export it → link error otherwise).
2. Copies `src/video/ohos/*` into the SDL tree.
3. `CMakeLists.txt`: `if(OHOS)` block in the unix branch — sets
   `SDL_VIDEO_DRIVER_OHOS`, globs the sources, sets `HAVE_SDL_VIDEO`, enables
   `SDL_VIDEO_OPENGL`/`_ES2`/`_EGL`, and links `native_window`
   (`OH_NativeWindow_NativeWindowHandleOpt` for buffer geometry).
4. `include/build_config/SDL_build_config.h.cmake`: emits `SDL_VIDEO_DRIVER_OHOS`.
5. `src/video/SDL_sysvideo.h`: `extern VideoBootStrap OHOS_bootstrap;`.
6. `src/video/SDL_video.c`: adds `&OHOS_bootstrap` to `bootstrap[]` (before `DUMMY`).
7. `src/video/SDL_egl.c`: OHOS branch — `libEGL.so` + desktop `libGLv4.so` (+ `libGLESv2.so`).
8. `src/video/khronos/EGL/eglplatform.h`: `#elif defined(__OHOS__)` with
   `typedef struct OHNativeWindow *EGLNativeWindowType;` + `#include <native_window/external_window.h>`.
9. `src/misc/ohos/SDL_sysurl.c`: copied in, and `src/misc/unix/SDL_sysurl.c` gets
   `#if !defined(__OHOS__)` around its body — otherwise two `SDL_SYS_OpenURL` definitions
   would be compiled (the unix one opens URLs by forking `xdg-open`, which OHOS lacks).
   The OHOS CMake block globs `src/misc/ohos/*` accordingly.

**Reverting a patcher change does not revert it.** The patcher is check-then-insert
(add-only), so a tree that was already patched keeps the edit and the next run merely
reports "already present" — that is how a removed `hilog_ndk.z` link kept failing the
`DT_NEEDED` check until the tree was reset. To undo, reset and let the patcher re-apply:

```sh
git -C ref/SDL-3.4.14 checkout -- .     # worktree back to pristine release-3.4.14
```

## 4. Verified build (2026-09-11, SDK clang 15.0.4, api 23; re-verified 2026-09-23, 3× clean rebuild)

| Item | Result |
|---|---|
| Configure | `--   Video drivers: dummy offscreen ohos` |
| Compile/link | ✅ `[229/231] Linking C shared library libSDL3.so.0.4.14` |
| `DT_NEEDED` | `libnative_window.so`, `libc.so` (EGL/GL are `dlopen`ed at runtime) |
| Exports | 1270 `SDL_*` dynamic symbols |
| Driver present | `SDL OpenHarmony (OHOS) video driver`; `OHOS_bootstrap` in `libSDL3.so` |
| Artifact | `stuffs/research/sdl/out/libSDL3.so` (→ installed as `libSDL3.so`, manifest tag `common`) |
| sha256 | `5fe4d5d44517d8f4bd1a37c5cef76518a977b7ca4e2f97b13bb81791c8d01e59` (2,054,656 bytes; 2026-09-23 **minimal-set cleanup**: game-initiated pointer moves are a no-op everywhere (`OHOS_WarpMouse` / bridge `meowGrabReset` / `glfwSetCursorPos`), the pump forces exactly one absolute report on the exit-grab (`grabbing` 1→0) edge, and the interim input probe machinery was cleaned up. **2026-09-23 follow-up (review fixes)**: the exit-grab absolute report now keeps `cLast` unchanged when the pump has no event window, so the sync is retried instead of being swallowed (`win==NULL` no longer degrades to a HEAD hover); and the `WARP ignored` proof line is capped at a hard one-per-second independent of the target (the old same-target dedup alone had no bound). Supersedes the `5f8b551f…` and `b7fcf15d…` artifacts) |
| Verification (2026-09-23) | **3× clean rebuild + `cmp` byte-identical** to each other and to the shipped `libs/meowlwjgls/libs/arm64-v8a/libSDL3.so` (`5fe4d5d4…`, 2,054,656 bytes). Scope: same tag `release-3.4.14` / same SDK (api 23, clang 15.0.4) / same absolute `--src` `ref/SDL-3.4.14` + `--out` `stuffs/research/sdl/out`. Method: reset the worktree to pristine + `rm -rf` the build dir before each round, then `cmp` (not just sha256). See §4b. |

> Reproducibility: like all our native builds, the digest corresponds to the
> recorded `--src`/`--out` paths; rebuilds at other paths are functionally
> identical but hash differently.

## 4b. Reproducibility

**Verification method / 校验方式 (2026-09-23): 3× clean rebuild, `cmp` byte-identical.** Each round
reset `ref/SDL-3.4.14` to pristine `release-3.4.14` (`git checkout -- .`, plus removing
the patcher's untracked `src/video/ohos/` and `src/misc/ohos/`, so the patcher is
exercised), then `rm -rf` the build dir, then ran `rebuild_for_meowcraft.sh`. All three
artifacts are **byte-identical to each other and to the shipped
`libs/meowlwjgls/libs/arm64-v8a/libSDL3.so`** (`cmp`, not just sha256):
`libSDL3.so` sha256 `5fe4d5d44517d8f4bd1a37c5cef76518a977b7ca4e2f97b13bb81791c8d01e59`, 2,054,656 bytes.
Scope: same tag (`release-3.4.14`), same SDK (api 23, clang 15.0.4) and the same absolute
`--src` (`ref/SDL-3.4.14`) / `--out` (`stuffs/research/sdl/out`) paths. Same-path caveat
as all our natives: the linker embeds the output path in `.dynstr`, so rebuilds at other
paths are functionally identical but hash differently.

`rebuild_for_meowcraft.sh` itself only `rm -rf`s the build dir (via `build_sdl_meow.sh`)
and re-runs the idempotent patcher in place — it does **not** re-create the worktree; the
pristine reset above is done by hand for the clean-rebuild check.

Earlier rounds (Vulkan, window-focus, clipboard/URL, and the 2026-09-23 motion-diagnostics
build `bd5b42df…`) were each verified byte-identical; the 2026-09-23 probe era produced
`b7fcf15d…`, the minimal-set cleanup `5f8b551f…` and the review-fix round this
`5fe4d5d4…` — those were iteration rounds, one rebuild each. This final round re-verified
the shipped `5fe4d5d4…` with the full 3×/`cmp` procedure above.

Contract checked on the artifact: 1270 `SDL_*` dynamic symbols, `DT_NEEDED` = `libnative_window.so libc.so`
only (EGL/GL/Vulkan/hilog are resolved at run time), `ohos` driver present.

## 5. Install into the app
```sh
sh Harmomeow-Craft-Launcher/tools/lwjgl/install_natives.sh --sdl stuffs/research/sdl/out/libSDL3.so
# → libs/meowlwjgls/libs/arm64-v8a/libSDL3.so (natives.manifest tag "common")
```
Then clean the module build and redeploy (`hvigor` does not track `libs/` add/remove):

```sh
rm -rf libs/{meowlwjgls,meowjre,meowcraftlib}/build entry/build
devecocli build --modules entry meowjre
devecocli run --module entry meowjre --device <serial>
```

## 6. Limitations / not provided

- **IME composition (preedit)**: only committed text (`TEXT_INPUT`) is delivered;
  `TEXT_EDITING` is not synthesized (Chinese input works via ArkUI's committed
  text; MC's own preedit overlay is not fed).
- **Fullscreen**: implemented — `OHOS_SetWindowFullscreen` forwards to the ArkTS
  `maximize()`/`recover()` chain (same chain the GLFW path used) via the bridge's
  plain-C `meowSetFullscreenRequest`; SDL core tracks `SDL_WINDOW_FULLSCREEN` and
  posts the ENTER/LEAVE events, and the real pixel size arrives via
  `OHOS_SyncSurfaceSize` (`device_caps |= VIDEO_DEVICE_CAPS_SENDS_FULLSCREEN_DIMENSIONS`).
  Exclusive mode degrades to borderless (display-mode list is empty).
- **Clipboard**: **write implemented** (2026-09-21) — MC 26.3 copies through
  `SDLClipboard.SDL_SetClipboardText` → `SDL_ohosclipboard.c` (the platform pasteboard NDK).
  Reading/pasting is not implemented on purpose (it needs `ohos.permission.READ_PASTEBOARD`,
  and the no-dialog alternative, the paste control, only exists in ArkTS UI).
- **Opening links**: **implemented** (2026-09-21) — MC >= 26.3 calls `SDLMisc.SDL_OpenURL`,
  which `src/misc/ohos/SDL_sysurl.c` turns into a request file that the ArkTS side picks up
  (see notes `00-current/架构决策与踩坑.md` §13.3). **MC <= 26.2 is not supported**: there MC
  bypasses every library and runs `xdg-open` itself through `Runtime.exec`, and OHOS exposes
  no native "open a link / start another app" API (see `已知限制与待解.md` §H6).
- **messagebox / tray**: not implemented by this driver.
- **Vulkan**: implemented (2026-09-19). `SDL_Vulkan_LoadLibrary` takes the caller's
  library path, else `SDL_HINT_VULKAN_LIBRARY` (which `SDL_GetHint` reads from the
  environment, so `SDL_VULKAN_LIBRARY=libmeowvulkan.so` switches loader with no
  rebuild), else the system loader. Instance extensions are reported as
  `{VK_KHR_surface, VK_OHOS_surface}` and the surface is created from the external
  OHNativeWindow the bridge publishes. Two things to know before touching it:
  (a) SDL 3.4.14's bundled Khronos headers predate the OHOS surface extension, so the
  WSI symbols are declared locally in `SDL_ohosvulkan.c` (values match the upstream
  HarmonyOS port and the bridge); (b) the driver deliberately does **not** reproduce the
  bridge's pre-surface window policy (producer geometry pinning + file-driven
  usage/format): the bridge and ArkTS already set both when the surface id is published,
  and the surface plus swapchain come up correctly without it (measured 2026-09-19), so
  the driver stays free of a `libmeowcraftbridge.so` dependency. That policy now lives in
  the bridge as a file-local static used only by the GLFW path.
  `SDL_Vulkan_GetPresentationSupport` is deliberately not
  implemented: SDL then reports "always supported", the same simplification the GLFW
  bridge makes. Evidence: `stuffs/research/sdl/reports/vulkan-mc263.md`.
- **This driver's own logging goes to stderr** (with a best-effort hilog copy): the
  application silences `SDL_Log*` — nothing from SDL core or this driver reaches hilog or
  a log file, even at `WARN` — while stderr provably arrives in the exported log, and
  linking hilog would add a `DT_NEEDED` entry that `build_sdl_meow.sh` deliberately
  rejects. Look for `[jre_stderr] MeowSDL: …`.
- **Motion diagnostics (always on as of 2026-09-23, still in the current build)**: the `ohos` input pump also
  emits rate-limited `MeowSDL: BUTTON …`, `MeowSDL: MOTION src=… grabbing=…`
  and `MeowSDL: GRABMODE src=…` lines on stderr (same `[jre_stderr] MeowSDL:` channel;
  `SDL_Log` stays invisible on this platform) to pin down the menu→game warp jump (since
  located in MC's own `MouseHandler.accumulatedDX/DY` and accepted — see notes
  `00-current/已知限制与待解.md` §B7).
  Reading: a `BUTTON down` immediately followed by `MOTION` from the same `src` marks that
  `src` as the suspect. A game-initiated warp no longer logs a `MOTION src=warp` (nothing
  moved): it prints a rate-limited (at most one per second, target-independent)
  `MeowSDL: WARP ignored (platform cannot move OS pointer) …` instead, so a device log
  proves the no-op was taken. The forced absolute report on the
  `grabbing` 1→0 edge is `MOTION src=exitgrab` (present even with `dx=dy=0`); the non-grab
  absolute pass-through stays `MOTION src=pumpabs`. These lines remain in the current build:
  the `WARP ignored` line is kept deliberately as the bounded proof the pointer no-op was
  taken (call sites `src/video/ohos/SDL_ohosevents.{h,c}` and the bridge
  `libs/meowcraftlib/src/main/cpp/meowcraftbridge/input_bridge.c`).
- Window `Show/Hide/Raise/Focusable/Minimize` are not implemented (external
  window owned by ArkTS).

## 7. Related

- Design/plan: `notes/20-design/render/SDL3桥接-设计.md`, `notes/20-design/render/SDL3适配-复盘.md`.
- Research reports: `stuffs/research/sdl/reports/*.md` (incl. `vulkan-mc263.md`).
- Upstream reference for OHOS (read-only; only on `main`, entering no 3.4.x release):
  `stuffs/research/sdl/upstream-openharmony/`.
- The jar side (adding the `org.lwjgl.sdl` module): `tools/lwjgl/README.md`.
