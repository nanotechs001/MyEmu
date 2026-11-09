using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MyEmu;

/// One Android you can run in its own window, with its own apps and data (Mac: Instances.swift).
/// Instance 1 is the original MyEmu setup and keeps its AVD.
public sealed record Instance(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    /// Fixed for the instance's life: picks its AVD and gRPC port.
    [property: JsonPropertyName("number")] int Number)
{
    public static readonly Instance Main = new("main", "Android 1", 1);
    const int BaseGrpcPort = 8554;

    /// Instance 1 keeps the original AVD name; the others get a suffix (the Mac's Play Store profile names).
    [JsonIgnore] public string Avd => Number == 1 ? "myemu" : $"myemu-{Number}";
    /// Two apart, like the engine's own console/adb port pairs.
    [JsonIgnore] public int GrpcPort => BaseGrpcPort + (Number - 1) * 2;
}

/// Every instance, in %LOCALAPPDATA%\MyEmu\instances.json (the Mac's InstanceList JSON).
public sealed class InstanceList
{
    /// Each one is a full Android with its own CPU, memory and several GB of disk.
    public const int MaxCount = 8, MaxNameLength = 40;

    [JsonPropertyName("instances")] public List<Instance> Instances { get; set; } = [Instance.Main];

    [JsonIgnore] public bool CanAdd => Instances.Count < MaxCount;

    public Instance? Find(string id) => Instances.FirstOrDefault(i => i.Id == id);

    /// Adds "Android <n>" (or `name`) with the next unused number; null at the limit.
    public Instance? Add(string? name = null)
    {
        if (!CanAdd) return null;
        var number = Instances.Max(i => i.Number) + 1;
        var instance = new Instance(Guid.NewGuid().ToString().ToUpperInvariant(), Clip(name) ?? $"Android {number}", number);
        Instances.Add(instance);
        return instance;
    }

    /// Instance 1 can't be removed.
    public void Remove(string id) => Instances.RemoveAll(i => i.Id == id && i.Number != 1);

    public void Rename(string id, string name)
    {
        var index = Instances.FindIndex(i => i.Id == id);
        if (Clip(name?.Trim()) is { Length: > 0 } trimmed && index >= 0) Instances[index] = Instances[index] with { Name = trimmed };
    }

    static string? Clip(string? name) => name is null ? null : name[..Math.Min(name.Length, MaxNameLength)];

    public static string FilePath { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MyEmu", "instances.json");

    public static InstanceList Load()
    {
        try
        {
            var list = JsonSerializer.Deserialize<InstanceList>(File.ReadAllText(FilePath));
            if (list != null && list.Instances.Any(i => i.Number == 1)) return list;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { } // none yet or unreadable
        return new(); // just instance 1
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
    }
}

/// An instance's AVD on disk (Mac: Engine+Device.swift's cloneAvd/ensureAvd/deleteAvd).
public static class AvdFiles
{
    public static string Root { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".android", "avd");

    /// Run-time files the engine recreates; the dead RAM snapshot (MyEmu never saves one) is GBs.
    static readonly string[] Skipped = ["snapshots", "tmpAdbCmds", "hardware-qemu.ini", "emu-launch-params.txt", "bootcompleted.ini"];

    static string Dir(string avd) => Path.Combine(Root, $"{avd}.avd");
    static string IniPath(string avd) => Path.Combine(Root, $"{avd}.ini");

    public static bool Exists(string avd) => File.Exists(IniPath(avd));

    static void WriteIni(string avd) =>
        File.WriteAllText(IniPath(avd), $"avd.ini.encoding=UTF-8\npath={Dir(avd)}\npath.rel=avd\\{avd}.avd\ntarget=android-35\n");

    /// The first Android on a new PC: the Play Store image, as phase 0 tested it (size, CPU and memory
    /// are then set by Ensure). No `hw.device.name`: the engine strips it anyway (Engine.EnforcedConfig).
    public const string DefaultConfig = """
        PlayStore.enabled=yes
        abi.type=x86_64
        avd.ini.encoding=UTF-8
        disk.dataPartition.size=16G
        hw.audioInput=yes
        hw.audioOutput=yes
        hw.cpu.arch=x86_64
        hw.cpu.ncore=4
        hw.device.manufacturer=Google
        hw.gltransport=asg
        hw.gpu.enabled=yes
        hw.gpu.mode=host
        hw.initialOrientation=landscape
        hw.keyboard=yes
        hw.lcd.density=240
        hw.lcd.height=900
        hw.lcd.width=1600
        hw.ramSize=4096
        image.sysdir.1=system-images\android-35\google_apis_playstore\x86_64\
        showDeviceFrame=no
        tag.id=google_apis_playstore
        tag.ids=google_apis_playstore
        target=android-35

        """;

    /// Creates `avd` the first time from `templateAvd`'s config (same image; DefaultConfig on a new PC),
    /// in landscape with CPU and memory suggested for this PC. Android's data starts fresh on its first boot.
    public static void Ensure(string avd, string templateAvd, IReadOnlyDictionary<string, string>? imageConfig = null)
    {
        if (Exists(avd)) return;
        Directory.CreateDirectory(Dir(avd));
        var template = Path.Combine(Dir(templateAvd), "config.ini");
        var config = File.Exists(template) ? File.ReadAllText(template) : DefaultConfig;
        var s = AvdSettings.FromConfig(Ini.Parse(config));
        s = (s.IsLandscape ? s : s.Rotated()).With(PerformancePreset.Suggested(HostLimits.Current));
        var values = new Dictionary<string, string>(s.ConfigValues);
        foreach (var (key, value) in imageConfig ?? new Dictionary<string, string>()) values[key] = value; // the profile's image
        File.WriteAllText(Path.Combine(Dir(avd), "config.ini"), Ini.Update(config, values));
        WriteIni(avd);
    }

    /// Copies a stopped AVD, Android data included, under a new name. A plain copy (NTFS has no
    /// clones), so it takes as long as copying its data. A source never created is skipped (false).
    public static async Task<bool> CloneAsync(string source, string target)
    {
        if (!Directory.Exists(Dir(source))) return false;
        if (Directory.Exists(Dir(target)) || File.Exists(IniPath(target))) throw new IOException($"{target} already exists.");
        await Task.Run(() => Copy(Dir(source), Dir(target), top: true));
        WriteIni(target);
        return true;
    }

    static void Copy(string from, string to, bool top)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.EnumerateFiles(from))
        {
            var name = Path.GetFileName(file);
            if (name.EndsWith(".lock") || top && Skipped.Contains(name)) continue; // locks belong to the original's runs
            File.Copy(file, Path.Combine(to, name));
        }
        foreach (var dir in Directory.EnumerateDirectories(from))
        {
            var name = Path.GetFileName(dir);
            if (name.EndsWith(".lock") || top && Skipped.Contains(name)) continue;
            Copy(dir, Path.Combine(to, name), top: false);
        }
    }

    /// Deletes an AVD and all its Android data. Missing AVDs are fine.
    public static void Delete(string avd)
    {
        if (Directory.Exists(Dir(avd)))
        {
            // Android's data has read-only files (data\misc\pstore\pstore.bin), which Directory.Delete refuses.
            foreach (var file in Directory.EnumerateFiles(Dir(avd), "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(Dir(avd), recursive: true);
        }
        if (File.Exists(IniPath(avd))) File.Delete(IniPath(avd));
    }
}
