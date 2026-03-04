import SwiftUI
import SwiftData

struct BookmarkTableView: View {
    @Query private var bookmarks: [Bookmark]
    let selectedGroup: String?
    @ObservedObject var store: BookmarkStore
    @State private var tableSelection: Set<PersistentIdentifier> = []

    init(selectedGroup: String?, store: BookmarkStore) {
        self.selectedGroup = selectedGroup
        self.store = store

        if let selectedGroup {
            _bookmarks = Query(
                filter: #Predicate<Bookmark> { $0.group == selectedGroup },
                sort: [
                    SortDescriptor(\Bookmark.group, order: .forward),
                    SortDescriptor(\Bookmark.title, order: .forward)
                ]
            )
        } else {
            _bookmarks = Query(
                sort: [
                    SortDescriptor(\Bookmark.group, order: .forward),
                    SortDescriptor(\Bookmark.title, order: .forward)
                ]
            )
        }
    }

    var body: some View {
        Table(bookmarks, selection: $tableSelection) {
            TableColumn("Title") { bookmark in
                Text(bookmark.title)
                    .lineLimit(1)
            }
            .width(min: 220, ideal: 320)

            TableColumn("URL") { bookmark in
                Text(bookmark.url)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .width(min: 280, ideal: 500)

            TableColumn("Group") { bookmark in
                TextField("Group", text: Binding(
                    get: { bookmark.group },
                    set: { bookmark.group = $0 }
                ))
                .textFieldStyle(.plain)
            }
            .width(min: 160, ideal: 220)
        }
        .onAppear {
            tableSelection = store.selectedBookmarkIDs
        }
        .onChange(of: tableSelection) { _, newValue in
            if store.selectedBookmarkIDs != newValue {
                store.selectedBookmarkIDs = newValue
            }
        }
        .onChange(of: selectedGroup) { _, _ in
            if !tableSelection.isEmpty {
                tableSelection.removeAll()
            }
        }
    }
}
