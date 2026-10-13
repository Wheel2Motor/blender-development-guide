#import "../common.typ": *

= 附录 E 常见问题

本附录收集实际开发中最容易卡住的问题。凡是本书核对基准版本上验证过的现象，
都会给出可直接执行的诊断或修复命令；凡是属于经验性建议的，会明确写成建议。

== E.1 源码获取与依赖

=== E.1.1 克隆到一半被中断，之后 git 好像坏了

这是本书编写过程中真实遇到的情况，症状很有辨识度：

- `git ls-files` *没有任何输出*（索引为空），
- `git status` 把成千上万个文件显示为已删除（`D`），
- 任何写索引的命令都报「另一个 git 进程似乎正在运行」，提示你删除锁文件。

原因通常是 `git clone` 检出阶段（尤其 Git LFS 正在过滤内容时）被强制中断，
索引还没写完，同时留下了 `.git/index.lock`。

#pitfall[
  不要急着重新克隆。先按下面的顺序处理，通常几分钟就能恢复，省下几 GB 的重复下载。
]

```bash
# 1) 确认没有活跃的 git / git-lfs 进程（有的话先等它结束，或确认是残留后再终止）
$ Get-Process git,git-lfs -ErrorAction SilentlyContinue

# 2) 确认锁文件确实是残留
$ Get-Item .git\index.lock

# 3) 删除锁文件（仅在确认没有活跃 git 进程后）
$ Remove-Item .git\index.lock

# 4) 用 mixed reset 从 HEAD 重建索引；工作区文件不受影响
$ git reset

# 5) 验证：索引条目数应等于仓库文件数，且子模块应重新可见
$ git ls-files | Measure-Object
$ git submodule status
```

修复后 `git submodule status` 会列出 `.gitmodules` 里的子模块（未初始化的前面带 `-`）。

=== E.1.2 为什么 `git submodule update` 没有任何反应

因为预编译库的子模块在 `.gitmodules` 里被显式标成了不自动更新：

#raw(
  "# .gitmodules（节选）\n"
  + "[submodule \"lib/windows_x64\"]\n"
  + "\tupdate = none\n"
  + "\tpath = lib/windows_x64\n"
  + "\turl = https://projects.blender.org/blender/lib-windows_x64.git\n"
  + "\tbranch = " + blender-branch,
  block: true,
  lang: "text",
)

这是有意为之——四个平台的库加起来很大，不应该因为一次 `git submodule update --recursive`
就全拉下来。要单独启用某个平台，先打开它的 update 策略再更新：

```bash
$ git config --local submodule.lib/windows_x64.update checkout
$ git submodule update --init lib/windows_x64
```

Windows 上的 `make.bat update` 与 macOS/Linux 上的 `make update` 会自动完成这套配置。

=== E.1.3 我只想要源码，不想下几 GB 的测试数据

主仓库自身的 Git LFS 内容里，*绝大多数是回归测试数据*，但不能因此跳过全部 LFS。
构建真正需要的是：

- `release/datafiles/` 下的资源——其中 `startup.blend`、预览文件和部分图标数据也是
  LFS 对象，首次配置前必须还原；
- `lib/<平台>_<架构>/` 子模块里的预编译依赖库。

所以可以在克隆阶段暂时跳过 LFS 内容以加快 Git 检出，但*不能直接开始配置*。
随后执行 `make update`（#win 为 `make.bat update`）会同时补主仓库 LFS 与平台库；
也可以先单独补主仓库对象：

```bash
$ git lfs pull
```

=== E.1.4 预编译库要下多久？能中途停吗

Windows 平台的库在 3 GB 量级，且大文件（例如 LLVM）传输很慢。源码里对这个阶段
有一段明确的警告：第一次下载完成后，还会发生一次「看不出进度」的更大更新，
可能超过一小时，*不要中断*。

#tip[
  最省时的做法是一次性让它跑完，然后不再想它。中途反复中断容易留下
  E.1 第一节那种索引与锁文件的残留状态，反而更费时间。
]

验证库是否真的就绪，最可靠的方式是抽查几个关键依赖是否存在*实体文件*
（而不是几行文本的 LFS 指针）：

```bash
# LFS 指针文件的第一行形如：version https://git-lfs.github.com/spec/v1
$ Get-Content lib\windows_x64\python\...\python.exe -TotalCount 1
```

如果第一行是 LFS 指针而不是二进制内容，说明该文件还没被还原。

=== E.1.5 构建时报「找不到外部库」

按顺序检查三件事：

1. 库目录是否存在且非空：`lib/windows_x64`（Windows x64）等；
2. 该目录下是否有子模块的 `.git` 标记（Windows 构建脚本正是用它判断库是否就绪的）；
3. 平台与架构是否匹配（例如 arm64 机器却只下了 `windows_x64`）。

== E.2 构建

=== E.2.1 Windows 上执行 `make` 报错

这不是环境问题，而是设计如此。源码根目录的 `GNUmakefile` 里写得很明确：

```text
# GNUmakefile:175
# This makefile is not meant for Windows,
```

Windows 请使用同目录下的 `make.bat`：

```bash
$ make.bat ninja
```

上面的写法适用于 `cmd.exe`。PowerShell 要写 `./make.bat ninja`，Git Bash 也写
`./make.bat ninja`；不要让 GNU Make 去处理源码根目录的 `GNUmakefile`。

两者的语义是对齐的（同样的构建类型、同样的配置预览文件），只是入口脚本与
环境检测方式不同。#mac #linux 用 `make`，#win 用 `make.bat` —— 记这一条就够。

=== E.2.2 改了 CMake 选项却不生效

CMake 把缓存写在构建目录里，改选项后必须让它重新配置。用 `make.bat nobuild`（#win）
可以只生成或重新配置工程而不编译。#mac #linux 的 `make config` 含义不同：它只会对
*已有构建目录*打开 `cmake-gui` 或 `ccmake`，让你编辑缓存并手动重新配置；它不能从零
创建构建目录。首次配置应运行 `make`，或直接使用 `cmake -S <源码> -B <构建目录>`。
如果怀疑缓存本身有问题，删掉构建目录重来往往比排查更快。

=== E.2.3 想更快地增量构建

- 首次构建成功后，构建目录里会生成 `rebuild.cmd`（#win）。它自己会激活编译器环境，
  直接运行它即可增量重建，比再走一遍 `make.bat` 快。
- 编译缓存能显著缩短重复构建时间：`make.bat ninja sccache`（#win）与 `make ccache`（#mac #linux）。
- 只改了几个文件时，让构建系统自己决定要重编什么，不要动辄 `clean`。

=== E.2.4 Release、Debug、developer、lite 怎么选

#figure(
  kind: table,
  table(
    columns: (auto, 1.6fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*构建*], [*适用场景*]),
    [`Release`（默认）], [日常使用、跑测试、截图。运行最快，但没有调试符号],
    [`debug`], [需要断点与单步调试时。体积大、运行慢，但符号完整],
    [`developer`], [开发时推荐：打开更多检查与开发者向默认选项],
    [`lite`], [只要一个能跑的精简版本。编译时间明显更短],
    [`full`], [需要全部可选功能时],
  ),
  caption: [构建类型的取舍],
) <tbl-e-build-types>

=== E.2.5 路径里有空格

Windows 的构建脚本会主动检查并拒绝含空格的路径。把源码放在不含空格的目录下，
或者用短路径（8.3 名称）绕开。这类问题在别处往往表现为莫名其妙的链接错误，
不如一开始就避开。

== E.3 运行与调试

=== E.3.1 一启动就崩，怀疑是插件

用 `-X` / `--factory-startup` 以出厂设置启动，它会*忽略用户配置与已启用的插件*。
如果这样能正常启动，问题就在插件或用户配置里，再逐个启用来定位。

```bash
$ blender -X
```

=== E.3.2 脚本化调用失败了，但退出码是 0

Blender 默认不会因为 Python 脚本抛异常而返回非零退出码。批处理与 CI 里必须显式要求它：

```bash
$ blender --background --python-exit-code 1 --python my_script.py
```

=== E.3.3 依赖图到底在干什么

依赖图有一整套专用调试参数，第一次排查建议先用「带耗时」的那个，它能告诉你时间
花在哪个环节：

```bash
$ blender --background --debug-depsgraph-time my_file.blend
```

如果输出顺序难以阅读，加上 `--debug-depsgraph-no-threads` 让它单线程求值，
输出就变成确定的顺序了。完整参数列表见附录 C.4.3。

=== E.3.4 只想看某一类日志

`--log` 支持通配与排除，比全局开 `--debug-all` 精确得多。源码自带的帮助里给出了
用法示例：

```bash
$ blender --log "*"              # 全部类别
$ blender --log "render,cycles"  # 只看两类
$ blender --log "*mesh*"         # 类别名含 mesh 的
$ blender --log "*,^operator"    # 除 operator 之外的全部
```

不确定有哪些类别可用时，先 `--log-list-categories`。

=== E.3.5 在没有界面的机器上跑

`--background` 是无界面模式。如果是要长期部署（例如渲染农场），可以构建
`headless` 配置（#win `make.bat headless`，#mac #linux `make headless`），
它去掉了界面相关部分。

== E.4 Python 插件

=== E.4.1 改了插件代码却不生效

Python 解释器会缓存已导入的模块。改完代码通常有两条路：

- *退出并重启 Blender*（最可靠）；
- 在脚本编辑器里*手工重载*模块，或先禁用再启用插件。

第二种方式更快，但对「模块级常量」「已注册的类」这类东西并不总是彻底 ——
类的注册与注销有顺序依赖，重载后容易出现新旧实现混在一起的情况。

#tip[
  如果你在频繁迭代，把插件代码写成一个*独立进程可测试*的形式（核心逻辑不依赖
  `bpy`），用普通的 Python 测试跑它，只在最后验证与 Blender 的接线。这会省掉大量重启。
]

=== E.4.2 插件卸载后还有残留

`unregister()` 必须把 `register()` 做过的事*全部且按相反顺序*撤销。常见遗漏有：

- 注册了类却忘了从 `bpy.types` 注销；
- 往菜单或快捷键里加了条目，但没有移除；
- 注册了定时器（`bpy.app.timers`）或处理器（`bpy.app.handlers`）却没有反注册。

判断标准很简单：*启用 → 禁用 → 再启用*，如果第二次启用报「已存在」之类的错误，
就是卸载不干净。

=== E.4.3 `context is incorrect` / 操作符的 `poll` 失败

`bpy.ops` 的调用依赖当前上下文。同一个操作符在不同编辑器、不同模式下可能不可用，
这正是它的 `poll` 在起作用。排查时：

- 先确认当前 `context.area.type`、`context.mode` 是否满足该操作符的要求；
- 在批处理脚本里，不要依赖界面上下文——优先直接操作数据 API（`bpy.data` / `bmesh`）
  而不是 `bpy.ops`。

=== E.4.4 `bpy.props` 的属性定义改了没反应

属性是在类注册时被登记的，`bpy.props` 的定义属于「注册元数据」而不是普通数据。
改了属性定义（类型、取值范围、枚举项）通常必须重启 Blender 才生效 ——
这与上一节「改了函数体可以重载」是两回事。

=== E.4.5 多文件插件的导入失败

多文件插件的包名是它会话内唯一的标识。常见问题是写成了「相对导入看起来能用、
实际上依赖了当前工作目录」。稳妥做法是始终使用相对导入（`from . import xxx`），
并且不要在模块导入时执行有副作用的 Blender API 调用（那些应该放在 `register()` 里）。

== E.5 C++ 源码修改

=== E.5.1 改完数据但界面不刷新

改完数据后必须*发通知*，界面才会重绘。不发通知的典型症状是：数据确实变了
（在 Python 控制台里能读到新值），但视图一动不动，直到你手动移动一下视角。

这是第 11 章的重点之一，请参考 §11.3。

=== E.5.2 撤销不工作

C++ 侧的操作符必须显式声明它要进入撤销栈，靠的是 `ot->flag` 里的两个位：

```cpp
/* source/blender/windowmanager/WM_types.hh:184, :186 */
OPTYPE_REGISTER = (1 << 0),
OPTYPE_UNDO = (1 << 1),
```

```cpp
ot->flag = OPTYPE_REGISTER | OPTYPE_UNDO;
```

这两个位在 Python 侧就是操作符的 `bl_options`，可见 #src("source/blender/makesrna/intern/rna_wm.cc:552")
的 `"REGISTER"` 与 #src("source/blender/makesrna/intern/rna_wm.cc:557") 的 `"UNDO"`。
也就是说：Python 写 `bl_options = {'REGISTER', 'UNDO'}`，等价于 C 侧设这两个位。

撤销栈的实际判断逻辑在 #src("source/blender/windowmanager/intern/wm_event_system.cc")，
其中多处按 `OPTYPE_UNDO` 分支（例如 `:1307`、`:1396`、`:1699`），值得对照阅读。

=== E.5.3 给 DNA 加了字段之后的兼容问题

给一个数据类型加字段会改变它的序列化布局，因此：

- 旧版本 `.blend` 文件在新版中打开需要*版本迁移*逻辑；
- 新版写出的文件，旧版可能无法正确读取。

这不是「能不能加」的问题，而是「加了之后要负责迁移」。第 9 章给出了完整的
DNA + RNA + 版本迁移的联动做法，详见 §9.2 与 §9.6。

=== E.5.4 怎么快速定位该改哪一行

不要通读代码。三条反查路径（详见 §8.3）：

1. *界面反查*：从界面上的文字开始搜，找到定义它的位置，再顺着回调下去；
2. *数据反查*：从数据结构或字段名开始搜，找到读写它的地方；
3. *调用栈反查*：在调试器里下断点，从运行时栈往上找。

附录 C.5 列出了这几种套路的具体检索方式。

#summary[
  本附录里最值得记住的三条：*#win 用 `make.bat` 而不是 `make`*；
  *排查问题先加 `-X` 排除插件与用户配置干扰*；
  *改完数据一定要发通知，否则界面不会刷新*。
]
