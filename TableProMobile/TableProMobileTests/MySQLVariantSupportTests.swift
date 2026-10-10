import Foundation
import TableProDatabase
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

    @Test(
        "A connection that dials a socket on the Mac is refused before connecting",
        arguments: [DatabaseType.mysql, .mariadb, .tidb, .oceanbase]
    )
    func macSocketIsRefused(type: DatabaseType) {
        let connection = DatabaseConnection(
            name: "Local",
            type: type,
            host: "localhost",
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"]
        )

        #expect(throws: ConnectionError.localSocketNotSupported) {
            try IOSDriverFactory().createDriver(for: connection, password: nil)
        }
    }

    @Test("A blank socket path connects by host and port, as the Mac driver does")
    func blankSocketPathConnectsByHost() throws {
        let connection = DatabaseConnection(
            name: "Local",
            type: .mysql,
            host: "db.example.com",
            additionalFields: [MySQLLocalSocket.fieldKey: "  "]
        )

        let driver = try IOSDriverFactory().createDriver(for: connection, password: nil)

        #expect(driver is MySQLDriver)
    }

    @Test("An SSH tunnel takes the place of the socket, as it does on the Mac")
    func sshTunnelReplacesTheSocket() throws {
        let connection = DatabaseConnection(
            name: "Remote",
            type: .mariadb,
            host: "127.0.0.1",
            port: 62_000,
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"],
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.example.com", username: "deploy")
        )

        let driver = try IOSDriverFactory().createDriver(for: connection, password: nil)

        #expect(driver is MySQLDriver)
    }

    @Test("SSH switched on without a tunnel configured leaves the socket to be refused")
    func sshWithoutTunnelStillRefused() {
        let connection = DatabaseConnection(
            name: "Local",
            type: .mysql,
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"],
            sshEnabled: true
        )

        #expect(throws: ConnectionError.localSocketNotSupported) {
            try IOSDriverFactory().createDriver(for: connection, password: nil)
        }
    }

    @Test("An OceanBase session lifts the server's own statement limit; other MySQL engines set nothing")
    func oceanBaseSessionSetup() {
        #expect(MySQLDriver.sessionSetupStatements(for: .oceanbase) == [
            "SET SESSION ob_query_timeout = 3216672000000000", "SET SESSION max_execution_time = 0"
        ])
        #expect(MySQLDriver.sessionSetupStatements(for: .mysql).isEmpty)
        #expect(MySQLDriver.sessionSetupStatements(for: .tidb).isEmpty)
        #expect(MySQLDriver.sessionSetupStatements(for: .mariadb).isEmpty)
    }
}
