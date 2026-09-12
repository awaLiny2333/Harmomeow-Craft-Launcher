<p align="center">
  <img src="AppScope/resources/base/media/foreground.png" width="120" alt="Harmomeow Craft Launcher">
</p>

<h1 align="center">Harmomeow Craft Launcher</h1>

<p align="center">
  <b>Harmo</b>nyOS + <b>meow</b> — a launcher that runs <b>Minecraft: Java Edition</b> natively on HarmonyOS PCs.<br/>
  <b>Built and run entirely on a HarmonyOS PC.</b>
</p>

<p align="center"><em>HarmonyOS 2in1 (PC) · ArkTS + self-written C/C++ bridge · Minecraft 1.6.x – 26.3</em></p>

<p align="center"><b>English</b> | <a href="README.zh.md">中文</a></p>

---

Harmomeow Craft Launcher targets **HarmonyOS PCs**. It does not rely on an Android compatibility layer and does not modify Minecraft; instead it uses **ArkTS + a self-written native bridge** to connect Minecraft's window / input / rendering / audio to HarmonyOS native capabilities (OHNativeWindow / EGL / input ring / OHAudio). Everything is **transparent and controllable**.

---

# Part 1 · User Guide

## Supported game versions

**Minecraft: Java Edition 1.6.x – 26.3**
(Verified on real hardware: 1.6.1 / 1.6.4 / 1.7.10 / 1.8.9 / 1.12.2 / 1.16.5 / 1.21.10 / 26.1.2 / 26.2 / 26.3-rc-1 are all playable)

| Version range | Rendering path | Status |
|---|---|---|
| 1.6.x – 1.12.2 | self-built LWJGL2 + gl4es (GLES) | ✅ |
| 1.13 – 1.16.x | LWJGL3 + gl4es (GLES) | ✅ |
| 1.17 – 1.21.x | LWJGL 3.3.3 + system desktop GL (Zink) | ✅ |
| ≥ 1.22 (26.x) | LWJGL 3.4.3 | ✅ |
| ≥ 26.3 | self-built SDL3 + `ohos` driver | ✅ |

## Features

**Game directories**
- Add multiple `.minecraft` directories with custom nicknames; switch between them freely.

**Version management**
- **Download / install vanilla versions online** (BMCLAPI / official mirror switching; release/snapshot/other filtering).
- Per-version **"version isolation"** toggle: saves / options / logs live inside the version folder, isolated from other versions (same model as HMCL / PCL — so `.minecraft` folders are mutually compatible!).
- Per-version **rendering backend** selection (Recommended by version / Desktop OpenGL / GL4ES (compatible)).

**Accounts**
- **Offline accounts**: multiple accounts; UUID and other info shown instantly.
- **Microsoft (premium) sign-in**: OAuth2 **device-code flow** (sign in / auto-refresh / manual refresh / sign out); you must supply your own valid Microsoft Azure client id (AppID).

**Game**
- Separate game window & separate process; you can close the launcher while the game keeps running.
- **Fullscreen** (F11 / video settings).
- **Display scaling**: render resolution = window / N (N = 1x/1.5x/2x/3x/4x); low-res rendering + upscale, to relieve the load on high-DPI screens (a little mercy for the Kirin & Maleoon GPU (￣ω￣;)).
- Built-in JRE with one-click extraction; drops some legacy OpenSL ES in favor of HarmonyOS **OHAudio** (low latency).

**Advanced options**: mouse sampling-rate overlay, CPU thread count, max heap, scroll speed, display scaling, Microsoft client_id, etc.

## Known limitations

- **Refresh-rate tier**: the FPS ceiling equals the system display tier ("Dynamic" = 60 / "High" = 90); the app cannot force 90.
- **Mouse grab sampling = display frame rate**: while grabbing (cursor locked) the mouse sampling is tied to the UI frame rate; when not grabbing, native ~500 Hz absolute coordinates pass through (a bit more responsive).
- **Physical F-keys**: the F row may behave oddly; we've done our best 🤪.
- **Native Vulkan backend unavailable on MC ≥ 26.2**: the KirinX90 Vulkan driver lacks some extensions MC requires.
- **1.16.5 first screen has no text** — honestly no idea why, very bizarre.
- The platform `libGLv4` is **Mesa Zink** (GL-on-Vulkan); occasional 20–70 ms spikes, not solvable at the app layer.
- Older versions (1.4.x / 1.5.x) are unverified and **outside** the support window.

## Getting & installing

> **Not on any app store** yet. Build it yourself (see Part 2).

> **Requirements**: HarmonyOS **2-in-1 (PC)**, API ≥ 23 (real device API 26 / 7.0.0). You need an installed copy of Minecraft Java Edition or use **online download**; for **Microsoft sign-in** you must supply your own Azure client_id (see the developer part).

---

# Part 2 · Developer Guide

## Positioning

**An impulsive, experimental launcher that compiles and runs Minecraft: Java Edition on a commercially-available HarmonyOS PC (?! spur-of-the-moment !?)** — connecting Minecraft's GLFW / SDL window, input, GL and OpenAL audio to HarmonyOS native capabilities (OHNativeWindow / EGL / SPSC input ring / OHAudio), with a fully **transparent and controllable** chain.

## Architecture overview

```
ArkTS (entry HAP)                       :game process (separate UIAbility / process)
 ├ directory / version / account / download / settings UI
 └ GameWindow ─ XComponent(surface)
        │  setGameSurface / launchJvm
        ▼
 libmeowjrebridge.so (meowcraftlib)     NAPI: launchJvm / surface / send_* / cursor lock
        │  dlopen(RTLD_GLOBAL)
        ▼
 libmeowcraftbridge.so                  clean-room bridge: EGL/GLCapabilities + SPSC input ring + window/resize/grab
        ▲
        │  dlsym / input ring / meow_environ shared block
 liblwjgl*.so / libSDL3.so              platform bindings (GLFW semantics / SDL3 ohos driver)
        ▼
 JVM (bundled JRE) → meow.launcher (clean-room) → Minecraft
```

- **Java side**: official LWJGL modules + our own **clean-room overlay** (GLFW / CallbackBridge / GLCapabilities / RendererInit).
- **Native side**: clean-room `libmeowcraftbridge.so` (provides all `glfw*` semantics), `libmeowjrebridge.so` (NAPI / `JLI_Launch`), `libmeowassets.so` (JRE extraction).
- **Launch chain**: `meow.launcher` handles classpath staging, accounts, argv, `JLI_Launch`.

## Platform & toolchain

- **Target platform**: HarmonyOS 2-in-1, `targetSdkVersion = 6.1.0(23)`, `deviceTypes = ["2in1","tablet","phone"]`; real device **MateBook Fold (Kirin X90)**.
- **Build toolchain**: **DevEco Studio / DevEco Code** and its CLI **`devecocli`**. **The vast majority of this project's artifacts are built by it** — HAP / HSP / HAR, CMake/NDK cross-compilation of the natives, signing, deployment, device management and static analysis. OHOS SDK at `$HOME/devecow/deveco_tools/sdk/default/openharmony`.

## This machine's environment (dev machine = target device)

- **Device**: HUAWEI MateBook Fold (2-in-1 PC, ARM aarch64, CPU **Kirin X90**)
- **OS**: **HarmonyOS 7.0.0.105 (SP12C00E100R12P5logpatch09)**
- **IDE / toolchain**: **DevEco Code 0.3.4** (and the CLI `devecocli`)
- **SDK**: `targetSdkVersion / compatibleSdkVersion = 6.1.0(23)`, `modelVersion 6.1.0`; SDK path `$HOME/devecow/deveco_tools/sdk/default/openharmony`
- **How it was made**: developed entirely with **DeepSeek V4 Flash + DeepSeek V4.1 Flash** (AI-assisted)
- Note: on HarmonyOS 7.0.0.105, DevEco Code inside the hiShell **cannot run a JVM correctly yet** → every `javac` step is run manually by a human in a JDK-equipped shell.

## Dependencies

| Component | Version | License | Bundled | Notes |
|---|---|---|---|---|
| OpenJDK / JRE | 26.0.2.1 (official glibc; our binary patches + self-built `libjli`/`libjvm`) | GPL-2.0 + Classpath-Exception | ✅ | Runtime; **fully self-held (zero black box)** — see `tools/jre26/` |
| LWJGL | 3.3.3 / 3.4.3 / 2.9.3 | BSD-3 | ✅ | **three generations co-exist**, selected per MC version |
| OpenAL Soft | 1.24.3 | LGPL-2.0+ | ✅ | OHAudio backend |
| FreeType | 2.13.3 | FTL | ✅ | font rendering |
| SDL3 | `release-3.4.14` (fork) | Zlib | ✅ | platform binding for MC ≥ 26.3 |
| shaderc / SPIRV-Cross | pinned to LWJGL 3.4.3 | Apache-2.0 | ✅ | MC ≥ 26.3 `renderpearl` |
| gl4es | v1.1.7 | MIT | ✅ | fixed-pipeline translation layer for ≤ 1.16 / legacy |
| libffi | 3.8.0 | MIT | (linked into lwjgl) | LWJGL ≥ 3.4 dependency |
| oshi | 5.7–6.9 + 1.1 | MIT | ✅ | CPU-info patch |
| gson | 2.13.1 | Apache-2.0 | ✅ | launcher-only (shaded to `meow.gson`) |

> Full third-party attributions: [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md); full license texts: [`LICENSES/`](LICENSES/); source offer: [`SOURCE-OFFER.md`](SOURCE-OFFER.md).

## Build guide

**The app itself**: open this project in **DevEco** → `devecocli build` (or IDE Build). **Signing material is not committed** — generate it locally via DevEco "Project Structure → Signing Configs → Automatically generate signature".

**Self-built bundled components (`tools/`)**: everything we build or patch ourselves is captured under [`tools/`](tools/), **fully path-parameterized, reusable independently of this project, and byte-reproducible**:

| Tool | Artifact |
|---|---|
| [`tools/lwjgl/`](tools/lwjgl/) | LWJGL two-generation jars + 6 natives + `libffi` + extras packing |
| [`tools/lwjgl2/`](tools/lwjgl2/) | legacy LWJGL2 `liblwjgl.so` (MC 1.6–1.12) |
| [`tools/openal/`](tools/openal/) [`tools/freetype/`](tools/freetype/) [`tools/gl4es/`](tools/gl4es/) [`tools/sdl/`](tools/sdl/) [`tools/shaderc/`](tools/shaderc/) [`tools/oshi/`](tools/oshi/) [`tools/meow-launcher/`](tools/meow-launcher/) | OpenAL / FreeType / gl4es / SDL3 / shaderc / oshi / clean-room launcher |

- Index: [`tools/README.md`](tools/README.md)
- Convention: **`javac` must be run by a human in a JDK-equipped shell** (DevEco Code in the hiShell cannot use a JVM on HarmonyOS 7.0.0.105 yet); native (CMake / cross-compilation) and python packaging are scriptable.
- **Reproducibility**: same tag + same SDK + same **absolute** build path → **byte-identical** (most artifacts verified with 3× clean rebuilds + `cmp`).

## Production

- **Runtime environment**: an ordinary HarmonyOS PC (2-in-1), API ≥ 23.
- **Deploy order**: install the HAR/HSP first (`meowjre` / `meowcraftlib` / `meowlwjgl3`), then the `entry` HAP; **after changing natives, clean the module build and rebuild the HSP**.

## License

The **original code of this project is MIT** (see [`LICENSE`](LICENSE)); bundled third-party components keep their own licenses (see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)).

## Non-affiliation

See [`TRADEMARKS.md`](TRADEMARKS.md) for trademark / non-affiliation notices. Minecraft is a trademark of Mojang / Microsoft; this project **does not distribute the game itself**.

## Acknowledgements

During design and implementation we studied the behavior and design of several **launcher projects** (to align on the directory model, install flow, accounts and version isolation; some of which we also use as our own daily drivers on Windows / HarmonyOS):

- **HMCL** (Hello Minecraft! Launcher) — directory model / vanilla install / accounts & version isolation
- **PojavLauncher** — the idea of a platform bridge for running Minecraft off-desktop platforms
- **Amethyst** (Pojav family) — LWJGLX / platform-adaptation reference
- **HomoLauncher** — a HarmonyOS launcher reference
- **PCL (Plain Craft Launcher, Windows)** — we admire its **design aesthetics and interaction**, and use it as our daily driver on Windows

These projects — shared selflessly on the internet, whether **open-source or not** — have brought joy to countless players and given every developer who ventures into this field **a solid starting point**.

Thanks as well to the Minecraft community and to the authors/contributors of these projects.

> Note: **PCL is closed-source**; HMCL / Pojav / Amethyst / HomoLauncher are mostly GPL-family. **This project includes none of their code** (a clean-room implementation) — this acknowledgement is a research & design tribute only, and does not constitute use of, or derivation from, their code.
