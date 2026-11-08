using System.IO;
using MyEmu;
using MyEmu.AutoPots;
using Xunit;

public class AutoPotsTests
{
    [Fact]
    public void RgbaFrameReadsTopDownRgb()
    {
        var pixels = new byte[2 * 2 * 4];
        pixels[(1 * 2 + 0) * 4 + 0] = 0x12; // (0, 1): R
        pixels[(1 * 2 + 0) * 4 + 1] = 0x34; //         G
        pixels[(1 * 2 + 0) * 4 + 2] = 0x56; //         B
        var frame = new RgbaFrame(pixels, 2, 2);
        Assert.Equal(0x123456, frame.Rgb(0, 1));
        Assert.Equal(0, frame.Rgb(1, 1));
    }

    [Fact]
    public void AdjustingMovesTheBoxAndPlacesThePotion()
    {
        var package = "test.myemu.autopots" + Guid.NewGuid().ToString("N");
        using var pots = new AutoPotsController(() => null, () => null, (_, _, _) => { });
        try
        {
            pots.AppDidChange(package);
            pots.Update(s => s with { OrbBox = new PixelRect(100, 100, 50, 50) });
            pots.PressAt(new PixelPoint(10, 10)); // not adjusting: ignored
            Assert.Null(pots.Settings.OrbPotion);
            pots.SetAdjusting(true);
            pots.PressAt(new PixelPoint(120, 120)); // inside the box: drag
            pots.DragTo(new PixelPoint(130, 125));
            Assert.Equal(new PixelRect(110, 105, 50, 50), pots.Box);
            pots.Release();
            Assert.Equal(new PixelRect(110, 105, 50, 50), pots.Settings.OrbBox);
            pots.PressAt(new PixelPoint(400, 300)); // outside: the potion
            Assert.Equal(new PixelPoint(400, 300), pots.Settings.OrbPotion);
            Assert.True(pots.Settings.IsCalibrated);
            Assert.True(AutoPotsSettings.Load(AutoPotsSettings.FilePath(package)).IsCalibrated); // saved per game
        }
        finally { File.Delete(AutoPotsSettings.FilePath(package)); }
    }
}
