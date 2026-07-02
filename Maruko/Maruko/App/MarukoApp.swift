import SwiftUI
import SwiftData

@main
struct MarukoApp: App {
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(AppModelContainer.shared)
        .commands {
            CheckForUpdatesCommands(updater: updater)
        }

        Window("Rewrite Rules", id: "rewriteRules") {
            RewriteRulesWindowView()
        }
        .modelContainer(AppModelContainer.shared)
        .defaultSize(width: 780, height: 520)
    }
}
