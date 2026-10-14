import Foundation
import TableProPluginKit
import Testing

struct RedisTLSFailureTests {
    @Test("a certificate naming another host is reported as a hostname mismatch, not an untrusted root")
    func nameMismatchIsHostnameMismatch() {
        let failure = RedisTLSFailure.certificateNameMismatch(
            "SSL_connect failed: certificate verify failed: hostname mismatch"
        )
        guard case .hostnameMismatch(let message) = failure.connectError as? SSLHandshakeError else {
            Issue.record("expected hostnameMismatch, got \(failure.connectError)")
            return
        }
        #expect(message.contains("hostname mismatch"))
    }

    @Test("an untrusted chain keeps its untrusted classification")
    func untrustedChainStaysUntrusted() {
        let failure = RedisTLSFailure.handshakeFailed("SSL_connect failed: certificate verify failed")
        guard case .untrustedCertificate = failure.connectError as? SSLHandshakeError else {
            Issue.record("expected untrustedCertificate, got \(failure.connectError)")
            return
        }
    }

    @Test("an unclassified handshake failure keeps the handshake message")
    func unclassifiedHandshakeFailure() throws {
        let failure = RedisTLSFailure.handshakeFailed("SSL_connect failed: Connection reset by peer")
        let error = try #require(failure.connectError as? RedisPluginError)
        #expect(error.message == "SSL handshake failed: SSL_connect failed: Connection reset by peer")
    }

    @Test("a context that could not be built reports its code")
    func contextRejectedReportsCode() throws {
        let error = try #require(RedisTLSFailure.contextRejected(code: 3).connectError as? RedisPluginError)
        #expect(error.code == 3)
        #expect(error.message == "Failed to create SSL context (error 3)")
    }
}
