import Foundation
import Testing
@testable import Maruko

struct ChromeOpListBuilderTests {
    private func adapted() throws -> (
        trees: [ChromeBookmarkTreeAdapter.RootedTree],
        orders: [String: [String]]
    ) {
        let tree = try JSONDecoder().decode(
            [ChromeBookmarkNode].self,
            from: Fixture.data("chrome-get-tree")
        )
        return (
            try ChromeBookmarkTreeAdapter.adapt(tree: tree),
            ChromeBookmarkTreeAdapter.childOrders(tree: tree)
        )
    }

    private let emptyPlan = FormatPlan(
        duplicates: [],
        recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
        otherBookmarksReordered: false,
        totalBookmarks: 0, totalFolders: 0
    )

    /// A recent-visit map from `url: date` pairs, all sharing one visit count.
    private func visitMap(_ entries: [String: Date], eachVisited count: Int = 1) -> [String: RecentVisit] {
        entries.mapValues { RecentVisit(lastVisitedAt: $0, visitCount: count) }
    }

    // MARK: - Deletes (dedup only, via the chrome-get-tree fixture)

    @Test func deletesCarryChromeIdsAndDeleteOnlyFoldersEmitNoReorder() throws {
        let (trees, orders) = try adapted()
        let duplicates = BookmarkTreeFormatter.removeDuplicates(in: trees.map(\.node))
        let plan = FormatPlan(
            duplicates: duplicates,
            recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
            otherBookmarksReordered: false,
            totalBookmarks: 0, totalFolders: 0
        )

        let ops = ChromeOpListBuilder.makeOps(originalChildOrders: orders, formattedTrees: trees, plan: plan)

        // DFS keeps the bar's copies; "13" (github dupe) and "21" (swift
        // docs dupe) go.
        #expect(ops.deletes == ["13", "21"])
        #expect(ops.retitles.isEmpty)
        #expect(ops.reorders.isEmpty)
    }

    @Test func retitlesAreAlwaysEmpty() throws {
        let (trees, orders) = try adapted()
        let ops = ChromeOpListBuilder.makeOps(originalChildOrders: orders, formattedTrees: trees, plan: emptyPlan)
        #expect(ops.retitles.isEmpty)
    }

    @Test func unchangedFoldersEmitNothing() throws {
        let (trees, orders) = try adapted()
        let ops = ChromeOpListBuilder.makeOps(originalChildOrders: orders, formattedTrees: trees, plan: emptyPlan)
        #expect(ops.isEmpty)
    }

    // MARK: - Recent moves and reorder economy (built inline, with "Recent"
    // present, so `curateTree` can run end to end)

    private func chromeNode(
        _ id: String,
        _ title: String,
        url: String? = nil,
        folderType: String? = nil,
        children: [ChromeBookmarkNode]? = nil
    ) -> ChromeBookmarkNode {
        ChromeBookmarkNode(id: id, title: title, url: url, unmodifiable: nil, folderType: folderType, children: children)
    }

    @Test func overflowingRecentEmitsMovesAndReordersForRecentButNotOther() throws {
        let now = Date()
        var recentChildren: [ChromeBookmarkNode] = []
        var visits: [String: RecentVisit] = [:]
        for i in 1...22 {
            let url = "https://item\(i).example.com/"
            recentChildren.append(chromeNode("r\(i)", "Item \(i)", url: url))
            visits[url] = RecentVisit(lastVisitedAt: now.addingTimeInterval(Double(i)), visitCount: i)
        }
        let recent = chromeNode("10", "Recent", folderType: nil, children: recentChildren)
        let bar = chromeNode("1", "Bookmarks Bar", folderType: "bookmarks-bar", children: [recent])
        let other = chromeNode("2", "Other Bookmarks", folderType: "other", children: [])
        let syntheticRoot = chromeNode("0", "", children: [bar, other])

        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: [syntheticRoot])
        let orders = ChromeBookmarkTreeAdapter.childOrders(tree: [syntheticRoot])
        let plan = BookmarkTreeFormatter.curateTree(
            trees: trees.map { (rootKey: $0.rootKey, node: $0.node) },
            recentVisits: visits
        )
        let ops = ChromeOpListBuilder.makeOps(originalChildOrders: orders, formattedTrees: trees, plan: plan)

        #expect(ops.moves.sorted { $0.id < $1.id } == [
            BookmarkOps.Move(id: "r1", toFolderId: "2"),
            BookmarkOps.Move(id: "r2", toFolderId: "2"),
        ])

        let recentReorder = try #require(ops.reorders.first { $0.folderId == "10" })
        #expect(recentReorder.orderedChildIds.count == 20)
        #expect(recentReorder.orderedChildIds.first == "r22")
        #expect(!recentReorder.orderedChildIds.contains("r1"))
        #expect(!recentReorder.orderedChildIds.contains("r2"))

        // "Other Bookmarks" started empty and only gained two appended
        // items; nothing among its (empty) pre-existing children moved, so
        // it gets no reorder op at all.
        #expect(!ops.reorders.contains { $0.folderId == "2" })
    }

    @Test func appendOnlyChangeToALargeOtherBookmarksFolderEmitsNoReorderForIt() throws {
        // Regression test: a folder with thousands of pre-existing children
        // that only gains an appended eviction must not get a reorder op.
        // Emitting one for a huge folder when nothing among its existing
        // children moved is enormously expensive for the extension to apply
        // for no actual benefit. Names are chosen to already sort in their
        // original relative order so the alphabetical Other Bookmarks pass
        // doesn't introduce a reorder of its own.
        let existingCount = 5000
        let otherChildren: [ChromeBookmarkNode] = (1...existingCount).map {
            let padded = String(format: "%05d", $0)
            return chromeNode("o\($0)", "Item \(padded)", url: "https://o\($0).example.com/")
        }
        let recentChildren = (1...21).map {
            chromeNode("r\($0)", "Item \($0)", url: "https://r\($0).example.com/")
        }
        let now = Date()
        var visits: [String: RecentVisit] = [:]
        for i in 1...21 {
            visits["https://r\(i).example.com/"] = RecentVisit(lastVisitedAt: now.addingTimeInterval(Double(i)), visitCount: i)
        }

        let recent = chromeNode("10", "Recent", children: recentChildren)
        let bar = chromeNode("1", "Bookmarks Bar", folderType: "bookmarks-bar", children: [recent])
        let other = chromeNode("2", "Other Bookmarks", folderType: "other", children: otherChildren)
        let syntheticRoot = chromeNode("0", "", children: [bar, other])

        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: [syntheticRoot])
        let orders = ChromeBookmarkTreeAdapter.childOrders(tree: [syntheticRoot])
        let plan = BookmarkTreeFormatter.curateTree(
            trees: trees.map { (rootKey: $0.rootKey, node: $0.node) },
            recentVisits: visits
        )
        let ops = ChromeOpListBuilder.makeOps(originalChildOrders: orders, formattedTrees: trees, plan: plan)

        // One item evicted from Recent (over the 20 cap) into Other Bookmarks.
        #expect(ops.moves.count == 1)
        #expect(ops.moves.first?.toFolderId == "2")

        // Other Bookmarks' 5000 pre-existing children kept their exact
        // relative order (already alphabetical); gaining one appended child
        // at the tail doesn't reposition any of them.
        #expect(!ops.reorders.contains { $0.folderId == "2" })
    }
}
