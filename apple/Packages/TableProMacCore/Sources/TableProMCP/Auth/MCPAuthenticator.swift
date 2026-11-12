import Foundation

public enum MCPClientAddress: Sendable, Equatable, Hashable {
    case loopback
    // The app's Unix socket. Its own key, so failures any local account causes over TCP never lock it out.
    case localSocket
    case remote(String)

    public var isLoopback: Bool {
        if case .loopback = self { return true }
        return false
    }

    public var displayValue: String {
        switch self {
        case .loopback:
            return "127.0.0.1"
        case .localSocket:
            return "local socket"
        case .remote(let host):
            return host
        }
    }

    // For the window only: the audit log stores displayValue, so that one stays English.
    public var localizedDisplayValue: String {
        switch self {
        case .localSocket:
            return String(localized: "Local socket")
        case .loopback, .remote:
            return displayValue
        }
    }
}

public protocol MCPAuthenticator: Sendable {
    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision
}
