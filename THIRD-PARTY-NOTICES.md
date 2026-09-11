# Third-Party Notices

This project (Harmomeow Craft Launcher) bundles and/or depends on the
third-party components listed below. Each is used under its own license; the
full license texts are in [`LICENSES/`](LICENSES/). This file is the
authoritative attribution/notice list required by those licenses.

Where a component has been **modified or self-built** from upstream by this
project, that is stated so the "changed files"/"modified version" disclosure
required by the relevant licenses is satisfied.

---

## 1. OpenJDK / Java Runtime Environment (JRE 25)

* Bundled as: `libs/meowjre25/libs/arm64-v8a/*.so` (30 libraries, incl.
  `libjvm.so`, `libjli.so`) and the runtime data image
  `entry/src/main/resources/rawfile/meow_jre25.tar.gz`
  (`bin/`, `conf/`, `lib/modules`, …), plus `legal/`-derived font data.
* Upstream: OpenJDK 25 (aarch64, musl) — OpenHarmony port. The bundled build
  reports `JAVA_RUNTIME_VERSION=25.0.1-internal-adhoc...` and source commit
  `78770bfaefd2`.
* License: **GPL-2.0-only WITH Classpath-Exception** — [`LICENSES/GPL-2.0-with-Classpath-Exception.txt`](LICENSES/GPL-2.0-with-Classpath-Exception.txt)
  and [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt).
* Modification: the data image was slimmed by `tools/slim_jre_data.py`
  (removed redundant `.so` copies). NOTE: this removed the JRE's own `legal/`
  directory; the required license notices are provided here instead.
* **The Classpath Exception permits this project's own code to be licensed
  differently (MIT) and linked against the JRE.** Redistribution of the JRE
  binary requires the corresponding source — see [`SOURCE-OFFER.md`](SOURCE-OFFER.md).
* Bundled fonts may be subject to the Oracle Lucida font license where present.

Bundled **`jni.h` / `jni_md.h`** (`libs/meowcraftlib/src/main/cpp/meowcraftbridge/`)
are copied from OpenJDK and are under the same GPL-2.0+Classpath-Exception terms.

## 2. OpenAL Soft  (`libopenal.so`)

* Version: OpenAL Soft 1.24.3 (self-built for OHOS).
* License: **LGPL-2.0-or-later** — [`LICENSES/LGPL-2.0.txt`](LICENSES/LGPL-2.0.txt).
* Modification: OHOS port + a new **OHAudio** backend + OpenSL fixes, and
  export of `ALC_SOFT_system_events`. Source: `tools/openal/` (patches and
  `ohaudio/ohaudio.{cpp,h}`).
* Dynamic linking only (separate `libopenal.so`). The complete corresponding
  source of the modified library, plus our build recipe, is available — see
  [`SOURCE-OFFER.md`](SOURCE-OFFER.md). Users may replace/relink the library.
* Embedded third-party inside OpenAL Soft: fmt, gsl (**MIT**), pffft
  (**BSD**, [`LICENSES/LICENSE-pffft`](LICENSES/LICENSE-pffft)), SADIE II HRTF
  data (**Apache-2.0**).

## 3. FreeType  (`libfreetype.so`)

* Version: FreeType 2.13.3 (self-built, "zlib only").
* License: **FreeType License (FTL)** (chosen branch) — [`LICENSES/FTL.txt`](LICENSES/FTL.txt).
* Required credit (FTL advertising clause): *Portions of this software are
  copyright © 1996-2024 The FreeType Project (https://www.freetype.org).
  All rights reserved.*

## 4. LWJGL

* `libs/meowlwjgl3/libs/arm64-v8a/liblwjgl{,_opengl,_stb}_{333,343}.so`,
  `liblwjgl_tinyfd.so`, and the legacy `liblwjgl.so` (LWJGL **2.9.3**
  `@2df01dd7`) — self-built from upstream source.
* `lwjgl-3.3.3.jar` / `lwjgl-3.4.3.jar` (inside `meowcraft_extras.tar.gz`) —
  upstream Maven modules plus this project's **clean-room overlay** (replacing
  the GLFW binding / `GLCapabilities` / `RendererInit`); the overlay files are
  derivatives of LWJGL and remain BSD-3-Clause.
* License: **BSD-3-Clause** — [`LICENSES/BSD-3-Clause.txt`](LICENSES/BSD-3-Clause.txt).
* `liblwjgl_343.so` statically links **libffi 3.8.0** (MIT, see §7).
* `liblwjgl_stb_*.so` link **stb** (public domain / MIT).
* `liblwjgl_tinyfd.so` links **tinyfiledialogs** (Zlib).
* Files have been **modified** (OHOS build configuration, GLFW overlay, LWJGL2
  generator bypass patch). Copyright notices retained.

## 5. SDL3  (`libSDL3.so`)

* Version: SDL3 `release-3.4.14` + this project's custom **`ohos`** video /
  mouse / EGL driver (`tools/sdl/src/video/ohos/`) — a **modified fork**.
* License: **Zlib** — [`LICENSES/Zlib.txt`](LICENSES/Zlib.txt).
* Per Zlib §3: this is an **altered** version; it must not be represented as
  the original SDL, and the upstream authors do not endorse this project.

## 6. shaderc / SPIRV-Cross / SPIRV-Tools / SPIRV-Headers / glslang

* `libshaderc.so` (google/shaderc `2c8cae7`, glslang/SPIRV-Tools/SPIRV-Headers
  statically linked) and `libspirv-cross.so` (SPIRV-Cross `6c09849`).
* License: **Apache-2.0** (SPIRV-Headers and parts of glslang are Khronos/
  MIT-style; glslang also carries BSD-3) — [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt).
* Self-built (revisions pinned to those LWJGL 3.4.3's official natives used).
* Apache-2.0 §4: the upstream `NOTICE` files (where present) must be preserved;
  these libraries are unmodified except for the OHOS build configuration.

## 7. gl4es / libffi / oshi / gson

* **gl4es** v1.1.7 — **MIT** ([`LICENSES/MIT.txt`](LICENSES/MIT.txt));
  self-built for OHOS (`libgl4es.so`).
* **libffi** 3.8.0 — **MIT**; statically linked into `liblwjgl_343.so`.
* **oshi** 5.7.4 / 5.7.5 / 5.8.2 / 5.8.5 / 6.2.2 / 6.4.5 / 6.4.10 / 6.6.5 /
  6.9.0 and legacy 1.1 (`4047d5be65`) — **MIT**; patched
  (`oshi-overrides/oshi-core-*-meow.jar`, `tools/oshi/`).
* **gson** 2.13.1 — **Apache-2.0**; bundled as
  `gson-for-launcher.jar`, **relocated (`com.google.gson` → `meow.gson`)** =
  modified; Apache-2.0 requires preserving the license/notice and stating the
  change.

## 8. Build-time / toolchain (not redistributed as separate files)

* `libc++_shared.so` — LLVM libc++ (**Apache-2.0 WITH LLVM-exception**);
  injected by the OHOS NDK toolchain at build time.

---

## Marker

If you believe a component is missing, or a notice is inaccurate, please open
an issue. This file is intended to be complete; when in doubt, the upstream
license text in [`LICENSES/`](LICENSES/) governs.
