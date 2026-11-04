import Foundation

public enum ConnectionDisplayStatus: Equatable, Sendable {
    case notConnected
    case connecting
    case reconnecting(attempt: Int, of: Int)
    case connected
    case lost(cause: String?)
    case failed(cause: String?)
}

public enum ConnectionStatusSymbol: Equatable, Sendable {
    case progress
    case lost
    case failed

    public var systemName: String? {
        switch self {
        case .progress: nil
        case .lost: "bolt.slash.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

public enum ConnectionStatusTint: Equatable, Sendable {
    case secondary
    case warning
    case critical
}

public enum ConnectionStatusAction: Equatable, Sendable {
    case connect
    case reconnect
    case cancel
}

// Every surface that shows a connection's state renders this, so a state reads the same everywhere.
public struct ConnectionStatusPresentation: Equatable, Sendable {
    public let status: ConnectionDisplayStatus

    public init(_ status: ConnectionDisplayStatus) {
        self.status = status
    }

    // Connected and not connected are the resting states, so they carry no mark.
    public var symbol: ConnectionStatusSymbol? {
        switch status {
        case .notConnected, .connected: nil
        case .connecting, .reconnecting: .progress
        case .lost: .lost
        case .failed: .failed
        }
    }

    public var tint: ConnectionStatusTint {
        switch status {
        case .notConnected, .connected, .connecting, .reconnecting: .secondary
        case .lost: .warning
        case .failed: .critical
        }
    }

    public var title: String? {
        switch status {
        case .notConnected, .connected:
            nil
        case .connecting:
            String(localized: "Connecting")
        case .reconnecting(let attempt, let total) where total > 1:
            String(format: String(localized: "Reconnecting (%lld of %lld)"), attempt, total)
        case .reconnecting:
            String(localized: "Reconnecting")
        case .lost:
            String(localized: "Connection lost")
        case .failed:
            String(localized: "Couldn't connect")
        }
    }

    public var cause: String? {
        switch status {
        case .lost(let cause), .failed(let cause):
            cause.flatMap { $0.isEmpty ? nil : $0 }
        case .notConnected, .connecting, .reconnecting, .connected:
            nil
        }
    }

    public var help: String? {
        guard let title else { return nil }
        guard let cause else { return title }
        return String(format: String(localized: "%1$@: %2$@"), title, cause)
    }

    public var accessibilityStatus: String {
        switch status {
        case .notConnected: String(localized: "not connected")
        case .connected: String(localized: "connected")
        default: help ?? ""
        }
    }

    public var primaryAction: ConnectionStatusAction? {
        switch status {
        case .notConnected: .connect
        case .connecting, .reconnecting: .cancel
        case .connected: nil
        case .lost: .reconnect
        case .failed: .connect
        }
    }

    // A lost or reconnecting session still holds a driver and tunnels, so it can always be ended.
    public var offersDisconnect: Bool {
        switch status {
        case .connected, .reconnecting, .lost: true
        case .notConnected, .connecting, .failed: false
        }
    }

    public var isBusy: Bool {
        symbol == .progress
    }
}
