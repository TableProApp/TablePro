import Foundation
import Testing
import TableProModels
@testable import TableProMobile

@Suite("IntentConnectionLoader")
struct IntentConnectionLoaderTests {
    @Test("decodes the full connection model that the app persists")
    func decodesFullModel() throws {
        let connection = DatabaseConnection(
            id: UUID(),
            name: "Prod",
            type: .postgresql,
            host: "db.example.com",
            port: 5432,
            username: "alice",
            database: "appdb",
            sshEnabled: true,
            sslEnabled: true
        )
        let data = try JSONEncoder().encode([connection])

        let decoded = IntentConnectionLoader.decode(data)

        #expect(decoded.count == 1)
        #expect(decoded[0].id == connection.id)
        #expect(decoded[0].type == .postgresql)
        #expect(decoded[0].host == "db.example.com")
        #expect(decoded[0].database == "appdb")
        #expect(decoded[0].sshEnabled)
    }

    @Test("returns an empty list for invalid data")
    func invalidDataReturnsEmpty() {
        let decoded = IntentConnectionLoader.decode(Data("not json".utf8))
        #expect(decoded.isEmpty)
    }

    @Test("skips a connection that does not fully decode and keeps the valid ones")
    func skipsUndecodableConnection() throws {
        let valid = DatabaseConnection(
            id: UUID(), name: "Prod", type: .mysql,
            host: "h", port: 3306, username: "u", database: "d"
        )
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let mixed: [Any] = [["unexpected": "shape"], validObject]
        let data = try JSONSerialization.data(withJSONObject: mixed)

        let decoded = IntentConnectionLoader.decode(data)

        #expect(decoded.count == 1)
        #expect(decoded[0].id == valid.id)
    }
}
