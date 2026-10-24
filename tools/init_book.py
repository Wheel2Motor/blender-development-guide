#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 初始化书籍构建环境（Typst）。

做四件事：

1. 找 Typst（PATH 或 ``tools/bin/``）、打印版本；
2. 默认在项目字体目录为空时下载内置的 Noto 字体组；已有字体文件直接使用，不校验
   哈希或版本。``book/fonts/noto.json`` 只定义正文和代码槽位的字体族名称。
   ``--use-system-fonts`` 则读取
   ``system-fallbacks.json`` 并选择本机已有字体，不下载项目字体；
3. 建目录骨架（``book/build`` 尤其重要：Typst 不会自己创建输出目录）；
4. 预取 cetz 宏包 —— **用临时目录里的最小探针文件**，不碰书稿、不产出书稿 PDF。

用法::

    python tools/init_book.py               # 检查 + 补齐字体 + 预取 cetz
    python tools/init_book.py --use-system-fonts  # 跳过项目字体下载
    python tools/init_book.py --check-only  # 只检查，不下载、不编译

**本脚本不构建书稿。** PDF 与实验性 HTML 都由 ``tools/build_book.py`` 负责。历史上的
init 会编译一次全书来预取 cetz，那既慢又会让"初始化"意外产生 PDF；现在改成
在临时目录里编译一个三行的探针文件（见 ``prefetch_cetz``）。

环境边界（重要）：

* **可以自动下载**（只落进工程目录，删掉可重取）：正文/代码用的字体 ->
  ``book/fonts/``；cetz 宏包 -> Typst 自己的包缓存（Typst 的常规机制）。
* **只检查、不安装**：SCons、Typst、Python 3，以及 ``pdfinfo`` / Pillow 这些
  可选依赖。本脚本**不调用任何包管理器、不下载任何 CLI 可执行文件、不写系统目录**
  （系统字体目录、``%APPDATA%``、``/usr``、``~/.local`` 都不会被碰）。Typst 缺失时
  打印官方安装命令并以**非零退出码**结束；可选依赖缺失只提示，不影响退出码。

内置 Noto 字体组的下载地址、压缩包成员和目标文件名只在本脚本中维护；
``book/fonts/noto.json`` 只保存 Typst 的正文与代码字体槽位。用户可以把自己的
``.ttf``、``.otf``、``.ttc`` 或 ``.otc`` 文件放入 ``book/fonts/``，再把配置改为
Typst 识别出的字体族名称。已有字体文件直接使用，不检查哈希或版本。

注意：本脚本打印到控制台的一切文字都是英文 —— Windows 控制台默认代码页是 GBK，
中文输出会乱码。注释可以保留中文。
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

from font_config import FONT_DIR, NOTO_CONFIG, load_noto_config

TYPST_RECOMMENDED = "0.15.1"   # 本工程在这一版上验证过
CETZ_VERSION = "0.3.4"         # book/figures/*.typ 与 chapters/01-architecture.typ 里 import 的版本

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK = os.path.join(ROOT, "book")
BUILD = os.path.join(BOOK, "build")
PDF = os.path.join(BUILD, "blender-development-guide.pdf")
FONTS = FONT_DIR

OK, WARN, BAD, INFO = "[ OK ]", "[WARN]", "[FAIL]", "[ .. ]"

# 单个下载源允许的重试次数
RETRIES = 3

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def say(tag: str, msg: str) -> None:
    print("%s %s" % (tag, msg))


def run(cmd: list[str], cwd: str | None = None,
        timeout: int = 1800) -> subprocess.CompletedProcess:
    """跑外部命令并捕获输出；输出经临时文件中转（比 Pipe 兼容性更好）。"""
    handle = tempfile.TemporaryFile()
    try:
        try:
            cp = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=handle, stderr=subprocess.STDOUT,
                                timeout=timeout)
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


def ver_tuple(s: str) -> tuple[int, ...]:
    parts = [int(p) for p in re.findall(r"\d+", s)]
    return tuple(parts) if parts else (0,)


def cmp_ver(have: str, want: str) -> int:
    a, b = ver_tuple(have), ver_tuple(want)
    n = max(len(a), len(b))
    a, b = a + (0,) * (n - len(a)), b + (0,) * (n - len(b))
    return (a > b) - (a < b)


# ---------------------------------------------------------------------------
# 1) Typst
# ---------------------------------------------------------------------------
def find_typst() -> str | None:
    """先找 ``tools/bin/typst[.exe]``，再找 PATH。

    注意：``tools/bin/`` 只是一个**可选的固定版本位置**（想钉住某一版 Typst 时
    自己把二进制放进去，该目录被 .gitignore 忽略）。**两个脚本都不会下载 Typst**
    —— 找不到就报错并打印官方安装方式，装 Typst 是使用者自己的事。
    """
    local = os.path.join(ROOT, "tools", "bin", "typst")
    for cand in (local, local + ".exe"):
        if os.path.isfile(cand):
            return cand
    return shutil.which("typst")


def typst_version(exe: str) -> str | None:
    cp = run([exe, "--version"])
    if cp.returncode != 0:
        return None
    m = re.search(r"\d+\.\d+(?:\.\d+)?", text_of(cp))
    return m.group(0) if m else None


def check_python() -> bool:
    """报告解释器版本。**不自造门槛** —— 有明确要求的版本以第 2 章为准。

    本脚本**只检查、不安装**任何工具（包括 Python）。
    """
    ver = platform.python_version()
    if sys.version_info[0] == 3:
        say(OK, "python   : %s  (%s)" % (ver, sys.executable))
        say(INFO, "           no minimum is asserted here -- chapter 2 is the reference")
        say(INFO, "           for the required Python version.")
        return True
    say(BAD, "python   : %s  (this project needs Python 3)" % ver)
    say(INFO, "Install Python 3 yourself -- this script never installs it:")
    say(INFO, "  Windows : winget install --id Python.Python.3.12   (tick 'Add to PATH')")
    say(INFO, "  macOS   : brew install python")
    say(INFO, "  Linux   : sudo apt install python3   # Debian/Ubuntu (dnf/pacman likewise)")
    say(INFO, "  any OS  : https://www.python.org/downloads/")
    return False


def check_typst() -> str | None:
    print()
    print("== 1. Typst ==")
    exe = find_typst()
    if not exe:
        say(BAD, "typst NOT FOUND on PATH (also checked tools/bin/typst[.exe]).")
        say(INFO, "This project was verified with Typst %s. It is NOT downloaded by this script."
            % TYPST_RECOMMENDED)
        say(INFO, "Install it yourself, for example:")
        say(INFO, "  Windows : winget install --id Typst.Typst")
        say(INFO, "            or scoop install typst")
        say(INFO, "  macOS   : brew install typst")
        say(INFO, "  Linux   : cargo install --locked typst-cli")
        say(INFO, "  any OS  : download from https://github.com/typst/typst/releases")
        say(INFO, "Then re-run the same init-book command.")
        return None

    ver = typst_version(exe)
    say(OK, "typst found: %s" % exe)
    if ver:
        say(OK, "typst version: %s (recommended for this project: %s)"
            % (ver, TYPST_RECOMMENDED))
        if cmp_ver(ver, TYPST_RECOMMENDED) != 0:
            say(WARN, "Version differs from the verified one; layout may shift.")
    else:
        say(WARN, "Could not parse 'typst --version'; recommended version is %s."
            % TYPST_RECOMMENDED)
    return exe


# ---------------------------------------------------------------------------
# 2) 字体：槽位配置 + 默认 Noto 下载器
# ---------------------------------------------------------------------------
try:
    NOTO_FONT_CONFIG = load_noto_config()
    FONT_CONFIG_ERROR = None
except ValueError as exc:
    NOTO_FONT_CONFIG = {}
    FONT_CONFIG_ERROR = str(exc)

# JSON 只描述 Typst 槽位；自动下载的默认资产属于初始化实现细节，集中留在这里。
# 下载结果只做传输层检查：直链必须生成非空文件，ZIP 必须能打开并包含目标成员；
# 不校验哈希、字体版本、内部族名或字形覆盖。
FONT_SUFFIXES = (".ttf", ".otf", ".ttc", ".otc")
DEFAULT_BODY_FONTS = ("Noto Sans SC", "Noto Sans")
DEFAULT_CODE_FONTS = ("Noto Sans Mono", "Noto Sans Mono CJK SC", "Noto Sans")
DEFAULT_FONT_GROUPS = (
    {
        "label": "Noto Sans SC (body text)",
        "url": "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip",
        "kind": "zip",
        "files": (
            {"file": "NotoSansSC-Regular.otf", "member": "NotoSansSC-Regular.otf"},
            {"file": "NotoSansSC-Bold.otf", "member": "NotoSansSC-Bold.otf"},
        ),
    },
    {
        "label": "Noto Sans Mono (code Latin and symbols)",
        "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansMono/hinted/ttf/",
        "kind": "direct_multi",
        "files": (
            {
                "file": "NotoSansMono-Regular.ttf",
                "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansMono/hinted/ttf/NotoSansMono-Regular.ttf",
            },
            {
                "file": "NotoSansMono-Bold.ttf",
                "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansMono/hinted/ttf/NotoSansMono-Bold.ttf",
            },
        ),
    },
    {
        "label": "Noto Sans Mono CJK SC (code CJK fallback)",
        "url": "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/13_NotoSansMonoCJKsc.zip",
        "kind": "zip",
        "files": (
            {
                "file": "NotoSansMonoCJKsc-Regular.otf",
                "member": "NotoSansMonoCJKsc-Regular.otf",
            },
            {
                "file": "NotoSansMonoCJKsc-Bold.otf",
                "member": "NotoSansMonoCJKsc-Bold.otf",
            },
        ),
    },
    {
        "label": "Noto Sans (last-resort fallback)",
        "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSans/hinted/ttf/",
        "kind": "direct_multi",
        "files": (
            {
                "file": "NotoSans-Regular.ttf",
                "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSans/hinted/ttf/NotoSans-Regular.ttf",
            },
            {
                "file": "NotoSans-Bold.ttf",
                "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSans/hinted/ttf/NotoSans-Bold.ttf",
            },
        ),
    },
    {
        "label": "font license files",
        "url": "https://raw.githubusercontent.com/",
        "kind": "direct_multi",
        "files": (
            {
                "file": "LICENSE-NotoSansSC.txt",
                "url": "https://raw.githubusercontent.com/notofonts/noto-cjk/main/LICENSE",
            },
            {
                "file": "LICENSE-NotoSansMonoCJK.txt",
                "url": "https://raw.githubusercontent.com/notofonts/noto-cjk/main/LICENSE",
            },
            {
                "file": "OFL-NotoSans.txt",
                "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/notosans/OFL.txt",
            },
            {
                "file": "OFL-NotoSansMono.txt",
                "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/notosansmono/OFL.txt",
            },
        ),
    },
)

def download(url: str, dest: str) -> bool:
    """下载到 dest。已有文件不经过版本、哈希、族名或字形检查。"""
    for attempt in range(1, RETRIES + 1):
        if shutil.which("curl"):
            cp = run(["curl", "-sSL", "--fail", "--retry", "2",
                      "-o", dest, url], timeout=3600)
            ok = cp.returncode == 0 and os.path.isfile(dest)
        else:
            try:
                import urllib.request
                with urllib.request.urlopen(url, timeout=120) as resp, \
                        open(dest, "wb") as out:
                    shutil.copyfileobj(resp, out)
                ok = True
            except Exception as exc:  # noqa: BLE001
                say(WARN, "urllib failed: %s" % exc)
                ok = False
        if ok and os.path.getsize(dest) > 0:
            return True
        say(WARN, "download attempt %d/%d failed or empty: %s"
            % (attempt, RETRIES, url))
    return False


def fetch_group(group: dict, workdir: str, wanted: list[dict]) -> dict[str, bool]:
    """下载一组字体来源，并解出 wanted 里的成员。

    返回 ``{文件名: 是否成功}``。同一 URL 只下载一次。
    """
    url = group["url"]
    say(INFO, "  fetching %s" % url)

    if group["kind"] == "direct":
        dest = os.path.join(workdir, wanted[0]["file"])
        if not download(url, dest):
            say(BAD, "  download FAILED: %s" % url)
            return {w["file"]: False for w in wanted}
        return {w["file"]: True for w in wanted}

    if group["kind"] == "direct_multi":
        # 多个直链文件（拉丁等宽字体、许可文本），逐个下到各自 URL。
        result: dict[str, bool] = {}
        for spec in wanted:
            dest = os.path.join(workdir, spec["file"])
            this_url = spec.get("url") or url + spec["file"]
            if download(this_url, dest):
                say(OK, "  fetched -> %s (%.1f KB)"
                    % (spec["file"], os.path.getsize(dest) / 1024))
                result[spec["file"]] = True
            else:
                say(BAD, "  download FAILED: %s" % this_url)
                result[spec["file"]] = False
        return result

    archive = os.path.join(workdir, os.path.basename(url.split("?")[0]))
    if not download(url, archive):
        say(BAD, "  download FAILED: %s" % url)
        return {w["file"]: False for w in wanted}

    result: dict[str, bool] = {}
    try:
        with zipfile.ZipFile(archive) as zf:
            names = zf.namelist()
            for spec in wanted:
                member = spec["member"]
                if member not in names:
                    alt = [n for n in names
                           if os.path.basename(n) == os.path.basename(member)]
                    if not alt:
                        say(BAD, "  %s not found in archive" % member)
                        result[spec["file"]] = False
                        continue
                    say(WARN, "  archive layout changed; using %s" % alt[0])
                    member = alt[0]
                dest = os.path.join(workdir, spec["file"])
                with zf.open(member) as src, open(dest, "wb") as out:
                    shutil.copyfileobj(src, out)
                say(OK, "  extracted -> %s (%.1f MB)"
                    % (spec["file"], os.path.getsize(dest) / 1024 / 1024))
                result[spec["file"]] = True
    except Exception as exc:  # noqa: BLE001
        say(BAD, "  extract FAILED: %s" % exc)
        for spec in wanted:
            result.setdefault(spec["file"], False)
    finally:
        try:
            os.remove(archive)
        except OSError:
            pass
    return result


def project_font_files() -> list[str]:
    """Return every Typst-supported font file below book/fonts/."""
    found: list[str] = []
    if not os.path.isdir(FONTS):
        return found
    for base, _dirs, files in os.walk(FONTS):
        for filename in files:
            if filename.lower().endswith(FONT_SUFFIXES):
                found.append(os.path.join(base, filename))
    return sorted(found)


def uses_default_font_slots() -> bool:
    """Whether the editable slot config still requests the built-in Noto profile."""
    return (
        tuple(NOTO_FONT_CONFIG.get("body", ())) == DEFAULT_BODY_FONTS
        and tuple(NOTO_FONT_CONFIG.get("code", ())) == DEFAULT_CODE_FONTS
    )


def check_fonts(check_only: bool, heading: str | None = None) -> bool:
    print()
    print(heading or
          "== 2. Fonts (all shipped in book/fonts/; build uses --ignore-system-fonts) ==")
    say(INFO, "Configuration: %s" % NOTO_CONFIG)
    if FONT_CONFIG_ERROR:
        say(BAD, "Font configuration is invalid: %s" % FONT_CONFIG_ERROR)
        return False
    say(INFO, "Font dir: %s" % FONTS)
    if not os.path.isdir(FONTS):
        if check_only:
            say(BAD, "Font directory is missing (--check-only does not create it).")
            return False
        os.makedirs(FONTS, exist_ok=True)

    existing_fonts = project_font_files()
    if existing_fonts:
        say(OK, "Found %d project font file(s); accepting them as supplied."
            % len(existing_fonts))
        say(INFO, "init-book does not inspect completeness, family names, glyphs, hashes, or versions.")
        say(INFO, "The subsequent Typst build determines whether the configured slots are usable.")
        return True

    if not uses_default_font_slots():
        say(INFO, "Custom font slots are configured; the built-in Noto downloader is disabled.")
        say(BAD, "No .ttf, .otf, .ttc, or .otc file was found in book/fonts/.")
        say(INFO, "Copy your font files there and set body/code family names in noto.json.")
        say(INFO, "Use 'typst fonts --font-path book/fonts --ignore-system-fonts'")
        say(INFO, "to see the family names Typst recognizes.")
        return False

    say(INFO, "Font directory is empty and default slots are selected; using the built-in Noto profile.")
    ok_all = True

    for group in DEFAULT_FONT_GROUPS:
        say(INFO, "%s" % group["label"])
        need: list[dict] = []
        for spec in group["files"]:
            path = os.path.join(FONTS, spec["file"])
            if os.path.isfile(path):
                say(OK, "  found: %s" % spec["file"])
                continue
            need.append(spec)

        if not need:
            continue
        if check_only:
            for spec in need:
                say(BAD, "  %s missing (--check-only does not download)"
                    % spec["file"])
            say(INFO, "  source: %s" % group["url"])
            say(INFO, "  re-run without --check-only to fetch it.")
            ok_all = False
            continue

        say(INFO, "  need %d file(s); downloading from the configured source"
            % len(need))
        with tempfile.TemporaryDirectory(prefix="dsh-fonts-") as workdir:
            fetched = fetch_group(group, workdir, need)
            for spec in need:
                if not fetched.get(spec["file"]):
                    ok_all = False
                    continue
                candidate = os.path.join(workdir, spec["file"])
                if not os.path.isfile(candidate):
                    say(BAD, "  download did not produce %s" % spec["file"])
                    ok_all = False
                    continue
                dest = os.path.join(FONTS, spec["file"])
                try:
                    os.replace(candidate, dest)
                except OSError as exc:
                    say(BAD, "  could not install %s: %s" % (spec["file"], exc))
                    ok_all = False
                    continue
                say(OK, "  installed atomically -> %s" % spec["file"])

    if ok_all:
        say(OK, "All default Noto files are present; files are accepted as supplied.")
    else:
        say(BAD, "Font preparation FAILED because required files are missing.")
    say(INFO, "Font usability is determined by the subsequent Typst build.")
    return ok_all


# ---------------------------------------------------------------------------
# 3) 目录骨架
# ---------------------------------------------------------------------------
def ensure_dirs(check_only: bool) -> None:
    print()
    print("== 3. Directory skeleton ==")
    rels = ["book/build", "book/fonts", "book/res", "book/chapters", "book/figures",
            "book/examples", "tools"]
    for rel in rels:
        p = os.path.join(ROOT, *rel.split("/"))
        if os.path.isdir(p):
            say(OK, "%s exists" % rel)
            continue
        if check_only:
            say(WARN, "%s missing (--check-only does not create it)" % rel)
            continue
        os.makedirs(p, exist_ok=True)
        say(OK, "%s created" % rel)
    say(INFO, "book/build matters most: Typst does not create the output directory.")


def check_system_fonts(exe: str | None) -> bool:
    """复用构建器的候选列表，检查系统字体模式是否能实际工作。"""
    print()
    print("== 2. System fonts ==")
    if not exe:
        say(INFO, "Skipped because Typst is unavailable.")
        return False

    # 两个入口必须共享同一套平台候选，避免 init 成功而 build 使用另一套名单。
    from build_book import select_system_fonts

    selected = select_system_fonts(exe)
    if selected is None:
        return False
    body, code = selected
    say(OK, "System body fonts: %s" % " -> ".join(body))
    say(OK, "System code fonts: %s" % " -> ".join(code))
    say(INFO, "Project font download was skipped (--use-system-fonts).")
    say(INFO, "System-font output is machine-dependent and must not be released.")
    return True


# ---------------------------------------------------------------------------
# 4) 预取 cetz 宏包（最小探针，不碰书稿）
# ---------------------------------------------------------------------------
PROBE_TYP = """// Temporary probe written by tools/init_book.py -- only exists to pull the
// @preview/cetz package into Typst's cache. It is NOT the book.
#import "@preview/cetz:%s": canvas
#canvas({})
""" % CETZ_VERSION


def prefetch_cetz(exe: str, check_only: bool) -> bool:
    print()
    print("== 4. Prefetch the cetz package (does NOT build the book) ==")
    if check_only:
        say(INFO, "Skipped (--check-only).")
        say(INFO, "The first 'scons build-book' run downloads @preview/cetz:%s and needs network access."
            % CETZ_VERSION)
        return True

    say(INFO, "Compiling a minimal probe in a TEMPORARY directory to populate the package cache.")
    say(INFO, "The book itself is NOT compiled here -- use 'scons build-book' for that.")

    with tempfile.TemporaryDirectory(prefix="dsh-cetz-") as workdir:
        typ = os.path.join(workdir, "cetz-probe.typ")
        out = os.path.join(workdir, "cetz-probe.pdf")
        with open(typ, "w", encoding="utf-8") as fh:
            fh.write(PROBE_TYP)
        cp = run([exe, "compile", typ, out], cwd=workdir)
        text = text_of(cp)
        if cp.returncode != 0:
            say(BAD, "Probe compile FAILED (exit code %d). Typst output follows:"
                % cp.returncode)
            print("-" * 70)
            print(text.rstrip())
            print("-" * 70)
            say(INFO, "The package cache may need network access on first run.")
            return False
        say(OK, "@preview/cetz:%s is available (probe compiled, then deleted)."
            % CETZ_VERSION)
    return True


# ---------------------------------------------------------------------------
# 5) 可选依赖
# ---------------------------------------------------------------------------
def check_optional() -> None:
    print()
    print("== 5. Optional dependencies ==")
    try:
        import PIL  # noqa: F401
        say(OK, "Pillow is installed (needed only by tools/check_overflow.py).")
    except Exception:  # noqa: BLE001
        say(WARN, "Pillow NOT found -- only tools/check_overflow.py needs it.")
        say(INFO, "  python -m pip install pillow")
        say(INFO, "  Missing Pillow does not affect PDF output.")
    if shutil.which("pdfinfo"):
        say(OK, "pdfinfo found (tools/build_book.py uses it to report the page count).")
    else:
        say(WARN, "pdfinfo NOT found -- page count will be skipped (not an error).")
        say(INFO, "  Install poppler-utils if you want the page count.")


def main() -> int:
    ap = argparse.ArgumentParser(description="Initialize the book build environment (Typst).")
    ap.add_argument("--check-only", action="store_true",
                    help="only inspect; do not create directories and do not download/compile")
    ap.add_argument("--use-system-fonts", action="store_true",
                    help="check installed OS font fallbacks and skip project font downloads")
    args = ap.parse_args()

    print("=" * 70)
    print("Book build environment (Typst)")
    print("Project root : %s" % ROOT)
    print("Book         : %s" % BOOK)
    print("Fonts        : %s" % ("installed system fallbacks" if args.use_system_fonts
                                  else FONTS))
    mode = "system fonts" if args.use_system_fonts else "project fonts"
    if args.check_only:
        mode += ", check-only"
    print("Mode         : %s" % mode)
    print("=" * 70)
    say(INFO, "This script prepares the environment. It does NOT build the book;")
    say(INFO, "run 'scons build-book' for PDF or add '--format=html' for experimental HTML.")
    say(INFO, "Tools are CHECKED only: this script never installs Typst, Python, SCons, or other tools.")
    if args.use_system_fonts:
        say(INFO, "Project font downloads are disabled (--use-system-fonts).")
    else:
        say(INFO, "Only project font data may be downloaded into book/fonts/.")
    say(INFO, "Typst may populate its normal package cache while prefetching cetz.")

    py_ok = check_python()
    if not py_ok:
        print()
        print("=" * 70)
        say(BAD, "Python 3 is required -- install it, then re-run this script.")
        return 1
    exe = check_typst()
    fonts_ok = (check_system_fonts(exe) if args.use_system_fonts
                else check_fonts(args.check_only))
    ensure_dirs(args.check_only)
    cetz_ok = prefetch_cetz(exe, args.check_only) if exe else False
    check_optional()

    print()
    print("=" * 70)
    if not exe:
        say(BAD, "Typst is missing -- install it, then re-run this script.")
        return 1
    if not fonts_ok:
        say(BAD, "Environment check finished with missing/invalid fonts.")
        return 1
    if not cetz_ok:
        say(BAD, "Environment check finished with a failed cetz prefetch.")
        return 1
    say(OK, "Environment ready.")
    build_command = "scons build-book"
    if args.use_system_fonts:
        build_command += " --use-system-fonts"
    say(INFO, "Build the book with: %s" % build_command)
    html_command = "scons build-book --format=html"
    if args.use_system_fonts:
        html_command += " --use-system-fonts"
    say(INFO, "Build experimental HTML with: %s" % html_command)
    verify_command = "scons build-book --check"
    if args.use_system_fonts:
        verify_command += " --use-system-fonts"
    say(INFO, "Full verification (slow): %s" % verify_command)
    print("=" * 70)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
