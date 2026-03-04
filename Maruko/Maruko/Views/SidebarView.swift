import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: BookmarkStore
    @State private var sidebarSelection: String?

    var body: some View {
        List(selection: $sidebarSelection) {
            ForEach(store.displayedGroups, id: \.self) { group in
                HStack(spacing: 8) {
                    Text(group)
                    Spacer(minLength: 8)
                    Text("\(store.groupCounts[group, default: 0])")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                    .tag(Optional(group))
                    .contextMenu {
                        Button("Export Group") {
                            store.exportGroup(named: group)
                        }
                        .disabled(store.isExporting)

                        if store.isGroupHidden(group) {
                            Button("Unhide Group") {
                                store.unhideGroup(named: group)
                            }
                            .disabled(store.isImporting || store.isExporting)
                        } else {
                            Button("Hide Group") {
                                store.hideGroup(named: group)
                            }
                            .disabled(store.isImporting || store.isExporting)
                        }
                    }
            }
        }
        .onAppear {
            sidebarSelection = store.selectedGroup
        }
        .onChange(of: sidebarSelection) { _, newValue in
            if store.selectedGroup != newValue {
                Task { @MainActor in
                    store.selectedGroup = newValue
                }
            }
        }
        .onChange(of: store.selectedGroup) { _, newValue in
            if sidebarSelection != newValue {
                sidebarSelection = newValue
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Sort Group By", selection: $store.groupSort) {
                        ForEach(BookmarkStore.GroupSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}
