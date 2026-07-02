import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: BrowserFormatStore

    var body: some View {
        List(selection: profileSelection) {
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
                            .tag(profile)
                    }
                }
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

    private var profileSelection: Binding<BrowserProfile?> {
        Binding(
            get: { store.selectedProfile },
            set: { store.select($0) }
        )
    }

    private var supportedBrowsers: [DetectedBrowser] {
        store.browsers.filter(\.kind.isSupported)
    }

    private var comingSoonBrowsers: [DetectedBrowser] {
        store.browsers.filter { !$0.kind.isSupported }
    }
}
