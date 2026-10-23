#import "../common.typ": *

= 第 14 章 修饰器、节点与几何处理

到目前为止，本书讲过的所有改动都是"把命令接进某个已有的执行流程"：
第 11 章把用户的按键接到一个操作符上，第 12 章把一块矩形接到一个编辑器类型上，
第 13 章讲清楚了这套流程在什么样的求值图里执行。但这些章节都回避了一个问题：
*真正把几何算出来的代码，是谁在什么时候调用的？*

答案是本章的两个主角。第一是 #term("修饰器", "modifier") ——
它回答"我改了参数，网格什么时候变成新形状"。
第二是 #term("节点", "node") —— 它把同样的求值逻辑变成用户可以连线的图。
第三个主角是它们共同操作的对象：#term("几何", "geometry") 本身，
以及它的两种表示（`Mesh` 与 `BMesh`）。

这三者构成了一条完整的路径。读完本章，你应该能回答下面这些问题，
并且知道该去哪个文件里找答案：

- 一个修饰器的参数存在哪里、回调是谁调的、调用顺序由什么决定？
- 几何节点、着色器节点、合成器节点为什么写法完全不同，却共用一套 `bNodeType`？
- 什么时候该用 `Mesh`，什么时候必须换成 `BMesh`，两者怎么转换？
- 想加一个自己的修饰器或节点，最少要动几个文件？

#note[
  本章继续沿用第 10、12、13 章的引用惯例：所有路径与行号都以
  Blender #blender-version（#raw(blender-branch)）为准，格式为「文件路径:行号」。
  修饰器目录下既有 `.cc` 也有直接放在顶层的 `.hh`，
  `ModifierTypeInfo` 本身则不在 `modifiers/` 里，而在 `blenkernel/`。
]

== 14.1 修饰器体系

=== 14.1.1 两层结构：数据层与类型层

Blender 里几乎每一种可扩展的东西都遵循同一个模式（第 0 章已经点出）：
*定义一个描述结构体，填上一组回调函数指针，在启动时把它注册进一张全局表。*
修饰器是这个模式最干净的实例，而且它的两层分得异常清楚：

#figure(
  kind: table,
  table(
    columns: (1fr, 1.5fr, 1.5fr, 2.2fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*结构体*], [*定义位置*], [*要被写进 `.blend` 吗*]),
    [数据层],
    [`ModifierData` 及其派生结构],
    [#src("source/blender/makesdna/DNA_modifier_types.h:169")],
    [要。名字、开关、参数全部存盘],
    [类型层],
    [`ModifierTypeInfo`],
    [#src("source/blender/blenkernel/BKE_modifier.hh:187")],
    [不要。回调函数指针没法存盘，每次启动重建],
  ),
  caption: [修饰器的两层结构。数据层在 `makesdna`，类型层在 `blenkernel`。],
) <tbl-mod-two-layers>

这个划分带来一个立刻可用的推论：*给已有修饰器加一个参数，和加一个新修饰器，
是两件难度完全不同的事*。加参数只动数据层与 RNA；加新修饰器要同时动三层
（数据层、类型层、以及两者的连接处）。§14.4 会按后者走一遍完整流程。

=== 14.1.2 数据层：`ModifierData` 是所有修饰器的共同前缀

`ModifierData` 定义在 #src("source/blender/makesdna/DNA_modifier_types.h:169")。
它的写法值得单独看一眼，因为这条写法本身就是设计说明：

```c
/* source/blender/makesdna/DNA_modifier_types.h:169（节选） */
struct ModifierData {
  struct ModifierData *next = nullptr, *prev = nullptr;

  ModifierType type = eModifierType_None;
  ModifierMode mode = {};
  /* Time in seconds that the modifier took to evaluate. This is only set on evaluated objects. */
  float execution_time = 0;
  ModifierFlag flag = {};
  /* An "expand" bit for each of the modifier's (sub)panels (#uiPanelDataExpansion). */
  short ui_expand_flag = 0;
  ...
  /*
   * Uniquely identifies the modifier within the object. This identifier is stable across Blender
   * sessions. ...
   */
  int persistent_uid = 0;
  char name[/*MAX_NAME*/ 64] = "";

  char *error = nullptr;

  struct IDProperty *system_properties = nullptr;

  /* Runtime field which contains runtime data which is specific to a modifier type. */
  void *runtime = nullptr;
};
```

几点必须记住：

- *`next` / `prev` 在最前面*，所以修饰器栈就是一个普通的
  `ListBaseT<ModifierData>`（`Object::modifiers`）。
  "栈的顺序"就是链表的顺序，没有额外的序号字段。
- *`type` 是一个整数枚举*，取值见
  #src("source/blender/makesdna/DNA_modifier_types.h:38")，
  注释在最上面写着 "TYPEDEF VALUES ARE WRITTEN IN FILES! SO DO NOT CHANGE!"。
  这是 DNA 层最常见的约束：*枚举值会存进 `.blend`，只能追加，不能重排*。
  5.2 的这一版枚举从 `eModifierType_None = 0` 一直到
  `eModifierType_GreasePencilTexture = 86`，然后是 `NUM_MODIFIER_TYPES`。
- *`mode` 是运行开关，`flag` 是状态标记*，两者都是位域枚举。
  `mode` 里最关键的三位是 `eModifierMode_Realtime`、
  `eModifierMode_Render`、`eModifierMode_Editmode`
  （#src("source/blender/makesdna/DNA_modifier_types.h:131")），
  它们分别对应界面上那三个显示器 / 相机 / 编辑模式图标。
- *`execution_time` 是求值耗时*，而且注释明确说"只在求值对象上设置"。
  它由 `bke::ScopedModifierTimer` 写入
  （#src("source/blender/blenkernel/BKE_modifier.hh:656")），
  §14.1.5 会看到它在求值循环里怎么用的。
- *`runtime` 是 `void *`*，给修饰器放自己的缓存。
  它不存盘，并且由你的 `free_runtime_data` 回调负责释放
  （#src("source/blender/blenkernel/BKE_modifier.hh:391")）。

*每个修饰器的参数结构都以 `ModifierData` 作为第一个成员开头*。
例如 Wave 修饰器用的是：

```c
/* source/blender/makesdna/DNA_modifier_types.h 里的 WaveModifierData（结构示意） */
struct WaveModifierData {
  ModifierData modifier;    /* 必须是第一个成员 */
  ...
  short flag;               /* MOD_WAVE_X / MOD_WAVE_Y / MOD_WAVE_CYCL / ... */
  float timeoffs, lifetime, damp, speed;
  ...
};
```

因为第一个成员的位置永远是 0，所以 `ModifierData *` 和
`WaveModifierData *` 之间的转换只是一个指针 reinterpret
（源码里一律写成 `reinterpret_cast<WaveModifierData *>(md)`，
见 #src("source/blender/modifiers/intern/MOD_wave.cc:283")）。
这正是 C 时代"手写继承"的做法，也是整个 DNA 层的地基。

=== 14.1.3 类型层：`ModifierTypeInfo` 的每一个回调

`ModifierTypeInfo` 定义在 #src("source/blender/blenkernel/BKE_modifier.hh:187")，
一共约 240 行，字段全是 C 风格函数指针。按用途分成四组：

```cpp
/* source/blender/blenkernel/BKE_modifier.hh:187（节选，只保留字段名与类型） */
struct ModifierTypeInfo {
  char idname[64];        /* 唯一标识，也是 UI 面板 id 的来源 */
  char name[64];          /* 界面显示名 */
  char struct_name[64];   /* DNA 结构体名，"WaveModifierData" */
  int struct_size;        /* sizeof(WaveModifierData) */
  StructRNA **srna;       /* 指向 RNA_WaveModifier 这个指针的指针 */
  ModifierTypeType type;
  ModifierTypeFlag flags;
  int icon;               /* ICON_MOD_WAVE */

  void (*copy_data)(const ModifierData *md, ModifierData *target, int flag);
  void (*deform_verts)(ModifierData *md, const ModifierEvalContext *ctx,
                       Mesh *mesh, MutableSpan<float3> positions);
  Mesh *(*modify_mesh)(ModifierData *md, const ModifierEvalContext *ctx, Mesh *mesh);
  void (*modify_geometry_set)(ModifierData *md, const ModifierEvalContext *ctx,
                              bke::GeometrySet *geometry_set);
  ...
};
```

四组字段的作用如下表。

#figure(
  kind: table,
  table(
    columns: (1.5fr, 0.9fr, 2.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段*], [*必需*], [*作用*]),
    [`idname` / `name`], [必需],
    [`idname` 决定 UI 面板 id：`BKE_modifier_type_panel_id()` 拼成
     `"MOD_PT_" + idname`（#src("source/blender/blenkernel/BKE_modifier.hh:429")）],
    [`struct_name` / `struct_size`], [必需],
    [`BKE_modifier_new()` 按这两个值分配实例
     （#src("source/blender/blenkernel/intern/modifier.cc:146")）],
    [`srna`], [必需],
    [指向 RNA 结构体指针的*指针*。类型信息是静态初始化的，
     那时 RNA 还没建好（注释见 #src("source/blender/blenkernel/BKE_modifier.hh:206")）],
    [`type` / `flags` / `icon`], [必需],
    [`type` 决定进哪条求值通路，`flags` 决定能力与限制，`icon` 是界面图标],
    [`copy_data`], [必需],
    [复制用户参数。绝大多数修饰器直接填 `BKE_modifier_copydata_generic`],
    [`deform_verts` 系列], [可选],
    [只变形顶点位置，不改拓扑。见 §14.1.4],
    [`modify_mesh`], [可选],
    [返回一个新 `Mesh`，可以增删几何],
    [`modify_geometry_set`], [可选],
    [就地改 `GeometrySet`，可以产出非网格组件（点云、曲线、体积）],
    [`init_data`], [可选],
    [填默认值。`BKE_modifier_new()` 分配后会调它
     （#src("source/blender/blenkernel/intern/modifier.cc:162")）],
    [`required_data_mask`], [可选],
    [声明需要哪些 CustomData 层（顶点组、UV）。见 §14.3.3],
    [`update_depsgraph`], [可选],
    [向依赖图加边。这是第 13 章的内容在本章的落点],
    [`foreach_ID_link`], [可选],
    [遍历引用的其它 ID（纹理、物体），用于链接与引用计数],
    [`panel_register`], [可选],
    [注册 UI 面板类型。不填就没有设置界面。见 §14.1.7],
    [`blend_write` / `blend_read`], [可选],
    [额外的存盘 / 读盘处理，例如动态分配的数组],
    [`is_disabled` / `depends_on_time` / `depends_on_normals`], [可选],
    [三个"按数据内容判断"的回调：是否失效、是否随帧变化、是否需要网格法线],
    [`free_data` / `free_runtime_data` / `foreach_cache`], [可选],
    [释放用户数据 / 释放运行期缓存 / 枚举缓存键],
  ),
  caption: [`ModifierTypeInfo` 各字段的必需性与作用。「必需」指源码里的注释分组，不代表编译期强制。],
) <tbl-mti-fields>

=== 14.1.4 `ModifierTypeType`：决定进哪条求值通路

`ModifierTypeType` 只有六个取值（#src("source/blender/blenkernel/BKE_modifier.hh:46")），
但它是整个修饰器系统最重要的一个字段，因为*求值循环就是按它分支的*。

#figure(
  kind: table,
  table(
    columns: (1.4fr, 2.9fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*取值*], [*含义*], [*实际调用的回调*]),
    [`None`], [占位，只给 `modifierType_None` 用], [什么都不调],
    [`OnlyDeform`],
    [只改顶点位置，拓扑不变。源码注释要求它"必须有一个有效的 `deform_verts`"],
    [`deform_verts` 或 `deform_verts_EM`],
    [`Constructive`], [只增加几何，不删除], [`modify_mesh` 或 `modify_geometry_set`],
    [`Nonconstructive`], [既能增加也能删除几何], [`modify_mesh` 或 `modify_geometry_set`],
    [`DeformOrConstruct`],
    [两种回调都有效。注释举的例子是粒子修饰器：
     对网格来说它是变形，对曲线来说它会发射粒子],
    [两条通路都走],
    [`NonGeometrical`],
    [像 `Nonconstructive`，但不碰几何本身，只改 CustomData 层。
     注释举的例子是 UVProject 与 WeightVG],
    [`modify_mesh`],
  ),
  caption: [`ModifierTypeType` 的六个取值。前两个决定"能否放进变形阶段"。],
) <tbl-mod-type>

这个字段的威力在 §14.1.5 的求值循环里会看得非常清楚：
*所有连续的 `OnlyDeform` 修饰器会被合并成一次"只改坐标"的快速通路*，
而一旦遇到非 `OnlyDeform` 的修饰器，就必须退化成"复制整个网格"。

=== 14.1.4.1 `ModifierTypeFlag`

`ModifierTypeFlag` 是能力声明（#src("source/blender/blenkernel/BKE_modifier.hh:77")）。
常用的几个：

#figure(
  kind: table,
  table(
    columns: (2.3fr, 2.9fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*标志*], [*含义*]),
    [`AcceptsMesh`], [接受网格输入],
    [`AcceptsCVs`], [接受曲线 / 曲面 / 文字（CV = control vertex）],
    [`AcceptsVertexCosOnly`], [只接受一组坐标，不关心拓扑],
    [`AcceptsBMesh`], [接受未转换的 `BMesh`。不设这个标志时框架会先要求 `Mesh` 数据
     （#src("source/blender/blenkernel/intern/modifier.cc:967")）],
    [`AcceptsGreasePencil`], [接受蜡笔数据],
    [`SupportsMapping`],
    [支持 "On Cage"，输出几何能通过 `CD_ORIGINDEX` 映射回原始索引。
     注释特别提醒：*从输入凭空造出新几何的修饰器不该设这一位*],
    [`SupportsEditmode`], [可以在编辑模式里求值],
    [`EnableInEditmode`], [默认在编辑模式下启用。只有又快又常用的才该设],
    [`RequiresOriginalData`],
    [需要原始数据，因此*不能被放到任何非变形修饰器之后*。
     违反时求值循环会报错并跳过这个修饰器],
    [`UsesPointCache`], [使用点缓存],
    [`Single`], [物理类修饰器，同类型只允许一个],
    [`NoUserAdd`], [不出现在"添加修饰器"菜单里],
  ),
  caption: [`ModifierTypeFlag` 的常用取值。每个修饰器只填它真正需要的那几位。],
) <tbl-mod-flags>

#pitfall[
  `RequiresOriginalData` 是新手最容易踩的一位。它的含义不是"我需要一份数据副本"，
  而是"我必须看到*未被任何非变形修饰器动过*的网格"。
  求值循环用一个布尔量 `have_non_onlydeform_modifiers_applied` 判断
  （#src("source/blender/blenkernel/intern/mesh_data_update.cc:386")），
  一旦为真就 `BKE_modifier_set_error()` 然后 `continue`
  （#src("source/blender/blenkernel/intern/mesh_data_update.cc:398")）。
  现象很隐蔽：*修饰器不报错、不闪退，只是静默失效*，界面上多一行红字。
]

=== 14.1.5 注册与查找：一张定长数组

修饰器的"注册表"简单到不可思议，就在
#src("source/blender/blenkernel/intern/modifier.cc:87")：

```cpp
/* source/blender/blenkernel/intern/modifier.cc:87 */
static ModifierTypeInfo *modifier_types[NUM_MODIFIER_TYPES] = {nullptr};
```

*数组下标就是 `eModifierType_*` 的枚举值*。填充它的函数是
`modifier_type_init()`（#src("source/blender/modifiers/intern/MOD_util.cc:204")），
形式是一长串宏：

```cpp
/* source/blender/modifiers/intern/MOD_util.cc:204（节选） */
void modifier_type_init(ModifierTypeInfo *types[])
{
#define INIT_TYPE(typeName) (types[eModifierType_##typeName] = &modifierType_##typeName)
  INIT_TYPE(None);
  INIT_TYPE(Curve);
  INIT_TYPE(Lattice);
  ...
  INIT_TYPE(Wave);
  ...
#undef INIT_TYPE
}
```

调用链是 `BKE_modifier_init()`
（#src("source/blender/blenkernel/intern/modifier.cc:90")）
→ `modifier_type_init()`
（#src("source/blender/blenkernel/intern/modifier.cc:95")）。
注意数组元素填的是 `modifierType_*` 的*地址*，而这些变量全部声明在
#src("source/blender/modifiers/MOD_modifiertypes.hh")，
以 `extern ModifierTypeInfo modifierType_Wave;` 的形式
（#src("source/blender/modifiers/MOD_modifiertypes.hh:24")）。

查找走的是 `BKE_modifier_get_info()`
（#src("source/blender/blenkernel/intern/modifier.cc:120")）：

```cpp
/* source/blender/blenkernel/intern/modifier.cc:120 */
const ModifierTypeInfo *BKE_modifier_get_info(ModifierType type)
{
  /* type unsigned, no need to check < 0 */
  if (type < NUM_MODIFIER_TYPES && modifier_types[type] && modifier_types[type]->name[0] != '\0') {
    return modifier_types[type];
  }

  return nullptr;
}
```

三个防御必须同时满足：下标在范围内、指针非空、`name` 非空。
第三个条件看起来多余，其实是给"类型被删除但文件里还有旧实例"这种情况留的后路 ——
把 `name[0]` 置空就等于注销一个类型。调用方一律要判空，
源码里 `BKE_modifier_get_info(...)` 之后紧跟 `if (mti == nullptr)` 的写法随处可见。

#tip[
  `BKE_modifier_get_info()` 在 5.2 中出现了一百多次。
  当你想知道"某个 `md->type` 到底会走什么逻辑"，
  最快的办法是抄一份类型信息，或者直接在调试器里 `p *BKE_modifier_get_info(md->type)`。
  所有回调地址、`type`、`flags` 一眼可见。
]

=== 14.1.6 RNA 层：Python 看到的是什么

修饰器给 Python 暴露的入口只有一条，而且非常克制：

```cpp
/* source/blender/makesrna/intern/rna_modifier.cc:904（节选） */
static StructRNA *rna_Modifier_refine(PointerRNA *ptr)
{
  ModifierData *md = static_cast<ModifierData *>(ptr->data);
  const ModifierTypeInfo *modifier_type = BKE_modifier_get_info(md->type);
  if (modifier_type != nullptr) {
    return *modifier_type->srna;
  }
  return RNA_Modifier;
}
```

这是 #term("RNA refine", "类型细化") 机制：Python 拿到的
`obj.modifiers[i]` 表面上类型是 `Modifier`，实际类型由 `md->type` 决定 ——
*`ModifierTypeInfo::srna` 就是这个映射表*。这也是为什么
`bpy.types.Modifier` 的子类（`WaveModifier`、`SubsurfModifier` 等）
是只读的映射，而不是可继承的注册点。

"添加修饰器"这条路走的是操作符，属性项表是一个硬编码数组：

```c
/* source/blender/makesrna/intern/rna_modifier.cc:44 */
const EnumPropertyItem rna_enum_object_modifier_type_items[] = {
    RNA_ENUM_ITEM_HEADING(N_("Modify"), nullptr),
    {eModifierType_GreasePencilWeightProximity, "GREASE_PENCIL_VERTEX_WEIGHT_PROXIMITY", ...},
    ...
};
```

而 `OBJECT_OT_modifier_add` 把这个数组交给一个运行时过滤函数
（#src("source/blender/editors/object/object_modifier.cc:1436")），
过滤条件是 `NoUserAdd` 标志与"当前物体类型是否支持"：

```cpp
/* source/blender/editors/object/object_modifier.cc:1451（节选） */
for (int a = 0; rna_enum_object_modifier_type_items[a].identifier; a++) {
  const EnumPropertyItem *md_item = &rna_enum_object_modifier_type_items[a];

  if (md_item->identifier[0]) {
    const ModifierTypeInfo *mti = BKE_modifier_get_info(ModifierType(md_item->value));

    if (mti->flags & eModifierTypeFlag_NoUserAdd) {
      continue;
    }

    if (!BKE_object_support_modifier_type_check(ob, md_item->value)) {
      continue;
    }
  }
  ...
}
```

#pitfall[
  *Python 无法注册新的修饰器类型*。原因和"新增编辑器"（§12.5）完全一样：
  要注册一个类型，需要写进 `modifier_types[]` 这张 C++ 侧定长数组，
  而这张数组没有任何 Python 入口。`bpy.types` 里能看到 `WaveModifier`，
  只说明 RNA 为它建了一个 `StructRNA`，不说明你可以创造同类的新的。
  Python 能做的只有：*创建已有修饰器的实例*（`obj.modifiers.new(name, type)`）、
  *读写它们的属性*、*把它们按任意顺序排列*。
]

=== 14.1.7 面板是怎么挂上去的

修饰器的 UI 面板不是静态注册的，而是启动时动态生成的。
`SpaceType` 的 `panel_register` 回调里有一层循环
（#src("source/blender/editors/space_buttons/space_buttons.cc:1116")）：

```cpp
/* source/blender/editors/space_buttons/space_buttons.cc:1118（节选） */
for (int i = 0; i < NUM_MODIFIER_TYPES; i++) {
  const ModifierTypeInfo *mti = BKE_modifier_get_info(ModifierType(i));
  if (mti != nullptr && mti->panel_register != nullptr) {
    mti->panel_register(art);
  }
}
```

所以 *`ModifierTypeInfo::panel_register` 是"这个修饰器有没有设置界面"的唯一开关*。
不填它，修饰器照样能算，只是在属性编辑器里没有折叠面板。
面板自己则由 `modifier_panel_register()` 创建
（#src("source/blender/modifiers/intern/MOD_ui_common.cc:470")），
它把 `idname` 拼成 `MOD_PT_` 前缀：

```cpp
/* source/blender/blenkernel/intern/modifier.cc:130（节选） */
void BKE_modifier_type_panel_id(ModifierType type, char *r_idname)
{
  const ModifierTypeInfo *mti = BKE_modifier_get_info(type);
  BLI_string_join(r_idname, sizeof(PanelType::idname), MODIFIER_TYPE_PANEL_PREFIX, mti->idname);
}
```

注释里解释得很清楚："修饰器面板是按*每个修饰器实例*建的，而不是按类型建的"
（#src("source/blender/editors/space_buttons/space_buttons.cc:1116")）。
也就是说，同一个 `idname` 的面板会被反复实例化到每一个修饰器条目上。

=== 14.1.8 求值：两段式循环

现在到了最关键的部分：*谁在什么时候调用这些回调*。
答案在 #src("source/blender/blenkernel/intern/mesh_data_update.cc") 的
`mesh_calc_modifiers()`（同文件:271）。

求值循环被明确切成了两段。第一段只执行"开头的连续变形修饰器"
（#src("source/blender/blenkernel/intern/mesh_data_update.cc:345")）：

```cpp
/* source/blender/blenkernel/intern/mesh_data_update.cc:345（节选） */
/* Apply all leading deform modifiers. */
if (use_deform) {
  for (; md; md = md->next, md_datamask = md_datamask->next) {
    const ModifierTypeInfo *mti = BKE_modifier_get_info(md->type);

    if (!BKE_modifier_is_enabled(&scene, md, required_mode)) {
      continue;
    }

    if (mti->type == ModifierTypeType::OnlyDeform && !sculpt_dyntopo) {
      ScopedModifierTimer modifier_timer{*md};
      if (!mesh) {
        ASSERT_IS_VALID_MESH_INPUT(&mesh_input);
        mesh = BKE_mesh_copy_for_eval(mesh_input);
        ASSERT_IS_VALID_MESH_OUTPUT(mesh);
      }

      if (mti->required_data_mask) {
        CustomData_MeshMasks mask{};
        mti->required_data_mask(md, &mask);
        if (mask.vmask & CD_MASK_ORCO) {
          add_orco_mesh(ob, nullptr, *mesh, nullptr, CD_ORCO);
        }
      }

      BKE_modifier_deform_verts(md, &mectx, mesh, mesh->vert_positions_for_write());
    }
    else {
      break;
    }
  }
  ...
}
```

第二段处理剩下的全部（#src("source/blender/blenkernel/intern/mesh_data_update.cc:385")）：

```cpp
/* source/blender/blenkernel/intern/mesh_data_update.cc:385（节选） */
/* Apply all remaining constructive and deforming modifiers. */
bool have_non_onlydeform_modifiers_applied = false;
for (; md; md = md->next, md_datamask = md_datamask->next) {
  const ModifierTypeInfo *mti = BKE_modifier_get_info(md->type);

  if (!BKE_modifier_is_enabled(&scene, md, required_mode)) {
    continue;
  }

  if (mti->type == ModifierTypeType::OnlyDeform && !use_deform) {
    continue;
  }

  if ((mti->flags & eModifierTypeFlag_RequiresOriginalData) &&
      have_non_onlydeform_modifiers_applied)
  {
    BKE_modifier_set_error(&ob, md, "Modifier requires original data, bad stack position");
    continue;
  }
  ...
  ScopedModifierTimer modifier_timer{*md};
  ...
}
```

两段之间的分界线由 `break` 决定：*只要遇到第一个非 `OnlyDeform` 的修饰器，
第一段就结束*。这个设计的收益很直接 —— 顶点位置数组是连续的
`MutableSpan<float3>`，变形修饰器可以原地改它，不需要复制网格。
而一旦有修饰器要增删顶点，整个网格就必须被重建或复制。

`BKE_modifier_deform_verts()` 与 `BKE_modifier_modify_mesh()` 是两层的包装
（#src("source/blender/blenkernel/intern/modifier.cc:976")），
它们做的是回调分发加上一致性维护：

```cpp
/* source/blender/blenkernel/intern/modifier.cc:976（节选） */
bool BKE_modifier_deform_verts(ModifierData *md,
                               const ModifierEvalContext *ctx,
                               Mesh *mesh,
                               MutableSpan<float3> positions)
{
  using namespace blender::bke;
  const ModifierTypeInfo *mti = BKE_modifier_get_info(md->type);

  if (mti->deform_verts) {
    mti->deform_verts(md, ctx, mesh, positions);
    if (mesh) {
      mesh->tag_positions_changed();
    }
    return true;
  }
  /* Try to emulate #deform_verts by deforming a mesh. */
  if (mti->modify_geometry_set) {
    ...
  }
  return false;
}
```

这里有三个值得学的细节：

1. *`tag_positions_changed()` 由包装层调，不由修饰器调*。
   修饰器只管改坐标，通知框架"坐标变了"是框架的责任。
   手写 `mesh->vert_positions_for_write()` 的时候必须自己记得调它，
   否则法线不会重算，画面看起来是黑的或者脏的。
2. *`deform_verts` 为空时，包装层会尝试用 `modify_geometry_set` 模拟变形*。
   做法是把坐标写进一个只读的 `GeometrySet`，调一次节点式求值，
   再比较拓扑有没有变（`MeshTopologyState`，同文件:1006）。
   这条兜底路径是给"只实现了几何节点、没写传统回调"的修饰器准备的。
3. *`modify_mesh` 之前会按标志决定是否需要把 `BMesh` 包装展开成 `Mesh` 数据*
   （#src("source/blender/blenkernel/intern/modifier.cc:967")）。
   这就是 `eModifierTypeFlag_AcceptsBMesh` 的实际用处。

还有一条不显眼但很实用的规则：*只有连续开头的变形修饰器才能被合并*。
把 Wave 放到 Subdivision Surface 之后，Wave 就不再走快速通路；
放到之前，它就能省下一次网格复制。这也是界面上拖动修饰器顺序会显著影响
性能与结果的原因。

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.4fr, 2.4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*你想做的事*], [*要实现的回调*], [*还要注意*]),
    [只移动 / 缩放顶点],
    [`deform_verts`],
    [`type` 必须是 `OnlyDeform`；`flags` 至少要有 `AcceptsMesh`。
     编辑模式也要生效就加 `deform_verts_EM` + `SupportsEditmode`],
    [增删顶点、面],
    [`modify_mesh` 或 `modify_geometry_set`],
    [`type` 用 `Constructive` 或 `Nonconstructive`。
     用 `modify_mesh` 时*不能*释放传进来的 `mesh`],
    [同时处理曲线、点云],
    [`modify_geometry_set`],
    [直接操作 `bke::GeometrySet`，见 §14.3.4],
    [需要顶点组权重],
    [—],
    [`required_data_mask` 里设 `CD_MASK_MDEFORMVERT`，
     再用 `MOD_get_vgroup()` 取（#src("source/blender/modifiers/intern/MOD_util.cc:158")）],
    [需要当前帧时间],
    [`depends_on_time` 返回 true],
    [时间用 `DEG_get_ctime(ctx->depsgraph)` 取，
     不要在回调里直接读 `scene->r.cfra`],
    [需要引用其它物体],
    [`foreach_ID_link` + `update_depsgraph`],
    [前者管引用计数与库链接，后者给依赖图加边（第 13 章）],
  ),
  caption: [按需求选择回调的对照表。],
) <tbl-mod-choose-callback>

#summary[
  修饰器系统可以压缩成三句话：
  *数据在 `DNA_modifier_types.h`，类型信息在 `BKE_modifier.hh`，
  两者通过 `md->type` 这个整数下标相连*（注册表是 `modifier.cc:87` 的定长数组）。
  *求值分两段*：开头的连续 `OnlyDeform` 原地改坐标，
  之后的修饰器改几何本体，顺序就是链表顺序。
  *扩展点是 C++ 独占的*：`modifier_types[]` 没有 Python 入口，
  Python 只能操作已有类型的实例。
]

== 14.2 节点体系

节点是修饰器思想的推广。修饰器用一条固定顺序的链表表达"先做什么、后做什么"，
节点把它变成了一张由用户连线的有向图。但两者共享同一个底层设计：
*一个描述结构体 + 一组回调 + 一张全局注册表*。

=== 14.2.1 几套节点树，一套基础设施

Blender 里至少有五类节点树，它们共用同一套 DNA 结构（`bNodeTree` / `bNode` /
`bNodeSocket` / `bNodeLink`，定义在 #src("source/blender/makesdna/DNA_node_types.h:1869") 起），
但求值方式、注册方式和 UI 菜单都不同：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.5fr, 1.5fr, 1.4fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*节点树*], [*源码目录*], [*注册入口*], [*求值回调*]),
    [几何节点],
    [#src("source/blender/nodes/geometry/")],
    [`NOD_REGISTER_NODE` 宏],
    [`geometry_node_execute`],
    [着色器节点],
    [#src("source/blender/nodes/shader/")],
    [`register_node_type_sh_*` 手写清单],
    [`gpu_fn` 与 `materialx_fn`],
    [合成器节点],
    [#src("source/blender/nodes/composite/")],
    [`register_compositor_nodes()`],
    [`get_compositor_operation`],
    [函数节点],
    [#src("source/blender/nodes/function/")],
    [`register_function_nodes()`],
    [`build_multi_function`],
    [纹理节点],
    [#src("source/blender/nodes/texture/")],
    [`register_node_type_tex_*` 手写清单],
    [`exec_fn`（旧式执行栈）],
  ),
  caption: [五类节点树。它们共用 DNA 与 `bNodeType`，差别在注册方式与求值回调。],
) <tbl-node-trees>

这五类的总入口是 `register_nodes()`
（#src("source/blender/nodes/intern/node_register.cc:137")）：

```cpp
/* source/blender/nodes/intern/node_register.cc:137（节选） */
void register_nodes()
{
  register_zone_types();
  register_undefined_types();
  register_standard_node_socket_types();

  register_node_tree_type_geo();
  register_node_tree_type_cmp();

  register_node_type_frame();
  register_node_type_reroute();
  register_node_type_implicit_conversion();
  register_node_type_group_input();
  register_node_type_group_output();

  register_compositor_nodes();
  register_shader_nodes();
  register_texture_nodes();
  register_geometry_nodes();
  register_function_nodes();
}
```

它由 `node_system_init()`
（#src("source/blender/blenkernel/intern/node.cc:6080")）在启动时调用一次。

=== 14.2.1.1 `bNodeType`：节点版 `ModifierTypeInfo`

`bNodeType` 在 #src("source/blender/blenkernel/BKE_node.hh:264")，字段比
`ModifierTypeInfo` 多得多（约 210 行），因为它要同时服务于上面五套系统。
按用途分组，关键的几组是：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 3.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段组*], [*字段与作用*]),
    [标识],
    [`idname`（如 `"GeometryNodeWobble"`）、`type_legacy`（旧的整数类型）、
     `ui_name` / `ui_description` / `ui_icon` / `nclass` / `enum_name_legacy`],
    [尺寸],
    [`default_width` / `minwidth` / `maxwidth`，
     常用值集中在 `struct NodeWidth`（#src("source/blender/blenkernel/BKE_node.hh:241")）],
    [静态 socket 模板],
    [`inputs` / `outputs`，指向 `bNodeSocketTemplate` 数组，是声明式 socket 之前的旧机制],
    [声明],
    [`declare`（`NodeDeclareFunction`）与 `static_declaration`。
     *现代节点的 socket 全走这里*],
    [生命周期],
    [`initfunc` / `freefunc` / `copyfunc`，
     以及给 Python 用的 `initfunc_api` / `freefunc_api` / `copyfunc_api`],
    [可添加性],
    [`poll` / `poll_instance` / `add_ui_poll`],
    [绘制],
    [`draw_buttons` / `draw_buttons_ex` / `draw_backdrop` / `labelfunc` / `ui_class`],
    [求值],
    [`geometry_node_execute`、`build_multi_function`、`gpu_fn`、`exec_fn`、
     `get_compositor_operation`、`materialx_fn`、`eval_elem` / `eval_inverse`],
    [存储],
    [`storagename`（DNA 结构体名）、`blend_write_storage_content` /
     `blend_data_read_storage_content`],
    [RNA],
    [`rna_ext`（`ExtensionRNA`），指向对应的 `StructRNA`],
  ),
  caption: [`bNodeType` 的字段分组。同一个结构体要同时满足五套节点系统的需要。],
) <tbl-bnodetype>

#tip[
  看到一个节点想知道它是哪一套的，最快的办法是看 `idname` 前缀：
  `GeometryNode*` 是几何节点，`ShaderNode*` 是着色器节点，
  `CompositorNode*` 是合成器节点，`FunctionNode*` 是函数节点。
  这个命名约定在源码里几乎没有例外，也是 Python 侧
  `bl_idname` 必须逐字符匹配的那个字符串。
]

=== 14.2.1.2 `NOD_REGISTER_NODE`：为什么有这么一个宏

几何节点和函数节点的注册没有一长串手写清单，而是散在每个节点自己的 `.cc` 里。
机制是一个宏加一个构建期脚本。宏定义在
#src("source/blender/nodes/NOD_register.hh:37")：

```cpp
/* source/blender/nodes/NOD_register.hh:37 */
#define NOD_REGISTER_NODE(REGISTER_FUNC) \
  void REGISTER_FUNC##_discover(); \
  void REGISTER_FUNC##_discover() \
  { \
    REGISTER_FUNC(); \
  }
```

它做三件事（注释原文就在宏上方）：

1. *充当源码标记*，供 `discover_nodes.py` 搜索；
2. *生成一个非 static 的包装函数*（原注册函数是 static，外部调不到）；
3. *让注册过程在源码里"看得见"*，而不是完全靠魔法。

脚本在 #src("source/blender/nodes/intern/discover_nodes.py")，用法写在文件头：

```python
# source/blender/nodes/intern/discover_nodes.py:5（节选）
'''
Usage:
    python discover_nodes.py
        <sources/root>
        <path/to/output.cc>
        <generated_function_name>
        <source>...
'''
```

CMake 侧把它包成一个函数 `add_node_discovery()`
（#src("source/blender/nodes/CMakeLists.txt:9")），几何节点目录这样调用它
（#src("source/blender/nodes/geometry/CMakeLists.txt:383")）：

```cmake
# source/blender/nodes/geometry/CMakeLists.txt:383
add_node_discovery(
  bf_nodes_geometry_generated
  "${SRC}"
  ${CMAKE_CURRENT_BINARY_DIR}/register_geometry_nodes.cc
  register_geometry_nodes
)
```

脚本用一条正则同时匹配"进入命名空间""退出命名空间"和宏调用
（#src("source/blender/nodes/intern/discover_nodes.py:70")），
从而在生成的 `.cc` 里还原出每个注册函数的完整限定名，
例如 `blender::nodes::node_geo_mesh_primitive_grid_cc::node_register_discover()`。

#warn[
  这意味着*新增一个几何节点只需要新建一个 `.cc` 文件并把它加进
  `CMakeLists.txt` 的 `SRC` 列表*，不需要在 `node_register.cc` 里手动加一行。
  但代价是：*如果你的 `.cc` 没被加进 `SRC`，脚本就扫不到那个宏*，
  节点不会注册，而且不会有任何报错 —— 只是在添加菜单里找不到它。
  这是"节点写了但看不见"的头号原因。
]

=== 14.2.2 socket：实例、类型、声明

socket 是节点图上唯一的数据通道。它在源码里被切成三层，理解这三层之后，
节点的 socket 相关代码就全部能读懂了：

#figure(
  kind: table,
  table(
    columns: (1.1fr, 1.5fr, 1.3fr, 2fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*类型*], [*定义位置*], [*作用*]),
    [实例],
    [`bNodeSocket`],
    [#src("source/blender/makesdna/DNA_node_types.h:1426")],
    [存进 `.blend` 的那一份。有 `identifier`、`name`、
     `type`、`default_value`、`in_out`],
    [类型],
    [`bke::bNodeSocketType`],
    [#src("source/blender/blenkernel/BKE_node.hh:163")],
    [描述一类 socket 的外观与行为：怎么画、怎么取 C++ 值、默认值是什么],
    [声明],
    [`nodes::SocketDeclaration`],
    [#src("source/blender/nodes/NOD_node_declaration.hh:171")],
    [节点的"接口定义"。节点类型用声明来生成和更新实例 socket],
  ),
  caption: [socket 的三层。`.blend` 里只存第一层，后两层每次启动重建。],
) <tbl-socket-layers>

*为什么要拆成三层？* 因为节点的 socket 集合经常依赖上下文。
例如"分离 XYZ"的输出数量、"打包 / 解包"的 socket 数、
"菜单切换"的分支数，都要看节点的参数才能定。
把这些逻辑写进一个 `declare` 回调，框架就能在
"参数变了"或"版本升级了"的时候重新生成 socket，
并尽量保留旧 socket 上的默认值与连线（`update_or_build()`，
见 #src("source/blender/nodes/NOD_node_declaration.hh:253")）。

声明的具体类是 `decl::Float`、`decl::Int`、`decl::Vector`、`decl::Geometry` 等，
每个都有一个对应的 `*Builder` 提供链式配置。*声明类的名字就是 socket 数据类型的
编译期常量*：

```cpp
/* source/blender/nodes/NOD_socket_declarations.hh:30（节选） */
class Float : public SocketDeclaration {
 public:
  static constexpr eNodeSocketDatatype static_socket_type = SOCK_FLOAT;
  float default_value = 0.0f;
  ...
};
```

常用的几个：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.4fr, 1.2fr, 2.2fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*声明类*], [*socket 类型*], [*C++ 值类型*], [*常见 Builder 方法*]),
    [`decl::Float`], [`SOCK_FLOAT`], [`float`],
    [`.default_value()` `.min()` `.max()` `.subtype()`],
    [`decl::Int`], [`SOCK_INT`], [`int`], [同上],
    [`decl::Bool`], [`SOCK_BOOLEAN`], [`bool`], [`.default_value()`],
    [`decl::Vector`], [`SOCK_VECTOR`], [`float3`（内部是 `float4`）],
    [`.default_value(float3)` `.dimensions()` `.subtype(PROP_TRANSLATION)`],
    [`decl::Color` / `decl::Rotation` / `decl::String` / `decl::Menu`],
    [`SOCK_RGBA` / `_ROTATION` / `_STRING` / `_MENU`],
    [`ColorGeometry4f` / `math::Quaternion` / `std::string` / `MenuValue`],
    [`.default_value()` 等],
    [`decl::Geometry`], [`SOCK_GEOMETRY`], [`GeometrySet`],
    [`.supported_type()` `.only_realized_data()` `.only_instances()`],
    [`decl::Object` / `Material` / `Collection` / `Bundle`],
    [`SOCK_OBJECT` / `_MATERIAL` / `_COLLECTION` / `_BUNDLE`],
    [对应的 ID 指针], [—],
  ),
  caption: [常用 socket 声明类。完整列表见 #src("source/blender/nodes/NOD_socket_declarations.hh") 与
   #src("source/blender/nodes/NOD_socket_declarations_geometry.hh")。],
) <tbl-socket-decl>

`decl::Geometry` 的 `supported_type()` 是一个容易被忽略但很有用的约束。
它写进 `SocketDeclaration` 的成员里，
让"这个输入只接受网格，不接受曲线"这类规则在连线之前就能被判掉，
而不是等到求值时报错。声明本身的字段是：

```cpp
/* source/blender/nodes/NOD_socket_declarations_geometry.hh:17（节选） */
class Geometry : public SocketDeclaration {
  blender::Vector<bke::GeometryComponent::Type> supported_types_;
  bool only_realized_data_ = false;
  bool only_instances_ = false;
  ...
};
```

`socket` 的连接规则最终落在 `can_connect()` 上，
几何 socket 的实现是"通用规则 + 类型必须相等"：

```cpp
/* source/blender/nodes/intern/node_socket_declarations.cc:970 */
bool Geometry::can_connect(const bNodeSocket &socket) const
{
  return sockets_can_connect(*this, socket) && socket.type == SOCK_GEOMETRY;
}
```

而 socket 实例的创建走 `bke::node_add_socket()`
（#src("source/blender/nodes/intern/node_socket_declarations.cc:953")）。

=== 14.2.2.1 内置 socket 类型注册

标准 socket 类型由 `register_standard_node_socket_types()`
（#src("source/blender/nodes/intern/node_socket.cc:2318")）注册。
它做的事看起来有点笨但很必要：*同一类 socket 会因为 subtype 不同而被注册成不同的类型*。
例如浮点就有十几个变体（同文件:2322 起），
从 `make_socket_type_float(PROP_NONE)` 到
`make_socket_type_float(PROP_ANGLE)`、`PROP_DISTANCE`、`PROP_TIME`……
原因：subtype 决定 UI 上怎么画这个滑杆（角度、距离、百分比、时间……），
而 UI 是通过 socket 类型查找的。所以"浮点 + 角度"和"浮点 + 百分比"
必须是两个可查找的类型。

=== 14.2.2.2 `bNodeSocket` 实例的字段

实例这一层也值得扫一眼，因为调试时经常需要看它
（#src("source/blender/makesdna/DNA_node_types.h:1426")）：

```c
/* source/blender/makesdna/DNA_node_types.h:1426（节选） */
struct bNodeSocket {
  struct bNodeSocket *next = nullptr, *prev = nullptr;

  /* Unique identifier for mapping. */
  char identifier[64] = "";
  char name[/*MAX_NAME*/ 64] = "";

  eNodeSocketDatatype type = {};
  eNodeSocketInOut in_out = {};
  /* Runtime type information. */
  bke::bNodeSocketType *typeinfo = nullptr;

  /* Default input value used for unlinked sockets. */
  void *default_value = nullptr;
  ...
  /* A link pointer, set in #BKE_ntree_update. */
  struct bNodeLink *link = nullptr;
};
```

三点：

- *`identifier` 是稳定键，`name` 只是显示名*。
  代码里找 socket 一律用 `identifier`，
  写新节点时 `add_input<decl::Float>("Size"_ustr)` 的这个字符串同时是两者，
  除非显式给第二个参数（#src("source/blender/nodes/NOD_node_declaration.hh:763")）。
- *`default_value` 是 `void *`*，指向一个类型相关的数据块。
  未连线的输入就读它。所以"改默认值"实际上是写这块内存。
- *`link` 是缓存的入边*，由 `BKE_ntree_update()` 填充。
  不要自己维护它。

=== 14.2.3 节点类型注册的三个范式

现在把三套系统的注册代码摆在一起对比。*它们解决同一个问题，
但写法差异很大，这个差异本身就是最好的说明*。

*范式一：几何节点（模块化 + 构建期发现）。*
以网格立方体节点为例（#src("source/blender/nodes/geometry/nodes/node_geo_mesh_primitive_cube.cc:116")）：

```cpp
/* source/blender/nodes/geometry/nodes/node_geo_mesh_primitive_cube.cc:116（节选） */
static void node_register()
{
  static bke::bNodeType ntype;

  geo_node_type_base(&ntype, "GeometryNodeMeshCube"_ustr, GEO_NODE_MESH_PRIMITIVE_CUBE);
  ntype.ui_name = "Cube";
  ntype.ui_description = "Generate a cuboid mesh with variable side lengths and subdivisions";
  ntype.enum_name_legacy = "MESH_PRIMITIVE_CUBE";
  ntype.nclass = NODE_CLASS_GEOMETRY;
  ntype.declare = node_declare;
  ntype.geometry_node_execute = node_geo_exec;
  bke::node_register_type(ntype);
}
NOD_REGISTER_NODE(node_register)
```

四个要点：`static bke::bNodeType ntype;` 是*函数局部静态*，
所以生命周期覆盖整个进程，注册表里存的是它的地址；
`geo_node_type_base()` 负责填默认值与 poll 函数
（#src("source/blender/nodes/geometry/node_geometry_util.cc:136")）；
`declare` 与 `geometry_node_execute` 是两个必须给的回调；
最后一行宏让构建期脚本找到它。

*范式二：着色器节点（手写清单）。*
着色器节点的注册函数直接导出成全局符号，由
#src("source/blender/nodes/shader/node_shader_register.cc") 逐条调用，
`register_node_type_sh_bsdf_glass()` 从第 15 行开始排到第 114 行。

```cpp
/* source/blender/nodes/shader/nodes/node_shader_bsdf_glass.cc:111（节选） */
void register_node_type_sh_bsdf_glass()
{
  namespace file_ns = nodes::node_shader_bsdf_glass_cc;

  static bke::bNodeType ntype;

  sh_node_type_base(&ntype, "ShaderNodeBsdfGlass"_ustr, SH_NODE_BSDF_GLASS);
  ntype.ui_name = "Glass BSDF";
  ntype.ui_description = "Glass-like shader mixing refraction and reflection at grazing angles";
  ntype.enum_name_legacy = "BSDF_GLASS";
  ntype.nclass = NODE_CLASS_SHADER;
  ntype.declare = file_ns::node_declare;
  ntype.gather_link_search_ops = search_link_ops_for_shader_bsdf_node;
  ntype.add_ui_poll = object_shader_nodes_poll;
  ntype.default_width = bke::NodeWidth::_160;
  ntype.draw_buttons = file_ns::node_shader_buts_glass;
  ntype.initfunc = file_ns::node_shader_init_glass;
  ntype.gpu_fn = file_ns::node_shader_gpu_bsdf_glass;
  ntype.materialx_fn = file_ns::node_shader_materialx;

  bke::node_register_type(ntype);
}
```

差别一眼可见：*`gpu_fn` 取代了 `geometry_node_execute`*，
因为着色器节点的"求值"是把自己编译进 GPU 着色器；
另外多出 `materialx_fn` 与 `draw_buttons`。
这个函数不是 static、也没有 `NOD_REGISTER_NODE` —— 它必须被
`node_shader_register.cc` 手动列出来。

*范式三：合成器节点。* 同理，走
`register_compositor_nodes()`，求值入口换成
`get_compositor_operation`（`bNodeType` 里的
"Get an instance of this node's compositor operation"，
#src("source/blender/blenkernel/BKE_node.hh:378")）。
§15.5 会展开它。

#pitfall[
  三类节点的求值回调*不能互换*。给几何节点填 `gpu_fn` 不会报错，
  但节点永远不会执行（因为没有 GPU 材质编译流程会碰它）；
  给着色器节点填 `geometry_node_execute` 同理。
  判断方法：看节点在哪个 `register_*_nodes()` 清单里被列出，
  或者看 `idname` 前缀。填错了不会编译失败，只会"节点什么都不做"。
]

=== 14.2.4 Python 侧：能做什么，不能做什么

节点体系和修饰器体系的边界不一样，值得单独说清楚：

#figure(
  kind: table,
  table(
    columns: (2.6fr, 1fr, 2.2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*想做的事*], [*Python*], [*说明*]),
    [读写已有节点的 socket 值],
    [可以],
    [`node.inputs["Size"].default_value = 2.0`],
    [增删节点、连线、建节点组],
    [可以],
    [`bpy.ops.node.add_node` / `node_tree.links.new()`],
    [自定义节点的*绘制*与*属性面板*],
    [可以],
    [`bpy.types.Node` 子类 + `draw_buttons` 方法],
    [把自定义节点加进"添加"菜单],
    [可以],
    [`nodeitems_utils.register_node_categories()`，
     见 #src("scripts/modules/nodeitems_utils.py:99")],
    [自定义节点的*求值行为*],
    [不行],
    [没有 Python 回调能改变几何结果],
    [新增一种节点树类型],
    [不行],
    [`register_node_tree_type_*` 是 C++ 侧入口],
    [新增一个内置几何节点],
    [不行],
    [要写 `NOD_REGISTER_NODE` 并重新编译],
  ),
  caption: [节点体系的 Python 边界。注意第 3、4 行：Python 能做"外壳"，
   但求值内核必须在 C++ 里。],
) <tbl-node-python-boundary>

#note[
  Python 自定义节点的定位是"给已有节点组做界面包装"。
  你可以定义一个 `bpy.types.Node` 子类，让它拥有漂亮的按钮和标签，
  但它内部实际做的计算仍然要委托给节点组或已有节点。
  想要真正的新算法，只能走 §14.4.2 的 C++ 路径。
]

== 14.3 几何与 BMesh 进阶

修饰器和节点最终都要落到具体的数据结构上。这一节把"几何"这件事讲清楚。

=== 14.3.1 两种表示：`Mesh` 与 `BMesh`

Blender 里网格有两种表示，它们的存在理由完全不同：

#figure(
  kind: table,
  table(
    columns: (1fr, 1.5fr, 1.5fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*表示*], [*定义位置*], [*结构*], [*适用场景*]),
    [`Mesh`],
    [#src("source/blender/makesdna/DNA_mesh_types.h:144")],
    [紧凑的平铺数组 + `CustomData` 层],
    [存盘、渲染、缓存、任何只读或只改坐标的场合],
    [`BMesh`],
    [#src("source/blender/bmesh/bmesh_class.hh:320")],
    [指针互连的元素 + 内存池],
    [编辑模式、需要拓扑查询与修改的算法],
  ),
  caption: [`Mesh` 与 `BMesh`。前者面向存储与吞吐，后者面向拓扑操作。],
) <tbl-mesh-bmesh>

`Mesh` 的关键字段（#src("source/blender/makesdna/DNA_mesh_types.h:144") 起）：

```c
/* source/blender/makesdna/DNA_mesh_types.h:165（节选） */
struct Mesh {
  ...
  int verts_num = 0;
  ...
  /* Span<float3> vert_positions() const; */
  MutableSpan<float3> vert_positions_for_write();
  ...
  void tag_positions_changed();
  ...
};
```

*`verts_num` 是计数，坐标通过 `vert_positions()` / `vert_positions_for_write()`
取*（#src("source/blender/makesdna/DNA_mesh_types.h:353")）。
后者的名字里带 `_for_write` 是有意的：它会触发 copy-on-write 的"我要改了"语义。
改完坐标必须调 `tag_positions_changed()`
（#src("source/blender/makesdna/DNA_mesh_types.h:559")），
否则法线不会重算 —— 这就是 §14.1.8 里包装层替你调的那个函数。
如果明确知道法线不受影响，可以用
`tag_positions_changed_no_normals()`（同文件:563）。

=== 14.3.1.1 为什么 `BMesh` 的元素都以 `BMHeader` 开头

`BMesh` 的四个元素类型是 `BMVert` / `BMEdge` / `BMLoop` / `BMFace`，
每一个的第一个成员都是 `BMHeader`
（#src("source/blender/bmesh/bmesh_class.hh:53")）：

```c
/* source/blender/bmesh/bmesh_class.hh:41（注释原文 + 结构体） */
/*
 * #BMHeader
 *
 * All mesh elements begin with a #BMHeader. This structure
 * hold several types of data
 *
 * 1: The type of the element (vert, edge, loop or face)
 * 2: Persistent "header" flags/markings (smooth, seam, select, hidden, etc)
 *    note that this is different from the "tool" flags.
 * 3: Unique ID in the #BMesh.
 * 4: some elements for internal record keeping.
 */
struct BMHeader {
  /* NOTE: it its essential the #BMHeader is at least the size of two pointers.
   * This is a requirement of mempool's method of iteration. */
  /* CustomData layers. */
  void *data;

  int index;

  /* Element geometric type (verts/edges/loops/faces). */
  char htype;
  /* This would be a CD layer, see below. */
  char hflag;

  char api_flag;
};
```

注释里那两句话解释了整个设计：

- *"至少要有两个指针的大小"* 是内存池迭代的要求。
  这就是为什么 `BMHeader` 明明只需要一个指针加几个字节，却被填充到 16 字节 ——
  文件里还有一条静态断言盯着它：
  `BLI_STATIC_ASSERT((sizeof(BMHeader) <= 16), "BMHeader size has grown!")`
  （#src("source/blender/bmesh/bmesh_class.hh:88")）。
- *"所有元素都以 `BMHeader` 开头"* 意味着 `BMHeader *` 是所有元素指针的公共前缀，
  泛型迭代器、工具标志、选中状态这些"对四类元素一视同仁"的操作
  只需要一个基类型。这和 §14.1.2 里 `ModifierData` 作为公共前缀是同一个技巧。

四个元素各自的拓扑指针（行号对应 #src("source/blender/bmesh/bmesh_class.hh")）：

- `BMVert`（#src("bmesh_class.hh:94")）：`float co[3]`、`float no[3]`、
  `BMEdge *e`（任一条出边）。
- `BMEdge`（#src("bmesh_class.hh:124")）：`BMVert *v1, *v2`、
  `BMLoop *l`（径向环上任一个 loop）、`BMDiskLink v1_disk_link, v2_disk_link`。
- `BMLoop`（#src("bmesh_class.hh:158")）：`BMVert *v`、`BMEdge *e`、
  `BMFace *f`、`BMLoop *radial_next, *radial_prev`、`BMLoop *next, *prev`。
- `BMFace`（#src("bmesh_class.hh:277")）：`BMLoop *l_first`、
  `int len`（边界数）、`int mat_nr`。

=== 14.3.1.2 两种遍历：disk cycle 与 radial cycle

`BMesh` 的拓扑查询全部靠两条循环链表。源码注释在这两处写得非常清楚，
值得原样读一遍。*disk cycle*（围绕一个顶点的边环）在
#src("source/blender/bmesh/bmesh_class.hh:117")：

```c
/* source/blender/bmesh/bmesh_class.hh:116（注释原文） */
/*
 * Disk link structure (the element in a circular linked list),
 * only used by edges to reference connected edges for the first & second vertices.
 */
struct BMDiskLink {
  struct BMEdge *next, *prev;
};
```

*radial cycle*（围绕一条边的面环）在 `BMLoop::radial_next` 上
（#src("source/blender/bmesh/bmesh_class.hh:187")）。注释里直接给了用法：

```c
/* source/blender/bmesh/bmesh_class.hh:211（注释原文，C 示例） */
BMLoop *l_iter = edge->l;
do {
  operate_on_face(l_iter->f);
} while ((l_iter = l_iter->radial_next) != edge->l);
```

*为什么是环而不是数组？* 因为网格编辑操作要频繁地插入与删除元素。
在数组里做插入是 O(n)，在双链环里是 O(1)。
代价是"遍历"不能靠下标，只能靠游标，于是就有了下面的迭代器宏。

=== 14.3.1.3 迭代器宏

`BMesh` 的遍历入口是 #src("source/blender/bmesh/intern/bmesh_iterators.hh") 里的宏。
`BMIterType` 枚举把"遍历什么"编码成整数
（#src("source/blender/bmesh/intern/bmesh_iterators.hh:37")）：

```c
/* source/blender/bmesh/intern/bmesh_iterators.hh:37（节选） */
enum BMIterType {
  BM_VERTS_OF_MESH = 1,
  BM_EDGES_OF_MESH = 2,
  BM_FACES_OF_MESH = 3,
  /* these are topological iterators. */
  BM_EDGES_OF_VERT = 4,
  BM_FACES_OF_VERT = 5,
  BM_LOOPS_OF_VERT = 6,
  BM_VERTS_OF_EDGE = 7,
  BM_FACES_OF_EDGE = 8,
  BM_VERTS_OF_FACE = 9,
  BM_EDGES_OF_FACE = 10,
  BM_LOOPS_OF_FACE = 11,
  BM_LOOPS_OF_LOOP = 12,
  BM_LOOPS_OF_EDGE = 13,
};
```

对应的四个宏：

```c
/* source/blender/bmesh/intern/bmesh_iterators.hh:72（节选） */
#define BM_ITER_MESH(ele, iter, bm, itype) \
  for (BM_CHECK_TYPE_ELEM_ASSIGN(ele) = BM_iter_new(iter, bm, itype, NULL); ele; \
       BM_CHECK_TYPE_ELEM_ASSIGN(ele) = BM_iter_step(iter))

#define BM_ITER_MESH_INDEX(ele, iter, bm, itype, indexvar) \
  for (BM_CHECK_TYPE_ELEM_ASSIGN(ele) = BM_iter_new(iter, bm, itype, NULL), indexvar = 0; ele; \
       BM_CHECK_TYPE_ELEM_ASSIGN(ele) = BM_iter_step(iter), (indexvar)++)

#define BM_ITER_ELEM(ele, iter, data, itype) \
  for (BM_CHECK_TYPE_ELEM_ASSIGN(ele) = BM_iter_new(iter, NULL, itype, data); ele; \
       BM_CHECK_TYPE_ELEM_ASSIGN(ele) = BM_iter_step(iter))
```

三者的分工：`BM_ITER_MESH` 扫全网格的某一类元素，
`BM_ITER_ELEM` 从某个元素出发扫它的邻接（比如一个面的所有 loop），
带 `_INDEX` 的版本自动维护一个从 0 开始的计数器。
`BM_CHECK_TYPE_ELEM_ASSIGN` 在 debug 构建里会检查元素类型是否与 `itype` 匹配 ——
这是防止"把 `BMFace *` 塞进 `BM_VERTS_OF_MESH`"这类错误的第一道防线。

#pitfall[
  在 `BM_ITER_MESH` 循环里*删除当前元素*会让迭代器失效。
  源码专门提供了 `BM_ITER_MESH_MUTABLE`
  （#src("source/blender/bmesh/intern/bmesh_iterators.hh:83")），
  它在每一步先把下一个元素存起来再交给你。
  Release 构建下这个宏是简化的版本，但语义一样：
  *你要删元素，就必须用 MUTABLE 版本*。
]

=== 14.3.2 转换：`BM_mesh_bm_from_me` 与三个反向函数

两种表示之间靠三个方向的转换函数连接，全部声明在
#src("source/blender/bmesh/intern/bmesh_mesh_convert.hh")：

```cpp
/* source/blender/bmesh/intern/bmesh_mesh_convert.hh:38（节选） */
/*
 * \brief Mesh -> BMesh
 * \warning This function doesn't calculate face normals.
 */
void BM_mesh_bm_from_me(BMesh *bm, const Mesh *mesh, const BMeshFromMeshParams *params)
    ATTR_NONNULL(1, 3);

/*
 * A version of #BM_mesh_bm_to_me intended for getting the mesh
 * to pass to the modifier stack for evaluation, ...
 */
void BM_mesh_bm_to_me_for_eval(BMesh &bm, Mesh &mesh, const CustomData_MeshMasks *cd_mask_extra);

void BM_mesh_bm_to_me_compact(BMesh &bm,
                              Mesh &mesh,
                              const CustomData_MeshMasks *mask,
                              bool add_mesh_attributes);
```

*反向有三个版本，这不是冗余，而是性能与语义的分工*：

#figure(
  kind: table,
  table(
    columns: (1.9fr, 3.0fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*用途*]),
    [`BM_mesh_bm_to_me`],
    [模式切换时用。保留 shape key、顶点父级、选择历史，
     并做昂贵的索引查找。可以合并进已有网格],
    [`BM_mesh_bm_to_me_for_eval`],
    [为修饰器求值 / 几何节点求值准备网格。
     *忽略 shape key、顶点父级、选择历史*，
     用 `CD_MASK_DERIVEDMESH` 而不是 `CD_MASK_MESH`，
     不支持与已有网格合并],
    [`BM_mesh_bm_to_me_compact`],
    [允许跳过数据层复制，或显式要求补上网格属性。
     用于"我知道不需要那些层"的高频路径],
  ),
  caption: [`BMesh` 转回 `Mesh` 的三个函数及其分工。选错会显著变慢或丢数据。],
) <tbl-bmesh-to-mesh>

`BM_mesh_bm_from_me()` 的 `\warning` 也要留意：*它不算面法线*。
如果你需要法线，要显式调 `BM_mesh_normals_update()` 之类的函数。
这个设计是为了让调用方在批量导入时只算法线一次。

=== 14.3.3 属性与 CustomData

`Mesh` 的"平铺数组"并不只有坐标。所有附加数据（UV、顶点色、顶点组权重、
自定义属性……）都放在 `CustomData` 层里。修饰器声明需求的方式就是
`required_data_mask()`：

```cpp
/* source/blender/modifiers/intern/MOD_wave.cc:100（节选） */
static void required_data_mask(ModifierData *md, CustomData_MeshMasks *r_cddata_masks)
{
  WaveModifierData *wmd = reinterpret_cast<WaveModifierData *>(md);

  /* ask for UV coordinates if we need them */
  if (wmd->texture && wmd->texmapping == MOD_DISP_MAP_UV) {
    r_cddata_masks->fmask |= CD_MASK_MTFACE;
  }

  /* Ask for vertex-groups if we need them. */
  if (wmd->defgrp_name[0] != '\0') {
    r_cddata_masks->vmask |= CD_MASK_MDEFORMVERT;
  }
}
```

`CustomData_MeshMasks` 有五个掩码位段：`vmask`（顶点）、`emask`（边）、
`fmask`（面）、`lmask`（角 loop）、`pmask`（面 corner 兼容字段）。
*按需申请是性能要求*：求值器会据此决定要不要把某一层从原始网格复制到求值网格。

#tip[
  写新修饰器时，最省事的做法是*先不实现 `required_data_mask`*（等于"我什么都不要"），
  运行一遍看看结果对不对。如果结果不对且怀疑缺层，
  再逐位加上去。反过来，一上来就把所有位都置满会让新修饰器在小网格上
  比同类内置修饰器慢好几倍，而且很难定位原因。
]

拿到层数据的方式是 `CustomData_get_layer_for_write()` 一类的函数
（示例见 #src("source/blender/blenkernel/intern/mesh_data_update.cc:154")），
顶点组则用 `MOD_get_vgroup()`（#src("source/blender/modifiers/intern/MOD_util.cc:158")）：

```cpp
/* source/blender/modifiers/intern/MOD_util.cc:158（节选） */
void MOD_get_vgroup(const Object *ob,
                    const Mesh *mesh,
                    const char *name,
                    const MDeformVert *dvert,
                    int *defgrp_index)
{
  if (mesh) {
    *defgrp_index = BKE_id_defgroup_name_index(&mesh->id, name);
    if (*defgrp_index != -1) {
      *dvert = mesh->deform_verts().data();
    }
    ...
  }
  ...
}
```

注意它的最后两个参数是*输出参数*，而不是返回值 ——
原因是"顶点组不存在"不是错误，而是一种正常状态（权重全为 0）。
`*defgrp_index == -1` 就表示没找到。

=== 14.3.4 `GeometrySet`：跨几何类型的容器

第 14.2 节提到几何节点的输入输出是 `GeometrySet`。它定义在
#src("source/blender/blenkernel/BKE_geometry_set.hh:151")，注释写得非常完整：

```cpp
/* source/blender/blenkernel/BKE_geometry_set.hh:132（注释原文） */
/*
 * A geometry set is a container for multiple kinds of geometry. It does not own geometry directly
 * itself, instead geometry is owned by multiple #GeometryComponents, and the geometry set
 * increases the user count of each component, so they avoid losing the data. This means
 * individual components might be shared between multiple geometries and other code. Shared
 * components are copied automatically when write access is requested.
 *
 * The components usually do not store data directly, but keep a reference to a data
 * structure defined elsewhere. There is at most one component of each type:
 *  - #MeshComponent
 *  - #CurveComponent
 *  - #PointCloudComponent
 *  - #InstancesComponent
 *  - #VolumeComponent
 *  - #GreasePencilComponent
 *
 * Copying a geometry set is a relatively cheap operation, because it does not copy the referenced
 * geometry components, so #GeometrySet can often be passed or moved by value.
 */
```

这段注释解释了四个设计决定：

1. *`GeometrySet` 不直接拥有几何*，它持有一组 `GeometryComponentPtr`
   （`ImplicitSharingPtr<GeometryComponent>`，
   #src("source/blender/blenkernel/BKE_geometry_set.hh:62")）。
   所以拷贝一个 `GeometrySet` 很便宜 —— 只是若干引用计数加一。
2. *每种类型最多一个组件*。存储是一个按组件类型索引的
   `std::array<GeometryComponentPtr, GEO_COMPONENT_TYPE_ENUM_SIZE>`
   （#src("source/blender/blenkernel/BKE_geometry_set.hh:153")）。
3. *共享组件在请求写访问时自动复制*。这个语义由
   `get_component_for_write()` 实现
   （#src("source/blender/blenkernel/BKE_geometry_set.hh:179")）。
4. *组件通常不直接存数据*，而是引用别处的数据结构。
   `MeshComponent` 引用一个 `Mesh`，如此类推。

这一切的基础是 `ImplicitSharingMixin`（`GeometryComponent` 的基类，
#src("source/blender/blenkernel/BKE_geometry_set.hh:69")）。
它和 DNA 里的 `ID` 引用计数不是一回事：`ID` 的引用计数要存盘、
要跨文件链接，而隐式共享只活在内存里，所以可以做得极轻。

*实用规则*：在几何节点的 `node_geo_exec` 里拿到的 `GeometrySet`
是"可写"的（`extract_input<GeometrySet>` 返回的是值拷贝，
见 #src("source/blender/nodes/geometry/nodes/node_geo_transform_geometry.cc:79")），
你可以放心地就地改它，最后 `set_output` 出去。
如果只想读，用 `get_component<MeshComponent>()`；
要写就用 `get_mesh_for_write()`。

== 14.4 实践：写一个简单修饰器 / 节点

前面三节讲的是"系统长什么样"。这一节是"你怎么往里加东西"。
我们做两个练习，一大一小：

- *14.4.1* 加一个完整的修饰器 `Wobble`（沿 Z 轴按正弦偏移顶点）；
- *14.4.2* 加一个几何节点 `Wobble`（做同样的事）。

两者加起来会碰到本章讲过的几乎所有机制：DNA、RNA、`ModifierTypeInfo`、
`bNodeType`、socket 声明、`NOD_REGISTER_NODE`、CMake。

#warn[
  这两个练习都要重新编译 Blender。第 2 章的构建环境是它们的前提。
  增量构建通常只需几分钟，但第一次请预留足够时间。
  另外：本章的代码为说明目的做了精简（去掉了注释、i18n 包装，
  以及这两个练习暂时用不到的边界检查），*不能直接粘贴进上游提交*。
]

=== 14.4.1 加一个修饰器：`Wobble`

要动的文件一共六个。先给出清单，再逐个说明。

#figure(
  kind: table,
  table(
    columns: (0.4fr, 2.4fr, 0.8fr, 1.8fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*序号*], [*文件*], [*动作*], [*关键点*]),
    [1], [#src("source/blender/makesdna/DNA_modifier_types.h")], [改],
    [加枚举值 + 加 DNA 结构],
    [2], [#src("source/blender/modifiers/MOD_modifiertypes.hh")], [改],
    [加一行 `extern`],
    [3], [`source/blender/modifiers/intern/MOD_wobble.cc`], [新建],
    [修饰器实现本体],
    [4], [#src("source/blender/modifiers/CMakeLists.txt")], [改],
    [`SRC` 里加一行],
    [5], [#src("source/blender/modifiers/intern/MOD_util.cc")], [改],
    [`modifier_type_init()` 里加一行],
    [6], [#src("source/blender/makesrna/intern/rna_modifier.cc")], [改],
    [加 `rna_def_modifier_wobble()` + 枚举项 + 调用它],
  ),
  caption: [新增一个修饰器要动的六个文件。第 1、6 步是"能被存盘 / 能被 Python 看见"的必要条件。],
) <tbl-new-modifier-files>

*第 1 步：加枚举值。* 在 #src("source/blender/makesdna/DNA_modifier_types.h:38")
的 `ModifierType` 末尾、`NUM_MODIFIER_TYPES` 之前追加：

```c
/* source/blender/makesdna/DNA_modifier_types.h:127 之后（新增） */
  eModifierType_GreasePencilTexture = 86,
  eModifierType_Wobble = 87,        /* 新增。只能追加在末尾 */
  NUM_MODIFIER_TYPES,
```

#pitfall[
  *绝对不要把新枚举值插在中间。* 这个枚举的每一个值都会写进 `.blend` 文件，
  插在中间会让所有旧文件里的修饰器类型集体错位 ——
  用户打开旧工程会发现"我的波浪修饰器变成了别的什么东西"。
  源码在枚举上方有明确警告：
  "TYPEDEF VALUES ARE WRITTEN IN FILES! SO DO NOT CHANGE!
  (ONLY ADD NEW ITEMS AT THE END)"
  （#src("source/blender/makesdna/DNA_modifier_types.h:34")）。
]

*同一步：加 DNA 结构。* 追加到文件末尾的
`}  // namespace blender` 之前（同文件:3525）：

```c
/* source/blender/makesdna/DNA_modifier_types.h（新增） */
/* Wobble modifier: Z 方向正弦偏移。 */
struct WobbleModifierData {
  ModifierData modifier;    /* 必须第一个 */
  float amplitude;          /* 振幅 */
  float frequency;          /* 频率 */
  float phase;              /* 相位 */
  char _pad[4];             /* 对齐填充，保证 4 字节对齐 */
};
```

*`ModifierData modifier` 必须在第一个位置*，理由见 §14.1.2。
`_pad` 不是必需的，但加了能让结构体大小整齐（多个 4 字节），
也便于之后插入新的 `float` 而不改变已有字段偏移。

DNA 头文件用 `struct Name { ... };` 的 C++ 风格即可 ——
`makesdna` 的解析器不要求 `typedef`，它只找 `struct` 关键字
（#src("source/blender/makesdna/intern/dna_parse.cc:665")）。

*第 2 步：声明类型信息。* 在 #src("source/blender/modifiers/MOD_modifiertypes.hh")
的 `extern` 列表里加一行（就近放在 `modifierType_Wireframe` 之后即可）：

```cpp
/* source/blender/modifiers/MOD_modifiertypes.hh（新增） */
extern ModifierTypeInfo modifierType_Wobble;
```

*第 3 步：写实现。* 新建
`source/blender/modifiers/intern/MOD_wobble.cc`：

```cpp
/* source/blender/modifiers/intern/MOD_wobble.cc（新增，示意，include 从略） */
#include <cmath>

#include "BKE_modifier.hh"
#include "DNA_modifier_types.h"
#include "RNA_prototypes.hh"
#include "UI_interface_layout.hh"

#include "MOD_modifiertypes.hh"
#include "MOD_ui_common.hh"

namespace blender {

static void init_data(ModifierData *md)
{
  WobbleModifierData *wmd = reinterpret_cast<WobbleModifierData *>(md);
  wmd->amplitude = 0.25f;
  wmd->frequency = 2.0f;
  wmd->phase = 0.0f;
}

static void deform_verts(ModifierData *md,
                         const ModifierEvalContext * /*ctx*/,
                         Mesh * /*mesh*/,
                         MutableSpan<float3> positions)
{
  const WobbleModifierData *wmd = reinterpret_cast<const WobbleModifierData *>(md);
  const float amp = wmd->amplitude;
  const float freq = wmd->frequency;
  const float phase = wmd->phase;

  for (const int i : positions.index_range()) {
    const float3 &co = positions[i];
    positions[i].z = co.z + amp * std::sin(co.x * freq + phase);
  }
}

static void panel_draw(const bContext * /*C*/, Panel *panel)
{
  ui::Layout &layout = *panel->layout;
  PointerRNA *ptr = modifier_panel_get_property_pointers(panel, nullptr);

  layout.use_property_split_set(true);
  layout.prop(ptr, "amplitude", UI_ITEM_NONE, std::nullopt, ICON_NONE);
  layout.prop(ptr, "frequency", UI_ITEM_NONE, std::nullopt, ICON_NONE);
  layout.prop(ptr, "phase", UI_ITEM_NONE, std::nullopt, ICON_NONE);

  modifier_error_message_draw(layout, ptr);
}

static void panel_register(ARegionType *region_type)
{
  modifier_panel_register(region_type, eModifierType_Wobble, panel_draw);
}

ModifierTypeInfo modifierType_Wobble = {
    /*idname*/ "Wobble",
    /*name*/ N_("Wobble"),
    /*struct_name*/ "WobbleModifierData",
    /*struct_size*/ sizeof(WobbleModifierData),
    /*srna*/ &RNA_WobbleModifier,
    /*type*/ ModifierTypeType::OnlyDeform,
    /*flags*/ eModifierTypeFlag_AcceptsMesh | eModifierTypeFlag_AcceptsVertexCosOnly |
        eModifierTypeFlag_SupportsEditmode,
    /*icon*/ ICON_MOD_WAVE,

    /*copy_data*/ BKE_modifier_copydata_generic,

    /*deform_verts*/ deform_verts,
    /*deform_matrices*/ nullptr,
    /*deform_verts_EM*/ nullptr,
    /*deform_matrices_EM*/ nullptr,
    /*modify_mesh*/ nullptr,
    /*modify_geometry_set*/ nullptr,

    /*init_data*/ init_data,
    /*required_data_mask*/ nullptr,
    /*free_data*/ nullptr,
    /*is_disabled*/ nullptr,
    /*update_depsgraph*/ nullptr,
    /*depends_on_time*/ nullptr,
    /*depends_on_normals*/ nullptr,
    /*foreach_ID_link*/ nullptr,
    /*foreach_tex_link*/ nullptr,
    /*free_runtime_data*/ nullptr,
    /*panel_register*/ panel_register,
    /*blend_write*/ nullptr,
    /*blend_read*/ nullptr,
    /*foreach_cache*/ nullptr,
    /*foreach_working_space_color*/ nullptr,
};

}  // namespace blender
```

这段代码和 #src("source/blender/modifiers/intern/MOD_wave.cc:404") 的
`modifierType_Wave` 是同一个模子。字段顺序*必须与
`BKE_modifier.hh` 里的声明顺序完全一致*（那是位置初始化，
不是指定初始化），所以推荐直接抄一个现有修饰器的初始化块再删改 ——
这也是上游审阅时常见的建议。

#tip[
  本例把 `foreach_ID_link` 填成 `nullptr`（不引用任何 ID）。
  如果你给 `WobbleModifierData` 加了纹理或物体指针，
  *一定要同时实现 `foreach_ID_link` 与 `update_depsgraph`*：
  前者的缺失会让引用计数悄悄出错，症状是"删掉被引用的物体后崩溃"；
  后者的缺失会让"改了被引用物体、修饰器不跟着更新"。
]

*第 4 步：加进构建。* 在 #src("source/blender/modifiers/CMakeLists.txt:113")
附近的 `SRC` 列表里按字母序插入一行：

```cmake
# source/blender/modifiers/CMakeLists.txt（新增）
  intern/MOD_wobble.cc
```

*忘记这一步的后果*：文件根本不被编译，`modifierType_Wobble` 未定义，
链接期报 `undefined reference to blender::modifierType_Wobble`。

*第 5 步：注册类型。* 在 `modifier_type_init()` 里加一行
（#src("source/blender/modifiers/intern/MOD_util.cc:204")，
宏定义在紧接着的下一行）：

```cpp
/* source/blender/modifiers/intern/MOD_util.cc（新增） */
  INIT_TYPE(Wobble);
```

*第 6 步：RNA。* 这一步决定 Python 能不能看见它。先写结构：

```cpp
/* source/blender/makesrna/intern/rna_modifier.cc（新增，示意） */
static void rna_def_modifier_wobble(BlenderRNA *brna)
{
  StructRNA *srna;
  PropertyRNA *prop;

  srna = RNA_def_struct(brna, "WobbleModifier", "Modifier");
  RNA_def_struct_ui_text(srna, "Wobble Modifier", "Z 方向正弦偏移");
  RNA_def_struct_sdna(srna, "WobbleModifierData");
  RNA_def_struct_ui_icon(srna, ICON_MOD_WAVE);

  prop = RNA_def_property(srna, "amplitude", PROP_FLOAT, PROP_DISTANCE);
  RNA_def_property_float_sdna(prop, nullptr, "amplitude");
  RNA_def_property_range(prop, 0.0f, 100.0f);
  RNA_def_property_ui_text(prop, "Amplitude", "偏移振幅");
  RNA_def_property_update(prop, 0, "rna_Modifier_update");

  prop = RNA_def_property(srna, "frequency", PROP_FLOAT, PROP_NONE);
  RNA_def_property_float_sdna(prop, nullptr, "frequency");
  RNA_def_property_range(prop, 0.0f, 100.0f);
  RNA_def_property_ui_text(prop, "Frequency", "空间频率");
  RNA_def_property_update(prop, 0, "rna_Modifier_update");

  prop = RNA_def_property(srna, "phase", PROP_FLOAT, PROP_ANGLE);
  RNA_def_property_float_sdna(prop, nullptr, "phase");
  RNA_def_property_ui_text(prop, "Phase", "相位");
  RNA_def_property_update(prop, 0, "rna_Modifier_update");
}
```

然后加三处引用：枚举项表里加一项
（#src("source/blender/makesrna/intern/rna_modifier.cc:44")）、
在 `RNA_def_modifier()` 里调用
`rna_def_modifier_wobble(brna)`（同文件:11547 起的一长串调用中），
最后确认 `RNA_WobbleModifier` 这个符号能生成 ——
它由 `makesrna` 从 `RNA_def_struct(brna, "WobbleModifier", "Modifier")`
自动生成到 `RNA_prototypes.hh`，*不需要手写*。

#tip[
  `RNA_def_property_update(prop, 0, "rna_Modifier_update")` 这一行是
  "改了参数之后要重新求值"的关键。漏掉它的症状很好认：
  滑杆能拖动、数值会变，但视口里网格纹丝不动，
  必须手动按别的东西才会刷新。凡是能从界面改的修饰器属性，
  都要加这一行。
]

*验证清单*：构建通过后依次确认五件事。

1. 属性编辑器 → 修改器 → 添加 → 菜单里有 "Wobble"。
   没有：查第 6 步的枚举项，以及 `eModifierTypeFlag_NoUserAdd` 有没有被误设。
2. 加上它之后，网格出现按 X 方向的正弦起伏。没有：查第 5 步，
   以及 `modifierType_Wobble` 的 `type` 是不是 `OnlyDeform`。
3. 面板里三个滑杆可用。没有：查 `panel_register` 与
   RNA 属性名是否*逐字符一致* —— 名字不一致不会报错，只会静默跳过。
4. 拖动滑杆时视口立即更新。没有：查 `RNA_def_property_update`。
5. Python 能访问：

```python
import bpy
ob = bpy.context.object
mod = ob.modifiers.new(name="Wobble", type='WOBBLE')
print(mod.amplitude, mod.frequency, mod.phase)
mod.amplitude = 0.5
```

报 `TypeError: enum "Modifier.type" not found in ('WOBBLE',)` 说明
第 6 步的枚举项没加；报 `AttributeError: 'Modifier' object has no
attribute 'amplitude'` 说明 `RNA_def_struct` 或 refine 链有问题。

=== 14.4.2 加一个几何节点：`Wobble`

几何节点的流程比修饰器短，因为 `NOD_REGISTER_NODE` 会自动把它挂进注册清单。

#figure(
  kind: table,
  table(
    columns: (0.4fr, 2.5fr, 0.8fr, 1.8fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*序号*], [*文件*], [*动作*], [*关键点*]),
    [1], [`source/blender/nodes/geometry/nodes/node_geo_wobble.cc`], [新建],
    [声明 + 执行 + 注册，一个文件搞定],
    [2], [#src("source/blender/nodes/geometry/CMakeLists.txt")], [改],
    [`SRC` 里加一行。*漏了就扫不到宏*],
    [3], [#src("source/blender/makesrna/intern/rna_nodetree.cc")], [一般不用改],
    [几何节点走自动 RNA 生成],
  ),
  caption: [新增一个几何节点只需动两个文件。第 3 行是它与修饰器的最大差别。],
) <tbl-new-node-files>

*第 1 步：写节点。* 新建
`source/blender/nodes/geometry/nodes/node_geo_wobble.cc`：

```cpp
/* source/blender/nodes/geometry/nodes/node_geo_wobble.cc（新增，示意） */
#include <cmath>

#include "BLI_math_vector_types.hh"

#include "BKE_mesh.hh"

#include "NOD_geometry.hh"
#include "NOD_geometry_exec.hh"
#include "NOD_register.hh"
#include "node_geometry_util.hh"

namespace blender::nodes::node_geo_wobble_cc {

static void node_declare(NodeDeclarationBuilder &b)
{
  b.add_input<decl::Geometry>("Geometry"_ustr);
  b.add_input<decl::Float>("Amplitude"_ustr)
      .default_value(0.25f)
      .min(0.0f)
      .subtype(PROP_DISTANCE)
      .description("偏移振幅");
  b.add_input<decl::Float>("Frequency"_ustr)
      .default_value(2.0f)
      .min(0.0f)
      .description("空间频率");
  b.add_output<decl::Geometry>("Geometry"_ustr);
}

static void node_geo_exec(GeoNodeExecParams params)
{
  GeometrySet geometry_set = params.extract_input<GeometrySet>("Geometry"_ustr);
  const float amplitude = params.extract_input<float>("Amplitude"_ustr);
  const float frequency = params.extract_input<float>("Frequency"_ustr);

  if (Mesh *mesh = geometry_set.get_mesh_for_write()) {
    MutableSpan<float3> positions = mesh->vert_positions_for_write();
    for (const int i : positions.index_range()) {
      const float3 &co = positions[i];
      positions[i].z = co.z + amplitude * std::sin(co.x * frequency);
    }
    mesh->tag_positions_changed();
  }

  params.set_output("Geometry"_ustr, std::move(geometry_set));
}

static void node_register()
{
  static bke::bNodeType ntype;

  geo_node_type_base(&ntype, "GeometryNodeWobble"_ustr);
  ntype.ui_name = "Wobble";
  ntype.ui_description = "沿 Z 轴按正弦偏移顶点";
  ntype.nclass = NODE_CLASS_GEOMETRY;
  ntype.declare = node_declare;
  ntype.geometry_node_execute = node_geo_exec;
  bke::node_register_type(ntype);
}
NOD_REGISTER_NODE(node_register)

}  // namespace blender::nodes::node_geo_wobble_cc
```

这段代码里每一行都有来历，逐条对照：

- *`geo_node_type_base(&ntype, "GeometryNodeWobble"_ustr)` 的第三个参数省略了*。
  这个参数的签名是 `std::optional<int16_t> legacy_type = std::nullopt`
  （#src("source/blender/nodes/geometry/node_geometry_util.hh:32")），
  省略时由 `get_next_auto_legacy_type()` 自动分配一个唯一值
  （#src("source/blender/blenkernel/intern/node.cc:5755")）。
  *所以新节点不需要去改 `BKE_node_legacy_types.hh`*，
  只有当你要和已有代码用旧整数类型比较时才需要显式指定。
- *`add_input<decl::Geometry>("Geometry"_ustr)` 没有给 `identifier`*，
  按 #src("source/blender/nodes/NOD_node_declaration.hh:763") 的规则，
  `identifier` 会自动取 `name`。所以后面 `extract_input` 里的字符串必须一致。
- *`min()` 与 `subtype()` 是给 UI 用的软约束*，
  和 `RNA_def_property_range()` 那种硬限制不同：软约束只影响滑杆的拖动范围，
  用户仍可手动输入超出范围的值。
- *取输入用 `extract_input<T>()`，它消费这个输入*（每个输入只能取一次，
  见 #src("source/blender/nodes/NOD_geometry_exec.hh:102")）。
  只读不改的场合用 `get_input<T>()`。
- *改坐标之后调 `mesh->tag_positions_changed()`*。
  这一点与修饰器路径不同：修饰器的包装层
  `BKE_modifier_deform_verts()` 替你调了
  （#src("source/blender/blenkernel/intern/modifier.cc:987")），
  而几何节点里没有任何人替你调。
  *漏掉它的症状是光照完全不对*：法线还是旧的。
- *`set_output` 用 `std::move`*。`GeometrySet` 的拷贝很便宜（§14.3.4），
  但 move 更便宜，源码里也一律这么写
  （#src("source/blender/nodes/geometry/nodes/node_geo_transform_geometry.cc:105")）。

*第 2 步：加进 CMake。* 在
#src("source/blender/nodes/geometry/CMakeLists.txt") 的 `SRC` 列表里
按字母序插入 `nodes/node_geo_wobble.cc`。

#pitfall[
  这一步是几何节点最经典的易错点。因为注册是靠 `discover_nodes.py`
  扫 `SRC` 里的文件生成的
  （#src("source/blender/nodes/geometry/CMakeLists.txt:383")），
  *文件不在 `SRC` 里，宏就扫不到，节点不会注册，而且没有任何报错*。
  编译完全成功，只是"添加"菜单里找不到 "Wobble"。
  遇到"节点写了但看不见"，第一件事就是确认 CMake 那一行。
]

*第 3 步：不需要手工 RNA。* 与修饰器不同，几何节点的 RNA 结构体
（`bpy.types.GeometryNodeWobble`）由 `makesrna` 根据
`RNA_def_struct(...)` 的注册自动建 —— 而这一步在
`node_type_base()` 里就完成了：

```cpp
/* source/blender/blenkernel/intern/node.cc:5779（节选） */
  if (!ELEM(*legacy_type, NODE_CUSTOM, NODE_UNDEFINED)) {
    StructRNA *srna = RNA_struct_find(ntype.idname.c_str());
    BLI_assert(srna != nullptr);
    ntype.rna_ext.srna = srna;
    RNA_struct_blender_type_set(srna, &ntype);
  }
```

*`RNA_struct_find(ntype.idname)` 按 `idname` 查 RNA 结构体*，
所以你的 `idname`（`"GeometryNodeWobble"`）必须在 RNA 侧存在。
`makesrna` 会自动为 `GeometryNode*` 生成这个结构，
命名规则就是 `idname` 本身 —— 这也是为什么几何节点的 `idname`
不能随便起名。

*验证清单*：构建通过后确认四件事。

1. 几何节点编辑器 → 添加 → 几何 → 有 "Wobble"。
   没有：几乎一定是第 2 步漏了。
2. 把它接到一个"网格立方体"后面，立方体出现正弦起伏；
   接"曲线"则不生效（因为代码里只处理 `MeshComponent`）。
3. 拖动 Amplitude 滑杆，视口实时更新。
4. 光照正确。如果网格看起来像被压扁的平面，说明
   `tag_positions_changed()` 没调到 —— 法线还是旧的。

#summary[
  加修饰器与加节点，成本差别很大：

  *修饰器的六步里，有四步是"接线"*（枚举值、`extern` 声明、
  `INIT_TYPE` 调用、RNA 三处引用）。真正写算法的只有 `MOD_wobble.cc`。
  修饰器是一个有几十年历史、层层加壳的机制。

  *节点只有两步*（新建 `.cc`、加 CMake），前提是你知道
  `NOD_REGISTER_NODE` 的存在。RNA 自动生成、注册清单自动汇总，
  新代码不需要碰任何中心文件。

  这不是"节点比修饰器更先进"，而是*修饰器到现在仍然是被大量
  旧代码依赖的稳定接口*，而节点从一开始就按模块化设计。
  写新东西时，如果能用节点解决，优先用节点。
]

#summary[
  本章的三条主线：

  *修饰器*：数据在 DNA，类型信息在 `blenkernel`，用 `md->type` 作下标
  连成一张定长数组。求值按 `ModifierTypeType` 分两段，
  连续的开头变形修饰器走快速通路。扩展点完全在 C++ 侧。

  *节点*：五套节点树共用 `bNodeType` 与 DNA，差别在注册清单与求值回调。
  socket 分实例 / 类型 / 声明三层，`declare` 回调负责生成接口。
  几何节点的注册靠 `NOD_REGISTER_NODE` + 构建期脚本，
  所以"文件加进 CMake"这一步是必须的。

  *几何*：`Mesh` 面向存储与吞吐，`BMesh` 面向拓扑操作，
  两者由三个方向的转换函数连接。附加数据全在 `CustomData` 里，
  按需用 `required_data_mask()` 申请。跨类型几何用 `GeometrySet` 传递，
  它是廉价可拷贝的引用容器。
]

#exercise[
  *练习 14.1（读源码）* 打开 #src("source/blender/modifiers/intern/MOD_smooth.cc")，
  回答：（a）它的 `ModifierTypeType` 是什么，为什么？（b）它申请了哪些
  CustomData 层？（c）它在哪个函数里分配和释放内存，用的是什么 API？
  （提示：注意第 71、76、162、163 行。第 10 章讲过 5.2 里正确的分配 API。）

  *练习 14.2（读源码）* 找出所有 `ModifierTypeType::NonGeometrical`
  的内置修饰器。提示：在 #src("source/blender/modifiers/intern/") 下搜这个枚举。
  对每一个回答：它改了哪个 CustomData 层？为什么它不算
  `Nonconstructive`？（提示：看 `BKE_modifier_is_non_geometrical()`
  在 #src("source/blender/blenkernel/intern/modifier.cc:410") 的实现，
  以及它的调用者。）

  *练习 14.3（读源码）* `BKE_modifier_deform_verts()` 有一条兜底路径：
  当 `deform_verts` 为空而 `modify_geometry_set` 非空时，
  它会构造一个 `GeometrySet` 然后调 `modify_geometry_set`
  （#src("source/blender/blenkernel/intern/modifier.cc:991")）。
  读完整段代码，回答：（a）它在调用前后分别做了什么检查？
  （b）如果修饰器改变了拓扑，它会怎么做？
  （c）举出一个实际依赖这条路径的内置修饰器。
  提示：看 #src("source/blender/modifiers/intern/MOD_nodes.cc") 的类型信息。

  *练习 14.4（动手，小）* 给 §14.4.2 的 `Wobble` 节点加一个
  `decl::Bool` 输入 `"Along Normal"`，为真时沿顶点法线偏移而不是沿 Z 轴。
  要求：（a）用 `mesh->vert_normals()` 取法线；
  （b）为真时是纯变形，为假时结果与原来一致；
  （c）用 `.description()` 给这个 socket 加上提示文字，
  确认鼠标悬停时能看到。

  *练习 14.5（动手，中等）* 把 §14.4.2 的节点改造成一个
  *字段式* 节点：把 `Amplitude` 的声明改成
  `b.add_input<decl::Float>("Amplitude"_ustr).structure_type(StructureType::Field)`，
  然后用 `params.extract_input<Field<float>>("Amplitude"_ustr)` 取值。
  提示：字段需要绑定到几何上求值，参考
  #src("source/blender/nodes/geometry/nodes/node_geo_set_position.cc:130")
  到 #src("source/blender/nodes/geometry/nodes/node_geo_set_position.cc:163")
  的做法。完成后验证：把"位置"节点的 Z 输出接到 Amplitude 上，
  起伏幅度应随位置变化。

  *练习 14.6（动手，进阶）* 完整实现 §14.4.1 的 `Wobble` 修饰器，
  并做三项额外工作：
  （a）实现 `deform_verts_EM` 让它支持编辑模式，
  参考 #src("source/blender/modifiers/intern/MOD_wave.cc:278") 附近的写法；
  （b）实现 `update_depsgraph`，让振幅可以来自另一个物体的变换
  （提示：`DEG_add_object_relation` 与
  `MOD_depsgraph_update_object_bone_relation`，
  后者在 #src("source/blender/modifiers/intern/MOD_util.cc:188")）；
  （c）实现 `blend_write` / `blend_read`，如果你给结构体加了
  动态分配的数组。三步都做完后，用 `--debug-memory` 启动
  （第 10 章）确认退出时没有泄漏报告。
]
