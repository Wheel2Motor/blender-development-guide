@echo off
REM SPDX-License-Identifier: GPL-2.0-or-later
REM Build the public book release: PDF + examples directory.
REM Pass --check to include the slow page-render verification.
REM This file is intentionally ASCII-only.

setlocal
cd /d "%~dp0"

set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY (
  where python >nul 2>nul && set "PY=python"
)
if not defined PY (
  echo [FAIL] Python 3 not found on PATH.
  echo        Install it from https://www.python.org/downloads/
  exit /b 1
)

%PY% "tools\build_book_release.py" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
