#import "../common.typ": *

= 附录 F 图表索引

本附录按编号列出全书所有图与表，方便按图索骥。编号与页码由排版系统自动生成，
因此当你增删内容后重新编译，这里的页码会自动跟随。

== 图索引

#outline(title: none, target: figure.where(kind: image))

== 表索引

#outline(title: none, target: figure.where(kind: table))

== 必备图表清单

第 0 章所列的十一张必备图表，对应关系如下（章节号为所在位置，图号见上方图索引）：

#figure(
  kind: table,
  table(
    columns: (auto, 1.6fr, auto),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([序号], [*图表*], [*所在位置*]),
    [1], [全书学习路线图], [§0.1],
    [2], [不同平台的构建流程对照], [§2.2 / 附录 D],
    [3], [源码目录结构图（树状 + 模块前缀标注）], [§8.1],
    [4], [DNA → SDNA → RNA → `bpy` 代码生成管线图], [§9.4],
    [5], [ID / Main / 对象-数据块关系图], [§9.5],
    [6], [事件 → 操作符 → 执行 → 通知 → 撤销 链路图], [§11.1–§11.4],
    [7], [编辑器 `SpaceType` / `ScrArea` / `ARegion` 层级图], [§12.1],
    [8], [depsgraph 节点 / 关系 / 求值副本图], [§13.2],
    [9], [渲染管线图（场景 → 求值 → 引擎 → 合成 → 输出）], [§15.2],
    [10], [Python addon 生命周期图], [§4.1],
    [11], [Python/C++ 分工与"何时下沉 C++"决策图], [§6.4 / §6.6],
  ),
  caption: [必备图表与所在章节的对应关系],
) <tbl-figure-checklist>

#note[
  上表中的"所在位置"给出的是该图的*主题*所在章节；个别图可能在相邻小节展开
  （例如依赖图求值图也可能在 §13.3 再次出现局部放大版）。以图索引中的实际编号与
  页码为准。
]
