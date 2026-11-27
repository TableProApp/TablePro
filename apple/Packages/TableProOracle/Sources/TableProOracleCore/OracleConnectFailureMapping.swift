import Foundation
import OracleNIO

// What a failed connect says to the user. The driver's error structs are not for display, as the query path's
// `mapQueryError` says: they can carry this device's host name and OS user, or a login packet in hex.
enum OracleConnectFailureMapping {
    static func connectError(
        code: String,
        underlying: (any Error)?,
        serverMessage: String?,
        phase: String?,
        nativeNetworkEncryptionEnabled: Bool
    ) -> OracleCoreError {
        let detail = failureDetail(code: code, underlying: underlying, serverMessage: serverMessage)
        // BoringSSL's text is what tells an untrusted certificate from a cipher mismatch, and a TLS failure at a
        // redirect's target sits one level further down.
        let nested = (underlying as? OracleRedirectError)?.underlying
        for candidate in [detail] + [underlying, nested].compactMap({ tlsText($0) }) {
            if let kind = OracleSSLClassifier.classifyTLSFailure(candidate) {
                return .tlsHandshakeFailed(kind: kind, serverMessage: candidate)
            }
        }
        if let redirect = underlying as? OracleRedirectError {
            return redirectError(redirect)
        }
        if let underlying, OracleTransportFailure.isConnectionRefused(underlying) {
            return .connectionRefused
        }
        let failure = OracleConnectErrorClassifier.classify(code)
        if case .loginHandshakeTimedOut = failure {
            return .loginHandshakeStalled(phase: phase)
        }
        if case .advancedNegotiationRequired = failure {
            return .nativeEncryptionRequired
        }
        if OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: failure,
            nativeNetworkEncryptionEnabled: nativeNetworkEncryptionEnabled,
            timedOut: false
        ) {
            return .nativeEncryptionFailed(detail: detail)
        }
        switch failure {
        case .verifierUnsupported(let flag):
            return .authVerifierUnsupported(flag: flag)
        case .versionNotSupported:
            return .authVersionNotSupported
        case .connectionDropped:
            return .authConnectionDropped(phase: phase)
        case .advancedNegotiationFailed:
            return .nativeEncryptionFailed(detail: detail)
        case .advancedNegotiationRequired:
            return .nativeEncryptionRequired
        case .loginHandshakeTimedOut:
            return .loginHandshakeStalled(phase: phase)
        case .connectionFailed:
            return .connectionFailed(detail)
        }
    }

    // Only NIOSSL's own errors are read for TLS words. Any other description can hold what a listener sent, such as a
    // REFUSE that echoes this device's host name and OS user next to an ORA-29024.
    static func tlsText(_ error: (any Error)?) -> String? {
        guard let error, String(reflecting: type(of: error)).hasPrefix("NIOSSL.") else { return nil }
        return String(describing: error)
    }

    static func failureDetail(code: String, underlying: (any Error)?, serverMessage: String?) -> String {
        if let refused = underlying as? OracleListenerRefusedError {
            return OracleListenerRefusal.detail(code: refused.code)
        }
        if let serverMessage {
            return serverMessage
        }
        if let underlying {
            if let transport = OracleTransportFailure.detail(underlying) {
                return transport
            }
            // The negotiation's reason is a plain sentence, the one underlying error that is.
            if OracleConnectErrorClassifier.classify(code) == .advancedNegotiationFailed {
                return String(describing: underlying)
            }
        }
        return String(format: OracleCoreError.driverErrorFormat, code)
    }

    static func transportError(_ error: any Error) -> OracleCoreError {
        if OracleTransportFailure.isConnectionRefused(error) {
            return .connectionRefused
        }
        let detail = OracleTransportFailure.detail(error)
            ?? String(format: OracleCoreError.driverErrorFormat, String(describing: type(of: error)))
        return .connectionFailed(detail)
    }

    static func redirectError(_ redirect: OracleRedirectError) -> OracleCoreError {
        let target = redirect.host.map { host -> String in
            let shown = host.contains(":") ? "[\(host)]" : host
            return redirect.port.map { "\(shown):\($0)" } ?? shown
        }
        switch redirect.reason {
        case .notFollowed:
            // Following is turned off only when the dial is a tunnel's forward.
            return .listenerRedirectFailed(.throughTunnel, target: target)
        case .unreadable:
            return .listenerRedirectFailed(.unreadable, target: nil)
        case .transportMismatch:
            return .listenerRedirectFailed(.needsTLS, target: target)
        case .tooManyRedirects:
            return .listenerRedirectFailed(.tooManyRedirects, target: target)
        case .targetUnreachable:
            let detail = redirect.underlying.flatMap(OracleTransportFailure.detail)
            return .listenerRedirectFailed(.unreachable(detail: detail), target: target)
        case .targetRefused:
            let refusal = redirect.underlying as? OracleListenerRefusedError
            return .listenerRedirectFailed(
                .refused(detail: OracleListenerRefusal.detail(code: refusal?.code)), target: target
            )
        }
    }
}
