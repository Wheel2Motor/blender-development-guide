# SPDX-License-Identifier: GPL-2.0-or-later
"""Resolve a data file relative to the current add-on or script."""

from pathlib import Path


addon_dir = Path(__file__).resolve().parent
data_file = addon_dir / "data" / "presets.json"
print("addon 目录:", addon_dir)
print("随附文件:", data_file, data_file.exists())
