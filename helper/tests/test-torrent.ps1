$ErrorActionPreference = 'Stop'
# Tests the qBittorrent watcher against a fake qBittorrent (never the real one). Needs Python.
#   powershell -ExecutionPolicy Bypass -File helper\tests\test-torrent.ps1
$h = Split-Path $PSScriptRoot -Parent
$srv = Start-Process python -ArgumentList "`"$PSScriptRoot\fake_qbt.py`"", '18080' -PassThru -WindowStyle Hidden; Start-Sleep 2
try {
$ast = [Management.Automation.Language.Parser]::ParseFile("$h\library-helper.ps1", [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:Logs = @(); function Log($m, $l) { $script:Logs += $m }
$Root = Join-Path $env:TEMP 'pld-tortest'; $JobsDir = Join-Path $Root 'jobs'
if (Test-Path $Root) { [IO.Directory]::Delete($Root, $true) }; New-Item -ItemType Directory -Force $JobsDir | Out-Null
$env:APPDATA = Join-Path $Root 'appdata'   # a pretend qBittorrent settings folder
. "$h\pause.ps1"; . "$h\torrent.ps1"
$script:Published = @(); function Publish-Live($o) { $script:Published += , $o }
function Channel-On { $true }
$script:Sent = @(); function Send-Ntfy($t, $m) { $script:Sent += $t }; function Notify-On { $true }
function Qbt-Running { $true }                       # the fake answers; the real qBittorrent isn't touched
function Fmt-GB($b) { '{0:N1} GB' -f ($b / 1GB) }
$script:Cfg = [pscustomobject]@{ serverUrl = $null; torrent = [pscustomobject]@{ enabled = $true; port = 18080; notify = $true; rules = [pscustomobject]@{ plex = $false; game = $false } } }
$pass = 0; $fail = 0
function Check($n, $c) { if ($c) { $script:pass++; "PASS  $n" } else { $script:fail++; "FAIL  $n" } }
function Fake($q) { Invoke-RestMethod -Method Post "http://127.0.0.1:18080/test/set?$q" }
function FakeState { Invoke-RestMethod "http://127.0.0.1:18080/test/state" }

Torrent-Poll
$s = $script:TorrentState
Check 'reads torrents: 1 downloading, 1 seeding, 3 total' ($s.downloading -eq 1 -and $s.seeding -eq 1 -and $s.total -eq 3)
Check 'downloading first, with progress, speed and time left' ($s.torrents[0].name -like 'Big.Buck*' -and $s.torrents[0].progress -eq 42 -and $s.torrents[0].eta -eq 1300 -and $s.torrents[0].state -eq 'Downloading')
Check 'stopped one shows as Paused' (@($s.torrents | Where-Object { $_.state -eq 'Paused' }).Count -eq 1)
Check 'not slowed with no rule' (-not $s.slowed -and (FakeState).toggles -eq 0)
Check 'published to the dashboard' ($script:Published.Count -ge 1 -and $script:Published[-1].kind -eq 'torrents')

Set-TorrentHold $true 'test'; Torrent-Poll
Check 'a rule (hold) slows it down: turtle on, remembered as ours' ((FakeState).turtle -eq 1 -and (Test-Path $TorrentSlowedFile) -and $script:TorrentState.slowed -and $script:TorrentState.why -like '*paused from*')
Torrent-Poll
Check 'stays slowed without toggling again' ((FakeState).toggles -eq 1)

Set-TorrentHold $false 'test'; Torrent-Poll
Check 'rule cleared: waits 30 s before full speed' ((FakeState).turtle -eq 1)
$script:Tor.clearSince = (Get-Date).AddSeconds(-31); Torrent-Poll
Check 'then back to full speed, and forgets it was ours' ((FakeState).turtle -eq 0 -and -not (Test-Path $TorrentSlowedFile))

# the turtle you switched on yourself is never switched off
Fake 'turtle=1' | Out-Null; Torrent-Poll; $script:Tor.clearSince = (Get-Date).AddSeconds(-31); Torrent-Poll
Check 'leaves your own speed limit alone' ((FakeState).turtle -eq 1 -and (FakeState).toggles -eq 2)
Fake 'turtle=0' | Out-Null

# you switch it off while a rule applies: it stays off until the rule clears
Set-TorrentHold $true 'test'; Torrent-Poll
Fake 'turtle=0' | Out-Null; Torrent-Poll; Torrent-Poll
Check 'you switching it off wins while that rule lasts' ((FakeState).turtle -eq 0 -and $script:Logs -match 'switched the speed limit off yourself')
Set-TorrentHold $false 'test'; Torrent-Poll; Set-TorrentHold $true 'test'; Torrent-Poll
Check '...and it slows again the next time a rule starts' ((FakeState).turtle -eq 1)
Set-TorrentHold $false 'test'; $script:Tor.clearSince = (Get-Date).AddSeconds(-31); Torrent-Poll; Torrent-Poll

# finished downloads -> phone, once
Fake 'progress=1' | Out-Null; Torrent-Poll; Torrent-Poll
Check 'finished download: one phone notification' (@($script:Sent | Where-Object { $_ -like 'Downloaded: Big.Buck*' }).Count -eq 1)
Check 'already-finished torrents at start never notify' (-not ($script:Sent -like '*Sintel*'))

# qBittorrent not answering
$script:Cfg.torrent.port = 18099; Torrent-Poll
Check 'Web UI not answering: says so instead of failing' ($script:TorrentState.problem -like "*doesn't answer*")
$script:Cfg.torrent.port = 18080

# turned off: nothing is touched
$script:Cfg.torrent.enabled = $false; $before = (FakeState).toggles; Torrent-Poll
Check 'off: leaves qBittorrent alone and shows nothing' ((FakeState).toggles -eq $before -and $null -eq $script:TorrentState)

# setup: switching the Web UI on in a copy of the settings file
function Qbt-Running { $false }
New-Item -ItemType Directory -Force "$env:APPDATA\qBittorrent" | Out-Null
"[LegalNotice]`r`nAccepted=true`r`n`r`n[Preferences]`r`nSession\DefaultSavePath=D:\\`r`nWebUI\Enabled=false`r`nWebUI\Password_PBKDF2=`"@ByteArray(secret)`"`r`n" | Set-Content "$env:APPDATA\qBittorrent\qBittorrent.ini" -Encoding ascii
Qbt-EnableWebUi 8080
$w = Qbt-IniWebUi; $ini = Get-Content "$env:APPDATA\qBittorrent\qBittorrent.ini" -Raw
Check 'Web UI on, this PC only, no password from this PC' ($w.enabled -and $w.address -eq '127.0.0.1' -and $w.port -eq 8080 -and $w.localNoPassword)
Check 'other settings kept, a backup made' ($ini -match 'DefaultSavePath=D:' -and $ini -match 'Password_PBKDF2' -and $ini -match 'LegalNotice' -and (Test-Path "$env:APPDATA\qBittorrent\qBittorrent.ini.before-plex-library-helper"))
function Qbt-Running { $true }
$threw = $false; try { Qbt-EnableWebUi 8080 } catch { $threw = $_.Exception.Message -like 'Close qBittorrent*' }
Check 'refuses while qBittorrent is open' $threw
"`n$pass passed, $fail failed"
[IO.Directory]::Delete($Root, $true)
} finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
