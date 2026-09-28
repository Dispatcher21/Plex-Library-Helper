using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;

namespace PlexLibraryHelper
{
    // Starting the exe:
    //   from anywhere but the install folder -> install (or update) itself there, then start the installed copy
    //   "--tray"                             -> just the tray icon (what the helper starts at sign-in)
    //   otherwise                            -> tray icon plus the window (setup the first time)
    // Only one runs per Windows user; starting it again brings up the window of the one already running.
    public partial class App : Application
    {
        public static Tray TrayIcon;
        static MainWindow _main;
        static SetupWindow _setup;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += (s, ex) => { ShowError(ex.Exception); ex.Handled = true; };
            var trayOnly = e.Args.Contains("--tray");
            if (e.Args.Length >= 3 && e.Args[0] == "--qr") { Snapshot.Qr(e.Args[1], e.Args[2]); Shutdown(); return; }
            if (e.Args.Length >= 2 && e.Args[0] == "--snapshot") { Snapshot.Run(e.Args[1]); return; }

            var updated = e.Args.Contains("--updated");   // started by the updater
            if (!Installer.RunningFromInstall && (!Installer.TestMode || updated))
            {
                try
                {
                    var installed = Installer.InstalledVersion();
                    var fresh = installed == null || installed < Installer.MyVersion;
                    if (fresh) Installer.Install();
                    var args = new List<string>();
                    if (trayOnly) args.Add("--tray");
                    if (fresh) args.Add("--installed");
                    if (fresh && updated) args.Add("--updated");
                    Process.Start(new ProcessStartInfo(Installer.InstalledExe, string.Join(" ", args)) { UseShellExecute = false });
                }
                catch (Exception ex) { MessageBox.Show(ex.Message, "Plex Library Helper", MessageBoxButton.OK, MessageBoxImage.Error); }
                Shutdown(); return;
            }

            if (!SingleInstance.TryBecomeFirst())
            {
                if (!trayOnly) SingleInstance.SignalShow();
                Shutdown(); return;
            }
            if (!Installer.EngineCurrent()) { try { Installer.ExtractEngine(); } catch { } }

            TrayIcon = new Tray();
            // another start asked for the window, or a newer version is replacing this one
            new Thread(() => WaitSignals()) { IsBackground = true }.Start();

            if (!Engine.Configured || (!trayOnly && !Live.TaskExists())) ShowSetup();
            else if (!trayOnly) ShowMain();
            if (e.Args.Contains("--installed") && Engine.Configured && !Installer.TestMode && Live.TaskExists()) Task.Run(() => AfterUpdate());
            if (updated) TrayIcon.Say("Plex Library Helper updated", $"Now on version {Installer.VersionText}.");
            Updater.Start();
        }

        // A new version was just unpacked: restart the helper so it runs the new engine (unless it's in the
        // middle of an encode; then it picks it up after that, see VERSION.txt in library-helper.ps1)
        static async void AfterUpdate()
        {
            if (Live.Jobs().Any(j => j.Mode != "benchmark")) return;
            await Engine.Call("installtask");
        }

        static void WaitSignals()
        {
            var handles = new WaitHandle[] { SingleInstance.ShowEvent, SingleInstance.QuitEvent };
            while (true)
            {
                var i = WaitHandle.WaitAny(handles);
                Current.Dispatcher.Invoke(() => { if (i == 0) { if (!Engine.Configured) ShowSetup(); else ShowMain(); } else Quit(); });
                if (i == 1) return;
            }
        }

        public static void ShowMain(string page = null)
        {
            if (_setup != null && _setup.IsVisible) { _setup.Activate(); return; }
            if (_main == null) { _main = new MainWindow(); _main.Closed += (s, e) => _main = null; }
            if (page != null) _main.Go(page);
            _main.Show();
            if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
            _main.Activate();
        }

        public static void ShowSetup(int step = 0)
        {
            if (_setup != null) { _setup.Activate(); return; }
            _main?.Close();
            _setup = new SetupWindow(step);
            _setup.Closed += (s, e) => { _setup = null; if (Engine.Configured && Live.TaskExists()) ShowMain(); else if (!Engine.Configured) Quit(); };
            _setup.Show(); _setup.Activate();
        }

        public static void Quit()
        {
            TrayIcon?.Dispose();
            SingleInstance.Release();
            Current.Shutdown();
        }

        public static void ShowError(Exception ex) =>
            MessageBox.Show("Something went wrong: " + ex.Message, "Plex Library Helper", MessageBoxButton.OK, MessageBoxImage.Warning);

        public static void Open(string url) { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { } }

        // Windows 10/11: dark title bar to match
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        public static void DarkTitleBar(Window w)
        {
            w.SourceInitialized += (s, e) =>
            {
                var h = new WindowInteropHelper(w).Handle; int on = 1;
                if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4);
                int caption = 0x0016120F;   // title bar colour (BGR) = the page background, Windows 11
                DwmSetWindowAttribute(h, 35, ref caption, 4);
            };
        }
    }
}
