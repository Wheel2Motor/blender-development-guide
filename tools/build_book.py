#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 构建书籍 PDF。

做三件事：

1. 默认用绝对路径和项目固定字体运行 Typst，完全不看系统字体，因此构建可复现、
   也不会回退到系统里的商业字体；可选 ``--use-system-fonts`` 会枚举本机字体，并从
   当前平台的候选列表中选择真实存在的正文与等宽字体；
2. 成功后打印**产物的绝对路径**、文件大小、页数（``pdfinfo``，没有就跳过），
   以及 Typst 的 error / warning 计数；Typst 非零退出或出现任何 error / warning 都把
   诊断原样透出并非零退出；
3. 可选 ``--check``：构建后逐页渲染 PNG，跑 ``tools/check_overflow.py`` 扫版心溢出，
   最后删掉 ``book/build/page-*.png``。默认**不跑**（很慢，约十分钟）。

环境边界：本脚本**只检查、不安装**任何工具。Typst 缺失时打印官方安装方式并非零退出
（**不会**下载 Typst，也不会往 ``tools/bin/`` 放东西）；``pdfinfo`` 与 Pillow 是可选
依赖，缺失时分别只降级"页数报告"与"``--check`` 的溢出扫描"，不影响普通构建。
字体同样只按 manifest 核验，不在构建过程中下载或修复；缺失时引导运行
``scons init-book``。输出目录 ``book/build/`` 在工程内。

用法::

    python tools/build_book.py            # 只构建并报告
    python tools/build_book.py --check    # 构建 + 逐页渲染 + 版心溢出扫描
    python tools/build_book.py --use-system-fonts

注意：本脚本打印到控制台的一切文字都是英文 —— Windows 控制台默认代码页是 GBK，
中文输出会乱码。注释可以保留中文。
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK = os.path.join(ROOT, "book")
BUILD = os.path.join(BOOK, "build")
MAIN = os.path.join(BOOK, "main.typ")
PDF = os.path.join(BUILD, "blender-development-guide.pdf")
OVERFLOW = os.path.join(ROOT, "tools", "check_overflow.py")
# 默认字体由工程自带（book/fonts/，由 tools/init_book.py 下载），构建完全不看系统字体。
FONTS = os.path.join(BOOK, "fonts")

# Typst 的字体相关参数，含义见 doc/README-BOOK.md「字体」一节：
#   --font-path             指向工程字体目录；
#   --ignore-system-fonts   不看系统字体 —— 排除 LiSu（隶书，商业字体）这类回退，
#                           也是构建可复现的前提；
#   --ignore-embedded-fonts 连 Typst 内置字体也不参与回退，缺字必须显式暴露，
#                           而不是被 DejaVu / Libertinus 悄悄顶掉。
PROJECT_FONT_ARGS = [
    "--font-path", FONTS, "--ignore-system-fonts", "--ignore-embedded-fonts",
]

# ``--use-system-fonts`` 只从当前系统中实际存在的字体里选取候选，避免把不存在的
# family 传给 Typst 并产生 warning。代码字体末尾追加正文字体，给中文注释兜底。
SYSTEM_FONT_CANDIDATES = {
    "windows": {
        "body": (
            "Microsoft YaHei", "Microsoft YaHei UI", "DengXian", "SimHei", "Arial",
        ),
        "code": (
            "Cascadia Mono", "Cascadia Code", "Consolas", "Source Code Pro",
            "Courier New",
        ),
    },
    "macos": {
        "body": (
            "PingFang SC", "Hiragino Sans GB", "Heiti SC", "Songti SC",
            "Arial Unicode MS", "Helvetica", "Arial",
        ),
        "code": ("SF Mono", "Menlo", "Monaco", "Courier New"),
    },
    "linux": {
        "body": (
            "Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC",
            "WenQuanYi Micro Hei", "WenQuanYi Zen Hei", "DejaVu Sans", "Liberation Sans",
        ),
        "code": (
            "Noto Sans Mono", "Source Code Pro", "DejaVu Sans Mono",
            "Liberation Mono", "Ubuntu Mono",
        ),
    },
}

OK, BAD, INFO = "[ OK ]", "[FAIL]", "[ .. ]"

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def say(tag: str, msg: str) -> None:
    print("%s %s" % (tag, msg))


def run(cmd: list[str], cwd: str | None = None, stream: bool = False) -> subprocess.CompletedProcess:
    """跑外部命令。``stream=True`` 时把子进程输出直接接到当前控制台。

    流式模式是必须的：逐页渲染要跑十分钟，捕获到内存里会让用户以为卡死了。
    非流式模式的输出经临时文件中转（比 Pipe 兼容性更好），返回体里带输出文本。
    """
    if stream:
        try:
            return subprocess.run(cmd, cwd=cwd)
        except Exception as exc:  # noqa: BLE001
            return subprocess.CompletedProcess(cmd, 127, ("%s" % exc).encode())

    handle = tempfile.TemporaryFile()
    try:
        try:
            cp = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=handle, stderr=subprocess.STDOUT, timeout=3600)
            rc = cp.returncode
        except Exception as exc:  # noqa: BLE001
            rc = 127
            handle.write(("%s" % exc).encode("utf-8", "replace"))
        handle.seek(0)
        return subprocess.CompletedProcess(cmd, rc, handle.read())
    finally:
        handle.close()


def text_of(cp: subprocess.CompletedProcess) -> str:
    out = cp.stdout or b""
    if isinstance(out, str):
        return out
    return out.decode("utf-8", errors="replace")


def find_typst() -> str | None:
    local = os.path.join(ROOT, "tools", "bin", "typst")
    for cand in (local, local + ".exe"):
        if os.path.isfile(cand):
            return cand
    return shutil.which("typst")


def platform_key() -> str:
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def select_system_fonts(exe: str) -> tuple[list[str], list[str]] | None:
    """Return available body/code fallbacks for this OS, in preference order."""
    cp = run([exe, "fonts", "--ignore-embedded-fonts"], stream=False)
    if cp.returncode != 0:
        say(BAD, "Could not enumerate system fonts with 'typst fonts'.")
        out = text_of(cp).strip()
        if out:
            print(out)
        return None

    installed = {
        line.strip().casefold(): line.strip()
        for line in text_of(cp).splitlines()
        if line.strip()
    }
    candidates = SYSTEM_FONT_CANDIDATES[platform_key()]

    def available(names: tuple[str, ...]) -> list[str]:
        return [installed[name.casefold()] for name in names if name.casefold() in installed]

    body = available(candidates["body"])
    mono = available(candidates["code"])
    if not body:
        say(BAD, "No supported system body font was found for %s." % platform_key())
        say(INFO, "Candidates: %s" % ", ".join(candidates["body"]))
        return None
    if not mono:
        say(BAD, "No supported system monospace font was found for %s." % platform_key())
        say(INFO, "Candidates: %s" % ", ".join(candidates["code"]))
        return None

    # 等宽字体通常不含 CJK；把正文字体追加为代码中文的显式回退。
    code = mono + [name for name in body if name not in mono]
    return body, code


def system_font_args(exe: str) -> list[str] | None:
    selected = select_system_fonts(exe)
    if selected is None:
        return None
    body, code = selected
    say(OK, "System body fonts: %s" % " -> ".join(body))
    say(OK, "System code fonts: %s" % " -> ".join(code))
    say(INFO, "System-font mode is machine-dependent; use pinned project fonts for releases.")
    return [
        "--ignore-embedded-fonts",
        "--input", "font-mode=system",
        "--input", "font-body=" + ";".join(body),
        "--input", "font-code=" + ";".join(code),
    ]


def count_diagnostics(out: str) -> tuple[int, int]:
    """Typst 的诊断行形如 ``error: ...`` / ``warning: ...``（可能在文件路径行之后）。"""
    errors = len(re.findall(r"(?m)^\s*error:", out))
    warnings = len(re.findall(r"(?m)^\s*warning:", out))
    return errors, warnings


def pdf_pages(path: str) -> int | None:
    """用 pdfinfo 取页数。没有 pdfinfo / 解析失败就返回 None（不算错误）。"""
    exe = shutil.which("pdfinfo")
    if not exe:
        return None
    cp = run([exe, path], stream=False)
    if cp.returncode != 0:
        return None
    m = re.search(r"(?m)^Pages:\s+(\d+)", text_of(cp))
    return int(m.group(1)) if m else None


def clean_pages() -> int:
    removed = 0
    for p in glob.glob(os.path.join(BUILD, "page-*.png")):
        try:
            os.remove(p)
            removed += 1
        except OSError:
            pass
    return removed


def ensure_pillow() -> bool:
    """``--check`` 需要 Pillow（``tools/check_overflow.py`` 用它读 PNG）。

    只检查、**不安装**：缺了就打印安装方式并返回 False，调用方以非零退出码结束，
    并明确说明这不是"版心溢出"。普通构建（不带 ``--check``）完全不受影响。
    """
    try:
        import PIL  # noqa: F401
        return True
    except Exception:  # noqa: BLE001
        say(BAD, "--check needs Pillow for tools/check_overflow.py, and it is missing.")
        say(INFO, "Pillow is an OPTIONAL dependency -- the plain build is unaffected;")
        say(INFO, "only this verification step cannot run. Install it yourself, e.g.:")
        say(INFO, "  python -m pip install pillow")
        say(INFO, "This is NOT a margin-overflow result -- the scan never ran.")
        return False


def verify_project_fonts() -> bool:
    """Strict, read-only font preflight for builds.

    Downloading belongs exclusively to init_book.py. A build must never mutate
    its inputs or silently accept an unpinned font, so it uses check-only mode
    and stops with the platform entry points when preparation is required.
    """
    try:
        from init_book import check_fonts
    except Exception as exc:  # noqa: BLE001
        say(BAD, "Could not load the project font checker: %s" % exc)
        return False

    if check_fonts(
            check_only=True,
            force=False,
            heading="== Preflight: pinned project fonts (no downloads) =="):
        return True

    say(BAD, "Book fonts are missing, invalid, or do not match the pinned manifest.")
    say(INFO, "The build never downloads or repairs fonts. Prepare them first:")
    say(INFO, "  scons init-book")
    say(INFO, "Then re-run this build command; no manual file copying is required.")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the book PDF with Typst.")
    ap.add_argument("--check", "--verify", dest="check", action="store_true",
                    help="after building, render every page and scan for margin overflow "
                         "(slow, about ten minutes)")
    ap.add_argument("--use-system-fonts", action="store_true",
                    help="use an OS-specific list of installed fallback fonts instead of "
                         "the pinned project fonts (not reproducible; not for releases)")
    args = ap.parse_args()

    print("=" * 70)
    print("Build the book")
    print("Project root : %s" % ROOT)
    print("Book dir     : %s" % BOOK)
    print("Output       : %s" % PDF)
    print("Verify       : %s" % ("yes (--check)" if args.check else "no"))
    print("Fonts        : %s" % ("system fallbacks" if args.use_system_fonts
                                 else "pinned project fonts"))
    print("=" * 70)

    if not os.path.isfile(MAIN):
        say(BAD, "Entry file not found: %s" % MAIN)
        return 1

    exe = find_typst()
    if not exe:
        say(BAD, "typst NOT FOUND (PATH or tools/bin/typst[.exe]).")
        say(INFO, "Typst is NOT installed by this script -- install it yourself:")
        say(INFO, "  Windows : winget install --id Typst.Typst")
        say(INFO, "            or scoop install typst")
        say(INFO, "  macOS   : brew install typst")
        say(INFO, "  Linux   : cargo install --locked typst-cli")
        say(INFO, "  any OS  : https://github.com/typst/typst/releases")
        say(INFO, "Then re-run: python tools/build_book.py")
        say(INFO, "('python tools/init_book.py' re-checks the whole environment.)")
        return 1

    # Typst 不会创建输出目录，缺了就建
    if not os.path.isdir(BUILD):
        os.makedirs(BUILD, exist_ok=True)
        say(OK, "Created output directory: %s" % BUILD)

    if args.use_system_fonts:
        font_args = system_font_args(exe)
        if font_args is None:
            return 1
    else:
        # 项目字体必须已经由 init-book 备好；构建只读核验，不下载、不修复。
        if not verify_project_fonts():
            return 1
        font_files = [f for f in sorted(os.listdir(FONTS))
                      if f.lower().endswith((".ttf", ".otf", ".ttc", ".otc"))]
        say(OK, "Using %d project font file(s) from %s; system fonts are ignored."
            % (len(font_files), FONTS))
        font_args = PROJECT_FONT_ARGS

    start = time.time()
    say(INFO, "Running: %s compile %s %s %s" % (exe, " ".join(font_args), MAIN, PDF))
    cp = run([exe, "compile"] + font_args + [MAIN, PDF], cwd=BOOK, stream=False)
    out = text_of(cp)
    elapsed = time.time() - start
    errors, warnings = count_diagnostics(out)
    if out.strip():
        print("-" * 70)
        print(out.rstrip())
        print("-" * 70)

    if cp.returncode != 0:
        say(BAD, "Build FAILED (typst exit code %d, %.1fs, %d error(s), %d warning(s))."
            % (cp.returncode, elapsed, errors, warnings))
        return cp.returncode if cp.returncode > 0 else 1

    if not os.path.isfile(PDF):
        say(BAD, "typst exited 0 but the PDF is missing: %s" % PDF)
        return 1

    size = os.path.getsize(PDF)
    print()
    print("-" * 70)
    diagnostics_clean = errors == 0 and warnings == 0
    if diagnostics_clean:
        say(OK, "Build succeeded in %.1fs." % elapsed)
    else:
        say(BAD, "Typst produced a PDF in %.1fs, but diagnostics are not clean." % elapsed)
    print("     Artifact     : %s" % PDF)
    print("     Absolute path: %s" % os.path.abspath(PDF))
    print("     Size         : %d bytes (%.2f MB)" % (size, size / (1024 * 1024)))
    pages = pdf_pages(PDF)
    if pages is not None:
        print("     Pages        : %d" % pages)
    else:
        print("     Pages        : unknown (pdfinfo not available or failed)")
    print("     Diagnostics  : %d error(s), %d warning(s)" % (errors, warnings))
    print("-" * 70)

    if not diagnostics_clean:
        say(BAD, "Build rejected: this project requires zero errors and zero warnings.")
        say(INFO, "Fix the diagnostics printed above, then run the build again.")
        return 1

    if not args.check:
        say(INFO, "Skipped page-render verification (pass --check to run it; about ten minutes).")
        return 0

    # ---- 逐页渲染 + 版心溢出扫描（可选，很慢）----
    print()
    print("== Verification: per-page render + margin overflow scan ==")
    # tools/check_overflow.py needs Pillow。先自己检查，别让"缺 Pillow"被误报成
    # "版心溢出"（两者都会让那个脚本非零退出）。本脚本**不安装**任何包。
    if not ensure_pillow():
        return 1
    stale = clean_pages()
    if stale:
        say(INFO, "Removed %d pre-existing page-*.png before rendering." % stale)
    say(INFO, "Rendering every page as PNG ...")
    cp = run([exe, "compile"] + font_args + ["--format", "png", "--ppi", "90",
              "main.typ", "build/page-{p}.png"], cwd=BOOK, stream=True)
    if cp.returncode != 0:
        say(BAD, "Page render FAILED (exit code %d)." % cp.returncode)
        clean_pages()
        say(INFO, "Removed book/build/page-*.png")
        return 1

    pngs = sorted(glob.glob(os.path.join(BUILD, "page-*.png")))
    say(OK, "Rendered %d page image(s)." % len(pngs))

    say(INFO, "Scanning for content outside the text block (tools/check_overflow.py) ...")
    try:
        rc = subprocess.run([sys.executable, OVERFLOW, "--out", BUILD], cwd=ROOT).returncode
    finally:
        say(INFO, "Removed %d temporary page-*.png file(s)." % clean_pages())

    if rc != 0:
        say(BAD, "Overflow scan reported pages outside the text block (see the list above).")
        return 1
    say(OK, "Overflow scan clean.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
