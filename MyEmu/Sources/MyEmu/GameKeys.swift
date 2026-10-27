import AppKit
import os

private let log = Logger(subsystem: "MyEmu", category: "gamekeys")

/// MEmu-style game keys: an editor that places, moves and saves bindings, and play mode that
/// turns keys into touches.
@MainActor
@Observable
final class GameKeys {
    private static let escapeKeyCode: UInt16 = 53
    private static let deleteKeyCodes: Set<UInt16> = [51, 117] // ⌫ and ⌦
    private static let enabledDefaultsKey = "gameKeysEnabled"
    /// Where "Add Joystick" puts it: bottom-left, where games put their sticks.
    static let newJoystickCenter = NormalizedPoint(x: 0.18, y: 0.72)

    /// Remembered between launches, like MuMu.
    var isEnabled = UserDefaults.standard.bool(forKey: GameKeys.enabledDefaultsKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled { releaseAll() }
            changed()
        }
    }
    /// The Android app in front; its mapping is the one in use and being edited.
    private(set) var currentApp: String?
    /// A text field has the keyboard up: keys go to Android as typing, not game keys.
    private(set) var isTyping = false
    /// The saved mapping for the current app.
    private(set) var keymap: Keymap
    /// The mapping being edited, nil when not editing: Save writes it, Cancel drops it.
    private(set) var draft: Keymap?
    /// Where the next key pressed in the editor gets bound.
    private(set) var pendingTap: NormalizedPoint?
    /// The key or joystick last clicked in the editor.
    private(set) var selection: BindingRef?
    /// An error or hint for the editor.
    private(set) var message: String?

    @ObservationIgnored var client: EmulatorClient?
    @ObservationIgnored var deviceSize: DeviceSize? {
        didSet { mapper = nil }
    }
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Told when game keys start or stop mattering, so typing is only watched while they do.
    @ObservationIgnored var onLiveChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var mapper: KeyTouchMapper?
    /// Running burst-tap loops, by key.
    @ObservationIgnored private var bursts: [UInt16: Task<Void, Never>] = [:]

    init() {
        keymap = Keymap()
    }

    var isEditing: Bool { draft != nil }
    /// What the overlay and the drawer show: the draft while editing.
    var shownKeymap: Keymap { draft ?? keymap }
    var hasUnsavedChanges: Bool { draft.map { $0 != keymap } ?? false }

    /// Game keys are on and the app in front has a mapping.
    var isLive: Bool { isEnabled && currentApp != nil && !keymap.isEmpty }

    /// Your mapping from before mappings were per game, offered while this game has none.
    var canImportLegacyKeymap: Bool {
        currentApp != nil && keymap.isEmpty && FileManager.default.fileExists(atPath: Keymap.legacyFileURL.path)
    }

    func appDidChange(_ package: String) {
        guard package != currentApp else { return }
        releaseAll()
        cancelEdits()
        currentApp = package
        mapper = nil
        do {
            keymap = try Keymap.load(from: Keymap.fileURL(forApp: package))
            message = nil
        } catch {
            keymap = Keymap()
            message = "Couldn't read the mapping for \(package): \(error.localizedDescription)"
            log.error("Keymap load failed for \(package): \(error.localizedDescription)")
        }
        changed()
    }

    func typingDidChange(_ typing: Bool) {
        let typing = typing && isLive // only meaningful for the mapped app in front
        guard typing != isTyping else { return }
        isTyping = typing
        if typing { releaseAll() } // a held game key must not stay pressed while you type
        onChange?()
    }

    func importLegacyKeymap() {
        do {
            let legacy = try Keymap.load(from: Keymap.legacyFileURL)
            mutate { _ in legacy }
        } catch {
            message = "Couldn't read your earlier mapping: \(error.localizedDescription)"
            onChange?()
        }
    }

    // MARK: Editor

    func beginEditing() {
        guard draft == nil else { return }
        guard currentApp != nil else {
            message = "Open a game first; each game gets its own mapping."
            onChange?()
            return
        }
        releaseAll()
        (draft, pendingTap, selection, message) = (keymap, nil, nil, nil)
        changed()
    }

    func saveEdits() {
        guard let edited = draft else { return }
        (draft, pendingTap, selection) = (nil, nil, nil)
        update(edited)
        if !keymap.isEmpty { isEnabled = true } // saving a mapping means "play"
        changed()
    }

    func cancelEdits() {
        guard draft != nil else { return }
        (draft, pendingTap, selection, message) = (nil, nil, nil, nil)
        changed()
    }

    func toggleEditing() {
        if isEditing { saveEdits() } else { beginEditing() }
    }

    /// A click on the screen while editing: selects the key under it, or marks an empty spot for
    /// the next key pressed. ⌥-click puts the WASD joystick there.
    func editorPress(at point: NormalizedPoint, on binding: BindingRef?, placeJoystick: Bool) {
        guard let current = draft else { return }
        if placeJoystick {
            draft = current.withJoystick(at: point)
            (selection, pendingTap) = (.joystick, nil)
        } else if let binding {
            (selection, pendingTap) = (binding, nil)
        } else {
            (selection, pendingTap) = (nil, point)
        }
        message = nil
        onChange?()
    }

    func editorDrag(_ binding: BindingRef, to point: NormalizedPoint) {
        draft = draft?.moving(binding, to: point)
        onChange?()
    }

    func editorRemove(_ binding: BindingRef) {
        mutate { $0.removing(binding) }
        if selection == binding { selection = nil }
    }

    func deleteSelection() {
        if let selection { editorRemove(selection) }
    }

    func addJoystick() {
        mutate { $0.joystick == nil ? $0.withJoystick(at: Self.newJoystickCenter) : $0 }
        selection = .joystick
    }

    func setOpacity(_ value: Double) { mutate { $0.settingOpacity(value) } }
    func setJoystickRadius(_ radius: Double) { mutate { $0.settingJoystickRadius(radius) } }
    func setMode(_ mode: TapMode, forKey keyCode: UInt16) { mutate { $0.settingMode(mode, forKey: keyCode) } }
    func setBurstRate(_ rate: Double) { mutate { $0.settingBurstRate(rate) } }
    func removeTap(forKey keyCode: UInt16) { editorRemove(.tap(keyCode: keyCode)) }
    func removeJoystick() { editorRemove(.joystick) }
    func clear() { mutate { _ in Keymap() } }

    /// While editing, changes go to the draft; otherwise (drawer controls) they're saved right away.
    private func mutate(_ change: (Keymap) -> Keymap) {
        if let current = draft {
            draft = change(current)
            onChange?()
        } else {
            update(change(keymap))
        }
    }

    // MARK: Keys

    /// True when the key was used by game keys or the editor, so it must not also reach Android.
    func handleKey(_ event: NSEvent, down: Bool) -> Bool {
        if isEditing {
            if down, !event.isARepeat { editKey(event) }
            return true
        }
        guard isEnabled, !isTyping, let deviceSize else { return false }
        if let index = keymap.taps.firstIndex(where: { $0.keyCode == event.keyCode }), keymap.taps[index].mode == .burst {
            if down { startBurst(tapIndex: index, device: deviceSize) } else { bursts.removeValue(forKey: event.keyCode)?.cancel() }
            return true
        }
        var current = mapper ?? KeyTouchMapper(keymap: keymap, device: deviceSize)
        let touches = current.handle(keyCode: event.keyCode, down: down)
        mapper = current
        guard let touches else { return false }
        touches.forEach { client?.send(.touch($0)) }
        return true
    }

    /// Lifts any finger held by a game key (window lost focus, mapping changed or turned off).
    func releaseAll() {
        bursts.values.forEach { $0.cancel() } // each loop lifts its finger as it stops
        bursts = [:]
        guard var current = mapper else { return }
        current.releaseAll().forEach { client?.send(.touch($0)) }
        mapper = current
    }

    /// Taps the key's spot over and over until the key is released (its task is cancelled).
    private func startBurst(tapIndex index: Int, device: DeviceSize) {
        let tap = keymap.taps[index]
        guard bursts[tap.keyCode] == nil, let client else { return } // ignore auto-repeat
        let (x, y) = device.pixel(tap.position)
        let id = KeyTouchMapper.firstTapFingerID + Int32(index)
        let timing = Burst.timing(rate: keymap.burstRate)
        bursts[tap.keyCode] = Task {
            while !Task.isCancelled {
                client.send(.touch(TouchPoint(id: id, x: x, y: y, pressed: true)))
                try? await Task.sleep(for: timing.press) // a cancel wakes this early; we still lift below
                client.send(.touch(TouchPoint(id: id, x: x, y: y, pressed: false)))
                try? await Task.sleep(for: timing.release)
            }
        }
    }

    /// Keys while editing: bind the marked spot, re-key the selected key, Esc / Delete.
    private func editKey(_ event: NSEvent) {
        guard let current = draft else { return }
        if event.keyCode == Self.escapeKeyCode {
            (pendingTap, selection) = (nil, nil)
            onChange?()
            return
        }
        if selection != nil, Self.deleteKeyCodes.contains(event.keyCode) {
            deleteSelection()
            return
        }
        if current.joystick != nil, KeyTouchMapper.MacKey.wasd.contains(event.keyCode) {
            message = "W A S D drive the joystick. Pick another key."
            NSSound.beep()
            onChange?()
            return
        }
        let label = Self.label(for: event)
        if let spot = pendingTap {
            draft = current.binding(KeyTap(keyCode: event.keyCode, label: label, position: spot))
            (pendingTap, selection) = (nil, .tap(keyCode: event.keyCode))
        } else if case .tap(let keyCode)? = selection {
            draft = current.rebinding(keyCode, to: event.keyCode, label: label)
            selection = .tap(keyCode: event.keyCode)
        } else {
            NSSound.beep() // click a spot or a key first
            return
        }
        message = nil
        onChange?()
    }

    /// Saves the mapping for the current app.
    private func update(_ newKeymap: Keymap) {
        guard newKeymap != keymap else {
            onChange?()
            return
        }
        guard let currentApp else { return }
        releaseAll()
        keymap = newKeymap
        mapper = nil
        do {
            try newKeymap.save(to: Keymap.fileURL(forApp: currentApp))
            message = nil
        } catch {
            message = "Couldn't save key mapping: \(error.localizedDescription)"
            log.error("Keymap save failed: \(error.localizedDescription)")
        }
        changed()
    }

    /// Redraws the overlay and reports when game keys start or stop mattering.
    private func changed() {
        onChange?()
        guard isLive != wasLive else { return }
        wasLive = isLive
        onLiveChange?(isLive)
    }

    static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let text = event.charactersIgnoringModifiers?.uppercased() ?? ""
            // Function and other special keys come through as control or private-use characters.
            let printable = !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value < 0xF700 }
            return printable ? text : "#\(event.keyCode)"
        }
    }
}
