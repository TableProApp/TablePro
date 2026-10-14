import Foundation
@testable import TableProPluginKit
import Testing

struct OracleConnectErrorClassifierTests {
    @Test func testClassifyKnownCodes() {
        #expect(OracleConnectErrorClassifier.classify("uncleanShutdown") == .connectionDropped)
        #expect(OracleConnectErrorClassifier.classify("serverVersionNotSupported") == .versionNotSupported)
        #expect(OracleConnectErrorClassifier.classify("advancedNegotiationFailed") == .advancedNegotiationFailed)
        #expect(OracleConnectErrorClassifier.classify("somethingElse") == .connectionFailed)
        #expect(OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x12)") == .verifierUnsupported(flag: "unsupportedVerifierType(0x12)"))
    }

    @Test func testAdvancedNegotiationFailureIsEncryptionFailure() {
        #expect(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .advancedNegotiationFailed, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
    }

    @Test func testEncryptionFailureRequiresEncryptionEnabled() {
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionFailed, nativeNetworkEncryptionEnabled: false, timedOut: true
        ))
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped, nativeNetworkEncryptionEnabled: false, timedOut: false
        ))
    }

    @Test func testTimeoutWithEncryptionIsEncryptionFailure() {
        #expect(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionFailed, nativeNetworkEncryptionEnabled: true, timedOut: true
        ))
    }

    @Test func testHandshakeDropWithoutTimeoutIsNotEncryptionFailure() {
        // With encryption always offered at ACCEPTED, a plain handshake drop is
        // ambiguous (firewall, required-encryption server that RSTs, etc.), so it is
        // not auto-classified. Only a stalled (timed out) handshake or an explicit
        // advancedNegotiationFailed counts.
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionFailed, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
    }

    @Test func testAuthErrorsAreNotEncryptionFailures() {
        #expect(!(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .verifierUnsupported(flag: "x"), nativeNetworkEncryptionEnabled: true, timedOut: false
        )))
        #expect(!OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .versionNotSupported, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
    }
}
