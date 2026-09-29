// meowjrelegacy HSP：**第二套** JRE 载体（legacy 段：Forge ≤1.12.2 / 1.13–1.16；版本无关，JRE 版本由数据令牌体现）。
// - 为什么必须另起一个 HSP：`OHOS_DL_DIR` 是**单一扁平目录 + 裸名**（`$OHOS_DL_DIR/libjvm.so`），
//   两套 JRE 的 `.so` 合租同一 el1 目录会互相污染（见 notes `多JRE共存-方案.md` §2 C3）。
// - `libIsolation:true` → 自身 libs 目录为独立命名空间；
// - 静态依赖 meowcraftlib(HAR)：其 native（libmeowjrebridge/libmeowcraftbridge + c++）与
//   JRE .so 一起合入本模块 libs → 桥与 libjli 同目录，可同命名空间 dlopen。
// - 「选哪套 JRE」= 「用哪个模块的 el1 目录」；entry 侧由 `Paths.hspLibsDirFor(dir, module)` 决定。
export * from 'meowcraftlib';
