import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct IOSDriverFactoryRefusalTests {
    private func socketConnection(sshHost: String? = nil) -> DatabaseConnection {
        DatabaseConnection(
            type: .mysql,
            host: "localhost",
            database: "shop",
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"],
            sshEnabled: sshHost != nil,
            sshConfiguration: sshHost.map { SSHConfiguration(host: $0, username: "deploy") }
        )
    }

    @Test(
        "Every type with a driver on iPhone and iPad opens here",
        arguments: [
            DatabaseType.sqlite, .duckdb, .mysql, .mariadb, .tidb, .oceanbase, .postgresql, .redshift, .redis, .mssql, .oracle,
            .clickhouse, .mongodb
        ]
    )
    func supportedTypeOpens(type: DatabaseType) {
        #expect(IOSDriverFactory.refusal(for: DatabaseConnection(type: type, host: "db.acme.io")) == nil)
    }

    @Test("A type with no driver here is refused by its engine name", arguments: ["Cassandra", "Elasticsearch", "Snowflake"])
    func typeWithoutDriverIsRefused(engine: String) {
        let connection = DatabaseConnection(type: DatabaseType(rawValue: engine), host: "db.acme.io")

        #expect(IOSDriverFactory.refusal(for: connection) == .driverNotFound(engine))
    }

    @Test("A connection on a Mac socket is refused, and one whose tunnel replaces the socket opens")
    func macSocketIsRefused() {
        #expect(IOSDriverFactory.refusal(for: socketConnection()) == .localSocketNotSupported)
        #expect(IOSDriverFactory.refusal(for: socketConnection(sshHost: "bastion.acme.io")) == nil)
    }

    @Test("A PostgreSQL connection on a Mac socket is refused instead of dialing its leftover host")
    func postgresMacSocketIsRefused() {
        let connection = DatabaseConnection(
            type: .postgresql,
            host: "localhost",
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp"]
        )

        #expect(IOSDriverFactory.refusal(for: connection) == .localSocketNotSupported)
        #expect(throws: ConnectionError.localSocketNotSupported) {
            try IOSDriverFactory().createDriver(for: connection, password: nil)
        }
    }

    @Test("A Kerberos sign-in from the Mac is refused before it dials", arguments: [DatabaseType.postgresql, .mariadb])
    func kerberosIsRefused(type: DatabaseType) {
        let connection = DatabaseConnection(
            type: type,
            host: "db.corp.example.com",
            additionalFields: ["awsAuth": KerberosAuthFields.method]
        )

        #expect(IOSDriverFactory.refusal(for: connection) == .kerberosNotSupported)
        #expect(MacOnlyConnection.isMacOnly(connection))
    }

    @Test("The connect path gets the device's answer, socket included, not the protocol default")
    func connectPathUsesTheDeviceRule() {
        let factory: any DriverFactory = IOSDriverFactory()

        #expect(factory.refusal(for: socketConnection()) == .localSocketNotSupported)
        #expect(factory.refusal(for: DatabaseConnection(type: .cassandra)) == .driverNotFound("Cassandra"))
        #expect(factory.supportedTypes() == IOSDriverFactory.supportedTypeList)
    }
}
