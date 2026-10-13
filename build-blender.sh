#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Generate and build the already-initialized Blender checkout.
# Source and dependency downloads belong to init-blender.sh.
# This file is intentionally ASCII-only and does not wait for input.

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

exec "$PY" tools/build_blender.py "$@"
