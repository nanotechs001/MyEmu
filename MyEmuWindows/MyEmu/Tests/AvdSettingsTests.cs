using MyEmu;
using Xunit;

public class AvdSettingsTests
{
    static readonly HostLimits Host = new(20, 16 * 1024);

    [Fact]
    public void ReadsAndWritesTheAvdConfig()
    {
        var config = Ini.Parse("hw.lcd.width=1600\nhw.lcd.height=900\nhw.lcd.density=240\nhw.cpu.ncore=4\nhw.ramSize=4G\n");
        var s = AvdSettings.FromConfig(config);
        Assert.Equal(new AvdSettings(1600, 900, 240, 4, 4096), s);
        var rotated = s.Rotated();
        var written = Ini.Parse(Ini.Update("hw.gltransport=asg\nhw.ramSize=4G\n", rotated.ConfigValues));
        Assert.Equal("4096M", written["hw.ramSize"]);
        Assert.Equal("portrait", written["hw.initialOrientation"]);
        Assert.Equal("asg", written["hw.gltransport"]); // other lines stay
        Assert.Equal(rotated, AvdSettings.FromConfig(written));
    }

    [Fact]
    public void PresetsMatchAndProblemsAreCaught()
    {
        var s = new AvdSettings(1600, 900, 240, 4, 4096);
        Assert.Equal("Tablet 1600 × 900", ResolutionPreset.Matching(s)?.Name);
        Assert.Equal("Phone 1600 × 900", ResolutionPreset.Matching(s with { Density = 320 })?.Name); // phone turned landscape
        Assert.Equal("Medium", PerformancePreset.Matching(s)?.Name);
        Assert.Null(s.Problem(Host));
        Assert.NotNull((s with { Width = 1601 }).Problem(Host));
        Assert.NotNull((s with { CpuCores = 21 }).Problem(Host));
        Assert.NotNull((s with { RamMB = 17 * 1024 }).Problem(Host));
        Assert.Equal(new PerformancePreset("Suggested", 8, 8192), PerformancePreset.Suggested(Host)); // 20 threads, 32 GB
        Assert.Equal(8192, PerformancePreset.Suggested(new HostLimits(20, 16200)).RamMB); // Windows' 31.6 GB
    }
}
