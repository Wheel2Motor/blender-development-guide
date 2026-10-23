#import "../common.typ": *
#import "../figures/build-flow.typ": fig-build-flow

= 第 2 章 不同平台的开发环境与构建

第 1 章给出了源码地图，本章把这张地图变成一套可执行的构建流程：准备工具，获取源码与
依赖，完成配置和构建，最后启动自己编译的 Blender。不同平台共用同一套 CMake 工程，
差别主要集中在构建入口、编译器、平台依赖和产物形态。

Blender 的构建耗时较长，工具版本或依赖出错会显著放大试错成本。更重要的是，构建流程会
随版本演进；例如 Windows 使用 `make.bat` 而不是 GNU Make，当前预编译库通过 Git 子模块
和 Git LFS 获取，macOS 也不再提供 `lib/macos_x64`。因此，本章以书中核对的 Blender
版本为准，并在关键结论后标出对应源码位置。读者只需先抓住“准备 → 更新 → 配置 → 构建 →
运行”这条主线；完整命令和平台差异分别集中在附录 C、D，排错方法集中在附录 E。

== 2.1 通用工具链

不同平台的构建系统使用同一套 CMake 工程，差别只在外层的驱动脚本和预编译库。
所以先把平台无关的部分讲完。

=== 2.1.1 工具与最低版本

#figure(
  kind: table,
  table(
    columns: (0.9fr, 1.5fr, 1.3fr, 1.4fr),
    inset: 5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*工具*], [*用途*], [*最低要求*], [*源码里的依据*]),
    [Git],
    [克隆源码、更新分支、驱动子模块],
    [任意近期版本],
    [`build_files/utils/make_update.py`],
    [Git LFS],
    [拉取预编译库与主仓库的 LFS 对象],
    [与 Git 配套],
    [`make_update.py:157-160`],
    [CMake],
    [生成构建系统],
    [`3.21`],
    [`CMakeLists.txt:29`],
    [Ninja],
    [推荐的后端构建工具（可选但强烈建议）],
    [任意近期版本],
    [`configure_ninja.cmd:1-5`],
    [Python],
    [运行更新脚本与构建辅助工具；配置、编译阶段优先使用 `lib/` 随附的 Python],
    [#mac #linux 首次更新需要系统 Python 3；\
      预编译库随附 Python `3.13`],
    [`GNUmakefile:229-262`、\
      `CMakeLists.txt:1415-1419`],
    [#linux 编译器],
    [GCC / Clang],
    [`14.0.0` / `17.0`],
    [`CMakeLists.txt:107-133`],
    [#win 编译器],
    [本书只采用 MSVC；上游另有 `clang` 开关，但不属于本书验证路径],
    [VS2022 `17.14.14`],
    [`CMakeLists.txt:134-141`、\
     `platform_win32.cmake:42-46`],
    [#mac 编译器],
    [Apple clang（需要 Xcode 命令行工具）],
    [Xcode / CLT `16.0`；\
     最低部署目标 macOS 11.2],
    [`platform_apple_xcode.cmake:18-21`、\
     `:159-163`],
  ),
  caption: [构建 Blender 所需的通用工具与不同平台的编译器要求。],
) <tbl-toolchain>

关于 Python，有一个必须澄清的常见误解：*预编译库里的 Python 与系统 Python
承担的是不同阶段的工作*。

- 配置、编译和多数构建辅助步骤优先使用 `lib/` 预编译库中随附的 Python。以 #win 为例，
  脚本按固定路径查找 `lib\windows_x64\python\313\bin\python.exe`，
  找不到时再尝试 `311`（#src("build_files/windows/find_dependencies.cmd:5-23")）；
  POSIX 侧由 `GNUmakefile` 从 `lib/<平台>_<架构>/python/bin/` 下依次探测
  `3.15` 到 `3.10`（#src("GNUmakefile:229-262")）。
- 但在预编译库还没下载时，#mac #linux 上的 `GNUmakefile` 会回退到系统的
  `python3`，再找不到才尝试 `python`（#src("GNUmakefile:247-256")）。因此这两个平台
  首次运行 `make update` 前必须保证 Python 3 可用；#linux 的系统依赖安装助手本身也由
  Python 运行。
- #win 的引导路径不同：`make.bat update` 会先下载预编译库
  （其中包含 Python），再调用需要 Python 的更新脚本（#src("make.bat:82-98")）。
  若你在库没下完时中断，随后执行 `make_update.py` 会得到
  `python not found, required for this operation`
  （#src("build_files/windows/update_sources.cmd:1-4")）。

Blender 5.2 在 #win 上要求 *VS2022 17.14.14* 或更新版本。`make.bat` 仍保留较旧的
Visual Studio 年份开关，但旧工具集最终会被 CMake 以 `Compiler is unsupported` 拒绝
（#src("build_files/cmake/platform/platform_win32.cmake:42-45")）。因此不要根据开关名
判断兼容性，应以当前源码中的编译器检查为准。

=== 2.1.2 CMake 必须懂的四件事

你不需要会写 CMake，但必须理解四个概念，否则配置失败的输出对你就是天书。
好消息是这四个概念在 Blender 的构建里都有非常干净的实例。

- *目标（target）* 是 CMake 的构建单位：一个可执行文件、一个静态库、
  一个自定义命令。CMake 顶层通过 `add_subdirectory()` 把 `intern/`、`extern/`、
  `source/` 挂进来（#src("CMakeLists.txt:2434-2446")），`source/creator/` 里定义了
  `blender` 这个可执行目标。你日常说的"重编一下"，本质就是"重新构建 `blender`
  这个目标及其依赖"；理解了这一点，`ninja blender`（只构建主程序）与
  `ninja install`（构建并安装）的区别也就清楚了。

- *生成器（generator）*。CMake 自己不编译，它只*生成*另一套构建系统。生成器分两类：

  #figure(
    kind: table,
    table(
      columns: (0.9fr, 1.2fr, 1.2fr, 1.6fr),
      inset: 5.5pt,
      align: (left, left, left, left),
      stroke: 0.4pt + luma(78%),
      table.header([*类别*], [*典型生成器*], [*构建类型怎么给*], [*Blender 里的表现*]),
      [单配置],
      [`Ninja`、`Unix Makefiles`],
      [配置时定死：\
       `-DCMAKE_BUILD_TYPE=Release`],
      [产物直接在 `bin/` 下；\
       换构建类型要换构建目录],
      [多配置],
      [`Visual Studio …`、`Xcode`],
      [构建时给：\
       `--config Release` / `-C Release`],
      [产物在 `bin/Release/` 或 \
       `bin/Debug/` 下；\
       一个构建目录可容纳多种类型],
    ),
    caption: [单配置与多配置生成器的区别。这张表能解释本章后面几乎所有"路径为什么不一样"的问题。],
  ) <tbl-generators>

  Blender 的 CMake 明确处理了这两种情况：它用 `GENERATOR_IS_MULTI_CONFIG`
  判断当前生成器，然后把安装前缀里的 `${BUILD_TYPE}` 替换成 `$<CONFIG>`
  或者空字符串（#src("CMakeLists.txt:1236-1268")）。所以同一个 `bin/`，
  在 Ninja 下就是 `<构建目录>/bin/blender.exe`，在 VS 生成器下变成
  `<构建目录>/bin/Release/blender.exe` —— 后者正是
  #src("build_files/windows/find_blender.cmd:6-23") 要依次尝试两个路径的原因。

- *缓存*。CMake 把上一次配置的所有变量写进构建目录的 `CMakeCache.txt`。
  这就是为什么*改变配置后必须重新配置*，也是为什么"删掉构建目录重来"
  永远是排查构建问题的万能第一步。`GNUmakefile` 在构建成功后会提示你
  `Edit build configuration with: "<BUILD_DIR>/CMakeCache.txt"`（#src("GNUmakefile:410")）。

- *配置项（option）*。Blender 把可选功能全部做成了 `option(WITH_...)` 变量，
  例如 `WITH_GTESTS`（#src("CMakeLists.txt:778")）、`WITH_GHOST_X11` 与
  `WITH_GHOST_WAYLAND`（#src("CMakeLists.txt:343-348")）、
  `WITH_LIBS_PRECOMPILED`（#src("CMakeLists.txt:522-528")）、
  `WITH_INSTALL_PORTABLE`（#src("CMakeLists.txt:546-551")）。
  在命令行用 `-DWITH_XXX=ON` 覆盖，在缓存里改也可以。想知道全部可选项，
  执行 `make help_features`（#src("GNUmakefile:667")）。

#tip[
  一个立刻能用的判断法：*看到 `WITH_` 开头的全部大写下划线标识符，
  它就是 `-D` 可以直接改的配置项。* 看到 `CMAKE_` 开头的，多半是 CMake
  自身的通用变量。这两类名字在报错信息里出现频率最高。
]

=== 2.1.3 CMake 的三个开关：`-G`、`-D`、`-C`

Blender 的构建脚本本质上就是在拼一条 `cmake` 命令。你会在三个地方反复看到它们：

- `-G "<生成器>"` 指定生成器。Windows 的 Ninja 路径写的是
  `-G "Ninja"`（#src("build_files/windows/configure_ninja.cmd:7")），
  MSBuild 路径写的是 `-G "Visual Studio 17 2022"` 这样的形式
  （#src("build_files/windows/configure_msbuild.cmd:41")）；
  POSIX 侧由 `GNUmakefile` 在 `ninja` 目标下追加 `-G Ninja`
  （#src("GNUmakefile:325-328")）。
- `-D<变量>=<值>` 直接设置缓存变量，比如 `-DWITH_COMPILER_ASAN=On`、
  `-DWITH_WINDOWS_SCCACHE=On`（#src("build_files/windows/configure_ninja.cmd:9-26")）。
- `-C<初始缓存文件>` 先加载一份预置的配置脚本，再处理命令行。这就是
  `blender_lite.cmake`、`blender_developer.cmake` 这类"预设档"的加载方式。
  下一节会给出完整的对照表。

另外两个参数在 Blender 的脚本里也能看到：`-H<源码目录>` 与 `-B<构建目录>`
（#src("build_files/windows/configure_ninja.cmd:46-49")）。它们分别指定源码与
构建目录，等价于现代写法 `-S` 与 `-B`。

#warn[
  *Blender 不允许在源码目录内构建。* 一旦 `CMAKE_SOURCE_DIR` 等于
  `CMAKE_BINARY_DIR`，CMake 会直接 `FATAL_ERROR` 并提示你换目录
  （#src("CMakeLists.txt:8-27")）。强制绕过它的开关叫 `WITH_IN_SOURCE_BUILD`，
  源码注释里的原话是"不推荐"。#win 上 `make.bat` 帮你处理了这一点
  （默认构建目录在源码上一级的 `..\build_windows`），POSIX 上
  `make` 的默认构建目录同样在源码上一级（#src("GNUmakefile:208-210")）。
]

=== 2.1.4 构建入口：POSIX 用 `make`，Windows 用 `make.bat`

Blender 源码根目录有三个与构建直接相关的入口：
`CMakeLists.txt`（CMake 工程本身）、`GNUmakefile`（POSIX 便捷入口）、
`make.bat`（Windows 便捷入口）。

`GNUmakefile` 明确拒绝 Windows（#src("GNUmakefile:175-179")），Windows 平台配置也只接受
MSVC（#src("build_files/cmake/platform/platform_win32.cmake:9-11")）。因此：

- #win 在 `cmd.exe` 中执行 `make.bat`，在 PowerShell 或 Git Bash 中执行
  `./make.bat`。不要用 GNU Make、GCC 或 MinGW 构建 Blender 本体。#footnote[
    Blender 构建依赖库时可能自动准备 MSYS2，用它提供 `perl` 等辅助工具；这不意味着
    Blender 本体支持用 MinGW 编译，见
    #src("build_files/build_environment/cmake/setup_msys2.cmake:7-11")。
  ]
- #mac #h(0.3em) #linux 执行 `make`。它会调用 CMake 和选定的后端，并默认完成
  `install` 目标（#src("GNUmakefile:395-416")）。

== 2.2 获取源码与依赖

=== 2.2.1 克隆源码

Blender 官方仓库在 `projects.blender.org`。要拿到本书的核对基准（#blender-version），
直接克隆发布分支：

#raw(
  "$ git clone https://projects.blender.org/blender/blender.git\n"
  + "$ cd blender\n"
  + "$ git switch --detach " + blender-tag + "\n"
  + "$ git rev-parse HEAD\n"
  + blender-commit,
  block: true,
  lang: "bash",
)

如果你要跟随上游开发，用默认的 `main` 分支即可。这里不需要
`--recurse-submodules`：*预编译库子模块在 `.gitmodules` 里全部被标记为不自动更新*
（见下一节），克隆时它们不会被动，这是有意设计的。

发布分支 HEAD 以后还可能前进，不能永久锁定本书的核对基准，所以这里检出固定标签并
核对完整提交号。如果要在这份源码上提交自己的修改，再从标签创建工作分支，例如
`git switch -c my-blender-work`。如果你的目标是持续跟随 5.2 后续维护更新，
才使用 #raw(blender-branch) 分支；那时源码可能已经不再与本书逐行一致。

本书的核对基准是 commit #raw(blender-commit)，
分支 #raw(blender-branch)，版本号 #blender-version
（#src("source/blender/blenkernel/BKE_blender_version.h:23-29")，
其中 `BLENDER_VERSION_SUFFIX` 为 `LTS`）。行号对应这一版；
你的版本如果不同，请以同名符号为准检索。

#tip[
  本章正文只使用 Blender 官方主仓库，确保命令与官方文档及 Git LFS 服务保持一致。
  如果所在网络连接官方仓库不稳定，可以改用镜像；中国大陆网络环境通常值得优先尝试
  Gitee（码云）上的国内同步镜像。镜像地址、同步状态核验与 LFS 回退流程见附录 E.1.1。
]

==== 先理解 Git LFS：Git 里存指针，LFS 服务存实体

如果你过去主要使用 SVN，只会 Git 的 `clone`、`pull`、`commit` 等基本操作，
这里很容易产生误解。*Git LFS（Large File Storage）不是另一个源码仓库，也不是 Git
子模块*；它是 Git 的大文件扩展。普通 Git 很适合保存源码和文本差异，却不适合在每次提交中
直接塞入不断变化的巨大二进制文件。Git LFS 因而把一个大文件拆成两部分：

#figure(
  kind: table,
  table(
    columns: (1.05fr, 1.75fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*位置*], [*实际保存的内容*]),
    [Git 仓库的 commit / tree],
    [文件路径和一小段 LFS 指针文本；指针记录实体文件的 SHA-256 标识与字节数],
    [远端 Git LFS 服务],
    [真正的 `.blend`、图片、测试文件、预编译库等二进制字节],
    [本机 Git 元数据目录下的 `lfs/objects/`],
    [已经下载的 LFS 实体文件缓存；重试和切换分支时可以复用已完成的对象],
    [本机工作区],
    [正常情况下是可直接使用的实体文件；未下载成功或主动跳过还原时才会露出指针文本],
  ),
  caption: [Git 仓库、LFS 服务、本地缓存与工作区的关系],
) <tbl-git-lfs-storage>

Git 仓库里保存的不是一个含糊的“下载地址”，而是规范化的三行指针。例如一个
12,345 字节的文件在 commit 中可能对应：

```text
version https://git-lfs.github.com/spec/v1
oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
size 12345
```

`oid` 是实体内容的 SHA-256 标识；内容一变，`oid` 就会变，所以 Git 的 commit 仍能精确
固定“这个路径在这一版应该对应哪个大文件”。指针格式和过滤过程见
#weblink("https://github.com/git-lfs/git-lfs/blob/main/docs/spec.md", label: [Git LFS 官方规范])。

可以把它与 SVN 做一个近似比较：SVN 用户通常认为“版本记录和文件实体都从同一个仓库的
`checkout` / `update` 得到”；Git LFS 则把它拆成*先取 Git 历史与指针，再按指针取大文件
实体*两次传输。安装 Git LFS 后，这两步通常被过滤器自动串起来，所以一次 `git clone`
看起来仍像拿到了完整文件：checkout 遇到指针时，`smudge` 过滤器从 LFS 服务下载实体并
放进工作区。若使用 `GIT_LFS_SKIP_SMUDGE=1` 跳过这一步，工作区里暂时只剩指针；随后执行
`git lfs pull`，才会下载当前版本需要的对象并把指针替换为实体文件。Git LFS 官方手册也把
这种关系概括为“Git 仓库存指针，LFS 服务存内容”
（#weblink("https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs.adoc", label: [git-lfs(1)])）。

书中核对的版本有 6,671 个 LFS 路径，其中绝大多数位于 `tests/files/`；
`release/datafiles/`、`assets/` 等目录则包含启动文件、图标、画笔、色彩配置与应用模板。
这些数字用于说明规模，不应被当作其他版本的固定清单。#footnote[
  核对版本中，`tests/files/` 有 6,311 个 LFS 路径，`release/datafiles/` 有 197 个，
  `release/windows/` 有 137 个，其余 26 个分布在 `assets/`、`release/darwin/`、
  `scripts/startup/` 和文档资源中。升级版本后应重新执行 `git lfs ls-files` 统计。
]

这里还要把两个容易混淆的层次彻底分开：

- Blender 的 C/C++、Python、CMake 等源码绝大多数是*普通 Git 文件*；LFS 不是源码的另一份副本。
- `lib/<平台>_<架构>` 是*独立 Git 仓库组成的子模块*。主仓库只记录每个子模块应检出的
  commit，类似 SVN 使用者熟悉的 `svn:externals`；进入子模块以后，其中庞大的静态库、
  动态库、SDK 与工具又由该子模块自己的 Git LFS 管理。

因此一次完整的 Blender 初始化同时涉及三件事：克隆主源码仓库、还原主仓库的 LFS 文件、
检出本机平台的 `lib/` 子模块并还原它自己的 LFS 文件。只完成第一件事，目录看似完整，
实际上还不能可靠构建。

=== 2.2.2 四个预编译库子模块

Blender 不想让每个开发者都从零编译 100 多个第三方库，所以它把预编译结果
放在四个独立仓库里，通过 Git 子模块挂进 `lib/`。完整清单就在
#src(".gitmodules:1-20")，形式统一为 `lib/<平台>_<架构>` 对应
`https://projects.blender.org/blender/lib-<平台>_<架构>.git`，
分支都是 #raw(blender-branch)：

- `lib/linux_x64`
- `lib/macos_arm64`
- `lib/windows_x64`
- `lib/windows_arm64`

注意只有这四个 —— *没有 `macos_x64`，也没有 `linux_arm64`*。

三点需要展开。

第一，*四个子模块在 `.gitmodules` 里都标着 `update = none`*
（#src(".gitmodules:1-20")）。这意味着即使你
`git submodule update --init --recursive` 也不会碰它们。真正启用某个子模块的是
更新脚本：它先执行 `git config --local submodule.<路径>.update checkout`
把 `none` 改成 `checkout`，再更新这个子模块
（#src("build_files/utils/make_utils.py:227-235")）。你不需要手动做这件事，
但把 `make update` 的输出读一遍会看到
`* Enabling precompiled libraries at lib/windows_x64` 这样的行
（#src("build_files/utils/make_update.py:240-241")）。

第二，*没有 `macos_x64` 子模块，这是有意的。* 更新脚本对 `macos` + `x64`
这一组合会直接返回一段警告：macOS x64 支持在 Blender 5.0 被移除，
因此不再提供预编译依赖，要么自己编译依赖，要么回退到 4.5
（#src("build_files/utils/make_update.py:231-235")）。同时
`platform_apple.cmake` 在找不到 `lib/macos_<架构>` 时直接
`FATAL_ERROR`：`Mac OSX requires pre-compiled libs at: '<LIBDIR>'`
（#src("build_files/cmake/platform/platform_apple.cmake:50-59")）。
所以*用 Intel Mac 做主要开发机，从 5.x 起就不再是一个省事的选择*。

第三，*这些库很大，而且第一次下载有个容易出错的地方。* #win 的脚本会先问你
`Would you like to download them? (y/n)`，然后跳过 LFS 过滤器拉子模块元数据、
再在库目录里执行 `git lfs pull`（#src("build_files/windows/check_libraries.cmd:31-36")）。
脚本里那段加了很多星号的警告说的就是：*进度条走完不等于下载完成* ——
看到 `Resolving deltas: 100% (nnn/nnn) done` 之后，还会有一段没有任何可见输出的
长时间传输，脚本原文提醒它"可能超过一小时，请不要中断"
（#src("build_files/windows/check_libraries.cmd:22-30")）。
中断它，你就会得到一个半损坏的 `lib/`。

=== 2.2.3 `make update` 到底做了什么

POSIX 侧执行 `make update`（#src("GNUmakefile:617-618")），
它调用的 #src("build_files/utils/make_update.py") 是一个可跨平台直接运行的
Python 脚本；只更新代码、不动预编译库则是 `make update_code`，
对应 `make_update.py --no-libraries`（#src("GNUmakefile:620-621")）。

脚本的主流程（#src("build_files/utils/make_update.py:667-729")）可以归纳为三步：

1. 准备 Git LFS，并为镜像检出配置官方 LFS 回退来源；
2. 在当前分支允许更新时同步主仓库，再补齐主仓库的 LFS 对象；
3. 只启用当前平台的预编译库子模块，并补齐该子模块的 LFS 对象。

具体使用哪条 `git fetch`、如何选择子模块路径，属于更新脚本的实现细节；排错时再到附录 E
查对应命令即可。这里需要记住的边界是：`make update` 既处理源码更新，也处理构建所需的
LFS 内容和平台库。

#win 侧对应 `make.bat update` 与 `make.bat code_update`。前者依次执行
「检查/下载预编译库 → 更新库子模块 → 运行 `make_update.py` 更新源码」，
后者把中间一步跳过，只更新代码（#src("build_files/windows/parse_arguments.cmd:94-101")、
#src("make.bat:82-98")）。

`make update` 不会把固定标签的检出强行切回开发分支。处于 detached HEAD 时，脚本会跳过
主仓库拉取，但仍会补齐主仓库 LFS 与平台库；脚本根据 Blender 版本计算出的分支名，
主要用于选择匹配的外部库分支（#src("build_files/utils/make_update.py:673-679")）。

==== 下载中断后如何重试

Git LFS 对象按内容寻址，已经完整落盘的对象不会因为再次执行 `git lfs pull` 而重新下载。
因此网络中断后应重复更新命令补齐缺口，不要删除整个源码目录从头开始：

```bash
$ git lfs pull
$ git -C lib/<平台>_<架构> lfs pull
```

使用 Blender 官方入口时，也可以重新执行 `make update`（#win 为 `make.bat update`）。
若中断后出现大量“已修改”文件或残留 `index.lock`，按附录 E.1.2 的顺序确认进程、修复索引，
不要直接删除工作区。#footnote[
  `lfs.concurrenttransfers` 不是越大越快。并发收益取决于网络路径和服务器限制；除非正在做
 可重复的网络测量，否则保持默认值比同时下载多组 LFS 对象更容易判断失败位置。
]

=== 2.2.4 版本差异：为什么现在是 Git LFS 而不是 SVN

较早的教程会要求安装 SVN，用它检出预编译库；当前版本已改为“Git 子模块 + Git LFS”，
因此构建 Blender 不再需要 `svn`。源码里仍能看到 `BUILD_UPDATE_SVN`、`svn_update.cmd`
等历史名称，但对应脚本执行的已经是 `git submodule` 与 Git LFS 操作
（#src("build_files/windows/lib_update.cmd:1-23")）。判断流程时应看脚本行为，而不是根据
遗留文件名推断。

=== 2.2.5 主仓库自己的 LFS：测试数据为主，也包含构建资源

前面已经解释了 LFS 的存储关系与路径分布，这里只回答“哪些实体文件会影响构建”。
当你执行 `git lfs pull`（或第一次克隆触发 LFS 过滤）时，Blender 主仓库会拉取大量
LFS 对象。*绝大多数*位于 `tests/files/`，供回归测试使用；但主仓库 LFS 并不只包含
测试数据。固定基准中，`release/datafiles/` 也有
`startup.blend`、预览文件、图标数据与字体源文件等 LFS 对象，其中一部分是构建和
运行所必需的。

构建真正需要的实体资源在另外两个位置：

- `release/datafiles/`：图标、启动文件、主题、字体、着色器清单等。
  其中 `startup.blend`、`preview.blend`、`preview_grease_pencil.blend` 等由
  Git LFS 管理，首次配置前必须还原成实体文件。
- `lib/`：上一节那四个子模块。

CMake 甚至专门为这件事加了一条检查：*如果 `startup.blend` 小于 1KB
（也就是它只是一个 LFS 指针文件），配置阶段直接报错*
（#src("CMakeLists.txt:87-99")）。报错原文里已经写明了原因与修复方式：

```text
# CMakeLists.txt:96
Detected incomplete startup blend, likely due to missing Git LFS checkout.
Running "make update" or "git lfs pull" may resolve the issue.
```

看到这条报错时，优先检查 Git LFS，而不是编译器或 SDK。

但 `startup.blend` 只是 CMake 选择的一枚哨兵，不是“LFS 已完整”的证明。
固定基准里还有画笔资源、图标数据、预览文件与 `release/datafiles/colormanagement/icc/` 下的 ICC 配置由 LFS 管理；只要 `startup.blend` 已恢复，其他路径仍是指针时 configure 也可能通过，最后得到的程序却缺资源或在运行、测试阶段才报错。

完整检查应覆盖 `git lfs ls-files` 列出的每个路径：

```bash
$ git lfs ls-files
de873a2094 * assets/brushes/essentials_brushes-curve_sculpt.blend
...
```

OID 后面的 `*` 表示工作树中是完整对象，`-` 表示仍是 LFS 指针；检查时不应出现任何 `-` 记录。
需要人工确认可疑文件时，LFS 指针通常只有一百多字节，并以本节前面展示的三行格式开头。
体积很小和 `version https://git-lfs.github.com/spec/v1` 文件头要同时看，因为“小文件”
本身不一定是指针。
预编译库子模块也要在自己的目录执行同样的 `git lfs ls-files` 检查，不能只核对主仓库。

本节可以压成一句话：*`git clone` 取得 Git 历史与 LFS 指针；`make update`
（#win 是 `make.bat update`）补齐主仓库 LFS 与本机平台库；开始配置前，再按 LFS 清单
确认工作区里没有残留指针。* 库目录缺失会表现为 `Unable to find LIBDIR`（#linux）或
`Mac OSX requires pre-compiled libs`（#mac）；`startup.blend` 未恢复会触发不同平台均可能出现的
`Detected incomplete startup blend`，其他 LFS 缺口则未必能在配置阶段被发现。

== 2.3 Windows 构建

从本节开始按平台展开。先看全局：

#figure(fig-build-flow(), caption: [不同平台的构建流程对照（五个阶段）]) <fig-build-flow>

图中 Windows 一行采用推荐的 `make.bat ninja` 路径。若不加 `ninja`，`make.bat` 会使用
Visual Studio 生成器和 MSBuild（#src("make.bat:137-149")）；两种路径的区别见 §2.3.3。

=== 2.3.1 前置条件

#win 上的清单比另外两个平台长，因为 Blender 要求安装完整的 MSVC 工具链；
*不要求你预先激活 Developer Command Prompt*。

1. *Visual Studio 2022*（或 2026），安装时必须勾选
   「使用 C++ 的桌面开发」工作负载。构建脚本通过 `vswhere.exe` 查找
   安装了 `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`
   （arm64 时是 `...ARM64`）的实例；找不到时的提示原文是
   `Check the "Desktop development with C++" workload has been installed.`
   （#src("build_files/windows/detect_msvc_vswhere.cmd:16-44")）。
2. *CMake*，必须在 `PATH` 里。脚本用 `for %%X in (cmake.exe)` 的方式探测
   （#src("build_files/windows/find_dependencies.cmd:1-5")），
   找不到就在 `make.bat:114-117` 处直接退出。
3. *Git*，在 `PATH` 里；同时需要 *Git LFS*（`git lfs` 子命令可用）。
4. *Ninja*，仅当你要用 `ninja` 开关时需要，但强烈建议装。
   `configure_ninja.cmd` 第一件事就是 `ninja --version`，失败即
   `"Ninja not detected in the path"`（#src("build_files/windows/configure_ninja.cmd:1-5")）。
5. *Python 不需要自己装*，理由见 2.1.1。

#tip[
  你*不需要*先打开 "Developer Command Prompt for VS 2022"。
  `make.bat` 会自己找到 VS 安装目录并调用
  `vcvarsall.bat <架构>`（#src("build_files/windows/detect_msvc_vswhere.cmd:74-85")），
  而且它还会顺手验证 `msbuild` 与 `cl` 是否真的可用
  （#src("build_files/windows/detect_msvc_vswhere.cmd:87-113")）。
  这一点比很多教程里描述的方便。
]

=== 2.3.2 从零到构建成功

假设你已经把源码放在一个*路径里没有空格*的位置（见 §2.3.4）。

```cmd
:: 1. 进入源码目录
> cd C:\dev\blender

:: 2. 首次：更新源码并下载预编译库（会问 y/n，回答 y）
> make.bat update

:: 3. 首次构建：用 Ninja + Release，先执行一次"轻量"配置以便快速成功
> make.bat ninja lite

:: 4. 确认能启动
> ..\build_windows_Lite_x64_vc17_Release\bin\blender.exe --version

:: 5. 日常构建：改用默认配置（Release，但套用默认 CMake 选项）
> make.bat ninja

:: 6. C++ 开发与调试构建
> make.bat ninja debug developer
```

第 3 步之所以建议先使用 `lite`，是因为它关掉了大量可选组件
（#src("build_files/cmake/config/blender_lite.cmake:12-86")：
USD、Alembic、Cycles、OpenVDB、Draco、FFmpeg 编解码等统统关掉），
首次构建时间能明显缩短，而且能在你投入几小时之前先确认工具链是通的。

第 4 步的路径需要解释：`make.bat lite` 会设置 `TARGET=Lite`
（#src("build_files/windows/parse_arguments.cmd:32-34")），
而构建目录名是按

```text
<BUILD_DIR>[_<TARGET>]_<架构>_vc<VS主版本>_<BUILD_TYPE>
```

拼出来的（#src("build_files/windows/set_build_dir.cmd:1-5")）。
默认 `BUILD_DIR` 是源码上一级的 `build_windows`
（#src("build_files/windows/parse_arguments.cmd:1-2")），
`BUILD_VS_VER` 由检测脚本给出（VS2022 是 `17`，见
#src("build_files/windows/detect_msvc2022.cmd:1")）。于是：

```text
make.bat ninja                 -> ..\build_windows_x64_vc17_Release
make.bat ninja lite            -> ..\build_windows_Lite_x64_vc17_Release
make.bat ninja debug           -> ..\build_windows_x64_vc17_Debug
make.bat ninja bpy             -> ..\build_windows_Bpy_x64_vc17_Release
```

注意 `developer` 开关*不设置* `TARGET`，所以 `make.bat ninja developer`
与 `make.bat ninja` 用的是同一个构建目录，只是多加载了一份初始缓存文件。
这不算问题（`-C` 里的变量带 `FORCE`，会覆盖缓存），但要知道
它不会给你一个独立的目录。

=== 2.3.3 选择生成器与构建档位

`make.bat` 默认生成 Visual Studio 工程并用 MSBuild 构建；加上 `ninja` 后改用 Ninja。
前者适合在 Visual Studio 中浏览和调试工程，后者通常有更快的增量构建速度。无论选择哪种
生成器，`debug` 都表示 Debug 构建类型，`lite`、`developer`、`full` 等则是功能档位；
二者可以组合，具体区别见 §2.6.3。

日常只需记住下面五个组合。其余开关不应打断第一次构建，完整列表见附录 C.2。

- `make.bat update` —— *新克隆之后的第一步，必须在第一次构建之前完成。*
  它会先问你要不要下载预编译库（答 `y`），再更新子模块与源码。
- `make.bat ninja lite` —— *这是第一次构建。* 关掉可选组件，最快拿到一个能启动的
  Blender，用来验证工具链是否通了。
- `make.bat ninja` —— *这是日常 Release 构建。* 套用默认 CMake 选项，用 Ninja 后端。
- `make.bat ninja debug developer` —— *这是日常 C++ 开发与调试构建。*
  Debug 构建目录可以和 Release 构建共存；`developer` 档位还会
  打开 `WITH_ASSERT_ABORT`、`WITH_GTESTS`、`WITH_PYTHON_SAFETY`，
  非 Windows 上还会打开 ASAN，并生成 `compile_commands.json`
  （#src("build_files/cmake/config/blender_developer.cmake:11-30")）。

`make.bat nobuild` 可以只生成或重新配置工程，`make.bat builddir <路径>` 可以指定构建目录；
这两个命令适合已经理解 CMake 缓存的读者。不要把 `clean` 当成日常步骤，只有在确认缓存或
中间产物已经损坏时才清理。

#tip[
  首次构建成功后，构建目录里会生成一个 `rebuild.cmd`
  （Ninja 路径见 #src("build_files/windows/configure_ninja.cmd:57-63")，
  MSBuild 路径见 #src("build_files/windows/configure_msbuild.cmd:76-89")）。
  它的内容是「如果没在 VS 环境里就先 `call vcvarsall`，然后
  `ninja install`」或者「`msbuild INSTALL.vcxproj`」。
  *日常增量重建直接运行它最快*，因为它省掉了 `make.bat` 的一整套环境探测。
]

=== 2.3.4 Windows 构建排错

#win 上最常见的问题集中在路径、工具探测和依赖完整性；更完整的诊断顺序见附录 E.2。

- *源码路径不能含空格。* `make.bat` 的第三件事就是检查这件事，发现空格就打印
  `There are spaces detected in the build path "...", this is currently not supported, exiting....`
  然后退出（#src("build_files/windows/check_spaces_in_path.cmd:1-6")）。
  它检查的是*源码目录*，所以在 `C:\Users\你的名字\...` 这类路径下经常直接踩中；
  把源码放在 `C:\dev\blender` 这种路径下最省事。
- *Ninja 不在 `PATH` 里。* 报错原文 `"Ninja not detected in the path"`
  （#src("build_files/windows/configure_ninja.cmd:1-5")）。它是用
  `ninja --version` 探测的，所以"装了但没加进 `PATH`"与"没装"是同一个症状。
- *预编译库没下载完，或者你中断了它。* 症状会在配置阶段出现：CMake 报找不到
  `LIBDIR`。而 `check_libraries.cmd` 的判定标准很朴素 —— 它只看
  `lib\windows_x64\.git` 是否存在（#src("build_files/windows/check_libraries.cmd:10")）。
  也就是说*一个残缺的 `.git` 目录会被当成"库已就绪"*，于是它不再询问、
  直接进入配置，然后在 CMake 里失败。遇到这种情况，最干净的做法是删掉
  `lib\windows_x64` 整个目录，重新执行 `make.bat update`，并等待它彻底完成。
- *构建目录命名不符合预期。* `developer` 不设置独立的 `TARGET`，因此它与默认配置
  共用目录；`lite` 等档位则会进入目录名。想完全控制位置就使用
  `make.bat builddir <路径>`。

#pitfall[
  *VS 版本选错或组件不全。* 三种症状各不相同：

  - `make.bat` 阶段就报 `Visual Studio 2022 not found (try with the 'verbose' switch ...)`
    （#src("make.bat:62-74")）—— `vswhere` 没找到带
    `VC.Tools.x86.x64` 组件的实例，或你指定了没装的年份。加 `verbose`
    能看到它执行的查询（#src("build_files/windows/detect_msvc_vswhere.cmd:22-31")）。
  - 自动检测选错年份：不指定时的顺序固定是 2019 → 2022 → 2026
    （#src("build_files/windows/autodetect_msvc.cmd:3-10")）。装了多个 VS 时
    用 `make.bat 2022 ninja` 明确指定。
  - 配置通过、编译阶段报 `Compiler is unsupported, MSVC 2022 17.14.14 or newer is required`
    （#src("build_files/cmake/platform/platform_win32.cmake:40-48")）—— 工具集太旧。
]

#warn[
  默认（不加 `ninja`）那条 MSBuild 路径会生成 `Blender.sln`
  （VS2026 下是 `Blender.slnx`，见 #src("make.bat:76-80")），
  编译分两步：先 `msbuild Blender.<后缀> /target:build`，
  再 `msbuild INSTALL.vcxproj`（#src("build_files/windows/build_msbuild.cmd:3-24")）。
  这一步的 `INSTALL` 不是可选项 —— 库文件与脚本是在 install 阶段复制到产物目录的。
  手动用 Visual Studio 打开 `.sln` 时，必须把 `INSTALL` 工程也构建一次，
  否则你打开的 `blender.exe` 可能缺少运行时脚本。
]

== 2.4 macOS 构建

=== 2.4.1 前置条件

#mac 的前置条件相对较少：

- *Xcode 或 Xcode 命令行工具（Command Line Tools）16.0 以上。* 构建系统会调用
  `xcode-select --print-path`（#src("build_files/cmake/platform/platform_apple_xcode.cmake:16-21")）
  并检测完整 Xcode 或 CLT；低于 16.0 会直接报错
  （#src("build_files/cmake/platform/platform_apple_xcode.cmake:102-105")）。
- *CMake*、*Git*、*Git LFS*、*Ninja*。前三个必需，Ninja 强烈建议。
- *预编译库*：`lib/macos_arm64`，通过 `make update` 自动获取。
- *架构*：预编译库只提供 arm64。构建系统会按
  `uname -m` 自动设定 `CMAKE_OSX_ARCHITECTURES`
  （#src("build_files/cmake/platform/platform_apple_xcode.cmake:7-14")），
  然后据此选 `lib/macos_<架构>`
  （#src("build_files/cmake/platform/platform_apple.cmake:50-59")）。

关于 Homebrew，需要说清楚一个边界：*标准构建不需要用 Homebrew 安装 Blender 的
第三方库依赖*。CMake、Git 与 Git LFS 仍然必须通过 Homebrew、MacPorts 或手工安装等
任一方式准备好。Blender 的第三方库由 `lib/macos_arm64` 提供，CMake 会把 `lib/` 下
每个子目录加进
`CMAKE_PREFIX_PATH` 去查找它们（#src("build_files/cmake/platform/platform_apple.cmake:79-89")）。
只有在你选择自行编译依赖（`make deps`）时，才需要一堆命令行工具，
那些工具的名字写在源码里：

```text
# build_files/build_environment/cmake/check_software.cmake:62-63
On macOS (with homebrew):
  brew install autoconf automake bison dos2unix flex libtool meson ninja pkg-config yasm
```

#warn[
  上面这行 Homebrew 命令是*构建依赖（`make deps`）*才需要的，不是你日常构建
  Blender 所需要的。而且它的内容是构建脚本里的一句提示文本，
  随时间可能变化。装依赖前请以官方文档为准：
  #weblink("https://developer.blender.org/docs/handbook/building_blender/mac/", label: [Building Blender on macOS])。
]

=== 2.4.2 从零到构建成功

#raw(
  "# 1. 确认命令行工具已安装（没装会弹窗引导安装）\n"
  + "$ xcode-select --install\n\n"
  + "# 2. 克隆源码\n"
  + "$ git clone https://projects.blender.org/blender/blender.git\n"
  + "$ cd blender\n"
  + "$ git switch --detach " + blender-tag + "\n\n"
  + "# 3. 拉取预编译库（这一步下载量大，耐心等）\n"
  + "$ make update\n\n"
  + "# 4. 首次构建：先 lite + ninja，快速验证\n"
  + "$ make lite ninja\n\n"
  + "# 5. 确认可运行\n"
  + "$ ./../build_darwin_lite/bin/Blender.app/Contents/MacOS/Blender --version\n\n"
  + "# 6. 日常构建\n"
  + "$ make ninja",
  block: true,
  lang: "bash",
)

第 5 步的路径是 `build_darwin_lite` 而不是 `build_macos_lite`。
默认构建目录由 `build_$(OS_NCASE)` 拼出，而 `OS_NCASE` 是 `uname -s`
转小写的结果，在 macOS 上是 `darwin`
（#src("GNUmakefile:182-197")、#src("GNUmakefile:208-210")）；
预编译库目录名才用 `macos`（#src("GNUmakefile:193-197")）。
这两个名字容易混，记住"*库叫 macos，构建目录叫 darwin*"即可。

第 4 步的 `lite` 与 `ninja` 的顺序无所谓 —— `GNUmakefile` 里的注释明确写了
"传多个目标时顺序不重要"，并且举的例子就是 `make lite ccache ninja`
（#src("GNUmakefile:26-27")）。不过有一个例外值得记住：*配置档之间有覆盖关系，
命令行里靠后的那个生效*，所以 `make bpy release` 的效果是"先加载 release，
再加载 bpy"，也就是 bpy 的设置赢（#src("GNUmakefile:279-282")）。

=== 2.4.3 产物路径

#mac 的产物是一个标准的 `.app` 应用包。安装阶段把主程序装到包的
`Contents/MacOS/` 下，Python、脚本、图标等资源装到
`Contents/Resources/` 下：

- 主程序：`<构建目录>/bin/Blender.app/Contents/MacOS/Blender`
  （#src("GNUmakefile:348-350")）。
- 版本相关的资源：`Blender.app/Contents/Resources/<版本号>/`
  （#src("source/creator/CMakeLists.txt:437-441")）。
- 动态库：`Blender.app/Contents/Resources/lib/`
  （#src("source/creator/CMakeLists.txt:438")）。
- 运行时用 `DYLD_LIBRARY_PATH` 指向同一个 `Resources/lib/`
  （#src("build_files/cmake/platform/platform_apple.cmake:504")）。

目标属性里显式设置了 `MACOSX_BUNDLE TRUE`
（#src("source/creator/CMakeLists.txt:322")），所以无论用 Ninja 还是
Xcode 生成器，产物形态都是应用包。

=== 2.4.4 用 Xcode 生成工程

`GNUmakefile` 只支持 Ninja 与 Makefiles 两种后端
（#src("GNUmakefile:322-341")），它*不会*给你 Xcode 工程。
想要 Xcode 工程就绕开 `make`，直接调用 CMake：

```bash
$ cmake -S . -B ../build_xcode -G Xcode \
    -C build_files/cmake/config/blender_developer.cmake
```

这条路径是源码支持的：`platform_apple_xcode.cmake` 里有多处
`if(${CMAKE_GENERATOR} MATCHES "Xcode")` 分支专门为 Xcode 生成器服务
（#src("build_files/cmake/platform/platform_apple_xcode.cmake:23-25")、
#src("build_files/cmake/platform/platform_apple_xcode.cmake:152-155")），
源码注释也说明 Xcode 版本"由 Xcode 生成器提供，Unix Makefiles 或 Ninja 没有"
（#src("build_files/cmake/platform/platform_apple_xcode.cmake:23-25")）。

#warn[
  多配置生成器（Xcode、VS）和单配置生成器（Ninja、Makefiles）的
  产物路径与构建类型传递方式不同，见 2.1.2 中「单配置与多配置生成器」那张表。
  在 Xcode 里你会得到 `bin/Debug/Blender.app` 这样的结构，
  而不是 `bin/Blender.app`。
]

== 2.5 Linux 构建

=== 2.5.1 发行版依赖

#linux 的情况介于另外两者之间：预编译库同样由 `lib/linux_x64` 提供，
但*窗口系统相关的开发包必须来自发行版*。原因很直接：Wayland 与 X11
在配置阶段是用 `pkg-config` 与 `find_package(X11 REQUIRED)` 探测系统安装的
（#src("build_files/cmake/platform/platform_unix.cmake:727-789")、
#src("build_files/cmake/platform/platform_unix.cmake:843-844")），
预编译库不覆盖它们。

Blender 官方构建环境是 Rocky Linux 8，其依赖清单在源码里就是一份可执行的
`dnf` 脚本（#src("build_files/build_environment/linux/linux_rocky8_setup.sh")）。
其中"构建 Blender 本体"（而不只是构建依赖库）需要的部分是这样八项：
`libxkbcommon-devel`、`libX11-devel`、`libXcursor-devel`、`libXi-devel`、
`libXinerama-devel`、`libXrandr-devel`、`libXt-devel`、`libXxf86vm-devel`
（#src("build_files/build_environment/linux/linux_rocky8_setup.sh:162-175")）。

各发行版的包名不同。为了让这件事可操作，源码里带了一个会识别发行版的
安装助手（支持 `debian` / `fedora` / `suse` / `arch` 四类，
见 #src("build_files/build_environment/install_linux_packages.py:18-22")）：

```bash
$ python3 build_files/build_environment/install_linux_packages.py
$ python3 build_files/build_environment/install_linux_packages.py --show-deps
$ python3 build_files/build_environment/install_linux_packages.py --distro-id debian
```

它的说明文本写得很清楚：*默认只安装构建 Blender 所需的关键工具与依赖，
不包含预编译库已经提供的那些库；完成后应当再执行 `make update`*
（#src("build_files/build_environment/install_linux_packages.py:1132-1151")）。
它用 `sudo` 或 `doas` 提权；两者都没有时可以用 `--no-sudo`，
此时它只打印需要安装的包名。

#warn[
  源码里还有一份 Debian / Ubuntu 的 `apt` 清单，但它的用途是
  *自行编译依赖*（`make deps`），不是标准构建：

```text
# build_files/build_environment/cmake/check_software.cmake:59-60
On Debian and Ubuntu:
  apt install autoconf automake autopoint flex help2man gettext texinfo \
    bison libtool yasm tcl ninja-build meson python3-mako patchelf \
    pkg-config
```

  包名会随发行版与源码演进变化，安装前请以官方文档为准：
  #weblink("https://developer.blender.org/docs/handbook/building_blender/linux/", label: [Building Blender on Linux])。
]

=== 2.5.2 从零到构建成功

#raw(
  "# 1. 克隆源码\n"
  + "$ git clone https://projects.blender.org/blender/blender.git\n"
  + "$ cd blender\n"
  + "$ git switch --detach " + blender-tag + "\n\n"
  + "# 2. （推荐）先让助手把关键构建依赖装上\n"
  + "$ python3 build_files/build_environment/install_linux_packages.py\n\n"
  + "# 3. 拉取预编译库\n"
  + "$ make update\n\n"
  + "# 4. 首次构建\n"
  + "$ make lite ninja\n\n"
  + "# 5. 确认可运行\n"
  + "$ ./../build_linux_lite/bin/blender --version\n\n"
  + "# 6. 日常构建 / 调试构建\n"
  + "$ make ninja\n"
  + "$ make debug ninja",
  block: true,
  lang: "bash",
)

=== 2.5.3 产物路径

Linux 默认是*便携安装*：`WITH_INSTALL_PORTABLE` 默认 `ON`
（#src("CMakeLists.txt:546-551")），此时安装前缀就是
`<构建目录>/bin`（#src("CMakeLists.txt:1249-1253")），
主程序装到 `bin/` 下。

- 主程序：`<构建目录>/bin/blender`（#src("GNUmakefile:351-353")）。
- 动态库：与主程序同级的 `lib/`，通过 RPATH 里的 `$ORIGIN/lib` 定位
  （#src("build_files/cmake/platform/platform_unix.cmake:1093-1102")）。
  这意味着*把整个 `bin/` 目录搬到另一台机器上仍然能运行*，
  前提是目标机的 glibc 版本足够新（见 §2.5.4）。
- 测试程序的相对路径略有不同，源码里明确区分了
  `Blender.app`（#mac）/ `<版本号>`（#win 或便携安装）/
  `share/blender/<版本号>`（非便携 #linux）
  这三种情况（#src("build_files/cmake/testing.cmake:139-149")）。

=== 2.5.4 Linux 构建排错

#pitfall[
  *忘了 `make update`，然后被一堆找不到库的报错淹没。*
  这是 Linux 上最常见、也最容易被误诊的问题。当 `<源码>/lib/linux_x64`
  不存在或为空时，`platform_unix.cmake` 不会报错退出，而是*静默地把
  `WITH_LIBS_PRECOMPILED` 关掉*，然后去用系统库：

```text
# build_files/cmake/platform/platform_unix.cmake:51-65
Unable to find LIBDIR: "<...>". system libraries may be used
(disable WITH_LIBS_PRECOMPILED to suppress this message).
```

  于是你会看到一连串"某个第三方库版本不满足"的报错，
  而真正的原因只是库没下载。*看到这类报错先检查
  `lib/linux_x64/` 是不是空的。*
]

#pitfall[
  *二进制不可移植（glibc 版本）。* 预编译库是按 glibc 2.28 ABI 编译的，
  源码里把这一点写在注释里：
  `# Path to libraries with known glibc 2.28 ABI.`
  （#src("build_files/cmake/platform/platform_unix.cmake:13-19")）。
  在更新的发行版上编译出来的 `bin/` 拿到更老的发行版上会因 glibc 符号版本
  缺失而无法启动。要给老系统分发，请在老系统上构建，
  或者用官方容器环境。
]

#pitfall[
  *X11 与 Wayland 都要有。* 两者的构建选项默认都是 `ON`
  （#src("CMakeLists.txt:343-348")），X11 用的是
  `find_package(X11 REQUIRED)`（#src("build_files/cmake/platform/platform_unix.cmake:843-844")）。
  只想装一种的话，要么把另一个显式关掉
  （`-DWITH_GHOST_X11=OFF` 或 `-DWITH_GHOST_WAYLAND=OFF`），
  要么按官方文档装齐开发包。缺 `libXxf86vm` 之类的包时，
  报错信息里会给出"Disable `WITH_X11_XXX` if you want to build without ..."
  的提示（#src("build_files/cmake/platform/platform_unix.cmake:851-879")）。
]

=== 2.5.5 可选：`make deps` 自行编译依赖

如果官方预编译库确实不适用，可以自行编译全部依赖：

```bash
$ make deps
```

该目标面向平台维护者，会把结果写入 `lib/<平台>_<架构>/`，并可能覆盖已经下载的
预编译库（#src("GNUmakefile:35-38")、#src("GNUmakefile:431-451")）。因此它不是标准构建的
备用“修复按钮”：普通开发者应优先解决 `make update` 或平台库下载问题。#footnote[
  #win 对应的底层入口是
  `build_files/build_environment/windows/build_deps.cmd`；只有维护依赖工具链时才需要直接
  使用它，常规 Blender 构建仍应走 `make.bat`。
]

== 2.6 首次构建、增量构建与常用档位

=== 2.6.1 首次构建：会花多久，卡在哪

首次构建耗时长，不只因为 C/C++ 文件多，还因为链接和生成步骤也要完整执行：

- `intern/`、`extern/` 下的第三方库全部要从源码或预编译静态库参与链接。
- RNA 相关的生成步骤（`makesdna`、`makesrna`）要先执行一遍，
  它们会把 `DNA_*.h` 与 `RNA_*.cc` 变成 C 代码。
- 着色器、图标、语言包、Python 字节码都在构建期生成。

所以首次构建可能需要半小时到几小时，而第二次改一个 `.cc` 文件通常只需要几十秒到几分钟。
这个落差是正常的，不表示构建系统损坏。

中断后先判断所处阶段：源码、LFS 或预编译库下载失败时，重复 §2.2.3 的更新命令；
已经进入构建阶段，则重新执行同一条 `make`、`make.bat`、Ninja 或 MSBuild 命令。
构建后端会复用已经完成的目标，不需要删除源码或构建目录重新开始。

=== 2.6.2 增量构建

POSIX 上最简单的增量构建就是再次执行：

```bash
$ make
```

`all` 目标会重新执行配置（幂等）再执行 `install`
（#src("GNUmakefile:395-416")）。它最后会打印一行提示，
告诉你构建好的二进制在哪：

```text
# GNUmakefile:410-415（节选）
Edit build configuration with: "<BUILD_DIR>/CMakeCache.txt" run make again to rebuild.
Blender successfully built, run from: <BUILD_DIR>/bin/blender
```

如果嫌 `make` 每次都要重新过一遍 CMake，可以直接用后端：

```bash
$ ninja -C ../build_linux install
```

这和在 Windows 上运行构建目录里的 `rebuild.cmd` 是同一个道理。

#tip[
  改代码时优先用 `ninja` 直接构建单个目标，例如只想重新链接主程序：
  `ninja -C <构建目录> blender`。只改了某个模块时，
  构建系统会自己算出最小重编集合 —— 前提是你没有
  "顺手改一下 CMake 选项"而触发全量重配置。
]

=== 2.6.3 构建档位：`debug`、`developer`、`lite`、`full`、`release`

这是本章最容易混的一组概念，因为它其实包含*两类*不同的开关：

- *构建类型（build type）*：`Release` 还是 `Debug`。影响优化级别与调试符号。
  POSIX 上由 `debug` 目标设置（#src("GNUmakefile:289-292")），
  #win 上由 `debug` 开关设置（#src("build_files/windows/parse_arguments.cmd:11-14")）。
- *构建档位（configuration profile）*：加载哪一份
  `build_files/cmake/config/*.cmake`。影响的是"打开哪些可选功能"。

这两者可以叠加：`make debug developer` 就是"Debug 构建类型 +
开发者档位"，而且因为 `debug` 会给构建目录加 `_debug` 后缀，
它会和你的 Release 构建完全隔离。

下面这张表用于选择档位。第一次验证工具链优先用 `lite`，开始修改 C++ 后再切到
`debug developer`；其余档位只在目标明确时使用。

#figure(
  kind: table,
  table(
    columns: (0.9fr, 1.3fr, 1.5fr, 1.4fr),
    inset: 5.5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*档位*], [*CMake 文件*], [*它到底做了什么*], [*什么时候选它*]),
    [`full`],
    [`blender_full.cmake`],
    [把官方发布版该有的功能全部打开：Cycles、USD、Alembic、OpenVDB、
      MaterialX、Hydra、OpenXR、FFmpeg 等],
    [想验证"功能完整版能不能编译"，
      但不需要 CUDA / OptiX 等 GPU 二进制],
    [`release`],
    [`blender_release.cmake`],
    [等同于 `full`，*额外打开 GPU 计算后端与二进制内核*：
      `WITH_CYCLES_DEVICE_OPTIX` / `HIPRT` / `ONEAPI`、
      `WITH_CYCLES_CUDA_BINARIES` / `HIP_BINARIES` / `ONEAPI_BINARIES`
      （#src("build_files/cmake/config/blender_release.cmake:91-112")）],
    [要复现 blender.org 官方发布的构建，
      或者要测试 GPU 渲染路径],
    [`lite`],
    [`blender_lite.cmake`],
    [显式把几十项功能设成 `OFF`：Cycles、USD、Alembic、Bullet、
      OpenVDB、Draco、FFmpeg 编解码、Freestyle、流体与海洋模拟、
      XR、NDOF……（#src("build_files/cmake/config/blender_lite.cmake:12-86")）],
    [*第一次构建*、以及只做 UI / Python / 窗口相关开发的时候],
    [`headless`],
    [`blender_headless.cmake`],
    [`WITH_HEADLESS=ON`，并关掉所有音频后端与
      X11 输入相关选项（#src("build_files/cmake/config/blender_headless.cmake:12-28")）],
    [服务器 / 渲染农场 / 无显示环境的批处理],
    [`developer`],
    [`blender_developer.cmake`],
    [`WITH_ASSERT_ABORT=ON`、`WITH_ASSERT_RELEASE=ON`、
      `WITH_GTESTS=ON`、`WITH_PYTHON_SAFETY=ON`、`WITH_BUILDINFO=OFF`、
      非 Windows 上 `WITH_COMPILER_ASAN=ON` 与 `WITH_STRSIZE_DEBUG=ON`、
      并生成 `compile_commands.json`
      （#src("build_files/cmake/config/blender_developer.cmake:11-30")）],
    [*改 Blender C++ 源码时的默认选择*。
      断言会在出错处直接停下，而不是悄悄继续执行],
    [`cycles`],
    [`cycles_standalone.cmake`],
    [`WITH_BLENDER=OFF` + `WITH_CYCLES_STANDALONE=ON`，
      只构建 Cycles 独立版（#src("build_files/cmake/config/cycles_standalone.cmake:11-17")）],
    [只做 Cycles 渲染器开发],
    [`bpy`],
    [`bpy_module.cmake`],
    [`WITH_PYTHON_MODULE=ON`，把 Blender 构建成可导入的 Python 模块；
      关掉缩略图生成器、音频设备、NDOF 等对模块无意义的部件
      （#src("build_files/cmake/config/bpy_module.cmake:11-90")）],
    [只写 Python 插件、但需要自己编译 `bpy` 时],
  ),
  caption: [七个构建档位的真实差别（全部来自 `build_files/cmake/config/` 下的实际文件）。],
) <tbl-profiles>

#note[
  `full` 与 `release` 的差别很容易记错。源码里 `show_help.cmd` 的说法是：
  `release` 等同于官方 blender.org 构建，`full` 是
  "same as release minus the cuda kernels"
  （#src("build_files/windows/show_help.cmd:3-4")）。
  对比两份文件也能看出来：`blender_full.cmake` 里没有
  `blender_release.cmake:91-112` 那一大段 `WITH_CYCLES_*` GPU 开关。
  不想下载几 GB 的 GPU 内核，就用 `full`。
]

#tip[
  *给日常开发一个推荐组合：`make debug developer ninja`*
  （#win 是 `make.bat ninja debug developer`）。
  Debug 构建类型给你准确的断点与栈，
  developer 档位给你断言、单元测试与 `compile_commands.json`，
  Ninja 给你最快的增量编译。三者互不冲突。
]

=== 2.6.4 测试、配置与维护目标

构建主线之外，日常偶尔会用到下面几类目标：

- `make test`：运行测试套件。它的实现是调用
  `build_files/utils/make_test.py`，而后者转手执行
  `ctest . --output-on-failure -O <构建目录>/tests/log.txt`
  （#src("build_files/utils/make_test.py:47-59")）。
- `make config`：只打开 CMake 配置工具改选项，
  有 `DISPLAY` 时用 `cmake-gui`，否则用 `ccmake`
  （#src("GNUmakefile:385-390")、#src("GNUmakefile:455-456")）。
- `make help` / `make help_features`：前者打印目标说明，
  后者列出所有可选功能开关（#src("GNUmakefile:462-463")、
  #src("GNUmakefile:667")）。
- `make format` / `make license`：提交前执行格式化与许可证检查
  （#src("GNUmakefile:623-628")）。

打包、文档生成和 `check_*` 静态检查属于发布或专项维护流程，不必在第一次构建时掌握；
需要时查附录 C 的目标表即可。

== 2.7 运行与调试

构建完成只是开始。这一节讲怎么*启动刚编译出来的 Blender 并监控它*。

=== 2.7.1 三个最重要的命令行参数

Blender 的命令行参数在 #src("source/creator/creator_args.cc") 里注册，
按"参数段"（pass）分组成批。对开发者来说，下面三个参数覆盖了 80% 的场景。

- `-b` / `--background`：*无界面模式*。源码注释是
  "Run in background (often used for UI-less rendering)"，
  并且它默认会关掉音频设备
  （#src("source/creator/creator_args.cc:3160")、
  #src("source/creator/creator_args.cc:1109-1114")）。
  你写自动化脚本、执行渲染与回归测试都靠它。
- `-X` / `--factory-startup`：*跳过用户目录里的启动文件*，
  也就是忽略你的偏好设置与已安装插件，以出厂状态启动
  （#src("source/creator/creator_args.cc:3348")、
  #src("source/creator/creator_args.cc:1924-1932")）。
  当你要确认"某个诡异行为到底是我改坏了代码，还是我的用户配置搞的鬼"，
  这是第一个该加的开关。它同时会置上"退出时不保存用户偏好"的标志。
- `--python <文件>`：启动后执行一个 Python 脚本
  （#src("source/creator/creator_args.cc:3383")）。
  配合 `-b` 与 `-X`，你就得到了一个可脚本化的 Blender：

```bash
$ ./bin/blender --background --factory-startup --python-exit-code 1 \
    --python my_script.py
```

  `--python-exit-code 1` 让脚本抛异常时 Blender 以退出码 1 结束
  （#src("source/creator/creator_args.cc:3387")），
  脚本化调用时*务必加上*，否则 CI 会把失败当成功。
  这套组合不是本书编的 —— Blender 自己的构建目标就在用几乎相同的写法：

```make
# GNUmakefile:645-651（节选）
python_stubs: .FORCE
	@ASAN_OPTIONS=halt_on_error=0:${ASAN_OPTIONS} \
	$(BLENDER_BIN) \
	    --background --factory-startup --quiet \
	    --python-exit-code 1 \
	    --python doc/python_api/sphinx_doc_gen.py
```

=== 2.7.2 `--debug-*` 家族

`--debug-*` 是 Blender 里性价比最高的一组开发工具。它们绝大多数只影响
日志输出（少数会改变行为），可以自由叠加，注册位置在
#src("source/creator/creator_args.cc:3180-3343")。常用的有：

- `-d` / `--debug`：总开关。打开内存错误检测、禁止鼠标抓取
  （方便切到调试器）、保留 Python 的 `sys.stdin`，并打印完整参数表
  （#src("source/creator/creator_args.cc:1362-1384")）。
- `--debug-python`：Python 解释器与 `bpy` 绑定的调试输出。*写插件时最常用*。
- `--debug-events`、`--debug-handlers`、`--debug-wm`、`--debug-ghost`、
  `--debug-jobs`：窗口与事件这一整条链路 —— 事件系统、事件处理器分发、
  窗口管理器、Ghost 跨平台窗口抽象、后台任务调度。
  "我的按键为什么没被处理""界面为什么卡了一下"都在这组里查。
- `--debug-gpu`：GPU 后端。另有一组更细的开关：
  `--debug-gpu-compile-shaders`、`--debug-gpu-shader-source`、
  `--debug-gpu-shader-no-preprocessor`、`--debug-gpu-shader-no-dce`
  （#src("source/creator/creator_args.cc:3255-3288")）。
- `--debug-depsgraph`：依赖图求值。这一族最有用，单独在下一段展开。
- `--debug-io`、`--debug-memory`、`--debug-fpe`、`--debug-value <n>`：
  文件读写（定位"这个 `.blend` 为什么加载不对"）、内存分配检查、
  浮点异常捕获（数值类 bug 的利器）、设置一个供代码内部分支使用的调试整数。
- `--debug-all`：打开全部调试输出。输出量极大，只在需要"全都看一眼"时用。

依赖图那一族值得单独列出来，因为它是第 13 章的主要工具。
它们的注册位置在 #src("source/creator/creator_args.cc:3290-3330")：

- `--debug-depsgraph`：总开关。
- `--debug-depsgraph-build`：只打印依赖图的*构建*过程。
- `--debug-depsgraph-eval`：只打印*求值*过程。
- `--debug-depsgraph-tag`：打印*标记（tag）*传播 ——
  想知道"改了这个属性为什么会触发那么多重算"就看它。
- `--debug-depsgraph-time`：打印每个节点的耗时。
- `--debug-depsgraph-no-threads`：单线程求值，
  让输出的因果关系不再交错，便于阅读。
- `--debug-depsgraph-pretty`：美化输出。
- `--debug-depsgraph-uid`：输出里带上数据块的 UID。

#tip[
  一个非常实用的排查顺序：*先用 `--debug-depsgraph-tag` 找"谁触发了重算"，
  再用 `--debug-depsgraph-time` 找"慢在哪"，最后用
  `--debug-depsgraph-no-threads` 打一份可读的完整日志。*
  四个开关组合起来，比在代码里到处插打印语句高效得多。
]

=== 2.7.3 单步调试：gdb 与 lldb

不同平台各有适合的主力调试器：

- #linux：`gdb`（或 `lldb`）。
- #mac：`lldb`（Xcode 自带）。
- #win：Visual Studio 调试器；也可以用 `lldb`（CodeLLDB 等）。

Blender 为 gdb 与 lldb 各准备了一个*美化打印器插件*，它能把
`blender::Map`、`blender::IndexMask`、`blender::Vector` 这类容器显示成人能读的
样子，并过滤掉层层包裹的栈帧。*这两个插件就在源码里*，
路径与安装方法都写在文件头部注释里：

- gdb：把
  `source <源码>/tools/debug/gdb/blender_gdb_extension.py`
  这一行加进 `~/.gdbinit`（#src("tools/debug/gdb/blender_gdb_extension.py:12-16")）。
  自检方法：`info pretty-printer` 应能看到 `blender-pretty-printers`，
  `info frame-filter` 应能看到 `blender-frame-filters`
  （#src("tools/debug/gdb/blender_gdb_extension.py:18-21")）。
- lldb：把
  `command script import <源码>/tools/debug/lldb/blender_lldb_formatter.py`
  加进 `~/.lldbinit`。用 VSCode 的 CodeLLDB 扩展时，还需要在 settings.json 里加
  `"lldb.launch.initCommands": [ "command source ${env:HOME}/.lldbinit" ]`
  （#src("tools/debug/lldb/blender_lldb_formatter.py:7-13")）。

这两个文件是"能显著降低调试痛苦、但知道的人不多"的典型。它们并不神奇 ——
只是把内部容器类型注册成调试器的 synthetic provider 与 summary provider ——
但正是这些容器让 `p some_vector` 在裸调试器里输出几百行噪声。
花两分钟配好，本书后半部分的调试体验都会不一样。

实际启动调试的典型流程（以 #linux 为例）：

```bash
$ gdb --args ./bin/blender --background --factory-startup \
    --python-exit-code 1 --python repro.py
(gdb) break BKE_object_free_caches
(gdb) run
(gdb) bt
```

关于优化级别有一个必须注意的点：*Release 构建里很多局部变量会被优化掉*，
`print` 出来是 `<optimized out>`。要正经单步，
用 `make debug developer ninja` 那条 Debug 路径。
这也是 2.6.3 那张表里把 `debug` 单独列出来的原因。

=== 2.7.4 生成 IDE 工程

最后一件与"日常怎么写代码"有关的事。Blender 仓库里*没有* `.vscode/`
目录，也没有任何随源码分发的 IDE 工程文件 —— 本书核对的上游仓库根目录中
不存在 `.vscode`。工程文件都是本地生成的。

- #win：CMake 的 Visual Studio 生成器直接产出 `Blender.sln`
  （VS2026 下是 `Blender.slnx`）。不加 `ninja` 开关执行一次
  `make.bat` 就会得到它（#src("build_files/windows/configure_msbuild.cmd:41")、
  #src("make.bat:76-80")）。用 `make.bat nobuild` 可以只生成工程不编译。
  另外源码里带了一份 Visual Studio 的调试可视化配置
  `tools/utils_ide/natvis/Blender.natvis`，可以在 VS 里加载它
  来改善 STL / 自定义容器的显示。
- #mac：用 `-G Xcode` 生成 Xcode 工程，见 2.4.4。
- #mac #linux：`make project_qtcreator` 生成 Qt Creator 工程，
  它调用 #src("tools/utils_ide/cmake_qtcreator_project.py")
  （#src("GNUmakefile:488-489")）；`make project_eclipse`
  生成 Eclipse CDT4 工程（#src("GNUmakefile:491-492")）。
- 不同平台通用：*VSCode + CMake Tools 或 clangd*。关键在于
  `compile_commands.json` —— 它是 Clang 系工具链取得每个文件的
  头文件搜索路径与编译选项的标准方式（很多 IDE 都依赖它）。
  `blender_developer.cmake` 里有专门一行打开它：

```cmake
# build_files/cmake/config/blender_developer.cmake:28-30
# For Ninja & Makefile: Generate compile_commands.json. Used by Clang tools (that many common IDEs
# rely on) to obtain include paths, compile flags, etc. from the build system.
set(CMAKE_EXPORT_COMPILE_COMMANDS     ON  CACHE BOOL "" FORCE)
```

  所以*用开发者档位配置一次，`compile_commands.json` 就出现在构建目录里*，
  把这个文件路径告诉你的编辑器即可。官方也有一页专门讲 VSCode 配置：
  #weblink("https://developer.blender.org/docs/handbook/development_environments/vscode/", label: [Visual Studio Code])。

== 2.8 下一步：把构建变成日常工作流

完成一次构建后，不必继续记忆平台表格。日常工作只需要保留三条稳定路径：依赖或版本变化时
重新执行更新命令；修改 C++ 后对既有构建目录做增量构建；需要断点调试时使用独立的
`debug developer` 构建。不同平台的命令、目录和产物位置已经集中在附录 D，遇到错误再按附录 E 的症状
索引排查。

#summary[
  这一章的要点可以压缩成五句话：

  1. *入口不同*：#win 用 `make.bat`，其余用 `make`；`GNUmakefile` 明确拒绝 Windows。
  2. *预编译依赖通过 Git 子模块引用，子模块中的大文件再由 Git LFS 管理，而不是 SVN*；
     网络不稳定时可以改用镜像，但镜像不替代官方 LFS，
     下载中断后可以续传，但必须按 `git lfs ls-files` 全量核对。
  3. *不同平台使用同一套 CMake 工程与同一批 `build_files/cmake/config/*.cmake` 档位*，
     差异只在生成器、编译器、产物形态与系统依赖。
  4. *改 C++ 源码就用 `debug developer`*；只想快速验证工具链就先 `lite`。
  5. *启动后立刻配好两个调试器插件*（gdb / lldb 的美化打印器），
     它们会让后面所有章节的调试工作轻松一个数量级。
]

#exercise[
  *练习 2.1（必做）* 在你自己的机器上完成一次构建，并回答：
  你的构建目录叫什么名字？它是怎么被拼出来的（给出 Blender 源码中的行号）？
  产物可执行文件的完整路径是什么？

  *练习 2.2* 用 `lite` 与 `full` 各配置一次（可以用 `nobuild` 只配置不编译），
  然后对比两个构建目录里 `CMakeCache.txt` 中 `WITH_USD`、`WITH_CYCLES`、
  `WITH_OPENVDB` 三个变量的值。再打开对应的
  `build_files/cmake/config/*.cmake` 找出它们是在哪一行被设定的。

  *练习 2.3* 分别用下面两条命令启动你构建好的 Blender，
  观察输出的差别，并解释为什么：
  ```bash
  $ ./bin/blender --background --version
  $ ./bin/blender --background --debug-depsgraph-tag --version
  ```

  *练习 2.4* 配置好你所用平台的调试器美化打印器
  （#linux 用 gdb，#mac 用 lldb，#win 可先试 lldb 或用 natvis），
  用自检方法确认它确实注册成功。

  *练习 2.5* 故意制造两个错误并记下报错原文：
  （1）把源码目录复制到一个含空格的路径下再运行 `make.bat`；
  （2）在 POSIX 上把 `lib/<平台>_<架构>` 临时改名后重新配置。
  这两个练习的目的是让你以后能*一眼认出*这两类报错，
  而不是在编译器与 SDK 上白找半天。
]
