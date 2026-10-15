# 质量检查

仓库只保留能够重复运行、具有明确失败条件的质量检查。一次性审稿脚本、定点抽查脚本、
运行结果和中间转储不进入版本控制。

## Markdown 文档检查

`qa/check_markdown.py` 检查根目录说明和 `doc/` 下的 Markdown 文档，包括：

- ATX 标题标记后是否有空格；
- 代码围栏和粗体标记是否成对闭合；
- `**粗体**` 与相邻中英文正文之间是否留有空格。

```bash
python qa/check_markdown.py
```

对于标题和粗体间距问题，可先自动修正，再重新检查：

```bash
python qa/check_markdown.py --fix
python qa/check_markdown.py
```

脚本会跳过围栏代码块和行内代码，只向终端输出结果，不生成报告文件。标点符号可以直接
位于粗体标记外侧，不要求额外插入空格。

## 随书示例检查

`qa/check_examples.py` 检查：

- 每个 `#example-file("...")` 脚注指向的文件或目录确实存在；
- `book/examples/` 中每个发布文件都至少被书稿引用一次；
- 示例目录不混入构建产物或未约定的文件类型；
- 所有 Python 示例都能通过语法编译；
- 书稿没有通过 `#src()` 暴露工程内部的 `book/examples/` 路径。

```bash
python qa/check_examples.py
```

检查器只打印当次的动态统计，不写入报告文件。Blender API 行为仍需在钉住版本的 Blender
中实测；Python 语法通过不等于插件已经完成运行时验证。

## 源码引用检查

`qa/check_source_refs.py` 检查全书所有 `#src("path[:line[-line]]")`：

- `blender/` 是否处于书稿钉住的 Blender commit；
- 引用路径是否存在且没有越出源码目录；
- 行号和行号区间是否合法、是否超出文件长度；
- 是否存在无法解析的 `#src()` 调用。

```bash
python qa/check_source_refs.py
```

脚本只向终端输出摘要，并以退出码表示通过或失败，不生成 Markdown 报告、JSON 或文本
转储。若要临时保存输出，应写到版本控制之外，或写到被忽略的 `qa/output/`。

这项检查只能证明“路径和行号仍然有效”，不能证明正文对源码的解释正确。涉及机制、
行为或版本差异的修改仍需人工阅读钉住版本的源码，并在修改后运行完整书稿检查：

```bash
python qa/check_examples.py
scons build-book --check
```

该检查针对正式 PDF。HTML 只做构建冒烟检查：

```bash
scons build-book --format=html
```

HTML 不分页，不能与 `--check` 或 `--release` 组合。

## 不应提交的内容

以下内容不应放进仓库，也不应作为历史档案保存在说明文档中：

- 某次检查的通过数量、缺陷数量或覆盖率；
- 按章节拆分的一次性检查报告；
- JSON、文本转储、截图和人工抽查清单；
- 只为某个既有缺陷或某一组硬编码符号编写的临时脚本。

若某项检查值得长期保留，应改造成无中间状态、覆盖全书、失败条件明确的稳定检查器。
