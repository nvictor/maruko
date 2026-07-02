import SwiftUI

/// What the sidebar can select: a detected browser profile (file-based
/// formatting) or the Chrome extension flow (for synced profiles / while
/// the browser runs).
enum SidebarItem: Hashable {
    case profile(BrowserProfile)
    case chromeExtension
}

struct SidebarView: View {
    @ObservedObject var store: BrowserFormatStore
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            if !store.hasFolderAccess {
                Section("Setup") {
                    Button {
                        store.grantAccess()
                    } label: {
                        Label("Grant Access…", systemImage: "folder.badge.questionmark")
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(supportedBrowsers) { browser in
                Section(browser.kind.displayName) {
                    if browser.profiles.isEmpty {
                        Text(store.hasFolderAccess ? "No profiles found" : "Grant access to list profiles")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(browser.profiles) { profile in
                        Label(profile.displayName, systemImage: "person.crop.circle")
                            .tag(SidebarItem.profile(profile))
                    }
                }
            }

            // Visible even without folder access — this path never reads
            // the browser's files.
            Section("Extension") {
                Label("Chrome Extension", systemImage: "puzzlepiece.extension")
                    .tag(SidebarItem.chromeExtension)
            }

            if !comingSoonBrowsers.isEmpty {
                Section("Coming Soon") {
                    ForEach(comingSoonBrowsers) { browser in
                        Label(browser.kind.displayName, systemImage: "hourglass")
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Maruko")
    }

    private var supportedBrowsers: [DetectedBrowser] {
        store.browsers.filter(\.kind.isSupported)
    }

    private var comingSoonBrowsers: [DetectedBrowser] {
        store.browsers.filter { !$0.kind.isSupported }
    }
}
