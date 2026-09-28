using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace PlexLibraryHelper
{
    public class ApiResult
    {
        public bool Ok;
        public Dictionary<string, object> Data = new Dictionary<string, object>();
        public string Error;
    }

    // Runs the PowerShell engine's commands (library-helper.ps1 -Api <cmd>, see helper/api.ps1): the windows
    // never change settings themselves, so setup behaves exactly like the tested scripts.
    public static class Engine
    {
        public static string Root => Installer.InstallDir;
        public static string JobsDir => Path.Combine(Root, "jobs");
        public static string ConfigPath => Path.Combine(Root, "config.json");
        public static string StatePath => Path.Combine(Root, "state.json");
        public static string PauseFile => Path.Combine(JobsDir, "PAUSED");
        public static string BenchRequest => Path.Combine(JobsDir, "BENCHMARK");
        public static string LogDir => Path.Combine(Root, "logs");
        public const string TaskName = "Plex Library Helper";
        public const string Dashboard = "https://dispatcher21.github.io/Plex-Library-Helper/";

        // progress and ask run on a background thread; ask returns the line to answer with
        public static Task<ApiResult> Call(string cmd, object args = null, Action<Dictionary<string, object>> progress = null,
            Func<Dictionary<string, object>, string> ask = null)
        {
            return Task.Run(() =>
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    $"-NoProfile -ExecutionPolicy Bypass -File \"{Path.Combine(Root, "library-helper.ps1")}\" -Api {cmd}")
                {
                    UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Root,
                    RedirectStandardOutput = true, RedirectStandardInput = true, RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
                };
                psi.EnvironmentVariables["PLH_API_ARGS"] = args == null ? "" : Json.Write(args);
                ApiResult result = null;
                var errors = new StringBuilder();
                using (var p = new Process { StartInfo = psi })
                {
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (errors) errors.AppendLine(e.Data); };
                    try { p.Start(); } catch (Exception e) { return new ApiResult { Error = "Couldn't start PowerShell: " + e.Message }; }
                    p.BeginErrorReadLine();
                    string line;
                    while ((line = p.StandardOutput.ReadLine()) != null)
                    {
                        if (line.StartsWith("@@PROGRESS ")) { try { progress?.Invoke(Json.Parse(line.Substring(11))); } catch { } }
                        else if (line.StartsWith("@@ASK "))
                        {
                            string answer = "";
                            try { answer = ask?.Invoke(Json.Parse(line.Substring(6))) ?? ""; } catch { }
                            p.StandardInput.WriteLine(answer); p.StandardInput.Flush();
                        }
                        else if (line.StartsWith("@@RESULT ")) result = new ApiResult { Ok = true, Data = Json.Parse(line.Substring(9)) ?? new Dictionary<string, object>() };
                        else if (line.StartsWith("@@ERROR ")) result = new ApiResult { Ok = false, Error = line.Substring(8).Trim() };
                    }
                    p.WaitForExit();
                }
                if (result == null)
                {
                    var err = errors.ToString().Trim();
                    result = new ApiResult { Error = string.IsNullOrEmpty(err) ? $"The helper didn't answer ({cmd})." : err.Split('\n').First().Trim() };
                }
                return result;
            });
        }

        public static Dictionary<string, object> ReadConfig() { try { return Json.Parse(File.ReadAllText(ConfigPath)); } catch { return null; } }
        public static bool Configured => File.Exists(ConfigPath);
    }
}
