#import "../common.typ": *

= 附录 D 三平台构建差异对照表

第 2 章按平台分节讲了完整流程。本附录把它压成一页，供日常查阅。
所有条目都以本书的核对基准版本为准，来源标注在表下。

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.4fr, 1.4fr, 1.4fr),
    inset: 5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*项目*], [#win], [#mac], [#linux]),

    [构建入口],
    [`make.bat`],
    [`make`],
    [`make`],

    [为什么不用 GNU Make],
    [`GNUmakefile` 明确声明不面向 Windows],
    [—],
    [—],

    [编译器],
    [MSVC（本书验证路径；上游另有 clang-cl 支持）],
    [Apple clang（Xcode / CLT 16.0+）],
    [系统 gcc / clang],

    [构建系统生成器],
    [Ninja 或 MSBuild],
    [Ninja 或 Makefiles],
    [Ninja 或 Makefiles],

    [CMake 最低版本],
    [`3.21`（三平台一致）],
    [`3.21`],
    [`3.21`],

    [预编译库子模块],
    [`lib/windows_x64`（x64）\
     `lib/windows_arm64`（arm64）],
    [`lib/macos_arm64`],
    [`lib/linux_x64`],

    [预编译库获取方式],
    [Git LFS 子模块],
    [Git LFS 子模块],
    [Git LFS 子模块],

    [更新源码与库],
    [`make.bat update`],
    [`make update`],
    [`make update`],

    [只更新代码],
    [`make.bat code_update`],
    [`make update_code`],
    [`make update_code`],

    [默认构建类型],
    [`Release`],
    [`Release`],
    [`Release`],

    [构建目录位置],
    [源码上一级，名字形如\
     `build_windows_x64_vc17_Release`],
    [源码上一级，形如\
     `build_darwin`],
    [源码上一级，形如\
     `build_linux`],

    [产物形态],
    [Ninja：`bin\blender.exe`；\
     Visual Studio：`bin\Release\blender.exe`；\
     依赖 `blender.shared\` 下的 DLL],
    [`bin/Blender.app` 应用包],
    [`bin/blender`，\
     同级 `lib/` 用 `$ORIGIN` 定位],

    [是否要手动激活编译器环境],
    [不需要；`make.bat` 会自动检测 VS 并调用 `vcvarsall.bat`],
    [不需要；但必须安装 Xcode 或 CLT],
    [不需要；但必须安装受支持的 GCC 或 Clang],

    [调试器],
    [Visual Studio 调试器 / lldb],
    [lldb],
    [gdb / lldb],

    [生成 IDE 工程],
    [CMake 生成器直接产出 VS 工程],
    [`-G Xcode`，或 `make project_qtcreator` / `project_eclipse`],
    [`make project_qtcreator` / `project_eclipse`],

    [额外注意事项],
    [路径含空格会出问题；首次构建前必须等预编译库下载完成],
    [需要 Xcode 命令行工具；arm64 是当前主推架构],
    [需要按发行版安装开发包；可用 `make deps` 自行编译依赖],
  ),
  caption: [三平台构建差异一览],
) <tbl-platform-matrix>

本表的依据：

- 构建入口与目标名来自 #src("GNUmakefile")；其中第 175 行声明该 Makefile 不面向 Windows。
- Windows 的命令、开关与构建目录命名来自 #src("build_files/windows/parse_arguments.cmd")
  与 #src("build_files/windows/set_build_dir.cmd")。
- 预编译库的四个子模块与获取方式来自 #src(".gitmodules")
  与 #src("build_files/windows/check_libraries.cmd")。
- CMake 最低版本来自 #src("CMakeLists.txt:29")。
- 各平台产物形态来自 #src("build_files/cmake/platform/") 下的平台文件。

#warn[
  macOS 的预编译库子模块*只有 `macos_arm64`*，没有 `macos_x64`。
  也就是说在 Intel Mac 上你无法直接使用官方预编译库，需要自己编译依赖
  （`make deps`）。这是选择开发机时值得提前知道的一点。
]

#summary[
  三平台的差异其实集中在三个地方：*入口命令*（`make.bat` 对 `make`）、
  *编译器工具链的准备方式*（VS / Xcode CLT / 系统 GCC 或 Clang）、以及*产物形态*
  （`.exe` + DLL 目录 / `.app` 包 / 裸可执行文件 + `lib/`）。
  其余部分 —— CMake 配置、Ninja 后端、Git LFS 预编译库、构建类型 —— 三平台是一致的。
]
