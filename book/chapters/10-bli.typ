#import "../common.typ": *

= 第 10 章 基础库 BLI 与 C++ 约定

写 C++ 改动时，最容易犯的错误不是"算法写错了"，而是"用了不属于这个代码库的写法"。
一个熟悉 `std::vector` 的人会很自然地写下 `std::vector<Object *> objs;`，
然后在 code review 里被问：为什么不直接用 `Vector<Object *>`；
他会试着 `free(ptr)`，然后发现整个代码库找不到一处 `free`；
他会把异常当作常规错误通道，随后发现 Blender 的核心路径通常采用返回值、
错误枚举与 `ReportList` 表达失败。

这些约定不是风格偏好，它们背后都有具体的技术理由，而且每一条都能在源码里找到证据。
本章把 `source/blender/blenlib/`（下称 BLI）和 `intern/` 下的两个内部库讲清楚，
让你写出的 C++ 代码"看起来就像 Blender 自己写的"。

#note[
  本章的代码引用基准是 Blender #blender-version。*这一版有一个重要变化*：
  历史上广为人知的 `MEM_mallocN` / `MEM_callocN` / `MEM_freeN` 系列宏已经*不复存在*。
  如果你读的是 3.x 或 4.x 时代的教程，那里的分配代码在本章对应的版本上全部无法编译。
  §10.1.3 会给出完整的新旧对照。
]

== 10.1 内存管理：`guardedalloc`、`MEM_` 与生命周期

=== 10.1.1 为什么 Blender 不用 `new` / `delete` / `malloc` / `free`

Blender 的内存需求有三个特点，标准库的分配器一个都满足不了：

1. *几乎所有分配都发生在热路径上*，但调试时需要知道每一块内存"是谁分配的"。
2. *分配量巨大且长期驻留*，泄漏一块就泄漏几十 MB，而崩溃时又必须能指认元凶。
3. *同一个进程里需要在"快"和"可追踪"之间切换*，而不是重新编译。

`guardedalloc` 就是为这三点设计的内部库，位于 #src("intern/guardedalloc/")。
它提供两套分配器实现，运行时切换：

#figure(
  kind: table,
  table(
    columns: (auto, 1.35fr, 1.35fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*分配器*], [*实现文件*], [*特点*]),
    [`lockfree`（默认）],
    [#src("intern/guardedalloc/intern/mallocn_lockfree_impl.cc")],
    [无锁、快；统计分配次数与字节数，但不记录每块的名称],
    [`guarded`（`-d` / `--debug` 时启用）],
    [#src("intern/guardedalloc/intern/mallocn_guarded_impl.cc")],
    [每次调用加锁、慢；把每个块挂进一个全局 `ListBase`，因而能按名字列出所有未释放的块],
  ),
  caption: [guardedalloc 的两套后端实现],
) <tbl-guardedalloc-backends>

切换动作发生在程序的极早期，早到"任何一次分配之前"。
源码里对这个约束有明确注释和检查，见 #src("source/creator/creator.cc:403-L420")：

```cpp
/* NOTE: Special exception for guarded allocator type switch:
 *       we need to perform switch from lock-free to fully
 *       guarded allocator before any allocation happened.
 */
{
  int i;
  for (i = 0; i < argc; i++) {
    if (STR_ELEM(argv[i], "-d", "--debug", "--debug-memory", "--debug-all")) {
      printf("Switching to fully guarded memory allocator.\n");
      MEM_use_guarded_allocator();
      break;
    }
    if (STR_ELEM(argv[i], "--", "-c", "--command")) {
      break;
    }
  }
  MEM_init_memleak_detection();
}
```

这段代码（节选）解释了为什么 `guardedalloc` 的后端是两套实现、却暴露成同一个 API：
公开头文件里用*函数指针*把实现间接掉。例如

```cpp
// intern/guardedalloc/MEM_guardedalloc.h:77（节选）
extern size_t (*MEM_allocN_len)(const void *vmemh) ATTR_WARN_UNUSED_RESULT;
```

这样的字段在 #src("intern/guardedalloc/MEM_guardedalloc.h") 里有一整组
（`MEM_realloc_uninitialized_id`、`MEM_printmemlist`、`MEM_consistency_check`、
`MEM_get_memory_in_use` 等），运行期绑定到 `MEM_guarded_*` 或 `MEM_lockfree_*` 之一。
头文件里的两套符号名也印证了这一点：`MEM_guarded_mallocN` 与 `MEM_lockfree_mallocN`
在代码库中是同时存在的。

#tip[
  你可以直接用 `blender -d` 启动，观察退出时的泄漏报告。
  输出形如 `Error: Not freed memory blocks: %u, total unfreed memory %f MB`
  —— 这个格式串就在 #src("intern/guardedalloc/intern/leak_detector.cc:38")，
  紧接着的 `MEM_printmemlist()` 会把每一块的*分配名称*和大小打出来。
]

=== 10.1.2 `guardedalloc` 暴露什么

公开头文件是 #src("intern/guardedalloc/MEM_guardedalloc.h")（676 行），
外加一个安全乘法辅助头 #src("intern/guardedalloc/MEM_safe_multiply.h")。
头文件把 API 明确分成两组，注释写得很直白：

- *Untyped Allocation API*（#src("intern/guardedalloc/MEM_guardedalloc.h:59-L70")），
  即"C 风格、`void *` + 显式尺寸"的那一组。注释原文是
  "This API should usually not be used anymore in C++ code"。
- *Type-aware allocation & construction API*（#src("intern/guardedalloc/MEM_guardedalloc.h:313-L328")），
  即 `MEM_new` / `MEM_delete` 这一组，注释明确说"When possible, it is preferred to use these"。

第二组才是你日常要用的。逐个列出关键函数与其精确位置：

#figure(
  kind: table,
  table(
    columns: (auto, 1.7fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*API*], [*语义*]),
    [`MEM_new<T>(name, args...)`],
    [分配 `sizeof(T)` 并用 `args...` 构造；调用 `T` 的构造函数。语义等价于 `new T(args...)`],
    [`MEM_new_zeroed<T>(name)`],
    [分配并清零，*不*调用构造函数。用于 POD 或需要"零初始化后再手工构造"的场景],
    [`MEM_new_array_zeroed<T>(n, name)`],
    [分配 `n` 个 `T` 并清零，带整数溢出检查],
    [`MEM_new_array_uninitialized<T>(n, name)`],
    [同上，但不清零。用于随后会被整体覆盖的大数组],
    [`MEM_new_uninitialized<T>(name)`],
    [单个对象，不清零],
    [`MEM_delete(ptr)`],
    [析构（若非平凡析构）并释放。对多态类型会先 `dynamic_cast<void *>` 求出最派生地址，因此虚基类指针也能正确释放],
    [`MEM_SAFE_DELETE(v)`],
    [`MEM_delete(v)` 之后把 `v` 置为 `nullptr`，见 #src("intern/guardedalloc/MEM_guardedalloc.h:436-L442")],
    [`MEM_delete_void(p)`],
    [释放无类型内存，配合 untyped API 使用。*不能*用于 `MEM_new` 分配的内存],
    [`MEM_dupalloc<T>(other)`],
    [按位复制一份 `T`，返回新指针；`nullptr` 安全],
    [`MEM_realloc_uninitialized(p, len)`],
    [重新分配，新字节不初始化。宏形式，自动把 `__func__` 当作分配名],
    [`MEM_realloc_zeroed(p, len)`],
    [同上，但新字节清零],
  ),
  caption: [`guardedalloc` 的 C++ 分配 API。所有 `name` 参数只存指针，因此*必须是静态字符串*],
) <tbl-mem-api>

最后一条表注是真实存在的易错点，头文件里写得非常明确
（#src("intern/guardedalloc/MEM_guardedalloc.h:122-L125")）：

```
 * Allocate a block of memory of size len, with tag name str. The
 * memory is cleared. The name must be static, because only a
 * pointer to it is stored!
```

所以 `MEM_new<Foo>(std::string("foo" + i).c_str())` 是*悬垂指针*，
而 `MEM_new<Foo>(__func__)` 是标准写法。这就是为什么你在 Blender 源码里
看到 `MEM_new<XrActionSet>(__func__)` 这样的写法遍地都是。

#warn[
  `MEM_realloc_uninitialized` / `MEM_realloc_zeroed` 是*宏*，不是函数，
  它们把 `__func__` 补进去（#src("intern/guardedalloc/MEM_guardedalloc.h:118-L119")）。
  想指定自定义名称要用带 `_id` 后缀的底层函数指针，例如
  `MEM_realloc_zeroed_id(ptr, size, "NlaEvalSnapshot::channels")`。
  另外注意注释里那句"this is not as optimized as a system realloc"——
  它其实是"新分配 + 拷贝 + 释放"，不要放进每帧几万次的内循环。
]

=== 10.1.3 新旧对照：`MEM_mallocN` 去哪了

这是本章最需要强调的一条事实。在 #blender-version 源码树里：

```bash
$ rg -n "MEM_mallocN|MEM_callocN|MEM_freeN|MEM_dupallocN|MEM_reallocN" \
    --glob '*.{c,cc,hh,h}' source intern
1 match
source/blender/editors/space_node/node_bundle_type_search.cc:45:
/* This class must not have a destructor, since it is used by buttons and freed with #MEM_freeN. */
```

全代码库只剩*一条注释*还在提 `MEM_freeN`，而且这条注释本身已经过期。
公开 API 中这些名字一个都不存在。迁移对照如下：

#figure(
  kind: table,
  table(
    columns: (1.15fr, 1.3fr, 1.3fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*旧写法（≤ 4.x 教程）*], [*5.2 写法*], [*备注*]),
    [`MEM_callocN(n, "x")`], [`MEM_new_zeroed(n, "x")`], [`n` 是字节数，不是元素个数],
    [`MEM_mallocN(n, "x")`], [`MEM_new_uninitialized(n, "x")`], [—],
    [`MEM_calloc_arrayN(n, s, "x")`], [`MEM_new_array_zeroed(n, s, "x")`], [带溢出检查],
    [`MEM_malloc_arrayN(n, s, "x")`], [`MEM_new_array_uninitialized(n, s, "x")`], [带溢出检查],
    [`MEM_freeN(p)`], [`MEM_delete_void(p)`], [无类型指针用这个],
    [`MEM_dupallocN(p)`], [`MEM_dupalloc(p)`], [模板版，更安全],
    [`MEM_reallocN(p, n)`], [`MEM_realloc_uninitialized(p, n)`], [宏],
    [`MEM_recallocN(p, n)`], [`MEM_realloc_zeroed(p, n)`], [宏],
    [`MEM_SAFE_FREE(p)`], [`MEM_SAFE_DELETE_VOID(p)`], [#src("intern/guardedalloc/MEM_guardedalloc.h:448-L454")],
  ),
  caption: [guardedalloc 分配 API 的新旧对照表],
) <tbl-mem-migration>

还有一个只在源码内部存在的"类型化 ID 分配"模式，值得单独看一眼。
数据块（ID）按类型分配时，尺寸来自该类型的注册信息，而不是 `sizeof`：

```cpp
// source/blender/blenkernel/intern/lib_id.cc:1355（节选）
ID *BKE_libblock_alloc_notest(short type)
{
  const char *name;
  size_t size = BKE_libblock_get_alloc_info(type, &name);
  if (size != 0) {
    ID *id = static_cast<ID *>(MEM_new_zeroed(size, name));
    return id;
  }
  BLI_assert_msg(0, "Request to allocate unknown data type");
  return nullptr;
}
```

`BKE_libblock_get_alloc_info` 返回的 `size` 来自 `IDTypeInfo::struct_size`
（在 #src("source/blender/blenkernel/intern/lib_id.cc:1352") 返回），
而 `name` 也来自同一个注册表。这就是"一切皆注册类型"落实到内存分配上的样子：
*分配器不需要认识 `Mesh`，它只认识一张表*。分配名称同时也是泄漏报告里显示的那个名字。

=== 10.1.4 泄漏检测是怎么工作的

整套机制只有一个入口和两个开关：

```cpp
// intern/guardedalloc/MEM_guardedalloc.h:253-L264（节选）
/**
 * This should be called as early as possible in the program. When it has been called, information
 * about memory leaks will be printed on exit.
 */
void MEM_init_memleak_detection(void);

/**
 * When this has been called and memory leaks have been detected, the process will have an exit
 * code that indicates failure. This can be used for when checking for memory leaks with automated
 * tests.
 */
void MEM_enable_fail_on_memleak(void);
```

实现只有 93 行（#src("intern/guardedalloc/intern/leak_detector.cc")），
核心是一个函数局部的 `static` 对象：

```cpp
// intern/guardedalloc/intern/leak_detector.cc:60-L80（节选）
void MEM_init_memleak_detection()
{
  /* Calling this ensures that the memory usage counters outlive the memory leak detection. */
  memory_usage_init();

  /* Ensure that the static memleak data storage is initialized before the #MemLeakPrinter one, so
   * that it outlives the memory leak detection. */
  std::any any_data = std::make_any<int>(0);
  mem_guarded::internal::add_memleak_data(any_data);

  static MemLeakPrinter printer;
}
```

`MemLeakPrinter` 的析构函数在进程退出时运行，打印未释放块的数量与总字节数，
然后调用 `mem_clearmemlist()`（#src("intern/guardedalloc/intern/leak_detector.cc:46")）。
注释解释了为什么必须清空：不清空的话，那些本来"还被 Blender 自己持有"的块
会被 LeakSanitizer 也报一遍，产生假阳性。

#pitfall[
  两个最常见的误用：

  1. *在 `main` 之后还分配内存。* `MemLeakPrinter` 析构后，`leak_detector_has_run` 置真，
     此时再 `MEM_delete` 或再分配都会触发
     `"Freeing memory after the leak detector has run..."`。
     源码给的处方写在同一个文件里（#src("intern/guardedalloc/intern/leak_detector.cc:19-L22")）：
     把静态变量改成 "construct on first use" 惯用法，也就是放进函数里做函数局部 `static`。
  2. *以为 `-d` 只是个日志开关。* 它会切到 `guarded` 分配器，带来全局锁，
     运行会明显变慢。测性能时不要带 `-d`。
]

`--debug-exit-on-error` 是给自动化测试用的组合开关
（#src("source/creator/creator_args.cc:1070-L1075")）：

```cpp
static int arg_handle_debug_exit_on_error(int /*argc*/, const char ** /*argv*/, void * /*data*/)
{
  MEM_enable_fail_on_memleak();
  CLG_error_fn_set(clog_abort_on_error_callback);
  return 0;
}
```

它把"有内存泄漏"和"CLOG 报了 error 级日志"两件事都变成进程退出码非零，
于是 CI 里只要看退出码就够了。参数注册在 #src("source/creator/creator_args.cc:3343")。

=== 10.1.5 COW 的历史命名与 copy-on-evaluation

`guardedalloc` 管的是"一块内存的生死"，而 Blender 里还有一层更大的生命周期问题：
*一个数据块（ID）在什么时候是"用户编辑的那份"，什么时候是"求值用的那份"*。

这套机制在旧资料和许多源码标识符中简称 *COW*。这个缩写原本展开为
*copy-on-write*，不能展开成“copy-on-eval”或“Copy on Evaluate”。Blender 当前源码
采用的正式名称是 *copy-on-evaluation*（求值时复制）：依赖图为求值生成并刷新一份
独立副本，而不是等到对共享对象执行首次写入时才复制。理解它的最简方式是记住两条
指针关系：

- `ID *id_orig` —— 原始数据块，属于 `Main`，用户在界面里改的就是它，它会被存进 `.blend`。
- `ID *id_cow` —— 求值副本，由依赖图持有，*不*进 `.blend`，求值器读它、改它。

求值副本的创建与刷新集中在
#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc")。
公开接口在 `deg` 命名空间里声明
（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.h:38-L79")）：

```cpp
// source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.h:42-L52（节选）
ID *deg_update_eval_copy_datablock(const Depsgraph *depsgraph, const IDNode *id_node);
ID *deg_update_eval_copy_datablock(const Depsgraph *depsgraph, struct ID *id_orig);

/** Helper function which frees memory used by copy-on-written data-block. */
void deg_free_eval_copy_datablock(struct ID *id_cow);

/**
 * Callback function for depsgraph operation node which ensures evaluated
 * data-block is ready for use by further evaluation routines.
 */
void deg_create_eval_copy(blender::Depsgraph *depsgraph, const struct IDNode *id_node);
```

"是求值副本吗"这个问题，靠 `ID::tag` 上的一位来判断：`ID_TAG_COPIED_ON_EVAL`
（#src("source/blender/makesdna/DNA_ID.h:918")）。求值副本的分配路径也在这里留下痕迹
（#src("source/blender/blenkernel/intern/lib_id.cc:1605")）：`new_id->tag |= ID_TAG_COPIED_ON_EVAL;`。

"要不要复制"则由一个独立谓词决定，它是有例外清单的
（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.h:70-L79")）：

```cpp
/**
 * Check whether an evaluated data-block copy is needed for given ID.
 *
 * There are some exceptions on data-blocks which are covered by dependency graph
 * but which we don't want to start duplicating.
 *
 * This includes images.
 */
bool deg_eval_copy_is_needed(const ID *id_orig);
bool deg_eval_copy_is_needed(const ID_Type id_type);
```

刷新逻辑最能说明求值副本的生命周期
（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:844-L883")，节选）：

```cpp
ID *deg_update_eval_copy_datablock(const Depsgraph *depsgraph, const IDNode *id_node)
{
  const ID *id_orig = id_node->id_orig;
  ID *id_cow = id_node->id_cow;
  /* Similar to expansion, no need to do anything here. */
  if (!deg_eval_copy_is_needed(id_orig)) {
    return id_cow;
  }
  ...
  RuntimeBackup backup(depsgraph);
  backup.init_from_id(id_cow);
  deg_free_eval_copy_datablock(id_cow);
  deg_expand_eval_copy_datablock(depsgraph, id_node);
  backup.restore_to_id(id_cow);
  return id_cow;
}
```

注意最后三步：*先把求值副本上那些"运行时才有意义"的指针备份走，再释放并重建它，
然后恢复回去*。这就是为什么求值副本不能用"直接 `MEM_delete` 再 `MEM_new`"来刷新 ——
它身上挂着求值器、缓存、GPU 资源等只能原地保留的运行时状态。

判断一个块是否"已展开"，用的居然是一个字符串成员
（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:465-L469")）：

```cpp
/* Check whether given ID is expanded or still a shallow copy. */
inline bool check_datablock_expanded(const ID *id_cow)
{
  return (id_cow->name[0] != '\0');
}
```

初看很怪，但理由在 `deg_expand_eval_copy_datablock` 的注释里
（#src("source/blender/depsgraph/intern/eval/deg_eval_copy_on_write.cc:762-L770")）：
被释放之后那个 `id_cow` 只是"一块脏缓冲区"，连 `ID::runtime` 都可能无效，
而 `name[0]` 是唯一被 `deg_free_eval_copy_datablock` 可靠清掉的标志位。

#summary[
  三条实践结论：

  1. *不要自己 `MEM_delete` 一个 ID。* 用 `BKE_id_free()` 之类的释放 API
     （见第 9 章），它们会顺带处理引用计数、运行时数据、依赖图通知。
  2. *不要修改求值副本。* 你改的应该是 `id_orig`；改完发 notifier（§11.3），
     让依赖图自己决定何时重建副本。
  3. *拿到 ID 指针时先问自己拿到的是哪一份。* `DEG_get_evaluated_*` 系列返回求值副本，
     `CTX_data_*` 系列返回原始数据块。两者混用是"改了没反应"和"崩溃"的第一大来源。
]

== 10.2 容器：`ListBase` 与 `blender::` 命名空间

=== 10.2.1 一个代码库，两套容器

这是新手最困惑的地方：Blender 里同时存在两套容器体系，而且都不能不用。

- *C 时代继承下来的侵入式双向链表*：`ListBase` / `ListBaseT<T>` / `Link`。
- *C++ 时代自研的容器*：`blender::Vector`、`Array`、`Map`、`Set`、`Span`、`StringRef`。

它们的用法分工很清楚，先记住结论，再看理由：

#figure(
  kind: table,
  table(
    columns: (1fr, 1.5fr, 1.3fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*需求*], [*用什么*], [*理由*]),
    [数据要写进 `.blend` / 定义在 `DNA_*.h` 里], [`ListBaseT<T>`], [布局稳定、与旧文件二进制兼容],
    [数据要参与依赖图、被 ID 拥有], [`ListBaseT<T>`], [同上；且可被遍历器做增量更新],
    [纯运行时、临时收集一批东西], [`Vector<T>` / `Array<T>`], [更安全、更快、有内联缓冲],
    [键值查找], [`Map<K, V>`], [开放寻址哈希，远快于线性扫描],
    [去重], [`Set<K>`], [同 `Map`],
    [只读传参 / 借用一段连续内存], [`Span<T>` / `Span<const T>`], [零拷贝，不涉及所有权],
    [只读传字符串（不拷贝）], [`StringRef`], [零拷贝，不比 `std::string` 差],
  ),
  caption: [两套容器的分工],
) <tbl-container-choice>

规模上的对比也能说明问题。在 `source/` 与 `intern/` 中做粗略符号统计：

#figure(
  kind: table,
  table(
    columns: (auto, auto),
    inset: 6pt,
    align: (left, right),
    stroke: 0.4pt + luma(78%),
    table.header([*符号*], [*出现次数（`source/` + `intern/`）*]),
    [`Span<`], [13,797],
    [`Vector<`], [6,037],
    [`Array<`], [5,210],
    [`ListBaseT<`], [3,517],
    [`Map<`], [1,374],
  ),
  caption: [容器使用频次的量级对比。`Span` 最多，因为它是"传参"的首选；`ListBaseT` 排第四，但它是 DNA 里的唯一选择。],
) <tbl-container-counts>

=== 10.2.2 `ListBase`、`Link` 与 `ListBaseT<T>`

真正的定义不在 `BLI_listbase.h` 里，而在 DNA 里
（#src("source/blender/makesdna/DNA_listBase.h")）。这一点常常被搞错，
值得先看清楚（节选）：

```cpp
// source/blender/makesdna/DNA_listBase.h:19-L38（节选）
/** Generic - all structs which are put into linked lists begin with this. */
struct Link {
  struct Link *next, *prev;
};

/** Simple subclass of Link. Use this when it is not worth defining a custom one. */
struct LinkData {
  struct LinkData *next, *prev;
  void *data;
};

/**
 * The basic double linked-list structure.
 *
 * \warning Never change the size/definition of this struct! The #init_structDNA
 * function (from dna_genfile.cc) uses it to compute the #pointer_size.
 */
struct ListBase {
  void *first, *last;
};
```

`ListBase` 只有两个 `void *`，这就是"侵入式链表"的含义：
*链表节点本身不包含数据指针，而是数据里嵌了 `next`/`prev`*。
`Link` 就是"嵌在最前两个字段"这个约定的类型标记。于是：

- 节点的地址就是元素的地址，不需要额外分配。
- 元素只能属于一个链表（除非你自己维护多份 `Link` 字段）。
- 遍历靠 `(Link *)var)->next` 强转，*类型安全完全依赖命名约定*。

5.2 用 `ListBaseT<T>` 把最后一点补上了
（#src("source/blender/makesdna/DNA_listBase.h:48-L52")）：

```cpp
/**
 * This is a thin wrapper around #ListBase to make it type-safe. It's designed to be used in DNA
 * structs. It is written as untyped #ListBase in .blend files for compatibility.
 */
template<typename T> struct ListBaseT : public ListBase {
```

"写在 `.blend` 文件里仍是无类型 `ListBase`"这句是关键：
*类型安全是纯 C++ 层面的，磁盘格式没有变*。所以这个改造不需要版本迁移。

`ListBaseT<T>` 带来的直接好处是可以写 range-for，以及一批便利方法：

```cpp
// source/blender/makesdna/DNA_listBase.h:54-L96（节选，方法签名）
bool is_empty() const;      // 第 54 行
bool is_single() const;     // 第 60 行
void clear_no_delete();     // 第 68 行
void free_no_destruct();    // 第 77 行
int count() const;          // 第 89 行
ListBaseTIterator<T> begin() const;  // 第 100 行
ListBaseTIterator<T> end() const;    // 第 105 行
```

除了 `begin()`/`end()`，还有四个方向/可变性组合的遍历器，声明在
#src("source/blender/makesdna/DNA_listBase.h:111-L146")：

#figure(
  kind: table,
  table(
    columns: (1.2fr, 1.3fr, 1.5fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*表达式*], [*返回类型*], [*用途*]),
    [`list`], [`ListBaseTIterator<T>`], [正向只读遍历，`for (const T &x : list)`],
    [`list.enumerate()`], [`ListBaseEnumerateWrapper<T>`], [带下标的遍历，`for (auto [i, x] : list.enumerate())`],
    [`list.items_mutable()`], [`ListBaseMutableWrapper<T>`], [遍历时允许删除当前项],
    [`list.items_reversed()`], [`ListBaseBackwardWrapper<T>`], [反向遍历],
    [`list.items_reversed_mutable()`], [`ListBaseMutableBackwardWrapper<T>`], [反向且可删],
  ),
  caption: [`ListBaseT<T>` 的五种遍历方式。实现见 #src("source/blender/blenlib/BLI_listbase_iterator.hh")],
) <tbl-listbase-iter>

#pitfall[
  有一件事必须提前说清楚，否则你会照着老教程写出编译不过的代码：
  *`LISTBASE_FOREACH` 宏在 5.2 的源码里已经不再是公开 API。*
  它现在只作为 #src("source/blender/blenlib/intern/listbase.cc:25-L28") 的
  文件内私有辅助而存在：

  ```cpp
  #define LISTBASE_FOREACH(type, var, list) \
    for (type var = (type)((list)->first); var != nullptr; var = (type)(((Link *)(var))->next))
  #define LISTBASE_FOREACH_BACKWARD(type, var, list) \
    for (type var = (type)((list)->last); var != nullptr; var = (type)(((Link *)(var))->prev))
  ```

  你*看不到*这两个宏在别的 .cc 文件里被使用。写新代码用 `ListBaseT<T>` 的 range-for。
]

`BLI_listbase.h` 里仍然保留着完整的 C 风格链表操作函数 —— 它们没有废弃，
因为 C 代码和历史调用点还在用。清单如下（均出自
#src("source/blender/blenlib/BLI_listbase.h")）：

#figure(
  kind: table,
  table(
    columns: (1.35fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*作用*]),
    [`BLI_addtail`], [146], [加到尾部],
    [`BLI_addhead`], [169], [加到头部],
    [`BLI_remlink`], [152], [摘除（不释放）],
    [`BLI_remlink_safe`], [156], [摘除；不在链上时返回 `false` 而不是崩],
    [`BLI_freelinkN`], [242], [摘除并 `MEM_delete_void` 释放该节点],
    [`BLI_freelistN`], [142], [释放整条链表的所有节点],
    [`BLI_listbase_clear`], [297], [`first`/`last` 置空，*不*释放],
    [`BLI_listbase_count`], [238], [计数（O(n)）],
    [`BLI_listbase_is_empty`], [—†], [判空],
    [`BLI_findindex`], [26], [求下标，找不到返回 -1],
    [`BLI_findstringindex`], [32], [按字符串匹配求下标],
    [`BLI_insertlinkbefore`], [174], [插到指定节点之前],
    [`BLI_insertlinkafter`], [179], [插到指定节点之后],
    [`BLI_insertlinkreplace`], [187], [原位替换],
    [`BLI_listbase_move_index`], [213], [按下标移动],
    [`BLI_listbase_link_move`], [207], [按步长移动某节点],
    [`BLI_listbase_swaplinks`], [247], [交换两个节点],
    [`BLI_movelisttolist`], [258], [把 src 整体接到 dst 尾部],
    [`BLI_duplicatelist`], [275], [深拷贝整表（按位复制节点）],
    [`BLI_listbase_reverse`], [276], [反转],
    [`BLI_listbase_rotate_first`], [280], [把某节点转到首位],
    [`BLI_listbase_rotate_last`], [284], [把某节点转到末位],
    [`BLI_listbase_sort`], [194], [排序，传入比较函数],
    [`BLI_listbase_validate`], [306], [调试用校验],
    [`BLI_genericNodeN`], [328], [把裸指针包成 `LinkData`],
  ),
  caption: [`BLI_listbase.h` 中的 C 风格链表 API。† `is_empty` 是 `ListBaseT<T>` 的成员，不在 C API 里],
) <tbl-listbase-c-api>

#warn[
  `BLI_remlink` 和 `BLI_freelinkN` 的区别只有一步，但后果差别很大：
  前者只是从链上摘下来（你自己负责释放或复用），后者顺手释放。
  最常见的崩溃是"用 `BLI_remlink` 摘下来、加入另一条链、然后把旧表 `BLI_freelistN` 掉了"。
  另外 `BLI_freelistN` 释放的是节点本身，如果节点里还持有别的 `MEM_new` 出来的指针，
  你得先自己遍历释放。
]

还有一个类型安全的查找辅助，它是模板函数而非宏
（#src("source/blender/blenlib/BLI_listbase.h:376-L377")）：

```cpp
template<typename T, typename Fn>
T *BLI_listbase_find(const ListBaseT<T> &listbase, Fn &&predicate)
```

另外 #src("source/blender/blenlib/BLI_listbase_wrapper.hh") 提供了
`ListBaseWrapper` 风格的旧式包装器，属于历史遗留，新代码不必再用。

=== 10.2.3 `Span`：传参的默认选择

`Span<T>` 是"某处有一段连续的 `T`，我不拥有它"的表示。
定义在 #src("source/blender/blenlib/BLI_span.hh:74")，配套的
`MutableSpan<T>` 在 #src("source/blender/blenlib/BLI_span.hh:447")。
内部就两个字段（#src("source/blender/blenlib/BLI_span.hh:85-L86")）：

```cpp
const T *data_ = nullptr;
int64_t size_ = 0;
```

它的核心成员函数签名（均在 #src("source/blender/blenlib/BLI_span.hh")）：

#figure(
  kind: table,
  table(
    columns: (auto, auto),
    inset: 6pt,
    align: (left, right),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*行号*]),
    [`constexpr int64_t size() const`], [256],
    [`constexpr bool is_empty() const`], [264],
    [`constexpr const T &first() const`], [319],
  ),
  caption: [`Span<T>` 的关键成员。`MutableSpan<T>` 的对应成员在 499 / 515 / 685 行],
) <tbl-span-members>

#figure(
  kind: table,
  table(
    columns: (auto, auto, auto),
    inset: 6pt,
    align: (left, right, right),
    stroke: 0.4pt + luma(78%),
    table.header([*容器头文件*], [*类声明行*], [*是否推荐新代码使用*]),
    [`BLI_span.hh`], [74 / 447], [是],
    [`BLI_vector.hh`], [76], [是，动态数组首选],
    [`BLI_array.hh`], [50], [是，定长数组],
    [`BLI_map.hh`], [129], [是],
    [`BLI_set.hh`], [106], [是],
    [`BLI_string_ref.hh`], [49 / 136 / 154], [是，只读字符串首选],
  ),
  caption: [本章涉及的 `blender::` 容器与其声明位置],
) <tbl-container-decls>

`Span` 之所以出现频次最高（表 <tbl-container-counts>），
是因为它把"函数该收什么参数"这个问题变简单了：
*收 `Span<const T>`，调用方可以传 `Vector`、`Array`、C 数组、`std::vector` 的 `.data()`+长度。*
这就是 `BLI_math_geom.hh` 里能看到
`bool isect_point_poly(const float2 &pt, Span<float2> verts)`
（#src("source/blender/blenlib/BLI_math_geom.hh:339")）这种签名的原因。

#tip[
  `Span` 不延长被引用对象的生命周期，它只是一对指针。所以
  `Span<const int> s = some_vector.as_span();` 之后如果 `some_vector` 被释放或扩容，
  `s` 立刻悬垂。需要长期保存的场合请持有 `Vector`，只在调用边界上借出 `Span`。
]

=== 10.2.4 `Vector` 与内联缓冲

`Vector` 的定义在 #src("source/blender/blenlib/BLI_vector.hh:76")，
模板参数有三个（#src("source/blender/blenlib/BLI_vector.hh:57-L75")）：

```cpp
template<
    /** Type of the values stored in this vector. It has to be movable. */
    typename T,
    /**
     * The number of values that can be stored in this vector, without doing a heap allocation.
     * ...
     */
    int64_t InlineBufferCapacity = default_inline_buffer_capacity(sizeof(T)),
    /**
     * The allocator used by this vector. Should rarely be changed, except when you don't want that
     * MEM_* is used internally.
     */
    typename Allocator = GuardedAllocator>
class Vector {
```

第二个参数是*内联缓冲容量*，默认值由 `default_inline_buffer_capacity(sizeof(T))`
按元素大小算出。内部成员可以直接看到这个缓冲（#src("source/blender/blenlib/BLI_vector.hh:102-L103")）：

```cpp
/** A placeholder buffer that will remain uninitialized until it is used. */
BLI_NO_UNIQUE_ADDRESS TypedBuffer<T, InlineBufferCapacity> inline_buffer_;
```

也就是说，一个 `Vector<int>` 在小于内联容量时*完全不碰堆*。
这是 Blender 大量使用 `Vector` 而不是 `std::vector` 的主要理由之一：
函数里临时收集十几个元素的场景太常见，每次都 `malloc` 是实打实的开销。

关键成员函数（均出自 #src("source/blender/blenlib/BLI_vector.hh")）：

#figure(
  kind: table,
  table(
    columns: (auto, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*行号*], [*说明*]),
    [`Span<T> as_span() const`], [390], [借出视图，零拷贝],
    [`void reserve(int64_t)`], [405], [预留容量],
    [`void resize(int64_t)`], [418], [改变大小，新元素默认构造],
    [`void resize(int64_t, const T &)`], [439], [改变大小并填充],
    [`void append(const T &)`], [498], [尾插（拷贝）],
    [`void append(T &&)`], [502], [尾插（移动）],
    [`void append_non_duplicates(const T &)`], [537], [尾插但去重 —— 线性查找，仅适合小规模],
    [`void append_unchecked(const T &)`], [549], [不检查容量，调用方须已 `reserve`],
    [`void append_n_times(const T &, int64_t n)`], [569], [重复插入 n 次],
    [`void extend(Span<T>)`], [595], [拼接一批],
    [`void extend(const T *start, int64_t amount)`], [599], [拼接裸指针区间],
    [`void extend_non_duplicates(Span<T>)`], [626], [拼接并去重],
    [`int64_t size() const`], [780], [元素数],
    [`bool is_empty() const`], [792], [是否为空],
    [`void remove_last()`], [801], [弹出尾部],
    [`void remove_and_reorder(int64_t)`], [829], [O(1) 删除：与末尾元素交换],
    [`void remove_first_occurrence_and_reorder(const T &)`], [847], [同上，按值找],
    [`void remove(int64_t index)`], [860], [删除单个（保序，O(n)）],
    [`void remove(int64_t start, int64_t amount)`], [879], [删除一段],
  ),
  caption: [`Vector` 的常用成员。注意 `remove_and_reorder` 与 `remove` 的性能差异],
) <tbl-vector-members>

还有一个 `RawVector`（#src("source/blender/blenlib/BLI_vector.hh:1160-L1161")）：

```cpp
template<typename T, int64_t InlineBufferCapacity = default_inline_buffer_capacity(sizeof(T))>
using RawVector = Vector<T, InlineBufferCapacity, RawAllocator>;
```

它绕开 `guardedalloc`，用于*静态存储期*对象。为什么静态对象要绕开？
因为静态对象的构造早于/晚于 `guardedalloc` 的初始化都可能发生，
而 `guardedalloc` 的分配器切换要求"在任何分配之前"完成。

#pitfall[
  一个非常容易出错的地方：*`Vector<T>` 的元素地址在扩容后会变。*
  和 `std::vector` 一样，`append` 可能触发重新分配。
  所以不要把 `&vec[0]` 或 `vec.first()` 的地址存进别的结构里长期使用。
  需要稳定地址就用 `ListBaseT`，或者提前 `reserve` 到一个确定不会再增长的容量并
  在注释里写明这个不变量。
]

=== 10.2.5 `Map`、`Set`、`StringRef`

`Map` 在 #src("source/blender/blenlib/BLI_map.hh:129")，`Set` 在
#src("source/blender/blenlib/BLI_set.hh:106")。两者的核心 API：

#figure(
  kind: table,
  table(
    columns: (1.5fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*行号*], [*语义*]),
    [`Map::add_new(key, value)`], [265], [插入；键已存在时*断言失败*],
    [`Map::add_new_as(key, value)`], [282], [同上，转发参数避免构造临时对象],
    [`Map::contains(key)`], [353], [存在性检查（不做插入）],
    [`Map::remove(key)`], [368], [返回是否真的删掉了],
    [`Map::size()` / `is_empty()`], [976 / 986], [元素数 / 判空],
    [`Map::clear()`], [1038], [清空],
    [`Map::clear_and_keep_capacity()`], [1051], [清空但保留桶数组],
    [`Set::contains(key)`], [310], [存在性检查],
    [`Set::contains_as(key)`], [314], [同上，异构查找],
    [`Set::remove(key)`], [404], [删除],
    [`Set::size()` / `is_empty()`], [606 / 614], [元素数 / 判空],
    [`Set::clear()`], [570], [清空],
  ),
  caption: [`Map` 与 `Set` 的关键成员],
) <tbl-map-set>

`Map` 内部是开放寻址哈希表，所以有三个和 `std::unordered_map` 不同的地方：

1. *没有稳定的元素地址。* 扩容会搬移所有槽位。
2. *`add_new` 在键重复时会断言*，不像 `operator[]` 那样静默覆盖。
   想"有则更新、无则插入"就用 `lookup_or_add` 系列。
3. *遍历顺序不稳定*，且随插入/删除变化。需要确定顺序时，把 `keys()` 取出来自己排序。

`StringRef` 在 #src("source/blender/blenlib/BLI_string_ref.hh")。
基类是 `StringRefBase`（#src("source/blender/blenlib/BLI_string_ref.hh:49")），
它和 `Span` 一样只是"指针 + 长度"，不做任何拷贝：

#figure(
  kind: table,
  table(
    columns: (auto, auto),
    inset: 6pt,
    align: (left, right),
    stroke: 0.4pt + luma(78%),
    table.header([*成员*], [*行号*]),
    [`constexpr int64_t size() const`], [60],
    [`constexpr bool startswith(StringRef) const`], [99],
    [`constexpr bool endswith(StringRef) const`], [100],
    [`constexpr StringRef substr(int64_t, int64_t) const`], [101],
    [`constexpr int64_t find(char, int64_t) const`], [113],
    [`constexpr int64_t find(StringRef, int64_t) const`], [114],
    [`constexpr int64_t find_first_of(StringRef, int64_t) const`], [117],
    [`constexpr int64_t find_last_of(StringRef, int64_t) const`], [119],
  ),
  caption: [`StringRefBase` 的关键成员],
) <tbl-stringref>

两个派生类型（#src("source/blender/blenlib/BLI_string_ref.hh:136-L163")）：

- `StringRefNull` —— *保证*以 `\0` 结尾，因此提供 `c_str()`（第 146 行）。
  需要传给 C API 时用它。
- `StringRef` —— 只保证"一个指针 + 一个长度"，句尾可能不是 `\0`。
  不能直接传给 `printf` 之类。

#pitfall[
  `StringRef` 最常见的崩溃是自己把自己指向的缓冲区改掉。典型错误：

  ```cpp
  // 错误示意：s 指向 ss 的内部缓冲，ss 被销毁后 s 悬垂
  StringRef s = std::string("hello");
  ```

  头文件在 `StringRef` 的 `std::string` 构造函数处专门写了警告
  （#src("source/blender/blenlib/BLI_string_ref.hh:463-L466")，
  "Remember that when the std::string is destructed, the StringRef 会失效"）。
  `StringRef` 是*借用*语义，和 `Span` 一样。
]

*`std::string` 能用吗？* 能，而且用得不少 —— 但有一条规律：
它出现在"返回值"和"拥有型成员"的位置，不用于参数传递。
证据就在本章引用过的源码里：`wmOperatorType::get_name` 的回调签名是
`std::string (*get_name)(wmOperatorType *ot, PointerRNA *ptr)`
（#src("source/blender/windowmanager/WM_types.hh:1172")），
`StringRef` 则出现在查找、比较、传参的位置。
原因还是内联缓冲与所有权语义：返回 `std::string` 意味着"我造了一个新的、你拥有它"，
收 `StringRef` 意味着"我借用、不拷贝"。这两件事用同一种类型表达会模糊意图。

=== 10.2.6 `BLI_memory_utils.hh`：容器底下的原语

`blender::Vector` 之类的容器不直接用 `MEM_new`，而是走一层原语。
这一层暴露在 #src("source/blender/blenlib/BLI_memory_utils.hh")，
理解它有助于读懂容器的实现，也解释了"Blender 为什么敢自己写容器"。

#figure(
  kind: table,
  table(
    columns: (1.5fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*原语*], [*行号*], [*语义*]),
    [`destruct_n(T *ptr, int64_t n)`], [34], [析构 n 个对象，不释放内存],
    [`default_construct_n(T *ptr, int64_t n)`], [43], [默认构造 n 个对象],
    [`initialized_copy_n(...)`], [48], [拷贝赋值到已构造区间],
    [`uninitialized_copy_n(...)`], [53], [拷贝构造到裸内存],
    [`initialized_move_n(...)`], [64], [移动赋值到已构造区间],
    [`uninitialized_move_n(...)`], [69], [移动构造到裸内存],
    [`initialized_relocate_n(...)`], [74], [就地搬移（可用于非可移动类型）],
    [`uninitialized_relocate_n(...)`], [80], [同上，目标为裸内存],
    [`uninitialized_convert_n<From, To>(...)`], [59], [类型转换地构造],
    [`initialized_fill_n(...)`], [86], [填充已构造区间],
    [`uninitialized_fill_n(...)`], [91], [填充裸内存],
  ),
  caption: [`BLI_memory_utils.hh` 的对象生命周期原语。它们是"分配/构造/析构/释放"四件事的解耦点],
) <tbl-memory-primitives>

"标准容器语义但用 `guardedalloc` 分配"这件事，靠一个自定义删除器收口
（#src("source/blender/blenlib/BLI_memory_utils.hh:96-L111")）：

```cpp
template<typename T> struct DestructValueAtAddress {
  ...
};

template<typename T> using destruct_ptr = std::unique_ptr<T, DestructValueAtAddress<T>>;
```

`destruct_ptr<T>` 就是"用 `MEM_delete` 释放的 `unique_ptr`"。
凡是看到 `destruct_ptr`，都应该按 `unique_ptr` 的语义理解，只是释放走 Blender 的分配器。

另外几个高频工具类型：

#figure(
  kind: table,
  table(
    columns: (1.4fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*类型*], [*行号*], [*用途*]),
    [`AlignedBuffer<Size, Alignment>`], [117], [带对齐的裸字节缓冲],
    [`TypedBuffer<T, Size>`], [154], [`Vector` 的内联缓冲就是它],
    [`NoInitialization`], [226], [标签类型：跳过初始化],
    [`NoExceptConstructor`], [234], [标签类型：声明不抛异常的构造路径],
    [`assign_if_different(T &, T)`], [327], [有变化才赋值，返回是否变化 —— 依赖图标记用得多],
    [`ScopedDeferHelper<Func>`], [338], [作用域退出时执行 —— Blender 版的 scope guard],
    [`copy_assign_container(...)`], [284], [容器拷贝赋值的共同实现],
    [`move_assign_container(...)`], [301], [容器移动赋值的共同实现],
  ),
  caption: [`BLI_memory_utils.hh` 中的工具类型],
) <tbl-memory-tools>

`assign_if_different` 值得单独记住（#src("source/blender/blenlib/BLI_memory_utils.hh:327")）：
它在依赖图里被反复用来"只在真的变了的时候才打脏标记"。
没有它，每次属性求值都会触发一次全量重建。

```cpp
template<typename T> inline bool assign_if_different(T &old_value, T new_value)
```

== 10.3 数学库：`float3`、`float4x4`、欧拉与四元数

=== 10.3.1 `VecBase<T, Size>` 与那些别名

数学库最大的设计决定是*用一个模板撑起所有向量类型*，
而 `float3` 这些只是别名。类型定义在
#src("source/blender/blenlib/BLI_math_vector_types.hh")：

```cpp
// source/blender/blenlib/BLI_math_vector_types.hh:783-L790（节选）
using float1 = VecBase<float, 1>;
using float2 = VecBase<float, 2>;
using float3 = VecBase<float, 3>;
using float4 = VecBase<float, 4>;

using double2 = VecBase<double, 2>;
using double3 = VecBase<double, 3>;
using double4 = VecBase<double, 4>;
```

整数与字符版本也一并生成（#src("source/blender/blenlib/BLI_math_vector_types.hh:759-L781")）：
`char2..char4`、`uchar2..uchar4`、`int2..int4`、`uint2..uint4`、
`short2..short4`、`ushort2..ushort4`。

`VecBase` 的类声明在 #src("source/blender/blenlib/BLI_math_vector_types.hh:201")。
它继承自一个"按类型是否 trivial 选择基类"的辅助
（#src("source/blender/blenlib/BLI_math_vector_types.hh:24-L40")）：

```cpp
template<typename T, int Size, bool is_trivial_type> struct vec_struct_base {
};

template<typename T> struct vec_struct_base<T, 1, false> {
  T x;
};
```

这个设计的目的是：对 `float3` 这类平凡类型，`VecBase<float, 3>` 的布局
*就是一个 `float[3]`*，可以直接和 C 数组互操作、可以 `reinterpret_cast` 进 DNA 结构体。
对非平凡类型则走另一个基类（#src("source/blender/blenlib/BLI_math_vector_types.hh:59-L127")），
以便挂上 swizzle 成员函数。别名 `base_type` 在
#src("source/blender/blenlib/BLI_math_vector_types.hh:208")。

#warn[
  因为 `float3` 与 `float[3]` 布局相同，源码里充满了这种转换：
  `*reinterpret_cast<float3 *>(v)` 或 `float3(*v)`。这很方便，也非常容易写错 ——
  *一次误转不会编译失败，只会读到垃圾值或越界*。
  凡是做这种转换，先确认目标指针的对齐与长度。
]

=== 10.3.2 向量运算函数

所有运算都是自由函数，位于 `blender::math` 命名空间（头文件在顶部用
`namespace math { ... }` 展开，见 #src("source/blender/blenlib/BLI_math_vector.hh")）。
常用的如下：

#figure(
  kind: table,
  table(
    columns: (1.7fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*说明*]),
    [`dot(a, b)`], [425], [点积],
    [`cross(a, b)`], [543 / 557], [叉积；2D 版返回标量，3D 版返回向量],
    [`cross_high_precision(a, b)`], [565], [高精度叉积，用于大坐标],
    [`cross_poly(Span<T>)`], [578], [多边形的 Newell 法求法向],
    [`normal_tri(v1, v2, v3)`], [618], [三角形法向（已归一化）],
    [`length_squared(a)`], [446], [长度平方 —— 比较距离时用它，避免开方],
    [`length(a)`], [451], [长度],
    [`length_manhattan(a)`], [437], [L1 长度],
    [`distance(a, b)`], [480], [距离],
    [`distance_squared(a, b)`], [474], [距离平方],
    [`normalize(v)`], [537], [归一化；零向量时结果未定义，见下],
    [`normalize_and_get_length(v, &len)`], [521], [归一化并返回原长度],
    [`interpolate(a, b, t)`], [631], [线性插值],
    [`midpoint(a, b)`], [642], [中点],
    [`reflect(incident, normal)`], [486], [反射],
    [`refract(incident, normal, eta)`], [494], [折射],
    [`project(p, normal)`], [511], [投影到法向方向],
    [`faceforward(v, n, n_ref)`], [652], [按参考法向翻转],
    [`orthogonal(v)`], [733 / 751], [求一个正交向量],
    [`dominant_axis(a)`], [662], [绝对值最大的分量下标],
    [`reduce_max` / `reduce_min` / `reduce_add` / `reduce_mul`], [671 / 685 / 699 / 711], [归约],
    [`average(a)`], [723], [分量平均],
    [`is_equal(a, b, eps)`], [760], [带容差比较],
    [`almost_equal_relative(a, b, eps)`], [25], [相对误差比较],
    [`is_unit_scale(v)`], [457], [是否为单位长度的容差检查],
    [`safe_divide(a, b)`], [336 / 346], [除零安全的除法],
    [`safe_sqrt(a)`], [384], [负数安全的开方],
    [`floored_mod(a, b)`], [201 / 213], [Python 语义的取模],
    [`clamp(a, min, max)`], [119 / 131], [夹取],
    [`min(a, b)` / `max(a, b)`], [57 / 88], [分量极值；也有接受 `Span` 的重载],
  ),
  caption: [`BLI_math_vector.hh` 中的常用自由函数],
) <tbl-vector-funcs>

#warn[
  注意 `safe_*` 家族的意图：Blender 的求值路径上"某个长度恰好为 0"
  是*正常输入*而不是异常，所以 `normalize()`（#src("source/blender/blenlib/BLI_math_vector.hh:537")）
  本身不做保护，而 `safe_divide`、`safe_sqrt`、`safe_rcp` 做了。
  写求值代码时，如果你的输入可能退化成零长度，用 `normalize_and_get_length`
  拿到长度后自己判断，比事后 `isnan` 检查更可靠。
]

=== 10.3.3 矩阵：`float4x4` 与 `float3x3`

矩阵类推在 #src("source/blender/blenlib/BLI_math_matrix_types.hh")。
别名（#src("source/blender/blenlib/BLI_math_matrix_types.hh:1016-L1035")）：

```cpp
using float2x2 = MatBase<float, 2, 2>;
using float2x3 = MatBase<float, 2, 3>;
using float2x4 = MatBase<float, 2, 4>;
using float3x2 = MatBase<float, 3, 2>;
using float3x3 = MatBase<float, 3, 3>;
using float3x4 = MatBase<float, 3, 4>;
using float4x2 = MatBase<float, 4, 2>;
using float4x3 = MatBase<float, 4, 3>;
using float4x4 = MatBase<float, 4, 4>;
```

配套的还有"视图"类型，用来零拷贝包装裸 C 数组
（#src("source/blender/blenlib/BLI_math_matrix_types.hh:1028-L1029")）：

```cpp
using float4x4_view = MatView<float, 4, 4, 4, 4, 0, 0, alignof(float)>;
using float4x4_mutableview = MutableMatView<float, 4, 4, 4, 4, 0, 0, alignof(float)>;
```

`MatBase` 里有一个受保护的关键细节：*存储是按列存的 C 数组*
（#src("source/blender/blenlib/BLI_math_matrix_types.hh:168")）：

```cpp
using c_style_mat = T[NumCol][NumRow];
```

而头文件顶部注释说明了为什么不加 padding
（#src("source/blender/blenlib/BLI_math_matrix_types.hh:73")）：
"This is in order to avoid padding when using arrays of matrices."
这直接关系到 DNA 里矩阵字段的布局 —— 一个 `float mat[4][4]` 和一个 `float4x4`
是逐字节等价的，可以互相 `view()`。

`MatBase` 的类型别名（#src("source/blender/blenlib/BLI_math_matrix_types.hh:77-L81")）：

```cpp
using base_type = T;
using vec3_type = VecBase<T, 3>;
using col_type = VecBase<T, NumRow>;
using row_type = VecBase<T, NumCol>;
using loc_type = VecBase<T, (NumRow < NumCol) ? NumRow : (NumRow - 1)>;
```

数学函数都在 #src("source/blender/blenlib/BLI_math_matrix.hh") 的 `math` 命名空间里：

#figure(
  kind: table,
  table(
    columns: (1.75fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*说明*]),
    [`invert(mat, bool &r_success)`], [28], [求逆，报告是否成功（不抛异常）],
    [`pseudo_invert(mat, &success)`], [169], [伪逆，用于不可逆矩阵],
    [`transpose(mat)`], [34], [转置],
    [`normalize(mat)`], [40], [归一化各列],
    [`from_scale<MatT>(scale)`], [188], [从缩放构造],
    [`from_rotation<MatT>(rotation)`], [194], [从任意旋转类型构造],
    [`from_loc_rot<MatT>(loc, rot)`], [206], [位置 + 旋转],
    [`from_loc_rot_scale<MatT>(loc, rot, scale)`], [220], [位置 + 旋转 + 缩放],
    [`to_scale(mat)`], [336 / 338], [提取缩放],
    [`to_loc_rot_scale(mat, ...)`], [351 / 360], [分解为位置/欧拉/缩放],
    [`to_loc_rot_scale_safe(mat, ..., &ok)`], [1401], [分解，容忍剪切等非法情形],
    [`transform_point(mat, p)`], [375–396], [变换点（含平移）],
    [`project_point(mat, p)`], [417], [投影（含透视除法）],
    [`transform_points(transform, ...)`], [1817], [批量变换，`Span` 接口],
  ),
  caption: [`BLI_math_matrix.hh` 中的常用函数。矩阵乘法直接用 `operator*`],
) <tbl-matrix-funcs>

`from_rotation` 支持全部旋转表示，靠重载区分
（#src("source/blender/blenlib/BLI_math_matrix.hh:608-L626")）：
`AngleRadianBase`、`EulerXYZBase`、`Euler3Base`、`QuaternionBase`、
`DualQuaternionBase`、`CartesianBasis`、`AxisAngleBase`。
实例化声明在 #src("source/blender/blenlib/BLI_math_matrix.hh:1169-L1180")，
列出了所有被显式实例化的 `float` 组合 —— 读这个列表就能知道
"实际被用到的是哪几种转换"。

#tip[
  用 `float3x3` 还是 `float4x4`？规律是：
  *方向、法向、纯旋转* 用 `float3x3`；*需要平移的坐标变换* 用 `float4x4`。
  混合使用时要显式转换：`float3x3(mat)` 会截取左上 3×3，`float4x4(mat33)` 会补上单位平移。
  两者都不会"自动"帮你做正确的事。
]

=== 10.3.4 旋转：欧拉、四元数、轴角、角度单位

这一块在 Blender 5.x 经历了大改造，命名和过去很不一样。
类型分散在四个头文件里：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.5fr, 1.2fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*头文件*], [*关键类型*], [*备注*]),
    [`BLI_math_angle_types.hh`], [`AngleRadian` / `AngleCartesian`], [强类型角度，见下],
    [`BLI_math_euler_types.hh`], [`EulerXYZ` / `Euler3`], [`Euler3` 带 `EulerOrder`],
    [`BLI_math_quaternion_types.hh`], [`Quaternion` / `DualQuaternion`], [—],
    [`BLI_math_axis_angle_types.hh`], [`AxisAngle` / `AxisAngleCartesian`], [—],
    [`BLI_math_rotation.hh`], [一堆 `to_*` 转换函数], [—],
    [`BLI_math_rotation_legacy.hh`], [旧式 `float[3]` / `float[4]` 接口], [迁移期兼容层],
  ),
  caption: [旋转相关的头文件与类型],
) <tbl-rotation-types>

*角度是强类型的。* `AngleRadian` 与 `AngleCartesian` 是两个不同的类型
（#src("source/blender/blenlib/BLI_math_angle_types.hh:723-L724")）：

```cpp
using AngleRadian = AngleRadianBase<float>;
using AngleCartesian = AngleCartesianBase<float>;
```

`AngleRadian` 内部存弧度值，`AngleCartesian` 内部存 sin/cos 对。
后者是为了避免在热路径上反复调用三角函数，注释里的理由是
"Still costly but faster than using `atan()`"
（#src("source/blender/blenlib/BLI_math_angle_types.hh:298")）。
同一个文件在 #src("source/blender/blenlib/BLI_math_angle_types.hh:261") 还留了一条
"有意不实现"的说明，防止有人不小心到处用 `atan`。

#pitfall[
  这一条最容易吃亏：*`AngleRadian` 不能隐式从 `float` 构造*（构造函数是私有的）。
  所以 `EulerXYZ(float3(1.0f, 0.0f, 0.0f))` 这类写法在 5.x 里不成立，
  你会看到代码里到处都是 `DEG2RADF(90.0f)` 或 `M_PI_2` 包一层。
  这是故意的 —— 老代码里"这个 `float` 到底是度还是弧度"的 bug 太多。
]

欧拉有两套。`EulerXYZ` 是*固定 XYZ 顺序*的（#src("source/blender/blenlib/BLI_math_euler_types.hh:135")），
`Euler3` 带一个运行期的顺序字段（#src("source/blender/blenlib/BLI_math_euler_types.hh:203-L208")）：

```cpp
template<typename T> struct Euler3Base : public EulerBase<T> {
  using AngleT = AngleRadianBase<T>;
  ...
  EulerOrder order_;
```

顺序枚举在 #src("source/blender/blenlib/BLI_math_euler_types.hh:39")。头文件的注释
（#src("source/blender/blenlib/BLI_math_euler_types.hh:13-L26")）解释了取舍：
`EulerXYZ` 用在*明确知道顺序*的内部计算，`Euler3` 用在*需要保留用户设置顺序*的场合
（例如一个物体的 `rotation_euler` 是可见、可改的，必须记住顺序）。

四元数（#src("source/blender/blenlib/BLI_math_quaternion_types.hh:36-L332")）：

```cpp
template<typename T> struct QuaternionBase {
  ...
};

using Quaternion = QuaternionBase<float>;
using DualQuaternion = DualQuaternionBase<float>;
```

转换函数在 #src("source/blender/blenlib/BLI_math_rotation.hh")，且都有显式实例化声明
（#src("source/blender/blenlib/BLI_math_rotation.hh:481-L496")）：

```cpp
extern template EulerXYZ to_euler(const AxisAngle &);
extern template EulerXYZ to_euler(const AxisAngleCartesian &);
extern template EulerXYZ to_euler(const Quaternion &);
extern template Euler3 to_euler(const Quaternion &, EulerOrder);
extern template Quaternion to_quaternion(const AxisAngle &);
extern template Quaternion to_quaternion(const AxisAngleCartesian &);
extern template Quaternion to_quaternion(const Euler3 &);
extern template Quaternion to_quaternion(const EulerXYZ &);
extern template AxisAngleCartesian to_axis_angle(const Euler3 &);
extern template AxisAngleCartesian to_axis_angle(const EulerXYZ &);
extern template AxisAngleCartesian to_axis_angle(const Quaternion &);
```

另外有一组 `rotate` 重载（#src("source/blender/blenlib/BLI_math_rotation.hh:34-L61")），
语义是"把旋转 `a` 再叠加旋转 `b`"。它们内部会做必要的类型提升，
例如欧拉版本的实现是"转成矩阵乘完再转回欧拉"
（#src("source/blender/blenlib/BLI_math_rotation.hh:207-L210")）。
*这就是为什么连续旋转不该用欧拉表示*：一次叠加就要走两趟转换，还有万向锁。

#summary[
  数学库的实用选择顺序：

  - 内部计算、不需要用户看见 ⇒ *四元数或矩阵*。
  - 需要和用户/动画曲线/RNA 交互 ⇒ *欧拉*（并且必须保留顺序，用 `Euler3`）。
  - 只做方向、不需要平移 ⇒ *`float3x3`*。
  - 做坐标变换 ⇒ *`float4x4`*。
  - 角度一律用 `AngleRadian` / `DEG2RADF`，不要在脑子里记"这里是度还是弧度"。
]

=== 10.3.5 几何工具

几何相关的自由函数在 #src("source/blender/blenlib/BLI_math_geom.hh")
（新式、类型安全，基于 `VecBase`）与 #src("source/blender/blenlib/BLI_math_geom.h")（旧式 `float[3]` 接口）。

#figure(
  kind: table,
  table(
    columns: (1.8fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*说明*]),
    [`normal_quad(v1, v2, v3, v4)`], [32], [四边形法向],
    [`area_tri(v1, v2, v3)`], [44], [三角形面积],
    [`cotangent_tri_weight(v1, v2, v3)`], [56], [余切权重，用于拉普拉斯算子],
    [`plane_from_point_normal(co, normal)`], [81], [由点与法向构造平面 `float4`],
    [`plane_point_side(plane, co)`], [94], [点相对平面的有符号距离],
    [`closest_to_line_segment(p, l1, l2)`], [110], [点到线段最近点],
    [`dist_squared_to_line_segment(p, l1, l2)`], [134], [点到线段距离平方],
    [`closest_to_plane(plane, co)`], [161], [点到平面最近点],
    [`dist_squared_to_plane(co, plane)`], [176], [点到平面距离平方],
    [`line_point_factor(p, l1, l2)`], [199], [点在直线上的参数 t],
    [`axis_dominant_to_m3(normal)`], [224], [由法向构造正交基],
    [`isect_line_line(...)`], [249], [两直线交点],
    [`isect_line_plane(...)`], [266], [线面交点，返回 `std::optional<float3>`],
    [`isect_point_tri(pt, ...)`], [287], [点是否在三角形内],
    [`isect_point_quad(p, ...)`], [313], [点是否在四边形内],
    [`isect_point_poly(pt, Span<float2>)`], [339], [点是否在多边形内],
    [`barycentric_weights(...)`], [355], [重心坐标],
    [`poly_to_tri_count(poly_count, corner_count)`], [382], [三角化后的面数上界],
    [`area_poly(Span<float2>)`], [390], [多边形面积],
    [`interp_weights_poly(...)`], [403], [多边形重心插值权重],
    [`interp_bilinear_quad(...)`], [438], [四边形双线性插值],
    [`map_to_sphere(co)`], [461], [单位球坐标映射，用于环境贴图采样],
  ),
  caption: [`BLI_math_geom.hh` 中的常用几何函数],
) <tbl-geom-funcs>

注意 `isect_line_plane` 的返回类型是 `std::optional<float3>`
（#src("source/blender/blenlib/BLI_math_geom.hh:266")）。
这是无异常约定的一个具体体现：*平行、退化、无解都通过返回值表达*，
而不是抛异常或返回一个"不可能的坐标"。

#note[
  这里的 `std::optional` 用得很规范：`isect_line_plane` 会返回
  `std::nullopt` 表示"没有交点"，调用方必须显式处理。
  对比一下那些返回 `bool` + 输出参数的老接口（例如
  `invert(mat, bool &r_success)`），两者都合规，
  新代码偏向 `std::optional`。
]

== 10.4 字符串、文件、路径与日志

=== 10.4.1 字符串：`BLI_string.h`

字符串工具在 #src("source/blender/blenlib/BLI_string.h")（700 行）。
一条重要规律：*这里的绝大多数函数是"就地修改调用方提供的缓冲区"，而不是返回新字符串。*
缓冲区长度用 `maxncpy` 语义（尺寸含结尾 `\0`）。

#figure(
  kind: table,
  table(
    columns: (1.9fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*说明*]),
    [`BLI_strdupn(str, len)`], [53], [按长度复制，返回 `MEM_new` 出来的新串],
    [`BLI_strdup(str)`], [62], [复制到新分配内存],
    [`BLI_strdup_null(str)`], [71], [`nullptr` 安全版],
    [`BLI_strdupcat(str1, str2)`], [79], [拼接并返回新串],
    [`BLI_strncpy(dst, src, maxncpy)`], [91], [安全复制，保证结尾 `\0`],
    [`BLI_strncpy_rlen(dst, src, maxncpy)`], [120], [同上，返回写入长度],
    [`BLI_strncat(dst, src, maxncpy)`], [124], [安全拼接],
    [`BLI_snprintf(dst, maxncpy, fmt, ...)`], [180], [安全格式化],
    [`BLI_sprintfN(fmt, ...)`], [222], [格式化到新分配内存],
    [`BLI_str_escape(dst, src, maxncpy)`], [240], [转义],
    [`BLI_str_unescape(dst, src, maxncpy)`], [276], [反转义],
    [`BLI_str_format_int_grouped(dst[15], num)`], [297], [千分位格式化，缓冲区尺寸有宏],
    [`BLI_str_format_byte_unit(dst[15], ...)`], [321], [字节单位格式化],
    [`BLI_strcaseeq(a, b)`], [399], [大小写无关相等],
    [`BLI_strcasecmp(a, b)`], [409], [大小写无关比较],
    [`BLI_strcasecmp_natural(s1, s2)`], [416], [自然序比较（`file2` < `file10`）],
    [`BLI_strnlen(str, maxlen)`], [432], [有界 `strlen`],
    [`BLI_str_tolower_ascii(str, len)`], [438], [就地转小写],
    [`BLI_str_startswith(str, ...)`], [497], [前缀检查],
    [`BLI_str_endswith(str, end)`], [506], [后缀检查],
    [`BLI_str_partition(...)`], [520], [按分隔符切分，返回三段],
    [`BLI_string_find_split_words(...)`], [572], [按词切分（搜索用）],
  ),
  caption: [`BLI_string.h` 中的常用函数],
) <tbl-string-funcs>

几个必须有尺寸的格式化函数，其目标缓冲区大小被定义成宏
（#src("source/blender/blenlib/BLI_string.h:24-L42")）：

```cpp
#define BLI_STR_FORMAT_UINT64_GROUPED_SIZE 27
#define BLI_STR_FORMAT_INT64_GROUPED_SIZE 28
#define BLI_STR_FORMAT_INT32_GROUPED_SIZE 15
#define BLI_STR_FORMAT_INT64_BYTE_UNIT_SIZE 15
#define BLI_STR_FORMAT_INT64_BYTE_UNIT_COMPACT_SIZE 5
#define BLI_STR_FORMAT_INT32_DECIMAL_UNIT_SIZE 7
#define BLI_STR_FORMAT_INT32_INTEGER_UNIT_SIZE 5
```

用这种方式声明缓冲区（数组尺寸从宏来，不会写错）：

```cpp
char numstr[BLI_STR_FORMAT_INT32_GROUPED_SIZE];
BLI_str_format_int_grouped(numstr, 1234567);
```

还有两个极高频的宏（#src("source/blender/blenlib/BLI_string.h:605-L609")）：

```cpp
#define STRNCPY_RLEN(dst, src) BLI_strncpy_rlen(dst, src, ARRAY_SIZE(dst))
#define SNPRINTF(dst, format, ...) BLI_snprintf(dst, ARRAY_SIZE(dst), format, __VA_ARGS__)
#define SNPRINTF_RLEN(dst, format, ...) ...
#define VSNPRINTF(dst, format, args) BLI_vsnprintf(dst, ARRAY_SIZE(dst), format, args)
```

`ARRAY_SIZE` 在宏里自动求出，所以 `STRNCPY(dst, src)` 不会写错尺寸。
*这是 Blender C 代码里最该学会的两个宏*：凡是往定长数组里拷字符串，
先找 `STRNCPY` / `SNPRINTF`，不要手写 `strncpy(dst, src, sizeof(dst) - 1)`。

还有一批长度宏，用在函数签名里表达"这个参数必须够大"
（#src("source/blender/blenlib/BLI_string.h:605-L609") 附近，以及
`BLI_strncpy_ensure_pad` 等签名上的 `ATTR_NONNULL`）：
看到 `char dst[/*MAX_ID_NAME*/ 258]` 这种写法，意思是"运行时我无法检查，
但至少注释告诉你需要多大"。

=== 10.4.2 路径：`BLI_path_utils.hh`

路径工具在 #src("source/blender/blenlib/BLI_path_utils.hh")。
和字符串一样，绝大多数是*就地修改* `char *path`。

#figure(
  kind: table,
  table(
    columns: (1.9fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*说明*]),
    [`BLI_path_is_unc(path)`], [41], [UNC 路径判断（Windows）],
    [`BLI_path_is_win32_drive(path)`], [43], [盘符判断],
    [`BLI_path_parent_dir(path)`], [61], [上跳一级，就地修改],
    [`BLI_path_make_safe_filename_ex(name, allow_tokens)`], [121], [非法字符替换],
    [`BLI_path_make_safe(path)`], [133], [路径安全化],
    [`BLI_path_to_display_name(...)`], [141], [转为显示用名称],
    [`BLI_path_normalize(path)`], [172], [规范化 `/./` `\..\` 等],
    [`BLI_path_normalize_native(path)`], [181], [同上，用本机分隔符],
    [`BLI_path_normalize_dir(dir, maxncpy)`], [190], [目录版本],
    [`BLI_path_canonicalize_native(path, maxncpy)`], [217], [解析为绝对规范路径],
    [`BLI_path_filename_ensure(filepath, maxncpy, filename)`], [229], [确保路径以指定文件名为结尾],
    [`BLI_path_suffix(path, maxncpy, suffix, sep)`], [244], [加后缀（如 `_001`）],
    [`BLI_path_slash_find(path)`], [256], [找第一个分隔符],
    [`BLI_path_slash_rfind(path)`], [260], [找最后一个分隔符],
    [`BLI_path_slash_ensure(path, maxncpy)`], [272], [确保结尾有分隔符],
    [`BLI_path_slash_rstrip(path)`], [276], [去掉结尾分隔符],
    [`BLI_path_slash_native(path)`], [284], [分隔符转本机风格],
    [`BLI_path_split_dir_file(...)`], [296], [拆成目录 + 文件名],
    [`BLI_path_split_dir_part(...)`], [304], [只取目录部分],
    [`BLI_path_split_file_part(...)`], [311], [只取文件名部分],
    [`BLI_path_basename(path)`], [320], [取基名（不修改原串，返回值指向原串内部）],
    [`BLI_path_append(dst, maxncpy, file)`], [343], [拼接并加分隔符],
    [`BLI_path_join(...)`], [381], [变参宏，多段拼接，见下],
    [`BLI_path_extension_or_end(filepath)`], [477], [返回扩展名起点或串尾],
    [`BLI_path_extension(filepath)`], [483], [返回扩展名（含点）],
    [`BLI_path_extension_check(path, ext)`], [488], [后缀检查],
    [`BLI_path_extension_replace(path, maxncpy, ext)`], [516], [替换扩展名],
    [`BLI_path_extension_strip(path)`], [522], [去掉扩展名],
    [`BLI_path_extension_ensure(path, maxncpy, ext)`], [526], [确保扩展名正确],
    [`BLI_path_frame(path, maxncpy, frame, digits)`], [623], [把 `#` 替换成帧号],
    [`BLI_path_frame_get(path, &frame, &digits_len)`], [636], [从路径解析帧号],
    [`BLI_path_frame_check_chars(path)`], [648], [是否含 `#` 占位],
    [`BLI_path_abs(path, basepath)`], [686], [相对路径转绝对，就地修改],
    [`BLI_path_rel(path, basepath)`], [691], [绝对路径转相对（加 `//` 前缀）],
    [`BLI_path_is_abs_from_cwd(path)`], [710], [是否是从 CWD 起算的绝对路径],
    [`BLI_path_abs_from_cwd(path, maxncpy)`], [719], [相对 CWD 转绝对],
  ),
  caption: [`BLI_path_utils.hh` 中的常用函数。该模块只有这一个头文件，没有对应的同名 `.h`],
) <tbl-path-funcs>

`BLI_path_join` 是个变参宏，派发到 `_BLI_path_join_3` 到 `_BLI_path_join_12`
（#src("source/blender/blenlib/BLI_path_utils.hh:381")，各实现见
#src("source/blender/blenlib/BLI_path_utils.hh:394-L450")）：

```cpp
#define BLI_path_join(...) VA_NARGS_CALL_OVERLOAD(_BLI_path_join_, __VA_ARGS__)
```

也就是说它支持 3 到 12 个参数，形式是 `BLI_path_join(dst, maxncpy, p1, p2, ...)`。
底层实现 `BLI_path_join_array` 在 #src("source/blender/blenlib/intern/path_utils.cc:1707")。

#warn[
  路径函数的"就地修改"约定有几个必须记住的后果：

  1. *缓冲区必须够大。* 签名里的 `FILE_MAX` 是硬约束
     （例如 `bool BLI_path_abs(char path[FILE_MAX], const char *basepath)`，
     #src("source/blender/blenlib/BLI_path_utils.hh:686")）。
     传一个 `char[64]` 进去会越界写，而且不会有任何运行时检查。
  2. *返回值常常是"成功与否"而不是新路径。* `BLI_path_abs` 改的是 `path` 本身。
  3. *`BLI_path_basename` 返回指向原串内部的指针*（#src("source/blender/blenlib/BLI_path_utils.hh:320")）。
     原串失效或被改，返回值立刻失效。

  相对路径的 `//` 前缀是 Blender 特有的：它表示"相对于当前 `.blend` 文件"，
  会存在文件里、在别的机器上照样有效。转换方向由
  `BLI_path_abs`（→ 绝对）与 `BLI_path_rel`（→ 相对）负责。
]

=== 10.4.3 日志：`CLOG_` 宏

日志库叫 clog（C Logging），位于 #src("intern/clog/")，
只有两个文件：#src("intern/clog/CLG_log.h")（206 行）与 #src("intern/clog/clog.cc")。

头文件的用法说明（#src("intern/clog/CLG_log.h:11-L28")）：

```
 * Usage
 * -----
 *
 * - `CLG_LOGREF_DECLARE_GLOBAL` macro to declare #CLG_LogRef pointers.
 * - `CLOG_` prefixed macros for logging.
 *
 * Identifiers
 * -----------
 *
 * #CLG_LogRef holds an identifier which defines the category of the logger.
 * ...
 * By convention lower case dot separated identifiers are used, eg:
 * `module.sub_module`, this allows filtering by `module.*`,
```

所以第一步是*声明一个日志类别*。使用方式是：

```cpp
// 在某处（通常是对应的 .cc 或 .hh）
CLG_LOGREF_DECLARE_GLOBAL(MY_LOG_THING, "mymodule.thing");
```

真实例子（#src("source/blender/windowmanager/intern/wm_init_exit.cc:122-L126")）：

```cpp
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_OPERATORS, "operator");
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_EVENTS, "event");
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_TOOL_GIZMO, "tool.gizmo");
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_MSGBUS_PUB, "msgbus.pub");
CLG_LOGREF_DECLARE_GLOBAL(WM_LOG_MSGBUS_SUB, "msgbus.sub");
```

宏本身（#src("intern/clog/CLG_log.h:138-L141")）：

```cpp
/** Declare outside function, declare as extern in header. */
#define CLG_LOGREF_DECLARE_GLOBAL(var, id) \
  static CLG_LogRef _static_##var = {id}; \
  CLG_LogRef *var = &_static_##var
```

第二步是*用 `CLOG_*` 宏打日志*。级别枚举在 #src("intern/clog/CLG_log.h:52-L65")：

```cpp
enum CLG_Level {
  /* Similar to assert. This logs the message, then a stack trace and abort. */
  CLG_LEVEL_FATAL = 0,
  /* An error we can recover from, should not happen. */
  CLG_LEVEL_ERROR = 1,
  /* General warnings (which aren't necessary to show to users). */
  CLG_LEVEL_WARN = 2,
  /* Information about devices, files, configuration, user operations. */
  CLG_LEVEL_INFO = 3,
  /* Debugging information for developers. */
  CLG_LEVEL_DEBUG = 4,
  /* Very verbose code execution tracing. */
  CLG_LEVEL_TRACE = 5,
};
```

宏清单（#src("intern/clog/CLG_log.h:186-L206")）：

#figure(
  kind: table,
  table(
    columns: (1.6fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*宏*], [*行号*], [*说明*]),
    [`CLOG_FATAL(ref, fmt, ...)`], [187], [打日志 + 栈回溯；通常随后 abort],
    [`CLOG_ERROR(ref, fmt, ...)`], [188], [错误，可恢复],
    [`CLOG_WARN(ref, fmt, ...)`], [189], [警告],
    [`CLOG_INFO(ref, fmt, ...)`], [190], [信息（文件、配置、用户操作）],
    [`CLOG_DEBUG(ref, fmt, ...)`], [191], [开发者调试信息],
    [`CLOG_TRACE(ref, fmt, ...)`], [192], [极详细执行追踪],
    [`CLOG_STR_FATAL / _ERROR / _WARN / _INFO / _DEBUG / _TRACE`], [195–200], [同上，但直接给一个字符串而不是格式串],
    [`CLOG_INFO_NOCHECK(ref, fmt, ...)`], [204], [无视过滤与级别，只被 `CLG_quiet_set` 抑制],
    [`CLOG_STR_INFO_NOCHECK(ref, str)`], [206], [同上，字符串版],
  ),
  caption: [`CLOG_` 宏家族。`ref` 是 `CLG_LogRef *`，所以要写 `&MY_LOG_THING` 或 `WM_LOG_OPERATORS`（后者本身就是指针）],
) <tbl-clog-macros>

真实用法（#src("source/blender/blenloader/intern/readfile.cc:3709-L3710")）：

```cpp
CLOG_INFO(&LOG, "Read file %s", fd->relabase);
```

以及在操作符登记失败时的用法（#src("source/blender/windowmanager/intern/wm_operator_type.cc:126")）：

```cpp
CLOG_ERROR(WM_LOG_OPERATORS, "Operator '%s' has no name property", ot->idname);
```

注意这里直接写了 `WM_LOG_OPERATORS` 而没有取地址 —— 因为
`CLG_LOGREF_DECLARE_GLOBAL` 声明出来的变量本身就是 `CLG_LogRef *`。

关键实现细节：*日志只在级别通过时才求值*。
`CLOG_AT_LEVEL` 展开后先检查 `_lg_ty->level >= verbose_level`
（#src("intern/clog/CLG_log.h:150-L157")）：

```cpp
#define CLOG_AT_LEVEL(clg_ref, verbose_level, ...) \
  { \
    const CLG_LogType *_lg_ty = CLOG_ENSURE(clg_ref); \
    if (_lg_ty->level >= verbose_level) { \
      CLG_logf(_lg_ty, verbose_level, __FILE__ ":" STRINGIFY(__LINE__), __func__, __VA_ARGS__); \
    } \
  } \
  ((void)0)
```

`CLOG_ENSURE` 负责*惰性初始化*（#src("intern/clog/CLG_log.h:144-L145")）：

```cpp
#define CLOG_ENSURE(clg_ref) \
  ((clg_ref)->type ? (clg_ref)->type : (CLG_logref_init(clg_ref), (clg_ref)->type))
```

所以你可以随处声明 `CLG_LOGREF_DECLARE_GLOBAL` 而不必关心初始化顺序 ——
第一次真正打日志时才建 `CLG_LogType`。

控制接口（#src("intern/clog/CLG_log.h:99-L130")）：

#figure(
  kind: table,
  table(
    columns: (1.7fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*用途*]),
    [`CLG_init()` / `CLG_exit()`], [100 / 101], [会话级初始化与销毁],
    [`CLG_output_set(void *file_handle)`], [103], [输出重定向到文件句柄],
    [`CLG_output_use_source_set(int)`], [104], [输出是否带文件名],
    [`CLG_output_use_basename_set(int)`], [105], [是否只输出基名],
    [`CLG_output_use_timestamp_set(int)`], [106], [是否带时间戳],
    [`CLG_output_use_memory_set(int)`], [107], [是否输出内存地址],
    [`CLG_error_fn_set(fn)`], [108], [ERROR 级时的回调],
    [`CLG_fatal_fn_set(fn)`], [109], [FATAL 级时的回调],
    [`CLG_backtrace_fn_set(fn)`], [110], [栈回溯输出回调],
    [`CLG_type_filter_include(match, len)`], [112], [包含某类别，支持 `module.*`],
    [`CLG_type_filter_exclude(match, len)`], [113], [排除某类别],
    [`CLG_level_set(CLG_Level)`], [115], [全局级别],
    [`CLG_logref_list_all(cb, user_data)`], [120], [列出所有已注册类别],
    [`CLG_quiet_set(bool)` / `CLG_quiet_get()`], [129 / 130], [抑制 NOCHECK 日志],
  ),
  caption: [`CLG_*` 控制接口],
) <tbl-clog-controls>

`CLG_init()` 被调用的位置在 #src("source/creator/creator.cc:439") 的注释
"Initialize logging." 下面。这就是为什么你可以在启动参数里控制日志 ——
参数解析发生在 `CLG_init()` 之前。

#tip[
  调试某个模块时，最快的办法是加一条日志过滤器而不是重编译：

  ```bash
  $ blender --log "operator.*" --log-level 3
  ```

  类别名就是你 `CLG_LOGREF_DECLARE_GLOBAL` 里写的那个字符串
  （`CLG_type_filter_include` 支持 `*` 通配，见
  #src("intern/clog/CLG_log.h:112-L113") 附近以及头文件 24-26 行的说明）。
  另一个有用的组合是 `--debug-exit-on-error`（§10.1.4），
  它让任何 `CLOG_ERROR` 直接变成非零退出码。
]

== 10.5 断言、错误处理与异常边界

=== 10.5.1 `BLI_assert` 家族

断言在 #src("source/blender/blenlib/BLI_assert.h")（120 行）。
在非 `NDEBUG` 构建下（#src("source/blender/blenlib/BLI_assert.h:45-L59")）：

```cpp
#  define BLI_assert(a) \
    (void)((!(a)) ? ((_BLI_assert_print_backtrace(), \
                      _BLI_ASSERT_PRINT_POS(a), \
                      _BLI_ASSERT_ABORT(), \
                      NULL)) : \
                    NULL)
/** A version of #BLI_assert() to pass an additional message to be printed on failure. */
#  define BLI_assert_msg(a, msg) \
    (void)((!(a)) ? ((_BLI_assert_print_backtrace(), \
                      _BLI_ASSERT_PRINT_POS(a), \
                      _BLI_ASSERT_EXTRA(msg), \
                      _BLI_ASSERT_ABORT(), \
                      NULL)) : \
                    NULL)
```

在 `NDEBUG` 下两者都变成 `((void)0)`（#src("source/blender/blenlib/BLI_assert.h:61-L62")）。
*这意味着断言里的表达式在发布构建中完全不求值*，所以断言里不能放有副作用的调用。

`_BLI_ASSERT_ABORT` 还受一个编译开关控制
（#src("source/blender/blenlib/BLI_assert.h:39-L44")）：

```cpp
#  ifdef WITH_ASSERT_ABORT
#    define _BLI_ASSERT_ABORT _BLI_assert_abort
#  else
#    define _BLI_ASSERT_ABORT() (void)0
#  endif
```

也就是说，默认的调试构建只*打印*断言失败并附栈回溯，不会真的 abort。
要做崩溃式调试，需要用 `-DWITH_ASSERT_ABORT=ON` 构建
（或者挂调试器在 `_BLI_assert_print_pos` 上断点）。

其余断言工具：

#figure(
  kind: table,
  table(
    columns: (1.9fr, auto, 1.4fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*工具*], [*行号*], [*说明*]),
    [`BLI_assert(a)`], [46], [条件断言，失败时打印位置 + 栈回溯],
    [`BLI_assert_msg(a, msg)`], [53], [同上，附自定义消息],
    [`BLI_STATIC_ASSERT(a, msg)`], [67], [编译期断言（C++ 走 `static_assert`）],
    [`BLI_STATIC_ASSERT_ALIGN(st, align)`], [86], [结构体对齐检查],
    [`BLI_assert_unreachable()`], [93], [标记不可达；debug 下 abort，release 下打印错误],
    [`BLI_assert_unreachable_static()`], [107], [编译期不可达检查（C++20 惯用法）],
    [`BLI_assert_unreachable_static_t(T)`], [117], [同上，把类型名带进错误信息],
  ),
  caption: [`BLI_assert.h` 提供的断言工具],
) <tbl-asserts>

`BLI_assert_unreachable_static` 的实现值得一提（#src("source/blender/blenlib/BLI_assert.h:107-L118")）：

```cpp
#  define BLI_assert_unreachable_static() \
    static_assert([]<bool flag = false>() { return flag; }(), \
                  "Unreachable code path reached at compile-time!")

template<class T> inline constexpr bool _bli_always_false = false;

#  define BLI_assert_unreachable_static_t(T) \
    static_assert(_bli_always_false<T>, "Unreachable code path reached at compile-time!")
```

为什么不用 `static_assert(false)`？注释直接回答了：
"Just doing `static_assert(false)` doesn't work in C++20 for this use-case."
因为 `static_assert(false)` 在模板里会无条件失败，即使该分支从未被实例化。
用依赖模板参数的 `_bli_always_false<T>` 才能做到"只有真的实例化了才失败"。

#pitfall[
  三个关于断言的实操要点：

  1. *断言不是错误处理。* `BLI_assert` 表达的是"这是程序员的错，
     不该发生"；用户能触发的非法输入必须走 `BKE_report` 之类。
     把用户输入校验写成 `BLI_assert`，发布版里就会静默带着坏数据继续跑。
  2. *`BLI_assert` 里的表达式在 release 会被删掉。*
     `BLI_assert(do_something())` 是 bug。
  3. *默认不 abort。* 如果你在调试一个"断言刷屏但程序继续跑"的问题，
     那不是断言没生效，而是 `WITH_ASSERT_ABORT` 没开。
]

=== 10.5.2 异常不是常规错误通道

Blender 的核心 C++ 路径通常*不把异常作为常规错误处理机制*。这不是说代码库里
完全没有 `throw` / `catch`：例如资产表示会抛出 `std::invalid_argument`
（#src("source/blender/asset_system/intern/asset_representation.cc:63")），OBJ 导出会在
文件错误时抛出并就地捕获 `std::system_error`
（#src("source/blender/io/wavefront_obj/exporter/obj_export_file_writer.cc:68")、
#src("source/blender/io/wavefront_obj/exporter/obj_exporter.cc:284")），BLI 容器也包含
用于异常安全的捕获与重抛。更准确的约定是：*异常应限制在明确的局部边界内，
不能穿过 C ABI，也不应成为求值与交互主路径的普通分支。* 原因包括：

- *跨 C ABI 边界抛异常是未定义行为。* Blender 有大量 C 代码、
  以及 Python C API、GPU 后端、第三方 C 库（OpenEXR、OpenSubdiv、FFmpeg 等）。
  异常穿过这些边界会直接崩，且栈信息毫无意义。
- *求值路径上"失败"是常态。* 一个几何节点遇到空网格不是异常情况。
- *异常会让代码路径不可预测。* 求值器需要"我确定这里不会跳走"才能推理资源状态。

那么失败怎么表达？源码里有四种模式，都在本章前面出现过：

#figure(
  kind: table,
  table(
    columns: (1.25fr, 1.5fr, 1.35fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*模式*], [*真实例子*], [*何时用*]),
    [返回 `std::optional<T>`],
    [`isect_line_plane`（#src("source/blender/blenlib/BLI_math_geom.hh:266")）],
    [无解或解不存在是正常结果],
    [返回 `bool` + 输出参数],
    [`invert(mat, bool &r_success)`（#src("source/blender/blenlib/BLI_math_matrix.hh:28")）],
    [结果总是有、只是可能失败，且输出参数尺寸大],
    [返回错误枚举],
    [`eUndoPushReturn`（#src("source/blender/blenkernel/BKE_undo_system.hh:102-L107")）],
    [多种成败状态需要区分],
    [写进 `ReportList`],
    [`BKE_report(CTX_wm_reports(C), RPT_OPERATOR, ...)`（#src("source/blender/windowmanager/intern/wm_event_system.cc:1335")）],
    [需要把消息给用户看，且调用栈很深],
  ),
  caption: [Blender 中表达失败的四种方式],
) <tbl-error-modes>

`eUndoPushReturn` 是"错误枚举"模式的典型（#src("source/blender/blenkernel/BKE_undo_system.hh:102-L107")）：

```cpp
enum eUndoPushReturn {
  UNDO_PUSH_RET_FAILURE = 0,
  UNDO_PUSH_RET_SUCCESS = (1 << 0),
  UNDO_PUSH_RET_OVERRIDE_CHANGED = (1 << 1),
};
ENUM_OPERATORS(eUndoPushReturn)
```

注意它同时表达了"成功"和"成功但有额外情况"（`OVEERRIDE_CHANGED`），
这是 `bool` 表达不了的。`ENUM_OPERATORS` 宏让这些值支持 `|` 与 `&` 运算。

#summary[
  写 C++ 改动时的错误处理清单：

  1. *一般业务与求值路径不要把异常作为常规失败通道。* 对接会抛异常的库时，
     在明确边界内捕获并转换为返回值、报告或日志；不要用 `catch (...)` 静默吞掉问题。
  2. *不要用 `BLI_assert` 校验用户输入。* 用返回值或 `BKE_report`。
  3. *可失败的操作优先返回 `std::optional`。* 它比 `bool + out param` 更难用错
     （因为调用方必须写 `.value()` 或 `*`，也就必须面对"可能没有"这件事）。
  4. *需要给用户看的消息走 `ReportList`。*
     操作符里的 `op->reports` 就是它，见 §11.1。
  5. *需要给开发者看的消息走 `CLOG_*`。* 两者不要混用：
     日志不会出现在界面上，报告不该用来刷日志。
]

#exercise[
  *练习 10.1 —— 用 `guardedalloc` 做一次真正的泄漏定位。*

  1. 在 `source/blender/blenkernel/intern/object.cc` 里找一个
     你确定不会被 release 的路径（例如 `BKE_object_add_only_object` 之后的对象创建），
     人为插入一处 `MEM_new_zeroed<Object>(__func__)` 并*故意不释放*。
     注意：不要真的改坏现有逻辑，插在一个不会被调用的位置即可。
  2. 用 `blender -d` 启动，然后退出。观察退出时打印的
     `Error: Not freed memory blocks: ...` 与随后的 `MEM_printmemlist()` 输出，
     确认你的分配名称（也就是 `__func__` 的值）出现在列表里。
  3. 再启动一次，加上 `--debug-exit-on-error`，用
     `echo $LASTEXITCODE`（PowerShell）确认退出码非零。
  4. 阅读 #src("intern/guardedalloc/intern/leak_detector.cc") 全文（93 行），
     用自己的话说明为什么 `mem_clearmemlist()` 必须在打印*之后*调用。
     提示：想想 LeakSanitizer 会怎么看待那个全局块列表。
  5. 最后删掉你插入的那一行，确认泄漏报告恢复干净。

  *练习 10.2 —— 把一段 `ListBase` 遍历改成 `ListBaseT<T>` 风格。*

  1. 在 `source/blender/blenkernel/intern/object.cc` 里找一个使用
     `ListBase *` 或 `ListBaseT<T>` 的循环。
  2. 如果它已经是 C 风格指针遍历，改写成 `ListBaseT<T>` 的 range-for。
     参考 #src("source/blender/makesdna/DNA_listBase.h:100-L146") 的五种遍历器，
     根据是否需要下标、是否需要边遍历边删，选正确的那一种。
  3. 编译通过后，用 `git diff` 检查你的改动是不是*只改了遍历形式*。
     如果你发现自己动了别的地方，说明原来的循环有隐含副作用，回去读清楚。
  4. 思考题：为什么 `LISTBASE_FOREACH` 宏在 5.2 里是 #src("source/blender/blenlib/intern/listbase.cc")
     的文件内私有宏（#src("source/blender/blenlib/intern/listbase.cc:25-L28")）？
     提示：注意那个宏展开里 `list` 参数被用了两次。
]
