using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;

namespace PlexLibraryHelper
{
    // One running job (compression, estimate or benchmark), read straight from the worker's files so the
    // progress bars move every couple of seconds (the helper itself only reports every 20 s).
    public class JobView
    {
        public string Id, Title, Mode, Preset, Scope, Encoder, Phase, Paused;
        public int? Year;
        public double Percent;
        public long? SecsLeft;
        public bool Alive;

        public string Heading
        {
            get
            {
                if (Mode == "benchmark") return "Benchmark";
                var name = Title + (Year.HasValue ? $" ({Year})" : "");
                if (!string.IsNullOrEmpty(Scope)) name += " · " + ScopeName(Scope);
                return name;
            }
        }
        public string Kind => Mode == "estimate" ? "Estimate" : Mode == "benchmark" ? "Measuring encoders" : "Compressing";
        public string PresetLabel => Presets.Label(Preset);

        public static string ScopeName(string s)
        {
            if (s == "all") return "whole show";
            if (s != null && s.Length == 3 && s[0] == 'S' && int.TryParse(s.Substring(1), out var n)) return n == 0 ? "Specials" : "Season " + n;
            return s;
        }
    }

    public static class Presets
    {
        public static readonly (string Id, string Label)[] All =
        {
            ("4kx", "4K Extreme"), ("4kh", "4K High"), ("4kn", "4K Normal"), ("4ks", "4K Data Saver"),
            ("1080h", "1080p High"), ("1080n", "1080p Normal"), ("1080s", "1080p Data Saver"),
        };
        public static string Label(string id) => All.FirstOrDefault(p => p.Id == id).Label ?? id ?? "";

        // the encoders in helper/encoders.ps1
        static readonly Dictionary<string, string> Encoders = new Dictionary<string, string>
        {
            ["amf"] = "AMD graphics (HEVC)", ["nvenc"] = "NVIDIA graphics (HEVC)", ["qsv"] = "Intel graphics (HEVC)",
            ["x265"] = "Processor, x265 (HEVC)", ["x265slow"] = "Processor, x265 slow (HEVC)",
            ["av1_amf"] = "AMD graphics (AV1)", ["av1_nvenc"] = "NVIDIA graphics (AV1)", ["av1_qsv"] = "Intel graphics (AV1)", ["svtav1"] = "Processor, SVT-AV1 (AV1)",
        };
        public static string EncoderLabel(string id) => id != null && Encoders.TryGetValue(id, out var l) ? l : null;
        public static bool IsCpu(string id) => id == "x265" || id == "x265slow" || id == "svtav1";
    }

    public static class Live
    {
        public static List<JobView> Jobs()
        {
            var list = new List<JobView>();
            if (!Directory.Exists(Engine.JobsDir)) return list;
            foreach (var f in Directory.GetFiles(Engine.JobsDir, "*.json"))
            {
                if (f.EndsWith(".status.json", StringComparison.OrdinalIgnoreCase)) continue;
                var j = Json.Parse(SafeRead(f));
                if (j == null || j.B("finished")) continue;
                var pid = (int)j.D("workerPid");
                var alive = pid > 0 && ProcessAlive(pid);
                var st = Json.Parse(SafeRead(f.Substring(0, f.Length - 5) + ".status.json"));
                if (!alive && (st == null || st.S("state") != "run")) continue;   // finished or gone: the helper tidies it up
                list.Add(new JobView
                {
                    Id = j.S("jobId"), Title = j.S("title"), Mode = j.S("mode"), Preset = j.S("preset"), Scope = j.S("scope"), Encoder = j.S("encoder"),
                    Year = j.Has("year") ? (int?)(int)j.D("year") : null,
                    Percent = st?.D("percent") ?? 0, SecsLeft = st != null && st.D("secsLeft") > 0 ? (long?)(long)st.D("secsLeft") : null,
                    Phase = st?.S("phase") ?? "Starting", Paused = st?.S("paused"), Alive = alive,
                });
            }
            return list.OrderBy(x => x.Mode == "benchmark" ? 0 : x.Mode == "compress" ? 1 : 2).ToList();
        }

        public static Dictionary<string, object> State() => Json.Parse(SafeRead(Engine.StatePath));

        // Running = its process is alive and it has written its state in the last 3 minutes
        public static bool HelperAlive(Dictionary<string, object> s)
        {
            if (s == null) return false;
            var pid = (int)s.D("pid");
            if (pid <= 0 || !ProcessAlive(pid)) return false;
            return DateTime.TryParse(s.S("time"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var t) && (DateTime.Now - t.ToLocalTime()).TotalMinutes < 3;
        }

        public static bool Paused => File.Exists(Engine.PauseFile);
        public static void SetPaused(bool on)
        {
            Directory.CreateDirectory(Engine.JobsDir);
            if (on) File.WriteAllText(Engine.PauseFile, $"Paused from the app at {DateTime.Now:o}");
            else if (File.Exists(Engine.PauseFile)) File.Delete(Engine.PauseFile);
        }

        public static bool BenchmarkWaiting => File.Exists(Engine.BenchRequest);
        public static void RequestBenchmark()
        {
            Directory.CreateDirectory(Engine.JobsDir);
            File.WriteAllText(Engine.BenchRequest, $"Asked for from the app at {DateTime.Now:o}");
        }
        public static void StopBenchmark()
        {
            if (File.Exists(Engine.BenchRequest)) File.Delete(Engine.BenchRequest);
            foreach (var j in Jobs().Where(x => x.Mode == "benchmark"))
                File.WriteAllText(Path.Combine(Engine.JobsDir, j.Id + ".cancel"), "");
        }

        // ---- the scheduled task that runs the helper
        public static bool TaskExists() => Schtasks($"/Query /TN \"{Engine.TaskName}\"", out _) == 0;
        // The task is running but the helper hasn't reported yet (it takes ~15 s after starting); cached, schtasks is slowish
        // At most 90 s: a helper that stays silent longer is hung, and the watchdog should restart it.
        static DateTime _taskCheckedAt; static bool _taskWasRunning; static DateTime? _startSeen;
        public static bool Starting()
        {
            if (Installer.TestMode) return false;
            if ((DateTime.Now - _taskCheckedAt).TotalSeconds > 8) { _taskWasRunning = TaskRunning(); _taskCheckedAt = DateTime.Now; }
            if (!_taskWasRunning) { _startSeen = null; return false; }
            if (_startSeen == null) _startSeen = DateTime.Now;
            return (DateTime.Now - _startSeen.Value).TotalSeconds < 90;
        }
        public static void Reported() => _startSeen = null;   // the helper wrote its state: next silence counts afresh
        public static bool TaskRunning() => Schtasks($"/Query /TN \"{Engine.TaskName}\" /FO CSV /NH", out var o) == 0 && o.Contains("\"Running\"");

        // Stop (if running), wait until Windows has really stopped it, start, check it came back. Starting too
        // early is ignored (the task never runs two copies), which once left the helper stopped.
        public static bool RestartHelper()
        {
            if (Installer.TestMode) return false;
            var old = (int)(State()?.D("pid") ?? 0);
            Schtasks($"/End /TN \"{Engine.TaskName}\"", out _);
            if (old > 0) { try { Process.GetProcessById(old).Kill(); } catch { } }
            for (int i = 0; i < 40 && (TaskRunning() || (old > 0 && ProcessAlive(old))); i++) Thread.Sleep(500);
            if (Schtasks($"/Run /TN \"{Engine.TaskName}\"", out _) != 0) return false;
            for (int i = 0; i < 40; i++)
            {
                Thread.Sleep(500);
                var s = State();
                var pid = (int)(s?.D("pid") ?? 0);
                if (pid > 0 && pid != old && ProcessAlive(pid)) return true;
            }
            return false;
        }

        public static void StopHelper()
        {
            if (Installer.TestMode) return;
            var old = (int)(State()?.D("pid") ?? 0);
            Schtasks($"/End /TN \"{Engine.TaskName}\"", out _);
            if (old > 0) { try { Process.GetProcessById(old).Kill(); } catch { } }
        }

        static int Schtasks(string args, out string output)
        {
            output = "";
            try
            {
                var psi = new ProcessStartInfo("schtasks.exe", args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                using (var p = Process.Start(psi)) { output = p.StandardOutput.ReadToEnd(); p.WaitForExit(15000); return p.ExitCode; }
            }
            catch { return -1; }
        }

        public static bool ProcessAlive(int pid)
        {
            try { var p = Process.GetProcessById(pid); return !p.HasExited; } catch { return false; }
        }

        public static string SafeRead(string path)
        {
            for (int i = 0; i < 3; i++)
            {
                try
                {
                    if (!File.Exists(path)) return null;
                    using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var r = new StreamReader(fs)) return r.ReadToEnd();
                }
                catch { Thread.Sleep(100); }
            }
            return null;
        }

        public static string Duration(double secs)
        {
            var m = (int)Math.Round(secs / 60);
            if (m < 1) return "under a minute";
            if (m < 60) return m + " min";
            var h = m / 60; var r = m % 60;
            if (h >= 48) return Math.Round(h / 24.0) + " days";
            return r > 0 ? $"{h} h {r} min" : $"{h} h";
        }
        public static string Size(double bytes) => bytes >= 1024.0 * 1024 * 1024 * 1024 ? $"{bytes / Math.Pow(1024, 4):0.0} TB" : bytes >= 100.0 * 1024 * 1024 * 1024 ? $"{bytes / Math.Pow(1024, 3):0} GB" : $"{bytes / Math.Pow(1024, 3):0.0} GB";
    }
}
