import Metal
import SwiftUI

/// MuMu-style gaming optimizations that this engine supports.
struct PerformanceDrawer: View {
    let model: EmulatorModel

    private static let gpuName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"
    private static let host = HostLimits.current
    private static let customPreset = "Custom"

    private var options: AndroidOptions { AndroidOptions.shared }

    var body: some View {
        engineSection
        frameRateSection
        renderSection
        lightweightSection
        cpuMemorySection
        DrawerSection("Graphics") {
            Picker("Renderer", selection: Binding(get: { options.guestAngle }, set: { options.guestAngle = $0 })) {
                Text("Vulkan (fast)").tag(true)
                Text("OpenGL").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Vulkan runs games' graphics through Metal via ANGLE: about 40% less CPU and 20% less GPU than OpenGL, which goes through macOS's old OpenGL. Use OpenGL only if a game draws incorrectly.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let running = model.runningGuestAngle, running != options.guestAngle {
                Button("Restart Android to Apply") { model.restartAndroid() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRestarting)
            }
            Label("Host GPU: \(Self.gpuName)", systemImage: "cpu")
            Text("Games render on your Mac's GPU through Metal (Vulkan via MoltenVK). Always on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the running engine is doing, MuMu-style; nothing to set, so it shows live status.
    private var engineSection: some View {
        DrawerSection("Engine") {
            statusRow("Direct display", on: model.runningDisplay == .direct, detail: directDisplayDetail)
            statusRow("Engine threads on fast cores", on: model.runningEngineTuned,
                      detail: "Virtual CPUs and the graphics renderer run at top priority, so macOS keeps them on the performance cores.")
        }
    }

    private var directDisplayDetail: String {
        switch model.runningDisplay {
        case .direct: "Android draws straight into this window on the GPU, as in MuMu: no frame copy, no extra wait."
        case .stream: "Fallback: frames are copied from the GPU each time. Restart Android to try direct display again."
        case nil: "Starts with Android."
        }
    }

    private func statusRow(_ title: String, on: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text("\(title): \(on ? "On" : "Off")")
            } icon: {
                Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(on ? Color.green : Color.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var frameRateSection: some View {
        DrawerSection("Frame rate") {
            let maxFPS = model.displayMaxFPS ?? 60
            Picker("Limit", selection: Binding(get: { model.fpsCap }, set: { cap in
                model.fpsCap = cap
                model.focusScreen()
            })) {
                Text("Max (\(maxFPS) fps)").tag(0)
                ForEach(EmulatorModel.fpsChoices.filter { $0 < maxFPS }, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Text("Applied instantly. Max follows the screen MyEmu opened on (\(maxFPS) Hz).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show FPS counter", isOn: Binding(get: { model.showFPS }, set: { model.showFPS = $0 }))
            Toggle("Drop to \(EmulatorModel.backgroundFPS) fps when hidden",
                   isOn: Binding(get: { model.lowerFPSInBackground }, set: { model.lowerFPSInBackground = $0 }))
                .help("Saves power while MyEmu is minimized or covered by other windows.")
        }
    }

    /// MuMu-style: games draw slightly smaller and Android scales them up, saving Mac GPU time.
    private var renderSection: some View {
        DrawerSection("Game render scale") {
            Picker("Render scale", selection: Binding(get: { options.renderScale }, set: { scale in
                options.renderScale = scale
                model.focusScreen()
            })) {
                ForEach(AndroidOptions.renderScales, id: \.self) { scale in
                    Text(scale >= 1 ? "100% (sharpest)" : "\(Int((scale * 100).rounded()))%").tag(scale)
                }
            }
            .labelsHidden()
            Text("Lower draws games at less than full resolution to free GPU for smoothness (85% used about 10% less GPU at the same fps). Takes effect when a game next starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lightweightSection: some View {
        DrawerSection("Lightweight Android") {
            Toggle("Switch off unused apps", isOn: Binding(get: { options.lightweight }, set: { options.lightweight = $0 }))
                .toggleStyle(.switch)
                .accessibilityLabel("Lightweight Android: switch off unused apps") // switch style drops the label
            Text("Turns off \(Debloat.packages.count) Google apps a game emulator doesn't need — Assistant, Wellbeing, Messages, Phone, Camera, Gmail, YouTube and more — freeing about 600 MB. Play Store, Chrome, sign-in and the keyboard stay. Switch off to bring them all back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cpuMemorySection: some View {
        if let settings = model.settings, let draft = model.draft {
            DrawerSection("CPU & memory") {
                let presets = PerformancePreset.available(on: Self.host)
                Picker("Preset", selection: Binding(
                    get: { PerformancePreset.matching(draft)?.name ?? Self.customPreset },
                    set: { name in
                        if let preset = presets.first(where: { $0.name == name }) { model.draft = draft.with(preset) }
                    })) {
                    ForEach(presets) { Text($0.name).tag($0.name) }
                    Text(Self.customPreset).tag(Self.customPreset)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Stepper("CPU cores: \(draft.cpuCores)",
                        value: model.draftBinding(\.cpuCores, fallback: settings.cpuCores),
                        in: 1...Self.host.maxCpuCores)
                Stepper("Memory: \(draft.ramMB / 1024) GB",
                        value: Binding(get: { draft.ramMB / 1024 }, set: { model.draft?.ramMB = $0 * 1024 }),
                        in: (AvdSettings.minRamMB / 1024)...(Self.host.maxRamMB / 1024))
                let suggestion = PerformancePreset.suggested(for: Self.host)
                HStack {
                    Text("Suggested for this Mac (\(Self.host.performanceCores) fast + \(Self.host.efficiencyCores) efficiency cores, \(Self.host.maxRamMB * 2 / 1024) GB): \(suggestion.cpuCores) cores, \(suggestion.ramMB / 1024) GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Suggested") { model.draft = draft.with(suggestion) }
                        .controlSize(.small)
                        .disabled(draft.cpuCores == suggestion.cpuCores && draft.ramMB == suggestion.ramMB)
                }
            }
            ApplyChangesFooter(model: model)
        }
    }
}
