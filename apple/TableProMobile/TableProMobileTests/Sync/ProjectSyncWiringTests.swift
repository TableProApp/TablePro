import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
struct ProjectSyncWiringTests {
    private let fixture: AppStateFixture
    private let zoneID = CKRecordZone.ID(zoneName: "RecordingZone", ownerName: CKCurrentUserDefaultName)
    private let project = ConnectionProject(name: "Acme")

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeState(transport: RecordingSyncTransport, writable: Bool) -> AppState {
        let state = fixture.makeState(syncEnabled: true, transport: transport, projectSyncWritable: writable)
        state.connectSync()
        return state
    }

    // A library with one project holding a top-level group and an ungrouped connection, with nothing waiting to upload.
    private func seed(_ state: AppState) -> (group: ConnectionGroup, connection: DatabaseConnection) {
        #expect(state.addImportedProject(project))
        let group = ConnectionGroup(name: "Production", projectId: project.id)
        let connection = DatabaseConnection(name: "Orders", type: .postgresql, host: "db.example.com", projectId: project.id)
        #expect(state.addGroup(group).isSaved)
        #expect(state.addConnection(connection))
        for type in [SyncRecordType.project, .group, .connection] {
            fixture.metadata.clearDirty(type: type)
        }
        return (group, connection)
    }

    // The server's fields are written raw: the mapper leaves out what Production does not hold yet.
    private func projectRecord(_ project: ConnectionProject) -> CKRecord {
        let id = SyncRecordMapper.recordID(type: .project, id: project.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.project.rawValue, recordID: id)
        record["projectId"] = project.id.uuidString as CKRecordValue
        record["name"] = project.name as CKRecordValue
        record["sortOrder"] = Int64(project.sortOrder) as CKRecordValue
        return record
    }

    @Test("While project sync is off, a pulled connection and group keep the project this device stores")
    func pullKeepsLocalMembershipWhileUnwritable() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: false)
        let seeded = seed(state)
        var renamed = seeded.connection
        renamed.name = "Orders (renamed on the Mac)"
        var recolored = seeded.group
        recolored.color = .blue
        await transport.answerPulls(with: [
            SyncRecordMapper.toRecord(renamed, zoneID: zoneID),
            SyncRecordMapper.toRecord(recolored, zoneID: zoneID)
        ])

        await state.syncCoordinator.sync()

        let connection = try #require(state.connections.first)
        let group = try #require(state.groups.first)
        #expect(connection.name == "Orders (renamed on the Mac)")
        #expect(connection.projectId == project.id)
        #expect(group.color == .blue)
        #expect(group.projectId == project.id)
        #expect(!fixture.defaults.bool(forKey: IOSSyncCoordinator.membershipUploadedKey))
    }

    @Test("Once project sync is on, a pulled record's project replaces the stored one")
    func pullReadsMembershipOnceWritable() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: true)
        let seeded = seed(state)
        fixture.defaults.set(true, forKey: IOSSyncCoordinator.membershipUploadedKey)
        let other = UUID()
        let record = SyncRecordMapper.toRecord(seeded.connection, zoneID: zoneID)
        record["projectId"] = other.uuidString as CKRecordValue
        record["name"] = "Moved on the Mac" as CKRecordValue
        await transport.answerPulls(with: [record])

        await state.syncCoordinator.sync()

        #expect(state.connections.first?.projectId == other)
    }

    @Test("The first run that can write projects uploads every project and member once, before its pull reads over them")
    func membershipUploadsOnceWhenWritable() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: true)
        let seeded = seed(state)
        await transport.answerPulls(with: [
            SyncRecordMapper.toRecord(seeded.connection, zoneID: zoneID),
            SyncRecordMapper.toRecord(seeded.group, zoneID: zoneID)
        ])

        await state.syncCoordinator.sync()

        let pushed = Set(await transport.pushedRecords.map(\.recordID.recordName))
        #expect(pushed == [
            SyncRecordType.project.recordName(for: project.id.uuidString),
            SyncRecordType.group.recordName(for: seeded.group.id.uuidString),
            SyncRecordType.connection.recordName(for: seeded.connection.id.uuidString)
        ])
        let uploaded = await transport.pushedRecords
        for record in uploaded where record.recordType != SyncRecordType.project.rawValue {
            #expect(record["projectId"] as? String == project.id.uuidString)
        }
        #expect(state.connections.first?.projectId == project.id)
        #expect(state.groups.first?.projectId == project.id)
        #expect(fixture.defaults.bool(forKey: IOSSyncCoordinator.membershipUploadedKey))

        await transport.answerPulls(with: [])
        await state.syncCoordinator.sync()
        #expect(await transport.pushedRecords.count == 3)
    }

    // A group and a connection another device put in the project, pulled and cached while project sync was off, so
    // this device stores no project for either.
    private func pullMembersAssignedElsewhere(
        through transport: RecordingSyncTransport
    ) async throws -> (group: ConnectionGroup, connection: DatabaseConnection) {
        let group = ConnectionGroup(name: "Production")
        let connection = DatabaseConnection(name: "Orders", type: .postgresql, host: "db.example.com")
        let groupRecord = SyncRecordMapper.toRecord(group, zoneID: zoneID)
        groupRecord["projectId"] = project.id.uuidString as CKRecordValue
        let connectionRecord = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        connectionRecord["projectId"] = project.id.uuidString as CKRecordValue
        await transport.answerPulls(with: [projectRecord(project), groupRecord, connectionRecord])
        await transport.answerOnlyFullFetches()

        let unwritable = makeState(transport: transport, writable: false)
        await unwritable.syncCoordinator.sync()
        #expect(unwritable.connections.first?.projectId == nil)
        #expect(unwritable.groups.first?.projectId == nil)
        #expect(await transport.pushedRecords.isEmpty)
        return (group, connection)
    }

    private func lastPushed(_ type: SyncRecordType, _ id: UUID, by transport: RecordingSyncTransport) async throws -> CKRecord {
        let name = type.recordName(for: id.uuidString)
        let pushed = await transport.pushedRecords
        return try #require(pushed.last { $0.recordID.recordName == name })
    }

    @Test("The first run that can write projects keeps a project another device assigned when an unrelated edit goes up")
    func unrelatedEditKeepsAProjectAssignedElsewhere() async throws {
        let transport = RecordingSyncTransport(newToken: try RecordingSyncTransport.makeChangeToken())
        let members = try await pullMembersAssignedElsewhere(through: transport)

        let writable = makeState(transport: transport, writable: true)
        writable.renameConnection(members.connection.id, to: "Orders (renamed here)")
        #expect(writable.mutateGroup(members.group.id) { $0.color = .blue }.isSaved)
        await writable.syncCoordinator.sync()

        let pushedConnection = try await lastPushed(.connection, members.connection.id, by: transport)
        #expect(pushedConnection["name"] as? String == "Orders (renamed here)")
        #expect(pushedConnection["projectId"] as? String == project.id.uuidString)
        let pushedGroup = try await lastPushed(.group, members.group.id, by: transport)
        #expect(pushedGroup["color"] as? String == ConnectionColor.blue.rawValue)
        #expect(pushedGroup["projectId"] as? String == project.id.uuidString)
        #expect(writable.connections.first?.projectId == project.id)
        #expect(writable.groups.first?.projectId == project.id)
    }

    @Test("A project removed here after that first run is removed in iCloud")
    func removalAfterTheFirstRunGoesUp() async throws {
        let transport = RecordingSyncTransport(newToken: try RecordingSyncTransport.makeChangeToken())
        let members = try await pullMembersAssignedElsewhere(through: transport)
        let writable = makeState(transport: transport, writable: true)
        await writable.syncCoordinator.sync()
        #expect(writable.connections.first?.projectId == project.id)
        #expect(writable.groups.first?.projectId == project.id)
        let seeded = await transport.pushedRecords
        #expect(seeded.allSatisfy { $0.recordType == SyncRecordType.project.rawValue })

        writable.moveToProject(nil, connections: [members.connection.id], groups: [members.group.id])
        await writable.syncCoordinator.sync()

        let pushedConnection = try await lastPushed(.connection, members.connection.id, by: transport)
        #expect(pushedConnection.changedKeys().contains("projectId"))
        #expect(pushedConnection["projectId"] == nil)
        let pushedGroup = try await lastPushed(.group, members.group.id, by: transport)
        #expect(pushedGroup.changedKeys().contains("projectId"))
        #expect(pushedGroup["projectId"] == nil)
        #expect(writable.connections.first?.projectId == nil)
        #expect(writable.groups.first?.projectId == nil)
    }

    @Test("A pulled project joins the list, and a local edit to one goes up")
    func projectsPullAndPush() async throws {
        let remote = ConnectionProject(name: "From the Mac", sortOrder: 2)
        let transport = RecordingSyncTransport(remoteRecords: [projectRecord(remote)])
        let state = makeState(transport: transport, writable: true)
        guard case .applied(let localId) = state.addProject(named: "Local") else {
            Issue.record("the project was not added")
            return
        }

        await state.syncCoordinator.sync()

        #expect(Set(state.projects.map(\.name)) == ["Local", "From the Mac"])
        let pushed = await transport.pushedRecords.map(\.recordID.recordName)
        #expect(pushed == [SyncRecordType.project.recordName(for: localId.uuidString)])
    }

    @Test("A project deleted on another device goes, its members stay in no project, and the list shows everything")
    func remoteProjectDeletionClearsMembership() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: true)
        let seeded = seed(state)
        fixture.defaults.set(true, forKey: IOSSyncCoordinator.membershipUploadedKey)
        state.setActiveProject(project.id)
        await transport.answerPulls(
            with: [],
            deletions: [SyncRecordMapper.recordID(type: .project, id: project.id.uuidString, in: zoneID)]
        )

        await state.syncCoordinator.sync()

        #expect(state.projects.isEmpty)
        #expect(state.connections.first { $0.id == seeded.connection.id }?.projectId == nil)
        #expect(state.groups.first?.projectId == nil)
        #expect(state.activeProjectId == nil)
        #expect(state.scopedConnections.count == 1)

        let relaunched = fixture.makeState(syncEnabled: false)
        #expect(relaunched.projects.isEmpty)
        #expect(relaunched.connections.first?.projectId == nil)
    }

    @Test("A group deleted on another device hands its project to the connections and subgroups it leaves here")
    func remoteGroupDeletionKeepsMembership() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: true)
        let seeded = seed(state)
        fixture.defaults.set(true, forKey: IOSSyncCoordinator.membershipUploadedKey)
        let subgroup = ConnectionGroup(name: "EU", parentId: seeded.group.id)
        let held = DatabaseConnection(name: "Held", type: .postgresql, host: "held.example.com", groupId: seeded.group.id)
        let nested = DatabaseConnection(name: "Nested", type: .postgresql, host: "nested.example.com", groupId: subgroup.id)
        #expect(state.addGroup(subgroup).isSaved)
        #expect(state.addConnection(held))
        #expect(state.addConnection(nested))
        state.setActiveProject(project.id)
        await transport.answerPulls(
            with: [],
            deletions: [SyncRecordMapper.recordID(type: .group, id: seeded.group.id.uuidString, in: zoneID)]
        )

        await state.syncCoordinator.sync()

        #expect(state.groups.map(\.id) == [subgroup.id])
        #expect(state.groups.first?.projectId == project.id)
        let kept = try #require(state.connections.first { $0.id == held.id })
        #expect(kept.groupId == nil)
        #expect(kept.projectId == project.id)
        #expect(state.connections.first { $0.id == nested.id }?.groupId == subgroup.id)
        #expect(Set(state.scopedConnections.map(\.id)) == [seeded.connection.id, held.id, nested.id])

        let relaunched = fixture.makeState(syncEnabled: false)
        #expect(relaunched.connections.first { $0.id == held.id }?.projectId == project.id)
    }

    // A group holding a connection and a subgroup with its own connection, with nothing waiting to upload.
    private func seedMembers(
        of group: ConnectionGroup,
        in state: AppState
    ) -> (held: DatabaseConnection, subgroup: ConnectionGroup, nested: DatabaseConnection) {
        let subgroup = ConnectionGroup(name: "EU", parentId: group.id)
        let held = DatabaseConnection(name: "Held", type: .postgresql, host: "held.example.com", groupId: group.id)
        let nested = DatabaseConnection(name: "Nested", type: .postgresql, host: "nested.example.com", groupId: subgroup.id)
        #expect(state.addGroup(subgroup).isSaved)
        #expect(state.addConnection(held))
        #expect(state.addConnection(nested))
        for type in [SyncRecordType.group, .connection] {
            fixture.metadata.clearDirty(type: type)
        }
        return (held, subgroup, nested)
    }

    // What the device that deleted the group uploads: its tombstone, and each member without the group.
    private func releasedRecords(held: DatabaseConnection, subgroup: ConnectionGroup) -> [CKRecord] {
        var releasedConnection = held
        releasedConnection.groupId = nil
        var releasedGroup = subgroup
        releasedGroup.parentId = nil
        return [
            SyncRecordMapper.toRecord(releasedConnection, zoneID: zoneID),
            SyncRecordMapper.toRecord(releasedGroup, zoneID: zoneID)
        ]
    }

    @Test("While project sync is off, a pull that releases a group's members and deletes the group keeps them in its project")
    func memberUpdateAndGroupDeletionInOnePull() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: false)
        let seeded = seed(state)
        let members = seedMembers(of: seeded.group, in: state)
        state.setActiveProject(project.id)
        await transport.answerPulls(
            with: releasedRecords(held: members.held, subgroup: members.subgroup),
            deletions: [SyncRecordMapper.recordID(type: .group, id: seeded.group.id.uuidString, in: zoneID)]
        )

        await state.syncCoordinator.sync()

        let held = try #require(state.connections.first { $0.id == members.held.id })
        #expect(held.groupId == nil)
        #expect(held.projectId == project.id)
        let subgroup = try #require(state.groups.first { $0.id == members.subgroup.id })
        #expect(state.groups.map(\.id) == [members.subgroup.id])
        #expect(subgroup.parentId == nil)
        #expect(subgroup.projectId == project.id)
        #expect(state.connections.first { $0.id == members.nested.id }?.groupId == members.subgroup.id)
        #expect(Set(state.scopedConnections.map(\.id)) == [seeded.connection.id, members.held.id, members.nested.id])

        let relaunched = fixture.makeState(syncEnabled: false)
        #expect(relaunched.connections.first { $0.id == members.held.id }?.projectId == project.id)
        #expect(relaunched.groups.first?.projectId == project.id)
    }

    @Test("Once project sync is on, a released member takes the project its own record carries")
    func releasedMemberRecordIsAuthoritativeOnceWritable() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: true)
        let seeded = seed(state)
        fixture.defaults.set(true, forKey: IOSSyncCoordinator.membershipUploadedKey)
        let members = seedMembers(of: seeded.group, in: state)
        let other = UUID()
        let records = releasedRecords(held: members.held, subgroup: members.subgroup)
        records[0]["projectId"] = other.uuidString as CKRecordValue
        await transport.answerPulls(
            with: records,
            deletions: [SyncRecordMapper.recordID(type: .group, id: seeded.group.id.uuidString, in: zoneID)]
        )

        await state.syncCoordinator.sync()

        #expect(state.connections.first { $0.id == members.held.id }?.projectId == other)
        #expect(state.groups.first { $0.id == members.subgroup.id }?.projectId == nil)
    }

    @Test("Membership pulled while project sync was off is fetched again and applied by the first run that reads it")
    func membershipSkippedWhileUnwritableIsRefetched() async throws {
        let group = ConnectionGroup(name: "Production")
        let connection = DatabaseConnection(name: "Orders", type: .postgresql, host: "db.example.com")
        let groupRecord = SyncRecordMapper.toRecord(group, zoneID: zoneID)
        groupRecord["projectId"] = project.id.uuidString as CKRecordValue
        let connectionRecord = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        connectionRecord["projectId"] = project.id.uuidString as CKRecordValue
        let transport = RecordingSyncTransport(
            remoteRecords: [projectRecord(project), groupRecord, connectionRecord],
            newToken: try RecordingSyncTransport.makeChangeToken()
        )
        await transport.answerOnlyFullFetches()

        let unwritable = makeState(transport: transport, writable: false)
        await unwritable.syncCoordinator.sync()
        #expect(unwritable.connections.first?.projectId == nil)
        #expect(unwritable.groups.first?.projectId == nil)
        #expect(fixture.metadata.loadToken() != nil)
        await unwritable.syncCoordinator.sync()
        #expect(await transport.fullFetchCount == 1)

        let writable = makeState(transport: transport, writable: true)
        await writable.syncCoordinator.sync()

        #expect(await transport.fullFetchCount == 2)
        #expect(writable.connections.first?.projectId == project.id)
        #expect(writable.groups.first?.projectId == project.id)
        await writable.syncCoordinator.sync()
        #expect(await transport.fullFetchCount == 2)
    }

    @Test("The readable set names projects and the membership fields only while a pull reads them")
    func readableSetFollowsTheGate() {
        let closed = IOSSyncCoordinator.readableRecordTypes(projectSyncWritable: false)
        let open = IOSSyncCoordinator.readableRecordTypes(projectSyncWritable: true)

        #expect(!closed.contains(SyncRecordType.project.rawValue))
        #expect(!closed.contains(ConnectionSyncField.projectContentKind))
        #expect(!closed.contains(ConnectionGroupSyncField.projectContentKind))
        #expect(open == closed.union([
            SyncRecordType.project.rawValue,
            ConnectionSyncField.projectContentKind,
            ConnectionGroupSyncField.projectContentKind
        ]))
    }

    @Test("While project sync is off, a pulled project and a project's deletion leave the projects and the scope as they are")
    func projectRecordsWaitWhileUnwritable() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: false)
        let seeded = seed(state)
        state.setActiveProject(project.id)
        let arriving = ConnectionProject(name: "From the Mac")
        await transport.answerPulls(
            with: [projectRecord(arriving)],
            deletions: [SyncRecordMapper.recordID(type: .project, id: project.id.uuidString, in: zoneID)]
        )

        await state.syncCoordinator.sync()

        #expect(state.projects.map(\.name) == ["Acme"])
        #expect(state.activeProjectId == project.id)
        #expect(state.connections.first { $0.id == seeded.connection.id }?.projectId == project.id)
        #expect(state.groups.first?.projectId == project.id)
    }

    @Test("A group and its project deleted in one pull leave the connection in no project and no group")
    func remoteGroupAndProjectDeletion() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: true)
        let seeded = seed(state)
        fixture.defaults.set(true, forKey: IOSSyncCoordinator.membershipUploadedKey)
        let held = DatabaseConnection(name: "Held", type: .postgresql, host: "held.example.com", groupId: seeded.group.id)
        #expect(state.addConnection(held))
        await transport.answerPulls(
            with: [],
            deletions: [
                SyncRecordMapper.recordID(type: .group, id: seeded.group.id.uuidString, in: zoneID),
                SyncRecordMapper.recordID(type: .project, id: project.id.uuidString, in: zoneID)
            ]
        )

        await state.syncCoordinator.sync()

        let kept = try #require(state.connections.first { $0.id == held.id })
        #expect(kept.groupId == nil)
        #expect(kept.projectId == nil)
        #expect(state.groups.isEmpty)
        #expect(state.projects.isEmpty)
    }

    @Test("A project deleted here is deleted in iCloud")
    func localProjectDeletionPushesATombstone() async throws {
        let transport = RecordingSyncTransport()
        let state = makeState(transport: transport, writable: false)
        _ = seed(state)

        state.deleteProject(project.id)
        await state.syncCoordinator.sync()

        let deleted = await transport.pushedDeletions.map(\.recordName)
        #expect(deleted == [SyncRecordType.project.recordName(for: project.id.uuidString)])
    }
}
