using System.Text.Json;
using MyEmu;
using Xunit;

/// Mac: DeviceProfileTests / PhoneLineTests (minus the IMEI, not on Windows yet).
public class DeviceTests
{
    [Fact]
    public void EachInstanceHasAnAvdPerProfile()
    {
        var two = new Instance("x", "Android 2", 2);
        Assert.Equal(("myemu", "myemu-custom"), (Instance.Main.Avd(DeviceProfile.PlayStore), Instance.Main.Avd(DeviceProfile.CustomModel)));
        Assert.Equal(("myemu-2", "myemu-custom-2"), (two.Avd(DeviceProfile.PlayStore), two.Avd(DeviceProfile.CustomModel)));
        Assert.Equal(@"system-images\android-35\google_apis\x86_64\", DeviceProfile.CustomModel.ImageConfig()["image.sysdir.1"]);
        Assert.Contains("-writable-system", Engine.Arguments("myemu-custom", 8554, 60, writableSystem: true, phoneNumber: "15550101234"));
        Assert.Equal("15550101234", Engine.Arguments("a", 1, 60, phoneNumber: "15550101234").SkipWhile(a => a != "-phone-number").ElementAt(1));
        Assert.DoesNotContain("-writable-system", Engine.Arguments("myemu", 8554, 60));
    }

    [Fact]
    public void IdentitiesAndPhoneNumbersAreChecked()
    {
        Assert.All(DeviceIdentity.Presets.Append(DeviceIdentity.Stock), p => Assert.Null(p.Problem));
        Assert.NotNull((DeviceIdentity.Stock with { Model = " " }).Problem);
        Assert.NotNull((DeviceIdentity.Stock with { Model = "a\"; reboot" }).Problem); // goes into a shell script
        Assert.NotNull((DeviceIdentity.Stock with { MarketName = new string('a', 41) }).Problem);
        Assert.Null(new PhoneLine("15550101234").Problem);
        Assert.Null(new PhoneLine().Problem);
        Assert.NotNull(new PhoneLine("+1555").Problem);
        Assert.NotNull(new PhoneLine("12").Problem);
    }

    [Fact]
    public void IdentityScriptRestoresThenRewrites()
    {
        var script = DeviceSetup.IdentityScript(DeviceIdentity.Presets[0]);
        Assert.Contains("cp -p /system/build.prop.myemu-orig /system/build.prop && sed -i -E", script);
        Assert.Contains(@"\1=SM-S928B/", script);
        Assert.DoesNotContain("sed", DeviceSetup.IdentityScript(DeviceIdentity.Stock)); // stock: just restore the originals
    }

    [Fact]
    public void SettingsJsonIsTheMacsShape()
    {
        var json = JsonSerializer.Serialize(DeviceSettings.Default with { Profile = DeviceProfile.CustomModel });
        Assert.Equal("""{"profile":"customModel","identity":{"brand":"google","manufacturer":"Google","model":"sdk_gphone64_x86_64","marketName":"sdk_gphone64_x86_64"},"phoneLine":{"phoneNumber":"","imei":""}}""", json);
        Assert.Equal(DeviceProfile.CustomModel, JsonSerializer.Deserialize<DeviceSettings>(json)!.Profile);
    }
}
