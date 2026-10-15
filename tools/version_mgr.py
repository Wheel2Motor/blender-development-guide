#!/usr/bin/env python3
"""Bump the book version and promote pending release notes."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
META_PATH = ROOT / "book" / "meta.json"
RELEASE_NOTE_PATH = ROOT / "RELEASE_NOTE.md"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
LIST_ITEM_RE = re.compile(r"^[-+*]\s+\S.*$")


def _configure_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="replace")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bump the book version and promote pending release notes."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--major", action="store_const", const="major", dest="part",
                       help="bump X.y.z to X+1.0.0")
    group.add_argument("--minor", action="store_const", const="minor", dest="part",
                       help="bump x.Y.z to x.Y+1.0")
    group.add_argument("--micro", action="store_const", const="micro", dest="part",
                       help="bump x.y.Z to x.y.Z+1")
    return parser.parse_args()


def _load_metadata() -> tuple[dict[str, object], str]:
    try:
        data = json.loads(META_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read valid JSON from {META_PATH}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{META_PATH} must contain a JSON object.")
    version = data.get("version")
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
        raise ValueError(
            f"{META_PATH} must define version as MAJOR.MINOR.MICRO; got {version!r}."
        )
    return data, version


def _bump(version: str, part: str) -> str:
    match = VERSION_RE.fullmatch(version)
    if match is None:  # Kept local so this function is safe to reuse independently.
        raise ValueError(f"Invalid semantic version: {version!r}.")
    major, minor, micro = (int(value) for value in match.groups())
    if part == "major":
        major, minor, micro = major + 1, 0, 0
    elif part == "minor":
        minor, micro = minor + 1, 0
    else:
        micro += 1
    return f"{major}.{minor}.{micro}"


def _promote_pending(notes: str, version: str) -> tuple[str, int]:
    top_level = re.findall(r"(?m)^#\s+(.+?)\s*$", notes)
    expected = ["Release Note", "Pending"]
    if top_level != expected:
        raise ValueError(
            f"{RELEASE_NOTE_PATH} must contain exactly these top-level headings "
            f"in order: {expected}."
        )

    release_match = re.search(r"(?m)^# Release Note\s*$", notes)
    pending_match = re.search(r"(?m)^# Pending\s*$", notes)
    if release_match is None or pending_match is None or release_match.end() >= pending_match.start():
        raise ValueError(f"Cannot locate the release-note sections in {RELEASE_NOTE_PATH}.")

    release_body = notes[release_match.end():pending_match.start()].strip()
    pending_body = notes[pending_match.end():].strip()
    if not pending_body:
        raise ValueError("The Pending section has no unordered-list items to promote.")
    item_count = 0
    for line in pending_body.splitlines():
        if not line.strip():
            continue
        if LIST_ITEM_RE.fullmatch(line):
            item_count += 1
            continue
        if item_count and (line.startswith("  ") or line.startswith("\t")):
            continue
        raise ValueError(
            "The Pending section may contain only unordered-list items and their "
            f"indented continuation lines; invalid line: {line!r}."
        )
    if item_count == 0:
        raise ValueError("The Pending section has no unordered-list items to promote.")
    if re.search(rf"(?m)^##\s+{re.escape(version)}\s*$", release_body):
        raise ValueError(f"Release Note already contains version {version}.")

    new_section = f"## {version}\n\n{pending_body}"
    release_sections = new_section
    if release_body:
        release_sections += "\n\n" + release_body
    result = f"# Release Note\n\n{release_sections}\n\n# Pending\n"
    return result, item_count


def _write_temp(path: Path, content: str) -> Path:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
        return Path(handle.name)


def _replace_pair(meta_content: str, notes_content: str) -> None:
    original_meta = META_PATH.read_text(encoding="utf-8")
    meta_temp: Path | None = None
    notes_temp: Path | None = None
    rollback_temp: Path | None = None
    try:
        meta_temp = _write_temp(META_PATH, meta_content)
        notes_temp = _write_temp(RELEASE_NOTE_PATH, notes_content)
        os.replace(meta_temp, META_PATH)
        try:
            os.replace(notes_temp, RELEASE_NOTE_PATH)
        except OSError as replace_error:
            rollback_temp = _write_temp(META_PATH, original_meta)
            os.replace(rollback_temp, META_PATH)
            raise replace_error
    finally:
        for temp_path in (meta_temp, notes_temp, rollback_temp):
            if temp_path is not None:
                temp_path.unlink(missing_ok=True)


def main() -> int:
    _configure_console()
    args = _parse_args()
    try:
        metadata, old_version = _load_metadata()
        new_version = _bump(old_version, args.part)
        notes = RELEASE_NOTE_PATH.read_text(encoding="utf-8")
        new_notes, item_count = _promote_pending(notes, new_version)
        metadata["version"] = new_version
        new_metadata = json.dumps(metadata, ensure_ascii=False, indent=2) + "\n"
        _replace_pair(new_metadata, new_notes)
    except (OSError, ValueError) as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    print(f"[ OK ] Book version: {old_version} -> {new_version}")
    print(f"[ OK ] Promoted {item_count} pending release note item(s).")
    print(f"[ .. ] Updated: {META_PATH}")
    print(f"[ .. ] Updated: {RELEASE_NOTE_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
