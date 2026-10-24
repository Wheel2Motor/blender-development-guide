// ============================================================================
//  《Blender 开发指南》—— 公共【定义】模块
//
//  ⚠ 重要架构约定：
//    本文件只放【定义】（变量 / 函数）。所有 `#set` 与 `#show` 规则一律写在
//    main.typ 里。原因是 Typst 的样式规则只在声明它的文件内生效，`#import`
//    不会把样式带给导入方；而各章是通过 `#include` 拼进 main.typ 的，
//    因此只有写在 main.typ 里的规则才能作用到章节内容。
//
//  ⚠ 写作约定：
//    1. Typst 加粗是【单星号】：*加粗*。写 Markdown 的 **加粗** 会触发
//       "no text within stars" 警告且不生效。
//    2. 以尾下划线结尾的标识符必须放进行内代码，否则触发「未闭合强调」：
//       写 `ED_`、`BKE_`、`DEG_`、`GPU_`，不要写裸的 ED_。
//    3. 章节编号一律手写在标题文本里（main.typ 已全局关闭自动编号）。
//    4. 显式 `#set text(...)` 一律给 `weight`：正文用的是静态 Noto Sans SC
//       （Regular 400 / Bold 700 两份 OTF）。历史上用过可变字体，其默认实例是
//       Thin(100)，漏写 weight 就会渲染成细体；这条约定保留下来更稳。
//    5. 默认构建使用工程自带字体；`--use-system-fonts` 开发模式通过 `sys.inputs`
//       注入当前平台实际存在的 fallback 列表。见下方「字体与调色板」。
// ============================================================================

// ---------------------------------------------------------------------------
// 书籍元数据
// ---------------------------------------------------------------------------
// 书籍版本与 Blender 核对基准是两套独立版本。发布新书稿时只修改 meta.json；
// 升级 Blender 基准时修改 blender-baseline.json，并重新完成源码核对。
#let book-meta = json("meta.json")
#let book-version = book-meta.at("version")

// ---------------------------------------------------------------------------
// Blender 核对基准
// ---------------------------------------------------------------------------
// 版本升级时先改 blender-baseline.json。书稿与 Python 检查器都读取同一份数据；
// 版本相关的技术内容仍需按新源码逐项复核，不能只改这里就宣称升级完成。
#let blender-baseline = json("blender-baseline.json")
#let blender-version = blender-baseline.at("version")
#let blender-version-series = blender-baseline.at("version_series")
#let blender-version-suffix = blender-baseline.at("version_suffix")
#let blender-tag = blender-baseline.at("tag")
#let blender-branch = blender-baseline.at("branch")
#let blender-commit = blender-baseline.at("commit")
#let blender-commit-short = blender-commit.slice(0, 12)
#let blender-display-version = blender-version + " " + blender-version-suffix

// ---------------------------------------------------------------------------
// 字体与调色板
// ---------------------------------------------------------------------------
// 字体槽位由两份 JSON 配置之一提供：
//   * fonts/fonts.json              项目字体的正文/代码字体栈；
//   * fonts/fonts-system-fonts.json 不同系统的候选 fallback chain。
// 默认直接读取 Noto 配置。`--use-system-fonts` 由构建脚本选择系统配置、枚举本机实际安装
// 的字体，再通过 Typst 原生的 `sys.inputs` 传入已解析的正文与代码字体栈。
#let font-config-path = sys.inputs.at("font-config", default: "fonts/fonts.json")
#let font-config = json(font-config-path)
#let configured-font-list(name, default: ()) = {
  let encoded = sys.inputs.at(name, default: "")
  if encoded == "" { default } else { encoded.split(";").filter(it => it != "") }
}
#let font-body = configured-font-list("font-body", default: font-config.at("body", default: ()))
#let font-code = configured-font-list("font-code", default: font-config.at("code", default: ()))
#assert(font-body.len() > 0, message: "font configuration produced an empty body slot")
#assert(font-code.len() > 0, message: "font configuration produced an empty code slot")

// font-zh / font-mono 是面向既有图表与助手函数的语义名称；两者分别指向完整槽位。
// Typst 会按数组顺序寻找包含目标字形的第一个字体族。
#let font-zh = font-body
#let font-mono = font-code

// Cetz currently targets paged output. The HTML build pre-renders every maintained
// diagram to build/res/fig-*.svg, then this helper emits a semantic external image.
// The callback is intentionally lazy: HTML export must not evaluate the Cetz canvas.
#let html-figure(name, draw) = context {
  if target() == "html" {
    html.img(src: "res/" + name + ".svg", alt: "", loading: "lazy")
  } else {
    draw()
  }
}

#let c-primary = rgb("#1f6feb")
#let c-note = rgb("#1f6feb")
#let c-tip = rgb("#1a7f37")
#let c-warn = rgb("#9a6700")
#let c-pitfall = rgb("#b62324")
#let c-summary = rgb("#5b3fa8")
#let c-source = rgb("#0b6b6b")
#let c-part = rgb("#0d3f77")

#let rule-color = luma(78%)

#let book-title = "Blender 开发指南"
#let book-subtitle = "从 Python 插件到 C++ 源码修改"

// ---------------------------------------------------------------------------
// 图
// ---------------------------------------------------------------------------
// 截图统一按栏宽缩放
#let shot(path, width: 100%) = image(path, width: width)

// ---------------------------------------------------------------------------
// 提示框
// ---------------------------------------------------------------------------
#let _box(label, color, body) = block(
  width: 100%,
  inset: (x: 0.85em, y: 0.65em),
  radius: 3pt,
  fill: color.lighten(93%),
  stroke: (left: 2.6pt + color, rest: 0.4pt + color.lighten(40%)),
  above: 0.9em,
  below: 0.9em,
)[
  #set par(first-line-indent: 0em)
  #text(font: font-zh, weight: 700, fill: color.darken(15%))[#label]
  #h(0.6em)
  #body
]

#let note(body) = _box([提示], c-note, body)
#let tip(body) = _box([技巧], c-tip, body)
#let warn(body) = _box([注意], c-warn, body)
#let pitfall(body) = _box([陷阱], c-pitfall, body)
#let summary(body) = _box([小结], c-summary, body)

// 实践练习：每个实践性章节末尾使用
#let exercise(body) = block(
  width: 100%,
  inset: (x: 0.9em, y: 0.7em),
  radius: 3pt,
  fill: luma(96%),
  stroke: 0.6pt + luma(55%),
  above: 1.1em,
  below: 0.9em,
)[
  #set par(first-line-indent: 0em)
  #text(font: font-zh, size: 11.5pt, weight: 700)[实践练习]
  #v(0.35em)
  #body
]

// ---------------------------------------------------------------------------
// 篇封面
// ---------------------------------------------------------------------------
#let part-page(num, title, blurb: none) = page(
  header: none,
  footer: none,
  margin: (x: 3cm, top: 6cm, bottom: 3cm),
)[
  #set text(font: font-zh, weight: 400)
  #text(size: 13pt, fill: c-part.lighten(20%))[第 #num 篇]
  #v(0.6em)
  #text(size: 30pt, weight: 700, fill: c-part)[#title]
  #v(0.7em)
  #line(length: 32%, stroke: 1.6pt + c-part)
  #if blurb != none {
    v(1.2em)
    block(width: 78%)[
      #set text(size: 11pt, fill: luma(25%))
      #blurb
    ]
  }
]

// ---------------------------------------------------------------------------
// 行内语义助手
// ---------------------------------------------------------------------------

// 术语首次出现：加粗中文 + 括号英文。例：#term("操作符", "operator")
#let term(zh, en) = [#strong(zh)（#en）]

// 源码路径：等宽 + 主题色。
//
// 这里必须和 main.typ 里行内代码的处理保持一致：在 / _ - . : 之后插入零宽空格，
// 否则长路径（如 source/blender/makesrna/intern/rna_define.cc:940）没有断行点，
// 它的最小内容宽度会把整张表格的列挤变形、甚至把表撑出版心。
// 另外把不换行空格（U+00A0，来自 `\ ` 转义）换成普通空格 —— 前者同样阻止断行，
// 而且会在路径中间多出一个可见空格。
#let src(path) = {
  let parts = ()
  for c in path.clusters() {
    if c == "\u{00A0}" {
      parts.push(" ")
      continue
    }
    parts.push(c)
    if c in ("/", "_", "-", ".", ":") { parts.push("\u{200B}") }
  }
  text(font: font-mono, size: 0.93em, fill: c-source)[#parts.join()]
}

// 外链：可点击超链接 + 明文网址（明文是给纸质读者手抄用的）。
// 明文网址统一用*斜体加下划线*呈现，不用尖括号包裹。
#let weblink(url, label: none) = {
  let plain = text(font: font-mono, size: 8.4pt, fill: luma(40%), style: "italic")[
    #underline[#url]
  ]
  if label == none {
    link(url)[#plain]
  } else {
    link(url)[#label]
    h(0.3em)
    plain
  }
}

// 交叉引用提示：详见第 X 章 / §X.Y
#let seealso(target) = text(size: 9.5pt, fill: luma(30%))[详见 #target]

// 随书完整示例。正文只保留讲解所需的代码；可独立运行、编译或安装的版本
// 统一放进发布包的 examples/ 目录，并用脚注给出稳定的相对路径。
#let example-file(path) = footnote[
  完整文件随发布包放在 #src("examples/" + path)；正文可能只展示与当前主题有关的部分。
]

// 平台标签
#let win = text(fill: c-primary, weight: 700)[Windows]
#let mac = text(fill: c-primary, weight: 700)[macOS]
#let linux = text(fill: c-primary, weight: 700)[Linux]

// 未完成占位（写作过程中使用，交付前必须清空）
#let todo(body) = block(
  width: 100%,
  inset: 0.6em,
  radius: 3pt,
  fill: rgb("#fff4d6"),
  stroke: 0.8pt + rgb("#d4a017"),
)[
  #text(weight: 700, fill: rgb("#8a6100"))[待补] #body
]
