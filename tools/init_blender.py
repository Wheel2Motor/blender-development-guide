#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 初始化 Blender 源码与开发环境。

做四件事：

1. 把 Blender 源码克隆到基准 commit（``blender/`` 不存在时）；
2. 仅在上游要求“构建前额外准备”时取对应平台的预编译库子模块；
   Windows 的 ``make.bat`` 会自行检测并询问下载，因此初始化脚本不重复实现；
3. 探测开发工具链并打印版本，与书里第 2 章的门槛对照给出 PASS / FAIL；
4. 打印调用 ``scons build-blender`` 的下一步命令
   （**不真的构建**）。

环境边界（重要）：

* **可以自动获取**（只落进工程目录，删掉可重取）：Blender 源码 -> ``blender/``，
  预编译库 -> ``blender/lib/<平台>_<架构>``。
* **只检查、不安装**：git / git-lfs / cmake / ninja / 编译器（Windows 仅 MSVC，
  macOS/Linux 为 GCC 或 Clang）/ Python 3。本脚本**不调用任何包管理器、不下载任何
  CLI 可执行文件、不写
  系统目录**；必需项缺失或低于门槛时打印官方安装命令，并以**非零退出码**结束。
  可选项（git-lfs、ninja、Windows 上的 gcc）只提示，不影响退出码。

用法::

    python tools/init_blender.py                # 缺了就克隆，然后检查
    python tools/init_blender.py --check-only   # 只检查，不克隆不下库（缺必需项则非零退出）
    python tools/init_blender.py --src DIR      # 指定源码目录（默认 ./blender）

设计原则：**只增不删、不擅自改用户工作区**。已经存在的源码目录只会被核对与告警，
不会被 checkout / reset。

注意：本脚本打印到控制台的一切文字都是英文 —— Windows 控制台默认代码页是 GBK，
中文输出会乱码。注释可以保留中文。
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from blender_baseline import BLENDER_BRANCH, BLENDER_COMMIT, BLENDER_VERSION

BLENDER_REPO = "https://projects.blender.org/blender/blender.git"
# 全书带 `文件:行号` 的源码引用都钉在上面的 commit 上；换版本可能对不上。
# 当前引用数量由 qa/check_source_refs.py 在运行时统计，不在仓库里保存快照。

# 书里第 2 章的门槛。没有出处的数字一个都不要写进来。
CMAKE_MIN = "3.21"          # book/chapters/02-build-environment.typ（CMakeLists.txt:29）
GCC_MIN = "14.0"            # 同上（CMakeLists.txt:107-133）
CLANG_MIN = "17.0"          # 同上
MSVC_TOOLSET_MIN = "19.44.35216"  # build_files/cmake/platform/platform_win32.cmake:42

# 由 ensure_libs() 设置的"当前状态"，供 check_tools() 判断 git-lfs 是必需还是用不到：
#   * LFS_NEEDED 非 None -> 需要拉取/还原 lib/，此时缺 git-lfs 就是 [FAIL]；
#   * UPSTREAM_LIB_HANDLING -> 是否把平台库交给 Blender 上游构建脚本管理；
#   * 两者均未设 -> lib/ 已是还原好的实体文件，缺 git-lfs 只 [WARN]。
LFS_NEEDED: str | None = None
# Windows make.bat 自己管理平台库；用独立状态避免把"委托上游"误报为
# "lib/ 已经还原"。
UPSTREAM_LIB_HANDLING = False
# 由 check_tools() 设置：ninja 是否在位（初始化报告仍会说明推荐后端是否可用）。
NINJA_PRESENT = False
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OK, WARN, BAD, INFO = "[ OK ]", "[WARN]", "[FAIL]", "[ .. ]"

# Windows 控制台默认 GBK：显式把 stdout/stderr 切到 UTF-8，避免工具输出里的
# 非 ASCII 字符（编译器路径、上游报错）把脚本自己搞崩。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def say(tag: str, msg: str) -> None:
    print("%s %s" % (tag, msg), flush=True)


def run(cmd: list[str], cwd: str | None = None) -> subprocess.CompletedProcess:
    """跑一个外部命令，捕获输出（永不抛异常）。

    输出先落到临时文件再读回，而不是用 PIPE：某些受约束的运行环境禁止子进程
    使用匿名管道，临时文件这条路在所有平台上都稳。
    """
    handle = tempfile.TemporaryFile()
    try:
        try:
            cp = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=handle, stderr=subprocess.STDOUT, timeout=900)
            rc = cp.returncode
        except Exception as exc:  # noqa: BLE001
            rc = 127
            handle.write(("%s" % exc).encode("utf-8", "replace"))
        handle.seek(0)
        return subprocess.CompletedProcess(cmd, rc, handle.read())
    finally:
        handle.close()


def command_text(cmd: list[str]) -> str:
    """Return a copy-pasteable command for progress and error messages."""
    if os.name == "nt":
        return subprocess.list2cmdline(cmd)
    return shlex.join(cmd)


def run_live(cmd: list[str], description: str,
             cwd: str | None = None) -> subprocess.CompletedProcess:
    """Run a long command with its output attached to the current terminal.

    Clone, fetch, submodule, and Git LFS operations must not use ``run()``:
    captured output makes a large download look frozen. Git writes its progress
    meter to stderr, so inheriting both standard streams also preserves the
    interactive progress display in the BAT/SH terminal.
    """
    say(INFO, "%s ..." % description)
    say(INFO, "Command: %s" % command_text(cmd))
    sys.stdout.flush()
    sys.stderr.flush()
    started = time.monotonic()
    try:
        cp = subprocess.run(cmd, cwd=cwd)
    except KeyboardInterrupt:
        elapsed = time.monotonic() - started
        say(BAD, "%s interrupted after %.1f s." % (description, elapsed))
        return subprocess.CompletedProcess(cmd, 130)
    except Exception as exc:  # noqa: BLE001
        elapsed = time.monotonic() - started
        say(BAD, "%s could not start after %.1f s: %s"
            % (description, elapsed, exc))
        return subprocess.CompletedProcess(cmd, 127)

    elapsed = time.monotonic() - started
    if cp.returncode == 0:
        say(OK, "%s completed in %.1f s (exit code 0)." % (description, elapsed))
    else:
        say(BAD, "%s failed after %.1f s (exit code %d)."
            % (description, elapsed, cp.returncode))
    return cp


def text_of(cp: subprocess.CompletedProcess) -> str:
    out = cp.stdout or b""
    if isinstance(out, str):
        return out
    return out.decode("utf-8", errors="replace")


def first_line(s: str) -> str:
    for line in s.splitlines():
        line = line.strip()
        if line:
            return line
    return ""


def probe_version(cmd: list[str]) -> str | None:
    """跑 ``cmd``，从输出里挑一个像版本号的东西返回；找不到就返回首行。"""
    cp = run(cmd)
    if cp.returncode != 0:
        return None
    out = text_of(cp)
    m = re.search(r"\d+\.\d+(?:\.\d+)*", out)
    if m:
        return m.group(0)
    return first_line(out) or None


def ver_tuple(s: str) -> tuple[int, ...]:
    parts: list[int] = []
    for p in re.findall(r"\d+", s):
        parts.append(int(p))
    return tuple(parts) if parts else (0,)


def cmp_ver(have: str, want: str) -> int:
    a, b = ver_tuple(have), ver_tuple(want)
    n = max(len(a), len(b))
    a = a + (0,) * (n - len(a))
    b = b + (0,) * (n - len(b))
    return (a > b) - (a < b)


def tool_path(name: str) -> str | None:
    return shutil.which(name)


# ---------------------------------------------------------------------------
# 平台：预编译库子模块的名字
# ---------------------------------------------------------------------------
def lib_submodule(system: str, machine: str) -> list[str]:
    """返回候选的 ``lib/`` 子模块名，按可能性排序。

    注意：**没有 macos_x64** —— 上游只提供 macOS arm64 的预编译库，
    Intel Mac 走 ``build_files/build_environment`` 自己编译依赖。
    """
    m = machine.lower()
    if system == "Windows":
        if m in ("arm64", "aarch64"):
            return ["windows_arm64", "windows_x64"]
        return ["windows_x64"]
    if system == "Darwin":
        if m in ("arm64", "aarch64"):
            return ["macos_arm64"]
        return []  # 没有 macos_x64（上游未提供）
    if m in ("arm64", "aarch64"):
        return ["linux_arm64", "linux_x64"]
    return ["linux_x64"]


# ---------------------------------------------------------------------------
# git 小工具
# ---------------------------------------------------------------------------
def git(src: str, *args: str) -> subprocess.CompletedProcess:
    return run(["git", "-C", src, *args])


def head_commit(src: str) -> str | None:
    cp = git(src, "rev-parse", "HEAD")
    if cp.returncode != 0:
        return None
    return first_line(text_of(cp)) or None


def dir_has_content(path: str) -> bool:
    try:
        return any(True for _ in os.scandir(path))
    except OSError:
        return False


def lfs_pointer_files(path: str, limit: int = 400) -> list[str]:
    """找出目录里还是 LFS 指针（未被还原）的文件。

    Git LFS 没拉下来时，文件内容是文本指针，首行形如
    ``version https://git-lfs.github.com/spec/v1``。只抽样看小文件。
    """
    hits: list[str] = []
    seen = 0
    for base, _dirs, files in os.walk(path):
        for name in files:
            seen += 1
            if seen > limit:
                return hits
            p = os.path.join(base, name)
            try:
                if os.path.getsize(p) > 512:
                    continue
                with open(p, "rb") as f:
                    head = f.read(120)
            except OSError:
                continue
            if head.startswith(b"version https://git-lfs"):
                hits.append(os.path.relpath(p, path))
                if len(hits) >= 5:
                    return hits
    return hits


# ---------------------------------------------------------------------------
# 1) 克隆 / 核对源码
# ---------------------------------------------------------------------------
def ensure_source(src: str, check_only: bool) -> bool:
    """克隆/核对源码。返回"是否可用"（缺失、克隆失败、无法核对 -> False）。"""
    print()
    print("== 1. Blender source ==")
    if os.path.isdir(os.path.join(src, ".git")):
        head = head_commit(src)
        if head is None:
            if not tool_path("git"):
                say(BAD, "Found %s, but git is not on PATH so HEAD cannot be read." % src)
                say(INFO, "Install git first -- section 3 below prints the official install")
                say(INFO, "commands for your platform. This script never installs it for you.")
            else:
                say(BAD, "Found %s but 'git rev-parse HEAD' failed." % src)
                say(INFO, "The directory does not look like a usable git checkout;")
                say(INFO, "delete it and re-run this script to clone a fresh one.")
            return False
        if head == BLENDER_COMMIT:
            say(OK, "Source is at the baseline commit %s." % BLENDER_COMMIT)
        else:
            say(WARN, "Source HEAD is %s, baseline is %s." % (head, BLENDER_COMMIT))
            say(WARN, "This is a WARNING, not a failure: you may have deliberately checked")
            say(INFO, "           out a different version, and this script will NOT touch")
            say(INFO, "           your working tree. But note the consequence: the book's")
            say(INFO, "           file:line source references are pinned to %s,"
                % BLENDER_COMMIT[:12])
            say(INFO, "           so line numbers and symbols may not match on another version.")
            say(INFO, "           To align it (checking for local changes first):")
            say(INFO, "  git -C \"%s\" status" % src)
            say(INFO, "  git -C \"%s\" fetch --progress --depth 1 origin %s"
                % (src, BLENDER_COMMIT))
            say(INFO, "  git -C \"%s\" checkout %s" % (src, BLENDER_COMMIT))
        return True

    if os.path.isdir(src):
        say(BAD, "%s exists but is not a git repository; cannot verify the baseline." % src)
        say(INFO, "Move it aside and re-run this script to clone a fresh checkout.")
        return False

    if check_only:
        say(BAD, "%s does not exist (--check-only does not clone)." % src)
        say(INFO, "Run without --check-only to clone it (large download, takes a while).")
        return False

    if not tool_path("git"):
        say(BAD, "git not found on PATH; cannot clone Blender source.")
        say(INFO, "Install git first -- section 3 below prints the official install")
        say(INFO, "commands for your platform. This script never installs it for you.")
        return False

    say(INFO, "The source repository is large. Git will print transfer progress below.")
    cp = run_live(
        ["git", "clone", "--progress", "--branch", BLENDER_BRANCH,
         BLENDER_REPO, src],
        "Clone Blender source (branch %s)" % BLENDER_BRANCH,
    )
    if cp.returncode != 0:
        say(INFO, "Git printed the error above. A partial directory may remain at %s." % src)
        say(INFO, "Move or remove that partial directory before retrying; this script will")
        say(INFO, "not delete it automatically.")
        return False

    head = head_commit(src)
    if head == BLENDER_COMMIT:
        say(OK, "Cloned and already at the baseline commit %s." % BLENDER_COMMIT)
        return True

    say(INFO, "Branch tip is %s; fetching baseline commit %s ..."
        % ((head or "?")[:12], BLENDER_COMMIT[:12]))
    cp = run_live(
        ["git", "-C", src, "fetch", "--progress", "--depth", "1",
         "origin", BLENDER_COMMIT],
        "Fetch baseline commit %s" % BLENDER_COMMIT[:12],
    )
    if cp.returncode != 0:
        say(INFO, "The clone succeeded, but the baseline commit could not be fetched.")
        say(INFO, "The checkout was left untouched so you can inspect or retry it safely.")
        return False

    cp = run_live(
        ["git", "-C", src, "checkout", "--progress", BLENDER_COMMIT],
        "Check out baseline commit %s" % BLENDER_COMMIT[:12],
    )
    if cp.returncode != 0:
        say(INFO, "The fetch succeeded, but checkout failed; Git printed the reason above.")
        return False
    head = head_commit(src)
    if head == BLENDER_COMMIT:
        say(OK, "Checked out the baseline commit %s." % BLENDER_COMMIT)
        return True
    say(BAD, "Could not check out the baseline commit (HEAD=%s)." % (head or "?"))
    say(INFO, "Upstream may have rolled the branch; fetch the commit manually:")
    say(INFO, "  git -C \"%s\" fetch origin %s" % (src, BLENDER_COMMIT))
    return False


# ---------------------------------------------------------------------------
# 2) 预编译库子模块
# ---------------------------------------------------------------------------
def ensure_libs(src: str, check_only: bool) -> bool:
    """取/核对 ``lib/`` 子模块。返回"是否可用"（缺失、为空、仍是 LFS 指针 -> False）。

    副作用：需要拉取/还原 ``lib/`` 时把模块级 ``LFS_NEEDED`` 设成原因字符串，
    这样 ``check_tools()`` 才知道缺 git-lfs 到底是 [FAIL] 还是当前用不到。
    """
    global LFS_NEEDED, UPSTREAM_LIB_HANDLING
    print()
    print("== 2. Precompiled libraries (lib/ submodule) ==")
    system, machine = platform.system(), platform.machine()
    cands = lib_submodule(system, machine)
    if not os.path.isdir(os.path.join(src, ".git")):
        if cands:
            LFS_NEEDED = "the source checkout and lib/%s still need to be fetched" % cands[0]
        say(BAD, "Skipped: no git repository at %s (see section 1)." % src)
        return False

    say(INFO, "Platform: %s / %s" % (system, machine))

    if system == "Windows":
        UPSTREAM_LIB_HANDLING = True
        say(OK, "Dependency preparation is delegated to Blender's upstream make.bat.")
        say(INFO, "If the platform libraries are missing, make.bat will detect them and")
        say(INFO, "offer its native download flow during project generation/build.")
        say(INFO, "init-blender does not duplicate that upstream behavior.")
        return True

    if not cands:
        say(WARN, "Upstream ships no precompiled libs for %s/%s (there is no macos_x64)."
            % (system, machine))
        say(INFO, "Build the dependencies yourself with build_files/build_environment/.")
        say(INFO, "This is an upstream limitation (upstream simply does not ship libs for")
        say(INFO, "this platform), NOT a missing tool on your side -- not a failure.")
        return True

    name = cands[0]
    lib_path = os.path.join(src, "lib", name)
    if len(cands) > 1:
        say(INFO, "Preferred submodule: lib/%s (fallback: %s)"
            % (name, ", ".join("lib/" + c for c in cands[1:])))

    # 取一次 submodule 状态，用来判断是否已初始化
    cp = git(src, "submodule", "status", "lib/" + name)
    status_line = first_line(text_of(cp)) if cp.returncode == 0 else ""
    if status_line:
        say(INFO, "submodule status: %s" % status_line)

    if dir_has_content(lib_path):
        say(OK, "lib/%s exists and is not empty." % name)
        ptrs = lfs_pointer_files(lib_path)
        if ptrs:
            LFS_NEEDED = ("lib/%s still contains un-restored Git LFS pointer files" % name)
            can_restore = not check_only and bool(tool_path("git-lfs"))
            say(WARN if can_restore else BAD,
                "Git LFS files are still pointers (content NOT downloaded):")
            for p in ptrs:
                say(INFO, "  %s" % p)
            if not can_restore:
                say(INFO, "Fix: git -C \"%s\" lfs pull, or re-run this script."
                    % lib_path)
                say(INFO, "That needs git-lfs (see section 3); this script never installs it.")
                return False
            say(INFO, "Normal mode will now restore the missing Git LFS content.")
            cp = run_live(
                ["git", "-C", lib_path, "lfs", "pull"],
                "Restore Git LFS files for lib/%s" % name,
            )
            if cp.returncode != 0:
                return False
            ptrs = lfs_pointer_files(lib_path)
            if ptrs:
                say(BAD, "Git LFS pointer files remain after 'git lfs pull'.")
                return False
            say(OK, "Git LFS files for lib/%s are materialized." % name)
            return True
        say(OK, "No Git LFS pointer files found in the sample scanned.")
        say(INFO, "If a build fails with missing libs, check the first line of any file:")
        say(INFO, "  a materialized file is binary; an LFS pointer starts with")
        say(INFO, "  'version https://git-lfs...' -> the content was never downloaded.")
        return True

    LFS_NEEDED = "lib/%s must still be fetched (it is a Git LFS submodule)" % name

    if check_only:
        say(BAD, "lib/%s is missing or empty (--check-only does not download it)." % name)
        say(INFO, "Run: git -C \"%s\" submodule update --init --progress -- lib/%s"
            % (src, name))
        return False

    if not tool_path("git"):
        say(BAD, "git not found on PATH; cannot fetch the lib submodule.")
        say(INFO, "Install git first -- section 3 below prints the official install")
        say(INFO, "commands for your platform. This script never installs it for you.")
        return False

    if not tool_path("git-lfs"):
        say(BAD, "git-lfs not found on PATH, and lib/%s is a Git LFS submodule." % name)
        say(INFO, "Without git-lfs the submodule materializes as LFS pointer files and")
        say(INFO, "the Blender build fails with missing libs. Install git-lfs, then re-run.")
        say(INFO, "Install commands are printed in section 3 below; this script never")
        say(INFO, "installs tools for you.")
        return False

    cp = run_live(
        ["git", "-C", src, "submodule", "update", "--init", "--progress",
         "--", "lib/" + name],
        "Fetch submodule lib/%s (Git LFS; large)" % name,
    )
    if cp.returncode != 0:
        say(INFO, "Git printed the submodule or Git LFS error above.")
        return False

    if dir_has_content(lib_path):
        say(OK, "lib/%s fetched and is not empty." % name)
        ptrs = lfs_pointer_files(lib_path)
        if ptrs:
            LFS_NEEDED = ("lib/%s still contains un-restored Git LFS pointer files" % name)
            say(WARN, "Git LFS files are still pointers after submodule checkout:")
            for p in ptrs:
                say(INFO, "  %s" % p)
            cp = run_live(
                ["git", "-C", lib_path, "lfs", "pull"],
                "Restore Git LFS files for lib/%s" % name,
            )
            if cp.returncode != 0:
                return False
            ptrs = lfs_pointer_files(lib_path)
            if ptrs:
                say(BAD, "Git LFS pointer files remain after 'git lfs pull'.")
                return False
            say(OK, "Git LFS files for lib/%s are materialized." % name)
        else:
            say(OK, "No Git LFS pointer files found in the sample scanned.")
        say(INFO, "An LFS pointer file starts with 'version https://git-lfs...' -- if you see")
        say(INFO, "that as the first line of a library file, its real content is missing.")
        return True

    say(BAD, "lib/%s is still empty after the submodule update." % name)
    say(INFO, "Check that .gitmodules has not been edited and that git-lfs is installed.")
    return False


# ---------------------------------------------------------------------------
# 3) 开发工具链探测
# ---------------------------------------------------------------------------
def probe_exe_file_version(exe: str) -> str | None:
    """读 Windows PE 文件的版本资源。

    MSVC 的工具集目录名（例如 ``14.44.35207``）**不是** CMake 拿来比对的
    ``CMAKE_CXX_COMPILER_VERSION``；cl.exe 的版本资源才是。所以这里直接读文件版本。
    """
    ps = tool_path("powershell") or tool_path("pwsh")
    if not ps:
        return None
    cmd = ("$ErrorActionPreference='SilentlyContinue';"
           "(Get-Item -LiteralPath '%s').VersionInfo.FileVersion" % exe.replace("'", "''"))
    cp = run([ps, "-NoProfile", "-NonInteractive", "-Command", cmd])
    if cp.returncode != 0:
        return None
    m = re.search(r"\d+\.\d+\.\d+(?:\.\d+)?", text_of(cp))
    return m.group(0) if m else None


def find_msvc_toolset() -> str | None:
    """尽力找出 MSVC 工具集版本（形如 19.44.35216）。

    Windows 上只有 cl.exe 的版本号能与 CMake 的门槛直接比较。依次尝试：
    PATH 上的 cl.exe、vswhere 报出的 VS 安装目录下的 cl.exe。
    """
    cl = tool_path("cl")
    if cl:
        v = probe_cl_version(cl)
        if v:
            return v

    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    vswhere = os.path.join(pf86, "Microsoft Visual Studio", "Installer", "vswhere.exe")
    if not os.path.isfile(vswhere):
        return None
    cp = run([vswhere, "-latest", "-products", "*",
              "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
              "-property", "installationPath"])
    install = first_line(text_of(cp))
    if not install or not os.path.isdir(install):
        return None
    tools = os.path.join(install, "VC", "Tools", "MSVC")
    if os.path.isdir(tools):
        # 目录名按字典序不一定等于版本序，先按数值排序挑最新的
        names = sorted(os.listdir(tools), key=ver_tuple, reverse=True)
        for name in names:
            candidate = os.path.join(tools, name, "bin", "Hostx64", "x64", "cl.exe")
            if os.path.isfile(candidate):
                v = probe_exe_file_version(candidate)
                if v:
                    return v
        if names:
            # 退一步：至少给出工具集目录名。**它不是 CMake 拿来比对的
            # CMAKE_CXX_COMPILER_VERSION**（见上面的注释），所以用 "~" 前缀标记
            # "不可直接与门槛比较"，调用方会把它降级成 WARN 而不是 PASS/FAIL。
            return "~" + first_line(names[0])
    return None


def probe_cl_version(cl: str) -> str | None:
    """跑 ``cl`` 拿版本。cl 在无输入时返回非零，所以不看 returncode。"""
    cp = run([cl])
    out = text_of(cp)
    m = re.search(r"Version\s+(\d+\.\d+\.\d+(?:\.\d+)?)", out)
    if m:
        return m.group(1)
    m = re.search(r"(\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else None


def install_hint(tool: str, lines: list[str]) -> None:
    """打印某个工具的官方安装方式（英文，可直接复制粘贴）。

    边界原则：**本脚本只检查、不安装**。它不调用任何包管理器，也不下载
    CLI 可执行文件；装工具是使用者的环境，不是这个工程的职责。
    """
    say(INFO, "  '%s' is NOT installed by this script -- install it yourself:" % tool)
    for line in lines:
        say(INFO, "    %s" % line)


def check_python() -> bool:
    """报告解释器版本。**不自造门槛** —— 有明确要求的版本以第 2 章为准。"""
    ver = platform.python_version()
    if sys.version_info[0] == 3:
        say(OK, "python   : %s  (%s)" % (ver, sys.executable))
        say(INFO, "           no minimum is asserted here -- chapter 2 is the reference")
        say(INFO, "           for the required Python version.")
        return True
    say(BAD, "python   : %s  (this project needs Python 3)" % ver)
    install_hint("Python 3", [
        "Windows : winget install --id Python.Python.3.12   (tick 'Add to PATH')",
        "macOS   : brew install python",
        "Linux   : sudo apt install python3   # Debian/Ubuntu (dnf/pacman likewise)",
        "any OS  : https://www.python.org/downloads/",
    ])
    return False


def check_tools() -> bool:
    """探测开发工具链。**只检查，不安装，不下载任何可执行文件。**

    返回值：所有*必需*项是否都满足。必需项缺失或低于门槛时 ``main()`` 会非零退出；
    可选项（git-lfs、ninja、gcc-on-Windows 等）只提示，不影响退出码。
    """
    print()
    print("== 3. Development toolchain ==")
    say(INFO, "This script only CHECKS these tools -- it never installs or downloads them.")
    say(INFO, "Thresholds below come from book/chapters/02-build-environment.typ and")
    say(INFO, "blender/build_files/cmake/platform/platform_win32.cmake. When in doubt,")
    say(INFO, "chapter 2 is the reference -- this script only reports what it can probe.")

    required_ok = True
    if not check_python():
        required_ok = False

    # git（必需）
    git_exe = tool_path("git")
    if git_exe:
        say(OK, "git      : %s  (%s)" % (probe_version(["git", "--version"]) or "?", git_exe))
    else:
        say(BAD, "git      : NOT FOUND on PATH (required).")
        install_hint("git", [
            "Windows : winget install --id Git.Git",
            "macOS   : brew install git",
            "Linux   : sudo apt install git      # Debian/Ubuntu",
            "          sudo dnf install git      # Fedora",
            "any OS  : https://git-scm.com/downloads",
        ])
        required_ok = False

    # git-lfs：**需要拉取/还原 lib/ 时是必需项**（lib/ 是 Git LFS 子模块，没有它
    # 只会拿到指针文件，构建必然缺库）；lib/ 已经是还原好的实体文件时用不到它。
    lfs_exe = tool_path("git-lfs")
    if lfs_exe:
        if LFS_NEEDED:
            lfs_reason = "required to fetch/restore lib/"
        elif UPSTREAM_LIB_HANDLING:
            lfs_reason = "available for Blender's upstream dependency flow"
        else:
            lfs_reason = "not needed right now: lib/ is already materialized"
        say(OK, "git-lfs  : %s  (%s)" % (
            probe_version(["git-lfs", "version"]) or "?",
            lfs_reason))
    elif LFS_NEEDED:
        say(BAD, "git-lfs  : NOT FOUND on PATH (required): %s." % LFS_NEEDED)
        say(INFO, "           A Git LFS submodule without git-lfs materializes as pointer")
        say(INFO, "           files, so the Blender build fails with missing libraries.")
        install_hint("git-lfs", [
            "Windows : winget install --id GitHub.GitLFS",
            "macOS   : brew install git-lfs   (then: git lfs install)",
            "Linux   : sudo apt install git-lfs   (then: git lfs install)",
            "any OS  : https://git-lfs.com/",
        ])
        required_ok = False
    elif UPSTREAM_LIB_HANDLING:
        say(WARN, "git-lfs  : NOT FOUND (Blender's upstream dependency flow may need it).")
        say(INFO, "           init-blender leaves that dependency handling to make.bat.")
        install_hint("git-lfs", [
            "Windows : winget install --id GitHub.GitLFS",
            "any OS  : https://git-lfs.com/",
        ])
    else:
        say(WARN, "git-lfs  : NOT FOUND (not needed right now -- lib/ is already materialized).")
        install_hint("git-lfs", [
            "Windows : winget install --id GitHub.GitLFS",
            "macOS   : brew install git-lfs   (then: git lfs install)",
            "Linux   : sudo apt install git-lfs   (then: git lfs install)",
            "any OS  : https://git-lfs.com/",
        ])

    # cmake（必需，>= 3.21）
    cm = probe_version(["cmake", "--version"]) if tool_path("cmake") else None
    if cm:
        if cmp_ver(cm, CMAKE_MIN) >= 0:
            say(OK, "cmake    : %s  (>= %s required)" % (cm, CMAKE_MIN))
        else:
            say(BAD, "cmake    : %s  (below the required %s)" % (cm, CMAKE_MIN))
            install_hint("CMake >= %s" % CMAKE_MIN, [
                "Windows : winget install --id Kitware.CMake",
                "macOS   : brew install cmake",
                "Linux   : sudo apt install cmake   # Debian/Ubuntu (dnf/pacman likewise)",
                "any OS  : https://cmake.org/download/",
            ])
            required_ok = False
    else:
        say(BAD, "cmake    : NOT FOUND on PATH (required, >= %s)." % CMAKE_MIN)
        install_hint("CMake >= %s" % CMAKE_MIN, [
            "Windows : winget install --id Kitware.CMake",
            "macOS   : brew install cmake",
            "Linux   : sudo apt install cmake   # Debian/Ubuntu (dnf/pacman likewise)",
            "any OS  : https://cmake.org/download/",
        ])
        required_ok = False

    # ninja（**推荐**，不是必需：第 2 章写的是"推荐后端"，make.bat 不带参数也能跑）
    global NINJA_PRESENT
    if tool_path("ninja"):
        NINJA_PRESENT = True
        say(OK, "ninja    : %s  (recommended backend)" % (probe_version(["ninja", "--version"]) or "?"))
    else:
        NINJA_PRESENT = False
        say(WARN, "ninja    : NOT FOUND (recommended, not required).")
        say(INFO, "           'make.bat ninja' needs it on PATH; without ninja the build")
        say(INFO, "           still works via the default generator, just slower.")
        install_hint("ninja", [
            "Windows : winget install --id Ninja-build.Ninja",
            "macOS   : brew install ninja",
            "Linux   : sudo apt install ninja-build   # Debian/Ubuntu",
            "any OS  : https://github.com/ninja-build/ninja/releases",
        ])

    system = platform.system()
    compiler_ok = False
    if system == "Windows":
        say(INFO, "compiler : this project uses MSVC only on Windows.")
        say(INFO, "           Visual Studio is auto-detected with vswhere; a Developer")
        say(INFO, "           Command Prompt is not required. GCC/MinGW/clang-cl are ignored.")
        msvc_ok = False
        ver = find_msvc_toolset()
        inconclusive = bool(ver) and ver.startswith("~")
        if inconclusive:
            say(WARN, "MSVC     : could not read cl.exe's file version; the toolset")
            say(INFO, "           directory name is %s -- that number is NOT what CMake" % ver[1:])
            say(INFO, "           compares against, so this is reported as inconclusive instead")
            say(INFO, "           of PASS/FAIL. Required toolset: >= %s." % MSVC_TOOLSET_MIN)
            ver = None
        if ver:
            verdict = cmp_ver(ver, MSVC_TOOLSET_MIN)
            if verdict >= 0:
                note = "meets" if verdict == 0 else "above"
                say(OK, "MSVC     : toolset %s  (%s the required %s)"
                    % (ver, note, MSVC_TOOLSET_MIN))
                msvc_ok = True
            else:
                say(BAD, "MSVC     : toolset %s  (below the required %s)"
                    % (ver, MSVC_TOOLSET_MIN))
                say(INFO, "           Building will fail with 'Compiler is unsupported,")
                say(INFO, "           MSVC 2022 17.14.14 or newer is required'.")
        elif not inconclusive:
            say(BAD, "MSVC     : Visual Studio with the C++ workload was not found.")
            say(INFO, "           Detection uses vswhere and does not require a developer prompt.")
            say(INFO, "           Required toolset version: >= %s." % MSVC_TOOLSET_MIN)
        compiler_ok = msvc_ok
        if not compiler_ok:
            say(BAD, "compiler : a supported MSVC toolset was not found.")
            install_hint("MSVC", [
                "Windows : open Visual Studio Installer and update Visual Studio 2022",
                "          to 17.14.14+; keep 'Desktop development with C++' enabled",
                "          required MSVC toolset: >= %s" % MSVC_TOOLSET_MIN,
                "new install: winget install --id Microsoft.VisualStudio.2022.Community",
                "docs    : https://developer.blender.org/docs/handbook/building_blender/",
            ])
    else:
        gcc = probe_version(["gcc", "--version"]) if tool_path("gcc") else None
        gcc_ok = False
        if gcc:
            if cmp_ver(gcc, GCC_MIN) >= 0:
                say(OK, "gcc      : %s  (>= %s required)" % (gcc, GCC_MIN))
                gcc_ok = True
            else:
                say(BAD, "gcc      : %s  (below the required %s)" % (gcc, GCC_MIN))
        else:
            say(WARN, "gcc      : NOT FOUND (GCC >= %s or Clang >= %s is required)."
                % (GCC_MIN, CLANG_MIN))
        clang = probe_version(["clang", "--version"]) if tool_path("clang") else None
        clang_ok = False
        if clang:
            if cmp_ver(clang, CLANG_MIN) >= 0:
                say(OK, "clang    : %s  (>= %s required)" % (clang, CLANG_MIN))
                clang_ok = True
            else:
                say(BAD, "clang    : %s  (below the required %s)" % (clang, CLANG_MIN))
        else:
            say(WARN, "clang    : NOT FOUND (GCC >= %s or Clang >= %s is required)."
                % (GCC_MIN, CLANG_MIN))
        compiler_ok = gcc_ok or clang_ok
        if not compiler_ok:
            say(BAD, "compiler : neither GCC >= %s nor Clang >= %s is usable."
                % (GCC_MIN, CLANG_MIN))
            if system == "Darwin":
                install_hint("a C/C++ compiler", [
                    "macOS   : xcode-select --install   (Apple Clang toolchain)",
                    "          brew install llvm   (standalone clang, if you need >= %s)" % CLANG_MIN,
                    "docs    : https://developer.blender.org/docs/handbook/building_blender/",
                ])
            else:
                install_hint("a C/C++ compiler", [
                    "Linux   : sudo apt install build-essential   # Debian/Ubuntu",
                    "          sudo dnf groupinstall 'Development Tools'   # Fedora",
                    "          sudo pacman -S base-devel   # Arch",
                    "docs    : https://developer.blender.org/docs/handbook/building_blender/",
                ])

    if not compiler_ok:
        required_ok = False
    return required_ok


def next_steps(src: str) -> None:
    """打印项目统一的 Blender 构建入口；初始化本身不编译。"""
    print()
    print("== 4. Next step: build Blender (NOT run by this script) ==")
    default_src = os.path.abspath(os.path.join(ROOT, "blender"))
    source_arg = "" if os.path.normcase(src) == os.path.normcase(default_src) else (
        " --src \"%s\"" % src
    )
    if platform.system() == "Windows":
        say(INFO, "cd /d \"%s\"  &&  scons build-blender%s" % (ROOT, source_arg))
        say(INFO, "Blender's upstream dependency handling remains active in make.bat.")
    else:
        say(INFO, "cd \"%s\"  &&  scons build-blender%s" % (ROOT, source_arg))
        say(INFO, "Required pre-build platform libraries were checked by init-blender.")
    say(INFO, "A full build takes hours and writes to build_*/ next to the repository.")


def main() -> int:
    ap = argparse.ArgumentParser(description="Initialize the Blender source tree and dev tools.")
    ap.add_argument("--check-only", action="store_true",
                    help="only inspect; do not clone and do not fetch the lib submodule "
                         "(exits non-zero if something required is missing)")
    ap.add_argument("--src", default=os.path.join(ROOT, "blender"),
                    help="source directory (default: ./blender)")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    print("=" * 70)
    print("Blender source + dev environment check")
    print("Project root : %s" % ROOT)
    print("Source dir   : %s" % src)
    print("Baseline     : Blender %s, %s (%s)" % (
        BLENDER_VERSION, BLENDER_BRANCH, BLENDER_COMMIT
    ))
    print("Mode         : %s" % ("check-only" if args.check_only else "init"))
    print("=" * 70)

    ok_src = ensure_source(src, args.check_only)
    ok_libs = ensure_libs(src, args.check_only)
    ok_tools = check_tools()

    print()
    print("=" * 70)
    if not (ok_src and ok_libs and ok_tools):
        say(BAD, "Environment check FAILED -- see the [FAIL] lines above.")
        say(INFO, "This script only CHECKS: it never installs tools and never downloads")
        say(INFO, "executables. Install what is missing (each [FAIL] block prints the")
        say(INFO, "official install commands), then re-run this script.")
        print("=" * 70)
        return 1
    say(OK, "Environment check passed.")
    next_steps(src)
    print("=" * 70)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
