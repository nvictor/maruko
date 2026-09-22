import AppKit
import Combine
import Foundation
import OSLog

private enum AnalysisError: Error {
    case missingRequiredFolders(Set<RequiredFolder>)
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
        case missingRequiredFolders
        case awaitingConfirmation
        case waitingForExtension
        case applied
        case failed
    }

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var pairingCode: String?
    @Published private(set) var extensionConnected = false
    @Published private(set) var phase: Phase = .waitingForSession
    @Published private(set) var plan: FormatPlan?
    @Published private(set) var missingFolders: Set<RequiredFolder> = []
    @Published private(set) var resultSummary: String?
    @Published private(set) var installState: ExtensionInstaller.ExportState = .notExported
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// What Maruko does. Editing an option re-runs analysis on the retained
    /// payload if one is pending.
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

    private var server: ExtensionServer?
    private var sessionStore: ExtensionSessionStore?
    private var eventTask: Task<Void, Never>?
    private var activeAnalysis: Task<(FormatPlan, BookmarkOps), Error>?

    private var currentSessionId: String?
    private var lastPayload: ExtensionSessionPayload?
    private var pendingOps: BookmarkOps?

    init() {
        extensionConnected = UserDefaults.standard.bool(forKey: Self.hasPairedKey)
        if let data = UserDefaults.standard.data(forKey: Self.formatOptionsKey),
           let options = try? JSONDecoder().decode(FormatOptions.self, from: data) {
            formatOptions = options
        } else {
            formatOptions = .default
        }
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
        var text = "Removed \(result.counts.deleted) duplicates, moved \(result.counts.moved) bookmarks."
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
        missingFolders = []
        resultSummary = nil
        statusMessage = nil
        errorMessage = nil
        phase = .analyzing

        let options = formatOptions

        let work = Task.detached(priority: .userInitiated) { () -> (FormatPlan, BookmarkOps) in
            let recentVisits = ExtensionHistoryMapper.recentVisits(
                history: payload.history,
                cutoff: options.recencyCutoff
            )

            let rooted = try ChromeBookmarkTreeAdapter.adapt(tree: payload.tree)
            let originalOrders = ChromeBookmarkTreeAdapter.childOrders(tree: payload.tree)
            let trees = rooted.map { (rootKey: $0.rootKey, node: $0.node) }

            let missing = BookmarkTreeFormatter.missingRequiredFolders(in: trees)
            guard missing.isEmpty else { throw AnalysisError.missingRequiredFolders(missing) }

            let plan = BookmarkTreeFormatter.curateTree(
                trees: trees,
                recentVisits: recentVisits,
                options: options
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
            defer { activeAnalysis = nil }
            do {
                let (plan, ops) = try await work.value
                guard currentSessionId == sessionId else { return }
                self.plan = plan
                pendingOps = ops
                phase = .awaitingConfirmation
                sessionStore?.markAwaitingConfirmation(sessionId: sessionId)
                logger.info("Analyzed extension session: \(plan.totalBookmarks) bookmarks, \(plan.duplicates.count) duplicates")
            } catch is CancellationError {
                guard currentSessionId == sessionId else { return }
                statusMessage = "Analysis cancelled."
                sessionStore?.cancel(sessionId: sessionId)
                phase = .waitingForSession
            } catch AnalysisError.missingRequiredFolders(let missing) {
                guard currentSessionId == sessionId else { return }
                missingFolders = missing
                phase = .missingRequiredFolders
                sessionStore?.fail(sessionId: sessionId)
                logger.error("Extension analysis stopped: missing folders \(missing.map(\.rawValue).joined(separator: ", "), privacy: .public)")
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

    // MARK: - Confirmation

    func confirm() {
        guard phase == .awaitingConfirmation,
              let sessionId = currentSessionId,
              let pendingOps else { return }
        sessionStore?.confirm(sessionId: sessionId, ops: pendingOps)
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
