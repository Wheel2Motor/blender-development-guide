// ============================================================================
//  图 3：Python addon 生命周期
//  用法（在章节文件里）：
//    #import "../figures/addon-lifecycle.typ": fig-addon-lifecycle
//    #figure(fig-addon-lifecycle(), caption: [Python addon 生命周期]) <fig-addon-lifecycle>
//
//  排版注意（踩过的坑，改图前请先读）：
//   1. cetz 画布里的中文必须显式指定 font 与 weight，否则 Noto Sans SC
//      会退化成 Thin 实例。
//   2. cetz 的 content() 会按【锚点位置到画布边界】给出可用宽度。
//      因此右栏说明文字不能依赖外层 box(width:) —— 内容一旦超过这个
//      可用宽度就会被裁掉且不会换行。本图的两栏文字都用短标签，
//      详细说明放在章节正文里，以规避这个陷阱。
//   3. 【实测】cetz canvas 按 1:1 自然尺寸渲染，**不会**按栏宽缩放：
//      标称高 10.5cm，200dpi 渲染实测 829px = 10.53cm。所以图上字号就是
//      印刷字号，整幅宽度要自己控制在正文栏宽（16.4cm）之内。
//      画布边界由**实际绘制范围**决定：画到 x<0 的元素会把整幅图右推
//      （旧版"再启用"标签以 x=0.0 / anchor:"east" 左伸 0.56cm，
//      整幅因此右移 0.28cm）。所以越界元素不会被裁掉，而是悄悄挪动整图。
//   4. 【实测，Noto Sans SC 6.5pt】最长阶段名 "⑦ 模块仍在内存" = 1.657cm
//      （旧注释写的 2.87cm 是错的，"⑤ 可用状态" 实测只有 1.199cm）；
//      最长触发者标签 "enable() 不删" = 1.697cm；右栏最长说明
//      "扫描 addons_core 与 addons" = 3.033cm。改文字或改字号必须重新
//      用 measure() 实测，不要照抄这里的数字。
//   5. 不要用 #src()：cetz 的 canvas 子作用域里拿不到 common.typ 的函数。
//   6. 【cetz API 坑】draw.bezier 的签名是 bezier(start, end, ..控制点)：
//      第 1、2 个位置参数是【起点与终点】，控制点跟在后面。旧版按
//      (起点, 控制点, 控制点, 终点) 传参，于是箭头落在第二个点
//      (y=3.1，⑥ 那一行) 上，并画出一条只有 0.25cm 宽的细梭。
//   7. 【cetz API 坑】dash 不是 cetz 的样式键：`dash: "dashed"` 会被静默
//      忽略（画成实线）。虚线要写进 stroke 字典：
//      `stroke: (paint: c-primary, thickness: 0.7pt, dash: "dashed")`。
//
//  事实来源（均已核对，出处同时写在章节正文与图注里）：
//   - scripts/modules/addon_utils.py:84     paths()：addons_core / addons 两类目录
//   - scripts/modules/addon_utils.py:111    _paths_with_extension_repos()：扩展仓库目录
//   - scripts/modules/addon_utils.py:126    _fake_module()：只读到 bl_info 那一段
//   - scripts/modules/addon_utils.py:149    while not line.startswith("bl_info")
//   - scripts/modules/addon_utils.py:197    mod.bl_info = ast.literal_eval(body.value)
//   - scripts/modules/addon_utils.py:208    缺 bl_info 的警告
//   - scripts/modules/addon_utils.py:212    modules_refresh()：按 __time__ 判断元数据缓存
//   - scripts/modules/addon_utils.py:428    mtime_orig != mtime_new -> importlib.reload
//   - scripts/modules/addon_utils.py:450    with RestrictBlend()：加载期禁用 context
//   - scripts/modules/addon_utils.py:458    mod = importlib.import_module(module_name)
//   - scripts/modules/addon_utils.py:544    mod.register()
//   - scripts/modules/addon_utils.py:548    del sys.modules[module_name]（**只在注册失败时**）
//   - scripts/modules/addon_utils.py:558    mod.__addon_enabled__ = True
//   - scripts/modules/addon_utils.py:595    mod.unregister()
//   - scripts/modules/addon_utils.py:610    _addon_remove()：从 preferences.addons 移除
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-pitfall, c-primary, html-figure

#let fig-addon-lifecycle() = html-figure("fig-addon-lifecycle", () => canvas(length: 1cm, {
  import draw: *

  // 布局常量（单位：cm）。宽度由 measure() 实测后定，改字号必须重新实测。
  // 左侧留白（0 .. lx）用来放"再启用"虚线回路：旧版只留 0.7cm，回路被压成
  // 0.25cm 宽的细梭；现在给它 3.3cm，回路本身宽 1.35cm、标签 1.61cm 都放得下。
  let lx = 3.30         // 左栏左边界
  let lw = 5.60         // 左栏宽度；右边界 = 8.90
  let rx = 9.40         // 右栏左边界
  let rw = 4.00         // 右栏宽度；右边界 = 13.40（整幅 13.4cm < 正文栏宽 16.4cm）
  let row_h = 1.5
  let spine_x = 2.75    // 阶段推进连线所在的 x（距左栏 0.55cm）
  let loop_x = 1.95     // "再启用"回路竖段所在的 x（与主干连线相隔 0.80cm）
  let name_dx = 0.59    // 阶段名相对 lx 的偏移
  let who_pad = 0.12    // 触发者标签距右边界的内边距

  // 实测宽度（6.5pt 粗体）：最长阶段名 "⑦ 模块仍在内存" = 1.657cm；
  // 实测宽度（6.5pt 等宽）：最长触发者 "enable() 不删" = 1.697cm。
  // name 右端 0.59 + 1.657 = 2.247cm，who 左端 5.60 - 0.12 - 1.697 = 3.783cm
  // —— 余量 1.536cm，不重叠。
  let stages = (
    (10.2, "① 启动扫描", "startup", luma(48%)),
    (8.7, "② 读元数据", "fast-path", c-primary),
    (7.2, "③ 导入模块", "enable()", c-warn),
    (5.7, "④ register()", "enable()", c-tip),
    (4.2, "⑤ 可用状态", "user", c-tip),
    (2.7, "⑥ unregister()", "disable()", c-pitfall),
    (1.2, "⑦ 模块仍在内存", "enable() 不删", c-pitfall),
  )

  // 右栏：每条不超过 18 个汉字的短标签（另配等宽标识符）。
  // 说明细节写在章节正文，避免触发 content() 的可用宽度裁剪。
  let mono = body => text(font: font-mono, size: 0.92em, fill: luma(22%))[#body]
  let notes = (
    [扫描 addons_core 与 addons],
    [读 ] + mono("bl_info") + [，取字面量],
    [执行你的代码],
    [挂类与菜单项],
    [偏好设置里已启用],
    [反序撤销副作用],
    [模块没被卸载],
  )

  for (i, (y, name, who, col)) in stages.enumerate() {
    let y0 = y
    let y1 = y + row_h
    let yc = y + row_h / 2

    // ---- 左栏：阶段 ----
    rect((lx, y0), (lx + lw, y1), radius: 3pt, fill: col.lighten(96%), stroke: 0.7pt + col)
    content(
      (lx + name_dx, yc),
      text(font: font-zh, size: 6.5pt, weight: 700, fill: col.darken(18%))[#name],
      anchor: "west",
    )
    content(
      (lx + lw - who_pad, yc),
      text(font: font-mono, size: 6.5pt, fill: luma(42%))[#who],
      anchor: "east",
    )

    // ---- 右栏：一句话说明 ----
    rect((rx, y0), (rx + rw, y1), radius: 3pt, fill: white, stroke: 0.4pt + luma(75%))
    content(
      (rx + 0.28, yc),
      text(font: font-zh, size: 6.5pt, weight: 400, fill: luma(15%))[#notes.at(i)],
      anchor: "west",
    )
  }

  // 阶段推进连线：穿过各行左侧留白，不压文字
  for i in range(stages.len() - 1) {
    line(
      (spine_x, stages.at(i).at(0) + row_h),
      (spine_x, stages.at(i + 1).at(0)),
      mark: (end: ">", scale: 0.4),
      stroke: 0.6pt + luma(45%),
    )
  }

  // ---- "再启用"回路：⑦（模块仍在内存）→ ④ register() ----
  //
  // 语义（依据 scripts/modules/addon_utils.py 的 enable()）：
  //   enable() 先 importlib.import_module(module_name)（:458），再 mod.register()（:544）。
  //   disable() 只调用 mod.unregister()（:595），**不动 sys.modules**；只有 register()
  //   抛异常时那条路径才会 del sys.modules[module_name]（:548）。所以"再次启用"时
  //   importlib 命中模块缓存、模块代码不重新执行，真正被重跑的是 ④ register()。
  //   → 箭头终点必须在 ④（不是 ⑤，更不是 ⑥），并标出"不重新导入模块"。
  let y_out = 1.95      // 出发点：⑦ 模块仍在内存 那一行的中心
  let y_ret = 6.45      // 终点：④ register() 那一行的中心
  let cr = 0.35         // 折角半径
  let k = 0.5523 * cr   // 四分之一圆的三次贝塞尔控制点系数
  let ret-stroke = (paint: c-primary.lighten(10%), thickness: 0.7pt, dash: "dashed")

  // 回路在主线上是"跨过"而不是"接上"：先给主干连线开两个小口，
  // 免得交点看起来像分叉。
  for yy in (y_out, y_ret) {
    line((spine_x, yy - 0.14), (spine_x, yy + 0.14), stroke: 2.4pt + white)
  }

  // 横段（从 ⑦ 左缘向左）→ 左下圆角 → 竖段（向上）→ 左上圆角 → 横段（向右进 ④）
  line((lx, y_out), (loop_x + cr, y_out), stroke: ret-stroke)
  bezier(
    (loop_x + cr, y_out), (loop_x, y_out + cr),
    (loop_x + cr - k, y_out), (loop_x, y_out + cr - k),
    stroke: ret-stroke,
  )
  line((loop_x, y_out + cr), (loop_x, y_ret - cr), stroke: ret-stroke)
  bezier(
    (loop_x, y_ret - cr), (loop_x + cr, y_ret),
    (loop_x, y_ret - cr + k), (loop_x + cr - k, y_ret),
    stroke: ret-stroke,
  )
  line(
    (loop_x + cr, y_ret), (lx, y_ret),
    stroke: ret-stroke,
    mark: (end: ">", scale: 0.6),
  )

  // 标签：横排两行，放在竖段左侧的留白里（x 0.10 .. 1.70，不压回路也不出画布）。
  // 第 1 行是动作，第 2 行是这一步的关键事实；sys.modules / 旧模块对象那句
  // 完整解释在章末图注与 4.1.3 的表里，图内不重复。
  content(
    (0.90, 4.46),
    text(font: font-zh, size: 6.5pt, weight: 700, fill: c-primary.darken(8%))[再启用],
    anchor: "center",
  )
  content(
    (0.90, 4.02),
    text(font: font-zh, size: 6.5pt, weight: 400, fill: luma(35%))[不重新导入模块],
    anchor: "center",
  )
}))
