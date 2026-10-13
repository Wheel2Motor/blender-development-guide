#import "../common.typ": *

= 第 3 章 bpy API 全景

到第 2 章为止，你已经能编译 Blender，也能在脚本编辑器中运行 Python。但从
"代码能够执行"到"知道应该调用哪个接口"，还需要理解：*`bpy` 这套 API 如何形成*。

这一章要解决三个问题。第一，`bpy` 下面那七八个子模块各自管什么，遇到需求该往哪儿找。
第二，`bpy.types` 里成百上千个类从何而来 —— 理解了这条生成链，你就知道为什么
有些东西能改、有些只能读，为什么有些属性名和 C 源码里的字段名不一样。第三，
`bpy.data` 和 `bpy.context` 这两条数据入口的准确语义，以及围绕它们最常见的几类错误。

本章不涉及 UI 绘制与操作符编写，那是第 5 章的内容；数据批处理的性能话题留到第 6 章。

想照着官方教程亲手跑通第一个脚本（而不是先读 API），从官方手册的这篇开始：
#weblink("https://docs.blender.org/manual/en/latest/advanced/scripting/introduction.html#getting-started", label: [脚本入门（Getting Started）])。

== 3.1 模块地图

=== 3.1.1 顶层结构：只有三个是真模块

`bpy` 对外的第一眼印象是"一个包里装了很多子模块"。这个印象只有一部分是对的。
`scripts/modules/bpy/__init__.py:9` 给出的 `__all__` 是：

```python
# scripts/modules/bpy/__init__.py:9（节选）
__all__ = (
    "app", "context", "data", "msgbus", "ops",
    "path", "props", "types", "utils",
)
```

紧接着第 23 行到第 37 行说明了它们的来源：只有 `ops`、`path`、`utils` 是真正的
Python 模块（`from . import ...`），其余全部来自 C 扩展 `_bpy`：

```python
# scripts/modules/bpy/__init__.py:23（节选）
from _bpy import (
    app,
    context,
    data,
    msgbus,
    props,
    types,
)
```

注意第 59 行那几行，它在 `sys.modules` 里塞了几个假模块，好让
`from bpy.types import Panel` 这样的写法成立：

```python
# scripts/modules/bpy/__init__.py:59（节选）
sys.modules.update({
    "bpy.app": app,
    "bpy.app.handlers": app.handlers,
    "bpy.app.translations": app.translations,
    "bpy.types": types,
})
```

这一点值得记住：*`bpy.app`、`bpy.types` 并不是磁盘上的 `bpy/` 目录里的文件*，
而是 C 侧创建出来的对象。你用 `glob` 在 `scripts/modules/bpy/` 下找不到
`types.py`，这是正常的。

最后一个细节是第 73 行的 `main()` 调用 —— `bpy/__init__.py` 在被导入时会执行
`bpy.utils.load_scripts(extensions=False)`（#src("scripts/modules/bpy/__init__.py:70")），
也就是*先加载所有非扩展脚本、把 keymap 建好，再加载 addon*。这个顺序会在第 4 章
再次出现，它是很多"为什么我的 addon 启动顺序很奇怪"问题的根源。

=== 3.1.2 七个模块的分工

#figure(
  kind: table,
  table(
    columns: (auto, 1fr, 1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*模块*], [*是什么*], [*拿来做什么*]),
    [`bpy.data`],
    [一个 `bpy.types.BlendData` 实例，不是模块（#src("source/blender/python/intern/bpy_rna.cc:8903")）],
    [读写数据块：对象、网格、材质、场景、集合……],
    [`bpy.types`],
    [一个 C 扩展模块，属性访问时按需生成类（#src("source/blender/python/intern/bpy_rna.cc:8956")）],
    [继承 `Operator`/`Panel`/`PropertyGroup` 等基类，做类型检查],
    [`bpy.ops`],
    [一个 Python 包，把内部模块 `_bpy.ops` 包装成动态命名空间（#src("scripts/modules/bpy/ops.py:38")）],
    [调用操作符，例如 `bpy.ops.object.select_all()`],
    [`bpy.context`],
    [一个 `bpy.types.Context` 实例，背后直接指向活的 `bContext`（#src("source/blender/python/intern/bpy_interface.cc:294")）],
    [读取当前窗口/区域/选中物体等"运行时状态"],
    [`bpy.props`],
    [C 模块，注册期使用的属性构造器（#src("source/blender/python/intern/bpy_props.cc:5875")）],
    [给自定义类声明 RNA 属性],
    [`bpy.utils`],
    [Python 包，内含 `register_class`、路径与资源助手（#src("scripts/modules/bpy/utils/__init__.py:23")）],
    [注册/注销类、查路径、打包资源],
    [`bpy.app`],
    [C 模块，版本号、路径、调试开关、事件处理器（#src("source/blender/python/intern/bpy_app.cc:86")）],
    [做版本兼容判断、挂载 `handlers`、读 `debug_python`],
  ),
  caption: [`bpy` 顶层模块分工。注意只有 `ops` / `path` / `utils` 是磁盘上的 Python 包。],
) <tbl-bpy-modules>

`bpy.path` 与 `bpy.msgbus` 没有进这张表 —— 前者是一小组字符串处理助手（`abspath`、
`basename`、`display_name` 等），几乎只被自身和少数 addon 使用；后者只有三个函数
（`subscribe_rna` / `publish_rna` / `clear_by_owner`），用途单一：订阅 RNA 属性的变更通知。

=== 3.1.3 怎么用这张表

判断"该往哪儿找"有一条很实用的规则：

1. *我要读写一个已经存在的东西* → 先看 `bpy.data`。
2. *我要改"当前正在编辑的是什么"* → 看 `bpy.context`。
3. *我要让 Blender 做一件事* → 看 `bpy.ops`。
4. *我要新增一种 Blender 认识的东西* → 看 `bpy.types` + `bpy.props` + `bpy.utils.register_class()`。

#pitfall[
  新手最容易犯的错，是拿 `bpy.ops` 当数据 API 用。`bpy.ops` 走的是操作符系统 ——
  它要过 `poll()`、要开撤销步、要发通知、要重绘界面，开销比直接读写数据大一到两个
  数量级。批量改一万个物体的位置，用 `foreach_set`（第 6 章）比用任何
  `bpy.ops.transform.*` 都快得多。反过来，只有 `bpy.ops` 才有的能力（例如
  启动一个模态工具、弹出文件选择器）也不该用数据 API 硬凑。
]

=== 3.1.4 `bpy.data` 不是模块

`bpy.data` 的实现只有十行，但它解释了一个常见困惑：

```cpp
// source/blender/python/intern/bpy_rna.cc:8901（节选）
/* 'bpy.data' from Python. */
static PointerRNA *rna_module_ptr = nullptr;
PyObject *BPY_rna_module()
{
  BPy_StructRNA *pyrna;

  /* For now, return the base RNA type rather than a real module. */
  PointerRNA ptr = RNA_main_pointer_create(G_MAIN);
  pyrna = reinterpret_cast<BPy_StructRNA *>(pyrna_struct_CreatePyObject(&ptr));

  rna_module_ptr = &pyrna->ptr.value();
  return reinterpret_cast<PyObject *>(pyrna);
}
```

`bpy.data` 是一个 `BPy_StructRNA` 包装，内部持有一个指向全局 `G_MAIN` 的
`PointerRNA`。它之所以在打开新 `.blend` 文件之后依旧可用，是因为
`BPY_update_rna_module()`（#src("source/blender/python/intern/bpy_rna.cc:8915")）
会把这个指针里的 `data` 重新指向新的 `G_MAIN`。

#tip[
  想确认某个名字在 `bpy.data` 上到底存不存在，别靠记忆。在 Blender 的 Python
  控制台里敲 `dir(bpy.data)`，或在命令行加 `--python-expr`。`bpy.data` 的
  可用集合由 #src("source/blender/makesrna/intern/rna_main.cc:320") 的那张
  `MainCollectionDef lists[]` 表决定，和 RNA 定义是一一对应的。
]

== 3.2 `bpy` 是怎么生成的

这一节讲 RNA 定义如何变成 Python 里的类与方法，是本章的重点。它不是"背景知识"，而是能直接帮你少走弯路的操作性知识。

=== 3.2.1 三层结构：DNA → RNA → Python

Blender 的数据层分三步构建，每一步都有独立的代码目录：

- *DNA*：`source/blender/makesdna/DNA_*.h`，是纯 C 结构体定义，负责"字节怎么排布"。
  它的消费者是文件读写，不是你。
- *RNA*：`source/blender/makesrna/intern/rna_*.cc`，为每个 DNA 结构注册一份*运行时
  元数据* —— 类型叫什么名字、有哪些属性、属性是只读还是可写、UI 上显示什么提示。
- *Python 绑定*：`source/blender/python/intern/bpy_*.cc`，把 RNA 元数据*映射*成
  Python 类型与描述符。这一层不认识 DNA 字段，只认识 RNA。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr, 1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*在哪*], [*它是关于什么的*]),
    [DNA], [`source/blender/makesdna/DNA_*.h`], [C 结构体的内存布局（`.blend` 文件格式的基础）],
    [RNA], [`source/blender/makesrna/intern/rna_*.cc`], [运行时可查询的类型/属性元数据（含 UI 文案与权限）],
    [Python 绑定], [`source/blender/python/intern/bpy_*.cc`], [把 RNA 元数据实例化成 Python 类与 getset 描述符],
  ),
  caption: [三层结构的职责划分。`makesrna` 完全不认识 Python —— 它一行 `PyObject` 都没有。],
) <tbl-three-layers>

下面这个事实很反直觉，但很容易验证：*`makesrna` 里没有任何 Python 代码*。
用 grep 在 `source/blender/makesrna/` 下搜 `pyrna` 或 `PyObject`，只会在注释里
命中（例如 #src("source/blender/makesrna/intern/rna_ID.cc:1771")）。
Python 绑定全部发生在 `source/blender/python/intern/`。

=== 3.2.2 RNA 定义长什么样

打开任意一个 `rna_*.cc`，你会看到高度重复的注册函数。以 `ID` 为例：

```cpp
// source/blender/makesrna/intern/rna_ID.cc:2388（节选）
srna = RNA_def_struct(brna, "ID", nullptr);
RNA_def_struct_ui_text(
    srna,
    "ID",
    "...");
```

`RNA_def_struct(brna, "ID", nullptr)` 的含义是：在一个全局的 `BlenderRNA` 注册表
（`brna`）里登记一个名为 `"ID"` 的结构。第三个参数是基类名，`nullptr` 表示没有基类。

用基类的例子更直观。#src("source/blender/makesrna/intern/rna_object.cc:2994")
注册了 `Object`：

```cpp
// source/blender/makesrna/intern/rna_object.cc:2994（节选）
srna = RNA_def_struct(brna, "Object", "ID");
```

`Mesh` 同理（#src("source/blender/makesrna/intern/rna_mesh.cc:2914")）：

```cpp
// source/blender/makesrna/intern/rna_mesh.cc:2914（节选）
srna = RNA_def_struct(brna, "Mesh", "ID");
```

这两个 `"ID"` 参数，就是 `isinstance(bpy.data.objects[0], bpy.types.ID)`
为真的原因 —— *Python 的类继承关系是从 RNA 的基类链推导出来的，不是手工写的*。

规模感：`source/blender/makesrna/intern/` 下有 108 个 `rna_*.cc`，其中
`RNA_def_struct(` 共出现 1,037 次（以 `brna` 为首参的 1,014 次），
`RNA_def_` 前缀的调用约 52,700 次。这个数量级说明：*你不可能记住这些定义，
你只能学会怎么查它们*。

=== 3.2.3 生成链：四步

`bpy.types.Foo` 从无到有，走的是下面四步。

*第一步：`makesrna` 在启动时把 RNA 结构注册进 `BlenderRNA`。*
每个模块都有一个形如 `void RNA_def_object(BlenderRNA *brna)` 的入口函数，
由 `makesrna` 生成的启动代码统一调用。注册结果是内存里的一张 `StructRNA` 链表。

*第二步：C 侧创建 `bpy.types`，并读入 Python 侧的类定义。*
`BPy_init_modules()` 里的顺序很关键（#src("source/blender/python/intern/bpy.cc:790")）：

```cpp
// source/blender/python/intern/bpy.cc:790（节选）
/* Needs to be first so `_bpy_types` can run. */
PyObject *bpy_types = BPY_rna_types();
...
PyModule_AddObject(mod, "types", bpy_types);

/* Needs to be first so `_bpy_types` can run. */
BPY_library_load_type_ready();

BPY_rna_data_context_type_ready();

BPY_rna_gizmo_module(mod);

/* Important to internalizes `_bpy_types` before creating RNA instances. */
{
  PyObject *bpy_types_dict_dummy = PyDict_New();
  BPY_rna_types_dict_set(bpy_types_dict_dummy);
  PyObject *bpy_types_module_py = bpy_import_test("_bpy_types");
  BLI_assert(PyDict_GET_SIZE(bpy_types_dict_dummy) == 0);
  Py_DECREF(bpy_types_dict_dummy);

  PyObject *bpy_types_module_py_dict = PyModule_GetDict(bpy_types_module_py);
  BPY_rna_types_dict_set(bpy_types_module_py_dict);
}
PyModule_AddObject(mod, "data", BPY_rna_module());
BPY_rna_types_finalize_external_types(bpy_types);
```

注意第 806 行到第 808 行那个"哑模块"。`_bpy_types.py` 在被导入时会执行
`class Object(_types.ID): ...` 这样的类定义语句，而 `_types.ID` 又会触发
`bpy.types.ID` 的实例化 —— 此时 `bpy.types` 还没有对应的 Python 字典。
那行 `BLI_assert(PyDict_GET_SIZE(bpy_types_dict_dummy) == 0)` 就是在断言
"哑模块从未被真正使用"，因为第一次访问都走的是 `bpy.types` 模块自身。

*第三步：Python 侧提供"手工类"，C 侧在需要时接上去。*
`scripts/modules/_bpy_types.py` 是一个纯 Python 文件，里面为一批类型提供了
Python 层的实现。它做的第一件事是定义 `Context`：

```python
# scripts/modules/_bpy_types.py:20（节选）
class Context(_StructRNA):
    __slots__ = ()
```

以及 `class Object(_types.ID)`（第 236 行）、`class Mesh(_types.ID)`（第 730 行）、
`class PropertyGroup(_StructRNA, metaclass=_RNAMetaPropGroup)`（第 1155 行）
等等，共 100 处 `class` / `__slots__` 声明。

这些类不是必须的 —— 只是"C 生成"不够用时才需要。而一旦提供了，C 侧就会优先采用它。
判定逻辑在 `pyrna_srna_ExternalType()`（#src("source/blender/python/intern/bpy_rna.cc:8447")）：

```cpp
// source/blender/python/intern/bpy_rna.cc:8447（节选）
static PyObject *pyrna_srna_ExternalType(StructRNA *srna)
{
  BLI_assert(bpy_types_dict);

  const char *idname = RNA_struct_identifier(srna);
  PyObject *newclass = PyDict_GetItemString(bpy_types_dict, idname);

  /* Sanity check, could skip this unless in debug mode. */
  if (newclass) {
    PyObject *base_compare = pyrna_srna_PyBase(srna);
    PyObject *tp_bases = (reinterpret_cast<PyTypeObject *>(newclass))->tp_bases;
    PyObject *tp_slots = PyDict_GetItem((reinterpret_cast<PyTypeObject *>(newclass))->tp_dict,
                                        bpy_intern_str___slots__);

    if (tp_slots == nullptr) {
      CLOG_ERROR(
          BPY_LOG_RNA, "expected class '%s' to have __slots__ defined, see _bpy_types.py", idname);
      newclass = nullptr;
    }
    ...
  }

  return newclass;
}
```

这里有两个硬性要求，它们解释了写 `_bpy_types.py` 风格代码时最常见的两条报错：

- 类*必须有* `__slots__` 条目。否则会打出
  `expected class 'X' to have __slots__ defined, see _bpy_types.py` 并退回自动生成。
- 类的第一个基类*必须等于* RNA 推导出的基类。否则会打出
  `incorrect subclassing of SRNA 'X', expected 'Y'`。

*第四步：真正的类在第一次被访问时惰性构造。*
`bpy.types` 模块的方法表里挂了一个 `__getattr__`
（#src("source/blender/python/intern/bpy_rna.cc:9025")），它做的事是：

```cpp
// source/blender/python/intern/bpy_rna.cc:8956（节选）
static PyObject *bpy_types_module_getattro(PyObject *self, PyObject *pyname)
{
  BPy_TypesModule_State *state = static_cast<BPy_TypesModule_State *>(PyModule_GetState(self));
  BLI_assert(state->ptr.has_value());

  PointerRNA newptr;
  PyObject *ret;
  const char *name = PyUnicode_AsUTF8(pyname);

  if (name == nullptr) {
    PyErr_SetString(PyExc_AttributeError, "bpy.types: __getattr__ must be a string");
    ret = nullptr;
  }
  else if (RNA_property_collection_lookup_string(&state->ptr.value(), state->prop, name, &newptr))
  {
    ret = pyrna_struct_Subtype(&newptr);
    ...
```

而 `pyrna_srna_Subtype()`（#src("source/blender/python/intern/bpy_rna.cc:8496")）
是那个"如果没有就造一个"的地方：

```cpp
// source/blender/python/intern/bpy_rna.cc:8496（节选）
static PyObject *pyrna_srna_Subtype(StructRNA *srna)
{
  PyObject *newclass = nullptr;

  /* Stupid/simple case. */
  if (srna == nullptr) {
    newclass = nullptr; /* Nothing to do. */
  } /* The class may have already been declared & allocated. */
  else if ((newclass = static_cast<PyObject *>(RNA_struct_py_type_get(srna)))) {
    /* Add a reference for the return value. */
    Py_INCREF(newclass);
  } /* Check if `_bpy_types.py` module has the class defined in it. */
  else if ((newclass = pyrna_srna_ExternalType(srna))) {
    pyrna_subtype_set_rna(newclass, srna);
    /* Add a reference for the return value. */
    Py_INCREF(newclass);
  } /* Create a new class instance with the C API
     * mainly for the purposing of matching the C/RNA type hierarchy. */
  else {
    ...
```

三层查找顺序写在代码里，一目了然：*已缓存 → `_bpy_types.py` 里的手工类 →
用 C API 现造一个*。现造那一段（#src("source/blender/python/intern/bpy_rna.cc:8568")）
等价于 Python 里的：

```python
# 示意：pyrna_srna_Subtype() 中现造分支的逻辑等价物
Material = type("Material", (bpy.types.ID,), {"__module__": "bpy.types", "__slots__": ()})
```

生成出来的类被写回 `srna->py_type` 字段缓存（`RNA_struct_py_type_set`，
定义在 #src("source/blender/makesrna/intern/rna_access.cc:1118")），
所以第二次访问 `bpy.types.Material` 走的是缓存分支。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 5.5pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*符号*], [*职责*]),
    [`BPy_StructRNA`], [一个 RNA 结构*实例*的 Python 表示，例如 `bpy.data.objects[0]` 这个对象本身],
    [`pyrna_struct_Type`], [所有 `bpy.types.*` 类的共同基类（#src("source/blender/python/intern/bpy_rna.cc:7368")）],
    [`pyrna_srna_Subtype()`], [按需把某个 `StructRNA` 变成 Python 类，含查缓存与查 `_bpy_types.py`],
    [`pyrna_subtype_set_rna()`], [把 Python 类登记回 `StructRNA`，并挂上 `bl_rna` 属性（#src("source/blender/python/intern/bpy_rna.cc:8350")）],
    [`bpy_types_dict`], [`_bpy_types.py` 的模块字典，手工类的查找表（#src("source/blender/python/intern/bpy_rna.cc:8437")）],
  ),
  caption: [3.2 节涉及的几个核心符号。名字都以源码为准。],
) <tbl-bpy-symbols>

=== 3.2.4 为什么这么设计

这套机制看起来绕，但它一次解决了四个问题：

- *单一事实来源*。属性的可读可写、UI 文案、取值范围都定义在 RNA 里。C 的 UI 绘制、
  `.blend` 的文件版本迁移（versioning）、Python 绑定，读的是同一份元数据。
  加一个属性只需要改一处。
- *Python 不必硬编码 1,000 个类*。`bpy.types` 是一个"按需生成"的命名空间，
  省掉了手写（并维护）上千个 `PyTypeObject` 的工作量。
- *Python 侧仍可定制*。`_bpy_types.py` 给 `Mesh`、`Object`、`Panel` 等类加了
  C 侧不便于实现的助手方法与 `__slots__` 约束，C 侧通过
  `pyrna_srna_ExternalType()` 把它们接进来。
- *注册机制天然分层*。`RNA_def_struct_register_funcs()` 为每个可注册类型
  指定一对"注册/注销"回调。没有这对回调的类型，`bpy.utils.register_class()`
  会直接拒绝 —— 这就是"为什么不能注册新的编辑器类型"的机制层面答案。

最后一点可以在源码里直接看到。`bpy.utils.register_class()` 最终走到
`pyrna_register_class()`，它在 #src("source/blender/python/intern/bpy_rna.cc:10464")
做检查：

```cpp
// source/blender/python/intern/bpy_rna.cc:10463（节选）
/* Check that we have a register callback for this type. */
reg = RNA_struct_register(srna);

if (!reg) {
  PyErr_Format(PyExc_ValueError,
               "%s expected a subclass of a registerable "
               "RNA type (%.200s does not support registration)",
               error_prefix,
               RNA_struct_identifier(srna));
  return nullptr;
}
```

那么哪些类型有注册回调？`bpy.utils.register_class` 的文档字符串把清单写死了
（#src("source/blender/python/intern/bpy_rna.cc:10313")）：`Panel`、`UIList`、
`Menu`、`Header`、`Operator`、`KeyingSetInfo`、`RenderEngine`、`AssetShelf`、
`FileHandler`、`PropertyGroup`、`AddonPreferences`、`NodeTree`、`Node`、
`NodeSocket`、`Gizmo`、`GizmoGroup`。*一共十六个。* 这个清单是穷尽的，不是举例。

#warn[
  "`bpy.types` 里有 `SpaceView3D`，所以我可以继承它注册一个新编辑器" —— 不成立。
  能在 `bpy.types` 里*看到*一个类，只说明它对应的 RNA 结构已注册；
  能否*注册子类*取决于该结构有没有 `register` 回调。`Space` 系列没有。
  第 0 章的边界对照表说的就是这件事，这里给出了它在源码里的判据。
]

=== 3.2.5 怎么用：四个可操作的推论

*推论一：查 API 的正确顺序是"先查 RNA 定义，再看 Python 文档"。*
手动档的 `bl_rna` 是最好的自省工具。对一个实例 `x`，`x.bl_rna.properties`
给出全部属性，`x.bl_rna.functions` 给出全部方法，`x.bl_rna.identifier`
给出 RNA 类型名。`bl_rna` 这个属性本身就是 `pyrna_subtype_set_rna()` 挂上去的
（#src("source/blender/python/intern/bpy_rna.cc:8381")）。
下面的脚本可直接在 Blender 中运行。#example-file("ch03/rna_introspection.py")

```python
# 完整可运行：把一个类型的方法与属性打印出来
import bpy

mesh = bpy.data.meshes.new("probe")
print(mesh.bl_rna.identifier)                       # 'Mesh'
print(len(mesh.bl_rna.properties))                  # 属性数量
print([p.identifier for p in mesh.bl_rna.functions])  # 可调方法名
bpy.data.meshes.remove(mesh)
```

*推论二：属性是只读还是可写，由 RNA 标志决定，不由 Python 决定。*
RNA 属性上有 `PROP_EDITABLE` 标志，被清掉之后 Python 侧的 setter 会拒绝赋值。
`BlendData.filepath` 是一个典型例子（#src("source/blender/makesrna/intern/rna_main.cc:560")）：

```cpp
// source/blender/makesrna/intern/rna_main.cc:560（节选）
prop = RNA_def_property(srna, "filepath", PROP_STRING, PROP_FILEPATH);
RNA_def_property_string_maxlength(prop, FILE_MAX);
RNA_def_property_string_funcs(
    prop, "rna_Main_filepath_get", "rna_Main_filepath_length", nullptr);
RNA_def_property_clear_flag(prop, PROP_EDITABLE);
RNA_def_property_ui_text(prop, "Filename", "Path to the .blend file");
```

`RNA_def_property_clear_flag(..., PROP_EDITABLE)` 之后，`bpy.data.filepath = "x"`
会抛异常。想换文件请用 `bpy.ops.wm.open_mainfile()`。

*推论三：Python 属性名 = RNA 标识符，不是 DNA 字段名。*
RNA 可以给属性起一个和 DNA 字段完全不同的名字。上一条里的
`RNA_def_property_string_funcs()` 就是"值的读写走这两个 C 函数，不走 DNA 字段"的声明。
遇到"我在 `DNA_mesh_types.h` 里看到的字段，Python 里叫另一个名字"，原因就在这里。

*推论四：`bpy.props` 定义的属性在注册时被"翻译"成 RNA 属性。*
Python 类里的类型注解（`x: bpy.props.IntProperty()`）并不是装饰性的。
`pyrna_deferred_register_class()` 会调用 `typing.get_type_hints()`
把这些注解取出来（#src("source/blender/python/intern/bpy_rna.cc:9368")），
再逐个变成真正的 RNA 属性：

```cpp
// source/blender/python/intern/bpy_rna.cc:9365（节选）
/**
 * Extract "__annotations__" using "typing.get_type_hints" which handles the delayed evaluation.
 */
static int pyrna_deferred_register_class_from_type_hints(StructRNA *srna, PyTypeObject *py_class)
```

这解释了为什么 `bpy.props` 的文档里反复强调"这些函数的参数必须用关键字传递"
（#src("source/blender/python/intern/bpy_props.cc:5866")）—— 它们在注册期被
按名解析，而不是在调用期。

=== 3.2.6 常见问题

#pitfall[
  *易错点一：把 `_bpy_types.py` 里的类当成"可以随意继承的基类"。*
  `bpy.types.Mesh` 是 RNA 类型；`_bpy_types.py:730` 里的 `class Mesh(_types.ID)`
  只是它的一次性实现。你*不能*继承 `bpy.types.Mesh` 来注册一个"新的网格类型"，
  因为 `Mesh` 没有注册回调。
]

#pitfall[
  *易错点二：依赖 `bpy.types.X` 在启动时就存在。*
  类型是惰性生成的。第一次访问某个不常用的类型会触发一次构造，构造期间
  如果 `_bpy_types.py` 的类写错了（缺 `__slots__`、基类不匹配），
  错误只在那一次访问时冒出来，且表现为"这个类型变成了自动生成的版本"。
  开发期建议打开日志分类 `BPY_LOG_RNA`，相关 `CLOG_ERROR` 都在这个分类下。
]

#tip[
  *想看某个属性到底从哪来*：在 RNA 定义文件里搜属性名。例如不确定
  `Object.hide_viewport` 的来源，就在 `source/blender/makesrna/intern/rna_object.cc`
  里搜 `"hide_viewport"`。RNA 里的 `RNA_def_property_ui_text()` 第二个参数就是
  UI 上显示的名字 —— 它和 Python 标识符经常不一样，是搜不到时的另一条线索。
]

== 3.3 数据、上下文与常用模块

这一节介绍每个模块*管什么、用之前必须记住什么*；不逐条罗列它的类、属性与方法。
`bpy` 有几百个类与函数，完整签名与用法示例以官方 API 文档为准 ——
每个模块的链接都列在下面。读完这一节，你应该能回答两个问题：
"遇到一件事该去哪个模块找"，以及"用这个模块之前，有哪些易错点必须先在脑子里过一遍"。

#figure(
  kind: table,
  table(
    columns: (auto, 1fr),
    inset: 5pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*模块*], [*一句话定位*]),
    [`bpy.data`], [所有数据块的入口：`Object`、`Mesh`、`Material`、`Scene`……一个 `.blend` 的全部内容],
    [`bpy.context`], [当前状态：在哪个界面、选中了什么、处在什么模式、活动对象是谁],
    [`bpy.ops`], [调用界面上的命令（菜单里那些操作），行为依赖上下文],
    [`bpy.types`], [所有可注册的类：`Operator`、`Panel`、`Menu`、`PropertyGroup`……],
    [`bpy.props`], [定义属性的类型、默认值与界面元数据],
    [`bpy.path`], [路径处理：解析 `//` 相对路径、取文件名与扩展名],
    [`bpy.utils`], [注册助手：`register_class`、`user_resource`、`blend_paths`……],
    [`bpy.app`], [运行时信息：版本号、是否后台模式、`handlers` 回调与 `bpy.app.timers`],
    [`bpy.msgbus`], [订阅 RNA 属性的变更通知：`subscribe_rna` / `publish_rna` / `clear_by_owner`],
  ),
  caption: [`bpy` 里需要你主动去用的模块。],
) <tbl-bpy-members>

要查某个模块或类的完整签名，看官方 API 文档 —— #weblink("https://docs.blender.org/api/current/")，
一个模块一页。最常查的三页：

- `bpy.data`：#weblink("https://docs.blender.org/api/current/bpy.data.html", label: [数据块 API])
- `bpy.context`：#weblink("https://docs.blender.org/api/current/bpy.context.html", label: [上下文 API])
- `bpy.ops`：#weblink("https://docs.blender.org/api/current/bpy.ops.html", label: [操作符清单])

下面先讲数据块与上下文 —— 这两个是理解其它一切的前提；
再简要过一遍操作符、注册类与属性、几个助手模块，最后介绍一个不属于 `bpy` 的库 `mathutils`。

=== 3.3.1 数据块（ID）是什么

Blender 把所有"可持久化、可命名、可被引用的顶层数据"统称为
#term("数据块", "data-block")，在代码里叫 *ID*。对象、网格、材质、场景、
图像、动作、集合、世界、文本……都是 ID。

ID 的 RNA 定义在 #src("source/blender/makesrna/intern/rna_ID.cc:2388")：

```cpp
// source/blender/makesrna/intern/rna_ID.cc:2388（节选）
srna = RNA_def_struct(brna, "ID", nullptr);
```

所以 `Object`（`"ID"` 为基类）和 `Mesh`（同样是 `"ID"` 为基类）在 Python 侧
都是 `bpy.types.ID` 的子类。这意味着"两个对象共享同一个网格"这种结构在
API 上是一等公民：#example-file("ch03/shared_mesh.py")

```python
# 完整可运行
import bpy

mesh = bpy.data.meshes.new("Shared")
for name in ("A", "B"):
    ob = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(ob)

print(bpy.data.objects["A"].data is bpy.data.objects["B"].data)  # True
print(bpy.data.objects["A"].data.users)                          # > 1：两个物体共享它
```

`bpy.data.objects.new(name, object_data)` 的第二个参数类型是 `ID`
（#src("source/blender/makesrna/intern/rna_main_api.cc:1020")），不是 `Mesh` ——
这正是"任何 ID 都能当对象数据"的接口体现。

#figure(
  image("../res/fig-outliner-datablocks.png", width: 88%),
  caption: [Outliner 切到 *Blender File* 显示模式，看到的就是「数据块」这一层：`Object`、`Mesh`、`Material`、`Scene` 各自并列成行，而不是嵌套在一起。用本书自己编译的 Blender #blender-display-version 截取（build hash #blender-commit-short）。],
) <fig-outliner-datablocks>

=== 3.3.2 Object 与 data：“壳”与“载荷”

上面那段代码暴露了一个贯穿全书的结构：*`Object` 和 `Mesh` 不是一回事，
它们是两个互相独立的 ID*。可以这样记：*`Object` 是“壳”，`obj.data` 是“载荷”*。

- *壳（`Object`）* 管的是“它在哪、和谁有关系”：变换（`location` / `rotation` /
  `scale`）、父子关系、所属集合、*修改器栈*、可见性与选择状态。
- *载荷（`obj.data`）* 管的是“它长什么样”：网格的顶点 / 边 / 面、曲线的控制点、
  摄像机的焦距、灯光的强度。

两者既然独立，就有两种组合方式：壳可以换载荷（`ob.data = another_mesh`），
一份载荷也可以被多个壳共用（就是上面 `a.data is b.data` 为 `True` 的那种结构）。
界面上叫*关联复制*的那个 `Alt+D`，做的正是后者。

*这个结构有一个每天都在用、却很少被说清楚的推论*：既然修改器栈挂在壳上，
那两个共享同一份网格的对象就可以有*各自不同*的修改器结果。这正是
`Alt+D`（共享载荷）与 `Shift+D`（连壳一起复制）在加上修改器之后表现不同的原因——
它们共享的只是载荷，不共享壳上的修改器列表。

写插件时还有一条实用推论：*`obj.data` 的类型随 `obj.type` 变化*，
不能假定它一定是 `Mesh`。在书中基准版本（Blender #blender-version）上实测默认场景：

```text
Camera       type=CAMERA     data=Camera
Cube         type=MESH       data=Mesh
Light        type=LIGHT      data=PointLight
```

第三行值得留意：RNA 类型叫 `Light`，但 Python 类名是 `PointLight`——
这是 RNA 的子类型机制（§9.4.4 会讲它怎么生成）。空物体更极端：
`type` 是 `EMPTY`，`obj.data` 直接是 `None`。

所以“遍历 `bpy.data.objects` 然后读 `.vertices`”这类写法，
必然在第一个非网格对象上崩掉。正确写法是先判 `ob.type`：
#example-file("ch03/object_data_type.py")

```python
# 完整可运行
import bpy

ob = bpy.context.active_object
if ob is None or ob.data is None:
    print("没有可显示的数据")
elif ob.type == "MESH":
    print("%s 的网格：%d 个顶点" % (ob.name, len(ob.data.vertices)))
else:
    print("%s 的载荷类型是 %s" % (ob.name, type(ob.data).__name__))
```

这条“先看 `ob.type` 再碰 `ob.data`”的习惯，在 C 侧是硬性要求：
第 9 章会看到，源码里必须靠 `ob->type` 才知道该把那个 ID 指针转成哪种结构体。


#figure(
  image("../res/fig-script-editors.png", width: 100%),
  caption: [同一个窗口里摆开三个脚本类编辑器：左下 *Python 控制台*（逐行试验）、右下 *文本编辑器*（写多行脚本）、以及可切换成 *Info* 的区域（操作符的 `report` 输出落在这里）。用本书自己编译的 Blender #blender-display-version 截取（build hash #blender-commit-short）。],
) <fig-script-editors>

=== 3.3.3 顶层入口：`bpy.data` 的集合

`bpy.data` 上可用的集合，全部来自 #src("source/blender/makesrna/intern/rna_main.cc:320")
的 `MainCollectionDef lists[]`。下面是它开头的几项（节选）：

```cpp
// source/blender/makesrna/intern/rna_main.cc:320（节选）
/* Plural must match ID-types in `readblenentry.cc`. */
MainCollectionDef lists[] = {
    {"cameras", "Camera", "rna_Main_cameras_begin", ...},
    {"scenes", "Scene", "rna_Main_scenes_begin", ...},
    {"objects", "Object", "rna_Main_objects_begin", ...},
    {"materials", "Material", "rna_Main_materials_begin", ...},
    {"node_groups", "NodeTree", "rna_Main_nodetrees_begin", ...},
    {"meshes", "Mesh", "rna_Main_meshes_begin", ...},
    {"lights", "Light", "rna_Main_lights_begin", ...},
    {"libraries", "Library", "rna_Main_libraries_begin", ...},
    ...
```

每个条目给出三件事：Python 属性名（复数）、元素类型、迭代器函数名。
*注意 `node_groups` 对应的是 `NodeTree`* —— 名字对不上，这是必须去源码里核对的
典型例子。

除了集合，`BlendData` 还有一个"所有 ID"的只读视图
（#src("source/blender/makesrna/intern/rna_main.cc:630")）：

```cpp
// source/blender/makesrna/intern/rna_main.cc:630（节选）
prop = RNA_def_property(srna, "all_ids", PROP_COLLECTION, PROP_NONE);
RNA_def_property_clear_flag(prop, PROP_EDITABLE);
RNA_def_property_override_clear_flag(prop, PROPOVERRIDE_NO_COMPARISON);
RNA_def_property_struct_type(prop, "ID");
```

`all_ids` 在 C 侧的说明是 `"Read-only list of all IDs listed in Blender data-base"`
（#src("source/blender/makesrna/intern/rna_main.cc:643")），遍历它拿到的每个元素
可能是任意 ID 子类，需要自己按类型分派。

=== 3.3.4 在 `bpy.data` 上创建与删除

数据块的增删是*类型化*的：每个集合有自己的 `new()` / `remove()`。
以对象为例（#src("source/blender/makesrna/intern/rna_main_api.cc:1015")）：

```cpp
// source/blender/makesrna/intern/rna_main_api.cc:1015（节选）
func = RNA_def_function(srna, "new", "rna_Main_objects_new");
RNA_def_function_flag(func, FUNC_USE_REPORTS);
RNA_def_function_ui_description(func, "Add a new object to the main database");
parm = RNA_def_string(func, "name", "Object", 0, "", "New name for the data-block");
RNA_def_parameter_flags(parm, PropertyFlag(0), PARM_REQUIRED);
parm = RNA_def_pointer(func, "object_data", "ID", "", "Object data or None for an empty object");
RNA_def_parameter_flags(parm, PropertyFlag(0), PARM_REQUIRED);
```

网格同理（#src("source/blender/makesrna/intern/rna_main_api.cc:1151")），
而且多了一个 `new_from_object`，可以从一个已有物体（含其求值后几何）反向生成网格：

```cpp
// source/blender/makesrna/intern/rna_main_api.cc:1159（节选）
func = RNA_def_function(srna, "new_from_object", "rna_Main_meshes_new_from_object");
RNA_def_function_ui_description(
    func,
    "Add a new mesh created from given object (undeformed geometry if object is original, and "
    "final evaluated geometry, with all modifiers etc., if object is evaluated)");
```

删除走的是同一个 C 函数 `rna_Main_ID_remove`（#src("source/blender/makesrna/intern/rna_main_api.cc:115")），
它有一个值得注意的前置检查：

```cpp
// source/blender/makesrna/intern/rna_main_api.cc:122（节选）
ID *id = static_cast<ID *>(id_ptr->data);
if (id->tag & ID_TAG_NO_MAIN) {
  BKE_reportf(reports,
              RPT_ERROR,
              "%s '%s' is outside of main database and cannot be removed from it",
              BKE_idtype_idcode_to_name(GS(id->name)),
              id->name + 2);
  return;
}
```

`ID_TAG_NO_MAIN` 的意思是"这个 ID 不属于主数据库"。什么时候会遇到？
*当你对一个来自操作符参数的 ID 调用 `remove()` 时* —— 例如在某个
`bpy.types.Operator` 的 `execute()` 里，`self.some_id` 可能只是一个临时拷贝。
这解释了一类很常见的报错。

`do_unlink` 与 `do_id_user` 两个参数决定了删除的激进程度。对象版的定义是
（#src("source/blender/makesrna/intern/rna_main_api.cc:1033")）：

```cpp
// source/blender/makesrna/intern/rna_main_api.cc:1033（节选）
RNA_def_boolean(
    func, "do_unlink", true, "", "Unlink all usages of this object before deleting it");
RNA_def_boolean(func,
                "do_id_user",
                true,
                "",
                "Decrement user counter of all data-blocks used by this object");
RNA_def_boolean(
    func, "do_ui_user", true, "", "Make sure interface does not reference this object");
```

#warn[
  `do_unlink=True` 是默认值，也是"删一个物体顺手把它引用的网格也带走"的原因。
  只想解除关联、不想删除数据块时，不要用 `remove()` —— 从集合里把对象移除
  （`bpy.data.objects.remove(ob, do_unlink=False)`）仍然会删掉对象本身；
  要保留对象，应该改它的 `users_collection`，或直接清掉
  `Scene.collection.objects` 里的引用。
]

=== 3.3.5 层级：从文件到顶点

Blender 的数据组织是一条清晰的树，Python 侧每一步都是一次属性访问：
#example-file("ch03/data_hierarchy.py")

```python
# 完整可运行：打印一条从文件到顶点的路径
import bpy

scene = bpy.context.scene                      # bpy.types.Scene
view_layer = bpy.context.view_layer            # bpy.types.ViewLayer
collection = scene.collection                  # bpy.types.Collection
ob = collection.objects[0]                     # bpy.types.Object
mesh = ob.data                                 # bpy.types.Mesh
print(len(mesh.vertices), len(mesh.polygons), len(mesh.materials))
```

这条链上的每一层都有明确的 RNA 归属：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*Python 表达式*], [*RNA 类型*], [*说明*]),
    [`bpy.data`], [`BlendData`], [整份 `.blend` 的根（#src("source/blender/makesrna/intern/rna_main.cc:554")）],
    [`bpy.data.scenes[...]`], [`Scene`], [一个场景；`Scene` 是 ID，可被链接],
    [`scene.collection`], [`Collection`], [场景的主集合，集合可嵌套],
    [`scene.collection.objects`], [`CollectionObjects`], [集合里的对象引用，不是对象本身],
    [`view_layer`], [`ViewLayer`], [场景的"一层"视图；选中状态与可见性挂在这里],
    [`ob.data`], [`ID`], [对象的数据块指针；RNA 声明为 `ID`，运行时可能是 `Mesh` / `Curve` / …],
    [`mesh.vertices`], [`MeshVertices`], [顶点集合，元素是 `MeshVertex`],
    [`mesh.materials`], [`IDMaterials`], [材质槽列表，元素是 `Material` 或 `None`],
  ),
  caption: [从文件到顶点的层级。`ID` 一栏是 RNA 声明的类型；实际类型由对象本身决定。],
) <tbl-data-hierarchy>

注意第 5 行：*选中状态不在 `Object` 上，而在 `ViewLayer` 上*。这是下一节的主角。

=== 3.3.6 集合对象：`bpy_prop_collection` 的语义

`bpy.data.objects`、`mesh.vertices`、`mesh.materials` 都是
`bpy_prop_collection` 的实例（#src("source/blender/python/intern/bpy_rna.cc:7719")）。
它的行为有两处和普通 Python 容器不一样，值得单独记住。

*第一，比较是按值语义做的。* `bpy.data.objects["A"] == bpy.data.objects["A"]` 为真，
但每次取出来的都是*新的包装对象*。判等由 `pyrna_struct_richcmp()`
（#src("source/blender/python/intern/bpy_rna.cc:981")）按内部指针比较，
而不是按 Python 身份。

*第二，不是所有集合都能 `new()`。* 只有 `ID` 类型的集合有增删方法。
`mesh.vertices` 这类几何集合没有 `new()` —— 想加顶点必须走
`mesh.from_pydata()` 或 `bmesh`。

顺便记住 `bpy.data` 上几个只有 C 侧才有的方法。它们不是在 `rna_*.cc` 里定义的，
而是在 `source/blender/python/intern/bpy_rna_id_collection.cc` 里，由
`BPY_rna_types_extend_capi()` 挂到 `BlendData` 类型上
（#src("source/blender/python/intern/bpy_rna_types_capi.cc:204")）：

```cpp
// source/blender/python/intern/bpy_rna_types_capi.cc:204（节选）
/* BlendData */
ARRAY_SET_ITEMS(pyrna_blenddata_methods,
                BPY_rna_id_collection_user_map_method_def,
                BPY_rna_id_collection_file_path_map_method_def,
                BPY_rna_id_collection_file_path_foreach_method_def,
                BPY_rna_id_collection_batch_remove_method_def,
                BPY_rna_id_collection_orphans_purge_method_def,
                BPY_rna_data_context_method_def);
BLI_STATIC_ASSERT(ARRAY_SIZE(pyrna_blenddata_methods) == 7, "Unexpected number of methods")
pyrna_struct_type_extend_capi(RNA_BlendData, pyrna_blenddata_methods, nullptr);
```

这六个方法里最常用的两个是 `orphans_purge()` 和 `batch_remove()`。
下面的示例会清理当前文件中的所有孤立数据，运行前应先保存工作：
#example-file("ch03/orphan_cleanup.py")

```python
# 完整可运行：清理孤立数据块
import bpy

# 先制造一个孤儿网格
mesh = bpy.data.meshes.new("Orphan")
mesh.name = "DefinitelyOrphan"
print("孤儿数（含已有）:", len(bpy.data.meshes))
removed = bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)
print("已删除 ID 数:", removed)
```

`orphans_purge()` 的签名在文档字符串里写得很明确
（#src("source/blender/python/intern/bpy_rna_id_collection.cc:1053")）：
`orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=False)`，
返回删除的 ID 个数。

#pitfall[
  `bpy.data.orphans_purge()` 是*破坏性*操作，而且它删的不只是"你刚造的那个孤儿"。
  任何 `users == 0` 的数据块都会被删，包括那些你打算稍后再用的中间结果。
  在 addon 代码里调用它之前，确认自己没有持有需要保留的中间数据块 ——
  或者先用 `bpy.data.user_map()` 查一遍谁引用了谁。
]

=== 3.3.7 上下文（context）与选择状态

`bpy.data` 回答"文件里有什么"，`bpy.context` 回答"用户此刻在哪里、手里拿着什么"。
写插件时这两个入口几乎总是一起出现：前者给你对象，后者告诉你用户想让这个对象
发生什么。

这一小组讲清三件事：`context` 的结构为什么"时有时无"、选择状态到底存在哪里
（它不在 `context` 里），以及在不需要界面的场合（后台运行、批处理、测试）
该怎么绕开它。

==== `bpy.context` 是什么

`bpy.context` 是一个 `bpy.types.Context` 实例，它内部直接持有一个活的
`bContext*`。创建它的是 `BPy_init_modules()`（#src("source/blender/python/intern/bpy.cc:828")）：

```cpp
// source/blender/python/intern/bpy.cc:828（节选）
PointerRNA ctx_ptr = RNA_pointer_create_discrete(nullptr, RNA_Context, C);
bpy_context_module = reinterpret_cast<BPy_StructRNA *>(pyrna_struct_CreatePyObject(&ctx_ptr));
PyModule_AddObject(mod, "context", reinterpret_cast<PyObject *>(bpy_context_module));
```

而 `BPY_context_get()` 读的正是这份指针
（#src("source/blender/python/intern/bpy_interface.cc:292")）：

```cpp
// source/blender/python/intern/bpy_interface.cc:292（节选）
bContext *BPY_context_get()
{
  return static_cast<bContext *>(bpy_context_module->ptr->data);
}

void BPY_context_set(bContext *C)
{
  bpy_context_module->ptr->data = static_cast<void *>(C);
}
```

*`bpy.context` 是一扇窗，不是一张快照。* 窗口里的内容随用户操作实时变化。

==== 固定成员与动态成员

`Context` 的 RNA 定义（#src("source/blender/makesrna/intern/rna_context.cc:258")）
声明的是一批"固定成员"，就是那些永远存在的槽位：

```cpp
// source/blender/makesrna/intern/rna_context.cc:263（节选）
prop = RNA_def_property(srna, "window_manager", PROP_POINTER, PROP_NONE);
RNA_def_property_clear_flag(prop, PROP_EDITABLE);
RNA_def_property_struct_type(prop, "WindowManager");
RNA_def_property_pointer_funcs(prop, "rna_Context_manager_get", nullptr, nullptr, nullptr);
```

`window_manager`、`window`、`workspace`、`screen`、`area`、`space_data`、
`region`、`region_popup`、`region_data`、`gizmo_group`、`blend_data`、`scene`、
`view_layer`、`engine`、`collection`、`layer_collection`、`tool_settings`、
`preferences`、`mode` —— 这些都在 `rna_context.cc` 里显式定义。

但 `bpy.context.selected_objects` 不在这份清单里。它是*动态成员*，
由各个编辑器通过"context 回调表"注册进来的。屏幕相关的成员在
#src("source/blender/editors/screen/screen_context.cc:62")：

```cpp
// source/blender/editors/screen/screen_context.cc:62（节选）
const char *screen_context_dir[] = {
    "scene",
    "view_layer",
    "visible_objects",
    "selectable_objects",
    "selected_objects",
    "editable_objects",
    "selected_editable_objects",
    "objects_in_mode",
    "objects_in_mode_unique_data",
    ...
    "active_object",
    "object",
    "edit_object",
    ...
```

对应的回调登记在第 1196 行开始的 `ensure_ed_screen_context_functions()` 里：

```cpp
// source/blender/editors/screen/screen_context.cc:1196（节选）
static const Map<StringRef, context_callback> &ensure_ed_screen_context_functions()
{
  static Map<StringRef, context_callback> screen_context_functions = []() {
    Map<StringRef, context_callback> map;
    map.add("scene", screen_ctx_scene);
    map.add("visible_objects", screen_ctx_visible_objects);
    map.add("selectable_objects", screen_ctx_selectable_objects);
    map.add("selected_objects", screen_ctx_selected_objects);
    ...
    map.add("active_object", screen_ctx_active_object);
    map.add("object", screen_ctx_object);
    ...
```

这条链在 Python 侧的落点是 `BPY_context_member_get()`
（#src("source/blender/python/intern/bpy_interface.cc:879")）：

```cpp
// source/blender/python/intern/bpy_interface.cc:879（节选）
bool BPY_context_member_get(bContext *C, const char *member, bContextDataResult *result)
{
  ...
  pyctx = static_cast<PyObject *>(CTX_py_dict_get(C));
  item = PyDict_GetItemString(pyctx, member);

  if (item == nullptr) {
    /* Pass. */
  }
  else if (item == Py_None) {
    done = true;
  }
  else if (BPy_StructRNA_Check(item)) {
    ptr = &reinterpret_cast<BPy_StructRNA *>(item)->ptr.value();
    CTX_data_pointer_set_ptr(result, ptr);
    CTX_data_type_set(result, ContextDataType::Pointer);
    done = true;
  }
  ...
```

注意最前面那三行：*Python 侧的覆盖字典优先于 C 侧回调*。这是
`context.temp_override()` 能生效的原因。

为什么要有"动态成员"这一层？因为同一个名字在不同编辑器里含义不同。
`bpy.context.active_object` 在 3D 视图和在大纲视图里解析出的对象可能不一样，
而"哪个编辑器说了算"这件事只能由当前 `area` 决定。固定成员装不下这种语义。

==== 选择状态在哪里

这是本节最实用的一条。*"选中"不是 `Object` 的固有属性。*
在 Blender 5.2 里，选择状态挂在 `ViewLayer` 上：每个 `ViewLayer` 有一份
`objects` 集合，元素是 `ObjectBase`，而 `select` 标志在 `ObjectBase` 上。

所以同一个对象可以在两个 view layer 里一个选中、一个未选中。这直接决定了
下面三种写法的差别：#example-file("ch03/selection_states.py")

```python
# 完整可运行：三种"选中"的读法
import bpy

# 1) 从 context 读，走屏幕上下文回调，受当前编辑器影响
print([ob.name for ob in bpy.context.selected_objects])

# 2) 从 view layer 读，不经过 context，稳定
view_layer = bpy.context.view_layer
print([ob.name for ob in view_layer.objects if ob.select_get()])

# 3) 读"活动对象"——同样有两个来源
print(bpy.context.view_layer.objects.active)
print(bpy.context.active_object)
```

#tip[
  在 addon 的操作符里，*优先用 `view_layer` 而不是 `context`*。原因有二：
  `context` 的成员依赖当前 `area`（后台运行时可能全是 `None`）；
  `view_layer` 是操作符本来就该操作的那份数据，语义更明确。
  需要 `context` 时，用 `context.view_layer` 或显式传入的 `context`，
  不要用全局的 `bpy.context`。
]

`view_layer.objects.active` 和 `context.active_object` 的关系需要说清楚：
前者是 `ViewLayer` 上的 RNA 属性，后者是屏幕上下文回调算出来的。两者在
3D 视图里通常一致，但它们的*失效条件不一样*。后台（`--background`）运行时，
`context.window` 是 `None`，屏幕上下文回调拿不到 `area`，`context.active_object`
就可能取不到值。

==== `context.temp_override()`

从 Blender 3.2 起，改写上下文的官方方式是 `context.temp_override()`。
它的实现在 #src("source/blender/python/intern/bpy_rna_context.cc:711")：

```cpp
// source/blender/python/intern/bpy_rna_context.cc:711（节选）
static PyObject *bpy_context_temp_override(PyObject *self, PyObject *args, PyObject *kwds)
{
  const PointerRNA *context_ptr = pyrna_struct_as_ptr(self, RNA_Context);
  ...
  static const char *const _keywords[] = {
      "window",
      "screen",
      "area",
      "region",
      nullptr,
  };
  ...
  /* Parse known keywords, the remaining keywords are set using #CTX_py_state_push. */
  kwds = kwds ? PyDict_Copy(kwds) : PyDict_New();
```

四个已知关键字是 `window` / `screen` / `area` / `region`；*其余任意关键字
都被当作 context 成员覆盖*。文档字符串里对 `screen` 有一条专门的警告
（#src("source/blender/python/intern/bpy_rna_context.cc:700")）：

```
   ... than other arguments as it will also change the works-space
   and potentially the scene (when pinned).
```

用法是上下文管理器：#example-file("ch03/context_override.py")

```python
# 完整可运行：在后台运行时"伪造"一个 3D 视图上下文
import bpy

area = next((a for w in bpy.context.window_manager.windows
             for a in w.screen.areas if a.type == 'VIEW_3D'), None)
if area is not None:
    with bpy.context.temp_override(area=area, region=next(iter(area.regions))):
        # 这里的 bpy.context.area 指向被覆盖的 area
        print(bpy.context.area.type)
else:
    print("没有 3D 视图（后台模式下属正常）")
```

#warn[
  `temp_override()` 只在 `with` 块内有效，且*不要*把块内的 `context`
  保存下来跨块使用。覆盖在退出时会被弹掉，保存下来的引用会指向已经失效的
  状态。
]

==== 怎么在 addon 里写"上下文无关"的代码

把上面几点合起来，就是一条可执行的原则：

1. 操作符的 `execute(self, context)` 里的 `context` 参数，永远优先于
   全局 `bpy.context`。前者是 Blender 传进来的、语义明确的那个。
2. 要读选中集合，用 `context.selected_objects`（它已经处理好了 view layer）。
3. 要读某个特定 view layer 的状态，直接走 `context.view_layer`。
4. 需要界面上不存在的 `area` 时，用 `temp_override()` 显式造一个，
   并在 `with` 块里完成全部工作。
5. 需要在没有界面的环境下工作（后台渲染、`--background` 脚本）时，
   不要依赖任何 `context.window` / `context.area` / `context.region`。

#pitfall[
  *"在我这儿能跑"的上下文 bug。* 一段用了 `bpy.context.area.type` 的代码，
  在脚本编辑器里跑没问题，装成 addon 后在面板按钮里点就可能崩 ——
  因为那时的 `area` 不是脚本编辑器。凡是读了 `area` / `region` / `space_data`
  的代码，都必须假设它们可能是 `None`。
]

=== 3.3.8 操作符：`bpy.ops`

你在界面上点的每一个菜单项、按的每一个快捷键，背后都是一个*操作符*。
Python 侧用 `bpy.ops.<类别>.<名字>()` 调用它，例如 `bpy.ops.mesh.primitive_cube_add()`。

两条必须记住的语义：

1. *它依赖上下文*。同一个操作符在不同编辑器、不同模式下行为不同，甚至直接
   `poll()` 失败并报 `context is incorrect`。这也是下一节要讲 `temp_override()` 的原因。
2. *它返回一个集合*。`{'FINISHED'}` 表示执行成功，`{'CANCELLED'}` 表示被中止。
   想知道"到底做没做成"，就要看这个返回值，而不是猜。

有哪些操作符、各自参数是什么，官方文档按类别列全了（`bpy.ops.mesh.*`、
`bpy.ops.object.*`……）。而操作符的完整机制 —— `poll` / `invoke` / `exec`、
撤销、`report` —— 第 5 章讲 Python 侧怎么写，第 11 章讲 C++ 侧的 `wmOperatorType`。

=== 3.3.9 注册类与属性：`bpy.types` 与 `bpy.props`

`bpy.types` 是"所有能被注册的东西"的命名空间：`Operator`、`Panel`、`Menu`、
`Header`、`UIList`、`PropertyGroup`、`AddonPreferences`……写插件做的事，
本质上就是*继承其中一个、写几个方法、然后注册它*。

`bpy.props` 负责"属性长什么样"：类型（`BoolProperty`、`IntProperty`、`EnumProperty`、
`PointerProperty`、`CollectionProperty`……）、默认值、取值范围，以及界面上怎么显示、
鼠标悬停时显示什么。

这两者合起来是插件的地基：第 4 章讲注册机制与生命周期，第 5 章讲属性与界面。
这里只需记住一点 —— *`bpy.props` 定义的不是"值"，而是"这个值该怎么用"*：
真正的数据存在类的实例里，属性定义只是规则。

=== 3.3.10 助手模块：`bpy.path`、`bpy.utils`、`bpy.app`

这三个小模块平时不起眼，但插件的"工程性"部分几乎都靠它们：

- `bpy.path`：处理 `.blend` 里的相对路径（`//` 开头）与跨平台路径拼接；
- `bpy.utils`：`register_class` / `unregister_class`、`user_resource`（定位用户的脚本
  与配置目录）、`blend_paths`（列出 `.blend` 依赖的所有外部文件）；
- `bpy.app`：版本号、是否处于后台模式，以及 `handlers`（事件回调）与 `bpy.app.timers`（定时器）。

补充一句关于*编辑器空间*：如果你要碰"某个编辑器当前显示什么"，入口是
`context.space_data`，它的类型是 `bpy.types.Space` 的某个子类（`SpaceView3D`、
`SpaceNodeEditor`……）。但*新增*一种编辑器类型在 Python 侧做不到 —— 那是 C++ 的事，
见第 12 章的 `SpaceType`。这里只需要知道入口在哪。

=== 3.3.11 数学库：`mathutils`

`mathutils` *不属于 `bpy`* —— 它是一个独立的模块，要自己 `import`，专管几何与变换
的数学：`Vector`、`Matrix`、`Quaternion`、`Euler`、`Color`。
官方文档单独一页：#weblink("https://docs.blender.org/api/current/mathutils.html", label: [mathutils 文档])。

它值得单独说一句，是因为*运算符被重载了*，写起来接近数学本身：两个 `Vector`
相加就是逐分量相加，`matrix @ vector` 就是变换一个点，`quat @ quat` 就是复合旋转。
它还支持原地操作（`v += w`）和 `foreach_*` 批量接口 —— 后者是第 6 章讲性能时的主要工具。

两个容易踩的地方：Blender 内部一律用*弧度*而不是角度；`Matrix` 到底是 4×4
（含平移）还是 3×3（纯方向/缩放），代码里必须自己拎清，因为两者在 API 上长得一样。

=== 3.3.12 常见问题

下面是本节最容易出问题的地方，主要涉及 `bpy.data` 与对象数据；
`bpy.context`、`bpy.ops`、`bpy.props` 与 `mathutils` 的易错点写在各自小节里。

#pitfall[
  *引用失效。* 数据块被删除或文件被重新加载后，你手里那个 Python 对象会变成
  "失效引用"。此后任何属性访问都会抛 `ReferenceError`。RNA 层的实现是
  `pyrna_struct_validity_check()`（#src("source/blender/python/intern/bpy_rna.cc:189")）。
  在 addon 里长期持有对象引用是不安全的做法；持有 *名字*，用的时候再查，
  是更稳的模式。
]

#tip[
  *数据块名字是唯一的。* `bpy.data.objects.new("Cube", None)` 在已有 `"Cube"` 时
  会得到 `"Cube.001"`。不要假设 `new()` 之后名字就是你传进去的那个；
  用返回值，或者事后读 `ob.name`。
]

== 3.4 本章小结

- `bpy` 的九个顶层成员里，只有 `ops` / `path` / `utils` 是磁盘上的 Python 包；
  `data` 与 `context` 是 RNA 结构的实例，`types` / `props` / `app` / `msgbus` 是 C 模块。
- RNA 是唯一的元数据来源。`makesrna` 不碰 Python；Python 绑定全在
  `source/blender/python/intern/`。
- `bpy.types.X` 的类按需生成，查找顺序是"缓存 → `_bpy_types.py` 手工类 →
  C 侧现造"。手工类必须有 `__slots__`，且第一个基类必须匹配 RNA 基类。
- 能否注册子类，取决于 RNA 结构有没有 `register` 回调。可注册类型只有十六个。
- `bpy.data` 的集合清单由 `rna_main.cc` 的 `MainCollectionDef lists[]` 决定；
  集合名与元素类型名并不总是一致（`node_groups` → `NodeTree`）。
- 选择状态在 `ViewLayer` 的 `ObjectBase` 上，不在 `Object` 上；
  `context.selected_objects` 与 `view_layer.objects` 是两条不同的读取路径。
- `context.temp_override()` 的四个已知关键字是 `window`/`screen`/`area`/`region`，
  其余关键字直接覆盖 context 成员。

#exercise[
  *练习 3.1（自省）* 写一段脚本，遍历 `bpy.data.all_ids`，按 `bl_rna.identifier`
  统计当前文件里每种 RNA 类型各有多少个数据块，按数量降序打印。
  提示：`all_ids` 的说明见 #src("source/blender/makesrna/intern/rna_main.cc:643")。

  *练习 3.2（核实）* 用 grep 在 `source/blender/makesrna/intern/rna_object.cc`
  里找出 `Object` 的 `mode` 属性的定义（提示：搜 `RNA_def_property(srna, "mode"`），
  记录它的行号、属性类型、枚举项数组名，以及它是否可写。
  再用 Python 打印 `bpy.data.objects[0].bl_rna.properties["mode"]` 的类型与
  取值集合，对照源码确认两者一致。

  *练习 3.3（惰性生成）* 在 Blender 里先后执行这两行，比较结果并解释：

  ```python
  import bpy
  print(len(bpy.types.ID.__subclasses__()))   # 第一次
  bpy.types.Mesh                              # 触发一次 pyrna_srna_Subtype()
  print(len(bpy.types.ID.__subclasses__()))   # 第二次
  ```

  提示一：`dir(bpy.types)` 走的是 `bpy_types_module_dir()`
  （#src("source/blender/python/intern/bpy_rna.cc:8992")），它把 RNA 结构集合
  与模块 `__dict__` 合在一起列出 —— 所以*每个* RNA 类型都在里面。
  而 Python 的 `ID.__subclasses__()` 只反映*已经实际构造出来的* Python 类。
  为什么两条路径给出的集合不同？

  提示二：读一下 `BPY_rna_types_finalize_external_types()` 的注释
  （#src("source/blender/python/intern/bpy_rna.cc:9101")）。它解释了
  "没有 `bl_rna` 的半初始化类"是怎么出现的，以及为什么只靠
  `__subclasses__()` 遍历 RNA 类型是不可靠的做法。

  *练习 3.4（上下文）* 写一个 addon，在 `View3D` 的头部菜单里加一项，
  点击后打印 `bpy.context.area.type`、`bpy.context.region.type` 与
  `len(bpy.context.selected_objects)`。再在同一个 addon 里加一条
  `--background` 下运行的测试命令，观察哪些值为 `None`，并据此把读
  `area` 的代码改成先判断再使用。
]
