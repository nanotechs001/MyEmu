using System.Media;

namespace MyEmu;

/// MEmu-style game keys: an editor that places, moves and saves bindings, and play mode that turns
/// keys into touches. Port of GameKeys.swift; UI-free (MainWindow and KeymapOverlay drive it).
public sealed class GameKeys(Action<TouchPoint> sendTouch, Func<bool> loadEnabled, Action<bool> saveEnabled)
{
    const ushort EscapeKey = 53;
    static readonly HashSet<ushort> DeleteKeys = [51, 117]; // Backspace, Delete
    /// Where "Add Joystick" puts it: bottom-left, where games put their sticks.
    public static readonly NormalizedPoint NewJoystickCenter = new(0.18, 0.72);

    bool enabled = loadEnabled();
    /// Remembered between launches.
    public bool IsEnabled
    {
        get => enabled;
        set
        {
            if (enabled == value) return;
            enabled = value;
            saveEnabled(value);
            if (!value) ReleaseAll();
            Changed();
        }
    }

    /// The Android app in front; its mapping is the one in use and being edited.
    public string? CurrentApp { get; private set; }
    /// A text field has the keyboard up: keys go to Android as typing, not game keys.
    public bool IsTyping { get; private set; }
    /// The saved mapping for the current app.
    public Keymap Keymap { get; private set; } = new();
    /// The mapping being edited, null when not editing: Save writes it, Cancel drops it.
    public Keymap? Draft { get; private set; }
    /// Where the next key pressed in the editor gets bound.
    public NormalizedPoint? PendingTap { get; private set; }
    /// The key or joystick last clicked in the editor.
    public BindingRef? Selection { get; private set; }
    /// An error or hint for the editor.
    public string? Message { get; private set; }

    DeviceSize? device;
    public DeviceSize? Device { get => device; set { device = value; mapper = null; } }

    /// Redraw the overlay and panels.
    public event Action? OnChange;
    /// Game keys started or stopped mattering, so typing is only watched while they do.
    public event Action<bool>? OnLiveChange;
    bool wasLive;
    KeyTouchMapper? mapper;
    readonly Dictionary<ushort, CancellationTokenSource> bursts = [];

    public bool IsEditing => Draft != null;
    /// What the overlay shows: the draft while editing.
    public Keymap ShownKeymap => Draft ?? Keymap;
    /// Game keys are on and the app in front has a mapping.
    public bool IsLive => IsEnabled && CurrentApp != null && !Keymap.IsEmpty;

    public void AppDidChange(string package)
    {
        if (package == CurrentApp) return;
        ReleaseAll();
        CancelEdits();
        CurrentApp = package;
        mapper = null;
        try
        {
            Keymap = Keymap.Load(Keymap.FilePath(package));
            Message = null;
        }
        catch (Exception e) when (e is System.IO.IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
        {
            Keymap = new();
            Message = $"Couldn't read the mapping for {package}: {e.Message}";
        }
        Changed();
    }

    public void TypingDidChange(bool typing)
    {
        typing = typing && IsLive; // only meaningful for the mapped app in front
        if (typing == IsTyping) return;
        IsTyping = typing;
        if (typing) ReleaseAll(); // a held game key must not stay pressed while you type
        OnChange?.Invoke();
    }

    // --- Editor

    public void BeginEditing()
    {
        if (Draft != null) return;
        if (CurrentApp == null)
        {
            Message = "Open a game first; each game gets its own mapping.";
            OnChange?.Invoke();
            return;
        }
        ReleaseAll();
        (Draft, PendingTap, Selection, Message) = (Keymap, null, null, null);
        Changed();
    }

    public void SaveEdits()
    {
        if (Draft is not { } edited) return;
        (Draft, PendingTap, Selection) = (null, null, null);
        Update(edited);
        if (!Keymap.IsEmpty) IsEnabled = true; // saving a mapping means "play"
        Changed();
    }

    public void CancelEdits()
    {
        if (Draft == null) return;
        (Draft, PendingTap, Selection, Message) = (null, null, null, null);
        Changed();
    }

    public void ToggleEditing()
    {
        if (IsEditing) SaveEdits(); else BeginEditing();
    }

    /// A click on the screen while editing: selects the key under it, or marks an empty spot for the
    /// next key pressed. Alt-click puts the WASD joystick there.
    public void EditorPress(NormalizedPoint point, BindingRef? binding, bool placeJoystick)
    {
        if (Draft is not { } current) return;
        if (placeJoystick)
        {
            Draft = current.WithJoystick(point);
            (Selection, PendingTap) = (BindingRef.JoystickRef, null);
        }
        else if (binding != null) (Selection, PendingTap) = (binding, null);
        else (Selection, PendingTap) = (null, point);
        Message = null;
        OnChange?.Invoke();
    }

    public void EditorDrag(BindingRef binding, NormalizedPoint point)
    {
        Draft = Draft?.Moving(binding, point);
        OnChange?.Invoke();
    }

    public void EditorRemove(BindingRef binding)
    {
        Mutate(k => k.Removing(binding));
        if (Selection == binding) Selection = null;
        OnChange?.Invoke();
    }

    public void DeleteSelection() { if (Selection != null) EditorRemove(Selection); }

    public void AddJoystick()
    {
        Mutate(k => k.Joystick == null ? k.WithJoystick(NewJoystickCenter) : k);
        Selection = BindingRef.JoystickRef;
        OnChange?.Invoke();
    }

    public void SetOpacity(double value) => Mutate(k => k.SettingOpacity(value));
    public void SetJoystickRadius(double radius) => Mutate(k => k.SettingJoystickRadius(radius));
    public void SetMode(TapMode mode, ushort keyCode) => Mutate(k => k.SettingMode(mode, keyCode));
    public void SetBurstRate(double rate) => Mutate(k => k.SettingBurstRate(rate));
    public void Clear() => Mutate(_ => new Keymap());

    /// While editing, changes go to the draft; otherwise (panel controls) they're saved right away.
    void Mutate(Func<Keymap, Keymap> change)
    {
        if (Draft is { } current)
        {
            Draft = change(current);
            OnChange?.Invoke();
        }
        else Update(change(Keymap));
    }

    // --- Keys

    /// True when the key was used by game keys or the editor, so it must not also reach Android.
    public bool HandleKey(ushort keyCode, string label, bool down, bool isRepeat)
    {
        if (IsEditing)
        {
            if (down && !isRepeat) EditKey(keyCode, label);
            return true;
        }
        if (!IsEnabled || IsTyping || Device is not { } size) return false;
        var index = Keymap.Taps.ToList().FindIndex(t => t.KeyCode == keyCode);
        if (index >= 0 && Keymap.Taps[index].Mode == TapMode.Burst)
        {
            if (down) StartBurst(index, size);
            else if (bursts.Remove(keyCode, out var burst)) burst.Cancel();
            return true;
        }
        mapper ??= new KeyTouchMapper(Keymap, size);
        var touches = mapper.Handle(keyCode, down);
        if (touches == null) return false;
        touches.ForEach(sendTouch);
        return true;
    }

    /// Lifts any finger held by a game key (window lost focus, mapping changed or turned off).
    public void ReleaseAll()
    {
        foreach (var burst in bursts.Values) burst.Cancel(); // each loop lifts its finger as it stops
        bursts.Clear();
        mapper?.ReleaseAll().ForEach(sendTouch);
    }

    /// Taps the key's spot over and over until the key is released.
    void StartBurst(int index, DeviceSize size)
    {
        var tap = Keymap.Taps[index];
        if (bursts.ContainsKey(tap.KeyCode)) return; // auto-repeat
        var (x, y) = KeyTouchMapper.Pixel(size, tap.Position);
        var id = KeyTouchMapper.FirstTapFingerId + index;
        var (press, release) = Burst.Timing(Keymap.BurstRate);
        var stop = new CancellationTokenSource();
        bursts[tap.KeyCode] = stop;
        _ = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                sendTouch(new TouchPoint(id, x, y, true));
                try { await Task.Delay(press, stop.Token); } catch (OperationCanceledException) { } // still lift below
                sendTouch(new TouchPoint(id, x, y, false));
                try { await Task.Delay(release, stop.Token); } catch (OperationCanceledException) { }
            }
        });
    }

    /// Keys while editing: bind the marked spot, re-key the selected key, Esc / Delete.
    void EditKey(ushort keyCode, string label)
    {
        if (Draft is not { } current) return;
        if (keyCode == EscapeKey)
        {
            (PendingTap, Selection) = (null, null);
            OnChange?.Invoke();
            return;
        }
        if (Selection != null && DeleteKeys.Contains(keyCode))
        {
            DeleteSelection();
            return;
        }
        if (current.Joystick != null && KeyTouchMapper.Wasd.Contains(keyCode))
        {
            Message = "W A S D drive the joystick. Pick another key.";
            SystemSounds.Beep.Play();
            OnChange?.Invoke();
            return;
        }
        if (PendingTap is { } spot)
        {
            Draft = current.Binding(new KeyTap(keyCode, label, spot));
            (PendingTap, Selection) = (null, BindingRef.Tap(keyCode));
        }
        else if (Selection is { IsJoystick: false, KeyCode: { } selected })
        {
            Draft = current.Rebinding(selected, keyCode, label);
            Selection = BindingRef.Tap(keyCode);
        }
        else
        {
            SystemSounds.Beep.Play(); // click a spot or a key first
            return;
        }
        Message = null;
        OnChange?.Invoke();
    }

    /// Saves the mapping for the current app.
    void Update(Keymap newKeymap)
    {
        if (newKeymap.SameAs(Keymap) || CurrentApp is not { } app)
        {
            OnChange?.Invoke();
            return;
        }
        ReleaseAll();
        Keymap = newKeymap;
        mapper = null;
        try
        {
            newKeymap.Save(Keymap.FilePath(app));
            Message = null;
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException)
        {
            Message = $"Couldn't save key mapping: {e.Message}";
        }
        Changed();
    }

    void Changed()
    {
        OnChange?.Invoke();
        if (IsLive == wasLive) return;
        wasLive = IsLive;
        OnLiveChange?.Invoke(IsLive);
    }
}
