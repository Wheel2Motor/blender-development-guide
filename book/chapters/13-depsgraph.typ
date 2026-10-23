#import "../common.typ": *
#import "../figures/depsgraph.typ": fig-depsgraph

= 第 13 章 依赖图与求值

第 12 章讲的编辑器负责"把数据画出来"。但画之前必须先有*求值结果*：
物体在世界空间里到底在哪、网格经过修改器之后到底长什么样、
驱动的目标属性这一刻到底等于多少。生产这些结果的是本章的主角 ——
*依赖图*（dependency graph，代码里统一缩写为 depsgraph，前缀 `DEG_`）。

依赖图是 Blender 里最"反直觉"也最关键的一个子系统。它的反直觉之处在于：
你在界面里改一个参数，*并不是*立刻算出新结果，而是往一张表上打个标记；
真正的计算发生在这一帧结束、下一次绘制开始之前，由框架统一调度。
这个设计换来的是三件东西：正确性（不依赖调用顺序）、速度（并行 + 跳过不可见）、
以及可扩展性（插件不需要知道别人依赖它）。

本章按"为什么 → 是什么 → 怎么算 → 谁在算 → 怎么查"的顺序展开。
读完你应该能回答：`DEG_id_tag_update()` 之后到底发生了什么，
为什么 `DEG_get_evaluated_*` 拿到的是另一个指针，以及
`DEG_` 与 `DRW_` 的分界线在哪里。

== 13.1 为什么需要依赖图：从递归更新到图求值

=== 13.1.1 递归更新的三个致命问题

在 Blender 2.8 之前，数据更新的组织方式可以粗略概括为*递归更新*：
某个操作符改了物体 A，就调用一串 `update` 函数，函数内部再调用别人，
一层层递归下去，顺便把自己标记为"需要重算"。这种写法在代码规模小、
数据类型少的时候能工作，但它有三个无法通过打补丁解决的问题：

*问题一：顺序决定结果。* 递归更新的正确性依赖于"调用者知道该先更新谁"。
如果 A 依赖 B，但改 A 的代码没有先去更新 B，A 就会用上一帧的 B 算出一个
*看起来合理但错误*的结果。这类 bug 极难定位 —— 因为结果不崩溃、不报警，
只是"差一点"。更糟的是它可能只在某个特定的操作顺序下出现。

*问题二：无法并行。* 递归更新本质上是一棵深度优先的调用树，
所有计算都发生在同一个线程里。而 2.8 之后 Blender 需要同时处理
几十万顶点的网格、多个视口、多个渲染层。单线程递归是硬上限。

*问题三：无法"跳过"。* 如果物体 A 被隐藏了，递归更新仍然会走完整棵树 ——
因为每一层不知道自己最终会不会被用到。反过来，如果为了性能在
某一层提前 `return`，就可能漏掉"别人依赖 A 的结果"这种情况。

*图求值* 用一个更昂贵但更结实的数据结构换来这三个问题的解：
把所有"数据"和"计算"显式表示成节点，把所有依赖显式表示成有向边，
然后*每次重建整张图*，再按依赖顺序调度。顺序由边的方向决定（问题一解决），
同层无依赖的节点可以并行（问题二解决），不可见分支可以整棵剪掉（问题三解决）。

#note[
  这不是无代价的。依赖图把一个"改了就立刻生效"的模型变成了
  "改了先标记、之后统一算"的模型。代价是*延迟*：你调完 API 之后
  读到的仍是旧值，必须显式触发求值。第二篇后面几章会反复遇到这个模式 ——
  它是理解 Blender 内部代码的关键。
]

=== 13.1.2 一次"改个参数"的完整路径

先用一张表把全局流程立起来。以"在属性编辑器里把某个修改器的参数
从 2 改成 3"为例：

#figure(
  kind: table,
  table(
    columns: (0.4fr, 2.2fr, 4fr),
    inset: 6pt,
    align: (right, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*步*], [*阶段*], [*发生什么*]),
    [1], [界面事件], [按钮把一个 RNA 属性写入内存（第 9 章），随后调用 `RNA_def_property_update` 注册的通知回调],
    [2], [打标记], [`DEG_id_tag_update(id, ID_RECALC_GEOMETRY)` 被调用；它只*记录意图*，不做计算],
    [3], [传播标记], [`deg_graph_flush_updates()` 沿关系的方向把"需要更新"传播到所有下游节点，同时设置 C++ 侧的 `DEPSOP_FLAG_NEEDS_UPDATE`],
    [4], [求值], [`deg_evaluate_on_refresh()` 按四个阶段调度被标记的节点，回调里做真正的计算],
    [5], [写回/通知], [少部分结果写回原数据；编辑器收到 `DEG_editors_update` 通知后重画],
    [6], [读取], [界面与渲染调用 `DEG_get_evaluated_id()` 取求值副本，拿到参数 3 之后的结果],
  ),
  caption: [一次参数修改从界面到像素的六个阶段。],
) <tbl-update-pipeline>

本章的小节就是按这张表展开的：13.2 讲节点与关系（第 3、4 步的数据结构），
13.3 讲第 3–5 步，13.4 讲第 4 步里"谁在算"，13.5 讲怎么观察整个过程。

#figure(fig-depsgraph(), caption: [依赖图节点 / 关系 / 求值副本图。上方是原数据与 copy-on-evaluation 生成的求值数据两个独立实例；中间是图结构（`IDNode` → `ComponentNode` → `OperationNode`，`Relation` 是它们之间的有向边）；下方是求值的四个阶段与计数式拓扑调度。]) <fig-depsgraph>

== 13.2 节点、关系、组件；原数据与求值数据

=== 13.2.1 三类节点：`NodeClass` 与 `NodeType`

依赖图里的节点分三个"层级"（#src("source/blender/depsgraph/intern/node/deg_node.hh:34")）：

```cpp
/* source/blender/depsgraph/intern/node/deg_node.hh:34 */
enum class NodeClass {
  /* Types generally unassociated with user-visible entities,
   * but needed for graph functioning. */
  GENERIC = 0,
  /* [Outer Node] An "aspect" of evaluating/updating an ID-Block, requiring
   * certain types of evaluation behavior. */
  COMPONENT = 1,
  /* [Inner Node] A glorified function-pointer/callback for scheduling up
   * evaluation operations for components, subject to relationship
   * requirements. */
  OPERATION = 2,
};
```

注释里的 *Outer Node* 与 *Inner Node* 是理解整个数据结构的关键：

- *外层节点（`IDNode` + `ComponentNode`）* 是*容器与分类*。它们本身几乎不计算，
  只负责"这是哪个数据块"、"这是它的哪个方面（几何？变换？动画？）"。
- *内层节点（`OperationNode`）* 才持有真正的计算回调。

所有节点共同的基类是 `Node`（#src("source/blender/depsgraph/intern/node/deg_node.hh:159")），
它的核心就是入边和出边两张表：

```cpp
/* source/blender/depsgraph/intern/node/deg_node.hh:159（节选） */
struct Node {
  struct TypeInfo {
    TypeInfo(NodeType type, const char *type_name, int id_recalc_tag = 0);
    NodeType type;
    const char *type_name;
    int id_recalc_tag;
  };
  struct Stats {
    void reset();
    void reset_current();
    double current_time;   /* 当前这次求值花在这个节点上的时间 */
  };
  using Relations = Vector<Relation *>;

  std::string name;   /* 标识符，主要用于调试 */
  NodeType type;      /* 结构类型 */
  Relations inlinks;  /* 我依赖谁 */
  Relations outlinks; /* 谁依赖我 */
  Stats stats;
  int custom_flags;   /* 遍历算法的临时标记，各算法自行清理 */

  virtual std::string identifier() const;
  virtual void tag_update(Depsgraph *graph, eUpdateSource source) {}
  virtual OperationNode *get_entry_operation() { return nullptr; }
  virtual OperationNode *get_exit_operation() { return nullptr; }
  virtual NodeClass get_class() const;
};
```

`NodeType`（#src("source/blender/depsgraph/intern/node/deg_node.hh:49")）
是节点的具体种类。它把三类混在一个枚举里，靠名字区分：
`OPERATION`、`TIMESOURCE`、`ID_REF` 是内层与通用节点；其余全是组件类型 ——
`PARAMETERS`、`ANIMATION`、`TRANSFORM`、`GEOMETRY`、`SEQUENCER`、
`COMPOSITOR`、`LAYER_COLLECTIONS`、`COPY_ON_EVAL`、`OBJECT_FROM_LAYER`、
`HIERARCHY`、`AUDIO`、`ARMATURE`、`VISIBILITY`、`EVAL_POSE`、`BONE`、
`PARTICLE_SYSTEM`、`PARTICLE_SETTINGS`、`SHADING`、`POINT_CACHE`、
`IMAGE_ANIMATION`、`CACHE`、`BATCH_CACHE`、`INSTANCING`、`SYNCHRONIZATION`、
`NTREE_OUTPUT`、`NTREE_GEOMETRY_PREPROCESS`。

#tip[
  想知道"有没有现成的组件能挂"的时候，先读这个枚举。*组件是按"更新粒度"切的，
  不是按数据类型切的*：`TRANSFORM` 管位置/旋转/缩放（含父子关系与约束），
  `GEOMETRY` 管顶点数据（含修改器），`ANIMATION` 管 F-Curve，
  `PARAMETERS` 是"其它一切 RNA 属性"的兜底。所以"我想在读几何前做点事"
  应该挂 `GEOMETRY`，"我想在变换算完之后做点事"应该挂 `TRANSFORM`。
]

=== 13.2.2 关系：`Relation`

边就是 `Relation`（#src("source/blender/depsgraph/intern/depsgraph_relation.hh:35")）：

```cpp
/* source/blender/depsgraph/intern/depsgraph_relation.hh:34（节选） */
/* B depends on A (A -> B) */
struct Relation {
  Relation(Node *from, Node *to, const char *description) : from(from), to(to), name(description)
  {
  }
  void unlink();

  Node *from;       /* A */
  Node *to;         /* B */

  /* relationship attributes */
  const char *name; /* label for debugging */
  int flag = 0;     /* Bitmask of RelationFlag. */
};
```

方向约定要记牢：*`from -> to` 表示 `to` 依赖 `from`，数据从 `from` 流向 `to`*。
所以 `to->inlinks` 是"我依赖谁"，`from->outlinks` 是"谁依赖我"。

`name` 字段纯粹给调试用 —— `--debug-depsgraph` 输出里每条边后面那串
带引号的文字就是它（例如 `"Eval Order"`、`"Component"`、`"Parent"`）。
`flag` 是 `RelationFlag` 位掩码（#src("source/blender/depsgraph/intern/depsgraph_relation.hh:17")），
其中两个对求值行为有实质影响：

- `RELATION_FLAG_CYCLIC`：这条边被判定为环的一部分。求值时它会跳过
  "等待父节点"的计数（见 13.3.4），*不阻塞调度*。
- `RELATION_FLAG_NO_FLUSH`：脏标记*不会*沿这条边传播。

另外 `RELATION_FLAG_FLUSH_USER_EDIT_ONLY` 表示"只有用户编辑引起的标记
才沿这条边传播"，`RELATION_FLAG_GODMODE` 表示"环检测不能删掉这条边"。

=== 13.2.3 `IDNode`、`ComponentNode`、`OperationNode`

*`IDNode`*（#src("source/blender/depsgraph/intern/node/deg_node_id.hh:38")）
是每个数据块一个。最关键的字段就是那两个 ID 指针：

```cpp
/* source/blender/depsgraph/intern/node/deg_node_id.hh:71（节选） */
  /* Type of the ID stored separately, so it's possible to perform check whether evaluated copy is
   * needed without de-referencing the id_cow (which is not safe when ID is NOT covered by
   * copy-on-evaluation and has been deleted from the main database.) */
  ID_Type id_type;

  /* ID Block referenced. */
  ID *id_orig;

  /* Session-wide UUID of the id_orig. */
  uint id_orig_session_uid;

  /* Evaluated data-block.
   * Will be covered by the copy-on-evaluation system if the ID Type needs it. */
  ID *id_cow;

  /* Hash to make it faster to look up components. */
  Map<ComponentIDKey, ComponentNode *> components;
  ...
  eDepsNode_LinkedState_Type linked_state;
  bool is_visible_on_build;
  bool is_enabled_on_eval;
```

`id_orig` / `id_cow` 这一对是整章的枢纽，13.2.5 节专门讲。
`linked_state` 取值 `DEG_ID_LINKED_INDIRECTLY` / `VIA_SET` / `DIRECTLY`
（#src("source/blender/depsgraph/intern/node/deg_node_id.hh:27")），
它决定"这个数据块是不是本视图层直接可见的" —— 这是可见性优化的输入。

*`ComponentNode`*（#src("source/blender/depsgraph/intern/node/deg_node_component.hh:33")）
是 ID 的一个"方面"：

```cpp
/* source/blender/depsgraph/intern/node/deg_node_component.hh:117（节选） */
  IDNode *owner;

  /* Operations stored as a hash map, for faster build.
   * This hash map will be freed when graph is fully built. */
  Map<ComponentNode::OperationIDKey, OperationNode *> *operations_map;

  /* This is a "normal" list of operations, used by evaluation
   * and other routines after construction. */
  Vector<OperationNode *> operations;

  OperationNode *entry_operation;
  OperationNode *exit_operation;

  virtual bool depends_on_cow() { return true; }

  /* Denotes whether copy-on-eval component is to be tagged when this component
   * is tagged for update. */
  virtual bool need_tag_cow_before_update(const IDRecalcFlag /*tag*/) { return true; }

  bool possibly_affects_visible_id;
  bool affects_visible_id;
```

两个数据结构并存的原因写在注释里：*建图期用哈希表*（`operations_map`，
按 `OperationIDKey` 快速查找/去重），*建完图后换成数组*（`operations`，
求值时顺序遍历更快），哈希表在 `ComponentNode::finalize_build()` 里释放。

`entry_operation` / `exit_operation` 是组件的"入口"和"出口"。
外部只跟这两个操作打交道，组件内部怎么排是它自己的事 ——
这是"封装"在图里唯一的体现。

各组件类型的区别靠 C++ 虚函数表达
（#src("source/blender/depsgraph/intern/node/deg_node_component.hh:192")）。
例如 `BatchCacheComponentNode` 覆盖 `need_tag_cow_before_update()` 返回 `false`
（批量缓存是绘制期数据，不需要求值副本），`ShadingComponentNode` 同理。

*`OperationNode`*（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:257")）
才是真正干活的：

```cpp
/* source/blender/depsgraph/intern/node/deg_node_operation.hh:257（节选） */
struct OperationNode : public Node {
  ...
  /* Component that contains the operation. */
  ComponentNode *owner;

  /* Callback for operation. */
  DepsEvalOperationCb evaluate;

  /* How many inlinks are we still waiting on before we can be evaluated. */
  uint32_t num_links_pending;
  bool scheduled;

  /* Identifier for the operation being performed. */
  OperationCode opcode;
  int name_tag;
  int flag;
};
```

三个字段要记住：

- *`evaluate`* 是 `std::function<void(blender::Depsgraph *)>`
  （`DepsEvalOperationCb`，#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:28")）。
  这个回调在*建图时*就绑好了，通常是一个 lambda，里面调用真正的计算函数。
- *`num_links_pending`* 是"还差几个上游没算完"。它就是 13.3.4 节要讲的
  计数式拓扑排序的核心。
- *`flag`* 是 `OperationFlag` 位掩码（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:227")），
  最重要的两个是 `DEPSOP_FLAG_NEEDS_UPDATE`（需要重算）与
  `DEPSOP_FLAG_USER_MODIFIED`（由用户编辑引起，会沿边传播）。
  `DEPSOP_FLAG_CLEAR_ON_EVAL` 是"求值完就清掉的那几个位"的集合。

`opcode` 是 `OperationCode`（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:31")），
一个 100 多项的枚举，把操作分成"通用 / 层级 / 动画驱动 / 场景 / 物体 /
变换 / 刚体 / 几何 / 姿态 / 骨骼 / 粒子 / 缓存 / 集合 / 求值副本 / 着色 /
光照链接 / 节点树 / 遮罩 / 影片剪辑 / 图像 / 同步 / 序列器 / 合成 / 实例"若干组。
每个 `OperationCode` 都带一个 id_recalc_tag，用于"求值完把哪些
`ID_RECALC_*` 位回写到求值数据上"。

=== 13.2.4 `Depsgraph` 本身

图对象是 `deg::Depsgraph`（#src("source/blender/depsgraph/intern/depsgraph.hh:50")）。
字段很多，按用途分组看最清楚：

```cpp
/* source/blender/depsgraph/intern/depsgraph.hh:50（节选） */
struct Depsgraph {
  using OperationNodes = Vector<OperationNode *>;
  using IDDepsNodes = Vector<IDNode *>;

  Depsgraph(Main *bmain, Scene *scene, ViewLayer *view_layer, eEvaluationMode mode);
  ...
  /* Core Graph Functionality ........... */

  /**
   * Used to decrease the cost of allocating many small structs when building the graph. This is a
   * viable strategy because the graph is rebuilt from scratch rather than changed in-place.
   */
  LinearAllocator<> build_allocator;

  /* <ID : IDNode> mapping from ID blocks to nodes representing these
   * blocks, used for quick lookups. */
  Map<const ID *, IDNode *> id_hash;

  /* Ordered list of ID nodes, order matches ID allocation order. */
  IDDepsNodes id_nodes;

  /* Top-level time source node. */
  TimeSourceNode *time_source;
  ...
  /* Nodes which have been tagged as "directly modified". */
  Set<OperationNode *> entry_tags;
  ...
  /* All operation nodes, sorted in order of single-thread traversal order. */
  OperationNodes operations;

  /* Spin lock for threading-critical operations. */
  SpinLock lock;

  Main *bmain;
  Scene *scene;
  ViewLayer *view_layer;
  eEvaluationMode mode;

  float frame;
  float ctime;
  Scene *scene_cow;
  ...
  /* The number of times this graph has been evaluated. */
  uint64_t update_count;
```

需要特别理解的是 `build_allocator` 的注释：*"This is a viable strategy because
the graph is rebuilt from scratch rather than changed in-place."*
依赖图不加支持增量修改的复杂度，而是每次从零重建，于是所有小对象都可以从
一个线性分配器（`LinearAllocator`）里切出来，回收时整体释放 ——
这比 `malloc`/`free` 几十万次快得多。这个取舍解释了后面很多设计。

三个索引表的用途不同：`id_hash` 是 `ID* -> IDNode*` 的查找表；
`id_nodes` 是有序数组（顺序与 ID 分配顺序一致，注释说明这是为了
"不同遍历之间保持稳定顺序"）；`operations` 是*扁平的*操作数组，
求值时就是遍历它来调度。

=== 13.2.5 Copy-on-evaluation：原数据与求值数据

这是本章最重要的概念。

*原数据（original）* 是你编辑的那一份。它由 `Main` 拥有，存进 `.blend` 文件，
Python 的 `bpy.data.objects["Cube"]` 拿到的就是它。

*求值数据（evaluated / COW copy）* 是求值器唯一写入的那一份。
它由依赖图拥有，不存盘，界面、渲染、导出全部读它。

#note[
  *COW* 是沿用至今的历史缩写，原本展开为 *copy-on-write*；它不能展开成
  “copy-on-eval”或“Copy on Evaluate”。Blender 在 2024 年把依赖图机制的正式称呼
  改为 *copy-on-evaluation*，以强调副本在求值流程中生成，而不是经典意义上等到
  首次写入才复制。`id_cow`、`scene_cow`、`deg_eval_copy_on_write.*` 等名称是尚未
  全部改掉的历史痕迹。本书只在对应这些既有标识符时继续使用 COW。当前称呼可直接见
  #src("source/blender/makesdna/DNA_ID.h:453-458")；命名变更记录见
  #weblink("https://projects.blender.org/blender/blender/pulls/118745", label: [Blender PR #118745])。
]

两份数据的关系是*双向指针*：求值数据里 `ID::orig_id` 指回原数据
（#src("source/blender/makesdna/DNA_ID.h:458")），并且被打上
`ID_TAG_COPIED_ON_EVAL` 标记（#src("source/blender/makesdna/DNA_ID.h:918")）。
判断"我拿到的是哪一份"就靠这个标记：

```cpp
/* source/blender/depsgraph/intern/depsgraph_query.cc:291（节选） */
bool DEG_is_original_id(const ID *id)
{
  /* Some explanation of the logic.
   *
   * What we want all the data-blocks which are created by copy-on-evaluation mechanism will be
   * tagged with ID_TAG_COPIED_ON_EVAL tag. Those data-blocks can not be original. */
  ...
}
```

#note[
  这里要纠正一个常见的误解。很多介绍性材料（包括本书任务清单里给出的线索）
  会说 COW 是由 `IDTypeInfo` 里的 `copy_on_write` 回调实现的。
  *在 Blender #blender-version 里没有这个字段。*
  `IDTypeInfo`（#src("source/blender/blenkernel/BKE_idtype.hh:145")）的全部字段是：
  `id_code`、`id_filter`、`dependencies_id_types`、`main_listbase_index`、
  `struct_size`、`name`、`name_plural`、`translation_context`、`flags`、
  `asset_type_info`、`init_data`、`copy_data`、`free_data`、`make_local`、
  `foreach_id`、`foreach_cache`、`foreach_path`、
  `foreach_working_space_color`、`owner_pointer_get`、`blend_write`、
  `blend_read_data`、`blend_read_after_liblink`、`blend_read_undo_preserve`、
  `lib_override_apply_post`。整个头文件里没有任何 `copy_on_write` 字段。
  Copy-on-evaluation 的实现在 depsgraph 模块内部，见下面。
]

哪些数据类型需要求值副本由一个宏决定
（#src("source/blender/makesdna/DNA_ID.h:672")）：

```c
/* source/blender/makesdna/DNA_ID.h:671 */
/* Check whether datablock type is covered by copy-on-evaluation. */
#define ID_TYPE_USE_COPY_ON_EVAL(_id_type) \
  (!ELEM(_id_type, ID_LI, ID_SCR, ID_VF, ID_BR, ID_WM, ID_PAL, ID_PC, ID_WS, ID_IM))
```

也就是说，*九类 ID 不生成求值副本*：库（`ID_LI`）、屏幕（`ID_SCR`）、
矢量字体（`ID_VF`）、笔刷（`ID_BR`）、窗口管理器（`ID_WM`）、
调色板（`ID_PAL`）、绘画曲线（`ID_PC`）、工作区（`ID_WS`）、图像（`ID_IM`）。
其余（场景、物体、网格、材质、节点树、动作、集合……）都要生成求值副本。
depsgraph 侧对应的函数是 `deg_eval_copy_is_needed()`：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:1050 */
bool deg_eval_copy_is_needed(const ID_Type id_type)
{
  return ID_TYPE_USE_COPY_ON_EVAL(id_type);
}
```

压缩与展开是两个不同的时刻，对应两个函数：

- *`deg_create_eval_copy()`*（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:1004")）
  在 `COPY_ON_EVAL` 操作里被调用，给 `IDNode` 分配一个空的、
  已挂上 `orig_id` 与 `ID_TAG_COPIED_ON_EVAL` 的求值副本。
- *`deg_expand_eval_copy_datablock()`*（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:747")）
  真正把数据拷过去。它的主体逻辑值得读一遍：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:747（节选） */
ID *deg_expand_eval_copy_datablock(const Depsgraph *depsgraph, const IDNode *id_node)
{
  const ID *id_orig = id_node->id_orig;
  ID *id_cow = id_node->id_cow;
  ...
  /* Copy data from original ID to a copied version. */
  /* First we handle special cases which are not covered by BKE_id_copy() yet.
   * or cases where we want to do something smarter than simple datablock copy. */
  const ID_Type id_type = GS(id_orig->name);
  switch (id_type) {
    case ID_SCE: {
      done = scene_copy_inplace_no_main(...);
      ...
    }
    case ID_ME: {
      /* TODO(sergey): Ideally we want to handle meshes in a special
       * manner here to avoid initial copy of all the geometry arrays. */
      break;
    }
    default:
      break;
  }
  if (!done) {
    done = id_copy_inplace_no_main(id_orig, id_cow);
  }
  ...
  /* Update pointers to nested ID datablocks. */
  deg_tag_eval_copy_id(...);
  BKE_library_foreach_ID_link(nullptr, id_cow, foreach_libblock_remap_callback, ...);
  update_id_after_copy(depsgraph, id_node, id_orig, id_cow);
  id_cow->recalc = id_cow_recalc;
  return id_cow;
}
```

它做的四件事：*复制*（`id_copy_inplace_no_main`，内部用 `BKE_id_copy_ex`
加 `LIB_ID_COPY_LOCALIZE | LIB_ID_CREATE_NO_ALLOCATE | LIB_ID_COPY_SET_COPIED_ON_WRITE`
三个标志，见 #src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:269")
与 #src("source/blender/blenkernel/BKE_lib_id.hh:265")）、
*重映射*（求值副本里的 ID 指针不能指向原数据，必须指向对应的求值副本，
靠 `BKE_library_foreach_ID_link` 遍历改指针）、
*打标记*（`ID_TAG_COPIED_ON_EVAL`）、
*恢复 recalc 位*（复制会覆盖 `recalc`，最后要还原）。

*场景是特例*：`ID_SCE` 走 `scene_copy_inplace_no_main()`，而且复制完还要调
`scene_setup_view_layers_before_remap()` 把视图层准备好。
这也是为什么 `Depsgraph` 单独缓存了一个 `scene_cow` 指针
（#src("source/blender/depsgraph/intern/depsgraph.hh:154")）——
场景是访问最频繁的求值数据。

#pitfall[
  Copy-on-evaluation 带来一个非常容易出错的地方：*同一个数据块有两个地址*。
  `ob` 和 `DEG_get_evaluated_id(depsgraph, ob)` 不是同一个指针。
  如果你把前者塞进一个需要"求值后数据"的 API，你会读到旧数据；
  把后者塞进一个会*写*数据的 API，你会污染求值结果（而且它下一帧就没了）。
  经验规则：*读显示/渲染用的数据用求值版，改数据用原版*。
  想知道某个 API 要哪一版，看它的参数名（`ob` vs `ob_eval`）和注释；
  拿不准时用 `DEG_is_original_id()` 断言。
]

== 13.3 标记脏、传播、拓扑调度、并行求值

=== 13.3.1 脏标记：`ID_RECALC_*`

标记用位掩码表达，定义在 #src("source/blender/makesdna/DNA_ID.h:1053") 起。
常用的一批：

#figure(
  kind: table,
  table(
    columns: (2.2fr, 0.9fr, 3.4fr),
    inset: 5pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*标记*], [*位*], [*含义*]),
    [`ID_RECALC_TRANSFORM`], [`1<<0`], [位置 / 旋转 / 缩放 / 父子关系变了],
    [`ID_RECALC_GEOMETRY`], [`1<<1`], [几何数据变了（含修改器），画面会变],
    [`ID_RECALC_ANIMATION`], [`1<<2`], [动画（F-Curve）结果变了],
    [`ID_RECALC_PSYS_REDO`], [`1<<3`], [粒子系统需要重算],
    [`ID_RECALC_SHADING`], [`1<<7`], [着色 / 材质变了，只需重编绘制的缓存],
    [`ID_RECALC_SELECT`], [`1<<9`], [选择状态变了，几何本身没变],
    [`ID_RECALC_BASE_FLAGS`], [`1<<10`], [视图层的 base 标记（可见性 / 可选性）变了],
    [`ID_RECALC_EDITORS`], [`1<<12`], [只需通知编辑器，不求值],
    [`ID_RECALC_SYNC_TO_EVAL`], [`1<<13`], [把原数据的改动同步到求值副本，但不重算依赖它的东西],
    [`ID_RECALC_FRAME_CHANGE`], [`1<<15`], [帧号变了],
    [`ID_RECALC_PARAMETERS`], [`1<<21`], [某个 RNA 参数变了],
    [`ID_RECALC_SOURCE`], [`1<<23`], [源头数据变了（如 `bNodeTree`）],
    [`ID_RECALC_NTREE_OUTPUT`], [`1<<25`], [节点树输出变了],
    [`ID_RECALC_HIERARCHY`], [`1<<26`], [集合 / 物体的层级结构变了],
    [`ID_RECALC_ALL`], [`0xffffffff`], [全部标记],
  ),
  caption: [`ID_RECALC_*` 常用取值，完整定义见 #src("source/blender/makesdna/DNA_ID.h:1053")–#src("source/blender/makesdna/DNA_ID.h:1191")。],
) <tbl-recalc-flags>

有几个复合宏也常常用到（同文件）：
`ID_RECALC_GEOMETRY_ALL_MODES = ID_RECALC_GEOMETRY | ID_RECALC_SYNC_TO_EVAL`
（#src("source/blender/makesdna/DNA_ID.h:1180")）、
`ID_RECALC_PSYS_ALL`（#src("source/blender/makesdna/DNA_ID.h:1190")）、
以及给未来预留的 `ID_RECALC_PROVISION_27` 到 `_31`
（#src("source/blender/makesdna/DNA_ID.h:1163")，注释说明它们存在是为了
让 `ID_RECALC_ALL` 的位检查不触发 sanitizer 警告）。

#tip[
  *选标记的经验规则*：改了会影响顶点坐标的东西 → `ID_RECALC_GEOMETRY`；
  只改了材质但几何不变 → `ID_RECALC_SHADING`（比重算几何便宜得多）；
  只改了选择集 → `ID_RECALC_SELECT`；
  只改了 UI 需要知道但求值不需要的东西 → `ID_RECALC_EDITORS`。
  标的过重会浪费 CPU（甚至触发整网格重算），标的过轻会让界面显示旧数据。
]

=== 13.3.2 `DEG_id_tag_update()` 的实现链

对外的入口在 #src("source/blender/depsgraph/DEG_depsgraph.hh:123")：

```cpp
/* source/blender/depsgraph/DEG_depsgraph.hh:122（节选） */
/** Tag given ID for an update in all the dependency graphs. */
void DEG_id_tag_update(ID *id, unsigned int flags);
void DEG_id_tag_update_ex(Main *bmain, ID *id, unsigned int flags);

void DEG_graph_id_tag_update(Main *bmain, Depsgraph *depsgraph, ID *id, unsigned int flags);
```

实现分三层（#src("source/blender/depsgraph/intern/depsgraph_tag.cc")）：

```cpp
/* source/blender/depsgraph/intern/depsgraph_tag.cc:843 */
void DEG_id_tag_update(ID *id, uint flags)
{
  DEG_id_tag_update_ex(G.main, id, flags);
}

/* source/blender/depsgraph/intern/depsgraph_tag.cc:848 */
void DEG_id_tag_update_ex(Main *bmain, ID *id, uint flags)
{
  if (id == nullptr) {
    /* Ideally should not happen, but old depsgraph allowed this. */
    return;
  }
  deg::id_tag_update(bmain, id, flags, deg::DEG_UPDATE_SOURCE_USER_EDIT);
}
```

注意 `G.main` —— `DEG_id_tag_update` 是"作用于当前主数据库的全部图"的版本；
`sandboxed`/后台场景应该用 `DEG_id_tag_update_ex` 显式传 `bmain`。

再往下（#src("source/blender/depsgraph/intern/depsgraph_tag.cc:663")）：

```cpp
/* source/blender/depsgraph/intern/depsgraph_tag.cc:663（节选） */
void id_tag_update(Main *bmain, ID *id, uint flags, eUpdateSource update_source)
{
  graph_id_tag_update(bmain, nullptr, id, flags, update_source);
  for (deg::Depsgraph *depsgraph : deg::get_all_registered_graphs(bmain)) {
    graph_id_tag_update(bmain, depsgraph, id, flags, update_source);
  }

  if (update_source & DEG_UPDATE_SOURCE_USER_EDIT) {
    BKE_lib_override_id_tag_on_deg_tag_from_user(id);
  }

  /* Accumulate all tags for an ID between two undo steps, so they can be
   * replayed for undo. */
  id->recalc_after_undo_push |= deg_recalc_flags_effective(nullptr, flags);
}
```

这里出现了"*所有已注册的依赖图*"这个概念：一个 `Main` 上可以同时存在
多张图（主视口一张、渲染一张、合成预览一张……），
注册表在 #src("source/blender/depsgraph/intern/depsgraph_registry.hh:21")：

```cpp
/* source/blender/depsgraph/intern/depsgraph_registry.hh:21（节选） */
void register_graph(Depsgraph *depsgraph);
void unregister_graph(Depsgraph *depsgraph);
Span<Depsgraph *> get_all_registered_graphs(Main *bmain);
```

最后落到单张图的 `graph_id_tag_update()`
（#src("source/blender/depsgraph/intern/depsgraph_tag.cc:701")）。它做五件事：

1. *求值期间拒绝打标记*。开头就有一段保护 —— 如果 `graph->is_evaluating`
   为真，只打印一条警告并 `return`。这防止求值过程中自我触发造成无限循环。
2. *按位拆解*。`flags` 是一个位掩码，函数用 `bitscan_forward_clear_uint`
   逐个取出置位的标记，对每个标记调用
   `graph_id_tag_update_single_flag()`。注释解释了原因：*"Store original
   flag in the ID. Allows to have more granularity than a node-factory based
   flags."*
3. *回写 `id_cow->recalc`*（#src("source/blender/depsgraph/intern/depsgraph_tag.cc:734")）。
4. *用户编辑时同时写 `id->recalc`*。注释说明了为什么
   （#src("source/blender/depsgraph/intern/depsgraph_tag.cc:736")）：
   撤销/重做会重建整张图，只有把标记存进原数据，重建后才知道要补算哪些。
5. *累积到 `recalc_after_undo_push`*，供撤销重放。

`graph_id_tag_update_single_flag()` 把"哪个标记"翻译成"哪个组件的哪个操作"
（#src("source/blender/depsgraph/intern/depsgraph_tag.cc:769") 起的一长串
`case`）：`ID_RECALC_TRANSFORM` → `TRANSFORM` 组件，`ID_RECALC_GEOMETRY` →
`GEOMETRY` 组件，`ID_RECALC_ANIMATION` → `ANIMATION` 组件，等等。
翻译完成后，被标记的 `OperationNode` 被塞进 `graph->entry_tags`
（#src("source/blender/depsgraph/intern/depsgraph.hh:129")）——
"被直接标脏的根集合"。

=== 13.3.3 传播：`flush`

`entry_tags` 只是*根*。它们下游的节点也必须重算，把"需要更新"沿边传播下去
的过程叫 *flush*（#src("source/blender/depsgraph/intern/eval/deg_eval_flush.cc")）。
入口是 `deg_graph_flush_updates()`，它在求值前被调用
（#src("source/blender/depsgraph/intern/eval/deg_eval.cc") 的
`deg_flush_updates_and_refresh()` 里，见
#src("source/blender/depsgraph/intern/depsgraph_eval.cc:41")）。

核心是一个广度优先的队列：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval_flush.cc:98（节选） */
inline void flush_schedule_entrypoints(Depsgraph *graph, FlushQueue *queue)
{
  for (OperationNode *op_node : graph->entry_tags) {
    queue->push_back(op_node);
    op_node->scheduled = true;
    DEG_DEBUG_PRINTF((::blender::Depsgraph *)graph,
                     EVAL,
                     "Operation is entry point for update: %s\n",
                     op_node->identifier().c_str());
  }
}
```

传播时每条边都要检查它的 `flag`：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval_flush.cc:163（节选） */
inline OperationNode *flush_schedule_children(OperationNode *op_node, FlushQueue *queue)
{
  if (op_node->flag & DEPSOP_FLAG_USER_MODIFIED) {
    IDNode *id_node = op_node->owner->owner;
    id_node->is_user_modified = true;
  }

  OperationNode *result = nullptr;
  for (Relation *rel : op_node->outlinks) {
    /* Flush is forbidden, completely. */
    if (rel->flag & RELATION_FLAG_NO_FLUSH) {
      continue;
    }
    /* Relation only allows flushes on user changes, but the node was not affected by user. */
    if ((rel->flag & RELATION_FLAG_FLUSH_USER_EDIT_ONLY) &&
        (op_node->flag & DEPSOP_FLAG_USER_MODIFIED) == 0)
    {
      continue;
    }
    OperationNode *to_node = static_cast<OperationNode *>(rel->to);
    /* Always flush flushable flags, so children always know what happened to their parents. */
    to_node->flag |= (op_node->flag & DEPSOP_FLAG_FLUSH);
    ...
  }
  return result;
}
```

#pitfall[
  两个"标记"名字很像但完全不同：
  `ID_RECALC_*`（`ID::recalc`）是*按数据块*的语义化标记，存在 ID 里；
  `DEPSOP_FLAG_*`（`OperationNode::flag`）是*按操作节点*的实现细节标记，
  只活在这一次求值里。
  调试时看到的 `--debug-depsgraph-tag` 输出是前者，
  `--debug-depsgraph-build` 输出里带 `DEPSOP_FLAG` 的是后者。
  两者的对应关系就是 `graph_id_tag_update_single_flag()` 里那一大串 `case`。
]

flush 完成后，每个需要重算的 `OperationNode` 都带上了
`DEPSOP_FLAG_NEEDS_UPDATE`；不需要的则没有。求值阶段就只执行带标记的节点。

=== 13.3.4 计数式拓扑排序

这是本章技术含量最高的一点。

常见的图求值实现是"先做一次拓扑排序，得到线性顺序，再按顺序执行"。
Blender *没有*这么做 —— 代码库里搜不到 `topological sort` 之类的函数。
它用的是*在线计数*：每个节点记一个"还差几个父节点没算完"，
父节点算完后就把子节点的计数减一，减到零就入队。
这相当于把拓扑排序融进了调度本身。

准备工作是给每个节点重算计数
（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:144")）：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval.cc:144（节选） */
void calculate_pending_parents_for_node(const DepsgraphEvalState *state, OperationNode *node)
{
  /* Update counters, applies for both visible and invisible IDs. */
  node->num_links_pending = 0;
  node->scheduled = false;
  /* Invisible IDs requires no pending operations. */
  if (!check_operation_node_visible(state, node)) {
    return;
  }
  /* No need to bother with anything if node is not tagged for update. */
  if ((node->flag & DEPSOP_FLAG_NEEDS_UPDATE) == 0) {
    return;
  }
  for (Relation *rel : node->inlinks) {
    if (rel->from->type == NodeType::OPERATION && (rel->flag & RELATION_FLAG_CYCLIC) == 0) {
      OperationNode *from = static_cast<OperationNode *>(rel->from);
      ...
      /* No need to wait for operation which is up to date. */
      if ((from->flag & DEPSOP_FLAG_NEEDS_UPDATE) == 0) {
        continue;
      }
      ++node->num_links_pending;
    }
  }
}
```

三个细节全在这里：*只数操作节点之间的入边*（组件节点不参与求值）；
*跳过已经是最新的上游*（它们不会被重新算，也就不会来"通知"）;
*跳过被标记为环的边*（否则环上的节点永远等不到计数归零）。

调度函数是 `schedule_node()`（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:276")）：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval.cc:276（节选） */
void schedule_node(DepsgraphEvalState *state,
                   OperationNode *node,
                   bool dec_parents,
                   const FunctionRef<void(OperationNode *)> schedule_fn)
{
  /* No need to schedule nodes of invisible ID. */
  if (!check_operation_node_visible(state, node)) {
    return;
  }
  /* No need to schedule operations which are not tagged for update. */
  if ((node->flag & DEPSOP_FLAG_NEEDS_UPDATE) == 0) {
    return;
  }
  if (dec_parents) {
    BLI_assert(node->num_links_pending > 0);
    atomic_sub_and_fetch_uint32(&node->num_links_pending, 1);
  }
  /* Can not schedule operation while its dependencies are not yet evaluated. */
  if (node->num_links_pending != 0) {
    return;
  }
  /* During the copy-on-eval stage only schedule copy-on-eval nodes. */
  if (!need_evaluate_operation_at_stage(state, node)) {
    return;
  }
  /* Actually schedule the node. */
  bool is_scheduled = atomic_fetch_and_or_uint8(reinterpret_cast<uint8_t *>(&node->scheduled),
                                                uint8_t(true));
  if (!is_scheduled) {
    if (node->is_noop()) {
      /* skip NOOP node, schedule children right away */
      schedule_children(state, node, schedule_fn);
    }
    else {
      /* children are scheduled once this task is completed */
      schedule_fn(node);
    }
  }
}
```

注意 `atomic_sub_and_fetch_uint32` 与 `atomic_fetch_and_or_uint8` ——
*计数与去重都是原子操作*，因为多个线程会同时减同一个节点的计数。
这是"计数式拓扑排序"能在多线程下工作的关键：不需要全局排序，
每个节点自己的状态就足以决定"是否具备执行条件"。

还有两处性能优化值得注意：

- *`node->is_noop()` 的短路*（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:269")：
  `return bool(evaluate) == false;`）。没有回调的节点（纯占位、用于连接关系）
  不入队，直接递归调度它的子节点，省掉一次任务池往返。
- *`schedule_children` 里"一个子节点直接返回"*（
  #src("source/blender/depsgraph/intern/eval/deg_eval_flush.cc:157") 的注释：
  "One of the children will bypass the queue and will be returned as a function
  return value, so it can start being handled right away, without building too
  much of a queue."）。这减少了队列抖动。

=== 13.3.5 四个阶段与并行

求值的总入口是 `deg_evaluate_on_refresh()`
（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:420")）。
它先把 `entry_tags` 是否为空作为快速退出条件，然后依次执行四个阶段：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval.cc:61 */
enum class EvaluationStage {
  /* Stage 1: Only Copy-on-Write operations are to be evaluated, prior to anything else.
   * This allows other operations to access its dependencies when there is a dependency cycle
   * involved. */
  COPY_ON_EVAL,

  /* Evaluate actual ID nodes visibility based on the current state of animation and drivers. */
  DYNAMIC_VISIBILITY,

  /* Threaded evaluation of all possible operations. */
  THREADED_EVALUATION,

  /* Workaround for areas which can not be evaluated in threads.
   *
   * For example, meta-balls, which are iterating over all bases and are requesting dupli-lists
   * to see whether there are meta-balls inside. */
  SINGLE_THREADED_WORKAROUND,
};
```

为什么必须是这个顺序？看主函数的注释
（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:456")）：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval.cc:456（节选） */
  /* Evaluation happens in several incremental steps:
   *
   * - Start with the copy-on-evaluation operations which never form dependency cycles. This will
   *   ensure that if a dependency graph has a cycle evaluation functions will always "see" valid
   *   expanded datablock. It might not be evaluated yet, but at least the datablock will be valid.
   *
   * - If there is potentially dynamically changing visibility in the graph update the actual
   *   nodes visibilities, so that actual heavy data evaluation can benefit from knowledge that
   *   something heavy is not currently visible.
   *
   * - Multi-threaded evaluation of all possible nodes.
   *   Certain operations (and their subtrees) could be ignored. For example, meta-balls are not
   *   safe from threading point of view, so the threaded evaluation will stop at the metaball
   *   operation node.
   *
   * - Single-threaded pass of all remaining operations. */
```

对应到代码：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval.cc:473（节选） */
  TaskPool *task_pool = deg_evaluate_task_pool_create(&state);

  evaluate_graph_threaded_stage(&state, task_pool, EvaluationStage::COPY_ON_EVAL);

  if (graph->has_animated_visibility || graph->need_update_nodes_visibility) {
    state.need_update_pending_parents = true;
    evaluate_graph_threaded_stage(&state, task_pool, EvaluationStage::DYNAMIC_VISIBILITY);
    deg_graph_flush_visibility_flags_if_needed(graph);
    state.need_update_pending_parents = true;
  }

  evaluate_graph_threaded_stage(&state, task_pool, EvaluationStage::THREADED_EVALUATION);

  BLI_task_pool_free(task_pool);

  evaluate_graph_single_threaded_if_needed(&state);
  ...
  deg_graph_clear_tags(graph);
```

四个阶段的设计意图：

1. *先执行 `COPY_ON_EVAL`*，因为它*永远不会形成环*（它只是"复制自己"），
   所以能保证后面的操作看到的求值数据"至少是合法的"—— 可能还没算完，
   但指针有效、结构完整。这是把环的破坏性降到最低的巧妙做法。
2. *`DYNAMIC_VISIBILITY` 只在有动态可见性时才执行*
   （`has_animated_visibility` 或 `need_update_nodes_visibility`）。
   它只执行带 `DEPSOP_FLAG_AFFECTS_VISIBILITY` 的操作，算完刷新
   `affects_visible_id`，让第 3 阶段能跳过"看不见的重活"。
3. *`THREADED_EVALUATION`* 是主战场，用任务池并行。
   `check_operation_node_visible()`（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:126")）
   在这里过滤掉不可见的数据块。
4. *`SINGLE_THREADED_WORKAROUND`* 处理线程不安全的少数节点。
   触发条件是 `is_metaball_object_operation()`
   （#src("source/blender/depsgraph/intern/eval/deg_eval.cc:199")，元球要遍历所有
   base 并请求 dupli-list）与 `is_modifier_subframe_operation()`
   （#src("source/blender/depsgraph/intern/eval/deg_eval.cc:216")，
   流体域 / 动态绘画画布会直接改别的物体，有竞态，见 #115636）。
   判定到这类节点时，第 3 阶段*把它排除*并设置 `need_single_thread_pass`，
   留到第 4 阶段用普通队列串行执行。

任务池的创建有一个重要分支：

```cpp
/* source/blender/depsgraph/intern/eval/deg_eval.cc:409 */
TaskPool *deg_evaluate_task_pool_create(DepsgraphEvalState *state)
{
  if (G.debug & G_DEBUG_DEPSGRAPH_NO_THREADS) {
    return BLI_task_pool_create_no_threads(state);
  }

  return BLI_task_pool_create_suspended(state, TASK_PRIORITY_HIGH);
}
```

这就是 `--debug-depsgraph-no-threads` 的作用：把并行版换成单线程版，
用来判断"某个 bug 是不是并发引起的"。

#warn[
  求值期间会释放 Python 的 GIL，因为 Python 驱动表达式需要在其它线程里执行
  （#src("source/blender/depsgraph/intern/eval/deg_eval.cc:440")：
  `BPy_BEGIN_ALLOW_THREADS`，注释指向 #91046）。这意味着*求值回调里的
  Python 代码可能在非主线程执行*。写驱动表达式时不要假设自己持有 GIL
  之外的东西，也不要在里面碰界面数据。
]

=== 13.3.6 查询：`DEG_get_evaluated_*` 与朋友

求值完成后，读结果统一用 `DEG_depsgraph_query.hh` 里的函数。
注意 *`DEG_get_evaluated_object()` 这个函数在 #blender-version 里不存在* ——
物体也走通用接口：

```cpp
/* source/blender/depsgraph/DEG_depsgraph_query.hh:86（节选） */
Scene *DEG_get_evaluated_scene(const Depsgraph *graph);
ViewLayer *DEG_get_evaluated_view_layer(const Depsgraph *graph);

/** Get evaluated version of given ID data-block. */
ID *DEG_get_evaluated_id(const Depsgraph *depsgraph, ID *id);
const ID *DEG_get_evaluated_id(const Depsgraph *depsgraph, const ID *id);

template<typename T> T *DEG_get_evaluated(const Depsgraph *depsgraph, T *id)
{
  static_assert(dna::is_ID_v<T>);
  return reinterpret_cast<T *>(DEG_get_evaluated_id(depsgraph, reinterpret_cast<ID *>(id)));
}

/** Get original version of given evaluated ID data-block. */
ID *DEG_get_original_id(ID *id);
const ID *DEG_get_original_id(const ID *id);
```

所以"拿到物体的求值版"应该写 `DEG_get_evaluated<Object>(depsgraph, ob)`
或 `DEG_get_evaluated_id(depsgraph, &ob->id)`，而不是
`DEG_get_evaluated_object(...)`。模板版本会做 `dna::is_ID_v<T>` 静态断言，
传错类型编译不过 —— 这是有意的保护。

完整的查询 API 分组：

#figure(
  kind: table,
  table(
    columns: (2.5fr, 0.6fr, 3.2fr),
    inset: 5pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*作用*]),
    [`DEG_get_input_scene`], [44], [建图时用的原场景],
    [`DEG_get_input_view_layer`], [47], [建图时用的原视图层],
    [`DEG_get_bmain`], [50], [建图时用的 `Main`],
    [`DEG_get_mode`], [53], [`DAG_EVAL_VIEWPORT` 还是 `DAG_EVAL_RENDER`],
    [`DEG_get_ctime`], [56], [最后一次求值用的时间（经时间重映射后的帧号）],
    [`DEG_id_type_updated`], [65], [某类 ID 是否被标记过更新],
    [`DEG_get_eval_flags_for_id`], [72], [该 ID 的额外求值标记（如"需要曲线路径"）],
    [`DEG_get_evaluated_scene`], [86], [求值后的场景],
    [`DEG_get_evaluated_view_layer`], [92], [求值后的视图层],
    [`DEG_get_evaluated_id` / `DEG_get_evaluated<T>`], [95], [求值后的数据块],
    [`DEG_get_evaluated_rna_pointer`], [112], [把 RNA 指针翻译成指向求值副本的 RNA 指针],
    [`DEG_get_original_id` / `DEG_get_original<T>`], [117], [求值副本 → 原数据],
    [`DEG_get_depsgraph_by_id`], [140], [从这个 ID 反查它所属的图（缓存在 `id.runtime->depsgraph`）],
    [`DEG_is_original_id`], [148], [这个 ID 是原数据还是求值副本],
  ),
  caption: [`DEG_depsgraph_query.hh` 的查询 API。行号对应 #src("source/blender/depsgraph/DEG_depsgraph_query.hh")。],
) <tbl-deg-query-api>

`DEG_get_evaluated_view_layer` 的实现里有一个值得注意的细节 ——
它是*按名字查找*的（#src("source/blender/depsgraph/intern/depsgraph_query.cc:195")，
注释里写着 `/* Do name-based lookup. */ /* TODO(sergey): Can this be optimized? */`）：

```cpp
/* source/blender/depsgraph/intern/depsgraph_query.cc:204（节选） */
  ViewLayer *view_layer_orig = deg_graph->view_layer;
  ViewLayer *view_layer_cow = static_cast<ViewLayer *>(
      BLI_findstring(&scene_cow->view_layers, view_layer_orig->name, offsetof(ViewLayer, name)));
```

这是因为它不能靠指针比较：求值副本的视图层是复制出来的新对象。

另外 `DEG_get_evaluated_rna_pointer()`（#src("source/blender/depsgraph/intern/depsgraph_query.cc:221")）
是 Python 侧的桥梁。它要处理三种情况：ID 指针（直接换 `data`）、
姿态骨骼（按名字特查，注释说是为了骨骼关键帧这个高频路径）、
其它（先求 RNA 路径，再在求值副本上解析路径）。
找不到时会往 stderr 打一行 `Couldn't resolve RNA path` —— 你在终端里
看到这行，说明某处的依赖关系漏了，正在访问未求值的数据。

=== 13.3.7 图的构建与重建

求值之前必须先把图建出来。入口是一组 `DEG_graph_build_*`
（#src("source/blender/depsgraph/DEG_depsgraph_build.hh:38")）：

```cpp
/* source/blender/depsgraph/DEG_depsgraph_build.hh:37（节选） */
/** Build depsgraph for the given scene layer, and dump results in given graph container. */
void DEG_graph_build_from_view_layer(Depsgraph *graph);
void DEG_graph_build_for_all_objects(Depsgraph *graph);
void DEG_graph_build_for_render_pipeline(Depsgraph *graph);
void DEG_graph_build_for_compositor_preview(Depsgraph *graph);
void DEG_graph_build_from_ids(Depsgraph *graph, Span<ID *> ids);
void DEG_graph_build_from_collection(Depsgraph *graph, Collection *collection);
```

它们各自实例化一个"构建流水线"然后执行
（#src("source/blender/depsgraph/intern/depsgraph_build.cc:283")）：

```cpp
/* source/blender/depsgraph/intern/depsgraph_build.cc:283（节选） */
void DEG_graph_build_from_view_layer(Depsgraph *graph)
{
  deg::ViewLayerBuilderPipeline builder(graph);
  builder.build();
}
```

所有流水线共享同一个四步骨架
（#src("source/blender/depsgraph/intern/builder/pipeline.cc:88")）：

```cpp
/* source/blender/depsgraph/intern/builder/pipeline.cc:88（节选） */
void AbstractBuilderPipeline::build()
{
  double start_time = 0.0;
  if (G.debug & (G_DEBUG_DEPSGRAPH_BUILD | G_DEBUG_DEPSGRAPH_TIME)) {
    start_time = BLI_time_now_seconds();
  }

  build_step_sanity_check();
  build_step_nodes();
  build_step_relations();
  build_step_finalize();

  if (need_sanity_checks()) {
    do_sanity_checks(deg_graph_, ids_build_by_node_builder_, ids_build_by_relations_builder_);
  }

  if (G.debug & (G_DEBUG_DEPSGRAPH_BUILD | G_DEBUG_DEPSGRAPH_TIME)) {
    printf("Depsgraph built in %f seconds.\n", BLI_time_now_seconds() - start_time);
  }
}
```

*节点与关系分两步建，而且用两个不同的 builder*，这是设计上的关键取舍：

```cpp
/* source/blender/depsgraph/intern/builder/pipeline.cc:116（节选） */
void AbstractBuilderPipeline::build_step_nodes()
{
  /* Generate all the nodes in the graph first */
  std::unique_ptr<DepsgraphNodeBuilder> node_builder = construct_node_builder();
  node_builder->begin_build();
  build_nodes(*node_builder);
  node_builder->end_build();
  ...
}

/* source/blender/depsgraph/intern/builder/pipeline.cc:129（节选） */
void AbstractBuilderPipeline::build_step_relations()
{
  /* Hook up relationships between operations - to determine evaluation order. */
  std::unique_ptr<DepsgraphRelationBuilder> relation_builder = construct_relation_builder();
  relation_builder->begin_build();
  build_relations(*relation_builder);
  relation_builder->build_copy_on_write_relations();
  relation_builder->build_driver_relations();
  ...
}
```

先建完所有节点，再连关系 —— 这样"连关系"时任何节点都已经存在，
不用处理"引用了还没建的节点"。代价是必须保证两个 builder 覆盖同一批 ID，
所以 `do_sanity_checks()`（#src("source/blender/depsgraph/intern/builder/pipeline.cc:35")）
会比较两边记录的 ID 集合，不一致就 `CLOG_ERROR` 报出来 ——
*这是排查"图里有节点但关系缺失"的第一手工具*。

关系变化时的增量更新只有一条路：把整张图标记为"关系需要更新"，
下次求值时重建：

```cpp
/* source/blender/depsgraph/intern/depsgraph_build.cc:319（节选） */
void DEG_graph_tag_relations_update(Depsgraph *graph)
{
  DEG_DEBUG_PRINTF(graph, TAG, "%s: Tagging relations for update.\n", __func__);
  deg::Depsgraph *deg_graph = reinterpret_cast<deg::Depsgraph *>(graph);
  deg_graph->need_update_relations = true;
  ...
}
```

所以"往场景里加一个物体"、"改一个修改器的类型"这类*结构性*改动是昂贵的：
它们导致建图，而不是只导致几个节点重算。这也是为什么"拓扑结构不变"的
参数改动（比如把修改器的 amount 从 2 改成 3）非常快。

#tip[
  `DEG_graph_build_from_ids()` 和 `DEG_graph_build_from_collection()` 是给
  *局部求值*用的：只建"算这几样东西所需的最小图"。写插件做批量导出、
  或做资产缩略图时，用它们能省掉大量无关节点。
]

== 13.4 修饰器、约束、驱动在求值中的位置

前三节讲的是"机制"。这一节回答"谁在算" —— 把第 14 章要展开的三样东西
（修饰器、约束、驱动）先在图里定位。

=== 13.4.1 修饰器：`GEOMETRY` 组件的 `MODIFIER` 操作

建图时，每个物体的每个修改器都会得到一个 `OperationNode`
（#src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:925")）：

```cpp
/* source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:925（节选） */
void DepsgraphNodeBuilder::build_object_modifiers(Object *object)
{
  if (object->modifiers.is_empty()) {
    return;
  }

  const ModifierMode modifier_mode = (graph_->mode == DAG_EVAL_VIEWPORT) ? eModifierMode_Realtime :
                                                                           eModifierMode_Render;

  IDNode *id_node = find_id_node(&object->id);

  add_operation_node(&object->id,
                     NodeType::GEOMETRY,
                     OperationCode::VISIBILITY,
                     [id_node](blender::Depsgraph *depsgraph) {
                       deg_evaluate_object_modifiers_mode_node_visibility(depsgraph, id_node);
                     });

  for (const auto [modifier_index, modifier] : object->modifiers.enumerate()) {
    OperationNode *modifier_node = add_operation_node(
        &object->id, NodeType::GEOMETRY, OperationCode::MODIFIER, nullptr, modifier.name);
    ...
    /* Mute modifier mode if the modifier is not enabled for the dependency graph mode. */
    if ((modifier.mode & modifier_mode) == 0) {
      modifier_node->flag |= DEPSOP_FLAG_MUTE;
    }

    if (is_modifier_visibility_animated(object, &modifier)) {
      graph_->has_animated_visibility = true;
    }
  }
  ...
}
```

三个要点：

- *每个修改器一个节点，名字就是修改器名*（`modifier.name`）。
  所以求值日志里会看到形如 `Object_001/GEOMETRY/Subdivision` 的标识符。
- *不适用于当前模式的修改器被 `DEPSOP_FLAG_MUTE` 静音*。
  这就是"只在渲染时启用的修改器在视口里不算"的实现方式 ——
  不是求值时判断，而是建图时就静音。
- *可动画的可见性会把 `has_animated_visibility` 置真*，
  从而启用 `DYNAMIC_VISIBILITY` 阶段。

真正求值修改器栈的是 `BKE_object_eval_uber_data()`
（#src("source/blender/blenkernel/intern/object_update.cc:375")），
它是 `GEOMETRY_EVAL` 操作的回调
（#src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1754")）。
它按物体类型分派（#src("source/blender/blenkernel/intern/object_update.cc:179")）：

```cpp
/* source/blender/blenkernel/intern/object_update.cc:179（节选） */
void BKE_object_handle_data_update(Depsgraph *depsgraph, Scene *scene, Object *ob)
{
  DEG_debug_print_eval(depsgraph, __func__, ob->id.name, ob);

  /* includes all keys and modifiers */
  switch (ob->type) {
    case OB_EMPTY: { empty_object_update(depsgraph, scene, ob); break; }
    case OB_MESH: { ... bke::mesh_data_update(*depsgraph, *scene, *ob, cddata_masks); break; }
    case OB_ARMATURE: { BKE_pose_where_is(depsgraph, scene, ob); break; }
    case OB_MBALL: { BKE_mball_data_update(depsgraph, scene, ob); break; }
    ...
  }
}
```

修改器栈本身在 `bke::mesh_data_update()` → `modifier_modify_mesh_and_geometry_set()`
里逐个执行（#src("source/blender/blenkernel/intern/mesh_data_update.cc:206")）：

```cpp
/* source/blender/blenkernel/intern/mesh_data_update.cc:206（节选） */
static Mesh *modifier_modify_mesh_and_geometry_set(ModifierData *md,
                                                  const ModifierEvalContext &mectx,
                                                  Mesh *input_mesh,
                                                  GeometrySet &geometry_set)
{
  Mesh *mesh_output = nullptr;
  const ModifierTypeInfo *mti = BKE_modifier_get_info(md->type);
  if (mti->modify_geometry_set == nullptr) {
    mesh_output = BKE_modifier_modify_mesh(md, &mectx, input_mesh);
  }
  else {
    ...
    geometry_set.replace_mesh(input_mesh, GeometryOwnershipType::Editable);
    /* Let the modifier change the geometry set. */
    mti->modify_geometry_set(md, &mectx, &geometry_set);
    ...
  }
  return mesh_output;
}
```

所以第 14 章讲的 `ModifierTypeInfo` 回调（`modify_mesh` / `deform_mesh` /
`modify_geometry_set`）就是在这里被调用的。*依赖图负责"什么时候调"，
`ModifierTypeInfo` 负责"调什么"*。

#note[
  `Object::modifiers` 在求值副本里也是一份独立列表。几何节点修改器
  （`eModifierType_Nodes`）有特殊处理：它在建图时注册了一个额外回调，
  把 `DEPSOP_FLAG_USER_MODIFIED` 转写成修改器自己的
  `eModifierFlag_UserModified` 标记（
  #src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:946")）。
  原因是几何节点需要知道"这次重算是用户改的，还是别人引起的"，
  两者对缓存的处理策略不同。
]

=== 13.4.2 约束：`TRANSFORM` 组件的 `TRANSFORM_CONSTRAINTS` 操作

约束属于*变换*，不属于几何。建图时
（#src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1151")）：

```cpp
/* source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1144（节选） */
void DepsgraphNodeBuilder::build_object_constraints(Object *object)
{
  /* create node for constraint stack */
  Scene *scene_cow = get_cow_datablock(scene_);
  Object *object_cow = get_cow_datablock(object);
  add_operation_node(&object->id,
                     NodeType::TRANSFORM,
                     OperationCode::TRANSFORM_CONSTRAINTS,
                     [scene_cow, object_cow](blender::Depsgraph *depsgraph) {
                       BKE_object_eval_constraints(depsgraph, scene_cow, object_cow);
                     });
}
```

`BKE_object_eval_constraints()`（#src("source/blender/blenkernel/intern/object_update.cc:94")）
只有十几行，因为求解细节在 BKE 约束模块里：

```cpp
/* source/blender/blenkernel/intern/object_update.cc:94（节选） */
void BKE_object_eval_constraints(Depsgraph *depsgraph, Scene *scene, Object *ob)
{
  bConstraintOb *cob;
  float ctime = BKE_scene_ctime_get(scene);

  DEG_debug_print_eval(depsgraph, __func__, ob->id.name, ob);

  /* evaluate constraints stack */
  cob = BKE_constraints_make_evalob(depsgraph, scene, ob, nullptr, CONSTRAINT_OBTYPE_OBJECT);
  BKE_constraints_solve(depsgraph, &ob->constraints, cob, ctime);
  BKE_constraints_clear_evalob(cob);
}
```

*顺序*很重要。物体变换的完整链条是
（#src("source/blender/blenkernel/intern/object_update.cc:391")）：

```cpp
/* source/blender/blenkernel/intern/object_update.cc:391（节选） */
void BKE_object_eval_transform_all(Depsgraph *depsgraph, Scene *scene, Object *object)
{
  BKE_object_eval_reset(depsgraph, object);
  BKE_object_eval_local_transform(depsgraph, object);
  if (object->parent) {
    BKE_object_eval_parent(depsgraph, object);
  }
  if (!object->constraints.is_empty()) {
    BKE_object_eval_constraints(depsgraph, scene, object);
  }
  BKE_object_eval_uber_transform(depsgraph, object);
  BKE_object_eval_transform_final(depsgraph, object);
}
```

对应的图结构是 `TRANSFORM_INIT` → `TRANSFORM_LOCAL` → `TRANSFORM_PARENT`
→ `TRANSFORM_CONSTRAINTS` → `TRANSFORM_EVAL` → `TRANSFORM_FINAL`
（opcode 定义见 #src("source/blender/depsgraph/intern/node/deg_node_operation.hh:70")）。
*约束在父子关系之后、最终矩阵之前* —— 这就是"约束解算使用父级已经算好的
世界矩阵，而约束结果会影响最终矩阵"这一语义在图里的体现。

骨骼约束是平行的一套：`BONE_CONSTRAINTS`
（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:133")），
位于 `BONE_POSE_PARENT` 之后、`BONE_READY` 之前。
`BONE_READY` 的注释解释了它为什么存在
（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:135")）：

```cpp
/* source/blender/depsgraph/intern/node/deg_node_operation.hh:134（节选） */
  /* Bone transforms are ready
   *
   * - "READY"  This (internal, noop) is used to signal that all pre-IK
   *            operations are done. Its role is to help mediate situations
   *            where cyclic relations may otherwise form (i.e. one bone in
   *            chain targeting another in same chain),
   *
   * - "DONE"   This noop is used to signal that the bone's final pose
   *            transform can be read by others. */
```

也就是说，*骨骼链里故意插了两个空操作（noop）作为"同步点"*，
用来把本来会形成环的依赖拆成两段。这是 13.3.4 节里
"`RELATION_FLAG_CYCLIC` 的边不阻塞调度"之外的另一种环处理手段：
*用 noop 打破环*。

=== 13.4.3 驱动：`PARAMETERS` 组件的 `DRIVER` 操作

驱动是"用表达式算出一个 RNA 属性的值"，所以它属于 `PARAMETERS` 组件，
而且*每个驱动一个节点*（#src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1356")）：

```cpp
/* source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1356（节选） */
void DepsgraphNodeBuilder::build_driver(ID *id, FCurve *fcurve, int driver_index)
{
  /* Create data node for this driver */
  ID *id_cow = get_cow_id(id);

  /* TODO(sergey): ideally we could pass the copy-on-eval of fcu, but since it
   * has not yet been allocated at this point we can't. As a workaround
   * the animation systems allocates an array so we can do a fast lookup
   * with the driver index. */
  ensure_operation_node(
      id,
      NodeType::PARAMETERS,
      OperationCode::DRIVER,
      [id_cow, driver_index, fcurve](blender::Depsgraph *depsgraph) {
        BKE_animsys_eval_driver(depsgraph, id_cow, driver_index, fcurve);
      },
      fcurve->rna_path ? fcurve->rna_path : "",
      fcurve->array_index);
  build_driver_variables(id, fcurve);
}
```

*节点的 `name` 是 `fcurve->rna_path`，`name_tag` 是 `array_index`* ——
所以一个 `location` 向量的三个分量是三个不同的驱动节点。
这是 `OperationIDKey` 里 `name` + `name_tag` 组合的典型用法。

`name_tag` 的存在也解释了那个 TODO：驱动被求值时，`fcurve` 指针仍是*原数据*
的，因为它指向的求值副本此刻还没分配；动画系统于是按 `driver_index`
在求值副本的驱动数组里查对应项。

还有一种特殊情况需要额外节点：如果驱动的目标属性是"共享数据"
（比如多个物体指向同一个网格），写它就等于改了别人看到的东西。
这时会加一个 `DRIVER_UNSHARE` 操作
（#src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1343")）：

```cpp
/* source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1343（节选） */
  if (!needs_unshare) {
    return;
  }

  ID *id_cow = get_cow_id(id);
  ensure_operation_node(id,
                        NodeType::PARAMETERS,
                        OperationCode::DRIVER_UNSHARE,
                        [id_cow](blender::Depsgraph *depsgraph) {
                          BKE_animsys_eval_driver_unshare(depsgraph, id_cow);
                        });
```

`OperationCode::DRIVER_UNSHARE` 的注释写着 *"Writes to RNA properties to
ensure implicitly-shared data is un-shared."*
（#src("source/blender/depsgraph/intern/node/deg_node_operation.hh:54")）。
这是隐式共享数据的经典 *copy-on-write*：先复制一份再改。它和依赖图 ID 的
copy-on-evaluation 不是同一件事，不能因为两处都出现“复制”就混用术语。

驱动的*变量*也要建成依赖：`build_driver_variables()`
（#src("source/blender/depsgraph/intern/builder/deg_builder_nodes.cc:1377")）
遍历 `DriverVar` 的每个目标，把目标属性建成图里的节点，
于是"驱动 A 依赖 B 的某个属性"变成一条真实的边，A 自然会在 B 之后求值。
如果驱动表达式里用了 `frame`（时间），建图时还会额外连一条时间依赖
（#src("source/blender/depsgraph/intern/builder/deg_builder_relations.cc:159")
里的 `BKE_driver_expression_depends_on_time(driver)`）——
这就是"驱动会随时间重新求值"的实现。

普通 F-Curve 动画走 `ANIMATION` 组件的 `ANIMATION_ENTRY` / `ANIMATION_EVAL` /
`ANIMATION_EXIT` 三个操作，入口是 `BKE_animsys_evaluate_animdata()`
（#src("source/blender/blenkernel/intern/anim_sys.cc:4004")，
调用点见 #src("source/blender/blenkernel/intern/anim_sys.cc:4048")
的 `animsys_evaluate_drivers()`）。

=== 13.4.4 三者的图内定位对照

#figure(
  kind: table,
  table(
    columns: (1fr, 1.5fr, 1.9fr, 2.6fr),
    inset: 5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*东西*], [*组件*], [*操作*], [*求值入口*]),
    [修饰器], [`GEOMETRY`], [`MODIFIER`（每个修改器一个，名字 = 修改器名）], [`BKE_object_eval_uber_data` → `mti->modify_geometry_set` / `BKE_modifier_modify_mesh`],
    [几何节点修改器], [`GEOMETRY` + `NTREE_*`], [`MODIFIER` + `NTREE_OUTPUT` + `NTREE_GEOMETRY_PREPROCESS`], [同上，最终走 `MOD_nodes` 的 `modify_geometry_set`],
    [物体约束], [`TRANSFORM`], [`TRANSFORM_CONSTRAINTS`], [`BKE_object_eval_constraints` → `BKE_constraints_solve`],
    [骨骼约束], [`BONE`], [`BONE_CONSTRAINTS`], [姿态求解内部，`BKE_pose_where_is` 链上],
    [驱动], [`PARAMETERS`], [`DRIVER`（名字 = `rna_path`，tag = 数组下标）], [`BKE_animsys_eval_driver`],
    [驱动写共享数据], [`PARAMETERS`], [`DRIVER_UNSHARE`], [`BKE_animsys_eval_driver_unshare`],
    [F-Curve 动画], [`ANIMATION`], [`ANIMATION_ENTRY` / `ANIMATION_EVAL` / `ANIMATION_EXIT`], [`BKE_animsys_evaluate_animdata`],
    [形状键], [`GEOMETRY`], [`GEOMETRY_SHAPEKEY`], [网格求值内部],
  ),
  caption: [修饰器 / 约束 / 驱动在依赖图里的位置。],
) <tbl-eval-locations>

#summary[
  这张表可以用一句话概括：*依赖图不关心"算什么"，只关心"什么依赖什么"*。
  每一类计算都只是某个组件里的某个操作，并且提供一个
  `DepsEvalOperationCb` 回调。想插入自己的计算，就找到正确的组件与操作位置，
  在正确的位置建一个节点并连上关系。
]

== 13.5 调试 depsgraph

依赖图的问题（"为什么这个物体没更新"、"为什么这一帧这么慢"）
没法靠读代码解决，必须靠观察。这一节是工具箱。

=== 13.5.1 命令行开关

全部开关注册在 #src("source/creator/creator_args.cc:3290")
到 #src("source/creator/creator_args.cc:3330")：

```c
/* source/creator/creator_args.cc:3290（逐行对应 :3290–:3330） */
  BLI_args_add(ba, nullptr, "--debug-depsgraph",
               CB_EX(arg_handle_debug_mode_generic_set, depsgraph),
               reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH));
  BLI_args_add(ba, nullptr, "--debug-depsgraph-build", ... G_DEBUG_DEPSGRAPH_BUILD);
  BLI_args_add(ba, nullptr, "--debug-depsgraph-eval",  ... G_DEBUG_DEPSGRAPH_EVAL);
  BLI_args_add(ba, nullptr, "--debug-depsgraph-tag",   ... G_DEBUG_DEPSGRAPH_TAG);
  BLI_args_add(ba, nullptr, "--debug-depsgraph-time",  ... G_DEBUG_DEPSGRAPH_TIME);
  BLI_args_add(ba, nullptr, "--debug-depsgraph-no-threads", ... G_DEBUG_DEPSGRAPH_NO_THREADS);
  BLI_args_add(ba, nullptr, "--debug-depsgraph-pretty",     ... G_DEBUG_DEPSGRAPH_PRETTY);
  BLI_args_add(ba, nullptr, "--debug-depsgraph-uid",        ... G_DEBUG_DEPSGRAPH_UID);
```

各行的精确行号：`--debug-depsgraph` 在 :3292、
`-build` :3297、`-eval` :3302、`-tag` :3307、`-time` :3312、
`-no-threads` :3318、`-pretty` :3323、`-uid` :3328。

#figure(
  kind: table,
  table(
    columns: (2.4fr, 3.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*开关*], [*输出什么 / 干什么*]),
    [`--debug-depsgraph`], [打开下面 build + eval + tag + time + uid 五项的并集（见 13.5.2 的宏定义）],
    [`--debug-depsgraph-build`], [建图过程：节点创建、关系添加、`Depsgraph built in N seconds.`；同时启用建图断言与 `CLOG` 错误],
    [`--debug-depsgraph-eval`], [每个求值操作一行（由 `DEG_debug_print_eval` 等打印）；刷新时还打印累积的 recalc 位],
    [`--debug-depsgraph-tag`], [每次打标记打印 `graph_id_tag_update: id=... flags=... source=...`，以及求值期打标记的警告],
    [`--debug-depsgraph-time`], [每节点耗时统计（需要 `do_time_debug()`），求值结束聚合打印],
    [`--debug-depsgraph-no-threads`], [把任务池换成单线程版（`BLI_task_pool_create_no_threads`），用于排查并发问题],
    [`--debug-depsgraph-pretty`], [日志带 ANSI 颜色，指针用固定颜色区分（`terminal_do_color()`）],
    [`--debug-depsgraph-uid`], [校验会话级唯一 ID：生成求值副本时调 `BKE_object_check_uids_unique_and_report`，序列器调 `seq::relations_check_uids_unique_and_report`],
  ),
  caption: [`--debug-depsgraph*` 系列开关。定义在 #src("source/creator/creator_args.cc:3290")–#src("source/creator/creator_args.cc:3330")。],
) <tbl-depsgraph-cli>

用法示例：

```bash
# 只观察打标记与求值，带颜色
$ blender --debug-depsgraph-tag --debug-depsgraph-eval --debug-depsgraph-pretty

# 排查并发 bug：关掉多线程
$ blender --debug-depsgraph --debug-depsgraph-no-threads

# 观察建图耗时与节点数
$ blender --debug-depsgraph-build --debug-depsgraph-time
```

#tip[
  `--debug-depsgraph-eval` 的输出量极大（每个操作一行），
  建议配合重定向只留关键部分：

  ```bash
  $ blender --background --debug-depsgraph-eval myfile.blend > dep.log 2>&1
  $ grep -n "GEOMETRY" dep.log | head -50
  ```

  在 Windows 上对应的写法是 `blender.exe ... > dep.log 2>&1`，
  然后用 `Select-String` 代替 `grep`（见附录 C）。
]

=== 13.5.2 位标志：`G_DEBUG_DEPSGRAPH_*`

开关最终设置的是 `G.debug` 的位（#src("source/blender/blenkernel/BKE_global.hh:252")）：

```cpp
/* source/blender/blenkernel/BKE_global.hh:252（节选） */
  G_DEBUG_DEPSGRAPH_BUILD = (1 << 8), /* depsgraph construction messages */
  G_DEBUG_DEPSGRAPH_EVAL = (1 << 9),  /* depsgraph evaluation messages */
  G_DEBUG_DEPSGRAPH_TAG = (1 << 10),  /* depsgraph tagging messages */
  G_DEBUG_DEPSGRAPH_TIME = (1 << 11), /* depsgraph timing statistics and messages */
  G_DEBUG_DEPSGRAPH_NO_THREADS = (1 << 12), /* single threaded depsgraph */
  G_DEBUG_DEPSGRAPH_PRETTY = (1 << 13),     /* use pretty colors in depsgraph messages */
  G_DEBUG_DEPSGRAPH_UID = (1 << 14),        /* Verify validness of session-wide identifiers */
  ...
  G_DEBUG_DEPSGRAPH = (G_DEBUG_DEPSGRAPH_BUILD | G_DEBUG_DEPSGRAPH_EVAL | G_DEBUG_DEPSGRAPH_TAG |
                       G_DEBUG_DEPSGRAPH_TIME | G_DEBUG_DEPSGRAPH_UID),
```

注意 `G_DEBUG_DEPSGRAPH` 的并集里*不含* `NO_THREADS` 与 `PRETTY` ——
这两个要单独加。

在 C++ 代码里读这些位的方式有两种，取决于有没有 `Depsgraph` 指针
（#src("source/blender/depsgraph/intern/debug/deg_debug.h:47")）：

```cpp
/* source/blender/depsgraph/intern/debug/deg_debug.h:47 */
#define DEG_DEBUG_PRINTF(depsgraph, type, ...) \
  do { \
    if (DEG_debug_flags_get(depsgraph) & G_DEBUG_DEPSGRAPH_##type) { \
      DEG_debug_print_begin(depsgraph); \
      fprintf(stdout, __VA_ARGS__); \
    } \
  } while (0)

#define DEG_GLOBAL_DEBUG_PRINTF(type, ...) \
  do { \
    if (G.debug & G_DEBUG_DEPSGRAPH_##type) { \
      fprintf(stdout, __VA_ARGS__); \
    } \
  } while (0)
```

*优先用第一个*：每张图可以有自己的调试位
（`DepsgraphDebug::flags`，#src("source/blender/depsgraph/intern/debug/deg_debug.h:29")），
通过 `DEG_debug_flags_set()` 单独设置。Python 侧就是这么做的。

`DepsgraphDebug` 类还负责计时与 "上次求值花了多久"
（#src("source/blender/depsgraph/intern/debug/deg_debug.h:17")）：

```cpp
/* source/blender/depsgraph/intern/debug/deg_debug.h:17（节选） */
class DepsgraphDebug {
 public:
  DepsgraphDebug();

  bool do_time_debug() const;

  void begin_graph_evaluation();
  void end_graph_evaluation();

  double total_evaluation_time() const;

  /* NOTE: Corresponds to G_DEBUG_DEPSGRAPH_* flags. */
  int flags;

  /* Name of this dependency graph (is used for debug prints, helping to distinguish graphs
   * created for different view layer). */
  std::string name;
  ...
};
```

`name` 字段的存在说明一件事：*一个会话里通常有多张图*，
调试输出必须能区分它们（比如 `Viewport` 与 `Render`）。

=== 13.5.3 Python 侧：`bpy.app.debug_depsgraph`

Python 侧对应 `bpy.app.debug_depsgraph` 及其变体，
注册在 #src("source/blender/python/intern/bpy_app.cc:602") 起：

```c
/* source/blender/python/intern/bpy_app.cc:596（节选，逐项行号 602–627） */
     reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH)},        /* :602 */
     reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH_BUILD)},  /* :607 */
     reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH_EVAL)},   /* :612 */
     reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH_TAG)},    /* :617 */
     reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH_TIME)},   /* :622 */
     reinterpret_cast<void *>(G_DEBUG_DEPSGRAPH_PRETTY)}, /* :627 */
```

所以可以在不重启 Blender 的情况下开调试：

```python
# 示意：运行中打开 depsgraph 求值日志
import bpy
bpy.app.debug_depsgraph = True
bpy.app.debug_depsgraph_eval = True
bpy.app.debug_depsgraph_tag = True

# 触发一次求值
bpy.context.view_layer.update()

# 查完关掉，否则输出会淹没终端
bpy.app.debug_depsgraph = False
bpy.app.debug_depsgraph_eval = False
bpy.app.debug_depsgraph_tag = False
```

`bpy.context.view_layer.update()` 是最常用的"手动触发一次求值"的方法，
对应第 3 步到第 5 步。写插件改完数据后需要立刻读到新结果时就用它。

#warn[
  `bpy.app.debug_depsgraph_*` 只影响*全局* `G.debug` 位，
  它是所有图共享的。所以打开它会同时打印视口图与渲染图，
  输出里必须靠 `DepsgraphDebug::name` 区分。
]

=== 13.5.4 `DEG_debug_*` API

程序化地检查图的状态，用 #src("source/blender/depsgraph/DEG_depsgraph_debug.hh")：

```cpp
/* source/blender/depsgraph/DEG_depsgraph_debug.hh:29（节选） */
void DEG_debug_flags_set(Depsgraph *depsgraph, int flags);
int DEG_debug_flags_get(const Depsgraph *depsgraph);

void DEG_debug_name_set(Depsgraph *depsgraph, const char *name);
const char *DEG_debug_name_get(Depsgraph *depsgraph);

/**
 * Obtain simple statistics about the complexity of the depsgraph.
 * \param[out] r_outer:      The number of outer nodes in the graph.
 * \param[out] r_operations: The number of operation nodes in the graph.
 * \param[out] r_relations:  The number of relations between (executable) nodes in the graph.
 */
void DEG_stats_simple(const Depsgraph *graph,
                      size_t *r_outer,
                      size_t *r_operations,
                      size_t *r_relations);

std::string DEG_debug_graph_to_dot(const Depsgraph &graph, StringRef label);
void DEG_debug_stats_gnuplot(const Depsgraph *graph,
                             FILE *fp,
                             const char *label,
                             const char *output_filename);
```

三个层次的自查工具：

- *`DEG_stats_simple()`*：只要数量。写性能报告或自动化测试时最方便 ——
  节点数暴涨通常意味着依赖关系失控。
- *`DEG_debug_graph_to_dot()`*：导出 Graphviz DOT。配合
  `dot -Tsvg` 可以看到整张图；实现见
  #src("source/blender/depsgraph/intern/debug/deg_debug_relations_graphviz.cc")。
- *`DEG_debug_stats_gnuplot()`*：导出每节点耗时的 gnuplot 数据，
  实现见 #src("source/blender/depsgraph/intern/debug/deg_debug_stats_gnuplot.cc")。
  这是"这一帧到底慢在哪个节点"的答案。

另外两个"体检"函数：

```cpp
/* source/blender/depsgraph/DEG_depsgraph_debug.hh:61（节选） */
/** Compare two dependency graphs. */
bool DEG_debug_compare(const Depsgraph *graph1, const Depsgraph *graph2);

/** Check that dependencies in the graph are really up to date. */
bool DEG_debug_graph_relations_validate(Depsgraph *graph,
                                        Main *bmain,
                                        Scene *scene,
                                        ViewLayer *view_layer);

/** Perform consistency check on the graph. */
bool DEG_debug_consistency_check(Depsgraph *graph);

std::string DEG_stringify_recalc_flags(unsigned int flags);
```

`DEG_debug_compare()` 比较两张图的结构是否一致 ——
典型用法是"同一场景建两次图，应该完全相同"。
`DEG_debug_graph_relations_validate()` 检查"图里声明的依赖是否真的都满足了"，
是排查"少了一条关系"的直接手段。
`DEG_debug_consistency_check()` 做整体一致性检查。

`DEG_stringify_recalc_flags()` 把位掩码翻译成人能读的字符串
（#src("source/blender/depsgraph/DEG_depsgraph_debug.hh:72") 的注释给了例子：
`DEG_stringify_recalc_flags(ID_RECALC_GEOMETRY | ID_RECALC_SHADING)` →
`"GEOMETRY, SHADING"`）。日志里那行
`id=OB_cube flags=GEOMETRY source=USER_EDIT` 就是它生成的。

#tip[
  排查"改了参数但画面不变"的固定流程：

  1. 开 `--debug-depsgraph-tag`，改参数。*有没有出现 tag 日志？*
     没有 → 你的代码根本没调 `DEG_id_tag_update`（或者 `bmain` 传错了）。
  2. 有 tag 日志，看 `flags=` 是什么。*标记对不对？*
     只标了 `ID_RECALC_EDITORS` 却期望几何重算 → 标记选轻了。
  3. 开 `--debug-depsgraph-eval`，看对应的操作*有没有被求值*。
     没有 → 依赖关系缺了，用 `DEG_debug_graph_relations_validate()` 确认。
  4. 有求值，看 `--debug-depsgraph-time` 的输出，确认它确实执行了。
     已执行但结果不对 → 问题在计算函数里，不在依赖图里。

  这四步能把"依赖图问题"与"计算问题"彻底分开，
  避免在错误的地方找 bug。
]

#summary[
  依赖图是 Blender 的"求值操作系统"。它把整个数据模型显式表示成
  `IDNode` → `ComponentNode` → `OperationNode` 三层节点与 `Relation` 有向边，
  每次结构性改动就重建整张图，每次数据改动就沿图传播脏标记，
  最后用计数式拓扑调度 + 任务池并行求值。
  原数据与求值数据通过 copy-on-evaluation 分离：
  编辑只碰原数据，求值只写求值副本，读取统一用 `DEG_get_evaluated_*`。
  这条链路解释了第二篇后面几章反复出现的三个模式：
  *标记而非立即计算*、*两个 ID 指针*、*重建而非增量修改*。
]

#exercise[
  *练习 13.1（读源码）* 读
  #src("source/blender/depsgraph/intern/depsgraph_tag.cc:701") 的
  `graph_id_tag_update()`，回答：（a）它在什么条件下直接 `return`，
  为什么（提示：看 `graph->is_evaluating`）？（b）它为什么要把标记同时写进
  `id_cow->recalc` 和（在某些情况下）`id->recalc`？（c）`recalc_after_undo_push`
  是给谁用的？

  *练习 13.2（读源码）* 读
  #src("source/blender/depsgraph/intern/eval/deg_eval.cc:144") 的
  `calculate_pending_parents_for_node()`，然后回答：
  （a）为什么只统计 `rel->from->type == NodeType::OPERATION` 的入边？
  （b）如果一个上游节点没有 `DEPSOP_FLAG_NEEDS_UPDATE`，为什么可以不计数？
  （c）`RELATION_FLAG_CYCLIC` 的边被排除会产生什么后果？
  再用 `--debug-depsgraph-build` 找一个真实存在环的场景
  （提示：骨骼链上互相约束、或两个物体互相驱动）验证你的理解。

  *练习 13.3（动手，小）* 写一个 Python 脚本，遍历 `bpy.data` 里的所有
  物体，对每个物体调用 `bpy.context.view_layer.update()` 前后分别
  用 `bpy.app.debug_depsgraph_eval` 观察求值次数。回答：
  为什么第二次 `update()` 的求值操作数远少于第一次？
  （提示：看 13.3.4 节 `node->flag & DEPSOP_FLAG_NEEDS_UPDATE` 的判断。）

  *练习 13.4（动手，中等）* 用 `DEG_debug_graph_to_dot()`
  导出当前视口图：在
  #src("source/blender/depsgraph/DEG_depsgraph_debug.hh") 里找到它的声明，
  临时在某个你方便触发的函数里调用它并 `fprintf` 到文件
  （或者直接用 Python 侧已有的接口，如果存在）。
  用 `dot -Tsvg` 渲染成 SVG，在里面找到 `OB_cube` 的 `GEOMETRY` 组件，
  数出它下游有多少个操作节点，并用源码核对每一个的来源。

  *练习 13.5（动手，进阶）* 求值副本的代价随几何数据量线性增长。
  读 #src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:796")
  那段关于网格的 TODO（*"Ideally we want to handle meshes in a special manner
  here to avoid initial copy of all the geometry arrays"*），
  然后：
  （a）说明为什么网格可以"延迟复制"而场景不行；
  （b）估算一下一个有 100 万顶点的网格每次生成求值副本要复制多少字节
  （提示：看 `Mesh` 的 DNA 结构和 `CustomData` 层）；
  （c）用 `--debug-depsgraph-time` 测量拖动一个 100 万顶点网格的物体时的
  每帧求值时间，判断瓶颈是否在求值副本的创建或刷新。
]
