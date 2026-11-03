import Foundation

enum ConnectedScreen {
    case connecting
    case notConnected
    case failed(AppError)
    case lost(AppError)
    case tabs

    static func resolve(
        phase: ConnectionCoordinator.ConnectionPhase,
        isReconnecting: Bool,
        isHeldByEditor: Bool
    ) -> ConnectedScreen {
        guard !isHeldByEditor else { return .tabs }
        switch phase {
        case .notConnected:
            return .notConnected
        case .connecting:
            return .connecting
        case .failed(let error):
            return .failed(error)
        case .lost(let error):
            return isReconnecting ? .connecting : .lost(error)
        case .connected:
            return .tabs
        }
    }
}
