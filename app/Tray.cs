using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace PlexLibraryHelper
{
    // The notification-area icon: colour shows the state (amber idle, teal working, grey paused, red not
    // running), hover shows what it's doing, double-click opens the window. It also restarts the helper if it
    // has stopped without you choosing Quit (the watchdog from tray.ps1).
    public sealed class Tray : IDisposable
    {
        readonly Forms.NotifyIcon _icon;
        readonly Icon _idle = Draw("#E5A00D"), _busy = Draw("#5FD4B0"), _paused = Draw("#9AA0A6"), _off = Draw("#FF8A80");
        readonly Forms.ToolStripMenuItem _status, _pause, _bench, _restart;
        readonly DispatcherTimer _timer;
        DateTime? _downSince, _lastAutoStart;
        Dictionary<string, JobView> _lastJobs = new Dictionary<string, JobView>();
        bool _restarting;

        public Tray()
        {
            var menu = new Forms.ContextMenuStrip { ShowImageMargin = false, Renderer = new DarkRenderer() };
            _status = new Forms.ToolStripMenuItem("Starting…") { Enabled = false };
            var open = new Forms.ToolStripMenuItem("Open Plex Library Helper", null, (s, e) => App.ShowMain()) { Font = new Font(Forms.Control.DefaultFont, FontStyle.Bold) };
            _pause = new Forms.ToolStripMenuItem("Pause all compressions", null, (s, e) => { Live.SetPaused(!Live.Paused); Update(); });
            _bench = new Forms.ToolStripMenuItem("Run benchmark", null, (s, e) => ToggleBenchmark());
            _restart = new Forms.ToolStripMenuItem("Restart helper", null, (s, e) => Restart("Helper restarted"));
            menu.Items.AddRange(new Forms.ToolStripItem[]
            {
                _status, new Forms.ToolStripSeparator(), open,
                new Forms.ToolStripMenuItem("Open dashboard", null, (s, e) => App.Open(Engine.Dashboard)),
                _pause, _bench, new Forms.ToolStripSeparator(),
                new Forms.ToolStripMenuItem("Empty _TO_DELETE…", null, (s, e) => App.ShowMain("trash")),
                new Forms.ToolStripMenuItem("Settings", null, (s, e) => App.ShowMain("settings")),
                new Forms.ToolStripMenuItem("Open log folder", null, (s, e) => App.Open(Engine.LogDir)),
                new Forms.ToolStripSeparator(), _restart,
                new Forms.ToolStripMenuItem("Quit", null, (s, e) => QuitAll()),
            });
            _icon = new Forms.NotifyIcon { Icon = _idle, Text = "Plex Library Helper", Visible = true, ContextMenuStrip = menu };
            _icon.DoubleClick += (s, e) => App.ShowMain();
            _icon.BalloonTipClicked += (s, e) => App.ShowMain();
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            _timer.Tick += (s, e) => { try { Update(); } catch { } };
            _timer.Start();
            Update();
        }

        void ToggleBenchmark()
        {
            if (Live.Jobs().Any(j => j.Mode == "benchmark") || Live.BenchmarkWaiting) { Live.StopBenchmark(); Update(); return; }
            Live.RequestBenchmark();
            _icon.ShowBalloonTip(5000, "Plex Library Helper", "Benchmark asked for: it starts once no compression is running (about 20-60 min; pauses for Plex and games).", Forms.ToolTipIcon.Info);
            Update();
        }

        void Update()
        {
            var s = Live.State();
            var paused = Live.Paused;
            var jobs = Live.Jobs();
            var benching = jobs.Any(j => j.Mode == "benchmark");
            _pause.Text = paused ? "Resume compressions" : "Pause all compressions";
            var cfg = s != null && s.B("compress");
            _pause.Visible = _bench.Visible = cfg;
            _bench.Text = benching ? "Stop benchmark" : Live.BenchmarkWaiting ? "Cancel benchmark (waiting)" : "Run benchmark";

            // "done" balloons: a job that was running a moment ago and isn't any more
            foreach (var gone in _lastJobs.Values.Where(j => jobs.All(x => x.Id != j.Id)))
                if (gone.Mode != "benchmark") _icon.ShowBalloonTip(6000, gone.Mode == "estimate" ? "Estimate finished" : "Compression finished", gone.Heading + " · " + gone.PresetLabel + ". Open the dashboard for the result.", Forms.ToolTipIcon.Info);
                else _icon.ShowBalloonTip(6000, "Benchmark finished", "The measurements are in: see Encoders in Plex Library Helper.", Forms.ToolTipIcon.Info);
            _lastJobs = jobs.ToDictionary(j => j.Id ?? Guid.NewGuid().ToString());

            if (!Live.HelperAlive(s))
            {
                if (Live.Starting()) { _icon.Icon = _idle; _icon.Text = "Plex Library Helper: starting"; _status.Text = "Starting…"; _downSince = null; return; }
                _icon.Icon = _off; _icon.Text = "Plex Library Helper: not running"; _status.Text = "Not running"; _restart.Text = "Start helper";
                // Watchdog: a helper down for 2 minutes is started again, at most every 10 minutes. It also
                // restarts at once after an update left it stopped (VERSION.txt newer than what it runs).
                if (!Engine.Configured || Installer.TestMode || !Live.TaskExists()) return;
                if (_downSince == null) _downSince = DateTime.Now;
                var quiet = _lastAutoStart == null || (DateTime.Now - _lastAutoStart.Value).TotalMinutes >= 10;
                var updated = s != null && s.S("version") != Installer.VersionText;
                if (((DateTime.Now - _downSince.Value).TotalMinutes >= 2 || updated) && quiet) { _lastAutoStart = DateTime.Now; Restart("The helper had stopped"); }
                return;
            }
            _downSince = null; _restart.Text = "Restart helper"; Live.Reported();
            var parts = new List<string>(); var lines = new List<string>();
            foreach (var j in jobs)
            {
                var left = j.SecsLeft.HasValue ? ", " + Live.Duration(j.SecsLeft.Value) + " left" : "";
                parts.Add($"{Short(j.Mode == "benchmark" ? "Benchmark" : j.Title ?? "", 14)} {Math.Round(j.Percent)}%");
                lines.Add($"{j.Kind} {(j.Mode == "benchmark" ? "" : j.Title + " ")}{Math.Round(j.Percent)}%{left}{(string.IsNullOrEmpty(j.Paused) ? "" : " (paused)")}");
            }
            var rip = s.O("rip");
            if (rip != null) { parts.Add($"Rip {Math.Round(rip.Has("totalPercent") ? rip.D("totalPercent") : rip.D("percent"))}%"); lines.Add($"Ripping {rip.S("folder")}: {Math.Round(rip.D("percent"))}%"); }
            _icon.Icon = paused ? _paused : parts.Count > 0 ? _busy : _idle;
            var head = $"Helper {s.S("version")}{(paused ? " (paused)" : "")}";
            _icon.Text = Short(string.Join(" | ", new[] { head }.Concat(parts)), 63);   // Windows allows 63 characters
            _status.Text = lines.Count > 0 ? string.Join("\n", lines) : paused ? "Compressions paused" : "Idle: nothing running";
        }

        async void Restart(string why)
        {
            if (_restarting) return;
            _restarting = true;
            var ok = await Task.Run(() => Live.RestartHelper());
            _restarting = false;
            _downSince = null;
            _icon.ShowBalloonTip(ok ? 3000 : 6000, "Plex Library Helper", ok ? why + " - running again." : why + ", but it didn't come back. Open Plex Library Helper > Settings.", ok ? Forms.ToolTipIcon.Info : Forms.ToolTipIcon.Warning);
            Update();
        }

        void QuitAll()
        {
            var busy = Live.Jobs().Any();
            var msg = busy
                ? "An encode is running. It keeps going, but nothing reports on it until the helper starts again (next sign-in).\n\nQuit Plex Library Helper?"
                : "Quit Plex Library Helper? It starts again the next time you sign in to Windows.";
            if (System.Windows.MessageBox.Show(msg, "Plex Library Helper", System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question) != System.Windows.MessageBoxResult.Yes) return;
            Live.StopHelper();
            App.Quit();
        }

        static string Short(string s, int n) => s.Length <= n ? s : s.Substring(0, n - 1) + "…";

        static Icon Draw(string hex)
        {
            var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                var p = new GraphicsPath(); int r = 8;
                p.AddArc(0, 0, r * 2, r * 2, 180, 90); p.AddArc(31 - r * 2, 0, r * 2, r * 2, 270, 90);
                p.AddArc(31 - r * 2, 31 - r * 2, r * 2, r * 2, 0, 90); p.AddArc(0, 31 - r * 2, r * 2, r * 2, 90, 90); p.CloseFigure();
                g.FillPath(new SolidBrush(ColorTranslator.FromHtml(hex)), p);
                g.FillPolygon(new SolidBrush(ColorTranslator.FromHtml("#1A1203")), new[] { new Point(9, 7), new Point(16, 7), new Point(23, 16), new Point(16, 25), new Point(9, 25), new Point(16, 16) });
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        public void Dispose() { _timer.Stop(); _icon.Visible = false; _icon.Dispose(); }

        // Dark menu to match the windows
        sealed class DarkRenderer : Forms.ToolStripProfessionalRenderer
        {
            public DarkRenderer() : base(new DarkColors()) { }
            protected override void OnRenderItemText(Forms.ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Enabled ? Color.FromArgb(232, 234, 237) : Color.FromArgb(163, 169, 179); base.OnRenderItemText(e); }
        }
        sealed class DarkColors : Forms.ProfessionalColorTable
        {
            static readonly Color Bg = Color.FromArgb(29, 34, 42), Hover = Color.FromArgb(37, 43, 53), Line = Color.FromArgb(58, 65, 77);
            public override Color ToolStripDropDownBackground => Bg;
            public override Color MenuBorder => Line;
            public override Color MenuItemBorder => Hover;
            public override Color MenuItemSelected => Hover;
            public override Color MenuItemSelectedGradientBegin => Hover;
            public override Color MenuItemSelectedGradientEnd => Hover;
            public override Color SeparatorDark => Line;
            public override Color SeparatorLight => Bg;
            public override Color ImageMarginGradientBegin => Bg;
            public override Color ImageMarginGradientMiddle => Bg;
            public override Color ImageMarginGradientEnd => Bg;
        }
    }
}
