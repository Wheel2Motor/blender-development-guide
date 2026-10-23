// ============================================================================
//  图：Blender 源码目录结构 + 模块命名前缀（第 8 章 8.1 节）
//  用法（在章节文件里）：
//    #import "../figures/source-tree.typ": fig-source-tree
//    #figure(fig-source-tree(), caption: [源码目录结构与模块命名前缀对照])
//
//  事实来源均按 blender-baseline.json 中的基准核对：
//   - source/blender/                      33 个子模块（Get-ChildItem -Directory 计数）
//   - git ls-files 统计：source/ 下 642 个 .h、2,050 个 .hh
//   - source/blender/CMakeLists.txt:5-102  SRC_DNA_INC 共 96 个 DNA_*.h；同目录共 97 个
//   - source/blender/makesrna/intern/      108 个 rna_*.cc + 7 个 rna_*.hh = 115 个
//   - 前缀函数名个数 = 该模块目录内形如 PREFIX...  的唯一标识符个数（git grep -o -E）
//   - intern/ extern/ scripts/ build_files/ lib/ release/ doc/ tests/ tools/ 在仓库根目录
//
//  注意：本图所有文字都以【字符串】传入，字符串不会被当成 Typst 标记解析，
//        因此不要在这里写反引号或星号（会原样显示）。
//  排版注意：本图宽 15.76cm（实测：行高亮条从 x=-0.08 到 15.68，标称 15.6cm 少算了这 0.16cm；
//  版心 16.4cm，余量 0.64cm）。改动任何文字后必须重渲染确认不重叠。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, blender-version, html-figure

#let fig-source-tree() = html-figure("fig-source-tree", () => canvas(length: 1cm, {
  import draw: *

  let y0 = 10.0
  let step = 0.405
  let tree-x = 0.05
  let pre-x = 4.35
  let note-x = 5.55

  let mono6(c) = text(font: font-mono, size: 6.1pt, weight: 400, fill: luma(15%))[#c]
  let pref(c, col) = text(font: font-mono, size: 6.1pt, weight: 700, fill: col)[#c]
  let note(c) = text(font: font-zh, size: 6.2pt, weight: 400, fill: luma(24%))[#c]
  let head(c) = text(font: font-zh, size: 6.4pt, weight: 700, fill: c-part)[#c]

  // (树形文本, 前缀文本, 前缀颜色, 说明, 是否为强调行)
  let rows = (
    ("源码根目录/", "", luma(50%), "本书核对基准：Blender v" + blender-version, false),
    ("├─ source/", "", luma(50%), "Blender 自有的 C/C++ 源码：642 个 .h + 2,050 个 .hh", false),
    ("│  ├─ blender/", "", c-part, "主体，33 个子模块 —— 前缀就是模块名", true),
    ("│  │  ├─ makesdna/", "DNA_", c-part, "97 个 DNA_*.h，96 个被 makesdna 扫描（§9.1）", false),
    ("│  │  ├─ makesrna/", "RNA_", c-part, "115 个 rna_* 文件 → 生成 bpy.types（§9.3）", false),
    ("│  │  ├─ blenlib/", "BLI_", c-part, "基础库：字符串、容器、数学（1,186）", false),
    ("│  │  ├─ blenkernel/", "BKE_", c-part, "核心数据类型与算法（3,538）", false),
    ("│  │  ├─ editors/", "ED_", c-part, "各编辑器的实现与绘制（1,337）", false),
    ("│  │  ├─ windowmanager/", "WM_", c-part, "窗口、事件分发、操作符（902）", false),
    ("│  │  ├─ depsgraph/", "DEG_", c-part, "依赖图：构建、标记、求值（131）", false),
    ("│  │  ├─ gpu/", "GPU_", c-part, "图形 API 抽象与着色器（769）", false),
    ("│  │  ├─ imbuf/", "IMB_", c-part, "图像缓冲与格式读写（257）", false),
    ("│  │  ├─ render/", "RE_", c-part, "渲染管线与引擎接口（160）", false),
    ("│  │  ├─ blenloader/", "BLO_", c-part, "读写 .blend、版本迁移（86）", false),
    (
      "│  │  ├─ nodes/",
      "（无）",
      c-tip,
      "节点系统，靠 blender::nodes 命名空间；geometry/、compositor/、sequencer/ 同理",
      false,
    ),
    ("│  │  ├─ python/", "BPY_", c-part, "bpy 的 C 侧绑定（106）", false),
    ("│  │  └─ 其余 20 个模块", "", luma(50%), "含 animrig、bmesh、draw、geometry、io、modifiers …", false),
    ("│  └─ creator/", "—", luma(50%), "main()、命令行参数、启动流程", false),
    (
      "├─ intern/",
      "—",
      luma(50%),
      "Blender 自有的独立库：ghost、guardedalloc、clog、cycles …",
      false,
    ),
    (
      "├─ extern/",
      "—",
      luma(50%),
      "随源码分发的第三方库：audaspace、bullet2、tinygltf …",
      false,
    ),
    (
      "├─ scripts/",
      "—",
      luma(50%),
      "随发行版的 Python：startup/、addons_core/、modules/",
      false,
    ),
    ("├─ build_files/", "—", luma(50%), "CMake 平台配置与不同平台的构建脚本", false),
    ("└─ lib/", "—", luma(50%), "预编译依赖（Git LFS 子模块，按平台分目录）", false),
    (
      "   release/ doc/ tests/ tools/",
      "—",
      luma(50%),
      "分发数据、开发者文档、测试套件与辅助脚本",
      false,
    ),
  )

  // 表头
  content((tree-x, y0 + 0.42), head("目录（自仓库根起）"), anchor: "west")
  content((pre-x, y0 + 0.42), head("前缀"), anchor: "west")
  content(
    (note-x, y0 + 0.42),
    head("职责 / 这里有啥（括号内为该前缀在模块内出现的函数名个数）"),
    anchor: "west",
  )
  line((0.0, y0 + 0.30), (15.6, y0 + 0.30), stroke: 0.6pt + c-part.lighten(40%))

  for (i, r) in rows.enumerate() {
    let y = y0 - step * i
    if r.at(4) {
      rect((-0.08, y - 0.20), (15.68, y + 0.20), fill: c-part.lighten(96.5%), stroke: none)
    }
    content((tree-x, y), mono6(r.at(0)), anchor: "west")
    if r.at(1) != "" {
      content((pre-x, y), pref(r.at(1), r.at(2)), anchor: "west")
    }
    content((note-x, y), note(r.at(3)), anchor: "west")
  }
}))
