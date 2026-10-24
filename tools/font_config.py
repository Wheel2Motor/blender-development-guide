#!/usr/bin/env python3
"""Shared loader for the book's two font configurations."""

from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK = os.path.join(ROOT, "book")
FONT_DIR = os.path.join(BOOK, "fonts")
NOTO_CONFIG = os.path.join(FONT_DIR, "noto.json")
SYSTEM_CONFIG = os.path.join(FONT_DIR, "system-fallbacks.json")


def platform_key() -> str:
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def _load(path: str, expected_mode: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise ValueError("cannot read font configuration %s: %s" % (path, exc)) from exc
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise ValueError("font configuration must be a schema-1 JSON object: %s" % path)
    if data.get("mode") != expected_mode:
        raise ValueError("font configuration mode must be %r: %s" % (expected_mode, path))
    return data


def load_noto_config() -> dict:
    try:
        with open(NOTO_CONFIG, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise ValueError(
            "cannot read font configuration %s: %s" % (NOTO_CONFIG, exc)) from exc
    if not isinstance(data, dict):
        raise ValueError("project font configuration must be a JSON object: %s" % NOTO_CONFIG)
    for key in ("body", "code"):
        value = data.get(key)
        if not isinstance(value, list) or not value or not all(
                isinstance(item, str) and item.strip() for item in value):
            raise ValueError(
                "Noto font configuration %r must be a non-empty string list: %s"
                % (key, NOTO_CONFIG))
    return data


def load_system_config() -> dict:
    data = _load(SYSTEM_CONFIG, "system")
    platforms = data.get("platforms")
    if not isinstance(platforms, dict) or platform_key() not in platforms:
        raise ValueError("system font configuration has no entry for %s" % platform_key())
    return data


def typst_relative(path: str) -> str:
    """Return a slash-separated path that Typst resolves from book/main.typ."""
    return os.path.relpath(path, BOOK).replace(os.sep, "/")
