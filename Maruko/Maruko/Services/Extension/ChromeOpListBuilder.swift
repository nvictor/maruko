import Foundation

/// The edit list the extension applies via chrome.bookmarks, in order:
/// deletes, then retitles, then moves, then reorders. `orderedChildIds` is
/// the complete desired child order of a folder *after* deletes and moves.
nonisolated struct BookmarkOps: Codable, Equatable, Sendable {
    struct Retitle: Codable, Equatable, Sendable {
        let id: String
        let title: String
    }

    struct Move: Codable, Equatable, Sendable {
        let id: String
        let toFolderId: String
    }

    struct Reorder: Codable, Equatable, Sendable {
        let folderId: String
        let orderedChildIds: [String]
    }

    var deletes: [String] = []
    var retitles: [Retitle] = []
    var moves: [Move] = []
    var reorders: [Reorder] = []

    var isEmpty: Bool {
        deletes.isEmpty && retitles.isEmpty && moves.isEmpty && reorders.isEmpty
    }
}

/// Turns a formatted tree + its change plan into `BookmarkOps`. Deletes and
/// retitles come straight from the plan's change records (which carry the
/// chrome node id); moves come from `plan.recentFolderAdditions` (bookmarks
/// pulled into a "Recent" folder from Other Bookmarks) and
/// `plan.recentFolderEvictions` (bookmarks moved back out to Other Bookmarks);
/// reorders are the one diff — a folder's final child ids against its
/// original order minus the deleted ids — which confines them to
/// `moveRecentToTop`/Recent-folder-curation effects and never emits one for
/// the bookmark bar's own row (the formatter skips it, so the diff is empty
/// there). A folder that merely gained or lost children at the tail (e.g.
/// Other Bookmarks after a Recent-folder move) without any actual
/// repositioning among what stayed doesn't get a reorder op — for a folder
/// with thousands of children, emitting one anyway is enormously expensive
/// for the extension to apply (it has to fetch and index-compare the whole
/// child list) for a change that never needed repositioning in the first
/// place.
nonisolated enum ChromeOpListBuilder {
    static func makeOps(
        originalChildOrders: [String: [String]],
        formattedTrees: [ChromeBookmarkTreeAdapter.RootedTree],
        plan: FormatPlan
    ) -> BookmarkOps {
        var ops = BookmarkOps()
        ops.deletes = plan.duplicates.compactMap(\.nodeID)
        ops.retitles = plan.titleChanges.compactMap { change in
            change.nodeID.map { BookmarkOps.Retitle(id: $0, title: change.newTitle) }
        }
        ops.moves = (plan.recentFolderAdditions + plan.recentFolderEvictions).compactMap { move in
            guard let id = move.nodeID, let toFolderId = move.toFolderID else { return nil }
            return BookmarkOps.Move(id: id, toFolderId: toFolderId)
        }

        let deleted = Set(ops.deletes)

        func walk(_ node: BookmarkNode) {
            guard node.kind == .folder, let folderId = node.raw["id"] as? String else { return }
            let finalOrder = node.children.compactMap { $0.raw["id"] as? String }
            let expected = (originalChildOrders[folderId] ?? []).filter { !deleted.contains($0) }

            if finalOrder != expected {
                // Restrict both sides to ids present in both — i.e. ignore
                // anything that was only added or only removed — and compare
                // just the relative order of what persisted. If that's
                // unchanged, nothing actually needs repositioning.
                let finalSet = Set(finalOrder)
                let expectedSet = Set(expected)
                let commonFinal = finalOrder.filter { expectedSet.contains($0) }
                let commonExpected = expected.filter { finalSet.contains($0) }
                if commonFinal != commonExpected {
                    ops.reorders.append(
                        BookmarkOps.Reorder(folderId: folderId, orderedChildIds: finalOrder)
                    )
                }
            }
            for child in node.children {
                walk(child)
            }
        }

        for tree in formattedTrees {
            walk(tree.node)
        }
        return ops
    }
}
