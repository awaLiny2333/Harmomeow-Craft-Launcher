# Source Code Offer

This project bundles some components under **copyleft** licenses that require
the distributor to make the corresponding source code available. This file is
that written offer.

## 1. OpenJDK / Java Runtime Environment (GPL-2.0-only WITH Classpath-Exception)

We distribute an OpenJDK 26 JRE that we **modified and partly rebuilt**:

* Bundled as `entry/src/main/resources/rawfile/meow_jre.tar.gz` (the `java.home`
  data image) and `libs/meowjre/libs/arm64-v8a/*.so` (**29** native libs).
* **Base**: official OpenJDK **26.0.2.1** (Linux/aarch64, **glibc**) —
  `https://jdk.java.net/archive/`, `JAVA_RUNTIME_VERSION=26.0.2.1+1-7`
  (`openjdk-26.0.2.1_linux-aarch64_bin.tar.gz`, sha256
  `b96b265a4a1a36c02454148891aa58ca63303cbc2d1b7979c33b4fe99e09117b`).
* **Our modifications / self-builds** (recipe: `tools/jre26/`):
  * 26 of the official libraries are **binary-patched** in place (ELF `.dynstr`
    NEEDED rewrite; `tools/jre26/patch_dynstr.py`) so they load on OHOS (musl);
  * `libc6.so` — our self-built glibc compatibility shim (`tools/jre26/glibc_compat.c`);
  * `libjvm.so` and `libjli.so` — **self-built** from OpenJDK source
    (`https://github.com/openjdk/jdk`, tag **`jdk-26-ga`**, commit `4408cd2a07a…`)
    with our OHOS split-layout patches (`tools/jre26/patches/`);
  * the data image (`lib/modules`, …) — official 26.0.2.1 data, **slimmed** via `jlink`.

> **We DO modify the JRE code.** The claim that only a data image was slimmed is obsolete.

In accordance with **GPLv2 §3**, the complete corresponding source code of the
exact binaries we ship is available:
* **Our modifications + rebuild recipe:** `tools/jre26/` (scripts, `patches/*.patch`, `README.md`).
* **Upstream base sources:** the official OpenJDK **26.0.2.1** build
  (`https://jdk.java.net/archive/`) and the OpenJDK source tag **`jdk-26-ga`**
  (`https://github.com/openjdk/jdk`, commit `4408cd2a07a14243a58cd9d30813302bfbe81133`).

If you cannot obtain it from upstream, we offer — for **at least three (3)
years** from the date of distribution — to provide the corresponding source
code on a medium customarily used for software interchange, for no more than
our cost of physically performing the distribution.

**Contact:** `<maintainer@example.com>`  ← TODO(maintainer): fill in an email.

## 2. OpenAL Soft 1.24.3 (LGPL-2.0-or-later)

We ship a **modified** `libopenal.so` (OpenAL Soft 1.24.3 + this project's OHOS
port, a new OHAudio backend, OpenSL fixes, and `ALC_SOFT_system_events` export).

The complete corresponding source of the modified library is available in this
repository:

* `tools/openal/` — patch scripts and the added `ohaudio/ohaudio.{cpp,h}`.
* `tools/openal/README.md` — how to obtain upstream 1.24.3 and rebuild
  byte-for-byte.

Because the library is a **separate, dynamically-linked `.so`**, you may
replace or relink it with your own build. (Per LGPL §6, both the library source
and the "work that uses the library" — our MIT source — are available to enable
this.)

**Contact:** `<maintainer@example.com>`  ← TODO(maintainer): fill in an email.

## 3. Other self-built components

The other self-built natives (LWJGL, FreeType, SDL3 fork, shaderc,
SPIRV-Cross, gl4es) are built from their public upstream sources; their
revisions are recorded in `tools/*/README.md` and `THIRD-PARTY-NOTICES.md`.
Their licenses (BSD-3, FTL, Zlib, Apache-2.0, MIT) do not require a source
offer, but the sources are publicly available upstream.
