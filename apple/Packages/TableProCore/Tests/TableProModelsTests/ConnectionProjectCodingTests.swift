import Foundation
import Testing

@testable import TableProModels

struct ConnectionProjectCodingTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func keys<Value: Encodable>(_ value: Value) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return Set((object as? [String: Any] ?? [:]).keys)
    }

    @Test("A project keeps every field through a save and a load")
    func projectRoundTrips() throws {
        let project = ConnectionProject(name: "Acme", sortOrder: 2, color: .blue, iconName: "shippingbox")

        let decoded = try JSONDecoder().decode(ConnectionProject.self, from: JSONEncoder().encode(project))

        #expect(decoded == project)
    }

    @Test("A project with only an id and a name decodes")
    func minimalProjectDecodes() throws {
        let project = try decode(
            ConnectionProject.self,
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Acme"}"#
        )

        #expect(project.name == "Acme")
        #expect(project.sortOrder == 0)
        #expect(project.color == .none)
        #expect(project.iconName == nil)
    }

    @Test("A connection saved before projects decodes with no project")
    func oldConnectionDecodes() throws {
        let connection = try decode(DatabaseConnection.self, """
        {"id":"00000000-0000-0000-0000-000000000002","name":"Orders","type":"PostgreSQL","host":"db","port":5432,
         "username":"app","database":"orders","groupId":"00000000-0000-0000-0000-000000000003"}
        """)

        #expect(connection.projectId == nil)
        #expect(connection.groupId != nil)
    }

    @Test("A connection's project survives a save and a load, and is written only when set")
    func connectionProjectRoundTrips() throws {
        var connection = DatabaseConnection(name: "Orders")
        #expect(try !keys(connection).contains("projectId"))

        connection.projectId = UUID()
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(connection))

        #expect(decoded.projectId == connection.projectId)
        #expect(decoded == connection)
    }

    @Test("A group saved before projects decodes with no project")
    func oldGroupDecodes() throws {
        let group = try decode(
            ConnectionGroup.self,
            #"{"id":"00000000-0000-0000-0000-000000000004","name":"Production","sortOrder":1,"color":"Red"}"#
        )

        #expect(group.projectId == nil)
        #expect(group.name == "Production")
    }

    @Test("A group's project survives a save and a load, and is written only when set")
    func groupProjectRoundTrips() throws {
        var group = ConnectionGroup(name: "Production")
        #expect(try !keys(group).contains("projectId"))

        group.projectId = UUID()
        let decoded = try JSONDecoder().decode(ConnectionGroup.self, from: JSONEncoder().encode(group))

        #expect(decoded == group)
    }

    // The previous stable has no `projectId` key, so it reads the new file and drops the key on its next save.
    @Test("The shape before projects reads a file that carries them")
    func previousShapeReadsNewFile() throws {
        struct PreviousGroup: Decodable {
            let id: UUID
            let name: String
            let parentId: UUID?
        }
        let group = ConnectionGroup(name: "Production", projectId: UUID())

        let previous = try JSONDecoder().decode(PreviousGroup.self, from: JSONEncoder().encode(group))

        #expect(previous.id == group.id)
        #expect(previous.name == "Production")
    }
}
