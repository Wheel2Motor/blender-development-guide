// ============================================================================
//  图：DNA → SDNA → RNA → bpy 代码生成管线（第 9 章 9.4 节）
//  用法（在章节文件里）：
//    #import "../figures/dna-rna-pipeline.typ": fig-dna-rna-pipeline
//    #figure(fig-dna-rna-pipeline(), caption: [DNA → SDNA → RNA → `bpy` 代码生成管线])
//
//  事实来源均按 blender-baseline.json 中的基准核对：
//   - source/blender/CMakeLists.txt:5-102         SRC_DNA_INC 共 96 个 DNA_*.h 被扫描
//   - source/blender/makesdna/intern/CMakeLists.txt:100-117  makesdna 产出 5 个文件
//   - source/blender/makesdna/intern/makesdna.cc:863-919     make_structDNA 主流程
//   - source/blender/makesdna/intern/makesdna.cc:952-1019    main() 的 5 个位置参数
//   - source/blender/makesrna/intern/CMakeLists.txt:145-153  rna_*.cc → rna_*_gen.cc
//   - source/blender/makesrna/intern/CMakeLists.txt:422-428  makesrna 调用与三个目录参数
//   - source/blender/makesrna/intern/makesrna.cc:4019-4100   PROCESS_ITEMS（77 个条目）
//   - source/blender/makesrna/intern/makesrna.cc:4412-4414   makesrna 直接解析 DNA 头
//   - source/blender/makesrna/intern/CMakeLists.txt:413      makesrna 链接 bf_dna_defaults
//   - source/blender/python/intern/bpy_rna.cc:9068           BPY_rna_types()
//   - source/blender/python/intern/bpy_rna.cc:8496-8511      StructRNA → PyType 懒创建
//
//  排版注意：本图宽 15.6cm（版心 16.4cm）。改动任何文字后必须重渲染确认不重叠。
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, html-figure

#let fig-dna-rna-pipeline() = html-figure("fig-dna-rna-pipeline", () => canvas(length: 1cm, {
  import draw: *

  let z(x) = text(font: font-zh, size: 6.2pt, weight: 400, fill: luma(18%))[#x]
  let m(x) = text(font: font-mono, size: 5.9pt, weight: 400, fill: luma(18%))[#x]

  // 一个阶段盒子：标题 + 若干行
  let blk(x0, y0, x1, y1, col, title, rows) = {
    rect((x0, y0), (x1, y1), radius: 2.5pt, fill: col.lighten(95%), stroke: 0.7pt + col)
    let step = (y1 - y0) / (rows.len() + 2)
    content(
      ((x0 + x1) / 2, y1 - step),
      text(font: font-zh, size: 6.7pt, weight: 700, fill: col.darken(30%))[#title],
    )
    for (i, r) in rows.enumerate() {
      content(((x0 + x1) / 2, y1 - step * (i + 2)), r)
    }
  }

  // 推进箭头
  let go(x0, x1, y) = line(
    (x0, y),
    (x1, y),
    mark: (end: ">", scale: 0.45),
    stroke: 0.7pt + luma(40%),
  )

  /* ---------------- 两条泳道底板 ---------------- */
  rect((0, 3.60), (15.6, 6.10), radius: 3pt, fill: c-part.lighten(96.5%), stroke: none)
  rect((0, 0.20), (15.6, 2.90), radius: 3pt, fill: c-tip.lighten(96.5%), stroke: none)

  content(
    (0.12, 5.95),
    anchor: "west",
    text(font: font-zh, size: 6.8pt, weight: 700, fill: c-part)[
      DNA 线 · 构建期：结构体定义 → SDNA 字节块 → 写进每个 `.blend`
    ],
  )
  content(
    (0.12, 2.75),
    anchor: "west",
    text(font: font-zh, size: 6.8pt, weight: 700, fill: c-tip)[
      RNA 线 · 同一次构建：`rna_*.cc` → 生成代码 → `bpy.types`
    ],
  )

  /* ---------------- DNA 线（上） ---------------- */
  let ya0 = 3.70
  let ya1 = 5.75
  let ya = 4.725

  blk(
    0.0,
    ya0,
    3.0,
    ya1,
    c-part,
    [① DNA 结构定义],
    (
      m("makesdna/DNA_*.h"),
      z("96 个文件被扫描"),
      z("C++ 结构体 + 默认值"),
      z("POD 约定 · `ID` 基类"),
    ),
  )
  blk(
    3.667,
    ya0,
    6.667,
    ya1,
    c-part,
    [② `makesdna`],
    (
      z("构建期可执行档"),
      m("dna_parse.cc"),
      z("解析头文件并定尺寸"),
      z("对齐不合法就报错"),
    ),
  )
  blk(
    7.333,
    ya0,
    11.333,
    ya1,
    c-part,
    [③ 生成物（build 目录内）],
    (
      m("dna.cc"),
      m("dna_type_offsets.h"),
      m("dna_struct_ids.cc"),
      m("dna_defaults.cc"),
      m("dna_verify.cc"),
    ),
  )
  blk(
    12.0,
    ya0,
    15.6,
    ya1,
    c-part,
    [④ `bf_dna` 库],
    (
      m("DNA_sdna_current_init()"),
      z("编进可执行档，"),
      z("也写进 `.blend` 的 `DNA1` 块"),
      z("读旧文件时按 SDNA 重建"),
    ),
  )

  go(3.02, 3.65, ya)
  go(6.69, 7.31, ya)
  go(11.35, 11.98, ya)

  /* ---------------- RNA 线（下） ---------------- */
  let yb0 = 0.30
  let yb1 = 2.35
  let yb = 1.325

  blk(
    0.0,
    yb0,
    3.0,
    yb1,
    c-tip,
    [①′ RNA 定义],
    (
      m("makesrna/intern/"),
      m("rna_*.cc") + z(" · 115 个"),
      z("50,432 次 ") + m("RNA_def_") + z(" 调用"),
      m("RNA_def_property_*_sdna"),
    ),
  )
  blk(
    3.667,
    yb0,
    6.667,
    yb1,
    c-tip,
    [②′ `makesrna`],
    (
      z("构建期可执行档"),
      z("读同一批 DNA 头文件"),
      z("校验字段真在 DNA 里"),
      z("逐结构体生成 C++ 代码"),
    ),
  )
  blk(
    7.333,
    yb0,
    11.333,
    yb1,
    c-tip,
    [③′ 生成物（build 目录内）],
    (
      m("rna_<name>_gen.cc"),
      m("rna_prototypes_gen.hh"),
      m("RNA_prototypes.hh"),
      z("每文件一个 `_gen.cc`"),
    ),
  )
  blk(
    12.0,
    yb0,
    15.6,
    yb1,
    c-tip,
    [④′ `bf_rna` 库 → `bpy`],
    (
      m("BPY_rna_types()"),
      z("每个 `StructRNA` 懒创建一个"),
      z("`bpy.types.*` 类"),
      m("bl_rna") + z(" · ") + m("foreach_get/set"),
    ),
  )

  go(3.02, 3.65, yb)
  go(6.69, 7.31, yb)
  go(11.35, 11.98, yb)

  /* ---------------- 跨线依赖（虚线） ---------------- */
  line(
    (1.525, 3.58),
    (1.525, 2.92),
    mark: (end: ">", scale: 0.45),
    stroke: (paint: luma(45%), thickness: 0.6pt, dash: "dashed"),
  )
  content(
    (2.0, 3.44),
    anchor: "west",
    text(font: font-zh, size: 6pt, weight: 400, fill: luma(32%))[
      虚线 = `makesrna` 直接解析同一批 `DNA_*.h` —— `RNA_def_*_sdna` 里的字段名就是在这里校验的
    ],
  )
  content(
    (2.0, 3.12),
    anchor: "west",
    text(font: font-zh, size: 6pt, weight: 400, fill: luma(32%))[
      `makesrna` 还链接 `bf_dna_defaults`，用 DNA 结构体的默认成员初始化值填 RNA 默认值
    ],
  )
}))
