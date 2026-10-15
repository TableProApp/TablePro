import Foundation
@testable import TableProOracleCore
import Testing

struct OracleListenerRefusalTests {
    @Test func testKnownCodesMapToHumanReasonWithORACode() {
        #expect(OracleListenerRefusal.detail(code: 12_514) == "The listener does not know the requested service name (ORA-12514).")
        #expect(OracleListenerRefusal.detail(code: 12_505) == "The listener does not know the requested SID (ORA-12505).")
        #expect(OracleListenerRefusal.detail(code: 12_528) == "The listener is blocking new connections to the requested service (ORA-12528).")
    }

    @Test func testHandlerUnavailableCodesShareOneReason() {
        for code in [12_516, 12_519, 12_520] {
            #expect(OracleListenerRefusal.reason(forCode: code) == "The listener has no handler available for the requested service")
        }
    }

    @Test func testUnknownCodeFallsBackToGenericMessage() {
        #expect(OracleListenerRefusal.reason(forCode: 9_999) == nil)
        #expect(OracleListenerRefusal.detail(code: 9_999) == "The Oracle listener refused the connection (ORA-9999).")
    }

    @Test func testMissingCodeFallsBackToGenericMessage() {
        #expect(OracleListenerRefusal.detail(code: nil) == "The Oracle listener refused the connection.")
    }
}
