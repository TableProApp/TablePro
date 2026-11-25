import Foundation

public enum ImportFailure: Sendable, Equatable {
    case libraryUnreadable
    case connectionsNotSaved
    case savedQueriesNotSaved
}

public enum ImportHandoff: Sendable, Equatable {
    case open(UUID)
    case select([UUID])
    case stay
}

// Who chose the hosts an import wrote: a file or a link may come from someone else.
public enum ImportOrigin: Sendable, Equatable {
    case fileOrLink
    case ownMachineOrAccount
}

public struct ImportOutcome: Sendable, Equatable {
    // Added or replaced rows in plan order; a Keep Existing target was not written, so it is left out.
    public var connectionIds: [UUID]
    public var connectionsAdded: Int
    public var connectionsReplaced: Int
    // Secrets the store refused; their connections were imported without them.
    public var passwordsNotKept: Int
    public var savedQueriesAdded: Int
    public var savedQueriesNotImported: Int
    public var failure: ImportFailure?

    public var importedAnything: Bool {
        connectionsAdded + connectionsReplaced + savedQueriesAdded > 0
    }

    // Opening one connection from a file or a link would connect, without consent, to a host its sender chose.
    public func handoff(from origin: ImportOrigin) -> ImportHandoff {
        switch (connectionIds.count, origin) {
        case (0, _): .stay
        case (1, .ownMachineOrAccount): .open(connectionIds[0])
        default: .select(connectionIds)
        }
    }

    public init(
        connectionIds: [UUID] = [],
        connectionsAdded: Int = 0,
        connectionsReplaced: Int = 0,
        passwordsNotKept: Int = 0,
        savedQueriesAdded: Int = 0,
        savedQueriesNotImported: Int = 0,
        failure: ImportFailure? = nil
    ) {
        self.connectionIds = connectionIds
        self.connectionsAdded = connectionsAdded
        self.connectionsReplaced = connectionsReplaced
        self.passwordsNotKept = passwordsNotKept
        self.savedQueriesAdded = savedQueriesAdded
        self.savedQueriesNotImported = savedQueriesNotImported
        self.failure = failure
    }
}
