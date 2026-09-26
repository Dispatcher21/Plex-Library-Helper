@echo off
title Plex Library Helper - Setup
echo Sets up the Plex Library Helper on this PC. Use the same download on every PC.
echo  1. Signs in to your Plex account (a Plex page opens: approve "Plex Library Helper")
echo  2. Asks whether this PC should do encoding / compression
echo  3. Starts it now and whenever you sign in to Windows
echo Run this again any time to change your answers.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0library-helper.ps1" -Setup
echo.
pause
