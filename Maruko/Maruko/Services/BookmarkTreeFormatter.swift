import Foundation

struct DuplicateRemoval: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    let folderPath: String
    let keptFolderPath: String
    /// The node's own id (`raw["id"]`). String in both the Bookmarks file
    /// and the chrome.bookmarks API, so the extension can target the node.
    var nodeID: String?
}

/// A bookmark added to, or evicted from, "Routine" or "Recent".
struct FolderMove: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    /// Why this bookmark moved, e.g. "Banking" or "12 visits in 30 days" for
    /// an addition, "Ranked outside the top 20" for an eviction.
    let reason: String
    /// See `DuplicateRemoval.nodeID`.
    var nodeID: String?
    /// The destination folder's own id.
    var toFolderID: String?
}

/// A bookmark's final position in "Routine" or "Recent", in the order it
/// will be applied.
struct CuratedFolderItem: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    let reason: String
    var nodeID: String?
}

/// A bookmark's recent-history footprint: when it was last opened and how
/// many times Chrome has recorded it being visited. Keyed by normalized URL
/// in the `[String: RecentVisit]` maps `BookmarkTreeFormatter` consumes.
struct RecentVisit: Sendable, Equatable {
    let lastVisitedAt: Date
    let visitCount: Int
}

struct FormatPlan: Sendable {
    let duplicates: [DuplicateRemoval]

    let routineAdditions: [FolderMove]
    let routineEvictions: [FolderMove]
    /// Final URL contents of "Routine", in the order that will be applied.
    let routineItems: [CuratedFolderItem]
    /// True when "Routine"'s order changed even without any addition or
    /// eviction (e.g. two already-resident items swapped rank).
    let routineReordered: Bool

    let recentAdditions: [FolderMove]
    let recentEvictions: [FolderMove]
    /// Final URL contents of "Recent", in the order that will be applied.
    let recentItems: [CuratedFolderItem]
    let recentReordered: Bool

    /// "Other Bookmarks"' own direct children were sorted alphabetically.
    let otherBookmarksReordered: Bool

    let totalBookmarks: Int
    let totalFolders: Int

    var isEmpty: Bool {
        duplicates.isEmpty
            && routineAdditions.isEmpty && routineEvictions.isEmpty && !routineReordered
            && recentAdditions.isEmpty && recentEvictions.isEmpty && !recentReordered
            && !otherBookmarksReordered
    }

    /// Duplicates whose title or URL contains `query` (case-insensitive).
    /// An empty or whitespace-only query matches everything.
    func duplicates(matching query: String) -> [DuplicateRemoval] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return duplicates }
        return duplicates.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    func routineAdditions(matching query: String) -> [FolderMove] { Self.filter(routineAdditions, matching: query) }
    func routineEvictions(matching query: String) -> [FolderMove] { Self.filter(routineEvictions, matching: query) }
    func routineItems(matching query: String) -> [CuratedFolderItem] { Self.filter(routineItems, matching: query) }
    func recentAdditions(matching query: String) -> [FolderMove] { Self.filter(recentAdditions, matching: query) }
    func recentEvictions(matching query: String) -> [FolderMove] { Self.filter(recentEvictions, matching: query) }
    func recentItems(matching query: String) -> [CuratedFolderItem] { Self.filter(recentItems, matching: query) }

    private static func filter(_ moves: [FolderMove], matching query: String) -> [FolderMove] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return moves }
        return moves.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    private static func filter(_ items: [CuratedFolderItem], matching query: String) -> [CuratedFolderItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    /// Human-readable description of what applying this plan will do, for
    /// the apply confirmation dialog. Omits clauses that made no change.
    var confirmationSummary: String {
        var clauses: [String] = []
        if !duplicates.isEmpty { clauses.append("removes \(duplicates.count) duplicates") }
        if !routineAdditions.isEmpty || !routineEvictions.isEmpty {
            clauses.append("updates Routine (\(routineAdditions.count) added, \(routineEvictions.count) moved out)")
        } else if routineReordered {
            clauses.append("sorts Routine")
        }
        if !recentAdditions.isEmpty || !recentEvictions.isEmpty {
            clauses.append("updates Recent (\(recentAdditions.count) added, \(recentEvictions.count) moved out)")
        } else if recentReordered {
            clauses.append("sorts Recent")
        }
        if otherBookmarksReordered { clauses.append("sorts Other Bookmarks alphabetically") }
        let joined = clauses.isEmpty ? "makes no changes" : clauses.joined(separator: ", ")
        let sentence = joined.prefix(1).uppercased() + joined.dropFirst() + "."
        return "\(sentence) The extension applies the changes while Chrome runs, so sync picks them up like ordinary edits. A snapshot of the current tree is saved first. Undo is not available for extension formatting yet."
    }
}

/// The two folders Maruko manages. Must already exist somewhere in the
/// user's Chrome bookmarks, found by exact (case-insensitive) title, the
/// same way "Recent" used to be found. Maruko never creates them.
nonisolated enum RequiredFolder: String, CaseIterable, Sendable {
    case routine = "Routine"
    case recent = "Recent"
}

/// Curates Maruko's three managed folders. Remove duplicate URLs, then
/// classify every remaining bookmark in the tree into "Routine" (curated,
/// on-device heuristic; personal + work sites used constantly) or "Recent"
/// (most accessed in the last 30 days), capping each at 20 and evicting
/// whatever doesn't make the cut back to "Other Bookmarks". Everything else
/// is left exactly where it is; "Other Bookmarks" own direct children are
/// sorted alphabetically as its one folder-specific rule. The trees are
/// mutated in place with the result.
nonisolated enum BookmarkTreeFormatter {
    /// The first folder matching `name` exactly (trimmed, case-insensitive),
    /// found via depth-first search across the given roots in a fixed order
    /// (bookmark bar, other, synced, then any remaining roots as
    /// encountered). If more than one match exists anywhere in the tree,
    /// only the first is used.
    static func findNamedFolder(_ name: String, in trees: [(rootKey: String, node: BookmarkNode)]) -> BookmarkNode? {
        let priority = ["bookmark_bar", "other", "synced"]
        let ordered = priority.compactMap { key in trees.first { $0.rootKey == key } }
            + trees.filter { tree in !priority.contains(tree.rootKey) }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func isMatch(_ node: BookmarkNode) -> Bool {
            node.kind == .folder
                && node.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        func dfs(_ node: BookmarkNode) -> BookmarkNode? {
            if isMatch(node) { return node }
            for child in node.children where child.kind == .folder {
                if let found = dfs(child) { return found }
            }
            return nil
        }
        for tree in ordered {
            if let found = dfs(tree.node) { return found }
        }
        return nil
    }

    /// "Routine" and/or "Recent" folders not found anywhere in the tree.
    /// Callers must check this is empty before calling `curateTree`.
    static func missingRequiredFolders(in trees: [(rootKey: String, node: BookmarkNode)]) -> Set<RequiredFolder> {
        var missing: Set<RequiredFolder> = []
        for folder in RequiredFolder.allCases where findNamedFolder(folder.rawValue, in: trees) == nil {
            missing.insert(folder)
        }
        return missing
    }

    /// Removes URL nodes whose normalized URL already appeared earlier in a
    /// depth-first walk of the roots (bookmark bar first). Folders are never
    /// removed, even when emptied.
    static func removeDuplicates(in roots: [BookmarkNode]) -> [DuplicateRemoval] {
        var keptPathsByURL: [String: String] = [:]
        var removals: [DuplicateRemoval] = []

        func walk(_ folder: BookmarkNode, path: String) {
            folder.children.removeAll { child in
                guard child.kind == .url else { return false }
                let key = child.normalizedURL ?? child.url ?? ""
                guard !key.isEmpty else { return false }

                if let keptPath = keptPathsByURL[key] {
                    removals.append(
                        DuplicateRemoval(
                            title: child.title,
                            url: child.url ?? "",
                            folderPath: path,
                            keptFolderPath: keptPath,
                            nodeID: child.raw["id"] as? String
                        )
                    )
                    return true
                }
                keptPathsByURL[key] = path
                return false
            }

            for child in folder.children where child.kind == .folder {
                walk(child, path: "\(path) / \(child.title)")
            }
        }

        for root in roots {
            walk(root, path: root.title)
        }
        return removals
    }

    /// One remaining URL bookmark under consideration, with its current
    /// parent folder and how it scores against each curated folder.
    private struct Candidate {
        let node: BookmarkNode
        let parent: BookmarkNode
        let match: RoutineMatch?
        let visit: RecentVisit?
    }

    /// A candidate that made a folder's top-N cut, carrying the reason
    /// shown in the plan preview.
    private struct RankedItem {
        let node: BookmarkNode
        let parent: BookmarkNode
        let reason: String
    }

    /// `rootKey` follows the Bookmarks-file naming convention
    /// ("bookmark_bar", "other", "synced") that `ChromeBookmarkTreeAdapter`
    /// maps chrome.bookmarks roots onto. Requires "Routine" and "Recent" to
    /// already exist in `trees` — check `missingRequiredFolders` first.
    static func curateTree(
        trees: [(rootKey: String, node: BookmarkNode)],
        recentVisits: [String: RecentVisit] = [:],
        options: FormatOptions = .default
    ) -> FormatPlan {
        let roots = trees.map(\.node)
        let duplicates = options.removeDuplicates ? removeDuplicates(in: roots) : []

        func totals() -> (bookmarks: Int, folders: Int) {
            var totalBookmarks = 0
            var totalFolders = 0
            for root in roots {
                visit(root) { node in
                    switch node.kind {
                    case .url: totalBookmarks += 1
                    case .folder: totalFolders += 1
                    }
                }
            }
            return (totalBookmarks, max(0, totalFolders - roots.count))
        }

        guard let routineFolder = findNamedFolder(RequiredFolder.routine.rawValue, in: trees),
              let recentFolder = findNamedFolder(RequiredFolder.recent.rawValue, in: trees) else {
            let (bookmarks, folders) = totals()
            return FormatPlan(
                duplicates: duplicates,
                routineAdditions: [], routineEvictions: [], routineItems: [], routineReordered: false,
                recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
                otherBookmarksReordered: false,
                totalBookmarks: bookmarks, totalFolders: folders
            )
        }
        let otherRoot = trees.first(where: { $0.rootKey == "other" })?.node

        // Collect every remaining URL bookmark, tree-wide, with its current
        // parent. "Routine" and "Recent"'s own subfolders are left
        // completely untouched: walk their direct URL children (candidates
        // for keep/evict) but never recurse into a subfolder living inside
        // them.
        var candidates: [Candidate] = []
        func collect(_ folder: BookmarkNode) {
            let isManaged = folder === routineFolder || folder === recentFolder
            for child in folder.children {
                switch child.kind {
                case .url:
                    candidates.append(
                        Candidate(
                            node: child,
                            parent: folder,
                            match: RoutineClassifier.classify(url: child.url, title: child.title),
                            visit: child.normalizedURL.flatMap { recentVisits[$0] }
                        )
                    )
                case .folder:
                    if isManaged { continue }
                    collect(child)
                }
            }
        }
        for root in roots { collect(root) }

        // Routine takes precedence: a bookmark matching a routine category
        // counts only toward Routine, even if it also has recent-visit data.
        let routineCandidates = candidates.filter { $0.match != nil }
        let recentCandidates = candidates.filter { $0.match == nil && $0.visit != nil }

        let rankedRoutine = routineCandidates
            .sorted { a, b in
                if a.match!.strength != b.match!.strength { return a.match!.strength > b.match!.strength }
                let visitA = a.visit?.visitCount ?? 0
                let visitB = b.visit?.visitCount ?? 0
                if visitA != visitB { return visitA > visitB }
                return a.node.title.localizedCaseInsensitiveCompare(b.node.title) == .orderedAscending
            }
            .prefix(FormatOptions.maxRoutineItems)
            .map { RankedItem(node: $0.node, parent: $0.parent, reason: $0.match!.label) }

        let rankedRecent = recentCandidates
            .sorted { a, b in
                if a.visit!.visitCount != b.visit!.visitCount { return a.visit!.visitCount > b.visit!.visitCount }
                return a.visit!.lastVisitedAt > b.visit!.lastVisitedAt
            }
            .prefix(FormatOptions.maxRecentItems)
            .map { RankedItem(node: $0.node, parent: $0.parent, reason: Self.recentReason($0.visit!)) }

        let routineResult = applyFolderCuration(
            target: routineFolder,
            kept: Array(rankedRoutine),
            otherRoot: otherRoot,
            evictionReason: { node in
                RoutineClassifier.classify(url: node.url, title: node.title) != nil
                    ? "Ranked outside the top \(FormatOptions.maxRoutineItems)"
                    : "No longer matches a routine category"
            }
        )
        let recentResult = applyFolderCuration(
            target: recentFolder,
            kept: Array(rankedRecent),
            otherRoot: otherRoot,
            evictionReason: { node in
                node.normalizedURL.flatMap { recentVisits[$0] } != nil
                    ? "Ranked outside the top \(FormatOptions.maxRecentItems) most visited"
                    : "No visits in the last \(FormatOptions.recencyWindowDays) days"
            }
        )

        var otherBookmarksReordered = false
        if let otherRoot {
            let originalOrder = otherRoot.children.map(\.title)
            otherRoot.children.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            otherBookmarksReordered = otherRoot.children.map(\.title) != originalOrder
        }

        let (bookmarks, folders) = totals()
        return FormatPlan(
            duplicates: duplicates,
            routineAdditions: routineResult.additions,
            routineEvictions: routineResult.evictions,
            routineItems: routineResult.items,
            routineReordered: routineResult.reordered,
            recentAdditions: recentResult.additions,
            recentEvictions: recentResult.evictions,
            recentItems: recentResult.items,
            recentReordered: recentResult.reordered,
            otherBookmarksReordered: otherBookmarksReordered,
            totalBookmarks: bookmarks,
            totalFolders: folders
        )
    }

    private static func recentReason(_ visit: RecentVisit) -> String {
        let visits = "\(visit.visitCount) visit\(visit.visitCount == 1 ? "" : "s")"
        return "\(visits) in the last \(FormatOptions.recencyWindowDays) days · last opened \(visit.lastVisitedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Moves `kept` (already ranked, capped) into `target`, in order.
    /// Removes each from wherever it currently lives; whatever `target`
    /// currently holds directly that isn't in `kept` is evicted to
    /// `otherRoot`'s root (never removed outright, even if `otherRoot` is
    /// unavailable — in that unlikely case nothing is evicted). Subfolders
    /// already inside `target` are preserved, appended after the URL
    /// children.
    private static func applyFolderCuration(
        target: BookmarkNode,
        kept: [RankedItem],
        otherRoot: BookmarkNode?,
        evictionReason: (BookmarkNode) -> String
    ) -> (additions: [FolderMove], evictions: [FolderMove], items: [CuratedFolderItem], reordered: Bool) {
        let originalOrder = target.children.filter { $0.kind == .url }.compactMap { $0.raw["id"] as? String }
        let nonURLChildren = target.children.filter { $0.kind != .url }
        let previousDirectURLChildren = target.children.filter { $0.kind == .url }
        let keptIDs = Set(kept.map { ObjectIdentifier($0.node) })
        let movableOtherRoot = (otherRoot === target) ? nil : otherRoot

        let additions = kept.filter { $0.parent !== target }
        let evicted = movableOtherRoot == nil
            ? []
            : previousDirectURLChildren.filter { !keptIDs.contains(ObjectIdentifier($0)) }
        let stayedButUnranked = movableOtherRoot == nil
            ? previousDirectURLChildren.filter { !keptIDs.contains(ObjectIdentifier($0)) }
            : []

        for addition in additions {
            addition.parent.children.removeAll { $0 === addition.node }
        }

        target.children = kept.map(\.node) + stayedButUnranked + nonURLChildren
        if !evicted.isEmpty {
            movableOtherRoot?.children.append(contentsOf: evicted)
        }

        let targetID = target.raw["id"] as? String
        let otherID = movableOtherRoot?.raw["id"] as? String

        let additionMoves = additions.map {
            FolderMove(title: $0.node.title, url: $0.node.url ?? "", reason: $0.reason, nodeID: $0.node.raw["id"] as? String, toFolderID: targetID)
        }
        let evictionMoves = evicted.map {
            FolderMove(title: $0.title, url: $0.url ?? "", reason: evictionReason($0), nodeID: $0.raw["id"] as? String, toFolderID: otherID)
        }
        let items = kept.map {
            CuratedFolderItem(title: $0.node.title, url: $0.node.url ?? "", reason: $0.reason, nodeID: $0.node.raw["id"] as? String)
        }

        let finalOrder = target.children.filter { $0.kind == .url }.compactMap { $0.raw["id"] as? String }
        let reordered = finalOrder != originalOrder

        return (additionMoves, evictionMoves, items, reordered)
    }

    private static func visit(_ node: BookmarkNode, _ body: (BookmarkNode) -> Void) {
        body(node)
        for child in node.children {
            visit(child, body)
        }
    }
}
