# Third-Party Notices

Harmomeow Craft Launcher bundles and/or depends on the third-party components
listed below. Each is used under its own license; the **full license text of every
component is in [`entry/src/main/resources/rawfile/licenses/`](entry/src/main/resources/rawfile/licenses/)**, one self-contained file per component
(verbatim license text plus that component's upstream and copyright line). This
file is the authoritative attribution / notice list required by those licenses.

Where a component has been **modified or self-built** from upstream, that is stated
so the "changed files" / "modified version" disclosure required by the relevant
license is satisfied. Copyleft components (GPL / LGPL) additionally have a written
source offer in [`SOURCE-OFFER.md`](SOURCE-OFFER.md).

## 1. Bundled components (shipped inside the HAP / HSP)

| Component | Version | License (SPDX) | Key redistribution obligations | License text | Bundled |
|---|---|---|---|---|---|
| OpenJDK JRE (`meowjre`) | 26.0.2.1 | `GPL-2.0-only WITH Classpath-exception-2.0` | Copyleft; **modified binaries require the corresponding source** (SOURCE-OFFER); the Classpath Exception lets our own code be MIT and link the JRE. JRE `legal/` dir not shipped. | [`entry/src/main/resources/rawfile/licenses/OpenJDK-JRE-GPL-2.0-with-Classpath-Exception.txt`](entry/src/main/resources/rawfile/licenses/OpenJDK-JRE-GPL-2.0-with-Classpath-Exception.txt) | Yes |
| OpenJDK 8 JRE (`meowjrelegacy`, Eclipse Adoptium Temurin) | 8u504-b01 (`1.8.0_504`) | `GPL-2.0-only WITH Classpath-exception-2.0` | Same as above. JRE `legal/` dir not shipped. | [`entry/src/main/resources/rawfile/licenses/OpenJDK-Temurin-JRE-GPL-2.0-with-Classpath-Exception.txt`](entry/src/main/resources/rawfile/licenses/OpenJDK-Temurin-JRE-GPL-2.0-with-Classpath-Exception.txt) | Yes |
| LWJGL (modern) | 3.4.3 | `BSD-3-Clause` | Keep the copyright notice, conditions and disclaimer; reproduce them in binary docs; **no endorsement** by LWJGL. | [`entry/src/main/resources/rawfile/licenses/LWJGL3-BSD-3-Clause.txt`](entry/src/main/resources/rawfile/licenses/LWJGL3-BSD-3-Clause.txt) | Yes |
| LWJGL (legacy, `liblwjgl.so`) | 2.9.3 | `BSD-3-Clause` | Same (LWJGL2 copyright line). | [`entry/src/main/resources/rawfile/licenses/LWJGL2-BSD-3-Clause.txt`](entry/src/main/resources/rawfile/licenses/LWJGL2-BSD-3-Clause.txt) | Yes |
| libffi (static in `liblwjgl_343.so`) | 3.8.0 | `MIT` | Keep the copyright + permission notice. | [`entry/src/main/resources/rawfile/licenses/libffi-MIT.txt`](entry/src/main/resources/rawfile/licenses/libffi-MIT.txt) | Yes |
| stb / stb_image (static in `liblwjgl_343_stb.so`) | stb_image 2.30 | `MIT` (dual MIT / Unlicense) | Keep the copyright + permission notice; we rely on the MIT alternative. | [`entry/src/main/resources/rawfile/licenses/stb-MIT.txt`](entry/src/main/resources/rawfile/licenses/stb-MIT.txt) | Yes |
| tinyfiledialogs (in `liblwjgl_tinyfd.so`) | (LWJGL tinyfd) | `Zlib` | Mark altered versions as such; do not remove/alter the notice. | [`entry/src/main/resources/rawfile/licenses/tinyfiledialogs-Zlib.txt`](entry/src/main/resources/rawfile/licenses/tinyfiledialogs-Zlib.txt) | Yes |
| VulkanMemoryAllocator / VMA (in `liblwjgl_vma.so`) | (LWJGL vma module) | `MIT` | Keep the copyright + permission notice. | [`entry/src/main/resources/rawfile/licenses/VulkanMemoryAllocator-MIT.txt`](entry/src/main/resources/rawfile/licenses/VulkanMemoryAllocator-MIT.txt) | Yes |
| gl4es | 1.1.7 | `MIT` | Keep the copyright + permission notice. | [`entry/src/main/resources/rawfile/licenses/gl4es-MIT.txt`](entry/src/main/resources/rawfile/licenses/gl4es-MIT.txt) | Yes |
| OpenAL Soft | 1.24.3 | `LGPL-2.0-or-later` | Copyleft (library): keep the license; because it is a **separate, dynamically-linked `.so`** users may relink it; **corresponding source provided** (SOURCE-OFFER). Do not present as the original. | [`…/licenses/OpenAL-Soft-LGPL-2.0-or-later.txt`](entry/src/main/resources/rawfile/licenses/OpenAL-Soft-LGPL-2.0-or-later.txt) (full LGPL v2) + [`…/licenses/OpenAL-Soft-dynamic-linking-notice.txt`](entry/src/main/resources/rawfile/licenses/OpenAL-Soft-dynamic-linking-notice.txt) (relink / dynamic-linking notice) | Yes |
| fmt (static in `libopenal.so`) | 11.2.0 | `MIT` | Keep the copyright + permission notice. | [`entry/src/main/resources/rawfile/licenses/fmt-MIT.txt`](entry/src/main/resources/rawfile/licenses/fmt-MIT.txt) | Yes |
| Guidelines Support Library / GSL (static in `libopenal.so`) | (OpenAL-bundled) | `MIT` | Keep the copyright + permission notice. | [`entry/src/main/resources/rawfile/licenses/gsl-MIT.txt`](entry/src/main/resources/rawfile/licenses/gsl-MIT.txt) | Yes |
| PFFFT (modified; static in `libopenal.so`) | (OpenAL-bundled) | `BSD-3-Clause` | Keep copyright/conditions/disclaimer; **no endorsement** by NCAR/UCAR. | [`entry/src/main/resources/rawfile/licenses/pffft-BSD-3-Clause.txt`](entry/src/main/resources/rawfile/licenses/pffft-BSD-3-Clause.txt) | Yes |
| SADIE II HRTF dataset (default HRTF in `libopenal.so`) | (OpenAL-bundled) | `Apache-2.0` | Give a copy of the license; keep attribution; state changes; reproduce any NOTICE (none ships upstream). | [`entry/src/main/resources/rawfile/licenses/SADIE-II-HRTF-Apache-2.0.txt`](entry/src/main/resources/rawfile/licenses/SADIE-II-HRTF-Apache-2.0.txt) | Yes |
| Spherical-Harmonic-Transform portions (in `libopenal.so`) | (OpenAL-bundled) | `BSD-3-Clause` | Keep copyright/conditions/disclaimer; **no endorsement**. | [`entry/src/main/resources/rawfile/licenses/Spherical-Harmonic-Transform-BSD-3-Clause.txt`](entry/src/main/resources/rawfile/licenses/Spherical-Harmonic-Transform-BSD-3-Clause.txt) | Yes |
| FreeType | 2.13.3 | `FTL` (this project uses the FTL branch of FreeType's FTL/GPLv2 dual license) | Keep the FTL; **binary credit required**: "based in part on the work of the FreeType Team"; no commercial use of the other's name. | [`…/licenses/FreeType-FTL.txt`](entry/src/main/resources/rawfile/licenses/FreeType-FTL.txt) (FTL — the license actually used) + [`…/licenses/FreeType-GPLv2.txt`](entry/src/main/resources/rawfile/licenses/FreeType-GPLv2.txt) (the GPLv2 alternative, for the dual-license disclosure only) | Yes |
| SDL3 (this project's fork) | `release-3.4.14` | `Zlib` | This is an **altered** version: state that clearly; do not represent it as the original SDL; no endorsement by the SDL authors. | [`entry/src/main/resources/rawfile/licenses/SDL3-Zlib.txt`](entry/src/main/resources/rawfile/licenses/SDL3-Zlib.txt) | Yes |
| shaderc | commit `2c8cae77` | `Apache-2.0` | Give a copy of the license; state significant changes; keep attribution; reproduce any NOTICE (none ships upstream). | [`entry/src/main/resources/rawfile/licenses/shaderc-Apache-2.0.txt`](entry/src/main/resources/rawfile/licenses/shaderc-Apache-2.0.txt) | Yes |
| glslang (static in `libshaderc.so`) | 16.4.0 (commit `168d452a`) | multi: `BSD-3-Clause AND BSD-2-Clause AND MIT AND Apache-2.0 AND GPL-3.0-or-later WITH Bison-exception-2.2` | Keep each applicable notice; reproduce them in binary docs; state significant changes. The **GPL-3.0 text with the Bison exception** (the license of the bison-generated parser-skeleton fragment inside glslang) is reproduced **in full inside `glslang-multi-license.txt`**; Apache-2.0 §4 NOTICE: **upstream provides no NOTICE file**. | [`…/licenses/glslang-multi-license.txt`](entry/src/main/resources/rawfile/licenses/glslang-multi-license.txt) | Yes |
| SPIRV-Tools (static in `libshaderc.so`) | commit `b707790a` | `Apache-2.0` | Give a copy of the license; state significant changes; keep attribution; reproduce any NOTICE (**upstream provides no NOTICE file**). | [`entry/src/main/resources/rawfile/licenses/SPIRV-Tools-Apache-2.0.txt`](entry/src/main/resources/rawfile/licenses/SPIRV-Tools-Apache-2.0.txt) | Yes |
| SPIRV-Headers (static in `libshaderc.so`) | commit `29981f65` | `MIT AND CC-BY-4.0` | Keep the copyright + permission notice (some spec files are CC-BY-4.0). | [`entry/src/main/resources/rawfile/licenses/SPIRV-Headers-MIT-CC-BY-4.0.txt`](entry/src/main/resources/rawfile/licenses/SPIRV-Headers-MIT-CC-BY-4.0.txt) | Yes |
| SPIRV-Cross | commit `6c09849f` | `Apache-2.0` | Give a copy of the license; state significant changes; keep attribution; reproduce any NOTICE (**upstream provides no NOTICE file**). | [`entry/src/main/resources/rawfile/licenses/SPIRV-Cross-Apache-2.0.txt`](entry/src/main/resources/rawfile/licenses/SPIRV-Cross-Apache-2.0.txt) | Yes |
| OSHI (`oshi-core-*-meow.jar`) | 5.7.4 / 5.7.5 / 5.8.2 / 5.8.5 / 6.2.2 / 6.4.5 / 6.4.10 / 6.6.5 / 6.9.0, and legacy 1.1 | `MIT` | Keep the copyright + permission notice. | [`entry/src/main/resources/rawfile/licenses/oshi-MIT.txt`](entry/src/main/resources/rawfile/licenses/oshi-MIT.txt) | Yes |
| OW2 ASM (`asm`, `asm-analysis`, `asm-commons`, `asm-tree`, `asm-util`) | 9.9.1 | `BSD-3-Clause` | Keep INRIA/France Telecom copyright + conditions + disclaimer; reproduce in binary docs; **no endorsement** by INRIA / France Telecom / OW2. | [`entry/src/main/resources/rawfile/licenses/ASM-BSD-3-Clause.txt`](entry/src/main/resources/rawfile/licenses/ASM-BSD-3-Clause.txt) | Yes |
| LLVM libc++ (`libc++_shared.so`) | (OHOS NDK) | `Apache-2.0 WITH LLVM-exception` | Give a copy of the license; keep attribution (the **LLVM exception** text is included in full at the end of the file; it relaxes Apache-2.0 4(a)/4(b)/4(d) for embedded object code); Apache-2.0 §4 NOTICE: **upstream provides no NOTICE file**. | [`…/licenses/libcxx-Apache-2.0-LLVM-exception.txt`](entry/src/main/resources/rawfile/licenses/libcxx-Apache-2.0-LLVM-exception.txt) | Yes (toolchain-injected) |

### 1a. Notes on specific bundled components

* **OpenJDK JRE (both runtimes).** Bundled as `libs/meowjre/libs/arm64-v8a/*.so`
  (29 libs) + `entry/src/main/resources/rawfile/meow_jre.tar.gz`, and
  `libs/meowjrelegacy/libs/arm64-v8a/*.so` (25 libs) +
  `entry/src/main/resources/rawfile/meow_jre_legacy.tar.gz`. We **modify** both:
  the official libraries are binary-patched in place (ELF `.dynstr` NEEDED rewrite);
  `libc6.so`, `libjli.so` and `libjvm.so` are self-built from OpenJDK source. The
  exact source + rebuild recipes are the subject of [`SOURCE-OFFER.md`](SOURCE-OFFER.md).
  Bundled `jni.h` / `jni_md.h` (`libs/meowcraftlib/src/main/cpp/meowcraftbridge/`)
  are copied from OpenJDK and are under the same GPL-2.0-with-Classpath-Exception terms.
* **LWJGL.** The jar `lwjgl-3.4.3.jar` and the five ASM jars live in
  `entry/src/main/resources/rawfile/meowcraft_extras.tar.gz`; the natives live in
  `libs/meowlwjgls/libs/arm64-v8a/`. The jar is upstream modules plus this project's
  clean-room overlay (GLFW binding / `GLCapabilities` / `RendererInit`); the overlay
  is a derivative of LWJGL and stays BSD-3-Clause.
* **OSHI.** The ten patched jars are in
  `entry/src/main/resources/rawfile/oshi-overrides/` (`oshi-core-<v>-meow.jar`); the
  change is a CPU-topology synthesis patch so `/proc/cpuinfo` is not required.
* **FreeType.** FreeType is dual-licensed (FTL or GPLv2). **This project relies on
  the FTL** and distributes FreeType under the FTL. Both texts are shipped for a
  complete dual-license disclosure: `FreeType-FTL.txt` (the FTL, which quotes
  the required credit line) and `FreeType-GPLv2.txt` (the GPLv2 alternative,
  disclosure only).
* **OpenAL Soft.** Shipped only as a separate, dynamically-linked `libopenal.so`
  (never statically linked). The short `OpenAL-Soft-dynamic-linking-notice.txt`
  documents that dynamic linkage / relinkability (LGPL §6) and points to
  `SOURCE-OFFER.md`; the full LGPL v2 text is in
  `OpenAL-Soft-LGPL-2.0-or-later.txt`.
* **Apache-2.0 components** (shaderc, glslang, SPIRV-Tools, SPIRV-Cross, SADIE II,
  and LLVM libc++). The full Apache-2.0 text is shipped for each (embedded in that
  component's file; `libcxx-…` additionally carries the LLVM exception verbatim).
  Apache-2.0 §4(d) only requires reproducing a NOTICE file when the upstream Work
  ships one — **none of these upstreams provides a NOTICE file**, so none is
  reproduced here. (SPIRV-Headers, also bundled, is `MIT AND CC-BY-4.0`, not
  Apache-2.0.)
* **SDL3 / gl4es / OpenAL Soft / shaderc.** These are self-built forks/ports; the
  "changed files" disclosure required by Zlib §2, the LGPL, and Apache-2.0 §4 is
  satisfied by the "Our use" line and the source offer/recipe links.

## 2. Build-time only — not distributed

These are used to build/verify our artifacts or are platform components; they are
**not** redistributed as part of this application.

| Component | Version | License (SPDX) | Why / where used | Bundled |
|---|---|---|---|---|
| gson | 2.13.1 | `Apache-2.0` | Declared and downloaded per-instance by Minecraft / Fabric / Forge at runtime; not shipped by us. | No |
| JNA / jna-platform | — | `LGPL-2.1` / `Apache-2.0` | Compile classpath for the OSHI build only. | No |
| slf4j-api | — | `MIT` | Compile classpath for the OSHI build only. | No |
| AndroidX / AOSP `android/util/*` | — | `Apache-2.0` | Historical vendored code, since removed. | No |
| OpenHarmony SDK / NDK, `libGLv4` / `libEGL` (Mesa Zink), `libhilog_ndk`, `libace_napi`, `librawfile`, `libz`, `libnative_window*` | — | platform licenses | Platform / toolchain capabilities, not application assets. | No |

## 3. Source code offer (GPL / LGPL components)

The copyleft components above — **OpenJDK 26 JRE, OpenJDK 8 JRE (Temurin), OpenAL
Soft, and glslang** (the latter's bison parser-skeleton fragment, `GPL-3.0 WITH
Bison-exception-2.2`) — require the corresponding source of the (modified)
binaries we distribute. That written offer, with the exact upstream tags/commits
and our build recipes, is in [`SOURCE-OFFER.md`](SOURCE-OFFER.md).

## 4. Provenance

Per-artifact provenance (names, versions, tags/commits, digests, download URLs and
whether each item is bundled) is recorded under
[`../notes/30-supply-chain/`](../notes/30-supply-chain/) (`provenance-master.md`,
`per-so-catalog.md`, `assets-digests.txt`).

---

## Marker

If you believe a component is missing, or a notice is inaccurate, please open an
issue. This file is intended to be complete; when in doubt, the upstream license
text in [`entry/src/main/resources/rawfile/licenses/`](entry/src/main/resources/rawfile/licenses/) governs.
