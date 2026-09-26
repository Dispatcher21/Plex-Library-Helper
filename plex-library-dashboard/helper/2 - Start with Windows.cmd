@echo off
title Plex Library Helper - Start with Windows
echo Starts the Plex Library Helper now, and automatically whenever you sign in to Windows.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-helper.ps1"
echo.
pause
