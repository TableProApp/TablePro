@testable import TableProOracleCore
import XCTest

/// OracleNIO documents its own errors as unfit to show: "These errors should not be forwareded to
/// the end user, as they may leak sensitive information." One reached an alert as
/// `OracleSQLError(code: clientClosedConnection, triggeredFromRequestInFile: ...)`.
final class OracleCoreErrorMessageTests: XCTestCase {
    private let cases: [OracleCoreError] = [
        .notConnected,
        .connectionFailed("listener refused the connection"),
        .queryFailed("ORA-00942: table or view does not exist"),
        .cancelled,
        .connectionClosed,
        .protocolError,
        .loginTimedOut,
        .queryTimedOut,
        .transactionLost,
        .authVerifierUnsupported(flag: "unsupportedVerifierType(0x939)"),
        .authVersionNotSupported,
        .authConnectionDropped(phase: "authentication"),
        .loginHandshakeStalled(phase: "connect"),
        .nativeEncryptionFailed(detail: "checksum mismatch"),
        .nativeEncryptionRequired,
        .tlsHandshakeFailed(kind: .cipherMismatch, serverMessage: "ORA-29024"),
        .certificateUnavailable(field: .clientKey, path: "/tmp/key.pem")
    ]

    func testNoMessageLeaksTheDriversOwnErrorStruct() {
        for error in cases {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.contains("OracleSQLError("), message)
            XCTAssertFalse(message.contains("triggeredFromRequestInFile"), message)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testAClosedChannelSaysSoAndSaysWhatToDo() {
        let message = OracleCoreError.connectionClosed.errorDescription ?? ""
        XCTAssertTrue(message.contains("closed"), message)
        XCTAssertTrue(message.contains("again"), message)
    }

    func testADriverErrorWithNoServerMessageNamesItsCode() {
        let message = String(format: OracleCoreError.driverErrorFormat, "malformedStatement")
        XCTAssertTrue(message.contains("malformedStatement"), message)
        XCTAssertFalse(message.contains("OracleSQLError("), message)
    }
}
