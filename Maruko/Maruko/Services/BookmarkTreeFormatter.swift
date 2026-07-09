import Foundation

struct DuplicateRemoval: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    let folderPath: String
    let keptFolderPath: String
    /// The node's own id (`raw["id"]`) — string in both the Bookmarks file
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
    /// The destination folder's own id (Other Bookmarks).
    var toFolderID: String?
}

struct FormatPlan: Sendable {
    let duplicates: [DuplicateRemoval]
    let titleChanges: [TitleChange]
    /// Folders whose recently opened bookmarks were moved to the top. Zero
    /// whenever a "Recent" folder is curated instead — see `recentFolderMoves`.
    let reorderedFolderCount: Int
    /// Bookmarks moved out of a "Recent" folder into Other Bookmarks because
    /// the folder held more than the most-recently-accessed 20.
    let recentFolderMoves: [RecentFolderMove]
    let totalBookmarks: Int
    let totalFolders: Int

    var isEmpty: Bool {
        duplicates.isEmpty && titleChanges.isEmpty && reorderedFolderCount == 0 && recentFolderMoves.isEmpty
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

    /// Recent-folder moves whose title or URL contains `query`
    /// (case-insensitive). An empty or whitespace-only query matches everything.
    func recentFolderMoves(matching query: String) -> [RecentFolderMove] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recentFolderMoves }
        return recentFolderMoves.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Applies Maruko's cleanup — remove duplicate URLs, rewrite titles, move
/// recently opened bookmarks to the top of their folders — to a tree
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

        var reorderedFolderCount = 0
        var recentFolderMoves: [RecentFolderMove] = []
        if options.moveRecentToTop {
            if let recentFolder = findRecentFolder(in: trees) {
                // A "Recent" folder curates itself — only its own children
                // are sorted/capped; the legacy global reorder is skipped
                // entirely everywhere else in the tree.
                let otherRoot = trees.first(where: { $0.rootKey == "other" })?.node
                recentFolderMoves = curateRecentFolder(
                    recentFolder,
                    otherRoot: otherRoot,
                    recentVisits: recentVisits
                )
            } else {
                for (key, node) in trees {
                    reorderedFolderCount += moveRecentToTop(
                        in: node,
                        recentVisits: recentVisits,
                        // The bookmark bar's own row of items is ordered
                        // strategically by the user — never reorder it.
                        skipThisFolder: key == "bookmark_bar"
                    )
                }
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
            recentFolderMoves: recentFolderMoves,
            totalBookmarks: totalBookmarks,
            // Don't count the root containers themselves.
            totalFolders: max(0, totalFolders - roots.count)
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
    /// keyed by `raw["guid"]` — the extension adapter synthesizes
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
    /// folder exists anywhere in the tree, only the first is used — a
    /// documented limitation, not multi-folder support.
    static func findRecentFolder(in trees: [(rootKey: String, node: BookmarkNode)]) -> BookmarkNode? {
        let priority = ["bookmark_bar", "other", "synced"]
        let ordered = priority.compactMap { key in trees.first { $0.rootKey == key } }
            + trees.filter { tree in !priority.contains(tree.rootKey) }

        func dfs(_ node: BookmarkNode) -> BookmarkNode? {
            if node.kind == .folder && node.title == "Recent" { return node }
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

    /// Sorts a "Recent" folder's direct URL children by last-visited date,
    /// most recent first — bookmarks with no visit in `recentVisits` rank
    /// oldest. Keeps the top `maxKept` and relocates the rest into
    /// `otherRoot`'s children (appended at the end; no ordering requirement
    /// there). Subfolders inside "Recent" are left untouched, placed after
    /// the sorted URL children. Returns the bookmarks that were relocated.
    static func curateRecentFolder(
        _ recentFolder: BookmarkNode,
        otherRoot: BookmarkNode?,
        recentVisits: [String: Date],
        maxKept: Int = 20
    ) -> [RecentFolderMove] {
        guard let otherRoot, otherRoot !== recentFolder else { return [] }

        let urlChildren = recentFolder.children.enumerated().filter { $0.element.kind == .url }
        let nonURLChildren = recentFolder.children.filter { $0.kind != .url }

        let ranked = urlChildren
            .sorted { a, b in
                let visitA = a.element.normalizedURL.flatMap { recentVisits[$0] } ?? .distantPast
                let visitB = b.element.normalizedURL.flatMap { recentVisits[$0] } ?? .distantPast
                if visitA != visitB { return visitA > visitB }
                return a.offset < b.offset
            }
            .map(\.element)

        let kept = Array(ranked.prefix(maxKept))
        let evicted = Array(ranked.dropFirst(maxKept))

        recentFolder.children = kept + nonURLChildren
        guard !evicted.isEmpty else { return [] }

        otherRoot.children.append(contentsOf: evicted)

        let otherFolderId = otherRoot.raw["id"] as? String
        return evicted.map {
            RecentFolderMove(title: $0.title, url: $0.url ?? "", nodeID: $0.raw["id"] as? String, toFolderID: otherFolderId)
        }
    }

    private static func visit(_ node: BookmarkNode, _ body: (BookmarkNode) -> Void) {
        body(node)
        for child in node.children {
            visit(child, body)
        }
    }
}
