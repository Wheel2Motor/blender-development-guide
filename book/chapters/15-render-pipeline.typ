#import "../common.typ": *
#import "../figures/render-pipeline.typ": fig-render-pipeline

= 第 15 章 渲染管线与引擎

第 13 章讲清楚了依赖图怎么把场景算成"一份可以被读的求值数据"，
第 14 章讲了这份数据是怎么被修饰器和节点加工出来的。
本章要回答最后一个问题：*这份数据最终怎么变成一张图，写到磁盘上或画到屏幕上。*

这个问题比看上去复杂，因为"渲染"在 Blender 里不是一个引擎，而是一个*框架*。
框架负责的是一堆与具体算法无关的事情：解析相机、决定分辨率、建立一份
只用于渲染的依赖图、切分视图层、管理渲染通道、合并分块结果、
调用合成器、写文件、给界面报告进度、随时响应"取消"。
而真正的像素计算则被外包给一个 #term("渲染引擎", "render engine") ——
可能是内置的 EEVEE 或 Workbench，也可能像 Cycles 一样由 Python 层完成注册、
由原生模块承担核心计算，还可以是你自己实现的 Python 或 C++ 引擎。

本章的核心认识就是这一句话：

#block(
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 3pt,
  fill: c-part.lighten(95%),
  stroke: (left: 2.6pt + c-part, rest: 0.4pt + c-part.lighten(40%)),
)[
  #set par(first-line-indent: 0em)
  `source/blender/render/` 是*框架*，它只提供两个扩展点：
  一个 `RenderEngineType` 结构体（引擎类型），
  和一个 `RenderEngine` 结构体（引擎实例）。
  除此之外的一切 —— 光线怎么追踪、阴影怎么算、采样怎么收敛 ——
  都不在这个目录里。
]

#figure(fig-render-pipeline(), caption: [渲染管线：场景 → 求值 → 引擎 → 合成 → 输出。
  上半是五个阶段的推进顺序，下半分别展开每个阶段内部的关键调用、
  引擎分支的判定条件，以及分块渲染的机制。]) <fig-render-pipeline>

== 15.1 渲染数据与依赖图（`RE_`）

=== 15.1.1 目录布局与「为什么是 `.h`」

`source/blender/render/` 的结构和本书前面讲过的目录都不一样，值得先看一眼：

#figure(
  kind: table,
  table(
    columns: (1.6fr, 2.9fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*路径*], [*内容*]),
    [#src("source/blender/render/")],
    [`RE_` 公开头文件。*后缀是 `.h` 而不是 `.hh`*],
    [#src("source/blender/render/intern/")],
    [实现。这里是 `.cc`，并且*随实现一起的私有头也用 `.h`*，
     例如 #src("source/blender/render/intern/render_types.h")],
    [#src("source/blender/render/RE_pipeline.h")],
    [管线主入口：`RE_RenderFrame()`、`RE_InitState()`、`RenderResult` 家族],
    [#src("source/blender/render/RE_engine.h")],
    [引擎接口：`RenderEngineType`、`RenderEngine`、`R_engines`],
    [#src("source/blender/render/RE_bake.h")],
    [烘焙接口：`BakeTargets`、`BakePixel`],
    [#src("source/blender/render/RE_texture.h")],
    [旧纹理求值接口。注释自称 "still old cruft here"],
    [#src("source/blender/render/RE_compositor.hh")],
    [合成器桥接。*这一份是 `.hh`*],
  ),
  caption: [`render/` 目录的布局。后缀不一致不是笔误，`.h` 是历史遗留。],
) <tbl-render-layout>

#warn[
  *`render/` 里既有 `.h` 也有 `.hh`，这与本书其它目录的惯例不同。*
  写 `#include` 时不要凭习惯补成 `.hh`：
  `#include "RE_pipeline.hh"` 会直接编译失败。
  反过来，`RE_compositor.hh` 确实是双 `h`。
  唯一可靠的办法是去目录里看一眼（或者让 IDE 补全）。
]

=== 15.1.1.1 四个层次的数据结构

管线的数据被分成四层，名字很像，容易混淆。先把它们摆清楚：

#figure(
  kind: table,
  table(
    columns: (1.2fr, 1.5fr, 2.2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*层*], [*结构体*], [*含义*]),
    [一次渲染],
    [`Render`],
    [整个渲染任务的运行时状态。有场景、依赖图、引擎实例、
     窗口尺寸、显示回调。*不存盘，一次渲染一份*。
     定义在 #src("source/blender/render/intern/render_types.h:118")],
    [一个视图层的结果],
    [`RenderLayer`],
    [一次渲染里每个视图层一份结果，含全部渲染通道。
     定义在 #src("source/blender/render/RE_pipeline.h:90")],
    [一个通道],
    [`RenderPass`],
    [`RenderLayer` 里的一个数据通道，例如 Combined、Depth、Normal。
     定义在 #src("source/blender/render/RE_pipeline.h:57")],
    [渲染结果容器],
    [`RenderResult`],
    [持有若干 `RenderLayer` 与若干 `RenderView`（多视图）。
     定义在 #src("source/blender/render/RE_pipeline.h:102")],
  ),
  caption: [渲染数据的四个层次。`Render` 是"任务"，其余三个都是"结果"。],
) <tbl-render-data-layers>

`Render` 的关键字段（#src("source/blender/render/intern/render_types.h:118") 起）：

```c
/* source/blender/render/intern/render_types.h:170（节选） */
  /* main, scene, and its full copy of renderdata and world */
  struct Main *main = nullptr;
  Scene *scene = nullptr;
  RenderData r = {};
  char single_view_layer[MAX_NAME] = "";
  struct Object *camera_override = nullptr;

  render::TilesHighlight tile_highlight;

  /* NOTE: This is a minimal dependency graph and evaluated scene which is enough to access view
   * layer visibility and use for postprocessing (compositor and sequencer). */
  struct Depsgraph *pipeline_depsgraph = nullptr;
  Scene *pipeline_scene_eval = nullptr;
```

三点：

- *`r` 是 `RenderData` 的*值拷贝*，不是指针*。
  `RenderData` 是场景里那份渲染设置（分辨率、帧率、输出格式……）。
  拷贝一份的原因是：*渲染过程中用户可以继续改场景，但这一次渲染必须用
  一开始的设置完成*。快照本体就写在
  #src("source/blender/render/intern/pipeline.cc:1948")
  （`RenderData rd = dna::shallow_copy(scene->r);`；同函数里
  "Ugly global still..." 那段注释讲的是 `G.is_rendering`，
  见 §15.1.2 第 2 步）。
- *`pipeline_depsgraph` 是渲染专用的依赖图*，用 `DAG_EVAL_RENDER` 模式建，
  与界面用的那份不同。见 §15.1.3。
- *`tile_highlight` 是分块高亮的缓存*，只在界面渲染时用。见 §15.2.5。

=== 15.1.1.2 `RenderResult`：为什么它是链表套链表

```c
/* source/blender/render/RE_pipeline.h:102（节选） */
struct RenderResult {
  struct RenderResult *next = nullptr, *prev = nullptr;

  int user_counter = 0;

  /* target image size */
  int rectx = 0, recty = 0;

  struct ImBuf *ibuf = nullptr;

  /* coordinates within final image (after cropping) */
  rcti tilerect;

  /* the main buffers */
  ListBaseT<RenderLayer> layers = {};

  /* multiView maps to a StringVector in OpenEXR */
  ListBaseT<RenderView> views = {};

  /* Render layer to display. */
  RenderLayer *renlay = nullptr;

  int framenr = 0;
  ...
};
```

结构是 `RenderResult` → `RenderLayer` → `RenderPass` 三级链表，
每一级都带自己的 `rectx` / `recty`。这个设计有两个直接后果：

1. *一个渲染结果可以同时容纳多个视图层、每个视图层多个通道*，
   而界面上显示的只是其中一层（`renlay`）。
   所以 `renlay` 的注释才会写 "Render layer to display"。
2. *分块渲染天然可表达*：一个"块"就是一个 `RenderResult`，
   它的 `tilerect` 说明自己该贴在整图的什么位置
   （见 §15.2.5 与@fig-render-pipeline 的第 ④ 部分）。

`RenderPass` 里数据本身的存储是惰性的：

```c
/* source/blender/render/RE_pipeline.h:57（节选） */
struct RenderPass {
  struct RenderPass *next, *prev;
  int channels;
  char name[/*EXR_PASS_MAXNAME*/ 64];
  char chan_id[/*EXR_PASS_MAXCHAN*/ 24];

  /*
   * Image buffer which contains data of this pass.
   *
   * The data can be either CPU side stored in ibuf->float_buffer, or a GPU-side stored in
   * ibuf->gpu (during rendering, i.e.).
   *
   * The pass data storage is lazily allocated, and until data is actually provided
   * (via either CPU buffer of GPU texture) the ibuf is not allocated.
   */
  struct ImBuf *ibuf;

  int rectx, recty;
  ...
};
```

*惰性分配*是性能设计：一个渲染可能有几十个通道（AOV、Cryptomatte、
Denoising Normal……），全部分配会瞬间吃掉大量内存。
只有引擎真正写了数据的通道才会拿到 `ImBuf`。
配合 `RenderResult::passes_allocated` 这一位
（#src("source/blender/render/RE_pipeline.h:156")），
引擎可以"先声明有哪些通道，稍后再写像素"。

=== 15.1.2 视图层与渲染通道

#term("视图层", "view layer") 是"一次渲染里的独立图层"。
它不是一个纯 UI 概念 —— `ViewLayer` 是 DNA 结构
（#src("source/blender/makesdna/DNA_layer_types.h:242")），会存进 `.blend`：

```c
/* source/blender/makesdna/DNA_layer_types.h:242（节选） */
struct ViewLayer {
  struct ViewLayer *next = nullptr, *prev = nullptr;
  char name[/*MAX_NAME*/ 64] = "";
  eViewLayer_Flag flag = VIEW_LAYER_RENDER | VIEW_LAYER_FREESTYLE;
  ...
  ListBaseT<Base> object_bases = {nullptr, nullptr};
  ...
  /* Old SceneRenderLayer data. */
  int layflag = SCE_LAY_FLAG_DEFAULT;
  /* Pass_xor has to be after passflag. */
  int passflag = SCE_PASS_COMBINED;
  ...
  int samples = 0;

  struct Material *mat_override = nullptr;
  struct World *world_override = nullptr;
  ...
};
```

视图层决定了四件事：

- *哪些物体参与*（`object_bases` 里的可见性标记，也就是界面上的"漏斗"图标）；
- *哪些通道被渲染*（`passflag` / `pass_xor`）；
- *有多少采样*（`samples`，覆盖场景设置）；
- *材质与世界是否被替换*（`mat_override` / `world_override`）。

`pass_xor` 紧跟在 `passflag` 后面，注释明确说 "Pass_xor has to be after
passflag"（#src("source/blender/makesdna/DNA_layer_types.h:260")）——
因为存盘代码把这两个 `int` 当成一个 64 位掩码一次性读写。

引擎看到的视图层列表由宏 `FOREACH_VIEW_LAYER_TO_RENDER_BEGIN`
遍历（#src("source/blender/render/intern/engine.cc:1097")）：

```cpp
/* source/blender/render/intern/engine.cc:1093（节选） */
  /* Render view layers. */
  bool delay_grease_pencil = false;

  if (type->render) {
    FOREACH_VIEW_LAYER_TO_RENDER_BEGIN (re, view_layer_iter) {
      CLOG_INFO(&LOG, "Start rendering: %s, %s", re->scene->id.name + 2, view_layer_iter->name);
      CLOG_INFO(&LOG, "Engine: %s", engine->type->name);
      const bool use_grease_pencil = (view_layer_iter->layflag & SCE_LAY_GREASE_PENCIL) != 0;
      engine_render_view_layer(re, engine, view_layer_iter, true, use_grease_pencil);

      /* If render passes are not allocated the render engine deferred final pixels write for
       * later. ... */
      delay_grease_pencil = use_grease_pencil && engine->has_grease_pencil &&
                            !re->result->passes_allocated;

      if (RE_engine_test_break(engine)) {
        break;
      }
    }
    FOREACH_VIEW_LAYER_TO_RENDER_END;
  }
```

*这段代码回答了一个常见疑问：为什么一个视图层只能有一个渲染引擎？*
因为引擎实例在循环外面创建一次（`engine = re->engine`），
循环里只是反复用它渲染不同的视图层。
引擎自己负责在每次 `render()` 回调里区分"现在在渲哪一层"。

=== 15.1.3 渲染专用的依赖图

渲染开始前，管线会建一份*独立的*依赖图
（#src("source/blender/render/intern/pipeline.cc:1886")）：

```cpp
/* source/blender/render/intern/pipeline.cc:1886 */
static void render_init_depsgraph(Render *re)
{
  Scene *scene = re->scene;
  ViewLayer *view_layer = BKE_view_layer_default_render(re->scene);

  re->pipeline_depsgraph = DEG_graph_new(re->main, scene, view_layer, DAG_EVAL_RENDER);
  DEG_debug_name_set(re->pipeline_depsgraph, "RENDER PIPELINE");

  /* Make sure there is a correct evaluated scene pointer. */
  DEG_graph_build_for_render_pipeline(re->pipeline_depsgraph);

  /* Update immediately so we have proper evaluated scene. */
  render_update_depsgraph(re);

  re->pipeline_scene_eval = DEG_get_evaluated_scene(re->pipeline_depsgraph);
}
```

为什么必须另建一份？三个理由，每一个都能在代码里看到：

1. *求值模式不同*。第四个参数是 `DAG_EVAL_RENDER` 而不是 `DAG_EVAL_VIEWPORT`。
   回顾第 13 章：修饰器的 `mode` 位里有 `eModifierMode_Render` 与
   `eModifierMode_Realtime` 两位，求值模式决定哪一位被检查。
   一个只在视图里可见的修饰器不该出现在最终渲染里，反之亦然。
2. *只建需要的东西*。`DEG_graph_build_for_render_pipeline()` 是"渲染专用构建"，
   它只包含渲染真正需要的组件（几何、变换、参数），
   不像界面依赖图那样要带上所有 UI 相关的关系。
   `render_types.h` 里的注释说得直白：
   "This is a *minimal* dependency graph"（#src("source/blender/render/intern/render_types.h:178")）。
3. *生命周期独立*。渲染结束后整图被释放
   （#src("source/blender/render/intern/pipeline.cc:1915")），
   不会污染用户当前在编辑的那个场景。

#tip[
  `DEG_debug_name_set()` 给图起了个名字 "RENDER PIPELINE"。
  这个名字会出现在 `--debug-depsgraph` 的输出里（第 13 章）。
  调试"为什么渲染结果和视口不一样"时，先确认你看的是哪一张图 ——
  两者不是同一份数据，这是设计如此，不是 bug。
]

== 15.2 帧渲染主流程与引擎调度

管线的主入口是 `RE_RenderFrame()`
（声明在 #src("source/blender/render/RE_pipeline.h:367")，
实现在 #src("source/blender/render/intern/pipeline.cc:1925")）。
它的参数就是"渲染一帧"所需的全部上下文：

```cpp
/* source/blender/render/RE_pipeline.h:358（注释原文 + 声明） */
/*
 * General Blender frame render call.
 *
 * \note Only #RE_NewRender() needed, main Blender render calls.
 *
 * \param write_still: Saves frames to disk (typically disabled). Useful for batch-operations
 * (e.g. rendering from Python) when an additional save action for is inconvenient.
 * This is the default behavior for #RE_RenderAnim.
 */
void RE_RenderFrame(struct Render *re,
                    struct Main *bmain,
                    struct Scene *scene,
                    struct ViewLayer *single_layer,
                    struct Object *camera_override,
                    int frame,
                    float subframe,
                    bool write_still);
```

实现的主干（#src("source/blender/render/intern/pipeline.cc:1925")）：

```cpp
/* source/blender/render/intern/pipeline.cc:1934（节选） */
  CLOG_INFO(&LOG, "Rendering frame %d", frame);

  render_callback_exec_id(re, re->main, &scene->id, BKE_CB_EVT_RENDER_INIT);

  G.is_rendering = true;

  scene->r.cfra = frame;
  scene->r.subframe = subframe;

  if (render_init_from_main(
          re, &scene->r, bmain, scene, single_layer, camera_override, false, false))
  {
    RenderData rd = dna::shallow_copy(scene->r);
    MEM_reset_peak_memory();

    render_callback_exec_id(re, re->main, &scene->id, BKE_CB_EVT_RENDER_PRE);

    /* Reduce GPU memory usage so renderer has more space. */
    RE_FreeGPUTextureCaches();

    render_init_depsgraph(re);

    do_render_full_pipeline(re);
    ...
  }
```

按顺序读下来，每一步都有明确目的：

1. *`BKE_CB_EVT_RENDER_INIT` 回调*。这是 Python 侧的 `bpy.app.handlers.render_init`。
   第 4 章讲过 handler 机制，这里是它在 C++ 侧的落点。
2. *`G.is_rendering = true`*。一个全局标志，界面用它来禁用某些操作、
   让细分曲面算全分辨率（源码注释称之为 "Ugly global still"）。
3. *写回 `frame` / `subframe`*。注意这是*写进场景*的。
   动画渲染时每一帧都会走到这里。
4. *`render_init_from_main()`*（#src("source/blender/render/intern/pipeline.cc:1798")）
   做初始化，其中会调 `RE_InitState()`
   （#src("source/blender/render/intern/pipeline.cc:785")）
   决定窗口尺寸、投影矩阵、渲染层列表。
5. *`dna::shallow_copy(scene->r)`*。这就是 §15.1.1.1 说的"快照"。
6. *`RE_FreeGPUTextureCaches()`*。渲染前先释放 GPU 纹理缓存，
   把显存让给引擎。这一行是后来加的优化，注释写明了原因。
7. *`render_init_depsgraph(re)`*。§15.1.3 那份图。
8. *`do_render_full_pipeline(re)`*。真正的分支发生在这里。
9. 之后是写文件、`BKE_CB_EVT_RENDER_POST` / `_WRITE` 回调、
   `render_pipeline_free()` 清理、`G.is_rendering = false`。

=== 15.2.1 三分支：`do_render_full_pipeline()` 的判定

这是整章的骨架（#src("source/blender/render/intern/pipeline.cc:1480")）：

```cpp
/* source/blender/render/intern/pipeline.cc:1479（节选） */
/* Render full pipeline, using render engine, sequencer and compositing nodes. */
static void do_render_full_pipeline(Render *re)
{
  bool render_seq = false;

  re->display->current_scene_update_cb(re->display->suh, re->scene);

  BKE_scene_camera_switch_update(re->scene);

  re->i.starttime = BLI_time_now_seconds();

  /* ensure no rendered results are cached from previous animated sequences */
  BKE_image_all_free_anim_ibufs(re->main, re->r.cfra);

  if (RE_engine_render(re, true)) {
    /* in this case external render overrides all */
  }
  else if (RE_seq_render_active(re->scene, &re->r)) {
    /* NOTE: do_render_sequencer() frees rect32 when sequencer returns float images. */
    if (!re->display->test_break()) {
      do_render_sequencer(re);
      render_seq = true;
    }

    re->display->stats_draw(&re->i);
    re->display->display_update(re->result, nullptr);
  }
  else {
    do_render_compositor(re);
  }
  ...
}
```

三个分支的优先级是*有意的*：

#figure(
  kind: table,
  table(
    columns: (0.5fr, 2.1fr, 1.5fr, 2.2fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*序*], [*条件*], [*做什么*], [*为什么在这个位置*]),
    [1],
    [`RE_engine_render(re, true)` 返回真],
    [完全交给外部引擎],
    [注释原文："in this case external render overrides all"。
     外部引擎（Cycles、Octane、自己写的）理应控制全部流程，
     包括它自己的合成与写盘],
    [2],
    [`RE_seq_render_active(scene, &r)`],
    [`do_render_sequencer(re)`],
    [序列器激活时，渲染结果就是剪辑输出，
     不该再被节点树加工一遍],
    [3],
    [以上都不成立],
    [`do_render_compositor(re)`],
    [这是默认路径。*注意它会按需回头调用 `do_render_engine()`*，
     见 §15.5],
  ),
  caption: [`do_render_full_pipeline()` 的三个分支及其优先级。],
) <tbl-pipeline-branches>

`RE_engine_render()` 的返回值语义值得单独说清楚
（#src("source/blender/render/intern/engine.cc:1003")）：

```cpp
/* source/blender/render/intern/engine.cc:1003（节选） */
bool RE_engine_render(Render *re, bool do_all)
{
  RenderEngineType *type = RE_engines_find(re->r.engine);

  /* verify if we can render */
  if (!type->render) {
    return false;
  }
  if ((re->r.scemode & R_BUTS_PREVIEW) && !(type->flag & RE_USE_PREVIEW)) {
    return false;
  }
  if (do_all && !(type->flag & RE_USE_POSTPROCESS)) {
    return false;
  }
  if (!do_all && (type->flag & RE_USE_POSTPROCESS)) {
    return false;
  }
  ...
}
```

*返回 `false` 的意思不是"渲染失败"，而是"这个引擎不接管全流程"。*
判定条件只有四条，全是标志位的组合：

- `type->render == nullptr`：引擎没实现渲染回调（只做视口预览的引擎就是这样）。
- 预览渲染但引擎不支持预览（缺 `RE_USE_PREVIEW`）。
- `do_all == true` 但引擎声明"我还要走后处理"（缺 `RE_USE_POSTPROCESS`）。
- `do_all == false` 但引擎声明"我要接管后处理"（有 `RE_USE_POSTPROCESS`）。

最后两条是一对：`do_all` 表示"这一次调用要不要负责到最终图像"。
`do_render_full_pipeline()` 传 `true`（要负责到底），
`do_render_engine()` 传 `false`（只出原始层，后处理交给框架）。

#figure(
  kind: table,
  table(
    columns: (2.1fr, 2.6fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*`RenderEngineTypeFlag`*], [*含义*]),
    [`RE_INTERNAL`], [内置引擎。退出时*不*释放（静态存储期对象）],
    [`RE_USE_PREVIEW`], [支持材质 / 纹理预览渲染],
    [`RE_USE_POSTPROCESS`], [引擎自己负责后处理，框架不再走合成器],
    [`RE_USE_EEVEE_VIEWPORT`], [视口用 EEVEE 而不是自己的 `view_draw`],
    [`RE_USE_SHADING_NODES_CUSTOM`], [自己处理着色节点，
     也就是"这个引擎的材质是它自己解释的"],
    [`RE_USE_SPHERICAL_STEREO`], [支持球面立体（全景）],
    [`RE_USE_STEREO_VIEWPORT`], [视口支持立体],
    [`RE_USE_GPU_CONTEXT`], [需要一个 GPU 上下文，
     框架会在调用前后 `DRW_render_context_enable/disable`],
    [`RE_USE_CUSTOM_FREESTYLE`], [自己处理 Freestyle],
    [`RE_USE_NO_IMAGE_SAVE`], [不让框架写图片文件。`bl_use_image_save`
      是它的*负向*映射，而且 UI 上的限制是"只在 `bl_use_postprocess`
      也被关闭时支持"—— 也就是要求 `RE_USE_POSTPROCESS` *被置上*
      （#src("source/blender/makesrna/intern/rna_render.cc:957-965")）],
    [`RE_USE_MATERIALX`], [支持 MaterialX 导出],
  ),
  caption: [`RenderEngineTypeFlag` 的全部取值
   （#src("source/blender/render/RE_engine.h:44")）。],
) <tbl-engine-flags>

=== 15.2.2 引擎实例的创建与视图层循环

回到 `RE_engine_render()` 的主体。引擎实例是在这里懒创建的
（#src("source/blender/render/intern/engine.cc:1032")）：

```cpp
/* source/blender/render/intern/engine.cc:1032（节选） */
  /* Create engine. */
  RenderEngine *engine = re->engine;

  if (!engine) {
    engine = RE_engine_create(type);
    re->engine = engine;
  }

  /* Create render result. Do this before acquiring lock, to avoid lock
   * inversion as this calls python to get the render passes, while python UI
   * code can also hold a lock on the render result. */
  const bool create_new_result = (re->result == nullptr || !(re->r.scemode & R_BUTS_PREVIEW));
  RenderResult *new_result = (create_new_result) ? engine_render_create_result(re) : nullptr;
  ...
```

那段注释是一手材料，说明了一个真实的死锁场景：
*创建渲染结果时会调用 Python 来枚举渲染通道
（`update_render_passes` 回调可以来自 Python），
而 Python 侧的 UI 代码可能正持有渲染结果的锁*。
所以顺序被刻意调整成"先建结果，再拿锁"。

然后进入视图层循环（§15.1.2 已经引过），
每个视图层调一次 `engine_render_view_layer()`
（#src("source/blender/render/intern/engine.cc:872")）。
这个函数的骨架是：

```cpp
/* source/blender/render/intern/engine.cc:878（节选） */
  /* Lock UI so scene can't be edited while we read from it in this render thread. */
  re->display->draw_lock();
  ...
  /* Sync data to engine, within draw lock so scene data can be accessed safely. */
  if (use_engine) {
    const bool use_gpu_context = (engine->type->flag & RE_USE_GPU_CONTEXT);
    if (use_gpu_context) {
      DRW_render_context_enable(engine->re);
    }
    ...
    if (engine->type->update) {
      engine->type->update(engine, re->main, engine->depsgraph);
    }
    ...
  }

  re->display->draw_unlock();

  /* Perform render with engine. */
  if (use_engine) {
    ...
    BLI_mutex_lock(&engine->re->engine_draw_mutex);
    re->engine->flag |= RE_ENGINE_CAN_DRAW;
    BLI_mutex_unlock(&engine->re->engine_draw_mutex);

    engine->type->render(engine, engine->depsgraph);

    BLI_mutex_lock(&engine->re->engine_draw_mutex);
    re->engine->flag &= ~RE_ENGINE_CAN_DRAW;
    BLI_mutex_unlock(&engine->re->engine_draw_mutex);
    ...
  }
```

这里有三个必须理解的机制：

*第一，`draw_lock` 锁的是界面绘制。*
`re->display->draw_lock()` 锁住界面绘制，目的是"防止用户在引擎读场景数据时
改动场景"。所以引擎的 `update()` 回调在锁内执行，
而 `render()` 回调在锁外执行 —— 后者可能耗时几分钟，
不能一直霸占界面。

*第二，`RE_ENGINE_CAN_DRAW` 标志控制绘制时机。*
它在 `render()` 调用前后被置位与清除。
引擎（或它启动的线程）检查这个标志来判断"现在能不能往渲染结果里画东西"。
配套的接口是 `RE_engine_draw_acquire()` / `RE_engine_draw_release()`
（#src("source/blender/render/RE_engine.h:256")），
注释写明："Drawing is possible if the engine has the `draw()` callback
and it is in its `render()` callback"。

*第三，GPU 上下文的开关是框架的事。*
如果引擎声明了 `RE_USE_GPU_CONTEXT`，框架会在调 `update` / `render` 前
`DRW_render_context_enable()`，调完 `DRW_render_context_disable()`。
引擎不需要自己管理主上下文 —— 这一点对后台渲染尤其重要，
因为后台渲染时 Blender 本来没有窗口上下文。

#note[
  第 15.1.4.2 节这几段是"框架与引擎的契约"最集中的地方。
  自己写引擎时最容易出错的两个地方都在这里：
  *在 `render()` 里改场景数据*（锁已经放开，会与界面线程竞争），
  以及 *忘记请求 `RE_USE_GPU_CONTEXT` 却直接用 GPU API*（空指针崩溃）。
]

=== 15.2.3 引擎注册表与回退

引擎类型列表是另一张简单的全局链表
（#src("source/blender/render/intern/engine.cc:59")）：

```cpp
/* source/blender/render/intern/engine.cc:59 */
ListBaseT<RenderEngineType> R_engines = {nullptr, nullptr};
```

它声明在 #src("source/blender/render/RE_engine.h:69")，
配套的操作函数一共五个
（#src("source/blender/render/RE_engine.h:275-280")）：
`RE_engines_init()`、`RE_engines_exit()`、`RE_engines_register()`、
`RE_engines_find()`、`RE_engines_is_registered()`。下面是其中两个：

```cpp
/* source/blender/render/intern/engine.cc:97（节选） */
void RE_engines_register(RenderEngineType *render_type)
{
  BLI_addtail(&R_engines, render_type);
}

RenderEngineType *RE_engines_find(const char *idname)
{
  RenderEngineType *type = static_cast<RenderEngineType *>(
      BLI_findstring(&R_engines, idname, offsetof(RenderEngineType, idname)));
  if (!type) {
    type = static_cast<RenderEngineType *>(
        BLI_findstring(&R_engines, "BLENDER_EEVEE", offsetof(RenderEngineType, idname)));
  }

  return type;
}
```

*`RE_engines_find()` 找不到时回退到 `"BLENDER_EEVEE"`，这个行为很重要。*
它意味着：删掉一个引擎的插件之后，用那个引擎的旧文件不会渲染失败，
而是静默换成 EEVEE。这是一个务实的决定 —— 总比打不开好 ——
但也意味着"我的场景渲出来是 EEVEE 的画面"这个症状的原因常常是
*引擎 idname 拼错了或者插件没启用*，而不是渲染设置被改过。
注意回退是硬编码字符串，没有用 `RE_engine_id_BLENDER_EEVEE` 常量。

内置引擎的注册发生在 `RE_engines_init()`
（#src("source/blender/render/intern/engine.cc:63")）：

```cpp
/* source/blender/render/intern/engine.cc:63 */
void RE_engines_init()
{
  DRW_engines_register();
  DRW_module_init();
}
```

*注意这里没有 EEVEE 的名字* —— 它被藏在 draw manager 里
（#src("source/blender/draw/intern/draw_context.cc:2281")）：

```cpp
/* source/blender/draw/intern/draw_context.cc:2281 */
void DRW_engines_register()
{
  RE_engines_register(&DRW_engine_viewport_eevee_type);
  RE_engines_register(&DRW_engine_viewport_workbench_type);
}
```

也就是说 *EEVEE 与 Workbench 这两个"渲染引擎"在源码里是 draw manager 的一部分*，
它们同时承担视口绘制与最终渲染两种角色。
这一点解释了 §15.4 会看到的现象：EEVEE 的渲染代码在
`draw/engines/eevee/` 而它的 `RenderEngineType` 也定义在那里。

=== 15.2.4 界面上的引擎列表是动态的

`Scene.render.engine` 这个 RNA 枚举的静态项表只有一项
（#src("source/blender/makesrna/intern/rna_scene.cc:6983")）：

```c
/* source/blender/makesrna/intern/rna_scene.cc:6983 */
  static const EnumPropertyItem engine_items[] = {
      {0, "BLENDER_EEVEE", 0, "EEVEE", ""},
      {0, nullptr, 0, nullptr, nullptr},
  };
```

*真正可用的引擎列表是运行时从 `R_engines` 生成的*
（#src("source/blender/makesrna/intern/rna_scene.cc:1860")）：

```c
/* source/blender/makesrna/intern/rna_scene.cc:1860（节选） */
static const EnumPropertyItem *rna_RenderSettings_engine_itemf(bContext * /*C*/,
                                                               PointerRNA * /*ptr*/,
                                                               PropertyRNA * /*prop*/,
                                                               bool *r_free)
{
  RenderEngineType *type;
  EnumPropertyItem *item = nullptr;
  EnumPropertyItem tmp = {0, "", 0, "", ""};
  int a = 0, totitem = 0;

  for (type = static_cast<RenderEngineType *>(R_engines.first); type; type = type->next, a++) {
    tmp.value = a;
    tmp.identifier = type->idname;
    tmp.name = type->name;
    RNA_enum_item_add(&item, &totitem, &tmp);
  }
  ...
}
```

*枚举的 `value` 是链表下标，不是任何持久化标识。*
所以 setter 必须把下标翻译回 idname
（#src("source/blender/makesrna/intern/rna_scene.cc:1849")）：

```c
/* source/blender/makesrna/intern/rna_scene.cc:1849 */
static void rna_RenderSettings_engine_set(PointerRNA *ptr, int value)
{
  RenderData *rd = static_cast<RenderData *>(ptr->data);
  RenderEngineType *type = static_cast<RenderEngineType *>(BLI_findlink(&R_engines, value));

  if (type) {
    STRNCPY_UTF8(rd->engine, type->idname);
    DEG_id_tag_update(ptr->owner_id, ID_RECALC_SYNC_TO_EVAL);
  }
}
```

*存盘的是 `idname` 字符串，不是下标*（`rd->engine` 是一个 `char[64]`）。
这是唯一稳定的做法 —— 链表顺序会随插件启用顺序变化。

内置的四个 idname 常量集中在一处
（#src("source/blender/blenkernel/intern/scene.cc:1675")）：

```c
/* source/blender/blenkernel/intern/scene.cc:1675 */
const char *RE_engine_id_BLENDER_EEVEE = "BLENDER_EEVEE";
const char *RE_engine_id_BLENDER_EEVEE_NEXT = "BLENDER_EEVEE_NEXT";
const char *RE_engine_id_BLENDER_WORKBENCH = "BLENDER_WORKBENCH";
const char *RE_engine_id_CYCLES = "CYCLES";
```

`BLENDER_EEVEE_NEXT` 的声明处（#src("source/blender/makesdna/DNA_scene_types.h:2944")）
有注释说明它"只用于版本升级"，是 4.2 到 5.0 过渡期的遗留。

=== 15.2.5 分块渲染

"分块"是渲染框架里最容易被误解的机制。常见误解是
"Blender 把图像切成固定大小的网格，一块一块渲染"。
5.2 的实际做法是：*框架提供分块的能力，切不切、怎么切由引擎决定*。

机制本身只有两个函数（#src("source/blender/render/RE_engine.h:186")）：

```c
/* source/blender/render/RE_engine.h:186（节选） */
struct RenderResult *RE_engine_begin_result(
    RenderEngine *engine, int x, int y, int w, int h, const char *layername, const char *viewname);
void RE_engine_update_result(RenderEngine *engine, struct RenderResult *result);
void RE_engine_add_pass(RenderEngine *engine,
                        const char *name,
                        int channels,
                        const char *chan_id,
                        const char *layername);
void RE_engine_end_result(RenderEngine *engine,
                          struct RenderResult *result,
                          bool cancel,
                          bool highlight,
                          bool merge_results);
```

`RE_engine_begin_result()` 的 `(x, y, w, h)` 就是这一块的坐标与尺寸。
它内部会把结果裁进整图范围，然后建一个带 `tilerect` 的 `RenderResult`
（#src("source/blender/render/intern/engine.cc:344")）：

```cpp
/* source/blender/render/intern/engine.cc:336（节选） */
  rcti disprect;

  /* ensure the coordinates are within the right limits */
  CLAMP(x, 0, re->result->rectx);
  CLAMP(y, 0, re->result->recty);
  CLAMP(w, 0, re->result->rectx);
  CLAMP(h, 0, re->result->recty);

  if (x + w > re->result->rectx) {
    w = re->result->rectx - x;
  }
  if (y + h > re->result->recty) {
    h = re->result->recty - y;
  }
  ...
  if (result) {
    render_result_clone_passes(re, result, viewname);
    render_result_passes_allocated_ensure(result);

    BLI_addtail(&engine->fullresult, result);

    result->tilerect.xmin += re->disprect.xmin;
    result->tilerect.xmax += re->disprect.xmin;
    result->tilerect.ymin += re->disprect.ymin;
    result->tilerect.ymax += re->disprect.ymin;
  }

  return result;
```

*注意最后四行把坐标平移了 `re->disprect` 的原点。*
因为 `disprect` 表示"整图里的哪一块区域正在被渲染"（边框渲染、
区域渲染等），块坐标是相对于这个子区域的。忘了这一步的结果是
"边框渲染时图像错位"。

`RE_engine_end_result()` 负责收尾与合并
（#src("source/blender/render/intern/engine.cc:421")）：

```cpp
/* source/blender/render/intern/engine.cc:439（节选） */
  if (re->engine && (re->engine->flag & RE_ENGINE_HIGHLIGHT_TILES)) {
    render::TilesHighlight *tile_highlight = re->get_tile_highlight();

    if (tile_highlight) {
      if (highlight) {
        tile_highlight->highlight_tile_for_result(result);
      }
      else {
        tile_highlight->unhighlight_tile_for_result(result);
      }
    }
  }

  if (!cancel || merge_results) {
    if (!(re->display->test_break() && (re->r.scemode & R_BUTS_PREVIEW))) {
      re_ensure_passes_allocated_thread_safe(re);
      render_result_merge(re->result, result);
    }
    ...
  }
```

四个参数各司其职：`cancel` 表示"这一块作废了"（比如用户取消），
`highlight` 控制界面上的方块高亮，`merge_results` 是
"即使 cancel 了也把已有内容合并进去"（用于"取消时保留已完成部分"）。

*`RE_ENGINE_HIGHLIGHT_TILES` 这个标志是引擎自己开的*，
表示"我会报告分块进度"。它对应 `RenderEngineFlag`
（#src("source/blender/render/RE_engine.h:59")）。
界面上的方块来自 `RE_engine_get_current_tiles()`
（#src("source/blender/render/intern/engine.cc:634")）：

```cpp
/* source/blender/render/intern/engine.cc:634（节选） */
const rcti *RE_engine_get_current_tiles(Render *re, int *r_total_tiles)
{
  render::TilesHighlight *tiles_highlight = re->get_tile_highlight();
  if (!tiles_highlight) {
    *r_total_tiles = 0;
    return nullptr;
  }

  Span<rcti> highlighted_tiles = tiles_highlight->get_all_highlighted_tiles();
  ...
  *r_total_tiles = highlighted_tiles.size();
  return highlighted_tiles.data();
}
```

高亮块的集合由一个专门的类维护
（#src("source/blender/render/intern/tile_highlight.cc")），
它同时维护一个去重的集合和一个缓存数组，只在集合变化时重建
（`did_tiles_change_` 标志，同文件:83）。因为界面每帧都会查询这个列表，
不去重会让渲染时的界面疯狂重绘。

#pitfall[
  分块渲染有一个容易搞混的地方：*`RE_engine_begin_result()` 返回的
  `RenderResult` 是你自己持有的对象*，它同时被挂进了 `engine->fullresult`
  链表（`BLI_addtail`）。所以*不要手工 `MEM_delete` 它*，
  必须走 `RE_engine_end_result()`。后者会把 `engine->fullresult`
  里的引用摘掉并释放。
  如果你 `begin` 了却从不 `end`，或者在 `end` 之后继续写它的像素，
  会分别导致内存泄漏与访问已释放内存。
]

=== 15.2.6 取消、进度与报告

渲染可能持续几十分钟，框架必须能被打断、能报告状态。
引擎侧的接口全在 #src("source/blender/render/RE_engine.h:216") 附近：

#figure(
  kind: table,
  table(
    columns: (2.4fr, 2.5fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*作用*]),
    [`RE_engine_test_break(engine)`], [查询"是否该退出"。默认实现与用户取消、
     共享内存不足等有关],
    [`RE_engine_update_stats(engine, stats, info)`],
    [更新状态栏文字（`info` 可为 `nullptr`）],
    [`RE_engine_update_progress(engine, progress)`], [更新进度条（0..1）],
    [`RE_engine_update_memory_stats(engine, used, peak)`], [更新内存统计],
    [`RE_engine_report(engine, type, msg)`],
    [给报告系统发一条消息（`RPT_ERROR` / `RPT_WARNING` / `RPT_INFO`）],
    [`RE_engine_set_error_message(engine, msg)`],
    [设置只显示在界面上的错误提示，不写入日志，
     也不阻止渲染完成],
    [`RE_engine_frame_set(engine, frame, subframe)`],
    [切换帧（在 `render()` 内被框架调用）],
    [`RE_engine_active_view_get(engine)`],
    [查询当前视图名（多视图渲染时用）],
  ),
  caption: [引擎可用的运行时接口。前四个是"渲染过程中的通信"，
   后几个是"帧与视图的上下文查询"。],
) <tbl-engine-runtime-api>

`RE_engine_set_error_message()` 与 `RE_engine_report()`
的区别值得强调：*前者只出现在界面，后者会进日志*。
源码在 `BKE_modifier_set_warning()` 那里也有同样的分工
（第 14 章）。EEVEE 用的就是前者
（#src("source/blender/draw/engines/eevee/eevee_instance.cc:717")），
把一长串着色器编译错误汇总成一句话给用户看。

取消的传播路径是单向的：
用户按 <kbd>Esc</kbd> → 界面设 `G.is_break` →
`RE_engine_test_break()` 返回真 → 引擎提前返回 →
`do_render_full_pipeline()` 里的 `test_break()` 检查生效 →
`RE_RenderFrame()` 末尾发 `BKE_CB_EVT_RENDER_CANCEL` 而不是 `_COMPLETE`
（#src("source/blender/render/intern/pipeline.cc:2000")）。

#figure(
  kind: table,
  table(
    columns: (1.4fr, 2.9fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*回调*], [*触发时机*]),
    [`BKE_CB_EVT_RENDER_INIT`], [`RE_RenderFrame()` 一开始],
    [`BKE_CB_EVT_RENDER_PRE`], [`render_init_from_main()` 成功之后、求值之前],
    [`BKE_CB_EVT_RENDER_POST`], [图像已写出之后],
    [`BKE_CB_EVT_RENDER_WRITE`], [仅当 `write_still` 为真时],
    [`BKE_CB_EVT_RENDER_CANCEL`], [被中断时（`G.is_break`）],
    [`BKE_CB_EVT_RENDER_COMPLETE`], [正常走完时],
  ),
  caption: [渲染相关的 `BKE_CB_EVT_*` 回调。Python 侧对应
   `bpy.app.handlers.render_*`。行号见 #src("source/blender/render/intern/pipeline.cc:1936") 起的调用序列。],
) <tbl-render-callbacks>

#summary[
  §15.1–§15.2 的要点：
  *`render/` 只提供框架，不提供算法*。它做的是快照设置、建渲染专用依赖图、
  遍历视图层、调用引擎回调、合并分块、执行合成器、写文件。
  *`do_render_full_pipeline()` 有三个分支*，优先级是
  外部引擎 → 序列器 → 合成器。
  *`RE_engine_render()` 返回 `false` 的意思是"我不接管全流程"，不是失败*。
  *分块由引擎自己决定*，框架只提供 `RE_engine_begin_result()` /
  `RE_engine_end_result()` 这对接口。
]

== 15.3 Cycles 概览

Cycles 在 Blender 源码里是一个"外来者"，理解它的组织方式比理解它的算法
更有价值 —— 因为它展示了一条*不用改一行 Blender C++ 就能接入渲染管线*的路径。

=== 15.3.1 它是插件，不是内置引擎

与 EEVEE / Workbench 不同，Cycles 是一个*addon*。它的构成有两部分：

#figure(
  kind: table,
  table(
    columns: (1.9fr, 1.3fr, 2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*部分*], [*源码位置*], [*构建产物*]),
    [Python 插件],
    [#src("intern/cycles/blender/addon/")],
    [`scripts/addons_core/cycles/`，
     由 #src("intern/cycles/CMakeLists.txt:14") 指定安装路径],
    [原生 Python 模块],
    [#src("intern/cycles/blender/")],
    [编译进 Blender 的 `_cycles` 扩展模块],
    [渲染内核],
    [其余 `intern/cycles/` 目录],
    [静态链接进 `_cycles` 模块],
  ),
  caption: [Cycles 的三部分。Python 部分负责接入 Blender，
   原生部分负责实际计算。],
) <tbl-cycles-parts>

原生模块的注册在 `bpy_internal_modules` 表里
（#src("source/blender/python/intern/bpy_interface.cc:320")）：

```cpp
/* source/blender/python/intern/bpy_interface.cc:307（节选） */
#ifdef WITH_CYCLES
/* Defined in `cycles` module. */
static PyObject *CCL_initPython()
{
  return (PyObject *)CCL_python_module_init();
}
#endif
...
static _inittab bpy_internal_modules[] = {
    ...
#ifdef WITH_CYCLES
    {"_cycles", CCL_initPython},
#endif
    ...
};
```

模块本身的名字在 #src("intern/cycles/blender/python.cpp:867") 定义：

```cpp
/* intern/cycles/blender/python.cpp:865 */
static struct PyModuleDef module = {
    /*m_base*/ PyModuleDef_HEAD_INIT,
    /*m_name*/ "_cycles",
    /*m_doc*/ "Blender cycles render integration",
    /*m_size*/ -1,
    /*m_methods*/ methods,
    /*m_slots*/ nullptr,
    /*m_traverse*/ nullptr,
    /*m_clear*/ nullptr,
    /*m_free*/ nullptr,
};
```

*这就是为什么 Cycles 不需要改 Blender 的核心代码就能成为渲染引擎*：
它用 Python 的 `RenderEngine` 基类注册自己（下一节），
而这个基类在 RNA 层是公开的。

它作为 addon 被启用的方式也与普通 addon 一样：
名字是 `"cycles"`，关掉 `WITH_CYCLES` 时会被从用户偏好里清掉
（#src("source/blender/windowmanager/intern/wm_files.cc:523")）：

```c
/* source/blender/windowmanager/intern/wm_files.cc:520（节选） */
static void wm_init_userdef(Main *bmain)
{
  /* Not versioning, just avoid errors. */
#ifndef WITH_CYCLES
  BKE_addon_remove_safe(&U.addons, "cycles");
#endif
```

=== 15.3.2 `RenderEngine` 的 Python 子类

接入点就是一段很短的 Python 代码（#src("intern/cycles/blender/addon/__init__.py:44")）：

```python
# intern/cycles/blender/addon/__init__.py:44（节选）
class CyclesRender(bpy.types.RenderEngine):
    bl_idname = 'CYCLES'
    bl_label = "Cycles"
    bl_use_eevee_viewport = True
    bl_use_preview = True
    bl_use_exclude_layers = True
    bl_use_spherical_stereo = True
    bl_use_custom_freestyle = True

    def __init__(self, *args, *kwargs):
        super().__init__(*args, *kwargs)
        self.session = None

    def __del__(self):
        engine.free(self)

    # final render
    def update(self, data, depsgraph):
        if not self.session:
            if self.is_preview:
                cscene = bpy.context.scene.cycles
                use_osl = cscene.shading_system

                engine.create(self, data, preview_osl=use_osl)
            else:
                engine.create(self, data)

        engine.reset(self, data, depsgraph)

    def render(self, depsgraph):
        engine.render(self, depsgraph)

    def render_frame_finish(self):
        engine.render_frame_finish(self)
    ...
```

*这个类的方法名与 `RenderEngineType` 的字段是一一对应的*：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.5fr, 2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*Python 方法*], [*C++ 字段*], [*`bl_use_*` 属性*]),
    [`update(data, depsgraph)`], [`update`], [—],
    [`render(depsgraph)`], [`render`], [—],
    [`render_frame_finish()`], [`render_frame_finish`], [—],
    [`draw(context, depsgraph)`], [`draw`], [—],
    [`bake(...)`], [`bake`], [—],
    [`view_update(context, depsgraph)`], [`view_update`], [`bl_use_eevee_viewport`],
    [`view_draw(context, depsgraph)`], [`view_draw`], [`bl_use_eevee_viewport`],
    [`update_script_node(node)`], [`update_script_node`], [`bl_use_shading_nodes_custom`],
    [`update_render_passes(scene, srl)`], [`update_render_passes`], [`bl_use_preview` / `bl_use_postprocess`],
    [`update_custom_camera(cam)`], [`update_custom_camera`], [`bl_use_custom_freestyle`],
  ),
  caption: [Python `RenderEngine` 方法、C++ `RenderEngineType` 字段、
   以及影响注册的标志属性三者对照。],
) <tbl-renderengine-python-mapping>

=== 15.3.3 注册是怎么发生的

Python 引擎的注册入口是 RNA 的 `register` 回调
（#src("source/blender/makesrna/intern/rna_render.cc:303")）：

```cpp
/* source/blender/makesrna/intern/rna_render.cc:303（节选） */
static StructRNA *rna_RenderEngine_register(Main *bmain,
                                            ReportList *reports,
                                            void *data,
                                            const char *identifier,
                                            StructValidateFunc validate,
                                            StructCallbackFunc call,
                                            StructFreeFunc free)
{
  ...
  /* validate the python class */
  if (validate(&dummy_engine_ptr, data, have_function) != 0) {
    return nullptr;
  }
  ...
  /* create a new engine type */
  et = MEM_new_uninitialized<RenderEngineType>("Python render engine");
  memcpy(et, &dummy_et, sizeof(dummy_et));

  et->rna_ext.srna = RNA_def_struct_ptr(&RNA_blender_rna_get(), et->idname, RNA_RenderEngine);
  et->rna_ext.data = data;
  et->rna_ext.call = call;
  et->rna_ext.free = free;
  RNA_struct_blender_type_set(et->rna_ext.srna, et);

  et->update = (have_function[0]) ? engine_update : nullptr;
  et->render = (have_function[1]) ? engine_render : nullptr;
  et->render_frame_finish = (have_function[2]) ? engine_render_frame_finish : nullptr;
  et->draw = (have_function[3]) ? engine_draw : nullptr;
  et->bake = (have_function[4]) ? engine_bake : nullptr;
  et->view_update = (have_function[5]) ? engine_view_update : nullptr;
  et->view_draw = (have_function[6]) ? engine_view_draw : nullptr;
  et->update_script_node = (have_function[7]) ? engine_update_script_node : nullptr;
  et->update_render_passes = (have_function[8]) ? engine_update_render_passes : nullptr;
  et->update_custom_camera = (have_function[9]) ? engine_update_custom_camera : nullptr;

  RE_engines_register(et);

  return et->rna_ext.srna;
}
```

*这四十行是整个"自定义渲染引擎"功能的全部机制。*
逐条读：

1. *先用一个 dummy 引擎执行 `validate`*。Python 类上声明的
   `bl_use_*` 属性会被写进 `dummy_et`（`dummy_engine.type = &dummy_et`）。
   这解释了为什么 §15.3.2 那些 `bl_use_* = True` 能生效。
2. *`have_function[]` 数组是"这个 Python 类实现了哪些方法"的位图*。
   只有实现了方法的槽位才会被填上 C++ 蹦床函数（trampoline）；
   没实现的保持 `nullptr`，于是 `RE_engine_render()` 的
   `if (!type->render) return false;` 就会正确地判定"这个引擎不接管全流程"。
3. *`idname` 来自 RNA 结构体标识符*，也就是 Python 的 `bl_idname`。
   长度检查在 #src("source/blender/makesrna/intern/rna_render.cc:327")，
   超过 64 字节直接报错。
4. *重复注册会先注销旧的*（同文件:337 起）。热重载 addon 时不会留下僵尸引擎。
5. *最后一行 `RE_engines_register(et)` 把它挂进 §15.2.3 那张链表*。

因此，*Cycles 出现在 `Scene.render.engine` 下拉框里的完整链条*是：

`CyclesRender` 类定义 → `bpy.utils.register_class(CyclesRender)` →
`rna_RenderEngine_register()` → `RE_engines_register()` →
`rna_RenderSettings_engine_itemf()` 遍历 `R_engines` 生成枚举项 → 下拉框。

#tip[
  这条链意味着：*你可以用同样的方式写一个纯 Python 引擎*，
  完全不用编译 Blender。当然，纯 Python 做光线追踪会非常慢 ——
  Cycles 的 Python 层只是壳，真正的计算在链接进 `_cycles` 的 C++ 里。
  但如果你想把渲染外包给一个外部程序（比如自己写的命令行渲染器），
  Python `RenderEngine` 是完全够用的：在 `render()` 里调
  `subprocess`，然后把结果通过 `engine.begin_result()` 交回来。
]

=== 15.3.4 Python 层与原生层的分界

Cycles 的 Python 层（#src("intern/cycles/blender/addon/engine.py")）
把每个回调转成对 `_cycles` 模块的调用。例如：

```python
# intern/cycles/blender/addon/engine.py:61（节选，示意）
def create(engine, data, region=None, v3d=None, rv3d=None, preview_osl=False):
    ...
```

原生侧的 `create_func` 从 Python 拿到一堆不透明指针，
再把它们转回 C++ 对象（#src("intern/cycles/blender/python.cpp:165")）：

```cpp
/* intern/cycles/blender/python.cpp:165（节选） */
static PyObject *create_func(PyObject * /*self*/, PyObject *args)
{
  PyObject *pyengine;
  PyObject *pypreferences;
  PyObject *pydata;
  PyObject *pyscreen;
  PyObject *pyregion;
  PyObject *pyv3d;
  PyObject *pyrv3d;
  int preview_osl;

  if (!PyArg_ParseTuple(args, "OOOOOOOi", &pyengine, &pypreferences, &pydata, ...))
  {
    return nullptr;
  }

  /* RNA */
  blender::ID *bScreen = (blender::ID *)PyLong_AsVoidPtr(pyscreen);

  blender::RenderEngine *engine = static_cast<blender::RenderEngine *>(PyLong_AsVoidPtr(pyengine));
  ...
```

*`PyLong_AsVoidPtr()` 这种"把指针塞进 Python int"的写法是 RNA 层的普遍做法*
（第 9 章讲过 RNA 指针的表示）。它不安全但快，而且这些指针只在
单次渲染会话内有效，生命周期由 Python 侧的对象持有。

#pitfall[
  这条分界有一个实际后果：*Cycles 的报错信息有一半来自 Python 层*。
  当你在控制台看到 `_cycles` 相关的 traceback 时，
  它可能是 Python 侧的接口不匹配（例如 Blender 版本升级后
  `bpy.types.RenderEngine` 的某个方法签名变了），
  而不是渲染内核出错。排查顺序应该是：
  先用纯 Python 引擎渲染一遍最小场景，确认框架侧没问题，
  再怀疑原生侧。
]

== 15.4 EEVEE 概览

EEVEE 与 Cycles 走的是完全不同的路线：*它是内置引擎，
而且是 draw manager 的一部分*。

=== 15.4.1 引擎结构体只有十几行

EEVEE 的 `RenderEngineType` 定义在
#src("source/blender/draw/engines/eevee/eevee_engine.cc:79")，
长度不到 25 行：

```cpp
/* source/blender/draw/engines/eevee/eevee_engine.cc:79 */
RenderEngineType DRW_engine_viewport_eevee_type = {
    /*next*/ nullptr,
    /*prev*/ nullptr,
    /*idname*/ "BLENDER_EEVEE",
    /*name*/ N_("EEVEE"),
    /*flag*/ RE_INTERNAL | RE_USE_PREVIEW | RE_USE_STEREO_VIEWPORT | RE_USE_GPU_CONTEXT,
    /*update*/ nullptr,
    /*render*/ &eevee_render,
    /*render_frame_finish*/ nullptr,
    /*draw*/ nullptr,
    /*bake*/ nullptr,
    /*view_update*/ nullptr,
    /*view_draw*/ nullptr,
    /*update_script_node*/ nullptr,
    /*update_render_passes*/ &eevee_render_update_passes,
    /*update_custom_camera*/ nullptr,
    /*draw_engine*/ nullptr,
    /*rna_ext*/
    {
        /*data*/ nullptr,
        /*srna*/ nullptr,
        /*call*/ nullptr,
    },
};
```

*这是本章最有价值的一段代码*，因为它把"一个引擎最少要实现什么"
压缩到了一眼能看完的程度：

- *只实现了两个回调*：`render` 与 `update_render_passes`。
  `update` 是 `nullptr`，`draw` 是 `nullptr`，`view_draw` 也是 `nullptr`。
- *`draw` 为空却能画视口*，靠的不是引擎自己的回调 —— 源码注释说得很直接：
  "all modes are done in the draw manager, except external render engines
  like Cycles"（#src("source/blender/editors/space_view3d/view3d_draw.cc:1641-1645")）。
  注意 EEVEE 的 `RenderEngineType` 里*并没有* `RE_USE_EEVEE_VIEWPORT`
  （看上面 `/*flag*/` 那一行），这个标志是*别的*引擎设的：Cycles 的 Python 侧
  把它打开（`bl_use_eevee_viewport = True`，
  #src("intern/cycles/blender/addon/__init__.py:47")），于是
  `ED_view3d_engine_type()` 在 `OB_MATERIAL`（材质预览）模式下改去取
  `RE_engine_id_BLENDER_EEVEE`（#src("source/blender/editors/space_view3d/view3d_draw.cc:1647-1649")）。
  换句话说：视口绘制走 draw manager 的主循环，不走引擎的 `draw` 回调；
  而 `RE_USE_EEVEE_VIEWPORT` 是"材质预览模式下把视口交给 EEVEE"的开关。
- *`RE_USE_GPU_CONTEXT` 是必须的*，因为它确实要用 GPU。
- *`RE_INTERNAL` 让退出时不被 `MEM_delete`*（见
  #src("source/blender/render/intern/engine.cc:87")）——
  这是一个静态存储期对象，删它才是错的。

对比 Workbench（#src("source/blender/draw/engines/workbench/workbench_engine.cc:799")），
差别只在标志位：Workbench 没有 `RE_USE_PREVIEW`，其余几乎一样。

=== 15.4.2 `eevee_render()`：三层套娃

EEVEE 的 `render` 回调只有三十几行，但里面有三次嵌套
（#src("source/blender/draw/engines/eevee/eevee_engine.cc:40")）：

```cpp
/* source/blender/draw/engines/eevee/eevee_engine.cc:40（节选） */
static void eevee_render(RenderEngine *engine, Depsgraph *depsgraph)
{
  Instance *instance = nullptr;

  auto eevee_render_to_image = [&](RenderEngine *engine, RenderLayer *layer, const rcti /*rect*/) {
    Render *render = engine->re;
    Object *camera_original_ob = RE_GetCamera(engine->re);
    const char *viewname = RE_GetActiveRenderView(engine->re);
    int size[2] = {engine->resolution_x, engine->resolution_y};

    /* Avoid leaking in the case of multiview. (see #145743) */
    delete instance;
    /* WORKAROUND: Fails if created in the parent scope. Must be because of lack of active
     * `DRWContext`. To be revisited. */
    instance = new Instance();

    rctf view_rect;
    rcti rect;
    RE_GetViewPlane(render, &view_rect, &rect);
    rcti visible_rect = rect;

    instance->init(size, &rect, &visible_rect, engine, depsgraph, camera_original_ob, layer);
    instance->render_frame(engine, layer, viewname);
  };

  auto eevee_store_metadata = [&](RenderResult *render_result) {
    instance->store_metadata(render_result);
  };

  DRW_render_to_image(engine, depsgraph, eevee_render_to_image, eevee_store_metadata);

  delete instance;
}
```

三层分别是：

1. *`DRW_render_to_image()` 是桥*。它把渲染框架的 `RenderEngine`
   接到 draw manager 的执行环境上（建 GPU 上下文、准备 DRW 上下文、
   遍历渲染层、准备 metadata 回调）。EEVEE 与 Workbench 都通过它
   （Workbench 见 #src("source/blender/draw/engines/workbench/workbench_engine.cc:796")）。
2. *`eevee_render_to_image` lambda 是"一层渲染"*。
   `DRW_render_to_image()` 会为每个渲染层调它一次。
   它干的事是 `new Instance()` 然后 `init()` + `render_frame()`。
3. *`Instance` 是 EEVEE 自己的引擎实例*
   （#src("source/blender/draw/engines/eevee/eevee_instance.hh:88")），
   继承自 `DrawEngine`。它有 `init()` / `render_sync()` /
   `render_frame()` / `render_sample()` 等方法。

*为什么要 `delete instance; instance = new Instance();`？*
注释写得很坦白：这是一个 workaround。
父作用域里创建的 `Instance` 会失败，因为那时还没有活动的 `DRWContext`；
必须等到 `DRW_render_to_image()` 的回调里才创建。
`delete` 那一行是为了多视图渲染时不泄漏。

#pitfall[
  *`Instance` 的构造时机不能随便挪。* 这段 workaround 代码在
  上游是有编号的 issue 与 TODO 的（注释里的 "To be revisited"）。
  如果你在改 EEVEE 时"顺手"把这个 lambda 改成共享一个 `Instance`，
  症状会是"多视图渲染时第二只眼睛是黑的"或者直接崩溃 ——
  因为 `DRWContext` 的生命周期与 `Instance` 绑定。
  这种"看起来可以清理、实际不能动"的代码在渲染相关代码里很多，
  动手前先读注释里的 issue 号。
]

=== 15.4.3 `render_frame()` 与采样循环

`Instance::render_frame()` 是采样循环所在
（#src("source/blender/draw/engines/eevee/eevee_instance.cc:659")）：

```cpp
/* source/blender/draw/engines/eevee/eevee_instance.cc:673（节选） */
  DebugScope debug_scope(debug_scope_render_frame, "EEVEE.render_frame");

  /* TODO: Break on RE_engine_test_break(engine) */
  while (!sampling.finished()) {
    this->render_sample();

    if ((sampling.sample_index() == 1) || ((sampling.sample_index() % 25) == 0) ||
        sampling.finished())
    {
      std::string re_info = "Rendering " + std::to_string(sampling.sample_index()) + " / " +
                            std::to_string(sampling.sample_count()) + " samples";
      RE_engine_update_stats(engine, nullptr, re_info.c_str());
    }
    ...
  }

  this->film.cryptomatte_sort();

  this->render_read_result(render_layer, view_name);
```

四个可读的细节：

- *进度更新不是每帧都做*，而是第 1 帧、每 25 帧、以及最后一帧。
  理由很实在：`RE_engine_update_stats()` 会触发界面重绘，
  每采样都调会把 CPU 全花在刷新界面上。
- *有一条 TODO 承认这里没有响应取消*
  （`TODO: Break on RE_engine_test_break(engine)`）。
  这是把第 15.1.7 节的"契约"与实现对照读的好处：
  框架提供了取消接口，但引擎可以选择不查。
- *`render_read_result()` 在循环之外*。所有采样累积完之后一次性读回。
  这是把 GPU 结果读回 CPU 内存的成本决定的 —— 每采样读一次会很慢。
- *`GPU_render_step()` 按后端分支*（同文件:690）。
  注释解释了为什么 Metal 与 Vulkan 需要它：
  避免一次性提交一个巨大的命令缓冲区导致显存爆掉或 TDR。
  *_TDR_ 是 Windows 显卡驱动的"超时检测与恢复"机制，
  一次提交太久会被驱动强制重置。* 这是平台差异在渲染代码里的典型体现。

=== 15.4.4 EEVEE 与视口

`Instance::draw_viewport()`（#src("source/blender/draw/engines/eevee/eevee_instance.cc:724")）
里的处理顺序能解释一个日常现象："切到材质预览时视口先黑一下然后慢慢出来"：

```cpp
/* source/blender/draw/engines/eevee/eevee_instance.cc:724（节选） */
void Instance::draw_viewport()
{
  if (skip_render_ || !is_loaded(needed_shaders)) {
    DefaultFramebufferList *dfbl = draw_ctx->viewport_framebuffer_list_get();
    GPU_framebuffer_clear_color_depth(dfbl->default_fb, double4(0.0), 1.0f);
    if (!is_loaded(needed_shaders & ~WORLD_SHADERS)) {
      info_append_i18n("Compiling EEVEE engine shaders");
      DRW_viewport_request_redraw();
    }
    ...
    return;
  }

  render_sample();
  ...
  /* Do not request redraw during viewport animation to lock the frame-rate to the animation
   * playback rate. ... */
  if (!sampling.finished_viewport() && !is_playback) {
    DRW_viewport_request_redraw();
  }
```

三点：

- *着色器没编译好时清屏并返回*。这就是"黑一下"。
  `info_append_i18n("Compiling EEVEE engine shaders")` 是那句提示文字的来源。
- *`DRW_viewport_request_redraw()` 主动请求重绘*。
  TAA（时域抗锯齿）需要连续多帧累积，所以 EEVEE 会一帧一帧地要求重画，
  直到 `sampling.finished_viewport()` 为真。
- *播放动画时故意不请求重绘*。注释给出了两个理由：
  锁住帧率以保持运动模糊正确，以及避免 TAA 重置导致闪烁。
  这是"性能优化"与"正确性"权衡后写进代码的典型例子。

#summary[
  §15.3 与 §15.4 的对比可以总结成一张表：

  *Cycles*：插件 + Python `RenderEngine` 子类 + 原生模块。
  接入路径完全走 RNA，*不需要改 Blender 一行 C++*（除了把 `_cycles`
  注册成内置模块）。代价是每次跨语言调用都有开销，
  所以 Python 层被写得极薄。

  *EEVEE*：内置引擎，是 draw manager 的一部分。
  `RenderEngineType` 结构体只有两个非空回调，
  真正的实现在一个继承 `DrawEngine` 的 `Instance` 类里。
  它同时服务视口与最终渲染，所以 `draw_viewport()` 与
  `render_frame()` 是两条并行的代码路径。

  两者共同说明了一件事：*框架只要求一个结构体和几个回调*。
  剩下的全是自由。
]

== 15.5 合成器

合成器在管线里的位置是"引擎之后、写盘之前"（@fig-render-pipeline 的第 ④ 阶段）。
它的职责是把渲染结果当作输入，执行一遍节点树，产出最终图像。

=== 15.5.1 两个合成器

首先要区分两个同名但完全不相关的东西：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.8fr, 2.2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*名称*], [*位置*], [*触发时机*]),
    [渲染合成器],
    [#src("source/blender/render/intern/compositor.cc")],
    [`RE_compositor_execute()`，由管线在引擎之后调用],
    [视口合成器],
    [#src("source/blender/compositor/")],
    [由 draw manager 在每个视图层绘制时执行，
     用于"视口合成"开关打开时],
  ),
  caption: [两个合成器。本章只讲渲染合成器（`RE_compositor_execute`）],
) <tbl-two-compositors>

接口非常小，只有一个头文件：
#src("source/blender/render/RE_compositor.hh")，全文 46 行。

```cpp
/* source/blender/render/RE_compositor.hh:22（节选；分隔线已缩短） */
/* ------------------------------------------------------------------------
 * Render Compositor
 *
 * Implementation of the compositor for final rendering, as opposed to the viewport compositor
 * that is part of the draw manager. The input and output of this is pre-existing RenderResult
 * buffers in scenes, that are uploaded to and read back from the GPU. */

/* Execute compositor. */
void RE_compositor_execute(Render &render,
                           const Main &main,
                           const Scene &scene,
                           const RenderData &render_data,
                           const bNodeTree &node_tree,
                           const char *view_name,
                           compositor::RenderContext *render_context,
                           compositor::NodeGroupOutputTypes needed_outputs);

/* Free compositor caches. */
void RE_compositor_free(Render &render);
```

*注释里那一句是关键*："The input and output of this is pre-existing
`RenderResult` buffers in scenes, that are *uploaded to and read back from the GPU*."
也就是说：*渲染合成器是 GPU 实现*，它把 `RenderResult` 里的像素上传到 GPU，
完成节点树计算之后再读回 CPU 的 `RenderResult`。
这个"上传 - 计算 - 回读"的模式决定了它的性能特征，
也解释了为什么它需要一个专门的 GPU 上下文。

=== 15.5.2 `do_render_compositor()`

管线的调用点在 #src("source/blender/render/intern/pipeline.cc:1214")：

```cpp
/* source/blender/render/intern/pipeline.cc:1212（节选） */
/* Render compositor nodes, along with any scenes required for them.
 * The result will be output into a compositing render layer in the render result. */
static void do_render_compositor(Render *re)
{
  bNodeTree *ntree = re->pipeline_scene_eval->compositing_node_group;
  bool update_newframe = false;

  if (compositor_needs_render(re->pipeline_scene_eval)) {
    /* render the frames
     * it could be optimized to render only the needed view
     * but what if a scene has a different number of views
     * than the main scene? */
    do_render_engine(re);
  }
  else {
    re->i.cfra = re->r.cfra;

    /* ensure new result gets added, like for regular renders */
    BLI_rw_mutex_lock(&re->resultmutex, THREAD_LOCK_WRITE);

    render_result_free(re->result);
    if ((re->r.mode & R_CROP) == 0) {
      render_result_disprect_to_full_resolution(re);
    }
    re->result = render_result_new(re, &re->disprect, RR_ALL_LAYERS, RR_ALL_VIEWS);

    BLI_rw_mutex_unlock(&re->resultmutex);

    /* Scene render process already updates animsys. */
    update_newframe = true;
    ...
  }
  ...
```

*第一段代码回答了一个容易困惑的问题：为什么走合成器分支时还会调用引擎？*
条件是 `compositor_needs_render()`
（#src("source/blender/render/intern/pipeline.cc:1131")）：

```cpp
/* source/blender/render/intern/pipeline.cc:1128（节选） */
/* Returns true if the given scene needs a render, either because it doesn't use the compositor
 * pipeline and thus needs a simple render, or that its compositor node tree requires the scene to
 * be rendered. */
static bool compositor_needs_render(Scene *scene)
{
  bNodeTree *ntree = scene->compositing_node_group;

  if (ntree == nullptr) {
    return true;
  }
  if ((scene->r.scemode & R_DOCOMP) == 0) {
    return true;
  }

  for (const bNode *node : ntree->all_nodes()) {
    Scene *node_scene = get_scene_referenced_by_node(node);
    if (node_scene && node_scene == scene) {
      return true;
    }
  }

  return false;
}
```

三种情况需要真渲染：*没有合成节点树*、*节点树存在但合成开关关着*、
*节点树里有一个引用本场景的"渲染层"节点*。
最后一条是合成器最常用的工作方式（渲染层节点 + 调色 + 输出），
所以实际上大多数场景都会走到 `do_render_engine(re)`。

反过来，*如果节点树里只有图片、文字、遮罩这类输入，就不需要渲染场景*，
于是走 `else` 分支：直接建一个空白的 `RenderResult` 给合成器当画布。
这就是"纯合成"工作流的快速路径。

=== 15.5.3 执行与输出类型

真正的执行是循环每个视图调一次 `RE_compositor_execute()`
（#src("source/blender/render/intern/pipeline.cc:1283")）：

```cpp
/* source/blender/render/intern/pipeline.cc:1269（节选） */
        compositor::NodeGroupOutputTypes needed_outputs =
            compositor::NodeGroupOutputTypes::GroupOutputNode |
            compositor::NodeGroupOutputTypes::FileOutputNode;
        if (!G.background) {
          needed_outputs |= compositor::NodeGroupOutputTypes::ViewerNode |
                            compositor::NodeGroupOutputTypes::NodePreviews;
        }

        CLOG_STR_INFO(&LOG, "Executing compositor");

        re->i.infostr = IFACE_("Compositing");
        re->display->stats_draw(&re->i);
        re->i.infostr = nullptr;

        compositor::RenderContext compositor_render_context;
        compositor_render_context.is_animation_render = re->flag & R_ANIMATION;
        for (RenderView &rv : re->result->views) {
          RE_compositor_execute(*re,
                                *re->main,
                                *re->pipeline_scene_eval,
                                re->r,
                                *ntree,
                                rv.name,
                                &compositor_render_context,
                                needed_outputs);
        }
        compositor_render_context.save_file_outputs(re->pipeline_scene_eval);
```

`needed_outputs` 是一个位掩码，告诉合成器"这一次需要哪些输出节点真的执行"。
*后台渲染时会把 Viewer 与 Node Previews 去掉* ——
这两者只是给界面看的，后台执行它们纯属浪费。
这是一个很典型的"渲染代码里到处都有 `if (!G.background)`"的例子。

`FileOutput` 节点的写盘被推迟到最后一步
（`save_file_outputs()`），原因是它需要知道所有视图都处理完成了。
注释在 `RenderData` 的定义处也有呼应：
"When rendering an animation, saving files is required"（#src("source/blender/render/RE_pipeline.h:484")）。

*Free 与 Execute 是分开的*：

```cpp
/* source/blender/render/intern/compositor.cc:855 */
void RE_compositor_free(Render &render)
{
  render.compositor_free();
}
```

它在 `render_pipeline_free()` 里被调
（#src("source/blender/render/intern/pipeline.cc:1911")），
注释说明了原因："Destroy compositor that was using pipeline depsgraph"。
*合成器持有对管线依赖图的引用，所以必须先释放它再释放图*，
否则会留下悬垂指针。这个顺序在渲染代码里必须严格遵守。

=== 15.5.4 合成器节点

合成器节点与几何节点、着色器节点共用 `bNodeType`，
但求值回调不同。区别在 `bNodeType::get_compositor_operation`
（#src("source/blender/blenkernel/BKE_node.hh:376")）：

```cpp
/* source/blender/blenkernel/BKE_node.hh:376（注释原文） */
  /* Get an instance of this node's compositor operation. Freeing the instance is the
   * responsibility of the caller. */
  NodeGetCompositorOperationFunction get_compositor_operation = nullptr;
```

*"操作"（operation）是这个系统的核心抽象*。
每个合成器节点提供一个 `Operation` 子类的实例，
这些实例构成一张与节点树同构的求值图。相关的类都在
#src("source/blender/compositor/")：

#figure(
  kind: table,
  table(
    columns: (1.6fr, 2.4fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*类*], [*作用*]),
    [`COM_operation.hh` 里的 `Operation`],
    [一切操作的基类：有输入、输出、以及一个执行方法],
    [`COM_simple_operation.hh`], ["简单"操作，一对一处理像素],
    [`COM_pixel_operation.hh`], [逐像素操作，是最常用的一种],
    [`COM_shader_operation.hh`], [用一段 GPU 着色器实现的操作],
    [`COM_node_operation.hh`], [把节点与操作连起来的中间层],
    [`COM_scheduler.hh`、`COM_compile_state.hh`],
    [操作的编译与调度。节点树在这里被"编译"成可执行的指令序列],
    [`COM_render_context.hh`],
    [`RenderContext`，携带"是不是动画渲染"之类的上下文],
  ),
  caption: [合成器的主要类。这一层是 GPU 计算着色器的封装，
   与几何节点的字段求值是两套完全不同的机制。],
) <tbl-compositor-classes>

#note[
  *为什么合成器不像几何节点那样用字段（field）？*
  因为它们的数据模型不同。几何节点要在"元素域"（点 / 边 / 面 / 角）
  上求值，字段是表达这种求值的自然方式；
  而合成器面对的是整张二维图像，几乎所有操作都是"逐像素的同一段程序"，
  用一段 GPU 着色器表达最直接。这也解释了
  `COM_shader_operation.hh` 的存在。
]

== 15.6 接入与扩展渲染

本章的最后一节把"怎么写一个自己的引擎"整理成可以照做的步骤。
两条路：Python 与 C++。

=== 15.6.1 两条路的取舍

#figure(
  kind: table,
  table(
    columns: (1.2fr, 1.6fr, 1.6fr, 1.4fr),
    inset: 6pt,
    align: (left, left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*路线*], [*要做什么*], [*能力*], [*成本*]),
    [Python `RenderEngine` 子类],
    [定义一个类，实现 `render()` 等方法，
     用 `bpy.utils.register_class()` 注册],
    [框架给什么就用什么。
     拿不到底层数据结构，但可以调 `bpy` 的一切，
     包括起子进程],
    [零编译、分发简单、
     热重载],
    [C++ `RenderEngineType`],
    [填一个结构体，
     在 `DRW_engines_register()` 之类的地方注册],
    [`re->pipeline_depsgraph`、
     `GeometrySet`、GPU 抽象全都能直接用，
     `RE_USE_GPU_CONTEXT` 可用],
    [必须重新编译，
     要跟随上游变化],
  ),
  caption: [接入渲染的两条路线。判断标准与第 0 章给出的三路线一致：
   先看 Python 够不够。],
) <tbl-engine-two-routes>

一个常见的中间方案：*Python 引擎 + 外部原生程序*。
在 `render()` 里把场景导出成一个中立格式（`glTF`、`Alembic`、或者自定义格式），
调用外部渲染器的命令行，等它结束后把图像读回来。
这条路不需要碰任何 C++，也不需要把渲染器编译进 Blender，
代价是"导出 - 渲染 - 导入"的往返开销。

=== 15.6.2 Python 引擎：最小可用实现

下面是一个完整可运行的 Python 引擎。它不理解场景，只是在渲染时
报告进度、画一个渐变色、并把结果交回 Blender：
#example-file("ch15/gradient_render_engine.py")

```python
# my_engine.py —— 最小可用 Python 渲染引擎（完整示例）
import bpy
import numpy as np


class GradientRenderEngine(bpy.types.RenderEngine):
    bl_idname = "GRADIENT"
    bl_label = "Gradient"
    bl_use_preview = False
    bl_use_postprocess = False

    def render(self, depsgraph):
        scene = depsgraph.scene
        scale = scene.render.resolution_percentage / 100.0
        width = int(scene.render.resolution_x * scale)
        height = int(scene.render.resolution_y * scale)

        # 逐行写入，让用户能看到进度。
        # 全部写完再一次 begin/end 也是合法的，那样更快。
        rows_per_chunk = max(1, height // 20)
        for y in range(0, height, rows_per_chunk):
            h = min(rows_per_chunk, height - y)

            result = self.begin_result(0, y, width, h)
            layer = result.layers[0].passes["Combined"]

            # Blender 的像素是自下而上的 RGBA float 数组。
            chunk = np.empty((h, width, 4), dtype=np.float32)
            ys = (np.arange(y, y + h, dtype=np.float32) / max(1, height - 1))
            chunk[..., 0] = 0.1
            chunk[..., 1] = ys[:, None]
            chunk[..., 2] = 0.6
            chunk[..., 3] = 1.0
            layer.rect = chunk.reshape(-1, 4).tolist()

            self.end_result(result)

            self.update_progress((y + h) / height)
            if self.test_break():
                return

    def view_update(self, context, depsgraph):
        # 视口里不需要做任何事，但我们得请求一次重绘，
        # 否则视口不会显示新结果。
        pass


classes = (GradientRenderEngine,)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
```

几个必须注意的点：

- *`begin_result(x, y, w, h)` 的 `(x, y)` 是这一块在整图中的左下角坐标。*
  这与 §15.2.5 的 `RE_engine_begin_result()` 是同一个接口的 Python 版本，
  参数顺序完全一致（`x, y, w, h`）。
- *`layer.rect` 是一个二维 float 列表*，形状为 `(w * h, channels)`；
  RGBA 通道时每个内层元素恰好有 4 个分量。像素顺序是*自下而上*、每行从左到右。
  C++ 侧对应
  `RenderPass::ibuf` 的 `float_buffer`。
- *`self.test_break()` 是 Python 版的 `RE_engine_test_break()`*。
  长循环里必须查它，否则用户按取消不会有反应 ——
  这正是 §15.4.3 里 EEVEE 那处 TODO 说的同一件事。
- *`bl_use_postprocess = False`* 很关键：它让 `RE_engine_render()` 在
  `do_all == true`（全流程）时返回真，也就是"这个引擎接管到底"。
  如果设成 `True`，框架会在引擎之后继续执行合成器 ——
  那时你的结果是合成器的输入而不是最终图像。

#warn[
  *`bl_use_postprocess` 的默认值是 `True`*，但它与 `RE_USE_POSTPROCESS`
  是*反相*关系：RNA 用的是 `RNA_def_property_boolean_negative_sdna(...)`
  （#src("source/blender/makesrna/intern/rna_render.cc:937-940")），
  也就是 `bl_use_postprocess == !(type->flag & RE_USE_POSTPROCESS)`。
  所以*置上 `RE_USE_POSTPROCESS` 才等价于 Python 侧的
  `bl_use_postprocess = False`* —— 这一位的含义是"引擎接管到底，
  框架不再执行合成器"。
  判定逻辑有两条（#src("source/blender/render/intern/engine.cc:1014")）：

  ```cpp
  /* source/blender/render/intern/engine.cc:1014（节选） */
    if (do_all && !(type->flag & RE_USE_POSTPROCESS)) {
      return false;
    }
    if (!do_all && (type->flag & RE_USE_POSTPROCESS)) {
      return false;
    }
  ```

  `do_render_full_pipeline()` 传 `do_all == true`
  （#src("source/blender/render/intern/pipeline.cc:1493")），
  所以*无论这一位是真是假，你的引擎都会被调到* —— 只是走两条不同的路径。
  这一位为*真*时，`RE_engine_render(re, true)` 直接返回真，
  源码注释写明 "in this case external render overrides all"
  （#src("source/blender/render/intern/pipeline.cc:1493-1495")），
  渲染结果就是最终图像，框架*不*再碰它；这一位为*假*时，
  `RE_engine_render(re, true)` 返回假，框架转而调用
  `do_render_compositor()`（#src("source/blender/render/intern/pipeline.cc:1507")），
  后者再调 `do_render_engine()` → `RE_engine_render(re, false)`
  （#src("source/blender/render/intern/pipeline.cc:1224")）让你的引擎出图，
  然后*在合成节点树上再加工一遍你的结果*。

  *结论：自己写的引擎如果不希望被合成节点树二次加工，
  就显式设 `bl_use_postprocess = False`（Python）或*
  *给上 `RE_USE_POSTPROCESS`（C++）。* 反过来，如果你希望用户的
  合成节点树照常生效（例如你的引擎只出各种渲染通道），就保留默认值
  —— 不设这一位，Python 侧看到的就是 `bl_use_postprocess = True`。
]

=== 15.6.3 C++ 引擎：从结构体到注册

如果 Python 不够用，C++ 侧的流程是：

*第一步：定义 `RenderEngineType`。* 抄一份 EEVEE 的骨架
（#src("source/blender/draw/engines/eevee/eevee_engine.cc:79")），
按需实现回调：

```cpp
/* 自定义引擎的 RenderEngineType（示意） */
static void myengine_update(RenderEngine *engine, Main *bmain, Depsgraph *depsgraph)
{
  /* 同步场景数据。在这里读 depsgraph，不要缓存原始 ID 指针。 */
}

static void myengine_render(RenderEngine *engine, Depsgraph *depsgraph)
{
  /* 一次渲染的主体。用 RE_engine_begin_result() / RE_engine_end_result()
   * 交回结果，用 RE_engine_update_progress() 报告进度，
   * 用 RE_engine_test_break() 响应取消。 */
}

RenderEngineType myengine_type = {
    /*next*/ nullptr,
    /*prev*/ nullptr,
    /*idname*/ "MY_ENGINE",
    /*name*/ N_("My Engine"),
    /*flag*/ RE_USE_GPU_CONTEXT,          /* 按需；不用 GPU 就别加 */
    /*update*/ &myengine_update,
    /*render*/ &myengine_render,
    /*render_frame_finish*/ nullptr,
    /*draw*/ nullptr,
    /*bake*/ nullptr,
    /*view_update*/ nullptr,
    /*view_draw*/ nullptr,
    /*update_script_node*/ nullptr,
    /*update_render_passes*/ nullptr,
    /*update_custom_camera*/ nullptr,
    /*draw_engine*/ nullptr,
    /*rna_ext*/ {nullptr, nullptr, nullptr},
};
```

*第二步：注册。* 最省事的做法是在 `DRW_engines_register()` 里加一行
（#src("source/blender/draw/intern/draw_context.cc:2281")）：

```cpp
/* source/blender/draw/intern/draw_context.cc:2281（改） */
void DRW_engines_register()
{
  RE_engines_register(&DRW_engine_viewport_eevee_type);
  RE_engines_register(&DRW_engine_viewport_workbench_type);
  RE_engines_register(&myengine_type);       /* 新增这一行 */
}
```

这会让你的引擎出现在 `Scene.render.engine` 下拉框里（§15.2.4）。
注意*不要*给它 `RE_INTERNAL` —— 那个标志是给静态存储期对象用的，
而且退出时 `RE_engines_exit()` 会跳过带这个标志的项
（#src("source/blender/render/intern/engine.cc:87")）。

*第三步：决定要不要接管后处理。*
如果你想把合成器也交给自己的引擎，加上 `RE_USE_POSTPROCESS`；
如果想让 Blender 的节点树继续生效，*不要加*。

#figure(
  kind: table,
  table(
    columns: (2.2fr, 2.6fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*症状*], [*最可能的原因*]),
    [引擎不出现在下拉框里],
    [`RE_engines_register()` 没调，或者注册在 `RE_engines_init()` 之前],
    [出现在列表里但选中后仍渲 EEVEE],
    [`Scene.render.engine` 存的是 idname 字符串；
     检查 `RE_engines_find()` 有没有回退（§15.2.3）],
    [点渲染什么也没发生，直接出黑图],
    [引擎设了 `RE_USE_POSTPROCESS` 但没实现，
     或反过来：本该接管却被框架绕过],
    [渲染结果里只有第一块或只有一行像素],
    [每块都 `begin_result()` 了，但忘了 `end_result()` 或坐标算错],
    [界面在渲染期间卡死],
    [`render()` 是同步的。要边渲边显示必须靠
     `begin_result` / `end_result` 分块 + `display_update`],
    [按取消没反应],
    [循环里没查 `RE_engine_test_break()` 或 Python 的 `self.test_break()`],
    [退出时崩溃或报内存错误],
    [`RE_INTERNAL` 被误设，或 `begin_result` 的结果被手工释放],
  ),
  caption: [自定义引擎的八种典型故障。前三条属于"接不进去"，
   中间三条属于"接进去但不工作"，最后两条属于"能工作但不干净"。],
) <tbl-engine-pitfalls>

=== 15.6.4 调试渲染问题的顺序

本章涉及的层次很多，出问题时的排查顺序应该固定下来：

1. *先确认用的是哪个引擎*。`scene.render.engine` 的值、
   以及 `RE_engines_find()` 有没有回退到 EEVEE。
   加 `--log "render"`（或 `--log "*"`）启动就会打印引擎信息：
   `engine.cc` 里这个日志类别就叫 `{"render"}`
   （#src("source/blender/render/intern/engine.cc:61")），
   它用 `CLOG_INFO` 打出 `Engine: %s`
   （#src("source/blender/render/intern/engine.cc:1099")）。
2. *确认渲染走的是哪个分支*。§15.2.1 的三个分支各自的行为差别很大。
   一个快速判据：如果合成节点树里的调色完全没生效，
   说明你的引擎带 `RE_USE_POSTPROCESS`，把合成器绕过去了。
3. *确认依赖图是渲染模式的*。视口与渲染用的是两份图（§15.1.3）。
   "视口对、渲染不对"十有八九是某处的
   `eModifierMode_Render` / `eModifierMode_Realtime` 位设错了。
4. *确认分块坐标*。如果是分块引擎，先把块数降到 1
   （整帧一块）确认结果正确，再逐步增加。
5. *最后才怀疑算法*。

#summary[
  写一个渲染引擎，本质上只需要回答五个问题：

  1. *我是谁*：一个 `RenderEngineType`（C++）或一个
     `bpy.types.RenderEngine` 子类（Python），有一个唯一的 `idname`。
  2. *我要不要接管到底*：`RE_USE_POSTPROCESS` 决定合成器是否继续生效。
  3. *我怎么读场景*：通过 `engine->depsgraph` / `engine->re`，
     绝不缓存原始 ID 指针。
  4. *我怎么交结果*：`RE_engine_begin_result()` /
     `RE_engine_end_result()`（Python 是 `begin_result` / `end_result`）。
  5. *我怎么被打断*：`RE_engine_test_break()`（Python 是 `test_break()`）。

  框架负责其余的一切。这就是为什么 EEVEE 的 `RenderEngineType`
  只有两个非空回调，而 Cycles 完全不需要改 Blender 的核心代码。
]

#summary[
  本章三条主线：

  *框架*（§15.1–§15.2）：`render/` 只提供框架。数据分四层
  （`Render` → `RenderResult` → `RenderLayer` → `RenderPass`）。
  一次帧渲染有明确的阶段序列（@fig-render-pipeline），
  其中 `do_render_full_pipeline()` 按
  "外部引擎 → 序列器 → 合成器"的优先级分支。
  渲染用独立的 `DAG_EVAL_RENDER` 依赖图。
  分块由引擎自己决定，框架提供 `begin/end_result` 与高亮接口。

  *引擎*（§15.3、§15.4）：Cycles 是插件，
  通过 Python `RenderEngine` 子类接入，注册走
  `rna_RenderEngine_register()` → `RE_engines_register()`。
  EEVEE 是内置引擎，也是 draw manager 的一部分，
  它的 `RenderEngineType` 只有两个非空回调，
  真正的实现是继承 `DrawEngine` 的 `Instance`。

  *合成*（§15.5）：渲染合成器是 GPU 实现，
  输入输出都是现成的 `RenderResult`。
  它会被管线按需调用，也可以在纯合成工作流里跳过引擎。
  节点靠 `get_compositor_operation` 提供 `Operation` 实例。

  *接入*（§15.6）：Python 路线零编译，适合外包给外部程序；
  C++ 路线能拿到全部的底层能力。
  两条路都要正确处理"接管后处理"、"分块交结果"、"响应取消"这三件事。
]

#exercise[
  *练习 15.1（读源码）* 打开 #src("source/blender/render/intern/pipeline.cc")，
  读完 `do_render_full_pipeline()`（同文件:1480）与
  `do_render_compositor()`（同文件:1214），回答：
  （a）如果把场景的 `scemode` 里的 `R_DOCOMP` 关掉，走的是哪个分支？
  （b）`compositor_needs_render()` 在什么情况下返回真？
  （c）为什么 `do_render_engine()`（同文件:1055）里要先
  `RE_SetCamera(re, camera)` 再调 `RE_engine_render()`？

  *练习 15.2（读源码）* 对比 #src("source/blender/draw/engines/eevee/eevee_engine.cc:79")
  与 #src("source/blender/draw/engines/workbench/workbench_engine.cc:799")
  两个 `RenderEngineType`。回答：（a）标志位差的唯一一项是什么，
  它带来什么行为差别？（b）为什么两者的 `draw_engine` 字段都是 `nullptr`，
  但视口仍然能画？（提示：视口引擎不由 `draw_engine` 字段决定，
  而是 draw manager 在 #src("source/blender/draw/intern/draw_context.cc:1200")
  处按 `render_engine_type` 选择；这个类型的来路见
  #src("source/blender/editors/space_view3d/view3d_draw.cc:1639-1651") 的
  `ED_view3d_engine_type()`。）

  *练习 15.3（读源码）* 读 #src("source/blender/render/intern/engine.cc:1003")
  的 `RE_engine_render()`，把四个 `return false` 的条件写成一张真值表
  （输入：`type->render` 是否为空、`R_BUTS_PREVIEW`、`RE_USE_PREVIEW`、
  `do_all`、`RE_USE_POSTPROCESS`）。然后回答：*一个
  `bl_use_postprocess = True` 的 Python 引擎，在 F12 渲染时会不会被调到？
  如果会，它是在哪一步被调的？*

  *练习 15.4（动手，小）* 用 §15.6.2 的代码建立一个 Python 引擎插件：
  （a）把它保存成一个 addon 目录并在偏好设置里启用；
  （b）确认 `Scene.render.engine` 下拉框里出现 "Gradient"；
  （c）按 F12，确认渲染结果是一个绿色渐变；
  （d）在渲染过程中按 <kbd>Esc</kbd>，确认它能停下来。
  如果第（d）步停不下来，说明 `test_break()` 的位置不对 —— 把它移到
  最内层循环里。

  *练习 15.5（动手，中等）* 给 §15.6.2 的引擎加上真正的场景感知：
  用 `depsgraph.scene.camera` 取相机，用
  `camera.matrix_world` 算出相机位置，然后让渐变的颜色取决于
  *每个像素对应的相机射线方向*。提示：可以用
  `camera.calc_matrix_camera(depsgraph, x=width, y=height)` 拿到投影矩阵，
  再用 numpy 求逆。完成后验证：旋转相机会让颜色分布跟着变。

  *练习 15.6（动手，进阶）* 实现一个 C++ 引擎 `MY_ENGINE`：
  （a）按 §15.6.3 的三步定义并注册；
  （b）`render()` 里用 `RE_engine_begin_result()` 把图像分成
  4×4 共 16 块，每块填一个纯色，块与块颜色依次变化，
  这样能直接看出分块顺序与坐标是否正确；
  （c）每块之间调 `RE_engine_update_progress()` 与
  `RE_engine_test_break()`；
  （d）验证：按 F12 能看到 16 个色块；按 <kbd>Esc</kbd> 能在中途停下；
  界面上的进度条在走。
  注意：坐标是"整图中的左下角坐标"，不是"从左上角算的行列号"，
  搞错的话 16 个色块会错位或镜像。
]
