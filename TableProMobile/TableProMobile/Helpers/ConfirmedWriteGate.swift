import Foundation
import TableProModels

nonisolated struct ConfirmedWriteGate: Equatable, Sendable {
    nonisolated enum Decision: Equatable, Sendable {
        case run(String)
        case awaitConfirmation
        case blocked
    }

    private(set) var pendingStatement: String?

    mutating func submit(_ statement: String, under level: SafeModeLevel) -> Decision {
        pendingStatement = nil
        switch level.writePermission {
        case .blocked:
            return .blocked
        case .requiresConfirmation:
            pendingStatement = statement
            return .awaitConfirmation
        case .proceed:
            return .run(statement)
        }
    }

    mutating func confirm(under level: SafeModeLevel) -> String? {
        defer { pendingStatement = nil }
        guard !level.blocksWrites else { return nil }
        return pendingStatement
    }

    mutating func cancel() {
        pendingStatement = nil
    }
}
