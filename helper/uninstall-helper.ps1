# Stops the Plex Library Helper and removes it from startup. Your settings and logs stay in this folder.
Stop-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'Plex Library Helper' -Confirm:$false -ErrorAction SilentlyContinue
# and its tray icon
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Join-Path $PSScriptRoot 'tray.ps1')) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
'Plex Library Helper stopped and removed from startup. Delete this folder to remove it completely.'
