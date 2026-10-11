import Foundation

public enum ImportFailure: Sendable, Equatable {
    case libraryUnreadable
    case connectionsNotSaved
    case savedQueriesNotSaved
}

public struct ImportOutcome: Sendable, Equatable {
    public var connectionsAdded: Int
    public var connectionsReplaced: Int
    public var savedQueriesAdded: Int
    public var savedQueriesNotImported: Int
    public var failure: ImportFailure?

    public var importedAnything: Bool {
        connectionsAdded + connectionsReplaced + savedQueriesAdded > 0
    }

    public init(
        connectionsAdded: Int = 0,
        connectionsReplaced: Int = 0,
        savedQueriesAdded: Int = 0,
        savedQueriesNotImported: Int = 0,
        failure: ImportFailure? = nil
    ) {
        self.connectionsAdded = connectionsAdded
        self.connectionsReplaced = connectionsReplaced
        self.savedQueriesAdded = savedQueriesAdded
        self.savedQueriesNotImported = savedQueriesNotImported
        self.failure = failure
    }
}
