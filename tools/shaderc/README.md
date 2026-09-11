# tools/shaderc — self-built OHOS aarch64 `libshaderc.so` + `libspirv-cross.so`

Cross-compiled OHOS/OpenHarmony aarch64 (musl, `libc++_shared`) builds of the two
native libraries Minecraft 26.3's renderpearl path loads through LWJGL 3.4.3:

| Meowcraft artifact | Upstream project / CMake target | LWJGL binding |
|---|---|---|
| `libshaderc.so` | `google/shaderc` → `shaderc_shared` | `org.lwjgl.util.shaderc.Shaderc` |
| `libspirv-cross.so` | `KhronosGroup/SPIRV-Cross` → `spirv-cross-c-shared` | `org.lwjgl.util.spvc.Spvc` |

Both are **self-contained shared objects**: their `DT_NEEDED` is only
`libc++_shared.so` + `libc.so`, exactly like the native LWJGL ships (glslang,
SPIRV-Tools and SPIRV-Headers are statically linked into `libshaderc.so`).

## Pinned revisions

Read from the `libshaderc.so.git` / `libspirv-cross.so.git` markers inside the
official LWJGL 3.4.3 native jars
(`org.lwjgl:lwjgl-shaderc:3.4.3:natives-linux`,
`org.lwjgl:lwjgl-spvc:3.4.3:natives-linux`). The shaderc dependencies are the
revisions listed in shaderc's `DEPS` at that commit:

| Project | Revision | Notes |
|---|---|---|
| google/shaderc | `2c8cae778eec0283b44acbe7ed1a386865d78799` | "Finalize Shaderc v2026.3" |
| KhronosGroup/glslang | `168d452a4f460d24b588fed08477a81c44ee27a1` | glslang 16.4.0 (from shaderc DEPS) |
| KhronosGroup/SPIRV-Headers | `29981f65241605e08b0ede4cfeb999fe3b723c6a` | from shaderc DEPS |
| KhronosGroup/SPIRV-Tools | `b707790a898e44038547df54580022fc1cf89c3d` | v2026.3 (from shaderc DEPS) |
| KhronosGroup/SPIRV-Cross | `6c09849fe88c48eaed08413aa022aaa136a3a057` | from LWJGL `libspirv-cross.so.git` marker |

Source checkouts live at the workspace level: `ref/shaderc`, `ref/glslang`,
`ref/SPIRV-Tools`, `ref/SPIRV-Headers`, `ref/spirv-cross` (never inside the app
repo). The TLS proxy uses a self-signed cert, so clones use
`git -c http.sslVerify=false`.

## Sources (where to pull what)

`rebuild_for_meowcraft.sh` **auto-clones** any missing tree into the workspace-level
`ref/` (never inside the app repo) and checks out the pinned revision, then builds.
The TLS proxy uses a self-signed cert, so clones pass `git -c http.sslVerify=false`.

| dir | upstream | revision |
|---|---|---|
| `ref/shaderc` | https://github.com/google/shaderc.git | `2c8cae778eec0283b44acbe7ed1a386865d78799` |
| `ref/glslang` | https://github.com/KhronosGroup/glslang.git | `168d452a4f460d24b588fed08477a81c44ee27a1` |
| `ref/SPIRV-Tools` | https://github.com/KhronosGroup/SPIRV-Tools.git | `b707790a898e44038547df54580022fc1cf89c3d` |
| `ref/SPIRV-Headers` | https://github.com/KhronosGroup/SPIRV-Headers.git | `29981f65241605e08b0ede4cfeb999fe3b723c6a` |
| `ref/spirv-cross` | https://github.com/KhronosGroup/SPIRV-Cross.git | `6c09849fe88c48eaed08413aa022aaa136a3a057` |

## Build

```sh
# from the workspace root (Meowcraft/): clones the ref/ trees if missing, then builds
sh Meowcraft/tools/shaderc/rebuild_for_meowcraft.sh
```

The wrapper pins/uses the `ref/` trees, builds into
`stuffs/research/shaderc/build-ohos/{shaderc,spirv-cross}`, logs to
`stuffs/research/shaderc/build-meow.log`, and drops the artifacts in
`stuffs/research/shaderc/out/`.

Generic, path-agnostic script (any OHOS project can reuse it):

```sh
sh Meowcraft/tools/shaderc/build_shaderc_meow.sh \
  --src <shaderc> --glslang <glslang> --spirv-tools <SPIRV-Tools> \
  --spirv-headers <SPIRV-Headers> --spirv-cross <SPIRV-Cross> \
  --sdk-native <OHOS SDK>/native --out <out> \
  [--build <dir>] [--api 23] [--arch arm64-v8a] [--only both]
```

SDK path defaults to `$OHOS_SDK_NATIVE`, else
`$HOME/devecow/deveco_tools/sdk/default/openharmony/native`.

### The configure commands (what the script runs)

shaderc (`BUILD_SHARED_LIBS=OFF` is deliberate — see below; the `shaderc_shared`
target is declared `SHARED` explicitly, so glslang/SPIRV-Tools stay static and
get embedded):

```sh
cmake -G Ninja -S ref/shaderc -B <build>/shaderc \
  -DCMAKE_TOOLCHAIN_FILE=Meowcraft/tools/shaderc/shaderc_ohos.toolchain.cmake \
  -DOHOS_SDK_NATIVE=$OHOS_SDK_NATIVE -DOHOS_ARCH=arm64-v8a \
  -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL=23 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSHADERC_GLSLANG_DIR=$PWD/ref/glslang \
  -DSHADERC_SPIRV_TOOLS_DIR=$PWD/ref/SPIRV-Tools \
  -DSHADERC_SPIRV_HEADERS_DIR=$PWD/ref/SPIRV-Headers \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_EXECUTABLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
  -DSHADERC_ENABLE_SHARED_CRT=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
  -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DGLSLANG_TESTS=OFF
ninja -C <build>/shaderc shaderc_shared
```

SPIRV-Cross:

```sh
cmake -G Ninja -S ref/spirv-cross -B <build>/spirv-cross \
  -DCMAKE_TOOLCHAIN_FILE=Meowcraft/tools/shaderc/shaderc_ohos.toolchain.cmake \
  -DOHOS_SDK_NATIVE=$OHOS_SDK_NATIVE -DOHOS_ARCH=arm64-v8a \
  -DOHOS_STL=c++_shared -DOHOS_PLATFORM_LEVEL=23 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SHARED=ON \
  -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_WERROR=OFF
ninja -C <build>/spirv-cross spirv-cross-c-shared
```

`tools/shaderc/shaderc_ohos.toolchain.cmake` wraps the OHOS SDK toolchain and
re-labels the target as Linux so shaderc/glslang/SPIRV-Tools/SPIRV-Cross take
their generic UNIX paths and pass CMake's `try_compile` sanity checks; the real
compiler stays `aarch64-linux-ohos`, and `OHOS_STL=c++_shared` keeps the
`libc++_shared.so` runtime dependency.

## Verified build (2026-09-11, SDK clang 15.0.4, api 23)

| Item | `libshaderc.so` | `libspirv-cross.so` |
|---|---|---|
| Upstream → product | shaderc `2c8cae7` → `libshaderc_shared.so.1` | SPIRV-Cross `6c09849` → `libspirv-cross-c-shared.so.0.68.0` |
| Output path | `stuffs/research/shaderc/out/libshaderc.so` | `stuffs/research/shaderc/out/libspirv-cross.so` |
| Size (stripped) | 7 829 864 bytes | 2 902 376 bytes |
| sha256 | `0cff346503fc23ccd84e12c56a817a114f0a8cbf9435adc55e12603d8101c6ed` | `93ad99077aad8fa59dfe3b253ea783b2d3484894d0bbf34b195e526d505f71d7` |
| `DT_NEEDED` | `libc++_shared.so`, `libc.so` | `libc++_shared.so`, `libc.so` |
| `SONAME` | `libshaderc_shared.so.1` | `libspirv-cross-c-shared.so.0` |
| Dynamic symbols defined | 7044 (45 `shaderc_*`) | 206 (169 `spvc_*`) |
| Required exports | `shaderc_compiler_initialize`, `shaderc_compile_into_spv`, `shaderc_compile_options_initialize` ✅ | `spvc_context_create`, `spvc_compiler_create_compiler_options` ✅ |

Export counts match the official x86-64 LWJGL natives exactly (45 `shaderc_*`,
169 `spvc_*`). A `--no-undefined` link smoke test against both artifacts
(`stuffs/research/shaderc/check/*.so`) succeeds with
`aarch64-unknown-linux-ohos-clang`.

Both files are `llvm-strip --strip-unneeded`-stripped. The `SONAME` is kept as
upstream (`libshaderc_shared.so.1`, `libspirv-cross-c-shared.so.0`); LWJGL
`System.load()`s the extracted file by absolute path, so the renamed file name
(`libshaderc.so`, `libspirv-cross.so`) is what matters.

## Reproducibility

**3× clean rebuilds → `cmp` byte-identical** (same `--src`/`--out` paths):

| artifact | sha256 |
|---|---|
| `libshaderc.so` | `0cff346503fc23ccd84e12c56a817a114f0a8cbf9435adc55e12603d8101c6ed` |
| `libspirv-cross.so` | `93ad99077aad8fa59dfe3b253ea783b2d3484894d0bbf34b195e526d505f71d7` |

`libshaderc.so` is deterministic as-is. **`libspirv-cross.so` needed a fix**:
SPIRV-Cross's `CMakeLists.txt` embeds `string(TIMESTAMP …)` into `gitversion.h`,
which is compiled into `.rodata` (and the build-id), so a plain build differed on
every run. CMake's `string(TIMESTAMP)` honours `SOURCE_DATE_EPOCH`, so
`build_shaderc_meow.sh` exports it — defaulting to the pinned SPIRV-Cross commit's
time (`git show -s --format=%ct HEAD`). **No upstream source is modified.**

As with all our natives, byte-identity holds for the recorded **absolute
`--src`/`--out` paths**; a build at other paths is functionally identical but hashes
differently (the linker embeds the output path in `.dynstr`).

## Why `BUILD_SHARED_LIBS=OFF`

Building shaderc with `-DBUILD_SHARED_LIBS=ON` produces a `libshaderc_shared.so`
with three extra `DT_NEEDED` entries (`libglslang.so.16`,
`libSPIRV-Tools-shared.so`, `libSPIRV.so.16`), i.e. a bundle of sibling `.so`s
rather than the single self-contained library LWJGL ships and loads. Because
`libshaderc/CMakeLists.txt` declares `add_library(shaderc_shared SHARED …)`
independent of `BUILD_SHARED_LIBS`, leaving `BUILD_SHARED_LIBS=OFF` still yields
the shared `libshaderc_shared.so`, but with glslang/SPIRV-Tools linked in
statically — matching the official native's symbol set.

## Risks / unknowns

1. **Runtime on device is unverified.** Build + link + exports are verified; no
   on-device `shaderc_compile_into_spv` / `spvc` call has been executed yet.
2. **`libc++_shared.so` availability at load time.** Both libs `DT_NEEDED`
   `libc++_shared.so`; the packaging must place a matching `libc++_shared.so`
   where the dynamic linker finds it, or the load fails before any symbol use.
3. **SONAME/`DT_NEEDED` filename mismatch is benign for LWJGL** (absolute-path
   `System.load`), but any other consumer that links by `-lshaderc`/SONAME would
   need the file named `libshaderc_shared.so.1`. Not patched.
4. **glslang/SPIRV-Tools static-link bloat**: `libshaderc.so` is ~7.8 MB (vs the
   official ~10.4 MB x86-64), all-language support included (HLSL/GLSL/SPIR-V).
   Trimming language backends would shrink it but risks behaviour drift vs the
   official native.
5. **Toolchain quirks**: the OHOS SDK emits a harmless
   `--gcc-toolchain=… unused` warning and warns that `OHOS_PLATFORM_LEVEL` is
   unused by these projects; neither affects the result.
