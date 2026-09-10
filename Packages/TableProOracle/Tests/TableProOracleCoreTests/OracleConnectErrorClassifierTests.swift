import XCTest
@testable import TableProOracleCore

final class OracleConnectErrorClassifierTests: XCTestCase {
    func testVerifierPrefixIsClassifiedWithItsFlag() {
        let failure = OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x12)")
        XCTAssertEqual(failure, .verifierUnsupported(flag: "unsupportedVerifierType(0x12)"))
    }

    func testKnownCodesMapToTheirFailures() {
        XCTAssertEqual(OracleConnectErrorClassifier.classify("uncleanShutdown"), .connectionDropped)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("serverVersionNotSupported"), .versionNotSupported)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("advancedNegotiationFailed"), .advancedNegotiationFailed)
    }

    func testUnknownCodeFallsBackToConnectionFailed() {
        XCTAssertEqual(OracleConnectErrorClassifier.classify("somethingElse"), .connectionFailed)
    }

    func testAdvancedNegotiationIsAlwaysANativeEncryptionSignal() {
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationFailed,
            nativeNetworkEncryptionEnabled: true,
            timedOut: false
        ))
    }

    func testDroppedConnectionCountsOnlyWhenItTimedOut() {
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped,
            nativeNetworkEncryptionEnabled: true,
            timedOut: false
        ))
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped,
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
    }

    func testAuthFailuresAreNeverEncryptionFailures() {
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .versionNotSupported,
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .verifierUnsupported(flag: "x"),
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
    }

    func testNothingCountsWhenEncryptionIsDisabled() {
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationFailed,
            nativeNetworkEncryptionEnabled: false,
            timedOut: true
        ))
    }

    func testChannelFatalCodesResetTheConnection() {
        XCTAssertTrue(OracleChannelFatalCode.isChannelFatal("connectionError"))
        XCTAssertTrue(OracleChannelFatalCode.isChannelFatal("messageDecodingFailure"))
        XCTAssertTrue(OracleChannelFatalCode.isChannelFatal("unexpectedBackendMessage"))
        XCTAssertFalse(OracleChannelFatalCode.isChannelFatal("statementError"))
    }

    func testTLSClassifierRecognizesOracleWalletAndCipherErrors() {
        XCTAssertEqual(OracleSSLClassifier.classifyTLSFailure("ORA-28759: failure to open file"), .clientCertRequired)
        XCTAssertEqual(OracleSSLClassifier.classifyTLSFailure("ORA-29024: Certificate validation failure"), .cipherMismatch)
        XCTAssertEqual(OracleSSLClassifier.classifyTLSFailure("ORA-28860: Fatal SSL error"), .cipherMismatch)
        XCTAssertEqual(
            OracleSSLClassifier.classifyTLSFailure("certificate verify failed: untrusted root"),
            .untrustedCertificate
        )
        XCTAssertNil(OracleSSLClassifier.classifyTLSFailure("connection reset by peer"))
    }
}
