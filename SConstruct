#!/usr/bin/env python3
"""Cross-platform entry points for the book and Blender development environment."""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

from SCons.Script import (
    Action,
    AddOption,
    AlwaysBuild,
    Default,
    Dir,
    Environment,
    GetOption,
    Help,
)


ROOT = Path(Dir("#").abspath)

COMMANDS = {
    "init-book": ("tools/init_book.py", "Prepare Typst, pinned fonts, and the book workspace."),
    "build-book": ("tools/build_book.py", "Build the PDF or experimental HTML output."),
    "init-blender": (
        "tools/init_blender.py",
        "Fetch/check pinned Blender sources and required pre-build dependencies.",
    ),
    "build-blender": (
        "tools/build_blender.py",
        "Configure and build Blender with the native upstream workflow.",
    ),
    "bump-version": (
        "tools/version_mgr.py",
        "Bump the book version and promote pending release notes.",
    ),
}

HELP_TEXT = r"""
Blender development guide commands
==================================

Usage:
  scons help
  scons <command> [options]

Commands:
  init-book             Check Typst and prepare either project or system fonts.
  build-book            Build the book as PDF (default) or experimental HTML.
  init-blender          Fetch/check pinned sources, LFS content and platform libraries.
  build-blender         Configure and build Blender.
  bump-version          Bump the book version and promote Pending release notes.
  help                  Print this command list and the supported options.

init-book options:
  --check-only          Inspect without creating directories or downloading fonts.
                        Also accepted by init-blender (inspect only, never clones).
  --force               Ignore the font manifest and re-verify every font file.
  --use-system-fonts    Skip the project font download; check installed OS fonts.

build-book options:
  --format=FORMAT       Output format: pdf (default) or html (experimental).
  --check               Render every page and scan for margin overflow (slow).
  --release             Build the public PDF plus examples/ release directory.
  --use-system-fonts    Preview with installed OS fonts (same switch as init-book).

init-blender options:
  --check-only          Inspect without cloning or updating (init-book accepts it too).
  --src=DIR             Source directory to create or inspect (default: ./blender).
  --mirror=MIRROR       Where a NEW clone comes from (default: official):
                          official  projects.blender.org, the canonical repository
                          github    github.com/blender/blender, the official mirror
                          gitee     gitee.com/mirrors/blender, a third-party mirror
                        Only the main repository changes hands: lib/ platform
                        libraries and the repository's Git LFS objects still come
                        from projects.blender.org. A mirror that lacks the pinned
                        branch or commit fails fast instead of downloading
                        everything first. An existing checkout is never rewritten.
  --mirror-url=URL      Clone URL that overrides --mirror, e.g. a self-hosted
                        mirror or a company GitLab.
  --retries=N           Retries after a failed network step (default: 10).
  --retry-delay=SECONDS Seconds between those retries (default: 10).

build-blender options:
  --src=DIR                 Build this source directory (default: ./blender).
  --build-dir=DIR           Override the out-of-source CMake build directory.
  --blender-config=CONFIG   Release or Debug (default: Release).
  --configure-only          Generate the CMake project without compiling.
  --allow-other-revision    Permit a source HEAD different from the pinned baseline.
  -j N, --jobs=N            Forward the explicit parallel job count to Blender.

bump-version options (choose exactly one):
  --major               Bump X.y.z to X+1.0.0.
  --minor               Bump x.Y.z to x.Y+1.0.
  --micro               Bump x.y.Z to x.y.Z+1.

Examples:
  scons init-book
  scons init-book --use-system-fonts
  scons build-book
  scons build-book --format=html
  scons build-book --check
  scons build-book --use-system-fonts
  scons build-book --release
  scons build-book --release --check
  scons init-blender
  scons init-blender --check-only
  scons init-blender --mirror=github
  scons init-blender --mirror=gitee
  scons init-blender --mirror-url=https://git.example.com/blender.git
  scons init-blender --retries=30 --retry-delay=20
  scons build-blender --blender-config=Debug -j 12
  scons bump-version --minor
"""


AddOption("--check", dest="book_check", action="store_true", default=False,
          help="render every book page and run the overflow scan")
AddOption("--format", dest="book_format", type="choice", choices=("pdf", "html"),
          default="pdf", help="book output format: pdf or experimental html")
AddOption("--release", dest="book_release", action="store_true", default=False,
          help="build the public PDF plus examples/ release directory")
AddOption("--use-system-fonts", dest="use_system_fonts", action="store_true", default=False,
          help="use installed OS font fallbacks rather than pinned project fonts")
AddOption("--check-only", dest="check_only", action="store_true", default=False,
          help="inspect initialization state without downloading or writing")
AddOption("--force", dest="force_fonts", action="store_true", default=False,
          help="re-verify every project font during init-book")
AddOption("--src", dest="source_dir", type="string", default=None,
          help="override the Blender source directory")
AddOption("--mirror", dest="blender_mirror", type="choice",
          choices=("official", "github", "gitee"), default="official",
          help="source mirror for a new Blender clone: official, github, or gitee")
AddOption("--mirror-url", dest="blender_mirror_url", type="string", default=None,
          help="override the mirror clone URL, e.g. a self-hosted mirror")
AddOption("--retries", dest="blender_retries", type="int", default=10,
          help="retries after a failed network step during init-blender (default: 10)")
AddOption("--retry-delay", dest="blender_retry_delay", type="float", default=10.0,
          help="seconds between network retries during init-blender (default: 10)")
AddOption("--build-dir", dest="blender_build_dir", type="string", default=None,
          help="override the Blender CMake build directory")
AddOption("--blender-config", dest="blender_config", type="choice",
          choices=("Release", "Debug"), default="Release",
          help="Blender build configuration: Release or Debug")
AddOption("--configure-only", dest="configure_only", action="store_true", default=False,
          help="generate the Blender CMake project without compiling")
AddOption("--allow-other-revision", dest="allow_other_revision",
          action="store_true", default=False,
          help="allow Blender source HEAD to differ from the pinned baseline")
AddOption("--major", dest="version_major", action="store_true", default=False,
          help="bump the book's major version")
AddOption("--minor", dest="version_minor", action="store_true", default=False,
          help="bump the book's minor version")
AddOption("--micro", dest="version_micro", action="store_true", default=False,
          help="bump the book's micro version")


def _option_was_explicit(*names: str) -> bool:
    for arg in sys.argv[1:]:
        for name in names:
            if arg == name or arg.startswith(name + "="):
                return True
        if "-j" in names and arg.startswith("-j") and len(arg) > 2:
            return True
    return False


def _script_args(alias: str) -> list[str]:
    args: list[str] = []
    if alias == "build-book":
        if not GetOption("book_release"):
            args.extend(("--format", GetOption("book_format")))
        if GetOption("book_check"):
            args.append("--check")
        if GetOption("use_system_fonts"):
            args.append("--use-system-fonts")
    elif alias == "init-book":
        if GetOption("check_only"):
            args.append("--check-only")
        if GetOption("force_fonts"):
            args.append("--force")
        if GetOption("use_system_fonts"):
            args.append("--use-system-fonts")
    elif alias == "init-blender":
        if GetOption("check_only"):
            args.append("--check-only")
        if GetOption("source_dir"):
            args.extend(("--src", GetOption("source_dir")))
        args.extend(("--mirror", GetOption("blender_mirror")))
        if GetOption("blender_mirror_url"):
            args.extend(("--mirror-url", GetOption("blender_mirror_url")))
        args.extend(("--retries", str(GetOption("blender_retries"))))
        args.extend(("--retry-delay", str(GetOption("blender_retry_delay"))))
    elif alias == "build-blender":
        if GetOption("source_dir"):
            args.extend(("--src", GetOption("source_dir")))
        if GetOption("blender_build_dir"):
            args.extend(("--build-dir", GetOption("blender_build_dir")))
        args.extend(("--config", GetOption("blender_config")))
        if GetOption("configure_only"):
            args.append("--configure-only")
        if GetOption("allow_other_revision"):
            args.append("--allow-other-revision")
        if _option_was_explicit("-j", "--jobs"):
            args.extend(("--jobs", str(GetOption("num_jobs"))))
    elif alias == "bump-version":
        for option, dest in (
            ("--major", "version_major"),
            ("--minor", "version_minor"),
            ("--micro", "version_micro"),
        ):
            if GetOption(dest):
                args.append(option)
    return args


def _display(command: list[str]) -> str:
    if os.name == "nt":
        return subprocess.list2cmdline(command)
    return shlex.join(command)


def _run_script(target, source, env) -> int:  # noqa: ANN001
    alias = env["ENTRY_ALIAS"]
    version_flags = [
        name
        for name, enabled in (
            ("--major", GetOption("version_major")),
            ("--minor", GetOption("version_minor")),
            ("--micro", GetOption("version_micro")),
        )
        if enabled
    ]
    if alias == "bump-version" and len(version_flags) != 1:
        print("[FAIL] bump-version requires exactly one of "
              "--major, --minor, or --micro.")
        return 2
    if alias != "bump-version" and version_flags:
        print("[FAIL] --major, --minor, and --micro only apply to bump-version.")
        return 2
    if alias != "init-blender" and _option_was_explicit("--mirror", "--mirror-url"):
        print("[FAIL] --mirror and --mirror-url only apply to init-blender.")
        return 2
    if alias != "init-blender" and _option_was_explicit("--retries", "--retry-delay"):
        print("[FAIL] --retries and --retry-delay only apply to init-blender.")
        return 2
    release = alias == "build-book" and GetOption("book_release")
    book_format = GetOption("book_format")
    if alias == "build-book" and book_format == "html" and GetOption("book_check"):
        print("[FAIL] --check only applies to paged PDF output; "
              "it cannot be combined with --format=html.")
        return 2
    if release and book_format != "pdf":
        print("[FAIL] --release only packages the PDF edition; "
              "it cannot be combined with --format=html.")
        return 2
    if release and GetOption("use_system_fonts"):
        print("[FAIL] --release and --use-system-fonts are mutually exclusive; "
              "release builds require pinned project fonts.")
        return 2
    if alias == "init-book" and GetOption("force_fonts") and GetOption("use_system_fonts"):
        print("[FAIL] --force and --use-system-fonts are mutually exclusive; "
              "there are no project fonts to verify in system-font mode.")
        return 2
    script = ROOT / ("tools/build_book_release.py" if release else COMMANDS[alias][0])
    command = [sys.executable, str(script), *_script_args(alias)]
    print("[ .. ] %s" % _display(command), flush=True)
    return subprocess.run(command, cwd=ROOT).returncode


def _print_help(target, source, env) -> int:  # noqa: ANN001
    print(HELP_TEXT.strip())
    return 0


env = Environment(tools=[])
for alias in COMMANDS:
    alias_env = env.Clone(ENTRY_ALIAS=alias)
    node = alias_env.Alias(alias, [], Action(_run_script, "Run %s" % alias))
    AlwaysBuild(node)

help_alias = env.Alias("help", [], Action(_print_help, "Print supported commands"))
AlwaysBuild(help_alias)
Default(help_alias)
Help(HELP_TEXT)
