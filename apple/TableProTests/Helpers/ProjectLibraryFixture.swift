import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

// The three library stores over one throwaway defaults suite, with the scope that reads them.
@MainActor
final class ProjectLibraryFixture {
    let defaults: UserDefaults
    let metadata: SyncMetadataStorage
    let tracker: SyncChangeTracker
    let appEvents: AppEvents
    let connections: ConnectionStorage
    let groups: GroupStorage
    let projects: ProjectStorage
    let scope: ConnectionScope
    let connectionsURL: URL

    private let suite: EphemeralDefaults
    private let syncSuite: EphemeralDefaults
    private let directory: URL

    init(unreadableConnections: Bool = false) throws {
        suite = try EphemeralDefaults("ProjectLibraryFixture")
        syncSuite = try EphemeralDefaults("ProjectLibraryFixture.sync")
        defaults = suite.defaults
        let metadata = SyncMetadataStorage(userDefaults: syncSuite.defaults)
        self.metadata = metadata
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        self.tracker = tracker
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("project-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        connectionsURL = directory.appendingPathComponent("connections.json")
        if unreadableConnections {
            try Data("not json".utf8).write(to: connectionsURL)
        }
        let keychain = InMemoryKeychain()
        let events = AppEvents()
        appEvents = events
        let connectionStorage = ConnectionStorage(
            fileURL: connectionsURL,
            userDefaults: suite.defaults,
            syncTracker: tracker,
            keychain: keychain,
            appEvents: events,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
        connections = connectionStorage
        let groupStorage = GroupStorage(
            userDefaults: suite.defaults,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            appEvents: events
        )
        groups = groupStorage
        let projectStorage = ProjectStorage(
            userDefaults: suite.defaults,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            groupStorage: groupStorage,
            appEvents: events
        )
        projects = projectStorage
        scope = ConnectionScope(
            userDefaults: suite.defaults,
            connectionStorage: connectionStorage,
            groupStorage: groupStorage,
            projectStorage: projectStorage,
            appEvents: events
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func addConnection(
        _ name: String,
        groupId: UUID? = nil,
        projectId: UUID? = nil,
        localOnly: Bool = false
    ) -> DatabaseConnection {
        let connection = DatabaseConnection(name: name, groupId: groupId, projectId: projectId, localOnly: localOnly)
        connections.addConnection(connection)
        return connection
    }

    @discardableResult
    func addGroup(_ name: String, parentId: UUID? = nil, projectId: UUID? = nil) throws -> ConnectionGroup {
        let group = ConnectionGroup(name: name, parentId: parentId, projectId: projectId)
        try groups.addGroup(group)
        return try #require(groups.group(for: group.id))
    }

    func stored(_ connection: DatabaseConnection) -> DatabaseConnection? {
        connections.loadConnection(id: connection.id)
    }

    func dirty(_ type: SyncRecordType) -> Set<String> {
        tracker.dirtyRecords(for: type)
    }

    func tombstones(_ type: SyncRecordType) -> Set<String> {
        Set(metadata.tombstones(for: type).map(\.id))
    }

    func clearDirty() {
        for type in SyncRecordType.allCases {
            tracker.clearAllDirty(type)
        }
    }
}
