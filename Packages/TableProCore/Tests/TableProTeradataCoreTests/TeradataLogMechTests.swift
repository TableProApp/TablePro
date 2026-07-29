import XCTest
@testable import TableProTeradataCore

final class TeradataLogMechTests: XCTestCase {
    private func config(_ mech: TeradataLogMech) -> TeradataConnectionConfig {
        TeradataConnectionConfig(host: "127.0.0.1", username: "u", password: "p", logMech: mech)
    }

    func testUnsupportedMechanismsRejectedBeforeNetwork() {
        for mech in [TeradataLogMech.ldap, .krb5, .jwt] {
            XCTAssertThrowsError(try TeradataConnection(config: config(mech)).connect()) { error in
                guard case TeradataWireError.unsupported(let detail) = error else {
                    return XCTFail("expected .unsupported for \(mech.rawValue), got \(error)")
                }
                XCTAssertTrue(detail.contains(mech.rawValue))
            }
        }
    }

    func testTd2AndTdnegoPassMechanismValidation() {
        for mech in [TeradataLogMech.td2, .tdnego] {
            XCTAssertThrowsError(try TeradataConnection(config: config(mech)).connect()) { error in
                if case TeradataWireError.unsupported = error {
                    XCTFail("\(mech.rawValue) must pass mechanism validation, was rejected as unsupported")
                }
            }
        }
    }
}
