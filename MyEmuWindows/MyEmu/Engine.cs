using System.Diagnostics;
using System.IO;

namespace MyEmu;

/// A running instance of Google's emulator engine, headless, controlled over gRPC.
public sealed record EngineInstance(int Port, string Token, string Serial, DeviceSize Size, Process Process);

/// Google's emulator engine (QEMU + WHPX + gfxstream). Mirrors the Mac app's Engine.swift.
public static class Engine
{
    static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// The SDK the installer puts next to the app, else Android Studio's.
    public static string Sdk { get; } = new[] { Path.Combine(AppContext.BaseDirectory, "sdk"), Path.Combine(LocalAppData, "Android", "Sdk") }
        .FirstOrDefault(d => File.Exists(Path.Combine(d, "emulator", "emulator.exe"))) ?? Path.Combine(LocalAppData, "Android", "Sdk");

    public static string EmulatorExe => Path.Combine(Sdk, "emulator", "emulator.exe");
    public static string AdbExe => Path.Combine(Sdk, "platform-tools", "adb.exe");
    public static string LogFile => Path.Combine(LocalAppData, "MyEmu", "engine.log");

    /// Where the engine writes pid_<pid>.ini (port, token, ...): %TEMP%\avd\running on Windows.
    static string DiscoveryDir => Path.Combine(Path.GetTempPath(), "avd", "running");

    public static string ConfigPath(string avd) => Path.Combine(Home, ".android", "avd", $"{avd}.avd", "config.ini");

    /// Same flags as the Mac app. Guest ANGLE (Vulkan) vs OpenGL made no fps difference in phase 0.
    public static List<string> Arguments(string avd, int port, int refreshRate, bool guestAngle = false) =>
    [
        "-avd", avd, "-no-window", "-gpu", "host",
        "-feature", guestAngle ? "GuestAngle" : "-GuestAngle",
        "-grpc", port.ToString(), "-grpc-use-token",
        "-vsync-rate", refreshRate.ToString(),
        "-no-boot-anim", "-no-snapshot-save",
    ];

    /// No named device profile (it re-adds a fake camera hole) and the ASG shared-memory graphics transport.
    public static readonly IReadOnlyDictionary<string, string> EnforcedConfig =
        new Dictionary<string, string> { ["hw.device.name"] = "", ["hw.gltransport"] = "asg" };

    public static async Task<EngineInstance> StartAsync(string avd, int port, int refreshRate, CancellationToken cancel = default)
    {
        if (!File.Exists(EmulatorExe)) throw new FileNotFoundException($"Emulator engine not found at {EmulatorExe}.");
        var configPath = ConfigPath(avd);
        if (!File.Exists(configPath)) throw new FileNotFoundException($"Android \"{avd}\" not found ({configPath}).");
        var text = await File.ReadAllTextAsync(configPath, cancel);
        var config = Ini.Parse(text);
        var changes = EnforcedConfig.Where(kv => !config.TryGetValue(kv.Key, out var v) || v != kv.Value)
            .ToDictionary(kv => kv.Key, kv => kv.Value);
        if (changes.Count > 0) await File.WriteAllTextAsync(configPath, Ini.Update(text, changes), cancel);
        var size = DeviceSize.FromAvdConfig(config);

        Directory.CreateDirectory(Path.GetDirectoryName(LogFile)!);
        var log = new StreamWriter(LogFile, append: false) { AutoFlush = true };
        var info = new ProcessStartInfo(EmulatorExe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        foreach (var arg in Arguments(avd, port, refreshRate)) info.ArgumentList.Add(arg);
        var launchedAt = DateTime.Now.AddSeconds(-1); // file times are coarse
        var process = Process.Start(info)!;
        process.StandardInput.Close(); // the engine must not read ours
        process.OutputDataReceived += (_, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        for (var i = 0; i < 120; i++) // up to 60 s
        {
            if (ReadDiscovery(port, launchedAt) is { } values && values.TryGetValue("grpc.token", out var token))
                return new EngineInstance(port, token, $"emulator-{values.GetValueOrDefault("port.serial", "5554")}", size, process);
            if (process.HasExited) throw new InvalidOperationException($"Emulator engine exited during startup (code {process.ExitCode}). Log: {LogFile}");
            await Task.Delay(500, cancel);
        }
        process.Kill(entireProcessTree: true);
        throw new TimeoutException("Emulator engine started but never published its gRPC token.");
    }

    /// Our port's discovery file; ignores stale ones left by crashed runs.
    static Dictionary<string, string>? ReadDiscovery(int port, DateTime newerThan)
    {
        if (!Directory.Exists(DiscoveryDir)) return null;
        foreach (var file in Directory.EnumerateFiles(DiscoveryDir, "*.ini"))
        {
            try
            {
                if (File.GetLastWriteTime(file) < newerThan) continue;
                var values = Ini.Parse(File.ReadAllText(file));
                if (values.GetValueOrDefault("grpc.port") == port.ToString() && !string.IsNullOrEmpty(values.GetValueOrDefault("grpc.token")))
                    return values;
            }
            catch (IOException) { } // being written
        }
        return null;
    }

    /// Asks Android to shut down, then makes sure every engine process is gone.
    public static async Task StopAsync(EngineInstance engine)
    {
        try { await AdbAsync(engine.Serial, ["emu", "kill"]); } catch { } // engine may already be gone
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try { await engine.Process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) { engine.Process.Kill(entireProcessTree: true); }
    }

    /// Runs `command` in Android once it has finished booting; retries while adb is still unauthorized.
    public static async Task AdbShellAfterBootAsync(string serial, string command)
    {
        var script = $"while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done; {command}";
        for (var attempt = 1; ; attempt++)
        {
            try { await AdbAsync(serial, ["wait-for-device", "shell", script]); return; }
            catch when (attempt < 5) { await Task.Delay(2000); }
        }
    }

    public static async Task<string> AdbAsync(string serial, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo(AdbExe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        info.ArgumentList.Add("-s");
        info.ArgumentList.Add(serial);
        foreach (var arg in arguments) info.ArgumentList.Add(arg);
        using var process = Process.Start(info)!;
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var text = await output + await error;
        if (process.ExitCode != 0)
            throw new InvalidOperationException(text.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? $"adb exited with code {process.ExitCode}.");
        return text;
    }
}
