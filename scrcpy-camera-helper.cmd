rem SPDX-License-Identifier: AGPL-3.0-only
rem This file is part of scrcpy-camera-helper.
rem License: GNU AGPL v3.0 or later - <https://www.gnu.org/licenses/agpl-3.0.html>

@echo off
rem ============================================================
rem  scrcpy-camera-helper launcher
rem  Double-click to open the TUI. Any arguments are passed through.
rem ============================================================
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    set "PWSH=pwsh.exe"
) else if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
) else (
    echo.
    echo  PowerShell 7 was not found. On Windows:
    echo    winget install Microsoft.PowerShell
    echo.
    pause
    exit /b 1
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrcpy-camera-helper.ps1" %*
exit /b %errorlevel%
