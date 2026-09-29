# Plex Library Dashboard — notes for Claude

Read this first. If `private/HANDOFF.md` exists, read it too: it has the owner's machine names,
drives and network details (never commit it; `private/` is gitignored).

## What this is

A static website (GitHub Pages, no build step) that shows every movie/show across the user's
Plex servers Steam-library style: which drive each copy is on, quality badges, duplicates,
Fix Match, and quarantine actions. Plus the **Plex Library Helper** (`helper/`), a PowerShell
background program on each PC that does file work the website can't.

- `index.html`, `css/styles.css`, `js/*.js` (ES modules, no framework, no bundler)
  - `plex.js` — Sign in with Plex (PIN flow; popup + polling, same-tab fallback), server discovery
    (local → remote → relay), library reads, labels, Fix Match calls
  - `model.js` — merges copies across items/servers by TMDB/IMDb/TVDB id, quality detection,
    `score()` ranking ("highest quality"), locations from file paths
  - `jobs.js` — job queue carried in Plex labels (see below); `DemoJobs` for `?demo`
  - `compress.js` — compression presets, label option/progress formats, rough size/time guesses
  - `notify.js` + `/sw.js` — "done" notifications for compress/estimate jobs (browser Notification API,
    via the service worker because Android Chrome requires it; `sw.js` caches nothing) and in-page
    toasts. Owner chose browser notifications only (no phone push service, no Windows toasts).
    Finished jobs are spotted by comparing with the states remembered at the previous refresh
    (`lastStates`), not `before`: demo jobs mutate in place.
  - `app.js` — UI, filters, detail view, confirm dialogs, jobs panel, Fix Match dialog
  - `cache.js` — IndexedDB snapshot per server (offline servers show "last seen")
  - `demo.js` — sample data; open `?demo` to test UI without Plex
- `helper/compress.ps1` — compression worker, one process per job (see Compression below)
- `helper/library-helper.ps1` — Windows PowerShell 5.1. `-Setup` (guided: Plex sign-in, "Use this PC for
  encoding / compression?" with tool installs, start with Windows; re-runnable), `-Status`, `-Once`,
  `-EnableCompress`, default loop (re-reads config.json every poll). Double-click `.cmd` launchers for
  users. `test-helper.ps1` = offline tests (must stay passing).
- **One download for every PC:** `download/Plex-Library-Helper-<version>.zip` + `download/latest.json` (the dashboard's link reads it), built by `make-helper-download.ps1`
  (forward-slash entry names, CRLF `.cmd`). **Rebuild and commit it whenever `helper/` changes**; the
  dashboard links to it (relative URL, served by Pages).
- `serve.ps1` / `Start Dashboard.cmd` — tiny local static server on http://localhost:5173/
  (the desktop app's preview config is `plex-dashboard` in `Documents\Claude\.claude\launch.json`)

## Job mailbox (no backend)

The dashboard adds a label to the movie in Plex: `pld:<jobId>:<action>:<mediaId>:<state>[:<info>]`.
Helpers poll Plex every 20 s over the LAN, claim jobs whose files are on *their* drives (UNC share
→ local path map from `Get-SmbShare`, or local drive paths when Plex runs on that PC), do the work,
and swap the label to `run` → `done:<bytes>` / `fail:<reason>`. Finished labels are removed after 24 h.

- `q`  = quarantine (move to `<drive>:\_TO_DELETE\<date>\...`, same volume, never delete).
  Helper refuses if no *other* copy of the item still exists on disk (checkFiles) → "last-copy guard".
- `qa` = same, guard skipped; dashboard sends it only when the surviving copy is in another Plex
  item/server (it verified via checkFiles) or the user explicitly confirmed quarantining the last copy.
- Every move is logged to `_TO_DELETE\manifest.jsonl` (from/to) for restore.

## Hard-won gotchas (don't regress these)

- **PS 5.1 `ConvertFrom-Json` fails on Plex JSON** (keys differing only by case: `guid`/`Guid`,
  `rating`/`Rating`). `Pms` uses `JavaScriptSerializer` → results are dictionaries; use
  `$x.Key` access and `Where-Object { $_.prop ... }` scriptblocks (not `Where-Object prop -eq`).
- **Plex capitalises label tags on items** (`Pld:`). Parse prefixes case-insensitively everywhere.
- **Label swaps: add new first, then remove old** — otherwise a failure mid-swap loses the job.
- **Never rank a missing file as best.** Dashboard asks Plex `checkFiles=1` when a movie opens;
  missing copies get `missing`, `score()` returns -1, actions stay disabled until checked.
- **Variable names are case-insensitive in PowerShell** (`$f` == `$F`). Bit us once.
- `[math]::Min(1MB, $long)` picks the Int32 overload → overflow on >2 GB files. Cast to `[long]`.
- **AT&T gateways block `*.plex.direct` DNS answers for private IPs** (rebinding protection) →
  "unable to connect securely". Fix on the *client*: set DNS to 1.1.1.1 / 8.8.8.8 for IPv4 **and**
  IPv6 (Windows prefers the gateway's IPv6 DNS). Phones: Android Private DNS `dns.google`.
- The page drops `http://` connections when served over https (mixed content); plex.direct https
  or relay are used instead.
- WD external enclosures may present 4K logical sectors; NTFS formatted there won't mount at 512.

## Working style the owner expects

- Explain the plan and wait for a go-ahead before destructive or long-running work.
- Verify before and after every file operation (sizes, sampled hashes); never hard-delete —
  quarantine or move to a folder the owner deletes.
- Push notifications at checkpoints and on any error when running long jobs.
- Test in `?demo` and with `test-helper.ps1`; syntax-check PowerShell with the AST parser.

## Compression (version 0.3)

**Compress…** on a movie copy → dialog (preset, audio, pause rules, *Estimate first*) → label
`pldc:<id>:c|ce:<mediaId>:queued:p=4kh;a=keep;r=plex+game`. Own prefix so helpers < 0.3 ignore it
(they'd fail unknown `pld:` actions). Only a helper with `-EnableCompress` (the gaming PC) claims them;
it reads the file from its own drive or over SMB and starts `helper/compress.ps1 -JobFile jobs\<id>.json`
as a separate process. Worker ↔ helper talk through `jobs\<id>.status.json` (+ `.cancel`, `.log`).
Running label info: `run:<pct>;<secsLeft>;<phase|paused: why>;<preset>`, updated ≤ once a minute.
Dashboard "Stop" swaps the state to `stop`; helper drops a `.cancel` file.

Pipeline (compress.ps1): probe → [GPU+DV: ffmpeg | dovi_tool -m 2 extract-rpu (P7/P8 → 8.1)] →
encode (AMF: d3d11va decode, raw .hevc; x265: video-only .mkv) → dovi_tool inject-rpu → mkvmerge
(original audio/subs/chapters) → verify (frames = encoder's count, video length vs source, DV present,
track counts, test-decode start and end) → copy to `<Title> (<Year>) - Compressed <preset>.mkv` next to
the original (or a new `<Title> (<Year>)\` folder when the original is loose in e.g. `E:\Movies`) →
helper asks Plex to rescan. Original never touched; "Replace original…" on the compressed copy is the
normal quarantine flow. Estimate = 3 samples (20/50/80%), VMAF against the same scaling/tone-mapping.

Test results that set the presets (Jurassic World Rebirth 4K DV P7 remux; Black Hawk Down for grain):

| Preset | Encoder | Clean film size / VMAF | Speed |
|---|---|---|---|
| 4K Extreme | x265 slow CRF 18 | 20% / 95.6 | ~1 fps (≈2 days/film) |
| 4K High | AMF CQP 20 | 27% / 94.9 (96.9 on another scene) | ~30 fps (≈1.5 h) |
| 4K Normal | AMF CQP 22 | ~20% / ~94 | ~30 fps |
| 4K Data Saver | AMF CQP 26 | ~10% / ~89 | ~30 fps |
| 1080p High/Normal/Saver | AMF CQP 20/22/24, HDR→SDR (zscale+hable) | 9% / – / 5% | ~24 fps (CPU tone-map) |

Grainy film: AMF QP20 came out **bigger than the source** at VMAF 84; x265 medium 48% at 80. Hence
"Estimate first". x265 *medium* was barely better than AMF per GB at 10× the time, so it's not a preset.

Pause rules (worker, every 5 s; NtSuspendProcess on ffmpeg, resume after 30 s clear): `plex` (Plex
`/status/sessions` size > 0, fallback: Plex Transcoder process), `game` (foreground window covers its
monitor), `idle` (GetLastInputInfo < 10 min), `night` (config `compress.nightWindow`, default 23:00-07:00).
Even at Idle priority a 16-thread x265 encode made a Plex transcode stutter; GPU encodes with GPU
decode use ~2 s CPU per 20 s clip.

The owner's LG C1 plays Dolby Vision (not HDR10+). DV 8.1 playback of a compressed MKV on the C1 via
Plex was **not yet confirmed** (test clip `G:\PLEX\MOVIES\Compression Test DV (2025)\`; remove after).

Real jobs (2026-09-26): Harry Potter 1 disc rip, 4K High + smaller audio: 76.6 GB → 15.8 GB (21%),
encode 1 h 02 min at 59 fps (GPU decode doubled the test speed), whole job 1 h 18 min.
Pirates 3 estimate (4K High): 56% at VMAF 95.3 (grainier film).
Pause rule changed after a night paused by a Chromecast direct play + a *paused* tablet session:
`plex` now = only while Plex is **transcoding** (videoDecision=transcode, playing), `plexall` = any
playing session; paused sessions never count.
Pre-flight (start of every compress): write test + free space (GetDiskFreeSpaceEx, works on UNC) in the
original's folder and the work folder. It found that LENOVOLEGION (connects as `BEELINK-MINI\John`)
**can't write to `\\BEELINK-MINI\PLEX Server`**: the share needs Change permission for John before
Beelink movies can be compressed.

Phone notifications (helper 0.3.3): owner chose **ntfy** over Web Push (browser notifications only fire
while the page is awake; Android freezes background tabs). Config `notify = { enabled, server, topic }`
(topic `pld-` + 20 random chars, made in `-Setup` → `Setup-Notifications`, only on the compressing PC).
`Notify-Job` runs after the label is set to done/fail and never throws; JSON publish to the server root
as UTF-8 bytes (PS 5.1 mangles non-ASCII otherwise); `click` = `$DashboardUrl`. No message for jobs
stopped from the dashboard. ntfy.sh is unreachable from Claude's sandbox (TLS fails), so live sends were
never tested from there: the setup's test message is the end-to-end check.

Pause alerts (`notify.pauses`, default on): `Track-Pause` in the helper's running-job branch, alert once
a pause has lasted `$PauseAlertAfter` (120 s), at most every `$PauseAlertEvery` (30 min) per job; "resumed"
only after a "paused". Low priority; failures are high.

Emptying `_TO_DELETE` (`-EmptyTrash`, `Empty _TO_DELETE.cmd`): owner asked for it; deliberately **local and
interactive only** (the dashboard can't see inside `_TO_DELETE`, and permanent deletion shouldn't be
remotely triggerable). Deletes only `<drive>:\_TO_DELETE\yyyy-MM-dd` batches, skips batches containing
reparse points, logs `{deleted, bytes, titles}` lines in manifest.jsonl.

### Shows (helper 0.3.4)

Episodes can't carry labels, so show jobs are labels **on the show** (Plex type 2; tested: labels on shows
work, capitalised like movies, 600+ characters stored intact). Old helpers scan movie sections only, so
they never see show jobs: the Beelink's helper must be updated before show quarantines on its drives run.
- Quarantine: `pld:<id>:qm|qma:sh<showKey>:<state>:ids=<media>+<media>...;n=..;s=<scope>`, one label per
  drive (dashboard groups by `v.loc`), ≤40 ids each. `qm` = guarded (keep-best, replace-originals: each copy
  only moves if another copy of that episode exists and isn't targeted), `qma` = season/show removal.
  Scopes: `all`, `S02`, `dupes-S02`, `dupes-S01E03`, `replace-S02`. Done info `b,f,n,s,x` (x = first problem).
  `Quarantine -Episode` never moves a folder (season folders are shared and episodes are < 300 MB) and
  only takes sidecars named exactly `<episode>.*`.
- Compress: `pldc:<id>:c|ce:sh<showKey>:queued:p=..;a=..;r=..;s=S02|all`. Helper builds `items` (per
  episode the biggest non-compressed copy; skips episodes that already have a `- Compressed` copy);
  worker `Run-Episodes` does them in turn (one failing doesn't stop the rest), output
  `<Show> (<Year>) - S02E05 - Compressed <preset>.mkv` next to the episode. `Estimate-Episodes` samples
  first/middle/last episode (skips unreadable ones) and scales by running time. Run info has a 5th
  field (scope); done info adds `c` (episodes), `n` (done), `f`, `w` (scope), `x`.
- Dashboard: season cards (Compress…, Replace N originals with compressed, Keep best, Quarantine…),
  show-wide versions, missing-episode gaps (`missingText`), job progress on the show.

### MakeMKV rip progress (helper 0.3.5-0.3.6; **this PC routes everything through a Surfshark WireGuard VPN, which breaks TLS to ntfy.sh**: needs ntfy.sh in Surfshark Bypasser. `Test-Ntfy` explains this in setup/status. A new rip folder is not in MakeMKV's MRU until the rip ends: use the window's output file, `helper/rips.ps1`, `js/rips.js`)

Owner chose: watch normal MakeMKV GUI rips (no helper-driven ripping), movies and TV, ntfy as the channel,
optional auto-compress. Watcher runs every poll (`Rip-Poll`): MakeMKV running → `.mkv` files growing
in MakeMKV's destinations (`HKCU:\Software\MakeMKV` `path_DestDirMRU` + `app_DestinationDir`; also holds
the licence key: never print it) → status. Progress: MakeMKV's Qt progress bars via UI Automation
(`MakeMkv-Progress`: **works** on MakeMKV 1.17.7: bars plus label/value texts, incl. "Output file :" and "Source size :", which are used first) else file size vs disc titles (`Get-DiscTitles`: MPLS
parser for BDMV, VTS sizes for DVD; `Expected-Bytes`: movie disc = longest title, else median).
A file quiet for 90 s is done. Status JSON → `<topic>-status` (priority 1); dashboard polls the last 2 h
then streams `/sse`; `{"cmd":"autocompress","id","on"}` ← `<topic>-cmd`. Auto-compress: Plex scan, find the
item among the 40 newest, queue `pldc:...:c:` with `rip.preset4k` / `rip.presetHD` (movie libraries only).
The dashboard learns the topic from `#ntfy=` (setup's `Dashboard-Link`) or pasting in Jobs (localStorage).
This PC: disc drive F:, MakeMKV 1.17.7, rips into `G:\PLEX\MOVIES\<Title (Year)>` / `G:\PLEX\TV\...`.

### Live channel, pause, tray (helper 0.3.7, `helper/live.ps1`, `helper/tray.ps1`)

One ntfy topic pair per household: `<topic>-status` (helper -> dashboard: kinds `helper`, `trash`, `trashResult`,
`rip`, each with `pc`) and `<topic>-cmd` (dashboard -> helpers: `pause`, `emptytrash`, `autocompress`; each helper
acts only on its own `pc`). `Live-Poll` each poll: writes `state.json` (tray), reads commands, publishes helper
status on change / every 5 min and the trash summary on change / every 15 min. Pause = file `jobs\PAUSED`:
no job starts, and compress.ps1's `Pause-Reason` freezes the running encode (resumes within ~5 s). Remote
empty: request must name this PC, be < 10 min old (ntfy replays old messages to a restarted helper), not be
in `jobs\done-requests.txt`, and only batches the helper itself lists are deleted. The Beelink joins via
`Setup-Channel` (paste the topic). Tray: WinForms NotifyIcon in its own STA PowerShell, started by the
helper (`Start-Tray`), one per folder (mutex), reads `state.json` every 3 s; tooltip max 63 characters. Watchdog (0.3.8): helper dead (no live pid or state.json
older than 3 min) for 2 min and the tray still running (= you didn't Quit) -> `Restart-Helper`, at most every 10 min.
`Restart-Helper` waits for the task to really stop before starting it: starting too early is ignored (task runs
one copy), which left the helper stopped on 2026-09-27 (exit 0xC000013A).
Gotcha: a test helper function named `Cmd` hijacked `cmd /c` (names are case-insensitive): don't.

### Any PC, several encoders, benchmark (helper 0.3.9: `helper/encoders.ps1`, `helper/bench.ps1`)

Owner asked to open compression up beyond the AMD gaming PC (NVIDIA, more CPU options, the N100 NAS) and chose:
AV1 as an option, auto-calibration, routing "always whichever is free". `encoders.ps1`: registry (amf, nvenc, qsv,
x265, x265slow, av1_amf, av1_nvenc, av1_qsv, svtav1) with sweep ranges and default settings; `Test-Encoders` (0.5 s
lavfi encode each, in setup); `Choose-Encoder` (graphics first; Extreme -> efficient CPU encoder if `allowCpu`;
calibrated setting else default; encoders the benchmark marked `skipped` for that tier are left out). Every PC with
compression on claims any job it can do when free (no central scheduler). Done labels carry `m=<PC>;e=<enc>[;v=av1]`.

Benchmark (`mode: benchmark` in compress.ps1, `Run-Benchmark`): per tier (4K, 1080p) a film from `Find-BenchSources`
(Plex movies > 1 h, not compressed, local first then highest bitrate; worker takes the first candidate that isn't DV P5
or short); 3 x 8 s samples for GPU encoders, 3 x 2 s for CPU; 5 settings each; VMAF, kbps, fps (paused time excluded);
CPU encoders under 0.6 fps are skipped. `Interp-Level` picks the setting for each target (`$QualityTargets`: extreme
96.5, high 95, normal 93.5, saver 90). `Bench-Poll` (every helper loop): saves `compress.calibration.<enc>.<tier>`,
phone summary, starts requested runs (`jobs\BENCHMARK`, from tray/setup/dashboard `{"cmd":"benchmark","pc"[,"stop"]}`)
once no worker runs; auto-runs when encoders are unmeasured and the PC has been idle 10 min (retry after 7 days).
`Bench-Holding` stops new compress claims while a benchmark waits or runs. Publishes `kind: caps` (cpu, gpus,
encoders, allowCpu, compact calibration: `q`/`kbps` arrays in level order, fps, skip) on change and hourly; the
dashboard (`rips.caps()`, `cz.pcGuesses`) shows per-PC encoder/speed in Jobs and per-PC size/time in Compress.

**VMAF pairing bug (fixed 0.3.9):** libvmaf pairs frames by timestamp; the `-c copy` sample and its encode start at
different timestamps, so it compared neighbouring frames and scored ~10 low (AMF q20: 83.5 instead of 96.8). Both
inputs now go through `setpts=N`. Estimates from earlier helpers may have under-reported quality.
First real calibration on this PC (Transformers 1986 4K): AMF q20 = VMAF 96.4 at 52 fps; x265 medium CRF 16 = 96.2.

### The app: one exe (0.4.0, `app/`)

Owner asked to replace the command prompts with a premium UI, one file. `app/` = C# WPF for **.NET Framework 4.8**
(in every Windows 10/11, so the exe is ~375 KB and needs nothing installed); the PowerShell engine rides inside
as embedded resources (`engine/*`). Build: `make-helper-download.ps1` (needs the .NET 8 SDK; on this PC it's in
`%LOCALAPPDATA%\Microsoft\dotnet`, installed with dotnet-install.ps1 because the winget one sat at its UAC prompt)
-> `download/Plex-Library-Helper-<ver>.exe` + `latest.json`. Version comes from `$Version` in library-helper.ps1.
- Exe run from anywhere installs/updates itself into `%LOCALAPPDATA%\Plex Library Helper` (copies itself, unpacks
  the engine, writes VERSION.txt) and starts the installed copy. One instance per user (mutex + Show/Quit events).
- The scheduled task still runs the engine (`library-helper.ps1`, hidden); `Start-Tray` launches `Plex Library
  Helper.exe --tray` when present (tray.ps1 only for zip installs). The app's tray = old tray + watchdog + balloons.
- Windows never change settings themselves: `library-helper.ps1 -Api <cmd>` (`helper/api.ps1`), args in env
  `PLH_API_ARGS`, output lines `@@PROGRESS/@@ASK/@@RESULT/@@ERROR`. Commands: info, takeover (old zip copy's
  config + dovi_tool), signin (`Plex-SignIn`, keeps other settings; ASK for server choice), testencoders,
  installtool, savecompress, savenotify, sendtest, saverip, installtask, uninstall, trash, emptytrash.
- Progress bars read `jobs\*.json` + `.status.json` directly every 2 s (state.json is only every 20 s).
- Updates: engine exits when VERSION.txt != its `$Version` and no worker runs; the tray restarts it at once.
- QR codes (`QrCode.cs`, byte mode, ECC M, v1-10) verified by decoding with jsQR.
- Testing: `PLH_HOME=<folder>` = test install (no watchdog, never touches the scheduled task); `--snapshot <dir>`
  renders every page/step to PNG; `--qr <text> <png>`. Setup flow was driven end to end with UI Automation.
- Updater (0.4.1, `Updater.cs`): reads latest.json 2 min after start then every 6 h; `app.json` `updates` = ask
  (default; owner: end users may not want auto-updates on a Plex machine) | auto (installs only with no worker
  running). Downloads to %TEMP%, requires `sha256` (written by make-helper-download.ps1) to match, runs it with
  `--tray --updated`; the new exe installs itself (Quit event to the old one) and says "updated" in the tray.
  Tested end to end in a test install (0.4.1 -> 0.4.2 in ~6 s; a wrong fingerprint is refused and deleted).
  Test hooks: `PLH_UPDATE_URL`, `PLH_UPDATE_FIRST` (seconds); a PLH_HOME install has its own single-instance lock.
- Not yet: code signing (SmartScreen warns on the first manual download: More info > Run anyway).

### qBittorrent (0.4.2, `helper/torrent.ps1`, `helper/pause.ps1`)

Owner's scope: download status and auto-slowing only; **never search/add torrents** (no Radarr-style fetching).
Owner chose: slow down (qBittorrent's alternative speed limits = turtle, `transfer/toggleSpeedLimitsMode`) not
pause; the same rule set as compressions, chosen in setup (defaults plex + game); Web UI with localhost auth bypass
(no stored password). qBittorrent 5.0.4 on LENOVOLEGION, saves to D:\, Web UI was off (setup's
`Qbt-EnableWebUi` edits `%APPDATA%\qBittorrent\qBittorrent.ini` [Preferences] WebUI\Enabled/Address=127.0.0.1/
Port/LocalHostAuth=false; only while qBittorrent is closed; backup `.before-plex-library-helper`).
- `pause.ps1` = the pause rules moved out of compress.ps1 (PldWin, In-Window, Plex-Activity, Pause-Reason with a
  `$holdFile` parameter: compressions jobs\PAUSED, torrents jobs\TORRENTS-HOLD).
- `Torrent-Poll` each helper loop: turtle on when a rule applies (remembered in jobs\torrents-slowed.txt), off 30 s
  after it clears, only if it was ours; user switching it off wins until the rule clears. POSTs need a Referer
  (qBittorrent CSRF check). PS 5.1 `ConvertFrom-Json` returns an array as one item: unroll with ForEach-Object.
- Publishes `kind: torrents` (on change / every minute while downloading); state.json `torrents`; dashboard
  `#torcard`; command `{"cmd":"torrents","pc","hold"}`. The app reads qBittorrent's API itself for 2 s progress.
- Tests: `helper/tests/test-torrent.ps1` (19, against `fake_qbt.py`, never the real qBittorrent). test-helper.ps1
  now checks the exe/download carry every engine file (pause.ps1/torrent.ps1 were missed once).

### ntfy message budget (0.4.3)

**ntfy.sh allows ~250 messages a day per internet connection** (both PCs share the home IP). From 12:45 on
2026-09-28 every publish got 429: the 5-min heartbeat alone was 288/day, rip progress went out every poll, trash
every 15 min. Now: helper status only on job start/finish/pause + hourly (job % comes from Plex labels; the
dashboard's helper line takes % from the label); rips at once on start/next file/done, else every 3 min; trash
and caps on change + every 6 h; torrents on state changes, progress every 20 min while downloading, else hourly.
After a 429, `Publish-Live` stays quiet for 30 min (`$script:NtfyQuietUntil`) so phone notifications get the
rest. Dashboard reads `since=12h` (ntfy.sh keeps 12 h), PCs count as silent after 70 min, rip card "No update"
after 8 min, qBittorrent card hidden after 70 min. Busy day estimate: ~150-190 for both PCs.
Measured 2026-09-29 (ntfy `/v1/account`: basis ip, 250/day, 0 left by 07:12 local; the day resets at 00:00 UTC):
in 8 h ntfy held 94 heartbeats from the **Beelink (still 0.3.7, every 5 min = ~270/day on its own)**, 48 from this PC
(mostly the 0.4.0 benchmark reporting every step; 0.4.3 = ~1/hour) and 8 phone notifications. The Beelink must run
0.4.3+. **Dashboard commands never worked before 0.4.4:** PS 5.1 returns ntfy's `/json` list (application/x-ndjson)
as `byte[]`, so `.Content -split` found nothing; `Web-Text` decodes it. Test fakes must return bytes like the real one.
The steps after an encode are named "Finishing up: ..." (with a log line each; they take 20-40 min on 4K films:
audio, mkvmerge, verify, copy); the app and dashboard add "the last steps can take 20-40 min".

### Compression gotchas

- **GPU frames dropped** with `-hwaccel_output_format d3d11`: "Static surface pool size exceeded" → ffmpeg
  silently skipped ~20% of frames on some files (the frame-count check caught it). Fixed with
  `-extra_hw_frames 16`. Jobs before helper 0.3.4 can fail their final check because of this.

- **`[math]::Min(1, 0.37)` returns 0** (Int32 overload, same trap as the 1MB one below): this kept GPU
  progress at 0% until the end. Use `1.0` / `[double]` in Min/Max.
- AMF `-rc qvbr` ignores bitrate limits on this driver (output 2.7× the source). Use `-rc cqp`.
- AMF `-usage high_quality` / `-preanalysis` fail to init on RDNA2.
- AMF labels 10-bit output "Main" unless `-profile:v main10` is set.
- x265 via ffmpeg: `-dolbyvision` "auto" silently drops DV; force `1`, which also needs VBV
  (`vbv-maxrate/bufsize`), else "Dolby Vision requires VBV settings to enable HRD".
- DV profile 5 (IPT, streaming) is refused: re-encoding/tone-mapping its base layer would be wrong colours.
- MKV `NUMBER_OF_BYTES` / `DURATION` tags survive `-c copy` cuts (wrong for clips); `BPS` stays right.
- Audio can outlast video; compare *video* length (last video packet), not the container duration.
- Tone-mapped SDR output kept HDR mastering metadata until the `sidedata=mode=delete` filters were added.
- VMAF needs timestamps: compare MKV samples, not raw .hevc (25 fps default).
- PS 5.1: `Split-Path -LiteralPath x -Parent` is a parameter-set error; use `[IO.Path]::GetDirectoryName`.
- PS: `R` is an alias (Invoke-History), so don't name helper functions `R`. `Start-Process` needs
  `$p.Handle` touched before exit or `ExitCode` is empty.
- Tools: ffmpeg (winget Gyan.FFmpeg), MKVToolNix, `tools\dovi_tool.exe` (official release from
  github.com/quietvoid/dovi_tool; `tools/` is gitignored).

### Next

- Set up the helper on LENOVOLEGION (`Set up Plex Library Helper.cmd`, answer yes) and run a real job
  through Plex. Update the Beelink's helper from the same zip (setup there skips compression: no AMD card).
- Confirm DV playback on the C1; then remove the test clip.
- Push the repo-root move + v0.3 once the owner says so (Pages URL changes to the repo root).
