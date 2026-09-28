<#
  Plex Library Helper - live channel, pause switch, _TO_DELETE on the dashboard, tray status
  (loaded by library-helper.ps1; uses its Send-Ntfy, Log, Fmt-GB, Running-Workers, Get-TrashBatches ...)

  The dashboard and this helper talk through the private ntfy topic:
    <topic>-status  helper -> dashboard   {"kind":"helper"|"trash"|"trashResult"|"rip", "pc":..., ...}
    <topic>-status  also {"kind":"caps"}: what this PC can compress with and its benchmark results (bench.ps1)
    <topic>-cmd     dashboard -> helper   {"cmd":"pause"|"emptytrash"|"autocompress"|"benchmark", "pc":..., ...}
  Every PC's helper reads the same command topic and only acts on commands naming it.

  Pausing: the file jobs\PAUSED. While it exists no compression or estimate starts, and a running one is
  frozen in place (compress.ps1 checks it with its other pause rules). The tray menu and the dashboard
  both just create or remove it.

  Emptying _TO_DELETE from the dashboard deletes for good, so a request is only carried out if it names
  this PC, is less than 10 minutes old, hasn't been carried out before (ntfy keeps old messages, so a
  restarted helper sees them again), and only for dated batches this helper itself reported.
#>

$PauseFile = Join-Path $JobsDir 'PAUSED'
$StateFile = Join-Path $Root 'state.json'
$script:LiveStarted = Get-Date
$script:CmdSince = $null
$script:LastHelperMsg = @{ sig = ''; at = [datetime]::MinValue }
$script:LastTrashMsg = @{ sig = ''; at = [datetime]::MinValue }

function Channel-On { [bool]($script:Cfg.notify -and $script:Cfg.notify.topic) }

function Publish-Live($obj) {
    $n = $script:Cfg.notify
    $body = [ordered]@{ topic = "$($n.topic)-status"; message = ($obj | ConvertTo-Json -Compress -Depth 5); title = [string]$obj.kind; priority = 1 }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))
    Invoke-RestMethod -Method Post -Uri $n.server.TrimEnd('/') -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
}

# ---------------------------------------------------------------- pause

function Is-Paused { Test-Path -LiteralPath $PauseFile }
function Set-Paused([bool]$on, [string]$by) {
    if (-not (Test-Path $JobsDir)) { New-Item -ItemType Directory -Force $JobsDir | Out-Null }
    if ($on -and -not (Is-Paused)) { "Paused from $by at $(Get-Date -Format o)" | Out-File -LiteralPath $PauseFile -Encoding ascii; Log "Compressions paused from $by" }
    elseif (-not $on -and (Is-Paused)) { Remove-Item -LiteralPath $PauseFile -Force; Log "Compressions resumed from $by" }
}

# ---------------------------------------------------------------- commands

function Done-Requests { $f = Join-Path $JobsDir 'done-requests.txt'; if (Test-Path $f) { @(Get-Content -LiteralPath $f) } else { @() } }
function Remember-Request([string]$id) { if (-not (Test-Path $JobsDir)) { New-Item -ItemType Directory -Force $JobsDir | Out-Null }; Add-Content -LiteralPath (Join-Path $JobsDir 'done-requests.txt') -Value $id }

function Read-Commands {
    if (-not (Channel-On)) { return }
    $n = $script:Cfg.notify
    $since = if ($script:CmdSince) { $script:CmdSince } else { '10m' }
    $raw = (Invoke-WebRequest -Uri "$($n.server.TrimEnd('/'))/$($n.topic)-cmd/json?poll=1&since=$since" -UseBasicParsing -TimeoutSec 15).Content
    foreach ($line in ($raw -split "`n" | Where-Object { $_.Trim() })) {
        $m = try { $line | ConvertFrom-Json } catch { $null }
        if (-not $m -or $m.event -ne 'message') { continue }
        $script:CmdSince = $m.id
        $c = try { $m.message | ConvertFrom-Json } catch { $null }
        if (-not $c) { continue }
        $sent = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.time).LocalDateTime
        try { Handle-Command $c $sent $m.id } catch { Log "Command '$($c.cmd)' failed: $($_.Exception.Message)" 'WARN' }
    }
}

function Handle-Command($c, [datetime]$sent, [string]$msgId) {
    switch ([string]$c.cmd) {
        'autocompress' { Handle-RipCommand $c }
        'benchmark' {
            if ($c.pc -ne $env:COMPUTERNAME) { return }
            if ((Done-Requests) -contains $msgId) { return }
            Remember-Request $msgId
            if (((Get-Date) - $sent).TotalMinutes -gt 10) { return }                # an old request replayed to a restarted helper
            if ($c.stop) { Stop-Benchmark 'the dashboard' } elseif (Compress-On) { Request-Benchmark 'the dashboard' }
            $script:LastCapsMsg.sig = ''
        }
        'pause' {
            if ($c.pc -and $c.pc -ne $env:COMPUTERNAME) { return }
            if ($sent -lt $script:LiveStarted.AddSeconds(-60)) { return }   # from before this helper started
            Set-Paused ([bool]$c.on) 'the dashboard'
            $script:LastHelperMsg.sig = ''                                   # report the change straight away
        }
        'emptytrash' {
            if ($c.pc -ne $env:COMPUTERNAME) { return }
            $req = [string]$c.req; if (-not $req) { $req = $msgId }
            if ((Done-Requests) -contains $req) { return }
            Remember-Request $req                                            # never twice, even if it fails
            if (((Get-Date) - $sent).TotalMinutes -gt 10) { Log "Ignored an old request to empty _TO_DELETE ($req, sent $sent)" 'WARN'; return }
            Empty-TrashRequest @($c.batches) $req
        }
    }
}

# ---------------------------------------------------------------- _TO_DELETE

function Trash-Summary {
    $b = @(Get-TrashBatches (Trash-Roots) | Sort-Object Root, Date)
    [ordered]@{ kind = 'trash'; v = 1; pc = $env:COMPUTERNAME; time = (Get-Date).ToString('o')
        total = [long](($b | Measure-Object Bytes -Sum).Sum)
        batches = @($b | ForEach-Object { [ordered]@{ path = $_.Path; drive = $_.Root.Substring(0, 2); date = $_.Name; bytes = [long]$_.Bytes; files = $_.Files; links = [bool]$_.HasLinks; titles = @($_.Titles | Where-Object { $_ } | Select-Object -First 8); more = [math]::Max(0, @($_.Titles).Count - 8) } }) }
}

function Empty-TrashRequest([string[]]$paths, [string]$req) {
    $current = @(Get-TrashBatches (Trash-Roots))
    $pick = @($current | Where-Object { $paths -contains $_.Path })      # only batches this helper reported
    $freed = 0L; $deleted = @(); $errors = @()
    foreach ($b in $pick) {
        try { Remove-TrashBatch $b; $freed += $b.Bytes; $deleted += $b.Path; Log "Emptied $($b.Path) from the dashboard: $(Fmt-GB $b.Bytes)" }
        catch { $errors += $_.Exception.Message; Log "Empty _TO_DELETE: $($_.Exception.Message)" 'WARN' }
    }
    $missing = @($paths | Where-Object { @($pick | ForEach-Object { $_.Path }) -notcontains $_ })
    if ($missing.Count) { $errors += "not found any more: $($missing -join ', ')" }
    try { Publish-Live ([ordered]@{ kind = 'trashResult'; v = 1; pc = $env:COMPUTERNAME; req = $req; time = (Get-Date).ToString('o'); freed = $freed; deleted = $deleted; errors = $errors }) } catch { }
    $script:LastTrashMsg.sig = ''
    if (Notify-On -and $deleted.Count) { try { Send-Ntfy "Emptied _TO_DELETE on $env:COMPUTERNAME" "Freed $(Fmt-GB $freed) ($($deleted.Count) batch$(if ($deleted.Count -ne 1) { 'es' }))$(if ($errors.Count) { ". Problems: $($errors -join '; ')" })." 'wastebasket' } catch { } }
}

# ---------------------------------------------------------------- what the helper is doing (dashboard + tray)

function Helper-Summary {
    $jobs = @(Running-Workers | ForEach-Object {
        $st = Read-Json ([IO.Path]::ChangeExtension((Join-Path $JobsDir "$($_.jobId).json"), $null).TrimEnd('.') + '.status.json')
        [ordered]@{ title = $_.title; year = $_.year; mode = $_.mode; preset = $_.preset; scope = $_.scope
            percent = $(if ($st) { [int]$st.percent } else { 0 }); secsLeft = $(if ($st -and $st.secsLeft) { [long]$st.secsLeft } else { $null })
            what = $(if ($st -and $st.paused) { "paused: $($st.paused)" } elseif ($st) { [string]$st.phase } else { 'starting' }) }
    })
    [ordered]@{ kind = 'helper'; v = 1; pc = $env:COMPUTERNAME; version = $Version; time = (Get-Date).ToString('o')
        compress = (Compress-On); paused = (Is-Paused); jobs = $jobs }
}

# Called every poll: commands in, status out (only when something changed, plus a heartbeat)
function Live-Poll {
    $h = Helper-Summary
    $rip = if ($script:Rip -and $script:Rip.active) { $script:Rip } else { $null }
    # the tray reads this file every few seconds
    $state = [ordered]@{ pid = $PID; root = $Root; version = $Version; time = (Get-Date).ToString('o'); paused = $h.paused; compress = $h.compress; jobs = $h.jobs
        rip = $(if ($script:RipLastStatus -and $script:RipLastStatus.state -eq 'ripping') { $script:RipLastStatus } else { $null })
        channel = (Channel-On); dashboard = $DashboardUrl }
    try { ($state | ConvertTo-Json -Depth 6) | Out-File -LiteralPath "$StateFile.tmp" -Encoding UTF8; Move-Item -LiteralPath "$StateFile.tmp" -Destination $StateFile -Force } catch { }

    if (-not (Channel-On)) { return }
    try { Read-Commands } catch { }
    $h = Helper-Summary
    $sig = "$($h.paused)|" + (($h.jobs | ForEach-Object { "$($_.title)/$([int]($_.percent / 5))/$($_.what)" }) -join ',')
    if ($sig -ne $script:LastHelperMsg.sig -or ((Get-Date) - $script:LastHelperMsg.at).TotalMinutes -ge 5) {
        try { Publish-Live $h; $script:LastHelperMsg = @{ sig = $sig; at = Get-Date } } catch { }
    }
    if (((Get-Date) - $script:LastTrashMsg.at).TotalMinutes -ge 5 -or -not $script:LastTrashMsg.sig) {
        $t = Trash-Summary
        $tsig = ($t.batches | ForEach-Object { "$($_.path)=$($_.bytes)" }) -join ','
        if ($tsig -ne $script:LastTrashMsg.sig -or ((Get-Date) - $script:LastTrashMsg.at).TotalMinutes -ge 15) {
            try { Publish-Live $t; $script:LastTrashMsg = @{ sig = $tsig; at = Get-Date } } catch { }
        } else { $script:LastTrashMsg.at = Get-Date }
    }
}

# ---------------------------------------------------------------- tray icon

# Start the tray icon unless one from this folder is already running: the app (Plex Library Helper.exe, which
# also has the windows) when installed by it, else tray.ps1
function Start-Tray {
    $exe = Join-Path $Root 'Plex Library Helper.exe'
    if (Test-Path -LiteralPath $exe) {
        $mine = @(Get-Process -Name 'Plex Library Helper' -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $exe } catch { $false } })
        if (-not $mine.Count) { Start-Process -FilePath $exe -ArgumentList '--tray' | Out-Null }
        return
    }
    $tray = Join-Path $Root 'tray.ps1'
    if (-not (Test-Path -LiteralPath $tray)) { return }
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($tray) })
    if ($running.Count) { return }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$tray`"" | Out-Null
}
