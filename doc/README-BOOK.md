# 书稿构建与排版

本文档只说明如何准备、构建和维护 Typst 书稿。涉及 Blender 源码、编译、运行测试或
截图的工作，见 [README-BLENDER.md](README-BLENDER.md)。

## 一、准备书稿环境

在工程根目录运行：

```bash
scons init-book
```

SCons alias 调用 `tools/init_book.py`，负责：

- 检查 Python 与 Typst；
- 默认下载并校验 `book/fonts/` 中的项目字体；
- 创建书稿构建目录；
- 用临时探针预取 `@preview/cetz:0.3.4`。

字体下载以仓库中的哈希清单为准：先下载到临时目录，完成格式、字体族、字形覆盖和
SHA-256 校验后，再原子安装到 `book/fonts/`。下载失败或内容与清单不符时不会覆盖已有
文件，也不需要维护者手工解压、移动或改配置。

它不会安装命令行工具，也不会构建 PDF。Typst 缺失时，初始化会打印官方安装方式并以
非零状态退出；它不会下载 Typst，也不会调用 `winget`、Homebrew、apt、Cargo 等包管理器。
首次预取 cetz 时，Typst 自身会按正常机制写入其包缓存；cetz 是书稿依赖，不是由脚本
安装的系统工具。

如果准备使用系统字体，可在初始化阶段一并声明。该命令会检查候选系统字体，但完全跳过
`book/fonts/` 的校验和下载：

```bash
scons init-book --use-system-fonts
```

只检查、不下载或编译时使用：

```bash
python tools/init_book.py --check-only
# 或
scons init-book --check-only
```

## 二、构建与验证

普通构建：

```bash
scons build-book
```

默认格式是 PDF。实验性 HTML 构建使用：

```bash
scons build-book --format=html
```

构建顺序固定为：发现书稿中的 Cetz 图表 → 将每张图单独导出为
`book/build/res/fig-*.svg` → 准备网页字体资源 → 编译 HTML → 嵌入
`book/html/style.css`。图表通过相对路径引用这些 SVG，不依赖 Typst 尚未完成的 Cetz
HTML 布局支持。`book/figures/*.typ` 中的 `fig-<文件名>()` 会自动发现；章节中直接书写的
`figure(canvas(...))` 也会扫描，但必须带唯一的 `<fig-...>` 标签。

默认项目字体模式会把清单中 8 个已校验字体及其 OFL 许可复制到 `book/build/res/`，并生成对应的
`@font-face`。使用 `--use-system-fonts` 时只生成 SVG，不复制字体，网页改用
`style.css` 中的 Windows、macOS 与 Linux fallback。HTML、SVG 和字体共同构成网页产物，
移动 HTML 时应连同同级的 `res/` 一起移动。

Typst 官方仍将 HTML 导出标记为实验功能；构建器只放行“HTML 功能尚不完整”和分页布局
元素被忽略这两类已知警告，其他 warning 或任何 error 都会失败。`--check` 依赖 PDF
分页，`--release` 也只发布 PDF，因此两者不能与 `--format=html` 组合。

构建脚本不会联网下载或修复字体。它会在调用 Typst 前按清单进行只读预检；任何字体缺失、
损坏或哈希不符都会立即停止，并提示先运行 `scons init-book`。初始化成功
后再次构建即可，不存在需要人工处理字体文件的中间步骤。

完整检查会重新构建、逐页渲染并扫描版心溢出：

```bash
scons build-book --check
```

PDF 构建产物位于 `book/build/blender-development-guide.pdf`。脚本会打印绝对路径、文件大小、
页数及 Typst 的 error / warning 数量。PDF 的任何 error 或 warning 都会使构建以非零状态
退出，即使 Typst 已经生成文件；正式交付标准始终是零诊断。

对外发布时不要直接复制整个 `book/build/`。运行：

```bash
scons build-book --release
```

发布目录位于 `dist/blender-development-guide/`，顶层只包含
`blender-development-guide.pdf` 与 `examples/`。`book/examples/` 是源码维护位置；
书中用脚注展示的路径以发布目录为基准，因此统一写成 `examples/...`。
`--release` 可以和 `--check` 组合，但不能和 `--use-system-fonts` 组合：对外发布始终强制
使用项目固定字体，以保证分页可复现并避免系统字体的再分发许可问题。

需要直接调用 Typst 时，字体参数不能省略：

```bash
cd book
typst compile --font-path fonts --ignore-system-fonts --ignore-embedded-fonts \
  main.typ build/blender-development-guide.pdf
```

单独编译章节时要加 `--root .`；若章节引用了其他章节的标签，出现
`label <fig-xxx> does not exist` 属于预期限制，不代表整书构建失败。

### 使用系统字体

临时开发构建可以跳过项目字体，改用本机字体：

```bash
scons build-book --use-system-fonts
scons build-book --check --use-system-fonts
scons build-book --format=html --use-system-fonts
```

如果尚未初始化，先运行 `scons init-book --use-system-fonts`；初始化和构建使用同一套候选
列表。`--force` 只适用于项目字体，因此不能与 `--use-system-fonts` 组合。

构建器先执行 `typst fonts --ignore-embedded-fonts`，只把本机实际存在的字体传给 Typst，
因此候选列表中的缺失项不会产生诊断。各平台的优先列表为：

| 平台 | 正文字体候选 | 等宽字体候选 |
|---|---|---|
| Windows | Microsoft YaHei、Microsoft YaHei UI、DengXian、SimHei、Arial | Cascadia Mono、Cascadia Code、Consolas、Source Code Pro、Courier New |
| macOS | PingFang SC、Hiragino Sans GB、Heiti SC、Songti SC、Arial Unicode MS、Helvetica、Arial | SF Mono、Menlo、Monaco、Courier New |
| Linux | Noto Sans CJK SC、Noto Sans SC、Source Han Sans SC、WenQuanYi Micro Hei、WenQuanYi Zen Hei、DejaVu Sans、Liberation Sans | Noto Sans Mono、Source Code Pro、DejaVu Sans Mono、Liberation Mono、Ubuntu Mono |

代码字体列表末尾还会追加已找到的正文字体，为中文注释兜底。如果正文或等宽候选一个都
找不到，构建会明确失败。系统字体模式的分页、字宽和字体许可取决于本机，只适合临时预览；
正式发布必须使用默认的项目字体模式。

## 三、目录与样式归属

```text
main.typ         全书入口；保存所有 #set / #show 样式
common.typ       函数与常量；不保存全局样式
meta.json        书籍自身版本的唯一配置
blender-baseline.json  Blender 版本、分支、标签与 commit 的唯一配置
front-matter.typ 前言
chapters/        18 章与附录 A–F
figures/         cetz 矢量图定义
html/            HTML 样式表
res/             平铺存放的位图与截图
examples/        随书完整代码案例
fonts/           项目字体、清单和许可文件
build/           PDF、HTML、网页 res/ 与逐页 PNG
```

Typst 的 `#set` 与 `#show` 只在声明文件内生效。章节必须通过 `#include` 拼入
`main.typ`，不要把全局样式放入 `common.typ` 后期待 `#import` 传播样式。

书籍版本与 Blender 基准版本彼此独立。发布书稿版本时通过下述命令更新 `meta.json`；
升级技术核对基准时修改 `blender-baseline.json`，并按 Blender 构建文档重新完成源码、
行为与截图验证。

### 版本号与发布说明

不要直接编辑 `meta.json` 来发布新版本。先把本次改动逐条写成无序列表，放到根目录
`RELEASE_NOTE.md` 的 `Pending` 一级标题下，再选择一种版本提升：

```bash
scons bump-version --major
scons bump-version --minor
scons bump-version --micro
```

三个开关互斥且必须恰好选择一个，分别重置或递增 `MAJOR.MINOR.MICRO` 的对应部分。
命令会先完整校验版本号和发布说明，再同步更新 `book/meta.json`，并在
`Release Note` 段最前面建立新版本二级标题、迁移全部 `Pending` 列表项。没有待发布条目、
标题结构不正确或目标版本已经存在时都会停止，避免生成空版本或覆盖既有记录。

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
- `book/res/` 平铺存放书稿位图；`book/figures/` 保存 cetz 图定义，两者不能混用。
  `book/build/res/` 是 HTML 构建自动生成的 SVG 与字体目录，不得手工维护或提交。

## 六、字体

默认构建只使用 `book/fonts/` 中的项目字体，禁止回退到系统字体：

| 用途 | 字体 | 授权 |
|---|---|---|
| 正文中文 | Noto Sans SC | SIL OFL 1.1 |
| 代码拉丁与符号 | Noto Sans Mono | SIL OFL 1.1 |
| 代码中文回退 | Noto Sans Mono CJK SC | SIL OFL 1.1 |
| 拉丁字符兜底 | Noto Sans | SIL OFL 1.1 |

代码字体栈的顺序不能调整：首选字体中的制表符与 ASCII 等宽，中文则由 CJK 等宽字体
回退。每一处显式 `#set text` 都应指定 `weight`，避免字体版本变化导致意外细体。
`--use-system-fonts` 是显式选择的开发模式，不改变上述默认与发布要求。

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
3. 运行 `scons build-book --check`，要求零 error、零 warning、零版心溢出。
4. 抽查受影响页面，确认没有纵向重叠、裁切或图形语义错误。
5. 确认 PDF 只嵌入项目字体，没有系统字体回退。
6. 确认全文无 `#todo` 占位，目录、章节及图表编号正确。
7. 发布版本时，确认 `RELEASE_NOTE.md` 的 `Pending` 条目完整，再运行一次对应的
   `scons bump-version` 命令。
