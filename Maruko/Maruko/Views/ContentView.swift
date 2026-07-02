import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var rulesStore = RewriteRulesStore()
    @StateObject private var extensionStore = ExtensionFormatStore()
    @State private var selection: SidebarItem? = .chromeExtension

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            switch selection {
            case .chromeExtension:
                ChromeExtensionView(extensionStore: extensionStore)
            case nil:
                ContentUnavailableView(
                    "Chrome Extension",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Choose Chrome Extension in the sidebar to format bookmarks.")
                )
            }
        }
        .onAppear {
            rulesStore.configure(context: modelContext)
            extensionStore.configure(
                rules: { [weak rulesStore] in try rulesStore?.enabledRuleSnapshots() ?? [] }
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
