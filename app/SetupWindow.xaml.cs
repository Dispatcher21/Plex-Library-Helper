using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Forms = System.Windows.Forms;

namespace PlexLibraryHelper
{
    // The guided setup (same steps as the old command-prompt setup): welcome and taking over an older copy,
    // Plex sign-in, compression on this PC, phone notifications / dashboard, MakeMKV rips, start with Windows.
    // Every change goes through the engine's API (helper/api.ps1).
    public partial class SetupWindow : Window
    {
        enum Step { Welcome, Plex, Compress, Phone, Rips, Finish }
        static readonly string[] Names = { "Welcome", "Plex sign-in", "Compression", "Phone & dashboard", "MakeMKV rips", "Finish" };

        Dictionary<string, object> _info;
        Step _step;
        readonly int _startAt;
        bool _busy;

        // choices, filled from the current settings
        bool _compressOn, _allowCpu, _benchmarkNow;
        string _workDir;
        List<string> _encoders;                       // tested on this PC during setup (null = not tested)
        string _notifyMode = "phone";                 // phone | connect | none
        bool _pauses = true;
        string _topicPasted = "";
        Dictionary<string, object> _notifySaved;
        bool _ripOn, _ripAuto;
        string _preset4k = "4kh", _presetHD = "1080h";

        public SetupWindow(int startAt = 0)
        {
            InitializeComponent();
            App.DarkTitleBar(this);
            _startAt = startAt;
            VersionText.Text = "Setup · version " + Installer.VersionText;
            PcText.Text = "This PC: " + Environment.MachineName;
            BackBtn.Click += (s, e) => Go(Prev(_step));
            NextBtn.Click += async (s, e) => await Next();
            Loaded += async (s, e) => await Load();
        }

        async Task Load(Step? then = null)
        {
            ShowLoading("Checking this PC…", "Looking at the graphics card, the tools compression needs, and your current settings.");
            var r = await Engine.Call("info");
            if (!r.Ok) { Page.Content = Ui.Card(Ui.T("Couldn't read this PC's settings", "H2"), Ui.T(r.Error).M(0, 8, 0, 12), Ui.Btn("Try again", async () => await Load(), "Primary")); SetFoot(""); return; }
            _info = r.Data;
            var c = _info.O("compress");
            _compressOn = c != null ? c.B("enabled") : true;
            _allowCpu = c != null ? c.B("allowCpu") : Environment.ProcessorCount >= 8;
            _workDir = _info.S("suggestWorkDir");
            var n = _info.O("notify");
            _notifyMode = n != null && n.B("enabled") ? "phone" : n != null && n.S("topic") != null ? "connect" : (_compressOn ? "phone" : "connect");
            _pauses = n == null || n.B("pauses");
            _topicPasted = n?.S("topic") ?? "";
            var rip = _info.O("rip");
            _ripOn = rip == null || rip.B("enabled");
            _ripAuto = rip != null && rip.B("autoCompress");
            _preset4k = rip?.S("preset4k") ?? "4kh"; _presetHD = rip?.S("presetHD") ?? "1080h";
            Go(then ?? (Step)_startAt);
        }

        // ---------------------------------------------------------------- navigation

        bool HasRips => _info != null && _info.B("makemkv");
        Step Prev(Step s) { var p = s - 1; if (p == Step.Rips && !HasRips) p--; return p < 0 ? 0 : p; }
        Step Following(Step s) { var n = s + 1; if (n == Step.Rips && !HasRips) n++; return n; }

        public void GoStep(int s) => Go((Step)s);
        public bool Ready => _info != null;

        void Go(Step s)
        {
            _step = s;
            FootText.Text = ""; FootText.Foreground = Ui.Br("Fg3");
            BackBtn.Visibility = s == Step.Welcome || s == Step.Finish ? Visibility.Hidden : Visibility.Visible;
            NextBtn.IsEnabled = true; BackBtn.IsEnabled = true;
            NextBtn.Content = s == Step.Finish ? "Open Plex Library Helper" : "Next";
            DrawSteps();
            switch (s)
            {
                case Step.Welcome: Welcome(); break;
                case Step.Plex: Plex(); break;
                case Step.Compress: Compress(); break;
                case Step.Phone: Phone(); break;
                case Step.Rips: Rips(); break;
                case Step.Finish: Finish(); break;
            }
            Scroll.ScrollToTop();
        }

        void DrawSteps()
        {
            StepList.Children.Clear();
            for (int i = 0; i < Names.Length; i++)
            {
                if ((Step)i == Step.Rips && !HasRips) continue;
                bool done = i < (int)_step, now = i == (int)_step;
                var circle = new Grid { Width = 24, Height = 24, Margin = new Thickness(0, 0, 12, 0) };
                circle.Children.Add(new Ellipse { Fill = now ? Ui.Br("Accent") : done ? Ui.Br("AccentSoft") : Ui.Br("Raised"), Stroke = done || now ? Ui.Br("Accent") : Ui.Br("LineStrong"), StrokeThickness = 1 });
                circle.Children.Add(new TextBlock { Text = done ? "✓" : (StepList.Children.Count + 1).ToString(), FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = now ? Ui.Br("AccentInk") : done ? Ui.Br("Accent") : Ui.Br("Fg3"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
                var row = Ui.H(circle, Ui.T(Names[i], "Body", fg: now ? Ui.Br("Fg") : done ? Ui.Br("Fg2") : Ui.Br("Fg3")));
                ((TextBlock)row.Children[1]).FontWeight = now ? FontWeights.SemiBold : FontWeights.Normal;
                ((TextBlock)row.Children[1]).VerticalAlignment = VerticalAlignment.Center;
                row.Margin = new Thickness(0, 0, 0, 14);
                StepList.Children.Add(row);
            }
        }

        async Task Next()
        {
            if (_busy) return;
            try
            {
                switch (_step)
                {
                    case Step.Welcome:
                        if (_info.S("oldCopy") != null)
                        {
                            Busy("Moving your settings over…");
                            var r = await Engine.Call("takeover");
                            Idle();
                            if (!r.Ok) { Error(r.Error); return; }
                            await Load(Step.Plex); return;
                        }
                        break;
                    case Step.Plex:
                        if (!_info.B("configured")) { Error("Sign in with Plex first."); return; }
                        break;
                    case Step.Compress: if (!await SaveCompress()) return; break;
                    case Step.Phone: if (!await SaveNotify(false)) return; break;
                    case Step.Rips: if (!await SaveRips()) return; break;
                    case Step.Finish: Close(); return;
                }
                Go(Following(_step));
            }
            catch (Exception e) { Idle(); Error(e.Message); }
        }

        // ---------------------------------------------------------------- helpers

        void ShowLoading(string title, string text)
        {
            Page.Content = Ui.V(Ui.T(title, "H1").M(0, 0, 0, 8), Ui.T(text).M(0, 0, 0, 16), Ui.Bar(0, true));
            NextBtn.IsEnabled = false; BackBtn.IsEnabled = false;
        }
        void Busy(string text) { _busy = true; NextBtn.IsEnabled = false; BackBtn.IsEnabled = false; SetFoot(text); }
        void Idle() { _busy = false; NextBtn.IsEnabled = true; BackBtn.IsEnabled = true; SetFoot(""); }
        void SetFoot(string text) { FootText.Text = text; FootText.Foreground = Ui.Br("Fg3"); }
        void Error(string text) { FootText.Text = text; FootText.Foreground = Ui.Br("Bad"); }
        void Ui_(Action a) => Dispatcher.Invoke(a);

        StackPanel Header(string title, string text) => Ui.V(Ui.T(title, "H1").M(0, 0, 0, 8), Ui.T(text).M(0, 0, 0, 22));

        // ---------------------------------------------------------------- 1 welcome

        void Welcome()
        {
            var hw = _info.O("hardware");
            var page = Header(_info.B("configured") ? "Welcome back" : "Welcome to Plex Library Helper",
                "The helper does the file work for the Plex Library Dashboard on this PC: quarantining duplicates, compressing movies and shows, and showing MakeMKV rips. It runs quietly in the background and lives in the notification area next to the clock.");
            page.Children.Add(Ui.Card(Ui.T("THIS PC", "Label"), Ui.Rows(
                ("Name", Ui.T(_info.S("pc"), fg: Ui.Br("Fg"))),
                ("Processor", Ui.T($"{hw?.S("cpu")} ({hw?.D("threads")} threads)", fg: Ui.Br("Fg"))),
                ("Graphics", Ui.T(string.Join(", ", hw?.AS("gpus") ?? new List<string>()), fg: Ui.Br("Fg"))))));
            var old = _info.S("oldCopy");
            if (old != null)
            {
                var busy = _info.AS("oldBusy");
                if (busy.Count > 0)
                {
                    page.Children.Add(Ui.Card(Ui.Status("warn", "Your current helper is compressing right now"),
                        Ui.T($"{string.Join(", ", busy)} is being compressed by the helper in {old}. Switching now would leave that encode with nobody watching it. Let it finish (or Stop it in the dashboard), then check again.").M(0, 8, 0, 12),
                        Ui.Btn("Check again", async () => await Load(Step.Welcome), "Small")));
                    NextBtn.IsEnabled = false;
                }
                else page.Children.Add(Ui.Card(Ui.Status("ok", "Found your existing helper"),
                    Ui.T($"It's in {old}. Its Plex sign-in and settings move over to this app, so there's nothing to redo; the old folder can be deleted afterwards.").M(0, 8, 0, 0)));
            }
            page.Children.Add(Ui.T("Nothing here opens your PC to the internet: the helper only talks to your Plex server at home, to plex.tv, and (if you want phone notifications) to ntfy.sh.", "Fine").M(0, 6, 0, 0));
            Page.Content = page;
            NextBtn.Content = old != null ? "Move my settings over" : "Get started";
        }

        // ---------------------------------------------------------------- 2 Plex

        void Plex()
        {
            var page = Header("Sign in with Plex", "The helper uses your Plex account to see the jobs you queue in the dashboard. You approve it on Plex's own website; your password never passes through the helper.");
            var status = new ContentControl();
            var bar = Ui.Bar(0, true); bar.Visibility = Visibility.Collapsed;
            var reopen = new Button { Style = Ui.St("LinkButton"), Content = "Open the Plex page again", Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 0) };
            string url = null;
            reopen.Click += (s, e) => { if (url != null) App.Open(url); };
            Button signIn = null;
            signIn = Ui.Btn(_info.B("configured") ? "Sign in again" : "Sign in with Plex", async () =>
            {
                signIn.IsEnabled = false; bar.Visibility = Visibility.Visible; Busy("Waiting for Plex…");
                status.Content = Ui.T("Opening Plex in your browser… approve Plex Library Helper there, then come back here.");
                var r = await Engine.Call("signin", null,
                    p => { if (p.S("url") != null) Ui_(() => { url = p.S("url"); App.Open(url); reopen.Visibility = Visibility.Visible; status.Content = Ui.T("Approve Plex Library Helper in the browser window that just opened. This page continues by itself."); }); },
                    q => Dispatcher.Invoke(() => Dialog.Pick(this, "Which Plex server?", "Your account has several servers. Which one does this helper work for?", q.AS("options").ToArray())));
                bar.Visibility = Visibility.Collapsed; reopen.Visibility = Visibility.Collapsed; signIn.IsEnabled = true; Idle();
                if (!r.Ok) { status.Content = Ui.Status("bad", r.Error); return; }
                _info["configured"] = true; _info["serverName"] = r.Data.S("serverName"); _info["serverUrl"] = r.Data.S("serverUrl");
                Go(Step.Plex);
            }, _info.B("configured") ? null : "Primary");
            if (_info.B("configured"))
                status.Content = Ui.V(Ui.Status("ok", $"Signed in · server {_info.S("serverName")}"), Ui.T(_info.S("serverUrl"), "Fine").M(17, 4, 0, 0));
            page.Children.Add(Ui.Card(status, bar, reopen, Ui.H(signIn).M(0, 14, 0, 0)));
            Page.Content = page;
        }

        // ---------------------------------------------------------------- 3 compression

        void Compress()
        {
            var page = Header("Compression", "The dashboard can shrink big movies and shows (for example a 70 GB 4K disc rip to 15-20 GB, keeping Dolby Vision). Every PC with this on takes the next waiting job it can do, so a slower PC like a file server can work through the queue while your main PC is busy.");
            var details = Ui.V();
            details.Visibility = _compressOn ? Visibility.Visible : Visibility.Collapsed;
            page.Children.Add(Ui.Switch("Use this PC for encoding / compression", "Off: this PC only does quarantines (moving files into _TO_DELETE).", _compressOn,
                on => { _compressOn = on; details.Visibility = on ? Visibility.Visible : Visibility.Collapsed; }));

            // tools
            var tools = _info.O("tools");
            var toolList = Ui.V();
            void AddTool(string key, string name, string what, string apiName)
            {
                bool have = key == "ffmpeg" ? tools.B("ffmpeg") && tools.B("ffprobe") : tools.B(key);
                var right = new ContentControl();
                var bar = Ui.Bar(0, true); bar.Visibility = Visibility.Collapsed; bar.Width = 120; bar.Margin = new Thickness(0);
                if (have) right.Content = Ui.Status("ok", "Installed");
                else
                {
                    Button b = null;
                    b = Ui.Btn("Install", async () =>
                    {
                        b.IsEnabled = false; right.Content = bar; bar.Visibility = Visibility.Visible; Busy($"Installing {name}…");
                        var r = await Engine.Call("installtool", new { name = apiName }, p => Ui_(() => SetFoot(p.S("text"))));
                        Idle();
                        if (!r.Ok) { right.Content = b; b.IsEnabled = true; Error(r.Error); return; }
                        tools[key] = true; if (key == "ffmpeg") tools["ffprobe"] = true;
                        right.Content = Ui.Status("ok", "Installed");
                        if (key == "ffmpeg") await TestEncoders();
                    }, "Small");
                    right.Content = b;
                }
                right.VerticalAlignment = VerticalAlignment.Center;
                toolList.Children.Add(Ui.Split(Ui.V(Ui.T(name, "Body", fg: Ui.Br("Fg")), Ui.T(what, "Fine")), right).M(0, 0, 0, 12));
            }
            AddTool("ffmpeg", "ffmpeg", "Does the encoding (free, installed with winget)", "ffmpeg");
            AddTool("mkvmerge", "MKVToolNix", "Puts the finished file together with the original audio and subtitles", "mkvmerge");
            AddTool("dovi", "dovi_tool", "Keeps Dolby Vision (3 MB from github.com/quietvoid/dovi_tool)", "dovi");
            details.Children.Add(Ui.Card(Ui.T("TOOLS", "Label"), toolList));

            // encoders
            _encList = Ui.V(); _encBar = Ui.Bar(); _encBar.Visibility = Visibility.Collapsed;
            _encTest = Ui.Btn("Test again", async () => await TestEncoders(), "Small");
            var hw = _info.O("hardware");
            details.Children.Add(Ui.Card(Ui.Split(Ui.T("ENCODERS ON THIS PC", "Label"), _encTest),
                Ui.T($"Graphics: {string.Join(", ", hw?.AS("gpus") ?? new List<string>())}. The helper uses the graphics card when it can (fast) and the processor otherwise (slow, but the smallest files).", "Fine").M(0, 0, 0, 10),
                _encBar, _encList));
            DrawEncoders(null);

            // processor jobs
            var threads = (int)(hw?.D("threads") ?? Environment.ProcessorCount);
            var slow = threads >= 12 ? "about a day" : threads >= 8 ? "one to two days" : "several days";
            details.Children.Add(Ui.Card(
                Ui.Switch("Take processor-only jobs too", $"4K Extreme, and AV1 without a graphics AV1 encoder, run on the processor: with {threads} threads here a 2-hour 4K film takes {slow}. They pause for Plex streams and games.", _allowCpu, on => _allowCpu = on).M(0, 0, 0, 0)));

            // work folder
            var box = new TextBox { Text = _workDir };
            box.TextChanged += (s, e) => _workDir = box.Text.Trim();
            var browse = Ui.Btn("Browse…", () =>
            {
                using (var d = new Forms.FolderBrowserDialog { Description = "Folder for encodes in progress", SelectedPath = Directory.Exists(_workDir) ? _workDir : "" })
                    if (d.ShowDialog() == Forms.DialogResult.OK) box.Text = d.SelectedPath;
            }, "Small");
            browse.Margin = new Thickness(8, 0, 0, 0);
            var drives = string.Join(" · ", _info.AO("drives").Select(d => $"{d.S("drive")} {d.D("freeGB"):0} GB free"));
            details.Children.Add(Ui.Card(Ui.T("WORK FOLDER", "Label"), Ui.Split(box, browse),
                Ui.T($"Half-finished encodes live here: needs free space of about 60% of the biggest movie. {drives}", "Fine").M(0, 8, 0, 0)));

            details.Children.Add(Ui.Card(Ui.Switch("Measure the encoders as soon as setup finishes", "The helper measures each encoder on two of your own films (quality, size and speed) so it knows the right setting for each quality level here, and the dashboard can show real estimates. About 20-60 minutes. Otherwise it does this by itself the first time the PC is idle.", _benchmarkNow, on => _benchmarkNow = on).M(0, 0, 0, 0)));
            page.Children.Add(details);
            Page.Content = page;
            if (_compressOn && _encoders == null && tools.B("ffmpeg")) Dispatcher.BeginInvoke(new Action(async () => await TestEncoders()));
        }

        StackPanel _encList; ProgressBar _encBar; Button _encTest;
        readonly Dictionary<string, bool?> _encResults = new Dictionary<string, bool?>();

        void DrawEncoders(string current)
        {
            _encList.Children.Clear();
            var saved = _info.O("compress")?.AS("encoders") ?? new List<string>();
            foreach (var e in _info.AO("encoderLabels"))
            {
                var id = e.S("id");
                bool? ok = _encResults.ContainsKey(id) ? _encResults[id] : (_encoders == null && saved.Count > 0 ? saved.Contains(id) : (bool?)null);
                if (_encoders != null && !_encResults.ContainsKey(id) && current == null) ok = _encoders.Contains(id);
                var kind = id == current ? "busy" : ok == true ? "ok" : ok == false ? "off" : "off";
                var label = e.S("label") + (id == current ? " · testing…" : ok == false ? " · not available" : ok == null ? "" : "");
                var s = Ui.Status(kind, label);
                if (ok == false) ((TextBlock)s.Children[1]).Foreground = Ui.Br("Fg3");
                _encList.Children.Add(s.M(0, 0, 0, 6));
            }
        }

        async Task TestEncoders()
        {
            if (_encList == null) return;
            _encResults.Clear(); _encBar.Visibility = Visibility.Visible; _encBar.Value = 0; _encTest.IsEnabled = false;
            Busy("Testing which encoders work on this PC…");
            var order = _info.AO("encoderLabels").Select(e => e.S("id")).ToList();
            DrawEncoders(order.FirstOrDefault());
            var r = await Engine.Call("testencoders", null, p => Ui_(() =>
            {
                _encResults[p.S("id")] = p.B("ok"); _encBar.Value = p.D("percent");
                var i = order.IndexOf(p.S("id"));
                DrawEncoders(i >= 0 && i + 1 < order.Count ? order[i + 1] : null);
            }));
            Idle(); _encBar.Visibility = Visibility.Collapsed; _encTest.IsEnabled = true;
            if (!r.Ok) { Error(r.Error); return; }
            _encoders = r.Data.AS("encoders");
            DrawEncoders(null);
            if (!_encoders.Any(id => !_info.AO("encoderLabels").First(e => e.S("id") == id).B("cpu")))
                SetFoot("No graphics-card encoder here: only processor encodes, which are slow.");
        }

        async Task<bool> SaveCompress()
        {
            var wasOn = _info.O("compress")?.B("enabled") ?? false;
            if (!_compressOn)
            {
                if (!wasOn) return true;
                Busy("Saving…");
                var off = await Engine.Call("savecompress", new { enabled = false });
                Idle();
                if (!off.Ok) { Error(off.Error); return false; }
                return true;
            }
            if (string.IsNullOrWhiteSpace(_workDir)) { Error("Choose a work folder."); return false; }
            Busy(_encoders == null ? "Testing encoders and saving…" : "Saving…");
            var r = await Engine.Call("savecompress", new { enabled = true, allowCpu = _allowCpu, workDir = _workDir, encoders = _encoders, benchmark = _benchmarkNow });
            Idle();
            if (!r.Ok) { Error("Compression is not on yet: " + r.Error); return false; }
            return true;
        }

        // ---------------------------------------------------------------- 4 phone and dashboard

        void Phone()
        {
            var page = Header("Phone & dashboard", "Your phone can get a notification when a compression, estimate or benchmark finishes or fails, even when the dashboard is closed. It uses the free ntfy app, through a private topic (only the title and the result are sent). The same topic lets the dashboard show rips and _TO_DELETE live, and pause or empty from anywhere.");
            var body = new ContentControl();
            void Draw()
            {
                if (_notifyMode == "phone")
                {
                    var v = Ui.V(Ui.Switch("Also a quiet notification when a compression pauses and carries on", "For example while Plex is transcoding a stream.", _pauses, on => _pauses = on));
                    if (_notifySaved != null) v.Children.Add(Scan(_notifySaved));
                    else v.Children.Add(Ui.H(Ui.Btn("Set up my phone", async () => { if (await SaveNotify(true)) Draw(); }, "Primary")).M(0, 4, 0, 0));
                    body.Content = v;
                }
                else if (_notifyMode == "connect")
                {
                    var box = new TextBox { Text = _topicPasted };
                    box.TextChanged += (s, e) => _topicPasted = box.Text.Trim();
                    var v = Ui.V(Ui.T("Paste the topic from your main PC (it starts with pld-; Plex Library Helper > Settings shows it there), or the dashboard link.", "Body").M(0, 0, 0, 10), box);
                    if (_notifySaved != null) v.Children.Add(Scan(_notifySaved, false));
                    body.Content = v;
                }
                else body.Content = Ui.T("No notifications from this PC, and the dashboard won't see its _TO_DELETE or rips. You can change this any time in Settings.");
            }
            page.Children.Add(Ui.Wrap(
                Ui.Pill("This PC sends notifications", "nm", _notifyMode == "phone", () => { _notifyMode = "phone"; _notifySaved = null; Draw(); }),
                Ui.Pill("Join the topic from my main PC", "nm", _notifyMode == "connect", () => { _notifyMode = "connect"; _notifySaved = null; Draw(); }),
                Ui.Pill("Neither", "nm", _notifyMode == "none", () => { _notifyMode = "none"; Draw(); })).M(0, 0, 0, 12));
            page.Children.Add(Ui.Card(body));
            Draw();
            Page.Content = page;
        }

        // The two QR codes: subscribe in ntfy, and open the dashboard already connected
        UIElement Scan(Dictionary<string, object> saved, bool phone = true)
        {
            var topic = saved.S("topic"); var server = saved.S("server") ?? "https://ntfy.sh";
            var v = Ui.V();
            if (!string.IsNullOrEmpty(saved.S("problem")))
                v.Children.Add(new Border { Background = Ui.Br("BadSoft"), CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 0, 0, 14), Child = Ui.T("Not working yet: " + saved.S("problem") + " Your settings are saved; it starts working as soon as that's fixed.", fg: Ui.Br("Fg")) });
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            UIElement Qr(string title, string text, string content, string steps)
            {
                var img = new Image { Source = QrCode.Encode(content).ToImage(), Width = 170, Height = 170, HorizontalAlignment = HorizontalAlignment.Left };
                RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.NearestNeighbor);
                return Ui.V(Ui.T(title, "H2").M(0, 0, 0, 6), Ui.T(steps, "Fine").M(0, 0, 0, 10), new Border { CornerRadius = new CornerRadius(8), Background = Brushes.White, Padding = new Thickness(4), HorizontalAlignment = HorizontalAlignment.Left, Child = img }, Ui.T(text, "Fine").M(0, 8, 0, 0));
            }
            if (phone)
            {
                var a = Qr("1. Notifications", "Topic: " + topic, $"{server.TrimEnd('/')}/{topic}", "Install ntfy on your phone (Play Store / App Store). Scan this with the camera: it opens your topic; subscribe to it there, or in the app tap + and type the topic below.");
                grid.Children.Add(a);
            }
            var b = Qr(phone ? "2. Dashboard on your phone" : "Dashboard on your phone", "Keep this private, like the topic.", saved.S("dashboardLink"), "Scan to open the dashboard connected to your helpers: rip progress, _TO_DELETE, pause and benchmarks, from anywhere.");
            Grid.SetColumn((UIElement)b, phone ? 2 : 0); grid.Children.Add(b);
            v.Children.Add(grid);
            if (phone)
            {
                var result = new ContentControl { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                Button send = null;
                send = Ui.Btn("Send a test notification", async () =>
                {
                    send.IsEnabled = false; result.Content = Ui.T("Sending…", "Fine");
                    var r = await Engine.Call("sendtest");
                    send.IsEnabled = true;
                    result.Content = r.Ok ? Ui.Status("ok", "Sent. Did it arrive? If not: check the topic, and that ntfy may show notifications (Android: Battery > Unrestricted).") : Ui.Status("bad", r.Error);
                    if (r.Ok) ((TextBlock)((StackPanel)result.Content).Children[1]).TextWrapping = TextWrapping.Wrap;
                }, "Small");
                v.Children.Add(Ui.Split(send, null).M(0, 16, 0, 0));
                v.Children.Add(result);
                result.Margin = new Thickness(0, 10, 0, 0);
            }
            return v;
        }

        async Task<bool> SaveNotify(bool fromButton)
        {
            if (_notifySaved != null && !fromButton) return true;
            object args;
            if (_notifyMode == "phone") args = new { phone = true, pauses = _pauses, channel = true };
            else if (_notifyMode == "connect")
            {
                if (string.IsNullOrWhiteSpace(_topicPasted)) { Error("Paste the topic, or choose Neither."); return false; }
                args = new { phone = false, pauses = false, topic = _topicPasted };
            }
            else args = new { phone = false, pauses = false };
            Busy("Saving…");
            var r = await Engine.Call("savenotify", args);
            Idle();
            if (!r.Ok) { Error(r.Error); return false; }
            // show the QR codes before moving on
            if (_notifyMode != "none") { _notifySaved = r.Data; if (!fromButton) { Phone(); SetFoot("Scan the codes with your phone, then Next."); return false; } }
            return true;
        }

        // ---------------------------------------------------------------- 5 MakeMKV

        void Rips()
        {
            var page = Header("MakeMKV rips", "MakeMKV is installed here. The helper can show your rips on the dashboard (disc, %, speed, time left) and tell your phone when one finishes. You keep ripping in MakeMKV as usual.");
            var auto = Ui.V();
            void DrawAuto()
            {
                auto.Children.Clear();
                if (!_ripAuto) return;
                auto.Children.Add(Ui.T("4K DISCS", "Label").M(0, 6, 0, 8));
                auto.Children.Add(Ui.Wrap(Presets.All.Where(p => p.Id.StartsWith("4k")).Select(p => (UIElement)Ui.Pill(p.Label, "p4", _preset4k == p.Id, () => _preset4k = p.Id)).ToArray()));
                auto.Children.Add(Ui.T("BLU-RAYS", "Label").M(0, 6, 0, 8));
                auto.Children.Add(Ui.Wrap(Presets.All.Where(p => p.Id.StartsWith("1080")).Select(p => (UIElement)Ui.Pill(p.Label, "ph", _presetHD == p.Id, () => _presetHD = p.Id)).ToArray()));
                auto.Children.Add(Ui.T("Movies only: TV rips need their episodes named first, then compress the season from the dashboard. DVDs are left as they are.", "Fine").M(0, 4, 0, 0));
            }
            page.Children.Add(Ui.Card(
                Ui.Switch("Show MakeMKV rip progress on the dashboard", null, _ripOn, on => _ripOn = on),
                Ui.Switch("Compress automatically after a rip finishes", "You can switch this per rip on the dashboard.", _ripAuto, on => { _ripAuto = on; DrawAuto(); }).M(0, 0, 0, 4),
                auto));
            DrawAuto();
            Page.Content = page;
        }

        async Task<bool> SaveRips()
        {
            Busy("Saving…");
            var r = await Engine.Call("saverip", new { enabled = _ripOn, autoCompress = _ripAuto, preset4k = _preset4k, presetHD = _presetHD });
            Idle();
            if (!r.Ok) { Error(r.Error); return false; }
            return true;
        }

        // ---------------------------------------------------------------- 6 finish: start with Windows

        void Finish()
        {
            var status = new ContentControl();
            var bar = Ui.Bar(0, true);
            var page = Header("Starting the helper", "It starts now and whenever you sign in to Windows, and sits in the notification area next to the clock.");
            page.Children.Add(Ui.Card(status, bar));
            Page.Content = page;
            status.Content = Ui.T("Starting…");
            NextBtn.IsEnabled = false;
            Dispatcher.BeginInvoke(new Action(async () =>
            {
                var r = Installer.TestMode ? new ApiResult { Ok = true } : await Engine.Call("installtask");
                bar.Visibility = Visibility.Collapsed; NextBtn.IsEnabled = true;
                if (!r.Ok) { status.Content = Ui.V(Ui.Status("bad", "Couldn't start it: " + r.Error), Ui.Btn("Try again", () => Finish(), "Small").M(0, 10, 0, 0)); return; }
                if (r.Data.B("busy")) { status.Content = Ui.Status("warn", "The helper is compressing right now, so it keeps going; the new settings apply straight away and the new version takes over when it finishes."); }
                else status.Content = Ui.V(Ui.Status("ok", "Running, and starts with Windows."),
                    Ui.T(_benchmarkNow && _compressOn ? "The benchmark starts in a moment: follow it under Encoders." : "Queue compressions from the dashboard; this app shows their progress.", "Fine").M(17, 6, 0, 0));
                var old = _info.S("oldCopy");
                if (old != null) page.Children.Add(Ui.Card(Ui.T("THE OLD FOLDER", "Label"), Ui.T($"Your settings came over from {old}. Nothing runs from there any more: you can delete it (its logs are the only thing you might want)."),
                    Ui.Btn("Show the old folder", () => App.Open(old), "Small").M(0, 10, 0, 0)));
                FootText.Text = "";
            }));
        }
    }
}
