import Foundation
import TableProPluginKit
import Testing

@Suite("LibPQ SSL Classifier")
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

@Suite("MariaDB SSL Classifier")
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

@Suite("MongoDB SSL Classifier")
struct MongoDBClassifierTests {
    @Test("Atlas internal-error handshake failure → unknown, not cipherMismatch")
    func testAtlasInternalErrorHandshake() {
        let message = "No suitable servers found: [TLS handshake failed: internal error (-9838) "
            + "calling hello on 'ac-zmho1ul-shard-00-00.dsllzcf.mongodb.net:27017']"
        guard case .unknown = MongoDBSSLClassifier.classifySSLError(message) else {
            Issue.record("Expected unknown for a generic handshake failure")
            return
        }
    }

    @Test("Genuine cipher/protocol failure → cipherMismatch")
    func testGenuineCipherMismatch() {
        guard case .cipherMismatch = MongoDBSSLClassifier.classifySSLError("TLS handshake failed: sslv3 alert handshake failure: no shared cipher") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Certificate verify failure → untrustedCertificate")
    func testCertificateVerifyFailed() {
        guard case .untrustedCertificate = MongoDBSSLClassifier.classifySSLError("TLS handshake failed: certificate verify failed") else {
            Issue.record("Expected untrustedCertificate")
            return
        }
    }

    @Test("Hostname verification failure → hostnameMismatch")
    func testHostnameVerification() {
        guard case .hostnameMismatch = MongoDBSSLClassifier.classifySSLError("hostname verification failed") else {
            Issue.record("Expected hostnameMismatch")
            return
        }
    }

    @Test("TLS required → serverRejectedPlaintext")
    func testTLSRequired() {
        guard case .serverRejectedPlaintext = MongoDBSSLClassifier.classifySSLError("TLS required by Atlas cluster") else {
            Issue.record("Expected serverRejectedPlaintext")
            return
        }
    }
}

@Suite("Redis SSL Classifier")
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

@Suite("Oracle SSL Classifier")
struct OracleClassifierTests {
    @Test("ORA-29024 → cipherMismatch")
    func testORA29024() {
        guard case .cipherMismatch = OracleSSLClassifier.classifySSLError("ORA-29024: Certificate validation failure") else {
            Issue.record("Expected cipherMismatch")
            return
        }
    }

    @Test("Network timeout (ORA-12606) is not classified as SSL")
    func testTimeoutNotSSL() {
        #expect(OracleSSLClassifier.classifySSLError("ORA-12606: TNS: Application timeout occurred") == nil)
    }

    @Test("ORA-28759 → clientCertRequired")
    func testORA28759() {
        guard case .clientCertRequired = OracleSSLClassifier.classifySSLError("ORA-28759: failure to open file") else {
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
        let error = URLError(.notConnectedToInternet)
        #expect(ClickHouseSSLClassifier.classifySSLError(error) == nil)
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
        #expect(CassandraClientKeyClassifier.isEncryptedPrivateKey(encryptedPkcs8))
        #expect(CassandraClientKeyClassifier.isEncryptedPrivateKey(encryptedPkcs1))
        #expect(!CassandraClientKeyClassifier.isEncryptedPrivateKey(unencryptedPkcs8))
    }

    @Test("Encrypted key with no passphrase → clientKeyPassphraseRequired")
    func testEncryptedNoPassphrase() {
        let error = CassandraClientKeyClassifier.privateKeyLoadError(
            keyPEM: encryptedPkcs8, hasPassphrase: false, keyPath: "/k.pem")
        guard case .clientKeyPassphraseRequired = error else {
            Issue.record("Expected clientKeyPassphraseRequired")
            return
        }
    }

    @Test("Encrypted key with wrong passphrase → clientKeyPassphraseIncorrect")
    func testEncryptedWrongPassphrase() {
        let error = CassandraClientKeyClassifier.privateKeyLoadError(
            keyPEM: encryptedPkcs1, hasPassphrase: true, keyPath: "/k.pem")
        guard case .clientKeyPassphraseIncorrect = error else {
            Issue.record("Expected clientKeyPassphraseIncorrect")
            return
        }
    }

    @Test("Unencrypted but unreadable key → clientKeyInvalid, never a passphrase error")
    func testUnencryptedInvalid() {
        let withoutPassphrase = CassandraClientKeyClassifier.privateKeyLoadError(
            keyPEM: unencryptedPkcs8, hasPassphrase: false, keyPath: "/k.pem")
        let withPassphrase = CassandraClientKeyClassifier.privateKeyLoadError(
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
