using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace PlexLibraryHelper
{
    // Updates: the app reads the site's download/latest.json a couple of minutes after starting and then every
    // 6 hours. A newer version is downloaded, checked against the SHA-256 in latest.json (a damaged or
    // different file is refused), and run: it installs itself over this one (see Installer).
    //   Ask me first (default): the tray and the window offer "Install update"; nothing changes until you click.
    //   Automatic: installs by itself, but only while no compression, estimate or benchmark is running.
    // The choice is kept in app.json next to the app (the helper's own settings stay in config.json).
    public static class Updater
    {
        public static string LatestUrl => Environment.GetEnvironmentVariable("PLH_UPDATE_URL") ?? Engine.Dashboard + "download/latest.json";
        static string SettingsPath => Path.Combine(Installer.InstallDir, "app.json");

        public static Version Available { get; private set; }      // newer than this app, or null
        public static string Error { get; private set; }
        public static DateTime? CheckedAt { get; private set; }
        public static bool Busy { get; private set; }
        public static event Action Changed;

        static Dictionary<string, object> _latest;
        static DispatcherTimer _timer;
        static string _notified;                                    // the version the tray already mentioned

        public static bool Auto
        {
            get { var s = Json.Parse(Live.SafeRead(SettingsPath)); return s != null && s.S("updates") == "auto"; }
            set
            {
                var s = Json.Parse(Live.SafeRead(SettingsPath)) ?? new Dictionary<string, object>();
                s["updates"] = value ? "auto" : "ask";
                try { File.WriteAllText(SettingsPath, Json.Write(s)); } catch { }
                Changed?.Invoke();
                if (value) _ = Tick();
            }
        }

        public static void Start()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            // PLH_UPDATE_FIRST (seconds): check sooner, for testing
            var first = int.TryParse(Environment.GetEnvironmentVariable("PLH_UPDATE_FIRST"), out var sec) ? TimeSpan.FromSeconds(sec) : TimeSpan.FromMinutes(2);
            _timer = new DispatcherTimer { Interval = first };
            _timer.Tick += async (s, e) =>
            {
                _timer.Stop();
                await Tick();
                // waiting to install automatically: look again every 10 minutes; otherwise every 6 hours
                _timer.Interval = TimeSpan.FromMinutes(Available != null && Auto ? 10 : 360);
                _timer.Start();
            };
            _timer.Start();
        }

        // Check; and in automatic mode install once nothing is running
        static async Task Tick()
        {
            await Check();
            if (Available == null) return;
            if (Auto) { if (!Live.Jobs().Any()) await Install(); }
            else if (_notified != Available.ToString()) { _notified = Available.ToString(); App.TrayIcon?.OfferUpdate(Available.ToString()); }
        }

        public static async Task Check()
        {
            if (Busy) return;
            Busy = true; Changed?.Invoke();
            try
            {
                using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) })
                {
                    var text = await http.GetStringAsync(LatestUrl + (LatestUrl.Contains("?") ? "&" : "?") + "t=" + DateTime.UtcNow.Ticks);
                    _latest = Json.Parse(text);
                }
                Version v;
                Available = _latest != null && Version.TryParse(_latest.S("version"), out v) && v > Installer.MyVersion ? v : null;
                Error = null;
            }
            catch (Exception e) { Error = "Couldn't check for updates: " + (e.InnerException?.Message ?? e.Message); }
            CheckedAt = DateTime.Now;
            Busy = false; Changed?.Invoke();
        }

        // Download, verify and run the new version (it replaces this app and starts again)
        public static async Task<string> Install()
        {
            if (Busy) return null;
            if (Available == null || _latest == null) return "No update to install.";
            if (Live.Jobs().Any()) return "Waiting: an encode is running. It installs as soon as nothing is running.";
            Busy = true; Changed?.Invoke();
            try
            {
                var file = Path.GetFileName(_latest.S("file") ?? "");
                var sha = (_latest.S("sha256") ?? "").ToLowerInvariant();
                if (!file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || sha.Length != 64) throw new Exception("the update's description on the site is incomplete, so it wasn't installed.");
                var url = new Uri(new Uri(LatestUrl), file);
                var dir = Path.Combine(Path.GetTempPath(), "PlexLibraryHelper-update");
                Directory.CreateDirectory(dir);
                var path = Path.Combine(dir, file);
                using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
                    File.WriteAllBytes(path, await http.GetByteArrayAsync(url));
                string got;
                using (var s = File.OpenRead(path)) using (var h = SHA256.Create()) got = BitConverter.ToString(h.ComputeHash(s)).Replace("-", "").ToLowerInvariant();
                if (got != sha) { File.Delete(path); throw new Exception("the download didn't match the published version (damaged or changed), so it wasn't installed."); }
                // the new exe installs itself (this app is asked to quit) and starts in the tray
                Process.Start(new ProcessStartInfo(path, "--tray --updated") { UseShellExecute = false });
                return null;
            }
            catch (Exception e) { Error = "Update failed: " + e.Message; Busy = false; Changed?.Invoke(); return Error; }
        }
    }
}
