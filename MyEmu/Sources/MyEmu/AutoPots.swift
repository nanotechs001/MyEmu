import AppKit
import Observation
import os

private let log = Logger(subsystem: "MyEmu", category: "autopots")

/// autopotsCO, built into MyEmu: reads the game's HP from the engine's screen (outside Android),
/// taps the potion when it drops below 90%, and runs turbo tap triggers. Nothing runs in Android.
@MainActor
@Observable
final class AutoPots {
    enum Editing: Equatable {
        /// Dragging the HP box and the potion point on the screen.
        case calibration
        /// Placing and moving tap triggers.
        case triggers
    }

    /// Android touch slot for potion taps, clear of the mouse (0), joystick (1) and mapped keys (2…).
    nonisolated static let potionFingerID: Int32 = 9

    @ObservationIgnored var client: EmulatorClient?
    @ObservationIgnored var deviceSize: DeviceSize?
    /// Redraws the on-screen boxes and triggers.
    @ObservationIgnored var onChange: (() -> Void)?

    private(set) var currentApp: String?
    var settings = AutoPotsSettings() {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?()
            updateLoop() // the fast path picks up the change on its next frame
        }
    }
    private(set) var isRunning = false
    /// The game AutoPots was started in; it pauses while another app is in front.
    private(set) var sessionApp: String?
    /// Latest HP reading (0…1), nil when nothing was read.
    private(set) var reading: Float?
    /// Readings run while the drawer is open, so calibration can be checked live (no taps).
    var isPreviewing = false {
        didSet { if isPreviewing != oldValue { updateLoop() } }
    }
    var editing: Editing? {
        didSet {
            onChange?()
            syncRunner() // no potion taps while the HP box is being adjusted
        }
    }
    var selectedTrigger: Int?
    var message: String?
    /// Switches AutoPots on and off from the keyboard (shared by every game and window).
    private(set) var hotkey = AutoPotsHotkey.saved
    /// The next key pressed becomes the hotkey (Esc cancels).
    var isRecordingHotkey = false

    /// Running, but the game it was started in isn't in front.
    var isPaused: Bool { isRunning && currentApp != sessionApp }

    /// A key pressed in this window: records the hotkey, or toggles AutoPots when it matches.
    /// True when the key was used (the game doesn't get it).
    func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?, typingInMac: Bool) -> Bool {
        if isRecordingHotkey {
            isRecordingHotkey = false
            if keyCode != 53 { // Esc cancels
                hotkey = .recorded(keyCode: keyCode, flags: flags, characters: characters)
                hotkey.save()
            }
            return true
        }
        let current = AutoPotsHotkey.saved // another window may have changed it
        hotkey = current
        // A plain-key hotkey must not fire while typing in one of MyEmu's own text fields.
        guard current.matches(keyCode: keyCode, flags: flags), current.hasModifiers || !typingInMac else { return false }
        if !isRunning && !settings.isCalibrated {
            message = "Set up AutoPots for this game first (Auto-detect with HP full)."
            return true
        }
        toggle()
        return true
    }

    /// The fast path (frame stream, HP reading, potion taps), while running or previewing.
    @ObservationIgnored private var runner: AutoPotsRunner?
    @ObservationIgnored private var runnerTask: Task<Void, Never>?
    /// Full-size frames for Auto-detect.
    @ObservationIgnored private var frames: SharedFrameBuffer?

    // MARK: Game and settings

    func appDidChange(_ package: String) {
        guard package != currentApp else { return }
        stopTrigger()
        currentApp = package
        editing = nil
        do {
            settings = try AutoPotsSettings.load(from: AutoPotsSettings.fileURL(forApp: package))
            message = nil
        } catch {
            settings = AutoPotsSettings()
            message = "Couldn't read AutoPots settings for \(package): \(error.localizedDescription)"
        }
        updateLoop() // another game in front pauses tapping; its own setup may differ
    }

    private func save() {
        guard let currentApp else { return }
        do {
            try settings.save(to: AutoPotsSettings.fileURL(forApp: currentApp))
        } catch {
            message = "Couldn't save AutoPots settings: \(error.localizedDescription)"
            log.error("AutoPots save failed: \(error.localizedDescription)")
        }
    }

    // MARK: Running

    var status: String {
        if !settings.isCalibrated { return "Not set up for this game yet: use Auto-detect with HP full." }
        if isRunning, currentApp != sessionApp { return "Paused: \(sessionApp ?? "the game") isn't in front." }
        if editing != nil { return isRunning ? "Paused while you adjust." : "Adjusting." }
        guard let reading else { return isRunning ? "Running: waiting for a reading…" : "Off." }
        let hp = readout(reading)
        return isRunning ? "Running · \(hp)" : "Off · \(hp)"
    }

    /// autopotsCO's readout: the orb only tells full from not full; simple view shows the match.
    func readout(_ value: Float) -> String {
        if value >= AutoPotsRules.triggerLevel { return "HP 100%" }
        switch settings.view {
        case .orb: return "HP not full"
        case .simple: return value < AutoPotsRules.simpleEmptyLevel ? "HP 0%" : "HP \(Int(value * 100))%"
        }
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        guard settings.isCalibrated else {
            message = "Set up AutoPots for this game first (Auto-detect with HP full)."
            return
        }
        guard let currentApp else { return }
        sessionApp = currentApp
        isRunning = true
        message = nil
        updateLoop()
    }

    func stop() {
        isRunning = false
        updateLoop()
    }

    /// The engine went away (restart, stop): nothing to read or tap.
    func engineStopped() {
        stop()
        isPreviewing = false
        stopRunner()
        stopTrigger()
        frames = nil
        reading = nil
    }

    private func updateLoop() {
        if isRunning || isPreviewing, settings.isCalibrated {
            startRunner()
        } else {
            stopRunner()
        }
        syncRunner()
    }

    private func startRunner() {
        guard runner == nil, let client, let deviceSize else { return }
        let runner = AutoPotsRunner(client: client, device: deviceSize, config: runnerConfig) { [weak self] value in
            Task { @MainActor in self?.reading = value }
        }
        self.runner = runner
        runnerTask = Task.detached(priority: .userInitiated) { await runner.run() }
    }

    private func stopRunner() {
        runnerTask?.cancel()
        runnerTask = nil
        runner = nil
        reading = nil
    }

    private var runnerConfig: AutoPotsRunner.Config {
        .init(settings: settings, tapping: isRunning && currentApp == sessionApp && editing != .calibration)
    }

    /// Hands the current settings and on/off state to the fast path (it reads them every frame).
    private func syncRunner() {
        let config = runnerConfig
        runner?.config.withLock { $0 = config }
    }

    // MARK: Reading the screen

    /// A fresh frame from the engine at 1/`scale` size (full size by default, as autopotsCO's
    /// calibration reads it).
    private func capture(scale requested: Int? = nil) async -> (frame: RGBAFrame, scale: Int)? {
        guard let client, let deviceSize else { return nil }
        let scale = requested ?? AutoPotsRules.captureScale(width: deviceSize.width, height: deviceSize.height)
        let (w, h) = (deviceSize.width / scale, deviceSize.height / scale)
        do {
            if frames == nil || frames!.length < w * h * 4 { frames = try SharedFrameBuffer(capacity: w * h * 4) }
            guard let frames, let size = try await client.screenshot(into: frames, width: w, height: h),
                  size.width * scale == deviceSize.width || size.width == w else { return nil }
            let pixels = UnsafeRawBufferPointer(start: frames.base, count: size.width * size.height * 4)
            return (RGBAFrame(width: size.width, height: size.height, pixels: pixels), scale)
        } catch {
            log.error("AutoPots capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The scale the fast path reads at (the simple-view template must be taken at it).
    private var runnerScale: Int? { deviceSize.map(AutoPotsRunner.scale(for:)) }

    // MARK: Auto-detect (autopotsCO's calibration step 0)

    private static let detectSamples = 3
    private static let detectTries = 5
    private static let detectGap: Duration = .milliseconds(200)
    /// A box that reads below this at full HP is nudged down until it doesn't (up to 40 px).
    private static let fullHPGate: Float = 0.97
    private static let maxNudgePx = 40
    /// autopotsCO aims the orb potion 8 px below the computed point.
    private static let orbPotionBiasPx = 8

    /// Finds the HP orb or text and the potion on screen. HP must be full.
    func autoDetect() async {
        let wasRunning = isRunning
        stop()
        defer { if wasRunning { start() } }
        message = "Looking for the HP display…"
        var orbBoxes: [[Int]] = []
        var simpleMaps: [SimpleHp.MapResult] = []
        var last: (frame: RGBAFrame, scale: Int)?
        for attempt in 0..<Self.detectTries {
            if attempt > 0 { try? await Task.sleep(for: Self.detectGap) }
            guard let shot = await capture() else { continue }
            last = shot
            switch settings.view {
            case .orb: if let box = HpDetector.autoMapOrb(shot.frame) { orbBoxes.append(box) }
            case .simple:
                let map = SimpleHp.autoMap(shot.frame)
                if !map.fromFallback { simpleMaps.append(map) }
            }
            if max(orbBoxes.count, simpleMaps.count) >= Self.detectSamples { break }
        }
        guard let (frame, scale) = last else {
            message = "Couldn't read the screen. Is Android running?"
            return
        }
        switch settings.view {
        case .orb: detectOrb(orbBoxes, frame: frame, scale: scale)
        case .simple: await detectSimple(simpleMaps, frame: frame, scale: scale)
        }
    }

    private func detectOrb(_ boxes: [[Int]], frame: RGBAFrame, scale: Int) {
        guard !boxes.isEmpty else {
            let simpleFound = !SimpleHp.autoMap(frame).fromFallback
            message = simpleFound
                ? "No HP orb found, but the simple-view HP text is there: switch Game view to Simple."
                : "No HP orb found. Show the game's normal HUD with the orb visible, then try again."
            return
        }
        var box = (0..<4).map { i in boxes.map { $0[i] }.sorted()[boxes.count / 2] } // median per coordinate
        var nudge = 0
        while HpDetector.hpFractionArc(frame, box[0], box[1], box[2], box[3]) < Self.fullHPGate, nudge < Self.maxNudgePx {
            box[1] += 1
            nudge += 1
        }
        guard HpDetector.hpFractionArc(frame, box[0], box[1], box[2], box[3]) >= Self.fullHPGate else {
            message = "Found the orb, but HP doesn't read full. Fill your HP, then Auto-detect again."
            return
        }
        settings.orbBox = PixelRect(x: box[0] * scale, y: box[1] * scale, width: box[2] * scale, height: box[3] * scale)
        settings.orbPotion = PixelPoint(
            x: Int((Float(box[0]) + HpDetector.potionXPerWidth * Float(box[2])) * Float(scale)),
            y: Int((Float(box[1]) + HpDetector.potionYPerHeight * Float(box[3])) * Float(scale)) + Self.orbPotionBiasPx)
        message = "Found the HP orb and the potion. Check the green dot sits on your HP potion."
    }

    private func detectSimple(_ maps: [SimpleHp.MapResult], frame: RGBAFrame, scale: Int) async {
        guard let map = maps.isEmpty ? nil : maps.sorted(by: { $0.left < $1.left })[maps.count / 2] else {
            message = HpDetector.autoMapOrb(frame) != nil
                ? "No \"HP: 100%\" text found, but the HP orb is there: switch Game view to Orb."
                : "No \"HP: 100%\" text found. Switch the game to simple view with HP full, then try again."
            return
        }
        let box = PixelRect(x: map.left * scale, y: map.top * scale, width: map.width * scale, height: map.height * scale)
        // The template is matched against the fast path's half-size frames, so it's taken at that size.
        guard let (small, smallScale) = await capture(scale: runnerScale),
              let signature = SimpleHp.buildSignature(small, box.x, box.y, box.width, box.height, scale: smallScale) else {
            message = "Found the HP text but couldn't read it clearly. Try again with HP full."
            return
        }
        settings.simpleBox = box
        settings.simplePotion = PixelPoint(x: Int(map.potionX * Float(scale)), y: Int(map.potionY * Float(scale)))
        settings.simpleSignature = SimpleHp.encode(signature)
        message = map.potionFound
            ? "Found the HP text and the potion."
            : "Found the HP text. Drag the green dot onto your HP potion (Adjust on screen)."
    }

    /// Simple view: re-takes the "100%" template after the box was moved by hand. HP must be full.
    func retakeTemplate() async {
        guard let box = settings.simpleBox, let (frame, scale) = await capture(scale: runnerScale) else { return }
        if let signature = SimpleHp.buildSignature(frame, box.x, box.y, box.width, box.height, scale: scale) {
            settings.simpleSignature = SimpleHp.encode(signature)
            message = "Took a new HP template."
        } else {
            message = "No readable HP text in the box. Move it over \"100%\" with HP full."
        }
    }

    // MARK: Tap triggers

    @ObservationIgnored private var triggerTask: Task<Void, Never>?
    @ObservationIgnored private var pressedTrigger: TapTrigger?
    @ObservationIgnored private var turboStarted = false
    /// The trigger whose turbo keeps going after release (lock mode).
    private(set) var latchedTrigger: Int?

    /// A trigger under the point, when triggers are shown for this game.
    func trigger(at p: PixelPoint) -> TapTrigger? {
        guard settings.showTriggers, editing == nil else { return nil }
        return settings.triggers.last { $0.contains(p) }
    }

    /// Mouse pressed on a trigger: tap once on release, or turbo once held for its delay.
    func pressTrigger(_ trigger: TapTrigger) {
        if latchedTrigger == trigger.id { // clicking a latched trigger stops it
            stopTrigger()
            return
        }
        stopTrigger()
        pressedTrigger = trigger
        turboStarted = false
        triggerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(trigger.holdMs, 80))) // turbo never within 80 ms
            guard !Task.isCancelled else { return }
            await self?.runTurbo(trigger)
        }
    }

    func releaseTrigger() {
        guard let trigger = pressedTrigger else { return }
        pressedTrigger = nil
        if turboStarted {
            if trigger.lock { latchedTrigger = trigger.id } else { stopTrigger() }
            return
        }
        triggerTask?.cancel()
        triggerTask = Task { [weak self] in
            await self?.tap(trigger, pressMs: min(max(self?.settings.pressMs ?? 0, 1), 250))
        }
    }

    func stopTrigger() {
        triggerTask?.cancel()
        triggerTask = nil
        latchedTrigger = nil
        turboStarted = false
    }

    private func runTurbo(_ trigger: TapTrigger) async {
        turboStarted = true
        let period = Duration.milliseconds(1000 / trigger.rate)
        let press = AutoPotsRules.turboPressMs(rate: trigger.rate, pressSetting: settings.pressMs)
        let limit = ContinuousClock.now + .seconds(trigger.lock ? 600 : 120) // safety cap
        var lastTap = ContinuousClock.now - .seconds(1)
        while !Task.isCancelled, ContinuousClock.now < limit {
            let now = ContinuousClock.now
            // Potions come first: no turbo during a potion tap, and at most 3/s right after one.
            let potion = runner?.potionClock.withLock { $0 } ?? AutoPotsRunner.PotionClock()
            let nearPotion = now - potion.lastTap < .milliseconds(AutoPotsRules.potionPriorityMs)
            if now >= potion.busyUntil, !nearPotion || now - lastTap >= .milliseconds(AutoPotsRules.slowedTurboIntervalMs) {
                lastTap = now
                await tap(trigger, pressMs: press)
            }
            // Next period, or a short wait when a potion held this tap back (never a busy loop).
            try? await Task.sleep(until: max(lastTap + period, now + .milliseconds(5)))
        }
        if latchedTrigger == trigger.id { latchedTrigger = nil }
    }

    private func tap(_ trigger: TapTrigger, pressMs: Int) async {
        guard let client else { return }
        let (x, y) = (Int32(trigger.center.x), Int32(trigger.center.y))
        client.send(.touch(TouchPoint(id: KeyTouchMapper.mouseFingerID, x: x, y: y, pressed: true)))
        try? await Task.sleep(for: .milliseconds(pressMs)) // a cancel wakes this early; still lift below
        client.send(.touch(TouchPoint(id: KeyTouchMapper.mouseFingerID, x: x, y: y, pressed: false)))
    }

    func addTrigger() {
        guard let id = settings.nextTriggerID, let deviceSize else { return }
        let offset = (id - 1) * 70
        settings.triggers.append(TapTrigger(id: id, center: PixelPoint(x: deviceSize.width / 2 + offset - 140,
                                                                       y: deviceSize.height / 2)))
        selectedTrigger = id
        editing = .triggers
    }

    func removeTrigger(_ id: Int) {
        settings.triggers.removeAll { $0.id == id }
        if selectedTrigger == id { selectedTrigger = nil }
    }

    func updateTrigger(_ id: Int, _ change: (inout TapTrigger) -> Void) {
        guard let i = settings.triggers.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.triggers[i])
    }
}
