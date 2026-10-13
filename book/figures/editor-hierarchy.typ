// ============================================================================
//  图：SpaceType / ScrArea / ARegion 层级图（第 12 章必备图表）
//  用法（在章节文件里）：
//    #import "../figures/editor-hierarchy.typ": fig-editor-hierarchy
//    #figure(fig-editor-hierarchy(), caption: [...])
//
//  事实来源（均已按本书采用的 Blender 源码版本核对）：
//   - source/blender/makesdna/DNA_screen_types.h:95    struct bScreen（areabase）
//   - source/blender/makesdna/DNA_screen_types.h:610   struct ScrArea（type / spacedata / regionbase）
//   - source/blender/makesdna/DNA_screen_types.h:809   struct ARegion（regiontype / runtime->type）
//   - source/blender/makesdna/DNA_screen_types.h:680   enum eRegion_Type（RGN_TYPE_*）
//   - source/blender/blenkernel/BKE_screen.hh:100      struct SpaceType（regiontypes）
//   - source/blender/blenkernel/BKE_screen.hh:155/156  SpaceType.space_subtype_get / _set
//   - source/blender/blenkernel/BKE_screen.hh:249      struct ARegionType（paneltypes / headertypes）
//   - source/blender/blenkernel/BKE_screen.hh:349      struct PanelType
//   - source/blender/blenkernel/BKE_screen.h:619       struct HeaderType
//   - source/blender/makesdna/DNA_space_types.h:95     struct SpaceLink
//
//  排版注意：中文必须显式 font: font-zh + weight。
//  **canvas 的 length 是坐标单位，不是文字缩放**：本图 length: 0.85cm 只决定
//  "1 单位画多长"，文字仍按 pt 绝对大小排版（实测 PDF 里字号就是写死的 pt 值）。
//  也就是说"放大画布单位"并不会让字变大——要字大只能改 pt。
//  实测（2026-10-12，量自最终 PDF）：本图正文最小字号曾低到 4.86pt，
//  现已抬到 5.4pt（区域卡片说明）与 5.5pt（类型框字段表），仍是全图最小两档。
//  宽度实测：旧版整幅墨迹 16.085cm（右下那句长标注伸出外框 3.46cm、距版心右界仅 0.15cm），
//  现在改成外框加宽 + 类型框加宽 4.05 单位 + 右句缩短，整幅宽度降下来（见文件末尾注释）。
//  改字号或文字长度后必须重新渲染并量"文字框 vs 框边界"，不要只看代码坐标。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-primary

#let fig-editor-hierarchy() = canvas(length: 0.85cm, {
  import draw: *

  let ink = luma(20%)
  let faint = luma(45%)

  // -------------------------------------------------------------------------
  // 0 级：bScreen
  // -------------------------------------------------------------------------
  rect((0, 0.55), (15.80, 9.30), radius: 4pt, fill: luma(98.4%), stroke: 0.8pt + luma(70%))

  content(
    (0.30, 9.02),
    text(font: font-zh, size: 7.56pt, weight: 700, fill: luma(25%))[bScreen （一个屏幕，ID_SCR）],
    anchor: "west",
  )
  content(
    (15.50, 9.02),
    text(font: font-mono, size: 5.94pt, fill: faint)[areabase: ListBaseT<ScrArea>],
    anchor: "east",
  )

  // -------------------------------------------------------------------------
  // 1 级：三个 ScrArea
  // -------------------------------------------------------------------------
  let areas = (
    (name: "Area A", space: "SpaceView3D", base: "SPACE_VIEW3D", col: c-part,
     subs: (
       (id: "RGN_TYPE_HEADER", note: "高 = HEADERY"),
       (id: "RGN_TYPE_WINDOW", note: "主区域"),
       (id: "RGN_TYPE_UI", note: "宽 = UI_SIDEBAR_PANEL_WIDTH"),
     )),
    (name: "Area B", space: "SpaceSpreadsheet", base: "SPACE_SPREADSHEET", col: c-tip,
     subs: (
       (id: "RGN_TYPE_HEADER", note: "高 = HEADERY"),
       (id: "RGN_TYPE_TOOLS", note: "宽 = 150 + V2D_SCROLL_WIDTH"),
       (id: "RGN_TYPE_WINDOW", note: "主区域"),
       (id: "RGN_TYPE_FOOTER", note: "高 = HEADERY"),
     )),
    (name: "Area C", space: "SpaceOutliner", base: "SPACE_OUTLINER", col: c-warn,
     subs: (
       (id: "RGN_TYPE_HEADER", note: "高 = HEADERY"),
       (id: "RGN_TYPE_WINDOW", note: "主区域"),
     )),
  )

  // 三张 area 卡加宽到 4.90 单位（旧版 4.16）：卡片里的 5.4pt 说明行最宽
  // 3.05cm，内宽 4.58 单位 = 3.89cm，留 0.8cm 余量。
  let xs = (0.32, 5.52, 10.72)
  let w = 4.90
  let xin = 0.16

  for (i, a) in areas.enumerate() {
    let x = xs.at(i)
    let xr = x + w

    // Area 底板
    rect((x, 0.90), (xr, 8.70), radius: 3pt, fill: white, stroke: 1.0pt + a.col)

    // 标题行
    content(
      (x + xin, 8.36),
      text(font: font-zh, size: 6.84pt, weight: 700, fill: a.col.darken(12%))[#a.name],
      anchor: "west",
    )
    content(
      (xr - xin, 8.36),
      text(font: font-mono, size: 5.76pt, fill: ink)[#a.space],
      anchor: "east",
    )
    line((x + xin, 8.16), (xr - xin, 8.16), stroke: 0.4pt + a.col.lighten(45%))

    // regionbase 说明
    content(
      (x + xin, 7.88),
      text(font: font-mono, size: 5.58pt, fill: faint)[regionbase],
      anchor: "west",
    )

    // region 卡片：自上而下堆叠
    let y = 7.36
    let h = 1.10
    for sub in a.subs {
      rect(
        (x + xin, y - h),
        (xr - xin, y),
        radius: 2pt,
        fill: a.col.lighten(94%),
        stroke: 0.5pt + a.col.lighten(20%),
      )
      content(
        (x + xin + 0.12, y - 0.28),
        text(font: font-mono, size: 5.94pt, weight: 700, fill: a.col.darken(28%))[#sub.id],
        anchor: "west",
      )
      content(
        (x + xin + 0.12, y - 0.58),
        text(font: font-mono, size: 5.4pt, fill: luma(48%))[#sub.note],
        anchor: "west",
      )
      content(
        (x + xin + 0.12, y - 0.94),
        text(font: font-mono, size: 5.4pt, fill: luma(58%))[runtime->type · paneltypes],
        anchor: "west",
      )
      y = y - h - 0.08
    }

    // spacetype 字段
    content(
      (x + xin, 1.16),
      text(font: font-mono, size: 5.67pt, fill: ink)[spacetype = #a.base],
      anchor: "west",
    )
  }

  // -------------------------------------------------------------------------
  // 2 级：类型层（四张回调表）
  // -------------------------------------------------------------------------
  let types = (
    (key: "SpaceType", sub2: "每个编辑器一个", col: c-part, lines: (
      "name / spaceid / iconid",
      "create / free / init / exit",
      "operatortypes / keymap",
      "gizmos / dropboxes",
      "space_subtype_get / _set",
      "regiontypes（区域类型表）",
    )),
    (key: "ARegionType", sub2: "每个区域一个", col: c-tip, lines: (
      "regionid（RGN_TYPE_*）",
      "init / exit / poll / draw",
      "draw_overlay / layout",
      "listener / cursor / free",
      "prefsizex / prefsizey",
      "paneltypes / headertypes",
    )),
    (key: "PanelType", sub2: "挂在 ARegionType 上", col: c-warn, lines: (
      "idname / label / category",
      "poll / draw",
      "draw_header",
      "draw_header_preset",
      "parent / children / order",
      "PANEL_TYPE_NO_HEADER 等",
    )),
    (key: "HeaderType", sub2: "挂在 ARegionType 上", col: c-primary, lines: (
      "idname",
      "space_type / region_type",
      "poll",
      "draw",
      "（每个 header 区域一个）",
      "通常画菜单栏与模式切换",
    )),
  )

  // 类型框加宽到 4.05 单位（旧版 3.44）：字段表字号从 5.13pt 抬到 5.5pt 后
  // 最长行 "create / free / init / exit" 实测 3.143cm，内宽 4.05 单位 = 3.44cm
  // 减去左侧 0.18 单位内边距后仍有 3.24cm，能放下。
  let tw = 4.05
  let txs = (0.32, 4.57, 8.82, 13.07)

  for (i, t) in types.enumerate() {
    let x = txs.at(i)
    let xr = x + tw
    let cx = (x + xr) / 2

    rect((x, -3.52), (xr, -0.16), radius: 3pt, fill: t.col.lighten(95%), stroke: 0.9pt + t.col)

    content((cx, -0.56), text(font: font-mono, size: 7.38pt, weight: 700, fill: t.col.darken(18%))[#t.key])
    content((cx, -0.94), text(font: font-zh, size: 5.58pt, fill: faint)[#t.sub2])
    line((x + 0.14, -1.14), (xr - 0.14, -1.14), stroke: 0.4pt + t.col.lighten(45%))

    let y = -1.42
    for ln in t.lines {
      content((x + 0.18, y), text(font: font-mono, size: 5.5pt, fill: ink)[#ln], anchor: "west")
      y = y - 0.35
    }
  }

  // -------------------------------------------------------------------------
  // 运行时 -> 类型：四条虚线
  // 只画到 y = 0.44：再往上就会从两条底部标注（y = 0.62）身上穿过去，
  // 旧版箭头一直画到 0.84，实测正从「SpaceType」「ARegionType」两个词中间穿过。
  // -------------------------------------------------------------------------
  for (i, t) in types.enumerate() {
    let cx = txs.at(i) + tw / 2
    line(
      (cx, 0.44),
      (cx, -0.10),
      stroke: (paint: luma(58%), thickness: 0.55pt, dash: "dashed"),
      mark: (end: ">", scale: 0.42),
    )
  }

  // 两条标注：都改成 west 对齐、起于外框内；右句缩短，不再伸到版心右界附近。
  content(
    (0.32, 0.62),
    text(font: font-zh, size: 5.4pt, fill: faint)[每个 Area 的 type 字段指向 SpaceType ↓],
    anchor: "west",
  )
  content(
    (9.60, 0.62),
    text(font: font-zh, size: 5.4pt, fill: faint)[regiontypes 串起 ARegionType → PanelType / HeaderType],
    anchor: "west",
  )
})
