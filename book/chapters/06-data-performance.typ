#import "../common.typ": *
#import "../figures/when-to-drop.typ": fig-when-to-drop

= 第 6 章 数据操作与性能

第 3 章讲的是 `bpy` 这套 API 长什么样，第 5 章讲的是怎么让用户触发它。
本章讲第三件事：*当你真的开始读写大量数据时，哪些写法快、哪些写法慢、
以及慢了之后该怎么办。*

这一章在三章里最「工程化」。它给的每一条建议都配了测量方法，
因为这一章的主题本身就是「不要猜」。

#figure(
  kind: table,
  table(
    columns: (1.4fr, 3.2fr, 2.0fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*主题*], [*本篇的核心问题*], [*章节*]),
    [网格数据], [`Mesh` 与 `bmesh` 各是什么、什么时候用哪个], [§6.1],
    [批量读写], [`foreach_get` / `foreach_set` 为什么快、什么时候不生效], [§6.2],
    [其他数据类型], [曲线、材质、节点树、集合、自定义属性的读写入口], [§6.3],
    [性能分析], [Python 慢在哪、怎么用 `cProfile` 找到真凶], [§6.4],
    [动画与渲染], [动画数据、驱动、`bpy.ops.render`、`RenderEngine`], [§6.5],
    [原生加速], [用 Rust / C / C++ 写 C ABI 动态库并接进 addon], [§6.6],
  ),
  caption: [本章路线。三节深挖内容按「定义 → 为什么这么设计 → 在源码哪里 → 怎么用 → 常见问题」展开。],
) <tbl-ch6-roadmap>

== 6.1 网格数据：`bpy.types.Mesh` 与 `bmesh`

=== 6.1.1 两套并存的网格表示

Blender 里「网格」这个概念有两套不同的数据结构，它们的用途几乎没有重叠：

- *`bpy.types.Mesh`（C 侧 `Mesh` 结构体）*：网格在 `.blend` 文件里的
  持久化形式，也是依赖图求值、修改器、渲染所消费的形式。它是*只读友好*的：
  可以改顶点坐标、可以换属性数据，但*不能*在这里做拓扑操作
  （连边、切面、挤出）。
- *`bmesh`（C 侧 `BMesh`）*：一个完全独立的内存结构，专门为*拓扑编辑*设计。
  它有显式的顶点/边/面/环四层结构、有邻接关系、有一整套算子（operator）。
  它*不是*网格数据块，必须先转成 `Mesh` 才能挂到物体上。

选择规则很简单：

#summary[
  只要改坐标、改属性，用 `Mesh` + `foreach_get` / `foreach_set`；
  只要改*拓扑*（增删顶点、连边、切分面、挤出），用 `bmesh`。
  不要用 `bmesh` 去做「把所有顶点沿法线推 0.1 米」这种纯数据工作 ——
  转换本身就是纯开销。
]

=== 6.1.2 `Mesh` 的结构：从 DNA 到通用属性

先看 DNA。`Mesh` 的定义在 #src("source/blender/makesdna/DNA_mesh_types.h:144")，
它现在的样子和十年前很不一样：

```cpp
// source/blender/makesdna/DNA_mesh_types.h:144（节选）
struct Mesh {
  ID id;
  struct AnimData *adt = nullptr;
  struct Key *key = nullptr;
  struct Material **mat = nullptr;

  /** The number of vertices in the mesh, and the size of #vert_data. */
  int verts_num = 0;
  /** The number of edges in the mesh, and the size of #edge_data. */
  int edges_num = 0;
  /** The number of faces in the mesh, and the size of #face_data. */
  int faces_num = 0;
  /** The number of face corners in the mesh, and the size of #corner_data. */
  int corners_num = 0;

  /**
   * Array owned by mesh. See #Mesh::faces() and #OffsetIndices.
   */
  int *face_offset_indices = nullptr;

  /**
   * Vertex, edge, face, and corner generic attributes.
   */
  struct AttributeStorage attribute_storage;

  /** Store for non-generic layer data on each domain. */
  CustomData vert_data;
  CustomData edge_data;
  CustomData face_data;
  ...
};
```

这段定义里最值得注意的是*没有的东西*：没有 `MVert *mvert`，
没有 `MLoop *mloop`，没有 `MPoly *mpoly`。它们全部被
`attribute_storage`（通用属性）+ `face_offset_indices`（面偏移表）取代了。
旧结构仍然在 #src("source/blender/makesdna/DNA_meshdata_types.h:392")（`MVert`）、
#src("source/blender/makesdna/DNA_meshdata_types.h:352")（`MPoly`）、
#src("source/blender/makesdna/DNA_meshdata_types.h:411")（`MLoop`）里，
但注释明确写着它们只用于读写旧文件：

```cpp
// source/blender/makesdna/DNA_meshdata_types.h:389（节选）
/**
 * Deprecated mesh vertex data structure. Now stored with generic attributes.
 */
struct MVert { ... };
```

顶点坐标现在的实际存放位置，可以从 RNA 的迭代器读出来
（#src("source/blender/makesrna/intern/rna_mesh.cc:1583")）：

```cpp
// source/blender/makesrna/intern/rna_mesh.cc:1583（节选）
static void rna_Mesh_vertices_begin(CollectionPropertyIterator *iter, PointerRNA *ptr)
{
  Mesh *mesh = rna_mesh(ptr);
  rna_iterator_array_begin(iter,
                           ptr,
                           mesh->vert_positions_for_write().data(),
                           sizeof(float3),
                           mesh->verts_num,
                           false,
                           nullptr);
}
```

三件事同时被确认了：

1. 顶点坐标是一段*连续的* `float3` 数组（`vert_positions_for_write()`）；
2. 每一项的步长是 `sizeof(float3)`，即 12 字节；
3. 因此内存布局就是 `[x0 y0 z0 x1 y1 z1 ...]`，与 `numpy` 的
   `(n, 3) float32` 数组完全兼容。

这就是 §6.2 的基础。

=== 6.1.3 Python 侧能做什么

`bpy.types.Mesh` 在 Python 层的补充实现很短
（#src("scripts/modules/_bpy_types.py:730")），只加了少量便利方法。
真正可用的成员来自 RNA。下表列出最常打交道的：

#figure(
  kind: table,
  table(
    columns: (1.9fr, 1.1fr, 3.0fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*类型*], [*说明*]),
    [`vertices`], [集合], [`MeshVertex` 集合，长度 `verts_num`],
    [`edges`], [集合], [`MeshEdge` 集合；每项两个无符号顶点索引],
    [`loops`], [集合], [`MeshLoop` 集合，即「面角」。数量 = 所有面的顶点数之和],
    [`polygons`], [集合], [`MeshPolygon` 集合。`loop_start` / `loop_total` 描述面在 `loops` 中的范围],
    [`loop_triangles`], [集合], [三角化结果。需要 `calc_loop_triangles()` 后有效],
    [`attributes`], [集合], [通用属性组。*新版代码应该优先用它*],
    [`uv_layers`], [集合], [UV 层的便利视图，底层是 `FLOAT2` 属性],
    [`color_attributes`], [集合], [顶点色的便利视图],
    [`vertex_normals`], [`corner_normals`], [`polygon_normals`], [只读集合], [法线缓存，由这些只读集合惰性计算（旧的 `calc_normals_split()` 在 4.1 已移除）],
    [`from_pydata(vertices, edges, faces, shade_flat=True)`], [方法], [从 Python 序列建网格。见下],
    [`validate(...)`], [方法], [修正非法数据。`from_pydata` 之后应当调用],
    [`update(calc_edges=False, calc_edges_loose=False)`], [方法], [重建边索引与内部缓存],
    [`shade_flat()`], [`shade_smooth()`], [方法], [设置 / 清除 `sharp_face` 属性],
    [`vert_positions`（不存在）], [—], [注意：Python 侧*没有*这个名字，用 `vertices` 或 `attributes["position"]`],
  ),
  caption: [`bpy.types.Mesh` 的主要成员，核对自 #src("source/blender/makesrna/intern/rna_mesh.cc:2918") 起],
) <tbl-mesh-members>

关于 `from_pydata`：它的 Python 实现在
#src("scripts/modules/_bpy_types.py:733")，而且*它自己就是用
`foreach_set` 写的*——这是本章最好的第一课：

```python
# scripts/modules/_bpy_types.py:778（节选）
self.vertices.add(vertices_len)
self.edges.add(edges_len)
self.loops.add(sum(face_lengths))
self.polygons.add(faces_len)

self.vertices.foreach_set("co", tuple(chain.from_iterable(vertices)))
self.edges.foreach_set("vertices", tuple(chain.from_iterable(edges)))

vertex_indices = tuple(chain.from_iterable(faces))
loop_starts = tuple(islice(chain([0], accumulate(face_lengths)), faces_len))

self.polygons.foreach_set("loop_start", loop_starts)
self.polygons.foreach_set("vertices", vertex_indices)
```

#pitfall[
  `from_pydata` 的 docstring 里有一条明确的警告
  （#src("scripts/modules/_bpy_types.py:761")）：

  ```text
  Invalid mesh data (out of range indices, edges with matching indices,
  2 sided faces... etc) are **not** prevented.
  ```

  也就是说它会愉快地写入一串越界索引。生产代码里必须跟一句
  `mesh.validate(verbose=False)`，否则后续任何一次 `Mesh` 求值都可能崩溃。
]

=== 6.1.4 `bmesh`：需要拓扑操作时的唯一选择

`bmesh` 是一个完整的 C 扩展模块，入口在
#src("source/blender/python/bmesh/bmesh_py_api.cc:204")：

```cpp
// source/blender/python/bmesh/bmesh_py_api.cc:215（节选）
mod = PyModule_Create(&BPy_BM_module_def);

/* bmesh.types */
PyModule_AddObject(mod, "types", (submodule = BPyInit_bmesh_types()));
/* bmesh.ops (not a real module, exposes module like access). */
PyModule_AddObject(mod, "ops", (submodule = BPyInit_bmesh_ops()));
PyModule_AddObject(mod, "utils", (submodule = BPyInit_bmesh_utils()));
PyModule_AddObject(mod, "geometry", (submodule = BPyInit_bmesh_geometry()));
```

顶层只有三个函数（#src("source/blender/python/bmesh/bmesh_py_api.cc:162") 的方法表）：
`bmesh.new()`、`bmesh.from_edit_mesh(mesh)`、`bmesh.update_edit_mesh(mesh, ...)`。

一个完整的、修完拓扑后写回的工具函数长这样：

```python
import bpy
import bmesh


def bevel_all_edges(obj, offset=0.02):
    """把所有边倒角。返回受影响的边数。"""
    if obj.type != 'MESH':
        raise TypeError("需要一个网格物体")

    mesh = obj.data
    # 1) 从已有网格建 bmesh
    bm = bmesh.new()
    bm.from_mesh(mesh)
    try:
        # 2) 取所有边
        bm.edges.ensure_lookup_table()
        edges = list(bm.edges)
        if not edges:
            return 0

        # 3) 跑算子
        result = bmesh.ops.bevel(
            bm,
            geom=edges,
            offset=offset,
            offset_type='OFFSET',
            segments=2,
            affect='EDGES',
        )
        count = len(result.get("faces", ()))

        # 4) 法线缓存必须手动更新
        bm.normal_update()

        # 5) 写回网格
        bm.to_mesh(mesh)
        mesh.update()
        return count
    finally:
        # 6) 一定要释放！
        bm.free()
```

这段代码里的每一步都有对应的源码依据：

- `bmesh.ops.xxx(bm, **kwargs)` 的调用约定是「一个位置参数 + 其余全为关键字」。
  这一点在 #src("source/blender/python/bmesh/bmesh_py_ops_call.cc:783") 的报错信息里
  写得很直白：

  ```text
  bmesh operators expect a single BMesh positional argument,
  all other args must be keywords
  ```

- 关键字名必须与算子的 slot 名一致。以 `create_cube` 为例，
  它的输入 slot 定义在
  #src("source/blender/bmesh/intern/bmesh_opdefines.cc:2343")：
  `size`、`matrix`、`calc_uvs`，输出是 `verts.out`。
  传错名字会得到 `keyword "xxx" is invalid for this operator`
  （#src("source/blender/python/bmesh/bmesh_py_ops_call.cc:805")）。
- 算子返回一个 `dict`，键是输出 slot 名（`__doc__` 里写明了
  `-> dict(...)`，见 #src("source/blender/python/bmesh/bmesh_py_ops.cc:120")）。
- `ensure_lookup_table()` 是必需的：在索引访问 `bm.verts[i]` 之前
  必须调用它，否则 #src("source/blender/python/bmesh/bmesh_py_types.cc:4458")
  会报 `... run ensure_lookup_table() first`。

#pitfall[
  `bm.free()` 不能省。`BMesh` 不是 Python 对象管理的资源，
  它的内存是 C 侧分配的。忘了释放的表现是内存持续增长，
  而且不会有任何报错。习惯写法是把 `to_mesh` 之后的清理放进 `finally`。
]

#note[
  `bmesh.ops` 不是真正的模块，是「像模块一样暴露的对象」
  （源码注释：`/* bmesh.ops (not a real module, exposes module like access). */`，
  #src("source/blender/python/bmesh/bmesh_py_api.cc:221")）。
  因此 `import bmesh.ops` 是*错的*，必须先 `import bmesh` 再用 `bmesh.ops`。
]

#exercise[
  *练习 6.1* 用两套 API 做同一件事并对比：

  1. 用 `bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32)`
     建一个球，记录 `len(mesh.vertices)`；
  2. 用 `bmesh` 把它整体放大 1.5 倍（所有顶点坐标乘 1.5），
     打印 `bm.verts` 的数量，确认拓扑没变；
  3. 用 `bmesh.ops.triangulate` 把所有面三角化，记录面数的变化
     （三角化后面数应该等于三角数）；
  4. 尝试用 `Mesh` 直接删掉一个顶点（你会发现做不到），
     记下你为了做到这件事最终必须调用哪个 `bmesh.ops`。
]

== 6.2 批量数据读写：`foreach_get` / `foreach_set`

=== 6.2.1 定义

`foreach_get(attr, seq)` 与 `foreach_set(attr, seq)` 定义在
*RNA 集合*与*RNA 数组*两种对象上，作用是把集合中每一项的某个
「基本类型属性」一次性读进 / 写入一段连续内存。

它最反直觉的特点不是「快」，而是*签名里没有「逐项」这个概念*：

```python
# 读：把 n 个顶点的 co（每项 3 个 float）拍平写进 buf
mesh.vertices.foreach_get("co", buf)      # buf 长度必须是 n * 3

# 写：把 buf 里的值拍平写回
mesh.vertices.foreach_set("co", buf)
```

传入的不是「一个顶点的坐标」，而是*整个属性的扁平化数组*。
这就是它能绕开 Python 对象的原因。

=== 6.2.2 为什么这么设计

如果没有它，读一次顶点坐标只能这样写：

```python
# 慢：每个顶点都会创建一个 MeshVertex 对象，每次 .co 都会创建一个 float 数组
coords = [0.0] * (len(mesh.vertices) * 3)
for i, v in enumerate(mesh.vertices):
    coords[i * 3:i * 3 + 3] = v.co
```

这条路径上有 *两次* Python 堆分配 + 一次 Python 循环迭代，
每次迭代都要穿过一次 RNA 属性解析。30 万个顶点时它是 0.185 秒（见下文实测），
而 `foreach_get` 把同样的工作做到 0.0106 秒。

设计动机写在这两个函数的 docstring 里
（#src("source/blender/python/intern/bpy_rna.cc:6193")）：

```text
.. method:: foreach_get(attr, seq)

   Fast access to a basic-type attribute within a collection.

   :param attr: Name of the item attribute to read (for example ``co``, ``normal`` or
      ``select``). The attribute must be a basic type (bool, int or float).
```

「basic type」这个限定是关键：只有 `bool` / `int` / `float` 三种
（以及它们的定长数组）能走这条路。字符串、指针、集合都不行 ——
RNA 里 `rna_raw_access` 对类型做了硬检查
（#src("source/blender/makesrna/intern/rna_access.cc:5536")）：

```cpp
// source/blender/makesrna/intern/rna_access.cc:5536（节选）
if (!ELEM(itemtype, PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_ENUM)) {
  BKE_report(reports, RPT_ERROR, "Only boolean, int, float, and enum properties supported");
  return 0;
}
```

=== 6.2.3 在源码哪里：三层实现与三条路径

这是本节最重要的一段，因为它解释了「为什么有时候很快，有时候没那么快」。

*第一层*：Python 方法入口。`foreach_get` / `foreach_set` 注册在
`BPy_PropertyRNA` 的方法表里（#src("source/blender/python/intern/bpy_rna.cc:6626")），
实现是 `pyrna_prop_collection_foreach_get` / `..._set`
（#src("source/blender/python/intern/bpy_rna.cc:6206")、
#src("source/blender/python/intern/bpy_rna.cc:6228")），
两者都转发给同一个函数 `foreach_getset`
（#src("source/blender/python/intern/bpy_rna.cc:5975")）。

*第二层*：`foreach_getset` 里有一个三岔口。写成伪代码：

```text
foreach_getset(self, args, set):
    # 1. 用 foreach_parse_args 取 attr / seq / 长度 / 原始类型
    # 2. 如果 seq 支持 buffer 协议（numpy 数组、array.array、memoryview）：
    #      取 buffer -> foreach_compat_buffer 判断类型是否匹配
    #      - 匹配  -> RNA_property_collection_raw_get/set(...)    ← 最快
    #      - 不匹配 -> 落回序列路径
    # 3. 序列路径：
    #      分配 C 临时数组 -> RNA_property_collection_raw_get/set
    #      -> 逐项把 C 值转成 Python 对象（或反向）
```

对应源码里两处 `PyObject_CheckBuffer`
（#src("source/blender/python/intern/bpy_rna.cc:6010") 与
#src("source/blender/python/intern/bpy_rna.cc:6086")），
以及降级后的逐项循环（#src("source/blender/python/intern/bpy_rna.cc:6035")
与 #src("source/blender/python/intern/bpy_rna.cc:6120")）。

类型匹配的判断函数是 `foreach_compat_buffer`
（#src("source/blender/python/intern/bpy_rna.cc:5922")）：

```cpp
// source/blender/python/intern/bpy_rna.cc:5946（节选）
case PROP_RAW_INT:
  if (attr_signed) {
    return (f == 'i') ? true : false;
  }
  else {
    return (f == 'I') ? true : false;
  }
```

`f` 是 Python buffer 的 `format` 首字符。也就是说，
*你的 dtype 必须和 C 侧的原始类型逐字符对上*：
C 侧是 `int` 就必须是 `'i'`（`numpy.int32`），
`numpy.int64` 对应 `'q'`，`numpy.float32` 对应 `'f'`。

*第三层*：`RNA_property_collection_raw_get` / `..._set`
（#src("source/blender/makesrna/intern/rna_access.cc:5878") 与
#src("source/blender/makesrna/intern/rna_access.cc:5889")），
它们转发到 `rna_raw_access`（#src("source/blender/makesrna/intern/rna_access.cc:5496")）。
这里还有*第二个*分岔，而且这是绝大多数人不知道的一个：

```cpp
// source/blender/makesrna/intern/rna_access.cc:5550（节选）
/* try to access as raw array */
else if (RNA_property_collection_raw_array(ptr, prop, itemprop, set, &out)) {
  if (in.len != item_len * out.len) {
    BKE_reportf(reports, RPT_ERROR, "Array length mismatch (expected %d, got %d)", ...);
    return 0;
  }

  /* matching raw types */
  if (out.type == in.type) {
    ...
    if (size == out.stride) {
      /* The property is stored contiguously so the entire array can be copied at once. */
      if (set) {
        memcpy(outp, inp, size * out.len);
      }
      ...
```

也就是说，只有当*下面两个条件同时成立*时，才会真的执行一次 `memcpy`：

1. 集合的迭代器是标准的数组迭代器，即
   `RNA_property_collection_raw_array` 返回真；
2. 你的 buffer 类型与 C 侧原始类型完全一致。

条件 1 的判定在 #src("source/blender/makesrna/intern/rna_access.cc:5332")：

```cpp
// source/blender/makesrna/intern/rna_access.cc:5332（节选）
if (!(prop->flag_internal & PROP_INTERN_RAW_ARRAY) ||
    !(itemprop->flag_internal & PROP_INTERN_RAW_ACCESS))
{
  return 0;
}
```

这两个 `flag_internal` 位是*构建时由 `makesrna` 自动生成代码时打上的*，
判定逻辑在 #src("source/blender/makesrna/intern/makesrna.cc:2196")：

```cpp
// source/blender/makesrna/intern/makesrna.cc:2196（节选）
/* test if we can allow raw array access, if it is using our standard
 * array get/next function, we can be sure it is an actual array */
if (cprop->next && cprop->get) {
  if (STREQ((const char *)cprop->next, "rna_iterator_array_next") &&
      STREQ((const char *)cprop->get, "rna_iterator_array_get"))
  {
    prop->flag_internal |= PROP_INTERN_RAW_ARRAY;
  }
}
```

而 `PROP_INTERN_RAW_ACCESS` 由 `rna_set_raw_property`
（#src("source/blender/makesrna/intern/makesrna.cc:1896")）设置，
它*要求该项属性有对应的 DNA 结构体字段*：

```cpp
// source/blender/makesrna/intern/makesrna.cc:1898（节选）
if (dp->dnapointerlevel != 0) {
  return;
}
if (dp->dnatype.is_empty() || dp->dnaname.is_empty() || dp->dnastructname.is_empty()) {
  return;
}
```

#note[
  这解释了一个看起来很奇怪的现象：*同样是「顶点上的浮点数据」，
  `attributes[...]` 能走 `memcpy`，而 `mesh.vertices[...]` 不能。*

  原因是后者在 Blender 4.0 之后不再有 DNA 结构体：
  顶点坐标存在通用属性里，`MeshVertex.co` 是通过一对回调读写的
  （#src("source/blender/makesrna/intern/rna_mesh.cc:2038") 用
  `RNA_def_property_float_funcs` 而非 sdna），
  于是 `dnastructname` 为空，`PROP_INTERN_RAW_ACCESS` 不会被置位。
  而 `Mesh` 的 `attributes` 集合里，`FloatAttributeValue.value`
  之类的项类型*是* DNA 结构（如 `MFloatProperty`，
  #src("source/blender/makesrna/intern/rna_attribute.cc:1464")），
  于是走最上面那条 `memcpy` 路径。
]

=== 6.2.4 实测

下面的数字是在 Blender 4.2.13 上实测的（同一段数据，取 7 次最优）：

- 网格：299,209 个顶点 / 1,192,464 个面角 / 298,116 个四边面；
- 硬件与系统：单机笔记本，Windows 11；绝对数字不可移植，
  *比值*是可移植的。

#figure(
  kind: table,
  table(
    columns: (3.0fr, 1.2fr, 1.0fr, 1.2fr),
    inset: 6pt,
    align: (left, right, right, right),
    stroke: 0.4pt + luma(78%),
    table.header([*调用*], [*输出 dtype*], [*耗时*], [*相对最慢*]),
    [`vertices.foreach_get("co", a)`], [`float32`], [0.0106 s], [17×],
    [`vertices.foreach_get("co", a)`], [`float64`], [0.0553 s], [3.3×],
    [`attributes["int_attr"].data.foreach_get("value", a)`], [`int32`], [0.000073 s], [2531×],
    [`attributes["int_attr"].data.foreach_get("value", a)`], [`int64`], [0.0123 s], [15×],
    [`attributes["vec_attr"].data.foreach_get("vector", a)`], [`float32`], [0.000416 s], [444×],
    [`attributes["bytecol"].data.foreach_get("color", a)`], [`float32`], [0.0097 s], [19×],
    [`polygons.foreach_get("loop_start", a)`], [`int32`], [0.0235 s], [7.9×],
    [Python `for` 循环读 `v.co.x`（299,209 次）], [—], [0.1847 s], [*1×*],
  ),
  caption: [同一次读操作的八种写法。最后一列以最慢的一种为基准；「2531×」意味着 memcpy 路径与 Python 逐项循环之间差三个数量级。],
) <tbl-foreach-bench>

这张表要读出四个结论：

1. *真正走 `memcpy` 的那两行（`int32` 与 `float32` 向量）
   比其他所有行快一到三个数量级。* 具体地：`int32` 是 73 微秒，
   相当于 40 亿项/秒 —— 这不可能是逐项循环，它一定是一次内存拷贝。
2. *dtype 不匹配的代价极大。* 同一份 `int` 属性，`int64` 比 `int32` 慢 168 倍。
   这不是「慢一点」，而是从 `memcpy` 掉进了逐项 Python 对象创建。
3. *`vertices.foreach_get("co", ...)` 确实比 Python 循环快 17 倍，
   但它没有走到 `memcpy`。* 这一点与上一小节的源码分析一致
   （`MeshVertex` 没有 DNA 结构）。它对 `float64` 的额外开销
   （只快 3.3 倍）也符合「需要逐项类型转换」的特征。
4. *`polygons.foreach_get("loop_start", int32)` 只快 7.9 倍，
   是表里最令人意外的行。* 这个属性的 DNA 类型确实是 `int`
   （#src("source/blender/makesdna/DNA_mesh_types.h:179") 的
   `int *face_offset_indices`），dtype 也对得上，但它仍然没走 `memcpy`。
   可能的解释是面偏移表在运行时可能被共享/重定向
   （源码注释提到 `bmesh::MeshRuntime::face_offsets_sharing_info`，
   #src("source/blender/makesdna/DNA_mesh_types.h:176")），
   导致集合迭代器不是标准数组迭代器。*这是本书实测中确认为
   「未能完全解释」的一点*，写在这里以免读者被一个看似矛盾的基准误导。

#warn[
  不要把上表的绝对数字当作基准。它测量的是 *Blender 4.2.13*。
  但「dtype 对上就有数量级差异」这个性质来自
  `foreach_compat_buffer` 的源码逻辑，跨版本稳定。
  你自己的代码应该在*你自己的数据*上量一次。
]

=== 6.2.5 怎么用：四条能直接照抄的规则

==== 规则一：永远用 `numpy` 数组，不要用 list

```python
import numpy as np

mesh = obj.data
n = len(mesh.vertices)

# 好
co = np.empty(n * 3, dtype=np.float32)
mesh.vertices.foreach_get("co", co)
co = co.reshape(n, 3)

# 差：list 没有 buffer 协议，强制走逐项路径
co_list = [0.0] * (n * 3)
mesh.vertices.foreach_get("co", co_list)
```

==== 规则二：dtype 必须与 C 侧原始类型一致

对应关系是死的（来自 #src("source/blender/python/intern/bpy_rna.cc:5922")）：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.5fr, 2.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*C 侧原始类型*], [*numpy dtype*], [*说明*]),
    [`float`], [`np.float32`], [单精度。Blender 里绝大多数几何数据都是它],
    [`double`], [`np.float64`], [双精度。少数 IDProperty 与部分参数是它],
    [`int`], [`np.int32`], [有符号时 format 是 `'i'`],
    [`uint`], [`np.uint32`], [无符号时 format 是 `'I'`。*与 int32 不通用*],
    [`int64_t`], [`np.int64`], [format `'q'`],
    [`uint64_t`], [`np.uint64`], [format `'Q'`],
    [`short`、`ushort`], [`np.int16`、`np.uint16`], [format `h` 或 `H`],
    [`char`、`uchar`], [`np.int8`、`np.uint8`], [format `b` 或 `B`],
    [`bool`], [`np.bool_`], [format `'?'`],
  ),
  caption: [`foreach_*` 的 dtype 对照表。用错一列就会从 `memcpy` 掉到逐项循环。],
) <tbl-foreach-dtypes>

==== 规则三：C 连续（C-contiguous）

buffer 协议只认连续内存。切片、转置、`reshape` 的某些组合会产生
非连续视图，此时 `PyObject_GetBuffer(..., PyBUF_ND)` 会失败并*静默降级*
（源码里 `PyErr_Clear()` 之后落回序列路径，
#src("source/blender/python/intern/bpy_rna.cc:6015")）。这是
官方 addon 里到处出现 `.ravel()` 的原因 —— 见 §6.3 里 FBX 的
`edges_conv.ravel()`（#src("scripts/addons_core/io_scene_fbx/import_fbx.py:1904")）。

```python
bad = big_array[:, ::2]              # 非连续视图
mesh.vertices.foreach_set("co", bad)  # 不报错，但变慢

good = np.ascontiguousarray(bad)      # 先转成连续
mesh.vertices.foreach_set("co", good)
```

==== 规则四：长度必须精确等于 `项数 × 每项元素数`

长度不对会得到一条运行时错误（#src("source/blender/makesrna/intern/rna_access.cc:5552")）：

```text
RuntimeError: internal error setting the array
```

注意：`foreach_parse_args` 里那段「提前检查长度」的代码是*被 `#if 0` 关掉的*
（#src("source/blender/python/intern/bpy_rna.cc:5888")），
因为混合三角形/四边形的网格里每项长度不同（注释引用了 issue #111117）。
所以长度检查被推迟到 `rna_raw_access` 里，报错信息也就没那么友好。

#pitfall[
  四个最常见的错误，按出现频率排序：

  1. *用 `np.zeros(n*3)` 的默认 `float64` 去读 `co`。* 不报错，
     但慢 5 倍。永远显式写 `dtype=np.float32`。
  2. *忘记 `reshape` 就按 `[i]` 索引。* `co` 是扁平的，
     `co[i]` 是第 i 个*浮点数*，不是第 i 个顶点。
  3. *在 `foreach_set` 之后忘记 `mesh.update()`。* 属性写进去了，
     但依赖图和显示缓存没被标脏。
  4. *对字符串属性用 `foreach_get`。* 会得到
     `AttributeError: ... elements have no attribute ...`
     或 `attribute does not support foreach method`
     （#src("source/blender/python/intern/bpy_rna.cc:5916")）。
]

=== 6.2.6 `numpy` 带来的第二种收益：把数学也搬出 Python

`foreach_get` 只解决了「进出」的开销。数据拿到 `numpy` 之后，
真正的收益是*后续计算也不再有 Python 循环*。
官方 glTF 导出器就是标准范例（#src("scripts/addons_core/io_scene_gltf2/blender/exp/primitive_extract.py:1435")）：

```python
# scripts/addons_core/io_scene_gltf2/blender/exp/primitive_extract.py:1435（节选）
def __get_uvs_attribute(self, blender_uv_idx, attr):
    layer = self.blender_mesh.uv_layers[blender_uv_idx]
    uvs = np.empty(len(self.blender_mesh.loops) * 2, dtype=np.float32)
    layer.uv.foreach_get('vector', uvs)
    uvs = uvs.reshape(len(self.blender_mesh.loops), 2)

    # Blender UV space -> glTF UV space
    # u,v -> u,1-v
    uvs[:, 1] *= -1
    uvs[:, 1] += 1
    ...
    del uvs
```

注意 `uvs[:, 1] *= -1` 这一行：翻转整个 UV 的 V 分量，
在纯 Python 里是 120 万次浮点乘法加 120 万次列表索引，
在 `numpy` 里是一次向量化的原地操作。

#tip[
  官方 FBX 导入器把这个思路做成了可复用的小工具，
  值得直接读一遍（#src("scripts/addons_core/io_scene_fbx/fbx_utils.py:674") 起）：
  它用一个 `AttributeDataTypeInfo` 命名元组把
  「属性类型 → numpy dtype → foreach 用的属性名 → 每项元素数」
  四件事绑在一起，再用 `attribute_to_ndarray()` 统一读。
  这是「不要在每个格式解析器里重复写同样的 dtype 映射」的教科书做法。
]

#exercise[
  *练习 6.2* 亲手复现这张基准表：

  1. 用 `from_pydata` 建一个 512×512 的四边面平面（约 26 万顶点），
     随后调用 `mesh.validate()`；
  2. 分别用「Python `for` 循环读 `.co`」与
     「`foreach_get` 到 `float32` / `float64` 数组」把坐标读出来，
     用 `time.perf_counter()` 各测 5 次取最小；
  3. 给网格加一个 `INT` 属性，比较 `np.int32` 与 `np.int64` 读取的耗时；
  4. 把第 3 步的结论整理成一句话，说明「为什么 dtype 会带来数量级差异」，
     并用 #src("source/blender/python/intern/bpy_rna.cc:5922") 的那段逻辑解释；
  5. 把 `int64` 那次的数组改成一个非连续的切片（如 `arr[::2]`），
     观察耗时是否进一步变化。
]

== 6.3 曲线、材质、节点树、集合与自定义属性的读写

上一节讲的是「怎么快」。这一节讲「在哪里读」——把常用数据类型的
读写入口集中列一遍，并把 `foreach_*` 的适用范围说清楚。

=== 6.3.1 曲线：`Spline` 就是 `Nurb`

第一条要知道的事实：Python 里的 `bpy.types.Spline`
在 C 侧的结构体叫 `Nurb`（#src("source/blender/makesrna/intern/rna_curve.cc:2003")）：

```cpp
// source/blender/makesrna/intern/rna_curve.cc:2002（节选）
srna = RNA_def_struct(brna, "Spline", nullptr);
RNA_def_struct_sdna(srna, "Nurb");
```

这解释了为什么你在写 C 时会看到 `nurb` 这个词，而 Python 里全是 `spline`。

第二条：曲线有*两种完全不同的点类型*，由 `Spline.type` 决定：

- `POLY` 与 `NURBS` 用 `spline.points`（C 侧字段 `bp`，
  #src("source/blender/makesrna/intern/rna_curve.cc:2010")），
  每项是 `BPoint`，`co` 是*四*个浮点（齐次坐标 `x y z w`）；
- `BEZIER` 用 `spline.bezier_points`（C 侧字段 `bezt`，
  #src("source/blender/makesrna/intern/rna_curve.cc:2027")），
  每项是 `BezierSplinePoint`，除了 `co`（三个浮点）还有
  `handle_left` 与 `handle_right`（各三个浮点），以及
  `handle_left_type` 与 `handle_right_type`。

#warn[
  `points` 的 `co` 是 4 个分量，`bezier_points` 的 `co` 是 3 个分量。
  数组长度必须分别按 `n * 4` 和 `n * 3` 算。
  这是 `foreach_get` 在曲线数据上最常见的错误来源。
]

`foreach_get` 支持到什么粒度？实测结论是：*它只能作用在
「点集合」上，不能穿透到「样条集合」*。下面这段会失败：

```python
# 错误：Spline 不是基本类型，无法批量读
cu.splines.foreach_get("bezier_points", buf)
# RuntimeError: internal error setting the array
```

错误的根因在 §6.2 讲过的类型检查
（#src("source/blender/makesrna/intern/rna_access.cc:5536")）：
被读取的必须是 `PROP_BOOLEAN` / `PROP_INT` / `PROP_FLOAT` / `PROP_ENUM`，
而 `bezier_points` 是一个 `PROP_COLLECTION`。

正确的写法是逐样条读取（实测 2000 条贝塞尔样条、8002 个控制点，
遍历加读取总耗时 0.0044 秒）：

```python
import numpy as np

curve = obj.data
total = sum(len(s.bezier_points) for s in curve.splines
            if s.type == 'BEZIER')

co = np.empty(total * 3, dtype=np.float32)
offset = 0
for spline in curve.splines:
    if spline.type != 'BEZIER':
        continue
    count = len(spline.bezier_points)
    if not count:
        continue
    chunk = co[offset:offset + count * 3]
    spline.bezier_points.foreach_get("co", chunk)
    offset += count * 3

co = co.reshape(-1, 3)
```

#tip[
  读取时给 `foreach_get` 传一个*切片视图*是可以的，只要那个切片是连续的。
  `co[offset:offset + count * 3]` 是连续的，因此没问题。
  但不要传 `co[::2]` 这类跨步切片，理由见 §6.2 规则三。
]

=== 6.3.2 材质与节点树

材质相关的入口都很直白：

- `bpy.data.materials`：所有材质数据块；
- `material.node_tree`（#src("source/blender/makesrna/intern/rna_material.cc:1258")）：
  该材质的节点树，可能为 `None`；
- `object.material_slots`：物体上的材质槽，每槽的 `material` 可能为 `None`。

节点树的遍历结构是 `node_tree.nodes` 与 `node_tree.links`。
节点位置确实可以 `foreach_get`，但节点数量通常是几十到几百，
没有向量化的必要。真正值得批量的场景是「批量改 socket 默认值」，
而这种场景的量级也不大，直接循环即可：

```python
tree = bpy.data.materials["Probe"].node_tree

for node in tree.nodes:
    if node.type == 'BSDF_PRINCIPLED':
        node.inputs["Roughness"].default_value = 0.5
        node.inputs["Metallic"].default_value = 0.0
```

#pitfall[
  *不要用 socket 的整数下标。* `node.inputs[0]` 在不同版本、
  甚至在不同界面语言下都可能指向不同的 socket。
  永远用 `node.inputs["名字"]`。名字是 socket 的英文标识，
  不随界面语言变化。
]

#note[
  节点的 `Socket` 是一个 RNA 结构，`default_value` 的类型取决于
  socket 的数据类型（`Float` 是 `float`，`Vector` 是三元组，
  `Color` 是四元组，`Shader` 是节点引用）。
  写之前用 `socket.type` 判断一下，可以避免「赋值成功但值没变」
  这类静默错误。
]

=== 6.3.3 集合（Collection）

`bpy.types.Collection` 和 Python 的 `list` 没有关系，
它是 Blender 的「场景组织单元」。读写入口如下：

#figure(
  kind: table,
  table(
    columns: (2.0fr, 3.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*说明*]),
    [`collection.objects`], [直接链接到该集合的物体],
    [`collection.all_objects`], [包含子集合在内的所有物体。*通常这才是你想要的*],
    [`collection.children`], [子集合],
    [`collection.users_collection`], [该集合本身被哪些集合引用],
    [`collection.objects.link(ob)`], [把物体链接进集合],
    [`collection.objects.unlink(ob)`], [解除链接],
    [`scene.collection`], [场景根集合],
    [`bpy.data.collections.new(name)`], [新建集合。*新建后必须 link，否则它不在场景里*],
  ),
  caption: [集合的常用成员。`objects` 与 `all_objects` 的区别是最容易出错的地方],
) <tbl-collection-members>

```python
import bpy

# 遍历场景里所有物体，包括子集合里的
for ob in bpy.context.scene.collection.all_objects:
    print(ob.name)

# 新建集合并正确链接
coll = bpy.data.collections.new("ProbeCollection")
bpy.context.scene.collection.children.link(coll)
```

#pitfall[
  `bpy.data.collections.new()` 创建的集合*不在任何场景里*，
  因此不会出现在大纲视图，也不会被保存的可见内容引用。
  必须显式 link 到某个父集合。忘了这一步的表现是
  「物体会被渲染，但大纲里看不见」——因为物体确实在场景里，
  只是它所属的集合是个孤儿。
]

=== 6.3.4 自定义属性（IDProperty）的批量读写

§5.4 讲了 `obj["key"]` 这套 IDProperty 访问。这里只补一条与性能有关的：

*IDProperty 不支持 `foreach_get`。* 它是 RNA 里的 `PROP_IDPROPERTY` 标记，
走的是 IDProperty 自己的遍历逻辑，不在 §6.2 那张 dtype 对照表的覆盖范围内。

因此，如果你的数据量大到需要考虑性能，*不要把它存成自定义属性*。
用下面两条替代路径：

- *存在网格或曲线上的逐元素数据*：用 `mesh.attributes.new(...)`
  建通用属性，然后 `foreach_get` 与 `foreach_set`；
- *存在物体上的少量配置*：用 `PropertyGroup` 加 `PointerProperty`（§5.4）。
  它底层仍然是 IDProperty 存储，但类型、默认值、范围都被 RNA 描述清楚了，
  UI 上也能直接画。

```python
import bpy
import numpy as np

mesh = obj.data
n = len(mesh.vertices)

# 建一个逐顶点的浮点属性（已存在时 new() 会抛错，先判断）
attr = mesh.attributes.get("probe_weight")
if attr is None:
    attr = mesh.attributes.new("probe_weight", 'FLOAT', 'POINT')

rng = np.random.default_rng(1)
weights = rng.random(n).astype(np.float32)
attr.data.foreach_set("value", weights)
```

#note[
  `mesh.attributes.new(name, type, domain)` 的合法取值可以现场查，
  也可以对照源码。类型来自
  #src("source/blender/makesrna/intern/rna_attribute.cc:32")：
  `FLOAT`、`INT`、`BOOLEAN`、`FLOAT_VECTOR`、`FLOAT_COLOR`、
  `BYTE_COLOR`、`QUATERNION`、`FLOAT4X4`、`STRING`、`INT8`、
  `INT16_2D`、`INT32_2D`、`FLOAT2`、`FLOAT4`。
  `domain` 的取值见 #src("source/blender/makesrna/intern/rna_attribute.cc:142")，
  常用 `POINT`、`EDGE`、`FACE`、`CORNER`。
]

#warn[
  两类属性的 `foreach_*` 性能特性并不一样（依据 §6.2 的源码分析）：
  标量属性（`FLOAT`、`INT`、`BOOLEAN`）与 `FLOAT_VECTOR` 走的是
  `memcpy` 路径，极快；`BYTE_COLOR` 有 sRGB 与线性空间的转换回调，
  因此掉进逐项路径。实测读 30 万项：`INT` 是 73 微秒，
  `BYTE_COLOR` 是 9.7 毫秒，相差 133 倍。
  颜色数据量大时优先用 `FLOAT_COLOR`，或者读成 `float32`
  之后在 `numpy` 里自己做转换。
]

#exercise[
  *练习 6.3* 把这四种数据的读写各练一遍：

  1. 建一条 200 个控制点的 `POLY` 曲线，用 `spline.points.foreach_set`
     把 `co` 设成一条螺旋线（注意 `co` 是 4 个分量）；
  2. 把它的 `spline.type` 改成 `'BEZIER'`，确认控制点是否还在，
     以及 `points` 与 `bezier_points` 此时各自是否可访问；
  3. 给一个网格加 `FLOAT` 与 `BYTE_COLOR` 两个逐顶点属性，
     各写入 10 万项，比较 `foreach_set` 的耗时；
  4. 用 `scene.collection.all_objects` 与 `scene.collection.objects`
     分别数一遍物体，构造一个「子集合里有物体」的场景让两者结果不同。
]

== 6.4 Python 性能：慢在哪、怎么测量、何时该下沉 C++

=== 6.4.1 定义

本节要回答的问题是：*当一个 addon「太慢」时，你该改哪一行代码。*
这不是一个关于「Python 比 C 慢」的问题 —— 那个结论太粗，没法指导行动。
真正的问题是把「慢」拆成可测量的成分，然后针对成分下药。

先把结论列出来：Python 插件里的时间几乎总是花在下面四类开销上，
而不是「计算」本身。

=== 6.4.2 四类开销

==== 第一类：跨界调用

每一次 `obj.location`、`mesh.vertices[0]`、`bpy.ops.object.select_all()`
都要穿过 RNA 层：查找属性、检查类型、转换值、可能还要分配一个
Python 包装对象。单次成本是几十到几百纳秒 ——
小到可以忽略，但乘以一百万就是几十毫秒。

这一类的解法是 §6.2 的 `foreach_*`：把一百万次往返压缩成一次 `memcpy`。

==== 第二类：Python 对象分配

`mesh.vertices` 是一个集合，但迭代它时*每一项都会创建对象*。
`bpy.types.MeshVertex` 这样的包装类每创建一个都要走一次 `PyObject` 分配与 `__init__`（它是 RNA 层注册的类型，见 #src("source/blender/makesrna/intern/rna_mesh.cc:2031")；注意 #src("scripts/modules/_bpy_types.py:883") 是 `class MeshEdge`，不是它）。

官方的 `GreasePencilDrawing.strokes` 属性的 docstring 把这层成本
写得非常直白（#src("scripts/modules/_bpy_types.py:1712")）：

```text
.. note::

   This API should *not* be used for performance critical operations.
   Use the :class:`GreasePencilDrawing.attributes` API instead.
```

也就是说，遇到「便利 API」和「属性 API」两条路时，*属性 API 是为性能准备的*。

==== 第三类：解释器循环本身

一个空的 `for i in range(1_000_000): pass` 在 CPython 里大约
要几十毫秒。这一部分*无法通过换 API 消除*，只能靠：

- 用 `numpy` 把循环搬进 C（向量化）；
- 用生成器表达式 / `sum()` / `map()` 之类把循环搬进 C 内建；
- 或者接受它。

==== 第四类：真正的算法/计算

如果前面三类都排除掉了，剩下的才是「我的算法本身慢」——
比如一个 O(n²) 的最近邻搜索，或者一次网格简化的收敛迭代。
*只有到这一步，写 C 扩展才是正确选择。*

#pitfall[
  最常见的错误是跳过测量直接判断「Python 慢，所以我要写 C」。
  结果花两周写出来的 C 扩展只快了 1.3 倍，
  因为瓶颈其实在第 1 类开销上 —— 每一轮循环都还在跨界调用。
  *先测量，再优化*，这一节剩下的部分就是讲怎么测量。
]

=== 6.4.3 怎么测量：`cProfile`

Python 标准库的 `cProfile` 是确定性分析器（deterministic profiler）：
它记录每一次函数调用的进入与退出，因此计数精确、开销可预测
（通常是 2 到 5 倍的减速）。

Blender 官方的 glTF 导出器内置了一套可直接照抄的写法
（#src("scripts/addons_core/io_scene_gltf2/__init__.py:1393")）：

```python
# scripts/addons_core/io_scene_gltf2/__init__.py:1393（节选）
profile = bpy.app.debug_value == 102
if profile:
    import cProfile
    import pstats
    import io
    from pstats import SortKey
    pr = cProfile.Profile()
    pr.enable()
    res = gltf2_blender_export.save(context, export_settings)
    pr.disable()
    s = io.StringIO()
    sortby = SortKey.TIME
    ps = pstats.Stats(pr, stream=s).sort_stats(sortby)
    ps.print_stats()
    print(s.getvalue())
else:
    res = gltf2_blender_export.save(context, export_settings)
```

三个值得学的细节：

1. *用一个开关控制*。这里是 `bpy.app.debug_value == 102`。
   `debug_value` 是一个全局整数（RNA 定义在
   #src("source/blender/python/intern/bpy_app.cc:651")），
   用户可以随时改它来打开调试功能，不需要改代码。
   导入侧的同一个开关在 #src("scripts/addons_core/io_scene_gltf2/blender/imp/blender_gltf.py:25")。
2. *只在被分析的那段代码周围 `enable()` / `disable()`。* 包住整个
   addon 会把 Blender 自己的回调也算进去，噪音极大。
3. *用 `SortKey.TIME` 排序*，并且把结果写进 `io.StringIO` 再一次性
   `print` —— 在 Blender 里逐行 `print` 统计结果会非常慢，
   而且可能被丢弃。

=== 6.4.4 一个可直接用的 profile 脚手架

```python
# profile_addon.py —— 在 Blender 的脚本编辑器里运行，
# 或用 blender -b --factory-startup --python profile_addon.py
import cProfile
import pstats
import io
from pstats import SortKey


def profile_call(label, func, *args, **kwargs):
    pr = cProfile.Profile()
    pr.enable()
    try:
        return func(*args, **kwargs)
    finally:
        pr.disable()
        stream = io.StringIO()
        stats = pstats.Stats(pr, stream=stream)
        # 只按累计时间排序，并只看前 25 行，避免刷屏
        stats.sort_stats(SortKey.CUMULATIVE).print_stats(25)
        print("=== profile: %s ===" % label)
        print(stream.getvalue())


def work():
    """把你要测量的东西放这里。"""
    import bpy
    import numpy as np
    mesh = bpy.context.object.data
    n = len(mesh.vertices)
    co = np.empty(n * 3, dtype=np.float32)
    mesh.vertices.foreach_get("co", co)
    co = co.reshape(n, 3)
    return co.mean(axis=0)


profile_call("work()", work)
```

=== 6.4.5 怎么读统计输出

`pstats` 的输出里有两个列经常被误读：

- `tottime`：该函数*自身*（不含它调用的子函数）消耗的时间。
  *优化要看这一列。*
- `cumtime`：该函数及其所有子调用消耗的时间。
  *定位入口要看这一列。*

正确的工作流是：

1. 先按 `cumtime` 排序，找到你 addon 的入口函数；
2. 再按 `tottime` 排序，看*谁在真正烧时间*；
3. 如果 `tottime` 最高的那一行是你自己写的纯 Python 函数，
   那就是真热点，可以动手；
4. 如果最高的几行都是 `<built-in method ...>` 或 `bpy` 里的东西，
   说明时间花在跨界调用上 —— 应该去改*调用方式*（`foreach_get`），
   而不是改算法。

#tip[
  `pstats` 支持 `print_callers()` 与 `print_callees()`。
  当你发现某个函数 `tottime` 很高但不知道是谁在调它时，
  `print_callers("函数名")` 是定位调用点的最快手段。
]

=== 6.4.6 决策图

把 §6.4 与 §6.6 的判断压缩成一张图：

#figure(fig-when-to-drop(), caption: [「何时下沉 C++」决策图。四个主链判定框自上而下，右栏是唯一的「改源码」出口。]) <fig-when-to-drop>

#summary[
  这张图的读法是：*每一层都是一次「先试更便宜的方案」*。
  第 1 层问「有没有 Python 入口」，第 2 层问「能不能向量化」，
  第 3 层问「热点到底在哪」，第 4 层才允许你写原生库。
  跳过第 2、3 层直接到第 4 层，是本章要防的头号错误。
]

=== 6.4.7 关于 `timeit` 与手写计时的取舍

`cProfile` 告诉你*哪个函数*慢，但不告诉你*循环的一次迭代有多贵*。
做微基准时用 `time.perf_counter()` 手写计时更灵活，但要遵守三条：

1. *取多次的最小值*，不要取平均值。前者更接近「没有被打断的真值」。
2. *先在旁边跑一遍热身*，避免把缓存冷启动算进去。
3. *不要用 `time.time()`*，它的分辨率不够，而且受系统时钟调整影响。

```python
import time


def bench(label, fn, reps=7):
    best = float("inf")
    fn()  # 热身
    for _ in range(reps):
        t = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t)
    print("%-40s %.6f s" % (label, best))
```

本书 §6.2 那张基准表就是用这个 `bench()` 得到的。

#warn[
  Blender 是单线程事件循环 + 一个 UI 线程的程序。后台跑基准时，
  用 `blender -b --factory-startup`（无界面、无用户配置）能得到
  最干净的数字。在带界面的 Blender 里跑基准，结果会被重绘、
  依赖图更新、定时器抖动干扰，通常偏高 20% 到 200%。
]

#exercise[
  *练习 6.4* 用测量代替猜测：

  1. 写两个函数：一个用 Python 循环算 20 万顶点的平均坐标，
     一个用 `numpy`；
  2. 先用 `bench()` 对比两者的墙钟时间；
  3. 再用 `profile_call()` 分别 profile 两者，
     记录各自的 `tottime` 排行前三名，解释差异来自哪一类开销；
  4. 给第一个函数改成「先 `foreach_get` 到 `float64` 数组，
     再在 Python 里循环求和」，看它比纯 Python 循环快还是慢，
     并用 §6.2 的 dtype 结论解释结果。
]

== 6.5 动画、驱动与渲染调用

=== 6.5.1 动画数据的三层结构

Blender 的动画系统在数据结构上分成三层，理解这三层是写好动画相关
addon 的前提：

#figure(
  kind: table,
  table(
    columns: (1.6fr, 1.5fr, 3.0fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*RNA 类型*], [*作用*]),
    [动画数据], [`AnimData`], [挂在数据块上（`object.animation_data`），指向一个 Action 与一组 NLA 轨道。定义在 #src("source/blender/makesrna/intern/rna_animation.cc:1629")],
    [动作], [`Action`], [一组 F-Curve。`AnimData.action` 见 #src("source/blender/makesrna/intern/rna_animation.cc:1649")],
    [函数曲线], [`FCurve`], [一条通道，由 `data_path` + `array_index` 定位（#src("source/blender/makesrna/intern/rna_fcurve.cc:2652")、#src("source/blender/makesrna/intern/rna_fcurve.cc:2660")）],
    [关键帧], [`Keyframe`], [`FCurve.keyframe_points`（#src("source/blender/makesrna/intern/rna_fcurve.cc:2732")）],
  ),
  caption: [动画系统的四层结构],
) <tbl-anim-layers>

`AnimData` 上还挂着一组*驱动*：`AnimData.drivers`
（#src("source/blender/makesrna/intern/rna_animation.cc:1720")）。

=== 6.5.2 插入关键帧

最简单的入口是 `bpy_struct` 上的 `keyframe_insert` 方法
（方法表见 #src("source/blender/python/intern/bpy_rna.cc:6503")）：

```python
import bpy

obj = bpy.context.object
obj.location = (0.0, 0.0, 0.0)
obj.keyframe_insert(data_path="location", frame=1)

obj.location = (2.0, 0.0, 0.0)
obj.keyframe_insert(data_path="location", frame=24)
```

`data_path` 的写法与 `FCurve.data_path` 完全一致：它是相对于该数据块的
RNA 路径，可以用 `bpy.utils.make_rna_paths`
（#src("scripts/modules/bpy/utils/__init__.py:1408")）拼出来。

#pitfall[
  *不要用 `bpy.ops.anim.keyframe_insert()` 做批量插帧。*
  它是一个操作符，每次调用都要走一遍上下文检查与撤销逻辑。
  几百个关键帧时用 `keyframe_insert()` 直接调，
  最后手动 `bpy.ops.ed.undo_push()` 压一条（见 §5.7）。
]

=== 6.5.3 驱动

驱动的入口同样在 `bpy_struct` 上（方法表见
#src("source/blender/python/intern/bpy_rna.cc:6511")），文档在
#src("source/blender/python/intern/bpy_rna_anim.cc:603")：

```text
.. method:: driver_add(path, index=-1, /)

   Adds driver(s) to the given property

   :param path: path to the property to drive, analogous to the fcurve's data path.
   :param index: array index of the property drive.
      Defaults to -1 for all indices or a single channel if the property is not an array.
   :return: The driver added or a list of drivers when index is -1.
```

```python
import bpy

obj = bpy.context.object
# 驱动 location.x，返回一个 FCurve
fcurve = obj.driver_add("location", 0)
driver = fcurve.driver
driver.type = 'SCRIPTED'
driver.expression = "frame * 0.05"
```

#warn[
  驱动是一把双刃剑。它会在每一次依赖图求值时被重新计算，
  而且*表达式是用 Python 求值的*。写一个会遍历 `bpy.data` 的驱动表达式，
  等于给每一帧都塞进一次全场景扫描 —— 这是最常见的「Blender 越用越卡」
  来源之一。驱动表达式里只用它拿到的变量和简单算术。
]

=== 6.5.4 渲染：`bpy.ops.render.render`

从 Python 触发渲染只有一条路（除了自己实现 `RenderEngine`，见下）：

```python
import bpy

# 渲染当前帧，并写入 scene.render.filepath
bpy.ops.render.render(write_still=True)

# 渲染动画区间
bpy.ops.render.render(animation=True)
```

操作符定义在 #src("source/blender/editors/render/render_internal.cc:1146")，
它的属性有 `animation`、`write_still`、`use_viewport`、
`use_sequencer_scene`、`layer`（#src("source/blender/editors/render/render_internal.cc:1166") 起）。

#note[
  这个操作符*没有* `poll`（源码里那段 `ot->poll = ED_operator_screenactive`
  被 `#if 0` 注掉了，注释写着
  「This isn't needed, causes failure in background mode」，
  #src("source/blender/editors/render/render_internal.cc:1161")）。
  这是它能从 `blender --background` 里调用的原因 ——
  对比 §5.7 里带 `ED_operator_screenactive` 的 `bpy.ops.ed.undo_push`
  在后台就会失败。*如果你要写的操作符需要在无界面模式下可用，
  这一点是必须照抄的。*
]

=== 6.5.5 自定义渲染引擎：`RenderEngine`

这是 Python 插件能力边界上最特殊的一个点：*你可以用 Python 实现一个
完整的渲染引擎*，Blender 会把它当成内置引擎一样对待 ——
出现在引擎下拉菜单里、支持 F12、支持视口渲染。

入口是 `bpy.types.RenderEngine`，RNA 定义在
#src("source/blender/makesrna/intern/rna_render.cc:540")：

```cpp
// source/blender/makesrna/intern/rna_render.cc:540（节选）
srna = RNA_def_struct(brna, "RenderEngine", nullptr);
RNA_def_struct_sdna(srna, "RenderEngine");
RNA_def_struct_ui_text(srna, "Render Engine", "Render engine");
RNA_def_struct_refine_func(srna, "rna_RenderEngine_refine");
RNA_def_struct_register_funcs(srna,
                              "rna_RenderEngine_register",
                              "rna_RenderEngine_unregister",
                              "rna_RenderEngine_instance");
```

Python 侧它只是一个带 metaclass 的空类
（#src("scripts/modules/_bpy_types.py:1608")），真正的契约在回调上。
注册时，C 侧按*固定顺序*把有实现的方法接到引擎类型的函数指针上
（#src("source/blender/makesrna/intern/rna_render.cc:371")）：

```cpp
// source/blender/makesrna/intern/rna_render.cc:371（节选）
et->update                 = (have_function[0]) ? engine_update : nullptr;
et->render                 = (have_function[1]) ? engine_render : nullptr;
et->render_frame_finish    = (have_function[2]) ? engine_render_frame_finish : nullptr;
et->draw                   = (have_function[3]) ? engine_draw : nullptr;
et->bake                   = (have_function[4]) ? engine_bake : nullptr;
et->view_update            = (have_function[5]) ? engine_view_update : nullptr;
et->view_draw              = (have_function[6]) ? engine_view_draw : nullptr;
et->update_script_node     = (have_function[7]) ? engine_update_script_node : nullptr;
et->update_render_passes   = (have_function[8]) ? engine_update_render_passes : nullptr;
et->update_custom_camera   = (have_function[9]) ? engine_update_custom_camera : nullptr;
```

#figure(
  kind: table,
  table(
    columns: (1.9fr, 2.5fr, 1.4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*方法*], [*签名*], [*必须*]),
    [`update`], [`update(self, data, depsgraph)`], [否],
    [`render`], [`render(self, depsgraph)`], [否],
    [`render_frame_finish`], [`render_frame_finish(self)`], [否],
    [`draw`], [`draw(self, context, depsgraph)`], [否],
    [`bake`], [`bake(self, depsgraph, object, pass_type, pass_filter, width, height)`], [否],
    [`view_update`], [`view_update(self, context, depsgraph)`], [否],
    [`view_draw`], [`view_draw(self, context, depsgraph)`], [否],
    [`update_script_node`], [`update_script_node(self, node)`], [否],
    [`update_render_passes`], [`update_render_passes(self, scene, renderlayer)`], [否],
    [`update_custom_camera`], [`update_custom_camera(self, cam)`], [否],
    [`bl_idname`（属性）], [字符串，引擎标识], [*是*],
    [`bl_label`（属性）], [字符串，界面显示名], [*是*],
    [`bl_use_preview`], [`bool`，是否支持材质/灯光预览], [否],
    [`bl_use_postprocess`], [`bool`，是否应用合成], [否],
    [`bl_use_gpu_context`], [`bool`，是否在 `render` 里可用 GPU 上下文], [否],
  ),
  caption: [`bpy.types.RenderEngine` 的回调与注册属性。签名核对自 #src("source/blender/makesrna/intern/rna_render.cc:550") 起],
) <tbl-renderengine>

下面的骨架只用来说明结果缓冲的写法；可独立注册的完整示例见 §15.6.2。

```python
import bpy
import numpy as np


class ProbeRenderEngine(bpy.types.RenderEngine):
    bl_idname = "PROBE_RENDER"
    bl_label = "Probe 渲染器"
    bl_use_preview = False
    bl_use_postprocess = False

    def render(self, depsgraph):
        scene = depsgraph.scene
        scale = scene.render.resolution_percentage / 100.0
        width = int(scene.render.resolution_x * scale)
        height = int(scene.render.resolution_y * scale)

        # 为一个视图层申请一块结果缓冲，返回一个 RenderResult
        result = self.begin_result(0, 0, width, height)
        render_pass = result.layers[0].passes["Combined"]

        # 拿一个 pass 的像素缓冲。rect 是二维 float 数组，
        # 外层有 width * height 个像素，每个像素有 4 个分量（RGBA）
        pixels = np.empty(width * height * 4, dtype=np.float32)
        # 这里真正应该调用你自己的渲染逻辑；示意：填一个渐变
        xs = np.linspace(0.0, 1.0, width, dtype=np.float32)
        ys = np.linspace(0.0, 1.0, height, dtype=np.float32)
        grad = np.outer(ys, xs)                     # (height, width)
        pixels[0::4] = grad.ravel()
        pixels[1::4] = grad.ravel()
        pixels[2::4] = 1.0 - grad.ravel()
        pixels[3::4] = 1.0

        render_pass.rect = pixels.reshape(-1, 4).tolist()

        self.update_result(result)
        self.end_result(result)


classes = (ProbeRenderEngine,)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
```

注册后，在 `scene.render.engine` 的下拉里就能选到「Probe 渲染器」。

关于结果缓冲有三个必须知道的点：

- `begin_result(x, y, w, h)` 创建一个渲染结果并返回它
  （RNA 定义 #src("source/blender/makesrna/intern/rna_render.cc:642")）；
- `RenderPass.rect` 是一个*二维动态数组*（#src("source/blender/makesrna/intern/rna_render.cc:1211")，
  `RNA_def_property_multi_array(prop, 2, nullptr)`），
  形状是 `(width * height, channels)`；长度回调
  #src("source/blender/makesrna/intern/rna_render.cc:474") 明确把
  第一维设成 `rectx * recty`，第二维设成 `channels`；
- 写完像素后要 `update_result()`（让界面能刷新），
  最后 `end_result()` 声明这一块结果完成
  （#src("source/blender/makesrna/intern/rna_render.cc:674")）。

#pitfall[
  自定义引擎有两个安静的失败模式：

  1. *`update_result()` 忘调。* 渲染结果其实已经写进去了，
     但界面永远显示渲染前的状态。看起来像「渲染出黑图」，
     实际上数据是对的。
  2. *把 `pixels` 的形状写成 `(height, width * channels)`。* `rect` 的
     每个内层元素表示一个像素，长度必须等于 `channels`（一般是 4，RGBA）。
     维度不对时，属性赋值会直接报 `ValueError` 或 `TypeError`。
]

#exercise[
  *练习 6.5* 写一个真正干活的渲染引擎：

  1. 基于上面的骨架，改成「把场景里所有物体的世界坐标包围盒画成
     一个 2D 正交投影图」（颜色深浅表示深度）；
  2. 从 `depsgraph.object_instances` 取每个实例的矩阵与网格顶点，
     用 `foreach_get` 批量读坐标；
  3. 用 `update_render_passes` 额外声明一个 `DEPTH` pass；
  4. 给引擎加一个 `BoolProperty` 开关（通过 `PropertyGroup` 挂到
     `scene` 上），让用户可以切换是否按深度上色；
  5. 观察「按 `F12`」「视口渲染」两种模式下分别调用了哪些回调，
     用 `print` 记录调用顺序。
]

== 6.6 原生加速：用 Rust / C / C++ 写成 C ABI 动态库

=== 6.6.1 定义

#term("原生加速", "native acceleration") 指的是：
把插件里计算最密集的那一部分用 C / C++ / Rust 重新实现，
编译成一个*导出 C ABI 的动态库*（Windows `.dll`、Linux `.so`、
macOS `.dylib`），再用 `ctypes`、`cffi` 或 PyO3 把它接进 Python。

关键限定词是 *C ABI*。它意味着：

- 不跨边界传 C++ 类、模板、`std::string`、异常；
- 只传「C 语言能描述的东西」：整数、浮点、指针、不透明句柄；
- 函数用 `extern "C"`（C++）或 `#[no_mangle] extern "C"`（Rust）导出，
  避免名字修饰（name mangling）。

#warn[
  *这一节是本章唯一会显著增加你的分发成本的方案。*
  走这条路之前，请确认你已经做过 §6.4 的三件事：
  确认有 Python 入口、确认已经向量化、确认 `cProfile` 指出热点
  确实在计算上。跳过这三步直接写原生库，
  结果通常是「花两周换来 1.3 倍」。
]

=== 6.6.2 为什么这么设计：C ABI 是唯一稳定的接口

Python 的解释器（CPython）本身就是一个 C 程序。`ctypes` 的工作方式是：

1. 在运行时用操作系统的动态加载器打开你的库；
2. 按你声明的签名，把 Python 对象转换成 C 值；
3. 用 `dlsym` / `GetProcAddress` 找到函数地址并调用。

这条路径上*没有任何 C++ 概念* —— 没有 RTTI、没有名字修饰、
没有栈展开。所以跨边界的东西必须能退化成一个地址或一个值。
这就是「只导出 C ABI」的全部理由。

Blender 官方 addon 里已经有两个真实的、长期维护的例子，
它们的共同点值得注意：

- draco 压缩（#src("scripts/addons_core/io_scene_gltf2/io/exp/draco.py:5") 起）
  用一个*不透明句柄*（`encoderCreate` 返回 `c_void_p`）来避免
  跨边界暴露 C++ 对象；
- meshopt 编解码
  （#src("scripts/addons_core/io_scene_gltf2/io/imp/gltf2_io_binary_meshopt.py:33")、
  #src("scripts/addons_core/io_scene_gltf2/io/exp/meshopt.py:43")）
  全部用「指针 + 长度」的扁平缓冲区接口。

还有一个更简单的例子在 i18n 工具里
（#src("scripts/modules/_bl_i18n_utils/utils_rtl.py:182")），
它加载系统的 FriBidi 库来做阿拉伯语整形：

```python
# scripts/modules/_bl_i18n_utils/utils_rtl.py:182（节选）
fbd = ctypes.CDLL(settings.FRIBIDI_LIB)

for msg in msgs:
    msg = protect_format_seq(msg)

    fbc_str = ctypes.create_unicode_buffer(msg)
    ln = len(fbc_str) - 1
    btypes = (ctypes.c_int * ln)()
    ...
    fbd.fribidi_get_bidi_types(fbc_str, ln, ctypes.byref(btypes))
```

这段代码值得学的是 `ctypes.create_unicode_buffer` 与
`ctypes.byref(...)` 这两个用法：它们分别解决了「Python 字符串到
C 宽字符缓冲」和「把输出参数传进去」两个问题。

#tip[
  去找你需要的库时，先看看 Blender 自己是怎么加载动态库的。
  glTF addon 的 `dll_path()`（#src("scripts/addons_core/io_scene_gltf2/io/com/library.py:10")）
  是一份现成的、处理了三平台差异与安装目录差异的实现，
  可以直接借鉴（注意它的许可证是 Apache-2.0，与 Blender 的 GPL 不同，
  只能参考思路，不能整段抄进你的 GPL 插件）。
]

=== 6.6.3 写原生库：一个完整可编译的例子

下面的例子在本书的核对环境里*实际编译并运行过*（见「验证」小节）。
它在三平台都能用同一份源码。完整的 C 文件、Python 绑定和测试脚本一并随书提供。
#example-file("ch06/native_probe")

#figure(
  kind: table,
  table(
    columns: (1.3fr, 4.2fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*平台*], [*编译命令*]),
    [#win], [`gcc -O2 -Wall -Wextra -shared -o probe_native.dll probe_native.c`],
    [#linux], [`gcc -O2 -Wall -Wextra -fPIC -shared -o libprobe_native.so probe_native.c -lm`],
    [#mac], [`cc -O2 -Wall -Wextra -dynamiclib -o libprobe_native.dylib probe_native.c`],
  ),
  caption: [三平台的编译命令。用 clang / MSVC 也可以，只是导出宏的写法不同],
) <tbl-native-build>

```c
/* examples/ch06/native_probe/probe_native.c（节选） */
#include <stddef.h>
#include <stdint.h>
#include <math.h>

#if defined(_WIN32)
#  define PROBE_EXPORT __declspec(dllexport)
#  define PROBE_CALL __cdecl
#else
#  define PROBE_EXPORT __attribute__((visibility("default")))
#  define PROBE_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* 版本号：Python 侧加载后应当先校验它，避免版本错配。
 * 注意用 uint32_t 而不是 int —— 跨边界时位宽必须明确。 */
PROBE_EXPORT uint32_t PROBE_CALL probe_abi_version(void)
{
  return 1u;
}

/* 把 count 个 float3 沿指定方向缩放。
 *   coords : 指向 float[count * 3] 的连续内存
 *   count  : 元素（顶点）个数
 *   factor : 缩放系数
 * 返回 0 成功，-1 参数非法。 */
PROBE_EXPORT int PROBE_CALL probe_scale_verts(float *coords, size_t count, float factor)
{
  if (coords == NULL || count == 0) {
    return -1;
  }
  if (!(factor == factor)) { /* NaN 自检 */
    return -1;
  }

  const size_t total = count * 3u;
  for (size_t i = 0; i < total; ++i) {
    coords[i] *= factor;
  }
  return 0;
}

/* 计算 float3 点集的轴对齐包围盒。由调用方提供输出缓冲。 */
PROBE_EXPORT int PROBE_CALL probe_bounds(const float *coords,
                                        size_t count,
                                        float *out_min,
                                        float *out_max)
{
  if (coords == NULL || count == 0 || out_min == NULL || out_max == NULL) {
    return -1;
  }
  ...
}

#ifdef __cplusplus
} /* extern "C" */
#endif
```

完整的源码还包含用于演示 GIL 的 `probe_busy_work`，同目录的
`probe_native.py` 给出全部 `ctypes` 签名，`probe_native_test.py` 负责数值与错误路径验证。

这段代码里的每一条约定都不是装饰，它们各自对应一类跨边界的经典故障：

#figure(
  kind: table,
  table(
    columns: (2.1fr, 3.3fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*约定*], [*不遵守会怎样*]),
    [`extern "C"` / `#[no_mangle]`], [C++ 编译器会做名字修饰（name mangling），`ctypes` 按原名找不到符号，报 `AttributeError: function 'foo' not found`],
    [`uint32_t` / `size_t` 等定宽类型], [`int` 在三平台未必同宽；`long` 在 Windows 是 32 位、在 Linux 是 64 位，这是最阴的一类 bug],
    [`PROBE_CALL`（`__cdecl`）], [Windows 上 32 位程序的默认调用约定可能是 `__stdcall`，参数被错误地弹栈。64 位下两者统一，所以这个 bug 只在 32 位目标上出现],
    [参数非空与范围自检], [`ctypes` 传来的指针不会自动校验。一次空指针解引用会让*整个 Blender* 崩溃，而不是抛异常],
    [不做 I/O、不打印], [标准输出在无界面模式下可能不可用；而且日志会与 Blender 自己的输出交错],
    [由调用方分配内存], [谁分配谁释放是唯一不会出错的所有权规则。跨 DLL 边界的 `free()` 在 Windows 上可能因 CRT 不同而崩溃],
  ),
  caption: [C ABI 的六条铁律，以及违反它们的实际后果],
) <tbl-cabi-rules>

=== 6.6.4 Python 侧：`ctypes` 的正确声明方式

`.restype` 与 `.argtypes` *必须*都设。不设的后果是 `ctypes` 按
默认规则猜：整数按 `int` 传、返回值按 `int` 解释。对 64 位指针来说
这是灾难 —— 指针会被截断成 32 位。

```python
import ctypes
import os
import sys

# 三平台的文件名约定与 Blender 官方 glTF addon 一致
if sys.platform == "win32":
    _LIB_NAME = "probe_native.dll"
elif sys.platform == "darwin":
    _LIB_NAME = "libprobe_native.dylib"
else:
    _LIB_NAME = "libprobe_native.so"


def load_library(addon_dir):
    """addon_dir 应当是这个插件包的目录（__file__ 所在目录）。"""
    lib_path = os.path.join(addon_dir, _LIB_NAME)
    if not os.path.isfile(lib_path):
        raise OSError("找不到原生库：%s" % lib_path)

    # CDLL（而不是 PyDLL）的关键区别：CDLL 在调用期间【释放 GIL】
    lib = ctypes.CDLL(lib_path)

    # ---- 逐个函数声明签名 ----
    lib.probe_abi_version.restype = ctypes.c_uint32
    lib.probe_abi_version.argtypes = []

    lib.probe_scale_verts.restype = ctypes.c_int
    lib.probe_scale_verts.argtypes = [
        ctypes.POINTER(ctypes.c_float),   # float*  （会被原地修改）
        ctypes.c_size_t,                  # size_t
        ctypes.c_float,                   # float
    ]

    lib.probe_bounds.restype = ctypes.c_int
    lib.probe_bounds.argtypes = [
        ctypes.POINTER(ctypes.c_float),   # const float*
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_float),   # float* out_min
        ctypes.POINTER(ctypes.c_float),   # float* out_max
    ]

    lib.probe_busy_work.restype = ctypes.c_double
    lib.probe_busy_work.argtypes = [ctypes.c_uint64]

    # ---- ABI 版本自检：一定要做 ----
    if lib.probe_abi_version() != 1:
        raise OSError("原生库 ABI 版本不匹配，请重新安装插件")

    return lib
```

=== 6.6.5 `numpy` 与原生库之间的零拷贝桥

这是整节最核心的一段。`numpy` 数组的底层就是一段连续内存，
`arr.ctypes.data_as(...)` 能把它变成 C 指针，*不复制数据*：

```python
import ctypes
import numpy as np


def scale_verts(lib, coords, factor):
    """coords: (n, 3) float32 数组，会被原地修改。"""
    # 1) 必须保证 C 连续，否则 C 侧按行优先读取会得到错位的数据
    coords = np.ascontiguousarray(coords, dtype=np.float32)

    n = coords.shape[0]
    ptr = coords.ctypes.data_as(ctypes.POINTER(ctypes.c_float))

    rc = lib.probe_scale_verts(ptr, ctypes.c_size_t(n), ctypes.c_float(factor))
    if rc != 0:
        raise RuntimeError("probe_scale_verts 返回错误码 %d" % rc)
    return coords


def bounds(lib, coords):
    """coords: (n, 3) float32 数组。返回 (min, max) 两个 (3,) 数组。"""
    coords = np.ascontiguousarray(coords, dtype=np.float32)
    n = coords.shape[0]

    out_min = np.empty(3, dtype=np.float32)
    out_max = np.empty(3, dtype=np.float32)

    rc = lib.probe_bounds(
        coords.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
        ctypes.c_size_t(n),
        out_min.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
        out_max.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
    )
    if rc != 0:
        raise RuntimeError("probe_bounds 返回错误码 %d" % rc)
    return out_min, out_max
```

#pitfall[
  关于 `coords.ctypes.data_as(...)` 有三条必须记住：

  1. *`np.ascontiguousarray` 可能在无提示的情况下复制数据。*
     如果 `coords` 已经是连续的 `float32`，它是零开销的；
     否则你拿到的是副本，*对它的修改不会写回原数组*。
     需要「原地修改 + 确定无拷贝」时，先自己判断
     `arr.flags["C_CONTIGUOUS"]`。
  2. *指针的生命周期由 `numpy` 数组决定。* 一旦数组被垃圾回收，
     指针就是野指针。C 侧绝对不能把这个指针存下来以后再用 ——
     除非你显式 `arr = np.ascontiguousarray(...)` 并把它绑在
     某个活着的对象上。
  3. *`data_as` 不做类型检查。* 你可以把一个 `int32` 数组的指针
     声明成 `POINTER(c_float)`，`ctypes` 不会阻止你，
     结果是一堆乱码浮点数。类型必须靠你自己对齐。
]

=== 6.6.6 实测：符号解析、数值一致、错误路径与原地修改

本书在核对环境里实际执行了下面这条链路，全部通过：

```text
$ gcc -O2 -Wall -Wextra -shared -o probe_native.dll probe_native.c
（无警告，退出码 0）

$ blender -b --factory-startup --python probe_native_test.py
PROBE loaded C:\...\probe_native.dll
PROBE abi_version = 1
PROBE scale_verts rc = 0
PROBE bounds rc = 0  min = [8.09e-06 6.98e-06 1.37e-06]  max = [1.99999 1.99997 1.99997]
PROBE numpy check:  min = [8.09e-06 6.98e-06 1.37e-06]  max = [1.99999 1.99997 1.99997]
PROBE NULL guard rc = -1
PROBE ALL OK
```

四件事被验证了：

1. *符号能被找到*：`ctypes.CDLL` 成功解析了全部四个 `PROBE_EXPORT` 函数；
2. *数值正确*：C 侧算出的包围盒与 `numpy` 的 `co.min(axis=0)` /
   `co.max(axis=0)` 逐位相同；
3. *错误路径可用*：传 `None` 作为指针时 C 侧的 `NULL` 自检返回 `-1`，
   而不是崩溃；
4. *数据是原地修改的*：`probe_scale_verts(..., 2.0)` 之后
   `numpy` 侧看到的 `max` 从 1.0 变成 2.0。

=== 6.6.7 GIL 与线程：一个能改变架构的细节

`ctypes` 有两个加载器，它们对 GIL 的处理*完全不同*：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.5fr, 2.7fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*加载器*], [*调用期间 GIL*], [*什么时候用*]),
    [`ctypes.CDLL`], [*释放*], [绝大多数情况。原生计算能真正并行，不阻塞 Blender 的界面线程],
    [`ctypes.PyDLL`], [*保持*], [只有当 C 侧会回调 Python C API（`Py_*` 函数）时才需要],
    [`ctypes.WinDLL`], [*释放*], [Windows 上的 `stdcall` 约定库；64 位下与 `CDLL` 等价],
    [`ctypes.OleDLL`], [*释放*], [Windows COM；与本篇无关],
  ),
  caption: [`ctypes` 四种加载器对 GIL 的处理。选错会得到「多线程完全没加速」这种难以察觉的问题],
) <tbl-ctypes-loaders>

这一点在核对环境里被实测确认过：对一个约 5500 万次浮点开方运算的函数，
单次调用 0.055 秒；*用 4 个 Python 线程同时调用 4 次，总耗时 0.088 秒*
（比值 1.60，而不是 GIL 被全程持有的 4.00）。也就是说这些调用
确实并行跑在了多个核心上。

```python
import threading
import time


def run_concurrently(lib, n_threads=4, iterations=20_000_000):
    n = ctypes.c_uint64(iterations)

    def worker():
        lib.probe_busy_work(n)

    t = time.perf_counter()
    threads = [threading.Thread(target=worker) for _ in range(n_threads)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    return time.perf_counter() - t
```

#summary[
  这条性质给了你一个在纯 Python 里做不到的能力：
  *把一段重计算放到后台线程跑，界面不卡。*
  但要注意 C 侧*不能*碰任何 `bpy` 对象 —— 它没有 GIL 保护。
  正确做法是：Python 侧先把数据 `foreach_get` 成 `numpy` 数组，
  `numpy` 数组交给后台线程去调 C，结果算完再回主线程写回
  `bpy`。§5.5 的 `bpy.app.timers` 就是「回主线程」的现成机制。
]

=== 6.6.8 打包与分发

这一段和 §7 的打包流程是配合的。要点有三条：

==== 一、目录布局

原生库放在插件包*根目录旁边*，与文件名约定保持一致：

```text
my_addon/
├── __init__.py
├── probe_native.dll        # Windows
├── libprobe_native.so      # Linux
├── libprobe_native.dylib   # macOS
└── probe_core.py
```

`__init__.py` 里用 `os.path.dirname(__file__)` 定位：

```python
import os

_ADDON_DIR = os.path.dirname(os.path.abspath(__file__))
```

==== 二、不要打包所有平台的库

一个 zip 里同时放三平台的 `.dll` / `.so` / `.dylib` 会让体积翻倍，
而且 Blender 的扩展平台（§7 会讲）支持按平台分发的机制。
如果手动分发，就在加载失败时给一条清楚的错误信息，
而不是让用户看到 `OSError: [WinError 126]`：

```python
try:
    lib = load_library(_ADDON_DIR)
except OSError as exc:
    # 把它变成用户能看懂的话
    raise OSError(
        "本插件需要原生的 probe_native 库，但未能加载。"
        "请确认你下载的是与本机平台匹配的版本。原始错误：%s" % exc
    ) from exc
```

==== 三、许可证

你的库如果是动态加载的独立文件，通常可以和 GPL 插件共存；
但如果你把某个第三方库*静态链接*进了你的 `.dll`，
那个库的许可证就会约束整个插件。*分发前务必确认这一点* ——
Blender 的官方 addon 只用 Apache-2.0 / MIT 兼容的库，
正是出于这个原因。

=== 6.6.9 什么时候该考虑 PyO3 / cffi 而不是 `ctypes`

最后回答一个常见疑问：既然 `ctypes` 是标准库、零依赖，为什么还要别的？

- *cffi*：可以写 C 声明的字符串形式，编译期就能检查签名与结构体布局。
  适合接口复杂（结构体很多、回调很多）的库。代价是引入一个依赖。
- *PyO3（Rust）*：不是「加载一个库」，而是*生成一个真正的 Python 扩展模块*。
  你可以直接在 Rust 里操作 `PyObject`、抛 Python 异常、使用迭代器。
  代价是编译产物与 Python 版本、ABI 版本绑定，
  而 Blender 会随版本升级 Python（5.2 用的是 3.13，
  见 #src("build_files/build_environment/cmake/versions.cmake:381")），
  你必须为每个 Blender 版本重新编译。

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.6fr, 1.4fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*方案*], [*接口表达力*], [*构建复杂度*], [*何时选*]),
    [`ctypes`], [弱：只有标量与指针], [最低：不需要编译环境], [接口是「指针 + 长度」的扁平数据，绝大多数计算热点都属于这类],
    [`cffi`], [中：可描述结构体与回调], [中：需要 C 编译器或预编译], [接口里有结构体、联合体、函数指针],
    [PyO3], [强：完整的 Python C API], [高：要为每个 Python 版本编译], [需要与 Python 对象深度交互，或想用 Rust 的类型系统保证内存安全],
  ),
  caption: [三种接入方式的取舍。默认选 `ctypes`，只有它不够用时才升级],
) <tbl-native-options>

#exercise[
  *练习 6.6* 从零走完原生加速的完整链路：

  1. 用随书的 `examples/ch06/native_probe/probe_native.c` 作为模板，写一个
     `mesh_smooth.c`，导出
     `int mesh_smooth(float *coords, const int *edge_v1, const int *edge_v2, size_t edge_count, size_t vert_count, int iterations)`
     —— 按边邻接对顶点坐标做若干轮拉普拉斯平滑；
  2. 用 gcc / clang 编译成动态库，确保*零警告*；
  3. 写一个 `test_mesh_smooth.py`：
     建一个网格、`foreach_get` 出 `co`、
     用 `foreach_get("vertices", ...)` 取出每条边的两个顶点索引，
     调用原生函数，再 `foreach_set` 写回；
  4. 与一个纯 `numpy` 实现（用 `np.add.at` 做邻接累加）
     比较 20 万顶点时的耗时，记录两者的比值；
  5. 把 C 函数的参数顺序故意改一处（比如把 `vert_count` 与
     `edge_count` 对调）但*不*改 Python 侧的 `argtypes`，
     观察会发生什么 —— 这是体会「`ctypes` 不检查类型」最快的方式。
]

=== 6.6.10 C ABI 跨语言桥接的八类常见错误

前面几节讲的是"怎么接"，这里集中列出"接起来之后最容易错在哪"。

这些错误与"API 用错了"是两回事。它们的共同根源是*跨语言桥接本身的固有难点*：
Python 与原生库之间只隔着一层 C ABI，而 C ABI 只约定*符号名与调用约定*，
*不约定类型宽度、内存归属、对象生命周期与数据布局*。两端对这些的假设一旦不一致，
症状往往离根因很远 —— 数值变成乱码、同一份代码在 Windows 上正常却在 Linux 上崩溃、
或者偶发崩溃且与 GC 时机相关。

打包与分发、以及何时改用 PyO3 / cffi 的注意点写在各自小节里。

#figure(
  kind: table,
  table(
    columns: (1.6fr, 1.6fr, 2.4fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*类别*], [*症状*], [*根因与解法*]),
    [类型不匹配], [数值是乱码或 0],
    [漏设 `argtypes` / `restype`。64 位指针被当成 `int` 截断。逐个函数都设全],
    [类型不匹配], [`AttributeError: function 'x' not found`],
    [`extern "C"` 漏了，符号被 C++ 名字修饰。用 `nm` / `dumpbin` 查导出表],
    [宽度不匹配], [Windows 上正常、Linux 上崩],
    [`long` / `unsigned long` 的位宽在两平台不同。改用 `int64_t` / `uint64_t`],
    [GIL], [多线程没有任何加速],
    [用了 `ctypes.PyDLL`（保持 GIL），或 C 侧自己拿了 GIL 不还。改用 `CDLL`],
    [内存所有权], [随机崩溃、堆损坏],
    [跨 DLL 边界 `free()` 了别人 `malloc()` 的内存。规定「谁分配谁释放」],
    [生命周期], [偶发崩溃，与 GC 时机相关],
    [把 `numpy` 数组的裸指针存进 C 侧全局变量，数组后来被回收。要么复制数据，要么把数组也存进 C 侧结构],
    [数据布局], [结果错位、错行],
    [`numpy` 数组非 C 连续，或 dtype 与 C 侧不符。用 `np.ascontiguousarray(..., dtype=...)` 显式统一],
  ),
  caption: [原生加速的八类常见问题。前两类占实际排查时间的一半以上],
) <tbl-native-pitfalls>


