import SwiftUI

struct ImportView: View {
    @ObservedObject var store: BookmarkStore

    var body: some View {
        HStack(spacing: 12) {
            if let summary = store.importSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
