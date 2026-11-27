import Foundation
@testable import TablePro
import Testing

struct StoredConnectionProjectTests {
    private func object(_ connection: DatabaseConnection) throws -> [String: Any] {
        let data = try JSONEncoder().encode(StoredConnection(from: connection))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A connection's project round trips through the stored record")
    func roundTrip() throws {
        let projectId = UUID()
        let connection = DatabaseConnection(name: "Local", projectId: projectId)

        let data = try JSONEncoder().encode(StoredConnection(from: connection))
        let decoded = try JSONDecoder().decode(StoredConnection.self, from: data)

        #expect(decoded.toConnection().projectId == projectId)
    }

    @Test("A connection in no project writes no project key, so the file matches what the previous build wrote")
    func noKeyWithoutAProject() throws {
        #expect(try object(DatabaseConnection(name: "Local"))["projectId"] == nil)
        #expect(try object(DatabaseConnection(name: "Local", projectId: UUID()))["projectId"] is String)
    }

    @Test("A record the previous build wrote reads as in no project")
    func readsARecordWithoutTheKey() throws {
        var json = try object(DatabaseConnection(name: "Local", groupId: UUID(), projectId: UUID()))
        json.removeValue(forKey: "projectId")

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(StoredConnection.self, from: data).toConnection()

        #expect(decoded.projectId == nil)
        #expect(decoded.groupId != nil)
        #expect(decoded.name == "Local")
    }

    @Test("A group the previous build wrote reads as in no project, and a group in none writes no key")
    func groupsReadAndWriteWithoutTheKey() throws {
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","name":"Production","color":"Red","sortOrder":2}]"#

        let decoded = try JSONDecoder().decode([ConnectionGroup].self, from: Data(old.utf8))
        #expect(decoded.first?.projectId == nil)
        #expect(decoded.first?.sortOrder == 2)

        let written = try JSONEncoder().encode(ConnectionGroup(name: "Production"))
        let fields = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(fields["projectId"] == nil)
    }

    // The previous stable ignores keys it does not know, so it still opens the file. It drops the project
    // on its next save of the record, which is the stated cost of keeping membership on the record.
    @Test("A reader that knows no project key still reads a record that carries one")
    func olderReaderIgnoresTheKey() throws {
        struct PreviousGroup: Decodable {
            let id: UUID
            let name: String
            let parentId: UUID?
            let sortOrder: Int
        }
        let group = ConnectionGroup(name: "Production", sortOrder: 1, projectId: UUID())

        let read = try JSONDecoder().decode(PreviousGroup.self, from: JSONEncoder().encode(group))

        #expect(read.id == group.id)
        #expect(read.name == "Production")
    }
}
