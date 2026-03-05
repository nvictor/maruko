import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = BookmarkStore()
    @State private var showingClearConfirmation = false
    @State private var showingRules = false
    @State private var showingApplyPreview = false
    @State private var applyPreview: RuleApplyPreview?

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
                        applyPreview = store.previewGroupingImpact()
                        showingApplyPreview = applyPreview != nil
                    }
                    .disabled(store.isImporting || store.isExporting)

                    Button("Grouping Rules") {
                        showingRules = true
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
        .confirmationDialog(
            "Apply Grouping",
            isPresented: $showingApplyPreview,
            titleVisibility: .visible
        ) {
            Button("Apply Grouping") {
                store.applyGroupingRules()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let applyPreview {
                Text("This will update \(applyPreview.changedCount) bookmarks and leave \(applyPreview.unchangedCount) unchanged.")
            } else {
                Text("Preview unavailable.")
            }
        }
        .sheet(isPresented: $showingRules) {
            RulesListView(store: store)
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
