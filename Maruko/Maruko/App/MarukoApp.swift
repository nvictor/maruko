import SwiftUI

@main
struct MarukoApp: App {
    @StateObject private var updater = AppUpdater()
    @StateObject private var extensionStore = ExtensionFormatStore()

    var body: some Scene {
        WindowGroup {
            ContentView(extensionStore: extensionStore)
        }
        .commands {
            CheckForUpdatesCommands(updater: updater)
        }

        Settings {
            SettingsView(extensionStore: extensionStore)
        }
    }
}
