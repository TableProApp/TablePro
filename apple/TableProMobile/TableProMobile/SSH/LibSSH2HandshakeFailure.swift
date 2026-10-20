import CLibSSH2
import Foundation
import TableProSSHTransport

// Runs on the failed session before libssh2_session_free, which drops what the negotiation agreed.
nonisolated enum LibSSH2HandshakeFailure {
    static func error(session: OpaquePointer, rc: Int32) -> SSHTunnelError {
        // libssh2_session_methods overwrites the last error when a method is missing, so it is read first.
        let detail = lastError(session)

        switch rc {
        case LIBSSH2_ERROR_KEX_FAILURE:
            return .negotiationFailed(negotiation(session))
        case LIBSSH2_ERROR_TIMEOUT:
            // libssh2 says "Timed out waiting on socket", which reads as blocked Local Network access,
            // but the TCP connect already succeeded.
            return .handshakeFailed(String(localized: "The SSH server did not answer in time."))
        default:
            return .handshakeFailed(detail ?? "Handshake failed (error \(rc))")
        }
    }

    private static func negotiation(_ session: OpaquePointer) -> SSHNegotiationFailure {
        let stage = SSHNegotiationFailure.stage(
            kex: method(session, LIBSSH2_METHOD_KEX),
            cipher: agreed(session, LIBSSH2_METHOD_CRYPT_CS, LIBSSH2_METHOD_CRYPT_SC),
            mac: agreed(session, LIBSSH2_METHOD_MAC_CS, LIBSSH2_METHOD_MAC_SC)
        )

        var supported: [String] = []
        var supportedHostKeys: [String] = []
        switch stage {
        case .keyExchangeOrHostKey:
            supported = SSHNegotiationFailure.clientMethods(algorithms(session, LIBSSH2_METHOD_KEX))
            supportedHostKeys = algorithms(session, LIBSSH2_METHOD_HOSTKEY)
        case .cipher:
            supported = algorithms(session, LIBSSH2_METHOD_CRYPT_CS)
        case .mac:
            supported = algorithms(session, LIBSSH2_METHOD_MAC_CS)
        case .undetermined:
            break
        }

        return SSHNegotiationFailure(
            stage: stage,
            serverSoftware: SSHNegotiationFailure.serverSoftware(banner: banner(session)),
            supported: supported,
            supportedHostKeys: supportedHostKeys
        )
    }

    // libssh2 agrees each direction on its own, so one side alone is not an agreement.
    private static func agreed(_ session: OpaquePointer, _ clientToServer: Int32, _ serverToClient: Int32) -> String? {
        guard let outgoing = method(session, clientToServer), method(session, serverToClient) != nil else {
            return nil
        }
        return outgoing
    }

    private static func method(_ session: OpaquePointer, _ type: Int32) -> String? {
        guard let name = libssh2_session_methods(session, type) else { return nil }
        return String(cString: name)
    }

    private static func algorithms(_ session: OpaquePointer, _ type: Int32) -> [String] {
        var names: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let count = libssh2_session_supported_algs(session, type, &names)
        guard count > 0, let names else { return [] }
        defer { libssh2_free(session, names) }
        return (0 ..< Int(count)).compactMap { index in names[index].map { String(cString: $0) } }
    }

    private static func banner(_ session: OpaquePointer) -> String? {
        guard let banner = libssh2_session_banner_get(session) else { return nil }
        return String(cString: banner)
    }

    private static func lastError(_ session: OpaquePointer) -> String? {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        guard let message, length > 0 else { return nil }
        return String(cString: message)
    }
}
