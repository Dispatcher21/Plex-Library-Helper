# Plex Library Dashboard

A Steam-library-style view of everything on your Plex servers: every movie and show, which
drive and machine each copy lives on, its quality (4K / 1080p / SD, remux or disc rip,
HDR / Dolby Vision, lossless audio), and where you're wasting space on duplicates.

It's a plain static website — no build step, no backend. You sign in with your Plex account,
and your browser talks directly to plex.tv and your own Plex servers.

## Try it

- **On this PC:** double-click `Start Dashboard.cmd`, then open http://localhost:5173/.
- **Without signing in:** open http://localhost:5173/?demo (sample data).

To use it from your phone, host it somewhere with HTTPS (GitHub Pages works) — see below.

## How it works

1. **Sign in with Plex** uses Plex's PIN flow: you log in on plex.tv, which hands this page a
   token. The token is stored only in your browser (`localStorage`) and is only ever sent to
   plex.tv and your own servers.
2. The page lists the Plex servers you own and connects to each one the same way the Plex
   apps do — local address first, then remote, then Plex's relay. If you can stream from
   anywhere, this works from anywhere.
3. It reads every movie and episode, including each file's path, size, resolution, codecs and
   bitrate, and merges copies of the same title (matched by TMDB/IMDb/TVDB ID) across
   libraries and servers.
4. Each file's path tells it the drive: `\\MEDIA-PC\PLEX Server\...` shows up as
   *MEDIA-PC · PLEX Server*, `D:\...` as *<server> · D:*.
5. The last scan of each server is kept in IndexedDB, so the library loads instantly and a
   server that's switched off still shows its contents as "last seen".

Opening a title loads exact stream details from Plex (HDR format, Dolby Vision, Atmos);
before that, those badges are read from the file and folder names.

### Quality badges

| Badge | Meaning |
|---|---|
| 4K / 1080p / 720p / SD | Resolution Plex detected |
| Remux | "remux" in the name, or a very high bitrate (4K over 45 Mbps, 1080p over 25 Mbps) |
| Disc rip | MakeMKV-style `name_t00.mkv` |
| HDR / DV | HDR10, HLG or Dolby Vision |
| Lossless | TrueHD, DTS-HD MA, FLAC or PCM audio |
| N copies | The same title exists more than once |

"Highest quality" ranks copies by resolution, then source (remux/disc rip over re-encodes),
then Dolby Vision/HDR, lossless audio and bitrate.

## Fix match

Items Plex couldn't identify get an **Unmatched** badge and filter chip. Open any movie or show
and choose **Fix match**: it searches Plex's catalog (the dashboard guesses a clean title from
names like `Dune_t00`), and **Use this** applies the match in Plex, the same as Plex's own
Fix Match. If a title is split across several Plex entries, you choose which ones to update.
This talks to Plex directly, so it works from anywhere without the Library Helper.

## Quarantine (version 2)

Open a movie and choose **Quarantine this copy**, or **Keep highest quality, quarantine the rest**
on a duplicate. The copy's files move into `_TO_DELETE\<date>\` on the same drive. Nothing is
deleted; you review and empty `_TO_DELETE` yourself.

The dashboard can only *ask*. The work is done by the **Plex Library Helper**
(`helper/library-helper.ps1`), a small background program on the PC that owns the drive. Jobs
travel through Plex itself, so there's no extra service and nothing exposed to the internet:

1. The dashboard adds a label to the movie in Plex: `pld:<job>:q:<copy id>:queued`.
2. The helper checks Plex over the home network every 20 seconds, sees the label, and claims jobs
   whose files are on its own shares (it maps `\\PC\Share\...` to the local folder).
3. It checks the file exists and its size matches Plex, then moves it: the movie's whole folder if
   the folder holds only that movie, otherwise just the file and its same-name subtitles/artwork.
   Category folders like `E:\Movies`, share roots and drive roots are never moved.
4. It records every move in `_TO_DELETE\manifest.jsonl` (for restoring), swaps the label to
   `done` or `fail`, and asks Plex to rescan that folder. Finished labels are removed after a day.

Only accounts that can edit your library (you) can add labels, so only you can queue jobs.
Jobs wait while the Plex server or the helper's PC is off.

### Setting up the Library Helper (on each PC with media drives)

One download for every PC: **`download/Plex-Library-Helper.zip`** (the dashboard's Jobs panel links
to it). Unzip it and double-click **`Set up Plex Library Helper.cmd`**: it signs in to Plex (approve
the page it opens), asks **"Use this PC for encoding / compression?"** (yes only on the PC with the
AMD graphics card), and starts the helper with Windows.

See `helper/README.md` for what it does, where its log is, and how to stop or remove it.

## Compress (version 3)

Open a movie and choose **Compress…** on a copy. Pick a quality, what to do with the audio, and when
it may run; then **Estimate first** (encodes three short samples of that film and tells you the real
size, encode time and picture quality, in a few minutes) or **Start compressing**.

| Quality | Runs on | Typical result for a 4K remux | Time for a 2-hour film |
|---|---|---|---|
| 4K Extreme | Processor | ~20% of the size, indistinguishable | about 2 days (for favourites) |
| 4K High | Graphics card | ~27%, looks the same on a TV | about 1.5 hours |
| 4K Normal | Graphics card | ~20%, very close | about 1.5 hours |
| 4K Data Saver | Graphics card | ~10%, some softness | about 1.5 hours |
| 1080p High / Normal / Data Saver | Graphics card | 5–9%, HDR becomes normal colour | about 2 hours |

- **Dolby Vision is kept** on every 4K preset (converted to profile 8.1, the kind TVs and Plex play
  best). HDR10 is kept. HDR10+ is not.
- **Audio:** keep everything, or one smaller main track (reuses the disc's Dolby Digital Plus track,
  often Atmos, when there is one).
- **When:** pause while someone is watching Plex, pause while a game or full-screen video runs,
  only when the PC is idle, only overnight. Paused encodes carry on by themselves.
- **Grainy films** (lots of film grain) shrink far less, sometimes not at all. That's why Estimate exists.
- **Safety:** the original is never touched. The result is checked (length, every frame, audio and
  subtitle tracks, Dolby Vision, a test playback) before it's copied next to the original as
  `<Title> (<Year>) - Compressed <quality>.mkv`, where Plex shows it as a second version. When you're
  happy with it, choose **Replace original…** on the compressed copy: that quarantines the original.

The work is done by the Library Helper on the PC with the graphics card: answer yes to
"Use this PC for encoding / compression?" in its setup. It can compress files on other PCs' shared
drives too.

## Limits

- Quarantine works on movies. Shows and episodes are view-only for now.
- Only files in a Plex library are visible.
- Free space per drive isn't available from Plex; the drive cards show how much of your
  *library* is on each drive.

## Hosting on GitHub Pages

1. Create a repository and push these files.
2. Settings → Pages → deploy from the `main` branch, root folder.
3. Open `https://<you>.github.io/<repo>/` and sign in with Plex.

No secrets live in the code, so the repository can be public. Each visitor signs in with their
own Plex account and only ever sees their own servers.

## Files

| Path | What it is |
|---|---|
| `index.html`, `css/styles.css` | The page |
| `js/app.js` | UI, filters, detail view |
| `js/plex.js` | Plex sign-in, server discovery, API calls |
| `js/model.js` | Merging titles, quality detection, duplicate ranking |
| `js/jobs.js`, `js/compress.js` | Jobs sent to the Library Helper; compression presets |
| `js/cache.js` | Last-scan cache (IndexedDB) |
| `js/demo.js` | Sample data for `?demo` |
| `serve.ps1`, `Start Dashboard.cmd` | Tiny local web server for Windows |
