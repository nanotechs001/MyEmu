using System.IO;
using System.Text.Json;
using MyEmu;
using Xunit;

/// Mac: InstancesTests (list rules) and the AVD clone/ensure/delete tests.
public class InstancesTests
{
    [Fact]
    public void ListAddsNumbersRenamesAndKeepsInstanceOne()
    {
        var list = new InstanceList();
        var two = list.Add()!;
        Assert.Equal((2, "Android 2", "myemu-2", 8556), (two.Number, two.Name, two.Avd, two.GrpcPort));
        Assert.Equal(("myemu", 8554), (Instance.Main.Avd, Instance.Main.GrpcPort));
        list.Rename(two.Id, "  Farm " + new string('x', 60));
        Assert.Equal(InstanceList.MaxNameLength, list.Find(two.Id)!.Name.Length);
        list.Rename(two.Id, "   "); // ignored
        Assert.StartsWith("Farm", list.Find(two.Id)!.Name);
        list.Remove("main"); // instance 1 stays
        list.Remove(two.Id);
        Assert.Equal([Instance.Main], list.Instances);
        while (list.CanAdd) list.Add();
        Assert.Null(list.Add());
        Assert.Equal(InstanceList.MaxCount, list.Instances.Count);
    }

    [Fact]
    public void JsonIsTheMacsShape()
    {
        var json = JsonSerializer.Serialize(new InstanceList());
        Assert.Equal("""{"instances":[{"id":"main","name":"Android 1","number":1}]}""", json);
        Assert.Equal(Instance.Main, JsonSerializer.Deserialize<InstanceList>(json)!.Instances[0]);
    }

    [Fact]
    public async Task AvdsAreCreatedClonedAndDeleted()
    {
        var root = Path.Combine(Path.GetTempPath(), "myemu-avd-test-" + Guid.NewGuid().ToString("N"));
        var saved = AvdFiles.Root;
        AvdFiles.Root = root;
        try
        {
            var main = Path.Combine(root, "myemu.avd");
            Directory.CreateDirectory(Path.Combine(main, "snapshots", "default_boot"));
            Directory.CreateDirectory(Path.Combine(main, "data", "misc"));
            File.WriteAllText(Path.Combine(main, "config.ini"), "image.sysdir.1=system-images\\x\nhw.lcd.width=900\nhw.lcd.height=1600\nhw.cpu.ncore=2\nhw.ramSize=2048\n");
            File.WriteAllText(Path.Combine(main, "userdata-qemu.img.qcow2"), "data");
            File.WriteAllText(Path.Combine(main, "data", "misc", "kept"), "x");
            File.SetAttributes(Path.Combine(main, "data", "misc", "kept"), FileAttributes.ReadOnly); // like Android's pstore.bin
            File.WriteAllText(Path.Combine(main, "snapshots", "default_boot", "ram.img"), "huge");
            File.WriteAllText(Path.Combine(main, "multiinstance.lock"), "");
            File.WriteAllText(Path.Combine(root, "myemu.ini"), "path=x\n");

            AvdFiles.Ensure("myemu-2", "myemu"); // new: same image, landscape
            var fresh = Ini.Parse(File.ReadAllText(Path.Combine(root, "myemu-2.avd", "config.ini")));
            Assert.Equal(("system-images\\x", "1600", "900", "landscape"),
                (fresh["image.sysdir.1"], fresh["hw.lcd.width"], fresh["hw.lcd.height"], fresh["hw.initialOrientation"]));
            Assert.Contains("path.rel=avd\\myemu-2.avd", File.ReadAllText(Path.Combine(root, "myemu-2.ini")));
            Assert.False(File.Exists(Path.Combine(root, "myemu-2.avd", "userdata-qemu.img.qcow2"))); // data starts fresh

            Assert.True(await AvdFiles.CloneAsync("myemu", "myemu-3"));
            var copy = Path.Combine(root, "myemu-3.avd");
            Assert.True(File.Exists(Path.Combine(copy, "userdata-qemu.img.qcow2")));
            Assert.True(File.Exists(Path.Combine(copy, "data", "misc", "kept")));
            Assert.False(Directory.Exists(Path.Combine(copy, "snapshots"))); // the dead RAM snapshot isn't copied
            Assert.False(File.Exists(Path.Combine(copy, "multiinstance.lock")));
            await Assert.ThrowsAsync<IOException>(() => AvdFiles.CloneAsync("myemu", "myemu-3"));
            Assert.False(await AvdFiles.CloneAsync("never-made", "myemu-4"));

            AvdFiles.Delete("myemu-3");
            Assert.False(Directory.Exists(copy) || File.Exists(Path.Combine(root, "myemu-3.ini")));
            AvdFiles.Delete("myemu-3"); // already gone: fine
        }
        finally
        {
            AvdFiles.Delete("myemu"); // the test's own copy, read-only file included (Root is still the temp folder)
            AvdFiles.Root = saved;
            Directory.Delete(root, recursive: true);
        }
    }
}
