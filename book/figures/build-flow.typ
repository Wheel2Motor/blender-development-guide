// ============================================================================
//  图 2：不同平台的构建流程对照
//  用法：
//    #import "../figures/build-flow.typ": fig-build-flow
//    #figure(fig-build-flow(), caption: [不同平台的构建流程对照])
//
//  事实来源（均已核对）：
//   - CMakeLists.txt:29        cmake_minimum_required(VERSION 3.21)
//   - GNUmakefile:175          "This makefile is not meant for Windows"
//   - build_files/windows/parse_arguments.cmd:1-2   BUILD_DIR=..\build_windows, BUILD_TYPE=Release
//   - build_files/windows/configure_ninja.cmd:46-49 cmake -G Ninja ... -H<src> -B<build>
//   - build_files/windows/build_ninja.cmd:5          ninja install
//   - build_files/windows/check_libraries.cmd:31-36  lib 是 Git LFS 子模块，先跳 smudge 再 lfs pull
//   - build_files/cmake/platform/platform_apple.cmake:504  macOS 产物是 Blender.app 包
// ============================================================================
#import "@preview/cetz:0.3.4": canvas, draw
#import "../common.typ": font-zh, font-mono, c-part, c-tip, c-warn, c-primary, c-source, html-figure

#let fig-build-flow() = html-figure("fig-build-flow", () => canvas(length: 1cm, {
  import draw: *

  let col-x = (1.9, 4.6, 7.3, 10.0, 12.7)   // 5 个阶段的左边界（列间留 0.25 给推进箭头）
  let col-w = 2.45
  let stages = ("① 获取源码", "② 获取预编译库", "③ 配置", "④ 构建", "⑤ 产物")

  // 平台行： (y, 名称, 颜色, 五个单元格内容)
  let rows = (
    (
      2.15, "Windows", c-primary,
      ("git clone", "make.bat update", "make.bat ninja", "ninja install", "bin\\blender.exe"),
    ),
    (
      1.15, "macOS", c-tip,
      ("git clone", "make update", "cmake -G Ninja", "ninja install", "bin/Blender.app"),
    ),
    (
      0.15, "Linux", c-warn,
      ("git clone", "make update", "cmake -G Ninja", "ninja install", "bin/blender"),
    ),
  )

  // 表头
  for (i, s) in stages.enumerate() {
    rect((col-x.at(i), 3.22), (col-x.at(i) + col-w, 3.72), fill: c-part.lighten(93%), stroke: 0.5pt + c-part.lighten(45%))
    content((col-x.at(i) + col-w / 2, 3.47), text(font: font-zh, size: 7.5pt, weight: 700, fill: c-part)[#s])
  }

  // 平台行
  for (y, name, col, cells) in rows {
    // 左侧平台名
    rect((0, y), (1.8, y + 0.9), fill: col.lighten(90%), stroke: 0.5pt + col)
    content((0.9, y + 0.45), text(font: font-zh, size: 8pt, weight: 700, fill: col.darken(20%))[#name])
    // 单元格
    for (i, c) in cells.enumerate() {
      rect(
        (col-x.at(i), y),
        (col-x.at(i) + col-w, y + 0.9),
        fill: white,
        stroke: 0.4pt + luma(72%),
      )
      content(
        (col-x.at(i) + col-w / 2, y + 0.45),
        text(font: font-mono, size: 6.4pt, fill: luma(15%))[#c],
      )
    }
    // 行间箭头（阶段推进）
    for i in range(4) {
      line(
        (col-x.at(i) + col-w + 0.04, y + 0.45),
        (col-x.at(i + 1) - 0.04, y + 0.45),
        mark: (end: ">", scale: 0.4),
        stroke: 0.6pt + luma(45%),
      )
    }
  }
}))
