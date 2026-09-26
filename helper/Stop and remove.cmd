@echo off
title Plex Library Helper - Stop and remove
echo Stops the Plex Library Helper and removes it from Windows startup.
echo Your settings and logs stay in this folder.
echo.
choice /M "Continue"
if errorlevel 2 goto :eof
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-helper.ps1"
echo.
pause
