import Foundation
import TableProGoogleCloud
@testable import TableProSpannerCore

struct StubSpannerResponse: Sendable {
    let status: Int
    let chunks: [Data]
    let requestFailure: SpannerTransportError?
    let trailingFailure: SpannerTransportError?

    init(
        status: Int = 200,
        chunks: [Data] = [],
        requestFailure: SpannerTransportError? = nil,
        trailingFailure: SpannerTransportError? = nil
    ) {
        self.status = status
        self.chunks = chunks
        self.requestFailure = requestFailure
        self.trailingFailure = trailingFailure
    }

    var body: Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    static func json(_ text: String, status: Int = 200) -> StubSpannerResponse {
        StubSpannerResponse(status: status, chunks: [Data(text.utf8)])
    }

    static func stream(_ chunks: [String], status: Int = 200, trailingFailure: SpannerTransportError? = nil) -> StubSpannerResponse {
        StubSpannerResponse(status: status, chunks: chunks.map { Data($0.utf8) }, trailingFailure: trailingFailure)
    }

    static func failing(_ error: SpannerTransportError) -> StubSpannerResponse {
        StubSpannerResponse(requestFailure: error)
    }
}

final class StubSpannerTransport: SpannerTransport, @unchecked Sendable {
    typealias Responder = @Sendable (URLRequest) async throws -> StubSpannerResponse?

    private let lock = NSLock()
    private let responder: Responder?
    private var queue: [StubSpannerResponse]
    private var log: [URLRequest] = []
    private var closes = 0

    init(_ responses: [StubSpannerResponse] = [], responder: Responder? = nil) {
        self.queue = responses
        self.responder = responder
    }

    var requests: [URLRequest] {
        lock.withLock { log }
    }

    var closeCount: Int {
        lock.withLock { closes }
    }

    func enqueue(_ responses: StubSpannerResponse...) {
        lock.withLock { queue.append(contentsOf: responses) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try await nextResponse(for: request)
        if let failure = response.requestFailure {
            throw failure
        }
        return (response.body, try Self.httpResponse(for: request, status: response.status))
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let response = try await nextResponse(for: request)
        if let failure = response.requestFailure {
            throw failure
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in response.chunks {
                continuation.yield(chunk)
            }
            continuation.finish(throwing: response.trailingFailure)
        }
        return (try Self.httpResponse(for: request, status: response.status), body)
    }

    func close() async {
        lock.withLock { closes += 1 }
    }

    private func nextResponse(for request: URLRequest) async throws -> StubSpannerResponse {
        lock.withLock { log.append(request) }
        if let responder, let answer = try await responder(request) {
            return answer
        }
        return lock.withLock { () -> StubSpannerResponse in
            guard !queue.isEmpty else { return .json("{}") }
            return queue.removeFirst()
        }
    }

    private static func httpResponse(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            throw SpannerTransportError.invalidResponse
        }
        return response
    }
}

actor StubAccessTokenProvider: GoogleAccessTokenProviding {
    private var tokens: [String]
    private(set) var accessTokenCalls = 0
    private(set) var invalidations = 0

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func accessToken() async throws -> String {
        accessTokenCalls += 1
        guard tokens.count > 1 else { return tokens.first ?? "" }
        return tokens.removeFirst()
    }

    func invalidateCachedToken() async {
        invalidations += 1
    }
}

enum SpannerEmulatorEnvironment {
    static var host: String? {
        value("SPANNER_EMULATOR_HOST")
    }

    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum SpannerTestFixtures {
    static let databasePath = "projects/proj/instances/inst/databases/gdb"
    static let sessionName = "projects/proj/instances/inst/databases/gdb/sessions/s1"

    static func settings(
        endpoint: String = "",
        authMethod: SpannerAuthMethod = .serviceAccount
    ) throws -> SpannerConnectionSettings {
        try SpannerConnectionSettings.parse(fields: [
            SpannerConnectionSettings.FieldKey.projectId: "proj",
            SpannerConnectionSettings.FieldKey.instanceId: "inst",
            SpannerConnectionSettings.FieldKey.databaseId: "gdb",
            SpannerConnectionSettings.FieldKey.endpoint: endpoint,
            SpannerConnectionSettings.FieldKey.authMethod: authMethod.rawValue
        ])
    }

    static func emulatorSettings() throws -> SpannerConnectionSettings {
        try settings(endpoint: "http://localhost:9020", authMethod: .emulator)
    }

    static func client(
        transport: StubSpannerTransport,
        settings: SpannerConnectionSettings,
        tokenProvider: (any GoogleAccessTokenProviding)? = nil
    ) -> SpannerRESTClient {
        SpannerRESTClient(
            settings: settings,
            transport: transport,
            tokenProvider: tokenProvider,
            retryDelays: [.zero, .zero, .zero]
        )
    }

    static func emulatorClient(transport: StubSpannerTransport) throws -> SpannerRESTClient {
        client(transport: transport, settings: try emulatorSettings())
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: httpBody)) as? [String: Any]
    }

    var authorization: String? {
        value(forHTTPHeaderField: "Authorization")
    }

    var absoluteURL: String {
        url?.absoluteString ?? ""
    }
}

func collectEvents(_ stream: AsyncThrowingStream<SpannerStreamEvent, Error>) async throws -> [SpannerStreamEvent] {
    var events: [SpannerStreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

func streamedRows(_ events: [SpannerStreamEvent]) -> [[SpannerJSONValue]] {
    events.flatMap { event -> [[SpannerJSONValue]] in
        guard case .rows(let rows) = event else { return [] }
        return rows
    }
}
