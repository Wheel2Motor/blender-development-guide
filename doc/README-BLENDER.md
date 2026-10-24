# Blender 构建与实证环境

本文档面向修改书中技术内容的维护者，说明如何准备 Blender 源码、构建可运行程序，并用
真实结果支撑正文。只构建或排版书籍不需要这套环境，见
[README-BOOK.md](README-BOOK.md)。

## 一、什么时候需要 Blender 环境

书中 API、结构体字段、源码路径、构建开关、运行行为和界面截图都会随版本变化。路径存在
不代表解释正确，编译通过也不代表运行行为正确。除纯排版修改外，技术内容应形成以下证据链：

1. 在固定版本源码中找到对应实现；
2. 对涉及的代码执行真实构建或最小可运行测试；
3. 涉及界面或交互时，在实际 Blender 中复现并截图；
4. 写入书稿后重新运行源码引用和 PDF 检查。

不得根据函数名、旧教程或记忆推测行为，也不能用“看起来合理”的示例冒充真实 API。

## 二、版本基准

本书技术内容基于 Blender 5.2 LTS。精确版本、分支、标签和提交号只由
`book/blender-baseline.json` 定义。Typst 书稿、初始化脚本、构建脚本和源码引用检查器都
读取这份文件；README 与项目文档不复制具体提交号。

工程默认把维护用源码放在 `blender/`，预编译库位于其 `lib/<平台>_<架构>` 下。这只是
本书工程的内部约定，正文不能假设读者使用相同目录名。

`scons init-blender` 对已有的非基准检出只报告差异，不会覆盖工作树；
`scons build-blender` 和 `scons build-book --check` 默认要求提交号严格匹配。只有明确进行
本地版本实验时，才对 Blender 构建使用 `--allow-other-revision`。

## 三、准备源码、依赖与工具链

在仓库根目录运行：

```bash
scons init-blender
```

该命令负责：

- 在默认目录缺失时克隆源码，并检出配置文件指定的基准；
- 还原主仓库中的 Git LFS 文件；
- 准备当前平台对应的 `lib/` 预编译库及其 LFS 内容；
- 检查 Git、Git LFS、CMake、Ninja 和本机编译器；
- 把 Git 和 Git LFS 的长操作实时输出到当前终端。

初始化成功意味着源码、主仓库 LFS 与平台预编译库已经具备。后续
`scons build-blender` 不再负责下载这些输入，也不依赖上游脚本的交互询问。

初始化脚本不会安装系统工具，也不会自动开始耗时的 Blender 编译。只检查现有状态时使用：

```bash
scons init-blender --check-only
```

需要使用其他源码目录时，可以传入 `--src`：

```bash
scons init-blender --src=D:/src/blender
scons build-blender --src=D:/src/blender
python qa/check_source_refs.py --source D:/src/blender
```

`scons build-book --check` 使用默认的 `blender/` 目录；自定义源码路径的引用检查应直接调用
`qa/check_source_refs.py --source ...`。

### 镜像与 Git LFS

默认主仓库来自 Blender 官方服务。网络不稳定时可以更换主仓库克隆来源：

```bash
scons init-blender --mirror=official
scons init-blender --mirror=github
scons init-blender --mirror=gitee
scons init-blender --mirror-url=https://git.example.com/blender.git
```

- `github` 是 Blender 官方维护的 GitHub 镜像；
- `gitee` 是 Gitee（码云）上的国内同步镜像，在中国大陆网络环境中通常更易连接；
- `--mirror-url` 用于自建镜像或公司内网 Git 服务。

镜像只影响新克隆的主仓库，不会改写已有检出的远端。平台预编译库和主仓库 Git LFS
对象仍由 Blender 官方服务提供，因此镜像不能替代依赖下载，也不改变构建命令。

脚本会在克隆前后核验配置文件指定的分支和提交，避免把同步滞后的镜像分支顶端误当作
书籍基准。它还会检查全部 LFS 跟踪文件，而不只抽查 `startup.blend`；缺失的图标、画笔或
色彩配置即使没有立刻阻止 CMake 配置，也会造成不完整的运行产物。

### 网络重试

联网步骤失败后默认会重试，次数和间隔可调整：

```bash
scons init-blender --retries=30 --retry-delay=20
scons init-blender --retries=0
```

下载步骤是幂等的，重试只补缺口。脚本不会删除已有源码目录；只有某次新克隆由脚本自身
创建且尚未完成时，才会在下一次克隆尝试前清理该半成品。

## 四、生成工程并构建

初始化完成后运行：

```bash
scons build-blender
```

构建包装层先核对源码提交、LFS 内容和平台预编译库，再调用 Blender 上游构建入口生成
out-of-source CMake 工程并编译。任一输入未准备好时，它会在配置前失败并提示重新运行
`scons init-blender`，不会悄悄执行 `git pull`、`make update` 或依赖下载。

| 平台 | 默认生成与构建方式 | 默认构建目录 | 典型产物 |
|---|---|---|---|
| Windows | MSVC、Visual Studio 生成器、`cmake --build` | `build_windows/` | `bin/Release/blender.exe` |
| macOS | Apple Clang、Ninja；缺少 Ninja 时使用 Unix Makefiles | `build_macos/` | `bin/Blender.app` |
| Linux | GCC 或 Clang、Ninja；缺少 Ninja 时使用 Unix Makefiles | `build_linux/` | `bin/blender` |

Windows 入口只使用 MSVC，并通过 `vswhere` 自动定位 Visual Studio 和 C++ 工具集；可以从
普通 `cmd.exe` 启动，不要求预先打开 Developer Command Prompt。生成的工程通常是
`Blender.sln`，新工具链也可能使用 `.slnx`。

常用参数：

```bash
scons build-blender --configure-only
scons build-blender --blender-config=Debug
scons build-blender --build-dir=D:/build/blender
scons build-blender -j 12
```

默认拒绝构建与基准不同的提交。`--allow-other-revision` 只适合明确的本地版本实验；使用它
得到的结果不能直接作为当前书稿的源码证据。脚本不会删除已有构建目录。更换生成器或
编译器导致 CMake 缓存冲突时，应使用新的 `--build-dir`。

源码检出、平台库和构建产物都不进入本书仓库。

## 五、技术内容的验证层级

| 修改类型 | 最低验证要求 |
|---|---|
| 纯文字润色，不改变技术含义 | 核对上下文并构建书稿 |
| 路径、字段、函数签名或行号 | 阅读基准源码，并运行源码引用检查 |
| Python addon、操作符或 UI 示例 | 在基准 Blender 中注册、执行并清理 |
| C/C++ 修改、构建参数或依赖 | 完成对应配置与编译，记录可复现条件 |
| 性能结论 | 使用固定输入测量，不凭主观体验描述 |
| 界面、菜单或交互说明 | 在实际 Blender 中复现并使用实机截图 |

全书 `#src(...)` 引用可以单独检查：

```bash
python qa/check_source_refs.py
```

检查器会核对提交、路径和行号范围，但不能判断正文解释是否正确。技术结论仍需人工阅读
被引代码，并在行为相关场景中运行 Blender。完整的 `scons build-book --check` 会自动执行
同一项检查；普通书籍构建不读取 Blender 源码。

## 六、截图

截图工具位于 `tools/capture_screenshots.py`，需要图形界面和可运行的基准 Blender。原始
截图写入 `book/res/`，但自动采集成功不代表内容正确，仍需人工确认：

- 窗口、工作区和面板处于正文描述的状态；
- 关键控件、菜单和提示文字完整可见；
- 截图优先裁到相关区域，避免窗口过大导致 Blender 内文字过小；
- 截图中的版本行为与当前技术基准一致。

不得用示意图冒充实际运行截图。若只能使用示意图，图注必须明确说明。

## 七、完成标准

一次技术内容修改至少应满足：

1. 源码位于书籍基准提交，或明确标明只是其他版本的本地实验；
2. 相关源码事实已经人工核对；
3. 需要编译或运行的示例已经真实执行；
4. 界面和交互说明已经在实际程序中复现；
5. `scons build-book --check` 通过，受影响页面已经人工检查。

## 八、升级 Blender 基准

升级基准不是替换版本字符串。应按以下顺序处理：

1. 更新 `book/blender-baseline.json` 中的版本、分支、标签和提交字段；
2. 准备对应提交的干净源码和可运行构建；
3. 运行源码引用检查，修复失效路径与行号；
4. 逐章复核 API、字段、统计数字、构建命令和版本行为；
5. 重新执行完整示例并重截受影响的界面图片；
6. 构建并完整检查书稿。

配置文件解决的是基准信息的单点维护，不能让正文自动适配新版本。书中作为兼容性案例出现
的旧版本号、文件格式版本和历史行为必须按语义判断是否保留。
