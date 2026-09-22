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

    /// A minimal three-root tree with empty "Routine" and "Recent" folders
    /// on the bar, ready for `curateTree` to run without any precondition
    /// failure. Extra bar/other children can be layered on by the caller.
    private func baseTrees(
        barChildren: [[String: Any]] = [],
        otherChildren: [[String: Any]] = [],
        routineChildren: [[String: Any]] = [],
        recentChildren: [[String: Any]] = []
    ) -> [(rootKey: String, node: BookmarkNode)] {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawFolder(id: "r0", name: "Routine", children: routineChildren),
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
            rawFolder(id: "10", name: "Routine", children: []),
        ]))!
        let found = BookmarkTreeFormatter.findNamedFolder("Routine", in: [(rootKey: "bookmark_bar", node: bar)])
        #expect(found?.raw["id"] as? String == "10")
    }

    // MARK: - missingRequiredFolders

    @Test func missingRequiredFoldersReportsBothWhenNeitherExists() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: []))!
        let missing = BookmarkTreeFormatter.missingRequiredFolders(in: [(rootKey: "bookmark_bar", node: bar)])
        #expect(missing == [.routine, .recent])
    }

    @Test func missingRequiredFoldersReportsOnlyMissingOne() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawFolder(id: "10", name: "Routine", children: []),
        ]))!
        let missing = BookmarkTreeFormatter.missingRequiredFolders(in: [(rootKey: "bookmark_bar", node: bar)])
        #expect(missing == [.recent])
    }

    @Test func missingRequiredFoldersEmptyWhenBothExist() {
        let trees = baseTrees()
        #expect(BookmarkTreeFormatter.missingRequiredFolders(in: trees).isEmpty)
    }

    // MARK: - curateTree: Routine

    @Test func curateTreePullsRoutineCandidateFromAnywhereInTreeWithReason() {
        let trees = baseTrees(otherChildren: [
            rawURL(id: "chase", name: "Chase", url: "https://chase.com/"),
        ])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])

        #expect(plan.routineAdditions.count == 1)
        #expect(plan.routineAdditions.first?.reason == "Banking")
        #expect(plan.routineAdditions.first?.nodeID == "chase")
        #expect(plan.routineItems.map(\.reason) == ["Banking"])

        let routineFolder = BookmarkTreeFormatter.findNamedFolder("Routine", in: trees)!
        #expect(routineFolder.children.map { $0.raw["id"] as? String } == ["chase"])
        let otherRoot = trees.first { $0.rootKey == "other" }!.node
        #expect(otherRoot.children.isEmpty)
    }

    @Test func curateTreeRoutineTakesPrecedenceOverRecentOnDoubleMatch() {
        let now = Date()
        let trees = baseTrees(otherChildren: [
            rawURL(id: "chase", name: "Chase", url: "https://chase.com/"),
        ])
        let visits = visitMap(["https://chase.com/": now], eachVisited: 10)

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.routineAdditions.count == 1)
        #expect(plan.recentAdditions.isEmpty)
        #expect(plan.recentItems.isEmpty)
        #expect(plan.routineItems.map(\.reason) == ["Banking"])
    }

    @Test func curateTreeCapsRoutineAtTwentyRankedByVisitsWithinSameTier() {
        // All 22 are hostExact matches (same strength tier), so ranking
        // falls to visit count: the two least-visited get evicted.
        let domains = [
            "amazon.com", "target.com", "walmart.com", "costco.com", "ebay.com", "etsy.com", "bestbuy.com",
            "chase.com", "bankofamerica.com", "wellsfargo.com", "citibank.com", "capitalone.com", "americanexpress.com",
            "discover.com", "paypal.com", "venmo.com", "fidelity.com", "schwab.com", "vanguard.com",
            "geico.com", "progressive.com", "statefarm.com",
        ]
        #expect(domains.count == 22)

        var children: [[String: Any]] = []
        var visits: [String: RecentVisit] = [:]
        let now = Date()
        for (index, domain) in domains.enumerated() {
            let url = "https://\(domain)/"
            children.append(rawURL(id: domain, name: domain, url: url))
            visits[url] = RecentVisit(lastVisitedAt: now, visitCount: index + 1)
        }
        let trees = baseTrees(otherChildren: children)

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.routineItems.count == 20)
        #expect(plan.routineAdditions.count == 20)
        #expect(plan.routineEvictions.isEmpty)

        let routineFolder = BookmarkTreeFormatter.findNamedFolder("Routine", in: trees)!
        // Highest visit count (statefarm.com, index 22) ranks first.
        #expect(routineFolder.children.first?.raw["id"] as? String == "statefarm.com")
        // The two least-visited (amazon.com, target.com) were evicted.
        let otherRoot = trees.first { $0.rootKey == "other" }!.node
        #expect(Set(otherRoot.children.compactMap { $0.raw["id"] as? String }) == ["amazon.com", "target.com"])
    }

    @Test func curateTreeEvictsResidentRoutineItemsThatNoLongerRankOrMatch() {
        let now = Date()
        var children: [[String: Any]] = [
            rawURL(id: "unmatched", name: "Random Site", url: "https://random.example.com/"),
        ]
        var visits: [String: RecentVisit] = [:]
        for i in 1...20 {
            let url = "https://item\(i).chase.com/"
            children.append(rawURL(id: "chase\(i)", name: "Chase \(i)", url: url))
            visits[url] = RecentVisit(lastVisitedAt: now, visitCount: i)
        }
        let trees = baseTrees(routineChildren: children)

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.routineEvictions.count == 1)
        #expect(plan.routineEvictions.first?.nodeID == "unmatched")
        #expect(plan.routineEvictions.first?.reason == "No longer matches a routine category")
        #expect(plan.routineItems.count == 20)

        let otherRoot = trees.first { $0.rootKey == "other" }!.node
        #expect(otherRoot.children.map { $0.raw["id"] as? String } == ["unmatched"])
    }

    // MARK: - curateTree: Routine pinning (declined evictions)

    @Test func pinningAnEvictionConsumesARoutineSlotAndBumpsTheLowestRankedItem() {
        let now = Date()
        var children: [[String: Any]] = [
            rawURL(id: "unmatched", name: "Random Site", url: "https://random.example.com/"),
        ]
        var visits: [String: RecentVisit] = [:]
        for i in 1...20 {
            let url = "https://item\(i).chase.com/"
            children.append(rawURL(id: "chase\(i)", name: "Chase \(i)", url: url))
            visits[url] = RecentVisit(lastVisitedAt: now, visitCount: i)
        }
        let trees = baseTrees(routineChildren: children)

        let plan = BookmarkTreeFormatter.curateTree(
            trees: trees,
            recentVisits: visits,
            pinnedRoutineNodeIDs: ["unmatched"]
        )

        #expect(plan.routineItems.count == 20)
        #expect(plan.routineItems.contains { $0.nodeID == "unmatched" })
        #expect(plan.routineItems.first { $0.nodeID == "unmatched" }?.reason == "Kept — you chose not to move this out")
        // Pinning "unmatched" ate one of the 20 slots, so the lowest-ranked
        // (least-visited) resident chase bookmark gets evicted instead.
        #expect(plan.routineEvictions.map(\.nodeID) == ["chase1"])
        #expect(plan.routineEvictions.first?.reason == "Ranked outside the top 20")

        let routineFolder = BookmarkTreeFormatter.findNamedFolder("Routine", in: trees)!
        let routineIDs = routineFolder.children.compactMap { $0.raw["id"] as? String }
        #expect(routineIDs.contains("unmatched"))
        #expect(!routineIDs.contains("chase1"))
    }

    @Test func pinningANodeIDNotCurrentlyInRoutineHasNoEffect() {
        let trees = baseTrees(otherChildren: [
            rawURL(id: "chase", name: "Chase", url: "https://chase.com/"),
        ])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:], pinnedRoutineNodeIDs: ["chase"])

        #expect(plan.routineAdditions.count == 1)
        #expect(plan.routineItems.map(\.reason) == ["Banking"])
    }

    @Test func pinningAResidentThatStillMatchesKeepsItsCategoryReason() {
        let trees = baseTrees(routineChildren: [
            rawURL(id: "chase", name: "Chase", url: "https://chase.com/"),
        ])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:], pinnedRoutineNodeIDs: ["chase"])

        #expect(plan.routineItems.map(\.reason) == ["Banking"])
        #expect(plan.routineEvictions.isEmpty)
        #expect(plan.routineAdditions.isEmpty)
    }

    @Test func pinnedRoutineResidentIsExcludedFromRecentCandidacy() {
        let now = Date()
        let trees = baseTrees(routineChildren: [
            rawURL(id: "ambiguous", name: "Ambiguous", url: "https://ambiguous.example.com/"),
        ])
        let visits = visitMap(["https://ambiguous.example.com/": now])

        let plan = BookmarkTreeFormatter.curateTree(
            trees: trees,
            recentVisits: visits,
            pinnedRoutineNodeIDs: ["ambiguous"]
        )

        // Without the pin, this unmatched-but-visited bookmark would have
        // been pulled into Recent instead. Pinning keeps it in Routine.
        #expect(plan.recentAdditions.isEmpty)
        #expect(plan.recentItems.isEmpty)
        #expect(plan.routineItems.map(\.nodeID) == ["ambiguous"])
        #expect(plan.routineItems.first?.reason == "Kept — you chose not to move this out")
        #expect(plan.routineEvictions.isEmpty)
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

    @Test func curateTreePullsRecentlyVisitedBookmarksFromAnywhere() {
        let now = Date()
        let trees = baseTrees(
            barChildren: [rawURL(id: "onbar", name: "On The Bar", url: "https://onbar.example.com/")],
            otherChildren: [rawURL(id: "other1", name: "In Other", url: "https://other1.example.com/")]
        )
        let visits = visitMap([
            "https://onbar.example.com/": now,
            "https://other1.example.com/": now.addingTimeInterval(-3600),
        ])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.recentAdditions.count == 2)
        #expect(plan.recentItems.map(\.title) == ["On The Bar", "In Other"])

        let recentFolder = BookmarkTreeFormatter.findNamedFolder("Recent", in: trees)!
        #expect(recentFolder.children.map(\.title) == ["On The Bar", "In Other"])
    }

    // MARK: - Subfolders inside Routine/Recent are untouched

    @Test func curateTreeLeavesSubfoldersInsideRoutineAndRecentUntouched() {
        let nestedInRoutine = rawFolder(id: "nested-routine", name: "Nested", children: [
            rawURL(id: "buried-chase", name: "Buried Chase", url: "https://chase.com/"),
        ])
        let nestedInRecent = rawFolder(id: "nested-recent", name: "Nested", children: [
            rawURL(id: "buried-recent", name: "Buried Recent", url: "https://buried.example.com/"),
        ])
        let trees = baseTrees(
            routineChildren: [nestedInRoutine],
            recentChildren: [nestedInRecent]
        )
        let visits = visitMap(["https://buried.example.com/": Date()])

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: visits)

        #expect(plan.routineAdditions.isEmpty)
        #expect(plan.routineEvictions.isEmpty)
        #expect(plan.recentAdditions.isEmpty)
        #expect(plan.recentEvictions.isEmpty)

        let routineFolder = BookmarkTreeFormatter.findNamedFolder("Routine", in: trees)!
        #expect(routineFolder.children.map { $0.raw["id"] as? String } == ["nested-routine"])
        #expect(routineFolder.children.first?.children.map { $0.raw["id"] as? String } == ["buried-chase"])

        let recentFolder = BookmarkTreeFormatter.findNamedFolder("Recent", in: trees)!
        #expect(recentFolder.children.map { $0.raw["id"] as? String } == ["nested-recent"])
    }

    @Test func curateTreeAppendsSubfoldersAfterURLChildrenInRoutine() {
        let subfolder = rawFolder(id: "sub", name: "Sub", children: [])
        let trees = baseTrees(
            otherChildren: [rawURL(id: "chase", name: "Chase", url: "https://chase.com/")],
            routineChildren: [subfolder]
        )

        _ = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])

        let routineFolder = BookmarkTreeFormatter.findNamedFolder("Routine", in: trees)!
        #expect(routineFolder.children.last?.raw["id"] as? String == "sub")
        #expect(routineFolder.children.last?.kind == .folder)
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

    @Test func curateTreeDedupsBeforeClassifying() {
        let trees = baseTrees(
            barChildren: [rawURL(id: "bar-chase", name: "Chase", url: "https://chase.com/")],
            otherChildren: [rawURL(id: "other-chase", name: "Chase Dupe", url: "https://chase.com/")]
        )

        let plan = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])

        #expect(plan.duplicates.count == 1)
        #expect(plan.routineItems.count == 1)
        #expect(plan.routineAdditions.count == 1)
    }

    @Test func curateTreeIsIdempotent() {
        let trees = baseTrees(otherChildren: [
            rawURL(id: "chase", name: "Chase", url: "https://chase.com/"),
        ])

        let first = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])
        #expect(!first.isEmpty)

        let second = BookmarkTreeFormatter.curateTree(trees: trees, recentVisits: [:])
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
        #expect(plan.routineItems.isEmpty)
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
            routineAdditions: [], routineEvictions: [],
            routineItems: [
                CuratedFolderItem(title: "Chase", url: "https://chase.com/", reason: "Banking"),
                CuratedFolderItem(title: "Geico", url: "https://geico.com/", reason: "Insurance"),
            ],
            routineReordered: false,
            recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
            otherBookmarksReordered: false,
            totalBookmarks: 4, totalFolders: 1
        )

        #expect(plan.duplicates(matching: "").count == 2)
        #expect(plan.routineItems(matching: "  ").count == 2)
        #expect(plan.duplicates(matching: "GITHUB").map(\.title) == ["GitHub"])
        #expect(plan.duplicates(matching: "docs.example").map(\.url) == ["https://docs.example.com/guide"])
        #expect(plan.routineItems(matching: "chase").map(\.title) == ["Chase"])
        #expect(plan.routineItems(matching: "insurance").isEmpty) // filters by title/url, not reason
        #expect(plan.duplicates(matching: "zzz").isEmpty)
        #expect(plan.routineItems(matching: "zzz").isEmpty)
    }

    @Test func confirmationSummaryOmitsZeroClauses() {
        let emptyPlan = FormatPlan(
            duplicates: [],
            routineAdditions: [], routineEvictions: [], routineItems: [], routineReordered: false,
            recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
            otherBookmarksReordered: false,
            totalBookmarks: 0, totalFolders: 0
        )
        #expect(emptyPlan.confirmationSummary.hasPrefix("Makes no changes."))

        let fullPlan = FormatPlan(
            duplicates: [DuplicateRemoval(title: "A", url: "https://a.example.com/", folderPath: "Bar", keptFolderPath: "Bar")],
            routineAdditions: [FolderMove(title: "New", url: "https://new.example.com/", reason: "Banking")],
            routineEvictions: [],
            routineItems: [], routineReordered: false,
            recentAdditions: [], recentEvictions: [
                FolderMove(title: "Old", url: "https://old.example.com/", reason: "Ranked outside the top 20 most visited"),
            ],
            recentItems: [], recentReordered: false,
            otherBookmarksReordered: true,
            totalBookmarks: 2, totalFolders: 1
        )
        let summary = fullPlan.confirmationSummary
        #expect(summary.hasPrefix("Removes 1 duplicates, updates Routine (1 added, 0 moved out), updates Recent (0 added, 1 moved out), sorts Other Bookmarks alphabetically."))

        let reorderOnlyPlan = FormatPlan(
            duplicates: [],
            routineAdditions: [], routineEvictions: [], routineItems: [], routineReordered: true,
            recentAdditions: [], recentEvictions: [], recentItems: [], recentReordered: false,
            otherBookmarksReordered: false,
            totalBookmarks: 3, totalFolders: 1
        )
        #expect(!reorderOnlyPlan.isEmpty)
        #expect(reorderOnlyPlan.confirmationSummary.hasPrefix("Sorts Routine."))
    }
}
