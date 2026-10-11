@testable import TableProOracleCore
import XCTest

final class OracleConnectionOptionsTests: XCTestCase {
    func testAdditionalFieldKeysMatchTheMacKeysExactly() {
        XCTAssertEqual(OracleConnectionOptions.AdditionalFieldKey.connectionType, "oracleConnectionType")
        XCTAssertEqual(OracleConnectionOptions.AdditionalFieldKey.serviceName, "oracleServiceName")
        XCTAssertEqual(OracleConnectionOptions.AdditionalFieldKey.sid, "oracleSID")
    }

    func testIdentifierModeRawValuesMatchTheMacValues() {
        XCTAssertEqual(OracleConnectionOptions.IdentifierMode.service.rawValue, "service")
        XCTAssertEqual(OracleConnectionOptions.IdentifierMode.sid.rawValue, "sid")
    }

    func testIdentifierModeDefaultsToServiceWhenAbsent() {
        XCTAssertEqual(OracleConnectionOptions.identifierMode(from: [:]), .service)
    }

    func testIdentifierModeReadsSID() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.connectionType: "sid"]
        XCTAssertEqual(OracleConnectionOptions.identifierMode(from: fields), .sid)
    }

    func testIdentifierModeFallsBackToServiceForUnknownValue() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.connectionType: "tns"]
        XCTAssertEqual(OracleConnectionOptions.identifierMode(from: fields), .service)
    }

    func testIdentifierUsesServiceNameInServiceMode() {
        let options = makeOptions(identifierMode: .service, serviceName: "ORCL", sid: "XE", database: "DB")
        XCTAssertEqual(options.identifier, "ORCL")
    }

    func testIdentifierUsesSIDInSIDMode() {
        let options = makeOptions(identifierMode: .sid, serviceName: "ORCL", sid: "XE", database: "DB")
        XCTAssertEqual(options.identifier, "XE")
    }

    func testIdentifierFallsBackToDatabaseWhenChosenFieldIsEmpty() {
        let serviceMode = makeOptions(identifierMode: .service, serviceName: "", sid: "XE", database: "DB")
        XCTAssertEqual(serviceMode.identifier, "DB")

        let sidMode = makeOptions(identifierMode: .sid, serviceName: "ORCL", sid: "", database: "DB")
        XCTAssertEqual(sidMode.identifier, "DB")
    }

    func testDefaultPortIsOracleListenerPort() {
        XCTAssertEqual(OracleConnectionOptions.defaultPort, 1_521)
    }

    func testRemainingMillisecondConnectBudgetTakesPrecedence() {
        let fields = [
            OracleConnectionOptions.AdditionalFieldKey.connectTimeoutMilliseconds: "1250",
            OracleConnectionOptions.AdditionalFieldKey.connectTimeoutSeconds: "30"
        ]

        XCTAssertEqual(OracleConnectionOptions.loginTimeoutSeconds(from: fields), 1.25)
    }

    func testConfiguredConnectSecondsAndOldHostDefault() {
        XCTAssertEqual(
            OracleConnectionOptions.loginTimeoutSeconds(from: [
                OracleConnectionOptions.AdditionalFieldKey.connectTimeoutSeconds: "2.5"
            ]),
            2.5
        )
        XCTAssertEqual(
            OracleConnectionOptions.loginTimeoutSeconds(from: [:]),
            OracleConnectionOptions.defaultLoginTimeoutSeconds
        )
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
