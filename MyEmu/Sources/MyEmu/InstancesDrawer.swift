import AppKit
import SwiftUI

/// MuMu-style multi-instance manager: every Android, its state, and New / Delete.
struct InstancesDrawer: View {
    let model: EmulatorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let manager = model.manager {
            DrawerSection("Instances") {
                ForEach(manager.list.instances) { instance in
                    row(instance, manager: manager)
                }
                Button {
                    if let instance = manager.create() { open(instance.id) }
                } label: {
                    Label("New Instance", systemImage: "plus")
                }
                .disabled(!manager.list.canAdd)
                Text("Each instance is a separate Android with its own apps, sign-ins and data, in its own window. Closing a window stops that Android. Running several at once uses each one's CPU and memory share (Performance drawer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ instance: Instance, manager: InstanceManager) -> some View {
        let running = manager.openIDs.contains(instance.id)
        let isThisWindow = instance.id == model.instance.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(running ? "Running" : "Stopped")
                TextField("Name", text: Binding(get: { instance.name },
                                                set: { manager.rename(instance.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .font(.body.weight(isThisWindow ? .semibold : .regular))
                if isThisWindow { Text("this window").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack {
                if running {
                    if !isThisWindow { Button("Show") { open(instance.id) } }
                    Button("Stop") { manager.stop(instance.id) }
                } else {
                    Button("Start") { open(instance.id) }
                }
                Spacer()
                if instance.number != 1 {
                    Button(role: .destructive) {
                        confirmDelete(instance, manager: manager)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(running)
                    .help(running ? "Stop it first" : "Delete this instance and its Android data")
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private func open(_ id: String) {
        openWindow(id: InstanceManager.windowID, value: id)
    }

    private func confirmDelete(_ instance: Instance, manager: InstanceManager) {
        let alert = NSAlert()
        alert.messageText = "Delete \(instance.name)?"
        alert.informativeText = "This permanently deletes its Android, including installed apps, sign-ins and game data."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.delete(instance.id)
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }
}
