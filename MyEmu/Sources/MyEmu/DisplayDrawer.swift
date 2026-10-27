import SwiftUI

/// Screen resolution: MuMu-style phone/tablet presets or a custom size and DPI.
struct DisplayDrawer: View {
    let model: EmulatorModel

    private static let plainNumber = IntegerFormatStyle<Int>.number.grouping(.never)

    var body: some View {
        if let settings = model.settings, let draft = model.draft {
            DrawerSection("Current") {
                Text(verbatim: "\(String(settings.width)) × \(String(settings.height)) · \(String(settings.density)) DPI")
                    .font(.callout.monospacedDigit())
            }
            DrawerSection("Colors") {
                Text("Color intensity: \(Int((model.colorIntensity * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                Slider(value: Binding(get: { model.colorIntensity }, set: { model.colorIntensity = $0 }),
                       in: EmulatorModel.colorIntensityRange, step: 0.05) { editing in
                    if !editing { model.focusScreen() }
                }
                .accessibilityLabel("Color intensity")
                Text("100% shows Android's colors exactly. Lower it for a softer, less saturated picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DrawerSection("Screen cutout") {
                ForEach(CutoutStyle.allCases) { style in
                    RadioRow(title: style.title, detail: nil, selected: model.cutout == style) { model.cutout = style }
                }
                Text("Draws a phone-style camera cutout so apps can be tested around it. Applies right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DrawerSection("Resolution") {
                Picker("Orientation", selection: Binding(get: { draft.isLandscape }, set: { landscape in
                    if landscape != draft.isLandscape { model.draft = draft.rotated() }
                })) {
                    Text("Landscape").tag(true)
                    Text("Portrait").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ForEach(ResolutionPreset.list(landscape: draft.isLandscape)) { preset in
                    RadioRow(title: preset.name, detail: "\(preset.density) DPI",
                             selected: ResolutionPreset.matching(draft) == preset) {
                        model.draft = draft.with(preset)
                    }
                }
                RadioRow(title: "Custom", detail: nil, selected: ResolutionPreset.matching(draft) == nil) {}
            }
            DrawerSection("Custom size") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    numberRow("Width", model.draftBinding(\.width, fallback: settings.width))
                    numberRow("Height", model.draftBinding(\.height, fallback: settings.height))
                    numberRow("DPI", model.draftBinding(\.density, fallback: settings.density))
                }
                Text("Game-key positions scale with the screen, so your mapping keeps working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ApplyChangesFooter(model: model)
        } else {
            Text("Available once Android has started.").foregroundStyle(.secondary)
        }
    }

    private func numberRow(_ label: String, _ value: Binding<Int>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: value, format: Self.plainNumber)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }
}
