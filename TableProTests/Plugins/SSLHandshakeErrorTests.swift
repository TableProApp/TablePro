import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SSLHandshakeError")
struct SSLHandshakeErrorTests {
    @Test("serverRejectedPlaintext suggests switching to Required")
    func testServerRejectedPlaintext() {
        let error = SSLHandshakeError.serverRejectedPlaintext(serverMessage: "FATAL: no pg_hba.conf entry")
        #expect(error.errorDescription?.contains("requires") == true)
        #expect(error.recoverySuggestion?.contains("Required") == true)
        #expect(error.serverMessage.contains("pg_hba"))
    }

    @Test("serverRequiresPlaintext suggests switching to Disabled")
    func testServerRequiresPlaintext() {
        let error = SSLHandshakeError.serverRequiresPlaintext(serverMessage: "Server does not support SSL")
        #expect(error.errorDescription?.contains("does not accept") == true)
        #expect(error.recoverySuggestion?.contains("Disabled") == true)
    }

    @Test("untrustedCertificate suggests Verify CA")
    func testUntrustedCertificate() {
        let error = SSLHandshakeError.untrustedCertificate(serverMessage: "self-signed certificate")
        #expect(error.errorDescription?.contains("could not be verified") == true)
        #expect(error.recoverySuggestion?.contains("Verify CA") == true)
    }

    @Test("hostnameMismatch suggests fix path")
    func testHostnameMismatch() {
        let error = SSLHandshakeError.hostnameMismatch(serverMessage: "hostname does not match certificate")
        #expect(error.errorDescription?.contains("hostname") == true)
        #expect(error.recoverySuggestion != nil)
    }

    @Test("clientCertRequired suggests providing client cert")
    func testClientCertRequired() {
        let error = SSLHandshakeError.clientCertRequired(serverMessage: "client certificate required")
        #expect(error.recoverySuggestion?.contains("client certificate") == true)
    }

    @Test("cipherMismatch suggests server update")
    func testCipherMismatch() {
        let error = SSLHandshakeError.cipherMismatch(serverMessage: "no shared cipher")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("formatted() redacts password from libpq-style conninfo")
    func testSanitizeKeyValuePassword() {
        let error = SSLHandshakeError.untrustedCertificate(serverMessage: "host=db.example.com user=root password=Sup3rS3cret port=5432")
        let formatted = SSLHandshakeError.formatted(error)
        #expect(!formatted.contains("Sup3rS3cret"))
        #expect(formatted.contains("password=[redacted]"))
    }

    @Test("formatted() redacts password from URL userinfo segment")
    func testSanitizeURLUserInfo() {
        let error = SSLHandshakeError.serverRejectedPlaintext(serverMessage: "Failed: postgresql://admin:LeakedPass@db.example.com/app")
        let formatted = SSLHandshakeError.formatted(error)
        #expect(!formatted.contains("LeakedPass"))
        #expect(formatted.contains("://[redacted]@"))
    }

    @Test("formatted() leaves non-credential text untouched")
    func testSanitizePreservesContent() {
        let error = SSLHandshakeError.cipherMismatch(serverMessage: "no shared cipher between client and server")
        let formatted = SSLHandshakeError.formatted(error)
        #expect(formatted.contains("no shared cipher"))
    }

    @Test("All cases expose the original server message")
    func testServerMessageRoundTrip() {
        let cases: [SSLHandshakeError] = [
            .serverRejectedPlaintext(serverMessage: "msg-1"),
            .serverRequiresPlaintext(serverMessage: "msg-2"),
            .untrustedCertificate(serverMessage: "msg-3"),
            .hostnameMismatch(serverMessage: "msg-4"),
            .clientCertRequired(serverMessage: "msg-5"),
            .cipherMismatch(serverMessage: "msg-6"),
            .unknown(serverMessage: "msg-7")
        ]
        for error in cases {
            #expect(!error.serverMessage.isEmpty)
        }
    }
}
