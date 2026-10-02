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

/// Each session carries its own route header, so cases running in parallel never read each other's
/// scripted replies through the shared protocol class.
private final class MockSSEProtocol: URLProtocol, @unchecked Sendable {
    private static let routeHeader = "X-SSE-Test-Route"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [(status: Int, body: Data)]] = [:]

    static func session(replying replies: [(status: Int, body: Data)]) -> URLSession {
        let route = UUID().uuidString
        lock.withLock { scripts[route] = replies }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSSEProtocol.self]
        config.httpAdditionalHeaders = [routeHeader: route]
        return URLSession(configuration: config)
    }

    private static func nextReply(for request: URLRequest) -> (status: Int, body: Data)? {
        guard let route = request.value(forHTTPHeaderField: routeHeader) else { return nil }
        return lock.withLock {
            guard var replies = scripts[route], !replies.isEmpty else { return nil }
            let reply = replies.removeFirst()
            scripts[route] = replies
            return reply
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let reply = Self.nextReply(for: request),
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct SSEEventStreamTests {
    @Test("Parses streamed lines then emits final events, in order")
    func happyPathOrdering() async throws {
        let session = MockSSEProtocol.session(
            replying: [(200, Data("data: {\"text\":\"a\"}\n\ndata: {\"text\":\"b\"}\n\n".utf8))]
        )
        let stream = SSEEventStream.make(
            session: session,
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
        let session = MockSSEProtocol.session(replying: [(500, Data("{\"error\":{\"message\":\"boom\"}}".utf8))])
        let stream = SSEEventStream.make(
            session: session,
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
        let session = MockSSEProtocol.session(replying: [
            (401, Data()),
            (200, Data("data: {\"text\":\"ok\"}\n\n".utf8))
        ])
        let counter = RefreshCounter()
        let stream = SSEEventStream.make(
            session: session,
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
