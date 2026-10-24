#import "../common.typ": *

= 附录 E Blender 构建与开发排错

本附录按症状整理源码获取、构建、运行与开发中的高频故障。遇到问题时，先找到最接近的
症状，再按检查顺序逐项排除；不要一开始就删除整个构建目录或重新克隆仓库。

== E.1 源码获取与依赖

=== E.1.1 官方仓库连接不稳定时，怎样选择镜像

Blender 的主仓库地址是：

```text
https://projects.blender.org/blender/blender.git
```

如果克隆时反复超时或中断，可以改用下面两种来源取得 Git 对象：

- `https://github.com/blender/blender.git` 是 Blender 官方维护的 GitHub 镜像。Blender
  官方文档明确说明，开发仍在 `projects.blender.org` 进行，而且 GitHub 镜像不包含
  Git LFS 文件（#weblink("https://developer.blender.org/docs/handbook/contributing/using_git/clone_update/#github-mirror", label: [Git Clone and Update: GitHub Mirror])）。
- `https://gitee.com/mirrors/blender.git` 是 Gitee（码云）国内代码托管平台上的同步镜像。
  对中国大陆读者而言，国内网络链路通常更短；在官方仓库或 GitHub 连接缓慢、频繁中断时，
  可以优先测试这个地址。Gitee 对自身平台的介绍见
  #weblink("https://gitee.com/about_us", label: [关于 Gitee])。

#note[
  镜像速度会随地区、运营商和时段变化，而且同步进度可能落后。先检查目标分支与提交是否存在，
  再开始大体积下载，可以避免克隆结束后才发现版本不全。
]

先确认镜像公开了前言所列的发布分支：

#raw(
  "$ git ls-remote --exit-code --heads <镜像 URL> " + blender-branch,
  block: true,
  lang: "bash",
)

命令成功只说明分支存在，不能证明前言所列的固定提交已经同步。已经安装 Git LFS 时，
直接克隆不提供 LFS 对象的镜像，还可能在 Git 对象下载完成后才在 checkout 阶段失败。
因此应先跳过 LFS smudge。#linux 与 #mac 使用：

#raw(
  "$ export GIT_LFS_SKIP_SMUDGE=1\n"
  + "$ git clone --branch " + blender-branch + " \\\n"
  + "    --single-branch <镜像 URL> blender\n"
  + "$ unset GIT_LFS_SKIP_SMUDGE",
  block: true,
  lang: "bash",
)

#win 的 PowerShell 写法是：

#raw(
  "$env:GIT_LFS_SKIP_SMUDGE = \"1\"\n"
  + "git clone --branch " + blender-branch + " `\n"
  + "  --single-branch <镜像 URL> blender\n"
  + "Remove-Item Env:GIT_LFS_SKIP_SMUDGE",
  block: true,
  lang: "powershell",
)

#block(breakable: false)[
  克隆结束后，先确认固定提交存在，再直接检出该提交，并从官方仓库补齐 LFS 对象：

  #raw(
    "$ cd blender\n"
    + "$ git cat-file -e " + blender-commit + "^{commit}\n"
    + "$ git switch --detach " + blender-commit + "\n"
    + "$ git remote add lfs-fallback \\\n"
    + "    https://projects.blender.org/blender/blender.git\n"
    + "$ git config lfs.remote.searchall true\n"
    + "$ git lfs pull lfs-fallback\n"
    + "$ git rev-parse HEAD\n"
    + blender-commit,
    block: true,
    lang: "bash",
  )
]

如果 `git cat-file` 失败，说明镜像尚未包含目标提交；不要用分支顶端的另一个提交
替代。镜像只负责提供 Git 对象，平台预编译库与缺失的 Git LFS 对象仍应从
`projects.blender.org` 获取。

=== E.1.2 克隆中断后，索引或锁文件异常

这类中断的症状很有辨识度：

- `git ls-files` *没有任何输出*（索引为空），
- `git status` 把成千上万个文件显示为已删除（`D`），
- 任何写索引的命令都报「另一个 git 进程似乎正在运行」，提示你删除锁文件。

原因通常是 `git clone` 检出阶段（尤其 Git LFS 正在过滤内容时）被强制中断，
索引还没写完，同时留下了 `.git/index.lock`。

#pitfall[
  不要急着重新克隆。只要 Git 对象已经下载完成，通常可以重建索引，避免重复下载数 GB 数据。
]

```powershell
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

#mac 与 #linux 可用 `ps` 或 `pgrep` 确认没有残留的 `git` / `git-lfs` 进程，再用
`test -e .git/index.lock` 检查锁文件；确认它确实是残留后删除，随后同样执行
`git reset`、`git ls-files` 与 `git submodule status`。锁文件存在并不自动意味着可以删除：
若仍有 Git 进程在工作，应等待它结束。

=== E.1.3 为什么 `git submodule update` 没有任何反应

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

这是有意为之——不同平台与架构的库加起来很大，不应该因为一次 `git submodule update --recursive`
就全拉下来。要单独启用某个平台，先打开它的 update 策略再更新：

```bash
$ git config --local submodule.lib/windows_x64.update checkout
$ git submodule update --init lib/windows_x64
```

Windows 上的 `make.bat update` 与 macOS/Linux 上的 `make update` 会自动完成这套配置。

=== E.1.4 只阅读源码时，可以暂缓哪些下载

如果还不清楚“Git 仓库里的指针”和“LFS 服务里的实体文件”是什么关系，先读 §2.2.1
的「先理解 Git LFS」；下面只讨论哪些对象可以暂缓下载。

主仓库自身的 Git LFS 内容里，*绝大多数是回归测试数据*，但不能因此跳过全部 LFS。
构建真正需要的是：

- `release/datafiles/` 下的资源——其中 `startup.blend`、预览文件和部分图标数据也是
  LFS 对象，首次配置前必须还原；
- `lib/<平台>_<架构>/` 子模块里的预编译依赖库。

如果只是阅读和检索源码，可以在克隆阶段暂时跳过 LFS 内容；准备配置和构建之前，
则必须还原构建所需资源并取得当前平台的预编译库。
随后执行 `make update`（#win 为 `make.bat update`）会同时补主仓库 LFS 与平台库；
也可以先单独补主仓库对象：

```bash
$ git lfs pull
```

=== E.1.5 预编译库下载很慢，能否中断

预编译库通常有数 GB，其中还包含 LLVM 等大文件。下载完成后，Git LFS 还可能经历一段
输出很少的检出过程；此时进程仍在工作，并不表示卡死。只要磁盘或网络仍有活动，就应继续等待。

#tip[
  尽量让首次下载与检出一次完成。反复中断容易留下 E.1.2 所述的空索引或锁文件，
  后续恢复所花的时间往往比继续等待更长。
]

验证库是否真的就绪，应先检查该子模块列出的全部 LFS 路径：

```bash
$ git -C lib/<平台>_<架构> lfs ls-files
```

OID 后面不应出现表示工作区仍为指针的 `-`。若需要进一步检查可疑路径，再读取文件头；
实体二进制文件不应显示 LFS 指针文本：

```powershell
# LFS 指针文件的第一行形如：version https://git-lfs.github.com/spec/v1
$ Get-Content <可疑文件> -TotalCount 1
```

如果第一行是 LFS 指针而不是二进制内容，说明该文件还没被还原。

=== E.1.6 构建时报「找不到外部库」

按顺序检查四件事：

1. 库目录是否存在且非空：`lib/windows_x64`（Windows x64）等；
2. 该目录下是否有子模块的 `.git` 标记（Windows 构建脚本正是用它判断库是否就绪的）；
3. `git -C lib/<平台>_<架构> lfs ls-files` 是否仍有 `-` 记录；
4. 平台与架构是否匹配（例如 arm64 机器却只下了 `windows_x64`）。

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

两者的语义是对齐的（同样的构建类型、同样的配置预设），只是入口脚本与
环境检测方式不同。#mac #linux 用 `make`，#win 用 `make.bat` —— 记这一条就够。

=== E.2.2 改了 CMake 选项却不生效

CMake 把缓存写在构建目录里，改选项后必须让它重新配置。用 `make.bat nobuild`（#win）
可以只生成或重新配置工程而不编译。#mac #linux 的 `make config` 含义不同：它只会对
*已有构建目录*打开 `cmake-gui` 或 `ccmake`，让你编辑缓存并手动重新配置；它不能从零
创建构建目录。首次配置应运行平台对应的官方构建入口；只有在已经理解 Blender 的配置
预设与依赖路径时，才适合直接使用 `cmake -S <源码> -B <构建目录>`。

重新配置后仍无效时，用 `cmake -LA -N <构建目录>` 查看缓存中的最终值，并检查是否被
构建档位的预设再次覆盖。只有确认缓存已经互相矛盾或指向旧路径时，才需要删除整个构建目录。

=== E.2.3 想更快地增量构建

- 首次构建成功后，构建目录里会生成 `rebuild.cmd`（#win）。它自己会激活编译器环境，
  直接运行它即可增量重建，省去 `make.bat` 的环境探测与重新配置步骤。
- 编译缓存能显著缩短重复构建时间：`make.bat ninja sccache`（#win）与 `make ccache`（#mac #linux）。
- 只改了几个文件时，让构建系统自己决定要重编什么，不要动辄 `clean`。

=== E.2.4 构建类型与构建档位怎么选

`Release` / `Debug` 是*构建类型*，控制优化与调试符号；`lite` / `developer` / `full`
是*构建档位*，控制启用哪些功能。两类开关可以组合，例如 `debug developer`。

#figure(
  kind: table,
  table(
    columns: (auto, 1.6fr),
    inset: 6pt,
    align: (left, left),
    stroke: 0.4pt + luma(78%),
    table.header([*类型或档位*], [*适用场景*]),
    [`Release` 类型（默认）], [日常使用、性能测量与截图。启用优化，不适合逐句单步调试],
    [`Debug` 类型（`debug`）], [需要断点与单步调试时。体积更大、运行更慢，但调试信息完整],
    [`lite` 档位], [第一次验证工具链，或只需要一个精简的可运行版本],
    [`developer` 档位], [修改 C++ 源码时推荐：打开断言、测试和开发者向检查],
    [`full` 档位], [需要完整可选功能，但不需要官方发布构建中的 GPU 二进制内核],
  ),
  caption: [构建类型与构建档位的取舍],
) <tbl-e-build-types>

=== E.2.5 路径里有空格

Windows 的构建脚本会主动检查并拒绝含空格的路径。把源码放在
`C:\dev\blender` 这类不含空格的目录下；不要依赖短路径名称绕过检查，否则后续工具仍可能
在路径转换时失败。

== E.3 运行与调试

=== E.3.1 一启动就崩，怀疑是插件

用 `-X` / `--factory-startup` 以出厂设置启动。它会跳过用户的 `startup.blend`，载入默认偏好，
因此也不会按用户偏好启用插件。如果这样能正常启动，问题范围就缩小到了用户启动文件、偏好
或已启用插件；恢复普通启动后逐项排除即可。如果仍然崩溃，则应继续检查 GPU 后端、驱动、
命令行参数以及当前构建本身。

```bash
$ blender -X
```

=== E.3.2 脚本化调用失败了，但退出码是 0

Blender 默认不会因为 Python 脚本抛异常而返回非零退出码。批处理与 CI 里必须显式要求它：

```bash
$ blender --background --python-exit-code 1 --python my_script.py
```

=== E.3.3 怎样判断依赖图把时间花在哪里

依赖图有一整套专用调试参数。先启用耗时输出，判断瓶颈属于关系更新还是节点求值：

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

=== E.3.5 在没有界面的机器上运行

`--background` 是无界面模式。如果是要长期部署（例如渲染农场），可以构建
`headless` 配置（#win `make.bat headless`，#mac #linux `make headless`），
它去掉了界面相关部分。

== E.4 Python 插件

=== E.4.1 改了插件代码却不生效

Python 解释器会缓存已导入的模块，而禁用插件通常只调用 `unregister()`，不会把整棵模块
从 `sys.modules` 删除。因此「禁用后再启用」不等于重新导入代码。

- *退出并重启 Blender*：最可靠，适合改了注册结构、模块依赖或全局状态之后；
- *显式重载模块*：适合开发期的小改动，但必须先按相反顺序注销旧类与回调，再按依赖顺序
  重载子模块并重新注册。

如果重载后出现「类已经注册」「属性已经存在」或新旧行为混杂，不要继续叠加 `reload()`；
重启 Blender，先恢复到只有一份模块与注册对象的干净状态。

#tip[
  如果你在频繁迭代，把插件代码写成一个*独立进程可测试*的形式（核心逻辑不依赖
  `bpy`），用普通的 Python 测试执行它，只在最后验证与 Blender 的接线。这会省掉大量重启。
]

=== E.4.2 插件卸载后还有残留

`unregister()` 必须把 `register()` 做过的事*全部且按相反顺序*撤销。常见遗漏有：

- 用 `bpy.utils.register_class()` 注册了类，却没有对应调用 `bpy.utils.unregister_class()`；
- 往菜单或快捷键里加了条目，但没有移除；
- 注册了定时器（`bpy.app.timers`）、处理器（`bpy.app.handlers`）或消息总线订阅，
  却没有反注册或按 owner 清理；
- 给 `bpy.types.Scene` 等现有类型添加了属性，却没有用 `del` 删除。

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
改了属性类型、取值范围或枚举项后，需要先完整注销旧类，再重载模块并重新注册；挂在
`bpy.types.Scene` 等现有类型上的指针属性也要先删除。若旧类已经因异常而无法正常注销，
重启 Blender 是恢复干净注册状态最稳妥的办法。这与只修改普通函数体不同。

=== E.4.5 多文件插件的导入失败

多文件插件应把自身当作一个 Python 包。包内引用统一使用相对导入，例如
`from . import operators`；不要通过修改 `sys.path` 或依赖当前工作目录来寻找相邻模块。
模块导入阶段也不要执行注册类、修改菜单等有副作用的 Blender API 调用，这些操作应集中在
`register()` 中，并在 `unregister()` 中逐项撤销。

== E.5 C++ 源码修改

=== E.5.1 改完数据但界面不刷新

直接修改 C/C++ 数据后，通常要处理两类更新：

- *数据与求值更新*：用相应的 tag 告诉依赖图哪些结果已经失效；
- *界面更新*：发送 notifier，或在只影响局部绘制时标记对应区域重绘。

只做前者，数据可能已经重新求值但界面没有立即刷新；只做后者，界面可能仍在显示旧的求值结果。
典型症状是 Python 控制台能读到新值，但视图要等到切换模式或移动视角后才变化。应先参考同类
属性的 RNA update 回调或相邻操作符，复用它们采用的 tag 与 notifier，而不是随意选择一个通知。

这是第 11 章的重点之一，请参考 §11.3。

=== E.5.2 撤销不工作

C++ 侧会修改可撤销数据的操作符，需要在 `ot->flag` 中声明注册与撤销能力：

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

这两个标志只是让窗口管理器知道如何处理该操作符。若数据在错误阶段修改，或直接写入未被
撤销系统接管的内存，它们并不能自动补出一条正确的撤销记录。若标志已经设置但撤销仍无效，
应继续检查数据修改是否发生在操作符执行期间，以及同类内置操作符是否还调用了专用的 undo API。

撤销栈的判断逻辑在 #src("source/blender/windowmanager/intern/wm_event_system.cc")，
其中多处按 `OPTYPE_UNDO` 分支（例如 `:1307`、`:1396`、`:1699`）。

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
  排错时先缩小范围：源码获取失败，分别检查 Git 对象、Git LFS 与平台库；构建失败，先确认
  平台入口、缓存值和工具链；启动异常，用 `-X` 排除用户状态；插件异常，区分模块缓存与注册
  残留；C++ 修改没有生效，则分别检查依赖图 tag、界面通知与撤销声明。
]
