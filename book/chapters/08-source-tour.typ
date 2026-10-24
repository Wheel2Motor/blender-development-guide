#import "../common.typ": *
#import "../figures/source-tree.typ": fig-source-tree

= 第 8 章　源码结构深度导览

前七章里，你始终站在 Python 这一侧：`bpy` 给你什么，你就用什么。
从本章开始，你要走到另一侧去 —— *在数百万行 C/C++ 里找到该动的那一行*。

这件事的主要难点不在逐行理解代码，而在准确定位。Blender 的源码规模是
`source/` 与 `intern/` 合计约 318 万行 C/C++（第 0 章核对过），
通读全部代码既不现实，也没有必要。本章采用两种互补的方法：

1. *知道东西大概在哪* —— 靠的是模块划分和命名约定。这是 §8.1 的内容。
2. *从已知信息倒推出确切位置* —— 靠的是几条可重复执行的反查路径。这是 §8.3 的内容。

中间夹着的 §8.2 讲头文件扩展名、命名空间和代码风格，看起来琐碎，
但它是你每天都要打交道的层面：一次格式不符合 `.clang-format` 的提交，
在上游会被直接退回。

#summary[
  读完本章，你应该能够根据界面功能名、`bpy` 属性名或一段崩溃调用栈，
  判断相关实现大概率位于哪个目录、哪个文件，
  以及下一步该 grep 什么。这是一项可以练出来的手艺。
]

== 8.1 模块划分与命名前缀约定

=== 8.1.1 先建立"哪五个目录"的概念

第一次 `ls` 仓库根目录会被吓到：`.gitea`、`assets`、`build_files`、`doc`、
`extern`、`intern`、`lib`、`locale`、`release`、`scripts`、`source`、
`tests`、`tools`……十三个顶层目录，其中大部分和你无关。真正需要记住的是五个：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr, auto),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*目录*], [*里面是什么*], [*多久会碰一次*]),
    [`source/blender/`], [Blender 主体：33 个子模块，你几乎所有的改动都落在这里], [每天],
    [`source/creator/`], [`main()`、命令行参数、启动流程], [改启动行为时],
    [`intern/`], [Blender 自有的独立库：`ghost`、`guardedalloc`、`clog`、`cycles` …], [偶尔],
    [`extern/`], [随源码分发的第三方库：`audaspace`、`bullet2`、`tinygltf` …], [几乎不改],
    [`scripts/`], [随发行版的 Python：`startup/`、`addons_core/`、`modules/`], [写插件时常看],
  ),
  caption: [五个值得记住的顶层目录（其余目录的作用见 §8.1.4 的目录树）],
) <tbl-top-dirs>

有两个常见的误判值得提前说清楚。

第一，`intern/` *是 Blender 项目自己的代码*，不是第三方库。`intern/ghost/`
是跨平台窗口系统抽象层，`intern/guardedalloc/` 是带越界检测的内存分配器，
`intern/cycles/` 是 Cycles 渲染器（它独立于 `source/` 目录树开发）。
它们从源码仓库里单独构建，但在版本控制和许可证上都属于 Blender。

第二，`extern/` 里是*随源码一起分发*的第三方库源码。你几乎不需要改它们 ——
改了也很难被上游接受，因为上游的原则是"尽量少改动 vendored 代码"。
真正想改的第三方行为，通常是在 `source/` 里写你自己的适配层。

=== 8.1.2 前缀即模块：C 时代的命名空间替代方案

Blender 诞生于 1990 年代，主体是 C 代码，而 C 没有命名空间#footnote[
  这种“用统一前缀模拟命名空间”的办法有时被俗称为 poor man's namespace。
  这个说法描述的是技术约束下的折中，不是 Blender 的正式术语。
]。
于是它采用了一个到今天仍然主导代码库的做法：
*给每一个公开函数加上模块前缀*。

这个规则的好处是立竿见影的：看到 `BKE_object_free()`，你立刻知道实现
在 `blenkernel` 模块；看到 `ED_operator_object_active_editable()`，
你知道它在 `editors`。*前缀就是一张可以直接换算成目录的索引表*。

#figure(
  kind: table,
  table(
    columns: (auto, auto, auto, 1fr),
    inset: 5.5pt,
    align: (left, left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header(
      [*前缀*],
      [*模块目录（`source/blender/`）*],
      [*函数名*],
      [*这个模块负责什么*],
    ),
    [`BLI_`], [`blenlib/`], [1,186], [基础库：字符串、容器、数学、文件、线程],
    [`BKE_`], [`blenkernel/`], [3,538], [核心数据类型与算法，源码里最大的一块],
    [`ED_`], [`editors/`], [1,337], [各编辑器的实现、绘制与交互],
    [`WM_`], [`windowmanager/`], [902], [窗口、事件分发、操作符框架],
    [`GPU_`], [`gpu/`], [769], [图形 API 抽象：着色器、纹理、帧缓冲],
    [`RNA_`], [`makesrna/`], [745], [RNA 定义 API 与运行时访问],
    [`IMB_`], [`imbuf/`], [257], [图像缓冲与格式读写],
    [`RE_`], [`render/`], [160], [渲染管线与引擎接口],
    [`DEG_`], [`depsgraph/`], [131], [依赖图的构建、标记与求值],
    [`BLO_`], [`blenloader/`], [86], [读写 `.blend` 文件、版本迁移],
    [`DNA_`], [`makesdna/`], [55], [DNA 结构体的解析与 SDNA 生成],
    [`BPY_`], [`python/`], [106], [`bpy` 的 C 侧绑定],
    [`ANIM_`], [`animrig/`], [52], [动画框架（新版 Action/Slot 系统）],
    [`BM_`], [`bmesh/`], [603], [BMesh 网格编辑 API],
    [`DRW_`], [`draw/`], [279], [绘制管理器：视口与渲染的 GPU 通道],
    [`BLF_`], [`blenfont/`], [91], [界面字体渲染],
    [`SEQ_`], [`sequencer/`], [5], [视频序列编辑器（已大部分迁入命名空间）],
    [`NOD_`], [`nodes/`], [5], [节点系统（已基本迁入命名空间）],
    [`GEO_`], [`geometry/`], [1], [几何算法（已迁入命名空间，见下）],
  ),
  caption: [
    *模块前缀对照表。*"函数名"列统计的是各模块目录（含全部子目录）内出现的、
    形如"前缀 + 下划线 + 名字"且后面紧跟 `(` 的*去重*标识符个数。复现命令（以 `BLI_` 为例）：
    `git grep -o -E 'BLI_[A-Za-z0-9_]+[(]' -- source/blender/blenlib | sort -u | wc -l`。
    它衡量该模块对外暴露的接口体量，不是精确的函数个数。
  ],
) <tbl-prefix-map>

这张表怎么用？举个例子。你想找"把对象从集合里移出去"的代码：

```bash
# 从任意一个你知道的函数名出发，grep 前缀，看它的头文件在哪
$ git grep -l "BKE_collection_object_remove" -- 'source/**/*.hh'
source/blender/blenkernel/BKE_collection.hh
```

拿到头文件路径，就拿到了实现目录（`blenkernel/intern/collection.cc`）
和这一模块的全部同类函数。你不需要先理解整个 `blenkernel`。

#tip[
  记忆负担可以进一步压缩：只要记住 *`BLI_` 是基础、`BKE_` 是数据与算法、
  `ED_` 是界面、`WM_` 是事件与操作符*，就已经能覆盖日常 80% 的定位需求。
  剩下的前缀在用到时查表 8.2 即可。
]

=== 8.1.3 前缀的三条退化规则

如果"前缀 = 模块"永远成立，这一节就不必写了。可惜 5.x 的代码库里
至少有三种偏离，不知道它们会让你的 grep 白费力气。

*规则一：新模块把前缀留在文件名里，函数改用命名空间。*

`geometry/` 模块是最好的例子。它的头文件仍然叫
#src("source/blender/geometry/GEO_add_curves_on_mesh.hh")，
但里面的函数*没有* `GEO_` 前缀：

```cpp
// source/blender/geometry/GEO_add_curves_on_mesh.hh:14-62（节选）
namespace blender {
namespace geometry {

struct AddCurvesOnMeshInputs { /* ... */ };

AddCurvesOnMeshOutputs add_curves_on_mesh(bke::CurvesGeometry &curves,
                                          const AddCurvesOnMeshInputs &inputs);
}  // namespace geometry
}  // namespace blender
```

调用点写的是 `geometry::add_curves_on_mesh(...)`
（见 #src("source/blender/editors/sculpt_paint/curves/sculpt_add.cc:231")），
前缀 `GEO_` 只出现在 `#include` 的那一行。

这不是孤例。用 `git grep` 数一下各模块目录里 `namespace` 声明的出现次数，
可以看到迁移的梯度：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 5.5pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*命名空间*], [*声明次数*], [*状态*]),
    [`blender::nodes`], [997], [新代码一律用命名空间，`NOD_` 只剩文件名],
    [`blender::ed`], [869], [`editors/` 的 C++ 新代码；对外 C API 仍是 `ED_`],
    [`blender::gpu`], [609], [`gpu/` 的 C++ 层；`GPU_` 是它的 C 兼容层],
    [`blender::bke`], [577], [`blenkernel/` 的 C++ 化部分（`BKE_` 仍是主力）],
    [`blender::compositor`], [341], [合成器，基本完整迁移],
    [`blender::draw`], [280], [绘制管理器，基本完整迁移],
    [`blender::geometry`], [135], [几何算法，基本完整迁移],
    [`blender::seq`], [109], [序列编辑器，迁移中],
    [`blender::animrig`], [108], [动画框架，新模块，原生 C++],
    [`blender::dna`], [10], [DNA 运行时（`sdna_struct_id_get` 等）],
    [`blender::bmesh`], [0], [仍是 `BM_` 前缀的 C 风格 API],
    [`blender::wm`], [0], [写作 `namespace blender { namespace wm {`，共 2 处],
  ),
  caption: [命名空间的普及程度。数字是 `source/` 下 `namespace <名>` 的出现次数。],
) <tbl-namespaces>

#pitfall[
  因此"`GEO_` 前缀 ⇒ 函数名以 `GEO_` 开头"在 5.x 已经不成立。
  正确的说法是：*前缀保证你能找到文件和目录，不保证函数名长什么样*。
  定位时先按文件名找，再看文件里的实际符号。
]

*规则二：小写前缀表示"模块内部"。*

`blenloader` 模块对外是 `BLO_`：`BLO_read_from_file()`、
`BLO_write_file()`、`BLO_blendhandle_from_file()` —— 这些在
#src("source/blender/blenloader/BLO_readfile.hh") 与
#src("source/blender/blenloader/BLO_writefile.hh") 里声明。
但模块*内部*的实现函数用小写 `blo_`：

```bash
$ git grep -h -o -E '\bblo_[a-z0-9_]+\(' -- source/blender/blenloader | sort -u | head -6
blo_add_main_for_library(
blo_bhead_first(
blo_bhead_id_name(
blo_bhead_is_id(
blo_do_versions_dna(
blo_read_file_internal(
```

`blo_do_versions_dna()` 就是 §9.2 要讲的 DNA 版本迁移入口。

这种"大写 = 对外、小写 = 对内"的约定在 Blender 里相当一致：
`blo_`（blenloader）、`dna_`（makesdna 内部，如
#src("source/blender/makesdna/intern/dna_parse.cc")）、`rna_`（makesrna 内部）。

*规则三：调用方可能同时看到两套名字。*

在同一份代码里，你会看到 `BKE_object_free()`（C 风格）和
`bke::action_blend_read_data()`（C++ 风格）并存。这不是历史遗留的混乱，
而是*有意的分层*：

- 以 `BKE_` 开头的函数是*稳定的、给其他模块用的接口*，
  它们的声明集中在 `blenkernel/BKE_*.hh`。
- `namespace blender::bke` 里的函数是*实现细节*，
  头文件可能不在 `BKE_*.hh` 而在某个具体模块的头里。
  例如 #src("source/blender/blenkernel/BKE_screen.hh:740") 的注释里
  就明确写着"Don't use directly, use `ed::asset::shelf::type_asset_poll()`"。

#tip[
  查找时的经验规则：*先按 `BKE_`/`ED_` 这种全大写前缀找公开接口，
  找不到再按 `bke::`/`ed::` 找 C++ 实现*。反过来的顺序会让你在
  `blenkernel/intern/` 里绕很久。
]

=== 8.1.4 一张目录树

#figure(fig-source-tree(), caption: [源码目录结构与模块命名前缀对照]) <fig-source-tree>

=== 8.1.5 怎么用：从"我要改什么"到"去哪个目录"

把上面的规则整理成一张反查表，贴在显示器边上比背下来更实用：

#figure(
  kind: table,
  table(
    columns: (1.25fr, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*我想改的东西*], [*第一站*]),
    [字符串、容器、数学、文件、线程这类工具函数], [`blenlib/`（`BLI_`）],
    [某个数据类型的行为（对象、网格、材质…）], [`blenkernel/`（`BKE_`）],
    [界面上的按钮、面板、菜单、快捷键行为], [`editors/` + `windowmanager/`（`ED_` / `WM_`）],
    [视口绘制、着色器、GPU 后端], [`draw/` + `gpu/`（`DRW_` / `GPU_`）],
    [数据求值顺序、缓存失效、修饰器何时执行], [`depsgraph/`（`DEG_`）],
    [图像读写、色彩管理], [`imbuf/`（`IMB_`）+ `blenkernel` 里的色彩代码],
    [渲染管线、渲染引擎注册], [`render/`（`RE_`）+ `editors/render/`],
    [`.blend` 的读写格式、旧文件兼容], [`blenloader/`（`BLO_`）+ `makesdna/`],
    [`bpy` 里的属性、类型、函数], [`makesrna/intern/`（`RNA_`）+ `python/intern/`],
    [某个 `.blend` 字段的含义], [`makesdna/DNA_*.h`],
    [命令行长这样、启动时做了什么], [`source/creator/`],
  ),
  caption: [反查表：从需求到目录。括号里是那一站的主要前缀。],
) <tbl-reverse-dir>

=== 8.1.6 常见问题

#pitfall[
  *易错点 1：把 `intern/` 当成第三方。*  `intern/guardedalloc` 是 Blender 自己的
  内存分配器，`intern/clog` 是自己的日志系统。改它们是完全正当的，
  而且 `guardedalloc` 常常是你排查内存问题的关键工具。
]

#pitfall[
  *易错点 2：在 `editors/` 里找 `BKE_` 函数的定义。*  `ED_*` 文件里出现 `BKE_xxx()`
  调用是常态，但定义一定在 `blenkernel/intern/` 下。判断方法是看
  `#include` 的头文件路径：`#include "BKE_xxx.hh"` 说明定义在别处。
]

#pitfall[
  *易错点 3：忽略 `source/creator/`。*  很多"Blender 启动时为什么这样"的问题
  —— 默认工作区怎么来的、`--factory-startup` 做了什么、环境变量在哪读 ——
  答案都在 `source/creator/creator_args.cc`，而它的位置不在 `source/blender/` 里。
]

== 8.2 头文件 `.h` vs `.hh`、命名空间、代码风格与 `.clang-format`

=== 8.2.1 两种扩展名，一条硬规则

Blender 的 C++ 头文件用 `.hh`，C 兼容的头文件用 `.h`。
规则本身不复杂，但*代价很大*：搞错了会在链接或编译期报出难以理解的错误。

#figure(
  kind: table,
  table(
    columns: (auto, auto, auto, 1fr),
    inset: 6pt,
    align: (left, right, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*位置*], [*`.h`*], [*`.hh`*], [*说明*]),
    [`source/`], [642], [2,050], [主体代码，`.hh` 是压倒性多数],
    [`intern/`], [702], [108], [大量继承自早期的 C 实现],
    [`extern/`], [689], [0], [第三方库，都是 C 风格，别动],
  ),
  caption: [`git ls-files` 统计的头文件数量（基准 commit `d13f752e`）],
) <tbl-header-ext>

分模块看会更清楚这种"混合"是怎么分布的：

#figure(
  kind: table,
  table(
    columns: (1fr, auto, auto, 1fr),
    inset: 5.5pt,
    align: (left, right, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*模块*], [*`X_*.h`*], [*`X_*.hh`*], [*解读*]),
    [`blenlib/`（`BLI_`）], [92], [157], [数学与容器已 C++ 化，字符串等仍是 C 接口],
    [`blenkernel/`（`BKE_`）], [47], [186], [绝大部分已迁到 `.hh`],
    [`editors/include/`（`ED_`）], [1], [63], [几乎全是 `.hh`],
  ),
  caption: [主要模块的头文件扩展名分布],
) <tbl-header-ext-module>

实践上有一条*可以放心依赖的规律*：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-part.lighten(95%),
  stroke: (left: 2.6pt + c-part, rest: 0.4pt + c-part.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  *`DNA_*.h` 全部是 `.h`*（#src("source/blender/makesdna/") 下 97 个
  `DNA_*.h` 加 4 个工具用 `.hh`），因为它们要被 `makesdna` 当作纯文本解析，
  而且必须同时能被 C 和 C++ 编译。*`rna_*.cc` 全部是 `.cc`*，因为它们是 C++。
]

`DNA_*.h` 里的写法因此很克制：可以用 `ListBaseT<T>` 这样的模板、
可以用 `= nullptr` / `= {}` 默认成员初始化、可以用
`static constexpr ID_Type id_type`（例如
#src("source/blender/makesdna/DNA_screen_types.h:98")），
但*不能引入需要构造与析构的成员*。原因见 §9.1.2 —— 这些结构体的内存
会被逐字节写进 `.blend` 文件，也会被整体 `memcpy`。
#src("source/blender/makesdna/DNA_defs.h:104-134") 的
`DNA_DEFINE_CXX_METHODS` 宏正是为此服务的：它显式删掉拷贝/移动构造，
只保留"浅拷贝"（`dna::shallow_copy`）和"清零构造"两种受控形式。

#warn[
  `.hh` 里可以写 C++，但*不要*给 `DNA_*.h` 里已有的结构体加需要构造/析构的成员。
  `makesdna` 会检查结构体的大小与每个成员的偏移
  （生成的 `dna_verify.cc` 里全是 `BLI_STATIC_ASSERT(offsetof(...) == N)`，
  见 #src("source/blender/makesdna/intern/makesdna.cc:760-799")），
  加错一个 `std::string` 就会在编译期直接炸掉整个构建。
]

=== 8.2.2 命名空间：只有一层，名字就叫 `blender`

Blender 的 C++ 代码只有一个顶层命名空间：`blender`。
你几乎不会看到别的顶层命名空间（例外是 `extern/` 里的第三方库）。

```cpp
// source/blender/geometry/GEO_add_curves_on_mesh.hh:14-69（节选）
namespace blender {

struct Mesh;
template<typename CoordT> struct KDTree;

namespace geometry {

AddCurvesOnMeshOutputs add_curves_on_mesh(bke::CurvesGeometry &curves,
                                          const AddCurvesOnMeshInputs &inputs);

}  // namespace geometry
}  // namespace blender
```

有三种写法在库里同时存在，都算合规：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*写法*], [*出现在哪 / 含义*]),
    [`namespace blender::bke { … }`],
    [C++17 起的嵌套写法，新代码的主流；`blenkernel/` 里 437 处],
    [`namespace blender { namespace bke { … } }`],
    [老写法，与上者等价；`windowmanager/` 的 `wm` 仍这么写（2 处）],
    [`using namespace blender;`],
    [只允许出现在 `.cc` 的顶部（生成代码里常见），*绝不允许出现在 `.hh` 里*],
  ),
  caption: [命名空间的三种写法],
) <tbl-namespace-styles>

注意每个 `}` 后面那行 `// namespace xxx` 注释 —— 这不是可选项。
`.clang-format` 里开着 `FixNamespaceComments: true`
（#src(".clang-format:88")），格式化时会自动补，但你自己写的时候
漏了它，`make format` 会把它加回去，于是你的 diff 里多出一行噪音。

#pitfall[
  在 `.hh` 里写 `using namespace blender;` 会污染所有包含它的翻译单元。
  这个错误在 Blender 里极少见，但一旦引入，症状是*别处*出现
  莫名其妙的符号冲突 —— 排查成本极高。养成习惯：头文件里永远写全限定名
  （`bke::CurvesGeometry`），或者把 `using` 放进函数体内。
]

=== 8.2.3 `.clang-format`：不是风格建议，是构建规则

仓库根目录的 #src(".clang-format") 有 276 行，逐条读完没有必要，
但下面这些条目必须知道，因为它们会*改变你写代码的手感*：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 5.5pt,
    align: (left, auto, left),
    stroke: 0.4pt + luma(78%),
    table.header([*选项*], [*值*], [*对你的影响*]),
    [`ColumnLimit`], [`99`], [第 100 个字符就超限；`.editorconfig` 里也写了 99],
    [`IndentWidth` / `TabWidth`], [`2` / `2`], [缩进两个空格，不用 Tab],
    [`UseTab`], [`Never`], [任何地方都不许出现 Tab],
    [`BinPackParameters`], [`false`], [参数放不下就*一个一行*，不要挤成两行],
    [`BinPackArguments`], [`false`], [同上，针对函数调用],
    [`AlignAfterOpenBracket`], [`Align`], [续行参数与左括号后第一个参数对齐],
    [`BreakBeforeBraces`], [`Custom`], [大括号位置见 `.clang-format:62` 起的定义],
    [`SortIncludes`], [`true`], [`#include` 会被自动排序，别手动维护顺序],
    [`FixNamespaceComments`], [`true`], [自动补 `// namespace xxx`],
    [`SpacesBeforeTrailingComments`], [`2`], [行尾注释前两个空格],
    [`AccessModifierOffset`], [`-1`], [`public:` 比 `class` 少缩进一格],
    [`ConstructorInitializerIndentWidth`], [`4`],
    [初始化列表缩进 4 格，且 `:` 另起一行],
    [`PenaltyReturnTypeOnItsOwnLine`], [`10000`], [强烈避免返回类型单独成行],
    [`AllowShortBlocksOnASingleLine`], [`false`], [`if (x) { y; }` 要拆开写],
  ),
  caption: [`.clang-format` 里最常影响日常书写的选项],
) <tbl-clang-format>

`bin-packing` 那两条值得多看一眼，因为它们最反直觉：

```cpp
// BinPackParameters: false 的效果 —— 放不下就每行一个
void long_function_name(int parameter_one,
                        int parameter_two,
                        int parameter_three);

// 而不是这样（放不下时挤成两行）：
// void long_function_name(int parameter_one, int parameter_two,
//                         int parameter_three);
```

`AlignAfterOpenBracket: Align` 则解释了为什么 Blender 的续行是
"对齐到左括号后"而不是"缩进两格"。

还有一个和格式无关但同样会卡住你的文件：
#src("source/creator/") 之外的语言用的是 `.editorconfig`
（#src(".editorconfig")）。它规定 C/C++/GLSL 文件 `max_line_length = 99`、
`indent_size = 2`，Python 则是 `indent_size = 4`、`max_line_length = 120`。
换句话说，*同一个仓库里 C++ 和 Python 的行宽上限是不同的*。

=== 8.2.4 怎样执行格式化

Blender 提供的入口是 `make format`：

```bash
# 格式化整个仓库（需要 clang-format 与 autopep8）
$ make format

# 只格式化你改过的目录，速度快得多，也更不容易产生无关 diff
$ make format PATHS="source/blender/blenkernel source/blender/blenlib"
```

它的实现是调用两个 Python 脚本（#src("GNUmakefile:623-625")）：
`tools/utils_maintenance/clang_format_paths.py` 与
`tools/utils_maintenance/autopep8_format_paths.py`。
`PATHS` 参数会原样传给这两个脚本。

#note[
  #win #h(0.4em) 下没有可用的 GNU `make`（`GNUmakefile` 开头就写着
  "This makefile is not meant for Windows"，#src("GNUmakefile:175")）。
  请直接调用脚本，或使用随源码构建出来的 `clang-format` 二进制：
  `python tools/utils_maintenance/clang_format_paths.py source/blender/blenkernel`。
]

#note[
  `.clang-format` 里写着"Tested to work with versions: 8 to 11"
  （#src(".clang-format:5")）。版本不对时格式化结果会有细微差异，
  于是你的 diff 里会混进大量无关改动。提交前最好只格式化自己改过的文件，
  并且 `git diff` 通读一遍。
]

=== 8.2.5 每个文件都要有的头部

Blender 从 2023 年起要求所有源文件带 SPDX 标识。`source/` 下
7,157 个受版本控制的文件里，有 7,148 个带 `SPDX-License-Identifier`
（其余几个是二进制或配置文件）。新文件的模板是：

```cpp
/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup blenkernel
 */

#pragma once
```

四个要素，一个都不能少：

1. `SPDX-FileCopyrightText` —— 年份加 `Blender Authors`（新的贡献都归这个名义）。
2. `SPDX-License-Identifier` —— C/C++ 用 `GPL-2.0-or-later`，
   Python 用 `GPL-2.0-or-later`（`scripts/` 下部分文件例外）。
3. `/** \file` + `\ingroup <模块>` —— Doxygen 分组的依据，
   写错了文件在生成的文档里会归错组。
4. `#pragma once` —— Blender 统一用它，不用 `#ifndef` 卫士。
   这个约定执行得相当彻底：`source/` 下 2,050 个 `.hh` 里有 1,879 个、
   642 个 `.h` 里有 638 个用了 `#pragma once`。
   剩下的少数例外多半是需要被重复包含的宏文件或纯前置声明文件
   （例如 #src("source/blender/blenkernel/BKE_id_hash.hh")）。

#pitfall[
  *忘记 `#pragma once`* 在 Blender 里会以"重复定义"的形式爆炸，
  而且报错位置常常在第三个包含它的文件里，很难一眼看出病因。
  新建 `.hh` 时第一件事就是写它。
]

== 8.3 从"一个想法"到"改哪一行"：三路反查法

前面两节给你的是"地图"。这一节给你的是"导航"。
目标很具体：*已知一条零碎信息，找到该改的那一行*。

=== 8.3.1 三条路径与它们的适用条件

可用的信息只有三类，对应三条路径：

#figure(
  kind: table,
  table(
    columns: (auto, 1.15fr, 1fr, 1fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*路径*], [*起点信息*], [*手法*], [*终点*]),
    [界面反查],
    [界面上看到的文字（"渲染区域"、"Loop Mode"…）],
    [`bl_rna` 自省 → RNA 定义 → `UI` 绘制代码],
    [绘制这段界面的 C++ 函数],
    [数据反查],
    [`bpy` 属性名、`.blend` 里的字段、结构体成员名],
    [grep `DNA_*.h` → 找 `_sdna` 绑定 → 找读者/写者],
    [所有读写该字段的代码],
    [调用栈反查],
    [崩溃栈、`--debug-*` 输出、观测到的行为],
    [在候选函数上下断点 / 打开日志],
    [确切的执行路径与行号],
  ),
  caption: [三路反查法的适用条件],
) <tbl-three-paths>

三条路径的可靠性递减、确定性递增：界面反查最快但可能落在别处，
调用栈反查最慢但给出的是事实。*实践中几乎总是组合使用* —— §8.3.5 给了一个完整例子。

=== 8.3.2 路径一：界面反查

起点是界面上的文字。你看到的每一个按钮、滑块、下拉框，
背后几乎都对应一个 RNA 属性，而 RNA 属性有明确的定义位置。

#warn[
  Blender 自带一个"编辑源代码"功能（右键菜单里的 *Edit Source*，
  操作符 `UI_OT_editsource`，定义在
  #src("source/blender/editors/interface/interface_ops.cc:2260-2269")），
  但它*只能跳到 Python*。它的实现依赖 `PyC_FileAndNum_Safe()`
  抓当前 Python 行号（#src("source/blender/editors/interface/interface_ops.cc:2154")），
  对 C++ 定义的按钮只会报
  "Active button is not from a script, cannot edit source"（同文件 :2239-2241）。
  此外这个菜单项只在打开 *Developer Extras* 时出现
  （#src("source/blender/editors/interface/interface_context_menu.cc:1292")）。
  *所以它不能用来反查 C++ 界面代码*，下面讲的方法才是正路。
]

第一步，把界面文字变成 RNA 标识符。开一个脚本控制台：

```python
import bpy

# 拿一个具体的对象，然后枚举它的 RNA 属性
obj = bpy.context.object
for prop in obj.bl_rna.properties:
    if prop.name == "Render Region":          # 界面上显示的文字
        print(prop.identifier, prop.description)
```

`prop.identifier` 就是 RNA 标识符（例如 `use_render_border`），
`prop.description` 就是鼠标悬停时的提示文字。

第二步，用标识符去 grep RNA 定义。因为 `RNA_def_property_ui_text()`
的第二个参数就是界面文字，*界面文字本身也是一个很好的搜索键*：

```bash
# 用 RNA 标识符找定义
$ git grep -n '"use_render_border"' -- source/blender/makesrna
source/blender/makesrna/intern/rna_space.cc:5669:
  prop = RNA_def_property(
      srna, "use_render_border", PROP_BOOLEAN, PROP_NONE);

# 或者直接搜界面文字（注意它有可能是被翻译的，命中率略低）
$ git grep -n 'Render Region' -- source/blender/editors
```

第三步，读这段 RNA 定义，拿到 DNA 绑定和"更新通知"：

```cpp
// source/blender/makesrna/intern/rna_space.cc:5668-5676（节选）
prop = RNA_def_property(srna, "use_render_border", PROP_BOOLEAN, PROP_NONE);
RNA_def_property_boolean_sdna(prop, nullptr, "flag2", V3D_RENDER_BORDER);
RNA_def_property_clear_flag(prop, PROP_ANIMATABLE);
RNA_def_property_ui_text(prop, "Render Region",
                         "Use a region within the frame size for rendered viewport ...");
RNA_def_property_update(prop, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
```

这一小段信息量极大：

- `RNA_def_struct_sdna(srna, "View3D")`（同函数 :5651）告诉我们
  RNA 的 `SpaceView3D` 映射到 DNA 的 `View3D`（在
  #src("source/blender/makesdna/DNA_space_types.h") 里）。
- `RNA_def_property_boolean_sdna(prop, nullptr, "flag2", V3D_RENDER_BORDER)`
  告诉我们它其实是 `View3D.flag2` 的*一个二进制位* —— 这类"一个 bool 对应
  int 的一位"的映射，是 RNA 里最常见的形态（见 §9.3.4）。
- `RNA_def_property_update(prop, NC_SPACE | ND_SPACE_VIEW3D, nullptr)`
  里的 `ND_SPACE_VIEW3D` 是*通知类型*。它就是你从"属性"跳到
  "重绘代码"的桥：去 grep 谁监听 `ND_SPACE_VIEW3D`。

```bash
$ git grep -rn 'ND_SPACE_VIEW3D' -- source/blender/editors | head -5
```

第四步（可选），找绘制这个属性的界面代码。Blender 的 C++ 界面代码里，
凡是画 RNA 属性的地方都会写属性名：

```bash
$ git grep -rn 'use_render_border' -- source/blender/editors
```

如果命中，你就拿到了那一段 `uiItemR(...)` 或 `uiDefButR(...)` 所在的
函数，这就是"界面那一行"。

#tip[
  界面反查有一个"翻译"陷阱：安装中文语言包后，界面上显示的是
  "渲染区域"而不是 "Render Region"，此时用中文搜源码一定搜不到。
  解决办法是*先把语言切回英文*（`Edit > Preferences > Interface > Translation`），
  或者用 `bl_rna` 拿到 `identifier` 后跳过文字这一步。
]

=== 8.3.3 路径二：数据反查

起点是一个字段名，终点是*所有读写它的代码*。这条路径最确定，
因为字段名在整个代码库里是唯一的（同名会冲突，`makesdna` 会报错）。

第一步，确定它属于哪个 DNA 结构体：

```bash
$ git grep -n 'simulation_frame_start' -- source/blender/makesdna
source/blender/makesdna/DNA_scene_types.h:2914:  int simulation_frame_start = 1;
```

第二步，找 RNA 绑定（如果有）。有两种写法，都要试：

```bash
# 写法 A：RNA 标识符与 DNA 成员同名 —— 可能根本没有 _sdna 调用
$ git grep -n '"simulation_frame_start"' -- source/blender/makesrna
source/blender/makesrna/intern/rna_scene.cc:9113:
  prop = RNA_def_property(
      srna, "simulation_frame_start", PROP_INT, PROP_NONE);

# 写法 B：名字不同 —— 一定有 _sdna 调用
$ git grep -n 'simulation_frame_start' -- source/blender/makesrna
```

这里出现了一个必须解释的现象：`rna_scene.cc:9113` 的后面*没有*
`RNA_def_property_int_sdna(...)`，可是这个属性确实能读写 DNA。
原因在 #src("source/blender/makesrna/intern/rna_define.cc:1337-1376")：
`RNA_def_property()` 会*自动尝试*用 RNA 标识符当 DNA 成员名去当前结构体里找，
成功就悄悄绑定，失败也不报错（`DefRNA.silent = true`）。
显式的 `RNA_def_property_*_sdna()` 是*覆盖*这个默认行为。
这条机制在 §9.3.4 详细展开，此处只需记住：
*没有 `_sdna` 调用不代表没有 DNA 绑定*。

第三步，找所有读者和写者。有了 DNA 成员名，直接全库搜：

```bash
$ git grep -n '\bsimulation_frame_start\b' -- source/
source/blender/blenkernel/intern/bake_geometry_nodes_modifier.cc:194:
    return fix_frame_range(scene.simulation_frame_start,
                           scene.simulation_frame_end);
source/blender/blenloader/intern/versioning_400.cc:1631:
    scene.simulation_frame_start = scene.r.sfra;
source/blender/makesdna/DNA_scene_types.h:2914:  int simulation_frame_start = 1;
source/blender/makesrna/intern/rna_scene.cc:9113:  ...
```

四条命中，信息量已经足够你动手了：
读者在 `blenkernel`，版本迁移在 `blenloader/versioning_400.cc`，
定义在 `DNA_scene_types.h`，暴露给 Python 在 `rna_scene.cc`。
*这就是一个字段的完整生命周期*。

第四步，想更深入时，用生成物查内存布局。`makesdna` 会生成
`dna_type_offsets.h`（枚举每个结构体的 SDNA 序号）与
`dna_struct_ids.cc`（`sdna_struct_id_get<T>()` 的特化），
读写 `.blend` 时靠它们把 C++ 类型映射到 SDNA：

```cpp
// source/blender/blenloader/BLO_read_write.hh:108-111（节选）
template<typename T> void write_struct(const T *data)
{
  this->write_struct_by_id(dna::sdna_struct_id_get<T>(), data);
}
```

由此可以知道：*凡是能被写进 `.blend` 的类型，都必须有 SDNA 序号*。
如果你新增了一个 DNA 结构体却忘了把它加进
#src("source/blender/CMakeLists.txt:5-102") 的 `SRC_DNA_INC` 列表，
`makesdna` 根本看不到它，`sdna_struct_id_get<T>()` 就没有特化，
链接期会报未定义符号 —— 报错信息不会提到 `SRC_DNA_INC`，
这是新手最容易卡住的地方之一。

#note[
  还有一个遗留设施值得提一句：`makesdna` 仍然会生成
  `#define SDNA_TYPE_FROM_STRUCT(id) _SDNA_TYPE_##id`
  （#src("source/blender/makesdna/intern/makesdna.cc:677")），
  但 5.2 的代码库里*已经没有任何地方使用它*。
  如果你在网上看到老文章让你用这个宏，那是过时信息。
]

=== 8.3.4 路径三：调用栈反查

前两条路径是"静态"的：只看代码，不动程序。当它们都失效时
（比如你只知道"点某个按钮后卡了三秒"），就必须让程序自己说话。

*用调试器抓调用栈。*

这是最直接的做法。先构建一个 `RelWithDebInfo` 或 `Debug` 版本
（第 2 章讲过 `CMAKE_BUILD_TYPE`），然后用 gdb / lldb 附加：

```bash
# Linux / macOS：直接带符号启动
$ gdb --args ./build_linux/bin/blender --factory-startup
(gdb) break BKE_collection_object_add
(gdb) run
(gdb) bt
```

断点的选择是技巧所在。*不要断在你猜的那个函数上*，
而是断在它的"必经之路"上：

- 想追操作符执行 → 断 `WM_operator_name_call_ptr` 或操作符的 `exec`。
- 想追数据求值 → 断 `DEG_evaluate_on_framechange`（依赖图入口，见第 13 章）。
- 想追 `.blend` 读取 → 断 `blo_read_file_internal`。
- 想追渲染 → 断 `RE_RenderFrame`。

命中断点后再用 `bt` 看栈，就能确认"到底是不是这条路"。

*打开内部日志。*

Blender 有一套分类日志系统（`intern/clog`），可以用命令行开关打开。
相关的调试开关多达几十个，常用的有：

```bash
# 看依赖图到底重建了什么、什么时候重建
$ blender --debug-depsgraph

# 看事件分发（理解"为什么这个快捷键没反应"）
$ blender --debug-events --debug-handlers

# 看 Python 侧的额外信息
$ blender --debug-python

# 看内存分配（配合 guardedalloc 使用）
$ blender --debug-memory

# 全开（输出会非常吵）
$ blender --debug-all
```

这些开关在 #src("source/creator/creator_args.cc:749-798") 里被登记，
每一项都对应 `G_DEBUG_*` 里的一个二进制位
（#src("source/blender/blenkernel/BKE_global.hh:246-284")）。
比如 `--debug-depsgraph` 会打开
`G_DEBUG_DEPSGRAPH_BUILD | G_DEBUG_DEPSGRAPH_EVAL | G_DEBUG_DEPSGRAPH_TAG |
G_DEBUG_DEPSGRAPH_TIME | G_DEBUG_DEPSGRAPH_UID`。

#tip[
  看日志时不要从第一行读。正确做法是：先记下"出问题的那一刻"
  （比如按下按钮），然后从日志末尾往前找时间戳跳变的地方。
  也可以在代码里临时加一句 `CLG_logf` 或 `printf` 打一个自己的标记，
  再用 `grep` 定位你在整段输出里的位置 —— 这比逐行读快一个数量级。
]

*崩溃时拿到栈。*

Blender 自己的断言（`BLI_assert`）在失败时会打印一份栈回溯：

```cpp
// source/blender/blenlib/intern/BLI_assert.cc:39（节选）
blender::BLI_system_backtrace(stderr);
```

`BLI_system_backtrace()` 声明在 #src("source/blender/blenlib/BLI_system.h:21")。
它依赖构建时的符号信息，所以 *Release 构建的崩溃栈几乎没有用*。
排查崩溃时请务必用带调试符号的构建。

启动时加 `--debug-exit-on-error`
（#src("source/creator/creator_args.cc:796")）可以让 Blender 在
检测到错误报告时立刻退出，方便脚本化地抓栈。

*用一个反查的小工具。*

调用栈告诉你"现在发生了什么"，但有时候你需要知道"这行代码是什么时候、
为什么被加进来的"。这时候 `git log -S` 比读代码有效得多：

```bash
# 找出哪次提交引入了这个字段
$ git log -S "simulation_frame_start" --oneline -- source/blender/makesdna/DNA_scene_types.h

# 找出哪次提交改动了这个函数的这一部分
$ git log -L :BKE_collection_object_add:source/blender/blenkernel/intern/collection.cc
```

*提交信息常常直接写出原因和 issue 编号*，这是任何静态阅读都拿不到的信息。

=== 8.3.5 三路合流：一个完整的例子

任务：*"视口的 Render Region 开关到底改了哪个数据？我要让它在某个
条件下自动关闭。"*

*第 1 步（界面反查）。* 界面文字是 "Render Region"。用 `bl_rna`
找到 RNA 标识符：

```python
import bpy
space = bpy.context.space_data
print(space.bl_rna.identifier)          # SpaceView3D
print([p.identifier for p in space.bl_rna.properties
       if "render_border" in p.identifier or p.name == "Render Region"])
```

*第 2 步（界面反查 → RNA）。* 拿到标识符 `use_render_border`，
去 `makesrna` 找定义，得到
#src("source/blender/makesrna/intern/rna_space.cc:5669-5676")：
它绑定到 `View3D.flag2` 的 `V3D_RENDER_BORDER` 位，
结构体 SDNA 名是 `View3D`，更新通知是 `NC_SPACE | ND_SPACE_VIEW3D`。

*第 3 步（数据反查）。* 去 `DNA_space_types.h` 确认 `View3D` 的布局：

```bash
$ git grep -n 'V3D_RENDER_BORDER' -- source/blender/makesdna
source/blender/makesdna/DNA_space_types.h:...:  V3D_RENDER_BORDER = ...
```

同时全库搜 `V3D_RENDER_BORDER`，就能找到所有读这个位的地方
（渲染边框的裁剪计算、绘制边框线、渲染时的视口渲染路径等）。
*这些命中点就是你要插入"自动关闭"逻辑的候选位置。*

*第 4 步（调用栈反查）。* 现在你要确认"用户在视口里拖边框"走的是哪条路。
开 `--debug-events` 复现一次，看是哪个操作符被调用；
或者直接在 gdb 里断在读取 `V3D_RENDER_BORDER` 的那个函数上，
按一下开关看是否命中。

*第 5 步（写代码）。* 到这里你才发现一个关键事实：
`View3D` *不是 ID*，它挂在 `bScreen`/`ScrArea` 下面，
而 `bScreen` 才是 `ID`（`ID_SCR`，见
#src("source/blender/makesdna/DNA_screen_types.h:98")）。
所以"自动关闭"这件事必须考虑：`View3D` 什么时候被重建、
这个改动要不要进 undo、要不要通知依赖图。这些问题在本章无法回答，
但*你能问出正确的问题了* —— 这正是三路反查法的产出。

#summary[
  三路反查法的价值不在"找到那一行"，而在*快速淘汰错误假设*。
  大多数人在源码里迷路，不是因为找不到答案，
  而是因为在一个错误的方向上投入了两小时。
  每一路都能在十分钟内给出"是/不是"的判断。
]

=== 8.3.6 常见问题

#pitfall[
  *易错点 1：只用一种搜索方式。*  `git grep "foo"` 只搜到字面量。
  想搜"所有把某字段设为 1 的地方"要写 `git grep -E '\.foo = (1|true)'`；
  想搜"谁调用它"要写 `git grep -E '\bBKE_foo\('`。把 `-E`、`\b`、
  `--include` 这几个选项练熟，效率差别很大。
]

#pitfall[
  *易错点 2：忘记排除生成目录。*  在仓库根目录执行 `grep -r` 会把
  `lib/`（预编译依赖，可能上 G）一起扫一遍，慢到怀疑人生。
  用 `git grep` 而不是 `grep -r` —— 它只搜受版本控制的文件，
  自动跳过 `lib/`、构建目录和 `.git`。
]

#pitfall[
  *易错点 3：把"界面上的文字"当成稳定的搜索键。*  界面文字会随版本重写，
  也可能是翻译过的。稳定的键是 *RNA 标识符* 和 *操作符 idname*
  （形如 `OBJECT_OT_delete`）—— 后者在上游被视为 API，改名要经过弃用流程。
]

#exercise[
  *练习 8.1（模块定位，30 分钟）。*  不看本章的表，用 `git grep` 回答：
  (a) 把网格的顶点位置批量取出来的函数叫什么、在哪个文件？
  (b) 视口的"叠加层（Overlay）"开关背后的 DNA 字段是什么？
  (c) `bpy.ops.object.duplicate` 的 C++ 实现文件是哪一个？
  答完后回查表 8.2 与表 8.7，看你的直觉路径和正确答案差在哪一步。

  *练习 8.2（数据反查，45 分钟）。*  挑一个你熟悉的 `bpy` 属性
  （例如 `obj.hide_viewport`），完整走一遍 §8.3.3 的四步：
  找 DNA 定义 → 找 RNA 绑定 → 列出所有读写点 → 说明它的更新通知类型。
  把每一步的 `file:line` 记下来。你会得到一份属于自己的"属性解剖报告"。

  *练习 8.3（调用栈反查，1 小时）。*  构建一个带调试符号的 Blender，
  用 gdb/lldb 在 `blo_read_file_internal` 上打断点，打开一个 `.blend`，
  然后把完整的调用栈抄下来。对照第 13 章讲过的依赖图初始化顺序，
  检查你能否说出栈里每一层"为什么必须在这里被调用"。

  *练习 8.4（格式与风格）。*  随便找一个 `.hh` 文件，故意破坏格式
  （把某个函数参数改成一个一行、把缩进改成 4 空格、删掉 `// namespace`），
  然后执行 `make format PATHS="<你改的目录>"`，观察 `git diff` 里
  clang-format 具体修了什么。这是理解 `.clang-format` 最快的方式。
]
