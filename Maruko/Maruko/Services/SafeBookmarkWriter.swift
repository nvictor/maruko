import Foundation

enum SafeBookmarkWriterError: LocalizedError {
    case bookmarksFileMissing(String)
    case nothingToUndo

    var errorDescription: String? {
        switch self {
        case .bookmarksFileMissing(let path):
            return "No Bookmarks file at \(path)."
        case .nothingToUndo:
            return "There is no Maruko change to undo for this profile."
        }
    }
}

/// Writes formatted bookmark data into a browser profile without ever leaving
/// the profile in a broken state: every write is preceded by a timestamped
/// backup into Maruko's own container, performed as an atomic replace, and
/// recorded so it can be undone. The browser's own `Bookmarks.bak` is never
/// touched.
nonisolated struct SafeBookmarkWriter {
    struct UndoRecord: Codable, Sendable {
        let bookmarksFilePath: String
        let backupFilePath: String
        let appliedAt: Date
    }

    static let maxBackupsPerProfile = 10

    private let backupsRoot: URL
    private let undoStateURL: URL
    private let fileManager = FileManager.default

    /// Uses `Application Support/Maruko` inside the app's sandbox container.
    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maruko", isDirectory: true)
        self.init(stateDirectory: base)
    }

    init(stateDirectory: URL) {
        backupsRoot = stateDirectory.appendingPathComponent("Backups", isDirectory: true)
        undoStateURL = stateDirectory.appendingPathComponent("undo-state.json")
    }

    /// Backs up the current file, atomically replaces it with `data`, prunes
    /// old backups, and records the change for undo.
    @discardableResult
    func apply(
        _ data: Data,
        to fileURL: URL,
        browserFolder: String,
        profileFolder: String,
        now: Date = Date()
    ) throws -> UndoRecord {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw SafeBookmarkWriterError.bookmarksFileMissing(fileURL.path)
        }

        let backupURL = try backUp(
            fileURL,
            browserFolder: browserFolder,
            profileFolder: profileFolder,
            now: now
        )
        try atomicallyReplace(fileURL, with: data)
        try prune(browserFolder: browserFolder, profileFolder: profileFolder)

        let record = UndoRecord(
            bookmarksFilePath: fileURL.path,
            backupFilePath: backupURL.path,
            appliedAt: now
        )
        var state = loadUndoState()
        state[fileURL.path] = record
        try saveUndoState(state)
        return record
    }

    /// Restores the state captured by the last `apply` (or the last undo —
    /// the current file is backed up first, so undoing twice is a redo).
    @discardableResult
    func undoLastChange(
        for fileURL: URL,
        browserFolder: String,
        profileFolder: String,
        now: Date = Date()
    ) throws -> UndoRecord {
        guard let record = lastUndoRecord(for: fileURL),
              fileManager.fileExists(atPath: record.backupFilePath) else {
            throw SafeBookmarkWriterError.nothingToUndo
        }

        let restoredData = try Data(contentsOf: URL(fileURLWithPath: record.backupFilePath))
        return try apply(
            restoredData,
            to: fileURL,
            browserFolder: browserFolder,
            profileFolder: profileFolder,
            now: now
        )
    }

    func lastUndoRecord(for fileURL: URL) -> UndoRecord? {
        loadUndoState()[fileURL.path]
    }

    // MARK: - Backups

    func backupsDirectory(browserFolder: String, profileFolder: String) -> URL {
        backupsRoot
            .appendingPathComponent(browserFolder, isDirectory: true)
            .appendingPathComponent(profileFolder, isDirectory: true)
    }

    private func backUp(
        _ fileURL: URL,
        browserFolder: String,
        profileFolder: String,
        now: Date
    ) throws -> URL {
        let directory = backupsDirectory(browserFolder: browserFolder, profileFolder: profileFolder)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var backupURL = directory.appendingPathComponent("Bookmarks-\(Self.timestamp(now)).json")
        var counter = 1
        while fileManager.fileExists(atPath: backupURL.path) {
            backupURL = directory.appendingPathComponent("Bookmarks-\(Self.timestamp(now))-\(counter).json")
            counter += 1
        }

        try fileManager.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }

    private func prune(browserFolder: String, profileFolder: String) throws {
        let directory = backupsDirectory(browserFolder: browserFolder, profileFolder: profileFolder)
        let backups = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        // Timestamped names sort chronologically.
        let sorted = backups
            .filter { $0.lastPathComponent.hasPrefix("Bookmarks-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for stale in sorted.dropFirst(Self.maxBackupsPerProfile) {
            try fileManager.removeItem(at: stale)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return formatter.string(from: date)
    }

    // MARK: - Atomic write

    private func atomicallyReplace(_ fileURL: URL, with data: Data) throws {
        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).maruko-\(UUID().uuidString)")
        try data.write(to: temporaryURL)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
    }

    // MARK: - Undo state

    private func loadUndoState() -> [String: UndoRecord] {
        guard let data = try? Data(contentsOf: undoStateURL) else { return [:] }
        return (try? JSONDecoder().decode([String: UndoRecord].self, from: data)) ?? [:]
    }

    private func saveUndoState(_ state: [String: UndoRecord]) throws {
        try fileManager.createDirectory(
            at: undoStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: undoStateURL)
    }
}
