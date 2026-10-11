import Foundation
import Testing

@testable import TableProModels

struct DatabaseConnectionTimeoutTests {
    @Test("Query timeout initializer accepts the maximum and rejects the next second")
    func initializerBoundsQueryTimeout() {
        let maximum = DatabaseConnection.queryTimeoutSecondsRange.upperBound

        #expect(DatabaseConnection(queryTimeoutSeconds: maximum).queryTimeoutSeconds == maximum)
        #expect(DatabaseConnection(queryTimeoutSeconds: maximum + 1).queryTimeoutSeconds == nil)
    }

    @Test("Decoding rejects a query timeout unsafe for millisecond APIs")
    func decodingRejectsUnsafeQueryTimeout() throws {
        let maximum = DatabaseConnection.queryTimeoutSecondsRange.upperBound
        let connection = DatabaseConnection(name: "Timeouts", queryTimeoutSeconds: maximum)
        let valid = try JSONDecoder().decode(
            DatabaseConnection.self,
            from: JSONEncoder().encode(connection)
        )
        #expect(valid.queryTimeoutSeconds == maximum)

        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any]
        )
        object["queryTimeoutSeconds"] = maximum + 1
        let invalid = try JSONDecoder().decode(
            DatabaseConnection.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(invalid.queryTimeoutSeconds == nil)
    }
}
