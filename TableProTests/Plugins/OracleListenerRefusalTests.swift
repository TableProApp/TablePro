import Foundation
import Testing

@testable import TablePro

@Suite("Oracle listener refusal detail")
struct OracleListenerRefusalTests {
    @Test("Known listener codes map to a human reason with the ORA code")
    func knownCodes() {
        #expect(OracleListenerRefusal.detail(code: 12_514)
            == "The listener does not know the requested service name (ORA-12514).")
        #expect(OracleListenerRefusal.detail(code: 12_505)
            == "The listener does not know the requested SID (ORA-12505).")
        #expect(OracleListenerRefusal.detail(code: 12_528)
            == "The listener is blocking new connections to the requested service (ORA-12528).")
    }

    @Test("Handler-unavailable codes share one reason")
    func handlerUnavailableCodes() {
        for code in [12_516, 12_519, 12_520] {
            #expect(OracleListenerRefusal.reason(forCode: code)
                == "The listener has no handler available for the requested service")
        }
    }

    @Test("An unknown code falls back to the generic message with the code")
    func unknownCode() {
        #expect(OracleListenerRefusal.reason(forCode: 9_999) == nil)
        #expect(OracleListenerRefusal.detail(code: 9_999)
            == "The Oracle listener refused the connection (ORA-9999).")
    }

    @Test("A missing code falls back to the generic message")
    func missingCode() {
        #expect(OracleListenerRefusal.detail(code: nil)
            == "The Oracle listener refused the connection.")
    }
}
