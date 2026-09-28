# Plex Library Helper

**What it is:** a small background program that does file work for the Plex Library Dashboard.
The dashboard (on your PC or phone) can only *ask* for a job. This helper runs on your PCs and does
the actual work. **It's the same download for every PC**; setup asks what each PC should do.

**What it does**
- **Quarantine** (every PC): moves a copy's files into `_TO_DELETE\<date>\` on the same drive
  (for example `E:\_TO_DELETE\2026-09-26\...`).
- **Compress** (every PC you say yes on): makes a smaller copy of a movie and adds it next to the original.
  It uses the graphics card when there is a suitable one (AMD, NVIDIA or Intel, including the Intel
  graphics in small PCs like an N100 file server) and otherwise the processor, which is much slower. Whichever
  PC that can do a job is free first takes it, so a file server can work through the queue while your main
  PC is busy.

**What it never does:** delete anything, change an original when compressing, touch files that aren't
on this PC's drives or your shares, move a drive, share or category folder (like `E:\Movies`) as a
whole, or open anything up to the internet. It only talks to your Plex server over your home network,
and to plex.tv.

## Setting it up (each PC)

Download **`Plex-Library-Helper-<version>.exe`** from the dashboard and run it. It's one small file (no
administrator rights needed): it installs itself in `%LOCALAPPDATA%\Plex Library Helper`, adds an icon next to
the clock, and opens setup:

1. **Welcome**: shows this PC; if you used the older zip version, it moves that copy's Plex sign-in and settings
   over (nothing to redo; it waits if that copy is in the middle of a compression).
2. **Plex sign-in**: approve *Plex Library Helper* on Plex's page in your browser.
3. **Compression**: on or off for this PC; installs what's missing (ffmpeg, MKVToolNix, dovi_tool) with one
   click each, tests which encoders work (graphics card and processor), whether to take processor-only jobs,
   the work folder, and whether to run the benchmark straight away.
4. **Phone & dashboard**: phone notifications through ntfy, with **QR codes** to scan: one subscribes your
   phone, one opens the dashboard already connected. A PC without its own notifications (like a file server)
   joins the main PC's topic instead (paste it; Settings shows it on the main PC).
5. **MakeMKV rips** (only if MakeMKV is installed).
6. **Finish**: starts the helper now and whenever you sign in to Windows.

**Updating:** the app checks the dashboard's site for new versions (a couple of minutes after it starts, then
every 6 hours). You choose in setup or Settings > Updates:
- **Ask me first** (default): the tray and the Overview say *Update available*, and nothing changes until you
  click Install.
- **Install automatically when idle**: it installs by itself, but never while a compression, estimate or
  benchmark is running.

Each download is checked against the SHA-256 fingerprint published with it and refused if it differs. Running a
newer exe by hand also works (it replaces the installed one). Running the exe again any time just opens the app.

## The app

Double-click the icon next to the clock (or run the exe again):
- **Overview**: is the helper running, Pause all compressions, and every running compression, estimate and
  benchmark with a live progress bar, time left and why it's paused; MakeMKV rips too.
- **Encoders & benchmark**: each encoder's measured speed and the setting it uses for each quality level;
  Run / Stop benchmark.
- **_TO_DELETE**: what's waiting on this PC's drives, and Empty (type DELETE to confirm).
- **Settings**: change any setup step, restart the helper, open the logs, or Stop and remove.

The icon's colour shows the state (amber idle, green working, grey paused, red not running); right-click
for Pause, Run benchmark, Empty _TO_DELETE, Settings, Restart and Quit. If the helper stops without you
choosing Quit, the app starts it again after 2 minutes. Windows may show a balloon when a job finishes.

**Pause all compressions** (app, tray or dashboard > Jobs) freezes a running encode where it is and holds the
queue until you resume; nothing is lost.
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

## Benchmark (measuring each PC)

Encoders differ a lot: the same setting gives a different quality and size on an AMD, NVIDIA or Intel
graphics card or on the processor, and speed depends on the PC. So each compressing PC measures its own
encoders on two of your films (a 4K one and a 1080p one, preferring disc rips on its own drives): short
samples at five settings each, scored for quality (VMAF, the measure streaming services use), size and speed.
From that it works out the setting that reaches each quality level on this PC (4K High = VMAF 95, Normal
93.5, Data Saver 90, Extreme 96.5) and uses it for every job. A processor encoder that manages less than
0.6 frames a second on 4K is marked too slow there and not used for 4K.

- It runs **by itself** the first time a PC has encoders it hasn't measured, once nothing else is running
  and nobody has used the PC for 10 minutes; also when a new encoder appears (at most once a week).
- **Run it yourself** from the tray menu, setup, or the dashboard (Jobs > the PC > Run benchmark). It waits
  for running jobs to finish and holds new ones until it's done: about 20-60 minutes on a gaming PC,
  longer on a small one. It pauses for Plex streams and games like any job; Stop in the same places.
- The results go to the dashboard, which shows each PC's encoders and speeds and, in Compress, the size
  and time **on each PC** for every quality level. Your phone gets a short summary when it finishes.

**AV1** (Compress > Video format) makes files about a quarter smaller again at the same quality, but needs a
newer TV or player, and Dolby Vision becomes HDR10. Graphics cards from AMD RX 7000, NVIDIA RTX 40 and Intel
Arc up encode it quickly; otherwise it's done on the processor (SVT-AV1, slow).

## Phone notifications

When a compression or estimate finishes or fails, the helper sends a notification to your phone
through **ntfy** (free app, no account), even with the phone locked and the dashboard closed.
For example: *Compressed: Harry Potter and the Sorcerer's Stone (2001) · 4K High: 71.3 GB → 14.7 GB (21%)*.
Tapping it opens the dashboard.

1. In setup (or Settings > Phone & dashboard) choose **This PC sends notifications**, then **Set up my phone**.
   It makes a private topic like `pld-7f3k9q2m...` and shows it with a QR code.
2. On the phone: install **ntfy** (Play Store / App Store) and scan the code, or tap **+** in the app and enter
   the topic (server `ntfy.sh`). **Send a test notification** checks it works.

You also hear about **interruptions**: a compression that fails, or stops because the PC restarted
(reported when the helper starts again). If you said yes to **pause alerts**, you get a quiet
*Paused: … Plex is transcoding a stream* once a pause has lasted 2 minutes (at most one every 30 minutes
per job), and *Resumed: … after 25 min paused, about 1 h left* when it carries on.

Only the movie title and the result are sent, through ntfy.sh; no file paths or Plex details. Keep the
topic name private: anyone who knows it can read the messages. Settings > Phone & dashboard turns it off,
and has **Copy topic** if you need it again.

## Files in this folder

| File | What it's for |
|---|---|
| `Plex Library Helper.exe` | The app: setup, status windows, tray icon; carries the rest |
| `library-helper.ps1` | The helper itself (the engine, runs hidden) |
| `api.ps1` | What the app's windows ask the engine to do |
| `compress.ps1` | Does one compression, estimate or benchmark (started by the helper) |
| `encoders.ps1` | The encoders it knows (AMD, NVIDIA, Intel graphics; x265, SVT-AV1 on the processor) and how it picks one |
| `bench.ps1` | The benchmark: which films, when it runs, saving the results, telling the dashboard |
| `install-helper.ps1` / `uninstall-helper.ps1` | Add it to / remove it from Windows startup |
| `config.json` | Created by setup: your server and Plex sign-in (encrypted for your Windows user), compression settings |
| `logs\helper-YYYYMMDD.log` | Everything it did, one file per day |
| `jobs\` | Compression jobs this PC ran: settings, progress and a log for each |
| `tools\` | dovi_tool, if setup downloaded it |

## Command line (optional)

```powershell
powershell -ExecutionPolicy Bypass -File library-helper.ps1 -Setup             # the old text setup
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
`<topic>-status` topic nobody's phone subscribes to), so each device needs to know the topic once: scan the
dashboard QR code from setup (`…/#ntfy=pld-…`) on it, or paste the topic under **Jobs**.

**Compress when finished** (optional, per rip on the card; default and presets chosen in setup): once the
file has stopped growing, the helper asks Plex to scan it and queues a compression, 4K discs and Blu-rays
with their own preset. Movies only: MakeMKV names TV episodes by title number, so name them first and
compress the season from the show. DVDs are left as they are.

## Emptying _TO_DELETE

Quarantined files stay in `_TO_DELETE` until you empty it. In the app on the PC that owns the drive
(quarantined files stay on their own drive), **_TO_DELETE** lists every batch by drive and date with its size
and the movies in it; choose batches and **Empty…**, then type `DELETE`. It only removes the dated folders
inside `_TO_DELETE`, skips anything containing a link to another folder, and records each deletion in
`manifest.jsonl`. The tray menu goes to the same page.

**From the dashboard:** Jobs lists what's waiting in `_TO_DELETE` on each connected PC, with **Empty…**
(choose batches, type `DELETE`). The helper on that PC deletes only the dated batches it reported, only
for a request less than 10 minutes old that it hasn't carried out before, and your phone gets a note of
what was freed. A PC appears there once its helper is connected to the dashboard's ntfy topic: setup
asks (on a PC without its own notifications, paste the topic from your main PC).

## Putting something back

Every move is recorded in `_TO_DELETE\manifest.jsonl` on that drive (`from` → `to`). Move the
folder or file back to its `from` location and rescan the library in Plex.
