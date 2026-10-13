#import "../common.typ": *
#import "../figures/addon-lifecycle.typ": fig-addon-lifecycle

= 第 4 章 Addon 结构与生命周期

第 3 章讲的是"可以调用什么"。本章讲的是"如何把自己的代码接入 Blender"。

一个 addon 从磁盘上的一个 `.py` 文件，到用户按下"启用"，中间经过了好几个环节：
*扫描*（Blender 怎么发现它）、*读取元数据*（`bl_info` 从哪来）、*注册*（你的
`register()` 被谁调用）、*注销*（用户禁用时发生了什么）。这几个环节的顺序和边界
都有明确的源码依据。理解这些边界，才能避免插件只在开发机器上可用、换到其他环境后
无法被发现或加载的问题。

本章还会覆盖 addon 的两种分发形态：传统的 `.py`/压缩包安装，以及 Blender 4.2 之后
的*扩展平台*（extensions）。最后是调试与测试。

== 4.1 `bl_info`、`register()` / `unregister()`

先把整体流程摆出来。@fig-addon-lifecycle 是一条 addon 从被扫描到被禁用的完整路径，
右边那一栏是这一步"到底做了什么"的一句话概括；本节余下的内容就是逐格拆开它。

#figure(fig-addon-lifecycle(), caption: [
  Python addon 生命周期。左栏是阶段，中间等宽小字是驱动这一阶段的代码入口，
  右栏是该阶段的一句话说明。注意第 ⑥ 与第 ⑦ 步的差别：`disable()` 会调用
  `unregister()`，但*不会*把模块从 `sys.modules` 里删掉，所以"改完代码直接
  再启用"拿到的仍是旧模块对象。图中每一条断言都能在
  #src("scripts/modules/addon_utils.py") 里找到对应行，逐条出处见本节正文。
  左侧蓝色虚线是"再启用"的回路：它直接回到第 ④ 步 `register()`，第 ③ 步的模块
  导入不会重跑。
]) <fig-addon-lifecycle>

=== 4.1.1 bl_info 的约束与注册函数的配对

每个传统 addon 的入口文件（通常是 `__init__.py`）顶部都有一个 `bl_info` 字典：

```python
# scripts/addons_core/io_anim_bvh/__init__.py:5（节选）
bl_info = {
    "name": "BioVision Motion Capture (BVH) format",
    # This is now displayed as the maintainer, so show the foundation.
    # "author": "Campbell Barton", # Original Author
    "author": "Blender Foundation",
    "version": (1, 0, 1),
    "blender": (2, 81, 6),
    "location": "File > Import-Export",
    "description": "Import-Export BVH from armature objects",
    "warning": "",
    "doc_url": "{BLENDER_MANUAL_URL}/addons/import_export/anim_bvh.html",
    "support": 'OFFICIAL',
    "category": "Import-Export",
}
```

而 `bl_info` 的*完整字段表*（含默认值）就在 #src("scripts/modules/addon_utils.py:692")：

```python
# scripts/modules/addon_utils.py:692（节选）
def _bl_info_basis():
    return {
        "name": "",
        "author": "",
        "version": (),
        "blender": (),
        "location": "",
        "description": "",
        "doc_url": "",
        "support": 'COMMUNITY',
        "category": "",
        "warning": "",
        "show_expanded": False,
    }
```

注意 `support` 的默认值是 `'COMMUNITY'`，`show_expanded` 是一个 UI 折叠状态。
官方 addon 里还常见 `tracker_url`（例如
#src("scripts/addons_core/io_scene_gltf2/__init__.py:16")），
它不在基表里 —— 也就是说*未知键是被容忍的*，但也不会被 UI 使用。

*为什么 `bl_info` 必须是字面量、必须在顶部*

这是 addon 加载性能的关键，也是初学者最容易违反的约束。

Blender 在启动时要扫描所有 addon 目录，并把每个 addon 的名字、描述、分类填进
偏好设置的列表。如果为每个 addon 都执行一遍完整的 Python 导入，启动会变得很慢。
所以 `_fake_module()` 采取了一条捷径（#src("scripts/modules/addon_utils.py:126")）：

```python
# scripts/modules/addon_utils.py:145（节选）
    with file_mod:
        if speedy:
            lines = []
            line_iter = iter(file_mod)
            line = ""
            while not line.startswith("bl_info"):
                try:
                    line = line_iter.readline()
                except UnicodeDecodeError as ex:
                    if not error_encoding:
                        error_encoding = True
                        print("Error reading file as UTF-8:", mod_path, ex)
                    return None

                if len(line) == 0:
                    break
            while line.rstrip():
                lines.append(line)
                try:
                    line = line_iter.readline()
                except UnicodeDecodeError as ex:
                    ...
            data = "".join(lines)

        else:
            data = file_mod.read()
```

它*只读到 `bl_info` 那一行为止*，然后把这一段交给 `ast.parse()` 解析，
再用 `ast.literal_eval()` 取出值（#src("scripts/modules/addon_utils.py:197")）：

```python
# scripts/modules/addon_utils.py:194（节选）
    if body_info:
        try:
            mod = ModuleType(mod_name)
            mod.bl_info = ast.literal_eval(body.value)
            mod.__file__ = mod_path
            mod.__time__ = os.path.getmtime(mod_path)
        except Exception:
            print("AST error parsing bl_info for:", repr(mod_path))
            import traceback
            traceback.print_exc()
            return None
```

三条结论直接从这段代码推出来：

- *`bl_info` 必须是字面量。* `ast.literal_eval()` 只接受字符串、数字、
  元组、列表、字典、布尔与 `None`。写成 `"version": get_version()` 或
  `"blender": bpy.app.version` 会解析失败，addon 直接不被识别。
- *`bl_info` 必须在第一个非空语句块的位置"尽可能靠前"。* 扫描逻辑是
  "逐行读到以 `bl_info` 开头的那一行，然后继续读到空行"。任何在 `bl_info` 之前
  的代码，只要含有以 `bl_info` 开头的行就会干扰它；而在 `bl_info` 之后的那段
  代码必须能作为独立的表达式被解析。
- *字典必须用 `{}` 字面量，且 `bl_info` 必须出现在文件的前面部分。*
  如果读完整行没找到，`body_info` 就是 `None`，于是打印
  `Warning: add-on missing 'bl_info', this can cause poor performance!`
  （#src("scripts/modules/addon_utils.py:208")）并返回 `None` —— 这个 addon
  在列表里就看不到了。

#pitfall[
  *"我 import 了 `bpy` 再定义 `bl_info`"* —— 可以工作，但你牺牲了整个
  快速路径：`speedy` 分支会一直读到文件末尾才找到 `bl_info` 或者根本找不到。
  把 `bl_info` 放在 `import bpy` 之前，是官方 addon 的一致做法。
]

*`bl_info` 是只读的建议，不是运行时的契约*

`module_bl_info()` 是真正把 `bl_info` 交给 UI 之前的"补齐"步骤
（#src("scripts/modules/addon_utils.py:708")）：

```python
# scripts/modules/addon_utils.py:708（节选）
def module_bl_info(mod, *, info_basis=None):
    if info_basis is None:
        info_basis = _bl_info_basis()

    addon_info = getattr(mod, "bl_info", {})

    # avoid re-initializing
    if "_init" in addon_info:
        return addon_info

    if not addon_info:
        if mod.__name__.startswith(_ext_base_pkg_idname_with_dot):
            addon_info, filepath_toml = _bl_info_from_extension(mod.__name__, mod.__file__)
            ...
        mod.bl_info = addon_info

    for key, value in info_basis.items():
        addon_info.setdefault(key, value)

    if not addon_info["name"]:
        addon_info["name"] = mod.__name__
```

要点有三：缺失字段会被补默认值；`name` 为空时用模块名兜底；
补齐后写入一个 `"_init"` 标记，避免重复处理。

顺带一个实用细节：`author` 字段里的邮箱会被剥掉
（#src("scripts/modules/addon_utils.py:747")）：

```python
# scripts/modules/addon_utils.py:744（节选）
    # Remove the maintainers email while it's not private, showing prominently
    # could cause maintainers to get direct emails from issue tracking systems.
    import re
    if "author" in addon_info:
        addon_info["author"] = re.sub(r"\s*<.*?>", "", addon_info["author"])
```

*`register()` / `unregister()`：必须是一对*

`enable()` 是启用一个 addon 的唯一入口。它的核心段落
（#src("scripts/modules/addon_utils.py:338")）：

```python
# scripts/modules/addon_utils.py:450（节选）
    # Disable the context: using the context at all
    # while loading an addon is really bad, don't do it!
    with RestrictBlend():

        # 1) try import
        try:
            # Use instead of `__import__` so that sub-modules can eventually be supported.
            # This is also documented to be the preferred way to import modules.
            mod = importlib.import_module(module_name)
            ...
        except Exception as ex:
            ...
            return None
        ...
        # 2) Try register collected modules.
        # Removed register_module, addons need to handle their own registration now.

        # Core add-ons are unconditionally enabled and don't support being filtered out.
        use_owner = is_extension or (module_name not in _addons_hidden_core)

        from _bpy import _bl_owner_id_get, _bl_owner_id_set
        owner_id_prev = _bl_owner_id_get()
        _bl_owner_id_set(module_name if use_owner else "")

        # 3) Try run the modules register function.
        try:
            mod.register()
        except Exception as ex:
            print("Exception in module register():", (mod_file or module_name))
            handle_error(ex)
            del sys.modules[module_name]
            if default_set:
                _addon_remove(module_name)
            if is_extension and not refresh_handled:
                extensions_refresh(handle_error=handle_error)
            return None
        finally:
            _bl_owner_id_set(owner_id_prev)

    # * OK loaded successfully! *
    mod.__addon_enabled__ = True
    mod.__addon_persistent__ = persistent
```

这一段里有四个必须记住的事实。

*事实一：加载过程中 context 是被禁用的。* 那行注释写得很直白：
`using the context at all while loading an addon is really bad, don't do it!`
实现方式是 `_bpy_restrict_state.RestrictBlend`。所以在 `register()` 里
*不要* `bpy.context.preferences.addons[...]` 之外的 context 访问 ——
读 `bpy.context.scene`、`bpy.context.object` 都属于"不该做的事"。
第 3 章 3.4 节说"操作符里要用传入的 context"，这里是同一条原则在启动期的延伸。

*事实二：注册失败时，模块会从 `sys.modules` 里被删掉
（`del sys.modules[module_name]`），并被标记为未启用。*
这意味着用户点第二次"启用"会走一遍完整的重新导入，而不是"接着上次的状态继续"。
不要依赖模块级的全局变量在失败的注册之后还活着。

*事实三：`register()` 里的异常会被完整 traceback 打印，然后被吞掉。*
用户界面只会看到"启用失败"或者根本没有反应。开发期请从终端看输出，
或者用 `--debug-python`（见 4.4）。

*事实四：`_bl_owner_id_set(module_name)` 划定了这个 addon 的所有权范围。*
它让 Blender 能知道"某个操作符/面板是哪个 addon 注册的"。
核心 addon（`_addons_hidden_core`，见 #src("scripts/modules/addon_utils.py:46")）
传空字符串，因为它们不属于任何用户可禁用的 addon。

`disable()` 是对称的（#src("scripts/modules/addon_utils.py:567")）：

```python
# scripts/modules/addon_utils.py:585（节选）
    mod = sys.modules.get(module_name)

    # Possible this add-on is from a previous session and didn't load a
    # module this time. So even if the module is not found, still disable
    # the add-on in the user preferences.
    if mod and getattr(mod, "__addon_enabled__", False) is not False:
        mod.__addon_enabled__ = False
        mod.__addon_persistent__ = False

        try:
            mod.unregister()
        except Exception as ex:
            mod_path = getattr(mod, "__file__", module_name)
            print("Exception in module unregister():", repr(mod_path))
            del mod_path
            handle_error(ex)
```

注意 `unregister()` 抛出的异常同样被吞掉，只是打印。*用户禁用 addon 之后
界面里残留一个面板，通常就是 `unregister()` 没把 `register()` 做的事做全。*

=== 4.1.2 一个最小但完整的骨架

下面的骨架和官方 addon 的结构一致，可以直接作为起点。它演示了
"类列表 + 循环注册"这一官方惯用法。#example-file("ch04/my_addon")

```python
# 完整可运行：最小 addon 骨架（保存为 my_addon/__init__.py）
bl_info = {
    "name": "My Add-on",
    "author": "You",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "View3D > Sidebar > My Tab",
    "description": "A minimal but complete add-on",
    "warning": "",
    "doc_url": "",
    "support": 'COMMUNITY',
    "category": "Object",
}

import bpy


class MYADDON_OT_hello(bpy.types.Operator):
    """Say hello"""
    bl_idname = "my_addon.hello"
    bl_label = "Hello"
    # 这个操作符不修改数据，因此不应把空步骤压入撤销栈。
    bl_options = {'REGISTER'}

    def execute(self, context):
        self.report({'INFO'}, "hello from my_addon")
        return {'FINISHED'}


class MYADDON_PT_panel(bpy.types.Panel):
    bl_label = "My Add-on"
    bl_idname = "MYADDON_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "My Tab"

    def draw(self, context):
        self.layout.operator(MYADDON_OT_hello.bl_idname)


classes = (
    MYADDON_OT_hello,
    MYADDON_PT_panel,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
```

顺带把上面那个 `bl_options = {'REGISTER', 'UNDO'}` 的来龙去脉说清楚，
因为它是"Python 声明的枚举 → C 位标志"这一层映射的最好例子。

RNA 侧的定义在 #src("source/blender/makesrna/intern/rna_wm.cc:2297")：

```cpp
// source/blender/makesrna/intern/rna_wm.cc:2297（节选）
  prop = RNA_def_property(srna, "bl_options", PROP_ENUM, PROP_NONE);
  RNA_def_property_enum_sdna(prop, nullptr, "type->flag");
  RNA_def_property_flag(prop, PROP_REGISTER_OPTIONAL | PROP_ENUM_FLAG);
  RNA_def_property_enum_items(prop, rna_enum_operator_type_flag_items);
  RNA_def_property_ui_text(prop, "Options", "Options for this operator type");
```

两个细节值得注意：`RNA_def_property_enum_sdna(prop, nullptr, "type->flag")`
说明这个"枚举"其实*直接读写* `wmOperatorType::flag` 这个位标志字段；
而 `PROP_ENUM_FLAG` 表示它是可组合的标志集合（所以 Python 里写成 `set`）。
对应的 C 侧标志就是 #src("source/blender/windowmanager/WM_types.hh:184") 的枚举：

```cpp
// source/blender/windowmanager/WM_types.hh:162（节选）
/** #wmOperatorType.flag */
enum {
  /**
   * Register operators in stack after finishing (needed for redo).
   ...
   */
  OPTYPE_REGISTER = (1 << 0),
  /** Do an undo push after the operator runs. */
  OPTYPE_UNDO = (1 << 1),
```

于是 `{'REGISTER', 'UNDO'}` 与 `OPTYPE_REGISTER | OPTYPE_UNDO` 是同一个东西的
两种拼法。这张映射表的原文就在 #src("source/blender/makesrna/intern/rna_wm.cc:550")：

```cpp
// source/blender/makesrna/intern/rna_wm.cc:550（节选）
const EnumPropertyItem rna_enum_operator_type_flag_items[] = {
    {OPTYPE_REGISTER,
     "REGISTER",
     0,
     "Register",
     "Display in the info window and support the redo toolbar panel"},
    {OPTYPE_UNDO,
     "UNDO",
     0,
     "Undo",
     "Push an undo event when the operator returns `FINISHED` (needed for operator redo, "
     "mandatory if the operator modifies Blender data)"},
    {OPTYPE_UNDO_GROUPED,
     "UNDO_GROUPED",
     0,
     "Grouped Undo",
     "Push a single undo event for repeated instances of this operator"},
```

每一项都是"位标志 → Python 字符串"的一一对应，所以 `UNDO_GROUPED` 的 C 侧
名字是 `OPTYPE_UNDO_GROUPED`（#src("source/blender/windowmanager/WM_types.hh:211")）。
这也是第 3 章那条"Python 属性名由 RNA 标识符决定"的又一个实例。

`unregister()` 用 `reversed(classes)` 不是洁癖：如果两个类之间有依赖
（例如 `Panel` 引用了 `Operator` 的 `bl_idname`），反序注销才安全。
`bpy.utils.register_classes_factory()`（#src("scripts/modules/bpy/utils/__init__.py:1001")）
就是这个模式的标准实现：

```python
# scripts/modules/bpy/utils/__init__.py:1001（节选）
def register_classes_factory(classes):
    """
    Utility function to create register and unregister functions
    which simply registers and unregisters a sequence of classes.

    :param classes: Sequence of classes to register and unregister.
    :type classes: Sequence[type]
    :return: register and unregister functions.
    :rtype: tuple[Callable[[], None], Callable[[], None]]
    """
    def register():
        for cls in classes:
            register_class(cls)

    def unregister():
        for cls in reversed(classes):
            unregister_class(cls)

    return register, unregister
```

于是上面那两段 `register` / `unregister` 可以压缩成一行：

```python
# 示意：等价写法
register, unregister = bpy.utils.register_classes_factory(classes)
```

=== 4.1.3 启用、禁用、移除是三件不同的事

用户界面上有三个容易混淆的动作：

#figure(
  kind: table,
  table(
    columns: (auto, 1fr, 1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*动作*], [*发生了什么*], [*对 addon 代码的含义*]),
    [启用],
    [import 模块 → 调用 `register()` → 写入 `preferences.addons`],
    [`register()` 必须幂等且完整；不要依赖磁盘状态],
    [禁用],
    [调用 `unregister()` → 从 `preferences.addons` 移除 → 保留模块缓存],
    [`unregister()` 必须撤销 `register()` 的*全部*副作用],
    [移除],
    [删除磁盘文件（在禁用之后）],
    [下次启动时模块不再被扫描到；残留的 `.pyc` 会导致怪问题],
    [重载脚本],
    [`bpy.utils.load_scripts(reload_scripts=True)` → 重新加载与注销全部脚本],
    [`__init__.py` 需要有"重新导入子模块"的自保逻辑],
  ),
  caption: [启用 / 禁用 / 移除 / 重载脚本四者的差别。注意它们由不同代码路径驱动。],
) <tbl-addon-actions>

"重载脚本"的调用链可以在源码里跟到底：`SCRIPT_OT_reload`
（#src("source/blender/editors/space_script/script_edit.cc:139")）会调
`bpy.utils.load_scripts(reload_scripts=True)`
（#src("source/blender/editors/space_script/script_edit.cc:118")），
而 `load_scripts()` 在末尾调用 `load_scripts_extensions()`
（#src("scripts/modules/bpy/utils/__init__.py:343")），
后者在非首次加载时走 `_addon_utils.reset_all(reload_scripts=reload_scripts)`
（#src("scripts/modules/bpy/utils/__init__.py:400")）。

`reset_all()` 会逐个比较"偏好设置里说该启用"和"当前实际加载状态"
（#src("scripts/modules/addon_utils.py:638")）：

```python
# scripts/modules/addon_utils.py:638（节选）
        for mod_name, _mod_path in _bpy.path.module_names(path, package=pkg_id):
            is_enabled, is_loaded = check(mod_name)

            # first check if reload is needed before changing state.
            if reload_scripts:
                import importlib
                mod = sys.modules.get(mod_name)
                if mod:
                    importlib.reload(mod)

            if is_enabled == is_loaded:
                pass
            elif is_enabled:
                enable(mod_name, refresh_handled=True)
            elif is_loaded:
                print("\taddon_utils.reset_all unloading", mod_name)
                disable(mod_name)
```

而 `check()` 返回的是一个二元组（#src("scripts/modules/addon_utils.py:277")）：
`(loaded_default, loaded_state)` —— 前者是"偏好设置希望它启用吗"，
后者是"它现在真的启用了吗"。这也是唯一能在代码里正确判断 addon 状态的接口：
#example-file("ch04/addon_status.py")

```python
# 完整可运行：正确判断 addon 状态
import addon_utils

loaded_default, loaded_state = addon_utils.check("io_scene_gltf2")
print("偏好设置里启用:", loaded_default, " 当前已加载:", loaded_state)
```

#pitfall[
  *不要用 `module in sys.modules` 判断 addon 是否启用。* 模块可能在
  `sys.modules` 里而处于未启用状态（注册失败时会 `del`，但重新导入后
  注销失败时不会）。`addon_utils.check()` 存在的原因就是这个。
  同理，自己维护一个 `IS_REGISTERED` 全局变量也不可靠 —— 脚本重载会重置它。
]

=== 4.1.4 多文件 addon 的重载自保

多文件 addon 在"重载脚本"时有一个经典问题：`importlib.reload()` 只重载
`__init__.py`，子模块仍是旧的。官方 addon 的标准解法是在 `__init__.py` 顶部
检查 `locals()`：

```python
# scripts/addons_core/io_anim_bvh/__init__.py:20（节选）
if "bpy" in locals():
    import importlib
    if "import_bvh" in locals():
        importlib.reload(import_bvh)
    if "export_bvh" in locals():
        importlib.reload(export_bvh)

import bpy
```

`io_scene_gltf2` 把这件事做得更彻底 —— 它递归重载整个包
（#src("scripts/addons_core/io_scene_gltf2/__init__.py:30")）：

```python
# scripts/addons_core/io_scene_gltf2/__init__.py:30（节选）
def reload_package(module_dict_main):
    import importlib
    from pathlib import Path

    def reload_package_recursive(current_dir, module_dict):
        for path in current_dir.iterdir():
            if "__init__" in str(path) or path.stem not in module_dict:
                continue

            if path.is_file() and path.suffix == ".py":
                importlib.reload(module_dict[path.stem])
            elif path.is_dir():
                reload_package_recursive(path, module_dict[path.stem].__dict__)

    reload_package_recursive(Path(__file__).parent, module_dict_main)


if "bpy" in locals():
    reload_package(locals())
```

#tip[
  "`if "bpy" in locals()`"这个判断的含义是"这个文件之前被导入过" ——
  因为第一次导入时 `bpy` 还没被绑定，第二次（reload）时它已经在
  `locals()` 里了。这是 Blender 生态里一个约定俗成的惯用法，
  不用去别处找"官方做法"。
]

=== 4.1.5 常见问题

#pitfall[
  *易错点一：`register()` 里做耗时工作。* 用户每次启用、每次重载脚本、
  每次切换应用模板都会调用它。下载文件、扫描大目录、编译 shader
  这类事情应该延后到首次真正需要时（惰性初始化）或用 `bpy.app.timers` 异步做。
]

#pitfall[
  *易错点二：只注册不注销。* 在 `register()` 里 `bpy.types.TOPBAR_MT_file_import.append(...)`，
  却在 `unregister()` 里忘了对应的 `remove(...)`。后果是菜单项重复出现，
  而且重复次数等于"启用-禁用"的次数。规则很简单：*`register()` 里的每一行，
  `unregister()` 里都要有一行反向操作，顺序相反。*
]

#pitfall[
  *易错点三：在 `register()` 里写 `bpy.types.Scene.my_prop = bpy.props.IntProperty()`。*
  这确实能工作，但对应的注销必须手动做：

  ```python
  # 示意：给已有类型追加属性时的成对写法
  def register():
      bpy.types.Scene.my_prop = bpy.props.IntProperty(default=0)

  def unregister():
      del bpy.types.Scene.my_prop
  ```

  忘了 `del` 会让 `register()` 报
  `AttributeError: bpy_struct: attribute "my_prop" from "Scene" is read-only`。
  另外注意：*动态追加的属性无法在 `bl_rna` 之外被序列化*，
  重启后不会自动回来，它的初始值只在 `register()` 运行后存在。
]

== 4.2 偏好设置、多文件组织、资源打包

*`AddonPreferences`：addon 的持久化配置*

想在"编辑 → 偏好设置 → 插件"里给自己的 addon 一个配置面板，需要一个
`bpy.types.AddonPreferences` 子类。官方 addon 的例子
（#src("scripts/addons_core/io_scene_gltf2/__init__.py:2206")）：

```python
# scripts/addons_core/io_scene_gltf2/__init__.py:2206（节选）
class GLTF_AddonPreferences(bpy.types.AddonPreferences):
    bl_idname = __package__

    settings_node_ui: bpy.props.BoolProperty(
        default=False,
        description="Displays glTF Material Output node in Shader Editor (Menu Add > Output)"
    )

    KHR_materials_variants_ui: bpy.props.BoolProperty(
        default=False,
        description="Displays glTF UI to manage material variants",
        update=gltf_variant_ui_update
    )

    gltfpack_path_ui: bpy.props.StringProperty(
        default="",
        name="glTFpack file path",
        description="Path to gltfpack binary",
        subtype='FILE_PATH'
    )

    def draw(self, context):
        layout = self.layout
        row = layout.row()
        row.prop(self, "settings_node_ui", text="Shader Editor Add-ons")
        row.prop(self, "KHR_materials_variants_ui", text="Material Variants")
        row = layout.row()
        row.prop(self, "gltfpack_path_ui", text="Path to gltfpack")
```

*`bl_idname` 是这里唯一有硬性约束的字段。* RNA 侧把它定义为注册属性
（#src("source/blender/makesrna/intern/rna_userdef.cc:4787")）：

```cpp
// source/blender/makesrna/intern/rna_userdef.cc:4785（节选）
  /* registration */
  RNA_define_verify_sdna(false);
  prop = RNA_def_property(srna, "bl_idname", PROP_STRING, PROP_NONE);
  RNA_def_property_string_sdna(prop, nullptr, "module");
  RNA_def_property_flag(prop, PROP_REGISTER);
  RNA_define_verify_sdna(true);
```

`PROP_REGISTER`（没有 `PROP_REGISTER_OPTIONAL`）意味着*不提供它就会注册失败*。
校验发生在 `bpy_class_validate_recursive()`（#src("source/blender/python/intern/bpy_rna.cc:9701")）：

```cpp
// source/blender/python/intern/bpy_rna.cc:9701（节选）
    if (!(flag & PROP_REGISTER)) {
      continue;
    }

    const char *identifier = RNA_property_identifier(prop);
    PyObject *item = nullptr;
    switch (PyObject_GetOptionalAttrString(py_class, identifier, &item)) {
```

失败时报出的错误是 `expected bpy.types.AddonPreferences, X class to have an "bl_idname" attribute`
（#src("source/blender/python/intern/bpy_rna.cc:9757")）。

不过源码里有一个便利机制（#src("source/blender/python/intern/bpy_rna.cc:9690")）：

```cpp
// source/blender/python/intern/bpy_rna.cc:9686（节选）
  /* Allow Python `__name__` to be used for `bl_idname` for convenience. */
  struct {
    const char *rna_attr;
    PyObject *py_attr;
  } bpy_property_substitutions[] = {
      {"bl_idname", bpy_intern_str___name__},
      {"bl_description", bpy_intern_str___doc__},
  };
```

也就是说 `bl_idname` 会回退到类的 `__name__`。但*不要依赖这个回退* ——
`bl_idname` 必须等于 addon 的模块名，而类名几乎不可能等于模块名。
显式写 `bl_idname = __package__` 是唯一正确的做法。

`bl_idname` 的长度还有一个硬上限：#src("source/blender/blenkernel/BKE_addon.h:19")
里 `bAddonPrefType::idname` 是 `char idname[128]`，
而 `rna_AddonPref_register()` 会显式检查
（#src("source/blender/makesrna/intern/rna_userdef.cc:1310")）：

```cpp
// source/blender/makesrna/intern/rna_userdef.cc:1310（节选）
  if (strlen(identifier) >= sizeof(dummy_apt.idname)) {
    BKE_reportf(reports,
                RPT_ERROR,
                "%s '%s' is too long, maximum length is %d",
                error_prefix,
                identifier,
                int(sizeof(dummy_apt.idname)));
    return nullptr;
  }
```

回到 addon 侧的读取方式。运行时拿自己的偏好设置，官方写法是走
`context.preferences.addons`：

```python
# scripts/addons_core/io_scene_gltf2/__init__.py:2288（节选）
    prefs = bpy.context.preferences.addons['io_scene_gltf2'].preferences
    if prefs.KHR_materials_variants_ui is True:
        blender_ui.variant_register()
```

Rigify 封装了一个更稳的访问器（#src("scripts/addons_core/rigify/__init__.py:202")）：

```python
# scripts/addons_core/rigify/__init__.py:197（节选）
class RigifyPreferences(AddonPreferences):
    # this must match the addon name, use '__package__'
    # when defining this in a submodule of a python package.
    bl_idname = __name__

    @staticmethod
    def get_instance(context: bpy.types.Context = None) -> 'RigifyPreferences':
        prefs = (context or bpy.context).preferences.addons[__package__].preferences
        assert isinstance(prefs, RigifyPreferences)
        return prefs
```

#pitfall[
  *在 `register()` 里读自己的偏好设置会失败。* `bpy.context.preferences.addons`
  里的条目是在 `enable()` *开始*时建立的（`_addon_ensure()`，
  #src("scripts/modules/addon_utils.py:321")），但 `preferences` 对象本身
  依赖 context，而 `register()` 运行在 `RestrictBlend` 里
  （#src("scripts/modules/addon_utils.py:452")）。
  需要读取偏好设置的初始化逻辑，请放到 `AddonPreferences` 的 `update` 回调里，
  或者放在操作符/面板第一次被调用时。
]

=== 4.2.1 多文件组织

从单文件 addon 到多文件包，只需要把 `__init__.py` 从"实现"改成"装配"。
Blender 认得的 addon 单位是*顶层包或顶层模块*，内部结构完全自由。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr, 1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*形态*], [*磁盘结构*], [*`bpy.context.preferences.addons` 里的键*]),
    [单文件], [`my_addon.py`], [`"my_addon"`],
    [包], [`my_addon/__init__.py` + 任意子模块], [`"my_addon"`],
    [扩展仓库中的包], [`<repo>/my_addon/` + `blender_manifest.toml`], [`"bl_ext.<repo>.my_addon"`],
  ),
  caption: [addon 的两种传统形态与一种扩展形态。键名即 `enable()` 的参数。],
) <tbl-addon-forms>

官方 `io_anim_bvh` 是最小的多文件例子：
`__init__.py`（注册与 UI）、`import_bvh.py`、`export_bvh.py`。
大的例子是 `rigify`，它有 `operators/`、`rigs/`、`utils/` 等子包。
Rigify 的 `register()` 演示了"先子模块、后类、最后依赖子模块的整体初始化"这个顺序
（#src("scripts/addons_core/rigify/__init__.py:647")）：

```python
# scripts/addons_core/rigify/__init__.py:647（节选）
def register():
    from bpy.utils import register_class

    # Sub-modules.
    ui.register()
    feature_set_list.register()
    metarig_menu.register()
    operators.register()

    # Classes.
    for cls in classes:
        register_class(cls)

    register_usetime_properties()
    register_rna_properties()

    prefs = RigifyPreferences.get_instance()
    prefs.register_feature_sets(True)
    prefs.update_external_rigs()
```

子包的注册可以用 `register_submodule_factory()`
（#src("scripts/modules/bpy/utils/__init__.py:1022")）自动生成：

```python
# 示意：把一组子模块的 register/unregister 串起来
import bpy

from . import operators, ui

register, unregister = bpy.utils.register_submodule_factory(
    __name__, ("operators", "ui"),
)
```

它的实现要点是"按给定顺序注册，注销时反序，并从 `sys.modules` 里删掉"

```python
# scripts/modules/bpy/utils/__init__.py:1051（节选）
    def unregister():
        from sys import modules
        for mod, mod_name in reversed(submodules):
            mod.unregister()
            delattr(module, mod_name)
            del modules[mod.__name__]
        submodules.clear()
```

#warn[
  `register_submodule_factory()` 的 `unregister()` 会 `del modules[mod.__name__]`。
  如果你的子模块在别处被引用了（例如操作符的 `execute` 里 `from .operators import X`），
  这类删除是安全的（下次导入会重新加载），但*不要在模块级*保存跨注销周期
  需要存活的对象。
]

=== 4.2.2 资源打包：图标、数据文件、第三方模块

addon 常常需要带着文件走：工具栏图标、预设、模板、数据表，
甚至第三方 Python 模块。

*图标。* 不要用绝对路径加载 `.png`。正确的做法是把图片作为 Blender 图像数据块
打包进 `.blend`，或者干脆用 Blender 自带的图标名（`layout.operator(..., icon='MESH_CUBE')`）。
需要自定义预览时用 `bpy.utils.previews`（`scripts/modules/bpy/utils/previews.py`）。

*同目录数据文件。* 获取 addon 自己的目录，靠 `__file__`：
#example-file("ch04/addon_paths.py")

```python
# 完整可运行：定位 addon 自身目录与随附文件
import os
import bpy

addon_dir = os.path.dirname(os.path.abspath(__file__))
data_file = os.path.join(addon_dir, "data", "presets.json")
print("addon 目录:", addon_dir)
print("数据文件:", data_file, os.path.exists(data_file))
```

不要硬编码 `~/.config/blender/...` 或 `scripts/addons/` 这类路径。
需要"用户可写"的目录时用 `bpy.utils.user_resource()` 与
`bpy.utils.extension_path_user()`（#src("scripts/modules/bpy/utils/__init__.py:918")、
#src("scripts/modules/bpy/utils/__init__.py:952")）。

*第三方 Python 模块。* 传统 addon 只能靠 `sys.path` 技巧；扩展平台提供了官方方案：
把 `.whl` 放进包里并在清单里声明 `wheels`，Blender 会在启用时安装到
扩展自己的目录（见 4.3）。

*随附的 Python 模块。* `bpy/__init__.py` 在启动时会往 `sys.path` 里追加两个
"addon 共享模块"目录（#src("scripts/modules/bpy/__init__.py:50")）：

```python
# scripts/modules/bpy/__init__.py:50（节选）
    dirpath = join(dirname(dirname(dirname(__file__))), "addons_core", "modules")
    if exists(dirpath):
        sys.path.append(dirpath)

    # Don't check if this exists as it may be created as part of installing add-ons.
    sys.path.append(join(utils.user_resource('SCRIPTS'), "addons", "modules"))
```

也就是说 `<user scripts>/addons/modules/` 下的模块可以被*所有* addon 直接
`import`。这是"多个 addon 共享代码"的官方位置。但它不是扩展平台的一部分，
扩展应该把共享代码放在自己的包里。

=== 4.2.3 国际化：注册插件自己的翻译

界面文字不要根据 `bpy.app.translations.locale` 自己写一串 `if`。常规 addon 只需提供
翻译字典，再把它与插件生命周期绑定。字典的外层键是 locale#footnote[
  locale 是“语言 + 可选地区或书写体系”的标识，例如 `fr_FR`、`pt_BR`；
  Blender 的简体中文标识为 `zh_HANS`，定义见
  #src("scripts/modules/_bl_i18n_utils/settings.py:44")。
]，内层键是 `(context, 原文)`；没有特殊上下文时用 `"*"`：

```python
import bpy

translations = {
    "zh_HANS": {
        ("*", "Inspect Mesh"): "检查网格",
        ("*", "Write Report"): "写入报告",
    },
}


def register():
    # 先注册类和属性，再让 Blender 接管这些界面字符串。
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.app.translations.register(__name__, translations)


def unregister():
    bpy.app.translations.unregister(__name__)
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
```

`register(module_name, translations_dict)` 与 `unregister(module_name)` 的签名和字典形状
由 #src("source/blender/python/intern/bpy_app_translations.cc:299") 定义；官方示例也明确要求
两者分别放进插件的 `register()` 与 `unregister()`
（#src("doc/python_api/examples/bpy.app.translations.0.py:20")）。`module_name` 必须稳定且唯一，
通常直接用 `__name__`。同名重复注册会在
#src("source/blender/python/intern/bpy_app_translations.cc:338") 抛出 `ValueError`，因此热重载前
一定要先注销旧字典。

#note[
  对 `bl_label`、属性 `name`、`description` 以及 `layout.*` 接收的普通文字，
  Blender 会在绘制 UI 时按上下文查翻译；常规插件不需要到处手动调用 `pgettext_*`。
  只有拼接或格式化后的动态句子才考虑 `pgettext_iface()` / `pgettext_tip()`，
  而且要先翻译模板，再插入变量。
]

=== 4.2.4 常见问题

#pitfall[
  *易错点一：`bl_idname = __name__` 写在子模块里。* 如果 `AddonPreferences`
  定义在 `my_addon/prefs.py` 里，`__name__` 是 `"my_addon.prefs"`，
  而 `bl_idname` 必须是 `"my_addon"`。Rigify 的注释说得很清楚
  （#src("scripts/addons_core/rigify/__init__.py:198")）：
  "this must match the addon name, use `'__package__'` when defining this
  in a submodule of a python package."。用 `__package__` 两种情况都对。
]

#pitfall[
  *易错点二：在 `AddonPreferences` 里放 `PointerProperty` / 大数组。*
  偏好设置会被写进用户的 `userpref.blend`。放几百 KB 的数据会让偏好设置
  文件臃肿、同步变慢。大体积的运行时数据应该放到 4.2.2 讲的
  `user_resource` 目录里，偏好设置里只存一个路径。
]

== 4.3 分发：安装、扩展平台、版本兼容

*两种分发形态*

Blender 4.2 引入了*扩展平台*。从这一版起，"addon"有了新旧两种形态，
它们从扫描到加载的路径完全不同。

#figure(
  kind: table,
  table(
    columns: (1fr, 1fr, 1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*维度*], [*传统 addon*], [*扩展（extension）*]),
    [元数据来源], [文件顶部的 `bl_info` 字典], [`blender_manifest.toml`],
    [扫描方式], [`ast.literal_eval()` 读 `bl_info` 那一段], [读取清单文件（`tomllib`）],
    [安装位置], [`<user scripts>/addons/`], [扩展仓库目录（用户或系统）],
    [模块名], [`"my_addon"`], [`"bl_ext.<repo>.my_addon"`],
    [第三方依赖], [自己在 `sys.path` 上想办法], [清单里声明 `wheels`，Blender 负责安装],
    [权限声明], [无], [`[permissions]` 里声明 `network`/`files`/`clipboard`…],
    [官方分发渠道], [各处自建], [extensions.blender.org],
  ),
  caption: [传统 addon 与扩展的对照。两套机制在 5.2 里并存。],
) <tbl-dist-forms>

两种形态的扫描入口在 `addon_utils.paths()`
（#src("scripts/modules/addon_utils.py:84")）与
`_paths_with_extension_repos()`（#src("scripts/modules/addon_utils.py:111")）：

```python
# scripts/modules/addon_utils.py:84（节选）
def paths():
    import os

    paths = []
    for i, p in enumerate(_bpy.utils.script_paths()):
        # Bundled add-ons are always first.
        # Since this isn't officially part of the API, print an error so this never silently fails.
        addon_dir = os.path.join(p, "addons_core" if i == 0 else "addons")
        if os.path.isdir(addon_dir):
            paths.append(addon_dir)
        elif i == 0:
            print("Internal error:", addon_dir, "was not found!")
    return paths
```

`i == 0` 是 Blender 自带的脚本目录，它下面叫 `addons_core`
（这就是为什么随源码分发的官方 addon 在 `scripts/addons_core/` 而不是
`scripts/addons/`）；用户目录下才叫 `addons`。

=== 4.3.1 传统安装

给用户一个含 `__init__.py` 的目录或一个 `.zip`，在
"编辑 → 偏好设置 → 插件 → 从磁盘安装"里选择即可。安装结果是解压到
`<user scripts>/addons/<name>/`。

开发期的替代做法是直接把开发目录软链接到 `addons/` 下，避免反复打包。
环境变量 `BLENDER_USER_SCRIPTS` 可以把整个用户脚本目录指到你自己的位置，
这是做隔离测试的标准手段：

```bash
# 把用户脚本目录指向一个临时位置，避免污染日常配置
$ BLENDER_USER_SCRIPTS=/tmp/blender_scripts blender --background \
    --python-expr \
    "import addon_utils; print(addon_utils.paths())"
```

=== 4.3.2 扩展平台的清单文件

一个扩展至少需要两样东西：`blender_manifest.toml` 和一个提供
`register()` / `unregister()` 的 `__init__.py`。官方的示例扩展很短
（#src("scripts/addons_core/bl_pkg/example_extension/__init__.py")）：

```python
# scripts/addons_core/bl_pkg/example_extension/__init__.py（完整）
def register():
    print("Register", __package__)


def unregister():
    print("UnRegister", __package__)
```

注意它*没有* `bl_info` —— 扩展的元数据不在这里。清单文件的模板在
#src("scripts/templates_toml/blender_manifest.toml")：

```toml
# scripts/templates_toml/blender_manifest.toml（节选）
schema_version = "1.0.0"

# Example of manifest file for a Blender extension
# Change the values according to your extension
id = "my_example_extension"
version = "1.0.0"
name = "My Example Extension"
tagline = "This is another extension"
maintainer = "Developer name <email@address.com>"
# Supported types: "add-on", "theme"
type = "add-on"

# # Optional: link to documentation, support, source files, etc
# website = "https://extensions.blender.org/add-ons/my-example-package/"

# # Optional: tag list defined by Blender and server, see:
# # https://docs.blender.org/manual/en/dev/advanced/extensions/tags.html
# tags = ["Animation", "Sequencer"]

blender_version_min = "4.2.0"
# # Optional: Blender version that the extension does not support, earlier versions are supported.
# # This can be omitted and defined later on the extensions platform if an issue is found.
# blender_version_max = "5.1.0"

# License conforming to https://spdx.org/licenses/ (use "SPDX: prefix)
# https://docs.blender.org/manual/en/dev/advanced/extensions/licenses.html
license = [
  "SPDX:GPL-3.0-or-later",
]
```

`type` 的合法取值由 `bl_pkg` 的 CLI 常量表给出
（#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:76")）：

```python
# scripts/addons_core/bl_pkg/cli/blender_ext.py:74（节选）
# Extension types supported by this version of Blender.
# Unknown types are skipped, allowing repositories to contain future extension types.
PKG_MANIFEST_TYPE_SUPPORTED = {"add-on", "theme"}
```

字段的完整清单（含必填与类型）在
#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:1973")：

```python
# scripts/addons_core/bl_pkg/cli/blender_ext.py:1973（节选）
    ("id", str, pkg_manifest_validate_field_idname),
    ("schema_version", str, pkg_manifest_validate_field_any_version),
    ("name", str, pkg_manifest_validate_field_any_non_empty_string_stripped_no_control_chars),
    ("tagline", str, pkg_manifest_validate_field_tagline),
    ("version", str, pkg_manifest_validate_field_any_version),
    ("type", str, pkg_manifest_validate_field_type),
    ("maintainer", str, pkg_manifest_validate_field_any_non_empty_string_stripped_no_control_chars),
    ("license", list, pkg_manifest_validate_field_any_non_empty_list_of_non_empty_strings),
    ("blender_version_min", str, pkg_manifest_validate_field_blender_version),
```

清单字段与传统 `bl_info` 的映射关系，在兼容层里写得一清二楚
（#src("scripts/modules/addon_utils.py:1281")）：

```python
# scripts/modules/addon_utils.py:1303（节选）
    # This isn't a full validation which happens on package install/update.
    if (value := data.get("name", None)) is None:
        print("Error: missing \"name\" in", filepath_toml)
        return None, filepath_toml
    ...
    bl_info["name"] = value
    ...
    bl_info["version"] = value
    ...
    bl_info["blender"] = value
    ...
        bl_info["description"] = value
    ...
    bl_info["author"] = value

    bl_info["category"] = "Development"  # Dummy, will be removed.
```

也就是说：清单里的 `maintainer` → `bl_info["author"]`，
`tagline` → `bl_info["description"]`，`blender_version_min` → `bl_info["blender"]`。

#warn[
  扩展*不应该*同时提供 `bl_info`。`enable()` 会显式检查并删除它
  （#src("scripts/modules/addon_utils.py:513")）：

  ```python
  # scripts/modules/addon_utils.py:513（节选）
        if is_extension:
            # Handle the case the an extension has `bl_info` (which is not used for extensions).
            # Note that internally a `bl_info` is added based on the extensions manifest - for compatibility.
            # So it's important not to use this one.
            bl_info = getattr(mod, "bl_info", None)
            ...
                # Always remove as this is not expected to exist and will be lazily initialized.
                del mod.bl_info
  ```

  在 `--debug-python` 下会打印
  `Add-on "..." has a "bl_info" which will be ignored in favor of "blender_manifest.toml"`。
]

=== 4.3.3 扩展的平台级约束

扩展有几个传统 addon 没有的约束，都写在清单里：

- *`platforms`*：`"windows-x64"`、`"macos-arm64"`、`"linux-x64"` 等取值。
  省略表示全平台可用。带原生二进制的扩展必须声明。
- *`wheels`*：随包分发的 `.whl`，Blender 负责按当前平台与 Python 版本挑选并安装。
- *`[permissions]`*：`network` / `files` / `clipboard` / `camera` / `microphone`。
  声明网络权限后，代码里还应检查 `bpy.app.online_access`。
- *`license`*：必须带 `SPDX:` 前缀。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 5.5pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*清单字段*], [*说明*]),
    [`schema_version`], [清单格式版本，示例模板用 `"1.0.0"`],
    [`id`], [包标识，必须能作为 Python 模块名的一部分],
    [`version`], [语义化版本字符串，如 `"0.2.0"`],
    [`name` / `tagline`], [界面显示名与一句话说明],
    [`maintainer`], [维护者；对应 `bl_info["author"]`],
    [`type`], [`"add-on"` 或 `"theme"`],
    [`blender_version_min` / `blender_version_max`], [兼容的 Blender 版本范围],
    [`license` / `copyright`], [SPDX 标识与版权声明],
    [`platforms`], [支持的平台列表；省略即全平台],
    [`wheels`], [随包分发的 Python wheel 路径],
    [`[permissions]`], [需要的能力与理由（每条一句话，句末不加句号）],
    [`[build]`], [`paths_exclude_pattern` 等打包排除规则],
  ),
  caption: [`blender_manifest.toml` 的字段。必填项见 #src("scripts/addons_core/bl_pkg/cli/blender_ext.py:1973")。],
) <tbl-manifest-fields>

=== 4.3.4 用命令行打包与校验

扩展的打包与校验不需要打开 Blender 界面，它是一条 CLI 子命令：
`blender --command extension`。"Command line access for extension operations" 这句
提示就写在 #src("scripts/addons_core/bl_pkg/bl_extension_cli.py:5")。

注册这条命令的代码在 `bl_pkg` 的 `register()` 里
（#src("scripts/addons_core/bl_pkg/__init__.py:979")）：

```python
# scripts/addons_core/bl_pkg/__init__.py:979（节选）
    cli_commands.append(bpy.utils.register_cli_command("extension", cli_extension))
```

`bpy.utils.register_cli_command()` 的接口文档
（#src("source/blender/python/intern/bpy_cli_command.cc:187")）：

```cpp
// source/blender/python/intern/bpy_cli_command.cc:187（节选）
PyDoc_STRVAR(
    /* Wrap. */
    bpy_cli_command_register_doc,
    ".. function:: register_cli_command(id, execute)\n"
    "\n"
    "   Register a command, accessible via the (``-c`` / ``--command``) command-line argument.\n"
    "\n"
    "   :param id: The command identifier (must pass an ``str.isidentifier`` check).\n"
```

两条开发期最常用的子命令是 `build` 与 `validate`，它们的参数定义在
#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:5394") 与
#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:5428")：

```python
# scripts/addons_core/bl_pkg/cli/blender_ext.py:5394（节选）
def argparse_create_author_build(
        subparsers: "argparse._SubParsersAction[argparse.ArgumentParser]",
        args_internal: bool,
) -> None:
    subparse = subparsers.add_parser(
        "build",
        help="Build a package.",
        description="Build a package in the current directory.",
        formatter_class=argparse.RawTextHelpFormatter,
    )

    generic_arg_package_source_dir(subparse)
    generic_arg_package_output_dir(subparse)
    generic_arg_package_output_filepath(subparse)
    generic_arg_package_valid_tags(subparse)
    generic_arg_build_split_platforms(subparse)
    generic_arg_verbose(subparse)
```

四个参数的默认值定义在各自函数里（#src("scripts/addons_core/bl_pkg/cli/blender_ext.py:3427")）：
`--source-dir` 默认 `"."`，`--output-dir` 默认 `"."`，
`--output-filepath` 默认空（自动取 `<id>-<version>.zip`），
另有 `--valid-tags` 与 `--split-platforms`。

```bash
# 查看扩展命令的全部子命令
$ blender --command extension --help

# 校验当前目录下的清单（不打包）
$ blender --command extension validate

# 打包当前目录（清单与代码都在当前目录）
$ blender --command extension build --source-dir . --output-dir dist
```

#tip[
  `validate` 是提交到 extensions.blender.org 之前的必做一步。它会检查
  清单字段、标签合法性、以及包结构，报错信息比运行时清晰得多。
  校验逻辑在 #src("scripts/addons_core/bl_pkg/cli/blender_ext.py:5028") 的
  `subcmd_author.validate()`。
]

=== 4.3.5 运行时安装与管理

对用户来说，扩展可以通过图形界面安装，也可以用命令行脚本批量管理：

```python
# 示意：脚本方式安装一个本地扩展包
import bpy

bpy.ops.extensions.package_install_files(
    filepath="/abs/path/my_addon-1.0.0.zip",
    repo="user_default",
    enable_on_install=True,
)
```

这些操作符的 `bl_idname` 都在
#src("scripts/addons_core/bl_pkg/bl_extension_ops.py") 里，例如
`extensions.package_install_files`（第 2459 行）、
`extensions.package_install`（第 2927 行）、
`extensions.package_uninstall`（第 3458 行）。

命令行等价物是 `blender --command extension install-file / remove` 等子命令
（#src("scripts/addons_core/bl_pkg/bl_extension_cli.py:903")）：

```python
# scripts/addons_core/bl_pkg/bl_extension_cli.py:903（节选）
def cli_extension_args_extra(
    subparsers: "argparse._SubParsersAction[argparse.ArgumentParser]",
) -> None:
    # Package commands.
    cli_extension_args_list(subparsers)
    cli_extension_args_sync(subparsers)
    cli_extension_args_upgrade(subparsers)
    cli_extension_args_install(subparsers)
    cli_extension_args_install_file(subparsers)
    cli_extension_args_remove(subparsers)

    # Preference commands.
    cli_extension_args_repo_list(subparsers)
    cli_extension_args_repo_add(subparsers)
    cli_extension_args_repo_remove(subparsers)
```

=== 4.3.6 版本兼容声明

*传统 addon* 的 `bl_info["blender"]` 是"最低要求的 Blender 版本"，写成元组，
例如 `(4, 2, 0)`。它*不会*阻止 addon 在新版本上加载，也不会阻止它在旧版本上加载 ——
它只是给用户和扩展平台的一个声明。

*扩展*的兼容范围写在清单里。运行时能不能用，取决于安装/更新时的校验，
以及启动时扩展仓库写入的兼容性缓存。这个缓存在
#src("scripts/modules/addon_utils.py:1173") 附近被刷新，
不兼容的扩展会被记进 `_extensions_incompatible`，启用时直接报错
（#src("scripts/modules/addon_utils.py:383")）：

```python
# scripts/modules/addon_utils.py:382（节选）
        # Ensure the extensions are compatible.
        if _extensions_incompatible:
            if (error := _extensions_incompatible.get(
                    module_name[len(_ext_base_pkg_idname_with_dot):].partition(".")[0::2],
            )):
                try:
                    raise RuntimeError(
                        "Extension {:s} is incompatible ({:s})".format(
                            module_name, error
                        )
                    )
```

自己写代码判断版本时，用 `bpy.app.version`
（#src("source/blender/python/intern/bpy_app.cc:86")），它和 `bl_info["blender"]`
是同一个三元组格式：#example-file("ch04/version_check.py")

```python
# 完整可运行：版本相关的分支判断
import bpy

if bpy.app.version >= (5, 0, 0):
    print("5.0 或更新的 API 可用")
else:
    print("需要兼容分支，当前版本:", bpy.app.version_string)
```

#pitfall[
  *不要用字符串比较版本。* `bpy.app.version_string` 是给人看的
  （例如 `"5.2.2"`），`"5.10.0" < "5.9.0"` 在字符串比较下为真。
  比较一律用 `bpy.app.version` 元组。
]

#pitfall[
  *不要只在 `bl_info["blender"]` 里写新版本就以为旧版本会拒绝加载。*
  传统 addon 的版本声明不是运行时的强约束。如果你用了 4.2 才有的 API，
  就在代码里显式判断并给出清晰报错，而不是指望 Blender 拦住你。
]

=== 4.3.7 常见问题

#pitfall[
  *易错点一：把手写的 `.zip` 直接当扩展包。* 扩展包必须由
  `--command extension build` 或平台的打包流程生成 —— 它会在根目录放入
  清单文件，并按排除规则过滤掉 `__pycache__/`、`.git/` 等。
  随便 `zip -r` 出来的压缩包在 `package_install_files` 那里会被清单校验拒绝。
]

#pitfall[
  *易错点二：本地测试时用了 `bl_ext.<repo>.<id>` 之外的模块名。*
  扩展的模块名由仓库与包 id 拼成，代码里若硬编码了 `"my_addon"` 这类
  传统模块名，在扩展形态下会导入失败。需要引用自身名字时一律用
  `__package__` / `__name__`。
]

== 4.4 测试与调试 Python 插件

*调试开关：`--debug-python`*

Blender 有一族 `--debug-*` 命令行开关，它们的定义与文档字符串都在
#src("source/creator/creator_args.cc")。Python 相关的那一条：

```cpp
// source/creator/creator_args.cc:3193（节选）
  BLI_args_add(ba,
               nullptr,
               "--debug-python",
               CB_EX(arg_handle_debug_mode_generic_set, python),
               reinterpret_cast<void *>(G_DEBUG_PYTHON));
```

文档字符串是 `"Enable debug messages for Python."`
（#src("source/creator/creator_args.cc:1391")）。它设置的是
`G_DEBUG_PYTHON` 标志位，值定义在 #src("source/blender/blenkernel/BKE_global.hh:246")：

```cpp
// source/blender/blenkernel/BKE_global.hh:246（节选）
  G_DEBUG_PYTHON = (1 << 2),          /* extra python info */
```

运行时可以在 Python 里读写它（#src("source/blender/python/intern/bpy_app.cc:578")）：
#example-file("ch04/debug_flags.py")

```python
# 完整可运行：检查调试标志
import bpy
print("debug:", bpy.app.debug, " debug_python:", bpy.app.debug_python)
```

#figure(
  kind: table,
  table(
    columns: (1fr, 1fr),
    inset: 5.5pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*打开后会发生什么*], [*源码位置*]),
    [Python 警告默认全部显示（`warnings` 过滤器加 `default`）],
    [#src("source/blender/python/intern/bpy_interface.cc:469")],
    [`addon_utils` 打印 `fake_module` / `enable` / `disable` 的每一步],
    [#src("scripts/modules/addon_utils.py:130")],
    [注册类时警告"继承了已注册的基类/子类"],
    [#src("source/blender/python/intern/bpy_rna.cc:10406")],
    [扩展同时带 `bl_info` 与清单时打印忽略提示],
    [#src("scripts/modules/addon_utils.py:523")],
  ),
  caption: [`--debug-python` 的几个实际效果。它不改变 API 行为，只增加输出。],
) <tbl-debug-python>

关于 Python 警告的那一条值得展开。`bpy_interface.cc` 里的逻辑是
（#src("source/blender/python/intern/bpy_interface.cc:465")）：

```cpp
// source/blender/python/intern/bpy_interface.cc:465（节选）
    {
      /* NOTE: running scripts directly uses the default behavior *but* the default
       * warning filter doesn't show warnings form module besides `__main__`.
       * Use the default behavior unless debugging Python. See: !139487. */
      bool show_python_warnings = false;

#  ifdef NDEBUG
      show_python_warnings = G.debug & G_DEBUG_PYTHON;
#  else
      /* Always show warnings for debug builds so developers are made aware
       * of outdated API use before any breakages occur. */
      show_python_warnings = true;
#  endif
```

注意 `NDEBUG` 分支：*Debug 构建（未定义 `NDEBUG`）里 Python 警告永远打开*，
Release 构建里才需要 `--debug-python`。如果你按第 2 章的方法构建了 Debug 版，
这些警告已经在你眼前了。

#tip[
  在 addon 开发期，建议的启动命令是：

  ```bash
  $ blender --background --factory-startup --debug-python --python-exit-code 1 --python my_test.py
  ```

  `--factory-startup` 排除用户配置与已启用的 addon（保证结果可复现）；
  `--python-exit-code 1` 让脚本里的未捕获异常变成非零退出码，
  这样 CI 才能发现失败（见下）。
]

=== 4.4.1 `--python-exit-code`：让脚本错误变成进程错误码

这是做自动化测试最关键的一个开关。它的实现
（#src("source/creator/creator_args.cc:2836")）：

```cpp
// source/creator/creator_args.cc:2836（节选）
static const char arg_handle_python_exit_code_set_doc[] =
    "<code>\n"
    "\tSet the exit-code in [0..255] to exit if a Python exception is raised\n"
    "\t(only for scripts executed from the command line), zero disables.";
```

要点：*它只对命令行传入的脚本有效*（`--python`、`--python-expr`），
对脚本编辑器里手敲的代码无效。默认值是 0（禁用），所以不加这个开关时
Python 出错也只会在终端里打印一行 traceback，进程仍然返回 0。

=== 4.4.2 官方测试是怎么跑的

Blender 自己的 Python 测试放在 `tests/python/`，由 CMake 注册成 CTest。
统一的命令行参数定义在 #src("tests/CMakeLists.txt:56")：

```cmake
# tests/CMakeLists.txt:54（节选）
# Standard Blender arguments for running tests.
# Specify exit code so that if a Python script error happens, the test fails.
set(TEST_BLENDER_EXE_PARAMS
  --background
  --console-crash-handler
  --factory-startup
  --debug-memory
  --debug-exit-on-error
  --python-exit-code 1
)
```

其中 `--python-exit-code 1` 正是上一条讲的东西。注册一个测试只需要一行
（#src("tests/python/CMakeLists.txt:228")）：

```cmake
# tests/python/CMakeLists.txt:228（节选）
add_blender_test(
  script_load_addons
  --python ${CMAKE_CURRENT_LIST_DIR}/bl_load_addons.py
)
```

跟 addon 生命周期最相关的一个测试是 `tests/python/bl_load_addons.py`。
它做的事情值得抄：*把所有 addon 逐个启用、禁用、重载，并断言状态一致*。
它的文件头就写明了运行方式（#src("tests/python/bl_load_addons.py:7")）：

```python
# tests/python/bl_load_addons.py:7（节选）
"""
./blender.bin --background --factory-startup --python tests/python/bl_load_addons.py
"""
```

核心断言很朴素但很有力（#src("tests/python/bl_load_addons.py:60")）：

```python
# tests/python/bl_load_addons.py:69（节选）
    for mod in modules:
        mod_name = mod.__name__
        print("\tenabling:", mod_name)
        addon_utils.enable(mod_name, default_set=True)
        if (mod_name not in addons) and (mod_name not in EXCLUDE_ADDONS):
            addons_fail.append(mod_name)
```

以及"启用→禁用→重载→再启用"的顺序组合
（#src("tests/python/bl_load_addons.py:85")）。*这个测试是最省事的
addon 冒烟测试*：把自己的 addon 放进去跑一遍，能挡住大部分
"禁用后残留""重载后重复注册"的问题。

=== 4.4.3 给自己的 addon 写单元测试

Blender 侧的 Python 单元测试没有专门的框架，直接用标准库 `unittest`。
官方测试的惯用法是"让 `unittest.main()` 读 `--` 之后的参数"
（#src("tests/python/bl_pyapi_prop.py:584")）：

```python
# tests/python/bl_pyapi_prop.py:584（节选）
if __name__ == '__main__':
    import sys
    sys.argv = [__file__] + (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    unittest.main()
```

这解释了为什么 Blender 的测试命令里常有 `-- --verbose`：`--` 之前的参数归
Blender，之后的归你的脚本。文件头也写明了这一点
（#src("tests/python/bl_pyapi_prop.py:9")）：

```python
# tests/python/bl_pyapi_prop.py:9（节选）
# ./blender.bin --background --python tests/python/bl_pyapi_prop.py -- --verbose
```

一个给 addon 用的最小测试脚本可以这样写：
#example-file("ch04/addon_smoke_test.py")

```python
# 完整可运行：addon 冒烟测试（保存为 my_test.py，用 --python 传入）
"""Run with:
   blender --background --factory-startup --python-exit-code 1 --python my_test.py
"""
import unittest

import addon_utils
from _bpy import ops as _ops


class TestAddonLifecycle(unittest.TestCase):
    module_name = "my_addon"

    def tearDown(self):
        addon_utils.disable(self.module_name, default_set=False)

    def test_enable_disable_twice(self):
        for _ in range(2):
            addon_utils.enable(self.module_name, default_set=False)
            _, loaded = addon_utils.check(self.module_name)
            self.assertTrue(loaded, "addon 未成功加载")

            addon_utils.disable(self.module_name, default_set=False)
            _, loaded = addon_utils.check(self.module_name)
            self.assertFalse(loaded, "addon 未成功卸载")

    def test_operator_registered(self):
        addon_utils.enable(self.module_name, default_set=False)
        self.assertIn("MY_ADDON_OT_hello", set(_ops.dir()))


if __name__ == "__main__":
    import sys
    sys.argv = [__file__]
    unittest.main()
```

#note[
  `test_operator_registered` 直接遍历操作符类型注册表：`_bpy.ops.dir()`
  返回全部已注册的 `idname`（#src("source/blender/python/intern/bpy_operator.cc:33")）。
  `bpy.ops` 是动态命名空间，`hasattr(bpy.ops.my_addon, "hello")` 永远为真
  —— 因为它按需创建可调用对象（#src("scripts/modules/bpy/ops.py:18")），
  属性存在与否不反映是否注册成功。
]

如果只想做一次交互式检查，可以单独运行下面的脚本：
#example-file("ch04/operator_registry.py")

```python
# 完整可运行：列出全部已注册操作符并检查自己那一个
from _bpy import ops as _ops

registered = set(_ops.dir())
print("my_addon.hello 已注册:", "MY_ADDON_OT_hello" in registered)
```

第 3 章讲过 `bpy.ops` 的命名映射规则：Python 侧写 `my_addon.hello`，
C 侧注册名是 `MY_ADDON_OT_hello`，转换函数是
`WM_operator_bl_idname()`（#src("source/blender/windowmanager/intern/wm_operators.cc:159")），
分隔符常量 `OP_BL_SEP_STRING "_OT_"` 在
#src("source/blender/windowmanager/intern/wm_operators.cc:128")。

=== 4.4.4 崩溃与卡死怎么查

Python 层的错误都会带 traceback，但有两类问题不会：

- *崩溃（segfault）*。多半是持有失效引用。第 3 章的 `ReferenceError` 是
  友好版本；如果代码绕过了检查（例如把指针交给了 `foreach_get`），
  就会直接崩。定位手段是 `--debug-memory`（见
  #src("tests/CMakeLists.txt:60")）以及 gdb/lldb 的 backtrace。
- *卡死或极慢*。先怀疑在循环里逐元素访问 `bpy_prop_collection`。
  第 6 章讲 `foreach_get` / `foreach_set`。

#tip[
  最快的定位手段往往还是加打印。但要注意 `register()` 期间的输出可能被
  其他启动日志淹没，用 `--debug-python` 加上 `--background` 重定向到文件：

  ```bash
  $ blender --background --factory-startup --debug-python --python my_test.py > log.txt 2>&1
  ```
]

=== 4.4.5 常见问题

#pitfall[
  *易错点一：以为 `--python-exit-code` 对 `bpy.ops.script.python_file_run` 之类也生效。*
  它的文档明确写了"only for scripts executed from the command line"
  （#src("source/creator/creator_args.cc:2838")）。在运行时用操作符执行脚本，
  异常只会被打印。
]

#pitfall[
  *易错点二：用 `hasattr()` 判断操作符/面板是否注册成功。*
  见 4.4.3 的提醒：`bpy.ops` 是动态命名空间，属性检测没有意义。
  面板/操作符注册失败时 `bpy.utils.register_class()` 会直接抛异常，
  捕获异常才是可靠的检测方式。
]

#pitfall[
  *易错点三：把 `bl_info` 里的 `"version"` 写成字符串。*
  `ast.literal_eval()` 能解析字符串，但 UI 与扩展平台期望的是元组
  `(1, 0, 0)`。写成 `"1.0.0"` 不会有明显报错，只是在界面上显示异常。
]

== 4.5 本章小结

- `bl_info` 是"文件顶部的字面量字典"。Blender 用 `ast.literal_eval()` 只读它那一小段，
  所以它必须是字面量、必须靠前。缺失只会打印警告并让 addon 在列表里消失。
- 字段的完整清单与默认值见 #src("scripts/modules/addon_utils.py:692")。
- `enable()` 的流程是：`RestrictBlend` → `import_module` → `register()` → 打标记。
  期间 context 被禁用，失败时模块会从 `sys.modules` 删除。
- `disable()` 调用 `unregister()`，异常同样被吞掉。`register()` 的每个副作用
  都要在 `unregister()` 里成对撤销（顺序相反）。
- `bpy.utils.register_classes_factory()` 与 `register_submodule_factory()`
  是两个官方惯用法，能省掉大量样板代码。
- 多文件 addon 需要在 `__init__.py` 里做重载自保（`if "bpy" in locals()`）。
- `AddonPreferences.bl_idname` 必须等于 addon 模块名，通常写 `__package__`；
  它是 `PROP_REGISTER` 必填项，长度上限 127 字符。
- 分发有两种形态：传统 `bl_info` + `addons/`，以及扩展的
  `blender_manifest.toml` + 扩展仓库。扩展的元数据字段见
  #src("scripts/addons_core/bl_pkg/cli/blender_ext.py:1973")。
- 打包与校验用 `blender --command extension build` / `validate`。
- 调试用 `--debug-python`（Release 构建下才需要，Debug 构建默认开）；
  自动化用 `--background --factory-startup --python-exit-code 1 --python ...`。

#exercise[
  *练习 4.1（生命周期）* 写一个只有 `register()` / `unregister()` 和
  一个 `AddonPreferences` 的最小 addon，在 `register()` 里往
  `bpy.types.TOPBAR_MT_file_import` 追加一个菜单项，在 `unregister()` 里移除。
  然后反复"启用 → 禁用"五次，确认菜单里始终只有一个条目。
  再把 `unregister()` 里的 `remove` 注释掉，观察重复现象。

  *练习 4.2（自保重载）* 把练习 4.1 的 addon 拆成
  `__init__.py` + `operators.py` + `prefs.py` 三个文件，
  给 `__init__.py` 加上 `if "bpy" in locals()` 的重载自保。
  在 `operators.py` 里定义一个模块级计数器，然后在 Blender 里执行五次
  `bpy.ops.script.reload()`，观察计数器是否被重置。
  如果没被重置，说明你的自保逻辑漏了哪个子模块？

  *练习 4.3（清单与打包）* 把练习 4.1 的 addon 改造成扩展：
  写一个 `blender_manifest.toml`，`id` 用 `"my_addon"`，`type = "add-on"`，
  填好 `maintainer`、`tagline`、`license`。然后运行

  ```bash
  $ blender --command extension validate
  $ blender --command extension build --source-dir . --output-dir dist
  ```

  检查 `dist/` 下生成的 `.zip`：*里面有没有第一层目录？清单文件在不在根目录？*
  再故意把 `license` 写成不带 `SPDX:` 前缀的形式，看 `validate` 报什么错。

  *练习 4.4（回归测试）* 用 4.4.3 的模板给练习 4.1 的 addon 写一个测试脚本，
  用

  ```bash
  $ blender --background --factory-startup --python-exit-code 1 --python my_test.py
  ```

  跑通它。然后故意在 `register()` 里抛一个异常，确认进程返回非零退出码。
  最后把 `addon_utils.enable()` 的返回值用起来，验证它在失败时返回 `None`
  （依据 #src("scripts/modules/addon_utils.py:355") 的文档字符串：
  "the loaded module or None on failure"）。
]
