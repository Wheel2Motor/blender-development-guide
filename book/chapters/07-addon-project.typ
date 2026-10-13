#import "../common.typ": *

= 第 7 章 综合案例：完整 Addon 项目

第 3 章到第 6 章是分头讲的：`bpy` 的类型是怎么生成的、addon 从被导入到被卸载
经过哪些环节、面板与操作符怎么搭出界面、批量数据怎么又快又安全地读写。
每一章都单独看得懂，但例子都是"为了说明一个知识点"而写的片段。

这一章换一种做法：*从一个真实需求出发，把它做成一个可以打包、安装、
长期维护的多文件 addon*。过程中不引入新的 API 概念，但会反复用到前四章的东西，
并且会碰上前四章刻意绕开的那些麻烦：文件拆开之后谁导入谁、
`register()` 和 `unregister()` 为什么必须镜像、属性定义改了为什么不生效、
`poll` 什么时候会失败。

== 7.1 需求分析与结构设计

=== 7.1.1 选题：网格质检工具 `Mesh Inspector`

我们从三个候选方向中选择一个。判断标准不是题目是否新奇，而是
*它能否自然覆盖本章要求的知识点*，避免为了展示 API 而拼凑功能。

#figure(
  kind: table,
  table(
    columns: (1.2fr, 0.8fr, 0.9fr, 1.4fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*候选*], [*操作符*], [*偏好设置*], [*适合本章吗*]),
    [批量重命名 / 层级整理],
    [多],
    [弱],
    [偏简单：难点在字符串规则而非 addon 结构],
    [按规则批量导出],
    [少],
    [强],
    [好，但严重依赖其他 addon（glTF / OBJ 导出器）是否启用，示例不稳定],
    [*网格统计与检查*],
    [适中],
    [强],
    [*最合适*],
  ),
  caption: [三个候选方向的比较],
) <tbl-candidates>

选择网格质检的理由：

- *结果天然是"集合"*。一次检查产生若干条问题记录，这正好需要
  `CollectionProperty` 做数据模型，而不是为了演示而硬造一个列表。
- *阈值天然是"偏好"*。多大的面算退化面、多少非流形边算不合格 ——
  这些是用户级配置，属于 `AddonPreferences` 的正统用途。
- *既有只读操作，也有修改操作*。检查本身不改数据，而"选中问题物体"改选择状态。
  这给了我们一个绝好的对照，用来讲清 `UNDO` 什么时候该加、什么时候不该加。
- *不依赖任何其他 addon*，只用到 `bpy` 和 `bmesh`，读者照抄就能跑。

项目定名为 *Mesh Inspector*，模块名 `mesh_inspector`。正文按主题拆解文件；
可直接安装的完整项目随书提供。#example-file("ch07/mesh_inspector")

=== 7.1.2 功能边界与目录结构

先把"不做什么"写清楚，这比写"做什么"更重要。一个 addon 失控，
通常不是因为功能太少，而是因为边界没定。

*要做*：对选中（或全部）网格物体做几何体检，产出五类问题记录 ——
面数与顶点数统计、退化面（面积近似 0）、非流形边、孤立边、未应用的物体缩放；
把结果存进场景供界面长期显示；一键选中所有有问题的物体；
把结果导出成文本报告；阈值可通过偏好设置调整。

*不做*：不自动修复几何（破坏性操作，交给用户决定）；
不碰编辑模式下的网格（官方 UV 导出工具在需要操作几何时会先切回物体模式，
见 #src("scripts/addons_core/io_mesh_uv_layout/__init__.py:141")，
我们这里直接要求用户在物体模式下使用）；不注册快捷键。

多文件 addon 的第一件事是分目录。原则只有一条：
*按"什么时候需要它"分层，而不是按"它是什么类型"分层*。

```bash
mesh_inspector/
├── __init__.py      # bl_info、模块重载、register()/unregister() 总调度
├── prefs.py         # AddonPreferences + 阈值 PropertyGroup
├── properties.py    # 数据模型：一条问题记录、一次检查的结果
├── inspect.py       # 纯计算层：不 import bpy，不碰界面
├── operators.py     # 操作符：检查、选中问题物体、导出报告
├── ui.py            # 面板 + UIList
└── report.py        # 报告文本的生成与写盘
```

依赖方向是单向的：`inspect.py` ← `operators.py` ← `ui.py`，
`properties.py` 与 `prefs.py` 被三者共用。

#tip[
  `inspect.py` 刻意不 `import bpy`。它接收 `Mesh` 对象和一组阈值，
  返回普通的 Python 数据。这样它可以脱离 Blender 单独测试，
  也让"检查算法"和"Blender 集成"这两件事可以分别演进。
  这是把第 6 章的数据操作经验产品化的关键一步。
]

#warn[
  相对导入是这里的第一个易错点。子模块里必须写 `from . import properties`，
  不能写 `import properties`。后者在 `addons/` 目录安装方式下可能"碰巧能用"
  （因为 addon 目录被加进了 `sys.path`，见
  #src("scripts/modules/addon_utils.py:56-L58")），
  但一旦你的 addon 被安装成扩展（模块名前缀变成 `bl_ext.<repo>.`），
  或者别的 addon 里也有个叫 `properties` 的模块，就会导入错误的对象。
  详见 7.4.5。
]

=== 7.1.3 `bl_info`：真实字段清单

`bl_info` 是一个普通字典，Blender 只认其中一部分键。权威清单在
#src("scripts/modules/addon_utils.py:692-L705") 的 `_bl_info_basis()` 里，
它定义了所有会被补全默认值的字段：`name`、`author`、`version`、`blender`、
`location`、`description`、`doc_url`、`support`、`category`、`warning`、
`show_expanded`。几个容易写错的地方：

- `version` 和 `blender` 是 *元组*，不是字符串。`(1, 0, 0)` 对，`"1.0.0"` 错。
  `version` 取三元组，`blender` 写"最低需要"的版本，如 `(5, 2, 0)`。
- `support` 的合法取值由 RNA 枚举决定。官方自带工具用 `'OFFICIAL'`
  （#src("scripts/addons_core/io_mesh_uv_layout/__init__.py:16")），
  第三方 addon 应当用 `'COMMUNITY'`。
- `doc_url` 里可以写占位符 `{BLENDER_MANUAL_URL}`。
  #src("scripts/modules/addon_utils.py:735-L742") 会在读取时把它替换成
  与当前 Blender 版本匹配的手册地址；官方 addon 就是这么用的
  （#src("scripts/addons_core/io_mesh_uv_layout/__init__.py:15")）。
- `category` 决定偏好设置里的分类标签，写错不报错，只是显示得奇怪。

我们的 `bl_info`：

```python
bl_info = {
    "name": "Mesh Inspector",
    "author": "Blender 开发指南编写组",
    "version": (1, 0, 0),
    "blender": (5, 2, 0),
    "location": "3D Viewport > Sidebar > Mesh Inspector",
    "description": "Inspect mesh geometry: degenerate faces, non-manifold and loose edges",
    "warning": "",
    "doc_url": "",
    "support": 'COMMUNITY',
    "category": "Mesh",
}
```

#pitfall[
  `author` 字段在加载时会被正则处理一次：`<...>` 包裹的部分会被删掉，
  见 #src("scripts/modules/addon_utils.py:744-L748")。注释写明了原因 ——
  维护者邮箱会被直接展示给用户，容易招来私人邮件。
  所以别把邮箱当联系方式写在 `author` 里，那不会生效。
]

=== 7.1.4 第 3–6 章的哪些东西会在这里出现

为了让本章的定位清楚，先列出"复用清单"。如果你对其中某一项没印象，
回去翻对应章节，本章不会重新解释：

- *操作符的三个回调*（第 3、5 章）：`poll` / `execute` / `invoke`，
  以及 `report()` 反馈 —— 见 7.2.2，`poll` 失败的排查见 7.4.4；
- *`bpy.props` 各属性类型与参数*（第 4、5 章）：
  阈值与偏好设置 —— 见 7.2.4，参数名核实表见 7.2.5；
- *`PropertyGroup` + `PointerProperty` + `CollectionProperty`*（第 4、5 章）：
  数据模型与挂载 —— 见 7.2.4；
- *面板的位置四件套*（第 5 章）：
  `bl_space_type` / `bl_region_type` / `bl_category` / `bl_label` —— 见 7.2.6；
- *`foreach_get` 与 `numpy` 批量读网格*（第 6 章）：
  位置与面积的高效读取 —— 见 7.2.7；
- *模块生命周期与代码重载*（第 4 章）：重载的四种做法 —— 见 7.4.1。

== 7.2 插件入口与操作符

=== 7.2.1 `__init__.py`：总调度与重载

`__init__.py` 只做四件事：声明元数据、处理代码重载、按顺序注册、按顺序卸载。
它*不*实现任何功能。

```python
# mesh_inspector/__init__.py

bl_info = { ... }   # 见 7.1.3

# --- 代码重载 ---------------------------------------------------------------
# 用户在偏好设置里点 "Reload Scripts" 时，Python 会重新执行本模块。
# 此时 `bpy` 已在局部命名空间里，这是官方 addon 判断"本次是重载"的惯用手法。
# 参见 scripts/addons_core/io_scene_gltf2/__init__.py:47。
if "bpy" in locals():
    import importlib
    from . import prefs, properties, inspect, report, operators, ui
    for _mod in (properties, prefs, inspect, report, operators, ui):
        importlib.reload(_mod)

import bpy

from . import prefs, properties, inspect, report, operators, ui

# 顺序是有意义的：先属性组，再由属性组派生的偏好与数据模型，
# 最后才是使用它们的操作符和界面。
_classes = (
    properties.MSI_Finding,
    properties.MSI_ObjectSummary,
    properties.MSI_Result,
    prefs.MSI_Thresholds,
    prefs.MSI_Preferences,
    operators.MSI_OT_inspect,
    operators.MSI_OT_select_flagged,
    operators.MSI_OT_export_report,
    ui.MSI_UL_findings,
    ui.MSI_PT_main,
    ui.MSI_PT_settings,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)

    # 场景级数据模型：上一次检查的结果集合 + 当前选中的记录。
    bpy.types.Scene.msi_result = bpy.props.PointerProperty(type=properties.MSI_Result)

    # 物体级数据模型：每个物体自己的阈值覆盖。
    bpy.types.Object.msi_thresholds = bpy.props.PointerProperty(type=prefs.MSI_Thresholds)


def unregister():
    # 卸载顺序与注册顺序严格相反：先删最后加的 bpy.types 属性。
    del bpy.types.Object.msi_thresholds
    del bpy.types.Scene.msi_result

    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
```

`register()` / `unregister()` 的对称性不是风格偏好，
Blender 自己的工具函数就是这么实现的：

```python
# scripts/modules/bpy/utils/__init__.py:1001（节选）
def register_classes_factory(classes):
    def register():
        for cls in classes:
            register_class(cls)

    def unregister():
        for cls in reversed(classes):
            unregister_class(cls)

    return register, unregister
```

注意 `reversed(classes)`。为什么必须反过来？

- *类型之间的依赖*。若 `MSI_OT_inspect` 的属性引用了 `MSI_Finding`，
  注册时属性组必须先存在；卸载时就必须先卸掉引用它的操作符，
  否则会留下悬空引用。
- *界面与数据的依赖*。`MSI_PT_main` 的 `draw()` 会读
  `context.scene.msi_result`。面板先卸、数据后卸，
  中间不会出现"面板还在但数据没了"的窗口。

对 `bpy.types` 上的属性也一样：先注册的先删。所以 `msi_result`
在 `register()` 里最后加，在 `unregister()` 里最先删。

#pitfall[
  最常见的卸载泄漏不是"忘了删"，而是*删除顺序错了*。
  典型症状：禁用再启用 addon 后，面板报 `AttributeError`，
  或者执行 `bpy.ops.preferences.addon_disable` 之后 Blender 在退出时崩溃。
  如果只记得本文的一句话，记这句：*`unregister()` 是 `register()` 的录像倒放*。
]

=== 7.2.2 操作符（一）：只读的检查操作符

核心操作符。它是一个*只读*操作符 —— 除了往 `scene.msi_result`
里写结果之外不改动任何用户数据。

```python
# mesh_inspector/operators.py（节选一：检查操作符）

import bpy

from . import inspect
from . import properties
from . import report as report_mod


class MSI_OT_inspect(bpy.types.Operator):
    """对选中的网格物体做几何体检"""

    bl_idname = "mesh_inspector.inspect"
    bl_label = "Inspect Selected Meshes"
    bl_description = "Check selected mesh objects for common geometry problems"

    # 注意：这里【没有】UNDO。
    # 本操作符不修改任何可撤销的数据，加 UNDO 只会污染撤销栈。
    bl_options = {'REGISTER'}

    use_selection_only: bpy.props.BoolProperty(
        name="Selection Only", default=True,
        description="Only inspect selected objects instead of every mesh in the scene",
    )
    clear_previous: bpy.props.BoolProperty(
        name="Clear Previous Results", default=True,
        description="Discard the results of the previous run before inspecting",
    )

    @classmethod
    def poll(cls, context):
        # poll 只回答"现在能不能跑"，不做实际工作，也不该有副作用。
        if context.mode != 'OBJECT':
            return False
        if context.scene is None:
            return False
        return any(obj.type == 'MESH' for obj in context.scene.objects)

    @staticmethod
    def _iter_targets(context, use_selection):
        candidates = context.selected_objects if use_selection else context.scene.objects
        for obj in candidates:
            if obj.type == 'MESH' and obj.data is not None:
                yield obj

    def execute(self, context):
        scene = context.scene
        result = scene.msi_result

        if self.clear_previous:
            result.findings.clear()
            result.object_summaries.clear()
            result.active_index = 0
            result.checked_objects = 0

        thresholds = context.preferences.addons[__package__].preferences.thresholds

        targets = list(self._iter_targets(context, self.use_selection_only))
        if not targets:
            # CANCELLED 表示"什么都没发生"，此时不应留下撤销记录。
            self.report({'WARNING'}, "没有找到要检查的网格物体")
            return {'CANCELLED'}

        total_issues = 0
        for obj in targets:
            # 物体级阈值可覆盖全局偏好（见 7.2.4）。
            limits = obj.msi_thresholds if obj.msi_thresholds.override else thresholds
            object_findings = inspect.inspect_mesh(obj, limits)

            for finding in object_findings:
                item = result.findings.add()
                item.object_name = obj.name
                item.check = finding.check
                item.severity = finding.severity
                item.count = finding.count
                item.detail = finding.detail

            result.add_summary(
                obj.name, object_findings,
                face_count=len(obj.data.polygons),
                vert_count=len(obj.data.vertices),
            )
            result.checked_objects += 1
            total_issues += sum(f.count for f in object_findings)

        if total_issues == 0:
            self.report({'INFO'}, f"检查完成：{len(targets)} 个物体，未发现问题")
        else:
            self.report(
                {'WARNING'},
                f"检查完成：{len(targets)} 个物体，发现 {total_issues} 处问题",
            )

        return {'FINISHED'}
```

这里有四处值得停下来看。

*第一，只读操作符的 `bl_options` 只写 `{'REGISTER'}`，不写 `{'REGISTER', 'UNDO'}`。*
`UNDO` 的含义在 C 侧定义里写得很明确
（#src("source/blender/windowmanager/WM_types.hh:186")）：它要求操作符在返回
`FINISHED` 时压入一个撤销事件，注释写明 *"mandatory if the operator modifies
Blender data"（若操作符修改 Blender 数据则必须加）*。
反过来说：*不改数据就不要加*。给只读操作符加 `UNDO`，
用户按一次 Ctrl+Z 会撤销掉一次"什么都没改"，纯粹是干扰。

而 `REGISTER`（#src("source/blender/windowmanager/WM_types.hh:184")）是另一回事：
它让操作符出现在信息编辑器里、并支持重做面板。要做参数化的操作符就该开。

Python 侧 `bl_options` 的 RNA 定义在
#src("source/blender/makesrna/intern/rna_wm.cc:2297")，合法取值就是
`rna_enum_operator_type_flag_items` 里的那些
（#src("source/blender/makesrna/intern/rna_wm.cc:550-L593")）：
`REGISTER`、`UNDO`、`UNDO_GROUPED`、`BLOCKING`、`MACRO`、`GRAB_CURSOR`、
`GRAB_CURSOR_X`、`GRAB_CURSOR_Y`、`DEPENDS_ON_CURSOR`、`PRESET`、`INTERNAL`、
`MODAL_PRIORITY`。写一个不在列表里的名字会让 `register_class` 直接失败。

*第二，`poll()` 是 `@classmethod`，`execute()` / `invoke()` 是实例方法。*
在 #src("scripts/modules/_bpy_types.py:1095") 的 `bpy.types.Operator` 里
看不出这一点（那里只有属性转发逻辑），它是 RNA 注册元数据决定的：
`poll` 被标记为 `FUNC_NO_SELF | FUNC_REGISTER_OPTIONAL`
（#src("source/blender/makesrna/intern/rna_wm_api.cc:1362-L1364")），
所以它拿到的是类而不是实例。

*第三，`self.report()` 的第一个参数是集合。* 很多人写成
`self.report("WARNING", ...)`。RNA 侧把它声明成 *enum flag*，参数名就叫 `type`：

```c
// source/blender/makesrna/intern/rna_wm_api.cc:1246（节选）
func = RNA_def_function(srna, "report", "rna_Operator_report");
parm = RNA_def_enum_flag(func, "type", rna_enum_wm_report_items, 0, "Type", "");
```

可用值来自 `rna_enum_wm_report_items`
（#src("source/blender/makesrna/intern/rna_wm.cc:627-L634")）：
`DEBUG`、`INFO`、`OPERATOR`、`WARNING`、`ERROR`。日常用后四个。
注意报告只是*通知*，它不改变操作符的返回值 ——
想让调用方知道失败，必须自己 `return {'CANCELLED'}`。

*第四，`context.selected_objects` 和 `context.scene.objects` 不是一回事。*
前者只含当前视图层里被选中的物体。我们用 `use_selection_only` 开关
把选择交给用户，而不是替他决定。

#note[
  `poll` 不接受操作符属性，所以它无法知道 `use_selection_only` 当前是什么值。
  因此这里按更宽的条件检查“场景中是否存在网格”；如果用户最终选择了
  “只检查选中物体”却没有选中网格，`execute()` 再给出明确提示并返回 `CANCELLED`。
]

=== 7.2.3 操作符（二）：`invoke` 与修改数据的操作符

有了只读操作符做对照，再看两个操作符：一个*修改数据*（选中问题物体），
一个用 `invoke` 打开文件选择器。

```python
# mesh_inspector/operators.py（节选二：选中问题物体）

class MSI_OT_select_flagged(bpy.types.Operator):
    """选中所有存在问题的物体"""

    bl_idname = "mesh_inspector.select_flagged"
    bl_label = "Select Flagged Objects"

    # 这个操作符【修改】了物体的选择状态，属于可撤销的数据变更，
    # 因此必须加 UNDO。
    bl_options = {'REGISTER', 'UNDO'}

    deselect_others: bpy.props.BoolProperty(
        name="Deselect Others",
        description="Deselect everything else before selecting flagged objects",
        default=True,
    )

    @classmethod
    def poll(cls, context):
        result = getattr(context.scene, "msi_result", None)
        return bool(result is not None and result.object_summaries)

    def invoke(self, context, event):
        # invoke 是"由用户交互触发时"的入口。这里用它检查一个前置条件，
        # 再转交 execute。注意：invoke 不会自动调用 execute。
        if context.scene.msi_result.checked_objects == 0:
            self.report({'ERROR'}, "还没有检查结果，请先执行一次检查")
            return {'CANCELLED'}
        return self.execute(context)

    def execute(self, context):
        result = context.scene.msi_result

        if self.deselect_others:
            for obj in context.view_layer.objects:
                obj.select_set(False)

        selected = 0
        first = None
        for summary in result.object_summaries:
            if summary.issue_total == 0:
                continue
            obj = context.scene.objects.get(summary.object_name)
            if obj is None:
                # 物体在检查之后被删除或改名了，跳过而不是报错。
                continue
            obj.select_set(True)
            if first is None:
                first = obj
            selected += 1

        if selected == 0:
            self.report({'INFO'}, "没有需要选中的物体")
            return {'CANCELLED'}

        # 设置活动物体，让"最后选中的那个"在属性编辑器里可见。
        context.view_layer.objects.active = first
        self.report({'INFO'}, f"已选中 {selected} 个有问题的物体")
        return {'FINISHED'}
```

```python
# mesh_inspector/operators.py（节选三：导出报告）

class MSI_OT_export_report(bpy.types.Operator):
    """把检查结果写成一个文本报告"""

    bl_idname = "mesh_inspector.export_report"
    bl_label = "Export Inspection Report"
    bl_options = {'REGISTER'}

    filepath: bpy.props.StringProperty(
        name="Report File", subtype='FILE_PATH',
        description="Where to write the report",
    )
    use_timestamp_dir: bpy.props.BoolProperty(
        name="Use Timestamp Sub-folder", default=False,
        description="Write into a sub-folder named after the current run",
    )

    @classmethod
    def poll(cls, context):
        result = getattr(context.scene, "msi_result", None)
        return bool(result is not None and result.findings)

    def invoke(self, context, event):
        # 官方工具的惯用法：先算出默认文件名，再交给文件选择器。
        # 参见 scripts/addons_core/io_mesh_uv_layout/__init__.py:117。
        if not self.filepath:
            self.filepath = report_mod.default_report_name(context.scene)
        context.window_manager.fileselect_add(self)
        return {'RUNNING_MODAL'}

    def execute(self, context):
        text = report_mod.build_report(context.scene)
        try:
            written = report_mod.write_report(
                self.filepath, text, use_timestamp_dir=self.use_timestamp_dir,
            )
        except OSError as ex:
            self.report({'ERROR'}, f"写入失败：{ex}")
            return {'CANCELLED'}

        self.report({'INFO'}, f"报告已写入 {written}")
        return {'FINISHED'}
```

`invoke` 与 `execute` 的分工是很多人一开始会搞混的：

#figure(
  kind: table,
  table(
    columns: (0.7fr, 1.6fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*回调*], [*何时被调用*], [*典型用途*]),
    [`poll`],
    [任何入口之前，且会反复调用（每次重绘、每次菜单悬停）],
    [判定上下文是否满足；必须廉价且无副作用],
    [`invoke`],
    [由用户交互触发时（点按钮、按快捷键、从菜单选）],
    [弹文件选择器、弹确认对话框、读取 `event` 做手势、参数预填],
    [`execute`],
    [`invoke` 主动转交，或由脚本 / `bpy.ops.xxx()` 直接调用时],
    [真正干活],
  ),
  caption: [`poll` / `invoke` / `execute` 的分工],
) <tbl-handlers>

关键的纪律：*`invoke` 不会自动调用 `execute`*。如果你定义了 `invoke`
却忘了在末尾 `return self.execute(context)`，操作符会返回 `None`，
Blender 会当作失败处理。

`invoke` 里那两行是官方 addon 的标准写法，值得逐字记住：

- `context.window_manager.fileselect_add(self)` 打开文件浏览器，
  把用户选的路径写回 `self.filepath`，然后*再次*调用 `execute`；
- 返回值必须是 `{'RUNNING_MODAL'}`，因为你把控制权交给了文件选择器。

`subtype='FILE_PATH'` 是 `StringProperty` 的合法子类型，
解析表在 #src("source/blender/python/intern/bpy_props.cc:4925-L4927")。

#pitfall[
  `bpy.ops.mesh_inspector.inspect()` 这种脚本调用会*跳过 `invoke`，直接进 `execute`*，
  但*一定会先跑 `poll`*。所以如果逻辑只写在 `invoke` 里，
  从脚本调用就会看到"什么都没发生"。把必要条件放 `poll`，
  把参数校验放 `execute`，才是稳的写法。
]

== 7.3 偏好设置、数据模型与界面

现在写数据层。四个类，各管一件事：`MSI_Thresholds` 是一组阈值，
*被复用两次* —— 一次作为全局默认放进偏好设置，一次作为物体级覆盖挂在每个物体上；
`MSI_Preferences` 是 `AddonPreferences`；`MSI_Finding` / `MSI_ObjectSummary` /
`MSI_Result` 是检查结果的数据模型。

```python
# mesh_inspector/prefs.py

import bpy


class MSI_Thresholds(bpy.types.PropertyGroup):
    """一组检查阈值。既用作全局默认，也用作物体级覆盖。"""

    override: bpy.props.BoolProperty(name="Override Global Thresholds", default=False)

    degenerate_area: bpy.props.FloatProperty(
        name="Degenerate Face Area", default=1e-6,
        description="Faces with an area below this value are reported as degenerate",
        min=0.0, soft_max=1e-3, precision=9,
    )
    max_non_manifold_edges: bpy.props.IntProperty(
        name="Max Non-Manifold Edges", default=0,
        description="Report the object when it has more non-manifold edges than this",
        min=0, soft_max=1000,
    )
    report_loose_edges: bpy.props.BoolProperty(
        name="Report Loose Edges", default=True,
        description="Report edges that are not connected to any face",
    )
    max_scale_deviation: bpy.props.FloatProperty(
        name="Max Scale Deviation", default=0.0001,
        description="Report objects whose non-uniform scale exceeds this ratio",
        min=0.0, soft_max=0.1, precision=6,
    )


class MSI_Preferences(bpy.types.AddonPreferences):
    # bl_idname 必须是 addon 的模块名。用 __package__ 最稳，
    # 因为它在被安装成扩展时会自动变成 bl_ext.<repo>.mesh_inspector。
    # 官方 addon 同样这么做，见 scripts/addons_core/io_scene_gltf2/__init__.py:2207。
    bl_idname = __package__

    # 一个偏好项直接就是一个 PointerProperty 指向属性组。
    # 参见 scripts/addons_core/node_wrangler/preferences.py:105。
    thresholds: bpy.props.PointerProperty(type=MSI_Thresholds)

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        box = layout.box()
        box.label(text="Default Thresholds", icon='PREFERENCES')
        thresholds = self.thresholds
        box.prop(thresholds, "degenerate_area")
        box.prop(thresholds, "max_non_manifold_edges")
        box.prop(thresholds, "report_loose_edges")
        box.prop(thresholds, "max_scale_deviation")
```

```python
# mesh_inspector/properties.py

import bpy


class MSI_Finding(bpy.types.PropertyGroup):
    """一条问题记录。"""

    object_name: bpy.props.StringProperty(name="Object", default="")
    check: bpy.props.StringProperty(name="Check", default="")

    severity: bpy.props.EnumProperty(
        name="Severity", default='WARNING',
        description="How serious this finding is",
        items=(
            ('INFO', "Info", "Informational, not necessarily a problem"),
            ('WARNING', "Warning", "Likely to cause trouble down the line"),
            ('ERROR', "Error", "Almost certainly broken geometry"),
        ),
    )
    count: bpy.props.IntProperty(name="Count", default=0, min=0)
    detail: bpy.props.StringProperty(name="Detail", default="")


class MSI_ObjectSummary(bpy.types.PropertyGroup):
    """单个物体的汇总，供"选中问题物体"和报告使用。"""

    object_name: bpy.props.StringProperty(default="")
    face_count: bpy.props.IntProperty(default=0, min=0)
    vert_count: bpy.props.IntProperty(default=0, min=0)
    issue_total: bpy.props.IntProperty(default=0, min=0)


class MSI_Result(bpy.types.PropertyGroup):
    """一次检查的完整结果，挂在场景上。"""

    findings: bpy.props.CollectionProperty(type=MSI_Finding)
    object_summaries: bpy.props.CollectionProperty(type=MSI_ObjectSummary)

    active_index: bpy.props.IntProperty(default=0, min=0)
    checked_objects: bpy.props.IntProperty(default=0, min=0)

    def add_summary(self, object_name, findings, *, face_count=0, vert_count=0):
        """从一个纯 Python 的 finding 列表建一条汇总。"""
        summary = self.object_summaries.add()
        summary.object_name = object_name
        summary.face_count = face_count
        summary.vert_count = vert_count
        summary.issue_total = sum(f.count for f in findings)
        return summary
```

三个必须理解的细节：

- *`CollectionProperty` 的 `type` 必须是 `PropertyGroup` 子类*，
  而它的元素用 `.add()` 创建、`collection[i]` 索引、`del collection[i]` 删除。
  `MSI_Result.findings` 和 `object_summaries` 都是这样。
- *`active_index` 是给 `template_list` 用的*。它不是我们的业务数据，
  但 `template_list` 需要一对 `(集合, 索引属性)`（见 7.2.6）。
- *`add_summary` 的调用点把面数与顶点数都传进来了*
  （7.2.2 里 `face_count=len(obj.data.polygons)`、
  `vert_count=len(obj.data.vertices)`）。这两个参数都是 `IntProperty`，
  位置又相邻，把面数传给顶点数参数不会有任何报错 ——
  只会让报告里的顶点数一直显示成面数。这类"能跑但语义不对"的问题
  正是 7.4.6 要用单元测试兜住的东西。

=== 7.3.1 `bpy.props` 的参数名：以源码为准

`bpy.props` 的属性工厂最容易凭印象写错参数名。下面这张表是从
`source/blender/python/intern/bpy_props.cc` 里各属性的 `_keywords[]`
数组（也就是真正被接受的参数名）逐条核对出来的。

#figure(
  kind: table,
  table(
    columns: (1.15fr, 1.6fr, 0.8fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*属性类型*], [*关键字参数*], [*`_keywords` 行号*]),
    [`BoolProperty`],
    [`attr`, `name`, `description`, `translation_context`, `default`, `options`, `override`, `tags`, `subtype`, `update`, `get`, `set`, `get_transform`, `set_transform`],
    [3632],
    [`IntProperty`],
    [同上，另有 `min`, `max`, `soft_min`, `soft_max`, `step`, `subtype`],
    [4051],
    [`FloatProperty`],
    [`IntProperty` 的全部，另有 `precision`, `unit`],
    [4486],
    [`StringProperty`],
    [`attr`, `name`, `description`, `translation_context`, `default`, `maxlen`, `options`, `override`, `tags`, `subtype`, `update`, `get`, `set`, `get_transform`, `set_transform`, `search`, `search_options`],
    [4939],
    [`EnumProperty`],
    [`attr`, `items`, `name`, `description`, `translation_context`, `default`, `options`, `override`, `tags`, `update`, `get`, `set`, `get_transform`, `set_transform`],
    [5199],
    [`PointerProperty`],
    [`attr`, `type`, `name`, `description`, `translation_context`, `options`, `override`, `tags`, `poll`, `update`],
    [5462],
    [`CollectionProperty`],
    [`attr`, `type`, `name`, `description`, `translation_context`, `options`, `override`, `tags`],
    [5620],
  ),
  caption: [`bpy.props` 各属性工厂接受的真实参数名（Blender #blender-version）],
) <tbl-props-kwargs>

两个必须记住的结论：

*第一，`attr` 是位置参数，没有例外。* 所有工厂的第一个参数都叫 `attr`，
解析格式串是 `"O&"`（#src("source/blender/python/intern/bpy_props.cc:3634") 起），
必须提供。在类体里写注解时它由 Blender 从类字典的键自动填进来，
所以写 `default=-1.0` 时不写 `attr` 是对的；但*在类体之外*给 `Scene`
加属性时必须自己写全：

```python
bpy.types.Scene.msi_result = bpy.props.PointerProperty(type=MSI_Result)
```

*第二，`type` 只对 `PointerProperty` / `CollectionProperty` 存在，
而且目标类型受严格限制。* #src("source/blender/python/intern/bpy_props.cc:5516-L5522")
有一段明确的检查：目标只能是 *`PropertyGroup` 的子类* 或 *`ID` 类型*
（`Object`、`Mesh`、`Material` 这种）。你不可能写一个指向
`bpy.types.Operator` 或 `bpy.types.UIList` 的指针属性。

同一处的文档字符串还有一个值得注意的限制
（#src("source/blender/python/intern/bpy_props.cc:5424-L5427")）：
指针属性*不支持*指向嵌入型 ID，例如 `Scene.collection`、`Material.node_tree`。
这类数据必须通过它们的宿主 ID 访问。

#tip[
  记不住参数名时，最快的办法是在 Blender 的 Python 控制台里敲
  `help(bpy.props.PointerProperty)`。文档字符串是从上面那些宏直接拼出来的，
  所以它和源码永远同步 —— 这比查任何第三方资料都可靠。
]

*在面板里读取偏好设置*有两个路径，必须分清。
`context.preferences.addons` 的键是 addon 的*模块名*，
而 `__package__` 在 `__init__.py` 里正是模块名、在子模块里
是 `"mesh_inspector"`，两种情况都对：

```python
# 路径一（推荐）：从任意上下文拿到本 addon 的偏好对象。
context.preferences.addons[__package__].preferences

# 路径二：只拿到了子模块的名字时。
context.preferences.addons[__name__.split(".")[0]].preferences
```

#pitfall[
  两个最常见的错误：一是硬编码
  `context.preferences.addons["mesh_inspector"].preferences`，
  改目录名就崩；二是把 `__package__` 和 `__name__` 混用 ——
  在 `ui.py` 里 `__name__` 是 `"mesh_inspector.ui"`，
  拿它去索引 `addons` 一定会 `KeyError`。
]

=== 7.3.2 面板

面板要回答四个问题：*在哪个编辑器*、*在哪个区域*、*在哪个标签页*、*叫什么名字*。

```python
# mesh_inspector/ui.py（节选一：面板）

class MSI_PT_main(bpy.types.Panel):
    """主面板：运行检查并浏览结果"""

    bl_label = "Mesh Inspector"
    bl_idname = "MSI_PT_main"

    # 这四项就是"位置四件套"。
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Mesh Inspector"

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT'

    def draw(self, context):
        layout = self.layout
        result = context.scene.msi_result

        col = layout.column(align=True)
        op = col.operator(operators.MSI_OT_inspect.bl_idname,
                          text="Inspect", icon='CHECKMARK')
        op.use_selection_only = True
        op.clear_previous = True

        row = col.row(align=True)
        row.operator(operators.MSI_OT_select_flagged.bl_idname,
                     text="Select Flagged", icon='RESTRICT_SELECT_OFF')

        export = row.operator(operators.MSI_OT_export_report.bl_idname,
                              text="Export Report", icon='FILE_TICK')
        export.use_timestamp_dir = False

        col.separator()

        if result.checked_objects == 0:
            col.label(text="还没有检查结果。", icon='INFO')
            return

        col.label(
            text=f"已检查 {result.checked_objects} 个物体，"
                 f"{len(result.findings)} 类问题",
            icon='MESH_DATA',
        )

        # template_list 需要一对 (集合属性, 索引属性)。
        col.template_list(
            "MSI_UL_findings", "",
            result, "findings",
            result, "active_index",
            rows=5,
        )


class MSI_PT_settings(bpy.types.Panel):
    """物体级阈值覆盖面板"""

    bl_label = "Per-Object Thresholds"
    bl_idname = "MSI_PT_settings"
    bl_space_type = 'PROPERTIES'
    bl_region_type = 'WINDOW'
    bl_context = "object"
    bl_options = {'DEFAULT_CLOSED'}

    @classmethod
    def poll(cls, context):
        obj = context.object
        return bool(obj is not None and obj.type == 'MESH')

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        thresholds = context.object.msi_thresholds
        layout.prop(thresholds, "override")
        col = layout.column()
        col.enabled = thresholds.override
        col.prop(thresholds, "degenerate_area")
        col.prop(thresholds, "max_non_manifold_edges")
        col.prop(thresholds, "report_loose_edges")
        col.prop(thresholds, "max_scale_deviation")
```

`bl_space_type` 与 `bl_region_type` 的合法值由 RNA 枚举给出，
分别定义在 `rna_enum_space_type_items`
（#src("source/blender/makesrna/intern/rna_space.cc:90")）和
`rna_enum_region_type_items`
（#src("source/blender/makesrna/intern/rna_screen.cc:28")）。
3D 视口右侧栏的标准组合就是 `bl_space_type = 'VIEW_3D'` 加
`bl_region_type = 'UI'`；后者的 UI 名称正是 "Sidebar"。

`bl_category` 是*字符串*，不是枚举。它决定 N 面板上那一列按钮的文字。
多个 addon 用同一个 `bl_category` 时会共用一个标签页，这是特性不是 bug。

`bl_options` 对面板来说只有四个合法值
（#src("source/blender/makesrna/intern/rna_ui.cc:1819-L1843")）：
`DEFAULT_CLOSED`、`HIDE_HEADER`、`INSTANCED`、`HEADER_LAYOUT_EXPAND`。
注意 `DEFAULT_CLOSED` 是*默认折叠*，不是"默认隐藏"。

#warn[
  给面板设 `bl_parent_id` 时，*父子面板必须同空间同区域*。
  如果父面板在 `VIEW_3D` / `UI` 而子面板在 `PROPERTIES` / `WINDOW`，
  Blender 不会报错，子面板会静默地当作独立面板显示。
]

=== 7.3.3 `inspect.py`：真正的检查逻辑

这是唯一不依赖 `bpy` 的模块：接收一个 `Object` 和一组阈值，
返回普通的具名元组列表。

```python
# mesh_inspector/inspect.py

import math
from collections import namedtuple

import bmesh
import numpy as np

# 纯 Python 的数据载体，不是 bpy.types.PropertyGroup。
# 这样这个模块可以脱离 Blender 单独测试。
Finding = namedtuple("Finding", "check severity count detail")

# 检查项的稳定标识符。写成常量而不是散落的字面量，
# 因为报告和界面都要引用它们。
CHECK_DEGENERATE = "degenerate_faces"
CHECK_NON_MANIFOLD = "non_manifold_edges"
CHECK_LOOSE_EDGES = "loose_edges"
CHECK_MESH_VALIDATE = "mesh_validate"
CHECK_SCALE = "scale_deviation"


def positions_minmax(mesh):
    """用属性 API + numpy 求顶点坐标的包围盒。"""
    attr = mesh.attributes.get("position")
    if attr is None:
        return None
    count = len(attr.data)
    if count == 0:
        return None
    flat = np.empty(count * 3, dtype=np.float32)
    attr.data.foreach_get("vector", flat)
    xyz = flat.reshape(count, 3)
    return tuple(xyz.min(axis=0)), tuple(xyz.max(axis=0))


def degenerate_face_count(mesh, area_limit):
    """统计面积小于阈值的面数，返回 (数量, 总面积)。"""
    face_count = len(mesh.polygons)
    if face_count == 0:
        return 0, 0.0
    areas = np.empty(face_count, dtype=np.float32)
    mesh.polygons.foreach_get("area", areas)
    bad = areas < area_limit
    return int(np.count_nonzero(bad)), float(areas[bad].sum())


def topology_counts(mesh):
    """用 bmesh 统计非流形边与孤立边。"""
    bm = bmesh.new()
    try:
        bm.from_mesh(mesh)
        non_manifold = 0
        loose = 0
        for edge in bm.edges:
            if edge.is_wire:
                loose += 1
            elif not edge.is_manifold:
                non_manifold += 1
        return non_manifold, loose
    finally:
        # bmesh 实例必须显式释放，否则会泄漏内存。
        bm.free()


def scale_deviation(vector):
    """返回最大轴与最小轴的比值偏差。等比缩放时为 0。"""
    axes = [abs(v) for v in vector]
    largest = max(axes)
    if largest <= 0.0:
        return math.inf
    return (largest - min(axes)) / largest


def inspect_mesh(obj, limits):
    """对一个网格物体做完整检查，返回 Finding 列表。"""
    import bpy

    mesh = obj.data
    findings = []

    # 1) 退化面
    count, total_area = degenerate_face_count(mesh, limits.degenerate_area)
    if count:
        findings.append(Finding(
            CHECK_DEGENERATE, 'ERROR', count,
            f"{count} faces below area {limits.degenerate_area:g} "
            f"(total {total_area:.6g})",
        ))

    # 2) 拓扑问题
    non_manifold, loose = topology_counts(mesh)
    if non_manifold > limits.max_non_manifold_edges:
        findings.append(Finding(
            CHECK_NON_MANIFOLD, 'WARNING', non_manifold,
            f"{non_manifold} non-manifold edges "
            f"(limit {limits.max_non_manifold_edges})",
        ))
    if loose and limits.report_loose_edges:
        findings.append(Finding(
            CHECK_LOOSE_EDGES, 'WARNING', loose,
            f"{loose} loose edges not attached to any face",
        ))

    # 3) Blender 自己的网格校验。
    # validate() 会就地修改网格，所以必须在一份临时副本上做。
    probe = mesh.copy()
    try:
        if probe.validate(verbose=False):
            findings.append(Finding(
                CHECK_MESH_VALIDATE, 'ERROR', 1,
                "Blender reported invalid geometry in a copy of this mesh",
            ))
    finally:
        bpy.data.meshes.remove(probe)

    # 4) 未应用的缩放
    deviation = scale_deviation(obj.scale)
    if deviation > limits.max_scale_deviation:
        findings.append(Finding(
            CHECK_SCALE, 'INFO', 1,
            f"non-uniform object scale {tuple(round(v, 6) for v in obj.scale)}",
        ))

    return findings
```

#pitfall[
  `mesh.validate()` *不是只读的*。RNA 的文档字符串写得很明确：
  "Validate geometry, return True when the mesh has had invalid geometry
  corrected/removed"（#src("source/blender/makesrna/intern/rna_mesh_api.cc:394-L396")）。
  它会就地修改网格。想在"检查"阶段用它，就必须像上面那样先在
  `mesh.copy()` 出来的一份上做。直接对用户数据调用 `validate()`
  是一次你没告诉用户的破坏性操作。
]

#tip[
  用 `bmesh.new()` / `bm.free()` 而不是 `bmesh.from_edit_mesh()`：
  前者的 `from_mesh()` 对物体模式下的网格是安全的只读访问，
  后者只能在编辑模式下用，而且会绑定到编辑网格的生命周期上。
  官方 addon 处理大量网格时普遍走 `from_mesh()` 这条路。
]

`positions_minmax()` 用到的参数*名字*需要核实：`mesh.attributes` 是
`AttributeGroupMesh`（#src("source/blender/makesrna/intern/rna_attribute.cc:2268-L2282")），
其中 `"position"` 是点域上的 `FLOAT_VECTOR` 属性
（#src("source/blender/blenkernel/intern/mesh.cc:620")），
每个元素通过 `vector` 属性暴露三个浮点数
（#src("source/blender/makesrna/intern/rna_attribute.cc:1502-L1505")）。
所以 `foreach_get("vector", flat)` 里的 `"vector"` 不能写成
`"value"` 或 `"position"`。

非流形边用 `bmesh` 判定，`BMEdge.is_manifold` 与 `BMEdge.is_wire`
都是只读 getter，定义在
#src("source/blender/python/bmesh/bmesh_py_types.cc:1034-L1058")。
注意 `MeshEdge`（`mesh.edges[i]`）*没有* `is_manifold`，
只有 `is_loose`（#src("source/blender/makesrna/intern/rna_mesh.cc:2131-L2134")）——
这是必须用 `bmesh` 而不能只用 `Mesh` API 的原因。

=== 7.3.4 `report.py`：写盘与目录规则

报告模块要注意的是*不要假设目录存在*。用户给的路径可能差好几层。

```python
# mesh_inspector/report.py

import datetime
import os


def default_report_name(scene):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"mesh-inspection-{stamp}.txt"


def build_report(scene):
    result = scene.msi_result
    lines = [
        "Mesh Inspector Report",
        "=" * 60,
        f"Scene     : {scene.name}",
        f"Generated : {datetime.datetime.now().isoformat(timespec='seconds')}",
        f"Objects   : {result.checked_objects}",
        "",
    ]

    if not result.findings:
        return "\n".join(lines + ["No problems found."]) + "\n"

    lines += ["-" * 60, "Summary", "-" * 60]
    for summary in sorted(result.object_summaries, key=lambda s: -s.issue_total):
        lines.append(
            f"{summary.object_name:<32} faces={summary.face_count:<8} "
            f"verts={summary.vert_count:<8} issues={summary.issue_total}"
        )

    lines += ["", "-" * 60, "Details", "-" * 60]
    for name in dict.fromkeys(f.object_name for f in result.findings):
        lines.append(f"[{name}]")
        for finding in result.findings:
            if finding.object_name == name:
                lines.append(
                    f"  {finding.severity:<7} {finding.check:<20} "
                    f"count={finding.count:<6} {finding.detail}"
                )
        lines.append("")

    return "\n".join(lines) + "\n"


def write_report(filepath, text, *, use_timestamp_dir=False):
    """写入报告，返回实际写出的绝对路径。

    目录不存在时会逐层创建，这是用户最容易忽略的一步。
    """
    filepath = os.path.abspath(filepath)
    directory = os.path.dirname(filepath)

    if use_timestamp_dir:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        directory = os.path.join(directory, stamp)
        filepath = os.path.join(directory, os.path.basename(filepath))

    # exist_ok=True 让"目录已存在"不再是错误。
    os.makedirs(directory, exist_ok=True)
    with open(filepath, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return filepath
```

#tip[
  写文本文件时显式指定 `encoding="utf-8"` 和 `newline="\n"`。
  前者避免中文报告在 Windows 上按系统代码页写坏；
  后者让三平台产出的报告可以被同一套 diff 工具比较。
]

=== 7.3.5 UIList

`UIList` 的 `draw_item` 签名必须与 RNA 声明完全一致，
否则 `register_class` 会失败。签名在
#src("source/blender/makesrna/intern/rna_ui.cc:2095-L2131") 里逐个参数列出。

```python
# mesh_inspector/ui.py（节选二：UIList）

class MSI_UL_findings(bpy.types.UIList):
    """检查结果列表。"""

    # 严重程度到图标的映射，放在类属性上，draw_item 里查表。
    _ICONS = {'INFO': 'INFO', 'WARNING': 'ERROR', 'ERROR': 'CANCEL'}

    def draw_item(self, context, layout, data, item, icon,
                  active_data, active_propname, index=0):
        # 官方模板里强调：每个 item 的第一行必须是一个 label 或
        # 非浮雕的 prop，否则这一行在列表里点不中。
        # 见 scripts/templates_py/UI/list_simple.py:21。
        row = layout.row(align=True)
        row.label(text=item.object_name, translate=False)
        row.label(text=item.check, translate=False)
        row.label(text=str(item.count))
        row.label(text="", icon=self._ICONS.get(item.severity, 'INFO'))
```

#note[
  `index` 和 `flt_flag` 是可选的。RNA 声明里 `index` 被标为
  `PARM_PYFUNC_REGISTER_OPTIONAL`（#src("source/blender/makesrna/intern/rna_ui.cc:2126-L2128")），
  所以不声明也能注册成功。一旦声明，就必须有默认值 ——
  上面写了 `index=0`。漏掉默认值会在注册时报参数数量错误。
]

=== 7.3.6 此时你应该看到什么

在继续之前先验证一遍。把 `mesh_inspector/` 放到用户级 addon 目录
（位置见 7.3.2），重启 Blender，然后：

1. 偏好设置 → Add-ons，搜索 "Mesh Inspector"，勾选启用。
   *应该看到*：列表项展开后有一个 "Default Thresholds" 折叠框，
   里面四项阈值，和 `prefs.py` 里 `draw()` 写的一致。
2. 切到 3D 视口，按 `N` 打开侧栏。*应该看到*：一个名为
   "Mesh Inspector" 的标签页，里面是 "Inspect"、"Select Flagged"、
   "Export Report" 三个按钮。
3. 建一个立方体，进编辑模式删掉一个面，回到物体模式，点 "Inspect"。
   *应该看到*：信息编辑器里出现一条黄色警告
   "检查完成：1 个物体，发现 N 处问题"，侧栏出现结果列表。
4. 按 `Ctrl+Z`。*应该看到*：什么都不发生 —— 因为检查操作符没有加 `UNDO`。
   这是正确的。接着点 "Select Flagged"，再按 `Ctrl+Z`，
   *应该看到*：之前的选择状态被恢复了，因为那个操作符加了 `UNDO`。
5. 点 "Export Report"，选一个不存在的子目录下的路径，
   例如 `D:\reports\2024\mesh.txt`。*应该看到*：目录被自动创建，
   报告写入成功，信息编辑器显示完整路径。

如果第 4 步里撤销真的撤销掉了什么，说明你把 `UNDO` 加错地方了。

== 7.4 打包、安装、发布

=== 7.4.1 目录要求与打 zip

传统 addon 的安装单元是*一个目录或一个 `.py` 文件*。目录形式要求：

- 目录名就是模块名，必须与 `bl_info["name"]` 分开对待 ——
  用户看到的是 `name`，Python 导入用的是*目录名*；
- 目录里必须有 `__init__.py`。这一点在
  #src("scripts/modules/addon_utils.py:462") 的注释里被特别指出：
  *"An extension is a directory that doesn't contain an `__init__.py` file"* ——
  没有 `__init__.py` 的目录会被当作*扩展*而不是传统 addon；
- 目录里不要有 `__pycache__`、`.git`、测试数据。

打包就是把目录压成 zip，并且 *zip 内必须保留顶层目录*：

```bash
# 正确：压缩包里有 mesh_inspector/__init__.py
$ zip -r mesh_inspector-1.0.0.zip mesh_inspector/

# 错误：压缩包里直接是 __init__.py，安装后会缺少一层
$ cd mesh_inspector && zip -r ../mesh_inspector-1.0.0.zip .
```

在 Windows 上用 PowerShell：

```bash
$ Compress-Archive -Path mesh_inspector -DestinationPath mesh_inspector-1.0.0.zip
```

#pitfall[
  zip 结构错了不会立刻报错。Blender 会安装成功，但 addon 列表中
  出现的名字会是 `__init__` 或者什么都不出现。判断标准很简单：
  用任意压缩工具打开 zip，*第一层必须只有一个目录*，
  点进去才是 `__init__.py`。
]

=== 7.4.2 addon 目录在哪里

这是最常被问、也最容易答错的问题。答案完全由
#src("scripts/modules/addon_utils.py:84-L96") 的 `paths()` 决定。
三条结论：

*第一条：第一个脚本目录下找 `addons_core`，其余目录下找 `addons`。*
也就是 *随 Blender 分发的官方 addon 目录叫 `addons_core`*，
不是网络资料里常见的 `scripts/addons`。这一点在本章的基准版本里
可以在磁盘上直接看到：`scripts/addons_core/io_mesh_uv_layout/`、
`scripts/addons_core/rigify/` 等等。

*第二条：`script_paths()` 是*列表*，不是"用户 + 系统"两条。*
它的实现在 #src("scripts/modules/bpy/utils/__init__.py:432-L492")，
按顺序拼装：`LOCAL` 资源路径下的 `scripts`（仅 `check_all=True` 时）、
用户脚本目录、系统脚本目录、`bpy.utils` 自己所在的那个 `scripts` 目录
（#src("scripts/modules/bpy/utils/__init__.py:85")）、
用户偏好里自定义的脚本路径、以及环境变量给出的路径。最终会去重。
底层 `bpy.utils.script_paths()` 返回的两元素元组（系统、用户）
定义在 #src("source/blender/python/intern/bpy.cc:79-L94")。

*第三条：这些路径由 `BKE_appdir` 计算，而且可以用环境变量覆盖。*
目录名拼接逻辑在 #src("source/blender/blenkernel/intern/appdir.cc:649-L760")，
每个 `case` 分支处理一种资源类型。以用户脚本目录为例
（#src("source/blender/blenkernel/intern/appdir.cc:703-L710")）：
先看 `BLENDER_USER_SCRIPTS` 环境变量，
未设置则在用户根目录下拼出 `scripts` 子目录。

用户根目录来自 GHOST，三平台各不相同：*Windows* 用
`FOLDERID_RoamingAppData`（#src("intern/ghost/intern/GHOST_SystemPathsWin32.cc:44-L57")）；
*Linux* 优先 `$XDG_CONFIG_HOME/blender/<版本>`，
否则 `$HOME/.config/blender/<版本>`
（#src("intern/ghost/intern/GHOST_SystemPathsUnix.cc:76-L109")）；
*macOS* 用 `NSSearchPathForDirectoriesInDomains` 查 `NSApplicationSupportDirectory`，
拼成 `<Application Support>/Blender/<版本>`
（#src("intern/ghost/intern/GHOST_SystemPathsCocoa.mm:18-L38")）。

其中 `<版本>` 是*主版本.次版本*，由
#src("source/blender/blenkernel/intern/appdir.cc:125-L131") 的
`blender_version_decimal()` 生成（`"%d.%d"`，所以 5.2 得到 `"5.2"`，
*不含*补丁号）。小版本升级不会换目录，大版本升级会。

#figure(
  kind: table,
  table(
    columns: (0.8fr, 1.9fr, 1.4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*平台*], [*用户级 addon 目录*], [*系统级（只读）*]),
    [Windows],
    [`%APPDATA%\Blender Foundation\Blender\5.2\scripts\addons\`],
    [安装目录下的 `5.2\scripts\addons\`],
    [Linux],
    [`$XDG_CONFIG_HOME/blender/5.2/scripts/addons/`，默认即 `~/.config/blender/5.2/scripts/addons/`],
    [`/usr/share/blender/5.2/scripts/addons/`],
    [macOS],
    [`~/Library/Application Support/Blender/5.2/scripts/addons/`],
    [`/Library/Application Support/Blender/5.2/scripts/addons/`，
      回退到 `Blender.app/Contents/Resources/5.2/scripts/addons/`],
  ),
  caption: [三平台的 addon 目录。版本号是 `主版本.次版本`，不含补丁号。],
) <tbl-addon-dirs>

#note[
  macOS 那一格有两处与直觉不符，值得单独说明。
  *第一，系统级路径不在 `Blender.app` 里，而是与用户级同源。*
  macOS 版的 `getSystemDir()` 用的也是 `NSApplicationSupportDirectory`，
  只是把搜索域从用户域换成了本机域
  （`NSLocalDomainMask`，见 #src("intern/ghost/intern/GHOST_SystemPathsCocoa.mm:40-L44")；
  用户级用 `NSUserDomainMask`，见 #src("intern/ghost/intern/GHOST_SystemPathsCocoa.mm:46-L50")）。
  于是两者只差一个前缀：`/Library/…` 对 `~/Library/…`。
  Windows 与 Linux 则不同 —— 它们的系统级路径落在*安装目录*附近
  （`get_path_system()` 与回退的 `get_path_local()`，
  见 #src("source/blender/blenkernel/intern/appdir.cc:712-L719")）。

  *第二，macOS 是唯一需要回退的平台。*
  `get_path_local_ex()` 里有一段 macOS 专属的路径改写：
  把基目录拼成 `<程序目录>/../Resources` 再规范化
  （#src("source/blender/blenkernel/intern/appdir.cc:387-L396")），
  注释写明了原因 —— 由于 OS X 10.9.5 之后的代码签名限制，
  版本目录必须挪进 `Resources`。
  所以 `BLENDER_SYSTEM_SCRIPTS` 在 macOS 上会先试
  `/Library/Application Support/Blender/5.2/scripts`，
  再回退到 `Blender.app/Contents/Resources/5.2/scripts`
  （#src("source/blender/blenkernel/intern/appdir.cc:712-L719")）。
  这也是为什么这一格不能只写一个路径。
]

最省事的做法不是背这张表，而是在 Blender 的 Python 控制台里直接问：

```python
import addon_utils
addon_utils.paths()
# ['C:\\Program Files\\Blender Foundation\\Blender 5.2\\5.2\\scripts\\addons_core',
#  'C:\\Users\\<你>\\AppData\\Roaming\\Blender Foundation\\Blender\\5.2\\scripts\\addons']
```

列表里的第二项及之后就是你可以写的地方。

#tip[
  开发时不要真的往用户目录里拷。用*符号链接*（Windows 上用
  `mklink /D`，需要管理员权限或开发者模式）把源码目录链进
  `scripts/addons/`，改完代码只需在 Blender 里 "Reload Scripts"。
  这是 7.4.1 的讨论能派上用场的前提。
]

环境变量可以整体改写用户根目录：`BLENDER_USER_RESOURCES`
替换整个用户资源根目录（于是 `scripts/`、`config/`、`extensions/`
都跟着搬走，见 #src("source/blender/blenkernel/intern/appdir.cc:506")）；
`BLENDER_USER_SCRIPTS` 只替换用户脚本目录
（#src("source/blender/blenkernel/intern/appdir.cc:704")）。
这两个变量在自动化测试里非常有用：起一个干净的 Blender 实例跑测试，
不污染开发者自己的配置。

=== 7.4.3 扩展（extensions）与传统 addon 的差别

从 Blender 4.2 起，官方主推的发布形态是 #term("扩展", "extension")。
它和传统 addon 不是同一种东西，混用容易出错：

#figure(
  kind: table,
  table(
    columns: (0.9fr, 1.5fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*维度*], [*传统 addon*], [*扩展 extension*]),
    [元数据],
    [模块里的 `bl_info` 字典],
    [同目录的 `blender_manifest.toml`],
    [`__init__.py`],
    [*必须有*],
    [*不能有*，见 #src("scripts/modules/addon_utils.py:462")],
    [模块名],
    [目录名，例如 `mesh_inspector`],
    [`bl_ext.<repo>.<id>`，由仓库与清单里的 `id` 拼出，
      见 #src("scripts/modules/addon_utils.py:111-L123")],
    [安装位置],
    [`scripts/addons/` 或 `scripts/addons_core/`],
    [`bpy.utils.user_resource('EXTENSIONS')` 给出的 `extensions/`],
    [打包],
    [自己压 zip，第一层是 addon 目录],
    [`blender --command extension build` 产出 zip],
    [第三方 wheel],
    [用户手动装，容易冲突],
    [`wheels` 字段声明，Blender 负责安装与隔离，
      见 #src("scripts/modules/addon_utils.py:1186-L1195")],
  ),
  caption: [传统 addon 与扩展的对照],
) <tbl-addon-vs-ext>

一个必须记住的事实：*扩展的 `bl_info` 是从清单生成的*，不是你自己写的。
#src("scripts/modules/addon_utils.py:1281-L1358") 的
`_bl_info_from_extension()` 会读取 `blender_manifest.toml`
并"造"出一个 `bl_info` 给 Blender 内部使用。所以如果你给一个扩展
写了 `bl_info`，它会被忽略。

#pitfall[
  扩展目录里放了 `__init__.py` 之后，症状非常具有误导性：
  Blender 会把它当传统 addon 加载，你对 `blender_manifest.toml`
  的任何修改都看不出效果 —— 因为那条路径根本没被读。
  排查时第一步就是确认目录里有没有 `__init__.py`。
]

=== 7.4.4 `blender_manifest.toml` 的真实字段

字段清单以 #src("scripts/addons_core/bl_pkg/cli/blender_ext.py:1965-L1992")
的 `pkg_manifest_known_keys_and_types` 为准，那里同时区分了必填与可选。
必填九项：`id`、`schema_version`、`name`、`tagline`、`version`、`type`、
`maintainer`、`license`、`blender_version_min`。
可选八项：`blender_version_max`、`website`、`copyright`、`permissions`、
`tags`、`platforms`、`wheels`（另有仓库侧生成的三个 `archive_*` 字段，
见 #src("scripts/addons_core/bl_pkg/cli/blender_ext.py:1994-L2002")）。

官方模板在 #src("scripts/templates_toml/blender_manifest.toml")，
可以直接复制改。要点：

- `version` 在清单里是*字符串* `"1.0.0"`（语义化版本），
  不像 `bl_info` 里是元组。转换由
  #src("scripts/modules/addon_utils.py:1311-L1325") 负责。
- `blender_version_min` 也是字符串 `"4.2.0"`，读取时按 `.`
  切分成整数元组后赋给 `bl_info["blender"]`
  （#src("scripts/modules/addon_utils.py:1327-L1338")）。
- `type` 只支持 `"add-on"` 和 `"theme"`
  （#src("scripts/templates_toml/blender_manifest.toml:10-L11")）。
- `license` 是*列表*，且要求 SPDX 前缀，模板里写的是
  `"SPDX:GPL-3.0-or-later"`。
- `id` 有命名约束，由 `pkg_manifest_validate_field_idname` 校验。
- `permissions` 用于声明能力需求（文件、网络、剪贴板、摄像头、麦克风），
  模板里给出示例（#src("scripts/templates_toml/blender_manifest.toml:61-L64")）。
  只声明你真的需要的。

一份可以直接用的清单：

```toml
schema_version = "1.0.0"

id = "mesh_inspector"
version = "1.0.0"
name = "Mesh Inspector"
tagline = "Inspect mesh geometry for degenerate faces and non-manifold edges"
maintainer = "Blender 开发指南编写组"
type = "add-on"

blender_version_min = "5.2.0"

license = [
  "SPDX:GPL-3.0-or-later",
]

tags = ["Mesh", "Modeling"]

[permissions]
files = "Write inspection reports to disk"
```

注意 `mesh_inspector` 这个 id 与目录名一致，但不是硬性要求；
真正被用作模块名的是 `bl_ext.<repo>.<id>`。

扩展的构建不是自己压 zip，而是走 Blender 命令行。入口在
#src("scripts/addons_core/bl_pkg/__init__.py:979")：
`bpy.utils.register_cli_command("extension", cli_extension)`。所以命令是：

```bash
$ blender --command extension build --source-dir . --output-dir ./dist
$ blender --command extension validate .
```

`build` 的参数定义在
#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:5394-L5425")，
可用的是 `--source-dir`、`--output-dir`、`--output-filepath`、
`--split-platforms`（另有内部用的 `--valid-tags`、`--verbose`）。
默认输出文件名是 `<id>-<version>.zip`，见
#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:3455-L3466")。
`validate` 接受一个位置参数 `source_path`
（#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:5428-L5450")）。

#tip[
  即使你暂时不想发布到 extensions.blender.org，也建议用
  `--command extension validate` 跑一遍。它会把清单字段的类型、
  命名约束、版本格式全部检查一遍，比在 Blender 界面里看到
  "安装失败"再去猜要快得多。
]

=== 7.4.5 版本兼容声明的两种写法

两套体系各有一套声明方式，别混：

#figure(
  kind: table,
  table(
    columns: (0.9fr, 1.3fr, 1.7fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*体系*], [*最低版本*], [*最高版本*]),
    [传统 addon（`bl_info`）],
    [`"blender": (5, 2, 0)`],
    [没有对应字段，不兼容只能靠 `warning` 文字提示],
    [扩展（清单）],
    [`blender_version_min = "5.2.0"`],
    [`blender_version_max = "5.1.0"`（可选）],
  ),
  caption: [版本兼容声明的字段对照],
) <tbl-version-fields>

关于 `blender_version_max`，模板注释里有一句值得照抄的实践建议：
它"可以省略，等发现问题时再在扩展平台上定义"
（#src("scripts/templates_toml/blender_manifest.toml:21-L23")）。
也就是官方推荐*声明下限、靠实测发现问题再补上限*，
而不是一开始就悲观地封顶。

传统 addon 的 `warning` 字段是纯文本，会显示在 addon 列表项上。
版本不匹配时 Blender 不会阻止加载，只显示这一行字。
所以它是"给人看的"，不是"给机器看的"。

=== 7.4.6 发布检查清单

1. `bl_info` 的 `version` 已递增，`blender` 下限与实测一致；
2. `unregister()` 干净：禁用后 `bpy.types.Scene` 上没有 `msi_result` 残留；
3. 至少 Windows 与 Linux 各跑过一遍，特别注意路径分隔符与文本编码；
4. zip 结构正确：打开压缩包第一层只有一个目录；
5. 走扩展的话，`blender --command extension validate .` 零错误；
6. 报告里不包含用户机器的绝对路径（除非用户自己指定）；
7. 有 README 说明*插件在哪个标签页*、*怎么触发*、*阈值怎么调*。

第 7 条经常被跳过，但它决定了用户是"五分钟上手"还是"发邮件问你"。

== 7.5 常见问题与调试技巧

=== 7.5.1 改了代码不生效：模块缓存与重载

这是多文件 addon 开发中最高频的问题。症状是：改了 `ui.py`，
禁用再启用 addon，界面还是旧的。

原因在 Python 的模块缓存：`sys.modules` 里的模块对象在你
"禁用 addon"时*不会*被清除。Blender 的 addon 禁用只调用你的
`unregister()`，不碰 `sys.modules`。于是下次启用时，
`from . import ui` 命中缓存，返回的是旧模块对象。

官方 addon 用"执行本模块时 `bpy` 是否已在局部命名空间里"来判断
这次是不是重载（#src("scripts/addons_core/io_scene_gltf2/__init__.py:47-L48")）：

```python
# scripts/addons_core/io_scene_gltf2/__init__.py:47（节选）
if "bpy" in locals():
    reload_package(locals())
```

更彻底的版本会递归遍历包目录、逐个 `importlib.reload`
（#src("scripts/addons_core/io_scene_gltf2/__init__.py:30-L44")）。
`rigify` 走另一条路：先从 `sys.modules` 里按前缀找出所有子模块，
*删掉*不在白名单里的，再按固定顺序 reload
（#src("scripts/addons_core/rigify/__init__.py:66-L79")）：

```python
# scripts/addons_core/rigify/__init__.py:66（节选）
def get_loaded_modules():
    prefix = __name__ + '.'
    return [name for name in sys.modules if name.startswith(prefix)]


def reload_modules():
    fixed_modules = set(reload_list)

    for name in get_loaded_modules():
        if name not in fixed_modules:
            del sys.modules[name]

    for name in reload_list:
        importlib.reload(sys.modules[name])
```

注意这里出现了 `del sys.modules[name]` —— *这才是真正让代码生效的操作*。
单纯 `importlib.reload()` 只重新执行当前模块，
如果它 import 的子模块没被 reload，你看到的仍然是旧的。

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.1fr, 0.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*做法*], [*生效范围*], [*风险*]),
    [不管，直接重启 Blender],
    [100% 干净],
    [几十秒一次，频繁改代码时无法忍受],
    [只 `import` 子模块，不改重载逻辑],
    [本次会话生效],
    [改动 `bpy.props` 定义仍然不生效（见 7.4.3）],
    [递归 `importlib.reload` 整个包],
    [本次会话生效，覆盖最全],
    [需要显式列出重载顺序，顺序错了会在 reload 期间报错],
    [`del sys.modules[...]` + 重新 import],
    [最接近重启],
    [若模块对象被别处持有引用，那些引用会指向"孤儿"模块，界面里用的仍是旧类],
  ),
  caption: [代码生效的四种做法及其取舍],
) <tbl-reload>

实践建议：*开发期用递归 reload 加一个 "Reload Scripts" 热键，
但要为它设一条纪律 —— 每次改完先重载，重载后行为异常就重启再试。*
不要在 reload 状态下排查"诡异 bug"，那是在和一个半旧半新的
解释器状态搏斗。

=== 7.5.2 `unregister` 漏删：三种残留

卸载不干净的后果通常不是当场崩，而是*延迟崩*：禁用再启用后
第一次点面板才崩，或者退出 Blender 时才崩。三种典型残留：

*残留一：`bpy.types` 上的自定义属性没删。* 这类属性不在 `_classes` 里，
`for cls in reversed(_classes)` 覆盖不到，必须手写：

```python
def unregister():
    # 这两行不能忘。漏掉的话，禁用 addon 后
    # bpy.types.Scene.msi_result 仍然存在，但它的类型 MSI_Result
    # 已经被注销 —— 访问时得到一个指向已释放 RNA 的悬空引用。
    del bpy.types.Object.msi_thresholds
    del bpy.types.Scene.msi_result
    ...
```

*残留二：往菜单 / 头文件里 append 的绘制函数没 remove。*
官方 UV 导出工具演示了正确做法
（#src("scripts/addons_core/io_mesh_uv_layout/__init__.py:291-L298")）：

```python
def register():
    bpy.utils.register_class(ExportUVLayout)
    bpy.types.IMAGE_MT_uvs.append(menu_func)


def unregister():
    bpy.utils.unregister_class(ExportUVLayout)
    bpy.types.IMAGE_MT_uvs.remove(menu_func)
```

*残留三：关键映射（keymap）没删。* 这是我们本章刻意没做的
（见 7.1.2），但如果你加了，必须成对维护。官方 node_wrangler
把 `(km, kmi)` 元组存进一个模块级列表，卸载时逐个移除再 `clear()`，
见 #src("scripts/addons_core/node_wrangler/preferences.py:390-L408")。

#pitfall[
  判断"卸载是否干净"有一个可执行的检查清单。禁用 addon 之后，
  在 Python 控制台里跑：

  ```python
  import bpy
  assert not hasattr(bpy.types.Scene, "msi_result")
  assert not hasattr(bpy.types.Object, "msi_thresholds")
  print(bpy.types.Operator.bl_rna_get_subclass_py("MSI_OT_inspect"))
  # 期望输出 None
  ```

  第三行返回非 `None` 就说明操作符还活着。把这三行写进
  你的开发笔记，比事后追崩溃快十倍。
]

=== 7.5.3 `bpy.props` 属性定义不可修改

这是一条硬性限制，也是最让人困惑的一条：*通过 `bpy.props` 定义的属性，
其元数据（`name`、`description`、`default`、`min` / `max`、`items` 等）
在注册之后不可修改，而且重新注册同一套定义也不会得到新值。*

真正的报错来自注册路径。`bpy.utils.register_class` 会检查类字典里
是否已经有 `bl_rna`（#src("source/blender/python/intern/bpy_rna.cc:10383-L10390")）：
如果同一个类被注册两次，会直接抛
`ValueError: ... already registered as a subclass`。

而"改完属性定义再注册"的问题在于：`unregister_class` 会清掉
`bl_rna`，但属性定义本身已经写进底层的 RNA 结构并做过缓存。表现是：

- 只改 `default`：多数情况下不生效，属性还是旧默认值；
- 改 `min` / `max` / `soft_max`：界面上的滑块范围不变；
- 改 `items`（枚举项）：可能出现枚举值与界面不一致的诡异状态；
- 把 `BoolProperty` 改成 `IntProperty`：注册时报类型冲突。

*结论：任何涉及属性定义的改动，都必须重启 Blender。*
这不是懒惰的妥协，是当前架构的边界。

#tip[
  开发期把"可能频繁改动的值"和"属性定义"分开。
  阈值这类东西，属性定义只写宽松的边界（`min=0.0`、
  `soft_max` 给一个很宽的范围），真正的默认值从偏好设置里读。
  这样调参不需要重启，只有"加一个新阈值项"才需要重启。
  本章 `prefs.py` 里 `degenerate_area` 的 `precision=9`
  就是按这个思路给的 —— 它能显示很细的差别，但可调范围留得很宽。
]

另外有一条容易踩的边界：*不要给已经注册的基类加属性，也不要用继承
已注册类的方式共享功能。* `register_class` 在开启 `--debug-python`
时会对这两种情况发出告警
（#src("source/blender/python/intern/bpy_rna.cc:10406-L10428")），
提示"引用了一个已注册的基类 / 子类"。正确做法是用普通 Python 类
做 mix-in，并在类声明里把它放在 `bpy.types.Operator` *之后*。

=== 7.5.4 `poll` 失败与 `context is incorrect`

`context is incorrect` 是 Blender 里最著名的报错之一。
它由操作符调用层抛出，不是你的代码抛的，所以堆栈里看不到自己的函数。
三个层次的排查，从便宜到贵：

*第一层：`poll` 返回 `False`。* 从脚本调用
`bpy.ops.mesh_inspector.inspect()` 时，若 `poll` 为假，你会得到
`RuntimeError: ... poll() failed, context is incorrect`。
最快的诊断是手动调一次：

```python
import bpy
cls = bpy.types.Operator.bl_rna_get_subclass_py("MSI_OT_inspect")
print(cls.poll(bpy.context))
print(bpy.context.mode)
```

把 `poll` 里每个条件单独打印出来，比读堆栈快得多。

*第二层：上下文里缺东西，但 `poll` 没检查。* 常见于在 `execute` 里
直接访问 `context.active_object`、`context.space_data`、`context.area`。
在后台模式（`blender -b`）或脚本运行器里这些可能是 `None`。
纪律是：*`poll` 里检查什么，`execute` 里就只用什么。*
本章的 `MSI_OT_inspect.poll` 检查了 `context.scene` 和物体列表，
`execute` 里就只访问这两者。

*第三层：`bpy.ops` 的默认上下文覆盖。* 在 `execute` 里调用别的
`bpy.ops.*` 时，如果目标操作符需要不同的 `area` / `region`，
需要用 `context.temp_override(...)` 显式指定。本章没有跨上下文调用，
但这是第 5 章内容的自然延伸。

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.0fr, 1.5fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*症状*], [*原因*], [*检查动作*]),
    [`poll() failed, context is incorrect`],
    [`poll` 返回 `False`],
    [手动调 `cls.poll(bpy.context)`，逐条打印条件],
    [`AttributeError: 'NoneType' ...`],
    [上下文成员在后台模式下为 `None`],
    [`context.area` / `context.active_object` 是否未判空],
    [`ValueError: ... already registered`],
    [同一个类注册了两次],
    [`unregister` 是否真的跑过；`bl_rna` 是否残留],
    [`TypeError: PointerProperty(...) expected ...`],
    [目标不是 `PropertyGroup` / `ID`],
    [见 #src("source/blender/python/intern/bpy_props.cc:5516") 的检查],
  ),
  caption: [`poll` 与上下文相关报错的对照表],
) <tbl-poll-errors>

=== 7.5.5 多文件 addon 的相对导入

*规则一：子模块用 `from . import x`，永远不要用 `import x`。*
在 `addons/` 模式下，addon 目录本身被加进了 `sys.path`
（#src("scripts/modules/addon_utils.py:56-L58") 的
`_bpy.utils._sys_path_ensure_append(path)`），
所以 `import properties` 可能真的能找到 `mesh_inspector/properties.py`。
但它找到的是*顶层模块* `properties`，和 `from . import properties`
得到的 `mesh_inspector.properties` 是*两个不同的模块对象*。
症状是"我给属性组加了个方法，一处能调一处不能调"，
或者类的身份比较失败。

*规则二：包名会变，所以不要硬编码。* 在扩展模式下模块名是
`bl_ext.<repo>.<id>`，`__package__` 会相应变化。
所以在 `__init__.py` 里把包名交给 `__package__`
（`MSI_Preferences.bl_idname = __package__`），而不是写字符串。

*规则三：`__init__.py` 里不要 import 一个还没定义的符号。*
循环导入在 addon 里很常见，因为 `ui.py` 需要操作符的 `bl_idname`，
而 `operators.py` 有时又需要界面常量。本章用"操作符只引用数据层、
界面只引用操作符"的单向依赖避开了它（见 7.1.2 的依赖图）。
如果你发现自己需要反向导入，正确做法是把共享常量抽到一个
不依赖任何东西的小模块里 —— 本章的 `inspect.py` 就承担了这个角色。

#pitfall[
  一个特别隐蔽的循环导入症状是
  `AttributeError: module 'X' has no attribute 'Y'`，而且报错行看起来完全正确。
  这通常意味着模块被*部分执行*过 —— 循环导入时 Python 会把半成品模块
  放进 `sys.modules`。诊断办法是在异常处打印
  `import sys; print([k for k in sys.modules if 'mesh_inspector' in k])`，
  如果同一个模块名出现两次（一次带前缀一次不带），就是规则一被违反了。
]

=== 7.5.6 调试技巧清单

`inspect.py` 不依赖 `bpy`，所以它可以脱离 Blender 测试。
这是本章结构设计带来的最大回报：

```python
# 脱离 Blender 测试退化面统计（示意）
import numpy as np


def degenerate_face_count_pure(areas, area_limit):
    bad = areas < area_limit
    return int(np.count_nonzero(bad)), float(areas[bad].sum())


areas = np.array([1.0, 1e-9, 0.5, 0.0], dtype=np.float32)
assert degenerate_face_count_pure(areas, 1e-6) == (2, 1e-9)
```

把"能在纯 Python 里测的部分"和"必须开 Blender 的部分"分开，
是 addon 可维护性的分水岭。前者可以进 CI，后者只能靠人肉回归。

其他几条实战经验：

- *用 `print()`，但要能关掉。* 后台模式下 `print` 进 stdout，
  可以用 `blender -b --python-expr` 抓取；GUI 下进控制台。
  发布版里把调试输出收敛到一个开关（可以就放在偏好设置里）。
- *报告用 `self.report`，不用 `print`。* `report` 会进信息编辑器，
  用户看得见；`print` 只有开发者看得见。
- *`--debug-python` 会让关联的告警出现。* 例如 7.4.3 引用的
  已注册基类告警，只有在 `G_DEBUG_PYTHON` 打开时才会打印。
- *性能先测量。* `bmesh` 遍历在几十万个元素的网格上不算快。
  本章用 `numpy` + `foreach_get` 处理面积与坐标，只有拓扑判断
  还在用 `bmesh`。如果真实项目里发现这里是瓶颈，
  回到第 6 章的方法论：先测，再优化，最后才考虑原生库。

#summary[
  这一节列的六个问题里，前四个（重载、卸载残留、属性定义不可改、
  上下文依赖）占了实际开发中八成的时间。它们的共同点是：
  *报错信息不会直接告诉你原因*。所以真正有用的不是记住报错，
  而是记住这四条对应的检查动作 —— 重启、手动跑卸载清单、
  确认改的是不是属性定义、手动调 `poll`。
]

== 7.6 本章小结

这个 addon 的价值不在于它检查网格有多准，而在于它把第 3–6 章的能力
组织成了一个完整的东西：

- *分层*：算法层（`inspect.py`）不依赖 Blender，集成层薄而明确；
- *数据模型落进 `.blend`*：`PointerProperty` + `CollectionProperty`
  挂到 `Scene` 和 `Object` 上，检查结果随文件保存；
- *注册与卸载镜像*：`reversed(_classes)` 加上对 `bpy.types` 属性的
  显式清理，禁用后不留残留；
- *撤销有分寸*：只读操作符不加 `UNDO`，改数据的加，理由是
  #src("source/blender/windowmanager/WM_types.hh:184-L186") 的定义；
- *能分发*：传统 addon 走 zip，扩展走 `blender --command extension build`，
  兼容性声明各有一套字段。

到此第 1 篇结束。你已经能用纯 Python 做出可分发的东西了。
第 2 篇会回答那些 Python 到不了的问题：为什么某些功能只能在 C++ 层实现，
以及如果必须下去，应该从源码的哪一层下手。

#exercise[
  *练习 7-A（基础）：让检查支持"所有物体"，并给 UIList 加过滤器。*

  目前 `MSI_OT_inspect` 的 `use_selection_only` 默认是 `True`，
  但面板里的 `draw()` 把它硬编码成 `True` 了。请：

  1. 在面板里把它变成一个可勾选的选项，并在操作符调用时传进去
     （提示：`op = col.operator(...)` 之后 `op.<属性名> = 值`）；

  2. 给 `MSI_UL_findings` 加上按严重程度过滤：把
     `use_filter_show` 设为 `True`，加一个自定义的
     `EnumProperty`（例如 `filter_severity`），实现 `filter_items()`
     读写 `filter_flags`，并在 `draw_filter()` 里画出过滤器控件。
     `draw_filter` 与 `filter_items` 的参数列表见
     #src("source/blender/makesrna/intern/rna_ui.cc:2133-L2170")。

  *验收*：关掉过滤器时列表显示全部；只勾 `ERROR` 时列表只剩错误项，
  且点选列表行时高亮的项与数据对应（这里最容易错，
  注意 `filter_flags` 只使用低 16 位）。

  *练习 7-B（进阶）：把结果写进网格属性，让检查结果随网格走。*

  检查结果目前挂在场景上，复制物体时不会跟着走。请改用 Blender 5.x
  的属性 API，给 `mesh.attributes` 添加一个 `BOOLEAN` 类型的
  `"msi_flagged"` 属性（点域），把有问题的顶点标为 `True`。要求：

  1. 先在只读的属性上做统计，不要中途修改被遍历的集合；
  2. 属性可能已存在，要用"存在则复用"的写法，不要重复创建；
  3. 域名与数据类型的合法枚举见
     #src("source/blender/makesrna/intern/rna_attribute.cc:144-L148")；
  4. 因为这个操作符*确实修改了数据*，请给它加上 `UNDO`，
     并写一句注释说明为什么这次应该加。

  *验收*：检查后 `Ctrl+Z` 能撤销标记；保存 `.blend` 后重新打开，
  用 `bpy.data.meshes[...].attributes.keys()` 能看到 `"msi_flagged"`。
]
