@testable import TableProOracleCore
import XCTest

final class OracleConnectErrorClassifierTests: XCTestCase {
    func testVerifierPrefixIsClassifiedWithItsFlag() {
        let failure = OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x12)")
        XCTAssertEqual(failure, .verifierUnsupported(flag: "unsupportedVerifierType(0x12)"))
    }

    func testKnownCodesMapToTheirFailures() {
        XCTAssertEqual(OracleConnectErrorClassifier.classify("uncleanShutdown"), .connectionDropped)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("serverVersionNotSupported"), .versionNotSupported)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("advancedNegotiationFailed"), .advancedNegotiationFailed)
        XCTAssertEqual(
            OracleConnectErrorClassifier.classify("advancedNegotiationRequired"),
            .advancedNegotiationRequired
        )
        XCTAssertEqual(
            OracleConnectErrorClassifier.classify("loginHandshakeTimedOut"),
            .loginHandshakeTimedOut
        )
    }

    func testStalledLoginIsNotBlamedOnEncryption() {
        XCTAssertFalse(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .loginHandshakeTimedOut,
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
    }

    func testRequiredNegotiationIsAnEncryptionSignal() {
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationRequired,
            nativeNetworkEncryptionEnabled: true,
            timedOut: false
        ))
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

    /// The table mirrors OracleNIO's own `ConnectionStateMachine.shouldCloseConnection(reason:)`,
    /// which is internal and so cannot be called. Every case it names is pinned here.
    func testChannelFatalTableMirrorsOracleNIO() {
        for code in [
            "clientClosesConnection",
            "clientClosedConnection",
            "failedToAddSSLHandler",
            "failedToVerifyTLSCertificates",
            "connectionError",
            "messageDecodingFailure",
            "missingParameter",
            "unexpectedBackendMessage",
            "serverVersionNotSupported",
            "sidNotSupported",
            "uncleanShutdown",
            "unsupportedDataType",
            "unsupportedVerifierType(0x939)",
            "advancedNegotiationFailed",
            "advancedNegotiationRequired",
            "loginHandshakeTimedOut"
        ] {
            XCTAssertTrue(OracleChannelFatalCode.isChannelFatal(code), code)
        }

        for code in ["statementCancelled", "nationalCharsetNotSupported", "missingStatement", "malformedStatement"] {
            XCTAssertFalse(OracleChannelFatalCode.isChannelFatal(code), code)
        }
    }

    /// ORA-28 is the session being killed and ORA-600 an internal error; OracleNIO closes the
    /// channel on both and on no other server error.
    func testServerErrorsAreFatalOnlyForKilledSessions() {
        XCTAssertTrue(OracleChannelFatalCode.isChannelFatal("server", serverErrorNumber: 28))
        XCTAssertTrue(OracleChannelFatalCode.isChannelFatal("server", serverErrorNumber: 600))
        XCTAssertFalse(OracleChannelFatalCode.isChannelFatal("server", serverErrorNumber: 942))
        XCTAssertFalse(OracleChannelFatalCode.isChannelFatal("server"))
    }

    /// A lost socket must not be reported as the server sending something the driver could not
    /// read: `uncleanShutdown` and `connectionError` are the transport going away, and
    /// `OracleConnectErrorClassifier` already calls the first of them a dropped connection.
    func testClosuresAreToldApartByWhatTookTheChannel() {
        XCTAssertEqual(OracleChannelFatalCode.closureKind("clientClosedConnection"), .clientClose)
        XCTAssertEqual(OracleChannelFatalCode.closureKind("clientClosesConnection"), .clientClose)
        XCTAssertEqual(OracleChannelFatalCode.closureKind("uncleanShutdown"), .transportLoss)
        XCTAssertEqual(OracleChannelFatalCode.closureKind("connectionError"), .transportLoss)
        XCTAssertEqual(OracleChannelFatalCode.closureKind("messageDecodingFailure"), .protocolFailure)
        XCTAssertEqual(OracleChannelFatalCode.closureKind("unexpectedBackendMessage"), .protocolFailure)
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
