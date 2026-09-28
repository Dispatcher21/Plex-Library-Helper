using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace PlexLibraryHelper
{
    // The app's main window: what's running (with live progress bars), the encoders and their benchmark
    // results, _TO_DELETE, and settings.
    public partial class MainWindow : Window
    {
        readonly DispatcherTimer _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        string _page = "overview";

        public MainWindow()
        {
            InitializeComponent();
            App.DarkTitleBar(this);
            SideSub.Text = "Version " + Installer.VersionText;
            DashBtn.Click += (s, e) => App.Open(Engine.Dashboard);
            NavOverview.Checked += (s, e) => Go("overview");
            NavEncoders.Checked += (s, e) => Go("encoders");
            NavTrash.Checked += (s, e) => Go("trash");
            NavSettings.Checked += (s, e) => Go("settings");
            _timer.Tick += (s, e) => Tick();
            Loaded += (s, e) => { if (Page.Content == null) Go(_page); _timer.Start(); };
            Closed += (s, e) => _timer.Stop();
        }

        public void Go(string page)
        {
            _page = page;
            var nav = page == "encoders" ? NavEncoders : page == "trash" ? NavTrash : page == "settings" ? NavSettings : NavOverview;
            if (nav.IsChecked != true) { nav.IsChecked = true; return; }   // its Checked handler comes back here
            _cards.Clear(); _overview = null; _encoders = null; _heroSig = null;
            switch (page)
            {
                case "overview": Overview(); break;
                case "encoders": Encoders(); break;
                case "trash": Trash(); break;
                case "settings": Settings(); break;
            }
            Scroll.ScrollToTop();
            Tick();
        }

        void Tick()
        {
            try
            {
                var s = Live.State();
                var alive = Live.HelperAlive(s);
                SideFoot.Text = alive ? $"Helper running on {Environment.MachineName}" : "Helper not running";
                if (_page == "overview") UpdateOverview(s, alive);
                else if (_page == "encoders") UpdateEncoders();
            }
            catch { }
        }

        static StackPanel Header(string title, string text, UIElement right = null)
        {
            var h = Ui.T(title, "H1");
            return Ui.V(right == null ? (UIElement)h : Ui.Split(h, right), string.IsNullOrEmpty(text) ? null : Ui.T(text).M(0, 6, 0, 0), new Border { Height = 20 });
        }

        // ================================================================ overview

        StackPanel _overview, _jobsPanel; ContentControl _hero, _rip, _empty, _downloads; string _heroSig;
        readonly Dictionary<string, JobCard> _cards = new Dictionary<string, JobCard>();

        void Overview()
        {
            _hero = new ContentControl(); _rip = new ContentControl(); _jobsPanel = Ui.V(); _empty = new ContentControl(); _downloads = new ContentControl(); _torSig = null;
            var banner = new ContentControl();
            void Banner() => banner.Content = Updater.Available == null || Updater.Auto ? null
                : new Border { Style = Ui.St("Card"), BorderBrush = Ui.Br("Accent"), Child = Ui.Split(Ui.V(Ui.T($"Update available: version {Updater.Available.Major}.{Updater.Available.Minor}.{Updater.Available.Build}", "H2"), Ui.T($"You have {Installer.VersionText}. Settings > Updates can install them automatically instead.", "Fine").M(0, 4, 0, 0)),
                    Ui.Btn("Install", async () => { var err = await Updater.Install(); if (err != null) Dialog.Info(this, "Update", err); }, "Primary")) };
            Action changed = () => Dispatcher.BeginInvoke(new Action(Banner));
            Updater.Changed += changed; Closed += (s, e) => Updater.Changed -= changed;
            Banner();
            _overview = Ui.V(Header("Overview", null), banner, _hero, Ui.T("NOW", "Label").M(0, 10, 0, 10), _jobsPanel, _rip, _downloads, _empty);
            Page.Content = _overview;
        }

        void UpdateOverview(Dictionary<string, object> s, bool alive)
        {
            if (_overview == null) return;
            var cfg = Engine.ReadConfig();
            var paused = Live.Paused;
            var compress = cfg?.O("compress")?.B("enabled") ?? false;
            // hero: state, where, and the main actions (rebuilt only when something in it changes)
            var starting = !alive && Live.Starting();
            var heroSig = $"{alive}|{starting}|{paused}|{compress}|{cfg?.S("serverName")}|{s?.S("version")}";
            if (heroSig != _heroSig) { _heroSig = heroSig; Hero(s, alive, starting, paused, compress, cfg); }
            UpdateJobs(s, paused, compress);
            UpdateTorrents(s);
        }

        // ---- qBittorrent: header (state, speeds, button) redrawn only when it changes; the bars every tick
        string _torSig; bool _torFetching; StackPanel _torRows; TextBlock _torSpeeds;
        async void UpdateTorrents(Dictionary<string, object> s)
        {
            var port = Live.TorrentPort();
            if (port == null) { _downloads.Content = null; _torSig = null; return; }
            if (_torFetching) return;
            _torFetching = true;
            var list = await Live.Torrents(port.Value);
            _torFetching = false;
            if (_overview == null) return;
            var ts = s?.O("torrents");
            var held = Live.TorrentsHeld;
            var slowed = ts != null && ts.B("slowed");
            var why = held ? "Slowed down from the app, tray or dashboard" : slowed && ts.B("byHelper") ? "Slowed down: " + ts.S("why") : slowed ? "qBittorrent's speed limit is on" : null;
            var sig = $"{list != null}|{held}|{why}";
            if (sig != _torSig)
            {
                _torSig = sig;
                if (list == null) { _downloads.Content = Ui.Card(Ui.T("qBittorrent", "H2"), Ui.T("Not running (or its Web UI isn't set up: Settings > qBittorrent).", "Fine").M(0, 4, 0, 0)); return; }
                _torRows = Ui.V(); _torSpeeds = Ui.T("", "Fine");
                var btn = Ui.Btn(held ? "Back to normal" : "Slow down now", () => { Live.SetTorrentsHeld(!held); _torSig = null; }, "Small");
                _downloads.Content = new Border { Style = Ui.St("Card"), Child = Ui.V(
                    Ui.Split(Ui.V(Ui.T("qBittorrent", "H2"), _torSpeeds.M(0, 2, 0, 0)), btn),
                    why == null ? null : Ui.Status("warn", why).M(0, 10, 0, 0), _torRows) };
            }
            if (list == null) return;
            double dl = list.Sum(t => t.D("dlspeed")), up = list.Sum(t => t.D("upspeed"));
            var active = new[] { "Downloading", "Stalled", "Getting details", "Queued", "Checking" };
            int downloading = list.Count(t => t.D("progress") < 1 && active.Contains(Live.TorrentState(t.S("state"))));
            int seeding = list.Count(t => Live.TorrentState(t.S("state")) == "Seeding");
            _torSpeeds.Text = $"↓ {Live.Rate(dl)} · ↑ {Live.Rate(up)} · {downloading} downloading, {seeding} seeding";
            _torRows.Children.Clear();
            var rows = list.Where(t => t.D("progress") < 1).OrderBy(t => Live.TorrentState(t.S("state")) == "Paused" ? 1 : 0).ThenByDescending(t => t.D("added_on")).Take(6).ToList();
            if (rows.Count == 0) _torRows.Children.Add(Ui.T("Nothing downloading.", "Fine").M(0, 10, 0, 0));
            foreach (var t in rows)
            {
                var pct = t.D("progress") * 100; var eta = t.D("eta");
                var bar = Ui.Bar(pct); bar.Foreground = Live.TorrentState(t.S("state")) == "Paused" ? Ui.Br("Fg3") : Ui.Br("Link");
                _torRows.Children.Add(Ui.V(Ui.Split(Ui.T(t.S("name"), "Body", fg: Ui.Br("Fg")), Ui.T($"{pct:0.#}%", "Fine").M(12, 0, 0, 0)), bar,
                    Ui.T($"{Live.TorrentState(t.S("state"))} · {Live.Size(t.D("size"))}{(t.D("dlspeed") > 0 ? " · " + Live.Rate(t.D("dlspeed")) : "")}{(eta > 0 && eta < 8640000 ? " · about " + Live.Duration(eta) + " left" : "")}", "Fine")).M(0, 12, 0, 0));
            }
        }

        void Hero(Dictionary<string, object> s, bool alive, bool starting, bool paused, bool compress, Dictionary<string, object> cfg)
        {
            var state = starting ? Ui.Status("busy", "Starting…") : !alive ? Ui.Status("bad", "Not running") : paused ? Ui.Status("off", "Paused: no compression runs until you resume") : Ui.Status("ok", "Running");
            ((TextBlock)state.Children[1]).FontSize = 17; ((TextBlock)state.Children[1]).FontWeight = FontWeights.SemiBold;
            var sub = Ui.T($"{Environment.MachineName} · Plex server {cfg?.S("serverName") ?? "?"} · helper {s?.S("version") ?? Installer.VersionText}{(compress ? " · compresses" : " · quarantines only")}", "Fine").M(17, 4, 0, 0);
            var buttons = Ui.H();
            if (!alive && !starting) buttons.Children.Add(Ui.Btn("Start helper", async () => { SideFoot.Text = "Starting…"; await Task.Run(() => Live.RestartHelper()); Tick(); }, "Primary"));
            else if (compress) buttons.Children.Add(Ui.Btn(paused ? "Resume compressions" : "Pause all compressions", () => { Live.SetPaused(!paused); Tick(); }, paused ? "Primary" : null));
            _hero.Content = new Border { Style = Ui.St("Card"), Child = Ui.Split(Ui.V(state, sub), buttons) };
        }

        void UpdateJobs(Dictionary<string, object> s, bool paused, bool compress)
        {

            // running jobs: keep each card and just move its bar, so nothing flickers
            var jobs = Live.Jobs();
            foreach (var id in _cards.Keys.Where(k => jobs.All(j => j.Id != k)).ToList()) { _jobsPanel.Children.Remove(_cards[id].Root); _cards.Remove(id); }
            foreach (var j in jobs)
            {
                if (!_cards.TryGetValue(j.Id, out var card)) { card = new JobCard(); _cards[j.Id] = card; _jobsPanel.Children.Add(card.Root); }
                card.Update(j, paused);
            }

            // MakeMKV rip
            var rip = s?.O("rip");
            if (rip != null)
            {
                var pct = rip.Has("totalPercent") ? rip.D("totalPercent") : rip.D("percent");
                var left = rip.D("secsLeft") > 0 ? " · about " + Live.Duration(rip.D("secsLeft")) + " left" : "";
                var rate = rip.D("rate") > 0 ? $" · {rip.D("rate") / 1048576:0} MB/s" : "";
                var bar = Ui.Bar(pct); bar.Foreground = Ui.Br("Accent");
                _rip.Content = Ui.Card(Ui.Split(Ui.T($"Ripping {rip.S("disc")}", "H2"), Ui.T($"{pct:0}%", "H2")),
                    Ui.T($"MakeMKV · into {rip.S("folder")}{rate}{left}", "Fine").M(0, 2, 0, 0), bar,
                    Ui.T(rip.S("file") ?? "", "Fine"));
            }
            else _rip.Content = null;

            _empty.Content = jobs.Count == 0 && rip == null
                ? Ui.Card(Ui.T("Nothing running", "H2"), Ui.T(compress ? "Queue a compression or an estimate from the dashboard (open a movie or a season, then Compress…). Its progress shows up here." : "This PC does quarantines; compressions run on your other PCs.").M(0, 6, 0, 12),
                    Ui.H(Ui.Btn("Open dashboard", () => App.Open(Engine.Dashboard), "Small")))
                : null;
        }

        // One running job: title, what it's doing, a progress bar, time left
        sealed class JobCard
        {
            public readonly Border Root;
            readonly TextBlock _title = Ui.T("", "H2"), _pct = Ui.T("", "H2"), _sub = Ui.T("", "Fine"), _phase = Ui.T("", "Fine"), _left = Ui.T("", "Fine");
            readonly ProgressBar _bar = Ui.Bar();
            readonly ContentControl _action = new ContentControl();
            string _mode;
            public JobCard()
            {
                _pct.HorizontalAlignment = HorizontalAlignment.Right;
                _left.HorizontalAlignment = HorizontalAlignment.Right; _left.Foreground = Ui.Br("Fg2");
                _bar.Height = 10;
                Root = new Border { Style = Ui.St("Card"), Child = Ui.V(Ui.Split(_title, _pct), _sub.M(0, 2, 0, 0), _bar, Ui.Split(_phase, _left), _action) };
            }
            public void Update(JobView j, bool allPaused)
            {
                _title.Text = j.Heading;
                _pct.Text = $"{Math.Floor(j.Percent)}%";
                var enc = Presets.EncoderLabel(j.Encoder);
                _sub.Text = j.Mode == "benchmark" ? "Measuring quality, size and speed of each encoder on your films" : $"{j.Kind} · {j.PresetLabel}{(enc != null ? " · " + enc : "")}";
                _bar.Value = j.Percent;
                var paused = !string.IsNullOrEmpty(j.Paused);
                _bar.Foreground = paused ? Ui.Br("Fg3") : j.Mode == "benchmark" ? Ui.Br("Accent") : Ui.Br("Teal");
                _phase.Text = paused ? "Paused: " + j.Paused : j.Phase;
                _phase.Foreground = paused ? Ui.Br("Warn") : Ui.Br("Fg3");
                _left.Text = j.SecsLeft.HasValue && !paused ? "about " + Live.Duration(j.SecsLeft.Value) + " left" : "";
                if (_mode != j.Mode)
                {
                    _mode = j.Mode;
                    _action.Content = j.Mode == "benchmark"
                        ? Ui.H(Ui.Btn("Stop benchmark", () => Live.StopBenchmark(), "Small")).M(0, 10, 0, 0)
                        : Ui.T("Stop or change it in the dashboard (Jobs).", "Fine").M(0, 6, 0, 0);
                }
            }
        }

        // ================================================================ encoders and benchmark

        StackPanel _encoders; ContentControl _benchState, _encTables; string _calSig;

        void Encoders()
        {
            _benchState = new ContentControl(); _encTables = new ContentControl(); _calSig = null;
            _encoders = Ui.V(Header("Encoders & benchmark", "Each PC measures its own encoders on two of your films (a 4K and a 1080p one): quality (VMAF, where 95 looks the same as the original on a TV), size and speed. From that it picks the setting for each quality level on this PC, and the dashboard shows real size and time estimates per PC."),
                _benchState, _encTables);
            Page.Content = _encoders;
        }

        void UpdateEncoders()
        {
            if (_encoders == null) return;
            var cfg = Engine.ReadConfig();
            var c = cfg?.O("compress");
            if (c == null || !c.B("enabled"))
            {
                _benchState.Content = Ui.Card(Ui.T("Compression is off on this PC", "H2"), Ui.T("Turn it on in Settings to use this PC's encoders.").M(0, 6, 0, 12), Ui.H(Ui.Btn("Settings", () => App.ShowSetup(2), "Small")));
                _encTables.Content = null; return;
            }
            var bench = Live.Jobs().FirstOrDefault(j => j.Mode == "benchmark");
            if (bench != null)
            {
                var bar = Ui.Bar(bench.Percent); bar.Foreground = Ui.Br("Accent"); bar.Height = 10;
                var paused = !string.IsNullOrEmpty(bench.Paused);
                _benchState.Content = Ui.Card(Ui.Split(Ui.T("Benchmark running", "H2"), Ui.T($"{Math.Floor(bench.Percent)}%", "H2")), bar,
                    Ui.T(paused ? "Paused: " + bench.Paused : bench.Phase, "Fine", fg: paused ? Ui.Br("Warn") : null),
                    Ui.H(Ui.Btn("Stop benchmark", () => { Live.StopBenchmark(); Tick(); }, "Small")).M(0, 12, 0, 0));
            }
            else if (Live.BenchmarkWaiting)
                _benchState.Content = Ui.Card(Ui.Status("busy", "Benchmark waiting: it starts as soon as no compression is running"), Ui.H(Ui.Btn("Cancel", () => { Live.StopBenchmark(); Tick(); }, "Small")).M(0, 12, 0, 0));
            else
            {
                var measured = (c.O("calibration")?.Count ?? 0) > 0;
                _benchState.Content = Ui.Card(Ui.Split(Ui.V(Ui.T(measured ? "Measured" : "Not measured yet", "H2"),
                        Ui.T(measured ? "Run it again after changing graphics card or drivers, or to measure new encoders." : "It runs by itself the first time the PC is idle, or start it now. About 20-60 minutes; it waits for running compressions, and pauses for Plex streams and games.", "Fine").M(0, 4, 16, 0)),
                    Ui.Btn(measured ? "Measure again" : "Run benchmark", () => { Live.RequestBenchmark(); Tick(); }, "Primary")));
            }

            // tables: only redrawn when the measurements change
            var cal = c.O("calibration");
            var sig = Json.Write(cal ?? new Dictionary<string, object>()) + string.Join(",", c.AS("encoders")) + c.B("allowCpu");
            if (sig == _calSig) return;
            _calSig = sig;
            var v = Ui.V();
            if (c.AS("encoders").Count == 0)
            {
                _encTables.Content = Ui.Card(Ui.T("Encoders not tested yet", "H2"), Ui.T("Setup tests which encoders work on this PC (a few seconds).").M(0, 6, 0, 12), Ui.H(Ui.Btn("Test encoders", () => App.ShowSetup(2), "Small")));
                return;
            }
            foreach (var tier in new[] { "4k", "1080" })
            {
                var rows = c.AS("encoders").Where(id => AllowCpu(c) || !Presets.IsCpu(id)).ToList();
                v.Children.Add(Ui.T(tier == "4k" ? "4K FILMS" : "1080P FILMS", "Label").M(0, 10, 0, 10));
                v.Children.Add(new Border { Style = Ui.St("Card"), Padding = new Thickness(18, 12, 18, 12), Child = TierTable(tier, rows, cal) });
            }
            var src = cal?.Values.OfType<Dictionary<string, object>>().SelectMany(e => e.Values.OfType<Dictionary<string, object>>()).FirstOrDefault(x => x.S("source") != null);
            if (src != null && DateTime.TryParse(src.S("time"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var when))
                v.Children.Add(Ui.T($"Last measured {when.ToLocalTime():d MMM yyyy, HH:mm}. Settings: lower = better quality and bigger files. Size is the video's share of the film it was measured on; grainy films come out bigger.", "Fine").M(0, 4, 0, 0));
            _encTables.Content = v;
        }

        static Grid TierTable(string tier, List<string> ids, Dictionary<string, object> cal)
        {
            var g = new Grid();
            var widths = new[] { 2.4, 1.0, 1.0, 1.0, 1.0, 1.0 };
            foreach (var w in widths) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w, GridUnitType.Star) });
            var head = new[] { "Encoder", "Speed", "Extreme", "High", "Normal", "Data Saver" };
            void Cell(int row, int col, UIElement e) { Grid.SetRow(e, row); Grid.SetColumn(e, col); g.Children.Add(e); }
            g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (int i = 0; i < head.Length; i++) Cell(0, i, Ui.T(head[i], "Fine").M(0, 0, 8, 8));
            var levels = new[] { "extreme", "high", "normal", "saver" };
            int r = 1;
            foreach (var id in ids)
            {
                g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var m = cal?.O(id)?.O(tier);
                Cell(r, 0, Ui.T(Presets.EncoderLabel(id) ?? id, fg: Ui.Br("Fg")).M(0, 6, 8, 6));
                if (m == null) { var t = Ui.T("not measured yet", "Fine").M(0, 8, 0, 6); Grid.SetColumnSpan(t, 5); Cell(r, 1, t); }
                else if (!string.IsNullOrEmpty(m.S("skipped"))) { Cell(r, 1, Ui.T($"{Fps(m.D("fps"))} fps", fg: Ui.Br("Fg2")).M(0, 6, 8, 6)); var t = Ui.T("too slow here for these films: not used", "Fine").M(0, 8, 0, 6); Grid.SetColumnSpan(t, 4); Cell(r, 2, t); }
                else
                {
                    Cell(r, 1, Ui.T($"{Fps(m.D("fps"))} fps", fg: Ui.Br("Fg")).M(0, 6, 8, 6));
                    var src = m.D("srcKbps");
                    for (int i = 0; i < 4; i++)
                    {
                        var q = m.O("levels")?.D(levels[i], double.NaN) ?? double.NaN;
                        var kb = m.O("kbps")?.D(levels[i]) ?? 0;
                        Cell(r, 2 + i, Ui.V(Ui.T(double.IsNaN(q) ? "–" : $"setting {q:0.#}", fg: Ui.Br("Fg")), src > 0 && kb > 0 ? Ui.T($"{kb / src * 100:0}% size", "Fine") : null).M(0, 6, 8, 6));
                    }
                }
                r++;
            }
            return g;
        }
        // missing (set up before 0.3.9) counts as yes, as in the helper
        static bool AllowCpu(Dictionary<string, object> c) => !c.Has("allowCpu") || c.B("allowCpu");
        static string Fps(double f) => f >= 10 ? f.ToString("0") : f.ToString("0.0");

        // ================================================================ _TO_DELETE

        void Trash()
        {
            var page = Header("_TO_DELETE", "Quarantined files wait here, on their own drive, so you can put them back (each move is in _TO_DELETE\\manifest.jsonl). Emptying deletes them for good. This lists this PC's drives only; the dashboard shows every PC.");
            var list = new ContentControl { Content = Ui.V(Ui.T("Looking…", "Fine"), Ui.Bar(0, true)) };
            page.Children.Add(list);
            Page.Content = page;
            Dispatcher.BeginInvoke(new Action(async () => await LoadTrash(list)));
        }

        async Task LoadTrash(ContentControl list)
        {
            var r = await Engine.Call("trash");
            if (_page != "trash") return;
            if (!r.Ok) { list.Content = Ui.Card(Ui.Status("bad", r.Error)); return; }
            var batches = r.Data.AO("batches");
            if (batches.Count == 0) { list.Content = Ui.Card(Ui.Status("ok", "Empty: nothing waiting in _TO_DELETE on this PC's drives.")); return; }
            var chosen = new HashSet<string>(batches.Where(b => !b.B("links")).Select(b => b.S("path")));
            var total = Ui.T("", "Body");
            var go = Ui.Btn("Empty…", () => { }, "Danger");
            void Sum()
            {
                var bytes = batches.Where(b => chosen.Contains(b.S("path"))).Sum(b => b.D("bytes"));
                total.Text = $"{chosen.Count} of {batches.Count} batch{(batches.Count == 1 ? "" : "es")} chosen · {Live.Size(bytes)}";
                go.IsEnabled = chosen.Count > 0;
            }
            var v = Ui.V();
            foreach (var b in batches)
            {
                var path = b.S("path");
                var titles = b.AS("titles");
                var cb = new CheckBox { IsChecked = chosen.Contains(path), IsEnabled = !b.B("links"), Margin = new Thickness(0, 0, 0, 14) };
                cb.Content = Ui.V(Ui.T($"{b.S("drive")} {b.S("date")} · {Live.Size(b.D("bytes"))} · {b.D("files"):0} file{(b.D("files") == 1 ? "" : "s")}", fg: Ui.Br("Fg")),
                    titles.Count > 0 ? Ui.T(string.Join(", ", titles.Take(8)) + (titles.Count > 8 ? $" and {titles.Count - 8} more" : ""), "Fine") : null,
                    b.B("links") ? Ui.T("Contains a link to another folder: check and delete it by hand.", "Fine", fg: Ui.Br("Warn")) : null);
                cb.Checked += (s, e) => { chosen.Add(path); Sum(); };
                cb.Unchecked += (s, e) => { chosen.Remove(path); Sum(); };
                v.Children.Add(cb);
            }
            go.Click += async (s, e) =>
            {
                var bytes = batches.Where(b => chosen.Contains(b.S("path"))).Sum(b => b.D("bytes"));
                if (!Dialog.Confirm(this, "Empty _TO_DELETE?", Ui.T($"This permanently deletes {Live.Size(bytes)} ({chosen.Count} batch{(chosen.Count == 1 ? "" : "es")}). It can't be undone."), $"Delete {Live.Size(bytes)} for good", "Danger", "DELETE")) return;
                list.Content = Ui.V(Ui.T("Deleting…", "Fine"), Ui.Bar(0, true));
                var res = await Engine.Call("emptytrash", new { paths = chosen.ToArray() });
                if (!res.Ok) { Dialog.Info(this, "Couldn't empty it", res.Error); }
                else
                {
                    var errs = res.Data.AS("errors");
                    Dialog.Info(this, "Emptied", $"Freed {Live.Size(res.Data.D("freed"))}." + (errs.Count > 0 ? " Problems: " + string.Join("; ", errs) : ""));
                }
                await LoadTrash(list);
            };
            Sum();
            list.Content = Ui.V(Ui.Card(v), Ui.Split(total, go).M(0, 4, 0, 0));
        }

        // ================================================================ updates (Settings, and a banner on Overview)

        // The choice (ask first / automatic), where things stand, and Check now / Install
        UIElement UpdatesBox()
        {
            var state = new ContentControl();
            var box = Ui.V(
                Ui.T("Updates come from the dashboard's site. Each download is checked against the fingerprint published with it before it's installed, and nothing is installed while a compression, estimate or benchmark is running.", "Fine").M(0, 0, 0, 12),
                Ui.Wrap(Ui.Pill("Ask me first", "upd", !Updater.Auto, () => Updater.Auto = false),
                        Ui.Pill("Install automatically when idle", "upd", Updater.Auto, () => Updater.Auto = true)),
                state);
            void Draw()
            {
                UIElement line;
                if (Updater.Busy) line = Ui.V(Ui.T(Updater.Available != null ? "Downloading and installing… the app restarts by itself." : "Checking…", "Fine"), Ui.Bar(0, true));
                else if (Updater.Available != null)
                {
                    var v = $"{Updater.Available.Major}.{Updater.Available.Minor}.{Updater.Available.Build}";
                    var busy = Live.Jobs().Any();
                    line = Ui.Split(Ui.Status("warn", $"Version {v} is available (you have {Installer.VersionText})" + (busy ? ": it installs when the running job finishes" : "")),
                        Ui.Btn("Install now", async () => { var err = await Updater.Install(); if (err != null) Dialog.Info(this, "Update", err); }, "Primary"));
                }
                else if (Updater.Error != null) line = Ui.Split(Ui.Status("bad", Updater.Error), Ui.Btn("Check now", async () => await Updater.Check(), "Small"));
                else line = Ui.Split(Ui.Status("ok", $"Up to date: version {Installer.VersionText}" + (Updater.CheckedAt.HasValue ? $" (checked {Updater.CheckedAt:HH:mm})" : "")),
                    Ui.Btn("Check now", async () => await Updater.Check(), "Small"));
                state.Content = ((FrameworkElement)line).M(0, 6, 0, 0);
            }
            Action changed = () => Dispatcher.BeginInvoke(new Action(Draw));
            Updater.Changed += changed;
            box.Unloaded += (s, e) => Updater.Changed -= changed;
            Draw();
            return box;
        }

        // ================================================================ settings

        void Settings()
        {
            var cfg = Engine.ReadConfig() ?? new Dictionary<string, object>();
            var c = cfg.O("compress"); var n = cfg.O("notify"); var rip = cfg.O("rip");
            var page = Header("Settings", null);
            Border Section(string title, FrameworkElement body, int step) =>
                new Border { Style = Ui.St("Card"), Child = Ui.V(Ui.Split(Ui.T(title, "H2"), step >= 0 ? Ui.Btn("Change…", () => App.ShowSetup(step), "Small") : null), body.M(0, 12, 0, 0)) };
            FrameworkElement Val(string s) => Ui.T(s, fg: Ui.Br("Fg"));

            page.Children.Add(Section("Plex", Ui.Rows(("Server", Val(cfg.S("serverName") ?? "not signed in")), ("Address", Val(cfg.S("serverUrl") ?? "–"))), 1));
            var encs = c?.AS("encoders") ?? new List<string>();
            page.Children.Add(Section("Compression", c != null && c.B("enabled")
                ? (FrameworkElement)Ui.Rows(("On this PC", Val("Yes")),
                    ("Encoders", Val(encs.Count > 0 ? string.Join(", ", encs.Select(e => Presets.EncoderLabel(e) ?? e)) : "not tested yet")),
                    ("Processor-only jobs", Val(AllowCpu(c) ? "Taken" : "Not taken")), ("Work folder", Val(c.S("workDir"))))
                : Ui.Rows(("On this PC", Val("No: quarantines only"))), 2));
            var topic = n?.S("topic");
            var copy = topic == null ? null : Ui.H(Ui.Btn("Copy topic", () => { try { Clipboard.SetText(topic); } catch { } }, "Small"));
            page.Children.Add(Section("Phone & dashboard", Ui.V(Ui.Rows(
                ("Phone notifications", Val(n != null && n.B("enabled") ? "On" + (n.B("pauses") ? ", with pause alerts" : "") : "Off")),
                ("Topic", Val(topic == null ? "none" : topic.Substring(0, Math.Min(8, topic.Length)) + "… (private)"))), copy), 3));
            if (rip != null) page.Children.Add(Section("MakeMKV rips", Ui.Rows(("Rip progress", Val(rip.B("enabled") ? "Shown on the dashboard" : "Off")),
                ("After a rip", Val(rip.B("autoCompress") ? $"Compress: 4K {Presets.Label(rip.S("preset4k"))}, Blu-ray {Presets.Label(rip.S("presetHD"))}" : "Nothing automatic"))), 4));

            var tor = cfg.O("torrent");
            if (tor != null || File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"qBittorrent\qBittorrent.ini")))
            {
                var tr = tor?.O("rules");
                var names = new List<string>();
                if (tr != null) { if (tr.B("plex")) names.Add("Plex transcoding"); if (tr.B("plexall")) names.Add("anything playing on Plex"); if (tr.B("game")) names.Add("full-screen games"); if (tr.B("idle")) names.Add("PC in use"); if (tr.B("night")) names.Add("outside the overnight window"); }
                var on = tor != null && tor.B("enabled");
                page.Children.Add(Section("qBittorrent", Ui.Rows(("Downloads", Val(on ? "Shown here and on the dashboard" : "Not watched")),
                    ("Slows down for", Val(on ? (names.Count > 0 ? string.Join(", ", names) : "nothing (only when you ask)") : "–"))), 5));
            }
            page.Children.Add(Section("Updates", (FrameworkElement)UpdatesBox(), -1));

            var status = Ui.T("", fg: Ui.Br("Fg"));
            var helper = Ui.V(Ui.Rows(("Version", Val(Installer.VersionText)), ("Installed in", Val(Engine.Root)), ("Starts with Windows", status)),
                Ui.Wrap(Ui.Btn("Restart helper", async () => { status.Text = "Restarting…"; var ok = await Task.Run(() => Live.RestartHelper()); status.Text = ok ? "Yes · restarted just now" : "Couldn't restart it"; }, "Small").M(0, 0, 8, 8),
                    Ui.Btn("Open log folder", () => App.Open(Engine.LogDir), "Small").M(0, 0, 8, 8),
                    Ui.Btn("Run the whole setup again", () => App.ShowSetup(0), "Small").M(0, 0, 8, 8)).M(0, 6, 0, 0));
            page.Children.Add(Section("Helper", helper, -1));
            Task.Run(() => Live.TaskExists()).ContinueWith(t => Dispatcher.Invoke(() => status.Text = t.Result ? "Yes" : "No"));

            page.Children.Add(Section("Remove", Ui.V(Ui.T("Stops the helper and removes it from startup. Your settings and logs stay in the install folder; queued jobs wait until a helper runs again."),
                Ui.H(Ui.Btn("Stop and remove…", async () =>
                {
                    if (!Dialog.Confirm(this, "Stop and remove the helper?", Ui.T("It stops now and no longer starts with Windows. Running compressions keep going but nothing reports on them."), "Stop and remove", "Danger")) return;
                    var r = await Engine.Call("uninstall");
                    if (!r.Ok) { Dialog.Info(this, "Couldn't remove it", r.Error); return; }
                    Dialog.Info(this, "Removed", $"The helper is stopped and won't start with Windows. To remove it completely, delete {Engine.Root} after closing this app.");
                    App.Quit();
                }, "Danger")).M(0, 12, 0, 0)), -1));
            Page.Content = page;
        }
    }
}
