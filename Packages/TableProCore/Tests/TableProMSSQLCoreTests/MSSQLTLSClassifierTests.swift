import Testing
@testable import TableProMSSQLCore

@Suite("MSSQL TLS Classifier")
struct MSSQLTLSClassifierTests {
    @Test("Server requires encryption → serverRejectedPlaintext")
    func testServerRequires() {
        guard case .serverRejectedPlaintext = MSSQLTLSClassifier.classifySSLError("Server requires encryption") else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }

    @Test("Server does not support encryption → serverRequiresPlaintext")
    func testServerNoSupport() {
        guard case .serverRequiresPlaintext = MSSQLTLSClassifier.classifySSLError("encryption not supported by server") else {
            Issue.record("Expected serverRequiresPlaintext")
            return
        }
    }

    @Test("Certificate verify failed → untrustedCertificate")
    func testUntrustedCertificate() {
        guard case .untrustedCertificate = MSSQLTLSClassifier.classifySSLError("certificate verify failed") else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("Hostname mismatch → hostnameMismatch")
    func testHostnameMismatch() {
        guard case .hostnameMismatch = MSSQLTLSClassifier.classifySSLError("certificate does not match host name") else {
            Issue.record("Expected hostnameMismatch")
            return
        }
    }

    @Test("OpenSSL handshake → cipherMismatch")
    func testOpenSSL() {
        guard case .cipherMismatch = MSSQLTLSClassifier.classifySSLError("OpenSSL error during SSL handshake") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Non-TLS error returns nil")
    func testNonTLS() {
        #expect(MSSQLTLSClassifier.classifySSLError("Login failed for user 'sa'") == nil)
    }
}
