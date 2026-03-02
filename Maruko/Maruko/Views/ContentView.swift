import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = BookmarkStore()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            VStack(spacing: 0) {
                ImportView(store: store)

                Divider()

                BookmarkTableView(selectedGroup: store.selectedGroup, store: store)
            }
            .navigationTitle(store.selectedGroup ?? "Bookmarks")
        }
        .onAppear {
            store.configure(context: modelContext)
        }
        .alert("Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { newValue in if !newValue { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
    }
}
