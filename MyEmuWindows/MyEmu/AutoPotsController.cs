using MyEmu.AutoPots;

namespace MyEmu;

/// Android's screen as AutoPots reads it: RGBA rows, top row first (the frame stream's buffer).
public sealed class RgbaFrame(byte[] pixels, int width, int height) : IPixelFrame
{
    public int Width { get; } = width;
    public int Height { get; } = height;

    public int Rgb(int x, int y)
    {
        int i = (y * Width + x) * 4;
        return pixels[i] << 16 | pixels[i + 1] << 8 | pixels[i + 2];
    }
}

/// AutoPots inside MyEmu (Mac: AutoPots.swift): per-game setup, Start/Stop, Auto-detect and adjusting the HP
/// box and potion dot on the screen. Detection, rules and the fast path are the MuMu AutoPots app's (shared
/// files); here they read MyEmu's own frames and tap through its gRPC touches. UI thread only.
public sealed class AutoPotsController(Func<IPixelFrame?> liveFrame, Func<IPixelFrame?> frameCopy, Action<int, int, bool> touch) : IDisposable
{
    Runner? runner;
    AutoPotsSettings settings = new();
    string? currentApp, sessionApp;
    PixelPoint? dragStart;
    PixelRect? dragBox;

    public event Action? OnChange;
    public AutoPotsSettings Settings => settings;
    public bool Running { get; private set; }
    /// The HP box and potion dot take clicks on the screen (the game doesn't).
    public bool Adjusting { get; private set; }
    public bool Detecting { get; private set; }
    public float? Reading { get; private set; }
    public string? Message { get; private set; }
    public PixelRect? Box => dragBox ?? (settings.View == GameView.Orb ? settings.OrbBox : settings.SimpleBox);
    public bool ReadingLow => Reading is { } v && v < AutoPotsRules.TriggerLevel;
    /// Shown over the game while adjusting or running.
    public bool ShowsMarks => Adjusting || (Running && settings.IsCalibrated);

    /// Starts reading HP once Android's frames flow; `onReading` comes from the reader thread.
    public void Attach(Action<float?> onReading) =>
        runner ??= new Runner(liveFrame, touch, Config, onReading);

    public void Dispose()
    {
        runner?.Dispose();
        runner = null;
    }

    public void SetReading(float? value)
    {
        Reading = value;
        OnChange?.Invoke();
    }

    /// The game in front changed: its own setup applies; another app in front pauses tapping.
    public void AppDidChange(string package)
    {
        if (package == currentApp) return;
        currentApp = package;
        try
        {
            settings = AutoPotsSettings.Load(AutoPotsSettings.FilePath(package));
            Message = null;
        }
        catch (Exception e)
        {
            settings = new();
            Message = $"Couldn't read AutoPots settings for {package}: {e.Message}";
        }
        Sync();
    }

    Runner.Config Config => new(settings, Running && currentApp == sessionApp && !Adjusting && dragBox == null);

    void Sync()
    {
        if (runner != null) runner.Current = Config;
        OnChange?.Invoke();
    }

    public void Toggle() { if (Running) Stop(); else Start(); }

    public void Start()
    {
        if (!settings.IsCalibrated) { Say("Set up AutoPots for this game first: Auto-detect with HP full."); return; }
        if (currentApp == null) { Say("Waiting for Android to show a game."); return; }
        sessionApp = currentApp;
        Running = true;
        Message = null;
        Sync();
    }

    public void Stop()
    {
        Running = false;
        Sync();
    }

    public void SetAdjusting(bool on)
    {
        Adjusting = on;
        if (!on) (dragStart, dragBox) = (null, null);
        Message = on ? "Drag the box onto the HP display; click elsewhere to put the potion dot on your HP potion." : null;
        Sync();
    }

    public string Status
    {
        get
        {
            if (!settings.IsCalibrated) return "Not set up for this game yet.";
            if (Running && currentApp != sessionApp) return $"Paused: {sessionApp} isn't in front.";
            if (Adjusting) return Running ? "Paused while you adjust." : "Adjusting.";
            if (Reading is not { } value) return Running ? "Running: waiting for a reading…" : "Off.";
            var hp = AutoPotsRules.Readout(value, settings.View);
            return Running ? $"Running · {hp}" : $"Off · {hp}";
        }
    }

    void Say(string text)
    {
        Message = text;
        OnChange?.Invoke();
    }

    /// Applies a change, saves it for the game in front, and hands it to the fast path.
    public void Update(Func<AutoPotsSettings, AutoPotsSettings> change)
    {
        settings = change(settings);
        if (currentApp != null)
        {
            try { settings.Save(AutoPotsSettings.FilePath(currentApp)); }
            catch (Exception e) { Message = $"Couldn't save AutoPots settings: {e.Message}"; }
        }
        Sync();
    }

    public async Task AutoDetectAsync()
    {
        if (Detecting) return;
        var wasRunning = Running;
        Stop();
        Detecting = true;
        Say("Looking for the HP display…");
        var view = settings.View;
        var (change, message) = await Task.Run(() => Calibration.Detect(frameCopy, view));
        Detecting = false;
        if (change != null) Update(change);
        Say(message);
        if (wasRunning) Start();
    }

    public void RetakeTemplate()
    {
        if (settings.SimpleBox is not { } box || frameCopy() is not { } frame) return;
        if (Calibration.RetakeTemplate(frame, box) is { } signature)
        {
            Update(s => s with { SimpleSignature = signature });
            Say("Took a new HP template.");
        }
        else Say("No readable HP text in the box. Move it over \"100%\" with HP full.");
    }

    // --- Adjusting on the screen (device pixels)

    public void PressAt(PixelPoint p)
    {
        if (!Adjusting) return;
        if (Box is { } box && box.Contains(p))
        {
            (dragStart, dragBox) = (p, box);
            Sync(); // no potion taps while the box moves
            return;
        }
        Update(s => s.View == GameView.Orb ? s with { OrbPotion = p } : s with { SimplePotion = p });
        Say("Potion point set.");
    }

    public void DragTo(PixelPoint p)
    {
        if (dragStart is not { } start || (settings.View == GameView.Orb ? settings.OrbBox : settings.SimpleBox) is not { } box) return;
        dragBox = box with { X = box.X + p.X - start.X, Y = box.Y + p.Y - start.Y };
        OnChange?.Invoke();
    }

    public void Release()
    {
        if (dragBox is not { } moved) return;
        (dragStart, dragBox) = (null, null);
        Update(s => s.View == GameView.Orb ? s with { OrbBox = moved } : s with { SimpleBox = moved });
        if (settings.View == GameView.Simple) Say("Box moved: with HP full, press Retake template.");
    }
}
