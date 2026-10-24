# 《Blender 开发指南》

这是一本面向 Blender 插件开发者和源码贡献者的中文技术书。内容从 Python 插件开发
开始，逐步延伸到原生库加速、Blender C/C++ 源码阅读与修改，以及测试和上游贡献。
目标读者应具备 Python 或 C/C++ 基础，但不需要事先了解 Blender 的内部架构。

本仓库保存书稿、插图、随书示例和构建工具。默认产物是 PDF；实验性 HTML 用于本地
预览。对外发布目录只包含 PDF 与 `examples/`，不会混入字体、构建缓存或维护脚本。
书中技术内容以 Blender 5.2 LTS 为核对基准。

## 从这里开始

### 只构建书籍

准备 Python、SCons 和 Typst 后，在仓库根目录运行：

```bash
scons init-book
scons build-book
```

`init-book` 会在项目字体目录为空时下载默认 Noto 字体，并准备构建目录和 CeTZ 宏包
缓存；已有字体文件会直接使用，不校验哈希或版本。`build-book` 不会临时下载或修复
字体。生成的 PDF 位于
`book/build/blender-development-guide.pdf`。

网络状况可能导致默认字体拉取失败。此时可以自行下载 Typst 支持的 `.ttf`、`.otf`、
`.ttc` 或 `.otc` 字体并放入 `book/fonts/`，再在 `book/fonts/noto.json` 中填写字体的
内部 family name；文件名可以不同。也可以完全跳过项目字体：

```bash
scons init-book --use-system-fonts
scons build-book --use-system-fonts
```

系统字体的授权因操作系统和字体而异，本机预览通常不等于允许嵌入 PDF 或对外再分发。
使用前应自行核对许可；系统字体模式不得用于正式发布。

普通书籍构建不需要 Blender 源码，也不会访问 `blender/`。如果你只想阅读、排版或生成
PDF，到这里就足够了。

常用的其他构建方式：

```bash
scons build-book --use-system-fonts  # 使用本机字体临时预览
scons build-book --format=html       # 生成实验性 HTML
scons build-book --release           # 生成 PDF + examples/ 发布目录
```

系统字体模式不保证不同机器上的分页一致，也可能涉及系统字体许可，因此不能用于正式发布。
HTML 输出由 `book/build/blender-development-guide.html` 与同级 `res/` 资源目录共同组成。

### 修改技术内容

书中大量内容依赖真实的 Blender 版本：API、源码路径、构建命令、运行行为和截图都不能
凭印象编写。修改这些内容前，需要额外准备源码和可运行程序：

```bash
scons init-blender
scons build-blender
```

`init-blender` 负责取得固定版本的源码、还原 Git LFS 内容、准备当前平台的预编译库并
检查工具链；`build-blender` 只核验现有输入、生成 CMake 工程并构建，不主动更新源码或
下载依赖。

官方仓库连接不稳定时，可以改用 GitHub 官方镜像或 Gitee（码云）同步镜像：

```bash
scons init-blender --mirror=github
scons init-blender --mirror=gitee
```

镜像只改变主仓库的克隆来源。平台预编译库和 Git LFS 数据仍来自 Blender 官方服务，
构建方式不变。完整说明见 [Blender 构建与实证环境](doc/README-BLENDER.md)。

### 运行完整检查

提交书稿改动前运行：

```bash
python qa/check_markdown.py
python qa/check_examples.py
scons build-book --check
```

`build-book --check` 面向书稿维护者：它要求默认的 `blender/` 检出处于书籍固定提交，
先检查全部源码引用，再构建 PDF、逐页渲染并扫描版心溢出。普通 `build-book` 不执行这些
源码检查，二者的使用边界是有意区分的。

需要同时生成发布目录时使用：

```bash
scons build-book --release --check
```

## 项目文档

不同文档各自回答一个问题：

| 文档 | 内容 |
|---|---|
| [书稿规格](doc/BOOK-SPEC.md) | 本书面向谁、覆盖什么、如何组织，以及完成标准 |
| [书稿构建与排版](doc/README-BOOK.md) | Typst 环境、字体、PDF/HTML 构建、排版和视觉验收 |
| [Blender 构建与实证环境](doc/README-BLENDER.md) | 固定版本源码、依赖、编译、运行验证和截图 |
| [质量检查](doc/README-QA.md) | 各检查器的职责、依赖和适用场景 |
| [发布说明](RELEASE_NOTE.md) | 已发布版本与下一版本的待发布改动 |
| [待办事项](TODO.md) | 尚未完成的书稿工作 |

`AGENTS.md` 保存面向维护者和自动化工具的工程约束，不是普通读者的入门文档。

## 命令概览

所有跨平台入口都由根目录的 `SConstruct` 提供。`scons help` 是命令和参数的权威列表。

| 命令 | 用途 |
|---|---|
| `scons init-book` | 检查书稿工具并准备项目字体和 CeTZ 缓存 |
| `scons build-book` | 构建 PDF，或通过 `--format=html` 构建实验性 HTML |
| `scons init-blender` | 准备固定版本的 Blender 源码、LFS 内容、预编译库和工具链 |
| `scons build-blender` | 生成并构建本机 Blender 工程 |
| `scons bump-version` | 提升书籍版本并迁移 Pending 发布说明 |
| `scons help` | 显示全部命令、参数和示例 |

SCons 只负责编排，实际逻辑位于 `tools/` 下的 Python 脚本中。自定义参数建议写成
`--opt=value`，例如 `--src=D:/src/blender`；完整参数不要在 README 中重复维护，以
`scons help` 为准。

## 版本与核对基准

书籍版本和 Blender 技术基准是两套独立信息：

- `book/meta.json` 只记录书籍版本，并显示在封面上；
- `book/blender-baseline.json` 记录全书核对使用的 Blender 版本、分支、标签和提交号；
- `RELEASE_NOTE.md` 记录已发布版本和 `Pending` 改动。

这些文件是维护阶段的统一数据源，不是读者构建书籍前需要理解的配置。README 和项目
文档不复制具体提交号；需要确认当前基准时，应直接读取 `book/blender-baseline.json`。
发布新书稿时，先更新 `Pending`，再运行 `scons bump-version --major`、`--minor` 或
`--micro` 中恰好一个。升级 Blender 基准则必须重新核对源码引用、技术结论、示例和截图，
不能只替换版本字符串。

## 环境边界

初始化脚本可以下载工程内部、可重新获取的数据：

- 项目字体写入 `book/fonts/`；
- Blender 源码、Git LFS 内容和平台预编译库写入 `blender/`；
- CeTZ 由 Typst 写入自己的包缓存。

脚本不会安装 Python、SCons、Typst、Git、CMake、Ninja 或编译器，不会调用系统包管理器，
也不会修改系统环境。必需工具缺失时会给出安装指引并退出。`build-book` 和
`build-blender` 都不会把下载动作隐藏在构建过程中；需要准备输入时应先运行对应的
`init-*` 命令。

## 仓库结构

```text
README.md                 项目入口
RELEASE_NOTE.md           已发布版本与 Pending 改动
SConstruct                跨平台命令入口
doc/                      规格、构建和质量文档
book/                     Typst 书稿、图表、截图与随书示例
book/examples/            对外发布的完整示例源码
qa/                       可重复运行的质量检查器
tools/                    初始化、构建、版本和截图工具
blender/                  固定版本的 Blender 源码与依赖（不入库）
book/build/               书籍构建产物（不入库）
dist/                     对外发布目录（不入库）
build_*/                  Blender 本机构建产物（不入库）
```

仓库不保存某次检查的日志、统计快照或一次性报告。检查结果应以当次命令的退出码和终端
输出为准；路径检查通过也不能代替人工阅读源码和实际运行验证。

## 授权

本仓库内容依据 [LICENSE](LICENSE) 中的 GPL-3.0 许可发布。项目字体和其他第三方资源
分别遵循其随附许可；引用的 Blender 源码片段遵循 Blender 的 GPL-2.0-or-later。
