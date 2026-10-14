import Foundation
import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleNetworkEncryptionTests {
    @Test func testNetworkEncryptionKeyMatchesTheMacKey() {
        #expect(OracleConnectionOptions.AdditionalFieldKey.networkEncryption == "oracleNetworkEncryption")
    }

    @Test func testLevelRawValuesAreStableWireStrings() {
        #expect(OracleConnectionOptions.NetworkEncryption.rejected.rawValue == "rejected")
        #expect(OracleConnectionOptions.NetworkEncryption.accepted.rawValue == "accepted")
        #expect(OracleConnectionOptions.NetworkEncryption.requested.rawValue == "requested")
        #expect(OracleConnectionOptions.NetworkEncryption.required.rawValue == "required")
    }

    @Test func testLevelDefaultsToAcceptedWhenAbsent() {
        #expect(OracleConnectionOptions.networkEncryption(from: [:]) == .accepted)
    }

    @Test func testLevelDefaultsToAcceptedForAnUnknownValue() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.networkEncryption: "maybe"]
        #expect(OracleConnectionOptions.networkEncryption(from: fields) == .accepted)
    }

    @Test func testLevelIsReadFromAdditionalFields() {
        for level in OracleConnectionOptions.NetworkEncryption.allCases {
            let fields = [OracleConnectionOptions.AdditionalFieldKey.networkEncryption: level.rawValue]
            #expect(OracleConnectionOptions.networkEncryption(from: fields) == level)
        }
    }

    @Test func testEveryLevelMapsToTheMatchingDriverLevel() {
        #expect(OracleCoreConnection.encryptionLevel(for: .rejected) == .rejected)
        #expect(OracleCoreConnection.encryptionLevel(for: .accepted) == .accepted)
        #expect(OracleCoreConnection.encryptionLevel(for: .requested) == .requested)
        #expect(OracleCoreConnection.encryptionLevel(for: .required) == .required)
    }

    @Test func testOptionsDefaultToAccepted() {
        let options = OracleConnectionOptions(host: "localhost", user: "scott", password: "tiger")
        #expect(options.networkEncryption == .accepted)
    }

    @Test func testStalledLoginNamesTheStepItStalledIn() {
        let error = OracleCoreError.loginHandshakeStalled(phase: "advancedNegotiation")
        let description = error.errorDescription ?? ""
        #expect(description.contains("network encryption"), "\(description)")
    }

    @Test func testStalledLoginWithoutAPhaseStillReads() {
        let error = OracleCoreError.loginHandshakeStalled(phase: nil)
        #expect(!((error.errorDescription ?? "").isEmpty))
    }

    @Test func testAnUnknownPhaseFallsBackToItsRawLabel() {
        #expect(OracleCoreError.handshakePhaseName("somethingNew") == "somethingNew")
    }
}
