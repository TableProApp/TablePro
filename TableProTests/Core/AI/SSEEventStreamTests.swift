//
//  SSEEventStreamTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private struct SSETestState {
    var deltas = 0
}

private actor RefreshCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private func sseRequest() -> URLRequest {
    URLRequest(url: URL(string: "https://example.com/responses")!)
}

private func sseDecodeLine(_ line: String) -> [String: Any]? {
    guard line.hasPrefix("data: ") else { return nil }
    let payload = String(line.dropFirst(6))
    guard let data = payload.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

private func sseParse(_ json: [String: Any], _ state: inout SSETestState) -> [ChatStreamEvent] {
    guard let text = json["text"] as? String else { return [] }
    state.deltas += 1
    return [.textDelta(text)]
}

private func collectText(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [String] {
    var texts: [String] = []
    for try await event in stream {
        if case .textDelta(let value) = event { texts.append(value) }
    }
    return texts
}

private final class MockSSEProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [(status: Int, body: Data)] = []

    static func enqueue(_ responses: [(status: Int, body: Data)]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses
    }

    private static func next() -> (status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? (200, Data()) : queue.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = Self.next()
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("SSEEventStream")
struct SSEEventStreamTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSSEProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Parses streamed lines then emits final events, in order")
    func happyPathOrdering() async throws {
        MockSSEProtocol.enqueue([(200, Data("data: {\"text\":\"a\"}\n\ndata: {\"text\":\"b\"}\n\n".utf8))])
        let stream = SSEEventStream.make(
            session: makeSession(),
            buildRequest: { sseRequest() },
            decodeLine: sseDecodeLine,
            makeState: { SSETestState() },
            parse: { sseParse($0, &$1) },
            finalEvents: { _ in [.textDelta("FINAL")] }
        )
        let texts = try await collectText(stream)
        #expect(texts == ["a", "b", "FINAL"])
    }

    @Test("Non-200 throws a mapped provider error")
    func nonOKThrows() async throws {
        MockSSEProtocol.enqueue([(500, Data("{\"error\":{\"message\":\"boom\"}}".utf8))])
        let stream = SSEEventStream.make(
            session: makeSession(),
            buildRequest: { sseRequest() },
            decodeLine: sseDecodeLine,
            makeState: { SSETestState() },
            parse: { sseParse($0, &$1) }
        )
        await #expect(throws: AIProviderError.self) {
            _ = try await collectText(stream)
        }
    }

    @Test("A 401 refreshes once and retries the request")
    func unauthorizedRetries() async throws {
        MockSSEProtocol.enqueue([
            (401, Data()),
            (200, Data("data: {\"text\":\"ok\"}\n\n".utf8))
        ])
        let counter = RefreshCounter()
        let stream = SSEEventStream.make(
            session: makeSession(),
            buildRequest: { sseRequest() },
            decodeLine: sseDecodeLine,
            makeState: { SSETestState() },
            parse: { sseParse($0, &$1) },
            refreshOnUnauthorized: { await counter.bump() }
        )
        let texts = try await collectText(stream)
        #expect(texts == ["ok"])
        #expect(await counter.count == 1)
    }
}
