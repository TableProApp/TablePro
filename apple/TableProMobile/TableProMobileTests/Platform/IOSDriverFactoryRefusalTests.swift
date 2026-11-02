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
            .clickhouse, .mongodb, .cloudflareD1
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

    private func tls(_ type: DatabaseType, _ mode: TableProModels.SSLConfiguration.SSLMode) -> DatabaseConnection {
        DatabaseConnection(
            type: type,
            host: "db.corp.example.com",
            sslEnabled: mode != .disable,
            sslConfiguration: TableProModels.SSLConfiguration(mode: mode)
        )
    }

    @Test(
        "A verify mode the driver here cannot honour is refused before it dials",
        arguments: [
            (DatabaseType.mssql, TableProModels.SSLConfiguration.SSLMode.verifyCa, String(localized: "Verify CA")),
            (.mssql, .verifyFull, String(localized: "Verify Identity")),
            (.oracle, .verifyCa, String(localized: "Verify CA"))
        ]
    )
    func unsupportedVerifyModeIsRefused(
        type: DatabaseType,
        mode: TableProModels.SSLConfiguration.SSLMode,
        modeName: String
    ) async {
        let connection = tls(type, mode)
        let refusal = ConnectionError.sslModeNotSupported(mode: modeName, typeName: type.mobileDisplayName)

        #expect(IOSDriverFactory.refusal(for: connection) == refusal)
        #expect(MacOnlyConnection.isMacOnly(connection))
        let manager = ConnectionManager(driverFactory: IOSDriverFactory(), secureStore: EphemeralSecureStore())
        await #expect(throws: refusal) {
            _ = try await manager.connect(connection)
        }
        let error = ErrorClassifier.connectionFailure(refusal)
        #expect(!error.canRetry)
        #expect(error.opensEditor)
    }

    @Test(
        "Every mode the driver here keeps opens",
        arguments: [
            (DatabaseType.mssql, SSLModeChoice.disable), (.mssql, .preferred), (.mssql, .require),
            (.oracle, .preferred), (.oracle, .verifyFull),
            (.postgresql, .verifyCa), (.mysql, .verifyFull), (.redis, .verifyCa), (.mongodb, .verifyFull)
        ]
    )
    func supportedModeOpens(type: DatabaseType, choice: SSLModeChoice) {
        let connection = DatabaseConnection(
            type: type,
            host: "db.corp.example.com",
            sslEnabled: choice != .disable,
            sslConfiguration: choice.applied(to: TableProModels.SSLConfiguration())
        )

        #expect(IOSDriverFactory.supportedSSLModes(for: type).contains(choice))
        #expect(IOSDriverFactory.refusal(for: connection) == nil)
    }

    @Test("A file or API engine is never refused for an SSL mode left from another engine")
    func fileEngineIgnoresSSLMode() {
        #expect(IOSDriverFactory.refusal(for: tls(.sqlite, .verifyCa)) == nil)
        #expect(IOSDriverFactory.refusal(for: tls(.duckdb, .verifyFull)) == nil)
        #expect(IOSDriverFactory.refusal(for: tls(.cloudflareD1, .verifyCa)) == nil)
    }

    @Test("Only a server engine dials the SSH tunnel a record carries", arguments: [
        (DatabaseType.mysql, true), (.postgresql, true), (.sqlite, false), (.duckdb, false), (.cloudflareD1, false)
    ])
    func onlyServerEnginesDialTheTunnel(type: DatabaseType, dials: Bool) {
        let connection = DatabaseConnection(
            type: type, sshEnabled: true, sshConfiguration: SSHConfiguration(host: "jump.example.com")
        )
        let factory: any DriverFactory = IOSDriverFactory()

        #expect(factory.dialsSSHTunnel(for: connection) == dials)
    }

    @Test("The connect path gets the device's answer, socket included, not the protocol default")
    func connectPathUsesTheDeviceRule() {
        let factory: any DriverFactory = IOSDriverFactory()

        #expect(factory.refusal(for: socketConnection()) == .localSocketNotSupported)
        #expect(factory.refusal(for: DatabaseConnection(type: .cassandra)) == .driverNotFound("Cassandra"))
        #expect(factory.supportedTypes() == IOSDriverFactory.supportedTypeList)
    }
}
