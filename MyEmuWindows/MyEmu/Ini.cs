namespace MyEmu;

/// `key=value` files: AVD config.ini and the engine's discovery files. Same rules as the Mac app.
public static class Ini
{
    public static Dictionary<string, string> Parse(string text)
    {
        var values = new Dictionary<string, string>();
        foreach (var line in text.Split('\n', '\r'))
        {
            var i = line.IndexOf('=');
            if (i <= 0) continue;
            values[line[..i].Trim()] = line[(i + 1)..].Trim();
        }
        return values;
    }

    /// Rewrites `key=value` lines in place, appends missing keys, and leaves every other line alone.
    public static string Update(string text, IReadOnlyDictionary<string, string> values)
    {
        var remaining = new Dictionary<string, string>(values);
        var lines = text.Replace("\r\n", "\n").Split('\n').Select(line =>
        {
            var i = line.IndexOf('=');
            var key = i > 0 ? line[..i].Trim() : null;
            return key != null && remaining.Remove(key, out var value) ? $"{key}={value}" : line;
        }).ToList();
        if (lines.Count > 0 && lines[^1] == "") lines.RemoveAt(lines.Count - 1);
        lines.AddRange(remaining.Keys.Order(StringComparer.Ordinal).Select(k => $"{k}={remaining[k]}"));
        return string.Join("\n", lines) + "\n";
    }
}

public readonly record struct DeviceSize(int Width, int Height)
{
    public static DeviceSize FromAvdConfig(IReadOnlyDictionary<string, string> config) =>
        config.TryGetValue("hw.lcd.width", out var w) && config.TryGetValue("hw.lcd.height", out var h)
        && int.TryParse(w, out var width) && int.TryParse(h, out var height) && width > 0 && height > 0
            ? new DeviceSize(width, height)
            : throw new System.IO.InvalidDataException("The AVD's config.ini has no screen size (hw.lcd.width/height).");
}
