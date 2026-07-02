import Foundation
import Testing
@testable import Maruko

struct BookmarkTreeFormatterTests {
    private func roots(fromFixture name: String) throws -> [BookmarkNode] {
        let file = try ChromiumBookmarksFile.load(data: Fixture.data(name))
        return ChromiumBookmarksFile.rootKeys.compactMap { key in
            file.rootNode(key).flatMap(BookmarkNode.init(raw:))
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

    @Test func formatProducesLoadableFileWithValidChecksumAndCounts() throws {
        let result = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-duplicates"),
            rules: []
        )

        #expect(result.plan.duplicates.count == 4)
        #expect(result.plan.titleChanges.isEmpty)
        #expect(result.plan.totalBookmarks == 3)
        #expect(result.plan.totalFolders == 1)

        let written = try ChromiumBookmarksFile.load(data: result.formattedData)
        #expect(written.computeChecksum() == written.root["checksum"] as? String)
    }

    @Test func formatPreservesGuidsIdsAndUnknownKeys() throws {
        let result = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-basic"),
            rules: []
        )
        let written = try JSONSerialization.jsonObject(with: result.formattedData) as! [String: Any]

        #expect(written["sync_metadata"] as? String == "QmFzZTY0U3luY0Jsb2I=")
        #expect(written["x_top_unknown"] != nil)

        var sawUnknownNodeKey = false
        var guids: Set<String> = []
        func walk(_ node: [String: Any]) {
            if node["x_unknown_key"] as? String == "keep me" { sawUnknownNodeKey = true }
            if let guid = node["guid"] as? String { guids.insert(guid) }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for root in (written["roots"] as! [String: Any]).values {
            walk(root as! [String: Any])
        }
        #expect(sawUnknownNodeKey)
        #expect(guids.count == 8)
    }

    @Test func optionsDisableIndividualSteps() throws {
        var options = FormatOptions.default
        options.removeDuplicates = false
        options.moveRecentToTop = false

        let result = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-duplicates"),
            rules: [],
            options: options,
            recentVisits: ["https://example.com/other": Date()]
        )
        #expect(result.plan.duplicates.isEmpty)
        #expect(result.plan.reorderedFolderCount == 0)
        #expect(result.plan.totalBookmarks == 7)
    }

    @Test func rewriteToggleOffIgnoresEnabledRules() throws {
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

        let result = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-basic"),
            rules: [rule],
            options: options
        )
        #expect(result.plan.titleChanges.isEmpty)
    }

    @Test func allOptionsOffLeavesFileContentUnchanged() throws {
        let options = FormatOptions(removeDuplicates: false, rewriteTitles: false, moveRecentToTop: false)
        let originalData = try Fixture.data("chrome-duplicates")
        let result = try BookmarkTreeFormatter.format(fileData: originalData, rules: [], options: options)

        #expect(result.plan.isEmpty)
        let written = try JSONSerialization.jsonObject(with: result.formattedData) as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: originalData) as? [String: Any]
        #expect(NSDictionary(dictionary: written ?? [:]) == NSDictionary(dictionary: original ?? [:]))
    }

    @Test func titleOverridesApplyByGuidAndRecordChanges() throws {
        // chrome-basic: the GitHub bookmark has guid ...000000000007.
        let overrides = ["00000000-0000-4000-8000-000000000007": "Maruko on GitHub"]
        let result = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-basic"),
            rules: [],
            titleOverrides: overrides
        )

        #expect(result.plan.titleChanges.count == 1)
        #expect(result.plan.titleChanges.first?.oldTitle == "GitHub")
        #expect(result.plan.titleChanges.first?.newTitle == "Maruko on GitHub")

        let written = try ChromiumBookmarksFile.load(data: result.formattedData)
        #expect(written.computeChecksum() == written.root["checksum"] as? String)
    }

    @Test func overrideWinsOverRegexRewriteInOneChange() throws {
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

        let result = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-basic"),
            rules: [regexRule],
            titleOverrides: overrides
        )

        let change = try #require(
            result.plan.titleChanges.first { $0.url == "https://github.com/nvictor/maruko" }
        )
        #expect(change.oldTitle == "GitHub")
        #expect(change.newTitle == "Final Title")
    }

    @Test func recentBookmarkCandidatesFilterByRecentVisits() throws {
        let candidates = try BookmarkTreeFormatter.recentBookmarkCandidates(
            fileData: Fixture.data("chrome-basic"),
            recentVisits: [
                "https://github.com/nvictor/maruko": Date(),
                "https://docs.example.com/guide": Date(),
            ]
        )

        #expect(candidates.map(\.title).sorted() == ["Docs", "GitHub"])
        #expect(candidates.allSatisfy { !$0.guid.isEmpty })

        let none = try BookmarkTreeFormatter.recentBookmarkCandidates(
            fileData: Fixture.data("chrome-basic"),
            recentVisits: [:]
        )
        #expect(none.isEmpty)
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

    @Test func formatIsIdempotent() throws {
        let recentVisits = ["https://dd.example.com/": Date()]
        let first = try BookmarkTreeFormatter.format(
            fileData: Fixture.data("chrome-unsorted"),
            rules: [],
            recentVisits: recentVisits
        )
        #expect(!first.plan.isEmpty)

        let second = try BookmarkTreeFormatter.format(
            fileData: first.formattedData,
            rules: [],
            recentVisits: recentVisits
        )
        #expect(second.plan.isEmpty)
    }
}
