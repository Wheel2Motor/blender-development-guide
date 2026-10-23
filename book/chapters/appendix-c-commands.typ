#import "../common.typ": *

= 附录 C Blender 构建与开发命令速查

本附录把全书用到的命令集中到一处，按"我正要做什么"组织。所有内容都以
本书的核对基准版本（见前言）为准，来源在每节标注了源码位置。

#note[
  本附录的开关与参数名全部来自源码中的解析代码，不是从旧文档抄来的：
  Windows 构建开关来自 #src("build_files/windows/parse_arguments.cmd")，
  POSIX 构建目标来自 #src("GNUmakefile")，
  运行时参数来自 #src("source/creator/creator_args.cc")。
]

== C.1 获取与更新源码

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*目的*], [*命令*]),
    [克隆本书固定标签],
    [#raw("git clone --branch " + blender-tag) \
     `--single-branch` \
     `https://projects.blender.org/blender/blender.git`],
    [进入刚克隆的源码目录],
    [`cd blender`],
    [查看当前提交],
    [`git rev-parse HEAD`],
    [查看预编译库子模块配置],
    [`git config --file .gitmodules --get-regexp path`],
    [查看子模块状态],
    [`git submodule status`],
    [只初始化 Windows 预编译库],
    [`git config submodule.lib/windows_x64.update checkout`\
     `git submodule update --init lib/windows_x64`],
  ),
  caption: [源码获取相关命令],
) <tbl-c-source>

#pitfall[
  克隆时如果被中断（例如中途取消 LFS 拉取），可能留下两个后遗症：
  `git` 的*索引为空*（`git ls-files` 无输出、`git status` 显示大量 `D`），
  以及残留的 `.git/index.lock`。前者用 `git reset`（mixed，不动工作区）重建即可；
  后者在确认没有活跃 `git` 进程后删掉锁文件。
]

主仓库自身的 LFS 内容主要是回归测试数据，但 `release/datafiles/` 中也有
`startup.blend`、预览文件和图标数据等构建或运行所需对象。克隆时可以暂时跳过
LFS 下载，但首次配置前必须用 `make update`（#win 为 `make.bat update`）或
`git lfs pull` 将它们还原成实体文件；平台预编译库则位于 `lib/` 子模块。

== C.2 构建：#win

Windows 上*不能用 GNU Make 驱动构建* —— 源码里写得很清楚：

```text
# GNUmakefile:175
# This makefile is not meant for Windows,
```

Windows 的入口是同目录下的 `make.bat`，它做的是「检测环境 → 配置 CMake → 构建」的完整流程，
默认在源码目录的上一级创建构建目录 `..\build_windows`，默认构建类型为 `Release`。

```bash
$ make.bat ninja
```

`ninja` 开关让 `make.bat` 使用 Ninja 而不是 MSBuild。构建目录的最终名字会带上架构、
VS 版本与构建类型，例如 `build_windows_x64_vc17_Release`。

=== C.2.1 构建开关速查

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*开关*], [*作用*]),
    table.cell(colspan: 2, align: center)[*构建类型与配置*],
    [`ninja`], [用 Ninja 而不是 MSBuild 构建],
    [`debug`], [构建类型设为 `Debug`（默认是 `Release`）],
    [`release`], [套用 `blender_release.cmake` 配置],
    [`developer`], [套用 `blender_developer.cmake`：开发者向的默认选项与更多警告],
    [`full`], [套用 `blender_full.cmake`：打开全部可选功能],
    [`lite`], [套用 `blender_lite.cmake`：关闭可选组件，构建更快],
    [`cycles`], [套用 `cycles_standalone.cmake`：只构建 Cycles],
    [`headless`], [套用 `blender_headless.cmake`：无界面构建],
    [`bpy`], [套用 `bpy_module.cmake`：构建可作为 Python 模块导入的 `bpy`],
    [`asan`], [打开地址消毒器（`-DWITH_COMPILER_ASAN=On`）],
    [`sccache`], [启用 sccache 编译缓存],
    [`clean`], [构建前清理构建目录],
    [`nobuild`], [只配置不构建],
    [`nobuildinfo`], [关闭构建信息写入（`-DWITH_BUILDINFO=OFF`）],
    [`builddir <路径>`], [自定义构建目录（带盘符视为绝对路径，否则相对源码上一级）],
    table.cell(colspan: 2, align: center)[*平台与编译器*],
    [`x64` / `arm64`], [指定目标架构（`x86` 已不支持，会直接报错）],
    [`2019` / `2019b`], [解析器保留的旧开关；不满足 Blender 5.2.2 的 MSVC 最低版本，不能用于本书基准],
    [`2022` / `2026`], [指定 Visual Studio 年份；`b` 用 Build Tools 版，`pre` / `i` 用预览版],
    [`packagename <名>`], [覆盖 CPack 打包名（`-DCPACK_OVERRIDE_PACKAGENAME`）],
    [`pydebug`], [启用 Python 调试构建],
    [`clang`], [用 clang-cl 而不是 MSVC 编译],
    [`msvc`], [在 arm64 上强制使用 MSVC（不受支持，仅供参考）],
    table.cell(colspan: 2, align: center)[*更新与维护*],
    [`update`], [更新源码、子模块与预编译库],
    [`code_update`], [只更新代码，不更新预编译库（等价于 `--no-libraries`）],
    table.cell(colspan: 2, align: center)[*测试与工具*],
    [`test`], [运行测试（隐含 `nobuild`）],
    [`with_tests`], [配置时打开 C++ 单元测试（`-DWITH_GTESTS=ON`）],
    [`with_gpu_tests`], [配置时打开 GPU 测试],
    [`format`], [按 `.clang-format` 格式化代码],
    [`license`], [检查许可证头],
    [`icons_geom`], [重新生成图标几何数据],
    [`doc_py`], [生成 Python API 文档],
    [`showhash`], [只显示当前提交信息，不构建],
    [`verbose`], [打印详细过程],
    [`help`], [打印帮助],
  ),
  caption: [`make.bat` 的完整开关列表（来源：`build_files/windows/parse_arguments.cmd`）],
) <tbl-c-makebat>

=== C.2.2 常用组合

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*命令*], [*用途*]),
    [`make.bat update`], [首次或长期未更新后：拉源码、子模块与预编译库],
    [`make.bat ninja`], [日常构建：配置（若需要）并构建，Release + Ninja],
    [`make.bat ninja debug`], [日常*调试*构建：带符号、可用于断点],
    [`make.bat ninja developer`], [开发者构建：打开更多检查与可选功能],
    [`make.bat ninja lite`], [快速构建：关掉可选组件，编译时间明显更短],
    [`make.bat nobuild`], [只生成构建系统，不编译（改完 CMake 选项后用）],
    [`make.bat ninja clean`], [构建前清理，用于排查奇怪的构建错误],
  ),
  caption: [Windows 下最常用的几个组合],
) <tbl-c-makebat-combos>

#tip[
  首次构建成功后，构建目录里会生成一个 `rebuild.cmd`。它会先激活 Visual Studio 环境
  再执行 `ninja install`，因此*后续增量重建直接运行它即可*，不必再走一遍 `make.bat`
  的环境检测。这是日常迭代最快的路径。
]

== C.3 构建：#mac #linux

macOS 与 Linux 使用源码根目录的 `GNUmakefile`，通过 `make` 驱动同一套 CMake 构建。

```bash
$ make update      # 首次：拉取与更新预编译库
$ make             # 配置（若需要）并构建
$ make debug       # 调试构建
```

=== C.3.1 `make` 目标速查

#figure(
  kind: table,
  table(
    columns: (0.85fr, 1.5fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*目标*], [*作用*]),
    table.cell(colspan: 2, align: center)[*构建*],
    [`all`], [默认目标：配置（若需要）并构建],
    [`release` / `debug` / `full` / `lite`  / `headless` / `bpy` / `cycles` / `developer`],
    [选择对应的配置或构建类型（与 Windows 的开关语义一致）],
    [`ninja`], [使用 Ninja 作为后端],
    [`ccache`], [启用 ccache 编译缓存],
    table.cell(colspan: 2, align: center)[*依赖*],
    [`deps`], [在 `build_files/build_environment` 下自行编译依赖（不使用预编译库时）],
    [`config`], [打开已有构建目录的 `cmake-gui` 或 `ccmake`；不会从零生成构建目录],
    table.cell(colspan: 2, align: center)[*更新与清理*],
    [`update`], [更新源码与预编译库],
    [`update_code`], [只更新代码，不更新预编译库],
    [`clean`], [清理构建产物],
    table.cell(colspan: 2, align: center)[*测试*],
    [`test`], [运行测试套件],
    [`benchmark`], [运行基准测试],
    table.cell(colspan: 2, align: center)[*静态检查*],
    [`check_cppcheck` / `check_mypy`  / `check_pep8` / `check_clang_array`],
    [分别运行 cppcheck、mypy、PEP8、clang 数组检查],
    [`check_spelling_c` / `check_spelling_py`  / `check_spelling_cmake` / `check_spelling_shaders`],
    [各类拼写检查],
    [`check_descriptions` / `check_deprecated` / `check_licenses` / `check_cmake`],
    [文档描述、弃用项、许可证头、CMake 规范检查],
    [`check_struct_comments` / `check_size_comments` / `check_docs_file_structure`],
    [结构体注释、尺寸注释、文档目录结构检查],
    table.cell(colspan: 2, align: center)[*工程与文档*],
    [`project_qtcreator` / `project_eclipse`], [生成对应 IDE 的工程文件],
    [`doc_py` / `python_stubs`], [生成 Python API 文档 / 生成 Python 存根],
    [`doc_doxy` / `doc_dna` / `doc_man`], [生成 Doxygen / DNA / man 文档],
    [`help_features`], [列出所有可用的 CMake 功能开关],
    table.cell(colspan: 2, align: center)[*发布与其他*],
    [`package_archive` / `source_archive`], [打包二进制归档 / 打包源码归档],
    [`icons_geom`], [重新生成图标几何数据],
    [`format` / `license`], [格式化代码 / 检查许可证],
    [`help`], [打印帮助],
  ),
  caption: [`make` 目标列表（来源：`GNUmakefile`）],
) <tbl-c-make>

== C.4 运行与调试

构建完成后，Blender 可执行文件位于构建目录的 `bin/` 下：#win 的 Ninja 构建是
`bin\blender.exe`，默认 Visual Studio 生成器是 `bin\Release\blender.exe`；
#mac 是 `bin/Blender.app` 包，#linux 是 `bin/blender`。

=== C.4.1 启动与批处理

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*参数*], [*作用*]),
    [`-b` / `--background`], [无界面模式，用于脚本与批处理],
    [`-c` / `--command`], [执行某个命令后退出（隐含 `--background`）],
    [`-X` / `--factory-startup`], [忽略用户配置与插件，以出厂设置启动 —— 排查"是不是插件搞的鬼"的第一选择],
    [`-a` / `--render-anim`], [渲染整个动画序列],
    [`-f` / `--render-frame <n>`], [渲染指定帧],
    [`-o` / `--render-output <路径>`], [指定渲染输出路径],
    [`-E` / `--engine <引擎>`], [指定渲染引擎],
    [`-F` / `--render-format <格式>`], [指定输出格式],
    [`-s` / `--frame-start` / `-e` / `--frame-end` / `-j` / `--frame-jump`],
    [渲染帧范围的起点、终点与步长],
    [`-t` / `--threads <n>`], [指定线程数],
    [`-q` / `--quiet`], [减少输出],
    [`--verbose`], [增加输出],
    [`-v` / `--version`], [打印版本并退出],
    [`-h` / `--help`], [打印帮助并退出],
  ),
  caption: [启动与批处理参数（来源：`source/creator/creator_args.cc`）],
) <tbl-c-cli>

=== C.4.2 Python 相关

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*参数*], [*作用*]),
    [`--python <文件>`], [启动后执行该 Python 脚本],
    [`--python-text <名称>`], [执行一个文本数据块里的脚本],
    [`--python-expr <表达式>`], [直接执行一段 Python 表达式],
    [`--python-console`], [进入 Python 交互控制台],
    [`--python-exit-code <n>`], [脚本异常时以此退出码退出，*脚本化调用务必设置*],
    [`--python-use-system-env`], [允许 Python 读取系统环境变量],
    [`--python-use-user-env`], [允许 Python 读取用户环境变量],
    [`--addons <列表>`], [以逗号分隔的插件列表启动],
  ),
  caption: [Python 相关参数],
) <tbl-c-cli-python>

=== C.4.3 调试参数

`--debug` 家族是一组非常实用的开关。它们大多只影响日志输出，可以按需叠加。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*参数*], [*作用*]),
    [`-d` / `--debug`], [打开调试输出],
    [`--debug-all`], [打开所有调试输出（输出量很大）],
    [`--debug-python`], [Python 解释器与绑定的调试输出 —— *写插件时最常用*],
    [`--debug-value <n>`], [设置一个调试用整数值，供代码内部分支使用],
    [`--debug-events`], [事件处理输出],
    [`--debug-handlers`], [事件处理器输出],
    [`--debug-wm`], [窗口管理器输出],
    [`--debug-jobs`], [任务调度输出],
    [`--debug-ghost`], [窗口系统 GHOST 层输出],
    [`--debug-gpu`], [GPU 相关输出],
    [`--debug-gpu-force-workarounds`], [强制启用 GPU 兼容性变通],
    [`--debug-gpu-compile-shaders`], [打印着色器编译信息],
    [`--debug-memory`], [内存分配调试信息],
    [`--debug-fpe`], [浮点异常处理设置],
    [`--debug-io`], [文件读写（Blender I/O）调试],
    [`--debug-exit-on-error`], [遇到错误立即退出，便于配合调试器],
    [`--debug-cycles`], [Cycles 相关调试输出],
  ),
  caption: [调试参数（节选）],
) <tbl-c-cli-debug>

依赖图是第 2 篇的重点，它有一组专用开关：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*参数*], [*作用*]),
    [`--debug-depsgraph`], [依赖图求值的基本输出],
    [`--debug-depsgraph-build`], [输出依赖图的构建/重建过程],
    [`--debug-depsgraph-eval`], [输出求值过程],
    [`--debug-depsgraph-tag`], [输出标记脏（tag）的过程],
    [`--debug-depsgraph-time`], [输出各环节耗时 —— 定位性能问题的起点],
    [`--debug-depsgraph-no-threads`], [求值强制单线程，便于对输出排序],
    [`--debug-depsgraph-pretty`], [美化输出排版],
    [`--debug-depsgraph-uid`], [输出中包含唯一标识，便于对照],
  ),
  caption: [依赖图调试参数],
) <tbl-c-cli-depsgraph>

=== C.4.4 其他常用参数

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*参数*], [*作用*]),
    [`--log <类别>`], [开启日志类别，支持通配与排除，例如 `--log "*"`、`--log "*mesh*"`、`--log "*,^operator"`],
    [`--log-level <级别>`], [设置日志级别],
    [`--log-file <文件>`], [把日志写到文件],
    [`--log-list-categories`], [列出所有可用日志类别并退出],
    [`--log-show-source` / `--log-show-backtrace` / `--log-show-memory`],
    [日志中附带源码位置、回溯、内存信息],
    [`--gpu-backend <后端>`], [指定 GPU 后端],
    [`--gpu-device <设备>`], [指定 GPU 设备],
    [`--profile-gpu`], [GPU 性能分析],
    [`--factory-startup`], [同 `-X`],
    [`--app-template <模板>`], [以指定应用模板启动],
    [`--env-system-scripts <路径>`], [覆盖系统脚本目录（其余 `--env-system-*` 同理）],
    [`--online-mode` / `--offline-mode`], [强制联网 / 离线模式],
    [`--enable-autoexec` / `--disable-autoexec`], [允许 / 禁止脚本自动执行],
    [`-r` / `--register`], [把 `.blend` 关联到本程序（*文件类型关联*，Windows 与 Linux 有效），执行后立即退出。注意这*不是*注册插件],
    [`--register-allusers`], [为所有用户注册扩展],
    [`--unregister` / `--unregister-allusers`], [注销扩展],
    [`--no-window-focus`], [启动时不抢焦点],
    [`-p` / `--window-geometry <x y w h>`], [指定窗口位置与大小],
    [`-W` / `--window-fullscreen`], [全屏启动],
    [`--start-console`], [同时打开控制台窗口（#win）],
  ),
  caption: [其他常用参数],
) <tbl-c-cli-misc>

== C.5 源码定位

"我该改哪一行"是第 2 篇反复出现的问题。下面这些检索套路比通读代码高效得多。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*我要找*], [*怎么找*]),
    [某个界面文字对应的代码],
    [直接检索该字符串，通常会命中界面的按钮或菜单定义，再顺着回调找到实现],
    [某个操作符的实现],
    [先找它的 `WM_OT_` 函数名（例如 `WM_OT_xxx`），再检索 `WM_operatortype_append` 附近的注册处],
    [某个 RNA 属性的定义],
    [在 `source/blender/makesrna/intern/` 下检索 `RNA_def_` 加属性名],
    [某个 DNA 字段的定义],
    [在 `source/blender/makesdna/` 下检索字段名],
    [某个类型的所有使用点],
    [检索 `BKE_` / `ED_` / `DEG_` 等前缀加函数名],
    [某个宏的取值],
    [检索宏名，或看它所在的枚举定义],
    [某个开关背后的 CMake 选项],
    [`make help_features`（#mac #linux）或检索 `CMakeLists.txt`],
  ),
  caption: [源码定位常用套路],
) <tbl-c-grep>

#summary[
  本附录的骨架可以概括成三句话：*Windows 用 `make.bat`，macOS/Linux 用 `make`；
  排查问题时先加 `-X`（排除用户配置与插件干扰），再按需叠加 `--debug-*`；
  找代码时不要通读，而是"从界面文字或数据字段反查"。*
]
