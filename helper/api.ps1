<#
  Plex Library Helper - the commands the app's windows use (loaded by library-helper.ps1)

  Plex Library Helper.exe shows the setup and status windows; everything it changes goes through here, so
  the tested PowerShell setup logic stays the only one:
      powershell -File library-helper.ps1 -Api <command> [-ApiArgs <json>]
  Output lines the app reads (anything else, like log lines, is ignored):
      @@PROGRESS {"text":..., "percent":...}   while working
      @@ASK {...}                              a question; the app writes the answer as one line to stdin
      @@RESULT {...}                           the answer, last line
      @@ERROR <message>                        it failed
#>

function Api-Out([string]$kind, $obj) {
    $line = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Compress -Depth 10 }
    [Console]::Out.WriteLine("@@$kind $line"); [Console]::Out.Flush()
}
function Api-Progress([string]$text, $percent = $null) { Api-Out 'PROGRESS' ([ordered]@{ text = $text; percent = $percent }) }

function Api-Config {
    if (-not (Test-Path $ConfigPath)) { return $null }
    try { Load-Config } catch { $null }
}

# Everything the windows show: settings, this PC's hardware and tools, what's installed where
function Api-Info {
    $script:Cfg = Api-Config
    $c = $script:Cfg
    $installed = Installed-Root
    $task = Get-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
    $tools = Find-Tools
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object FreeSpace -Descending | ForEach-Object { [ordered]@{ drive = $_.DeviceID; freeGB = [math]::Round($_.FreeSpace / 1GB) } })
    $old = if ($installed -and $installed.TrimEnd('\') -ne $Root.TrimEnd('\') -and (Test-Path -LiteralPath $installed)) { $installed } else { $null }
    $oldBusy = @()
    if ($old) {
        $oldBusy = @(Get-ChildItem -LiteralPath (Join-Path $old 'jobs') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.status.json' } | ForEach-Object {
            $jf = try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { $null }
            if ($jf -and -not $jf.finished -and (Worker-Alive $jf.workerPid)) { [string]$jf.title }
        })
    }
    [ordered]@{
        version = $Version; pc = $env:COMPUTERNAME; root = $Root; configured = [bool]$c
        serverName = $(if ($c) { $c.serverName }); serverUrl = $(if ($c) { $c.serverUrl })
        compress = $(if ($c -and $c.compress) { [ordered]@{ enabled = [bool]$c.compress.enabled; encoders = @($c.compress.encoders | Where-Object { $_ }); allowCpu = $c.compress.allowCpu -ne $false; workDir = $c.compress.workDir; calibration = $c.compress.calibration } })
        notify = $(if ($c -and $c.notify) { [ordered]@{ enabled = [bool]$c.notify.enabled; topic = $c.notify.topic; server = $c.notify.server; pauses = $c.notify.pauses -ne $false } })
        rip = $(if ($c -and $c.rip) { [ordered]@{ enabled = [bool]$c.rip.enabled; autoCompress = [bool]$c.rip.autoCompress; preset4k = $c.rip.preset4k; presetHD = $c.rip.presetHD } })
        dashboard = $DashboardUrl
        dashboardLink = $(if ($c -and $c.notify -and $c.notify.topic) { Dashboard-Link })
        task = [ordered]@{ installed = [bool]$task; root = $installed; state = $(if ($task) { [string]$task.State }) }
        oldCopy = $old; oldBusy = $oldBusy
        makemkv = [bool](@("${env:ProgramFiles(x86)}\MakeMKV\makemkv.exe", "$env:ProgramFiles\MakeMKV\makemkv.exe") | Where-Object { Test-Path -LiteralPath $_ })
        hardware = [ordered]@{
            cpu = [string](@(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)[0].Name).Trim(); threads = [Environment]::ProcessorCount
            gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { $_ -and $_ -notmatch 'Basic Display|Remote|Virtual' })
        }
        tools = [ordered]@{ ffmpeg = [bool]$tools.ffmpeg; ffprobe = [bool]$tools.ffprobe; mkvmerge = [bool]$tools.mkvmerge; dovi = [bool]$tools.dovi }
        winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
        drives = $drives
        suggestWorkDir = $(if ($c -and $c.compress -and $c.compress.workDir) { $c.compress.workDir } elseif ($drives.Count) { "$($drives[0].drive)\_PLD_WORK" })
        encoderLabels = $(($Encoders.Keys | ForEach-Object { @{ id = $_; label = $Encoders[$_].Label; cpu = $Encoders[$_].Kind -eq 'cpu'; codec = $Encoders[$_].Codec } }))
        levels = @($QualityTargets.Keys)
    }
}

# The copy Windows used to start (an older zip folder): take its sign-in, settings and dovi_tool
function Api-TakeOver {
    $info = Api-Info
    if (-not $info.oldCopy) { return [ordered]@{ copied = $false } }
    if ($info.oldBusy.Count) { throw "The old copy is compressing $($info.oldBusy -join ', '). Let it finish or Stop it in the dashboard first." }
    $copied = @()
    if (-not (Test-Path $ConfigPath) -and (Test-Path (Join-Path $info.oldCopy 'config.json'))) { Copy-Item -LiteralPath (Join-Path $info.oldCopy 'config.json') -Destination $ConfigPath; $copied += 'settings' }
    if (-not (Test-Path (Join-Path $Root 'tools\dovi_tool.exe')) -and (Test-Path (Join-Path $info.oldCopy 'tools\dovi_tool.exe'))) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root 'tools') | Out-Null
        Copy-Item -LiteralPath (Join-Path $info.oldCopy 'tools\dovi_tool.exe') -Destination (Join-Path $Root 'tools'); $copied += 'dovi_tool'
    }
    if ($copied.Count) { Log "Took over from the old copy in $($info.oldCopy): $($copied -join ', ')" }
    [ordered]@{ copied = $copied.Count -gt 0; what = $copied; from = $info.oldCopy }
}

function Api-SignIn($a) {
    Plex-SignIn { param($url) Api-Out 'PROGRESS' ([ordered]@{ text = 'Waiting for you to approve in the browser'; url = $url }) } {
        param($names)
        Api-Out 'ASK' ([ordered]@{ question = 'server'; options = $names })
        [Console]::In.ReadLine()
    }
    $script:Cfg = Load-Config
    [ordered]@{ serverName = $script:Cfg.serverName; serverUrl = $script:Cfg.serverUrl }
}

function Api-TestEncoders {
    $t = Find-Tools
    if (-not $t.ffmpeg) { throw 'ffmpeg is not installed yet.' }
    $n = $Encoders.Count; $script:apiI = 0
    $found = @(Test-Encoders $t.ffmpeg { param($id, $ok) $script:apiI++; Api-Out 'PROGRESS' ([ordered]@{ text = $Encoders[$id].Label; percent = [int]($script:apiI / $n * 100); id = $id; ok = $ok }) })
    [ordered]@{ encoders = $found }
}

function Api-InstallTool($a) {
    switch ([string]$a.name) {
        'ffmpeg'   { Api-Progress 'Installing ffmpeg with winget (a minute or two)'; Install-WithWinget 'Gyan.FFmpeg' 'ffmpeg' }
        'mkvmerge' { Api-Progress 'Installing MKVToolNix with winget'; Install-WithWinget 'MoritzBunkus.MKVToolNix' 'MKVToolNix' }
        'dovi'     { Api-Progress 'Downloading dovi_tool from github.com/quietvoid/dovi_tool'; Get-DoviTool }
        default    { throw "Unknown tool '$($a.name)'" }
    }
    $t = Find-Tools
    $key = if ($a.name -eq 'ffmpeg') { 'ffmpeg' } else { [string]$a.name }
    if (-not $t[$key]) { throw "$($a.name) still isn't found. If Windows asked for permission, allow it and try again." }
    [ordered]@{ ok = $true }
}

function Api-SaveCompress($a) {
    $script:Cfg = Load-Config
    if (-not $a.enabled) {
        if (Compress-On) { $script:Cfg.compress.enabled = $false; Save-Config; Log 'Compression turned off in the app.' }
        return [ordered]@{ enabled = $false }
    }
    if ($a.encoders) { $script:FoundEncoders = @($a.encoders) }
    $script:AllowCpu = [bool]$a.allowCpu
    if ($a.workDir) { $script:WorkDir = [string]$a.workDir }
    Enable-Compress
    if ($a.benchmark) { Request-Benchmark 'setup' }
    [ordered]@{ enabled = $true; workDir = $script:Cfg.compress.workDir }
}

# Phone notifications and/or the dashboard channel. phone: send notifications from this PC;
# topic: join the topic another PC made (a PC without its own notifications); pauses: pause alerts
function Api-SaveNotify($a) {
    $script:Cfg = Load-Config
    $n = $script:Cfg.notify
    $topic = [string]$a.topic
    if ($topic) {
        $topic = $topic.Trim() -replace '^.*#ntfy=', '' -replace '[&?].*$', ''
        if ($topic -notmatch '^pld-[a-z0-9]{8,}$') { throw "That doesn't look like a topic (it starts with pld-)." }
    } elseif ($n -and $n.topic) { $topic = $n.topic }
    elseif ($a.phone -or $a.channel) { $topic = New-Topic }
    if (-not $topic) {
        if ($n) { $n.enabled = $false; Save-Config }
        return [ordered]@{ topic = $null }
    }
    $server = if ($n -and $n.server) { $n.server } else { 'https://ntfy.sh' }
    $script:Cfg | Add-Member -NotePropertyName notify -Force -NotePropertyValue ([ordered]@{ enabled = [bool]$a.phone; server = $server; topic = $topic; pauses = [bool]$a.pauses })
    Save-Config
    Log "Notifications: phone $(if ($a.phone) { 'on' } else { 'off' }), topic $topic, pause alerts $(if ($a.pauses) { 'on' } else { 'off' })."
    [ordered]@{ topic = $topic; server = $server; dashboardLink = (Dashboard-Link); problem = (Test-Ntfy $server) }
}

function Api-SendTest {
    $script:Cfg = Load-Config
    if (-not ($script:Cfg.notify -and $script:Cfg.notify.topic)) { throw 'Notifications are not set up yet.' }
    $p = Test-Ntfy $script:Cfg.notify.server
    if ($p) { throw $p }
    Send-Ntfy 'Plex Library Helper is connected' "Notifications from $env:COMPUTERNAME work. You'll hear from it when a compression or estimate finishes." 'tada'
    [ordered]@{ sent = $true }
}

function Api-SaveRip($a) {
    $script:Cfg = Load-Config
    if ($a.enabled -and -not ($script:Cfg.notify -and $script:Cfg.notify.topic)) {
        $script:Cfg | Add-Member -NotePropertyName notify -Force -NotePropertyValue ([ordered]@{ enabled = $false; server = 'https://ntfy.sh'; topic = (New-Topic); pauses = $false })
    }
    $p4 = if ($a.preset4k -match '^(4k[xhns]|1080[hns])$') { $a.preset4k } else { '4kh' }
    $pH = if ($a.presetHD -match '^1080[hns]$') { $a.presetHD } else { '1080h' }
    $script:Cfg | Add-Member -NotePropertyName rip -Force -NotePropertyValue ([ordered]@{ enabled = [bool]$a.enabled; autoCompress = [bool]$a.autoCompress; preset4k = $p4; presetHD = $pH })
    Save-Config
    Log "Rip progress $(if ($a.enabled) { 'on' } else { 'off' }) (auto-compress $(if ($a.autoCompress) { "on: 4K $p4, Blu-ray $pH" } else { 'off' }))."
    [ordered]@{ ok = $true }
}

# Start with Windows from this folder (and stop the old copy's tray, if any). Won't switch while an
# encode is running, so it isn't left unattended.
function Api-InstallTask {
    if (@(Running-Workers).Count) { return [ordered]@{ started = $false; busy = $true } }
    Stop-ScheduledTask -TaskName 'Plex Library Helper' -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match 'tray\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & (Join-Path $Root 'install-helper.ps1') | Out-Null
    [ordered]@{ started = $true }
}

function Api-Uninstall {
    & (Join-Path $Root 'uninstall-helper.ps1') | Out-Null
    [ordered]@{ removed = $true }
}

function Api-Trash {
    @(Get-TrashBatches (Trash-Roots) | Sort-Object Root, Date | ForEach-Object {
        [ordered]@{ path = $_.Path; drive = $_.Root.Substring(0, 2); date = $_.Name; bytes = [long]$_.Bytes; files = $_.Files; links = [bool]$_.HasLinks; titles = @($_.Titles | Where-Object { $_ }) }
    })
}

# Permanently deletes the chosen dated batches (the app has asked you to type DELETE)
function Api-EmptyTrash($a) {
    $want = @($a.paths); $freed = 0L; $deleted = @(); $errors = @()
    foreach ($b in @(Get-TrashBatches (Trash-Roots) | Where-Object { $want -contains $_.Path })) {
        try { Remove-TrashBatch $b; $freed += $b.Bytes; $deleted += $b.Path; Log "Emptied $($b.Path) from the app: $(Fmt-GB $b.Bytes)" }
        catch { $errors += $_.Exception.Message }
    }
    [ordered]@{ freed = $freed; deleted = $deleted; errors = $errors }
}

function Invoke-Api([string]$name, [string]$json) {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $a = if ($json) { $json | ConvertFrom-Json } else { [pscustomobject]@{} }
    try {
        $r = switch ($name) {
            'info'         { Api-Info }
            'takeover'     { Api-TakeOver }
            'signin'       { Api-SignIn $a }
            'testencoders' { Api-TestEncoders }
            'installtool'  { Api-InstallTool $a }
            'savecompress' { Api-SaveCompress $a }
            'savenotify'   { Api-SaveNotify $a }
            'sendtest'     { Api-SendTest }
            'saverip'      { Api-SaveRip $a }
            'installtask'  { Api-InstallTask }
            'uninstall'    { Api-Uninstall }
            'trash'        { @{ batches = @(Api-Trash) } }
            'emptytrash'   { Api-EmptyTrash $a }
            default        { throw "Unknown command '$name'" }
        }
        Api-Out 'RESULT' $r
    } catch {
        Api-Out 'ERROR' ([string]$_.Exception.Message -replace '[\r\n]+', ' ')
    }
}
