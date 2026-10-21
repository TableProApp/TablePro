//
//  VaultFakeTransport.swift
//  TableProTests
//

import Foundation
@testable import TablePro

final class VaultFakeTransport: VaultTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
    }

    struct Sent: Equatable {
        let method: String
        let path: String
        let query: String?
        let token: String?
        let namespace: String?
        let body: [String: String]
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var sent: [Sent] = []

    // Replies queue per "METHOD path"; the last one repeats.
    func reply(_ method: String, _ path: String, status: Int = 200, _ body: String) {
        lock.withLock { replies["\(method) \(path)", default: []].append(Reply(status: status, body: body)) }
    }

    var requests: [Sent] { lock.withLock { sent } }

    func requests(to path: String) -> [Sent] {
        requests.filter { $0.path == path }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let path = String(url.path.dropFirst("/v1/".count))
        let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let reply = lock.withLock { () -> Reply? in
            sent.append(Sent(
                method: method,
                path: path,
                query: url.query,
                token: request.value(forHTTPHeaderField: "X-Vault-Token"),
                namespace: request.value(forHTTPHeaderField: "X-Vault-Namespace"),
                body: object.mapValues { "\($0)" }
            ))
            let key = "\(method) \(path)"
            guard var queue = replies[key], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            replies[key] = queue
            return next
        }
        guard let reply,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            throw URLError(.cannotConnectToHost)
        }
        return (Data(reply.body.utf8), response)
    }
}

final class VaultFakeCallbackReceiver: VaultOIDCCallbackReceiving, @unchecked Sendable {
    private let parameters: [String: String]
    private let lock = NSLock()
    private var stopped = false

    init(parameters: [String: String]) {
        self.parameters = parameters
    }

    var wasStopped: Bool { lock.withLock { stopped } }

    func start() async throws {}

    func callback(timeout: Duration) async throws -> [String: String] { parameters }

    func stop() {
        lock.withLock { stopped = true }
    }
}

enum VaultFixtures {
    static let endpoint = VaultEndpoint(
        address: URL(string: "https://vault.test:8200") ?? URL(fileURLWithPath: "/"),
        namespace: nil
    )

    static let credsReply = """
        {"lease_id":"database/creds/readonly/abc","lease_duration":3600,"renewable":true,
         "data":{"username":"v-token-readonly-1","password":"s3cret"}}
        """

    static func lookupReply(ttl: Int = 0) -> String {
        #"{"data":{"ttl":\#(ttl),"renewable":false}}"#
    }

    static func authReply(token: String, ttl: Int = 1200, renewable: Bool = true) -> String {
        #"{"auth":{"client_token":"\#(token)","lease_duration":\#(ttl),"renewable":\#(renewable)}}"#
    }

    static func authenticator(
        transport: VaultFakeTransport,
        environment: [String: String] = ["VAULT_ADDR": "https://vault.test:8200"],
        files: [String: String] = [:],
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        receiver: VaultFakeCallbackReceiver = VaultFakeCallbackReceiver(parameters: [:]),
        opened: OpenedURLs = OpenedURLs()
    ) -> VaultAuthenticator {
        VaultAuthenticator(
            transport: transport,
            environment: { environment },
            readFile: { path in files.first { path.hasSuffix($0.key) }?.value },
            now: now,
            openURL: { opened.append($0) },
            makeCallbackReceiver: { receiver }
        )
    }

    final class OpenedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        var all: [URL] { lock.withLock { urls } }

        func append(_ url: URL) {
            lock.withLock { urls.append(url) }
        }
    }
}
