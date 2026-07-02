import Foundation
import SQLite3
import Testing
@testable import Maruko

struct BrowserHistoryReaderTests {
    /// Builds a minimal Chromium-shaped History database.
    private func makeHistoryDatabase(rows: [(url: String, lastVisit: Date, hidden: Bool)]) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("History-\(UUID().uuidString)")

        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE urls(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url LONGVARCHAR,
            title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL,
            typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL,
            hidden INTEGER DEFAULT 0 NOT NULL
        )
        """
        #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)

        for row in rows {
            let insert = """
            INSERT INTO urls(url, title, last_visit_time, hidden)
            VALUES ('\(row.url)', '', \(ChromeTimestamp.value(from: row.lastVisit)), \(row.hidden ? 1 : 0))
            """
            #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
        }
        return path
    }

    @Test func returnsOnlyVisibleVisitsAfterCutoff() throws {
        let now = Date()
        let database = try makeHistoryDatabase(rows: [
            ("https://recent.example.com/", now.addingTimeInterval(-3600), false),
            ("https://old.example.com/", now.addingTimeInterval(-90 * 86_400), false),
            ("https://hidden.example.com/", now, true),
        ])

        let visits = try BrowserHistoryReader.visits(
            inDatabase: database,
            since: now.addingTimeInterval(-30 * 86_400)
        )

        #expect(visits.count == 1)
        #expect(visits["https://recent.example.com/"] != nil)
    }

    @Test func mergesURLVariantsKeepingNewestVisit() throws {
        let now = Date()
        let database = try makeHistoryDatabase(rows: [
            ("https://example.com/page#a", now.addingTimeInterval(-7200), false),
            ("https://example.com/page/", now.addingTimeInterval(-60), false),
        ])

        let visits = try BrowserHistoryReader.visits(
            inDatabase: database,
            since: now.addingTimeInterval(-86_400)
        )

        #expect(visits.count == 1)
        let visited = try #require(visits["https://example.com/page"])
        #expect(abs(visited.timeIntervalSince(now.addingTimeInterval(-60))) < 1)
    }

    @Test func missingDatabaseMeansNothingIsRecent() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("History-\(UUID().uuidString)")
        let visits = try BrowserHistoryReader.recentVisits(historyDatabase: missing, since: Date())
        #expect(visits.isEmpty)
    }

    @Test func copiesLiveDatabaseBeforeReading() throws {
        let now = Date()
        let database = try makeHistoryDatabase(rows: [
            ("https://recent.example.com/", now, false),
        ])

        let visits = try BrowserHistoryReader.recentVisits(
            historyDatabase: database,
            since: now.addingTimeInterval(-60)
        )
        #expect(visits.count == 1)
        // The original is untouched and still present.
        #expect(FileManager.default.fileExists(atPath: database.path))
    }
}
