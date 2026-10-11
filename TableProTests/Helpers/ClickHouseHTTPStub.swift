import Foundation
import TableProPluginKit

struct ClickHouseStubRequest: Sendable {
    let queryItems: [String: String]
    let body: String
    let timeoutInterval: TimeInterval

    func item(_ name: String) -> String? {
        queryItems[name]
    }
}

struct ClickHouseStubReply: Sendable {
    let statusCode: Int
    let body: String

    static let oneRow = ClickHouseStubReply(statusCode: 200, body: "n\nUInt8\n1\n")
    static let empty = ClickHouseStubReply(statusCode: 200, body: "")
}

final class ClickHouseHTTPStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (ClickHouseStubRequest) -> ClickHouseStubReply?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responders: [String: Responder] = [:]
    nonisolated(unsafe) private static var recorded: [String: [ClickHouseStubRequest]] = [:]

    static func register(host: String, responder: @escaping Responder) {
        lock.withLock { responders[host] = responder }
    }

    static func requests(to host: String) -> [ClickHouseStubRequest] {
        lock.withLock { recorded[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let stubRequest = ClickHouseStubRequest(
            queryItems: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }),
            body: Self.bodyText(of: request),
            timeoutInterval: request.timeoutInterval
        )
        let responder = Self.lock.withLock { () -> Responder? in
            Self.recorded[host, default: []].append(stubRequest)
            return Self.responders[host]
        }
        guard let responder,
              let reply = responder(stubRequest),
              let response = HTTPURLResponse(url: url, statusCode: reply.statusCode, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyText(of request: URLRequest) -> String {
        guard let stream = request.httpBodyStream else {
            return String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

struct ClickHouseStubServer {
    let host = "clickhouse-\(UUID().uuidString.lowercased()).test"

    init(responder: @escaping ClickHouseHTTPStubProtocol.Responder = { _ in .oneRow }) {
        ClickHouseHTTPStubProtocol.register(host: host, responder: responder)
    }

    var requests: [ClickHouseStubRequest] {
        ClickHouseHTTPStubProtocol.requests(to: host)
    }

    func connectedDriver() -> ClickHousePluginDriver {
        let driver = ClickHousePluginDriver(config: DriverConnectionConfig(
            host: host,
            port: 8_123,
            username: "default",
            password: "",
            database: "default"
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClickHouseHTTPStubProtocol.self]
        driver.session = URLSession(configuration: configuration)
        return driver
    }

    func firstRequest(where matches: (ClickHouseStubRequest) -> Bool) async -> ClickHouseStubRequest? {
        for _ in 0 ..< 500 {
            if let request = requests.first(where: matches) {
                return request
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
