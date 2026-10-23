#import "../common.typ": *
#import "../figures/editor-hierarchy.typ": fig-editor-hierarchy

= 第 12 章 编辑器与 UI

第 11 章讲的是"用户按下一个键之后代码怎么执行"。但按钮和菜单栏本身画在哪里？
谁决定 3D 视口上方那一行的高度、谁决定按 <kbd>N</kbd> 冒出来的右侧栏里有哪些面板？
答案在本章。

本章要建立的核心认识是一句话：*Blender 的界面是"数据 + 类型表"两层结构*。
数据层（`bScreen` / `ScrArea` / `ARegion`）描述"这一块矩形是什么、有多大、
属于哪个编辑器"，定义在 `makesdna`（要存进 `.blend`）；
类型层（`SpaceType` / `ARegionType` / `PanelType` / `HeaderType`）描述
"这类编辑器能做哪些事、由哪些回调实现"，定义在 `blenkernel` 与 `editors`（纯运行时）。
理解这两层之后，"新增一个编辑器"就变成一个可照做的清单 —— 这正是 12.5 的内容。

== 12.1 `SpaceType` / `ScrArea` / `ARegion` 层级

=== 12.1.1 四个层次

把一个窗口从外往内拆，会依次经过四层：

#figure(
  kind: table,
  table(
    columns: (1fr, 1.2fr, 1.4fr, 2.4fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层次*], [*数据层*], [*类型层*], [*说明*]),
    [窗口], [`wmWindow`], [`wmWindowManager`], [一个操作系统窗口，含 1 个屏幕],
    [屏幕], [`bScreen`], [—], [ID 类型 `ID_SCR`，可存进 `.blend`；`areabase` 是区域表],
    [区域], [`ScrArea`], [`SpaceType`], [用户看到的"一个编辑器格子"，如 3D 视口、大纲视图],
    [区块], [`ARegion`], [`ARegionType`], [格子内部的一条或一块，如头部、侧栏、主窗口],
    [界面元素], [`ui::Block` / `uiBut`], [`PanelType` / `HeaderType`], [按钮、滑杆、面板标题栏],
  ),
  caption: [界面的四个层次。每层都有自己的"数据"和"类型"两半。],
) <tbl-ui-layers>

本书统一按 Blender 官方中文界面的说法：`ScrArea` 叫 *编辑器区域*（代码里也直接
叫 area），`ARegion` 叫 *区块*。一个 `ScrArea` 里通常有 2 到 9 个 `ARegion`。

#figure(fig-editor-hierarchy(), caption: [`SpaceType` / `ScrArea` / `ARegion` 层级图。上半是运行时数据（一个 `bScreen` 切成三个 `ScrArea`，每个 area 里堆叠若干 `ARegion`）；下半是类型层：`ScrArea.type` 指向 `SpaceType`，`SpaceType.regiontypes` 串起 `ARegionType`，后者再串起 `PanelType` 与 `HeaderType`。]) <fig-editor-hierarchy>

=== 12.1.2 `ScrArea`：用户看到的"一个编辑器格子"

`ScrArea` 定义在 #src("source/blender/makesdna/DNA_screen_types.h:610")。
它是 DNA 结构，关键字段如下（其余从略）：

```c
/* source/blender/makesdna/DNA_screen_types.h:610（节选） */
struct ScrArea {
  ScrVert *v1, *v2, *v3, *v4;   /* 有序：左下、左上、右上、右下 */
  bScreen *full;                /* area == full 时的父屏幕 */
  rcti totrct;                  /* 由 v1..v4 围出的矩形（缓存） */

  char spacetype;               /* eSpace_Type（SPACE_FOO） */
  char butspacetype;            /* 切换编辑器期间的临时值，平时应为 SPACE_EMPTY */
  short butspacetype_subtype;
  short winx, winy;             /* 尺寸 */
  ...
  struct SpaceType *type;       /* 运行时指针，不存盘 */
  ...
  ListBaseT<SpaceLink> spacedata;   /* 在这个 area 里打开过的编辑器数据 */
  ListBaseT<ARegion> regionbase;    /* 只属于当前可见的那个编辑器 */
  ...
  ScrArea_Runtime runtime;
};
```

四点值得注意：

- *几何是"顶点 + 边"定义的*。`ScrArea` 不存矩形坐标，而是引用四个 `ScrVert`，
  分割线是 `ScrEdge`；`bScreen` 因此有 `vertbase` / `edgebase` / `areabase`
  三张表（#src("source/blender/makesdna/DNA_screen_types.h:106")）。
  拖动分割线只需移动顶点，相邻格子的矩形自动重算。
- *`spacetype` 是 `char`*，取值是 `eSpace_Type`（
  #src("source/blender/makesdna/DNA_space_enums.h:1151")）。枚举注释写着
  `Do NOT change order, append on end` —— 数值会存进 `.blend`，改顺序等于
  破坏所有旧文件。
- *`spacedata` 是列表而非单个指针*。切换编辑器时旧数据留在表里，切回来优先复用
  （#src("source/blender/makesdna/DNA_screen_types.h:658")）。
- *`regionbase` 只属于当前可见的编辑器*。源码注释明确警告：要用
  `SpaceLink.regionbase` 才是"非活动编辑器"的区块表
  （#src("source/blender/makesdna/DNA_screen_types.h:664")）。这是常见的易错点。
- *`type` 不存盘*，运行时指向注册表里的 `SpaceType`。

=== 12.1.3 `ARegion`：格子内部的一条或一块

`ARegion` 在 #src("source/blender/makesdna/DNA_screen_types.h:809")，
`regiontype` 取值是 `eRegion_Type`（#src("source/blender/makesdna/DNA_screen_types.h:680")），
同样"顺序不能改，只能追加"：

```c
/* source/blender/makesdna/DNA_screen_types.h:680（节选，只列常用项） */
enum eRegion_Type : short {
  RGN_TYPE_WINDOW = 0,        /* 主工作区 */
  RGN_TYPE_HEADER = 1,        /* 顶部菜单栏 */
  RGN_TYPE_CHANNELS = 2,
  RGN_TYPE_TEMPORARY = 3,
  RGN_TYPE_UI = 4,            /* 右侧属性栏 */
  RGN_TYPE_TOOLS = 5,         /* 左侧工具栏 / 数据集栏 */
  RGN_TYPE_TOOL_PROPS = 6,
  RGN_TYPE_PREVIEW = 7,
  RGN_TYPE_HUD = 8,
  RGN_TYPE_NAV_BAR = 9,
  RGN_TYPE_EXECUTE = 10,
  RGN_TYPE_FOOTER = 11,
  RGN_TYPE_TOOL_HEADER = 12,
  RGN_TYPE_XR = 13,
  RGN_TYPE_ASSET_SHELF = 14,
  RGN_TYPE_ASSET_SHELF_HEADER = 15,
  RGN_TYPE_SCRUBBING = 16,
};
```

`RGN_TYPE_XR` 的注释说明它*不是一个真实可见区域*，只是给内部代码与插件
注册 XR 绘制回调用的（#src("source/blender/makesdna/DNA_screen_types.h:696")）。

区块的另外两组字段：`alignment`（#src("source/blender/makesdna/DNA_screen_types.h:827")）
决定贴哪条边，取值 `RGN_ALIGN_TOP` / `_BOTTOM` / `_LEFT` / `_RIGHT` / `_FLOAT` /
`_QSPLIT` 等（#src("source/blender/makesdna/DNA_screen_types.h:717")）；
`runtime->type`（#src("source/blender/blenkernel/BKE_screen.hh:514")）指向
`ARegionType`，绘制时就是通过它调回调的：

```cpp
/* source/blender/editors/screen/area.cc:488（节选） */
void ED_region_do_draw(bContext *C, ARegion *region)
{
  ScrArea *area = CTX_wm_area(C);
  ARegionType *at = region->runtime->type;
  ...
  ui::theme::theme_set(area ? area->spacetype : 0, at->regionid);
  ...
  else if (at->draw) {
    at->draw(C, region);
  }
  ...
}
```

*每个区块的像素都由它自己的 `ARegionType::draw` 回调画出来*。你写编辑器，
本质上就是写这个回调。

=== 12.1.4 四个类型结构

四个类型结构都在 #src("source/blender/blenkernel/BKE_screen.hh")。
`SpaceType`（#src("source/blender/blenkernel/BKE_screen.hh:100")）按用途分组：

```cpp
/* source/blender/blenkernel/BKE_screen.hh:100（节选） */
struct SpaceType {
  char name[BKE_ST_MAXNAME];   /* BKE_ST_MAXNAME = 64，见同文件:90 */
  int spaceid;                 /* 即 eSpace_Type 里的 SPACE_xxx */
  int iconid;

  /* 生命周期 */
  SpaceLink *(*create)(const ScrArea *area, const Scene *scene);
  void (*free)(SpaceLink *sl);            /* 不释放 spacelink 本身 */
  void (*init)(wmWindowManager *wm, ScrArea *area);
  void (*exit)(wmWindowManager *wm, ScrArea *area);
  void (*listener)(const wmSpaceTypeListenerParams *params);
  void (*refresh)(const bContext *C, ScrArea *area);
  SpaceLink *(*duplicate)(SpaceLink *sl);

  /* 启动时各执行一次的注册期回调 */
  void (*operatortypes)();
  void (*keymap)(wmKeyConfig *keyconf);
  void (*dropboxes)();
  void (*gizmos)();

  bContextDataCallback context;
  void (*id_remap)(ScrArea *area, SpaceLink *sl, const bke::id::IDRemapper &mappings);
  void (*foreach_id)(SpaceLink *space_link, LibraryForeachIDData *data);

  /* 子类型（同一 SpaceType 的多种形态） */
  int (*space_subtype_get)(ScrArea *area);
  void (*space_subtype_set)(ScrArea *area, int value);
  void (*space_subtype_item_extend)(bContext *C, EnumPropertyItem **item, int *totitem);
  StringRefNull (*space_name_get)(const ScrArea *area);
  int (*space_icon_get)(const ScrArea *area);

  /* 文件读写 */
  void (*blend_read_data)(BlendDataReader *reader, SpaceLink *space_link);
  void (*blend_read_after_liblink)(BlendLibReader *reader, ID *parent_id, SpaceLink *space_link);
  void (*blend_write)(BlendWriter *writer, SpaceLink *space_link);

  ListBaseT<ARegionType> regiontypes;   /* 区域类型定义 */
  int keymapflag;
  ~SpaceType();
};
```

`space_subtype` 不是字段而是五个回调，用途是*让同一个 `SpaceType` 呈现为多个
可选形态*。代码库里用到这套回调的恰好五个编辑器：

#figure(
  kind: table,
  table(
    columns: (1.2fr, 1.3fr, 2.6fr),
    inset: 5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*编辑器*], [*子类型存于*], [*`space_subtype_*` 赋值行*]),
    [`SPACE_IMAGE`], [`SpaceImage::mode`], [#src("source/blender/editors/space_image/space_image.cc:1333")],
    [`SPACE_GRAPH`], [`SpaceGraph::mode`], [#src("source/blender/editors/space_graph/space_graph.cc:999")],
    [`SPACE_NODE`], [`SpaceNode::tree_type`], [#src("source/blender/editors/space_node/space_node.cc:1735")],
    [`SPACE_ACTION`], [`SpaceAction::mode`], [#src("source/blender/editors/space_action/space_action.cc:977")],
    [`SPACE_FILE`], [`SpaceFile::browse_mode`], [#src("source/blender/editors/space_file/space_file.cc:1030")],
  ),
  caption: [使用 `space_subtype_*` / `space_name_get` / `space_icon_get` 的五个编辑器。],
) <tbl-space-subtype-users>

以图像编辑器为例：`image_space_name_get` 查 `rna_enum_space_image_mode_items`
拿到当前模式的显示名，于是类型下拉里显示的是 *"Image Editor: Paint"* 而不是
干巴巴的 "Image Editor"，图标也跟着变：

```cpp
/* source/blender/editors/space_image/space_image.cc:1280（节选） */
static StringRefNull image_space_name_get(const ScrArea *area)
{
  SpaceImage *sima = static_cast<SpaceImage *>(area->spacedata.first);
  int index = RNA_enum_from_value(rna_enum_space_image_mode_items, sima->mode);
  if (index < 0) {
    index = SI_MODE_VIEW;
  }
  const EnumPropertyItem item = rna_enum_space_image_mode_items[index];
  return item.name;
}
```

#note[
  属性编辑器（`SPACE_PROPERTIES`）*不使用*这套回调。它的十来个标签页
  （渲染 / 输出 / 场景 / 世界 / 物体 / 修改器 …）由
  `rna_enum_buttons_context_items` 与 `SpaceProperties::visible_tabs` 驱动。
  不要因为"属性编辑器看起来最像子类型"就去 `space_buttons.cc` 里找
  `space_subtype_get` —— 那里没有。
]

`ARegionType`（#src("source/blender/blenkernel/BKE_screen.hh:249")）：

```cpp
/* source/blender/blenkernel/BKE_screen.hh:249（节选） */
struct ARegionType {
  int regionid;                             /* RGN_TYPE_xxxx */

  void (*init)(wmWindowManager *wm, ARegion *region);
  void (*exit)(wmWindowManager *wm, ARegion *region);
  bool (*poll)(const RegionPollParams *params);
  void (*draw)(const bContext *C, ARegion *region);
  void (*draw_overlay)(const bContext *C, ARegion *region);
  void (*layout)(const bContext *C, ARegion *region);   /* 只算布局，不画 */
  int (*snap_size)(const ARegion *region, int size, int axis);
  void (*listener)(const wmRegionListenerParams *params);
  void (*free)(ARegion *);
  void *(*duplicate)(void *poin);
  void (*cursor)(wmWindow *win, ScrArea *area, ARegion *region);
  bContextDataCallback context;
  void (*on_poll_success)(const bContext *C, ARegion *region);
  void (*on_user_resize)(const ARegion *region);
  void (*on_view2d_changed)(const bContext *C, ARegion *region);

  ARegionTypeFlag flag;
  ListBaseT<RegionDrawCB> drawcalls;    /* 自定义绘制回调 */
  ListBaseT<PanelType> paneltypes;
  ListBaseT<HeaderType> headertypes;

  int minsizex, minsizey;
  int prefsizex, prefsizey;             /* 区块首次出现的默认尺寸 */
  int keymapflag;
  short do_lock, lock;
};
```

`layout` 与 `draw` 的分工是编辑器 UI 的关键：`layout` 只*构建按钮结构*
（创建 `ui::Block` / `uiBut`），`draw` 才*渲染像素*。分开是为了让布局结果可缓存 ——
鼠标 hover 高亮不必再次执行 `layout`。几乎所有"面板型"区块都直接把这两个回调指到框架：

```cpp
/* source/blender/editors/space_spreadsheet/space_spreadsheet.cc:842（节选） */
art->init = spreadsheet_sidebar_init;
art->layout = ED_region_panels_layout;   /* ED_screen.hh:135 */
art->draw = ED_region_panels_draw;       /* ED_screen.hh:136 */
```

`PanelType`（#src("source/blender/blenkernel/BKE_screen.hh:349")）：

```cpp
/* source/blender/blenkernel/BKE_screen.hh:349（节选） */
struct PanelType {
  char idname[BKE_ST_MAXNAME];
  char label[BKE_ST_MAXNAME];
  const char *description;
  char category[BKE_ST_MAXNAME];      /* 用于区块级标签页 */
  char owner_id[128];                 /* 工作区选择性显示 */
  char parent_id[BKE_ST_MAXNAME];     /* 子面板 */
  short space_type;
  short region_type;
  int order;                          /* 同级排序权重 */
  int flag;

  bool (*poll)(const bContext *C, PanelType *pt);
  void (*draw_header)(const bContext *C, Panel *panel);
  void (*draw_header_preset)(const bContext *C, Panel *panel);
  void (*draw)(const bContext *C, Panel *panel);
  void (*listener)(const wmRegionListenerParams *params);

  PanelType *parent;
  ListBaseT<LinkData> children;
  ExtensionRNA rna_ext;
};
```

`PanelType::flag`（#src("source/blender/blenkernel/BKE_screen.hh:425")）里有三个常用值：
`PANEL_TYPE_DEFAULT_CLOSED`（默认折叠）、`PANEL_TYPE_NO_HEADER`（不画标题栏）、
`PANEL_TYPE_INSTANCED`（由列表驱动的实例化面板）。

`HeaderType`（#src("source/blender/blenkernel/BKE_screen.hh:619")）只有五个字段：

```cpp
/* source/blender/blenkernel/BKE_screen.hh:619 */
struct HeaderType {
  HeaderType *next, *prev;
  char idname[BKE_ST_MAXNAME];
  int space_type;
  int region_type;

  bool (*poll)(const bContext *C, HeaderType *ht);
  void (*draw)(const bContext *C, Header *header);

  ExtensionRNA rna_ext;
};
```

=== 12.1.5 注册表：一个函数局部静态 `Vector`

类型层不是硬编码的，而是运行时构建的（#src("source/blender/blenkernel/intern/screen.cc:299")）：

```cpp
/* source/blender/blenkernel/intern/screen.cc:299 */
/** Keep global; this has to be accessible outside of window-manager. */
static Vector<std::unique_ptr<SpaceType>> &get_space_types()
{
  static Vector<std::unique_ptr<SpaceType>> space_types;
  return space_types;
}
```

围绕它的全部 API：

#figure(
  kind: table,
  table(
    columns: (1.8fr, 1.3fr, 1.5fr, 3fr),
    inset: 5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*声明*], [*实现*], [*作用*]),
    [`BKE_spacetype_from_id`], [#src("BKE_screen.hh:760")], [#src("intern/screen.cc:340")], [按 `spaceid` 线性查找 `SpaceType*`],
    [`BKE_regiontype_from_id`], [#src("BKE_screen.hh:761")], [#src("intern/screen.cc:350")], [在给定 `SpaceType` 内按 `regionid` 查 `ARegionType*`],
    [`BKE_spacetypes_list`], [#src("BKE_screen.hh:762")], [#src("intern/screen.cc:360")], [返回只读列表，供遍历注册操作符 / 快捷键 / dropbox],
    [`BKE_spacetype_register`], [#src("BKE_screen.hh:763")], [#src("intern/screen.cc:365")], [追加 `SpaceType`；重复 `spaceid` 打印错误并拒绝],
    [`BKE_spacetype_exists`], [#src("BKE_screen.hh:764")], [#src("intern/screen.cc:377")], [判存在],
    [`BKE_spacetypes_free`], [#src("BKE_screen.hh:766")], [#src("intern/screen.cc:335")], [退出时清空],
  ),
  caption: [`SpaceType` 注册表的全部 API。声明都在 #src("source/blender/blenkernel/BKE_screen.hh")。],
) <tbl-spacetype-api>

`BKE_spacetype_register` 只有 11 行，但三件事都在里面：

```cpp
/* source/blender/blenkernel/intern/screen.cc:365 */
void BKE_spacetype_register(std::unique_ptr<SpaceType> st)
{
  /* sanity check */
  SpaceType *stype = BKE_spacetype_from_id(st->spaceid);
  if (stype) {
    printf("error: redefinition of spacetype %s\n", stype->name);
    return;
  }

  get_space_types().append(std::move(st));
}
```

1. *所有权*。传 `std::unique_ptr<SpaceType>`，注册表接管。
   因为 `SpaceType` 有非平凡析构（#src("source/blender/blenkernel/intern/screen.cc:306")
   负责释放 `regiontypes`、面板的 RNA 扩展、`drawcalls` 等）。
2. *重复注册被静默拒绝*，只在 stderr 打印一行。所以"我加了编辑器但菜单里没有"
   最常见的原因就是 `spaceid` 撞车。
3. *没有反注册入口*。这正是第 0 章"扩展点是封闭的"的具体体现，也是
   Python 无法注册新编辑器的根本原因 —— 它没有能调用这个函数的入口。

注册时机在启动序列里（#src("source/blender/windowmanager/intern/wm_init_exit.cc:230")）：

```cpp
/* source/blender/windowmanager/intern/wm_init_exit.cc:228（节选） */
  BKE_spacedata_callback_id_remap_set(ED_spacedata_id_remap_single);
  DEG_editors_set_update_cb(ED_render_id_flush_update, ED_render_scene_update);

  ED_spacetypes_init();
```

`ED_spacetypes_init()`（#src("source/blender/editors/space_api/spacetypes.cc:63")）
先调 19 个注册函数，再注册全屏幕级与各编辑器的操作符类型，最后遍历注册表：

```cpp
/* source/blender/editors/space_api/spacetypes.cc:141（节选） */
  /* Register types for operators and gizmos. */
  for (const std::unique_ptr<SpaceType> &type : BKE_spacetypes_list()) {
    /* Initialize gizmo types first, operator types need them. */
    if (type->gizmos) {
      type->gizmos();
    }
    if (type->operatortypes) {
      type->operatortypes();
    }
  }
```

这解释了 `SpaceType::operatortypes` 的注释为什么写 "Register operator types on
startup"（#src("source/blender/blenkernel/BKE_screen.hh:132")）—— 它只在启动时执行一次。

#pitfall[
  `SpaceType` 的回调分两类：*注册期回调*（`operatortypes` / `keymap` / `dropboxes` /
  `gizmos`）在启动时各执行一次；*运行期回调*（`create` / `init` / `listener` /
  `refresh` / `blend_write` 等）在对应事件发生时执行。把需要每帧更新的逻辑写进
  `operatortypes`，它永远不会执行第二次。
]

== 12.2 `ED_` 编辑器 API 概览

=== 12.2.1 `ED_` 前缀的三层分工

`source/blender/editors/` 对外导出的符号都以 `ED_` 开头，但内部有三层：

#figure(
  kind: table,
  table(
    columns: (1.2fr, 2.6fr, 2.4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*代表符号*], [*谁调用*]),
    [编辑器类型注册],
    [18 个 `ED_spacetype_*()` + `spreadsheet::register_spacetype()`],
    [只由 `ED_spacetypes_init()` 调用，见 #src("source/blender/editors/space_api/spacetypes.cc:70")],
    [屏幕与区块管理],
    [`ED_region_panels_layout` / `ED_region_panels_draw` / `ED_region_header` / `ED_area_tag_redraw` / `ED_region_tag_redraw`],
    [各编辑器实现；声明在 #src("source/blender/editors/include/ED_screen.hh")],
    [领域逻辑],
    [`ED_object_*` / `ED_mesh_*` / `ED_anim_*` / `ED_uvedit_*` …],
    [操作符实现、Python API、其他模块],
  ),
  caption: [`ED_` 前缀的三层分工。写编辑器主要用前两层。],
) <tbl-ed-layers>

=== 12.2.2 全部 19 处 `SpaceType` 注册

Blender #blender-version 里 `BKE_spacetype_register(std::move(st))` 恰好 19 次，
全在 `source/blender/editors/space_*/space_*.cc`：

#figure(
  kind: table,
  table(
    columns: (2.0fr, 1.7fr, 1.3fr, 2.0fr, 1.7fr, 1.3fr),
    inset: 4pt,
    align: (left, left, left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*文件*], [*注册函数*], [*`:行`*], [*文件*], [*注册函数*], [*`:行`*]),
    [`action/space_action.cc`], [`ED_spacetype_action`], [1052], [`outliner/space_outliner.cc`], [`ED_spacetype_outliner`], [702],
    [`buttons/space_buttons.cc`], [`ED_spacetype_buttons`], [1163], [`script/space_script.cc`], [`ED_spacetype_script`], [217],
    [`clip/space_clip.cc`], [`ED_spacetype_clip`], [1332], [`sequencer/space_sequencer.cc`], [`ED_spacetype_sequencer`], [1332],
    [`console/space_console.cc`], [`ED_spacetype_console`], [393], [`spreadsheet/space_spreadsheet.cc`], [`register_spacetype`], [863],
    [`file/space_file.cc`], [`ED_spacetype_file`], [1110], [`statusbar/space_statusbar.cc`], [`ED_spacetype_statusbar`], [162],
    [`graph/space_graph.cc`], [`ED_spacetype_ipo`], [1071], [`text/space_text.cc`], [`ED_spacetype_text`], [509],
    [`image/space_image.cc`], [`ED_spacetype_image`], [1437], [`topbar/space_topbar.cc`], [`ED_spacetype_topbar`], [334],
    [`info/space_info.cc`], [`ED_spacetype_info`], [294], [`userpref/space_userpref.cc`], [`ED_spacetype_userpref`], [466],
    [`nla/space_nla.cc`], [`ED_spacetype_nla`], [743], [`view3d/space_view3d.cc`], [`ED_spacetype_view3d`], [1727],
    [`node/space_node.cc`], [`ED_spacetype_node`], [1832], [—], [—], [—],
  ),
  caption: [全部 19 处 `SpaceType` 注册。路径省略了公共前缀 `source/blender/editors/space_`；每处的 `spaceid` 依次为 `SPACE_ACTION`、`SPACE_PROPERTIES`、`SPACE_CLIP`、`SPACE_CONSOLE`、`SPACE_FILE`、`SPACE_GRAPH`、`SPACE_IMAGE`、`SPACE_INFO`、`SPACE_NLA`、`SPACE_NODE`、`SPACE_OUTLINER`、`SPACE_SCRIPT`、`SPACE_SEQ`、`SPACE_SPREADSHEET`、`SPACE_STATUSBAR`、`SPACE_TEXT`、`SPACE_TOPBAR`、`SPACE_USERPREF`、`SPACE_VIEW3D`。声明在 #src("source/blender/blenkernel/BKE_screen.hh:763")。],
) <tbl-spacetype-registrations>

三个细节：

- *命名不统一*。18 个叫 `ED_spacetype_xxx()`，只有电子表格叫 `register_spacetype()`
  （#src("source/blender/editors/space_spreadsheet/space_spreadsheet.cc:774")），
  因为它在 `blender::ed::spreadsheet` 命名空间里。而 `space_graph` 的注册函数叫
  `ED_spacetype_ipo` —— `ipo` 是 Ipo 曲线的历史遗留名。*不要靠命名推断行为，
  要看 `st->spaceid`*。
- *`space_script` 注册的是已废弃编辑器*。`SPACE_SCRIPT = 14` 在枚举里带着
  `/* Deprecated */`（#src("source/blender/makesdna/DNA_space_enums.h:1169")），
  但注册代码还在。所以"19 个注册"不等于"19 个用户可见编辑器"。
- *区块数差异极大*（按 `art->regionid` 统计）：`Sequencer` 注册 9 个区块、
  `View3D` 8 个、`Image` 7 个；而 `StatusBar` 只注册 1 个（`RGN_TYPE_HEADER`），
  `Console` / `Info` / `Outliner` / `Script` / `TopBar` 各 2 个
  （`WINDOW` + `HEADER`）。`Sequencer` 那 9 个是
  `WINDOW`、`PREVIEW`、`UI`、`TOOLS`、`CHANNELS`、`TOOL_HEADER`、`HEADER`、
  `FOOTER`、`SCRUBBING`；`View3D` 那 8 个是
  `WINDOW`、`UI`、`TOOLS`、`TOOL_HEADER`、`HEADER`、`ASSET_SHELF`、
  `ASSET_SHELF_HEADER`、`XR`。

#tip[
  想学"最小结构"就看区块少的（`StatusBar`、`Info`、`Console`）；想学"复杂区块协作"
  就看区块多的（`Sequencer`、`View3D`）。而 *`Spreadsheet` 是信息密度最高的样板* ——
  它只有 5 个区块（`WINDOW`、`HEADER`、`FOOTER`、`UI`、`TOOLS`），却把五类区块一个不缺
  地覆盖了，所以本章 12.5 用它当蓝本。
]

=== 12.2.3 屏幕与区块级 API

#figure(
  kind: table,
  table(
    columns: (2.3fr, 0.7fr, 3.6fr),
    inset: 5pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*作用*]),
    [`ED_region_panels_init`], [108], [区块初始化：建立 `ui::Block` 容器与滚动状态],
    [`ED_region_panels_layout`], [135], [执行所有 `PanelType::poll` 与 `draw_header`，生成布局],
    [`ED_region_panels_draw`], [136], [把上一步的布局渲染出来],
    [`ED_region_header_init`], [138], [头部区块初始化],
    [`ED_region_header`], [139], [一步完成头部的布局 + 绘制],
    [`ED_region_header_layout` / `_draw`], [140 / 141], [拆开的版本，供需要先知道头部尺寸的代码使用],
    [`ED_region_tag_redraw`], [76], [把这个区块标记为需要重画],
    [`ED_region_tag_redraw_partial`], [77], [只重画区块内某个矩形，附带是否重建布局],
    [`ED_area_tag_redraw`], [242], [把整个编辑器区域标记为需要重画],
    [`ED_area_tag_redraw_regiontype`], [244], [只标记区域内某一类区块],
    [`ED_area_headersize`], [267], [返回当前头部高度（像素）],
  ),
  caption: [编辑器常用的 `ED_` 屏幕 API，行号对应 #src("source/blender/editors/include/ED_screen.hh")。],
) <tbl-ed-screen-api>

*重画的正确姿势是"只标记，不直接调 `draw`"*，渲染循环会在下一帧统一处理：

```cpp
/* 示意：在 listener 或操作符里 */
ED_region_tag_redraw(region);                          /* 只重画这一个区块 */
ED_area_tag_redraw(area);                              /* 整个 area 的所有区块 */
ED_area_tag_redraw_regiontype(area, RGN_TYPE_HEADER);  /* 只重画头部 */
```

#warn[
  不要在 `draw` 回调里标记自己重画，那会造成无限重画。重画请求应该来自
  `listener`（响应通知）、操作符（响应数据修改）或 `on_user_resize` 之类的尺寸变化。
  电子表格有一个规范例子：主区块更新完数据后标记*别人*重画 ——
  "Tag other regions for redraw, because the main region updates data for them."
  （#src("source/blender/editors/space_spreadsheet/space_spreadsheet.cc:518")）。
]

=== 12.2.4 自定义绘制回调

除整块 `ARegionType::draw`，还能挂*若干*自定义绘制回调
（#src("source/blender/editors/space_api/spacetypes.cc:231")）：

```cpp
/* source/blender/editors/space_api/spacetypes.cc:231（节选） */
void *ED_region_draw_cb_activate(ARegionType *art,
                                 void (*draw)(const bContext *, ARegion *, void *),
                                 void *customdata,
                                 int type)
{
  RegionDrawCB *rdc = MEM_new_zeroed<RegionDrawCB>(__func__);

  BLI_addtail(&art->drawcalls, rdc);
  rdc->draw = draw;
  rdc->customdata = customdata;
  rdc->type = type;

  return rdc;
}
```

配套的 `ED_region_draw_cb_exit()`（#src("source/blender/editors/space_api/spacetypes.cc:246")）
与 `ED_region_draw_cb_draw()`（#src("source/blender/editors/space_api/spacetypes.cc:267")）；
调用点在 `ED_region_do_draw()` 的 `REGION_DRAW_POST_PIXEL` 阶段
（#src("source/blender/editors/screen/area.cc:528")）。这个机制主要给插件往
已有编辑器叠加内容用。自己写编辑器时直接实现 `draw_overlay` 更简单。

== 12.3 `uiLayout`、`PanelType`、头部/侧栏

=== 12.3.1 `ui::Layout`：按钮的声明式描述

`ui::Layout` 在 #src("source/blender/editors/include/UI_interface_layout.hh:115")：

```cpp
/* source/blender/editors/include/UI_interface_layout.hh:115（节选） */
struct Layout : public Item, NonCopyable, NonMovable {
 protected:
  LayoutRoot *root_ = nullptr;
  bContextStore *context_ = nullptr;
  Layout *parent_ = nullptr;
  std::string heading_;

  Vector<Item *> items_;
  Layout *child_items_layout_ = nullptr;
  ...
};
```

API 是*流式*的：`layout.row()` 返回一个新的 `Layout&`，你继续往它上面加控件：

```cpp
/* 示意：一个典型的 PanelType::draw */
static void my_panel_draw(const bContext *C, Panel *panel)
{
  ui::Layout &layout = *panel->layout;
  PointerRNA *ptr = ui::panel_custom_data_get(panel);

  ui::Layout &col = layout.column(false);
  col.prop(ptr, "my_float_property", UI_ITEM_NONE, std::nullopt, ICON_NONE);

  ui::Layout &row = layout.row(true);
  row.prop(ptr, "use_my_flag", UI_ITEM_NONE, std::nullopt, ICON_NONE);
  row.operator_("object.my_operator", "执行", ICON_PLAY);
}
```

常用布局方法（都在 `UI_interface_layout.hh`）：

#figure(
  kind: table,
  table(
    columns: (2.4fr, 0.7fr, 3fr),
    inset: 5pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*方法*], [*行号*], [*语义*]),
    [`box()`], [261], [带边框的容器],
    [`column(align)` / `(align, heading)`], [266 / 274], [竖向排列；带 `heading` 时画分组标题],
    [`row(align)` / `(align, heading)`], [280 / 288], [横向排列],
    [`column_flow(number, align)`], [295], [自动折行的多列排布],
    [`split(percentage, align)`], [388], [按百分比分成左右两块],
    [`prop(ptr, propname, flag, name, icon)`], [574], [加一个 RNA 属性控件],
    [`popover(C, panel_type, name, icon)`], [581], [加一个弹出面板按钮],
    [`prop_enum(ptr, prop, value, name, icon)`], [593], [加一个枚举值按钮（单选项）],
  ),
  caption: [`ui::Layout` 的常用方法，行号对应 #src("source/blender/editors/include/UI_interface_layout.hh")。],
) <tbl-ui-layout>

关键在于 *`ui::Layout` 只是一个描述*：`layout.column()` 不会立刻分配 GPU 资源，
只往 `items_` 里加一个 `Item`。所以同一份布局代码可以复用于面板、菜单、弹出框。
Python 侧 `self.layout.row()` 就是这同一个 API。

=== 12.3.2 把面板挂到区块上

注册方式是往 `ARegionType::paneltypes` 链表加一个 `PanelType`。最干净的样板是
电子表格的数据集面板（#src("source/blender/editors/space_spreadsheet/spreadsheet_panels.cc:17")），
全文 28 行：

```cpp
/* source/blender/editors/space_spreadsheet/spreadsheet_panels.cc:17 */
void spreadsheet_data_set_region_panels_register(ARegionType &region_type)
{
  PanelType *panel_type = MEM_new_zeroed<PanelType>(__func__);
  STRNCPY_UTF8(panel_type->idname, "SPREADSHEET_PT_data_set");
  STRNCPY_UTF8(panel_type->label, N_("Data Set"));
  STRNCPY_UTF8(panel_type->translation_context, BLT_I18NCONTEXT_DEFAULT_BPYRNA);
  panel_type->flag = PANEL_TYPE_NO_HEADER;
  panel_type->draw = spreadsheet_data_set_panel_draw;
  BLI_addtail(&region_type.paneltypes, panel_type);
}
```

四点：`idname` 应遵循 `<SPACE>_PT_<name>` 格式（Python 侧会被校验，见
#src("source/blender/makesrna/intern/rna_ui.cc:371")）；`label` 用 `N_()` 包住
以便提取翻译；`translation_context` 一般填 `BLT_I18NCONTEXT_DEFAULT_BPYRNA`；
用 `MEM_new_zeroed` 而不是 `MEM_new`。

#note[
  `PanelType::order` 是*同层级内的排序权重*。源码插入时是从链表尾部往前找第一个
  `order <=` 自己的位置（#src("source/blender/makesrna/intern/rna_ui.cc:416")）。
  不设置则默认为 0，顺序就变成"谁先注册谁靠后"。
]

=== 12.3.3 头部（`RGN_TYPE_HEADER`）

头部是"模式栏 + 菜单栏"。实现有两种写法：简单场景直接
`art->draw = ED_region_header;`（一步完成布局 + 绘制）；标准写法是
在 `art->init` 里调 `ED_region_header_init(region)`，
`art->draw` 里调 `ED_region_header(C, region)`。电子表格用的是后者的变体：

```cpp
/* source/blender/editors/space_spreadsheet/space_spreadsheet.cc:572（节选） */
static void spreadsheet_header_region_init(wmWindowManager * /*wm*/, ARegion *region)
{
  ED_region_header_init(region);
}

static void spreadsheet_header_region_draw(const bContext *C, ARegion *region)
{
  spreadsheet_update_context(C);
  ED_region_header(C, region);
}
```

头部高度由 `HEADERY` 决定（#src("source/blender/makesdna/DNA_screen_types.h:602")）：

```c
/* source/blender/makesdna/DNA_screen_types.h:601 */
#define HEADER_PADDING_Y 6
#define HEADERY (20 + HEADER_PADDING_Y)   /* = 26 */
```

注册区块时通过 `prefsizey` 设置，同时用 `keymapflag` 决定加载哪些快捷键表：

```cpp
/* source/blender/editors/space_spreadsheet/space_spreadsheet.cc:808（节选） */
  art = MEM_new_zeroed<ARegionType>("spacetype spreadsheet header region");
  art->regionid = RGN_TYPE_HEADER;
  art->prefsizey = HEADERY;
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_VIEW2D | ED_KEYMAP_HEADER | ED_KEYMAP_FRAMES;
  art->lock = REGION_DRAW_LOCK_ALL;

  art->init = spreadsheet_header_region_init;
  art->draw = spreadsheet_header_region_draw;
  art->free = spreadsheet_header_region_free;
  art->listener = spreadsheet_header_region_listener;
  BLI_addhead(&st->regiontypes, art);
```

`ED_KEYMAP_HEADER` 是头部专用的一组（<kbd>F3</kbd> 搜索、右键菜单等），
`ED_KEYMAP_UI` 是按钮通用快捷键，`ED_KEYMAP_FRAMES` 是动画播放控制。
`art->lock = REGION_DRAW_LOCK_ALL` 表示渲染 / 烘焙进行时不要画这个区块，
取值是 `ARegionDrawLockFlags`（#src("source/blender/blenkernel/BKE_screen.hh:242")），
含义扩展见 #src("source/blender/blenkernel/BKE_screen.hh:340")。
判断"哪些算头部类区块"可以用 `RGN_TYPE_IS_HEADER_ANY`
（#src("source/blender/makesdna/DNA_screen_types.h:710")），它同时匹配
`HEADER` / `TOOL_HEADER` / `FOOTER` / `ASSET_SHELF_HEADER` / `SCRUBBING`。

=== 12.3.4 侧栏（`RGN_TYPE_UI`）与左侧栏（`RGN_TYPE_TOOLS`）

侧栏与左侧栏的注册套路固定，差别只在 `prefsizex` 和 `draw`：

```cpp
/* source/blender/editors/space_spreadsheet/space_spreadsheet.cc:836（节选） */
  /* 右侧属性栏：交给面板框架 */
  art = MEM_new_zeroed<ARegionType>("spacetype spreadsheet right region");
  art->regionid = RGN_TYPE_UI;
  art->prefsizex = UI_SIDEBAR_PANEL_WIDTH;      /* = 280，见 UI_interface_c.hh:435 */
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_FRAMES;
  art->lock = REGION_DRAW_LOCK_ALL;
  art->init = spreadsheet_sidebar_init;
  art->layout = ED_region_panels_layout;
  art->draw = ED_region_panels_draw;
  art->free = spreadsheet_right_region_free;
  art->listener = spreadsheet_right_region_listener;
  BLI_addhead(&st->regiontypes, art);

  register_row_filter_panels(*art);

  /* 左侧数据集栏：自己画树视图 */
  art = MEM_new_zeroed<ARegionType>("spreadsheet dataset region");
  art->regionid = RGN_TYPE_TOOLS;
  art->prefsizex = 150 + V2D_SCROLL_WIDTH;      /* UI_view2d.hh:79 */
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_FRAMES;
  art->lock = REGION_DRAW_LOCK_ALL;
  art->init = ED_region_panels_init;
  art->draw = spreadsheet_dataset_region_draw;
  art->listener = spreadsheet_dataset_region_listener;
  spreadsheet_data_set_region_panels_register(*art);
  BLI_addhead(&st->regiontypes, art);
```

#pitfall[
  `prefsizex` 里给滚动条预留的 `V2D_SCROLL_WIDTH`
  （#src("source/blender/editors/include/UI_view2d.hh:79")，随 UI 缩放变化）
  *一定要加上*。忘了加的症状是内容被滚动条压住 —— 很小但很常见的错误。
]

区块的*创建*发生在 `SpaceType::create` 里，此时只设置 `regiontype` 与
`alignment`，具体尺寸交给类型层的 `prefsizex` / `prefsizey`：

```cpp
/* source/blender/editors/space_spreadsheet/space_spreadsheet.cc:87（节选） */
  {
    /* Properties region. */
    ARegion *region = BKE_area_region_new();
    BLI_addtail(&spreadsheet_space->regionbase, region);
    region->regiontype = RGN_TYPE_UI;
    region->alignment = RGN_ALIGN_RIGHT;
    region->flag = RGN_FLAG_HIDDEN;   /* 默认收起，按 N 才显示 */
  }
```

`RGN_FLAG_HIDDEN` 见 #src("source/blender/makesdna/DNA_screen_types.h:752")。

=== 12.3.5 RNA 侧：Python 能看到什么

Python 不参与编辑器注册，但需要一个"柄"来访问编辑器数据，这个柄是 RNA 结构。
`rna_space.cc` 里共定义了 *23 个* `Space*` 结构：

#figure(
  kind: table,
  table(
    columns: (1.6fr, 0.5fr, 1.7fr, 0.5fr),
    inset: 4pt,
    align: (left, right, left, right),
    stroke: 0.4pt + luma(78%),
    table.header([*RNA 结构名*], [*`:行`*], [*RNA 结构名*], [*`:行`*]),
    [`Space`], [4128], [`SpaceGraphEditor`], [7329],
    [`SpaceUVEditor`], [4236], [`SpaceNLA`], [7463],
    [`SpaceOutliner`], [4436], [`SpaceConsole`], [7556],
    [`SpaceView3D`], [5650], [`SpaceFileBrowser`], [8048],
    [`SpaceProperties`], [6177], [`SpaceInfo`], [8219],
    [`SpaceImageOverlay`], [6246], [`SpacePreferences`], [8261],
    [`SpaceImageEditor`], [6286], [`SpaceNodeEditorPath`], [8322],
    [`SpaceSequenceEditor`], [6796], [`SpaceNodeOverlay`], [8372],
    [`SpaceTextEditor`], [7004], [`SpaceNodeEditor`], [8499],
    [`SpaceDopeSheetOverlay`], [7137], [`SpaceClipOverlay`], [8671],
    [`SpaceDopeSheetEditor`], [7163], [`SpaceClipEditor`], [8739],
    [`SpaceSpreadsheet`], [9433], [—], [—],
  ),
  caption: [`rna_space.cc` 里全部 23 个 `Space*` RNA 结构定义（行号对应 #src("source/blender/makesrna/intern/rna_space.cc")）。],
) <tbl-rna-space-structs>

其中 `SpaceUVEditor`、`SpaceImageOverlay`、`SpaceDopeSheetOverlay`、
`SpaceNodeEditorPath`、`SpaceNodeOverlay`、`SpaceClipOverlay` 六个
*不是独立编辑器*，而是"叠加层数据"，只是 RNA 命名约定要求同族结构前缀一致。
`SpaceProperties` 也是这种情况的例外命名 —— 它对应 `SPACE_PROPERTIES`，
而 RNA 名不叫 `SpaceButtons`。

基类 `Space` 的定义：

```c
/* source/blender/makesrna/intern/rna_space.cc:4128（节选） */
  srna = RNA_def_struct(brna, "Space", nullptr);
  RNA_def_struct_sdna(srna, "SpaceLink");
  ...
  prop = RNA_def_property(srna, "type", PROP_ENUM, PROP_NONE);
  RNA_def_property_enum_sdna(prop, nullptr, "spacetype");
  RNA_def_property_enum_items(prop, rna_enum_space_type_items);
  /* When making this property editable, take care for the special case of global areas
   * (see rna_Area_type_set). */
  RNA_def_property_clear_flag(prop, PROP_EDITABLE);
```

三点：*`Space` 映射到 `SpaceLink`*（#src("source/blender/makesdna/DNA_space_types.h:95")）
而不是某个具体类型；*`"type"` 属性映射到 `SpaceLink::spacetype`*，取值表是
`rna_enum_space_type_items`（#src("source/blender/makesrna/intern/rna_space.cc:90")），
第一项是 `{SPACE_EMPTY, "EMPTY", ICON_NONE, "Empty", ""}`；*该属性被显式设为不可编辑*，
因为切换编辑器类型的入口在 `rna_Area_type_set`。

Python 侧因此可以这样读：

```python
import bpy
area = bpy.context.area
print(area.type)                     # 'VIEW_3D' 等
print(type(area.spaces.active))      # <class 'bpy.types.SpaceView3D'>
```

但要强调：`bpy.types.SpaceView3D` 只是*已有 C++ 结构在 RNA 层的映射*，
它没有对应的注册元数据。继承它注册不出新编辑器 —— 这就是 12.5 必须改 C++ 的原因。

== 12.4 GPU 抽象（`GPU_`）与 draw manager（`DRW_`）

=== 12.4.1 三层分工

#figure(
  kind: table,
  table(
    columns: (0.9fr, 1.5fr, 4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*目录*], [*职责*]),
    [`GPU_`], [`source/blender/gpu/`], [硬件抽象：缓冲、着色器、纹理、状态、帧缓冲。屏蔽 GL / Vulkan / Metal 差异],
    [`DRW_`], [`source/blender/draw/`], [场景绘制编排（draw manager）：画哪些物体、用哪个 pass、怎么排序],
    [`ED_`], [`source/blender/editors/`], [编辑器自己的绘制逻辑，直接调 `GPU_` 或通过 `DRW_` 请求场景绘制],
  ),
  caption: [`GPU_` / `DRW_` / `ED_` 三层分工。],
) <tbl-gpu-layers>

对*编辑器*而言：

- 2D 界面（头部、侧栏、面板、按钮）→ 直接调 `GPU_` 或 `ui::` 的绘图辅助函数，
  这条路上几乎不碰 `DRW_`。
- 3D 视口 → 调 `DRW_draw_view(C)`（#src("source/blender/draw/DRW_engine.hh:61")），
  把整帧场景交给 draw manager。
- 叠加层（gizmo、光标、自定义叠加）→ 在 `ARegionType::draw_overlay` 里直接调 `GPU_`。

`DRW_engine.hh` 对外入口不多：

```cpp
/* source/blender/draw/DRW_engine.hh:41（节选） */
void DRW_engines_register();
void DRW_engines_free();
void DRW_module_init();
void DRW_module_exit();
...
/**
 * Everything starts here.
 * This function takes care of calling all cache and rendering functions
 * for each relevant engine / mode engine.
 */
void DRW_draw_view(const bContext *C);

void DRW_draw_render_loop_offscreen(Depsgraph *depsgraph, ...);   /* :71 */
void DRW_draw_select_loop(Depsgraph *depsgraph, ...);             /* :84 */
void DRW_draw_depth_loop(Depsgraph *depsgraph, ...);              /* :98 */
```

draw manager 内部是 `draw::Manager` 类（#src("source/blender/draw/intern/draw_manager.hh:48")），
持有按资源索引的物体矩阵 / 包围盒 / 属性缓冲，以及 `PassSimple` / `PassMain`
两种绘制通道（#src("source/blender/draw/intern/draw_manager.hh:44")）。
那部分属于第 15 章，本章只需知道"3D 视口调 `DRW_draw_view`"。

=== 12.4.2 `GPUBatch`：把顶点缓冲与索引缓冲绑成一次绘制

```cpp
/* source/blender/gpu/GPU_batch.hh:75（节选） */
class Batch {
 public:
  gpu::VertBuf *verts[GPU_BATCH_VBO_MAX_LEN];   /* = 16，verts[0] 必须非空 */
  gpu::IndexBuf *elem;                          /* 元素列表，可为 nullptr */
  int32_t procedural_vertices;
  GPUBatchFlag flag;                            /* 含缓冲所有权位 */
  GPUPrimType prim_type;                        /* 几何类型 */
  gpu::Shader *shader;                          /* DEPRECATED，只用于 uniform 绑定 */
  ...
  uint32_t vertex_count_get() const { ... }
};
```

注意注释：*"Do not allocate manually as the real struct is bigger (i.e: GLBatch).
This is only the common and 'public' part of the struct."*
（#src("source/blender/gpu/GPU_batch.hh:71")）。所以必须用工厂函数创建：

#figure(
  kind: table,
  table(
    columns: (2.6fr, 0.6fr, 3.4fr),
    inset: 5pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数 / 宏*], [*行号*], [*作用*]),
    [`GPU_batch_calloc()`], [128], [分配"空状态"batch，随后要调 `GPU_batch_init_ex`],
    [`GPU_batch_create_ex(prim, vbo, ibo, owns)`], [133], [一步创建，显式指定缓冲所有权],
    [`GPU_batch_create_procedural(prim, count)`], [138], [无顶点缓冲，顶点数绘制时决定],
    [`GPU_batch_create(prim, vbo, ibo)`], [143], [宏，等于 `_create_ex(..., (GPUBatchFlag)0)`，不接管所有权],
    [`GPU_batch_init_ex(batch, prim, vbo, ibo, owns)`], [151], [初始化已分配的 batch],
    [`GPU_batch_discard(batch)`], [197], [释放 batch 及其拥有的缓冲],
    [`GPU_batch_program_set_builtin(batch, id)`], [249], [绑定内置着色器，最常用],
    [`GPU_batch_set_shader(batch, shader)`], [246], [绑定自定义着色器],
    [`GPU_batch_draw(batch)`], [304], [画全部顶点],
    [`GPU_batch_draw_range` / `_instance_range` / `_advanced` / `_indirect`], [317 / 331 / 344 / 358], [画一段顶点 / 一段实例 / 完整控制 / 从存储缓冲读参数],
  ),
  caption: [`GPUBatch` 的创建与绘制 API，行号对应 #src("source/blender/gpu/GPU_batch.hh")。],
) <tbl-gpubatch-api>

`GPUPrimType` 见 #src("source/blender/gpu/GPU_primitive.hh:18")：
`GPU_PRIM_POINTS`、`GPU_PRIM_LINES`、`GPU_PRIM_TRIS`、`GPU_PRIM_TRI_STRIP`、
`GPU_PRIM_LINES_ADJ`、`GPU_PRIM_TRIS_ADJ`。
`GPUBatchFlag`（#src("source/blender/gpu/GPU_batch.hh:39")）里的所有权位很关键：
填了 `GPU_BATCH_OWNS_VBO` / `GPU_BATCH_OWNS_INDEX` 之后 `GPU_batch_discard`
会连带释放这些缓冲；不填就得自己管生命周期。填错方向会造成内存泄漏或重复释放。

缓冲构建分三步：*格式 → 顶点数据 → 索引*。

```cpp
/* 示意：一个最小的三角形批次 */
GPUVertFormat format = {0};
uint pos_id = GPU_vertformat_attr_add(&format, "pos", gpu::VertAttrType::SFLOAT_32_32);

gpu::VertBuf *vbo = GPU_vertbuf_create_with_format(format);
GPU_vertbuf_data_alloc(*vbo, 3);
GPU_vertbuf_attr_fill(vbo, pos_id, my_float2_array);

gpu::Batch *batch = GPU_batch_create_ex(GPU_PRIM_TRIS, vbo, nullptr, GPU_BATCH_OWNS_VBO);
GPU_batch_program_set_builtin(batch, GPU_SHADER_3D_UNIFORM_COLOR);
GPU_batch_uniform_4fv(batch, "color", my_color);
GPU_batch_draw(batch);
```

下面是完整可用的真实例子（#src("source/blender/editors/gizmo_library/gizmo_draw_utils.cc:19")）：

```cpp
/* source/blender/editors/gizmo_library/gizmo_draw_utils.cc:26（节选） */
  GPUVertFormat format = {0};
  uint pos_id = GPU_vertformat_attr_add(&format, "pos", gpu::VertAttrType::SFLOAT_32_32_32);

  /* Elements */
  GPUIndexBufBuilder elb = {0};
  GPU_indexbuf_init(&elb, GPU_PRIM_TRIS, info->ntris, info->nverts);
  for (int i = 0; i < info->ntris; i++) {
    const ushort *idx = &info->indices[i * 3];
    GPU_indexbuf_add_tri_verts(&elb, idx[0], idx[1], idx[2]);
  }
  gpu::IndexBuf *el = GPU_indexbuf_build(&elb);

  gpu::VertBuf *vbo = GPU_vertbuf_create_with_format(format);
  GPU_vertbuf_data_alloc(*vbo, info->nverts);
  GPU_vertbuf_attr_fill(vbo, pos_id, info->verts);

  gpu::Batch *batch = GPU_batch_create_ex(
      GPU_PRIM_TRIS, vbo, el, GPU_BATCH_OWNS_VBO | GPU_BATCH_OWNS_INDEX);
  GPU_batch_program_set_builtin(batch, GPU_SHADER_3D_UNIFORM_COLOR);

  GPU_batch_uniform_4fv(batch, "color", color);
  ...
  GPU_batch_draw(batch);
  ...
  GPU_batch_discard(batch);
```

#tip[
  源码里就留着一条 TODO：*"store the Batches inside the GizmoGeomInfo and updated
  it when geom changes. So we don't need to re-created and discard it every time"*
  （#src("source/blender/editors/gizmo_library/gizmo_draw_utils.cc:23")）。
  *别在每帧的 `draw` 里重建 `GPUBatch`*。正确做法是把 batch 缓存在编辑器数据
  （`SpaceXxx::runtime`）里，只在几何变化时重建。屏幕边线的绘制就是缓存样板：
  #src("source/blender/editors/screen/screen_draw.cc:71") 的
  `if (screen_edges_batch == nullptr) { ... }` 只在第一次构建。
]

=== 12.4.3 `GPUShader`：从 `GPUShaderCreateInfo` 创建

```cpp
/* source/blender/gpu/GPU_shader.hh:53（节选） */
/** Create a shader using the given #GPUShaderCreateInfo.
 *  Can return a null pointer if compilation fails. */
gpu::Shader *GPU_shader_create_from_info(const GPUShaderCreateInfo *_info);

/** Same as GPU_shader_create_from_info but will run preprocessor on source strings. */
gpu::Shader *GPU_shader_create_from_info_python(const GPUShaderCreateInfo *_info);

/** Create a shader using a named #GPUShaderCreateInfo registered at startup.
 *  These are declared inside `*_info.hh` files using the `GPU_SHADER_CREATE_INFO()` macro.
 *  They are also expected to have been flagged using `do_static_compilation`. */
gpu::Shader *GPU_shader_create_from_info_name(const char *info_name);
```

`GPU_SHADER_CREATE_INFO` 用来声明静态的着色器描述。例如界面边框着色器
（#src("source/blender/gpu/shaders/infos/gpu_shader_2D_area_borders_infos.hh:22")）：

```cpp
/* source/blender/gpu/shaders/infos/gpu_shader_2D_area_borders_infos.hh:18 */
GPU_SHADER_INTERFACE_INFO(smooth_uv_iface)
SMOOTH(float2, uv)
GPU_SHADER_INTERFACE_END()

GPU_SHADER_CREATE_INFO(gpu_shader_2D_area_borders)
VERTEX_IN(0, float2, pos)
VERTEX_OUT(smooth_uv_iface)
FRAGMENT_OUT(0, float4, fragColor)
PUSH_CONSTANT(float4x4, ModelViewProjectionMatrix)
PUSH_CONSTANT(float4, rect)
PUSH_CONSTANT(float4, color)
PUSH_CONSTANT(float, scale)
PUSH_CONSTANT(float, width)
PUSH_CONSTANT(int, cornerLen)
VERTEX_SOURCE("gpu_shader_2D_area_borders_vert.glsl")
FRAGMENT_SOURCE("gpu_shader_2D_area_borders_frag.glsl")
DO_STATIC_COMPILATION()
GPU_SHADER_CREATE_END()
```

这是一个声明式 DSL：`VERTEX_IN(0, float2, pos)` 是顶点属性（location 0）；
`PUSH_CONSTANT(...)` 是推送常量（Blender 5.2 统一用它代替传统 uniform 变量）；
`VERTEX_SOURCE` / `FRAGMENT_SOURCE` 是 GLSL 源文件名，宏定义在
#src("source/blender/gpu/intern/gpu_shader_create_info.hh:188")；
`DO_STATIC_COMPILATION()` 表示启动时预编译，设了它就能在运行时用
`GPU_shader_create_from_info_name("gpu_shader_2D_area_borders")` 按名字取。

使用流程是四步：

```cpp
/* 示意 */
gpu::Shader *shader = GPU_shader_create_from_info_name("gpu_shader_2D_area_borders");
GPU_shader_bind(shader);                                 /* GPU_shader.hh:154 */
GPU_shader_uniform_4fv(shader, "rect", rect_data);
GPU_shader_uniform_4fv(shader, "color", color_data);
...
GPU_shader_unbind();                                     /* GPU_shader.hh:162 */
```

`GPU_shader_free()` 在 #src("source/blender/gpu/GPU_shader.hh:139")；
uniform 设置函数的各类型变体（`_1i` / `_1f` / `_2fv` / `_3fv` / `_4fv` / `_mat4` …）
在 #src("source/blender/gpu/GPU_shader.hh:218") 到
#src("source/blender/gpu/GPU_shader.hh:237")。

#warn[
  创建函数的注释写着 *"Can return a null pointer if compilation fails"*。
  着色器有语法错误时不会崩溃，只会拿到 `nullptr`，然后你的绘制静默消失。
  写自定义着色器一定要检查返回值，并用
  `GPU_shader_create_info_check_error()`（#src("source/blender/gpu/GPU_shader.hh:83")）
  或 `--debug-gpu` 查原因。
]

=== 12.4.4 `GPU_immediate`：来不及建缓冲时用

顶点数很少的 2D 图元（分隔线、矩形填充）用*立刻模式*
（#src("source/blender/gpu/GPU_immediate.hh")）更省事：

```cpp
/* 示意：立刻模式画一条线 */
GPUVertFormat *format = immVertexFormat();                                    /* :27 */
uint pos = GPU_vertformat_attr_add(format, "pos", gpu::VertAttrType::SFLOAT_32_32);
immBindBuiltinProgram(GPU_SHADER_3D_UNIFORM_COLOR);                           /* :137 */
immUniformColor4fv(color);                                                    /* :122 */
immBegin(GPU_PRIM_LINES, 2);                                                  /* :45 */
immVertex2f(pos, x0, y0);                                                     /* :87 */
immVertex2f(pos, x1, y1);
immEnd();                                                                     /* :48，这里才真正提交绘制 */
immUnbindProgram();                                                           /* :32 */
```

缓冲区由 Blender 按帧管理：`immBegin` 借一块预分配内存，`immEnd` 提交并归还。
所以它*不能跨帧保存*，顶点数超过几千就该改用 `GPUBatch`。
另有 `immBeginBatch` / `immBeginBatchAtMost`（#src("source/blender/gpu/GPU_immediate.hh:56")）
把"开始 → 提交"拆开，返回 `gpu::Batch*` 供你稍后自己 `GPU_batch_draw`。

电子表格的主绘制函数是很好的混合范例 —— 局部图形用立刻模式，文字用 `BLF_`：

```cpp
/* source/blender/editors/space_spreadsheet/spreadsheet_draw.cc:345（节选） */
void draw_spreadsheet_in_region(const bContext *C,
                                ARegion *region,
                                const SpreadsheetDrawer &drawer)
{
  ...
  ui::theme::frame_buffer_clear(TH_BACK);

  GPUVertFormat *format = immVertexFormat();
  uint pos = GPU_vertformat_attr_add(format, "pos", gpu::VertAttrType::SFLOAT_32_32);
  immBindBuiltinProgram(GPU_SHADER_3D_UNIFORM_COLOR);

  draw_index_column_background(pos, region, drawer);
  draw_alternating_row_overlay(pos, scroll_offset_y, region, drawer);
  draw_top_row_background(pos, region, drawer);
  draw_separator_lines(pos, scroll_offset_x, region, drawer);

  immUnbindProgram();

  draw_left_column_content(scroll_offset_y, C, region, drawer);
  draw_top_row_content(C, region, drawer, scroll_offset_x);
  draw_cell_contents(C, region, drawer, scroll_offset_x, scroll_offset_y);
  ...
}
```

结构很清楚：*先用一个 `immBindBuiltinProgram` / `immUnbindProgram` 区间把所有几何
图元画完，再画文字*，这样切换图形管线的次数最少。

另一个技巧是用 `GPU_scissor()` 把绘制限制在某个矩形内
（#src("source/blender/editors/space_spreadsheet/spreadsheet_draw.cc:146")），
画完用 `GPU_scissor(UNPACK4(old_scissor))` 恢复 —— 这就是"冻结行 / 冻结列"
的实现方式：不需要把内容切成两份，只要用两次不同 scissor 画同一份数据。
`GPU_scissor_get` / `GPU_scissor` 声明在 #src("source/blender/gpu/GPU_state.hh")。

#tip[
  要画标准界面元素（圆角矩形、滚动条、图标）时*不要自己写着色器*，`ui::` 里有现成的：
  `ui::draw_roundbox_4fv(&rect, true, 0, color)`
  （#src("source/blender/editors/space_spreadsheet/spreadsheet_draw.cc:341")）、
  `ui::theme::frame_buffer_clear(TH_BACK)`
  （#src("source/blender/editors/space_spreadsheet/spreadsheet_draw.cc:353")）、
  `ui::view2d_scrollers_draw(v2d, &mask)`
  （#src("source/blender/editors/space_spreadsheet/spreadsheet_draw.cc:388")）、
  `ui::view2d_mask_from_win(&region->v2d, &mask)`
  （#src("source/blender/editors/space_spreadsheet/space_spreadsheet.cc:513")）。

  颜色一律取自*主题*而非硬编码：`ui::theme::get_color_3fv(TH_EDITOR_BORDER, color)`
  （#src("source/blender/editors/screen/area.cc:567")），或在立刻模式里用
  `immUniformThemeColor(...)`（#src("source/blender/gpu/GPU_immediate.hh:140")）。
  这样你的编辑器会自动跟随用户配色，也不会在亮色主题下变成一片黑。
]

== 12.5 实践：新增一个编辑器类型

目标：*从零加一个"示例编辑器（Sample）"*，含一个头部、一个主工作区、
一个右侧属性栏，属性栏里有一个面板。全程只改源码，不写任何 Python。
蓝本是 `SpaceSpreadsheet` —— 它是 Blender 里最新的编辑器，结构最干净，
且五类区块一个不缺。

=== 12.5.1 要动的文件清单

#figure(
  kind: table,
  table(
    columns: (0.4fr, 2.6fr, 4fr),
    inset: 5pt,
    align: (right, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*步*], [*文件*], [*做什么*]),
    [1], [`makesdna/DNA_space_enums.h`], [加 `SPACE_SAMPLE = 24`（只能追加在末尾）与 `SPACE_TYPE_NUM`],
    [2], [`makesdna/DNA_space_types.h`], [加 `struct SpaceSample` 与 `SpaceSample_Runtime`],
    [3], [`makesrna/intern/rna_space.cc`], [加 `rna_def_space_sample()`；改 `rna_Space_refine`；改 `rna_enum_space_type_items`],
    [4], [`editors/CMakeLists.txt`], [加 `add_subdirectory(space_sample)`],
    [5], [`editors/space_sample/CMakeLists.txt`], [新建，声明源文件与依赖库],
    [6], [`editors/space_sample/sample_intern.hh`], [新建，放 `SpaceSample_Runtime` 与函数声明],
    [7], [`editors/space_sample/space_sample.cc`], [新建，实现 `SpaceType` 与区块注册],
    [8], [`editors/space_sample/sample_panels.cc`], [新建，实现 `PanelType` 注册],
    [9], [`editors/space_api/spacetypes.cc`], [加一行 `sample::register_spacetype();` 与对应 include],
    [10], [`editors/space_api/CMakeLists.txt`], [`LIB` 里加 `bf_editor_space_sample`（否则链接失败）],
  ),
  caption: [新增编辑器要动的 10 个位置。],
) <tbl-new-editor-steps>

#note[
  如果新编辑器还需要新的 `.blend` 数据（新的列表结构、新的 `ID` 类型），
  还要动 `blenloader` 的读写与版本升级（`do_versions`）。本节只加一个最小状态字段。
]

=== 12.5.2 第 1 步：加枚举值

`eSpace_Type` 在 #src("source/blender/makesdna/DNA_space_enums.h:1151")，
带着明确警告 `Do NOT change order, append on end`。所以在
`SPACE_SPREADSHEET = 23` 后追加，并同步改 `SPACE_TYPE_NUM`：

```c
/* source/blender/makesdna/DNA_space_enums.h（改后） */
  SPACE_STATUSBAR = 22,
  SPACE_SPREADSHEET = 23,
  SPACE_SAMPLE = 24

#define SPACE_TYPE_NUM (SPACE_SAMPLE + 1)
```

三件不能做错的事：*不要插在中间*（`.blend` 存的是数值，插入会让旧文件把
电子表格读成示例编辑器）；*值类型是 `char`*（`enum eSpace_Type : char`），
上限 127；*`SPACE_TYPE_NUM` 必须同步更新*，它被用作数组边界，不更新会越界写。

=== 12.5.3 第 2 步：加 DNA 结构

在 #src("source/blender/makesdna/DNA_space_types.h") *文件末尾追加*：

```c
/* source/blender/makesdna/DNA_space_types.h（新增） */

struct SpaceSample {
  SpaceLink *next = nullptr, *prev = nullptr;
  /** Storage of regions for inactive spaces. */
  ListBaseT<ARegion> regionbase = {nullptr, nullptr};
  char spacetype = 0;
  eSpace_Link_Flag link_flag = {};
  char _pad0[6] = {};
  /* End 'SpaceLink' header. */

  /** A user-visible setting that IS saved to .blend files. */
  float sample_value = 0.0f;
  /** Display style. */
  int display_style = 0;
  char _pad1[4] = {};

  ed::sample::SpaceSample_Runtime *runtime = nullptr;
};
```

每处都有讲究：

- *前 7 行是 `SpaceLink` 的"头部"，必须逐字节一致*。看 `SpaceSpreadsheet`
  （#src("source/blender/makesdna/DNA_space_types.h:1241")）的开头就知道 ——
  所有 `SpaceXxx` 都重复这 7 行，源码用 `/* End 'SpaceLink' header. */` 标出边界。
  `makesdna` 生成的结构偏移表依赖这个约定，使 `SpaceLink*` 能安全转成任意 `SpaceXxx*`。
- *`_pad0[6]` 是为 8 字节对齐*：`char spacetype` + `eSpace_Link_Flag` 凑不满
  8 字节。改这些填充会破坏二进制兼容。
- *用 `ListBaseT<T>`*（带类型的列表模板，定义在 #src("source/blender/makesdna/DNA_listBase.h:52")），
  不要用旧的 `ListBase`。
- *运行期数据单独放 `_Runtime` 结构*，用一个指针引用。这是 Blender 的现代约定：
  `.blend` 读写的代码不会碰它。`SpaceSpreadsheet` 就是这么做的
  （#src("source/blender/makesdna/DNA_space_types.h:1275")）。

#warn[
  改完 DNA 后必须重新运行 `makesdna`（Ninja 会自动做），它会重新生成
  `dna_type_offsets.h` 与 `rna_prototypes_gen.h` 等文件。看到
  `dna_type_offsets.h` 相关错误时先完整重编译一次，*不要手工改生成的文件*。
]

=== 12.5.4 第 3 步：加 RNA 结构

在 #src("source/blender/makesrna/intern/rna_space.cc") 里加：

```c
/* source/blender/makesrna/intern/rna_space.cc（新增） */
static void rna_def_space_sample(BlenderRNA *brna)
{
  StructRNA *srna;
  PropertyRNA *prop;

  srna = RNA_def_struct(brna, "SpaceSample", "Space");
  RNA_def_struct_ui_text(srna, "Space Sample", "Sample editor space data");

  rna_def_space_generic_show_region_toggles(srna, (1 << RGN_TYPE_UI) | (1 << RGN_TYPE_HEADER));

  prop = RNA_def_property(srna, "sample_value", PROP_FLOAT, PROP_NONE);
  RNA_def_property_float_sdna(prop, nullptr, "sample_value");
  RNA_def_property_range(prop, -10.0f, 10.0f);
  RNA_def_property_ui_text(prop, "Sample Value", "A value shown in the sidebar");
  RNA_def_property_update(prop, NC_SPACE | ND_SPACE_PROPERTIES, nullptr);

  prop = RNA_def_property(srna, "display_style", PROP_ENUM, PROP_NONE);
  RNA_def_property_enum_sdna(prop, nullptr, "display_style");
  RNA_def_property_enum_items(prop, rna_enum_space_sample_style_items);
  RNA_def_property_update(prop, NC_SPACE | ND_SPACE_PROPERTIES, nullptr);
}
```

#note[
  `RNA_def_property_update` 的第二个参数是*通知*（notifier）：属性改动后 Blender
  广播它，各区块的 `listener` 收到后决定要不要重画。这里借用已有的
  `ND_SPACE_PROPERTIES`（#src("source/blender/windowmanager/WM_types.hh:563")）作为演示。
  *真实提交应该新增自己的通知*：在 #src("source/blender/windowmanager/WM_types.hh")
  里加 `#define ND_SPACE_SAMPLE (23 << 16)`（现有 `ND_SPACE_SPREADSHEET` 是
  `(22 << 16)`，#src("source/blender/windowmanager/WM_types.hh:575")）。
  通知值一旦分配就不能重排，因为插件会按名字引用它。
]

然后必须在两个地方调用它。第一处是 `rna_Space_refine` —— 它把泛化的
`SpaceLink` 指针细化为具体的 RNA 结构
（#src("source/blender/makesrna/intern/rna_space.cc:759")）：

```c
/* source/blender/makesrna/intern/rna_space.cc:759（节选） */
static StructRNA *rna_Space_refine(PointerRNA *ptr)
{
  SpaceLink *space = static_cast<SpaceLink *>(ptr->data);

  switch (eSpace_Type(space->spacetype)) {
    case SPACE_VIEW3D:
      return RNA_SpaceView3D;
    ...
    case SPACE_SPREADSHEET:
      return RNA_SpaceSpreadsheet;

      /* Currently no type info. */
    case SPACE_SCRIPT:
    case SPACE_EMPTY:
    case SPACE_TOPBAR:
    case SPACE_STATUSBAR:
      break;
  }
  ...
}
```

在 `case SPACE_SPREADSHEET:` 后加：

```c
    case SPACE_SAMPLE:
      return RNA_SpaceSample;
```

注意 `SPACE_SCRIPT` / `SPACE_EMPTY` / `SPACE_TOPBAR` / `SPACE_STATUSBAR`
被归入 "Currently no type info." —— 这四个编辑器*没有*独立 RNA 结构，共用基类
`Space`。所以 RNA 结构并非每个 `SpaceType` 都必须有；我们的编辑器要暴露属性，
所以必须有。

第二处是 `RNA_def_space` 末尾的初始化序列，在 `rna_def_space_spreadsheet(brna);`
（#src("source/blender/makesrna/intern/rna_space.cc:9550")）后加
`rna_def_space_sample(brna);`。

最后把新编辑器加进"用户能选的编辑器类型"表 `rna_enum_space_type_items`
（#src("source/blender/makesrna/intern/rna_space.cc:90")，`SPACE_SPREADSHEET`
那一项在同文件:176）：

```c
    /* source/blender/makesrna/intern/rna_space.cc:90（节选） */
    {SPACE_SPREADSHEET,
     "SPREADSHEET",
     ICON_SPREADSHEET,
     "Spreadsheet",
     "Explore geometry data in a table"},
```

我们追加：

```c
    {SPACE_SAMPLE, "SAMPLE", ICON_FILE_SCRIPT, "Sample", "Sample editor for the book"},
```

*第一项 `SPACE_EMPTY` 必须留在开头* —— 源码注释写着 "empty must be here for
python, is skipped for UI"，它给 Python 一个"没有编辑器"的占位值。
图标名必须是 `UI_icons.hh` 里已存在的枚举：`ICON_SPREADSHEET` 在同文件
#src("source/blender/editors/include/UI_icons.hh:218")，`ICON_FILE_SCRIPT` 在
#src("source/blender/editors/include/UI_icons.hh:789")。图标本身来自
#src("release/datafiles/icons_svg/") 下的 SVG，构建时转成 `.dat` 并生成这个枚举头，
  所以*不能随便编图标名*，拼错会直接编译失败。

=== 12.5.5 第 4 步：建目录与 CMake

在 #src("source/blender/editors/CMakeLists.txt:47") 附近按字母序插入：

```cmake
# source/blender/editors/CMakeLists.txt（新增一行）
  add_subdirectory(space_sample)
```

再新建 `source/blender/editors/space_sample/CMakeLists.txt`，照抄
#src("source/blender/editors/space_spreadsheet/CMakeLists.txt") 的结构换名字：

```cmake
# source/blender/editors/space_sample/CMakeLists.txt（新增）
# SPDX-License-Identifier: GPL-2.0-or-later

set(INC
  ../include
  ../../makesrna
  # RNA_prototypes.hh
  ${CMAKE_BINARY_DIR}/source/blender/makesrna
)

set(INC_SYS
)

set(SRC
  space_sample.cc
  sample_panels.cc

  sample_intern.hh
)

set(LIB
  PRIVATE bf::blenkernel
  PRIVATE bf::blenlib
  PRIVATE bf::blenloader
  PRIVATE bf::blentranslation
  PRIVATE bf::depsgraph
  PRIVATE bf::dna
  PRIVATE bf::gpu
  PRIVATE bf::intern::guardedalloc
  PRIVATE bf::windowmanager
)

blender_add_lib(bf_editor_space_sample "${SRC}" "${INC}" "${INC_SYS}" "${LIB}")

# RNA_prototypes.hh dna_type_offsets.h
add_dependencies(bf_editor_space_sample bf_rna)
```

#pitfall[
  只建新库还不够。`ED_spacetypes_init()` 在 `space_api` 库里，必须能链接到你的库。
  所以要改 #src("source/blender/editors/space_api/CMakeLists.txt:18") 的 `LIB` 列表，
  在 `bf_editor_space_spreadsheet`（同文件:37）附近加一行*不带 `PRIVATE`* 的
  `bf_editor_space_sample`。漏掉这一行的症状是链接期报
  `undefined reference to 'blender::ed::sample::register_spacetype()'`。
  另一种常见失败是补了库名却漏了某个 `bf::gpu` 之类的依赖，症状同样是链接错误 ——
  看缺的符号属于哪个库，回来补进 `LIB`。
]

=== 12.5.6 第 5 步：写 `SpaceType` 与区块

先写内部头文件，把 `_Runtime` 结构放进命名空间：

```cpp
/* source/blender/editors/space_sample/sample_intern.hh（新增） */
#pragma once

#include "BKE_screen.hh"
#include "DNA_space_types.h"

namespace blender::ed::sample {

/** Runtime data for the Sample editor. Not saved to .blend files. */
struct SpaceSample_Runtime {
  void *batch = nullptr;      /* 缓存的 GPU batch */
  int draw_count = 0;
};

void register_spacetype();
void register_sample_panels(ARegionType &region_type);

}  // namespace blender::ed::sample
```

注意 `SpaceSample_Runtime` 在命名空间 `blender::ed::sample` 里，而
`DNA_space_types.h` 里的字段声明写成 `ed::sample::SpaceSample_Runtime *runtime` ——
因为该头文件整体在 `namespace blender` 内，`ed::sample::` 是相对 `blender::` 的。
写成 `blender::ed::sample::` 反而容易出错。

再新建 `space_sample.cc`。骨架照 `register_spacetype()`
（#src("source/blender/editors/space_spreadsheet/space_spreadsheet.cc:774")）：

```cpp
/* source/blender/editors/space_sample/space_sample.cc（新增） */
#include "BKE_screen.hh"

#include "BLI_listbase.h"
#include "BLI_string_utf8.h"

#include "DNA_screen_types.h"
#include "DNA_space_types.h"

#include "ED_screen.hh"
#include "UI_interface_layout.hh"
#include "UI_resources.hh"

#include "sample_intern.hh"

namespace blender::ed::sample {

static SpaceLink *sample_create(const ScrArea * /*area*/, const Scene * /*scene*/)
{
  SpaceSample *space = MEM_new<SpaceSample>("sample space");
  space->runtime = MEM_new<SpaceSample_Runtime>(__func__);
  space->spacetype = SPACE_SAMPLE;

  {
    ARegion *region = BKE_area_region_new();      /* Header. */
    BLI_addtail(&space->regionbase, region);
    region->regiontype = RGN_TYPE_HEADER;
    region->alignment = (U.uiflag & USER_HEADER_BOTTOM) ? RGN_ALIGN_BOTTOM : RGN_ALIGN_TOP;
  }
  {
    ARegion *region = BKE_area_region_new();      /* Sidebar. */
    BLI_addtail(&space->regionbase, region);
    region->regiontype = RGN_TYPE_UI;
    region->alignment = RGN_ALIGN_RIGHT;
    region->flag = RGN_FLAG_HIDDEN;
  }
  {
    ARegion *region = BKE_area_region_new();      /* Main window. */
    BLI_addtail(&space->regionbase, region);
    region->regiontype = RGN_TYPE_WINDOW;
  }

  return reinterpret_cast<SpaceLink *>(space);
}

static void sample_free(SpaceLink *sl)
{
  SpaceSample *space = reinterpret_cast<SpaceSample *>(sl);
  MEM_delete(space->runtime);
}

static void sample_init(wmWindowManager * /*wm*/, ScrArea * /*area*/) {}

static SpaceLink *sample_duplicate(SpaceLink *sl)
{
  const SpaceSample *old_space = reinterpret_cast<SpaceSample *>(sl);
  SpaceSample *new_space = static_cast<SpaceSample *>(MEM_dupalloc(old_space));
  new_space->runtime = MEM_new<SpaceSample_Runtime>(__func__, *old_space->runtime);
  return reinterpret_cast<SpaceLink *>(new_space);
}

static void sample_keymap(wmKeyConfig *keyconf)
{
  WM_keymap_ensure(keyconf, "Sample Generic", SPACE_SAMPLE, RGN_TYPE_WINDOW);
}

/* --- 区块回调 ---
 * 主工作区用空实现（真实实现见 12.4 的绘制小节）；头部与侧栏委托给框架。 */
static void sample_main_region_draw(const bContext * /*C*/, ARegion * /*region*/) {}
static void sample_main_region_listener(const wmRegionListenerParams * /*params*/) {}
static void sample_header_region_draw(const bContext *C, ARegion *region)
{
  ED_region_header(C, region);
}
static void sample_header_region_listener(const wmRegionListenerParams * /*params*/) {}
static void sample_sidebar_init(wmWindowManager *wm, ARegion *region)
{
  ED_region_panels_init(wm, region);
}
static void sample_sidebar_listener(const wmRegionListenerParams * /*params*/) {}

void register_spacetype()
{
  std::unique_ptr<SpaceType> st = std::make_unique<SpaceType>();
  ARegionType *art;

  st->spaceid = SPACE_SAMPLE;
  STRNCPY_UTF8(st->name, "Sample");
  st->iconid = ICON_FILE_SCRIPT;

  st->create = sample_create;
  st->free = sample_free;
  st->init = sample_init;
  st->duplicate = sample_duplicate;
  st->keymap = sample_keymap;

  /* regions: main window */
  art = MEM_new_zeroed<ARegionType>("spacetype sample region");
  art->regionid = RGN_TYPE_WINDOW;
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_VIEW2D | ED_KEYMAP_FRAMES;
  art->lock = REGION_DRAW_LOCK_ALL;
  art->draw = sample_main_region_draw;
  art->listener = sample_main_region_listener;
  BLI_addhead(&st->regiontypes, art);

  /* regions: header */
  art = MEM_new_zeroed<ARegionType>("spacetype sample header region");
  art->regionid = RGN_TYPE_HEADER;
  art->prefsizey = HEADERY;
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_VIEW2D | ED_KEYMAP_HEADER | ED_KEYMAP_FRAMES;
  art->lock = REGION_DRAW_LOCK_ALL;
  art->draw = sample_header_region_draw;
  art->listener = sample_header_region_listener;
  BLI_addhead(&st->regiontypes, art);

  /* regions: right panel buttons */
  art = MEM_new_zeroed<ARegionType>("spacetype sample right region");
  art->regionid = RGN_TYPE_UI;
  art->prefsizex = UI_SIDEBAR_PANEL_WIDTH;
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_FRAMES;
  art->lock = REGION_DRAW_LOCK_ALL;
  art->init = sample_sidebar_init;
  art->layout = ED_region_panels_layout;
  art->draw = ED_region_panels_draw;
  art->listener = sample_sidebar_listener;
  BLI_addhead(&st->regiontypes, art);

  register_sample_panels(*art);

  BKE_spacetype_register(std::move(st));
}

}  // namespace blender::ed::sample
```

六个必须注意的细节：

- *`BLI_addhead` 而不是 `BLI_addtail`*。区块顺序影响布局处理顺序；
  `space_spreadsheet.cc` 里*全部用 `BLI_addhead`*，我们保持一致。
- *`create` 里必须先 `MEM_new<SpaceSample>` 再设 `runtime`*。参考
  #src("source/blender/editors/space_spreadsheet/space_spreadsheet.cc:56")。
- *`free` 只释放非 `SpaceLink` 数据*。`SpaceType::free` 的注释明确写着
  "Not free spacelink itself"（#src("source/blender/blenkernel/BKE_screen.hh:113")），
  框架负责释放 `SpaceLink` 本身。
- *`spacetype = SPACE_SAMPLE` 必须设*。很多代码靠 `SpaceLink::spacetype`
  判断当前编辑器，不只靠 `ScrArea::spacetype`。
- *`keymap` 至少要 `WM_keymap_ensure` 建一个空表*，否则后续给这个编辑器加
  快捷键时会找不到表。`operatortypes` 则允许不设（本示例没有自己的操作符）。
- *`iconid` 用的是 `ICON_*` 枚举*，与菜单里选编辑器时的图标一致。

=== 12.5.7 第 6 步：加面板

新建 `sample_panels.cc`，照抄 `spreadsheet_panels.cc` 的 28 行结构：

```cpp
/* source/blender/editors/space_sample/sample_panels.cc（新增） */
#include "BLI_listbase.h"
#include "BLI_string_utf8.h"

#include "BKE_screen.hh"
#include "BLT_translation.hh"
#include "UI_interface_layout.hh"
#include "UI_resources.hh"

#include "sample_intern.hh"

namespace blender::ed::sample {

static void sample_settings_panel_draw(const bContext * /*C*/, Panel *panel)
{
  ui::Layout &layout = *panel->layout;
  PointerRNA *ptr = ui::panel_custom_data_get(panel);

  ui::Layout &col = layout.column(false);
  col.prop(ptr, "sample_value", UI_ITEM_NONE, std::nullopt, ICON_NONE);
  col.prop(ptr, "display_style", UI_ITEM_NONE, std::nullopt, ICON_NONE);
}

void register_sample_panels(ARegionType &region_type)
{
  PanelType *panel_type = MEM_new_zeroed<PanelType>(__func__);
  STRNCPY_UTF8(panel_type->idname, "SAMPLE_PT_settings");
  STRNCPY_UTF8(panel_type->label, N_("Settings"));
  STRNCPY_UTF8(panel_type->translation_context, BLT_I18NCONTEXT_DEFAULT_BPYRNA);
  panel_type->space_type = SPACE_SAMPLE;
  panel_type->region_type = RGN_TYPE_UI;
  panel_type->flag = PANEL_TYPE_DEFAULT_CLOSED;
  panel_type->draw = sample_settings_panel_draw;
  BLI_addtail(&region_type.paneltypes, panel_type);
}

}  // namespace blender::ed::sample
```

面板 `draw` 的签名是 `void (*)(const bContext *C, Panel *panel)`
（#src("source/blender/blenkernel/BKE_screen.hh:391")），
`panel->layout` 是 `ui::Layout*`（#src("source/blender/makesdna/DNA_screen_types.h:256")）。

#pitfall[
  面板里的 RNA 属性名（`"sample_value"`）必须与 `rna_def_space_sample()` 里
  `RNA_def_property(srna, "sample_value", ...)` 的名字*逐字符一致*。
  名字对不上不会编译报错，而是在运行时打印 "property not found" 并静默跳过 ——
  现象是"面板是空的"。自查面板问题时先看这里。
]

=== 12.5.8 第 7 步：接入 `ED_spacetypes_init()`

```cpp
/* source/blender/editors/space_api/spacetypes.cc（改） */
#include "spreadsheet_intern.hh"   /* 现有 */
#include "sample_intern.hh"        /* 新增 */
```

```cpp
/* source/blender/editors/space_api/spacetypes.cc:88 附近（改） */
  spreadsheet::register_spacetype();
  sample::register_spacetype();       /* 新增这一行 */
```

两点：

- *不需要改 `ED_space_api.hh`*。电子表格的注册函数没有在那里声明，因为它在
  命名空间里；我们的也一样 —— 只要 `spacetypes.cc` 能看到 `sample_intern.hh`。
  这提示了一个规律：*`ED_spacetype_*` 是历史遗留的全局符号，新代码应该放进
  命名空间*。所以 12.5.1 节表里的第 10 步指的是改 CMake，不是改头文件。
- *`using namespace blender::ed;` 在函数体内*（
  #src("source/blender/editors/space_api/spacetypes.cc:65")），所以
  `ED_spacetypes_init()` 里可以直接写 `sample::register_spacetype();`，
  不必写全 `ed::sample::`。

=== 12.5.9 第 8 步：构建与验证

```bash
$ cmake --build ../build_windows --target blender
```

（构建命令细节见第 2 章。）构建通过后，验证四件事：

1. *编辑器类型菜单里有 "Sample"*。点任意编辑器左上角的类型按钮，新条目应出现在
   列表里。没有的话：检查 `rna_enum_space_type_items` 是否加了、注册函数是否被调用、
   `spaceid` 是否撞车（看 stderr 有没有 `error: redefinition of spacetype`）。
2. *头部正常显示*。高度为 0 或内容错乱时：检查 `art->prefsizey = HEADERY` 与 `art->draw`。
3. *按 <kbd>N</kbd> 弹出右侧栏，面板标题是 "Settings"*。栏空着：检查
   `panel_type->space_type` / `region_type` 是否与 `st->spaceid` / `art->regionid`
   一致。栏根本不出来：检查 `sample_create` 里是否创建了 `RGN_TYPE_UI` 区块。
4. *Python 侧能访问*：

```python
import bpy
area = bpy.context.area
area.type = 'SAMPLE'
print(area.spaces.active.sample_value)
area.spaces.active.sample_value = 3.5
```

第 4 步报 `AttributeError` 说明 RNA 结构没注册成功，回头看 12.5.4 的两个调用点。

=== 12.5.10 六种典型故障

#figure(
  kind: table,
  table(
    columns: (2.2fr, 4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*症状*], [*最可能的原因*]),
    [编辑器不出现在列表里], [`rna_enum_space_type_items` 没加，或注册函数没被调用],
    [`error: redefinition of spacetype`], [`spaceid` 与已有编辑器重复（注意 `SPACE_SCRIPT` 也占一个）],
    [能切过去但一片空白], [`art->draw` 没设，或 `draw` 里既没清背景也没画东西],
    [面板不出现], [`panel_type->space_type` / `region_type` 不匹配，或 `rna_Space_refine` 漏改],
    [面板出现但空], [`col.prop()` 的属性名与 RNA 注册名不一致],
    [链接期 `undefined reference`], [`space_api/CMakeLists.txt` 的 `LIB` 里没加新库，或 `add_subdirectory` 漏了],
  ),
  caption: [新增编辑器时六种典型故障及其原因。],
) <tbl-new-editor-pitfalls>

#summary[
  新增一个编辑器，本质上是把*类型层*补齐：一个枚举值（`SPACE_SAMPLE`）、
  一个 DNA 结构（`SpaceSample`）、一个 RNA 结构（`SpaceSample`）、
  一个 `SpaceType`（含若干 `ARegionType`）、若干 `PanelType`，
  最后在 `ED_spacetypes_init()` 里注册一行。
  数据层（`ScrArea` / `ARegion`）完全不用改 —— 框架会按 `SpaceType::create`
  的返回值自动创建它们。
  这也解释了为什么 *Python 做不到这件事*：`bpy` 只暴露了 RNA 结构这一层，
  而注册一个 `SpaceType` 需要 C++ 侧的 `BKE_spacetype_register()`，
  没有任何 Python 入口。
]

#exercise[
  *练习 12.1（读源码）* 打开 #src("source/blender/editors/space_outliner/space_outliner.cc")，
  找到它的 `BKE_spacetype_register` 调用，回答：（a）它注册了几个 `ARegionType`，
  分别是什么？（b）两个区块的 `keymapflag` 是否相同？（c）它有没有设
  `st->space_subtype_*`？对照 12.1.4 节的表说明为什么。

  *练习 12.2（读源码）* 读 #src("source/blender/editors/space_spreadsheet/space_spreadsheet.cc")
  里的 `spreadsheet_main_region_listener`（同文件:525）与
  `spreadsheet_header_region_listener`（同文件:585），列出各自响应了哪些
  `wmNotifier` 类别，并回答：*为什么主区块需要把重画转发给 footer 与 sidebar*
  （提示：看同文件:518 的注释）？

  *练习 12.3（动手，小）* 在 #src("source/blender/editors/gizmo_library/gizmo_draw_utils.cc:23")
  的 TODO 处动手：把 `wm_gizmo_geometryinfo_draw` 里的 `GPU_batch_create_ex` /
  `GPU_batch_discard` 改成"缓存在 `GizmoGeomInfo` 里"。提示：`GizmoGeomInfo`
  定义在 #src("source/blender/editors/gizmo_library/gizmo_geometry.h:21")。
  改完后用 `--debug-gpu` 与帧计时（第 16 章）验证每帧绘制次数下降。

  *练习 12.4（动手，中等）* 按 12.5 的步骤加一个 `SPACE_SAMPLE` 编辑器。要求：
  （a）头部画一行静态文字 "Sample Editor"（提示：`ED_region_header` 在头部没有
  按钮时会画空白，需要在 `sample_header_region_draw` 里先用 `ui::Layout` 加一个
  `layout.label(...)`）；（b）主工作区用立刻模式画一个随窗口大小变化的网格
  （提示：`immBegin(GPU_PRIM_LINES, ...)` + `GPU_scissor`）；（c）右侧栏有一个
  浮点滑杆 `sample_value`，拖动它会通过 `RNA_def_property_update` 广播通知，
  由 `listener` 收到后重画主工作区。

  *练习 12.5（动手，进阶）* 给示例编辑器加"子类型"：用 `space_subtype_get` /
  `space_subtype_set` / `space_subtype_item_extend` 实现两种模式
  （"网格视图"与"列表视图"），并让 `space_name_get` / `space_icon_get` 返回
  不同名字与图标。参考图像编辑器在这五个回调上的实现，
  位置在 #src("source/blender/editors/space_image/space_image.cc:1250") 到
  #src("source/blender/editors/space_image/space_image.cc:1285")，
  以及它在 #src("source/blender/editors/space_image/space_image.cc:1333") 起的赋值。
  完成后验证：编辑器类型下拉菜单里出现两项，各带不同图标。
]
