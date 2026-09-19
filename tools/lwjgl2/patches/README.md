# tools/lwjgl2/patches/

对 vendored 上游 `ref/lwjgl`（`git describe` = **`lwjgl2.9.3-19-g2df01dd7`**，commit `2df01dd7`，
`git clone https://github.com/LWJGL/lwjgl.git && git checkout 2df01dd7`）的**本地必要补丁**。`ref/lwjgl` 是独立 git clone，
补丁不改上游语义，仅在 JDK9+ 环境下让 generator 能跑通。

## 应用

```sh
cd <ws>/ref/lwjgl
git apply <ws>/Harmomeow-Craft-Launcher/tools/lwjgl2/patches/0001-generator-filer-bypass.patch
```

校验（若改动已在工作区，反向应通过）：

```sh
git apply --check --reverse .../0001-generator-filer-bypass.patch
```

## 清单

| 补丁 | 内容 | 为什么 |
|---|---|---|
| `0001-generator-filer-bypass.patch` | `GeneratorVisitor.visitTypeAsInterface` 改为**绕过 `Filer` 直写**生成 Java；`.gitignore` 忽略 `bin-meow/`、`src/hdrs-meow/` | JDK9+ `JavacFiler` 拒绝创建与编译输入同 FQN 的源文件；核心模板 `GL14.java` 声明的正是 `org.lwjgl.opengl.GL14` → `FilerException: Attempt to recreate a file`。上游跑 JDK6/7 无此检查 |

## 重新生成补丁

```sh
cd <ws>/ref/lwjgl && git diff > <ws>/Harmomeow-Craft-Launcher/tools/lwjgl2/patches/0001-generator-filer-bypass.patch
```
（需在补丁头部保留说明注释块，或另建 `0001-*.md` 记录。）

## 验证「补丁完整表达改动」（实测 2026-09-11，PASS）

铁律（`notes/00-current/工程与规范.md`）：**断言前自己实跑**。三种检查，从弱到强：

1. **能应用**：`git -C ref/lwjgl apply --check --cached <patch>`（对 pristine 索引）。
2. **== 工作区改动**：`git -C ref/lwjgl diff` 与补丁正文（首个 `diff --git` 起）**逐字节一致**；
   且 `git status --porcelain -uall` 除这 2 个文件外**无其它非忽略改动**。
3. **端到端（最强）**：从 pristine HEAD 导出 → 只打本补丁 → 与当前工作区**逐文件比对**：

```sh
T=$(mktemp -d)
git -C ref/lwjgl archive HEAD | tar -x -C "$T"          # 不含 .git
( cd "$T" && git apply <this-patch> )                    # 应 "Applied ... cleanly"
git -C ref/lwjgl ls-files | while IFS= read -r f; do
  cmp -s "$T/$f" "ref/lwjgl/$f" || echo "DIFF $f"
done
```

**实测结果**：HEAD = `2df01dd7`（pristine 上游 `LWJGL/lwjgl`，**无本地提交**）；补丁两文件均
`Applied ... cleanly`；**1378 个 tracked 文件 0 差异、0 缺失** ⇒ 新 clone + 本补丁 == 当前工作区。
