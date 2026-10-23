#import "../common.typ": *
#import "../figures/dna-rna-pipeline.typ": fig-dna-rna-pipeline
#import "../figures/id-main.typ": fig-id-main

= 第 9 章 数据层：DNA 与 RNA

第 8 章教你怎么找到代码。从本章开始，你要真正改东西了。
而 Blender 里"改东西"最常见的形态，是*给一个数据类型加一个字段*。

这件事看起来很简单：在结构体里加一行，在 `bpy` 里加一个属性。
但它牵动了 Blender 里最精妙的一层设计：

- 这个字段必须能被*逐字节写进 `.blend`*，并且十年后还能被读出来 —— 这是 *DNA*。
- 这个字段必须能被*界面画出来、被 Python 读写、被动画驱动* —— 这是 *RNA*。
- 两者的绑定关系不是手写的，而是*构建期生成*的 —— 这是 `makesdna` 与 `makesrna`。

本章按"数据长什么样 → 怎么存 → 怎么暴露 → 怎么生成 → 怎么管理 → 动手做"的顺序展开。
§9.6 是一个可以跟着做的完整实践：给 `Scene` 加一个能保存进 `.blend`、
能在 `bpy` 里读写的浮点字段，并处理旧文件的迁移。

#note[
  本章会大量出现*以尾下划线结尾*的标识符（`DNA_`、`RNA_`、`ID_` 等）。
  那个下划线是 Blender 的命名约定，不是笔误：`DNA_` 前缀属于 makesdna 那一层
  （磁盘格式定义），`RNA_` 属于 makesrna 的定义 API（如 `RNA_def_*`），
  `ID_` 属于 ID 基类那一层（如 `ID_IS_LINKED`）。
]

== 9.1 DNA：结构体、POD 约定与 ID 基类

=== 9.1.1 定义：DNA 就是"能被保存的类型定义"

#term("DNA", "Data-block Names and Addresses / 序列化结构定义") 指的是
#src("source/blender/makesdna/") 下那一批 `DNA_*.h` 头文件里定义的、
*可以被序列化进 `.blend` 文件的 C++ 结构体*。

它的规模很小但极其关键。目录下共 97 个 `DNA_*.h`，其中
*96 个*会被 `makesdna` 扫描（这份名单写在
#src("source/blender/CMakeLists.txt:5-102") 的 `SRC_DNA_INC` 变量里），
另一个（`DNA_vec_defaults.h`）和四个 `.hh` 工具头归在
`SRC_DNA_OTHER_INC`（同文件 :105-111）里，不参与结构体解析。

DNA 里放的是"数据长什么样"，不是"数据怎么用"：

```c
// source/blender/makesdna/DNA_camera_types.h（节选，示意）
struct Camera {
  ID id;
  char type;
  char dt;
  ...
  float lens;
  float sensor_x;
  ...
};
```

注意三件事：

1. 第一个成员*永远是* `ID id;`（唯一的例外是 `ID` 自己）。
   这就是所谓的 *ID 基类* 模式 —— C 没有继承，于是用"公共头放在最前面"来模拟。
2. 成员类型只有基本类型、指针、数组、嵌套结构体，以及 `ListBaseT<T>` 这样的轻量包装。
3. 没有成员函数（除了极少数 `static constexpr` 常量与 `#ifdef __cplusplus` 里的方法声明）。

=== 9.1.2 为什么这么设计

因为 DNA 结构体的内存会被*原样写进磁盘*，而且*跨版本、跨平台读取*。
这两条要求把能用的语言特性压缩到了极小的一个子集。

#src("source/blender/makesdna/intern/dna_genfile.cc:87-119") 用一段注释
把规则写得非常清楚（这是本节最重要的引用，建议你打开原文读一遍）：

#figure(
  kind: table,
  table(
    columns: (1fr, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*允许并已被测试的改动*], [*不允许的*]),
    [改变成员类型（`char` → `float` 会按 /255 换算）],
    [数组到数学结构体的自动转换（`float vec[3]` → `float3`）],
    [改变成员在结构体中的位置（可以随便重排）],
    [用 `#define` 做数组长度（DNA 解析器读不到）],
    [结构体套结构体（递归任意层）],
    [使用 `uint`（要写 `unsigned int`）],
    [新增成员（旧文件里自动初始化为 0）],
    [在 `.blend` 里额外假设指针宽度固定],
    [删除成员、改变数组长度],
    [——],
    [改变指针*目标类型*但保持名字（内容会被拷贝过去）],
    [——],
  ),
  caption: [
    DNA 结构体的兼容性规则（整理自 #src("source/blender/makesdna/intern/dna_genfile.cc:87-119")）。
    最后一栏是 5.0 之后仍然不支持的能力。
  ],
) <tbl-dna-rules>

图表里有一栏需要单独强调：*对齐*。
注释里给了每个类型的对齐要求（`short` 2 字节、`int`/`float` 4 字节、
`double`/`long`/`int64`/结构体 8 字节），并明确要求
"不要让任何平台在结构体里产生 padding 空洞"。这就是为什么你在 DNA 头文件里
会看到大量手写的 `char _pad[4];` —— 它们不是多余的，是*跨平台布局的填充物*：

```c
// source/blender/makesdna/DNA_ID.h:550-553（节选）
  uint16_t flag = 0;
  uint16_t undo_runtime_tag = 0;
  char _pad[4] = {};
```

没有这一行 `_pad`，`flag` 之后的成员在不同编译器上就会落在不同偏移，
而 `.blend` 是按偏移读的。

关于 C++ 特性，DNA 用的是一套"受控的浅拷贝"机制。
#src("source/blender/makesdna/DNA_defs.h:104-134") 的
`DNA_DEFINE_CXX_METHODS(class_name)` 宏做了这些事：

- 删掉拷贝构造、拷贝赋值、移动构造、移动赋值（因为成员里可能有"拥有权"语义的指针）；
- 保留一个受控的*浅拷贝*构造（用 `dna::shallow_copy(obj)` 触发）；
- 保留一个受控的*清零*构造（用 `dna::shallow_zero_initialize()` 触发）。

#tip[
  这条规则的实际含义是：*DNA 结构体里不要放 `std::string`、`std::vector`、
  `std::unique_ptr` 这类需要构造/析构的成员*。
  它们会让结构体不再是"可以整体 memcpy 的一段内存"，
  而整个 `.blend` 读写、撤销栈、依赖图的 copy-on-evaluation 都依赖这个性质。
  需要字符串就用定长 `char name[N]`，需要变长数组就用 `ListBaseT<T>` 加堆分配。
]

=== 9.1.3 `ID` 基类：所有可保存类型的公共头

`ID` 定义在 #src("source/blender/makesdna/DNA_ID.h:378-493")。
它是整个数据层的 "Object 基类"。逐字段看一遍非常值得：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 5.5pt,
    align: (left, auto, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段*], [*行号*], [*作用*]),
    [`next` / `prev`], [:381], [把 ID 串进 `Main` 的双向链表],
    [`lib`], [:384], [所属的 `Library`；非空即"链接来的"，`ID_IS_LINKED()` 的判据],
    [`name[258]`], [:395], [唯一标识符；*前两字节是类型码*],
    [`flag` / `tag`], [:400-404], [持久化标志（写盘）与运行时标志（不写盘）],
    [`us`], [:405], [引用计数，配合 `ID_REAL_USERS` 等宏使用],
    [`recalc*` 三个字段], [:407-418], [依赖图的失效标记，撤销系统靠它算差异],
    [`session_uid`], [:423], [会话内唯一 ID，跨撤销/重做保持稳定],
    [`properties` / `system_properties`], [:439-447], [用户属性与系统属性（Python 里的 `obj["k"]`）],
    [`override_library`], [:452], [`IDOverrideLibrary *`，override 的入口（见 §9.5）],
    [`orig_id`], [:458], [copy-on-evaluation 生成的求值副本在这里指回原件],
    [`py_instance`], [:474], [缓存对应的 Python 对象，避免重复创建],
    [`runtime`], [:492], [`ID_Runtime *`，纯运行时数据，*绝不写盘*],
  ),
  caption: [
    `struct ID` 的主要成员（完整列表见 #src("source/blender/makesdna/DNA_ID.h:378-493")）。
    还有 `newid`、`asset_data`、`icon_id`、`deep_hash`、`library_weak_reference` 等少量成员未列出。
  ],
) <tbl-id-fields>

有一个细节值得单独讲：`name[258]` 的*前两个字节是类型码*。

```c
// source/blender/makesdna/DNA_ID.h:388-395（节选）
  /**
   * Main identifier for this data-block. Must be unique within the ID name-space ...
   * The first two bytes are always the #ID_Type code of the data-block's type.
   */
  char name[/*MAX_ID_NAME*/ 258] = "";
```

于是有一个"取类型"的宏：

```c
// source/blender/makesdna/DNA_ID.h:684
#define GS(a) (CHECK_TYPE_ANY(a, char *, const char *), (ID_Type)(*((const short *)(a))))
```

`GS(id->name)` 就把名字的前两字节重新解释成 `ID_Type`。
这个技巧让"给定一个 `ID *`，判断它是 Object 还是 Mesh"变成一次指针解引用，
不需要虚函数、不需要 RTTI，也不依赖结构体开头的 `id_type` 成员 ——
因为在 C 里 `ID` 是所有类型的共同前缀，而 `ID` 里没有类型字段。

#pitfall[
  `GS()` 依赖*主机字节序*（`MAKE_ID2` 的注释明确写着
  "NOTE: this is endianness-sensitive."，#src("source/blender/makesdna/DNA_ID_enums.h:116")）。
  这在实践中不是问题（它只在内存里使用，不写盘），
  但如果你自己写工具去解析 `.blend` 的 `BHead.code`，必须自己处理字节序。
]


*`ID` 最常被用到的场合，就是对象指向它的数据。* 回到第 3 章那个“壳与载荷”的说法，
C 侧的 `struct Object` 把这份分工写得很直白
（#src("source/blender/makesdna/DNA_object_types.h:466")）：

```cpp
// source/blender/makesdna/DNA_object_types.h:466（节选）
struct Object {
  ID id;                              // :473  对象自己也是一个 ID
  ObjectType type = OB_EMPTY;         // :477  类型标签：OB_MESH / OB_CURVE / …
  struct Object *parent = nullptr;    // :483  父子关系
  ID *data = nullptr;                 // :496  ← 载荷：指向另一个 ID
  ListBaseT<ModifierData> modifiers;  // :513  修改器栈（在壳上，不在载荷上）
  eObjectMode mode = OB_MODE_OBJECT;  // :520
  float loc[3], scale[3], rot[3];     // :534 起  变换
  …
};
```

关键是 `:496` 那一行的类型：*是 `ID *data`，不是 `Mesh *`*。这就是第 3 章
“任何 ID 都能当对象数据”在 C 侧的样子。RNA 侧给出的是同一个事实
（#src("source/blender/makesrna/intern/rna_object.cc:3001")）：

```cpp
prop = RNA_def_property(srna, "data", PROP_POINTER, PROP_NONE);
RNA_def_property_struct_type(prop, "ID");   // ← 结构类型是 ID，不是 Mesh
RNA_def_property_pointer_funcs(
    prop, "rna_Object_data_get", "rna_Object_data_set", "rna_Object_data_typef", nullptr);
```

注意最后那个参数：`typef` 是一个*类型过滤回调*。它必须存在，因为
“任意 ID”不等于“任意组合都合法”——`ob->type` 才是决定 `ob->data`
该被看成什么类型的那个标签。这份映射写在同文件的一个 switch 里
（#src("source/blender/makesrna/intern/rna_object.cc:583")）：

```cpp
static StructRNA *rna_Object_data_typef(PointerRNA *ptr)
{
  Object *ob = static_cast<Object *>(ptr->data);
  /* keep in sync with OB_DATA_SUPPORT_ID() macro */
  switch (ob->type) {
    case OB_MESH:          return RNA_Mesh;
    case OB_CURVES_LEGACY: return RNA_Curve;
    case OB_SURF:          return RNA_Curve;
    case OB_FONT:          return RNA_Curve;
    case OB_MBALL:         return RNA_MetaBall;
    case OB_LAMP:          return RNA_Light;
    case OB_CAMERA:        return RNA_Camera;
    case OB_LATTICE:       return RNA_Lattice;
    case OB_ARMATURE:      return RNA_Armature;
    case OB_CURVES:        return RNA_Curves;
    case OB_GREASE_PENCIL: return RNA_GreasePencil;
    case OB_POINTCLOUD:    return RNA_PointCloud;
    case OB_VOLUME:        return RNA_Volume;
    …
    default:               return RNA_ID;
  }
}
```

两件事值得停下来看一眼：

1. *这是多对一*。`OB_CURVES_LEGACY`、`OB_SURF`、`OB_FONT` 三种对象类型
   都返回 `RNA_Curve` —— 曲线、曲面、文字共享同一个 `Curve` 数据块类型。
   所以“一种对象类型对应一种数据块类型”是错的。
2. *默认分支返回 `RNA_ID`*。没有专门映射的对象类型，在 Python 侧只能当
   通用 ID 来用——这解释了为什么某些对象的 `.data` 上什么属性都读不到。

那行注释 `keep in sync with OB_DATA_SUPPORT_ID() macro` 指向同一份映射的另一个副本
（#src("source/blender/makesdna/DNA_object_types.h:757")）：C 侧判断
“这种对象类型能不能挂这种 ID”用的是那个宏。两处必须同步，改一处就得改另一处。

C 侧真正取用载荷时，惯用写法是 `id_cast` 而不是裸 `static_cast`
（#src("source/blender/blenkernel/intern/crazyspace.cc:233")）：

```cpp
Mesh *me_input = id_cast<Mesh *>(ob->data);
```

`id_cast` 在 debug 构建里会校验 ID 的实际类型与目标类型是否相符，
所以它比 `static_cast` 更早暴露类型不匹配——这正是“壳与载荷松耦合”之后
必须补上的那层安全检查。

*为什么要把壳和载荷拆开？* 三个原因，按重要性排：

- *几何可以被共享*。一份网格被多个对象引用，既省内存，也让“改一处、处处生效”
  成为默认行为。这是 Blender 做植被、砖墙、粒子这类重复物体的基础。
- *变换和几何解耦*。移动、旋转一个对象只改壳上的 `loc` / `rot`，碰都不碰几何数据。
  这不是省一次拷贝那么简单——它是第 13 章依赖图能把“变换”与“几何”当成
  两个独立组件、进而做局部重算与 copy-on-evaluation 的前提。
- *一个壳可以换载荷*。`ob.data = another_mesh` 就是一句赋值，
  对象的名字、父子关系、修改器栈、集合归属全部保留，不需要销毁重建。

=== 9.1.4 `ID_Type` 枚举与 `id_type` 常量

`ID_Type` 定义在 #src("source/blender/makesdna/DNA_ID_enums.h:132-172")，
每个枚举值由两个字符拼成：

```c
// source/blender/makesdna/DNA_ID_enums.h:117
#define MAKE_ID2(c, d) ((d) << 8 | (c))

// source/blender/makesdna/DNA_ID_enums.h:132-140（节选）
enum ID_Type {
  ID_SCE = MAKE_ID2('S', 'C'),       /* Scene */
  ID_LI = MAKE_ID2('L', 'I'),        /* Library */
  ID_OB = MAKE_ID2('O', 'B'),        /* Object */
  ID_ME = MAKE_ID2('M', 'E'),        /* Mesh */
  ...
};
```

5.2 里一共有 40 个枚举项，另外还有几个"假 ID"用 `#define` 给出
（`ID_SEQ`、`ID_CO` 等，#src("source/blender/makesdna/DNA_ID_enums.h:180-184")）。

从 4.x 开始，每个 DNA 结构体还会带一个编译期常量，用来做类型安全的转换：

```c
// source/blender/makesdna/DNA_screen_types.h:95-99
struct bScreen {
#ifdef __cplusplus
  /** See #ID_Type comment for why this is here. */
  static constexpr ID_Type id_type = ID_SCR;
#endif

  ID id;
  ...
```

这个 `id_type` 是 `static constexpr`，*不占结构体空间*，因此不影响 `.blend` 布局。
它的用途见 `BKE_lib_id.hh` 的模板函数：

```cpp
// source/blender/blenkernel/BKE_lib_id.hh:188-191（节选）
template<typename T> inline T *BKE_id_new(Main *bmain, const char *name)
{
  const short id_type = T::id_type;
  return static_cast<T *>(BKE_id_new(bmain, id_type, name));
}
```

于是 `BKE_id_new<Object>(bmain, "Cube")` 这种写法在编译期就绑定了类型，
写错类型组合会直接报错。`IDTypeInfo` 的注释里也提醒
"These types should also be available on their corresponding DNA struct"
（#src("source/blender/makesdna/DNA_ID_enums.h:125-128")）。

还有一份"遍历顺序"表，也叫索引表：

```c
// source/blender/makesdna/DNA_ID.h:1278-1280（节选）
enum eID_Index {
  /* Special case: Library, should never ever depend on any other type. */
  INDEX_ID_LI = 0,
  ...
#define INDEX_ID_MAX (INDEX_ID_NULL + 1)   // DNA_ID.h:1359
```

`INDEX_ID_*` 决定 `Main` 遍历所有 ID 时的顺序（先是 `Library`，
然后是动画、节点树、文件类、图像类、着色类、object-data 类……）。
*这个顺序不是随意的*：注释里写明"从使用者到被使用者"，
因为很多算法（如 ID 重映射、库链接）依赖这个拓扑序。

=== 9.1.5 怎么用/怎么改

*加一个字段。* 三件事按顺序做：

1. 打开对应的 `DNA_*.h`，在结构体里加成员，*并给它一个默认值*：
   `float my_value = 1.0f;`。默认值不是可选的 ——
   它会被 `makesdna` 抓取并写进生成的 `dna_defaults.cc`，
   成为 RNA 属性的默认值（§9.3.5 详述）。
2. 如果新增成员会破坏对齐，补 `char _pad[N];`。
   判断方法很直接：*构建一次*，如果偏移检查失败，
   `dna_verify.cc` 里的 `BLI_STATIC_ASSERT` 会给出精确的报错。
3. 如果这是一个*新的结构体*，别忘了把它的头文件加进
   #src("source/blender/CMakeLists.txt:5-102") 的 `SRC_DNA_INC`。
   漏掉这一步的症状是链接期找不到 `sdna_struct_id_get<T>()` 的特化，
   报错信息完全不会提到 `SRC_DNA_INC`。

*这些事不要做。* 别删成员（旧文件会读失败），别改数组长度（同上），
别加需要构造/析构的成员，别用 `#define` 当数组长度。
如果确实要废弃一个成员，用 `DNA_DEPRECATED` 标记并保留在结构体里：

```c
// source/blender/makesdna/DNA_screen_types.h:114
  DNA_DEPRECATED struct Scene *scene = nullptr;
```

`DNA_DEPRECATED` 在 `DNA_DEPRECATED_ALLOW` 未定义时展开成
`[[deprecated]]`（#src("source/blender/makesdna/DNA_defs.h:14-23")），
于是任何还在用它的人都会收到编译告警 —— 这就是 Blender 的"软删除"。

还有一个冷知识：*不想让某个结构体进 `.blend`* 时，
在它上面加两行 `#`：

```c
#
#
struct MyInternalStruct {
  int value;
};
```

这是 `makesdna` 的"跳过"语法（#src("source/blender/makesdna/DNA_documentation.h:28-45")，
以及 #src("source/blender/makesdna/intern/dna_genfile.cc:43-44") 的重申）。

=== 9.1.6 常见问题

#pitfall[
  *易错点 1：把 DNA 当普通 C++ 结构体用。*  `DNA_camera_types.h` 里的 `Camera`
  不是你随手 `new`/`delete` 的对象，它由 `BKE_libblock_alloc()` 分配、
  由 `BKE_id_free()` 释放，生命周期由 `Main` 管理（§9.5）。
]

#pitfall[
  *易错点 2：改了 DNA 却不重新构建 `makesdna`。*  `DNA_*.h` 的改动必须让
  再次执行 `makesdna`，重新生成 `dna.cc` 等产物。
  正常用 CMake/Ninja 时会自动处理，但如果你手工拷贝过 `build/` 目录，
  或者用 `ccache` 加手工 `g++` 编译，就可能读到过期的 SDNA，
  症状是"字段明明加了，Python 里读出来却是 0"。
]

#pitfall[
  *易错点 3：以为 `char` 的符号性可以依赖。*  `dna_genfile.cc:107` 明确写着
  "Chars are always unsigned"。写 `char flag;` 却期望它能表示 -1 是错的；
  需要负数请用 `int8_t` 或 `short`。
]

== 9.2 SDNA 与 `.blend` 序列化、跨版本/跨平台兼容、版本迁移

=== 9.2.1 `.blend` 文件的构成

`.blend` 文件的结构非常朴素（#src("doc/blender_file_format/mystery_of_the_blend.html")
是仓库内唯一一份格式说明，描述的是 2.5x 时代，但整体结构至今未变）：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*文件片段*], [*内容*]),
    [文件头], [12 字节：magic `BLENDER`、指针宽度（`_` = 4 字节 / `-` = 8 字节）、字节序、版本号],
    [第一个文件块], [代码为 `DNA1`，其数据就是 `SDNA` 块本身],
    [后续文件块], [每个 `BHead` 带类型码、数据长度、旧内存地址、SDNA 序号、元素个数],
    [图片等大块数据], [`REND` / `TEST` / `GLOB` 等特殊块],
    [文件结尾], [代码为 `ENDB` 的空块],
  ),
  caption: [`.blend` 文件的整体结构],
) <tbl-blend-layout>

关键点在于 *`SDNA` 块被完整地复制在每一个 `.blend` 文件里*。
这也是 `dna_genfile.cc:46-49` 那段注释说的：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-part.lighten(95%),
  stroke: (left: 2.6pt + c-part, rest: 0.4pt + c-part.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  "Structure DNA data is added to each blender file and to each executable,
  this to detect in .blend files new variables in structs, changed array sizes, etc.
  It is also used for converting pointer size (32-64 bits)."
]

翻译过来：*每个 `.blend` 文件自带一份"写它的时候的结构体定义"*。
读文件时，Blender 把文件里的 SDNA 和自己的 SDNA 做比较，
按成员*名字*逐个搬运数据。这就是为什么"加字段、删字段、重排字段、改数组长度"
都能自动兼容 —— 它们都只是"新旧两份成员清单的差异"。

=== 9.2.2 SDNA 块长什么样

SDNA 的二进制布局写在 #src("source/blender/makesdna/intern/dna_genfile.cc:52-75")，
用伪语法描述如下：

```text
SDNA (4 bytes) (magic)
NAME (4 bytes)
<nr> (4 bytes) 名字个数
<string> <string> ...        % 所有成员名的去重列表
TYPE (4 bytes)
<nr> (4 bytes) 类型个数
<string> <string> ...        % 所有类型名
TLEN (4 bytes)
<len> (short) ...            % 每个类型的字节长度
STRC (4 bytes)
<nr> (4 bytes) 结构体个数
<typenr><nr_of_elems> <typenr><namenr> <typenr><namenr> ...
```

读进内存后对应 `struct SDNA`（#src("source/blender/makesdna/DNA_sdna_types.h:52")），
里面有 `types` / `types_size` / `structs` / `members` 等数组，
以及一个很关键的字段：

```c
// source/blender/makesdna/DNA_sdna_types.h:59-60
  /** Size of a pointer in bytes. */
  int pointer_size;
```

`pointer_size` 是"跨平台兼容"的核心：写文件的机器可能是 32 位（4 字节指针），
读文件的机器是 64 位（8 字节指针）。读的时候，SDNA 会知道
"这个成员在文件里只占 4 字节，但在我的结构体里占 8 字节"，
于是按新宽度重新分配并放置。这个转换在 5.0 之前是双向的（还能处理字节序），
而字节序处理在 5.0 被删除了 —— #src("source/blender/makesdna/intern/dna_genfile.cc:742-744")
的注释说明这段代码"很可能多年未被实际使用"。

#note[
  实际结论：*5.x 的 Blender 只处理小端（little-endian）文件*。
  32/64 位指针转换仍然支持，但已有多年没有真实用户走过这条路
  （所有的 Blender 构建都是 64 位）。当你在代码里看到
  `DNA_struct_convert` 之类的老函数名时，别以为它还在承担重要职责。
]

=== 9.2.3 加载时发生了什么：比较与重建

读 `.blend` 时的三个关键函数都在 #src("source/blender/makesdna/intern/dna_genfile.cc")：

1. *解析文件的 SDNA。*  `DNA_sdna_from_data()`
   （:558）把文件里的 SDNA 块解析成 `SDNA` 对象，同时可选地建立
   别名映射（`do_alias` 参数）。启动时自己的 SDNA 由
   `DNA_sdna_current_init()`（:603-606）从生成的字节数组建立：

   ```cpp
   // source/blender/makesdna/intern/dna_genfile.cc:603-606
   void DNA_sdna_current_init()
   {
     g_sdna = DNA_sdna_from_data(DNAstr, DNAlen, false, true, nullptr);
   }
   ```

   `DNAstr` / `DNAlen` 就是 `makesdna` 生成的那个字节块
   （声明在 #src("source/blender/makesdna/DNA_genfile.h:19-21")）。

2. *给每个结构体打比较标记。*  `DNA_struct_get_compareflags()`
   （:706-760）返回一个 `char` 数组，每个元素是
   `SDNA_CMP_EQUAL` / `SDNA_CMP_NOT_EQUAL` / `SDNA_CMP_REMOVED`
   （#src("source/blender/makesdna/DNA_genfile.h:64-71")）。
   相等的结构体可以整体 `memcpy`，不相等的才需要逐成员重建 —— 这是性能关键。

3. *重建。*  `DNA_struct_reconstruct()`（:1246-1276）为新结构体分配
   *清零* 的内存，然后调用 `reconstruct_structs()` 生成一串"重建步骤"：

   ```cpp
   // source/blender/makesdna/intern/dna_genfile.cc:1310-1317（节选）
     const SDNA_StructMember *old_member = find_member_with_matching_name(
         oldsdna, old_struct, new_name, &old_member_offset);
     if (old_member == nullptr) {
       /* No matching member has been found in the old struct. */
       r_step->type = RECONSTRUCT_STEP_INIT_ZERO;
       return;
     }
   ```

   注意 `RECONSTRUCT_STEP_INIT_ZERO` —— *新成员在旧文件里被清零*。
   这正是 §9.6 里"为什么需要版本迁移代码"的根本原因：
   清零 ≠ 你写的默认值。

#summary[
  一句话记住 SDNA 的工作方式：*按成员名字对齐，按新版本的类型宽度重新落地，
  找不到的成员留零*。所有跨版本兼容问题都可以用这句话推导出来。
]

=== 9.2.4 版本迁移（versioning）：清零不够用时

如果你的新字段默认值就是 0（或 `false`、空字符串），
那么"旧文件读进来是 0"恰好就是你要的行为，*不需要写任何迁移代码*。

但如果默认值非零 —— 比如 §9.6 例子里 `book_demo_value` 的默认值是 `1.0f` ——
旧文件读进来会得到 0，语义就错了。这时需要 *versioning 代码*。

Blender 的 versioning 分三个层次：

#figure(
  kind: table,
  table(
    columns: (1.1fr, 1fr, 1fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层次*], [*文件*], [*解决什么问题*]),
    [DNA 层],
    [`blenloader/intern/versioning_dna.cc`],
    [结构体/成员*改名*：让新名字去匹配旧文件里的旧名字],
    [数据层],
    [`versioning_250.cc` … `versioning_520.cc`],
    [字段*内容*需要换算、拆分、合并、补默认值],
    [用户配置层],
    [`versioning_userdef.cc`],
    [`userpref.blend` / `startup.blend` 的迁移],
  ),
  caption: [versioning 的三个层次],
) <tbl-versioning-layers>

*改名*这一类不需要你写新代码，只需要在两个地方登记：
`dna_rename_defs.h`（把 C++ 里的新名字映射成 SDNA 里的旧名字）
和 `versioning_dna.cc`。后者的写法是这样的：

```cpp
// source/blender/blenloader/intern/versioning_dna.cc:22-35（节选）
  if (!DNA_VERSION_ATLEAST(280, 2)) {
    if (versionfile >= 280) {
      DNA_sdna_patch_struct_by_name(sdna, "SceneLayer", "ViewLayer");
      DNA_sdna_patch_struct_member_by_name(
          sdna, "FileGlobal", "cur_render_layer", "cur_view_layer");
      ...
```

`DNA_sdna_patch_struct_member_by_name()` 的语义是
"把 `FileGlobal` 的成员 `cur_view_layer` *在旧文件的记录里*改名成
`cur_render_layer`"（实现在 #src("source/blender/makesdna/intern/dna_genfile.cc:1805")）。
改完之后，重建过程就"认得"旧名字了。

*内容*这一类才是 §9.6 要写的代码，它的骨架极其固定：

```cpp
// source/blender/blenloader/intern/versioning_520.cc:870-881（节选）
  if (!MAIN_VERSION_FILE_ATLEAST(bmain, 502, 40)) {
    for (wmWindowManager &wm : bmain->wm) {
      wm.xr.session_settings.viewfinder_enabled = false;
      ...
    }
  }
```

三个要点：

1. `MAIN_VERSION_FILE_ATLEAST(main, ver, subver)` 定义在
   #src("source/blender/blenkernel/BKE_main.hh:869-871")，判断的是
   *文件*的版本（`main->versionfile` / `main->subversionfile`），不是当前程序的版本。
2. 版本号由 #src("source/blender/blenkernel/BKE_blender_version.h") 给出：

   ```c
   // source/blender/blenkernel/BKE_blender_version.h:23-33
   #define BLENDER_VERSION 502
   #define BLENDER_VERSION_PATCH 2
   ...
   /* Blender file format version. */
   #define BLENDER_FILE_VERSION BLENDER_VERSION
   #define BLENDER_FILE_SUBVERSION 45
   ```

   本次核对基准的文件子版本是 `45`。*每加一段 versioning 代码，
   就要把这个数字 +1*。
3. 函数末尾永远留着一段提醒（#src("source/blender/blenloader/intern/versioning_520.cc:825-829")）：

   ```cpp
   /**
    * Always bump subversion in BKE_blender_version.h when adding versioning
    * code here, and wrap it inside a MAIN_VERSION_FILE_ATLEAST check.
    *
    * \note Keep this message at the bottom of the function.
    */
   ```

每个版本一个文件：`versioning_250.cc` 到 `versioning_520.cc`，
它们在 #src("source/blender/blenloader/intern/readfile.cc:3719-3764") 里
被按顺序调用（`blo_do_versions_pre250` → `blo_do_versions_250` → … → `blo_do_versions_520`），
声明集中在 #src("source/blender/blenloader/intern/readfile.hh:330-345")。
要开新版本时，仓库里有一份现成的模板：
#src("source/blender/blenloader/intern/versioning_xxx_template.cc")，
它的文件头注释写清了四个步骤（复制改名、改函数名、加进 CMakeLists、
在 `readfile.cc`/`readfile.hh` 里加调用）。

*两轮* versioning 需要区分：

- `blo_do_versions_*`：数据块刚读进来、*链接（liblink）之前*，
  只能操作已有的数据，不能创建或删除 ID。
- `do_versions_after_linking_*`：链接之后，
  可以做跨文件的操作（#src("source/blender/blenloader/BLO_readfile.hh:215-224") 有说明）。

#warn[
  在 *release 分支*（比如本书的 #raw(blender-branch)）上加 versioning
  是违反上游流程的：release 分支的文件格式已经冻结。
  上游的做法是在下一个开发周期的 `versioning_530.cc` 里加。
  §9.6 为了让你能在手头的分支上成功复现，演示的是"直接改 `versioning_520.cc`
  并把自己的子版本号 +1"——这在本地构建里完全有效，
  但如果你要提交给上游，请先读第 17 章的贡献流程。
]

=== 9.2.5 跨平台：真正需要担心的是什么

跨版本兼容由 SDNA 自动处理，跨平台则要看具体是哪一种差异：

- *指针宽度（4 vs 8 字节）*：影响。由 `SDNA.pointer_size`
  （#src("source/blender/makesdna/DNA_sdna_types.h:59-60")）记录，
  读取时按新宽度重排。
- *结构体对齐与 padding*：影响。靠 DNA 里手工写的 `_pad` 成员保证，
  并由 `dna_verify.cc` 的静态断言兜底。
- *`long` 的宽度*：影响。所以 Blender 只在"需要指针那么宽"的场合用 `long`
  （#src("source/blender/makesdna/intern/dna_genfile.cc:105-106")），
  需要确定宽度请用 `int64_t` / `uint64_t`。
- *字节序*：理论上影响，实际上已不再支持大端。
  #src("source/blender/makesdna/intern/dna_genfile.cc:742-744") 的注释说明
  这段转换代码"很可能多年未被实际使用"，并在 5.0 被删除。
- *浮点格式*：不影响，全部是 IEEE 754。
- *行尾与文本编码*：不影响。`.blend` 是二进制文件，
  路径按 UTF-8 字节串存取。

`dna_verify.cc` 是这一层的保险丝。它由 `makesdna` 生成
（#src("source/blender/makesdna/intern/makesdna.cc:759-799")），
内容是一大串静态断言：

```cpp
// 生成的 dna_verify.cc 片段（示意，见 makesdna.cc:785-798）
BLI_STATIC_ASSERT(offsetof(struct Camera, lens) == 296, "DNA member offset verify");
BLI_STATIC_ASSERT(sizeof(struct Camera) == 432, "DNA struct size verify");
```

只要你改动 DNA 导致某个平台的布局和预期不符，
*构建时*就会失败，而不是等到用户打开文件时才发现数据错位。
这是 Blender 数据层最值得学习的一个设计。

=== 9.2.6 常见问题

#pitfall[
  *易错点 1：以为新增字段会自动拿到"默认值"。*  不会。旧文件里是*零*。
  这是本节最重要的一条。测试方法很直接：
  用老版本建一个场景、保存，用你的构建打开，
  然后 `print(bpy.context.scene.book_demo_value)` —— 看到的是 0.0。
]

#pitfall[
  *易错点 2：在 versioning 里创建 ID。*  `blo_do_versions_*` 阶段
  `Main` 还没完成链接，`BKE_id_new()` 出来的 ID 不会被正确处理。
  需要创建 ID 就放到 `do_versions_after_linking_*` 里。
]

#pitfall[
  *易错点 3：忘了 bump `BLENDER_FILE_SUBVERSION`。*  不 bump 的后果很隐蔽：
  你的迁移代码会用 `!MAIN_VERSION_FILE_ATLEAST(bmain, 502, 46)` 判断，
  但当前文件版本也是 46，于是*新写的文件再打开时又被迁移一次*。
  如果迁移不是幂等的（比如"加 1"），数据就会越用越错。
]

== 9.3 RNA：`RNA_def_*` 与字段映射

=== 9.3.1 定义：RNA 是 DNA 的"自省层"

DNA 只描述内存布局，它不知道：
"这个字段该不该显示在界面上"、"它的取值是 0..1 还是 0..100"、
"改它之后要通知谁"、"在 Python 里它叫什么"。

#term("RNA", "RNA / Blender 的属性系统") 就是这层元数据。
它把 DNA 结构体包装成一套*可自省的类型系统*，让同一份描述同时服务于：

- 界面绘制（`uiItemR()` 之类只需要一个 RNA 指针）；
- Python 绑定（`bpy.types.Camera.lens`）；
- 动画系统（F-Curve 用 RNA 路径寻址：`camera.lens`）；
- 库覆盖（override 按 RNA 路径记录差异，见 §9.5）；
- 文件读写（序列化时按 RNA 属性把非 DNA 数据也带上）。

`RNA_define.hh` 开头那段注释把 DNA 校验机制讲得很清楚
（#src("source/blender/makesrna/RNA_define.hh:44-57")）：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-tip.lighten(95%),
  stroke: (left: 2.6pt + c-tip, rest: 0.4pt + c-tip.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  "Tell the RNA maker to check whether the property exists in the matching DNA structure.
  When in DNA, RNA generates automatically the accessors code.
  Otherwise, you have to give it explicit getters/setters/etc."
]

也就是说：*如果 RNA 属性绑定到了 DNA，访问器代码是自动生成的*；
绑不上，你就必须自己写 get/set 函数。

=== 9.3.2 三层结构体

RNA 的运行时对象只有三种（#src("source/blender/makesrna/RNA_types.hh")）：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 6pt,
    align: (left, auto, left),
    stroke: 0.4pt + luma(78%),
    table.header([*运行时类型*], [*声明行号*], [*对应到 Python*]),
    [`StructRNA`], [:1025], [`bpy.types.Object` 这个类本身],
    [`PropertyRNA`], [:858], [类上的属性描述符（`Object.location`）],
    [`FunctionRNA`], [:970], [类上的方法（`Object.select_set`）],
    [`BlenderRNA`], [:1032], [所有 `StructRNA` 的根容器],
  ),
  caption: [RNA 的四个核心结构体（#src("source/blender/makesrna/RNA_types.hh")）],
) <tbl-rna-types>

界面和脚本看到的是它们的*结果*；你写代码时接触的是定义它们的宏与函数。
115 个 `rna_*` 文件（108 个 `.cc` + 7 个 `.hh`）里一共有
50,278 次 `RNA_def_` 开头的调用，用到 269 个不同的 `RNA_def_*` 名字。
其中最常用的几个类别：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数族*], [*作用*]),
    [`RNA_def_struct(blender_rna, "id", "父类型")`],
    [定义一个 RNA 类型；父类型为 `nullptr` 表示它是根类型],
    [`RNA_def_property(srna, "id", PROP_FLOAT, PROP_NONE)`],
    [定义一个属性（第四个参数是显示子类型，如 `PROP_DISTANCE`）],
    [`RNA_def_property_float_sdna(prop, nullptr, "lens")`],
    [把属性绑定到 DNA 成员（见 §9.3.4）],
    [`RNA_def_property_range` / `_ui_range`],
    [硬范围（会被强制裁剪）与界面软范围],
    [`RNA_def_property_ui_text(prop, "Lens", "Focal length...")`],
    [界面标签与鼠标悬停提示（也就是你在@fig-source-tree 反查时用的搜索键）],
    [`RNA_def_property_update(prop, NC_OBJECT, "rna_Object_update")`],
    [属性改变后发出的通知（通知类型 + 回调）],
    [`RNA_def_property_float_funcs(prop, get, set, nullptr)`],
    [当无法绑定 DNA 时，手写访问器],
    [`RNA_def_struct_ui_text` / `_ui_icon`],
    [类型的显示名与图标],
  ),
  caption: [`RNA_def_*` 里最常用的几类（完整清单见 #src("source/blender/makesrna/RNA_define.hh")）],
) <tbl-rna-def-families>

=== 9.3.3 一个真实的 RNA 定义长什么样

看 `SpaceView3D` 的开头（#src("source/blender/makesrna/intern/rna_space.cc:5650-5676")）：

```cpp
  srna = RNA_def_struct(brna, "SpaceView3D", "Space");
  RNA_def_struct_sdna(srna, "View3D");
  RNA_def_struct_ui_text(srna, "3D View Space", "3D View space data");
  ...
  prop = RNA_def_property(srna, "use_render_border", PROP_BOOLEAN, PROP_NONE);
  RNA_def_property_boolean_sdna(prop, nullptr, "flag2", V3D_RENDER_BORDER);
  RNA_def_property_clear_flag(prop, PROP_ANIMATABLE);
  RNA_def_property_ui_text(prop, "Render Region",
                           "Use a region within the frame size for rendered viewport ...");
  RNA_def_property_update(prop, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
```

三个名字在这里出现了分叉，必须分清：

#figure(
  kind: table,
  table(
    columns: (auto, auto, auto),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*RNA 类型名*], [*DNA 结构体名*], [*怎么指定*]),
    [`Space`], [`SpaceLink`], [`RNA_def_struct_sdna(srna, "SpaceLink")`（:4129）],
    [`SpaceView3D`], [`View3D`], [`RNA_def_struct_sdna(srna, "View3D")`（:5651）],
    [`Scene`], [`Scene`], [*不用写* —— 名字相同，自动绑定],
    [`Object`], [`Object`], [*不用写*],
    [`bScreen` 相关的 `Screen`], [`bScreen`], [靠名字修补表（见下）],
  ),
  caption: [RNA 类型名与 DNA 结构体名的三种关系],
) <tbl-rna-dna-names>

"不写也行"的秘密在 `RNA_def_struct()` 的末尾：

```cpp
// source/blender/makesrna/intern/rna_define.cc:872-882（节选）
#ifndef RNA_RUNTIME
  StructDefRNA *ds = MEM_new<StructDefRNA>("StructDefRNA");
  ds->srna = srna;
  rna_addtail(&DefRNA.structs, ds);
  ...
  /* in preprocess, try to find sdna */
  RNA_def_struct_sdna(srna, srna->identifier);
#endif
```

也就是说：*每个 RNA 结构体默认用它的标识符去找同名的 DNA 结构体*。
第 882 行这一句是自动绑定，显式调用 `RNA_def_struct_sdna()` 是覆盖它。

少数名字对不上的情况有一张补丁表：

```cpp
// source/blender/makesrna/intern/makesrna.cc:2696-2706（节选）
    if (!ds->dnaname.is_empty()) {
      if (ds->dnaname == "Screen") {
        ds->dnaname = "bScreen";
      }
      if (ds->dnaname == "Group") {
        ds->dnaname = "Collection";
      }
      ...
```

`Group` → `Collection` 这类映射是历史遗留：2.x 时代的 `Group` 在 2.8 改名成
`Collection`，而 Python 侧的名字也一起改了，只有旧 `.blend` 里还留着老名字。

=== 9.3.4 字段映射：`RNA_def_*_sdna` 家族

这是本章最需要动手掌握的一节。绑定 DNA 有*两种*触发方式。

*方式一：自动。*  `RNA_def_property()` 在结尾处会自动尝试绑定：

```cpp
// source/blender/makesrna/intern/rna_define.cc:1337-1353（节选）
  switch (type) {
    case PROP_BOOLEAN:
      DefRNA.silent = true;
      RNA_def_property_boolean_sdna(prop, nullptr, identifier, 0);
      DefRNA.silent = false;
      break;
    ...
    case PROP_FLOAT: {
      DefRNA.silent = true;
      RNA_def_property_float_sdna(prop, nullptr, identifier);
      DefRNA.silent = false;
      break;
    }
```

注意 `DefRNA.silent = true` —— *失败不报错*。
所以"属性名字恰好和 DNA 成员同名"时，绑定是静默完成的，
你在源码里看不到任何 `_sdna` 调用。
这解释了上一章里那个疑问：`rna_scene.cc:9113` 的
`simulation_frame_start` 没有 `_sdna` 调用，却能读写 DNA。

*方式二：显式。*  当自动绑定不成立时，调用
`RNA_def_property_*_sdna()` 覆盖它。必须显式指定的情形有五种：

#figure(
  kind: table,
  table(
    columns: (1.05fr, 1.5fr, 1.15fr),
    inset: 5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*情形*], [*写法*], [*例子*]),
    [RNA 名 ≠ DNA 名],
    [`RNA_def_property_float_sdna(prop, nullptr, "dna_name")`],
    [`RenderEngine` 的多数属性],
    [布尔映射到某个整型的某一位],
    [`RNA_def_property_boolean_sdna(prop, nullptr, "flag2", V3D_RENDER_BORDER)`],
    [#src("source/blender/makesrna/intern/rna_space.cc:5670")],
    [布尔映射到某一位且取反],
    [`RNA_def_property_boolean_negative_sdna(...)`],
    [#src("source/blender/makesrna/RNA_define.hh:391")],
    [映射到嵌套成员路径],
    [`RNA_def_property_float_sdna(prop, nullptr, "render_border.xmin")`],
    [#src("source/blender/makesrna/intern/rna_space.cc:5679")],
    [映射到"派生结构体"的成员],
    [`RNA_def_struct_sdna_from(srna, "bChildOfConstraint", "data")`],
    [#src("source/blender/makesrna/intern/rna_constraint.cc:1098")],
  ),
  caption: [必须显式写 `_sdna` 的五种情形],
) <tbl-sdna-cases>

五种情形里，"映射到嵌套成员路径"最值得细看，因为它的语法很特殊。
`RNA_def_property_sdna()` 支持的路径语法是 `.` 和 `->`：

```cpp
// source/blender/makesrna/intern/rna_define.cc:330（函数注释）
/** Find DNA type info, recursively following `.` and `->`. */
static bool rna_find_sdna_member(const StringRef structname,
                                 const StringRef path,
                                 PropertyDefRNA *r_dp = nullptr,
                                 const void *base_default_data = nullptr)
```

于是 `render_border.xmin` 会被解析成"先找到 `render_border` 成员，
再在里面找 `xmin`"（#src("source/blender/makesrna/intern/rna_define.cc:342-380")）。
指针成员用 `->`，例如 `mask_info.mask`（同文件 `rna_space.cc:4173`）。

"派生结构体"（`sdna_from`）解决的是 C 里的"伪继承"问题。
看约束的例子：`bChildOfConstraint` 结构体里有一个 `bConstraint data;`，
RNA 类型 `ChildOfConstraint` 的父类型是 `Constraint`（对应 `bConstraint`），
但它自己的属性要落在 `bChildOfConstraint` 上。`RNA_def_struct_sdna_from()` 就是
"我的 DNA 结构体是 X，但我挂在一个 Y 类型的对象上，Y 里指向我的字段叫 Z"。
生成访问器时会多一层解引用：

```cpp
// source/blender/makesrna/intern/makesrna.cc:330-345（节选）
static void rna_print_data_get(FILE *f, PropertyDefRNA *dp)
{
  if (!dp->dnastructfromname.is_empty() && !dp->dnastructfromprop.is_empty()) {
    fprintf(f,
            "    %s *data = (%s *)(((%s *)ptr->data)->%s);\n",
            dp->dnastructname.c_str(), dp->dnastructname.c_str(),
            dp->dnastructfromname.c_str(), dp->dnastructfromprop.c_str());
  }
  ...
```

*绑定失败时会发生什么？*  `rna_def_property_sdna()` 会报错并置
`DefRNA.error`（#src("source/blender/makesrna/intern/rna_define.cc:2279-2285")）：

```cpp
    CLOG_ERROR(&LOG,
               "\"%s.%s\" (identifier \"%s\") not found. Struct must be in DNA.",
               structname, propname, prop->identifier);
    DefRNA.error = true;
```

`makesrna` 最终会以失败退出，构建中断。错误信息里给了结构体名和成员名 ——
照着它去 `DNA_*.h` 里核对，通常一眼就能看出是拼写错了还是结构体写错了。

如果你*故意*要定义一个不在 DNA 里的 RNA 类型
（例如纯运行时类型、或者某个 Python 侧特有的包装类型），
用 `RNA_define_verify_sdna(false)` 关掉校验，用完再开回来：

```cpp
// source/blender/makesrna/intern/rna_render.cc:862
  RNA_define_verify_sdna(false);
```

全库有 58 处这样的调用（`git grep -c RNA_define_verify_sdna`）。
`RenderEngine`（#src("source/blender/makesrna/intern/rna_render.cc:540")）
就是一个典型：它是 Python 侧实现的渲染引擎基类，没有任何 DNA 对应物。

=== 9.3.5 默认值是哪里来的

这在 5.x 有一个*非常优雅*的机制，值得单独讲。

你在 DNA 里写的默认成员初始化值，会被 `makesdna` 抓出来。
它生成的 `dna_defaults.cc`（#src("source/blender/makesdna/intern/makesdna.cc:709-757")）
长这样（示意）：

```cpp
/* Default struct member values for RNA. */
static const Scene DNA_DEFAULT_Scene = {};
static const void *const member_defaults_Scene[] = {
  &DNA_DEFAULT_Scene.id,
  &DNA_DEFAULT_Scene.r,
  ...
  &DNA_DEFAULT_Scene.book_demo_value,
};
extern const void *const *const DNA_member_default_table[] = {
  member_defaults_Scene,
  ...
};
```

`static const Scene DNA_DEFAULT_Scene = {};` 这一行含义很关键：
它*调用 C++ 的默认构造函数*，于是你在 `DNA_scene_types.h` 里写的
`float book_demo_value = 1.0f;` 就生效了。
然后 `makesrna` 通过这张指针表读出每个成员的默认值：

```cpp
// source/blender/makesrna/intern/rna_define.cc:313-328（节选）
static const void *rna_default_data(const int struct_idx,
                                    const int member_idx,
                                    const void *base_default_data)
{
  const void *member_default_data = DNA_member_default_table[struct_idx][member_idx];
  ...
```

浮点属性最终在 `RNA_def_property_float_sdna()` 里被用上：

```cpp
// source/blender/makesrna/intern/rna_define.cc:2686-2691（节选）
    else if (dp->dnatype == "float") {
      fprop->defaultvalue = *(const float *)dp->dnadefaultdata;
    }
```

#tip[
  这张表的头文件 #src("source/blender/makesrna/intern/rna_defaults.hh") 只有 20 行，
  注释写得很清楚："This table is defined in the auto generated dna_defaults.cc,
  and populated using the C++ default member initializers of each DNA struct."
  这是 5.x 相对 4.x 的一个重要改进 —— 以前默认值要在 RNA 里
  用 `RNA_def_property_float_default()` 再写一遍，两处容易不一致。
]

那"新建一个 Scene"时默认值是怎么进的？看 `scene_init_data()`：

```cpp
// source/blender/blenkernel/intern/scene.cc:165-172（节选）
static void scene_init_data(ID *id)
{
  Scene *scene = id_cast<Scene *>(id);
  ...
  INIT_DEFAULT_STRUCT_AFTER(scene, id);
```

`INIT_DEFAULT_STRUCT_AFTER` 定义在
#src("source/blender/blenlib/BLI_utildefines.h:424-429")：

```cpp
#define INIT_DEFAULT_STRUCT_AFTER(struct_dst, member) \
  { \
    const typename std::remove_reference<decltype(*(struct_dst))>::type struct_src; \
    BLI_assert(MEMCMP_STRUCT_AFTER_IS_ZERO_OR_EQUAL(struct_dst, &struct_src, member)); \
    MEMCPY_STRUCT_AFTER(struct_dst, &struct_src, member); \
  }
```

读法：*造一个默认构造的临时对象，然后把它（除了 `id` 成员以外的部分）
整块 memcpy 到新分配的数据块上。*
那一句 `BLI_assert` 保证被覆盖的区域原本是零或已经是默认值 ——
这既是一道安全检查，也提醒你"数据块分配出来时就是零"。

#pitfall[
  *易错点：把默认值只写在 RNA 里。*  如果你用 `RNA_def_property_float_default(prop, 2.0f)`
  覆盖了默认值，那么*只有 RNA 层*是 2.0，C++ 侧新建的数据块仍是 DNA 里的默认值。
  两处不一致时，`bpy` 里新建对象和 C++ 里 `BKE_id_new` 出来的对象会有不同初值。
  5.x 的正确做法是*把默认值写在 DNA 的成员初始化里*，
  让两处自然一致。
]

=== 9.3.6 常见问题

#pitfall[
  *易错点 1：以为不写 `_sdna` 就是没绑定。*  见 §9.3.4。
  判断某个 RNA 属性到底绑定到哪个 DNA 成员，
  最可靠的办法是*构建后去看生成的 `rna_*_gen.cc`*，
  里面直接写着 `offsetof(View3D, flag2)`。
]

#pitfall[
  *易错点 2：`PROP_EDITABLE` 忘了加。*  RNA 属性默认是只读的。
  想让它能在 Python 里赋值，除了要有 set 访问器，还要
  `RNA_def_property_flag(prop, PROP_EDITABLE)`。
  症状是 `AttributeError: Attribute 'xxx' is read-only`。
]

#pitfall[
  *易错点 3：加了 `_sdna` 却没加 `RNA_def_property_update`。*  
  属性改动能写进 DNA，但界面不刷新、依赖图不重建。
  你会在"改了属性但视口没反应"上浪费很多时间。
]

== 9.4 代码生成链路：`makesdna` → SDNA → `makesrna` → `*_gen.cc` → `bpy`

=== 9.4.1 全景图

这一节把前面三节串成一条流水线。

#figure(fig-dna-rna-pipeline(), caption: [DNA → SDNA → RNA → `bpy` 代码生成管线]) <fig-dna-rna-pipeline>

图里最重要的信息不是"有哪些步骤"，而是*两条线共用同一批输入*：

- `makesdna` 读 `DNA_*.h`，产出 SDNA 字节块与几个辅助文件；
- `makesrna` *也*读同一批 `DNA_*.h`（不读 SDNA 的二进制，而是重新解析头文件），
  再加上 115 个 `rna_*` 文件，产出 `rna_*_gen.cc`。

为什么 `makesrna` 不直接读 SDNA？因为要*校验*。
如果它读 SDNA，那么"RNA 绑定的成员在 DNA 里存不存在"就永远为真，
检查不出任何错误。

=== 9.4.2 `makesdna` 侧

入口是 `make_structDNA()`（#src("source/blender/makesdna/intern/makesdna.cc:863-919")），
流程只有六步：

```cpp
// source/blender/makesdna/intern/makesdna.cc:876-914（节选）
  Vector<dna::ParsedStruct> parsed_structs;
  Vector<dna::ParsedEnum> parsed_enums;

  if (!dna::parse_dna_headers(base_directory, parsed_structs, parsed_enums, includefiles)) {
    return false;
  }

  /* Write default values for RNA before any substitution or renaming ... */
  write_rna_defaults(file_defaults, base_directory, parsed_structs);

  /* Substitute C++ types with C types known to SDNA. */
  if (!dna::substitute_cpp_types(parsed_structs, parsed_enums, false)) { return false; }

  /* Apply renames from `dna_rename_defs.h`. */
  if (!apply_renames(parsed_structs)) { return false; }

  TypeTable table = build_type_table(parsed_structs);
  if (compute_type_size_and_alignment(table, parsed_structs)) { return false; }

  write_sdna_blob(file, table, parsed_structs);
  write_sdna_type_offsets(file_offsets, parsed_structs);
  write_sdna_struct_ids(file_ids, parsed_structs);
  write_sdna_verify(file_verify, table, parsed_structs, base_directory);
```

五个产物，各自的用途：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*产物*], [*用途*]),
    [`dna.cc`], [SDNA 字节块本体，编译成 `DNAstr` / `DNAlen` 全局数组],
    [`dna_type_offsets.h`], [每个结构体的 SDNA 序号枚举（`_SDNA_TYPE_Scene` 等）],
    [`dna_struct_ids.cc`], [`dna::sdna_struct_id_get<T>()` 的模板特化，供 `write_struct<T>()` 用],
    [`dna_defaults.cc`], [RNA 属性的默认值表（§9.3.5）],
    [`dna_verify.cc`], [`offsetof` / `sizeof` 静态断言，保证布局符合预期],
  ),
  caption: [`makesdna` 的五个产物],
) <tbl-makesdna-outputs>

这些文件写在*构建目录*里，位置由 CMake 规则决定
（#src("source/blender/makesdna/intern/CMakeLists.txt:100-117")）：

```text
<build>/source/blender/makesdna/intern/
├── dna.cc
├── dna_defaults.cc
├── dna_struct_ids.cc
├── dna_type_offsets.h
├── dna_verify.cc
├── dna_includes_all.h            # 由 CMake 生成，列出所有 DNA 头
└── dna_includes_as_strings.h     # 同上，作为字符串列表
```

`makesdna` 的命令行接口很朴素（#src("source/blender/makesdna/intern/makesdna.cc:941-948")）：

```text
Usage: makesdna [--include-file <file>, ...] dna.cc dna_type_offsets.h \
       dna_verify.cc dna_struct_ids.cc dna_defaults.cc [base directory]
```

五个位置参数就是五个产物，最后可选地给一个"头文件所在的基础目录"。

=== 9.4.3 `makesrna` 侧

`makesrna` 的入口在 #src("source/blender/makesrna/intern/makesrna.cc:4391-4429")，
它先解析 DNA 头文件，再进入 `rna_preprocess()`：

```cpp
// source/blender/makesrna/intern/makesrna.cc:4410-4424（节选）
    const char *dna_header_path = argv[1];
    Vector<dna::ParsedEnum> enums;
    if (!(dna::parse_dna_headers(
              dna_header_path, DefRNA.dna_structs, enums, dna::default_dna_header_filenames()) &&
          dna::substitute_cpp_types(DefRNA.dna_structs, enums, true)))
    {
      fprintf(stderr, "Fatal!\n");
      CLOG_FATAL(&LOG, "Failed to parse DNA headers for RNA registration");
    }
    ...
    return_status = rna_preprocess(argv[2], (argc > 2) ? argv[3] : nullptr);
```

调用方式是三个目录参数
（#src("source/blender/makesrna/intern/CMakeLists.txt:422-428") 给出）：

```text
makesrna <源码里的 makesdna 目录> <构建输出目录> <公开头文件输出目录>
```

产物命名规则写在 `rna_preprocess()` 里（#src("source/blender/makesrna/intern/makesrna.cc:4340-4348")）：

```cpp
    const bool is_cc = BLI_str_endswith(PROCESS_ITEMS[i].filename, ".cc");
    const int ext_len = is_cc ? 3 : 2;
    const int filename_len = strlen(PROCESS_ITEMS[i].filename);
    SNPRINTF(deffile, "%s%.*s%s" TMP_EXT,
             outfile,
             (filename_len - ext_len), PROCESS_ITEMS[i].filename,
             is_cc ? "_gen.cc" : "_gen.c");
```

即：`rna_space.cc` → `rna_space_gen.cc`，`rna_prototypes_gen.hh` 与 `RNA_prototypes.hh`
是两个额外的头文件。输出位置：

```text
<build>/source/blender/makesrna/intern/
├── rna_space_gen.cc                # 每个 rna_*.cc 一个
├── rna_object_gen.cc
├── ...                             # 共 77 个条目
└── rna_prototypes_gen.hh

<build>/source/blender/makesrna/
└── RNA_prototypes.hh                # 对外公开的原型头
```

`PROCESS_ITEMS[]`（#src("source/blender/makesrna/intern/makesrna.cc:4019-4100")）
里有 77 个条目，每个条目形如：

```cpp
    {"rna_texture.cc", "rna_texture_api.cc", RNA_def_texture},
```

三个字段分别是：定义文件、可选的 API 文件、以及那个负责往
`BlenderRNA` 里注册所有类型的函数。生成的 `_gen.cc` 就是一个
"把两个 include 拼起来 + 生成所有访问器"的翻译单元：

```cpp
// 生成的 rna_space_gen.cc 开头（示意，模板见 makesrna.cc:4107-4145）
/* Automatically generated struct definitions for the Data API.
 * Do not edit manually, changes will be overwritten.           */
#include <float.h>
#include <stdio.h>
...
#include "DNA_scene_types.h"
#include "RNA_define.hh"
#include "RNA_prototypes.hh"
#include "rna_prototypes_gen.hh"
#include "rna_space.cc"
```

#pitfall[
  *不要试图编辑生成物。*  `dna.cc`、`rna_*_gen.cc` 都在构建目录里，
  每次构建都会被覆盖，而且它们带有
  "Do not edit manually, changes will be overwritten." 的头注释。
  想看它们是为了*理解*，不是为了改。
]

=== 9.4.4 `bpy` 侧：`StructRNA` 怎么变成 Python 类

这一步和大多数人想的不一样：*`bpy.types` 里的类不是一次性全部创建的，
而是"用到才建"*。

入口是 `BPY_rna_types()`（#src("source/blender/python/intern/bpy_rna.cc:9068-9097")），
它创建一个 `bpy.types` 子模块对象，并注册几个内部基类
（`bpy_struct`、`bpy_prop`、`bpy_prop_collection` 等）：

```cpp
// source/blender/python/intern/bpy_rna.cc:9078-9093（节选）
  {
    static PyTypeObject *pyrna_types[] = {
        &pyrna_struct_meta_idprop_Type,
        &pyrna_struct_Type,
        &pyrna_prop_Type,
        &pyrna_prop_array_Type,
        &pyrna_prop_collection_Type,
        &pyrna_prop_collection_idprop_Type,
        &pyrna_func_Type,
    };
```

这个模块被挂到 `bpy` 上（#src("source/blender/python/intern/bpy_interface.cc:285")）：

```cpp
  PyModule_AddObject(mod, "types", BPY_rna_types()); /* This does not need updating. */
```

真正的"从 RNA 类型造 Python 类"发生在 `pyrna_srna_Subtype()`
（#src("source/blender/python/intern/bpy_rna.cc:8496-8511")），逻辑是三段式：

```cpp
  /* Stupid/simple case. */
  if (srna == nullptr) {
    newclass = nullptr; /* Nothing to do. */
  } /* The class may have already been declared & allocated. */
  else if ((newclass = static_cast<PyObject *>(RNA_struct_py_type_get(srna)))) {
    Py_INCREF(newclass);
  } /* Check if `_bpy_types.py` module has the class defined in it. */
  else if ((newclass = pyrna_srna_ExternalType(srna))) {
    pyrna_subtype_set_rna(newclass, srna);
    Py_INCREF(newclass);
  } /* Create a new class instance with the C API ... */
  else {
    ...用 PyType_Type 现造一个...
  }
```

三段式对应三种来源，这个设计很值得记住：

1. *已经造过* —— `RNA_struct_py_type_get(srna)` 里有缓存（存在
   `StructRNA::py_type`，也就是 `ID.py_instance` 注释里提到的机制，
   见 #src("source/blender/makesdna/DNA_ID.h:498-513")）。
2. *Python 脚本里定义了子类* —— 检查
   #src("scripts/modules/_bpy_types.py")，例如
   `class Object(bpy_types.ID)` 就定义在那里。
3. *都没有* —— 用 C API 现造一个 `bpy.types.Xxx` 类，
   父类由 RNA 的继承关系决定。

`BPY_rna_types_finalize_external_types()`（同文件 :9099-9150）负责把
`_bpy_types.py` 里的类和 RNA 类型对上号，并且对"下划线开头的名字"特殊处理：

```cpp
// source/blender/python/intern/bpy_rna.cc:9118-9125（节选）
    const char *key_str = PyUnicode_AsUTF8(arg_key);
    if (key_str[0] == '_') {
      continue;
    }
    BLI_assert_msg(
        PyObject_IsSubclass(arg_value, (PyObject *)&pyrna_struct_Type),
        "Members of _bpy_types.py which are not StructRNA sub-classes must use a \"_\" prefix!");
```

#tip[
  这段逻辑解释了一个常见困惑："为什么 `bpy.types` 里有些类在
  `_bpy_types.py` 里能找到、有些找不到？"
  能定义在 Python 侧的只是*需要额外 Python 行为*的那些
  （`Object`、`Collection`、`NodeTree` 等）；纯数据类
  （`Camera`、`Mesh` 的多数子类型）由 C API 现造，所以不在脚本里。
]

=== 9.4.5 构建顺序与增量行为

CMake 用两条 `add_custom_command` 把这些串起来
（#src("source/blender/makesdna/intern/CMakeLists.txt:100-117") 与
#src("source/blender/makesrna/intern/CMakeLists.txt:422-428")）：

```cmake
# makesdna 的产物声明
add_custom_command(
  OUTPUT
    ${CMAKE_CURRENT_BINARY_DIR}/dna.cc
    ${CMAKE_CURRENT_BINARY_DIR}/dna_defaults.cc
    ${CMAKE_CURRENT_BINARY_DIR}/dna_struct_ids.cc
    ${CMAKE_CURRENT_BINARY_DIR}/dna_type_offsets.h
    ${CMAKE_CURRENT_BINARY_DIR}/dna_verify.cc
  COMMAND ... "$<TARGET_FILE:makesdna>" ... ${CMAKE_SOURCE_DIR}/source/blender/makesdna/
  DEPENDS makesdna
)
```

依赖链是：`DNA_*.h` 变化 → 再次执行 `makesdna` → 重新生成 5 个产物
→ `bf_dna` 重新编译 → 再次执行 `makesrna`（它依赖 `bf_dna_defaults`，
见 #src("source/blender/makesrna/intern/CMakeLists.txt:413")）
→ `rna_*_gen.cc` 重新生成 → `bf_rna` 重新编译。

*这条链比你想的长*：改一个 `DNA_*.h` 里的一个字段，
会触发 `makesrna` 再次执行并重写*几乎全部* `_gen.cc`。
所以第一次改 DNA 后的增量构建会慢很多，这是正常的。

对应的经验规则：

#figure(
  kind: table,
  table(
    columns: (1fr, 1fr, auto),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*你改了什么*], [*会重新生成什么*], [*构建时间*]),
    [`rna_object.cc` 里的一个属性], [只有 `rna_object_gen.cc`], [短],
    [`DNA_object_types.h` 里的一个字段],
    [5 个 dna 产物 + 几乎全部 `rna_*_gen.cc`],
    [长（几分钟到十几分钟）],
    [新增一个 `DNA_foo_types.h`], [同上，外加 `dna.c` 的 `#include` 列表], [长],
    [新增一个 `rna_foo.cc`],
    [`rna_foo_gen.cc` 与原型头，*且必须同时改 CMakeLists.txt*],
    [中],
  ),
  caption: [改动类型与构建代价],
) <tbl-build-cost>

#pitfall[
  *新增 `rna_*.cc` 时必须改两处。*  一是
  #src("source/blender/makesrna/intern/CMakeLists.txt:25-102") 的 `DEFSRC`
  列表（决定哪些 `_gen.cc` 被编译），二是
  #src("source/blender/makesrna/intern/makesrna.cc:4019-4100") 的 `PROCESS_ITEMS`
  数组（决定生成哪些 `_gen.cc`）。只改一处的话，
  要么文件被生成但没被编译，要么被编译但根本没生成。
]

=== 9.4.6 常见问题

#pitfall[
  *易错点 1：改了 DNA 但 `makesrna` 没有再次执行。*  症状是 Python 侧看不到新字段，
  但 C++ 侧编译通过。原因几乎总是 `DEPENDS` 没被触发 ——
  例如你手工改了构建目录里的 `dna.cc`，
  或者用了 `ccache` 加上不完整的构建缓存。
  处理办法：删掉 `<build>/source/blender/makesdna/intern/` 与
  `<build>/source/blender/makesrna/intern/` 下的生成文件，重新构建。
]

#pitfall[
  *易错点 2：以为 `bpy.types.X` 是 Python 类所以能改。*  
  它们是由 C API 现造的静态类型；`setattr` 只能加 `bpy.props` 定义的属性，
  不能改已有属性的行为。
]

#pitfall[
  *易错点 3：在生成物里找 bug。*  `rna_object_gen.cc` 里出现的怪代码
  （比如 `offsetof`、`RawPropertyType`）是生成器写的，
  真正要改的是 `rna_object.cc` 或 `makesrna.cc`。
]

== 9.5 `Main` 数据库与 ID 生命周期、库链接（Library）、override 概览

=== 9.5.1 `Main`：一个 `.blend` 文件在内存里的样子

#term("Main", "Main 数据库") 定义在
#src("source/blender/blenkernel/BKE_main.hh:239")。
它*不是* DNA 结构体（不写进 `.blend`），而是一个运行时容器。

#figure(fig-id-main(), caption: [Main 数据库、ID 引用关系、库链接与 override]) <fig-id-main>

`Main` 里最关键的部分是那几十个 `ListBaseT<T>`：

```cpp
// source/blender/blenkernel/BKE_main.hh:367-398（节选）
  ListBaseT<Scene> scenes = {};
  ListBaseT<Library> libraries = {};
  ListBaseT<Object> objects = {};
  ListBaseT<Mesh> meshes = {};
  ListBaseT<Curve> curves = {};
  ...
```

#term("ID", "数据块 / data-block") 是这些链表里的元素。
*Blender 里所有"有名字、能保存、有引用计数"的东西都是 ID*：
Object、Mesh、Material、Scene、Collection、Image、Action、NodeTree、
World、Brush、Library……

`Main` 的设计要点：

1. *按类型分链表，而不是一张大表。*  好处是按类型遍历是 O(该类型数量)，
   坏处是"遍历所有 ID"需要一张索引表 —— 这就是
   `MainListsArray` 与 `BKE_main_lists_get()`：

   ```cpp
   // source/blender/blenkernel/BKE_main.hh:762-773（节选）
   using MainListsArray = std::array<ListBaseT<ID> *, INDEX_ID_MAX - 1>;

   /**
    * Returns the pointers to all the #ListBaseT structs in given `bmain`.
    * ...
    * \note The order of each ID type #ListBaseT in the array is determined by the
    * `INDEX_ID_<IDTYPE>` enum definitions in `DNA_ID.h`.
    */
   MainListsArray BKE_main_lists_get(Main &bmain);
   ```

2. *链表按名字排序。*  注释里写着"Within a same type, IDs are iterated based on
   their libraries (local IDs always iterated first) and names (alphanumeric sorting)"
   （#src("source/blender/blenkernel/BKE_main.hh:780-783")）。
   这让"按名字找 ID"可以二分，也让界面里的列表天然有序。

3. *遍历有两条路。*  老的宏：

   ```c
   // source/blender/blenkernel/BKE_main.hh:694-698（节选）
   #define FOREACH_MAIN_ID_BEGIN(_bmain, _id) \
     { \
       ListBaseT<ID> *_lb; \
       FOREACH_MAIN_LISTBASE_BEGIN ((_bmain), _lb) { \
         FOREACH_MAIN_LISTBASE_ID_BEGIN (_lb, (_id))
   ```

   新的迭代器（支持 `std::ranges`）：

   ```cpp
   // source/blender/blenkernel/BKE_main.hh:791-799（节选）
   class MainAllIDsIterator {
    public:
     using iterator_category = std::bidirectional_iterator_tag;
     using value_type = ID;
     ...
   ```

   实际用法就是 §9.2.4 里见过的 `for (ID &id : MainAllIDsIterator{*bmain})`。

#warn[
  `FOREACH_MAIN_ID_BEGIN` 的注释里有一条重要警告：
  "DO NOT use break statement with that macro, use `FOREACH_MAIN_LISTBASE` and
  `FOREACH_MAIN_LISTBASE_ID` instead if you need that kind of control flow."
  （#src("source/blender/blenkernel/BKE_main.hh:692-693")）
  因为它展开成两层嵌套循环，`break` 只会跳出内层。
  用 `MainAllIDsIterator` 就没这个问题。
]

=== 9.5.2 ID 的生命周期

一个 ID 的一生是：*创建 → 使用（引用计数）→ 释放*。

#figure(
  kind: table,
  table(
    columns: (auto, 1.5fr, 1.5fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*阶段*], [*API*], [*做什么*]),
    [创建], [`BKE_libblock_alloc()`], [分配内存、挂进对应链表、初始化 `ID` 公共头],
    [创建 + 初始化], [`BKE_id_new<T>()`], [再调用该类型的 `init_data` 回调（§9.5.3）],
    [创建（游离）], [`BKE_id_new_nomain()`], [临时数据块，用于求值/计算，不写盘],
    [复制], [`BKE_id_copy()` / `BKE_libblock_copy()`], [调用类型的 `copy_data` 回调做深拷贝],
    [引用], [`id_us_plus()` 与各种 `set` 函数], [增加 `ID.us`；多数 API 会自动处理],
    [释放], [`BKE_id_free()`], [只释放数据，调用者已确定没人用了],
    [删除], [`BKE_id_delete()`], [先做 ID 重映射（清掉别处对它的引用），再释放],
    [改名], [`BKE_id_new_name_validate()`], [保证名字在 `Main` 内唯一，冲突时加 `.001` 后缀],
  ),
  caption: [
    ID 生命周期中的主要 API。以上函数都声明在
    #src("source/blender/blenkernel/BKE_lib_id.hh")：`BKE_libblock_alloc` 见 :120、
    `BKE_id_new<T>` 见 :188、`BKE_id_new_nomain` 见 :219、`BKE_libblock_copy` 见 :352、
    `BKE_id_free` 见 :580、`BKE_id_delete` 见 :612、`BKE_id_new_name_validate` 见 :885。
  ],
) <tbl-id-lifecycle>

引用计数有几个宏必须认识（都在 #src("source/blender/makesdna/DNA_ID.h:639-669")）：

```c
#define ID_FAKE_USERS(id) ((id_cast<const ID *>(id)->flag & ID_FLAG_FAKEUSER) ? 1 : 0)
#define ID_REAL_USERS(id) (id_cast<const ID *>(id)->us - ID_FAKE_USERS(id))
#define ID_REFCOUNTING_USERS(id) (ID_REAL_USERS(id) - ID_EXTRA_REAL_USERS(id))
```

#term("Fake User", "伪用户") 是 Blender 的一个用户可见概念：
给 ID 打上 `ID_FLAG_FAKEUSER`，它就不会因为"没人引用"而被清理。
界面上的"盾牌"图标就是它。宏的作用是把"伪用户"从计数里剔除，
让你能区分"真的有人用"和"只是被标记为保留"。

#pitfall[
  *易错点：`ID.us == 0` 不代表可以立刻删除。*  Blender 的 ID 删除要经过
  "孤儿数据清理"流程（`BKE_id_delete` 加 ID 重映射），
  直接 `MEM_freeN(id)` 会留下悬空指针。
  所有 ID 的释放都必须经过 `BKE_id_free*` 家族。
]

=== 9.5.3 `IDTypeInfo`：每种 ID 的"虚函数表"

C 没有虚函数，所以每种 ID 类型提供一个回调集合 `IDTypeInfo`
（#src("source/blender/blenkernel/BKE_idtype.hh")）。它的字段分三类：

- *标识*：`id_code`（就是 `ID_Type`）、`id_filter`（文件浏览器过滤用）、
  `main_listbase_index`（在 `INDEX_ID_*` 里的序号）、`struct_size`、`name`。
- *生命周期回调*：`init_data`、`copy_data`、`free_data`、`make_local`、
  `foreach_id`、`foreach_cache`、`foreach_path`。
- *文件读写回调*：`blend_write`、`blend_read_data`、
  `blend_read_after_liblink`、`blend_read_undo_preserve`、
  `lib_override_apply_post`。

以 `Scene` 为例（#src("source/blender/blenkernel/intern/scene.cc:1610-1644")）：
`id_code = Scene::id_type`、`main_listbase_index = INDEX_ID_SCE`、
`struct_size = sizeof(Scene)`、`init_data = scene_init_data`、
`copy_data = scene_copy_data`、`free_data = scene_free_data`、
`blend_write = scene_blend_write`、`blend_read_data = scene_blend_read_data`。

这些实例被集中注册进一张表（#src("source/blender/blenkernel/intern/idtype.cc:46")）：

```cpp
// source/blender/blenkernel/intern/idtype.cc:130-137（节选）
#define INIT_TYPE(_id_code) \
  { \
    BLI_assert(IDType_##_id_code.main_listbase_index == INDEX_##_id_code); \
    BLI_assert(id_type_is_valid(IDType_##_id_code)); \
    id_types[INDEX_##_id_code] = &IDType_##_id_code; \
    init_types_num++; \
  } \
  (void)0
```

注意那个 `BLI_assert(id_type_is_valid(...))`：在 Debug 构建里，
*每个回调都必须被显式赋值*，包括"没有实现"的情况也要写成 `nullptr`。
`id_type_is_valid()` 会检查每个字段是否还停留在 `InvalidPointer()` 哨兵值
（#src("source/blender/blenkernel/intern/idtype.cc:48-127")）。
这是一个很实用的约定：*它逼你明确回答"这个回调我实现了没有"*，
而不是靠默认值蒙混过去。

`foreach_id` 尤其重要：它告诉 Blender"这个 ID 引用了哪些其他 ID"，
库链接、ID 重映射、依赖图都靠它建图。

=== 9.5.4 库链接（Library）

#term("库链接", "Library linking") 指的是把另一个 `.blend` 文件里的数据
*引用*到当前文件里来（`File > Link`）。

核心只有两个字段：

- `ID.lib`（#src("source/blender/makesdna/DNA_ID.h:415")）指向它所属的 `Library`；
- `Library.filepath[1024]`（#src("source/blender/makesdna/DNA_ID.h:547")）指向磁盘上的文件。

判断函数就是一组宏（#src("source/blender/makesdna/DNA_ID.h:682-721")）：

```c
#define ID_IS_LINKED(_id) (id_cast<const ID *>(_id)->lib != NULL)
#define ID_IS_PACKED(_id) (ID_IS_LINKED(_id) && ((_id)->flag & ID_FLAG_LINKED_AND_PACKED))
#define ID_IS_OVERRIDABLE_LIBRARY(_id) \
  (ID_IS_OVERRIDABLE_LIBRARY_HIERARCHY((_id)) && \
   (id_cast<const ID *>(_id)->tag & ID_TAG_EXTERN) != 0)
```

链接数据的基本规则：

- *链接数据是只读的。*  想改就得先 `make local`，这会创建一份本地副本并断开 `lib` 指针。
- *`.blend` 里只存引用，不存数据。*  所以打开一个链接了别的文件的工程时，
  那个被链接的文件必须还在原路径上（或者被 pack 进来）。
- *`Library` 本身也是一个 ID*（`ID_LI`，#src("source/blender/makesdna/DNA_ID_enums.h:134")），
  它挂在 `Main.libraries` 上。这就是 `INDEX_ID_LI = 0` 的含义 ——
  Library 必须最先遍历，因为其他 ID 都依赖它。

链接的实现主要在 #src("source/blender/blenloader/") 与
#src("source/blender/blenkernel/intern/library.cc")，
相关 API 声明在 #src("source/blender/blenkernel/BKE_library.hh")
（例如 `BKE_library_filepath_set()`，:141）。

#note[
  库链接还有一个"隐藏假设"值得知道：被链接的 ID 在库文件里的*名字*
  就是它在本文件里的身份。所以如果你在库里把 `Material` 改名，
  所有链接它的工程都会"找不到"那个数据块（显示为 missing）。
  这也解释了为什么 `ID_MISSING()` 这个宏存在
  （#src("source/blender/makesdna/DNA_ID.h:680")）。
]

=== 9.5.5 override 概览

#term("库覆盖", "Library override / override") 是"链接但可改"的机制。
它是 Blender 2.8 引入的、用于替代旧的 proxy 系统的方案。

数据结构只有一个（#src("source/blender/makesdna/DNA_ID.h:341-358")）：

```c
struct IDOverrideLibrary {
  /** Reference linked ID which this one overrides. */
  struct ID *reference = nullptr;
  ListBaseT<IDOverrideLibraryProperty> properties = {nullptr, nullptr};

  /** Override hierarchy root ID. Usually the actual root of the hierarchy ... */
  struct ID *hierarchy_root = nullptr;

  IDOverrideLibraryRuntime *runtime = nullptr;
  eID_OverrideLib_Flag flag = {};
  char _pad_1[4] = {};
};
```

工作方式：*本文件里的 ID 与库里的原件一一对应，逐属性记录"被改过"的差异*。
差异项的路径就是 RNA 路径：

```c
// source/blender/makesdna/DNA_ID.h:313-326（节选）
struct IDOverrideLibraryProperty {
  struct IDOverrideLibraryProperty *next = nullptr, *prev = nullptr;

  /**
   * Path from ID to overridden property.
   * *Does not* include indices/names for final arrays/collections items.
   */
  char *rna_path = nullptr;

  ListBaseT<IDOverrideLibraryPropertyOperation> operations = {nullptr, nullptr};
  ...
```

注意 `rna_path` 的类型是 `char *`。这意味着：

*override 是建立在 RNA 之上的机制*。一个字段如果没被 RNA 暴露，
就无法被 override。这是"RNA 是唯一的数据访问层"这一设计的一个直接后果，
也是你在加新字段时应该顺便想一下"它要不要可被 override"的原因
（RNA 定义里加 `RNA_def_property_override_flag(prop, PROPOVERRIDE_OVERRIDABLE_LIBRARY)`）。

常用的判断宏与 API：

- 判断：`ID_IS_OVERRIDE_LIBRARY_REAL()`（:713，有 `override_library` 且
  `reference` 非空）、`ID_IS_OVERRIDE_LIBRARY_VIRTUAL()`（:717，
  嵌入式数据被 override）、`ID_IS_OVERRIDE_LIBRARY()`（:720，前两者取或）、
  `ID_IS_OVERRIDE_LIBRARY_HIERARCHY_ROOT()`（:723）。
- 操作（都在 #src("source/blender/blenkernel/BKE_lib_override.hh")）：
  `BKE_lib_override_library_create()`（:240）从链接的 ID 创建 override；
  `..._resync()`（:316）与库中的原件重新同步；
  `..._make_local()`（:370）彻底转为本地数据；
  `..._delete()`（:358）删除整个层级。

三条经验规则：

1. *override 的最小单位是"属性"，不是"数据块"。*  所以你可以在
   一个被 override 的 Object 上只改位置，其余属性继续跟随库更新。
2. *层级（hierarchy）很重要。*  一个角色 collection 被 override 时，
   它下面的 object、material 会被自动纳入同一个层级，
   `hierarchy_root` 指向层级根。resync 是按层级做的。
3. *resync 可能失败并保留你的修改。*  当库里的原件被删除时，
   override 会变成"孤儿"但不立即消失（见 `eID_OverrideLib_Flag` 的定义，
   #src("source/blender/makesdna/DNA_ID.h:297-309")）。

#warn[
  本节对 override 只做"够用"级别的介绍。真正的 override 实现有
  上万行代码，涉及 ID 重映射、层级重建、属性 diff 算法。
  如果你要做 override 相关的修改，请先读
  #src("source/blender/blenkernel/BKE_lib_override.hh") 里的完整注释 ——
  它是整个仓库里注释密度最高的文件之一，每段都能省你半天时间。
]

=== 9.5.6 常见问题

#pitfall[
  *易错点 1：把 `Main` 当全局变量。*  确实有一个全局 `G.main`，
  但大多数函数都接收一个 `Main *bmain` 参数。
  *在新代码里请一律用参数传递的 `bmain`* ——
  全局变量在后台渲染、库链接等场景下指向的可能是"另一个 Main"。
]

#pitfall[
  *易错点 2：遍历 `Main` 时删 ID。*  `FOREACH_MAIN_ID_BEGIN` 在迭代中
  删除/新增元素会导致未定义行为。正确做法是把要删的 ID 收集到一个
  `Vector` 里，遍历结束后统一处理。
]

#pitfall[
  *易错点 3：忘记 `foreach_id`。*  新加一种"引用别的 ID 的指针字段"时，
  必须在对应类型的 `foreach_id` 回调里登记它。
  漏掉的后果非常隐蔽：普通使用没问题，但库链接/复制/重映射时
  引用计数不对，表现为"数据莫名消失"或"崩溃在别处"。
]

== 9.6 实践：给一个数据类型加一个可保存字段

这是本章的动手部分。我们要做的功能很小 ——
*给 `Scene` 加一个能保存进 `.blend`、能在 `bpy` 里读写的浮点字段* ——
但要走完 DNA → 构建 → RNA → `bpy` → 版本迁移的完整链路。

字段名用 `book_demo_value`（*教学示例的命名*，真实项目请换成有意义的
小写加下划线名字，并遵循 §8.2 的代码风格）。

=== 9.6.1 目标与验收标准

做之前先把验收标准写清楚，这能省掉来回调试：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*编号*], [*验收条件*]),
    [V1], [`Scene` 结构体里有一个 `float book_demo_value`，默认值 `1.0f`],
    [V2], [`makesdna` / `makesrna` 重新生成成功，`dna_verify.cc` 的静态断言通过],
    [V3], [`python -c "import bpy; print(bpy.types.Scene.book_demo_value)"` 能打印出属性描述],
    [V4], [`bpy.context.scene.book_demo_value = 3.5` 之后保存、重开，值仍是 3.5],
    [V5], [用一个 5.2.2 官方版本保存的旧 `.blend` 打开后，值是 `1.0f`（而不是 0.0）],
  ),
  caption: [本实践的验收标准],
) <tbl-practice-acceptance>

V5 是唯一需要*额外写代码*的一条，也是大多数人第一次做时最容易漏的。

=== 9.6.2 第 1 步：改 DNA

打开 #src("source/blender/makesdna/DNA_scene_types.h")，
找到 `struct Scene`（:2797 开始，到 :2932 结束），
在 `simulation_frame_end`（:2915）之后、`SceneDisplay display`（:2917）之前
插入一行：

```c
  /**
   * 教学示例：一个可保存进 .blend 的浮点字段。
   *
   * 这里的默认值 1.0f 不是装饰 —— makesdna 会把它抓取到生成的
   * `dna_defaults.cc` 里，成为 RNA 属性的默认值（见 §9.3.5）。
   */
  float book_demo_value = 1.0f;
```

*为什么插在这里？*  有两个理由，一个是硬的，一个是软的。

软理由是"可读性"：放在相关字段附近，diff 也小。

硬理由是*对齐*。`float` 要求 4 字节对齐。它前面的 `simulation_frame_end`
是 `int`（4 字节，位于偏移 4 的整数倍上），所以紧跟其后的 `float`
天然满足 4 字节对齐，*不会引入任何 padding*。
如果你把它插在一串 `char` 或 `short` 后面，就可能需要手工补 `_pad`。

#tip[
  不确定的时候有个笨办法：先插进去，构建一次。
  如果布局不合法，生成的 `dna_verify.cc` 里的
  `BLI_STATIC_ASSERT(offsetof(struct Scene, ...) == N, ...)`
  会精确地告诉你哪个成员的偏移不对。
  这比手工算偏移快得多，也更不容易错。
]

=== 9.6.3 第 2 步：重建，观察生成物

现在构建一次。用第 2 章建立的构建目录：

```bash
$ cmake --build ../build_windows --target blender
```

或者直接用 Ninja：

```bash
$ cd ../build_windows && ninja
```

构建开始后，`makesdna` 会再次执行。你可以趁这个机会去看生成物
（注意 `<build>` 换成你自己的构建目录）：

#win #h(0.4em) 下用 PowerShell 列出这些产物：

```powershell
> Get-ChildItem <build>\source\blender\makesdna\intern\ | Select-Object Name
```

#linux #h(0.4em) 与 #mac #h(0.4em) 下看到的是同一批文件：

```bash
$ ls <build>/source/blender/makesdna/intern/
dna.cc  dna_defaults.cc  dna_struct_ids.cc  dna_type_offsets.h  dna_verify.cc ...
```

在 `dna_defaults.cc` 里搜索 `book_demo_value`，你应该能看到
它被登记进了 `member_defaults_Scene[]` 数组。
在 `dna_verify.cc` 里搜索 `book_demo_value`，你应该能看到：

```cpp
BLI_STATIC_ASSERT(offsetof(struct Scene, book_demo_value) == <某个4的倍数>, "DNA member offset verify");
```

*这就是 V2 的证据。*  如果这一行报错，说明布局不对，
回去检查是不是需要 `_pad`。

#pitfall[
  如果构建报出 `dna_verify.cc` 的静态断言失败，*不要*直接改
  `dna_verify.cc` —— 它是生成物。要改的是 `DNA_scene_types.h`。
]

=== 9.6.4 第 3 步：加 RNA

打开 #src("source/blender/makesrna/intern/rna_scene.cc")，
找到 `RNA_def_scene()`（:8826 开始），在 `Scene` 结构体定义里
（`srna = RNA_def_struct(brna, "Scene", "ID");` 在 :8888）
的末尾找一个位置插入：

```cpp
  /* 教学示例：把 Scene.book_demo_value 暴露给 Python。 */
  prop = RNA_def_property(srna, "book_demo_value", PROP_FLOAT, PROP_NONE);
  RNA_def_property_float_sdna(prop, nullptr, "book_demo_value");
  RNA_def_property_range(prop, 0.0f, 10.0f);
  RNA_def_property_ui_text(prop, "Demo Value",
                           "教学示例字段：能被保存、能被 Python 读写");
  RNA_def_property_update(prop, NC_SCENE, "rna_Scene_set_update");
```

逐行解释：

- 第 1 行：定义 RNA 属性，类型 `PROP_FLOAT`，子类型 `PROP_NONE`
  （如果它表示距离，应该用 `PROP_DISTANCE`，界面会自动带单位）。
- 第 2 行：*显式绑定 DNA*。这里其实可以不写 ——
  RNA 标识符 `book_demo_value` 与 DNA 成员同名，`RNA_def_property()`
  的自动绑定（§9.3.4）已经能成功。但*显式写出更安全*：
  以后有人把 RNA 名字改成 `demo_value`，如果没有这一行就会静默失去绑定
  （自动绑定失败不报错！）；有这一行则会立刻在 `makesrna` 阶段报错。
  第一个参数 `nullptr` 表示"用当前结构体的 DNA 名"，
  也就是 `RNA_def_struct(brna, "Scene", ...)` 自动推出的 `"Scene"`。
- 第 3 行：硬范围。`bpy` 里赋值超出范围会被裁剪。
- 第 4 行：界面文字与悬停提示。这是第 8 章"界面反查"的搜索键，
  别留空。
- 第 5 行：属性变化时发出 `NC_SCENE` 通知，
  并调用 `rna_Scene_set_update`。前者让依赖图标记该场景需要更新，
  后者让界面刷新。*这一行忘了，你会看到"值改了但界面不变"。*

#pitfall[
  如果你的字段是布尔型，绑定要写
  `RNA_def_property_boolean_sdna(prop, nullptr, "flag", MY_BIT)`
  —— 第四个参数是*位掩码*，不是值。
  写错了不会报错，但读写会表现得很奇怪（一次改一堆位）。
]

=== 9.6.5 第 4 步：让 `bpy` 可见并验证

再构建一次（这次 `makesrna` 会再次执行并重新生成 `rna_scene_gen.cc`），
然后启动 Blender，在脚本控制台里验证：

```python
import bpy

# V3：属性存在吗？
print(bpy.types.Scene.book_demo_value)
print(bpy.types.Scene.bl_rna.properties["book_demo_value"].description)

# 看默认值是怎么来的
print(bpy.types.Scene.bl_rna.properties["book_demo_value"].default)   # 期望 1.0

# V4：新建一个场景，看默认值；再改值
scene = bpy.data.scenes.new("DemoScene")
print(scene.book_demo_value)          # 期望 1.0（来自 DNA 的默认成员初始化）

scene.book_demo_value = 3.5
print(scene.book_demo_value)          # 3.5

# 越界会被硬范围裁剪
scene.book_demo_value = 999.0
print(scene.book_demo_value)          # 期望 10.0

# 保存再打开，验证能落盘
bpy.ops.wm.save_as_mainfile(filepath="//demo_save_test.blend")
bpy.ops.wm.open_mainfile(filepath="//demo_save_test.blend")
print(bpy.data.scenes["DemoScene"].book_demo_value)   # 期望 3.5（注意上面被裁到 10 之前的值）
```

还可以从 C++ 侧的角度确认绑定是否正确：
打开 `<build>/source/blender/makesrna/intern/rna_scene_gen.cc`，
搜索 `book_demo_value`，你会看到生成出来的访问器里有
`offsetof(Scene, book_demo_value)` —— *这就是"绑定成功"的铁证*。

#tip[
  如果 `bpy.types.Scene.book_demo_value` 报 `AttributeError`，
  按这个顺序排查：
  (1) `rna_scene_gen.cc` 里有没有 `book_demo_value`？没有说明
  `RNA_def_property` 那几行没被编译进去，检查插入位置是否在
  `RNA_def_scene()` 函数体内。
  (2) 有的话，检查 `makesrna` 是否报过错（构建日志里搜 `rna.define`）。
  (3) 再检查你运行的 Blender 是不是刚构建出来的那个
  （`bin/blender --version` 对比 commit）。
]

=== 9.6.6 第 5 步：版本迁移（V5）

现在处理最容易被忽略的一条：*用旧版本保存的 `.blend` 里，
`book_demo_value` 会是 0.0，而不是我们想要的 1.0*。

原因在 §9.2.3 已经说过：重建时找不到的成员走
`RECONSTRUCT_STEP_INIT_ZERO`，得到的是零，不是 DNA 里的默认值。
`INIT_DEFAULT_STRUCT_AFTER` 只在*新建*数据块时生效。

所以需要一段 versioning 代码。三步：

*第一步：把文件子版本号 +1。*

```c
// source/blender/blenkernel/BKE_blender_version.h:33
#define BLENDER_FILE_SUBVERSION 45
```

改成 `46`。

*第二步：在老文件上补默认值。*
打开 #src("source/blender/blenloader/intern/versioning_520.cc")，
在 `blo_do_versions_520()` 的末尾，
也就是那段 "Always bump subversion" 注释（:916-921）*之前*插入：

```cpp
  /* 教学示例：`Scene.book_demo_value` 在 5.2.46 之前不存在，
   * 旧文件读进来会是 0.0，这里补上语义上的默认值。 */
  if (!MAIN_VERSION_FILE_ATLEAST(bmain, 502, 46)) {
    for (Scene &scene : bmain->scenes) {
      scene.book_demo_value = 1.0f;
    }
  }
```

三个要点：

1. `!MAIN_VERSION_FILE_ATLEAST(bmain, 502, 46)` 判断的是*文件*的子版本。
   所有 5.2.45 及更早的文件（包括官方 5.2.2 发布的）都会命中。
2. `for (Scene &scene : bmain->scenes)` 是 5.x 的推荐写法 ——
   `ListBaseT<T>` 支持 range-for（#src("source/blender/makesdna/DNA_listBase.h:100-109")），
   比 `FOREACH_MAIN_ID_BEGIN` 之类的宏安全得多。
3. 这段代码必须放在 `blo_do_versions_520()` 内、注释之前 ——
   那行注释是"这是函数结尾"的标记。

*第三步：确认头文件都被包含。*
`versioning_520.cc` 已经包含了
`DNA_scene_types.h`（:21）和 `BKE_main.hh`（:41），
`MAIN_VERSION_FILE_ATLEAST` 来自后者，所以不需要加 `#include`。
如果你换一个字段所在的类型，记得补上对应的 `DNA_*.h`。

构建后重新验证 V5：用官方 5.2.2 保存一个场景，用你的构建打开，
`print(bpy.context.scene.book_demo_value)` 应该显示 `1.0`。

#warn[
  按上游流程，release 分支不该加 versioning（文件格式已冻结）。
  这里为了让你能在手头的 #raw(blender-branch) 上成功复现才这么写。
  真正的上游提交应该落在下一个开发周期的
  `versioning_530.cc` 里（照
  #src("source/blender/blenloader/intern/versioning_xxx_template.cc") 的四步走）。
]

=== 9.6.7 第 6 步：如果只想要"不改文件格式的字段"

有时候你需要的是一个*不改变 DNA 文件格式*的字段。
这时有三条路，按推荐的优先级排列：

1. *纯 Python 属性。*  如果你的需求能在插件里解决，用
   `bpy.types.Scene.my_prop = bpy.props.FloatProperty()`。
   它会被存进 `.blend` 的 IDProperty 里（因为 IDProperty 是 DNA 的一部分），
   完全不用改 C++。
2. *`ID_Runtime` 里的运行时字段。*  `ID.runtime` 指向
   `bke::id::ID_Runtime`（#src("source/blender/makesdna/DNA_ID.h:533")），
   它*明确不写盘、不进撤销栈*（注释见同文件 :523-532）。
   适合放缓存、指针、临时状态。
3. *DNA 里的字段 + 不写盘。*  这条最难，也最容易做错：
   你得在对应类型的 `blend_write` 回调里跳过它，
   或者在读的时候重算。*不推荐*，除非你有明确理由。

#pitfall[
  *易错点：把运行时状态放进 DNA。*  最常见的形式是往 DNA 里加函数指针、
  缓存指针、或者"只在本会话有意义"的计数。
  症状是保存再打开后行为异常，或者撤销/重做后崩溃 ——
  因为撤销栈也是靠 DNA 快照实现的。
  记住那条分界：*`ID.runtime` 明确不写盘；DNA 字段默认属于持久化数据*。
  即使某个类型的写入回调可以特殊处理，也不要把 DNA 当作一般的运行时存储。
]

=== 9.6.8 回滚清单

如果做实验做到一半想撤销，按这个顺序回退：

1. `source/blender/makesdna/DNA_scene_types.h`：删掉 `book_demo_value` 那一行。
2. `source/blender/makesrna/intern/rna_scene.cc`：删掉那 6 行 RNA 定义。
3. `source/blender/blenloader/intern/versioning_520.cc`：删掉那个 `if` 块。
4. `source/blender/blenkernel/BKE_blender_version.h`：把
   `BLENDER_FILE_SUBVERSION` 改回 `45`。
5. *删掉构建目录里生成的旧文件*，然后重新构建：

```bash
$ rm -rf <build>/source/blender/makesdna/intern/dna*.cc \
         <build>/source/blender/makesdna/intern/dna*.h \
         <build>/source/blender/makesrna/intern/rna_*_gen.cc \
         <build>/source/blender/makesrna/intern/rna_prototypes_gen.hh \
         <build>/source/blender/makesrna/RNA_prototypes.hh
$ cmake --build <build> --target blender
```

第 5 步很重要：*生成物不会因为你删了源码而自动消失*。
如果不清理，`makesrna` 可能因为时间戳判断而跳过重新生成，
你会看到"源码已经删了但 Python 里还有这个属性"的诡异现象。

#summary[
  回顾一下这个字段走过了哪些地方：
  `DNA_scene_types.h`（定义 + 默认值）→ `makesdna`（SDNA + 默认值表 + 布局断言）
  → `dna.cc` / `dna_defaults.cc` / `dna_verify.cc`
  → `rna_scene.cc`（RNA 定义 + 绑定 + 单位 + 通知）
  → `makesrna`（校验 DNA 成员存在，生成访问器）
  → `rna_scene_gen.cc` → `bf_rna` → `bpy.types.Scene.book_demo_value`
  → 以及为旧文件准备的 `versioning_520.cc` + 子版本号 +1。
  *这就是"给一个数据类型加字段"的全部成本。*  理解了这条链，
  后面第 10–15 章的每一章你都会轻松很多。
]

#exercise[
  *练习 9.1（跟着做，1–2 小时）。*  完整实现 §9.6 的 `book_demo_value`，
  逐条通过 V1–V5。每一步都记录 `file:line`。

  *练习 9.2（换一个类型，1 小时）。*  把同样的流程用在 `Object` 上：
  在 #src("source/blender/makesdna/DNA_object_types.h") 的
  `struct Object`（:466 开始）里加一个
  `float book_demo_object_value = 0.5f;`，在
  #src("source/blender/makesrna/intern/rna_object.cc") 里暴露它，
  并在 `versioning_520.cc` 里补默认值。
  注意 `Object` 的属性在 `blender` 命名空间里（`namespace blender`），
  写 versioning 时用 `for (Object &ob : bmain->objects)`。

  *练习 9.3（读懂生成物，45 分钟）。*  构建完成后，打开
  `<build>/source/blender/makesrna/intern/rna_object_gen.cc`，
  找 `hide_viewport` 这个属性的 get/set 函数，
  说明它是如何用 `offsetof` 访问 DNA 的。
  再找 `dna_verify.cc` 里 `struct Object` 的那几行断言。

  *练习 9.4（逆向工程一个不存在的绑定，45 分钟）。*  随便挑一个
  `bpy` 属性（例如 `scene.frame_step`），用 §8.3.3 的数据反查法
  找出它的 DNA 成员、RNA 定义位置、以及它是否有显式 `_sdna` 调用。
  如果答案是"没有显式调用"，解释为什么。

  *练习 9.5（加一个枚举字段，1.5 小时）。*  给 `Scene` 加一个枚举字段：
  DNA 里用 `int book_demo_mode = 0;`，RNA 侧定义
  `EnumPropertyItem` 数组并用 `RNA_def_property_enum_items()` 绑定。
  注意枚举在 DNA 里是整数，在 RNA 里是 `PROP_ENUM`，
  两者的对应关系靠 `RNA_def_property_enum_sdna()` 与
  `RNA_def_property_enum_items()` 建立。做完后思考：
  *为什么 RNA 需要 `_enum_items` 而不能从 DNA 自动推出取值列表？*

  *练习 9.6（迁移的幂等性）。*  故意把 `BLENDER_FILE_SUBVERSION`
  留在 `45` 而不改成 `46`，重复打开/保存同一个文件三次。
  观察 `book_demo_value` 是否被反复重置为 `1.0f`。
  用这一次实验解释 §9.2.6 的"易错点 3"。
]
