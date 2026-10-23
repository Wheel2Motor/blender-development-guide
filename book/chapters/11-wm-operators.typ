#import "../common.typ": *
#import "../figures/wm-chain.typ": fig-wm-chain

= 第 11 章 操作符、事件与窗口系统（WM）

第 10 章讲的是"工具"。本章讲的是"流程"。

当你按下 `G`，Blender 内部发生的事情大致是：一个按键事件被派发、被某个键盘映射匹配、
解析出一个操作符类型、通过 `poll` 检查、执行、改数据、发出通知、界面重绘、
把这一步压进撤销栈。这条链上的每一环都可以被你替换或插入新东西 ——
而这也正是"改 C++ 源码"里收益最高的一类改动。

本章按这条链的顺序展开。§11.1、§11.3 和 §11.4 是重点。

== 11.1 `wmOperatorType` 与 `wmOperator`

#figure(fig-wm-chain(), caption: [事件 → 操作符 → 执行 → 通知 → 撤销 的完整链路。实线为主链路，虚线为撤销回灌与静态查找路径。]) <fig-wm-chain>

=== 11.1.1 两个结构体，一件事

理解操作符制度的关键，是分清两个名字很像的结构体：

- *`wmOperatorType`* —— 类型。描述"这个操作符是什么、能做什么"。
  全局唯一，在启动时静态注册，*不进 `.blend` 文件*。
- *`wmOperator`* —— 实例。描述"这一次调用"。
  带属性、带报告列表、带运行时状态，*可以被保存*（"调整上一步操作"面板就靠它）。

用面向对象的说法：`wmOperatorType` 是类，`wmOperator` 是对象。
本节的其余部分都在展开这两句话。

先看定义位置：

#figure(
  kind: table,
  table(
    columns: (1.15fr, 1.7fr, auto),
    inset: 6pt,
    align: (left, left, right),
    stroke: 0.4pt + luma(78%),
    table.header([*结构体*], [*文件*], [*起始行*]),
    [`wmOperatorType`], [#src("source/blender/windowmanager/WM_types.hh")], [1082],
    [`wmOperator`], [#src("source/blender/makesdna/DNA_windowmanager_types.h")], [486],
    [`wmOperatorTypeMacro`], [#src("source/blender/makesdna/DNA_windowmanager_types.h")], [279],
    [`wmOperatorCallParams`], [#src("source/blender/windowmanager/WM_types.hh")], [1224],
  ),
  caption: [操作符相关结构体的定义位置。注意 `wmOperator` 在 DNA 里（因为它要存进文件），`wmOperatorType` 不在],
) <tbl-op-structs>

`wmOperatorType` 的真实字段

`wmOperatorType` 在 #src("source/blender/windowmanager/WM_types.hh:1082-L1218")。
它的回调字段*全部有默认值 `= nullptr`*，所以定义一个操作符时只需填你要用的那几个。
按声明顺序列出（这是本章最该记住的一张表）：

#figure(
  kind: table,
  table(
    columns: (1.55fr, auto, 1.6fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段*], [*行号*], [*含义*]),
    [`const char *name`], [1090], [界面与撤销里显示的名字，不要超过 `OP_MAX_TYPENAME`],
    [`const char *idname`], [1092], [唯一标识符，形如 `WM_OT_window_close`],
    [`const char *translation_context`], [1094], [i18n 上下文],
    [`const char *description`], [1096], [工具提示与 Python 文档],
    [`const char *undo_group`], [1098], [把若干操作符合并成一个撤销组的标识],
    [`wmOperatorStatus (*exec)(bContext *, wmOperator *)`], [1106], [无交互执行；不能用界面代码或输入设备状态],
    [`bool (*check)(bContext *, wmOperator *)`], [1114], [属性变化时校验；返回 `true` 表示需要重绘],
    [`wmOperatorStatus (*invoke)(bContext *, wmOperator *, const wmEvent *)`], [1122], [交互式启动],
    [`void (*cancel)(bContext *, wmOperator *)`], [1130], [模态被取消时的清理（少用）],
    [`wmOperatorStatus (*modal)(bContext *, wmOperator *, const wmEvent *)`], [1138], [模态持续处理事件],
    [`bool (*poll)(bContext *)`], [1146], [能否在当前上下文执行],
    [`bool (*poll_property)(const bContext *, wmOperator *, const PropertyRNA *)`], [1152], [属性是否该显示在自动 UI 里],
    [`void (*ui)(bContext *, wmOperator *)`], [1157], [自定义"调整上一步"面板],
    [`bool (*ui_poll)(wmOperatorType *, PointerRNA *)`], [1162], [是否调用 `ui`],
    [`std::string (*get_name)(wmOperatorType *, PointerRNA *)`], [1172], [按属性值动态取名（源码注释说明它目前多数场合不生效）],
    [`std::string (*get_description)(bContext *, wmOperatorType *, PointerRNA *)`], [1178], [按属性值动态取描述],
    [`bool (*depends_on_cursor)(bContext &, wmOperatorType &, PointerRNA *)`], [1181], [`OPTYPE_DEPENDS_ON_CURSOR` 的动态版],
    [`StructRNA *srna`], [1184], [属性用的 RNA 结构 —— 属性就挂在这上面],
    [`IDProperty *last_properties`], [1187], [上次运行的设置，用于复用],
    [`PropertyRNA *prop`], [1196], [通用 `invoke` 用的默认属性（如下拉菜单的 `type`）],
    [`ListBaseT<wmOperatorTypeMacro> macro`], [1199], [宏操作符的子步骤列表],
    [`wmKeyMap *modalkeymap`], [1202], [指向模态键映射，*不要*释放],
    [`bool (*pyop_poll)(bContext *, wmOperatorType *)`], [1205], [Python 操作符的 poll 包装],
    [`std::unique_ptr<TypeData> custom_data`], [1208], [类型专属的额外静态信息],
    [`ExtensionRNA rna_ext`], [1211], [RNA 集成（Python 注册的操作符走这里）],
    [`int cursor_pending`], [1213], [等待光标输入时的光标形状],
    [`short flag`], [1217], [`OPTYPE_*` 位标志],
  ),
  caption: [`wmOperatorType` 的完整字段表。"行号"列指向 #src("source/blender/windowmanager/WM_types.hh")。注意*没有* `OPERATOR_*` 字段 —— 那是返回值，不是标志],
) <tbl-wmoperatortype-fields>

这张表里有几个反直觉的点，值得单独点出来。

*第一，没有 `idname` 之外的"命名空间"字段。* `Object` 相关的操作符叫
`OBJECT_OT_xxx`、`WM` 的叫 `WM_OT_xxx`，前缀完全是命名约定。
`WM_operator_bl_idname` 只认 `_OT_` 这个分隔符
（#src("source/blender/windowmanager/intern/wm_operators.cc:128")：

```cpp
#define OP_BL_SEP_STRING "_OT_"
```

校验逻辑在 #src("source/blender/windowmanager/intern/wm_operators.cc:179-L197")，
规则是：`_OT_` 之前只允许大写字母、数字、下划线；之后只允许小写字母、数字、下划线；
分隔符不能在开头或结尾。*违反这条规则会在注册时被 `BLI_assert` 抓住*
（#src("source/blender/windowmanager/intern/wm_operator_type.cc:138")）：

```cpp
BLI_assert(WM_operator_bl_idname_is_valid(ot->idname));
```

*第二，`macro` 不是"宏定义"而是"子步骤"。* `ListBaseT<wmOperatorTypeMacro>`
（#src("source/blender/windowmanager/WM_types.hh:1199")）装的是这个操作符要依次执行的
其他操作符。这是"把一个复合动作、一次撤销、一次重做打包成一个操作符"的机制。

*第三，属性挂在 `srna` 上，不是挂在一个专门的"属性列表"字段上。*
`StructRNA *srna`（#src("source/blender/windowmanager/WM_types.hh:1184")）在注册时被创建，
之后你用 `RNA_def_int(ot->srna, ...)` 之类往上加属性。
看一个真实例子（#src("source/blender/windowmanager/intern/wm_operators.cc:2206-L2216")）：

```cpp
ot->flag = OPTYPE_INTERNAL;

PropertyRNA *prop;

prop = RNA_def_string(ot->srna, "name", nullptr, BKE_ST_MAXNAME, "Name", "Name of the menu");
```

这两行说明了整个约定：*属性直接定义在 `ot->srna` 上，第一个参数永远是它*。

`wmOperator` 的真实字段

实例结构体在 #src("source/blender/makesdna/DNA_windowmanager_types.h:486-L516")，
只有 30 行，完整抄录如下：

```cpp
struct wmOperator {
  struct wmOperator *next = nullptr, *prev = nullptr;

  /* saved */
  /** Used to retrieve type pointer. */
  char idname[/*OP_MAX_TYPENAME*/ 64] = "";
  /** Saved, user-settable properties. */
  IDProperty *properties = nullptr;

  /* runtime */
  /** Operator type definition from idname. */
  struct wmOperatorType *type = nullptr;
  /** Custom storage, only while operator runs. */
  void *customdata = nullptr;
  /** Python stores the class instance here. */
  void *py_instance = nullptr;

  /** Rna pointer to access properties. */
  struct PointerRNA *ptr = nullptr;
  /** Errors and warnings storage. */
  struct ReportList *reports = nullptr;

  /** List of operators, can be a tree. */
  ListBaseT<wmOperator> macro = {nullptr, nullptr};
  /** Current running macro, not saved. */
  struct wmOperator *opm = nullptr;
  /** Runtime for drawing. */
  ui::Layout *layout = nullptr;
  eOperator_Flag flag = {};
  char _pad[6] = {};
};
```

源码里的注释 `/* saved */` 与 `/* runtime */` 是理解它的关键：

- *会被写进 `.blend` 的*：`idname`（用来自动重建 `type` 指针）与 `properties`。
  这就是为什么 `wmOperator` 定义在 DNA 里 —— 它必须有一个稳定的磁盘布局。
- *纯运行时的*：`type`、`customdata`、`py_instance`、`ptr`、`reports`、
  `macro` 的链表本身、`opm`、`layout`、`flag`。

`eOperator_Flag` 是*实例级*的标志，和 `wmOperatorType::flag`（`OPTYPE_*`）不是一回事。
定义在 #src("source/blender/makesdna/DNA_windowmanager_enums.h:47-L73")：

#figure(
  kind: table,
  table(
    columns: (1.7fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*标志*], [*值*], [*含义*]),
    [`OP_IS_INVOKE = (1 << 0)`], [52], [exec() 被调用时能判断"我是被 invoke 进来的"，见 smooth-view],
    [`OP_IS_REPEAT = (1 << 1)`], [54], [由"调整上一步操作"触发],
    [`OP_IS_REPEAT_LAST = (1 << 2)`], [63], [由 `SCREEN_OT_repeat_last` 触发],
    [`OP_IS_MODAL_GRAB_CURSOR = (1 << 3)`], [66], [光标已被抓取],
    [`OP_IS_MODAL_CURSOR_REGION = (1 << 4)`], [72], [让模态操作符以光标所在区域为上下文],
  ),
  caption: [`eOperator_Flag`（`wmOperator::flag`）的取值。它是运行期状态，不进文件],
) <tbl-operator-flags>

返回值：`wmOperatorStatus`

回调的返回值是一个枚举，定义在 #src("source/blender/makesdna/DNA_windowmanager_enums.h:18-L32")：

```cpp
enum wmOperatorStatus {
  OPERATOR_RUNNING_MODAL = (1 << 0),
  OPERATOR_CANCELLED = (1 << 1),
  OPERATOR_FINISHED = (1 << 2),
  /** Add this flag if the event should pass through. */
  OPERATOR_PASS_THROUGH = (1 << 3),
  /** In case operator got executed outside WM code (like via file-select). */
  OPERATOR_HANDLED = (1 << 4),
  /**
   * Used for operators that act indirectly (eg. popup menu).
   * \note this isn't great design (using operators to trigger UI) avoid where possible.
   */
  OPERATOR_INTERFACE = (1 << 5),
};
ENUM_OPERATORS(wmOperatorStatus);
```

调试构建下每次回调返回都会做一次合法性检查
（#src("source/blender/makesdna/DNA_windowmanager_enums.h:38-L44")）：

```cpp
#define OPERATOR_RETVAL_CHECK(ret) \
  { \
    CHECK_TYPE(ret, wmOperatorStatus); \
    BLI_assert(ret != 0 && (ret & OPERATOR_FLAGS_ALL) == ret); \
  } \
  ((void)0)
```

`OPERATOR_PASS_THROUGH` 可以和别的值按位或，这是它存在的意义：
"我处理了这个事件，但请让系统继续把事件传下去"。
模态操作符里这很常见（比如视图旋转时仍希望滚轮缩放生效）。

#pitfall[
  三个关于返回值的常见错误：

  1. *返回 `0`。* 断言会直接抓住你（`ret != 0`）。
     `OPERATOR_CANCELLED = (1 << 1)` 而不是 `0`，正是为了防止"忘记返回"和
     "返回取消"混淆。
  2. *用 `bool` 思路理解。* `wmOperatorStatus` 不是"成功/失败"，
     而是"接下来怎么处理"。模态回调返回 `OPERATOR_RUNNING_MODAL` 表示持续；
     返回 `OPERATOR_FINISHED` 表示收工并接受结果；返回 `OPERATOR_CANCELLED`
     表示收工并丢弃。
  3. *`exec` 里做交互。* 头文件说得很明确（#src("source/blender/windowmanager/WM_types.hh:1100-L1104")）：
     exec "cannot use any interface code or input device state"。
     需要弹窗、需要读鼠标，就得写 `invoke`。
]

=== 11.1.2 注册：`WM_operatortype_append`

注册入口只有两个函数（#src("source/blender/windowmanager/WM_api.hh:1414-L1416")）：

```cpp
void WM_operatortype_append(void (*opfunc)(wmOperatorType *ot));
void WM_operatortype_append_ptr(void (*opfunc)(wmOperatorType *ot, void *userdata),
                                void *userdata);
```

#note[
  *这个签名和很多老教程不一样。* 注意回调是 `void (*)(wmOperatorType *)` ——
  它*收*一个已经分配好的 `ot` 指针，而不是返回一个 `wmOperatorType *`。
  你不再写 `static wmOperatorType *WM_OT_foo()`，而是写
  `static void WM_OT_foo(wmOperatorType *ot)`。
]

实现只有六行（#src("source/blender/windowmanager/intern/wm_operator_type.cc:151-L156")）：

```cpp
void WM_operatortype_append(void (*opfunc)(wmOperatorType *))
{
  wmOperatorType *ot = wm_operatortype_append__begin();
  opfunc(ot);
  wm_operatortype_append__end(ot);
}
```

前后两个 `__begin` / `__end` 做了所有"样板活"，非常值得读一遍，
因为*你的操作符能做什么、Python 能看到什么，全在这里决定*。
`__begin`（#src("source/blender/windowmanager/intern/wm_operator_type.cc:108-L122")）：

```cpp
static wmOperatorType *wm_operatortype_append__begin()
{
  wmOperatorType *ot = MEM_new<wmOperatorType>(__func__);

  BLI_assert(ot_prop_basic_count == -1);

  ot->srna = RNA_def_struct_ptr(&RNA_blender_rna_get(), "", RNA_OperatorProperties);
  RNA_def_struct_property_tags(ot->srna, rna_enum_operator_property_tag_items);
  /* Set the default i18n context now, so that opfunc can redefine it if needed! */
  RNA_def_struct_translation_context(ot->srna, BLT_I18NCONTEXT_OPERATOR_DEFAULT);
  ot->translation_context = BLT_I18NCONTEXT_OPERATOR_DEFAULT;
  ot->cursor_pending = WM_CURSOR_PICK_AREA;

  return ot;
}
```

`__end`（#src("source/blender/windowmanager/intern/wm_operator_type.cc:123-L147")）：

```cpp
static void wm_operatortype_append__end(wmOperatorType *ot)
{
  if (ot->name == nullptr) {
    CLOG_ERROR(WM_LOG_OPERATORS, "Operator '%s' has no name property", ot->idname);
  }
  BLI_assert((ot->description == nullptr) || (ot->description[0]));

  /* Allow calling _begin without _end in operatortype creation. */
  WM_operatortype_props_advanced_end(ot);

  /* XXX All ops should have a description but for now allow them not to. */
  RNA_def_struct_ui_text(
      ot->srna, ot->name, ot->description ? ot->description : UNDOCUMENTED_OPERATOR_TIP);
  RNA_def_struct_identifier(&RNA_blender_rna_get(), ot->srna, ot->idname);

  BLI_assert(WM_operator_bl_idname_is_valid(ot->idname));
  get_operators_map().add_new(ot);

  /* Needed so any operators registered after startup will have their shortcuts set,
   * in "register" scripts for example, see: #143838.
   *
   * This only has run-time implications when run after startup,
   * it's a no-op when run beforehand, see: #WM_keyconfig_update_on_startup. */
  WM_keyconfig_update_operatortype_tag();
}
```

从这 40 行能读出五条规则：

1. *`ot` 是 `MEM_new` 出来的*，所以注销时必须 `MEM_delete`。
   这一点在 `WM_operatortype_remove_ptr` 里能看到
   （#src("source/blender/windowmanager/intern/wm_operator_type.cc:197")：`MEM_delete(ot);`）。
2. *没写 `name` 会打 `CLOG_ERROR`* —— 这正好是 §10.4.3 讲的 clog 用法。
3. *`description` 可以是 `nullptr`，但不能是空串*（`BLI_assert`）。
   不写的话会退化成 `UNDOCUMENTED_OPERATOR_TIP`。
4. *注册表是一张哈希表*，`get_operators_map().add_new(ot)` 就是插入。
   `add_new` 在键重复时会断言，所以*同一个 `idname` 注册两次会崩*。
5. *注册完之后要通知键映射系统*（`WM_keyconfig_update_operatortype_tag()`），
   否则运行期注册的操作符拿不到快捷键。

查找则走 `WM_operatortype_find`
（#src("source/blender/windowmanager/intern/wm_operator_type.cc:78-L99")），
它有一个体贴的小设计：*同时接受 Python 风格的名字*
（#src("source/blender/windowmanager/intern/wm_operator_type.cc:80-L87")）：

```cpp
if (idname[0]) {
  /* Needed to support python style names without the `_OT_` syntax. */
  char idname_bl[OP_MAX_TYPENAME];
  WM_operator_bl_idname(idname_bl, idname);

  if (wmOperatorType *const *ot = get_operators_map().lookup_key_ptr_as(StringRef(idname_bl))) {
    return *ot;
  }
```

也就是说 `WM_operatortype_find("object.select_all")` 与
`WM_operatortype_find("OBJECT_OT_select_all")` 等价。§11.5 会讲这套名字转换的全貌。

内置操作符的注册清单在哪

`WM` 自己的操作符在 #src("source/blender/windowmanager/intern/wm_operators.cc")，
注册函数是 `wm_operatortypes_register()`：

```cpp
// source/blender/windowmanager/intern/wm_operators.cc:4233-L4240（节选）
void wm_operatortypes_register()
{
  WM_operatortype_append(WM_OT_window_close);
  WM_operatortype_append(WM_OT_window_new);
  WM_operatortype_append(WM_OT_window_new_main);
  WM_operatortype_append(WM_OT_read_history);
  WM_operatortype_append(WM_OT_read_homefile);
  WM_operatortype_append(WM_OT_read_factory_settings);
  ...
```

这个文件里有 47 处 `WM_operatortype_append` 调用。
它的声明在 #src("source/blender/windowmanager/wm.hh:75")：

```cpp
void wm_operatortypes_register();
```

调用点是 #src("source/blender/windowmanager/intern/wm_init_exit.cc:213")。
所以整个启动序列是：
`wm_init_exit.cc` 的初始化函数 → `wm_operatortypes_register()` →
一长串 `WM_operatortype_append(...)` → 每个操作符的 `WM_OT_xxx` 函数。

其他模块各有自己的注册函数，命名规律是 `operatortypes_<模块>()`。
例如 Object 模块的 `blender::ed::object::operatortypes_object()`
（#src("source/blender/editors/object/object_ops.cc:29-L31")）：

```cpp
namespace blender::ed::object {

void operatortypes_object()
{
  WM_operatortype_append(OBJECT_OT_location_clear);
  WM_operatortype_append(OBJECT_OT_rotation_clear);
```

这个文件里有 233 处 `WM_operatortype_append`。
它们被谁调用？通过每个编辑器的 `SpaceType::operatortypes` 回调链
（见 §11.6.4 与第 12 章）。

=== 11.1.3 一个完整的最小操作符

与其抽象描述，不如直接看 Blender 自己写的最小操作符
（#src("source/blender/windowmanager/intern/wm_operators.cc:2380-L2389")）：

```cpp
/* Included for script-access. */
static void WM_OT_window_close(wmOperatorType *ot)
{
  ot->name = "Close Window";
  ot->idname = "WM_OT_window_close";
  ot->description = "Close the current window";

  ot->exec = wm_window_close_exec;
  ot->poll = WM_operator_winactive;
}
```

六行，覆盖了最小必要集合。对应的 `exec` 在
#src("source/blender/windowmanager/intern/wm_window.cc:1483-L1489")：

```cpp
wmOperatorStatus wm_window_close_exec(bContext *C, wmOperator * /*op*/)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  wmWindow *win = CTX_wm_window(C);
  wm_window_close_request(C, wm, win);
  return OPERATOR_FINISHED;
}
```

`poll` 在 #src("source/blender/windowmanager/intern/wm_operators.cc:1276-L1283")：

```cpp
bool WM_operator_winactive(bContext *C)
{
  if (CTX_wm_window(C) == nullptr) {
    return false;
  }
  return true;
}
```

这份代码值得逐条拆解，因为它示范了所有约定：

#figure(
  kind: table,
  table(
    columns: (1.5fr, 1.9fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*写法*], [*为什么*]),
    [`static void WM_OT_window_close(wmOperatorType *ot)`],
    [`static`：注册函数只在同一翻译单元里按名引用。签名必须是 `void (wmOperatorType *)`],
    [`ot->name = "Close Window";`],
    [给*用户*看的名字，会被 i18n 翻译],
    [`ot->idname = "WM_OT_window_close";`],
    [给*代码*看的名字。必须与注册函数名一致（这是惯例，不是强制）],
    [`ot->description = "...";`],
    [工具提示与 Python 文档。不写会退化为 `UNDOCUMENTED_OPERATOR_TIP`],
    [`ot->exec = wm_window_close_exec;`],
    [只填需要的回调。其余字段由 `__begin` 初始化或保持 `nullptr`],
    [`ot->poll = WM_operator_winactive;`],
    [不填 `poll` 意味着"总是可以执行"，多数场合是错的],
    [注释 `/* Included for script-access. */`],
    [这个操作符同时要暴露给 Python（`bpy.ops.wm.window_close()`），所以 `__end` 里创建 `srna` 是必要的],
  ),
  caption: [`WM_OT_window_close` 逐行解释。这六行就是新增操作符的最小骨架],
) <tbl-minimal-op-walkthrough>

需要交互时会多一个 `invoke`。注意 `invoke` 与 `exec` 的签名差别只是多一个 `const wmEvent *`
（对比 #src("source/blender/windowmanager/WM_types.hh:1106") 与
#src("source/blender/windowmanager/WM_types.hh:1122")）。典型写法是
"`invoke` 先做交互准备，然后转调 `exec`"，或者"`invoke` 里注册模态处理器"（§11.2）。

=== 11.1.4 属性与 `op->customdata`：状态放哪

属性（用户可见、可保存）与自定义数据（运行时、不可保存）是两套完全不同的机制，
初学者极易混用。

*属性*挂在 `ot->srna` 上。除了 §11.1.1 里看到的 `RNA_def_string`，还有一批
`RNA_def_*`：`RNA_def_int`、`RNA_def_float`、`RNA_def_boolean`、`RNA_def_enum`、
`RNA_def_float_vector` 等。它们返回 `PropertyRNA *`，可以用
`RNA_def_property_flag(prop, PROP_SKIP_SAVE)` 之类的调用继续配置
（真实例子见 #src("source/blender/windowmanager/intern/wm_operators.cc:2209-L2212")）。

读取属性值的标准方式是先拿到 `PointerRNA`，再取字段。
操作符实例上已经有现成的指针（#src("source/blender/makesdna/DNA_windowmanager_types.h:503-L504")）：

```cpp
/** Rna pointer to access properties. */
struct PointerRNA *ptr = nullptr;
```

所以你能看到类似 `RNA_int_get(op->ptr, "some_prop")` 的调用。
`op->ptr` 由系统在调用操作符前准备好，*不要自己改它*。

*`customdata`* 是操作符自己的私货（#src("source/blender/makesdna/DNA_windowmanager_types.h:498-L499")）：

```cpp
/** Custom storage, only while operator runs. */
void *customdata = nullptr;
```

它有两个鲜明的特点：

1. *类型是 `void *`。* 类型检查完全靠程序员自律：写的时候
   `op->customdata = data;`（`data` 是 `MyGizmoData *`），
   读的时候 `MyGizmoData *data = static_cast<MyGizmoData *>(op->customdata);`。
2. *它只在操作符存活期间有效。* 操作符结束时框架会把它置为 `nullptr`
   （#src("source/blender/windowmanager/intern/wm_event_system.cc:1297")：
   `op->customdata = nullptr;`），*但不会释放它指向的内存* ——
   释放是你的责任，通常放在 `modal` 返回 `OPERATOR_FINISHED` 的分支里。

真实用法（#src("source/blender/windowmanager/xr/intern/wm_xr_operators.cc:189")）：

```cpp
op->customdata = MEM_new_zeroed<XrGrabData>(__func__);
```

#pitfall[
  `customdata` 是内存泄漏的头号来源，原因就是上面第 2 条：
  *框架清零指针，但不调用 `MEM_delete`。* 你必须在所有退出路径
  （`FINISHED`、`CANCELLED`、`cancel` 回调）上都释放它。
  惯用模式是：

  ```cpp
  // 收尾时用 MEM_SAFE_DELETE，它同时把指针置空（见 §10.1.2）
  MEM_SAFE_DELETE(data);
  op->customdata = nullptr;
  ```

  配合 `blender -d` 的泄漏报告（§10.1.4），这类问题很容易定位：
  报告里会出现你 `MEM_new` 时写的那个名字。
]

`py_instance` 是第三个位置（#src("source/blender/makesdna/DNA_windowmanager_types.h:500-L501")）：

```cpp
/** Python stores the class instance here. */
void *py_instance = nullptr;
```

它是给 Python 操作符存类实例用的，C++ 操作符不要碰。

=== 11.1.5 `reports`：给用户的消息

操作符实例自带一个报告列表（#src("source/blender/makesdna/DNA_windowmanager_types.h:505-L506")）：

```cpp
/** Errors and warnings storage. */
struct ReportList *reports = nullptr;
```

往它写消息用 `BKE_report` / `BKE_reportf`，读出来由界面负责（状态栏）。
在 `wm_operator_finished` 里能看到它如何被交接给窗口管理器
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1262-L1263")）：

```cpp
/* If the caller owns them, handle this. */
WM_reports_from_reports_move(CTX_wm_manager(C), op->reports);
```

以及调试模式下把整个操作符调用打印成 Python 调用串
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1333-L1336")）：

```cpp
if (G.debug & G_DEBUG_WM) {
  std::string pystring = WM_operator_pystring(C, op, false, true);
  BKE_report(CTX_wm_reports(C), RPT_OPERATOR, pystring.c_str());
}
```

#tip[
  这是一条非常好用的调试技巧。启动 `blender -d`（或用
  `--debug-wm`，注册在 #src("source/creator/creator_args.cc:3212")），
  然后每次用界面执行操作符，状态栏/控制台就会打印出*等效的 Python 调用串*。
  你可以直接把它复制到脚本编辑器里，这就是"把一次界面操作变成脚本"的最快方法。
]

== 11.2 事件、keymap 与模态操作符

=== 11.2.1 `wmEvent`

事件结构体在 #src("source/blender/windowmanager/WM_types.hh:795-L877")。
它同时携带"这一次事件"和"上一次的状态"，后者是拖拽检测与点击判定的基础。

#figure(
  kind: table,
  table(
    columns: (1.5fr, auto, 1.6fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段*], [*行号*], [*含义*]),
    [`wmEventType type`], [799], [事件码本身（`short`，也是键映射里的键）],
    [`short val`], [801], [按下 / 释放 / 滚轮值],
    [`int xy[2]`], [803], [鼠标屏幕坐标],
    [`int mval[2]`], [805], [区域相对坐标（Blender 2.5 前的命名）],
    [`char utf8_buf[6]`], [813], [单个 UTF-8 字符；*不保证以 `\0` 结尾*],
    [`wmEventModifierFlag modifier`], [816], [`KM_SHIFT` / `KM_CTRL` / `KM_ALT` / `KM_OSKEY` / `KM_HYPER`],
    [`int8_t direction`], [819], [方向，仅 `KM_PRESS_DRAG` 事件有效],
    [`wmEventType keymodifier`], [825], ["任意键当修饰键"的机制],
    [`wmTabletData tablet`], [828], [数位板信息],
    [`eWM_EventFlag flag`], [830], [事件标志],
    [`short custom` / `customdata_free`], [835 / 836], [自定义数据类型标记与是否需释放],
    [`void *customdata`], [849], [附属数据，类型由 `custom` 决定],
    [`wmEventType prev_type`], [854], [上一次的 `type`],
    [`short prev_val`], [856], [上一次的 `val`],
    [`int prev_xy[2]`], [862], [上一次的鼠标位置（任何移动都会更新）],
    [`wmEventType prev_press_type`], [867], [按下时的 `type`],
    [`int prev_press_xy[2]`], [872], [按下时的位置（拖拽阈值与方向计算用）],
    [`wmEventModifierFlag prev_press_modifier`], [874], [按下时的修饰键],
    [`wmEventType prev_press_keymodifier`], [876], [按下时的 `keymodifier`],
  ),
  caption: [`wmEvent` 的字段。行号指向 #src("source/blender/windowmanager/WM_types.hh")],
) <tbl-wmevent-fields>

关于 `customdata`，头文件里有一张非常有用的对照表
（#src("source/blender/windowmanager/WM_types.hh:837-L849")）：

```
   * The #wmEvent::type implies the following #wmEvent::custodata.
   *
   * - #EVT_ACTIONZONE_AREA / #EVT_ACTIONZONE_FULLSCREEN / #EVT_ACTIONZONE_FULLSCREEN:
   *   Uses #sActionzoneData.
   * - #EVT_DROP: uses #ListBaseT<wmDrag> (also #wmEvent::custom == #EVT_DATA_DRAGDROP).
   * - #EVT_FILESELECT: uses #wmOperator.
   * - #EVT_XR_ACTION: uses #wmXrActionData (also #wmEvent::custom == #EVT_DATA_XR).
   * - #NDOF_MOTION: uses #wmNDOFMotionData (also #wmEvent::custom == #EVT_DATA_NDOF_MOTION).
   * - #TIMER: uses #wmTimer (also #wmEvent::custom == #EVT_DATA_TIMER).
```

*这就是 `void *` 在 Blender 里怎么保持安全的方式*：靠一张注释表 + 一个 `custom` 标记位。
你如果引入新的事件类型，必须同时更新这张表、加一个 `EVT_DATA_*` 标记。

事件类型命名不统一，务必注意

事件类型枚举在 #src("source/blender/windowmanager/WM_event_types.hh:45")，
名叫 `wmEventType`。但里面的常量前缀*不统一*，这是历史遗留：

#figure(
  kind: table,
  table(
    columns: (1.5fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*常量*], [*行号*], [*说明*]),
    [`EVENT_NONE = 0x0000`], [47], ["非事件"，例如被禁用的定时器],
    [`LEFTMOUSE = 0x0001`], [55], [鼠标按键 —— *没有* `EVT_` 前缀],
    [`MIDDLEMOUSE = 0x0002`], [56], [同上],
    [`RIGHTMOUSE = 0x0003`], [57], [同上],
    [`MOUSEMOVE = 0x0004`], [58], [同上],
    [`WHEELUPMOUSE = 0x000a`], [72], [滚轮],
    [`MOUSEPAN = 0x000e`], [66], [触控板平移],
    [`EVT_AKEY = 0x0061`], [120], [键盘 —— *有* `EVT_` 前缀],
    [`EVT_ESCKEY = 0x00da`], [203], [Esc],
    [`EVT_RETKEY = 0x00dc`], [205], [回车],
    [`EVT_SPACEKEY = 0x00dd`], [206], [空格],
    [`TIMER = 0x0110`], [346], [定时器事件，广播给所有队列],
    [`EVT_ACTIONZONE_AREA = 0x5000`], [360], [区域边缘的"动作区"（拖拽分屏用）],
  ),
  caption: [`wmEventType` 的部分取值。注意鼠标是裸名、键盘带 `EVT_` 前缀 —— 写代码前先查这个文件],
) <tbl-event-type-names>

修饰键位与匹配值在 #src("source/blender/windowmanager/WM_types.hh:286-L351")：

```cpp
enum wmEventModifierFlag : uint8_t {
  KM_SHIFT = (1 << 0),
  KM_CTRL = (1 << 1),
  KM_ALT = (1 << 2),
  /** Use for Windows-Key on MS-Windows, Command-key on macOS and Super on Linux. */
  KM_OSKEY = (1 << 3),
  KM_HYPER = (1 << 4),
};
ENUM_OPERATORS(wmEventModifierFlag);
```

而按键映射条目里的"匹配值"是另一套常量（#src("source/blender/windowmanager/WM_types.hh:317-L329")）：

```cpp
/** #wmKeyMapItem.val */
enum {
  KM_ANY = -1,
  KM_NOTHING = 0,
  KM_PRESS = 1,
  KM_RELEASE = 2,
  KM_CLICK = 3,
  KM_DBL_CLICK = 4,
  /** 见 KM_PRESS_DRAG 注释 */
  KM_PRESS_DRAG = 5,
};
```

`KM_ANY` 表示"按下或释放都触发"，`KM_MOD_HELD`（#src("source/blender/windowmanager/WM_types.hh:335")）
是修饰键字段的"按住"值 —— 它的数值恰好等于 `KM_PRESS`，源码专门写了注释提醒
"modifiers should only be compared with `(KM_ANY, KM_NOTHING, KM_MOD_HELD)`"。
这就是一个真实的"数值巧合但语义不同"陷阱。

=== 11.2.2 keymap：`wmKeyMap` 与 `wmKeyMapItem`

键映射的定义在 DNA 里，因为它要存进用户配置（#src("source/blender/makesdna/DNA_windowmanager_types.h")）。

`wmKeyMapItem`（#src("source/blender/makesdna/DNA_windowmanager_types.h:344-L405")）的关键字段：

#figure(
  kind: table,
  table(
    columns: (1.5fr, auto, 1.6fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*字段*], [*行号*], [*含义*]),
    [`char idname[64]`], [349], [要调用的操作符 idname],
    [`IDProperty *properties`], [351], [随按键一起绑定的操作符属性],
    [`short propvalue`], [357], [模态映射里表示"哪个模态值"；非模态项为 0],
    [`char propvalue_str[64]`], [355], [模态值的字符串形式（运行期临时存储）],
    [`short type`], [361], [事件码（`wmEventType`）],
    [`int8_t val`], [363], [`KM_PRESS` / `KM_RELEASE` / `KM_CLICK` / `KM_PRESS_DRAG` 等],
    [`int8_t direction`], [368], [`KM_DIRECTION_N` 等，仅 `KM_PRESS_DRAG` 有效],
    [`int8_t shift`, `ctrl`, `alt`, `oskey`, `hyper`], [377–383], [五个修饰键各自的期望状态],
    [`short keymodifier`], [388], ["任意键当修饰键"],
    [`eKMI_Flag flag`], [391], [启用/展开等标志],
    [`eKMI_MapType maptype`], [395], [键映射属于键盘还是鼠标等],
    [`short id`], [397], [唯一标识；*正数表示覆盖内置项，负数表示内置项本身*],
    [`PointerRNA *ptr`], [404], [访问属性的 RNA 指针，`owner_id` 必须为空],
  ),
  caption: [`wmKeyMapItem` 的关键字段],
) <tbl-keymapitem-fields>

`id` 的正负号设计很巧妙（源码注释 #src("source/blender/makesdna/DNA_windowmanager_types.h:396")：
"Positive for kmi that override builtins, negative otherwise"）：
它让"内置快捷键"和"用户自定义覆盖"共存于同一条链表，
而且"恢复默认"只需删掉正数 id 的那些。

`wmKeyMap` 本身（#src("source/blender/makesdna/DNA_windowmanager_types.h:418-L443")）：

```cpp
struct wmKeyMap {
  struct wmKeyMap *next = nullptr, *prev = nullptr;

  ListBaseT<wmKeyMapItem> items = {nullptr, nullptr};
  ListBaseT<wmKeyMapDiffItem> diff_items = {nullptr, nullptr};

  /** Global editor keymaps, or for more per space/region. */
  char idname[64] = "";
  /** Same IDs as in DNA_space_types.h. */
  short spaceid = 0;
  /** See above. */
  short regionid = 0;
  /** Optional, see: #wmOwnerID. */
  char owner_id[128] = "";

  /** General flags. */
  eKeyMap_Flag flag = {};
  /** Last kmi id. */
  short kmi_id = 0;

  /* runtime */
  /** Verify if enabled in the current context, use #WM_keymap_poll instead of direct calls. */
  bool (*poll)(struct bContext *);
  bool (*poll_modal_item)(const struct wmOperator *op, int value) = {};
```

两个要点：

- `items` 与 `diff_items` 分开。`diff_items` 装的是"差异项"
  （`wmKeyMapDiffItem`，#src("source/blender/makesdna/DNA_windowmanager_types.h:408-L413")，
  一对 `remove_item` + `add_item`），
  这样用户配置文件里只需要存"我改了什么"，而不是整份键映射的副本。
- `poll` 上面的注释很直接：*不要直接调用它，用 `WM_keymap_poll`*。
  直接调用会漏掉上下文与区域判断。

keymap 的注册 API

键映射的 API 在 #src("source/blender/windowmanager/WM_keymap.hh")，
不在 `WM_api.hh` 里，容易找错。

#figure(
  kind: table,
  table(
    columns: (1.95fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*用途*]),
    [`WM_keyconfig_init(bContext *)`], [27], [初始化所有键映射配置],
    [`WM_keyconfig_new(wm, idname, user_defined)`], [30], [新建配置],
    [`WM_keyconfig_ensure(wm, idname, user_defined)`], [31], [有则取、无则建],
    [`WM_keyconfig_set_active(wm, idname)`], [36], [切换活动配置（预设）],
    [`WM_keyconfig_update(wm)`], [44], [把改动同步到运行期键映射],
    [`WM_keyconfig_update_tag(keymap, kmi)`], [46], [标记某个条目需要重建],
    [`WM_keyconfig_update_operatortype_tag()`], [47], [操作符注册后调用（见 §11.1.2）],
    [`WM_keymap_clear(keymap)`], [93], [清空条目],
    [`WM_keymap_add_item(keymap, idname, params)`], [98], [添加条目，总是新增],
    [`WM_keymap_add_item_copy(keymap, kmi_src)`], [101], [复制一个已有条目],
    [`WM_keymap_remove_item(keymap, kmi)`], [103], [删除条目],
    [`WM_keymap_item_to_string(kmi, compact)`], [104], [转成可读字符串],
    [`WM_keymap_ensure(keyconf, idname, spaceid, regionid)`], [114], [有则取、无则建],
    [`WM_keymap_find_all(wm, idname, spaceid, regionid)`], [115], [全局查找],
    [`WM_keymap_active(wm, keymap)`], [120], [取当前生效的那份],
    [`WM_keymap_remove(keyconf, keymap)`], [121], [移除],
    [`WM_keymap_poll(C, keymap)`], [122], [上下文是否适用（*唯一正确的调用方式*）],
    [`WM_keymap_item_find_id(keymap, id)`], [124], [按 id 查条目],
    [`WM_keymap_item_compare(k1, k2)`], [125], [条目是否等价],
    [`WM_keymap_guess_opname(C, opname)`], [173], [按操作符名猜合适的键映射],
    [`WM_modalkeymap_ensure(keyconf, idname, items)`], [188], [建立模态键映射],
    [`WM_modalkeymap_find(keyconf, idname)`], [191], [查找模态键映射],
    [`WM_modalkeymap_add_item(km, params, value)`], [192], [给模态映射加条目（按枚举值）],
    [`WM_modalkeymap_add_item_str(km, params, value)`], [193], [同上，字符串形式],
    [`WM_modalkeymap_find_propvalue(km, propvalue)`], [196], [按模态值反查条目],
    [`WM_modalkeymap_assign(km, opname)`], [197], [*把模态映射挂到操作符上*],
    [`WM_key_event_operator_string(C, opname, ...)`], [232], [反查某操作符绑的快捷键，用于界面显示],
  ),
  caption: [`WM_keymap.hh` 的 API。注意 `WM_keymap_add_item` 收的是 `const KeyMapItem_Params *`，不是逐个参数],
) <tbl-keymap-api>

`WM_keymap_add_item` 的参数结构体在 #src("source/blender/windowmanager/WM_keymap.hh:58-L80")：

```cpp
/** Parameters for matching events, passed into functions that create key-map items. */
struct KeyMapItem_Params {
  /** #wmKeyMapItem.type. */
  int16_t type;
  /** #wmKeyMapItem.val. */
  int8_t value;
  /**
   * This value is used to initialize #wmKeyMapItem `ctrl, shift, alt, oskey, hyper`.
   *
   * Valid values:
   *
   * - Combinations of: #KM_SHIFT, #KM_CTRL, #KM_ALT, #KM_OSKEY, #KM_HYPER.
   *   Are mapped to #KM_MOD_HELD.
   * - Combinations of the modifier flags bit-shifted using #KMI_PARAMS_MOD_TO_ANY.
   *   Are mapped to #KM_ANY.
   * - The value #KM_ANY is represents all modifiers being set to #KM_ANY.
   */
  int16_t modifier;

  /** #wmKeyMapItem.keymodifier. */
  int16_t keymodifier;
  /** #wmKeyMapItem.direction. */
  int8_t direction;
};
```

配合两个位移宏（#src("source/blender/windowmanager/WM_keymap.hh:86-L91")）：

```cpp
#define KMI_PARAMS_MOD_TO_ANY(mod) ((mod) << 8)
#define KMI_PARAMS_MOD_FROM_ANY(mod) ((mod) >> 8)
```

语义是：*普通地写 `KM_CTRL` 表示"必须按住 Ctrl"；写
`KMI_PARAMS_MOD_TO_ANY(KM_CTRL)` 表示"Ctrl 按不按都行"*。
这个设计把五个修饰键字段压缩成一个 `int16_t`，代价是需要记住这两个宏。

#note[
  *这是一个真实发生过变化的 API。* 老教程里的写法是
  `WM_keymap_add_item(km, "ID_OT_name", AKEY, KM_PRESS, KM_CTRL, 0)` ——
  六个位置参数。5.2 里它变成三个参数、修饰键走结构体
  （#src("source/blender/windowmanager/WM_keymap.hh:98-L100")）。
  看到长度是 6 的调用，你读的源码版本比 5.2 旧。
]

模态键映射：`WM_modalkeymap_*`

模态操作符需要一个"事件 → 语义值"的映射表，让 `modal` 回调能直接比较枚举值，
而不是自己判断一堆 `if (event->type == ...)`。真实例子在
#src("source/blender/editors/space_view3d/view3d_navigate_fly.cc:102-L144")：

```cpp
void fly_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {FLY_MODAL_CONFIRM, "CONFIRM", 0, "Confirm", ""},
      {FLY_MODAL_CANCEL, "CANCEL", 0, "Cancel", ""},

      {FLY_MODAL_DIR_FORWARD, "FORWARD", 0, "Forward", ""},
      {FLY_MODAL_DIR_BACKWARD, "BACKWARD", 0, "Backward", ""},
      ...
      {0, nullptr, 0, nullptr, nullptr},
  };

  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "View3D Fly Modal");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "View3D Fly Modal", modal_items);

  /* Assign map to operators. */
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_fly");
}
```

四个必备元素：

1. *一个 `EnumPropertyItem` 表*，把模态值映射到字符串名。它同时会出现在
   用户自定义快捷键的界面里（用户能看到 "Confirm"、"Forward" 这些名字）。
2. *一次 `WM_modalkeymap_find` 短路检查*。注释说明了原因：
   这个函数对每个 `SpaceType` 都会被调用一次，只需建一次。
3. *`WM_modalkeymap_ensure` 建立映射*。
4. *`WM_modalkeymap_assign` 把它绑到操作符 idname*。
   这一步会把 `wmOperatorType::modalkeymap`（#src("source/blender/windowmanager/WM_types.hh:1202")）填上。

`WM_modalkeymap_assign` 的作用机制在事件系统里有直接体现
（#src("source/blender/windowmanager/intern/wm_event_system.cc:2548-L2549")）：

```cpp
if (op->type->modalkeymap) {
  wmKeyMap *keymap = WM_keymap_active(CTX_wm_manager(C), op->type->modalkeymap);
```

也就是说：*模态期间，事件先被这张表翻译成模态值，再交给 `modal`*。
这也是为什么 `wmKeyMapItem::propvalue` 字段在模态项上有意义（§11.2.2 的表）。

=== 11.2.3 模态操作符的三件套

写一个模态操作符需要三样东西，缺一不可：

#figure(
  kind: table,
  table(
    columns: (auto, 1.7fr, 1.5fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([\*序\*], [*要做什么*], [*关键 API / 字段*]),
    [1], [在 `invoke` 里注册模态处理器],
    [`wmEventHandler_Op *WM_event_add_modal_handler(bContext *C, wmOperator *op)`（#src("source/blender/windowmanager/WM_api.hh:766")）],
    [2], [实现 `modal` 回调，按模态值分支],
    [`wmOperatorStatus (*modal)(bContext *, wmOperator *, const wmEvent *)`（#src("source/blender/windowmanager/WM_types.hh:1138")）],
    [3], [建立模态键映射并 `assign` 给操作符],
    [`WM_modalkeymap_ensure` + `WM_modalkeymap_assign`],
  ),
  caption: [模态操作符的三件套],
) <tbl-modal-trio>

`WM_event_add_modal_handler` 的回调变体与移除函数
（#src("source/blender/windowmanager/WM_api.hh:762-L784")）：

```cpp
wmEventHandler_Op *WM_event_add_modal_handler_ex(wmWindow *win, ...);
wmEventHandler_Op *WM_event_add_modal_handler(bContext *C, wmOperator *op) ATTR_NONNULL(1, 2);
void WM_event_remove_modal_handler(ListBaseT<wmEventHandler> *handlers, ...);
void WM_event_remove_modal_handler_all(const wmOperator *op, bool postpone) ATTR_NONNULL(1);
void WM_event_modal_handler_area_replace(wmWindow *win, ...);
void WM_event_modal_handler_region_replace(wmWindow *win, ...);
```

后两个 `_replace` 函数解决了一个具体问题：*模态运行期间，用户可能拖动分屏、
把区域移动或销毁*，这时处理器记录的 `area` / `region` 指针就悬垂了。
它们由区域管理代码调用（第 12 章会看到调用点）。
`_all` 的第二个参数 `postpone` 表示"延迟移除"，
用于"当前正在遍历处理器链表，不能立即摘"的场景。

模态处理器承载在 `wmEventHandler_Op` 上
（#src("source/blender/windowmanager/wm_event_system.hh:113")），
它是 `wmEventHandler` 的派生类型（#src("source/blender/windowmanager/wm_event_system.hh:47")）。
处理器链表挂在窗口上，这就是"模态操作符能持续收到事件"的物理基础。

模态回调到底在哪里被调用

这是理解模态机制的关键一行
（#src("source/blender/windowmanager/intern/wm_event_system.cc:2656-L2695")，节选）：

```cpp
/* Derived, modal or blocking operator. */
if ((handler_base->type == WM_HANDLER_TYPE_OP) &&
    ((reinterpret_cast<wmEventHandler_Op *>(handler_base))->op != nullptr))
{
  wmEventHandler_Op *handler = reinterpret_cast<wmEventHandler_Op *>(handler_base);
  wmOperator *op = handler->op;
  wmOperatorType *ot = op->type;

  if (!wm_operator_check_locked_interface(C, ot)) {
    /* Interface is locked and operator is not allowed to run,
     * nothing to do in this case. */
  }
  else if (ot->modal) {
    ...
    const intptr_t undo_id_prev = wm_operator_undo_active_id(wm);
    const intptr_t register_id_prev = wm_operator_register_active_id(wm);
    if (ot->flag & OPTYPE_UNDO) {
      wm->op_undo_depth++;
    }

    /* Warning, after this call all context data and 'event' may be freed. see check below. */
    retval = ot->modal(C, op, event);
    OPERATOR_RETVAL_CHECK(retval);

    if (ot->flag & OPTYPE_UNDO && CTX_wm_manager(C) == wm) {
      wm->op_undo_depth--;
    }
```

这段代码里有三件重要的事：

1. *`wm->op_undo_depth` 在模态期间递增。* 这是防止"模态操作符内部调用别的操作符时
   嵌套压栈"的机制 —— 见 §11.4.1 的 `wm_operator_register_check`。
2. *注释警告 `event` 可能已经被释放。* 模态操作符可以关窗口、加载新文件，
   于是 `C`、`event`、`op` 全都可能失效。
   紧接着的检查（#src("source/blender/windowmanager/intern/wm_event_system.cc:2700")）：
   `if (CTX_wm_window(C) == win) {` —— *所有模态之后的收尾代码都必须在这个判断里*。
   这是本节最该记住的一条实践规则。
3. *`OPERATOR_RETVAL_CHECK` 在每次模态返回后执行。* 返回非法值会立刻断言。

模态值的还原由一对函数负责
（#src("source/blender/windowmanager/intern/wm_event_system.cc:2680-L2681")）：

```cpp
wmEvent_ModalMapStore event_backup;
wm_event_modalkeymap_begin(C, op, event, &event_backup);
...
wm_event_modalkeymap_end(event, &event_backup);
```

它们把"事件 → 模态值"的翻译结果临时写回事件对象，
并在回调返回后还原，这样模态操作符的 `modal` 里可以直接检查修改后的值。

#pitfall[
  模态操作符的四个经典易错点：

  1. *在 `modal` 之外保存 `op` 指针。* 模态结束后 `op` 会被释放
     （#src("source/blender/windowmanager/intern/wm_event_system.cc:1351")：
     `WM_operator_free(op);`）。任何跨帧持有的指针都是悬垂的。
  2. *忘记在有一条退出路径上释放 `customdata`。*
     见 §11.1.4 的陷阱框。
  3. *在模态里直接发 notifier 修改区域数据。* 分屏可能正在被销毁。
     模态回调应该在返回 `FINISHED`/`CANCELLED` 之后再做结构性改动。
  4. *以为 `invoke` 一定会被调用。* 从 Python 用 `bpy.ops.x.y('EXEC_DEFAULT')`
     或在脚本里调用时，可能直接走 `exec`（§11.5.3）。
     `invoke` 里的初始化不能是 `exec` 的隐含前提。
]

== 11.3 notifier 与界面刷新

本节回答两个问题，它们在实践中总是成对出现：

- *改完数据，为什么界面没变？* —— 因为你没发 notifier。
- *改完数据，为什么撤销不回来？* —— 因为你没让系统记录撤销步骤。

而这两个问题共享同一个根：*你改了数据，但没有告诉任何人*。

=== 11.3.1 notifier 是什么：一个 32 位整数

notifier 的全部内容就是一个 `unsigned int`、一个可选的引用指针，
以及一个窗口。数据结构在 #src("source/blender/windowmanager/WM_types.hh:362-L370")：

```cpp
struct wmNotifier {
  wmNotifier *next, *prev;

  const wmWindow *window;

  unsigned int category, data, subtype, action;

  void *reference;
};
```

那个 `unsigned int` 被切成四段（#src("source/blender/windowmanager/WM_types.hh:372-L378")）：

```
/* 4 levels
 *
 * 0xFF000000; category
 * 0x00FF0000; data
 * 0x0000FF00; data subtype (unused?)
 * 0x000000FF; action
 */
```

掩码常量（#src("source/blender/windowmanager/WM_types.hh:381-L624")）：

```cpp
#define NOTE_CATEGORY 0xFF000000
#define NOTE_DATA 0x00FF0000
#define NOTE_SUBTYPE 0x0000FF00
#define NOTE_ACTION (0x000000FF)
```

拆包发生在提交 notifier 的地方
（#src("source/blender/windowmanager/intern/wm_event_system.cc:355-L380")，节选）：

```cpp
static void wm_event_add_notifier_intern(wmWindowManager *wm,
                                         const wmWindow *win,
                                         uint type,
                                         void *reference)
{
  ...
  note_test.category = type & NOTE_CATEGORY;
  note_test.data = type & NOTE_DATA;
  note_test.subtype = type & NOTE_SUBTYPE;
  note_test.action = type & NOTE_ACTION;
  note_test.reference = reference;

  BLI_assert(!wm_notifier_is_clear(&note_test));

  wm->runtime->notifier_queue_set.lookup_key_or_add_cb(&note_test, [&]() {
    wmNotifier *note = MEM_new<wmNotifier>(__func__);
    *note = note_test;
    BLI_addtail(&wm->runtime->notifier_queue, note);
    return note;
  });
}
```

两点值得注意：`BLI_assert(!wm_notifier_is_clear(...))` 会拦住"什么都没指定"的
空 notifier；`notifier_queue_set` 是一个去重集合，
*同一个类别 + 同一个引用在同一帧内只会入队一次*（去重判据见
#src("source/blender/windowmanager/intern/wm_event_system.cc:342-L347")）。
这是性能设计：一帧里改一万个顶点不能变成一万条 notifier。

`NC_` 类别：`WM_types.hh:381-L418`

类别占最高字节，是一个互斥的"领域"标签（#src("source/blender/windowmanager/WM_types.hh:383-L418")，
这里节选最常用的）：

```cpp
#define NC_WM (1 << 24)
#define NC_WINDOW (2 << 24)
#define NC_WORKSPACE (3 << 24)
#define NC_SCREEN (4 << 24)
#define NC_SCENE (5 << 24)
#define NC_OBJECT (6 << 24)
#define NC_MATERIAL (7 << 24)
#define NC_TEXTURE (8 << 24)
...
#define NC_SPACE (16 << 24)
#define NC_GEOM (17 << 24)
#define NC_NODE (18 << 24)
#define NC_ID (19 << 24)
```

完整清单共 29 个。用法是"领域 + 具体事件"按位或：

```cpp
WM_event_add_notifier(C, NC_OBJECT | ND_TRANSFORM, ob);
```

`ND_` 数据子类：同一个字节里的不同含义

`ND_*` 占第二个字节，但*同一个数值在不同 `NC_` 下含义完全不同*。
这是 notifier 系统最需要小心的地方。看几组真实定义
（#src("source/blender/windowmanager/WM_types.hh:424-L577")，节选）：

```cpp
#define ND_FILEREAD (1 << 16)
#define ND_FILESAVE (2 << 16)
#define ND_DATACHANGED (3 << 16)
#define ND_HISTORY (4 << 16)
#define ND_JOB (5 << 16)
#define ND_UNDO (6 << 16)
...
#define ND_FRAME (3 << 16)
...
#define ND_MODE (11 << 16)
...
#define ND_TRANSFORM (18 << 16)
...
#define ND_DRAW (23 << 16)
...
#define ND_SPACE_VIEW3D (10 << 16)
```

`ND_FILEREAD = (1 << 16)` 属于 `NC_WM`；
`ND_FRAME = (3 << 16)` 属于 `NC_SCENE`；`ND_DATACHANGED = (3 << 16)` 属于 `NC_WM`。
所以 *`NC_SCENE | ND_DATACHANGED` 是一个没有意义的组合* ——
它的数值虽然合法，但没有任何 listener 会认它。
写 notifier 时不能凭"数值对上"来推断，必须查注释里的分组。

#warn[
  `ND_*` 的数值空间被多个 `NC_` 复用，源码用注释把它们分组
  （例如 #src("source/blender/windowmanager/WM_types.hh:433") 附近的
  "`/* NC_WINDOW */`"、#src("source/blender/windowmanager/WM_types.hh:446")
  附近的 "`/* NC_SCENE */`"）。
  *抄一个 notifier 的时候要连注释一起抄。*
  本书建议的做法：永远从同一领域里现有的调用点复制整行，
  而不是自己拼数字。
]

`NC_SPACE` 下的 `ND_SPACE_*` 是一组给具体编辑器用的通知
（#src("source/blender/windowmanager/WM_types.hh:553-L577")）：

```cpp
#define ND_SPACE_CONSOLE (1 << 16)     /* General redraw. */
#define ND_SPACE_INFO_REPORT (2 << 16) /* Update for reports, could specify type. */
#define ND_SPACE_INFO (3 << 16)
#define ND_SPACE_IMAGE (4 << 16)
#define ND_SPACE_FILE_PARAMS (5 << 16)
#define ND_SPACE_FILE_LIST (6 << 16)
#define ND_SPACE_ASSET_PARAMS (7 << 16)
#define ND_SPACE_NODE (8 << 16)
#define ND_SPACE_OUTLINER (9 << 16)
#define ND_SPACE_VIEW3D (10 << 16)
#define ND_SPACE_PROPERTIES (11 << 16)
#define ND_SPACE_TEXT (12 << 16)
#define ND_SPACE_TIME (13 << 16)
#define ND_SPACE_GRAPH (14 << 16)
#define ND_SPACE_DOPESHEET (15 << 16)
#define ND_SPACE_NLA (16 << 16)
#define ND_SPACE_SEQUENCER (17 << 16)
#define ND_SPACE_NODE_VIEW (18 << 16)
...
#define ND_SPACE_CLIP (20 << 16)
#define ND_SPACE_FILE_PREVIEW (21 << 16)
#define ND_SPACE_SPREADSHEET (22 << 16)
```

注意到 `ND_SPACE_CONSOLE` 的注释写着 "General redraw." ——
这是"我也不知道具体变了什么，总之重画"的兜底选项。

提交 notifier 的三个入口

#figure(
  kind: table,
  table(
    columns: (2.0fr, auto, 1.6fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*用途*]),
    [`WM_event_add_notifier(const bContext *C, uint type, void *reference)`],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:396")],
    [最常用。提交到*当前窗口与上下文*],
    [`WM_event_add_notifier_ex(wmWindowManager *wm, const wmWindow *win, uint, void *)`],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:382")],
    [显式指定窗口管理器与窗口],
    [`WM_main_add_notifier(uint type, void *reference)`],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:403")],
    [提交给所有窗口（`win` 传 `nullptr`）],
  ),
  caption: [notifier 的三个提交入口。声明分别在 #src("source/blender/windowmanager/WM_api.hh:821")、#src("source/blender/windowmanager/WM_api.hh:817")、#src("source/blender/windowmanager/WM_api.hh:825") 附近],
) <tbl-notifier-api>

源码里的实现很短，值得看（#src("source/blender/windowmanager/intern/wm_event_system.cc:396-L408")）：

```cpp
void WM_event_add_notifier(const bContext *C, uint type, void *reference)
{
  /* XXX: in future, which notifiers to send to other windows? */

  WM_event_add_notifier_ex(CTX_wm_manager(C), CTX_wm_window(C), type, reference);
}

void WM_main_add_notifier(uint type, void *reference)
{
  Main *bmain = G_MAIN;
  wmWindowManager *wm = static_cast<wmWindowManager *>(bmain->wm.first);

  WM_event_add_notifier_ex(wm, nullptr, type, reference);
}
```

#pitfall[
  `WM_event_add_notifier` 从 `C` 里取窗口管理器。
  这意味着*在后台模式（`--background`）或没有窗口的上下文里，它会静默什么都不做*
  —— `WM_event_add_notifier_ex` 的第一件事就是
  `if (wm == nullptr) { return; }`（#src("source/blender/windowmanager/intern/wm_event_system.cc:384-L392")）。
  这是刻意的（注释解释了 `G_MAIN` 可能不是真正的 `main` 的情况），
  但会让你在插件/脚本调试时困惑：脚本里改了数据却没触发刷新，
  因为脚本执行时可能根本没有当前窗口。
]

=== 11.3.2 notifier 是怎么被消费的：listener 链

发出去的 notifier 不会直接操作界面。它进队列，然后在事件循环的某些时刻被
*分发*给注册了 listener 的对象。分发逻辑在
#src("source/blender/windowmanager/intern/wm_event_system.cc:755-L820")，节选：

```cpp
ED_workspace_do_listen(C, note);
ED_screen_do_listen(C, note);

for (ARegion &region : screen->regionbase) {
  wmRegionListenerParams region_params{};
  region_params.window = &win;
  region_params.area = nullptr;
  region_params.region = &region;
  region_params.scene = scene;
  region_params.notifier = note;

  ED_region_do_listen(&region_params);
}

ED_screen_areas_iter (&win, screen, area) {
  if ((note->category == NC_SPACE) && note->reference) {
    /* Filter out notifiers sent to other spaces. RNA sets the reference to the owning ID
     * though, the screen, so let notifiers through that reference the entire screen. */
    if (!ELEM(note->reference, area->spacedata.first, screen, scene)) {
      continue;
    }
  }
  wmSpaceTypeListenerParams area_params{};
  ...
  ED_area_do_listen(&area_params);
  for (ARegion &region : area->regionbase) {
    ...
    ED_region_do_listen(&region_params);
  }
}
```

这段代码把整条链讲清楚了：

1. *工作区*（`ED_workspace_do_listen`）与*屏幕*（`ED_screen_do_listen`）先听。
2. *屏幕自身的区域*（浮动面板等）逐个听。
3. *每个区域*（`ScrArea`）调 `ED_area_do_listen`，它转发到该区域的
   `SpaceType::listener`；然后该区域的每个子区域再调 `ED_region_do_listen`，
   转发到 `ARegionType::listener`。
4. *`reference` 参与过滤。* 对 `NC_SPACE` 类通知，如果 `reference`
   不是这个区域的数据、也不是屏幕/场景，就跳过。
   这就是"改 3D 视图属性不要惊动图像编辑器"的实现。

回调字段的定义在 #src("source/blender/blenkernel/BKE_screen.hh")：

```cpp
// BKE_screen.hh:100-L121（节选）
struct SpaceType {
  ...
  void (*listener)(const wmSpaceTypeListenerParams *params);   // 第 121 行
};

// BKE_screen.hh:249-L280（节选）
struct ARegionType {
  ...
  void (*listener)(const wmRegionListenerParams *params);      // 第 280 行
};
```

真实挂载点（#src("source/blender/editors/space_view3d/space_view3d.cc:1605")）：

```cpp
st->listener = space_view3d_listener;
```

而区域级的是（#src("source/blender/editors/space_view3d/space_view3d.cc:1628")）：

```cpp
art->listener = view3d_main_region_listener;
```

对应实现位于 #src("source/blender/editors/space_view3d/space_view3d.cc:1420")
（`static void space_view3d_listener(const wmSpaceTypeListenerParams *params)`）。

#summary[
  *"改完数据为什么要发 notifier"的完整答案：*

  1. 你的代码改了 DNA 数据，但*没有任何机制会自动发现这件事*。
     Blender 不是响应式框架，没有脏检查全局扫描。
  2. 界面元素的重新绘制由 `listener` 决定。`listener` 只有在收到 notifier 时
     才被调用；被调用后它做的事通常就是给相关区域打上"需要重绘"的标记。
  3. 因此不发 notifier 的后果是：*数据确实变了、缓存也确实失效了，
     但画面还是旧的*，直到用户碰巧做了什么触发重绘的动作。
  4. 反过来，发一个"过宽"的 notifier（例如 `NC_WINDOW`）会让所有界面都重绘，
     表现为"改一个数整个界面闪一下"。这就是为什么 `ND_*` 要区分得这么细。
]

#tip[
  找"该发哪个 notifier"的正确方法：*在你修改的同一类数据的其他修改点里找*。
  例如你要给 `Object` 加一个新的变换操作，就在 `source/blender/editors/transform/`
  里搜 `ND_TRANSFORM`，会看到现有调用点用的完整表达式，
  以及它们传的 `reference` 是什么（通常是 `ob` 或 `ob->data`）。
  这本书的附录 B 也按"想做的事"整理了这类索引。
]

== 11.4 撤销 / 重做与操作符收尾

撤销系统的公开结构体在 #src("source/blender/blenkernel/BKE_undo_system.hh")。
理解它的关键是把"栈"和"步骤"分开。

栈（#src("source/blender/blenkernel/BKE_undo_system.hh:52-L74")）：

```cpp
struct UndoStack {
  ListBaseT<UndoStep> steps;
  UndoStep *step_active;
  /**
   * The last memfile state read, used so we can be sure the names from the
   * library state matches the state an undo step was written in.
   */
  UndoStep *step_active_memfile;

  /**
   * Some undo systems require begin/end, see: #UndoType.step_encode_init
   *
   * \note This is not included in the 'steps' list.
   * That is done once end is called.
   */
  UndoStep *step_init;

  /**
   * Keep track of nested group begin/end calls,
   * within which all but the last undo-step is marked for skipping.
   */
  int group_level;
};
```

步骤（#src("source/blender/blenkernel/BKE_undo_system.hh:76-L94")）：

```cpp
struct UndoStep {
  UndoStep *next, *prev;
  char name[64];
  const UndoType *type;
  /** Size in bytes of all data in step (not including the step). */
  size_t data_size;
  /** Users should never see this step (only use for internal consistency). */
  bool skip;
  /** Some situations require the global state to be stored, edge cases when exiting modes. */
  bool use_memfile_step;
  /**
   * When this is true, undo/memfile read code is allowed to re-use old data-blocks for unchanged
   * IDs, and existing depsgraphs. This has to be forbidden in some cases (like renamed IDs).
   */
  bool use_old_bmain_data;
  /** For use by undo systems that accumulate changes (mesh-sculpt & image-painting). */
  bool is_applied;
  /* Over alloc 'type->struct_size'. */
};
```

最后一行注释"Over alloc `type->struct_size`"是核心机制：
*`UndoStep` 是一个基类，实际的步骤结构体比它大，额外部分由各撤销类型自己定义。*
所以不能 `MEM_new<UndoStep>` —— 必须由类型系统按 `step_size` 分配。

撤销类型（#src("source/blender/blenkernel/BKE_undo_system.hh:111-L169")）：

```cpp
struct UndoType {
  UndoType *next, *prev;
  /** Only for debugging. */
  const char *name;

  /**
   * When undefined, we don't consider this undo type for context checks.
   * Operators must explicitly set the undo type and handle adding the undo step.
   * ...
   */
  bool (*poll)(bContext *C);

  /**
   * None of these callbacks manage list add/removal.
   *
   * Note that 'step_encode_init' is optional,
   * some undo types need to perform operations before undo push finishes.
   */
  void (*step_encode_init)(bContext *C, UndoStep *us);

  bool (*step_encode)(bContext *C, Main *bmain, UndoStep *us);

  /**
   * \param is_final: whether the step being decoded is the target undo step being restored.
   */
  void (*step_decode)(bContext *C, Main *bmain, UndoStep *us, eUndoStepDir dir, bool is_final);

  /**
   * \note When freeing all steps,
   * free from the last since #BKE_UNDOSYS_TYPE_MEMFILE
   * will merge with the next undo type in the list.
   */
  void (*step_free)(UndoStep *us);
  ...
  /** Information for the generic undo system to refine handling of this specific undo type. */
  uint flags;

  /**
   * The size of the undo struct 'inherited' from #UndoStep for that specific type. Used for
   * generic allocation in BKE's `undo_system.cc`. */
  size_t step_size;
};
```

请注意 `UndoType` 的形状：*一个 `poll` 加四个 `step_*` 回调，再加一个 `step_size`*。
这和第 0 章讲的"定义描述结构体 + 填回调 + 注册"完全同构
（注册函数是 `BKE_undosys_type_append`，
#src("source/blender/blenkernel/BKE_undo_system.hh:357")，注释写着
"Similar to `WM_operatortype_append`"）。

内置的撤销类型是外部可见的全局常量
（#src("source/blender/blenkernel/BKE_undo_system.hh:193-L198")）：

```cpp
extern const UndoType *BKE_UNDOSYS_TYPE_IMAGE;
extern const UndoType *BKE_UNDOSYS_TYPE_MEMFILE;
extern const UndoType *BKE_UNDOSYS_TYPE_PAINTCURVE;
extern const UndoType *BKE_UNDOSYS_TYPE_PARTICLE;
extern const UndoType *BKE_UNDOSYS_TYPE_SCULPT;
extern const UndoType *BKE_UNDOSYS_TYPE_TEXT;
```

*`BKE_UNDOSYS_TYPE_MEMFILE` 是默认的那个*，也是最能解释"撤销为什么能恢复一切"的那个：
它把整个 `Main`（所有数据块）写进一个内存中的 `.blend` 文件快照。
所以它能撤销任何东西，代价是内存与时间。

"全局状态"与"局部状态"的混合

`UndoStep::use_memfile_step`（#src("source/blender/blenkernel/BKE_undo_system.hh:84-L85")）
的注释是理解混合策略的钥匙：

```
  /** Some situations require the global state to be stored, edge cases when exiting modes. */
  bool use_memfile_step;
```

默认情况下，memfile 撤销步骤只保存"变化的 ID"（增量）。
但在退出编辑模式等场合，整个 `Main` 的全局状态必须一起存，
否则"部分恢复"会产生不一致的状态。

三个关键 API 与一个返回值枚举

对外的撤销 API 在 #src("source/blender/editors/include/ED_undo.hh")。
核心几个：

#figure(
  kind: table,
  table(
    columns: (1.9fr, auto, 1.5fr),
    inset: 6pt,
    align: (left, right, left),
    stroke: 0.4pt + luma(78%),
    table.header([*函数*], [*行号*], [*用途*]),
    [`bool ED_undo_is_state_valid(bContext *C)`], [35], [主事件循环里的健全性检查：begin/end 是否配对],
    [`void ED_undo_group_begin(bContext *C)`], [36], [开始一个撤销组],
    [`void ED_undo_group_end(bContext *C)`], [37], [结束撤销组],
    [`void ED_undo_push(bContext *C, const char *str)`], [38], [*手动*压入一个撤销步骤，名字是 `str`],
    [`void ED_undo_push_op(bContext *C, wmOperator *op)`], [39], [按操作符压入（用它的名字）],
    [`void ED_undo_grouped_push(...)`], [40], [压入一个"分组型"步骤],
    [`void ED_undo_grouped_push_op(bContext *C, wmOperator *op)`], [41], [分组型 + 操作符],
    [`void ED_undo_pop_op(bContext *C, wmOperator *op)`], [42], [撤销并关联到操作符],
    [`void ED_undo_pop(bContext *C)`], [43], [撤销一步],
    [`void ED_undo_redo(bContext *C)`], [44], [重做一步],
    [`bool ED_undo_operator_repeat(bContext *C, wmOperator *op)`], [56], [重复上一次操作（"调整上一步"）],
    [`void ED_undo_operator_repeat_cb(...)`], [60], [UI 回调用的便捷版],
    [`bool ED_undo_is_valid(const bContext *C, const char *undoname)`], [66], [是否存在名为 `undoname` 的撤销步骤],
    [`bool ED_undo_has_redo_step(const bContext *C)`], [70], [是否有可重做步骤],
    [`bool ED_undo_is_memfile_compatible(const bContext *C)`], [72], [当前状态能否用 memfile 撤销],
    [`UndoStack *ED_undo_stack_get()`], [128], [直接拿栈（源码注释说明"最好不要"）],
  ),
  caption: [`ED_undo.hh` 的公开 API。注意 `ED_undo_push` 的第二个参数是*字符串名字*，不是操作符],
) <tbl-ed-undo-api>

`ED_undo_push` 的实现（#src("source/blender/editors/undo/ed_undo.cc:97-L139")，节选）：

```cpp
void ED_undo_push(bContext *C, const char *str)
{
  CLOG_INFO(&LOG, "Push '%s'", str);
  WM_file_tag_modified();

  wmWindowManager *wm = CTX_wm_manager(C);
  if (G.background) {
    /* Python developers may have explicitly created the undo stack in background mode,
     * otherwise allow it to be nullptr, see: #60934.
     * Otherwise it must never be nullptr, even when undo is disabled. */
    if (wm->runtime->undo_stack == nullptr) {
      return;
    }
  }

  int steps = U.undosteps;
  ...
  /* Only apply limit if this is the last undo step. */
  if (wm->runtime->undo_stack->step_active &&
      (wm->runtime->undo_stack->step_active->next == nullptr))
  {
    BKE_undosys_stack_limit_steps_and_memory(wm->runtime->undo_stack, steps - 1, 0);
  }

  push_retval = BKE_undosys_step_push(wm->runtime->undo_stack, C, str);
```

三个可读出的结论：

1. *撤销栈挂在 `wm->runtime->undo_stack` 上*，不在全局变量里。
   所以"后台模式没有撤销栈"是正常状态（注释引用了 issue #60934）。
2. *`ED_undo_push` 会标记文件已修改*（`WM_file_tag_modified()`）——
   这就是撤销栈和"未保存"标记的联系。
3. *步骤数量上限在压栈时裁剪*（`U.undosteps`，用户偏好）。
   注释解释了为什么只在"这是最后一步"时裁剪。

返回值是 `eUndoPushReturn`（#src("source/blender/blenkernel/BKE_undo_system.hh:102-L107")）：

```cpp
enum eUndoPushReturn {
  UNDO_PUSH_RET_FAILURE = 0,
  UNDO_PUSH_RET_SUCCESS = (1 << 0),
  UNDO_PUSH_RET_OVERRIDE_CHANGED = (1 << 1),
};
ENUM_OPERATORS(eUndoPushReturn)
```

撤销步骤是怎么"回滚"的

底层机制在 `BKE_undosys_*` 系列（#src("source/blender/blenkernel/BKE_undo_system.hh:279-L341")）：

```cpp
bool BKE_undosys_step_load_data_ex(
    UndoStack *ustack, bContext *C, UndoStep *us_target, UndoStep *us_reference, bool use_skip);
bool BKE_undosys_step_load_data(UndoStack *ustack, bContext *C, UndoStep *us_target);
void BKE_undosys_step_load_from_index(UndoStack *ustack, bContext *C, int index);
bool BKE_undosys_step_undo_with_data_ex(UndoStack *ustack, bContext *C, UndoStep *us_target,
                                        bool use_skip);
bool BKE_undosys_step_undo(UndoStack *ustack, bContext *C);
bool BKE_undosys_step_redo_with_data_ex(UndoStack *ustack, bContext *C, UndoStep *us_target,
                                        bool use_skip);
bool BKE_undosys_step_redo(UndoStack *ustack, bContext *C);
```

关键概念是 `eUndoStepDir`（#src("source/blender/blenkernel/BKE_undo_system.hh:96-L100")）：

```cpp
enum eUndoStepDir {
  STEP_REDO = 1,
  STEP_UNDO = -1,
  STEP_INVALID = 0,
};
```

*撤销和重做共用同一套代码，只是方向不同。*
方向由 `BKE_undosys_step_calc_direction` 算出
（#src("source/blender/blenkernel/BKE_undo_system.hh:262-L264")）：

```cpp
eUndoStepDir BKE_undosys_step_calc_direction(const UndoStack *ustack,
                                             const UndoStep *us_target,
                                             const UndoStep *us_reference);
```

它的注释说明了语义细节："If `us_reference` and `us_target` are the same,
we consider this is an undo"（#src("source/blender/blenkernel/BKE_undo_system.hh:258-L259")）。

`step_decode` 收到 `dir` 后负责把数据恢复到目标状态
（#src("source/blender/blenkernel/BKE_undo_system.hh:134-L137")）：

```cpp
  /**
   * \param is_final: whether the step being decoded is the target undo step being restored.
   */
  void (*step_decode)(bContext *C, Main *bmain, UndoStep *us, eUndoStepDir dir, bool is_final);
```

`is_final` 的存在说明了一个重要事实：*撤销可能一次跨越多步*
（比如"撤销到历史记录里的某个状态"）。中间的步骤只做"数据状态推进"，
只有最后一步才需要真正把界面状态（编辑模式、选择集、活动对象）恢复到位。
这就是 `ED_undo_object_editmode_restore_helper` 之类辅助函数存在的原因
（#src("source/blender/editors/include/ED_undo.hh:108-L112")）。

撤销组：把多个步骤合并成一个

`ED_undo_group_begin` / `ED_undo_group_end`
（#src("source/blender/editors/include/ED_undo.hh:36-L37")）
对应 `UndoStack::group_level`（#src("source/blender/blenkernel/BKE_undo_system.hh:69-L73")）：

```
  /**
   * Keep track of nested group begin/end calls,
   * within which all but the last undo-step is marked for skipping.
   */
  int group_level;
```

机制很直接：组内压入的步骤会被打上 `UndoStep::skip = true`
（#src("source/blender/blenkernel/BKE_undo_system.hh:82-L83")），
只有组结束时的那一步保留。撤销时"跳过被标记的步骤"
（即 `use_skip` 参数的作用）。

配对的健全性检查在 `ED_undo_is_state_valid`
（#src("source/blender/editors/undo/ed_undo.cc:62-L83")）：

```cpp
bool ED_undo_is_state_valid(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);

  /* Currently only checks matching begin/end calls. */
  if (wm->runtime->undo_stack == nullptr) {
    /* No undo stack is valid, nothing to do. */
    return true;
  }
  if (wm->runtime->undo_stack->group_level != 0) {
    /* If this fails #ED_undo_grouped_begin, #ED_undo_grouped_end calls don't match. */
    return false;
  }
  ...
```

#pitfall[
  `ED_undo_group_begin` 必须与 `ED_undo_group_end` 严格配对。
  任何一个提前 `return` 的分支漏掉 `end`，
  主事件循环的检查就会持续报 `ED_undo_is_state_valid` 失败
  （源码注释点名了后果："begin/end calls don't match"）。
  惯用做法是把你自己的整个实现包在 `begin` 之后、
  用 `ED_undo_group_end` 之前，且*所有*退出路径都汇到一个出口。
]

=== 11.4.1 操作符与撤销的连接点

这是本章最重要的一条链：*`OPTYPE_UNDO` 标志如何变成一次真正的压栈*。

标志定义（#src("source/blender/windowmanager/WM_types.hh:184-L186")）：

```cpp
  OPTYPE_REGISTER = (1 << 0),
  /** Do an undo push after the operator runs. */
  OPTYPE_UNDO = (1 << 1),
```

`OPTYPE_REGISTER` 的注释（#src("source/blender/windowmanager/WM_types.hh:163-L183")）
信息量很大，直接抄录：

```
  /**
   * Register operators in stack after finishing (needed for redo).
   *
   * \note Typically this flag should be enabled along with #OPTYPE_UNDO.
   * There are some exceptions to this:
   *
   * - Operators can conditionally perform an undo push,
   *   Examples include operators that may modify "screen" data
   *   (which the undo system doesn't track), or data-blocks such as objects, meshes etc.
   *   In this case the undo push depends on the operators internal logic.
   *   ...
   * - Operators can perform an undo push indirectly.
   *   (`UI_OT_reset_default_button` for example).
   *
   *   In this case, register needs to be enabled so as not to clear the "Redo" panel, see #133761.
   *   Unless otherwise stated, any operators that register without the undo flag
   *   can be assumed to be creating undo steps indirectly (potentially at least).
   */
```

*"Register"和"Undo"是两件事*：register 决定这个操作符是否进入"上一次操作"记录
（也就是能不能用"调整上一步操作"面板），undo 决定是否压撤销栈。
大多数操作符两个都要，所以你会到处看到
`ot->flag = OPTYPE_REGISTER | OPTYPE_UNDO;`。

消费点是 `wm_operator_finished`
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1282-L1330")，节选）：

```cpp
static void wm_operator_finished(bContext *C,
                                 wmOperator *op,
                                 const bool repeat,
                                 const bool store,
                                 const bool has_undo_step,
                                 const bool has_register)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  ...
  const bool do_register = (repeat == false) && wm_operator_register_check(wm, op->type);

  op->customdata = nullptr;

  if (store) {
    WM_operator_last_properties_store(op);
  }

  /* We don't want to do undo pushes for operators that are being
   * called from operators that already do an undo push. Usually
   * this will happen for python operators that call C operators. */
  if (wm->op_undo_depth == 0) {
    if (op->type->flag & OPTYPE_UNDO) {
      ED_undo_push_op(C, op);
      if (repeat == 0) {
        hud_status = CLEAR;
      }
    }
    else if (op->type->flag & OPTYPE_UNDO_GROUPED) {
      ED_undo_grouped_push_op(C, op);
      ...
```

把它翻译成操作规则：

1. *`OPTYPE_UNDO` 的执行顺序是"先执行、后压栈"。*
   `wm_operator_finished` 在 `exec`/`invoke`/`modal` 返回成功之后才被调用。
   所以撤销栈里记录的是*执行之后*的状态，这一点和"记录执行前状态"的系统相反。
2. *`wm->op_undo_depth == 0` 是嵌套保护。*
   如果你在操作符 A 里调用操作符 B，且 A 已经压过栈，
   那 B 的 `OPTYPE_UNDO` 就不会再压一次。
3. *`OPTYPE_UNDO_GROUPED` 是另一种压栈方式*（#src("source/blender/windowmanager/WM_types.hh:210-L211")）：

   ```cpp
   /** Special type of undo which doesn't store itself multiple times. */
   OPTYPE_UNDO_GROUPED = (1 << 10),
   ```

   它走 `ED_undo_grouped_push_op`。用它的典型场合是"连续拖拽"：
   每次鼠标移动都算一次执行，但不该产生几百个撤销步骤。

4. *`has_undo_step` 参数给"间接压栈"的操作符用*（#src("source/blender/windowmanager/intern/wm_event_system.cc:1319-L1329")）：

   ```cpp
   else if (has_undo_step) {
     /* An undo step was added but the operator wasn't registered (and won't register itself),
      * therefor a redo panel wouldn't redo this action but the previous registered action,
      * causing the "redo" to remove/loose this operator. See: #101743.
      * Register check is needed so nested operator calls don't clear the HUD. See: #103587. */
     if (!(has_register || do_register)) {
       if (repeat == 0) {
         hud_status = CLEAR;
       }
     }
   }
   ```

   注释里引用了两个 issue 编号，全是真实遇到过的易错点。

`wm_operator_register_check` 是判定"要不要记进操作符栈"的地方
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1270-L1275")）：

```cpp
static bool wm_operator_register_check(wmWindowManager *wm, wmOperatorType *ot)
{
  /* Check undo flag here since undo operators are also added to the list,
   * to support checking if the same operator is run twice. */
  return wm && (wm->op_undo_depth == 0) && (ot->flag & (OPTYPE_REGISTER | OPTYPE_UNDO));
}
```

注意 `ot->flag & (OPTYPE_REGISTER | OPTYPE_UNDO)` —— *两个标志里有一个就够了*。
这就是 `OPTYPE_REGISTER` 的注释所说"没有 undo 标志的 register 可以假定它在间接压栈"
的代码依据。

`op_undo_depth` 在模态期间也会被维护
（#src("source/blender/windowmanager/intern/wm_event_system.cc:1307")、
#src("source/blender/windowmanager/intern/wm_event_system.cc:1396")、
#src("source/blender/windowmanager/intern/wm_event_system.cc:1699")、
#src("source/blender/windowmanager/intern/wm_event_system.cc:2337")、
#src("source/blender/windowmanager/intern/wm_event_system.cc:2685")、
#src("source/blender/windowmanager/intern/wm_event_system.cc:2987") 等多处按
`OPTYPE_UNDO` 分支）。所以模态操作符在运行期间不会误压栈。

手写撤销：什么时候需要

`OPTYPE_UNDO` 覆盖不了两种情况：

1. *你想自己控制撤销步骤的名字。*
   `ED_undo_push_op` 用的是操作符的 `name`。
   复合操作往往需要更具体的名字，例如 "Move 3 Objects"。
2. *你在非操作符路径上改数据*（面板回调、Python 脚本、gizmo）。

这时用手动压栈：

```cpp
// 示意：改完数据之后
ED_undo_push(C, "My Custom Step");
```

如果你希望这一步能重做，还需要它关联一个操作符；
`ED_undo_push_op` 就是做这件事的（#src("source/blender/editors/include/ED_undo.hh:39")）。

#warn[
  *手动压栈有两个必须注意的时机问题：*

  1. *必须在数据改完之后压*，因为 memfile 撤销存的是当前状态。
     在改之前压栈会丢掉这次修改。
  2. *不要重复压。* 一次用户动作压多个步骤会让用户按一次 Ctrl+Z
     只撤销掉一半。复合操作请用 `ED_undo_group_begin` / `ED_undo_group_end`
     包起来（§11.4），或者设置 `ot->undo_group`（#src("source/blender/windowmanager/WM_types.hh:1098")）
     让框架替你分组。

  另外注意 `ED_undo_push` 里有 `if (steps <= 0) return;` ——
  *用户把撤销步数设为 0 时，你的手动压栈会静默失败*（#src("source/blender/editors/undo/ed_undo.cc:125-L127")）。
  这通常是你想要的（尊重用户设置），但如果你在依赖"撤销步骤存在"做逻辑判断，
  就不能这么假设。
]

=== 11.4.2 完整的一帧：把 notifier 与撤销串起来

把本章前文的所有环节按时间顺序排一遍，用一次"用 G 移动物体"为例：

#figure(
  kind: table,
  table(
    columns: (auto, 1.5fr, 1.5fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*阶段*], [*发生了什么*], [*源码位置*]),
    [1], [按键产生 `wmEvent`，`type = EVT_GKEY`, `val = KM_PRESS`],
    [#src("source/blender/windowmanager/WM_types.hh:795")],
    [2], [keymap 匹配到 `TRANSFORM_OT_translate`（`wmKeyMapItem::idname`）],
    [#src("source/blender/makesdna/DNA_windowmanager_types.h:349")],
    [3], [`WM_operatortype_find` 查出 `wmOperatorType *ot`],
    [#src("source/blender/windowmanager/intern/wm_operator_type.cc:78")],
    [4], [`ot->poll(C)` 通过；`ot->invoke` 被调用并注册模态处理器],
    [#src("source/blender/windowmanager/WM_api.hh:766")],
    [5], [每次鼠标移动重入 `ot->modal`；`op_undo_depth` 在模态期间递增],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:2690")],
    [6], [左键确认，返回 `OPERATOR_FINISHED`；模态处理器被移除],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:2704")],
    [7], [`wm_operator_finished` 里因 `OPTYPE_UNDO` 调用 `ED_undo_push_op(C, op)`],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:1307-L1308")],
    [8], [变换代码已经发过 `NC_OBJECT | ND_TRANSFORM` 之类 notifier],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:396")],
    [9], [`ED_area_do_listen` → `view3d_main_region_listener` 收到通知，区域标脏],
    [#src("source/blender/windowmanager/intern/wm_event_system.cc:808")],
    [10], [下一帧绘制时依赖图重新求值，界面显示新位置],
    [见第 13 章],
  ),
  caption: [一次模态变换操作符的完整生命周期。第 7、8 步的顺序说明了"数据先改、撤销后记、通知随时"的节奏],
) <tbl-op-lifecycle>

#summary[
  *撤销与 notifier 的分工，一句话版本：*

  - *notifier* 回答"界面该不该重画"。它*不*影响数据，只影响显示。
  - *撤销栈* 回答"用户能不能退回去"。它*不*影响显示，只影响数据历史。
  - 两者都依赖你*主动告知*。Blender 不做自动推断。
  - 因此一个"改数据的操作符"的完整形态是：
    `poll` + `exec`/`modal` + 数据修改 + `WM_event_add_notifier` +
    `ot->flag = OPTYPE_REGISTER | OPTYPE_UNDO`。
    少任何一项，用户都会遇到"看起来不对"的行为，
    而且症状（不刷新 / 撤销丢失 / 上一步面板为空）彼此完全不同。
]

== 11.5 `bpy.ops` 与 C++ 操作符的映射

=== 11.5.1 名字转换：`_OT_` ↔ `.`

Python 里写 `bpy.ops.object.select_all()`，C++ 里叫 `OBJECT_OT_select_all`。
转换规则由两个函数实现，它们是本节的核心
（#src("source/blender/windowmanager/intern/wm_operators.cc:128-L177")）：

```cpp
#define OP_BL_SEP_STRING "_OT_"
#define OP_BL_SEP_LEN 4

#define OP_PY_SEP_CHAR '.'
#define OP_PY_SEP_LEN 1

size_t WM_operator_py_idname(char *dst, const char *src)
{
  const char *sep = strstr(src, OP_BL_SEP_STRING);
  if (sep) {
    const size_t sep_offset = size_t(sep - src);

    /* NOTE: we use ASCII `tolower` instead of system `tolower`, because the
     * latter depends on the locale, and can lead to `idname` mismatch. */
    memcpy(dst, src, sep_offset);
    BLI_str_tolower_ascii(dst, sep_offset);

    dst[sep_offset] = OP_PY_SEP_CHAR;
    return BLI_strncpy_rlen(dst + (sep_offset + OP_PY_SEP_LEN),
                            sep + OP_BL_SEP_LEN,
                            OP_MAX_TYPENAME - sep_offset - OP_PY_SEP_LEN) +
           (sep_offset + OP_PY_SEP_LEN);
  }
  /* Should not happen but support just in case. */
  return BLI_strncpy_rlen(dst, src, OP_MAX_TYPENAME);
}

size_t WM_operator_bl_idname(char *dst, const char *src)
{
  const size_t from_len = strlen(src);

  const char *sep = strchr(src, OP_PY_SEP_CHAR);
  if (sep && (from_len <= OP_MAX_PY_IDNAME)) {
    const size_t sep_offset = size_t(sep - src);
    memcpy(dst, src, sep_offset);
    BLI_str_toupper_ascii(dst, sep_offset);

    memcpy(dst + sep_offset, OP_BL_SEP_STRING, OP_BL_SEP_LEN);
    BLI_strncpy(dst + sep_offset + OP_BL_SEP_LEN,
                sep + OP_PY_SEP_LEN,
                from_len - sep_offset - OP_PY_SEP_LEN + 1);
    return from_len + OP_BL_SEP_LEN - OP_PY_SEP_LEN;
  }
  ...
```

规则归纳（配合 #src("source/blender/windowmanager/intern/wm_operators.cc:134-L136") 的长度宏）：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 1.3fr, 1.7fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*C++（`b` 名）*], [*Python*], [*规则*]),
    [`OBJECT_OT_select_all`], [`object.select_all`], [`_OT_` 前的部分转小写，`_OT_` 换成 `.`],
    [`WM_OT_window_close`], [`wm.window_close`], [前缀只用第一个 `.` 之前的部分],
    [`MYADDON_OT_do_thing`], [`myaddon.do_thing`], [插件前缀规则相同，无特殊处理],
    [—], [`object.select_all` 也能被 C++ 查找], [`WM_operatortype_find` 会先做 `bl_idname` 转换（§11.1.2）],
  ),
  caption: [操作符名字的 C++ / Python 对应关系。转换是纯字符串操作，没有查表],
) <tbl-op-idname-mapping>

`OP_MAX_PY_IDNAME` 的定义（#src("source/blender/windowmanager/intern/wm_operators.cc:136")）：

```cpp
/* Difference between python 'identifier' and BL/C code one ("." separator replaced by "_OT_"),
 * and final `\0` char. */
#define OP_MAX_PY_IDNAME (OP_MAX_TYPENAME - OP_BL_SEP_LEN + OP_PY_SEP_LEN - 1)
```

因为 `_OT_`（4 字符）比 `.`（1 字符）长，Python 名可以比 C++ 名略长。
注意那句注释里解释为什么用 ASCII 版 `tolower`：*系统的 `tolower` 受 locale 影响*，
在土耳其语等 locale 下 `I` 会转成 `ı`，导致 idname 不匹配。
这是个很具体的跨平台易错点，也是"细节决定可移植性"的例子。

校验：`WM_operator_bl_idname_is_valid`

#src("source/blender/windowmanager/intern/wm_operators.cc:179-L197")：

```cpp
bool WM_operator_bl_idname_is_valid(const char *idname)
{
  const char *sep = strstr(idname, OP_BL_SEP_STRING);
  /* Separator missing or at string beginning/end. */
  if ((sep == nullptr) || (sep == idname) || (sep[OP_BL_SEP_LEN] == '\0')) {
    return false;
  }

  for (const char *ch = idname; ch < sep; ch++) {
    if ((*ch >= 'A' && *ch <= 'Z') || (*ch >= '0' && *ch <= '9') || *ch == '_') {
      continue;
    }
    return false;
  }

  for (const char *ch = sep + OP_BL_SEP_LEN; *ch; ch++) {
    if ((*ch >= 'a' && *ch <= 'z') || (*ch >= '0' && *ch <= '9') || *ch == '_') {
      continue;
    }
```

反过来说：*注册一个 `MyAddon_OT_foo` 或 `MYADDON_OT_Foo` 都会失败*。
这解释了很多人的困惑"我的操作符注册了但 `bpy.ops` 里找不到"。

名字 `_OT_` 之外的一个细节：`__` 双下划线

有些操作符会用到双下划线来消歧（例如 `OBJECT_OT_modifier_move_to_index`）。
转换是纯字符串的，所以 `object.modifier_move_to_index` 正确。
但如果你自己用双下划线做分隔，要意识到 Python 属性名里不能有 `_OT_` 之外的
分隔符逻辑 —— 全部会原样保留。

=== 11.5.2 `bpy.ops` 模块是怎么造出来的

`bpy.ops` 模块本身非常薄。实现在
#src("source/blender/python/intern/bpy_operator.cc")，
只有 100 行左右。核心是（#src("source/blender/python/intern/bpy_operator.cc:33-L93")）：

```cpp
static PyObject *pyop_dir(PyObject * /*self*/)
{
  ...
}

static PyMethodDef bpy_ops_methods[] = {
  ...
};

static PyModuleDef bpy_ops_module = {
    /*m_base*/ PyModuleDef_HEAD_INIT,
    ...
    /*m_methods*/ bpy_ops_methods,
    ...
};

...
  submodule = PyModule_Create(&bpy_ops_module);
```

*`bpy.ops` 不是一张预先建好的操作符清单，而是一个动态代理。*
`bpy.ops.object` 也不是真的子模块 —— 它是 `bpy.ops` 的 `__getattr__`
按前缀临时构造出来的。这就是为什么：

- `bpy.ops.object` 在 `dir(bpy.ops)` 里可能看不到，但能访问；
- 操作符运行时注册（例如插件注册新操作符）之后，
  `bpy.ops.myaddon.do_thing()` 立刻可用，不需要重启或重新 import；
- 拼错名字得到的是 `AttributeError` 而不是 `None`，
  而且错误信息里会列出"相近的名字"。

`pyop_dir` 的存在就是为了让 `dir()` 和补全工作 ——
它需要动态枚举注册表（走 §11.1.2 的 `get_operators_map`）。

Python 操作符反向变成 C++ 操作符类型

插件用 `bpy.types.Operator` 子类 + `bl_idname` 定义操作符。
这些"Python 操作符"在 C++ 侧也必须是 `wmOperatorType`，否则：
`bpy.ops.x.y()` 的调用机制、撤销、键映射绑定全都无法统一。

转换在这两个函数里（#src("source/blender/python/intern/bpy_operator_wrap.cc")）：

```cpp
// bpy_operator_wrap.cc:85-L99（节选）
void BPY_RNA_operator_wrapper(wmOperatorType *ot, void *userdata)
{
  /* take care not to overwrite anything set in
   * WM_operatortype_append_ptr before opfunc() is called */
  StructRNA *srna = ot->srna;
  *ot = std::move(*(static_cast<wmOperatorType *>(userdata)));
  ot->srna = srna; /* restore */

  /* Use i18n context from rna_ext.srna if possible (py operators). */
  if (ot->rna_ext.srna) {
    RNA_def_struct_translation_context(ot->srna, RNA_struct_translation_context(ot->rna_ext.srna));
  }

  operator_properties_init(ot);
}
```

这里有几个精确的细节：

- *它通过 `WM_operatortype_append_ptr` 注册*（用户数据里带着 Python 侧建好的
  `wmOperatorType`）。这就是 §11.1.2 里那个带 `void *userdata` 的变体的用途。
- *`ot->srna` 要在整体赋值前保存、赋值后恢复*（第 89、91 行）。
  因为 `__begin` 已经建好了 `srna`，而 Python 侧那份里没有。
- *`operator_properties_init` 负责把 Python 声明的属性转成 RNA 属性*
  （#src("source/blender/python/intern/bpy_operator_wrap.cc:29")）。

宏版本的转换在 #src("source/blender/python/intern/bpy_operator_wrap.cc:101-L120")，
它*逐个字段*复制而不是整体赋值，注释说明了原因
（#src("source/blender/python/intern/bpy_operator_wrap.cc:105")）：
"only copy a couple of things, the rest is set by the macro registration"。

`bpy.ops.macro_define`

宏操作符的 Python 侧入口在 #src("source/blender/python/intern/bpy_operator_wrap.cc:122")：

```cpp
PyObject *PYOP_wrap_macro_define(PyObject * /*self*/, PyObject *args)
```

它内部也做名字转换（#src("source/blender/python/intern/bpy_operator_wrap.cc:136-L139")）：

```cpp
  /* Support both `foo.bar` & `FOO_OT_bar`. */
  WM_operator_bl_idname(idname, idname_py);
  if (!WM_operator_bl_idname_is_valid(idname)) {
    PyErr_Format(PyExc_ValueError, "Macro Define: '%s' is not a valid operator id name", idname);
```

#tip[
  这说明*Python 侧传来的名字通常是 Python 风格*（`object.select_all`），
  需要在 C++ 侧转换。你自己写桥接代码时也要照做。
  反过来，C++ 侧要显示给用户看的名字用 `WM_operator_py_idname` 转回去 ——
  这在生成"等效 Python 脚本"（§11.1.5 的 `WM_operator_pystring`）时用到。
]

=== 11.5.3 `bpy.ops.x.y()` 到底做了什么

从 Python 调用一个操作符，实际发生的是一系列"准备上下文 → 选择调用路径 → 执行"。
关键点有三个：

*第一，`bpy.ops` 的调用可能走 `invoke` 或 `exec`，由 `operator_context` 决定。*
C++ 侧的枚举在 #src("source/blender/windowmanager/WM_types.hh:246-L261")：

```cpp
namespace wm {
enum class OpCallContext : int8_t {
  /* If there's invoke, call it, otherwise exec. */
  InvokeDefault,
  InvokeRegionWin,
  InvokeRegionChannels,
  InvokeRegionPreview,
  InvokeArea,
  InvokeScreen,
  /* Only call exec. */
  ExecDefault,
  ExecRegionWin,
  ExecRegionChannels,
  ExecRegionPreview,
  ExecArea,
  ExecScreen,
};
}
```

配套的谓词（#src("source/blender/windowmanager/WM_types.hh:264-L269")）：

```cpp
#define WM_OP_CONTEXT_HAS_AREA(type) \
  (CHECK_TYPE_INLINE(type, wm::OpCallContext), \
   !ELEM(type, wm::OpCallContext::InvokeScreen, wm::OpCallContext::ExecScreen))
#define WM_OP_CONTEXT_HAS_REGION(type) \
  (WM_OP_CONTEXT_HAS_AREA(type) && \
   !ELEM(type, wm::OpCallContext::InvokeArea, wm::OpCallContext::ExecArea))
```

所以 Python 里写：

```python
bpy.ops.object.select_all()                      # 默认：InvokeDefault
bpy.ops.object.select_all('EXEC_DEFAULT')        # 强制只走 exec
bpy.ops.transform.translate('INVOKE_REGION_WIN') # 强制走 invoke，且要求有区域上下文
```

区别是实质性的：`EXEC_DEFAULT` 跳过 `invoke`，
*如果操作符只有 `invoke` 没有 `exec`，调用会失败*。
这是脚本里最常见的 `RuntimeError: Operator ... can't be executed` 来源。

*第二，Python 调用会构造一个临时的 `wmOperator`。*
属性从关键字参数填进去（走 `op->properties`），
执行完就释放。所以*不要指望在 Python 里跨调用持有操作符状态* ——
每次 `bpy.ops.x.y()` 都是一次全新的调用。

*第三，撤销行为与 C++ 调用完全一致*，因为它走的是同一套
`wm_operator_finished` 逻辑（§11.4.1）。
这就是为什么"Python 脚本里改数据"和"用操作符改数据"在撤销上表现不同
（前者通常不进撤销栈，除非你手工 `ED_undo_push`）。

#pitfall[
  关于 `bpy.ops` 的三个常见误解：

  1. *"`bpy.ops` 调用的性能开销可以忽略。"*
     不对。每次调用都要查注册表、建 RNA 属性、走完整的操作符执行栈。
     循环里调用 `bpy.ops.mesh.primitive_cube_add()` 一千次会很慢。
     批量场景应该用数据 API（`bpy.data`）而不是 `bpy.ops`，见第 6 章。
  2. *"`bpy.ops` 能调用任何操作符。"*
     不全对。`poll` 返回 `false` 时调用会失败，
     而且错误信息往往是笼统的 "context is incorrect"。
     `bpy.ops.x.y.poll()` 可以在调用前检查（Python 侧封装了 poll）。
  3. *"内部操作符（`OPTYPE_INTERNAL`）也能随便调。"*
     `OPTYPE_INTERNAL` 的作用是*从搜索菜单里隐藏*
     （#src("source/blender/windowmanager/WM_types.hh:201-L206")），
     它不阻止 `bpy.ops` 调用。但这类操作符通常依赖特定的内部状态，
     从脚本调用多数会失败或产生未定义结果。
]

== 11.6 实践：注册一个 C++ 操作符并挂到菜单与快捷键

本节给出一个可跟做的完整流程。目标是加一个操作符
`OBJECT_OT_report_selected_count`：统计当前视图层里被选中的物体数量，
把结果写进状态栏报告，并支持撤销（它不改数据，但我们要演示撤销相关的完整形态）。

#note[
  这个练习的价值不在功能本身，而在*把新增操作符要碰的每一个文件都走一遍*。
  一旦你走过一次，加第二个操作符就只是复制粘贴。
  所有改动都在你检出的 Blender 源码树中，括号里给出建议的行号位置（以 #blender-version 为准，
  你的版本可能有偏移，请按符号名定位）。
]

=== 11.6.1 第一步：选一个模块和文件

先决定操作符属于哪个编辑器。我们的操作符作用于物体选择，
所以放在 Object 模块：

#figure(
  kind: table,
  table(
    columns: (1.3fr, 2.1fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*要改的文件*], [*改什么*]),
    [#src("source/blender/editors/object/object_intern.hh")],
    [声明 `void OBJECT_OT_report_selected_count(wmOperatorType *ot);`
     （与其他 `OBJECT_OT_*` 声明放在一起）],
    [#src("source/blender/editors/object/object_ops.cc")],
    [在 `operatortypes_object()` 里加一行注册调用],
    [#src("source/blender/editors/object/object_ops.cc")],
    [实现 `WM_OT_report_selected_count` 同族的操作符定义函数与 `exec`/`poll`],
    [#src("scripts/startup/bl_ui/space_view3d.py")],
    [把操作符挂进 3D 视图的 Object 菜单（Python 侧）],
    [#src("source/blender/editors/space_view3d/view3d_ops.cc")],
    [在 `view3d_keymap()` 里加一个快捷键（可选）],
  ),
  caption: [新增一个 Object 操作符要碰的文件。注意菜单在 Python 侧、快捷键在 C++ 侧，这是 5.2 的实际状态],
) <tbl-new-op-files>

#warn[
  *一个必须提前说明的事实*：在 5.2 里，*3D 视图的 Add 菜单定义在 Python 里*
  （#src("scripts/startup/bl_ui/space_view3d.py:2679") 的 `class VIEW3D_MT_add(Menu)`），
  而不是 C++ 里。它是"内置 UI"，随 Blender 一起编译，
  所以改它需要重新构建（`make update` 会把 `scripts/` 打包进二进制）。
  第 12 章会详细讨论"内置 Python UI"这个混合形态。
  本节的流程把这部分也走一遍，因为它是最常用的"挂菜单"方式。
]

为什么把实现放在 `object_ops.cc` 里

严格来说你可以新建一个文件。但要注意 `operatortypes_object()` 所在的文件
必须在构建系统里（`object_ops.cc` 已经在），
而新建文件需要同时改 #src("source/blender/editors/object/CMakeLists.txt")。
*为了降低第一次跟做的难度，本节选择"加在已有文件里"。*

同时要注意 Object 模块的命名空间（#src("source/blender/editors/object/object_ops.cc:27")）：

```cpp
namespace blender::ed::object {

void operatortypes_object()
{
```

所以你的函数要放在这个命名空间里，或者用
`blender::ed::object::` 限定。`WM_operatortype_append` 收的是函数指针，
命名空间不影响它 —— 但 `object_intern.hh` 里的声明必须与定义在同一个命名空间内。

=== 11.6.2 第二步：写出操作符定义与回调

在 #src("source/blender/editors/object/object_ops.cc") 的
`operatortypes_object()` 之前插入以下代码。
这段代码的每一处写法都能在源码里找到同类
（回调签名见 #src("source/blender/windowmanager/WM_types.hh:1106-L1146")）：

```cpp
/* -------------------------------------------------------------------- */
/** \name Report Selected Count Operator
 * \{ */

static bool report_selected_count_poll(bContext *C)
{
  /* 只在有视图层可用时允许执行。 */
  return CTX_data_view_layer(C) != nullptr;
}

static wmOperatorStatus report_selected_count_exec(bContext *C, wmOperator *op)
{
  const ViewLayer *view_layer = CTX_data_view_layer(C);

  int count = 0;
  for (const Base &base : view_layer->object_bases) {
    if ((base.flag & BASE_SELECTED) != 0) {
      count++;
    }
  }

  BKE_reportf(op->reports, RPT_INFO, "Selected objects: %d", count);

  /* 这个操作符不修改数据，但为了演示撤销形态，仍然发一条通知。
   * 实际项目里若真的什么都没改，是不需要发 notifier 的。 */
  WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, nullptr);

  return OPERATOR_FINISHED;
}

static void WM_OT_report_selected_count(wmOperatorType *ot)
{
  ot->name = "Report Selected Count";
  ot->idname = "OBJECT_OT_report_selected_count";
  ot->description = "Report how many objects are selected in the current view layer";

  ot->exec = report_selected_count_exec;
  ot->poll = report_selected_count_poll;

  /* Register 让它进入"调整上一步操作"记录；UNDO 让它压入撤销栈。
   * 定义位置：source/blender/windowmanager/WM_types.hh:184, :186 */
  ot->flag = OPTYPE_REGISTER | OPTYPE_UNDO;
}

/** \} */
```

#warn[
  上面这段代码里有两个字段需要你*在自己的版本里核对*，因为它们是
  §11.6 中唯一没有逐字抄自现有调用点的地方：

  1. `view_layer->object_bases` 与 `base.flag & BASE_SELECTED`。
     遍历视图层里的选中物体有若干等价写法（也可能走
     `BKE_view_layer_selected_objects_iterator_begin` 之类的辅助函数）。
     请在你克隆的源码里 grep `BASE_SELECTED` 确认当前版本的字段与标志名，
     再决定用哪种写法。
  2. `BKE_reportf` 与 `RPT_INFO`。`ReportList` 与报告类型的名字很稳定，
     但如果你要输出更严格的类型（`RPT_ERROR` / `RPT_WARNING`），
     请查 #src("source/blender/blenkernel/BKE_report.hh")。

  这两处不影响本节要讲的结构（`poll`/`exec`/`flag`/`notifier`），
  但*公开出版的书不应该让你照抄一段没核对过的字段访问* ——
  所以这里明确标出，请你以自己版本为准。
]

#tip[
  想知道"遍历视图层里的物体"在本版本里最规范的写法，最快的办法是
  在 `source/blender/` 里 grep 你要找的那个标志或函数名，
  看*离你最近的*那几个调用点怎么写的。Blender 源码里同一件事常有新旧两种写法
  （例如 `ListBase` 指针遍历 vs `ListBaseT<T>` 的 range-for，见 §10.2.2），
  跟着最近的写法走最安全。
]

=== 11.6.3 第三步：声明与注册

*3a. 在 #src("source/blender/editors/object/object_intern.hh") 里声明。*
和其他 `OBJECT_OT_*` 声明放一起。这个头文件的声明形式是：

```cpp
void OBJECT_OT_report_selected_count(wmOperatorType *ot);
```

*3b. 在 `operatortypes_object()` 里加一行。*
位置在 #src("source/blender/editors/object/object_ops.cc:29-L31") 的清单里，
建议加在 `OBJECT_OT_select_all` 附近以保持分组清晰：

```cpp
void operatortypes_object()
{
  ...
  WM_operatortype_append(OBJECT_OT_select_all);
  WM_operatortype_append(OBJECT_OT_report_selected_count);   /* ← 新增 */
  ...
}
```

*3c. 关于 `RNA_def_*`：本操作符不需要。*
这是一个重要的判断点。`RNA_def_*` 只在*操作符需要属性*时才写。
我们的操作符没有参数，所以 `ot->srna`（由 `__begin` 建好）保持空属性即可。
对比一下需要属性的场合（#src("source/blender/windowmanager/intern/wm_operators.cc:2208-L2212")）：

```cpp
PropertyRNA *prop;

prop = RNA_def_string(ot->srna, "name", nullptr, BKE_ST_MAXNAME, "Name", "Name of the menu");
RNA_def_property_flag(prop, PROP_SKIP_SAVE);
```

三个判断规则：

#figure(
  kind: table,
  table(
    columns: (2.0fr, 1.5fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*情况*], [*要不要 `RNA_def_*`*]),
    [操作符没有参数（如本节的统计操作符）], [不要。`ot->srna` 留空属性],
    [有参数、且希望用户能在"调整上一步"面板里改], [要。定义在 `ot->srna` 上],
    [有参数、且希望 Python 侧能用关键字参数传], [要。Python 侧看到的就是这些 RNA 属性],
    [参数只是内部开关、不想让用户看见], [可以要，然后用 `RNA_def_property_flag(prop, PROP_HIDDEN)` 隐藏],
  ),
  caption: [什么时候需要声明操作符属性],
) <tbl-when-rna-def>

*3d. 构建并验证注册成功。* 重新构建后，启动 Blender，打开 Python 控制台：

```python
>>> import bpy
>>> hasattr(bpy.ops.object, "report_selected_count")
True
>>> bpy.ops.object.report_selected_count()
{'FINISHED'}
```

如果 `hasattr` 返回 `False`，按顺序检查这四件事：

1. `WM_operatortype_append(OBJECT_OT_report_selected_count);` 这一行加了没有；
2. `operatortypes_object()` 是否真的被调用（它在 `SpaceType::operatortypes` 链上，
   见 #src("source/blender/editors/space_view3d/space_view3d.cc:1608")）；
3. `idname` 是否符合 `_OT_` 规则（§11.5.1）；
4. 你的文件是否真的被重新编译（Ninja 有时会因为头文件依赖没更新而跳过 ——
   先试 `ninja` 全量再试 `ninja install`）。

#note[
  *`OBJECT_OT_*` 这个名字前缀不决定操作符注册在哪个编辑器下。*
  它在功能上只是一段字符串。`bpy.ops.object.xxx` 的 `object` 部分
  完全由 `idname` 里 `_OT_` 之前的内容决定（§11.5.1）。
  你可以注册一个 `OBJECT_OT_foo` 然后只在图像编辑器里 `poll` 通过 —— 逻辑上没问题，
  但会让人困惑。*命名与实际归属保持一致是团队约定，不是技术约束。*
]

=== 11.6.4 第四步：挂到菜单

有两种方式，选哪种取决于你的操作符是"给人用的"还是"给脚本用的"。

方式 A：Python 内置 UI（推荐，改起来最快）

3D 视图的 Object 菜单定义在 #src("scripts/startup/bl_ui/space_view3d.py")。
添加菜单位置的关键是找对 `Menu` 类。用 grep 定位：

```bash
$ rg -n "class VIEW3D_MT_object" scripts/startup/bl_ui/space_view3d.py
```

然后在对应的 `draw` 方法里加一行 `layout.operator(...)`。
真实例子（#src("scripts/startup/bl_ui/space_view3d.py:2428-L2430")）：

```python
        layout.operator("mesh.primitive_plane_add", text="Plane", icon='MESH_PLANE')
        layout.operator("mesh.primitive_cube_add", text="Cube", icon='MESH_CUBE')
        layout.operator("mesh.primitive_circle_add", text="Circle", icon='MESH_CIRCLE')
```

你的那一行：

```python
        layout.operator("object.report_selected_count", text="Report Selected Count")
```

说明：

- *参数用的是 Python 风格名字*（`object.report_selected_count`），
  不是 `OBJECT_OT_report_selected_count`。转换由 §11.5.1 的两个函数负责。
- `text=` 覆盖显示名。不写就用 `ot->name`。
- `icon=` 指定图标。图标名是枚举值，见 `makesrna` 里的图标定义。
- 也可以用 `layout.operator_context` 控制走 `invoke` 还是 `exec`，
  真实例子（#src("scripts/startup/bl_ui/space_view3d.py:2696")）：

  ```python
        layout.operator_context = 'EXEC_REGION_WIN'
  ```

  以及注释里解释为什么（#src("scripts/startup/bl_ui/space_view3d.py:2692-L2695")）：

  ```python
        # NOTE: don't use 'EXEC_SCREEN' or operators won't get the `v3d` context.

        # NOTE: was `EXEC_AREA`, but this context does not have the `rv3d`, which prevents
        #       "align_view" to work on first call (see #32719).
  ```

  *这两行注释是本节最值得记住的东西*：菜单里的 `operator_context` 直接决定
  操作符能拿到什么上下文。写错了不是崩溃，而是"某些功能莫名其妙不工作"。

#tip[
  快速迭代的技巧：*Python 内置 UI 可以通过把文件复制到 `scripts/startup/bl_ui/`
  之外的地方来免重编译测试* —— 但更简单的做法是先写成插件里的 `Panel` / `Menu`，
  验证逻辑正确后再搬进内置 `bl_ui`。
  另外，你也可以不改任何源码，直接用 Python 往菜单上挂：

  ```python
  import bpy

  def menu_func(self, context):
      self.layout.operator("object.report_selected_count")

  bpy.types.VIEW3D_MT_object.append(menu_func)
  ```

  *这是最高效的原型验证路径*：先确认功能对，再决定是否改源码。
]

方式 B：C++ 侧菜单（如果菜单本身是 C++ 定义的）

不是所有菜单都在 Python 里。较老的编辑器（以及一些内部菜单）
仍在 C++ 里用 `uiItem*` 系列函数构建。第 12 章会给出 C++ 菜单的完整写法。
这里给出判断方法：

```bash
$ rg -n "MY_MENU_IDNAME" source/ scripts/
```

如果只在 `source/` 里出现，就是 C++ 菜单；只在 `scripts/` 里出现，就是 Python 菜单。

=== 11.6.5 第五步：加 keymap

快捷键在 C++ 侧注册。3D 视图的键映射函数是
`view3d_keymap(wmKeyConfig *keyconf)`
（#src("source/blender/editors/space_view3d/view3d_ops.cc:268-L283")）：

```cpp
void view3d_keymap(wmKeyConfig *keyconf)
{
  WM_keymap_ensure(keyconf, "3D View Generic", SPACE_VIEW3D, RGN_TYPE_WINDOW);

  /* only for region 3D window */
  WM_keymap_ensure(keyconf, "3D View", SPACE_VIEW3D, RGN_TYPE_WINDOW);

  fly_modal_keymap(keyconf);
  walk_modal_keymap(keyconf);
  viewrotate_modal_keymap(keyconf);
  viewmove_modal_keymap(keyconf);
  viewzoom_modal_keymap(keyconf);
  viewdolly_modal_keymap(keyconf);
  viewplace_modal_keymap(keyconf);
  vr_location_scouting_capture_review_modal_keymap(keyconf);
}
```

它的声明在 #src("source/blender/editors/space_view3d/view3d_navigate.hh:278")，
挂载点是 `SpaceType::keymap`（#src("source/blender/editors/space_view3d/space_view3d.cc:1609")）：

```cpp
  st->keymap = view3d_keymap;
```

也就是说，*`SpaceType` 通过两个字段分别注册操作符与快捷键*：

```cpp
// source/blender/editors/space_view3d/space_view3d.cc:1608-L1609
  st->operatortypes = view3d_operatortypes;
  st->keymap = view3d_keymap;
```

*这就是"新操作符要能被界面调用"的完整挂载点。*
第 12 章会给出 `SpaceType` 的全部字段。

加一条快捷键

`WM_keymap_add_item` 的签名是三个参数
（#src("source/blender/windowmanager/WM_keymap.hh:98-L100")）：

```cpp
wmKeyMapItem *WM_keymap_add_item(wmKeyMap *keymap,
                                 const char *idname,
                                 const KeyMapItem_Params *params);
```

所以要构造一个 `KeyMapItem_Params`。真实调用点（#src("source/blender/windowmanager/gizmo/intern/wm_gizmo_group.cc:845")）：

```cpp
      wmKeyMapItem *kmi = WM_keymap_add_item(km, "GIZMOGROUP_OT_gizmo_select", &params);
```

完整写法（加在 `view3d_keymap` 里，注意要先 `WM_keymap_ensure` 拿到 `wmKeyMap *`）：

```cpp
void view3d_keymap(wmKeyConfig *keyconf)
{
  /* only for region 3D window */
  wmKeyMap *keymap = WM_keymap_ensure(keyconf, "3D View", SPACE_VIEW3D, RGN_TYPE_WINDOW);

  /* Ctrl+Shift+C：统计选中物体数量。
   * 修饰键字段的语义见 source/blender/windowmanager/WM_keymap.hh:58-L80。 */
  const KeyMapItem_Params params{
      /*type*/ EVT_CKEY,
      /*value*/ KM_PRESS,
      /*modifier*/ KM_CTRL | KM_SHIFT,
      /*keymodifier*/ 0,
      /*direction*/ KM_ANY,
  };
  WM_keymap_add_item(keymap, "OBJECT_OT_report_selected_count", &params);

  ...
}
```

#warn[
  上面这段代码里有两个需要你核对的点：

  1. *核对 `KeyMapItem_Params` 的字段顺序与数量。*
     结构体定义在 #src("source/blender/windowmanager/WM_keymap.hh:58-L80")，
     字段依次是 `type`、`value`、`modifier`、`keymodifier`、`direction`。
     用指定初始化器（C++20 designated initializers，即 `.type = ...`）写更安全，
     前提是你的编译器与项目的 C++ 标准允许
     （Blender 5.x 要求 C++20 或更高，所以通常可以）。
  2. *核对 `EVT_CKEY` 这个常量名。* 事件类型常量既有裸名
     （`LEFTMOUSE`、`MOUSEMOVE`）又有 `EVT_` 前缀名
     （`EVT_AKEY`、`EVT_RETKEY`、`EVT_ESCKEY`），见 §11.2.1 的表。
     *在 #src("source/blender/windowmanager/WM_event_types.hh") 里确认你要的那个字母键的实际名字*，
     不要照抄别的字母。

  另外 `KM_ANY` 用在 `direction` 字段上是"忽略方向"的意思
  （#src("source/blender/windowmanager/WM_types.hh:338-L341")），
  用在 `value` 字段上是"按下或释放都触发"，同一个常量两种语义。
]

让用户能改快捷键

你不需要做任何事 —— 键映射项一旦注册，就自动出现在
用户偏好设置的 Keymap 编辑器里，可以改、可以恢复默认。
这正是 §11.2.2 里 `wmKeyMapItem::id` 正负号设计的价值：
内置项是负数 id，用户覆盖是正数 id，"恢复默认"只需删掉正数那些。

模态操作符的额外两步

如果你加的是模态操作符（§11.2.3），还要：

1. 在 `view3d_keymap` 里（或你自己的 `xxx_modal_keymap` 函数里）
   调用 `WM_modalkeymap_ensure` + `WM_modalkeymap_assign`
   （参考 #src("source/blender/editors/space_view3d/view3d_navigate_fly.cc:102-L144")）；
2. 把 `view3d_keymap` 里加上对这个 `xxx_modal_keymap` 函数的调用
   （就像 #src("source/blender/editors/space_view3d/view3d_ops.cc:275-L282") 里
   那一串 `fly_modal_keymap(keyconf);` 的写法）。

#pitfall[
  模态键映射有一个必须在源码里遵守的约定
  （#src("source/blender/editors/space_view3d/view3d_navigate_fly.cc:135-L138")）：

  ```cpp
  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }
  ```

  *`keymap` 函数会被每个 `SpaceType` 调用一次。*
  没有这个短路检查，同一个模态映射会被建立多次，
  轻则快捷键重复、重则内存泄漏（`WM_modalkeymap_ensure` 会新建对象）。
  这个模式在源码里被反复使用，加模态映射时务必照抄。
]

=== 11.6.6 第六步：验证清单

做完以上改动后，按这个顺序验证（每一步失败都对应一个明确的原因）：

#figure(
  kind: table,
  table(
    columns: (auto, 1.5fr, 1.6fr),
    inset: 6pt,
    align: (left, left, left),
    stroke: 0.4pt + luma(78%),
    table.header([\*序\*], [*验证动作*], [*失败说明什么*]),
    [1], [构建通过，无 `BLI_assert` 崩溃],
    [`idname` 不合规，或重复注册（§11.1.2 的 `add_new` 断言）],
    [2], [`hasattr(bpy.ops.object, "report_selected_count")` 为 `True`],
    [没加注册调用，或 `operatortypes_object()` 没被执行],
    [3], [Python 里 `bpy.ops.object.report_selected_count()` 返回 `{'FINISHED'}`],
    [`poll` 不通过，或 `exec` 里提前返回了非 `FINISHED`],
    [4], [状态栏出现 "Selected objects: N"],
    [`op->reports` 没写，或 `BKE_reportf` 的报告类型被过滤],
    [5], [菜单里能看到条目，点它有效果],
    [`draw` 方法里的 `layout.operator` 名字拼错，或菜单类选错],
    [6], [快捷键触发有效效果],
    [`WM_keymap_add_item` 加错了键映射（`spaceid` / `regionid` 不匹配）],
    [7], [执行一次后按 Ctrl+Z，再 Ctrl+Shift+Z 能回到原状态],
    [`OPTYPE_UNDO` / `OPTYPE_REGISTER` 没设，或 notifier 没发],
    [8], [`blender -d` 退出时无新增泄漏报告],
    [`customdata` 或自己分配的内存没释放（§11.1.4）],
  ),
  caption: [新增操作符的验证清单。每一步失败的原因都很具体，按表排查比盲目读代码快得多],
) <tbl-op-verify-checklist>

#exercise[
  *练习 11.1 —— 完整跟做 §11.6。*

  1. 按 §11.6.1 到 §11.6.5 把操作符加进去。
     *请在动手前先在你自己克隆的源码里 grep 确认三件事*：
     `view_layer->object_bases` 的实际字段名、
     `BASE_SELECTED` 的实际标志名、
     以及字母 `C` 对应的事件常量名（是 `EVT_CKEY` 吗？）。
  2. 构建、启动、按验证清单逐项确认（表 <tbl-op-verify-checklist>）。
  3. *故意破坏一次，观察症状。* 依次做下面三件事，每次只改一处、
     重新构建、再观察：
     - 注释掉 `ot->flag = OPTYPE_REGISTER | OPTYPE_UNDO;` —— 撤销与"调整上一步"如何变化？
     - 注释掉 `WM_event_add_notifier(...)` —— 界面有变化吗？为什么（或不为什么）？
     - 把 `ot->idname` 改成 `"OBJECT_report_selected_count"`（去掉中间的 `_OT_`）——
       在哪一步失败？错误信息是什么？
     这三组对照实验比读十遍源码更能让你记住本章的内容。
  4. 执行一次 `blender -d`，确认 §11.1.5 提到的
     "等效 Python 调用串"被打印出来（提示：需要 `G_DEBUG_WM`，
     也就是 `--debug-wm`），把你操作后的那行输出记下来。

  *练习 11.2 —— 写一个真正需要撤销的模态操作符。*

  设计一个 `OBJECT_OT_scatter_selected`：按住左键拖动时，
  让所有选中物体沿鼠标拖拽方向做一次位移，松开左键确认，按 Esc 取消。

  要求（每一条都对应本章的一个知识点）：

  1. 用 `invoke` 注册模态处理器（§11.2.3），把初始状态存进
     `op->customdata`（§11.1.4）。
  2. 建立模态键映射，至少包含 `CONFIRM`（左键松开）与 `CANCEL`（Esc）两个模态值，
     并用 `WM_modalkeymap_assign` 绑到 `OBJECT_OT_scatter_selected`
     （参考 #src("source/blender/editors/space_view3d/view3d_navigate_fly.cc:102-L144")）。
  3. `modal` 里读取 `event->xy` 与 `event->prev_press_xy`（§11.2.1），
     计算位移并修改物体的 `loc`。
  4. 每次修改后发 notifier 让视图刷新（§11.3.1）。
     注意思考：应该发 `NC_OBJECT | ND_TRANSFORM`，还是
     `NC_SPACE | ND_SPACE_VIEW3D`？两者的 listener 分别是谁？
  5. 设置 `ot->flag = OPTYPE_REGISTER | OPTYPE_UNDO`。
     然后在 `modal` 的 `FINISHED` 分支里检查一次：
     *撤销栈里应该只有一步*，而不是拖动过程中的每一步。
     如果发现有多步，说明你需要 `OPTYPE_UNDO_GROUPED`
     或 `ED_undo_group_begin` / `ED_undo_group_end`（§11.4）。
  6. *务必在所有退出路径上释放 `op->customdata`*，
     然后用 `blender -d` 验证没有泄漏（§11.1.4 的陷阱框）。
  7. 按 Esc 取消时，确认物体回到了拖动开始前的位置 ——
     这意味着你的 `cancel` 路径必须自己恢复数据，
     框架不会帮你（`cancel` 回调的签名见
     #src("source/blender/windowmanager/WM_types.hh:1130")）。

  *练习 11.3 —— 追一条 notifier。*

  1. 在 #src("source/blender/editors/space_view3d/space_view3d.cc:1420")
     读 `space_view3d_listener` 的完整实现。
  2. 列出它处理了哪些 `NC_` / `ND_` 组合，每种组合它做了什么
     （打脏标记？改缓存？什么都不做？）。
  3. 回答这个问题：*如果我在 `exec` 里改了 `ob->loc` 但完全不发 notifier，
     界面最终会更新吗？* 给出你的推理，然后在源码里找一个
     "确实会在某一时刻强制重绘"的机制来验证（提示：想想
     `ob->id.recalc` 与依赖图标记、以及哪些动作会无条件触发重绘）。
  4. 最后回答：为什么 Blender 选择"notifier 驱动重绘"而不是
     "每帧检查脏标记"？从性能与代码可维护性两个角度各给一条理由。
]
