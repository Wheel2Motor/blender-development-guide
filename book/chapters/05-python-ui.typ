#import "../common.typ": *

= 第 5 章 用 Python 定义 UI 与交互

第 4 章讲了 addon 怎么被加载、类怎么被注册。但从用户的角度看，一个 addon 是由
*能点、能按、能看见的东西*组成的：一个按钮、一个面板、一个快捷键、一个拖动时
实时更新的浮层。本章讲的就是这些东西在 `bpy` 里分别是什么、由谁调度、
以及它们背后那条从 Python 到 C 的路径。

有一个前提值得先说明。Python 能做 UI，但 Python *不是*在绘制 UI。
`bpy.types.Panel` 的子类只提供一段 `draw()` 回调，真正的布局计算、控件绘制、
事件派发全在 C 侧。你在 Python 里能决定的只有「放什么、按什么条件放」——
这个边界同时解释了本章的绝大部分限制。

#figure(
  kind: table,
  table(
    columns: (1.5fr, 2.2fr, 2.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*Python 侧 ID*], [*C 侧存储结构*], [*注册入口（本节核对位置）*]),
    [`bpy.types.Operator`], [`wmOperatorType`],
    [#src("source/blender/makesrna/intern/rna_wm.cc:2319")（`RNA_def_struct`）],
    [`bpy.types.Panel`], [`Panel`],
    [#src("source/blender/makesrna/intern/rna_ui.cc:1845")],
    [`bpy.types.Menu`], [`Menu`],
    [#src("source/blender/makesrna/intern/rna_ui.cc:2268")],
    [`bpy.types.Header`], [`Header`],
    [#src("source/blender/makesrna/intern/rna_ui.cc:2200")],
    [`bpy.types.UIList`], [`uiList`],
    [#src("source/blender/makesrna/intern/rna_ui.cc:2024")],
    [`bpy.types.UILayout`], [`ui::Layout`],
    [#src("source/blender/makesrna/intern/rna_ui.cc:1723")],
    [`bpy.types.PropertyGroup`], [`bpy_struct`（运行时动态属性）],
    [—（由 `bpy.props` 在运行时定义）],
  ),
  caption: [本章涉及的 Python UI 类型与它们在 C 侧的对应物],
) <tbl-ui-types>

== 5.1 操作符：统一的用户命令入口

=== 5.1.1 定义

#term("操作符", "operator") 是 Blender 用来表示*可由用户或脚本显式触发的命令*
的核心机制。点菜单、按快捷键、按工具栏按钮、执行脚本里的一句
`bpy.ops.object.select_all()` —— 这四种入口最终都会调用操作符系统。

在 Python 里，一个操作符就是一个 `bpy.types.Operator` 的子类，其中：

- `bl_idname` 是它的*唯一标识*，形如 `category.name`（小写 + 点），
  注册后 C 侧会把它转成 `CATEGORY_OT_name`。转换逻辑在
  #src("source/blender/windowmanager/intern/wm_operators.cc:159")（`WM_operator_bl_idname`），
  合法性检查在同文件 #src("source/blender/windowmanager/intern/wm_operators.cc:179")。
- 一组以 `bl_` 开头的类属性描述其元数据（`bl_label`、`bl_description`、
  `bl_options`、`bl_undo_group`、`bl_cursor_pending`）。
- 一组可选的回调方法实现行为：`poll`、`execute`、`check`、`invoke`、
  `modal`、`draw`、`cancel`、`description`。

这八个回调在 C 侧的对应位置是 `wmOperatorType` 的八个函数指针字段
（#src("source/blender/windowmanager/WM_types.hh:1082") 起），
而 Python 版本通过八个包装回调接上去：

```cpp
// source/blender/makesrna/intern/rna_wm.cc:1917（节选）
dummy_ot.pyop_poll = (have_function[0]) ? rna_operator_poll_cb : nullptr;
dummy_ot.exec      = (have_function[1]) ? rna_operator_exec_cb : nullptr;
dummy_ot.check     = (have_function[2]) ? rna_operator_check_cb : nullptr;
dummy_ot.invoke    = (have_function[3]) ? rna_operator_invoke_cb : nullptr;
dummy_ot.modal     = (have_function[4]) ? rna_operator_modal_cb : nullptr;
dummy_ot.ui        = (have_function[5]) ? rna_operator_draw_cb : nullptr;
dummy_ot.cancel    = (have_function[6]) ? rna_operator_cancel_cb : nullptr;
dummy_ot.get_description = (have_function[7]) ? rna_operator_description_cb : nullptr;
```

#note[
  `have_function[8]` 这个数组由注册时对 Python 类的校验产生：
  有哪个方法就装哪个回调。这也是为什么在 Python 里 `poll` 是可选的 ——
  不写它，`dummy_ot.pyop_poll` 就是 `nullptr`，C 侧默认「总是可用」。
]

=== 5.1.2 各回调的精确签名

签名由 RNA 定义决定，可以从 #src("source/blender/makesrna/intern/rna_wm_api.cc:1240")
（`RNA_api_operator`）逐个读出。把它们整理成表：

#figure(
  kind: table,
  table(
    columns: (1.15fr, 2.6fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*方法*], [*必须的签名*], [*返回值*]),
    [`poll`], [`poll(cls, context)`，须为 classmethod], [`bool`],
    [`execute`], [`execute(self, context)`], [`set[str]`],
    [`invoke`], [`invoke(self, context, event)`], [`set[str]`],
    [`modal`], [`modal(self, context, event)`], [`set[str]`],
    [`check`], [`check(self, context)`], [`bool`],
    [`draw`], [`draw(self, context)`], [`None`],
    [`cancel`], [`cancel(self, context)`], [`None`],
    [`description`], [`description(cls, context, properties)`，须为 classmethod], [`str`],
  ),
  caption: [`bpy.types.Operator` 八个可注册回调的签名。返回值一栏是运行时真实检查的约束，不是建议。],
) <tbl-operator-callbacks>

关于 `poll`：它必须是静态方法或类方法，否则注册就会失败。已核对的实际报错是

```text
TypeError: expected Operator, T_OT_probe class "poll" attribute
to be a static/class method, not a function
```

最省事的写法是用 `classmethod`：

```python
class T_OT_probe(bpy.types.Operator):
    bl_idname = "t.probe"
    bl_label = "Probe"

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT'

    def execute(self, context):
        return {'FINISHED'}
```

#pitfall[
  这里有一个细节值得单独记住：`@classmethod` 与 `@staticmethod` 都能通过注册，
  但*如果你用 `@staticmethod`，第一个参数就不叫 `cls`*，
  而 `poll` 的 RNA 定义声明了 `FUNC_NO_SELF`
  （#src("source/blender/makesrna/intern/rna_wm_api.cc:1264")），
  所以静态写法是 `def poll(context)`。混用这两种写法的报错信息很晦涩。
  本书统一用 `@classmethod`。
]

=== 5.1.3 返回值：不是「随便返回一个集合」

`execute` / `invoke` / `modal` 的返回值在 RNA 里被声明为
`result`，其枚举项定义在 #src("source/blender/makesrna/intern/rna_wm.cc:595")
（`rna_enum_operator_return_items`）：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 3.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*标识*], [*含义（引自源码 `ui_description`）*]),
    [`RUNNING_MODAL`], [保持运行，继续接收事件],
    [`CANCELLED`], [退出但没有做任何事，因此*不应*压入撤销记录],
    [`FINISHED`], [完成动作后退出],
    [`PASS_THROUGH`], [什么也不做，把事件传给下层（只能与其他值按位或）],
    [`INTERFACE`], [已处理但不执行（弹出菜单）],
  ),
  caption: [`bpy.types.Operator.execute` 的返回值枚举。注意它们是*按位或*的旗标，不是互斥值。],
) <tbl-operator-returns>

返回值必须是一个*集合*。C 侧把 Python 返回值按 RNA 枚举旗标解析
（解析路径见 #src("source/blender/python/intern/bpy_rna.cc:10035")：
`ret_len == 1` 时调用 `pyrna_py_to_prop`），因此下面这些都会当场报错：

```text
RuntimeError: class T_OT_probe, function execute: incompatible return value ,
             Function.result expected a set, not a NoneType
RuntimeError: class T_OT_probe3, function execute: incompatible return value ,
             Function.result expected a set, not a str
```

也就是说，`return 'FINISHED'`（字符串）和 `return None` 都是错的，
必须写 `return {'FINISHED'}`。而只声明了 `draw` 或 `cancel` 的方法
（它们的 RNA 定义没有 `result` 输出参数）则必须返回 `None` —— 返回别的东西会得到

```text
RuntimeError: expected class X, function draw to return None, not set
```

=== 5.1.4 `bl_options`

`bl_options` 是一个集合，可取的值来自
#src("source/blender/makesrna/intern/rna_wm.cc:550")：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*值*], [*作用*]),
    [`REGISTER`], [显示在信息编辑器里，并支持重做面板（Redo）],
    [`UNDO`], [返回 `FINISHED` 时压入一个撤销步骤。*修改数据就必须加*],
    [`UNDO_GROUPED`], [同一操作符的连续调用只压一个撤销步骤],
    [`BLOCKING`], [独占鼠标指针],
    [`MACRO`], [标记为宏操作符],
    [`GRAB_CURSOR`], [`GRAB_CURSOR_X`], [`GRAB_CURSOR_Y`], [抓取鼠标，启用连续抓取时自动环绕],
    [`DEPENDS_ON_CURSOR`], [需要用户先指定一个位置才能开始],
    [`PRESET`], [在标题栏显示预设按钮],
    [`INTERNAL`], [从搜索菜单里隐藏],
    [`MODAL_PRIORITY`], [优先于其他模态操作符接收事件（慎用）],
  ),
  caption: [`bl_options` 可取的值。`UNDO` 与 `REGISTER` 的关系见 §5.7。],
) <tbl-bl_options>

=== 5.1.5 `self` 上还能访问什么

`bpy.types.Operator` 在 Python 层的实现只有短短二十多行
（#src("scripts/modules/_bpy_types.py:1095")），核心是三个特殊方法：

```python
# scripts/modules/_bpy_types.py:1098（节选）
class Operator(_StructRNA, metaclass=_RNAMeta):
    __slots__ = ()

    def __getattribute__(self, attr):
        properties = _StructRNA.path_resolve(self, "properties")
        bl_rna = getattr(properties, "bl_rna", None)
        if (bl_rna is not None) and (attr in bl_rna.properties):
            return getattr(properties, attr)
        return super().__getattribute__(attr)
```

这段代码解释了一个很容易出错的地方：*操作符属性优先从 `self.properties` 解析*。
凡是在 `properties.bl_rna.properties` 里存在的名字，`self.xxx` 拿到的是
运行时属性值，而不是类属性。已核对的行为差异：

```python
# 类上访问：拿到 Python 侧写的标识
bpy.types.T_OT_probe7.bl_idname        # -> 't.probe7'
# 方法内通过 self 访问：bl_idname 在 OperatorProperties 里也存在，走 RNA 分支
self.bl_idname                          # -> 'T_OT_probe7'
```

#warn[
  在 `execute`/`poll` 里不要用 `self.bl_idname` 去拼操作符标识。
  它会返回 Python 类名。需要标识时用
  `type(self).bl_idname`，或者直接写常量字符串。
]

类上还提供了两个实用工具：

- `as_keywords(*, ignore=())`（#src("scripts/modules/_bpy_types.py:1119")）：
  把实例上的所有属性导成一个 dict，用于「用同样的参数再调一次操作符」。
  它会自动忽略 `rna_type`；集合类型的属性导出后是 `bpy_prop_array`
  而不是普通序列，不要直接拿去序列化。
- `is_registered`（#src("scripts/modules/_bpy_types.py:974")）：
  类属性，返回 `"bl_rna" in cls.__dict__`，即这个类是否已经注册过。

#exercise[
  *练习 5.1* 写一个 `t.duplicate_n_times` 操作符，带一个 `count` 整数属性
  （1–16），`execute` 里把选中的物体各复制 `count` 份，每份沿 X 轴偏移 2 米。
  要求：

  1. `poll` 用 `classmethod`，只在对象模式下、且有选中物体时返回 `True`；
  2. `bl_options` 至少包含 `{'REGISTER', 'UNDO'}`；
  3. 用 `self.report({'INFO'}, ...)` 报告实际复制了多少个；
  4. 故意把 `execute` 改成 `return 'FINISHED'`，观察报错信息，再改回来。
]

3D 视图右侧的侧栏也常被叫作 N 面板#footnote[
  这个俗称来自打开 / 关闭侧栏的默认快捷键 `N`；API 中应使用正式的区域类型和
  `bl_region_type = 'UI'`，不要把“N 面板”当作可查询的标识符。
]。

#figure(
  image("../res/fig-viewport-guide-panel.png", width: 62%),
  caption: [3D 视图侧栏。最右侧是页签列；自定义 `Panel` 的 `bl_category` 会在这里生成额外页签。用本书编译的 Blender #blender-display-version 截取（build hash #blender-commit-short）。]) <fig-viewport-guide-panel>

== 5.2 面板、菜单、头部与 UILayout 布局

=== 5.2.1 四种 UI 容器

这四个类都继承自 `_GenericUI`
（#src("scripts/modules/_bpy_types.py:1171")），它们的 Python 实现本身都是空壳：

```python
# scripts/modules/_bpy_types.py:1282（节选）
class Panel(_StructRNA, _GenericUI, metaclass=_RNAMeta):
    __slots__ = ()

class UIList(_StructRNA, _GenericUI, metaclass=_RNAMeta):
    __slots__ = ()

class Header(_StructRNA, _GenericUI, metaclass=_RNAMeta):
    __slots__ = ()

class Menu(_StructRNA, _GenericUI, metaclass=_RNAMeta):
    __slots__ = ()
```

真正的约束在 RNA 定义里。以面板为例
（#src("source/blender/makesrna/intern/rna_ui.cc:1812") 起）：

- `bl_space_type`：放在哪个编辑器里（`VIEW_3D`、`NODE_EDITOR`、`PROPERTIES`……）；
- `bl_region_type`：放在这个编辑器的哪个区域（`UI`、`HEADER`、`TOOLS`、`WINDOW`……）；
- `bl_category`：侧栏（N 面板）里的标签页名；
- `bl_context`：属性编辑器里的上下文（`object`、`mesh`、`render`……）；
- `bl_parent_id` / `bl_order`：父子面板与排序；
- `bl_options`：可取 `DEFAULT_CLOSED`、`HIDE_HEADER`、`INSTANCED`、
  `HEADER_LAYOUT_EXPAND`
  （#src("source/blender/makesrna/intern/rna_ui.cc:1819") 的 `panel_flag_items`）。
- `poll` 和 `draw` 两个回调，其中 `draw` 是 `FUNC_REGISTER`（必须实现），
  `poll` 是 `FUNC_REGISTER_OPTIONAL`（可选），且 `poll` 声明了 `FUNC_NO_SELF`
  —— 所以它同样必须是 `classmethod`。

一个可以直接用的完整面板：

```python
import bpy


class T_PT_probe(bpy.types.Panel):
    bl_idname = "T_PT_probe"
    bl_label = "探测面板"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Probe"
    bl_options = {'DEFAULT_CLOSED'}

    @classmethod
    def poll(cls, context):
        return context.object is not None

    def draw(self, context):
        layout = self.layout
        layout.label(text="选中物体：%s" % context.object.name)
        layout.prop(context.object, "location")
```

#note[
  `bl_space_type` / `bl_region_type` 的合法值很少变动，但确实会随版本增删。
  不要凭记忆写，用下面的方法现场查：
  `bpy.types.Panel.bl_rna.properties['bl_space_type'].enum_items`
  与 `...['bl_region_type'].enum_items`。
  例如 `bl_region_type` 在 5.2 里包含 `WINDOW`、`HEADER`、`CHANNELS`、
  `TEMPORARY`、`UI`、`TOOLS`、`TOOL_PROPS`、`ASSET_SHELF`、`PREVIEW`、
  `HUD`、`NAVIGATION_BAR`、`EXECUTE`、`FOOTER`、`TOOL_HEADER`、`XR`。
]

=== 5.2.2 UILayout：能调的方法都在 `rna_ui_api.cc` 里

`UILayout` 是 RNA 结构 `ui::Layout` 的映射
（#src("source/blender/makesrna/intern/rna_ui.cc:1723")），
它暴露的不是属性而是一大把*函数*，全部定义在
#src("source/blender/makesrna/intern/rna_ui_api.cc:1332")（`RNA_api_ui_layout`）。
本书只列最常用的部分，完整清单请直接读那个函数——那是最权威的 API 参考。

#figure(
  kind: table,
  table(
    columns: (2fr, 1.6fr, 2.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*方法*], [*分类*], [*说明*]),
    [`row(align=False, heading="")`], [容器], [横向一行],
    [`column(align=False, heading="")`], [容器], [纵向一列],
    [`column_flow(columns=0, align=False)`], [容器], [等宽多列自动折行],
    [`grid_flow(row_major=False, columns=0, even_columns=False, ...)`], [容器], [网格布局，做面板阵列时用],
    [`box()`], [容器], [带边框的分组框],
    [`split(factor=0.0, align=False)`], [容器], [按比例切分左右两栏],
    [`panel(propname, ...)`], [容器], [折叠面板；`panel_prop` 用回调决定是否显示],
    [`label(text="", icon='NONE', icon_value=0)`], [静态], [纯文本 / 图标],
    [`separator(factor=1.0)`], [布局], [间隔，`factor > 1` 会插入一条分隔线],
    [`prop(data, property, ...)`], [属性], [最重要的一个：为一个 RNA 属性生成控件],
    [`props_enum(data, property)`], [属性], [把枚举的每一项画成一个按钮],
    [`prop_menu_enum(data, property, text="")`], [属性], [枚举画成下拉菜单],
    [`prop_search(data, property, search_data, search_property, ...)`], [属性], [带搜索框的数据块选择器],
    [`operator(operator, text="", icon='NONE', emboss=True, depress=False, ...)`], [操作], [操作符按钮，返回 `OperatorProperties`],
    [`operator_enum(operator, property)`], [操作], [枚举操作符画成一排按钮],
    [`operator_menu_enum(operator, property, text="")`], [操作], [枚举操作符画成下拉菜单],
    [`menu(menu, text="", icon='NONE')`], [菜单], [子菜单按钮],
    [`popover(panel, text="", icon='NONE')`], [菜单], [弹出面板],
    [`menu_pie(menu)`], [菜单], [饼菜单],
    [`template_ID(data, property, ...)`], [模板], [数据块选择框],
    [`template_list(list_type, list_id, dataptr, propname, active_dataptr, active_propname, ...)`], [模板], [`UIList` 的实例化入口],
    [`template_color_ramp` / `template_curve_mapping` / `template_icon_view` ...], [模板], [内置可视化控件],
    [`context_pointer_set(name, value)`], [上下文], [设置 `layout.context`，让按钮里的操作符看到不同上下文],
    [`link(url, text="")`], [其他], [可点击链接],
    [`progress(factor=0.0, type='BAR', text="")`], [其他], [进度条],
    [`use_property_split`（属性）], [属性], [把 `prop()` 画成左右分栏的紧凑样式],
    [`use_property_decorate`（属性）], [属性], [显示关键帧按钮等装饰],
    [`enabled` / `alert` / `active` / `alignment` / `scale_x` / `scale_y`], [属性], [子布局的状态],
  ),
  caption: [`UILayout` 常用成员，全部核对自 #src("source/blender/makesrna/intern/rna_ui_api.cc:1332") 与 #src("source/blender/makesrna/intern/rna_ui.cc:1723")],
) <tbl-uilayout>

`layout.operator()` 接受的 `operator` 参数是*小写加点的 Python 形式*，
不是 `OBJECT_OT_xxx`。这一点在 C 侧很清楚：
`rna_uiItemO` 直接把参数交给 `WM_operatortype_find(opname, false)`
（#src("source/blender/makesrna/intern/rna_ui_api.cc:480")），
而 `WM_operatortype_find` 是按 C 侧 `idname` 查表的。
也就是说，如果你写成 `layout.operator("T_OT_probe")`，
它找不到、只会在控制台打印一条 `unknown operator` 警告，
按钮静默消失：

```python
layout.operator("t.probe")           # 正确
layout.operator("T_OT_probe")        # 错误：只会打印警告，按钮不出现
```

#tip[
  在 `draw()` 里写 `self.layout`，在操作符的 `draw()`（弹出对话框）里
  同样写 `self.layout` —— 操作符的 `layout` 属性在 RNA 里存在
  （#src("source/blender/makesrna/intern/rna_wm.cc:2333")），
  这让你能在 `invoke_props_dialog` 的对话框里画自定义内容。
]

=== 5.2.3 Menu 与 Header

`Menu` 的 RNA 定义在 #src("source/blender/makesrna/intern/rna_ui.cc:2268")，
同样有 `poll`（可选）与 `draw`（必须）。`Header` 在
#src("source/blender/makesrna/intern/rna_ui.cc:2200")，只有 `draw`。

`Menu` 额外提供了一个实用方法 `path_menu`
（#src("scripts/modules/_bpy_types.py:1297")）：扫描若干目录、
按自然序排序、把每个文件生成一个按钮。导入导出 addon 用它来列预设，
就不必自己写目录遍历。

`_GenericUI` 提供的 `append` / `prepend` / `remove` / `is_extended`
（#src("scripts/modules/_bpy_types.py:1226") 起）是*扩展已有菜单*的入口。
关键在 `_dyn_ui_initialize`（#src("scripts/modules/_bpy_types.py:1174")）：
第一次 `append` 时，它把原来的 `cls.draw` 包成一个 `draw_ls`，
再把自己装回去。所以：

```python
import bpy


def menu_extra(self, context):
    self.layout.separator()
    self.layout.operator("t.probe", text="探测")


# 在 register() 中：
bpy.types.VIEW3D_MT_object.append(menu_extra)

# 在 unregister() 中：
bpy.types.VIEW3D_MT_object.remove(menu_extra)
```

#pitfall[
  `draw_ls` 里有一个 `try/except` 包住每次 `func(self, context)`
  （#src("scripts/modules/_bpy_types.py:1206")），
  目的是「一个坏掉的菜单函数不该让整个菜单画不出来」。
  代价是：*你在菜单回调里抛出的异常只会打到控制台*，
  UI 上看不出任何异常，只是少了几个条目。
  调试菜单时请打开系统控制台。
]

#summary[
  5.2 的全部规则可以压缩成三句话：
  面板/菜单/头部只提供 `draw()` 与可选的 `poll()`；
  一切布局都通过 `self.layout` 上的方法完成；
  按钮背后的操作符一律用小写加点标识。
]

#exercise[
  *练习 5.2* 给练习 5.1 的操作符加上完整 UI：

  1. 在 3D 视图侧栏新建 `Probe` 分类下的面板，`poll` 只在对象模式显示；
  2. 面板里放一个 `count` 的整数滑块（用 `layout.prop`）；
  3. 面板底部加一个「复制」按钮；
  4. 用 `layout.column_flow(columns=2, align=True)` 排一排图标按钮，
     分别调用 `bpy.ops.object.shade_smooth()` / `shade_flat()` 对应的操作符；
  5. 给这个面板加一个 `bl_parent_id` 指向主面板的子面板，
     并让它默认折叠（`bl_options = {'DEFAULT_CLOSED'}`）。
]

== 5.3 属性系统：`bpy.props`

=== 5.3.1 `bpy.props` 是什么，不是什么

本节要澄清的第一个问题很基础，但经常被搞错：*`bpy.props` 不是 Python 模块。*

```python
# scripts/modules/bpy/__init__.py:23（节选）
# Internal Blender C-API modules.
from _bpy import (
    app,
    context,
    data,
    msgbus,
    props,
    types,
)
```

`props` 是由 C 扩展模块 `_bpy` 提供的，在
#src("source/blender/python/intern/bpy.cc:821") 处挂上去：

```cpp
// source/blender/python/intern/bpy.cc:821（节选）
PyModule_AddObject(mod, "props", BPY_rna_props());
```

它的实现在 #src("source/blender/python/intern/bpy_props.cc")，全文约 5900 行。
所以本节引用的每个函数签名，都能在那个文件里找到对应的 `PyDoc_STRVAR`。

可用的类型共十一种，分别是 `BoolProperty`、`BoolVectorProperty`、
`IntProperty`、`IntVectorProperty`、`FloatProperty`、`FloatVectorProperty`、
`StringProperty`、`EnumProperty`、`PointerProperty`、`CollectionProperty`、
`RemoveProperty`（#src("source/blender/python/intern/bpy_props.cc:5820") 起的方法表）。

=== 5.3.2 关键机制：为什么属性定义能写在类体里

你肯定见过这种写法：

```python
class MySettings(bpy.types.PropertyGroup):
    factor: bpy.props.FloatProperty(default=1.0, min=0.0, max=10.0)
```

按 Python 语义，这一行只是把一个 `FloatProperty(...)` 的返回值绑到类属性
`factor` 上。但 `bpy.props.FloatProperty(...)` 在*没有*传第一个位置参数时，
并不立即创建 RNA 属性——它返回一个延迟对象。这一点在
#src("source/blender/python/intern/bpy_props.cc:3235")
（`bpy_prop_deferred_data_or_srna`）里可以读出来：

```cpp
// source/blender/python/intern/bpy_props.cc:3248（节选）
/* Call this function with the first argument set to `self`. */
if (args_len == 1) {
  self = PyTuple_GET_ITEM(args, 0);
  args = PyTuple_New(0);
  ...
  *r_deferred_result = method_fn(self, args, kw);
  ...
  return nullptr;
}
```

规则是：*属性定义函数可以接受一个位置参数；给了它就是「立即注册到一个已存在的
RNA 类型上」，不给就是「返回延迟对象，等注册时再处理」。*

注册时，C 侧把你的 `__annotations__` 取出来逐个处理。
这条路径是 `pyrna_deferred_register_class` →
`pyrna_deferred_register_class_from_type_hints`
（#src("source/blender/python/intern/bpy_rna.cc:9368")），
它做的事情在注释里写得很直白：

```cpp
// source/blender/python/intern/bpy_rna.cc:9366（节选）
/**
 * Extract `__annotations__` using `typing.get_type_hints` which handles the delayed evaluation.
 */
```

#warn[
  这里有两个直接后果。
  第一，属性定义必须写成*带注解*的形式（`name: bpy.props.XxxProperty(...)`）。
  写成 `name = bpy.props.XxxProperty(...)` 也能运行，但那是因为 Python 的类体
  恰好把结果存进了 `__dict__`；一旦使用 `from __future__ import annotations`
  或注解是字符串，只有带注解的形式才稳定。
  第二，因为用了 `typing.get_type_hints`（见
  #src("source/blender/python/intern/bpy_rna.cc:9374")），
  *每次注册都会真的求值一遍注解表达式*。类体里不要写有副作用的表达式。
]

=== 5.3.3 `update` / `get` / `set` 回调的参数个数是硬性检查

这是 `bpy.props` 里最容易被卡住的地方。所有回调函数都会被检查参数个数，
检查函数是 `bpy_prop_callback_check`
（#src("source/blender/python/intern/bpy_props.cc:2731")）：

```cpp
// source/blender/python/intern/bpy_props.cc:2742（节选）
PyCodeObject *f_code = reinterpret_cast<PyCodeObject *>(PyFunction_GET_CODE(py_func));
if (f_code->co_argcount != argcount) {
  PyErr_Format(PyExc_TypeError,
               "%s keyword: expected a function taking %d arguments, not %d",
               keyword, argcount, f_code->co_argcount);
```

对照表如下。注意 `self` 计入参数个数，所以定义为类方法的回调
就要多一个参数：

#figure(
  kind: table,
  table(
    columns: (1.4fr, 1.3fr, 2.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*关键字*], [*`co_argcount`*], [*典型写法（定义在 PropertyGroup 上）*]),
    [`update`], [2], [`def _update(self, context): ...`],
    [`get`], [1], [`def _get(self): ...`],
    [`set`], [2], [`def _set(self, value): ...`],
    [`get_transform`], [3], [`def _gt(self, target, prop): ...`],
    [`set_transform`], [4], [`def _st(self, target, prop, value): ...`],
    [`poll`（`PointerProperty`）], [2], [`def _poll(self, context): ...`],
    [`search`（`StringProperty`）], [3], [`def _search(self, context, edit_text): ...`],
  ),
  caption: [`bpy.props` 回调的参数个数约束，核对自 #src("source/blender/python/intern/bpy_props.cc:2731")],
) <tbl-prop-callbacks>

#pitfall[
  三个高频错误：

  1. `def _set(self, value)` 是对的；`def _set(self, value, extra)` 会报
     `expected a function taking 2 arguments, not 3`。
  2. 回调会被检查 *是否是函数对象*（`PyFunction_Check`，
     #src("source/blender/python/intern/bpy_props.cc:2734")），
     传一个 `functools.partial` 或 lambda 之外的可调用对象会失败。
  3. `set` 回调*必须*与 `get` 回调成对出现。只给 `set` 会得到
     `The ` + "`set`" + ` callback is defined without a matching ` + "`get`" + ` function`
     （#src("source/blender/python/intern/bpy_props.cc:2803")）。
]

=== 5.3.4 各属性函数的完整签名

下面这些签名逐字取自各函数的 `PyDoc_STRVAR`。每个函数*实际接受*哪些关键字，
还有一份更权威的名单：`bpy_props.cc` 里每个工厂函数内部的 `_keywords[]` 数组
（它就是 `PyArg_ParseTupleAndKeywords` 白名单，写错关键字会直接报
`invalid keyword argument`）。两者的行号一并给出：

#figure(
  kind: table,
  table(
    columns: (1.6fr, 1.3fr, 1.3fr, 2.4fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*工厂函数*], [*`PyDoc` 签名*], [*`_keywords[]`*], [*与相邻项的关键差异*]),
    [`BoolProperty`], [`:3555`], [`:3632`], [—],
    [`BoolVectorProperty`], [`:3744`], [`:3828`], [多一个 `size`],
    [`IntProperty`], [`:3965`], [`:4050`], [有 `min` / `max` / `soft_min` / `soft_max` / `step`],
    [`IntVectorProperty`], [`:4160`], [`:4252`], [同上，另加 `size`],
    [`FloatProperty`], [`:4391`], [`:4485`], [比 `IntProperty` 多 `precision` 与 `unit`],
    [`FloatVectorProperty`], [`:4602`], [`:4703`], [同上，另加 `size`],
    [`StringProperty`], [`:4851`], [`:4939`], [有 `maxlen`、`search`、`search_options`],
    [`EnumProperty`], [`:5073`], [`:5199`], [第一个位置参数是 `items`。*没有 `subtype` / `min` / `max` / `unit`*],
    [`PointerProperty`], [`:5396`], [`:5462`], [第一个参数是 `type`。多一个 `poll`],
    [`CollectionProperty`], [`:5564`], [`:5620`], [第一个参数是 `type`。*没有 `poll`*],
    [`RemoveProperty`], [—], [`:5749`], [用于动态属性注销],
  ),
  caption: [`bpy.props` 各工厂函数的两种行号。路径前缀均为 #src("source/blender/python/intern/bpy_props.cc")],
) <tbl-prop-factories>

#pitfall[
  上表最后两列标注的差异是本小节最值得记的两条，因为它们都属于
  「看起来应该有，其实没有」：

  1. *`EnumProperty` 没有 `subtype`、`min`、`max`、`unit`。*
     枚举的取值范围由 `items` 本身决定，没有数值区间可言。
     传 `subtype` 会得到 `invalid keyword argument`。
  2. *`CollectionProperty` 没有 `poll`。* `poll` 是「这个指针属性在
     当前上下文里是否可赋值」的过滤器，而集合属性是「增删元素」的语义，
     没有单一目标可过滤。所以 `poll` 只存在于 `PointerProperty` 上。
]

```python
# 标量：BoolProperty / IntProperty / FloatProperty / StringProperty
# BoolProperty        source/blender/python/intern/bpy_props.cc:3555
bpy.props.BoolProperty(*, name="", description="", translation_context="*",
                       default=False, options={'ANIMATABLE'}, override=set(),
                       tags=set(), subtype='NONE', update=None,
                       get=None, set=None, get_transform=None, set_transform=None)

# IntProperty         source/blender/python/intern/bpy_props.cc:3965
bpy.props.IntProperty(*, name="", description="", translation_context="*",
                      default=0, min=-2**31, max=2**31-1,
                      soft_min=-2**31, soft_max=2**31-1, step=1,
                      options={'ANIMATABLE'}, override=set(), tags=set(),
                      subtype='NONE', update=None,
                      get=None, set=None, get_transform=None, set_transform=None)

# FloatProperty       source/blender/python/intern/bpy_props.cc:4391
bpy.props.FloatProperty(*, name="", description="", translation_context="*",
                        default=0.0, min=-3.402823e+38, max=3.402823e+38,
                        soft_min=-3.402823e+38, soft_max=3.402823e+38, step=3,
                        precision=2, options={'ANIMATABLE'}, override=set(),
                        tags=set(), subtype='NONE', unit='NONE', update=None,
                        get=None, set=None, get_transform=None, set_transform=None)

# StringProperty      source/blender/python/intern/bpy_props.cc:4851
bpy.props.StringProperty(*, name="", description="", translation_context="*",
                         default="", maxlen=0, options={'ANIMATABLE'},
                         override=set(), tags=set(), subtype='NONE', update=None,
                         get=None, set=None, get_transform=None,
                         set_transform=None, search=None,
                         search_options={'SUGGESTION'})
```

```python
# 向量：BoolVectorProperty / IntVectorProperty / FloatVectorProperty
# BoolVectorProperty  source/blender/python/intern/bpy_props.cc:3744
bpy.props.BoolVectorProperty(*, name="", description="", translation_context="*",
                             default=(False, False, False),
                             options={'ANIMATABLE'}, override=set(), tags=set(),
                             subtype='NONE', size=3, update=None,
                             get=None, set=None, get_transform=None, set_transform=None)

# IntVectorProperty   source/blender/python/intern/bpy_props.cc:4160
bpy.props.IntVectorProperty(*, name="", description="", translation_context="*",
                            default=(0, 0, 0), min=-2**31, max=2**31-1,
                            soft_min=-2**31, soft_max=2**31-1, step=1,
                            options={'ANIMATABLE'}, override=set(), tags=set(),
                            subtype='NONE', size=3, update=None,
                            get=None, set=None, get_transform=None, set_transform=None)

# FloatVectorProperty source/blender/python/intern/bpy_props.cc:4602
bpy.props.FloatVectorProperty(*, name="", description="", translation_context="*",
                              default=(0.0, 0.0, 0.0), min=-sys.float_info.max,
                              max=sys.float_info.max, soft_min=-sys.float_info.max,
                              soft_max=sys.float_info.max, step=3, precision=2,
                              options={'ANIMATABLE'}, override=set(), tags=set(),
                              subtype='NONE', unit='NONE', size=3, update=None,
                              get=None, set=None, get_transform=None, set_transform=None)
```

`EnumProperty` 的第一个参数是 `items`（位置参数，必需）。
它的关键字白名单在 #src("source/blender/python/intern/bpy_props.cc:5199")，
一共只有 `attr`、`items`、`name`、`description`、`translation_context`、
`default`、`options`、`override`、`tags`、`update`、`get`、`set`、
`get_transform`、`set_transform` 十四个：

```python
# source/blender/python/intern/bpy_props.cc:5073
bpy.props.EnumProperty(items, *, name="", description="", translation_context="*",
                       default=None, options={'ANIMATABLE'}, override=set(),
                       tags=set(), update=None, get=None, set=None,
                       get_transform=None, set_transform=None)
```

`items` 的格式文档写在 #src("source/blender/python/intern/bpy_props.cc:5091") 起：

```text
:param items: sequence of enum items formatted:
   [(identifier, name, description, icon, number), ...].
   The first three elements of the tuples are mandatory.
```

也就是说 `(标识, 界面名, 说明)` 三个元素是必需的，
第四、五个可以省略（省略时按 `(identifier, name, description, number)` 解析）。
标识为空串的项会被当成*分隔符*。

`PointerProperty` 与 `CollectionProperty` 是*数据块类型*与*运行时子结构*
之间的桥，第一个参数都是类型。两者的白名单分别是
#src("source/blender/python/intern/bpy_props.cc:5462")
（`attr`、`type`、`name`、`description`、`translation_context`、`options`、
`override`、`tags`、`poll`、`update`）与
#src("source/blender/python/intern/bpy_props.cc:5620")
（同上但*没有* `poll`）：

```python
# source/blender/python/intern/bpy_props.cc:5396
bpy.props.PointerProperty(type, *, name="", description="",
                          translation_context="*", options={'ANIMATABLE'},
                          override=set(), tags=set(), poll=None, update=None)

# source/blender/python/intern/bpy_props.cc:5564
bpy.props.CollectionProperty(type, *, name="", description="",
                             translation_context="*", options={'ANIMATABLE'},
                             override=set(), tags=set())
```

`PointerProperty` 的 `type` 必须是 `PropertyGroup` 的派生类或某个 `ID` 类型，
否则报错信息是（#src("source/blender/python/intern/bpy_props.cc:5517")）：

```text
PointerProperty(...) expected an RNA type derived from ID or PropertyGroup
```

#note[
  `PointerProperty` 的文档里有一句限制很容易忽略
  （#src("source/blender/python/intern/bpy_props.cc:5424")）：
  它*不支持*指向内嵌 ID（`Scene.collection`、`Material.node_tree` 之类）。
  这类内嵌 ID 只能通过其宿主 ID 访问。
]

#warn[
  还有一条注册期的限制值得提前知道：同一个名字不能被注册两次。
  重复注册会在注册时（而不是定义时）抛出

  ```text
  ValueError: ... already registered as a subclass '...'
  ```

  抛出位置在 #src("source/blender/python/intern/bpy_rna.cc:10386")。
  它最常见的触发场景是「先注册了一次，`unregister()` 里漏了
  `bpy.utils.unregister_class()`，然后又注册一次」——
  也就是第 4 章反复强调的对称性问题。
]


=== 5.3.5 `options` 到底有哪些值

`options` 的合法值来自 `rna_enum_property_flag_items`
（#src("source/blender/makesrna/intern/rna_rna.cc:189")），常用的有：

`ANIMATABLE`（默认，可被动画系统驱动）、`HIDDEN`、`SKIP_SAVE`、
`SKIP_PRESET`、`LIBRARY_EDITABLE`、`PROPORTIONAL`、`TEXTEDIT_UPDATE`、
`OUTPUT_PATH`、`PATH_SUPPORTS_BLEND_RELATIVE`、`SUPPORTS_TEMPLATES`、
`READ_ONLY`。

枚举属性另有一组（#src("source/blender/makesrna/intern/rna_rna.cc:233")），
在通用集合基础上多了 `ENUM_FLAG`——加上它，枚举就变成可以按位或的多选旗标，
`default` 也相应要写成集合。

#pitfall[
  `READ_ONLY` 这个名字在 `bpy.props` 里的含义与 RNA 内部相反。
  源码里的注释说明了原因
  （#src("source/blender/makesrna/intern/rna_rna.cc:190")）：
  Python 侧为了「默认可编辑」，把枚举值 `PROP_EDITABLE` 反着用，
  再由 `bpy_prop_assign_flag` 翻回来。
  所以你写 `options={'READ_ONLY'}` 得到的确实是只读属性——不要被枚举值绕晕。
]

#exercise[
  *练习 5.3* 建一个 `ProbeSettings(PropertyGroup)`，包含：

  1. `factor: FloatProperty(name="系数", default=1.0, min=0.0, max=8.0, step=10, precision=3)`；
  2. `mode: EnumProperty(items=[('SIMPLE', "简单", ""), ('FANCY', "精细", ""),
     ('EXTREME', "极端", "")], default='SIMPLE')`；
  3. `flags: EnumProperty(items=[('A', "A", ""), ('B', "B", ""), ('C', "C", "")],
     options={'ENUM_FLAG'}, default={'A'})`；
  4. `axis: FloatVectorProperty(subtype='XYZ', default=(0.0, 0.0, 1.0), size=3)`；
  5. `filepath: StringProperty(subtype='FILE_PATH')`；
  6. 一个 `level: IntProperty(min=1, max=5)`，配一个 `update` 回调，
     在回调里 `print(self, context)` 观察两个参数分别是什么。

  然后把它挂到 `Object` 上（`bpy.types.Object.probe: bpy.props.PointerProperty(type=ProbeSettings)`），
  并验证：*注销顺序不对*时会出现什么报错。这个报错本身是第 4 章的知识点。
]

== 5.4 `PropertyGroup`、自定义属性与 `UIList`

=== 5.4.1 `PropertyGroup`：把一组属性打包成可复用的结构

`PropertyGroup` 在 Python 层的实现只有一个空类体
（#src("scripts/modules/_bpy_types.py:1155")）：

```python
# scripts/modules/_bpy_types.py:1155（节选）
class PropertyGroup(_StructRNA, metaclass=_RNAMetaPropGroup):
    __slots__ = ()
```

关键在于它的 metaclass。`_RNAMetaPropGroup` 继承自
`bpy_struct_meta_idprop`（#src("scripts/modules/_bpy_types.py:979")），
而这个元类的 C 实现就是 #src("source/blender/python/intern/bpy_rna.cc:7276")
的 `pyrna_struct_meta_idprop_Type`。它做的事是：
*把实例的属性读写重定向到该实例上的一张 IDProperty 表*。

这解释了一件事：`PropertyGroup` 的实例数据并不是存在一个固定布局的 C 结构体里，
而是存在 IDProperty 里。所以：

- 你可以在运行时给它加属性（见下）；
- 它能随 `.blend` 文件保存（IDProperty 会被序列化）；
- `bpy.props` 定义只是给它一个「默认值 + 界面元数据 + 合法范围」的外壳。

把一组设置挂到数据块上，标准做法是 `PointerProperty`：

```python
import bpy


class ProbeSettings(bpy.types.PropertyGroup):
    factor: bpy.props.FloatProperty(name="系数", default=1.0, min=0.0, max=8.0)
    label: bpy.props.StringProperty(name="标签", default="probe")


classes = (ProbeSettings,)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Object.probe = bpy.props.PointerProperty(type=ProbeSettings)


def unregister():
    del bpy.types.Object.probe
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
```

#warn[
  `bpy.types.Object.probe = ...` 这种「给已注册 RNA 类型打补丁」的写法
  只在运行时有效，*不会*写进 `.blend`。它必须在 `register()` 里执行，
  并且必须在 `unregister()` 里用 `del` 撤销——否则禁用 addon 后
  这个悬空指针会导致崩溃。这是第 4 章反复强调的对称性原则在这里的具体体现。
]

=== 5.4.2 自定义属性（IDProperty）

任何 `ID` 派生类型（`Object`、`Mesh`、`Scene`、`Material`……）都支持
方括号访问，走的是 IDProperty：

```python
import bpy

obj = bpy.context.object

# 写
obj["my_int"] = 42
obj["my_float"] = 1.5
obj["my_list"] = [1.0, 2.0, 3.0]
obj["my_group"] = {"nested": True, "count": 3}

# 读
print(obj["my_int"], obj.get("missing", "default"))

# 判断存在性与删除
if "my_float" in obj:
    del obj["my_float"]
```

IDProperty 的结构体定义在 #src("source/blender/makesdna/DNA_ID.h:143")
（`IDProperty`），名字缓冲区的长度上限是
#src("source/blender/makesdna/DNA_ID.h:174") 的 `MAX_IDPROP_NAME`，
其值为 64，所以*名字最长 63 个字符*。

#pitfall[
  同一个类上，「注解属性」和「IDProperty」是两套不同的存储，
  但共享属性访问语法。`obj.key = v` 若 `key` 是已注册的 RNA 属性就走 RNA，
  否则走 IDProperty。最常见的后果是：
  你把 `bpy.props` 定义写在了类体里但*忘了注册这个类*，
  赋值看起来「成功」了，但读出来永远是默认值、
  而且 `obj.bl_rna.properties` 里根本找不到它。
  调试时先查 `obj.bl_rna.properties.keys()`。
]

#note[
  RNA 属性的名字不允许以下划线开头。这条限制在
  #src("source/blender/python/intern/bpy_rna.cc:9301") 内，

  ```text
  bpy_struct "X" registration error: '_foo' FloatProperty could not
  register because it starts with an '_'
  ```

  所以约定上，`bpy.props` 定义的属性名一律不带下划线前缀。
]

=== 5.4.3 `UIList`：把集合画成一个列表

`UIList` 在 Python 层同样是空壳
（#src("scripts/modules/_bpy_types.py:1286")），它的契约全在 RNA 里
（#src("source/blender/makesrna/intern/rna_ui.cc:2024")）。核心属性与回调：

#figure(
  kind: table,
  table(
    columns: (1.9fr, 3.2fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*说明*]),
    [`bl_idname`], [列表类型标识，如 `OBJECT_UL_vgroups`；不设则取类名],
    [`list_id`], [只读。`template_list` 传入的 `list_id` 参数],
    [`layout_type`], [只读。`DEFAULT` / `COMPACT` / `GRID`],
    [`use_filter_show`], [是否显示过滤栏],
    [`filter_name`], [按名字过滤，支持 `*` 通配],
    [`use_filter_invert`], [反转过滤结果],
    [`use_filter_sort_alpha`、`use_filter_sort_reverse`、`use_filter_sort_lock`],
    [排序选项],
    [`draw_item(context, layout, data, item, icon, active_data, active_property, index, flt_flag)`],
    [画一行。签名由 RNA 逐参数声明，见 #src("source/blender/makesrna/intern/rna_ui.cc:2095")],
    [`draw_filter(context, layout)`], [画过滤栏，可选],
    [`filter_items(context, data, property)`], [返回 `(filter_flags, filter_neworder)` 两个列表],
    [`bitflag_filter_item`], [只读常数，在 `filter_flags` 里置位表示「这一项要显示」],
    [`bitflag_item_never_show`], [只读常数，置位表示「永不显示」],
  ),
  caption: [`bpy.types.UIList` 的成员，核对自 #src("source/blender/makesrna/intern/rna_ui.cc:2024") 起],
) <tbl-uilist>

`draw_item` 的参数很多，但绝大多数时候只有前几个用得到。一个完整可用的例子：

```python
import bpy


class ProbeItem(bpy.types.PropertyGroup):
    name: bpy.props.StringProperty()
    weight: bpy.props.FloatProperty(default=1.0, min=0.0, max=1.0)


class PROBE_UL_items(bpy.types.UIList):
    bl_idname = "PROBE_UL_items"

    def draw_item(self, context, layout, data, item, icon,
                  active_data, active_property, index, flt_flag):
        # 防御性判断：Blender 不保证 item 的类型
        if self.layout_type in {'DEFAULT', 'COMPACT'}:
            row = layout.row(align=True)
            row.prop(item, "name", text="", emboss=False)
            row.prop(item, "weight", text="")
        elif self.layout_type == 'GRID':
            layout.alignment = 'CENTER'
            layout.label(text="", icon_value=icon)

    def filter_items(self, context, data, property):
        items = getattr(data, property)
        # 用 bitflag_filter_item 表示「保留」，其余位留给自己用
        flags = [self.bitflag_filter_item] * len(items)
        for i, item in enumerate(items):
            if item.weight <= 0.0:
                flags[i] = 0
        return flags, []


class ProbeListOwner(bpy.types.PropertyGroup):
    items: bpy.props.CollectionProperty(type=ProbeItem)
    active_index: bpy.props.IntProperty()
```

在 `draw()` 里实例化它：

```python
row = layout.row()
row.template_list("PROBE_UL_items", "", owner, "items", owner, "active_index")
```

`filter_items` 的返回值语义在 RNA 的 `ui_description` 里写得很清楚
（#src("source/blender/makesrna/intern/rna_ui.cc:2144")）：
「输出过滤结果到 `filter_flags`，输出重排结果到 `filter_neworder`」。
返回空列表表示「不重排」。同时那条说明也提醒了一句：

```text
(NOTE: The upper 16 bits, including FILTER_ITEM, are reserved,
only use the lower 16 bits for custom usages)
```

也就是说，你自己的标记只能占 `filter_flags` 的低 16 位。

#exercise[
  *练习 5.4* 把练习 5.3 的设置升级成「带列表的」：

  1. 定义 `ProbeItem`（`name: StringProperty`、`weight: FloatProperty`）；
  2. 定义 `ProbeListOwner`（`items: CollectionProperty(type=ProbeItem)`、
     `active_index: IntProperty`）；
  3. 定义 `PROBE_UL_items`，`draw_item` 里显示名字与权重，
     `filter_items` 里把权重为 0 的项过滤掉；
  4. 在练习 5.2 的面板里用 `template_list` 把它画出来；
  5. 再加两个操作符：`t.probe_item_add` / `t.probe_item_remove`，
     操作 `items` 集合并维护 `active_index`。注意它们必须带 `UNDO`。
]

== 5.5 事件、快捷键、模态操作符、定时器与消息总线

=== 5.5.1 `bpy.types.Event`

模态操作符的参数 `event` 是 `bpy.types.Event`，RNA 定义在
#src("source/blender/makesrna/intern/rna_wm.cc:2484") 起。最常用的字段：

#figure(
  kind: table,
  table(
    columns: (1.7fr, 1.3fr, 2.4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段*], [*类型*], [*含义*]),
    [`type`], [`enum`], [事件类型，如 `'MOUSEMOVE'`、`'LEFTMOUSE'`、`'ESC'`、`'RET'`],
    [`value`], [`enum`], [`'PRESS'` / `'RELEASE'` / `'CLICK'` / `'DOUBLE_CLICK'` / `'NOTHING'`],
    [`type_prev`、`value_prev`], [`enum`], [上一个事件的类型与值],
    [`mouse_x`、`mouse_y`], [`int`], [相对于*窗口*的坐标],
    [`mouse_region_x`、`mouse_region_y`], [`int`], [相对于*区域*的坐标。模态里最常用],
    [`mouse_prev_x`、`mouse_prev_y`], [`int`], [上一次事件的位置，用来算增量],
    [`is_repeat`], [`bool`], [按住不放产生的重复事件],
    [`shift`、`ctrl`、`alt`、`oskey`], [`bool`], [修饰键是否按下],
    [`ascii`、`unicode`], [`str`], [按键对应的字符],
    [`pressure`、`tilt`、`is_tablet`], [`float` 或 `bool`], [数位板数据],
  ),
  caption: [`bpy.types.Event` 的常用字段，核对自 #src("source/blender/makesrna/intern/rna_wm.cc:2484")],
) <tbl-event>

#note[
  `shift` / `ctrl` / `alt` 的 `RNA_def_property_boolean_sdna` 指向
  `modifier` 字段的 `KM_SHIFT` / `KM_CTRL` / `KM_ALT` 位
  （#src("source/blender/makesrna/intern/rna_wm.cc:2645") 起）。
  注意 `mouse_region_x/y` 来自 `mval`，而 `mouse_x/y` 来自 `xy`：
  在一个分了多个区域的窗口里，这两组值并不相同。
  模态操作符应该用 `mouse_region_*`。
]

=== 5.5.2 模态操作符

一个模态操作符需要两个方法：`invoke` 用来接管控制权（通常返回
`{'RUNNING_MODAL'}`），`modal` 用来处理后续每一个事件。

```python
import bpy
from bpy_extras import view3d_utils


class T_OT_modal_probe(bpy.types.Operator):
    bl_idname = "t.modal_probe"
    bl_label = "模态探测"
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        return context.area is not None and context.area.type == 'VIEW_3D'

    def invoke(self, context, event):
        if context.area.type != 'VIEW_3D':
            self.report({'WARNING'}, "只能在 3D 视图里运行")
            return {'CANCELLED'}

        self.start_mouse = (event.mouse_region_x, event.mouse_region_y)
        # 把当前状态存进窗口管理器，供 draw 使用
        context.window_manager.modal_handler_add(self)
        return {'RUNNING_MODAL'}

    def modal(self, context, event):
        # 先处理退出条件
        if event.type in {'RIGHTMOUSE', 'ESC'}:
            return {'CANCELLED'}

        if event.type == 'MOUSEMOVE':
            dx = event.mouse_region_x - self.start_mouse[0]
            dy = event.mouse_region_y - self.start_mouse[1]
            self.report({'INFO'}, "位移 %d, %d" % (dx, dy))

        elif event.type in {'LEFTMOUSE', 'RET'}:
            return {'FINISHED'}

        return {'RUNNING_MODAL'}

    def cancel(self, context):
        # 只有真的需要清理时才写这个回调
        pass
```

这里有三条必须记住的规则：

1. *`modal` 返回 `{'RUNNING_MODAL'}` 才会继续收到事件。* 这一点在
   `wmOperatorType::modal` 的注释里说得很明确
   （#src("source/blender/windowmanager/WM_types.hh:1132")）：
   「They keep running until they don't return `OPERATOR_RUNNING_MODAL`」。
2. *`invoke` 返回 `{'RUNNING_MODAL'}` 才会进入模态循环。* 如果返回
   `{'FINISHED'}`，模态循环根本不会开始。
3. *必须在 `invoke` 里注册模态处理器。* Python 侧调用
   `context.window_manager.modal_handler_add(self)`
   （RNA 入口 #src("source/blender/makesrna/intern/rna_wm_api.cc:1019")，
   绑定到 `rna_event_modal_handler_add`）。忘了这一句，
   操作符会在 `invoke` 返回后直接结束。

#warn[
  模态操作符里*不要*做重活。`modal` 会在每一帧、每一个鼠标移动事件上被调用。
  一旦它耗时超过一帧的预算，界面就会明显卡顿。
  长任务要么拆成短小步骤，再由 `bpy.app.timers` 分批调度；要么把不访问 `bpy`
  数据的纯计算放到后台线程，完成后再回到主线程写回结果。定时器本身仍在主线程运行，
  不能用来包住一个长时间不返回的计算。
]

#pitfall[
  如果 `modal` 抛出异常，C 侧会移除为这个操作符注册的*所有*模态处理器
  （`WM_event_remove_modal_handler_all`，
  #src("source/blender/makesrna/intern/rna_wm.cc:1633")——这是修
  issue #113479 时加的保护）。表现是操作符突然「静默失效」，
  而你在界面上只看到控制台里一行 traceback。写模态操作符时，
  第一件事就是打开系统控制台。
]

=== 5.5.3 快捷键：`wm.keyconfigs`

Python 侧注册快捷键的入口是 `bpy.context.window_manager.keyconfigs`
（`WindowManager.keyconfigs` 的实现见
#src("source/blender/makesrna/intern/rna_wm.cc:1560") 附近）。相关 API：

```python
# KeyConfigs.new(name)                  source/blender/makesrna/intern/rna_wm_api.cc:1594
# KeyMaps.new(name, *, space_type='EMPTY', region_type='WINDOW',
#             modal=False, tool=False)
#                                       source/blender/makesrna/intern/rna_wm_api.cc:1536
# KeyMapItems.new(idname, type, value, *, any=False, shift=..., ctrl=...,
#                 alt=..., oskey=..., hyper=..., key_modifier=..., direction=...,
#                 repeat=False, head=False)
#                                       source/blender/makesrna/intern/rna_wm_api.cc:1425
# KeyMapItems.new_modal(propvalue, type, value, *, ...)
#                                       source/blender/makesrna/intern/rna_wm_api.cc:1451
```

一个完整的、可撤销的快捷键注册：

```python
import bpy

addon_keymaps = []


def register():
    wm = bpy.context.window_manager
    # 在默认键盘配置里追加，而不是新建一个配置
    kc = wm.keyconfigs.addon
    if kc:
        km = kc.keymaps.new(name="3D View", space_type='VIEW_3D')
        kmi = km.keymap_items.new("t.probe", 'P', 'PRESS',
                                 ctrl=True, shift=True)
        kmi.properties.count = 4
        addon_keymaps.append((km, kmi))


def unregister():
    for km, kmi in addon_keymaps:
        km.keymap_items.remove(kmi)
    addon_keymaps.clear()
```

`new_modal` 用于给模态键盘映射（`modal=True` 的 KeyMap）添加条目，
它的第一个参数是 `propvalue`——模态操作符在 `modal()` 里通过
`event.type` 之外的方式区分事件时用得到。

#pitfall[
  两个最常见的快捷键 bug：

  1. *在 `unregister()` 里没有移除条目。* 后果是禁用再启用 addon 后
     快捷键出现两份，而且 `KeyMapItems.remove()` 之后原来的 `kmi`
     对象会失效，不要留着继续用。
  2. *用了 `wm.keyconfigs.active` 而不是 `wm.keyconfigs.addon`。*
     往用户当前配置里直接塞条目会被用户的自定义覆盖，
     而且不会随 addon 一起被清理。始终用 `addon`。
]

=== 5.5.4 `bpy.app.timers`

定时器是「不阻塞界面地周期性做事」的正确工具。实现只有 212 行：
#src("source/blender/python/intern/bpy_app_timers.cc")。它提供三个函数：

```python
# source/blender/python/intern/bpy_app_timers.cc:76
bpy.app.timers.register(function, *, first_interval=0, persistent=False)
# source/blender/python/intern/bpy_app_timers.cc:126
bpy.app.timers.unregister(function)
# source/blender/python/intern/bpy_app_timers.cc:144
bpy.app.timers.is_registered(function)
```

回调契约写在 `register` 的文档里（#src("source/blender/python/intern/bpy_app_timers.cc:76")）：

```text
The function gets no arguments and is expected to return either None or a float.
If ``None`` is returned, the timer will be unregistered.
A returned number specifies the delay until the function is called again.
```

返回值到 C 侧的转换在 `handle_returned_value`
（#src("source/blender/python/intern/bpy_app_timers.cc:22")）：
返回 `Py_None` 得到 `-1`（移除）；返回负数会被 `std::max(value, 0.0)` 夹到 0。

```python
import bpy
import time

_last = [0.0]


def poll_scene_stats():
    """每 0.5 秒更新一次统计信息；返回 None 时自动注销。"""
    obj_count = len(bpy.context.scene.objects)
    print("物体数：%d" % obj_count)
    if obj_count > 10_000:
        return None          # 停止定时器
    return 0.5               # 0.5 秒后再来一次


def register():
    bpy.app.timers.register(poll_scene_stats, first_interval=1.0)


def unregister():
    if bpy.app.timers.is_registered(poll_scene_stats):
        bpy.app.timers.unregister(poll_scene_stats)
```

#note[
  `persistent=True` 的含义是「加载新文件时不移除这个定时器」——
  见 `register` 的文档（#src("source/blender/python/intern/bpy_app_timers.cc:88")）
  与 `BLI_timer_register` 的最后一个 `persistent` 参数
  （#src("source/blender/blenlib/BLI_timer.h:25")）。
  只有当回调确实需要跨文件继续存在时才设为 `True`；普通 addon 保留默认的
  `False` 更安全。无论取值如何，`unregister()` 都应显式移除仍在注册的定时器。
]

#pitfall[
  定时器回调在 C 侧被调用时，会先 `PyGILState_Ensure()`
  （#src("source/blender/python/intern/bpy_app_timers.cc:44")）。
  这意味着它*在主线程*运行，操作 `bpy.data` 是安全的；
  但也意味着*你在回调里睡多久，界面就卡多久*。
  千万不要在定时器里 `time.sleep()` 或执行耗时循环。
]

=== 5.5.5 `bpy.app.handlers`

定时器解决「周期性」，`handlers` 解决「事件发生时」。可用的处理器名字
定义在 #src("source/blender/python/intern/bpy_app_handlers.cc:97") 起，
包括 `frame_change_pre` / `frame_change_post`、`render_pre` /
`render_post` / `render_init` / `render_complete` / `render_cancel`、
`load_pre` / `load_post`、`save_pre` / `save_post`、
`undo_pre` / `undo_post` / `redo_pre` / `redo_post`、
`depsgraph_update_pre` / `depsgraph_update_post`、
`version_update`、`annotation_pre` / `annotation_post` 等。

用法与定时器对称：

```python
import bpy


def on_frame_change(scene, depsgraph=None):
    print("帧：%d" % scene.frame_current)


def register():
    bpy.app.handlers.frame_change_post.append(on_frame_change)


def unregister():
    bpy.app.handlers.frame_change_post.remove(on_frame_change)
```

#pitfall[
  `frame_change_pre` 的文档（#src("source/blender/python/intern/bpy_app_handlers.cc:99")）
  特别提醒：它*不是*「帧改变之前」的意思，而是「新帧的任何数据被求值之前」。
  在它里面可以改数据和关系（比如换掉一个物体的网格），
  但*依赖图不可用*——因为依赖图还没为新帧更新。
  需要在求值后做事就用 `frame_change_post`。
]

=== 5.5.6 `bpy.msgbus`：订阅 RNA 属性变化

当需求是“某个 RNA 属性变化后更新自己的缓存或界面”时，不必用定时器不断轮询，
也不必用范围过大的 `depsgraph_update_post`。`bpy.msgbus` 提供了属性级订阅：
`subscribe_rna()` 注册，`clear_by_owner()` 成组清理，`publish_rna()` 在少数需要手动发布的
场景使用。三者由 #src("source/blender/python/intern/bpy_msgbus.cc:192") 定义。

```python
import bpy

_msgbus_owner = object()


def object_name_changed():
    # 回调在相关操作符结束后执行；不要在这里做长时间计算。
    print("有物体改名")


def register():
    bpy.msgbus.subscribe_rna(
        key=(bpy.types.Object, "name"),
        owner=_msgbus_owner,
        args=(),
        notify=object_name_changed,
    )


def unregister():
    bpy.msgbus.clear_by_owner(_msgbus_owner)
```

这里的 `owner` 不是数据块所有者，而是订阅的清理句柄#footnote[
  `owner` 可以是任意 Python 对象，比较方式是对象身份而不是相等性；
  因此模块级 `object()` 很适合把一个插件的多条订阅归为一组。
]。`key=(bpy.types.Object, "name")` 会订阅*所有*物体的名字；若只关心一个具体属性，
可传入该 RNA 属性对象。某些属性取出后会被转换成普通 Python 值，这时用
`datablock.path_resolve("property_name", False)` 取得可订阅的属性句柄
（官方示例见 #src("doc/python_api/examples/bpy.msgbus.1.py:38")）。

#warn[
  消息总线不是“所有变化的统一事件流”。官方示例明确列出两个不会触发通知的来源：
  在 3D 视图里直接移动物体，以及动画系统写值；回调中的修改也不会自动并入相关的
  撤销步骤。订阅会在加载另一份 `.blend` 时被清空；需要跨文件继续工作的插件，
  应在 `load_post` 里重新订阅。`options={'PERSISTENT'}` 只影响 ID 重映射，
  不能替代加载后的重新注册。
]

#exercise[
  *练习 5.5* 做一个「实时物体计数器」：

  1. 用 `bpy.app.timers.register` 每 0.25 秒统计一次场景里处于
     `'EDIT'` 模式的物体数量，并打印出来；
  2. 让定时器在统计到 0 个物体时自动停止（返回 `None`）；
  3. 再加一个模态操作符 `t.measure`：`invoke` 里用
     `wm.modal_handler_add(self)` 接管控制，`modal` 里跟踪鼠标
     在两点的距离并写进 `self.report`，`ESC` 取消；
  4. 在 `3D View` 键盘映射里给它绑定 `Ctrl+Shift+M`，
     并确保禁用 addon 后绑定被干净地移除；
  5. 用 `bpy.msgbus` 订阅所有 `Object.name` 的变化，禁用 addon 时通过同一个
     owner 一次性清理订阅。
]

== 5.6 视口叠加绘制：draw handler 与 `gpu`

面板属于 Blender 的常规 UI；测量线、选择轮廓、屏幕角落的状态文字则需要画进编辑器区域。
Python 侧的入口是各 `Space` 类型上的 `draw_handler_add()`：它返回一个句柄，区域每次重绘时
都会调用你的函数。签名与绘制阶段的含义见
#src("source/blender/python/intern/bpy_rna_types_capi.cc:150")。

=== 5.6.1 先选对坐标空间

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*`draw_type`*], [*常见用途*], [*坐标含义*]),
    [`POST_VIEW`], [3D 线框、点、辅助几何], [世界 / 视图空间，由当前视图矩阵投影],
    [`POST_PIXEL`], [屏幕文字、鼠标轨迹、HUD], [区域像素坐标],
    [`PRE_VIEW`], [少数需要在常规 3D 内容之前绘制的效果], [3D 视图空间],
    [`BACKDROP`], [节点编辑器背景], [节点编辑器专用],
  ),
  caption: [`Space.draw_handler_add()` 支持的四个绘制阶段。常规 3D 叠加层用 `POST_VIEW`，2D HUD 用 `POST_PIXEL`。],
) <tbl-python-draw-types>

绝大多数 3D 视图叠加层都把 `region_type` 设为 `'WINDOW'`。这四个枚举在
#src("source/blender/python/intern/bpy_rna_callback.cc:41") 定义；传错区域或绘制阶段时，
结果通常不是异常，而是回调存在却什么都看不到。

=== 5.6.2 一个可干净注销的 3D 线框

下面的例子使用内置折线着色器和 `batch_for_shader()`。batch#footnote[
  这里的 batch 是“一次绘制所需的顶点、可选索引和图元类型”的组合，
  不是 Blender 的批处理模式。把它缓存起来复用，可避免每次重绘都重建 GPU 缓冲。
] 在注册前创建一次，回调里只更新 uniform 并发出绘制命令：

```python
import bpy
import gpu
from gpu_extras.batch import batch_for_shader

_handle = None
_coords = ((-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0))
_shader = gpu.shader.from_builtin('POLYLINE_UNIFORM_COLOR')
_batch = batch_for_shader(_shader, 'LINES', {"pos": _coords})


def draw_axes():
    _shader.uniform_float("viewportSize", gpu.state.viewport_get()[2:])
    _shader.uniform_float("lineWidth", 2.0)
    _shader.uniform_float("color", (1.0, 0.35, 0.1, 1.0))
    _batch.draw(_shader)


def register():
    global _handle
    if _handle is None:
        _handle = bpy.types.SpaceView3D.draw_handler_add(
            draw_axes, (), 'WINDOW', 'POST_VIEW'
        )


def unregister():
    global _handle
    if _handle is not None:
        bpy.types.SpaceView3D.draw_handler_remove(_handle, 'WINDOW')
        _handle = None
```

`draw_handler_remove()` 必须收到注册时返回的句柄和同一个 `region_type`；已经移除的句柄
再次传入会报错。实现会把有效句柄包装成 capsule，并在移除后标记为无效
（#src("source/blender/python/intern/bpy_rna_callback.cc:385")）。因此句柄与快捷键、定时器、
消息总线 owner 一样，都是插件生命周期资源，必须在 `unregister()` 里对称清理。

#pitfall[
  绘制回调不是动画循环：它只在区域重绘时运行。模态操作符中数据变化后可调用
  `context.area.tag_redraw()`；若后台事件改变了叠加层状态，则应找到相应的 3D 视图区域并
  请求重绘。回调里不要改场景数据、调用操作符或分配大量对象，它的职责只应是“读取状态并画”。
]

#note[
  如果回调改变了 `gpu.state`（例如深度测试、混合或点大小），退出前要恢复到预期状态，
  否则后续 Blender 绘制可能继承你的设置。本例只设置当前 shader 的 uniform，
  没有改全局 GPU 状态。官方 `gpu` 示例位于
  #src("doc/python_api/examples/gpu.3.py:13")。
]

#exercise[
  *练习 5.6* 把 §5.5 的测量操作符改成真正的视口工具：

  1. `invoke()` 中以 `POST_PIXEL` 注册 draw handler；
  2. 每次 `MOUSEMOVE` 保存起点和终点，并调用 `context.area.tag_redraw()`；
  3. 用 `batch_for_shader()` 画线，再用 `blf` 在终点旁显示像素距离；
  4. `FINISHED`、`CANCELLED` 和异常清理路径都移除同一个句柄；
  5. 连续启用、禁用插件三次，确认叠加层没有重复出现。
]

== 5.7 撤销 / 重做与 `bpy.ops` 的配合

=== 5.7.1 为什么这一节必须单独讲

前面所有小节里，Python 脚本都在直接改数据：`obj.location = (1, 2, 3)`、
`mesh.from_pydata(...)`、`collection.objects.link(ob)`。这些操作
*完全不产生撤销步骤*。用户按下 `Ctrl+Z`，什么也不会发生。

撤销是一个显式契约：只有*操作符*才能压入撤销步骤，而且必须主动声明。
这一小节把这个契约讲清楚，因为它是「脚本好用」与「脚本让用户抓狂」的分界线。

=== 5.7.2 一条完整的因果链

先给出结论，再拆开验证。当你执行一个带 `{'UNDO'}` 的操作符时，
下面这条链被走完：

1. `bl_options` 里的 `'UNDO'` 在注册时被写进 `wmOperatorType.flag`，
   对应的 C 侧旗标是 `OPTYPE_UNDO`
   （#src("source/blender/windowmanager/WM_types.hh:186")）。
   映射关系在 RNA 里：#src("source/blender/makesrna/intern/rna_wm.cc:2297")
   把 `bl_options` 的 sdna 指向 `type->flag`。
2. 执行时，`wm_operator_exec` 检测到 `OPTYPE_UNDO`，
   于是先把「撤销深度」加一，再调用你的 `exec`：

```cpp
// source/blender/windowmanager/intern/wm_event_system.cc:1395（节选）
if (op->type->exec) {
  if (op->type->flag & OPTYPE_UNDO) {
    wm->op_undo_depth++;
  }

  retval = op->type->exec(C, op);
  OPERATOR_RETVAL_CHECK(retval);

  if (op->type->flag & OPTYPE_UNDO && CTX_wm_manager(C) == wm) {
    wm->op_undo_depth--;
  }
}
```

3. 你的 `exec` 若返回 `{'FINISHED'}`，`wm_operator_exec` 调用
   `wm_operator_finished`
   （#src("source/blender/windowmanager/intern/wm_event_system.cc:1419")）。
4. `wm_operator_finished` 判断 `wm->op_undo_depth == 0` 之后，
   按旗标分派到三种压栈方式：

```cpp
// source/blender/windowmanager/intern/wm_event_system.cc:1306（节选）
if (wm->op_undo_depth == 0) {
  if (op->type->flag & OPTYPE_UNDO) {
    ED_undo_push_op(C, op);
    ...
  }
  else if (op->type->flag & OPTYPE_UNDO_GROUPED) {
    ED_undo_grouped_push_op(C, op);
    ...
  }
  else if (has_undo_step) {
    ...
  }
}
```

5. `ED_undo_push_op` 只用操作符的*名字*作为撤销步骤名
   （#src("source/blender/editors/undo/ed_undo.cc:370")）：

```cpp
// source/blender/editors/undo/ed_undo.cc:370（节选）
void ED_undo_push_op(bContext *C, wmOperator *op)
{
  /* in future, get undo string info? */
  ED_undo_push(C, op->type->name);
}
```

这条链解释了四件事，每一件都是实战中会踩到的：

#figure(
  kind: table,
  table(
    columns: (2.3fr, 3.3fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*现象*], [*原因（对应上面第几步）*]),
    [`return {'CANCELLED'}` 之后没有撤销步骤],
    [第 3 步只在 `retval & OPERATOR_FINISHED` 时才调用 `wm_operator_finished`。这也正是源码里 `CANCELLED` 的描述：*不应*压入撤销记录],
    [Python 操作符里再调 `bpy.ops.xxx()`，只产生一条撤销记录],
    [第 2 步把 `op_undo_depth` 加一，嵌套调用的 `wm_operator_finished` 看到它不是 0 就跳过。源码注释写明了这是有意为之：「python operators that call C operators」],
    [撤销面板里显示的名字是操作符的内部名字],
    [第 5 步用的是 `op->type->name`，不是 `bl_label`],
    [脚本直接改 `bpy.data` 无法撤销],
    [整条链只在操作符执行路径上，改数据不经过它],
  ),
  caption: [撤销行为与源码位置的对应关系],
) <tbl-undo-behaviour>

=== 5.7.3 `UNDO_GROUPED` 与 `bl_undo_group`

`{'UNDO_GROUPED'}`（C 侧 `OPTYPE_UNDO_GROUPED`，
#src("source/blender/windowmanager/WM_types.hh:211")，注释是
「Special type of undo which doesn't store itself multiple times」）
解决的是「拖动滑块时不该产生 200 条撤销记录」。

它的实现思路很简单——*如果这次的名字和当前活动撤销步骤的名字相同，
先把当前步骤清掉，再压一条*：

```cpp
// source/blender/editors/undo/ed_undo.cc:341（节选）
void ED_undo_grouped_push(bContext *C, const char *str)
{
  ...
  const UndoStep *us = ustack->step_active;
  if (us && STREQ(str, us->name)) {
    BKE_undosys_stack_clear_active(ustack);
  }

  /* push as usual */
  ED_undo_push(C, str);
}
```

而名字从哪来？就是 `bl_undo_group`：

```cpp
// source/blender/editors/undo/ed_undo.cc:376（节选）
void ED_undo_grouped_push_op(bContext *C, wmOperator *op)
{
  if (op->type->undo_group[0] != '\0') {
    ED_undo_grouped_push(C, op->type->undo_group);
  }
  else {
    ED_undo_grouped_push(C, op->type->name);
  }
}
```

`bl_undo_group` 在 RNA 里映射到 `type->undo_group`
（#src("source/blender/makesrna/intern/rna_wm.cc:2287")）。

```python
class T_OT_probe_slider(bpy.types.Operator):
    bl_idname = "t.probe_slider"
    bl_label = "滑动"
    bl_options = {'REGISTER', 'UNDO_GROUPED'}
    bl_undo_group = "t_probe_slider"   # 同名则合并为一条撤销记录
    value: bpy.props.FloatProperty(default=0.0)
```

#note[
  注意 `UNDO_GROUPED` 与 `UNDO` 是*两个不同的旗标*，不要同时写。
  `wm_operator_finished` 的判断是 `if ... OPTYPE_UNDO { } else if ...
  OPTYPE_UNDO_GROUPED { }`，先命中 `UNDO` 就永远不会走分组分支。
]

=== 5.7.4 与重做面板的配合

重做面板（Redo 面板，默认快捷键 `F9`）之所以能「用同一组参数再执行一遍」，
靠的是操作符执行完后被登记进窗口管理器的操作符栈。
判断条件是 `OPTYPE_REGISTER | OPTYPE_UNDO` 两者之一
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1270")）：

```cpp
// source/blender/windowmanager/intern/wm_event_system.cc:1274（节选）
return wm && (wm->op_undo_depth == 0) && (ot->flag & (OPTYPE_REGISTER | OPTYPE_UNDO));
```

重放本身由 `WM_operator_repeat` 完成
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1464")），
它会调用 `wm_operator_exec(C, op, repeat=true, store=true)` ——
注意 `store=true`，这一步会把当前属性存下来
（`WM_operator_last_properties_store`，
#src("source/blender/windowmanager/intern/wm_event_system.cc:1300")）。
Python 侧的 `Operator.is_repeat()`
（RNA 绑定 #src("source/blender/makesrna/intern/rna_wm_api.cc:1253")）
就是用来在 `execute` 里问「我这是被重复执行吗？」。
文件导入类操作符通常会这样用：

```python
def execute(self, context):
    if self.is_repeat():
        # 重做面板触发的重复执行：不要重新读文件，只更新参数
        self.apply_settings(context)
    else:
        self.do_full_import(context)
    return {'FINISHED'}
```

#pitfall[
  想让重做面板正常工作，`bl_options` 里必须有 `REGISTER`。
  如果只有 `UNDO`，撤销步骤会被压，但操作符不会被登记，
  重做面板就指向了上一个注册过的操作符。
  源码里在 `has_undo_step` 那个分支的注释解释了这一点
  （#src("source/blender/windowmanager/intern/wm_event_system.cc:1319")，
  引用了 issue #101743）：这种情况下的「重做」会*撤掉*刚做的操作。
  结论：*修改数据用 `{'REGISTER', 'UNDO'}`，不要只用 `'UNDO'`。*
]

=== 5.7.5 在脚本里手动压撤销步骤

从脚本（不是操作符）改数据时，唯一干净的补救方式是显式压一条：

```python
import bpy

obj = bpy.context.object
obj.location.x += 1.0

# 手动压一条撤销步骤。message 会显示在撤销历史里。
bpy.ops.ed.undo_push(message="移动物体")
```

`ED_OT_undo_push` 的定义在 #src("source/blender/editors/undo/ed_undo.cc:590")：

```cpp
// source/blender/editors/undo/ed_undo.cc:590（节选）
void ED_OT_undo_push(wmOperatorType *ot)
{
  ot->name = "Undo Push";
  ot->description = "Add an undo state (internal use only)";
  ot->idname = "ED_OT_undo_push";

  ot->exec = ed_undo_push_exec;
  /* Unlike others undo operators this initializes undo stack. */
  ot->poll = ED_operator_screenactive;

  ot->flag = OPTYPE_INTERNAL;

  RNA_def_string(ot->srna, "message", "Add an undo step *function may be moved*",
                 BKE_UNDO_STR_MAX, "Undo Message", "");
}
```

#warn[
  三个必须知道的限制：

  1. 它带 `OPTYPE_INTERNAL`，所以*不会*出现在搜索菜单里——它是给脚本用的。
  2. `poll` 是 `ED_operator_screenactive`，即*必须有活跃的屏幕*。
     在 `blender --background` 下调用会失败。
  3. 撤销步骤必须在数据*已经*被修改之前建立基线。
     正确顺序是先 `undo_push`、再改数据；先改再 push 会让这一条
     撤销步骤里已经含着你的改动，`Ctrl+Z` 回不去。
]

#summary[
  5.7 的规则可以压缩成一条：
  *凡是通过脚本修改 `bpy.data` 的地方，都要么包进一个
  `bl_options = {'REGISTER', 'UNDO'}` 的操作符，要么显式
  `bpy.ops.ed.undo_push()`。* 这不是可选项——没有它，
  用户的下一次 `Ctrl+Z` 会撤掉你意想不到的东西。
]

#exercise[
  *练习 5.7* 用一个实验把本节所有结论验证一遍：

  1. 写操作符 `t.undo_ok`，`bl_options = {'REGISTER', 'UNDO'}`，
     把选中物体的 X 坐标加 1；执行三次，然后在撤销历史里数步骤数；
  2. 写操作符 `t.undo_bad`，`bl_options = {'UNDO'}`（故意漏掉 `REGISTER`），
     做同样的事，观察重做面板（`F9`）指向了谁；
  3. 写操作符 `t.undo_grouped`，`bl_options = {'REGISTER', 'UNDO_GROUPED'}`，
     再写一个带 `update` 回调的 `FloatProperty`，让回调里调用
     `bpy.ops.t.undo_grouped(value=self.value)`；拖动滑块，
     检查撤销历史是否只有一条；
  4. 在脚本编辑器里直接 `bpy.context.object.location.x += 5`，
     再按 `Ctrl+Z`，确认什么也没发生；然后加上
     `bpy.ops.ed.undo_push(message="脚本移动")` 重做一遍；
  5. 把 `t.undo_ok` 的 `execute` 改成 `return {'CANCELLED'}`，
     确认不再产生撤销步骤。
]

