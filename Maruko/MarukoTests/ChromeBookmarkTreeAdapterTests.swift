import Foundation
import Testing
@testable import Maruko

struct ChromeBookmarkTreeAdapterTests {
    private func fixtureTree() throws -> [ChromeBookmarkNode] {
        try JSONDecoder().decode([ChromeBookmarkNode].self, from: Fixture.data("chrome-get-tree"))
    }

    @Test func mapsRootsByFolderTypeAndSkipsManaged() throws {
        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: fixtureTree())

        #expect(trees.map(\.rootKey) == ["bookmark_bar", "other", "synced"])
        #expect(trees.map(\.chromeRootID) == ["1", "2", "3"])
    }

    @Test func mapsRootsPositionallyWhenFolderTypeAbsent() throws {
        let json = Data("""
        [{"id": "0", "title": "", "children": [
            {"id": "1", "title": "Bar", "children": []},
            {"id": "2", "title": "Other", "children": []},
            {"id": "3", "title": "Mobile", "children": []}
        ]}]
        """.utf8)
        let tree = try JSONDecoder().decode([ChromeBookmarkNode].self, from: json)
        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: tree)

        #expect(trees.map(\.rootKey) == ["bookmark_bar", "other", "synced"])
    }

    @Test func synthesizesGuidFromChromeId() throws {
        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: fixtureTree())

        var checked = 0
        func walk(_ node: BookmarkNode) {
            #expect(node.raw["guid"] as? String == node.raw["id"] as? String)
            checked += 1
            for child in node.children { walk(child) }
        }
        for tree in trees { walk(tree.node) }
        // 3 roots + 1 subfolder + 7 urls; the managed root's url never appears.
        #expect(checked == 11)
    }

    @Test func adaptedNodesRoundTripKindsAndTitles() throws {
        let trees = try ChromeBookmarkTreeAdapter.adapt(tree: fixtureTree())
        let bar = trees[0].node

        #expect(bar.kind == .folder)
        #expect(bar.children.count == 2)
        #expect(bar.children[0].kind == .url)
        #expect(bar.children[0].title == "GitHub")
        #expect(bar.children[0].url == "https://github.com/")
        #expect(bar.children[1].kind == .folder)
        #expect(bar.children[1].children.map(\.title) == ["Swift Docs", "GitHub again", "MDN"])
    }

    @Test func childOrdersCoverEveryReachableFolder() throws {
        let orders = ChromeBookmarkTreeAdapter.childOrders(tree: try fixtureTree())

        #expect(orders["1"] == ["10", "11"])
        #expect(orders["11"] == ["12", "13", "14"])
        #expect(orders["2"] == ["20", "21", "22"])
        #expect(orders["3"] == [])
        // Managed root is not reachable.
        #expect(orders["4"] == nil)
    }

    @Test func throwsWhenNoRootsAreRecognizable() throws {
        let json = Data("""
        [{"id": "0", "title": "", "children": [
            {"id": "99", "title": "Mystery", "children": []}
        ]}]
        """.utf8)
        let tree = try JSONDecoder().decode([ChromeBookmarkNode].self, from: json)

        #expect(throws: ChromeBookmarkTreeAdapterError.self) {
            _ = try ChromeBookmarkTreeAdapter.adapt(tree: tree)
        }
    }
}
