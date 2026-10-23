#import "../common.typ": *
#import "../figures/roadmap.typ": fig-roadmap

= 第 0 章 导论

在选择实现路径之前，先要回答两个问题：*Blender 的内部结构是什么样的*，以及
*目标功能是否有合适的扩展入口*。如果第二个问题没有答案，过早动手很容易造成返工：
插件已经成形，才发现关键能力并未向 Python 开放。

本章围绕这两个问题展开。读完后，你应该能够判断一个需求适合纯 Python 插件、
需要原生库加速，还是必须修改 C++ 源码；如果要改源码，也能初步判断应从哪一层定位。

== 0.1 覆盖范围、读者与学习路线

=== 0.1.1 两条扩展路径

Blender 的开发入口可以先概括为两条路径。它们能够完成的任务有所交集，
但可达范围与工程成本明显不同：

- *Python 插件（addon）*：在脚本编辑器里就能开始写，修改后无需重新编译 Blender，
  通常用一个压缩包即可分发。它与 Blender 的交互受公开 API 限制，计算部分则可以
  通过原生动态库扩展。
- *修改 C++ 源码*：可以进入 Python 未开放的内部机制，例如新增编辑器类型、
  调整求值策略或修改渲染管线。代价是要维护完整的编译环境，并在数百万行代码中
  准确定位改动点。

本书把两条路都走完，并且刻意把中间最容易被跳过的部分讲透：
为什么 Python 注册不了新的编辑器类型、`bpy` 里那些类和方法究竟从哪来、
依赖图为什么必须存在、一次"改个参数"背后经过了哪些环节。

=== 0.1.2 读者假设

本书假设你已经：

- 具备 C++ 基础：能阅读类、继承、模板与 `std::` 容器，了解 CMake 的基本用途；
- 能使用 Python 编写函数、类、装饰器与模块；
- 尚未系统阅读 Blender 源码，对 Blender 的日常操作也可能只掌握基础部分。

本书不假设你懂 Blender 的内部术语。每个内部概念第一次出现时都先给定义、
再说它为什么这么设计，最后才谈怎么用、怎么改。如果你只是想把 Blender 当作
一个建模工具来学，本书不是合适的选择 —— 它关心的是程序内部。

=== 0.1.3 学习路线

全书分为三篇，篇内递进，篇间可以按需跳读。

#figure(fig-roadmap(), caption: [全书学习路线图]) <fig-roadmap>

- *第 0 篇（第 0–2 章）* 打地基。第 1 章建立架构印象，第 2 章把编译环境搭起来。
  即使你只想写 Python 插件，也建议读完第 0 章 —— 它能帮你避开"动手之后才发现
  根本做不到"的弯路。只做 Python 插件时可以使用官方发布版 Blender；
  从第 8 章开始修改源码前，再完成第 2 章的构建流程。
- *第 1 篇（第 3–7 章）* 纯 Python 插件开发。从 `bpy` 的生成机制讲到界面、
  数据操作与性能，终点是一个可以打包分发的完整 addon。
- *第 2 篇（第 8–17 章）* 修改 C++ 源码。沿一条真实的调用链向下：
  数据层（DNA/RNA）→ 基础库 → 窗口与操作符 → 编辑器 → 依赖图 → 渲染管线，
  最后是调试、性能与上游贡献。

附录按"我要做某件事"来查：术语表、源码路径索引、构建与开发命令速查、
不同平台的构建差异对照、构建与开发排错，以及全书图表索引。

== 0.2 Blender 是什么样的程序

=== 0.2.1 规模：先建立一个数量级概念

第一次打开 `source/blender` 目录时，很容易因文件数量而无从下手。先看一组本书核对过的
规模数据（基准版本见前言）：

#figure(
  kind: table,
  table(
    columns: (auto, auto, auto),
    inset: 6pt,
    align: (left, right, right),
    stroke: 0.4pt + luma(78%),
    table.header([*目录*], [*文件数*], [*行数*]),
    [`source/`（Blender 自身，C/C++）], [6,365], [2,826,648],
    [`source/`（Python）], [—], [1,070],
    [`intern/`（内部库，C/C++）], [—], [354,206],
    [`extern/`（第三方，C/C++）], [—], [561,914],
    [`scripts/`（Python）], [808], [281,545],
  ),
  caption: [源码规模。`source/` 与 `intern/` 是 Blender 自己的代码，`extern/` 是随源码分发的第三方库。],
) <tbl-scale>

#note[
  行数的统计口径：按 *行* 计（含空行与注释）。方法是在源码根目录对 Git 追踪的
  `*.c` / `*.cc` / `*.cpp` / `*.h` / `*.hh` 执行 `git grep -c '^'` 并求和
  （`git grep` 会跳过二进制文件）。若改用「只数非空行」的口径，同一份源码得到的是
  约 242 万行 —— 两个数都不算错，差别只在口径。本书统一使用前一种。
]

这些数字说明两件事。第一，*没有必要通读全部代码*；本书关注的是如何判断目标代码
位于何处，以及如何快速验证定位结果。第二，Blender 的自有代码（`source/` + `intern/`）
约 318 万行 C/C++，另有约 28 万行 Python。规模虽然庞大，但模块边界与命名约定
为按功能定位提供了清晰线索，它并不是一个无法拆解的黑箱。

=== 0.2.2 模块化哲学：一切皆注册类型 + 回调

如果说有一条主线能帮你理解整个代码库，那就是这句话：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-part.lighten(95%),
  stroke: (left: 2.6pt + c-part, rest: 0.4pt + c-part.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  Blender 里几乎每一种可扩展的东西 —— 操作符、修饰器、节点、编辑器、面板、
  渲染引擎 —— 都遵循同一个模式：*定义一个描述结构体，填上一组回调函数指针，
  在启动时把它注册进一张全局表。* 运行时框架只认这张表，不认具体实现。
]

这个模式的具体表现，可以在源码里直接看到：

- *操作符*。`WM_operatortype_append()` 在 #src("source/blender/windowmanager/WM_api.hh:1414")
  声明，在 #src("source/blender/windowmanager/intern/wm_operator_type.cc:151") 实现。
  而所有内置操作符的注册清单，就是 #src("source/blender/windowmanager/intern/wm_operators.cc")
  里从第 4235 行开始的那一长串 `WM_operatortype_append(WM_OT_xxx)` 调用。
  全代码库中有 365 个文件出现了 `wmOperatorType`。
- *修饰器*。每个修饰器提供一个 `ModifierTypeInfo`，其中包含 `deform_verts`（#src("source/blender/blenkernel/BKE_modifier.hh:236")）、`deform_matrices`（:244）、`modify_mesh`（:280）、`modify_geometry_set`（:287）等回调。136 个文件出现了 `ModifierTypeInfo`。
- *编辑器*。`BKE_spacetype_register()` 在 #src("source/blender/blenkernel/BKE_screen.hh:763")
  声明，代码库中有 19 处调用，每个编辑器一处。
- *界面数据层*。`makesrna` 中共有 50,278 次 `RNA_def_` 调用，分布在 105 个 `.cc` 文件里；底层的 `makesdna` 有 97 个 `DNA_*.h` 结构定义文件。

#tip[
  这个模式对你是好消息。它意味着扩展点的位置是*可预测*的：
  想知道"怎么加一个修饰器"，就去读别的修饰器怎么注册；
  想知道"一个操作符能提供哪些回调"，就去看 `wmOperatorType` 结构体的定义。
  你几乎不需要理解整个程序，只需要理解"这一类东西"的约定。
]

=== 0.2.3 注册式架构也提示了扩展边界

采用注册表并不意味着每张表都向 Python 开放。操作符、面板等类型有对应的 Python
注册桥梁，可以在运行时加入；另一些内部类型只有 C++ 注册入口。RNA 能让 Python
看到一个已有类型，也不等于 Python 能创建同类的新类型。判断扩展边界时，关键不是
"能否在 `bpy.types` 中看到它"，而是"是否存在面向 Python 的注册入口"。

== 0.3 开发边界：先想清楚能做与不能做

这是本章最重要的一节。很多人卡住不是因为不会写代码，而是因为选错了路径。
在动手之前，请先回答三个问题：

1. 我要做的事，Blender 有没有为它预留扩展点？
2. 那个扩展点是在 Python 层暴露的，还是只在 C++ 层？
3. 如果只在 C++ 层，我是否愿意接受"必须编译、必须跟随上游变化"的成本？

=== 0.3.1 边界对照表

#figure(
  kind: table,
  table(
    columns: (2.1fr, 1fr, 1fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*想做的事*], [*纯 Python 插件*], [*改 C++ 源码*]),
    [新增操作符、面板、菜单、快捷键], [可以], [可以],
    [自定义属性、`PropertyGroup`、`UIList`], [可以], [可以],
    [批量读写网格数据（`foreach_*` / `numpy`）], [可以], [—],
    [自定义渲染引擎（`RenderEngine`）], [可以], [可以],
    [调用自己的原生动态库（C ABI）], [可以，见下], [可以],
    [新增编辑器类型（新 `SpaceType`）], [*不行*], [可以],
    [改界面绘制、draw manager、GPU 后端], [不行], [可以],
    [改依赖图求值策略、修饰器求值、节点求值], [不行], [可以],
    [给已有数据类型加可保存进 `.blend` 的字段], [不行], [可以],
    [替换或加速核心算法], [不行], [可以],
  ),
  caption: [开发边界对照表。"不行"指没有官方扩展入口，不是指技术上绝对做不到。],
) <tbl-boundary>

关于这张表，有几点需要展开。

=== 0.3.2 为什么"新增编辑器类型"必须改 C++

这是最常被问到的边界。答案就在源码里：编辑器类型 `SpaceType` 是一个 C++ 结构体，
它的注册入口是 `BKE_spacetype_register(std::unique_ptr<SpaceType>)`
（#src("source/blender/blenkernel/BKE_screen.hh:763")），而现有编辑器全部由
C++ 侧注册，共 19 处，每处都在对应的编辑器实现文件里：

```cpp
// source/blender/editors/space_view3d/space_view3d.cc:1727（节选）
BKE_spacetype_register(std::move(st));
```

Python 侧看到的是*结果*而不是*入口*。`bpy.types` 里确实存在这些类型 ——
例如 `SpaceView3D` 在 #src("source/blender/makesrna/intern/rna_space.cc:5650")
被定义为 `RNA_def_struct(brna, "SpaceView3D", "Space")`，`rna_space.cc` 里共有
23 个 `Space*` 结构定义 —— 但 `bpy` 没有提供"注册一个新的 `SpaceType`"这条路径。
你能*操作*已有的编辑器，不能*创造*新的编辑器。

#pitfall[
  "`bpy.types` 里能看到 `SpaceView3D`，所以也许我能继承它注册一个新编辑器？"
  —— 不能。这个类型只是已有 C++ 结构在 RNA 层的映射，它没有对应的注册元数据。
  凡是"以 `bpy.types` 里存在某个类"来推断"可以注册这类东西"的思路，
  都要先用本节的方法验证一次。
]

=== 0.3.3 Python 能走多远：调用你自己的原生库

有一个常见误解是"Python 插件性能差，所以想加速就必须改 C++ 源码"。这不成立。
Python 插件可以加载*任意*原生动态库（Windows 的 `.dll`、Linux 的 `.so`、
macOS 的 `.dylib`），只要那个库导出的是 C ABI。做法是 `ctypes`（标准库，
无需安装）、`cffi`，或用 PyO3 把 Rust 代码包装成 Python 扩展模块。

这不是理论可能 —— Blender 官方自带的 addon 就在这么做：

```python
# scripts/addons_core/io_scene_gltf2/io/imp/gltf2_io_binary_meshopt.py:33（节选）
import ctypes
...
lib = ctypes.CDLL(lib_path.resolve())
```

同类用法还出现在同目录的 `.../io/exp/meshopt.py:43`（`ctypes.CDLL`）、`.../io/exp/draco.py:18`（`cdll.LoadLibrary`），
以及 #src("scripts/modules/_bl_i18n_utils/utils_rtl.py:182") 中的
`ctypes.CDLL(settings.FRIBIDI_LIB)`。

这意味着你可以用 Rust、C 或 C++ 写一个纯计算热点（网格处理、数值求解、
格式编解码），编译成 C ABI 动态库，随插件一起分发。第 6 章会给出完整做法。

#warn[
  原生加速把"分发一个纯 Python 包"变成了"要为每个平台编译并分发二进制"。
  只有当 `numpy` 向量化和 `foreach_get` / `foreach_set`（见第 6 章）都确实不够快时，
  再走这条路。先测量，再优化。
]

=== 0.3.4 三条路线与取舍

综合上面的边界，本书把常见开发路线归纳为三类：

#figure(
  kind: table,
  table(
    columns: (1.1fr, 1.5fr, 1.2fr, 1.1fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*路线*], [*能做什么*], [*成本*], [*何时选*]),
    [纯 Python 插件],
    [操作符、面板、属性、数据读写、自定义渲染引擎、`ctypes` 调原生库],
    [零编译、分发简单],
    [绝大多数需求],
    [Python 插件 + 原生加速库],
    [以上全部，外加自己实现的计算热点],
    [要为每个平台编译并分发二进制],
    [纯 Python 确实慢，且已测量确认],
    [修改 C++ 源码],
    [以上全部，外加新编辑器、新求值策略、改渲染管线、给数据类型加字段],
    [必须能编译，改动需跟随上游演进],
    [功能本身没有 Python 入口],
  ),
  caption: [三条开发路线及其取舍],
) <tbl-routes>

#summary[
  判断顺序应该是：*先查有没有 Python 入口* → 有就写纯 Python 插件；
  *性能不够就先测量* → 确实不够再考虑原生加速库；
  *功能没有 Python 入口* → 才轮到改 C++ 源码。
  一开始就修改源码，往往会过早引入编译、分发与上游同步成本。
]

== 0.4 本书约定

=== 0.4.1 术语

术语第一次出现时加粗并附英文，例如 *操作符*（operator）。
以尾下划线结尾的标识符（如 `ED_`、`BKE_`、`DEG_`、`GPU_`）一律用等宽字体标出，
以免与正文词混淆 —— 那个下划线是 Blender 的命名约定，不是笔误。完整的术语表见附录 A。

=== 0.4.2 代码与命令

代码块标注语言。命令示例中 `$` 表示普通用户权限，`#` 表示需要提权：

```bash
$ cmake -B ../build_windows -G Ninja
```

源码引用一律给出「文件路径 + 行号」，写成 `source/blender/blenkernel/BKE_screen.hh:763` 这样。
需要说明的是，行号对应的是前言中给出的核对基准版本；你的版本如果不同，
行号会有偏移，请以同名的符号为准检索。

#warn[
  凡是只摘录了片段而非完整函数、或为说明而简化的代码，都会明确标注「节选」或「示意」。
  只有明确标注「完整可运行」「完整可编译」，并由脚注指向随书 `examples/` 目录的代码，
  才承诺可以作为独立文件使用。其余代码块即使没有写「节选」，也可能只是交互式命令、
  输出记录，或依赖当前小节上下文的局部写法，不能据此视为完整程序。
]

=== 0.4.3 平台标记

不同平台之间的差异用 `Windows`、`macOS`、`Linux` 三个小标签标出。第 2 章给出每个平台
从零到构建成功的完整步骤，附录 D 是三者的一页速查对照。

=== 0.4.4 交叉引用与延伸阅读

前后章节的依赖用"详见第 X 章"或"§X.Y"给出指引。凡给出网址，都同时提供
可点击超链接与明文网址，方便纸质阅读时手动输入。

=== 0.4.5 关于实践练习

各实践章节或小节都配有「实践练习」，并且不需要额外的商业软件。
第 3–7 章的练习可以使用官方发布版 Blender；第 8–17 章涉及源码阅读与修改，
需要先完成第 2 章的源码获取与构建流程。
