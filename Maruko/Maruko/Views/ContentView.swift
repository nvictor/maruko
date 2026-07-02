import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var store = BrowserFormatStore()
    @StateObject private var rulesStore = RewriteRulesStore()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            if let profile = store.selectedProfile {
                BrowserProfileView(store: store, rulesStore: rulesStore, profile: profile)
            } else {
                ContentUnavailableView(
                    "Pick a browser profile",
                    systemImage: "bookmark",
                    description: Text(
                        store.hasFolderAccess
                            ? "Choose a profile in the sidebar to clean up its bookmarks."
                            : "Grant access in the sidebar so Maruko can find your browsers' bookmarks."
                    )
                )
            }
        }
        .onAppear {
            rulesStore.configure(context: modelContext)
            store.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "rewriteRules")
                } label: {
                    Label("Rewrite Rules", systemImage: "wand.and.stars")
                }
                .help("Edit the title rewrite rules applied by Format Bookmarks")
            }
        }
        .alert("Error", isPresented: errorBinding(for: store)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .alert("Error", isPresented: errorBinding(for: rulesStore)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rulesStore.errorMessage ?? "Unknown error")
        }
    }

    private func errorBinding(for store: BrowserFormatStore) -> Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func errorBinding(for store: RewriteRulesStore) -> Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}
