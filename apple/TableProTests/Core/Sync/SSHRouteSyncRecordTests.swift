import CloudKit
import Foundation
@testable import TablePro
@testable import TableProSSHConfig
import TableProSSHTransport
import TableProSyncTransport
import Testing

struct SSHRouteSyncRecordTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let routeKey = ConnectionSyncField.sshRouteJson.key

    private func route() -> PublishedSSHRoute {
        PublishedSSHRoute(
            publisher: UUID(),
            input: .init(host: "db", port: nil, username: "", jumpHosts: []),
            hops: [.init(id: UUID(), alias: "bastion", host: "b.example", port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )
    }

    private func tunnelled() -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Alias",
            sshConfig: SSHConfiguration(
                enabled: true,
                host: "db",
                authMethod: .privateKey,
                privateKeyPath: "~/.ssh/id_ed25519",
                jumpHosts: [SSHJumpHost(host: "edge", authMethod: .privateKey, privateKeyPath: "~/.ssh/edge")]
            )
        )
        connection.sshRoute = route()
        return connection
    }

    @Test("The route this Mac dialed goes on the record and comes back")
    func routeRoundTrips() throws {
        let connection = tunnelled()

        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)

        #expect(try SyncRecordMapper.toConnection(record).sshRoute == connection.sshRoute)
    }

    @Test("The synced route holds hosts, ports and usernames, never a key or a key path")
    func routeCarriesNoKeys() throws {
        let record = SyncRecordMapper.toCKRecord(tunnelled(), in: zoneID)
        let data = try #require(record[routeKey] as? Data)
        let route = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hops = try #require(route["hops"] as? [[String: Any]])
        let target = try #require(route["target"] as? [String: Any])

        #expect(Set(route.keys) == ["version", "publisher", "basis", "hops", "target"])
        #expect(hops.allSatisfy { Set($0.keys) == ["id", "alias", "host", "port", "username"] })
        #expect(Set(target.keys) == ["alias", "host", "port", "username"])
        #expect(!String(decoding: data, as: UTF8.self).contains(".ssh"))
    }

    @Test("A route this Mac cleared is cleared on the server")
    func clearedRouteClearsTheServer() {
        var connection = tunnelled()
        let base = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        connection.sshRoute = nil

        let updated = SyncRecordMapper.toCKRecord(connection, in: zoneID, base: base)

        #expect(updated[routeKey] == nil)
        #expect(Set(updated.changedKeys()).contains(routeKey))
    }

    @Test("A route this build cannot read survives this Mac saving another change")
    func unreadableRouteSurvivesPush() throws {
        let base = SyncRecordMapper.toCKRecord(tunnelled(), in: zoneID)
        let unreadable = Data(#"{"version":2,"legs":[]}"#.utf8)
        base[routeKey] = unreadable as CKRecordValue
        var connection = try SyncRecordMapper.toConnection(base)
        #expect(connection.sshRoute == nil)
        connection.name = "Renamed"

        let updated = SyncRecordMapper.toCKRecord(connection, in: zoneID, base: base)

        #expect(updated[routeKey] as? Data == unreadable)
    }

    @Test("An unchanged route keeps the bytes another Mac wrote")
    func unchangedRouteIsNotRewritten() throws {
        let dialed = tunnelled()
        let base = SyncRecordMapper.toCKRecord(dialed, in: zoneID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let otherSpelling = try encoder.encode(try #require(dialed.sshRoute))
        base[routeKey] = otherSpelling as CKRecordValue
        var connection = try SyncRecordMapper.toConnection(base)
        connection.name = "Renamed"

        let updated = SyncRecordMapper.toCKRecord(connection, in: zoneID, base: base)

        #expect(updated[routeKey] as? Data == otherSpelling)
    }

    @Test("A copy with no route keeps the one another Mac published, and the publisher clears its own")
    func onlyThePublisherClearsTheRoute() throws {
        let published = tunnelled()
        let route = try #require(published.sshRoute)
        let base = SyncRecordMapper.toCKRecord(published, in: zoneID)
        var unread = published
        unread.sshRoute = nil

        let elsewhere = SyncRecordMapper.keepingForeignRoute(of: unread, in: base, publisher: UUID())
        let kept = SyncRecordMapper.toCKRecord(elsewhere, in: zoneID, base: base)
        #expect(elsewhere.sshRoute == route)
        #expect(kept[routeKey] as? Data == route.encoded())

        let publisher = SyncRecordMapper.keepingForeignRoute(of: unread, in: base, publisher: route.publisher)
        #expect(publisher.sshRoute == nil)
        #expect(SyncRecordMapper.toCKRecord(publisher, in: zoneID, base: base)[routeKey] == nil)
    }

    @Test("A Mac upgraded from a build that skipped the route fetches the zone once")
    @MainActor
    func upgradeRefetchesSkippedRoutes() throws {
        let pool = EphemeralDefaultsPool()
        let metadata = SyncMetadataStorage(userDefaults: try pool.make().defaults)
        var older = SyncCoordinator.readableContent
        older.remove(ConnectionSyncField.sshRouteContentKind)
        _ = metadata.adoptReadableRecordTypes(older)

        #expect(SyncCoordinator.readableContent(for: .default).contains(ConnectionSyncField.sshRouteContentKind))
        #expect(metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
        #expect(!metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
    }

    @Test("A profile's emptied port and jump hosts are cleared on the server")
    func profileClearsEmptiedFields() {
        let record = SyncRecordMapper.toCKRecord(SSHProfile(name: "Bastion", host: "b.example"), in: zoneID)
        let changed = Set(record.changedKeys())

        #expect(changed.contains(SSHProfileSyncField.port.key))
        #expect(changed.contains(SSHProfileSyncField.jumpHostsJson.key))
        #expect(record[SSHProfileSyncField.port.key] == nil)
        #expect(record[SSHProfileSyncField.jumpHostsJson.key] == nil)
    }

    @Test("A credential profile's emptied secure field list is cleared on the server")
    func credentialProfileClearsSecureFields() {
        let record = SyncRecordMapper.toCKRecord(CredentialProfile(name: "Shared", username: "app"), in: zoneID)

        #expect(Set(record.changedKeys()).contains(CredentialProfileSyncField.secureFieldIdsJson.key))
    }
}

@MainActor
struct SSHRouteSyncCoordinatorTests {
    private static let zoneID = SyncTestEnvironment.zoneID
    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "ssh-route-sync")
    }

    private static func tunnelled() -> DatabaseConnection {
        DatabaseConnection(name: "Alias", sshConfig: SSHConfiguration(enabled: true, host: "db", authMethod: .sshAgent))
    }

    // As another Mac published it, for a copy this Mac cached before it read the field.
    private func cacheRecord(of connection: DatabaseConnection) throws -> PublishedSSHRoute {
        let route = PublishedSSHRoute(
            publisher: UUID(),
            input: connection.sshConfig.publishedRouteInput,
            hops: [.init(id: UUID(), alias: "bastion", host: "b.example", port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )
        let record = SyncRecordMapper.toCKRecord(connection, in: Self.zoneID)
        record[ConnectionSyncField.sshRouteJson.key] = try #require(route.encoded()) as CKRecordValue
        environment.recordCache.store([record])
        return route
    }

    @Test("An edit from a Mac that cached the record before reading the route leaves another Mac's route on it")
    func editKeepsAnotherMacsRoute() async throws {
        let connection = Self.tunnelled()
        let route = try cacheRecord(of: connection)
        #expect(environment.connections.addConnection(connection))
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: Self.zoneID)
        let pushed = try #require(await transport.pushedRecords.first { $0.recordID == recordID })
        #expect(pushed[ConnectionSyncField.sshRouteJson.key] as? Data == route.encoded())
    }

    @Test("A copy edited during its push takes another Mac's route from the pull it merges")
    func mergeKeepsAnotherMacsRoute() async throws {
        let connection = Self.tunnelled()
        let route = try cacheRecord(of: connection)
        #expect(environment.connections.addConnection(connection))
        var remote = connection
        remote.port = 6_543
        remote.sshRoute = route
        let remoteRecord = SyncRecordMapper.toCKRecord(remote, in: Self.zoneID)
        let store = environment.connections
        let connectionId = connection.id
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { _ = store.mutateConnections(ids: [connectionId]) { $0.name = "Renamed" } },
            pulled: { _ in PullResult(changedRecords: [remoteRecord], deletedRecordIDs: [], newToken: nil) }
        )

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let merged = try #require(environment.connections.loadConnection(id: connectionId))
        #expect(merged.name == "Renamed")
        #expect(merged.port == 6_543)
        #expect(merged.sshRoute == route)
    }
}
