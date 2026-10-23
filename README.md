# 《Blender 开发指南》

一本面向 Blender 插件开发者与源码贡献者的系统开发指南，贯通 Python 插件、原生加速
与 C++ 源码修改三条实践路径。书籍自身版本由
[`book/meta.json`](book/meta.json) 唯一定义；全书的 Blender 版本、分支、标签与 commit 由
[`book/blender-baseline.json`](book/blender-baseline.json) 唯一定义，书稿和检查脚本
读取同一份配置。已发布版本与待发布改动记录在 [RELEASE_NOTE.md](RELEASE_NOTE.md)。

## 维护前提

本项目不只是把 Typst 编译成 PDF。书中大量 API、源码路径、构建命令、运行行为和截图
必须来自真实的 Blender 源码与可运行程序，不能凭印象补写。

| 要做什么 | 必需环境 | 说明文档 |
|---|---|---|
| 只构建或检查现有书稿 | 书稿环境 | [README-BOOK.md](doc/README-BOOK.md) |
| 修改技术内容、代码或截图 | 书稿环境 + Blender 开发环境 | [README-BLENDER.md](doc/README-BLENDER.md) |
| 运行持续质量检查 | 视检查项目而定 | [README-QA.md](doc/README-QA.md) |

因此，继续开发书籍内容时，准备并构建 Blender 是必要步骤；只有纯排版修改可以不启动
Blender，但仍需完成书稿构建和视觉检查。

## 快速开始

所有平台统一使用根目录的 `SConstruct`。先确保 Python、SCons 与 Typst 可用；项目只检查
这些工具，不会自行安装。`scons help` 会打印全部 alias 与参数。

先准备书稿环境并构建 PDF：

```bash
scons init-book
scons build-book
```

`build-book` 的默认格式是 PDF。实验性 HTML 构建使用：

```bash
scons build-book --format=html
```

HTML 输出为 `book/build/blender-development-guide.html`，样式维护在
`book/html/style.css`。构建器会先把全部 Cetz 图表渲染成
`book/build/res/*.svg`；默认字体模式还会把已校验的项目字体复制到该资源目录。
Typst 的 HTML 导出仍是实验功能，因此 `--check` 与 `--release` 只支持 PDF。

默认情况下，`init-book` 会自动下载、校验并安装缺失字体；`build-book` 只做严格预检和编译，不会在
构建过程中联网修改输入。若字体未准备好，构建会停止并提示先运行对应的初始化入口。
需要完全跳过项目字体下载时，初始化和构建都要显式选择系统字体模式：

```bash
scons init-book --use-system-fonts
scons build-book --use-system-fonts
```

该模式会从当前 Windows、macOS 或 Linux 的候选列表中选择本机实际存在的字体，因此结果
不保证跨机器一致，不应用于正式发布。

需要修改技术内容时，再准备 Blender 源码、依赖和工具链：

```bash
scons init-blender       # 源码与依赖下载到 blender/
scons build-blender      # 生成本机 CMake 工程并构建
```

`init-blender` 负责源码、主仓库 LFS 内容、所有平台（含 Windows）的预编译库，以及
工具链检查；Git 与 Git LFS 长操作会实时显示进度。
`build-blender` 本身只核验初始化结果、生成工程和编译，不主动执行 `update` 或
Git `fetch`；三者缺一就在 configure 前失败并指回 `scons init-blender`。
Windows 平台的库也由 `init-blender` 非交互准备（等价于 `make.bat` 询问时回答 y），
所以 `make.bat` 的询问只有在库仍缺失时才会出现。
Windows 构建入口仅使用 MSVC，并通过 `vswhere` 自动定位 Visual Studio；可以从普通
`cmd.exe` 启动，不要求预先打开 Developer Command Prompt。
Windows 默认生成并构建 `build_windows/Blender.sln`（新工具链也可能生成 `.slnx`）；
macOS/Linux 默认使用 `build_macos/` 或 `build_linux/`。

官方仓库拉不动时，`init-blender` 可以换主仓库来源，`--mirror` 默认就是 `official`：
`--mirror=github` 走 GitHub 官方镜像，`--mirror=gitee` 走 Gitee 第三方镜像（同步状态由
维护者决定，脚本会先核验基准分支与提交，落后就失败），`--mirror-url=URL` 指向自建镜像。
镜像只换主仓库地址，`lib/` 平台库与 Git LFS 数据仍来自 `projects.blender.org`（`init-blender`
会把主仓库的 LFS 内容补齐，因为上游 configure 会拒绝指针形态的 `startup.blend`），
构建命令不变；细节见 [README-BLENDER.md](doc/README-BLENDER.md)。

提交前运行：

```bash
python qa/check_markdown.py
python qa/check_examples.py
python qa/check_source_refs.py
scons build-book --check
```

生成对外发布目录：

```bash
scons build-book --release
```

结果位于 `dist/blender-development-guide/`，顶层严格只有 PDF 与 `examples/`。
发布脚本会先检查书中示例脚注、示例文件和 Python 语法，再构建 PDF；传入 `--check`
还会执行逐页渲染与版心溢出扫描。发布构建必须使用项目固定字体，因此 `--release` 与
`--use-system-fonts` 互斥。

## 环境边界

初始化入口只往工程目录写可重新获取的数据，从不安装系统工具、不调用包管理器、不写系统
目录，也不下载任何命令行可执行文件：

- 字体 → `book/fonts/`（`init-book` 下载、校验后安装）
- Blender 源码、主仓库 Git LFS 内容与 `lib/<平台>_<架构>` → `blender/`（`init-blender`）
- cetz 宏包 → Typst 自己的包缓存（由 Typst 在预取时拉取，项目不代管）

`scons`、`typst`、`git`、`cmake`、`ninja`、编译器与 Python 只 **检查**：必需项缺失时打印
官方安装命令并 **非零退出**，可选项（`ninja`、`pdfinfo`、Pillow、`fontTools`）缺失只降级
功能、不影响退出码；`git-lfs` 视是否需要拉取 `lib/` 或主仓库 LFS 定为必需或仅提示。
Typst 自身不会被下载：脚本只查 `tools/bin/typst[.exe]` 与 `PATH`，找不到即报错退出。

## 项目文档

- [书稿规格](doc/BOOK-SPEC.md)：章节结构、内容范围和交付标准。
- [书稿构建与排版](doc/README-BOOK.md)：Typst 环境、字体、PDF/HTML 构建和排版验收。
- [Blender 构建与实证](doc/README-BLENDER.md)：源码、编译、运行测试和截图规范。
- [质量检查](doc/README-QA.md)：稳定检查器、适用边界和不应归档的产物。
- [发布说明](RELEASE_NOTE.md)：已发布版本及下一版本的待发布改动。
- [TODO.md](TODO.md)：书稿内容的待办清单（多镜像拉取、重试等选题）。
- `AGENTS.md`：面向维护者和自动化工具的工程约束，保留在仓库根目录。

## SCons 入口

| Alias | 职责 |
|---|---|
| `scons init-book` | 检查 Typst、准备书稿环境；默认下载项目字体，`--use-system-fonts` 时跳过 |
| `scons build-book` | 只读预检字体并构建 PDF（默认）或实验性 HTML |
| `scons init-blender` | 拉取固定 Blender 源码（`--mirror` 可换官方/GitHub/Gitee 来源）、还原主仓库 LFS、在所有平台准备 `lib/` 预编译库并检查工具链 |
| `scons build-blender` | 核验源码/LFS/依赖后生成 Blender CMake 工程并完成本机构建 |
| `scons bump-version` | 提升书籍版本，并把 `Pending` 列表移到发布说明最前面 |
| `scons help` | 打印全部 alias、参数与示例 |

SCons 只负责编排；实际跨平台逻辑仍位于 `tools/` 下的 Python 脚本中。全部 alias 与参数的
权威列表就是 `scons help`，常用参数示例：

```bash
scons build-book --check
scons build-book --format=html
scons build-book --format=html --use-system-fonts
scons init-book --use-system-fonts
scons build-book --use-system-fonts
scons build-book --release
scons build-book --release --check
scons init-blender --check-only
scons init-blender --mirror=official
scons init-blender --mirror=github
scons init-blender --mirror=gitee
scons init-blender --mirror-url=https://git.example.com/blender.git
scons init-blender --retries=30 --retry-delay=20
scons build-blender --blender-config=Debug -j 12
scons bump-version --minor
```

`--mirror` 与 `--mirror-url` 只属于 `init-blender`，且只在需要克隆时生效：已有检出只会被
核对与报告，不会被改写来源。所有联网步骤失败后默认重试 10 次、每次间隔 10 秒，可用
`--retries` 与 `--retry-delay` 调整（两者也只属于 `init-blender`）。SCons 的自定义参数
一律写成 `--opt=value`（例如 `--src=D:/src/blender`），空格分隔会被当成缺少参数。

发布新版本前，先把改动以无序列表写入 `RELEASE_NOTE.md` 的 `Pending` 段，再运行
`scons bump-version --major`、`--minor` 或 `--micro` 中恰好一个。命令会同步更新
`book/meta.json`，并把待发布条目归入新版本；详见
[书稿构建与排版](doc/README-BOOK.md)。

## 目录概览

```text
README.md                 项目入口
RELEASE_NOTE.md           已发布版本与 Pending 改动
AGENTS.md                 维护与自动化约束
SConstruct                跨平台初始化与构建入口
doc/                      项目文档
book/                     Typst 书稿、插图、截图和随书案例
book/examples/            书中明确标注的完整示例源码
book/html/                HTML 样式表
qa/                       可重复运行且不生成报告文件的质量检查器
tools/                    初始化、构建、检查和截图工具
blender/                  固定版本的 Blender 源码与预编译库（不入库）
book/build/               PDF、HTML、网页资源与逐页渲染产物（不入库）
dist/                     对外发布目录（不入库）
build_*/                  Blender 本机构建产物（不入库）
```

所有初始化入口只向工程目录写入可重新获取的数据，不安装系统工具，也不修改系统环境。
详细边界分别见两份构建文档。

## 验证原则

仓库不归档某次检查的页数、通过数量或问题清单；这些数据会随书稿变化而过期。以当次
检查命令的退出码和输出为准。技术结论即使通过路径检查，也仍需人工阅读源码或运行
Blender 验证。

## 授权

书稿与项目脚本沿用本项目既定授权。引用的 Blender 源码片段遵循 Blender 的
GPL-2.0-or-later；本地 `blender/` 检出目录的授权见其中的 `COPYING`。
