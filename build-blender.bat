@echo off
REM SPDX-License-Identifier: GPL-2.0-or-later
REM Generate and build the already-initialized Blender checkout.
REM Source and dependency downloads belong to init-blender.bat.
REM This file is intentionally ASCII-only: the cmd.exe code page is GBK here.

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
  echo        and tick "Add python.exe to PATH" during setup.
  pause
  exit /b 1
)

%PY% "tools\build_blender.py" %*
set "RC=%ERRORLEVEL%"
echo.
echo Exit code: %RC%
pause
endlocal & exit /b %RC%
