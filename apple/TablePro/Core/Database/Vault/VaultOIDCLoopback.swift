//
//  VaultOIDCLoopback.swift
//  TablePro
//

import Foundation
import Network
import os

protocol VaultOIDCCallbackReceiving: Sendable {
    func start() async throws
    func callback(timeout: Duration) async throws -> [String: String]
    func stop()
}

// Listens where the vault CLI does, http://localhost:8250/oidc/callback, the redirect URI an OIDC role already allows.
final class VaultOIDCLoopback: VaultOIDCCallbackReceiving, @unchecked Sendable {
    static let port: UInt16 = 8_250
    static let callbackPath = "/oidc/callback"

    private static let logger = Logger(subsystem: "com.TablePro", category: "VaultOIDCLoopback")
    private static let maximumRequestHeadBytes = 8_192

    private let queue = DispatchQueue(label: "com.TablePro.VaultOIDC.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?
    private var timeoutItem: DispatchWorkItem?

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw VaultError.oidcCallbackPortInUse
        }
        listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                self.listener = listener
                readyContinuation = continuation
            }
            listener.start(queue: queue)
        }
    }

    func callback(timeout: Duration) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let settled = lock.withLock { () -> Result<[String: String], Error>? in
                    if let outcome { return outcome }
                    callbackContinuation = continuation
                    let item = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(VaultError.oidcFailed(String(localized: "The browser sign-in timed out."))))
                    }
                    timeoutItem = item
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    queue.asyncAfter(deadline: .now() + seconds, execute: item)
                    return nil
                }
                if let settled { continuation.resume(with: settled) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        finish(.failure(CancellationError()))
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { readyContinuation = nil }
                return readyContinuation
            }
            continuation?.resume()
        case .failed(let error), .waiting(let error):
            Self.logger.error("Vault OIDC callback listener failed: \(error.publicLogShape, privacy: .public)")
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { readyContinuation = nil }
                return readyContinuation
            }
            if let continuation {
                continuation.resume(throwing: VaultError.oidcCallbackPortInUse)
            }
            finish(.failure(VaultError.oidcCallbackPortInUse))
        case .cancelled:
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { readyContinuation = nil }
                return readyContinuation
            }
            continuation?.resume(throwing: CancellationError())
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let admitted = lock.withLock { () -> Bool in
            guard outcome == nil, connections.count < 16 else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard admitted else {
            connection.cancel()
            return
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
            if let content { received.append(content) }
            if let parameters = Self.callbackParameters(in: received) {
                self.respond(on: connection, status: "200 OK", body: Self.successPage())
                self.finish(.success(parameters))
                return
            }
            if Self.headIsComplete(received) || received.count >= Self.maximumRequestHeadBytes || isComplete || error != nil {
                self.respond(on: connection, status: "404 Not Found", body: "")
                return
            }
            self.receive(on: connection, head: received)
        }
    }

    static func callbackParameters(in head: Data) -> [String: String]? {
        guard headIsComplete(head), let text = String(data: head, encoding: .utf8),
              let requestLine = text.components(separatedBy: .newlines).first
        else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost" + parts[1]),
              components.path == callbackPath
        else { return nil }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { parameters[item.name] = value }
        }
        return parameters
    }

    private static func headIsComplete(_ head: Data) -> Bool {
        head.range(of: Data("\r\n\r\n".utf8)) != nil || head.range(of: Data("\n\n".utf8)) != nil
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.release(connection)
        })
    }

    private func release(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = nil }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let (continuation, listener, settled, abandoned) = lock.withLock {
            () -> (CheckedContinuation<[String: String], Error>?, NWListener?, Result<[String: String], Error>, [NWConnection]) in
            let firstOutcome = outcome == nil
            if firstOutcome { outcome = result }
            timeoutItem?.cancel()
            timeoutItem = nil
            let continuation = callbackContinuation
            callbackContinuation = nil
            let listener = self.listener
            self.listener = nil
            // A connection still sending the success page closes itself once it is sent.
            var abandoned: [NWConnection] = []
            if firstOutcome, case .failure = result {
                abandoned = Array(connections.values)
            }
            return (continuation, listener, outcome ?? result, abandoned)
        }
        listener?.cancel()
        abandoned.forEach { $0.cancel() }
        continuation?.resume(with: settled)
    }

    private static func successPage() -> String {
        let message = String(localized: "Signed in to Vault. You can close this window and return to TablePro.")
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>TablePro</title></head>
            <body style="font-family: -apple-system, sans-serif; text-align: center; margin-top: 4em">
            <p>\(message)</p></body></html>
            """
    }
}
