import SwiftUI

/// AutoPots settings for the game in front (autopotsCO built into MyEmu).
struct AutoPotsDrawer: View {
    let model: EmulatorModel

    private var autoPots: AutoPots { model.autoPots }

    private func binding<T>(_ keyPath: WritableKeyPath<AutoPotsSettings, T>) -> Binding<T> {
        Binding(get: { autoPots.settings[keyPath: keyPath] }, set: { autoPots.settings[keyPath: keyPath] = $0 })
    }

    var body: some View {
        if autoPots.currentApp == nil {
            Text("Open a game in Android first. AutoPots keeps its own setup for each game.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            runSection
            calibrationSection
            tappingSection
            triggersSection
            advancedSection
        }
    }

    private var runSection: some View {
        DrawerSection("AutoPots") {
            Toggle("Auto-potion", isOn: Binding(get: { autoPots.isRunning }, set: { $0 ? autoPots.start() : autoPots.stop() }))
                .toggleStyle(.switch)
                .disabled(!autoPots.settings.isCalibrated && !autoPots.isRunning)
            HStack {
                Text("Hotkey").foregroundStyle(.secondary)
                Text(autoPots.isRecordingHotkey ? "Press a key…" : autoPots.hotkey.label)
                    .font(.callout.monospaced().weight(.semibold))
                Spacer()
                Button(autoPots.isRecordingHotkey ? "Cancel" : "Change") {
                    autoPots.isRecordingHotkey.toggle()
                }
            }
            Text(autoPots.isRecordingHotkey
                 ? "Press the key or combination (e.g. F5 or ⌥A). Esc cancels."
                 : "Turns AutoPots on and off in any game. The vial on the sidebar does the same in one click.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(autoPots.status)
                .font(.callout.monospacedDigit())
            if let message = autoPots.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Text("Taps your HP potion when HP drops below 90%. Runs in MyEmu, not in Android, for \(autoPots.currentApp ?? "this game").")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var calibrationSection: some View {
        DrawerSection("HP display") {
            Picker("Game view", selection: binding(\.view)) {
                Text("Orb").tag(AutoPotsSettings.GameView.orb)
                Text("Simple view").tag(AutoPotsSettings.GameView.simple)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button("Auto-detect") { Task { await autoPots.autoDetect() } }
                    .buttonStyle(.borderedProminent)
                Toggle("Adjust on screen", isOn: Binding(
                    get: { autoPots.editing == .calibration },
                    set: { autoPots.editing = $0 ? .calibration : nil }))
                    .toggleStyle(.button)
                    .disabled(!autoPots.settings.isCalibrated && autoPots.settings.potion == nil)
            }
            if autoPots.settings.view == .simple, autoPots.settings.simpleBox != nil {
                Button("Retake HP template") { Task { await autoPots.retakeTemplate() } }
            }
            Text(autoPots.settings.view == .orb
                 ? "With HP full, click Auto-detect: it finds the red half of the HP orb and the potion beside it. Drag the red box or the green dot to fine-tune."
                 : "With HP full and the game in simple view, click Auto-detect: it remembers how \"HP: 100%\" looks and pots when it changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tappingSection: some View {
        DrawerSection("Potion taps") {
            Stepper("Taps per burst: \(autoPots.settings.clicksPerBurst)", value: binding(\.clicksPerBurst),
                    in: AutoPotsSettings.burstRange)
            Stepper("Press time: \(autoPots.settings.pressMs) ms", value: binding(\.pressMs),
                    in: AutoPotsSettings.pressRange, step: autoPots.settings.pressMs < 200 ? 10 : 100)
            Stepper("Randomize: ±\(autoPots.settings.tapRandomPx) px", value: binding(\.tapRandomPx),
                    in: AutoPotsSettings.tapRandomRange)
            Stepper("Confirm readings: \(autoPots.settings.confirmReadings)", value: binding(\.confirmReadings),
                    in: AutoPotsSettings.confirmRange)
            Stepper(autoPots.settings.scanIntervalMs == 0 ? "Scan: every frame (0 ms)" : "Scan interval: \(autoPots.settings.scanIntervalMs) ms",
                    value: binding(\.scanIntervalMs), in: 0...1000, step: 5)
            Text("Readings below 90% in a row before potting (filters skill flashes). Taps stop when HP doesn't move for 3 s (out of potions), and resume when it does.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var triggersSection: some View {
        DrawerSection("Tap triggers") {
            Toggle("Show triggers", isOn: binding(\.showTriggers))
            HStack {
                Button("Add") { autoPots.addTrigger() }
                    .disabled(autoPots.settings.nextTriggerID == nil)
                Toggle("Arrange", isOn: Binding(get: { autoPots.editing == .triggers },
                                                set: { autoPots.editing = $0 ? .triggers : nil }))
                    .toggleStyle(.button)
                    .disabled(autoPots.settings.triggers.isEmpty)
            }
            ForEach(autoPots.settings.triggers) { trigger in
                triggerRow(trigger)
            }
            Text("Place a trigger over a game button. Click it to tap once; hold it to tap rapidly (Lock: keeps tapping after release until clicked again). Potion taps always go first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerRow(_ trigger: TapTrigger) -> some View {
        let id = trigger.id
        func value<T>(_ keyPath: WritableKeyPath<TapTrigger, T>) -> Binding<T> {
            Binding(get: { autoPots.settings.triggers.first { $0.id == id }?[keyPath: keyPath] ?? trigger[keyPath: keyPath] },
                    set: { new in autoPots.updateTrigger(id) { $0[keyPath: keyPath] = new } })
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(Color(nsColor: AutoPotsOverlayView.color(forTrigger: id))).frame(width: 12, height: 12)
                Text("Trigger \(id)").font(.callout.weight(.medium))
                Spacer()
                Picker("Mode", selection: value(\.lock)) {
                    Text("While held").tag(false)
                    Text("Lock").tag(true)
                }
                .labelsHidden()
                .frame(width: 100)
                Button { autoPots.removeTrigger(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove trigger \(id)")
                    .accessibilityLabel("Remove trigger \(id)")
            }
            Stepper("Speed: \(trigger.rate) taps/s", value: value(\.rate), in: TapTrigger.rates)
            Stepper("Size: \(trigger.size) px", value: value(\.size), in: TapTrigger.sizes, step: 4)
            Stepper("Turbo after: \(trigger.holdMs) ms", value: value(\.holdMs), in: TapTrigger.holdDelays, step: 50)
            Stepper("See-through: \(trigger.transparency)%", value: value(\.transparency), in: TapTrigger.transparencies, step: 5)
        }
        .padding(8)
        .background(autoPots.selectedTrigger == id ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
    }

    private var advancedSection: some View {
        DrawerSection("Advanced") {
            Toggle("Custom darkness threshold", isOn: Binding(
                get: { autoPots.settings.customDarkMax != nil },
                set: { autoPots.settings.customDarkMax = $0 ? HpDetector.darkMax : nil }))
            if let dark = autoPots.settings.customDarkMax {
                Stepper("Darkness: \(dark)", value: Binding(get: { dark }, set: { autoPots.settings.customDarkMax = $0 }),
                        in: AutoPotsSettings.darkMaxRange, step: 5)
            }
            Text("Orb view: how dark a pixel must be to count as lost HP. Higher pots sooner, lower waits for deeper black. The built-in value (\(HpDetector.darkMax)) is best for most games.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
