#import "../common.typ": *

= 附录 A 术语表

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


本附录收录全书出现频率最高的内部术语，按所属层次分五组：
*数据层*（进得了 `.blend` 的东西）、*系统层*（启动与运行时框架）、
*编辑器与界面*、*求值与渲染*、*构建与工程 / Python 插件*。

每条的「来源」列给出定义所在的源码位置，均以本书的核对基准版本为准
（见前言）。带尾下划线的前缀（`BKE_`、`ED_`、`DEG_` 等）是模块归属标记，
不是类型名，速查见 A.6。

#note[
  「来源」列里的路径在斜杠、下划线等处可以折行（折行点由渲染层插入的零宽空格提供），
  折行处*不属于路径本身*；引用时请把两行拼回一条（例如 `source/blender/blenkernel/` 与
  `BKE_screen.hh:763` 合成 `source/blender/blenkernel/BKE_screen.hh:763`）。
]

#warn[
  本表刻意区分三种东西：*数据结构*（DNA 里的 POD 结构体）、
  *描述结构体*（`...Type` 后缀，装回调指针的注册元数据）、
  *运行时实例*（进程内活着的对象）。同一个词在不同语境下指哪一个，
  先看它有没有 `Type` 后缀。
]

== A.1 数据层

这一组是"能被存进 `.blend`、能被链接、能被依赖图引用"的东西。

#table(
  columns: (1.4fr, 1.0fr, 3.05fr, 2.75fr),
  inset: 5pt,
  align: (left, left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*术语*], [*英文*], [*含义*], [*来源*]),

  [DNA],
  [DNA],
  [Blender 的*磁盘内存布局描述语言*：把 C 结构体声明当作可执行文件里的元数据，
   让 `.blend` 能跨版本、跨平台读写。它就是 `makesdna` 目录里那批 `DNA_*.h` 文件。],
  [#p("source/blender/makesdna/DNA_ID.h")],

  [SDNA],
  [SDNA],
  [DNA 的*运行时表示*：结构名表、成员名表、类型长度与对齐表，
   从 `.blend` 文件头（或可执行文件）解析而来。],
  [#p("source/blender/makesdna/DNA_sdna_types.h:52")],

  [`DNA_sdna_from_data`],
  [—],
  [从一块 `DNA1` 数据（`.blend` 内的 `SDNA` 块或可执行文件的 `DNAstr` 段）
   解析出 `SDNA`；读取旧文件的第一步。],
  [#p("source/blender/makesdna/DNA_genfile.h:77")],

  [`blend` 文件],
  [`.blend` file],
  [以 `SDNA` 元数据 + 按块存放的 ID 数据构成的文件，可做内存映射式读取；
   与平台、指针宽度无关。],
  [#p("source/blender/blenloader/BLO_readfile.hh:175")],

  [ID],
  [ID / data-block],
  [*数据块的基类*。所有可保存、可被引用、有名字的实体（Object、Mesh、Scene、
   Material…）都以 `ID` 开头，靠 `ID.name` 唯一定位、
   靠 `ID.session_uid` 在会话内标识。],
  [#p("source/blender/makesdna/DNA_ID.h:409")],

  [`BKE_id_new`],
  [—],
  [在给定的 `Main` 中新建一个数据块（按 `ID_Type` 分派），并把它挂进对应链表。
   Python 侧 `bpy.data.objects.new()` 最终走到这里。],
  [#p("source/blender/blenkernel/BKE_lib_id.hh:186")],

  [IDProperty],
  [ID property],
  [挂在任意 ID 上的*自定义属性树*，是 Python 里能写进 `.blend` 的唯一通用容器
   （`obj["mykey"] = 1`）；支持整型、浮点、字符串、数组、嵌套组。],
  [#p("source/blender/makesdna/DNA_ID.h:143")],

  [Library],
  [library],
  [一个被链接进来的 `.blend`；`ID.lib` 指向它。它是"链接"与"追加"的判定依据，
   也是库覆盖（override）的锚点。],
  [#p("source/blender/makesdna/DNA_ID.h:539")],

  [override],
  [library override],
  [在本地 `Main` 中为链入的 ID 生成一份*可编辑副本*，并把对它原始数据的改动
   记录成可回放的覆盖操作，用于资产管线。],
  [#p("source/blender/blenkernel/BKE_lib_override.hh:164")],

  [blenloader],
  [—],
  [负责读写 `.blend` 的模块：`BLO_read_*` / `BLO_write_*` 与版本迁移
   （旧文件字段升级到新结构）。],
  [#p("source/blender/blenloader/BLO_writefile.hh:57")],

  [Asset],
  [asset],
  [带自定义预览与元数据的 ID，是资产库（Asset Library）的最小单位。],
  [#p("source/blender/asset_system/AS_asset_representation.hh:44")],

  [evaluated ID],
  [evaluated ID],
  [求值后副本，又称 *COW 副本*。当前正式名称是 copy-on-evaluation；COW 是
   copy-on-write 留下的历史缩写。它由依赖图持有，
   包含修饰器 / 节点树作用后的结果；求值器写它，绘制与渲染只读它。
   原始 ID 永远只服务于编辑。],
  [#p("source/blender/depsgraph/DEG_depsgraph_query.hh:95")],
)

== A.2 系统层

这一组是程序启动时搭起来的框架：数据库根、窗口管理器、
以及"一切皆注册类型"所依赖的那些描述结构体。

#table(
  columns: (1.4fr, 1.0fr, 3.05fr, 2.75fr),
  inset: 5pt,
  align: (left, left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*术语*], [*英文*], [*含义*], [*来源*]),

  [Main],
  [main database],
  [一个运行会话的*数据库根*：按 ID 类型分链表持有全部数据块。
   打开文件就是新建/替换一个 `Main`。所有 `BKE_*` 函数几乎都要 `Main *bmain`
   参数，原因就在这里。],
  [#p("source/blender/blenkernel/BKE_main.hh:239")],

  [WM],
  [window manager],
  [`wm` 前缀所属模块。管窗口、事件、操作符注册表、键位图、任务与通知；
   `WM_init()` 是启动阶段初始化整个交互框架的入口。],
  [#p("source/blender/windowmanager/intern/wm_init_exit.cc:201")],

  [操作符],
  [operator],
  [*所有用户可见动作的统一表示*。一个操作符有 `idname`（如 `object.delete`）、
   `poll`（当前上下文能否执行）、`exec` / `invoke` / `modal` 回调与一组属性。
   注册进全局表后，菜单、快捷键、Python、命令行都能调用它。],
  [#p("source/blender/windowmanager/WM_types.hh:1082")],

  [`WM_operatortype_append`],
  [—],
  [把一个操作符类型注册进全局表；内置操作符的注册清单是 `wm_operators.cc`
   里的一长串调用，共 47 处。],
  [#p("source/blender/windowmanager/WM_api.hh:1414")],

  [`OPTYPE_REGISTER`],
  [—],
  [操作符标志：把本次操作写进 *Info* 编辑器与操作历史（`F3` 可重复上一个）。
   常与 `OPTYPE_UNDO`（同文件 `:186`）配对使用。],
  [#p("source/blender/windowmanager/WM_types.hh:184")],

  [notifier],
  [notifier],
  [`NC_*` / `ND_*` 位掩码构成的消息，用于*跨编辑器*刷新：
   编辑器只监听自己关心的类别，不直接调用别人的重绘。
   `WM_event_add_notifier()` 在帧末批量派发。],
  [#p("source/blender/windowmanager/WM_types.hh:362")],

  [`wmEvent`],
  [window event],
  [一次输入事件（键、鼠标、定时器、文件拖放），带修饰键状态、按下/释放类型
   与派发目标区域。],
  [#p("source/blender/windowmanager/WM_types.hh:795")],

  [keymap],
  [key map],
  [把「键位组合 + 修饰键 + 区域/模式」映射到操作符的结构。
   `wmKeyMap` 按 `spaceid` / `regionid` 分组，运行时可被用户配置覆盖。],
  [#p("source/blender/makesdna/DNA_windowmanager_types.h:418")],

  [`wmKeyMapItem`],
  [key map item],
  [键位图里的一条绑定：`modal` 按键序列、`type` / `val` / `shift` 等字段，
   以及要调用的操作符 `idname`。],
  [#p("source/blender/makesdna/DNA_windowmanager_types.h:344")],

  [`WM_keymap_add_item`],
  [—],
  [向一张键位图添加一条绑定，返回新建的 `wmKeyMapItem *` 供继续设置属性。],
  [#p("source/blender/windowmanager/WM_keymap.hh:98")],

  [`BKE_`],
  [—],
  [*Blender Kernel* 前缀，`blenkernel/` 模块。放不依赖界面、
   但需要同时了解多种数据类型的核心逻辑（对象、场景、ID 管理、修饰器分派）。],
  [#p("source/blender/blenkernel/BKE_main.hh")],

  [`BLI_`],
  [—],
  [*Blender Library* 前缀，`blenlib/` 模块。通用数据结构、字符串、数学、
   线程、内存池与任务调度；不含 Blender 业务语义。],
  [#p("source/blender/blenlib/BLI_task.h:196")],

  [`ED_`],
  [—],
  [*Editor* 前缀，`editors/` 模块。界面与交互逻辑：屏幕布局、
   各编辑器的绘制与事件处理、操作符的 `exec` 实现。],
  [#p("source/blender/editors/space_api/spacetypes.cc:63")],

  [`WM_`],
  [—],
  [`windowmanager/` 模块，管窗口、事件、操作符注册、键位图、通知与任务。],
  [#p("source/blender/windowmanager/WM_api.hh")],

  [`GPU_`],
  [—],
  [`gpu/` 模块，跨后端（OpenGL / Vulkan / Metal）的图形抽象层，
   含缓冲、着色器、纹理、绘制调用与后端实现。],
  [#p("source/blender/gpu/GPU_batch.hh:75")],

  [`DNA_`],
  [—],
  [`makesdna/` 下的结构体声明文件；这些文件是 `.blend` 的格式定义，
   改动会改变文件格式。],
  [#p("source/blender/makesdna/DNA_ID.h")],

  [`RNA_`],
  [—],
  [`makesrna/` 下的属性定义 API（`RNA_def_*`）与运行时访问 API，
   是 C++ 数据到 Python / 界面 / 属性编辑器的映射层。],
  [#p("source/blender/makesrna/intern/rna_define.cc:940")],
)

== A.3 编辑器与界面

这一组的关键区别是：`SpaceType` / `PanelType` 是 C++ 注册的描述结构体，
而 `ScrArea` / `ARegion` 是每个窗口里真实存在很多份的数据。

#table(
  columns: (1.4fr, 1.0fr, 3.05fr, 2.75fr),
  inset: 5pt,
  align: (left, left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*术语*], [*英文*], [*含义*], [*来源*]),

  [RNA],
  [RNA],
  [*反射层*。用 `RNA_def_*` 注册的结构与属性，同时提供四种能力：
   运行时读写 C 数据、自动生成 Python 绑定、驱动界面属性控件、支持撤销与动画。
   名字取自 "DNA 的运行时替身"。],
  [#p("source/blender/makesrna/intern/rna_internal_types.hh:662")],

  [`RNA_def_struct`],
  [—],
  [在 RNA 里声明一个结构（`identifier`）并指定它继承自哪个结构。
   `rna_space.cc` 里 23 个 `Space*` 都是这样定义的。],
  [#p("source/blender/makesrna/intern/rna_define.cc:940")],

  [SpaceType],
  [space type],
  [*一个编辑器类型*（如 3D 视图、节点编辑器）的注册元数据：`idname`、
   区域回调、窗口槽、操作符与键位图。*必须由 C++ 注册*，
   Python 拿不到这个入口。],
  [#p("source/blender/blenkernel/BKE_screen.hh:100")],

  [`BKE_spacetype_register`],
  [—],
  [注册一个 `SpaceType`；每一种编辑器在启动时调用一次，
   `editors/` 下共 19 处。],
  [#p("source/blender/blenkernel/BKE_screen.hh:763")],

  [`ED_spacetypes_init`],
  [—],
  [启动阶段注册全部编辑器类型的总入口，由窗口管理器初始化流程调用。],
  [#p("source/blender/editors/space_api/spacetypes.cc:63")],

  [ScrArea],
  [screen area],
  [屏幕上的*编辑器区域*（一个矩形槽位），持有 `SpaceLink *spacedata`
   与区域链表、窗口矩阵。是"这个编辑器在哪、多大"的载体。],
  [#p("source/blender/makesdna/DNA_screen_types.h:610")],

  [ARegion],
  [area region],
  [区域内部的*子分区*（侧栏、标题栏、工具头、浮动面板）。
   类型由 `regiontype` 常量区分，交互与绘制按分区分别实现。],
  [#p("source/blender/makesdna/DNA_screen_types.h:809")],

  [PanelType],
  [panel type],
  [可折叠 UI 面板的注册元数据：`poll` / `draw` / `draw_header` 回调与
   面板在哪个 `space_type` / `region_type` 下出现。
   Python 的 `bpy.types.Panel` 就是它的映射。],
  [#p("source/blender/blenkernel/BKE_screen.hh:349")],

  [MenuType],
  [menu type],
  [菜单的注册元数据：`draw` 回调负责逐条添加条目。
   与面板共用 `PanelType` 的很多字段，Python 侧对应 `bpy.types.Menu`。],
  [#p("source/blender/blenkernel/BKE_screen.hh:656")],

  [`Layout`],
  [uiLayout],
  [面板绘制时描述布局的*流式对象*：`row()` / `column()` / `split()` /
   `prop()` / `operator()` 依次声明控件，由界面系统负责具体排版。
   旧代码与 Python 侧仍称 `uiLayout`。],
  [#p("source/blender/editors/include/UI_interface_layout.hh:115")],

  [`SpaceView3D`],
  [—],
  [3D 视图编辑器的 RNA 结构，`Space` 的子类；`Space*` 在 `rna_space.cc`
   中共 23 个定义，这是其中最常用的一个。],
  [#p("source/blender/makesrna/intern/rna_space.cc:5650")],

  [draw manager],
  [draw manager],
  [`draw/` 模块，负责把依赖图求值后的数据提交给 GPU：
   管理绘制引擎（EEVEE、Workbench、Overlay…）、缓存与 Pass。
   `DRW_draw_view()` 是视口一次完整绘制的入口。],
  [#p("source/blender/draw/DRW_engine.hh:61")],
)

== A.4 求值与渲染

这一组回答"我改了参数，屏幕上为什么变了"以及"变了之后谁把它画出来"。

#table(
  columns: (1.4fr, 1.0fr, 3.05fr, 2.75fr),
  inset: 5pt,
  align: (left, left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*术语*], [*英文*], [*含义*], [*来源*]),

  [depsgraph],
  [dependency graph],
  [*依赖图*。一张"谁依赖谁"的有向图：节点是 ID 与 ID 上的具体运算
   （几何、变换、着色…），边是数据依赖。它决定求值顺序与并行度，
   也是"改了参数为什么界面会变"的答案。],
  [#p("source/blender/depsgraph/intern/depsgraph.hh:50")],

  [`DEG_`],
  [—],
  [`depsgraph/` 模块：建图、标记脏、求值、查询求值结果。],
  [#p("source/blender/depsgraph/DEG_depsgraph.hh:123")],

  [COW],
  [copy-on-write（历史缩写；当前称 copy-on-evaluation）],
  [*求值时复制*。求值时不改原始 ID，而是生成求值后副本；求值器写副本，
   绘制与渲染等下游只读副本，撤销与编辑仍作用于原始数据。],
  [#p("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.h")],

  [tag（标记脏）],
  [tag / tagged for update],
  [告诉依赖图「这个 ID 的某类数据变了」，标志位是 `ID_RECALC_*`
   （如 `ID_RECALC_TRANSFORM`、`ID_RECALC_GEOMETRY`）。
   只标不立即求值，下一帧统一刷新。],
  [#p("source/blender/makesdna/DNA_ID.h:1048")],

  [`DEG_id_tag_update`],
  [—],
  [C++ 侧标记 ID 脏的标准入口；对全体已注册依赖图生效。],
  [#p("source/blender/depsgraph/DEG_depsgraph.hh:123")],

  [evaluation mode],
  [evaluation mode],
  [依赖图按用途分模式求值，例如视口交互（`DAG_EVAL_VIEWPORT`）
   与最终渲染（`DAG_EVAL_RENDER`）—— 两者对细分、简化、
   预览设置的处理不同，这是"视口与出图不一致"的常见根源。],
  [#p("source/blender/depsgraph/DEG_depsgraph.hh:46")],

  [`ModifierTypeInfo`],
  [modifier type info],
  [修饰器类型的回调表：`deform`、`modify_geometry`、`generate_geometry`、
   `panel_register` 等。修饰器在启动时注册进一张按 `ModifierType` 索引的数组，
   运行时用 `BKE_modifier_get_info()` 取回。],
  [#p("source/blender/blenkernel/BKE_modifier.hh:187")],

  [`bNodeType`],
  [node type],
  [一个节点类型的定义：输入 / 输出 socket 声明、`init` / `free` /
   `update` 回调、执行方式（CPU 函数、GPU 着色器、几何节点字段…）。],
  [#p("source/blender/blenkernel/BKE_node.hh:264")],

  [`bNodeSocketType`],
  [node socket type],
  [socket 的类型定义：`idname`、`type`（`SOCK_FLOAT` / `SOCK_VECTOR` /
   `SOCK_GEOMETRY`…）与 `subtype`，决定连线时的隐式转换规则。],
  [#p("source/blender/blenkernel/BKE_node.hh:163")],

  [`NOD_REGISTER_NODE`],
  [—],
  [节点注册的宏标记。它一方面生成可被外部调用的注册包装函数，
   另一方面作为 `discover_nodes.py` 的检索标记，
   由脚本生成"注册全部节点"的调用代码。],
  [#p("source/blender/nodes/NOD_register.hh:37")],

  [`RenderEngine`],
  [render engine],
  [渲染引擎的*运行时实例*：`type` 指向 `RenderEngineType`，另持
   `re`（`Render`）、`depsgraph`、`py_instance` 等本次渲染的状态。
   `render`、`draw`、`view_draw`、`view_update`、`update_script_node`
   等回调*不*在这里，它们属于注册元数据 `RenderEngineType`
   （`RE_engine.h:71`；按上面的约定，带 `Type` 后缀的那个才是描述结构体）。
   Python 侧派生自定义引擎用的 `bpy.types.RenderEngine` 名字虽然如此，
   注册字段（`bl_use_preview` 等）实际写在引擎类型上。],
  [#p("source/blender/render/RE_engine.h:131")],

  [EEVEE],
  [EEVEE],
  [实时光栅化渲染引擎，同时用于视口与最终渲染；
   实现位于 `draw/engines/eevee/`。],
  [#p("source/blender/draw/engines/eevee/")],

  [Cycles],
  [Cycles],
  [路径追踪渲染引擎。它*不*在 `source/blender/` 下，
   而是作为独立内部库位于 `intern/cycles/`，可单独构建。],
  [#p("intern/cycles/")],

  [compositor],
  [compositor],
  [节点式后期合成器。其 C++ 侧由 `compositor/` 提供，
   节点类型定义在 `nodes/composite/`；现代实现把节点图编译成
   可复用的求值流程，而不是逐像素回调解算。],
  [#p("source/blender/compositor/COM_node_operation.hh:28")],

  [`GPUBatch`],
  [GPU batch],
  [一次绘制调用的*完整参数集合*：几何缓冲（`GPUVertBuf`）、索引缓冲、
   图元类型与着色器。C++ 侧实际类型为 `blender::gpu::Batch`，按后端特化。],
  [#p("source/blender/gpu/GPU_batch.hh:75")],

  [`GPUShader`],
  [GPU shader],
  [编译后的着色器程序及其接口（属性、uniform、纹理槽）。
   后端无关的部分在 `GPU_shader.hh`，具体实现按 GL / Vulkan / Metal 特化。],
  [#p("source/blender/gpu/intern/gpu_shader_private.hh:52")],
)

== A.5 构建与工程 / Python 插件

这一组偏工程实践：内存与容器基础设施、构建目标，以及 Python 侧那些
"看起来在 Python 里、其实要读 C++"的东西。

#table(
  columns: (1.4fr, 1.0fr, 3.05fr, 2.75fr),
  inset: 5pt,
  align: (left, left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*术语*], [*英文*], [*含义*], [*来源*]),

  [guardedalloc],
  [guarded allocator],
  [`MEM_*` 内存分配器（`intern/guardedalloc/`）。所有分配都带名字与统计，
   `--debug-memory` 下还会加保护字节检测越界写；配套的泄漏检测能按分配名
   列出未释放块。新代码推荐 `MEM_new` / `MEM_delete`。],
  [#p("intern/guardedalloc/MEM_guardedalloc.h")],

  [`MEM_new`],
  [—],
  [类型安全的分配：返回 `T *` 并直接构造，释放用 `MEM_delete`。
   底层落到 `mem_guarded::internal::mem_mallocN_aligned_ex`。],
  [#p("intern/guardedalloc/MEM_guardedalloc.h:352")],

  [`ListBase`],
  [list base],
  [Blender 的*侵入式双向链表头*：只有 `first` / `last` 两个指针，
   节点自己带 `next` / `prev`。DNA 里到处是它，因为它是 POD、
   跨平台布局稳定。C++ 侧常用 `ListBaseT<T>` 模板包装。],
  [#p("source/blender/makesdna/DNA_listBase.h:36")],

  [`BLI_task`],
  [—],
  [任务与并行原语：`BLI_task_parallel_range()` 最常用，
   把 `[begin, end)` 区间切成块分给工作线程；还有并行 for 与图调度。],
  [#p("source/blender/blenlib/BLI_task.h:196")],

  [CMake 目标],
  [CMake target],
  [每个模块通过 `blender_add_lib(bf_<模块> …)` 生成一个静态库目标，
   并加上 `bf::<模块>` 别名供其它目标链接；可执行文件目标名是 `blender`。],
  [#p("build_files/cmake/macros.cmake:480")],

  [`bpy.types`],
  [—],
  [`bpy.types` 不是纯 Python：`Operator`、`Panel`、`Menu`、`UIList`、
   `PropertyGroup`、`RenderEngine` 等基类定义在 `scripts/modules/_bpy_types.py`
   （*文件名的前导下划线不可省*），其余类型由 RNA 在运行时生成。],
  [#p("scripts/modules/_bpy_types.py:1095")],

  [`bpy.props`],
  [—],
  [*不是 Python 文件*。它是 C 实现 `bpy_props.cc`，
   通过 `from _bpy import props` 暴露给 Python，
   所以 `bpy.props` 没有对应的 `.py` 源码可读 —— 要读就读 C++。],
  [#p("source/blender/python/intern/bpy_props.cc")],

  [`foreach_get` / `foreach_set`],
  [—],
  [`bpy_prop_collection` 的批量读写：一次调用把整个数组搬进 / 搬出
   `numpy` 或 `array` 缓冲，避开逐元素 Python 属性访问的开销。
   C 实现是两个函数共用的一段逻辑。],
  [#p("source/blender/python/intern/bpy_rna.cc:5975")],

  [addon],
  [add-on / plug-in],
  [放在 `scripts/addons_core/`（官方内置）或用户扩展目录下的 Python 包，
   通过 `register()` / `unregister()` 挂载清理。
   `scripts/addons_core/` 下共 12 个。],
  [#p("scripts/modules/addon_utils.py")],

  [extension],
  [extension],
  [打包为 zip 并带 `blender_manifest.toml` 的*新式分发单位*，
   由扩展仓库管理，可在线安装与更新；与旧式 addon 并存。],
  [#p("scripts/modules/addon_utils.py:28")],

  [`bl_info`],
  [—],
  [旧式 addon 顶部的元数据字典（名称、作者、版本、`blender` 版本区间…）。
   由 `addon_utils` 直接读取模块源码解析，而不是 import 后才读。],
  [#p("scripts/modules/addon_utils.py:197")],

  [`register()`],
  [—],
  [addon 的挂载入口：在这里注册操作符、面板、属性组、键位图与事件处理器。
   Blender 在启用插件时调用它。],
  [#p("scripts/modules/addon_utils.py:544")],
)

== A.6 尾下划线前缀速查

这些前缀是*模块归属标记*，出现在几乎每个导出符号上。
认出前缀就能猜到函数该去哪里找、能不能在 Python 里用。

#table(
  columns: (1.4fr, 2.4fr, 6.2fr),
  inset: 5pt,
  align: (left, left, left),
  stroke: 0.4pt + luma(78%),
  table.header([*前缀*], [*模块目录*], [*职责与典型符号*]),

  [`BKE_`], [`blenkernel/`],
  [核心业务逻辑，需要 `Main` 或跨数据类型知识。`BKE_id_new`、`BKE_modifier_get_info`],

  [`BLI_`], [`blenlib/`],
  [通用基础设施，无 Blender 业务语义。`BLI_task_parallel_range`、`BLI_path_join`],

  [`ED_`], [`editors/`],
  [界面与交互实现。`ED_spacetypes_init`、`ED_undo_push`],

  [`WM_`], [`windowmanager/`],
  [窗口、事件、操作符注册、键位图、通知。`WM_operatortype_append`、`WM_event_add_notifier`],

  [`DEG_`], [`depsgraph/`],
  [依赖图的构建、标记与求值。`DEG_id_tag_update`、`DEG_get_evaluated_id`],

  [`GPU_`], [`gpu/`],
  [后端无关的图形抽象。`GPU_batch_create`、`GPU_shader_create_from_info`],

  [`DRW_`], [`draw/`],
  [绘制引擎与绘制缓存管理。`DRW_draw_view`、`DRW_engines_register`],

  [`RE_`], [`render/`],
  [渲染管线与渲染引擎接口。`RenderEngine`、`RE_engines_register`],

  [`MOD_`], [`modifiers/`],
  [修饰器的具体实现（每个修饰器一个文件）。],

  [`NOD_`], [`nodes/`],
  [节点类型与节点求值的声明。`NOD_REGISTER_NODE`、`register_geometry_nodes`],

  [`DNA_`], [`makesdna/`],
  [*磁盘格式*结构体声明，是 `.blend` 的内存布局契约。],

  [`RNA_`], [`makesrna/`],
  [属性定义与运行时访问。`RNA_def_struct`、`RNA_property_float_get`],

  [`ID_`], [`makesdna/`],
  [数据块的类型枚举与标志位。`ID_RECALC_*`、`ID_Type`],

  [`BM_`], [`bmesh/`],
  [可编辑网格的拓扑结构（BMesh）与迭代器。],

  [`MEM_`], [`intern/guardedalloc/`],
  [内存分配与统计。`MEM_new`、`MEM_delete`],

  [`BLO_`], [`blenloader/`],
  [`.blend` 的读写与版本迁移。`BLO_read_from_file`、`BLO_write_file`],
)

#summary[
  读这份术语表有一个省时间的用法：*先认前缀判断层次，再看有没有 `Type` 后缀判断
  它是数据还是注册元数据。* `ModifierTypeInfo`、`SpaceType`、`wmOperatorType`、
  `bNodeType`、`RenderEngineType` 都是同一类东西 —— 装回调的结构体；
  而 `ScrArea`、`ARegion`、`wmKeyMap`、`bNodeSocketType` 是真正被持有很多份的数据。
  全书反复出现的"注册模式"（#seealso([§0.2])）就建立在后一类是 POD、
  前一类只在启动时填一次这个分工上。
]
