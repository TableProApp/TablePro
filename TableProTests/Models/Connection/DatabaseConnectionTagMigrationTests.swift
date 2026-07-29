import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseConnection tag migration")
struct DatabaseConnectionTagMigrationTests {
    private func decode(_ json: [String: Any]) throws -> DatabaseConnection {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(DatabaseConnection.self, from: data)
    }

    @Test("Legacy single tagId promotes to tagIds")
    func legacyTagIdPromotes() throws {
        let tagId = UUID()
        let connection = try decode([
            "id": UUID().uuidString,
            "name": "Local",
            "tagId": tagId.uuidString,
        ])
        #expect(connection.tagIds == [tagId])
    }

    @Test("tagIds is preferred over legacy tagId when both present")
    func tagIdsPreferred() throws {
        let legacy = UUID()
        let a = UUID()
        let b = UUID()
        let connection = try decode([
            "id": UUID().uuidString,
            "name": "Local",
            "tagId": legacy.uuidString,
            "tagIds": [a.uuidString, b.uuidString],
        ])
        #expect(connection.tagIds == [a, b])
    }

    @Test("No tag keys decodes to empty array")
    func noTagsEmpty() throws {
        let connection = try decode([
            "id": UUID().uuidString,
            "name": "Local",
        ])
        #expect(connection.tagIds.isEmpty)
    }

    @Test("Encoding writes tagIds plus the first tag as legacy tagId for downgrade safety")
    func encodeWritesTagIdsAndLegacyFirst() throws {
        let a = UUID()
        let b = UUID()
        var connection = DatabaseConnection(name: "Local")
        connection.tagIds = [a, b]
        let data = try JSONEncoder().encode(connection)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["tagIds"] as? [String] == [a.uuidString, b.uuidString])
        #expect(object["tagId"] as? String == a.uuidString)
    }

    @Test("Empty tagIds omits the key on encode")
    func encodeEmptyOmitsKey() throws {
        let connection = DatabaseConnection(name: "Local")
        let data = try JSONEncoder().encode(connection)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["tagIds"] == nil)
    }
}
