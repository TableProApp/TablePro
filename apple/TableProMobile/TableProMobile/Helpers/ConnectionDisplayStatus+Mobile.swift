import SwiftUI
import TableProConnectionLibrary

extension ConnectionDisplayStatus {
    // iOS redials once per loss, which the presentation titles without a count.
    init(phase: ConnectionCoordinator.ConnectionPhase, isReconnecting: Bool) {
        switch phase {
        case .notConnected:
            self = .notConnected
        case .connecting:
            self = .connecting
        case .connected:
            self = isReconnecting ? .reconnecting(attempt: 1, of: 1) : .connected
        case .failed(let error):
            self = .failed(cause: error.message)
        case .lost(let error):
            self = isReconnecting ? .reconnecting(attempt: 1, of: 1) : .lost(cause: error.message)
        }
    }

    // The engine leaves the resting states unmarked; the Info row still names them.
    var restingTitle: String? {
        switch self {
        case .connected: String(localized: "Connected")
        case .notConnected: String(localized: "Not Connected")
        case .connecting, .reconnecting, .lost, .failed: nil
        }
    }
}

extension ConnectionStatusTint {
    var color: Color {
        switch self {
        case .secondary: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}
