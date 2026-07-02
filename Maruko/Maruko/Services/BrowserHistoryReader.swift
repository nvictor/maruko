import Foundation
import SQLite3

enum BrowserHistoryReaderError: LocalizedError {
    case cannotOpen(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let message):
            return "Could not open the browser history database: \(message)"
        case .queryFailed(let message):
            return "Could not read the browser history database: \(message)"
        }
    }
}

/// Reads recent visit times from a Chromium profile's `History` SQLite
/// database (the sibling of the `Bookmarks` file).
///
/// The browser holds a lock on the live database while it runs, so the file
/// (and its journal sidecars) is copied into Maruko's temporary directory and
/// the copy is opened read-only.
nonisolated enum BrowserHistoryReader {
    /// Normalized URL → most recent visit, for visits after `cutoff`.
    /// A missing database (fresh profile) is not an error: returns [:].
    static func recentVisits(historyDatabase: URL, since cutoff: Date) throws -> [String: Date] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: historyDatabase.path) else { return [:] }

        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("maruko-history-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let copy = scratch.appendingPathComponent("History")
        try fileManager.copyItem(at: historyDatabase, to: copy)
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: historyDatabase.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        return try visits(inDatabase: copy, since: cutoff)
    }

    static func visits(inDatabase database: URL, since cutoff: Date) throws -> [String: Date] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw BrowserHistoryReaderError.cannotOpen(message)
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT url, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BrowserHistoryReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, ChromeTimestamp.value(from: cutoff))

        var result: [String: Date] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw BrowserHistoryReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            guard let urlText = sqlite3_column_text(statement, 0) else { continue }
            let url = String(cString: urlText)
            guard let normalized = URLNormalizer.normalize(url) else { continue }

            let visited = ChromeTimestamp.date(from: sqlite3_column_int64(statement, 1))
            if let existing = result[normalized] {
                if visited > existing { result[normalized] = visited }
            } else {
                result[normalized] = visited
            }
        }
        return result
    }
}
