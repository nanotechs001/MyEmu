import SwiftUI

/// MEmu-style key-mapping toolbar over the game while editing: transparency, joystick, the
/// selected key's settings, and Save / Cancel.
struct KeymapEditorBar: View {
    let model: EmulatorModel
    private var keys: GameKeys { model.gameKeys }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Key Mapping", systemImage: "keyboard").font(.headline)
                Spacer()
                Button {
                    model.editorBarAtBottom.toggle()
                } label: {
                    Image(systemName: model.editorBarAtBottom ? "arrow.up.to.line" : "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
                .help("Move this bar out of the way")
                Button("Cancel") {
                    keys.cancelEdits()
                    model.focusScreen()
                }
                Button("Save") {
                    keys.saveEdits()
                    model.focusScreen()
                }
                .buttonStyle(.borderedProminent)
                .help("Save this game's mapping (⌘K)")
            }
            KeyTransparencySlider(model: model)
            joystickRow
            selectionRow
            Text(keys.message ?? hint)
                .font(.caption)
                .foregroundStyle(keys.message == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(10)
    }

    private var hint: String {
        keys.pendingTap != nil
            ? "Now press the key for the marked spot."
            : "Click empty space, then press a key to add it · Drag keys to move them · Click a key, then press another key to change it · Right-click or ⌫ deletes · ⌥-click places the WASD joystick"
    }

    @ViewBuilder private var joystickRow: some View {
        if let joystick = keys.shownKeymap.joystick {
            HStack {
                Text("Joystick size").frame(width: 92, alignment: .leading)
                Slider(value: Binding(get: { joystick.radius }, set: { keys.setJoystickRadius($0) }),
                       in: Keymap.joystickRadiusRange) { editing in
                    if !editing { model.focusScreen() }
                }
            }
        } else {
            Button {
                keys.addJoystick()
                model.focusScreen()
            } label: {
                Label("Add WASD Joystick", systemImage: "dpad")
            }
        }
    }

    @ViewBuilder private var selectionRow: some View {
        if case .tap(let keyCode)? = keys.selection,
           let tap = keys.shownKeymap.taps.first(where: { $0.keyCode == keyCode }) {
            HStack {
                Text("Key \(tap.label)").frame(width: 92, alignment: .leading)
                Picker("Mode", selection: Binding(get: { tap.mode }, set: { mode in
                    keys.setMode(mode, forKey: keyCode)
                    model.focusScreen()
                })) {
                    Text("Hold").tag(TapMode.hold)
                    Text("Burst").tag(TapMode.burst)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                deleteSelectionButton
            }
        } else if keys.selection == .joystick {
            HStack {
                Text("WASD joystick").frame(width: 92, alignment: .leading)
                Spacer()
                deleteSelectionButton
            }
        }
    }

    private var deleteSelectionButton: some View {
        Button(role: .destructive) {
            keys.deleteSelection()
            model.focusScreen()
        } label: {
            Image(systemName: "trash")
        }
        .help("Delete (⌫)")
    }
}

/// How see-through the mapped keys are drawn over the game. Saved with each game's mapping.
struct KeyTransparencySlider: View {
    let model: EmulatorModel
    private var keys: GameKeys { model.gameKeys }

    var body: some View {
        HStack {
            Text("Key opacity").frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { keys.shownKeymap.opacity }, set: { keys.setOpacity($0) }),
                   in: Keymap.opacityRange) { editing in
                if !editing { model.focusScreen() }
            }
            Text("\(Int((keys.shownKeymap.opacity * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}
