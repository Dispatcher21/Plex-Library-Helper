using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PlexLibraryHelper
{
    // For checking the look without clicking through: "--snapshot <folder>" saves every page and setup step
    // as a PNG (use with PLH_HOME for a test install); "--qr <text> <file.png>" saves a QR code.
    public static class Snapshot
    {
        public static void Qr(string text, string png)
        {
            var q = QrCode.Encode(text);
            int scale = 8, size = (q.Size + 8) * scale;
            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen()) dc.DrawImage(q.ToImage(), new Rect(0, 0, size, size));
            var rtb = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
            RenderOptions.SetEdgeMode(dv, EdgeMode.Aliased);
            rtb.Render(dv);
            SavePng(rtb, png);
        }

        public static async void Run(string dir)
        {
            try
            {
                Directory.CreateDirectory(dir);
                if (!Installer.EngineCurrent()) Installer.ExtractEngine();
                var main = new MainWindow();
                main.Show();
                foreach (var page in new[] { "overview", "encoders", "trash", "settings" })
                {
                    main.Go(page);
                    await Task.Delay(page == "trash" ? 9000 : 3000);
                    Save(main, Path.Combine(dir, $"main-{page}.png"));
                }
                main.Close();
                var setup = new SetupWindow(0);
                setup.Show();
                while (!setup.Ready) await Task.Delay(500);
                for (int s = 0; s <= 4; s++)
                {
                    setup.GoStep(s);
                    await Task.Delay(s == 2 ? 14000 : 2000);
                    Save(setup, Path.Combine(dir, $"setup-{s}.png"));
                }
                setup.Close();
            }
            catch (Exception e) { File.WriteAllText(Path.Combine(dir, "error.txt"), e.ToString()); }
            Application.Current.Shutdown();
        }

        static void Save(Window w, string path)
        {
            var el = (FrameworkElement)w.Content;
            var dpi = VisualTreeHelper.GetDpi(w);
            int wpx = (int)(el.ActualWidth * dpi.DpiScaleX), hpx = (int)(el.ActualHeight * dpi.DpiScaleY);
            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen())
            {
                var r = new Rect(0, 0, el.ActualWidth, el.ActualHeight);
                dc.DrawRectangle(w.Background, null, r);
                dc.DrawRectangle(new VisualBrush(el), null, r);
            }
            var rtb = new RenderTargetBitmap(wpx, hpx, 96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, PixelFormats.Pbgra32);
            rtb.Render(dv);
            SavePng(rtb, path);
        }

        static void SavePng(BitmapSource b, string path)
        {
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(b));
            using (var f = File.Create(path)) enc.Save(f);
        }
    }
}
