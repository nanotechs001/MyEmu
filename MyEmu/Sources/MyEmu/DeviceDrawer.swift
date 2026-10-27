import SwiftUI

/// Which phone Android presents itself as. Only the root-capable custom-model profile can change it.
struct DeviceDrawer: View {
    let model: EmulatorModel

    private var draft: DeviceIdentity { model.draftIdentity }

    var body: some View {
        DrawerSection("Current") {
            Text(verbatim: model.profile == .playStore
                 ? "Play Store · Google SDK phone"
                 : "Custom model · \(model.identity.marketName) (\(model.identity.model))")
                .font(.callout)
        }
        DrawerSection("Profile") {
            Picker("Profile", selection: Binding(get: { model.draftProfile }, set: { model.draftProfile = $0 })) {
                ForEach(DeviceProfile.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.draftProfile == .playStore
                 ? "Google Play works here, but Google locks this image, so the device model can't change."
                 : "Pick the phone Android reports to games. Google Play Store is added automatically. Its apps and sign-in are separate from the Play Store profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.draftProfile == .customModel {
            DrawerSection("Device model") {
                RadioRow(title: "Google SDK phone (stock)", detail: nil, selected: draft == .stock) {
                    model.draftIdentity = .stock
                }
                ForEach(DevicePreset.all) { preset in
                    RadioRow(title: preset.identity.marketName, detail: preset.identity.model,
                             selected: draft == preset.identity) {
                        model.draftIdentity = preset.identity
                    }
                }
                RadioRow(title: "Custom", detail: nil, selected: isCustom) {}
            }
            DrawerSection("Custom model") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    field("Name", \.marketName)
                    field("Brand", \.brand)
                    field("Maker", \.manufacturer)
                    field("Model", \.model)
                }
                Text("Apps read these as the phone's name, Build.BRAND, Build.MANUFACTURER and Build.MODEL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DrawerSection("Phone") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    phoneField("Number", \.phoneNumber, prompt: "Default")
                    GridRow {
                        Text("IMEI").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            phoneTextField(\.imei, prompt: "Default", width: 128)
                            Button { model.draftPhoneLine.imei = PhoneLine.randomIMEI() } label: {
                                Image(systemName: "dice")
                            }
                            .help("Random valid IMEI")
                            .accessibilityLabel("Random valid IMEI")
                        }
                    }
                }
                Text("The SIM's phone number and the IMEI shown in About phone. Leave empty for the defaults. Android restarts to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        footer
    }

    private var isCustom: Bool {
        draft != .stock && !DevicePreset.all.contains { $0.identity == draft }
    }

    @ViewBuilder private var footer: some View {
        let profileChanged = model.draftProfile != model.profile
        let identityChanged = model.draftProfile == .customModel && model.draftIdentity != model.identity
        let phoneLineChanged = model.draftProfile == .customModel && model.draftPhoneLine != model.phoneLine
        if profileChanged || identityChanged || phoneLineChanged {
            let problem = model.draftProfile == .customModel ? draft.problem ?? model.draftPhoneLine.problem : nil
            VStack(alignment: .leading, spacing: 6) {
                Text(problem ?? (profileChanged
                     ? "Android restarts in the \(model.draftProfile.title) profile. The first switch to Custom model sets up its Android (about a minute)."
                     : phoneLineChanged ? "Android restarts to apply the new phone settings."
                     : "Android restarts once to load the new model."))
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                HStack {
                    Button(profileChanged ? "Apply & Restart" : "Apply") { model.applyDeviceDraft() }
                        .buttonStyle(.borderedProminent)
                        .disabled(problem != nil || model.isRestarting)
                    Button("Revert") {
                        model.draftProfile = model.profile
                        model.draftIdentity = model.identity
                        model.draftPhoneLine = model.phoneLine
                    }
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }

    private func phoneField(_ label: String, _ keyPath: WritableKeyPath<PhoneLine, String>, prompt: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            phoneTextField(keyPath, prompt: prompt, width: 150)
        }
    }

    private func phoneTextField(_ keyPath: WritableKeyPath<PhoneLine, String>, prompt: String, width: CGFloat) -> some View {
        TextField(prompt, text: Binding(get: { model.draftPhoneLine[keyPath: keyPath] },
                                        set: { model.draftPhoneLine[keyPath: keyPath] = $0 }))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: width)
    }

    private func field(_ label: String, _ keyPath: WritableKeyPath<DeviceIdentity, String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: Binding(get: { model.draftIdentity[keyPath: keyPath] },
                                           set: { model.draftIdentity[keyPath: keyPath] = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }
}
