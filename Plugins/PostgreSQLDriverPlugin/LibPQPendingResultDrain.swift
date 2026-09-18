//
//  LibPQPendingResultDrain.swift
//  PostgreSQLDriverPlugin
//

import Foundation

nonisolated enum LibPQCopyDirection: Sendable, Equatable {
    case copyIn
    case copyOut
    case copyBoth
}

nonisolated enum LibPQCopyFormat: Sendable, Equatable {
    case textual
    case binary
}

nonisolated struct LibPQCopy: Sendable, Equatable {
    let direction: LibPQCopyDirection
    let format: LibPQCopyFormat
}

nonisolated enum LibPQPendingResult: Sendable, Equatable {
    case copy(LibPQCopy)
    case completed
}

nonisolated struct LibPQDrainOutcome: Sendable, Equatable {
    let endedCopies: [LibPQCopy]
    let stuckInCopy: LibPQCopy?

    static let idle = LibPQDrainOutcome(endedCopies: [], stuckInCopy: nil)

    var abandonedCopy: LibPQCopy? { endedCopies.first ?? stuckInCopy }
    var leavesConnectionUnusable: Bool { stuckInCopy != nil }
}

nonisolated enum LibPQPendingResultDrain {
    static func drain(
        nextResult: () -> LibPQPendingResult?,
        endCopy: (LibPQCopy) -> Void
    ) -> LibPQDrainOutcome {
        var endedCopies: [LibPQCopy] = []
        var copyAwaitingCompletion: LibPQCopy?
        while let pending = nextResult() {
            guard case .copy(let copy) = pending else {
                copyAwaitingCompletion = nil
                continue
            }
            if let unfinished = copyAwaitingCompletion {
                return LibPQDrainOutcome(endedCopies: endedCopies, stuckInCopy: unfinished)
            }
            copyAwaitingCompletion = copy
            endedCopies.append(copy)
            endCopy(copy)
        }
        return LibPQDrainOutcome(endedCopies: endedCopies, stuckInCopy: nil)
    }
}
