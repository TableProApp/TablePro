import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

struct SyncRecordMapperProjectTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let projectId = UUID()

    // Written past the gate, as a build after the Production deploy writes it.
    private func connectionRecord(_ connection: DatabaseConnection, projectId: UUID?) -> CKRecord {
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        record[ConnectionSyncField.projectId.key] = projectId?.uuidString
        return record
    }

    private func groupRecord(_ group: ConnectionGroup, projectId: UUID?) -> CKRecord {
        let record = SyncRecordMapper.toRecord(group, zoneID: zoneID)
        record[ConnectionGroupSyncField.projectId.key] = projectId?.uuidString
        return record
    }

    private func projectRecord(id: UUID, name: String?) -> CKRecord {
        let recordID = SyncRecordMapper.recordID(type: .project, id: id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.project.rawValue, recordID: recordID)
        record[ConnectionProjectSyncField.projectId.key] = id.uuidString
        record[ConnectionProjectSyncField.name.key] = name
        return record
    }

    @Test("A project record maps to a project")
    func projectFromRecord() throws {
        let record = projectRecord(id: projectId, name: "Acme")
        record[ConnectionProjectSyncField.color.key] = ConnectionColor.blue.rawValue
        record[ConnectionProjectSyncField.iconName.key] = "shippingbox"
        record[ConnectionProjectSyncField.sortOrder.key] = Int64(3)

        let project = try #require(SyncRecordMapper.toProject(record))

        #expect(project == ConnectionProject(
            id: projectId, name: "Acme", sortOrder: 3, color: .blue, iconName: "shippingbox"
        ))
    }

    @Test("A project record with no name does not map")
    func projectNeedsAName() {
        #expect(SyncRecordMapper.toProject(projectRecord(id: projectId, name: nil)) == nil)
    }

    @Test("A project is written only through the fields Production holds")
    func projectWritesOnlyDeployedFields() {
        let project = ConnectionProject(id: projectId, name: "Acme", sortOrder: 2, color: .red, iconName: "shippingbox")

        let record = SyncRecordMapper.toRecord(project, zoneID: zoneID)
        let updated = projectRecord(id: projectId, name: "Old")
        SyncRecordMapper.updateRecord(updated, with: project)

        #expect(record.recordType == "ConnectionProject")
        #expect(record.recordID.recordName == "Project_\(projectId.uuidString)")
        #expect(Set(record.allKeys()).isSubset(of: ConnectionProjectSyncField.writableKeys))
        if ConnectionProjectSyncField.name.isWritable {
            #expect(SyncRecordMapper.toProject(record)?.name == "Acme")
            #expect(SyncRecordMapper.toProject(updated)?.name == "Acme")
        } else {
            #expect(SyncRecordMapper.toProject(updated)?.name == "Old")
        }
    }

    @Test("A connection's project reaches the record only once the field is deployed")
    func connectionProjectIsGated() {
        let connection = DatabaseConnection(name: "Orders", projectId: projectId)

        let built = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        let updated = SyncRecordMapper.toRecord(DatabaseConnection(id: connection.id, name: "Orders"), zoneID: zoneID)
        SyncRecordMapper.updateRecord(updated, with: connection)

        let expected = ConnectionSyncField.projectId.isWritable ? projectId.uuidString : nil
        #expect(built[ConnectionSyncField.projectId.key] as? String == expected)
        #expect(updated[ConnectionSyncField.projectId.key] as? String == expected)
    }

    @Test("A group's project reaches the record only once the field is deployed")
    func groupProjectIsGated() {
        let group = ConnectionGroup(name: "Production", projectId: projectId)

        let built = SyncRecordMapper.toRecord(group, zoneID: zoneID)
        let updated = SyncRecordMapper.toRecord(ConnectionGroup(id: group.id, name: "Production"), zoneID: zoneID)
        SyncRecordMapper.updateRecord(updated, with: group)

        let expected = ConnectionGroupSyncField.projectId.isWritable ? projectId.uuidString : nil
        #expect(built[ConnectionGroupSyncField.projectId.key] as? String == expected)
        #expect(updated[ConnectionGroupSyncField.projectId.key] as? String == expected)
    }

    @Test("A schema that holds the project fields writes them, and one that does not leaves them out")
    func injectedSchemaDecidesTheProjectWrite() {
        let connection = DatabaseConnection(name: "Orders", projectId: projectId)
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        let project = ConnectionProject(id: projectId, name: "Acme")
        let deployed = SyncWritableSchema.projects(deployed: true)
        let heldBack = SyncWritableSchema.projects(deployed: false)

        #expect(deployed.writesProjects)
        #expect(!heldBack.writesProjects)
        #expect(SyncRecordMapper.toRecord(connection, zoneID: zoneID, schema: deployed)["projectId"] as? String == projectId.uuidString)
        #expect(SyncRecordMapper.toRecord(group, zoneID: zoneID, schema: deployed)["projectId"] as? String == projectId.uuidString)
        #expect(SyncRecordMapper.toRecord(project, zoneID: zoneID, schema: deployed)["name"] as? String == "Acme")
        #expect(SyncRecordMapper.toRecord(connection, zoneID: zoneID, schema: heldBack)["projectId"] == nil)
        #expect(SyncRecordMapper.toRecord(group, zoneID: zoneID, schema: heldBack)["projectId"] == nil)
        #expect(SyncRecordMapper.toRecord(project, zoneID: zoneID, schema: heldBack).allKeys().isEmpty)
    }

    @Test("Once the field is written, no project here against a project in the cached record is an edit that clears it")
    func noProjectOverACachedProjectIsAnEdit() throws {
        let connection = DatabaseConnection(name: "Orders")
        let group = ConnectionGroup(name: "Production")
        let deployed = SyncWritableSchema.projects(deployed: true)

        let connectionEdit = SyncRecordMapper.edit(
            connection, base: connectionRecord(connection, projectId: projectId), zoneID: zoneID, schema: deployed
        )
        let groupEdit = SyncRecordMapper.edit(
            group, base: groupRecord(group, projectId: projectId), zoneID: zoneID, schema: deployed
        )
        let heldBack = SyncRecordMapper.edit(
            connection,
            base: connectionRecord(connection, projectId: projectId),
            zoneID: zoneID,
            schema: .projects(deployed: false)
        )

        #expect(connectionEdit.editedKeys.contains("projectId"))
        #expect(connectionEdit.record["projectId"] == nil)
        #expect(groupEdit.editedKeys.contains("projectId"))
        #expect(!heldBack.editedKeys.contains("projectId"))
        #expect(heldBack.record["projectId"] as? String == projectId.uuidString)
    }

    @Test("While project sync is off a pulled connection keeps this device's project")
    func pulledConnectionKeepsLocalProject() throws {
        let local = DatabaseConnection(name: "Orders", projectId: projectId)
        var remote = local
        remote.name = "Renamed"
        remote.projectId = nil

        let pulled = try #require(SyncRecordMapper.pulledConnection(
            connectionRecord(remote, projectId: nil), over: local, projectSyncWritable: false
        ))
        let fromAnotherBuild = try #require(SyncRecordMapper.pulledConnection(
            connectionRecord(remote, projectId: UUID()), over: local, projectSyncWritable: false
        ))
        let unknownHere = try #require(SyncRecordMapper.pulledConnection(
            connectionRecord(remote, projectId: UUID()), over: nil, projectSyncWritable: false
        ))

        #expect(pulled.name == "Renamed")
        #expect(pulled.projectId == projectId)
        #expect(fromAnotherBuild.projectId == projectId)
        #expect(unknownHere.projectId == nil)
    }

    @Test("Once project sync is on a pulled connection takes the record's project")
    func pulledConnectionTakesRecordProject() throws {
        let local = DatabaseConnection(name: "Orders", projectId: projectId)
        let other = UUID()

        let moved = try #require(SyncRecordMapper.pulledConnection(
            connectionRecord(local, projectId: other), over: local, projectSyncWritable: true
        ))
        let cleared = try #require(SyncRecordMapper.pulledConnection(
            connectionRecord(local, projectId: nil), over: local, projectSyncWritable: true
        ))

        #expect(moved.projectId == other)
        #expect(cleared.projectId == nil)
    }

    @Test("While project sync is off a pulled group keeps this device's project")
    func pulledGroupKeepsLocalProject() throws {
        let local = ConnectionGroup(name: "Production", projectId: projectId)
        var remote = local
        remote.color = .red
        remote.projectId = nil

        let pulled = try #require(SyncRecordMapper.pulledGroup(
            groupRecord(remote, projectId: nil), over: local, projectSyncWritable: false
        ))

        #expect(pulled.color == .red)
        #expect(pulled.projectId == projectId)
    }

    @Test("Once project sync is on a pulled group takes the record's project")
    func pulledGroupTakesRecordProject() throws {
        let local = ConnectionGroup(name: "Production", projectId: projectId)
        let other = UUID()

        let moved = try #require(SyncRecordMapper.pulledGroup(
            groupRecord(local, projectId: other), over: local, projectSyncWritable: true
        ))
        let cleared = try #require(SyncRecordMapper.pulledGroup(
            groupRecord(local, projectId: nil), over: local, projectSyncWritable: true
        ))

        #expect(moved.projectId == other)
        #expect(cleared.projectId == nil)
    }

    @Test("The plain readers follow the deploy gate")
    func plainReadersFollowTheGate() throws {
        let connection = try #require(SyncRecordMapper.toConnection(
            connectionRecord(DatabaseConnection(name: "Orders"), projectId: projectId)
        ))
        let group = try #require(SyncRecordMapper.toGroup(
            groupRecord(ConnectionGroup(name: "Production"), projectId: projectId)
        ))

        let expected = SyncSchemaGate.isProjectSyncWritable ? projectId : nil
        #expect(connection.projectId == expected)
        #expect(group.projectId == expected)
    }
}

private extension SyncWritableSchema {
    // Production's schema with the project type and both membership fields deployed, or held back.
    static func projects(deployed: Bool) -> SyncWritableSchema {
        SyncWritableSchema(
            field: { field in
                let isProjectField = field is ConnectionProjectSyncField
                    || field.key == ConnectionSyncField.projectId.key
                return isProjectField ? deployed : field.isWritable
            },
            type: { $0 == .project ? deployed : $0.isWritable }
        )
    }
}
