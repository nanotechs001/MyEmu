// AutoPots settings and runtime rules, ported from the Mac app's AutoPotsSettings.swift. The JSON uses the
// same field names, so a game's setup file is the same on both.
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MyEmu.AutoPots;

/// A point or rectangle in Android screen pixels.
public sealed record PixelPoint(int X, int Y);

public sealed record PixelRect(int X, int Y, int Width, int Height)
{
    public bool Contains(PixelPoint p) => p.X >= X && p.X < X + Width && p.Y >= Y && p.Y < Y + Height;
}

public enum GameView
{
    /// The default HUD: the red/blue HP/MP orb at the bottom.
    Orb,
    /// The game's simple view: "HP: 100%" text at the top left.
    Simple,
}

/// AutoPots settings for one game (saved per Android package).
public sealed record AutoPotsSettings
{
    public const int ConfirmMax = 10, TapRandomMax = 80, PressMax = 2000, BurstMax = 10;

    public GameView View { get; set; } = GameView.Orb;
    public PixelRect? OrbBox { get; set; }
    public PixelPoint? OrbPotion { get; set; }
    public PixelRect? SimpleBox { get; set; }
    public PixelPoint? SimplePotion { get; set; }
    /// The "100%" template (SimpleHp.Encode), taken at full HP.
    public string SimpleSignature { get; set; } = "";
    /// Readings below the trigger level in a row before potting (filters skill flashes).
    public int ConfirmReadings { get; set; } = 2;
    /// Minimum gap between readings; 0 reads as often as the capture allows.
    public int ScanIntervalMs { get; set; }
    /// Each potion tap lands up to this many px from the point.
    public int TapRandomPx { get; set; }
    /// How long each potion tap is held down.
    public int PressMs { get; set; }
    /// Taps fired back to back before HP is read again.
    public int ClicksPerBurst { get; set; } = 1;
    /// Null = the detector's tuned darkness threshold.
    public int? CustomDarkMax { get; set; }

    [JsonIgnore] public PixelPoint? Potion => View == GameView.Orb ? OrbPotion : SimplePotion;

    [JsonIgnore]
    public bool IsCalibrated => View switch
    {
        GameView.Orb => OrbBox != null && OrbPotion != null,
        _ => SimpleBox != null && SimplePotion != null && SimpleHp.Decode(SimpleSignature) != null,
    };

    // MARK: Storage

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static string FilePath(string package) =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MyEmu", "autopots", package + ".json");

    /// A missing file means not set up yet; an unreadable one throws for the caller to report.
    public static AutoPotsSettings Load(string path) =>
        File.Exists(path) ? JsonSerializer.Deserialize<AutoPotsSettings>(File.ReadAllText(path), Json) ?? new() : new();

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
        File.Move(temp, path, overwrite: true);
    }
}

/// autopotsCO's runtime rules (OverlayService.kt), as pure functions so they're tested directly.
public static class AutoPotsRules
{
    /// Fire below 90% HP, in both views (autopotsCO's fixed trigger level).
    public const float TriggerLevel = 0.90f;
    /// A low reading that doesn't move more than this for StuckWindowMs after tapping means the
    /// taps do nothing (dead, out of potions): stop until it moves or HP is full again.
    public const float StuckEpsilon = 0.03f;
    public const int StuckWindowMs = 3000;
    /// After a multi-tap burst the HP bar needs a moment before it reflects the potions.
    public const int BurstSettleMs = 90;
    public const int BurstGapMs = 1;
    /// Simple view reads below this as "HP 0%" in the readout.
    public const float SimpleEmptyLevel = 0.70f;

    public static int PressMs(int setting) => Math.Max(Math.Min(setting, AutoPotsSettings.PressMax), 1);

    /// How long a burst of `count` taps occupies the potion button, settle time included.
    public static int BurstBusyMs(int count, int pressMs) =>
        count > 1 ? (count - 1) * (pressMs + BurstGapMs) + pressMs + BurstSettleMs : pressMs;

    /// autopotsCO's readout: the orb only tells full from not full; simple view shows the match.
    public static string Readout(float value, GameView view)
    {
        if (value >= TriggerLevel) return "HP 100%";
        return view == GameView.Orb ? "HP not full" : value < SimpleEmptyLevel ? "HP 0%" : $"HP {(int)(value * 100)}%";
    }
}

/// The futile-tap guard: remembers the reading when tapping began and reports when it hasn't
/// moved for StuckWindowMs. Times are milliseconds on any monotonic clock.
public struct StuckGuard
{
    float? baseline;
    long since;

    public void Reset() => baseline = null;

    /// Call with each low reading; true means stop tapping for now.
    public bool IsStuck(float reading, long nowMs, bool tapping)
    {
        if (baseline is not { } baseValue)
        {
            if (tapping) { baseline = reading; since = nowMs; }
            return false;
        }
        if (Math.Abs(reading - baseValue) > AutoPotsRules.StuckEpsilon)
        {
            baseline = reading; since = nowMs; // it moved: the taps work
            return false;
        }
        return nowMs - since >= AutoPotsRules.StuckWindowMs;
    }
}
