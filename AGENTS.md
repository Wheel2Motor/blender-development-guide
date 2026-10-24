# 项目接手须知（面向维护者与 AI）

这是一本以 Blender 5.2 LTS 为技术基准的中文开发指南。项目的主要交付物是书籍，
不是可执行软件；改动应同时满足内容准确、编排清楚、排版稳定与构建可复现。

根目录的 `SConstruct` 是唯一的跨平台命令入口。业务逻辑放在 `tools/`，可重复运行的
质量检查放在 `qa/`。不要重新增加功能重复的 `.bat` 或 `.sh` 入口。

## 1. 先读哪些文档

开始工作前，按任务范围阅读以下文档：

- `README.md`：项目定位、使用入口与交付物。
- `doc/BOOK-SPEC.md`：书籍定位、内容边界、结构与写作规范。
- `doc/README-BOOK.md`：书稿初始化、构建、字体和 Typst 排版约定。
- `doc/README-BLENDER.md`：Blender 源码初始化、构建与实机验证。
- `doc/README-QA.md`：持续质量检查、源码引用检查及其边界。

文档层级必须保持清晰：

- 根 `README.md` 只介绍项目和工作流，**不得维护书籍目录**。
- 书籍的篇、章、附录结构只在 `doc/BOOK-SPEC.md` 中维护。
- 只要新增、删除、移动或重命名篇章、章节、附录，或者调整某章的职责边界，必须在
  同一次改动中同步更新 `doc/BOOK-SPEC.md`。
- 命令、参数或工作流变更时，要同步更新 `scons help`、根 `README.md` 与对应的专题文档。

## 2. 构建与检查的边界

### 2.1 书籍

```bash
scons init-book
scons build-book
```

`init-book` 检查 Typst、准备目录、在字体目录为空时下载默认项目字体、预取 Typst 宏包，
但不构建书籍。
所有入口只检查外部工具，不得自动安装 Typst、SCons、Git、CMake、编译器等程序。

`build-book` 默认只构建 PDF，不依赖本地 Blender 源码。字体或宏包未准备好时，应明确
提示用户先运行 `scons init-book`，不得在构建过程中偷偷下载。

常用变体：

```bash
scons init-book --use-system-fonts
scons build-book --use-system-fonts
scons build-book --format=html
scons build-book --check
scons build-book --release
```

- `--use-system-fonts` 用于本机预览，不保证分页可复现；发布构建必须使用配置中的 Noto 字体。
- `--format=html` 是实验性导出，会先准备 SVG 图形、网页资源和样式表；它不能与
  `--check` 或 `--release` 组合。
- `--check` 是完整检查：先核对源码引用与 Blender 基准，再构建 PDF、逐页渲染并检查
  横向溢出。因此它要求已经通过 `scons init-blender` 准备好 `blender/`。
- `--release` 只发布 PDF 与 `examples/`，不得把中间产物、检查报告或字体打入发布包。

字体槽位的唯一配置是 `book/fonts/fonts.json` 与
`book/fonts/fonts-system-fonts.json`。
两份 JSON 只保存 Typst 字体族槽位，不记录下载地址、文件名、哈希或版本。默认 Noto
字体组的下载实现集中在 `tools/init_book.py`；已有 `.ttf`、`.otf`、`.ttc` 或 `.otc`
项目字体直接使用。系统字体模式从对应平台的候选链筛选本机已有字体。调整排版字体时改
槽位配置，不要在 Typst 或 CSS 中复制字体族名单；调整默认下载源时只改初始化脚本。

### 2.2 Blender

```bash
scons init-blender
scons build-blender
```

`init-blender` 负责获取并核对 Blender 源码、主仓库 Git LFS 内容，以及当前平台所需的
预编译库。`build-blender` 只核验、配置和构建，不主动执行 Git fetch、LFS 拉取或子模块
更新；输入缺失时应指向 `init-blender`。

`--mirror`、`--mirror-url`、`--retries` 与 `--retry-delay` 只适用于 `init-blender`。
镜像只改变主仓库的克隆来源，不能改变固定基准，也不能放宽提交一致性检查。Windows 构建
只使用 MSVC，并应从普通终端通过 `vswhere` 自动定位 Visual Studio 2022，不得要求用户
预先打开 Developer Command Prompt，也不得自动降级到 clang-cl。

## 3. 版本与基准

- Blender 技术基准由 `book/blender-baseline.json` 唯一定义。Typst 书稿、初始化脚本和
  源码引用检查器应读取该配置，不要各自复制版本或提交信息。
- README、`doc/` 文档与 `AGENTS.md` 可以说明本书基于 Blender 5.2 LTS，并指向上述配置，
  但不得写死具体提交号。一次运行得到的行数、带宽、耗时等数据也不要写进长期文档。
- 升级 Blender 基准时，必须重新核对源码引用、版本相关结论、命令输出和截图；不要机械
  替换用于解释历史兼容性的旧版本示例。
- 书籍自身版本由 `book/meta.json` 唯一定义。先把面向读者的变更写入
  `RELEASE_NOTE.md` 的 `Pending` 无序列表，再运行且只运行一个：

  ```bash
  scons bump-version --major
  scons bump-version --minor
  scons bump-version --micro
  ```

## 4. 内容与排版规则

### 4.1 源码事实必须有证据

路径、字段、函数签名、控制流、行号和统计结论都必须以固定基准下的真实源码为准。
尤其注意负向映射、条件取反、同名概念和“只有若干处使用”之类的分布性结论；写入正文前
应检索完整定义与调用范围。不要凭记忆补齐源码行为。

普通 `scons build-book` 不承担源码真实性检查。涉及源码引用的改动至少运行：

```bash
python qa/check_source_refs.py
```

或者直接运行包含该检查的 `scons build-book --check`。

### 4.2 正文只呈现书籍范围内的信息

- 不要在书中提及本书工程的仓库、目录组织、构建脚本或维护流程。
- 不要把 `#term(...)`、`#src(...)` 等 Typst 宏写成面向读者的说明；这些属于
  `doc/README-BOOK.md`。
- 主线所需的前提、步骤、安全警告、版本行为与源码证据必须留在正文。术语别名、命名背景
  等短小旁支可放入脚注，不能把关键条件藏进脚注。
- 可独立运行的完整示例放在 `examples/`，正文明确指出示例文件；不要让发布所需代码只
  存在于书稿片段中。
- 正文中不要使用维护者本地的 `blender-src` 假设。源码目录统一称为 `blender/`；读者只
  构建书籍时不需要该目录。

### 4.3 Typst 与 Markdown

- 图表编号由 Typst 自动生成，引用使用标签，不要手写“图 4.1”之类的编号。
- 路径、长函数调用和代码行要主动选择断点并保持缩进；代码块和表格的字号只在确有版面
  需要时局部调整，不能以缩小到难以阅读的方式掩盖排版问题。
- 所有渲染路径的辅助函数都要允许在 `/`、`_`、`-`、`.`、`:` 等位置断行，避免撑宽表格。
- Markdown 的粗体标记与相邻中英文正文之间留空格，标点可直接跟在标记外侧。
- `book/res/` 保持平铺；新增图片后检查引用、图注、图表索引与实际清晰度。

## 5. 实现约束

- SCons 只负责编排，不复制 `tools/` 中的业务逻辑。新增参数必须放进 `scons help` 中所属
  alias 的分段，并拒绝在不适用的 alias 上使用，不能静默忽略。
- `qa/` 只保留可重复运行、失败时返回非零退出码的检查器；不要提交一次性脚本、报告、
  转储、逐页 PNG 或某次运行的统计快照。
- `tools/` 下脚本面向用户的输出使用英文，并确保 Windows 控制台路径含中文时不会因编码
  崩溃；代码注释可以使用中文。
- 初始化脚本只下载工程内可重新获取的数据。构建脚本不得自动安装工具，也不得偷偷修改
  用户的系统环境。
- 不要提交 `book/build/`、`book/fonts/`、`blender/`、平台构建目录或任何 PDF。
- 不要假定工作区是干净的。修改前查看 `git status`，保留用户已有的未提交改动。

## 6. 按改动选择验证

修改 Markdown：

```bash
python qa/check_markdown.py
```

修改书稿或示例：

```bash
python qa/check_examples.py
scons build-book
```

修改源码引用、基准相关内容或准备发布：

```bash
scons build-book --check
```

修改 HTML 导出：

```bash
scons build-book --format=html
```

修改 SCons 命令或参数：

```bash
scons help
```

`tools/check_overflow.py` 只检查横向版心溢出，不能发现表格末行压住表注等纵向重叠。
涉及复杂表格、浮动图、代码块或字体变化时，还需要人工查看最终 PDF/HTML，而不能只依据
零错误、零警告判断版面正确。
