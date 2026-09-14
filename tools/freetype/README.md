# tools/freetype — 自编 OHOS 版 FreeType（libfreetype.so）

用**上游 FreeType 2.13.3 源码**自编鸿蒙版 `libfreetype.so`，替换外部转手来的预编译件
（`libs/meowlwjgls/libs/arm64-v8a/libfreetype.so`），把可控性从「归因（未复现）」升级为「**源码级**」。

## 为什么 / 关键发现
- `libfreetype.so` 是 **MC 字体渲染**的 native（LWJGL `lwjgl-freetype` 绑定）。
- 取证：外部参照件 = **原版 FreeType 2.13.3**（无源码魔改）——我们自编后 **`.text` / `.rodata` 与外部参照件逐字节一致**，
  整体仅剩 build-id（20B）+ 段表元数据（11B）差异。

## 文件

| 文件 | 作用 |
|---|---|
| `build_freetype_meow.sh` | **独立通用**构建脚本：路径全从参数来，无项目假设 |
| `rebuild_for_meowcraft.sh` | 本项目 wrapper：`ref/freetype` 拉临时 worktree(`VER-2-13-3`) → 构建 → 落 meowlwjgls |

## 用法

```sh
sh tools/freetype/rebuild_for_meowcraft.sh              # 默认 tag VER-2-13-3
sh tools/freetype/rebuild_for_meowcraft.sh VER-2-13-3   # 显式
sh tools/freetype/build_freetype_meow.sh --src <源码树> --sdk-native <SDK>/native --out <目录>
```

SDK 不在默认位置时用 `OHOS_SDK_NATIVE` 覆盖（默认 `$HOME/devecow/deveco_tools/sdk/default/openharmony/native`）。

## 构建配置
- OHOS clang 15 + sysroot；`BUILD_SHARED_LIBS=ON`。
- **只留 zlib**：`FT_DISABLE_BZIP2/PNG/HARFBUZZ/BROTLI=ON`。
- 产物 `SONAME=libfreetype.so.6`，`DT_NEEDED=libz.so + libc.so`。
- strip + 去掉 OHOS 元数据段（`.permission`/`.codesign`/`.comment`）以对齐外部参照件形状。
- 断言：导出 `FT_/FTC_/TT_` 符号 ≥ 200（实际 222）。

## 核验（2026-09-09，实机通过）

| 项 | ours | 外部参照件 |
|---|---|---|
| 版本 | 2.13.3 | 2.13.3 |
| 导出符号 | 222 T | 222 T（`comm` diff 为空） |
| **`.text` / `.rodata`** | — | **逐字节一致** |
| 文件大小（去元数据后） | 701912 | 701912 |
| sha256 | `e41fe6b927f3d6605548473a6468000855ab9ad9239ef8d6ad988a3b2e0f1167` | `e85fbbb4…`（差异仅 build-id + 段表偏移） |
| 实机 | **MC 字体正常** ✅ | — |

## 相关
- 溯源：`notes/30-supply-chain/provenance-master.md` §4.3、`per-so-catalog.md` §B
- 上游：`ref/freetype`（完整 clone，含 `VER-2-13-3` tag）
- 对照（同类自编）：`tools/openal/`
