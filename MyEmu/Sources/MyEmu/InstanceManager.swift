import SwiftUI

/// Runs each instance in its own window: a window open means that instance's Android is running.
@MainActor
@Observable
final class InstanceManager {
    static let windowID = "instance"

    private(set) var list = InstanceList.load()
    /// Instances whose window is open (their Android is starting or running).
    private(set) var openIDs: Set<String> = []
    @ObservationIgnored private var models: [String: EmulatorModel] = [:]

    init() {
        // App-wide Android options apply to every running instance right away.
        AndroidOptions.shared.onChange = { [weak self] in
            self?.models.values.forEach { $0.applyAndroidOptions() }
        }
    }

    /// The model behind an instance's window, created on first use; nil if the instance was deleted.
    func model(for id: String) -> EmulatorModel? {
        if let model = models[id] { return model }
        guard let instance = list.instance(id: id) else { return nil }
        let model = EmulatorModel(instance: instance)
        model.manager = self
        models[id] = model
        return model
    }

    func name(of id: String) -> String {
        list.instance(id: id)?.name ?? "MyEmu"
    }

    func windowOpened(_ id: String) {
        guard let model = model(for: id) else { return }
        openIDs.insert(id)
        model.start()
    }

    func windowClosed(_ id: String) {
        models.removeValue(forKey: id)?.stop()
        openIDs.remove(id)
    }

    /// Closing the window is what stops an instance (see `windowClosed`).
    func stop(_ id: String) {
        models[id]?.screen.window?.close()
    }

    func stopAll() {
        models.values.forEach { $0.stop() }
        models = [:]
        openIDs = []
    }

    func create() -> Instance? {
        guard let instance = list.add() else { return nil }
        list.save()
        return instance
    }

    func rename(_ id: String, to name: String) {
        list.rename(id: id, to: name)
        list.save()
    }

    /// Deletes a stopped instance and all its Android data (both profiles). Instance 1 stays.
    func delete(_ id: String) throws {
        guard let instance = list.instance(id: id), instance.number != 1, !openIDs.contains(id) else { return }
        for profile in DeviceProfile.allCases { try Engine.deleteAvd(instance.avd(for: profile)) }
        EmulatorModel.removeSettings(of: instance)
        list.remove(id: id)
        list.save()
    }
}

/// One instance's window: its Android screen and sidebar.
struct InstanceWindow: View {
    let manager: InstanceManager
    let id: String

    var body: some View {
        if let model = manager.model(for: id) {
            EmulatorWindowContent(model: model)
                .navigationTitle(manager.name(of: id))
                .onAppear { manager.windowOpened(id) }
                .onDisappear { manager.windowClosed(id) }
        } else {
            Text("This instance was deleted.").padding(40)
        }
    }
}

struct EmulatorWindowContent: View {
    let model: EmulatorModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                ScreenRepresentable(view: model.screen)
                if let notice = model.notice {
                    Text(notice)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                }
                if model.gameKeys.isEditing {
                    KeymapEditorBar(model: model)
                        .frame(maxHeight: .infinity, alignment: model.editorBarAtBottom ? .bottom : .top)
                }
            }
            .frame(minWidth: 120, minHeight: AspectLockingWindowDelegate.minScreenHeight)
            // An overlay, so the splash image's own size never resizes the window.
            .overlay { if !model.androidReady { SplashView(status: model.status) } }
            Divider()
            Sidebar(model: model)
        }
        .dropDestination(for: URL.self) { files, _ in
            model.installAPKs(files)
            return true
        }
    }
}
