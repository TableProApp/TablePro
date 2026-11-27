import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncRecordMapperProjectTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    // The mapper writes only fields in Production, so a record another build wrote is built by key.
    private func projectRecord(_ project: ConnectionProject) -> CKRecord {
        let record = CKRecord(
            recordType: SyncRecordType.project.rawValue,
            recordID: SyncRecordMapper.recordID(type: .project, id: project.id.uuidString, in: zoneID)
        )
        record[ConnectionProjectSyncField.projectId.key] = project.id.uuidString
        record[ConnectionProjectSyncField.name.key] = project.name
        record[ConnectionProjectSyncField.color.key] = project.color.rawValue
        record[ConnectionProjectSyncField.iconName.key] = project.iconName
        record[ConnectionProjectSyncField.sortOrder.key] = Int64(project.sortOrder)
        return record
    }

    @Test("A project record reads back its name, color, icon and order")
    func readsAProject() throws {
        let project = ConnectionProject(name: "Acme", color: .blue, iconName: "briefcase", sortOrder: 4)

        #expect(SyncRecordMapper.toProject(projectRecord(project)) == project)
    }

    @Test("A project record with no id or no name is skipped")
    func skipsAnIncompleteProject() {
        let record = projectRecord(ConnectionProject(name: "Acme"))
        record[ConnectionProjectSyncField.name.key] = nil

        #expect(SyncRecordMapper.toProject(record) == nil)
    }

    @Test("A project record is named by its type prefix and id")
    func recordName() {
        let project = ConnectionProject(name: "Acme")

        let record = SyncRecordMapper.toCKRecord(project, in: zoneID)

        #expect(record.recordType == "ConnectionProject")
        #expect(record.recordID.recordName == "Project_\(project.id.uuidString)")
    }

    @Test("Nothing of a project is written while its fields are not in Production")
    func writesNothingUnverified() {
        let record = SyncRecordMapper.toCKRecord(ConnectionProject(name: "Acme", color: .red), in: zoneID)

        let unverified = ConnectionProjectSyncField.allCases.filter { !$0.isWritable }.map(\.key)
        for key in unverified {
            #expect(record[key] == nil)
        }
    }

    @Test("A connection's project is read only when asked, and written only once the field is in Production")
    func connectionProject() throws {
        let projectId = UUID()
        let connection = DatabaseConnection(name: "a", projectId: projectId)
        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        #expect((record[ConnectionSyncField.projectId.key] != nil) == ConnectionSyncField.projectId.isWritable)

        record[ConnectionSyncField.projectId.key] = projectId.uuidString

        #expect(try SyncRecordMapper.toConnection(record, readsProject: true).projectId == projectId)
        #expect(try SyncRecordMapper.toConnection(record, readsProject: false).projectId == nil)
    }

    @Test("A group's project is read only when asked, and written only once the field is in Production")
    func groupProject() throws {
        let projectId = UUID()
        let group = ConnectionGroup(name: "Production", projectId: projectId)
        let record = SyncRecordMapper.toCKRecord(group, in: zoneID)
        #expect((record[ConnectionGroupSyncField.projectId.key] != nil) == ConnectionGroupSyncField.projectId.isWritable)

        record[ConnectionGroupSyncField.projectId.key] = projectId.uuidString

        #expect(SyncRecordMapper.toGroup(record, readsProject: true)?.projectId == projectId)
        #expect(SyncRecordMapper.toGroup(record, readsProject: false)?.projectId == nil)
    }
}
