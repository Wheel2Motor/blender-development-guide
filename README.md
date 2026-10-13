# 《Blender 开发指南》

一本面向 Blender 插件开发者与源码贡献者的系统开发指南，贯通 Python 插件、原生加速
与 C++ 源码修改三条实践路径。书籍自身版本由
[`book/meta.json`](book/meta.json) 唯一定义；全书的 Blender 版本、分支、标签与 commit 由
[`book/blender-baseline.json`](book/blender-baseline.json) 唯一定义，书稿和检查脚本
读取同一份配置。

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

先准备书稿环境并构建 PDF：

```bash
init-book.bat            # Windows
build-book.bat

./init-book.sh           # macOS / Linux
./build-book.sh
```

`init-book` 会自动下载、校验并安装缺失字体；`build-book` 只做严格预检和编译，不会在
构建过程中联网修改输入。若字体未准备好，构建会停止并提示先运行对应的初始化入口。

需要修改技术内容时，再准备 Blender 源码、依赖和工具链：

```bash
init-blender.bat         # Windows；源码下载到 blender/
build-blender.bat        # 生成 Visual Studio solution 并构建
./init-blender.sh        # macOS / Linux
./build-blender.sh       # 生成 CMake 工程并构建
```

`init-blender` 负责源码、工具链检查，以及官方要求在构建前额外准备的平台依赖；
Git 与 Git LFS 长操作会实时显示进度。
`build-blender` 本身只核验初始化结果、生成工程和编译，不主动执行 `update` 或
Git `fetch`。Windows 上的平台库由 Blender 上游 `make.bat` 自动检测并在需要时询问
下载，因此 `init-blender` 不重复拉取；Linux/macOS 上构建前必须额外准备的库仍由
`init-blender` 处理。
Windows 构建入口仅使用 MSVC，并通过 `vswhere` 自动定位 Visual Studio；可以从普通
`cmd.exe` 启动，不要求预先打开 Developer Command Prompt。
Windows 默认生成并构建 `build_windows/Blender.sln`（新工具链也可能生成 `.slnx`）；
macOS/Linux 默认使用 `build_macos/` 或 `build_linux/`。

提交前运行：

```bash
python qa/check_markdown.py
python qa/check_examples.py
python qa/check_source_refs.py
python tools/build_book.py --check
```

生成对外发布目录：

```bash
build-book-release.bat        # Windows
./build-book-release.sh       # macOS / Linux
```

结果位于 `dist/blender-development-guide/`，顶层严格只有 PDF 与 `examples/`。
发布脚本会先检查书中示例脚注、示例文件和 Python 语法，再构建 PDF；传入 `--check`
还会执行逐页渲染与版心溢出扫描。

## 项目文档

- [书稿规格](doc/BOOK-SPEC.md)：章节结构、内容范围和交付标准。
- [书稿构建与排版](doc/README-BOOK.md)：Typst 环境、字体、排版规则和 PDF 验收。
- [Blender 构建与实证](doc/README-BLENDER.md)：源码、编译、运行测试和截图规范。
- [质量检查](doc/README-QA.md)：稳定检查器、适用边界和不应归档的产物。
- `AGENTS.md`：面向维护者和自动化工具的工程约束，保留在仓库根目录。

## 入口脚本

| Windows | macOS / Linux | 职责 |
|---|---|---|
| `init-book.bat` | `./init-book.sh` | 下载并校验书稿字体、检查 Typst、准备书稿环境 |
| `build-book.bat` | `./build-book.sh` | 只读预检字体并构建、检查 PDF |
| `build-book-release.bat` | `./build-book-release.sh` | 构建仅含 PDF 与 `examples/` 的书籍发布目录 |
| `init-blender.bat` | `./init-blender.sh` | 拉取固定 Blender 源码、检查工具链，并准备官方要求的构建前依赖 |
| `build-blender.bat` | `./build-blender.sh` | 生成 Blender CMake 工程并完成本机构建 |

## 目录概览

```text
README.md                 项目入口
AGENTS.md                 维护与自动化约束
doc/                      项目文档
book/                     Typst 书稿、插图、截图和随书案例
book/examples/            书中明确标注的完整示例源码
qa/                       可重复运行且不生成报告文件的质量检查器
tools/                    初始化、构建、检查和截图工具
blender/                  固定版本的 Blender 源码与预编译库（不入库）
book/build/               PDF 与逐页渲染产物（不入库）
dist/                     对外发布目录（不入库）
build_*/                  Blender 本机构建产物（不入库）
```

所有初始化脚本只向工程目录写入可重新获取的数据，不安装系统工具，也不修改系统环境。
详细边界分别见两份构建文档。

## 验证原则

仓库不归档某次检查的页数、通过数量或问题清单；这些数据会随书稿变化而过期。以当次
检查命令的退出码和输出为准。技术结论即使通过路径检查，也仍需人工阅读源码或运行
Blender 验证。

## 授权

书稿与项目脚本沿用本项目既定授权。引用的 Blender 源码片段遵循 Blender 的
GPL-2.0-or-later；本地 `blender/` 检出目录的授权见其中的 `COPYING`。
