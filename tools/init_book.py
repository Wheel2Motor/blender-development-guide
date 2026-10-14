#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 初始化书籍构建环境（Typst）。

做四件事：

1. 找 Typst（PATH 或 ``tools/bin/``）、打印版本；
2. 默认把**书稿需要的字体下载进** ``book/fonts/``（该目录不入版本控制），
   并校验每个文件确实是字体、族名正确、覆盖书稿需要的字符；已存在且校验通过就
   跳过（幂等）。``--use-system-fonts`` 则只检查系统字体，不下载项目字体；
3. 建目录骨架（``book/build`` 尤其重要：Typst 不会自己创建输出目录）；
4. 预取 cetz 宏包 —— **用临时目录里的最小探针文件**，不碰书稿、不产出书稿 PDF。

用法::

    python tools/init_book.py               # 检查 + 补齐字体 + 预取 cetz
    python tools/init_book.py --use-system-fonts  # 跳过项目字体下载
    python tools/init_book.py --check-only  # 只检查，不下载、不编译
    python tools/init_book.py --force       # 忽略 manifest，重新校验/下载

**本脚本不构建书稿。** 出 PDF 是 ``tools/build_book.py`` 的职责。历史上的
init 会编译一次全书来预取 cetz，那既慢又会让"初始化"意外产生 PDF；现在改成
在临时目录里编译一个三行的探针文件（见 ``prefetch_cetz``）。

环境边界（重要）：

* **可以自动下载**（只落进工程目录，删掉可重取）：正文/代码用的字体 ->
  ``book/fonts/``；cetz 宏包 -> Typst 自己的包缓存（Typst 的常规机制）。
* **只检查、不安装**：SCons、Typst、Python 3，以及 ``pdfinfo`` / Pillow / fontTools 这些
  可选依赖。本脚本**不调用任何包管理器、不下载任何 CLI 可执行文件、不写系统目录**
  （系统字体目录、``%APPDATA%``、``/usr``、``~/.local`` 都不会被碰）。Typst 缺失时
  打印官方安装命令并以**非零退出码**结束；可选依赖缺失只提示，不影响退出码。

字体来源全部是**官方且可自由分发**的（SIL OFL，允许嵌入与再分发），
来自 ``github.com/notofonts``：

* ``18_NotoSansSC.zip``（noto-cjk，Sans2.004）-> Noto Sans SC Regular / Bold（正文中文）
* ``NotoSansMono.zip`` / 直链（notofonts.github.io）-> Noto Sans Mono Regular / Bold
  （代码里的拉丁与符号；它的 U+2500 系制表符是**半宽**，与 ASCII 等宽）
* ``13_NotoSansMonoCJKsc.zip``（noto-cjk，Sans2.004）-> Noto Sans Mono CJK SC
  Regular / Bold（代码里的中文回退；它自己的制表符是**全宽**的，首选字体命中后用不到）
* ``NotoSans.zip`` / 直链（notofonts.github.io）-> Noto Sans Regular / Bold
  （每个字体栈末尾的显式兜底，例如 U+0131）
* ``LICENSE-*.txt`` / ``OFL-*.txt`` / ``.manifest.json``（许可与校验依据，体积很小）

注意：本脚本打印到控制台的一切文字都是英文 —— Windows 控制台默认代码页是 GBK，
中文输出会乱码。注释可以保留中文。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

TYPST_RECOMMENDED = "0.15.1"   # 本工程在这一版上验证过
CETZ_VERSION = "0.3.4"         # book/figures/*.typ 与 chapters/01-architecture.typ 里 import 的版本

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK = os.path.join(ROOT, "book")
BUILD = os.path.join(BOOK, "build")
PDF = os.path.join(BUILD, "blender-development-guide.pdf")
FONTS = os.path.join(BOOK, "fonts")
MANIFEST = os.path.join(FONTS, ".manifest.json")

OK, WARN, BAD, INFO = "[ OK ]", "[WARN]", "[FAIL]", "[ .. ]"

# 字体二进制的最小合理大小（防止把错误页 / 截断下载当成字体）。
MIN_FONT_BYTES = 50 * 1024
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


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


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
# 2) 字体：规格 + 下载 + 校验
# ---------------------------------------------------------------------------
# 每个字体文件：来源、期望族名、用途。
# 来源全部是官方且可自由分发的产物（SIL OFL）。
#   * 归档类来源（noto-cjk 的 Releases，zip）：记录归档内成员路径；
#   * 直链类来源（google/fonts 仓里的可变字体）：不需要解包。
# 同一个 URL 在一个字体组里只下载一次（比如一组里若同时需要 Regular 与 Bold，
# 它们来自同一个 zip，只下载解包一次）。
FONT_GROUPS = [
    {
        "label": "Noto Sans SC (body text, sans-serif)",
        "url": "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip",
        "kind": "zip",
        "files": [
            {
                "file": "NotoSansSC-Regular.otf",
                "role": "body text (Chinese, sans-serif, regular)",
                "family": "Noto Sans SC",
                "min_bytes": 4 * 1024 * 1024,
                "member": "NotoSansSC-Regular.otf",
                "license": "SIL OFL 1.1",
            },
            {
                "file": "NotoSansSC-Bold.otf",
                "role": "body text (Chinese, sans-serif, bold)",
                "family": "Noto Sans SC",
                "min_bytes": 4 * 1024 * 1024,
                "member": "NotoSansSC-Bold.otf",
                "license": "SIL OFL 1.1",
            },
        ],
    },
    {
        # 代码用的是**两个**字体组成的字体栈（见 book/common.typ 的 font-code）：
        #   首选 Noto Sans Mono        —— 拉丁/符号；制表符是**半宽**（与 ASCII 等宽），
        #                                  所以 `├──` 正好占 3 个 ASCII 格；
        #   回退 Noto Sans Mono CJK SC —— 代码里的中文；它自己的制表符是全宽（2 格），
        #                                  但因为首选字体已经命中这些码位，不会被用到。
        # 这是"用现成字体"能达到的最小代价方案，不需要自建/派生字体。
        "label": "Noto Sans Mono (code latin and symbols)",
        "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansMono/hinted/ttf/",
        "url_pattern": "%sNotoSansMono-%s.ttf",
        "kind": "direct_multi",
        "files": [
            {
                "file": "NotoSansMono-Regular.ttf",
                "role": "code latin (monospace, regular)",
                "family": "Noto Sans Mono",
                "min_bytes": 128 * 1024,
                "url": ("https://raw.githubusercontent.com/notofonts/"
                        "notofonts.github.io/main/fonts/NotoSansMono/hinted/ttf/"
                        "NotoSansMono-Regular.ttf"),
                # 制表符与箭头必须是**半宽**（== ASCII），否则 `├──` 会占 6 格。
                "require_chars": "─│┌┐└┘├┤┬┴┼←→↓↑",
                "require_same_advance": True,
                "license": "SIL OFL 1.1",
            },
            {
                "file": "NotoSansMono-Bold.ttf",
                "role": "code latin (monospace, bold)",
                "family": "Noto Sans Mono",
                "min_bytes": 128 * 1024,
                "url": ("https://raw.githubusercontent.com/notofonts/"
                        "notofonts.github.io/main/fonts/NotoSansMono/hinted/ttf/"
                        "NotoSansMono-Bold.ttf"),
                "require_chars": "─│┌┐└┘├┤┬┴┼←→↓↑",
                "require_same_advance": True,
                "license": "SIL OFL 1.1",
            },
        ],
    },
    {
        # CJK 回退来自 noto-cjk 的独立发布归档，不能拼接到上面的
        # notofonts.github.io/NotoSansMono 直链目录。两种字体只是共同组成 font-code，
        # 下载来源与归档格式并不相同。
        "label": "Noto Sans Mono CJK SC (code CJK fallback)",
        "url": ("https://github.com/notofonts/noto-cjk/releases/download/"
                "Sans2.004/13_NotoSansMonoCJKsc.zip"),
        "kind": "zip",
        "files": [
            {
                "file": "NotoSansMonoCJKsc-Regular.otf",
                "role": "code CJK fallback (monospace, regular)",
                "family": "Noto Sans Mono CJK SC",
                "min_bytes": 4 * 1024 * 1024,
                "member": "NotoSansMonoCJKsc-Regular.otf",
                "license": "SIL OFL 1.1",
            },
            {
                "file": "NotoSansMonoCJKsc-Bold.otf",
                "role": "code CJK fallback (monospace, bold)",
                "family": "Noto Sans Mono CJK SC",
                "min_bytes": 4 * 1024 * 1024,
                "member": "NotoSansMonoCJKsc-Bold.otf",
                "license": "SIL OFL 1.1",
            },
        ],
    },
    {
        # 显式指定的最后兜底字体。存在的唯一理由是 U+0131（无点 i）：
        # Noto Sans SC 与 Noto Sans Mono 都没有这个字符，而书里有一处必须显示它
        # （11-wm-operators.typ:2021 讲土耳其语 locale 的例子）。
        # 有了它就不必依赖 Typst 内置的 Libertinus，也不会渲染成缺字方框。
        "label": "Noto Sans (explicit last-resort fallback, covers U+0131)",
        "url": "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSans/hinted/ttf/",
        "kind": "direct_multi",
        "files": [
            {
                "file": "NotoSans-Regular.ttf",
                "role": "last-resort fallback (latin, regular)",
                "family": "Noto Sans",
                "min_bytes": 256 * 1024,
                "url": ("https://raw.githubusercontent.com/notofonts/"
                        "notofonts.github.io/main/fonts/NotoSans/hinted/ttf/"
                        "NotoSans-Regular.ttf"),
                # 这个字体就是为它进来的：必须真的覆盖 U+0131。
                "require_chars": "\u0131",
                "license": "SIL OFL 1.1",
            },
            {
                "file": "NotoSans-Bold.ttf",
                "role": "last-resort fallback (latin, bold)",
                "family": "Noto Sans",
                "min_bytes": 256 * 1024,
                "url": ("https://raw.githubusercontent.com/notofonts/"
                        "notofonts.github.io/main/fonts/NotoSans/hinted/ttf/"
                        "NotoSans-Bold.ttf"),
                "require_chars": "\u0131",
                "license": "SIL OFL 1.1",
            },
            {
                "file": "OFL-NotoSans.txt",
                "role": "license text (Noto Sans)",
                "min_bytes": 1024,
                "max_bytes": 64 * 1024,
                "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/notosans/OFL.txt",
                "license_text": True,
            },
        ],
    },
    {
        "label": "license files (OFL requires keeping these)",
        "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/",
        "kind": "direct_multi",
        "files": [
            {
                "file": "OFL-NotoSansMono.txt",
                "role": "license text (Noto Sans Mono)",
                "min_bytes": 1024,
                "max_bytes": 64 * 1024,
                "url": "https://raw.githubusercontent.com/google/fonts/main/ofl/notosansmono/OFL.txt",
                "license_text": True,
            },
        ],
    },
]

FONT_SIGNATURES = (b"\x00\x01\x00\x00",   # TrueType outlines
                   b"OTTO",               # CFF outlines
                   b"true", b"ttcf")      # legacy / collection


def looks_like_font(path: str) -> bool:
    """文件头必须是字体签名 —— 防住把 HTML 错误页当成字体。"""
    try:
        with open(path, "rb") as fh:
            head = fh.read(4)
    except OSError:
        return False
    return any(head == sig for sig in FONT_SIGNATURES)


def font_family(path: str) -> str | None:
    """读字体内部族名。没有 fontTools 就返回 None（不阻断，只少一层校验）。"""
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        return None
    try:
        f = TTFont(path, lazy=True)
        name = f["name"].getDebugName(1)
        f.close()
        return name
    except Exception:  # noqa: BLE001
        return None


def font_coverage(path: str) -> set[str] | None:
    """返回字体覆盖的字符集合（用 cmap）。没有 fontTools 就返回 None。"""
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        return None
    try:
        f = TTFont(path, lazy=True)
        cov: set[str] = set()
        for table in f["cmap"].tables:
            if table.isUnicode():
                cov |= {chr(cp) for cp in table.cmap}
        f.close()
        return cov
    except Exception:  # noqa: BLE001
        return None


def non_monospaced(path: str, chars: str) -> list[tuple[str, int, int]] | None:
    """检查 chars 里每个字符的推进宽度是否与 ASCII 一致。

    返回 ``[(字符, 该字符宽度, ASCII 宽度), ...]``；没有 fontTools 返回 None。
    对**代码首选字体**（Noto Sans Mono）这是一条硬校验：它的 U+2500 系制表符必须
    与 ASCII 等宽，`├──` 才会正好占 3 个 ASCII 格。反过来，回退字体
    Noto Sans Mono CJK SC 的制表符是全宽的（2 格）—— 它不该被用到，所以我们对它
    只校验"字形存在"，不校验等宽。
    """
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        return None
    try:
        f = TTFont(path, lazy=True)
        cmap: dict[int, str] = {}
        for table in f["cmap"].tables:
            if table.isUnicode():
                cmap.update(table.cmap)
        hmtx = f["hmtx"]
        if ord("A") not in cmap:
            return None
        ascii_adv = hmtx[cmap[ord("A")]][0]
        bad: list[tuple[str, int, int]] = []
        for c in chars:
            g = cmap.get(ord(c))
            if g is None:
                continue
            adv = hmtx[g][0]
            if adv != ascii_adv:
                bad.append((c, adv, ascii_adv))
        f.close()
        return bad
    except Exception:  # noqa: BLE001
        return None


def download(url: str, dest: str, want_font: bool = False) -> bool:
    """下载到 dest。可以用 curl；否则退回 urllib。返回是否成功。

    ``want_font=True`` 时要求文件头是字体签名；无论哪种模式都拒绝 HTML ——
    直链下载最容易把 404/限流页面当成目标文件存下来，**光看大小挡不住**
    （实测：一个写错的 GitHub LICENSE 路径返回 200 + 270 KB 的 HTML 页面）。
    内容是否"够大、是不是 OFL 文本"由 verify_font_file 按 spec 判定。
    """
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
        if ok and os.path.getsize(dest) > 0 and not looks_like_html(dest):
            if not want_font or looks_like_font(dest):
                return True
            say(WARN, "downloaded file is not a font binary: %s" % url)
            ok = False
        elif ok:
            say(WARN, "downloaded file looks like HTML (wrong URL?): %s" % url)
        say(WARN, "download attempt %d/%d failed or invalid: %s"
            % (attempt, RETRIES, url))
    return False


def load_manifest() -> dict | None:
    """Load the pinned font hashes; return None when the manifest is unusable."""
    try:
        with open(MANIFEST, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        say(BAD, "Font manifest is missing: %s" % MANIFEST)
        return None
    except Exception as exc:  # noqa: BLE001
        say(BAD, "Font manifest is unreadable: %s" % exc)
        return None
    if not isinstance(data, dict):
        say(BAD, "Font manifest root must be a JSON object: %s" % MANIFEST)
        return None
    return data


def save_manifest(data: dict) -> bool:
    try:
        with open(MANIFEST, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
    except OSError as exc:
        say(BAD, "could not write %s: %s" % (MANIFEST, exc))
        return False
    return True


def looks_like_html(path: str) -> bool:
    """识别 HTML 错误页。

    为什么必须查：从 GitHub 取 LICENSE 时若路径写错，返回的是 200 + 一个
    270 KB 的 GitHub 404 HTML 页面 —— 只看大小完全挡不住（实测踩过）。
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(512).lstrip().lower()
    except OSError:
        return False
    return (head.startswith(b"<!doctype html") or head.startswith(b"<html")
            or b"<head>" in head[:200])


def verify_font_file(path: str, spec: dict, deep: bool) -> tuple[bool, str]:
    """校验单个字体文件。返回 (是否通过, 说明)。deep=False 时跳过耗时的字符集检查。"""
    if not os.path.isfile(path):
        return False, "missing"
    size = os.path.getsize(path)
    if size < spec.get("min_bytes", MIN_FONT_BYTES):
        return False, "too small (%d bytes) -- likely an error page" % size
    if spec.get("max_bytes") and size > spec["max_bytes"]:
        return False, ("too large (%d bytes, expected <= %d) -- likely an HTML page"
                       % (size, spec["max_bytes"]))
    if looks_like_html(path):
        return False, "content is HTML, not the expected file"

    if spec.get("license_text"):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as exc:
            return False, "unreadable: %s" % exc
        if "SIL OPEN FONT LICENSE" not in text:
            return False, "does not contain the SIL OFL text"
        return True, "%d bytes of OFL text" % size

    if not looks_like_font(path):
        return False, "not a font binary (bad magic) -- likely an HTML error page"

    fam = font_family(path)
    if fam is None:
        return True, "%d bytes (fontTools unavailable: family not checked)" % size
    want = spec.get("family")
    if want and fam.strip() != want:
        return False, "internal family is %r, expected %r" % (fam, want)

    if deep and spec.get("require_chars"):
        cov = font_coverage(path)
        if cov is not None:
            missing = [c for c in spec["require_chars"] if c not in cov]
            if missing:
                return False, "missing required glyphs: %s" % "".join(missing)
        if spec.get("require_same_advance"):
            bad = non_monospaced(path, spec["require_chars"])
            if bad:
                return False, ("box-drawing/arrow glyphs are NOT the same advance "
                               "as ASCII: %s" % bad)
    return True, "%d bytes, family=%s" % (size, fam)


def fetch_group(group: dict, workdir: str, wanted: list[dict]) -> dict[str, bool]:
    """下载一组字体来源，并解出 wanted 里的成员。

    返回 ``{文件名: 是否成功}``。同一 URL 只下载一次。
    """
    url = group["url"]
    say(INFO, "  fetching %s" % url)

    if group["kind"] == "direct":
        dest = os.path.join(workdir, wanted[0]["file"])
        if not download(url, dest, want_font=True):
            say(BAD, "  download FAILED: %s" % url)
            return {w["file"]: False for w in wanted}
        return {w["file"]: True for w in wanted}

    if group["kind"] == "direct_multi":
        # 多个直链文件（拉丁等宽字体、许可文本），逐个下到各自 URL。
        result: dict[str, bool] = {}
        for spec in wanted:
            dest = os.path.join(workdir, spec["file"])
            this_url = spec.get("url") or url + spec["file"]
            want_font = not spec.get("license_text")
            if download(this_url, dest, want_font=want_font):
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
    say(INFO, "  archive sha256: %s" % sha256(archive))

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


def check_fonts(check_only: bool, force: bool, heading: str | None = None) -> bool:
    print()
    print(heading or
          "== 2. Fonts (all shipped in book/fonts/; build uses --ignore-system-fonts) ==")
    say(INFO, "Font dir: %s" % FONTS)
    if not os.path.isdir(FONTS):
        if check_only:
            say(BAD, "Font directory is missing (--check-only does not create it).")
            return False
        os.makedirs(FONTS, exist_ok=True)

    manifest = {} if force else load_manifest()
    if manifest is None:
        say(BAD, "Cannot verify or download fonts without the pinned manifest.")
        return False

    specs = [spec for group in FONT_GROUPS for spec in group["files"]]
    if not force:
        missing_entries = [spec["file"] for spec in specs
                           if not manifest.get(spec["file"], {}).get("sha256")]
        if missing_entries:
            say(BAD, "Font manifest has no pinned sha256 for:")
            for name in missing_entries:
                say(INFO, "  %s" % name)
            say(INFO, "A maintainer must review the source and regenerate the manifest with")
            say(INFO, "'python tools/init_book.py --force'; the build will not trust new data.")
            return False
    try:
        import fontTools  # noqa: F401
    except ImportError:
        say(INFO, "fontTools is unavailable; family/glyph inspection is skipped, but the")
        say(INFO, "pinned SHA-256 check still verifies the exact reviewed font files.")

    ok_all = True
    font_suffixes = (".ttf", ".otf", ".ttc", ".otc")
    expected_fonts = {spec["file"] for spec in specs
                      if spec["file"].lower().endswith(font_suffixes)}
    actual_fonts = {name for name in os.listdir(FONTS)
                    if name.lower().endswith(font_suffixes)}
    extra_fonts = sorted(actual_fonts - expected_fonts)
    if extra_fonts:
        say(BAD, "Unmanaged font files would make fallback behavior non-reproducible:")
        for name in extra_fonts:
            say(INFO, "  %s" % name)
        say(INFO, "Move them outside book/fonts/; init-book never deletes user files.")
        ok_all = False

    def verify_and_record(spec: dict, failure_tag: str = BAD,
                          path: str | None = None) -> bool:
        """校验一个字体文件，并把 sha256 记进 manifest。"""
        actual_path = path or os.path.join(FONTS, spec["file"])
        good, why = verify_font_file(actual_path, spec, deep=True)
        recorded = manifest.get(spec["file"], {}).get("sha256")
        if good:
            digest = sha256(actual_path)          # 大文件只读一次
            if recorded and digest != recorded:
                good, why = False, "sha256 differs from the recorded manifest"
            else:
                manifest.setdefault(spec["file"], {})["sha256"] = digest
        if good:
            say(OK, "  verified: %s" % why)
        else:
            say(failure_tag, "  %s" % why)
        return good

    for group in FONT_GROUPS:
        say(INFO, "%s" % group["label"])
        need: list[dict] = []
        for spec in group["files"]:
            path = os.path.join(FONTS, spec["file"])
            failure_tag = BAD if check_only else WARN
            if os.path.isfile(path) and verify_and_record(spec, failure_tag=failure_tag):
                continue
            need.append(spec)

        if not need:
            continue
        if check_only:
            for spec in need:
                say(BAD, "  %s missing/invalid (--check-only does not download)"
                    % spec["file"])
            say(INFO, "  source: %s" % group["url"])
            say(INFO, "  re-run without --check-only to fetch it.")
            ok_all = False
            continue

        say(INFO, "  need %d file(s); downloading the pinned official release"
            % len(need))
        with tempfile.TemporaryDirectory(prefix="dsh-fonts-") as workdir:
            fetched = fetch_group(group, workdir, need)
            for spec in need:
                if not fetched.get(spec["file"]):
                    ok_all = False
                    continue
                candidate = os.path.join(workdir, spec["file"])
                if not verify_and_record(spec, path=candidate):
                    say(BAD, "  downloaded candidate rejected; existing file was not changed")
                    ok_all = False
                    continue
                dest = os.path.join(FONTS, spec["file"])
                try:
                    os.replace(candidate, dest)
                except OSError as exc:
                    say(BAD, "  could not install %s: %s" % (spec["file"], exc))
                    ok_all = False
                    continue
                manifest.setdefault(spec["file"], {})["source"] = group["url"]
                if "member" in spec:
                    manifest[spec["file"]]["member"] = spec["member"]
                say(OK, "  installed atomically -> %s" % spec["file"])

    # 派生产物（自建并合字体）已不再是方案的一部分：代码字体就是
    # Noto Sans Mono CJK SC 本身，一个字体里同时有等宽拉丁、等宽中文与制表符。

    if ok_all and not check_only and not save_manifest(manifest):
        ok_all = False
    if ok_all:
        say(OK, "Font check passed: the book builds without any system font.")
    else:
        say(BAD, "Font check FAILED -- the build would fall back or miss glyphs.")
    say(INFO, "Every font family is SIL OFL, so the PDF may be redistributed freely.")
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
    try:
        import fontTools  # noqa: F401
        say(OK, "fontTools is installed (used to verify the shipped fonts).")
    except Exception:  # noqa: BLE001
        say(WARN, "fontTools NOT found -- font family/glyph checks are reduced.")
        say(INFO, "  python -m pip install fonttools")
    if shutil.which("pdfinfo"):
        say(OK, "pdfinfo found (tools/build_book.py uses it to report the page count).")
    else:
        say(WARN, "pdfinfo NOT found -- page count will be skipped (not an error).")
        say(INFO, "  Install poppler-utils if you want the page count.")


def main() -> int:
    ap = argparse.ArgumentParser(description="Initialize the book build environment (Typst).")
    ap.add_argument("--check-only", action="store_true",
                    help="only inspect; do not create directories and do not download/compile")
    ap.add_argument("--force", action="store_true",
                    help="ignore the font manifest and re-verify every font file")
    ap.add_argument("--use-system-fonts", action="store_true",
                    help="check installed OS font fallbacks and skip project font downloads")
    args = ap.parse_args()

    if args.force and args.use_system_fonts:
        ap.error("--force and --use-system-fonts are mutually exclusive")

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
    say(INFO, "run 'scons build-book' for the PDF.")
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
                else check_fonts(args.check_only, args.force))
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
    verify_command = "scons build-book --check"
    if args.use_system_fonts:
        verify_command += " --use-system-fonts"
    say(INFO, "Full verification (slow): %s" % verify_command)
    print("=" * 70)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
