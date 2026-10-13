# Blender 构建与实证环境

本文档说明书稿维护者如何准备 Blender 源码、构建可运行程序，并用真实结果支撑书中
内容。Typst 书稿的构建方式见 [README-BOOK.md](README-BOOK.md)。

## 一、为什么书稿开发需要 Blender

书中包含大量随版本变化的技术事实：API 名称、结构体字段、源码路径、构建开关、运行
行为、性能表现和界面截图。路径存在不等于解释正确，编译通过也不等于运行行为正确。

除纯排版修改外，维护者必须具备以下证据链：

1. 在固定版本源码中找到对应实现；
2. 对修改涉及的代码执行真实构建或最小可运行测试；
3. 涉及界面或交互时，在实际 Blender 中复现并截图；
4. 将结论写入书稿后，重新运行源码引用与 PDF 检查。

不得根据函数名、旧教程或记忆推测行为，也不得用“看起来合理”的示例冒充真实 API。

## 二、固定版本

本项目的唯一机器可读基准是 `book/blender-baseline.json`：

| 项目 | 含义 |
|---|---|
| `version` / `version_series` | 完整版本号与主次版本系列 |
| `version_suffix` / `tag` | 版本后缀与发布标签 |
| `branch` | 维护者使用的上游分支 |
| `commit` | 所有源码路径和行号所钉住的完整提交号 |
| 默认源码目录 | `blender/` |
| 预编译库 | `blender/lib/<平台>_<架构>` |

Typst 从 `common.typ` 读取该 JSON 并导出 `blender-version`、`blender-branch`、
`blender-commit` 等变量；`tools/init_blender.py` 与 `qa/check_source_refs.py` 也读取
同一文件。不要在脚本中另建一份常量。

正文不能假设读者使用了 `blender/` 这个目录名；它只是本书工程内部的维护约定。

## 三、初始化源码与工具链

在工程根目录运行：

```bash
init-blender.bat         # Windows
./init-blender.sh        # macOS / Linux
```

入口脚本调用 `tools/init_blender.py`，负责：

- 在 `blender/` 缺失时克隆固定分支并检出基准 commit；
- 在 Linux/macOS 上初始化官方要求于构建前额外准备的 Git LFS 预编译库子模块；
- 在 Windows 上不重复拉取平台库，保留 Blender 上游 `make.bat` 的自动检测和懒下载；
- 检查 Git、Git LFS、CMake、Ninja 和编译器；
- 打印调用 `build-blender.bat` / `.sh` 的下一步命令。

源码克隆、基准提交获取，以及需要额外执行的子模块初始化和 Git LFS 下载由这一份
跨平台 Python 逻辑统一执行。Windows 平台库属于上游构建脚本能自行处理的情况，
项目初始化层不介入。上述长操作会
直接把 Git 输出透传到当前终端，并强制显示传输进度；每一步开始时会打印实际命令，
结束时会打印成功或失败、退出码与耗时。因此终端长时间没有回到提示符并不再意味着
“无反馈下载”。若克隆失败，脚本会保留不完整目录供排查，不会擅自删除。

脚本不会安装系统工具，也不会自动开始耗时的 Blender 编译。只检查、不下载时使用：

```bash
python tools/init_blender.py --check-only
```

需要临时使用其他源码目录时，可以传入 `--src`；这不会改变项目默认约定：

```bash
python tools/init_blender.py --src "D:/src/blender"
python qa/check_source_refs.py --source "D:/src/blender"
```

若已有目录的 HEAD 与基准不同，脚本只给出警告，不会覆盖工作树或强制切换版本。

## 四、生成工程并构建 Blender

初始化成功后，在工程根目录运行：

```bash
build-blender.bat         # Windows
./build-blender.sh        # macOS / Linux
```

`build-blender` 项目包装层只读核验源码提交和已有的 `lib/<平台>_<架构>`，
自身不会运行 `make update`、`git pull/fetch`、子模块更新或 Git LFS 下载。但
Windows 上 Blender 上游 `make.bat` 自带依赖检查与懒下载逻辑；这是上游
构建流程的一部分，项目包装层不屏蔽其询问或改变其行为。

所有平台仍应先运行 `init-blender`来准备源码并检查工具链。Linux/macOS 的官方
流程另外要求在构建前准备预编译库，这一前置步骤才由 `init-blender` 完成。

Windows 先使用 Blender 上游 `make.bat ... nobuild` 生成 out-of-source Visual Studio
CMake 工程，再通过 `cmake --build` 构建 solution 中的 `INSTALL` 目标。默认工程目录为
`build_windows/`，solution 通常是 `Blender.sln`，新版本 Visual Studio/CMake 也可能生成
`Blender.slnx`。Windows 构建入口仅使用 MSVC，会通过 `vswhere` 自动定位 Visual Studio 和
C++ 工具集，因此不要求从 Developer Command Prompt 启动；工具集低于书稿基准要求时
会立即报错并提示更新 Visual Studio。macOS/Linux 则在 `build_macos/` 或 `build_linux/` 中使用
Ninja，找不到 Ninja
时回退到 Unix Makefiles，并通过 CMake 构建 `install` 目标。

常用参数：

```bash
build-blender.bat --configure-only
build-blender.bat --config Debug
build-blender.bat --build-dir "D:/build/blender"
./build-blender.sh --jobs 12
```

默认拒绝构建与 `book/blender-baseline.json` 不同的提交；只有明确进行本地版本实验时才传
`--allow-other-revision`。脚本不会自动删除或清理已有构建目录；生成器或编译器改变导致
CMake 缓存冲突时，应改用新的 `--build-dir`，不要让自动化擅自删除本地构建结果。

构建产物、源码检出和预编译库均不应提交到本仓库。

## 五、内容修改的验证层级

| 修改类型 | 最低验证要求 |
|---|---|
| 纯文字润色，不改变技术含义 | 核对上下文并构建书稿 |
| 路径、字段、函数签名或行号 | 阅读基准源码，运行 `qa/check_source_refs.py` |
| Python 插件、操作符或 UI 示例 | 在基准 Blender 中注册、执行并清理 |
| C/C++ 修改、构建参数或依赖 | 完成对应配置与编译，记录实际命令和结果 |
| 性能结论 | 使用可复现输入进行测量，不凭主观体验描述 |
| 界面、菜单或交互说明 | 在实际 Blender 中复现并使用实机截图 |

截图工具位于 `tools/capture_screenshots.py`。它需要 GUI，并把原始截图写入
`book/res/`；截图后仍需人工确认目标面板、状态和文字与正文一致。

## 六、源码核对

全书 `#src(...)` 引用通过以下命令验证路径与行号：

```bash
python qa/check_source_refs.py
```

检查器会确认 `blender/` 的 commit、引用路径和行号范围，但不会判断正文解释是否正确。
技术结论仍需人工阅读被引代码，并在行为相关场景中运行 Blender。

## 七、完成标准

一次技术内容修改至少应满足：

1. Blender 源码位于基准 commit，或明确说明验证的是其他版本；
2. 相关源码事实经过人工核对；
3. 需要编译或运行的示例已经真实执行；
4. 截图来自实际程序状态，不是示意图冒充实测；
5. 源码引用检查和书稿完整检查均通过。

## 八、升级 Blender 基准

版本跟进不是替换几个字符串。升级时按以下顺序处理：

1. 修改 `book/blender-baseline.json` 中的全部字段；
2. 准备对应 commit 的干净源码和可运行构建；
3. 运行 `qa/check_source_refs.py`，修复失效路径与行号；
4. 逐章复核 API、字段、统计数字、构建命令和版本行为；
5. 重新执行代码案例并重截受影响的界面图片；
6. 构建并完整检查书稿。

书中作为兼容性案例出现的旧版本号、文件格式版本和章节编号不应机械替换。配置变量只
消除“当前核对基准”的重复定义，不代表技术内容会自动适配新版本。
