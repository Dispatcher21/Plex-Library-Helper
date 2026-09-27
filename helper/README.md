# Plex Library Helper

**What it is:** a small background program that does file work for the Plex Library Dashboard.
The dashboard (on your PC or phone) can only *ask* for a job. This helper runs on your PCs and does
the actual work. **It's the same download for every PC**; setup asks what each PC should do.

**What it does**
- **Quarantine** (every PC): moves a copy's files into `_TO_DELETE\<date>\` on the same drive
  (for example `E:\_TO_DELETE\2026-09-26\...`).
- **Compress** (only the PC you say yes on, which needs an AMD Radeon graphics card): makes a smaller
  copy of a movie and adds it next to the original.

**What it never does:** delete anything, change an original when compressing, touch files that aren't
on this PC's drives or your shares, move a drive, share or category folder (like `E:\Movies`) as a
whole, or open anything up to the internet. It only talks to your Plex server over your home network,
and to plex.tv.

## Setting it up (each PC)

1. Unzip the download anywhere that stays put (for example `Documents\Plex Library Helper`).
2. Double-click **`Set up Plex Library Helper.cmd`**. It:
   - signs in to your Plex account: a Plex page opens, approve *Plex Library Helper*;
   - asks **"Use this PC for encoding / compression?"** Say yes only on the PC with the AMD Radeon
     graphics card. It then offers to install what compression needs (ffmpeg, MKVToolNix, and
     dovi_tool for Dolby Vision; each only if you say yes) and asks for a work folder. A PC without an
     AMD card skips this and just does quarantines;
   - on the compressing PC, asks **"Send phone notifications?"**: it makes a private ntfy topic
     name, shows it, and can send a test message (see below);
   - starts the helper now and whenever you sign in to Windows.

Run it again any time to change the compression answer; you won't have to sign in again.

**Updating:** unzip the new download and run its setup. Over the old folder is tidiest, but if the
browser saved it as `Plex-Library-Helper (1)` that's fine too: setup sees the older copy, takes over its
Plex sign-in and settings (no sign-in needed), and switches Windows startup to the new folder; then you
can delete the old one. If the old copy is in the middle of a compression, setup says so and changes
nothing, so the encode isn't left running unattended: let it finish or Stop it in the dashboard first.

## Double-click these

| File | What it does |
|---|---|
| `Set up Plex Library Helper.cmd` | Setup (above); run again to change settings or after updating |
| `Check status.cmd` | Is it running, which server and drives it handles, compression on/off, which jobs it can see |
| `Empty _TO_DELETE.cmd` | Lists what's waiting in `_TO_DELETE` on this PC's drives (dates, sizes, titles) and deletes it for good only if you choose all / older than 7 days **and** type `DELETE` |
| `Stop and remove.cmd` | Stops it and removes it from startup (asks first) |

`.ps1` files open in Notepad when double-clicked; that's Windows' default. Use the `.cmd` files above.

## How it gets jobs

There's no separate server. The dashboard puts a short label on the movie in Plex
(`pld:...:queued`, or `pldc:...` for compression). Every 20 seconds the helper asks Plex for those
labels, does the job, and updates the label (progress, then `done` or `fail`), which the dashboard's
**Jobs** panel shows. Only your Plex account can add labels to your library, so only you can queue jobs.

## Compression details

Each compression runs as its own background program, so quarantines keep working meanwhile. It pauses
by itself while someone is watching Plex or a full-screen game runs (you choose per job). Its log is
`jobs\<job>.log`. The original is never changed: the compressed copy is added next to it, checked, and
replacing the original is a separate quarantine you choose in the dashboard.

## Phone notifications

When a compression or estimate finishes or fails, the helper sends a notification to your phone
through **ntfy** (free app, no account), even with the phone locked and the dashboard closed.
For example: *Compressed: Harry Potter and the Sorcerer's Stone (2001) · 4K High: 71.3 GB → 14.7 GB (21%)*.
Tapping it opens the dashboard.

1. Run setup on the compressing PC and answer yes to **Send phone notifications?**. It shows a topic
   name like `pld-7f3k9q2m...` and offers a test message.
2. On the phone: install **ntfy** (Play Store / App Store), tap **+**, enter that topic, keep the
   server as `ntfy.sh`, subscribe.

You also hear about **interruptions**: a compression that fails, or stops because the PC restarted
(reported when the helper starts again). If you said yes to **pause alerts**, you get a quiet
*Paused: … Plex is transcoding a stream* once a pause has lasted 2 minutes (at most one every 30 minutes
per job), and *Resumed: … after 25 min paused, about 1 h left* when it carries on.

Only the movie title and the result are sent, through ntfy.sh; no file paths or Plex details. Keep the
topic name private: anyone who knows it can read the messages. Run setup again to turn it off.
`Check status.cmd` shows the topic if you need it again.

## Files in this folder

| File | What it's for |
|---|---|
| `library-helper.ps1` | The helper itself |
| `compress.ps1` | Does one compression (started by the helper) |
| `install-helper.ps1` / `uninstall-helper.ps1` | Add it to / remove it from Windows startup |
| `config.json` | Created by setup: your server and Plex sign-in (encrypted for your Windows user), compression settings |
| `logs\helper-YYYYMMDD.log` | Everything it did, one file per day |
| `jobs\` | Compression jobs this PC ran: settings, progress and a log for each |
| `tools\` | dovi_tool, if setup downloaded it |

## Command line (optional)

```powershell
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -Setup             # same as the .cmd
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -Status
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -EnableCompress -WorkDir D:\_PLD_WORK
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -DisableCompress
```

It also appears in **Task Scheduler** as *Plex Library Helper*, and in Plex under
**Settings → Authorized Devices** as *Plex Library Helper*. Removing it there revokes its access.

## MakeMKV rip progress

On a PC with MakeMKV, setup asks **"Show MakeMKV rip progress on the dashboard?"**. You keep ripping in
MakeMKV exactly as before; the helper watches:

- which disc is in, and its titles' lengths and sizes (read from the disc);
- MakeMKV's own progress bars when its window lets other programs read them (exact %, whole rip);
- the file growing in MakeMKV's destination folder (bytes, speed, % estimated from the disc otherwise).

The dashboard shows a **Ripping** card (disc, folder, %, speed, time left), live, from anywhere, and your
phone gets one ntfy notification when a rip finishes. Progress travels through ntfy (a separate
`<topic>-status` topic nobody's phone subscribes to), so each device needs to know the topic once: open
the link setup prints (`…/#ntfy=pld-…`) on it, or paste it under **Jobs**.

**Compress when finished** (optional, per rip on the card; default and presets chosen in setup): once the
file has stopped growing, the helper asks Plex to scan it and queues a compression, 4K discs and Blu-rays
with their own preset. Movies only: MakeMKV names TV episodes by title number, so name them first and
compress the season from the show. DVDs are left as they are.

## Emptying _TO_DELETE

Quarantined files stay in `_TO_DELETE` until you empty it. Double-click **`Empty _TO_DELETE.cmd`** on
the PC that owns the drive (quarantined files stay on their own drive, so run it on each PC). It shows
every batch by drive and date with its size and the movies in it, then asks: **A** all, **O** only
batches older than 7 days, or **N** nothing; deleting also needs you to type `DELETE`. It only removes
the dated folders inside `_TO_DELETE`, skips anything containing a link to another folder, and records
each deletion in `manifest.jsonl`. This can't be done from the dashboard, on purpose.

## Putting something back

Every move is recorded in `_TO_DELETE\manifest.jsonl` on that drive (`from` → `to`). Move the
folder or file back to its `from` location and rescan the library in Plex.
