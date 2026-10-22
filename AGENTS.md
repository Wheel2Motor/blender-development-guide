# 接手须知（给人，也给 AI）

这是一本 **技术书的书稿工程**，不是一个软件项目。改动的验收标准是
「PDF 能编译、版面正确、引用与源码相符」，不是「测试通过」。

> **首次接手**：先运行 `scons init-book`（检查 Typst、**下载字体到
> `book/fonts/`**、目录骨架、cetz 宏包预取），再运行 `scons build-book`。
> **`init-book` 不构建书稿** —— PDF 或实验性 HTML 都由 `build-book` 生成。
> `build-book` 也绝不下载字体：它先按 `.manifest.json` 做只读预检，缺失、损坏或哈希
> 不符就非零退出并引导运行 `init-book`。`init-book` 下载到临时目录，校验通过后才原子
> 安装，不要求人工解压或搬运文件。
> 要核对源码或重截截图才需要 `scons init-blender`
> （约 9 GB，很久；拉不动官方仓库时加 `--mirror=github` 或 `--mirror=gitee`），
> 随后用 `scons build-blender` 生成工程并编译。
> `init-blender` 负责源码、主仓库 LFS 与所有平台（含 Windows）的预编译库；
> `build-blender` 自身只核验、配置和构建：源码 / LFS / `lib/` 任一没准备好就直接失败并
> 指回 `init-blender`，不依赖上游 `make.bat` 的交互询问。六个 alias 由根目录
> `SConstruct` 提供 alias 与 `build-book --release` 模式，逻辑仍在 `tools/` 下的对应 `.py` 里。

## 一、先读这四份

1. `doc/BOOK-SPEC.md` —— 书稿规格。章节结构、必备图表、体例要求都在这。
2. `doc/README-BOOK.md` —— **Typst 排版与语法约定**。改 `.typ` 前先读。
3. `doc/README-BLENDER.md` —— Blender 源码获取、构建和实机验证约定。修改技术内容前先读。
4. `doc/README-QA.md` —— 持续质量检查及其边界。`qa/` 只放可重复运行的检查器，
   不保存一次性报告、转储或定点抽查脚本。

## 二、硬规则（每条都是踩过坑换来的）

### 1. 绝不凭印象写源码事实

正文里每个路径、字段、函数签名、行号、统计数字，都必须在 `blender/` 里查到。
历史教训：第 16 章曾把一条 **方向相反** 的结论当成"源码级纠正"写进正文
（`G_DEBUG_DEPSGRAPH_TIME` 其实 **在** `G_DEBUG_DEPSGRAPH` 并集里，见
`blender/source/blender/blenkernel/BKE_global.hh:260-261`），
是靠独立核查代理才发现的。同类错误还有把 `BLI_listbase_move_index` 写成
`BLI_move_index`、把负向 RNA 映射（`bl_use_postprocess == !RE_USE_PROCESS`）
当正向读。

**两类最危险的错误**：① 把负向 sdna 映射当正向；② "看起来合理但源码里查不到"的
分布性断言（"只有 9 个文件用了 X"）。写这两类话之前一定先 `git grep` 数一遍。

### 2. 改完必须运行这三步验证

```bash
python qa/check_examples.py           # 完整示例脚注、文件覆盖与 Python 语法
scons build-book                      # ① 默认编译 PDF（必须零 error 零 warning）
scons build-book --format=html        # 实验性 HTML：先生成 SVG、网页字体与样式
scons build-book --check              # ② + ③ 逐页渲染 + 版心溢出扫描（约十分钟）
```

`--check` 做的事就是下面这串手工命令，运行完会自动删掉 `book/build/page-*.png`：

```bash
cd book
typst compile --font-path fonts --ignore-system-fonts --ignore-embedded-fonts \
  main.typ build/blender-development-guide.pdf
typst compile --font-path fonts --ignore-system-fonts --ignore-embedded-fonts \
  --format png --ppi 90 main.typ "build/page-{p}.png"
python ../tools/check_overflow.py --out build
```

**字体参数不能省。** 少了 `--font-path` / `--ignore-system-fonts`，代码块里的中文
会回退到 `LiSu`（隶书，**商业字体**，随 PDF 分发有版权风险），而且分页不再可复现。
逐页渲染也必须用同一套参数，否则扫描的不是最终版面。

**零 error ≠ 排版正确。** 版心溢出和"表格末行压住表注"这类缺陷编译期完全看不出来。
历史上最严重的一页有 1855 个版心外墨迹像素点，编译却是通过的。

### 3. 长路径必须可断行

`main.typ`（行内代码）、`common.typ` 的 `src()`、附录的 `p()` 都在 `/ _ - . :`
之后插了零宽空格。**新写任何渲染路径的辅助函数都要照做**，否则它的最小内容宽度
会把整张表格的列挤成"每行一个字"、甚至把表撑出版心。

### 4. 不要手写图表编号

全书编号由 Typst 自动生成。正文引用一律用 `@fig-xxx` / `@tbl-xxx`。
历史上第 4 章写过「图 4.1」、第 9 章写过占位符「图 8.x」、第 15 章写过「图 3」，
全是错的。

### 5. 正文只描述读者看到的东西

正文里 **不要把 `#term(...)` / `#src(...)` / `#win` 这类调用写法当成文字写出来、也不要
解释给读者**。这些宏本身是书稿机制，该用就用；
这条规则针对的是"把它们暴露成读者可读的文字或实现说明"——那些属于 `doc/README-BOOK.md`。
读者要看到的是渲染后的样子：`*操作符*（operator）`、等宽路径、平台标签。

### 6. Markdown 文档也必须通过语法检查

Markdown 中的 `**粗体**` 与相邻的中英文正文之间必须留空格，句号、逗号、括号等标点
可以直接跟在粗体标记外侧。标题标记后必须留空格，代码围栏和粗体标记必须成对闭合。
修改 `.md` 后运行：

```bash
python qa/check_markdown.py
```

已有的机械性间距问题可以用 `python qa/check_markdown.py --fix` 修正，再人工复核语义。

## 三、环境

- **环境边界（脚本只往工程目录写，从不装工具）**：可以自动获取的只有工程内数据
  （字体 → `book/fonts/`；Blender 源码与 `lib/` → `blender/`；cetz → Typst 自己的
  包缓存）。`scons` / `typst` / `git` / `cmake` / `ninja` / 编译器 / Python 只 **检查**：必需项缺失
  时打印官方安装命令并 **非零退出**，可选项（`ninja`、`pdfinfo`、Pillow、`fontTools`）
  缺失只降级功能、不影响退出码。`git-lfs` 是 **有条件的必需项**：需要拉取/还原 `lib/`
  （Git LFS 子模块）时缺它就是 `[FAIL]`；`lib/` 已经是还原好的实体文件时缺它只 `[WARN]`。
  **脚本不调用任何包管理器、不下载任何 CLI
  可执行文件、不写系统目录**；Typst 也 **不会** 被下载（`tools/bin/typst[.exe]` 只是
  "想钉住某一版时自己放二进制"的可选位置）。详见根 `README.md` 的「环境边界」一节。
- **Typst 0.15.1** + cetz 0.3.4（`@preview/cetz:0.3.4`，由 Typst 自动拉取）
- **默认字体由工程自带**（`book/fonts/`，由 `init-book` 下载并校验；**不入版本控制**，
  约 50 MB）。构建 **完全不看系统字体**，必须带三条参数：
  `--font-path book/fonts --ignore-system-fonts --ignore-embedded-fonts`。
  `scons init-book --use-system-fonts` 会跳过项目字体下载并检查本机候选；
  `scons build-book --use-system-fonts` 只用于本机临时预览：构建器会从 Windows、macOS、
  Linux 各自的候选列表中筛选实际安装的字体，并通过 Typst inputs 注入书稿；该模式不保证
  分页可复现，也可能涉及系统字体的再分发限制，不得用于正式发布。
  全部字体都是 **SIL OFL**，允许嵌入与再分发：

  | 用途 | 字体 | 来源 |
  |---|---|---|
  | 正文中文（无衬线） | Noto Sans SC（Regular + Bold 静态 OTF） | `notofonts/noto-cjk` Releases |
  | 代码拉丁与符号（**半宽制表符**） | Noto Sans Mono（Regular + Bold 静态 TTF） | `notofonts/notofonts.github.io` 的 `fonts/NotoSansMono/` |
  | 代码里的中文（回退） | Noto Sans Mono CJK SC（Regular + Bold 静态 OTF） | `notofonts/noto-cjk` Releases |
  | **末尾兜底**（拉丁） | Noto Sans（Regular + Bold 静态 TTF） | `notofonts/notofonts.github.io` 的 `fonts/NotoSans/` |

  代码用 **字体栈**（`font-code = (font-mono, font-mono-cjk, font-fallback)`）：
  首选 `Noto Sans Mono` 的 U+2500 系制表符是 **半宽**（与 ASCII 完全等宽），所以
  代码块里 `├──` 正好占 3 个 ASCII 格、树与 `#` 注释列落在 ASCII 网格上；它不含
  汉字，中文由 `Noto Sans Mono CJK SC` 提供（等宽中文 = 2 个 ASCII 格）。
  **关键**：`Noto Sans Mono CJK SC` 自己 **也有** 制表符，但是全宽的（2 格）——
  首选字体命中后就不会用到它。调换字体顺序会悄悄改变树的宽度，`init_book.py`
  因此对首选字体强制校验"制表符/箭头与 ASCII **等宽**"。

  **末尾那个 `Noto Sans` 是显式兜底，不要删**：`Noto Sans SC`（正文中文）**不含**
  U+0131（无点 i `ı`，`11-wm-operators.typ:2021` 那个土耳其语 locale 例子）。
  少了它时 `ı` **不会** 变成缺字方框 —— 实测 Typst 仍会从 `--font-path` 目录里自动
  挑一个覆盖它的字体（结果同样是 `Noto Sans`），但"挑哪一个"由 Typst 的兜底顺序决定，
  不受我们控制；而 **只要去掉 `--ignore-embedded-fonts`**，Typst 内置的 Libertinus
  就会顶上来（实测：那次编译的 PDF 里立刻出现 `LibertinusSerif-Regular`）。显式写上
  `Noto Sans`，`ı` 由谁渲染就与参数组合无关，全由我们自己 pin。
  （实测补充：当前书稿里 U+0131 一共只出现 3 次，唯一会渲染的那次在
  `11-wm-operators.typ:2021` 的 **行内代码** 里，而 `Noto Sans Mono` 自己含 U+0131 ——
  所以最终 PDF 的 `pdffonts` 里其实 **没有** `NotoSans`。这个兜底是 **保险**：一旦有人
  把 `ı` 写进正文散文，它就派上用场，所以照样不要删。）
  **全字符覆盖审计结论（实测）**：把全书源码（含 `figures/`、`examples/`）与最终
  PDF 的字符集合，分别与 `book/fonts/` 全部字体 cmap 的并集做差集 ——
  **渲染层差集为空**；源码层唯一"缺"的是制表符 `\t`（不产生字形）。
  即 **全书不存在任何会渲染成缺字方框的字符**。改动字体后建议重新运行该审计。

  写法上仍要记住：**每处显式 `#set text` 都给 `weight`**（`font-zh` 现在有
  Regular/Bold 两份 OTF，但历史上用过默认实例为 Thin 的可变字体，别退回那个坑）。
- 单独编译某个章节时必须带 `--root .`（**还要带上字体参数**），否则代码块里的中文
  会去系统字体里找（历史上曾落到 `LiSu` 隶书，那是商业字体）：
  ```bash
  typst compile --root . --font-path fonts --ignore-system-fonts \
    --ignore-embedded-fonts chapters/09-dna-rna.typ
  ```
  否则 `#import "../common.typ"` 会报 "would escape the project root" —— 那是假错误。
  单章编译出现 `label <fig-xxx> does not exist` 也属正常（引用了别章的标签）。

## 四、源码与截图基准

- `blender/`：Blender 核对基准由 `book/blender-baseline.json` 唯一定义；Typst 书稿、
  初始化脚本和源码引用检查器都读取这份配置。
  **不入版本控制**（重新拉取要很久）。缺了就 `scons init-blender`（或
  `python tools/init_blender.py`）。
  注意 `lib/` 是 Git LFS 子模块且 `.gitmodules` 里写着 `update = none`——直接
  `git submodule update --init -- lib/<平台>_<架构>` 会 **静默什么都不做**，必须就地覆盖
  更新策略（脚本内部就是这么做的，手工恢复时照抄）：
  ```bash
  git -C blender -c submodule.lib/windows_x64.update=checkout \
    submodule update --init --progress -- lib/windows_x64
  git -C blender/lib/windows_x64 -c lfs.concurrenttransfers=32 lfs pull
  ```
  `init_blender.py` 会在所有平台自动选 `lib/` 子模块（**没有
  `macos_x64`**）、校验目录非空、自动还原 LFS 指针，并将下载进度
  实时透传到终端。Windows 也走这条非交互路径；上游 `make.bat` 的 `set /p`
  询问只在库仍缺失时才会出现，`init_blender.py` 不依赖它。
- 源码镜像：`scons init-blender --mirror=github|gitee`（默认 `official`）只换 **主仓库** 的
  克隆来源，`lib/` 子模块与主仓库的 Git LFS 对象仍来自 `projects.blender.org`，构建方式
  不变。主仓库的 LFS 内容必须还原成实体：上游 `CMakeLists.txt` 见到指针形态的
  `release/datafiles/startup.blend` 会直接 FATAL，`init-blender` 因此从官方补齐
  （`lfs-fallback` 远端 + `git lfs fetch`/`checkout`），`build-blender` 在 configure 前再核一次。
  **克隆和子模块更新一律跳过 LFS smudge**（逐文件串行 smudge 实测只有几十 KiB/s，镜像
  更会直接失败），改由随后一次并发的 `git lfs pull` 补齐（`lfs.concurrenttransfers=32`，
  实测把 `projects.blender.org` 从 0.43 MiB/s 提到 1.6 MiB/s）；`lib/` 子模块同理。
  还原后必须按 `git lfs ls-files` **全量** 核对，不能只查 `startup.blend`——上游只查那一个
  文件，半个 LFS 的树能配置通过、产出却缺图标/画笔/ICC 数据。
  中断的 git 操作会在主仓库和 `lib/` 的 git 目录里留下 `.git/index.lock`，脚本会告警
  （不替用户删文件），否则 LFS 文件会一直显示为 modified。
  镜像可能落后：脚本用 `git ls-remote` 先查基准分支、克隆后再核 `git rev-parse HEAD`，
  两者不一致就非零退出，不得为了让镜像“能用”而放宽这条核对或跳过基准 commit。
- 升级基准不能只修改版本字符串。更新 `book/blender-baseline.json` 后，必须重新核对
  源码引用、版本相关结论、命令输出和截图；书中保留的旧版本兼容性示例不要机械替换。
- 书籍自身版本由 `book/meta.json` 唯一定义，与 Blender 基准版本分开维护；封面小字
  直接读取该字段，发布书稿时不要在 Typst 源码中手写版本号，也不要直接改 JSON。
  先把改动写入根目录 `RELEASE_NOTE.md` 的 `Pending` 无序列表，再运行
  `scons bump-version --major|--minor|--micro`（实际命令只选一个开关）。
- 图片资源：`book/res/`（**平铺，无子目录**）。章节里的相对路径写 `../res/xxx.png`。
  采集脚本是 `tools/capture_screenshots.py`，**需要 GUI**，
  用同级的 `tools/example_addon/` 里那个自写插件做界面元素；它把新截图直接写进
  `book/res/`，临时装插件的用户脚本目录是 `tools/_user_scripts/`（不入库）。
  两个必须知道的坑（脚本注释里也写了）：
  - `window.workspace = ws` 在 5.2 里 **不生效**，切编辑器要直接改 `area.type`；
  - 不要调用 `userpref_show()`，那是模态窗口，会让 Blender 无法退出并留下卡死的窗口。

## 五、工具

| 工具 | 用途 |
|---|---|
| `SConstruct` | 六个跨平台 alias：`init-book`、`build-book`、`init-blender`、`build-blender`、`bump-version`、`help`；`build-book --release` 负责发布构建；SCons 只编排 `tools/` 下的 Python 逻辑 |
| `tools/init_book.py` | 检查 Typst；默认 **下载并校验 `book/fonts/` 里的字体**（幂等），`--use-system-fonts` 时跳过下载并检查系统候选；建目录骨架并用 **临时探针** 预取 cetz 宏包。**不构建书稿**（入口：`scons init-book`） |
| `tools/build_book.py` | 默认构建 PDF；`--format=html` 先生成 `book/build/res/*.svg` 与可选网页字体，再编译 HTML 并嵌入 `book/html/style.css`；`--use-system-fonts` 可显式选择系统 fallback；PDF 的 `--check` 再做逐页渲染 + 溢出扫描（入口：`scons build-book`） |
| `tools/build_book_release.py` | 检查示例、构建 PDF，并生成顶层仅含 PDF 与 `examples/` 的书籍发布目录（入口：`scons build-book --release`） |
| `tools/blender_baseline.py` | 读取并校验 `book/blender-baseline.json`，供 Blender 初始化与源码引用检查共用 |
| `tools/init_blender.py` | 拉取/核对 Blender 源码（`--mirror=official\|github\|gitee` 只换主仓库来源）、还原主仓库 LFS、在所有平台非交互准备 `lib/` 预编译库，并探测工具链门槛（入口：`scons init-blender`） |
| `tools/build_blender.py` | 只读核验已初始化的源码与依赖，生成 out-of-source CMake 工程并构建；Windows 生成并构建 Visual Studio solution（入口：`scons build-blender`） |
| `tools/version_mgr.py` | 校验语义版本与发布说明，提升 `book/meta.json` 中的版本，并将 `Pending` 列表原子迁移到最新发布记录（入口：`scons bump-version --major|--minor|--micro`） |
| `tools/check_overflow.py` | 逐页扫描版心外墨迹（**横向溢出**） |
| `tools/fix_typst_syntax.py` | 修正 Markdown 残留（`**粗**`、`###` 标题），**自动跳过代码块** |
| `tools/capture_screenshots.py` | 实机截图采集（**需要 GUI**，写进 `book/res/`） |
| `tools/example_addon/` | 截图用的示例插件源码（不是随书代码案例） |
| `qa/check_examples.py` | 校验完整示例脚注、发布文件覆盖与 Python 语法，不生成报告 |

根目录只保留一个 `SConstruct` 跨平台入口，alias 与参数必须同步维护在 `scons help`、
根 `README.md` 和对应构建文档中。`scons help` 的参数按 alias 分段（`init-book options:`、
`build-book options:`、`init-blender options:`、`build-blender options:`、
`bump-version options:`），新增参数必须放进它所属 alias 的段；同一个开关被多条 alias
接受时就在相关段里各自注明（`--check-only`、`--use-system-fonts` 是这种写法），
不要另开非命令名的段。SCons 只负责编排，不应复制 `tools/` 中的业务逻辑。
`--release` 与 `--use-system-fonts` 必须保持互斥；发布包只能使用项目固定字体。
`--mirror` 与 `--mirror-url` 只适用于 `init-blender`，只改主仓库的克隆来源，且只在克隆时
生效；镜像缺少基准分支或提交时必须非零退出，其余 alias 传入应直接拒绝。
`--format=html` 不能与 `--check` 或 `--release` 组合；HTML 只放行 Typst 已知的实验导出
警告。新增 `book/figures/<name>.typ` 时必须导出零参数 `fig-<name>()`；章节内直接写
`figure(canvas(...))` 时必须带唯一 `<fig-...>` 标签，供 HTML 资源构建器发现。
`init-book` 的 `--force` 与 `--use-system-fonts` 也互斥，因为系统字体模式没有项目字体可重验。
`bump-version` 必须且只能使用 `--major`、`--minor`、`--micro` 之一；发布说明只允许
`# Release Note`、`# Pending` 两个一级标题，待发布内容使用无序列表。
**`tools/` 下所有脚本面向用户的输出一律用英文** —— `print` / `sys.exit` / `argparse`
的 `description` 与 `help` 都算；注释可以是中文。这条不只是"乱码不好看"：GBK 控制台下
输出非 ASCII 会抛 `UnicodeEncodeError`，**连错误提示都打不出来**（`check_overflow.py`
的 Pillow 提示、`fix_typst_syntax.py` 与 `capture_screenshots.py` 的日志都踩过这个坑）。
相关脚本都在开头把 stdout/stderr `reconfigure` 成 UTF-8 作为兜底（这样路径里出现
中文也不会崩），但 **别因此就把面向用户的文字改回中文**。

**所有入口都只检查工具、不安装工具**：`init_book.py` 报 Typst / Python 与可选依赖，
`init_blender.py` 报 git / cmake / ninja / 编译器，并按是否需要拉取 `lib/` 或主仓库 LFS
给 `git-lfs` 定级。必需项缺失 → 官方安装命令 + **非零退出码**，可选项缺失 → 只提示。
初始化入口只下载工程内可重取数据（字体、Blender 源码、主仓库 LFS 与平台库）；
**`init-blender` 成功后源码、LFS、`lib/` 都必须已就绪**：所有平台（含 Windows）的
预编译库都由它非交互准备，`build_blender.py` 只核验、缺库直接失败并指回
`scons init-blender`，不依赖上游 `make.bat` 的交互询问。两个构建入口均不下载这些
输入，其中 `build_blender.py` 不主动调用 `update`、Git fetch 或 LFS/submodule 更新。
Windows 上游 `make.bat` 自带的依赖检查和懒下载逻辑保持原样，但正常情况下不会触发；
Linux/macOS 等平台若官方流程明确要求构建前另行执行 `make update` 或从旧 SVN/子模块
仓库拉依赖，则应由 `init-blender` 完成该前置步骤。
Windows 项目构建入口仅允许 MSVC，不得因 PATH 上存在 `clang-cl` 而自动降级；Visual Studio
必须通过 `vswhere` 从普通终端自动定位，不得要求用户先进入 Developer Command Prompt。

`check_overflow.py` 查不出 **纵向重叠**（表格压表注）。这类要肉眼看渲染图，
根因通常是 `figure` 不允许在正文与表注之间分页 —— `main.typ` 里已经设了
`#show figure: set block(breakable: true)`，别删。

## 六、已知取舍与未闭合项

1. **篇幅**：正文显著超过规格书的粗略页数参考。规格书同时要求以内容完整性为准；
   如果决定压缩，需要重新做一轮验证，因为内容调整会改变分页与溢出情况。
2. **第 5 章那张侧栏截图较弱**：图中侧栏停在 Blender 内置的 `Item` 页签，
   而不是示例插件的 `Guide` 页签（采集脚本只能打开侧栏、无法点击页签）。
   图注已如实说明。要更好的图，需要在 GUI 里手动点页签后重截。
3. **脚注只放旁支解释**：书稿已经开始使用原生 `#footnote[...]` 安置术语别名、
   命名背景等短说明；步骤前提、安全警告、版本行为和源码证据仍必须留在正文。
   具体判断规则见 `doc/README-BOOK.md` 的「脚注的使用边界」。
4. **术语"首现加粗附英文"约 108 处**，未做全书逐术语标注；附录 A 有系统术语表。
5. **散文叙述层未经机械核验**：`python qa/check_source_refs.py` 能验证 `#src()` 的路径、
   行号和源码版本，却不能证明“这个设计为什么这样”等解释正确；这类判断仍需人工阅读
   源码。不要在仓库里保存某次运行的统计数字或报告快照。
