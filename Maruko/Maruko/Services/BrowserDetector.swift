import AppKit
import Foundation

nonisolated enum BrowserKind: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case brave
    case edge
    case arc
    case safari
    case firefox
    case orion

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .safari: "Safari"
        case .firefox: "Firefox"
        case .orion: "Orion"
        }
    }

    var bundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .arc: "company.thebrowser.Browser"
        case .safari: "com.apple.Safari"
        case .firefox: "org.mozilla.firefox"
        case .orion: "com.kagi.kagimacOS"
        }
    }

    /// Where the browser keeps its profiles, relative to
    /// `~/Library/Application Support`. Nil for browsers that don't store
    /// Chromium-style profiles there.
    var dataDirectoryRelativePath: String? {
        switch self {
        case .chrome: "Google/Chrome"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .arc: "Arc/User Data"
        case .safari, .firefox, .orion: nil
        }
    }

    /// v0.1 formats Chromium-family bookmarks only.
    var isSupported: Bool {
        dataDirectoryRelativePath != nil
    }
}

nonisolated struct BrowserProfile: Identifiable, Hashable, Sendable {
    let browser: BrowserKind
    let directoryName: String
    let displayName: String
    let bookmarksFileURL: URL

    var id: String { bookmarksFileURL.path }
}

nonisolated struct DetectedBrowser: Identifiable, Sendable {
    let kind: BrowserKind
    let profiles: [BrowserProfile]

    var id: BrowserKind { kind }
}

enum BrowserDetector {
    /// Chromium reserves these directory names for non-user profiles.
    nonisolated private static let excludedProfileDirectories: Set<String> = ["System Profile", "Guest Profile"]

    static func installedBrowsers() -> [BrowserKind] {
        BrowserKind.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    static func isRunning(_ kind: BrowserKind) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == kind.bundleID }
    }

    /// All installed browsers with their profiles. `applicationSupportURL` is
    /// the security-scope-granted folder; supported browsers get their
    /// profiles enumerated, unsupported ones appear with none ("coming soon").
    static func detect(applicationSupportURL: URL?) -> [DetectedBrowser] {
        installedBrowsers().map { kind in
            guard let applicationSupportURL, kind.isSupported else {
                return DetectedBrowser(kind: kind, profiles: [])
            }
            return DetectedBrowser(
                kind: kind,
                profiles: profiles(for: kind, applicationSupportURL: applicationSupportURL)
            )
        }
    }

    /// Profile subdirectories that contain a `Bookmarks` file, with
    /// human-readable names from the browser's `Local State` when available.
    nonisolated static func profiles(for kind: BrowserKind, applicationSupportURL: URL) -> [BrowserProfile] {
        guard let relative = kind.dataDirectoryRelativePath else { return [] }
        let dataDirectory = applicationSupportURL.appendingPathComponent(relative, isDirectory: true)
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: dataDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let displayNames = profileDisplayNames(dataDirectory: dataDirectory)

        return entries
            .filter { entry in
                let name = entry.lastPathComponent
                guard !Self.excludedProfileDirectories.contains(name) else { return false }
                return fileManager.fileExists(atPath: entry.appendingPathComponent("Bookmarks").path)
            }
            .map { entry in
                let directoryName = entry.lastPathComponent
                return BrowserProfile(
                    browser: kind,
                    directoryName: directoryName,
                    displayName: displayNames[directoryName] ?? directoryName,
                    bookmarksFileURL: entry.appendingPathComponent("Bookmarks")
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Reads `Local State` → `profile.info_cache.<dir>.name`.
    nonisolated private static func profileDisplayNames(dataDirectory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any] else {
            return [:]
        }

        return infoCache.reduce(into: [:]) { result, entry in
            if let info = entry.value as? [String: Any], let name = info["name"] as? String {
                result[entry.key] = name
            }
        }
    }
}
