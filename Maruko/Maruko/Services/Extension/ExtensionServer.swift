import Foundation
import Network
import OSLog

nonisolated enum ExtensionServerError: LocalizedError {
    case noPortAvailable

    var errorDescription: String? {
        switch self {
        case .noPortAvailable:
            return "Ports \(ExtensionServer.candidatePorts.map(String.init).joined(separator: ", ")) are all in use."
        }
    }
}

/// Loopback-only HTTP listener the Chrome extension talks to. Binds strictly
/// to 127.0.0.1, requires the pairing token on every request, and pins the
/// Host header (DNS-rebinding guard). No CORS headers on purpose: the MV3
/// extension bypasses CORS via host_permissions while ordinary web pages
/// stay blocked from reading responses.
nonisolated final class ExtensionServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    static let candidatePorts: [UInt16] = [38765, 38766, 38767, 38768, 38769]

    private let queue = DispatchQueue(label: "com.mellowfleet.Maruko.ExtensionServer")
    private let logger = Logger(subsystem: "com.mellowfleet.Maruko", category: "ExtensionServer")
    private let token: String
    private let handler: Handler
    private var listener: NWListener?
    private(set) var boundPort: UInt16?

    init(token: String, handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    /// Binds the first free candidate port and returns it.
    func start() async throws -> UInt16 {
        for port in Self.candidatePorts {
            if let bound = try? await startListener(on: port) {
                boundPort = bound
                logger.info("Extension server listening on 127.0.0.1:\(bound)")
                return bound
            }
        }
        throw ExtensionServerError.noPortAvailable
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func startListener(on port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // stateUpdateHandler can fire multiple times; resume only once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let shouldResume = resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return false }
                    switch state {
                    case .ready, .failed, .cancelled:
                        alreadyResumed = true
                        return true
                    default:
                        return false
                    }
                }
                guard shouldResume else { return }

                switch state {
                case .ready:
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection, parser: HTTPRequestParser())
    }

    private func receiveLoop(_ connection: NWConnection, parser: HTTPRequestParser) {
        var parser = parser
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            do {
                if let data, !data.isEmpty, let request = try parser.append(data) {
                    self.respond(to: request, on: connection)
                    return
                }
            } catch let parseError as HTTPParseError {
                self.send(.error(parseError.statusCode, parseError.localizedDescription), on: connection)
                return
            } catch {
                self.send(.error(400, "Bad request."), on: connection)
                return
            }

            if isComplete {
                connection.cancel()
            } else {
                self.receiveLoop(connection, parser: parser)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        guard isHostAllowed(request.header("host")) else {
            send(.error(403, "Forbidden."), on: connection)
            return
        }
        guard request.header("x-maruko-token") == token else {
            send(.error(401, "Missing or invalid pairing token."), on: connection)
            return
        }

        let handler = self.handler
        Task {
            let response = await handler(request)
            self.send(response, on: connection)
        }
    }

    private func isHostAllowed(_ host: String?) -> Bool {
        guard let host else { return false }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}
