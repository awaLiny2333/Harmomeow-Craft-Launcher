# tools/lwjgl — self-build the LWJGL jar + natives for HarmonyOS (one modern generation)

Builds, from source, every LWJGL artifact we ship: the fat `lwjgl-3.4.3.jar` (the
**single** modern generation — its overlay carries *3.4.x compat shims* so it also serves
MC 1.13–1.21.x), the 3.4.3 natives, the `libffi.a` the 3.4.x core links, and the
`meowcraft_extras.tar.gz` bundle. Everything is path-parameterized and reproducible
(same tag + SDK + build path → byte-identical; see digests below).

| artifact | shipped as | recipe |
|---|---|---|
| `lwjgl-3.4.3.jar` (fat merge + the 3.4.x compat shims) | `entry/.../rawfile/meowcraft_extras.tar.gz` member | `build_lwjgl_jar.sh` (+ `pack_extras.py` to assemble the bundle) |
| `liblwjgl_343.so` / `liblwjgl_343_opengl.so` / `liblwjgl_343_stb.so` (3.4.3) | `libs/meowlwjgls/libs/arm64-v8a/` | `rebuild_for_meowcraft.sh` → `install_natives.sh` |
| `libffi.a` (3.8.0) | build input only | `build_libffi.sh` |

> `libmeowcraftbridge.so` (our GLFW/input/render bridge) is **separate** — it supplies
> every `nglfwXXX` symbol, so there is deliberately **no `liblwjgl_glfw.so`**.

## 0. Sources & how to obtain them

```sh
# LWJGL source (all tags; HEAD is a dev tree, always pick a tag)
git clone https://github.com/LWJGL/lwjgl3.git ref/lwjgl3
git -C ref/lwjgl3 worktree add --detach ref/lwjgl3-3.4.3 3.4.3     # 3.4.x source tree

# libffi source (3.8.0) for the 3.4.x core native
curl -sL -o stuffs/research/libffi/libffi-3.8.0.tar.gz \
  https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz
tar -C stuffs/research/libffi -xzf stuffs/research/libffi/libffi-3.8.0.tar.gz
```
The stock LWJGL module jars (Maven Central `org.lwjgl:<mod>:<ver>`), `jsr305` and
`org.jspecify:jspecify` are fetched automatically by `build_lwjgl_jar.sh` (with the
published `.sha1` verified) into `<work>/m2`.

## 1. The jar recipe — the "overlay" mechanism (read this first)

### 1.1 Why an overlay exists

Official LWJGL's `org.lwjgl.glfw.GLFW` is a thin JNI binding: it loads a real native
**GLFW** library and forwards calls to it. We ship **no native GLFW** — instead we have our own
bridge `libmeowcraftbridge.so` (GLFW semantics implemented on HarmonyOS APIs). So we **replace**
LWJGL's GLFW-side classes with our own implementations that load/call our bridge, and (for
`GLCapabilities` / `RendererInit`) drive GL context + function-slot loading ourselves.

The result is a **fat jar** that is the sole source of `org.lwjgl.*` (the ArkTS classpath
excludes MC's own `org/lwjgl/**`):

```
official LWJGL <ver> modules (Maven, sha1-verified)   <-- stock base: the bulk, untouched
      +
clean-room overlay source (this repo; we compile)     <-- our replacements
      => merge, OVERLAY WINS on name collisions
      => strip META-INF/* (keep MANIFEST) + net/java/openjdk/cacio/** + android/**
```

It is **not** "all compiled from source": the bulk stock Java is upstream; only the overlay
classes (and the natives) are ours.

### 1.2 The build pipeline (5 stages) and the two rules that matter

```
  --overlay deltas/overlay              (1) STAGE    cp -R in order into scratch overlay/
  --overlay deltas/overlay-<gen>                     -> a later --overlay OVERWRITES an earlier
        |                                               (rule A: "later wins")
        v
  scratch overlay/*.java --javac--> scratch classes/*.class        (2) COMPILE
        |                                 |  cp = the merged module jars (12 for 3.4.x) + jsr305 + jspecify
        |                                 |
  official module jars (12 for 3.4.x) --unzip--> merge/  <-- copy org/** classes    (3) MERGE
        |                                          (4) strip META-INF/cacio/android
        |                                          (rule B: overlay classes copied LAST and
        |                                                   only under org/** => they win)
        v
  merge/ --deterministic pack--> lwjgl-<ver>.jar                   (4) PACK
        |                                                          (5) SANITY: must-have classes,
        v                                                              no android/util, GLFW
                                                                       libname == meowcraftbridge
```

- **Rule A (stage, "later wins")** — pass layers in order: **common first, generation last**.
- **Rule B (merge, "overlay wins")** — overlay classes are copied over the official ones, and
  **only `org/**` overlay classes are merged** (the script runs `find org -name '*.class'`), so
  every overlay source file MUST live under `org/...`.
- **Guard** — if `deltas/overlay-<VERSION>` exists but was not passed, `build_lwjgl_jar.sh`
  **errors out** (you can never silently ship a jar whose version-pinned files are missing or
  taken from the wrong generation).

### 1.3 The two layers — and how to tell which file goes where

The split test is one question: **is this file pinned to a specific LWJGL version?**

| layer | dir | n | files | why it is here |
|---|---|---|---|---|
| **common** | `deltas/overlay/` | 13 | `glfw/{CallbackBridge, Callbacks, GLFWWindowProperties, GLFWNative{Cocoa,EGL,NSGL,OSMesa,WGL,Wayland,Win32,X11}}`, `opengl/RendererInit`, `system/MeowBundledNameMapper` | **version-agnostic**: they forward to our bridge, use reflection, or are platform stubs — one copy is correct for every generation |
| **per-generation** | `deltas/overlay-3.4.3/` | 7 | `opengl/GLCapabilities.java`, `glfw/GLFW.java`, **+ the 5 3.4.x compat shims** (`glfw/GLFWImage`, `stb/{STBIIOCallbacks,STBVorbisInfo,STBImageResize}`, `util/tinyfd/TinyFileDialogs`) | **version-pinned** — the two generated files pin the API/slot contract, the 5 shims back-port members 3.4.x removed (see §1.5) |

```
deltas/
├── overlay/                 # common (13) — needed regardless of generation
│   ├── org/lwjgl/glfw/      CallbackBridge  Callbacks  GLFWWindowProperties  GLFWNative*
│   ├── org/lwjgl/opengl/    RendererInit
│   └── org/lwjgl/system/    MeowBundledNameMapper
└── overlay-3.4.3/           # version-pinned (7): the 2 generated files + the 5 compat shims
    └── org/lwjgl/{opengl/GLCapabilities.java, glfw/GLFW.java, glfw/GLFWImage.java,
                   stb/{STBIIOCallbacks,STBVorbisInfo,STBImageResize}.java,
                   util/tinyfd/TinyFileDialogs.java}
# overlay-3.3.3/ was RETIRED on 2026-09-14 (single modern generation).
```

Why those two are version-pinned:
- **`glfw/GLFW.java`** — the GLFW **public API surface MC links against**; it differs per minor
  version (3.4.x adds the IME/preedit methods, etc.), so each generation has its own.
- **`opengl/GLCapabilities.java`** — its **field order is the C-side address-slot contract**:
  every `Java_org_lwjgl_opengl_*` native reads its function pointer via `tlsGetFunction(index)`,
  where `index` is the slot filled in Java declaration order (3.3.3 → **2228** slots,
  3.4.3 → **2270**). It MUST match the LWJGL version the natives were built from, or the
  pointers shift. It is **generated, never hand-edited**:

  ```sh
  python3 tools/lwjgl/gen_glcap.py <official GLCapabilities.java> <out>
  ```
  our **four** deterministic edits (inject `RendererInit.onCreateCapabilities`, drop the
  `if(!ext.contains(...)) return false;` guards, de-short-circuit `||`/`&&`, and neutralise the
  pure-logging `reportMissing("GL","…")` → `false` — without the last one the de-short-circuit makes
  LWJGL log `[GL] … an entry point is missing` for **every** probe); it reproduces the
  shipped 3.3.3/3.4.3 overlay **byte-for-byte** from the official file.

The 3.4.x `GLFW.java` adds the three 3.4.x IME/preedit methods MC ≥ 1.22 calls
(`glfwSetPreeditCallback`, `glfwSetIMEStatusCallback`, `glfwSetPreeditCursorRectangle`),
implemented in Java only (bridge unchanged; preedit is register-only/no-op).

### 1.4 Adding a generation (checklist)

1. `deltas/overlay-<newver>/org/lwjgl/{opengl/GLCapabilities.java, glfw/GLFW.java}` — generate the
   caps with `gen_glcap.py`; start `GLFW.java` from the previous generation's and diff the API.
2. Build: `--overlay deltas/overlay --overlay deltas/overlay-<newver>` (the guard enforces it).
3. Natives: `rebuild_for_meowcraft.sh <newver>` → `liblwjgl*_<digits>.so` + a `natives.manifest` entry.
4. Pack: add `lwjgl-<newver>.jar` (`pack_extras.py --jar … --require …`).
5. Runtime: add a `LWJGL_GEN_TABLE` row in `MinecraftLauncher.ets` (threshold = that gen's lwjgl
   version); add the jar name to `LaunchDefaults.LWJGL_GEN_JARS`; bump `EXTRAS_VERSION`,
   rebuild/deploy.
   - `LWJGL_GEN_JARS` is the single source for "which jars are ours" used by
     `ClasspathStager.dropOtherLwjglJar` (keep exactly one generation) and the classpath-shape
     guard (`lwjglClasspathOk`). Forgetting it makes the guard abort (or, worse, keeps two
     providers → `sealing violation`).

## 1.5 The 3.4.x compat shims (why ONE generation can serve 1.13–1.21.x)

Since 2026-09-14 we ship a **single** modern generation (3.4.3) and run *every* modern MC
on it. MC 1.13.2–1.21.11 was compiled against older LWJGLs and statically links a handful
of members that 3.4.x **removed**. `mc_lwjgl_compat_check.py` (member-level,
inheritance-aware) yields the exact gap — currently **5 members, 0 classes**:

| removed in 3.4.x | used by | shim (in `deltas/overlay-3.4.3/`) |
|---|---|---|
| `glfw.GLFWImage.mallocStack(int, MemoryStack)` | 1.13.2–1.18.2 | re-added statics (delegate to `malloc`) |
| `stb.STBIIOCallbacks.mallocStack(MemoryStack)` | 1.13.2–1.18.2 | idem |
| `stb.STBVorbisInfo.mallocStack(MemoryStack)` | 1.14.4–1.19.4 | idem |
| `stb.STBImageResize.nstbir_resize_uint8(JIIIJIIII)I` | 1.13.2–**1.21.11** | re-expressed on `nstbir_resize_uint8_linear` (resize2); v1 `num_channels` → resize2 layout with no alpha |
| `util.tinyfd.TinyFileDialogs.tinyfd_messageBox(CS,CS,CS,CS,Z)Z` | 1.16.5–1.21.11 | boolean overload delegating to the new `(…,I)I` |

Re-run the check whenever a new MC version is added (its output IS the shim surface;
validated: against the generation a version declares it reports 0):

```sh
python3 tools/lwjgl/mc_lwjgl_compat_check.py \
  --jar stuffs/research/lwjgl_build-3.4.3/out/lwjgl.jar \
  <path/to/.minecraft>/versions/<v>/<v>.jar ...
```

The shims are **version-pinned** exactly like `GLCapabilities` — if a *new* generation is
ever added, carry the still-needed ones into its overlay.

## 2. Build the generation

```sh
SDK=${OHOS_SDK_NATIVE:-$HOME/devecow/deveco_tools/sdk/default/openharmony}

# --- 3.4.3 (the ONLY modern generation: serves MC 1.13–1.21.x AND >= 1.22) ---
sh tools/lwjgl/build_libffi.sh --src stuffs/research/libffi/libffi-3.8.0 \
    --sdk-native $SDK/native --out stuffs/research/libffi/out-ohos
sh tools/lwjgl/build_lwjgl_jar.sh --version 3.4.3 \
    --overlay tools/lwjgl/deltas/overlay --overlay tools/lwjgl/deltas/overlay-3.4.3
    # -> stuffs/research/lwjgl_build-3.4.3/out/lwjgl.jar   (javac; you run it)
sh tools/lwjgl/rebuild_for_meowcraft.sh 3.4.3        # build + install -> liblwjgl_343{,_opengl,_stb}.so (+ manifest)
```

### Naming & the flat directory (why `libs/arm64-v8a/` must stay flat)

- hvigor packages **only top-level `libs/<abi>/*.so`** — subdirectories are silently
  dropped, so per-generation subfolders are impossible. Every MC version is served by ONE
  JRE HSP whose namespace must hold all generations side by side -> same base name -> a
  **generation tag right after the base name** disambiguates: 3.4.3 -> `liblwjgl_343.so` /
  `liblwjgl_343_opengl.so` / `liblwjgl_343_stb.so` (must stay in lockstep with
  `MeowBundledNameMapper`, the Java side that decides what LWJGL looks for).
- Natives must be **co-packaged** (fs-verity: runtime-written files fail `dlopen`).
- **`liblwjgl_tinyfd.so` is generation-agnostic** (no suffix): MC ≥ 1.22's
  `NativeLibrariesBootstrap` eagerly loads `org.lwjgl.util.tinyfd` at boot (fail-fast), and
  `MeowBundledNameMapper` passes `lwjgl_tinyfd` through unchanged. It is built by
  `build_lwjgl_natives.sh` (from `modules/lwjgl/tinyfd`'s `tinyfiledialogs.c` + generated JNI)
  and installed by `install_natives.sh` with a manifest line tagged `common`.
- **`libSDL3.so` is also generation-agnostic** (no suffix): MC ≥ 26.3 dropped GLFW and drives
  window/input/GL through SDL3 (`org.lwjgl.sdl`, LWJGL ≥ 3.4.x). It is a **local SDL3 fork** built by
  `tools/sdl/` (pin `release-3.4.14`, matching the official `libSDL3.so.git` that LWJGL 3.4.3 ships) and
  installed via `install_natives.sh --sdl <file>` (manifest tag `common`). `MeowBundledNameMapper` passes
  `SDL3` through unchanged, so the file keeps the plain name.
- **`libshaderc.so` / `libspirv-cross.so` are also generation-agnostic** (no suffix): MC ≥ 26.3's
  `renderpearl` loads `org.lwjgl.util.shaderc.Shaderc` → `libshaderc.so` and
  `org.lwjgl.util.spvc.Spvc` → `libspirv-cross.so` (LWJGL **direct bindings**). Built by `tools/shaderc/`
  (pinned to the exact upstream revisions LWJGL 3.4.3 used) and installed via
  `install_natives.sh --native libshaderc.so=<file>` / `--native libspirv-cross.so=<file>` (tag `common`).
- **Jar modules added automatically for LWJGL ≥ 3.4.x** (`build_lwjgl_jar.sh`): **`lwjgl-sdl`** (MC ≥ 26.3)
  and **`lwjgl-vma lwjgl-spvc lwjgl-shaderc`** (renderpearl). The `sdl` *native* is our `libSDL3.so`
  above — **not** the Maven `lwjgl-sdl-*-natives` jar.
- `tools/lwjgl/install_natives.sh` owns this directory: it copies a generation's build
  output in under the suffix and records `libs/meowlwjgls/libs/natives.manifest`
  (`<tag>\t<file>\t<sha256>`); `--clean <tag>` / `--list` for lifecycle. **Never hand-edit.**
- At launch LWJGL resolves the suffix via `MeowBundledNameMapper`
  (`-Dmeow.lwjgl.gen=<tag>`, set for **every** generation).

### Generation mapping (nearest clamp — never selects an un-shipped generation)

`lwjglGeneration()` (ArkTS, `MinecraftLauncher.ets`) maps the version json's
`org.lwjgl:lwjgl:<ver>` to a shipped generation via an ordered table (`LWJGL_GEN_TABLE`):
the highest generation whose threshold ≤ the declared version; anything older/unknown
(incl. no such dependency) clamps to the oldest shipped generation. Every shipped
generation's jar + natives are always in the bundle, so the selection never points at an
absent artifact. A version that genuinely needs an API no shipped generation has fails
loudly at runtime (`NoSuchMethodError`) — the signal to add a generation
(build jar+overlay → `rebuild_for_meowcraft.sh <tag>` → `install_natives.sh <tag>`, then
add a `LWJGL_GEN_TABLE` row).

## 3. Assemble the extras bundle

```sh
python3 tools/lwjgl/pack_extras.py \
  --base-tar entry/src/main/resources/rawfile/meowcraft_extras.tar.gz \
  --drop-prefix lwjgl-natives- \
  --jar lwjgl-3.4.3.jar=stuffs/research/lwjgl_build-3.4.3/out/lwjgl.jar \
  --require lwjgl-3.4.3.jar \
  --out stuffs/research/meowcraft_extras.tar.gz
# pack_extras.py drops EVERY lwjgl jar the base tar carried before adding --jar, so a
# retired generation cannot linger in the bundle (it used to only drop the ancient
# `lwjgl.jar`).
sh tools/lwjgl/install_natives.sh --verify    # assert every manifest native is on disk
cp stuffs/research/meowcraft_extras.tar.gz entry/src/main/resources/rawfile/
# then bump EXTRAS_VERSION in entry/.../constants/LaunchDefaults.ets and rebuild/deploy.
```
`finalize_for_meowcraft.sh` (the old single-`lwjgl.jar` swapper) is **retired** —
`pack_extras.py` replaces it.

## 4. Artifacts & digests (jar/tar re-measured 2026-09-14; natives 2026-09-10)

| artifact | sha256 |
|---|---|
| `lwjgl-3.4.3.jar` (carries the 5 3.4.x compat shims) | `7783219a6011a115781ea7abc38fc5967db1c8a8fc294308973b717c865088bf` |
| `liblwjgl_343.so` / `liblwjgl_343_opengl.so` / `liblwjgl_343_stb.so` (3.4.3) | `16298280…` / `e1f1413b…` / `8eb4a1b8…` |
| `libffi.a` (3.8.0, aarch64-linux-ohos) | `238cadb7bfa70ca5b4f718cc66878f1f3d26107bc6f6b0e272380c3f3f1fda5b` |
| `meowcraft_extras.tar.gz` (shipped; single modern generation) | `b76f45f78a3af9bb279aa7e881a3d4794f65f2522fdef04204a93890ba8592eb` |

Reproducibility caveats (verified 2026-09-10):
- **Native builds are byte-reproducible only when the absolute `--src`/`--out` paths are
  identical** — the linker embeds the absolute output path in `.dynstr` (no SONAME/RPATH
  entry is emitted; functional impact none). The digests above correspond to
  `--out …/stuffs/research/lwjgl_natives-3.4.3/out` (and the 3.3.3 set dropped in
  `libs/meowlwjgls/libs/arm64-v8a`); a rebuild at a different path is functionally identical
  but has a different hash. Verified: **3× same-path rebuilds `cmp`-identical**.
- `lwjgl-<ver>.jar`: deterministic (`pack_jar.py` + pinned Maven inputs). The digests in the table are
  the current shipped jars (2026-09-14: single modern generation + 5 compat shims); the 3.4.3 jar also carries the MC 26.3
  `sdl/vma/spvc/shaderc` modules. **Verified 2026-09-10**: two same-`--work` rebuilds of the
  then-current 3.4.3 jar were `cmp`-identical and reproduced their digest; the 3.3.3 jar likewise
  reproduces across rebuilds.
- `libffi.a`: **3× same-path rebuilds `cmp`-identical and independent of the output path**
  (static archive) — verified equal to the shipped build input.
- hvigor **re-strips** packaged `.so`, so the **installed** hash differs from the source build.

## 5. Pitfalls

- `ref/lwjgl3` HEAD is a dev tree — always use an explicit tag / the `ref/lwjgl3-3.4.3` worktree.
- `GLCapabilities.java` must be regenerated to match the version the natives are built from
  (slot index contract, above).
- LWJGL 3.4.x needs `org.jspecify:jspecify` on the javac classpath (auto-fetched) and
  libffi **3.8.0** at native link time (the stock 3.4.4 lacks `ffi_call_plan_*`).
- `lwjgl-lwjglx` and `nanovg` are dropped (dead for MC ≥ 1.17; `--with-lwjglx` re-adds lwjglx). For
  LWJGL ≥ 3.4.x the `sdl`/`vma`/`spvc`/`shaderc` bindings **are** merged (MC ≥ 26.3's SDL3 +
  `renderpearl`); their natives ship separately (`libSDL3.so`, `libshaderc.so`, `libspirv-cross.so`).
- Fresh classes dir every build (stale-`.class` trap).
- After changing `libs/meowlwjgls/libs/arm64-v8a/`, **clean the module build** before
  `devecocli build --modules entry meowjre25` (hvigor does not track libs add/remove).

Full analysis: `notes/20-design/{lwjgl自编方案.md,lwjgl多版本并存方案.md}`,
`stuffs/research/lwjgl/REPRODUCE_CONTRACT_lwjgl_jar.md`.
