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

    @Test("an MSSQL connection keeps a synced verify mode, so the driver refuses it rather than skipping the check")
    func mssqlKeepsPaths() {
        let viewModel = ConnectionFormViewModel(editing: existingConnection(type: .mssql))

        #expect(viewModel.mssqlSSLMode == .verifyFull)
        #expect(viewModel.storedMSSQLVerifyMode == .verifyFull)
        #expect(viewModel.mssqlSSLModeNote != nil)
        let rebuilt = viewModel.buildConnection()
        #expect(rebuilt.sslConfiguration?.mode == .verifyFull)
        #expect(rebuilt.sslConfiguration?.caCertificatePath == "/Users/mac/ca.pem")
    }

    private func preferredConnection(type: DatabaseType) -> DatabaseConnection {
        var connection = existingConnection(type: type)
        connection.sslConfiguration = SSLConfiguration(
            mode: .require,
            caCertificatePath: "/Users/mac/ca.pem",
            clientCertificatePath: "/Users/mac/client.pem",
            clientKeyPath: "/Users/mac/client.key",
            isMacPreferred: true
        )
        return connection
    }

    @Test("a Mac Preferred connection opens as Preferred in every picker", arguments: [
        DatabaseType.postgresql, .mysql, .mssql, .oracle
    ])
    func preferredOpensAsPreferred(type: DatabaseType) {
        let viewModel = ConnectionFormViewModel(editing: preferredConnection(type: type))

        #expect(viewModel.sslMode == .preferred)
        #expect(viewModel.mssqlSSLMode == .preferred)
        #expect(viewModel.oracleSSLMode == .preferred)
    }

    @Test("a Mac Preferred connection is written back as Preferred", arguments: [
        DatabaseType.postgresql, .mssql, .oracle
    ])
    func preferredRoundTrips(type: DatabaseType) {
        let viewModel = ConnectionFormViewModel(editing: preferredConnection(type: type))

        let rebuilt = viewModel.buildConnection()

        #expect(rebuilt.sslEnabled)
        #expect(rebuilt.sslConfiguration?.mode == .require)
        #expect(rebuilt.sslConfiguration?.isMacPreferred == true)
        #expect(rebuilt.sslConfiguration?.clientCertificatePath == "/Users/mac/client.pem")
    }

    @Test("Test Connection with Required picked over Preferred connects as Required")
    func requiredOverPreferredBuildsRequired() {
        let viewModel = ConnectionFormViewModel(editing: preferredConnection(type: .postgresql))

        viewModel.sslMode = .require
        let rebuilt = viewModel.buildConnection()

        #expect(rebuilt.sslConfiguration?.mode == .require)
        #expect(rebuilt.sslConfiguration?.isMacPreferred == false)
        #expect(rebuilt.sslConfiguration?.caCertificatePath == "/Users/mac/ca.pem")
    }

    @Test("Preferred shows the certificate rows like Required")
    func preferredShowsCertificateRows() {
        let viewModel = ConnectionFormViewModel(editing: preferredConnection(type: .mysql))

        #expect(viewModel.showsCertificateRows)
    }

    @Test("Preferred on Oracle notes that it connects in plain TCP")
    func oraclePreferredNote() {
        let viewModel = ConnectionFormViewModel(editing: preferredConnection(type: .oracle))

        #expect(viewModel.oracleSSLModeNote == ConnectionFormViewModel.oraclePreferredPlaintextMessage)

        viewModel.oracleSSLMode = .require
        #expect(viewModel.oracleSSLModeNote == nil)
    }

    @Test("Preferred on Redis notes that it forces TLS, as on the Mac")
    func redisPreferredNote() {
        let viewModel = ConnectionFormViewModel(editing: preferredConnection(type: .redis))

        #expect(viewModel.sslModeNote == ConnectionFormViewModel.redisPreferredForcesTLSMessage)

        viewModel.sslMode = .require
        #expect(viewModel.sslModeNote == nil)

        let mysql = ConnectionFormViewModel(editing: preferredConnection(type: .mysql))
        #expect(mysql.sslModeNote == nil)
    }

    @Test("a connection with SSL on and no stored configuration opens as Required in every picker")
    func sslEnabledWithoutModeOpensAsRequired() {
        var connection = existingConnection(type: .mssql)
        connection.sslConfiguration = nil

        let viewModel = ConnectionFormViewModel(editing: connection)

        #expect(viewModel.sslMode == .require)
        #expect(viewModel.mssqlSSLMode == .require)
        #expect(viewModel.oracleSSLMode == .require)
    }
}
