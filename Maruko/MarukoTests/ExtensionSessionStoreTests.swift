import Foundation
import Testing
@testable import Maruko

struct ExtensionSessionStoreTests {
    private func post(_ path: String, body: Data) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: [:], body: body)
    }

    private func get(_ path: String) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, headers: [:], body: Data())
    }

    private struct SessionCreated: Decodable {
        let sessionId: String
        let status: ExtensionSessionPhase
    }

    private struct SessionStatus: Decodable {
        let status: ExtensionSessionPhase
        let ops: BookmarkOps?
    }

    private func createSession(in store: ExtensionSessionStore) throws -> String {
        let response = store.handle(request: post("/session", body: try Fixture.data("extension-session-payload")))
        #expect(response.status == 200)
        return try JSONDecoder().decode(SessionCreated.self, from: response.body).sessionId
    }

    @Test func pingAnswersWithAppIdentity() {
        let store = ExtensionSessionStore()
        let response = store.handle(request: get("/ping"))

        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8)?.contains("\"app\":\"maruko\"") == true)
    }

    @Test func legalPhaseWalkReachesApplied() throws {
        let store = ExtensionSessionStore()
        let id = try createSession(in: store)
        #expect(store.currentPhase(sessionId: id) == .analyzing)

        store.markAwaitingConfirmation(sessionId: id)
        #expect(store.currentPhase(sessionId: id) == .awaitingConfirmation)

        let ops = BookmarkOps(deletes: ["13"], retitles: [], reorders: [])
        store.confirm(sessionId: id, ops: ops)
        #expect(store.currentPhase(sessionId: id) == .opsReady)

        // First status poll flips to applying and carries the ops; a second
        // poll still carries them so a reopened popup can resume.
        for _ in 0..<2 {
            let polled = store.handle(request: get("/session/\(id)"))
            let status = try JSONDecoder().decode(SessionStatus.self, from: polled.body)
            #expect(status.status == .applying)
            #expect(status.ops == ops)
        }

        let result = """
        {"ok": true, "counts": {"deleted": 1, "retitled": 0, "moved": 0}, "errors": []}
        """
        let response = store.handle(request: post("/session/\(id)/result", body: Data(result.utf8)))
        #expect(response.status == 200)
        #expect(store.currentPhase(sessionId: id) == .applied)
    }

    @Test func resultBeforeOpsReadyIsRejected() throws {
        let store = ExtensionSessionStore()
        let id = try createSession(in: store)

        let result = """
        {"ok": true, "counts": {"deleted": 0, "retitled": 0, "moved": 0}, "errors": []}
        """
        let response = store.handle(request: post("/session/\(id)/result", body: Data(result.utf8)))
        #expect(response.status == 409)
        #expect(store.currentPhase(sessionId: id) == .analyzing)
    }

    @Test func newSessionSupersedesTheOldOne() throws {
        let store = ExtensionSessionStore()
        let first = try createSession(in: store)
        let second = try createSession(in: store)

        #expect(store.currentPhase(sessionId: first) == nil)
        #expect(store.handle(request: get("/session/\(first)")).status == 404)
        #expect(store.handle(request: get("/session/\(second)")).status == 200)
    }

    @Test func unknownEndpointIs404AndBadPayloadIs400() {
        let store = ExtensionSessionStore()

        #expect(store.handle(request: get("/nope")).status == 404)
        #expect(store.handle(request: post("/session", body: Data("not json".utf8))).status == 400)
    }

    @Test func eventsFireForPairingSessionAndResult() async throws {
        let store = ExtensionSessionStore()
        var iterator = store.events.makeAsyncIterator()

        _ = store.handle(request: get("/ping"))
        guard case .paired = await iterator.next() else {
            Issue.record("Expected .paired first")
            return
        }

        let id = try createSession(in: store)
        guard case .sessionReceived(let sessionId, let payload, _) = await skippingPaired(&iterator) else {
            Issue.record("Expected .sessionReceived")
            return
        }
        #expect(sessionId == id)
        #expect(payload.browser == "chrome")
        #expect(payload.tree.count == 1)
        #expect(payload.history.count == 2)

        store.markAwaitingConfirmation(sessionId: id)
        store.confirm(sessionId: id, ops: BookmarkOps())
        _ = store.handle(request: get("/session/\(id)"))
        let result = """
        {"ok": false, "counts": {"deleted": 0, "retitled": 0, "moved": 0}, "errors": [{"op": "delete", "id": "9", "message": "gone"}]}
        """
        _ = store.handle(request: post("/session/\(id)/result", body: Data(result.utf8)))

        guard case .resultReceived(_, let applyResult) = await skippingPaired(&iterator) else {
            Issue.record("Expected .resultReceived")
            return
        }
        #expect(applyResult.ok == false)
        #expect(applyResult.errors.first?.op == "delete")
        #expect(store.currentPhase(sessionId: id) == .failed)
    }

    /// Every handled request emits `.paired`; skip those to reach the next
    /// interesting event.
    private func skippingPaired(
        _ iterator: inout AsyncStream<ExtensionServerEvent>.AsyncIterator
    ) async -> ExtensionServerEvent? {
        while let event = await iterator.next() {
            if case .paired = event { continue }
            return event
        }
        return nil
    }
}
