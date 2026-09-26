# Plex Library Helper

**What it is:** a small background program that moves files for the Plex Library Dashboard.
The dashboard (on your PC or phone) can only *ask* for a job. This helper runs on the PC that
owns the drives and does the actual work.

**What it does:** when you choose **Quarantine** in the dashboard, the helper moves that copy's
files into `_TO_DELETE\<date>\` on the same drive (for example `E:\_TO_DELETE\2026-09-26\...`).

**What it never does:** delete anything, touch files that aren't on this PC's shared drives,
move a drive, share or category folder (like `E:\Movies`) as a whole, or open anything up to the
internet. It only talks to your Plex server over your home network, and to plex.tv.

## How it gets jobs

There's no separate server. The dashboard puts a short label on the movie in Plex
(`pld:...:queued`). Every 20 seconds the helper asks Plex for those labels, does the job, and
updates the label to `done` or `fail`, which the dashboard's **Jobs** panel shows. Only your
Plex account can add labels to your library, so only you can queue jobs.

## Double-click these

| File | What it does |
|---|---|
| `1 - Set up (sign in to Plex).cmd` | First time on a PC: signs the helper in to Plex (approve the page it opens) |
| `2 - Start with Windows.cmd` | Starts the helper now and whenever you sign in to Windows |
| `Check status.cmd` | Is it running, which server and drives it handles, which jobs it can see |
| `Stop and remove.cmd` | Stops it and removes it from startup (asks first) |

`.ps1` files open in Notepad when double-clicked; that's Windows' default. Use the `.cmd` files above.

## Files in this folder

| File | What it's for |
|---|---|
| `library-helper.ps1` | The helper itself |
| `install-helper.ps1` | Start the helper automatically whenever you sign in to Windows |
| `uninstall-helper.ps1` | Stop it and remove it from startup |
| `test-helper.ps1` | Checks the quarantine rules on throwaway folders (touches nothing real) |
| `config.json` | Created by setup: your server and Plex sign-in (encrypted for your Windows user) |
| `logs\helper-YYYYMMDD.log` | Everything it did, one file per day |

## Common tasks

```powershell
# First time on a PC: sign in with Plex (approve the link it opens)
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -Setup

# Start automatically with Windows
powershell -ExecutionPolicy Bypass -File install-helper.ps1

# See what it's connected to and which jobs it can see
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -Status

# Stop it / remove from startup
powershell -ExecutionPolicy Bypass -File uninstall-helper.ps1
```

It also appears in **Task Scheduler** as *Plex Library Helper*, and in Plex under
**Settings → Authorized Devices** as *Plex Library Helper*. Removing it there revokes its access.

## Putting something back

Every move is recorded in `_TO_DELETE\manifest.jsonl` on that drive (`from` → `to`). Move the
folder or file back to its `from` location and rescan the library in Plex.
