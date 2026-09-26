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

  Usage
    library-helper.ps1 -Setup    one-time: sign in with Plex and pick the server
    library-helper.ps1           run forever (what the scheduled task does)
    library-helper.ps1 -Once     process waiting jobs once and exit
    library-helper.ps1 -Status   show settings and the jobs the helper can see
#>
param([switch]$Setup, [switch]$Once, [switch]$Status, [string]$ServerName)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$LogDir = Join-Path $Root 'logs'
$Product = 'Plex Library Helper'
$Version = '0.2.0'
$QuarantineDir = '_TO_DELETE'
$LabelPrefix = 'pld:'

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
    if (-not $tag -or -not $tag.StartsWith($LabelPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }  # Plex may capitalise it
    $p = $tag.Substring($LabelPrefix.Length).Split(':', 5)
    if ($p.Count -lt 4) { return $null }
    [pscustomobject]@{ Tag = $tag; JobId = $p[0]; Action = $p[1]; MediaId = $p[2]; State = $p[3]; Info = $(if ($p.Count -gt 4) { $p[4] } else { '' }) }
}
function Job-Label($j, [string]$state, [string]$info = '') {
    $clean = ($info -replace '[,\r\n]', ' ').Trim()
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 120) }
    "$LabelPrefix$($j.JobId):$($j.Action):$($j.MediaId):$state" + $(if ($clean) { ":$clean" } else { '' })
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
        $labels = @((Pms GET "/library/sections/$($s.key)/label").MediaContainer.Directory | Where-Object { $_.title -and $_.title.StartsWith($LabelPrefix, [StringComparison]::OrdinalIgnoreCase) })
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

# ---------------------------------------------------------------- main

if ($Setup) { Do-Setup; exit 0 }
$script:Cfg = Load-Config
$script:LocalServer = $false
try { $script:LocalServer = [bool](Get-Process 'Plex Media Server' -ErrorAction SilentlyContinue) } catch { }

if ($Status) {
    "Plex Library Helper $Version on $env:COMPUTERNAME -> server '$($Cfg.serverName)' at $($Cfg.serverUrl)"
    "Shares handled:"; (Share-Map).GetEnumerator() | ForEach-Object { "  $($_.Key) -> $($_.Value)" }
    "Jobs visible in Plex:"; Get-Jobs | ForEach-Object { "  $($_.Job.Tag)  on '$($_.Item.title)'" }
    exit 0
}

Log "Plex Library Helper $Version started on $env:COMPUTERNAME for server '$($Cfg.serverName)' ($($Cfg.serverUrl))"
do {
    try { Process-Jobs } catch { Log "Polling failed: $($_.Exception.Message)" 'ERROR' }
    if ($Once) { break }
    Start-Sleep -Seconds ([int]$Cfg.pollSeconds)
} while ($true)
