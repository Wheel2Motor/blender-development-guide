# 书稿构建与排版

本文档只说明如何准备、构建和维护 Typst 书稿。涉及 Blender 源码、编译、运行测试或
截图的工作，见 [README-BLENDER.md](README-BLENDER.md)。

## 一、准备书稿环境

在工程根目录运行：

```bash
init-book.bat            # Windows
./init-book.sh           # macOS / Linux
```

入口脚本调用 `tools/init_book.py`，负责：

- 检查 Python 与 Typst；
- 下载并校验 `book/fonts/` 中的项目字体；
- 创建书稿构建目录；
- 用临时探针预取 `@preview/cetz:0.3.4`。

字体下载以仓库中的哈希清单为准：先下载到临时目录，完成格式、字体族、字形覆盖和
SHA-256 校验后，再原子安装到 `book/fonts/`。下载失败或内容与清单不符时不会覆盖已有
文件，也不需要维护者手工解压、移动或改配置。

它不会安装命令行工具，也不会构建 PDF。只检查、不下载时使用：

```bash
python tools/init_book.py --check-only
```

## 二、构建与验证

普通构建：

```bash
build-book.bat            # Windows
./build-book.sh           # macOS / Linux
```

构建脚本不会联网下载或修复字体。它会在调用 Typst 前按清单进行只读预检；任何字体缺失、
损坏或哈希不符都会立即停止，并提示先运行 `init-book.bat` 或 `./init-book.sh`。初始化成功
后再次构建即可，不存在需要人工处理字体文件的中间步骤。

完整检查会重新构建、逐页渲染并扫描版心溢出：

```bash
build-book.bat --check
# 或
python tools/build_book.py --check
```

构建产物位于 `book/build/blender-development-guide.pdf`。脚本会打印绝对路径、文件大小、
页数及 Typst 的 error / warning 数量。任何 error 或 warning 都会使构建以非零状态退出，
即使 Typst 已经生成 PDF；交付标准始终是零诊断。

对外发布时不要直接复制整个 `book/build/`。运行：

```bash
build-book-release.bat        # Windows
./build-book-release.sh       # macOS / Linux
```

发布目录位于 `dist/blender-development-guide/`，顶层只包含
`blender-development-guide.pdf` 与 `examples/`。`book/examples/` 是源码维护位置；
书中用脚注展示的路径以发布目录为基准，因此统一写成 `examples/...`。

需要直接调用 Typst 时，字体参数不能省略：

```bash
cd book
typst compile --font-path fonts --ignore-system-fonts --ignore-embedded-fonts \
  main.typ build/blender-development-guide.pdf
```

单独编译章节时要加 `--root .`；若章节引用了其他章节的标签，出现
`label <fig-xxx> does not exist` 属于预期限制，不代表整书构建失败。

## 三、目录与样式归属

```text
main.typ         全书入口；保存所有 #set / #show 样式
common.typ       函数与常量；不保存全局样式
meta.json        书籍自身版本的唯一配置
blender-baseline.json  Blender 版本、分支、标签与 commit 的唯一配置
front-matter.typ 前言
chapters/        18 章与附录 A–F
figures/         cetz 矢量图定义
res/             平铺存放的位图与截图
examples/        随书完整代码案例
fonts/           项目字体、清单和许可文件
build/           PDF 与逐页 PNG
```

Typst 的 `#set` 与 `#show` 只在声明文件内生效。章节必须通过 `#include` 拼入
`main.typ`，不要把全局样式放入 `common.typ` 后期待 `#import` 传播样式。

书籍版本与 Blender 基准版本彼此独立。发布书稿版本时修改 `meta.json`；升级技术核对基准时
修改 `blender-baseline.json`，并按 Blender 构建文档重新完成源码、行为与截图验证。

## 四、Typst 语法规则

| 规则 | 正确做法 |
|---|---|
| 加粗 | 使用单星号：`*粗体*`；不要写 Markdown 的 `**粗体**` |
| 标题 | 使用 `=`、`==`、`===`；`#` 在 Typst 中进入代码模式 |
| 尾下划线标识符 | `DNA_`、`RNA_`、`BKE_` 等必须放进行内代码 |
| 表格单元格 | 使用 `[...]` 包住内容 |
| 内容块中的井号 | 写成 `\#` |
| 以斜杠开头的文字 | 放进行内代码，避免被解析为术语列表 |

## 五、代码、表格与路径

- 代码块先做语义换行，再考虑字号。Python 使用悬挂缩进；C/C++ 按参数或逻辑表达式
  断行；Shell 使用续行符并对齐后续参数。单行尽量不超过约 96 个 ASCII 字符。
- 全局代码字号为 8.2pt，表格字号为 9pt。内容仍然拥挤时，优先精简、调整列宽或拆表，
  不要继续压缩字号。
- 源码路径必须允许断行。相关辅助函数已在 `/`、`_`、`-`、`.`、`:` 后插入零宽空格；
  新增路径渲染函数时必须保持这一行为。
- 图片路径相对调用它的章节文件解析。章节引用 `book/res/` 中资源时使用
  `../res/<文件名>`。
- `book/res/` 平铺存放位图；`book/figures/` 保存 cetz 图定义，两者不能混用。

## 六、字体

构建只使用 `book/fonts/` 中的项目字体，禁止回退到系统字体：

| 用途 | 字体 | 授权 |
|---|---|---|
| 正文中文 | Noto Sans SC | SIL OFL 1.1 |
| 代码拉丁与符号 | Noto Sans Mono | SIL OFL 1.1 |
| 代码中文回退 | Noto Sans Mono CJK SC | SIL OFL 1.1 |
| 拉丁字符兜底 | Noto Sans | SIL OFL 1.1 |

代码字体栈的顺序不能调整：首选字体中的制表符与 ASCII 等宽，中文则由 CJK 等宽字体
回退。每一处显式 `#set text` 都应指定 `weight`，避免字体版本变化导致意外细体。

## 七、术语、引用与脚注

- 术语首次出现时加粗并附英文。正文只写渲染结果，不向读者暴露 `#term(...)` 等宏。
- 源码引用使用 `#src(...)`，图表引用使用 `@fig-xxx` 或 `@tbl-xxx`，不得手写编号。
- 脚注只安置不影响当前推理的短解释，例如术语别名、命名来历、区域代码格式和轻量
  版本背景，长度控制在一至三句话。
- 可独立运行、编译或安装的完整示例必须放在 `book/examples/`，并在正文使用
  `#example-file("...")` 脚注标明发布包中的相对路径；正文代码可以只保留讲解所需片段。
- 操作前提、行为差异、安全警告、撤销与资源清理、核心概念及源码证据不得移入脚注。

## 八、视觉检查

编译成功和横向溢出扫描无法发现所有问题。修改表格、图注或 cetz 图后，还要检查：

- 表格末行是否压住表注；
- 连线是否穿过文字或箭头方向是否错误；
- 文字是否出框、裁切或被错误换行；
- cetz 样式键是否真实生效；
- 图中的函数、类型和路径是否与 Blender 源码一致；
- 小字号内容在正常阅读比例下是否仍然清晰。

## 九、交付前检查

1. 运行 `python qa/check_markdown.py`。
2. 运行 `python qa/check_source_refs.py`。
3. 运行 `python tools/build_book.py --check`，要求零 error、零 warning、零版心溢出。
4. 抽查受影响页面，确认没有纵向重叠、裁切或图形语义错误。
5. 确认 PDF 只嵌入项目字体，没有系统字体回退。
6. 确认全文无 `#todo` 占位，目录、章节及图表编号正确。
