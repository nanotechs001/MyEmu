import AppKit
import SwiftUI

/// MuMu-style multi-instance manager inside an instance's window.
struct InstancesDrawer: View {
    let model: EmulatorModel

    var body: some View {
        if let manager = model.manager {
            DrawerSection("Instances") {
                InstanceRows(manager: manager, currentID: model.instance.id)
                Text("Each instance is a separate Android with its own apps, sign-ins and data, in its own window. Closing a window stops that Android. Running several at once uses each one's CPU and memory share (Performance drawer).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The window MyEmu opens with (like MuMu's launcher): every Android, started from here.
struct LauncherView: View {
    let manager: InstanceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Androids").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    InstanceRows(manager: manager, currentID: nil)
                }
            }
            Text("Each one is a separate Android with its own apps, sign-ins and game data. Clone copies a stopped Android instantly, everything included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 360)
    }
}

/// Every instance with Start / Show / Stop / Rename / Clone / Delete, plus New.
struct InstanceRows: View {
    let manager: InstanceManager
    /// The instance whose window shows this list (none in the launcher).
    let currentID: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(manager.list.instances) { instance in
            row(instance)
        }
        Button {
            if let instance = manager.create() { open(instance.id) }
        } label: {
            Label("New Instance", systemImage: "plus")
        }
        .disabled(!manager.list.canAdd)
    }

    private func row(_ instance: Instance) -> some View {
        let running = manager.openIDs.contains(instance.id)
        let isThisWindow = instance.id == currentID
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
                Button {
                    clone(instance)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .disabled(running || !manager.list.canAdd)
                .help(running ? "Stop it first to clone it"
                      : manager.list.canAdd ? "Clone: a new Android with this one's apps, sign-ins and data"
                      : "At most \(InstanceList.maxCount) instances")
                .accessibilityLabel("Clone \(instance.name)")
                if instance.number != 1 {
                    Button(role: .destructive) {
                        confirmDelete(instance)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(running)
                    .help(running ? "Stop it first" : "Delete this instance and its Android data")
                    .accessibilityLabel("Delete \(instance.name)")
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

    private func clone(_ instance: Instance) {
        do {
            _ = try manager.clone(instance.id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func confirmDelete(_ instance: Instance) {
        let alert = NSAlert()
        alert.messageText = "Delete \(instance.name)?"
        alert.informativeText = "This permanently deletes its Android, including installed apps, sign-ins and game data."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.delete(instance.id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
