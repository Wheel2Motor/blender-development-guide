#!/usr/bin/env python3
"""Load and validate the book's pinned Blender baseline."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASELINE_PATH = ROOT / "book" / "blender-baseline.json"


def _load() -> dict[str, str]:
    try:
        data = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Cannot read Blender baseline: {BASELINE_PATH}: {exc}") from exc

    required = {
        "version",
        "version_series",
        "version_suffix",
        "tag",
        "branch",
        "commit",
    }
    missing = sorted(required - data.keys())
    if missing:
        raise RuntimeError(f"Blender baseline is missing: {', '.join(missing)}")
    if not all(isinstance(data[key], str) and data[key] for key in required):
        raise RuntimeError("Every Blender baseline value must be a non-empty string")
    if not re.fullmatch(r"[0-9a-f]{40}", data["commit"]):
        raise RuntimeError("Blender baseline commit must be a full 40-character lowercase SHA-1")
    if not re.fullmatch(r"\d+\.\d+\.\d+", data["version"]):
        raise RuntimeError("Blender baseline version must use major.minor.patch")
    expected_series = data["version"].rsplit(".", 1)[0]
    if data["version_series"] != expected_series:
        raise RuntimeError(
            f"Blender version_series must be {expected_series} for version {data['version']}"
        )
    if data["tag"] != f"v{data['version']}":
        raise RuntimeError("Blender baseline tag must be 'v' followed by the full version")
    return data


BASELINE = _load()
BLENDER_VERSION = BASELINE["version"]
BLENDER_VERSION_SERIES = BASELINE["version_series"]
BLENDER_VERSION_SUFFIX = BASELINE["version_suffix"]
BLENDER_TAG = BASELINE["tag"]
BLENDER_BRANCH = BASELINE["branch"]
BLENDER_COMMIT = BASELINE["commit"]
