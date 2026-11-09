using System.IO;

namespace MyEmu;

/// The AVD hardware MyEmu lets you change (Mac: AvdSettings.swift). It lives in the AVD's config.ini,
/// so changes need an engine restart (Android reads it at boot).
public readonly record struct AvdSettings(int Width, int Height, int Density, int CpuCores, int RamMB)
{
    public const int MinSize = 320, MaxSize = 4096, MinDensity = 120, MaxDensity = 640, MinRamMB = 1024;

    public static AvdSettings FromConfig(IReadOnlyDictionary<string, string> config)
    {
        var size = DeviceSize.FromAvdConfig(config);
        return new(size.Width, size.Height,
            Int(config, "hw.lcd.density") ?? 420, Int(config, "hw.cpu.ncore") ?? 2,
            config.TryGetValue("hw.ramSize", out var ram) ? ParseMegabytes(ram) ?? 2048 : 2048);
    }

    public static AvdSettings Read(string avd) => FromConfig(Ini.Parse(File.ReadAllText(Engine.ConfigPath(avd))));

    public void Write(string avd)
    {
        var path = Engine.ConfigPath(avd);
        File.WriteAllText(path, Ini.Update(File.ReadAllText(path), ConfigValues));
    }

    public bool IsLandscape => Width > Height;

    /// The config.ini lines these settings own.
    public IReadOnlyDictionary<string, string> ConfigValues => new Dictionary<string, string>
    {
        ["hw.lcd.width"] = Width.ToString(), ["hw.lcd.height"] = Height.ToString(), ["hw.lcd.density"] = Density.ToString(),
        ["hw.cpu.ncore"] = CpuCores.ToString(), ["hw.ramSize"] = $"{RamMB}M",
        ["hw.initialOrientation"] = IsLandscape ? "landscape" : "portrait",
    };

    /// Null when usable on this PC, otherwise a message for the user.
    public string? Problem(HostLimits host)
    {
        if (Width is < MinSize or > MaxSize || Height is < MinSize or > MaxSize)
            return $"Width and height must be between {MinSize} and {MaxSize}.";
        if (Width % 2 != 0 || Height % 2 != 0) return "Width and height must be even numbers.";
        if (Density is < MinDensity or > MaxDensity) return $"DPI must be between {MinDensity} and {MaxDensity}.";
        if (CpuCores < 1 || CpuCores > host.MaxCpuCores) return $"CPU cores must be between 1 and {host.MaxCpuCores}.";
        if (RamMB < MinRamMB || RamMB > host.MaxRamMB) return $"Memory must be between {MinRamMB / 1024} and {host.MaxRamMB / 1024} GB.";
        return null;
    }

    public AvdSettings With(ResolutionPreset p) => this with { Width = p.Width, Height = p.Height, Density = p.Density };
    public AvdSettings With(PerformancePreset p) => this with { CpuCores = p.CpuCores, RamMB = p.RamMB };
    public AvdSettings Rotated() => this with { Width = Height, Height = Width };

    /// "4G", "228M" or a plain number of megabytes → megabytes.
    public static int? ParseMegabytes(string text)
    {
        var value = text.Trim().ToUpperInvariant();
        if (value.EndsWith('G')) return int.TryParse(value[..^1], out var g) ? g * 1024 : null;
        if (value.EndsWith('M')) value = value[..^1];
        return int.TryParse(value, out var m) ? m : null;
    }

    static int? Int(IReadOnlyDictionary<string, string> config, string key) =>
        config.TryGetValue(key, out var v) && int.TryParse(v, out var i) ? i : null;
}

/// How much of this PC Android may use: every logical core, half the memory (the rest is Windows').
public readonly record struct HostLimits(int MaxCpuCores, int MaxRamMB)
{
    public static readonly HostLimits Current = new(Environment.ProcessorCount,
        (int)(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1024 / 1024 / 2));
}

public sealed record ResolutionPreset(string Name, int Width, int Height, int Density)
{
    /// MuMu-style choices: phone portrait sizes and landscape tablet sizes.
    public static readonly ResolutionPreset[] All =
    [
        new("Phone 1080 × 2400", 1080, 2400, 420),
        new("Phone 1080 × 1920", 1080, 1920, 480),
        new("Phone 900 × 1600", 900, 1600, 320),
        new("Phone 720 × 1280", 720, 1280, 320),
        new("Tablet 2560 × 1440", 2560, 1440, 400),
        new("Tablet 1920 × 1080", 1920, 1080, 280),
        new("Tablet 1600 × 900", 1600, 900, 240),
        new("Tablet 1280 × 720", 1280, 720, 240),
    ];

    /// Every size turned to one orientation (phones and tablets both work either way).
    public static IEnumerable<ResolutionPreset> List(bool landscape) => All.Select(p => p.Oriented(landscape));

    public static ResolutionPreset? Matching(AvdSettings s) =>
        List(s.IsLandscape).FirstOrDefault(p => p.Width == s.Width && p.Height == s.Height && p.Density == s.Density);

    public ResolutionPreset Oriented(bool landscape) => (Width > Height) == landscape ? this
        : new($"{Name.Split(' ')[0]} {Height} × {Width}", Height, Width, Density);
}

public sealed record PerformancePreset(string Name, int CpuCores, int RamMB)
{
    public static readonly PerformancePreset[] All =
    [
        new("Low", 2, 2048), new("Medium", 4, 4096), new("High", 6, 6144), new("Ultra", 8, 8192),
    ];

    public static IEnumerable<PerformancePreset> Available(HostLimits host) =>
        All.Where(p => p.CpuCores <= host.MaxCpuCores && p.RamMB <= host.MaxRamMB);

    /// One Android on this PC: half the logical cores (2–8) and a quarter of the memory (2–8 GB).
    /// ponytail: the Mac counts fast + half the efficiency cores; half the threads gives the same 8 on hybrid Intel.
    public static PerformancePreset Suggested(HostLimits host)
    {
        var cpu = Math.Min(Math.Max(host.MaxCpuCores / 2, 2), Math.Min(8, host.MaxCpuCores));
        var pcGB = (int)Math.Round(host.MaxRamMB * 2 / 1024.0); // Windows reports a little under the installed 32 GB
        var ramGB = Math.Min(Math.Max(pcGB / 4, 2), Math.Min(8, host.MaxRamMB / 1024));
        return new("Suggested", cpu, ramGB * 1024);
    }

    public static PerformancePreset? Matching(AvdSettings s) => All.FirstOrDefault(p => p.CpuCores == s.CpuCores && p.RamMB == s.RamMB);
}
