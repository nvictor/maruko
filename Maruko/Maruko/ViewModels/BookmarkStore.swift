import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers
import OSLog
import Combine

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var groups: [String] = []
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

    func refreshGroups() {
        guard let context = modelContext else { return }

        do {
            let allBookmarks = try context.fetch(
                FetchDescriptor<Bookmark>(
                    sortBy: [SortDescriptor(\Bookmark.group, order: .forward)]
                )
            )

            var groupCounts: [String: Int] = [:]
            for bookmark in allBookmarks {
                let group = normalizedGroupName(bookmark.group)
                groupCounts[group, default: 0] += 1
            }

            let existingStates = try context.fetch(FetchDescriptor<GroupState>())
            var statesByName = Dictionary(uniqueKeysWithValues: existingStates.map { ($0.name, $0) })

            var didChangeState = false
            var autoUnhiddenGroups: [String] = []

            for (group, count) in groupCounts {
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

            for state in existingStates where groupCounts[state.name] == nil {
                context.delete(state)
                statesByName.removeValue(forKey: state.name)
                didChangeState = true
            }

            if didChangeState {
                try context.save()
            }

            hiddenGroupNames = Set(statesByName.values.filter(\.isHidden).map(\.name))
            groups = groupCounts.keys
                .filter { showHiddenGroups || !hiddenGroupNames.contains($0) }
                .sorted()

            selectedGroupIsHidden = selectedGroup.map { hiddenGroupNames.contains($0) } ?? false

            if let selectedGroup {
                if groupCounts[selectedGroup] == nil || (!showHiddenGroups && hiddenGroupNames.contains(selectedGroup)) {
                    self.selectedGroup = nil
                    selectedGroupIsHidden = false
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
        guard let context = modelContext, let selectedGroup else { return }

        isExporting = true
        errorMessage = nil

        do {
            let html = try exporter.exportGroup(selectedGroup, context: context)
            let suggestedName = selectedGroup.replacingOccurrences(of: " ", with: "-").lowercased() + ".html"
            try exporter.save(html: html, defaultName: suggestedName)
        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
    }

    func hideSelectedGroup() {
        guard let context = modelContext, let selectedGroup else { return }

        do {
            let count = try bookmarkCount(for: selectedGroup, in: context)
            let state = try fetchOrCreateGroupState(named: selectedGroup, in: context)
            state.isHidden = true
            state.hiddenBookmarkCount = count
            state.lastSeenBookmarkCount = count
            state.updatedAt = Date()
            try context.save()

            importSummary = "Group \(selectedGroup) hidden."
            refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unhideSelectedGroup() {
        guard let context = modelContext, let selectedGroup else { return }

        do {
            let state = try fetchOrCreateGroupState(named: selectedGroup, in: context)
            state.isHidden = false
            state.hiddenBookmarkCount = 0
            state.updatedAt = Date()
            try context.save()

            importSummary = "Group \(selectedGroup) unhidden."
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
            hiddenGroupNames = []
            importSummary = "Database cleared (\(bookmarks.count) bookmarks removed)."
            logger.info("Database cleared. Removed \(bookmarks.count) bookmarks.")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Database clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reapplyGroupingRules() {
        guard let context = modelContext else { return }

        do {
            let changedCount = try applyGroupingPolicy(toAllBookmarksIn: context)
            importSummary = "Re-applied grouping rules (\(changedCount) bookmarks updated)."
            logger.info("Re-applied grouping rules. Updated \(changedCount) bookmarks.")
            refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Re-applying grouping rules failed: \(error.localizedDescription, privacy: .public)")
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
}
