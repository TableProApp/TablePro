import Foundation
import Network
import os

internal enum GoogleOAuthLoopbackOutcome: Sendable, Equatable {
    case code(String)
    case denied(String)
}

internal final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    private static let maximumRequestHeadBytes = 8_192
    private static let maximumConnections = 16
    private static let headTerminators = [Data("\r\n\r\n".utf8), Data("\n\n".utf8)]
    private static let logger = Logger(subsystem: "com.TablePro", category: "GoogleOAuthLoopbackServer")

    private let expectedState: String
    private let queue = DispatchQueue(label: "com.TablePro.GoogleOAuth.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var outcomeContinuation: CheckedContinuation<GoogleOAuthLoopbackOutcome, Error>?
    private var result: Result<GoogleOAuthLoopbackOutcome, GoogleAuthError>?
    private var timeoutItem: DispatchWorkItem?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() async throws -> UInt16 {
        let listener = try makeListener()
        return try await withCheckedThrowingContinuation { continuation in
            let failure = lock.withLock { () -> GoogleAuthError? in
                if let result {
                    return result.failureOrCancelled
                }
                self.listener = listener
                readyContinuation = continuation
                listener.start(queue: queue)
                return nil
            }
            guard let failure else { return }
            listener.cancel()
            continuation.resume(throwing: failure)
        }
    }

    func awaitOutcome(timeout: Duration) async throws -> GoogleOAuthLoopbackOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let settled = lock.withLock { () -> Result<GoogleOAuthLoopbackOutcome, GoogleAuthError>? in
                if let result {
                    return result
                }
                outcomeContinuation = continuation
                let item = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(.oauthTimedOut))
                }
                timeoutItem = item
                queue.asyncAfter(deadline: .now() + Self.seconds(timeout), execute: item)
                return nil
            }
            if let settled {
                continuation.resume(with: settled)
            }
        }
    }

    func cancel() {
        finish(.failure(.oauthCancelled))
    }

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            Self.logger.error("Could not create the OAuth loopback listener")
            throw GoogleAuthError.transport("listenerUnavailable")
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            self?.listenerStateChanged(state, port: listener?.port?.rawValue)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        return listener
    }

    private func listenerStateChanged(_ state: NWListener.State, port: UInt16?) {
        switch state {
        case .ready:
            let continuation = lock.withLock { () -> CheckedContinuation<UInt16, Error>? in
                defer { readyContinuation = nil }
                return readyContinuation
            }
            guard let port, port > 0 else {
                continuation?.resume(throwing: GoogleAuthError.transport("listenerUnavailable"))
                finish(.failure(.transport("listenerUnavailable")))
                return
            }
            continuation?.resume(returning: port)
        case .failed:
            Self.logger.error("The OAuth loopback listener failed")
            finish(.failure(.transport("listenerFailed")))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let admitted = lock.withLock { () -> Bool in
            guard result == nil, connections.count < Self.maximumConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                self?.release(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, head: Data())
    }

    private func receive(on connection: NWConnection, head: Data) {
        let remaining = Self.maximumRequestHeadBytes - head.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var received = head
            if let content {
                received.append(content)
            }
            if error != nil, received.isEmpty {
                connection.cancel()
                return
            }
            let hasFullHead = Self.headTerminators.contains { received.range(of: $0) != nil }
            if error == nil, !isComplete, !hasFullHead, received.count < Self.maximumRequestHeadBytes {
                self.receive(on: connection, head: received)
                return
            }
            self.respond(on: connection, head: received)
        }
    }

    private func respond(on connection: NWConnection, head: Data) {
        let callback = GoogleOAuthCallback.parse(
            requestHead: head,
            expectedState: expectedState
        )
        switch callback {
        case .ignore:
            send(GoogleOAuthLoopbackPage.badRequest, on: connection)
        case .code(let code):
            release(connection)
            send(GoogleOAuthLoopbackPage.success, on: connection)
            finish(.success(.code(code)))
        case .denied(let reason):
            release(connection)
            send(GoogleOAuthLoopbackPage.failure, on: connection)
            finish(.success(.denied(reason)))
        }
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func release(_ connection: NWConnection) {
        lock.withLock {
            connections[ObjectIdentifier(connection)] = nil
        }
    }

    private func finish(_ outcome: Result<GoogleOAuthLoopbackOutcome, GoogleAuthError>) {
        let teardown = lock.withLock { () -> Teardown? in
            guard result == nil else { return nil }
            result = outcome
            let teardown = Teardown(
                listener: listener,
                connections: Array(connections.values),
                readyContinuation: readyContinuation,
                outcomeContinuation: outcomeContinuation,
                timeoutItem: timeoutItem
            )
            listener = nil
            connections = [:]
            readyContinuation = nil
            outcomeContinuation = nil
            timeoutItem = nil
            return teardown
        }
        guard let teardown else { return }
        teardown.timeoutItem?.cancel()
        teardown.listener?.cancel()
        teardown.connections.forEach { $0.cancel() }
        teardown.readyContinuation?.resume(throwing: outcome.failureOrCancelled)
        teardown.outcomeContinuation?.resume(with: outcome)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private struct Teardown {
        let listener: NWListener?
        let connections: [NWConnection]
        let readyContinuation: CheckedContinuation<UInt16, Error>?
        let outcomeContinuation: CheckedContinuation<GoogleOAuthLoopbackOutcome, Error>?
        let timeoutItem: DispatchWorkItem?
    }
}

private extension Result where Success == GoogleOAuthLoopbackOutcome, Failure == GoogleAuthError {
    var failureOrCancelled: GoogleAuthError {
        guard case .failure(let error) = self else { return .oauthCancelled }
        return error
    }
}

internal enum GoogleOAuthLoopbackPage {
    static let success = response(
        status: "200 OK",
        title: "Signed in to Google",
        message: "You can close this tab and return to TablePro."
    )
    static let failure = response(
        status: "200 OK",
        title: "Google sign-in did not finish",
        message: "Close this tab and try again in TablePro."
    )
    static let badRequest = response(status: "400 Bad Request", title: "Bad Request", message: "")

    private static func response(status: String, title: String, message: String) -> Data {
        let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>TablePro</title></head>"
            + "<body style=\"font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:60px\">"
            + "<h2>\(title)</h2><p>\(message)</p></body></html>"
        let bodyData = Data(body.utf8)
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "Connection: close"
        ]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + bodyData
    }
}
