using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;

namespace MyEmu;

public partial class MainWindow : Window
{
    const int KeyBack = 158, KeyHome = 172, KeyRecents = 580; // Linux evdev codes

    readonly Instance instance;
    string avd; // the running profile's AVD
    DeviceSettings device, deviceDraft; // this instance's profile, model and phone line, and the panel's edits
    string? notice; // shown after the fps in the status line (Custom-model setup)
    CancellationTokenSource? deviceSetup;
    CancellationTokenSource running = new(); // one per engine run: replaced on restart
    Task engineTask = Task.CompletedTask;
    bool restarting;
    AvdSettings? avdSettings, draft; // the AVD's config.ini and the panel's unapplied edits
    static readonly HostLimits Host = HostLimits.Current;
    EngineInstance? engine;
    EmulatorClient? client;
    FrameBuffer? frames;
    long frameCount; // written by the frame stream, read on the UI thread
    int frameWidth, frameHeight;
    readonly Stopwatch fpsClock = Stopwatch.StartNew();
    long fpsReceived;
    bool stopping;

    readonly AndroidOptions options = AndroidOptions.Shared;
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

    public MainWindow(Instance instance)
    {
        this.instance = instance;
        device = deviceDraft = DeviceSettings.Load(instance.Id);
        avd = instance.Avd(device.Profile);
        InitializeComponent();
        ShowDevice();
        Title = $"MyEmu · {instance.Name}";
        InstanceManager.Changed += ShowInstances;
        InstanceManager.OptionsChanged += OtherWindowChangedOptions;
        Closed += (_, _) => { InstanceManager.Changed -= ShowInstances; InstanceManager.OptionsChanged -= OtherWindowChangedOptions; };
        gameKeys = new GameKeys(t => client?.Touch(t.Id, t.X, t.Y, t.Pressed),
            () => options.GameKeysEnabled, on => { options.GameKeysEnabled = on; options.Save(); });
        gameKeys.OnChange += () => { overlay?.Refresh(); ShowGameKeys(); };
        gameKeys.OnLiveChange += WatchTyping;
        pots = new AutoPotsController(LiveFrame, FrameCopy, (x, y, down) => client?.Touch(PotionFingerId, x, y, down));
        pots.OnChange += () => { overlay?.Refresh(); ShowAutoPots(); };
        if (InstanceManager.F8Taken) PotsMessage.Text = "F8 is taken by another app (the MuMu AutoPots app?); use the Start button.";
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
        Loaded += (_, _) => engineTask = StartAsync();
        ShowInstances();
        Closing += OnClosing;
        PreviewKeyDown += (_, e) => OnKey(e, down: true);
        PreviewKeyUp += (_, e) => OnKey(e, down: false);
        new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(1), System.Windows.Threading.DispatcherPriority.Normal,
            (_, _) => UpdateFps(), Dispatcher).Start();
    }

    async Task StartAsync()
    {
        var cancel = running.Token;
        try
        {
            displayMaxFps = RefreshRate();
            Status.Text = $"Starting {avd}...";
            runningGuestAngle = options.GuestAngle;
            var profile = device.Profile;
            avd = instance.Avd(profile);
            // the first start of a new PC, instance or profile
            AvdFiles.Ensure(avd, Instance.Main.Avd, profile == DeviceProfile.PlayStore ? null : profile.ImageConfig());
            var custom = profile == DeviceProfile.CustomModel;
            GpuPriority.Apply(options.GpuPriority); // the GPU preference must be there before the engine starts
            engine = await Engine.StartAsync(avd, instance.GrpcPort, displayMaxFps, runningGuestAngle, cancel,
                writableSystem: profile.NeedsWritableSystem(), phoneNumber: custom ? device.PhoneLine.PhoneNumber : "");
            GpuPriority.Apply(options.GpuPriority); // and its process's priority, now that it runs
            if (custom) SetUpCustomModel(engine.Serial);
            ShowDevice();
            avdSettings = draft = AvdSettings.Read(avd);
            client = new EmulatorClient(engine.Port, engine.Token);
            frames = new FrameBuffer(engine.Size.Width * engine.Size.Height * 4);
            Status.Text = $"{avd} booting ({engine.Serial})";
            gameKeys.Device = engine.Size;
            ShowOptions(); // the frame-rate list depends on the screen's rate
            ShowDisplay();
            ApplyOptions();
            WatchTyping(gameKeys.IsLive); // after a restart: the old watch ended with the old engine
            _ = WatchForegroundAppAsync(engine.Serial, cancel);
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
            }, cancel);
            if (!stopping && !restarting) Status.Text = "The engine stopped sending frames.";
        }
        catch (Exception e) when (!stopping && !restarting)
        {
            Status.Text = e is OperationCanceledException ? "Stopped." : $"Error: {e.Message}";
        }
        catch { } // closing or restarting
    }

    /// Shuts Android down, writes the panel's AVD changes, and starts it again (Mac: EmulatorModel.restart).
    async Task RestartAndroidAsync()
    {
        if (restarting || engine == null) return;
        restarting = true;
        ShowDisplay();
        Status.Text = "Restarting Android…";
        await StopAndroidAsync();
        if (draft is { } d && d != avdSettings)
        {
            try { d.Write(avd); }
            catch (Exception e)
            {
                Status.Text = $"Couldn't save the new settings: {e.Message}";
                await Task.Delay(3000); // let it be read, then boot as before
            }
        }
        restarting = false;
        ShowDisplay();
        StartAndroid();
    }

    /// Shuts the engine down and waits until its frame stream has ended; the window stays.
    async Task StopAndroidAsync()
    {
        if (engine is not { } old) return;
        gameKeys.ReleaseAll();
        running.Cancel();
        await Engine.StopAsync(old); // the same AVD can't run twice
        await engineTask;
        frameWidth = frameHeight = 0; // AutoPots reads no frames now
        notice = null;
        client?.Dispose();
        frames?.Dispose();
        (client, frames, engine) = (null, null, null);
    }

    void StartAndroid()
    {
        if (stopping) return; // the window is closing
        running = new CancellationTokenSource();
        engineTask = StartAsync();
    }

    // --- Device: profile, model and phone line (Mac: DeviceDrawer, EmulatorModel.applyIdentity/applyDeviceDraft)

    /// The custom-model image has no Play Store and reports Google's SDK phone: add Google's Play apps, then
    /// write the model (Android reboots once for each change), then the Settings name.
    void SetUpCustomModel(string serial)
    {
        deviceSetup?.Cancel();
        var cancel = deviceSetup = CancellationTokenSource.CreateLinkedTokenSource(running.Token);
        var identity = device.Identity;
        _ = Task.Run(async () =>
        {
            void Say(string? text) => Dispatcher.BeginInvoke(() => { if (!cancel.IsCancellationRequested) notice = text; });
            try
            {
                Say("Checking Google Play Store…");
                if (await DeviceSetup.EnsurePlayStoreAsync(serial, instance.Avd(DeviceProfile.PlayStore))) Say("Google Play Store added");
                if (cancel.IsCancellationRequested) return;
                Say("Checking game speed…");
                if (await DeviceSetup.EnsureSpeedBridgeAsync(serial)) Say("Game speed installed");
                if (cancel.IsCancellationRequested) return;
                Say("Setting device model…");
                if (await DeviceSetup.ApplyIdentityAsync(identity, serial)) Say("Restarted with the new model");
                await DeviceSetup.SetDeviceNameAsync(identity.MarketName, serial);
                Say(null);
                await Dispatcher.BeginInvoke(ApplyGameSpeed); // the reboots above cleared the live speed
            }
            catch (Exception e) when (!cancel.IsCancellationRequested) { Say($"Device setup failed: {e.Message}"); }
            catch { } // Android stopped meanwhile
        });
    }

    void ShowDevice()
    {
        var wasLoading = loadingOptions;
        loadingOptions = true;
        var d = deviceDraft;
        DeviceCurrent.Text = device.Profile == DeviceProfile.PlayStore ? "Now: Play Store · Google SDK phone"
            : $"Now: Custom model · {device.Identity.MarketName} ({device.Identity.Model})";
        ProfileBox.SelectedIndex = d.Profile == DeviceProfile.PlayStore ? 0 : 1;
        ProfileNote.Text = d.Profile == DeviceProfile.PlayStore
            ? "Google Play works here, but Google locks this image, so the device model can't change."
            : "Pick the phone Android reports to games. Google Play Store is added automatically. Its apps and sign-in are separate from the Play Store profile.";
        CustomModelPanel.Visibility = d.Profile == DeviceProfile.CustomModel ? Visibility.Visible : Visibility.Collapsed;
        if (ModelBox.Items.Count == 0)
        {
            ModelBox.Items.Add(new ComboBoxItem { Content = "Google SDK phone (stock)", Tag = DeviceIdentity.Stock });
            foreach (var preset in DeviceIdentity.Presets) ModelBox.Items.Add(new ComboBoxItem { Content = $"{preset.MarketName} · {preset.Model}", Tag = preset });
            ModelBox.Items.Add(new ComboBoxItem { Content = "Custom" });
        }
        ModelBox.SelectedItem = ModelBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => Equals(i.Tag, d.Identity)) ?? ModelBox.Items[^1];
        foreach (var (box, value) in new[] { (MarketNameBox, d.Identity.MarketName), (BrandBox, d.Identity.Brand), (MakerBox, d.Identity.Manufacturer),
                     (ModelNameBox, d.Identity.Model), (PhoneBox, d.PhoneLine.PhoneNumber) })
            if (!box.IsKeyboardFocused) box.Text = value;

        var profileChanged = d.Profile != device.Profile;
        var custom = d.Profile == DeviceProfile.CustomModel;
        var identityChanged = custom && d.Identity != device.Identity;
        var phoneChanged = custom && d.PhoneLine != device.PhoneLine;
        DeviceApplyBox.Visibility = profileChanged || identityChanged || phoneChanged ? Visibility.Visible : Visibility.Collapsed;
        var problem = custom ? d.Identity.Problem ?? d.PhoneLine.Problem : null;
        DeviceApplyNote.Text = problem ?? (profileChanged
            ? $"Android restarts in the {d.Profile.Title()} profile. The first switch to Custom model sets up its Android (a few minutes)."
            : phoneChanged ? "Android restarts to apply the new phone number." : "Android restarts once to load the new model.");
        DeviceApplyNote.Foreground = problem != null ? System.Windows.Media.Brushes.IndianRed : System.Windows.Media.Brushes.LightGray;
        DeviceApplyButton.Content = profileChanged || phoneChanged ? "Apply & Restart" : "Apply";
        DeviceApplyButton.IsEnabled = problem == null && !restarting && engine != null;

        if (SpeedBox.Items.Count == 0)
            foreach (var speed in AndroidOptions.GameSpeeds)
                SpeedBox.Items.Add(new ComboBoxItem { Content = speed == 1 ? "Normal" : $"{speed.ToString(System.Globalization.CultureInfo.InvariantCulture)}×", Tag = speed });
        SpeedBox.SelectedItem = SpeedBox.Items.Cast<ComboBoxItem>().First(i => (double)i.Tag == device.GameSpeed);
        SpeedBox.IsEnabled = device.Profile == DeviceProfile.CustomModel;
        SpeedNote.Text = device.Profile == DeviceProfile.CustomModel
            ? "Runs the game's own clock faster or slower: only the game in front, not the rest of Android. Applies live."
            : "Game speed needs the Custom model profile (its writable system). Switch it under Device.";
        loadingOptions = wasLoading;
    }

    void Speed_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loadingOptions || SpeedBox.SelectedItem is not ComboBoxItem { Tag: double speed }) return;
        SetGameSpeed(speed);
    }

    /// Saves and applies this instance's game speed (also the MCP's set_game_speed).
    internal void SetGameSpeed(double speed)
    {
        device = device with { GameSpeed = speed };
        deviceDraft = deviceDraft with { GameSpeed = speed };
        device.Save(instance.Id);
        ShowDevice();
        ApplyGameSpeed();
    }

    /// Points the speed bridge at the game in front and sets its speed (Custom model only: the bridge is there).
    void ApplyGameSpeed()
    {
        if (device.Profile != DeviceProfile.CustomModel || currentApp is not { } app || !AndroidWatch.IsValidPackage(app)) return;
        RunInAndroid(AndroidCommands.GameSpeed(device.GameSpeed, app));
    }

    void Device_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loadingOptions) return;
        if (sender == ProfileBox) deviceDraft = deviceDraft with { Profile = ProfileBox.SelectedIndex == 1 ? DeviceProfile.CustomModel : DeviceProfile.PlayStore };
        else if (ModelBox.SelectedItem is ComboBoxItem { Tag: DeviceIdentity preset }) deviceDraft = deviceDraft with { Identity = preset };
        ShowDevice();
    }

    void DeviceText_Changed(object sender, RoutedEventArgs e)
    {
        if (loadingOptions) return;
        deviceDraft = deviceDraft with
        {
            Identity = new DeviceIdentity(BrandBox.Text.Trim(), MakerBox.Text.Trim(), ModelNameBox.Text.Trim(), MarketNameBox.Text.Trim()),
            PhoneLine = deviceDraft.PhoneLine with { PhoneNumber = PhoneBox.Text.Trim() },
        };
        ShowDevice();
    }

    async void DeviceApply_Click(object sender, RoutedEventArgs e)
    {
        var old = device;
        device = deviceDraft;
        device.Save(instance.Id);
        ShowDevice();
        // A new profile is the other AVD, and the engine sets the phone number as it starts: restart. A new
        // model on the running custom profile is written live (Android reboots once).
        if (device.Profile != old.Profile || device.Profile == DeviceProfile.CustomModel && device.PhoneLine != old.PhoneLine)
            await RestartAndroidAsync();
        else if (device.Profile == DeviceProfile.CustomModel && engine is { } e2) SetUpCustomModel(e2.Serial);
    }

    void DeviceRevert_Click(object sender, RoutedEventArgs e)
    {
        deviceDraft = device;
        ShowDevice();
    }

    // --- MCP hooks (InstanceManager's AI control calls these on the UI thread)

    /// Running: this window's Android is up or starting (not stopped over MCP).
    internal McpInstanceState McpState(Instance current) =>
        new(current.Id, current.Name, engine != null || !engineTask.IsCompleted, engine?.Serial, Status.Text, currentApp, device.Profile, device.GameSpeed);

    internal string McpStart()
    {
        if (engine != null || restarting || !engineTask.IsCompleted) return $"{instance.Name} is already running or starting. Poll list_instances until ready is true.";
        StartAndroid();
        return $"Starting {instance.Name}. Poll list_instances until ready is true.";
    }

    /// Stops Android; the window stays (closing the last window would quit MyEmu and its MCP server).
    internal async Task<string> McpStopAsync()
    {
        if (engine == null || restarting) return $"{instance.Name} isn't running.";
        restarting = true; // no restart or second stop meanwhile
        Status.Text = "Stopping Android…";
        await StopAndroidAsync();
        restarting = false;
        Status.Text = "Android stopped. start_instance (MCP) starts it again.";
        ShowDisplay();
        return $"Stopped {instance.Name}.";
    }

    /// The newest frame, copied (called off the UI thread by MCP).
    internal (byte[] Rgba, int Width, int Height)? ScreenCopy() =>
        frames is { } f && frameWidth > 0 ? ((byte[])f.Pixels.Clone(), frameWidth, frameHeight) : null;

    // --- Instances and AI control (Mac: InstancesDrawer, AIControlSection)

    void ShowInstances()
    {
        var wasLoading = loadingOptions;
        loadingOptions = true;
        AiControlBox.IsChecked = options.AiControl;
        AiControlUrl.Text = InstanceManager.AiControlRunning ? McpHttpServer.Url : "";
        AiControlNote.Text = InstanceManager.AiControlProblem
            ?? "AI apps (Claude Code, Codex…) can see every Android's screen and tap, type and open apps through this local address.";
        AiControlNote.Foreground = InstanceManager.AiControlProblem != null ? System.Windows.Media.Brushes.IndianRed : System.Windows.Media.Brushes.Gray;
        loadingOptions = wasLoading;

        if (InstancesPanel.IsKeyboardFocusWithin) return; // a name is being typed: rebuilt when it's done
        InstancesPanel.Children.Clear();
        var busy = InstanceManager.Busy;
        foreach (var other in InstanceManager.List.Instances)
        {
            var id = other.Id;
            var window = InstanceManager.Window(id);
            var isThis = id == instance.Id;
            var name = new TextBox { Text = other.Name, Width = 150, FontWeight = isThis ? FontWeights.SemiBold : FontWeights.Normal };
            name.LostFocus += (_, _) => { if (name.Text != other.Name) InstanceManager.Rename(id, name.Text); };
            name.KeyDown += (_, e) => { if (e.Key == Key.Enter) FocusScreen(); };
            var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 2) };
            header.Children.Add(new TextBlock
            {
                Text = "●", Margin = new Thickness(0, 2, 6, 0), FontSize = 12,
                Foreground = window != null ? System.Windows.Media.Brushes.LimeGreen : System.Windows.Media.Brushes.DimGray,
            });
            header.Children.Add(name);
            if (isThis) header.Children.Add(new TextBlock { Text = "this window", Margin = new Thickness(6, 3, 0, 0) });
            var buttons = new WrapPanel();
            Button Add(string label, Action click, bool enabled = true)
            {
                var button = new Button { Content = label, Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(0, 0, 4, 0), Focusable = false, IsEnabled = enabled };
                button.Click += (_, _) => click();
                buttons.Children.Add(button);
                return button;
            }
            if (window == null) Add("Start", () => InstanceManager.Open(id));
            else
            {
                if (!isThis) Add("Show", () => InstanceManager.Open(id));
                Add("Stop", () => window.Close()); // closing a window stops its Android
            }
            Add("Clone", () => CloneInstance(id), window == null && busy == null && InstanceManager.List.CanAdd);
            if (other.Number > 1) Add("Delete", () => DeleteInstance(other), window == null && busy == null);
            InstancesPanel.Children.Add(header);
            InstancesPanel.Children.Add(buttons);
        }
        NewInstanceButton.IsEnabled = busy == null && InstanceManager.List.CanAdd;
        InstancesBusy.Text = busy ?? "";
        InstancesBusy.Visibility = busy == null ? Visibility.Collapsed : Visibility.Visible;
    }

    void NewInstance_Click(object sender, RoutedEventArgs e)
    {
        if (InstanceManager.Create() is { } created) InstanceManager.Open(created.Id);
    }

    async void CloneInstance(string id)
    {
        try { await InstanceManager.CloneAsync(id); }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Couldn't clone the instance", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    void DeleteInstance(Instance other)
    {
        if (MessageBox.Show(this, $"This deletes {other.Name} and all its apps, sign-ins and game data. It can't be undone.",
                $"Delete {other.Name}?", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        try { InstanceManager.Delete(other.Id); }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Couldn't delete the instance", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    async void AiControl_Click(object sender, RoutedEventArgs e)
    {
        options.AiControl = AiControlBox.IsChecked == true;
        options.Save();
        await InstanceManager.SetAiControlAsync(options.AiControl);
    }

    /// Another instance's window changed the app-wide options: show and apply them here too.
    void OtherWindowChangedOptions(MainWindow from)
    {
        if (from == this) return;
        ShowOptions();
        ShowDisplay();
        ApplyOptions();
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
    async Task WatchForegroundAppAsync(string serial, CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                // The event stream reports only later switches; read the app already in front once.
                var dump = await Engine.AdbAsync(serial, ["wait-for-device", "shell", AndroidWatch.ForegroundProbe]);
                if (cancel.IsCancellationRequested) return;
                AppInFront(AndroidWatch.ForegroundPackageFromDump(dump));
                await foreach (var line in AndroidWatch.Lines(serial, AndroidWatch.ForegroundCommand, cancel))
                    AppInFront(AndroidWatch.ForegroundPackageFromEvent(line));
            }
            catch (Exception e) when (!cancel.IsCancellationRequested) { Debug.WriteLine($"Foreground watch ended: {e.Message}"); }
            catch { return; }
            try { await Task.Delay(2000, cancel); } catch (OperationCanceledException) { return; }
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
        ApplyGameSpeed();
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

    /// F8 (InstanceManager.RegisterF8), sent to the MyEmu window used last.
    internal void TogglePots() => pots.Toggle();

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
        GpuPriorityPanel.Visibility = GpuPriority.HasDedicatedGpu ? Visibility.Visible : Visibility.Collapsed;
        GpuPriorityBox.IsChecked = options.GpuPriority;
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
        var gpuPriorityChanged = options.GpuPriority != (GpuPriorityBox.IsChecked == true);
        options.GpuPriority = GpuPriorityBox.IsChecked == true;
        options.Save();
        if (gpuPriorityChanged) GpuPriority.Apply(options.GpuPriority); // app-wide: every instance's engine
        UpdateOptionNotes();
        ShowDisplay(); // a renderer change shows Apply & Restart
        ApplyOptions();
        InstanceManager.ApplyOptionsEverywhere(this);
    }

    void UpdateOptionNotes()
    {
        FpsBox.IsEnabled = RenderScaleBox.IsEnabled = !options.SuperLight;
        RendererNote.Text = engine != null && runningGuestAngle != options.GuestAngle
            ? "Applies when Android restarts (Apply & Restart below)."
            : "Vulkan ran Xerion at the same fps as OpenGL with about half the GPU. Use OpenGL only if a game draws incorrectly.";
    }

    // --- Display and CPU & memory (Mac: DisplayDrawer, PerformanceDrawer's CPU & memory, ApplyChangesFooter)

    bool? listedLandscape; // the orientation ResolutionBox lists

    void ShowDisplay()
    {
        var wasLoading = loadingOptions;
        loadingOptions = true;
        var editable = avdSettings != null && !restarting;
        foreach (var c in new Control[] { OrientationBox, ResolutionBox, WidthBox, HeightBox, DensityBox, PerformanceBox, CoresBox, MemoryBox, SuggestedButton })
            c.IsEnabled = editable;
        DisplayCurrent.Text = "Available once Android has started.";
        if (avdSettings is { } s && draft is { } d)
        {
            DisplayCurrent.Text = $"Now: {s.Width} × {s.Height} · {s.Density} DPI · {s.CpuCores} cores · {s.RamMB / 1024} GB";
            OrientationBox.SelectedIndex = d.IsLandscape ? 0 : 1;
            if (listedLandscape != d.IsLandscape)
            {
                listedLandscape = d.IsLandscape;
                ResolutionBox.Items.Clear();
                foreach (var p in ResolutionPreset.List(d.IsLandscape))
                    ResolutionBox.Items.Add(new ComboBoxItem { Content = $"{p.Name} · {p.Density} DPI", Tag = p });
                ResolutionBox.Items.Add(new ComboBoxItem { Content = "Custom" });
            }
            var size = ResolutionPreset.Matching(d);
            ResolutionBox.SelectedItem = ResolutionBox.Items.Cast<ComboBoxItem>().First(i => Equals(i.Tag, size));
            foreach (var (box, value) in new[] { (WidthBox, d.Width), (HeightBox, d.Height), (DensityBox, d.Density) })
                if (!box.IsKeyboardFocused) box.Text = value.ToString(); // not the one being typed in

            if (PerformanceBox.Items.Count == 0)
            {
                foreach (var p in PerformancePreset.Available(Host))
                    PerformanceBox.Items.Add(new ComboBoxItem { Content = $"{p.Name} · {p.CpuCores} cores, {p.RamMB / 1024} GB", Tag = p });
                PerformanceBox.Items.Add(new ComboBoxItem { Content = "Custom" });
                for (var n = 1; n <= Host.MaxCpuCores; n++) CoresBox.Items.Add(n);
                for (var gb = AvdSettings.MinRamMB / 1024; gb <= Host.MaxRamMB / 1024; gb++) MemoryBox.Items.Add(gb);
            }
            var perf = PerformancePreset.Matching(d);
            PerformanceBox.SelectedItem = PerformanceBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => Equals(i.Tag, perf))
                ?? PerformanceBox.Items[^1];
            CoresBox.SelectedItem = d.CpuCores;
            MemoryBox.SelectedItem = d.RamMB / 1024;
            var suggested = PerformancePreset.Suggested(Host);
            SuggestedNote.Text = $"Suggested for this PC ({Host.MaxCpuCores} threads, {Math.Round(Host.MaxRamMB * 2 / 1024.0)} GB): {suggested.CpuCores} cores, {suggested.RamMB / 1024} GB.";
            SuggestedButton.IsEnabled = editable && (d.CpuCores, d.RamMB) != (suggested.CpuCores, suggested.RamMB);
        }
        var avdChanged = draft != avdSettings;
        var rendererChanged = engine != null && runningGuestAngle != options.GuestAngle;
        ApplyBox.Visibility = avdChanged || rendererChanged || restarting ? Visibility.Visible : Visibility.Collapsed;
        var problem = avdChanged ? draft?.Problem(Host) : null;
        ApplyNote.Text = restarting ? "Restarting Android…" : problem ?? "Android restarts to apply this (about 30 seconds).";
        ApplyNote.Foreground = problem != null ? System.Windows.Media.Brushes.IndianRed : System.Windows.Media.Brushes.LightGray;
        ApplyButton.IsEnabled = problem == null && !restarting && engine != null;
        loadingOptions = wasLoading;
    }

    void Display_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loadingOptions || draft is not { } d) return;
        if (sender == OrientationBox && (OrientationBox.SelectedIndex == 0) != d.IsLandscape) d = d.Rotated();
        else if (sender == ResolutionBox && ResolutionBox.SelectedItem is ComboBoxItem { Tag: ResolutionPreset size }) d = d.With(size);
        else if (sender == PerformanceBox && PerformanceBox.SelectedItem is ComboBoxItem { Tag: PerformancePreset perf }) d = d.With(perf);
        else if (sender == CoresBox && CoresBox.SelectedItem is int cores) d = d with { CpuCores = cores };
        else if (sender == MemoryBox && MemoryBox.SelectedItem is int gb) d = d with { RamMB = gb * 1024 };
        draft = d;
        ShowDisplay();
    }

    void DisplaySize_Changed(object sender, RoutedEventArgs e)
    {
        if (loadingOptions || draft is not { } d) return;
        static int Number(TextBox box, int fallback) => int.TryParse(box.Text, out var n) ? n : fallback;
        draft = d with { Width = Number(WidthBox, d.Width), Height = Number(HeightBox, d.Height), Density = Number(DensityBox, d.Density) };
        ShowDisplay();
    }

    /// Enter takes the number and gives the keyboard back to Android (LostFocus applies it).
    void Number_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        FocusScreen();
        e.Handled = true;
    }

    /// Keys go to Android again (a size box loses focus, which applies it).
    void FocusScreen()
    {
        FocusManager.SetFocusedElement(this, this); // else focusing the window hands focus back to the box
        Keyboard.Focus(this);
    }

    void Suggested_Click(object sender, RoutedEventArgs e)
    {
        if (draft is not { } d) return;
        draft = d.With(PerformancePreset.Suggested(Host));
        ShowDisplay();
    }

    async void Apply_Click(object sender, RoutedEventArgs e) => await RestartAndroidAsync();

    void Revert_Click(object sender, RoutedEventArgs e)
    {
        draft = avdSettings;
        if (options.GuestAngle != runningGuestAngle)
        {
            options.GuestAngle = runningGuestAngle;
            options.Save();
            ShowOptions();
        }
        ShowDisplay();
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
        Status.Text = $"{avd} · {frameWidth}×{frameHeight} · {(received - fpsReceived) / fpsClock.Elapsed.TotalSeconds:0} fps"
            + (notice != null ? $" · {notice}" : "");
        fpsReceived = received;
        fpsClock.Restart();
    }

    // --- Touch: one finger from the left mouse button.

    void Screen_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox) FocusScreen();
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
        if (Keyboard.FocusedElement is TextBox) return; // typing a size in the panel
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
        if (stopping || engine == null) { stopping = true; running.Cancel(); return; }
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
