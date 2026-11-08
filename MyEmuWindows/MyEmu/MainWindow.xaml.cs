using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;

namespace MyEmu;

public partial class MainWindow : Window
{
    const int GrpcPort = 8554; // instance 1, as on the Mac
    const int KeyBack = 158, KeyHome = 172, KeyRecents = 580; // Linux evdev codes

    readonly string avd;
    readonly CancellationTokenSource running = new();
    EngineInstance? engine;
    EmulatorClient? client;
    FrameBuffer? frames;
    long frameCount; // written by the frame stream, read on the UI thread
    int frameWidth, frameHeight;
    readonly Stopwatch fpsClock = Stopwatch.StartNew();
    long fpsReceived;
    bool stopping;

    readonly AndroidOptions options = AndroidOptions.Load();
    int displayMaxFps = 60;
    bool runningGuestAngle;
    string? currentApp; // the app in front in Android
    Task adbChain = Task.CompletedTask; // option commands run in order
    bool loadingOptions = true; // controls fire change events while the XAML loads, before anything exists

    readonly GameKeys gameKeys;
    readonly AutoPotsController pots;
    const int PotionFingerId = 9; // the Mac's AutoPots.potionFingerID
    KeymapOverlay? overlay;
    CancellationTokenSource? typingWatch, typingCheck;

    public MainWindow(string avd)
    {
        this.avd = avd;
        InitializeComponent();
        gameKeys = new GameKeys(t => client?.Touch(t.Id, t.X, t.Y, t.Pressed),
            () => options.GameKeysEnabled, on => { options.GameKeysEnabled = on; options.Save(); });
        gameKeys.OnChange += () => { overlay?.Refresh(); ShowGameKeys(); };
        gameKeys.OnLiveChange += WatchTyping;
        pots = new AutoPotsController(LiveFrame, FrameCopy, (x, y, down) => client?.Touch(PotionFingerId, x, y, down));
        pots.OnChange += () => { overlay?.Refresh(); ShowAutoPots(); };
        SourceInitialized += (_, _) => RegisterF8();
        Loaded += (_, _) =>
        {
            overlay = new KeymapOverlay(this, gameKeys, pots);
            overlay.Show();
            PlaceOverlay();
        };
        Screen.LayoutUpdated += (_, _) => PlaceOverlay();
        LocationChanged += (_, _) => PlaceOverlay();
        Deactivated += (_, _) => gameKeys.ReleaseAll(); // keys released elsewhere never reach us
        ShowGameKeys();
        ShowAutoPots();
        ShowOptions();
        StateChanged += (_, _) => ApplyRate(); // minimized → background frame rate
        Loaded += async (_, _) => await StartAsync();
        Closing += OnClosing;
        PreviewKeyDown += (_, e) => OnKey(e, down: true);
        PreviewKeyUp += (_, e) => OnKey(e, down: false);
        new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(1), System.Windows.Threading.DispatcherPriority.Normal,
            (_, _) => UpdateFps(), Dispatcher).Start();
    }

    async Task StartAsync()
    {
        try
        {
            displayMaxFps = RefreshRate();
            Status.Text = $"Starting {avd}...";
            runningGuestAngle = options.GuestAngle;
            engine = await Engine.StartAsync(avd, GrpcPort, displayMaxFps, runningGuestAngle, running.Token);
            client = new EmulatorClient(engine.Port, engine.Token);
            frames = new FrameBuffer(engine.Size.Width * engine.Size.Height * 4);
            Status.Text = $"{avd} booting ({engine.Serial})";
            gameKeys.Device = engine.Size;
            ShowOptions(); // the frame-rate list depends on the screen's rate
            ApplyOptions();
            _ = WatchForegroundAppAsync(engine.Serial);
            pots.Attach(value => Dispatcher.BeginInvoke(() => pots.SetReading(value)));
            var size = engine.Size;
            await client.StreamFramesAsync(frames, size, (w, h) => // frame thread
            {
                Screen.Present(frames.Pixels, w, h);
                if (w != frameWidth || h != frameHeight)
                {
                    (frameWidth, frameHeight) = (w, h);
                    Dispatcher.BeginInvoke(() =>
                    {
                        FitScreen();
                        gameKeys.ReleaseAll();
                        gameKeys.Device = new DeviceSize(w, h); // rotation
                    });
                }
                Interlocked.Increment(ref frameCount);
            }, running.Token);
            if (!stopping) Status.Text = "The engine stopped sending frames.";
        }
        catch (Exception e) when (!stopping)
        {
            Status.Text = e is OperationCanceledException ? "Stopped." : $"Error: {e.Message}";
        }
        catch { } // closing
    }

    // --- Android options (Mac: EmulatorModel.applyAndroidOptions / applyAndroidRate / watchForegroundApp)

    /// Runs an adb shell command once Android has booted, after the ones queued before it.
    void RunInAndroid(string command)
    {
        if (engine is not { } e) return;
        adbChain = adbChain.ContinueWith(async _ =>
        {
            try { await Engine.AdbShellAfterBootAsync(e.Serial, command); }
            catch (Exception ex) { Debug.WriteLine($"Android command failed: {ex.Message}"); }
        }).Unwrap();
    }

    /// Everything the options set in Android. Idempotent, so it runs at every boot and every change.
    void ApplyOptions()
    {
        RunInAndroid(string.Join("; ", AndroidCommands.QuietGraphicsLog, AndroidCommands.KeepScreenOrientation,
            AndroidCommands.KeyboardOnly(options.KeyboardOnly), AndroidCommands.Lightweight(options.EffectiveLightweight),
            AndroidCommands.Animations(!options.SuperLight)));
        ApplyRate();
    }

    /// Android's refresh rate, and the game in front's own frame rate and render scale.
    void ApplyRate()
    {
        var rate = options.AndroidFps(displayMaxFps, WindowState == WindowState.Minimized);
        var command = AndroidCommands.RefreshRate(rate);
        if (currentApp != null) command += "; " + AndroidCommands.GameMode(rate, options.EffectiveRenderScale, currentApp);
        RunInAndroid(command);
    }

    /// Re-applies the game frame rate whenever another app comes to the front.
    async Task WatchForegroundAppAsync(string serial)
    {
        while (!running.IsCancellationRequested)
        {
            try
            {
                // The event stream reports only later switches; read the app already in front once.
                AppInFront(AndroidWatch.ForegroundPackageFromDump(await Engine.AdbAsync(serial, ["wait-for-device", "shell", AndroidWatch.ForegroundProbe])));
                await foreach (var line in AndroidWatch.Lines(serial, AndroidWatch.ForegroundCommand, running.Token))
                    AppInFront(AndroidWatch.ForegroundPackageFromEvent(line));
            }
            catch (Exception e) when (!running.IsCancellationRequested) { Debug.WriteLine($"Foreground watch ended: {e.Message}"); }
            catch { return; }
            try { await Task.Delay(2000, running.Token); } catch (OperationCanceledException) { return; }
        }
    }

    void AppInFront(string? package)
    {
        if (package == null) return;
        currentApp = package;
        gameKeys.AppDidChange(package);
        pots.AppDidChange(package);
        ScheduleTypingCheck(); // the new app may open with a text box focused
        ApplyRate();
    }

    // --- Typing: game keys pause while a text field has Android's keyboard (Mac: EmulatorModel.watchTyping)

    /// Watched only while game keys are live: it costs Android a little CPU.
    void WatchTyping(bool live)
    {
        typingWatch?.Cancel();
        typingWatch = null;
        typingCheck?.Cancel();
        gameKeys.TypingDidChange(false);
        if (!live || engine is not { } e) return;
        var watch = typingWatch = CancellationTokenSource.CreateLinkedTokenSource(running.Token);
        _ = Task.Run(async () =>
        {
            while (!watch.IsCancellationRequested)
            {
                Dispatcher.Invoke(ScheduleTypingCheck); // a text box may already be open
                try
                {
                    await foreach (var line in AndroidWatch.Lines(e.Serial, AndroidWatch.KeyboardEventsCommand, watch.Token))
                        if (AndroidWatch.IsKeyboardRequest(line)) Dispatcher.Invoke(ScheduleTypingCheck);
                }
                catch (Exception ex) when (!watch.IsCancellationRequested) { Debug.WriteLine($"Typing watch ended: {ex.Message}"); }
                catch { return; }
                try { await Task.Delay(2000, watch.Token); } catch (OperationCanceledException) { return; }
            }
        });
    }

    /// One check at a time: a burst of keyboard requests gets one check, after the last.
    void ScheduleTypingCheck()
    {
        if (typingWatch == null || engine is not { } e) return;
        typingCheck?.Cancel();
        var check = typingCheck = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            foreach (var delay in AndroidWatch.TypingProbeDelays)
            {
                try { await Task.Delay(delay, check.Token); } catch (OperationCanceledException) { return; }
                string? reading = null;
                try { reading = await Engine.AdbAsync(e.Serial, ["shell", AndroidWatch.TypingProbe]); } catch { } // next request retries
                if (check.IsCancellationRequested) return; // a newer check is running
                if (reading != null && AndroidWatch.IsTyping(reading) is { } typing) Dispatcher.Invoke(() => gameKeys.TypingDidChange(typing));
            }
        });
    }

    // --- AutoPots

    /// The newest frame, read in place (a frame arriving mid-read can tear a little; HP reads don't mind).
    MyEmu.AutoPots.IPixelFrame? LiveFrame() => frames != null && frameWidth > 0 ? new RgbaFrame(frames.Pixels, frameWidth, frameHeight) : null;

    /// A stable copy for Auto-detect and templates.
    MyEmu.AutoPots.IPixelFrame? FrameCopy() => frames != null && frameWidth > 0 ? new RgbaFrame((byte[])frames.Pixels.Clone(), frameWidth, frameHeight) : null;

    void ShowAutoPots()
    {
        var s = pots.Settings;
        loadingOptions = true;
        PotsStatus.Text = pots.Status;
        PotsMessage.Text = pots.Message ?? "";
        PotsMessage.Visibility = pots.Message == null ? Visibility.Collapsed : Visibility.Visible;
        OrbViewBox.IsChecked = s.View == MyEmu.AutoPots.GameView.Orb;
        SimpleViewBox.IsChecked = s.View == MyEmu.AutoPots.GameView.Simple;
        PotsStartButton.Content = pots.Running ? "Stop (F8)" : "Start (F8)";
        PotsDetectButton.IsEnabled = !pots.Detecting;
        PotsAdjustButton.IsChecked = pots.Adjusting;
        PotsTemplateButton.Visibility = s.View == MyEmu.AutoPots.GameView.Simple ? Visibility.Visible : Visibility.Collapsed;
        (PotsConfirmSlider.Value, PotsBurstSlider.Value, PotsPressSlider.Value, PotsSpreadSlider.Value) =
            (s.ConfirmReadings, s.ClicksPerBurst, s.PressMs, s.TapRandomPx);
        ShowPotsTuningLabels();
        loadingOptions = false;
    }

    void ShowPotsTuningLabels()
    {
        PotsConfirmLabel.Text = $"Readings before potting: {PotsConfirmSlider.Value:0}";
        PotsBurstLabel.Text = $"Taps per burst: {PotsBurstSlider.Value:0}";
        PotsPressLabel.Text = $"Press length: {PotsPressSlider.Value:0} ms";
        PotsSpreadLabel.Text = $"Tap spread: {PotsSpreadSlider.Value:0} px";
    }

    void PotsStart_Click(object sender, RoutedEventArgs e) => pots.Toggle();
    async void PotsDetect_Click(object sender, RoutedEventArgs e) => await pots.AutoDetectAsync();
    void PotsTemplate_Click(object sender, RoutedEventArgs e) => pots.RetakeTemplate();

    void PotsAdjust_Toggled(object sender, RoutedEventArgs e)
    {
        if (!loadingOptions) pots.SetAdjusting(PotsAdjustButton.IsChecked == true);
    }

    void PotsView_Checked(object sender, RoutedEventArgs e)
    {
        if (!loadingOptions)
            pots.Update(s => s with { View = SimpleViewBox.IsChecked == true ? MyEmu.AutoPots.GameView.Simple : MyEmu.AutoPots.GameView.Orb });
    }

    void PotsTuning_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (loadingOptions) return;
        ShowPotsTuningLabels();
        pots.Update(s => s with
        {
            ConfirmReadings = (int)PotsConfirmSlider.Value, ClicksPerBurst = (int)PotsBurstSlider.Value,
            PressMs = (int)PotsPressSlider.Value, TapRandomPx = (int)PotsSpreadSlider.Value,
        });
    }

    /// F8 starts/stops AutoPots from anywhere, as in the MuMu AutoPots app.
    void RegisterF8()
    {
        var source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        source.AddHook((nint hwnd, int msg, nint w, nint l, ref bool handled) =>
        {
            if (msg == 0x0312 && w == HotkeyId) { pots.Toggle(); handled = true; } // WM_HOTKEY
            return 0;
        });
        if (!RegisterHotKey(source.Handle, HotkeyId, 0x4000 /* MOD_NOREPEAT */, 0x77 /* F8 */))
            PotsMessage.Text = "F8 is taken by another app (the MuMu AutoPots app?); use the Start button.";
        Closed += (_, _) => UnregisterHotKey(source.Handle, HotkeyId);
    }

    const int HotkeyId = 1;
    [DllImport("user32.dll")] static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(nint hwnd, int id);

    // --- Game keys UI

    /// Keeps the key overlay exactly over the Android screen.
    void PlaceOverlay()
    {
        if (overlay == null || PresentationSource.FromVisual(Screen) is not { CompositionTarget: { } target }) return;
        var topLeft = target.TransformFromDevice.Transform(Screen.PointToScreen(new Point(0, 0)));
        if (overlay.Left != topLeft.X || overlay.Top != topLeft.Y) (overlay.Left, overlay.Top) = (topLeft.X, topLeft.Y);
        if (overlay.Width != Screen.ActualWidth || overlay.Height != Screen.ActualHeight)
            (overlay.Width, overlay.Height) = (Math.Max(1, Screen.ActualWidth), Math.Max(1, Screen.ActualHeight));
    }

    void ShowGameKeys()
    {
        var keymap = gameKeys.ShownKeymap;
        loadingOptions = true;
        KeysApp.Text = gameKeys.CurrentApp is { } app ? $"Mapping for {app}" : "Waiting for Android…";
        KeysEnabledBox.IsChecked = gameKeys.IsEnabled;
        KeysEnabledBox.IsEnabled = !gameKeys.Keymap.IsEmpty;
        EditKeysButton.Content = gameKeys.IsEditing ? "Save mapping (Ctrl+Shift+K)" : "Edit key mapping (Ctrl+Shift+K)";
        var status = gameKeys.Message ?? (gameKeys.IsTyping ? "Paused while you type." : null);
        KeysStatus.Text = status ?? "";
        KeysStatus.Visibility = status == null ? Visibility.Collapsed : Visibility.Visible;
        KeysSettings.Visibility = keymap.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
        BurstSlider.Value = keymap.BurstRate;
        BurstLabel.Text = $"Burst speed: {keymap.BurstRate:0} taps/s";

        EditorBar.Visibility = gameKeys.IsEditing ? Visibility.Visible : Visibility.Collapsed;
        OpacitySlider.Value = keymap.Opacity;
        var hasJoystick = keymap.Joystick != null;
        AddJoystickButton.Visibility = hasJoystick ? Visibility.Collapsed : Visibility.Visible;
        JoystickSizeLabel.Visibility = JoystickSlider.Visibility = hasJoystick ? Visibility.Visible : Visibility.Collapsed;
        if (keymap.Joystick is { } joystick) JoystickSlider.Value = joystick.Radius;
        var selectedTap = gameKeys.Selection is { KeyCode: { } code } ? keymap.Taps.FirstOrDefault(t => t.KeyCode == code) : null;
        SelectionRow.Visibility = gameKeys.Selection == null ? Visibility.Collapsed : Visibility.Visible;
        ModeBox.Visibility = selectedTap == null ? Visibility.Collapsed : Visibility.Visible;
        SelectionLabel.Text = selectedTap != null ? $"Key {selectedTap.Label}" : "WASD joystick";
        if (selectedTap != null) ModeBox.SelectedIndex = selectedTap.Mode == TapMode.Burst ? 1 : 0;
        EditorHint.Text = gameKeys.Message ?? (gameKeys.PendingTap != null
            ? "Now press the key for the marked spot."
            : "Click empty space, then press a key to add it · Drag keys to move them · Click a key, then press another key to change it · Right-click or Delete removes · Alt-click places the WASD joystick");
        loadingOptions = false;
    }

    void KeysEnabled_Click(object sender, RoutedEventArgs e) => gameKeys.IsEnabled = KeysEnabledBox.IsChecked == true;
    void EditKeys_Click(object sender, RoutedEventArgs e) => gameKeys.ToggleEditing();
    void SaveKeys_Click(object sender, RoutedEventArgs e) => gameKeys.SaveEdits();
    void CancelKeys_Click(object sender, RoutedEventArgs e) => gameKeys.CancelEdits();
    void AddJoystick_Click(object sender, RoutedEventArgs e) => gameKeys.AddJoystick();
    void DeleteSelection_Click(object sender, RoutedEventArgs e) => gameKeys.DeleteSelection();

    void ModeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loadingOptions && gameKeys.Selection is { KeyCode: { } code })
            gameKeys.SetMode(ModeBox.SelectedIndex == 1 ? TapMode.Burst : TapMode.Hold, code);
    }

    void OpacitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!loadingOptions) gameKeys.SetOpacity(e.NewValue);
    }

    void JoystickSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!loadingOptions) gameKeys.SetJoystickRadius(e.NewValue);
    }

    // Outside the editor each change is saved, so the burst slider saves when the drag ends.
    void BurstSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (loadingOptions) return;
        BurstLabel.Text = $"Burst speed: {e.NewValue:0} taps/s";
        if (gameKeys.IsEditing || !BurstSlider.IsMouseCaptureWithin) gameKeys.SetBurstRate(e.NewValue);
    }

    void KeySlider_DragCompleted(object sender, System.Windows.Controls.Primitives.DragCompletedEventArgs e) =>
        gameKeys.SetBurstRate(BurstSlider.Value);

    void ClearKeys_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "This removes every key and the joystick from this game's mapping.", "Clear all game keys?",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
            gameKeys.Clear();
    }

    // --- Options panel

    void OptionsButton_Toggled(object sender, RoutedEventArgs e)
    {
        OptionsPanel.Visibility = OptionsButton.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Fills the panel from the saved options.
    void ShowOptions()
    {
        loadingOptions = true;
        FpsBox.Items.Clear();
        FpsBox.Items.Add(new ComboBoxItem { Content = $"Max ({displayMaxFps} fps)", Tag = 0 });
        foreach (var fps in AndroidOptions.FpsChoices.Where(f => f < displayMaxFps))
            FpsBox.Items.Add(new ComboBoxItem { Content = $"{fps} fps", Tag = fps });
        FpsBox.SelectedItem = FpsBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag == options.FpsCap) ?? FpsBox.Items[0];
        if (RenderScaleBox.Items.Count == 0)
            foreach (var scale in AndroidOptions.RenderScales)
                RenderScaleBox.Items.Add(new ComboBoxItem
                {
                    Content = scale >= 1 ? "100% (sharpest)" : scale <= 0.1 ? "10% (fastest, very blurry)" : $"{Math.Round(scale * 100)}%",
                    Tag = scale,
                });
        RenderScaleBox.SelectedItem = RenderScaleBox.Items.Cast<ComboBoxItem>().First(i => (double)i.Tag == options.RenderScale);
        MinimizedBox.IsChecked = options.LowerFpsWhenMinimized;
        SuperLightBox.IsChecked = options.SuperLight;
        LightweightBox.IsChecked = options.Lightweight;
        KeyboardOnlyBox.IsChecked = options.KeyboardOnly;
        RendererBox.SelectedIndex = options.GuestAngle ? 0 : 1;
        UpdateOptionNotes();
        loadingOptions = false;
    }

    void Option_Changed(object sender, RoutedEventArgs e)
    {
        if (loadingOptions) return;
        options.FpsCap = (int)((ComboBoxItem)FpsBox.SelectedItem).Tag;
        options.RenderScale = (double)((ComboBoxItem)RenderScaleBox.SelectedItem).Tag;
        options.LowerFpsWhenMinimized = MinimizedBox.IsChecked == true;
        options.SuperLight = SuperLightBox.IsChecked == true;
        options.Lightweight = LightweightBox.IsChecked == true;
        options.KeyboardOnly = KeyboardOnlyBox.IsChecked == true;
        options.GuestAngle = RendererBox.SelectedIndex == 0;
        options.Save();
        UpdateOptionNotes();
        ApplyOptions();
    }

    void UpdateOptionNotes()
    {
        FpsBox.IsEnabled = RenderScaleBox.IsEnabled = !options.SuperLight;
        RendererNote.Text = engine != null && runningGuestAngle != options.GuestAngle
            ? "Takes effect the next time MyEmu starts Android."
            : "Vulkan ran Xerion at the same fps as OpenGL with about half the GPU. Use OpenGL only if a game draws incorrectly.";
    }

    /// Keeps the screen window at Android's aspect ratio, centered (DXGI stretches the frame to it).
    void FitScreen()
    {
        if (frameWidth == 0) return;
        var scale = Math.Min(ScreenArea.ActualWidth / frameWidth, ScreenArea.ActualHeight / frameHeight);
        Screen.Width = Math.Max(1, frameWidth * scale);
        Screen.Height = Math.Max(1, frameHeight * scale);
    }

    void ScreenArea_SizeChanged(object sender, SizeChangedEventArgs e) => FitScreen();

    /// Once a second: frames Android sent (each one is drawn as it arrives).
    void UpdateFps()
    {
        if (frameWidth == 0 || stopping) return;
        var received = Interlocked.Read(ref frameCount);
        Status.Text = $"{avd} · {frameWidth}×{frameHeight} · {(received - fpsReceived) / fpsClock.Elapsed.TotalSeconds:0} fps";
        fpsReceived = received;
        fpsClock.Restart();
    }

    // --- Touch: one finger from the left mouse button.

    void Screen_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (SendTouch(e.GetPosition(ScreenArea), pressed: true)) ScreenArea.CaptureMouse();
    }

    void Screen_MouseMove(object sender, MouseEventArgs e)
    {
        if (ScreenArea.IsMouseCaptured) SendTouch(e.GetPosition(ScreenArea), pressed: true);
    }

    void Screen_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!ScreenArea.IsMouseCaptured) return;
        SendTouch(e.GetPosition(ScreenArea), pressed: false, clamp: true);
        ScreenArea.ReleaseMouseCapture();
    }

    bool SendTouch(Point p, bool pressed, bool clamp = false)
    {
        if (client == null || engine == null) return false;
        var size = frameWidth > 0 ? new DeviceSize(frameWidth, frameHeight) : engine.Size;
        if (clamp) // lifting outside the screen still has to lift the finger
        {
            var scale = Math.Min(ScreenArea.ActualWidth / size.Width, ScreenArea.ActualHeight / size.Height);
            var left = (ScreenArea.ActualWidth - size.Width * scale) / 2;
            var top = (ScreenArea.ActualHeight - size.Height * scale) / 2;
            p = new Point(Math.Clamp(p.X, left, left + size.Width * scale - 1), Math.Clamp(p.Y, top, top + size.Height * scale - 1));
        }
        if (Pixels.DevicePoint(p.X, p.Y, ScreenArea.ActualWidth, ScreenArea.ActualHeight, size) is not { } d) return false;
        client.Touch(KeyTouchMapper.MouseFingerId, d.X, d.Y, pressed);
        return true;
    }

    // --- Keys: game keys first, the rest go to Android as Windows scan codes.

    void OnKey(KeyEventArgs e, bool down)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (down && Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && key is Key.K or Key.G)
        {
            if (key == Key.K) gameKeys.ToggleEditing();
            else if (!gameKeys.Keymap.IsEmpty) gameKeys.IsEnabled = !gameKeys.IsEnabled;
            e.Handled = true;
            return;
        }
        if (MacKeys.From(key) is { } mac ? gameKeys.HandleKey(mac.Code, mac.Label, down, e.IsRepeat) : gameKeys.IsEditing)
        {
            e.Handled = true; // while editing, no key reaches Android
            return;
        }
        if (client == null || e.IsRepeat) return;
        var scan = (int)MapVirtualKey((uint)KeyInterop.VirtualKeyFromKey(key), MapvkVkToVscEx);
        if (scan == 0) return;
        client.Key(scan, down);
        e.Handled = true; // keep Tab, arrows and Alt for Android, not WPF focus/menus
    }

    void Back_Click(object sender, RoutedEventArgs e) => client?.AndroidKey(KeyBack);
    void Home_Click(object sender, RoutedEventArgs e) => client?.AndroidKey(KeyHome);
    void Recents_Click(object sender, RoutedEventArgs e) => client?.AndroidKey(KeyRecents);

    async void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (stopping || engine == null) { running.Cancel(); return; }
        e.Cancel = true; // close again once Android is down
        stopping = true;
        Status.Text = "Shutting down Android...";
        running.Cancel();
        pots.Dispose(); // no taps into an Android that's shutting down
        await Engine.StopAsync(engine);
        client?.Dispose();
        frames?.Dispose();
        engine = null;
        Close();
    }

    // --- Win32

    const uint MapvkVkToVscEx = 4;
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public short SpecVersion, DriverVersion, Size, DriverExtra;
        public int Fields, PositionX, PositionY, DisplayOrientation, DisplayFixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public short LogPixels;
        public int BitsPerPel, PelsWidth, PelsHeight, DisplayFlags, DisplayFrequency;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string? device, int mode, ref DevMode devMode);

    /// The primary screen's refresh rate (Android otherwise runs at 60 Hz).
    static int RefreshRate()
    {
        var mode = new DevMode { Size = (short)Marshal.SizeOf<DevMode>() };
        return EnumDisplaySettings(null, -1, ref mode) && mode.DisplayFrequency >= 60 ? mode.DisplayFrequency : 60;
    }
}
