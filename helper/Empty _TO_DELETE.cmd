@echo off
title Plex Library Helper - Empty _TO_DELETE
echo Shows what is waiting in _TO_DELETE on this PC's drives, then deletes it for good
echo only if you choose to and type DELETE. Nothing is deleted without that.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0library-helper.ps1" -EmptyTrash
echo.
pause
