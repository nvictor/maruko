import Foundation

// MARK: - Wire types

/// Body of `POST /session` — the extension's snapshot of the live profile.
nonisolated struct ExtensionSessionPayload: Codable, Sendable {
    struct HistoryVisit: Codable, Sendable {
        let url: String
        /// Milliseconds since the Unix epoch (chrome.history lastVisitTime).
        let lastVisitTime: Double
    }

    let browser: String?
    let extensionVersion: String?
    let tree: [ChromeBookmarkNode]
    let history: [HistoryVisit]
}

/// Body of `POST /session/{id}/result`.
nonisolated struct ExtensionApplyResult: Codable, Sendable {
    struct Counts: Codable, Sendable {
        let deleted: Int
        let retitled: Int
        let moved: Int
    }

    struct OpError: Codable, Sendable {
        let op: String
        let id: String?
        let message: String
    }

    let ok: Bool
    let counts: Counts
    let errors: [OpError]
}

nonisolated enum ExtensionSessionPhase: String, Codable, Sendable {
    case analyzing
    case awaitingConfirmation
    case opsReady
    case applying
    case applied
    case failed
    case cancelled
}

nonisolated enum ExtensionServerEvent: Sendable {
    /// Any authenticated request arrived — the extension is paired.
    case paired
    case sessionReceived(sessionId: String, payload: ExtensionSessionPayload, rawBody: Data)
    case resultReceived(sessionId: String, result: ExtensionApplyResult)
}

// MARK: - Session store

/// Owns the extension-format session state machine and routes the HTTP
/// requests the server has already authenticated. Lock-guarded because the
/// server calls in from its own queue while the UI store mutates phases
/// from the main actor.
///
/// Phases: analyzing → awaitingConfirmation → opsReady → applying →
/// applied | failed; cancelled from any non-terminal phase. A new
/// `POST /session` cancels the previous session.
nonisolated final class ExtensionSessionStore: @unchecked Sendable {
    private struct Session {
        let id: String
        var phase: ExtensionSessionPhase
        var ops: BookmarkOps?
    }

    private let lock = NSLock()
    private var session: Session?
    private var eventContinuation: AsyncStream<ExtensionServerEvent>.Continuation?

    /// Single-consumer stream of server events for the UI store.
    var events: AsyncStream<ExtensionServerEvent> {
        AsyncStream { continuation in
            lock.lock()
            eventContinuation = continuation
            lock.unlock()
        }
    }

    private func emit(_ event: ExtensionServerEvent) {
        lock.lock()
        let continuation = eventContinuation
        lock.unlock()
        continuation?.yield(event)
    }

    // MARK: UI-side transitions

    func currentPhase(sessionId: String) -> ExtensionSessionPhase? {
        lock.lock()
        defer { lock.unlock() }
        guard session?.id == sessionId else { return nil }
        return session?.phase
    }

    /// Analysis produced a plan; waiting for the user to confirm in Maruko.
    func markAwaitingConfirmation(sessionId: String) {
        transition(sessionId: sessionId, from: [.analyzing], to: .awaitingConfirmation)
    }

    /// Format options changed before confirmation — the retained payload is
    /// being re-analyzed without a re-send from the extension.
    func markAnalyzing(sessionId: String) {
        transition(sessionId: sessionId, from: [.awaitingConfirmation], to: .analyzing)
    }

    /// User confirmed: park the ops for the extension's next poll.
    func confirm(sessionId: String, ops: BookmarkOps) {
        lock.lock()
        defer { lock.unlock() }
        guard session?.id == sessionId, session?.phase == .awaitingConfirmation else { return }
        session?.ops = ops
        session?.phase = .opsReady
    }

    func fail(sessionId: String) {
        transition(
            sessionId: sessionId,
            from: [.analyzing, .awaitingConfirmation, .opsReady, .applying],
            to: .failed
        )
    }

    func cancel(sessionId: String) {
        transition(
            sessionId: sessionId,
            from: [.analyzing, .awaitingConfirmation, .opsReady, .applying],
            to: .cancelled
        )
    }

    private func transition(
        sessionId: String,
        from allowed: Set<ExtensionSessionPhase>,
        to phase: ExtensionSessionPhase
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard session?.id == sessionId, let current = session?.phase, allowed.contains(current) else { return }
        session?.phase = phase
    }

    // MARK: HTTP routing (requests are already token-checked by the server)

    func handle(request: HTTPRequest) -> HTTPResponse {
        emit(.paired)

        let segments = request.path.split(separator: "?")[0].split(separator: "/").map(String.init)
        if request.method == "GET", segments == ["ping"] {
            return .json(200, PingResponse())
        }
        if request.method == "POST", segments == ["session"] {
            return receiveSession(request)
        }
        if request.method == "GET", segments.count == 2, segments[0] == "session" {
            return sessionStatus(id: segments[1])
        }
        if request.method == "POST", segments.count == 3, segments[0] == "session", segments[2] == "result" {
            return receiveResult(id: segments[1], request: request)
        }
        return .error(404, "Unknown endpoint.")
    }

    private struct PingResponse: Encodable {
        let app = "maruko"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private struct SessionCreatedResponse: Encodable {
        let sessionId: String
        let status: ExtensionSessionPhase
    }

    private struct SessionStatusResponse: Encodable {
        let status: ExtensionSessionPhase
        let ops: BookmarkOps?
    }

    private func receiveSession(_ request: HTTPRequest) -> HTTPResponse {
        let payload: ExtensionSessionPayload
        do {
            payload = try JSONDecoder().decode(ExtensionSessionPayload.self, from: request.body)
        } catch {
            return .error(400, "Could not decode session payload: \(error.localizedDescription)")
        }

        let id = UUID().uuidString
        lock.lock()
        session = Session(id: id, phase: .analyzing, ops: nil)
        lock.unlock()

        emit(.sessionReceived(sessionId: id, payload: payload, rawBody: request.body))
        return .json(200, SessionCreatedResponse(sessionId: id, status: .analyzing))
    }

    private func sessionStatus(id: String) -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        guard var current = session, current.id == id else {
            return .error(404, "Unknown or superseded session.")
        }

        // First poll that sees the ops flips the session to applying; the
        // ops stay in the response so a reopened popup can resume.
        if current.phase == .opsReady {
            current.phase = .applying
            session = current
        }

        let includeOps = current.phase == .applying
        return .json(200, SessionStatusResponse(
            status: current.phase,
            ops: includeOps ? current.ops : nil
        ))
    }

    private func receiveResult(id: String, request: HTTPRequest) -> HTTPResponse {
        let result: ExtensionApplyResult
        do {
            result = try JSONDecoder().decode(ExtensionApplyResult.self, from: request.body)
        } catch {
            return .error(400, "Could not decode apply result: \(error.localizedDescription)")
        }

        lock.lock()
        guard var current = session, current.id == id else {
            lock.unlock()
            return .error(404, "Unknown or superseded session.")
        }
        guard current.phase == .applying || current.phase == .opsReady else {
            let phase = current.phase
            lock.unlock()
            return .error(409, "Session is \(phase.rawValue); a result is not expected.")
        }
        current.phase = result.ok ? .applied : .failed
        session = current
        lock.unlock()

        emit(.resultReceived(sessionId: id, result: result))
        return .json(200, SessionStatusResponse(status: result.ok ? .applied : .failed, ops: nil))
    }
}

// MARK: - History mapping

/// Converts the extension's history payload into the `[normalized URL →
/// most recent visit]` map `BookmarkTreeFormatter` expects — the same shape
/// `BrowserHistoryReader.recentVisits` produces from the History database.
nonisolated enum ExtensionHistoryMapper {
    static func recentVisits(
        history: [ExtensionSessionPayload.HistoryVisit],
        cutoff: Date
    ) -> [String: Date] {
        var visits: [String: Date] = [:]
        for visit in history {
            guard let normalized = URLNormalizer.normalize(visit.url) else { continue }
            let date = Date(timeIntervalSince1970: visit.lastVisitTime / 1000)
            guard date >= cutoff else { continue }
            if let existing = visits[normalized], existing >= date { continue }
            visits[normalized] = date
        }
        return visits
    }
}
