// ============================================================================
//  图：依赖图节点 / 关系 / 求值副本图（第 13 章必备图表）
//  用法（在章节文件里）：
//    #import "../figures/depsgraph.typ": fig-depsgraph
//    #figure(fig-depsgraph(), caption: [...])
//
//  事实来源（均已按本书采用的 Blender 源码版本核对）：
//   - source/blender/depsgraph/intern/depsgraph.hh:50    struct deg::Depsgraph
//   - source/blender/depsgraph/intern/depsgraph.hh:90    build_allocator
//   - source/blender/depsgraph/intern/depsgraph.hh:94    id_hash
//   - source/blender/depsgraph/intern/depsgraph.hh:99    id_nodes
//   - source/blender/depsgraph/intern/depsgraph.hh:129   entry_tags
//   - source/blender/depsgraph/intern/depsgraph.hh:135   operations
//   - source/blender/depsgraph/intern/node/deg_node.hh:159     struct Node（inlinks/outlinks）
//   - source/blender/depsgraph/intern/node/deg_node.hh:34      enum class NodeClass
//   - source/blender/depsgraph/intern/node/deg_node_operation.hh:257 struct OperationNode
//   - source/blender/depsgraph/intern/node/deg_node_operation.hh:291 evaluate
//   - source/blender/depsgraph/intern/depsgraph_relation.hh:20  RelationFlag（含 _CYCLIC）
//   - source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:269 id_copy_inplace_no_main
//   - source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:844 deg_update_eval_copy_datablock
//   - source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:1050 deg_eval_copy_is_needed
//   - source/blender/depsgraph/intern/eval/deg_eval.cc:61        EvaluationStage
//   - source/blender/depsgraph/intern/eval/deg_eval.cc:144       calculate_pending_parents_for_node
//   - source/blender/depsgraph/intern/eval/deg_eval.cc:409       deg_evaluate_task_pool_create
//   - source/blender/depsgraph/intern/eval/deg_eval.cc:477       has_animated_visibility 分支
//   - source/blender/depsgraph/intern/eval/deg_eval.cc:255       is_metaball_object_operation
//   - source/blender/depsgraph/DEG_depsgraph_query.hh:95         DEG_get_evaluated_id
//   - source/blender/makesdna/DNA_ID.h:730                       ID_TYPE_USE_COPY_ON_EVAL
//
//  排版注意：中文必须显式 font: font-zh + weight；本图按「1 单位 = 1cm」估算过每段
//  文字宽度（等宽拉丁 ≈ 0.6 × 字号/28.35 单位，中文 ≈ 字号/28.35 单位），并在两栏
//  之间留了 >= 0.16 的净空。改动任何文字后必须重新渲染确认不溢出、不重叠。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-primary, c-summary, c-pitfall

#let fig-depsgraph() = canvas(length: 1cm, {
  import draw: *

  let ink = luma(18%)
  let faint = luma(46%)
  let c0 = c-summary
  let c1 = c-part
  let c2 = c-tip
  let c3 = c-warn
  let c4 = c-pitfall

  // =========================================================================
  // ① 原数据与求值数据
  // =========================================================================
  rect((0.10, -0.10), (13.90, 5.10), radius: 4pt, fill: luma(98.6%), stroke: 0.7pt + luma(72%))
  content(
    (0.34, 4.82),
    text(font: font-zh, size: 8.2pt, weight: 700, fill: c0.darken(10%))[① 原数据与求值数据：copy-on-evaluation],
    anchor: "west",
  )
  content(
    (13.66, 4.82),
    text(font: font-zh, size: 6.2pt, fill: faint)[两个独立的 ID 实例；求值只写右边那个],
    anchor: "east",
  )

  // --- 左：原 ID ---
  rect((0.34, 1.30), (5.90, 4.46), radius: 3pt, fill: white, stroke: 0.9pt + c1)
  content(
    (0.52, 4.18),
    text(font: font-mono, size: 7.0pt, weight: 700, fill: c1.darken(15%))[ID \*id_orig],
    anchor: "west",
  )
  content(
    (5.72, 4.18),
    text(font: font-zh, size: 5.9pt, fill: faint)[用户编辑的那一份],
    anchor: "east",
  )
  line((0.50, 4.00), (5.74, 4.00), stroke: 0.4pt + c1.lighten(45%))
  for (i, ln) in (
    "Object ob;  /* name = \"OB_cube\" */",
    "ob.object_to_world = ...  // 用户的编辑",
    "ob.modifiers = [Subdiv, Bevel]",
    "ob.data -> Mesh（原始网格）",
  ).enumerate() {
    content(
      (0.52, 3.70 - i * 0.34),
      text(font: font-mono, size: 5.7pt, fill: ink)[#ln],
      anchor: "west",
    )
  }
  content(
    (0.52, 2.30),
    text(font: font-zh, size: 5.6pt, fill: faint)[（原数据由 bmain 拥有）],
    anchor: "west",
  )
  content(
    (0.52, 1.86),
    text(font: font-zh, size: 5.7pt, fill: faint)[所有编辑都写在这里；求值器不碰它。],
    anchor: "west",
  )
  content(
    (0.52, 1.58),
    text(font: font-mono, size: 5.5pt, fill: faint)[DEG_id_tag_update(ob, ID_RECALC_GEOMETRY)],
    anchor: "west",
  )

  // --- 中：求值副本（历史简称 COW，虚线框）---
  rect(
    (5.97, 1.30),
    (7.83, 4.46),
    radius: 3pt,
    fill: c0.lighten(96%),
    stroke: (paint: c0.lighten(25%), thickness: 0.7pt, dash: "dashed"),
  )
  content(
    (6.90, 4.06),
    text(font: font-zh, size: 6.6pt, weight: 700, fill: c0.darken(12%))[求值副本],
  )
  line((6.20, 3.88), (7.60, 3.88), stroke: 0.4pt + c0.lighten(45%))
  // 两条长名字各被拆成 3 行：续行必须以 "…" 起头，否则读起来像 6 个独立标识符，
  // 读者会拿它们去源码里逐个搜、搜不到（与"省略号插在词中间"是同一类后果）。
  // 【实测】本该用 ↳ (U+21B3)，但 fontTools 查了 book/fonts/ 全部 8 个字体，
  // U+21B3 一个都没有（会渲染成缺字方框）；U+2026 (…) 8 个字体全有，故用它。
  // 名字取 "…" 后不加空格：加空格会让 "… SET_COPIED_ON_" 变成 16 格 = 1.83cm，
  // 超过框内可用宽度（框宽 1.86cm）。
  for (i, ln) in (
    "deg_expand_",
    "…eval_copy_",
    "…datablock()",
    "BKE_id_copy_ex",
    "LIB_ID_COPY_",
    "…SET_COPIED_ON_",
    "…WRITE",
  ).enumerate() {
    content(
      (6.90, 3.62 - i * 0.32),
      text(font: font-mono, size: 5.4pt, fill: ink)[#ln],
    )
  }

  // 复制箭头
  line((5.93, 2.88), (5.99, 2.88), stroke: 0.8pt + c0, mark: (end: ">", scale: 0.4))
  line((7.81, 2.88), (7.87, 2.88), stroke: 0.8pt + c0, mark: (end: ">", scale: 0.4))

  // --- 右：求值 ID ---
  rect((7.90, 1.30), (13.66, 4.46), radius: 3pt, fill: white, stroke: 0.9pt + c2)
  content(
    (8.08, 4.18),
    text(font: font-mono, size: 7.0pt, weight: 700, fill: c2.darken(15%))[ID \*id_cow（求值数据）],
    anchor: "west",
  )
  content(
    (13.48, 4.18),
    text(font: font-zh, size: 5.9pt, fill: faint)[求值器唯一写入目标],
    anchor: "east",
  )
  line((8.06, 4.00), (13.50, 4.00), stroke: 0.4pt + c2.lighten(45%))
  for (i, ln) in (
    "id_cow->orig_id = id_orig;  // 指回原 ID",
    "ob_cow.object_to_world = ...  // 求值结果",
    "ob_cow.modifiers = [...]  // 每项已求值",
    "ob_cow.data -> Mesh（已变形）",
  ).enumerate() {
    content(
      (8.08, 3.70 - i * 0.34),
      text(font: font-mono, size: 5.7pt, fill: ink)[#ln],
      anchor: "west",
    )
  }
  content(
    (8.08, 2.30),
    text(font: font-zh, size: 5.6pt, fill: faint)[（求值副本由 depsgraph 拥有）],
    anchor: "west",
  )
  content(
    (8.08, 1.86),
    text(font: font-zh, size: 5.7pt, fill: faint)[界面、渲染、导出全部读这一份。],
    anchor: "west",
  )
  content(
    (8.08, 1.58),
    text(font: font-mono, size: 5.5pt, fill: faint)[DEG_get_evaluated_id(depsgraph, id)],
    anchor: "west",
  )

  // =========================================================================
  // ② 图结构
  // =========================================================================
  rect((0.10, -6.30), (13.90, -0.40), radius: 4pt, fill: luma(98.6%), stroke: 0.7pt + luma(72%))
  content(
    (0.34, -0.66),
    text(font: font-zh, size: 8.2pt, weight: 700, fill: c1.darken(6%))[② 图结构：节点、关系与两张索引表],
    anchor: "west",
  )
  line((7.00, -0.14), (7.00, -0.56), stroke: 0.8pt + luma(50%), mark: (end: ">", scale: 0.45))
  content(
    (7.16, -0.25),
    text(font: font-zh, size: 5.9pt, fill: faint)[在同一个图里求值],
    anchor: "west",
  )

  rect((0.34, -6.06), (13.66, -0.92), radius: 3pt, fill: white, stroke: 0.9pt + c1)
  content(
    (0.52, -1.20),
    text(font: font-mono, size: 7.2pt, weight: 700, fill: c1.darken(15%))[struct deg::Depsgraph],
    anchor: "west",
  )
  content(
    (13.48, -1.20),
    text(font: font-zh, size: 5.9pt, fill: faint)[每次重建，不做原地增量改造],
    anchor: "east",
  )

  // IDNode
  rect((0.56, -5.36), (5.34, -1.46), radius: 2.5pt, fill: c1.lighten(95%), stroke: 0.6pt + c1.lighten(20%))
  content((0.74, -1.72), text(font: font-mono, size: 6.8pt, weight: 700, fill: c1.darken(20%))[IDNode], anchor: "west")
  line((0.72, -1.88), (5.18, -1.88), stroke: 0.4pt + c1.lighten(45%))
  for (i, ln) in (
    "id_orig / id_cow / components",
    "每个 ID 一个，持有求值副本指针",
    "",
    "ComponentNode（COMPONENT）",
    "  GEOMETRY / TRANSFORM / ANIMATION",
    "  PARAMETERS / COPY_ON_EVAL / ...",
    "  持有 operations 列表",
  ).enumerate() {
    if ln != "" {
      content(
        (0.74, -2.14 - i * 0.34),
        text(font: font-mono, size: 5.7pt, fill: ink)[#ln],
        anchor: "west",
      )
    }
  }

  // Relation
  rect((5.52, -5.36), (8.62, -1.46), radius: 2.5pt, fill: c2.lighten(95%), stroke: 0.6pt + c2.lighten(20%))
  content((5.70, -1.72), text(font: font-mono, size: 6.8pt, weight: 700, fill: c2.darken(20%))[Relation], anchor: "west")
  line((5.68, -1.88), (8.46, -1.88), stroke: 0.4pt + c2.lighten(45%))
  for (i, ln) in (
    "from -> to  （A -> B）",
    "name：调试用的标签",
    "flag：RelationFlag",
    "",
    "Node::inlinks ← 我依赖谁",
    "outlinks → 谁依赖我",
    "RELATION_FLAG_CYCLIC",
    "有环则环上的边不阻塞调度",
  ).enumerate() {
    if ln != "" {
      content(
        (5.70, -2.14 - i * 0.34),
        text(font: font-mono, size: 5.7pt, fill: ink)[#ln],
        anchor: "west",
      )
    }
  }

  // OperationNode
  rect((8.80, -5.36), (13.44, -1.46), radius: 2.5pt, fill: c3.lighten(96%), stroke: 0.6pt + c3.lighten(25%))
  content((8.98, -1.72), text(font: font-mono, size: 6.8pt, weight: 700, fill: c3.darken(22%))[OperationNode], anchor: "west")
  line((8.96, -1.88), (13.28, -1.88), stroke: 0.4pt + c3.lighten(45%))
  for (i, ln) in (
    "opcode / evaluate",
    "num_links_pending（待完成入边）",
    "一次具体计算，回调即求值函数",
    "",
    "DepsEvalOperationCb evaluate;",
    "  -> BKE_object_eval_uber_data(..)",
    "  -> BKE_object_eval_constraints",
    "  -> deg_create_eval_copy(...)",
  ).enumerate() {
    if ln != "" {
      content(
        (8.98, -2.14 - i * 0.34),
        text(font: font-mono, size: 5.7pt, fill: ink)[#ln],
        anchor: "west",
      )
    }
  }

  // 索引表与根集合
  content(
    (0.56, -5.66),
    text(font: font-zh, size: 5.9pt, fill: faint)[查找索引：],
    anchor: "west",
  )
  content(
    (1.60, -5.66),
    text(font: font-mono, size: 5.6pt, fill: ink)[id_hash（ID* -> IDNode*） id_nodes（有序 ID 列表） operations（扁平求值数组）],
    anchor: "west",
  )
  content(
    (0.56, -5.92),
    text(font: font-zh, size: 5.9pt, fill: faint)[整图重建：],
    anchor: "west",
  )
  content(
    (1.60, -5.92),
    text(font: font-mono, size: 5.6pt, fill: ink)[build_allocator（LinearAllocator） entry_tags（被直接标脏的根集合）],
    anchor: "west",
  )

  // =========================================================================
  // ③ 求值
  // =========================================================================
  rect((0.10, -12.60), (13.90, -6.60), radius: 4pt, fill: luma(98.6%), stroke: 0.7pt + luma(72%))
  content(
    (0.34, -6.86),
    text(font: font-zh, size: 8.2pt, weight: 700, fill: c4.darken(4%))[③ 求值：四个阶段 + 计数式拓扑调度],
    anchor: "west",
  )
  line((7.00, -6.34), (7.00, -6.76), stroke: 0.8pt + luma(50%), mark: (end: ">", scale: 0.45))
  content(
    (7.16, -6.45),
    text(font: font-zh, size: 5.9pt, fill: faint)[只跑被标脏的子图],
    anchor: "west",
  )

  let stages = (
    (key: "COPY_ON_EVAL", col: c1, l1: "先只跑 COPY_ON_EVAL", l2: "保证后续操作看到的", l3: "求值数据已展开",
     note: "避免环里看到未展开数据", file: "deg_eval.cc:248"),
    (key: "DYNAMIC_VISIBILITY", col: c3, l1: "跑影响可见性的操作", l2: "刷新 affects_visible_id", l3: "跳过看不见的重活",
     note: "has_animated_visibility", file: "deg_eval.cc:477"),
    (key: "THREADED_EVALUATION", col: c2, l1: "BLI_task_pool 多线程", l2: "num_links_pending 归零", l3: "才允许入队",
     note: "BLI_task_pool_suspended", file: "deg_eval.cc:409"),
    // note 是"触发原因"（行号跟着它），file 是"阶段入口"的位置，两者分开标注：
    // 元球/子帧的判据 is_metaball_object_operation 定义在 deg_eval.cc:199、调用在 :255；
    // 真正跑单线程兜底的是 :365 的 evaluate_graph_single_threaded_if_needed()。
    (key: "SINGLE_THREADED", col: c4, l1: "少数不安全节点", l2: "元球 / 子帧模拟", l3: "退回单线程跑完",
     note: "is_metaball_object_operation :255", file: "deg_eval.cc:365"),
  )
  // 长标识符的折行点：在 _ 之后插零宽空格（与 main.typ 处理长路径的做法一致）。
  // 卡片内宽只有 3.08cm，is_metaball_object_operation 在 5.4pt 下需要 3.20cm，
  // 只能折行，不能截断（截断出来的名字源码里查不到）。
  let brk = s => s.replace("_", "_\u{200B}")
  for (i, s) in stages.enumerate() {
    let x = 0.34 + i * 3.42
    let xr = x + 3.24
    rect((x, -9.90), (xr, -7.30), radius: 3pt, fill: s.col.lighten(95%), stroke: 0.8pt + s.col)
    content((x + 0.16, -7.58), text(font: font-mono, size: 6.7pt, weight: 700, fill: s.col.darken(22%))[#s.key], anchor: "west")
    line((x + 0.14, -7.76), (xr - 0.14, -7.76), stroke: 0.4pt + s.col.lighten(45%))
    for (j, l) in (s.l1, s.l2, s.l3).enumerate() {
      content((x + 0.16, -8.06 - j * 0.32), text(font: font-zh, size: 6.0pt, fill: ink)[#l], anchor: "west")
    }
    content((x + 0.16, -9.30), block(width: 3.00cm)[
      #text(font: font-mono, size: 5.4pt, fill: faint)[#brk(s.note)]
    ], anchor: "west")
    content((x + 0.16, -9.70), text(font: font-mono, size: 5.4pt, fill: faint)[#s.file], anchor: "west")
    if i < 3 {
      line((xr + 0.02, -8.60), (xr + 0.16, -8.60), stroke: 0.7pt + luma(45%), mark: (end: ">", scale: 0.4))
    }
  }

  // 结果去向
  line((7.00, -9.96), (7.00, -10.66), stroke: 0.8pt + luma(50%), mark: (end: ">", scale: 0.45))
  rect((0.34, -12.36), (13.66, -10.76), radius: 3pt, fill: c2.lighten(95%), stroke: 0.7pt + c2.lighten(20%))
  content(
    (0.52, -11.08),
    text(font: font-zh, size: 6.4pt, weight: 700, fill: c2.darken(15%))[求值完成后谁读这份数据],
    anchor: "west",
  )
  content(
    (0.52, -11.48),
    text(font: font-zh, size: 5.9pt, fill: ink)[界面、渲染、导出统一用 DEG_get_evaluated_id() / DEG_get_evaluated<T>() 取求值副本；],
    anchor: "west",
  )
  content(
    (0.52, -11.82),
    text(font: font-zh, size: 5.9pt, fill: ink)[极少数必须写回原数据的结果（动画 F-Curve、驱动的求值值），走 sync_writeback_callbacks 统一回写。],
    anchor: "west",
  )
  content(
    (0.52, -12.14),
    text(font: font-mono, size: 5.5pt, fill: faint)[DEG_get_evaluated_scene / DEG_get_evaluated_view_layer / DEG_get_original_id / DEG_is_original_id],
    anchor: "west",
  )
})
