<#
  Plex Library Helper - compression worker (Windows PowerShell 5.1+)

  Started by library-helper.ps1 for one job; runs as its own process so the helper keeps polling
  Plex while a long encode runs. Talks back only through a status file next to the job file.

    compress.ps1 -JobFile <helper\jobs\<id>.json>

  Modes
    compress  encode the movie with a preset, verify the result, then copy it next to the original
              as "<Title> (<Year>) - Compressed <preset>.mkv". The original is never touched.
    estimate  encode three short samples (20%, 50%, 80% in) with the same settings and predict the
              finished size, encode time and quality (VMAF) without writing anything to the library.

  Pause rules (checked every few seconds while encoding; ffmpeg is frozen, not killed)
    plex     Plex is transcoding a stream (the thing that actually competes with an encode)
    plexall  anything is playing on Plex, even direct play (paused sessions never count)
    game   a full-screen app (game or full-screen video) is in front
    idle   only run while nobody has used the PC for 10 minutes
    night  only run inside the overnight window (config nightWindow, default 23:00-07:00)
#>
param([string]$JobFile)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- presets
# The helper picks the encoder and setting for each job (encoders.ps1: Choose-Encoder, from this PC's
# benchmark) and passes them in the job file. Encoder/Q here are only for jobs from older helpers.
. (Join-Path $PSScriptRoot 'encoders.ps1')

$Presets = [ordered]@{
    '4kx'   = @{ Label = '4K Extreme';    Height = 2160; Encoder = 'x265slow'; Q = 18; KeepsDV = $true }
    '4kh'   = @{ Label = '4K High';       Height = 2160; Encoder = 'amf';  Q = 20; KeepsDV = $true }
    '4kn'   = @{ Label = '4K Normal';     Height = 2160; Encoder = 'amf';  Q = 22; KeepsDV = $true }
    '4ks'   = @{ Label = '4K Data Saver'; Height = 2160; Encoder = 'amf';  Q = 26; KeepsDV = $true }
    '1080h' = @{ Label = '1080p High';       Height = 1080; Encoder = 'amf'; Q = 20; KeepsDV = $false }
    '1080n' = @{ Label = '1080p Normal';     Height = 1080; Encoder = 'amf'; Q = 22; KeepsDV = $false }
    '1080s' = @{ Label = '1080p Data Saver'; Height = 1080; Encoder = 'amf'; Q = 24; KeepsDV = $false }
}
$SmallAudioKbps = 640
$IdleMinutes = 10

# ---------------------------------------------------------------- small helpers

function Write-Status([hashtable]$s) {
    $s.updated = (Get-Date).ToString('o')
    $tmp = "$($script:StatusFile).tmp"
    ($s | ConvertTo-Json -Depth 5 -Compress) | Out-File -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:StatusFile -Force
}

function Wlog([string]$msg) {
    Add-Content -LiteralPath $script:LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg) -Encoding UTF8
}

function Safe-Name([string]$s) { (($s -replace '[\\/:*?"<>|]', ' ') -replace '\s+', ' ').Trim() }

# Run a tool, wait, return stdout; throws with the tail of stderr on failure
function Invoke-Tool([string]$exe, [string[]]$argList, [string]$what, [switch]$Stderr) {
    $err = [IO.Path]::GetTempFileName(); $out = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardError $err -RedirectStandardOutput $out
        $null = $p.Handle   # makes ExitCode available after exit
        try { $p.PriorityClass = 'BelowNormal' } catch { }
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "$what failed: $(((Get-Content -LiteralPath $err -Tail 4) -join ' ').Trim())" }
        if ($Stderr) { Get-Content -LiteralPath $err -Raw } else { Get-Content -LiteralPath $out -Raw }
    } finally { Remove-Item -LiteralPath $err, $out -ErrorAction SilentlyContinue }
}

function Qt([string]$s) { '"' + $s.Replace('"', '\"') + '"' }

# ---------------------------------------------------------------- source analysis

# Bits per second of a stream. MKV statistics tags (BPS) stay right when a file is cut; byte counts don't.
function Stream-Bps($s) {
    $t = $s.tags
    foreach ($k in 'BPS', 'BPS-eng') { if ($t -and $t.$k) { return [double]$t.$k } }
    if ($s.bit_rate) { return [double]$s.bit_rate }
    [double]($SmallAudioKbps * 1000)
}

# Length of the video track itself (audio can run longer): time of the last video frame, found by seeking near the end
function Video-Duration([string]$path, [double]$approx, [double]$fps) {
    foreach ($back in 30, 300) {
    $from = [math]::Max(0.0, $approx - $back)
    $pts = (Invoke-Tool $script:Tools.ffprobe @('-v', 'error', '-select_streams', 'v:0', '-read_intervals', ('{0:0.###}%' -f $from), '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', (Qt $path)) 'Measuring the video length') -split "`r?`n" |
        Where-Object { $_ -match '^[\d.]+' } | ForEach-Object { [double]($_ -replace ',.*', '') }
    if ($pts) { return ($pts | Measure-Object -Maximum).Maximum + 1 / $fps }
    }
    $null   # couldn't tell; callers fall back to the file's overall length
}

function Get-SourceInfo([string]$path) {
    $json = Invoke-Tool $script:Tools.ffprobe @('-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', (Qt $path)) 'Reading the file'
    $p = $json | ConvertFrom-Json
    $v = @($p.streams | Where-Object { $_.codec_type -eq 'video' -and -not ($_.disposition.attached_pic -eq 1) })[0]
    if (-not $v) { throw 'No video track found in the file.' }
    $dv = @($v.side_data_list | Where-Object { $_.side_data_type -eq 'DOVI configuration record' })[0]
    $fr = $v.r_frame_rate -split '/'
    $fps = if ($fr.Count -eq 2 -and [double]$fr[1]) { [double]$fr[0] / [double]$fr[1] } else { 23.976 }
    $dur = [double]$p.format.duration
    $vdur = Video-Duration $path $dur $fps
    $exact = $null -ne $vdur
    if (-not $exact) { $vdur = $dur }
    $audio = @($p.streams | Where-Object { $_.codec_type -eq 'audio' })
    $audioBytes = 0L
    foreach ($a in $audio) { $audioBytes += [long]((Stream-Bps $a) / 8 * $dur) }
    [pscustomobject]@{
        Path = $path; Size = (Get-Item -LiteralPath $path).Length; Duration = $dur; Fps = $fps; FpsRational = $v.r_frame_rate
        Frames = [long][math]::Round($vdur * $fps); VideoDuration = $vdur; VideoDurationExact = $exact
        Width = [int]$v.width; Height = [int]$v.height; Codec = $v.codec_name; BitDepth = $(if ($v.pix_fmt -match '10|12') { 10 } else { 8 })
        Transfer = $v.color_transfer; Primaries = $v.color_primaries; Matrix = $v.color_space
        Hdr = $v.color_transfer -in 'smpte2084', 'arib-std-b67'
        DvProfile = $(if ($dv) { [int]$dv.dv_profile } else { 0 })
        DvCompat = $(if ($dv) { [int]$dv.dv_bl_signal_compatibility_id } else { 0 })
        Audio = $audio; AudioBytes = $audioBytes
        Subs = @($p.streams | Where-Object { $_.codec_type -eq 'subtitle' }).Count
        Language = $(if ($v.tags.language) { $v.tags.language } else { 'und' })
    }
}

# Why a preset can't be used on this file, or $null if it can
function Preset-Problem($preset, $src) {
    if ($src.Height -lt $preset.Height * 0.8 -and $src.Width -lt ($preset.Height * 16 / 9) * 0.8) { return "The file is only $($src.Width)x$($src.Height), smaller than $($preset.Label)." }
    if ($src.DvProfile -eq 5) { return 'This file uses Dolby Vision profile 5 (streaming-style colours), which compression does not support yet.' }
    $null
}

# ---------------------------------------------------------------- ffmpeg command lines

function Video-Filters($preset, $src) {
    $f = @()
    $scale = $src.Height -gt $preset.Height * 1.1
    $fit = if ($src.Width / [math]::Max(1.0, $src.Height) -ge 16 / 9) { 'w=1920:h=-2' } else { 'w=-2:h=1080' }
    if ($preset.Height -eq 1080 -and $src.Hdr) {
        # HDR -> SDR for 1080p: tone-map on the CPU, then drop every HDR tag so TVs don't treat it as HDR
        $f += "zscale=$($fit):filter=spline36", 'zscale=t=linear:npl=100', 'format=gbrpf32le', 'zscale=p=bt709',
            'tonemap=hable:desat=0', 'zscale=t=bt709:m=bt709:r=tv', 'format=p010le'
        $f += 'MASTERING_DISPLAY_METADATA', 'CONTENT_LIGHT_LEVEL', 'DOVI_METADATA', 'DOVI_RPU_BUFFER', 'DYNAMIC_HDR_PLUS' | ForEach-Object { "sidedata=mode=delete:type=$_" }
    } elseif ($scale) {
        $f += "zscale=$($fit):filter=spline36", 'format=p010le'
    }
    $f
}

function Color-Args($preset, $src) {
    if ($preset.Height -eq 1080 -and $src.Hdr) { return @('-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709') }
    $a = @()
    if ($src.Primaries -and $src.Primaries -ne 'unknown') { $a += '-color_primaries', $src.Primaries }
    if ($src.Transfer -and $src.Transfer -ne 'unknown') { $a += '-color_trc', $src.Transfer }
    if ($src.Matrix -and $src.Matrix -ne 'unknown') { $a += '-colorspace', $src.Matrix }
    $a
}

# Full ffmpeg argument list for the video encode. Encoders that can't carry Dolby Vision themselves write
# raw HEVC (so it can be injected afterwards); the others write video-only MKV.
function Encode-Args($preset, $src, [string]$inPath, [string]$outPath, [string]$progressPath, [double]$seek = -1, [double]$length = -1) {
    $enc = $Encoders[$preset.Encoder]
    if (-not $enc) { throw "Unknown encoder '$($preset.Encoder)'." }
    $a = @('-nostdin', '-hide_banner', '-y', '-v', 'error')
    if ($progressPath) { $a += '-progress', (Qt $progressPath) }
    $filters = @(Video-Filters $preset $src)
    $a += Decode-Args $enc (-not $filters.Count)
    if ($seek -ge 0) { $a += '-ss', ('{0:0.###}' -f $seek) }
    if ($length -gt 0) { $a += '-t', ('{0:0.###}' -f $length) }
    $a += '-i', (Qt $inPath), '-map', '0:v:0', '-fps_mode', 'passthrough', '-an', '-sn', '-dn'
    if ($filters.Count) { $a += '-vf', (Qt ($filters -join ',')) }
    $tenBit = [bool]$filters.Count -or $src.BitDepth -ge 10 -or $enc.Kind -eq 'cpu'   # CPU encoders: 10-bit always compresses better
    $a += Codec-Args $enc $preset.Q $tenBit ([bool]$filters.Count)
    if ($enc.Ffmpeg -eq 'libx265') {
        if ($src.DvProfile -in 7, 8 -and $preset.KeepsDV) { $a += '-dolbyvision', '1' }   # "auto" silently drops it
        $x = 'repeat-headers=1:vbv-maxrate=40000:vbv-bufsize=40000'   # Dolby Vision needs VBV (UHD Blu-ray level cap)
        if ($src.Hdr) { $x = "hdr10-opt=1:$x" }
        $a += '-x265-params', $x
    }
    $a += Color-Args $preset $src
    if ($outPath -like '*.hevc') { $a += '-bsf:v', 'hevc_mp4toannexb', '-f', 'hevc' }
    $a += (Qt $outPath)
    $a
}
# ---------------------------------------------------------------- pause rules

Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class PldWin {
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool GetDiskFreeSpaceEx(string dir, out long freeToCaller, out long total, out long totalFree);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  public static double IdleSeconds() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i); if (!GetLastInputInfo(ref i)) return 0; return ((uint)Environment.TickCount - i.dwTime) / 1000.0; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO i);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  // A window covering its whole monitor, that isn't the desktop or taskbar
  public static bool FullScreenAppInFront() {
    IntPtr h = GetForegroundWindow(); if (h == IntPtr.Zero) return false;
    var c = new StringBuilder(256); GetClassName(h, c, 256); string cls = c.ToString();
    if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Windows.UI.Core.CoreWindow") return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
    if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
    return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
  }
}
'@

function In-Window([string]$window, [datetime]$now) {
    if ($window -notmatch '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') { $window = '23:00-07:00'; $null = $window -match '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$' }
    $start = [int]$Matches[1] * 60 + [int]$Matches[2]; $end = [int]$Matches[3] * 60 + [int]$Matches[4]
    $m = $now.Hour * 60 + $now.Minute
    if ($start -le $end) { $m -ge $start -and $m -lt $end } else { $m -ge $start -or $m -lt $end }
}

# What Plex is doing: 'transcoding' (a stream being converted, which competes with encoding for the PC),
# 'watching' (something playing directly, or a paused transcode), or '' (nothing playing). Paused
# direct-play sessions don't count: a paused tablet could otherwise hold an encode all night.
function Plex-Activity {
    try {
        if ($script:PlexUrl) {
            $r = Invoke-WebRequest -Uri "$($script:PlexUrl)/status/sessions" -Headers @{ 'X-Plex-Token' = $script:PlexToken; Accept = 'application/xml' } -TimeoutSec 5 -UseBasicParsing
            $x = [xml]$r.Content
            $playing = @(@($x.MediaContainer.Video) + @($x.MediaContainer.Track) | Where-Object { $_ -and $_.Player.state -ne 'paused' })
            if (@($playing | Where-Object { $_.TranscodeSession -and $_.TranscodeSession.videoDecision -eq 'transcode' }).Count) { return 'transcoding' }
            if ($playing.Count) { return 'watching' }
            return ''
        }
    } catch { }
    if (Get-Process 'Plex Transcoder' -ErrorAction SilentlyContinue) { 'transcoding' } else { '' }
}

# Returns why the encode should be paused right now, or '' to run
function Pause-Reason($rules) {
    # the tray's and dashboard's 'Pause all compressions' (jobs\PAUSED next to the job file)
    if ($script:PauseFile -and (Test-Path -LiteralPath $script:PauseFile)) { return 'paused from the tray or dashboard' }
    if ($rules.night -and -not (In-Window $script:NightWindow (Get-Date))) { return "waiting for the overnight window ($($script:NightWindow))" }
    if ($rules.idle -and [PldWin]::IdleSeconds() -lt $IdleMinutes * 60) { return 'the PC is in use' }
    if ($rules.game -and [PldWin]::FullScreenAppInFront()) { return 'a full-screen game or video is running' }
    if ($rules.plex -or $rules.plexall) {
        $a = Plex-Activity
        if ($a -eq 'transcoding') { return 'Plex is transcoding a stream' }
        if ($a -eq 'watching' -and $rules.plexall) { return 'someone is watching Plex' }
    }
    ''
}

# ---------------------------------------------------------------- running ffmpeg with progress + pauses

# Runs ffmpeg for the video encode, freezing it while a pause rule applies. $onProgress gets
# (fraction 0..1, encode fps, paused reason). Returns the number of frames written.
function Run-Encode([string[]]$argList, [string]$progressPath, [double]$duration, $rules, [scriptblock]$onProgress, [long]$expectedFrames = 0) {
    $err = "$progressPath.err"
    Remove-Item -LiteralPath $progressPath, $err -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $script:Tools.ffmpeg -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardError $err
    $null = $p.Handle
    try { $p.PriorityClass = 'Idle' } catch { }
    $script:Child = $p
    $paused = ''; $clearSince = $null; $lastRuleCheck = [datetime]::MinValue; $frames = 0L; $pausedAt = $null; $script:LastPausedSecs = 0.0
    try {
        while (-not $p.WaitForExit(2000)) {
            # Wait for ffmpeg to really exit, or it still holds its files when the work folder is cleaned up
            if (Test-Path -LiteralPath $script:CancelFile) { try { $p.Kill(); $p.WaitForExit(30000) | Out-Null } catch { }; throw 'Cancelled from the dashboard.' }
            if (((Get-Date) - $lastRuleCheck).TotalSeconds -ge 5) {
                $lastRuleCheck = Get-Date
                $why = Pause-Reason $rules
                if ($why -and -not $paused) { [PldWin]::NtSuspendProcess($p.Handle) | Out-Null; $paused = $why; $pausedAt = Get-Date; Wlog "Paused: $why" }
                elseif ($why) { $paused = $why; $clearSince = $null }
                elseif ($paused) {
                    # resume only after the reason has been gone for 30 s, so a short break doesn't flap
                    if (-not $clearSince) { $clearSince = Get-Date }
                    elseif (((Get-Date) - $clearSince).TotalSeconds -ge 30 -or $paused -like 'paused from the tray*') { [PldWin]::NtResumeProcess($p.Handle) | Out-Null; $script:LastPausedSecs += ((Get-Date) - $pausedAt).TotalSeconds; Wlog "Resumed (was: $paused)"; $paused = ''; $clearSince = $null }
                }
            }
            $prog = Read-Progress $progressPath
            if ($prog) {
                # Raw HEVC output leaves ffmpeg's out_time empty, so count frames when we know how many there are
                $frac = if ($expectedFrames -gt 0) { $prog.frame / $expectedFrames } else { $prog.outSec / [math]::Max(1.0, $duration) }
                $frames = $prog.frame; & $onProgress ([math]::Min(1.0, [double]$frac)) $prog.fps $paused
            }
        }
    } finally { $script:Child = $null }
    if ($p.ExitCode -ne 0) { throw "Encoding failed: $(((Get-Content -LiteralPath $err -Tail 4 -ErrorAction SilentlyContinue) -join ' ').Trim())" }
    $prog = Read-Progress $progressPath
    if ($prog) { $frames = $prog.frame }
    $frames
}

# Last block of ffmpeg's -progress output
function Read-Progress([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lines = @(); try { $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs); $lines = $sr.ReadToEnd() -split "`n"; $sr.Close() } catch { return $null }
    $last = @{}
    foreach ($l in $lines) { if ($l -match '^(\w+)=(.*)$') { $last[$Matches[1]] = $Matches[2].Trim() } }
    if (-not $last.ContainsKey('frame')) { return $null }
    $us = 0L; [void][long]::TryParse([string]$last['out_time_us'], [ref]$us)
    $fps = 0.0; [void][double]::TryParse([string]$last['fps'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fps)
    [pscustomobject]@{ frame = [long]$last['frame']; outSec = [math]::Max(0.0, $us / 1e6); fps = $fps; ended = $last['progress'] -eq 'end' }
}

# ---------------------------------------------------------------- audio / mux

# mkvmerge track ids for the source's audio tracks, plus how to make the "smaller" audio track
function Audio-Plan($src, [string]$mode) {
    $j = (Invoke-Tool $script:Tools.mkvmerge @('-J', (Qt $src.Path)) 'Reading tracks') | ConvertFrom-Json
    $tracks = @($j.tracks | Where-Object { $_.type -eq 'audio' })
    if ($mode -ne 'small' -or -not $tracks.Count) { return @{ Copy = @($tracks | ForEach-Object { $_.id }); Transcode = $null; Bytes = $src.AudioBytes } }
    $main = $tracks[0]; $lang = $main.properties.language
    # A Dolby Digital Plus / Dolby Digital track in the same language is already small (and may be Atmos): keep it as-is
    $light = @($tracks | Where-Object { $_.properties.language -eq $lang -and $_.codec -match 'E-AC-3|AC-3' -and $_.properties.audio_channels -ge 6 })[0]
    if ($light) {
        $ai = [array]::IndexOf(@($tracks.id), $light.id)
        $b = [long]((Stream-Bps $src.Audio[$ai]) / 8 * $src.Duration)
        return @{ Copy = @($light.id); Transcode = $null; Bytes = $b }
    }
    @{ Copy = @(); Transcode = 0; Bytes = [long]($SmallAudioKbps * 125 * $src.Duration) }   # first audio track -> E-AC-3 5.1
}

# ---------------------------------------------------------------- verify

function Verify-Output([string]$path, $src, $preset, [long]$framesEncoded, [int]$audioTracks, [bool]$expectDv) {
    $o = Get-SourceInfo $path
    $problems = @()
    $want = $Encoders[$preset.Encoder].Codec
    if ($o.Codec -ne $want) { $problems += "video is $($o.Codec), expected $($want.ToUpper())" }
    $pk = (Invoke-Tool $script:Tools.ffprobe @('-v', 'error', '-select_streams', 'v:0', '-count_packets', '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', (Qt $path)) 'Counting frames').Trim()
    $outLen = [long]$pk / $src.Fps
    $tol = if ($src.VideoDurationExact) { [math]::Max(1.0, $src.VideoDuration * 0.001) } else { $src.VideoDuration * 0.03 }
    if ([math]::Abs($outLen - $src.VideoDuration) -gt $tol) { $problems += ('video is {0:N1} s long, original is {1:N1} s' -f $outLen, $src.VideoDuration) }
    if ($framesEncoded -and [long]$pk -ne $framesEncoded) { $problems += "has $pk frames, encoder wrote $framesEncoded" }
    if ($expectDv -and $o.DvProfile -ne 8) { $problems += 'Dolby Vision is missing' }
    if (@($o.Audio).Count -ne $audioTracks) { $problems += "has $(@($o.Audio).Count) audio tracks, expected $audioTracks" }
    if ($o.Subs -ne $src.Subs) { $problems += "has $($o.Subs) subtitle tracks, original has $($src.Subs)" }
    # Decode the start and the end: any decode error fails the job
    foreach ($ss in @(0, [math]::Max(0.0, $o.Duration - 60))) {
        $e = Invoke-Tool $script:Tools.ffmpeg @('-nostdin', '-v', 'error', '-ss', ('{0:0}' -f $ss), '-i', (Qt $path), '-t', '20', '-map', '0:v:0', '-map', '0:a?', '-f', 'null', '-') 'Test playback' -Stderr
        if ($e -and $e.Trim()) { $problems += "decode errors at $([int]$ss) s" }
    }
    if ($problems.Count) { throw "Check failed: $($problems -join '; ')" }
    $o
}

# ---------------------------------------------------------------- the two modes

function Run-Estimate($job, $src, $preset, [int]$samples = 3) {
    $len = if ($Encoders[$preset.Encoder].Kind -eq 'cpu') { 8 } else { 20 }
    $len = [math]::Min($len, [math]::Max(2.0, $src.Duration / 10))
    $totalBytes = 0L; $totalSec = 0.0; $encSecs = 0.0; $frames = 0L; $vmafs = @()
    for ($i = 0; $i -lt $samples; $i++) {
        $pos = $src.Duration * (0.2 + 0.3 * $i)
        $cut = Join-Path $script:Work "sample$i.mkv"
        Invoke-Tool $script:Tools.ffmpeg @('-nostdin', '-v', 'error', '-y', '-ss', ('{0:0.###}' -f $pos), '-t', $len, '-i', (Qt $src.Path), '-map', '0:v:0', '-c', 'copy', (Qt $cut)) 'Cutting a sample' | Out-Null
        $out = Join-Path $script:Work "sample$i-out.mkv"
        $cutInfo = Get-SourceInfo $cut
        $t = Get-Date
        $n = Run-Encode (Encode-Args $preset $src $cut $out (Join-Path $script:Work "sample$i.progress")) (Join-Path $script:Work "sample$i.progress") $cutInfo.Duration $job.rules {
            param($f, $fps, $why) Write-Status @{ state = 'run'; phase = "$($script:PhasePrefix)Estimating"; percent = [int](& $script:MapPct (($i + $f) / $samples * 100)); paused = $why }
        } $cutInfo.Frames
        $encSecs += ((Get-Date) - $t).TotalSeconds - $script:LastPausedSecs
        $frames += $n
        $totalBytes += (Get-Item -LiteralPath $out).Length; $totalSec += $cutInfo.Duration
        # Quality: compare against the same sample put through the same scaling/tone-mapping, so only compression loss counts
        $ref = @(Video-Filters $preset $src) + 'format=yuv420p10le'
        $lavfi = "[0:v]format=yuv420p10le[d];[1:v]$($ref -join ',')[r];[d][r]libvmaf=n_threads=8:n_subsample=4"
        $vm = [string](Invoke-Tool $script:Tools.ffmpeg @('-nostdin', '-hide_banner', '-i', (Qt $out), '-i', (Qt $cut), '-lavfi', (Qt $lavfi), '-f', 'null', '-') 'Measuring quality' -Stderr)
        $m = [regex]::Match($vm, 'VMAF score: ([\d.]+)')
        if ($m.Success) { $vmafs += [double]$m.Groups[1].Value }
    }
    $audio = Audio-Plan $src $job.audio
    $videoBytes = $totalBytes / [math]::Max(1.0, $totalSec) * $src.Duration
    $fps = $frames / [math]::Max(1.0, $encSecs)
    $secs = $src.Frames / [math]::Max(0.1, $fps) + $src.Size / 150MB + 60   # encode + reading/copying + checks
    @{ bytes = [long]($videoBytes + $audio.Bytes); secs = [long]$secs; vmaf = $(if ($vmafs.Count) { [math]::Round(($vmafs | Measure-Object -Average).Average, 1) } else { $null }); fps = [math]::Round($fps, 1); srcBytes = $src.Size }
}

# Free bytes where a folder lives: a local drive or a network share (\\PC\Share\...)
function Free-Bytes([string]$folder) {
    $free = 0L; $total = 0L; $all = 0L
    if (-not [PldWin]::GetDiskFreeSpaceEx($folder.TrimEnd('\') + '\', [ref]$free, [ref]$total, [ref]$all)) { return $null }
    $free
}

# Problems that would only show at the very end of a long encode: fail on them in the first seconds instead.
# Checks the result can be written next to the original (the folder is on a share for movies on another PC)
# and that there's room for it there and in the work folder.
function Preflight-Check($src, [string]$srcDir) {
    $probe = Join-Path $srcDir ".pld-write-test-$PID.tmp"
    try { [IO.File]::WriteAllText($probe, 'Plex Library Helper write test; safe to delete') }
    catch { throw "Can't write to $srcDir from this PC, so the compressed copy couldn't be saved next to the original. Give $env:USERNAME on $env:COMPUTERNAME permission to change files in that folder (or its share). ($($_.Exception.Message))" }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    # Assume the result can be up to 60% of the original: once in the work folder, once next to the original
    $need = [long]($src.Size * 0.6) + 2GB
    foreach ($d in @($script:Work, $srcDir)) {
        $free = Free-Bytes $d
        if ($null -ne $free -and $free -lt $need) { throw ('Not enough free space for {0} ({1:N0} GB free, needs about {2:N0} GB).' -f $d, ($free / 1GB), ($need / 1GB)) }
    }
}

# $target (episodes): @{ dir; base = "Show (Year) - S02E05"; title } puts the result in the episode's own folder
function Run-Compress($job, $src, $preset, $target = $null) {
    $srcDir = [IO.Path]::GetDirectoryName($src.Path)
    if ($target) {
        $title = $target.title; $base = $target.base; $destDir = $target.dir
    } else {
        $title = Safe-Name "$($job.title)$(if ($job.year) { " ($($job.year))" })"; $base = $title
        # Put the result next to the original when the movie has its own folder; for a loose file in a
        # shared folder like E:\Movies, make "<Title> (<Year>)\" there so Plex treats it as the same movie
        $others = @(Get-ChildItem -LiteralPath $srcDir -File | Where-Object { $_.FullName -ne $src.Path -and $_.Extension -match '^\.(mkv|mp4|m4v|avi|ts|m2ts)$' -and $_.Length -gt 300MB })
        $destDir = if ($others.Count) { Join-Path $srcDir $title } else { $srcDir }
    }
    $dest = Join-Path $destDir "$base - Compressed $($preset.Label).mkv"
    $k = 2; while (Test-Path -LiteralPath $dest) { $dest = Join-Path $destDir "$base - Compressed $($preset.Label) ($k).mkv"; $k++ }

    Preflight-Check $src $srcDir

    $useRpu = $Encoders[$preset.Encoder].Rpu -and $preset.KeepsDV -and $src.DvProfile -in 7, 8
    $expectDv = $preset.KeepsDV -and $src.DvProfile -in 7, 8
    $weights = @{ encode = 0.9 }
    $report = { param([string]$phase, [double]$pct, [double]$fps, [string]$why)
        $left = $null
        if ($phase -eq 'Encoding' -and $fps -gt 0) {
            $left = ($src.Frames * (1 - $pct / 100 / $weights.encode)) / $fps + $src.Size / 150MB + 60
            # episodes still to do after this one, at this one's speed
            if ($script:RemainingVideoSecs) { $left += $script:RemainingVideoSecs * $src.Fps / $fps + 90 * $script:RemainingItems }
            $left = [long]$left
        }
        Write-Status @{ state = 'run'; phase = "$($script:PhasePrefix)$phase"; percent = [int][math]::Min(99.0, (& $script:MapPct $pct)); secsLeft = $left; paused = $why; dest = $dest }
    }

    $rpu = Join-Path $script:Work 'rpu.bin'
    if ($useRpu) {
        & $report 'Reading Dolby Vision' 0 0 ''
        # Dolby Vision data from the original, converted to profile 8.1 (what TVs and Plex play best)
        $bat = Join-Path $script:Work 'extract-rpu.cmd'
        "@`"$($script:Tools.ffmpeg)`" -nostdin -v error -i $(Qt $src.Path) -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | `"$($script:Tools.dovi)`" -m 2 extract-rpu - -o $(Qt $rpu)" | Out-File -LiteralPath $bat -Encoding ascii
        $o = cmd /c "`"$bat`" 2>&1"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $rpu)) { throw "Reading Dolby Vision failed: $($o -join ' ')" }
    }

    $videoOut = Join-Path $script:Work $(if ($Encoders[$preset.Encoder].Rpu) { 'video.hevc' } else { 'video.mkv' })
    $progress = Join-Path $script:Work 'encode.progress'
    $frames = Run-Encode (Encode-Args $preset $src $src.Path $videoOut $progress) $progress $src.Duration $job.rules {
        param($f, $fps, $why) & $report 'Encoding' ($f * 100 * $weights.encode) $fps $why
    } $src.Frames
    Wlog "Encoded $frames frames"

    $videoFinal = $videoOut
    if ($useRpu) {
        & $report 'Adding Dolby Vision' 91 0 ''
        $videoFinal = Join-Path $script:Work 'video-dv.hevc'
        Invoke-Tool $script:Tools.dovi @('inject-rpu', '-i', (Qt $videoOut), '--rpu-in', (Qt $rpu), '-o', (Qt $videoFinal)) 'Adding Dolby Vision' | Out-Null
        Remove-Item -LiteralPath $videoOut
    }

    & $report 'Preparing audio' 93 0 ''
    $audio = Audio-Plan $src $job.audio
    $extraAudio = $null
    if ($null -ne $audio.Transcode) {
        $extraAudio = Join-Path $script:Work 'audio.mka'
        $ch = [math]::Min(6, [int]$src.Audio[0].channels)
        Invoke-Tool $script:Tools.ffmpeg @('-nostdin', '-v', 'error', '-y', '-i', (Qt $src.Path), '-map', '0:a:0', '-c:a', 'eac3', '-b:a', "$($SmallAudioKbps)k", '-ac', $ch, (Qt $extraAudio)) 'Converting audio' | Out-Null
    }

    & $report 'Putting it together' 95 0 ''
    $muxed = Join-Path $script:Work 'final.mkv'
    $m = @('-q', '-o', (Qt $muxed), '--title', (Qt $title))
    $m += '--language', "0:$($src.Language)"
    if ($Encoders[$preset.Encoder].Rpu) { $m += '--default-duration', "0:$($src.FpsRational)p" }   # raw stream: needs its frame rate
    else { $m += '--no-audio', '--no-subtitles', '--no-chapters', '--no-attachments' }
    $m += (Qt $videoFinal), '--no-video'
    if ($audio.Copy.Count) { $m += '--audio-tracks', ($audio.Copy -join ',') } else { $m += '--no-audio' }
    $m += (Qt $src.Path)
    if ($extraAudio) { $m += (Qt $extraAudio) }
    $mo = Invoke-Tool $script:Tools.mkvmerge $m 'Putting the file together'
    $audioCount = $audio.Copy.Count + $(if ($extraAudio) { 1 } else { 0 })

    & $report 'Checking the result' 97 0 ''
    $out = Verify-Output $muxed $src $preset $frames $audioCount $expectDv

    & $report 'Copying into the library' 98 0 ''
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $partial = "$dest.partial"
    Copy-Item -LiteralPath $muxed -Destination $partial -Force
    $len = (Get-Item -LiteralPath $muxed).Length
    if ((Get-Item -LiteralPath $partial).Length -ne $len) { Remove-Item -LiteralPath $partial -ErrorAction SilentlyContinue; throw 'The copied file is incomplete.' }
    Move-Item -LiteralPath $partial -Destination $dest
    Wlog "Wrote $dest ($len bytes)"
    @{ bytes = $len; srcBytes = $src.Size; dest = $dest; destDir = $destDir; dv = $expectDv }
}

# ---------------------------------------------------------------- seasons and shows
# $job.items: one entry per episode { source, sourcePlex, ep = 'S02E05', epTitle, durationMs, size }.
# Episodes are done one after another; one that fails is reported and the rest carry on. Stopping from
# the dashboard stops the lot.

$script:MapPct = { param($p) $p }      # progress of the current file -> progress of the whole job
$script:PhasePrefix = ''
$script:RemainingVideoSecs = 0; $script:RemainingItems = 0

function Episode-Target($job, $it, $src) {
    $show = Safe-Name "$($job.title)$(if ($job.year) { " ($($job.year))" })"
    @{ dir = [IO.Path]::GetDirectoryName($src.Path); base = "$show - $($it.ep)"; title = "$($job.title) - $($it.ep)$(if ($it.epTitle) { " - $($it.epTitle)" })" }
}

function Run-Episodes($job, $preset) {
    $items = @($job.items); $n = $items.Count
    $baseWork = $script:Work
    $done = 0; $bytes = 0L; $srcBytes = 0L; $failed = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i++) {
        $it = $items[$i]
        $script:MapPct = [scriptblock]::Create("param(`$p) ($i + `$p / 100) / $n * 100")
        $script:PhasePrefix = "Episode $($i + 1) of $n ($($it.ep)): "
        $rest = @($items | Select-Object -Skip ($i + 1))
        $script:RemainingVideoSecs = ($rest | ForEach-Object { [double]$_.durationMs / 1000 } | Measure-Object -Sum).Sum
        $script:RemainingItems = $rest.Count
        $script:Work = Join-Path $baseWork "ep$i"
        New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
        try {
            if (Test-Path -LiteralPath $script:CancelFile) { throw 'Cancelled from the dashboard.' }
            if (-not (Test-Path -LiteralPath $it.source -PathType Leaf)) { throw "can't open $($it.source)" }
            $src = Get-SourceInfo $it.source
            $why = Preset-Problem $preset $src
            if ($why) { throw $why }
            $r = Run-Compress $job $src $preset (Episode-Target $job $it $src)
            $done++; $bytes += $r.bytes; $srcBytes += $src.Size
            Wlog "$($it.ep) done: $($src.Size) -> $($r.bytes) bytes"
        } catch {
            if ($_.Exception.Message -like 'Cancelled*') { throw }
            $failed.Add("$($it.ep): $($_.Exception.Message)"); Wlog "$($it.ep) FAILED: $($_.Exception.Message)"
        } finally {
            if ($script:Child -and -not $script:Child.HasExited) { try { $script:Child.Kill(); $script:Child.WaitForExit(30000) | Out-Null } catch { } }
            Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
            $script:Work = $baseWork
        }
    }
    if (-not $done) { throw "No episode could be compressed. First problem: $($failed[0])" }
    @{ bytes = $bytes; srcBytes = $srcBytes; episodes = $n; done = $done; failed = $failed.Count; problem = $(if ($failed.Count) { $failed[0] } else { '' }) }
}

# Samples one spot in up to three episodes (first, middle, last) and scales up to the whole list by running time
function Estimate-Episodes($job, $preset) {
    $items = @($job.items); $n = $items.Count
    $pick = @(@(0, [math]::Floor($n / 2), ($n - 1)) | Select-Object -Unique)
    $totalSecs = ($items | ForEach-Object { [double]$_.durationMs / 1000 } | Measure-Object -Sum).Sum
    $sampledSecs = 0.0; $predBytes = 0.0; $predTime = 0.0; $vmafs = @(); $fpss = @()
    $baseWork = $script:Work
    for ($k = 0; $k -lt $pick.Count; $k++) {
        $it = $items[$pick[$k]]
        $script:MapPct = [scriptblock]::Create("param(`$p) ($k + `$p / 100) / $($pick.Count) * 100")
        $script:PhasePrefix = "Sampling $($it.ep): "
        $script:Work = Join-Path $baseWork "ep$k"; New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
        try {
            $src = Get-SourceInfo $it.source
            $why = Preset-Problem $preset $src; if ($why) { throw $why }
            $r = Run-Estimate $job $src $preset 1
            $sampledSecs += $src.Duration; $predBytes += $r.bytes; $predTime += $r.secs; $fpss += $r.fps
            if ($r.vmaf) { $vmafs += $r.vmaf }
        } catch {
            if ($_.Exception.Message -like 'Cancelled*') { throw }
            $firstProblem = "$($it.ep): $($_.Exception.Message)"; Wlog "Sample of $firstProblem"   # try the other episodes
        } finally { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue; $script:Work = $baseWork }
    }
    if (-not $sampledSecs) { throw "None of the sampled episodes could be read. $firstProblem" }
    $scale = if ($totalSecs) { $totalSecs / $sampledSecs } else { $n / $pick.Count }
    @{ bytes = [long]($predBytes * $scale); secs = [long]($predTime * $scale); episodes = $n
        vmaf = $(if ($vmafs.Count) { [math]::Round(($vmafs | Measure-Object -Average).Average, 1) } else { $null })
        fps = $(if ($fpss.Count) { [math]::Round(($fpss | Measure-Object -Average).Average, 1) } else { $null })
        srcBytes = [long](($items | ForEach-Object { [double]$_.size } | Measure-Object -Sum).Sum) }
}

# ---------------------------------------------------------------- main

if (-not $JobFile) { return }   # dot-sourced by tests
$job = Get-Content -LiteralPath $JobFile -Raw | ConvertFrom-Json
$base = [IO.Path]::ChangeExtension($JobFile, $null).TrimEnd('.')
$script:StatusFile = "$base.status.json"
$script:CancelFile = "$base.cancel"
$script:PauseFile = Join-Path ([IO.Path]::GetDirectoryName($JobFile)) 'PAUSED'
$script:LogFile = "$base.log"
$script:Tools = $job.tools
$script:NightWindow = $(if ($job.nightWindow) { $job.nightWindow } else { '23:00-07:00' })
$script:PlexUrl = $job.plexUrl
$script:PlexToken = $null
if ($job.tokenProtected) {
    try {
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $job.tokenProtected))
        try { $script:PlexToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { $script:PlexUrl = $null }
}
$script:Work = Join-Path $job.workDir $job.jobId
New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
$script:Child = $null

Write-Status @{ state = 'run'; phase = 'Starting'; percent = 0; pid = $PID }
Wlog "Worker ${PID}: $($job.mode) '$($job.title)' preset $($job.preset) audio $($job.audio) from $($job.source)"
try {
    $preset = $Presets[$job.preset]
    if (-not $preset) { throw "Unknown preset '$($job.preset)'." }
    $preset = $preset.Clone()
    if ($job.encoder) { $preset.Encoder = [string]$job.encoder; $preset.Q = [double]$job.q }   # chosen by the helper for this PC
    if ($Encoders[$preset.Encoder].Codec -ne 'hevc') { $preset.KeepsDV = $false }   # AV1 output keeps HDR10, not Dolby Vision
    Wlog "Encoder: $($Encoders[$preset.Encoder].Label), setting $($preset.Q)"
    if ($job.items) {
        Wlog "$(@($job.items).Count) episodes: $((@($job.items) | ForEach-Object { $_.ep }) -join ', ')"
        $result = if ($job.mode -eq 'estimate') { Estimate-Episodes $job $preset } else { Run-Episodes $job $preset }
        Write-Status @{ state = 'done'; percent = 100; result = $result }
        Wlog "Done: $($result | ConvertTo-Json -Compress)"
        return
    }
    if (-not (Test-Path -LiteralPath $job.source -PathType Leaf)) { throw "Can't open $($job.source)" }
    $src = Get-SourceInfo $job.source
    $why = Preset-Problem $preset $src
    if ($why) { throw $why }
    Wlog ("Source {0}x{1}, video {2:N1} s (exact: {5}), {6} frames, HDR {3}, Dolby Vision profile {4}" -f $src.Width, $src.Height, $src.VideoDuration, $src.Hdr, $src.DvProfile, $src.VideoDurationExact, $src.Frames)
    $result = if ($job.mode -eq 'estimate') { Run-Estimate $job $src $preset } else { Run-Compress $job $src $preset }
    Write-Status @{ state = 'done'; percent = 100; result = $result }
    Wlog "Done: $($result | ConvertTo-Json -Compress)"
} catch {
    $msg = $_.Exception.Message
    Wlog "FAILED: $msg"
    Write-Status @{ state = 'fail'; error = $msg }
} finally {
    if ($script:Child -and -not $script:Child.HasExited) { try { $script:Child.Kill(); $script:Child.WaitForExit(30000) | Out-Null } catch { } }
    # Half-finished encodes are big: retry for a bit if a file is still in use
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $script:Work); $i++) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:Work) { Start-Sleep -Seconds 3 }
    }
    if (Test-Path -LiteralPath $script:Work) { Wlog "Couldn't remove the work folder $($script:Work); delete it by hand." }
}








