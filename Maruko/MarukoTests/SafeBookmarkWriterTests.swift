import Foundation
import Testing
@testable import Maruko

struct SafeBookmarkWriterTests {
    private let fileManager = FileManager.default

    private func makeSandbox() throws -> (writer: SafeBookmarkWriter, profile: URL, bookmarks: URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SafeBookmarkWriterTests-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("Chrome/Profile 1", isDirectory: true)
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)

        let bookmarks = profile.appendingPathComponent("Bookmarks")
        try Data(#"{"roots": {}, "version": 1}"#.utf8).write(to: bookmarks)
        try Data("chrome's own backup".utf8).write(to: profile.appendingPathComponent("Bookmarks.bak"))

        let writer = SafeBookmarkWriter(stateDirectory: root.appendingPathComponent("Maruko", isDirectory: true))
        return (writer, profile, bookmarks)
    }

    @Test func applyBacksUpBeforeWritingAndRecordsUndo() throws {
        let (writer, _, bookmarks) = try makeSandbox()
        let originalData = try Data(contentsOf: bookmarks)
        let newData = Data(#"{"roots": {}, "version": 2}"#.utf8)

        let record = try writer.apply(newData, to: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")

        #expect(try Data(contentsOf: bookmarks) == newData)
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.backupFilePath)) == originalData)
        #expect(writer.lastUndoRecord(for: bookmarks)?.backupFilePath == record.backupFilePath)
    }

    @Test func undoRestoresPreviousBytesAndIsItselfUndoable() throws {
        let (writer, _, bookmarks) = try makeSandbox()
        let originalData = try Data(contentsOf: bookmarks)
        let newData = Data(#"{"roots": {}, "version": 2}"#.utf8)

        try writer.apply(newData, to: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")
        try writer.undoLastChange(for: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")
        #expect(try Data(contentsOf: bookmarks) == originalData)

        // Undoing the undo restores the formatted state.
        try writer.undoLastChange(for: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")
        #expect(try Data(contentsOf: bookmarks) == newData)
    }

    @Test func undoWithoutPriorApplyThrows() throws {
        let (writer, _, bookmarks) = try makeSandbox()
        #expect(throws: SafeBookmarkWriterError.self) {
            try writer.undoLastChange(for: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")
        }
    }

    @Test func applyToMissingFileThrowsAndWritesNothing() throws {
        let (writer, profile, _) = try makeSandbox()
        let missing = profile.appendingPathComponent("DoesNotExist")

        #expect(throws: SafeBookmarkWriterError.self) {
            try writer.apply(Data("x".utf8), to: missing, browserFolder: "Chrome", profileFolder: "Profile 1")
        }
        #expect(!fileManager.fileExists(atPath: missing.path))
    }

    @Test func chromesOwnBackupIsNeverTouched() throws {
        let (writer, profile, bookmarks) = try makeSandbox()
        let bak = profile.appendingPathComponent("Bookmarks.bak")
        let bakBefore = try Data(contentsOf: bak)

        try writer.apply(Data("new".utf8), to: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")
        try writer.undoLastChange(for: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")

        #expect(try Data(contentsOf: bak) == bakBefore)
    }

    @Test func pruneKeepsTenNewestBackups() throws {
        let (writer, _, bookmarks) = try makeSandbox()
        let base = Date(timeIntervalSince1970: 1_750_000_000)

        for i in 0..<14 {
            try writer.apply(
                Data("revision \(i)".utf8),
                to: bookmarks,
                browserFolder: "Chrome",
                profileFolder: "Profile 1",
                now: base.addingTimeInterval(Double(i))
            )
        }

        let directory = writer.backupsDirectory(browserFolder: "Chrome", profileFolder: "Profile 1")
        let backups = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Bookmarks-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(backups.count == SafeBookmarkWriter.maxBackupsPerProfile)
        // The oldest surviving backup is revision 3 (revisions 0-2 pruned;
        // backup i captures the file before revision i was written).
        #expect(try Data(contentsOf: backups.first!) == Data("revision 3".utf8))

        // Undo still works against the newest backup.
        try writer.undoLastChange(for: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")
        #expect(try Data(contentsOf: bookmarks) == Data("revision 12".utf8))
    }

    @Test func writeIsAtomicReplaceLeavingNoTempFiles() throws {
        let (writer, profile, bookmarks) = try makeSandbox()
        try writer.apply(Data("new".utf8), to: bookmarks, browserFolder: "Chrome", profileFolder: "Profile 1")

        let leftovers = try fileManager.contentsOfDirectory(atPath: profile.path)
            .filter { $0.contains("maruko-") }
        #expect(leftovers.isEmpty)
    }
}
