import Foundation

nonisolated enum SSHTunnelError: Error, LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case handshakeFailed(String)
    case authenticationFailed(String)
    case noAvailablePort
    case channelOpenFailed(String)
    case hostKeyRejected(String)
    case hostKeyUnverified(String)
    case jumpHostsUnsupported
    case tunnelClosed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SSH connection failed: \(msg)"
        case .handshakeFailed(let msg): return "SSH handshake failed: \(msg)"
        case .authenticationFailed(let msg): return "SSH authentication failed: \(msg)"
        case .noAvailablePort: return "No available local port for SSH tunnel"
        case .channelOpenFailed(let msg): return "SSH channel open failed: \(msg)"
        case .hostKeyRejected(let msg): return msg
        case .hostKeyUnverified(let msg): return msg
        case .jumpHostsUnsupported:
            return String(localized: """
                This connection goes through an SSH jump host, which TablePro on iPhone and iPad \
                cannot dial. Open it in TablePro on the Mac.
                """)
        case .tunnelClosed: return "SSH tunnel is closed"
        }
    }
}
