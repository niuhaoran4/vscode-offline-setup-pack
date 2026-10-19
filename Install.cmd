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
set "IN_ZIP_TEMP="
echo "%~dp0" | findstr /I /C:".zip" /C:"\AppData\Local\Temp\" >nul
if not errorlevel 1 set "IN_ZIP_TEMP=1"

if not exist "%~dp0scripts\setup.ps1" (
    echo [ERROR] Cannot find scripts\setup.ps1.
    if defined IN_ZIP_TEMP (
        echo You are running this file from inside a ZIP archive or a temporary folder.
        echo Right-click the downloaded ZIP, choose "Extract All", then run Install.cmd from the extracted folder.
    ) else (
        echo Extract the whole package first, then run Install.cmd from the extracted folder.
    )
    set "RC=1"
    goto failed
)
if not exist "%~dp0installer\VSCodeSetup-x64-*.exe" (
    echo.
    echo This is the source archive, not the full offline package.
    echo The full package is about 512 MB and will be downloaded from GitHub Releases.
    echo.
    choice /C YN /T 15 /D Y /M "Download the full package now"
    if errorlevel 2 goto source_declined
    if not exist "%~dp0scripts\bootstrap.ps1" (
        echo [ERROR] scripts\bootstrap.ps1 not found.
        set "RC=1"
        goto failed
    )
    echo Downloading...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\bootstrap.ps1" -Destination "%~dp0_full-package"
    if errorlevel 1 (
        echo [ERROR] Download or extraction failed.
        echo Download the full package manually from:
        echo https://github.com/niuhaoran4/vscode-offline-setup-pack/releases
        set "RC=1"
        goto failed
    )
    set "BOOTSTRAP_ROOT="
    for /d %%D in ("%~dp0_full-package\VSCode-Offline-Setup-Pack-*") do (
        if exist "%%D\scripts\setup.ps1" set "BOOTSTRAP_ROOT=%%D"
    )
    if not defined BOOTSTRAP_ROOT (
        echo [ERROR] Extracted package not found.
        set "RC=1"
        goto failed
    )
    set "NO_PAUSE_ARG="
    if defined NOPAUSE set "NO_PAUSE_ARG=-NoPause"
    call "%BOOTSTRAP_ROOT%\Install.cmd" %MODE% %DRYRUN% %NO_PAUSE_ARG%
    exit /b %ERRORLEVEL%
)

:source_declined
if not exist "%~dp0installer\VSCodeSetup-x64-*.exe" (
    echo.
    echo Download cancelled. Get the full package from:
    echo https://github.com/niuhaoran4/vscode-offline-setup-pack/releases
    set "RC=1"
    goto failed
)
if not exist "%~dp0extensions\*.vsix" (
    echo [ERROR] Extension files are missing. Download the full offline package from Releases.
    echo https://github.com/niuhaoran4/vscode-offline-setup-pack/releases
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
