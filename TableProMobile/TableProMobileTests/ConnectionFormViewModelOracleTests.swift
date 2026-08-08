import Foundation
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import Testing

@MainActor
@Suite("ConnectionFormViewModel Oracle")
struct ConnectionFormViewModelOracleTests {
    private func makeOracleConnection(
        additionalFields: [String: String],
        sslMode: SSLConfiguration.SSLMode = .disable
    ) -> DatabaseConnection {
        DatabaseConnection(
            id: UUID(),
            name: "Prod",
            type: .oracle,
            host: "db.example.com",
            port: 1_521,
            username: "scott",
            database: "",
            additionalFields: additionalFields,
            sslEnabled: sslMode != .disable,
            sslConfiguration: SSLConfiguration(mode: sslMode)
        )
    }

    @Test("Oracle defaults to Service Name on a new connection")
    func defaultsToServiceName() {
        let viewModel = ConnectionFormViewModel()
        viewModel.type = .oracle
        #expect(viewModel.oracleConnectionType == .service)
        #expect(viewModel.port == "1521")
    }

    @Test("Service Name connections hydrate from additionalFields")
    func hydratesServiceName() {
        let connection = makeOracleConnection(additionalFields: [
            OracleConnectionOptions.AdditionalFieldKey.connectionType: "service",
            OracleConnectionOptions.AdditionalFieldKey.serviceName: "ORCLPDB1"
        ])
        let viewModel = ConnectionFormViewModel(editing: connection)
        #expect(viewModel.oracleConnectionType == .service)
        #expect(viewModel.oracleServiceName == "ORCLPDB1")
        #expect(viewModel.oracleSID.isEmpty)
    }

    @Test("SID connections hydrate from additionalFields")
    func hydratesSID() {
        let connection = makeOracleConnection(additionalFields: [
            OracleConnectionOptions.AdditionalFieldKey.connectionType: "sid",
            OracleConnectionOptions.AdditionalFieldKey.sid: "XE"
        ])
        let viewModel = ConnectionFormViewModel(editing: connection)
        #expect(viewModel.oracleConnectionType == .sid)
        #expect(viewModel.oracleSID == "XE")
    }

    @Test("Oracle SSL mode is kept verbatim rather than coerced like SQL Server")
    func keepsVerifyModes() {
        let connection = makeOracleConnection(additionalFields: [:], sslMode: .verifyFull)
        let viewModel = ConnectionFormViewModel(editing: connection)
        #expect(viewModel.oracleSSLMode == .verifyFull)
        #expect(viewModel.mssqlSSLMode == .require)
    }

    @Test("Saving writes the same additionalFields keys the Mac app reads")
    func writesAdditionalFields() {
        let viewModel = ConnectionFormViewModel()
        viewModel.type = .oracle
        viewModel.host = "db.example.com"
        viewModel.username = "scott"
        viewModel.oracleConnectionType = .sid
        viewModel.oracleSID = "XE"
        viewModel.oracleServiceName = "ORCL"

        let built = viewModel.buildConnection()
        #expect(built.additionalFields["oracleConnectionType"] == "sid")
        #expect(built.additionalFields["oracleSID"] == "XE")
        #expect(built.additionalFields["oracleServiceName"] == "ORCL")
    }

    @Test("Saving derives sslEnabled from the Oracle SSL mode")
    func sslEnabledFollowsMode() {
        let viewModel = ConnectionFormViewModel()
        viewModel.type = .oracle
        viewModel.host = "db.example.com"

        viewModel.oracleSSLMode = .disable
        #expect(viewModel.buildConnection().sslEnabled == false)

        viewModel.oracleSSLMode = .verifyCa
        let secured = viewModel.buildConnection()
        #expect(secured.sslEnabled)
        #expect(secured.sslConfiguration?.mode == .verifyCa)
    }

    @Test("An Oracle connection round-trips through the form unchanged")
    func roundTripsThroughTheForm() {
        let original = makeOracleConnection(
            additionalFields: [
                OracleConnectionOptions.AdditionalFieldKey.connectionType: "service",
                OracleConnectionOptions.AdditionalFieldKey.serviceName: "ORCLPDB1",
                OracleConnectionOptions.AdditionalFieldKey.sid: ""
            ],
            sslMode: .require
        )
        let rebuilt = ConnectionFormViewModel(editing: original).buildConnection()
        #expect(rebuilt.additionalFields["oracleConnectionType"] == "service")
        #expect(rebuilt.additionalFields["oracleServiceName"] == "ORCLPDB1")
        #expect(rebuilt.sslConfiguration?.mode == .require)
        #expect(rebuilt.type == .oracle)
    }
}
