# 书稿构建与排版

本文档说明如何准备、构建和维护 Typst 书稿。只想生成 PDF 的读者不需要 Blender 源码；
修改 API、源码、构建流程或截图等技术内容时，再按
[README-BLENDER.md](README-BLENDER.md) 准备实证环境。

## 一、快速构建

先安装 Python、SCons 和 Typst，然后在仓库根目录运行：

```bash
scons init-book
scons build-book
```

`init-book` 准备字体、目录和 CeTZ 包缓存，但不生成书籍；`build-book` 默认生成 PDF：

```text
book/build/blender-development-guide.pdf
```

构建脚本不会安装命令行工具，也不会在编译过程中补下载字体。Typst 或字体缺失时会明确
失败，并提示先安装工具或重新运行 `scons init-book`。

## 二、准备书稿环境

`scons init-book` 调用 `tools/init_book.py`，完成以下工作：

- 检查 Python 与 Typst 是否可用；
- 当项目使用默认槽位且字体目录为空时，下载完整的内置 Noto 字体组；
- 创建书稿构建目录；
- 使用临时探针预取 `@preview/cetz:0.3.4`。

默认字体的下载地址、压缩包成员和目标文件名写在 `tools/init_book.py` 中，只服务于自动
拉取。字体先下载到临时目录，直链必须生成非空文件，ZIP 必须能打开并包含目标成员，然后
才会原子安装；不检查哈希或字体版本。

`book/fonts/noto.json` 不保存下载信息。只要 `book/fonts/` 中已有用户提供的字体文件，
就会直接使用；文件是否能覆盖书稿字符最终由 Typst 编译决定。若改用了自定义槽位，
`init-book` 不会擅自下载默认 Noto 字体，用户需要自行放入字体文件。

只检查现有环境、不下载字体或预取包时使用：

```bash
scons init-book --check-only
```

临时预览也可以完全跳过项目字体，改用系统字体：

```bash
scons init-book --use-system-fonts
scons build-book --use-system-fonts
```

初始化和构建必须选择同一种字体模式。系统字体模式的分页和字宽取决于本机环境，只适合
开发预览，不得用于正式发布。

## 三、构建模式

| 命令 | 结果与依赖 |
|---|---|
| `scons build-book` | 构建正式 PDF；不需要 Blender 源码 |
| `scons build-book --format=html` | 构建实验性 HTML 与 `res/` 资源目录 |
| `scons build-book --check` | 核对固定版本源码引用，再构建 PDF 并执行逐页版面扫描 |
| `scons build-book --release` | 生成顶层仅含 PDF 与 `examples/` 的发布目录 |
| `scons build-book --release --check` | 完整检查通过后生成发布目录 |

PDF 必须达到零 error、零 warning。即使 Typst 已经生成文件，只要出现不接受的诊断，
构建仍会以非零状态退出。

### 实验性 HTML

HTML 构建过程为：发现书稿中的 CeTZ 图表 → 导出 SVG → 准备网页字体 → 编译正文 →
嵌入 `book/html/style.css`。输出包括：

```text
book/build/blender-development-guide.html
book/build/res/
```

`book/figures/*.typ` 中导出的 `fig-<文件名>()` 会被自动发现。章节内直接书写的
`figure(canvas(...))` 也可以导出，但必须带唯一的 `<fig-...>` 标签。

默认字体模式会把配置中的网页字体和许可文件复制到 `res/`；使用
`--use-system-fonts` 时不复制字体，网页改用样式表中的 Windows、macOS 和 Linux fallback。
移动 HTML 时必须同时移动同级的 `res/`。

Typst 的 HTML 导出仍是实验功能。`--check` 依赖 PDF 分页，`--release` 也只发布 PDF，
因此两者不能与 `--format=html` 组合。

### 完整检查

```bash
scons build-book --check
```

完整检查面向书稿维护者，会按以下顺序执行：

1. 确认默认 `blender/` 检出的 HEAD 与 `book/blender-baseline.json` 一致；
2. 检查所有 `#src(...)` 路径和行号；
3. 使用项目字体重新构建 PDF；
4. 把每一页渲染为 PNG 并扫描版心横向溢出；
5. 删除逐页渲染产生的临时图片。

普通 `scons build-book` 不读取也不要求 Blender 源码。源码依赖只属于完整检查，不能成为
仅构建书籍的读者必须承担的下载成本。

### 发布目录

```bash
scons build-book --release
```

发布结果位于 `dist/blender-development-guide/`，顶层只包含：

```text
blender-development-guide.pdf
examples/
```

不要直接复制整个 `book/build/`。发布构建必须使用项目字体，因此 `--release` 与
`--use-system-fonts` 互斥。`book/examples/` 是示例的维护位置，正文脚注则以发布目录为
基准统一写成 `examples/...`。

## 四、字体

### 字体槽位配置

项目使用两份 JSON 配置，分别覆盖两种字体来源：

- `book/fonts/noto.json`：项目字体的正文与代码字体槽位；
- `book/fonts/system-fallbacks.json`：Windows、macOS 与 Linux 的正文和等宽字体候选链。

项目字体配置刻意保持简单，例如：

```json
{
  "body": ["Noto Sans SC", "Noto Sans"],
  "code": ["Noto Sans Mono", "Noto Sans Mono CJK SC", "Noto Sans"]
}
```

`body` 和 `code` 是两个排版槽位，不代表只使用两个字体族。每个值都是按优先级排列的
fallback chain：Typst 先尝试数组中的第一个字体族；当前字符没有对应字形时，再依次尝试
后面的字体族。两个数组可以共享同一个字体族。

默认配置共涉及四个唯一字体族：`Noto Sans SC` 是正文主字体，`Noto Sans Mono` 是代码中
拉丁字符和符号的主字体，`Noto Sans Mono CJK SC` 补充代码中的中文，`Noto Sans` 是两个
槽位共用的最终兜底。自动下载组为每个字体族准备 Regular 和 Bold 两种字重，因此共有八个
字体文件；“两个槽位”“四个字体族”和“八个字体文件”是三个不同层次的概念。

Typst 没有独立的字体配置文件格式，但 `text(font: (...))` 原生支持有顺序的字体族数组，
并能通过 `sys.inputs` 接收外部配置。构建脚本根据 `--use-system-fonts` 选择上述配置：默认
模式通过 `--font-path` 发现 `book/fonts/`，书稿直接读取 `noto.json` 的槽位；系统字体模式
先运行 `typst fonts`，从当前平台的候选链中筛出实际存在的字体，再通过 `sys.inputs` 把
结果交给书稿。HTML 导出还会查询 Typst 识别出的字体文件与字重，复制相应文件并生成
`@font-face`，因此 PDF、CeTZ 图和 HTML 样式共用同一套槽位定义。

### 自定义项目字体

[Typst 字体文档](https://typst.app/docs/reference/text/text/)说明了 `--font-path`、字体族
优先级和变体选择。当前 CLI 使用的字体扫描器可读取以下文件：

- `.ttf`：TrueType/OpenType 字体；
- `.otf`：OpenType 字体；
- `.ttc`：TrueType Collection 字体集合；
- `.otc`：OpenType Collection 字体集合。

WOFF 与 WOFF2 是网页字体封装，不属于 Typst CLI 通过 `--font-path` 扫描的字体格式。
实验性 HTML 会原样复制项目字体；考虑到浏览器对字体集合的支持并不一致，需要导出 HTML
时优先使用 `.ttf` 或 `.otf`。

JSON 中填写的是字体文件内部的 family name，不是文件名。把字体放入 `book/fonts/` 后，
先运行以下命令查看 Typst 实际识别的名称，再修改 `body` 与 `code`：

```bash
typst fonts --font-path book/fonts --ignore-system-fonts --ignore-embedded-fonts
```

同一字体族的 Regular、Bold、Italic 等文件使用相同 family name；Typst 会根据正文要求的
`weight`、`style` 和 `stretch` 选择最接近的变体。字体文件应连同其许可文本一起保存，
使用与再分发责任由提供字体的人确认。

默认构建只使用 `book/fonts/` 中的项目字体，并显式禁止系统字体和 Typst 内置字体回退：

| 槽位与职责 | 字体族 | 授权 |
|---|---|---|
| `body` 主字体 | Noto Sans SC | SIL OFL 1.1 |
| `code` 拉丁字符与符号主字体 | Noto Sans Mono | SIL OFL 1.1 |
| `code` 中文回退 | Noto Sans Mono CJK SC | SIL OFL 1.1 |
| `body`、`code` 共用的最终回退 | Noto Sans | SIL OFL 1.1 |

默认 `body` 先使用 Noto Sans SC，再以 Noto Sans 兜底；默认 `code` 先使用 Noto Sans
Mono，再用 Noto Sans Mono CJK SC 补齐中文，最后以 Noto Sans 兜底。调整数组内容或顺序
时要重新检查代码对齐、缺字与分页。每一处显式 `#set text` 都应指定 `weight`，避免字体
变化后意外使用细体。

系统字体候选以 `system-fallbacks.json` 为准，不在文档中复制一份容易失效的列表。正文或
等宽候选全部缺失时，构建会明确失败。系统字体的本机使用权不自动包含嵌入与再分发权；
选择该模式前应核对实际命中的字体许可，并且不要用它生成正式发布包。

## 五、书稿目录与版本

`book/` 中的重要路径如下：

```text
main.typ               全书入口和全局样式
common.typ             公共函数与常量
front-matter.typ       前言
chapters/              第 0–17 章与附录 A–F
figures/               CeTZ 矢量图定义
res/                   平铺存放的位图与截图
examples/              随书完整示例源码
html/style.css         HTML 样式表
fonts/                 两套字体配置、项目字体和许可文件
build/                 PDF、HTML 和临时构建资源
meta.json              书籍版本
blender-baseline.json  Blender 5.2 LTS 技术核对基准
```

书籍版本与 Blender 技术基准彼此独立。`meta.json` 只负责封面上的书籍版本；
`blender-baseline.json` 记录精确版本、分支、标签和提交号。文档不复制具体提交号，需要时
直接读取该配置文件。

发布新书稿时，不要直接编辑 `meta.json`。先把改动写入根目录 `RELEASE_NOTE.md` 的
`Pending` 列表，再运行以下命令之一：

```bash
scons bump-version --major
scons bump-version --minor
scons bump-version --micro
```

三个开关互斥且必须恰好选择一个。命令会校验语义版本和发布说明，更新 `meta.json`，并把
Pending 条目迁移到最新版本下。升级 Blender 基准则应按
[README-BLENDER.md](README-BLENDER.md) 重新完成源码、行为和截图验证。

## 六、Typst 与排版规则

Typst 的 `#set` 与 `#show` 只在声明文件及其包含范围内生效。章节通过 `#include` 拼入
`main.typ`；不要把全局样式放进 `common.typ` 后期待 `#import` 传播样式。

| 内容 | 规则 |
|---|---|
| 加粗 | 使用 Typst 单星号：`*粗体*`；不要写 Markdown 的双星号 |
| 标题 | 使用 `=`、`==`、`===`；`#` 在 Typst 中进入代码模式 |
| 尾下划线标识符 | `DNA_`、`RNA_`、`BKE_` 等必须放进行内代码 |
| 表格单元格 | 使用 `[...]` 包住内容 |
| 内容块中的井号 | 写成 `\#` |
| 以斜杠开头的文字 | 放进行内代码，避免被解析为术语列表 |

代码块应先按语言语义主动换行，再考虑字号：Python 使用悬挂缩进，C/C++ 按参数或逻辑
表达式断行，Shell 使用续行符并对齐后续参数。单行尽量不超过约 96 个 ASCII 字符。

全局代码字号为 8.2pt，表格字号为 9pt。内容拥挤时优先精简、调整列宽或拆表，不要不断
缩小字号。源码路径必须允许在 `/`、`_`、`-`、`.`、`:` 后断行；新增路径渲染函数时要
保持这一行为。

图片路径相对调用它的章节文件解析。章节引用 `book/res/` 时使用
`../res/<文件名>`。`book/res/` 保存位图，`book/figures/` 保存 CeTZ 图定义，
`book/build/res/` 是 HTML 构建产物，三者不能混用。

## 七、术语、引用、脚注与示例

- 术语首次出现时加粗并附英文，之后保持命名一致；正文只写渲染结果，不向读者解释
  `#term(...)` 等书稿宏。
- 源码引用使用 `#src(...)`，图表引用使用 `@fig-xxx` 或 `@tbl-xxx`，不得手写编号。
- 脚注只安置不影响当前推理的短解释，例如术语别名、命名来历和轻量版本背景。
- 操作前提、行为差异、安全警告、撤销与清理、核心概念和源码证据必须留在正文。
- 可独立运行、编译或安装的完整示例放在 `book/examples/`，正文通过
  `#example-file("...")` 脚注标明发布包中的相对路径。

## 八、视觉检查与交付

编译成功和横向溢出扫描无法发现全部版面问题。修改表格、图注、截图或 CeTZ 图后，还要
人工检查：

- 表格末行是否压住表注；
- 连线是否穿过文字，箭头方向是否正确；
- 文字是否出框、裁切或产生不合理换行；
- 图中的函数、类型和路径是否与源码一致；
- 小字号内容在正常阅读比例下是否清晰；
- 页眉、页脚、页码和章节过渡是否正常。

交付前按以下顺序确认：

1. 运行 `python qa/check_markdown.py`；
2. 运行 `python qa/check_examples.py`；
3. 运行 `scons build-book --check`，要求源码引用、提交号、编译诊断和版心扫描全部通过；
4. 抽查受影响页面，确认没有纵向重叠、裁切或图形语义错误；
5. 确认正式 PDF 只嵌入项目字体；
6. 确认目录、交叉引用和图表编号正确；
7. 发布时检查 Pending 条目，再运行对应的 `scons bump-version` 和发布构建。

需要直接调用 Typst 排错时，必须保持与默认构建相同的字体参数：

```bash
cd book
typst compile --font-path fonts --ignore-system-fonts --ignore-embedded-fonts \
  main.typ build/blender-development-guide.pdf
```

单独编译章节时还要加 `--root .`。章节引用其他文件中的标签时，单章编译出现缺失标签并不
代表整书构建失败；最终判断仍以完整书稿构建为准。
