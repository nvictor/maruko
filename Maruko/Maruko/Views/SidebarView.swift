import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: BookmarkStore

    var body: some View {
        List(selection: $store.selectedGroup) {
            ForEach(store.groups, id: \.self) { group in
                Text(group)
                    .tag(Optional(group))
            }
        }
        .navigationTitle("Groups")
    }
}
