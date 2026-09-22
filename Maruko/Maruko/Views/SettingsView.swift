import SwiftUI

/// Maruko's Settings window (Cmd+,). What Maruko does is opinionated by
/// design (Recent curation always runs); deduplication is the one
/// independent, low-risk toggle.
struct SettingsView: View {
    @ObservedObject var extensionStore: ExtensionFormatStore

    var body: some View {
        Form {
            Toggle("Remove Duplicates", isOn: $extensionStore.formatOptions.removeDuplicates)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
