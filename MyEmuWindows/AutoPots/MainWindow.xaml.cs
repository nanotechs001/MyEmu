// The AutoPots window: one MuMu instance's live screen with the HP box and potion dot, Auto-detect,
// Start/Stop (also F8, anywhere) and tuning. Mirrors the Mac app's AutoPots.swift.
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace MyEmu.AutoPots;

public partial class MainWindow : Window
{
    const int HotkeyId = 1;
    const uint VkF8 = 0x77, ModNoRepeat = 0x4000, WmHotkey = 0x0312;
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    // Auto-detect, as the Mac app (autopotsCO's calibration step 0).
    const int DetectSamples = 3, DetectTries = 5, DetectGapMs = 200;
    /// A box that reads below this at full HP is nudged down until it doesn't (up to 40 px).
    const float FullHpGate = 0.97f;
    const int MaxNudgePx = 40;
    /// autopotsCO aims the orb potion 8 px below the computed point.
    const int OrbPotionBiasPx = 8;

    readonly string? root = MuMu.FindRoot();
    MuMu? mumu;
    Runner? runner;
    CancellationTokenSource? appWatch;
    readonly DispatcherTimer previewTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };

    AutoPotsSettings settings = new();
    string? currentApp, sessionApp;
    bool running;
    float? reading;
    bool loading = true; // filling the controls, not the user changing them

    bool dragging;
    Point dragStart;
    PixelRect? dragBox;
    int frameW = 1280, frameH = 860;
    WriteableBitmap? bitmap;
    byte[] bgra = [];

    public MainWindow()
    {
        InitializeComponent();
        FillControls();
        previewTimer.Tick += (_, _) => DrawPreview();
        Loaded += (_, _) => { RegisterF8(); Connect(); };
        Closed += (_, _) => Disconnect();
    }

    // MARK: Instance

    int InstanceIndex => int.TryParse(InstanceBox.Text, out var i) && i >= 0 ? i : 1;

    void Connect()
    {
        Disconnect();
        if (root == null) { ConnectionText.Text = "MuMu Player 12 isn't installed."; return; }
        var m = mumu = new MuMu(root, InstanceIndex);
        runner = new Runner(m, RunnerConfig, value => Dispatcher.BeginInvoke(() => { reading = value; UpdateStatus(); }));
        previewTimer.Start();
        var watch = appWatch = new CancellationTokenSource();
        Task.Run(async () =>
        {
            while (!watch.IsCancellationRequested)
            {
                var app = m.ForegroundApp();
                await Dispatcher.InvokeAsync(() => { if (!watch.IsCancellationRequested) AppChanged(app); });
                try { await Task.Delay(1000, watch.Token); } catch (TaskCanceledException) { }
            }
        });
        UpdateStatus();
    }

    void Disconnect()
    {
        appWatch?.Cancel();
        previewTimer.Stop();
        runner?.Dispose();
        runner = null;
        mumu?.Dispose();
        mumu = null;
    }

    void InstanceChanged(object sender, RoutedEventArgs e)
    {
        if (mumu?.Instance == InstanceIndex) return;
        Stop();
        currentApp = null;
        Connect();
    }

    /// The game in front changed: its own setup applies; another app in front pauses tapping.
    void AppChanged(string? app)
    {
        if (app == null || app == currentApp) { UpdateStatus(); return; }
        currentApp = app;
        try
        {
            settings = AutoPotsSettings.Load(AutoPotsSettings.FilePath(app));
            Message(null);
        }
        catch (Exception ex)
        {
            settings = new();
            Message($"Couldn't read AutoPots settings for {app}: {ex.Message}");
        }
        FillControls();
        Sync();
    }

    // MARK: Running

    Runner.Config RunnerConfig => new(settings, running && currentApp == sessionApp && !dragging);

    void Sync()
    {
        if (runner != null) runner.Current = RunnerConfig;
        DrawOverlay();
        UpdateStatus();
    }

    void StartStop(object sender, RoutedEventArgs e) { if (running) Stop(); else Start(); }

    void Start()
    {
        if (!settings.IsCalibrated) { Message("Set up AutoPots for this game first (Auto-detect with HP full)."); return; }
        if (currentApp == null) { Message("Waiting for the game: is the MuMu instance running?"); return; }
        sessionApp = currentApp;
        running = true;
        Message(null);
        Sync();
    }

    void Stop()
    {
        running = false;
        Sync();
    }

    void RegisterF8()
    {
        var source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        source.AddHook((IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (msg == WmHotkey && w.ToInt32() == HotkeyId) { StartStop(this, new RoutedEventArgs()); handled = true; }
            return IntPtr.Zero;
        });
        if (!RegisterHotKey(source.Handle, HotkeyId, ModNoRepeat, VkF8)) Message("F8 is taken by another app; use the Start button.");
        Closed += (_, _) => UnregisterHotKey(source.Handle, HotkeyId);
    }

    string Status()
    {
        if (!settings.IsCalibrated) return "Not set up for this game yet: use Auto-detect with HP full.";
        if (running && currentApp != sessionApp) return $"Paused: {sessionApp} isn't in front.";
        if (dragging) return running ? "Paused while you adjust." : "Adjusting.";
        if (reading is not { } value) return running ? "Running: waiting for a reading…" : "Off.";
        var hp = AutoPotsRules.Readout(value, settings.View);
        return running ? $"Running · {hp}" : $"Off · {hp}";
    }

    void UpdateStatus()
    {
        StatusText.Text = Status();
        StartButton.Content = running ? "Stop (F8)" : "Start (F8)";
        ConnectionText.Text = mumu == null ? ConnectionText.Text
            : mumu.IsConnected ? $"connected · {currentApp ?? "…"} in front"
            : $"instance {InstanceIndex} isn't running";
        TemplateButton.Visibility = settings.View == GameView.Simple ? Visibility.Visible : Visibility.Collapsed;
        BoxRect.Stroke = reading is { } v && v < AutoPotsRules.TriggerLevel ? Brushes.Orange : new SolidColorBrush(Color.FromRgb(0x34, 0xC7, 0x59));
    }

    void Message(string? text) => MessageText.Text = text ?? "";

    // MARK: Settings

    /// Applies a change, saves it for the game in front, and hands it to the fast path.
    void Update(Func<AutoPotsSettings, AutoPotsSettings> change)
    {
        settings = change(settings);
        if (currentApp != null)
        {
            try { settings.Save(AutoPotsSettings.FilePath(currentApp)); }
            catch (Exception ex) { Message($"Couldn't save AutoPots settings: {ex.Message}"); }
        }
        Sync();
    }

    void FillControls()
    {
        loading = true;
        OrbView.IsChecked = settings.View == GameView.Orb;
        SimpleView.IsChecked = settings.View == GameView.Simple;
        ConfirmSlider.Value = settings.ConfirmReadings;
        BurstSlider.Value = settings.ClicksPerBurst;
        PressSlider.Value = settings.PressMs;
        RandomSlider.Value = settings.TapRandomPx;
        loading = false;
        DrawOverlay();
    }

    void ViewChanged(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        Update(s => s with { View = SimpleView.IsChecked == true ? GameView.Simple : GameView.Orb });
    }

    void SettingChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (loading) return;
        Update(s => s with
        {
            ConfirmReadings = (int)ConfirmSlider.Value,
            ClicksPerBurst = (int)BurstSlider.Value,
            PressMs = (int)PressSlider.Value,
            TapRandomPx = (int)RandomSlider.Value,
        });
    }

    // MARK: Screen preview and adjusting

    PixelRect? CurrentBox => dragging ? dragBox : settings.View == GameView.Orb ? settings.OrbBox : settings.SimpleBox;
    double Zoom => Screen.Width / frameW;

    void DrawPreview()
    {
        if (mumu?.CaptureCopy() is not { } frame) return;
        int w = frame.Width, h = frame.Height;
        if (bitmap == null || bitmap.PixelWidth != w || bitmap.PixelHeight != h)
        {
            bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgra32, null);
            Preview.Source = bitmap;
            bgra = new byte[w * h * 4];
            (frameW, frameH) = (w, h);
            Screen.Height = Screen.Width * h / w;
            Preview.Height = Screen.Height;
        }
        var src = frame.Pixels;
        for (int y = 0; y < h; y++)
        {
            int s = (h - 1 - y) * w * 4, d = y * w * 4; // MuMu's rows come bottom-up, RGBA
            for (int x = 0; x < w; x++, s += 4, d += 4)
            {
                bgra[d] = src[s + 2]; bgra[d + 1] = src[s + 1]; bgra[d + 2] = src[s]; bgra[d + 3] = 255;
            }
        }
        bitmap.WritePixels(new Int32Rect(0, 0, w, h), bgra, w * 4, 0);
        DrawOverlay();
    }

    void DrawOverlay()
    {
        double k = Zoom;
        if (CurrentBox is { } box)
        {
            BoxRect.Visibility = Visibility.Visible;
            System.Windows.Controls.Canvas.SetLeft(BoxRect, box.X * k);
            System.Windows.Controls.Canvas.SetTop(BoxRect, box.Y * k);
            BoxRect.Width = Math.Max(box.Width * k, 2);
            BoxRect.Height = Math.Max(box.Height * k, 2);
        }
        else BoxRect.Visibility = Visibility.Collapsed;
        if (settings.Potion is { } potion)
        {
            PotionDot.Visibility = Visibility.Visible;
            System.Windows.Controls.Canvas.SetLeft(PotionDot, potion.X * k - PotionDot.Width / 2);
            System.Windows.Controls.Canvas.SetTop(PotionDot, potion.Y * k - PotionDot.Height / 2);
        }
        else PotionDot.Visibility = Visibility.Collapsed;
    }

    PixelPoint ToPixel(Point p) => new((int)Math.Round(p.X / Zoom), (int)Math.Round(p.Y / Zoom));

    void ScreenDown(object sender, MouseButtonEventArgs e)
    {
        var p = e.GetPosition(Screen);
        var pixel = ToPixel(p);
        var box = CurrentBox;
        if (box != null && box.Contains(pixel))
        {
            dragging = true;
            dragStart = p;
            dragBox = box;
            Screen.CaptureMouse();
            Sync(); // no potion taps while the box moves
            return;
        }
        Update(s => s.View == GameView.Orb ? s with { OrbPotion = pixel } : s with { SimplePotion = pixel });
        Message("Potion point set.");
    }

    void ScreenMove(object sender, MouseEventArgs e)
    {
        if (!dragging) return;
        var box = settings.View == GameView.Orb ? settings.OrbBox : settings.SimpleBox;
        if (box == null) return;
        var p = e.GetPosition(Screen);
        dragBox = box with { X = box.X + (int)Math.Round((p.X - dragStart.X) / Zoom), Y = box.Y + (int)Math.Round((p.Y - dragStart.Y) / Zoom) };
        DrawOverlay();
    }

    void ScreenUp(object sender, MouseButtonEventArgs e)
    {
        if (!dragging) return;
        dragging = false;
        Screen.ReleaseMouseCapture();
        var moved = dragBox;
        dragBox = null;
        if (moved == null) { Sync(); return; }
        Update(s => s.View == GameView.Orb ? s with { OrbBox = moved } : s with { SimpleBox = moved });
        if (settings.View == GameView.Simple) Message("Box moved: with HP full, press Retake template.");
    }

    // MARK: Auto-detect

    async void AutoDetect(object sender, RoutedEventArgs e)
    {
        if (mumu is not { } m) return;
        bool wasRunning = running;
        Stop();
        DetectButton.IsEnabled = false;
        Message("Looking for the HP display…");
        var view = settings.View;
        var (change, message) = await Task.Run(() => Detect(m, view));
        if (change != null) Update(change);
        Message(message);
        DetectButton.IsEnabled = true;
        if (wasRunning) Start();
    }

    /// Finds the HP orb or text and the potion on screen (HP must be full). Returns the settings change.
    static (Func<AutoPotsSettings, AutoPotsSettings>? Change, string Message) Detect(MuMu m, GameView view)
    {
        var orbBoxes = new List<int[]>();
        var simpleMaps = new List<SimpleHp.MapResult>();
        NemuFrame? last = null;
        for (int attempt = 0; attempt < DetectTries; attempt++)
        {
            if (attempt > 0) Thread.Sleep(DetectGapMs);
            if (m.CaptureCopy() is not { } frame) continue;
            last = frame;
            if (view == GameView.Orb) { if (HpDetector.AutoMapOrb(frame) is { } box) orbBoxes.Add(box); }
            else if (SimpleHp.AutoMap(frame) is { FromFallback: false } map) simpleMaps.Add(map);
            if (Math.Max(orbBoxes.Count, simpleMaps.Count) >= DetectSamples) break;
        }
        if (last == null) return (null, "Couldn't read the screen. Is the MuMu instance running?");
        return view == GameView.Orb ? DetectOrb(orbBoxes, last) : DetectSimple(simpleMaps, last);
    }

    static (Func<AutoPotsSettings, AutoPotsSettings>?, string) DetectOrb(List<int[]> boxes, NemuFrame frame)
    {
        if (boxes.Count == 0)
            return (null, SimpleHp.AutoMap(frame).FromFallback
                ? "No HP orb found. Show the game's normal HUD with the orb visible, then try again."
                : "No HP orb found, but the simple-view HP text is there: switch Game view to Simple.");
        var box = Enumerable.Range(0, 4).Select(i => boxes.Select(b => b[i]).OrderBy(v => v).ElementAt(boxes.Count / 2)).ToArray();
        int nudge = 0;
        while (HpDetector.HpFractionArc(frame, box[0], box[1], box[2], box[3]) < FullHpGate && nudge < MaxNudgePx) { box[1]++; nudge++; }
        if (HpDetector.HpFractionArc(frame, box[0], box[1], box[2], box[3]) < FullHpGate)
            return (null, "Found the orb, but HP doesn't read full. Fill your HP, then Auto-detect again.");
        var orbBox = new PixelRect(box[0], box[1], box[2], box[3]);
        var potion = new PixelPoint((int)(box[0] + HpDetector.PotionXPerWidth * box[2]),
                                    (int)(box[1] + HpDetector.PotionYPerHeight * box[3]) + OrbPotionBiasPx);
        return (s => s with { OrbBox = orbBox, OrbPotion = potion }, "Found the HP orb and the potion. Check the green dot sits on your HP potion.");
    }

    static (Func<AutoPotsSettings, AutoPotsSettings>?, string) DetectSimple(List<SimpleHp.MapResult> maps, NemuFrame frame)
    {
        if (maps.Count == 0)
            return (null, HpDetector.AutoMapOrb(frame) != null
                ? "No \"HP: 100%\" text found, but the HP orb is there: switch Game view to Orb."
                : "No \"HP: 100%\" text found. Switch the game to simple view with HP full, then try again.");
        var map = maps.OrderBy(r => r.Left).ElementAt(maps.Count / 2);
        var box = new PixelRect(map.Left, map.Top, map.Width, map.Height);
        if (SimpleHp.BuildSignature(frame, box.X, box.Y, box.Width, box.Height, 1) is not { } signature)
            return (null, "Found the HP text but couldn't read it clearly. Try again with HP full.");
        var potion = new PixelPoint((int)map.PotionX, (int)map.PotionY);
        return (s => s with { SimpleBox = box, SimplePotion = potion, SimpleSignature = SimpleHp.Encode(signature) },
                map.PotionFound ? "Found the HP text and the potion." : "Found the HP text. Click your HP potion on the screen to place the dot.");
    }

    /// Simple view: re-takes the "100%" template after the box was moved by hand. HP must be full.
    void RetakeTemplate(object sender, RoutedEventArgs e)
    {
        if (settings.SimpleBox is not { } box || mumu?.CaptureCopy() is not { } frame) return;
        if (SimpleHp.BuildSignature(frame, box.X, box.Y, box.Width, box.Height, 1) is { } signature)
        {
            Update(s => s with { SimpleSignature = SimpleHp.Encode(signature) });
            Message("Took a new HP template.");
        }
        else Message("No readable HP text in the box. Move it over \"100%\" with HP full.");
    }
}
