<#
  Plex Library Helper (Windows PowerShell 5.1+)

  The small background program that moves files for the Plex Library Dashboard. The dashboard
  can only ask; this helper, running on the PC that owns the drives, does the work.

  The dashboard asks for a job by putting a label on a movie in Plex; the helper sees the label,
  does the job on this PC's drives, and reports back through the same label. Nothing at home is
  exposed to the internet: the helper only talks to your Plex server over the home network and
  to plex.tv.

  Jobs (label format  pld:<jobId>:<action>:<mediaId>:<state>[:<info>])
    q   quarantine: move that copy's files into <drive>:\_TO_DELETE\<date>\... on the same drive.
        Instant, reversible, nothing is ever deleted. Refused if no other copy of the movie still
        exists on disk (Plex checkFiles), so a duplicate clean-up can never remove the last copy.
    qa  the same, without that check: sent only when the dashboard has confirmed another copy
        exists elsewhere, or you explicitly chose to quarantine the last copy.

  Compression jobs (label format  pldc:<jobId>:<action>:<mediaId>:<state>[:<info>])
    A separate prefix, so helpers older than 0.3 ignore them instead of failing them.
    ce  estimate: encode three short samples and report predicted size, time and quality
    c   compress: encode the whole movie and add it next to the original (never replaces it)
    Queued info carries the options: p=<preset>;a=<keep|small>;r=<plex+plexall+game+idle+night>
    (plex = pause while Plex transcodes, plexall = while anything plays; see compress.ps1).
    Only a helper set up with -EnableCompress takes these; it reads files on its own drives or over
    the network, and runs compress.ps1 as a separate process so quarantines keep working meanwhile.
    States: queued -> run:<percent>;<seconds left>;<phase or pause reason>;<preset> -> done / fail.
    The dashboard asks to stop a running one by changing its state to "stop".

  Usage
    library-helper.ps1 -Setup             set up this PC (what "Set up Plex Library Helper.cmd" runs): sign in
                                          with Plex, choose whether this PC compresses, start with Windows.
                                          Run it again any time to change the compression answer.
    library-helper.ps1                    run forever (what the scheduled task does)
    library-helper.ps1 -Once              process waiting jobs once and exit
    library-helper.ps1 -Status            show settings and the jobs the helper can see
    library-helper.ps1 -EnableCompress [-WorkDir X:\_PLD_WORK]   let this PC run compression jobs
    library-helper.ps1 -DisableCompress
#>
param([switch]$Setup, [switch]$Once, [switch]$Status, [string]$ServerName, [switch]$EnableCompress, [switch]$DisableCompress, [string]$WorkDir)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$LogDir = Join-Path $Root 'logs'
$Product = 'Plex Library Helper'
$Version = '0.3.2'
$QuarantineDir = '_TO_DELETE'
$LabelPrefix = 'pld:'
$CompressPrefix = 'pldc:'
$JobsDir = Join-Path $Root 'jobs'

# ---------------------------------------------------------------- logging / config

function Log([string]$msg, [string]$level = 'INFO') {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1,-5} {2}' -f (Get-Date), $level, $msg
    Add-Content -LiteralPath (Join-Path $LogDir ('helper-{0:yyyyMMdd}.log' -f (Get-Date))) -Value $line -Encoding UTF8
    Write-Host $line
}

function Protect([string]$s) { ConvertTo-SecureString $s -AsPlainText -Force | ConvertFrom-SecureString }  # DPAPI, this Windows user only
function Unprotect([string]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $s))
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Not set up yet. Run: library-helper.ps1 -Setup" }
    $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $c | Add-Member -NotePropertyName Token -NotePropertyValue (Unprotect $c.tokenProtected) -Force
    $c
}

function Share-Map {
    # UNC prefix (as Plex sees it) -> local folder on this PC
    $map = @{}
    foreach ($s in Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\$$' -and $_.Path }) {
        $map["\\$($env:COMPUTERNAME)\$($s.Name)".ToLower()] = $s.Path.TrimEnd('\')
    }
    $map
}

# ---------------------------------------------------------------- Plex HTTP

function Plex-Headers($clientId, $token) {
    $h = @{ 'Accept' = 'application/json'; 'X-Plex-Product' = $Product; 'X-Plex-Version' = $Version; 'X-Plex-Client-Identifier' = $clientId; 'X-Plex-Device-Name' = "Library Helper on $env:COMPUTERNAME"; 'X-Plex-Platform' = 'Windows' }
    if ($token) { $h['X-Plex-Token'] = $token }
    $h
}

function Q([hashtable]$p) {
    ($p.GetEnumerator() | ForEach-Object { '{0}={1}' -f [Uri]::EscapeDataString([string]$_.Key), [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
}

function Pms([string]$method, [string]$path, [hashtable]$params = @{}) {
    $url = $script:Cfg.serverUrl + $path
    if ($params.Count) { $url += ($(if ($path.Contains('?')) { '&' } else { '?' }) + (Q $params)) }
    $res = Invoke-WebRequest -Method $method -Uri $url -Headers (Plex-Headers $script:Cfg.clientId $script:Cfg.Token) -TimeoutSec 60 -UseBasicParsing
    $text = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray())
    if (-not $text.Trim()) { return $null }
    # Plex sends keys that differ only by case ("guid"/"Guid", "rating"/"Rating"), which ConvertFrom-Json
    # rejects. JavaScriptSerializer keeps them apart; results are dictionaries, read with $x.Key as usual.
    $script:Json.DeserializeObject($text)
}
Add-Type -AssemblyName System.Web.Extensions
$script:Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Json.MaxJsonLength = [int]::MaxValue

# ---------------------------------------------------------------- setup

function Do-Setup {
    $clientId = [guid]::NewGuid().ToString()
    $pin = Invoke-RestMethod -Method Post -Uri 'https://plex.tv/api/v2/pins?strong=true' -Headers (Plex-Headers $clientId $null)
    $auth = 'https://app.plex.tv/auth#?' + (Q @{ clientID = $clientId; code = $pin.code; 'context[device][product]' = $Product })
    Write-Host ''
    Write-Host 'Open this link on any device where you are signed in to Plex and approve the Plex Library Helper:' -ForegroundColor Yellow
    Write-Host $auth
    Write-Host ''
    try { Start-Process $auth } catch { }
    $token = $null; $deadline = (Get-Date).AddMinutes(15)
    while (-not $token -and (Get-Date) -lt $deadline) {
        Start-Sleep 2
        $p = Invoke-RestMethod -Uri "https://plex.tv/api/v2/pins/$($pin.id)" -Headers (Plex-Headers $clientId $null)
        $token = $p.authToken
    }
    if (-not $token) { throw 'Sign-in timed out. Run -Setup again.' }
    Log 'Signed in to Plex.'

    $res = Invoke-RestMethod -Uri 'https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0' -Headers (Plex-Headers $clientId $token)
    $servers = @($res | Where-Object { $_.owned -and ($_.provides -split ',') -contains 'server' })
    if ($ServerName) { $servers = @($servers | Where-Object name -eq $ServerName) }
    if (-not $servers.Count) { throw 'No Plex server found on this account.' }
    if ($servers.Count -gt 1) { Log ("Several servers found ({0}); using '{1}'. Pass -ServerName to choose." -f (($servers.name) -join ', '), $servers[0].name) 'WARN' }
    $srv = $servers[0]

    # Prefer a plain LAN address (no DNS needed), then the secure plex.direct ones
    $cands = @()
    foreach ($c in @($srv.connections | Where-Object { $_.local -and -not $_.relay })) { $cands += "http://$($c.address):$($c.port)" }
    $cands += @($srv.connections | Where-Object { -not $_.relay } | ForEach-Object { $_.uri })
    $url = $null
    foreach ($u in ($cands | Select-Object -Unique)) {
        try { Invoke-RestMethod -Uri "$u/identity" -Headers (Plex-Headers $clientId $srv.accessToken) -TimeoutSec 5 | Out-Null; $url = $u; break } catch { }
    }
    if (-not $url) { throw "Couldn't reach '$($srv.name)' from this PC." }

    $cfg = [ordered]@{
        clientId = $clientId; tokenProtected = (Protect ($(if ($srv.accessToken) { $srv.accessToken } else { $token })))
        serverName = $srv.name; serverId = $srv.clientIdentifier; serverUrl = $url
        agentName = $env:COMPUTERNAME; pollSeconds = 20; version = $Version
    }
    $cfg | ConvertTo-Json | Out-File -LiteralPath $ConfigPath -Encoding UTF8
    Log "Set up for server '$($srv.name)' at $url. Shares handled: $(((Share-Map).Keys) -join ', ')"
}

# ---------------------------------------------------------------- labels

function Parse-Label([string]$tag) {
    if (-not $tag) { return $null }
    # Plex may capitalise it ("Pld:"), so compare without case
    $prefix = @($CompressPrefix, $LabelPrefix) | Where-Object { $tag.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (-not $prefix) { return $null }
    $p = $tag.Substring($prefix.Length).Split(':', 5)
    if ($p.Count -lt 4) { return $null }
    [pscustomobject]@{ Tag = $tag; Prefix = $prefix; JobId = $p[0]; Action = $p[1]; MediaId = $p[2]; State = $p[3]; Info = $(if ($p.Count -gt 4) { $p[4] } else { '' }) }
}
function Job-Label($j, [string]$state, [string]$info = '') {
    $clean = ($info -replace '[,\r\n]', ' ').Trim()
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 120) }
    $prefix = if ($j.Prefix) { $j.Prefix } else { $LabelPrefix }
    "$prefix$($j.JobId):$($j.Action):$($j.MediaId):$state" + $(if ($clean) { ":$clean" } else { '' })
}
function Job-Time([string]$jobId) {
    try { [DateTimeOffset]::FromUnixTimeMilliseconds([Convert]::ToInt64(($jobId -split '-')[0], 36)).LocalDateTime } catch { Get-Date }
}

function Item-Labels([string]$ratingKey) {
    $mc = (Pms GET "/library/metadata/$ratingKey").MediaContainer
    if (-not $mc -or -not $mc.Metadata) { throw "Plex returned no details for item $ratingKey" }
    @(@($mc.Metadata)[0].Label | Where-Object { $_ } | ForEach-Object { $_.tag })
}

# Replace one job label on an item with another, keeping every other label untouched.
# The new label goes on first, so a failure part-way never leaves the job without a label.
function Swap-Label([string]$sectionId, [string]$ratingKey, [string]$old, [string]$new) {
    if ($new) {
        $keep = @(@(Item-Labels $ratingKey) | Where-Object { $_ -and $_ -ne $old -and $_ -ne $new }) + $new
        $p = @{ type = 1; id = $ratingKey; 'label.locked' = 1 }
        for ($i = 0; $i -lt $keep.Count; $i++) { $p["label[$i].tag.tag"] = $keep[$i] }
        Pms PUT "/library/sections/$sectionId/all" $p | Out-Null
    }
    if ($old -and @(Item-Labels $ratingKey) -contains $old) {
        Pms PUT "/library/sections/$sectionId/all" @{ type = 1; id = $ratingKey; 'label[].tag.tag-' = $old } | Out-Null
    }
}

# ---------------------------------------------------------------- paths

function To-Local([string]$plexPath, [hashtable]$shares) {
    $lower = $plexPath.ToLower()
    foreach ($k in $shares.Keys) {
        if ($lower -eq $k -or $lower.StartsWith($k + '\')) { return $shares[$k] + $plexPath.Substring($k.Length) }
    }
    # Plex running on this same PC reports plain drive paths
    if ($script:LocalServer -and $plexPath -match '^[A-Za-z]:\\') { return $plexPath }
    $null
}

function Is-Video([string]$name) { $name -match '\.(mkv|mp4|avi|m4v|mov|wmv|ts|m2ts|webm|iso)$' }

# ---------------------------------------------------------------- jobs

function Quarantine($job, $item, $media, [hashtable]$shares) {
    $parts = @($media.Part)
    $local = @()
    foreach ($p in $parts) {
        $lp = To-Local $p.file $shares
        if (-not $lp) { return @{ skip = $true } }                     # not on this PC's drives
        if (-not (Test-Path -LiteralPath $lp -PathType Leaf)) { throw "File not found: $lp" }
        $len = (Get-Item -LiteralPath $lp -Force).Length
        if ($p.size -and [int64]$p.size -ne $len) { throw "Size on disk ($len) doesn't match Plex ($($p.size)) for $lp" }
        $local += [pscustomobject]@{ Plex = $p.file; Local = $lp; Size = $len }
    }
    if (-not $local.Count) { throw 'Plex lists no files for this copy.' }

    $folder = Split-Path $local[0].Local -Parent
    $drive = [IO.Path]::GetPathRoot($folder)
    # Move the whole folder only when it's this movie's own folder: never a drive root, a share root,
    # or a category folder like E:\Movies, and never a folder holding another movie's video
    $ownFolder = $false
    $isDriveRoot = $folder.TrimEnd('\') -eq $drive.TrimEnd('\')
    $isShareRoot = @($shares.Values | Where-Object { $_.TrimEnd('\').ToLower() -eq $folder.TrimEnd('\').ToLower() }).Count -gt 0
    if (-not $isDriveRoot -and -not $isShareRoot -and @(Get-ChildItem -LiteralPath $folder -Directory -Force).Count -le 20) {
        $mine = @($local.Local | ForEach-Object { $_.ToLower() })
        $others = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force | Where-Object {
            (Is-Video $_.Name) -and $_.Length -gt 300MB -and ($mine -notcontains $_.FullName.ToLower())
        })
        $ownFolder = $others.Count -eq 0
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd'
    if ($script:TestDrive) { $drive = $script:TestDrive }   # tests only: pretend this folder is the drive root
    $qRoot = Join-Path $drive "$QuarantineDir\$stamp"
    $moved = @(); $bytes = 0
    if ($ownFolder) {
        $rel = $folder.Substring($drive.Length)
        $dest = Join-Path $qRoot $rel
        if (Test-Path -LiteralPath $dest) { $dest = "$dest ($($job.JobId))" }
        New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
        $bytes = (Get-ChildItem -LiteralPath $folder -Recurse -File -Force | Measure-Object Length -Sum).Sum
        Move-Item -LiteralPath $folder -Destination $dest
        $moved += [pscustomobject]@{ from = $folder; to = $dest }
        $refresh = Split-Path $local[0].Plex -Parent | Split-Path -Parent
    } else {
        foreach ($f in $local) {
            # the video plus same-name sidecars (subtitles, .nfo, artwork)
            $base = [IO.Path]::GetFileNameWithoutExtension($f.Local)
            $group = @(Get-ChildItem -LiteralPath $folder -File -Force | Where-Object { $_.FullName -eq $f.Local -or ($_.BaseName -like "$base*" -and -not (Is-Video $_.Name)) })
            foreach ($g in $group) {
                $dest = Join-Path $qRoot $g.FullName.Substring($drive.Length)
                if (Test-Path -LiteralPath $dest) { $dest = [IO.Path]::Combine((Split-Path $dest -Parent), "$($job.JobId)-$($g.Name)") }
                New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
                Move-Item -LiteralPath $g.FullName -Destination $dest
                $bytes += $g.Length
                $moved += [pscustomobject]@{ from = $g.FullName; to = $dest }
            }
        }
        $refresh = Split-Path $local[0].Plex -Parent
    }
    foreach ($m in $moved) {
        [ordered]@{ job = $job.JobId; time = (Get-Date).ToString('o'); title = $item.title; year = $item.year; plexServer = $script:Cfg.serverName; mediaId = $job.MediaId; from = $m.from; to = $m.to } |
            ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $drive "$QuarantineDir\manifest.jsonl") -Encoding UTF8
    }
    @{ bytes = $bytes; moved = $moved; refresh = $refresh }
}

function Refresh-Plex([string]$sectionId, [string]$plexFolder) {
    try { Pms GET "/library/sections/$sectionId/refresh" @{ path = $plexFolder } | Out-Null } catch { Log "Plex rescan request failed: $($_.Exception.Message)" 'WARN' }
}

function Get-Jobs {
    $jobs = @()
    $sections = @((Pms GET '/library/sections').MediaContainer.Directory | Where-Object { $_.type -eq 'movie' })
    foreach ($s in $sections) {
        $labels = @((Pms GET "/library/sections/$($s.key)/label").MediaContainer.Directory | Where-Object { $_.title -and (Parse-Label $_.title) })
        foreach ($l in $labels) {
            $j = Parse-Label $l.title; if (-not $j) { continue }
            $items = @((Pms GET "/library/sections/$($s.key)/all" @{ type = 1; label = $l.key }).MediaContainer.Metadata)
            foreach ($it in $items) { if ($it) { $jobs += [pscustomobject]@{ Job = $j; Section = [string]$s.key; Item = $it } } }
        }
    }
    $jobs
}

function Process-Jobs {
    $shares = Share-Map
    $work = Get-Jobs
    foreach ($w in $work) {
        $j = $w.Job
        if ($j.Prefix -eq $CompressPrefix) {
            try { Process-CompressJob $w $shares } catch { Log "Compression job $($j.JobId) on '$($w.Item.title)': $($_.Exception.Message)" 'ERROR' }
            continue
        }
        $age = (Get-Date) - (Job-Time $j.JobId)
        if ($j.State -in 'done', 'fail' -and $age.TotalHours -gt 24) {
            Swap-Label $w.Section $w.Item.ratingKey $j.Tag $null; Log "Cleared finished job label $($j.JobId)"; continue
        }
        if ($j.State -eq 'run' -and $age.TotalHours -gt 2) {
            Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'Library Helper stopped while running this job'); continue
        }
        if ($j.State -ne 'queued') { continue }
        $media = @($w.Item.Media) | Where-Object { [string]$_.id -eq $j.MediaId } | Select-Object -First 1
        if (-not $media) {
            # Plex hasn't got this copy any more - usually already handled
            Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' "Plex no longer lists this copy"); continue
        }
        # Only claim jobs whose files are on this PC
        $mine = @($media.Part | Where-Object { To-Local $_.file $shares }).Count -gt 0
        if (-not $mine) { continue }
        if ($j.Action -notin 'q', 'qa') { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' "Unknown action '$($j.Action)'"); continue }

        # Last-copy guard: plain 'q' only runs if another copy of this movie still exists on disk and
        # isn't itself being quarantined. 'qa' means the dashboard confirmed it's fine (another copy
        # elsewhere, or you chose to quarantine the last one).
        if ($j.Action -eq 'q') {
            $md = @((Pms GET "/library/metadata/$($w.Item.ratingKey)" @{ checkFiles = 1 }).MediaContainer.Metadata)[0]
            $targeted = @(@($md.Label) | ForEach-Object { Parse-Label $_.tag } | Where-Object { $_ -and $_.Action -like 'q*' -and $_.State -in 'queued', 'run', 'done' } | ForEach-Object { [string]$_.MediaId })
            $survivors = @(@($md.Media) | Where-Object {
                [string]$_.id -ne $j.MediaId -and ($targeted -notcontains [string]$_.id) -and
                @(@($_.Part) | Where-Object { $_.exists -eq $false -or $_.accessible -eq $false }).Count -eq 0
            })
            if (-not $survivors.Count) {
                $msg = 'Kept: no other copy of this movie still exists, so this is the last one'
                Log "Job $($j.JobId) refused for $($w.Item.title): $msg" 'WARN'
                Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' $msg); continue
            }
        }

        $title = "$($w.Item.title) ($($w.Item.year))"
        Log "Job $($j.JobId): quarantine $title, copy $($j.MediaId)"
        $runTag = Job-Label $j 'run'
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag $runTag
        try {
            $r = Quarantine $j $w.Item $media $shares
            if ($r.skip) { Swap-Label $w.Section $w.Item.ratingKey $runTag $j.Tag; continue }
            foreach ($m in $r.moved) { Log "  moved $($m.from) -> $($m.to)" }
            Swap-Label $w.Section $w.Item.ratingKey $runTag (Job-Label $j 'done' ([string][int64]$r.bytes))
            Refresh-Plex $w.Section $r.refresh
            Log ("Job {0} done: {1:N1} GB quarantined" -f $j.JobId, ($r.bytes / 1GB))
        } catch {
            $msg = $_.Exception.Message
            Log "Job $($j.JobId) failed: $msg" 'ERROR'
            try { Swap-Label $w.Section $w.Item.ratingKey $runTag (Job-Label $j 'fail' $msg) } catch { Log "Couldn't report failure to Plex: $($_.Exception.Message)" 'ERROR' }
        }
    }
}

# ---------------------------------------------------------------- compression

function Save-Config {
    $out = [ordered]@{}
    foreach ($p in $script:Cfg.PSObject.Properties) { if ($p.Name -ne 'Token') { $out[$p.Name] = $p.Value } }
    $out | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $ConfigPath -Encoding UTF8
}

function Compress-On { [bool]($script:Cfg.compress -and $script:Cfg.compress.enabled) }

function Find-Tools {
    $first = { param([string[]]$c) foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath $x)) { return (Resolve-Path -LiteralPath $x).Path } }; $null }
    $cmd = { param($n) $g = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1; if ($g) { $g.Source } }
    # winget installs aren't on PATH in the window that installed them, so also look where winget puts things
    $links = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    $pkg = { param($n) Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter $n -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    $repoTools = Join-Path (Split-Path $Root -Parent) 'tools'
    [ordered]@{
        ffmpeg   = & $first @((& $cmd 'ffmpeg'), "$links\ffmpeg.exe", (& $pkg 'ffmpeg.exe'))
        ffprobe  = & $first @((& $cmd 'ffprobe'), "$links\ffprobe.exe", (& $pkg 'ffprobe.exe'))
        mkvmerge = & $first @((& $cmd 'mkvmerge'), "$env:ProgramFiles\MKVToolNix\mkvmerge.exe")
        dovi     = & $first @((Join-Path $Root 'tools\dovi_tool.exe'), (Join-Path $repoTools 'dovi_tool.exe'), (& $cmd 'dovi_tool'))
    }
}

function Enable-Compress {
    $tools = Find-Tools
    $missing = @($tools.Keys | Where-Object { -not $tools[$_] })
    $names = @{ ffmpeg = 'ffmpeg'; ffprobe = 'ffprobe (comes with ffmpeg)'; mkvmerge = 'MKVToolNix'; dovi = 'dovi_tool (tools folder)' }
    if ($missing) { throw "still missing $(($missing | ForEach-Object { $names[$_] }) -join ', '). Run setup again and say yes to installing it." }
    $enc = & $tools.ffmpeg -hide_banner -encoders 2>$null | Out-String
    if ($enc -notmatch 'hevc_amf') { throw "This ffmpeg can't use the AMD graphics encoder (hevc_amf)." }
    if (-not $WorkDir) {
        # the local drive with the most free space
        $d = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object FreeSpace -Descending | Select-Object -First 1
        $WorkDir = "$($d.DeviceID)\_PLD_WORK"
    }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $prev = $script:Cfg.compress
    $script:Cfg | Add-Member -NotePropertyName compress -Force -NotePropertyValue ([ordered]@{
        enabled = $true; workDir = $WorkDir; tools = $tools
        nightWindow = $(if ($prev -and $prev.nightWindow) { $prev.nightWindow } else { '23:00-07:00' })
    })
    Save-Config
    Log "Compression turned on. Work folder $WorkDir. Tools: $(($tools.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
}

# p=4kh;a=keep;r=plex+game  ->  preset, audio and pause rules
function Parse-CompressOptions([string]$info) {
    $o = @{}
    foreach ($kv in ($info -split ';')) { if ($kv -match '^\s*(\w+)=(.*)$') { $o[$Matches[1].ToLower()] = $Matches[2].Trim() } }
    $r = @(([string]$o['r']).ToLower() -split '\+' | Where-Object { $_ })
    [ordered]@{
        preset = [string]$o['p']
        audio  = $(if ($o['a'] -eq 'small') { 'small' } else { 'keep' })
        rules  = [ordered]@{ plex = $r -contains 'plex'; plexall = $r -contains 'plexall'; game = $r -contains 'game'; idle = $r -contains 'idle'; night = $r -contains 'night' }
    }
}

function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    for ($i = 0; $i -lt 3; $i++) { try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 200 } }
    $null
}
function Write-Json([string]$path, $obj) { $obj | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $path -Encoding UTF8 }

function Worker-Alive($workerPid) {
    if (-not $workerPid) { return $false }
    $p = Get-Process -Id ([int]$workerPid) -ErrorAction SilentlyContinue
    [bool]($p -and $p.ProcessName -match '^powershell')
}

# Jobs this PC is running right now, optionally only one mode ('compress' / 'estimate')
function Running-Workers([string]$mode) {
    if (-not (Test-Path $JobsDir)) { return @() }
    @(Get-ChildItem -LiteralPath $JobsDir -Filter '*.json' | Where-Object { $_.Name -notlike '*.status.json' } | ForEach-Object {
        $jf = Read-Json $_.FullName
        if ($jf -and -not $jf.finished -and (-not $mode -or $jf.mode -eq $mode) -and (Worker-Alive $jf.workerPid)) { $jf }
    })
}

function Fmt-Info([hashtable]$h) { ($h.GetEnumerator() | Where-Object { $null -ne $_.Value -and "$($_.Value)" -ne '' } | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' }

function Finish-CompressJob($jf, [string]$jobFile) {
    $jf | Add-Member -NotePropertyName finished -NotePropertyValue $true -Force
    Write-Json $jobFile $jf
    Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($jobFile, $null).TrimEnd('.') + '.cancel') -ErrorAction SilentlyContinue
}

function Process-CompressJob($w, [hashtable]$shares) {
    $j = $w.Job
    $age = (Get-Date) - (Job-Time $j.JobId)
    if ($j.State -in 'done', 'fail' -and $age.TotalHours -gt 24) {
        # Only the PC that ran it (or any PC if nobody claims it) clears it
        if ((Compress-On) -or -not (Test-Path (Join-Path $JobsDir "$($j.JobId).json"))) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag $null; Log "Cleared finished compression label $($j.JobId)" }
        return
    }
    if (-not (Compress-On)) { return }
    if (-not (Test-Path $JobsDir)) { New-Item -ItemType Directory -Force $JobsDir | Out-Null }
    $jobFile = Join-Path $JobsDir "$($j.JobId).json"
    $statusFile = Join-Path $JobsDir "$($j.JobId).status.json"
    $mode = if ($j.Action -eq 'ce') { 'estimate' } elseif ($j.Action -eq 'c') { 'compress' } else { $null }

    if ($j.State -eq 'queued') {
        if (-not $mode) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' "Unknown action '$($j.Action)'"); return }
        if (Test-Path -LiteralPath $jobFile) { return }                 # already claimed; label update pending
        if (@(Running-Workers $mode).Count) { return }                 # one compress and one estimate at a time
        $media = @($w.Item.Media) | Where-Object { [string]$_.id -eq $j.MediaId } | Select-Object -First 1
        if (-not $media) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'Plex no longer lists this copy'); return }
        $part = @($media.Part)[0]
        if (@($media.Part).Count -gt 1) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'Movies split into several files can''t be compressed yet'); return }
        # This PC's own drive, or a network share it can read
        $src = To-Local $part.file $shares
        if (-not $src -and $part.file -match '^\\\\' -and (Test-Path -LiteralPath $part.file -PathType Leaf)) { $src = $part.file }
        if (-not $src) { return }
        $opt = Parse-CompressOptions $j.Info
        $jf = [ordered]@{
            jobId = $j.JobId; mode = $mode; action = $j.Action; mediaId = $j.MediaId; preset = $opt.preset; audio = $opt.audio; rules = $opt.rules
            source = $src; sourcePlex = $part.file; section = $w.Section; ratingKey = [string]$w.Item.ratingKey
            title = $w.Item.title; year = $w.Item.year
            workDir = $script:Cfg.compress.workDir; tools = $script:Cfg.compress.tools; nightWindow = $script:Cfg.compress.nightWindow
            plexUrl = $script:Cfg.serverUrl; tokenProtected = $script:Cfg.tokenProtected
            created = (Get-Date).ToString('o'); workerPid = $null; lastInfo = ''; lastUpdate = $null
        }
        Write-Json $jobFile $jf
        $runTag = Job-Label $j 'run' "0;;Starting;$($opt.preset)"
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag $runTag
        $worker = Join-Path $Root 'compress.ps1'
        $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$worker`" -JobFile `"$jobFile`""
        $jf.workerPid = $p.Id
        Write-Json $jobFile $jf
        Log "Job $($j.JobId): $mode '$($w.Item.title)' preset $($opt.preset), audio $($opt.audio), pause rules $(($opt.rules.GetEnumerator() | Where-Object Value | ForEach-Object Key) -join '+'), from $src (worker $($p.Id))"
        return
    }

    $jf = Read-Json $jobFile
    if (-not $jf) { return }                                            # another PC's job
    if ($jf.finished) { return }
    $st = Read-Json $statusFile
    $alive = Worker-Alive $jf.workerPid

    if ($j.State -eq 'stop') {
        if ($alive -and (-not $st -or $st.state -eq 'run')) { New-Item -ItemType File -Force ([IO.Path]::ChangeExtension($jobFile, 'cancel')) | Out-Null; return }
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'Stopped from the dashboard')
        Finish-CompressJob $jf $jobFile
        Log "Job $($j.JobId) stopped from the dashboard"
        return
    }
    if ($j.State -ne 'run') { return }

    if ($st -and $st.state -eq 'done') {
        $r = $st.result
        if ($mode -eq 'estimate') {
            $info = Fmt-Info @{ p = $jf.preset; a = $jf.audio; b = [long]$r.bytes; t = [long]$r.secs; q = $r.vmaf; s = [long]$r.srcBytes }
        } else {
            $info = Fmt-Info @{ p = $jf.preset; b = [long]$r.bytes; s = [long]$r.srcBytes; dv = $(if ($r.dv) { 1 } else { 0 }) }
        }
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'done' $info)
        if ($mode -eq 'compress') {
            Refresh-Plex $w.Section ([IO.Path]::GetDirectoryName($jf.sourcePlex))
            Log ("Job {0} done: '{1}' {2:N1} GB -> {3:N1} GB at {4}" -f $j.JobId, $jf.title, ($r.srcBytes / 1GB), ($r.bytes / 1GB), $r.dest)
        } else { Log "Job $($j.JobId) estimate done: $info" }
        Finish-CompressJob $jf $jobFile
        return
    }
    if (($st -and $st.state -eq 'fail') -or -not $alive) {
        $msg = if ($st -and $st.state -eq 'fail') { $st.error } else { 'The compression worker stopped unexpectedly (PC restarted?). See the helper''s jobs folder log.' }
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' $msg)
        Log "Job $($j.JobId) failed: $msg" 'ERROR'
        Finish-CompressJob $jf $jobFile
        return
    }
    # Still running: report progress to Plex at most once a minute, or at once when it pauses/resumes
    if ($st) {
        $what = if ($st.paused) { "paused: $($st.paused)" } else { $st.phase }
        $info = '{0};{1};{2};{3}' -f [int]$st.percent, $(if ($st.secsLeft) { [long]$st.secsLeft } else { '' }), $what, $jf.preset
        $pausedChanged = ([string]$jf.lastInfo -split ';')[2] -ne $what
        $due = -not $jf.lastUpdate -or ((Get-Date) - [datetime]$jf.lastUpdate).TotalSeconds -ge 60
        if ($info -ne $jf.lastInfo -and ($due -or $pausedChanged)) {
            Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'run' $info)
            $jf.lastInfo = $info; $jf.lastUpdate = (Get-Date).ToString('o')
            Write-Json $jobFile $jf
        }
    }
}

# ---------------------------------------------------------------- guided setup (one download for every PC)

function Ask([string]$question, [bool]$default) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = ([string](Read-Host "$question $hint")).Trim().ToLower()
        if (-not $a) { return $default }
        if ($a -in 'y', 'yes') { return $true }
        if ($a -in 'n', 'no') { return $false }
    }
}
function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Install-WithWinget([string]$id, [string]$what) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Say "  winget isn't available on this PC. Install $what yourself, then run setup again." Yellow; return }
    Say "  Installing $what with winget (this can take a minute)..."
    & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
}

# The official Windows build from the dovi_tool project's releases page, into this folder's tools\
function Get-DoviTool {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quietvoid/dovi_tool/releases/latest' -Headers @{ 'User-Agent' = 'Plex-Library-Helper' }
    $asset = @($rel.assets | Where-Object { $_.name -match '^dovi_tool-.*-x86_64-pc-windows-msvc\.zip$' })[0]
    if (-not $asset) { throw "Couldn't find the Windows download of dovi_tool $($rel.tag_name)." }
    $zip = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    $dest = Join-Path $Root 'tools'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
    Say "  dovi_tool $($rel.tag_name) saved to $dest"
}

function Setup-Compression {
    Say ''
    Say 'Encoding / compression' Cyan
    Say 'The dashboard can shrink big movies (for example a 70 GB 4K disc rip to about 15-20 GB, keeping'
    Say 'Dolby Vision). Only one PC should do this: the one with the AMD Radeon graphics card.'
    $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name } | Where-Object { $_ })
    Say "Graphics on this PC: $($gpus -join ', ')"
    if (-not @($gpus | Where-Object { $_ -match 'Radeon|AMD' }).Count) {
        Say "This PC has no AMD Radeon graphics card, so it can't compress. It will handle quarantines only." Yellow
        if (Compress-On) { $script:Cfg.compress.enabled = $false; Save-Config; Log 'Compression turned off (no AMD graphics card).' }
        return
    }
    if (-not (Ask 'Use this PC for encoding / compression?' $true)) {
        if (Compress-On) { $script:Cfg.compress.enabled = $false; Save-Config; Log 'Compression turned off in setup.' }
        Say 'OK: this PC will handle quarantines only. Run setup again to change this.'
        return
    }

    # Tools it needs; each is only installed if you say yes
    $t = Find-Tools
    if (-not $t.ffmpeg -or -not $t.ffprobe) {
        if (Ask 'ffmpeg (does the encoding) is not installed. Install it now?' $true) { Install-WithWinget 'Gyan.FFmpeg' 'ffmpeg' }
    }
    if (-not $t.mkvmerge) {
        if (Ask 'MKVToolNix (puts the finished file together) is not installed. Install it now?' $true) { Install-WithWinget 'MoritzBunkus.MKVToolNix' 'MKVToolNix' }
    }
    if (-not $t.dovi) {
        if (Ask 'dovi_tool (keeps Dolby Vision, about 3 MB from github.com/quietvoid/dovi_tool) is not here. Download it now?' $true) {
            try { Get-DoviTool } catch { Say "  Download failed: $($_.Exception.Message)" Yellow }
        }
    }

    # Where the half-finished encodes live: the local drive with the most free space, unless you pick another
    $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object FreeSpace -Descending | Select-Object -First 1
    $suggest = if ($script:Cfg.compress -and $script:Cfg.compress.workDir) { $script:Cfg.compress.workDir } else { "$($best.DeviceID)\_PLD_WORK" }
    Say ('Work folder for encodes in progress (needs free space of about 60% of the biggest movie; {0} has {1:N0} GB free).' -f $best.DeviceID, ($best.FreeSpace / 1GB))
    $wd = ([string](Read-Host "Work folder [$suggest]")).Trim()
    $script:WorkDir = if ($wd) { $wd } else { $suggest }
    try {
        Enable-Compress
        Say "Compression is on. Work folder: $($script:Cfg.compress.workDir)" Green
    } catch {
        Say "Compression is not on yet: $($_.Exception.Message)" Yellow
        Say 'Fix that, then run setup again (you will not need to sign in again).' Yellow
    }
}

function Start-WithWindows {
    Say ''
    Say 'Start with Windows' Cyan
    $task = Get-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
    if ($task) {
        # Already installed: restart it so it runs this version, unless an encode is in progress
        if (@(Running-Workers).Count) { Say 'The helper is running an encode right now, so it keeps going; new settings apply straight away, a new version after the next restart.'; return }
        Stop-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
        & (Join-Path $Root 'install-helper.ps1') | Out-Host
        return
    }
    if (Ask 'Start the helper now, and whenever you sign in to Windows?' $true) { & (Join-Path $Root 'install-helper.ps1') | Out-Host }
    else { Say 'Not started. Run setup again when you want it running.' }
}

# Folder of the copy Windows currently starts (from the scheduled task), or $null
function Installed-Root {
    $t = Get-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $m = [regex]::Match([string]$t.Actions[0].Arguments, '-File "([^"]+)"')
    if ($m.Success) { Split-Path $m.Groups[1].Value -Parent } else { $null }
}

# A new download unzipped somewhere else (browsers save it as "...(1)"): take over from the old copy
# without orphaning an encode it's running, and keep its sign-in and settings.
function Replace-OldCopy {
    $old = Installed-Root
    if (-not $old -or $old.TrimEnd('\') -eq $Root.TrimEnd('\') -or -not (Test-Path -LiteralPath $old)) { return $true }
    Say "The helper that starts with Windows is another copy, in:" Yellow
    Say "  $old" Yellow
    $busy = @(Get-ChildItem -LiteralPath (Join-Path $old 'jobs') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.status.json' } | ForEach-Object {
        $jf = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        if (-not $jf.finished -and (Worker-Alive $jf.workerPid)) { $jf }
    })
    if ($busy.Count) {
        Say "That copy is in the middle of compressing: $(($busy | ForEach-Object { $_.title }) -join ', ')." Yellow
        Say 'Switching now would leave that encode running with nobody reporting on it. Either let it finish, or' Yellow
        Say 'Stop it in the dashboard (Jobs), then run this setup again. Nothing was changed.' Yellow
        return $false
    }
    if (-not (Test-Path $ConfigPath) -and (Test-Path (Join-Path $old 'config.json'))) {
        Copy-Item -LiteralPath (Join-Path $old 'config.json') -Destination $ConfigPath
        Say 'Copied its Plex sign-in and settings, so you won''t need to sign in again.'
    }
    if (-not (Test-Path (Join-Path $Root 'tools\dovi_tool.exe')) -and (Test-Path (Join-Path $old 'tools\dovi_tool.exe'))) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'tools') | Out-Null
        Copy-Item -LiteralPath (Join-Path $old 'tools\dovi_tool.exe') -Destination (Join-Path $Root 'tools')
    }
    Say "This copy takes over. When setup has finished you can delete the old folder (its logs are the only thing in it you might want)."
    Say ''
    $true
}

function Setup-Wizard {
    Say "Plex Library Helper $Version setup on $env:COMPUTERNAME" Cyan
    Say ''
    if (-not (Replace-OldCopy)) { return }
    $signIn = $true
    if (Test-Path $ConfigPath) {
        try {
            $script:Cfg = Load-Config
            Say "Already signed in: using Plex server '$($script:Cfg.serverName)'."
            $signIn = Ask 'Sign in to Plex again?' $false
        } catch { $signIn = $true }
    }
    if ($signIn) {
        Say 'Sign in to Plex' Cyan
        Do-Setup
        $script:Cfg = Load-Config
    }
    Setup-Compression
    Start-WithWindows
    Say ''
    Say 'All set. "Check status.cmd" shows what the helper is doing.' Green
}

# ---------------------------------------------------------------- main

if ($Setup) { Setup-Wizard; exit 0 }
$script:Cfg = Load-Config
$script:LocalServer = $false
try { $script:LocalServer = [bool](Get-Process 'Plex Media Server' -ErrorAction SilentlyContinue) } catch { }

if ($EnableCompress) { Enable-Compress; "Compression is on for $env:COMPUTERNAME. Work folder: $($Cfg.compress.workDir)"; exit 0 }
if ($DisableCompress) {
    if ($Cfg.compress) { $Cfg.compress.enabled = $false; Save-Config }
    Log 'Compression turned off.'; 'Compression is off. Running encodes finish; queued ones wait.'; exit 0
}

if ($Status) {
    "Plex Library Helper $Version on $env:COMPUTERNAME -> server '$($Cfg.serverName)' at $($Cfg.serverUrl)"
    "Shares handled:"; (Share-Map).GetEnumerator() | ForEach-Object { "  $($_.Key) -> $($_.Value)" }
    if (Compress-On) {
        "Compression: on. Work folder $($Cfg.compress.workDir), overnight window $($Cfg.compress.nightWindow)"
        Running-Workers | ForEach-Object { "  running: $($_.mode) '$($_.title)' ($($_.preset)), worker $($_.workerPid)" }
    } else { "Compression: off (to use this PC, run Set up Plex Library Helper and answer yes)" }
    "Jobs visible in Plex:"; Get-Jobs | ForEach-Object { "  $($_.Job.Tag)  on '$($_.Item.title)'" }
    exit 0
}

Log "Plex Library Helper $Version started on $env:COMPUTERNAME for server '$($Cfg.serverName)' ($($Cfg.serverUrl))"
do {
    # Re-read settings each round, so running setup again (e.g. turning compression on) applies straight away
    try { $script:Cfg = Load-Config } catch { Log "Couldn't re-read settings, keeping the old ones: $($_.Exception.Message)" 'WARN' }
    try { Process-Jobs } catch { Log "Polling failed: $($_.Exception.Message)" 'ERROR' }
    if ($Once) { break }
    Start-Sleep -Seconds ([int]$Cfg.pollSeconds)
} while ($true)
