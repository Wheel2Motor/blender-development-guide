#import "../common.typ": *

= 附录 B 源码路径索引

// 源码路径：等宽 + 主题色，字号略小于正文。
//
// 必须和 common.typ 的 src() 保持一致：在 / _ - . : 之后插入零宽空格，给长路径
// 制造断行点。否则路径的最小内容宽度会把整张表格撑出版心（正文块只有 16.4cm）。
// 另外把不换行空格（U+00A0，来自正文里的 `\ ` 转义）换成普通空格 ——
// 前者同样阻止断行，还会在路径中间多出一个可见空格。
#let p(path) = {
  let parts = ()
  for c in path.clusters() {
    if c == "\u{00A0}" {
      parts.push(" ")
      continue
    }
    parts.push(c)
    if c in ("/", "_", "-", ".", ":") { parts.push("\u{200B}") }
  }
  text(font: font-mono, size: 0.87em, fill: c-source)[#parts.join()]
}


本附录按「我想做的事 → 先看哪里」组织，而不是按目录树罗列。
用法是：先在下面找到你的问题属于哪个区，再按「先看这里」列给出的入口进去 ——
入口都是*注册点、定义点或分派点*，从那里顺着引用往下读，比通读目录快得多。

路径均以本书的核对基准版本为准（见前言）。行号对应那一版；
你的版本如果不同，请以同名的符号为准检索。

#note[
  列中的路径在斜杠、下划线等处可以折行（折行点由渲染层插入的零宽空格提供），
  折行处*不属于路径本身*；引用时请把两行拼回一条。
  表中所列行号一律针对本书的核对基准版本。
]

== B.1 A 区 —— 找代码

最常见的四类反查：界面文字、操作符、RNA 属性、DNA 字段。

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [从界面文字反查代码],
  [直接全局检索该字符串],
  [界面字符串几乎都是字面量，检索命中处就在定义该控件的地方。
   注意带 `_` 前缀的字符串（如 `"_Operator"`）也可能被翻译系统当作
   `N_()` 包裹的原文，检索时去掉引号只搜词更稳。],

  [从操作符反查实现],
  [#p("source/blender/windowmanager/WM_types.hh:1082")],
  [`wmOperatorType` 是操作符的结构定义：`idname`、`poll`、`exec` / `invoke` /
   `modal` 回调、`ui` 绘制回调、`macro` 与 `flag`。
   先在这里确认这个操作符能提供哪些回调。],

  [从操作符反查注册处],
  [#p("source/blender/windowmanager/intern/wm_operator_type.cc:151")
    #p("source/blender/windowmanager/intern/wm_operators.cc:4235")],
  [`WM_operatortype_append()` 是注册入口；内置操作符的注册清单位于
   `wm_operators.cc`，从 `:4235` 起共 47 处调用。
   在 `wm_operators.cc` 里搜 `WM_OT_<名字>` 就能跳到 `exec` 所在文件。],

  [操作符标志位到底管什么],
  [#p("source/blender/windowmanager/WM_types.hh:184")],
  [`OPTYPE_REGISTER` 写进操作历史与 *Info* 编辑器；
   同文件 `:186` 是 `OPTYPE_UNDO`；`:206` 是 `OPTYPE_INTERNAL`（不进菜单）。
   这两个标志在 Python 里对应 `bl_options = {'REGISTER', 'UNDO'}`。],

  [Python 里操作符基类从哪来],
  [#p("scripts/modules/_bpy_types.py:1095")],
  [`class Operator` 定义在带前导下划线的 `_bpy_types.py`，
   不叫 `bpy_types.py`。同类还有 `Panel`（`:1282`）、`UIList`（`:1286`）、
   `Menu`（`:1294`）、`RenderEngine`（`:1608`）。],

  [从 RNA 属性反查定义],
  [#p("source/blender/makesrna/intern/")],
  [在 `rna_*` 文件里搜 `RNA_def_` 加属性名。
   属性定义统一用 `RNA_def_<类型>`（`RNA_def_int` 等），
   声明处就是属性的全部信息：名字、范围、默认值、描述、子类型。],

  [RNA 属性定义的 C 实现],
  [#p("source/blender/makesrna/intern/rna_define.cc:940")],
  [`RNA_def_struct()` / `RNA_def_int()` 等定义函数都在这一个文件里；
   想知道某个 `RNA_def_*` 到底写了哪些字段，查这里。],

  [RNA 属性的运行时读写],
  [#p("source/blender/makesrna/intern/rna_access.cc:3569")],
  [`RNA_property_float_get()` 一类的访问器在 `rna_access.cc`。
   界面、Python、动画系统都通过它们取值，不直接读 C 结构体字段。],

  [`Space*` 类型的 RNA 定义],
  [#p("source/blender/makesrna/intern/rna_space.cc:4128")],
  [23 个 `Space*` 结构全在这一个文件：基类 `Space` 在 `:4128`，
   `SpaceView3D` 在 `:5650`，序列末尾的 `SpaceSpreadsheet` 在 `:9433`。],

  [从 DNA 字段反查结构体],
  [#p("source/blender/makesdna/")],
  [在 `DNA_*.h` 里搜字段名。这些文件是 `.blend` 的格式定义，
   字段的增删改都会影响文件格式，改动必须谨慎（见 #seealso([§8.3])）。],

  [`bpy.types` 里某类型对应哪个 C++ 结构],
  [#p("scripts/modules/bpy/__init__.py:23"),
    #p("source/blender/makesrna/intern/")],
  [`bpy.types` 的类型由 RNA 在运行时生成，C 侧只暴露 `types` 名字空间。
   反查路径是「RNA 里的 `identifier` 字符串 → `RNA_def_struct` 的调用点」；
   `rna_*` 文件的名字通常就是这个结构所属的领域。],

  [确认符号属于哪个模块],
  [—],
  [`BKE_` / `BLI_` / `ED_` / `WM_` / `DEG_` / `GPU_` / `DRW_` / `RE_` 等
   尾下划线前缀直接指示模块目录，先按前缀缩小范围再搜名字，
   比全局检索快一个数量级。前缀与模块的完整对照见 #seealso([附录 A 的 A.6])。],
)

== B.2 B 区 —— Python 插件与脚本

Python 侧的一切都在 `scripts/` 下（共 9 个子目录、808 个文件、28 万行）。
注意 `scripts/` *不在* `source/` 里 —— 它是随程序分发的数据，
所以能直接改、不用重新编译。

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [插件的发现、启用与加载流程],
  [#p("scripts/modules/addon_utils.py")],
  [`addon_utils` 是插件系统的总入口：扫描目录、解析 `bl_info`
   （`:197` 处直接按 AST 读模块源码，不 import）、
   调用 `register()` / `unregister()`、维护启用状态。],

  [扩展（extension）与插件的关系],
  [#p("scripts/modules/addon_utils.py:28")],
  [文件顶部缓存了扩展仓库信息与"不兼容扩展"表。
   新式扩展用 `blender_manifest.toml` 描述，与旧式 `bl_info` 并存。],

  [`bpy.types` 的 Python 基类],
  [#p("scripts/modules/_bpy_types.py:1095")],
  [*文件名带前导下划线。* 这里定义 `Operator`、`PropertyGroup`、
   `Panel` / `UIList` / `Menu` / `Header`、`RenderEngine` 等基类，
   以及 `_RNAMeta` 元类（决定子类如何变回 RNA 类型）。],

  [`bpy` 包的模块组成],
  [#p("scripts/modules/bpy/__init__.py")],
  [`bpy` 是 Python 包，`__all__` 列出九个公开名字。
   其中 `app` / `context` / `data` / `msgbus` / `props` / `types`
   来自 C 扩展 `_bpy`；`ops` / `path` / `utils` 是同目录的 Python 模块。],

  [`bpy.ops` 为什么能自动补全],
  [#p("scripts/modules/bpy/ops.py")],
  [`bpy.ops` 不是静态生成的模块，而是按需在 `_bpy.ops` 上拼装
   `bpy.ops.<类别>.<操作符>` 的动态包装。],

  [`bpy.path` 的路径工具],
  [#p("scripts/modules/bpy/path.py")],
  [相对路径解析、`//` 前缀展开、文件名清洗等纯 Python 工具。],

  [`bpy.utils` 与预览图 / 工具栏集成],
  [#p("scripts/modules/bpy/utils/__init__.py")
    #p("scripts/modules/bpy/utils/previews.py")
    #p("scripts/modules/bpy/utils/toolsystem.py")],
  [`utils/` 下按功能分模块：`previews.py` 管自定义图标与预览，
   `toolsystem.py` 管工具栏与 gizmo 分组。],

  [`bpy.props` 的源码在哪],
  [#p("source/blender/python/intern/bpy_props.cc")],
  [*没有 `bpy/props.py`。* `bpy.props` 是 C++ 实现，
   由 `bpy/__init__.py:23-30` 的 `from _bpy import props` 暴露。
   想读 `PropertyGroup` 注解的解析逻辑，只能读这个 C++ 文件。],

  [官方内置插件怎么写],
  [#p("scripts/addons_core/")],
  [12 个官方插件，是最可靠的范例来源：
   `io_scene_gltf2/`（大型多文件插件）、`rigify/`（生成器架构）、
   `node_wrangler/`（操作符与键位图）、`pose_library/`（资产集成）、
   `bl_pkg/`（本地包与扩展管理）、`hydra_storm/`（渲染引擎接入）。],

  [操作符 / 面板 / 菜单的注册范例],
  [#p("scripts/startup/bl_operators/")
    #p("scripts/startup/bl_ui/")],
  [`bl_operators/` 是纯 Python 操作符的存放处；
   `bl_ui/` 是全部内置面板与菜单（每个编辑器一个文件，如
   `properties_render.py`、`space_view3d.py`）。
   `scripts/startup/` 下还有两个顶层文件
   `keyingsets_builtins.py` 与 `nodeitems_builtins.py`。],

  [应用模板（app template）],
  [#p("scripts/startup/bl_app_templates_system/")],
  [启动时可选的应用模板；配合命令行 `--app-template` 使用。],

  [界面预设与主题文件],
  [#p("scripts/presets/")],
  [20 个子目录的预设：`interface_theme/`（主题）、`keyconfig/`（键位）、
   `cycles/` 与 `eevee/`（渲染设置）、`camera/` / `cloth/` / `fluid/` 等。
   格式是简单的文本，常被插件复用为"设置模板"。],

  [起手式模板与示例脚本],
  [#p("scripts/templates_py/")],
  [文本编辑器「模板」菜单的来源：`Operator/`、`UI/`、`Gizmo/` 三个目录，
   加上 `addon_add_object.py`、`custom_nodes.py`、`background_job.py`、
   `bmesh_simple.py`、`batch_export.py` 等单文件示例。
   写第一个插件时从这里抄比从零写快。],

  [着色器节点与 OSL / TOML 模板],
  [#p("scripts/templates_osl/")
    #p("scripts/templates_toml/")],
  [OSL 着色器模板与 TOML 模板。],

  [翻译与本地化数据],
  [#p("scripts/site/")
    #p("scripts/freestyle/")],
  [`site/` 放站点相关的生成数据；`freestyle/` 是 Freestyle 线框渲染的
   Python 样式模块。],

  [界面翻译字符串的提取],
  [#p("scripts/modules/")],
  [`scripts/modules/` 下除 `_bpy_types.py`、`addon_utils.py`、`bpy/` 之外，
   还有 `_bl_i18n_utils/` 等以 `_` 开头的内部工具包 ——
   它们是官方工具代码，不是给插件 import 的 API。],
)

== B.3 C 区 —— 数据层：DNA 与 RNA

这一层决定了「什么能存进 `.blend`」与「什么能被 Python 与界面访问」。
它与其它区的最大差别是：这里的文件既是代码，也是*格式契约*。

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [认识 DNA 的量级与组织],
  [#p("source/blender/makesdna/")],
  [97 个 `DNA_*.h` 结构定义文件，每个对应一类数据类型
   （`DNA_object_types.h`、`DNA_mesh_types.h`…）。
   它们是 POD 声明的集合，不含逻辑。],

  [`.blend` 里的自定义属性长什么样],
  [#p("source/blender/makesdna/DNA_ID.h:143")],
  [`IDProperty` 的定义。它是一棵可嵌套的树，
   支持整型 / 浮点 / 字符串 / 数组 / 组，
   是 Python `obj["key"]` 在文件中的实际形态。],

  [给数据块加一个能存进文件的新字段],
  [#p("source/blender/makesdna/DNA_<类型>_types.h")],
  [在对应的 `DNA_*.h` 里加字段，然后在 `makesrna` 里暴露它 ——
   两步都要做，否则字段存得进文件但 Python 与界面看不到。
   加字段会改变 `SDNA` 布局，老文件读取靠版本迁移补齐（见下一行）。],

  [老文件里的字段怎么升级],
  [#p("source/blender/blenloader/intern/versioning_*.cc")],
  [`blenloader/intern/` 下的 `versioning_*` 文件按版本号逐代升级旧数据。
   给 DNA 加字段/改语义时通常要在这里加一段迁移代码。],

  [`.blend` 读写入口],
  [#p("source/blender/blenloader/BLO_readfile.hh:175")
    #p("source/blender/blenloader/BLO_writefile.hh:57")],
  [`BLO_read_from_file()` 读、`BLO_write_file()` 写；
   两者都围绕 `Main` 工作，并用 `SDNA` 做字段映射。],

  [SDNA 的解析与字段访问],
  [#p("source/blender/makesdna/DNA_sdna_types.h:52")
    #p("source/blender/makesdna/DNA_genfile.h:77")],
  [`struct SDNA` 是运行时结构表，`DNA_sdna_from_data()` 从文件头解析出它。
   读写旧文件时"按名字找字段"的逻辑都基于这两个符号。],

  [RNA 属性是怎么定义的],
  [#p("source/blender/makesrna/intern/rna_define.cc:940")],
  [`RNA_def_*` 系列定义函数。所有 `rna_*.cc` 只是在调用它们，
   格式高度统一：定义结构 → 定义属性 → 定义枚举项 → 绑定更新回调。],

  [RNA 运行时结构与属性布局],
  [#p("source/blender/makesrna/intern/rna_internal_types.hh:662")],
  [`struct StructRNA`：`identifier`、`name`、`py_type`、`flag`、
   属性容器 `ContainerRNA cont`。想理解"RNA 到底存了什么"，读这一个结构。],

  [属性值的读写路径],
  [#p("source/blender/makesrna/intern/rna_access.cc")],
  [`rna_access.cc` 是 RNA 的运行时光标：`PointerRNA` 指向数据，
   `PropertyRNA` 描述访问方式，`RNA_property_*_get/set` 执行读写。],

  [RNA 结构的总注册清单],
  [#p("source/blender/makesrna/intern/makesrna.cc")],
  [启动时把各 `rna_*.cc` 的注册函数串起来的总表；
   想知道某个 RNA 文件在不在编译目标里，也从这里看。],

  [知道规模，避免误以为能读完],
  [—],
  [`source/` 下 C/C++ 共 6,365 文件、2,826,648 行；`intern/` 354,206 行；
   `extern/` 561,914 行；`scripts/` Python 808 文件、281,545 行。
   `DNA_*.h` 97 个、`rna_*` 115 个，`RNA_def_` 出现在 50,278 行中。],
)

== B.4 D 区 —— 核心系统

`blenkernel/` / `blenlib/` / `windowmanager/` / `editors/` /
`depsgraph/` 是改动最集中的五个模块。

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [程序从哪里启动],
  [#p("source/creator/creator.cc:332")],
  [`main()` 在这里。它依次初始化 Blender 各子系统，
   随后调用 `WM_init()`（同文件 `:608` 处可见调用点）。],

  [交互框架初始化],
  [#p("source/blender/windowmanager/intern/wm_init_exit.cc:201")],
  [`WM_init()`：建立窗口管理器、注册操作符与键位图、
   调用编辑器类型注册，是"启动时静态建表"的总闸门。],

  [新增 / 修改一个操作符],
  [#p("source/blender/windowmanager/WM_api.hh:1414")],
  [`WM_operatortype_append()` 的声明与用法。
   实现放 `editors/` 下对应编辑器目录，注册调用放 `wm_operators.cc`。],

  [编辑器类型是怎么注册的],
  [#p("source/blender/blenkernel/BKE_screen.hh:763")
    #p("source/blender/editors/space_api/spacetypes.cc:63")],
  [`BKE_spacetype_register()` 是注册入口（`editors/` 下共 19 处调用），
   `ED_spacetypes_init()` 是启动时统一调用的汇总函数。
   Python 无法注册新的编辑器类型，原因就在这条链只认 C++ 类型。],

  [编辑器区域与子分区],
  [#p("source/blender/makesdna/DNA_screen_types.h:610")
    #p("source/blender/makesdna/DNA_screen_types.h:809")],
  [`ScrArea`（区域，`:610`）与 `ARegion`（子分区，`:809`）。
   布局、尺寸、类型常量都在这里，写界面代码时反复要查。],

  [新增一个面板],
  [#p("source/blender/blenkernel/BKE_screen.hh:349")],
  [`PanelType`：`poll` / `draw` / `draw_header` 与它所属的
   `space_type` / `region_type`。C++ 侧照这个填，
   Python 侧继承 `bpy.types.Panel`。],

  [面板 / 菜单的布局怎么写],
  [#p("source/blender/editors/include/UI_interface_layout.hh:115")],
  [`struct Layout`（旧称 `uiLayout`）的流式 API：
   `row()` / `column()` / `split()` / `prop()` / `operator()`。
   界面代码的 90% 都在和它打交道。],

  [依赖图怎么建、怎么求值],
  [#p("source/blender/depsgraph/intern/depsgraph.hh:50")
    #p("source/blender/depsgraph/intern/builder/")],
  [`struct Depsgraph` 是图本体（节点、关系、时间源）；
   `intern/builder/` 负责按数据依赖建图，
   `intern/eval/` 负责求值与写回。],

  [标记数据脏（tag）],
  [#p("source/blender/depsgraph/DEG_depsgraph.hh:123")
    #p("source/blender/makesdna/DNA_ID.h:1048")],
  [`DEG_id_tag_update()` 是标记入口，标志位定义在 `IDRecalcFlag`
   （`DNA_ID.h:1048`）。标志位选错是"改了没反应"或"改了全刷新"的常见原因。],

  [拿到求值后的结果],
  [#p("source/blender/depsgraph/DEG_depsgraph_query.hh:95")],
  [`DEG_get_evaluated_id()` 与它的模板版本 `DEG_get_evaluated<T>()`。
   绘制与渲染只读求值后副本，绝不直接改原始 ID。],

  [写回同步（writeback）],
  [#p("source/blender/depsgraph/")],
  [入口是 `deg::sync_writeback::add()`，定义于
   `source/blender/depsgraph/DEG_depsgraph_writeback_sync.hh:29`。
   它注册一个「求值结束后执行」的任务，用于必须改原始数据块的场合
   （例如增加 `ID.us` 这类非原子计数）—— 它是少数"求值会改原始数据"的例外，
   改动时要格外小心。],

  [修饰器类型怎么注册与分派],
  [#p("source/blender/blenkernel/BKE_modifier.hh:187")
    #p("source/blender/blenkernel/intern/modifier.cc:90")],
  [`ModifierTypeInfo` 是回调表；修饰器在启动时填进
   `modifier.cc` 的类型数组，运行时用 `BKE_modifier_get_info()` 取回。],

  [节点类型怎么注册],
  [#p("source/blender/nodes/NOD_register.hh:37")
    #p("source/blender/nodes/intern/node_register.cc")],
  [`NOD_REGISTER_NODE` 宏既生成注册包装函数，又是
   `discover_nodes.py` 的检索标记；`node_register.cc` 里的
   `register_nodes()` 是总入口。节点实现在 `nodes/` 的
   `geometry/` / `shader/` / `composite/` / `function/` / `texture/` 下。],

  [通用数据结构与并行原语],
  [#p("source/blender/blenlib/BLI_task.h:196")
    #p("source/blender/makesdna/DNA_listBase.h:36")],
  [`BLI_task_parallel_range()` 是最常用的并行入口；
   `ListBase` 是最常见的容器头（C++ 侧用 `ListBaseT<T>`）。
   `blenlib/` 下还有字符串、路径、数学、内存池等主题文件。],

  [内存分配与泄漏排查],
  [#p("intern/guardedalloc/MEM_guardedalloc.h:352")],
  [`MEM_new` / `MEM_delete` 是推荐的 C++ 分配方式；
   用 `--debug-memory` 启动可打开保护字节与泄漏报告，
   泄漏会按分配名（通常是 `__func__`）归类输出。],

  [屏幕布局与区域尺寸计算的实现],
  [#p("source/blender/editors/screen/")],
  [区域划分、拖拽、边距与 `screen_edit` 逻辑都在这里；
   与 `wmEvent` 的事件处理合起来构成"窗口交互"的完整实现。],

  [撤销系统怎么接入],
  [#p("source/blender/editors/include/ED_undo.hh:38")],
  [`ED_undo_push()` 是 C++ 侧的推入点。它只在操作符声明了
   `OPTYPE_UNDO` 时才有意义 —— 标志位与推入调用必须成对。],
)

== B.5 E 区 —— 渲染与 GPU

这一区跨三个模块：`render/` 管管线与引擎接口，`gpu/` 管后端抽象，
`draw/` 管视口绘制。三者边界容易混，记住一句话：
*`render/` 决定"渲染什么"，`draw/` 决定"视口怎么画"，`gpu/` 只负责"怎么调显卡"。*

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [自定义渲染引擎（Python）],
  [#p("source/blender/render/RE_engine.h:131")
    #p("source/blender/makesrna/intern/rna_render.cc")],
  [`struct RenderEngine` 是引擎元数据（`render` / `view_draw` /
   `view_update` / `update_script_node` 回调）；
   RNA 侧在 `rna_render.cc` 定义，Python 的
   `bpy.types.RenderEngine` 就是它。],

  [内置渲染引擎注册],
  [#p("source/blender/render/intern/engine.cc:97")],
  [`RE_engines_register()` 把引擎类型加入注册表；
   Workbench、EEVEE 与外部引擎都从这里进入管线。],

  [渲染管线主流程],
  [#p("source/blender/render/intern/pipeline.cc")],
  [一帧渲染从创建 `Render` 到写文件的主循环；
   它在关键节点调用 `DEG_evaluate_on_framechange()` 触发依赖图求值
   （同目录 `engine.cc:715` 也是同类调用点）。],

  [EEVEE 的实现],
  [#p("source/blender/draw/engines/eevee/")],
  [EEVEE 属于 `draw/` 模块下的一个绘制引擎，
   但它同时被视口与最终渲染使用 —— 这是它和 Cycles 最大的结构差别。],

  [Workbench / Overlay / 选择 Pass],
  [#p("source/blender/draw/engines/workbench/")
    #p("source/blender/draw/engines/overlay/")
    #p("source/blender/draw/engines/select/")],
  [视口专用引擎。`select/` 生成选择缓冲（用于拾取），
   `overlay/` 画线框、辅助线、gizmo，`workbench/` 是实体模式渲染。],

  [视口一次绘制从哪里开始],
  [#p("source/blender/draw/DRW_engine.hh:61")
    #p("source/blender/draw/intern/draw_context.cc:1624")],
  [`DRW_draw_view()` 是入口，实现在 `draw_context.cc`；
   它负责组装绘制上下文、依次驱动各绘制引擎与绘制缓存。],

  [GPU 抽象层从哪进],
  [#p("source/blender/gpu/GPU_batch.hh:75")
    #p("source/blender/gpu/intern/gpu_shader_private.hh:52")],
  [`blender::gpu::Batch` 是一次绘制的参数集合，
   `blender::gpu::Shader` 是编译后的着色器程序。
   后端无关接口在 `gpu/*.hh`，实现按 GL / Vulkan / Metal 特化。],

  [内置着色器的源码与生成流程],
  [#p("source/blender/gpu/shaders/")],
  [GLSL 源文件、`.bsl.hh` 与 `infos/` 下的接口描述。
   着色器由 C++ `ShaderCreateInfo` 描述后编译成后端代码。],

  [合成器（compositor）],
  [#p("source/blender/compositor/COM_node_operation.hh:28")],
  [`NodeOperation` 是合成节点的执行基类；现代合成器把节点图
   编译成可复用的求值流程，而不是逐像素回调。
   节点类型定义在 `source/blender/nodes/composite/`。],

  [Cycles],
  [#p("intern/cycles/")],
  [Cycles *不在* `source/blender/` 下，而是独立内部库，
   可单独构建（CMake 配置见 `build_files/cmake/config/cycles_standalone.cmake`）。
   改 Cycles 的编译成本与改 `source/` 完全不同，先确认这一点。],

  [GPU 调试开关],
  [—],
  [`--debug-gpu` 打印 GPU 操作；`--debug-gpu-compile-shaders` 打印着色器
   编译信息；`--debug-gpu-force-workarounds` 强制兼容性变通。
   完整清单见附录 C 的 C.4.3。],

  [性能分析（CPU / GPU）],
  [#p("intern/profile/PRF_profile.hh")
    #p("extern/tracy_profiler/")],
  [`intern/profile/` 是内置的轻量采样器（`PRF_*` 宏）；
   第三方 Tracy 分析器在 `extern/tracy_profiler/`。
   定位依赖图耗时先用 `--debug-depsgraph-time`（见附录 C 的 C.4.3）。],
)

== B.6 F 区 —— 构建与工程

构建系统的所有内容都在仓库根目录与 `build_files/` 下，
`source/` 里只有各模块自己的 `CMakeLists.txt`。

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [构建入口（三平台通用）],
  [#p("make.bat")
    #p("GNUmakefile")],
  [#win 用 `make.bat`（`GNUmakefile:175` 明确声明不面向 Windows）；
   #mac #linux 用 `make`。两者最终都驱动同一套 CMake 配置。],

  [CMake 构建配置的定义位置],
  [#p("CMakeLists.txt:29")],
  [根 `CMakeLists.txt`：最低 CMake 版本 3.21、编译器要求、
   全局选项与 `add_subdirectory` 顺序都在这里。],

  [查某个编译开关叫什么、默认值是什么],
  [#p("build_files/cmake/config/")
    #p("build_files/cmake/macros.cmake:480")],
  [`config/` 下是配置预设：`blender_release.cmake`、`blender_developer.cmake`、
   `blender_full.cmake`、`blender_lite.cmake`、`blender_headless.cmake`、
   `bpy_module.cmake`、`cycles_standalone.cmake`。
   预设里的选项名就是可直接传给 CMake 的开关名。],

  [模块 → CMake 目标名怎么对应],
  [#p("source/blender/blenkernel/CMakeLists.txt:743")],
  [每个模块用 `blender_add_lib(bf_<模块> …)` 建静态库，
   并加 `add_library(bf::<模块> ALIAS …)` 别名。
   所以链接时见到 `bf::blenkernel`、`bf::blenlib` 就是模块库；
   可执行文件目标名是 `blender`（`source/creator/CMakeLists.txt:338`）。],

  [平台相关的编译设置],
  [#p("build_files/cmake/platform/")],
  [#win 的编译器版本门槛写在这里：
   `CMAKE_CXX_COMPILER_VERSION` 必须 ≥ `19.44.35216`
   （对应 VS2022 17.14.14，见 `platform_win32.cmake:42`）；
   各平台的产物形态与应用包设置也在这个目录。],

  [Windows 构建脚本细节],
  [#p("build_files/windows/")],
  [`parse_arguments.cmd`（开关解析）、`set_build_dir.cmd`
   （构建目录命名）、`check_libraries.cmd`（预编译库检查）、
   `autodetect_msvc.cmd`、`build_ninja.cmd` / `build_msbuild.cmd`。
   开关全集见附录 C 的 C.2.1。],

  [依赖（预编译库）从哪来、怎么更新],
  [#p(".gitmodules")
    #p("build_files/utils/make_update.py")],
  [四个预编译库子模块：`lib/windows_x64`、`lib/windows_arm64`、
   `lib/macos_arm64`、`lib/linux_x64`，以 Git LFS 子模块方式提供；
   更新用 `make update` / `make.bat update`。],

  [自行编译全部依赖],
  [#p("build_files/build_environment/")],
  [`make deps` 的实现在这里。只在无法使用预编译库时走这条路
   （例如 Intel Mac：官方没有 `macos_x64` 库，见附录 D 的注意框）。],

  [构建工具与打包辅助脚本],
  [#p("build_files/utils/")],
  [`make_update.py` / `make_utils.py`（更新与公共函数）、
   `make_test.py`（测试驱动）、`make_bpy_wheel.py`（构建 bpy wheel）、
   `make_source_archive.py`、`make_benchmark.py`。],

  [发行包与平台打包],
  [#p("build_files/package_spec/build_archive.py")
    #p("build_files/cmake/packaging.cmake")],
  [打二进制归档 / 源码归档的逻辑，以及各平台安装包生成；
   `make package_archive` / `make source_archive` 走这里。],

  [持续集成配置],
  [#p("build_files/buildbot/")],
  [官方构建机器的配置；离线开发时一般用不到，
   但它是"官方发布到底开了哪些开关"的权威来源。],

  [macOS / Linux 的构建目录名],
  [—],
  [#mac 是 `build_darwin`（`OS_NCASE` 为 `darwin`，
   `macos` 只是预编译库目录名）；#linux 是形如 `build_linux` 的名字。
   详见附录 D。],
)

== B.7 G 区 —— 测试

三类测试各自独立：C++ 单元测试（GoogleTest）、Python 集成测试、
以及需要人工目视的渲染对比测试。

#table(
  columns: (1.85fr, 2.25fr, 4.15fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*我想做的事*], [*先看这里*], [*说明*]),

  [测试总入口],
  [#p("tests/")
    #p("build_files/utils/make_test.py")],
  [`make test` 由 `make_test.py` 驱动；
   `tests/` 下分 `python/`、`gtests/`、`performance/`、`coverage/`、
   `files/`（测试数据，走 Git LFS）等。],

  [写 C++ 单元测试],
  [#p("tests/gtests/")],
  [`gtests/runner/` 是测试运行器与断言基础设施，
   各模块自己的 `tests/` 子目录放具体用例
   （例如 `source/blender/blenlib/tests/`）。
   用 `with_tests` / `-DWITH_GTESTS=ON` 打开。],

  [写 Python 集成测试],
  [#p("tests/python/")],
  [按领域分文件：`bl_pyapi_*.py`（Python API 行为）、
   `bl_rna_*.py`（RNA 一致性）、`bl_operator_*.py`（操作符 API）、
   `bl_mesh_*.py`、`bl_node_*.py`、`bl_blendfile_*.py`（文件读写与库链接）
   等。命名规律是 `bl_<领域>_<主题>.py`。],

  [无头运行 Blender 并执行脚本],
  [#p("tests/utils/blender_headless.py")],
  [测试常用的无头封装；同目录还有
   `bl_run_operators.py`（批量执行操作符）、
   `bl_run_operators_event_simulate.py`（模拟事件序列）、
   `batch_load_blendfiles.py`。],

  [渲染结果对比测试],
  [#p("tests/python/eevee_render_tests.py")
    #p("tests/python/cycles_render_tests.py")
    #p("tests/python/workbench_render_tests.py")],
  [按引擎分文件。它们与 `tests/files/` 中的参考图比较，
   属于需要 GPU 的测试，通常不在本地全部执行。],

  [检查代码风格与许可证头],
  [#p("GNUmakefile")],
  [`make check_pep8` / `check_mypy` / `check_cppcheck` /
   `check_licenses` / `check_spelling_*` / `format`。
   完整目标清单见附录 C 的 C.3.1。],

  [界面截图回归测试],
  [#p("tests/python/ui_screenshot_tests.py")],
  [对界面控件做截图比对；改界面代码后值得先执行一次。],

  [验证插件全部可加载],
  [#p("tests/python/bl_load_addons.py")
    #p("tests/python/bl_load_py_modules.py")],
  [前者逐个加载 addon 并检查注册/注销，
   后者加载 `scripts/` 下的所有 Python 模块。
   改了 `scripts/` 之后这两项是最省事的回归。],
)

== B.8 一屏速查：五个最常被问到的入口

#table(
  columns: (2.6fr, 5.6fr),
  inset: 5pt,
  align: (left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*问题*], [*直接打开*]),

  [程序从哪启动],
  [#p("source/creator/creator.cc:332")],

  [操作符怎么注册],
  [#p("source/blender/windowmanager/WM_api.hh:1414")
    #p("source/blender/windowmanager/intern/wm_operators.cc:4235")],

  [编辑器类型怎么注册],
  [#p("source/blender/blenkernel/BKE_screen.hh:763")],

  [Python 的类基类在哪],
  [#p("scripts/modules/_bpy_types.py:1095")],

  [改完数据怎么让界面刷新],
  [#p("source/blender/depsgraph/DEG_depsgraph.hh:123")
    #p("source/blender/windowmanager/WM_types.hh:362")],
)

#summary[
  这份索引的用法可以压缩成一句话：*不要从目录树往下读，要从"注册点"往下读。*
  Blender 的扩展机制是「定义描述结构体 + 启动时注册进全局表」（见 #seealso([§0.2])），
  所以任何一个功能的答案都在两处：描述结构体的定义（决定它能做什么），
  以及它被注册进表的那一行（决定它被谁调用）。
  B.1 教你从用户可见的东西反查到这两处，B.2–B.7 则给出每个领域
  *注册点所在的确切文件*。
]
