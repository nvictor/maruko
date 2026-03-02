import SwiftUI
import SwiftData

struct BookmarkTableView: View {
    @Query private var bookmarks: [Bookmark]
    @ObservedObject var store: BookmarkStore

    init(selectedGroup: String?, store: BookmarkStore) {
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
        Table(bookmarks, selection: $store.selectedBookmarkIDs) {
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
    }
}
