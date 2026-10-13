#!/usr/bin/env python3
"""Check repository Markdown style without producing report artifacts."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STRONG_MARK_RE = re.compile(r"(?<!\\)(?<!\*)\*\*(?!\*)")
FENCE_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})(.*)$")
HEADING_RE = re.compile(r"^( {0,3})(#{1,6})([^\s#])")


@dataclass(frozen=True)
class Issue:
    path: Path
    line: int
    message: str


def markdown_files() -> list[Path]:
    files = [ROOT / "README.md", ROOT / "AGENTS.md"]
    files.extend(sorted((ROOT / "doc").rglob("*.md")))
    return [path for path in files if path.is_file()]


def mask_inline_code(line: str) -> str:
    """Replace complete inline-code spans with spaces, preserving indices."""
    chars = list(line)
    cursor = 0
    while cursor < len(line):
        if line[cursor] != "`":
            cursor += 1
            continue
        end_run = cursor
        while end_run < len(line) and line[end_run] == "`":
            end_run += 1
        marker = line[cursor:end_run]
        closing = line.find(marker, end_run)
        if closing < 0:
            cursor = end_run
            continue
        for index in range(cursor, closing + len(marker)):
            chars[index] = " "
        cursor = closing + len(marker)
    return "".join(chars)


def wordlike(char: str) -> bool:
    return char.isalnum() or char == "_"


def fix_line(line: str, strong_open: bool) -> tuple[str, list[str], bool]:
    messages: list[str] = []
    heading = HEADING_RE.match(line)
    if heading:
        insert_at = len(heading.group(1)) + len(heading.group(2))
        line = line[:insert_at] + " " + line[insert_at:]
        messages.append("ATX heading marker must be followed by a space")

    masked = mask_inline_code(line)
    insertions: set[int] = set()
    removals: list[tuple[int, int]] = []
    for match in STRONG_MARK_RE.finditer(masked):
        if not strong_open:
            if match.start() > 0 and wordlike(line[match.start() - 1]):
                insertions.add(match.start())
                messages.append("strong emphasis must be separated from preceding prose")
            content_start = match.end()
            content_end = content_start
            while content_end < len(line) and line[content_end] in " \t":
                content_end += 1
            if content_end > content_start:
                removals.append((content_start, content_end))
                messages.append("strong emphasis must not start with whitespace")
            strong_open = True
        else:
            content_end = match.start()
            content_start = content_end
            while content_start > 0 and line[content_start - 1] in " \t":
                content_start -= 1
            if content_start < content_end:
                removals.append((content_start, content_end))
                messages.append("strong emphasis must not end with whitespace")
            if match.end() < len(line) and wordlike(line[match.end()]):
                insertions.add(match.end())
                messages.append("strong emphasis must be separated from following prose")
            strong_open = False

    edits = [(start, end, "") for start, end in removals]
    edits.extend((index, index, " ") for index in insertions)
    for start, end, replacement in sorted(edits, reverse=True):
        line = line[:start] + replacement + line[end:]
    return line, messages, strong_open


def check_file(path: Path, apply_fixes: bool) -> tuple[list[Issue], int]:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)
    updated: list[str] = []
    issues: list[Issue] = []
    changed_lines = 0
    fence_char: str | None = None
    fence_length = 0
    fence_line = 0
    strong_open = False
    strong_open_line = 0

    for number, raw_line in enumerate(lines, start=1):
        ending = ""
        line = raw_line
        if line.endswith("\r\n"):
            line, ending = line[:-2], "\r\n"
        elif line.endswith("\n"):
            line, ending = line[:-1], "\n"

        fence = FENCE_RE.match(line)
        if fence:
            marker = fence.group(2)
            if fence_char is None:
                fence_char = marker[0]
                fence_length = len(marker)
                fence_line = number
            elif marker[0] == fence_char and len(marker) >= fence_length:
                fence_char = None
                fence_length = 0
                fence_line = 0
            updated.append(raw_line)
            continue

        if fence_char is not None:
            updated.append(raw_line)
            continue

        was_open = strong_open
        fixed, messages, strong_open = fix_line(line, strong_open)
        if not was_open and strong_open:
            strong_open_line = number
        elif was_open and not strong_open:
            strong_open_line = 0
        if messages:
            if apply_fixes and fixed != line:
                changed_lines += 1
            else:
                for message in dict.fromkeys(messages):
                    issues.append(Issue(path, number, message))

        updated.append((fixed if apply_fixes else line) + ending)

    if fence_char is not None:
        issues.append(Issue(path, fence_line, "fenced code block is not closed"))
    if strong_open:
        issues.append(
            Issue(path, strong_open_line or 1, "unbalanced strong-emphasis markers outside code")
        )

    if apply_fixes and changed_lines:
        path.write_text("".join(updated), encoding="utf-8", newline="")
    return issues, changed_lines


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check Markdown headings, fences, emphasis markers, and bold spacing."
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Insert missing heading and strong-emphasis spacing in place.",
    )
    args = parser.parse_args()

    files = markdown_files()
    all_issues: list[Issue] = []
    changed_lines = 0
    for path in files:
        issues, changed = check_file(path, args.fix)
        all_issues.extend(issues)
        changed_lines += changed

    for issue in all_issues:
        relative = issue.path.relative_to(ROOT).as_posix()
        print(f"{relative}:{issue.line}: {issue.message}")

    if all_issues:
        print(f"[FAIL] {len(all_issues)} Markdown issue(s) found in {len(files)} file(s).")
        return 1
    if args.fix:
        print(f"[OK] Checked {len(files)} Markdown file(s); fixed {changed_lines} line(s).")
    else:
        print(f"[OK] Checked {len(files)} Markdown file(s); no issues found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
