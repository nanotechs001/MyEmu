// Ports of the Mac app's AutoPotsRulesTests.swift (the parts that aren't macOS-specific).
using System.IO;
using MyEmu.AutoPots;
using Xunit;

namespace MyEmu.AutoPots.Tests;

public class RulesTests
{
    [Fact]
    public void BurstTiming()
    {
        Assert.Equal(1, AutoPotsRules.PressMs(0)); // "instant" is the shortest real press
        Assert.Equal(2000, AutoPotsRules.PressMs(5000));
        Assert.Equal(1, AutoPotsRules.BurstBusyMs(count: 1, pressMs: 1));
        Assert.Equal(2 * 11 + 10 + 90, AutoPotsRules.BurstBusyMs(count: 3, pressMs: 10)); // gaps + last press + settle
    }

    [Fact]
    public void StuckGuardStopsFutileTapsAndResumesWhenHPMoves()
    {
        var guard = new StuckGuard();
        bool Stuck(float reading, long ms, bool tapping = true) => guard.IsStuck(reading, ms, tapping);
        bool notTapping = Stuck(0.5f, 0, tapping: false); // not tapping yet: no baseline
        bool firstTap = Stuck(0.5f, 0);                    // the first tap sets the baseline
        bool justBefore = Stuck(0.52f, 2999);
        bool atWindow = Stuck(0.51f, 3000);
        bool moved = Stuck(0.6f, 3100);                    // moved: the taps work
        Assert.True(!notTapping && !firstTap && !justBefore && atWindow && !moved);
        guard.Reset();
        Assert.False(Stuck(0.6f, 10_000));
    }

    [Fact]
    public void ReadoutTellsFullFromNotFull()
    {
        Assert.Equal("HP 100%", AutoPotsRules.Readout(0.95f, GameView.Orb));
        Assert.Equal("HP not full", AutoPotsRules.Readout(0.5f, GameView.Orb));
        Assert.Equal("HP 85%", AutoPotsRules.Readout(0.85f, GameView.Simple));
        Assert.Equal("HP 0%", AutoPotsRules.Readout(0.2f, GameView.Simple));
    }

    [Fact]
    public void SettingsRoundTripAndReportCalibration()
    {
        var s = new AutoPotsSettings();
        Assert.False(s.IsCalibrated);
        s.OrbBox = new PixelRect(587, 599, 44, 92);
        s.OrbPotion = new PixelPoint(553, 668);
        Assert.True(s.IsCalibrated);
        Assert.Equal(new PixelPoint(553, 668), s.Potion);
        s.View = GameView.Simple;
        Assert.False(s.IsCalibrated); // simple view needs its own box, potion and template
        s.SimpleBox = new PixelRect(91, 6, 51, 16);
        s.SimplePotion = new PixelPoint(139, 83);
        s.SimpleSignature = "2:0121";
        Assert.True(s.IsCalibrated);

        var path = Path.Combine(Path.GetTempPath(), $"autopots-test-{Guid.NewGuid()}.json");
        try
        {
            s.Save(path);
            Assert.Equal(s, AutoPotsSettings.Load(path));
            Assert.Equal(new AutoPotsSettings(), AutoPotsSettings.Load(path + ".missing"));
            // The Mac app's field names, so a game's file is the same on both.
            var json = File.ReadAllText(path);
            Assert.Contains("\"view\": \"simple\"", json);
            Assert.Contains("\"orbBox\"", json);
            Assert.Contains("\"width\": 44", json);
        }
        finally { File.Delete(path); }
    }
}
