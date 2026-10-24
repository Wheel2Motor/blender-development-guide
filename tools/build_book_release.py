#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build the book PDF and assemble its public release directory.

The release has exactly two top-level entries:

* ``blender-development-guide.pdf``
* ``examples/``
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PDF = ROOT / "book" / "build" / "blender-development-guide.pdf"
EXAMPLES = ROOT / "book" / "examples"
DIST = ROOT / "dist"
RELEASE = DIST / "blender-development-guide"

for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def run(command: list[str]) -> int:
    return subprocess.run(command, cwd=ROOT).returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build and package the PDF plus published examples."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="also validate pinned source references and run the per-page overflow scan",
    )
    args = parser.parse_args()

    print("== Validate published examples ==", flush=True)
    result = run([sys.executable, str(ROOT / "qa" / "check_examples.py")])
    if result != 0:
        return result

    print("\n== Build book PDF ==", flush=True)
    build_command = [sys.executable, str(ROOT / "tools" / "build_book.py")]
    if args.check:
        build_command.append("--check")
    result = run(build_command)
    if result != 0:
        return result

    if not PDF.is_file():
        print(f"[FAIL] PDF is missing after a successful build: {PDF}")
        return 1
    if not EXAMPLES.is_dir():
        print(f"[FAIL] Examples directory is missing: {EXAMPLES}")
        return 1

    DIST.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".release-", dir=DIST))
    try:
        shutil.copy2(PDF, staging / PDF.name)
        published_examples = staging / "examples"
        published_examples.mkdir()
        for source in sorted(EXAMPLES.rglob("*")):
            if not source.is_file():
                continue
            if "__pycache__" in source.parts or source.suffix.lower() in {".pyc", ".pyo"}:
                continue
            destination = published_examples / source.relative_to(EXAMPLES)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

        expected = {PDF.name, "examples"}
        actual = {path.name for path in staging.iterdir()}
        if actual != expected:
            print(f"[FAIL] Unexpected release entries: {sorted(actual - expected)}")
            return 1

        if RELEASE.parent.resolve() != DIST.resolve():
            print(f"[FAIL] Refusing to replace an unsafe release path: {RELEASE}")
            return 1
        if RELEASE.exists():
            shutil.rmtree(RELEASE)
        os.replace(staging, RELEASE)
    finally:
        if staging.exists():
            shutil.rmtree(staging)

    file_count = sum(1 for path in (RELEASE / "examples").rglob("*") if path.is_file())
    print("\n[ OK ] Public release assembled.")
    print(f"       Directory    : {RELEASE}")
    print(f"       Top-level    : {PDF.name}, examples/")
    print(f"       Example files: {file_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
