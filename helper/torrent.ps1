<#
  Plex Library Helper - qBittorrent watcher (loaded by library-helper.ps1)

  Shows your downloads on the dashboard and in the app, and slows qBittorrent down while the same pause rules
  as compressions apply (Plex transcoding / playing, a full-screen game, "only when idle", "only overnight").
  Slowing down = qBittorrent's own "alternative speed limits" (the turtle): torrents keep going slowly and
  seeding continues; the helper switches it back once the rule has been clear for 30 seconds.
  - Only watches and switches the turtle: it never adds, removes or searches for torrents.
  - Talks to qBittorrent's Web UI on 127.0.0.1 only (setup can switch that on, for this PC only, no password).
  - Turns the turtle off only if it turned it on; if you switch it off yourself while a rule applies, it
    leaves it off until that rule has cleared.
  - Silent while qBittorrent isn't running.

  Config: torrent = { enabled, port, rules = { plex, plexall, game, idle, night }, notify }
  The dashboard hears about changes at once and progress every 20 minutes (ntfy.sh message limit); the app
  reads qBittorrent itself every 2 seconds.
  Pause all (dashboard / tray / app): the file jobs\TORRENTS-HOLD = slow down now, whatever the rules say.
#>

$TorrentHold = Join-Path $JobsDir 'TORRENTS-HOLD'
$TorrentSlowedFile = Join-Path $JobsDir 'torrents-slowed.txt'   # we turned the turtle on (survives restarts)
$script:Tor = @{ clearSince = $null; override = $false; incomplete = @{}; lastSig = ''; lastAt = [datetime]::MinValue; wasOn = $false }
$script:TorrentState = $null

function Torrent-On { [bool]($script:Cfg.torrent -and $script:Cfg.torrent.enabled) }
function Qbt-Url { "http://127.0.0.1:$(if ($script:Cfg -and $script:Cfg.torrent -and $script:Cfg.torrent.port) { [int]$script:Cfg.torrent.port } else { (Qbt-IniWebUi).port })" }
function Qbt-Running { [bool](Get-Process qbittorrent -ErrorAction SilentlyContinue) }

function Qbt-Get([string]$path) {
    $u = Qbt-Url
    $r = Invoke-WebRequest -Uri "$u$path" -Headers @{ Referer = $u } -TimeoutSec 5 -UseBasicParsing
    if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
}
function Qbt-Post([string]$path, [hashtable]$form = @{}) {
    $u = Qbt-Url
    Invoke-WebRequest -Uri "$u$path" -Method Post -Body $form -Headers @{ Referer = $u; Origin = $u } -TimeoutSec 5 -UseBasicParsing | Out-Null
}

# Downloading-type states (qBittorrent 5 calls paused ones "stopped")
$QbtDownloading = 'downloading', 'stalledDL', 'metaDL', 'forcedDL', 'queuedDL', 'checkingDL', 'allocating', 'forcedMetaDL'
$QbtSeeding = 'uploading', 'stalledUP', 'forcedUP', 'queuedUP', 'checkingUP'
function Qbt-StateName([string]$s) {
    switch -regex ($s) {
        '^(downloading|forcedDL)$' { 'Downloading'; break }
        '^(metaDL|forcedMetaDL)$' { 'Getting details'; break }
        '^stalledDL$' { 'Stalled'; break }
        '^queuedDL$' { 'Queued'; break }
        '^(checking|allocating)' { 'Checking'; break }
        '^(pausedDL|stoppedDL)$' { 'Paused'; break }
        '^(uploading|forcedUP|stalledUP|queuedUP)$' { 'Seeding'; break }
        '^(pausedUP|stoppedUP)$' { 'Done'; break }
        '^(error|missingFiles)$' { 'Error'; break }
        default { $s }
    }
}

# What the dashboard and app show: totals, the turtle, and the torrents that matter (downloading first)
function Torrent-Summary($list, [bool]$slowed, [string]$why) {
    $sorted = @($list | Sort-Object @{ e = { if ($QbtDownloading -contains $_.state) { 0 } elseif ($_.state -match '^(paused|stopped)DL$') { 1 } elseif ($QbtSeeding -contains $_.state) { 2 } else { 3 } } }, @{ e = { [double]$_.added_on }; Descending = $true })
    $show = @($sorted | Where-Object { $_.progress -lt 1 -or $QbtSeeding -contains $_.state } | Select-Object -First 8)
    [ordered]@{ kind = 'torrents'; v = 1; pc = $env:COMPUTERNAME; time = (Get-Date).ToString('o'); running = $true
        slowed = $slowed; why = $why; byHelper = (Test-Path -LiteralPath $TorrentSlowedFile); held = (Test-Path -LiteralPath $TorrentHold)
        dl = [long](@($list | Measure-Object dlspeed -Sum).Sum); up = [long](@($list | Measure-Object upspeed -Sum).Sum)
        downloading = @($list | Where-Object { $QbtDownloading -contains $_.state }).Count
        seeding = @($list | Where-Object { $QbtSeeding -contains $_.state }).Count
        total = @($list).Count
        torrents = @($show | ForEach-Object {
            $n = [string]$_.name; if ($n.Length -gt 90) { $n = $n.Substring(0, 89) + [char]0x2026 }
            [ordered]@{ name = $n; hash = ([string]$_.hash).Substring(0, 12); progress = [math]::Round([double]$_.progress * 100, 1); state = (Qbt-StateName $_.state)
                dl = [long]$_.dlspeed; up = [long]$_.upspeed; size = [long]$_.size; eta = $(if ([long]$_.eta -gt 0 -and [long]$_.eta -lt 8640000) { [long]$_.eta } else { $null }); ratio = [math]::Round([double]$_.ratio, 2) }
        }) }
}

# Called every poll
function Torrent-Poll {
    if (-not (Torrent-On)) {
        if ($script:Tor.wasOn) { $script:Tor.wasOn = $false; $script:TorrentState = $null }
        return
    }
    $script:Tor.wasOn = $true
    if (-not (Qbt-Running)) { Torrent-Publish ([ordered]@{ kind = 'torrents'; v = 1; pc = $env:COMPUTERNAME; time = (Get-Date).ToString('o'); running = $false }); return }
    # (PowerShell 5.1 returns a JSON array as one item: unroll it)
    try { $list = @(Qbt-Get '/api/v2/torrents/info' | ConvertFrom-Json | ForEach-Object { $_ }); $mode = [string](Qbt-Get '/api/v2/transfer/speedLimitsMode') }
    catch {
        Torrent-Publish ([ordered]@{ kind = 'torrents'; v = 1; pc = $env:COMPUTERNAME; time = (Get-Date).ToString('o'); running = $true; problem = "qBittorrent's Web UI doesn't answer on $(Qbt-Url) (set it up in Plex Library Helper > Settings)" })
        return
    }

    # the rules (same code as compressions)
    $script:PlexUrl = $script:Cfg.serverUrl; $script:PlexToken = $script:Cfg.Token
    $script:NightWindow = $(if ($script:Cfg.compress -and $script:Cfg.compress.nightWindow) { $script:Cfg.compress.nightWindow } else { '23:00-07:00' })
    $why = Pause-Reason $script:Cfg.torrent.rules $TorrentHold
    $turtle = $mode.Trim() -eq '1'
    $ours = Test-Path -LiteralPath $TorrentSlowedFile
    if ($ours -and -not $turtle) { $script:Tor.override = [bool]$why; [IO.File]::Delete($TorrentSlowedFile); $ours = $false; if ($why) { Log "qBittorrent: you switched the speed limit off yourself; leaving it off until '$why' clears" } }
    if ($why) {
        $script:Tor.clearSince = $null
        if (-not $turtle -and -not $script:Tor.override) {
            try { Qbt-Post '/api/v2/transfer/toggleSpeedLimitsMode'; "$why at $(Get-Date -Format o)" | Out-File -LiteralPath $TorrentSlowedFile -Encoding ascii; $turtle = $true; Log "qBittorrent slowed down: $why" }
            catch { Log "Couldn't slow qBittorrent down: $($_.Exception.Message)" 'WARN' }
        }
    } else {
        $script:Tor.override = $false
        if ($ours -and $turtle) {
            if (-not $script:Tor.clearSince) { $script:Tor.clearSince = Get-Date }
            elseif (((Get-Date) - $script:Tor.clearSince).TotalSeconds -ge 30) {
                try { Qbt-Post '/api/v2/transfer/toggleSpeedLimitsMode'; [IO.File]::Delete($TorrentSlowedFile); $turtle = $false; $script:Tor.clearSince = $null; Log 'qBittorrent back to full speed' }
                catch { Log "Couldn't switch qBittorrent back to full speed: $($_.Exception.Message)" 'WARN' }
            }
        }
    }

    # finished downloads -> phone
    foreach ($t in $list) {
        $h = [string]$t.hash
        if ([double]$t.progress -lt 1) { $script:Tor.incomplete[$h] = $true; continue }
        if ($script:Tor.incomplete.ContainsKey($h)) {
            $script:Tor.incomplete.Remove($h)
            Log "qBittorrent finished: $($t.name)"
            if ((Notify-On) -and $script:Cfg.torrent.notify -ne $false) { try { Send-Ntfy "Downloaded: $($t.name)" "$(Fmt-GB ([double]$t.size)) on $env:COMPUTERNAME." 'inbox_tray' 'low' } catch { } }
        }
    }
    Torrent-Publish (Torrent-Summary $list $turtle $(if ($turtle -and (Test-Path -LiteralPath $TorrentSlowedFile)) { $why } else { '' }))
}

# To the app (state.json, every poll) and the dashboard (ntfy: on change, and every minute while downloading)
function Torrent-Publish($s) {
    $script:TorrentState = $s
    if (-not (Channel-On)) { return }
    # at once when something starts, finishes, stalls or gets slowed down; progress every 20 minutes while
    # downloading; otherwise hourly (ntfy.sh's daily message limit, see Publish-Live)
    $sig = "$($s.running)|$($s.slowed)|$($s.problem)|$($s.held)|" + (@($s.torrents) | ForEach-Object { "$($_.hash)/$($_.state)" }) -join ','
    $busy = [int]$s.downloading -gt 0
    $age = ((Get-Date) - $script:Tor.lastAt).TotalMinutes
    if ($sig -ne $script:Tor.lastSig -or ($busy -and $age -ge 20) -or $age -ge 60) {
        try { Publish-Live $s; $script:Tor.lastSig = $sig; $script:Tor.lastAt = Get-Date } catch { }
    }
}

function Set-TorrentHold([bool]$on, [string]$by) {
    if (-not (Test-Path $JobsDir)) { New-Item -ItemType Directory -Force $JobsDir | Out-Null }
    if ($on -and -not (Test-Path -LiteralPath $TorrentHold)) { "Slowed from $by at $(Get-Date -Format o)" | Out-File -LiteralPath $TorrentHold -Encoding ascii; Log "Torrents slowed down from $by" }
    elseif (-not $on -and (Test-Path -LiteralPath $TorrentHold)) { [IO.File]::Delete($TorrentHold); Log "Torrents back to their rules from $by" }
    $script:Tor.lastSig = ''
}

# ---------------------------------------------------------------- setup (used by the app, api.ps1)

function Qbt-Ini { Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini' }

function Qbt-Installed {
    [bool](@("$env:ProgramFiles\qBittorrent\qbittorrent.exe", "${env:ProgramFiles(x86)}\qBittorrent\qbittorrent.exe") | Where-Object { Test-Path -LiteralPath $_ }) -or (Test-Path (Qbt-Ini))
}

# The Web UI settings in qBittorrent.ini ([Preferences] WebUI\...), never the password hash
function Qbt-IniWebUi {
    $ini = Qbt-Ini
    $v = @{}
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in Get-Content -LiteralPath $ini) { if ($line -match '^WebUI\\(Enabled|Port|Address|LocalHostAuth)=(.*)$') { $v[$Matches[1]] = $Matches[2].Trim() } }
    }
    [ordered]@{ enabled = $v['Enabled'] -eq 'true'; port = $(if ($v['Port']) { [int]$v['Port'] } else { 8080 }); address = $(if ($v['Address']) { $v['Address'] } else { '*' }); localNoPassword = $v['LocalHostAuth'] -eq 'false' }
}

# Switch the Web UI on for this PC only (127.0.0.1, no password from this PC). qBittorrent must be closed:
# it rewrites its settings file when it exits. A copy of the old file is kept next to it.
function Qbt-EnableWebUi([int]$port = 8080) {
    if (Qbt-Running) { throw 'Close qBittorrent first (File > Exit), then try again: it rewrites its settings when it closes.' }
    $ini = Qbt-Ini
    if (-not (Test-Path -LiteralPath $ini)) { New-Item -ItemType Directory -Force (Split-Path $ini) | Out-Null; [IO.File]::WriteAllText($ini, "[Preferences]`r`n") }
    Copy-Item -LiteralPath $ini -Destination "$ini.before-plex-library-helper" -Force
    $lines = [Collections.Generic.List[string]]@(Get-Content -LiteralPath $ini)
    $want = [ordered]@{ 'WebUI\Enabled' = 'true'; 'WebUI\Address' = '127.0.0.1'; 'WebUI\Port' = [string]$port; 'WebUI\LocalHostAuth' = 'false' }
    $sec = $lines.IndexOf('[Preferences]')
    if ($sec -lt 0) { $lines.Add('[Preferences]'); $sec = $lines.Count - 1 }
    foreach ($k in $want.Keys) {
        $i = -1
        for ($j = $sec + 1; $j -lt $lines.Count -and -not $lines[$j].StartsWith('['); $j++) { if ($lines[$j].StartsWith("$k=")) { $i = $j; break } }
        if ($i -ge 0) { $lines[$i] = "$k=$($want[$k])" } else { $lines.Insert($sec + 1, "$k=$($want[$k])") }
    }
    [IO.File]::WriteAllLines($ini, $lines, (New-Object Text.UTF8Encoding $false))
    Log "qBittorrent's Web UI switched on for this PC only (127.0.0.1:$port, no password from this PC); old settings kept as $ini.before-plex-library-helper"
}
