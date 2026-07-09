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

struct TitleChange: Identifiable, Sendable {
    let id = UUID()
    let url: String
    let oldTitle: String
    let newTitle: String
    let folderPath: String
    /// See `DuplicateRemoval.nodeID`.
    var nodeID: String?
}

struct RecentFolderMove: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    /// See `DuplicateRemoval.nodeID`.
    var nodeID: String?
    /// The destination folder's own id.
    var toFolderID: String?
}

struct FormatPlan: Sendable {
    let duplicates: [DuplicateRemoval]
    let titleChanges: [TitleChange]
    /// Folders whose recently opened bookmarks were moved to the top. Zero
    /// whenever a "Recent" folder is curated instead.
    let reorderedFolderCount: Int
    /// Bookmarks pulled into a "Recent" folder from Other Bookmarks' own
    /// direct children because they were visited recently.
    let recentFolderAdditions: [RecentFolderMove]
    /// Bookmarks moved out of a "Recent" folder into Other Bookmarks because
    /// the folder held more than the most-recently-accessed 20.
    let recentFolderEvictions: [RecentFolderMove]
    /// The standalone Recent action sorted the Recent folder itself, even
    /// when no bookmarks moved into or out of it.
    var recentFolderReordered = false
    let totalBookmarks: Int
    let totalFolders: Int

    var isEmpty: Bool {
        duplicates.isEmpty && titleChanges.isEmpty && reorderedFolderCount == 0
            && recentFolderAdditions.isEmpty && recentFolderEvictions.isEmpty
            && !recentFolderReordered
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

    /// Title changes whose old title, new title, or URL contains `query`
    /// (case-insensitive). An empty or whitespace-only query matches everything.
    func titleChanges(matching query: String) -> [TitleChange] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return titleChanges }
        return titleChanges.filter {
            $0.oldTitle.localizedCaseInsensitiveContains(query)
                || $0.newTitle.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    /// Recent-folder additions whose title or URL contains `query`
    /// (case-insensitive). An empty or whitespace-only query matches everything.
    func recentFolderAdditions(matching query: String) -> [RecentFolderMove] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recentFolderAdditions }
        return recentFolderAdditions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    /// Recent-folder evictions whose title or URL contains `query`
    /// (case-insensitive). An empty or whitespace-only query matches everything.
    func recentFolderEvictions(matching query: String) -> [RecentFolderMove] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recentFolderEvictions }
        return recentFolderEvictions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    /// Human-readable description of what applying this plan will do, for
    /// the apply confirmation dialog. Omits clauses whose count is zero, so
    /// a Recent-only plan (from `curateRecentFolderPlan`) doesn't read
    /// "removes 0 duplicates, rewrites 0 titles…".
    var confirmationSummary: String {
        var clauses: [String] = []
        if !duplicates.isEmpty { clauses.append("removes \(duplicates.count) duplicates") }
        if !titleChanges.isEmpty { clauses.append("rewrites \(titleChanges.count) titles") }
        if reorderedFolderCount > 0 { clauses.append("moves recently opened bookmarks up in \(reorderedFolderCount) folders") }
        if !recentFolderAdditions.isEmpty || !recentFolderEvictions.isEmpty {
            clauses.append("updates Recent (\(recentFolderAdditions.count) added, \(recentFolderEvictions.count) moved out)")
        }
        if recentFolderReordered {
            clauses.append("sorts Recent by last opened")
        }
        let joined = clauses.isEmpty ? "makes no changes" : clauses.joined(separator: ", ")
        let sentence = joined.prefix(1).uppercased() + joined.dropFirst() + "."
        return "\(sentence) The extension applies the changes while Chrome runs, so sync picks them up like ordinary edits. A snapshot of the current tree is saved first. Undo is not available for extension formatting yet."
    }
}

/// Applies Maruko's cleanup. Remove duplicate URLs, rewrite titles, move
/// recently opened bookmarks to the top of their folders. To a tree
/// adapted from chrome.bookmarks, returning the change plan for preview.
/// The trees are mutated in place with the result.
nonisolated enum BookmarkTreeFormatter {
    /// `rootKey` follows the Bookmarks-file naming convention
    /// ("bookmark_bar", "other", "synced") that `ChromeBookmarkTreeAdapter`
    /// maps chrome.bookmarks roots onto.
    static func formatTree(
        trees: [(rootKey: String, node: BookmarkNode)],
        rules: [RewriteRuleSnapshot],
        options: FormatOptions = .default,
        recentVisits: [String: Date] = [:],
        titleOverrides: [String: String] = [:]
    ) -> FormatPlan {
        let roots = trees.map(\.node)
        let duplicates = options.removeDuplicates ? removeDuplicates(in: roots) : []
        let titleChanges = options.rewriteTitles
            ? rewriteTitles(in: roots, rules: rules, titleOverrides: titleOverrides)
            : []

        // "Recent" folder curation is a separate, user-triggered action
        // (`curateRecentFolderPlan`). Format Bookmarks treats a folder
        // named "Recent" like any other folder here, so it still gets the
        // ordinary top-of-folder treatment below when enabled.
        var reorderedFolderCount = 0
        if options.moveRecentToTop {
            for (key, node) in trees {
                reorderedFolderCount += moveRecentToTop(
                    in: node,
                    recentVisits: recentVisits,
                    // The bookmark bar's own row of items is ordered
                    // strategically by the user. Never reorder it.
                    skipThisFolder: key == "bookmark_bar"
                )
            }
        }

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

        return FormatPlan(
            duplicates: duplicates,
            titleChanges: titleChanges,
            reorderedFolderCount: reorderedFolderCount,
            recentFolderAdditions: [],
            recentFolderEvictions: [],
            totalBookmarks: totalBookmarks,
            // Don't count the root containers themselves.
            totalFolders: max(0, totalFolders - roots.count)
        )
    }

    /// Curates the "Recent" folder on its own. Sorts it by last-visited
    /// date, pulls in qualifying candidates from Other Bookmarks' own
    /// direct children, and caps it at `maxKept`. Without touching
    /// duplicates, titles, or any other folder's order. This is a separate,
    /// user-triggered action, independent of `FormatOptions.moveRecentToTop`.
    /// Returns `nil` if no folder named "Recent" exists anywhere in the tree.
    static func curateRecentFolderPlan(
        trees: [(rootKey: String, node: BookmarkNode)],
        recentVisits: [String: Date],
        maxKept: Int = 20
    ) -> FormatPlan? {
        guard let recentFolder = findRecentFolder(in: trees) else { return nil }
        let otherRoot = trees.first(where: { $0.rootKey == "other" })?.node
        let originalRecentOrder = recentFolder.children.compactMap { $0.raw["id"] as? String }
        let (additions, evictions) = curateRecentFolder(
            recentFolder,
            otherRoot: otherRoot,
            recentVisits: recentVisits,
            maxKept: maxKept
        )
        let finalRecentOrder = recentFolder.children.compactMap { $0.raw["id"] as? String }
        let recentFolderReordered = originalRecentOrder != finalRecentOrder

        var totalBookmarks = 0
        var totalFolders = 0
        for (_, node) in trees {
            visit(node) { n in
                switch n.kind {
                case .url: totalBookmarks += 1
                case .folder: totalFolders += 1
                }
            }
        }

        return FormatPlan(
            duplicates: [],
            titleChanges: [],
            reorderedFolderCount: 0,
            recentFolderAdditions: additions,
            recentFolderEvictions: evictions,
            recentFolderReordered: recentFolderReordered,
            totalBookmarks: totalBookmarks,
            totalFolders: max(0, totalFolders - trees.count)
        )
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

    /// Applies the regex rules to every bookmark, then `titleOverrides`
    /// (Chromium node guid → new title, produced by the async AI pass). A
    /// bookmark touched by both records one change from its original title to
    /// the final one; the override wins.
    static func rewriteTitles(
        in roots: [BookmarkNode],
        rules: [RewriteRuleSnapshot],
        titleOverrides: [String: String] = [:]
    ) -> [TitleChange] {
        guard rules.contains(where: \.isEnabled) || !titleOverrides.isEmpty else { return [] }
        var changes: [TitleChange] = []

        func walk(_ folder: BookmarkNode, path: String) {
            for child in folder.children {
                switch child.kind {
                case .url:
                    var rewritten = BookmarkRewriteEngine.rewrite(
                        title: child.title,
                        url: child.url ?? "",
                        snapshots: rules
                    )
                    if let guid = child.raw["guid"] as? String, let override = titleOverrides[guid] {
                        rewritten = override
                    }
                    if rewritten != child.title {
                        changes.append(
                            TitleChange(
                                url: child.url ?? "",
                                oldTitle: child.title,
                                newTitle: rewritten,
                                folderPath: path,
                                nodeID: child.raw["id"] as? String
                            )
                        )
                        child.title = rewritten
                    }
                case .folder:
                    walk(child, path: "\(path) / \(child.title)")
                }
            }
        }

        for root in roots {
            walk(root, path: root.title)
        }
        return changes
    }

    /// Bookmarks eligible for the AI title pass: url nodes whose normalized
    /// URL appears in `recentVisits`, in depth-first order. Candidates are
    /// keyed by `raw["guid"]`. The extension adapter synthesizes
    /// `guid = <chrome node id>` since chrome.bookmarks has no guid field.
    static func recentBookmarkCandidates(
        trees: [(rootKey: String, node: BookmarkNode)],
        recentVisits: [String: Date]
    ) -> [AIRewriteCandidate] {
        guard !recentVisits.isEmpty else { return [] }
        var candidates: [AIRewriteCandidate] = []

        func walk(_ node: BookmarkNode, rootKey: String, depth: Int) {
            if node.kind == .url,
               !(rootKey == "bookmark_bar" && depth == 1),
               !node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let normalized = node.normalizedURL,
               recentVisits[normalized] != nil,
               let guid = node.raw["guid"] as? String {
                candidates.append(
                    AIRewriteCandidate(guid: guid, title: node.title, url: node.url ?? "")
                )
            }
            for child in node.children {
                walk(child, rootKey: rootKey, depth: depth + 1)
            }
        }

        for (rootKey, node) in trees {
            walk(node, rootKey: rootKey, depth: 0)
        }
        return candidates
    }

    /// Moves bookmarks that appear in `recentVisits` (normalized URL → last
    /// visit) to the top of their folder, most recently opened first; every
    /// other item keeps its existing order. Pass `skipThisFolder` to leave a
    /// folder's own children untouched while still processing its subfolders.
    /// Returns how many folders changed order.
    static func moveRecentToTop(
        in root: BookmarkNode,
        recentVisits: [String: Date],
        skipThisFolder: Bool = false
    ) -> Int {
        var reordered = 0

        func lastVisit(_ node: BookmarkNode) -> Date? {
            guard node.kind == .url, let key = node.normalizedURL else { return nil }
            return recentVisits[key]
        }

        func walk(_ folder: BookmarkNode, skip: Bool) {
            if !skip && !recentVisits.isEmpty {
                let recent = folder.children
                    .enumerated()
                    .compactMap { item in
                        lastVisit(item.element).map { (offset: item.offset, node: item.element, visited: $0) }
                    }
                    .sorted {
                        if $0.visited != $1.visited { return $0.visited > $1.visited }
                        return $0.offset < $1.offset
                    }
                    .map(\.node)

                if !recent.isEmpty {
                    let rest = folder.children.filter { child in lastVisit(child) == nil }
                    let rearranged = recent + rest
                    if !rearranged.elementsEqual(folder.children, by: ===) {
                        folder.children = rearranged
                        reordered += 1
                    }
                }
            }

            for child in folder.children where child.kind == .folder {
                walk(child, skip: false)
            }
        }

        walk(root, skip: skipThisFolder)
        return reordered
    }

    /// The first folder titled exactly "Recent", found via depth-first search
    /// across the given roots in a fixed order (bookmark bar, other, synced,
    /// then any remaining roots as encountered). If more than one "Recent"
    /// folder exists anywhere in the tree, only the first is used. A
    /// documented limitation, not multi-folder support. The title match
    /// trims surrounding whitespace and ignores case, so a trailing space or
    /// different capitalization doesn't silently defeat detection.
    static func findRecentFolder(in trees: [(rootKey: String, node: BookmarkNode)]) -> BookmarkNode? {
        let priority = ["bookmark_bar", "other", "synced"]
        let ordered = priority.compactMap { key in trees.first { $0.rootKey == key } }
            + trees.filter { tree in !priority.contains(tree.rootKey) }

        func isRecentFolder(_ node: BookmarkNode) -> Bool {
            node.kind == .folder
                && node.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Recent") == .orderedSame
        }

        func dfs(_ node: BookmarkNode) -> BookmarkNode? {
            if isRecentFolder(node) { return node }
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

    /// Curates a "Recent" folder as a bounded, sorted view of the most
    /// recently visited bookmarks: candidates are its own direct URL
    /// children plus Other Bookmarks' own direct URL children that have a
    /// hit in `recentVisits` (bookmarks filed into other named folders, and
    /// never-visited items already sitting in Other Bookmarks, are left
    /// alone). All candidates are ranked by last-visited date, most recent
    /// first. Items with no visit rank oldest. The top `maxKept` end up in
    /// "Recent" (pulling in whichever Other Bookmarks candidates made the
    /// cut); anything that was in "Recent" but didn't make the cut moves
    /// back to Other Bookmarks. Subfolders inside "Recent" are left
    /// untouched, placed after the sorted URL children. Returns
    /// (additions moved into Recent, evictions moved out to Other Bookmarks).
    static func curateRecentFolder(
        _ recentFolder: BookmarkNode,
        otherRoot: BookmarkNode?,
        recentVisits: [String: Date],
        maxKept: Int = 20
    ) -> (additions: [RecentFolderMove], evictions: [RecentFolderMove]) {
        func lastVisit(_ node: BookmarkNode) -> Date {
            node.normalizedURL.flatMap { recentVisits[$0] } ?? .distantPast
        }

        let alreadyInRecent = recentFolder.children.filter { $0.kind == .url }
        let nonURLChildren = recentFolder.children.filter { $0.kind != .url }
        let movableOtherRoot = otherRoot === recentFolder ? nil : otherRoot
        let otherCandidates = (movableOtherRoot?.children ?? []).filter { child in
            child.kind == .url && child.normalizedURL.flatMap { recentVisits[$0] } != nil
        }

        let alreadyInRecentIDs = Set(alreadyInRecent.map(ObjectIdentifier.init))
        let otherCandidateIDs = Set(otherCandidates.map(ObjectIdentifier.init))

        let pool = alreadyInRecent + otherCandidates
        let ranked = pool.enumerated()
            .sorted { a, b in
                let visitA = lastVisit(a.element)
                let visitB = lastVisit(b.element)
                if visitA != visitB { return visitA > visitB }
                return a.offset < b.offset
            }
            .map(\.element)

        let effectiveMaxKept = movableOtherRoot == nil ? Int.max : maxKept
        let keptOrdered = Array(ranked.prefix(effectiveMaxKept))
        let droppedOrdered = Array(ranked.dropFirst(effectiveMaxKept))

        // Both derived from the ranked (not original-array) order, so the
        // move lists reflect recency order rather than incidental array order.
        let additions = keptOrdered.filter { otherCandidateIDs.contains(ObjectIdentifier($0)) }
        let evictions = droppedOrdered.filter { alreadyInRecentIDs.contains(ObjectIdentifier($0)) }

        recentFolder.children = keptOrdered + nonURLChildren

        let additionIDs = Set(additions.map(ObjectIdentifier.init))
        movableOtherRoot?.children.removeAll { additionIDs.contains(ObjectIdentifier($0)) }
        movableOtherRoot?.children.append(contentsOf: evictions)

        let recentFolderID = recentFolder.raw["id"] as? String
        let otherFolderID = movableOtherRoot?.raw["id"] as? String

        let additionMoves = additions.map {
            RecentFolderMove(title: $0.title, url: $0.url ?? "", nodeID: $0.raw["id"] as? String, toFolderID: recentFolderID)
        }
        let evictionMoves = evictions.map {
            RecentFolderMove(title: $0.title, url: $0.url ?? "", nodeID: $0.raw["id"] as? String, toFolderID: otherFolderID)
        }

        return (additionMoves, evictionMoves)
    }

    private static func visit(_ node: BookmarkNode, _ body: (BookmarkNode) -> Void) {
        body(node)
        for child in node.children {
            visit(child, body)
        }
    }
}
