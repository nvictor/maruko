import Foundation
import Testing
@testable import Maruko

struct BookmarkTreeFormatterTests {
    /// Loads a fixture's roots as bare `BookmarkNode` trees, for tests that
    /// don't care which root a node lives under.
    private func roots(fromFixture name: String) throws -> [BookmarkNode] {
        try trees(fromFixture: name).map(\.node)
    }

    /// Loads a fixture's roots keyed by root name ("bookmark_bar", "other",
    /// "synced"), matching what `ChromeBookmarkTreeAdapter.adapt` produces
    /// from a live chrome.bookmarks tree.
    private func trees(fromFixture name: String) throws -> [(rootKey: String, node: BookmarkNode)] {
        let object = try Fixture.dictionary(name)
        guard let rootsDict = object["roots"] as? [String: Any] else { return [] }
        return ["bookmark_bar", "other", "synced"].compactMap { key in
            (rootsDict[key] as? [String: Any])
                .flatMap(BookmarkNode.init(raw:))
                .map { (rootKey: key, node: $0) }
        }
    }

    /// A recent-visit map from `url: date` pairs, all sharing one visit
    /// count (default 1).
    private func visitMap(_ entries: [String: Date], eachVisited count: Int = 1) -> [String: RecentVisit] {
        entries.mapValues { RecentVisit(lastVisitedAt: $0, visitCount: count) }
    }

    private func rawURL(id: String, name: String, url: String) -> [String: Any] {
        ["type": "url", "id": id, "guid": id, "name": name, "url": url]
    }

    private func rawFolder(id: String, name: String, children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "id": id, "guid": id, "name": name, "children": children]
    }

    /// A minimal two-root tree with an empty "Recent" folder on the bar,
    /// ready for `curateTree` to run without any precondition failure.
    /// Extra bar/other children can be layered on by the caller.
    private func baseTrees(
        barChildren: [[String: Any]] = [],
        otherChildren: [[String: Any]] = [],
        recentChildren: [[String: Any]] = []
    ) -> [(rootKey: String, node: BookmarkNode)] {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawFolder(id: "n0", name: "Recent", children: recentChildren),
        ] + barChildren))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: otherChildren))!
        return [(rootKey: "bookmark_bar", node: bar), (rootKey: "other", node: other)]
    }

    // MARK: - Deduplication

    @Test func dedupeKeepsFirstDepthFirstOccurrence() throws {
        let roots = try self.roots(fromFixture: "chrome-duplicates")
        let removals = BookmarkTreeFormatter.removeDuplicates(in: roots)

        #expect(removals.count == 4)
        #expect(removals.allSatisfy { $0.keptFolderPath.hasPrefix("Bookmarks Bar") || $0.keptFolderPath.hasPrefix("Other Bookmarks") })

        var remaining: [String] = []
        func collect(_ node: BookmarkNode) {
            if node.kind == .url { remaining.append(node.url ?? "") }
            node.children.forEach(collect)
        }
        roots.forEach(collect)
        #expect(remaining == [
            "https://example.com/page",
            "https://example.com/other",
            "https://example.com/search?b=2&a=1",
        ])
    }

    @Test func dedupeNeverRemovesFolders() throws {
        let roots = try self.roots(fromFixture: "chrome-duplicates")
        _ = BookmarkTreeFormatter.removeDuplicates(in: roots)

        var folderTitles: [String] = []
        func collect(_ node: BookmarkNode) {
            if node.kind == .folder { folderTitles.append(node.title) }
            node.children.forEach(collect)
        }
        roots.forEach(collect)
        #expect(folderTitles.contains("Nested"))
    }

    // MARK: - findNamedFolder

    @Test func findNamedFolderLocatesNestedFolderByExactTitle() {
        let recent = rawFolder(id: "10", name: "Recent", children: [])
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawFolder(id: "2", name: "Other Stuff", children: [recent]),
        ]))!
        let other = BookmarkNode(raw: rawFolder(id: "3", name: "Other Bookmarks", children: []))!

        let found = BookmarkTreeFormatter.findNamedFolder("Recent", in: [
            (rootKey: "bookmark_bar", node: bar),
            (rootKey: "other", node: other),
        ])

        #expect(found?.title == "Recent")
        #expect(found?.raw["id"] as? String == "10")
    }

    @Test func findNamedFolderPrefersBookmarkBarThenOtherThenSynced() {
        let recentInOther = rawFolder(id: "20", name: "Recent", children: [])
        let recentInSynced = rawFolder(id: "30", name: "Recent", children: [])
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: []))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: [recentInOther]))!
        let synced = BookmarkNode(raw: rawFolder(id: "3", name: "Mobile Bookmarks", children: [recentInSynced]))!

        let found = BookmarkTreeFormatter.findNamedFolder("Recent", in: [
            (rootKey: "synced", node: synced),
            (rootKey: "other", node: other),
            (rootKey: "bookmark_bar", node: bar),
        ])

        #expect(found?.raw["id"] as? String == "20")
    }

    @Test func findNamedFolderReturnsNilWhenAbsent() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: []))!
        #expect(BookmarkTreeFormatter.findNamedFolder("Recent", in: [(rootKey: "bookmark_bar", node: bar)]) == nil)
    }

    @Test func findNamedFolderToleratesWhitespaceAndCase() {
        for name in ["Recent ", " Recent", "recent", "RECENT", "ReCeNt"] {
            let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
                rawFolder(id: "10", name: name, children: []),
            ]))!
            let found = BookmarkTreeFormatter.findNamedFolder("Recent", in: [(rootKey: "bookmark_bar", node: bar)])
            #expect(found?.raw["id"] as? String == "10", "expected to match folder named \(name.debugDescription)")
        }
    }

    @Test func findNamedFolderMatchesArbitraryName() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawFolder(id: "10", name: "Archive", children: []),
        ]))!
        let found = BookmarkTreeFormatter.findNamedFolder("Archive", in: [(rootKey: "bookmark_bar", node: bar)])
        #expect(found?.raw["id"] as? String == "10")
    }

    // MARK: - missingRequiredFolders

    @Test func missingRequiredFoldersReportsRecentWhenAbsent() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: []))!
        let missing = BookmarkTreeFormatter.missingRequiredFolders(in: [(rootKey: "bookmark_bar", node: bar)])
        #expect(missing == [.recent])
    }

    @Test func missingRequiredFoldersEmptyWhenRecentExists() {
        let trees = baseTrees()
        #expect(BookmarkTreeFormatter.missingRequiredFolders(in: trees).isEmpty)
    }

    // MARK: - curateTree: Recent

    @Test func curateTreeCapsRecentAtTwentyByVisitCountThenRecency() throws {
        let now = Date()
        var raws: [[String: Any]] = []
        var visits: [String: RecentVisit] = [:]
        for i in 1...22 {
            let url = "https://item\(i).example.com/"
            raws.append(rawURL(id: "\(i)", name: "Item \(i)", url: url))
            visits[url] = RecentVisit(lastVisitedAt: now.addingTimeInterval(Double(i)), visitCount: i)
        }
        let trees = baseTrees(recentChildren: raws)

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.recentAdditions.isEmpty)
        #expect(plan.recentItems.count == 20)
        // Evictions preserve the folder's original relative order (not rank order).
        #expect(plan.recentEvictions.map(\.title) == ["Item 1", "Item 2"])

        let recentFolder = BookmarkTreeFormatter.findNamedFolder("Recent", in: trees)!
        #expect(recentFolder.children.count == 20)
        #expect(recentFolder.children.first?.title == "Item 22")

        let otherRoot = trees.first { $0.rootKey == "other" }!.node
        #expect(otherRoot.children.map(\.title) == ["Item 1", "Item 2"])
    }

    @Test func curateTreePullsRecentlyVisitedBookmarksFromAnywhereExceptLooseOnTheBar() {
        let now = Date()
        let nested = rawFolder(id: "nested", name: "Nested", children: [
            rawURL(id: "innested", name: "In Nested", url: "https://innested.example.com/"),
        ])
        let trees = baseTrees(
            barChildren: [
                rawURL(id: "onbar", name: "On The Bar", url: "https://onbar.example.com/"),
                nested,
            ],
            otherChildren: [rawURL(id: "other1", name: "In Other", url: "https://other1.example.com/")]
        )
        let visits = visitMap([
            "https://onbar.example.com/": now,
            "https://innested.example.com/": now.addingTimeInterval(-1800),
            "https://other1.example.com/": now.addingTimeInterval(-3600),
        ])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        // "On The Bar" sits loose directly on the bar (not inside a
        // subfolder), so it's already at maximum visibility and is excluded
        // from "Recent" candidacy. The other two, though visited less
        // recently, still qualify.
        #expect(plan.recentAdditions.count == 2)
        #expect(plan.recentItems.map(\.nodeID) == ["innested", "other1"])

        let bar = trees.first { $0.rootKey == "bookmark_bar" }!.node
        #expect(bar.children.contains { $0.raw["id"] as? String == "onbar" })
    }

    // MARK: - Subfolders inside Recent are untouched

    @Test func curateTreeLeavesSubfoldersInsideRecentUntouched() {
        let nestedInRecent = rawFolder(id: "nested-recent", name: "Nested", children: [
            rawURL(id: "buried-recent", name: "Buried Recent", url: "https://buried.example.com/"),
        ])
        let trees = baseTrees(recentChildren: [nestedInRecent])
        let visits = visitMap(["https://buried.example.com/": Date()])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.recentAdditions.isEmpty)
        #expect(plan.recentEvictions.isEmpty)

        let recentFolder = BookmarkTreeFormatter.findNamedFolder("Recent", in: trees)!
        #expect(recentFolder.children.map { $0.raw["id"] as? String } == ["nested-recent"])
        #expect(recentFolder.children.first?.children.map { $0.raw["id"] as? String } == ["buried-recent"])
    }

    @Test func curateTreeAppendsSubfoldersAfterURLChildrenInRecent() {
        let subfolder = rawFolder(id: "sub", name: "Sub", children: [])
        let now = Date()
        let trees = baseTrees(
            otherChildren: [rawURL(id: "item", name: "Item", url: "https://item.example.com/")],
            recentChildren: [subfolder]
        )
        let visits = visitMap(["https://item.example.com/": now])

        _ = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        let recentFolder = BookmarkTreeFormatter.findNamedFolder("Recent", in: trees)!
        #expect(recentFolder.children.last?.raw["id"] as? String == "sub")
        #expect(recentFolder.children.last?.kind == .folder)
    }

    // MARK: - Other Bookmarks sorting

    @Test func curateTreeSortsOtherBookmarksDirectChildrenAlphabeticallyOnly() {
        let apple = rawFolder(id: "apple", name: "apple", children: [
            rawURL(id: "zed", name: "Zed", url: "https://zed.example.com/"),
            rawURL(id: "alpha", name: "Alpha", url: "https://alpha-nested.example.com/"),
        ])
        let trees = baseTrees(otherChildren: [
            rawURL(id: "zebra", name: "Zebra", url: "https://zebra.example.com/"),
            apple,
            rawURL(id: "banana", name: "Banana", url: "https://banana.example.com/"),
        ])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])

        #expect(plan.otherBookmarksReordered)
        let otherRoot = trees.first { $0.rootKey == "other" }!.node
        #expect(otherRoot.children.map(\.title) == ["apple", "Banana", "Zebra"])

        // Nested contents of "apple" are untouched, not recursively sorted.
        let appleNode = otherRoot.children.first { $0.title == "apple" }!
        #expect(appleNode.children.map(\.title) == ["Zed", "Alpha"])
    }

    // MARK: - Ordering with dedup

    @Test func curateTreeDedupsBeforeSelectingRecent() {
        let now = Date()
        let nested = rawFolder(id: "nested", name: "Nested", children: [
            rawURL(id: "bar-item", name: "Item", url: "https://item.example.com/"),
        ])
        let trees = baseTrees(
            barChildren: [nested],
            otherChildren: [rawURL(id: "other-item", name: "Item Dupe", url: "https://item.example.com/")]
        )
        let visits = visitMap(["https://item.example.com/": now])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.duplicates.count == 1)
        #expect(plan.recentItems.count == 1)
        #expect(plan.recentAdditions.count == 1)
    }

    @Test func curateTreeIsIdempotent() {
        let now = Date()
        let trees = baseTrees(otherChildren: [
            rawURL(id: "item", name: "Item", url: "https://item.example.com/"),
        ])
        let visits = visitMap(["https://item.example.com/": now])

        let first = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)
        #expect(!first.isEmpty)

        let second = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)
        #expect(second.isEmpty)
    }

    @Test func curateTreeWithoutRequiredFoldersOnlyDedups() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawURL(id: "a", name: "A", url: "https://a.example.com/"),
            rawURL(id: "a-dupe", name: "A Dupe", url: "https://a.example.com/"),
        ]))!
        let trees: [(rootKey: String, node: BookmarkNode)] = [(rootKey: "bookmark_bar", node: bar)]
        #expect(!BookmarkTreeFormatter.missingRequiredFolders(in: trees).isEmpty)

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])

        #expect(plan.duplicates.count == 1)
        #expect(plan.recentItems.isEmpty)
        #expect(plan.isEmpty == false) // dedup alone is still a change
    }

    // MARK: - FormatPlan helpers

    @Test func planFilterMatchesTitleAndURLCaseInsensitively() {
        let plan = FormatPlan(
            duplicates: [
                DuplicateRemoval(title: "GitHub", url: "https://github.com/nvictor/maruko", folderPath: "Bar", keptFolderPath: "Bar"),
                DuplicateRemoval(title: "", url: "https://docs.example.com/guide", folderPath: "Bar", keptFolderPath: "Bar"),
            ],
            recentAdditions: [], recentEvictions: [],
            recentItems: [
                CuratedFolderItem(title: "Chase", url: "https://chase.com/", reason: "12 visits in the last 30 days"),
                CuratedFolderItem(title: "Geico", url: "https://geico.com/", reason: "3 visits in the last 30 days"),
            ],
            recentReordered: false,
            otherBookmarksReordered: false,
            totalBookmarks: 4, totalFolders: 1
        )

        #expect(plan.duplicates(matching: "").count == 2)
        #expect(plan.recentItems(matching: "  ").count == 2)
        #expect(plan.duplicates(matching: "GITHUB").map(\.title) == ["GitHub"])
        #expect(plan.duplicates(matching: "docs.example").map(\.url) == ["https://docs.example.com/guide"])
        #expect(plan.recentItems(matching: "chase").map(\.title) == ["Chase"])
        #expect(plan.recentItems(matching: "visits").isEmpty) // filters by title/url, not reason
        #expect(plan.duplicates(matching: "zzz").isEmpty)
        #expect(plan.recentItems(matching: "zzz").isEmpty)
    }

    @Test func confirmationSummaryOmitsZeroClauses() {
        let emptyPlan = FormatPlan(
            duplicates: [],
            recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
            otherBookmarksReordered: false,
            totalBookmarks: 0, totalFolders: 0
        )
        #expect(emptyPlan.confirmationSummary.hasPrefix("Makes no changes."))

        let fullPlan = FormatPlan(
            duplicates: [DuplicateRemoval(title: "A", url: "https://a.example.com/", folderPath: "Bar", keptFolderPath: "Bar")],
            recentAdditions: [FolderMove(title: "New", url: "https://new.example.com/", reason: "1 visit in the last 30 days")],
            recentEvictions: [
                FolderMove(title: "Old", url: "https://old.example.com/", reason: "Ranked outside the top 20 most visited"),
            ],
            recentItems: [], recentReordered: false,
            otherBookmarksReordered: true,
            totalBookmarks: 2, totalFolders: 1
        )
        let summary = fullPlan.confirmationSummary
        #expect(summary.hasPrefix("Removes 1 duplicates, updates Recent (1 added, 1 moved out), sorts Other Bookmarks alphabetically."))

        let reorderOnlyPlan = FormatPlan(
            duplicates: [],
            recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: true,
            otherBookmarksReordered: false,
            totalBookmarks: 3, totalFolders: 1
        )
        #expect(!reorderOnlyPlan.isEmpty)
        #expect(reorderOnlyPlan.confirmationSummary.hasPrefix("Sorts Recent."))
    }
}
