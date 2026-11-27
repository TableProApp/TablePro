import Foundation
import Network
import NIOCore
import NIOSSL
import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleConnectFailureMappingTests {
    @Test func aRedirectNamesItsTargetForEachReason() {
        #expect(
            OracleConnectFailureMapping.redirectError(OracleRedirectError(reason: .notFollowed, host: "10.0.0.12", port: 1_521))
                == .listenerRedirectFailed(.throughTunnel, target: "10.0.0.12:1521")
        )
        #expect(
            OracleConnectFailureMapping.redirectError(OracleRedirectError(reason: .transportMismatch, host: "node1", port: 2_484))
                == .listenerRedirectFailed(.needsTLS, target: "node1:2484")
        )
        #expect(
            OracleConnectFailureMapping.redirectError(OracleRedirectError(reason: .tooManyRedirects, host: "node2", port: 1_521))
                == .listenerRedirectFailed(.tooManyRedirects, target: "node2:1521")
        )
        #expect(
            OracleConnectFailureMapping.redirectError(OracleRedirectError(reason: .unreadable, host: nil, port: nil))
                == .listenerRedirectFailed(.unreadable, target: nil)
        )
        #expect(
            OracleConnectFailureMapping.redirectError(OracleRedirectError(reason: .notFollowed, host: "fe80::1", port: 1_521))
                == .listenerRedirectFailed(.throughTunnel, target: "[fe80::1]:1521")
        )
    }

    @Test func anUnreachableTargetSaysWhy() {
        let error = OracleRedirectError(
            reason: .targetUnreachable, host: "node1-vip", port: 1_521, underlying: NWError.posix(.ECONNREFUSED)
        )
        #expect(
            OracleConnectFailureMapping.redirectError(error)
                == .listenerRedirectFailed(.unreachable(detail: "Connection refused"), target: "node1-vip:1521")
        )
    }

    @Test func aRefusalAtTheTargetSaysWhereAndWhy() {
        let error = OracleRedirectError(
            reason: .targetRefused, host: "node1", port: 1_521,
            underlying: OracleListenerRefusedError(code: 12_514, message: "(DESCRIPTION=(ERR=12514))")
        )
        #expect(
            OracleConnectFailureMapping.redirectError(error)
                == .listenerRedirectFailed(.refused(detail: OracleListenerRefusal.detail(code: 12_514)), target: "node1:1521")
        )
    }

    private let certificateFailure = NIOSSLError.handshakeFailed(.wantCertificateVerify)

    @Test func aTLSFailureIsStillReadFromTheUnderlyingError() {
        let text = String(describing: certificateFailure)
        let direct = OracleConnectFailureMapping.connectError(
            code: "connectionError", underlying: certificateFailure, serverMessage: nil, phase: "connect",
            nativeNetworkEncryptionEnabled: true
        )
        #expect(direct == .tlsHandshakeFailed(kind: .untrustedCertificate, serverMessage: text))
        let atTheTarget = OracleConnectFailureMapping.connectError(
            code: "connectionError",
            underlying: OracleRedirectError(
                reason: .targetUnreachable, host: "node1", port: 2_484, underlying: certificateFailure
            ),
            serverMessage: nil, phase: "connect", nativeNetworkEncryptionEnabled: true
        )
        #expect(atTheTarget == .tlsHandshakeFailed(kind: .untrustedCertificate, serverMessage: text))
    }

    // A listener's REFUSE text is the listener's to write, and it echoes the client's CID.
    @Test func aCraftedRefusalCannotSurfaceThroughTheTLSCheck() {
        let refusal = OracleListenerRefusedError(
            code: 12_514,
            message: "(DESCRIPTION=(ERR=12514)(CID=(HOST=dats-mac)(USER=dat))) ORA-29024 certificate verify untrusted"
        )
        let expected = OracleCoreError.connectionFailed(OracleListenerRefusal.detail(code: 12_514))
        #expect(
            OracleConnectFailureMapping.connectError(
                code: "connectionError", underlying: refusal, serverMessage: nil, phase: "connect",
                nativeNetworkEncryptionEnabled: true
            ) == expected
        )
        let atTheTarget = OracleConnectFailureMapping.connectError(
            code: "connectionError",
            underlying: OracleRedirectError(reason: .targetRefused, host: "node1", port: 1_521, underlying: refusal),
            serverMessage: nil, phase: "connect", nativeNetworkEncryptionEnabled: true
        )
        #expect(!(atTheTarget.errorDescription ?? "").contains("USER=dat"))
        #expect(!(atTheTarget.errorDescription ?? "").contains("dats-mac"))
    }

    private struct LoginPacketDump: Error {
        var payload = "AUTH_SESSKEY 0011223344"
    }

    @Test func aDriverStructNeverReachesTheMessage() {
        let error = OracleConnectFailureMapping.connectError(
            code: "missingParameter", underlying: LoginPacketDump(), serverMessage: nil, phase: "authentication",
            nativeNetworkEncryptionEnabled: true
        )
        #expect(error == .connectionFailed(String(format: OracleCoreError.driverErrorFormat, "missingParameter")))
    }

    @Test func aRedirectTheDriverDidNotFollowIsNotAStructDump() {
        let error = OracleConnectFailureMapping.connectError(
            code: "connectionError",
            underlying: OracleRedirectError(reason: .notFollowed, host: "10.0.0.12", port: 1_521),
            serverMessage: nil, phase: "connect", nativeNetworkEncryptionEnabled: true
        )
        #expect(error == .listenerRedirectFailed(.throughTunnel, target: "10.0.0.12:1521"))
        #expect(!(error.errorDescription ?? "").contains("OracleRedirectError"))
    }

    @Test func aResetDuringTheHandshakeReadsAsText() {
        let error = OracleConnectFailureMapping.connectError(
            code: "connectionError", underlying: NWError.posix(.ECONNRESET), serverMessage: nil, phase: "connect",
            nativeNetworkEncryptionEnabled: false
        )
        #expect(error == .connectionFailed("Connection reset by peer"))
    }

    @Test func aRefusedPortIsSaidInWords() {
        #expect(OracleConnectFailureMapping.transportError(NWError.posix(.ECONNREFUSED)) == .connectionRefused)
        #expect(OracleConnectFailureMapping.transportError(IOError(errnoCode: ECONNREFUSED, reason: "connect")) == .connectionRefused)
    }

    @Test func otherTransportFailuresReadAsText() {
        #expect(
            OracleConnectFailureMapping.transportError(ChannelError.connectTimeout(.seconds(10)))
                == .connectionFailed("no answer within 10 seconds")
        )
        #expect(
            OracleConnectFailureMapping.transportError(NWError.posix(.EHOSTUNREACH)) == .connectionFailed("No route to host")
        )
        #expect(
            OracleConnectFailureMapping.transportError(NWError.dns(-65_554))
                == .connectionFailed("the host name could not be resolved")
        )
    }

    private struct SomethingElse: Error {
        var secret = "AUTH_SESSKEY"
    }

    @Test func anUnknownFailureNamesItsTypeAndNothingInside() {
        guard case .connectionFailed(let detail) = OracleConnectFailureMapping.transportError(SomethingElse()) else {
            Issue.record("expected connectionFailed")
            return
        }
        #expect(detail.contains("SomethingElse"), "\(detail)")
        #expect(!detail.contains("AUTH_SESSKEY"), "\(detail)")
    }

    @Test func theConfigurationCarriesWhetherToFollowRedirects() throws {
        let direct = try OracleCoreConnection.configuration(for: OracleConnectionOptions(
            host: "scan.example.com", user: "scott", password: "tiger"
        ))
        #expect(direct.followsListenerRedirects)
        let tunneled = try OracleCoreConnection.configuration(for: OracleConnectionOptions(
            host: "127.0.0.1", user: "scott", password: "tiger", followsListenerRedirects: false
        ))
        #expect(!tunneled.followsListenerRedirects)
    }
}
