<#
  Plex Library Helper - benchmark and auto-calibration (loaded by library-helper.ps1; uses its Pms, To-Local,
  Share-Map, Running-Workers, Read-Json, Write-Json, Save-Config, Send-Ntfy, Publish-Live ...)

  Every PC that compresses measures its own encoders on real films from the library (a 4K one and a 1080p
  one): short samples at several settings each, scored for quality (VMAF), size and speed. From that it
  works out the setting that reaches each quality level on this PC (config compress.calibration), which
  Choose-Encoder then uses, and it tells the dashboard what it can do (a 'caps' message on the live
  channel) so the dashboard can show each PC's speed and estimates.

  When it runs
    - by itself, the first time a PC has encoders without measurements (and again when a new encoder
      appears), but only once nothing is running and nobody has used the PC for 10 minutes;
    - when asked: the tray menu, setup, or the dashboard ({"cmd":"benchmark","pc":...}). A request waits
      for running jobs to finish and holds new ones back until the benchmark is done.
  It pauses for Plex streams and full-screen games like any job, and is stopped by Stop in the tray menu,
  the dashboard ({"cmd":"benchmark","stop":true}) or pausing everything.
#>

$BenchRequest = Join-Path $JobsDir 'BENCHMARK'
$BenchLast = Join-Path $JobsDir 'bench-last.txt'
$script:LastCapsMsg = @{ sig = ''; at = [datetime]::MinValue }
$script:Hardware = $null

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PldIdle {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  public static double Seconds() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i); if (!GetLastInputInfo(ref i)) return 0; return ((uint)Environment.TickCount - i.dwTime) / 1000.0; }
}
'@

# Encoders this PC may use (processor ones only if it takes processor jobs)
function Bench-Encoders {
    $c = $script:Cfg.compress
    @($c.encoders | Where-Object { $_ -and $Encoders[$_] -and ($c.allowCpu -ne $false -or $Encoders[$_].Kind -ne 'cpu') })
}

function Running-Benchmark { @(Running-Workers 'benchmark') | Select-Object -First 1 }

# Compression jobs wait while a benchmark is asked for or running (it measures speed, so it runs alone)
function Bench-Holding { (Test-Path -LiteralPath $BenchRequest) -or [bool](Running-Benchmark) }

function Request-Benchmark([string]$by) {
    if (-not (Test-Path $JobsDir)) { New-Item -ItemType Directory -Force $JobsDir | Out-Null }
    if (Running-Benchmark) { Log "Benchmark asked for from $by, but one is already running"; return }
    "Asked for from $by at $(Get-Date -Format o)" | Out-File -LiteralPath $BenchRequest -Encoding ascii
    Log "Benchmark asked for from ${by}: it starts once nothing else is running"
}

function Stop-Benchmark([string]$by) {
    if (Test-Path -LiteralPath $BenchRequest) { [IO.File]::Delete($BenchRequest) }
    $b = Running-Benchmark
    if ($b) { New-Item -ItemType File -Force (Join-Path $JobsDir "$($b.jobId).cancel") | Out-Null; Log "Benchmark stopped from $by" }
}

# Has this PC got encoders it has never measured (and hasn't tried in the last week)?
function Needs-Calibration {
    if (-not (Compress-On)) { return $false }
    $cal = $script:Cfg.compress.calibration
    $missing = @(Bench-Encoders | Where-Object { -not ($cal -and $cal.$_) })
    if (-not $missing.Count) { return $false }
    -not (Test-Path -LiteralPath $BenchLast) -or ((Get-Date) - (Get-Item -LiteralPath $BenchLast).LastWriteTime).TotalDays -ge 7
}

# Films to measure on: per tier a few candidates (the worker takes the first that suits: not Dolby Vision
# profile 5, long enough). Live action only: animation compresses far more easily and would make every
# setting look better than it is on real films (the first run picked a 1986 cartoon). Films on this PC's own
# drives first (reading over the network could make the speed look worse than it is), then high bitrate:
# disc rips are what gets compressed. The same films each time, so later runs are comparable.
function Find-BenchSources([hashtable]$shares) {
    $found = @{ '4k' = @(); '1080' = @() }
    foreach ($s in @((Pms GET '/library/sections').MediaContainer.Directory | Where-Object { $_.type -eq 'movie' })) {
        foreach ($it in @((Pms GET "/library/sections/$($s.key)/all" @{ type = 1 }).MediaContainer.Metadata)) {
            if (-not $it) { continue }
            if (@($it.Genre | ForEach-Object { [string]$_.tag }) -match '^(Animation|Anime)$') { continue }
            foreach ($m in @($it.Media | Where-Object { $_ })) {
                $tier = switch ([string]$m.videoResolution) { '4k' { '4k' } '1080' { '1080' } default { $null } }
                if (-not $tier -or @($m.Part).Count -ne 1 -or [double]$m.duration -lt 3600000) { continue }
                $part = @($m.Part)[0]
                if ($part.file -match ' - Compressed (4K|1080p)\b') { continue }
                $local = To-Local $part.file $shares
                $found[$tier] += [pscustomobject]@{ path = $(if ($local) { $local } else { $part.file }); local = [bool]$local; kbps = [double]$m.bitrate; title = $it.title }
            }
        }
    }
    @(foreach ($tier in '4k', '1080') {
        $pick = @($found[$tier] | Sort-Object @{ e = { $_.local }; Descending = $true }, @{ e = { $_.kbps }; Descending = $true } |
            Where-Object { $_.local -or (Test-Path -LiteralPath $_.path -PathType Leaf) } | Select-Object -First 4)
        if ($pick.Count) { [ordered]@{ tier = $tier; paths = @($pick | ForEach-Object { $_.path }) } }
    })
}

function Start-Benchmark([string]$why) {
    $c = $script:Cfg.compress
    $encs = @(Bench-Encoders)
    if (-not $encs.Count) { throw 'no encoders to measure' }
    $sources = @(Find-BenchSources (Share-Map))
    if (-not $sources.Count) { throw 'no 4K or 1080p film (over an hour, not already compressed) in the library that this PC can read' }
    $id = 'bench-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $jobFile = Join-Path $JobsDir "$id.json"
    $jf = [ordered]@{
        jobId = $id; mode = 'benchmark'; title = 'Benchmark'; preset = ''; why = $why
        sources = $sources; encoders = $encs; rules = [ordered]@{ plex = $true; game = $true }
        workDir = $c.workDir; tools = $c.tools; nightWindow = $c.nightWindow
        plexUrl = $script:Cfg.serverUrl; tokenProtected = $script:Cfg.tokenProtected
        created = (Get-Date).ToString('o'); workerPid = $null
    }
    Write-Json $jobFile $jf
    "$why at $(Get-Date -Format o)" | Out-File -LiteralPath $BenchLast -Encoding ascii
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'compress.ps1')`" -JobFile `"$jobFile`""
    $jf.workerPid = $p.Id
    Write-Json $jobFile $jf
    Log "Benchmark $id started ($why): encoders $($encs -join ', '); films $(($sources | ForEach-Object { "$($_.tier): $(Split-Path @($_.paths)[0] -Leaf)" }) -join ', ') (worker $($p.Id))"
}

# Keep what the benchmark measured, per encoder and tier (a later run replaces only what it measured)
function Save-Calibration($result) {
    $c = $script:Cfg.compress
    $cal = if ($c.calibration) { $c.calibration | ConvertTo-Json -Depth 10 | ConvertFrom-Json } else { New-Object psobject }
    foreach ($tp in $result.tiers.PSObject.Properties) {
        $t = $tp.Value
        foreach ($ep in $t.encoders.PSObject.Properties) {
            $e = $ep.Value
            $entry = [pscustomobject][ordered]@{ levels = $e.levels; kbps = $e.kbps; vmaf = $e.vmaf; fps = $e.fps; skipped = $e.skipped; points = $e.points
                source = $t.source; srcKbps = $t.srcKbps; time = $result.time }
            if (-not $cal.($ep.Name)) { $cal | Add-Member -NotePropertyName $ep.Name -NotePropertyValue (New-Object psobject) -Force }
            $cal.($ep.Name) | Add-Member -NotePropertyName $tp.Name -NotePropertyValue $entry -Force
        }
    }
    if ($c -is [Collections.IDictionary]) { $c['calibration'] = $cal } else { $c | Add-Member -NotePropertyName calibration -NotePropertyValue $cal -Force }
    Save-Config
}

# One line per tier for the phone: the fastest encoder's setting for High, and how fast it is
function Bench-Summary($result) {
    @(foreach ($tp in $result.tiers.PSObject.Properties) {
        $best = @($tp.Value.encoders.PSObject.Properties | Where-Object { -not $_.Value.skipped -and $_.Value.levels.high } | Sort-Object { -[double]$_.Value.fps })
        if (-not $best.Count) { "$($tp.Name.ToUpper()): nothing fast enough"; continue }
        $e = $best[0]
        $film = [double]$tp.Value.srcKbps
        $pct = if ($film) { ' ({0:N0}% of the film)' -f ([double]$e.Value.kbps.high / $film * 100) } else { '' }
        '{0}: {1} at {2:N0} fps, High = setting {3}{4}' -f $tp.Name.ToUpper(), $Encoders[$e.Name].Label, [double]$e.Value.fps, $e.Value.levels.high, $pct
    }) -join '. '
}

# What this PC can do, for the dashboard (kept small: ntfy messages are limited to 4 KB)
function Caps-Summary {
    if (-not $script:Hardware) {
        $script:Hardware = @{
            cpu = [string](@(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)[0].Name).Trim()
            gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { $_ -and $_ -notmatch 'Basic Display|Remote|Virtual' })
        }
    }
    $c = $script:Cfg.compress
    $cal = [ordered]@{}
    if ($c -and $c.calibration) {
        foreach ($ep in $c.calibration.PSObject.Properties) {
            $cal[$ep.Name] = [ordered]@{}
            foreach ($tp in $ep.Value.PSObject.Properties) {
                $x = $tp.Value
                $lv = @($QualityTargets.Keys | ForEach-Object { $x.levels.$_ }); $kb = @($QualityTargets.Keys | ForEach-Object { $x.kbps.$_ })
                $cal[$ep.Name][$tp.Name] = [ordered]@{ fps = $x.fps; q = $(if ($null -ne $lv[0]) { $lv }); kbps = $(if ($null -ne $kb[0]) { $kb }); src = $x.srcKbps; skip = $x.skipped; time = $x.time }
            }
        }
    }
    $b = Running-Benchmark
    $bench = if ($b) {
        $st = Read-Json (Join-Path $JobsDir "$($b.jobId).status.json")
        [ordered]@{ state = 'running'; percent = $(if ($st) { [int]$st.percent } else { 0 }); what = $(if ($st -and $st.paused) { "paused: $($st.paused)" } elseif ($st) { [string]$st.phase } else { 'starting' }) }
    } elseif (Test-Path -LiteralPath $BenchRequest) { [ordered]@{ state = 'waiting' } } else { $null }
    [ordered]@{ kind = 'caps'; v = 1; pc = $env:COMPUTERNAME; version = $Version; time = (Get-Date).ToString('o')
        compress = (Compress-On); cpu = $script:Hardware.cpu; threads = [Environment]::ProcessorCount; gpus = $script:Hardware.gpus
        encoders = @($(if ($c) { $c.encoders })); allowCpu = $(if ($c) { $c.allowCpu -ne $false } else { $false })
        levels = @($QualityTargets.Keys); calibration = $cal; bench = $bench }
}

# Called every poll
function Bench-Poll {
    # a finished or failed benchmark
    if (Test-Path $JobsDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $JobsDir -Filter 'bench-*.json' | Where-Object { $_.Name -notlike '*.status.json' })) {
            $jf = Read-Json $f.FullName
            if (-not $jf -or $jf.finished) { continue }
            $st = Read-Json (Join-Path $JobsDir "$($jf.jobId).status.json")
            if ($st -and $st.state -eq 'done') {
                Save-Calibration $st.result
                Finish-CompressJob $jf $f.FullName
                $sum = Bench-Summary $st.result
                Log "Benchmark $($jf.jobId) done: $sum"
                $script:LastCapsMsg.sig = ''
                if (Notify-On) { try { Send-Ntfy "Benchmark done on $env:COMPUTERNAME" "$sum. Compressions on this PC now use these measurements." 'stopwatch' 'low' } catch { } }
            } elseif (($st -and $st.state -eq 'fail') -or -not (Worker-Alive $jf.workerPid)) {
                $msg = if ($st -and $st.state -eq 'fail') { [string]$st.error } else { 'the benchmark stopped unexpectedly (PC restarted?)' }
                Finish-CompressJob $jf $f.FullName
                Log "Benchmark $($jf.jobId) didn't finish: $msg" 'WARN'
                $script:LastCapsMsg.sig = ''
                if ((Notify-On) -and $msg -notmatch '^Cancelled') { try { Send-Ntfy "Benchmark failed on $env:COMPUTERNAME" $msg 'warning' 'low' } catch { } }
            }
        }
    }
    if ((Compress-On) -and -not (Is-Paused) -and -not @(Running-Workers).Count) {
        $why = $null
        if (Test-Path -LiteralPath $BenchRequest) { $why = ([string](Get-Content -LiteralPath $BenchRequest -TotalCount 1)) -replace ' at \d{4}-.*$', '' }
        elseif ((Needs-Calibration) -and [PldIdle]::Seconds() -ge 600) { $why = 'first run on this PC (it was idle)' }
        if ($why) {
            if (Test-Path -LiteralPath $BenchRequest) { [IO.File]::Delete($BenchRequest) }
            try { Start-Benchmark $why }
            catch {
                Log "Couldn't start the benchmark: $($_.Exception.Message)" 'WARN'
                "failed at $(Get-Date -Format o)" | Out-File -LiteralPath $BenchLast -Encoding ascii   # don't retry every poll
            }
        }
    }
    # tell the dashboard what this PC can do: on start, on change, and every 6 hours
    if (Channel-On) {
        $caps = Caps-Summary
        $sig = ($caps.calibration | ConvertTo-Json -Depth 6 -Compress) + "|$($caps.compress)|$($caps.encoders -join ',')|$($caps.bench.state)|$([int]($caps.bench.percent / 10))|$($caps.bench.what -match '^paused')"
        if ($sig -ne $script:LastCapsMsg.sig -or ((Get-Date) - $script:LastCapsMsg.at).TotalHours -ge 6) {
            try { Publish-Live $caps; $script:LastCapsMsg = @{ sig = $sig; at = Get-Date } } catch { }
        }
    }
}
