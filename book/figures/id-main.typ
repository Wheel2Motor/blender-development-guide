// ============================================================================
//  图：ID / Main / 对象-数据块关系（第 9 章 9.5 节）
//  用法（在章节文件里）：
//    #import "../figures/id-main.typ": fig-id-main
//    #figure(fig-id-main(), caption: [Main 数据库、ID 引用关系、库链接与 override])
//
//  事实来源均按 blender-baseline.json 中的基准核对：
//   - source/blender/blenkernel/BKE_main.hh:239-        struct Main
//   - source/blender/blenkernel/BKE_main.hh:367-398     Main 里每种 ID 一条 ListBaseT
//   - source/blender/blenkernel/BKE_main.hh:673-705     FOREACH_MAIN_ID_BEGIN
//   - source/blender/blenkernel/BKE_main.hh:762-773     MainListsArray / BKE_main_lists_get
//   - source/blender/makesdna/DNA_ID.h:409-534          struct ID
//   - source/blender/makesdna/DNA_ID.h:427              ID.name[258]
//   - source/blender/makesdna/DNA_ID.h:415              ID.lib（指向 Library）
//   - source/blender/makesdna/DNA_ID.h:489              ID.override_library
//   - source/blender/makesdna/DNA_ID.h:643-669          ID_FAKE_USERS / ID_REAL_USERS / …
//   - source/blender/makesdna/DNA_ID.h:682              ID_IS_LINKED(_id)
//   - source/blender/makesdna/DNA_ID.h:744              GS(a)
//   - source/blender/makesdna/DNA_ID.h:313-358          IDOverrideLibrary(Property)
//   - source/blender/makesdna/DNA_ID.h:1278-1359        eID_Index / INDEX_ID_MAX
//   - source/blender/makesdna/DNA_scene_types.h:2905    Scene.master_collection
//   - source/blender/makesdna/DNA_object_types.h:466    struct Object（data / material_slots）
//   - source/blender/blenkernel/BKE_lib_override.hh:85-370  override 公开 API
//
//  注意：本图所有文字都以【字符串】传入；字符串不会被当成 Typst 标记解析，
//        因此这里不要写反引号或星号（会原样显示）。
//  排版注意：本图宽 15.6cm（版心 16.4cm）。改动任何文字后必须重渲染确认不重叠。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, html-figure

#let fig-id-main() = html-figure("fig-id-main", () => canvas(length: 1cm, {
  import draw: *

  let ptl(c, col) = text(font: font-zh, size: 6.8pt, weight: 700, fill: col)[#c]
  let mono(c, size: 5.9pt, col: luma(14%)) = text(
    font: font-mono,
    size: size,
    weight: 400,
    fill: col,
  )[#c]
  let monoB(c, size: 6.1pt) = text(
    font: font-mono,
    size: size,
    weight: 700,
    fill: luma(10%),
  )[#c]
  let sans(c, size: 5.9pt, col: luma(26%)) = text(
    font: font-zh,
    size: size,
    weight: 400,
    fill: col,
  )[#c]

  // 单行节点框
  let nd(x0, y0, x1, y1, col, c, dashed: false) = {
    let strk = if dashed {
      (paint: col, thickness: 0.7pt, dash: "dashed")
    }
    else {
      0.7pt + col
    }
    rect((x0, y0), (x1, y1), radius: 2pt, fill: col.lighten(95%), stroke: strk)
    content(((x0 + x1) / 2, (y0 + y1) / 2), monoB(c))
  }

  let arrow(x0, y0, x1, y1, dashed: false) = {
    let strk = if dashed {
      (paint: luma(48%), thickness: 0.65pt, dash: "dashed")
    }
    else {
      0.7pt + luma(42%)
    }
    line((x0, y0), (x1, y1), mark: (end: ">", scale: 0.42), stroke: strk)
  }

  let lbl(x, y, c, size: 5.8pt) = content(
    (x, y),
    text(font: font-mono, size: size, weight: 400, fill: luma(38%))[#c],
  )

  /* ============ ① 一个 .blend 文件 = 一个 Main 数据库 ============ */
  rect((0, 3.95), (15.6, 8.40), radius: 3pt, fill: c-part.lighten(97%), stroke: none)
  content(
    (0.15, 8.22),
    ptl("① 打开一个 .blend = 拿到一个 Main（bmain）；其中所有 ID 按类型挂在不同的链表上", c-part),
    anchor: "west",
  )

  // Main 结构体盒子
  rect(
    (0.22, 4.30),
    (4.60, 7.90),
    radius: 2.5pt,
    fill: c-part.lighten(93%),
    stroke: 0.8pt + c-part,
  )
  content(
    (2.41, 7.68),
    text(font: font-mono, size: 6.6pt, weight: 700, fill: c-part.darken(25%))[Main bmain],
  )
  let mrows = (
    "char filepath[1024]",
    "short versionfile",
    "ListBaseT<Scene> scenes",
    "ListBaseT<Object> objects",
    "ListBaseT<Mesh> meshes",
    "ListBaseT<Material> materials",
    "ListBaseT<Library> libraries",
    "… 共 33 种 ID 类型",
  )
  for (i, r) in mrows.enumerate() {
    content((2.41, 7.30 - 0.30 * i), mono(r))
  }
  content((2.41, 4.85), sans("每种 ID 一条按名字排序的双向链表"))
  content((2.41, 4.58), sans("FOREACH_MAIN_ID_BEGIN 逐一遍历"))

  // 具体数据块
  nd(5.40, 7.55, 9.00, 8.00, c-part, "Scene \"Scene\"")
  nd(11.20, 7.55, 15.50, 8.00, c-part, "World \"World\"")
  nd(5.40, 6.65, 9.00, 7.10, c-part, "Collection \"Col\"")
  nd(11.20, 6.65, 15.50, 7.10, c-part, "Material \"Mat\"")
  nd(5.40, 5.75, 9.00, 6.20, c-part, "Object \"Cube\"")
  nd(11.20, 5.75, 15.50, 6.20, c-part, "Mesh \"Cube\"")

  arrow(7.20, 7.53, 7.20, 7.12)
  lbl(7.48, 7.33, "master_collection")

  arrow(9.02, 7.775, 11.18, 7.775)
  lbl(9.90, 7.95, "world")

  arrow(7.20, 6.63, 7.20, 6.22)
  lbl(7.48, 6.43, "CollectionObject")

  arrow(9.02, 5.975, 11.18, 5.975)
  lbl(10.04, 6.15, "data")

  arrow(9.02, 6.12, 11.18, 6.72)
  // 这条标注宽 2.09cm，中缝只有 2.20cm：放在缝里任何高度都会被那条斜箭头穿过，
  // 放在 (9.32, 6.72) 又会压在 Collection 框的底边与右边（实测穿透 0.65/0.16cm）。
  // 斜箭头的最高点是 (11.18, 6.72)，所以缝里唯一干净的位置是箭头上方那条三角空白。
  lbl(10.10, 6.95, "material_slots[0]")

  content(
    (5.40, 5.35),
    sans("ID 结构体是所有可保存类型的第一个成员：Object、Mesh、Scene … 都以 ID id 开头"),
    anchor: "west",
  )
  content(
    (5.40, 5.10),
    sans("前两字节即类型码 ID_Type；GS(id->name) 取回它；ID_IS_LINKED(id) ⇔ id->lib != NULL"),
    anchor: "west",
  )
  content(
    (5.40, 4.85),
    sans("引用计数放在 ID.us（ID_REAL_USERS / ID_FAKE_USERS / ID_REFCOUNTING_USERS 宏）"),
    anchor: "west",
  )
  content(
    (5.40, 4.60),
    sans("库链接与 override 是两个额外指针：ID.lib 与 ID.override_library"),
    anchor: "west",
  )

  /* ============ ② 库链接（Library）与覆盖（override） ============ */
  rect((0, 0.25), (15.6, 3.75), radius: 3pt, fill: c-tip.lighten(97%), stroke: none)
  content(
    (0.15, 3.58),
    ptl("② 库链接（Library）与覆盖（override）：同名数据块的两份实体", c-tip),
    anchor: "west",
  )

  nd(0.35, 2.60, 4.55, 3.05, c-tip, "Library \"lib.blend\"")
  nd(6.30, 2.60, 10.50, 3.05, c-tip, "Object \"Cube\" @ lib.blend", dashed: true)
  nd(0.35, 1.25, 4.55, 1.70, c-tip, "Object \"Cube\"（本文件）")
  nd(6.30, 1.25, 10.50, 1.70, c-warn, "IDOverrideLibrary")

  arrow(6.28, 2.825, 4.57, 2.825)
  lbl(5.05, 2.63, "ID.lib")

  arrow(4.57, 1.475, 6.28, 1.475)
  lbl(4.62, 1.85, "override_library")

  arrow(10.20, 1.72, 10.20, 2.58)
  lbl(9.05, 2.10, "reference")

  content((11.20, 2.98), sans("链接来的 ID：ID.lib != NULL，"), anchor: "west")
  content((11.20, 2.74), sans("只读，改动前要先 make local"), anchor: "west")
  content((11.20, 1.63), sans("本文件的 ID 与库中原件一一对应，"), anchor: "west")
  content((11.20, 1.39), sans("逐属性记录“被改过”的差异"), anchor: "west")

  content(
    (0.35, 0.85),
    sans("override 差异表：IDOverrideLibrary.properties 是 IDOverrideLibraryProperty 链表", col: luma(32%)),
    anchor: "west",
  )
  content(
    (0.35, 0.57),
    sans("相关 API：BKE_lib_override_library_create() · _resync() · _make_local() · _delete()", col: luma(32%)),
    anchor: "west",
  )
}))
