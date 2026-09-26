@echo off
title Plex Library Helper - Setup
echo Signs the Plex Library Helper in to your Plex account (one time per PC).
echo A Plex page will open - approve "Plex Library Helper" there.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0library-helper.ps1" -Setup
echo.
pause
