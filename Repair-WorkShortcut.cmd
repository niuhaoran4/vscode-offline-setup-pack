@echo off
setlocal
if "%~1"=="" (
    echo Drag the work folder onto this file.
    echo Or run: Repair-WorkShortcut.cmd "D:\path\to\work"
    pause
    exit /b 1
)
if not exist "%~1" (
    echo Folder not found: %~1
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Set-WorkShortcut.ps1" -WorkDir "%~1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
    echo Shortcut updated on the desktop.
) else (
    echo Failed with exit code %RC%.
)
pause
exit /b %RC%
