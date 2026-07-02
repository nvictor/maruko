import Foundation

struct DuplicateRemoval: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: String
    let folderPath: String
    let keptFolderPath: String
}

struct TitleChange: Identifiable, Sendable {
    let id = UUID()
    let url: String
    let oldTitle: String
    let newTitle: String
    let folderPath: String
}

struct FormatPlan: Sendable {
    let duplicates: [DuplicateRemoval]
    let titleChanges: [TitleChange]
    /// Folders whose recently opened bookmarks were moved to the top.
    let reorderedFolderCount: Int
    let totalBookmarks: Int
    let totalFolders: Int

    var isEmpty: Bool {
        duplicates.isEmpty && titleChanges.isEmpty && reorderedFolderCount == 0
    }
}

struct FormatResult: Sendable {
    let plan: FormatPlan
    /// The full Bookmarks file with the plan applied, ready to write.
    let formattedData: Data
}

/// Applies Maruko's cleanup — remove duplicate URLs, rewrite titles, move
/// recently opened bookmarks to the top of their folders — to a Chromium
/// `Bookmarks` file, returning both a change plan for preview and the
/// formatted file bytes.
nonisolated enum BookmarkTreeFormatter {
    static func format(
        fileData: Data,
        rules: [RewriteRuleSnapshot],
        options: FormatOptions = .default,
        recentVisits: [String: Date] = [:]
    ) throws -> FormatResult {
        var file = try ChromiumBookmarksFile.load(data: fileData)

        var trees: [(rootKey: String, node: BookmarkNode)] = []
        for key in ChromiumBookmarksFile.rootKeys {
            if let raw = file.rootNode(key), let node = BookmarkNode(raw: raw) {
                trees.append((key, node))
            }
        }

        let roots = trees.map(\.node)
        let duplicates = options.removeDuplicates ? removeDuplicates(in: roots) : []
        let titleChanges = options.rewriteTitles ? rewriteTitles(in: roots, rules: rules) : []

        var reorderedFolderCount = 0
        if options.moveRecentToTop {
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

        for (key, node) in trees {
            file.replaceChildren(
                ofRoot: key,
                with: node.children.map { $0.dictionaryRepresentation() }
            )
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

        let plan = FormatPlan(
            duplicates: duplicates,
            titleChanges: titleChanges,
            reorderedFolderCount: reorderedFolderCount,
            totalBookmarks: totalBookmarks,
            // Don't count the three root containers themselves.
            totalFolders: max(0, totalFolders - roots.count)
        )
        return FormatResult(plan: plan, formattedData: try file.serialized())
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
                            keptFolderPath: keptPath
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

    static func rewriteTitles(in roots: [BookmarkNode], rules: [RewriteRuleSnapshot]) -> [TitleChange] {
        guard rules.contains(where: \.isEnabled) else { return [] }
        var changes: [TitleChange] = []

        func walk(_ folder: BookmarkNode, path: String) {
            for child in folder.children {
                switch child.kind {
                case .url:
                    let rewritten = BookmarkRewriteEngine.rewrite(
                        title: child.title,
                        url: child.url ?? "",
                        snapshots: rules
                    )
                    if rewritten != child.title {
                        changes.append(
                            TitleChange(
                                url: child.url ?? "",
                                oldTitle: child.title,
                                newTitle: rewritten,
                                folderPath: path
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

    private static func visit(_ node: BookmarkNode, _ body: (BookmarkNode) -> Void) {
        body(node)
        for child in node.children {
            visit(child, body)
        }
    }
}
