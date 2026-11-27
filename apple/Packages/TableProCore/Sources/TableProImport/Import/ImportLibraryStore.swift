import Foundation

public struct ResolvedConnection: Sendable, Equatable {
    public let planned: PlannedConnection
    public let groupId: UUID?
    public let tagIds: [UUID]
    public let credentialProfileId: UUID?
    // What the connection stores. Nil inside a group, whose top-level group carries the project.
    public let projectId: UUID?

    public init(
        planned: PlannedConnection,
        groupId: UUID?,
        tagIds: [UUID],
        credentialProfileId: UUID?,
        projectId: UUID? = nil
    ) {
        self.projectId = projectId
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

public struct CredentialWriteResult: Sendable, Equatable {
    public var secretsNotKept: Int

    public init(secretsNotKept: Int) {
        self.secretsNotKept = secretsNotKept
    }

    public static let allKept = CredentialWriteResult(secretsNotKept: 0)
}

@MainActor
public protocol ImportLibraryStore {
    func snapshot() async throws -> ImportLibrarySnapshot
    // Returns only the profiles this call created: a bundle can create a profile, never select one.
    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID]
    /// The first component's `scope` is the project a top-level group is matched in and created with.
    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?]
    /// Matches by id, then by name, and creates what is missing: `ImportProjectResolver` holds the rule.
    func ensureProjects(_ projects: [PlannedProject]) throws -> [BundleRef: UUID]
    /// The project each of these saved connections shows in, nil for none. An id left out takes the import's project.
    func projectIds(ofSavedConnections ids: Set<UUID>) -> [UUID: UUID?]
    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID]
    // Only persisted ids, since credentials and saved queries follow what this returns; nil when nothing saved.
    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite?
    func existingConnectionIds() -> Set<UUID>
    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) -> CredentialWriteResult
}

public extension ImportLibraryStore {
    // A store with no projects resolves none, so every connection lands in the caller's target.
    func ensureProjects(_ projects: [PlannedProject]) throws -> [BundleRef: UUID] {
        [:]
    }

    func projectIds(ofSavedConnections ids: Set<UUID>) -> [UUID: UUID?] {
        [:]
    }
}

public protocol SavedQueryImportStore: Sendable {
    func importSavedQueries(_ queries: [PlannedQuery]) async -> SavedQueryImportWrite?
}
