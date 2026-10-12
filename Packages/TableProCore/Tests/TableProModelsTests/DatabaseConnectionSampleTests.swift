import Foundation
import Testing

@testable import TableProModels

@Suite("DatabaseConnection sample flag")
struct DatabaseConnectionSampleTests {
    private static let storedWithoutFlag = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Prod","type":"PostgreSQL","host":"db.local",\
    "port":5432,"username":"app","database":"prod"}
    """

    @Test("A connection stored before the flag existed decodes as not a sample")
    func legacyRecordIsNotSample() throws {
        let connection = try JSONDecoder().decode(
            DatabaseConnection.self,
            from: Data(Self.storedWithoutFlag.utf8)
        )

        #expect(connection.isSample == false)
        #expect(connection.participatesInSync)
    }

    @Test("A sample round-trips and stays out of sync")
    func sampleRoundTrips() throws {
        let sample = DatabaseConnection(name: "Sample", type: .sqlite, database: "Chinook.sqlite", isSample: true)

        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(sample))

        #expect(decoded.isSample)
        #expect(decoded.participatesInSync == false)
    }

    @Test("An ordinary connection writes no sample key")
    func ordinaryConnectionOmitsKey() throws {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any]

        #expect(object?["isSample"] == nil)
    }
}
