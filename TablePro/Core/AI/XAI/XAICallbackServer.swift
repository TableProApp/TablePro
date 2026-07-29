//
//  XAICallbackServer.swift
//  TablePro
//

import Foundation
import Network
import os

final class XAICallbackServer: @unchecked Sendable {
    enum ServerError: Error, LocalizedError {
        case unavailable
        case timedOut
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "Could not start the sign-in listener. Please try again.")
            case .timedOut:
                return String(localized: "Sign-in timed out. Please try again.")
            case .stateMismatch:
                return String(localized: "Sign-in could not be verified. Please try again.")
            }
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "XAICallbackServer")
    private static let timeout: TimeInterval = 300
    private static let startTimeout: TimeInterval = 10

    private let expectedState: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var boundPort: UInt16 = XAI.preferredRedirectPort

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    var redirectURI: String {
        XAI.redirectURI(port: lock.withLock { boundPort })
    }

    func start() async throws {
        do {
            try await startListener(on: XAI.preferredRedirectPort)
        } catch {
            Self.logger.notice("xAI callback preferred port unavailable; falling back to an ephemeral port")
            try await startListener(on: 0)
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.withLock { codeContinuation = continuation }
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                self?.finishCode(.failure(ServerError.timedOut))
            }
            lock.withLock { timeoutTask = task }
        }
    }

    func stop() {
        let (task, readyTask, conn, lst): (
            Task<Void, Never>?, Task<Void, Never>?, NWConnection?, NWListener?
        ) = lock.withLock {
            let values = (timeoutTask, readyTimeoutTask, connection, listener)
            timeoutTask = nil
            readyTimeoutTask = nil
            connection = nil
            listener = nil
            return values
        }
        task?.cancel()
        readyTask?.cancel()
        conn?.cancel()
        lst?.cancel()
    }

    private func startListener(on port: UInt16) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                self?.finishReady(.failure(ServerError.timedOut))
            }
            lock.withLock {
                readyContinuation = continuation
                readyTimeoutTask = timeout
            }
            do {
                try makeListener(on: port)
            } catch {
                finishReady(.failure(ServerError.unavailable))
            }
        }
    }

    private func makeListener(on port: UInt16) throws {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)

        let listener = try NWListener(using: parameters)
        let previous: NWListener? = lock.withLock {
            let old = self.listener
            self.listener = listener
            return old
        }
        previous?.cancel()

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let resolvedPort = listener.port?.rawValue {
                    self?.lock.withLock { self?.boundPort = resolvedPort }
                }
                self?.finishReady(.success(()))
            case .failed(let error):
                Self.logger.error("xAI callback listener failed: \(error.localizedDescription, privacy: .public)")
                self?.finishReady(.failure(ServerError.unavailable))
                self?.finishCode(.failure(ServerError.unavailable))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    private func handleConnection(_ newConnection: NWConnection) {
        lock.withLock { connection = newConnection }
        newConnection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.readRequest(from: newConnection)
            }
        }
        newConnection.start(queue: .global(qos: .userInitiated))
    }

    private func readRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            guard let data = content, let request = String(data: data, encoding: .utf8),
                  let query = Self.parseCallback(request) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.readRequest(from: connection)
                }
                return
            }
            let matches = query.state == self.expectedState
            Self.send(html: matches ? Self.successPage : Self.failurePage, to: connection)
            self.finishCode(matches ? .success(query.code) : .failure(ServerError.stateMismatch))
        }
    }

    private func finishReady(_ result: Result<Void, Error>) {
        let (continuation, timeout): (CheckedContinuation<Void, Error>?, Task<Void, Never>?) = lock.withLock {
            let pendingContinuation = readyContinuation
            let pendingTimeout = readyTimeoutTask
            readyContinuation = nil
            readyTimeoutTask = nil
            return (pendingContinuation, pendingTimeout)
        }
        timeout?.cancel()
        continuation?.resume(with: result)
    }

    private func finishCode(_ result: Result<String, Error>) {
        let continuation: CheckedContinuation<String, Error>? = lock.withLock {
            let pending = codeContinuation
            codeContinuation = nil
            return pending
        }
        guard let continuation else { return }
        continuation.resume(with: result)
        stop()
    }

    static func parseCallback(_ request: String) -> (code: String, state: String)? {
        guard let requestLine = request.components(separatedBy: "\r\n").first,
              let target = requestLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(target)"),
              let items = components.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else {
            return nil
        }
        return (code, state)
    }

    private static func send(html: String, to connection: NWConnection) {
        let body = Array(html.utf8)
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(contentsOf: body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>TablePro</title></head>
    <body style="font-family:-apple-system,Helvetica,Arial,sans-serif;text-align:center;padding-top:80px">
    <h2>Signed in to xAI</h2><p>You can return to TablePro.</p></body></html>
    """

    private static let failurePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>TablePro</title></head>
    <body style="font-family:-apple-system,Helvetica,Arial,sans-serif;text-align:center;padding-top:80px">
    <h2>Sign-in failed</h2><p>Please return to TablePro and try again.</p></body></html>
    """
}
