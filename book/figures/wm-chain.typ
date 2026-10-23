// ============================================================================
//  图：事件 → 操作符 → 执行 → 通知 → 撤销 链路
//  用法（在章节文件里）：
//    #import "../figures/wm-chain.typ": fig-wm-chain
//    #figure(fig-wm-chain(), caption: [事件到撤销的完整链路])
//
//  事实来源均按 blender-baseline.json 中的基准核对：
//   - source/blender/windowmanager/WM_types.hh:795        struct wmEvent
//   - source/blender/windowmanager/WM_types.hh:1082       struct wmOperatorType
//   - source/blender/windowmanager/WM_types.hh:1106/1122/1138/1146  exec/invoke/modal/poll
//   - source/blender/makesdna/DNA_windowmanager_types.h:486  struct wmOperator
//   - source/blender/makesdna/DNA_windowmanager_types.h:418  struct wmKeyMap
//   - source/blender/makesdna/DNA_windowmanager_types.h:344  struct wmKeyMapItem
//   - source/blender/windowmanager/WM_types.hh:184        OPTYPE_REGISTER = (1 << 0)
//   - source/blender/windowmanager/WM_types.hh:186        OPTYPE_UNDO = (1 << 1)
//   - source/blender/windowmanager/intern/wm_operator_type.cc:78   WM_operatortype_find
//   - source/blender/windowmanager/intern/wm_event_system.cc:2690  ot->modal(C, op, event)
//   - source/blender/windowmanager/intern/wm_event_system.cc:1307  ED_undo_push_op
//   - source/blender/windowmanager/intern/wm_event_system.cc:781   ED_screen_do_listen
//   - source/blender/windowmanager/intern/wm_event_system.cc:396   WM_event_add_notifier
//   - source/blender/editors/space_view3d/space_view3d.cc:1605     st->listener = ...
//
//  排版注意：中文字符一律显式指定 font: "Noto Sans SC" 且带 weight，否则可变字体
//  默认实例是 Thin，会渲染成细体。
//  【实测 2026-10-12，量自最终 PDF】框宽 7.22cm，框内文字左起 0.60、右留 0.10，
//  可用 6.52cm；最长的一行 ids 是 "ED_screen_do_listen :781  ·  ED_undo_push_op :1307"
//  = 6.35cm（旧版框宽 6.28cm 装不下，实测右出框 0.67cm，所以把 bw 从 6.28 加宽到 7.22）。
//  正文行 7.2pt：最长的 "listener 标脏重绘；含 OPTYPE_UNDO 才压栈" = 5.15cm，仍有 1.37cm 余量。
//  改动文案后必须重新渲染整页、放大目视确认不越框不重叠（本图**没有**也不要有
//  单独的 _preview-*.typ：图文件只导出函数，别的文件不存在）。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-primary, c-source, c-pitfall, html-figure

#let fig-wm-chain() = html-figure("fig-wm-chain", () => canvas(length: 1cm, {
  import draw: *

  let vstep = 1.74        // 步进（含行距）
  let bh = 1.50           // 框高
  let bw = 7.22           // 框宽（实测：最长 ids 行 6.35cm + 左 0.60 + 右 0.10）
  let cx0 = 0.00          // 左列左边界
  let col2 = 8.08         // 右列左边界（= bw + 0.86 的中缝）
  let y0 = 7.40           // 第一行顶部 y
  let ybot = y0 - 4 * vstep     // = 0.44

  let step(i, y, x, title, ids, body, col) = {
    rect(
      (x, y - bh), (x + bw, y),
      radius: 2.4pt,
      fill: col.lighten(97%),
      stroke: 0.8pt + col.lighten(18%),
    )
    circle((x + 0.30, y - 0.30), radius: 0.20, fill: white, stroke: 0.7pt + col)
    content(
      (x + 0.30, y - 0.305),
      text(font: font-mono, size: 7.4pt, weight: 700, fill: col.darken(10%))[#i],
    )
    content(
      (x + 0.60, y - 0.30),
      text(font: font-zh, size: 8.2pt, weight: 700, fill: col.darken(22%))[#title],
      anchor: "west",
    )
    content(
      (x + 0.60, y - 0.72),
      text(font: font-mono, size: 6.0pt, fill: c-source)[#ids],
      anchor: "west",
    )
    content(
      (x + 0.60, y - 1.19),
      text(font: font-zh, size: 7.2pt, weight: 400, fill: luma(28%))[#body],
      anchor: "west",
    )
  }

  let arrow(x, y_from, y_to) = line(
    (x, y_from), (x, y_to),
    mark: (end: ">", scale: 0.5),
    stroke: 1pt + c-part.lighten(12%),
  )

  // ---------------- 左列：事件分发 ----------------
  step("1", y0, cx0, "用户输入成为事件", "wmEvent  ·  WM_types.hh:795",
    [type / val / xy / modifier / prev_type], c-warn)
  step("2", y0 - vstep, cx0, "匹配 keymap", "wmKeyMap :418  ·  wmKeyMapItem :344  (DNA)",
    [spaceid + regionid + 修饰键 + type / val], c-primary)
  step("3", y0 - 2 * vstep, cx0, "按 idname 解析出类型", "WM_operatortype_find()",
    [查全局注册表；查不到则链条中断], c-tip)
  step("4", y0 - 3 * vstep, cx0, "poll 判定能否执行", "bool (*poll)(bContext *C)  ·  :1146",
    [只回答"当前上下文是否允许执行"], c-warn)
  arrow(cx0 + 0.30, y0 - bh - 0.04, y0 - vstep + 0.04)
  arrow(cx0 + 0.30, y0 - vstep - bh - 0.04, y0 - 2 * vstep + 0.04)
  arrow(cx0 + 0.30, y0 - 2 * vstep - bh - 0.04, y0 - 3 * vstep + 0.04)

  // poll 的 false 分支：短箭头向下 + 标注放在中缝空白处
  line((cx0 + 1.35, y0 - 3 * vstep - bh - 0.04), (cx0 + 1.35, y0 - 3 * vstep - bh - 0.52),
    mark: (end: ">", scale: 0.40), stroke: 0.7pt + c-pitfall)
  content(
    (cx0 + 1.45, y0 - 3 * vstep - bh - 0.30),
    text(font: font-zh, size: 6.3pt, weight: 400, fill: c-pitfall.darken(6%))[false ⇒ 跳过此操作符],
    anchor: "west",
  )

  // ---------------- 蛇形连接：左列底 → 右列顶 ----------------
  let yc = ybot - 0.36
  line((cx0 + 0.30, ybot - bh), (cx0 + 0.30, yc), stroke: 1pt + c-part.lighten(12%))
  line((cx0 + 0.30, yc), (col2 + 0.30, yc), stroke: 1pt + c-part.lighten(12%))
  line((col2 + 0.30, yc), (col2 + 0.30, y0), mark: (end: ">", scale: 0.5),
    stroke: 1pt + c-part.lighten(12%))

  // ---------------- 右列：执行与回灌 ----------------
  step("5", y0, col2, "执行：三选一", "invoke :1122  ·  exec :1106  ·  modal :1138",
    [invoke 要交互；exec 无交互；modal 转 6], c-tip)
  step("6", y0 - vstep, col2, "模态循环持续吃事件", "wm_event_system.cc:2690",
    [每次重入 modal；返回 FINISHED 才收尾], c-part)
  step("7", y0 - 2 * vstep, col2, "改数据并广播 notifier", "WM_event_add_notifier()  ·  :396",
    [NC_ 类别 + ND_ 子类 + reference], c-warn)
  step("8", y0 - 3 * vstep, col2, "重绘与撤销入栈", "ED_screen_do_listen :781  ·  ED_undo_push_op :1307",
    [listener 标脏重绘；含 OPTYPE_UNDO 才压栈], c-tip)
  arrow(col2 + 0.30, y0 - bh - 0.04, y0 - vstep + 0.04)
  arrow(col2 + 0.30, y0 - vstep - bh - 0.04, y0 - 2 * vstep + 0.04)
  arrow(col2 + 0.30, y0 - 2 * vstep - bh - 0.04, y0 - 3 * vstep + 0.04)

  // ---------------- 撤销：从步骤 8 反向回灌 ----------------
  let yundo = ybot - 0.36
  content(
    (cx0 + 0.04, yundo - 0.06),
    text(font: font-zh, size: 7.0pt, weight: 700, fill: c-primary.darken(8%))[撤销 / 重做],
    anchor: "west",
  )
  content(
    (cx0 + 0.04, yundo - 0.40),
    text(font: font-mono, size: 6.1pt, fill: c-source)[
      ED_undo_pop  →  DEG 重新求值  →  WM_event_add_notifier(NC_WM, ND_UNDO)
    ],
    anchor: "west",
  )
  line(
    (col2 + 0.30, y0 - 3 * vstep - bh - 0.04),
    (col2 + 0.30, yundo - 0.74),
    (1.34, yundo - 0.74),
    mark: (end: ">", scale: 0.5),
    stroke: (paint: c-primary, thickness: 0.9pt, dash: "dashed"),
  )

  // ---------------- 图例（两行，避免与 OPTYPE 说明撞行） ----------------
  let yleg = yundo - 0.98
  line((cx0, yleg), (cx0 + 0.60, yleg), mark: (end: ">", scale: 0.45),
    stroke: 1pt + c-part.lighten(12%))
  content((cx0 + 0.70, yleg),
    text(font: font-zh, size: 6.8pt, weight: 400, fill: luma(32%))[主链路],
    anchor: "west")
  line((2.10, yleg), (2.70, yleg), mark: (end: ">", scale: 0.45),
    stroke: (paint: c-primary, thickness: 0.9pt, dash: "dashed"))
  content((2.80, yleg),
    text(font: font-zh, size: 6.8pt, weight: 400, fill: luma(32%))[撤销回灌],
    anchor: "west")

  content((cx0, yleg - 0.48),
    text(font: font-mono, size: 6.2pt, fill: luma(42%))[
      OPTYPE_REGISTER = (1 << 0)  ·  OPTYPE_UNDO = (1 << 1)  ·  WM_types.hh:184,186
    ],
    anchor: "west")
}))
