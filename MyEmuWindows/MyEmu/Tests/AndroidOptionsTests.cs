using MyEmu;
using Xunit;

/// Same expectations as the Mac's AndroidOptionsTests, so both apps send Android the same commands.
public class AndroidOptionsTests
{
    [Fact]
    public void DebloatNeverTouchesProtectedAppsAndIsShellSafe()
    {
        Assert.Empty(Debloat.Packages.Intersect(Debloat.Protected));
        Assert.Equal(Debloat.Packages.Length, Debloat.Packages.Distinct().Count());
        Assert.All(Debloat.Packages, p => Assert.True(AndroidWatch.IsValidPackage(p)));
        var off = AndroidCommands.Lightweight(true);
        Assert.All(Debloat.Packages, p => Assert.Contains($"pm disable-user --user 0 {p} ", off));
        Assert.EndsWith("; true", off);
        Assert.Contains("pm enable --user 0 com.android.musicfx ", AndroidCommands.Lightweight(false));
    }

    [Fact]
    public void CommandsMatchTheMacApp()
    {
        Assert.Equal("settings put secure show_ime_with_hard_keyboard 0", AndroidCommands.KeyboardOnly(true));
        Assert.Equal("cmd game list-modes com.Tq.CQ2ClientAndroid | grep -q 'available game modes: \\[[a-z]' && cmd game set --fps 180 --downscale 0.85 com.Tq.CQ2ClientAndroid; true",
            AndroidCommands.GameMode(180, 0.85, "com.Tq.CQ2ClientAndroid"));
        Assert.Contains("--downscale disable", AndroidCommands.GameMode(60, 1, "a.b"));
        Assert.Contains("--fps 60 --downscale 0.10 a.b", AndroidCommands.GameMode(60, 0.1, "a.b"));
        Assert.Equal("settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0",
            AndroidCommands.Animations(false));
        Assert.Contains(AndroidOptions.SuperLightRenderScale, AndroidOptions.RenderScales);
    }

    [Fact]
    public void AndroidFpsFollowsMinimizedThenSuperLightThenCap()
    {
        var o = new AndroidOptions { FpsCap = 0 };
        Assert.Equal(165, o.AndroidFps(165, minimized: false));
        o.FpsCap = 90;
        Assert.Equal(90, o.AndroidFps(165, false));
        Assert.Equal(60, o.AndroidFps(60, false)); // never above the screen
        Assert.Equal(30, o.AndroidFps(165, minimized: true));
        o.LowerFpsWhenMinimized = false;
        Assert.Equal(90, o.AndroidFps(165, true));
        o.SuperLight = true;
        Assert.Equal(30, o.AndroidFps(165, false));
        Assert.Equal(0.1, o.EffectiveRenderScale);
        Assert.True(o.EffectiveLightweight);
    }

    [Fact]
    public void ForegroundParsing()
    {
        Assert.Equal("com.com.Xerion", AndroidWatch.ForegroundPackageFromEvent("[0,com.com.Xerion/com.com.Xerion.CQ2ClientActivity,resumeTopActivity]"));
        Assert.Equal("com.com.Xerion", AndroidWatch.ForegroundPackageFromDump(
            "  topResumedActivity=ActivityRecord{56a7da4 u0 com.com.Xerion/.CQ2ClientActivity t12}"));
        Assert.Null(AndroidWatch.ForegroundPackageFromEvent("garbage"));
        Assert.False(AndroidWatch.IsValidPackage("a.b; rm -rf /"));
    }
}
