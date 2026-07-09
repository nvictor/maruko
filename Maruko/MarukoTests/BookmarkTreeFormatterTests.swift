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

    @Test func dedupeKeepsFirstDepthFirstOccurrence() throws {
        let roots = try self.roots(fromFixture: "chrome-duplicates")
        let removals = BookmarkTreeFormatter.removeDuplicates(in: roots)

        // page/, page#section, EXAMPLE.com/page all normalize to the kept
        // /page; the query-order variant in Other Bookmarks loses to the one
        // seen first in DFS order.
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
        // "Nested" survives even though dedupe emptied it.
        #expect(folderTitles.contains("Nested"))
    }

    @Test func rewriteAppliesRulesAndRecordsChanges() throws {
        let roots = try self.roots(fromFixture: "chrome-basic")
        let rule = RewriteRuleSnapshot(
            id: UUID(),
            name: "GitHub Repo Title",
            isEnabled: true,
            order: 0,
            kind: .regexMatchReplace,
            matchField: .url,
            pattern: #"^https://github\.com/([^/]+)/([^/?#]+)$"#,
            replacementTemplate: "github > $1 > $2",
            isCaseSensitive: false,
            createdAt: Date()
        )

        let changes = BookmarkTreeFormatter.rewriteTitles(in: roots, rules: [rule])

        #expect(changes.count == 1)
        #expect(changes.first?.oldTitle == "GitHub")
        #expect(changes.first?.newTitle == "github > nvictor > maruko")
        #expect(changes.first?.folderPath == "Bookmarks Bar / Dev Tools")
    }

    @Test func disabledRulesChangeNothing() throws {
        let roots = try self.roots(fromFixture: "chrome-basic")
        let rule = RewriteRuleSnapshot(
            id: UUID(),
            name: "Disabled",
            isEnabled: false,
            order: 0,
            kind: .regexMatchReplace,
            matchField: .title,
            pattern: ".*",
            replacementTemplate: "clobbered",
            isCaseSensitive: false,
            createdAt: Date()
        )
        #expect(BookmarkTreeFormatter.rewriteTitles(in: roots, rules: [rule]).isEmpty)
    }

    @Test func recentItemsMoveToTopOfTheirFolderMostRecentFirst() throws {
        let roots = try self.roots(fromFixture: "chrome-unsorted")
        let now = Date()
        let recentVisits = [
            "https://d.example.com/": now.addingTimeInterval(-3600),
            "https://dd.example.com/": now,
        ]

        let reordered = BookmarkTreeFormatter.moveRecentToTop(
            in: roots[0],
            recentVisits: recentVisits,
            skipThisFolder: true
        )

        let aFolder = roots[0].children.first { $0.title == "A Folder" }!
        #expect(aFolder.children.map(\.title) == ["Delta", "delta"])
        #expect(reordered == 1)
    }

    @Test func bookmarkBarTopLevelIsNeverReordered() throws {
        let roots = try self.roots(fromFixture: "chrome-unsorted")
        let originalOrder = roots[0].children.map(\.title)
        // Everything directly in the bar was opened recently.
        let recentVisits = [
            "https://z.example.com/": Date(),
            "https://a.example.com/": Date(),
            "https://aa.example.com/": Date(),
        ]

        let reordered = BookmarkTreeFormatter.moveRecentToTop(
            in: roots[0],
            recentVisits: recentVisits,
            skipThisFolder: true
        )

        #expect(roots[0].children.map(\.title) == originalOrder)
        #expect(reordered == 0)
    }

    @Test func nonRecentItemsKeepTheirOrder() throws {
        let roots = try self.roots(fromFixture: "chrome-unsorted")
        // beta lives in "B Folder"; moving it is a no-op since it is alone,
        // and nothing else appears in history.
        let reordered = BookmarkTreeFormatter.moveRecentToTop(
            in: roots[0],
            recentVisits: ["https://b.example.com/": Date()],
            skipThisFolder: true
        )

        #expect(reordered == 0)
        let aFolder = roots[0].children.first { $0.title == "A Folder" }!
        #expect(aFolder.children.map(\.title) == ["delta", "Delta"])
    }

    @Test func formatTreeProducesPlanWithCounts() throws {
        let trees = try self.trees(fromFixture: "chrome-duplicates")
        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [])

        #expect(plan.duplicates.count == 4)
        #expect(plan.titleChanges.isEmpty)
        #expect(plan.totalBookmarks == 3)
        #expect(plan.totalFolders == 1)
    }

    @Test func formatTreePreservesGuidsAndUnknownKeys() throws {
        let trees = try self.trees(fromFixture: "chrome-basic")
        _ = BookmarkTreeFormatter.formatTree(trees: trees, rules: [])

        var sawUnknownNodeKey = false
        var guids: Set<String> = []
        func walk(_ node: BookmarkNode) {
            if node.raw["x_unknown_key"] as? String == "keep me" { sawUnknownNodeKey = true }
            if let guid = node.raw["guid"] as? String { guids.insert(guid) }
            node.children.forEach(walk)
        }
        trees.map(\.node).forEach(walk)

        #expect(sawUnknownNodeKey)
        #expect(guids.count == 8)
    }

    @Test func optionsDisableIndividualSteps() throws {
        let trees = try self.trees(fromFixture: "chrome-duplicates")
        var options = FormatOptions.default
        options.removeDuplicates = false
        options.moveRecentToTop = false

        let plan = BookmarkTreeFormatter.formatTree(
            trees: trees,
            rules: [],
            options: options,
            recentVisits: ["https://example.com/other": Date()]
        )
        #expect(plan.duplicates.isEmpty)
        #expect(plan.reorderedFolderCount == 0)
        #expect(plan.totalBookmarks == 7)
    }

    @Test func rewriteToggleOffIgnoresEnabledRules() throws {
        let trees = try self.trees(fromFixture: "chrome-basic")
        let rule = RewriteRuleSnapshot(
            id: UUID(),
            name: "GitHub Repo Title",
            isEnabled: true,
            order: 0,
            kind: .regexMatchReplace,
            matchField: .url,
            pattern: #"^https://github\.com/([^/]+)/([^/?#]+)$"#,
            replacementTemplate: "github > $1 > $2",
            isCaseSensitive: false,
            createdAt: Date()
        )
        var options = FormatOptions.default
        options.rewriteTitles = false

        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [rule], options: options)
        #expect(plan.titleChanges.isEmpty)
    }

    @Test func allOptionsOffProducesAnEmptyPlan() throws {
        let trees = try self.trees(fromFixture: "chrome-duplicates")
        let options = FormatOptions(removeDuplicates: false, rewriteTitles: false, moveRecentToTop: false)

        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [], options: options)
        #expect(plan.isEmpty)
    }

    @Test func titleOverridesApplyByGuidAndRecordChanges() throws {
        // chrome-basic: the GitHub bookmark has guid ...000000000007.
        let trees = try self.trees(fromFixture: "chrome-basic")
        let overrides = ["00000000-0000-4000-8000-000000000007": "Maruko on GitHub"]

        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [], titleOverrides: overrides)

        #expect(plan.titleChanges.count == 1)
        #expect(plan.titleChanges.first?.oldTitle == "GitHub")
        #expect(plan.titleChanges.first?.newTitle == "Maruko on GitHub")
    }

    @Test func overrideWinsOverRegexRewriteInOneChange() throws {
        let trees = try self.trees(fromFixture: "chrome-basic")
        let regexRule = RewriteRuleSnapshot(
            id: UUID(),
            name: "GitHub Repo Title",
            isEnabled: true,
            order: 0,
            kind: .regexMatchReplace,
            matchField: .url,
            pattern: #"^https://github\.com/([^/]+)/([^/?#]+)$"#,
            replacementTemplate: "github > $1 > $2",
            isCaseSensitive: false,
            createdAt: Date()
        )
        let overrides = ["00000000-0000-4000-8000-000000000007": "Final Title"]

        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [regexRule], titleOverrides: overrides)

        let change = try #require(
            plan.titleChanges.first { $0.url == "https://github.com/nvictor/maruko" }
        )
        #expect(change.oldTitle == "GitHub")
        #expect(change.newTitle == "Final Title")
    }

    @Test func recentBookmarkCandidatesFilterByRecentVisits() throws {
        let trees = try self.trees(fromFixture: "chrome-basic")
        let candidates = BookmarkTreeFormatter.recentBookmarkCandidates(
            trees: trees,
            recentVisits: [
                "https://example.com/": Date(),
                "https://github.com/nvictor/maruko": Date(),
                "https://cafe.example.com/recipes?a=1&b=2": Date(),
                "https://docs.example.com/guide": Date(),
            ]
        )

        // Direct bookmark bar URL items are skipped. Items in subfolders on
        // the bar, and items outside the bar, remain eligible.
        #expect(candidates.map(\.title).sorted() == ["Docs", "GitHub"])
        #expect(candidates.allSatisfy { !$0.guid.isEmpty })

        let none = BookmarkTreeFormatter.recentBookmarkCandidates(trees: trees, recentVisits: [:])
        #expect(none.isEmpty)
    }

    @Test func recentBookmarkCandidatesSkipEmptyTitles() {
        let tree = BookmarkNode(raw: [
            "type": "folder",
            "name": "Other Bookmarks",
            "children": [
                [
                    "type": "url",
                    "name": "",
                    "guid": "empty-title",
                    "url": "https://empty.example.com/",
                ],
                [
                    "type": "url",
                    "name": "Article Notes",
                    "guid": "article-notes",
                    "url": "https://article.example.com/",
                ],
            ],
        ])!

        let candidates = BookmarkTreeFormatter.recentBookmarkCandidates(
            trees: [(rootKey: "other", node: tree)],
            recentVisits: [
                "https://empty.example.com/": Date(),
                "https://article.example.com/": Date(),
            ]
        )

        #expect(candidates.map(\.title) == ["Article Notes"])
    }

    @Test func planFilterMatchesTitleAndURLCaseInsensitively() {
        let plan = FormatPlan(
            duplicates: [
                DuplicateRemoval(title: "GitHub", url: "https://github.com/nvictor/maruko", folderPath: "Bar", keptFolderPath: "Bar"),
                DuplicateRemoval(title: "", url: "https://docs.example.com/guide", folderPath: "Bar", keptFolderPath: "Bar"),
            ],
            titleChanges: [
                TitleChange(url: "https://github.com/nvictor/maruko", oldTitle: "GitHub", newTitle: "github > nvictor > maruko", folderPath: "Bar"),
                TitleChange(url: "https://news.example.com/", oldTitle: "Old News", newTitle: "News", folderPath: "Bar"),
            ],
            reorderedFolderCount: 0,
            recentFolderMoves: [],
            totalBookmarks: 4,
            totalFolders: 1
        )

        // Empty and whitespace-only queries match everything.
        #expect(plan.duplicates(matching: "").count == 2)
        #expect(plan.titleChanges(matching: "  ").count == 2)

        // Case-insensitive title match.
        #expect(plan.duplicates(matching: "GITHUB").map(\.title) == ["GitHub"])

        // URL match, including entries with empty titles.
        #expect(plan.duplicates(matching: "docs.example").map(\.url) == ["https://docs.example.com/guide"])

        // Title changes match on old title, new title, and URL.
        #expect(plan.titleChanges(matching: "old news").map(\.newTitle) == ["News"])
        #expect(plan.titleChanges(matching: "nvictor > maruko").count == 1)
        #expect(plan.titleChanges(matching: "news.example").map(\.newTitle) == ["News"])

        // No match returns empty.
        #expect(plan.duplicates(matching: "zzz").isEmpty)
        #expect(plan.titleChanges(matching: "zzz").isEmpty)
    }

    @Test func formatTreeIsIdempotent() throws {
        let trees = try self.trees(fromFixture: "chrome-unsorted")
        let recentVisits = ["https://dd.example.com/": Date()]

        let first = BookmarkTreeFormatter.formatTree(trees: trees, rules: [], recentVisits: recentVisits)
        #expect(!first.isEmpty)

        // Formatting the already-formatted (mutated in place) trees again
        // should find nothing left to change.
        let second = BookmarkTreeFormatter.formatTree(trees: trees, rules: [], recentVisits: recentVisits)
        #expect(second.isEmpty)
    }

    // MARK: - "Recent" folder curation

    private func rawURL(id: String, name: String, url: String) -> [String: Any] {
        ["type": "url", "id": id, "guid": id, "name": name, "url": url]
    }

    private func rawFolder(id: String, name: String, children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "id": id, "guid": id, "name": name, "children": children]
    }

    @Test func findRecentFolderLocatesNestedFolderByExactTitle() {
        let recent = rawFolder(id: "10", name: "Recent", children: [])
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [
            rawFolder(id: "2", name: "Other Stuff", children: [recent]),
        ]))!
        let other = BookmarkNode(raw: rawFolder(id: "3", name: "Other Bookmarks", children: []))!

        let found = BookmarkTreeFormatter.findRecentFolder(in: [
            (rootKey: "bookmark_bar", node: bar),
            (rootKey: "other", node: other),
        ])

        #expect(found?.title == "Recent")
        #expect(found?.raw["id"] as? String == "10")
    }

    @Test func findRecentFolderPrefersBookmarkBarThenOtherThenSynced() {
        let recentInOther = rawFolder(id: "20", name: "Recent", children: [])
        let recentInSynced = rawFolder(id: "30", name: "Recent", children: [])
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: []))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: [recentInOther]))!
        let synced = BookmarkNode(raw: rawFolder(id: "3", name: "Mobile Bookmarks", children: [recentInSynced]))!

        let found = BookmarkTreeFormatter.findRecentFolder(in: [
            (rootKey: "synced", node: synced),
            (rootKey: "other", node: other),
            (rootKey: "bookmark_bar", node: bar),
        ])

        // "other" beats "synced" per the fixed priority order, even though
        // it appears later in the input array.
        #expect(found?.raw["id"] as? String == "20")
    }

    @Test func findRecentFolderReturnsNilWhenAbsent() {
        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: []))!
        #expect(BookmarkTreeFormatter.findRecentFolder(in: [(rootKey: "bookmark_bar", node: bar)]) == nil)
    }

    @Test func curateRecentFolderSortsByRecencyAndRanksUnvisitedLast() {
        let now = Date()
        let recent = BookmarkNode(raw: rawFolder(id: "10", name: "Recent", children: [
            rawURL(id: "a", name: "A", url: "https://a.example.com/"),
            rawURL(id: "b", name: "B", url: "https://b.example.com/"),
            rawURL(id: "c", name: "C (never visited)", url: "https://c.example.com/"),
        ]))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: []))!
        let visits = [
            "https://a.example.com/": now.addingTimeInterval(-3600),
            "https://b.example.com/": now,
        ]

        let moves = BookmarkTreeFormatter.curateRecentFolder(recent, otherRoot: other, recentVisits: visits, maxKept: 20)

        #expect(moves.isEmpty)
        #expect(recent.children.map(\.title) == ["B", "A", "C (never visited)"])
    }

    @Test func curateRecentFolderKeepsExactlyTwentyWithoutEviction() {
        let children = (1...20).map { rawURL(id: "\($0)", name: "Item \($0)", url: "https://\($0).example.com/") }
        let recent = BookmarkNode(raw: rawFolder(id: "10", name: "Recent", children: children))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: []))!

        let moves = BookmarkTreeFormatter.curateRecentFolder(recent, otherRoot: other, recentVisits: [:], maxKept: 20)

        #expect(moves.isEmpty)
        #expect(recent.children.count == 20)
        #expect(other.children.isEmpty)
    }

    @Test func curateRecentFolderEvictsOldestBeyondCapToOtherBookmarks() {
        let now = Date()
        var raws: [[String: Any]] = []
        var visits: [String: Date] = [:]
        for i in 1...22 {
            let url = "https://item\(i).example.com/"
            raws.append(rawURL(id: "\(i)", name: "Item \(i)", url: url))
            // Higher i = more recently visited; items 1 and 2 are oldest.
            visits[url] = now.addingTimeInterval(Double(i))
        }
        let recent = BookmarkNode(raw: rawFolder(id: "10", name: "Recent", children: raws))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: []))!

        let moves = BookmarkTreeFormatter.curateRecentFolder(recent, otherRoot: other, recentVisits: visits, maxKept: 20)

        #expect(recent.children.count == 20)
        #expect(recent.children.first?.title == "Item 22")
        #expect(moves.map(\.title) == ["Item 2", "Item 1"])
        #expect(moves.allSatisfy { $0.toFolderID == "2" })
        #expect(other.children.map(\.title) == ["Item 2", "Item 1"])
    }

    @Test func curateRecentFolderLeavesSubfoldersInPlaceAfterURLChildren() {
        let subfolder = rawFolder(id: "99", name: "Nested", children: [])
        let raws: [[String: Any]] = [subfolder] + (1...3).map {
            rawURL(id: "\($0)", name: "Item \($0)", url: "https://\($0).example.com/")
        }
        let recent = BookmarkNode(raw: rawFolder(id: "10", name: "Recent", children: raws))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: []))!

        _ = BookmarkTreeFormatter.curateRecentFolder(recent, otherRoot: other, recentVisits: [:], maxKept: 20)

        #expect(recent.children.last?.title == "Nested")
        #expect(recent.children.last?.kind == .folder)
    }

    @Test func curateRecentFolderNoOpsWhenOtherRootMissing() {
        let recent = BookmarkNode(raw: rawFolder(id: "10", name: "Recent", children: (1...25).map {
            rawURL(id: "\($0)", name: "Item \($0)", url: "https://\($0).example.com/")
        }))!

        let moves = BookmarkTreeFormatter.curateRecentFolder(recent, otherRoot: nil, recentVisits: [:], maxKept: 20)

        #expect(moves.isEmpty)
        #expect(recent.children.count == 25)
    }

    @Test func formatTreeCuratesRecentFolderInsteadOfLegacyGlobalReorder() throws {
        let now = Date()
        var recentChildren: [[String: Any]] = []
        var visits: [String: Date] = [:]
        for i in 1...22 {
            let url = "https://recent\(i).example.com/"
            recentChildren.append(rawURL(id: "r\(i)", name: "Item \(i)", url: url))
            visits[url] = now.addingTimeInterval(Double(i))
        }
        let recentFolderRaw = rawFolder(id: "10", name: "Recent", children: recentChildren)

        // A second folder, elsewhere in the tree, whose contents WOULD be
        // reordered by the legacy global pass if it ran.
        let elsewhereVisit = "https://elsewhere.example.com/"
        visits[elsewhereVisit] = now
        let elsewhereFolderRaw = rawFolder(id: "20", name: "Elsewhere", children: [
            rawURL(id: "e1", name: "Old", url: "https://old.example.com/"),
            rawURL(id: "e2", name: "New", url: elsewhereVisit),
        ])

        let bar = BookmarkNode(raw: rawFolder(id: "1", name: "Bookmarks Bar", children: [recentFolderRaw, elsewhereFolderRaw]))!
        let other = BookmarkNode(raw: rawFolder(id: "2", name: "Other Bookmarks", children: []))!

        let trees: [(rootKey: String, node: BookmarkNode)] = [
            (rootKey: "bookmark_bar", node: bar),
            (rootKey: "other", node: other),
        ]

        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [], recentVisits: visits)

        #expect(plan.reorderedFolderCount == 0)
        #expect(plan.recentFolderMoves.count == 2)

        let elsewhere = bar.children.first { $0.title == "Elsewhere" }!
        // Legacy reorder never ran: "Old" is still before "New" even though
        // "New" was visited more recently.
        #expect(elsewhere.children.map(\.title) == ["Old", "New"])
    }

    @Test func formatTreeUsesLegacyGlobalReorderWhenNoRecentFolderExists() throws {
        let trees = try self.trees(fromFixture: "chrome-unsorted")
        let recentVisits = ["https://dd.example.com/": Date()]

        let plan = BookmarkTreeFormatter.formatTree(trees: trees, rules: [], recentVisits: recentVisits)

        #expect(plan.reorderedFolderCount > 0)
        #expect(plan.recentFolderMoves.isEmpty)
    }
}
