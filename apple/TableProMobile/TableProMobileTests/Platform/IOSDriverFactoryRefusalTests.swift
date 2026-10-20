import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
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
            .clickhouse
        ]
    )
    func supportedTypeOpens(type: DatabaseType) {
        #expect(IOSDriverFactory.refusal(for: DatabaseConnection(type: type, host: "db.acme.io")) == nil)
    }

    @Test("A type with no driver here is refused by its engine name", arguments: ["MongoDB", "Cassandra", "Elasticsearch"])
    func typeWithoutDriverIsRefused(engine: String) {
        let connection = DatabaseConnection(type: DatabaseType(rawValue: engine), host: "db.acme.io")

        #expect(IOSDriverFactory.refusal(for: connection) == .driverNotFound(engine))
    }

    @Test("A connection on a Mac socket is refused, and one whose tunnel replaces the socket opens")
    func macSocketIsRefused() {
        #expect(IOSDriverFactory.refusal(for: socketConnection()) == .localSocketNotSupported)
        #expect(IOSDriverFactory.refusal(for: socketConnection(sshHost: "bastion.acme.io")) == nil)
    }

    @Test("The connect path gets the device's answer, socket included, not the protocol default")
    func connectPathUsesTheDeviceRule() {
        let factory: any DriverFactory = IOSDriverFactory()

        #expect(factory.refusal(for: socketConnection()) == .localSocketNotSupported)
        #expect(factory.refusal(for: DatabaseConnection(type: .mongodb)) == .driverNotFound("MongoDB"))
        #expect(factory.supportedTypes() == IOSDriverFactory.supportedTypeList)
    }
}
