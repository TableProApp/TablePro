import XCTest
@testable import TableProPluginKit

final class OracleConnectErrorClassifierTests: XCTestCase {
    func testClassifyKnownCodes() {
        XCTAssertEqual(OracleConnectErrorClassifier.classify("uncleanShutdown"), .connectionDropped)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("serverVersionNotSupported"), .versionNotSupported)
        XCTAssertEqual(OracleConnectErrorClassifier.classify("somethingElse"), .connectionFailed)
        XCTAssertEqual(
            OracleConnectErrorClassifier.classify("unsupportedVerifierType(0x12)"),
            .verifierUnsupported(flag: "unsupportedVerifierType(0x12)")
        )
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

    func testHandshakeDropWithEncryptionIsEncryptionFailure() {
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: .connectionDropped, nativeNetworkEncryptionEnabled: true, timedOut: false
        ))
        XCTAssertTrue(OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
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
