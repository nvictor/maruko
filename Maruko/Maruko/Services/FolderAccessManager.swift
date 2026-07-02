import AppKit
import Foundation

/// One-time sandbox grant for `~/Library/Application Support`, persisted as a
/// security-scoped bookmark. A single grant of that folder covers every
/// Chromium browser's profile directory.
@MainActor
final class FolderAccessManager {
    private static let defaultsKey = "maruko.appSupportBookmark"

    /// The user's real `~/Library/Application Support`. Inside the sandbox,
    /// `NSHomeDirectory()` points at the app container, so resolve the actual
    /// home through the passwd database.
    nonisolated static var realApplicationSupportURL: URL {
        let home: String
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    var hasAccess: Bool {
        resolvedURL() != nil
    }

    /// Shows the grant panel and stores a security-scoped bookmark for the
    /// chosen folder. Returns nil if the user cancels.
    func requestAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.realApplicationSupportURL
        panel.prompt = "Grant Access"
        panel.message = "Maruko needs access to Application Support to read and format your browsers' bookmarks. Just click \"Grant Access\"."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.defaultsKey)
            return url
        } catch {
            return nil
        }
    }

    /// Resolves the stored grant, refreshing the bookmark if it went stale.
    func resolvedURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: Self.defaultsKey)
        }
        return url
    }

    func revokeAccess() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// True when the granted folder plausibly contains browser data — either
    /// Application Support itself or a folder holding a known browser
    /// directory. Guards against the user picking some unrelated folder.
    nonisolated static func grantCoversBrowserData(_ url: URL) -> Bool {
        if url.lastPathComponent == "Application Support" { return true }
        let fileManager = FileManager.default
        return BrowserKind.allCases.contains { kind in
            guard let relative = kind.dataDirectoryRelativePath else { return false }
            return fileManager.fileExists(atPath: url.appendingPathComponent(relative).path)
        }
    }
}
