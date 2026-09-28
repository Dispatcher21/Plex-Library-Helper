using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace PlexLibraryHelper
{
    // Small builders so pages read like the layout they make
    public static class Ui
    {
        public static Brush Br(string key) => (Brush)Application.Current.FindResource(key);
        public static Style St(string key) => (Style)Application.Current.FindResource(key);

        public static TextBlock T(string text, string style = "Body", double? size = null, Brush fg = null, Thickness? margin = null)
        {
            var t = new TextBlock { Text = text ?? "", Style = St(style) };
            if (size.HasValue) t.FontSize = size.Value;
            if (fg != null) t.Foreground = fg;
            if (margin.HasValue) t.Margin = margin.Value;
            return t;
        }
        public static TextBlock Rich(string style, params Inline[] parts)
        {
            var t = new TextBlock { Style = St(style) };
            t.Inlines.AddRange(parts);
            return t;
        }
        public static Run Bold(string s) => new Run(s) { FontWeight = FontWeights.SemiBold, Foreground = Br("Fg") };
        public static Run Plain(string s) => new Run(s);

        public static StackPanel V(params UIElement[] kids) { var p = new StackPanel(); foreach (var k in kids) if (k != null) p.Children.Add(k); return p; }
        public static StackPanel H(params UIElement[] kids) { var p = new StackPanel { Orientation = Orientation.Horizontal }; foreach (var k in kids) if (k != null) p.Children.Add(k); return p; }
        public static WrapPanel Wrap(params UIElement[] kids) { var p = new WrapPanel(); foreach (var k in kids) if (k != null) p.Children.Add(k); return p; }

        public static Border Card(params UIElement[] kids) => new Border { Style = St("Card"), Child = V(kids) };

        public static T M<T>(this T e, double l, double t, double r, double b) where T : FrameworkElement { e.Margin = new Thickness(l, t, r, b); return e; }

        public static Button Btn(string text, Action click, string style = null)
        {
            var b = new Button { Content = text };
            if (style != null) b.Style = St(style);
            b.Click += (s, e) => click();
            return b;
        }

        public static CheckBox Switch(string title, string sub, bool on, Action<bool> changed = null)
        {
            var c = new CheckBox { Style = St("Switch"), IsChecked = on, Margin = new Thickness(0, 4, 0, 12) };
            c.Content = V(T(title, "Body", fg: Br("Fg")), string.IsNullOrEmpty(sub) ? null : T(sub, "Fine").M(0, 2, 0, 0));
            if (changed != null) { c.Checked += (s, e) => changed(true); c.Unchecked += (s, e) => changed(false); }
            return c;
        }

        public static RadioButton Pill(string text, string group, bool on, Action picked)
        {
            var r = new RadioButton { Style = St("Pill"), Content = text, GroupName = group, IsChecked = on };
            r.Checked += (s, e) => picked();
            return r;
        }

        // A status dot + text: ok (green), warn (amber), bad (red), off (grey)
        public static StackPanel Status(string kind, string text)
        {
            var color = kind == "ok" ? "Ok" : kind == "warn" ? "Warn" : kind == "bad" ? "Bad" : kind == "busy" ? "Teal" : "Fg3";
            var dot = new System.Windows.Shapes.Ellipse { Width = 9, Height = 9, Fill = Br(color), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            return H(dot, T(text, "Body", fg: Br("Fg")));
        }

        // Label: value rows
        public static Grid Rows(params (string label, UIElement value)[] rows)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            for (int i = 0; i < rows.Length; i++)
            {
                g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var l = T(rows[i].label, "Fine").M(0, 3, 12, 8); Grid.SetRow(l, i);
                var v = rows[i].value as FrameworkElement ?? new ContentControl { Content = rows[i].value };
                v.Margin = new Thickness(0, 1, 0, 8); Grid.SetRow(v, i); Grid.SetColumn(v, 1);
                g.Children.Add(l); g.Children.Add(v);
            }
            return g;
        }

        public static ProgressBar Bar(double pct = 0, bool indeterminate = false) =>
            new ProgressBar { Minimum = 0, Maximum = 100, Value = pct, IsIndeterminate = indeterminate, Margin = new Thickness(0, 8, 0, 6) };

        public static Image Logo(double size) => new Image { Source = (ImageSource)Application.Current.FindResource("Logo"), Width = size, Height = size };

        // Right-aligned content next to a left-aligned one
        public static DockPanel Split(UIElement left, UIElement right)
        {
            var d = new DockPanel { LastChildFill = true };
            if (right != null) { DockPanel.SetDock(right, Dock.Right); d.Children.Add(right); }
            d.Children.Add(left);
            return d;
        }
    }

    // A modal message in the app's style. requireTyped: the OK button only works after typing that word.
    public class Dialog : Window
    {
        public string Answer;
        Dialog(Window owner, string title, UIElement body, string ok, string okStyle, string requireTyped, bool cancel)
        {
            Style = Ui.St("AppWindow"); Owner = owner; Title = title;
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
            SizeToContent = SizeToContent.Height; Width = 480; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = owner == null;
            App.DarkTitleBar(this);
            var okBtn = Ui.Btn(ok, () => { DialogResult = true; }, okStyle);
            okBtn.IsDefault = requireTyped == null;
            var panel = Ui.V(Ui.T(title, "H2").M(0, 0, 0, 10), body);
            if (requireTyped != null)
            {
                var box = new TextBox { Margin = new Thickness(0, 10, 0, 0) };
                okBtn.IsEnabled = false;
                box.TextChanged += (s, e) => { okBtn.IsEnabled = box.Text.Trim() == requireTyped; Answer = box.Text; };
                panel.Children.Add(Ui.T($"Type {requireTyped} to confirm:", "Fine").M(0, 12, 0, 0));
                panel.Children.Add(box);
                Loaded += (s, e) => box.Focus();
            }
            var buttons = Ui.H(cancel ? Ui.Btn("Cancel", () => { DialogResult = false; }, "Ghost").M(0, 0, 8, 0) : null, okBtn);
            buttons.HorizontalAlignment = HorizontalAlignment.Right; buttons.Margin = new Thickness(0, 20, 0, 0);
            panel.Children.Add(buttons);
            Content = new Border { Padding = new Thickness(24, 20, 24, 20), Child = panel };
        }

        public static bool Confirm(Window owner, string title, UIElement body, string ok = "OK", string okStyle = "Primary", string requireTyped = null) =>
            new Dialog(owner, title, body, ok, okStyle, requireTyped, true).ShowDialog() == true;
        public static void Info(Window owner, string title, string text) =>
            new Dialog(owner, title, Ui.T(text), "OK", "Primary", null, false).ShowDialog();

        // Pick one of several options (e.g. Plex servers)
        public static string Pick(Window owner, string title, string text, string[] options)
        {
            string chosen = options.Length > 0 ? options[0] : null;
            var wrap = Ui.Wrap();
            for (int i = 0; i < options.Length; i++) { var o = options[i]; wrap.Children.Add(Ui.Pill(o, "pick", i == 0, () => chosen = o)); }
            var d = new Dialog(owner, title, Ui.V(Ui.T(text).M(0, 0, 0, 12), wrap), "Use this one", "Primary", null, false);
            d.ShowDialog();
            return chosen;
        }
    }
}
