using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace MyEmu;

/// The mapped keys drawn over Android's screen (port of KeymapOverlayView + ScreenView's editor mouse).
/// A transparent window of its own, owned by MainWindow and kept over the screen: WPF can't draw over
/// the Direct3D child window. While playing, clicks pass through it (WS_EX_TRANSPARENT) to the game;
/// while editing it takes them. It never takes keyboard focus, so keys keep going to MainWindow.
public sealed class KeymapOverlay : Window
{
    public const double KeyRadius = 20;
    /// While editing, keys stay visible enough to grab even at a very low opacity setting.
    const double MinEditingAlpha = 0.45;

    readonly GameKeys keys;
    readonly Canvas canvas;
    BindingRef? dragged;
    bool clickThrough;

    public KeymapOverlay(Window owner, GameKeys keys)
    {
        this.keys = keys;
        Owner = owner;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Content = canvas = new Canvas(this);
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(hwnd).AddHook(NoActivate);
            SetWindowLong(hwnd, GwlExStyle, GetWindowLong(hwnd, GwlExStyle) | WsExNoActivate | WsExToolWindow);
            Refresh();
        };
        MouseLeftButtonDown += (_, e) => EditorDown(e);
        MouseMove += (_, e) => { if (dragged != null && e.LeftButton == MouseButtonState.Pressed) keys.EditorDrag(dragged, Normalized(e, clamp: true)); };
        MouseLeftButtonUp += (_, _) => { dragged = null; ReleaseMouseCapture(); };
        MouseRightButtonDown += (_, e) => { if (keys.IsEditing && Hit(Normalized(e)) is { } hit) keys.EditorRemove(hit); };
    }

    /// Redraws, and lets clicks through unless editing.
    public void Refresh()
    {
        canvas.InvalidateVisual();
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == 0 || clickThrough == !keys.IsEditing) return;
        clickThrough = !keys.IsEditing;
        var style = GetWindowLong(hwnd, GwlExStyle);
        SetWindowLong(hwnd, GwlExStyle, clickThrough ? style | WsExTransparent : style & ~WsExTransparent);
    }

    void EditorDown(MouseButtonEventArgs e)
    {
        if (!keys.IsEditing) return;
        var point = Normalized(e);
        var placeJoystick = Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);
        var hit = Hit(point);
        keys.EditorPress(point, hit, placeJoystick);
        dragged = placeJoystick ? BindingRef.JoystickRef : hit; // press on a key and drag to move it
        if (dragged != null) CaptureMouse();
    }

    NormalizedPoint Normalized(MouseEventArgs e, bool clamp = false)
    {
        var p = e.GetPosition(canvas);
        double x = p.X / Math.Max(1, canvas.ActualWidth), y = p.Y / Math.Max(1, canvas.ActualHeight);
        return clamp ? new(Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1)) : new(x, y);
    }

    BindingRef? Hit(NormalizedPoint p)
    {
        double w = canvas.ActualWidth, h = canvas.ActualHeight;
        return w > 0 && h > 0 ? keys.ShownKeymap.BindingAt(p, KeyRadius / w, KeyRadius / h, w / h) : null;
    }

    /// Clicking the overlay must not take focus (or keys) from MainWindow.
    static nint NoActivate(nint hwnd, int msg, nint w, nint l, ref bool handled)
    {
        if (msg != 0x21) return 0; // WM_MOUSEACTIVATE
        handled = true;
        return 3; // MA_NOACTIVATE
    }

    sealed class Canvas(KeymapOverlay owner) : FrameworkElement
    {
        static readonly Typeface Font = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        static readonly Color Accent = Color.FromRgb(0x3b, 0x82, 0xf6), Orange = Color.FromRgb(0xf5, 0x9e, 0x0b);

        protected override void OnRender(DrawingContext dc)
        {
            var keys = owner.keys;
            var editing = keys.IsEditing;
            double w = ActualWidth, h = ActualHeight;
            // Something must cover the area while editing, or clicks on empty spots fall through.
            dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(editing ? (byte)1 : (byte)0, 0, 0, 0)),
                editing ? new Pen(new SolidColorBrush(Color.FromArgb(204, Accent.R, Accent.G, Accent.B)), 2) : null,
                new Rect(1, 1, Math.Max(0, w - 2), Math.Max(0, h - 2)));
            if (!editing && !(keys.IsEnabled && !keys.IsTyping && !keys.Keymap.IsEmpty)) return;
            var keymap = keys.ShownKeymap;
            var alpha = editing ? Math.Max(keymap.Opacity, MinEditingAlpha) : keymap.Opacity;
            if (keymap.Joystick is { } joystick)
                DrawJoystick(dc, joystick, w, alpha, editing && keys.Selection == BindingRef.JoystickRef);
            foreach (var tap in keymap.Taps)
                DrawKey(dc, tap.Label, new Point(tap.Position.X * w, tap.Position.Y * h), alpha, tap.Mode == TapMode.Burst,
                    editing && keys.Selection == BindingRef.Tap(tap.KeyCode));
            if (editing && keys.PendingTap is { } pending)
            {
                var c = new Point(pending.X * w, pending.Y * h);
                dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(90, Accent.R, Accent.G, Accent.B)),
                    new Pen(new SolidColorBrush(Accent), 2) { DashStyle = new DashStyle([2, 1.5], 0) }, c, KeyRadius, KeyRadius);
                DrawText(dc, "?", c, 1);
            }
        }

        static Brush A(Color c, double alpha) => new SolidColorBrush(Color.FromArgb((byte)(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B));

        void DrawKey(DrawingContext dc, string label, Point c, double alpha, bool burst, bool selected)
        {
            dc.DrawEllipse(A(burst ? Orange : Colors.Black, 0.45 * alpha),
                new Pen(selected ? new SolidColorBrush(Accent) : A(Colors.White, 0.85 * alpha), selected ? 3 : 1.5), c, KeyRadius, KeyRadius);
            DrawText(dc, label, c, alpha);
            if (burst) DrawText(dc, "⚡", new Point(c.X, c.Y + KeyRadius - 6), alpha, 8);
        }

        void DrawJoystick(DrawingContext dc, Joystick joystick, double w, double alpha, bool selected)
        {
            var c = new Point(joystick.Center.X * w, joystick.Center.Y * ActualHeight);
            var r = joystick.Radius * w;
            dc.DrawEllipse(A(Colors.Black, 0.25 * alpha),
                new Pen(selected ? new SolidColorBrush(Accent) : A(Colors.White, 0.8 * alpha), selected ? 3 : 2), c, r, r);
            dc.DrawEllipse(A(Colors.White, 0.35 * alpha), null, c, r * 0.3, r * 0.3); // the thumb at rest
            foreach (var (label, dx, dy) in new[] { ("W", 0.0, -1.0), ("A", -1.0, 0.0), ("S", 0.0, 1.0), ("D", 1.0, 0.0) })
                DrawText(dc, label, new Point(c.X + dx * r * 0.68, c.Y + dy * r * 0.68), alpha);
        }

        void DrawText(DrawingContext dc, string text, Point c, double alpha, double? size = null)
        {
            var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            var fontSize = size ?? (text.Length > 2 ? 10 : 13);
            // Dark halo so white labels read over bright scenes too.
            var halo = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Font, fontSize, A(Colors.Black, 0.9), dpi);
            var origin = new Point(c.X - halo.Width / 2, c.Y - halo.Height / 2);
            foreach (var (ox, oy) in new[] { (-1, 0), (1, 0), (0, -1), (0, 1) }) dc.DrawText(halo, new Point(origin.X + ox, origin.Y + oy));
            dc.DrawText(new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Font, fontSize,
                A(Colors.White, Math.Max(alpha, 0.6)), dpi), origin);
        }
    }

    const int GwlExStyle = -20, WsExTransparent = 0x20, WsExToolWindow = 0x80, WsExNoActivate = 0x08000000;
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLong(nint hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern nint SetWindowLong(nint hwnd, int index, nint value);
}
