<#
  Plex Library Helper - tray icon (started by library-helper.ps1; one per helper folder)

  Shows what the helper is doing in the Windows notification area and gives quick access to it:
  hover for a one-line status, double-click for the dashboard, right-click for the menu. It reads
  state.json, which the helper rewrites every poll; pausing just creates/removes jobs\PAUSED.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = $PSScriptRoot
$StateFile = Join-Path $Root 'state.json'
$PauseFile = Join-Path $Root 'jobs\PAUSED'
$TaskName = 'Plex Library Helper'

# One tray icon per helper folder
$mutexName = 'PlexLibraryHelperTray_' + ($Root.ToLower() -replace '[^a-z0-9]', '_')
$mutex = [Threading.Mutex]::new($false, $mutexName)
if (-not $mutex.WaitOne(0)) { return }

# The dashboard's icon (a chevron on a rounded square), drawn in the colour for the current state
function New-TrayIcon([string]$hex) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $bg = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($hex))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $r = 8; $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc(31 - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc(31 - $r * 2, 31 - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, 31 - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
    $g.FillPath($bg, $path)
    $ink = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#1a1203'))
    $g.FillPolygon($ink, [Drawing.Point[]]@((New-Object Drawing.Point 9, 7), (New-Object Drawing.Point 16, 7), (New-Object Drawing.Point 23, 16), (New-Object Drawing.Point 16, 25), (New-Object Drawing.Point 9, 25), (New-Object Drawing.Point 16, 16)))
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$Icons = @{ idle = (New-TrayIcon '#e5a00d'); busy = (New-TrayIcon '#5fd4b0'); paused = (New-TrayIcon '#9aa0a6'); off = (New-TrayIcon '#ff8a80') }

function Read-State { try { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { $null } }
function Helper-Alive($s) { $s -and $s.pid -and (Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue) -and ((Get-Date) - [datetime]$s.time).TotalMinutes -lt 3 }
function Run-Cmd([string]$file) { Start-Process -FilePath (Join-Path $Root $file) -WorkingDirectory $Root }
function Short([string]$s, [int]$n) { if ($s.Length -le $n) { $s } else { $s.Substring(0, $n - 1) + [char]0x2026 } }

$ni = New-Object Windows.Forms.NotifyIcon
$ni.Icon = $Icons.idle; $ni.Text = 'Plex Library Helper'; $ni.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
$miStatus = $menu.Items.Add('Starting...'); $miStatus.Enabled = $false
[void]$menu.Items.Add('-')
$miDash = $menu.Items.Add('Open dashboard')
$miPause = $menu.Items.Add('Pause all compressions')
[void]$menu.Items.Add('-')
$miCheck = $menu.Items.Add('Status...')
$miLogs = $menu.Items.Add('Open log folder')
$miTrash = $menu.Items.Add('Empty _TO_DELETE...')
$miSetup = $menu.Items.Add('Run setup again...')
[void]$menu.Items.Add('-')
$miRestart = $menu.Items.Add('Restart helper')
$miQuit = $menu.Items.Add('Quit')
$ni.ContextMenuStrip = $menu

$script:state = $null
$openDashboard = { $u = if ($script:state -and $script:state.dashboard) { $script:state.dashboard } else { 'https://dispatcher21.github.io/Plex-Library-Helper/' }; Start-Process $u }
$ni.add_DoubleClick($openDashboard)
$miDash.add_Click($openDashboard)
$miPause.add_Click({
    if (Test-Path -LiteralPath $PauseFile) { Remove-Item -LiteralPath $PauseFile -Force }
    else { New-Item -ItemType Directory -Force (Split-Path $PauseFile) | Out-Null; "Paused from the tray at $(Get-Date -Format o)" | Out-File -LiteralPath $PauseFile -Encoding ascii }
    Update-Tray
})
$miCheck.add_Click({ Run-Cmd 'Check status.cmd' })
$miLogs.add_Click({ Start-Process explorer.exe (Join-Path $Root 'logs') })
$miTrash.add_Click({ Run-Cmd 'Empty _TO_DELETE.cmd' })
$miSetup.add_Click({ Run-Cmd 'Set up Plex Library Helper.cmd' })
$miRestart.add_Click({
    # Encodes are separate programs, so they keep running; the restarted helper picks them up again
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($script:state -and $script:state.pid) { Stop-Process -Id ([int]$script:state.pid) -Force -ErrorAction SilentlyContinue }
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $ni.ShowBalloonTip(3000, 'Plex Library Helper', 'Restarting...', 'Info')
})
$miQuit.add_Click({
    $busy = $script:state -and @($script:state.jobs).Count
    $msg = if ($busy) { "An encode is running. It keeps going, but nothing reports on it until the helper starts again (next sign-in, or Run setup again).`n`nQuit the Plex Library Helper?" } else { "Quit the Plex Library Helper? It starts again the next time you sign in to Windows." }
    if ([Windows.Forms.MessageBox]::Show($msg, 'Plex Library Helper', 'YesNo', 'Question') -ne 'Yes') { return }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($script:state -and $script:state.pid) { Stop-Process -Id ([int]$script:state.pid) -Force -ErrorAction SilentlyContinue }
    $ni.Visible = $false; [Windows.Forms.Application]::Exit()
})

function Update-Tray {
    $s = Read-State; $script:state = $s
    $paused = Test-Path -LiteralPath $PauseFile
    $miPause.Text = if ($paused) { 'Resume compressions' } else { 'Pause all compressions' }
    if (-not (Helper-Alive $s)) {
        $ni.Icon = $Icons.off; $ni.Text = 'Plex Library Helper: not running'; $miStatus.Text = 'Not running (Restart helper to start it)'
        return
    }
    $parts = @(); $lines = @()
    foreach ($j in @($s.jobs)) {
        if (-not $j) { continue }
        $left = if ($j.secsLeft) { ', ' + $(if ($j.secsLeft -ge 3600) { '{0}h{1:00}' -f [math]::Floor($j.secsLeft / 3600), [math]::Floor(($j.secsLeft % 3600) / 60) } else { '{0} min' -f [math]::Ceiling($j.secsLeft / 60) }) + ' left' } else { '' }
        $verb = if ($j.mode -eq 'estimate') { 'Estimating' } else { 'Compressing' }
        $parts += "$(Short $j.title 14) $($j.percent)%"
        $lines += "$verb $($j.title): $($j.percent)%$left$(if ($j.what -like 'paused*') { " ($($j.what))" })"
    }
    if ($s.rip) { $parts += "Rip $([math]::Round([double]$(if ($s.rip.totalPercent) { $s.rip.totalPercent } else { $s.rip.percent })))%"; $lines += "Ripping $($s.rip.folder): $([math]::Round([double]$s.rip.percent))%" }
    $ni.Icon = if ($paused) { $Icons.paused } elseif ($parts.Count) { $Icons.busy } else { $Icons.idle }
    $head = "Helper $($s.version)$(if ($paused) { ' (paused)' })"
    $ni.Text = Short ((@($head) + $parts) -join ' | ') 63      # Windows allows 63 characters here
    $miStatus.Text = if ($lines.Count) { $lines -join "`n" } elseif ($paused) { 'Compressions paused' } else { 'Idle: nothing running' }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ try { Update-Tray } catch { } })
$timer.Start()
Update-Tray
[Windows.Forms.Application]::Run()
$ni.Visible = $false; $ni.Dispose(); $mutex.ReleaseMutex()
