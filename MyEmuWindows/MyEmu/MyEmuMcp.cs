using System.Collections.Concurrent;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace MyEmu;

/// One instance as the MCP tools see it (read on the UI thread). Running: its window is open.
public sealed record McpInstanceState(string Id, string Name, bool Running, string? Serial, string Status, string? ForegroundApp,
    DeviceProfile Profile = DeviceProfile.PlayStore, double GameSpeed = 1.0);

/// What an AI can do over MCP (Mac: MyEmuMCP.swift): what you do in MyEmu's windows — start and stop
/// Androids, look at a screen, tap, swipe, type, press keys and open apps.
public sealed class MyEmuMcp(Func<Task<IReadOnlyList<McpInstanceState>>> instances, Func<string, Task<string>> start,
    Func<string, Task<string>> stop, Func<string, (byte[] Rgba, int Width, int Height)?> screen,
    Func<string, double, Task<string>>? setSpeed = null)
{
    /// Screenshots are scaled to fit this, small enough for an AI to read quickly.
    public const int MaxScreenshotSide = 1280;
    const double DefaultLongPressMs = 800, DefaultSwipeMs = 300, MaxGestureMs = 10_000;
    const int MaxTextLength = 1000;

    /// Each instance's last screenshot scale (image pixels per screen pixel): taps use the coordinates the AI saw.
    readonly ConcurrentDictionary<string, double> screenshotScale = new();

    public McpDispatcher Dispatcher => new("MyEmu", typeof(MyEmuMcp).Assembly.GetName().Version?.ToString(3) ?? "dev",
        Instructions, Tools, CallAsync);

    const string Instructions =
        "Controls MyEmu, an Android emulator on this PC, the way a person uses its windows. " +
        "Call list_instances first. Start an instance and poll list_instances until it's ready. " +
        "Take a screenshot to see the screen, then tap, long_press or swipe using that screenshot's " +
        "pixel coordinates, and take a new screenshot to check what happened.";

    // --- Tools

    static JsonObject Number(string description) => new() { ["type"] = "number", ["description"] = description };

    static McpTool Tool(string name, string description, JsonObject? properties = null, string[]? required = null) =>
        new(name, description, new JsonObject
        {
            ["type"] = "object", ["properties"] = properties ?? [],
            ["required"] = new JsonArray((required ?? []).Select(r => (JsonNode)r).ToArray()),
        });

    static McpTool OnInstance(string name, string description, JsonObject? properties = null, string[]? required = null)
    {
        properties ??= [];
        properties["instance"] = new JsonObject { ["type"] = "string", ["description"] = "Instance id or name, from list_instances" };
        return Tool(name, description, properties, ["instance", .. required ?? []]);
    }

    /// Android key names the press_key tool takes, and their key codes.
    public static readonly IReadOnlyDictionary<string, string> Keys = new Dictionary<string, string>
    {
        ["back"] = "KEYCODE_BACK", ["home"] = "KEYCODE_HOME", ["recents"] = "KEYCODE_APP_SWITCH", ["enter"] = "KEYCODE_ENTER",
        ["delete"] = "KEYCODE_DEL", ["tab"] = "KEYCODE_TAB", ["escape"] = "KEYCODE_ESCAPE", ["space"] = "KEYCODE_SPACE",
        ["up"] = "KEYCODE_DPAD_UP", ["down"] = "KEYCODE_DPAD_DOWN", ["left"] = "KEYCODE_DPAD_LEFT", ["right"] = "KEYCODE_DPAD_RIGHT",
        ["volume_up"] = "KEYCODE_VOLUME_UP", ["volume_down"] = "KEYCODE_VOLUME_DOWN",
    };

    public static readonly McpTool[] Tools =
    [
        Tool("list_instances", "Every Android in MyEmu: id, name, profile, game speed, whether it's running and ready, and for running ones their status and app in front."),
        OnInstance("start_instance", "Starts an instance (opens its window, or starts its Android if the window is open). Android takes a minute or so: poll list_instances until ready is true."),
        OnInstance("stop_instance", "Shuts an instance's Android down (its window stays open)."),
        OnInstance("screenshot", "The instance's screen as an image. tap, long_press and swipe take x/y in this image's pixels."),
        OnInstance("tap", "Taps the screen at x, y (pixels of the latest screenshot).",
            new() { ["x"] = Number("Pixels from the left"), ["y"] = Number("Pixels from the top") }, ["x", "y"]),
        OnInstance("long_press", "Touches and holds at x, y (pixels of the latest screenshot).",
            new() { ["x"] = Number("Pixels from the left"), ["y"] = Number("Pixels from the top"), ["duration_ms"] = Number("How long to hold; default 800") }, ["x", "y"]),
        OnInstance("swipe", "Drags a finger from x1, y1 to x2, y2 (pixels of the latest screenshot). Swipe up to scroll down.",
            new()
            {
                ["x1"] = Number("Start, from the left"), ["y1"] = Number("Start, from the top"),
                ["x2"] = Number("End, from the left"), ["y2"] = Number("End, from the top"),
                ["duration_ms"] = Number("How long the drag takes; default 300"),
            }, ["x1", "y1", "x2", "y2"]),
        OnInstance("type_text", "Types text into the focused text field (tap it first). ASCII only, one line; use press_key enter to submit.",
            new() { ["text"] = new JsonObject { ["type"] = "string" } }, ["text"]),
        OnInstance("press_key", "Presses an Android key, e.g. back or home.",
            new() { ["key"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray(Keys.Keys.Order(StringComparer.Ordinal).Select(k => (JsonNode)k).ToArray()) } }, ["key"]),
        OnInstance("list_apps", "Apps installed on the instance (package names), for launch_app.",
            new() { ["include_system"] = new JsonObject { ["type"] = "boolean", ["description"] = "Also list Android's own apps; default false" } }),
        OnInstance("launch_app", "Opens an app by its package name.", new() { ["package"] = new JsonObject { ["type"] = "string" } }, ["package"]),
        OnInstance("set_game_speed", "Sets how fast games run on this instance (Custom model profile only). Applies live to the game in front.",
            new() { ["speed"] = new JsonObject { ["type"] = "number", ["enum"] = new JsonArray(AndroidOptions.GameSpeeds.Select(s => (JsonNode)s).ToArray()) } }, ["speed"]),
    ];

    async Task<IReadOnlyList<McpContent>> CallAsync(string name, JsonObject arguments)
    {
        switch (name)
        {
            case "list_instances": return [new McpText(await ListInstancesAsync())];
            case "start_instance": return [new McpText(await start((await InstanceAsync(arguments)).Id))];
            case "stop_instance":
            {
                var instance = await InstanceAsync(arguments);
                screenshotScale.TryRemove(instance.Id, out _);
                return [new McpText(await stop(instance.Id))];
            }
            case "screenshot": return await ScreenshotAsync(arguments);
            case "tap":
            {
                var (instance, serial) = await ReadyAsync(arguments);
                var (x, y) = Point(arguments, "x", "y", instance);
                return [new McpText(await ShellAsync(serial, $"input tap {x} {y}", $"Tapped {x}, {y} on screen."))];
            }
            case "long_press":
            {
                var (instance, serial) = await ReadyAsync(arguments);
                var (x, y) = Point(arguments, "x", "y", instance);
                var ms = Duration(arguments, DefaultLongPressMs);
                return [new McpText(await ShellAsync(serial, $"input swipe {x} {y} {x} {y} {ms}", $"Held {x}, {y} for {ms} ms."))];
            }
            case "swipe":
            {
                var (instance, serial) = await ReadyAsync(arguments);
                var (x1, y1) = Point(arguments, "x1", "y1", instance);
                var (x2, y2) = Point(arguments, "x2", "y2", instance);
                var ms = Duration(arguments, DefaultSwipeMs);
                return [new McpText(await ShellAsync(serial, $"input swipe {x1} {y1} {x2} {y2} {ms}", "Swiped."))];
            }
            case "type_text":
            {
                var (_, serial) = await ReadyAsync(arguments);
                return [new McpText(await ShellAsync(serial, InputTextCommand(Str(arguments, "text") ?? ""), "Typed."))];
            }
            case "press_key":
            {
                var (_, serial) = await ReadyAsync(arguments);
                if (Str(arguments, "key") is not { } key || !Keys.TryGetValue(key, out var code))
                    throw new McpToolError($"key must be one of: {string.Join(", ", Keys.Keys.Order(StringComparer.Ordinal))}.");
                return [new McpText(await ShellAsync(serial, $"input keyevent {code}", $"Pressed {key}."))];
            }
            case "list_apps": return [new McpText(await ListAppsAsync(arguments))];
            case "launch_app": return [new McpText(await LaunchAppAsync(arguments))];
            case "set_game_speed":
            {
                var instance = await InstanceAsync(arguments);
                if (instance.Profile != DeviceProfile.CustomModel)
                    throw new McpToolError($"Game speed needs the Custom model profile; {instance.Name} runs {instance.Profile.Title()}.");
                if (arguments["speed"] is not JsonValue v || !v.TryGetValue(out double speed) || !AndroidOptions.GameSpeeds.Contains(speed))
                    throw new McpToolError($"speed must be one of {string.Join(", ", AndroidOptions.GameSpeeds)}.");
                if (setSpeed == null) throw new McpUnknownTool(name);
                return [new McpText(await setSpeed(instance.Id, speed))];
            }
            default: throw new McpUnknownTool(name);
        }
    }

    // --- Instances

    async Task<string> ListInstancesAsync()
    {
        var rows = new JsonArray();
        foreach (var s in await instances())
        {
            var row = new JsonObject { ["id"] = s.Id, ["name"] = s.Name, ["running"] = s.Running, ["profile"] = s.Profile.Title(), ["gameSpeed"] = s.GameSpeed };
            row["ready"] = s.Running && s.Serial != null && await IsBootedAsync(s.Serial);
            if (s.Running)
            {
                row["status"] = s.Status;
                if (s.ForegroundApp != null) row["foregroundApp"] = s.ForegroundApp;
            }
            rows.Add(row);
        }
        return rows.ToJsonString(McpDispatcher.Json);
    }

    static async Task<bool> IsBootedAsync(string serial)
    {
        try { return (await Engine.AdbAsync(serial, ["shell", "getprop sys.boot_completed"])).Trim() == "1"; }
        catch { return false; } // adb not up yet
    }

    /// The instance named by `instance` (an id, or a name in any case).
    async Task<McpInstanceState> InstanceAsync(JsonObject arguments)
    {
        if (Str(arguments, "instance") is not { } key) throw new McpToolError("Pass instance: an id or name from list_instances.");
        var all = await instances();
        return all.FirstOrDefault(i => i.Id == key) ?? all.FirstOrDefault(i => i.Name.Equals(key, StringComparison.OrdinalIgnoreCase))
            ?? throw new McpToolError($"No instance \"{key}\". Call list_instances for the ids.");
    }

    /// A running instance whose Android has finished starting, with its adb serial.
    async Task<(McpInstanceState Instance, string Serial)> ReadyAsync(JsonObject arguments)
    {
        var s = await InstanceAsync(arguments);
        if (!s.Running) throw new McpToolError($"{s.Name} isn't running. Call start_instance first.");
        if (s.Serial == null || !await IsBootedAsync(s.Serial)) throw new McpToolError($"{s.Name} is still starting ({s.Status}). Try again in a few seconds.");
        return (s, s.Serial);
    }

    // --- Screen and input

    async Task<IReadOnlyList<McpContent>> ScreenshotAsync(JsonObject arguments)
    {
        var (instance, _) = await ReadyAsync(arguments);
        if (screen(instance.Id) is not { } frame) throw new McpToolError("No frame from Android yet. Try again in a second.");
        var shot = Screenshot.FromRgba(frame.Rgba, frame.Width, frame.Height, MaxScreenshotSide);
        screenshotScale[instance.Id] = shot.Scale;
        return [new McpImage(shot.Jpeg, "image/jpeg"),
            new McpText($"{instance.Name}: a {shot.Width}×{shot.Height} image of its {frame.Width}×{frame.Height} screen. Give tap, long_press and swipe this image's pixel coordinates.")];
    }

    /// Screen pixels for x/y given in the latest screenshot's pixels.
    (int X, int Y) Point(JsonObject arguments, string xKey, string yKey, McpInstanceState instance)
    {
        if (Num(arguments, xKey) is not { } x || Num(arguments, yKey) is not { } y || x < 0 || y < 0)
            throw new McpToolError($"{xKey} and {yKey} must be numbers of 0 or more.");
        var scale = screenshotScale.GetValueOrDefault(instance.Id, 1); // no screenshot yet: screen pixels
        return ((int)Math.Round(x / scale), (int)Math.Round(y / scale));
    }

    static int Duration(JsonObject arguments, double fallback)
    {
        var ms = arguments.ContainsKey("duration_ms") ? Num(arguments, "duration_ms") : fallback;
        if (ms is not { } value || value < 1 || value > MaxGestureMs) throw new McpToolError($"duration_ms must be between 1 and {MaxGestureMs}.");
        return (int)value;
    }

    /// Android's `input text`, quoted for its shell. Spaces become %s, which is how it types a space.
    public static string InputTextCommand(string text)
    {
        if (text.Length is 0 or > MaxTextLength) throw new McpToolError($"text must be 1 to {MaxTextLength} characters.");
        if (text.Any(c => c < 0x20 || c >= 0x7F))
            throw new McpToolError("type_text takes plain ASCII on one line (Android's input command can't type other characters). Use press_key enter for a new line.");
        return $"input text '{text.Replace(" ", "%s").Replace("'", "'\\''")}'";
    }

    static async Task<string> ShellAsync(string serial, string command, string done)
    {
        await Engine.AdbAsync(serial, ["shell", command]);
        return done;
    }

    // --- Apps

    async Task<string> ListAppsAsync(JsonObject arguments)
    {
        var (_, serial) = await ReadyAsync(arguments);
        var flag = arguments["include_system"]?.GetValueKind() == JsonValueKind.True ? "" : " -3"; // -3: apps you installed
        var output = await Engine.AdbAsync(serial, ["shell", $"pm list packages{flag}"]);
        var packages = output.Split('\n', '\r').Where(l => l.StartsWith("package:")).Select(l => l["package:".Length..].Trim()).Order(StringComparer.Ordinal).ToList();
        return packages.Count == 0 ? "No apps found." : string.Join("\n", packages);
    }

    async Task<string> LaunchAppAsync(JsonObject arguments)
    {
        var (_, serial) = await ReadyAsync(arguments);
        if (Str(arguments, "package") is not { } package || !AndroidWatch.IsValidPackage(package))
            throw new McpToolError("package must be an Android package name, e.g. com.android.settings (see list_apps).");
        var output = await Engine.AdbAsync(serial, ["shell", $"monkey -p {package} -c android.intent.category.LAUNCHER 1"]);
        if (output.Contains("No activities found")) throw new McpToolError($"{package} isn't installed or has nothing to open.");
        return $"Opened {package}.";
    }

    static string? Str(JsonObject o, string key) => o[key]?.GetValueKind() == JsonValueKind.String ? (string)o[key]! : null;
    static double? Num(JsonObject o, string key) => o[key]?.GetValueKind() == JsonValueKind.Number ? (double)o[key]! : null;
}

/// A screen frame scaled down for an AI to read, with the scale to map its coordinates back.
public sealed record Screenshot(byte[] Jpeg, int Width, int Height, double Scale)
{
    public static Screenshot FromRgba(byte[] rgba, int width, int height, int maxSide)
    {
        var bgra = new byte[width * height * 4];
        for (var i = 0; i < bgra.Length; i += 4)
            (bgra[i], bgra[i + 1], bgra[i + 2], bgra[i + 3]) = (rgba[i + 2], rgba[i + 1], rgba[i], 255);
        BitmapSource image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, bgra, width * 4);
        var scale = Math.Min(1.0, (double)maxSide / Math.Max(width, height)); // never enlarged
        if (scale < 1) image = new TransformedBitmap(image, new ScaleTransform(scale, scale));
        var encoder = new JpegBitmapEncoder { QualityLevel = 75 };
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var output = new MemoryStream();
        encoder.Save(output);
        return new(output.ToArray(), image.PixelWidth, image.PixelHeight, (double)image.PixelWidth / width);
    }
}
