import Foundation
@testable import TableProOracleCore
import Testing

/// OracleNIO documents its own errors as unfit to show: "These errors should not be forwareded to
/// the end user, as they may leak sensitive information." One reached an alert as
/// `OracleSQLError(code: clientClosedConnection, triggeredFromRequestInFile: ...)`.
struct OracleCoreErrorMessageTests {
    private let cases: [OracleCoreError] = [
        .notConnected,
        .connectionFailed("listener refused the connection"),
        .queryFailed("ORA-00942: table or view does not exist"),
        .cancelled,
        .connectionClosed,
        .protocolError,
        .loginTimedOut,
        .connectTimedOut,
        .queryTimedOut,
        .transactionLost,
        .authVerifierUnsupported(flag: "unsupportedVerifierType(0x939)"),
        .authVersionNotSupported,
        .authConnectionDropped(phase: "authentication"),
        .loginHandshakeStalled(phase: "connect"),
        .nativeEncryptionFailed(detail: "checksum mismatch"),
        .nativeEncryptionRequired,
        .tlsHandshakeFailed(kind: .cipherMismatch, serverMessage: "ORA-29024"),
        .certificateUnavailable(field: .clientKey, path: "/tmp/key.pem"),
        .certificateAuthorityRequired
    ]

    @Test func testNoMessageLeaksTheDriversOwnErrorStruct() {
        for error in cases {
            let message = error.errorDescription ?? ""
            #expect(!(message.contains("OracleSQLError(")), "\(message)")
            #expect(!message.contains("triggeredFromRequestInFile"), "\(message)")
            #expect(!message.isEmpty)
        }
    }

    @Test func testAClosedChannelSaysSoAndSaysWhatToDo() {
        let message = OracleCoreError.connectionClosed.errorDescription ?? ""
        #expect(message.contains("closed"), "\(message)")
        #expect(message.contains("again"), "\(message)")
    }

    @Test func testTheMissingCARefusalNamesNoScreenOnlyOnePlatformHas() {
        let message = OracleCoreError.certificateAuthorityRequired.errorDescription ?? ""
        #expect(message.contains("CA certificate"), "\(message)")
        #expect(!message.localizedCaseInsensitiveContains("tab"), "\(message)")
    }

    @Test func testADriverErrorWithNoServerMessageNamesItsCode() {
        let message = String(format: OracleCoreError.driverErrorFormat, "malformedStatement")
        #expect(message.contains("malformedStatement"), "\(message)")
        #expect(!(message.contains("OracleSQLError(")), "\(message)")
    }
}
