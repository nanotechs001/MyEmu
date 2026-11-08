using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

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
    WriteableBitmap? bitmap;
    long frameCount, shownCount; // written by the frame stream, read on the UI thread
    int frameWidth, frameHeight;
    readonly Stopwatch fpsClock = Stopwatch.StartNew();
    long fpsFrames, fpsReceived;
    bool stopping;

    public MainWindow(string avd)
    {
        this.avd = avd;
        InitializeComponent();
        Loaded += async (_, _) => await StartAsync();
        Closing += OnClosing;
        PreviewKeyDown += (_, e) => OnKey(e, down: true);
        PreviewKeyUp += (_, e) => OnKey(e, down: false);
        CompositionTarget.Rendering += ShowLatestFrame;
        new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(1), System.Windows.Threading.DispatcherPriority.Normal,
            (_, _) => UpdateFps(), Dispatcher).Start();
    }

    async Task StartAsync()
    {
        try
        {
            var hz = RefreshRate();
            Status.Text = $"Starting {avd}...";
            engine = await Engine.StartAsync(avd, GrpcPort, hz, running.Token);
            client = new EmulatorClient(engine.Port, engine.Token);
            frames = new FrameBuffer(engine.Size.Width * engine.Size.Height * 4);
            Status.Text = $"{avd} booting ({engine.Serial})";
            _ = AfterBootAsync(engine.Serial, hz);
            await client.StreamFramesAsync(frames, engine.Size, (w, h) =>
            {
                frameWidth = w; frameHeight = h;
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

    /// Same as the Mac app at every boot: Android renders at the screen's rate, and the guest graphics
    /// driver stops logging two lines per frame from the game's render thread.
    async Task AfterBootAsync(string serial, int hz)
    {
        try
        {
            await Engine.AdbShellAfterBootAsync(serial,
                $"setprop log.tag.MESA W; settings put system peak_refresh_rate {hz}.0; settings put system min_refresh_rate {hz}.0");
        }
        catch (Exception e) { Debug.WriteLine($"After-boot setup failed: {e.Message}"); }
    }

    /// Copies the newest frame once per WPF render, so slow UI never queues frames up.
    unsafe void ShowLatestFrame(object? sender, EventArgs e)
    {
        var count = Interlocked.Read(ref frameCount);
        if (count == shownCount || frames == null) return;
        shownCount = count;
        int w = frameWidth, h = frameHeight;
        if (bitmap == null || bitmap.PixelWidth != w || bitmap.PixelHeight != h)
        {
            bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
            Screen.Source = bitmap;
        }
        bitmap.Lock();
        lock (frames.Sync) Pixels.RgbaToBgra(frames.Pixels.AsSpan(0, w * h * 4), new Span<byte>((void*)bitmap.BackBuffer, w * h * 4));
        bitmap.AddDirtyRect(new Int32Rect(0, 0, w, h));
        bitmap.Unlock();
        fpsFrames++;
    }

    /// Once a second: frames the engine sent vs frames we drew.
    void UpdateFps()
    {
        if (bitmap == null || stopping) return;
        var received = Interlocked.Read(ref frameCount);
        var seconds = fpsClock.Elapsed.TotalSeconds;
        Status.Text = $"{avd} · {frameWidth}×{frameHeight} · {(received - fpsReceived) / seconds:0} fps from Android, {fpsFrames / seconds:0} shown";
        fpsReceived = received;
        fpsFrames = 0;
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
