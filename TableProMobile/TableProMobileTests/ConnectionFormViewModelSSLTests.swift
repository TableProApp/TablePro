import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection form SSL preservation")
struct ConnectionFormViewModelSSLTests {
    private func existingConnection(type: DatabaseType) -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "prod",
            type: type,
            host: "db.example.com",
            port: 5432,
            username: "postgres",
            database: "app",
            additionalFields: ["redisDatabase": "3", "custom": "kept"],
            sslEnabled: true
        )
        connection.sslConfiguration = SSLConfiguration(
            mode: .verifyFull,
            caCertificatePath: "/Users/mac/ca.pem",
            clientCertificatePath: "/Users/mac/client.pem",
            clientKeyPath: "/Users/mac/client.key"
        )
        return connection
    }

    @Test("editing a connection keeps the certificate paths set on the Mac")
    func keepsMacCertificatePaths() {
        let original = existingConnection(type: .postgresql)
        let viewModel = ConnectionFormViewModel(editing: original)

        let rebuilt = viewModel.buildConnection()

        #expect(rebuilt.sslConfiguration?.caCertificatePath == "/Users/mac/ca.pem")
        #expect(rebuilt.sslConfiguration?.clientCertificatePath == "/Users/mac/client.pem")
        #expect(rebuilt.sslConfiguration?.clientKeyPath == "/Users/mac/client.key")
    }

    @Test("editing a connection keeps its additional fields")
    func keepsAdditionalFields() {
        let original = existingConnection(type: .redis)
        let viewModel = ConnectionFormViewModel(editing: original)

        let rebuilt = viewModel.buildConnection()

        #expect(rebuilt.additionalFields["redisDatabase"] == "3")
        #expect(rebuilt.additionalFields["custom"] == "kept")
    }

    @Test("the stored SSL mode is loaded into the form and written back")
    func roundTripsMode() {
        let original = existingConnection(type: .postgresql)
        let viewModel = ConnectionFormViewModel(editing: original)

        #expect(viewModel.sslMode == .verifyFull)
        #expect(viewModel.buildConnection().sslConfiguration?.mode == .verifyFull)

        viewModel.sslMode = .require
        let lowered = viewModel.buildConnection()
        #expect(lowered.sslConfiguration?.mode == .require)
        #expect(lowered.sslEnabled)
        #expect(lowered.sslConfiguration?.clientCertificatePath == "/Users/mac/client.pem")
    }

    @Test("turning SSL off keeps the certificate paths for when it is turned back on")
    func disablingKeepsPaths() {
        let viewModel = ConnectionFormViewModel(editing: existingConnection(type: .postgresql))

        viewModel.sslMode = .disable
        let rebuilt = viewModel.buildConnection()

        #expect(rebuilt.sslConfiguration?.mode == .disable)
        #expect(!rebuilt.sslEnabled)
        #expect(rebuilt.sslConfiguration?.clientCertificatePath == "/Users/mac/client.pem")
    }

    @Test("an MSSQL connection still coerces verify modes but keeps its paths")
    func mssqlKeepsPaths() {
        let viewModel = ConnectionFormViewModel(editing: existingConnection(type: .mssql))

        #expect(viewModel.mssqlSSLMode == .require)
        let rebuilt = viewModel.buildConnection()
        #expect(rebuilt.sslConfiguration?.mode == .require)
        #expect(rebuilt.sslConfiguration?.caCertificatePath == "/Users/mac/ca.pem")
    }
}
