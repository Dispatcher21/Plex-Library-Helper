<#
  Plex Library Helper - pause rules, shared by compressions (compress.ps1) and the qBittorrent watcher
  (torrent.ps1): Plex transcoding / playing, a full-screen game, "only when idle", "only overnight".
  Uses $script:PlexUrl / $script:PlexToken (Plex sessions) and $script:NightWindow from whoever loads it.
#>
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class PldWin {
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool GetDiskFreeSpaceEx(string dir, out long freeToCaller, out long total, out long totalFree);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  public static double IdleSeconds() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i); if (!GetLastInputInfo(ref i)) return 0; return ((uint)Environment.TickCount - i.dwTime) / 1000.0; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO i);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  // A window covering its whole monitor, that isn't the desktop or taskbar
  public static bool FullScreenAppInFront() {
    IntPtr h = GetForegroundWindow(); if (h == IntPtr.Zero) return false;
    var c = new StringBuilder(256); GetClassName(h, c, 256); string cls = c.ToString();
    if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Windows.UI.Core.CoreWindow") return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
    if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
    return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
  }
}
'@

function In-Window([string]$window, [datetime]$now) {
    if ($window -notmatch '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') { $window = '23:00-07:00'; $null = $window -match '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$' }
    $start = [int]$Matches[1] * 60 + [int]$Matches[2]; $end = [int]$Matches[3] * 60 + [int]$Matches[4]
    $m = $now.Hour * 60 + $now.Minute
    if ($start -le $end) { $m -ge $start -and $m -lt $end } else { $m -ge $start -or $m -lt $end }
}

# What Plex is doing: 'transcoding' (a stream being converted, which competes with encoding for the PC),
# 'watching' (something playing directly, or a paused transcode), or '' (nothing playing). Paused
# direct-play sessions don't count: a paused tablet could otherwise hold an encode all night.
function Plex-Activity {
    try {
        if ($script:PlexUrl) {
            $r = Invoke-WebRequest -Uri "$($script:PlexUrl)/status/sessions" -Headers @{ 'X-Plex-Token' = $script:PlexToken; Accept = 'application/xml' } -TimeoutSec 5 -UseBasicParsing
            $x = [xml]$r.Content
            $playing = @(@($x.MediaContainer.Video) + @($x.MediaContainer.Track) | Where-Object { $_ -and $_.Player.state -ne 'paused' })
            if (@($playing | Where-Object { $_.TranscodeSession -and $_.TranscodeSession.videoDecision -eq 'transcode' }).Count) { return 'transcoding' }
            if ($playing.Count) { return 'watching' }
            return ''
        }
    } catch { }
    if (Get-Process 'Plex Transcoder' -ErrorAction SilentlyContinue) { 'transcoding' } else { '' }
}

# Why work should hold right now, or '' to go ahead. $holdFile: the 'pause all' switch for this kind of work
# (compressions: jobs\PAUSED; torrents: jobs\TORRENTS-HOLD)
function Pause-Reason($rules, [string]$holdFile = $script:PauseFile) {
    if ($holdFile -and (Test-Path -LiteralPath $holdFile)) { return 'paused from the tray or dashboard' }
    if ($rules.night -and -not (In-Window $script:NightWindow (Get-Date))) { return "waiting for the overnight window ($($script:NightWindow))" }
    if ($rules.idle -and [PldWin]::IdleSeconds() -lt $(if ($IdleMinutes) { $IdleMinutes } else { 10 }) * 60) { return 'the PC is in use' }
    if ($rules.game -and [PldWin]::FullScreenAppInFront()) { return 'a full-screen game or video is running' }
    if ($rules.plex -or $rules.plexall) {
        $a = Plex-Activity
        if ($a -eq 'transcoding') { return 'Plex is transcoding a stream' }
        if ($a -eq 'watching' -and $rules.plexall) { return 'someone is watching Plex' }
    }
    ''
}

