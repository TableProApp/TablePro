import Foundation
import TableProModels

nonisolated struct ConfirmedWriteGate<Pending: Sendable>: Sendable {
    nonisolated enum Decision: Sendable {
        case run(Pending)
        case awaitConfirmation
        case blocked
    }

    private(set) var pending: Pending?

    mutating func submit(_ write: Pending, under level: SafeModeLevel) -> Decision {
        pending = nil
        switch level.writePermission {
        case .blocked:
            return .blocked
        case .requiresConfirmation:
            pending = write
            return .awaitConfirmation
        case .proceed:
            return .run(write)
        }
    }

    mutating func confirm(under level: SafeModeLevel) -> Pending? {
        defer { pending = nil }
        guard !level.blocksWrites else { return nil }
        return pending
    }

    mutating func cancel() {
        pending = nil
    }
}

nonisolated extension ConfirmedWriteGate.Decision: Equatable where Pending: Equatable {}
