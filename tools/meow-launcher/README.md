# tools/meow-launcher — clean-room `meow.launcher`

Builds the shipped `launcher.jar` from **our own** Java sources — no third-party
launcher, **no GPL code**. Replaces the earlier derived launcher built by `tools/launcher/`.

## What's in the jar
| package | what | license |
|---|---|---|
| `meow.launcher.*` | launcher (entry, class loader, dirs, account, version json, args, classpath, options) | ours |
| `com.mojang.text2speech.*` | clean-room narrator stub (`Narrator` + `NarratorDummy`) — MC calls `getNarrator()` | ours (API dictated by MC) |
| `android/util/*` | vendored AOSP (`ArrayMap` etc.) — needed by `lwjgl.jar`'s GLFW | Apache-2.0 |

Compile-only dep: **gson 2.13.1** (Apache-2.0). Kept as `com.google.gson` in the built jar and
**shaded to `meow.gson` in finalize** (`tools/relocate_gson.py`) so it never shadows MC's gson.

## Contract (must stay compatible with the ArkTS host)
- jar member name stays `launcher.jar`; argv `[<playerName>, <versionId>]`.
- main class `meow.launcher.MeowLauncher`; system class loader `meow.launcher.MeowClassLoader`
  (`extends URLClassLoader`, **public `(ClassLoader)` ctor**).
- Property keys (`MEOWCRAFT_HOME`, `MEOWCRAFT_GAME_DIR`, `meowcraft.path.*`, `glfwstub.*`, `cacio.managed.screensize`, …)
  are unchanged. The host pairing lives in `entry/.../constants/LaunchContract.ets`
  (`MEOW_MAIN_CLASS` / `MEOW_CLASS_LOADER`) + `MinecraftLauncher.ets`.

## Build / ship
```sh
# 1) compile + pack (javac must be run by you; the agent shell has no JVM)
sh tools/meow-launcher/build_meow_launcher.sh
# -> stuffs/research/meow_launcher_build/out/launcher.jar (still references com.google.gson)

# 2) swap into the shipped tar + shade gson (pure python; agent can run)
#    layout-aware: replaces ONLY launcher.jar (re-shading its gson refs to meow.gson),
#    keeping the multi-generation lwjgl-<gen>.jar members byte-identical.
sh tools/meow-launcher/finalize_for_meowcraft.sh

# 3) bump EXTRAS_VERSION in entry/.../constants/LaunchDefaults.ets, then
devecocli build && devecocli run --module entry meowjre --device <serial>
```
gson is fetched from Maven Central with the published `.sha1` verified (or pass `--gson FILE` / `--offline`).

## Clean-room discipline
We studied the historical upstream launcher only for its **behavior/contract**; the sources here are an
independent implementation (own names, structure, expression). Interoperability facts kept:
the two host-fixed class names/signatures, Mojang JSON keys, and the launcher's system properties.

## Not done (deliberately)
- No native extraction (not needed for MC 1.17–1.21.x).
- No `Server_Ip` quick-connect (drops the GPL dependency).
- No macOS/eawt block; cacio probe is benign/optional.
