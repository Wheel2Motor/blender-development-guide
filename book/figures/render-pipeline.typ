// ============================================================================
//  图：渲染管线（场景 → 求值 → 引擎 → 合成 → 输出）（第 15 章必备图表）
//  用法（在章节文件里）：
//    #import "../figures/render-pipeline.typ": fig-render-pipeline
//    #figure(fig-render-pipeline(), caption: [...])
//
//  事实来源（均已按本书采用的 Blender 源码版本核对）：
//   - source/blender/render/RE_pipeline.h:367   RE_RenderFrame() 声明
//   - source/blender/render/intern/pipeline.cc:1925  RE_RenderFrame() 实现
//   - source/blender/render/intern/pipeline.cc:1945  render_init_from_main()
//   - source/blender/render/intern/pipeline.cc:1956  render_init_depsgraph()
//   - source/blender/render/intern/pipeline.cc:1891  DEG_graph_new(..., DAG_EVAL_RENDER)
//   - source/blender/render/intern/pipeline.cc:1895  DEG_graph_build_for_render_pipeline()
//   - source/blender/render/intern/pipeline.cc:1958  do_render_full_pipeline()
//   - source/blender/render/intern/pipeline.cc:1480  do_render_full_pipeline() 三分支
//   - source/blender/render/intern/pipeline.cc:1493  RE_engine_render(re, true)
//   - source/blender/render/intern/pipeline.cc:1496  RE_seq_render_active()
//   - source/blender/render/intern/pipeline.cc:1507  do_render_compositor()
//   - source/blender/render/intern/pipeline.cc:1214  do_render_compositor()
//   - source/blender/render/intern/engine.cc:1003    RE_engine_render()
//   - source/blender/render/intern/engine.cc:1097    FOREACH_VIEW_LAYER_TO_RENDER_BEGIN
//   - source/blender/render/intern/engine.cc:872     engine_render_view_layer()
//   - source/blender/render/intern/engine.cc:941     engine->type->render(...)
//   - source/blender/render/intern/engine.cc:186     RE_engine_begin_result()
//   - source/blender/render/intern/engine.cc:421     RE_engine_end_result()
//   - source/blender/render/intern/engine.cc:634     RE_engine_get_current_tiles()
//   - source/blender/render/intern/compositor.cc:842 RE_compositor_execute()
//   - source/blender/render/intern/pipeline.cc:177   do_write_image_or_movie() 定义
//   - source/blender/render/intern/pipeline.cc:1985  do_write_image_or_movie() 调用
//
//  排版注意：中文必须显式 font: font-zh + weight。
//  画布总宽 15.70 cm（实测墨迹外接，量自最终 PDF），< 正文栏宽 16.4 cm，两侧各余 0.35 cm。
//  上一版这一图宽 15.445 cm —— 多出来的 0.925 cm 全部来自第 ⑤ 列的文字冲出框；
//  改法是**加宽列**并把长标识符写成全名（不再用 `…` 截断），不是缩字号。
//  ② 带的调用列表用 5.9pt（旧版 4.8pt 太小），每列 2 条；`BKE_image_path_from_imformat`
//  这类长标识符靠 `brk()` 在 `_` 后插的零宽空格折行，因此每列都能容纳全名。
//  改动任何文字后必须重新渲染确认不溢出、不重叠、不被裁切。
//  本文件**只导出函数**：不要在这里写模块级 `#set` / `#figure` —— 章节是用 `#import`
//  引入本文件的，在模块顶层放 `#set page(...)` 一旦被改成 `#include` 就会炸整本书版面。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-summary, c-pitfall, html-figure

#let fig-render-pipeline() = html-figure("fig-render-pipeline", () => canvas(length: 1cm, {
  import draw: *

  let ink = luma(18%)
  let faint = luma(46%)
  let c0 = c-part
  let c1 = c-summary
  let c2 = c-tip
  let c3 = c-warn
  let c4 = c-pitfall

  // 长标识符的折行点：在 `_` 之后插零宽空格（与 main.typ 处理长路径的做法一致）。
  // 只影响允许断行的位置，不改变字形宽度，所以短标识符加了也无害。
  let brk = s => s.replace("_", "_\u{200B}")

  // =========================================================================
  // ① 主流程：五个阶段
  // =========================================================================
  content(
    (0.10, 3.42),
    text(font: font-zh, size: 8.4pt, weight: 700, fill: c0.darken(8%))[① 一次帧渲染的五个阶段],
    anchor: "west",
  )
  content(
    (15.78, 3.42),
    text(font: font-mono, size: 6.0pt, fill: faint)[RE_RenderFrame()],
    anchor: "east",
  )

  // 列宽（实测）：①②④ 需要 2.90（④ 的 RE_compositor_execute 在 6.0pt 下 2.667cm），
  // ③ 需要 3.00（RE_engine_begin_result 2.747cm），⑤ 需要 3.20（do_write_image_or_movie 2.921cm）。
  // 间隙 0.20，五列合计 0.10 .. 15.80。
  let stages = (
    (x: 0.10, xr: 3.00, key: "① 场景 Scene", col: c0, fn: "scene->r.engine", sub: "要渲染什么"),
    (x: 3.20, xr: 6.10, key: "② 求值 Depsgraph", col: c1, fn: "DAG_EVAL_RENDER", sub: "算出结果数据"),
    (x: 6.30, xr: 9.30, key: "③ 引擎 RenderEngine", col: c2, fn: "type->render()", sub: "产出 RenderResult"),
    (x: 9.50, xr: 12.40, key: "④ 合成 Compositor", col: c3, fn: "RE_compositor_execute", sub: "节点树再加工"),
    (x: 12.60, xr: 15.80, key: "⑤ 输出 写盘 / 显示", col: c4, fn: "do_write_image_or_movie", sub: "ImBuf → 文件"),
  )

  for (i, s) in stages.enumerate() {
    rect((s.x, 1.30), (s.xr, 2.70), radius: 3pt, fill: s.col.lighten(95%), stroke: 0.9pt + s.col)
    content(
      (s.x + 0.13, 2.34),
      text(font: font-zh, size: 7.4pt, weight: 700, fill: s.col.darken(18%))[#s.key],
      anchor: "west",
    )
    content(
      (s.x + 0.13, 1.98),
      text(font: font-mono, size: 6.0pt, fill: faint)[#s.fn],
      anchor: "west",
    )
    content(
      (s.x + 0.13, 1.60),
      text(font: font-zh, size: 6.4pt, fill: ink)[#s.sub],
      anchor: "west",
    )
    if i < 4 {
      line((s.xr + 0.02, 2.00), (s.xr + 0.18, 2.00), stroke: 0.9pt + luma(45%), mark: (end: ">", scale: 0.4))
    }
  }

  // =========================================================================
  // ② 阶段内部的关键调用
  // =========================================================================
  content(
    (0.10, 0.86),
    text(font: font-zh, size: 8.4pt, weight: 700, fill: c0.darken(8%))[② 每个阶段内部发生的事],
    anchor: "west",
  )
  content(
    (15.78, 0.86),
    text(font: font-zh, size: 6.2pt, fill: faint)[行号见 source/blender/render/intern/],
    anchor: "east",
  )

  // 每个阶段 2~3 条关键调用，全部用源码里的**全名**（旧的 `render_init_from_...ain`
  // 那种"省略号插在词中间"的写法已废弃：它既不是真名，也无法在源码里搜到）。
  // ① 的三条都不折行，行距 0.40；②③④⑤ 各有一条折行，行距 0.52（0.44 时折行块与
  // 上一条的 bbox 会相碰，实测重叠 0.031cm）。
  let details = (
    (
      x: 0.10,
      xr: 3.00,
      dy: 0.40,
      col: c0,
      title: "初始化",
      lines: ("render_init_from_main", "RE_InitState", "camera / 分辨率解析"),
    ),
    (
      x: 3.20,
      xr: 6.10,
      dy: 0.52,
      col: c1,
      title: "建图 + 求值",
      lines: ("DEG_graph_new", "DEG_graph_build_for_render_pipeline"),
    ),
    (
      x: 6.30,
      xr: 9.30,
      dy: 0.52,
      col: c2,
      title: "逐视图层渲染",
      lines: ("RE_engine_begin_result", "RE_engine_end_result"),
    ),
    (
      x: 9.50,
      xr: 12.40,
      dy: 0.52,
      col: c3,
      title: "GPU 节点求值",
      lines: ("NodeGroupOutputTypes", "RE_compositor_execute"),
    ),
    (
      x: 12.60,
      xr: 15.80,
      dy: 0.52,
      col: c4,
      title: "写盘 / 回调",
      lines: ("do_write_image_or_movie", "BKE_image_path_from_imformat"),
    ),
  )

  for (d) in details {
    rect((d.x, -1.04), (d.xr, 0.62), radius: 2.5pt, fill: white, stroke: 0.7pt + d.col.lighten(25%))
    content(
      (d.x + 0.12, 0.38),
      text(font: font-zh, size: 6.6pt, weight: 700, fill: d.col.darken(18%))[#d.title],
      anchor: "west",
    )
    line((d.x + 0.10, 0.22), (d.xr - 0.10, 0.22), stroke: 0.4pt + d.col.lighten(45%))
    for (j, ln) in d.lines.enumerate() {
      if ln != "" {
        // 固定宽度的 block 才能让 brk() 插的零宽空格真的折行（cetz 的 content()
        // 默认按内容自然宽度测量，不给宽度就不会折行）。
        content(
          (d.x + 0.12, -0.10 - j * d.dy),
          block(width: (d.xr - d.x - 0.22) * 1cm)[
            #text(font: font-mono, size: 5.9pt, fill: ink)[#brk(ln)]
          ],
          anchor: "west",
        )
      }
    }
    // 从①阶段框指向②详情框的短箭头
    line((d.x + 0.5 * (d.xr - d.x), 1.22), (d.x + 0.5 * (d.xr - d.x), 0.70), stroke: 0.6pt + d.col.lighten(20%), mark: (end: ">", scale: 0.4))
  }

  // =========================================================================
  // ③ 引擎分支与分块渲染
  // =========================================================================
  rect((0.10, -4.06), (15.80, -1.44), radius: 4pt, fill: luma(98.6%), stroke: 0.7pt + luma(72%))
  content(
    (0.32, -1.72),
    text(font: font-zh, size: 8.4pt, weight: 700, fill: c3.darken(6%))[③ 引擎分支：谁是「渲染」的真正执行者],
    anchor: "west",
  )

  let branches = (
    (
      x: 0.32,
      xr: 5.28,
      col: c2,
      key: "type->render 非空 → 外部引擎",
      l1: "Cycles 走 Python 子类 RenderEngine",
      l2: "bl_idname = \"CYCLES\"（addon 注册）",
      l3: "RE_engine_render() 返回 true，独占全部流程",
    ),
    (
      x: 5.48,
      xr: 10.44,
      col: c3,
      key: "render 为空 + 有序列 → 序列器",
      l1: "RE_seq_render_active() 判真",
      l2: "do_render_sequencer() 直接出图",
      l3: "跳过引擎，也跳过合成器",
    ),
    (
      x: 10.64,
      xr: 15.60,
      col: c1,
      key: "其余情况 → 合成器管线",
      l1: "do_render_compositor()",
      l2: "需要时先 do_render_engine() 补渲场景",
      l3: "再执行节点树：RE_compositor_execute()",
    ),
  )

  for (b) in branches {
    rect((b.x, -3.84), (b.xr, -1.98), radius: 2.5pt, fill: b.col.lighten(96%), stroke: 0.7pt + b.col.lighten(20%))
    content(
      (b.x + 0.14, -2.22),
      text(font: font-zh, size: 6.8pt, weight: 700, fill: b.col.darken(20%))[#b.key],
      anchor: "west",
    )
    line((b.x + 0.12, -2.40), (b.xr - 0.12, -2.40), stroke: 0.4pt + b.col.lighten(45%))
    for (j, ln) in (b.l1, b.l2, b.l3).enumerate() {
      content(
        (b.x + 0.14, -2.68 - j * 0.34),
        text(font: font-zh, size: 5.9pt, fill: ink)[#ln],
        anchor: "west",
      )
    }
  }

  // =========================================================================
  // ④ 分块与显示
  // =========================================================================
  rect((0.10, -6.86), (15.80, -4.30), radius: 4pt, fill: luma(98.6%), stroke: 0.7pt + luma(72%))
  content(
    (0.32, -4.60),
    text(font: font-zh, size: 8.4pt, weight: 700, fill: c4.darken(4%))[④ 分块渲染与进度显示],
    anchor: "west",
  )

  let tiles = (
    (x: 0.32, xr: 5.28, col: c4, t: "引擎自己决定分块", l1: "RE_engine_begin_result(x, y, w, h)", l2: "RE_engine_end_result(...)"),
    (x: 5.48, xr: 10.44, col: c0, t: "分块即结果裁剪框", l1: "RenderResult.tilerect（rcti）", l2: "render_result_merge()"),
    (x: 10.64, xr: 15.60, col: c2, t: "高亮与取消", l1: "RE_engine_tile_highlight_set()", l2: "RE_engine_test_break()"),
  )

  for (t) in tiles {
    content(
      (t.x, -4.88),
      text(font: font-zh, size: 6.8pt, weight: 700, fill: t.col.darken(18%))[#t.t],
      anchor: "west",
    )
    line((t.x, -5.06), (t.xr, -5.06), stroke: 0.4pt + t.col.lighten(45%))
    for (j, ln) in (t.l1, t.l2).enumerate() {
      content(
        (t.x, -5.36 - j * 0.34),
        text(font: font-mono, size: 5.8pt, fill: ink)[#ln],
        anchor: "west",
      )
    }
  }

  content(
    (0.32, -6.30),
    text(font: font-zh, size: 5.9pt, fill: faint)[版本 5.2 起「分块」由引擎自行决定：内置引擎整帧出图，外部引擎可自行切块并回报高亮。],
    anchor: "west",
  )
  content(
    (0.32, -6.62),
    text(font: font-zh, size: 5.9pt, fill: faint)[视图层（ViewLayer）是「一次渲染里的独立图层」，引擎在 RE_engine_render() 里逐层调用 render 回调。],
    anchor: "west",
  )
}))
