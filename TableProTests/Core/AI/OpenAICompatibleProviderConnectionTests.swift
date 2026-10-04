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
    private func makeProvider(
        endpoint: String,
        treatsForbiddenAsAuthFailure: Bool = false
    ) -> OpenAICompatibleProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubConnectionProtocol.self]
        return OpenAICompatibleProvider(
            endpoint: endpoint,
            apiKey: "key",
            providerType: .custom,
            model: "glm-4.6",
            treatsForbiddenAsAuthFailure: treatsForbiddenAsAuthFailure,
            session: URLSession(configuration: config)
        )
    }

    private func thrownError(_ body: () async throws -> Void) async -> AIProviderError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? AIProviderError
        }
    }

    private func isAuthenticationFailure(_ error: AIProviderError?) -> Bool {
        if case .authenticationFailed = error { return true }
        return false
    }

    private static let requestyBadKeyBody = #"{"error":{"origin":"router","message":"Invalid authorization token"}}"#

    /// Requesty answers a wrong key with 403. Read as a server error, the sheet said "Server error
    /// (403)" and the chat offered to retry a request that could never succeed.
    @Test("A 403 from a server that rejects bad keys that way is an authentication failure")
    func forbiddenIsAnAuthFailureForAPresetThatSaysSo() async {
        StubConnectionProtocol.respond(status: 403, body: Self.requestyBadKeyBody)
        let provider = makeProvider(endpoint: "https://router.requesty.ai", treatsForbiddenAsAuthFailure: true)
        let error = await thrownError { _ = try await provider.testConnection() }
        #expect(isAuthenticationFailure(error))
        #expect(error?.isRetryable == false)
    }

    @Test("A 403 from any other server stays a server error")
    func forbiddenStaysAServerErrorByDefault() async {
        StubConnectionProtocol.respond(status: 403, body: #"{"error":{"message":"region not supported"}}"#)
        let error = await thrownError { _ = try await makeProvider(endpoint: "https://host/v1").testConnection() }
        #expect(error != nil)
        #expect(!isAuthenticationFailure(error))
    }

    @Test("A 403 on the model list is an authentication failure for such a server")
    func forbiddenModelListIsAnAuthFailure() async {
        StubConnectionProtocol.respond(status: 403, body: Self.requestyBadKeyBody)
        let provider = makeProvider(endpoint: "https://router.requesty.ai", treatsForbiddenAsAuthFailure: true)
        let error = await thrownError { _ = try await provider.fetchAvailableModels() }
        #expect(isAuthenticationFailure(error))
    }

    @Test("A 403 on a chat turn is an authentication failure for such a server, so it is not retried")
    func forbiddenChatTurnIsAnAuthFailure() async {
        StubConnectionProtocol.respond(status: 403, body: Self.requestyBadKeyBody)
        let provider = makeProvider(endpoint: "https://router.requesty.ai", treatsForbiddenAsAuthFailure: true)
        let error = await thrownError {
            let stream = provider.streamChat(
                turns: [ChatTurnWire(role: .user, blocks: [.text("hi")])],
                options: ChatTransportOptions(model: "glm-4.6")
            )
            for try await _ in stream {}
        }
        #expect(isAuthenticationFailure(error))
        #expect(error?.isRetryable == false)
    }

    @Test("A provider built from the Requesty preset reads a 403 as a rejected key")
    func presetProviderCarriesTheRule() async {
        StubConnectionProtocol.respond(status: 403, body: Self.requestyBadKeyBody)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubConnectionProtocol.self]
        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(preset: .requesty),
            apiKey: "key",
            session: URLSession(configuration: sessionConfig)
        )
        let error = await thrownError { _ = try await provider.testConnection() }
        #expect(isAuthenticationFailure(error))
        #expect(StubConnectionProtocol.lastRequestedURL() == "https://router.requesty.ai/v1/chat/completions")
    }

    @Test("A plain custom provider built from its configuration keeps a 403 as a server error")
    func plainCustomProviderDoesNot() async {
        StubConnectionProtocol.respond(status: 403, body: Self.requestyBadKeyBody)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubConnectionProtocol.self]
        let provider = OpenAICompatibleProvider(
            config: AIProviderConfig(type: .custom, endpoint: "https://host/v1"),
            apiKey: "key",
            session: URLSession(configuration: sessionConfig)
        )
        let error = await thrownError { _ = try await provider.testConnection() }
        #expect(error != nil)
        #expect(!isAuthenticationFailure(error))
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
