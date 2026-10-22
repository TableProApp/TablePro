import Foundation
import TableProConnectionLibrary
import TableProCoreTypes
import Testing

@testable import TableProMobile

@Suite("SQL DDL fallback policy on iOS")
struct SQLDDLFallbackPolicyIOSTests {
    // A `DROP TABLE "session:42"` came back from Redis as an unknown command after the menu had promised a delete.
    @Test("MongoDB and Redis are the iOS engines with no SQL DDL")
    func nonSQLEnginesHaveNoDDL() {
        let withoutDDL = IOSDriverFactory().supportedTypes()
            .filter { !SQLDDLFallbackPolicy.allowsGeneratedDDL(databaseTypeId: $0.rawValue) }
            .map(\.rawValue)
            .sorted()
        #expect(withoutDDL == ["MongoDB", "Redis"])
    }

    @Test("Every SQL engine iOS ships keeps Drop and Truncate")
    func sqlEnginesKeepTheirOperations() {
        for type in IOSDriverFactory().supportedTypes() where type.speaksSQL {
            #expect(
                SQLDDLFallbackPolicy.allowsGeneratedDDL(databaseTypeId: type.rawValue),
                "\(type.rawValue) should keep Drop and Truncate"
            )
        }
    }

    @Test("The shared ids match this app's own type constants")
    func sharedIdsMatchLocalConstants() {
        #expect(SQLDDLFallbackPolicy.engineIdsWithoutSQLDDL.contains(DatabaseType.redis.rawValue))
        #expect(!SQLDDLFallbackPolicy.engineIdsWithoutSQLDDL.contains(DatabaseType.postgresql.rawValue))
        #expect(!SQLDDLFallbackPolicy.engineIdsWithoutSQLDDL.contains(DatabaseType.sqlite.rawValue))
    }
}
