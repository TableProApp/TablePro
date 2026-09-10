import XCTest
@testable import TableProOracleCore

final class OracleRoleTests: XCTestCase {
    func testRoleKeyMatchesTheMacKey() {
        XCTAssertEqual(OracleConnectionOptions.AdditionalFieldKey.role, "oracleRole")
    }

    func testRoleRawValuesAreStableWireStrings() {
        XCTAssertEqual(OracleConnectionOptions.Role.normal.rawValue, "normal")
        XCTAssertEqual(OracleConnectionOptions.Role.sysdba.rawValue, "sysdba")
        XCTAssertEqual(OracleConnectionOptions.Role.sysoper.rawValue, "sysoper")
    }

    func testRoleDefaultsToNormalWhenAbsent() {
        XCTAssertEqual(OracleConnectionOptions.role(from: [:]), .normal)
    }

    func testRoleDefaultsToNormalForAnUnknownValue() {
        let fields = [OracleConnectionOptions.AdditionalFieldKey.role: "sysasm"]
        XCTAssertEqual(OracleConnectionOptions.role(from: fields), .normal)
    }

    func testRoleIsReadFromAdditionalFields() {
        for role in OracleConnectionOptions.Role.allCases {
            let fields = [OracleConnectionOptions.AdditionalFieldKey.role: role.rawValue]
            XCTAssertEqual(OracleConnectionOptions.role(from: fields), role)
        }
    }

    func testEveryRoleMapsToTheMatchingOracleAuthenticationMode() {
        XCTAssertEqual(
            OracleCoreConnection.authenticationMode(for: .normal).description,
            "DEFAULT"
        )
        XCTAssertEqual(
            OracleCoreConnection.authenticationMode(for: .sysdba).description,
            "SYSDBA"
        )
        XCTAssertEqual(
            OracleCoreConnection.authenticationMode(for: .sysoper).description,
            "SYSOPER"
        )
    }

    func testOptionsDefaultToANormalLogon() {
        let options = OracleConnectionOptions(host: "localhost", user: "scott", password: "tiger")
        XCTAssertEqual(options.role, .normal)
    }
}
