import Foundation
import Testing
@testable import TableProR2SQLCore

/// A protocol that answers `/ok` at once and leaves every other request hanging until cancelled,
/// so a test can hold several requests in flight and watch what a cancel does to each.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastTimeout: TimeInterval?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastTimeout = request.timeoutInterval
        guard request.url?.path == "/ok", let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("R2 SQL URLSession transport", .serialized)
struct R2SQLURLSessionTransportTests {
    private func transport() -> URLSessionR2SQLTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionR2SQLTransport(configuration: configuration, resourceTimeout: 3_600)
    }

    private func request(_ path: String, timeout: TimeInterval = 60) throws -> R2SQLHTTPRequest {
        R2SQLHTTPRequest(
            url: try #require(URL(string: "https://r2.test\(path)")),
            headers: [:],
            body: Data(),
            timeoutInterval: timeout
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A request carries its own timeout and returns the status and body")
    func roundTrip() async throws {
        let response = try await transport().send(try request("/ok", timeout: 330))

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"success":true}"#)
        #expect(StubProtocol.lastTimeout == 330)
    }

    @Test("Cancelling everything stops every request in flight, not just the latest")
    func cancelAllStopsEveryRequest() async throws {
        let transport = transport()
        let firstRequest = try request("/hang/1")
        let secondRequest = try request("/hang/2")
        let first = Task { try await transport.send(firstRequest) }
        let second = Task { try await transport.send(secondRequest) }
        await waitUntil { transport.inFlightCount == 2 }

        transport.cancelAll()

        for task in [first, second] {
            await #expect(throws: R2SQLError.cancelled) { try await task.value }
        }
    }

    @Test("Cancelling the awaiting task cancels its request")
    func taskCancellation() async throws {
        let transport = transport()
        let hanging = try request("/hang")
        let task = Task { try await transport.send(hanging) }
        await waitUntil { transport.inFlightCount == 1 }

        task.cancel()

        await #expect(throws: R2SQLError.cancelled) { try await task.value }
        #expect(transport.inFlightCount == 0)
    }
}
