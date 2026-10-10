import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Connection detail line")
struct ConnectionDetailFormatterTests {
    @Test("The default port is left out and the database follows a slash")
    func defaultPort() {
        let connection = DatabaseConnection(type: .postgresql, host: "db.acme.io", port: 5_432, database: "app")
        #expect(ConnectionDetailFormatter.detail(for: connection) == "db.acme.io/app")
    }

    @Test("A port other than the default is shown")
    func customPort() {
        let connection = DatabaseConnection(type: .postgresql, host: "db.acme.io", port: 6_543)
        #expect(ConnectionDetailFormatter.detail(for: connection) == "db.acme.io:6543")
    }

    @Test("A file database shows its file name, and an in-memory one says so")
    func fileDatabases() {
        let sqlite = DatabaseConnection(type: .sqlite, database: "/var/mobile/Documents/app.sqlite")
        let memory = DatabaseConnection(type: .duckdb, database: LocalDatabaseLocation.inMemoryPath)

        #expect(ConnectionDetailFormatter.detail(for: sqlite) == "app.sqlite")
        #expect(ConnectionDetailFormatter.detail(for: memory) == String(localized: "In Memory"))
    }

    @Test("An SSH connection names the jump host, with no middle dot")
    func sshTunnel() {
        let connection = DatabaseConnection(
            type: .mysql,
            host: "10.0.0.5",
            port: 3_306,
            database: "shop",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.acme.io", port: 22, username: "deploy", authMethod: .password)
        )

        let detail = ConnectionDetailFormatter.detail(for: connection)

        #expect(detail.hasPrefix("10.0.0.5/shop"))
        #expect(detail.hasSuffix("bastion.acme.io"))
        #expect(!detail.contains("·"))
    }

    @Test(
        "A connection that dials a socket on the Mac names the socket, not a host and port",
        arguments: [DatabaseType.mysql, .mariadb, .tidb, .oceanbase]
    )
    func macSocket(type: DatabaseType) {
        let withDatabase = DatabaseConnection(
            type: type,
            host: "localhost",
            port: 3_307,
            database: "shop",
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"]
        )
        let withoutDatabase = DatabaseConnection(
            type: type,
            host: "localhost",
            additionalFields: [MySQLLocalSocket.fieldKey: " /tmp/mysql.sock "]
        )

        #expect(ConnectionDetailFormatter.detail(for: withDatabase) == "shop on Mac socket /tmp/mysql.sock")
        #expect(ConnectionDetailFormatter.detail(for: withoutDatabase) == "Mac socket /tmp/mysql.sock")
    }

    @Test("An SSH tunnel replaces the socket, so the row shows the forwarded host")
    func sshTunnelReplacesTheSocket() {
        let connection = DatabaseConnection(
            type: .mariadb,
            host: "10.0.0.5",
            database: "shop",
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"],
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.acme.io", username: "deploy")
        )

        let detail = ConnectionDetailFormatter.detail(for: connection)

        #expect(detail.hasPrefix("10.0.0.5/shop"))
        #expect(!detail.contains("socket"))
    }

    @Test("A blank socket path, or one on an engine without sockets, leaves the host and port")
    func socketKeyIgnored() {
        let blank = DatabaseConnection(
            type: .mysql,
            host: "db.acme.io",
            port: 3_307,
            additionalFields: [MySQLLocalSocket.fieldKey: "  "]
        )
        let postgres = DatabaseConnection(
            type: .postgresql,
            host: "db.acme.io",
            port: 5_432,
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"]
        )

        #expect(ConnectionDetailFormatter.detail(for: blank) == "db.acme.io:3307")
        #expect(ConnectionDetailFormatter.detail(for: postgres) == "db.acme.io")
    }
}
