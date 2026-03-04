import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = BookmarkStore()
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            VStack(spacing: 0) {
                if store.importSummary != nil {
                    ImportView(store: store)
                    Divider()
                }

                BookmarkTableView(selectedGroup: store.selectedGroup, store: store)
            }
            .navigationTitle(store.selectedGroup ?? "Bookmarks")
        }
        .onAppear {
            store.configure(context: modelContext)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Import HTML") {
                        store.showImportPanelAndImport()
                    }
                    .disabled(store.isImporting)

                    Button("Apply Grouping") {
                        store.applyGroupingRules()
                    }
                    .disabled(store.isImporting || store.isExporting)

                    Toggle(
                        "Show Hidden",
                        isOn: Binding(
                            get: { store.showHiddenGroups },
                            set: { store.setShowHiddenGroups($0) }
                        )
                    )
                    .disabled(store.isImporting || store.isExporting)

                    Divider()

                    Button("Clear Database", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .disabled(store.isImporting || store.isExporting)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Clear all stored bookmarks?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Database", role: .destructive) {
                store.clearDatabase()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all bookmarks in Maruko.")
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
