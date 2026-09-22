import SwiftUI

struct ContentView: View {
    @ObservedObject var extensionStore: ExtensionFormatStore
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
        .alert("Error", isPresented: extensionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(extensionStore.errorMessage ?? "Unknown error")
        }
    }

    private var extensionErrorBinding: Binding<Bool> {
        Binding(
            get: { extensionStore.errorMessage != nil },
            set: { if !$0 { extensionStore.errorMessage = nil } }
        )
    }
}
