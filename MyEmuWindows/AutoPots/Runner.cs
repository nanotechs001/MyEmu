// AutoPots' fast path, ported from the Mac app's AutoPotsRunner.swift: read HP from each capture on its own
// thread and tap the potion right away. Settings and on/off arrive through Config. Shared by the MuMu app
// (MuMu's SDK) and MyEmu (its own frames and touches).
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace MyEmu.AutoPots;

public sealed class Runner : IDisposable
{
    /// Tapping = running, the game is in front and nothing is being adjusted (otherwise readings only).
    public sealed record Config(AutoPotsSettings Settings, bool Tapping);

    // ponytail: captures are polled (MuMu's SDK has no new-frame signal); 10 ms (100 reads/s) is ~3× the
    // game's fps in a crowd. Event-driven reads if a frame source ever needs it.
    const int MinPeriodMs = 10;
    const int PublishIntervalMs = 100;
    const int RetryMs = 500;

    readonly Func<IPixelFrame?> capture;
    readonly Action<int, int, bool> touch;
    readonly Action<float?> onReading;
    readonly Thread thread;
    volatile Config config;
    volatile bool stopping;

    // Loop state (loop thread only), plus the potion clock the tap bursts set.
    int lowStreak;
    StuckGuard stuck;
    long lastPublished = long.MinValue;
    long busyUntil;

    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static long NowMs => Clock.ElapsedMilliseconds;

    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);

    /// `capture`: the current screen, full size, or null when there is none. `touch`: (x, y, down) in its pixels.
    public Runner(Func<IPixelFrame?> capture, Action<int, int, bool> touch, Config config, Action<float?> onReading)
    {
        this.capture = capture;
        this.touch = touch;
        this.config = config;
        this.onReading = onReading;
        thread = new Thread(Loop) { IsBackground = true, Name = "AutoPots", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    public Config Current { set => config = value; }

    void Loop()
    {
        timeBeginPeriod(1); // 1 ms sleeps for the read period and tap presses (Windows' default is 15.6 ms)
        try
        {
            while (!stopping)
            {
                long start = NowMs;
                var frame = capture();
                if (frame == null)
                {
                    Publish(null, force: true);
                    Thread.Sleep(RetryMs);
                    continue;
                }
                Process(frame, start);
                int period = Math.Max(MinPeriodMs, config.Settings.ScanIntervalMs);
                int wait = (int)(start + period - NowMs);
                if (wait > 0) Thread.Sleep(wait);
            }
        }
        finally { timeEndPeriod(1); }
    }

    void Process(IPixelFrame frame, long now)
    {
        var c = config;
        var value = Read(frame, c.Settings);
        bool fire = false;
        if (value is { } v && v < AutoPotsRules.TriggerLevel)
        {
            lowStreak++;
            bool firing = c.Tapping && lowStreak >= c.Settings.ConfirmReadings;
            bool isStuck = stuck.IsStuck(v, now, firing);
            fire = firing && !isStuck && now >= Interlocked.Read(ref busyUntil);
        }
        else
        {
            lowStreak = 0;
            stuck.Reset();
        }
        if (fire && c.Settings.Potion is { } potion) TapPotion(potion, c.Settings, now);
        Publish(value);
    }

    void Publish(float? value, bool force = false)
    {
        long now = NowMs;
        if (!force && now - lastPublished < PublishIntervalMs) return;
        lastPublished = now;
        onReading(value);
    }

    /// Remaining HP (0…1) in the configured view, or null when it can't be read. Frames are full size.
    public static float? Read(IPixelFrame frame, AutoPotsSettings settings)
    {
        float value;
        switch (settings.View)
        {
            case GameView.Orb:
                if (settings.OrbBox is not { } box) return null;
                value = HpDetector.HpFractionArc(frame, box.X, box.Y, box.Width, box.Height,
                                                 settings.CustomDarkMax ?? HpDetector.DarkMax);
                break;
            default:
                if (settings.SimpleBox is not { } sbox || SimpleHp.Decode(settings.SimpleSignature) is not { } signature) return null;
                value = SimpleHp.Match(frame, sbox.X, sbox.Y, sbox.Width, sbox.Height, 1, signature, sbox.Width, sbox.Height);
                break;
        }
        return value < 0 ? null : value;
    }

    /// The potion burst: the first press goes out immediately, the rest are timed off the read thread.
    void TapPotion(PixelPoint potion, AutoPotsSettings settings, long now)
    {
        int count = Math.Clamp(settings.ClicksPerBurst, 1, AutoPotsSettings.BurstMax);
        int press = AutoPotsRules.PressMs(settings.PressMs);
        Interlocked.Exchange(ref busyUntil, now + AutoPotsRules.BurstBusyMs(count, press));
        int r = settings.TapRandomPx;
        var points = Enumerable.Range(0, count)
            .Select(_ => r > 0 ? new PixelPoint(potion.X + Random.Shared.Next(-r, r + 1), potion.Y + Random.Shared.Next(-r, r + 1)) : potion)
            .ToArray();
        touch(points[0].X, points[0].Y, true);
        Task.Run(() =>
        {
            for (int i = 0; i < count; i++)
            {
                if (i > 0) { Thread.Sleep(AutoPotsRules.BurstGapMs); touch(points[i].X, points[i].Y, true); }
                Thread.Sleep(press);
                touch(points[i].X, points[i].Y, false);
            }
        });
    }

    public void Dispose()
    {
        stopping = true;
        thread.Join(1000);
    }
}
