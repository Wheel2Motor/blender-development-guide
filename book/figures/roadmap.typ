// ============================================================================
//  图 1：全书学习路线图
//  用法（在章节文件里）：
//    #import "../figures/roadmap.typ": fig-roadmap
//    #figure(fig-roadmap(), caption: [全书学习路线图])
//
//  排版注意：左栏标签宽度必须 >= 最长篇名「第 2 篇 基于源码进行修改」在 9.5pt
//  下的实际宽度（实测 3.78cm，2026-10-12 量自 PDF；旧注释写的「约 4.1cm」偏大 0.3cm）
//  + 左内边距，因此分隔线定在 x=4.7，说明文字从 x=5.0 起。
//  改动字号或篇名后必须重新渲染确认不重叠。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-primary, html-figure

#let fig-roadmap() = html-figure("fig-roadmap", () => canvas(length: 1cm, {
  import draw: *

  // (y, 篇号, 篇名, 章节说明, 颜色)
  let rows = (
    (5.0, "第 0 篇", "基础与准备", [第 0–2 章 架构 · 源码导览 · 三平台构建], c-part),
    (2.7, "第 1 篇", "Python 插件开发", [第 3–7 章 bpy · addon · UI · 数据与性能 · 完整项目], c-tip),
    (0.4, "第 2 篇", "基于源码进行修改", [第 8–17 章 DNA/RNA · WM · 依赖图 · 渲染 · 调试 · 贡献], c-warn),
  )

  for (y, num, title, desc, col) in rows {
    // 整行底板
    rect((0, y), (15, y + 1.7), radius: 3pt, fill: col.lighten(96%), stroke: 0.7pt + col)
    // 左栏底纹（用一条竖线把篇名与说明分开，避免两栏文字互相压字）
    line((4.7, y + 0.12), (4.7, y + 1.58), stroke: 0.5pt + col.lighten(35%))

    content(
      (0.4, y + 0.85),
      text(font: font-zh, size: 9.5pt, weight: 700, fill: col.darken(15%))[#num #title],
      anchor: "west",
    )
    content(
      (5.0, y + 0.85),
      text(font: font-zh, size: 8.5pt, fill: luma(22%))[#desc],
      anchor: "west",
    )
  }

  // 篇与篇之间的推进箭头
  line((1.5, 5.0), (1.5, 4.4), mark: (end: ">"), stroke: 1pt + luma(42%))
  line((1.5, 2.7), (1.5, 2.1), mark: (end: ">"), stroke: 1pt + luma(42%))
}))
