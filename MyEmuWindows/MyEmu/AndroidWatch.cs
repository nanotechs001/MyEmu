using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace MyEmu;

/// Follows which app is in front in Android. Mirrors AndroidWatch.swift (foreground part).
public static class AndroidWatch
{
    /// Event-driven: Android logs one line per app switch. `-T 1` skips old lines.
    public const string ForegroundCommand = "logcat -b events -v raw -T 1 -s wm_set_resumed_activity";
    /// One-shot read of the app already in front (the event stream only reports later switches).
    public const string ForegroundProbe = "dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity";

    /// Android 15 logs each keyboard show/hide *request*; each one only triggers a `TypingProbe`.
    public const string KeyboardEventsCommand = "logcat -v brief -T 1 -s ImeTracker:I";
    /// The input type of the focused editor: a text type whenever a text field has focus. Costly inside
    /// Android, so it runs only after keyboard requests, never on a timer.
    public const string TypingProbe =
        "dumpsys input_method 2>/dev/null | grep -m1 -A1 'mCurrentEditorInfo:' | grep -o 'inputType=0x[0-9a-f]*'";
    /// Android updates the editor a moment after the request; the second look catches slow apps.
    public static readonly TimeSpan[] TypingProbeDelays = [TimeSpan.FromMilliseconds(200), TimeSpan.FromSeconds(1)];

    public static bool IsKeyboardRequest(string line) => line.Contains(": onRequestShow ") || line.Contains(": onRequestHide ");

    /// "inputType=0x100001" → true (a text field has focus); "inputType=0x0" → false; anything else → null.
    public static bool? IsTyping(string text)
    {
        text = text.Trim();
        return text.StartsWith("inputType=0x") && uint.TryParse(text["inputType=0x".Length..], System.Globalization.NumberStyles.HexNumber, null, out var type)
            ? (type & 0xF) != 0 // InputType.TYPE_MASK_CLASS: 0 (TYPE_NULL) when nothing takes text
            : null;
    }

    /// "[0,com.example.game/.MainActivity,reason]" → "com.example.game".
    public static string? ForegroundPackageFromEvent(string line)
    {
        var fields = line.Trim('[', ']', ' ', '\r', '\n').Split(',');
        if (fields.Length < 2) return null;
        var slash = fields[1].IndexOf('/');
        if (slash <= 0) return null;
        var package = fields[1][..slash];
        return IsValidPackage(package) ? package : null;
    }

    /// "…topResumedActivity=ActivityRecord{hash u0 com.example.game/.MainActivity t42}" → "com.example.game".
    public static string? ForegroundPackageFromDump(string text)
    {
        foreach (var field in text.Split([' ', '\t', '{', '}', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var slash = field.IndexOf('/');
            if (slash > 0 && IsValidPackage(field[..slash])) return field[..slash];
        }
        return null;
    }

    /// Android package names: letters, digits, "_" and "." only — safe inside a shell command.
    public static bool IsValidPackage(string name) =>
        name.Length is > 0 and <= 255 && name[0] != '.' && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.');

    /// Lines `command` prints in Android, until it ends or `cancel` fires.
    public static async IAsyncEnumerable<string> Lines(string serial, string command, [EnumeratorCancellation] CancellationToken cancel)
    {
        var info = new ProcessStartInfo(Engine.AdbExe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        foreach (var arg in new[] { "-s", serial, "wait-for-device", "shell", command }) info.ArgumentList.Add(arg);
        using var process = Process.Start(info)!;
        process.StandardInput.Close(); // adb forwards stdin to Android; never share ours
        process.ErrorDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        using var stop = cancel.Register(() => { try { process.Kill(); } catch (InvalidOperationException) { } });
        while (await process.StandardOutput.ReadLineAsync(cancel) is { } line) yield return line;
    }
}
