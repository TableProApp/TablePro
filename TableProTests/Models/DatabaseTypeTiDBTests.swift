import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseType TiDB")
struct DatabaseTypeTiDBTests {
    @Test("rawValue is TiDB")
    func rawValue() {
        #expect(DatabaseType.tidb.rawValue == "TiDB")
    }

    @Test("defaultPort is 4000")
    func defaultPort() {
        #expect(DatabaseType.tidb.defaultPort == 4_000)
    }

    @Test("iconName is tidb-icon")
    func iconName() {
        #expect(DatabaseType.tidb.iconName == "tidb-icon")
    }

    @Test("pluginTypeId resolves to MySQL")
    func pluginTypeIdResolvesToMySQL() {
        #expect(DatabaseType.tidb.pluginTypeId == "MySQL")
    }

    @Test("does not offer triggers or routines")
    func triggerAndRoutineFlags() {
        #expect(DatabaseType.tidb.supportsTriggers == false)
        #expect(DatabaseType.tidb.supportsRoutines == false)
    }

    @Test("allKnownTypes contains tidb")
    func allKnownTypesContainsTiDB() {
        #expect(DatabaseType.allKnownTypes.contains(.tidb))
    }

    @Test("Codable round-trips through rawValue")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(DatabaseType.tidb)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: encoded)
        #expect(decoded == DatabaseType.tidb)
    }
}
