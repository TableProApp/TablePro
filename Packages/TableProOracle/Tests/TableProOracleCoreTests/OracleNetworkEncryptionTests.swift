import OracleNIO
@testable import TableProOracleCore
import XCTest

final class OracleNetworkEncryptionTests: XCTestCase {
    func testNetworkEncryptionKeyMatchesTheMacKey() {
        XCTAssertEqual(
            OracleConnectionOptions.AdditionalFieldKey.networkEncryption,
            "oracleNetworkEncryption"
        )
    }

    func testLevelRawValuesAreStableWireStrings() {
        XCTAssertEqual(OracleConnectionOptions.NetworkEncryption.rejected.rawValue, "rejected")
        XCTAssertEqual(OracleConnectionOptions.NetworkEncryption.accepted.rawValue, "accepted")
        XCTAssertEqual(OracleConnectionOptions.NetworkEncryption.requested.rawValue, "requested")
        XCTAssertEqual(OracleConnectionOptions.NetworkEncryption.required.rawValue, "required")
    }

    func testLevelDefaultsToAcceptedWhenAbsent() {
        XCTAssertEqual(OracleConnectionOptions.networkEncryption(from: [:]), .accepted)
    }

    func testLevelDefaultsToAcceptedForAnUnknownValue() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.networkEncryption: "maybe"]
        XCTAssertEqual(OracleConnectionOptions.networkEncryption(from: fields), .accepted)
    }

    func testLevelIsReadFromAdditionalFields() {
        for level in OracleConnectionOptions.NetworkEncryption.allCases {
            let fields = [OracleConnectionOptions.AdditionalFieldKey.networkEncryption: level.rawValue]
            XCTAssertEqual(OracleConnectionOptions.networkEncryption(from: fields), level)
        }
    }

    func testEveryLevelMapsToTheMatchingDriverLevel() {
        XCTAssertEqual(OracleCoreConnection.encryptionLevel(for: .rejected), .rejected)
        XCTAssertEqual(OracleCoreConnection.encryptionLevel(for: .accepted), .accepted)
        XCTAssertEqual(OracleCoreConnection.encryptionLevel(for: .requested), .requested)
        XCTAssertEqual(OracleCoreConnection.encryptionLevel(for: .required), .required)
    }

    func testOptionsDefaultToAccepted() {
        let options = OracleConnectionOptions(host: "localhost", user: "scott", password: "tiger")
        XCTAssertEqual(options.networkEncryption, .accepted)
    }

    func testStalledLoginNamesTheStepItStalledIn() {
        let error = OracleCoreError.loginHandshakeStalled(phase: "advancedNegotiation")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("network encryption"), description)
    }

    func testStalledLoginWithoutAPhaseStillReads() {
        let error = OracleCoreError.loginHandshakeStalled(phase: nil)
        XCTAssertFalse((error.errorDescription ?? "").isEmpty)
    }

    func testAnUnknownPhaseFallsBackToItsRawLabel() {
        XCTAssertEqual(OracleCoreError.handshakePhaseName("somethingNew"), "somethingNew")
    }
}
