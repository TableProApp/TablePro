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
        .certificateAuthorityRequired,
        .listenerRedirectFailed(.throughTunnel, target: "10.0.0.12:1521"),
        .listenerRedirectFailed(.unreadable, target: nil),
        .listenerRedirectFailed(.needsTLS, target: "node1:2484"),
        .listenerRedirectFailed(.tooManyRedirects, target: "node2:1521"),
        .listenerRedirectFailed(.tooManyRedirects, target: nil),
        .listenerRedirectFailed(.unreachable(detail: "Connection refused"), target: "node1-vip:1521"),
        .listenerRedirectFailed(.unreachable(detail: nil), target: "node1-vip:1521"),
        .listenerRedirectFailed(.refused(detail: "The listener does not know the requested service name (ORA-12514)."), target: "node1:1521"),
        .connectionRefused
    ]

    @Test func testNoMessageLeaksTheDriversOwnErrorStruct() {
        for error in cases {
            let message = error.errorDescription ?? ""
            #expect(!(message.contains("OracleSQLError(")), "\(message)")
            #expect(!message.contains("triggeredFromRequestInFile"), "\(message)")
            #expect(!message.contains("OracleRedirectError"), "\(message)")
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

    // Under a tunnel the target is the one fact the user needs: it is the host to enter instead.
    @Test func testEveryRedirectFailureNamesWhereTheListenerSentTheConnection() {
        let failures: [OracleRedirectFailure] = [
            .throughTunnel, .needsTLS, .tooManyRedirects, .unreachable(detail: "Connection refused"), .unreachable(detail: nil),
            .refused(detail: "ORA-12514")
        ]
        for failure in failures {
            let message = OracleCoreError.listenerRedirectFailed(failure, target: "node1-vip:1521").errorDescription ?? ""
            #expect(message.contains("node1-vip:1521"), "\(message)")
        }
        let unreachable = OracleCoreError.listenerRedirectFailed(
            .unreachable(detail: "Connection refused"), target: "node1-vip:1521"
        ).errorDescription ?? ""
        #expect(unreachable.contains("Connection refused"), "\(unreachable)")
    }

    @Test func testADriverErrorWithNoServerMessageNamesItsCode() {
        let message = String(format: OracleCoreError.driverErrorFormat, "malformedStatement")
        #expect(message.contains("malformedStatement"), "\(message)")
        #expect(!(message.contains("OracleSQLError(")), "\(message)")
    }
}
