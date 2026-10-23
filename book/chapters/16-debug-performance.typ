#import "../common.typ": *

= 第 16 章 调试、性能与优化

第 8 到第 15 章走完了一条完整的调用链：数据层、基础库、窗口与操作符、编辑器、
依赖图、渲染管线。你现在知道相关代码在哪里、应该如何修改。但"能改"和"改对"
仍是两件事，而连接二者的是本章的两个主题：*定位*与*测量*。

一个具体的问题最能说明这有多重要。假设你写的操作符让 Blender 卡了三秒。
面对这种现象，常见的处理方式有两种：

- 凭直觉阅读刚写的 C++ 代码，挑出一个"看起来慢"的地方，修改后重新编译，
  再依据主观感受判断是否变快；
- 先测量这三秒究竟花在依赖图重算、某个循环还是 Python 回调上，
  *只有当数据指向具体函数时，才开始修改。*

本章要给你的就是后一条路。三件事：*用什么工具让程序开口说话*、
*怎么把"慢"翻译成一个具体的位置*、以及 *Blender 这个多线程程序的几条硬约束*。

== 16.1 调试工具链

=== 16.1.1 日志分类：让程序自己说出它在想什么

第 2 章讲的 `--debug-*` 是一大组布尔开关，一个开关管一整块子系统。粒度更细的
工具是日志，它按*类别*（category）组织，可以精确到"只看某个模块"。

接口只有七个参数，注册在 #src("source/creator/creator_args.cc:3092-3097")
与 #src("source/creator/creator_args.cc:3128")：

```bash
$ ./bin/blender --log "*" --log-level debug --log-show-source
$ ./bin/blender --log-list-categories
```

`--log` 的匹配语法写在它的帮助文本里（#src("source/creator/creator_args.cc:1307-1315")），
值得逐条记住：

#figure(
  kind: table,
  table(
    columns: (1.35fr, 2.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*写法*], [*含义*]),
    [`--log "*"`], [打开全部类别],
    [`--log "event"`], [只打开以 `event` 开头的类别],
    [`--log "*mesh*"`], [打开所有*包含* `mesh` 子串的类别],
    [`--log "render,cycles"`], [同时打开两个类别（逗号分隔）],
    [`--log "*,^operator"`], [`^` 前缀表示*排除*：除了操作符，其余全开],
  ),
  caption: [`--log` 的匹配语法。排除项与包含项写在同一个逗号分隔串里。],
) <tbl-log-match>

日志的*实现*在 #src("intern/clog/")：它是 Blender 自己的一层薄封装，
宏前缀是 `CLOG_`（不是 `CLG_`）。类别由 #src("intern/clog/CLG_log.h:139-141")
的 `CLG_LOGREF_DECLARE_GLOBAL` 注册：

```cpp
/* source/blender/windowmanager/WM_types.hh:1524（节选） */
extern CLG_LogRef *WM_LOG_OPERATORS;
extern CLG_LogRef *WM_LOG_EVENTS;
```

```cpp
/* source/blender/windowmanager/intern/wm_init_exit.cc:122（节选） */
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_OPERATORS, "operator");
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_EVENTS, "event");
```

也就是说，*类别的名字就是那个字符串字面量*，而日志点是*懒初始化*的 ——
不需要在启动时集中注册，第一次用到才建（#src("intern/clog/CLG_log.h:132-136")）。
文件头注释给了命名约定：小写、点号分隔，例如 `module.sub_module`，
这样可以用 `module.*` 做前缀过滤（#src("intern/clog/CLG_log.h:24-26")）。
`identifier` 字段是 `char[64]`（#src("intern/clog/CLG_log.h:71")），别写太长。

*级别*与宏一一对应。#src("intern/clog/CLG_log.h:52-65") 定义了六级：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 0.85fr, 2.6fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*枚举*], [*`--log-level`*], [*含义（源码注释原文的意思）*]),
    [`CLG_LEVEL_FATAL`], [`fatal`], [类似断言：打印后输出栈并 `abort`],
    [`CLG_LEVEL_ERROR`], [`error`], [可恢复的错误，本不该发生],
    [`CLG_LEVEL_WARN`], [`warning`], [一般警告，不必给最终用户看],
    [`CLG_LEVEL_INFO`], [`info`], [设备、文件、配置、用户操作的信息],
    [`CLG_LEVEL_DEBUG`], [`debug`], [给开发者的信息],
    [`CLG_LEVEL_TRACE`], [`trace`], [非常啰嗦的执行轨迹],
  ),
  caption: [日志级别。`--log-level` 接受级别名或数字（数字是向后兼容路径，见 `creator_args.cc:1231-1239`）。],
) <tbl-log-levels>

宏的名字就是级别名加前缀：`CLOG_FATAL`、`CLOG_ERROR`、`CLOG_WARN`、`CLOG_INFO`、
`CLOG_DEBUG`、`CLOG_TRACE`（#src("intern/clog/CLG_log.h:187-192")）。
第二个参数是那条消息自己的*最低级别要求* —— 只有类别级别不低于它才会真正打印：

```cpp
/* source/blender/python/intern/bpy_interface.cc:392（节选） */
CLOG_DEBUG(BPY_LOG_INTERFACE, 1, "Creating a new BPY_interpreter.");
```

另有两个"不受过滤影响"的变体 `CLOG_INFO_NOCHECK` 与 `CLOG_STR_INFO_NOCHECK`
（#src("intern/clog/CLG_log.h:204-206")）。它们用于必须出现的少数消息，
比如文件保存与加载；只有 `-q` / `--quiet`（`CLG_quiet_set`）能让它们安静下来。

下面这张表是从源码里核对出来的一部分真实类别，按调试场景分组。

#figure(
  kind: table,
  table(
    columns: (1.15fr, 2.5fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*类别*], [*什么时候用它*]),
    [`operator`], [操作符的调用与轮询。注册处 `WM_types.hh:1524`、`wm_init_exit.cc:122`],
    [`event`], [输入、窗口、屏幕事件。注册处 `wm_init_exit.cc:123`],
    [`tool.gizmo`], [工具与 gizmo。注册处 `wm_init_exit.cc:124`],
    [`msgbus.pub` / `msgbus.sub`], [消息总线的发布与订阅（界面局部刷新靠它）。注册处 `wm_init_exit.cc:125-126`],
    [`context`], [上下文成员的查找。注册处 `blenkernel/intern/context.cc:59`],
    [`bpy.interface` / `bpy.rna`], [Python 界面回调与 RNA 绑定。注册处 `python/intern/bpy_interface.cc:78-79`],
    [`hydra.scene_index` / `hydra.render`], [Hydra 渲染代理。注册处 `io/usd/hydra/scene_index.cc:40`、`render/hydra/engine.cc:30`],
    [`io.materialx`], [MaterialX 节点解析。注册处 `nodes/shader/materialx/node_parser.cc:15`],
  ),
  caption: [常用日志类别（注册点均已按本书采用的 Blender 源码版本核对）。完整清单用 `--log-list-categories` 打印。],
) <tbl-log-cats>

给自己加一个类别只要两行，这是排查"这段代码到底有没有被调用"最快的手段：

```cpp
/* 头文件里 */
extern CLG_LogRef *MY_LOG_EDITOR;

/* 实现文件里 */
CLG_LOGREF_DECLARE_GLOBAL(MY_LOG_EDITOR, "editor.my_feature");

/* 使用点 */
CLOG_INFO(MY_LOG_EDITOR, 1, "rebuilt %d items", count);
```

加完直接 `--log "editor.my_feature" --log-show-source` 验证。
`--log-show-source` 会让每条日志带上 `文件:行号` 与函数名
（#src("source/creator/creator_args.cc:1252-1258")），定位调用点比读代码快得多。

#tip[
  日志与 `--debug-*` 是两套独立机制，可以叠加。经验组合是：
  *`--debug-xxx` 打开子系统的调试行为，`--log "xxx.*"` 控制输出粒度。*
  `--debug-gpu` 就是一个把两者绑在一起的例子：它除了置上 `G_DEBUG_GPU`，
  还会自动把 `gpu.*` 加进日志过滤（#src("source/creator/creator_args.cc:1545-1552")）。
]

#warn[
  `CLOG_DEBUG` 与 `CLOG_TRACE` 在 Release 构建里*不会被编译掉*。
  把 `CLOG_TRACE` 放进高频循环，即使没人打开它也会参与判断与分支预测。
  写性能敏感代码时，这类日志要么只留在 Debug 分支，要么先测一次再决定。
  另外有一组 `--debug-*` 开关是*条件编译*的 —— `--debug-ffmpeg`、
  `--debug-freestyle`、`--debug-cycles`、`--debug-libmv`、`--debug-xr` 只在
  对应功能打开时才注册（#src("source/creator/creator_args.cc:3182-3245")），
  在你的构建里敲出来会得到"未知参数"。
]

=== 16.1.2 错误与内存：一组只影响行为的开关

大多数 `--debug-*` 只改日志。有几个改的是*程序行为*，在定位问题时价值最高：

- `--debug-exit-on-error`：遇到内部错误立即退出。它的实现只有两行
  （#src("source/creator/creator_args.cc:1070-1074")）：打开"检测到内存泄漏即失败"，
  并把日志错误回调换成 abort 回调。配合调试器或 `--python-exit-code` 使用时，
  它把"错误被悄悄忽略、后面才崩溃"变成"在错误发生的那一行停下"。
- `--debug-memory`：打开*完全受保护*的内存调试
  （#src("source/creator/creator_args.cc:1511-1518")，调用 `MEM_set_memory_debug()`）。
  它不在参数解析后才生效 —— 主程序启动早期会先扫一遍 `argv`，
  一旦发现 `-d`、`--debug`、`--debug-memory` 或 `--debug-all`，
  就在*任何分配发生之前*把分配器切换成受保护版本，并打开内存泄漏检测
  （#src("source/creator/creator.cc:407-420")）。
  受保护分配器会在每块内存的头尾加标记，越界写能在下次检查时被抓到。
- `--debug-value <n>`：把一个整数放进 `G.debug_value`
  （#src("source/creator/creator_args.cc:1520-1540")）。
  它本来是给 C 代码里的调试分支用的，但 Python 侧也能读 ——
  官方 glTF 插件就用 `bpy.app.debug_value == 102` 开启 `cProfile`
  （见第 6 章 §6.4）。
- `--debug-fpe`：浮点异常处理设置。数值类 bug（NaN 扩散、除以零）用它比用打印快。

关于这组开关的完整清单，以及"`-d` 具体做了什么"，见第 2 章 §2.7.2 与附录 C.4.3。

=== 16.1.3 单步调试与崩溃分析：三平台工具

断点调试的设置在第 2 章 §2.7.3 已经讲完（gdb / lldb 的调试器美化打印器、
natvis、以及"Release 构建里局部变量会被优化掉"这个易错点），这里不重复。
本节只补充 *C++ 侧的调用点*该往哪里下断点。

#figure(
  kind: table,
  table(
    columns: (1fr, 1.9fr, 1.5fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*你要查什么*], [*主力的落点*], [*备注*]),
    [某个操作符的行为],
    [`WM_operator_call_py` / `wm_operator_call_internal`],
    [从 `WM_OT_` 函数名反查注册处，见附录 C.5],
    [某次界面重绘],
    [`wm_draw_update`（`windowmanager/intern/wm_draw.cc`）],
    [`--debug-wm` 会打印这一段的流程],
    [某次网格求值],
    [`evaluate_node`（`depsgraph/intern/eval/deg_eval.cc:88` 附近的求值路径）],
    [`--debug-depsgraph-eval` 打印它走过的每个节点],
    [某个 Python 回调抛异常],
    [`--debug-python` 打开绑定层输出],
    [Python 异常被 C 侧吞掉时，这一步最关键],
  ),
  caption: [C++ 侧常用的断点落点。所有路径均已按本书采用的 Blender 源码版本核对。],
) <tbl-breakpoints>

还有一个只在崩溃时才用得上的参数：`--console-crash-handler`
（#src("source/creator/creator_args.cc:3152-3153")，注册为
`arg_handle_crash_handler_console`）。它让崩溃处理程序把信息打到控制台而不是
写成文件 —— 在 CI 或终端里执行复现脚本时，这一条能省掉找日志文件的功夫。
`--disable-crash-handler` 与 `--disable-abort-handler` 紧邻其后
（#src("source/creator/creator_args.cc:3154-3157")），后者在你要让断言直接
`abort` 进入调试器时有用。

== 16.2 Profiling：先测量，再优化

=== 16.2.1 三层工具与各自的前置成本

"我感觉是这里慢"不是测量。测量有三个层次，成本依次上升。*能用第一层解决
的问题，绝不要动第二层。*

#figure(
  kind: table,
  table(
    columns: (1.1fr, 1.35fr, 1.3fr, 0.7fr),
    inset: 5.5pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层次*], [*能回答的问题*], [*典型命令或工具*], [*要重新编译*]),
    [① 计时],
    [一个完整动作要多久，数值是否稳定],
    [`perf_counter` 手写计时（第 6 章 §6.4）],
    [不要],
    [② Blender 内置调试开关],
    [依赖图求值慢不慢、任务调度怎么排的],
    [`--debug-depsgraph-time`、`--debug-jobs`、`--profile-gpu`],
    [不要],
    [③ 采样分析器],
    [*哪个函数*在烧 CPU、调用栈长什么样],
    [`perf`（Linux）、Instruments（macOS）、VS 诊断工具（Windows）],
    [不要，但最好带符号构建],
  ),
  caption: [测量工具的三个层次。第三层是唯一能直接给出函数名的，也是唯一需要外部工具的。],
) <tbl-profiling-layers>

#tip[
  第三层与第二层的差别可以用一句话记住：*第二层告诉你"哪一步慢"，
  第三层告诉你"哪一行慢"。* 先用第二层把范围缩到一个函数，
  再用调试器或采样器看它的内部，是最省的路径。
]

=== 16.2.2 第二层：Blender 自带的计时输出

这一层的好处是*零安装*：不需要 profiler，不需要改构建。

*任务调度*用 `--debug-jobs`（#src("source/creator/creator_args.cc:3250-3254")）。
它对应的位在 #src("source/blender/blenkernel/BKE_global.hh:250") 的注释里
写得很直白：`G_DEBUG_JOBS` 是 "jobs time profiling"。

*依赖图*有两个时间口径，必须先分清，否则数字会读错：

#figure(
  kind: table,
  table(
    columns: (1.25fr, 1.3fr, 2.35fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*口径*], [*开什么*], [*输出与实现*]),
    [整图求值总时间],
    [`--debug-depsgraph-time`],
    [“`Depsgraph [名字] updated in N seconds`”。在 `begin_graph_evaluation()` 与 `end_graph_evaluation()` 之间用 `BLI_time_now_seconds()` 夹出来的墙钟时间（#src("source/blender/depsgraph/intern/debug/deg_debug.cc:27-49")）],
    [建图时间],
    [`--debug-depsgraph-time` 或 `--debug-depsgraph-build`],
    [“`Depsgraph built in N seconds`”。两个位共用同一个判断（#src("source/blender/depsgraph/intern/builder/pipeline.cc:88-107")）],
    [逐节点耗时],
    [`--debug-depsgraph-time`],
    [求值时给每个操作节点累加 `stats.current_time`（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:95-98")），求值结束后聚合到组件节点与 ID 节点（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:503-505")）；输出由 `deg_debug_stats_gnuplot.cc` 负责],

  ),
  caption: [依赖图的三个时间口径。最容易混的是第一行与第二行：看墙钟用第一行，看建图开销用第二行。],
) <tbl-depsgraph-time>

有一个细节值得点出来，因为它在源码里很容易看漏：
#src("source/blender/depsgraph/intern/debug/deg_debug.cc:22-25") 里
`do_time_debug()` 检查的是 `G_DEBUG_DEPSGRAPH_TIME`，而这个位*就在*
`G_DEBUG_DEPSGRAPH` 宏的并集里 —— 该并集由
`BUILD | EVAL | TAG | TIME | UID` 五项组成
（#src("source/blender/blenkernel/BKE_global.hh:260-261")），
不在其中的只有 `NO_THREADS` 与 `PRETTY` 两位
（这与第 13 章 §13.5、第 8 章的说法一致）。
所以 `--debug-depsgraph` 本身就会置上 `TIME`
（#src("source/creator/creator_args.cc:3290-3294")），
它会一并打开建图、求值、标记、耗时与 UID 五类输出。

这一步还有一个实际后果：*想只要耗时数字、不要逐节点日志，才需要单写
`--debug-depsgraph-time`*。`do_time_debug()` 只看 `TIME` 这一位
（#src("source/blender/depsgraph/intern/debug/deg_debug.cc:22-25")），
所以只加 `-time` 时，你不会得到 `--debug-depsgraph-eval` 那种逐节点求值日志 ——
拿到的是时间数字。需要两者同时看时，写一个 `--debug-depsgraph` 就够了，
也可以把 `-time` 与 `-eval` 两个开关都写上。

读输出的方法：

1. 先看整图总时间。如果它只有几十毫秒，而你的界面操作卡了几百毫秒，
   那瓶颈根本不在依赖图 —— 去查界面绘制（`wm_draw.cc`）或你的 Python 回调。
2. 再看逐节点列表里排名靠前的几个节点名。节点名由 `Node::identifier()` 拼成
   “`类型 : 名字`”（#src("source/blender/depsgraph/intern/node/deg_node.cc:297-300")），
   所以一眼就能看出是哪个数据块、哪一类操作。
3. 如果逐节点耗时之和远大于总时间，说明并行度是好的 —— *不要去"优化"
   这个差距*（关掉线程只会让总时间变长）。
4. 想知道"为什么重算"而不是"哪里慢"，换
   `--debug-depsgraph-tag`（见第 13 章 §13.5.4 的组合用法）。

*GPU 侧*只有一个内置入口，但它比想象的更有用：

```bash
$ ./bin/blender --profile-gpu scene.blend
```

它把 CPU 与 GPU 的耗时写成当前目录下的 `profile.json`
（#src("source/blender/gpu/intern/gpu_profile_report.hh:26-32")），格式是
Chrome Trace Event，可以直接拖进 `chrome://tracing` 或 Perfetto 查看。
每条记录同时带 GPU 时间与 CPU 时间，按线程分开
（#src("source/blender/gpu/intern/gpu_profile_report.hh:47-73")
与 #src("source/blender/gpu/intern/gpu_profile_report.hh:75-89")）。
注意它*写到当前工作目录*，所以在 `build/bin` 下执行会得到一个 `bin/profile.json`。

=== 16.2.3 什么时候才需要 Tracy

Blender 源码里带了一个嵌入式帧分析器 Tracy，开关在
#src("CMakeLists.txt:922-928")：

```text
# CMakeLists.txt:922-925
Enable profiling via the Tracy Frame Profiler.
This option adds a `tracy_profiler` target for building the profiler GUI front-end.
Requires internet access.
```

打开它要两件事：

```bash
$ cmake -B ../build_debug -DWITH_TRACY=ON -DCMAKE_BUILD_TYPE=Debug
$ ninja -C ../build_debug tracy_profiler      # 下载并构建分析器前端
```

`tracy_profiler` 这个目标名是特意起的 —— `extern/tracy_profiler/CMakeLists.txt:9-11`
的注释解释了原因：它由开发者手动构建，而不是被 `all` 带上。

埋点宏在 #src("intern/profile/PRF_profile.hh")，前缀是 `PRF_`。头文件注释
（#src("intern/profile/PRF_profile.hh:10-13")）说明了最省事的一点：
*没有打开 Tracy 时，这些宏是空操作*，所以可以把埋点直接留在代码里。

```cpp
/* source/blender/windowmanager/intern/wm.cc:598-620（节选） */
void WM_main(bContext *C)
{
  PRF_scope(ProfileCategory::Core);
  ...
  while (true) {
    ...
    PRF_frame_mark;   /* 一帧的边界 */
  }
}
```

现有埋点的分布决定了 Tracy 的适用边界。`PRF_scope` 系列宏的埋点远不止主循环：
在 `source/` 下数 `git grep -o 'PRF_scope' -- source/`，有 *485 处、
分布在 104 个文件*里（全仓库含 `intern/profile/PRF_profile.hh` 里这些宏自身的
20 处定义与包装，共 505 处 / 105 个文件）。按模块看，最多的是
`editors/sculpt_paint/`（300 处），其次是 `blenkernel/`（54 处，
例如 `pbvh.cc` 10 处、`curves_geometry.cc` 9 处、`mesh_normals.cc` 6 处）、
`sequencer/`（48 处）、`geometry/`（31 处，例如 `realize_instances.cc` 13 处）、
`blenlib/`（25 处）与 `windowmanager/`（12 处）。
窗口管理一侧的埋点确实覆盖主循环、事件分发、绘制与操作符调用 ——
`windowmanager/intern/wm.cc:600`、`wm_draw.cc:1238` 与 `:1644`、
`wm_event_system.cc:598`、`:1115`、`:1660`、`:2669`、`:4219`、
`wm_window.cc:2200` —— 但*几何算法（`geometry/`，以及 `blenkernel/` 里的
PBVH 与法线计算）内部同样有大量埋点*。真正没有埋点的是依赖图：
`depsgraph/` 目录下 `PRF_scope` 的命中数是 *0*。所以准确的说法是
"依赖图这一个模块内部没有埋点"，而不是"几何算法内部没有埋点"。

#note[
  这一点决定了 Tracy 的正确定位：它是*帧级工具*（这个界面操作在哪一段卡住、
  一帧里绘制占多少），不是"找热点函数"的工具。要找热点函数，
  仍然用采样器。要在依赖图内部找热点，先用 `--debug-depsgraph-time`，
  必要时自己在可疑的求值函数里临时加一个 `PRF_scope`。
]

打开 `WITH_TRACY` 之后，构建系统会带来一个 Tracy 的*服务端*可执行文件
（客户端库已经链进 Blender 里）。它的确切文件名以你本机构建目录里的产物为准，
本轮核对的环境里没有配置过这个选项，所以本书不给它一个可能出错的名字。
官方说明见
#weblink("https://developer.blender.org/docs/handbook/tools/profiling/", label: [Profiling with Tracy])。

=== 16.2.4 第三层：采样分析器

采样分析器按固定间隔抓取调用栈，因此*不需要你提前知道热点在哪*，
开销也远低于逐函数插桩。Blender 没有绑定其中任何一个，但它们是普通的外部工具，
用法与调任何 C++ 程序一样。

#linux 上主力是 `perf`。要拿到有意义的栈必须显式要调用图：

```bash
$ perf record -g --call-graph dwarf -o /tmp/blender.perf \
    -- ./bin/blender -b -X --python repro.py
$ perf report -i /tmp/blender.perf --sort=dso,symbol
```

`--call-graph dwarf` 是关键：Blender 的 C++ 代码内联与尾调用很多，
默认的帧指针法拿不到完整栈。`perf` 还能看*所有线程*，这对下面 16.4
要讲的并行问题很重要 —— 一个"主线程很闲、总时间却很长"的现场，
在 per-thread 视图里一眼就能看出来。

#mac 上对应的是 Instruments 的 Time Profiler：用 Xcode 打开工程不方便时，
可以直接在命令行里 `xctrace record --template 'Time Profiler' --launch ./Blender.app`，
本轮询到的模板名与选项请以你机器上 `xctrace list templates` 的输出为准。

#win 上最省事的是 Visual Studio 的"性能探查器"（Debug → Performance Profiler），
它本来就能附加到 CMake 生成的工程上；这也正是 `make.bat` 不加 `ninja` 时
会给你 `Blender.sln` 的附带好处（见第 2 章 §2.7.4）。
装了 RenderDoc 的场景可以用 `-DWITH_RENDERDOC=ON` 编译
（#src("CMakeLists.txt:900")），再用 `--debug-gpu-renderdoc`
（仅在 `WITH_RENDERDOC` 打开时注册，#src("source/creator/creator_args.cc:3280-3283")）
抓帧。

#pitfall[
  采样分析器最容易读错的两件事。第一，*符号缺失*：Release 构建把符号剥掉后
  你只会看到一堆地址。用 Debug 或 RelWithDebInfo 构建来取栈。
  第二，*内联*：热点函数被内联进调用者后，名字会出现在调用者身上。
  看到"大函数哪里都慢"时，先用 `perf annotate` 看逐行热度，
  再判断是不是内联导致的错觉。
]

== 16.3 优化方法论

这一节是本章的重点。工具会过时，方法不会。

=== 16.3.1 先立基线：一个可以重复执行的测量

没有基线的优化无法被证明。而"证明"是本章所有工作的交付物 ——
你自己一周后也会忘记当时到底快了多少。

基线场景要同时满足三条：*可以重复*、*贴近真实*、*足够快*（几十秒内出结果）。

```bash
# 基线：出厂配置、无界面、单线程、安静输出、固定输入
$ ./bin/blender -b -X -t 1 --quiet \
    --python-exit-code 1 --python bench_scene.py my_scene.blend
```

四个参数各有理由：

- `-b` 与 `-X`：去掉界面与用户配置的干扰。第 2 章已经解释过
  `-X` 是"是不是我的插件搞的鬼"的第一道筛子。
- `-t 1`：*固定线程数*。这是最常被忽略的一条。并行程序的运行时间与
  同时有多少线程可用强相关，同一份代码在一台空闲机器和一台正在承载其他
  任务的机器上可以差一倍。固定成 1 虽然慢，但数字稳定；需要看并行效果时
  再单独执行一组 `-t` 对比。
  `-t` 的实现是 `BLI_system_num_threads_override_set()`
  （#src("source/creator/creator_args.cc:2398-2421")），取值范围是
  `1..BLENDER_MAX_THREADS`，`0` 表示用系统处理器数。
- `--python-exit-code 1`：让脚本抛异常时以非零码退出，否则你会把一次
  失败的测量当成成功数据（第 2 章 §2.7.1）。

#tip[
  并行场景的基线别取平均值，取*多次运行的最小值*。理由与第 6 章
  讲 `timeit` 时一样：最小值最接近"没有被打断时的真值"，
  平均值把抖动算进了基线，会让你在优化后误判为"没有改善"。
]

=== 16.3.2 判断层级：把"慢"翻译成位置

这是整章最核心的一张表。它的用法是*从症状反查层级* ——
先确定层级，再决定要不要动 C++。

#figure(
  kind: table,
  table(
    columns: (1.7fr, 1.25fr, 1.6fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*症状*], [*责任层*], [*下一步*]),
    [只有 Python 脚本的纯计算慢，C 侧调用次数正常],
    [Python 层],
    [`cProfile` 找 `tottime` 最高的自有函数（第 6 章 §6.4）],
    [`tottime` 最高的几行都是 `bpy` 内置方法],
    [跨界调用层],
    [改调用方式：`foreach_get` / `foreach_set` / numpy，而不是改算法（第 6 章）],
    [拖动一个物体就掉帧，改个无关参数也要重算],
    [依赖图层],
    [`--debug-depsgraph-tag` 找标记来源，`--debug-depsgraph-time` 看逐节点耗时],
    [求值总时间不长，界面仍然卡],
    [界面绘制层],
    [`--profile-gpu` 拿 `profile.json` 看绘制各段耗时；`--debug-wm` 看事件流],
    [渲染一帧慢，而视图操作流畅],
    [渲染管线层],
    [先区分是 CPU 端场景准备还是 GPU 端着色；`--profile-gpu` 能分辨两者],
    [首次加载慢、之后正常],
    [I/O 与缓存层],
    [`--debug-io` 看文件读写；先确认不是冷缓存造成的假象],
  ),
  caption: [症状 → 层级 → 工具。*不要跳过这一步直接改算法。*],
) <tbl-layer-triage>

这张表的价值在于它强制你在动手前回答"我改的是不是那个慢的层"。
一个真实的教训：有人为了让网格处理"更快"，手写了一个比 Blender 内置实现
更复杂的 C++ 算法，结果整体只快了 5% —— 因为时间花在每次操作都重新
构建依赖图上，与他改的那个函数无关。

=== 16.3.3 四类优化手段与优先级

确定了层级之后，真正可用的手段只有四类。它们的顺序不是随意的：
*从上往下，风险与成本递增，收益与代价的比值递减。*

==== 第一类：减少工作量

最便宜、也最常被忽略的一类。多数"性能问题"其实不是算得慢，
而是*算了两遍*或*算了不需要的东西*。

- *批处理*：把 N 次调用合成 1 次。Python 侧的 `foreach_get` / `foreach_set`
  是同一个思想的具体化（第 6 章）。C++ 侧的对应做法是让接口接受区间，
  而不是逐个元素。
- *缓存*：值只依赖不变输入时，缓存它。Blender 里的正面样板是
  "表达式缓存" —— 驱动表达式编译后的代码对象被缓存下来，
  而不是每帧重新编译（相关注释见 #src("source/blender/python/intern/bpy_driver.cc:335-337")）。
- *提前退出*：多数"重算"请求其实不需要重算。依赖图靠 tag 位判断这一点，
  `deg_evaluate_on_refresh()` 的第一句就是空 tag 直接返回
  （#src("source/blender/depsgraph/intern/eval/deg_eval.cc:420-425")）。
  你写的代码也该有这样一个便宜的前置判断。

==== 第二类：换数据结构或算法

复杂度降一级，通常比任何常数级优化都值钱。这一层要动的是*算法*，
所以需要真正的测量支撑 —— 复杂度分析告诉你"哪个规模会爆炸"，
采样器告诉你"现在是不是就在这个规模上"。

==== 第三类：并行

并行有价值，但有三个必须同时满足的前提，否则会变慢：

1. *工作量足够大。* 调度本身要成本。Blender 的 C++ 并行入口
   `blender::threading::parallel_for` 就内置了这个判断：
   范围太小或粒度太细时，它直接在单线程上处理整个范围
   （#src("source/blender/blenlib/BLI_task.hh:68-82")）。
   参数 `grain_size` 的含义是"一次调度大约覆盖多少工作量"
   （#src("source/blender/blenlib/BLI_task.hh:55-58")），
   不是越大越好，也不是越小越好。
2. *没有共享可写状态。* 详见 16.4。
3. *不是内存带宽瓶颈。* 纯粹"把缓冲区填满"的循环加线程不会变快，
   因为瓶颈在内存总线上而不在 CPU 上。Blender 为这种情况准备了专门的入口
   `threading::memory_bandwidth_bound_task`
   （#src("source/blender/blenlib/BLI_task.hh:239-253")）：
   触碰内存小于 8 MiB 时它直接串行执行，否则把并发限制在一个 8 线程的
   `tbb::task_arena` 里（#src("source/blender/blenlib/intern/task_range.cc:291-317")）。

==== 第四类：下沉 C++

只有当前三类都确认不适用时，才写或改 C++。这一层的门槛更高：
你要维护它、跟随上游演进、承担线程安全与内存管理的责任。

#exercise[
  *练习 16.1* 拿一个你熟悉的场景（比如拖动一个高面数物体），
  分别用 `--debug-depsgraph-time` 与 `--debug-jobs` 执行一遍，
  记录整图求值时间与逐节点耗时前三名。然后回答：
  这三名的耗时之和与整图总时间哪个大？这个差距说明了什么？

  *练习 16.2* 用同一份基线命令分别执行 `-t 1` 与 `-t 8`，
  比较两次的总时间。如果两者几乎一样，你的场景是并行不足、
  还是本来就被内存带宽限住了？用 16.3.3 的判据给出结论。

  *练习 16.3* 用 `--profile-gpu` 生成 `profile.json`，
  用 Chrome 打开它，找出 CPU 端耗时最长的那一段的名字。
  它属于哪一层？
]

=== 16.3.4 测量本身会骗人：四条纪律

上面所有判断都建立在"数字可信"的基础上。下面四条是数字不可信的常见原因。

- *热/冷缓存。* 第一次执行要读盘、要编译着色器、要建各种缓存。
  至少测量两遍，只用第二遍之后的数字；并在基线里写清是冷还是热启动。
- *首次运行的额外开销。* GPU 着色器编译是最典型的例子。
  Blender 的 ShaderC / OpenGL 后端会把编译结果缓存下来
  （`--debug-gpu-compile-shaders` 与 `--debug-gpu-shader-no-preprocessor`
  这类开关就是为观察它而存在的），所以第一次启动慢是正常的。
- *构建类型。* *Debug 构建不影响功能正确性，但绝不能用来做性能判断。*
  断言的代价、-O0 的代价、未内联的代价叠加起来是数倍。
  判断性能用 Release，定位问题用 Debug —— 这也正是第 2 章
  建议"两套构建目录并存"的原因。
- *机器状态。* 笔记本降频、后台同步、浏览器，都能让同一份代码
  上下浮动几十个百分点。做对比测量时，关掉无关负载，
  并*交替*测量新旧两版（A、B、A、B），而不是先测完 A 的全部再测 B。

#warn[
  比较两个版本时，*一次只改一个变量*。同时改了算法和线程数，
  得到的好数字无法归因，下次还会犯同样的错。
]

=== 16.3.5 如何证明一次优化是成功的

优化提交需要证明两件事，缺一不可：

1. *数值上确实更好*，并且附上测量条件（版本、构建类型、线程数、场景）。
2. *没有破坏功能*。这一步靠第 17 章那套测试体系：
   `make test`（#win 是 `make.bat test`）。

#summary[
  优化方法可以压成五句话：
  1. *先立一个可以重复执行的基线*，否则你无法证明任何事。
  2. *先判断层级，再动手*：用 16.3.2 那张表从症状反查责任层。
  3. *按"减少工作量 → 换算法 → 并行 → 下沉 C++"的顺序尝试*，
     越靠前的越便宜。
  4. *并行有三个前提*：工作量够大、没有共享可写状态、不是内存带宽瓶颈。
  5. *保住功能*：优化完成后必须执行测试（第 17 章）。
]

== 16.4 内存与线程

=== 16.4.1 GIL：为什么工作线程里不能直接调 Python

Python 的全局解释器锁（GIL）保证*同一时刻只有一个线程在执行 Python 字节码*。
对 Blender 的 C++ 代码来说，这条规则有两个方向的含义，都很实际。

*方向一：别在没拿锁的时候碰 Python 对象。* 从 TBB 工作线程、任务池回调、
渲染线程里调用任何 Python C API 都是未定义行为。正确做法有三种：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.5fr, 2.1fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*场景*], [*配对*], [*源码依据*]),
    [线程是"外来"的，没有 Python 线程状态],
    [`PyGILState_Ensure()` 与 `PyGILState_Release()`],
    [驱动表达式求值就是这条路，注意它是成对且带状态的
     （#src("source/blender/python/intern/bpy_driver.cc:376-390") 与
      `:569-570`）],
    [本来在 Python 调用栈里，中途要放开锁去做长活],
    [`BPy_BEGIN_ALLOW_THREADS` 与 `BPy_END_ALLOW_THREADS`],
    [宏定义在 #src("source/blender/python/BPY_extern.hh:52-59")，
     底层是 `PyEval_SaveThread()` 与 `PyEval_RestoreThread()`
     （#src("source/blender/python/generic/bpy_threads.cc:20-38")）],
    [需要 `Py_DECREF` 一个可能在别的线程释放的对象],
    [`BPY_DECREF()`],
    [函数注释明确写了它会先拿 GIL（#src("source/blender/python/BPY_extern.hh:99-103")），
     实现就是 `PyGILState_Ensure()` 夹住一次 `Py_DECREF`
     （#src("source/blender/python/intern/bpy_interface.cc:793-798")）],
  ),
  caption: [三条 GIL 规则与它们在源码里的落地方式。],
) <tbl-gil-rules>

*方向二：你在 C++ 里执行耗时任务之前，要主动把锁放掉。* 否则主线程以外的
Python 代码（尤其是驱动表达式）会全部堵住。Blender 自己在几个关键位置
就是这么做的：

- 依赖图求值。`deg_evaluate_on_refresh()` 一开始就放开 GIL，
  求值结束再收回（#src("source/blender/depsgraph/intern/eval/deg_eval.cc:440-443")
  与 #src("source/blender/depsgraph/intern/eval/deg_eval.cc:511-513")）。
  源码注释指向报告 #91046。
- 视口渲染。`space_view3d.cc:163` 的 `BPy_BEGIN_ALLOW_THREADS`
  意义相同：GPU 与 CPU 在画，别让 Python 代码白等着。
- 脚本主动触发的依赖图更新。`bpy.context.view_layer.update()` 最终走
  `rna_Depsgraph_update()`，它在调用 `BKE_scene_graph_update_tagged()`
  之前同样放开 GIL（#src("source/blender/makesrna/intern/rna_depsgraph.cc:294-311")）。

这带来一个必须写进脑子的后果：*依赖图求值期间的 Python 代码
可能在非主线程执行*。第 13 章 §13.3.5 的告警在这里有实际的操作含义 ——
在驱动的表达式里不要假设自己独占界面数据，也不要假设当前线程是主线程。

#pitfall[
  `bpy.app.debug` 这个布尔值在进程内*只有一个*。它的读写都不加锁，
  所以"用 `bpy.app.debug` 当开关来执行多线程代码"是不可靠的：
  线程 A 打开它、线程 B 读到它、主线程又关掉它，中间没有任何同步。
  调试开关要传递，请用显式的参数，而不是全局标志。
]

还有一个正在变化的前提值得知道：在 `WITH_PYTHON_SAFETY` 或类似的
安全构建下，Python 侧的一些检查会让 GIL 相关的成本变高。这就是为什么
性能测量必须用 Release 构建 —— 也再次说明"判断性能"与"定位问题"
要用两套构建目录。

=== 16.4.2 `BLI_task`：任务池与并行原语

先要弄清一件事：`BLI_task` 是一对文件，不是一个。

#figure(
  kind: table,
  table(
    columns: (1.15fr, 1.15fr, 2.6fr),
    inset: 5.5pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*文件*], [*API 风格*], [*其中有什么*]),
    [`source/blender/blenlib/BLI_task.h`],
    [C],
    [任务调度器 `BLI_task_scheduler_*`、任务池 `BLI_task_pool_*`、
     `BLI_task_parallel_range`、`BLI_task_graph_*`、`BLI_task_isolate`
     （#src("source/blender/blenlib/BLI_task.h:32") 起）],
    [`source/blender/blenlib/BLI_task.hh`],
    [C++（`blender::threading`）],
    [`parallel_for`、`parallel_for_aligned`、`parallel_reduce`、
     `parallel_invoke`、`isolate_task`、`memory_bandwidth_bound_task`],

  ),
  caption: [`BLI_task` 的两半。写 C++ 优先用 `.hh` 里的那一半。],
) <tbl-bli-task>

`BLI_task.hh` 的实现直接落在 TBB 上（#src("source/blender/blenlib/BLI_task.hh:11-19")），
但*不要把 TBB API 直接写进 Blender 代码*：`.hh` 这一层替你处理了两件事 ——
没有 TBB 时的退化路径，以及"这个范围太小，别调度"的判断。
第 10 章 §10.x 已给出使用范例，这里只讲约束。

*约束一：`grain_size` 不是可选项。* 它必须反映"一个子任务大约多少工作量"。
写太小，调度与同步开销吃掉收益；写太大，函数体会串行化。
判断依据是循环体内部做了多少计算，而不是循环多少遍。

*约束二：函数体必须是线程安全的。* 这是最常见的错误来源。具体地说：

- 不要在并行体内分配或释放内存（会争用分配器的锁）。需要临时缓冲区时，
  按子范围一次性分配，或在循环外分配。
- 不要在并行体内修改共享的 `Vector`、`Map`、`Set`。要么用
  `threading::parallel_reduce`，要么每个子范围写自己的输出数组再合并。
- 不要在并行体内调用 Blender 的求值接口。并行的是"数据计算"，
  不是"再求值一次依赖图"。

*约束三：注意隔离（isolation）。* 嵌套并行有一个反直觉的失败模式：
一个主任务在等待它的子任务时，调度器可能把*另一个*主任务塞进这个线程。
如果这时它持有锁，就会死锁；如果它依赖线程局部变量，就会数据损坏。
`BLI_task.h` 里对这件事讲得很清楚，并给出了正确的入口
`BLI_task_isolate()`（#src("source/blender/blenlib/BLI_task.h:332-362")），
C++ 侧的对应物是 `threading::isolate_task()`：
*在隔离区内，只允许执行同一隔离区里派生出来的子任务。*

#pitfall[
  但隔离本身也能造成死锁。`BLI_task.h` 的注释给了一个真实的案例：
  在隔离区 A 里派生任务、却在隔离区 B 里等待它，那个等待的线程
  永远无法自行执行那个任务。单线程时立刻死锁，多线程时如果所有线程
  都进入这个状态就一起死锁 —— 源码里点名了 #88598
  （#src("source/blender/blenlib/BLI_task.h:352-359")）。
  遇到"偶发卡死"，先怀疑线程、再怀疑算法：
  用 `-t 1` 执行一遍 —— 如果单线程也死锁，那是逻辑问题；
  只有多线程死锁，才往这里查。
]

=== 16.4.3 线程池的五种类型与 `-t` 的联动

任务池有五种形态，选错的后果是"以为并行、其实串行"或反之。

#figure(
  kind: table,
  table(
    columns: (6.1cm, 1fr),
    inset: 5.5pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*创建函数*], [*行为与典型用途*]),
    [`BLI_task_pool_create`],
    [立即开始执行：推入时可能就在当前线程处理。用于通用并行计算],
    [`BLI_task_pool_create_`#linebreak()`background`],
    [总在后台线程执行，绝不立即执行。用于不阻塞主线程的后台作业],
    [`BLI_task_pool_create_`#linebreak()`background_serial`],
    [一个接一个，可能换线程但绝不并行。用于有顺序依赖的后台作业],
    [`BLI_task_pool_create_suspended`],
    [直到 `work_and_wait` 才开始。用于"数据结构全部就绪后才能开始算"的场景],
    [`BLI_task_pool_create_no_threads`],
    [全部在当前线程执行。用于调试并发问题 ——
     `--debug-depsgraph-no-threads` 就是它],
  ),
  caption: [五种任务池（`BLI_task.h:68-94`）。依赖图求值用的是"挂起池 + 高优先级"，单线程调试时换成"无线程池"（`depsgraph/intern/eval/deg_eval.cc:409-416`）。],
) <tbl-task-pools>

有一条联动规则必须知道，它解释了"为什么我明明写了并行代码，`-t 1` 之后就全串行了"：

```cpp
/* source/blender/blenlib/intern/task_pool.cc:184（节选） */
this->use_threads = BLI_task_scheduler_num_threads() > 1 && type != TASK_POOL_NO_THREADS;
```

`BLI_task_scheduler_num_threads()` 的来源是
#src("source/blender/blenlib/intern/task_scheduler.cc:36-58")：
如果给了 `-t N`（`N > 0`），它会用一个 `tbb::global_control` 把 TBB 的
最大并行度限制成 `N`，并把这个数当作"线程数"报告出去；否则报告系统的
处理器数。所以 `-t 1` 不只是"串行求值"，它会*关掉所有任务池的并行*。

这对排查极有价值：*`-t 1` 是最干净的"是并发问题吗"判据*。
如果 `-t 1` 下问题消失，就去按 16.4.2 的三条约束逐项检查；
如果 `-t 1` 下问题依旧，那就与线程无关。

=== 16.4.4 内存：受保护分配器能帮你找到什么

Blender 的所有分配都走 #src("intern/guardedalloc/MEM_guardedalloc.h")
里的受保护分配器（guarded allocator）。它不是标准库的 `malloc` 包装 ——
它在每块内存的*头尾各放一段标记*，于是一部分越界写能在下次检查时被抓到。

前面 16.1.2 已经讲了怎么开启它。这里补充"开启之后能用什么"：

```cpp
/* intern/guardedalloc/MEM_guardedalloc.h:195-234（节选，示意） */
MEM_printmemlist_pydict();   /* 打印所有已分配块的名字与大小，Python 字典格式 */
MEM_printmemlist();          /* 打印所有已分配块 */
MEM_printmemlist_stats();    /* 打印内存使用统计 */
MEM_consistency_check();     /* 头尾标记还正确吗？返回 false 表示内存被写坏 */
MEM_get_memory_in_use();     /* 当前占用字节数 */
MEM_get_peak_memory();       /* 峰值占用，含 mmap 分配 */
```

还有一个只在 Debug 下存在的工具：`MEM_name_ptr_set()`
（#src("intern/guardedalloc/MEM_guardedalloc.h:241-250")）。它能给某块内存
*改一个更有意义的名字*。头文件里的使用场景说明值得照抄：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-tip.lighten(95%),
  stroke: (left: 2.6pt + c-tip, rest: 0.4pt + c-tip.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  一个经常被调用、名字却很笼统的分配函数发生了泄漏。
  在调用它的地方（那里有更多信息）把名字改成具体的 ——
  于是一眼就能看出*是哪一个调用点*在泄漏。
]

实际排查顺序：

```bash
$ ./bin/blender -b -X --debug-memory --debug-exit-on-error \
    --python-exit-code 1 --python repro.py
```

- 如果它*在错误处停下*，拿调试器看栈。`--debug-exit-on-error` 让错误
  变成 abort（#src("source/creator/creator_args.cc:1070-1074")），
  所以栈就是你想要的那一个。
- 如果它*执行完成但报告泄漏*，用 `MEM_printmemlist()` 或
  `MEM_printmemlist_pydict()` 看是谁没还。
- 如果怀疑是*性能*问题而不是正确性问题，*别用这套*：
  受保护分配器会显著变慢。这种情况用采样器，不要开内存调试。

关于"两种分配器"的一个硬约束：切换只能在*任何分配发生之前*完成。
这一点在头文件里写了两遍 —— `MEM_use_lockfree_allocator()`
的注释末尾（#src("intern/guardedalloc/MEM_guardedalloc.h:273")）
与 `MEM_use_guarded_allocator()` 的注释末尾
（#src("intern/guardedalloc/MEM_guardedalloc.h:284")）都是同一句话：
"The switch between allocator types can only happen before any allocation did happen."
这就是为什么 `--debug-memory` 必须在启动参数里，而不能中途由脚本打开 ——
`creator.cc` 那段早期 `argv` 扫描正是为此存在的。
顺带一提，这两种分配器的差别也在注释里写明了：快速版只统计分配次数与字节数、
不记录块的名字；受保护版给每次分配加锁并保留完整的分配块列表，
所以它*慢*，只适合调试。

#warn[
  `WITH_MEM_VALGRIND` 与 `WITH_COMPILER_ASAN` 是*互斥*的：
  #src("CMakeLists.txt:993-994") 用 `set_and_warn_incompatible` 显式声明了
  这一点。想用 ASAN 就别开 Valgrind 支持，反之亦然。
  另外 `WITH_COMPILER_ASAN` 只作用于 `Debug` 与 `RelWithDebInfo`
  两个构建类型（#src("CMakeLists.txt:980-983") 的选项说明），
  在 `Release` 下打开它不会有任何效果。
]

=== 16.4.5 内存与线程的交叉陷阱

最后把两个主题交叉起来，列出自查清单。这些都是在实际排查里最容易
浪费半天的情形：

- *引用计数的原子性。* 在渲染或依赖图的工作线程里读写引用计数，
  必须用原子操作。看到"偶发的 use-after-free"，先检查这里。
- *线程局部缓存与 `-t 1`。* 有些缓存按线程建立。`-t 1` 时只有一个线程，
  缓存行为与多线程时不同，于是问题在调试时消失。
  *这不是"问题解决了"，这是问题被隐藏了。*
- *释放内存的线程与分配它的线程不同。* 受保护分配器本身能处理，
  但你自己写的池分配器未必。
- *在并行体内调用会记录日志的代码。* `CLOG_*` 内部有锁，
  高频日志在并行体内会变成串行瓶颈 —— 这既影响性能，也会让
  你测出的"并行加速比"偏低。
#exercise[
  *练习 16.4* 找一个你自己写的并行循环，把它改成
  `threading::parallel_for`，并按要求给一个合理的 `grain_size`。
  然后用 `-t 1` 与默认线程数各执行一次，证明并行确实带来了加速；
  如果没加速，用 16.3.3 的三个前提逐条排查。

  *练习 16.5* 故意制造一次越界写（例如对 `MEM_new_uninitialized(n, "x")`
  得到的缓冲区多写 8 字节，用完记得用 `MEM_delete_void()` 释放），
  然后用 `--debug-memory` 执行。你得到的是立即报错
  还是延迟报错？为什么？提示：看头文件里"头尾标记"这句话。

  *练习 16.6* 用 `--log "bpy.*" --log-show-source` 启动 Blender 并执行
  一个简单的 Python 脚本。你能在输出里看到你调用的那段 API 吗？
  把看到的类别与 16.1.1 那张表对照一下。

  *练习 16.7（综合）* 选一个你确实觉得慢的操作，走完本章的完整流程：
  （1）写出可重复的基线命令；（2）用 16.3.2 判断层级；
  （3）用对应工具拿到数字；（4）只做一处改动；
  （5）用交替测量证明改善；（6）执行 `make test` 证明功能未损坏。
  *把六步的中间数字都记下来* —— 这六步本身就是本章的交付物。
]
