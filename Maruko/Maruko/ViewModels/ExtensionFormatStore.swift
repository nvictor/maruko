import AppKit
import Combine
import Foundation
import OSLog

private enum SortRecentFolderError: Error {
    case noRecentFolder
}

/// Orchestrates Maruko's formatting flow: run the localhost server the
/// Chrome extension talks to, analyze the live tree it sends, preview the
/// plan, and hand the confirmed op list back for the extension to apply.
/// This works with Chrome running and Sync on. Every edit goes through
/// chrome.bookmarks and is journaled by sync, so nothing gets reverted.
@MainActor
final class ExtensionFormatStore: ObservableObject {
    enum ServerState: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// UI-facing phase; `waitingForSession` covers "server up, nothing sent
    /// yet" and `waitingForExtension` covers opsReady/applying.
    enum Phase: Equatable {
        case waitingForSession
        case analyzing
        case awaitingConfirmation
        case waitingForExtension
        case applied
        case failed
    }

    struct TitleRefreshProgress: Equatable {
        var processed: Int
        var total: Int
    }

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var pairingCode: String?
    @Published private(set) var extensionConnected = false
    @Published private(set) var phase: Phase = .waitingForSession
    @Published private(set) var plan: FormatPlan?
    @Published private(set) var excludedTitleChangeIDs: Set<UUID> = []
    @Published private(set) var titleRefreshProgress: TitleRefreshProgress?
    @Published private(set) var resultSummary: String?
    @Published private(set) var installState: ExtensionInstaller.ExportState = .notExported
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// What Format Bookmarks does. Editing an option re-runs analysis on
    /// the retained payload if one is pending.
    @Published var formatOptions: FormatOptions {
        didSet {
            guard formatOptions != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(formatOptions), forKey: Self.formatOptionsKey)
            reanalyzeIfNeeded()
        }
    }

    private static let pairingTokenKey = "maruko.extensionPairingToken"
    private static let hasPairedKey = "maruko.extensionHasPaired"
    private static let formatOptionsKey = "maruko.formatOptions"

    private let installer = ExtensionInstaller()
    private let snapshotWriter = ExtensionSnapshotWriter()
    private let logger = Logger(subsystem: "com.mellowfleet.Maruko", category: "ExtensionFormat")
    private let webpageTitleRefresher: WebpageTitleRefresher

    private var server: ExtensionServer?
    private var sessionStore: ExtensionSessionStore?
    private var eventTask: Task<Void, Never>?
    private var activeAnalysis: Task<(FormatPlan, BookmarkOps), Error>?

    private var currentSessionId: String?
    private var lastPayload: ExtensionSessionPayload?
    private var pendingOps: BookmarkOps?

    /// Wired by ContentView: rules stay owned by RewriteRulesStore so rule
    /// editing is shared with the rest of the app.
    private var rulesProvider: () throws -> [RewriteRuleSnapshot] = { [] }

    init(webpageTitleRefresher: WebpageTitleRefresher = WebpageTitleRefresher()) {
        self.webpageTitleRefresher = webpageTitleRefresher
        extensionConnected = UserDefaults.standard.bool(forKey: Self.hasPairedKey)
        if let data = UserDefaults.standard.data(forKey: Self.formatOptionsKey),
           let options = try? JSONDecoder().decode(FormatOptions.self, from: data) {
            formatOptions = options
        } else {
            formatOptions = .default
        }
    }

    func configure(rules: @escaping () throws -> [RewriteRuleSnapshot]) {
        rulesProvider = rules
    }

    // MARK: - Server lifecycle

    func start() {
        guard serverState == .stopped || isFailed(serverState) else { return }
        serverState = .starting

        let sessionStore = ExtensionSessionStore()
        self.sessionStore = sessionStore
        let server = ExtensionServer(token: pairingToken) { request in
            sessionStore.handle(request: request)
        }
        self.server = server

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in sessionStore.events {
                self?.handle(event)
            }
        }

        Task {
            do {
                let port = try await server.start()
                serverState = .listening(port: port)
                pairingCode = "\(port)-\(pairingToken)"
            } catch {
                serverState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isFailed(_ state: ServerState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var pairingToken: String {
        if let token = UserDefaults.standard.string(forKey: Self.pairingTokenKey) {
            return token
        }
        let token = (0..<32).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
        UserDefaults.standard.set(token, forKey: Self.pairingTokenKey)
        return token
    }

    // MARK: - Events

    private func handle(_ event: ExtensionServerEvent) {
        switch event {
        case .paired:
            if !extensionConnected {
                extensionConnected = true
                UserDefaults.standard.set(true, forKey: Self.hasPairedKey)
            }
        case .sessionReceived(let sessionId, let payload, let rawBody):
            do {
                try snapshotWriter.save(rawBody, browser: payload.browser ?? "chrome")
            } catch {
                logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
            beginAnalysis(sessionId: sessionId, payload: payload)
        case .resultReceived(let sessionId, let result):
            guard sessionId == currentSessionId else { return }
            phase = result.ok ? .applied : .failed
            resultSummary = Self.summary(for: result)
        }
    }

    private static func summary(for result: ExtensionApplyResult) -> String {
        var text = "Removed \(result.counts.deleted) duplicates, rewrote \(result.counts.retitled) titles, moved \(result.counts.moved) bookmarks."
        if !result.errors.isEmpty {
            text += " \(result.errors.count) operations failed. See the extension popup for details."
        }
        return text
    }

    // MARK: - Analysis

    private func beginAnalysis(sessionId: String, payload: ExtensionSessionPayload) {
        activeAnalysis?.cancel()
        currentSessionId = sessionId
        lastPayload = payload
        pendingOps = nil
        plan = nil
        excludedTitleChangeIDs = []
        resultSummary = nil
        statusMessage = nil
        errorMessage = nil
        titleRefreshProgress = nil
        phase = .analyzing

        let rules: [RewriteRuleSnapshot]
        do {
            rules = try rulesProvider()
        } catch {
            failSession(sessionId, message: error.localizedDescription)
            return
        }
        let options = formatOptions

        let progressHandler: @Sendable (Int, Int) -> Void = { processed, total in
            Task { @MainActor [weak self] in
                self?.titleRefreshProgress = TitleRefreshProgress(processed: processed, total: total)
            }
        }
        let webpageTitleRefresher = self.webpageTitleRefresher

        let work = Task.detached(priority: .userInitiated) { () -> (FormatPlan, BookmarkOps) in
            let recentVisits = ExtensionHistoryMapper.recentVisits(
                history: payload.history,
                cutoff: options.recencyCutoff
            )

            let rooted = try ChromeBookmarkTreeAdapter.adapt(tree: payload.tree)
            let originalOrders = ChromeBookmarkTreeAdapter.childOrders(tree: payload.tree)
            let trees = rooted.map { (rootKey: $0.rootKey, node: $0.node) }

            var titleOverrides: [String: String] = [:]
            if options.refreshTitlesFromWebpages {
                let candidates = BookmarkTreeFormatter.webpageTitleCandidates(trees: trees)
                titleOverrides = try await webpageTitleRefresher.refresh(
                    candidates: candidates,
                    progress: progressHandler
                )
            }

            let plan = BookmarkTreeFormatter.formatTree(
                trees: trees,
                rules: rules,
                options: options,
                recentVisits: options.moveRecentToTop ? recentVisits : [:],
                titleOverrides: titleOverrides
            )
            let ops = ChromeOpListBuilder.makeOps(
                originalChildOrders: originalOrders,
                formattedTrees: rooted,
                plan: plan
            )
            return (plan, ops)
        }
        activeAnalysis = work

        Task {
            defer {
                titleRefreshProgress = nil
                activeAnalysis = nil
            }
            do {
                let (plan, ops) = try await work.value
                guard currentSessionId == sessionId else { return }
                self.plan = plan
                pendingOps = ops
                phase = .awaitingConfirmation
                sessionStore?.markAwaitingConfirmation(sessionId: sessionId)
                logger.info("Analyzed extension session: \(plan.totalBookmarks) bookmarks, \(plan.duplicates.count) duplicates, \(plan.titleChanges.count) title changes")
            } catch is CancellationError {
                guard currentSessionId == sessionId else { return }
                statusMessage = "Analysis cancelled."
                sessionStore?.cancel(sessionId: sessionId)
                phase = .waitingForSession
            } catch {
                guard currentSessionId == sessionId else { return }
                failSession(sessionId, message: error.localizedDescription)
            }
        }
    }

    private func failSession(_ sessionId: String, message: String) {
        errorMessage = message
        sessionStore?.fail(sessionId: sessionId)
        phase = .failed
        logger.error("Extension analysis failed: \(message, privacy: .public)")
    }

    func cancelAnalysis() {
        activeAnalysis?.cancel()
    }

    /// Format options changed while a plan was pending. Re-run the
    /// analysis on the retained payload; no re-send needed.
    func reanalyzeIfNeeded() {
        guard phase == .awaitingConfirmation,
              let sessionId = currentSessionId,
              let payload = lastPayload else { return }
        sessionStore?.markAnalyzing(sessionId: sessionId)
        beginAnalysis(sessionId: sessionId, payload: payload)
    }

    /// Curates the "Recent" folder on its own, independent of Format
    /// Bookmarks and its `moveRecentToTop` toggle. Reuses the retained
    /// payload from the current session rather than requiring a fresh Send
    /// Bookmarks. This only works while a session is still live and
    /// awaiting confirmation: the extension stops polling a session the
    /// moment it goes terminal, and there's no way to hand it a session id
    /// it didn't itself request, so `phase == .awaitingConfirmation` is a
    /// hard precondition, not just a convenience check.
    func sortRecentFolder() {
        guard phase == .awaitingConfirmation,
              let sessionId = currentSessionId,
              let payload = lastPayload else { return }

        activeAnalysis?.cancel()
        let previousPlan = plan
        let previousOps = pendingOps
        statusMessage = nil
        errorMessage = nil
        phase = .analyzing
        sessionStore?.markAnalyzing(sessionId: sessionId)

        let options = formatOptions
        let work = Task.detached(priority: .userInitiated) { () -> (FormatPlan, BookmarkOps) in
            let recentVisits = ExtensionHistoryMapper.recentVisits(
                history: payload.history,
                cutoff: options.recencyCutoff
            )
            let rooted = try ChromeBookmarkTreeAdapter.adapt(tree: payload.tree)
            let originalOrders = ChromeBookmarkTreeAdapter.childOrders(tree: payload.tree)
            let trees = rooted.map { (rootKey: $0.rootKey, node: $0.node) }

            guard let plan = BookmarkTreeFormatter.curateRecentFolderPlan(
                trees: trees,
                recentVisits: recentVisits
            ) else { throw SortRecentFolderError.noRecentFolder }

            let ops = ChromeOpListBuilder.makeOps(
                originalChildOrders: originalOrders,
                formattedTrees: rooted,
                plan: plan
            )
            return (plan, ops)
        }
        activeAnalysis = work

        Task {
            defer { activeAnalysis = nil }
            do {
                let (newPlan, newOps) = try await work.value
                guard currentSessionId == sessionId else { return }
                plan = newPlan
                pendingOps = newOps
                phase = .awaitingConfirmation
                sessionStore?.markAwaitingConfirmation(sessionId: sessionId)
            } catch SortRecentFolderError.noRecentFolder {
                guard currentSessionId == sessionId else { return }
                statusMessage = "No folder named “Recent” was found. Nothing to sort."
                plan = previousPlan
                pendingOps = previousOps
                phase = .awaitingConfirmation
                sessionStore?.markAwaitingConfirmation(sessionId: sessionId)
            } catch is CancellationError {
                guard currentSessionId == sessionId else { return }
                plan = previousPlan
                pendingOps = previousOps
                phase = .awaitingConfirmation
                sessionStore?.markAwaitingConfirmation(sessionId: sessionId)
            } catch {
                guard currentSessionId == sessionId else { return }
                failSession(sessionId, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Confirmation

    var titleChangeApplyCount: Int {
        plan?.titleChanges.count {
            $0.nodeID != nil && !excludedTitleChangeIDs.contains($0.id)
        } ?? 0
    }

    func setTitleChangeExcluded(_ change: TitleChange, excluded: Bool) {
        guard change.nodeID != nil else { return }
        if excluded {
            excludedTitleChangeIDs.insert(change.id)
        } else {
            excludedTitleChangeIDs.remove(change.id)
        }
    }

    func setTitleChangesExcluded(_ changes: [TitleChange], excluded: Bool) {
        let ids = Set(changes.lazy.filter { $0.nodeID != nil }.map(\.id))
        if excluded {
            excludedTitleChangeIDs.formUnion(ids)
        } else {
            excludedTitleChangeIDs.subtract(ids)
        }
    }

    func confirm() {
        guard phase == .awaitingConfirmation,
              let sessionId = currentSessionId,
              let plan,
              let pendingOps else { return }
        let excludedNodeIDs = Set(plan.titleChanges.compactMap { change in
            excludedTitleChangeIDs.contains(change.id) ? change.nodeID : nil
        })
        let ops = pendingOps.excludingRetitles(withNodeIDs: excludedNodeIDs)
        sessionStore?.confirm(sessionId: sessionId, ops: ops)
        phase = .waitingForExtension
    }

    // MARK: - Installer

    func refreshInstallState() {
        installState = installer.stateOfExport()

        // Ship a newer bundled extension? Refresh the export in place.
        // Chrome re-reads unpacked files on reload.
        if case .outdated = installState {
            do {
                let url = try installer.exportBundledExtension()
                installState = .upToDate(url)
                statusMessage = "Extension updated. Click Reload (⟳) on the chrome://extensions page."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Exports the bundled extension and reveals it in Finder for
    /// drag-and-drop onto chrome://extensions.
    func installExtension() {
        do {
            let url = try installer.exportBundledExtension()
            installState = .upToDate(url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Escape hatch: export to a user-chosen folder instead of the app
    /// container.
    func exportToChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the \(ExtensionInstaller.exportFolderName) folder."
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            let target = directory.appendingPathComponent(
                ExtensionInstaller.exportFolderName,
                isDirectory: true
            )
            let url = try installer.exportBundledExtension(to: target)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
