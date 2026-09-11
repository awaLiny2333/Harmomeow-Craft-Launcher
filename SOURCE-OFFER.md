# Source Code Offer

This project bundles some components under **copyleft** licenses that require
the distributor to make the corresponding source code available. This file is
that written offer.

## 1. OpenJDK / Java Runtime Environment (GPL-2.0-only WITH Classpath-Exception)

We distribute a **prebuilt** OpenJDK 25 (aarch64, musl; OpenHarmony port):

* Bundled as `entry/src/main/resources/rawfile/meow_jre25.tar.gz` and
  `libs/meowjre25/libs/arm64-v8a/*.so`.
* Build identity: `JAVA_RUNTIME_VERSION=25.0.1-internal-adhoc...`;
  upstream source commit marker `78770bfaefd2`.
* We do **not** modify the JRE code; only its data image was slimmed
  (`tools/slim_jre_data.py` removes duplicate `.so` files — see
  `THIRD-PARTY-NOTICES.md` §1).

In accordance with **GPLv2 §3**, the complete corresponding source code of the
exact binary we ship is available from the upstream OpenJDK / OpenHarmony
OpenJDK project at the commit above.

> ⚠️ TODO(maintainer): pin the exact upstream repository URL + tag for the
> OpenHarmony OpenJDK 25.0.1 aarch64-musl build here.

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
