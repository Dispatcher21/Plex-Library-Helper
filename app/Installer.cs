using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;

namespace PlexLibraryHelper
{
    // The exe installs itself: one fixed folder per Windows user (no administrator rights, no "(1)" copies),
    // with the PowerShell engine unpacked next to it. Running a newer exe from anywhere (a download, or the
    // app's own updater) replaces the installed one; running an older one just opens the installed one.
    public static class Installer
    {
        public const string ExeName = "Plex Library Helper.exe";
        // PLH_HOME: a test install elsewhere (no watchdog, never touches the scheduled task)
        public static readonly string TestHome = Environment.GetEnvironmentVariable("PLH_HOME");
        public static bool TestMode => !string.IsNullOrEmpty(TestHome);
        public static readonly string InstallDir = TestMode ? TestHome : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Plex Library Helper");
        public static string InstalledExe => Path.Combine(InstallDir, ExeName);
        public static string SelfPath => Assembly.GetExecutingAssembly().Location;
        public static Version MyVersion => Assembly.GetExecutingAssembly().GetName().Version;
        public static string VersionText { get { var v = MyVersion; return $"{v.Major}.{v.Minor}.{v.Build}"; } }

        public static bool RunningFromInstall =>
            string.Equals(Path.GetFullPath(SelfPath), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

        public static Version InstalledVersion()
        {
            try { if (File.Exists(InstalledExe)) return new Version(FileVersionInfo.GetVersionInfo(InstalledExe).FileVersion); } catch { }
            return null;
        }

        // Copy this exe into the install folder (asking a running copy to close first) and unpack the engine
        public static void Install()
        {
            Directory.CreateDirectory(InstallDir);
            SingleInstance.AskRunningToQuit(TimeSpan.FromSeconds(15));
            Exception last = null;
            for (int i = 0; i < 20; i++)
            {
                try { File.Copy(SelfPath, InstalledExe, true); last = null; break; }
                catch (Exception e) { last = e; Thread.Sleep(500); }
            }
            if (last != null) throw new IOException("Couldn't replace the installed Plex Library Helper (is it still running?): " + last.Message);
            ExtractEngine();
        }

        // The PowerShell engine inside this exe -> the install folder (only files that changed)
        public static void ExtractEngine()
        {
            Directory.CreateDirectory(InstallDir);
            var asm = Assembly.GetExecutingAssembly();
            foreach (var name in asm.GetManifestResourceNames().Where(n => n.StartsWith("engine/")))
            {
                var target = Path.Combine(InstallDir, name.Substring("engine/".Length));
                byte[] data;
                using (var s = asm.GetManifestResourceStream(name)) using (var ms = new MemoryStream()) { s.CopyTo(ms); data = ms.ToArray(); }
                if (File.Exists(target) && File.ReadAllBytes(target).SequenceEqual(data)) continue;
                File.WriteAllBytes(target, data);
            }
            File.WriteAllText(Path.Combine(InstallDir, "VERSION.txt"), VersionText);
        }

        public static bool EngineCurrent()
        {
            try { return File.ReadAllText(Path.Combine(InstallDir, "VERSION.txt")).Trim() == VersionText && File.Exists(Path.Combine(InstallDir, "library-helper.ps1")); }
            catch { return false; }
        }
    }

    // One app per Windows user. A second start asks the first to show its window (or to quit, when a newer
    // version is being installed over it).
    public static class SingleInstance
    {
        // a test install (PLH_HOME) gets its own, so it never talks to the real app
        static readonly string Id = @"Local\PlexLibraryHelperApp" + (Installer.TestMode ? "." + Math.Abs(Installer.InstallDir.ToLowerInvariant().GetHashCode()) : "");
        static readonly string MutexName = Id, ShowName = Id + ".Show", QuitName = Id + ".Quit";
        static Mutex _mutex;
        public static EventWaitHandle ShowEvent, QuitEvent;

        public static bool TryBecomeFirst()
        {
            _mutex = new Mutex(false, MutexName);
            bool mine;
            try { mine = _mutex.WaitOne(0); } catch (AbandonedMutexException) { mine = true; }
            if (!mine) return false;
            ShowEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowName);
            QuitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, QuitName);
            return true;
        }
        public static void Release() { try { _mutex?.ReleaseMutex(); } catch { } }

        public static void SignalShow() { try { using (var e = EventWaitHandle.OpenExisting(ShowName)) e.Set(); } catch { } }

        public static void AskRunningToQuit(TimeSpan wait)
        {
            try { using (var e = EventWaitHandle.OpenExisting(QuitName)) e.Set(); } catch { return; }   // nobody running
            using (var m = new Mutex(false, MutexName))
            {
                try { if (m.WaitOne(wait)) m.ReleaseMutex(); } catch (AbandonedMutexException) { }
            }
        }
    }
}
