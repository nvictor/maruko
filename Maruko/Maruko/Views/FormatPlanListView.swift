import SwiftUI

/// The format-plan preview list shown by `ChromeExtensionView`.
struct FormatPlanListView: View {
    let plan: FormatPlan
    let filterText: String
    let recencyWindowDays: Int
    let lastFormattedAt: Date?

    var body: some View {
        let duplicates = plan.duplicates(matching: filterText)
        let titleChanges = plan.titleChanges(matching: filterText)
        let recentFolderMoves = plan.recentFolderMoves(matching: filterText)
        let isFiltering = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        List {
            Section("Overview") {
                LabeledContent("Bookmarks", value: "\(plan.totalBookmarks)")
                LabeledContent("Folders", value: "\(plan.totalFolders)")
                if let lastFormattedAt {
                    LabeledContent("Last formatted", value: lastFormattedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if plan.isEmpty {
                    Label("Already clean. Nothing to change.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }

            if isFiltering, duplicates.isEmpty, titleChanges.isEmpty, recentFolderMoves.isEmpty, !plan.isEmpty {
                ContentUnavailableView.search(text: filterText)
            }

            if !duplicates.isEmpty {
                Section(sectionTitle("Duplicates to remove", shown: duplicates.count, total: plan.duplicates.count)) {
                    ForEach(duplicates) { duplicate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(duplicate.title.isEmpty ? duplicate.url : duplicate.title)
                                .lineLimit(1)
                            Text("\(duplicate.folderPath). Kept in \(duplicate.keptFolderPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if !titleChanges.isEmpty {
                Section(sectionTitle("Titles to rewrite", shown: titleChanges.count, total: plan.titleChanges.count)) {
                    ForEach(titleChanges) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.oldTitle)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(change.newTitle)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if plan.reorderedFolderCount > 0 {
                Section("Recently Opened") {
                    Label(
                        "\(plan.reorderedFolderCount) folders will have bookmarks opened in the last \(recencyWindowDays) days moved to the top. The bookmark bar's own row is never reordered.",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }

            if !recentFolderMoves.isEmpty {
                Section(sectionTitle("Moved out of Recent", shown: recentFolderMoves.count, total: plan.recentFolderMoves.count)) {
                    Label(
                        "\(plan.recentFolderMoves.count) bookmarks moved from Recent to Other Bookmarks (kept the 20 most recently opened).",
                        systemImage: "tray.and.arrow.down"
                    )
                    ForEach(recentFolderMoves) { move in
                        Text(move.title.isEmpty ? move.url : move.title)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ label: String, shown: Int, total: Int) -> String {
        shown == total ? "\(label) (\(total))" : "\(label) (\(shown) of \(total))"
    }
}
