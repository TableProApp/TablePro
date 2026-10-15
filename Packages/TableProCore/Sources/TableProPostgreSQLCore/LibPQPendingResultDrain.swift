import Foundation

nonisolated public enum LibPQCopyDirection: Sendable, Equatable {
    case copyIn
    case copyOut
    case copyBoth
}

nonisolated public enum LibPQCopyFormat: Sendable, Equatable {
    case textual
    case binary
}

nonisolated public struct LibPQCopy: Sendable, Equatable {
    public let direction: LibPQCopyDirection
    public let format: LibPQCopyFormat

    public init(direction: LibPQCopyDirection, format: LibPQCopyFormat) {
        self.direction = direction
        self.format = format
    }
}

nonisolated public enum LibPQPendingResult: Sendable, Equatable {
    case copy(LibPQCopy)
    case completed
}

nonisolated public struct LibPQDrainOutcome: Sendable, Equatable {
    public let endedCopies: [LibPQCopy]
    public let stuckInCopy: LibPQCopy?

    public static let idle = LibPQDrainOutcome(endedCopies: [], stuckInCopy: nil)

    public var abandonedCopy: LibPQCopy? { endedCopies.first ?? stuckInCopy }
    public var leavesConnectionUnusable: Bool { stuckInCopy != nil }
}

nonisolated public enum LibPQPendingResultDrain {
    public static func drain(
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
