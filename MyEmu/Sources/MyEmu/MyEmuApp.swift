import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: InstanceManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built with SwiftPM (no .app bundle), so make it a normal foreground app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { manager?.stopAll() }
    }
}

@main
struct MyEmuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Plain let: the App is created once, and Command Line Tools lack the SwiftUI @State macro plugin.
    private let manager: InstanceManager

    init() {
        SettingsMigration.copyLegacySettings() // before anything reads settings
        manager = InstanceManager()
    }

    var body: some Scene {
        // One window per instance; launching opens instance 1.
        WindowGroup("MyEmu", id: InstanceManager.windowID, for: String.self) { $id in
            InstanceWindow(manager: manager, id: id ?? Instance.main.id)
                .onAppear { delegate.manager = manager }
        } defaultValue: {
            Instance.main.id
        }
        .defaultSize(width: 432 + Sidebar.iconStripWidth, height: 960)
        .commands {
            // New windows come from the Instances drawer; File ▸ New would open a second window
            // onto an instance that's already running.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
