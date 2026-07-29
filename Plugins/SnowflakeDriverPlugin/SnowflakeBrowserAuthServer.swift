//
//  SnowflakeBrowserAuthServer.swift
//  SnowflakeDriverPlugin
//
//  Ephemeral localhost HTTP server that captures the SAML token returned by the
//  identity provider during EXTERNALBROWSER (SSO) authentication.
//

import Foundation
import Network
import os

final class SnowflakeBrowserAuthServer: @unchecked Sendable {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()
    private var timeoutTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeBrowserAuthServer")

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { readyContinuation = cont }
            do {
                try startListener()
            } catch {
                lock.withLock { readyContinuation = nil }
                cont.resume(throwing: error)
            }
        }
    }

    func waitForToken() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { continuation = cont }
            let task = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                self.lock.withLock {
                    if let cont = self.continuation {
                        self.continuation = nil
                        cont.resume(throwing: SnowflakeError.timeout("Browser authentication timed out (2 minutes)"))
                    }
                }
                self.stop()
            }
            lock.withLock { timeoutTask = task }
        }
    }

    func stop() {
        let (task, conn, lst): (Task<Void, Never>?, NWConnection?, NWListener?) = lock.withLock {
            let values = (timeoutTask, connection, listener)
            timeoutTask = nil
            connection = nil
            listener = nil
            return values
        }
        task?.cancel()
        conn?.cancel()
        lst?.cancel()
    }

    private func startListener() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: params)
        lock.withLock { self.listener = listener }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                self?.lock.withLock {
                    if let cont = self?.readyContinuation {
                        self?.readyContinuation = nil
                        cont.resume(returning: port)
                    }
                }
            case .failed(let error):
                Self.logger.error("Browser auth server failed: \(error.localizedDescription)")
                let authError = SnowflakeError.authFailed("Browser auth server failed: \(error.localizedDescription)")
                self?.lock.withLock {
                    if let cont = self?.readyContinuation {
                        self?.readyContinuation = nil
                        cont.resume(throwing: authError)
                    }
                    if let cont = self?.continuation {
                        self?.continuation = nil
                        cont.resume(throwing: authError)
                    }
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] newConnection in
            self?.handleConnection(newConnection)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, _, error in
            guard let self, let data = content, error == nil,
                  let request = String(data: data, encoding: .utf8) else {
                self?.resumeWithError(SnowflakeError.authFailed("Failed to read browser callback"))
                return
            }

            if let token = self.extractToken(from: request) {
                self.sendSuccessResponse(to: connection)
                self.resumeWithToken(token)
            } else if request.contains("error=") {
                let desc = self.extractParam(named: "error", from: request) ?? "unknown"
                self.sendErrorResponse(to: connection, error: desc)
                self.resumeWithError(SnowflakeError.authFailed("SSO authorization failed: \(desc)"))
            } else {
                self.readRequest(from: connection)
            }
        }
    }

    private func extractToken(from request: String) -> String? {
        extractParam(named: "token", from: request)
    }

    private func extractParam(named name: String, from request: String) -> String? {
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(pathPart)")
        else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func sendSuccessResponse(to connection: NWConnection) {
        let html = """
            <html><body style="font-family:system-ui;text-align:center;padding:60px;">
            <h2>Authentication Successful</h2>
            <p>You can close this tab and return to TablePro.</p>
            </body></html>
            """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendErrorResponse(to connection: NWConnection, error: String) {
        let escaped = error
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
            <html><body style="font-family:system-ui;text-align:center;padding:60px;">
            <h2>Authentication Failed</h2>
            <p>\(escaped)</p>
            </body></html>
            """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resumeWithToken(_ token: String) {
        lock.withLock {
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: token)
            }
        }
        stop()
    }

    private func resumeWithError(_ error: Error) {
        lock.withLock {
            if let cont = continuation {
                continuation = nil
                cont.resume(throwing: error)
            }
        }
        stop()
    }
}
