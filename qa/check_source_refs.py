#!/usr/bin/env python3
"""Validate every ``#src(\"path[:line[-line]]\")`` reference in the book.

The checker is intentionally stateless: it reads the Typst sources and the pinned
Blender checkout, prints a summary, and creates no report or intermediate files.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from blender_baseline import BLENDER_COMMIT as BASELINE_COMMIT  # noqa: E402

SRC_CALL_RE = re.compile(r'#src\(\s*"([^"]+)"\s*\)', re.DOTALL)
LINE_SUFFIX_RE = re.compile(r"^(.*?):(\d+)(?:-L?(\d+))?$")


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description="Check paths and line ranges in all Typst #src() references."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=repo_root / "blender",
        help="Blender source checkout (default: <repo>/blender)",
    )
    parser.add_argument(
        "--skip-revision-check",
        action="store_true",
        help="validate against the current checkout even if it is not the pinned commit",
    )
    return parser.parse_args()


def git_head(source: Path) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout.strip() if result.returncode == 0 else None


def git_files(source: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(source), "ls-files", "-z"],
        capture_output=True,
    )
    if result.returncode != 0:
        return []
    return [
        entry.decode("utf-8", errors="surrogateescape").replace("\\", "/")
        for entry in result.stdout.split(b"\0")
        if entry
    ]


def resolve_target(
    rendered_path: str,
    repo_root: Path,
    source: Path,
    tracked_source_files: list[str],
) -> tuple[Path | None, str | None]:
    """Resolve full, directory, project-local, and unique shortened references."""
    normalized = rendered_path.replace("\\", "/").rstrip("/")
    if normalized == "blender":
        return source, None
    if normalized.startswith("book/"):
        return (repo_root / normalized).resolve(), None

    direct = (source / normalized).resolve()
    if direct.exists():
        return direct, None

    suffix = "/" + normalized
    candidates = [path for path in tracked_source_files if ("/" + path).endswith(suffix)]
    if len(candidates) == 1:
        return (source / candidates[0]).resolve(), None
    if len(candidates) > 1:
        return None, f"ambiguous shortened path ({len(candidates)} matches): {rendered_path}"
    return direct, None


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    book_root = repo_root / "book"
    source = args.source.resolve()
    errors: list[str] = []

    if not source.is_dir():
        print(f"ERROR: Blender source directory does not exist: {source}")
        return 2

    head = git_head(source)
    tracked_source_files = git_files(source)
    if head is None:
        errors.append(f"{source} is not a readable Git checkout")
    elif head != BASELINE_COMMIT and not args.skip_revision_check:
        errors.append(
            f"Blender revision is {head}; expected pinned commit {BASELINE_COMMIT}"
        )

    reference_count = 0
    references_with_lines = 0
    target_files: set[Path] = set()

    for typst_file in sorted(book_root.rglob("*.typ")):
        text = typst_file.read_text(encoding="utf-8")
        for match in SRC_CALL_RE.finditer(text):
            reference_count += 1
            rendered_ref = match.group(1)
            location = f"{typst_file.relative_to(repo_root)}:{text.count(chr(10), 0, match.start()) + 1}"
            suffix = LINE_SUFFIX_RE.match(rendered_ref)
            if suffix:
                relative_path = suffix.group(1)
                first_line = int(suffix.group(2))
                last_line = int(suffix.group(3) or first_line)
                references_with_lines += 1
                if first_line < 1 or last_line < first_line:
                    errors.append(f"{location}: invalid line range: {rendered_ref}")
                    continue
            else:
                relative_path = rendered_ref
                first_line = last_line = None

            target, resolution_error = resolve_target(
                relative_path, repo_root, source, tracked_source_files
            )
            if resolution_error:
                errors.append(f"{location}: {resolution_error}")
                continue
            assert target is not None
            allowed_roots = (source, repo_root / "book")
            if not any(target.is_relative_to(root.resolve()) for root in allowed_roots):
                errors.append(f"{location}: path escapes source checkout: {rendered_ref}")
                continue
            if not target.exists():
                errors.append(f"{location}: source path not found: {rendered_ref}")
                continue

            target_files.add(target)
            if last_line is not None:
                if not target.is_file():
                    errors.append(f"{location}: line range points to a directory: {rendered_ref}")
                    continue
                line_count = target.read_bytes().count(b"\n") + 1
                if last_line > line_count:
                    errors.append(
                        f"{location}: line {last_line} exceeds {relative_path} "
                        f"({line_count} lines)"
                    )

    print(f"Typst source references : {reference_count}")
    print(f"References with lines   : {references_with_lines}")
    print(f"Referenced source files : {len(target_files)}")
    print(f"Pinned Blender revision : {BASELINE_COMMIT}")

    if errors:
        print(f"\nFAILED: {len(errors)} problem(s)")
        for error in errors:
            print(f"- {error}")
        return 1

    print("\nPASS: all #src() paths and line ranges are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
