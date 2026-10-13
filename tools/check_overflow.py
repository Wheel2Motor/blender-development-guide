#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""逐页扫描书稿的**版心横向溢出**。

为什么需要它：Typst 编译零 error 并不代表版面正确。长源码路径、宽表格、
未断行的等宽标识符都会让内容冲出 2.3cm 的页边距，而编译期完全看不出来。
历史上最严重的一页有 1855 个版心外墨迹像素点。

用法::

    python tools/check_overflow.py                # 用 book/build 下已有的逐页 PNG
    python tools/check_overflow.py --render       # 先调 typst 渲染再扫描
    python tools/check_overflow.py --json         # 机器可读输出

``--render`` 用的字体参数与 ``tools/build_book.py`` 完全一致
（``--font-path book/fonts --ignore-system-fonts --ignore-embedded-fonts``），
保证扫描的版面与最终 PDF 是同一个。

它查不出**纵向重叠**（例如表格末行压住表注），那类缺陷必须肉眼看渲染图。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("Pillow is required: python -m pip install pillow "
             "(this script only reports it, it never installs packages)")

# Windows 控制台默认是 GBK，直接打印 ✓ / 中文标点会抛 UnicodeEncodeError。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_typst() -> str | None:
    """优先用工程自带的 typst，其次用 PATH 上的。"""
    local = os.path.join(repo_root(), "tools", "bin", "typst")
    for cand in (local, local + ".exe"):
        if os.path.isfile(cand):
            return cand
    return shutil.which("typst")


def font_args() -> list[str]:
    """和 tools/build_book.py 完全一致的字体参数。

    逐页渲染必须与构建 PDF 用同一套字体，否则扫描的图片与最终 PDF 不是同一个
    版面（字体不同 → 断行与分页都不同），扫描结论就没意义了。
    """
    return ["--font-path", os.path.join(repo_root(), "book", "fonts"),
            "--ignore-system-fonts", "--ignore-embedded-fonts"]


def render(book_dir: str, ppi: int) -> int:
    exe = find_typst()
    if not exe:
        sys.exit("typst not found; run 'python tools/init_book.py' first")
    for old in glob.glob(os.path.join(book_dir, "build", "page-*.png")):
        os.remove(old)
    print("Rendering per-page PNG (%d ppi) ..." % ppi)
    rc = subprocess.run(
        [exe, "compile"] + font_args() +
        ["--format", "png", "--ppi", str(ppi),
         "main.typ", "build/page-{p}.png"],
        cwd=book_dir,
    ).returncode
    return rc


def page_number(path: str) -> int:
    m = re.search(r"page-(\d+)\.png$", os.path.basename(path))
    return int(m.group(1)) if m else 0


def scan(out_dir: str, margin_cm: float, ppi: float, tol_px: int,
         y_from: float, y_to: float, threshold: int) -> list[dict]:
    files = sorted(glob.glob(os.path.join(out_dir, "page-*.png")), key=page_number)
    if not files:
        sys.exit("no page-*.png found -- pass --render, or render the pages first")
    margin = margin_cm / 2.54 * ppi
    bad: list[dict] = []
    for f in files:
        im = Image.open(f).convert("L")
        w, h = im.size
        px = im.load()
        left = right = 0
        for y in range(int(y_from * h), int(y_to * h), 2):
            for x in range(0, int(margin - tol_px)):
                if px[x, y] < threshold:
                    left += 1
            for x in range(int(w - margin + tol_px), w):
                if px[x, y] < threshold:
                    right += 1
        if left > tol_px or right > tol_px:
            bad.append({"page": page_number(f), "file": os.path.basename(f),
                        "left": left, "right": right})
    return bad


def main() -> int:
    root = repo_root()
    default_out = os.path.join(root, "book", "build")
    ap = argparse.ArgumentParser(description="Scan the book for horizontal margin overflow")
    ap.add_argument("--out", default=default_out, help="directory holding the per-page PNGs")
    ap.add_argument("--render", action="store_true", help="render with typst first")
    ap.add_argument("--ppi", type=float, default=90, help="ppi used for rendering and scanning")
    ap.add_argument("--margin-cm", type=float, default=2.3, help="left/right margin (cm)")
    ap.add_argument("--tol-px", type=int, default=8,
                    help="tolerance: anti-aliasing ink pixels that are allowed")
    ap.add_argument("--threshold", type=int, default=200, help="grey threshold; below it counts as ink")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    args = ap.parse_args()

    if args.render:
        if render(os.path.join(root, "book"), args.ppi) != 0:
            return 1

    bad = scan(args.out, args.margin_cm, args.ppi, args.tol_px, 0.055, 0.965, args.threshold)
    total = len(glob.glob(os.path.join(args.out, "page-*.png")))

    if args.json:
        print(json.dumps({"scanned": total, "bad": bad}, ensure_ascii=False, indent=2))
    else:
        print("Scanned %d page(s); pages with margin overflow beyond tolerance: %d"
              % (total, len(bad)))
        for b in bad:
            print("  page %-4d  left=%-4d right=%-4d  (%s)"
                  % (b["page"], b["left"], b["right"], b["file"]))
        if not bad:
            print("  every page is inside the text block -- OK")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
