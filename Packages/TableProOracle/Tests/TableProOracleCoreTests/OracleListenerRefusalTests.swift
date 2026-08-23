import XCTest
@testable import TableProOracleCore

final class OracleListenerRefusalTests: XCTestCase {
    func testKnownCodesMapToHumanReasonWithORACode() {
        XCTAssertEqual(
            OracleListenerRefusal.detail(code: 12_514),
            "The listener does not know the requested service name (ORA-12514)."
        )
        XCTAssertEqual(
            OracleListenerRefusal.detail(code: 12_505),
            "The listener does not know the requested SID (ORA-12505)."
        )
        XCTAssertEqual(
            OracleListenerRefusal.detail(code: 12_528),
            "The listener is blocking new connections to the requested service (ORA-12528)."
        )
    }

    func testHandlerUnavailableCodesShareOneReason() {
        for code in [12_516, 12_519, 12_520] {
            XCTAssertEqual(
                OracleListenerRefusal.reason(forCode: code),
                "The listener has no handler available for the requested service"
            )
        }
    }

    func testUnknownCodeFallsBackToGenericMessage() {
        XCTAssertNil(OracleListenerRefusal.reason(forCode: 9_999))
        XCTAssertEqual(
            OracleListenerRefusal.detail(code: 9_999),
            "The Oracle listener refused the connection (ORA-9999)."
        )
    }

    func testMissingCodeFallsBackToGenericMessage() {
        XCTAssertEqual(
            OracleListenerRefusal.detail(code: nil),
            "The Oracle listener refused the connection."
        )
    }
}
