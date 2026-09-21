//
//  OpenAICompatibleProviderConnectionTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

private final class StubConnectionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var requestedURLs: [String] = []

    nonisolated(unsafe) private static var contentType = "application/json"

    static func respond(status: Int, body: String, contentType: String = "application/json") {
        lock.lock(); defer { lock.unlock() }
        Self.status = status
        Self.body = Data(body.utf8)
        Self.contentType = contentType
        requestedURLs = []
    }

    static func lastRequestedURL() -> String? {
        lock.lock(); defer { lock.unlock() }
        return requestedURLs.last
    }

    private static func record(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        requestedURLs.append(url)
    }

    private static func current() -> (status: Int, body: Data, contentType: String) {
        lock.lock(); defer { lock.unlock() }
        return (status, body, contentType)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = Self.current()
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": response.contentType]
              )
        else { return }
        Self.record(url.absoluteString)
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("OpenAICompatibleProvider connection test", .serialized)
struct OpenAICompatibleProviderConnectionTests {
    private func makeProvider(endpoint: String) -> OpenAICompatibleProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubConnectionProtocol.self]
        return OpenAICompatibleProvider(
            endpoint: endpoint,
            apiKey: "key",
            providerType: .custom,
            model: "glm-4.6",
            session: URLSession(configuration: config)
        )
    }

    @Test("A 200 is a working connection")
    func acceptsOK() async throws {
        StubConnectionProtocol.respond(status: 200, body: "{}")
        #expect(try await makeProvider(endpoint: "https://host/v1").testConnection())
    }

    @Test("A 400 is a working connection, because the server answered the API")
    func acceptsBadRequest() async throws {
        StubConnectionProtocol.respond(status: 400, body: #"{"error":{"message":"bad param"}}"#)
        #expect(try await makeProvider(endpoint: "https://host/v1").testConnection())
    }

    /// A 404 answered with a JSON error page used to read as success, so a wrong Base URL was
    /// saved with a green "Connection successful".
    @Test("A JSON 404 is a failure, not a success")
    func rejectsJSONNotFound() async {
        StubConnectionProtocol.respond(
            status: 404,
            body: #"{"timestamp":"2026-09-21T16:05:33.970+00:00","status":404,"error":"Not Found"}"#
        )
        await #expect(throws: AIProviderError.self) {
            _ = try await makeProvider(endpoint: "https://host/v1").testConnection()
        }
    }

    @Test("A JSON 500 is a failure, not a success")
    func rejectsJSONServerError() async {
        StubConnectionProtocol.respond(status: 500, body: #"{"error":{"message":"boom"}}"#)
        await #expect(throws: AIProviderError.self) {
            _ = try await makeProvider(endpoint: "https://host/v1").testConnection()
        }
    }

    @Test("A 401 reports an authentication failure")
    func reportsAuthFailure() async {
        StubConnectionProtocol.respond(status: 401, body: "{}")
        await #expect(throws: AIProviderError.self) {
            _ = try await makeProvider(endpoint: "https://host/v1").testConnection()
        }
    }

    @Test("An endpoint with no scheme reports the app's own invalid-endpoint error")
    func reportsInvalidEndpoint() async {
        StubConnectionProtocol.respond(status: 200, body: "{}")
        await #expect(throws: AIProviderError.self) {
            _ = try await makeProvider(endpoint: "api.z.ai/api/paas/v4").testConnection()
        }
    }

    /// A wrong Base URL that lands on a proxy login page or a single-page app's fallback route
    /// answers 200 with HTML, which the chat stream cannot read.
    @Test("An HTML 200 is not a working connection")
    func rejectsHTMLSuccess() async throws {
        StubConnectionProtocol.respond(
            status: 200,
            body: "<!doctype html><html><body>Sign in</body></html>",
            contentType: "text/html; charset=utf-8"
        )
        #expect(try await makeProvider(endpoint: "https://host/v1").testConnection() == false)
    }

    @Test("A JSON body with no content type is still a working connection")
    func acceptsJSONWithoutContentType() async throws {
        StubConnectionProtocol.respond(status: 200, body: "{}", contentType: "text/plain")
        #expect(try await makeProvider(endpoint: "https://host/v1").testConnection())
    }

    @Test("The connection test reaches the server's own version segment")
    func callsTheResolvedURL() async throws {
        StubConnectionProtocol.respond(status: 200, body: "{}")
        _ = try await makeProvider(endpoint: "https://api.z.ai/api/paas/v4").testConnection()
        #expect(StubConnectionProtocol.lastRequestedURL() == "https://api.z.ai/api/paas/v4/chat/completions")
    }
}
