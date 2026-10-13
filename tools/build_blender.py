#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Configure and build the already-initialized Blender checkout.

This wrapper deliberately has no download or update step. Source code, the
platform library submodule, and toolchain preparation belong to
``tools/init_blender.py``. It does not suppress dependency handling performed
internally by Blender's own build scripts. This wrapper only:

1. verifies that the checkout, pinned revision, and materialized libraries are
   ready;
2. generates an out-of-source CMake project;
3. builds and installs Blender from that generated project.

On Windows the upstream ``make.bat`` wrapper generates ``Blender.sln`` (or the
newer ``Blender.slnx``), then ``cmake --build`` builds its INSTALL target. On
macOS/Linux this script configures Ninja, falling back to Unix Makefiles, and
builds the install target through CMake.
"""

from __future__ import annotations

import argparse
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from blender_baseline import BLENDER_BRANCH, BLENDER_COMMIT, BLENDER_VERSION
from init_blender import (MSVC_TOOLSET_MIN, cmp_ver, dir_has_content,
                          find_msvc_toolset, lfs_pointer_files, lib_submodule,
                          tool_path)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "blender"

OK, WARN, BAD, INFO = "[ OK ]", "[WARN]", "[FAIL]", "[ .. ]"

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def say(tag: str, message: str) -> None:
    print("%s %s" % (tag, message), flush=True)


def command_text(command: list[str]) -> str:
    if os.name == "nt":
        return subprocess.list2cmdline(command)
    return shlex.join(command)


def run_capture(command: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    """Run a short probe and capture combined output without anonymous pipes."""
    handle = tempfile.TemporaryFile()
    try:
        try:
            cp = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=handle, stderr=subprocess.STDOUT,
                                timeout=120)
            return_code = cp.returncode
        except Exception as exc:  # noqa: BLE001
            return_code = 127
            handle.write(str(exc).encode("utf-8", "replace"))
        handle.seek(0)
        return subprocess.CompletedProcess(command, return_code, handle.read())
    finally:
        handle.close()


def output_text(result: subprocess.CompletedProcess) -> str:
    output = result.stdout or b""
    if isinstance(output, str):
        return output
    return output.decode("utf-8", errors="replace")


def first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def run_live(command: list[str], description: str,
             cwd: Path | None = None) -> subprocess.CompletedProcess:
    """Run a long configure/build command with live terminal output."""
    say(INFO, "%s ..." % description)
    say(INFO, "Command: %s" % command_text(command))
    started = time.monotonic()
    try:
        result = subprocess.run(command, cwd=cwd)
    except KeyboardInterrupt:
        elapsed = time.monotonic() - started
        say(BAD, "%s interrupted after %.1f s." % (description, elapsed))
        return subprocess.CompletedProcess(command, 130)
    except Exception as exc:  # noqa: BLE001
        elapsed = time.monotonic() - started
        say(BAD, "%s could not start after %.1f s: %s"
            % (description, elapsed, exc))
        return subprocess.CompletedProcess(command, 127)

    elapsed = time.monotonic() - started
    if result.returncode == 0:
        say(OK, "%s completed in %.1f s (exit code 0)." % (description, elapsed))
    else:
        say(BAD, "%s failed after %.1f s (exit code %d)."
            % (description, elapsed, result.returncode))
    return result


def same_path(left: Path, right: Path) -> bool:
    try:
        return os.path.normcase(str(left.resolve())) == os.path.normcase(str(right.resolve()))
    except OSError:
        return False


def git_value(source: Path, *arguments: str) -> str | None:
    result = run_capture(["git", "-C", str(source), *arguments])
    if result.returncode != 0:
        return None
    return first_line(output_text(result)) or None


def validate_source(source: Path, allow_other_revision: bool) -> bool:
    """Require the checkout prepared by init-blender, not a partial directory."""
    required = ["CMakeLists.txt", "source", "build_files"]
    if platform.system() == "Windows":
        required.append("make.bat")
    missing = [name for name in required if not (source / name).exists()]
    if missing:
        say(BAD, "Blender source is incomplete at %s." % source)
        for name in missing:
            say(INFO, "  missing: %s" % name)
        say(INFO, "Run init-blender.bat / ./init-blender.sh before building.")
        return False

    if not tool_path("git"):
        say(BAD, "git is not on PATH, so the source revision cannot be verified.")
        return False
    top = git_value(source, "rev-parse", "--show-toplevel")
    if not top or not same_path(Path(top), source):
        say(BAD, "%s is not the root of an independent Git checkout." % source)
        say(INFO, "A partial directory must not be built; run init-blender first.")
        return False
    head = git_value(source, "rev-parse", "HEAD")
    if not head:
        say(BAD, "Could not read the Blender checkout revision.")
        return False
    if head != BLENDER_COMMIT:
        tag = WARN if allow_other_revision else BAD
        say(tag, "Source HEAD is %s; the book baseline is %s."
            % (head, BLENDER_COMMIT))
        if not allow_other_revision:
            say(INFO, "Refusing to build a different revision by default because source")
            say(INFO, "references and verified behavior are pinned to the baseline.")
            say(INFO, "Use --allow-other-revision only for an intentional local experiment.")
            return False
    else:
        say(OK, "Source revision matches the pinned baseline %s." % BLENDER_COMMIT)
    return True


def validate_libraries(source: Path, allow_upstream_handling: bool) -> bool:
    """Check dependencies without fetching; optionally defer to upstream tooling."""
    candidates = lib_submodule(platform.system(), platform.machine())
    if not candidates:
        say(INFO, "No project-managed precompiled library is defined for this platform.")
        say(INFO, "CMake will use the system or manually prepared platform dependencies.")
        return True

    name = candidates[0]
    library = source / "lib" / name
    if not dir_has_content(str(library)):
        tag = WARN if allow_upstream_handling else BAD
        say(tag, "Prepared platform dependencies are missing at %s." % library)
        if allow_upstream_handling:
            say(INFO, "Blender's upstream make.bat will handle or prompt for dependencies.")
            return True
        say(INFO, "Run ./init-blender.sh before building.")
        return False

    pointers = lfs_pointer_files(str(library))
    if pointers:
        tag = WARN if allow_upstream_handling else BAD
        say(tag, "lib/%s still contains Git LFS pointer files:" % name)
        for pointer in pointers:
            say(INFO, "  %s" % pointer)
        if allow_upstream_handling:
            say(INFO, "Continuing with Blender's upstream dependency handling unchanged.")
            return True
        say(INFO, "Run ./init-blender.sh to restore dependencies.")
        return False

    say(OK, "Prepared dependencies found at %s." % library)
    return True


def default_build_dir(source: Path) -> Path:
    names = {"Windows": "build_windows", "Darwin": "build_macos", "Linux": "build_linux"}
    return source.parent / names.get(platform.system(), "build_%s" % platform.system().lower())


def validate_windows_msvc() -> bool:
    """Find a supported MSVC toolset, including outside a developer prompt."""
    msvc = find_msvc_toolset()
    if not msvc or msvc.startswith("~"):
        say(BAD, "No verifiable MSVC installation was found.")
        say(INFO, "Visual Studio is discovered with vswhere; a Developer Command Prompt")
        say(INFO, "is not required. Install the 'Desktop development with C++' workload.")
        say(INFO, "Run init-blender.bat for detailed diagnostics and install hints.")
        return False
    if cmp_ver(msvc, MSVC_TOOLSET_MIN) < 0:
        say(BAD, "MSVC toolset %s is below the required %s." % (
            msvc, MSVC_TOOLSET_MIN
        ))
        say(INFO, "Blender 5.2.2 requires Visual Studio 2022 17.14.14 or newer.")
        say(INFO, "Open Visual Studio Installer, update Visual Studio and its C++ workload,")
        say(INFO, "then rerun build-blender.bat from any cmd.exe window.")
        return False
    say(OK, "Auto-detected supported MSVC toolset %s." % msvc)
    return True


def windows_batch_command(batch: Path, arguments: list[str]) -> list[str]:
    invocation = subprocess.list2cmdline([str(batch), *arguments])
    return [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/s", "/c", "call " + invocation]


def windows_build(source: Path, build_dir: Path, config: str,
                  jobs: int | None, configure_only: bool) -> bool:
    batch = source / "make.bat"
    if not validate_windows_msvc():
        return False

    common: list[str] = []
    if config == "Debug":
        common.append("debug")
    common.extend(["builddir", str(build_dir)])

    configure = windows_batch_command(batch, [*common, "nobuild"])
    result = run_live(configure, "Generate the Visual Studio CMake project", cwd=source)
    if result.returncode != 0:
        return False
    solutions = sorted([*build_dir.glob("Blender.sln"), *build_dir.glob("Blender.slnx")])
    if not solutions:
        say(BAD, "CMake reported success, but Blender.sln/Blender.slnx is missing in %s."
            % build_dir)
        return False
    say(OK, "Visual Studio solution: %s" % solutions[0])
    if configure_only:
        say(INFO, "Stopped after project generation (--configure-only).")
        return True

    cmake = tool_path("cmake")
    if not cmake:
        say(BAD, "cmake is not on PATH. Run init-blender for toolchain diagnostics.")
        return False
    build = [cmake, "--build", str(build_dir), "--config", config,
             "--target", "INSTALL", "--parallel"]
    if jobs:
        build.append(str(jobs))
    result = run_live(build, "Build the generated Visual Studio INSTALL target", cwd=ROOT)
    if result.returncode != 0:
        return False
    say(OK, "Windows build output: %s" % (build_dir / "bin"))
    return True


def unix_build(source: Path, build_dir: Path, config: str,
               jobs: int | None, configure_only: bool) -> bool:
    cmake = tool_path("cmake")
    if not cmake:
        say(BAD, "cmake is not on PATH. Run init-blender for toolchain diagnostics.")
        return False
    generator = "Ninja" if tool_path("ninja") else "Unix Makefiles"
    say(INFO, "CMake generator: %s" % generator)
    configure = [cmake, "-S", str(source), "-B", str(build_dir), "-G", generator,
                 "-DCMAKE_BUILD_TYPE=%s" % config]
    result = run_live(configure, "Generate the CMake build project", cwd=ROOT)
    if result.returncode != 0:
        return False
    if not (build_dir / "CMakeCache.txt").is_file():
        say(BAD, "CMake reported success, but CMakeCache.txt is missing in %s." % build_dir)
        return False
    if configure_only:
        say(INFO, "Stopped after project generation (--configure-only).")
        return True

    build = [cmake, "--build", str(build_dir), "--config", config,
             "--target", "install", "--parallel"]
    if jobs:
        build.append(str(jobs))
    result = run_live(build, "Build and install the generated CMake project", cwd=ROOT)
    if result.returncode != 0:
        return False
    say(OK, "Build output: %s" % (build_dir / "bin"))
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate and build Blender through its native build workflow."
    )
    parser.add_argument("--src", default=str(DEFAULT_SOURCE),
                        help="Blender source directory (default: ./blender)")
    parser.add_argument("--build-dir",
                        help="out-of-source CMake build directory (default: build_<platform>)")
    parser.add_argument("--config", choices=("Release", "Debug"), default="Release",
                        help="build configuration (default: Release)")
    parser.add_argument("--jobs", type=int,
                        help="parallel build job count (default: build-tool default)")
    parser.add_argument("--configure-only", action="store_true",
                        help="generate the CMake project but do not compile it")
    parser.add_argument("--allow-other-revision", action="store_true",
                        help="allow a source HEAD different from the pinned book baseline")
    args = parser.parse_args()

    if args.jobs is not None and args.jobs < 1:
        parser.error("--jobs must be a positive integer")

    source = Path(args.src).resolve()
    build_dir = (Path(args.build_dir).resolve() if args.build_dir
                 else default_build_dir(source).resolve())
    system = platform.system()

    print("=" * 70)
    print("Generate and build Blender")
    print("Project root : %s" % ROOT)
    print("Source dir   : %s" % source)
    print("Build dir    : %s" % build_dir)
    print("Baseline     : Blender %s, %s (%s)" % (
        BLENDER_VERSION, BLENDER_BRANCH, BLENDER_COMMIT
    ))
    print("Configuration: %s" % args.config)
    print("Mode         : %s" % ("configure-only" if args.configure_only else "configure + build"))
    print("Dependencies : wrapper does not fetch; upstream build behavior is preserved")
    print("=" * 70)

    if same_path(source, build_dir) or source in build_dir.parents:
        say(BAD, "The build directory must be outside the Blender source directory.")
        return 1
    if not validate_source(source, args.allow_other_revision):
        return 1
    if not validate_libraries(source, allow_upstream_handling=(system == "Windows")):
        return 1

    if system == "Windows":
        ok = windows_build(source, build_dir, args.config,
                           args.jobs, args.configure_only)
    elif system in ("Darwin", "Linux"):
        ok = unix_build(source, build_dir, args.config,
                        args.jobs, args.configure_only)
    else:
        say(BAD, "Unsupported platform: %s" % system)
        return 1

    print()
    print("=" * 70)
    if ok:
        say(OK, "Blender project generation%s completed."
            % (" and build" if not args.configure_only else ""))
        say(INFO, "This wrapper issued no source or dependency update command.")
        say(INFO, "Dependency handling inside Blender's upstream tools was left unchanged.")
        print("=" * 70)
        return 0
    say(BAD, "Blender project generation/build failed; see the command output above.")
    say(INFO, "The source and dependencies were not updated or deleted.")
    print("=" * 70)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
