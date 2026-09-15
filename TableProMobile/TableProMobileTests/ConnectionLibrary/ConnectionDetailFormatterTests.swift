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
        let memory = DatabaseConnection(type: .duckdb, database: ConnectionDetailFormatter.inMemoryDatabasePath)

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
}
