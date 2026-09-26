# Stops the Plex Library Helper and removes it from startup. Your settings and logs stay in this folder.
Stop-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'Plex Library Helper' -Confirm:$false -ErrorAction SilentlyContinue
'Plex Library Helper stopped and removed from startup. Delete this folder to remove it completely.'
