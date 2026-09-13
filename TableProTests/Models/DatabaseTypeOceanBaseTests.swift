import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseType OceanBase")
struct DatabaseTypeOceanBaseTests {
    @Test("rawValue is OceanBase")
    func rawValue() {
        #expect(DatabaseType.oceanbase.rawValue == "OceanBase")
    }

    @Test("defaultPort is 2881")
    func defaultPort() {
        #expect(DatabaseType.oceanbase.defaultPort == 2_881)
    }

    @Test("iconName is oceanbase-icon")
    func iconName() {
        #expect(DatabaseType.oceanbase.iconName == "oceanbase-icon")
    }

    @Test("pluginTypeId resolves to MySQL")
    func pluginTypeIdResolvesToMySQL() {
        #expect(DatabaseType.oceanbase.pluginTypeId == "MySQL")
    }

    @Test("triggers browse without trigger editing")
    func triggerFlags() {
        #expect(DatabaseType.oceanbase.supportsTriggers == true)
        #expect(DatabaseType.oceanbase.supportsTriggerEditing == false)
    }

    @Test("routines are offered")
    func routines() {
        #expect(DatabaseType.oceanbase.supportsRoutines == true)
    }

    @Test("allKnownTypes contains oceanbase")
    func allKnownTypesContainsOceanBase() {
        #expect(DatabaseType.allKnownTypes.contains(.oceanbase))
    }

    @Test("Codable round-trips through rawValue")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(DatabaseType.oceanbase)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: encoded)
        #expect(decoded == DatabaseType.oceanbase)
    }
}
