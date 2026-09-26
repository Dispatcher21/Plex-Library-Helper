@echo off
title Plex Library Helper - Status
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue; if ($t) { 'Running in the background: ' + $(if ($t.State -eq 'Running') { 'yes' } else { 'no (' + $t.State + ')' }) } else { 'Not set to start with Windows yet (run 2 - Start with Windows).' }; ''"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0library-helper.ps1" -Status
echo.
echo Activity log: %~dp0logs
echo.
pause
