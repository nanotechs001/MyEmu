import AppKit
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "MyEmu", category: "app")

/// The sidebar features; each icon opens its own settings drawer.
enum Drawer: String, CaseIterable, Identifiable {
    case display, performance, gameKeys, device, instances, autoPots

    static let width: CGFloat = 270

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Display"
        case .performance: "Performance"
        case .gameKeys: "Game Keys"
        case .device: "Settings"
        case .instances: "Instances"
        case .autoPots: "AutoPots"
        }
    }

    var icon: String {
        switch self {
        case .display: "rectangle.portrait.on.rectangle.portrait"
        case .performance: "gauge.with.dots.needle.67percent"
        case .gameKeys: "gamecontroller"
        case .device: "gearshape"
        case .instances: "square.stack.3d.up"
        case .autoPots: "cross.vial"
        }
    }
}

@MainActor
@Observable
final class EmulatorModel {
    /// Refresh rates outside this range aren't useful (and the engine forbids going above the host's).
    static let refreshRange = 30...240
    static let backgroundFPS = 30
    static let fpsChoices = [240, 180, 165, 144, 120, 90, 60, 30]
    /// How long an engine gets to shut down cleanly before it is killed.
    static let shutdownTimeout: Duration = .seconds(20)

    private enum DefaultsKey {
        static let fpsCap = "fpsCap", lowerFPSInBackground = "lowerFPSInBackground", showFPS = "showFPS"
        static let colorIntensity = "colorIntensity"
        static let profile = "deviceProfile", identity = "deviceIdentity"
        static let phoneLine = "phoneLine", cutout = "cutout", gameSpeed = "gameSpeed"
    }

    /// Which Android this window runs (its AVDs, port and profile).
    let instance: Instance
    @ObservationIgnored weak var manager: InstanceManager?
    var status = "Starting engine…"
    let screen = ScreenView()
    let gameKeys = GameKeys()
    let autoPots = AutoPots()

    /// The refresh rate of the screen the window opened on; the engine renders at this rate.
    private(set) var displayMaxFPS: Int?
    /// What the running Android uses.
    private(set) var settings: AvdSettings?
    /// Edited in the Display and Performance drawers; applied with a restart.
    var draft: AvdSettings?
    private(set) var isRestarting = false
    /// Android has finished booting (the splash screen shows until then, and during restarts).
    private(set) var androidReady = false
    /// The renderer the running Android was started with (nil while stopped).
    private(set) var runningGuestAngle: Bool?
    /// How the running Android reaches the window (nil while starting or stopped).
    private(set) var runningDisplay: DisplayPath?
    /// MyEmu's library is inside the running engine (direct display, engine threads on fast cores).
    private(set) var runningEngineTuned = false
    /// Where the key-mapping toolbar sits over the game, so it never hides the spot you need.
    var editorBarAtBottom = false

    /// Android's frame-rate limit; 0 means the display's maximum.
    var fpsCap: Int {
        didSet {
            UserDefaults.standard.set(fpsCap, forKey: DefaultsKey.fpsCap)
            applyAndroidRate()
        }
    }
    var lowerFPSInBackground: Bool {
        didSet {
            UserDefaults.standard.set(lowerFPSInBackground, forKey: DefaultsKey.lowerFPSInBackground)
            applyAndroidRate()
        }
    }
    static let colorIntensityRange = 0.6...1.0
    var colorIntensity: Double {
        didSet {
            UserDefaults.standard.set(colorIntensity, forKey: DefaultsKey.colorIntensity)
            screen.colorIntensity = Float(colorIntensity)
        }
    }
    var showFPS: Bool {
        didSet {
            UserDefaults.standard.set(showFPS, forKey: DefaultsKey.showFPS)
            screen.showsFPS = showFPS
        }
    }

    /// Which AVD runs: Play Store, or the root-capable image whose device model you can pick.
    private(set) var profile: DeviceProfile
    /// The model the custom-model profile reports.
    private(set) var identity: DeviceIdentity
    /// Edited in the Device drawer; applied with Apply.
    var draftProfile: DeviceProfile
    var draftIdentity: DeviceIdentity
    /// Phone number and IMEI of the custom-model profile; the engine sets them at start.
    private(set) var phoneLine: PhoneLine
    var draftPhoneLine: PhoneLine
    /// Android's screen-cutout emulation, switched live.
    var cutout: CutoutStyle {
        didSet {
            UserDefaults.standard.set(cutout.rawValue, forKey: instance.defaultsKey(DefaultsKey.cutout))
            applyAndroidOptions()
        }
    }

    /// How fast this instance's current game runs (1.0 = normal). Per instance, so each window keeps
    /// its own speed. Injected per game; custom-model profile only. Applies live to the running game.
    var gameSpeed: Double {
        didSet {
            UserDefaults.standard.set(gameSpeed, forKey: instance.defaultsKey(DefaultsKey.gameSpeed))
            applyGameSpeed()
        }
    }

    var selectedDrawer: Drawer? {
        didSet {
            autoPots.isPreviewing = selectedDrawer == .autoPots // live HP reading while its drawer is open
            if selectedDrawer != .autoPots { autoPots.editing = nil }
            if selectedDrawer != nil, oldValue == nil {
                draft = settings
                (draftProfile, draftIdentity, draftPhoneLine) = (profile, identity, phoneLine)
            }
            // Grow the window for the drawer (like MuMu) so the Android screen keeps its size.
            if (selectedDrawer == nil) != (oldValue == nil) {
                let delta = selectedDrawer == nil ? -Drawer.width : Drawer.width
                // After SwiftUI has inserted/removed the drawer, so its own min-size pass doesn't fight ours.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.resizeWindow(byWidth: delta) } }
            }
        }
    }

    @ObservationIgnored private var frames: SharedFrameBuffer?
    @ObservationIgnored private var display: DirectDisplay?
    @ObservationIgnored private var engine: EngineInstance?
    @ObservationIgnored private var client: EmulatorClient?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var rateTask: Task<Void, Never>?
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var occlusionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var aspectLock: AspectLockingWindowDelegate?
    @ObservationIgnored private var typingWatch: Task<Void, Never>?
    @ObservationIgnored private var typingCheck: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// A short message over the screen (APK installs, Play Store problems).
    private(set) var notice: String?
    @ObservationIgnored private var identityTask: Task<Void, Never>?
    @ObservationIgnored private var optionsTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?

    init(instance: Instance) {
        self.instance = instance
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.lowerFPSInBackground: true, DefaultsKey.showFPS: true,
                                     DefaultsKey.colorIntensity: 1.0])
        fpsCap = defaults.integer(forKey: DefaultsKey.fpsCap)
        lowerFPSInBackground = defaults.bool(forKey: DefaultsKey.lowerFPSInBackground)
        showFPS = defaults.bool(forKey: DefaultsKey.showFPS)
        let savedIntensity = defaults.double(forKey: DefaultsKey.colorIntensity)
        colorIntensity = Self.colorIntensityRange.contains(savedIntensity) ? savedIntensity : 1
        let savedProfile = defaults.string(forKey: instance.defaultsKey(DefaultsKey.profile))
            .flatMap(DeviceProfile.init) ?? .playStore
        let savedIdentity = defaults.data(forKey: instance.defaultsKey(DefaultsKey.identity))
            .flatMap { try? JSONDecoder().decode(DeviceIdentity.self, from: $0) } // unreadable → stock
            .flatMap { $0.problem == nil ? $0 : nil } ?? .stock
        (profile, identity) = (savedProfile, savedIdentity)
        (draftProfile, draftIdentity) = (savedProfile, savedIdentity)
        let savedLine = defaults.data(forKey: instance.defaultsKey(DefaultsKey.phoneLine))
            .flatMap { try? JSONDecoder().decode(PhoneLine.self, from: $0) }
            .flatMap { $0.problem == nil ? $0 : nil } ?? PhoneLine()
        (phoneLine, draftPhoneLine) = (savedLine, savedLine)
        cutout = defaults.string(forKey: instance.defaultsKey(DefaultsKey.cutout)).flatMap(CutoutStyle.init) ?? .none
        let savedSpeed = defaults.double(forKey: instance.defaultsKey(DefaultsKey.gameSpeed))
        gameSpeed = AndroidOptions.gameSpeeds.contains(savedSpeed) ? savedSpeed : 1.0
        screen.gameKeys = gameKeys
        screen.autoPots = autoPots
        screen.showsFPS = showFPS
        screen.colorIntensity = Float(colorIntensity)
        gameKeys.onLiveChange = { [weak self] live in self?.watchTyping(live) }
    }

    /// Forgets a deleted instance's own settings.
    private static let instanceSettings = [DefaultsKey.profile, DefaultsKey.identity, DefaultsKey.phoneLine, DefaultsKey.cutout, DefaultsKey.gameSpeed]

    /// A cloned instance starts with the original's profile, phone model, phone line, cutout and game speed.
    static func copySettings(from source: Instance, to target: Instance, defaults: UserDefaults = .standard) {
        for key in instanceSettings {
            if let value = defaults.object(forKey: source.defaultsKey(key)) {
                defaults.set(value, forKey: target.defaultsKey(key))
            }
        }
    }

    static func removeSettings(of instance: Instance) {
        for key in instanceSettings {
            UserDefaults.standard.removeObject(forKey: instance.defaultsKey(key))
        }
    }

    /// The AVD this instance runs for its current profile.
    var avdName: String { instance.avd(for: profile) }

    func toggleDrawer(_ drawer: Drawer) {
        selectedDrawer = selectedDrawer == drawer ? nil : drawer
    }

    // MARK: Engine lifecycle

    func start() {
        guard engine == nil else { return }
        androidReady = false
        SharedFrameBuffer.removeStaleFiles()
        tasks.append(Task { await self.boot() })
    }

    private func boot() async {
        do {
            // The engine must not render faster than the screen the window is on.
            let window = await windowOnScreen()
            let screenFPS = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
            let maxFPS = min(max(screenFPS, Self.refreshRange.lowerBound), Self.refreshRange.upperBound)
            displayMaxFPS = maxFPS
            try Engine.ensureAvd(avdName, profile: profile, templateAvd: Instance.main.avd(for: .playStore))
            status = "Starting engine…"
            await Engine.waitForPreviousEngine(avd: avdName)
            settings = try Engine.readSettings(avd: avdName)
            if let window { observeOcclusion(of: window) }

            let guestAngle = AndroidOptions.shared.guestAngle
            let display = DirectDisplay()
            self.display = display
            let engine = try await Engine.start(avd: avdName, port: instance.grpcPort, refreshRate: maxFPS,
                                                writableSystem: profile.needsWritableSystem, guestAngle: guestAngle,
                                                display: display,
                                                phoneLine: profile == .customModel ? phoneLine : PhoneLine())
            runningGuestAngle = guestAngle
            runningEngineTuned = display != nil && DirectDisplay.library != nil
            let client = try EmulatorClient(port: engine.port, token: engine.token)
            self.engine = engine
            self.client = client
            screen.client = client
            screen.deviceSize = engine.deviceSize
            gameKeys.client = client
            gameKeys.deviceSize = engine.deviceSize
            autoPots.client = client
            autoPots.deviceSize = engine.deviceSize
            fitWindow(to: engine.deviceSize)
            status = "Running"
            if profile == .customModel { applyIdentity(identity, serial: engine.serial) }
            applyAndroidRate()
            tasks.append(Task { await self.watchForegroundApp(serial: engine.serial) })
            watchTyping(gameKeys.isLive)
            applyAndroidOptions()
            tasks.append(Task { await self.waitUntilAndroidReady(serial: engine.serial) })
            tasks.append(Task {
                do {
                    try await Engine.hideCameraCutout(serial: engine.serial)
                } catch {
                    log.error("Could not hide the camera cutout: \(error.localizedDescription)")
                }
            })
            tasks.append(Task.detached {
                do { try await client.run() } catch { log.error("gRPC connection ended: \(error.localizedDescription)") }
            })
            // MuMu's way: gfxstream presents straight into our window. The screenshot stream (a GPU
            // readback and copy per frame) is only the fallback.
            if let display, DirectDisplay.library != nil,
               let contextId = await display.waitForContext(timeout: .seconds(60)) {
                screen.showDirect(contextId: contextId, display: display)
                runningDisplay = .direct
                return
            }
            runningDisplay = .stream
            let frames = try SharedFrameBuffer(capacity: engine.deviceSize.width * engine.deviceSize.height * 4)
            self.frames = frames
            screen.attach(frames)
            await streamUntilStopped(client: client, frames: frames, size: engine.deviceSize)
        } catch {
            status = "Error: \(error.localizedDescription)"
            log.error("Boot failed: \(error.localizedDescription)")
        }
    }

    /// The screen stream can drop while Android is still booting; reconnect until we stop.
    private func streamUntilStopped(client: EmulatorClient, frames: SharedFrameBuffer, size: DeviceSize) async {
        let signal = screen.frameSignal
        while !Task.isCancelled {
            do {
                try await client.streamFrames(into: frames, size: size) { width, height in
                    signal.post(width: width, height: height) // drawn on the next display refresh
                }
            } catch {
                log.info("Frame stream ended, retrying: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(1)) // cancellation also ends the loop
        }
    }

    /// Loads each game's own mapping as you switch apps in Android.
    private func watchForegroundApp(serial: String) async {
        while !Task.isCancelled {
            do {
                for try await line in AndroidWatch.lines(serial: serial, command: AndroidWatch.foregroundCommand) {
                    if let package = AndroidWatch.foregroundPackage(fromEvent: line) {
                        gameKeys.appDidChange(package)
                        autoPots.appDidChange(package)
                        scheduleTypingCheck() // the new app may open with a text box focused
                        applyAndroidRate() // includes lifting Android's 60 fps default for games
                        applyGameSpeed()
                    }
                }
            } catch {
                log.error("Foreground-app watch ended: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(2)) // engine restarting; cancellation ends the loop
        }
    }

    /// Mac-keyboard-only and Lightweight Android, as currently chosen (render scale rides along
    /// with each game's frame rate). Idempotent, so it runs on every boot and on every change.
    func applyAndroidOptions() {
        guard let serial = engine?.serial else { return }
        let options = AndroidOptions.shared
        var commands = [AndroidCommands.quietGraphicsLog, AndroidCommands.keepScreenOrientation, AndroidCommands.keyboardOnly(options.macKeyboardOnly),
                        AndroidCommands.lightweight(options.effectiveLightweight), cutout.command,
                        AndroidCommands.animations(!options.superLight)]
        if runningGuestAngle == true { commands.insert(AndroidCommands.angleWorkarounds, at: 0) } // before any game starts
        optionsTask?.cancel()
        optionsTask = Task {
            do {
                try await Engine.adbShellAfterBoot(serial: serial, commands.joined(separator: "; "))
            } catch {
                log.error("Could not apply Android options: \(error.localizedDescription)")
            }
        }
        applyAndroidRate()
        applyGameSpeed()
    }

    /// Preloads the speed library into the current game and applies the chosen speed. Custom-model
    /// only — the Play Store profile has no writable system to install the library into. Serialized
    /// so quick changes land in order.
    private func applyGameSpeed() {
        guard profile == .customModel, let engine, let game = gameKeys.currentApp,
              AndroidWatch.isValidPackage(game) else { return }
        let speed = gameSpeed
        let previous = speedTask
        speedTask = Task {
            await previous?.value
            do {
                try await Engine.setGameSpeed(speed, package: game, serial: engine.serial)
            } catch {
                log.error("Could not set game speed: \(error.localizedDescription)")
            }
        }
    }

    /// Typing is only watched while game keys are live: it costs Android a little CPU twice a second.
    private func watchTyping(_ live: Bool) {
        typingWatch?.cancel()
        typingWatch = nil
        typingCheck?.cancel()
        gameKeys.typingDidChange(false)
        log.debug("typing watch live=\(live)")
        guard live, let serial = engine?.serial else { return }
        typingWatch = Task {
            while !Task.isCancelled {
                scheduleTypingCheck() // a text box may already be open
                do {
                    for try await line in AndroidWatch.lines(serial: serial, command: AndroidWatch.keyboardEventsCommand)
                    where AndroidWatch.isKeyboardRequest(line) {
                        log.debug("keyboard request: \(line, privacy: .public)")
                        scheduleTypingCheck()
                    }
                } catch {
                    log.error("Typing watch ended: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(2)) // engine restarting; cancellation ends the loop
            }
        }
    }

    /// One check at a time: a burst of requests gets one check, after the last. Only while game keys are live.
    private func scheduleTypingCheck() {
        guard typingWatch != nil, let serial = engine?.serial else { return }
        typingCheck?.cancel()
        typingCheck = Task { await self.checkTyping(serial: serial) }
    }

    /// Asks Android whether a text field has focus, right after a keyboard request and once more later.
    private func checkTyping(serial: String) async {
        for delay in AndroidWatch.typingProbeDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let reading = try? await Engine.adb(serial: serial, ["shell", AndroidWatch.typingProbe]) // next request retries
            guard !Task.isCancelled else { return } // a newer check is running: this answer may be stale
            log.debug("typing check: \(reading ?? "failed", privacy: .public)")
            if let typing = reading.flatMap(AndroidWatch.isTyping(from:)) { gameKeys.typingDidChange(typing) }
        }
    }

    /// The window attaches to a screen a moment after launch, so wait briefly for it.
    private func windowOnScreen() async -> NSWindow? {
        for _ in 0..<40 { // up to 2 s
            if let window = screen.window, window.screen != nil { return window }
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.error("Window never appeared on a screen; using the main screen's refresh rate")
        return nil
    }

    /// Writes the drafted resolution / CPU / memory into the AVD and reboots Android with it.
    func applyDraft() {
        guard let draft, draft != settings, draft.problem(on: .current) == nil else { return }
        Task { await restart(applying: draft) }
    }

    /// Applies the Device drawer: a new profile means the other AVD (engine restart); a new model
    /// on the custom profile is written live and Android reboots once.
    func applyDeviceDraft() {
        guard draftIdentity.problem == nil, draftPhoneLine.problem == nil else { return }
        let profileChanged = draftProfile != profile
        let identityChanged = draftIdentity != identity
        let phoneLineChanged = draftPhoneLine != phoneLine
        guard profileChanged || identityChanged || phoneLineChanged else { return }
        let defaults = UserDefaults.standard
        defaults.set(draftProfile.rawValue, forKey: instance.defaultsKey(DefaultsKey.profile))
        if let data = try? JSONEncoder().encode(draftIdentity) {
            defaults.set(data, forKey: instance.defaultsKey(DefaultsKey.identity))
        }
        if let data = try? JSONEncoder().encode(draftPhoneLine) {
            defaults.set(data, forKey: instance.defaultsKey(DefaultsKey.phoneLine))
        }
        (profile, identity, phoneLine) = (draftProfile, draftIdentity, draftPhoneLine)
        // The engine sets the phone number and IMEI as it starts.
        if profileChanged || (phoneLineChanged && profile == .customModel) {
            restartAndroid()
        } else if profile == .customModel, let serial = engine?.serial {
            applyIdentity(identity, serial: serial)
        }
    }

    private func applyIdentity(_ identity: DeviceIdentity, serial: String) {
        identityTask?.cancel()
        identityTask = Task {
            await addPlayStore(serial: serial)
            status = "Setting device model…"
            do {
                if try await Engine.applyIdentity(identity, serial: serial) {
                    androidReady = false
                    status = "Restarting Android with the new model…"
                    // The frame stream picks the screen back up once Android is up again.
                    _ = try await Engine.adb(serial: serial, ["wait-for-device", "shell",
                        "while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done"])
                }
                try await Engine.setDeviceName(identity.marketName, serial: serial)
                do {
                    _ = try await Engine.applyGuestIMEI(phoneLine.imei, serial: serial)
                } catch {
                    log.error("IMEI apply failed: \(error.localizedDescription)") // the model still applied
                }
                status = "Running"
                androidReady = true
            } catch {
                status = "Couldn't set the device model: \(error.localizedDescription)"
                log.error("Device model apply failed: \(error.localizedDescription)")
            }
            // Custom-model has a writable system, so install the speed library now (one remount at
            // boot), making game speed work on every instance without a remount on the hot path.
            // Idempotent: skips when it's already there.
            do {
                _ = try await Engine.installSpeedLibrary(serial: serial)
            } catch {
                log.error("Speed library install failed: \(error.localizedDescription)")
            }
        }
    }

    /// The custom-model image has no Play Store of its own; MyEmu adds Google's, once per Android.
    private func addPlayStore(serial: String) async {
        status = "Checking Google Play Store…"
        do {
            if try await Engine.ensurePlayStore(serial: serial, sourceAvd: Instance.main.avd(for: .playStore)) {
                show(notice: "Google Play Store added")
            }
        } catch {
            show(notice: "Couldn't add Google Play Store: \(error.localizedDescription)", for: .seconds(10))
            log.error("Play Store install failed: \(error.localizedDescription)")
        }
    }

    /// Installs APK files into this Android (the Install APK button, or files dropped on the window).
    func installAPKs(_ files: [URL]) {
        let batches = ApkInstall.batches(files)
        guard !batches.isEmpty else { return show(notice: "Only .apk files can be installed.") }
        guard let serial = engine?.serial, androidReady else { return show(notice: "Wait for Android to finish starting.") }
        Task {
            for batch in batches {
                let name = batch.count == 1 ? batch[0].lastPathComponent : "\(batch.count) APK files"
                show(notice: "Installing \(name)…", for: nil)
                do {
                    _ = try await Engine.adb(serial: serial, ApkInstall.adbArguments(batch))
                    show(notice: "Installed \(name)")
                } catch {
                    show(notice: "Couldn't install \(name): \(error.localizedDescription)", for: .seconds(10))
                    log.error("APK install failed for \(name): \(error.localizedDescription)")
                }
            }
        }
    }

    func chooseAPKs() {
        let panel = NSOpenPanel()
        panel.title = "Install APK"
        panel.prompt = "Install"
        panel.allowsMultipleSelection = true // an app's split APKs together, or several apps
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        if panel.runModal() == .OK { installAPKs(panel.urls) }
        focusScreen()
    }

    /// nil duration: stays until the next notice.
    private func show(notice text: String, for duration: Duration? = .seconds(4)) {
        notice = text
        noticeTask?.cancel()
        guard let duration else { return }
        noticeTask = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { notice = nil }
        }
    }

    func restartAndroid() {
        Task { await restart(applying: nil) }
    }

    private func restart(applying newSettings: AvdSettings?) async {
        guard !isRestarting else { return }
        isRestarting = true
        androidReady = false
        defer { isRestarting = false }
        status = "Restarting Android…"
        await shutdownEngine()
        if let newSettings {
            do {
                try Engine.write(newSettings, avd: avdName)
            } catch {
                status = "Couldn't save the new settings: \(error.localizedDescription)"
                log.error("AVD config write failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(3)) // let the message be read, then boot as before
            }
        }
        start()
    }

    /// Stops the engine and waits for it to exit, since the same AVD can't run twice.
    private func shutdownEngine() async {
        let process = engine?.process
        stop()
        guard let process else { return }
        let deadline = ContinuousClock.now + Self.shutdownTimeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning {
            log.error("Engine ignored shutdown; killing it")
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func stop() {
        gameKeys.releaseAll()
        autoPots.engineStopped()
        autoPots.client = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        typingWatch?.cancel()
        typingWatch = nil
        typingCheck?.cancel()
        identityTask?.cancel()
        identityTask = nil
        client?.shutdown()
        engine?.process.terminate() // SIGTERM lets QEMU shut the VM down
        engine = nil
        client = nil
        frames = nil
        screen.showDirect(contextId: nil, display: nil)
        display = nil
        runningDisplay = nil
        runningEngineTuned = false
    }

    private func waitUntilAndroidReady(serial: String) async {
        do {
            try await Engine.adbShellAfterBoot(serial: serial, "true")
            androidReady = true
        } catch {
            log.error("Couldn't confirm Android finished booting: \(error.localizedDescription)")
            androidReady = true // don't hide a working screen behind the splash forever
        }
    }

    /// Asks first: restarting closes every app running in this Android.
    func confirmRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart Android?"
        alert.informativeText = "Apps running in \(instance.name) will close. Unsaved game progress may be lost."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { restartAndroid() }
        focusScreen()
    }

    /// Classic Android navigation buttons.
    enum NavigationKey: Int32 {
        case back = 158, home = 172, recents = 580 // Linux KEY_BACK, KEY_HOMEPAGE, KEY_APPSELECT

        var title: String { self == .back ? "Back" : self == .home ? "Home" : "Recent apps" }
        var icon: String { self == .back ? "arrowtriangle.backward" : self == .home ? "circle" : "square" }
    }

    func navigate(_ key: NavigationKey) {
        defer { focusScreen() }
        guard key == .home else {
            client?.send(.androidKey(evdevCode: key.rawValue))
            return
        }
        // The engine drops KEY_HOMEPAGE (Back and App Switch arrive fine), so ask Android directly.
        guard let serial = engine?.serial else { return }
        Task {
            do {
                _ = try await Engine.adb(serial: serial, ["shell", "input keyevent KEYCODE_HOME"])
            } catch {
                log.error("Home key failed: \(error.localizedDescription)")
            }
        }
    }

    /// Keyboard input goes back to Android after using the sidebar.
    func focusScreen() {
        screen.window?.makeFirstResponder(screen)
    }

    // MARK: Frame rate

    /// The rate Android should render at right now.
    var androidFPS: Int? {
        guard let displayMaxFPS else { return nil }
        if isInBackground, lowerFPSInBackground { return min(Self.backgroundFPS, displayMaxFPS) }
        if AndroidOptions.shared.superLight { return min(AndroidOptions.superLightFPS, displayMaxFPS) }
        return fpsCap == 0 ? displayMaxFPS : min(fpsCap, displayMaxFPS)
    }

    /// Applied live through adb; chained so quick changes land in order.
    private func applyAndroidRate() {
        guard let engine, let rate = androidFPS else { return }
        let game = gameKeys.currentApp
        let previous = rateTask
        rateTask = Task {
            await previous?.value
            do {
                try await Engine.setAndroidRefreshRate(rate, serial: engine.serial)
                if let game {
                    try await Engine.setGameMode(fps: rate, renderScale: AndroidOptions.shared.effectiveRenderScale,
                                                 package: game, serial: engine.serial)
                }
            } catch {
                log.error("Could not set Android's frame rate to \(rate): \(error.localizedDescription)")
            }
        }
    }

    /// Minimized or fully covered → background frame rate, to save power while you're elsewhere.
    private func observeOcclusion(of window: NSWindow) {
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.screen.window else { return }
                let hidden = !window.occlusionState.contains(.visible)
                guard hidden != self.isInBackground else { return }
                self.isInBackground = hidden
                self.applyAndroidRate()
            }
        }
    }

    // MARK: Window

    /// Reshapes the window so the Android screen fills it (e.g. after switching to a landscape tablet size).
    private func fitWindow(to device: DeviceSize) {
        guard let window = screen.window, let visible = window.screen?.visibleFrame else { return }
        lockAspect(of: window, to: device)
        let area = screen.bounds.size
        guard area.width > 0, area.height > 0 else { return }
        let aspect = CGFloat(device.width) / CGFloat(device.height)
        guard abs(area.width / area.height - aspect) / aspect > 0.02 else { return }
        let chrome = CGSize(width: window.frame.width - area.width, height: window.frame.height - area.height)
        var height = area.height
        var width = height * aspect
        let scale = min(1, (visible.width - chrome.width) / width, (visible.height - chrome.height) / height)
        width *= scale
        height *= scale
        setWindowSize(CGSize(width: width + chrome.width, height: height + chrome.height))
    }

    /// From now on, resizing keeps the Android area at the device's shape (no black bars).
    private func lockAspect(of window: NSWindow, to device: DeviceSize) {
        if aspectLock == nil || window.delegate !== aspectLock { // SwiftUI may have swapped its delegate back
            aspectLock = AspectLockingWindowDelegate(window: window, screenView: screen)
        }
        aspectLock?.aspect = CGFloat(device.width) / CGFloat(device.height)
    }

    private func resizeWindow(byWidth delta: CGFloat) {
        guard let window = screen.window else { return }
        setWindowSize(CGSize(width: window.frame.width + delta, height: window.frame.height))
    }

    /// Keeps the top-left corner where it is, then nudges the window back onto the screen.
    private func setWindowSize(_ size: CGSize) {
        guard let window = screen.window, let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - size.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - size.height))
        window.setFrame(frame, display: true) // no animation: it would race SwiftUI's layout
    }
}
