@echo off
if not exist "%~dp0Install.cmd" (
    echo [ERROR] Install.cmd not found.
    echo You are probably running this file from inside a ZIP archive.
    echo Right-click the downloaded ZIP, choose "Extract All", then run Install-D.cmd from the extracted folder.
    pause
    exit /b 1
)
call "%~dp0Install.cmd" D %*
exit /b %ERRORLEVEL%
