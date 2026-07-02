import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var store = BrowserFormatStore()
    @StateObject private var rulesStore = RewriteRulesStore()
    @StateObject private var extensionStore = ExtensionFormatStore()
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selection: sidebarSelection)
        } detail: {
            switch selection {
            case .profile(let profile):
                BrowserProfileView(store: store, rulesStore: rulesStore, profile: profile)
            case .chromeExtension:
                ChromeExtensionView(extensionStore: extensionStore, formatStore: store)
            case nil:
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
            extensionStore.configure(
                rules: { [weak rulesStore] in try rulesStore?.enabledRuleSnapshots() ?? [] },
                options: { [weak store] in store?.formatOptions ?? .default }
            )
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
        .alert("Error", isPresented: extensionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(extensionStore.errorMessage ?? "Unknown error")
        }
    }

    /// Keeps `store.selectedProfile` in sync so the file-based flow keeps
    /// working exactly as before.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                if case .profile(let profile) = newValue {
                    store.select(profile)
                } else {
                    store.select(nil)
                }
            }
        )
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

    private var extensionErrorBinding: Binding<Bool> {
        Binding(
            get: { extensionStore.errorMessage != nil },
            set: { if !$0 { extensionStore.errorMessage = nil } }
        )
    }
}
