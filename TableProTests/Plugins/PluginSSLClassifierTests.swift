import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("LibPQ SSL Classifier")
struct LibPQClassifierTests {
    @Test("Classifies the AWS RDS rejection in #1298 as serverRejectedPlaintext")
    func testRDSPattern() {
        let msg = "FATAL: no pg_hba.conf entry for host \"1.2.3.4\", user \"u\", database \"d\", no encryption"
        guard case .serverRejectedPlaintext = LibPQClassifier.classifySSLError(msg) else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }

    @Test("Classifies SSL-required as serverRequiresPlaintext")
    func testSSLRequired() {
        let msg = "FATAL: no pg_hba.conf entry for host \"1.2.3.4\", user \"u\", database \"d\", SSL on"
        guard case .serverRequiresPlaintext = LibPQClassifier.classifySSLError(msg) else {
            Issue.record("Expected serverRequiresPlaintext")
            return
        }
    }

    @Test("Classifies server-no-ssl-support as serverRequiresPlaintext")
    func testServerNoSSL() {
        let msg = "server does not support SSL, but SSL was required"
        guard case .serverRequiresPlaintext = LibPQClassifier.classifySSLError(msg) else {
            Issue.record("Expected serverRequiresPlaintext")
            return
        }
    }

    @Test("Classifies cert verify failure as untrustedCertificate")
    func testCertVerify() {
        let msg = "SSL error: certificate verify failed"
        guard case .untrustedCertificate = LibPQClassifier.classifySSLError(msg) else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("Classifies hostname mismatch")
    func testHostnameMismatch() {
        let msg = "server certificate for \"foo\" does not match host name \"bar\""
        guard case .hostnameMismatch = LibPQClassifier.classifySSLError(msg) else {
            Issue.record("Expected hostnameMismatch")
            return
        }
    }

    @Test("Non-SSL error returns nil")
    func testNonSSL() {
        #expect(LibPQClassifier.classifySSLError("FATAL: password authentication failed") == nil)
        #expect(LibPQClassifier.classifySSLError("connection refused") == nil)
    }
}

@Suite("MariaDB SSL Classifier")
struct MariaDBClassifierTests {
    @Test("CR_SSL_CONNECTION_ERROR with cipher message → cipherMismatch")
    func testSSLConnectionError() {
        guard case .cipherMismatch = MariaDBClassifier.classifySSLError(code: 2_026, message: "SSL connection error: no shared cipher") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("CR_SSL_CONNECTION_ERROR with certificate keyword → untrustedCertificate")
    func testSSLCertError() {
        guard case .untrustedCertificate = MariaDBClassifier.classifySSLError(code: 2_026, message: "SSL certificate not trusted") else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("require_secure_transport → serverRejectedPlaintext")
    func testRequireSecureTransport() {
        guard case .serverRejectedPlaintext = MariaDBClassifier.classifySSLError(code: 1_045, message: "Connections using insecure transport are prohibited while --require_secure_transport=ON") else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }

    @Test("Auth error 1045 not retried (returns nil)")
    func testAuthError() {
        #expect(MariaDBClassifier.classifySSLError(code: 1_045, message: "Access denied for user 'foo'@'bar'") == nil)
    }

    @Test("Network error 2002 not retried")
    func testNetworkError() {
        #expect(MariaDBClassifier.classifySSLError(code: 2_002, message: "Can't connect to MySQL server") == nil)
    }
}

@Suite("FreeTDS SSL Classifier")
struct FreeTDSClassifierTests {
    @Test("Server requires encryption → serverRejectedPlaintext")
    func testServerRequires() {
        guard case .serverRejectedPlaintext = FreeTDSClassifier.classifySSLError("Server requires encryption") else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }

    @Test("OpenSSL handshake → cipherMismatch")
    func testOpenSSL() {
        guard case .cipherMismatch = FreeTDSClassifier.classifySSLError("OpenSSL: SSL_connect failed") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }
}

@Suite("MongoDB SSL Classifier")
struct MongoDBClassifierTests {
    @Test("TLS handshake failed → cipherMismatch")
    func testTLSHandshake() {
        guard case .cipherMismatch = MongoDBClassifier.classifySSLError("TLS handshake failed: bad cipher") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Hostname verification failure → hostnameMismatch")
    func testHostnameVerification() {
        guard case .hostnameMismatch = MongoDBClassifier.classifySSLError("hostname verification failed") else {
            Issue.record("Expected hostnameMismatch")
            return
        }
    }

    @Test("TLS required → serverRejectedPlaintext")
    func testTLSRequired() {
        guard case .serverRejectedPlaintext = MongoDBClassifier.classifySSLError("TLS required by Atlas cluster") else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }
}

@Suite("Redis SSL Classifier")
struct RedisClassifierTests {
    @Test("No shared cipher → cipherMismatch")
    func testNoSharedCipher() {
        guard case .cipherMismatch = RedisClassifier.classifySSLError("SSL_connect: no shared cipher") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Cert verify failed → untrustedCertificate")
    func testCertVerify() {
        guard case .untrustedCertificate = RedisClassifier.classifySSLError("certificate verify failed (self-signed)") else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }
}

@Suite("Oracle SSL Classifier")
struct OracleClassifierTests {
    @Test("ORA-29024 → cipherMismatch")
    func testORA29024() {
        guard case .cipherMismatch = OracleClassifier.classifySSLError("ORA-29024: Certificate validation failure") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Network timeout (ORA-12606) is not classified as SSL")
    func testTimeoutNotSSL() {
        #expect(OracleClassifier.classifySSLError("ORA-12606: TNS: Application timeout occurred") == nil)
    }

    @Test("ORA-28759 → clientCertRequired")
    func testORA28759() {
        guard case .clientCertRequired = OracleClassifier.classifySSLError("ORA-28759: failure to open file") else {
            Issue.record("Expected clientCertRequired")
            return
        }
    }
}

@Suite("ClickHouse SSL Classifier")
struct ClickHouseClassifierTests {
    @Test("URLError.secureConnectionFailed → cipherMismatch")
    func testSecureConnectionFailed() {
        let error = URLError(.secureConnectionFailed)
        guard case .cipherMismatch = ClickHouseClassifier.classifySSLError(error) else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("URLError.serverCertificateUntrusted → untrustedCertificate")
    func testCertUntrusted() {
        let error = URLError(.serverCertificateUntrusted)
        guard case .untrustedCertificate = ClickHouseClassifier.classifySSLError(error) else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("Non-SSL error returns nil")
    func testNonSSL() {
        let error = URLError(.notConnectedToInternet)
        #expect(ClickHouseClassifier.classifySSLError(error) == nil)
    }
}

@Suite("Cassandra Client Key Classifier")
struct CassandraClassifierTests {
    private let encryptedPkcs8 = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF...\n-----END ENCRYPTED PRIVATE KEY-----"
    private let encryptedPkcs1 = """
    -----BEGIN RSA PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-256-CBC,1234

    MIIE...
    -----END RSA PRIVATE KEY-----
    """
    private let unencryptedPkcs8 = "-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----"

    @Test("Detects PKCS#8 and PKCS#1 encrypted keys, not unencrypted ones")
    func testEncryptionDetection() {
        #expect(CassandraClassifier.isEncryptedPrivateKey(encryptedPkcs8))
        #expect(CassandraClassifier.isEncryptedPrivateKey(encryptedPkcs1))
        #expect(!CassandraClassifier.isEncryptedPrivateKey(unencryptedPkcs8))
    }

    @Test("Encrypted key with no passphrase → clientKeyPassphraseRequired")
    func testEncryptedNoPassphrase() {
        let error = CassandraClassifier.privateKeyLoadError(
            keyPEM: encryptedPkcs8, hasPassphrase: false, keyPath: "/k.pem")
        guard case .clientKeyPassphraseRequired = error else {
            Issue.record("Expected clientKeyPassphraseRequired")
            return
        }
    }

    @Test("Encrypted key with wrong passphrase → clientKeyPassphraseIncorrect")
    func testEncryptedWrongPassphrase() {
        let error = CassandraClassifier.privateKeyLoadError(
            keyPEM: encryptedPkcs1, hasPassphrase: true, keyPath: "/k.pem")
        guard case .clientKeyPassphraseIncorrect = error else {
            Issue.record("Expected clientKeyPassphraseIncorrect")
            return
        }
    }

    @Test("Unencrypted but unreadable key → clientKeyInvalid, never a passphrase error")
    func testUnencryptedInvalid() {
        let withoutPassphrase = CassandraClassifier.privateKeyLoadError(
            keyPEM: unencryptedPkcs8, hasPassphrase: false, keyPath: "/k.pem")
        let withPassphrase = CassandraClassifier.privateKeyLoadError(
            keyPEM: unencryptedPkcs8, hasPassphrase: true, keyPath: "/k.pem")
        guard case .clientKeyInvalid = withoutPassphrase else {
            Issue.record("Expected clientKeyInvalid without passphrase")
            return
        }
        guard case .clientKeyInvalid = withPassphrase else {
            Issue.record("Expected clientKeyInvalid with passphrase")
            return
        }
    }
}
