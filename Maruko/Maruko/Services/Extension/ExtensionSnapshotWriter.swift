import Foundation

/// Saves the raw session payload the extension sent (the live bookmark tree
/// plus history) before anything is applied, for manual recovery. Undo via
/// inverse ops is not implemented for the extension path. These snapshots
/// are the safety net.
nonisolated struct ExtensionSnapshotWriter {
    static let maxSnapshots = 10

    private let snapshotsRoot: URL
    private let fileManager = FileManager.default

    /// Uses `Application Support/Maruko/ExtensionSnapshots` inside the
    /// app's sandbox container.
    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maruko", isDirectory: true)
            .appendingPathComponent("ExtensionSnapshots", isDirectory: true)
        self.init(snapshotsRoot: base)
    }

    init(snapshotsRoot: URL) {
        self.snapshotsRoot = snapshotsRoot
    }

    func directory(browser: String) -> URL {
        snapshotsRoot.appendingPathComponent(browser, isDirectory: true)
    }

    @discardableResult
    func save(_ payload: Data, browser: String, now: Date = Date()) throws -> URL {
        let directory = directory(browser: browser)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var url = directory.appendingPathComponent("bookmarks-\(Self.timestamp(now)).json")
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("bookmarks-\(Self.timestamp(now))-\(counter).json")
            counter += 1
        }
        try payload.write(to: url)
        try prune(browser: browser)
        return url
    }

    private func prune(browser: String) throws {
        let directory = directory(browser: browser)
        let snapshots = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        // Timestamped names sort chronologically.
        let sorted = snapshots
            .filter { $0.lastPathComponent.hasPrefix("bookmarks-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for stale in sorted.dropFirst(Self.maxSnapshots) {
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
}
