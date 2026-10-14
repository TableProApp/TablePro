import Foundation
@testable import TableProOracleCore
import Testing

struct OracleConnectErrorClassifierTests {
    @Test func testVerifierPrefixIsClassifiedWithItsFlag() {
        let failure = OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x12)")
        #expect(failure == .verifierUnsupported(flag: "unsupportedVerifierType(0x12)"))
    }

    @Test func testKnownCodesMapToTheirFailures() {
        #expect(OracleConnectErrorClassifier.classify("uncleanShutdown") == .connectionDropped)
        #expect(OracleConnectErrorClassifier.classify("serverVersionNotSupported") == .versionNotSupported)
        #expect(OracleConnectErrorClassifier.classify("advancedNegotiationFailed") == .advancedNegotiationFailed)
        #expect(OracleConnectErrorClassifier.classify("advancedNegotiationRequired") == .advancedNegotiationRequired)
        #expect(OracleConnectErrorClassifier.classify("loginHandshakeTimedOut") == .loginHandshakeTimedOut)
    }

    @Test func testStalledLoginIsNotBlamedOnEncryption() {
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .loginHandshakeTimedOut,
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
    }

    @Test func testRequiredNegotiationIsAnEncryptionSignal() {
        #expect(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationRequired,
            nativeNetworkEncryptionEnabled: true,
            timedOut: false
        ))
    }

    @Test func testUnknownCodeFallsBackToConnectionFailed() {
        #expect(OracleConnectErrorClassifier.classify("somethingElse") == .connectionFailed)
    }

    @Test func testAdvancedNegotiationIsAlwaysANativeEncryptionSignal() {
        #expect(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationFailed,
            nativeNetworkEncryptionEnabled: true,
            timedOut: false
        ))
    }

    @Test func testDroppedConnectionCountsOnlyWhenItTimedOut() {
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped,
            nativeNetworkEncryptionEnabled: true,
            timedOut: false
        ))
        #expect(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped,
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
    }

    @Test func testAuthFailuresAreNeverEncryptionFailures() {
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .versionNotSupported,
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        ))
        #expect(!(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .verifierUnsupported(flag: "x"),
            nativeNetworkEncryptionEnabled: true,
            timedOut: true
        )))
    }

    @Test func testNothingCountsWhenEncryptionIsDisabled() {
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationFailed,
            nativeNetworkEncryptionEnabled: false,
            timedOut: true
        ))
    }

    @Test func testChannelFatalCodesResetTheConnection() {
        #expect(OracleChannelFatalCode.isChannelFatal("connectionError"))
        #expect(OracleChannelFatalCode.isChannelFatal("messageDecodingFailure"))
        #expect(OracleChannelFatalCode.isChannelFatal("unexpectedBackendMessage"))
        #expect(!OracleChannelFatalCode.isChannelFatal("statementError"))
    }

    /// The table mirrors OracleNIO's own `ConnectionStateMachine.shouldCloseConnection(reason:)`,
    /// which is internal and so cannot be called. Every case it names is pinned here.
    @Test func testChannelFatalTableMirrorsOracleNIO() {
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
            "loginHandshakeTimedOut",
            "nationalCharsetNotSupported"
        ] {
            #expect(OracleChannelFatalCode.isChannelFatal(code), "\(code)")
        }

        for code in ["statementCancelled", "missingStatement", "malformedStatement"] {
            #expect(!OracleChannelFatalCode.isChannelFatal(code), "\(code)")
        }
    }

    /// ORA-28 is the session being killed and ORA-600 an internal error; OracleNIO closes the
    /// channel on both and on no other server error.
    @Test func testServerErrorsAreFatalOnlyForKilledSessions() {
        #expect(OracleChannelFatalCode.isChannelFatal("server", serverErrorNumber: 28))
        #expect(OracleChannelFatalCode.isChannelFatal("server", serverErrorNumber: 600))
        #expect(!OracleChannelFatalCode.isChannelFatal("server", serverErrorNumber: 942))
        #expect(!OracleChannelFatalCode.isChannelFatal("server"))
    }

    /// A lost socket must not be reported as the server sending something the driver could not
    /// read: `uncleanShutdown` and `connectionError` are the transport going away, and
    /// `OracleConnectErrorClassifier` already calls the first of them a dropped connection.
    @Test func testClosuresAreToldApartByWhatTookTheChannel() {
        #expect(OracleChannelFatalCode.closureKind("clientClosedConnection") == .clientClose)
        #expect(OracleChannelFatalCode.closureKind("clientClosesConnection") == .clientClose)
        #expect(OracleChannelFatalCode.closureKind("uncleanShutdown") == .transportLoss)
        #expect(OracleChannelFatalCode.closureKind("connectionError") == .transportLoss)
        #expect(OracleChannelFatalCode.closureKind("messageDecodingFailure") == .protocolFailure)
        #expect(OracleChannelFatalCode.closureKind("unexpectedBackendMessage") == .protocolFailure)
    }

    @Test func testTLSClassifierRecognizesOracleWalletAndCipherErrors() {
        #expect(OracleSSLClassifier.classifyTLSFailure("ORA-28759: failure to open file") == .clientCertRequired)
        #expect(OracleSSLClassifier.classifyTLSFailure("ORA-29024: Certificate validation failure") == .cipherMismatch)
        #expect(OracleSSLClassifier.classifyTLSFailure("ORA-28860: Fatal SSL error") == .cipherMismatch)
        #expect(OracleSSLClassifier.classifyTLSFailure("certificate verify failed: untrusted root") == .untrustedCertificate)
        #expect(OracleSSLClassifier.classifyTLSFailure("connection reset by peer") == nil)
    }
}
