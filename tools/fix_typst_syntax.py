#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""修正书稿里残留的 Markdown 写法。

最容易犯的两种：

* ``**粗体**`` —— Typst 的加粗是**单星号** ``*粗*``。写成双星号不会报错，
  而是渲染成"一个星号 + 粗体 + 一个星号"，肉眼不仔细看发现不了。
* ``### 标题`` —— Typst 用 ``=`` / ``==`` / ``===``。``#`` 在 Typst 里是代码模式。

**关键：必须跳过代码块。** 那个被替换的目录树里可能真有 `#`，
C++ 里真有 `char **argv`。天真的全局替换会把它们改坏。

用法::

    python tools/fix_typst_syntax.py --check        # 只报告，不修改
    python tools/fix_typst_syntax.py                # 就地修正
    python tools/fix_typst_syntax.py --min-age 90   # 跳过 90 秒内被改过的文件（防并发写入）
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys
import time

# Windows 控制台默认是 GBK：非 ASCII 输出（文件路径里也可能有）会抛
# UnicodeEncodeError，连提示都打不出来。这里统一切到 UTF-8 并放宽错误处理。
# （面向用户的输出一律用英文，见 AGENTS.md §五。）
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


FENCE = re.compile(r"^\s*```")
MD_HEADING = re.compile(r"^(#{2,6})\s+(.*)$")
INLINE_CODE = re.compile(r"`[^`]*`")


def strip_double_star(line: str) -> str:
    """把行内代码**之外**的 ``**`` 换成 ``*``。

    注意：不能简单地用"抹掉行内代码后是否含 ``**``"来判断——像
    ``*`platforms`*``（加粗套行内代码）抹掉反引号内容后，两侧星号会相邻成 ``**``，
    那是**误报**。所以一律算出结果再比较，只有真的变了才算需要修正。
    """
    out, pos = [], 0
    for mm in INLINE_CODE.finditer(line):
        out.append(line[pos:mm.start()].replace("**", "*"))
        out.append(mm.group(0))
        pos = mm.end()
    out.append(line[pos:].replace("**", "*"))
    return "".join(out)


def fix_text(text: str) -> tuple[str, list[str]]:
    lines = text.split("\n")
    in_fence = False
    notes: list[str] = []
    for i, line in enumerate(lines):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue  # 代码块里的 # 和 ** 是代码，不是排版
        if line.lstrip().startswith("//"):
            continue  # 注释里可能**故意**举反例，例如"不要写 **粗**"
        m = MD_HEADING.match(line)
        if m:
            lines[i] = ("=" * len(m.group(1))) + " " + m.group(2)
            notes.append("line %d: Markdown heading -> %s" % (i + 1, lines[i][:50]))
            continue
        fixed = strip_double_star(line)
        if fixed != line:
            lines[i] = fixed
            notes.append("line %d: ** -> *" % (i + 1))
    return "\n".join(lines), notes


def main() -> int:
    ap = argparse.ArgumentParser(description="Fix Markdown leftovers in the book sources")
    ap.add_argument("--check", action="store_true", help="report only, do not modify")
    ap.add_argument("--min-age", type=int, default=0,
                    help="skip files modified in the last N seconds "
                         "(avoids clashing with a process that is writing them)")
    args = ap.parse_args()

    root = repo_root()
    targets = sorted(glob.glob(os.path.join(root, "book", "**", "*.typ"), recursive=True))
    # 构建产物目录里不该有任何手写 .typ；万一有（排查排版时的脚手架），也不要去改它
    targets = [t for t in targets
               if os.sep + "build" + os.sep not in t and os.sep + "out" + os.sep not in t]

    changed = 0
    now = time.time()
    for path in targets:
        age = now - os.path.getmtime(path)
        if args.min_age and age < args.min_age:
            print("skipped (written %ds ago): %s" % (int(age), os.path.relpath(path, root)))
            continue
        with open(path, encoding="utf-8") as f:
            src = f.read()
        fixed, notes = fix_text(src)
        if not notes:
            continue
        changed += 1
        print("%s  (%d finding(s))" % (os.path.relpath(path, root), len(notes)))
        for n in notes[:6]:
            print("    " + n)
        if len(notes) > 6:
            print("    ... %d more" % (len(notes) - 6))
        if not args.check:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(fixed)

    if args.check:
        print("\n%d file(s) need fixing (nothing written; drop --check to fix in place)" % changed)
    else:
        print("\nFixed %d file(s). **Re-compile and re-check the rendered output.**" % changed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
