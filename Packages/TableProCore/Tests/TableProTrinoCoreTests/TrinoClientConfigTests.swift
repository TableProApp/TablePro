import Foundation
@testable import TableProTrinoCore
import Testing

@Suite("TrinoClientConfig")
struct TrinoClientConfigTests {
    @Test("The TLS setting alone picks the scheme, so an explicit SSL off on 443 stays plain HTTP")
    func statementURLScheme() {
        let plainHTTP = TrinoClientConfig(host: "trino.example.com", port: 443, user: "tablepro")
        let https = TrinoClientConfig(host: "trino.example.com", port: 443, useTLS: true, user: "tablepro")

        #expect(plainHTTP.statementURL?.absoluteString == "http://trino.example.com:443/v1/statement")
        #expect(https.statementURL?.absoluteString == "https://trino.example.com:443/v1/statement")
    }

    @Test("A password or an access token is a plaintext credential only when TLS is off")
    func plaintextCredential() {
        func config(useTLS: Bool, auth: TrinoAuth) -> TrinoClientConfig {
            TrinoClientConfig(host: "trino.example.com", useTLS: useTLS, user: "tablepro", auth: auth)
        }

        #expect(config(useTLS: false, auth: .basic(password: "secret")).plaintextCredential == .password)
        #expect(config(useTLS: false, auth: .jwt(token: "t")).plaintextCredential == .accessToken)
        #expect(config(useTLS: false, auth: .none).plaintextCredential == nil)
        #expect(config(useTLS: true, auth: .basic(password: "secret")).plaintextCredential == nil)
        #expect(config(useTLS: true, auth: .jwt(token: "t")).plaintextCredential == nil)
    }

    @Test("The refusal names the credential and what to change, and never the secret")
    func credentialRefusalText() {
        #expect(TrinoError.credentialsRequireTLS(.password).errorDescription
            == "A password is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify Identity, "
            + "or clear the password if the cluster has no authentication.")
        #expect(TrinoError.credentialsRequireTLS(.accessToken).errorDescription
            == "An access token is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify "
            + "Identity, or clear the Access Token if the cluster has no authentication.")
    }
}
