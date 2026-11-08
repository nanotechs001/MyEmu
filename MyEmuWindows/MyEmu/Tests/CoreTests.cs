using MyEmu;
using Xunit;

public class CoreTests
{
    [Fact]
    public void IniUpdateRewritesInPlaceAndAppendsMissingKeys()
    {
        var text = "hw.lcd.width=1600\r\n# comment\nhw.gltransport=pipe\n";
        var updated = Ini.Update(text, new Dictionary<string, string> { ["hw.gltransport"] = "asg", ["hw.device.name"] = "" });
        Assert.Equal("hw.lcd.width=1600\n# comment\nhw.gltransport=asg\nhw.device.name=\n", updated);
        Assert.Equal(new DeviceSize(1600, 900), DeviceSize.FromAvdConfig(Ini.Parse("hw.lcd.width = 1600\nhw.lcd.height=900")));
    }

    [Fact]
    public void EngineArgumentsMatchTheMacApp()
    {
        Assert.Equal(
            "-avd myemu -no-window -gpu host -feature -GuestAngle -grpc 8554 -grpc-use-token -vsync-rate 165 -no-boot-anim -no-snapshot-save",
            string.Join(' ', Engine.Arguments("myemu", 8554, 165)));
    }

    [Fact]
    public void DevicePointMapsAspectFitAndRejectsLetterbox()
    {
        var size = new DeviceSize(1600, 900);
        // 1000×900 view: scale 0.625, image 1000×562.5 centered vertically (top 168.75).
        Assert.Equal((800, 450), Pixels.DevicePoint(500, 450, 1000, 900, size));
        Assert.Null(Pixels.DevicePoint(500, 100, 1000, 900, size));
    }
}
