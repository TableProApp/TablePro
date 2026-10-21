import CryptoKit
import Foundation
import Network

// The loopback pairing flow in developers/pairing.mdx.
public struct CLIPairingRequest: Sendable, Equatable {
    public static let callbackPath = "/tablepro-pairing"

    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.base64Url(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = state
    }

    public static func random() -> CLIPairingRequest {
        CLIPairingRequest(verifier: base64Url(randomBytes(32)), state: base64Url(randomBytes(16)))
    }

    public func link(callbackPort: UInt16) -> URL? {
        var redirect = URLComponents()
        redirect.scheme = "http"
        redirect.host = "127.0.0.1"
        redirect.port = Int(callbackPort)
        redirect.path = Self.callbackPath
        guard let redirectUrl = redirect.url else { return nil }

        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "integrations"
        components.path = "/pair"
        components.queryItems = [
            URLQueryItem(name: "client", value: CLIClientIdentity.pairingName),
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "redirect", value: redirectUrl.absoluteString),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scopes", value: "readOnly")
        ]
        return components.url
    }

    static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public enum CLIPairingCallback: Sendable, Equatable {
    case approved(code: String)
    case denied
    // Another path, or a `state` from some other request.
    case ignored

    public static func parse(requestTarget: String, state: String) -> CLIPairingCallback {
        guard let components = URLComponents(string: requestTarget),
              components.path == CLIPairingRequest.callbackPath else {
            return .ignored
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("state") == state else { return .ignored }
        if let code = value("code"), !code.isEmpty {
            return .approved(code: code)
        }
        return value("error") == nil ? .ignored : .denied
    }
}

public final class CLICallbackListener: @unchecked Sendable {
    private static let maximumHeadBytes = 16 * 1_024

    private let state: String
    private let queue = DispatchQueue(label: "com.TablePro.cli.pairing")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var outcome: CLIPairingCallback?
    private var waiter: CheckedContinuation<CLIPairingCallback, Never>?

    public init(state: String) {
        self.state = state
    }

    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        lock.withLock { self.listener = listener }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { @Sendable [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    // Nil when nothing answered in time.
    public func waitForCallback(timeout: Duration) async -> CLIPairingCallback? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.ignored)
        }
        defer { timer.cancel() }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CLIPairingCallback, Never>) in
            let ready: CLIPairingCallback? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
        return result == .ignored ? nil : result
    }

    public func stop() {
        let (listener, connections) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            let taken = (self.listener, self.connections)
            self.listener = nil
            self.connections = []
            return taken
        }
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func finish(_ result: CLIPairingCallback) {
        let waiting: CheckedContinuation<CLIPairingCallback, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            let taken = waiter
            waiter = nil
            return taken
        }
        waiting?.resume(returning: result)
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { @Sendable [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if let head = Self.requestHead(accumulated) {
                self.answer(head, on: connection)
                return
            }
            guard error == nil, !isComplete, accumulated.count < Self.maximumHeadBytes else {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let parts = head.split(separator: " ", maxSplits: 2)
        let callback: CLIPairingCallback
        if parts.count >= 2, parts[0] == "GET" {
            callback = CLIPairingCallback.parse(requestTarget: String(parts[1]), state: state)
        } else {
            callback = .ignored
        }
        let response = Self.response(for: callback)
        connection.send(content: response, completion: .contentProcessed { @Sendable _ in
            connection.cancel()
        })
        guard callback != .ignored else { return }
        finish(callback)
    }

    static func requestHead(_ data: Data) -> String? {
        guard let end = data.range(of: Data("\r\n".utf8)) else { return nil }
        return String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
    }

    static func response(for callback: CLIPairingCallback) -> Data {
        let status: String
        let message: String
        switch callback {
        case .approved:
            status = "200 OK"
            message = "TablePro paired the tablepro command. You can close this tab."
        case .denied:
            status = "200 OK"
            message = "Pairing was declined. You can close this tab."
        case .ignored:
            status = "404 Not Found"
            message = "Nothing here."
        }
        let body = "<!doctype html><meta charset=\"utf-8\"><title>TablePro</title><p>\(message)</p>\n"
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data((head + body).utf8)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
