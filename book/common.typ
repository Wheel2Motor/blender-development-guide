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
// 默认字体**由工程自带**（`book/fonts/`，全部 SIL OFL，可自由嵌入分发），构建时必须加
//   --font-path book/fonts --ignore-system-fonts --ignore-embedded-fonts
// 三条缺一不可：
//   * --font-path             指向工程字体目录（由 init-book 下载，见 .gitignore）；
//   * --ignore-system-fonts   完全不看系统字体 —— 这是排除 LiSu（隶书，商业字体）
//                             这类系统回退的关键，也是构建可复现的前提；
//   * --ignore-embedded-fonts 连 Typst 内置的 DejaVu Sans Mono / Libertinus Serif
//                             也不参与回退，任何缺字都必须显式暴露而不是被顶掉。
// 一个字符都不许落到工程之外。开发者显式使用 `--use-system-fonts` 时，构建脚本先枚举
// 本机字体，再把真实存在的 family 通过以下 inputs 传入；不存在的候选不会进入书稿：
//   font-mode=system, font-body=A;B;C, font-code=X;Y;A;B;C
#let font-mode = sys.inputs.at("font-mode", default: "project")
#let input-font-list(name) = sys.inputs.at(name, default: "").split(";").filter(it => it != "")
#let system-font-body = input-font-list("font-body")
#let system-font-code = input-font-list("font-code")
#let font-zh = if font-mode == "system" { system-font-body } else { "Noto Sans SC" }

// 代码（代码块与行内代码）：Noto Sans Mono 首选 + Noto Sans Mono CJK SC 回退。
//
// 为什么是两个字体组成的栈：
//   * 首选 Noto Sans Mono 是纯拉丁等宽，它的 U+2500 系制表符是**半宽**
//     （与 ASCII 完全等宽），所以代码块里 `├──` 正好占 3 个 ASCII 格、树与
//     `#` 注释列落在 ASCII 网格上；
//   * 它不含汉字，所以代码里的中文由回退字体 Noto Sans Mono CJK SC 提供
//     （等宽中文 = 2 个 ASCII 格，与它自己的全角网格一致）。
//   注意：Noto Sans Mono CJK SC **自己**的制表符是全宽的（2 格），但首选字体
//   已经命中那些码位，所以永远不会走到它的制表符 —— 这一点实测确认过。
//   （实测：`├`/`─` 与 ASCII 同为 5.1pt@8.5pt，`中` 为 8.5pt。）
#let font-mono = if font-mode == "system" { system-font-code } else { "Noto Sans Mono" }
#let font-mono-cjk = "Noto Sans Mono CJK SC"

// 最后兜底：拉丁 Noto Sans。**必须放在每个字体栈的末尾。**
//
// 为什么需要它：书里有一个字符 U+0131（无点 i `ı`，见 11-wm-operators.typ:2021
// 讲土耳其语 locale 的那个例子 —— 无点 i 正是该例存在的理由）**不在 Noto Sans SC
// 里**。少了这一项时 `ı` 不会变成缺字方框：实测 Typst 仍会从 `--font-path` 目录里
// 自动挑一个覆盖它的字体（结果同样是 Noto Sans），但挑哪一个由 Typst 的兜底顺序决定，
// 不受我们控制；而**只要去掉 --ignore-embedded-fonts**，Typst 内置的 Libertinus 就会
// 顶上来（实测：那次编译的 PDF 里立刻出现 LibertinusSerif-Regular）。显式把 Noto Sans
// 放进栈里，字体就全部由我们自己 pin，与参数组合无关，PDF 里不会再出现 Libertinus。
// （实测补充：当前书稿里 U+0131 只出现在行内代码中，而 Noto Sans Mono 自己含该字符，
// 所以最终 PDF 的 pdffonts 里其实没有 NotoSans —— 这个兜底是保险，不是当前必需。）
// 放在末尾**不影响任何现有排版** —— 前面的字体命中了就用不到它。
#let font-fallback = "Noto Sans"

// 正文用的字体栈。
#let font-body = if font-mode == "system" { system-font-body } else { (font-zh, font-fallback) }

// 代码统一使用的字体栈：拉丁等宽 + 等宽中文回退 + 拉丁兜底。
#let font-code = if font-mode == "system" {
  system-font-code
} else {
  (font-mono, font-mono-cjk, font-fallback)
}

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
