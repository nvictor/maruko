import Foundation
import Testing
@testable import Maruko

struct ChromiumBookmarksFileTests {
    @Test func checksumMatchesChromiumAlgorithm() throws {
        let file = try ChromiumBookmarksFile.load(data: Fixture.data("chrome-basic"))
        #expect(file.computeChecksum() == file.root["checksum"] as? String)
    }

    @Test func unmodifiedRoundTripPreservesEveryKey() throws {
        let originalData = try Fixture.data("chrome-basic")
        let file = try ChromiumBookmarksFile.load(data: originalData)
        let written = try JSONSerialization.jsonObject(with: file.serialized()) as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: originalData) as? [String: Any]

        // Deep equality: unknown keys (sync_metadata, meta_info, x_* extras)
        // and the checksum itself must survive untouched.
        #expect(NSDictionary(dictionary: written ?? [:]) == NSDictionary(dictionary: original ?? [:]))
    }

    @Test func replaceChildrenTouchesOnlyChildrenAndChecksum() throws {
        let originalData = try Fixture.data("chrome-basic")
        var file = try ChromiumBookmarksFile.load(data: originalData)
        let originalBar = file.rootNode("bookmark_bar")!
        let originalChecksum = file.computeChecksum()

        let survivors = (originalBar["children"] as! [[String: Any]]).dropLast()
        file.replaceChildren(ofRoot: "bookmark_bar", with: Array(survivors))

        let written = try JSONSerialization.jsonObject(with: file.serialized()) as! [String: Any]
        let writtenRoots = written["roots"] as! [String: Any]
        let writtenBar = writtenRoots["bookmark_bar"] as! [String: Any]

        #expect((writtenBar["children"] as! [[String: Any]]).count == survivors.count)
        for key in originalBar.keys where key != "children" {
            let unchanged = (originalBar[key] as AnyObject).isEqual(writtenBar[key] as AnyObject)
            #expect(unchanged, "unexpected change in bookmark_bar.\(key)")
        }
        #expect(written["checksum"] as? String != originalChecksum)
        #expect(written["checksum"] as? String == file.computeChecksum())
        #expect(written["sync_metadata"] as? String == file.root["sync_metadata"] as? String)
        #expect(writtenRoots["other"] != nil)
        #expect(writtenRoots["synced"] != nil)
    }

    @Test func rejectsFilesWithoutRoots() {
        let junk = Data(#"{"version": 1}"#.utf8)
        #expect(throws: ChromiumBookmarksFileError.self) {
            _ = try ChromiumBookmarksFile.load(data: junk)
        }
    }
}
