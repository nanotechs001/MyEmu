import AppKit
import SwiftUI

/// Game-key settings: on/off, the editor, and each key's Hold/Burst mode.
struct GameKeysDrawer: View {
    let model: EmulatorModel
    private var keys: GameKeys { model.gameKeys }

    var body: some View {
        keyboardSection
        gameKeysSection
        if !keys.shownKeymap.isEmpty { keysSection }
    }

    private var keyboardSection: some View {
        DrawerSection("Keyboard") {
            Toggle("Mac keyboard only", isOn: Binding(get: { AndroidOptions.shared.macKeyboardOnly },
                                                      set: { on in
                                                          AndroidOptions.shared.macKeyboardOnly = on
                                                          model.focusScreen()
                                                      }))
                .toggleStyle(.switch)
                .accessibilityLabel("Mac keyboard only") // switch style drops the label
            Text("Hides Android's on-screen keyboard; text fields, passwords, numbers, web forms and in-game boxes take your Mac keyboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var gameKeysSection: some View {
        DrawerSection("Game keys") {
            LabeledContent("Mapping for") {
                Text(keys.currentApp ?? "Waiting for Android…")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(keys.currentApp ?? "")
            }
            if keys.isTyping {
                Label("Paused while you type", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Use game keys", isOn: Binding(get: { keys.isEnabled }, set: { enabled in
                keys.isEnabled = enabled
                model.focusScreen()
            }))
            .toggleStyle(.switch)
            .disabled(keys.keymap.isEmpty)
            .help("⌘G")
            .accessibilityLabel("Use game keys")
            if keys.isEditing {
                HStack {
                    Button("Save Mapping") {
                        keys.saveEdits()
                        model.focusScreen()
                    }
                    .buttonStyle(.borderedProminent)
                    .help("⌘K")
                    Button("Cancel") {
                        keys.cancelEdits()
                        model.focusScreen()
                    }
                }
            } else {
                Button("Edit Key Mapping…") {
                    keys.beginEditing()
                    model.focusScreen()
                }
                .help("⌘K")
            }
            if keys.canImportLegacyKeymap {
                Button("Use My Earlier Mapping Here") {
                    keys.importLegacyKeymap()
                    model.focusScreen()
                }
                .help("Copies the mapping you made before mappings were per game.")
            }
            if let message = keys.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var keysSection: some View {
        DrawerSection("Keys") {
            if keys.shownKeymap.joystick != nil {
                HStack {
                    keyBadge("WASD", burst: false)
                    Text("Joystick").foregroundStyle(.secondary)
                    Spacer()
                    removeButton { keys.removeJoystick() }
                }
            }
            ForEach(keys.shownKeymap.taps, id: \.keyCode) { tap in
                HStack(spacing: 6) {
                    keyBadge(tap.label, burst: tap.mode == .burst)
                    Picker("Mode", selection: Binding(get: { tap.mode }, set: { mode in
                        keys.setMode(mode, forKey: tap.keyCode)
                        model.focusScreen()
                    })) {
                        Text("Hold").tag(TapMode.hold)
                        Text("Burst").tag(TapMode.burst)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    removeButton { keys.removeTap(forKey: tap.keyCode) }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Burst speed: \(Int(keys.shownKeymap.burstRate)) taps/s")
                Slider(value: Binding(get: { keys.shownKeymap.burstRate }, set: { keys.setBurstRate($0) }),
                       in: Burst.rateRange, step: 1) { editing in
                    if !editing { model.focusScreen() }
                }
            }
            .padding(.top, 4)
            KeyTransparencySlider(model: model)
            Button("Clear All Keys…", role: .destructive) { confirmClear() }
        }
    }

    private func keyBadge(_ label: String, burst: Bool) -> some View {
        Text(label)
            .font(.system(.callout, design: .rounded).weight(.bold))
            .frame(minWidth: 40)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(burst ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 6))
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
            model.focusScreen()
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all game keys?"
        alert.informativeText = "This removes every key and the joystick from your mapping."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { keys.clear() }
        model.focusScreen()
    }
}
