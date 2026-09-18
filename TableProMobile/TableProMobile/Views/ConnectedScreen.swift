import Foundation

enum ConnectedScreen {
    case connecting
    case failed(AppError)
    case tabs

    static func resolve(phase: ConnectionCoordinator.ConnectionPhase, isHeldByEditor: Bool) -> ConnectedScreen {
        guard !isHeldByEditor else { return .tabs }
        switch phase {
        case .connecting:
            return .connecting
        case .error(let error):
            return .failed(error)
        case .connected:
            return .tabs
        }
    }
}
