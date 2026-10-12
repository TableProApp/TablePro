import Foundation
@testable import TableProTrinoCore
import Testing

struct TrinoRedirectPolicyTests {
    private func refusal(
        _ statusCode: Int,
        location: String?,
        from request: String,
        useTLS: Bool = false
    ) throws -> TrinoError {
        let response = TrinoHTTPResponse(
            statusCode: statusCode,
            headers: TrinoHeaderFields(location.map { ["Location": $0] } ?? [:]),
            body: Data("<html><head><title>Moved</title></head></html>".utf8)
        )
        return TrinoRedirectPolicy.refusal(
            for: response,
            requestURL: try #require(URL(string: request)),
            useTLS: useTLS
        )
    }

    @Test("Plain HTTP redirected to HTTPS on the same host and port is the plaintext rejection")
    func sameHostAndPortUpgrade() throws {
        let error = try refusal(
            301,
            location: "https://trino.example.com/v1/statement",
            from: "http://trino.example.com:443/v1/statement"
        )

        #expect(error == .tlsHandshakeFailed(
            kind: .serverRejectedPlaintext,
            serverMessage: "301 redirect to https://trino.example.com/v1/statement"
        ))
    }

    @Test("An HTTPS redirect to another port names the port")
    func upgradeToAnotherPort() throws {
        let error = try refusal(
            308,
            location: "https://trino.example.com/v1/statement",
            from: "http://trino.example.com:8080/v1/statement"
        )

        #expect(error == .redirected(
            statusCode: 308,
            location: "https://trino.example.com/v1/statement",
            advice: .turnOnTLS(port: 443)
        ))
        #expect(error.errorDescription?.contains("Set Port to 443 and SSL Mode to Verify Identity.") == true)
    }

    @Test("A host compared case-insensitively still counts as the same host")
    func hostCaseIsIgnored() throws {
        let error = try refusal(
            301,
            location: "https://Trino.Example.com:8443/v1/statement",
            from: "http://trino.example.com:8443/v1/statement"
        )

        guard case .tlsHandshakeFailed(.serverRejectedPlaintext, _) = error else {
            Issue.record("Expected the plaintext rejection, got \(error)")
            return
        }
    }

    @Test("A redirect from HTTPS to plain HTTP is never advice to turn TLS on")
    func downgradeIsCheckAddress() throws {
        let error = try refusal(
            307,
            location: "http://trino.example.com/v1/statement",
            from: "https://trino.example.com/v1/statement",
            useTLS: true
        )

        #expect(error == .redirected(
            statusCode: 307,
            location: "http://trino.example.com/v1/statement",
            advice: .checkAddress
        ))
    }

    @Test("A redirect to another host, or to another path on the same origin, asks to check the address")
    func otherTargetsAreCheckAddress() throws {
        let otherHost = try refusal(
            302,
            location: "https://gateway.example.com/v1/statement",
            from: "http://trino.example.com:8080/v1/statement"
        )
        let samePath = try refusal(
            307,
            location: "https://trino.example.com/moved/v1/statement",
            from: "https://trino.example.com/v1/statement",
            useTLS: true
        )

        #expect(otherHost == .redirected(
            statusCode: 302,
            location: "https://gateway.example.com/v1/statement",
            advice: .checkAddress
        ))
        #expect(samePath == .redirected(
            statusCode: 307,
            location: "https://trino.example.com/moved/v1/statement",
            advice: .checkAddress
        ))
    }

    @Test("A relative Location resolves against the request and drops its query")
    func relativeLocation() throws {
        let error = try refusal(302, location: "/login?next=%2Fv1", from: "http://trino.example.com:8080/v1/statement")

        #expect(error == .redirected(
            statusCode: 302,
            location: "http://trino.example.com:8080/login",
            advice: .checkAddress
        ))
    }

    @Test("Credentials and tokens in a Location never reach the message")
    func secretsAreDropped() throws {
        let error = try refusal(
            302,
            location: "https://u:p@sso.example.com/auth?state=abc&token=xyz#f",
            from: "https://trino.example.com/v1/statement",
            useTLS: true
        )

        #expect(error == .redirected(statusCode: 302, location: "https://sso.example.com/auth", advice: .checkAddress))
        let description = try #require(error.errorDescription)
        #expect(!description.contains("token"))
        #expect(!description.contains("u:p"))
    }

    @Test("A 3xx with no Location says so")
    func missingLocation() throws {
        let error = try refusal(300, location: nil, from: "http://trino.example.com:8080/v1/statement")

        #expect(error == .redirected(statusCode: 300, location: nil, advice: .checkAddress))
        #expect(error.errorDescription?.hasPrefix("The server answered with HTTP 300 and no address.") == true)
    }
}
