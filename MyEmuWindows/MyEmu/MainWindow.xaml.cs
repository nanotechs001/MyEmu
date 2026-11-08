using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace MyEmu;

public partial class MainWindow : Window
{
    const int GrpcPort = 8554; // instance 1, as on the Mac
    const int KeyBack = 158, KeyHome = 172, KeyRecents = 580; // Linux evdev codes

    readonly string avd;
    readonly CancellationTokenSource running = new();
    EngineInstance? engine;
    EmulatorClient? client;
    FrameBuffer? frames;
    long frameCount; // written by the frame stream, read on the UI thread
    int frameWidth, frameHeight;
    readonly Stopwatch fpsClock = Stopwatch.StartNew();
    long fpsReceived;
    bool stopping;

    readonly AndroidOptions options = AndroidOptions.Load();
    int displayMaxFps = 60;
    bool runningGuestAngle;
    string? currentApp; // the app in front in Android
    Task adbChain = Task.CompletedTask; // option commands run in order
    bool loadingOptions;

    public MainWindow(string avd)
    {
        this.avd = avd;
        InitializeComponent();
        ShowOptions();
        StateChanged += (_, _) => ApplyRate(); // minimized → background frame rate
        Loaded += async (_, _) => await StartAsync();
        Closing += OnClosing;
        PreviewKeyDown += (_, e) => OnKey(e, down: true);
        PreviewKeyUp += (_, e) => OnKey(e, down: false);
        new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(1), System.Windows.Threading.DispatcherPriority.Normal,
            (_, _) => UpdateFps(), Dispatcher).Start();
    }

    async Task StartAsync()
    {
        try
        {
            displayMaxFps = RefreshRate();
            Status.Text = $"Starting {avd}...";
            runningGuestAngle = options.GuestAngle;
            engine = await Engine.StartAsync(avd, GrpcPort, displayMaxFps, runningGuestAngle, running.Token);
            client = new EmulatorClient(engine.Port, engine.Token);
            frames = new FrameBuffer(engine.Size.Width * engine.Size.Height * 4);
            Status.Text = $"{avd} booting ({engine.Serial})";
            ShowOptions(); // the frame-rate list depends on the screen's rate
            ApplyOptions();
            _ = WatchForegroundAppAsync(engine.Serial);
            var size = engine.Size;
            await client.StreamFramesAsync(frames, size, (w, h) => // frame thread
            {
                Screen.Present(frames.Pixels, w, h);
                if (w != frameWidth || h != frameHeight)
                {
                    (frameWidth, frameHeight) = (w, h);
                    Dispatcher.BeginInvoke(FitScreen);
                }
                Interlocked.Increment(ref frameCount);
            }, running.Token);
            if (!stopping) Status.Text = "The engine stopped sending frames.";
        }
        catch (Exception e) when (!stopping)
        {
            Status.Text = e is OperationCanceledException ? "Stopped." : $"Error: {e.Message}";
        }
        catch { } // closing
    }

    // --- Android options (Mac: EmulatorModel.applyAndroidOptions / applyAndroidRate / watchForegroundApp)

    /// Runs an adb shell command once Android has booted, after the ones queued before it.
    void RunInAndroid(string command)
    {
        if (engine is not { } e) return;
        adbChain = adbChain.ContinueWith(async _ =>
        {
            try { await Engine.AdbShellAfterBootAsync(e.Serial, command); }
            catch (Exception ex) { Debug.WriteLine($"Android command failed: {ex.Message}"); }
        }).Unwrap();
    }

    /// Everything the options set in Android. Idempotent, so it runs at every boot and every change.
    void ApplyOptions()
    {
        RunInAndroid(string.Join("; ", AndroidCommands.QuietGraphicsLog, AndroidCommands.KeepScreenOrientation,
            AndroidCommands.KeyboardOnly(options.KeyboardOnly), AndroidCommands.Lightweight(options.EffectiveLightweight),
            AndroidCommands.Animations(!options.SuperLight)));
        ApplyRate();
    }

    /// Android's refresh rate, and the game in front's own frame rate and render scale.
    void ApplyRate()
    {
        var rate = options.AndroidFps(displayMaxFps, WindowState == WindowState.Minimized);
        var command = AndroidCommands.RefreshRate(rate);
        if (currentApp != null) command += "; " + AndroidCommands.GameMode(rate, options.EffectiveRenderScale, currentApp);
        RunInAndroid(command);
    }

    /// Re-applies the game frame rate whenever another app comes to the front.
    async Task WatchForegroundAppAsync(string serial)
    {
        while (!running.IsCancellationRequested)
        {
            try
            {
                // The event stream reports only later switches; read the app already in front once.
                AppInFront(AndroidWatch.ForegroundPackageFromDump(await Engine.AdbAsync(serial, ["wait-for-device", "shell", AndroidWatch.ForegroundProbe])));
                await foreach (var line in AndroidWatch.Lines(serial, AndroidWatch.ForegroundCommand, running.Token))
                    AppInFront(AndroidWatch.ForegroundPackageFromEvent(line));
            }
            catch (Exception e) when (!running.IsCancellationRequested) { Debug.WriteLine($"Foreground watch ended: {e.Message}"); }
            catch { return; }
            try { await Task.Delay(2000, running.Token); } catch (OperationCanceledException) { return; }
        }
    }

    void AppInFront(string? package)
    {
        if (package == null) return;
        currentApp = package;
        ApplyRate();
    }

    // --- Options panel

    void OptionsButton_Toggled(object sender, RoutedEventArgs e)
    {
        OptionsPanel.Visibility = OptionsButton.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Fills the panel from the saved options.
    void ShowOptions()
    {
        loadingOptions = true;
        FpsBox.Items.Clear();
        FpsBox.Items.Add(new ComboBoxItem { Content = $"Max ({displayMaxFps} fps)", Tag = 0 });
        foreach (var fps in AndroidOptions.FpsChoices.Where(f => f < displayMaxFps))
            FpsBox.Items.Add(new ComboBoxItem { Content = $"{fps} fps", Tag = fps });
        FpsBox.SelectedItem = FpsBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag == options.FpsCap) ?? FpsBox.Items[0];
        if (RenderScaleBox.Items.Count == 0)
            foreach (var scale in AndroidOptions.RenderScales)
                RenderScaleBox.Items.Add(new ComboBoxItem
                {
                    Content = scale >= 1 ? "100% (sharpest)" : scale <= 0.1 ? "10% (fastest, very blurry)" : $"{Math.Round(scale * 100)}%",
                    Tag = scale,
                });
        RenderScaleBox.SelectedItem = RenderScaleBox.Items.Cast<ComboBoxItem>().First(i => (double)i.Tag == options.RenderScale);
        MinimizedBox.IsChecked = options.LowerFpsWhenMinimized;
        SuperLightBox.IsChecked = options.SuperLight;
        LightweightBox.IsChecked = options.Lightweight;
        KeyboardOnlyBox.IsChecked = options.KeyboardOnly;
        RendererBox.SelectedIndex = options.GuestAngle ? 0 : 1;
        UpdateOptionNotes();
        loadingOptions = false;
    }

    void Option_Changed(object sender, RoutedEventArgs e)
    {
        if (loadingOptions) return;
        options.FpsCap = (int)((ComboBoxItem)FpsBox.SelectedItem).Tag;
        options.RenderScale = (double)((ComboBoxItem)RenderScaleBox.SelectedItem).Tag;
        options.LowerFpsWhenMinimized = MinimizedBox.IsChecked == true;
        options.SuperLight = SuperLightBox.IsChecked == true;
        options.Lightweight = LightweightBox.IsChecked == true;
        options.KeyboardOnly = KeyboardOnlyBox.IsChecked == true;
        options.GuestAngle = RendererBox.SelectedIndex == 0;
        options.Save();
        UpdateOptionNotes();
        ApplyOptions();
    }

    void UpdateOptionNotes()
    {
        FpsBox.IsEnabled = RenderScaleBox.IsEnabled = !options.SuperLight;
        RendererNote.Text = engine != null && runningGuestAngle != options.GuestAngle
            ? "Takes effect the next time MyEmu starts Android."
            : "Vulkan ran Xerion at the same fps as OpenGL with about half the GPU. Use OpenGL only if a game draws incorrectly.";
    }

    /// Keeps the screen window at Android's aspect ratio, centered (DXGI stretches the frame to it).
    void FitScreen()
    {
        if (frameWidth == 0) return;
        var scale = Math.Min(ScreenArea.ActualWidth / frameWidth, ScreenArea.ActualHeight / frameHeight);
        Screen.Width = Math.Max(1, frameWidth * scale);
        Screen.Height = Math.Max(1, frameHeight * scale);
    }

    void ScreenArea_SizeChanged(object sender, SizeChangedEventArgs e) => FitScreen();

    /// Once a second: frames Android sent (each one is drawn as it arrives).
    void UpdateFps()
    {
        if (frameWidth == 0 || stopping) return;
        var received = Interlocked.Read(ref frameCount);
        Status.Text = $"{avd} · {frameWidth}×{frameHeight} · {(received - fpsReceived) / fpsClock.Elapsed.TotalSeconds:0} fps";
        fpsReceived = received;
        fpsClock.Restart();
    }

    // --- Touch: one finger from the left mouse button.

    void Screen_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (SendTouch(e.GetPosition(ScreenArea), pressed: true)) ScreenArea.CaptureMouse();
    }

    void Screen_MouseMove(object sender, MouseEventArgs e)
    {
        if (ScreenArea.IsMouseCaptured) SendTouch(e.GetPosition(ScreenArea), pressed: true);
    }

    void Screen_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!ScreenArea.IsMouseCaptured) return;
        SendTouch(e.GetPosition(ScreenArea), pressed: false, clamp: true);
        ScreenArea.ReleaseMouseCapture();
    }

    bool SendTouch(Point p, bool pressed, bool clamp = false)
    {
        if (client == null || engine == null) return false;
        var size = frameWidth > 0 ? new DeviceSize(frameWidth, frameHeight) : engine.Size;
        if (clamp) // lifting outside the screen still has to lift the finger
        {
            var scale = Math.Min(ScreenArea.ActualWidth / size.Width, ScreenArea.ActualHeight / size.Height);
            var left = (ScreenArea.ActualWidth - size.Width * scale) / 2;
            var top = (ScreenArea.ActualHeight - size.Height * scale) / 2;
            p = new Point(Math.Clamp(p.X, left, left + size.Width * scale - 1), Math.Clamp(p.Y, top, top + size.Height * scale - 1));
        }
        if (Pixels.DevicePoint(p.X, p.Y, ScreenArea.ActualWidth, ScreenArea.ActualHeight, size) is not { } d) return false;
        client.Touch(0, d.X, d.Y, pressed);        return true;
    }

    // --- Keys go to Android as Windows scan codes.

    void OnKey(KeyEventArgs e, bool down)
    {
        if (client == null || e.IsRepeat) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var scan = (int)MapVirtualKey((uint)KeyInterop.VirtualKeyFromKey(key), MapvkVkToVscEx);
        if (scan == 0) return;
        client.Key(scan, down);
        e.Handled = true; // keep Tab, arrows and Alt for Android, not WPF focus/menus
    }

    void Back_Click(object sender, RoutedEventArgs e) => client?.AndroidKey(KeyBack);
    void Home_Click(object sender, RoutedEventArgs e) => client?.AndroidKey(KeyHome);
    void Recents_Click(object sender, RoutedEventArgs e) => client?.AndroidKey(KeyRecents);

    async void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (stopping || engine == null) { running.Cancel(); return; }
        e.Cancel = true; // close again once Android is down
        stopping = true;
        Status.Text = "Shutting down Android...";
        running.Cancel();
        await Engine.StopAsync(engine);
        client?.Dispose();
        frames?.Dispose();
        engine = null;
        Close();
    }

    // --- Win32

    const uint MapvkVkToVscEx = 4;
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public short SpecVersion, DriverVersion, Size, DriverExtra;
        public int Fields, PositionX, PositionY, DisplayOrientation, DisplayFixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public short LogPixels;
        public int BitsPerPel, PelsWidth, PelsHeight, DisplayFlags, DisplayFrequency;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string? device, int mode, ref DevMode devMode);

    /// The primary screen's refresh rate (Android otherwise runs at 60 Hz).
    static int RefreshRate()
    {
        var mode = new DevMode { Size = (short)Marshal.SizeOf<DevMode>() };
        return EnumDisplaySettings(null, -1, ref mode) && mode.DisplayFrequency >= 60 ? mode.DisplayFrequency : 60;
    }
}
