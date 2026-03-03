import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: BookmarkStore

    var body: some View {
        List(selection: $store.selectedGroup) {
            ForEach(store.groups, id: \.self) { group in
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
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu("Sort") {
                    Picker("Group Sort", selection: $store.groupSort) {
                        ForEach(BookmarkStore.GroupSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                }
            }
        }
    }
}
