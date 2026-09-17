import Foundation
import TableProConnectionLibrary
import TableProCoreTypes
import Testing

@testable import TableProMobile

@Suite("SQL DDL fallback policy on iOS")
struct SQLDDLFallbackPolicyIOSTests {
    /// Redis rows are keys and its driver tokenises the query text as a Redis command, so a
    /// `DROP TABLE "session:42"` came back as an unknown command after the menu had promised a
    /// delete. It is the only engine iOS ships that has no SQL DDL.
    @Test("Redis is the only iOS engine with no SQL DDL")
    func redisIsTheOnlyNonSQLEngine() {
        let withoutDDL = IOSDriverFactory().supportedTypes()
            .filter { !SQLDDLFallbackPolicy.allowsGeneratedDDL(databaseTypeId: $0.rawValue) }
            .map(\.rawValue)
            .sorted()
        #expect(withoutDDL == ["Redis"])
    }

    @Test("Every SQL engine iOS ships keeps Drop and Truncate")
    func sqlEnginesKeepTheirOperations() {
        for type in IOSDriverFactory().supportedTypes() where type != .redis {
            #expect(
                SQLDDLFallbackPolicy.allowsGeneratedDDL(databaseTypeId: type.rawValue),
                "\(type.rawValue) should keep Drop and Truncate"
            )
        }
    }

    /// The list is shared through the kit precisely so the two apps cannot drift. This asserts the
    /// ids are the raw values iOS actually uses, which is the only thing tying the string set to
    /// this app's `DatabaseType`.
    @Test("The shared ids match this app's own type constants")
    func sharedIdsMatchLocalConstants() {
        #expect(SQLDDLFallbackPolicy.engineIdsWithoutSQLDDL.contains(DatabaseType.redis.rawValue))
        #expect(!SQLDDLFallbackPolicy.engineIdsWithoutSQLDDL.contains(DatabaseType.postgresql.rawValue))
        #expect(!SQLDDLFallbackPolicy.engineIdsWithoutSQLDDL.contains(DatabaseType.sqlite.rawValue))
    }
}
