#import "../common.typ": *

= 第 17 章　测试与上游贡献

到这里，你已经能构建、能定位、能修改、能测量 Blender 的 C++ 源码了。
剩下最后一个问题，也是决定你的改动能不能留下来、能不能被别人接受的问题：
*你怎么证明它是对的，以及怎么把它送回上游。*

这两个问题在 Blender 这种规模的项目里不是礼节，而是硬需求。
第 16 章讲了"优化完成后必须执行测试"；反过来，任何在核心代码里的改动
—— 改一个求值顺序、动一个数据结构的布局、换一个默认值 ——
都可能影响几百个已有场景。上游对补丁的要求因此集中在两点：
*能复现、能验证*。

本章分四步：先看测试体系怎么组织（17.1），再看把改动送出去要遵守的
规范（17.2），然后是模块与评审流程（17.3），最后在 §17.3.4 给出一条实际可行的
贡献路线。

== 17.1 测试体系

=== 17.1.1 三级测试与两个入口

Blender 的测试可以按"测试对象、编写方式、执行耗时"分成三级。它们的编写位置、
运行开关和前置条件都不一样，混在一起记一定会乱。

#figure(
  kind: table,
  table(
    columns: (1.1fr, 1.5fr, 1.7fr, 0.75fr),
    inset: 5.5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*级别*], [*代码在哪*], [*测什么*], [*要测试数据*]),
    [C++ 单元测试],
    [`source/blender/*/tests/` 与若干 `*_test.cc`（共 209 个文件）],
    [单个函数、单个容器、单个算法。不启动界面],
    [少数需要],
    [Python 集成测试],
    [`tests/python/`（`bl_blendfile_*`、`bl_animation_*` 等）],
    [从 `bpy` 出发，处理真实文件并执行操作符、渲染与导入导出],
    [大量需要],
    [压力测试工具],
    [`tests/utils/`],
    [批量加载 `.blend`、模拟用户输入、模糊测试导入器。
     *不是*自动测试，需要手动执行],
    [需要],
  ),
  caption: [三级测试。第三级的定位由 `tests/utils/readme.rst:5-7` 明确说明：它们"不打算作为自动单元测试运行"，而是用于压力测试与 `git bisect`。],
) <tbl-test-levels>

三级测试共用一套调度器。整条链路是这样的：

```text
make test（#win 是 make.bat test）
  └─ build_files/utils/make_test.py
       └─ ctest . --output-on-failure -O <构建目录>/tests/log.txt
            ├─ C++ 单元测试（GTest 可执行文件）
            └─ Python 集成测试（用 ctest 驱动 blender 可执行文件）
```

三个环节都能在源码里对到行号：

- 入口目标。`GNUmakefile` 的测试目标单独成块，注释原文写着
  "Not associated with building Blender"（#src("GNUmakefile:50-54")），
  目标本身在 #src("GNUmakefile:477-478")：
  `test: .FORCE` 执行 `build_files/utils/make_test.py "$(BUILD_DIR)"`。
  #win 的对应脚本是 #src("build_files/windows/test.cmd:11")，
  它把 `--git-command`、`--ctest-command` 和 `--config`（构建类型）传进去。
- 调度脚本。#src("build_files/utils/make_test.py:47-59") 做三件事 ——
  在构建目录下建 `tests/`、切到构建目录、然后执行
  `ctest . --output-on-failure -O tests/log.txt`。
  注意 `-O` 会把完整日志写到 `<构建目录>/tests/log.txt`：
  *测试失败时先看这个文件，而不是往上翻终端输出。*
- 测试定义。Python 测试的每一个用例都由 CMake 注册成一条 ctest 用例。
  注册函数是 #src("tests/python/CMakeLists.txt:49-58") 的 `add_blender_test()`，
  文件里共有 116 处 `add_blender_test(` 调用。

#tip[
  `ctest` 的两个参数在日常里最省时间：
  `ctest -R <正则>` 只执行匹配的用例，`ctest -j <n>` 并行执行。
  例如只想验证你自己改的那一块：
  `ctest -R bl_animation --output-on-failure`。
  `make test` 只是这两个参数都不给的"执行全部测试"版本。
]

#win 上 `make.bat test` 有一个容易踩到的行为：它*隐含 `nobuild`*
（`build_files/windows/parse_arguments.cmd:110-112`），也就是说
*它只执行测试，不先构建*。这与其他开关的直觉相反 ——
POSIX 上也没有对应的"构建后再测"目标，`make test` 同样不构建。
所以两条命令是固定搭配：

```bash
# POSIX
$ make -j$(nproc) && make test

# Windows
> make.bat ninja && make.bat test
```

=== 17.1.2 统一测试参数：`tests/CMakeLists.txt:56`

Python 集成测试不是"随便执行一个脚本"。每个用例都由一组固定的命令行参数启动，
这组参数写在 #src("tests/CMakeLists.txt:56-63")：

```text
# tests/CMakeLists.txt:56-63
--background
--console-crash-handler
--factory-startup
--debug-memory
--debug-exit-on-error
--python-exit-code 1
```

逐条都值得理解，因为它们正好是第 2 章与第 16 章讲过的那些开关的组合：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 2.6fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*参数*], [*为什么测试要用它*]),
    [`--background`], [不启动界面。测试必须能在无人值守的环境里执行],
    [`--console-crash-handler`], [崩溃信息打到控制台，而不是写成文件。CI 里这一步很关键],
    [`--factory-startup`], [忽略用户配置与插件。*你的插件不会影响测试结果*],
    [`--debug-memory`], [切到完全受保护的分配器，越界写与泄漏能被抓到（见第 16 章 §16.1.2）],
    [`--debug-exit-on-error`], [检测到错误立即以非零码退出，而不是"执行完毕、但结果是错的"],
    [`--python-exit-code 1`], [脚本抛异常时以退出码 1 结束。没有这一条，CI 会把失败当成功],
  ),
  caption: [统一测试参数（`tests/CMakeLists.txt:56-63`）与它们的用途。这套组合也是你自己写复现脚本时该照抄的模板。],
) <tbl-test-params>

这解释了一个新手常见的困惑："为什么我在界面中手动执行时一切正常，`make test` 却失败？"
因为这组参数关掉了界面、关掉了你的插件与偏好设置，并且打开了三个会
*主动报错*的调试开关。测试比手工操作严格得多，这是有意的 ——
它要抓的正是"你的机器上恰好没出问题"的那类缺陷。

=== 17.1.3 C++ 单元测试：GTest

C++ 单元测试用 GoogleTest（含 gmock）。三个相关事实：

*一、框架随源码分发。* `extern/gtest` 与 `extern/gmock` 就在仓库里，
不需要额外下载。它们只在 `WITH_GTESTS` 打开时才被加进构建
（#src("extern/CMakeLists.txt:82-85")）。这个选项的定义与默认值在
#src("CMakeLists.txt:777-778")：

```text
# CMakeLists.txt:777-778
# Unit testing
option(WITH_GTESTS "Enable GTest unit testing" OFF)
```

默认是 `OFF` —— 也就是说，*默认构建里没有可执行的单元测试*。
打开它的最省事办法是用开发者档位（`blender_developer.cmake:22` 里有
`set(WITH_GTESTS ON CACHE BOOL "" FORCE)`，见第 2 章 §2.6.3），
#win 上也可以用 `make.bat with_tests`
（#src("build_files/windows/parse_arguments.cmd:24-25")，
它加的正是 `-DWITH_GTESTS=ON`）。

*二、测试按模块组织，每个模块一个测试套件。* 套件由宏
`blender_add_test_suite_executable(name ...)` 声明，例如
#src("source/blender/blenlib/CMakeLists.txt:616") 那一行就是 blenlib 的套件，
它的源文件列表从 #src("source/blender/blenlib/CMakeLists.txt:509") 开始，
是一长串 `tests/BLI_*_test.cc`。*仅 `source/blender/` 下*就有 209 个
`*_test.cc`（口径：`git ls-files 'source/blender/**/*_test.cc'`；
整个仓库含 `intern/`、`extern/` 与 `tests/gtests/` 共 291 个）。
套件注册点合计 32 处：29 处 `blender_add_test_suite_lib(`
（`git grep 'blender_add_test_suite_lib('` 的 30 个命中里，
`build_files/cmake/testing.cmake:297` 是一条注释），加上 3 处
`blender_add_test_suite_executable(`（`intern/cycles`、`intern/guardedalloc`
与 `source/blender/blenlib`）—— 后者正是上面那一行用到的宏。

*三、默认把它们链成一个可执行文件。* 由 `WITH_TESTS_SINGLE_BINARY` 控制，
默认 `ON`（#src("CMakeLists.txt:864-869")），配套的是
`tests/gtests/runner/` 下的 `blender_test` 可执行文件
（#src("tests/gtests/CMakeLists.txt:9-12")）。
这么做是为了加快整体构建、少占磁盘，代价是*单独构建某一个测试变慢*。

测试辅助设施在 #src("tests/gtests/testing/")：
`testing.h` 把 gtest、gmock、glog、gflags 一起引入
（#src("tests/gtests/testing/testing.h:10-12")），并提供
`EXPECT_V3_NEAR` 这类浮点比较宏
（#src("tests/gtests/testing/testing.h:41-47")）—— 写几何断言时别用
`EXPECT_EQ` 比浮点。

还有一点与第 16 章相呼应：GTest 用例可能需要在运行期申请临时内存做
分配失败测试，这类需求在 `testing.h` 里有专门的支持。
但真正需要记住的是*测试所需的资源路径*是怎么传进来的：
`blender_add_ctests()` 用 `gtest_add_tests(...)` 注册用例时，
通过 `EXTRA_ARGS` 传两个参数
（#src("build_files/cmake/testing.cmake:152-162")）：

```text
--test-assets-dir  <源码目录>/tests/files
--test-release-dir <安装目录>/<Blender 版本号>
```

它们由 ctest 自动加到每一条用例上。两个 flag 本身就定义在测试主程序里
（#src("tests/gtests/testing/testing_main.cc:11-12")），
读取它们的函数是 #src("tests/gtests/testing/testing.h:24-27") 里的
`flags_test_asset_dir()` 与 `flags_test_release_dir()`。
实现里有一处细节很值得记住：*如果对应的 flag 是空的，函数会直接
`ADD_FAILURE()`*，报错原文是
"Pass the flag --test-assets-dir and point to the tests/files directory."
（#src("tests/gtests/testing/testing_main.cc:16-31")）。
*这正是"直接手敲测试可执行文件会失败"的原因* —— 这两个参数缺席了。

还有一个与第 16 章相呼应的设计：*GTest 的 `main` 会在执行任何用例之前
无条件打开受保护分配器与内存泄漏检测*，并让泄漏直接导致失败
（#src("tests/gtests/testing/testing_main.cc:42-46")）：

```cpp
/* tests/gtests/testing/testing_main.cc:44-46（节选） */
MEM_use_guarded_allocator();
MEM_init_memleak_detection();
MEM_enable_fail_on_memleak();
```

这与 Python 测试那组参数里的 `--debug-memory` 和 `--debug-exit-on-error`
是同一个意图：*测试环境默认按最严格的方式运行。*
你写单元测试时因此不需要自己申请/释放检查器 ——
只要不泄漏，测试就会通过；泄漏了，测试就会失败，
而报告里会给出分配点的名字（见第 16 章 §16.4.4 的 `MEM_printmemlist`）。

=== 17.1.4 `tests/files/` 是 Git LFS 数据 —— 这是必须预先说明的问题

这是本章最实用的一节。如果你的克隆没有拉全 Git LFS 对象，
*大量测试会因为"测试数据缺失"而失败，而报错信息完全不会告诉你这一点*。

先看这个问题是怎么埋下的。`tests/python/CMakeLists.txt:17` 有一句判定：

```text
# tests/python/CMakeLists.txt:16-29（节选）
# Check which tests can be enabled.
if(IS_DIRECTORY ${TEST_SRC_DIR}/render)
  set(TEST_SRC_DIR_EXISTS TRUE)
  ...
else()
  set(TEST_SRC_DIR_EXISTS FALSE)
  message(STATUS "Tests: Disabling most tests, no test data in ${TEST_SRC_DIR}")
endif()
```

它只看 `tests/files/render` 这个目录*存不存在*。也就是说：
配置阶段就静默地少注册了几百个测试用例。你不会看到任何错误，
只是测试"变少了"。

而 `tests/files/` 下的数据是 Git LFS 对象。相关的 LFS 规则在
#src(".gitattributes") 里，测试数据里数量最多的几种类型全在其中：
`.blend`（#src(".gitattributes:15")）、`.png`（#src(".gitattributes:17")）、
`.exr`（#src(".gitattributes:18")）、`.abc`（#src(".gitattributes:50")）、
`.fbx`（#src(".gitattributes:91")）。

本书核对环境里这个问题是*实测*出来的，数字如下：

#figure(
  kind: table,
  table(
    columns: (2.4fr, 1.2fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*项目*], [*数量*]),
    [`tests/files/` 下实际检出的文件], [2,038],
    [`git ls-files tests/files` 记录的文件], [6,897],
    [`git status` 报为删除（`D`）的条目], [4,859],
    [`git lfs ls-files` 里 `tests/files/` 下的对象], [6,311],
    [本地 `.git/lfs/objects/` 里实际存在的对象], [1,701],
  ),
  caption: [`tests/files/` 的 LFS 缺失实测（本书核对基准版本、本机检出）。第二行远大于第一行，说明工作区里缺了近 5000 个文件。],
) <tbl-lfs-gap>

怎么自查？先进入你自己的 Blender 源码根目录，再执行：

```powershell
> git status --porcelain tests/files | Select-String "^ D" | Measure-Object
```

在干净但 LFS 未拉全的检出里，你会看到几千行以 `D` 开头的条目。
这不是你删的 —— 这就是没拉全。

修法：

```bash
$ git lfs pull
```

#pitfall[
  在 LFS 未拉全的检出上执行 `make test`，你会得到一批"看起来像代码 bug"的失败：
  网格对比测试找不到参考图、导入导出测试找不到输入 `.blend`、
  渲染回归测试没有 ground truth。*在开始排查代码之前，先执行一次
  `git status --porcelain tests/files`。* 这一步能省下大量白费功夫。
  第 2 章 §2.2.5 已经指出，并非所有主仓库 LFS 数据都会参与构建；这里要补上另一半：
  `tests/files/` 下的数据虽然不是 Blender 主程序的构建输入，却是回归测试所必需的。
]

=== 17.1.5 用例的两级严格度

统一的参数组里有一条会*被部分用例主动去掉*：`--debug-exit-on-error`。
原因写在注册函数自己的注释里
（#src("tests/python/CMakeLists.txt:60-64")）：

```text
# tests/python/CMakeLists.txt:60-64（节选）
function(add_blender_test_allow_error testname)
  # Remove `--debug-exit-on-error` since errors are printed on e.g. meshes with
  # invalid data or failed image loading, but sometimes we want to test those.
  set(EXE_PARAMS ${TEST_BLENDER_EXE_PARAMS})
  list(REMOVE_ITEM EXE_PARAMS --debug-exit-on-error)
```

这解释了测试体系里的两级严格度：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 2.5fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*注册函数*], [*适用场景*]),
    [`add_blender_test`],
    [正常用例。*任何*内部错误都会让用例失败 —— 这是默认值，
     也是你应该优先选择的那一级],
    [`add_blender_test_allow_error`],
    [*故意*制造非法数据的用例（损坏的网格、加载失败的图片）。
     去掉 `--debug-exit-on-error` 之后，被测试代码打印的错误不再
     升级为失败],
  ),
  caption: [两级严格度（`tests/python/CMakeLists.txt:49-58` 与 `:60-73`）。写新用例时先问一句：我是不是真的在测一个错误路径？],
) <tbl-test-strictness>

#tip[
  这条区分对你写新用例很有用。如果你在为"错误处理"写测试
  —— 比如"加载损坏的图片时要给出友好提示而不是崩溃" ——
  用 `add_blender_test_allow_error`；其余情况一律用 `add_blender_test`。
  反过来，如果你发现自己想用 `allow_error` 只是因为"不改它就无法通过测试"，
  那说明你的代码真的有问题。
]

界面的模拟测试还多一层前置条件：它需要能够启动无头 Wayland。
相关变量（`WESTON_BIN`、`WAYLAND_ROOT_DIR` 等）由 CMake 在
`WITH_UI_TESTS` 打开时组装成测试环境变量
（#src("tests/python/CMakeLists.txt:75-104")）。

=== 17.1.6 参考数据、报告与更新机制

Python 集成测试里有相当一部分是*视觉对比*：把渲染结果与
`tests/files/` 下的参考图逐像素比较。这套机制的四个部分值得知道：

*一、参考数据由测试脚本自己更新，而不是你手动拷。* 当对比失败时，
生成的报告 HTML 里会直接给出应执行的命令
（#src("tests/python/modules/render_report.py:424-428")）：

```text
Run this command to regenerate reference (ground truth) images:
BLENDER_TEST_UPDATE=1 ctest -R <引擎名>
...
Be sure to commit the new reference images under the tests/files folder afterwards.
```

`BLENDER_TEST_UPDATE` 这个环境变量是整套机制的开关，
在多个测试模块里被读取（`render_report.py:298`、`io_report.py:94`、
`mesh_test.py:225`、`imbuf_test.py:35` 等）。

*二、报告是 HTML。* 测试会把对比结果渲染成 `report.html` 写到
构建目录的 `tests/` 下。#src("tests/python/CMakeLists.txt:9") 把
测试输出目录设置为构建目录下的 `tests/`，报告文件名见
#src("tests/python/modules/render_report.py:499")。
看报告比读终端输出快得多。

*三、单条用例可以用 `ctest -R` 重新执行。* 报告里给出的命令就是
`ctest -R <用例名>`，这也是日常改渲染相关代码时最快的循环。

*四、这也是为什么测试失败可能是"你在改别人的参考图"。*
如果 LFS 拉全了但你本地对输出做了无意的改动，测试会报对比失败，
而报告会建议你重新生成参考图。*不要盲目接受那个建议* ——
先确认这是不是你真的想要的输出变化。

=== 17.1.7 性能基准：另一套东西

Blender 还有一个独立的性能基准框架，它与功能测试是两套机制：

- 目标：`make benchmark`（#src("GNUmakefile:480-481")）执行
  #src("build_files/utils/make_benchmark.py")。
- 框架本体在 #src("tests/performance/")：`benchmark.py` 是入口，
  `api/` 是基础设施（`config.py`、`device.py`、`table.py`、`graph.py`），
  `tests/` 下是按功能域的用例（`animation.py`、`cycles.py`、`eevee.py`、
  `geometry_nodes.py`、`sculpt.py`、`undo.py` 等）。
- 它不把基准数据放在主仓库，而是从另一个仓库
  `blender-benchmarks` 拉（#src("build_files/utils/make_benchmark.py:39-44")）。
- 官方说明见 #weblink("https://developer.blender.org/docs/handbook/testing/performance/", label: [Performance Testing])，
  这条网址就写在 #src("tests/performance/benchmark.py:8") 的文档字符串里。

第 16 章的方法论可以直接用在这里：*先有一个稳定的数字，
再谈优化*。`tests/performance/` 提供的就是"稳定的数字"那一层。

=== 17.1.8 静态检查：不执行代码也能发现问题

`GNUmakefile` 里还有一整组 `check_*` 目标。它们不在 `test` 里，
是提交前的自检工具。与 C++ 源码改动最相关的几个：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 2.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*目标*], [*检查什么*]),
    [`make format`],
    [按 `.clang-format` 格式化 C/C++，并按 autopep8 格式化 Python
     （#src("GNUmakefile:623-625")）],
    [`make license`],
    [许可证头（#src("GNUmakefile:627-628")，脚本为
     `tools/utils_maintenance/make_license.py`）],
    [`make check_pep8`],
    [Python 代码风格（#src("GNUmakefile:588-590")，脚本 `tests/python/pep8.py`）],
    [`make check_mypy`],
    [Python 类型检查（#src("GNUmakefile:522-523")）],
    [`make check_cppcheck`],
    [用 cppcheck 扫 C/C++（#src("GNUmakefile:499-504")）],
    [`make check_clang_array`],
    [数组越界类问题的静态检查（#src("GNUmakefile:517-520")）],
    [`make check_struct_comments`],
    [结构体成员的注释完整性（#src("GNUmakefile:506-511")）],
    [`make check_size_comments`],
    [结构体尺寸注释（#src("GNUmakefile:513-515")）],
    [`make check_cmake`],
    [CMake 文件的一致性（#src("GNUmakefile:592-594")）],
    [`make check_spelling_c` / `check_spelling_py`],
    [拼写检查（各有各的缓存文件，见 #src("GNUmakefile:529-539")）],
  ),
  caption: [提交前常用的静态检查目标（#win 上多数由 `make.bat` 的对应动作覆盖；完整清单见附录 C）。],
) <tbl-check-targets>

#win 上 `make format` 的对应物是 `make.bat format`，
它的实现有两处细节值得知道（#src("build_files/windows/format.cmd")）：
它*先用 `lib\windows_x64\llvm\bin\clang-format.exe`*（没有就试 `arm64`），
找不到就报 `clang-format not found` 并退出；然后把它加进 `PATH`
再调用 `tools/utils_maintenance/clang_format_paths.py`，最后调用 autopep8。
也就是说，*Windows 上格式化不需要你自己装 clang-format*，预编译库里就有。

== 17.2 代码规范、提交信息与评审

=== 17.2.1 代码规范：机器能查的和机器查不到的

C/C++ 的格式规范全部由仓库根目录的 `.clang-format` 描述。几个能解释
"为什么 Blender 的代码长这样"的设置：

#figure(
  kind: table,
  table(
    columns: (1.7fr, 0.95fr, 2fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*选项*], [*取值*], [*效果*]),
    [`ColumnLimit`], [`99`], [每行上限 99 列，不是常见的 80],
    [`IndentWidth` / `TabWidth`], [`2` / `2`], [两格缩进，不用制表符（`UseTab: Never`）],
    [`BinPackParameters`], [`false`], [参数不挤在一行，换行时每个参数一行],
    [`AlignAfterOpenBracket`], [`Align`], [续行与开括号后第一个参数对齐],
    [`IndentCaseLabels`], [`true`], [`case` 标签缩进一级],
    [`SortIncludes`], [`true`], [include 自动排序],
    [`BreakBeforeBraces`], [`Custom`], [花括号风格由 `BraceWrapping` 逐项指定],
  ),
  caption: [`.clang-format` 里最能解释代码外观的七项设置（行号见 `.clang-format:38`、`:106-108`、`:34-35`、`:13`、`:78`、`:135`、`:62-63`）。],
) <tbl-clang-format>

#tip[
  *不要手工对齐。* 改完代码执行一次 `make format`（#win 是 `make.bat format`），
  它会按上面这些设置重排。手工对齐反而会在评审时引入大量无意义的 diff。
  提交前执行一次格式化，已经是最基本的礼貌。
]

代码规范不止格式。几条在阅读源码时会注意到的约定：

- *命名*。库级函数用前缀区分归属：`BLI_` 是基础库，`BKE_` 是内核，
  `DEG_` 是依赖图，`ED_` 是编辑器，`WM_` 是窗口管理，`RE_` 是渲染。
  类型名用大驼峰（`SpaceType`、`ModifierTypeInfo`），
  全局变量常以 `G_` 开头（`G.debug`、`G_DEG_*` 这类宏）。
- *许可证头*。每个源文件开头是 SPDX 两行（`SPDX-FileCopyrightText` 与
  `SPDX-License-Identifier`）。`make license` 检查的就是它。
- *结构体注释*。DNA 结构体的字段注释不只是给人看的，`makesdna`
  会把它们带进 `.blend` 的元信息；这也是 `make check_struct_comments`
  存在的原因。
- *Python 侧*。风格检查是 `make check_pep8`，类型检查是 `make check_mypy`。
  注意 `pep8.py` 里对目录做了白名单/黑名单，`tools/`、`extern/`、`lib/`
  是被跳过的（#src("tests/python/pep8.py:25")）。

=== 17.2.2 提交信息

Blender 的提交信息有明确的固定形状，而且*平台会依赖它*。
最能说明问题的是 Gitea 的两份合并模板
（#src(".gitea/default_merge_message/REBASE_TEMPLATE.md")）：

```text
${CommitTitle}

${CommitBody}

Pull Request: https://projects.blender.org/blender/blender/pulls/${PullRequestIndex}
```

`squash` 模板（#src(".gitea/default_merge_message/SQUASH_TEMPLATE.md")）
是同一形状，只是标题取自 PR 标题：

```text
${PullRequestTitle}

Pull Request: https://projects.blender.org/blender/blender/pulls/${PullRequestIndex}
```

这两份文件本身就是规范：*标题一行，正文一段，最后一行是
`Pull Request:` 加链接。* 那个链接由平台在合并时自动填，
你不需要自己写；关键在于*不要把它写进正文中间，也不要在标题里塞说明*。

关于标题的措辞，本轮核对的环境里只检出到 #blender-version 那一个提交
（仓库是浅克隆，`git log` 只有一行），所以本书不给一份
"标题前缀全集"的列表 —— 那需要读足够多的历史才能总结，
凭印象编一份会误导你。可核实的做法只有一条：
*打开 `projects.blender.org` 上你所属模块的最近提交，照着它们的写法写。*

#warn[
  不要在你的提交信息里手动添加 `Pull Request:` 行。
  模板已经带了它，重复一遍会让最终记录里出现两行。
]

=== 17.2.3 代码评审：怎么让补丁被接受

评审要看的不是"代码写得漂不漂亮"，而是*这个改动能不能被安全地接受*。
按优先级，评审者关心四件事：

1. *这个改动解决什么问题，怎么复现。* PR 模板的第一个字段就是
   `Description`（#src(".gitea/pull_request_template.yaml")），
   而模板正文里明确写了版权与贡献者条款：
   "By submitting code here, you agree that the code is (compatible with)
   GNU GPL v2 or later"，以及"By default, all contributors are added to
   the AUTHORS file as part of a semi-automated process"。
2. *它有没有测试。* 修 bug 最好带一个能在修复前失败、修复后通过的用例。
   第 17.1 节讲的三级测试就是放它的地方。
3. *它的影响面有多大。* 改核心求值路径、改 DNA 布局、改 RNA 默认值，
   评审者会问"有没有兼容性影响"。DNA 的改动规范见
   #src("source/blender/blenkernel/BKE_blender_version.h:40") 注释里指向的
   那份兼容性处理文档。
4. *它是不是一件事。* 一个 PR 只做一件事。把"修 bug"和"顺手重命名"
   和"顺手格式化"混在一起，评审者无法判断哪一行是真正的修复。

#pitfall[
  最常见的被拒原因不是技术错误，而是*补丁太大且混装*。
  一个 3000 行的 diff 里同时有格式化、重命名、行为改动和三处无关修复，
  评审者只能逐行问"这一行为什么变"。正确做法是拆成 3 到 5 个 PR，
  每个都能独立说明与验证。
]

#tip[
  还有一条与"能不能验证"直接相关的实践：把复现步骤写成脚本
  （`blender -b -X --python-exit-code 1 --python repro.py`），
  而不是写成"打开文件，拖动这个物体，然后……"。
  前者评审者能直接执行，后者只能相信你。
]

=== 17.2.4 静态检查与评审的关系

评审者不会替你执行 `make format` 和 `make license`。这两件事属于
提交者的准备工作。一个实用的提交前清单：

```bash
$ make format          # 格式化（#win：make.bat format）
$ make license         # 许可证头
$ make check_mypy      # 只改了 Python 时
$ make test            # 至少执行与你改动相关的子集
```

#win 上把前两条换成 `make.bat format` 与 `make.bat license`
（许可证动作的脚本是 #src("build_files/windows/license.cmd")），
其余逻辑相同。

== 17.3 模块、维护者与流程

=== 17.3.1 模块不等于目录

理解 Blender 的组织方式，第一步是接受一件事：*模块划分与目录结构
不是一一对应的。* 这句话是源码里自己说的
（#src(".gitea/CODEOWNERS:1-9")）：

```text
# Definition of code owners for automatic assigment of reviewers.
#
# Blender is structured in modules, which do not always map directly to a
# specific directory or a set of files. This means that if reviewers were
# automatically assigned might not always be the ones to make the final
# decision.
```

同一段注释还给出了对贡献者的直接建议：
"Developers should consider adding themselves to files and directories they
are interested in review (or where they're often asked to do reviews)."
换句话说，*这份文件是活的*，等你熟悉了某个区域之后，可以把自己加进去。

`CODEOWNERS` 的用法是"路径模式 + 负责人"。它的结构按模块分成若干段，
`# ---...` 分隔线后面是模块名。可以核对到的段包括：
Depsgraph（#src(".gitea/CODEOWNERS:14")）、ID Management
（#src(".gitea/CODEOWNERS:17")）、Scene/Collections/Objects
（#src(".gitea/CODEOWNERS:35")）、Blendfile & Undo
（#src(".gitea/CODEOWNERS:45")）、DNA（#src(".gitea/CODEOWNERS:78")）、
RNA（#src(".gitea/CODEOWNERS:82")）、BPY（#src(".gitea/CODEOWNERS:89")）、
Render and Cycles（#src(".gitea/CODEOWNERS:110")）、
Geometry Nodes（#src(".gitea/CODEOWNERS:128")）、Blenlib
（#src(".gitea/CODEOWNERS:134")）、Editors（#src(".gitea/CODEOWNERS:216")）、
VSE（#src(".gitea/CODEOWNERS:222")）、Compositor
（#src(".gitea/CODEOWNERS:227")）。

举两个具体条目，感受一下粒度和写法：

```text
# .gitea/CODEOWNERS:15
source/blender/depsgraph/.*  @sergey
```

```text
# .gitea/CODEOWNERS:46-47
# No proper way with go regex to exclude some `versioning` files,
# so we need to include everything else explicitely (lack of negative lookahead...).
```

第二段注释本身很有信息量：它说明这套匹配用的是 *Go 的正则语法*，
不支持负向前瞻，所以有些规则写得很绕。你在读这些规则、
或者想给自己加一条时，知道这一点能省很多试错。

#tip[
  实用用法：*在动手改一个区域之前，先查 `CODEOWNERS`。*
  它直接告诉你这个区域由谁评审、以及这个模块是否被单独列为一段。
  一个不在 `CODEOWNERS` 里出现的目录，通常属于"没有专门负责人"的
  通用区域，评审会走更一般的路径。
]

=== 17.3.2 报 bug：报告的质量决定处理速度

Blender 把 bug 报告做成了结构化表单。模板在
#src(".gitea/issue_template/bug.yaml")，它的 `about` 一行就写明了
最省事的入口："Use Help > Report a Bug from the top of Blender to
automatically fill out part of this form" ——
也就是界面里的 *Help → Report a Bug*，它会自动带上系统信息与精确版本号。

模板正文里规定的必填内容是这几项（#src(".gitea/issue_template/bug.yaml")）：

```text
**System Information**
Operating system:
Graphics card:

**Blender Version**
Broken: (example: 3.0.0, main, `f1cca3055776`, 2020-12-30)
Worked: (newest version of Blender that worked as expected)

**Short description of error**

**Exact steps for others to reproduce the error**
Based on the default startup or on an attached .blend file (as simple as possible).
```

模板自己的收尾说明把优先级讲得很清楚（同一文件的末尾）：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-warn.lighten(94%),
  stroke: (left: 2.6pt + c-warn, rest: 0.4pt + c-warn.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  请附上崩溃日志、清晰的描述、精确的步骤，以及一个*尽可能简单的*
  复现用 `.blend` 文件。"You do your half of the work, then we do our half!"
]

#pitfall[
  对写代码的人来说，最重要的不是"怎么报 bug"，而是*怎么判断该不该报*。
  三个最常见的可避免情形，模板里都直接写了：
  （1）没先在每日构建上试 —— 可能已经修了；
  （2）没在更早的版本上试 —— 不知道"从哪个版本开始坏的"，
       也就没法给 `Broken` / `Worked` 两个字段；
  （3）一个报告里塞多个 bug —— 模板要求"如果有多个 bug，请开多个报告"。
]

除了 bug，模板目录里还有另外三类：
设计提案（#src(".gitea/issue_template/design.yaml")）、
待办（#src(".gitea/issue_template/todo.yaml")）、
API 文档问题（#src(".gitea/issue_template/api_docs.yaml")）。
先判断你的问题属于哪一类，再选模板 —— 选错模板只会让处理变慢。

=== 17.3.3 PR：从提交到被合并

Blender 的代码托管与评审在 `projects.blender.org` 上，用 Gitea。
仓库里与流程直接相关的、可核实的文件有这些：

#figure(
  kind: table,
  table(
    columns: (1.9fr, 2fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*文件*], [*作用*]),
    [`.gitea/pull_request_template.yaml`],
    [PR 表单与必读条款（GPL 兼容性、AUTHORS 文件、版权声明）],
    [`.gitea/CODEOWNERS`],
    [谁评审哪一块（见 17.3.1）],
    [`.gitea/default_merge_message/REBASE_TEMPLATE.md`],
    [rebase 合并时的最终提交信息形状],
    [`.gitea/default_merge_message/SQUASH_TEMPLATE.md`],
    [squash 合并时的最终提交信息形状],
    [`.gitea/workflows/cla.yml`],
    [PR 上的贡献者许可协议检查（在 `pull_request_target` 事件上触发，
     包含 `opened`、`ready_for_review`、`reopened`、`review_requested`、
     `synchronize` 五种动作）],
    [`.gitea/issue_template/`],
    [bug / design / todo / api_docs 四类问题模板],
  ),
  caption: [源码根目录 `.gitea/` 下与贡献流程直接相关的文件（全部核对存在）。],
) <tbl-gitea-files>

`cla.yml` 值得单独说一句：它说明 *PR 一旦被打开（或从草稿转为可评审），
就会自动执行一次许可协议检查*。这是很多新手第一次提 PR 时最困惑的一环 ——
"为什么有个机器人一直提醒我签协议"。它就是这里。

标准的 PR 生命周期大致是：

1. *先搜后提。* 在 `projects.blender.org` 上检索关键字，
   确认没有重复的 PR 或已修复的提交。
2. *本地做对。* 执行格式化和测试（17.2.4 那张清单）。
3. *开 PR。* 用模板填 `Description`，附复现脚本或测试用例。
   如果是"修 bug"，在描述里写清"修复前如何、修复后如何"。
4. *自动检查。* CLA 检查 + 构建/测试机器人的反馈先到位。
5. *评审。* 由 `CODEOWNERS` 指到的负责人（或他们指定的评审者）提意见。
   修改通常以追加提交的形式推上去；最终合并时会被 squash 或 rebase，
   并按 17.2.2 的模板生成最终提交信息。
6. *合并。* 完成后，`Pull Request:` 行由平台填入。

=== 17.3.4 一条实际可行的贡献路线

如果你从"想贡献"到"第一个 PR 被合并"需要一个顺序，建议按下面走。
它从最安全的地方开始，逐步进入风险更高的区域：

1. *从文档与测试开始。* 修错别字、补文档的缺失说明、
   为已有的行为补一个测试用例。这类改动*不改变行为*，
   评审成本低，同时你会被迫读懂那个模块到底在做什么。
   文档贡献的规范本身就在仓库里
   （#src("doc/python_api/rst/info_contributing.rst:172-177")：
   按官方贡献指南提 PR）。
2. *从 bug 修起。* 找一个标记为"需要复现文件"或"需要人确认"的
   issue，把它复现出来，写出最小复现脚本。*光是把一个 bug
   复现清楚就是很有价值的贡献。*
3. *小范围的功能改动。* 改一个已有操作符的行为、给一个修饰器
   加一项参数、补一个缺失的 RNA 属性。改动的范围最好在一个
   目录以内，这样评审者不需要跨模块协调。
4. *进入核心。* 依赖图求值路径、DNA 布局、渲染管线。
   到了这一步，你会需要 `CODEOWNERS` 里的负责人点头，
   而且改动通常需要一份设计说明（用 `design.yaml` 那份模板）。

#summary[
  本章的要点可以压成四句话：
  1. *三级测试各有前置条件*；C++ 单元测试要 `WITH_GTESTS=ON`
     （开发者档位已经打开），Python 集成测试要 `tests/files/` 的 LFS 数据。
  2. *执行测试前先确认 LFS 拉全了*：`git status --porcelain tests/files`
     不该有大片 `D`。这是最容易误判成代码 bug 的一类失败。
  3. *提交信息是固定形状*：一行标题、一段正文、最后一行是平台
     自动填的 `Pull Request:` 链接。别手动加它。
  4. *模块不等于目录*，`CODEOWNERS` 是唯一权威的"该找谁评审"来源。
]

#exercise[
  *练习 17.1* 在你自己的检出上执行 `git status --porcelain tests/files`。
  如果输出里有大片 `D`，先 `git lfs pull` 再重新配置一次构建目录。
  记录两次配置输出里关于测试的差异 ——
  特别是 `Tests: Disabling most tests` 这一行在修好之后是否消失。

  *练习 17.2* 找一个你不熟悉的模块（比如 `source/blender/blenloader/tests/`），
  用开发者档位构建后，只执行它的测试套件，把结果贴出来：
  ```bash
  $ ctest -R blenloader --output-on-failure
  ```
  （用例名以 `ctest -N` 的输出为准。）

  *练习 17.3* 在 `source/blender/blenlib/tests/` 下选一个已有测试，
  故意把断言里的期望值改错一位，重新执行测试，把失败输出读一遍。
  然后再用 `BLENDER_TEST_UPDATE=1` 之外的正常方式改回来。
  这一步的目的是让你熟悉"失败长什么样"，而不是只知道"通过"。

  *练习 17.4* 打开 `CODEOWNERS`，找出你最近改过（或最想改）的那几个文件
  属于哪一段，列出对应的负责人。如果你觉得这些文件应该在
  `CODEOWNERS` 里有一条更细的规则，按文件里的写法提一个 PR
  —— 这正是注释里鼓励的事情。

  *练习 17.5* 为你自己的一个改动写一份合格的提交信息：
  一行标题 + 一段正文。然后回答：如果这个改动要拆成两个 PR，
  你会怎么切？边界在哪一行？
]
