import Foundation
@testable import TablePro
import Testing

@Suite("StoredConnection tag persistence")
struct StoredConnectionTagTests {
    @Test("Round trips multiple tag IDs")
    func roundTripMultiple() throws {
        let a = UUID()
        let b = UUID()
        var connection = DatabaseConnection(name: "Local")
        connection.tagIds = [a, b]

        let stored = StoredConnection(from: connection)
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredConnection.self, from: data)

        #expect(decoded.toConnection().tagIds == [a, b])
    }

    @Test("Writes both legacy tagId and tagIds for backward compatibility")
    func writesBackwardCompatField() throws {
        let a = UUID()
        let b = UUID()
        var connection = DatabaseConnection(name: "Local")
        connection.tagIds = [a, b]

        let data = try JSONEncoder().encode(StoredConnection(from: connection))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["tagId"] as? String == a.uuidString)
        #expect(object["tagIds"] as? [String] == [a.uuidString, b.uuidString])
    }

    @Test("Legacy single tagId promotes to tagIds")
    func legacyPromotes() throws {
        let tagId = UUID()
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Local",
            "host": "localhost",
            "port": 3306,
            "database": "",
            "username": "root",
            "type": "mysql",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sslMode": "disabled",
            "color": "none",
            "tagId": tagId.uuidString,
            "safeModeLevel": "silent",
            "externalAccess": "readOnly",
            "sortOrder": 0,
            "localOnly": false,
            "isSample": false,
            "isFavorite": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let stored = try JSONDecoder().decode(StoredConnection.self, from: data)
        #expect(stored.toConnection().tagIds == [tagId])
    }
}
