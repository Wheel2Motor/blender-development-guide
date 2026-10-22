#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》—— 初始化 Blender 源码与开发环境。

做四件事：

1. 把 Blender 源码克隆到基准 commit（``blender/`` 不存在时）；
2. 取主仓库的 Git LFS 内容，并按平台准备预编译库 ``lib/<平台>_<架构>``：
   Windows 也在这里非交互完成（上游 ``make.bat`` 的 ``check_libraries.cmd`` 用
   ``set /p`` 询问，自动化会话里会失败；库已就绪时它不会再问）；
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

    python tools/init_blender.py                   # 缺了就克隆，然后检查
    python tools/init_blender.py --check-only      # 只检查，不克隆不下库（缺必需项则非零退出）
    python tools/init_blender.py --src DIR         # 指定源码目录（默认 ./blender）
    python tools/init_blender.py --mirror github   # 从 GitHub 官方镜像克隆
    python tools/init_blender.py --mirror gitee    # 从 Gitee 镜像克隆（第三方同步）
    python tools/init_blender.py --mirror-url URL  # 用任意镜像地址（自建、公司内网）
    python tools/init_blender.py --retries 30 --retry-delay 20   # 网络差时放宽重试

``--mirror`` 只改主仓库的克隆来源：``lib/`` 平台库和主仓库的 Git LFS 对象仍由
projects.blender.org 提供（镜像里的 ``.gitmodules``、``.gitattributes`` 与官方逐字
相同），所以构建方式与官方仓库一致，差别只在“数据从哪台机器下载”。主仓库的 LFS
内容必须还原成实体文件——上游 ``CMakeLists.txt`` 见到指针形态的
``release/datafiles/startup.blend`` 会直接 FATAL——镜像克隆因此会从官方补取
（见 ``ensure_repo_lfs()``）。

所有联网步骤（克隆、基准 commit、LFS、子模块）失败后都会自动重试：默认最多 10 次、
每次间隔 10 秒，可用 ``--retries`` 与 ``--retry-delay`` 调整。下载是幂等的，
重试只补缺口。

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

# 主仓库来源。--mirror 只切换这一处，**不切换 lib/ 子模块和 LFS 对象**：
# 镜像里的 .gitmodules / .gitattributes 与官方逐字相同，平台库和 LFS 数据文件仍由
# projects.blender.org 提供（见本文件 report_mirror_followup()）。
MIRRORS = {
    # 官方主仓库（Gitea），开发与发布都在这里。
    "official": "https://projects.blender.org/blender/blender.git",
    # 官方文档明确承认的官方镜像：
    # https://developer.blender.org/docs/handbook/contributing/using_git/clone_update/#github-mirror
    # 它不含本仓库的 Git LFS 对象，所以克隆时必须跳过 smudge（见 ensure_source）。
    "github": "https://github.com/blender/blender.git",
    # 第三方镜像（Gitee 上并没有 Blender 官方镜像）。mirrors/blender 由 Gitee 的 mirrors
    # 组织同步，核对时带有 blender-v5.2-release 与 v5.2.2；但它终究是别人同步的，
    # 所以 ensure_source 会在克隆前后都核对基准分支与 commit，落后就明确失败。
    # 另一个已知镜像 blender_5/blender 停在 blender-v5.0-release，不能用于本基准。
    "gitee": "https://gitee.com/mirrors/blender.git",
}
DEFAULT_MIRROR = "official"
# 官方仓库(也是镜像落后时补取基准 commit、补取 LFS 数据的来源)。
BLENDER_REPO = MIRRORS["official"]
# git-lfs 默认只开 8 个并发连接。实测 projects.blender.org 在这条网络上：
# 8 -> 0.43 MiB/s，32 -> 1.60 MiB/s，64 -> 2.00 MiB/s（再高收益递减）。
# 32 是速度与对服务器压力的折中；`-c` 会经 GIT_CONFIG_PARAMETERS 传给 git-lfs
# 子进程（用 `git lfs env` 验证过 ConcurrentTransfers 生效）。
LFS_CONCURRENCY = 32
# 网络操作的重试：默认失败后最多再重试 10 次、每次间隔 10 秒，可用
# --retries / --retry-delay 覆盖。下载是幂等的（git 复用已落盘对象），重试只补缺口。
RETRIES = 10
RETRY_DELAY_S = 10.0


def lfs_cmd(src: str, *args: str) -> list[str]:
    """Git LFS 命令，统一带上并发设置。"""
    return ["git", "-C", src,
            "-c", "lfs.concurrenttransfers=%d" % LFS_CONCURRENCY,
            "lfs", *args]
# 全书带 `文件:行号` 的源码引用都钉在上面的 commit 上；换版本可能对不上。
# 当前引用数量由 qa/check_source_refs.py 在运行时统计，不在仓库里保存快照。

# 书里第 2 章的门槛。没有出处的数字一个都不要写进来。
CMAKE_MIN = "3.21"          # book/chapters/02-build-environment.typ（CMakeLists.txt:29）
GCC_MIN = "14.0"            # 同上（CMakeLists.txt:107-133）
CLANG_MIN = "17.0"          # 同上
MSVC_TOOLSET_MIN = "19.44.35216"  # build_files/cmake/platform/platform_win32.cmake:42

# 由 ensure_libs() 设置的"当前状态"，供 check_tools() 判断 git-lfs 是必需还是用不到：
#   * LFS_NEEDED 非 None -> 需要拉取/还原 lib/ 或主仓库 LFS 内容，缺 git-lfs 就是 [FAIL]；
#   * 未设 -> 两者都已是还原好的实体文件，缺 git-lfs 只 [WARN]。
LFS_NEEDED: str | None = None
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
             cwd: str | None = None,
             env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Run a long command with its output attached to the current terminal.

    Clone, fetch, submodule, and Git LFS operations must not use ``run()``:
    captured output makes a large download look frozen. Git writes its progress
    meter to stderr, so inheriting both standard streams also preserves the
    interactive progress display in the BAT/SH terminal.

    ``env`` replaces the child environment when given (used to pass
    ``GIT_LFS_SKIP_SMUDGE`` to a mirror clone); ``None`` inherits ours.
    """
    say(INFO, "%s ..." % description)
    say(INFO, "Command: %s" % command_text(cmd))
    sys.stdout.flush()
    sys.stderr.flush()
    started = time.monotonic()
    try:
        cp = subprocess.run(cmd, cwd=cwd, env=env)
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


def discard_partial(path: str) -> None:
    """删掉本次运行自己创建、但没下载完的目录（重试前清理用）。"""
    say(INFO, "Removing the incomplete directory %s before retrying." % path)
    shutil.rmtree(path, ignore_errors=True)


def run_with_retry(cmd: list[str], description: str,
                   cwd: str | None = None,
                   env: dict[str, str] | None = None,
                   on_retry=None) -> subprocess.CompletedProcess:
    """运行一条可能因网络失败的命令，失败后按 ``--retries``/``--retry-delay`` 重试。

    下载类命令是幂等的：git 会复用已经落盘的对象，重试只补缺口，所以重试不会
    重复整份传输。``on_retry`` 在两次尝试之间调用，用来清理半成品（例如残留的
    clone 目录）。只在非零退出时重试；成功立刻返回，最后一次失败原样返回给调用方
    判断（有些命令用退出码表达"确定不存在"，例如 ``git ls-remote``）。
    """
    attempts = RETRIES + 1
    cp: subprocess.CompletedProcess | None = None
    for attempt in range(1, attempts + 1):
        if attempt > 1:
            say(WARN, "Retrying %s in %.0f s (attempt %d of %d) ..."
                % (description, RETRY_DELAY_S, attempt, attempts))
            time.sleep(RETRY_DELAY_S)
            if on_retry is not None:
                on_retry()
        label = description if attempt == 1 else (
            "%s (attempt %d of %d)" % (description, attempt, attempts))
        cp = run_live(cmd, label, cwd=cwd, env=env)
        if cp.returncode == 0:
            return cp
    say(BAD, "Giving up on %s after %d attempt(s)." % (description, attempts))
    return cp if cp is not None else subprocess.CompletedProcess(cmd, 127)


def run_probe_with_retry(cmd: list[str], description: str,
                         ok_codes: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess:
    """同 ``run_with_retry``，但用于输出被捕获的探测命令（如 ``git ls-remote``）。

    ``ok_codes`` 里列出的退出码视为"已经拿到确定结论"，立即返回、不再重试。
    """
    attempts = RETRIES + 1
    cp: subprocess.CompletedProcess | None = None
    for attempt in range(1, attempts + 1):
        if attempt > 1:
            say(WARN, "Retrying %s in %.0f s (attempt %d of %d) ..."
                % (description, RETRY_DELAY_S, attempt, attempts))
            time.sleep(RETRY_DELAY_S)
        cp = run(cmd)
        if cp.returncode in ok_codes:
            return cp
    return cp if cp is not None else subprocess.CompletedProcess(cmd, 127)


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
# 0) 镜像选择
# ---------------------------------------------------------------------------
def git_dir(repo: str) -> str | None:
    """返回仓库的 git 目录（子模块里是 ``.git`` 文件指向的路径）。"""
    cp = git(repo, "rev-parse", "--git-dir")
    if cp.returncode != 0:
        return None
    path = first_line(text_of(cp))
    if not path:
        return None
    return path if os.path.isabs(path) else os.path.normpath(os.path.join(repo, path))


def warn_stale_index_lock(repo: str, label: str) -> None:
    """中断的 git/git-lfs 操作可能留下 index.lock，导致索引再也刷新不了。

    不替用户删文件（可能还有 git 进程在运行），只明确告警，避免出现
    "内容都对、`git status` 却显示几千个文件已修改"的困惑。
    """
    gdir = git_dir(repo)
    if not gdir:
        return
    lock = os.path.join(gdir, "index.lock")
    if not os.path.exists(lock):
        return
    say(WARN, "Found a stale index.lock in the %s git directory." % label)
    say(INFO, "An interrupted git/git-lfs run left it behind; git cannot refresh")
    say(INFO, "the index until it is gone, so LFS files keep showing as modified.")
    say(INFO, "Make sure no git process is running, delete %s, then re-run." % lock)


def mirror_url(mirror: str, override: str | None) -> str:
    """把 ``--mirror`` 与 ``--mirror-url`` 解析成一个克隆 URL。

    ``--mirror-url`` 优先：Gitee 上没有任何官方镜像，用户自己的镜像（或公司内网
    GitLab）比预设名更实用，所以保留这个逃生口。
    """
    return override or MIRRORS[mirror]


def mirror_display_name(mirror: str, override: str | None) -> str:
    """报告里显示的镜像名：给了 URL 就叫 custom，避免把预设名安到别的地址上。"""
    if override:
        return "custom"
    return mirror


def report_mirror_followup(src: str, official: bool) -> None:
    """镜像克隆成功后的补充说明（LFS 已由 ensure_repo_lfs 处理好）。

    **不是失败**：镜像不托管主仓库的 Git LFS 对象，所以内容是在
    ``ensure_repo_lfs()`` 里从官方服务器补下来的。这里只说明来源，
    免得用户以为克隆混进了别的东西。
    """
    if official:
        return
    say(INFO, "Reminder: this checkout came from a mirror.")
    say(INFO, "The repository's Git LFS objects were fetched from")
    say(INFO, "projects.blender.org (remote 'lfs-fallback'), because mirrors do not")
    say(INFO, "host them. Upstream make_update.py does the same for third-party")
    say(INFO, "checkouts (lfs_fallback_setup); nothing else in the tree is mixed.")


def lfs_pointer(path: str, threshold: int = 1024) -> bool:
    """小文件且首行是 LFS 指针 -> 内容没下载。"""
    try:
        if os.path.getsize(path) >= threshold:
            return False
        with open(path, "rb") as f:
            return f.read(64).startswith(b"version https://git-lfs")
    except OSError:
        return False


def lfs_pointers(repo: str) -> list[str] | None:
    """列出该仓库里仍是 LFS 指针文件的路径（全量，不是抽样）。

    主仓库和 `lib/` 子模块都是 Git LFS 仓库，都适用。只查一个"代表文件"会让
    半成品蒙混过关：`git lfs pull` 被中断时那个文件可能已落地，其余几千个还是
    指针——上游 CMake 只查 `startup.blend`，那样的树会被放行、产出却是坏的。

    返回 ``None`` 表示 `git lfs ls-files` 不可用（没装 git-lfs），调用方退回
    按文件大小/头部抽样的 ``lfs_pointer_files()``。
    """
    cp = git(repo, "lfs", "ls-files", "--name-only")
    if cp.returncode != 0:
        return None
    hits: list[str] = []
    for rel in text_of(cp).splitlines():
        rel = rel.strip()
        if rel and lfs_pointer(os.path.join(repo, rel)):
            hits.append(rel)
    return hits


def lib_pointers(lib_path: str) -> list[str]:
    """``lib/<平台>_<架构>`` 里的指针文件：优先全量，没装 git-lfs 时退回抽样。"""
    found = lfs_pointers(lib_path)
    return lfs_pointer_files(lib_path) if found is None else found


def ensure_repo_lfs(src: str, official: bool) -> bool:
    """把主仓库被 LFS 管理的文件补成实体内容。

    这不是可选步骤：上游 ``CMakeLists.txt`` 在 configure 阶段就检查
    ``release/datafiles/startup.blend`` 的大小，指针文件会直接 FATAL
    （"Detected incomplete startup blend"）；``assets/*.blend``、画笔、ICC
    配置等也会被打包进产物。

    官方仓库克隆时由 git-lfs 的 smudge 自动完成；镜像克隆为了不让 checkout
    失败用了 ``GIT_LFS_SKIP_SMUDGE=1``，因此必须在这里从官方补取——
    等价于上游 ``make_update.py`` 的 ``lfs_fallback_setup()``。
    """
    sentinel = os.path.join(src, "release", "datafiles", "startup.blend")
    warn_stale_index_lock(src, "source checkout")
    pointers = lfs_pointers(src)
    if pointers is None:
        # 没有 git-lfs：只能按上游的判据检查那一个文件。
        pointers = [os.path.relpath(sentinel, src)] if lfs_pointer(sentinel) else []
    if not pointers:
        return True

    print()
    say(WARN, "Git LFS content is missing: %d file(s) are still pointer files."
        % len(pointers))
    for rel in pointers[:5]:
        say(INFO, "  %s" % rel)
    if len(pointers) > 5:
        say(INFO, "  ... and %d more" % (len(pointers) - 5))
    say(INFO, "The build needs all of it: upstream CMakeLists.txt refuses to configure")
    say(INFO, "while release/datafiles/startup.blend is a pointer file, and the rest")
    say(INFO, "(icons, brushes, color management data) ships inside Blender.")

    if not tool_path("git-lfs"):
        say(BAD, "git-lfs not found on PATH, so the LFS content cannot be fetched.")
        install_hint("git-lfs", [
            "Windows : winget install --id GitHub.GitLFS",
            "macOS   : brew install git-lfs   (then: git lfs install)",
            "Linux   : sudo apt install git-lfs   (then: git lfs install)",
            "any OS  : https://git-lfs.com/",
        ])
        return False

    if official:
        cp = run_with_retry(lfs_cmd(src, "pull"),
                            "Restore Git LFS files from the official repository")
    else:
        have = git(src, "remote", "get-url", "lfs-fallback")
        if have.returncode != 0:
            cp = run_live(["git", "-C", src, "remote", "add",
                           "lfs-fallback", BLENDER_REPO],
                          "Add the official repository as LFS fallback")
            if cp.returncode != 0:
                return False
        git(src, "config", "lfs.remote.searchall", "true")
        cp = run_with_retry(lfs_cmd(src, "fetch", "lfs-fallback"),
                            "Fetch Git LFS objects from the official repository")
        if cp.returncode != 0:
            say(INFO, "Git printed the LFS error above. Without these files the")
            say(INFO, "Blender build cannot configure, so this counts as a failure.")
            return False
        cp = run_with_retry(lfs_cmd(src, "checkout"),
                            "Materialize Git LFS files in the working tree")

    if cp.returncode != 0:
        say(BAD, "Git LFS restore failed (exit code %d)." % cp.returncode)
        return False
    remaining = lfs_pointers(src)
    if remaining is None:
        remaining = [os.path.relpath(sentinel, src)] if lfs_pointer(sentinel) else []
    if remaining:
        say(BAD, "%d file(s) are still pointer files after the LFS restore."
            % len(remaining))
        for rel in remaining[:5]:
            say(INFO, "  %s" % rel)
        say(INFO, "Check network access to %s and re-run this script." % BLENDER_REPO)
        return False
    say(OK, "Git LFS content is materialized (no pointer files left in the checkout).")
    return True


# ---------------------------------------------------------------------------
# 1) 克隆 / 核对源码
# ---------------------------------------------------------------------------
def ensure_source(src: str, check_only: bool, mirror: str, repo_url: str) -> bool:
    """克隆/核对源码。返回"是否可用"（缺失、克隆失败、无法核对 -> False）。"""
    print()
    print("== 1. Blender source ==")
    official = repo_url == BLENDER_REPO
    say(INFO, "Mirror   : %s (%s)" % (mirror, repo_url))
    if not official:
        say(INFO, "Only the main repository comes from this mirror. The lib/ platform")
        say(INFO, "libraries and this repository's Git LFS objects are still served by")
        say(INFO, "projects.blender.org: .gitmodules and .gitattributes are identical in")
        say(INFO, "every mirror, so the build procedure does not change.")
    if os.path.isdir(os.path.join(src, ".git")):
        cp = git(src, "remote", "get-url", "origin")
        origin = first_line(text_of(cp)) if cp.returncode == 0 else ""
        if origin and origin == repo_url:
            say(OK, "Existing checkout already tracks %s." % origin)
        elif origin and not official:
            say(INFO, "Existing checkout tracks %s." % origin)
            say(INFO, "--mirror selects where a NEW clone comes from; this working")
            say(INFO, "tree is left untouched, so nothing was re-downloaded.")
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
        if not ensure_repo_lfs(src, official):
            return False
        report_mirror_followup(src, official)
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

    # 先问一次远端有没有基准分支。镜像是别人同步的，可能落后好几个月；
    # 先花几秒问一句，好过下完 1.5 GiB 才发现分支根本不存在。
    # `--exit-code` 在“没有任何匹配的 ref”时返回 2，网络/DNS 故障返回 128。
    # 2 是确定结论，不重试；其余非零当作网络抖动，按重试参数再问。
    probe = run_probe_with_retry(
        ["git", "ls-remote", "--exit-code", "--heads", repo_url, BLENDER_BRANCH],
        "Check whether %s has branch %s" % (mirror, BLENDER_BRANCH),
        ok_codes=(0, 2),
    )
    if probe.returncode == 2:
        say(BAD, "Mirror %s has no branch %s." % (mirror, BLENDER_BRANCH))
        say(INFO, "It is behind the official repository, so it cannot provide the pinned")
        say(INFO, "baseline commit %s. Nothing was downloaded." % BLENDER_COMMIT)
        say(INFO, "Clone from the official repository instead:")
        say(INFO, "  scons init-blender --mirror official")
        say(INFO, "or point --mirror-url at a mirror that tracks %s." % BLENDER_BRANCH)
        return False
    if probe.returncode != 0:
        say(WARN, "Could not check whether %s has branch %s (git ls-remote failed)."
            % (mirror, BLENDER_BRANCH))
        say(INFO, "Continuing: if the mirror is unreachable from this network, the clone")
        say(INFO, "below prints the real error, and --mirror official is the fallback.")
    else:
        say(OK, "Mirror %s provides branch %s." % (mirror, BLENDER_BRANCH))

    # 所有镜像（含官方）都跳过 clone 时的 LFS smudge，理由有两条：
    #   1. 镜像根本不托管这些对象，smudge 会让 clone 直接失败；
    #   2. 官方仓库的 smudge 是逐文件串行的，实测只有几十 KiB/s；跳过之后由
    #      ensure_repo_lfs() 用并发的 `git lfs fetch/pull` 一次性补齐，快得多。
    # 这样三条镜像的取源路径完全一致，只差 URL。
    env = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1")
    say(INFO, "Cloning with GIT_LFS_SKIP_SMUDGE=1; Git LFS content is fetched")
    say(INFO, "afterwards in one concurrent pass (see section 1).")

    say(INFO, "The source repository is large. Git will print transfer progress below.")
    cp = run_with_retry(
        ["git", "clone", "--progress", "--branch", BLENDER_BRANCH,
         repo_url, src],
        "Clone Blender source (branch %s from %s)" % (BLENDER_BRANCH, mirror),
        env=env,
        # 目录是这条命令自己创建的；重试前必须清掉，否则 git 会拒绝往非空目录克隆。
        on_retry=lambda: discard_partial(src),
    )
    if cp.returncode != 0:
        say(INFO, "Git printed the error above; the incomplete directory is still at")
        say(INFO, "%s. This script will not delete it automatically." % src)
        return False

    head = head_commit(src)
    if head == BLENDER_COMMIT:
        say(OK, "Cloned and already at the baseline commit %s." % BLENDER_COMMIT)
        if not ensure_repo_lfs(src, official):
            return False
        report_mirror_followup(src, official)
        return True

    say(INFO, "Branch tip is %s." % (head or "?")[:12])
    # 克隆拉的是整条分支历史，基准 commit 一般已经在本地。此时不要再按 SHA 向远端
    # 取一次：并非每个镜像都允许 `fetch <sha>`，而本地已有对象就没必要联网。
    present = git(src, "cat-file", "-e", BLENDER_COMMIT + "^{commit}").returncode == 0
    if present:
        say(OK, "Baseline commit %s is already in the clone." % BLENDER_COMMIT[:12])
    else:
        say(INFO, "Fetching baseline commit %s ..." % BLENDER_COMMIT[:12])
        cp = run_with_retry(
            ["git", "-C", src, "fetch", "--progress", "--depth", "1",
             "origin", BLENDER_COMMIT],
            "Fetch baseline commit %s" % BLENDER_COMMIT[:12],
        )
        if cp.returncode != 0:
            say(INFO, "The clone succeeded, but the baseline commit could not be fetched.")
            if not official:
                say(INFO, "Mirror %s is behind: it does not carry %s."
                    % (mirror, BLENDER_COMMIT))
                say(INFO, "Fetch just this one commit from the official repository:")
                say(INFO, "  git -C \"%s\" remote add official %s" % (src, BLENDER_REPO))
                say(INFO, "  git -C \"%s\" fetch --depth 1 official %s"
                    % (src, BLENDER_COMMIT))
                say(INFO, "  git -C \"%s\" checkout %s" % (src, BLENDER_COMMIT))
                say(INFO, "Next time, --mirror official clones straight from upstream.")
            say(INFO, "The checkout was left untouched so you can inspect or retry it safely.")
            return False

    cp = run_with_retry(
        ["git", "-C", src, "checkout", "--progress", BLENDER_COMMIT],
        "Check out baseline commit %s" % BLENDER_COMMIT[:12],
    )
    if cp.returncode != 0:
        say(INFO, "The baseline commit is present, but checkout failed; Git printed the")
        say(INFO, "reason above. Run 'git -C \"%s\" status' to see local changes." % src)
        return False
    head = head_commit(src)
    if head == BLENDER_COMMIT:
        say(OK, "Checked out the baseline commit %s." % BLENDER_COMMIT)
        if not ensure_repo_lfs(src, official):
            return False
        report_mirror_followup(src, official)
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
    global LFS_NEEDED
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
        # 上游 make.bat 的 check_libraries.cmd 用 `set /p` 交互询问要不要下载平台库。
        # 在非交互会话（CI、自动化、从脚本调用）里那一步会直接失败，所以这里用
        # 同一套 git 命令把库准备好：make.bat 之后只因“库已存在”而跳过询问。
        say(INFO, "Windows platform libraries are prepared here, without make.bat's")
        say(INFO, "interactive prompt (its own prompt stays as a fallback if libraries")
        say(INFO, "are still missing).")

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
        warn_stale_index_lock(lib_path, "lib/%s" % name)
        ptrs = lib_pointers(lib_path)
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
            cp = run_with_retry(
                lfs_cmd(lib_path, "pull"),
                "Restore Git LFS files for lib/%s" % name,
            )
            if cp.returncode != 0:
                return False
            ptrs = lib_pointers(lib_path)
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
        say(INFO, "Run 'scons init-blender' (without --check-only) to fetch it;")
        say(INFO, "the submodule is pinned to a Git LFS repository, so git-lfs is required.")
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

    # .gitmodules 写着 `update = none`（上游故意的），必须就地改成 checkout，
    # 否则 `git submodule update` 会跳过它——make.bat 的 check_libraries.cmd
    # 也是先 `git config --local submodule.<path>.update checkout` 再更新。
    # 同时跳过 smudge：lib 仓库是 LFS，逐文件串行 smudge 实测只有几十 KiB/s，
    # 换成下面一次并发的 `git lfs pull`。
    cp = run_with_retry(
        ["git", "-C", src, "-c", "submodule.lib/%s.update=checkout" % name,
         "submodule", "update", "--init", "--progress", "--", "lib/" + name],
        "Fetch submodule lib/%s (Git checkout only)" % name,
        env=dict(os.environ, GIT_LFS_SKIP_SMUDGE="1"),
        # 目录同样是子模块命令自己创建的，重试前清掉半成品。
        on_retry=lambda: discard_partial(lib_path),
    )
    if cp.returncode != 0:
        say(INFO, "Git printed the submodule error above.")
        return False

    if tool_path("git-lfs"):
        cp = run_with_retry(
            lfs_cmd(lib_path, "pull"),
            "Fetch Git LFS content for lib/%s" % name,
        )
        if cp.returncode != 0:
            say(INFO, "Git printed the Git LFS error above.")
            return False

    if dir_has_content(lib_path):
        say(OK, "lib/%s fetched and is not empty." % name)
        ptrs = lib_pointers(lib_path)
        if ptrs:
            LFS_NEEDED = ("lib/%s still contains un-restored Git LFS pointer files" % name)
            say(WARN, "Git LFS files are still pointers after submodule checkout:")
            for p in ptrs:
                say(INFO, "  %s" % p)
            cp = run_with_retry(
                lfs_cmd(lib_path, "pull"),
                "Restore Git LFS files for lib/%s" % name,
            )
            if cp.returncode != 0:
                return False
            ptrs = lib_pointers(lib_path)
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

    # git-lfs：**需要拉取/还原 lib/ 或主仓库 LFS 时是必需项**（两者都是 Git LFS
    # 仓库，没有它只会拿到指针文件）；两者都已还原成实体文件时用不到它。
    lfs_exe = tool_path("git-lfs")
    if lfs_exe:
        if LFS_NEEDED:
            lfs_reason = "required to fetch/restore lib/ and repository LFS content"
        else:
            lfs_reason = "not needed right now: lib/ and LFS content are materialized"
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
    else:
        say(WARN, "git-lfs  : NOT FOUND (not needed right now: lib/ and LFS are materialized).")

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
        say(INFO, "Platform libraries are already prepared, so make.bat will not prompt.")
    else:
        say(INFO, "cd \"%s\"  &&  scons build-blender%s" % (ROOT, source_arg))
        say(INFO, "Required pre-build platform libraries were checked by init-blender.")
    say(INFO, "A full build takes hours and writes to build_*/ next to the repository.")


def main() -> int:
    # 网络步骤共用的重试设置（模块级状态，由 run_with_retry 读取）。
    global RETRIES, RETRY_DELAY_S
    ap = argparse.ArgumentParser(description="Initialize the Blender source tree and dev tools.")
    ap.add_argument("--check-only", action="store_true",
                    help="only inspect; do not clone and do not fetch the lib submodule "
                         "(exits non-zero if something required is missing)")
    ap.add_argument("--src", default=os.path.join(ROOT, "blender"),
                    help="source directory (default: ./blender)")
    ap.add_argument("--mirror", choices=sorted(MIRRORS), default=DEFAULT_MIRROR,
                    help="where a new clone comes from: official (default), github "
                         "(official mirror) or gitee (third-party mirror)")
    ap.add_argument("--mirror-url",
                    help="override the mirror clone URL, e.g. a self-hosted mirror")
    ap.add_argument("--retries", type=int, default=RETRIES,
                    help="retries after a failed network step (default: %d)" % RETRIES)
    ap.add_argument("--retry-delay", type=float, default=RETRY_DELAY_S,
                    help="seconds to wait between retries (default: %.0f)" % RETRY_DELAY_S)
    args = ap.parse_args()

    if args.retries < 0:
        ap.error("--retries must be zero or a positive integer")
    if args.retry_delay < 0:
        ap.error("--retry-delay must be zero or a positive number of seconds")

    # 网络步骤共用的重试设置已在函数开头声明为 global。
    RETRIES = args.retries
    RETRY_DELAY_S = args.retry_delay

    src = os.path.abspath(args.src)
    repo_url = mirror_url(args.mirror, args.mirror_url)
    mirror_name = mirror_display_name(args.mirror, args.mirror_url)
    print("=" * 70)
    print("Blender source + dev environment check")
    print("Project root : %s" % ROOT)
    print("Source dir   : %s" % src)
    print("Baseline     : Blender %s, %s (%s)" % (
        BLENDER_VERSION, BLENDER_BRANCH, BLENDER_COMMIT
    ))
    print("Mirror       : %s (%s)" % (mirror_name, repo_url))
    print("Retries      : %d attempt(s) after the first failure, %.0f s apart"
          % (RETRIES, RETRY_DELAY_S))
    print("Mode         : %s" % ("check-only" if args.check_only else "init"))
    print("=" * 70)

    ok_src = ensure_source(src, args.check_only, mirror_name, repo_url)
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
