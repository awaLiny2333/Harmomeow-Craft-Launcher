// meowjre25 HSP：自足隔离的 JRE25 载体（历史 jre25 拓扑）。
// - 本模块 libIsolation:true → 自身 libs 目录为独立命名空间；
// - 静态依赖 meowcraftlib(HAR)：其 native（libmeowjrebridge/libmeowcraftbridge + c++）与
//   JRE .so、组件一起合入本模块 libs → 桥与 libjli 同目录，可同命名空间 dlopen。
// - entry 动态 import 本模块取桥导出，跨版本切换只需换 import 的模块名。
export * from 'meowcraftlib';
