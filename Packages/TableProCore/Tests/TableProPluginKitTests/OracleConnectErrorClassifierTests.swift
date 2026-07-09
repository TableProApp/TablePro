import XCTest
@testable import TableProPluginKit

final class OracleConnectErrorClassifierTests: XCTestCase {
    func testClassifyKnownCodes() {
        XCTAssertEqual(OracleConnectErrorClassifier.classify("uncleanShutdown"), .connectionDropped)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("serverVersionNotSupported"), .versionNotSupported)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("advancedNegotiationFailed"), .advancedNegotiationFailed)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("somethingElse"), .connectionFailed)
        XCTAssertEqual(
            OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x12)"),
            .verifierUnsupported(flag: "unsupportedVerifierType(0x12)")
        )
    }

    func testAdvancedNegotiationFailureIsEncryptionFailure() {
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationFailed, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
    }

    func testEncryptionFailureRequiresEncryptionEnabled() {
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionFailed, nativeNetworkEncryptionEnabled: false, timedOut: true
        ))
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped, nativeNetworkEncryptionEnabled: false, timedOut: false
        ))
    }

    func testTimeoutWithEncryptionIsEncryptionFailure() {
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionFailed, nativeNetworkEncryptionEnabled: true, timedOut: true
        ))
    }

    func testHandshakeDropWithoutTimeoutIsNotEncryptionFailure() {
        // With encryption always offered at ACCEPTED, a plain handshake drop is
        // ambiguous (firewall, required-encryption server that RSTs, etc.), so it is
        // not auto-classified. Only a stalled (timed out) handshake or an explicit
        // advancedNegotiationFailed counts.
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionFailed, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
    }

    func testAuthErrorsAreNotEncryptionFailures() {
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .verifierUnsupported(flag: "x"), nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .versionNotSupported, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
    }
}
