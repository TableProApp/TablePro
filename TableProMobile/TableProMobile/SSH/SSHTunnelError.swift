import Foundation

enum SSHTunnelError: Error, LocalizedError {
    case connectionFailed(String)
    case handshakeFailed(String)
    case authenticationFailed(String)
    case noAvailablePort
    case channelOpenFailed(String)
    case tunnelClosed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SSH connection failed: \(msg)"
        case .handshakeFailed(let msg): return "SSH handshake failed: \(msg)"
        case .authenticationFailed(let msg): return "SSH authentication failed: \(msg)"
        case .noAvailablePort: return "No available local port for SSH tunnel"
        case .channelOpenFailed(let msg): return "SSH channel open failed: \(msg)"
        case .tunnelClosed: return "SSH tunnel is closed"
        }
    }
}
