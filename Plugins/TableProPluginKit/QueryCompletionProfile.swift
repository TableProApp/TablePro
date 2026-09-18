import Foundation

public struct QueryCompletionProfile: Sendable {
    public let resolvedDialect: SQLDialectDescriptor?
    public let statementCompletions: [CompletionEntry]

    /// Identifies the content, so a consumer can tell one profile from another without comparing
    /// a dialect that is not `Equatable`. The editor rebuilds its completion service only when
    /// this changes, which is what keeps a refresh in a sibling window from closing an open
    /// completion popup.
    public let revision: String

    public static let defaultRevision = "base"

    public init(
        resolvedDialect: SQLDialectDescriptor?,
        statementCompletions: [CompletionEntry],
        revision: String = QueryCompletionProfile.defaultRevision
    ) {
        self.resolvedDialect = resolvedDialect
        self.statementCompletions = statementCompletions
        self.revision = revision
    }
}
