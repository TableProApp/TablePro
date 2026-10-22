import CloudKit
import Foundation
@testable import TablePro
@testable import TableProSSHConfig
import TableProSSHTransport
import TableProSyncTransport
import Testing

@MainActor
private final class UndoOnce {
    var pending = true
}

@MainActor
struct SyncConflictRebaseTests {
    private static let zoneID = SyncTestEnvironment.zoneID
    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-conflict-rebase")
    }

    private func copy(_ record: CKRecord) throws -> CKRecord {
        try #require(record.copy() as? CKRecord)
    }

    private func lastPush(of recordID: CKRecord.ID, in transport: ScriptedSyncTransport) async throws -> CKRecord {
        try #require(await transport.pushedRecords.last { $0.recordID == recordID })
    }

    // The latest push of each record, as a pull after the push returns it.
    nonisolated private static func latestPushes(_ records: [CKRecord]) -> PullResult {
        let latest = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { _, last in last })
        return PullResult(changedRecords: Array(latest.values), deletedRecordIDs: [], newToken: nil)
    }

    private static func tunnelled() -> DatabaseConnection {
        DatabaseConnection(name: "Alias", sshConfig: SSHConfiguration(enabled: true, host: "db", authMethod: .sshAgent))
    }

    private static func route(of connection: DatabaseConnection, publisher: UUID, hop: String) -> PublishedSSHRoute {
        PublishedSSHRoute(
            publisher: publisher,
            input: connection.sshConfig.publishedRouteInput,
            hops: [.init(id: UUID(), alias: "bastion", host: hop, port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )
    }

    // This Mac published `own`, cached the record, then cleared its route; another Mac published a route since.
    private func clearedOwnRouteAfterAnotherMacPublished() throws -> (cached: CKRecord, server: CKRecord, other: PublishedSSHRoute) {
        var connection = Self.tunnelled()
        connection.sshRoute = Self.route(of: connection, publisher: environment.connections.sshRoutePublisherId, hop: "old.example")
        #expect(environment.connections.addConnection(connection))
        let stored = try #require(environment.connections.loadConnection(id: connection.id))
        let cached = SyncRecordMapper.toCKRecord(stored, in: Self.zoneID)
        environment.recordCache.store([cached])

        let other = Self.route(of: connection, publisher: UUID(), hop: "new.example")
        let server = try copy(cached)
        server.fields(ConnectionSyncField.self)[.sshRouteJson] = other.encoded()
        #expect(environment.connections.mutateConnections(ids: [connection.id], byUser: false) { $0.sshRoute = nil })
        return (cached, server, other)
    }

    @Test("A Mac clearing its own route keeps the route another Mac published after its copy")
    func staleClearKeepsAnotherMacsRoute() async throws {
        let (cached, server, other) = try clearedOwnRouteAfterAnotherMacPublished()
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        await transport.holdNewerCopy(server, of: cached.recordID)

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let pushed = try await lastPush(of: cached.recordID, in: transport)
        #expect(pushed[ConnectionSyncField.sshRouteJson.key] as? Data == other.encoded())
        #expect(await transport.pushCount == 2)
    }

    @Test("A copy whose push failed keeps another Mac's route when it merges the pull")
    func pullMergeKeepsAnotherMacsRoute() async throws {
        let (cached, server, other) = try clearedOwnRouteAfterAnotherMacPublished()
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            rejecting: [cached.recordID],
            pulled: { _ in PullResult(changedRecords: [server], deletedRecordIDs: [], newToken: nil) }
        )

        _ = await environment.makeCoordinator(transport: transport).runSyncCycle()

        let parsed = try #require(SyncRecordMapper.parse(recordName: cached.recordID.recordName))
        let connectionId = try #require(UUID(uuidString: parsed.id))
        #expect(environment.connections.loadConnection(id: connectionId)?.sshRoute == other)
    }

    @Test("A rename from a stale copy keeps the tunnel another device changed, however that device spelled it")
    func staleRenameKeepsAnotherDevicesTunnel() async throws {
        let connection = DatabaseConnection(
            name: "Production",
            sshConfig: SSHConfiguration(enabled: true, host: "bastion", authMethod: .sshAgent)
        )
        #expect(environment.connections.addConnection(connection))
        let stored = try #require(environment.connections.loadConnection(id: connection.id))
        let otherSpelling = JSONEncoder()
        otherSpelling.outputFormatting = .prettyPrinted
        let cached = SyncRecordMapper.toCKRecord(stored, in: Self.zoneID)
        cached.fields(ConnectionSyncField.self)[.sshConfigJson] = try otherSpelling.encode(stored.sshConfig)
        environment.recordCache.store([cached])

        var moved = stored.sshConfig
        moved.host = "bastion-eu"
        let server = try copy(cached)
        server.fields(ConnectionSyncField.self)[.sshConfigJson] = try otherSpelling.encode(moved)
        #expect(environment.connections.mutateConnections(ids: [connection.id]) { $0.name = "Production EU" })
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        await transport.holdNewerCopy(server, of: cached.recordID)

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let pushed = try SyncRecordMapper.toConnection(try await lastPush(of: cached.recordID, in: transport))
        #expect(pushed.name == "Production EU")
        #expect(pushed.sshConfig.host == "bastion-eu")
    }

    @Test("A tag recoloured from a stale copy keeps the name another device gave it, here and in iCloud")
    func staleTagEditKeepsAnotherDevicesName() async throws {
        let tag = ConnectionTag(name: "prod", color: .red)
        try environment.tags.addTag(tag)
        let cached = SyncRecordMapper.toCKRecord(tag, in: Self.zoneID)
        environment.recordCache.store([cached])
        let server = try copy(cached)
        server.fields(ConnectionTagSyncField.self)[.name] = "production"
        var recoloured = tag
        recoloured.color = .blue
        #expect(environment.tags.saveTags([recoloured]))
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID, echoing: { records, _ in Self.latestPushes(records) })
        await transport.holdNewerCopy(server, of: cached.recordID)

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let pushed = try #require(SyncRecordMapper.toTag(try await lastPush(of: cached.recordID, in: transport)))
        #expect(pushed.name == "production")
        #expect(pushed.color == .blue)
        let local = try #require(environment.tags.tag(for: tag.id))
        #expect(local.name == "production")
        #expect(local.color == .blue)
    }

    @Test("A refused edit no run could merge stays on this Mac and merges on the next push")
    func unmergedRefusalKeepsTheEdit() async throws {
        let tag = ConnectionTag(name: "prod", color: .red)
        try environment.tags.addTag(tag)
        let cached = SyncRecordMapper.toCKRecord(tag, in: Self.zoneID)
        environment.recordCache.store([cached])
        let server = try copy(cached)
        server.fields(ConnectionTagSyncField.self)[.name] = "production"
        var recoloured = tag
        recoloured.color = .blue
        #expect(environment.tags.saveTags([recoloured]))
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            pulled: { _ in PullResult(changedRecords: [server], deletedRecordIDs: [], newToken: nil) }
        )
        await transport.holdNewerCopy(nil, of: cached.recordID)
        let coordinator = environment.makeCoordinator(transport: transport)

        _ = await coordinator.runSyncCycle()

        #expect(environment.tags.tag(for: tag.id)?.color == .blue)
        #expect(environment.tracker.dirtyRecords(for: .tag).contains(tag.id.uuidString))

        await transport.holdNewerCopy(server, of: cached.recordID)
        _ = await coordinator.runSyncCycle()

        let pushed = try #require(SyncRecordMapper.toTag(try await lastPush(of: cached.recordID, in: transport)))
        #expect(pushed.name == "production")
        #expect(pushed.color == .blue)
    }

    @Test("Options changed on two Macs in one settings category are both kept")
    func settingsOptionsMerge() throws {
        let base = SyncRecordMapper.toCKRecord(category: "dataGrid", settingsData: Data(#"{"a":1,"b":1}"#.utf8), in: Self.zoneID)
        let server = try copy(base)
        server.fields(AppSettingsSyncField.self)[.settingsJson] = Data(#"{"a":2,"b":1}"#.utf8)

        let edit = SyncRecordMapper.settingsEdit(
            category: "dataGrid",
            settingsData: Data(#"{"a":1,"b":2}"#.utf8),
            in: Self.zoneID,
            base: base
        )

        let merged = try #require(edit.rebased(onto: server))
        let blob = try #require(SyncRecordMapper.settingsData(from: merged))
        let document = try JSONSerialization.jsonObject(with: blob) as? NSDictionary
        #expect(document == ["a": 2, "b": 2])
    }

    @Test(
        "Shortcuts, AI providers and a theme both Macs changed go up whole from this Mac, never mixed",
        arguments: [AppSettingsCategory.keyboard, AppSettingsCategory.ai, ThemeCatalog.syncCategory(for: "ocean")]
    )
    func wholeCategoriesAreNotMixed(category: String) throws {
        let base = SyncRecordMapper.toCKRecord(category: category, settingsData: Data(#"{"a":1,"b":1}"#.utf8), in: Self.zoneID)
        let server = try copy(base)
        server.fields(AppSettingsSyncField.self)[.settingsJson] = Data(#"{"a":2,"b":1}"#.utf8)
        let mine = Data(#"{"a":1,"b":2}"#.utf8)

        let edit = SyncRecordMapper.settingsEdit(category: category, settingsData: mine, in: Self.zoneID, base: base)

        let merged = try #require(edit.rebased(onto: server))
        #expect(SyncRecordMapper.settingsData(from: merged) == mine)
    }

    @Test("A settings category an older build cached in another key order is no pending edit")
    func respelledSettingsAreNoEdit() {
        let base = SyncRecordMapper.toCKRecord(category: "dataGrid", settingsData: Data(#"{"b":1,"a":2}"#.utf8), in: Self.zoneID)

        let edit = SyncRecordMapper.settingsEdit(
            category: "dataGrid",
            settingsData: Data(#"{"a":2,"b":1}"#.utf8),
            in: Self.zoneID,
            base: base
        )

        #expect(edit.changesContent == false)
    }

    @Test("Slash commands two Macs added under one name both stay, the later one under a free name")
    func mergedSlashCommandsKeepDistinctNames() throws {
        let shared = CustomSlashCommand(name: "explain", promptTemplate: "Explain {{query}}")
        let mine = CustomSlashCommand(name: "summarize", promptTemplate: "Summarize mine")
        let theirs = CustomSlashCommand(name: "Summarize", promptTemplate: "Summarize theirs")
        let encoder = JSONEncoder()
        let category = CustomSlashCommandStorage.syncCategory
        let base = SyncRecordMapper.toCKRecord(category: category, settingsData: try encoder.encode([shared]), in: Self.zoneID)
        let server = try copy(base)
        server.fields(AppSettingsSyncField.self)[.settingsJson] = try encoder.encode([shared, theirs])

        let edit = SyncRecordMapper.settingsEdit(
            category: category,
            settingsData: try encoder.encode([shared, mine]),
            in: Self.zoneID,
            base: base
        )

        let merged = try #require(edit.rebased(onto: server))
        let blob = try #require(SyncRecordMapper.settingsData(from: merged))
        let commands = try JSONDecoder().decode([CustomSlashCommand].self, from: blob)
        #expect(commands.map(\.name) == ["explain", "Summarize", "summarize-2"])
        #expect(commands.map(\.id) == [shared.id, theirs.id, mine.id])
    }

    @Test("A pulled record of a category this Mac does not sync is not cached")
    func unsyncedCategoryStaysOutOfTheCache() async throws {
        let tag = ConnectionTag(name: "prod", color: .red)
        let record = SyncRecordMapper.toCKRecord(tag, in: Self.zoneID)
        var settings = SyncSettings.default
        settings.syncGroupsAndTags = false
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        #expect(await coordinator.applyPullResult(
            PullResult(changedRecords: [record], deletedRecordIDs: [], newToken: nil),
            settings: settings
        ))

        #expect(environment.recordCache.record(for: record.recordID) == nil)
    }

    // A tag cached as iCloud held it, recoloured here and renamed in iCloud since.
    private func recolouredTag() throws -> (tag: ConnectionTag, cached: CKRecord, server: CKRecord) {
        let tag = ConnectionTag(name: "prod", color: .red)
        try environment.tags.addTag(tag)
        let cached = SyncRecordMapper.toCKRecord(tag, in: Self.zoneID)
        environment.recordCache.store([cached])
        let server = try copy(cached)
        server.fields(ConnectionTagSyncField.self)[.name] = "production"
        var recoloured = tag
        recoloured.color = .blue
        #expect(environment.tags.saveTags([recoloured]))
        return (tag, cached, server)
    }

    @Test("A refusal that names no server copy reads it and merges onto it in the same run")
    func refusalWithoutCopyIsMerged() async throws {
        let (_, cached, server) = try recolouredTag()
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        await transport.holdNewerCopy(nil, of: cached.recordID)
        await transport.serveOnFetch(server)

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let pushed = try #require(SyncRecordMapper.toTag(try await lastPush(of: cached.recordID, in: transport)))
        #expect(pushed.name == "production")
        #expect(pushed.color == .blue)
    }

    @Test("A record deleted elsewhere while this Mac edited it goes up again whole")
    func recordDeletedElsewhereIsRecreated() async throws {
        let (tag, cached, _) = try recolouredTag()
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        await transport.deleteElsewhere(cached.recordID)

        #expect(await environment.makeCoordinator(transport: transport).runSyncCycle() == nil)

        let pushed = try await lastPush(of: cached.recordID, in: transport)
        #expect(await transport.pushCount == 2)
        #expect(SyncRecordMapper.toTag(pushed) == ConnectionTag(id: tag.id, name: "prod", color: .blue))
        #expect(!environment.tracker.dirtyRecords(for: .tag).contains(tag.id.uuidString))
    }

    @Test("A record marked for upload but not changed here takes the change a pull brings")
    func unchangedMarkedRecordTakesThePull() async throws {
        let tag = ConnectionTag(name: "prod", color: .red)
        try environment.tags.addTag(tag)
        let cached = SyncRecordMapper.toCKRecord(tag, in: Self.zoneID)
        environment.recordCache.store([cached])
        environment.tracker.markDirty(.tag, ids: [tag.id.uuidString])
        let server = try copy(cached)
        server.fields(ConnectionTagSyncField.self)[.name] = "production"
        let coordinator = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))

        #expect(await coordinator.applyPullResult(PullResult(changedRecords: [server], deletedRecordIDs: [], newToken: nil)))

        #expect(environment.tags.tag(for: tag.id)?.name == "production")
    }

    @Test("A field set back to its old value while a merged save is in flight reaches iCloud on the next push")
    func undoDuringMergedSaveIsPushed() async throws {
        let (tag, cached, server) = try recolouredTag()
        let tags = environment.tags
        let undo = UndoOnce()
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: {
                guard undo.pending else { return }
                undo.pending = false
                _ = tags.saveTags([tag])
            },
            echoing: { records, _ in Self.latestPushes(records) }
        )
        await transport.holdNewerCopy(server, of: cached.recordID)
        let coordinator = environment.makeCoordinator(transport: transport)

        _ = await coordinator.runSyncCycle()
        #expect(environment.tags.tag(for: tag.id)?.color == .red)

        let merged = try await lastPush(of: cached.recordID, in: transport)
        await transport.holdNewerCopy(merged, of: cached.recordID)
        #expect(await coordinator.runSyncCycle() == nil)

        let pushed = try #require(SyncRecordMapper.toTag(try await lastPush(of: cached.recordID, in: transport)))
        #expect(pushed.name == "production")
        #expect(pushed.color == .red)
    }

    @Test("A route lands on the server's copy by the rules a dial uses")
    func routeRebaseRules() {
        let connection = Self.tunnelled()
        let me = UUID()
        let mine = Self.route(of: connection, publisher: me, hop: "a.example")
        let theirs = Self.route(of: connection, publisher: UUID(), hop: "b.example")
        var theirsElsewhere = theirs
        theirsElsewhere.publisher = UUID()
        theirsElsewhere.hops = theirs.hops.map { hop in
            var renamed = hop
            renamed.alias = "jump"
            renamed.id = UUID()
            return renamed
        }

        #expect(SyncRecordMapper.rebasedRoute(wanted: nil, server: theirs, publisher: me) == theirs)
        #expect(SyncRecordMapper.rebasedRoute(wanted: nil, server: mine, publisher: me) == nil)
        #expect(SyncRecordMapper.rebasedRoute(wanted: theirsElsewhere, server: theirs, publisher: me) == theirs)
        #expect(SyncRecordMapper.rebasedRoute(wanted: mine, server: theirs, publisher: me) == mine)
        #expect(SyncRecordMapper.rebasedRoute(wanted: mine, server: nil, publisher: me) == mine)
    }
}
