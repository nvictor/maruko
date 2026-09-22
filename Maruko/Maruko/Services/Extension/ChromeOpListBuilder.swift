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

extension BookmarkOps {
    func excludingRetitles(withNodeIDs excludedNodeIDs: Set<String>) -> BookmarkOps {
        guard !excludedNodeIDs.isEmpty else { return self }
        var copy = self
        copy.retitles.removeAll { excludedNodeIDs.contains($0.id) }
        return copy
    }
}

/// Turns a formatted tree + its change plan into `BookmarkOps`. Deletes come
/// straight from the plan's duplicate-removal records (which carry the
/// chrome node id); moves come from the plan's Recent addition and eviction
/// records; reorders are the one diff. A folder's final child ids against
/// its original order minus the deleted ids. A folder that merely gained or
/// lost children at the tail (e.g. Other Bookmarks after a Recent move)
/// without any actual repositioning among what stayed doesn't get a reorder
/// op. For a folder with thousands of children,
/// emitting one anyway is enormously expensive for the extension to apply
/// (it has to fetch and index-compare the whole child list) for a change
/// that never needed repositioning in the first place.
nonisolated enum ChromeOpListBuilder {
    static func makeOps(
        originalChildOrders: [String: [String]],
        formattedTrees: [ChromeBookmarkTreeAdapter.RootedTree],
        plan: FormatPlan
    ) -> BookmarkOps {
        var ops = BookmarkOps()
        ops.deletes = plan.duplicates.compactMap(\.nodeID)
        // Title-rewriting was removed; `retitles` stays in the wire struct
        // (always empty) so the extension, which reads it unconditionally,
        // doesn't need to be reloaded for this change to take effect.
        ops.retitles = []
        ops.moves = (plan.recentAdditions + plan.recentEvictions).compactMap { move in
            guard let id = move.nodeID, let toFolderId = move.toFolderID else { return nil }
            return BookmarkOps.Move(id: id, toFolderId: toFolderId)
        }

        let deleted = Set(ops.deletes)

        func walk(_ node: BookmarkNode) {
            guard node.kind == .folder, let folderId = node.raw["id"] as? String else { return }
            let finalOrder = node.children.compactMap { $0.raw["id"] as? String }
            let expected = (originalChildOrders[folderId] ?? []).filter { !deleted.contains($0) }

            if finalOrder != expected {
                // Restrict both sides to ids present in both. I.e. ignore
                // anything that was only added or only removed. And compare
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
