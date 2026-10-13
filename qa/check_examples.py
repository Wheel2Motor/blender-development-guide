#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Validate published examples and their references from the Typst manuscript."""

from __future__ import annotations

import re
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
BOOK = ROOT / "book"
EXAMPLES = BOOK / "examples"
REFERENCE = re.compile(r'#example-file\("([^"]+)"\)')
PUBLISHED_SUFFIXES = {".c", ".py", ".toml"}


def fail(message: str) -> None:
    print(f"[FAIL] {message}")


def main() -> int:
    errors = 0
    references: dict[str, list[Path]] = {}

    for manuscript in sorted(BOOK.rglob("*.typ")):
        text = manuscript.read_text(encoding="utf-8")
        for match in REFERENCE.finditer(text):
            references.setdefault(match.group(1), []).append(manuscript)

    if not references:
        fail("No #example-file references were found in the manuscript.")
        return 1

    examples_root = EXAMPLES.resolve()
    resolved_references: list[Path] = []
    for reference in sorted(references):
        relative = PurePosixPath(reference)
        if relative.is_absolute() or ".." in relative.parts or "\\" in reference:
            fail(f"Unsafe example reference: {reference}")
            errors += 1
            continue

        target = (EXAMPLES / Path(*relative.parts)).resolve()
        if target != examples_root and examples_root not in target.parents:
            fail(f"Example reference escapes book/examples: {reference}")
            errors += 1
            continue
        if not target.exists():
            fail(f"Referenced example does not exist: {reference}")
            errors += 1
            continue
        resolved_references.append(target)

    files = [
        path
        for path in sorted(EXAMPLES.rglob("*"))
        if path.is_file()
        and "__pycache__" not in path.parts
        and path.suffix.lower() not in {".pyc", ".pyo"}
    ]
    for path in files:
        relative = path.relative_to(EXAMPLES).as_posix()
        if path.suffix.lower() not in PUBLISHED_SUFFIXES:
            fail(f"Unexpected published file type: {relative}")
            errors += 1
        if not any(path == target or target in path.parents for target in resolved_references):
            fail(f"Published example is not referenced by the book: {relative}")
            errors += 1

        if path.suffix.lower() == ".py":
            try:
                compile(path.read_text(encoding="utf-8"), str(path), "exec")
            except SyntaxError as exc:
                fail(f"Python syntax error in {relative}:{exc.lineno}: {exc.msg}")
                errors += 1

    internal_reference = '#src("book/examples/'
    for manuscript in sorted(BOOK.rglob("*.typ")):
        if internal_reference in manuscript.read_text(encoding="utf-8"):
            fail(
                "Project-internal book/examples path exposed through #src in "
                f"{manuscript.relative_to(ROOT)}"
            )
            errors += 1

    if errors:
        print(f"[FAIL] Example validation found {errors} problem(s).")
        return 1

    print(
        f"[ OK ] {len(files)} published file(s) covered by "
        f"{len(references)} manuscript reference(s)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
