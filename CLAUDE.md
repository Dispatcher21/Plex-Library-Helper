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
  - `app.js` — UI, filters, detail view, confirm dialogs, jobs panel, Fix Match dialog
  - `cache.js` — IndexedDB snapshot per server (offline servers show "last seen")
  - `demo.js` — sample data; open `?demo` to test UI without Plex
- `helper/library-helper.ps1` — Windows PowerShell 5.1. `-Setup`, `-Status`, `-Once`, default loop.
  Double-click `.cmd` launchers for users. `test-helper.ps1` = offline tests (must stay passing).
- `serve.ps1` / `Start Dashboard.cmd` — tiny local static server on http://localhost:5173/

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

## Next: compression (in progress)

Goal: a **Compress…** action on a movie with presets, run by the helper on the gaming PC.

- Presets: 4K Extreme / High / Normal / Data Saver; 1080p High / Normal / Data Saver.
  4K Extreme/High → CPU x265 (best quality/GB, slow, overnight); 4K Normal/Data Saver and 1080p →
  GPU (AMD AMF HEVC on the RX 6750 XT; no AV1 encode). 1080p from HDR → tone-map to SDR.
- Audio choice per job: keep original (keeps TrueHD Atmos) or smaller surround (loses Atmos).
- Tool: HandBrakeCLI (install via winget **with the owner's approval**). First task: test encodes
  on a real Dolby Vision rip, CPU and GPU, to confirm what survives (DV/HDR10+/HDR10, audio, subs)
  and measure real speed/size before finalising presets.
- Scheduling is chosen **per job** by the user: start now / overnight window / only when idle /
  pause while gaming (full-screen app running) — combinable. Encodes run at low priority.
- Safety: original untouched; output verified (duration, streams) before it's added next to the
  original; "Replace original" is a separate, explicit step using the quarantine flow.
- Progress via the label info field (`run:37%`), shown in the Jobs panel.
- Needs a helper on the gaming PC first (not yet installed there; untested on a PC where Plex runs
  locally — `To-Local` handles drive-letter paths when `Plex Media Server` is running).

## Repo layout TODO

The first GitHub upload put everything in a `plex-library-dashboard/` subfolder, so Pages serves
at `.../Plex-Library-Helper/plex-library-dashboard/`. Move the files to the repo root.
