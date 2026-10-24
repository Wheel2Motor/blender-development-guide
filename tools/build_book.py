#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 构建书籍 PDF 或实验性 HTML。

做三件事：

1. 默认用绝对路径和项目配置字体运行 Typst，完全不看系统字体，因此构建可复现、
   也不会回退到系统里的商业字体；可选 ``--use-system-fonts`` 会枚举本机字体，并从
   当前平台的候选列表中选择真实存在的正文与等宽字体；
2. PDF 直接编译；HTML 会先把维护于 ``book/figures`` 的 Cetz 图预渲染为
   ``book/build/res/*.svg``，按字体模式准备网页字体，再编译正文并嵌入样式表；
3. 成功后打印**产物的绝对路径**、文件大小、PDF 页数（``pdfinfo``，没有就跳过），
   以及 Typst 的 error / warning 计数；PDF 要求零诊断，HTML 只放行上游明确的
   实验导出警告；
4. 可选 ``--check``：构建前用钉住版本的 Blender 源码核对全部 ``#src(...)`` 引用，
   构建后逐页渲染 PNG，跑 ``tools/check_overflow.py`` 扫版心溢出，最后删掉
   ``book/build/page-*.png``。默认**不跑**（很慢，约十分钟）。

环境边界：本脚本**只检查、不安装**任何工具。Typst 缺失时打印官方安装方式并非零退出
（**不会**下载 Typst，也不会往 ``tools/bin/`` 放东西）；``pdfinfo`` 与 Pillow 是可选
依赖，缺失时分别只降级"页数报告"与"``--check`` 的溢出扫描"，不影响普通构建。
普通构建不读取也不要求 ``blender/``；只有 ``--check`` 要求该目录存在、是可读的 Git
检出，并与 ``book/blender-baseline.json`` 中的固定提交一致。
项目字体构建只要求 ``book/fonts/`` 中存在 Typst 可扫描的字体，不校验哈希或版本，
也不在构建过程中下载或修复；缺失时引导运行 ``scons init-book``。输出目录
``book/build/`` 在工程内。

用法::

    python tools/build_book.py            # 只构建并报告
    python tools/build_book.py --format html
    python tools/build_book.py --check    # 源码引用核对 + 构建 + 逐页渲染与溢出扫描
    python tools/build_book.py --use-system-fonts

注意：本脚本打印到控制台的一切文字都是英文 —— Windows 控制台默认代码页是 GBK，
中文输出会乱码。注释可以保留中文。
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from font_config import (
    PROJECT_CONFIG,
    SYSTEM_FONTS_CONFIG,
    load_project_config,
    load_system_fonts_config,
    platform_key,
    typst_relative,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK = os.path.join(ROOT, "book")
BUILD = os.path.join(BOOK, "build")
MAIN = os.path.join(BOOK, "main.typ")
HTML_STYLE = os.path.join(BOOK, "html", "style.css")
HTML_RES = os.path.join(BUILD, "res")
OUTPUTS = {
    "pdf": os.path.join(BUILD, "blender-development-guide.pdf"),
    "html": os.path.join(BUILD, "blender-development-guide.html"),
}
FIGURES = os.path.join(BOOK, "figures")
OVERFLOW = os.path.join(ROOT, "tools", "check_overflow.py")
SOURCE_REFS = os.path.join(ROOT, "qa", "check_source_refs.py")
# 默认字体由工程自带（book/fonts/，由 tools/init_book.py 下载），构建完全不看系统字体。
FONTS = os.path.join(BOOK, "fonts")
FONT_SUFFIXES = (".ttf", ".otf", ".ttc", ".otc")

# Typst 的字体相关参数，含义见 doc/README-BOOK.md「字体」一节：
#   --font-path             指向工程字体目录；
#   --ignore-system-fonts   不看系统字体 —— 排除 LiSu（隶书，商业字体）这类回退，
#                           也是构建可复现的前提；
#   --ignore-embedded-fonts 连 Typst 内置字体也不参与回退，缺字必须显式暴露，
#                           而不是被 DejaVu / Libertinus 悄悄顶掉。
PROJECT_FONT_ARGS = [
    "--font-path", FONTS, "--ignore-system-fonts", "--ignore-embedded-fonts",
    "--input", "font-config=" + typst_relative(PROJECT_CONFIG),
]

try:
    PROJECT_FONT_CONFIG = load_project_config()
    SYSTEM_FONT_CONFIG = load_system_fonts_config()
    FONT_CONFIG_ERROR = None
except ValueError as exc:
    PROJECT_FONT_CONFIG = {}
    SYSTEM_FONT_CONFIG = {}
    FONT_CONFIG_ERROR = str(exc)

OK, BAD, INFO = "[ OK ]", "[FAIL]", "[ .. ]"

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def say(tag: str, msg: str) -> None:
    print("%s %s" % (tag, msg))


def display_command(command: list[str]) -> str:
    """Display an argv list using the current platform's quoting rules."""
    if os.name == "nt":
        return subprocess.list2cmdline(command)
    return shlex.join(command)


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


def verify_source_references() -> bool:
    """Validate every #src reference against the pinned Blender checkout.

    This intentionally belongs to ``--check`` rather than the plain build: readers who
    only want the rendered book must not need the large Blender source checkout.
    """
    print()
    print("== Verification: source references against pinned Blender revision ==")
    say(INFO, "--check requires ./blender at the commit pinned by the book.")
    sys.stdout.flush()
    cp = run([sys.executable, SOURCE_REFS], cwd=ROOT, stream=True)
    if cp.returncode != 0:
        say(BAD, "Source-reference verification failed.")
        say(INFO, "Run 'scons init-blender' to prepare the pinned checkout, or use")
        say(INFO, "plain 'scons build-book' when you only need to render the book.")
        return False
    say(OK, "Source references match the pinned Blender checkout.")
    return True


def find_typst() -> str | None:
    local = os.path.join(ROOT, "tools", "bin", "typst")
    for cand in (local, local + ".exe"):
        if os.path.isfile(cand):
            return cand
    return shutil.which("typst")


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
    candidates = SYSTEM_FONT_CONFIG["platforms"][platform_key()]

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
    code = list(mono)
    if SYSTEM_FONT_CONFIG.get("append_body_to_code", False):
        code.extend(name for name in body if name not in code)
    return body, code


def system_font_args(exe: str) -> tuple[list[str], list[str], list[str]] | None:
    selected = select_system_fonts(exe)
    if selected is None:
        return None
    body, code = selected
    say(OK, "System body fonts: %s" % " -> ".join(body))
    say(OK, "System code fonts: %s" % " -> ".join(code))
    say(INFO, "System-font mode is machine-dependent; use configured Noto fonts for releases.")
    args = [
        "--ignore-embedded-fonts",
        "--input", "font-config=" + typst_relative(SYSTEM_FONTS_CONFIG),
        "--input", "font-platform=" + platform_key(),
        "--input", "font-body=" + ";".join(body),
        "--input", "font-code=" + ";".join(code),
    ]
    return args, body, code


def count_diagnostics(out: str) -> tuple[int, int]:
    """Typst 的诊断行形如 ``error: ...`` / ``warning: ...``（可能在文件路径行之后）。"""
    errors = len(re.findall(r"(?m)^\s*error:", out))
    warnings = len(re.findall(r"(?m)^\s*warning:", out))
    return errors, warnings


def unexpected_html_warnings(out: str) -> list[str]:
    """Return warnings other than Typst's known experimental HTML diagnostics."""
    messages = re.findall(r"(?m)^\s*warning:\s*(.+?)\s*$", out)
    return [
        message for message in messages
        if message != "html export is under active development and incomplete"
        and not message.endswith("was ignored during HTML export")
    ]


def reset_html_resources() -> bool:
    """Remove generated HTML assets while keeping the operation inside build/res."""
    try:
        os.makedirs(HTML_RES, exist_ok=True)
        for entry in os.scandir(HTML_RES):
            if entry.is_file() and entry.name.lower().endswith(
                    (".svg", ".ttf", ".otf", ".ttc", ".otc", ".txt")):
                os.remove(entry.path)
    except OSError as exc:
        say(BAD, "Could not reset HTML resources in %s: %s" % (HTML_RES, exc))
        return False
    return True


def discover_project_font_faces(exe: str, families: list[str]) -> list[dict] | None:
    """Ask Typst which files and variants back the configured project families."""
    cp = run([
        exe, "fonts", "--font-path", FONTS,
        "--ignore-system-fonts", "--ignore-embedded-fonts", "--variants",
    ], cwd=ROOT, stream=False)
    if cp.returncode != 0:
        say(BAD, "Could not enumerate project font variants with 'typst fonts'.")
        out = text_of(cp).strip()
        if out:
            print(out)
        return None

    wanted = {family.casefold() for family in families}
    current_family = ""
    pending_path: str | None = None
    faces: list[dict] = []
    for raw_line in text_of(cp).splitlines():
        if raw_line and not raw_line[0].isspace():
            current_family = raw_line.strip()
            pending_path = None
            continue
        path_match = re.match(r"^\s*[├└](?:─)?\s+(.+?)\s*$", raw_line)
        if path_match:
            pending_path = path_match.group(1)
            continue
        variant_match = re.match(
            r"^\s*(?:│\s*)?Style:\s*([^,]+),\s*Weight:\s*(\d+),\s*Stretch:",
            raw_line)
        if not variant_match or not pending_path or current_family.casefold() not in wanted:
            continue
        source = pending_path
        if not os.path.isabs(source):
            source = os.path.join(ROOT, source)
        source = os.path.normpath(source)
        if not os.path.isfile(source):
            say(BAD, "Typst reported a project font path that does not exist: %s" % source)
            return None
        style_name = variant_match.group(1).strip().casefold()
        style = "italic" if "italic" in style_name else (
            "oblique" if "oblique" in style_name else "normal")
        faces.append({
            "family": current_family,
            "source": source,
            "style": style,
            "weight": int(variant_match.group(2)),
        })

    discovered = {face["family"].casefold() for face in faces}
    missing = [family for family in families if family.casefold() not in discovered]
    if missing:
        say(BAD, "Typst could not find configured project font families: %s"
            % ", ".join(missing))
        say(INFO, "List recognized names with:")
        say(INFO, "  typst fonts --font-path book/fonts --ignore-system-fonts")
        return None
    return faces


def copy_html_fonts(exe: str, families: list[str]) -> list[dict] | None:
    """Discover and copy configured project fonts for the experimental HTML export."""
    faces = discover_project_font_faces(exe, families)
    if faces is None:
        return None

    copied: dict[str, str] = {}
    used_names: set[str] = set()

    def destination_name(source: str) -> str:
        if source in copied:
            return copied[source]
        basename = os.path.basename(source)
        stem, suffix = os.path.splitext(basename)
        candidate = basename
        index = 2
        while candidate.casefold() in used_names:
            candidate = "%s-%d%s" % (stem, index, suffix)
            index += 1
        copied[source] = candidate
        used_names.add(candidate.casefold())
        return candidate

    try:
        for face in faces:
            target = destination_name(face["source"])
            if not os.path.isfile(os.path.join(HTML_RES, target)):
                shutil.copy2(face["source"], os.path.join(HTML_RES, target))
            face["file"] = target
        license_count = 0
        for base, _dirs, files in os.walk(FONTS):
            for filename in files:
                if not filename.lower().endswith(".txt"):
                    continue
                source = os.path.join(base, filename)
                target = destination_name(source)
                shutil.copy2(source, os.path.join(HTML_RES, target))
                license_count += 1
    except OSError as exc:
        say(BAD, "Could not copy HTML fonts into %s: %s" % (HTML_RES, exc))
        return None
    say(OK, "Copied %d project font file(s) and %d text license file(s) into %s."
        % (len(copied) - license_count, license_count, HTML_RES))
    return faces


def css_stack(names: list[str]) -> str:
    generic = {"serif", "sans-serif", "monospace", "system-ui"}
    return ", ".join(
        name if name in generic else '"%s"' % name.replace("\\", "\\\\").replace('"', '\\"')
        for name in names)


def html_font_css(use_system_fonts: bool, faces: list[dict],
                  body_fonts: list[str], code_fonts: list[str]) -> str:
    """Build web-font faces and CSS slots from the selected font configuration."""
    rules = []
    if not use_system_fonts:
        for face in faces:
            filename = face["file"]
            family = face["family"]
            weight = face["weight"]
            style = face["style"]
            rules.append(
                '@font-face {\n'
                '  font-family: "%s";\n'
                '  src: url("res/%s");\n'
                '  font-style: %s;\n'
                '  font-weight: %d;\n'
                '  font-display: swap;\n'
                '}' % (family.replace("\\", "\\\\").replace('"', '\\"'),
                       filename, style, weight)
            )

    rules.append(
        ':root {\n'
        '  --book-font-body: %s;\n'
        '  --book-font-code: %s;\n'
        '}' % (css_stack(body_fonts), css_stack(code_fonts))
    )
    return "\n\n".join(rules) + "\n\n"


def balanced_call(text: str, start: int) -> str | None:
    """Extract one balanced function call, skipping strings and Typst comments."""
    opening = text.find("(", start)
    if opening < 0:
        return None

    depth = 0
    quote = False
    escaped = False
    line_comment = False
    block_comment = False
    index = opening
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and following == "/":
                block_comment = False
                index += 1
        elif quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = False
        elif char == "/" and following == "/":
            line_comment = True
            index += 1
        elif char == "/" and following == "*":
            block_comment = True
            index += 1
        elif char == '"':
            quote = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    return None


def figure_specs() -> list[tuple[str, str, str]] | None:
    """Discover module figures and direct figure(canvas(...)) expressions."""
    specs: list[tuple[str, str, str]] = []
    try:
        sources = sorted(glob.glob(os.path.join(FIGURES, "*.typ")))
        for source in sources:
            stem = os.path.splitext(os.path.basename(source))[0]
            function = "fig-" + stem
            with open(source, encoding="utf-8") as fh:
                text = fh.read()
            if not re.search(r"(?m)^#let\s+%s\(\)\s*=" % re.escape(function), text):
                say(BAD, "Figure module does not export the expected %s() function: %s"
                    % (function, source))
                return None
            relative_source = os.path.relpath(source, BOOK).replace(os.sep, "/")
            wrapper = (
                '#import "%s": %s\n'
                '#set page(width: auto, height: auto, margin: 0pt, fill: none)\n'
                '#%s()\n' % (relative_source, function, function)
            )
            specs.append((function, wrapper,
                          os.path.join(HTML_RES, function + ".svg")))

        inline_pattern = re.compile(
            r'html-figure\(\s*"(?P<label>fig-[a-z0-9-]+)"\s*,\s*'
            r'\(\)\s*=>\s*(?P<canvas>canvas\()'
        )
        for chapter in sorted(glob.glob(os.path.join(BOOK, "chapters", "*.typ"))):
            with open(chapter, encoding="utf-8") as fh:
                text = fh.read()
            if re.search(r"#figure\(\s*canvas\(", text):
                say(BAD, "Inline Cetz figure must use html-figure(...): %s" % chapter)
                return None
            for match in inline_pattern.finditer(text):
                expression = balanced_call(text, match.start("canvas"))
                if expression is None:
                    say(BAD, "Could not parse an inline Cetz figure in %s." % chapter)
                    return None
                label = match.group("label")
                tail = text[match.start("canvas") + len(expression):
                            match.start("canvas") + len(expression) + 1200]
                if not re.search(r"\)\s*<%s>" % re.escape(label), tail):
                    say(BAD, "Inline Cetz asset name and figure label differ: %s" % chapter)
                    return None
                wrapper = (
                    '#import "@preview/cetz:0.3.4": canvas, draw\n'
                    '#import "common.typ": *\n'
                    '#set page(width: auto, height: auto, margin: 0pt, fill: none)\n'
                    '#%s\n' % expression
                )
                specs.append((label, wrapper,
                              os.path.join(HTML_RES, label + ".svg")))
    except OSError as exc:
        say(BAD, "Could not inspect the figure modules: %s" % exc)
        return None

    if not specs:
        say(BAD, "No Cetz figures were discovered in the book sources.")
        return None
    names = [name for name, _wrapper, _output in specs]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        say(BAD, "Duplicate HTML figure asset name(s): %s" % ", ".join(duplicates))
        return None
    return specs


def build_html_figures(exe: str, font_args: list[str]) -> bool:
    """Pre-render each Cetz figure as one transparent, tightly sized SVG."""
    specs = figure_specs()
    if specs is None:
        return False

    say(INFO, "Pre-rendering %d Cetz figure(s) as SVG ..." % len(specs))
    for name, wrapper_text, output in specs:
        wrapper = None
        temporary_output = output + ".tmp.svg"
        try:
            with tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", newline="\n", delete=False,
                    dir=BOOK, prefix=".html-figure-", suffix=".typ") as fh:
                wrapper = fh.name
                fh.write(wrapper_text)

            command = [exe, "compile"] + font_args + [
                "--format", "svg", wrapper, temporary_output,
            ]
            cp = run(command, cwd=BOOK, stream=False)
            out = text_of(cp)
            errors, warnings = count_diagnostics(out)
            if cp.returncode != 0 or errors or warnings:
                if out.strip():
                    print(out.rstrip())
                say(BAD, "Could not render %s (exit %d, %d error(s), %d warning(s))."
                    % (name, cp.returncode, errors, warnings))
                return False
            if not os.path.isfile(temporary_output):
                say(BAD, "Typst did not create the expected SVG: %s" % temporary_output)
                return False
            os.replace(temporary_output, output)
            say(OK, "Rendered %s" % os.path.relpath(output, BOOK))
        except OSError as exc:
            say(BAD, "Could not prepare %s: %s" % (name, exc))
            return False
        finally:
            for temporary in (wrapper, temporary_output):
                if temporary and os.path.isfile(temporary):
                    try:
                        os.remove(temporary)
                    except OSError:
                        pass

    return True


def embed_html_style(path: str, use_system_fonts: bool,
                     faces: list[dict], body_fonts: list[str],
                     code_fonts: list[str]) -> bool:
    """Embed the maintained stylesheet and generated web-font declarations."""
    try:
        with open(HTML_STYLE, encoding="utf-8") as fh:
            css = fh.read().strip()
        with open(path, encoding="utf-8") as fh:
            document = fh.read()
    except OSError as exc:
        say(BAD, "Could not read the HTML stylesheet or output: %s" % exc)
        return False

    if not css:
        say(BAD, "HTML stylesheet is empty: %s" % HTML_STYLE)
        return False
    if "</style" in css.lower():
        say(BAD, "HTML stylesheet contains a forbidden </style sequence: %s" % HTML_STYLE)
        return False
    if "</head>" not in document:
        say(BAD, "Could not embed the stylesheet: generated HTML has no </head> element.")
        return False

    combined_css = html_font_css(
        use_system_fonts, faces, body_fonts, code_fonts) + css
    style = '\n<style data-source="book/html/style.css">\n%s\n</style>\n' % combined_css
    document = document.replace("</head>", style + "</head>", 1)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", newline="\n", delete=False,
                dir=os.path.dirname(path), prefix=".html-style-", suffix=".tmp") as fh:
            temporary = fh.name
            fh.write(document)
        os.replace(temporary, path)
    except OSError as exc:
        say(BAD, "Could not write the styled HTML atomically: %s" % exc)
        if temporary and os.path.isfile(temporary):
            try:
                os.remove(temporary)
            except OSError:
                pass
        return False

    say(OK, "Embedded HTML stylesheet: %s" % HTML_STYLE)
    return True


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
    """Read-only configured-font preflight for builds.

    Downloading belongs exclusively to init_book.py. A build must never mutate
    its inputs, so it uses check-only mode and stops with the platform entry
    points when no usable project-font input has been prepared.
    """
    try:
        from init_book import check_fonts
    except Exception as exc:  # noqa: BLE001
        say(BAD, "Could not load the project font checker: %s" % exc)
        return False

    if check_fonts(
            check_only=True,
            heading="== Preflight: configured project fonts (no downloads) =="):
        return True

    say(BAD, "Project fonts are not prepared for the selected slot configuration.")
    say(INFO, "The build never downloads or repairs fonts. Prepare them first:")
    say(INFO, "  scons init-book")
    say(INFO, "You may also copy supported font files into book/fonts/ and edit fonts.json.")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the book as PDF or experimental HTML.")
    ap.add_argument("--format", choices=("pdf", "html"), default="pdf",
                    help="output format (default: pdf; html is experimental)")
    ap.add_argument("--check", "--verify", dest="check", action="store_true",
                    help="validate source references against the pinned Blender checkout, "
                         "then render every PDF page and scan for margin overflow")
    ap.add_argument("--use-system-fonts", action="store_true",
                    help="use an OS-specific list of installed fallback fonts instead of "
                         "the configured Noto fonts (not reproducible; not for releases)")
    args = ap.parse_args()

    if args.format == "html" and args.check:
        ap.error("--check only applies to paged PDF output and cannot be used with HTML")

    output = OUTPUTS[args.format]

    print("=" * 70)
    print("Build the book")
    print("Project root : %s" % ROOT)
    print("Book dir     : %s" % BOOK)
    print("Format       : %s%s" % (args.format,
                                      " (experimental)" if args.format == "html" else ""))
    print("Output       : %s" % output)
    print("Verify       : %s" % ("yes (--check)" if args.check else "no"))
    print("Fonts        : %s" % ("system fallbacks" if args.use_system_fonts
                                 else "configured Noto fonts"))
    print("=" * 70)

    if not os.path.isfile(MAIN):
        say(BAD, "Entry file not found: %s" % MAIN)
        return 1
    if args.format == "html" and not os.path.isfile(HTML_STYLE):
        say(BAD, "HTML stylesheet not found: %s" % HTML_STYLE)
        return 1
    if FONT_CONFIG_ERROR:
        say(BAD, "Font configuration is invalid: %s" % FONT_CONFIG_ERROR)
        return 1

    if args.check and not verify_source_references():
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
        selected_system = system_font_args(exe)
        if selected_system is None:
            return 1
        font_args, html_body_fonts, html_code_fonts = selected_system
        html_body_fonts = html_body_fonts + ["system-ui", "sans-serif"]
        html_code_fonts = html_code_fonts + ["monospace"]
        html_font_faces: list[dict] = []
    else:
        # 项目字体必须已经由 init-book 备好；构建只读核验，不下载、不修复。
        if not verify_project_fonts():
            return 1
        font_files = [
            os.path.join(base, filename)
            for base, _dirs, files in os.walk(FONTS)
            for filename in files
            if filename.lower().endswith(FONT_SUFFIXES)
        ]
        say(OK, "Using %d project font file(s) from %s; system fonts are ignored."
            % (len(font_files), FONTS))
        font_args = PROJECT_FONT_ARGS
        html_body_fonts = list(PROJECT_FONT_CONFIG["body"]) + ["sans-serif"]
        html_code_fonts = list(PROJECT_FONT_CONFIG["code"]) + ["monospace"]
        html_font_faces = []

    if args.format == "html":
        if not reset_html_resources():
            return 1
        if not build_html_figures(exe, font_args):
            return 1
        if not args.use_system_fonts:
            families = list(dict.fromkeys(
                PROJECT_FONT_CONFIG["body"] + PROJECT_FONT_CONFIG["code"]))
            copied_faces = copy_html_fonts(exe, families)
            if copied_faces is None:
                return 1
            html_font_faces = copied_faces
        if args.use_system_fonts:
            say(INFO, "System-font mode selected; no font files were copied to build/res.")

    format_args = ["--format", args.format]
    if args.format == "html":
        format_args = ["--features", "html"] + format_args

    command = [exe, "compile"] + font_args + format_args + [MAIN, output]
    start = time.time()
    say(INFO, "Running: %s" % display_command(command))
    cp = run(command, cwd=BOOK, stream=False)
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

    if not os.path.isfile(output):
        say(BAD, "typst exited 0 but the %s output is missing: %s"
            % (args.format.upper(), output))
        return 1

    unexpected_warnings = unexpected_html_warnings(out) if args.format == "html" else []
    diagnostics_acceptable = (
        errors == 0
        and (warnings == 0 or (args.format == "html" and not unexpected_warnings))
    )
    if diagnostics_acceptable and args.format == "html":
        if not embed_html_style(output, args.use_system_fonts, html_font_faces,
                                html_body_fonts, html_code_fonts):
            return 1

    size = os.path.getsize(output)
    print()
    print("-" * 70)
    if diagnostics_acceptable and warnings == 0:
        say(OK, "Build succeeded in %.1fs." % elapsed)
    elif diagnostics_acceptable:
        say(OK, "Experimental HTML build succeeded in %.1fs with %d expected warning(s)."
            % (elapsed, warnings))
    else:
        say(BAD, "Typst produced %s in %.1fs, but diagnostics are not acceptable."
            % (args.format.upper(), elapsed))
    print("     Artifact     : %s" % output)
    print("     Absolute path: %s" % os.path.abspath(output))
    print("     Size         : %d bytes (%.2f MB)" % (size, size / (1024 * 1024)))
    if args.format == "pdf":
        pages = pdf_pages(output)
        if pages is not None:
            print("     Pages        : %d" % pages)
        else:
            print("     Pages        : unknown (pdfinfo not available or failed)")
    else:
        print("     Pages        : n/a (HTML is not paged)")
    print("     Diagnostics  : %d error(s), %d warning(s)" % (errors, warnings))
    if unexpected_warnings:
        print("     Unexpected   : %s" % "; ".join(unexpected_warnings))
    print("-" * 70)

    if not diagnostics_acceptable:
        say(BAD, "Build rejected: PDF requires zero diagnostics; HTML only permits known "
            "experimental-export warnings.")
        say(INFO, "Fix the diagnostics printed above, then run the build again.")
        return 1

    if not args.check:
        if args.format == "html":
            say(INFO, "HTML is not paged; --check and release packaging only support PDF.")
        else:
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
