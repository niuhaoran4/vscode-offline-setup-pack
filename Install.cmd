@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "MODE=C"
set "DRYRUN="
set "NOPAUSE="

:parse
if "%~1"=="" goto parsed
if /I "%~1"=="C" set "MODE=C"
if /I "%~1"=="D" set "MODE=D"
if /I "%~1"=="-DryRun" set "DRYRUN=-DryRun"
if /I "%~1"=="-NoPause" set "NOPAUSE=1"
if /I "%~1"=="-h" goto usage
if /I "%~1"=="--help" goto usage
shift
goto parse

:parsed
if not exist "%~dp0scripts\setup.ps1" (
    echo [ERROR] scripts\setup.ps1 not found. Extract the whole package first.
    set "RC=1"
    goto failed
)
if not exist "%~dp0scripts\verify.ps1" (
    echo [ERROR] scripts\verify.ps1 not found. Extract the whole package first.
    set "RC=1"
    goto failed
)

if /I "%MODE%"=="D" (
    set "EXTRA=-VSCodeDir D:\VSCode -DataRoot D:\VSCodeData -MigrateData"
    set "TARGET=D: (D:\VSCode + D:\VSCodeData)"
    echo [INFO] Close all VSCode windows before continuing.
    echo [INFO] If a system VSCode already exists on C:, uninstall it first.
) else (
    set "EXTRA="
    set "TARGET=C: (default paths)"
)

echo.
echo ============================================================
echo  VSCode Offline Setup
echo  Package: %~dp0
echo  Target : %TARGET%
if defined DRYRUN echo  Mode   : DryRun (no changes)
echo ============================================================
echo.
echo Starting installer. Approve the UAC prompt if it appears.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1" %EXTRA% %DRYRUN%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto failed

if defined DRYRUN (
    echo.
    echo Dry run completed successfully. No changes were made.
    goto done
)

echo.
echo Installer finished. Running verification...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\verify.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto verify_failed

echo.
echo All done. Restart VSCode, or sign out and back in, to refresh PATH.
goto done

:failed
echo.
echo Installation failed with exit code %RC%.
echo See logs under "%~dp0logs".
goto done

:verify_failed
echo.
echo Installation completed, but verification reported problems.
echo See logs under "%~dp0logs".
goto done

:usage
echo Usage: Install.cmd [C^|D] [-DryRun] [-NoPause]
echo   C        Install to C: (default)
echo   D        Install to D:\VSCode with data in D:\VSCodeData
echo   -DryRun  Check only, do not install or change anything
echo   -NoPause Do not wait for a key at the end
exit /b 0

:done
echo.
if not defined NOPAUSE pause
exit /b %RC%
