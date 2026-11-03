import Foundation
import TableProHTTP
import TableProTestSupport
import Testing

struct SameOriginRedirectsTests {
    private static func apiKeyPost(to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("sk-secret", forHTTPHeaderField: "x-api-key")
        request.httpBody = Data(#"{"prompt":"hi"}"#.utf8)
        return request
    }

    @Test("A redirect on the same scheme, host and port is followed, the default port written or not", arguments: [
        ("https://registry.example.com/base", "https://REGISTRY.example.com/other"),
        ("http://registry.example.com", "http://registry.example.com:80/schemas"),
        ("https://registry.example.com:443/", "https://registry.example.com/schemas"),
        ("http://localhost:8081", "http://localhost:8081/subjects"),
    ])
    func sameOriginIsFollowed(origin: String, target: String) {
        #expect(SameOriginRedirects.follows(URL(string: target), from: URL(string: origin)))
    }

    @Test("A redirect to another host, port or scheme is refused, a downgrade to http included", arguments: [
        ("https://registry.example.com", "https://evil.example.com"),
        ("https://registry.example.com", "http://registry.example.com"),
        ("http://localhost:8081", "http://localhost:8082"),
        ("https://registry.example.com", "https://registry.example.com:8443"),
        ("https://registry.example.com", "file:///etc/passwd"),
    ])
    func otherOriginIsRefused(origin: String, target: String) {
        #expect(!SameOriginRedirects.follows(URL(string: target), from: URL(string: origin)))
    }

    @Test("A 307 to another origin comes back as the response, and the API key never reaches that origin")
    func crossOriginRedirectIsNotFollowed() async throws {
        let collector = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 200, body: "{}") }
        try await collector.start()
        defer { collector.stop() }
        let location = collector.url("/v1/messages").absoluteString
        let gateway = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 307, headers: ["Location": location]) }
        try await gateway.start()
        defer { gateway.stop() }

        let (_, response) = try await URLSession(configuration: .ephemeral).data(
            for: Self.apiKeyPost(to: gateway.url("/v1/messages")),
            delegate: SameOriginRedirects.shared
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        #expect(gateway.requests.first?.header("x-api-key") == "sk-secret")
        #expect(collector.requests.isEmpty)
    }

    @Test("A streamed request is not followed to another origin either")
    func crossOriginRedirectIsNotFollowedForBytes() async throws {
        let collector = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 200, body: "data: {}\n\n") }
        try await collector.start()
        defer { collector.stop() }
        let location = collector.url("/v1/messages").absoluteString
        let gateway = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 302, headers: ["Location": location]) }
        try await gateway.start()
        defer { gateway.stop() }

        let (_, response) = try await URLSession(configuration: .ephemeral).bytes(
            for: Self.apiKeyPost(to: gateway.url("/v1/messages")),
            delegate: SameOriginRedirects.shared
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(collector.requests.isEmpty)
    }

    @Test("A redirect on the same origin is followed")
    func sameOriginRedirectIsFollowed() async throws {
        let server = try LoopbackHTTPResponder { request in
            request.path == "/start"
                ? LoopbackResponse(status: 307, headers: ["Location": "/landed"])
                : LoopbackResponse(status: 200, body: "ok")
        }
        try await server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession(configuration: .ephemeral).data(
            for: Self.apiKeyPost(to: server.url("/start")),
            delegate: SameOriginRedirects.shared
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(bytes: data, encoding: .utf8) == "ok")
        let paths = server.requests.map { $0.path }
        #expect(paths == ["/start", "/landed"])
        #expect(server.requests.last?.header("x-api-key") == "sk-secret")
    }
}
