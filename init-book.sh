#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Blender Development Guide -- initialize the book build environment (Typst).
# macOS / Linux entry point. All logic lives in tools/init_book.py.
# This file is intentionally ASCII-only, and it never waits for a keypress,
# so it stays safe to call from other scripts.

set -euo pipefail
cd "$(dirname "$0")"

PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
      PY="$cand"
      break
    fi
  fi
done

if [ -z "$PY" ]; then
  echo "[FAIL] Python 3 not found on PATH."
  echo "  macOS:  brew install python"
  echo "  Debian: sudo apt install python3"
  echo "  Fedora: sudo dnf install python3"
  echo "  Arch:   sudo pacman -S python"
  exit 1
fi

exec "$PY" tools/init_book.py "$@"
