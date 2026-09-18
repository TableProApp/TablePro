import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseType Databend")
struct DatabaseTypeDatabendTests {
    @Test("rawValue is Databend")
    func rawValue() {
        #expect(DatabaseType.databend.rawValue == "Databend")
    }

    @Test("defaultPort is 3307")
    func defaultPort() {
        #expect(DatabaseType.databend.defaultPort == 3_307)
    }

    @Test("iconName is databend-icon")
    func iconName() {
        #expect(DatabaseType.databend.iconName == "databend-icon")
    }

    @Test("pluginTypeId resolves to MySQL")
    func pluginTypeIdResolvesToMySQL() {
        #expect(DatabaseType.databend.pluginTypeId == "MySQL")
    }

    @Test("warehouse flags")
    func warehouseFlags() {
        #expect(DatabaseType.databend.supportsForeignKeys == false)
        #expect(DatabaseType.databend.supportsTriggers == false)
        #expect(DatabaseType.databend.supportsRoutines == false)
    }

    @Test("allKnownTypes contains databend")
    func allKnownTypesContainsDatabend() {
        #expect(DatabaseType.allKnownTypes.contains(.databend))
    }

    @Test("Codable round-trips through rawValue")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(DatabaseType.databend)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: encoded)
        #expect(decoded == DatabaseType.databend)
    }
}
