import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("MySQL variant support on iOS")
@MainActor
struct MySQLVariantSupportTests {
    @Test("TiDB is offered and supported, Databend is neither")
    func offeredTypes() {
        #expect(DatabaseType.mobileSupportedTypes.contains(.tidb))
        #expect(DatabaseType.mobileSupportedTypes.contains(.oceanbase))
        #expect(!DatabaseType.mobileSupportedTypes.contains(.databend))
        let supported = IOSDriverFactory().supportedTypes()
        #expect(supported.contains(.tidb))
        #expect(supported.contains(.oceanbase))
        #expect(!supported.contains(.databend))
    }

    @Test("TiDB and Databend keep their own port and display name")
    func portsAndNames() {
        #expect(DatabaseType.tidb.defaultPort == "4000")
        #expect(DatabaseType.tidb.mobileDisplayName == "TiDB")
        #expect(DatabaseType.databend.defaultPort == "3307")
        #expect(DatabaseType.databend.mobileDisplayName == "Databend")
        #expect(DatabaseType.oceanbase.defaultPort == "2881")
        #expect(DatabaseType.oceanbase.mobileDisplayName == "OceanBase")
    }

    @Test("TiDB takes tabular inserts from Shortcuts, Databend does not")
    func tabularInsert() {
        #expect(IntentDatabaseSession.supportsTabularInsert(.tidb))
        #expect(IntentDatabaseSession.supportsTabularInsert(.oceanbase))
        #expect(!IntentDatabaseSession.supportsTabularInsert(.databend))
    }

    @Test("TiDB routes to the MySQL driver with its own type")
    func tiDBRoutesToMySQLDriver() throws {
        let connection = DatabaseConnection(name: "t", type: .tidb, host: "127.0.0.1", port: 4_000)
        let driver = try IOSDriverFactory().createDriver(for: connection, password: nil)
        let mysql = try #require(driver as? MySQLDriver)
        #expect(mysql.databaseType == .tidb)
    }

    @Test("OceanBase routes to the MySQL driver with its own type")
    func oceanBaseRoutesToMySQLDriver() throws {
        let connection = DatabaseConnection(name: "o", type: .oceanbase, host: "127.0.0.1", port: 2_881)
        let driver = try IOSDriverFactory().createDriver(for: connection, password: nil)
        let mysql = try #require(driver as? MySQLDriver)
        #expect(mysql.databaseType == .oceanbase)
    }
}
