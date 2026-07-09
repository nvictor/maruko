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

    private func format(
        _ trees: [ChromeBookmarkTreeAdapter.RootedTree],
        options: FormatOptions,
        rules: [RewriteRuleSnapshot] = [],
        recentVisits: [String: Date] = [:]
    ) -> FormatPlan {
        BookmarkTreeFormatter.formatTree(
            trees: trees.map { (rootKey: $0.rootKey, node: $0.node) },
            rules: rules,
            options: options,
            recentVisits: recentVisits
        )
    }

    @Test func deletesCarryChromeIdsAndDeleteOnlyFoldersEmitNoReorder() throws {
        let (trees, orders) = try adapted()
        var options = FormatOptions.default
        options.rewriteTitles = false
        options.moveRecentToTop = false

        let plan = format(trees, options: options)
        let ops = ChromeOpListBuilder.makeOps(
            originalChildOrders: orders,
            formattedTrees: trees,
            plan: plan
        )

        // DFS keeps the bar's copies; "13" (github dupe) and "21" (swift
        // docs dupe) go.
        #expect(ops.deletes == ["13", "21"])
        #expect(ops.retitles.isEmpty)
        #expect(ops.reorders.isEmpty)
    }

    @Test func retitlesCarryChromeIds() throws {
        let (trees, orders) = try adapted()
        var options = FormatOptions.default
        options.removeDuplicates = false
        options.moveRecentToTop = false

        let rule = RewriteRuleSnapshot(
            id: UUID(),
            name: "News",
            isEnabled: true,
            order: 0,
            kind: .regexMatchReplace,
            matchField: .title,
            pattern: "^News$",
            replacementTemplate: "Hacker News",
            isCaseSensitive: false,
            createdAt: Date()
        )

        let plan = format(trees, options: options, rules: [rule])
        let ops = ChromeOpListBuilder.makeOps(
            originalChildOrders: orders,
            formattedTrees: trees,
            plan: plan
        )

        #expect(ops.deletes.isEmpty)
        #expect(ops.retitles == [BookmarkOps.Retitle(id: "22", title: "Hacker News")])
        #expect(ops.reorders.isEmpty)
    }

    @Test func reordersAreCompletePostDeleteOrders() throws {
        let (trees, orders) = try adapted()
        var options = FormatOptions.default
        options.rewriteTitles = false

        // "22" (news) was visited recently; dedupe removes "21" from the
        // same folder. Expected final order of folder "2": 22 first, then
        // 20 — a complete order that already excludes the deleted 21.
        let newsKey = try #require(URLNormalizer.normalize("https://news.ycombinator.com/"))
        let plan = format(trees, options: options, recentVisits: [newsKey: Date()])
        let ops = ChromeOpListBuilder.makeOps(
            originalChildOrders: orders,
            formattedTrees: trees,
            plan: plan
        )

        #expect(ops.deletes == ["13", "21"])
        #expect(ops.reorders == [BookmarkOps.Reorder(folderId: "2", orderedChildIds: ["22", "20"])])
    }

    @Test func bookmarkBarDirectChildrenAreNeverReordered() throws {
        let (trees, orders) = try adapted()
        var options = FormatOptions.default
        options.removeDuplicates = false
        options.rewriteTitles = false

        // "14" (MDN, inside the Docs subfolder) is recent; the bar's own
        // row must stay put while the subfolder reorders.
        let mdnKey = try #require(URLNormalizer.normalize("https://developer.mozilla.org/"))
        let plan = format(trees, options: options, recentVisits: [mdnKey: Date()])
        let ops = ChromeOpListBuilder.makeOps(
            originalChildOrders: orders,
            formattedTrees: trees,
            plan: plan
        )

        #expect(plan.reorderedFolderCount == 1)
        #expect(ops.reorders == [BookmarkOps.Reorder(folderId: "11", orderedChildIds: ["14", "12", "13"])])
        #expect(!ops.reorders.contains { $0.folderId == "1" })
    }

    @Test func unchangedFoldersEmitNothing() throws {
        let (trees, orders) = try adapted()
        var options = FormatOptions.default
        options.removeDuplicates = false
        options.rewriteTitles = false
        options.moveRecentToTop = false

        let plan = format(trees, options: options)
        let ops = ChromeOpListBuilder.makeOps(
            originalChildOrders: orders,
            formattedTrees: trees,
            plan: plan
        )

        #expect(ops.isEmpty)
    }

    @Test func overflowingRecentFolderEmitsMovesAndReordersForBothFolders() throws {
        let now = Date()
        var recentChildren: [ChromeBookmarkNode] = []
        var visits: [String: Date] = [:]
        for i in 1...22 {
            let url = "https://item\(i).example.com/"
            recentChildren.append(ChromeBookmarkNode(id: "r\(i)", title: "Item \(i)", url: url, unmodifiable: nil, folderType: nil, children: nil))
            // Higher i = more recently visited; items 1 and 2 are oldest.
            visits[url] = now.addingTimeInterval(Double(i))
        }
        let recentFolder = ChromeBookmarkNode(id: "10", title: "Recent", url: nil, unmodifiable: nil, folderType: nil, children: recentChildren)
        let bar = ChromeBookmarkNode(id: "1", title: "Bookmarks Bar", url: nil, unmodifiable: nil, folderType: "bookmarks-bar", children: [recentFolder])
        let other = ChromeBookmarkNode(id: "2", title: "Other Bookmarks", url: nil, unmodifiable: nil, folderType: "other", children: [])
        let syntheticRoot = ChromeBookmarkNode(id: "0", title: "", url: nil, unmodifiable: nil, folderType: nil, children: [bar, other])

        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: [syntheticRoot])
        let orders = ChromeBookmarkTreeAdapter.childOrders(tree: [syntheticRoot])

        // Recent-folder curation is its own action now (`curateRecentFolderPlan`),
        // not part of the automatic `formatTree` pass.
        let plan = try #require(BookmarkTreeFormatter.curateRecentFolderPlan(
            trees: trees.map { (rootKey: $0.rootKey, node: $0.node) },
            recentVisits: visits
        ))
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

        // Redundant-but-harmless: the "other" root's diff also shows the
        // two relocated ids appended, in eviction order (least-stale of the
        // two evicted items first, since eviction ranks by recency descending).
        let otherReorder = try #require(ops.reorders.first { $0.folderId == "2" })
        #expect(otherReorder.orderedChildIds == ["r2", "r1"])
    }
}
