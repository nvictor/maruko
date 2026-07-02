import AppKit
import Combine
import Foundation
import OSLog

/// Orchestrates the direct-format flow: detect browsers, analyze a profile's
/// Bookmarks file against the rewrite rules, preview the plan, and apply or
/// undo the change through `SafeBookmarkWriter`.
@MainActor
final class BrowserFormatStore: ObservableObject {
    @Published private(set) var browsers: [DetectedBrowser] = []
    @Published private(set) var hasFolderAccess = false
    @Published var selectedProfile: BrowserProfile?

    @Published private(set) var isWorking = false
    @Published private(set) var plan: FormatPlan?
    @Published private(set) var browserIsRunning = false
    @Published private(set) var lastUndoRecord: SafeBookmarkWriter.UndoRecord?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// What Format Bookmarks does. Editing an option drops any pending plan —
    /// the profile view re-analyzes when it sees the change.
    @Published var formatOptions: FormatOptions {
        didSet {
            guard formatOptions != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(formatOptions), forKey: Self.formatOptionsKey)
            plan = nil
            pendingWrite = nil
        }
    }

    private static let formatOptionsKey = "maruko.formatOptions"
    private let accessManager = FolderAccessManager()
    private let writer = SafeBookmarkWriter()
    private let logger = Logger(subsystem: "com.mellowfleet.Maruko", category: "Format")

    /// The formatted file produced by the last analyze, plus the bytes it was
    /// computed from so apply can detect the file changing underneath us.
    private var pendingWrite: (source: Data, formatted: Data, profile: BrowserProfile)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.formatOptionsKey),
           let options = try? JSONDecoder().decode(FormatOptions.self, from: data) {
            formatOptions = options
        } else {
            formatOptions = .default
        }
    }

    // MARK: - Detection & access

    func refresh() {
        hasFolderAccess = accessManager.hasAccess
        browsers = scopedRead { BrowserDetector.detect(applicationSupportURL: $0) }
            ?? BrowserDetector.detect(applicationSupportURL: nil)
        refreshSelectionState()
    }

    func grantAccess() {
        guard let url = accessManager.requestAccess() else { return }

        if !FolderAccessManager.grantCoversBrowserData(url) {
            accessManager.revokeAccess()
            errorMessage = "That folder doesn't contain browser data. Please grant access to Application Support itself."
        }
        refresh()
    }

    func select(_ profile: BrowserProfile?) {
        selectedProfile = profile
        plan = nil
        pendingWrite = nil
        statusMessage = nil
        refreshSelectionState()
    }

    func recheckBrowserRunning() {
        refreshSelectionState()
    }

    private func refreshSelectionState() {
        guard let profile = selectedProfile else {
            browserIsRunning = false
            lastUndoRecord = nil
            return
        }
        browserIsRunning = BrowserDetector.isRunning(profile.browser)
        lastUndoRecord = writer.lastUndoRecord(for: profile.bookmarksFileURL)
    }

    // MARK: - Analyze / apply / undo

    func analyze(rules: [RewriteRuleSnapshot]) async {
        guard let profile = selectedProfile, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        defer {
            isWorking = false
            refreshSelectionState()
        }

        do {
            guard let scopeURL = accessManager.resolvedURL(), scopeURL.startAccessingSecurityScopedResource() else {
                throw NSError(
                    domain: "Maruko.Access",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Maruko no longer has access to Application Support. Grant access again."]
                )
            }
            defer { scopeURL.stopAccessingSecurityScopedResource() }

            let fileData = try Data(contentsOf: profile.bookmarksFileURL)
            let options = formatOptions
            let historyURL = profile.bookmarksFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("History")

            let result = try await Task.detached(priority: .userInitiated) {
                var recentVisits: [String: Date] = [:]
                if options.moveRecentToTop {
                    // Best-effort: a missing or unreadable History database
                    // just means nothing is "recent".
                    recentVisits = (try? BrowserHistoryReader.recentVisits(
                        historyDatabase: historyURL,
                        since: options.recencyCutoff
                    )) ?? [:]
                }
                return try BookmarkTreeFormatter.format(
                    fileData: fileData,
                    rules: rules,
                    options: options,
                    recentVisits: recentVisits
                )
            }.value

            plan = result.plan
            pendingWrite = (source: fileData, formatted: result.formattedData, profile: profile)
            logger.info("Analyzed \(profile.displayName, privacy: .public): \(result.plan.totalBookmarks) bookmarks, \(result.plan.duplicates.count) duplicates, \(result.plan.titleChanges.count) title changes")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Analyze failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func apply() {
        guard let pending = pendingWrite, let profile = selectedProfile,
              pending.profile == profile, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refreshSelectionState()
        }

        guard !BrowserDetector.isRunning(profile.browser) else {
            browserIsRunning = true
            errorMessage = "\(profile.browser.displayName) is running. Quit it before applying changes."
            return
        }

        do {
            try withScope { _ in
                let currentData = try Data(contentsOf: profile.bookmarksFileURL)
                guard currentData == pending.source else {
                    throw NSError(
                        domain: "Maruko.Format",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The Bookmarks file changed since it was analyzed. Analyze again before applying."]
                    )
                }
                try writer.apply(
                    pending.formatted,
                    to: profile.bookmarksFileURL,
                    browserFolder: profile.browser.rawValue,
                    profileFolder: profile.directoryName
                )
            }

            let summary = plan.map { plan in
                "Removed \(plan.duplicates.count) duplicates, rewrote \(plan.titleChanges.count) titles, moved recent bookmarks up in \(plan.reorderedFolderCount) folders."
            }
            statusMessage = "Bookmarks formatted. \(summary ?? "") A backup was saved."
            plan = nil
            pendingWrite = nil
            logger.info("Applied format to \(profile.bookmarksFileURL.path, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Apply failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func undoLastChange() {
        guard let profile = selectedProfile, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            refreshSelectionState()
        }

        guard !BrowserDetector.isRunning(profile.browser) else {
            browserIsRunning = true
            errorMessage = "\(profile.browser.displayName) is running. Quit it before undoing changes."
            return
        }

        do {
            _ = try withScope { _ in
                try writer.undoLastChange(
                    for: profile.bookmarksFileURL,
                    browserFolder: profile.browser.rawValue,
                    profileFolder: profile.directoryName
                )
            }
            statusMessage = "Restored the previous bookmarks. Undo again to reapply."
            plan = nil
            pendingWrite = nil
            logger.info("Undid last change for \(profile.bookmarksFileURL.path, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Undo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Security scope helpers

    private func withScope<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = accessManager.resolvedURL() else {
            throw NSError(
                domain: "Maruko.Access",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Maruko no longer has access to Application Support. Grant access again."]
            )
        }
        let hasScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasScope { url.stopAccessingSecurityScopedResource() }
        }
        return try body(url)
    }

    private func scopedRead<T>(_ body: (URL) -> T?) -> T? {
        guard let url = accessManager.resolvedURL() else { return nil }
        let hasScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasScope { url.stopAccessingSecurityScopedResource() }
        }
        return body(url)
    }
}
