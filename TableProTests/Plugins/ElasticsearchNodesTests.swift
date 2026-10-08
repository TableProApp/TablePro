//
//  ElasticsearchNodesTests.swift
//  TableProTests
//

import Foundation
import Network
@testable import TablePro
import TableProPluginKit
import Testing

struct ElasticsearchNodesTests {
    @Test("The node list wins over Host and Port")
    func listWins() {
        let nodes = ElasticsearchNodes.nodes(
            hostList: "es1.example:9201, [fd00::2]:9200,es3.example",
            host: "ignored.example",
            port: 9_200,
            useTLS: true
        )
        #expect(nodes.map(\.baseURL.absoluteString) == [
            "https://es1.example:9201",
            "https://[fd00::2]:9200",
            "https://es3.example:9200",
        ])
    }

    @Test("An empty list falls back to Host and Port, bracketing an IPv6 host")
    func fallbackToHost() {
        #expect(ElasticsearchNodes.nodes(hostList: "", host: "::1", port: 9_201, useTLS: false)
            .map(\.baseURL.absoluteString) == ["http://[::1]:9201"])
        #expect(ElasticsearchNodes.nodes(hostList: nil, host: "", port: 0, useTLS: false)
            .map(\.name) == ["localhost:9200"])
    }

    @Test("A pasted https:// node uses TLS even with SSL Mode left on Disabled")
    func httpsEntryUsesTLS() {
        let nodes = ElasticsearchNodes.nodes(
            hostList: "https://111.111.111.111:9200,https://111.111.111.112:9200",
            host: "",
            port: 9_200,
            useTLS: false
        )
        #expect(nodes.map(\.baseURL.absoluteString) == [
            "https://111.111.111.111:9200",
            "https://111.111.111.112:9200",
        ])
    }

    @Test(
        "The driver reads a row the way the connection form does",
        arguments: [
            "es1", "es1:9201", "https://es1", "http://es1:9300/", "[::1]:9201", "fe80::1",
            "es1:abc", "es1:0", "ftp://es1", "https://user:secret@es1", "es1/prefix", "[::1",
        ]
    )
    func grammarMatchesTheForm(entry: String) {
        let form = HostListEndpoint.parse(entry, defaultPort: 9_200)?.entry
        let driver = ElasticsearchNodes.node(from: entry, defaultPort: 9_200, useTLS: false)?.name
        #expect(form == driver)
    }

    @Test("Only a failure before the request left may resend a write")
    func neverSentCodes() {
        #expect(ElasticsearchFailover.neverSent(.cannotConnectToHost))
        #expect(ElasticsearchFailover.neverSent(.cannotFindHost))
        #expect(ElasticsearchFailover.neverSent(.serverCertificateUntrusted))
        #expect(!ElasticsearchFailover.neverSent(.timedOut))
        #expect(!ElasticsearchFailover.neverSent(.networkConnectionLost))
        #expect(!ElasticsearchFailover.neverSent(.cancelled))
    }

    @Test("A read moves on after a dropped connection but not after a timeout")
    func readResendPolicy() {
        #expect(ElasticsearchFailover.resends(after: .networkConnectionLost, isRead: true))
        #expect(!ElasticsearchFailover.resends(after: .networkConnectionLost, isRead: false))
        #expect(!ElasticsearchFailover.resends(after: .timedOut, isRead: true))
        #expect(ElasticsearchFailover.resends(after: .cannotConnectToHost, isRead: false))
    }
}

struct ElasticsearchFailoverTests {
    private static let root = MockHttpResponse(
        status: 200,
        headers: [("Content-Type", "application/json")],
        body: Data(#"{"version":{"number":"8.15.0"}}"#.utf8)
    )

    private static func status(_ code: Int) -> MockHttpResponse {
        MockHttpResponse(status: code, headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
    }

    private func connection(hosts: String) throws -> ElasticsearchConnection {
        try ElasticsearchConnection(config: DriverConnectionConfig(
            host: "",
            port: 9_200,
            username: "",
            password: "",
            database: "",
            additionalFields: ["esHosts": hosts, "esAuthMethod": "none"]
        ))
    }

    private func liveServer(_ responses: [MockHttpResponse]) async throws -> MockHttpServer {
        let server = MockHttpServer()
        try await server.start()
        await server.setResponses(responses)
        return server
    }

    @Test("Connect skips a node that refuses and stays on the one that answers")
    func connectSkipsRefusedNode() async throws {
        let live = try await liveServer([Self.root])
        let connection = try connection(hosts: "127.0.0.1:1,127.0.0.1:\(live.port)")

        try await connection.connect()
        try await connection.ping()

        #expect(connection.serverVersion == "8.15.0")
        #expect(await live.requests.map(\.path) == ["/", "/_cluster/health"])
        connection.disconnect()
        await live.stop()
    }

    @Test(
        "A node that trickles its reply gives up its share of the connect timeout",
        .timeLimit(.minutes(1))
    )
    func tricklingNodeKeepsToItsShare() async throws {
        let slow = try TricklingHTTPServer()
        try await slow.start()
        let live = try await liveServer([Self.root])
        let connection = try ElasticsearchConnection(config: DriverConnectionConfig(
            host: "",
            port: 9_200,
            username: "",
            password: "",
            database: "",
            additionalFields: [
                "esHosts": "127.0.0.1:\(slow.port),127.0.0.1:\(live.port)",
                "esAuthMethod": "none",
                "connectTimeoutMilliseconds": "3000",
            ]
        ))

        try await connection.connect()

        #expect(await live.requests.map(\.path) == ["/"])
        connection.disconnect()
        slow.stop()
        await live.stop()
    }

    @Test("When every node fails, the error names each one")
    func allNodesDown() async throws {
        let connection = try connection(hosts: "127.0.0.1:1,127.0.0.1:2")
        let error = await #expect(throws: ElasticsearchError.self) { try await connection.connect() }
        let message = error?.localizedDescription ?? ""
        #expect(message.contains("127.0.0.1:1"))
        #expect(message.contains("127.0.0.1:2"))
    }

    @Test("A rejected login stops at the first node")
    func authFailureStops() async throws {
        let first = try await liveServer([Self.status(401)])
        let second = try await liveServer([Self.root])
        let connection = try connection(hosts: "127.0.0.1:\(first.port),127.0.0.1:\(second.port)")

        await #expect(throws: ElasticsearchError.self) { try await connection.connect() }

        #expect(await second.requests.isEmpty)
        await first.stop()
        await second.stop()
    }

    @Test("A write goes to the next node when its node refuses the connection")
    func writeResentAfterRefusal() async throws {
        let first = try await liveServer([Self.root])
        let second = try await liveServer([Self.status(201)])
        let connection = try connection(hosts: "127.0.0.1:\(first.port),127.0.0.1:\(second.port)")
        try await connection.connect()
        await first.stop()

        let response = try await connection.request(method: "PUT", path: "/books/_doc/1", body: "{}")
        _ = try await connection.request(method: "GET", path: "/_cluster/health")

        #expect(response.statusCode == 201)
        #expect(await second.requests.map(\.method) == ["PUT", "GET"])
        connection.disconnect()
        await second.stop()
    }

    @Test("A GET with a body goes out as POST and is not sent again")
    func getWithBodyIsAWrite() async throws {
        let first = try await liveServer([Self.root, Self.status(503)])
        let second = try await liveServer([Self.root])
        let connection = try connection(hosts: "127.0.0.1:\(first.port),127.0.0.1:\(second.port)")
        try await connection.connect()

        let response = try await connection.request(method: "GET", path: "/books/_update/1", body: "{}")

        #expect(response.statusCode == 503)
        #expect(await second.requests.isEmpty)
        connection.disconnect()
        await first.stop()
        await second.stop()
    }

    @Test("A path that names another host is refused before anything is sent")
    func schemeRelativePathIsRefused() async throws {
        let node = try await liveServer([Self.root])
        let other = try await liveServer([Self.root])
        let connection = try connection(hosts: "127.0.0.1:\(node.port)")
        try await connection.connect()

        await #expect(throws: ElasticsearchError.self) {
            try await connection.request(method: "GET", path: "//127.0.0.1:\(other.port)/_cluster/health")
        }

        #expect(await other.requests.isEmpty)
        connection.disconnect()
        await node.stop()
        await other.stop()
    }

    @Test("A write a node answered is not sent again, a read is")
    func answeredWriteIsNotResent() async throws {
        let first = try await liveServer([Self.root, Self.status(503)])
        let second = try await liveServer([Self.root])
        let connection = try connection(hosts: "127.0.0.1:\(first.port),127.0.0.1:\(second.port)")
        try await connection.connect()

        let write = try await connection.request(method: "POST", path: "/books/_doc", body: "{}")
        #expect(write.statusCode == 503)
        #expect(await second.requests.isEmpty)

        let read = try await connection.request(method: "GET", path: "/_cluster/health")
        #expect(read.statusCode == 200)
        #expect(await second.requests.map(\.path) == ["/_cluster/health"])
        connection.disconnect()
        await first.stop()
        await second.stop()
    }
}

/// Answers with headers and then one byte every 100 ms, so URLSession's idle timeout never fires.
private final class TricklingHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TricklingHTTPServer")
    private var connections: [NWConnection] = []
    private var resumed = false
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.resumed else { return }
                switch state {
                case .ready:
                    self.resumed = true
                    self.port = self.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    self.resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100000\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        drip(to: connection)
    }

    private func drip(to connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            connection.send(content: Data(" ".utf8), completion: .contentProcessed { error in
                if error == nil { self?.drip(to: connection) }
            })
        }
    }
}
