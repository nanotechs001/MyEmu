using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MyEmu;

/// App-wide Android tweaks, applied at boot and live when changed. Mirrors AndroidOptions.swift; stored
/// in %LOCALAPPDATA%\MyEmu\settings.json instead of UserDefaults.
public sealed class AndroidOptions
{
    // Android's help lists 0.3 as its lowest, but its game mode takes 0.1 (checked on Android 15).
    public static readonly double[] RenderScales = [1.0, 0.9, 0.85, 0.75, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1];
    /// Saves GPU time with a barely softer image (85% measured ≈ 10% less GPU at the same fps on the Mac).
    public const double DefaultRenderScale = 0.85;
    public static readonly int[] FpsChoices = [240, 180, 165, 144, 120, 90, 60, 30];
    public static readonly double[] GameSpeeds = [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 10.0];
    public const int BackgroundFps = 30;
    /// Super Light: games as light as possible, looks don't matter (farming, many instances).
    public const double SuperLightRenderScale = 0.1;
    public const int SuperLightFps = 30;

    /// 0 = the screen's refresh rate.
    public int FpsCap { get; set; }
    public bool LowerFpsWhenMinimized { get; set; } = true;
    public double RenderScale { get; set; } = DefaultRenderScale;
    /// Games draw at 10%, 30 fps, no Android animations, unused apps off; your own settings come back when off.
    public bool SuperLight { get; set; }
    /// Unused Google apps (`Debloat.Packages`) are switched off.
    public bool Lightweight { get; set; } = true;
    /// Android's on-screen keyboard stays hidden; you type on the PC keyboard.
    public bool KeyboardOnly { get; set; } = true;
    /// Games' OpenGL ES runs as Vulkan (ANGLE in Android). Phase 0: same fps as OpenGL, ~half the GPU.
    /// Takes effect when Android next starts.
    public bool GuestAngle { get; set; } = true;
    /// MyEmu and the engine on the dedicated GPU, ahead of other apps (GpuPriority; only with a dedicated GPU).
    public bool GpuPriority { get; set; } = true;
    /// Game keys on (the mapping itself is per game, in keymaps\).
    public bool GameKeysEnabled { get; set; }
    /// The MCP endpoint for AI apps runs (Mac: AIControl, the launcher's "Allow AI control"). Off unless chosen.
    public bool AiControl { get; set; }

    [JsonIgnore] public double EffectiveRenderScale => SuperLight ? SuperLightRenderScale : RenderScale;
    [JsonIgnore] public bool EffectiveLightweight => SuperLight || Lightweight;

    /// The rate Android should render at right now.
    public int AndroidFps(int displayMaxFps, bool minimized) =>
        minimized && LowerFpsWhenMinimized ? Math.Min(BackgroundFps, displayMaxFps)
        : SuperLight ? Math.Min(SuperLightFps, displayMaxFps)
        : FpsCap == 0 ? displayMaxFps : Math.Min(FpsCap, displayMaxFps);

    static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MyEmu", "settings.json");

    /// The one copy every instance window uses (they're app-wide, as on the Mac).
    public static AndroidOptions Shared { get; } = Load();

    public static AndroidOptions Load()
    {
        try
        {
            var options = JsonSerializer.Deserialize<AndroidOptions>(File.ReadAllText(FilePath)) ?? new();
            if (!RenderScales.Contains(options.RenderScale)) options.RenderScale = DefaultRenderScale;
            return options;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); } // none yet or unreadable
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// Android commands for the options, run with adb once Android has booted. Same strings as the Mac app.
public static class AndroidCommands
{
    /// Android's window, transition and animator animations off (0) or back to normal (1).
    public static string Animations(bool on) => string.Join("; ",
        new[] { "window_animation_scale", "transition_animation_scale", "animator_duration_scale" }
            .Select(k => $"settings put global {k} {(on ? 1 : 0)}"));

    /// Hides (or shows again) the on-screen keyboard whenever a hardware keyboard is present.
    public static string KeyboardOnly(bool on) => $"settings put secure show_ime_with_hard_keyboard {(on ? 0 : 1)}";

    /// Switches the unused apps off (`pm disable-user`, reversible) or back on; apps an image lacks are skipped.
    public static string Lightweight(bool on)
    {
        var action = on ? "disable-user --user 0" : "enable --user 0";
        return string.Join("; ", Debloat.Packages.Select(p => $"pm {action} {p} >/dev/null 2>&1")) + "; true";
    }

    /// The guest graphics driver (MESA) logs two lines per frame from the game's render thread.
    public const string QuietGraphicsLog = "setprop log.tag.MESA W";

    /// Apps that insist on portrait are letterboxed instead of turning the whole screen sideways.
    public const string KeepScreenOrientation = "wm set-ignore-orientation-request true; settings put system accelerometer_rotation 0; "
        + "settings put system user_rotation 0; wm set-letterbox-style --backgroundType solid_color --backgroundColor '#000000'";

    /// Android otherwise renders at 60 Hz; a user minimum above that lifts the cap.
    public static string RefreshRate(int rate) => $"settings put system peak_refresh_rate {rate}.0; settings put system min_refresh_rate {rate}.0";

    /// Android 15 holds games at 60 fps (Xerion at 55) unless the game's own game-mode settings say
    /// otherwise, so set its fps and render scale there. Apps Android doesn't treat as games are left alone.
    /// `package` must pass `AndroidWatch.IsValidPackage`.
    public static string GameMode(int fps, double renderScale, string package)
    {
        var scale = renderScale >= 1 ? "disable" : renderScale.ToString("0.00", CultureInfo.InvariantCulture);
        return $"cmd game list-modes {package} | grep -q 'available game modes: \\[[a-z]' && "
            + $"cmd game set --fps {fps} --downscale {scale} {package}; true";
    }

    /// Live speed for the speed bridge (Device.cs, gpu_tls_bridge.c). A game in front becomes the one that's
    /// sped up; other apps leave it alone, so it keeps its speed behind them. Names avoid "myemu"/"speed".
    /// `package` must pass `AndroidWatch.IsValidPackage`.
    public static string GameSpeed(double speed, string package) =>
        $"cmd game list-modes {package} | grep -q 'available game modes: \\[[a-z]' && setprop debug.gpu.tlsp {package}; "
        + $"setprop debug.gpu.tls {speed.ToString("0.00", CultureInfo.InvariantCulture)}";
}

/// Google apps a game emulator doesn't need (Mac measurement: about 640 MB less RAM, nothing broken).
public static class Debloat
{
    public static readonly string[] Packages =
    [
        "com.google.android.apps.wellbeing", "com.google.android.googlequicksearchbox", "com.google.android.apps.messaging",
        "com.google.android.as", "com.google.android.as.oss", "com.google.android.tts", "com.google.android.apps.safetyhub",
        "com.google.android.apps.restore", "com.google.android.marvin.talkback", "com.google.android.apps.wallpaper",
        "com.android.wallpaper.livepicker", "com.google.android.apps.customization.pixel", "com.google.android.dialer",
        "com.google.android.contacts", "com.android.camera2", "com.android.cameraextensions", "com.google.android.calendar",
        "com.google.android.gm", "com.google.android.youtube", "com.google.android.apps.youtube.music",
        "com.google.android.apps.photos", "com.google.android.apps.maps", "com.google.android.apps.docs",
        "com.google.android.deskclock", "com.google.android.projection.gearhead", "com.google.android.feedback",
        "com.android.printspooler", "com.android.bips", "com.android.emergency", "com.android.musicfx",
    ];

    /// Never switched off: Play Store and sign-in, browser, keyboard, launcher, system UI, phone core.
    public static readonly string[] Protected =
    [
        "com.google.android.gms", "com.google.android.gsf", "com.android.vending", "com.android.chrome",
        "com.google.android.webview", "com.google.android.inputmethod.latin", "com.google.android.apps.nexuslauncher",
        "com.android.systemui", "com.android.settings", "com.android.phone", "com.google.android.documentsui",
        "com.google.android.permissioncontroller", "com.google.android.packageinstaller",
        "com.android.providers.contacts", "com.android.providers.calendar",
    ];
}
