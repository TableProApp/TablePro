import Foundation
@testable import TableProOracleCore
import Testing

struct OracleConnectionOptionsTests {
    @Test func testAdditionalFieldKeysMatchTheMacKeysExactly() {
        #expect(OracleConnectionOptions.AdditionalFieldKey.connectionType == "oracleConnectionType")
        #expect(OracleConnectionOptions.AdditionalFieldKey.serviceName == "oracleServiceName")
        #expect(OracleConnectionOptions.AdditionalFieldKey.sid == "oracleSID")
    }

    @Test func testIdentifierModeRawValuesMatchTheMacValues() {
        #expect(OracleConnectionOptions.IdentifierMode.service.rawValue == "service")
        #expect(OracleConnectionOptions.IdentifierMode.sid.rawValue == "sid")
    }

    @Test func testIdentifierModeDefaultsToServiceWhenAbsent() {
        #expect(OracleConnectionOptions.identifierMode(from: [:]) == .service)
    }

    @Test func testIdentifierModeReadsSID() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.connectionType: "sid"]
        #expect(OracleConnectionOptions.identifierMode(from: fields) == .sid)
    }

    @Test func testIdentifierModeFallsBackToServiceForUnknownValue() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.connectionType: "tns"]
        #expect(OracleConnectionOptions.identifierMode(from: fields) == .service)
    }

    @Test func testIdentifierUsesServiceNameInServiceMode() {
        let options = makeOptions(identifierMode: .service, serviceName: "ORCL", sid: "XE", database: "DB")
        #expect(options.identifier == "ORCL")
    }

    @Test func testIdentifierUsesSIDInSIDMode() {
        let options = makeOptions(identifierMode: .sid, serviceName: "ORCL", sid: "XE", database: "DB")
        #expect(options.identifier == "XE")
    }

    @Test func testIdentifierFallsBackToDatabaseWhenChosenFieldIsEmpty() {
        let serviceMode = makeOptions(identifierMode: .service, serviceName: "", sid: "XE", database: "DB")
        #expect(serviceMode.identifier == "DB")

        let sidMode = makeOptions(identifierMode: .sid, serviceName: "ORCL", sid: "", database: "DB")
        #expect(sidMode.identifier == "DB")
    }

    @Test func testDefaultPortIsOracleListenerPort() {
        #expect(OracleConnectionOptions.defaultPort == 1_521)
    }

    @Test func testRemainingMillisecondConnectBudgetTakesPrecedence() {
        let fields = [
            OracleConnectionOptions.AdditionalFieldKey.connectTimeoutMilliseconds: "1250",
            OracleConnectionOptions.AdditionalFieldKey.connectTimeoutSeconds: "30"
        ]

        #expect(OracleConnectionOptions.loginTimeoutSeconds(from: fields) == 1.25)
    }

    @Test func testConfiguredConnectSecondsAndOldHostDefault() {
        #expect(OracleConnectionOptions.loginTimeoutSeconds(from: [
            OracleConnectionOptions.AdditionalFieldKey.connectTimeoutSeconds: "2.5"
        ]) == 2.5)
        #expect(OracleConnectionOptions.loginTimeoutSeconds(from: [:]) == OracleConnectionOptions.defaultLoginTimeoutSeconds)
    }

    private func makeOptions(
        identifierMode: OracleConnectionOptions.IdentifierMode,
        serviceName: String,
        sid: String,
        database: String
    ) -> OracleConnectionOptions {
        OracleConnectionOptions(
            host: "localhost",
            user: "scott",
            password: "tiger",
            database: database,
            identifierMode: identifierMode,
            serviceName: serviceName,
            sid: sid
        )
    }
}
