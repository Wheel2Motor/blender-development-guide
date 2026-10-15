// ============================================================================
//  图：Python/C++ 分工与「何时下沉 C++」决策图
//  用于第 6 章 §6.4 / §6.6。
//
//  用法（在章节文件里）：
//    #import "../figures/when-to-drop.typ": fig-when-to-drop
//    #figure(fig-when-to-drop(), caption: [「何时下沉 C++」决策图]) <fig-when-to-drop>
//
//  排版注意：
//    - cetz 的 content 不继承 main.typ 的 #set text，因此每个 text() 都必须
//      显式给出 font/weight/size/fill；中文字体用 font-zh + weight: 400。
//    - 实测（2026-10-12，量自最终 PDF）：主链盒宽 8.20cm、右侧出口盒宽 5.50cm、
//      水平间隔 1.35cm。间隔必须 >= 「仍然不够」(8pt 粗体) 的实测宽 1.13cm + 左右各 0.1cm，
//      旧版 0.80cm 时这条标注的左右两头正好压在两侧框的竖边框上（实测穿透 0.28cm）。
//      改动任何文案或字号后
//      必须重新 `typst compile --root . --format png --ppi 150` 目视确认。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, c-part, c-note, c-tip, c-warn, c-pitfall, html-figure

#let fig-when-to-drop() = html-figure("fig-when-to-drop", () => canvas(length: 1cm, {
  import draw: *

  // 主链的四个判定框：y 坐标自上而下递减。
  let y-a = 9.60
  let y-b = 7.55
  let y-c = 5.50
  let y-d = 3.45
  let h = 1.40
  let x0 = 0.30
  let x1 = 8.50

  // 右侧「改 C++ 源码」的出口。
  let rx0 = 9.85
  let rx1 = 15.35
  let ry-top = 9.60
  let ry-bot = 3.45

  // --------------------------------------------------------------------------
  // 主链
  // --------------------------------------------------------------------------

  // 第 1 步：有没有 Python 入口
  rect((x0, y-a), (x1, y-a + h), radius: 3pt,
       fill: c-note.lighten(94%), stroke: 0.9pt + c-note)
  content((x0 + 0.26, y-a + h - 0.28),
    text(font: font-zh, size: 8.6pt, weight: 700, fill: c-note.darken(20%))[第 1 步 有没有 Python 入口？],
    anchor: "west")
  content((x0 + 0.26, y-a + 0.30),
    text(font: font-zh, size: 7.1pt, weight: 400, fill: luma(24%))[
      能注册操作符 / 面板 / 属性 / `PropertyGroup` 的都有入口。],
    anchor: "west")

  // 第 2 步：向量化
  rect((x0, y-b), (x1, y-b + h), radius: 3pt,
       fill: c-tip.lighten(95%), stroke: 0.9pt + c-tip)
  content((x0 + 0.26, y-b + h - 0.28),
    text(font: font-zh, size: 8.6pt, weight: 700, fill: c-tip.darken(20%))[第 2 步 先向量化：`foreach_get` / `foreach_set` / numpy],
    anchor: "west")
  content((x0 + 0.26, y-b + 0.30),
    text(font: font-zh, size: 7.1pt, weight: 400, fill: luma(24%))[
      属性走 `attribute.data.foreach_*`；坐标走 `foreach_get("co", arr)`。],
    anchor: "west")

  // 第 3 步：profile
  rect((x0, y-c), (x1, y-c + h), radius: 3pt,
       fill: c-warn.lighten(94%), stroke: 0.9pt + c-warn)
  content((x0 + 0.26, y-c + h - 0.28),
    text(font: font-zh, size: 8.6pt, weight: 700, fill: c-warn.darken(20%))[第 3 步 用 `cProfile` 定位真正的热点],
    anchor: "west")
  content((x0 + 0.26, y-c + 0.30),
    text(font: font-zh, size: 7.1pt, weight: 400, fill: luma(24%))[
      只优化 `cumtime` 排第一的函数。热点在循环体里就改算法，不要猜。],
    anchor: "west")

  // 第 4 步：原生加速
  rect((x0, y-d), (x1, y-d + h), radius: 3pt,
       fill: c-pitfall.lighten(95%), stroke: 0.9pt + c-pitfall)
  content((x0 + 0.26, y-d + h - 0.28),
    text(font: font-zh, size: 8.6pt, weight: 700, fill: c-pitfall.darken(20%))[第 4 步 热点在计算本身：写 C ABI 动态库],
    anchor: "west")
  content((x0 + 0.26, y-d + 0.30),
    text(font: font-zh, size: 7.1pt, weight: 400, fill: luma(24%))[
      经 `ctypes` / `cffi` / PyO3 接入；三平台各出一份二进制。],
    anchor: "west")

  // 右侧出口：改 C++ 源码
  rect((rx0, ry-bot), (rx1, ry-top), radius: 3pt,
       fill: c-part.lighten(95%), stroke: 1.0pt + c-part)
  content((rx0 + 0.26, ry-top - 0.34),
    text(font: font-zh, size: 9.2pt, weight: 700, fill: c-part)[改 C++ 源码],
    anchor: "west")
  content((rx0 + 0.26, ry-top - 1.00),
    text(font: font-zh, size: 7.6pt, weight: 400, fill: luma(24%))[见第 2 篇（第 8–17 章）],
    anchor: "west")
  content((rx0 + 0.26, ry-top - 1.60),
    text(font: font-zh, size: 7.1pt, weight: 400, fill: luma(24%))[只有这条路能做到：],
    anchor: "west")
  // 右侧盒内的四条「只有这条路能做到」逐行独立绘制：
  // 已实测，把多行 CJK 放进同一个 content() 会让 Noto Sans SC（可变字体）
  // 在窄行宽下出现字形叠印，必须拆成多条 content()。
  let rx-text = rx0 + 0.26
  let ry-lines = (
    (ry-top - 2.05, "能新增编辑器类型、"),
    (ry-top - 2.60, "改依赖图求值策略、"),
    (ry-top - 3.15, "改渲染管线、"),
    (ry-top - 3.70, "给 DNA 结构加字段。"),
  )
  for (ly, ltext) in ry-lines {
    content((rx-text, ly),
      text(font: font-zh, size: 7.1pt, weight: 400, fill: luma(24%))[#ltext],
      anchor: "west")
  }

  // --------------------------------------------------------------------------
  // 竖直箭头（沿主链向下）
  // --------------------------------------------------------------------------
  line((3.9, y-a), (3.9, y-b + h), mark: (end: ">"), stroke: 1pt + luma(40%))
  line((3.9, y-b), (3.9, y-c + h), mark: (end: ">"), stroke: 1pt + luma(40%))
  line((3.9, y-c), (3.9, y-d + h), mark: (end: ">"), stroke: 1pt + luma(40%))

  // 「有 / 还不够快 / 是」标记
  content((4.14, (y-a + y-b + h) / 2),
    text(font: font-zh, size: 8pt, weight: 700, fill: c-tip.darken(10%))[有],
    anchor: "west")
  content((4.14, (y-b + y-c + h) / 2),
    text(font: font-zh, size: 8pt, weight: 700, fill: c-warn.darken(10%))[还不够快],
    anchor: "west")
  content((4.14, (y-c + y-d + h) / 2),
    text(font: font-zh, size: 8pt, weight: 700, fill: c-pitfall.darken(10%))[是],
    anchor: "west")

  // --------------------------------------------------------------------------
  // 横向分支：第 1 步「没有」→ 改 C++ 源码
  // --------------------------------------------------------------------------
  line((x1, y-a + h / 2), (rx0, y-a + h / 2), mark: (end: ">"), stroke: 1pt + c-part)
  content(((x1 + rx0) / 2, y-a + h / 2 + 0.18),
    text(font: font-zh, size: 8pt, weight: 700, fill: c-part)[没有],
    anchor: "south")

  // --------------------------------------------------------------------------
  // 横向分支：第 4 步「仍然不够」→ 改 C++ 源码
  // 标注居中放在加宽后的中缝里（8pt 下 1.13cm < 1.35cm），不再压两侧框线
  // --------------------------------------------------------------------------
  line((x1, y-d + h / 2), (rx0, y-d + h / 2), mark: (end: ">"), stroke: 1pt + c-part)
  content(((x1 + rx0) / 2, y-d + h / 2 + 0.18),
    text(font: font-zh, size: 8pt, weight: 700, fill: c-part)[仍然不够],
    anchor: "south")
}))
