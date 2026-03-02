import SwiftUI

struct ImportView: View {
    @ObservedObject var store: BookmarkStore
    @State private var showingClearConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Button("Import HTML") {
                store.showImportPanelAndImport()
            }
            .disabled(store.isImporting)

            Button("Export Group") {
                store.exportSelectedGroup()
            }
            .disabled(store.selectedGroup == nil || store.isExporting)

            Button("Re-Apply Grouping") {
                store.reapplyGroupingRules()
            }
            .disabled(store.isImporting || store.isExporting)

            if store.selectedGroup != nil {
                if store.selectedGroupIsHidden {
                    Button("Unhide Group") {
                        store.unhideSelectedGroup()
                    }
                    .disabled(store.isImporting || store.isExporting)
                } else {
                    Button("Hide Group") {
                        store.hideSelectedGroup()
                    }
                    .disabled(store.isImporting || store.isExporting)
                }
            }

            Button("Clear Database", role: .destructive) {
                showingClearConfirmation = true
            }
            .disabled(store.isImporting || store.isExporting)

            Toggle(
                "Show Hidden",
                isOn: Binding(
                    get: { store.showHiddenGroups },
                    set: { store.setShowHiddenGroups($0) }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()

            if let summary = store.importSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
    }
}
