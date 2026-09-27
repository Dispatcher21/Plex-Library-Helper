<#
  Plex Library Helper - MakeMKV rip watcher (loaded by library-helper.ps1)

  Watches rips you start in MakeMKV as usual and reports them to the dashboard. Nothing here starts,
  stops or changes a rip; it only looks:
    - which disc is in the drive and how long / big its titles are (Blu-ray playlists, DVD title sets)
    - MakeMKV's own progress bars, read the way screen readers read windows (when MakeMKV exposes them)
    - the .mkv file growing in MakeMKV's destination folder (bytes, speed; % estimated from the disc)
  Status goes to a private ntfy topic (<topic>-status) that the dashboard reads; the dashboard sends the
  per-rip auto-compress switch back on <topic>-cmd. When a rip finishes: one phone notification, and
  optionally a compression queued for it once Plex has picked the file up.
#>

$RipMinSeconds = 600          # like MakeMKV's default minimum title length
$RipQuietSeconds = 90         # a file that hasn't grown for this long is finished

# ---------------------------------------------------------------- the disc

# Big-endian readers for Blu-ray structures
function Read-U16([byte[]]$b, [int]$o) { ([int]$b[$o] -shl 8) -bor $b[$o + 1] }
function Read-U32([byte[]]$b, [int]$o) { ([long]$b[$o] -shl 24) -bor ([long]$b[$o + 1] -shl 16) -bor ([long]$b[$o + 2] -shl 8) -bor [long]$b[$o + 3] }

# One Blu-ray playlist (BDMV\PLAYLIST\xxxxx.mpls): its clips and running time
function Read-Mpls([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 20 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'MPLS') { return $null }
    $pl = [int](Read-U32 $b 8)
    $count = Read-U16 $b ($pl + 6)
    $o = $pl + 10; $clips = @(); $ticks = 0L
    for ($i = 0; $i -lt $count -and $o + 22 -le $b.Length; $i++) {
        $len = Read-U16 $b $o
        $clips += [Text.Encoding]::ASCII.GetString($b, $o + 2, 5)
        $in = Read-U32 $b ($o + 14); $out = Read-U32 $b ($o + 18)
        if ($out -gt $in) { $ticks += $out - $in }
        $o += 2 + $len
    }
    [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($path); Clips = $clips; Seconds = $ticks / 45000.0 }
}

# The titles MakeMKV would show for the disc in drive $root (e.g. 'F:\'): name, length and size on disc.
# Blu-ray and UHD: one per playlist (duplicates of the same clips folded together). DVD: one per title set.
function Get-DiscTitles([string]$root) {
    $bd = Join-Path $root 'BDMV'
    if (Test-Path -LiteralPath (Join-Path $bd 'PLAYLIST')) {
        $sizes = @{}
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $bd 'STREAM') -Filter '*.m2ts' -ErrorAction SilentlyContinue) { $sizes[$f.BaseName] = $f.Length }
        $seen = @{}
        $titles = foreach ($p in Get-ChildItem -LiteralPath (Join-Path $bd 'PLAYLIST') -Filter '*.mpls' -ErrorAction SilentlyContinue) {
            $m = try { Read-Mpls $p.FullName } catch { $null }
            if (-not $m -or $m.Seconds -lt $RipMinSeconds) { continue }
            $key = $m.Clips -join ','
            if ($seen[$key]) { continue }; $seen[$key] = $true
            $bytes = [long](($m.Clips | Select-Object -Unique | ForEach-Object { [double]$sizes[$_] } | Measure-Object -Sum).Sum)
            [pscustomobject]@{ Name = "$($m.Name).mpls"; Seconds = [math]::Round($m.Seconds); Bytes = $bytes }
        }
        return @($titles | Sort-Object Seconds -Descending)
    }
    $vts = Join-Path $root 'VIDEO_TS'
    if (Test-Path -LiteralPath $vts) {
        $sets = Get-ChildItem -LiteralPath $vts -Filter 'VTS_*_*.VOB' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_0\.VOB$' } |
            Group-Object { $_.Name.Substring(0, 6) }
        return @($sets | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Seconds = $null; Bytes = [long](($_.Group | Measure-Object Length -Sum).Sum) } } |
            Where-Object { $_.Bytes -gt 300MB } | Sort-Object Bytes -Descending)
    }
    @()
}

# Optical drives with a disc in them: drive letter and disc name
function Get-Discs {
    @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 } |
        ForEach-Object { [pscustomobject]@{ Root = "$($_.DeviceID)\"; Label = $_.VolumeName; Bytes = [long]$_.Size } })
}

# What a file being written will probably end up as, from the disc's titles. A movie disc has one title
# much longer than the rest (the film): that's the one being ripped. Otherwise (TV discs) the episodes are
# similar, so the typical episode-length title. MakeMKV can leave out tracks, so this is an estimate.
function Expected-Bytes($titles, [long]$written) {
    $t = @($titles | Where-Object { $_.Bytes -gt 0 })
    if (-not $t.Count) { return $null }
    $byLen = @($t | Sort-Object { [double]$_.Seconds } -Descending)
    if ($byLen.Count -eq 1 -or ($byLen[0].Seconds -and $byLen[1].Seconds -and $byLen[0].Seconds -ge 3600 -and $byLen[0].Seconds -ge 1.5 * $byLen[1].Seconds)) {
        $e = $byLen[0].Bytes
    } else {
        $sizes = @($t | ForEach-Object { $_.Bytes } | Sort-Object)
        $e = $sizes[[int][math]::Floor($sizes.Count / 2)]
    }
    # never report more than 99% for a file that's still growing
    if ($written -gt $e * 0.99) { $e = [long]($written / 0.99) }
    $e
}

# ---------------------------------------------------------------- MakeMKV itself

function MakeMkv-Running { [bool](Get-Process makemkv, makemkvcon, makemkvcon64 -ErrorAction SilentlyContinue) }

# MakeMKV's destination folders, most recent first (its own settings)
function MakeMkv-Destinations {
    $k = Get-ItemProperty 'HKCU:\Software\MakeMKV' -ErrorAction SilentlyContinue
    if (-not $k) { return @() }
    $dirs = @(([string]$k.path_DestDirMRU -split '\*') + [string]$k.app_DestinationDir | Where-Object { $_ } | ForEach-Object { $_.Replace('/', '\').TrimEnd('\') })
    @($dirs | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
}

# MakeMKV's progress bars and status line, when its window exposes them (Qt usually does). $null if not.
function MakeMkv-Progress {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $procIds = @(Get-Process makemkv -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        if (-not $procIds.Count) { return $null }
        $root = [Windows.Automation.AutomationElement]::RootElement
        $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$procIds[0])
        $wins = $root.FindAll([Windows.Automation.TreeScope]::Children, $cond)
        $bars = @(); $texts = @()
        foreach ($w in $wins) {
            $pb = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ProgressBar)
            foreach ($e in $w.FindAll([Windows.Automation.TreeScope]::Descendants, $pb)) {
                $rv = $null
                if ($e.TryGetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern, [ref]$rv)) {
                    $max = $rv.Current.Maximum; if ($max -le 0) { $max = 100 }
                    $bars += [math]::Round(100.0 * ($rv.Current.Value - $rv.Current.Minimum) / ($max - $rv.Current.Minimum), 1)
                }
            }
            $tc = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)
            foreach ($e in $w.FindAll([Windows.Automation.TreeScope]::Descendants, $tc)) { if ($e.Current.Name) { $texts += $e.Current.Name } }
        }
        if (-not $bars.Count) { return $null }
        # MakeMKV shows "current progress" then "total progress", and label/value pairs like
        # "Output file :" "G:/PLEX/MOVIES/Title/Title_t00.mkv", "Source size :" "76763.2 M"
        $info = Read-MakeMkvInfo $texts
        [pscustomobject]@{ Current = $bars[0]; Total = $bars[$bars.Count - 1]; OutputFile = $info.OutputFile; SourceBytes = $info.SourceBytes; Texts = @($texts | Select-Object -Unique | Select-Object -First 16) }
    } catch { $null }
}

# The details MakeMKV's window shows while saving, as label/value pairs
function Read-MakeMkvInfo([string[]]$texts) {
    $pairs = @{}
    for ($i = 0; $i -lt $texts.Count - 1; $i++) { if ($texts[$i] -match '^\s*(.+?)\s*:\s*$') { $pairs[$Matches[1]] = $texts[$i + 1] } }
    $out = $pairs['Output file']; if ($out) { $out = $out.Replace('/', '\') }
    $size = $null
    if ($pairs['Source size'] -match '([\d.]+)\s*([KMG])') { $size = [long]([double]$Matches[1] * @{ K = 1KB; M = 1MB; G = 1GB }[$Matches[2]]) }
    @{ OutputFile = $out; SourceBytes = $size }
}

# ---------------------------------------------------------------- watching

# .mkv files being written (grew recently): the one MakeMKV's window names, plus any in its destination
# folders or their subfolders (a rip into a new folder isn't in MakeMKV's recent list until it's done)
function Rip-Files([string[]]$dirs, [datetime]$now, [string]$outputFile) {
    $recent = { $_.Extension -eq '.mkv' -and ($now - $_.LastWriteTime).TotalSeconds -lt $RipQuietSeconds }
    $found = @()
    # MakeMKV keeps naming the output file after it's finished, so it only counts while it's still growing
    if ($outputFile -and (Test-Path -LiteralPath $outputFile -PathType Leaf)) { $found += @(Get-Item -LiteralPath $outputFile | Where-Object $recent) }
    foreach ($d in $dirs) {
        $found += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object $recent)
        foreach ($sub in Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalMinutes -lt 30 }) {
            $found += @(Get-ChildItem -LiteralPath $sub.FullName -File -ErrorAction SilentlyContinue | Where-Object $recent)
        }
    }
    @($found | Sort-Object FullName -Unique)
}

# One step of the watcher: $state (the helper keeps it between polls) is updated from what's on disk now.
# Returns the status to publish, or $null when nothing is happening.
function Rip-Step($state, [datetime]$now, [bool]$running, [string[]]$dirs, $discs, $gui) {
    $files = if ($running) { @(Rip-Files $dirs $now $(if ($gui) { $gui.OutputFile })) } else { @() }
    if (-not $state.active) {
        if (-not $files.Count) { return $null }
        # a rip has started
        $disc = @($discs)[0]
        $state.active = $true; $state.id = [DateTimeOffset]::new($now).ToUnixTimeMilliseconds().ToString('x')
        $state.started = $now; $state.folder = $files[0].DirectoryName; $state.done = @(); $state.files = @{}
        $state.disc = if ($disc) { $disc.Label } else { '' }
        $state.titles = if ($disc) { @(Get-DiscTitles $disc.Root) } else { @() }
        $state.autoCompress = $null   # null = the setup default; the dashboard can switch it per rip
    }
    foreach ($f in $files) {
        $h = $state.files[$f.FullName]
        if (-not $h) { $h = @{ first = $now; firstBytes = $f.Length; seen = $now }; $state.files[$f.FullName] = $h }
        # 'seen' = last time it actually grew: a finished file keeps a fresh modified time for a while
        if ($f.Length -ne $h.bytes) { $h.seen = $now }
        $h.bytes = $f.Length
    }
    # files that stopped growing are finished
    foreach ($k in @($state.files.Keys)) {
        $quiet = ($now - $state.files[$k].seen).TotalSeconds
        $full = $gui -and $gui.Total -ge 100 -and $quiet -ge 20
        if (($quiet -ge $RipQuietSeconds -or $full) -and $state.done -notcontains $k) { $state.done += $k }
    }
    $current = @($state.files.Keys | Where-Object { $state.done -notcontains $_ } | Sort-Object { $state.files[$_].seen } -Descending | Select-Object -First 1)
    if (-not $current.Count) {
        # nothing growing any more: the rip is over, unless MakeMKV's bars say it's still going (between titles)
        if ($gui -and $gui.Total -gt 0 -and $gui.Total -lt 100 -and $running) { return (Rip-Status $state $now $null $gui 'ripping') }
        $state.active = $false
        return (Rip-Status $state $now $null $gui 'done')
    }
    Rip-Status $state $now $current[0] $gui 'ripping'
}

# ---------------------------------------------------------------- helper side (uses library-helper.ps1's
# Send-Ntfy, Pms, Swap-Label, Log, Save-Config)

$script:Rip = @{ active = $false }
$script:RipPending = @()        # finished rip files waiting for Plex, to compress
$script:RipLastStatus = $null

function Rip-On { [bool]($script:Cfg.rip -and $script:Cfg.rip.enabled -and $script:Cfg.notify -and $script:Cfg.notify.topic) }
function Rip-Topic([string]$kind) { "$($script:Cfg.notify.topic)-$kind" }

# The dashboard's switch for a rip (read by live.ps1's Read-Commands): {"cmd":"autocompress","id":"<rip id>","on":true}
function Handle-RipCommand($c) {
    if ($c.id -eq $script:Rip.id -and $script:Rip.active) { $script:Rip.autoCompress = [bool]$c.on; Log "Rip $($c.id): auto-compress switched $(if ($c.on) { 'on' } else { 'off' }) from the dashboard"; return }
    if ($c.id -eq $script:RipLastId) {
        # switched on just after the rip finished: still counts
        if ($c.on) { foreach ($f in $script:RipLastFiles) { if (-not ($script:RipPending | Where-Object { $_.path -eq $f })) { $script:RipPending += [pscustomobject]@{ path = $f; since = (Get-Date).ToString('o'); scanned = $false } } } }
        else { $script:RipPending = @($script:RipPending | Where-Object { $script:RipLastFiles -notcontains $_.path }) }
    }
}
# Plex library that a file on this PC belongs to: @{ key; type } or $null
function Library-For([string]$path) {
    foreach ($s in @((Pms GET '/library/sections').MediaContainer.Directory)) {
        foreach ($l in @($s.Location)) { if ($l.path -and $path.StartsWith($l.path.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return @{ key = [string]$s.key; type = $s.type } } }
    }
    $null
}

function New-JobId { $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $d = '0123456789abcdefghijklmnopqrstuvwxyz'; $s = ''; while ($ms -gt 0) { $s = $d[[int]($ms % 36)] + $s; $ms = [math]::Floor($ms / 36) }; "$s-rip" }

# For each finished rip file: have Plex scan it, find it, and queue a compression like the dashboard would
function Rip-QueueCompressions {
    if (-not $script:RipPending.Count) { return }
    $keep = @()
    foreach ($p in $script:RipPending) {
        try {
            $lib = Library-For $p.path
            if (-not $lib) { Log "Rip auto-compress: $($p.path) isn't in a Plex library folder; skipped" 'WARN'; continue }
            if ($lib.type -ne 'movie') { Log "Rip auto-compress: $($p.path) is in a TV library; name the episodes, then compress the season from the dashboard"; continue }
            if (-not $p.scanned) { Refresh-Plex $lib.key ([IO.Path]::GetDirectoryName($p.path)); $p.scanned = $true; $keep += $p; continue }
            $recent = @((Pms GET "/library/sections/$($lib.key)/all" @{ type = 1; sort = 'addedAt:desc'; 'X-Plex-Container-Start' = 0; 'X-Plex-Container-Size' = 40 }).MediaContainer.Metadata)
            $hit = $null
            foreach ($it in $recent) { foreach ($m in @($it.Media)) { if (@($m.Part | Where-Object { $_.file -eq $p.path }).Count) { $hit = @{ item = $it; media = $m } } } }
            if (-not $hit) {
                if (((Get-Date) - [datetime]$p.since).TotalMinutes -lt 60) { $keep += $p } else { Log "Rip auto-compress: Plex never showed $($p.path); not compressed" 'WARN' }
                continue
            }
            $res = [string]$hit.media.videoResolution
            $preset = if ($res -eq '4k') { $script:Cfg.rip.preset4k } elseif ($res -in '1080', '720') { $script:Cfg.rip.presetHD } else { $null }
            if (-not $preset) { Log "Rip auto-compress: $($hit.item.title) is $res, nothing to compress it to"; continue }
            $tag = "pldc:$(New-JobId):c:$($hit.media.id):queued:p=$preset;a=keep;r=plex+game"
            if (-not $script:ItemTypes) { $script:ItemTypes = @{} }; $script:ItemTypes[[string]$hit.item.ratingKey] = 1
            Swap-Label $lib.key ([string]$hit.item.ratingKey) $null $tag
            Log "Rip auto-compress: queued $preset for $($hit.item.title) ($($p.path))"
        } catch { Log "Rip auto-compress for $($p.path): $($_.Exception.Message)" 'WARN'; $keep += $p }
    }
    $script:RipPending = $keep
}

# Called every poll by the helper
function Rip-Poll {
    if (-not (Rip-On)) { return }
    Rip-QueueCompressions
    $running = MakeMkv-Running
    if (-not $running -and -not $script:Rip.active) { return }
    $discs = if ($script:Rip.active) { @() } else { Get-Discs }
    $gui = if ($running) { MakeMkv-Progress } else { $null }
    $wasActive = $script:Rip.active
    $s = Rip-Step $script:Rip (Get-Date) $running (MakeMkv-Destinations) $discs $gui
    if (-not $s) { return }
    if (-not $wasActive) {
        # a new rip: which Plex library it's going into (TV rips aren't compressed automatically)
        $lib = try { Library-For (Join-Path $script:Rip.folder 'x') } catch { $null }
        $script:Rip.library = if ($lib) { $lib.type } else { '' }; $s.library = $script:Rip.library
    }
    if ($s.library -eq 'show') { $s.autoCompress = $false; $script:Rip.autoCompress = $false }
    if ($null -eq $s.autoCompress) { $s.autoCompress = [bool]$script:Cfg.rip.autoCompress }
    $script:RipLastStatus = $s
    try { Publish-Live $s } catch { Log "Couldn't publish rip progress: $($_.Exception.Message)" 'WARN' }
    if ($s.state -eq 'done') {
        $files = @($script:Rip.done)
        $script:RipLastId = $s.id; $script:RipLastFiles = $files
        $total = ($s.done | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
        Log ("Rip finished: {0} ({1}), {2} file(s), {3:N1} GB" -f $s.folder, $s.disc, $files.Count, ($total / 1GB))
        if ($s.autoCompress) { foreach ($f in $files) { $script:RipPending += [pscustomobject]@{ path = $f; since = (Get-Date).ToString('o'); scanned = $false } } }
        if (Notify-On) {
            try { Send-Ntfy "Rip finished: $($s.folder)" ("{0} file(s), {1} in {2}{3}" -f $files.Count, (Fmt-GB $total), (Fmt-Time $s.elapsed), $(if ($s.autoCompress) { '. Compression will be queued once Plex has it.' } elseif ($s.library -eq 'show') { '. Name the episodes, then compress the season from the dashboard.' } else { '. Time for the next disc.' })) 'dvd' }
            catch { Log "Couldn't send the phone notification: $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Rip-Status($state, [datetime]$now, [string]$file, $gui, [string]$phase) {
    $s = [ordered]@{ kind = 'rip'; v = 1; id = $state.id; state = $phase; time = $now.ToString('o'); disc = $state.disc
        folder = (Split-Path $state.folder -Leaf); done = @($state.done | ForEach-Object { [ordered]@{ file = (Split-Path $_ -Leaf); bytes = [long]$state.files[$_].bytes } })
        autoCompress = $state.autoCompress; elapsed = [long]($now - $state.started).TotalSeconds; library = $state.library }
    if ($file) {
        $h = $state.files[$file]
        $secs = [math]::Max(1.0, ($now - $h.first).TotalSeconds)
        $rate = ($h.bytes - $h.firstBytes) / $secs
        $expected = if ($gui -and $gui.SourceBytes) { [long][math]::Max($gui.SourceBytes, $h.bytes / 0.99) } else { Expected-Bytes $state.titles $h.bytes }
        $s.file = Split-Path $file -Leaf; $s.bytes = [long]$h.bytes; $s.rate = [long]$rate
        if ($gui) { $s.percent = $gui.Current; $s.totalPercent = $gui.Total; $s.exact = $true }
        elseif ($expected) { $s.percent = [math]::Round(100.0 * $h.bytes / $expected, 1); $s.expected = [long]$expected; $s.exact = $false }
        if ($rate -gt 0 -and $s.percent) {
            # Time left: from the bytes still to write when the size is known; otherwise from how fast MakeMKV's
            # total bar has been moving since the watcher first saw it (the rip may have started earlier)
            $remaining = $null
            if ($expected) { $remaining = ($expected - $h.bytes) / $rate }
            if ($gui -and $gui.Total -gt 0 -and $gui.Total -lt 100) {
                if ($null -eq $state.firstTotal) { $state.firstTotal = [double]$gui.Total; $state.firstTotalAt = $now }
                $moved = [double]$gui.Total - $state.firstTotal; $took = ($now - $state.firstTotalAt).TotalSeconds
                # several titles: the total bar says how much of the whole rip is left
                if ($moved -gt 0.5 -and $took -gt 30 -and ($gui.Total -ne $gui.Current)) { $remaining = (100 - $gui.Total) * $took / $moved }
            }
            if ($remaining) { $s.secsLeft = [long]$remaining }
        }
    }
    $s
}
