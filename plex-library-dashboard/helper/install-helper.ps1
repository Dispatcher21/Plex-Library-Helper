# Starts the Plex Library Helper (hidden) whenever you sign in to Windows, and restarts it if it stops.
# Run once after "library-helper.ps1 -Setup". Remove with uninstall-helper.ps1.
$ErrorActionPreference = 'Stop'
$TaskName = 'Plex Library Helper'
$helper = Join-Path $PSScriptRoot 'library-helper.ps1'
if (-not (Test-Path (Join-Path $PSScriptRoot 'config.json'))) { throw 'Run library-helper.ps1 -Setup first.' }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helper`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Moves and quarantines files when you ask from the Plex Library Dashboard.' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
"Plex Library Helper installed and running. It starts whenever you sign in to Windows."
"Activity log: $(Join-Path $PSScriptRoot 'logs')"
