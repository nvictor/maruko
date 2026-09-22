import SwiftUI

/// The format-plan preview list shown by `ChromeExtensionView`.
struct FormatPlanListView: View {
    let plan: FormatPlan
    let filterText: String
    let lastFormattedAt: Date?

    var body: some View {
        let duplicates = plan.duplicates(matching: filterText)
        let routineItems = plan.routineItems(matching: filterText)
        let recentItems = plan.recentItems(matching: filterText)
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

            if isFiltering, duplicates.isEmpty, routineItems.isEmpty, recentItems.isEmpty, !plan.isEmpty {
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

            if !routineItems.isEmpty {
                Section(sectionTitle("Routine", shown: routineItems.count, total: plan.routineItems.count, cap: FormatOptions.maxRoutineItems)) {
                    if !plan.routineAdditions.isEmpty || !plan.routineEvictions.isEmpty {
                        moveSummaryLabel(
                            added: plan.routineAdditions.count,
                            evicted: plan.routineEvictions.count,
                            systemImage: "sparkles"
                        )
                    }
                    ForEach(Array(routineItems.enumerated()), id: \.element.id) { index, item in
                        curatedItemRow(index: index, item: item)
                    }
                }
            }

            if !recentItems.isEmpty {
                Section(sectionTitle("Recent", shown: recentItems.count, total: plan.recentItems.count, cap: FormatOptions.maxRecentItems)) {
                    if !plan.recentAdditions.isEmpty || !plan.recentEvictions.isEmpty {
                        moveSummaryLabel(
                            added: plan.recentAdditions.count,
                            evicted: plan.recentEvictions.count,
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    ForEach(Array(recentItems.enumerated()), id: \.element.id) { index, item in
                        curatedItemRow(index: index, item: item)
                    }
                }
            }

            if plan.otherBookmarksReordered {
                Section("Other Bookmarks") {
                    Label(
                        "Its own bookmarks and folders were sorted alphabetically. Nested subfolders elsewhere are left untouched.",
                        systemImage: "arrow.up.arrow.down"
                    )
                }
            }
        }
    }

    private func curatedItemRow(index: Int, item: CuratedFolderItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(index + 1). \(item.title.isEmpty ? item.url : item.title)")
                .lineLimit(1)
            Text(item.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func moveSummaryLabel(added: Int, evicted: Int, systemImage: String) -> some View {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if evicted > 0 { parts.append("\(evicted) moved out") }
        return Label(parts.joined(separator: ", "), systemImage: systemImage)
    }

    private func sectionTitle(_ label: String, shown: Int, total: Int, cap: Int) -> String {
        let count = shown == total ? "\(total) of \(cap)" : "\(shown) of \(total)"
        return "\(label) (\(count))"
    }

    private func sectionTitle(_ label: String, shown: Int, total: Int) -> String {
        shown == total ? "\(label) (\(total))" : "\(label) (\(shown) of \(total))"
    }
}
