import SwiftUI
import SwiftData

@main
struct MarukoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(AppModelContainer.shared)
    }
}
