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
    library-helper.ps1 -EmptyTrash        list what's in _TO_DELETE on this PC's drives and, after you type
                                          DELETE, remove it for good (what "Empty _TO_DELETE.cmd" runs)
#>
param([switch]$Setup, [switch]$Once, [switch]$Status, [string]$ServerName, [switch]$EnableCompress, [switch]$DisableCompress, [string]$WorkDir, [switch]$EmptyTrash)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$LogDir = Join-Path $Root 'logs'
$Product = 'Plex Library Helper'
$Version = '0.3.4'
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
    # Movies are Plex type 1, shows type 2 (show jobs live on the show, since episodes have no labels)
    $type = if ($script:ItemTypes -and $script:ItemTypes[$ratingKey]) { $script:ItemTypes[$ratingKey] } else { 1 }
    if ($new) {
        $keep = @(@(Item-Labels $ratingKey) | Where-Object { $_ -and $_ -ne $old -and $_ -ne $new }) + $new
        $p = @{ type = $type; id = $ratingKey; 'label.locked' = 1 }
        for ($i = 0; $i -lt $keep.Count; $i++) { $p["label[$i].tag.tag"] = $keep[$i] }
        Pms PUT "/library/sections/$sectionId/all" $p | Out-Null
    }
    if ($old -and @(Item-Labels $ratingKey) -contains $old) {
        Pms PUT "/library/sections/$sectionId/all" @{ type = $type; id = $ratingKey; 'label[].tag.tag-' = $old } | Out-Null
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

# -Episode: never move the folder. A season folder is shared by many episodes, and episodes are often
# smaller than the 300 MB "is this another movie" threshold, so the movie rule could take the whole season.
function Quarantine($job, $item, $media, [hashtable]$shares, [switch]$Episode) {
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
    if (-not $Episode -and -not $isDriveRoot -and -not $isShareRoot -and @(Get-ChildItem -LiteralPath $folder -Directory -Force).Count -le 20) {
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
            # Episodes: exactly "<name>.<anything>" so E01's clean-up can't take E10's subtitles
            $sidecar = if ($Episode) { { $_.Name.StartsWith("$base.", [StringComparison]::OrdinalIgnoreCase) } } else { { $_.BaseName -like "$base*" } }
            $group = @(Get-ChildItem -LiteralPath $folder -File -Force | Where-Object { $_.FullName -eq $f.Local -or ((& $sidecar) -and -not (Is-Video $_.Name)) })
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
    $script:ItemTypes = @{}
    $sections = @((Pms GET '/library/sections').MediaContainer.Directory | Where-Object { $_.type -in 'movie', 'show' })
    foreach ($s in $sections) {
        $type = if ($s.type -eq 'show') { 2 } else { 1 }
        $labels = @((Pms GET "/library/sections/$($s.key)/label").MediaContainer.Directory | Where-Object { $_.title -and (Parse-Label $_.title) })
        foreach ($l in $labels) {
            $j = Parse-Label $l.title; if (-not $j) { continue }
            $items = @((Pms GET "/library/sections/$($s.key)/all" @{ type = $type; label = $l.key }).MediaContainer.Metadata)
            foreach ($it in $items) {
                if (-not $it) { continue }
                $script:ItemTypes[[string]$it.ratingKey] = $type
                $jobs += [pscustomobject]@{ Job = $j; Section = [string]$s.key; Item = $it; IsShow = $type -eq 2 }
            }
        }
    }
    $jobs
}

# ---------------------------------------------------------------- show jobs
# Label on the show:  pld:<jobId>:qm|qma:sh<showRatingKey>:<state>:ids=<mediaId>+<mediaId>...;n=<count>;s=<what>
# Quarantines those episode copies. The dashboard puts copies from one drive in each label, so one helper
# does each label. qm = keep-best clean-up: each copy is only moved if another copy of that episode
# still exists and isn't being quarantined too. qma = you chose to remove these (whole season/show).

function Show-Episodes([string]$showKey, [switch]$CheckFiles) {
    $p = @{}; if ($CheckFiles) { $p.checkFiles = 1 }
    @((Pms GET "/library/metadata/$showKey/allLeaves" $p).MediaContainer.Metadata | Where-Object { $_ })
}

function Episode-Name($ep, $show) {
    '{0} - S{1:00}E{2:00}{3}' -f $show.title, [int]$ep.parentIndex, [int]$ep.index, $(if ($ep.title) { " - $($ep.title)" } else { '' })
}

function Process-ShowJob($w, [hashtable]$shares) {
    $j = $w.Job
    $age = (Get-Date) - (Job-Time $j.JobId)
    if ($j.State -in 'done', 'fail' -and $age.TotalHours -gt 24) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag $null; Log "Cleared finished job label $($j.JobId)"; return }
    if ($j.State -eq 'run' -and $age.TotalHours -gt 2) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'Library Helper stopped while running this job'); return }
    if ($j.State -ne 'queued') { return }
    if ($j.Action -notin 'qm', 'qma') { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' "Unknown action '$($j.Action)'"); return }

    $opt = @{}; foreach ($kv in ($j.Info -split ';')) { if ($kv -match '^\s*(\w+)=(.*)$') { $opt[$Matches[1].ToLower()] = $Matches[2].Trim() } }
    $ids = @(([string]$opt['ids']) -split '\+' | Where-Object { $_ -match '^\d+$' })
    if (-not $ids.Count) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'No episodes listed'); return }

    $show = $w.Item
    $eps = Show-Episodes $show.ratingKey -CheckFiles:($j.Action -eq 'qm')
    $byId = @{}
    foreach ($ep in $eps) { foreach ($m in @($ep.Media)) { if ($m) { $byId[[string]$m.id] = [pscustomobject]@{ Ep = $ep; Media = $m } } } }
    $targets = @($ids | ForEach-Object { $byId[$_] } | Where-Object { $_ })
    # Only claim a label whose copies are on this PC's drives
    $mine = @($targets | Where-Object { @($_.Media.Part | Where-Object { To-Local $_.file $shares }).Count -gt 0 })
    if (-not $mine.Count) {
        if (-not $targets.Count) { Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' 'Plex no longer lists these episodes') }
        return
    }

    $runTag = Job-Label $j 'run'
    Swap-Label $w.Section $w.Item.ratingKey $j.Tag $runTag
    Log "Job $($j.JobId): quarantine $($mine.Count) episode cop$(if ($mine.Count -eq 1) { 'y' } else { 'ies' }) of $($show.title) ($($opt['s']))"
    # Other active quarantine labels on this show: their copies don't count as survivors either
    $busy = @(@(Item-Labels $show.ratingKey) | ForEach-Object { Parse-Label $_ } | Where-Object { $_ -and $_.Action -like 'q*' -and $_.State -in 'queued', 'run', 'done' -and $_.JobId -ne $j.JobId } |
        ForEach-Object { if ($_.Action -in 'qm', 'qma') { ([regex]::Match($_.Info, 'ids=([\d+]+)').Groups[1].Value -split '\+') } else { $_.MediaId } })
    $all = @($ids) + $busy
    $bytes = 0L; $moved = 0; $failed = @(); $folders = @{}
    foreach ($t in $mine) {
        $name = Episode-Name $t.Ep $show
        try {
            if ($j.Action -eq 'qm') {
                $survivors = @(@($t.Ep.Media) | Where-Object {
                    $all -notcontains [string]$_.id -and @(@($_.Part) | Where-Object { $_.exists -eq $false -or $_.accessible -eq $false }).Count -eq 0
                })
                if (-not $survivors.Count) { throw 'kept: no other copy of this episode still exists' }
            }
            $jobForMove = [pscustomobject]@{ JobId = $j.JobId; MediaId = [string]$t.Media.id }
            $r = Quarantine $jobForMove ([pscustomobject]@{ title = $name; year = $show.year }) $t.Media $shares -Episode
            if ($r.skip) { continue }
            $bytes += $r.bytes; $moved++; $folders[$r.refresh] = $true
            foreach ($m in $r.moved) { Log "  moved $($m.from) -> $($m.to)" }
        } catch { $failed += "$('S{0:00}E{1:00}' -f [int]$t.Ep.parentIndex, [int]$t.Ep.index): $($_.Exception.Message)"; Log "  $name not moved: $($_.Exception.Message)" 'WARN' }
    }
    foreach ($f in $folders.Keys) { Refresh-Plex $w.Section $f }
    if (-not $moved -and $failed.Count) {
        Swap-Label $w.Section $w.Item.ratingKey $runTag (Job-Label $j 'fail' $failed[0])
    } else {
        # x (first problem) sorts last, so if the label gets cut at 120 characters only that is shortened
        $info = Fmt-Info @{ b = $bytes; n = $moved; f = $failed.Count; s = $opt['s']; x = $(if ($failed.Count) { ($failed[0] -replace '[;=+]', ' ') } else { '' }) }
        Swap-Label $w.Section $w.Item.ratingKey $runTag (Job-Label $j 'done' $info)
    }
    Log ("Job {0} done: {1} moved ({2:N1} GB), {3} not moved" -f $j.JobId, $moved, ($bytes / 1GB), $failed.Count)
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
        if ($w.IsShow) {
            try { Process-ShowJob $w $shares } catch { Log "Show job $($j.JobId) on '$($w.Item.title)': $($_.Exception.Message)" 'ERROR' }
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
        scope  = [string]$o['s']   # shows only: S02 or all
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

# ---------------------------------------------------------------- phone notifications (ntfy)
# When a compression or estimate finishes or fails, the helper posts one short message to a private ntfy
# topic; the free ntfy app on the phone shows it straight away, whatever the phone or dashboard is doing.
# Only the title and the result travel (no paths, no Plex details). Set up in -Setup.

$DashboardUrl = 'https://dispatcher21.github.io/Plex-Library-Helper/'
$PresetLabels = @{ '4kx' = '4K Extreme'; '4kh' = '4K High'; '4kn' = '4K Normal'; '4ks' = '4K Data Saver'; '1080h' = '1080p High'; '1080n' = '1080p Normal'; '1080s' = '1080p Data Saver' }

function Notify-On { [bool]($script:Cfg.notify -and $script:Cfg.notify.enabled -and $script:Cfg.notify.topic) }

# Same units as the dashboard (1 GB = 1024^3 bytes), so the numbers match what it shows
function Fmt-GB([double]$bytes) { if ($bytes -ge 100GB) { '{0:N0} GB' -f ($bytes / 1GB) } else { '{0:N1} GB' -f ($bytes / 1GB) } }
function Fmt-Time([double]$secs) {
    $m = [int][math]::Round($secs / 60.0)
    if ($m -lt 60) { return "$m min" }
    if ($m % 60) { '{0} h {1} min' -f [math]::Floor($m / 60), ($m % 60) } else { '{0} h' -f ($m / 60) }
}

function Send-Ntfy([string]$title, [string]$message, [string]$tags = '', [string]$priority = 'default') {
    $n = $script:Cfg.notify
    $body = [ordered]@{ topic = $n.topic; title = $title; message = $message; click = $DashboardUrl; priority = $(@{ low = 2; default = 3; high = 4 }[$priority]) }
    if ($tags) { $body.tags = @($tags -split ',') }
    # JSON as UTF-8 bytes: Windows PowerShell 5.1 would otherwise mangle accents and arrows in titles
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))
    Invoke-RestMethod -Method Post -Uri $n.server.TrimEnd('/') -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
}

# Title, message and icon for a finished or failed job; $null when there's nothing to say
function Job-Notification($jf, [string]$state, $result, [string]$errorText) {
    $name = "$($jf.title)$(if ($jf.year) { " ($($jf.year))" })$(if ($jf.scope) { " - $(Scope-Name $jf.scope)" })"
    $preset = $PresetLabels[[string]$jf.preset]; if (-not $preset) { $preset = [string]$jf.preset }
    if ($state -eq 'fail') {
        if ($errorText -match 'Stopped from the dashboard|Cancelled from the dashboard') { return $null }   # you did that yourself
        $what = if ($jf.mode -eq 'estimate') { 'Estimate' } else { 'Compression' }
        return @{ title = "$what failed: $name"; message = "$($preset): $errorText"; tags = 'warning'; priority = 'high' }
    }
    $src = [double]$result.srcBytes; $out = [double]$result.bytes
    $pct = if ($src) { ' ({0:N0}%)' -f ($out / $src * 100) } else { '' }
    if ($jf.mode -eq 'estimate') {
        $q = if ($result.vmaf) { ", quality $($result.vmaf)/100" } else { '' }
        $eps = if ($result.episodes) { " for $($result.episodes) episodes" } else { '' }
        return @{ title = "Estimate ready: $name"; message = "$($preset)$($eps): about $(Fmt-GB $out)$pct of $(Fmt-GB $src), about $(Fmt-Time $result.secs) to encode$q."; tags = 'bar_chart'; priority = 'default' }
    }
    if ($result.episodes) {
        $bad = if ($result.failed) { " $($result.failed) not done: $($result.problem)" } else { '' }
        return @{ title = "Compressed: $name"; message = "$($preset): $($result.done) of $($result.episodes) episodes, $(Fmt-GB $src) $([char]0x2192) $(Fmt-GB $out)$pct.$bad"; tags = $(if ($result.failed) { 'warning' } else { 'white_check_mark' }); priority = $(if ($result.failed) { 'high' } else { 'default' }) }
    }
    @{ title = "Compressed: $name"; message = "$($preset): $(Fmt-GB $src) $([char]0x2192) $(Fmt-GB $out)$pct. It's next to the original in Plex; choose Replace original when you're happy with it."; tags = 'white_check_mark'; priority = 'default' }
}

# Never lets a notification problem affect the job itself
function Notify-Job($jf, [string]$state, $result, [string]$errorText) {
    if (-not (Notify-On)) { return }
    try {
        $n = Job-Notification $jf $state $result $errorText
        if ($n) { Send-Ntfy $n.title $n.message $n.tags $n.priority; Log "Sent phone notification: $($n.title)" }
    } catch { Log "Couldn't send the phone notification: $($_.Exception.Message)" 'WARN' }
}

# Pause alerts. A pause is only worth a message once it has lasted a couple of minutes (Plex sessions
# start and stop all the time), at most one per job every 30 minutes; "resumed" only follows a "paused".
$PauseAlertAfter = 120; $PauseAlertEvery = 1800

function Set-Prop($o, [string]$name, $value) { $o | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }

# Updates the job's pause bookkeeping from the worker's status; returns 'pause', 'resume' or $null
function Track-Pause($jf, $st, [datetime]$now) {
    if ($st.paused) {
        if (-not $jf.pauseSince) { Set-Prop $jf 'pauseSince' $now.ToString('o'); Set-Prop $jf 'pauseNotified' $false; return $null }
        $long = ($now - [datetime]$jf.pauseSince).TotalSeconds -ge $PauseAlertAfter
        $quiet = -not $jf.lastPauseAlert -or ($now - [datetime]$jf.lastPauseAlert).TotalSeconds -ge $PauseAlertEvery
        if ($long -and $quiet -and -not $jf.pauseNotified) { Set-Prop $jf 'pauseNotified' $true; Set-Prop $jf 'lastPauseAlert' $now.ToString('o'); return 'pause' }
        return $null
    }
    $was = [bool]$jf.pauseNotified
    Set-Prop $jf 'pausedFor' $(if ($jf.pauseSince) { ($now - [datetime]$jf.pauseSince).TotalSeconds } else { 0 })
    Set-Prop $jf 'pauseSince' $null; Set-Prop $jf 'pauseNotified' $false
    if ($was) { 'resume' } else { $null }
}

function Pause-Notification($jf, [string]$kind, $st) {
    $name = "$($jf.title)$(if ($jf.year) { " ($($jf.year))" })"
    $preset = $PresetLabels[[string]$jf.preset]; if (-not $preset) { $preset = [string]$jf.preset }
    $what = if ($jf.mode -eq 'estimate') { 'estimate' } else { 'compression' }
    if ($kind -eq 'pause') {
        return @{ title = "Paused: $name"; message = "$preset $what at $([int]$st.percent)%: $($st.paused). It carries on by itself."; tags = 'pause_button'; priority = 'low' }
    }
    $left = if ($st.secsLeft) { " About $(Fmt-Time $st.secsLeft) left." } else { '' }
    @{ title = "Resumed: $name"; message = "$preset $what carrying on from $([int]$st.percent)% after $(Fmt-Time $jf.pausedFor) paused.$left"; tags = 'arrow_forward'; priority = 'low' }
}

# ---------------------------------------------------------------- compressing a season or show
# Label on the show: pldc:<id>:c|ce:sh<showKey>:queued:p=..;a=..;r=..;s=S02|all. The worker gets the list
# of episode files: per episode the biggest copy that isn't already compressed; episodes that already have
# a compressed copy are skipped. Files can be on this PC or on any share it can read.

function Scope-Name([string]$s) { if ($s -eq 'all') { 'whole show' } elseif ($s -match '^S(\d+)$') { if ([int]$Matches[1] -eq 0) { 'Specials' } else { "Season $([int]$Matches[1])" } } else { $s } }

function Show-CompressItems($showKey, [string]$scope, [hashtable]$shares) {
    $items = @(); $already = 0; $unreadable = 0
    foreach ($ep in (Show-Episodes $showKey | Sort-Object { [int]$_.parentIndex }, { [int]$_.index })) {
        if ($scope -ne 'all' -and ('S{0:00}' -f [int]$ep.parentIndex) -ne $scope) { continue }
        $media = @($ep.Media | Where-Object { $_ })
        if (@($media | Where-Object { @($_.Part | Where-Object { $_.file -match ' - Compressed (4K|1080p)\b' }).Count }).Count) { $already++; continue }
        $m = $media | Where-Object { @($_.Part).Count -eq 1 } | Sort-Object { [double]@($_.Part)[0].size } -Descending | Select-Object -First 1
        if (-not $m) { $unreadable++; continue }
        $part = @($m.Part)[0]
        $src = To-Local $part.file $shares
        if (-not $src -and $part.file -match '^\\\\' -and (Test-Path -LiteralPath $part.file -PathType Leaf)) { $src = $part.file }
        if (-not $src) { $unreadable++; continue }
        $items += [ordered]@{ source = $src; sourcePlex = $part.file; ep = ('S{0:00}E{1:00}' -f [int]$ep.parentIndex, [int]$ep.index); epTitle = $ep.title
            durationMs = $(if ($m.duration) { [double]$m.duration } else { [double]$ep.duration }); size = [double]$part.size; mediaId = [string]$m.id }
    }
    @{ items = $items; already = $already; unreadable = $unreadable }
}

function Start-ShowCompress($w, $j, [string]$mode, [hashtable]$shares, [string]$jobFile) {
    $opt = Parse-CompressOptions $j.Info
    $scope = if ($opt.scope) { $opt.scope } else { 'all' }
    $found = Show-CompressItems $w.Item.ratingKey $scope $shares
    if (-not $found.items.Count) {
        $why = if ($found.already) { "every episode in the $(Scope-Name $scope) already has a compressed copy" } else { "none of the episode files can be read from $env:COMPUTERNAME" }
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' "Nothing to do: $why"); return
    }
    $jf = [ordered]@{
        jobId = $j.JobId; mode = $mode; action = $j.Action; mediaId = $j.MediaId; preset = $opt.preset; audio = $opt.audio; rules = $opt.rules
        scope = $scope; items = $found.items; skipped = $found.already; unreadable = $found.unreadable
        source = $found.items[0].source; sourcePlex = $found.items[0].sourcePlex; section = $w.Section; ratingKey = [string]$w.Item.ratingKey
        title = $w.Item.title; year = $w.Item.year
        workDir = $script:Cfg.compress.workDir; tools = $script:Cfg.compress.tools; nightWindow = $script:Cfg.compress.nightWindow
        plexUrl = $script:Cfg.serverUrl; tokenProtected = $script:Cfg.tokenProtected
        created = (Get-Date).ToString('o'); workerPid = $null; lastInfo = ''; lastUpdate = $null
    }
    Write-Json $jobFile $jf
    Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'run' "0;;Starting;$($opt.preset);$scope")
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'compress.ps1')`" -JobFile `"$jobFile`""
    $jf.workerPid = $p.Id
    Write-Json $jobFile $jf
    Log "Job $($j.JobId): $mode '$($w.Item.title)' $(Scope-Name $scope), $($found.items.Count) episodes ($($found.already) already compressed, $($found.unreadable) unreadable), preset $($opt.preset) (worker $($p.Id))"
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
        if ($w.IsShow) { Start-ShowCompress $w $j $mode $shares $jobFile; return }
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
            $info = Fmt-Info @{ p = $jf.preset; a = $jf.audio; b = [long]$r.bytes; t = [long]$r.secs; q = $r.vmaf; s = [long]$r.srcBytes; c = $r.episodes; w = $jf.scope }
        } elseif ($jf.items) {
            # c = episodes in the job, n = compressed, f = failed, w = season/show, x = first problem (last: may be cut)
            $info = Fmt-Info @{ p = $jf.preset; b = [long]$r.bytes; s = [long]$r.srcBytes; c = $r.episodes; n = $r.done; f = $r.failed; w = $jf.scope; x = ([string]$r.problem -replace '[;=+]', ' ') }
        } else {
            $info = Fmt-Info @{ p = $jf.preset; b = [long]$r.bytes; s = [long]$r.srcBytes; dv = $(if ($r.dv) { 1 } else { 0 }) }
        }
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'done' $info)
        if ($mode -eq 'compress' -and $jf.items) {
            foreach ($d in @($jf.items | ForEach-Object { [IO.Path]::GetDirectoryName($_.sourcePlex) } | Select-Object -Unique)) { Refresh-Plex $w.Section $d }
            Log ("Job {0} done: '{1}' {2}: {3} of {4} episodes, {5:N1} GB -> {6:N1} GB" -f $j.JobId, $jf.title, (Scope-Name $jf.scope), $r.done, $r.episodes, ($r.srcBytes / 1GB), ($r.bytes / 1GB))
        } elseif ($mode -eq 'compress') {
            Refresh-Plex $w.Section ([IO.Path]::GetDirectoryName($jf.sourcePlex))
            Log ("Job {0} done: '{1}' {2:N1} GB -> {3:N1} GB at {4}" -f $j.JobId, $jf.title, ($r.srcBytes / 1GB), ($r.bytes / 1GB), $r.dest)
        } else { Log "Job $($j.JobId) estimate done: $info" }
        Finish-CompressJob $jf $jobFile
        Notify-Job $jf 'done' $r ''
        return
    }
    if (($st -and $st.state -eq 'fail') -or -not $alive) {
        $msg = if ($st -and $st.state -eq 'fail') { $st.error } else { 'The compression worker stopped unexpectedly (PC restarted?). See the helper''s jobs folder log.' }
        Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'fail' $msg)
        Log "Job $($j.JobId) failed: $msg" 'ERROR'
        Finish-CompressJob $jf $jobFile
        Notify-Job $jf 'fail' $null $msg
        return
    }
    # Still running: report progress to Plex at most once a minute, or at once when it pauses/resumes
    if ($st) {
        $what = if ($st.paused) { "paused: $($st.paused)" } else { $st.phase }
        $info = '{0};{1};{2};{3}' -f [int]$st.percent, $(if ($st.secsLeft) { [long]$st.secsLeft } else { '' }), $what, $jf.preset
        if ($jf.scope) { $info += ";$($jf.scope)" }
        $pausedChanged = ([string]$jf.lastInfo -split ';')[2] -ne $what
        $due = -not $jf.lastUpdate -or ((Get-Date) - [datetime]$jf.lastUpdate).TotalSeconds -ge 60
        $changed = $false
        if ($info -ne $jf.lastInfo -and ($due -or $pausedChanged)) {
            Swap-Label $w.Section $w.Item.ratingKey $j.Tag (Job-Label $j 'run' $info)
            $jf.lastInfo = $info; $jf.lastUpdate = (Get-Date).ToString('o'); $changed = $true
        }
        # Phone alert when a pause has lasted a while, and when it carries on again
        $before = "$($jf.pauseSince)|$($jf.pauseNotified)"
        $alert = Track-Pause $jf $st (Get-Date)
        if ($alert -and (Notify-On) -and $script:Cfg.notify.pauses -ne $false) {
            try { $n = Pause-Notification $jf $alert $st; Send-Ntfy $n.title $n.message $n.tags $n.priority; Log "Sent phone notification: $($n.title)" }
            catch { Log "Couldn't send the phone notification: $($_.Exception.Message)" 'WARN' }
        }
        if ($changed -or "$($jf.pauseSince)|$($jf.pauseNotified)" -ne $before) { Write-Json $jobFile $jf }
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

function New-Topic {
    # Long and random: anyone who knows an ntfy topic name can read it, so it works like a password
    $chars = 'abcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $b = New-Object byte[] 20; $rng.GetBytes($b)
    'pld-' + (-join ($b | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function Setup-Notifications {
    if (-not (Compress-On)) { return }   # only the compressing PC has anything to report
    Say ''
    Say 'Phone notifications' Cyan
    Say 'Get a notification on your phone when a compression or estimate finishes or fails, even with the'
    Say 'phone locked and the dashboard closed. Uses the free ntfy app; only the movie title and the result'
    Say 'are sent (through ntfy.sh), nothing else.'
    $on = Notify-On
    if (-not (Ask 'Send phone notifications?' $true)) {
        if ($on) { $script:Cfg.notify.enabled = $false; Save-Config; Log 'Phone notifications turned off.' }
        Say 'OK: no phone notifications. Run setup again to change this.'
        return
    }
    $topic = if ($script:Cfg.notify -and $script:Cfg.notify.topic) { $script:Cfg.notify.topic } else { New-Topic }
    $server = if ($script:Cfg.notify -and $script:Cfg.notify.server) { $script:Cfg.notify.server } else { 'https://ntfy.sh' }
    $pausesBefore = -not ($script:Cfg.notify -and $script:Cfg.notify.pauses -eq $false)
    $pauses = Ask 'Also tell you when a compression pauses (for example while Plex is transcoding) and carries on again?' $pausesBefore
    $script:Cfg | Add-Member -NotePropertyName notify -Force -NotePropertyValue ([ordered]@{ enabled = $true; server = $server; topic = $topic; pauses = $pauses })
    Save-Config
    Log "Phone notifications on (ntfy topic $topic), pause alerts $(if ($pauses) { 'on' } else { 'off' })."
    Say ''
    Say 'On your phone:' Green
    Say '  1. Install "ntfy" from the Play Store (or App Store).'
    Say '  2. Open it, tap +, and subscribe to this topic (keep the server as ntfy.sh):'
    Say ''
    Say "       $topic" Yellow
    Say ''
    Say "  (Or open $($server.TrimEnd('/'))/$topic on the phone and choose to open it in the app.)"
    Say '  Keep the topic name private: anyone who knows it can read these notifications.'
    Say ''
    if (Ask 'Send a test notification now?' $true) {
        try { Send-Ntfy 'Plex Library Helper is connected' "Notifications from $env:COMPUTERNAME work. You'll hear from it when a compression or estimate finishes." 'tada'; Say 'Sent. It should appear on your phone within a few seconds.' Green }
        catch { Say "Couldn't send it: $($_.Exception.Message)" Yellow }
    }
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
    Setup-Notifications
    Start-WithWindows
    Say ''
    Say 'All set. "Check status.cmd" shows what the helper is doing.' Green
}

# ---------------------------------------------------------------- emptying _TO_DELETE (permanent)
# Only ever run by a person at this PC (Empty _TO_DELETE.cmd), never from the dashboard or a job.
# Deletes whole dated batches (<drive>:\_TO_DELETE\yyyy-MM-dd\), nothing else: never the manifest, never
# anything outside _TO_DELETE, and never a batch containing a link (junction/symlink) that could point
# somewhere else.

function Trash-Roots {
    @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { Join-Path "$($_.DeviceID)\" $QuarantineDir } | Where-Object { Test-Path -LiteralPath $_ })
}

# One entry per dated batch folder, with its size and the titles the manifest says went into it
function Get-TrashBatches([string[]]$roots) {
    foreach ($root in $roots) {
        $titles = @{}
        $man = Join-Path $root 'manifest.jsonl'
        if (Test-Path -LiteralPath $man) {
            foreach ($line in Get-Content -LiteralPath $man -Encoding UTF8) {
                try { $m = $line | ConvertFrom-Json } catch { continue }
                if ($m.to -and $m.title -and $m.to -match ('\\' + [regex]::Escape($QuarantineDir) + '\\(\d{4}-\d{2}-\d{2})\\')) {
                    $key = $Matches[1]
                    if (-not $titles[$key]) { $titles[$key] = New-Object Collections.Generic.List[string] }
                    $t = "$($m.title)$(if ($m.year) { " ($($m.year))" })"
                    if (-not $titles[$key].Contains($t)) { $titles[$key].Add($t) }
                }
            }
        }
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }) {
            $all = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue)
            $links = @($all | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
            $when = [datetime]::MinValue; [void][datetime]::TryParseExact($d.Name, 'yyyy-MM-dd', $null, 'None', [ref]$when)
            [pscustomobject]@{
                Root = $root; Path = $d.FullName; Date = $when; Name = $d.Name
                Bytes = [long](($all | Where-Object { -not $_.PSIsContainer } | Measure-Object Length -Sum).Sum)
                Files = @($all | Where-Object { -not $_.PSIsContainer }).Count
                Titles = @($titles[$d.Name]); HasLinks = $links.Count -gt 0
            }
        }
    }
}

function Remove-TrashBatch($b) {
    # Belt and braces: exactly <drive>:\_TO_DELETE\yyyy-MM-dd, and no links inside
    $expect = '^[A-Za-z]:\\' + [regex]::Escape($QuarantineDir) + '\\\d{4}-\d{2}-\d{2}$'
    if ($script:TestDrive) { $expect = '^' + [regex]::Escape((Join-Path $script:TestDrive $QuarantineDir)) + '\\\d{4}-\d{2}-\d{2}$' }
    if ($b.Path -notmatch $expect) { throw "Refusing to delete $($b.Path): not a dated folder in $QuarantineDir" }
    if ($b.HasLinks) { throw "Skipped $($b.Path): it contains a link to another folder, delete it by hand after checking" }
    [IO.Directory]::Delete($b.Path, $true)
    [ordered]@{ time = (Get-Date).ToString('o'); deleted = $b.Path; bytes = $b.Bytes; files = $b.Files; titles = $b.Titles; by = "$env:USERNAME on $env:COMPUTERNAME" } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $b.Root 'manifest.jsonl') -Encoding UTF8
}

function Empty-Trash {
    Say "Empty _TO_DELETE on $env:COMPUTERNAME" Cyan
    Say 'Quarantined files wait in _TO_DELETE so you can put them back. Emptying deletes them for good.'
    Say ''
    $batches = @(Get-TrashBatches (Trash-Roots) | Sort-Object Root, Date)
    if (-not $batches.Count) { Say 'Nothing waiting: _TO_DELETE is empty (or missing) on every drive of this PC.' Green; return }
    foreach ($b in $batches) {
        Say ('{0}  {1}  {2,9}  {3} file(s){4}' -f $b.Root.Substring(0, 2), $b.Name, (Fmt-GB $b.Bytes), $b.Files, $(if ($b.HasLinks) { '  (contains a link: will be skipped)' } else { '' })) White
        $t = @($b.Titles | Where-Object { $_ })
        if ($t.Count) { Say ('      ' + (($t | Select-Object -First 6) -join ', ') + $(if ($t.Count -gt 6) { " and $($t.Count - 6) more" } else { '' })) }
    }
    $total = ($batches | Measure-Object Bytes -Sum).Sum
    $old = @($batches | Where-Object { $_.Date -lt (Get-Date).Date.AddDays(-7) })
    Say ''
    Say ('Total: {0} in {1} batch(es). {2} of it is older than 7 days.' -f (Fmt-GB $total), $batches.Count, (Fmt-GB (($old | Measure-Object Bytes -Sum).Sum)))
    Say '  A = delete all of it'
    Say '  O = delete only batches older than 7 days'
    Say '  N = delete nothing (default)'
    $c = ([string](Read-Host 'Choose A, O or N')).Trim().ToUpper()
    $pick = switch ($c) { 'A' { $batches } 'O' { $old } default { @() } }
    $pick = @($pick)
    if (-not $pick.Count) { Say 'Nothing deleted.'; return }
    Say ''
    Say ('This permanently deletes {0} ({1} batch(es)). It cannot be undone.' -f (Fmt-GB (($pick | Measure-Object Bytes -Sum).Sum)), $pick.Count) Yellow
    if (([string](Read-Host 'Type DELETE to confirm')).Trim() -cne 'DELETE') { Say 'Not confirmed. Nothing deleted.'; return }
    $freed = 0L
    foreach ($b in $pick) {
        try { Remove-TrashBatch $b; $freed += $b.Bytes; Log "Emptied $($b.Path): $(Fmt-GB $b.Bytes), $($b.Files) files"; Say "  deleted $($b.Path)" Green }
        catch { Log "Empty _TO_DELETE: $($_.Exception.Message)" 'WARN'; Say "  $($_.Exception.Message)" Yellow }
    }
    Say ''
    Say "Freed $(Fmt-GB $freed)." Green
}

# ---------------------------------------------------------------- main

if ($Setup) { Setup-Wizard; exit 0 }
if ($EmptyTrash) { Empty-Trash; exit 0 }   # works without Plex settings
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
        if (Notify-On) { "Phone notifications: on (ntfy topic $($Cfg.notify.topic) on $($Cfg.notify.server))" } else { 'Phone notifications: off (run Set up Plex Library Helper to turn them on)' }
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
