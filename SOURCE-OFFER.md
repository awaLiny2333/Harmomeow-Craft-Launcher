# Source Code Offer

This project bundles components under **copyleft** licenses that require the
distributor to make the corresponding source code available. This is that written
offer. It covers **every** copyleft (GPL / LGPL) component we distribute:

* **OpenJDK 26 JRE** — `GPL-2.0-only WITH Classpath-exception-2.0`
* **OpenJDK 8 JRE** (Eclipse Adoptium Temurin 8u504-b01) — `GPL-2.0-only WITH Classpath-exception-2.0`
* **OpenAL Soft 1.24.3** — `LGPL-2.0-or-later`
* **glslang** (the bison-generated parser-skeleton fragment inside `libshaderc.so`) —
  `GPL-3.0-or-later WITH Bison-exception-2.2`

The first three are **modified / partly self-built** by this project; glslang is used
unmodified. The locations below give the upstream source plus, where applicable, our
own modifications and rebuild recipes.

## 1. OpenJDK 26 JRE — GPL-2.0-only WITH Classpath-exception-2.0

* Bundled as `entry/src/main/resources/rawfile/meow_jre.tar.gz` (the `java.home`
  data image) and `libs/meowjre/libs/arm64-v8a/*.so` (**29** native libs).
* **Upstream base:** official OpenJDK **26.0.2.1** (Linux/aarch64, **glibc**) —
  `https://jdk.java.net/archive/`, `JAVA_RUNTIME_VERSION=26.0.2.1+1-7`
  (`openjdk-26.0.2.1_linux-aarch64_bin.tar.gz`, sha256
  `b96b265a4a1a36c02454148891aa58ca63303cbc2d1b7979c33b4fe99e09117b`).
* **Upstream source:** the OpenJDK update repository
  `https://github.com/openjdk/jdk26u`, tag **`jdk-26.0.2.1-ga`** →
  commit **`d55edf1cba61219d17565da51cd13a4d425f7c59`** (the exact commit the
  official build records as `SOURCE=git:d55edf1cba61`; 26.0.x is **not** in the
  mainline `openjdk/jdk`).
* **Our modifications / self-builds** (recipe: `tools/jre26/`):
  * 26 of the official libraries are **binary-patched** in place (ELF `.dynstr`
    NEEDED rewrite; `tools/jre26/patch_dynstr.py`) so they load on OHOS (musl);
  * `libc6.so` — our self-built glibc-compatibility shim (`tools/jre26/glibc_compat.c`);
  * `libjvm.so` and `libjli.so` — **self-built** from the source above with our OHOS
    split-layout patches (`tools/jre26/patches/`);
  * the data image (`lib/modules`, …) — official 26.0.2.1 data, **slimmed** via `jlink`,
    plus our `lib/patch/jdk.zipfs/**` best-effort-chmod class patch.

## 2. OpenJDK 8 JRE (Eclipse Adoptium Temurin 8u504-b01) — GPL-2.0-only WITH Classpath-exception-2.0

* Bundled as `entry/src/main/resources/rawfile/meow_jre_legacy.tar.gz` (the
  `java.home` data image; data token `1.8.0_504-b01-r1`) and
  `libs/meowjrelegacy/libs/arm64-v8a/*.so` (**25** native libs).
* **Upstream base:** official **Eclipse Adoptium Temurin 8** (`jdk8u504-b01`,
  Linux/aarch64, **glibc**, `image_type=jdk`) —
  `https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u504-b01/OpenJDK8U-jdk_aarch64_linux_hotspot_8u504b01.tar.gz`,
  sha256 `57b7ed8af9d48542bb49ff7894448040b17bea0a48b41677d11ecaec6129768d`
  (the official build records its own source as `SOURCE=".:git:1358e1b273e2+"`).
* **Upstream source:** `https://github.com/openjdk/jdk8u`, tag **`jdk8u504-b01`** →
  commit **`4efe36434f44bafb854e602ccbbe1b5696fce1a2`** (the exact tree our
  self-built libraries are compiled from).
* **Our modifications / self-builds** (recipe: `tools/jre8/`):
  * the shipped official libraries are **binary-patched** in place (ELF `.dynstr`
    NEEDED rewrite; `tools/jre8/patch_dynstr.py`);
  * `libc6.so` — our self-built glibc-compatibility shim (`tools/jre8/glibc_compat.c`);
  * `libjli.so` and `libjvm.so` — **self-built** from the source above with our OHOS
    split-layout patches (`tools/jre8/patches/`) and the NPTL pin (musl is
    misdetected as LinuxThreads without it).

## 3. OpenAL Soft 1.24.3 — LGPL-2.0-or-later

* Bundled as `libs/meowlwjgls/libs/arm64-v8a/libopenal.so` (a **separate,
  dynamically-linked** shared object).
* **Upstream source:** `https://github.com/kcat/openal-soft`, tag **`1.24.3`**
  (`ref/openal-soft`).
* **Our modifications** (recipe: `tools/openal/`): the OHOS port, a new **OHAudio**
  backend (default), OpenSL fixes, and the `ALC_SOFT_system_events` export
  (`tools/openal/patch_openal_*.py`, `tools/openal/ohaudio/ohaudio.{cpp,h}`).
* Per **LGPL §6** the library is relinkable (it is a separate `.so`), and both the
  library source and the "work that uses the library" (our MIT-licensed code) are
  available to enable this.

## 4. glslang — GPL-3.0-or-later WITH Bison-exception-2.2

* Bundled **statically into `libs/meowlwjgls/libs/arm64-v8a/libshaderc.so`**.
* Only the **bison-generated parser-skeleton fragment** inside glslang is under
  GPL-3.0 — and it is GPL-3.0 **with the Bison exception 2.2**, which expressly
  permits distributing a larger work that contains the skeleton under terms of your
  choice. glslang's core parsing/codegen code is permissive (BSD / MIT / Apache-2.0);
  the aggregate license text is in
  `entry/src/main/resources/rawfile/licenses/glslang-multi-license.txt`.
* **Upstream source:** `https://github.com/KhronosGroup/glslang`, commit
  **`168d452a`** (glslang 16.4.0) — the same revision pinned by our shaderc recipe
  (`tools/shaderc/`).

## How to obtain the source

* **Our modifications + rebuild recipes are in this repository:** `tools/jre26/`,
  `tools/jre8/`, and `tools/openal/` (scripts, `patches/*.patch`, `ohaudio/`,
  `README.md` with the exact upstream tags/commits and digests).
* **Upstream sources** are at the tags/commits listed in §1–§4 — from
  `https://github.com/openjdk/jdk26u`, `https://github.com/openjdk/jdk8u`,
  `https://github.com/kcat/openal-soft`, and `https://github.com/KhronosGroup/glslang`.

If you cannot obtain any of the above from upstream, we offer — for **at least
three (3) years** from the date of distribution — to provide the corresponding
source code on a medium customarily used for software interchange, for no more than
our cost of physically performing the distribution.

**Contact:** `meowycat@qq.com`

## 5. Other self-built components (not copyleft, no offer required)

The other self-built components (LWJGL native + jar, Legacy LWJGL2, FreeType, the
SDL3 fork, shaderc, SPIRV-Cross, gl4es, OSHI overrides) are built from their public
upstream sources; their revisions are recorded in the relevant `tools/*/README.md`
and in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). Their licenses
(BSD-3-Clause, FTL, Zlib, Apache-2.0, MIT) do not require a source offer, but the
sources are publicly available upstream.
