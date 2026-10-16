#import "../common.typ": *
#import "@preview/cetz:0.3.4": canvas, draw

= 第 1 章 Blender 架构总览

第 0 章划定了"能做什么、不能做什么"的边界。本章进一步回答：
*各类代码位于何处，它们如何协作。*

只靠关键词搜索阅读 Blender 源码，很容易沿调用链不断深入，最后失去最初的定位目标。
问题通常不在阅读能力，而在缺少全局地图。Blender 的 `source/`、`intern/`、`extern/`
共有 8,900 多个 C/C++ 源文件、合计 374 万行；在进入具体实现前，必须先知道
各模块的职责、边界与调用方向。

本章就是这张地图。它不追求细节 —— 细节在第 2 篇各章展开 —— 而是要在你脑子里
建立一个粗粒度的模型：源码分成哪几块；数据在程序里有哪两个层次；窗口、数据、
基础库、编辑器、依赖图这五块各自负责什么；一次渲染从按键到磁盘文件走了哪条路。

读完这一章，你应该能够回答诸如此类的问题：
"我想给物体加一个可以保存的字段，该动哪个模块"、
"这个函数名以 `BKE_` 开头，它大概在源码的哪一层"、
"为什么我改了 Python 里的属性值，3D 视口没有立刻更新"。

== 1.1 源码目录结构概览

这一节只建立“先去哪里找”的导航感，不在开篇堆出完整目录字典。具体的模块前缀、
迁移中的 C++ 命名空间、目录树和反查方法统一放在 §8.1；这里先记住五个入口即可。

=== 1.1.1 先用五区地图定位

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*入口*], [*第一次应当想到它的场景*]),
    [`source/blender/`], [修改 Blender 本体的数据、编辑器、绘制、渲染调度或 Python 绑定],
    [`source/creator/`], [追启动流程、命令行参数和 `main()`],
    [`intern/`], [查 Blender 自研但按独立库组织的组件，例如 GHOST、guardedalloc 与 Cycles],
    [`scripts/`], [查随发行版分发的 Python 界面、操作符、模块和官方 addon],
    [`extern/`], [查随仓库带入的第三方依赖；原则上不直接修改#footnote[
      “随仓库带入”常称为 vendored：项目固定一份第三方源码以保证可复现构建，
      但功能修复通常应先提交到该依赖的上游，再由 Blender 升级版本。
    ]],
  ),
  caption: [第一次定位源码时使用的五区地图。完整目录树与模块清单见 §8.1。],
) <tbl-topdirs>

这里最容易混淆的是 `intern/` 与 `extern/`：前者仍是 Blender 项目自己的代码，
只是能被独立构建或测试；后者才是第三方代码。排查构建错误时先分清这条边界，
比记住每个子目录名更有用。

=== 1.1.2 先记四个前缀

`source/blender/` 的传统公开 API 常用大写前缀标出所属模块。开篇阶段只需记住
下面四个；其余前缀以及“前缀与 C++ 命名空间并存”的例外在 §8.1 统一展开。

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*前缀*], [*目录*], [*职责*]),
    [`BLI_`], [`blenlib/`], [基础容器、数学、字符串、文件与线程工具],
    [`BKE_`], [`blenkernel/`], [核心数据类型及其算法],
    [`WM_`], [`windowmanager/`], [窗口、事件分发与操作符框架],
    [`ED_`], [`editors/`], [各编辑器的交互与界面实现],
  ),
  caption: [开篇阶段最值得记住的四个模块前缀。],
) <tbl-core-prefixes>

看到 `BKE_object_free()`，先去 `blenkernel/`；看到 `ED_` 开头的调用，
先去 `editors/`。这是“根据符号猜目录”的第一层直觉，不是绝对规则：
新代码会把函数放进 `blender::bke`、`blender::ed` 等命名空间，
因此找不到全大写前缀时，不要据此断定功能不存在。

=== 1.1.3 本章与第 8 章怎样分工

本章接下来关心的是*系统之间怎样协作*：DNA 与 RNA 如何分层，WM、BKE、BLI、
ED、DEG 的边界在哪里，一次交互或渲染怎样穿过这些边界。第 8 章才关心
*怎样在仓库里找到实现*：完整目录树、模块规模、前缀退化规则和三路反查法。
第一次阅读时顺着本章继续即可；真正开始改 C/C++ 时，再把 §8.1 当作参考表使用。

== 1.2 DNA / RNA 双数据层概览

=== 1.2.1 从"一个立方体的尺寸存在哪里"说起

在 Blender 里新建一个立方体，它的边长是 2 米。这个 2 存在哪里？

答案是分两处，而且是*两套完全不同的机制*：

- 一份存在内存里的 C 结构体 `Object` 里（准确说是 `Object.object_to_world`
  之类的矩阵，以及 `Mesh` 的顶点坐标），布局由 `DNA_object_types.h`、
  `DNA_mesh_types.h` 这些头文件描述。
- 另一份是"这个字段叫什么名字、能不能被 Python 读写、在界面里显示成什么控件"
  的描述，由 `makesrna` 里的 `RNA_def_property` 系列调用声明。

这两套东西在 Blender 里被称作 #term("DNA 层", "DNA layer") 与
#term("RNA 层", "RNA layer")。理解它们的分工，是理解整个 Blender 的第一道门。

=== 1.2.2 DNA：磁盘上的内存快照格式

DNA 解决的问题是：*怎么把一个充满指针的 C 结构体图，原样存进文件，并在几年后
换一台机器读回来。*

`.blend` 文件里存的不只是数据，还有一份*结构体布局的自述*
（被称为 SDNA 块）。读文件时，Blender 先读这份自述，把它和当前编译进来的
DNA 定义做比对，然后按字段名逐字段搬运。这样即使你换了平台、换了编译器、
把某个 `struct` 的字段顺序改了，老文件依然能正确读入。

这个 SDNA 描述在源码里的表示是 `SDNA` 结构体
（#src("source/blender/makesdna/DNA_sdna_types.h:52")），它把"有哪些类型、
每个类型多大、有哪些结构体、每个结构体有哪些成员、成员在什么偏移"全部记录下来：

```cpp
// source/blender/makesdna/DNA_sdna_types.h:52（节选）
struct SDNA {
  /** The 'encoded' data (full copy when #data_alloc is set, otherwise borrowed memory). */
  const char *data;
  int data_size;
  bool data_alloc;
  int pointer_size;
  /** Number of types. */
  int types_num;
  /** Type names. */
  const char **types;
  /** Type lengths. */
  short *types_size;
  ...
```

DNA 层的*源头*是 `source/blender/makesdna/` 里的 97 个 `DNA_*.h`
（`makesdna/` 下 `.h` 文件共 101 个；该目录全部文件为 110 个）。规则很严格：这些头文件里只能出现
固定宽度的整数、`float`、`char` 数组和指针，不能用 C++ 的类、模板、
`std::vector`。原因就是上面那条 —— 内存布局必须可预测、跨平台可复现。

这里需要区分*整份文件的读取入口*和*SDNA 数据的解析函数*。
本书后文所说的“`.blend` 读取入口”，默认是 `blenloader` 对磁盘文件公开的 #src("source/blender/blenloader/BLO_readfile.hh:175") `BLO_read_from_file()`；它负责打开并读取整份 `.blend` 文件。
内部读取链路随后在 #src("source/blender/blenloader/intern/readfile.cc:871-L903") `read_file_dna()` 中找到 `DNA1` 数据块，再把块中的字节交给 #src("source/blender/makesdna/intern/dna_genfile.cc:558") `DNA_sdna_from_data()`；后者只负责把这段编码后的 SDNA 数据解析成 `SDNA` 结构，并不是整份文件的入口。
简化后的关系是：
`BLO_read_from_file()` → `read_file_dna()` → `DNA_sdna_from_data()`。
与整文件读取对应的写入入口是 #src("source/blender/blenloader/BLO_writefile.hh:57") `BLO_write_file()`。

#pitfall[
  "我在 `DNA_object_types.h` 里给 `Object` 加了一个字段，为什么读老文件会崩？"
  —— 因为新字段在老文件里不存在，读入时它的值是未初始化的。
  正确做法不是直接加字段，而是在 `source/blender/blenloader/intern/`
  下写一段版本迁移代码（`versioning_*.cc`，按目标版本分文件，
  最新的一个是 #src("source/blender/blenloader/intern/versioning_520.cc")），
  把老文件的语义翻译成新结构。见第 9 章。
]

`blenloader/intern/` 下的 `versioning_250.cc` 到 `versioning_520.cc` 这一长串文件，
就是 Blender 十几年来所有数据格式变更的历史记录。这是它敢保证
"2005 年做的模型今天还能打开"的代价，也是你加字段时必须遵守的规矩。

=== 1.2.3 RNA：一份可以在运行时被查询的类型系统

DNA 解决"存得下"，但不解决"用得方便"。C 结构体的字段是编译期的，
而 Blender 需要：

- Python 能通过名字读写任意字段（`bpy.data.objects["Cube"].location[0] = 3`）；
- 界面能自动生成控件（拖动一个滑块就要写回字段，并触发更新）；
- 动画系统能按字符串路径找到通道（`objects["Cube"].location` 这条路径要能解析）；
- 撤销系统能把"哪个字段被改了"记成一笔。

于是有了 RNA：*一个运行时可查询的、描述"数据长什么样"的元数据层*。
它的核心结构体是 `StructRNA`
（#src("source/blender/makesrna/intern/rna_internal_types.hh:662")）
和 `PropertyRNA`
（#src("source/blender/makesrna/intern/rna_internal_types.hh:368")）。
`PropertyRNA` 里最关键的两个字段正好对应上面两个需求 ——
"改动时要做什么"和"要通知谁"：

```cpp
// source/blender/makesrna/intern/rna_internal_types.hh:420（节选）
  /** Callback for updates on change. */
  UpdateFunc update;
  int noteflag;
```

RNA 的*源头*是 `source/blender/makesrna/intern/` 下的 115 个 `rna_*` 文件
（其中 108 个是 `.cc` 定义文件，7 个是 `.hh`）。每个文件里有一个
`RNA_def_xxx(BlenderRNA *brna)` 函数，用一串 `RNA_def_*` 调用把
"有哪些类型、每个类型有哪些属性、属性的类型和范围是什么"声明出来。

以最常被当作例子的 `rna_action.cc` 为例，声明一个属性需要四步：

```cpp
// source/blender/makesrna/intern/rna_action.cc:1307（节选）
prop = RNA_def_property(srna, "show_datablock_filters", PROP_BOOLEAN, PROP_NONE);
RNA_def_property_boolean_sdna(prop, nullptr, "flag", ADS_FLAG_SHOW_DBFILTERS);
RNA_def_property_ui_text(
    prop,
    "Show Data-Block Filters",
    "Show options for whether channels related to certain types of data are included");
RNA_def_property_ui_icon(prop, ICON_RIGHTARROW, 1);
RNA_def_property_update(prop, NC_ANIMATION | ND_ANIMCHAN, nullptr);
```

这几行依次回答四个问题：*属性叫什么*（`show_datablock_filters`）、
*它存在 DNA 的哪个字段的哪一位*（`bDopeSheet.flag` 的 `ADS_FLAG_SHOW_DBFILTERS` 位）、
*界面里显示成什么文字和图标*、以及 *改了它要发什么通知并触发什么更新*。
最后一行是下面 §1.5 那条链的起点。

所有定义文件在 `makesrna` 内部的一张静态表里登记，
表的每一项是一个 `RNAProcessItem`
（#src("source/blender/makesrna/intern/makesrna.cc:4019")）：

```cpp
// source/blender/makesrna/intern/makesrna.cc:4019（节选）
struct RNAProcessItem {
  const char *filename;
  const char *api_filename;
  void (*define)(BlenderRNA *brna);
};

static RNAProcessItem PROCESS_ITEMS[] = {
    {"rna_rna.cc", nullptr, RNA_def_rna},
    {"rna_ID.cc", nullptr, RNA_def_ID},
    {"rna_texture.cc", "rna_texture_api.cc", RNA_def_texture},
    ...
```

`makesrna` 是一个*构建期工具*：它读这些定义，生成 C 代码
（`rna_*_gen.cc`），编译进 Blender。运行时 `RNA_init()`
（#src("source/blender/makesrna/intern/rna_access.cc:90")）再把
`BlenderRNA` 结构建起来，`bpy` 模块随即把 `StructRNA` 一个个包装成 Python 类型
（`StructRNA.py_type`，见 #src("source/blender/makesrna/intern/rna_internal_types.hh:674")）。
你在 `bpy.types` 里能看到的每一个类，都是这一步的产物。

=== 1.2.4 两层的分工

#figure(
  kind: table,
  table(
    columns: (auto, 2fr, 2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*问题*], [*DNA 层回答*], [*RNA 层回答*]),
    [定义在哪些文件], [`source/blender/makesdna/DNA_*.h`], [`source/blender/makesrna/intern/rna_*.cc`],
    [核心结构体], [`SDNA` / `SDNA_Struct`], [`StructRNA` / `PropertyRNA`],
    [描述的对象], [内存布局与磁盘布局], [名字、类型、范围、界面、更新回调],
    [何时生效], [构建期生成、读文件时校验], [启动时注册、运行时可查],
    [给谁用], [`.blend` 读写、版本迁移], [`bpy`、界面、动画、撤销、消息总线],
    [能否在运行时新增], [否，必须改头文件并重编译], [是，Python 里 `bpy.props` 就能加],
    [对应的 Python 入口], [不可见], [`bpy.types.*`、`bpy.props.*`],
  ),
  caption: [DNA 与 RNA 的分工对照。判断"该改哪层"的方法是问：这件事是"数据怎么存"还是"数据怎么用"。],
) <tbl-dna-rna>

一个实用判断法：*凡是"要存进 `.blend` 文件"的改动，都必然要动 DNA；
凡是"要让 Python 或界面看到"的改动，都必然要动 RNA。* 大多数功能改动要同时动两边。
两层的完整规则、以及"给已有类型加一个字段"的完整流程，在第 9 章展开。

== 1.3 核心子系统地图

这一节把五个最常被问到的子系统放一起，各自回答"它是什么、为什么存在、
代码在哪、你会在什么时候碰它"。细节留给第 2 篇对应章节。

=== 1.3.1 `WM`：窗口、事件与操作符

#term("窗口管理器", "window manager") 模块（`windowmanager/`，前缀 `WM_`）
承担三件事，而这三件事在别的程序里通常分属三个库：

1. *与操作系统对话*。把所有平台的窗口、鼠标、键盘、剪贴板、触控板、IME
   事件统一成内部事件。这一层实际上大部分委托给 `intern/ghost/`。
2. *事件分发*。把事件按"窗口 → 屏幕（`bScreen`）→ 区域（`ScrArea`）
   → 区段（`ARegion`）→ 控件"逐级下传，最终决定调用哪个
   #term("操作符", "operator")。
3. *操作符注册表*。所有可被用户或脚本调用的"动作"都登记在 `WM` 里。

第 3 件事是 `WM` 最被低估的贡献。Blender 里"做一件事"的统一抽象就是操作符：
按一次 `G` 是 `transform.translate`，点一下"删除"是 `object.delete`，
Python 里的 `bpy.ops.object.delete()` 也是同一个东西。
每个操作符对应一个 `wmOperatorType`
（#src("source/blender/windowmanager/WM_types.hh:1082")），它是一张*回调表*：

```cpp
// source/blender/windowmanager/WM_types.hh:1082（节选）
struct wmOperatorType {
  /** Text for UI, undo (should not exceed #OP_MAX_TYPENAME). */
  const char *name = nullptr;
  /** Unique identifier (must not exceed #OP_MAX_TYPENAME). */
  const char *idname = nullptr;
  ...
  wmOperatorStatus (*exec)(bContext *C, wmOperator *op) ATTR_WARN_UNUSED_RESULT = nullptr;
  ...
  wmOperatorStatus (*invoke)(bContext *C,
                             wmOperator *op,
                             const wmEvent *event) ATTR_WARN_UNUSED_RESULT = nullptr;
  ...
  wmOperatorStatus (*modal)(bContext *C,
                            wmOperator *op,
                            const wmEvent *event) ATTR_WARN_UNUSED_RESULT = nullptr;
  /** Verify if the operator can be executed in the current context. */
  bool (*poll)(bContext *C) ATTR_WARN_UNUSED_RESULT = nullptr;
  ...
  /** RNA for properties. */
  StructRNA *srna = nullptr;
```

`exec` 是不带交互的直接执行（`bpy.ops.object.delete()` 走这条），
`invoke` 是"带交互地启动"（按 `G` 走这条，它进入 modal），
`modal` 在交互过程中反复被调用，`poll` 决定"当前上下文下这个操作符能不能用"。
四个回调覆盖了从"一键执行"到"持续拖拽"的全部形态。

注册机制是第 0 章讲过的那条主线的一个实例。所有操作符的登记入口是
#src("source/blender/windowmanager/WM_api.hh:1414") 声明的
`WM_operatortype_append()`，实现于
#src("source/blender/windowmanager/intern/wm_operator_type.cc:151")。
而内置操作符的清单，就是
#src("source/blender/windowmanager/intern/wm_operators.cc:4233") 的
`wm_operatortypes_register()` 里从第 4235 行开始的那一串调用：

```cpp
// source/blender/windowmanager/intern/wm_operators.cc:4233（节选）
void wm_operatortypes_register()
{
  WM_operatortype_append(WM_OT_window_close);
  WM_operatortype_append(WM_OT_window_new);
  WM_operatortype_append(WM_OT_window_new_main);
  ...
```

这个函数在启动时被调用一次
（#src("source/blender/windowmanager/intern/wm_init_exit.cc:213")，
即在 `WM_init()` 内部）。*注册表在启动时构建完毕、此后只读* ——
这是第 0 章那条"扩展点封闭"的结论在源码里的具体位置。

#note[
  编辑器的操作符（`ED_operatortypes_*`）不在这里注册，而在
  `ED_spacetypes_init()` 里（#src("source/blender/editors/space_api/spacetypes.cc:63")）。
  原因是它们可能需要编辑器自己的状态。第 11 章会把这个区别讲透。
]

=== 1.3.2 `BKE`：核心数据层

`blenkernel/` 是全书出现频率最高的目录，也是改动最常落地的地方。
它管的是*数据本身*：`ID` 的创建/复制/释放、物体与网格、场景与视图层、
材质、修改器的求值入口、库链接、撤销的 ID 部分。

它的大小（323 千行、568 个文件）来自一个刻意的设计选择：
*Blender 没有把数据结构定义和操作它们的函数分开放在两个地方。*
数据结构的定义在 `makesdna/`（纯布局），操作它们的函数在 `blenkernel/`。
所以 `blenkernel` 里你会看到成对的 `BKE_mesh_*`、`BKE_object_*`、`BKE_scene_*`。

理解 `BKE` 的第一件事是 #term("ID", "ID") 这个概念。Blender 里所有"有名字、
能被链接、能被存进文件的数据块"都叫 ID：`Object`、`Mesh`、`Material`、
`Scene`、`World`、`NodeTree`、`Collection`、`Image`、`Action`……
它们全是 `ID` 结构体的"子类"（C 层面是把 `ID id;` 作为第一个成员）。
这带来几个全局性的后果：

- 每个 ID 有一个唯一名字（`Cube`、`Cube.001`），构成命名空间；
- 每个 ID 有一个运行时唯一标识 `session_uid`，跨重命名与重载稳定；
- 可以整体保存、整体链接、整体替换、整体做撤销。

想给你的功能加一个"能存进文件、能在 Python 里看到"的新数据类型，
工作量的大头就在"把它做成一个 ID"上。第 9 章有完整流程。

=== 1.3.3 `BLI`：基础库

`blenlib/`（254 个头文件、171 千行）是 Blender 的"标准库补丁"。
它存在的原因很实际：Blender 需要同时支持 2001 年的 C 代码和 2025 年的 C++20 代码，
需要自己的分配器、自己的可移植字符串处理、自己的容器，
并且这些容器必须能在没有异常、没有 RTTI 的构建配置下工作。

你会频繁用到的部分：

- 容器：`BLI_vector.hh`、`BLI_map.hh`、`BLI_set.hh`、`BLI_string_ref.hh`、
  `BLI_span.hh`。*新代码优先用这些，而不是 `std::vector`。*
- 数学：`BLI_math_vector.hh`、`BLI_math_matrix.hh`、`BLI_math_rotation.hh`，
  以及向量类型 `BLI_math_vector_types.hh` 里的 `float3`、`float4x4`。
- 哈希表：`BLI_ghash.h`，例如 `BLI_ghash_insert()`
  （#src("source/blender/blenlib/BLI_ghash.h:118")）、
  `BLI_ghash_lookup()`（#src("source/blender/blenlib/BLI_ghash.h:145")）。
- 线程：`BLI_threads.h`，例如 `BLI_rw_mutex_lock()`
  （#src("source/blender/blenlib/BLI_threads.h:132")）。
  渲染管线就是用它在渲染线程与主线程之间保护 `RenderResult`。

内存分配在 5.2 里已经全面 C++ 化。老代码里的 `MEM_mallocN` / `MEM_callocN` / `MEM_freeN` 这一族
在 5.2 源码树里已经不再使用（全库只剩 1 处过期注释提及 `MEM_freeN`），取而代之的是类型安全的
`MEM_new<T>()`（#src("intern/guardedalloc/MEM_guardedalloc.h:352")）与
`MEM_delete()`（#src("intern/guardedalloc/MEM_guardedalloc.h:400")）：

```cpp
// 5.2 的推荐写法：类型安全，分配名自动填 __func__
wmOperatorType *ot = MEM_new<wmOperatorType>(__func__);
...
MEM_delete(ot);
```

#pitfall[
  网上和旧书里大量出现 `MEM_callocN`、`MEM_mallocN`、`MEM_freeN` 的示例。
  这些 API 在本基准版本里已被移除，照抄会直接编译失败。
  遇到老代码要么改用 `MEM_new<T>` / `MEM_delete`，
  要么改用 `BLI_vector` 等容器。第 10 章给出完整的迁移对照表。
]

=== 1.3.4 `ED`：编辑器

`editors/` 是最大的模块，也是最"业务化"的模块：3D 视口的旋转、缩放、拾取，
属性面板每一行的绘制，大纲视图的层级展开，节点编辑器的连线吸附……
这些都在这里。

对于"我想加/改一个编辑器"这个需求，`ED` 里有两种不同性质的东西，必须分清：

- *编辑器类型*（`SpaceType`，如"3D 视口"这个编辑器本身）：由
  `BKE_spacetype_register()`（#src("source/blender/blenkernel/BKE_screen.hh:763")）
  注册。全代码库共 19 处调用，每处一个文件，
  例如 #src("source/blender/editors/space_view3d/space_view3d.cc:1727")
  的 `BKE_spacetype_register(std::move(st));`。
  这些调用的总入口是 `ED_spacetypes_init()`
  （#src("source/blender/editors/space_api/spacetypes.cc:63")），
  它在 `ED_spacetypes_init()` 开头逐个调用 `ED_spacetype_*()`
  （#src("source/blender/editors/space_api/spacetypes.cc:70") 起 18 个 `ED_spacetype_*()` 调用，第 88 行另有一个 `spreadsheet::register_spacetype()`，合计 19 个空间类型），
  最后再遍历 `BKE_spacetypes_list()` 调用各编辑器注册的操作符与 gizmo
  （#src("source/blender/editors/space_api/spacetypes.cc:141")）。

- *面板*（`Panel`）与*区段*（`ARegion`）：面板是编辑器内部的一块可折叠 UI，
  用 `bl_space_type` / `bl_region_type` / `bl_context` 决定它出现在哪里。
  这一类 Python 完全能做（第 5 章），也是绝大多数人真正需要的。

```cpp
// source/blender/editors/space_api/spacetypes.cc:63（节选）
void ED_spacetypes_init()
{
  using namespace blender::ed;
  /* UI unit is a variable, may be used in some space type initialization. */
  U.widget_unit = 20;

  /* Create space types. */
  ED_spacetype_outliner();
  ED_spacetype_view3d();
  ED_spacetype_ipo();
  ...
  spreadsheet::register_spacetype();
```

`ED_spacetypes_init()` 在 `WM_init()` 里被调用
（#src("source/blender/windowmanager/intern/wm_init_exit.cc:230")），
调用顺序很讲究：先建所有 `SpaceType`，再注册所有操作符，最后才让每个
`SpaceType` 注册自己的操作符与 gizmo（因为后者可能引用前者）。
*新编辑器必须插进这个序列的正确位置*，第 12 章会讲怎么插。

=== 1.3.5 `DEG`：依赖图

依赖图是这个架构里最重要的一个抽象，也是新读者最难建立直觉的一个。
用一句话说清它要解决的问题：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-part.lighten(95%),
  stroke: (left: 2.6pt + c-part, rest: 0.4pt + c-part.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  用户改了一个参数（"立方体的 Z 缩放变成 2"）。*哪些数据需要重算，
  以什么顺序重算，重算的结果放在哪* —— 这个问题的答案不能由每个功能自己
  临时判断，否则一定会出现"用了旧值算出来的结果"。
  #term("依赖图", "dependency graph") 把"谁依赖谁"显式建模成一张有向图，
  由它统一决定求值顺序。
]

为什么必须有它？在 Blender 里，渲染一个物体的画面需要：物体变换 → 修改器栈
→ 网格求值 → 材质/着色器 → 几何节点 → 粒子/模拟 → ……每一步都可能被多个
上游影响。如果由调用方手工保证顺序，那么"在修改器里用了刚被另一个修改器
改过的数据"这类 bug 会无穷无尽。Blender 2.8 之前就是手工管理的，
结果是数百个"顺序敏感"的补丁。2.8 引入完整依赖图之后，这类问题被系统性消除了。

依赖图的关键概念是 *original 数据* 与 *evaluated 数据* 的分离
（copy-on-evaluation）：用户在界面上编辑的是 original，依赖图求值产生一份
evaluated 副本；求值器写副本，渲染和绘制等下游只读副本。这样“求值器与用户编辑
同时改同一份数据”这类竞态就不会发生。

三个函数构成了你与依赖图交互的绝大部分：

- `DEG_id_tag_update(ID *id, unsigned int flags)`
  （#src("source/blender/depsgraph/DEG_depsgraph.hh:123")）——
  "这个数据变了"，`flags` 说明变了什么（`ID_RECALC_GEOMETRY`、
  `ID_RECALC_TRANSFORM`、`ID_RECALC_PARAMETERS`……）。
- `DEG_graph_relations_update(Depsgraph *graph)`
  （#src("source/blender/depsgraph/DEG_depsgraph_build.hh:70")）——
  "连接关系可能变了"，需要重建图的边（例如新建了一个物体、加了一个修改器）。
- 求值入口。#src("source/blender/depsgraph/DEG_depsgraph.hh:201") 的
  `DEG_evaluate_on_refresh()`

```cpp
// source/blender/depsgraph/DEG_depsgraph.hh:201
void DEG_evaluate_on_refresh(
    Depsgraph *graph,
    DepsgraphEvaluateSyncWriteback sync_writeback = DEG_EVALUATE_SYNC_WRITEBACK_NO);
```

和帧变化时的 #src("source/blender/depsgraph/DEG_depsgraph.hh:192") 的
`DEG_evaluate_on_framechange()`。

#tip[
  记住一个操作顺序能省很多调试时间：*改数据 → `DEG_id_tag_update` →
  改关系 → `DEG_relations_tag_update` / `DEG_graph_relations_update` → 求值。*
  99% 的"改了没生效"和"改了但用了旧值"都能从这四步里找到漏掉的那一步。
  第 13 章逐条讲。
]

=== 1.3.6 五个子系统的接缝

把上面五块拼起来，一次交互的骨架是这样的：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 3.6fr),
    inset: 5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*子系统*], [*源码目录*], [*它不知道的事*]),
    [`BLI_`], [`blenlib/`], [不知道任何 Blender 概念：不知道什么是物体、什么是场景],
    [`BKE_`], [`blenkernel/`], [不知道界面、不知道窗口、不知道事件],
    [`DEG_`], [`depsgraph/`], [不知道界面；通过回调通知编辑器刷新],
    [`WM_`], [`windowmanager/`], [不知道具体编辑器怎么画，只知道事件该送给哪个区域],
    [`ED_` / `DRW_`], [`editors/` / `draw/`], [知道一切，站在最上层],
  ),
  caption: [五层各自"不知道什么"。判断一段代码该放哪层时，问"它需不需要知道上层的东西"。],
) <tbl-layers>

== 1.4 渲染管线概貌

=== 1.4.1 三种"渲染"是同一件事的三个调用者

初学者最容易混淆的一点：Blender 里"渲染"这个词至少覆盖三种场景 ——
*离线渲染*（按 F12，出图）、*视口渲染*（把视口切到 Rendered 模式实时看）、
*预览渲染*（材质球、资产缩略图）。它们在源码里共用同一套引擎注册表，
但走不同的调用路径。

引擎注册表是 #src("source/blender/render/RE_engine.h:69") 的全局链表：

```cpp
// source/blender/render/RE_engine.h:69
extern ListBaseT<RenderEngineType> R_engines;
```

每个引擎是一个 `RenderEngineType`
（#src("source/blender/render/RE_engine.h:71")），同样是一张回调表：

```cpp
// source/blender/render/RE_engine.h:71（节选）
struct RenderEngineType {
  struct RenderEngineType *next, *prev;

  /* Type info. */
  char idname[/*BKE_ST_MAXNAME*/ 64];
  char name[64];
  int flag;

  void (*update)(struct RenderEngine *engine, struct Main *bmain, struct Depsgraph *depsgraph);
  void (*render)(struct RenderEngine *engine, struct Depsgraph *depsgraph);
  void (*render_frame_finish)(struct RenderEngine *engine);
  void (*draw)(struct RenderEngine *engine,
               const struct bContext *context,
               struct Depsgraph *depsgraph);
  ...
```

`render` 是离线渲染，`draw` 是视口绘制，`view_update` / `view_draw` 是视口的
更新与绘制，`bake` 是烘焙。这些回调全部是可选的 ——
一个只做离线渲染的引擎不需要实现 `draw`。

=== 1.4.2 内置引擎与外部引擎

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr, auto),
    inset: 5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*引擎*], [`idname`], [*实现在*], [*注册方式*]),
    [EEVEE], [`BLENDER_EEVEE`],
    [#src("source/blender/draw/engines/eevee/eevee_engine.cc:79")],
    [C++ 静态结构体 + `RE_engines_register()`],
    [Workbench], [`BLENDER_WORKBENCH`],
    [#src("source/blender/draw/engines/workbench/workbench_engine.cc:802")],
    [同上],
    [Cycles], [`CYCLES`],
    [#src("intern/cycles/blender/addon/__init__.py:44")],
    [Python `bpy.types.RenderEngine` 子类],
  ),
  caption: [内置引擎与外部引擎的注册方式对照。"注册方式"一列解释了为什么自定义渲染引擎是 Python 能做的事。],
) <tbl-engines>

这是全书最有教育意义的一组对照。EEVEE 是 C++ 引擎，它的
`RenderEngineType` 是一个静态初始化的全局变量，字段逐个填好：

```cpp
// source/blender/draw/engines/eevee/eevee_engine.cc:79（节选）
RenderEngineType DRW_engine_viewport_eevee_type = {
    /*next*/ nullptr,
    /*prev*/ nullptr,
    /*idname*/ "BLENDER_EEVEE",
    /*name*/ N_("EEVEE"),
    /*flag*/ RE_INTERNAL | RE_USE_PREVIEW | RE_USE_STEREO_VIEWPORT | RE_USE_GPU_CONTEXT,
    /*update*/ nullptr,
    /*render*/ &eevee_render,
    ...
```

然后由 #src("source/blender/draw/intern/draw_context.cc:2281") 的
`DRW_engines_register()` 登记：

```cpp
// source/blender/draw/intern/draw_context.cc:2281
void DRW_engines_register()
{
  RE_engines_register(&DRW_engine_viewport_eevee_type);
  RE_engines_register(&DRW_engine_viewport_workbench_type);
}
```

`RE_engines_register()` 本身极简（#src("source/blender/render/intern/engine.cc:97")）：

```cpp
// source/blender/render/intern/engine.cc:97
void RE_engines_register(RenderEngineType *render_type)
{
  BLI_addtail(&R_engines, render_type);
}
```

而 Cycles 走的是完全不同的路：它是在 Python 里继承 `bpy.types.RenderEngine`
声明的一个 addon 类
（#src("intern/cycles/blender/addon/__init__.py:44")），
由 `bpy` 的类注册机制在运行时把 Python 类翻译成一个 `RenderEngineType`
（`ExtensionRNA rna_ext` 字段就是那个桥）。这解释了第 0 章那张边界表里
"自定义渲染引擎：Python 可以"的原因 —— *引擎是少数几个 Python 能完整注册的
扩展类型之一*。

#note[
  默认引擎的兜底逻辑值得看一眼。`RE_engines_find()`
  （#src("source/blender/render/intern/engine.cc:102")）在按 `idname` 找不到时，
  会回退到 `"BLENDER_EEVEE"`。所以如果你把 Cycles addon 禁用了，
  场景里原本指向 `CYCLES` 的渲染设置不会报错，而是静默地变成 EEVEE。
  调试"为什么我的图看起来不对"时，先确认 `scene.render.engine` 实际解析到了谁。
]

=== 1.4.3 一次离线渲染的管线

离线渲染的总入口是
#src("source/blender/render/intern/pipeline.cc:1925") 的 `RE_RenderFrame()`。
它的骨架非常清楚：

```cpp
// source/blender/render/intern/pipeline.cc:1925（节选）
void RE_RenderFrame(Render *re, ...)
{
  ...
  if (render_init_from_main(
          re, &scene->r, bmain, scene, single_layer, camera_override, false, false))
  {
    ...
    render_init_depsgraph(re);      // 为渲染单独准备一个依赖图
    do_render_full_pipeline(re);    // 真正的渲染
    ...
        do_write_image_or_movie(re, bmain, scene, 0, filepath_override, write_still);
  }
}
```

`do_render_full_pipeline()`
（#src("source/blender/render/intern/pipeline.cc:1480")）决定"这一帧由谁产生"。
它的分支结构就是整个渲染管线的形状：

```cpp
// source/blender/render/intern/pipeline.cc:1480（节选）
static void do_render_full_pipeline(Render *re)
{
  ...
  if (RE_engine_render(re, true)) {
    /* in this case external render overrides all */
  }
  else if (RE_seq_render_active(re->scene, &re->r)) {
    ...
      do_render_sequencer(re);
  }
  else {
    do_render_compositor(re);
  }
```

三个分支：*外部引擎*（如果场景选的引擎实现了 `render` 回调，比如 Cycles，
它接管全部工作）、*序列器*（场景里开了视频序列编辑）、
*合成器 + 引擎*（默认路径）。第三条分支展开成：

#figure(
  html-figure("fig-offline-pipeline", () => canvas(length: 1cm, {
    import draw: *
    set-style(stroke: (paint: luma(72%), thickness: 0.35pt))

    let box(x, y, w, h, fill, border, label, sub) = {
      rect((x, y), (x + w, y + h), radius: 3pt, fill: fill, stroke: 0.9pt + border)
      content(
        (x + w / 2, y + h * 0.66),
        text(font: font-zh, size: 8.6pt, weight: 700, fill: border.darken(20%))[#label],
        anchor: "center",
      )
      if sub != none {
        content(
          (x + w / 2, y + h * 0.28),
          text(font: font-mono, size: 6.6pt, fill: luma(38%))[#sub],
          anchor: "center",
        )
      }
    }

    let arrow(x1, y1, x2, y2) = line(
      (x1, y1), (x2, y2), mark: (end: ">", fill: luma(35%)), stroke: 0.9pt + luma(45%),
    )

    let lbl(x, y, s) = content(
      (x, y), text(font: font-mono, size: 6.6pt, fill: luma(45%))[#s], anchor: "center",
    )

    // 入口
    box(0.3, 11.5, 5.4, 1.35, luma(96%), luma(45%), [RE_RenderFrame()], "pipeline.cc:1925")
    box(6.4, 11.5, 5.4, 1.35, luma(96%), luma(45%), [do_render_full_pipeline()], "pipeline.cc:1480")
    arrow(3.0, 11.5, 3.0, 9.75)
    arrow(9.1, 11.5, 9.1, 9.75)

    // 三条分支（等宽、间距相等：0.3 / 4.6 / 8.9）
    box(0.3, 8.4, 3.4, 1.35, c-primary.lighten(93%), c-primary, [合成器], "COM_  compositor/")
    box(4.6, 8.4, 3.4, 1.35, c-tip.lighten(93%), c-tip, [渲染引擎], "RE_  draw/engines")
    box(8.9, 8.4, 3.4, 1.35, c-warn.lighten(94%), c-warn, [序列器], "SEQ_  sequencer/")

    // 汇合到渲染结果
    box(5.4, 4.7, 4.9, 1.5, c-summary.lighten(95%), c-summary, [渲染结果 RenderResult], "imbuf/  IMB_")

    // 写盘
    box(5.4, 2.0, 4.9, 1.35, luma(96%), luma(45%), [写盘 / 显示], "do_write_image_or_movie()")

    arrow(2.0, 8.4, 6.3, 6.2)
    arrow(6.3, 8.4, 7.2, 6.2)
    arrow(10.6, 8.4, 8.1, 6.2)

    arrow(7.85, 4.7, 7.85, 3.35)

    // 箭头标注（全部落在方框之间的空白带上）
    lbl(3.1, 7.15, "do_render_engine()")
    lbl(7.9, 7.6, "渲染各视图层")
    lbl(8.9, 7.15, "do_render_sequencer()")
    lbl(7.85, 4.0, "do_write_image_or_movie()")

    line((0.0, 1.2), (11.8, 1.2), stroke: 0.8pt + c-part)
  })),
  caption: [一次离线渲染的管线。上部两个框是调度入口；三条分支里只有"引擎 + 合成器"是默认路径，另外两条会接管全部渲染工作。],
) <fig-offline-pipeline>

进入合成器分支后，真正的引擎求值发生在
#src("source/blender/render/intern/pipeline.cc:1224") 的
`do_render_engine(re)`；合成器自身的执行在
#src("source/blender/render/intern/pipeline.cc:1214") 的
`do_render_compositor(re)` 里，它最终把结果交给
`compositor::` 命名空间下的执行器（#src("source/blender/render/intern/pipeline.cc:1283")）。

=== 1.4.4 视口渲染走的是另一条路

视口里把着色模式切到 Rendered 时，走的不是 `RE_RenderFrame()`，
而是 `draw manager` 的实时循环：引擎的 `draw` 回调在每一帧被调用，
被渲染到屏幕上的帧缓冲而不是 `RenderResult`。EEVEE 两者都支持 ——
#src("source/blender/draw/engines/eevee/eevee_engine.cc:69") 的
`eevee_render()` 通过 `DRW_render_to_image()` 把 GPU 绘制的结果写进图像缓冲，
这样离线和视口能共用同一套绘制代码。

Cycles 则分别实现 `render`（离线）和 `view_draw`（视口预览），
两条路径都通向同一个 `engine.py` 里的 session。这也是
"Cycles 视口预览和最终渲染看起来不完全一样"的根源 —— 它们是不同的代码路径。

#summary[
  渲染管线的三句话版本：*引擎是一张回调表，注册在一张全局链表里；
  离线渲染由 `RE_RenderFrame` → `do_render_full_pipeline` 统一调度；
  视口渲染由 `draw manager` 每帧调用引擎的 `draw`，两者共用引擎但不共用调度。*
  第 15 章会逐函数展开 `do_render_compositor()` 与合成器的执行模型。
]

== 1.5 数据从哪来、到哪去：一次端到端走查

这一节把前面四节拼起来，跟着一次真实的操作走完全程。场景很普通：
*你在属性面板里把立方体的 "Z Scale" 从 1 拖到 2，然后按 F12 出图。*

我们会经过：鼠标事件 → 界面控件 → `RNA` 写值 → 通知 → 依赖图 → 重绘 →
按 F12 后的渲染。每一步都给出源码位置。建议你一边读一边在源码里打开这些位置 ——
这一节的目的是让你建立"一次改动要过多少道手"的直觉。

=== 1.5.1 第 0 步：启动时这些东西是怎么装上的

在跟着操作走之前，先确认"参与者"都在场。

`main()` 在 #src("source/creator/creator.cc:332")。它按固定顺序启动子系统：
日志（`CLG_init`）、图像缓冲（`IMB_init`）、`RNA_init()`
（#src("source/creator/creator.cc:571")）、渲染引擎表
（`RE_engines_init()`，#src("source/creator/creator.cc:574")）、
节点系统（`bke::node_system_init()`，#src("source/creator/creator.cc:575")），
最后 `WM_init(C, argc, argv)`（#src("source/creator/creator.cc:608")）。

`WM_init()`（#src("source/blender/windowmanager/intern/wm_init_exit.cc:201")）
再补齐操作符、面板类型、键位配置、编辑器类型（`ED_spacetypes_init()`，
第 230 行）、字体与翻译，最后读取启动文件和用户偏好。之后进入事件循环：

```cpp
// source/blender/windowmanager/intern/wm.cc:598（节选）
void WM_main(bContext *C)
{
  /* Single refresh before handling events.
   * This ensures we don't run operators before the depsgraph has been evaluated. */
  wm_event_do_refresh_wm_and_depsgraph(C);

  while (true) {
    /* Get events from ghost, handle window events, add to window queues. */
    wm_window_events_process(C);

    /* Per window, all events to the window, screen, area and region handlers. */
    wm_event_do_handlers(C);

    /* Events have left notes about changes, we handle and cache it. */
    wm_event_do_notifiers(C);

    /* Execute cached changes draw. */
    wm_draw_update(C);

    PRF_frame_mark;
  }
}
```

`WM_main()` 就是整个程序的形状。四步一轮：*取事件 → 处理事件 → 处理通知 →
重绘*。记住这四步，后面每一步都能对上号。

=== 1.5.2 第 1 步：从鼠标到"写值"

`wm_window_events_process()` 从 Ghost 取来原始事件，
`wm_event_do_handlers()` 把它逐级下传。拖拽数字滑块时，
调整的过程被界面代码累积；在你松开鼠标（或输入回车）确定数值时，
界面代码调用 RNA 的写接口把最终值写进 DNA 结构体的字段。

这一层你会用 Python 直接体验到。下面这段等价于"手动改这个值"，它走的是
完全相同的 C 路径（只是 Python 侧少了一次界面交互）：

```python
import bpy
ob = bpy.data.objects["Cube"]
ob.scale[2] = 2.0          # ← RNA 写值：PropertyRNA 的 set 回调
ob.update_tag()            # ← 显式打脏标记，见第 3 步
```

关键认识：*`ob.scale[2] = 2.0` 这一个赋值后面是一整条链*，
而这条链的最终效果是"3D 视口里立方体变高了"。这条链的驱动者就是 RNA 的
`update` 回调与 `noteflag`。

=== 1.5.3 第 2 步：RNA 写值触发了什么

写值的落点是 `rna_property_update()`
（#src("source/blender/makesrna/intern/rna_access.cc:2474")，
对外入口为同文件的 `RNA_property_update()`，第 2574 行）。它做四件事，
值得逐段读：

```cpp
// source/blender/makesrna/intern/rna_access.cc:2474（节选）
static void rna_property_update(
    bContext *C, Main *bmain, Scene *scene, PointerRNA *ptr, PropertyRNA *prop)
{
  ...
    if (prop->update) {
      ...
      else {
        prop->update(bmain, scene, ptr);        // ① 属性自己的更新回调
      }
    }

    if (prop->noteflag) {
      WM_main_add_notifier(prop->noteflag, ptr->owner_id);   // ② 广播通知
    }

    /* if C is nullptr, we're updating from animation. */
    if (C != nullptr) {
      wmMsgBus *mbus = CTX_wm_message_bus(C);
      WM_msg_publish_rna(mbus, ptr, prop);      // ③ 消息总线（供 UI 绑定使用）
    }
    if (ptr->owner_id != nullptr && ((prop->flag & PROP_NO_DEG_UPDATE) == 0)) {
      const short id_type = GS(ptr->owner_id->name);
      if (ID_TYPE_USE_COPY_ON_EVAL(id_type)) {
        if (prop->flag & PROP_DEG_SYNC_ONLY) {
          DEG_id_tag_update(ptr->owner_id, ID_RECALC_SYNC_TO_EVAL);
        }
        else {
          DEG_id_tag_update(ptr->owner_id,
                            ID_RECALC_SYNC_TO_EVAL | ID_RECALC_PARAMETERS);   // ④ 标记依赖图
        }
      }
    }
  ...
```

四件事分别是：*属性自己的回调*（例如"改了这个值要重新算缓存"）、
*广播通知*（`WM_main_add_notifier`，告诉界面"这块数据变了"）、
*发布到消息总线*（供 `bpy` 的属性订阅与界面绑定使用）、
*标记依赖图*（`DEG_id_tag_update`）。

注意 ④ 的位置很关键：*并不是所有属性都会自动标记依赖图*。
带 `PROP_NO_DEG_UPDATE` 标志的属性不会，而 ID 属性（自定义属性）会走另一条分支
（#src("source/blender/makesrna/intern/rna_access.cc:2531")），
并且那里有一段注释明确说出了行为差异：

```cpp
// source/blender/makesrna/intern/rna_access.cc:2533（节选）
    /* Disclaimer: this logic is not applied consistently, causing some confusing behavior.
     *
     * - When animated (which skips update functions).
     * - When ID-properties are edited via Python (since RNA properties aren't used in this case).
     ...
     * So editing custom properties only causes updates in the UI,
     * keep this exception because it happens to be useful for driving settings.
     * Python developers on the other hand will need to manually 'update_tag', see: #74000. */
```

#pitfall[
  这段注释解释了一个经典的困惑：*为什么我用 Python 改了自定义属性，
  渲染结果没变？* 因为自定义属性（`PROP_IDPROPERTY`）的写入只触发界面更新，
  不会自动打脏依赖图。Python 侧必须显式调用
  `id.update_tag()`（或 `bpy.context.view_layer.update()`）。
  这也是第 6 章那条"Python 改完数据要记得 update_tag"建议的出处。
]

=== 1.5.4 第 3 步：通知队列

`WM_main_add_notifier()`
（#src("source/blender/windowmanager/intern/wm_event_system.cc:403")）
只是把一个 `wmNotifier` 记录塞进队列，*不做任何即时处理*。
这是一种蓄意设计的延迟：

```cpp
// source/blender/windowmanager/intern/wm_event_system.cc:403
void WM_main_add_notifier(uint type, void *reference)
{
  Main *bmain = G_MAIN;
  wmWindowManager *wm = static_cast<wmWindowManager *>(bmain->wm.first);

  WM_event_add_notifier_ex(wm, nullptr, type, reference);
}
```

为什么要延迟？因为一次用户操作可能连续改十几个属性。如果每个都立即触发重绘，
一次拖拽就会引发几十次重绘，程序会卡死。*把所有改动收集起来，
在一轮事件处理结束时统一刷新*，是 Blender 界面能保持流畅的关键。
你现在应该能理解 `WM_main()` 循环为什么是"处理完事件 → 处理通知 → 重绘"
这个顺序了。

=== 1.5.5 第 4 步：处理通知 → 触发依赖图求值

一轮的第三步是 `wm_event_do_notifiers()`
（#src("source/blender/windowmanager/intern/wm_event_system.cc:596")）。
它遍历通知队列，把它们翻译成"哪个区域需要重绘"
（`ED_region_tag_redraw()`，#src("source/blender/editors/include/ED_screen.hh:76")）
和 "哪个区域需要重新构建"（`area.do_refresh`）。

紧接着，`wm_event_do_refresh_wm_and_depsgraph()`
（#src("source/blender/windowmanager/intern/wm_event_system.cc:545")）
先跑编辑器的刷新回调，再调用 `wm_event_do_depsgraph(C, false)`：

```cpp
// source/blender/windowmanager/intern/wm_event_system.cc:545（节选）
void wm_event_do_refresh_wm_and_depsgraph(bContext *C)
{
  ...
    for (ScrArea &area : screen->areabase) {
      if (area.do_refresh) {
        CTX_wm_area_set(C, &area);
        ED_area_do_refresh(C, &area);
      }
    }

  wm_event_do_depsgraph(C, false);
```

`wm_event_do_depsgraph()`（#src("source/blender/windowmanager/intern/wm_event_system.cc:488")）
是所有可见视图层的依赖图求值入口。它先合并各视口需要的
`CustomData_MeshMasks`（"这个视口需要网格的哪些层"），
然后对每个窗口的依赖图调用：

```cpp
// source/blender/windowmanager/intern/wm_event_system.cc:534（节选）
    Depsgraph *depsgraph = BKE_scene_ensure_depsgraph(bmain, scene, view_layer);
    if (is_after_open_file) {
      DEG_graph_tag_on_visible_update(depsgraph, true);
    }
    DEG_make_active(depsgraph);
    BKE_scene_graph_update_tagged(depsgraph, bmain);
```

`BKE_scene_graph_update_tagged()` 在
#src("source/blender/blenkernel/intern/scene.cc:2827")，
它转发给 `scene_graph_update_tagged()`
（#src("source/blender/blenkernel/intern/scene.cc:2749")），
后者的主体是一个*最多两轮的循环*，因为它要处理"更新回调又改了数据"这种情况：

```cpp
// source/blender/blenkernel/intern/scene.cc:2771（节选）
  for (int pass = 0; pass < 2; pass++) {
    /* (Re-)build dependency graph if needed. */
    DEG_graph_relations_update(depsgraph);
    /* Flush editing data if needed. */
    prepare_mesh_for_viewport_render(bmain, scene, view_layer);
    /* Update all objects: drivers, matrices, etc. flags set
     * by depsgraph or manual, no layer check here, gets correct flushed. */
    DEG_evaluate_on_refresh(depsgraph, DEG_EVALUATE_SYNC_WRITEBACK_YES);
    ...
    if (DEG_is_fully_evaluated(depsgraph)) {
      break;
    }
    ...
```

四行核心：*重建关系 → 刷新编辑模式数据 → 求值 → 检查是否能提前退出*。
求值结束后，`DEG_editors_update()`（通过第 1.3 节提到的那个回调，
由 `DEG_editors_set_update_cb()` 在
#src("source/blender/windowmanager/intern/wm_init_exit.cc:228") 注册）
把"哪些 ID 被重新求值了"通知给编辑器 ——
这就是"改了 Z Scale，右侧 N 面板的数值和 3D 视口同时更新"的机制。

=== 1.5.6 第 5 步：重绘

一轮的第四步 `wm_draw_update()` 才真正画图。
它只重绘被标记过的区域，被标记的区域里 3D 视口会用 `DRW_` 的绘制管线，
把依赖图求值出来的 evaluated 网格与变换画到屏幕上。
到这一步，你已经看到立方体变高了。

=== 1.5.7 第 6 步：按 F12 出图

按 F12 触发的是 `render.render` 操作符（`invoke` 进入渲染流程）。
它最终走到 §1.4 讲过的 `RE_RenderFrame()`
（#src("source/blender/render/intern/pipeline.cc:1925")）。
这里有一个关键点值得单独指出：

```cpp
// source/blender/render/intern/pipeline.cc:1956（节选）
    render_init_depsgraph(re);
```

*渲染不使用界面那个依赖图，而是新建一个专供渲染的依赖图。*
原因是渲染需要的数据比界面多得多（高精度细分、粒子、体积、更多 UV 层），
而且必须在与界面并行的线程里安全地求值。这条设计决定了
"视口看到的"和"渲染出来的"在细节上可能不一致 —— 这不是 bug，
是两个依赖图的 `CustomData_MeshMasks` 不同。第 13 章与第 15 章会分别
从依赖图侧和渲染侧解释这件事。

=== 1.5.8 整条链

#figure(
  html-figure("fig-e2e-chain", () => canvas(length: 0.98cm, {
    import draw: *
    set-style(stroke: (paint: luma(72%), thickness: 0.35pt))

    let step(x, y, w, h, fill, border, label, sub) = {
      rect((x, y), (x + w, y + h), radius: 3pt, fill: fill, stroke: 0.9pt + border)
      content(
        (x + 0.22, y + h * 0.68),
        text(font: font-zh, size: 8.4pt, weight: 700, fill: border.darken(20%))[#label],
        anchor: "west",
      )
      content(
        (x + 0.22, y + h * 0.25),
        text(font: font-mono, size: 6.8pt, fill: luma(38%))[#sub],
        anchor: "west",
      )
    }

    let arrow(x1, y1, x2, y2) = line(
      (x1, y1), (x2, y2), mark: (end: ">", fill: luma(35%)), stroke: 0.9pt + luma(45%),
    )

    // ── 第一行：事件阶段
    step(0.0, 9.9, 5.2, 1.35, luma(96%), luma(45%), [① Ghost 事件], "wm_window_events_process()")
    step(5.7, 9.9, 5.2, 1.35, luma(96%), luma(45%), [② 事件分发], "wm_event_do_handlers()")
    step(11.4, 9.9, 5.2, 1.35, c-primary.lighten(93%), c-primary, [③ RNA 写值], "rna_property_update()")

    // ── 第二行：标记阶段
    step(11.4, 7.9, 5.2, 1.35, c-tip.lighten(93%), c-tip, [④ 通知入队], "WM_main_add_notifier()")
    step(5.7, 7.9, 5.2, 1.35, c-tip.lighten(93%), c-tip, [⑤ 依赖图打脏], "DEG_id_tag_update()")
    step(0.0, 7.9, 5.2, 1.35, c-tip.lighten(93%), c-tip, [⑥ 消息总线], "WM_msg_publish_rna()")

    // ── 第三行：求值阶段
    step(0.0, 5.9, 5.2, 1.35, c-warn.lighten(94%), c-warn, [⑦ 编辑器刷新], "ED_area_do_refresh()")
    step(5.7, 5.9, 5.2, 1.35, c-warn.lighten(94%), c-warn, [⑧ 依赖图求值], "BKE_scene_graph_update_tagged()")
    step(11.4, 5.9, 5.2, 1.35, c-warn.lighten(94%), c-warn, [⑨ 通知编辑器], "DEG_editors_update()")

    // ── 第四行：呈现阶段
    step(11.4, 3.9, 5.2, 1.35, c-summary.lighten(95%), c-summary, [⑩ 区域重绘], "wm_draw_update()")
    step(5.7, 3.9, 5.2, 1.35, c-summary.lighten(95%), c-summary, [⑪ 硬件绘制], "DRW_ / GPU_")
    step(0.0, 3.9, 5.2, 1.35, c-summary.lighten(95%), c-summary, [⑫ 屏幕更新], "视口里立方体变高")

    // ── 渲染侧（F12）
    step(0.0, 1.5, 5.2, 1.35, luma(96%), luma(45%), [⑬ F12 / 渲染操作符], "render.render")
    step(5.7, 1.5, 5.2, 1.35, luma(96%), luma(45%), [⑭ 新依赖图], "RE_RenderFrame()")
    step(11.4, 1.5, 5.2, 1.35, luma(96%), luma(45%), [⑮ 引擎 + 合成器], "do_render_full_pipeline()")

    // 行内箭头（左→右）
    arrow(5.2, 10.58, 5.7, 10.58)
    arrow(10.9, 10.58, 11.4, 10.58)
    arrow(11.4, 8.58, 10.9, 8.58)
    arrow(5.7, 8.58, 5.2, 8.58)
    arrow(5.2, 6.58, 5.7, 6.58)
    arrow(10.9, 6.58, 11.4, 6.58)
    arrow(11.4, 4.58, 10.9, 4.58)
    arrow(5.7, 4.58, 5.2, 4.58)

    // 行间换行
    arrow(14.0, 9.9, 14.0, 9.25)
    arrow(8.3, 7.9, 8.3, 7.25)
    arrow(2.6, 5.9, 2.6, 5.25)
    arrow(14.0, 3.9, 14.0, 3.25)

    // 渲染链
    arrow(2.6, 3.9, 2.6, 2.85)
    arrow(5.2, 2.18, 5.7, 2.18)
    arrow(10.9, 2.18, 11.4, 2.18)
    arrow(14.0, 1.5, 14.0, 0.55)

    // 渲染输出终点
    rect((0.0, 0.15), (16.6, 0.85), radius: 3pt, fill: c-part.lighten(94%), stroke: 0.9pt + c-part)
    content(
      (8.3, 0.5),
      text(font: font-zh, size: 8.2pt, weight: 700, fill: c-part)[
        ⑯ `RenderResult` → `do_write_image_or_movie()` → 磁盘上的 PNG
      ],
      anchor: "center",
    )

    line((0.0, 14.55), (16.6, 14.55), stroke: 0.9pt + c-part)
    content(
      (0.0, 14.0),
      block(width: 16.2cm, text(font: font-zh, size: 7.4pt, fill: luma(42%))[
        箭头走向：①→⑥ 是一轮 `WM_main()` 四步中的前两步（取事件、处理事件）；⑦→⑫ 是后两步（处理通知、重绘）。⑬→⑯ 是按下 F12 之后的第二个流程。
      ]),
      anchor: "north-west",
    )
  })),
  caption: [一次"改参数 → 界面刷新 → 渲染出图"的完整链条。方框上方标着序号，下方是老老实实的函数名。],
) <fig-e2e-chain>

这张图值得对照源码走一遍。它的价值不在于记住 16 个函数名，而在于：

- *知道"改了没生效"可能断在哪一环* —— 断在 ④（没发通知），
  界面不会刷新；断在 ⑤（没打脏标记），依赖图不会重算；
  断在 ⑧（`PROP_NO_DEG_UPDATE`），求值不会发生。
- *知道界面和渲染是两条链* —— ⑬ 之后渲染另起一个依赖图。
  "视口正常但渲染错"和"渲染正常但视口错"是两类不同的问题。
- *知道哪里是天然的扩展点* —— 想在"改参数"之后插入自己的逻辑，
  正确的位置是给 `PropertyRNA` 挂 `update` 回调（③），
  不是在界面代码里打补丁。

#exercise[
  *练习 1.1（入门）· 画出你自己的调用链。*
  在源码里按顺序打开下面这些位置，把每一处的函数名与行号抄下来，
  然后在纸上画一张和你自己项目的调用链同构的图：

  ```bash
  # 在 Blender 源码根目录下执行
  $ grep -n "^void WM_main" source/blender/windowmanager/intern/wm.cc
  $ grep -n "wm_event_do_refresh_wm_and_depsgraph(bContext" source/blender/windowmanager/intern/wm_event_system.cc
  $ grep -n "static void rna_property_update" source/blender/makesrna/intern/rna_access.cc
  $ grep -n "void BKE_scene_graph_update_tagged" source/blender/blenkernel/intern/scene.cc
  ```

  要求：图中每个框必须有一个真实存在的"文件路径:行号"。

  *练习 1.2（进阶）· 找一条真实的属性更新回调。*
  选一个你能在界面上操作的属性（比如 3D 视口侧栏里
  "Viewport Display → Color"的物体的颜色），
  用 `grep` 在 `source/blender/makesrna/intern/` 里找到它的
  `RNA_def_property_update()` 调用，读出那个 `noteflag` 是什么，
  再到 `source/blender/windowmanager/` 下找出谁消费了这个 flag。
  这一步做完，你就掌握了"顺着通知排查界面不刷新"的完整方法。

  *练习 1.3（挑战）· 核验一条本文的结论。*
  文中说"带 `PROP_NO_DEG_UPDATE` 的属性不会自动打脏依赖图"。
  请在源码里找到至少两个设置了 `PROP_NO_DEG_UPDATE` 的属性定义，
  并解释：为什么这些属性*不应该*触发依赖图重算？如果错误地让它们触发，
  会造成什么后果？（提示：从代价的角度想，而不是从正确性的角度想。）
]
