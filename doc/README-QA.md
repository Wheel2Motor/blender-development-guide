# 质量检查

本项目只保留能够重复运行、失败条件明确的检查器。检查命令输出的是当前状态，不生成需要
归档的报告；技术解释、界面行为和图形语义仍需人工复核。

## 一、检查入口

| 命令 | 检查内容 | 是否需要 Blender 源码 |
|---|---|---|
| `python qa/check_markdown.py` | 项目 Markdown 文档的结构和粗体间距 | 否 |
| `python qa/check_examples.py` | 随书示例引用、发布覆盖和 Python 语法 | 否 |
| `python qa/check_source_refs.py` | `#src(...)` 的提交、路径和行号 | 是 |
| `scons build-book --check` | 源码引用、PDF 编译诊断、逐页渲染和版心溢出 | 是 |

普通 `scons build-book` 只生成书籍，不运行源码引用检查，也不需要 `blender/`。

## 二、Markdown 文档检查

```bash
python qa/check_markdown.py
```

检查范围包括根目录的 `README.md`、`RELEASE_NOTE.md`、`AGENTS.md`、`TODO.md`，以及
`doc/` 下的 Markdown 文档。检查内容包括：

- ATX 标题标记后是否留有空格；
- 代码围栏和粗体标记是否成对闭合；
- `**粗体**` 与相邻中英文正文之间是否留有空格。

标点可以直接跟在粗体标记外侧。脚本会跳过围栏代码块和行内代码。需要修复机械性间距
问题时可以先运行：

```bash
python qa/check_markdown.py --fix
python qa/check_markdown.py
```

自动修复后仍需人工检查语义和段落结构。

## 三、随书示例检查

```bash
python qa/check_examples.py
```

该检查确认：

- 每个 `#example-file("...")` 脚注都指向存在的文件或目录；
- `book/examples/` 中每个发布文件都至少被书稿引用一次；
- 示例目录没有混入缓存、编译产物或未约定的文件类型；
- Python 示例能够通过语法编译；
- 书稿没有通过 `#src()` 暴露工程内部的示例维护路径。

Python 语法通过不等于 Blender API 行为正确。插件注册、操作符执行、资源清理和界面交互
仍应在基准 Blender 中实际测试。

## 四、源码引用检查

```bash
python qa/check_source_refs.py
```

该检查要求默认 `blender/` 是可读的 Git 检出，并验证：

- HEAD 与 `book/blender-baseline.json` 中的固定提交一致；
- 每个 `#src("path[:line[-line]]")` 路径存在且没有越出允许目录；
- 行号或行号区间没有超过文件长度；
- 书稿中不存在无法解析的 `#src()` 调用。

临时使用其他源码目录时可以传入 `--source`。`--skip-revision-check` 只适合明确的本地版本
实验，不能作为当前书稿的正式验证结果。

路径和行号有效只能证明“引用仍指向某段文本”，不能证明正文对代码的解释正确。负向映射、
条件编译、运行时状态和跨模块调用关系都需要人工阅读源码，必要时还要构建和运行程序。

## 五、完整书稿检查

```bash
scons build-book --check
```

该命令先运行默认源码目录的引用检查，再构建 PDF、逐页渲染并扫描版心横向溢出。它要求：

- Blender 提交与书籍基准一致；
- 所有源码引用有效；
- Typst 为零 error、零 warning；
- 没有内容越出版心横向边界。

横向扫描不能发现表格压住表注、图形连线穿字、纵向重叠或截图内容错误。修改表格、图注、
截图和 CeTZ 图后，必须人工查看受影响页面。

HTML 不分页，只做构建冒烟检查：

```bash
scons build-book --format=html
```

`--check` 和 `--release` 都不能与 `--format=html` 组合。

## 六、按改动选择检查

| 改动 | 最低建议 |
|---|---|
| README 或 `doc/` 文档 | `python qa/check_markdown.py` |
| 书稿散文、脚注或示例引用 | Markdown 检查、示例检查、普通书籍构建、受影响页面目视检查 |
| 路径、API、字段、行号或构建说明 | `scons build-book --check`，并人工阅读相关源码 |
| 插件、C/C++ 示例或运行行为 | 完整书稿检查，加对应的真实运行或编译测试 |
| 发布版本 | `scons build-book --release --check`，再检查发布目录内容 |

## 七、不应提交的内容

以下内容不进入版本控制：

- 某次运行的通过数量、缺陷数量或覆盖率快照；
- 按章节拆分的一次性审稿报告；
- JSON、文本转储、逐页渲染图片和人工抽查清单；
- 只为某一个既有缺陷或一组硬编码符号编写的临时脚本。

若某项检查值得长期保留，应把它改造成覆盖范围稳定、无中间状态、失败条件明确的检查器，
而不是保存一份会随书稿变化而过期的报告。
