using MyEmu;
using Xunit;
using Key = System.Windows.Input.Key;

public class KeymapTests
{
    /// What the Mac app writes (JSONEncoder, .prettyPrinted + .sortedKeys); an old key has no "mode".
    const string MacJson = """
        {
          "burstRate" : 12,
          "joystick" : { "center" : { "x" : 0.18, "y" : 0.72 }, "radius" : 0.1 },
          "opacity" : 0.5,
          "taps" : [
            { "keyCode" : 49, "label" : "Space", "mode" : "burst", "position" : { "x" : 0.9, "y" : 0.8 } },
            { "keyCode" : 12, "label" : "Q", "position" : { "x" : 0.5, "y" : 0.25 } }
          ]
        }
        """;

    [Fact]
    public void ReadsAndWritesTheMacFormat()
    {
        var keymap = Keymap.FromJson(MacJson);
        Assert.Equal(12, keymap.BurstRate);
        Assert.Equal(0.5, keymap.Opacity);
        Assert.Equal(new Joystick(new NormalizedPoint(0.18, 0.72), 0.1), keymap.Joystick);
        Assert.Equal(new KeyTap(49, "Space", new NormalizedPoint(0.9, 0.8), TapMode.Burst), keymap.Taps[0]);
        Assert.Equal(TapMode.Hold, keymap.Taps[1].Mode); // missing mode = hold, as on the Mac
        var json = keymap.ToJson();
        foreach (var field in new[] { "\"taps\"", "\"keyCode\": 49", "\"mode\": \"burst\"", "\"position\"", "\"burstRate\"", "\"opacity\"", "\"center\"", "\"radius\"" })
            Assert.Contains(field, json);
        Assert.True(Keymap.FromJson(json).SameAs(keymap));
        Assert.True(Keymap.FromJson("{}").IsEmpty);
        Assert.Equal(Keymap.DefaultOpacity, Keymap.FromJson("{}").Opacity);
    }

    [Fact]
    public void WindowsKeysUseMacKeyCodes()
    {
        Assert.Equal(((ushort)0, "A"), MacKeys.From(Key.A));
        Assert.Equal(((ushort)13, "W"), MacKeys.From(Key.W));
        Assert.Equal(((ushort)18, "1"), MacKeys.From(Key.D1));
        Assert.Equal(((ushort)49, "Space"), MacKeys.From(Key.Space));
        Assert.Equal(((ushort)122, "F1"), MacKeys.From(Key.F1));
        Assert.Equal(((ushort)126, "↑"), MacKeys.From(Key.Up));
        Assert.Null(MacKeys.From(Key.LWin));
        Assert.Null(MacKeys.From(Key.LeftAlt)); // modifiers aren't mappable (as on the Mac); Alt places the joystick
    }

    [Fact]
    public void KeysTouchTheirSpotsAndWasdDrivesTheJoystick()
    {
        var device = new DeviceSize(1000, 500);
        var keymap = Keymap.FromJson(MacJson);
        var mapper = new KeyTouchMapper(keymap, device);
        Assert.Equal([new TouchPoint(3, 500, 125, true)], mapper.Handle(12, true)!); // Q, second tap → finger 3
        Assert.Empty(mapper.Handle(12, true)!); // repeat
        Assert.Null(mapper.Handle(14, true)); // E isn't mapped → goes to Android
        var push = mapper.Handle(KeyTouchMapper.MacD, true)!;
        Assert.Equal([new TouchPoint(1, 180, 360, true), new TouchPoint(1, 280, 360, true)], push); // down at center, then thumb right
        Assert.Equal(new[] { new TouchPoint(1, 180, 360, false), new TouchPoint(3, 500, 125, false) },
            mapper.ReleaseAll().OrderBy(t => t.Id));
    }

    [Fact]
    public void EditorBindsMovesRebindsAndRemoves()
    {
        var touches = new List<TouchPoint>();
        var enabled = false;
        var keys = new GameKeys(touches.Add, () => enabled, on => enabled = on);
        keys.BeginEditing();
        Assert.False(keys.IsEditing); // needs a game in front
        keys.AppDidChange("test.myemu.keymaps" + Guid.NewGuid().ToString("N")); // no file → empty mapping
        keys.BeginEditing();
        keys.EditorPress(new NormalizedPoint(0.5, 0.5), null, placeJoystick: false);
        Assert.True(keys.HandleKey(12, "Q", down: true, isRepeat: false));
        Assert.Equal(new KeyTap(12, "Q", new NormalizedPoint(0.5, 0.5)), keys.Draft!.Taps.Single());
        keys.EditorDrag(BindingRef.Tap(12), new NormalizedPoint(2, 0.1)); // clamped onto the screen
        Assert.Equal(new NormalizedPoint(1, 0.1), keys.Draft!.Taps.Single().Position);
        keys.HandleKey(14, "E", true, false); // selected Q → becomes E
        Assert.Equal("E", keys.Draft!.Taps.Single().Label);
        keys.AddJoystick();
        Assert.True(keys.HandleKey(KeyTouchMapper.MacW, "W", true, false)); // refused, still consumed
        Assert.NotNull(keys.Message);
        keys.EditorRemove(BindingRef.JoystickRef);
        keys.CancelEdits();
        Assert.True(keys.Keymap.IsEmpty); // cancel drops the draft
        Assert.False(enabled);
    }
}
