@testable import TableProTeradataCore
import XCTest

final class TeradataTLSTests: XCTestCase {
    func testDisabledOptionsDoNotEnableTLS() {
        XCTAssertFalse(TeradataTLSOptions.disabled.enabled)
        XCTAssertFalse(TeradataTLSOptions.disabled.verifiesCertificate)
    }

    func testClientAttributesEmbedSSLMode() throws {
        let parcel = TeradataMessages.clientAttributesParcel(
            username: "u", session: 1, charset: 0xBF, serverIP: "10.0.0.1",
            logMech: "TD2", transactionMode: "ANSI", sslMode: "REQUIRE", database: "db")
        let body = try XCTUnwrap(String(bytes: parcel.body, encoding: .isoLatin1))
        XCTAssertTrue(body.contains("SSLM=REQUIRE"), "attributes must carry the negotiated SSL mode")
        XCTAssertTrue(body.contains("LM=TD2"))
        XCTAssertTrue(body.contains("TM=ANSI"))
    }

    func testVerifyCAWithoutACARefusesTheTrustPolicy() {
        for path in ["", "   "] {
            let options = verifyingOptions(hostname: false, caCertificatePath: path)
            assertRefusal(containing: "no CA certificate") {
                _ = try TeradataTLSTransport.trustPolicy(for: options, host: "db.example.com")
            }
        }
    }

    func testVerifyCAWithoutACARefusesBeforeOpeningASocket() {
        let options = verifyingOptions(hostname: false, caCertificatePath: "")
        assertRefusal(containing: "no CA certificate") {
            _ = try TeradataTLSTransport(host: "127.0.0.1", options: options, timeoutSeconds: 5)
        }
    }

    func testUnreadableCAFileRefusesInBothVerifyModes() throws {
        let notACertificate = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-teradata-not-a-certificate-\(UUID().uuidString).pem")
        try Data("not a certificate".utf8).write(to: notACertificate)
        defer { try? FileManager.default.removeItem(at: notACertificate) }

        for path in ["/nonexistent/tablepro-teradata-tests/ca.pem", notACertificate.path] {
            for verifiesHostname in [false, true] {
                let options = verifyingOptions(hostname: verifiesHostname, caCertificatePath: path)
                assertRefusal(containing: "could not be read") {
                    _ = try TeradataTLSTransport.trustPolicy(for: options, host: "db.example.com")
                }
            }
        }
    }

    func testUnreadableCAFileRefusesBeforeOpeningASocket() {
        let options = verifyingOptions(hostname: true, caCertificatePath: "/nonexistent/tablepro-teradata-tests/ca.pem")
        assertRefusal(containing: "could not be read") {
            _ = try TeradataTLSTransport(host: "127.0.0.1", options: options, timeoutSeconds: 5)
        }
    }

    func testVerifyIdentityWithoutACAChecksTheSystemTrustStoreAndTheHostname() throws {
        let options = verifyingOptions(hostname: true, caCertificatePath: "")
        let policy = try TeradataTLSTransport.trustPolicy(for: options, host: "db.example.com")
        guard case .systemTrust(let hostname) = policy else {
            return XCTFail("expected the system trust store, got \(policy)")
        }
        XCTAssertEqual(hostname, "db.example.com")
    }

    func testReadableCAFileAnchorsBothVerifyModes() throws {
        let caFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-teradata-ca-\(UUID().uuidString).pem")
        try Data(Self.testAuthorityPEM.utf8).write(to: caFile)
        defer { try? FileManager.default.removeItem(at: caFile) }

        let verifyCA = try TeradataTLSTransport.trustPolicy(
            for: verifyingOptions(hostname: false, caCertificatePath: caFile.path), host: "db.example.com")
        guard case .anchors(let caAnchors, let caHostname) = verifyCA else {
            return XCTFail("expected the CA file as the only anchor, got \(verifyCA)")
        }
        XCTAssertEqual(caAnchors.count, 1)
        XCTAssertNil(caHostname)

        let verifyIdentity = try TeradataTLSTransport.trustPolicy(
            for: verifyingOptions(hostname: true, caCertificatePath: caFile.path), host: "db.example.com")
        guard case .anchors(let identityAnchors, let identityHostname) = verifyIdentity else {
            return XCTFail("expected the CA file as the only anchor, got \(verifyIdentity)")
        }
        XCTAssertEqual(identityAnchors.count, 1)
        XCTAssertEqual(identityHostname, "db.example.com")
    }

    func testRequiredModeNeverReadsTheCAFile() throws {
        let options = TeradataTLSOptions(
            enabled: true, caCertificatePath: "/nonexistent/tablepro-teradata-tests/ca.pem", modeLabel: "REQUIRE")
        let policy = try TeradataTLSTransport.trustPolicy(for: options, host: "db.example.com")
        guard case .acceptAny = policy else {
            return XCTFail("expected no certificate check, got \(policy)")
        }
    }

    func testPlaintextConnectIgnoresTLSFallbackFlag() {
        let config = TeradataConnectionConfig(
            host: "127.0.0.1", port: 9, username: "u", password: "p",
            tls: TeradataTLSOptions(enabled: false, allowPlaintextFallback: true),
            connectTimeoutSeconds: 1)
        XCTAssertThrowsError(try TeradataConnection(config: config).connect()) { error in
            guard case TeradataWireError.connectionFailed = error else {
                if case TeradataWireError.truncated = error { return }
                return XCTFail("expected a transport error, got \(error)")
            }
        }
    }

    private static let testAuthorityPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBJzCBzgIJAMLYxH2Rh5LAMAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEFRhYmxl
        UHJvIFRlc3QgQ0EwIBcNMjYwOTI4MTUwMDE2WhgPMjEyNjA5MDQxNTAwMTZaMBsx
        GTAXBgNVBAMMEFRhYmxlUHJvIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMB
        BwNCAATJmp4qF8ZPLELdv7zhRF+UgFduM9tQS5IR2CV3lcsn7mqhM2pOB7AULRWY
        lLOmxbRu13doRzengY46xrjP2qucMAoGCCqGSM49BAMCA0gAMEUCIQDaf/ow8D8x
        nBCmT33zqUHRFbg3uZyuI62VfVapXunZzgIgN5lVItMifnoHMg8Ls8eqf5TkK13C
        zKfWtkCRv0GhTSQ=
        -----END CERTIFICATE-----
        """

    private func verifyingOptions(hostname: Bool, caCertificatePath: String) -> TeradataTLSOptions {
        TeradataTLSOptions(
            enabled: true,
            verifiesCertificate: true,
            verifiesHostname: hostname,
            caCertificatePath: caCertificatePath,
            modeLabel: hostname ? "VERIFY-FULL" : "VERIFY-CA")
    }

    private func assertRefusal(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case TeradataWireError.connectionFailed(let detail) = error else {
                return XCTFail("expected a refusal, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(detail.contains(fragment), detail, file: file, line: line)
        }
    }
}
