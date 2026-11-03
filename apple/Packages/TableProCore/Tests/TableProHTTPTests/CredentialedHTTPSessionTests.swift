import Foundation
import TableProHTTP
import TableProTestSupport
import Testing

struct CredentialedHTTPSessionTests {
    private static let account = "https://acct.snowflakecomputing.com"

    private static func snowflakeSession() throws -> CredentialedHTTPSession {
        let origin = try #require(URL(string: account).flatMap(HTTPOrigin.init))
        return CredentialedHTTPSession(origin: origin, session: URLSession(configuration: .ephemeral)) { _ in }
    }

    @Test("A result path the server names stays on the account host", arguments: [
        ("/queries/x/result", "https://acct.snowflakecomputing.com/queries/x/result"),
        ("@collector.example/x", "https://acct.snowflakecomputing.com/@collector.example/x"),
        ("https://ACCT.snowflakecomputing.com:443/queries/y", "https://ACCT.snowflakecomputing.com:443/queries/y"),
    ])
    func followsSameOriginServerURL(value: String, expected: String) throws {
        let url = try Self.snowflakeSession().followServerURL(value)
        #expect(url.absoluteString == expected)
        #expect(url.host == "acct.snowflakecomputing.com" || url.host == "ACCT.snowflakecomputing.com")
    }

    @Test("A result URL on another host, scheme or port is refused", arguments: [
        "//collector.example/x",
        "http://acct.snowflakecomputing.com/x",
        "https://acct.snowflakecomputing.com.evil.example/x",
        "https://acct.snowflakecomputing.com:8443/x",
        "https:collector.example/x",
    ])
    func refusesOtherServerURL(value: String) throws {
        let session = try Self.snowflakeSession()
        #expect(throws: CredentialedHTTPError.crossOrigin(value)) {
            try session.followServerURL(value)
        }
    }

    @Test("A 307 to another port is refused, and the token never reaches that port")
    func crossOriginRedirectNeverReachesTheOtherPort() async throws {
        let other = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 200, body: "{}") }
        try await other.start()
        defer { other.stop() }
        let location = other.url("/v1/auth/approle/login").absoluteString
        let vault = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 307, headers: ["Location": location]) }
        try await vault.start()
        defer { vault.stop() }

        let origin = try #require(HTTPOrigin(vault.url("/")))
        let session = CredentialedHTTPSession(origin: origin, session: URLSession(configuration: .ephemeral)) {
            $0.setValue("vault-token", forHTTPHeaderField: "X-Vault-Token")
        }
        var request = URLRequest(url: vault.url("/v1/auth/approle/login"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"role_id":"r","secret_id":"s"}"#.utf8)

        await #expect(throws: CredentialedHTTPError.redirected(status: 307, location: location)) {
            try await session.data(for: request)
        }
        #expect(vault.requests.first?.header("X-Vault-Token") == "vault-token")
        #expect(other.requests.isEmpty)
    }

    @Test("A same-origin 302 is followed with the credential applied again")
    func sameOriginRedirectCarriesTheCredential() async throws {
        let server = try LoopbackHTTPResponder { request in
            request.path == "/start"
                ? LoopbackResponse(status: 302, headers: ["Location": "/landed"])
                : LoopbackResponse(status: 200, body: "ok")
        }
        try await server.start()
        defer { server.stop() }

        let origin = try #require(HTTPOrigin(server.url("/")))
        let session = CredentialedHTTPSession(origin: origin, session: URLSession(configuration: .ephemeral)) {
            $0.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: URLRequest(url: server.url("/start")))

        #expect(response.statusCode == 200)
        #expect(String(bytes: data, encoding: .utf8) == "ok")
        let paths = server.requests.map { $0.path }
        #expect(paths == ["/start", "/landed"])
        #expect(server.requests.last?.header("Authorization") == "Bearer secret")
    }

    @Test("A request off the origin is refused before anything is sent")
    func requestOffTheOriginIsNotSent() async throws {
        let other = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 200) }
        try await other.start()
        defer { other.stop() }
        let origin = try #require(URL(string: "http://127.0.0.1:1").flatMap(HTTPOrigin.init))
        let session = CredentialedHTTPSession(origin: origin, session: URLSession(configuration: .ephemeral)) {
            $0.setValue("token", forHTTPHeaderField: "X-Vault-Token")
        }
        let target = other.url("/v1/sys/health")

        await #expect(throws: CredentialedHTTPError.crossOrigin(target.absoluteString)) {
            try await session.data(for: URLRequest(url: target))
        }
        #expect(other.requests.isEmpty)
    }
}
