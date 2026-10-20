import Foundation
import Testing

@testable import TableProModels

struct SavedQueryCodingTests {
    private let created = Date(timeIntervalSince1970: 1_000)
    private let updated = Date(timeIntervalSince1970: 2_000)

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("A saved query keeps every field through a save and a load")
    func queryRoundTrips() throws {
        let query = SavedQuery(
            name: "Daily users",
            query: "SELECT 1",
            keyword: "dau",
            folderId: UUID(),
            connectionId: UUID(),
            sortOrder: 3,
            createdAt: created,
            updatedAt: updated
        )

        let decoded = try JSONDecoder().decode(SavedQuery.self, from: JSONEncoder().encode(query))

        #expect(decoded == query)
    }

    @Test("A saved query file without the optional keys loads with the defaults")
    func queryOptionalsDefault() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Daily","query":"SELECT 1","createdAt":1000}
        """

        let decoded = try decode(SavedQuery.self, json)

        #expect(decoded.keyword == nil)
        #expect(decoded.folderId == nil)
        #expect(decoded.connectionId == nil)
        #expect(decoded.sortOrder == 0)
        #expect(decoded.updatedAt == decoded.createdAt)
    }

    @Test("A saved query without a required key does not load", arguments: ["id", "name", "query", "createdAt"])
    func queryRequiredKeys(_ missing: String) throws {
        var object: [String: Any] = [
            "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            "name": "Daily",
            "query": "SELECT 1",
            "createdAt": 1_000
        ]
        object.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SavedQuery.self, from: data)
        }
    }

    @Test("A new saved query is unfiled, global and created and updated at one moment")
    func queryInitDefaults() {
        let query = SavedQuery(name: "Daily", query: "SELECT 1")

        #expect(query.keyword == nil)
        #expect(query.folderId == nil)
        #expect(query.connectionId == nil)
        #expect(query.sortOrder == 0)
        #expect(query.createdAt == query.updatedAt)
    }

    @Test("A folder keeps every field through a save and a load")
    func folderRoundTrips() throws {
        let folder = SavedQueryFolder(
            name: "Reports",
            parentId: UUID(),
            connectionId: UUID(),
            sortOrder: 2,
            createdAt: created,
            updatedAt: updated
        )

        let decoded = try JSONDecoder().decode(SavedQueryFolder.self, from: JSONEncoder().encode(folder))

        #expect(decoded == folder)
    }

    @Test("A folder file without the optional keys loads with the defaults")
    func folderOptionalsDefault() throws {
        let json = """
        {"id":"7A9619FF-8B86-D011-B42D-00C04FC964FF","name":"Reports","createdAt":1000}
        """

        let decoded = try decode(SavedQueryFolder.self, json)

        #expect(decoded.parentId == nil)
        #expect(decoded.connectionId == nil)
        #expect(decoded.sortOrder == 0)
        #expect(decoded.updatedAt == decoded.createdAt)
    }

    @Test("A folder without a required key does not load", arguments: ["id", "name", "createdAt"])
    func folderRequiredKeys(_ missing: String) throws {
        var object: [String: Any] = [
            "id": "7A9619FF-8B86-D011-B42D-00C04FC964FF",
            "name": "Reports",
            "createdAt": 1_000
        ]
        object.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SavedQueryFolder.self, from: data)
        }
    }

    @Test("A new folder sits at the root, global, created and updated at one moment")
    func folderInitDefaults() {
        let folder = SavedQueryFolder(name: "Reports")

        #expect(folder.parentId == nil)
        #expect(folder.connectionId == nil)
        #expect(folder.sortOrder == 0)
        #expect(folder.createdAt == folder.updatedAt)
    }
}
