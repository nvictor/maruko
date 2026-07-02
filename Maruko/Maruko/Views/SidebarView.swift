import SwiftUI

/// What the sidebar can select. Chrome Extension is the only destination:
/// Maruko formats bookmarks by having the extension apply changes through
/// chrome.bookmarks, which works with the browser running and Sync on.
enum SidebarItem: Hashable {
    case chromeExtension
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Extension") {
                Label("Chrome Extension", systemImage: "puzzlepiece.extension")
                    .tag(SidebarItem.chromeExtension)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Maruko")
    }
}
