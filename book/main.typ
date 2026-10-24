// ============================================================================
//  《Blender 开发指南》主文件
//  编译：typst compile main.typ build/blender-development-guide.pdf
//
//  ⚠ 所有 `#set` / `#show` 样式规则必须写在【本文件】里，不能放进 common.typ。
//    Typst 的样式规则只在声明它的文件内生效；章节文件是通过 #include 拼进来的，
//    因此只有写在 main.typ 的规则才能作用到章节内容。
//    章节文件只需 `#import "../common.typ": *` 来使用其中的函数。
// ============================================================================

#import "common.typ": *

//-
// 全局样式
//-
#set document(
  title: book-title,
  author: "Blender 开发指南编写组",
  keywords: ("Blender", "addon", "bpy", "C++", "RNA", "DNA", "depsgraph"),
)

#set page(
  paper: "a4",
  margin: (x: 2.3cm, top: 2.5cm, bottom: 2.2cm),
  header: context {
    // 每页从 1 重新开始编号；同一页内的脚注仍按出现顺序递增。
    counter(footnote).update(0)

    // 取"当前页或之前最后一个一级标题"作为本章标题。
    // 不用 .before()：Typst 的 query() 返回数组，没有该方法。
    let cur = none
    let page-no = here().page()
    for h in query(heading.where(level: 1)) {
      if h.location().page() <= page-no { cur = h }
    }
    if cur == none { return }
    set text(font: font-zh, size: 8.5pt, fill: luma(38%))
    let chapter = cur.body
    let left-text = if calc.even(here().page()) { chapter } else { book-title }
    let right-text = if calc.even(here().page()) { book-title } else { chapter }
    grid(
      columns: (1fr, 1fr),
      align: (left, right),
      left-text,
      right-text,
    )
    v(-0.55em)
    line(length: 100%, stroke: 0.4pt + rule-color)
  },
  footer: context {
    set text(font: font-zh, size: 9pt, fill: luma(35%))
    align(center)[#counter(page).display("1")]
  },
)

#set par(
  justify: true,
  leading: 0.85em,
  first-line-indent: (amount: 2em, all: true),
  spacing: 1.15em,
)

#set text(font: font-zh, fallback: false, size: 10.5pt, weight: 400, lang: "zh", region: "cn")

// Typst 把标记模式下的单个源码换行当作空格。中文正文为了便于维护会按行折行，
// 若换行两侧都是同一文本样式的汉字，这个空格就会出现在 PDF 文本层与 HTML 中。
// 清理同一文本样式内的「汉字 + 空白 + 汉字」序列。代码和不同格式的边界不会被
// 这条文本规则跨越；标题若需要分隔，使用显式的水平间距，而不依赖普通空格。
#show regex("[\u{3400}-\u{9fff}](?:[ \\t]+[\u{3400}-\u{9fff}])+"): text => {
  text.text.replace(regex("[ \\t]+"), "")
}

// 脚注承载不影响主线的短解释。正文与页底均使用圆圈编号，正文标记抬到右上角，
// 页底则按常规脚注字号排列。
#show footnote: it => context {
  let number = counter(footnote).display(at: it.location(), "1")
  super(
    box(
      move(
        dy: -0.62em,
        circle(
          width: 0.78em,
          height: 0.78em,
          stroke: 0.05em + black,
          inset: 0pt,
        )[
          #set align(center + horizon)
          #set text(size: 0.78em, weight: 500)
          #move(dy: 0.22em)[#number]
        ],
      ),
    ),
  )
}
#show footnote.entry: it => context {
  set text(font: font-zh, size: 8.5pt, weight: 400)
  let number = counter(footnote).display(at: it.note.location(), "1")
  grid(
    columns: (1em, 1fr),
    column-gutter: 0.28em,
    align(center + top)[
      #circle(
        width: 0.92em,
        height: 0.92em,
        stroke: 0.055em + black,
        inset: 0pt,
      )[
        #set align(center + horizon)
        #set text(size: 0.78em, weight: 500)
        #number
      ]
    ],
    it.note.body,
  )
}

// 章节编号一律手写在标题文本里，避免「自动编号 + 手写编号」双重编号
#set heading(numbering: none)

#show heading.where(level: 1): it => {
  context {
    if target() == "html" {
      it
    } else {
      pagebreak(weak: true)
      v(0.4em)
      block(width: 100%)[
        #set text(font: font-zh, size: 19pt, weight: 700, fill: c-part)
        #it.body
        #v(0.35em)
        #line(length: 100%, stroke: 1.1pt + c-part)
      ]
      v(0.5em)
    }
  }
}

#show heading.where(level: 2): it => {
  context {
    if target() == "html" {
      it
    } else {
      v(0.75em)
      block(width: 100%)[
        #set text(font: font-zh, size: 14pt, weight: 700, fill: black)
        #it.body
      ]
      v(0.15em)
    }
  }
}

#show heading.where(level: 3): it => {
  context {
    if target() == "html" {
      it
    } else {
      v(0.55em)
      block(width: 100%)[
        #set text(font: font-zh, size: 11.5pt, weight: 700, fill: luma(15%))
        #it.body
      ]
      v(0.05em)
    }
  }
}

// 代码块：底色 + 左侧色条，可跨页。字体走 font-code（Noto Sans Mono CJK SC）——
// 它一个字体里同时有等宽拉丁、**等宽中文**与 U+2500 系制表符，所以代码块里的中文
// 注释也是等宽的，不会落到系统字体，也不需要额外配中文回退。
#show raw.where(block: true): it => block(
  width: 100%,
  inset: (x: 0.5em, y: 0.6em),
  radius: 3pt,
  fill: luma(97%),
  stroke: (left: 2.2pt + luma(60%), rest: 0.4pt + luma(85%)),
  above: 0.9em,
  below: 0.9em,
  breakable: true,
)[#set text(font: font-code, size: 8.2pt, weight: 400); #it]

// 行内代码：换字体与颜色，并【制造断行机会】。
//
// 为什么必须这么做：像 source/blender/blenkernel/BKE_lib_id.hh:120 这样的长路径
// 在 Typst 里默认只能在少数几个字符后断行，于是它的「最小内容宽度」非常大。
// 当这样的单元格出现在表格里时，Typst 会把同一张表里其他列压到只剩一个字符宽
// （实测出现过「做/什/么」每行一个字、并且整表冲出版心几厘米的情况）。
// 在 / _ - . : 之后插入零宽空格（U+200B，不占宽度、不可见）即可让这些位置成为
// 合法断行点，从根本上把最小内容宽度降下来。
//
// 注意：不要套 box —— box 完全不可断行，会让长路径直接冲出版心。
#show raw.where(block: false): it => {
  let parts = ()
  for c in it.text.clusters() {
    parts.push(c)
    if c in ("/", "_", "-", ".", ":") { parts.push("\u{200B}") }
  }
  text(font: font-code, size: 0.93em, fill: luma(12%))[#parts.join()]
}

// 高密度对照表统一略小于正文；标题与强调仍可覆盖字重。
#show table: set text(font: font-zh, size: 9pt, weight: 400)

#set figure(supplement: [图], gap: 0.6em)

// figure 必须允许在「正文」与「表注/图注」之间分页。
//
// 否则当一张表恰好占满整页、连表注的位置都不够时，Typst 不会把最后几行推到
// 下一页，而是让它们与表注*印刷重叠*（附录 C 的表 17 就出现过这种情况）。
// 这类缺陷是「纵向重叠」，横向的版心溢出扫描查不出来，所以必须从根上允许分页。
#show figure: set block(breakable: true)

#show figure.caption: it => context {
  if target() == "html" {
    // Keep Typst's semantic <figcaption>; paged-only align/layout rules erase it in HTML.
    it
  } else {
    block(
      width: 100%,
      above: 0.35em,
    )[
      #set text(font: font-zh, size: 9pt, fill: luma(25%))
      #align(center)[#it]
    ]
  }
}

// 表格与图分开编号，增补词用「表」。用法：
//   #figure(kind: table, table(...), caption: [...])
#show figure.where(kind: table): set figure(supplement: [表], gap: 0.5em)

//-
// 封面
// ------
#page(
  header: none,
  footer: none,
  margin: (x: 2.6cm, top: 5.2cm, bottom: 3cm),
)[
  #text(font: font-zh, size: 32pt, weight: 700, fill: c-part)[#book-title]
  #v(0.5em)
  #text(font: font-zh, size: 14pt, weight: 400, fill: luma(35%))[#book-subtitle]
  #v(1.1em)
  #line(length: 55%, stroke: 2pt + c-part)
  #v(2.2em)

  #block(width: 82%)[
    #set text(font: font-zh, size: 11pt, fill: luma(20%))
    面向具备 C/C++ 与 Python 基础、但尚未读过 Blender 源码的开发者。
    全书分为三篇：从 API 使用者到插件作者，再到能够修改 C++ 源码的贡献者。
  ]

  #v(1fr)

  #block(width: 82%)[
    #set text(font: font-zh, size: 9.5pt, fill: luma(40%))
    书籍版本：#book-version\
    核对基准：Blender #blender-version（#raw(blender-branch)，commit #raw(blender-commit-short)）\
    排版：Typst 0.15.1 + cetz
  ]
]

// ---------------------------------------------------------------------------
// 前言
// ---------------------------------------------------------------------------
#include "front-matter.typ"

// ---------------------------------------------------------------------------
// 目录
// ---------------------------------------------------------------------------
#page(header: none)[
  // 这些规则只属于正文目录。若放在全局作用域，图表索引的一级条目也会全部加粗。
  #show outline.entry.where(level: 1): it => {
    v(0.45em, weak: true)
    strong(it)
  }
  #show outline.entry.where(level: 2): it => {
    set text(size: 9.5pt)
    it
  }

  #set text(font: font-zh, weight: 700, size: 19pt, fill: c-part)
  #heading(level: 1, outlined: false)[目录]
  #set text(font: font-zh, weight: 400, size: 10.5pt, fill: black)
  #outline(title: none, depth: 2, indent: 1.1em)
]

// ---------------------------------------------------------------------------
// 正文
// ---------------------------------------------------------------------------
#part-page("0", "基础与准备", blurb: [
  先把地图画出来。这一篇回答三个问题：Blender 到底是什么样的程序；
  它的源码分成哪些部分、彼此如何协作；以及 *哪些事情能改、哪些事情改不了* ——
  后者往往比前者更省时间。
])

#include "chapters/00-introduction.typ"
#include "chapters/01-architecture.typ"
#include "chapters/02-build-environment.typ"

#part-page("1", "Python 插件开发", blurb: [
  不碰一行 C++，也能做出真正有用的扩展。这一篇从 `bpy` 的生成机制讲起，
  经过 addon 生命周期、界面与交互、数据批量操作与性能，
  最后落在一个可以打包分发的完整项目上。
])

#include "chapters/03-bpy-api.typ"
#include "chapters/04-addon-lifecycle.typ"
#include "chapters/05-python-ui.typ"
#include "chapters/06-data-performance.typ"
#include "chapters/07-addon-project.typ"

#part-page("2", "基于源码进行修改", blurb: [
  当 Python 到不了的地方，就得动 C++。这一篇沿着一条真实的调用链向下走：
  从数据层（DNA/RNA）到基础库、窗口与操作符系统、编辑器、依赖图，
  直到渲染管线，最后讲清楚怎么调试、怎么测、怎么把改动送回上游。
])

#include "chapters/08-source-tour.typ"
#include "chapters/09-dna-rna.typ"
#include "chapters/10-bli.typ"
#include "chapters/11-wm-operators.typ"
#include "chapters/12-editors-ui.typ"
#include "chapters/13-depsgraph.typ"
#include "chapters/14-modifiers-nodes.typ"
#include "chapters/15-render-pipeline.typ"
#include "chapters/16-debug-performance.typ"
#include "chapters/17-testing-contribution.typ"

// ---------------------------------------------------------------------------
// 附录
// ---------------------------------------------------------------------------
#part-page("A", "附录", blurb: [
  速查与索引。术语表、按“想做的事”组织的源码路径索引、构建与开发命令速查、
  不同平台的构建差异对照、构建与开发排错，以及全书图表索引。
])

#include "chapters/appendix-a-glossary.typ"
#include "chapters/appendix-b-path-index.typ"
#include "chapters/appendix-c-commands.typ"
#include "chapters/appendix-d-platform-matrix.typ"
#include "chapters/appendix-e-faq.typ"
#include "chapters/appendix-f-figure-index.typ"
