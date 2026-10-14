import Foundation
@testable import TableProOracleCore
import Testing

struct OracleRoleTests {
    @Test func testRoleKeyMatchesTheMacKey() {
        #expect(OracleConnectionOptions.AdditionalFieldKey.role == "oracleRole")
    }

    @Test func testRoleRawValuesAreStableWireStrings() {
        #expect(OracleConnectionOptions.Role.normal.rawValue == "normal")
        #expect(OracleConnectionOptions.Role.sysdba.rawValue == "sysdba")
        #expect(OracleConnectionOptions.Role.sysoper.rawValue == "sysoper")
    }

    @Test func testRoleDefaultsToNormalWhenAbsent() {
        #expect(OracleConnectionOptions.role(from: [:]) == .normal)
    }

    @Test func testRoleDefaultsToNormalForAnUnknownValue() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.role: "sysasm"]
        #expect(OracleConnectionOptions.role(from: fields) == .normal)
    }

    @Test func testRoleIsReadFromAdditionalFields() {
        for role in OracleConnectionOptions.Role.allCases {
            let fields = [OracleConnectionOptions.AdditionalFieldKey.role: role.rawValue]
            #expect(OracleConnectionOptions.role(from: fields) == role)
        }
    }

    @Test func testEveryRoleMapsToTheMatchingOracleAuthenticationMode() {
        #expect(OracleCoreConnection.authenticationMode(for: .normal).description == "DEFAULT")
        #expect(OracleCoreConnection.authenticationMode(for: .sysdba).description == "SYSDBA")
        #expect(OracleCoreConnection.authenticationMode(for: .sysoper).description == "SYSOPER")
    }

    @Test func testOptionsDefaultToANormalLogon() {
        let options = OracleConnectionOptions(host: "localhost", user: "scott", password: "tiger")
        #expect(options.role == .normal)
    }
}
