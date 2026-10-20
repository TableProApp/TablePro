import Foundation

nonisolated enum SSHTunnelError: Error, LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case handshakeFailed(String)
    case authenticationFailed(String)
    case noAvailablePort
    case channelOpenFailed(String)
    case hostKeyRejected(String)
    case hostKeyUnverified(String)
    case usernameMissing(host: String)
    case jumpHostNeedsKey(host: String)
    case jumpHostSharedKeyMissing(host: String)
    case jumpHostFailed(host: String, reason: String)
    case jumpHostKeysUnreadable(String)
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
        case .usernameMissing(let host):
            return String(format: String(localized: "No SSH username is set for %@."), host)
        case .jumpHostNeedsKey(let host):
            return String(format: String(localized: "Jump host %@ has no key on this device."), host)
        case .jumpHostSharedKeyMissing(let host):
            return String(
                format: String(localized: "Jump host %@ uses the SSH server's key, which is not on this device."),
                host
            )
        case .jumpHostFailed(let host, let reason):
            return String(format: String(localized: "Jump host %1$@ failed: %2$@"), host, reason)
        case .jumpHostKeysUnreadable(let reason):
            return String(format: String(localized: "The jump host keys on this device could not be read: %@"), reason)
        case .tunnelClosed: return "SSH tunnel is closed"
        }
    }
}
