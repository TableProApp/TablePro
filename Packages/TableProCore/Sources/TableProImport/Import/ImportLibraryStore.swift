import Foundation

public struct ResolvedConnection: Sendable, Equatable {
    public let planned: PlannedConnection
    public let groupId: UUID?
    public let tagIds: [UUID]
    public let credentialProfileId: UUID?

    public init(planned: PlannedConnection, groupId: UUID?, tagIds: [UUID], credentialProfileId: UUID?) {
        self.planned = planned
        self.groupId = groupId
        self.tagIds = tagIds
        self.credentialProfileId = credentialProfileId
    }
}

public struct ConnectionImportWrite: Sendable, Equatable {
    public let added: [UUID]
    public let replaced: [UUID]

    public init(added: [UUID], replaced: [UUID]) {
        self.added = added
        self.replaced = replaced
    }
}

public struct SavedQueryImportWrite: Sendable, Equatable {
    public let insertedIds: [UUID]
    public let createdFolderIds: [UUID]
    public let alreadySaved: Int
    public let droppedKeywords: Int
    public let tooLarge: Int

    public init(insertedIds: [UUID], createdFolderIds: [UUID], alreadySaved: Int, droppedKeywords: Int, tooLarge: Int) {
        self.insertedIds = insertedIds
        self.createdFolderIds = createdFolderIds
        self.alreadySaved = alreadySaved
        self.droppedKeywords = droppedKeywords
        self.tooLarge = tooLarge
    }
}

public enum ImportStoreError: Error, Equatable {
    case unreadable
}

@MainActor
public protocol ImportLibraryStore {
    func snapshot() async throws -> ImportLibrarySnapshot
    /// Returns only the profiles this call created: a bundle can create a profile, never select one.
    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID]
    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?]
    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID]
    /// Only persisted ids, since credentials and saved queries follow what this returns; nil when nothing saved.
    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite?
    func existingConnectionIds() -> Set<UUID>
    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID)
}

public protocol SavedQueryImportStore: Sendable {
    func importSavedQueries(_ queries: [PlannedQuery]) async -> SavedQueryImportWrite?
}
