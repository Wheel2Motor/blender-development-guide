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
scons init-blender
```

SCons alias 调用 `tools/init_blender.py`，负责：

- 在 `blender/` 缺失时克隆固定分支并检出基准 commit；
- 允许用 `--mirror` 换主仓库的克隆来源（默认官方），并在克隆前后核验基准分支与提交；
- 把主仓库的 Git LFS 内容（`release/datafiles/startup.blend`、`assets/*.blend` 等）还原成
  实体文件，镜像克隆时从官方补齐；
- 在所有平台准备 `lib/<平台>_<架构>` 预编译库；Windows 也走这条非交互路径（等价于
  `make.bat` 询问时回答 y，自动化会话没有 stdin 也照样成功），`make.bat` 的询问只在库
  仍缺失时才会出现；
- 检查 Git、Git LFS、CMake、Ninja 和编译器；
- 打印调用 `scons build-blender` 的下一步命令。

源码克隆、基准提交获取、主仓库 LFS 还原，以及所有平台（含 Windows）的预编译库都由
这一份跨平台 Python 逻辑统一执行，所以 `scons init-blender` 成功后
`lib/`、LFS、基准 commit 三者都已就绪，`build-blender` 不再需要任何询问。
上述长操作会
直接把 Git 输出透传到当前终端，并强制显示传输进度；每一步开始时会打印实际命令，
结束时会打印成功或失败、退出码与耗时。因此终端长时间没有回到提示符并不再意味着
“无反馈下载”。若克隆失败，脚本会保留不完整目录供排查，不会擅自删除。

脚本不会安装系统工具，也不会自动开始耗时的 Blender 编译。只检查、不下载时使用：

```bash
python tools/init_blender.py --check-only
# 或
scons init-blender --check-only
```

需要临时使用其他源码目录时，可以传入 `--src`；这不会改变项目默认约定：

```bash
python tools/init_blender.py --src "D:/src/blender"
scons init-blender --src=D:/src/blender
python qa/check_source_refs.py --source "D:/src/blender"
```

SCons 的自定义参数必须写成 `--opt=value`，空格分隔会被 SCons 当成缺少参数。

若已有目录的 HEAD 与基准不同，脚本只给出警告，不会覆盖工作树或强制切换版本。

### 源码镜像

官方仓库是 `https://projects.blender.org/blender/blender.git`。网络受限时可以换用镜像。
完整参数以 `scons help` 的 `init-blender options` 一节为准：

```bash
scons init-blender --mirror=official  # 默认：官方主仓库
scons init-blender --mirror=github    # GitHub 官方镜像
scons init-blender --mirror=gitee     # Gitee（码云）国内同步镜像
scons init-blender --mirror-url="https://git.example.com/blender.git"
```

`--mirror` 默认为 `official`，只影响 **主仓库** 的克隆来源，`--check-only`、`--src` 照旧可用；
只在需要克隆时生效，已有检出不会被改写来源。

### 网络重试

所有联网步骤（基准分支探测、克隆、取基准 commit、主仓库 LFS、`lib/` 子模块与其 LFS）
失败后都会自动重试：默认失败后最多再试 **10 次**、每次间隔 **10 秒**。下载是幂等的，
重试只补缺口，不会重复整份传输；克隆重试前会先删掉它自己没下完的目录，不会留下半成品。

```bash
scons init-blender --retries=30 --retry-delay=20   # 网络差时放宽
scons init-blender --retries=0                     # 关闭重试，失败即退出
```

这些步骤之间没有可以安全并行的地方：主仓库 LFS 与 `lib/` LFS 都由同一台
`projects.blender.org` 提供，实测该服务器在约 2 MiB/s 处就是上限（把单连接的
`lfs.concurrenttransfers` 从 32 提到 64 只从 1.6 升到 2.0 MiB/s），两条流同时跑只会
平分同一个上限，还会把两个进度条交织在同一个终端里。真正的顺序依赖也存在：`lib/`
必须先检出子模块才能拉它的 LFS。

- `github` 指向 `blender/blender`。这是官方文档承认的镜像，见
  [Clone & Update](https://developer.blender.org/docs/handbook/contributing/using_git/clone_update/)
  的「GitHub Mirror」一节；已核对该镜像包含本项目基准提交
  `d13f752e3b9c4f8c261cda552b1021f8bcc0382c` 与标签 `v5.2.2`。
- `gitee` 指向 `mirrors/blender`。Gitee（码云）是国内代码托管与协作开发平台；对中国大陆
  网络环境而言，国内链路通常更短，在官方仓库或 GitHub 连接缓慢、频繁中断时值得优先尝试。
  该地址是平台上的同步镜像，分支进度可能与 Blender 官方仓库存在时间差；脚本核对的是基准
  **commit** 而不是把镜像分支顶端当成基准，因此同步差异不会被悄悄忽略。
  同平台上另有 `blender_5/blender`，它停在 `blender-v5.0-release`，不能用于本基准。
  脚本先用 `git ls-remote` 探测基准分支、克隆后再核 `git rev-parse HEAD`，落后时立刻失败
  并提示改用 `--mirror=official`，不会先下完约 1.5 GiB 的主仓库才发现白拉。
- `--mirror-url` 可覆盖任何预设，用于自建镜像或公司内网 GitLab。

镜像状态会随维护者变化，脚本每次运行都重新核验，文档里的结论只代表核对当时的情况。

镜像只换下载地址，**不改变构建方式**：

- 镜像保留的是同一批 commit，`make.bat`、`GNUmakefile`、`build_files/`、`CMakeLists.txt`
  与官方逐字相同（核对时用 `v5.2.2` 的 `BKE_blender_version.h`、`.gitmodules` 与本地检出
  逐条比对过），构建入口仍然是 `scons build-blender`。
- `lib/` 预编译库仍由 `projects.blender.org` 提供：镜像里的 `.gitmodules` 指向
  `https://projects.blender.org/blender/lib-<平台>_<架构>.git`，由 `init-blender` 在所有
  平台按这份配置下载（Windows 上不再依赖 `make.bat` 的交互询问）。
- 主仓库的 Git LFS 对象不在镜像里，而 **构建确实需要它们**：上游 `CMakeLists.txt` 在
  configure 阶段检查 `release/datafiles/startup.blend`，指针文件会让它直接
  `FATAL_ERROR`（"Detected incomplete startup blend"）；图标、画笔、ICC 配置等也会被打进
  产物——这些上游并不检查，只查那一个文件，所以"半个 LFS"能配置通过却产出坏的 Blender。
  `init-blender` 因此 **全量** 核对 `git lfs ls-files` 的每个路径（主仓库与 `lib/` 子模块
  都一样），而不是抽查一两个文件。
- **所有镜像（含官方）** 在克隆与子模块更新阶段都跳过 LFS smudge：逐文件串行 smudge
  实测只有几十 KiB/s，镜像更会直接失败；随后由 `init-blender` 用一次并发
  `git lfs fetch` 补齐（`lfs.concurrenttransfers=32`，实测把
  `projects.blender.org` 从 0.43 MiB/s 提到 1.6 MiB/s；默认 8 个连接）。镜像还要先加
  `lfs-fallback` 远端并 `lfs checkout`。这与上游
  `build_files/utils/make_update.py` 对非上游检出做的 `lfs_fallback_setup()` 一致。
  `build-blender` 在 configure 前再按同一套全量判据核对一次，指到 `init-blender` 而不是把
  上游的 `make update` 报错丢给读者。

镜像不是绕过依赖的捷径：网络受限时，`lib/` 子模块与主仓库的 LFS 数据仍然要走官方服务器，
镜像只省下主仓库的历史对象。

## 四、生成工程并构建 Blender

初始化成功后，在工程根目录运行：

```bash
scons build-blender
```

`build-blender` 项目包装层只读核验源码提交、Git LFS 是否已还原和已有的
`lib/<平台>_<架构>`，自身不会运行 `make update`、`git pull/fetch`、子模块更新或 Git LFS
下载。三者任一没准备好，它会在 configure 之前直接失败并指向 `scons init-blender`，
而不是把上游的询问或 `make update` 报错丢给读者。Windows 上游 `make.bat` 的依赖检查与
懒下载逻辑保持原样，只是库已就绪时它不会再询问。

所有平台都应先运行 `scons init-blender`：它准备源码、主仓库 LFS 与平台预编译库并检查
工具链，完成后 `build-blender` 直接可用。

Windows 先使用 Blender 上游 `make.bat ... nobuild` 生成 out-of-source Visual Studio
CMake 工程，再通过 `cmake --build` 构建 solution 中的 `INSTALL` 目标。默认工程目录为
`build_windows/`，solution 通常是 `Blender.sln`，新版本 Visual Studio/CMake 也可能生成
`Blender.slnx`。Windows 构建入口仅使用 MSVC，会通过 `vswhere` 自动定位 Visual Studio 和
C++ 工具集，因此不要求从 Developer Command Prompt 启动；工具集低于书稿基准要求时
会立即报错并提示更新 Visual Studio。macOS/Linux 则在 `build_macos/` 或 `build_linux/` 中使用
Ninja，找不到 Ninja 时回退到 Unix Makefiles，并通过 CMake 构建 `install` 目标。

Windows 的产物落在 `<构建目录>/bin/<配置>/blender.exe`（例如
`build_windows/bin/Release/blender.exe`）；多配置生成器会把配置名多套一层，包装层在
`INSTALL` 成功后会核对这个可执行文件确实存在，缺失即判失败。

常用参数：

```bash
scons build-blender --configure-only
scons build-blender --blender-config=Debug
scons build-blender --build-dir="D:/build/blender"
scons build-blender -j 12
```

默认拒绝构建与 `book/blender-baseline.json` 不同的提交；只有明确进行本地版本实验时才传
`scons build-blender --allow-other-revision`。脚本不会自动删除或清理已有构建目录；生成器或编译器改变导致
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
