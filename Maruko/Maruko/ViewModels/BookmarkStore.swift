import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers
import OSLog
import Combine

@MainActor
final class BookmarkStore: ObservableObject {
    enum GroupSort: String, CaseIterable, Identifiable {
        case nameAscending
        case nameDescending
        case countDescending
        case countAscending

        var id: String { rawValue }

        var title: String {
            switch self {
            case .nameAscending:
                "Name Ascending"
            case .nameDescending:
                "Name Descending"
            case .countDescending:
                "Count Highest First"
            case .countAscending:
                "Count Lowest First"
            }
        }
    }

    @Published private(set) var groups: [String] = []
    @Published private(set) var groupCounts: [String: Int] = [:]
    @Published var groupSort: GroupSort = .nameAscending
    @Published var selectedGroup: String?
    @Published var selectedBookmarkIDs: Set<PersistentIdentifier> = []
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var importSummary: String?
    @Published var errorMessage: String?
    @Published private(set) var selectedGroupIsHidden = false
    @Published private(set) var showHiddenGroups = false

    private let logger = Logger(subsystem: "com.mellowfleet.Maruko", category: "Import")
    private let importer = BookmarkImporter()
    private let exporter = BookmarkExporter()

    private(set) var modelContext: ModelContext?
    private var hiddenGroupNames: Set<String> = []

    init() {}

    convenience init(modelContext: ModelContext) {
        self.init()
        self.configure(context: modelContext)
    }

    func configure(context: ModelContext) {
        guard modelContext == nil else { return }
        modelContext = context

        do {
            try normalizeStoredGroupsIfNeeded(in: context)
        } catch {
            errorMessage = error.localizedDescription
        }

        refreshGroups()
    }

    func setShowHiddenGroups(_ isEnabled: Bool) {
        showHiddenGroups = isEnabled
        refreshGroups()
    }

    func isGroupHidden(_ group: String) -> Bool {
        hiddenGroupNames.contains(group)
    }

    func refreshGroups() {
        guard let context = modelContext else { return }

        do {
            let allBookmarks = try context.fetch(
                FetchDescriptor<Bookmark>(
                    sortBy: [SortDescriptor(\Bookmark.group, order: .forward)]
                )
            )

            var computedGroupCounts: [String: Int] = [:]
            for bookmark in allBookmarks {
                let group = normalizedGroupName(bookmark.group)
                computedGroupCounts[group, default: 0] += 1
            }

            let existingStates = try context.fetch(FetchDescriptor<GroupState>())
            var statesByName = Dictionary(uniqueKeysWithValues: existingStates.map { ($0.name, $0) })

            var didChangeState = false
            var autoUnhiddenGroups: [String] = []

            for (group, count) in computedGroupCounts {
                if let state = statesByName[group] {
                    if state.isHidden && count > state.hiddenBookmarkCount {
                        state.isHidden = false
                        state.hiddenBookmarkCount = 0
                        state.updatedAt = Date()
                        didChangeState = true
                        autoUnhiddenGroups.append(group)
                    }
                    if state.lastSeenBookmarkCount != count {
                        state.lastSeenBookmarkCount = count
                        state.updatedAt = Date()
                        didChangeState = true
                    }
                } else {
                    let newState = GroupState(
                        name: group,
                        isHidden: false,
                        hiddenBookmarkCount: 0,
                        lastSeenBookmarkCount: count,
                        updatedAt: Date()
                    )
                    context.insert(newState)
                    statesByName[group] = newState
                    didChangeState = true
                }
            }

            for state in existingStates where computedGroupCounts[state.name] == nil {
                context.delete(state)
                statesByName.removeValue(forKey: state.name)
                didChangeState = true
            }

            if didChangeState {
                try context.save()
            }

            hiddenGroupNames = Set(statesByName.values.filter(\.isHidden).map(\.name))
            groupCounts = computedGroupCounts
            let visibleGroups = computedGroupCounts.keys.filter { showHiddenGroups || !hiddenGroupNames.contains($0) }
            groups = visibleGroups.sorted()

            let currentSelection = selectedGroup
            selectedGroupIsHidden = currentSelection.map { hiddenGroupNames.contains($0) } ?? false

            if let currentSelection {
                let shouldClearSelection =
                    computedGroupCounts[currentSelection] == nil ||
                    (!showHiddenGroups && hiddenGroupNames.contains(currentSelection))

                if shouldClearSelection {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.selectedGroup == currentSelection {
                            self.selectedGroup = nil
                            self.selectedGroupIsHidden = false
                        }
                    }
                }
            }

            if !autoUnhiddenGroups.isEmpty {
                let names = autoUnhiddenGroups.sorted().joined(separator: ", ")
                importSummary = "New bookmarks detected in hidden groups: \(names). They were unhidden."
            }

            logger.info(
                "Refreshed groups. bookmarks: \(allBookmarks.count), groups shown: \(self.groups.count), hidden: \(self.hiddenGroupNames.count)"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showImportPanelAndImport() {
        guard let context = modelContext else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import Netscape Bookmarks"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        logger.info("Starting import for file: \(selectedURL.path, privacy: .public)")
        isImporting = true
        errorMessage = nil
        importSummary = nil

        Task {
            do {
                let result = try await importer.import(from: selectedURL, into: context)
                _ = try applyGroupingPolicy(toAllBookmarksIn: context)
                importSummary = "Imported \(result.importedCount) bookmarks, skipped \(result.skippedCount) duplicates."
                logger.info("Import completed. Imported: \(result.importedCount), skipped: \(result.skippedCount)")
                refreshGroups()
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Import failed: \(error.localizedDescription, privacy: .public)")
            }
            isImporting = false
        }
    }

    func exportSelectedGroup() {
        guard let selectedGroup else { return }
        exportGroup(named: selectedGroup)
    }

    func exportGroup(named group: String) {
        guard let context = modelContext else { return }

        isExporting = true
        errorMessage = nil

        do {
            let html = try exporter.exportGroup(group, context: context)
            let suggestedName = group.replacingOccurrences(of: " ", with: "-").lowercased() + ".html"
            try exporter.save(html: html, defaultName: suggestedName)
        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
    }

    func hideSelectedGroup() {
        guard let selectedGroup else { return }
        hideGroup(named: selectedGroup)
    }

    func hideGroup(named group: String) {
        guard let context = modelContext else { return }

        do {
            let count = try bookmarkCount(for: group, in: context)
            let state = try fetchOrCreateGroupState(named: group, in: context)
            state.isHidden = true
            state.hiddenBookmarkCount = count
            state.lastSeenBookmarkCount = count
            state.updatedAt = Date()
            try context.save()

            if selectedGroup == group && !showHiddenGroups {
                selectedGroup = nil
                selectedGroupIsHidden = false
            }

            importSummary = "Group \(group) hidden."
            refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unhideSelectedGroup() {
        guard let selectedGroup else { return }
        unhideGroup(named: selectedGroup)
    }

    func unhideGroup(named group: String) {
        guard let context = modelContext else { return }

        do {
            let state = try fetchOrCreateGroupState(named: group, in: context)
            state.isHidden = false
            state.hiddenBookmarkCount = 0
            state.updatedAt = Date()
            try context.save()

            importSummary = "Group \(group) unhidden."
            refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveSelection(to group: String) {
        guard let context = modelContext, !selectedBookmarkIDs.isEmpty else { return }

        do {
            let descriptor = FetchDescriptor<Bookmark>()
            let all = try context.fetch(descriptor)

            for bookmark in all where selectedBookmarkIDs.contains(bookmark.persistentModelID) {
                bookmark.group = group
            }

            try context.save()
            refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearDatabase() {
        guard let context = modelContext else { return }

        do {
            let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
            for bookmark in bookmarks {
                context.delete(bookmark)
            }

            let groupStates = try context.fetch(FetchDescriptor<GroupState>())
            for state in groupStates {
                context.delete(state)
            }

            try context.save()

            selectedBookmarkIDs.removeAll()
            selectedGroup = nil
            selectedGroupIsHidden = false
            groups = []
            groupCounts = [:]
            hiddenGroupNames = []
            importSummary = "Database cleared (\(bookmarks.count) bookmarks removed)."
            logger.info("Database cleared. Removed \(bookmarks.count) bookmarks.")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Database clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applyGroupingRules() {
        guard let context = modelContext else { return }

        do {
            let changedCount = try applyGroupingPolicy(toAllBookmarksIn: context)
            importSummary = "Applied grouping rules (\(changedCount) bookmarks updated)."
            logger.info("Applied grouping rules. Updated \(changedCount) bookmarks.")
            refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Applying grouping rules failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyGroupingPolicy(toAllBookmarksIn context: ModelContext) throws -> Int {
        let all = try context.fetch(FetchDescriptor<Bookmark>())
        var didChange = false
        var changedCount = 0

        for bookmark in all {
            let classification = BookmarkGroupingPolicy.classify(
                title: bookmark.title,
                url: bookmark.url,
                fallbackGroup: normalizedGroupName(bookmark.group)
            )

            var changedThisBookmark = false
            if bookmark.title != classification.title {
                bookmark.title = classification.title
                didChange = true
                changedThisBookmark = true
            }
            if bookmark.group != classification.group {
                bookmark.group = classification.group
                didChange = true
                changedThisBookmark = true
            }
            if changedThisBookmark {
                changedCount += 1
            }
        }

        if didChange {
            try context.save()
        }

        return changedCount
    }

    private func normalizeStoredGroupsIfNeeded(in context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<Bookmark>())
        var changed = false

        for bookmark in all {
            let normalized = normalizedGroupName(bookmark.group)
            if bookmark.group != normalized {
                bookmark.group = normalized
                changed = true
            }
        }

        if changed {
            try context.save()
        }
    }

    private func fetchOrCreateGroupState(named group: String, in context: ModelContext) throws -> GroupState {
        let descriptor = FetchDescriptor<GroupState>(predicate: #Predicate { $0.name == group })
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let newState = GroupState(name: group)
        context.insert(newState)
        return newState
    }

    private func bookmarkCount(for group: String, in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.group == group })
        return try context.fetchCount(descriptor)
    }

    private func normalizedGroupName(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ungrouped" : trimmed
    }

    var displayedGroups: [String] {
        sortGroups(groups, counts: groupCounts)
    }

    private func sortGroups(_ groupNames: [String], counts: [String: Int]) -> [String] {
        groupNames.sorted { lhs, rhs in
            let lhsCount = counts[lhs, default: 0]
            let rhsCount = counts[rhs, default: 0]
            let nameComparison = lhs.localizedCaseInsensitiveCompare(rhs)

            switch groupSort {
            case .nameAscending:
                return nameComparison == .orderedAscending
            case .nameDescending:
                return nameComparison == .orderedDescending
            case .countDescending:
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return nameComparison == .orderedAscending
            case .countAscending:
                if lhsCount != rhsCount { return lhsCount < rhsCount }
                return nameComparison == .orderedAscending
            }
        }
    }
}
