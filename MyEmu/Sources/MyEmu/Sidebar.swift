import SwiftUI

/// MuMu-style icon strip on the right. Each icon opens (or closes) its feature's settings drawer.
struct Sidebar: View {
    static let iconStripWidth: CGFloat = 52

    let model: EmulatorModel

    var body: some View {
        HStack(spacing: 0) {
            if let drawer = model.selectedDrawer {
                drawerPanel(drawer)
                    .frame(width: Drawer.width)
                    .background(.background)
                Divider()
            }
            iconStrip
        }
    }

    private var iconStrip: some View {
        VStack(spacing: 8) {
            ForEach(Drawer.allCases) { drawer in
                iconButton(drawer.icon, help: "\(drawer.title) (⌘\(drawerIndex(drawer) + 1))", selected: model.selectedDrawer == drawer) {
                    model.toggleDrawer(drawer)
                }
            }
            autoPotsSwitch
            iconButton("square.and.arrow.down", help: "Install APK (or drop APK files on the window)", selected: false) {
                model.chooseAPKs()
            }
            .disabled(!model.androidReady)
            Spacer()
            ForEach([EmulatorModel.NavigationKey.back, .home, .recents], id: \.rawValue) { key in
                iconButton(key.icon, help: key.title, selected: false) { model.navigate(key) }
            }
            Divider().frame(width: 28).padding(.vertical, 4)
            iconButton("arrow.clockwise", help: "Restart Android (⌘R)", selected: false) { model.confirmRestart() }
                .disabled(model.isRestarting)
            shortcuts
        }
        .padding(.vertical, 12)
        .frame(width: Self.iconStripWidth)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    /// ⌘1–3 open drawers, ⌘R restarts, ⌘G / ⌘K drive game keys, whether or not a drawer is open.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(Drawer.allCases.enumerated()), id: \.element) { index, drawer in
                Button("") { model.toggleDrawer(drawer) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Button("") { model.confirmRestart() }
                .keyboardShortcut("r")
                .disabled(model.isRestarting)
            Button("") {
                model.gameKeys.isEnabled.toggle()
                model.focusScreen()
            }
            .keyboardShortcut("g")
            .disabled(model.gameKeys.keymap.isEmpty)
            Button("") {
                model.gameKeys.toggleEditing()
                model.focusScreen()
            }
            .keyboardShortcut("k")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// AutoPots on/off in one click, showing its state; its settings stay in the AutoPots drawer.
    private var autoPotsSwitch: some View {
        let autoPots = model.autoPots
        let (state, color): (String, Color) = !autoPots.isRunning ? ("OFF", .secondary)
            : autoPots.isPaused ? ("PAUSE", .orange) : ("ON", .green)
        return Button {
            if autoPots.isRunning || autoPots.settings.isCalibrated {
                autoPots.toggle()
            } else {
                autoPots.message = "Set up AutoPots for this game first (Auto-detect with HP full)."
                model.selectedDrawer = .autoPots
            }
            model.focusScreen()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "cross.vial.fill").font(.system(size: 14, weight: .medium))
                Text(state).font(.system(size: 8, weight: .heavy))
            }
            .frame(width: 38, height: 38)
            .foregroundStyle(color)
            .background(autoPots.isRunning ? color.opacity(0.18) : .clear, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(autoPots.currentApp == nil)
        .help("AutoPots \(state) (\(autoPots.hotkey.label)): \(autoPots.status)")
        .accessibilityLabel("AutoPots \(state)")
    }

    private func drawerIndex(_ drawer: Drawer) -> Int {
        Drawer.allCases.firstIndex(of: drawer) ?? 0
    }

    private func iconButton(_ symbol: String, help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 38, height: 38)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func drawerPanel(_ drawer: Drawer) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(drawer.title).font(.headline)
                Spacer()
                Button { model.selectedDrawer = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch drawer {
                    case .display: DisplayDrawer(model: model)
                    case .performance: PerformanceDrawer(model: model)
                    case .gameKeys: GameKeysDrawer(model: model)
                    case .device: DeviceDrawer(model: model)
                    case .instances: InstancesDrawer(model: model)
                    case .autoPots: AutoPotsDrawer(model: model)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct DrawerSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// One choice in a drawer's list of presets.
struct RadioRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shown when the Display or Performance draft differs from what Android is running.
struct ApplyChangesFooter: View {
    let model: EmulatorModel

    var body: some View {
        if let draft = model.draft, let settings = model.settings, draft != settings {
            let problem = draft.problem(on: .current)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem ?? "Android restarts to apply this (about 10 seconds).")
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                HStack {
                    Button("Apply & Restart") { model.applyDraft() }
                        .buttonStyle(.borderedProminent)
                        .disabled(problem != nil || model.isRestarting)
                    Button("Revert") { model.draft = settings }
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }
}

extension EmulatorModel {
    /// A binding into the draft settings for drawer controls.
    func draftBinding<Value>(_ keyPath: WritableKeyPath<AvdSettings, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.draft?[keyPath: keyPath] ?? fallback },
                set: { self.draft?[keyPath: keyPath] = $0 })
    }
}
