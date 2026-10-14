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
    "build-book": ("tools/build_book.py", "Build the PDF; optionally render and verify every page."),
    "init-blender": (
        "tools/init_blender.py",
        "Fetch/check pinned Blender sources and required pre-build dependencies.",
    ),
    "build-blender": (
        "tools/build_blender.py",
        "Configure and build Blender with the native upstream workflow.",
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
  build-book            Build the book PDF.
  init-blender          Fetch/check pinned Blender sources and dependencies.
  build-blender         Configure and build Blender.
  help                  Print this command list and the supported options.

Book options:
  --check               Render every page and scan for margin overflow.
  --release             Build the public PDF plus examples/ release directory.
  --use-system-fonts    Skip project font download/use installed OS font fallbacks.
  --check-only          Inspect initialization state without downloading/writing.
  --force               Re-verify every project font during init-book.

Blender options:
  --check-only              Inspect initialization state without cloning/updating.
  --src=DIR                 Override the Blender source directory.
  --build-dir=DIR           Override the out-of-source CMake build directory.
  --blender-config=CONFIG   Release or Debug (default: Release).
  --configure-only          Generate the CMake project without compiling.
  --allow-other-revision    Permit a source HEAD different from the pinned baseline.
  -j N, --jobs=N            Forward the explicit parallel job count to Blender.

Examples:
  scons init-book
  scons init-book --use-system-fonts
  scons build-book
  scons build-book --check
  scons build-book --use-system-fonts
  scons build-book --release
  scons build-book --release --check
  scons init-blender
  scons build-blender --blender-config=Debug -j 12
"""


AddOption("--check", dest="book_check", action="store_true", default=False,
          help="render every book page and run the overflow scan")
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
    return args


def _display(command: list[str]) -> str:
    if os.name == "nt":
        return subprocess.list2cmdline(command)
    return shlex.join(command)


def _run_script(target, source, env) -> int:  # noqa: ANN001
    alias = env["ENTRY_ALIAS"]
    release = alias == "build-book" and GetOption("book_release")
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
