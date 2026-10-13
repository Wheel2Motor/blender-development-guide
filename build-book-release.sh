#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the public book release: PDF + examples directory.
# Pass --check to include the slow page-render verification.

set -euo pipefail
cd "$(dirname "$0")"

for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)'; then
      exec "$candidate" tools/build_book_release.py "$@"
    fi
  fi
done

echo "[FAIL] Python 3 not found on PATH."
exit 1
