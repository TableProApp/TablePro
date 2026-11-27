import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncProjectMembershipTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-project-membership")
    }

    private func coordinator(writable: Bool, transport: ScriptedSyncTransport? = nil) -> SyncCoordinator {
        environment.makeCoordinator(
            transport: transport ?? ScriptedSyncTransport(zoneID: Self.zoneID),
            projectSyncWritable: writable
        )
    }

    private static func pull(_ records: [CKRecord], deleted: [CKRecord.ID] = []) -> PullResult {
        PullResult(changedRecords: records, deletedRecordIDs: deleted, newToken: nil)
    }

    private static func recordID(_ type: SyncRecordType, _ id: UUID) -> CKRecord.ID {
        SyncRecordMapper.recordID(type: type, id: id.uuidString, in: zoneID)
    }

    // A record as a build with the type in Production writes it.
    private static func projectRecord(_ project: ConnectionProject) -> CKRecord {
        let record = CKRecord(recordType: SyncRecordType.project.rawValue, recordID: recordID(.project, project.id))
        record[ConnectionProjectSyncField.projectId.key] = project.id.uuidString
        record[ConnectionProjectSyncField.name.key] = project.name
        record[ConnectionProjectSyncField.sortOrder.key] = Int64(project.sortOrder)
        return record
    }

    private func stored(_ connection: DatabaseConnection) -> DatabaseConnection? {
        environment.connections.loadConnection(id: connection.id)
    }

    // MARK: - Membership stays local until a record can carry it

    @Test("A pulled connection with no project keeps this Mac's project while project sync is off")
    func pulledConnectionKeepsTheLocalProject() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let local = DatabaseConnection(name: "prod", projectId: project.id)
        environment.connections.addConnection(local)
        environment.tracker.clearAllDirty(.connection)
        var renamed = local
        renamed.name = "prod (renamed elsewhere)"
        renamed.projectId = nil

        let applied = await coordinator(writable: false).applyPullResult(
            Self.pull([SyncRecordMapper.toCKRecord(renamed, in: Self.zoneID)]),
            settings: .default
        )

        #expect(applied)
        #expect(stored(local)?.name == "prod (renamed elsewhere)")
        #expect(stored(local)?.projectId == project.id)
    }

    @Test("A pulled group with no project keeps this Mac's project while project sync is off")
    func pulledGroupKeepsTheLocalProject() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let local = ConnectionGroup(name: "Production", projectId: project.id)
        try environment.groups.addGroup(local)
        var recolored = local
        recolored.color = .red
        recolored.projectId = nil

        let applied = await coordinator(writable: false).applyPullResult(
            Self.pull([SyncRecordMapper.toCKRecord(recolored, in: Self.zoneID)]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.groups.group(for: local.id)?.color == .red)
        #expect(environment.groups.group(for: local.id)?.projectId == project.id)
    }

    @Test("Once project sync is on, a pulled record's project replaces this Mac's")
    func pulledMembershipAppliesOnceWritable() async throws {
        let here = try environment.projects.createProject(name: "Here")
        let there = try environment.projects.createProject(name: "There")
        let connection = DatabaseConnection(name: "prod", projectId: here.id)
        environment.connections.addConnection(connection)
        let group = ConnectionGroup(name: "Production", projectId: here.id)
        try environment.groups.addGroup(group)
        for type in SyncRecordType.allCases {
            environment.tracker.clearAllDirty(type)
        }
        let connectionRecord = SyncRecordMapper.toCKRecord(connection, in: Self.zoneID)
        connectionRecord[ConnectionSyncField.projectId.key] = there.id.uuidString
        let groupRecord = SyncRecordMapper.toCKRecord(group, in: Self.zoneID)
        groupRecord[ConnectionGroupSyncField.projectId.key] = there.id.uuidString

        let applied = await coordinator(writable: true).applyPullResult(
            Self.pull([connectionRecord, groupRecord]),
            settings: .default
        )

        #expect(applied)
        #expect(stored(connection)?.projectId == there.id)
        #expect(environment.groups.group(for: group.id)?.projectId == there.id)
    }

    @Test("A pulled connection naming a project this Mac does not hold keeps the id")
    func unknownProjectIdSurvivesAPull() async throws {
        let arrivesLater = UUID()
        let connection = DatabaseConnection(name: "prod")
        let record = SyncRecordMapper.toCKRecord(connection, in: Self.zoneID)
        record[ConnectionSyncField.projectId.key] = arrivesLater.uuidString

        let applied = await coordinator(writable: true).applyPullResult(Self.pull([record]), settings: .default)

        #expect(applied)
        #expect(stored(connection)?.projectId == arrivesLater)
    }

    // MARK: - Project records

    @Test("A project record is neither applied nor cached while project sync is off")
    func projectRecordWaitsWhileUnwritable() async throws {
        let remote = ConnectionProject(name: "Acme")
        let record = Self.projectRecord(remote)

        let applied = await coordinator(writable: false).applyPullResult(Self.pull([record]), settings: .default)

        #expect(applied)
        #expect(environment.projects.loadProjects().isEmpty)
        #expect(environment.recordCache.record(for: record.recordID) == nil)
    }

    @Test("A project deleted elsewhere stays here while project sync is off")
    func projectDeletionWaitsWhileUnwritable() async throws {
        let local = try environment.projects.createProject(name: "Acme")

        let applied = await coordinator(writable: false).applyPullResult(
            Self.pull([], deleted: [Self.recordID(.project, local.id)]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.projects.project(for: local.id) != nil)
    }

    @Test("Once project sync is on, a project record is applied and cached")
    func projectRecordAppliesOnceWritable() async throws {
        let remote = ConnectionProject(name: "Acme", sortOrder: 2)
        let record = Self.projectRecord(remote)

        let applied = await coordinator(writable: true).applyPullResult(Self.pull([record]), settings: .default)

        #expect(applied)
        #expect(environment.projects.loadProjects() == [remote])
        #expect(environment.recordCache.record(for: record.recordID) != nil)
        #expect(environment.tracker.dirtyRecords(for: .project).isEmpty)
    }

    @Test("A project deleted elsewhere goes here too, and its groups and connections leave it")
    func remoteProjectDeletionClearsMembership() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let group = ConnectionGroup(name: "Production", projectId: project.id)
        try environment.groups.addGroup(group)
        let synced = DatabaseConnection(name: "synced", projectId: project.id)
        let localOnly = DatabaseConnection(name: "local", projectId: project.id, localOnly: true)
        environment.connections.addConnection(synced)
        environment.connections.addConnection(localOnly)

        let applied = await coordinator(writable: true).applyPullResult(
            Self.pull([], deleted: [Self.recordID(.project, project.id)]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.projects.loadProjects().isEmpty)
        #expect(environment.groups.group(for: group.id)?.projectId == nil)
        #expect(stored(synced)?.projectId == nil)
        #expect(stored(localOnly)?.projectId == nil)
        #expect(environment.metadata.tombstones(for: .project).isEmpty)
    }

    // MARK: - Groups deleted elsewhere

    @Test("A group deleted elsewhere leaves no connection naming it, a Local only one included")
    func remoteGroupDeletionClearsMembers() async throws {
        let group = ConnectionGroup(name: "Production")
        try environment.groups.addGroup(group)
        let synced = DatabaseConnection(name: "synced", groupId: group.id)
        let localOnly = DatabaseConnection(name: "local", groupId: group.id, localOnly: true)
        environment.connections.addConnection(synced)
        environment.connections.addConnection(localOnly)

        let applied = await coordinator(writable: false).applyPullResult(
            Self.pull([], deleted: [Self.recordID(.group, group.id)]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.groups.loadGroups().isEmpty)
        #expect(stored(synced)?.groupId == nil)
        #expect(stored(localOnly)?.groupId == nil)
    }

    // A group holding a connection and a subgroup, with nothing waiting to upload.
    private func seedGroupWithMembers(
        projectId: UUID
    ) throws -> (group: ConnectionGroup, held: DatabaseConnection, subgroup: ConnectionGroup) {
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        try environment.groups.addGroup(group)
        let subgroup = ConnectionGroup(name: "EU", parentId: group.id)
        try environment.groups.addGroup(subgroup)
        let held = DatabaseConnection(name: "held", groupId: group.id)
        environment.connections.addConnection(held)
        for type in SyncRecordType.allCases {
            environment.tracker.clearAllDirty(type)
        }
        return (group, held, subgroup)
    }

    // What the device that deleted the group uploads: each member without the group, and the group's tombstone.
    private static func release(
        _ held: DatabaseConnection,
        _ subgroup: ConnectionGroup,
        from group: ConnectionGroup
    ) -> (connection: CKRecord, group: CKRecord, pull: PullResult) {
        var releasedConnection = held
        releasedConnection.groupId = nil
        var releasedGroup = subgroup
        releasedGroup.parentId = nil
        let connectionRecord = SyncRecordMapper.toCKRecord(releasedConnection, in: zoneID)
        let groupRecord = SyncRecordMapper.toCKRecord(releasedGroup, in: zoneID)
        return (connectionRecord, groupRecord, pull([connectionRecord, groupRecord], deleted: [recordID(.group, group.id)]))
    }

    @Test("While project sync is off, a pull that releases a group's members and deletes the group keeps them in its project")
    func memberUpdateAndGroupDeletionInOnePull() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let seeded = try seedGroupWithMembers(projectId: project.id)

        let applied = await coordinator(writable: false).applyPullResult(
            Self.release(seeded.held, seeded.subgroup, from: seeded.group).pull,
            settings: .default
        )

        #expect(applied)
        #expect(environment.groups.loadGroups().map(\.id) == [seeded.subgroup.id])
        #expect(stored(seeded.held)?.groupId == nil)
        #expect(stored(seeded.held)?.projectId == project.id)
        #expect(environment.groups.group(for: seeded.subgroup.id)?.parentId == nil)
        #expect(environment.groups.group(for: seeded.subgroup.id)?.projectId == project.id)
        #expect(environment.tracker.dirtyRecords(for: .connection).isEmpty)
    }

    @Test("Once project sync is on, a released member takes the project its own record carries")
    func releasedMemberRecordIsAuthoritativeOnceWritable() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let other = try environment.projects.createProject(name: "Other")
        let seeded = try seedGroupWithMembers(projectId: project.id)
        let released = Self.release(seeded.held, seeded.subgroup, from: seeded.group)
        released.connection[ConnectionSyncField.projectId.key] = other.id.uuidString

        let applied = await coordinator(writable: true).applyPullResult(released.pull, settings: .default)

        #expect(applied)
        #expect(stored(seeded.held)?.projectId == other.id)
        #expect(environment.groups.group(for: seeded.subgroup.id)?.projectId == nil)
    }

    // MARK: - The first run that can write membership

    @Test("The first run with project sync on marks every project and member once")
    func seedsMembershipOnce() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let group = ConnectionGroup(name: "Production", projectId: project.id)
        try environment.groups.addGroup(group)
        try environment.groups.addGroup(ConnectionGroup(name: "Unfiled"))
        let member = DatabaseConnection(name: "member", projectId: project.id)
        let localOnly = DatabaseConnection(name: "local", projectId: project.id, localOnly: true)
        let unfiled = DatabaseConnection(name: "unfiled")
        for connection in [member, localOnly, unfiled] {
            environment.connections.addConnection(connection)
        }
        for type in SyncRecordType.allCases {
            environment.tracker.clearAllDirty(type)
        }

        coordinator(writable: false).seedProjectMembershipIfNeeded()
        #expect(environment.tracker.dirtyRecords(for: .connection).isEmpty)
        #expect(!environment.metadata.projectMembershipSeeded)

        let writable = coordinator(writable: true)
        writable.seedProjectMembershipIfNeeded()
        #expect(environment.tracker.dirtyRecords(for: .project) == [project.id.uuidString])
        #expect(environment.tracker.dirtyRecords(for: .connection) == [member.id.uuidString])
        #expect(environment.tracker.dirtyRecords(for: .group) == [group.id.uuidString])
        #expect(environment.metadata.projectMembershipSeeded)

        for type in SyncRecordType.allCases {
            environment.tracker.clearAllDirty(type)
        }
        writable.seedProjectMembershipIfNeeded()
        #expect(environment.tracker.dirtyRecords(for: .connection).isEmpty)
        #expect(environment.tracker.dirtyRecords(for: .project).isEmpty)
    }

    @Test("A sync run uploads the members before it pulls")
    func seedRunsBeforeThePull() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let member = DatabaseConnection(name: "member", projectId: project.id)
        environment.connections.addConnection(member)
        for type in SyncRecordType.allCases {
            environment.tracker.clearAllDirty(type)
        }
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        #expect(await coordinator(writable: true, transport: transport).runSyncCycle() == nil)

        let pushed = await transport.pushedRecords.map(\.recordID.recordName)
        #expect(pushed.contains(Self.recordID(.connection, member.id).recordName))
        #expect(stored(member)?.projectId == project.id)
    }

    // The server's copy as a pull cached it while project sync was off: the record is kept whole, project included.
    private func cacheServerCopy(of connection: DatabaseConnection, projectId: UUID) -> CKRecord.ID {
        let record = SyncRecordMapper.toCKRecord(connection, in: Self.zoneID)
        record[ConnectionSyncField.projectId.key] = projectId.uuidString
        environment.recordCache.store([record])
        return record.recordID
    }

    private func cacheServerCopy(of group: ConnectionGroup, projectId: UUID) -> CKRecord.ID {
        let record = SyncRecordMapper.toCKRecord(group, in: Self.zoneID)
        record[ConnectionGroupSyncField.projectId.key] = projectId.uuidString
        environment.recordCache.store([record])
        return record.recordID
    }

    private func clearAllDirty() {
        for type in SyncRecordType.allCases {
            environment.tracker.clearAllDirty(type)
        }
    }

    @Test("The first run with project sync on keeps a project another device assigned when an unrelated edit goes up")
    func unrelatedEditKeepsAProjectAssignedElsewhere() async throws {
        let assigned = UUID()
        let connection = DatabaseConnection(name: "prod")
        environment.connections.addConnection(connection)
        let group = ConnectionGroup(name: "Production")
        try environment.groups.addGroup(group)
        let connectionRecordID = cacheServerCopy(of: connection, projectId: assigned)
        let groupRecordID = cacheServerCopy(of: group, projectId: assigned)
        clearAllDirty()
        var renamed = connection
        renamed.name = "prod (renamed here)"
        environment.connections.updateConnection(renamed)
        var recolored = group
        recolored.color = .red
        try environment.groups.updateGroup(recolored)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        #expect(await coordinator(writable: true, transport: transport).runSyncCycle() == nil)

        let pushed = await transport.pushedRecords
        let pushedConnection = try #require(pushed.first { $0.recordID == connectionRecordID })
        #expect(pushedConnection[ConnectionSyncField.name.key] as? String == "prod (renamed here)")
        #expect(pushedConnection[ConnectionSyncField.projectId.key] as? String == assigned.uuidString)
        let pushedGroup = try #require(pushed.first { $0.recordID == groupRecordID })
        #expect(pushedGroup[ConnectionGroupSyncField.color.key] as? String == ConnectionColor.red.rawValue)
        #expect(pushedGroup[ConnectionGroupSyncField.projectId.key] as? String == assigned.uuidString)
        #expect(stored(connection)?.projectId == assigned)
        #expect(environment.groups.group(for: group.id)?.projectId == assigned)
    }

    @Test("A project removed here after that first run is removed in iCloud")
    func removalAfterTheFirstRunGoesUp() async throws {
        let assigned = UUID()
        let connection = DatabaseConnection(name: "prod")
        environment.connections.addConnection(connection)
        let group = ConnectionGroup(name: "Production")
        try environment.groups.addGroup(group)
        let connectionRecordID = cacheServerCopy(of: connection, projectId: assigned)
        let groupRecordID = cacheServerCopy(of: group, projectId: assigned)
        clearAllDirty()
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        let coordinator = coordinator(writable: true, transport: transport)
        #expect(await coordinator.runSyncCycle() == nil)
        #expect(stored(connection)?.projectId == assigned)
        #expect(await transport.pushedRecords.isEmpty)

        var removed = try #require(stored(connection))
        removed.projectId = nil
        environment.connections.updateConnection(removed)
        var removedGroup = try #require(environment.groups.group(for: group.id))
        removedGroup.projectId = nil
        try environment.groups.updateGroup(removedGroup)
        #expect(await coordinator.runSyncCycle() == nil)

        let pushed = await transport.pushedRecords
        let pushedConnection = try #require(pushed.first { $0.recordID == connectionRecordID })
        #expect(pushedConnection.changedKeys().contains(ConnectionSyncField.projectId.key))
        #expect(pushedConnection[ConnectionSyncField.projectId.key] == nil)
        let pushedGroup = try #require(pushed.first { $0.recordID == groupRecordID })
        #expect(pushedGroup.changedKeys().contains(ConnectionGroupSyncField.projectId.key))
        #expect(pushedGroup[ConnectionGroupSyncField.projectId.key] == nil)
        #expect(stored(connection)?.projectId == nil)
        #expect(environment.groups.group(for: group.id)?.projectId == nil)
    }

    @Test("The first run with project sync on uploads this Mac's project over a different or absent one in iCloud")
    func localMembershipWinsOnTheFirstRun() async throws {
        let project = try environment.projects.createProject(name: "Acme")
        let connection = DatabaseConnection(name: "prod", projectId: project.id)
        environment.connections.addConnection(connection)
        let group = ConnectionGroup(name: "Production", projectId: project.id)
        try environment.groups.addGroup(group)
        let connectionRecordID = cacheServerCopy(of: connection, projectId: UUID())
        environment.recordCache.store([SyncRecordMapper.toCKRecord(group, in: Self.zoneID)])
        clearAllDirty()
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        #expect(await coordinator(writable: true, transport: transport).runSyncCycle() == nil)

        let pushed = await transport.pushedRecords
        let pushedConnection = try #require(pushed.first { $0.recordID == connectionRecordID })
        #expect(pushedConnection[ConnectionSyncField.projectId.key] as? String == project.id.uuidString)
        let pushedGroup = try #require(pushed.first { $0.recordID == Self.recordID(.group, group.id) })
        #expect(pushedGroup[ConnectionGroupSyncField.projectId.key] as? String == project.id.uuidString)
        let pushedProject = try #require(pushed.first { $0.recordID == Self.recordID(.project, project.id) })
        #expect(pushedProject[ConnectionProjectSyncField.name.key] as? String == "Acme")
        #expect(stored(connection)?.projectId == project.id)
        #expect(environment.groups.group(for: group.id)?.projectId == project.id)
    }

    // MARK: - Refetch

    @Test("The readable content names a record's project only while a pull reads it")
    func readableContentNamesTheProjectFieldsOnceWritable() {
        let closed = SyncCoordinator.readableContent(for: .default, readsProjects: false)
        let open = SyncCoordinator.readableContent(for: .default, readsProjects: true)

        #expect(!closed.contains(ConnectionSyncField.projectContentKind))
        #expect(!closed.contains(ConnectionGroupSyncField.projectContentKind))
        #expect(open == closed.union([ConnectionSyncField.projectContentKind, ConnectionGroupSyncField.projectContentKind]))
        #expect(SyncCoordinator.readableContent.isSuperset(of: SyncCoordinator.readableContent(for: .default)))
    }

    @Test("Projects follow the groups and tags category")
    func projectsFollowGroupsAndTags() {
        var settings = SyncSettings.default
        settings.syncGroupsAndTags = false
        #expect(!settings.syncs(.project))
        let content = SyncCoordinator.readableContent(for: settings, readsProjects: true)
        #expect(!content.contains(ConnectionGroupSyncField.projectContentKind))
        #expect(content.contains(ConnectionSyncField.projectContentKind))

        settings.syncGroupsAndTags = true
        #expect(settings.syncs(.project))
    }

    private func coordinator(writable: Bool, zone: MembershipZone) -> SyncCoordinator {
        let columnLayouts = environment.columnLayouts
        return SyncCoordinator(
            services: coordinator(writable: writable).services,
            recordCache: environment.recordCache,
            transport: zone,
            makeNetworkMonitor: { nil },
            columnLayouts: columnLayouts,
            licenseGate: { nil },
            pushRegistrar: .inert,
            schema: .projects(deployed: writable)
        )
    }

    @Test("Membership pulled while project sync was off is fetched again and applied by the first run that reads it")
    func membershipSkippedWhileUnwritableIsRefetched() async throws {
        let projectId = UUID()
        let connection = DatabaseConnection(name: "prod")
        let group = ConnectionGroup(name: "Production")
        let connectionRecord = SyncRecordMapper.toCKRecord(connection, in: Self.zoneID)
        connectionRecord[ConnectionSyncField.projectId.key] = projectId.uuidString
        let groupRecord = SyncRecordMapper.toCKRecord(group, in: Self.zoneID)
        groupRecord[ConnectionGroupSyncField.projectId.key] = projectId.uuidString
        let zone = MembershipZone(
            zoneID: Self.zoneID,
            records: [connectionRecord, groupRecord],
            token: try MembershipZone.makeChangeToken()
        )

        let unwritable = coordinator(writable: false, zone: zone)
        #expect(await unwritable.runSyncCycle() == nil)
        #expect(stored(connection) != nil)
        #expect(stored(connection)?.projectId == nil)
        #expect(environment.groups.group(for: group.id)?.projectId == nil)
        #expect(await unwritable.runSyncCycle() == nil)
        #expect(await zone.pulls == [.full, .delta])

        let writable = coordinator(writable: true, zone: zone)
        #expect(await writable.runSyncCycle() == nil)

        #expect(await zone.pulls == [.full, .delta, .full])
        #expect(stored(connection)?.projectId == projectId)
        #expect(environment.groups.group(for: group.id)?.projectId == projectId)
        #expect(await writable.runSyncCycle() == nil)
        #expect(await zone.pulls == [.full, .delta, .full, .delta])
    }

    // MARK: - A project this Mac cannot read

    private static let unreadableProjectId = UUID()
    private static let unreadableProjectJSON = #"{"id":"\#(unreadableProjectId.uuidString)","name":7,"shape":2}"#

    // Written before anything loads the store, so it keeps the record it cannot read.
    private func writeUnreadableProject() {
        environment.defaults.set(Data("[\(Self.unreadableProjectJSON)]".utf8), forKey: "com.TablePro.projects")
        #expect(environment.projects.unreadableProjectIds == [Self.unreadableProjectId])
    }

    private func unreadableProjectRow() throws -> NSDictionary? {
        let data = try #require(environment.defaults.data(forKey: "com.TablePro.projects"))
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [NSDictionary])
        return rows.first { $0["id"] as? String == Self.unreadableProjectId.uuidString }
    }

    private var originalProjectRow: NSDictionary? {
        try? JSONSerialization.jsonObject(with: Data(Self.unreadableProjectJSON.utf8)) as? NSDictionary
    }

    @Test("A pulled change to a project this Mac cannot read is held and kept out of the cache")
    func changeToAnUnreadableProjectIsHeld() async throws {
        writeUnreadableProject()
        let remote = ConnectionProject(id: Self.unreadableProjectId, name: "Renamed elsewhere")
        let recordID = Self.recordID(.project, Self.unreadableProjectId)

        let applied = await coordinator(writable: true).applyPullResult(
            Self.pull([Self.projectRecord(remote)]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.projects.loadProjects().isEmpty)
        #expect(try unreadableProjectRow() == originalProjectRow)
        #expect(environment.metadata.changesHeldForUnreadableCopies == [recordID.recordName])
        #expect(environment.recordCache.record(for: recordID) == nil)
    }

    @Test("The upload mark of a project this Mac cannot read waits for a build that can push it")
    func uploadMarkOfAnUnreadableProjectIsHeld() async throws {
        writeUnreadableProject()
        environment.tracker.markDirty(.project, id: Self.unreadableProjectId.uuidString)
        let coordinator = coordinator(writable: true)

        let batch = await coordinator.collectPushBatch(
            snapshot: environment.tracker.editSnapshot(),
            boundary: coordinator.syncBoundary(settings: .default),
            zoneID: Self.zoneID
        )

        #expect(batch.records.isEmpty)
        #expect(environment.tracker.dirtyRecords(for: .project).contains(Self.unreadableProjectId.uuidString))
    }

    @Test("A deletion from iCloud removes a project this Mac cannot read and forgets the change held for it")
    func deletionRemovesAnUnreadableProject() async throws {
        writeUnreadableProject()
        let recordID = Self.recordID(.project, Self.unreadableProjectId)
        environment.metadata.changesHeldForUnreadableCopies = [recordID.recordName]

        let applied = await coordinator(writable: true).applyPullResult(
            Self.pull([], deleted: [recordID]),
            settings: .default
        )

        #expect(applied)
        #expect(try unreadableProjectRow() == nil)
        #expect(environment.projects.unreadableProjectIds.isEmpty)
        #expect(environment.metadata.changesHeldForUnreadableCopies.isEmpty)
    }

    // MARK: - A tag this Mac cannot read

    @Test("A deletion from iCloud removes a tag this Mac cannot read by its id and forgets the change held for it")
    func deletionRemovesAnUnreadableTag() async throws {
        let unreadableId = UUID()
        // A save drops what the tag store read when it was built, so its next read is of the payload below.
        #expect(environment.tags.saveTags(ConnectionTag.presets))
        environment.tracker.clearAllDirty(.tag)
        let readable = ConnectionTag(name: "billing", color: .orange)
        let encoded = String(decoding: try JSONEncoder().encode(readable), as: UTF8.self)
        let unreadable = #"{"id":"\#(unreadableId.uuidString)","name":7,"shape":2}"#
        environment.defaults.set(Data("[\(encoded),\(unreadable)]".utf8), forKey: "com.TablePro.tags")
        #expect(environment.tags.loadTags().map(\.id) == [readable.id])
        #expect(environment.tags.unreadableTagIds == [unreadableId])
        let recordID = Self.recordID(.tag, unreadableId)
        environment.metadata.changesHeldForUnreadableCopies = [recordID.recordName]

        let applied = await coordinator(writable: false).applyPullResult(
            Self.pull([], deleted: [recordID]),
            settings: .default
        )

        #expect(applied)
        #expect(environment.tags.unreadableTagIds.isEmpty)
        #expect(environment.tags.loadTags().map(\.id) == [readable.id])
        let data = try #require(environment.defaults.data(forKey: "com.TablePro.tags"))
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [NSDictionary])
        #expect(rows.compactMap { $0["id"] as? String } == [readable.id.uuidString])
        #expect(environment.metadata.changesHeldForUnreadableCopies.isEmpty)
    }
}

// A zone nothing changes in: a full fetch lists its records and a pull from a token brings nothing.
private actor MembershipZone: SyncTransport {
    enum Pull: Equatable {
        case full
        case delta
    }

    let currentZoneID: CKRecordZone.ID
    private let records: [CKRecord]
    private let token: CKServerChangeToken
    private(set) var pulls: [Pull] = []

    init(zoneID: CKRecordZone.ID, records: [CKRecord], token: CKServerChangeToken) {
        currentZoneID = zoneID
        self.records = records
        self.token = token
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        ScriptedSyncTransport.accountId
    }

    func ensureZoneExists() async throws {}

    func saveSubscription() async throws {}

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        var outcome = PushOutcome()
        for record in records {
            outcome.recordSave(record)
        }
        for recordID in deletions {
            outcome.recordDeletion(recordID)
        }
        return outcome
    }

    func fetch(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        [:]
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pulls.append(token == nil ? .full : .delta)
        return PullResult(changedRecords: token == nil ? records : [], deletedRecordIDs: [], newToken: self.token)
    }

    // CKServerChangeToken has no public initializer, so a test token is decoded from an archive that names its class.
    static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: MembershipZoneChangeTokenArchive.self)
        archiver.encode(MembershipZoneChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

@objc(SyncProjectMembershipTestsChangeTokenArchive)
private final class MembershipZoneChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
