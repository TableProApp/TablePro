import Foundation
import TableProPluginKit
import Testing

struct LibPQClassifierTests {
    @Test("Classifies the AWS RDS rejection in #1298 as serverRejectedPlaintext")
    func testRDSPattern() {
        let msg = "FATAL: no pg_hba.conf entry for host \"1.2.3.4\", user \"u\", database \"d\", no encryption"
        guard case .serverRejectedPlaintext = LibPQSSLClassifier.classifySSLError(msg) else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }

    @Test("Classifies SSL-required as serverRequiresPlaintext")
    func testSSLRequired() {
        let msg = "FATAL: no pg_hba.conf entry for host \"1.2.3.4\", user \"u\", database \"d\", SSL on"
        guard case .serverRequiresPlaintext = LibPQSSLClassifier.classifySSLError(msg) else {
            Issue.record("Expected serverRequiresPlaintext")
            return
        }
    }

    @Test("Classifies server-no-ssl-support as serverRequiresPlaintext")
    func testServerNoSSL() {
        let msg = "server does not support SSL, but SSL was required"
        guard case .serverRequiresPlaintext = LibPQSSLClassifier.classifySSLError(msg) else {
            Issue.record("Expected serverRequiresPlaintext")
            return
        }
    }

    @Test("Classifies cert verify failure as untrustedCertificate")
    func testCertVerify() {
        let msg = "SSL error: certificate verify failed"
        guard case .untrustedCertificate = LibPQSSLClassifier.classifySSLError(msg) else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("Classifies hostname mismatch")
    func testHostnameMismatch() {
        let msg = "server certificate for \"foo\" does not match host name \"bar\""
        guard case .hostnameMismatch = LibPQSSLClassifier.classifySSLError(msg) else {
            Issue.record("Expected hostnameMismatch")
            return
        }
    }

    @Test("Non-SSL error returns nil")
    func testNonSSL() {
        #expect(LibPQSSLClassifier.classifySSLError("FATAL: password authentication failed") == nil)
        #expect(LibPQSSLClassifier.classifySSLError("connection refused") == nil)
    }
}

struct MariaDBClassifierTests {
    @Test("CR_SSL_CONNECTION_ERROR with cipher message → cipherMismatch")
    func testSSLConnectionError() {
        guard case .cipherMismatch = MariaDBSSLClassifier.classifySSLError(code: 2_026, message: "SSL connection error: no shared cipher") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("CR_SSL_CONNECTION_ERROR with certificate keyword → untrustedCertificate")
    func testSSLCertError() {
        guard case .untrustedCertificate = MariaDBSSLClassifier.classifySSLError(code: 2_026, message: "SSL certificate not trusted") else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("require_secure_transport → serverRejectedPlaintext")
    func testRequireSecureTransport() {
        let message = "Connections using insecure transport are prohibited while --require_secure_transport=ON"
        guard case .serverRejectedPlaintext = MariaDBSSLClassifier.classifySSLError(code: 1_045, message: message) else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }

    @Test("Auth error 1045 not retried (returns nil)")
    func testAuthError() {
        #expect(MariaDBSSLClassifier.classifySSLError(code: 1_045, message: "Access denied for user 'foo'@'bar'") == nil)
    }

    @Test("Network error 2002 not retried")
    func testNetworkError() {
        #expect(MariaDBSSLClassifier.classifySSLError(code: 2_002, message: "Can't connect to MySQL server") == nil)
    }
}

struct RedisClassifierTests {
    @Test("No shared cipher → cipherMismatch")
    func testNoSharedCipher() {
        guard case .cipherMismatch = RedisSSLClassifier.classifySSLError("SSL_connect: no shared cipher") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Cert verify failed → untrustedCertificate")
    func testCertVerify() {
        guard case .untrustedCertificate = RedisSSLClassifier.classifySSLError("certificate verify failed (self-signed)") else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }
}

struct ClickHouseClassifierTests {
    @Test("URLError.secureConnectionFailed → cipherMismatch")
    func testSecureConnectionFailed() {
        let error = URLError(.secureConnectionFailed)
        guard case .cipherMismatch = ClickHouseSSLClassifier.classifySSLError(error) else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("URLError.serverCertificateUntrusted → untrustedCertificate")
    func testCertUntrusted() {
        let error = URLError(.serverCertificateUntrusted)
        guard case .untrustedCertificate = ClickHouseSSLClassifier.classifySSLError(error) else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("Non-SSL error returns nil")
    func testNonSSL() {
        let error = URLError(
            .notConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        #expect(ClickHouseSSLClassifier.classifySSLError(error) == nil)
    }

    @Test("A host lookup failure is not a TLS hostname mismatch")
    func testHostLookupFailureIsNotTLS() {
        let error = URLError(
            .cannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found."]
        )
        #expect(ClickHouseSSLClassifier.classifySSLError(error) == nil)
    }

    @Test("A host lookup failure wrapped by the driver is not a TLS hostname mismatch")
    func testWrappedHostLookupFailureIsNotTLS() {
        let lookup = URLError(
            .cannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found."]
        )
        let wrapped = NSError(
            domain: "ClickHouse",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "A server with the specified hostname could not be found.",
                NSUnderlyingErrorKey: lookup
            ]
        )
        #expect(ClickHouseSSLClassifier.classifySSLError(wrapped) == nil)
    }

    @Test("A hostname complaint that is not a URL error still reads as a hostname mismatch")
    func testHostnameMessageOutsideURLError() {
        let error = NSError(
            domain: "ClickHouse",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "certificate hostname does not match"]
        )
        guard case .hostnameMismatch = ClickHouseSSLClassifier.classifySSLError(error) else {
            Issue.record("Expected hostnameMismatch")
            return
        }
    }
}
