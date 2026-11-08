using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MyEmu;

// Port of Keymap.swift. The JSON is the Mac's, field for field, and key codes are Mac virtual key codes
// (MacKeys translates Windows keys), so a game's mapping file works in both apps.

/// A screen position as a fraction (0...1) of the device's width and height.
public sealed record NormalizedPoint(double X, double Y);

/// Saved as "hold" / "burst" (camelCase enum converter in Keymap's JSON options).
public enum TapMode
{
    /// The finger stays down while the key is held.
    Hold,
    /// Holding the key taps the spot repeatedly at the keymap's burst rate.
    Burst,
}

/// A keyboard key that touches one spot while pressed.
public sealed record KeyTap(ushort KeyCode, string Label, NormalizedPoint Position, TapMode Mode = TapMode.Hold);

/// WASD drives a virtual thumb on an on-screen joystick.
public sealed record Joystick(NormalizedPoint Center, double Radius = Joystick.DefaultRadius)
{
    public const double DefaultRadius = 0.08;
}

/// One thing on the map: a key's tap spot (by key code), or the WASD joystick (null key code).
public sealed record BindingRef(ushort? KeyCode)
{
    public static readonly BindingRef JoystickRef = new((ushort?)null);
    public static BindingRef Tap(ushort keyCode) => new(keyCode);
    public bool IsJoystick => KeyCode == null;
}

public static class Burst
{
    public const double MinRate = 2, MaxRate = 20, DefaultRate = 10;
    /// Long enough for games that poll input once per frame to see the touch.
    const double MaxPress = 0.03;

    /// How long each tap holds the finger down, then how long it waits before the next tap.
    public static (TimeSpan Press, TimeSpan Release) Timing(double rate)
    {
        var period = 1 / Math.Clamp(rate, MinRate, MaxRate);
        var press = Math.Min(MaxPress, period / 2);
        return (TimeSpan.FromSeconds(press), TimeSpan.FromSeconds(period - press));
    }
}

public sealed record Keymap
{
    public const double MinOpacity = 0.1, MaxOpacity = 1, DefaultOpacity = 0.6;
    public const double MinJoystickRadius = 0.04, MaxJoystickRadius = 0.2;

    public IReadOnlyList<KeyTap> Taps { get; init; } = [];
    public Joystick? Joystick { get; init; }
    /// Taps per second for burst keys.
    public double BurstRate { get; init; } = Burst.DefaultRate;
    /// How visible the keys are drawn over the game while playing.
    public double Opacity { get; init; } = DefaultOpacity;

    [JsonIgnore] public bool IsEmpty => Taps.Count == 0 && Joystick == null;

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static string Directory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MyEmu", "keymaps");

    /// Each game (Android package) has its own mapping. `package` must pass `AndroidWatch.IsValidPackage`.
    public static string FilePath(string package) => Path.Combine(Directory, package + ".json");

    /// A missing file means no mapping yet; an unreadable one throws.
    public static Keymap Load(string path) => File.Exists(path) ? FromJson(File.ReadAllText(path)) : new();

    public static Keymap FromJson(string json) => JsonSerializer.Deserialize<Keymap>(json, Json) ?? new();
    public string ToJson() => JsonSerializer.Serialize(this, Json);

    public void Save(string path)
    {
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, ToJson());
        File.Move(temp, path, overwrite: true);
    }

    /// Value equality (records compare lists by reference).
    public bool SameAs(Keymap other) => ToJson() == other.ToJson();

    /// Binds `key`, replacing whatever that key did before.
    public Keymap Binding(KeyTap key) => this with { Taps = [.. Taps.Where(t => t.KeyCode != key.KeyCode), key] };

    public Keymap SettingMode(TapMode mode, ushort keyCode) =>
        this with { Taps = [.. Taps.Select(t => t.KeyCode == keyCode ? t with { Mode = mode } : t)] };

    public Keymap SettingBurstRate(double rate) => this with { BurstRate = Math.Clamp(rate, Burst.MinRate, Burst.MaxRate) };
    public Keymap SettingOpacity(double value) => this with { Opacity = Math.Clamp(value, MinOpacity, MaxOpacity) };

    public Keymap SettingJoystickRadius(double radius) =>
        Joystick == null ? this : this with { Joystick = Joystick with { Radius = Math.Clamp(radius, MinJoystickRadius, MaxJoystickRadius) } };

    public Keymap WithJoystick(NormalizedPoint center) =>
        this with { Joystick = new Joystick(center, Joystick?.Radius ?? MyEmu.Joystick.DefaultRadius) };

    /// Moves a key or the joystick, kept on the screen.
    public Keymap Moving(BindingRef binding, NormalizedPoint point)
    {
        var p = new NormalizedPoint(Math.Clamp(point.X, 0, 1), Math.Clamp(point.Y, 0, 1));
        if (binding.IsJoystick) return Joystick == null ? this : this with { Joystick = Joystick with { Center = p } };
        return this with { Taps = [.. Taps.Select(t => t.KeyCode == binding.KeyCode ? t with { Position = p } : t)] };
    }

    public Keymap Removing(BindingRef binding) => binding.IsJoystick
        ? this with { Joystick = null }
        : this with { Taps = [.. Taps.Where(t => t.KeyCode != binding.KeyCode)] };

    /// Gives a key's spot to a different keyboard key (the editor's "click a key, press a new one").
    public Keymap Rebinding(ushort keyCode, ushort newKey, string label)
    {
        var tap = Taps.FirstOrDefault(t => t.KeyCode == keyCode);
        if (tap == null) return this;
        return this with { Taps = [.. Taps.Where(t => t.KeyCode != keyCode && t.KeyCode != newKey), tap with { KeyCode = newKey, Label = label }] };
    }

    /// The key or joystick under `point`. `keyRadiusX/Y` is a key's size in normalized units per axis
    /// (screens aren't square); the joystick counts within its own radius.
    public BindingRef? BindingAt(NormalizedPoint point, double keyRadiusX, double keyRadiusY, double aspect)
    {
        double KeyDistance(NormalizedPoint p) => Math.Sqrt(Math.Pow((p.X - point.X) / keyRadiusX, 2) + Math.Pow((p.Y - point.Y) / keyRadiusY, 2));
        var nearest = Taps.MinBy(t => KeyDistance(t.Position));
        if (nearest != null && KeyDistance(nearest.Position) <= 1) return BindingRef.Tap(nearest.KeyCode);
        if (Joystick != null)
        {
            // Radius is a fraction of the width; measure in width units on both axes.
            double dx = point.X - Joystick.Center.X, dy = (point.Y - Joystick.Center.Y) / aspect;
            if (Math.Sqrt(dx * dx + dy * dy) <= Joystick.Radius) return BindingRef.JoystickRef;
        }
        return null;
    }
}

/// One finger to put down, move, or lift, in device pixels.
public readonly record struct TouchPoint(int Id, int X, int Y, bool Pressed);

/// Turns key presses into touches for a keymap. Pure logic; GameKeys sends the result.
public sealed class KeyTouchMapper(Keymap keymap, DeviceSize device)
{
    public const int MouseFingerId = 0, JoystickFingerId = 1, FirstTapFingerId = 2;
    public const ushort MacW = 13, MacA = 0, MacS = 1, MacD = 2;
    public static readonly HashSet<ushort> Wasd = [MacW, MacA, MacS, MacD];

    readonly HashSet<ushort> heldTaps = [];
    readonly HashSet<ushort> heldDirections = [];

    /// Touches for a key change, [] for a repeat or stray release, null when the key isn't mapped
    /// (it should then reach Android as a normal key).
    public List<TouchPoint>? Handle(ushort keyCode, bool down)
    {
        if (keymap.Joystick is { } joystick && Wasd.Contains(keyCode)) return MoveJoystick(joystick, keyCode, down);
        var index = keymap.Taps.ToList().FindIndex(t => t.KeyCode == keyCode);
        if (index < 0) return null;
        var changed = down ? heldTaps.Add(keyCode) : heldTaps.Remove(keyCode);
        if (!changed) return [];
        var (x, y) = Pixel(device, keymap.Taps[index].Position);
        return [new TouchPoint(FirstTapFingerId + index, x, y, down)];
    }

    /// Lifts every finger this mapper holds down (window lost focus, mapping turned off).
    public List<TouchPoint> ReleaseAll()
    {
        var lifts = new List<TouchPoint>();
        foreach (var key in heldTaps.ToList()) lifts.AddRange(Handle(key, false) ?? []);
        if (keymap.Joystick is { } joystick && heldDirections.Count > 0)
        {
            var (x, y) = Pixel(device, joystick.Center);
            heldDirections.Clear();
            lifts.Add(new TouchPoint(JoystickFingerId, x, y, false));
        }
        return lifts;
    }

    List<TouchPoint> MoveJoystick(Joystick joystick, ushort keyCode, bool down)
    {
        var wasActive = heldDirections.Count > 0;
        var changed = down ? heldDirections.Add(keyCode) : heldDirections.Remove(keyCode);
        if (!changed) return [];
        var (cx, cy) = Pixel(device, joystick.Center);
        if (heldDirections.Count == 0) return [new TouchPoint(JoystickFingerId, cx, cy, false)];
        double dx = 0, dy = 0;
        if (heldDirections.Contains(MacW)) dy -= 1;
        if (heldDirections.Contains(MacS)) dy += 1;
        if (heldDirections.Contains(MacA)) dx -= 1;
        if (heldDirections.Contains(MacD)) dx += 1;
        var length = Math.Sqrt(dx * dx + dy * dy); // 0 when opposite keys cancel: thumb rests at the center
        var reach = joystick.Radius * device.Width;
        var (x, y) = Clamped(device, length == 0 ? cx : cx + dx / length * reach, length == 0 ? cy : cy + dy / length * reach);
        var thumb = new TouchPoint(JoystickFingerId, x, y, true);
        return wasActive ? [thumb] : [new TouchPoint(JoystickFingerId, cx, cy, true), thumb];
    }

    /// A normalized screen position in device pixels, kept on the screen.
    public static (int X, int Y) Pixel(DeviceSize device, NormalizedPoint p) => Clamped(device, p.X * device.Width, p.Y * device.Height);

    static (int X, int Y) Clamped(DeviceSize device, double x, double y) =>
        ((int)Math.Clamp(x, 0, device.Width - 1), (int)Math.Clamp(y, 0, device.Height - 1));
}
