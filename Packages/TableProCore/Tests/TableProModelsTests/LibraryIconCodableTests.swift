import Foundation
import Testing

@testable import TableProModels

@Suite("Connection and group icons on disk")
struct LibraryIconCodableTests {
    private static let connectionWithoutIcon = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Prod","type":"PostgreSQL","host":"db.local",\
    "port":5432,"username":"app","database":"prod","color":"Red"}
    """

    private static let groupWithoutIcon = """
    {"id":"7A9619FF-8B86-D011-B42D-00C04FC964FF","name":"Clients","sortOrder":3,"color":"Blue"}
    """

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test("A connection keeps its icon through a save and a load")
    func connectionRoundTrips() throws {
        let connection = DatabaseConnection(name: "Prod", type: .postgresql, color: .red, iconName: "flame")

        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(connection))

        #expect(decoded.iconName == "flame")
        #expect(decoded.color == .red)
    }

    @Test("A connection saved before icons existed loads with no icon")
    func connectionOldPayloadDecodes() throws {
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: Data(Self.connectionWithoutIcon.utf8))

        #expect(decoded.iconName == nil)
        #expect(decoded.name == "Prod")
        #expect(decoded.color == .red)
    }

    @Test("A connection with no icon writes no icon key")
    func connectionWithoutIconOmitsKey() throws {
        let object = try jsonObject(DatabaseConnection(name: "Prod", type: .mysql))

        #expect(object["iconName"] == nil)
    }

    @Test("A group keeps its icon through a save and a load")
    func groupRoundTrips() throws {
        let parentId = UUID()
        let group = ConnectionGroup(name: "Clients", sortOrder: 2, color: .purple, iconName: "briefcase", parentId: parentId)

        let object = try jsonObject(group)
        let decoded = try JSONDecoder().decode(ConnectionGroup.self, from: JSONEncoder().encode(group))

        #expect(object["iconName"] as? String == "briefcase")
        #expect(decoded == group)
        #expect(decoded.iconName == "briefcase")
        #expect(decoded.parentId == parentId)
    }

    @Test("A group saved before icons existed loads with no icon")
    func groupOldPayloadDecodes() throws {
        let decoded = try JSONDecoder().decode(ConnectionGroup.self, from: Data(Self.groupWithoutIcon.utf8))

        #expect(decoded.iconName == nil)
        #expect(decoded.name == "Clients")
        #expect(decoded.sortOrder == 3)
        #expect(decoded.color == .blue)
    }
}
