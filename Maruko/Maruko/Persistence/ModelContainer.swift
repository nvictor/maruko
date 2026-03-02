import SwiftData

enum AppModelContainer {
    static let shared: ModelContainer = {
        let schema = Schema([Bookmark.self, GroupState.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData model container: \(error)")
        }
    }()
}
