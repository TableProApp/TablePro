//
//  BigQueryOAuthServer.swift
//  BigQueryDriverPlugin
//
//  Ephemeral localhost HTTP server for Google OAuth 2.0 redirect handling.
//

import Foundation
import Network
import os

internal final class BigQueryOAuthServer: @unchecked Sendable {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()
    private var timeoutTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryOAuthServer")

    /// Phase 1: Start NWListener, await .ready, return the bound port.
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

    /// Phase 2: Wait for the OAuth callback with a 2-minute timeout. Returns the auth code.
    func waitForAuthCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { continuation = cont }
            // Start 2-minute timeout
            let task = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                self.lock.withLock {
                    if let cont = self.continuation {
                        self.continuation = nil
                        cont.resume(throwing: BigQueryError.timeout("OAuth authorization timed out (2 minutes)"))
                    }
                }
                self.stop()
            }
            lock.withLock { timeoutTask = task }
        }
    }

    func stop() {
        let (task, conn, lst): (Task<Void, Never>?, NWConnection?, NWListener?) = lock.withLock {
            let t = timeoutTask
            let c = connection
            let l = listener
            timeoutTask = nil
            connection = nil
            listener = nil
            return (t, c, l)
        }
        task?.cancel()
        conn?.cancel()
        lst?.cancel()
    }

    private func startListener() throws {
        let params = NWParameters.tcp
        // Only accept connections from localhost
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
                Self.logger.error("OAuth server failed: \(error.localizedDescription)")
                let authError = BigQueryError.authFailed("OAuth server failed: \(error.localizedDescription)")
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
            case .cancelled:
                break
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, _, error in
            guard let self, let data = content, error == nil else {
                self?.resumeWithError(BigQueryError.authFailed("Failed to read OAuth callback"))
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.resumeWithError(BigQueryError.authFailed("Invalid OAuth callback data"))
                return
            }

            // Parse GET /path?code=AUTH_CODE&scope=... HTTP/1.1
            if let code = self.extractAuthCode(from: requestString) {
                self.sendSuccessResponse(to: connection)
                self.resumeWithCode(code)
            } else if requestString.contains("error=") {
                let errorDesc = self.extractParam(named: "error", from: requestString) ?? "unknown"
                self.sendErrorResponse(to: connection, error: errorDesc)
                self.resumeWithError(BigQueryError.authFailed("OAuth authorization denied: \(errorDesc)"))
            } else {
                // Might be favicon request or similar — ignore and wait for the real one
                self.readRequest(from: connection)
            }
        }
    }

    private func extractAuthCode(from request: String) -> String? {
        // HTTP request: GET /?code=AUTH_CODE&scope=... HTTP/1.1
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(pathPart)")
        else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func extractParam(named name: String, from request: String) -> String? {
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(pathPart)")
        else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func sendSuccessResponse(to connection: NWConnection) {
        let html = """
            <html><body style="font-family:system-ui;text-align:center;padding:60px;">
            <h2>Authorization Successful</h2>
            <p>You can close this tab and return to TablePro.</p>
            </body></html>
            """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendErrorResponse(to connection: NWConnection, error: String) {
        let escaped = htmlEscape(error)
        let html = """
            <html><body style="font-family:system-ui;text-align:center;padding:60px;">
            <h2>Authorization Failed</h2>
            <p>\(escaped)</p>
            <p>Please close this tab and try again in TablePro.</p>
            </body></html>
            """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resumeWithCode(_ code: String) {
        lock.withLock {
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: code)
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
