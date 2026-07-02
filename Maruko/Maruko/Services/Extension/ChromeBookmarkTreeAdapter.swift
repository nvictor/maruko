import Foundation

/// One node of `chrome.bookmarks.getTree()` output. Decoded leniently —
/// the API returns more keys (dateAdded, index, syncing, …) that we don't
/// need and Codable ignores.
nonisolated struct ChromeBookmarkNode: Codable, Sendable {
    let id: String
    let title: String?
    let url: String?
    /// "managed" when the node is provisioned by enterprise policy.
    let unmodifiable: String?
    /// "bookmarks-bar" | "other" | "mobile" | "managed" (Chrome ≥ 134);
    /// absent on ordinary nodes and on older Chromium forks.
    let folderType: String?
    let children: [ChromeBookmarkNode]?
}

nonisolated enum ChromeBookmarkTreeAdapterError: LocalizedError {
    case noRecognizableRoots

    var errorDescription: String? {
        switch self {
        case .noRecognizableRoots:
            return "The extension sent a bookmark tree with no recognizable roots (bookmarks bar / other / mobile)."
        }
    }
}

/// Converts `chrome.bookmarks.getTree()` output into the same
/// `(rootKey, BookmarkNode)` trees the file-based formatter uses, so
/// `BookmarkTreeFormatter.formatTree` runs unchanged on live browser data.
nonisolated enum ChromeBookmarkTreeAdapter {
    struct RootedTree {
        let rootKey: String
        let node: BookmarkNode
        let chromeRootID: String
    }

    /// `tree` is the raw getTree() result: a single synthetic root (id "0")
    /// whose children are the top-level containers. Containers are mapped to
    /// the Bookmarks-file root keys by `folderType` where available, falling
    /// back to Chromium's stable ids ("1" bar, "2" other, "3" mobile) for
    /// forks that don't send it. Managed and unrecognized containers are
    /// skipped — the formatter must never touch policy-provisioned nodes.
    static func adapt(tree: [ChromeBookmarkNode]) throws -> [RootedTree] {
        var trees: [RootedTree] = []

        for root in tree {
            for container in root.children ?? [] {
                guard container.unmodifiable != "managed",
                      container.folderType != "managed",
                      let rootKey = rootKey(for: container) else { continue }
                guard let node = BookmarkNode(raw: rawDictionary(for: container)) else { continue }
                trees.append(RootedTree(rootKey: rootKey, node: node, chromeRootID: container.id))
            }
        }

        guard !trees.isEmpty else {
            throw ChromeBookmarkTreeAdapterError.noRecognizableRoots
        }
        return trees
    }

    /// Pre-format child order of every folder reachable from the adapted
    /// containers: folder id → child ids in current order. The op-list
    /// builder diffs these against the formatted trees to find reorders.
    static func childOrders(tree: [ChromeBookmarkNode]) -> [String: [String]] {
        var orders: [String: [String]] = [:]

        func walk(_ node: ChromeBookmarkNode) {
            guard let children = node.children else { return }
            orders[node.id] = children.map(\.id)
            for child in children {
                walk(child)
            }
        }

        for root in tree {
            for container in root.children ?? [] {
                guard container.unmodifiable != "managed",
                      container.folderType != "managed",
                      rootKey(for: container) != nil else { continue }
                walk(container)
            }
        }
        return orders
    }

    private static func rootKey(for container: ChromeBookmarkNode) -> String? {
        switch container.folderType {
        case "bookmarks-bar": return "bookmark_bar"
        case "other": return "other"
        case "mobile": return "synced"
        case .some: return nil
        case nil:
            // Fork without folderType: Chromium's root ids are stable.
            switch container.id {
            case "1": return "bookmark_bar"
            case "2": return "other"
            case "3": return "synced"
            default: return nil
            }
        }
    }

    /// Synthesizes the Bookmarks-file dictionary shape `BookmarkNode(raw:)`
    /// expects. `guid` is deliberately set to the chrome node id: the API
    /// exposes no guid, and the AI title pass keys candidates and overrides
    /// off `raw["guid"]`.
    private static func rawDictionary(for node: ChromeBookmarkNode) -> [String: Any] {
        var raw: [String: Any] = [
            "id": node.id,
            "guid": node.id,
            "name": node.title ?? "",
        ]
        if let url = node.url {
            raw["type"] = "url"
            raw["url"] = url
        } else {
            raw["type"] = "folder"
            raw["children"] = (node.children ?? [])
                .filter { $0.unmodifiable != "managed" }
                .map { rawDictionary(for: $0) }
        }
        return raw
    }
}
